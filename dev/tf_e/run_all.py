"""Runs every tests/*/test_*.py suite in parallel, writes each output to tf_e/<out>/<suite>.txt and prints a summary
line per suite as it finishes. Usage:

    run_all.py [out] [substring filters...] [-j N] [--all] [--dry-run]

- Only what changed: a suite runs when something it depended on changed since its last run (tools/testmap.py: its
  test files and helpers, the harness and mock, and the addon functions it called), or when it has no record yet.
  A suite that failed and whose inputs did not change is listed as failed again (exit code 1) without rerunning.
  --all runs every suite (before a release, or when in doubt); --dry-run only prints what would run and why.
- Longest first: each run records how long every suite took (tf_e/timings.json) and the next run starts the slowest
  ones first, so one long suite does not start last and hold up the end of the run.
- Shards: the suites in SHARDS are split into n processes run side by side (DZ_SHARD="i/n", see harness.in_shard).
- Machine-wide slots: every run_all on this machine shares SLOTS worker slots (lock files in tf_e/.slots/), so two
  agents running suites at once share the CPU instead of each starting a full set of workers. -j N caps this
  run's own workers (default: all slots).
- A suite is not started while less than MIN_FREE_MB of memory is free (unless nothing of this run is running).
"""
import ctypes
import glob
import json
import os
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
import testmap  # noqa: E402

try:
    sys.stdout.reconfigure(errors="replace", line_buffering=True)
except Exception:  # noqa: BLE001
    pass
from concurrent.futures import ThreadPoolExecutor, as_completed

SCRATCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = os.path.join(SCRATCH, "luaenv", "Scripts", "python.exe")
TF_E = os.path.join(SCRATCH, "tf_e")
TIMINGS = os.path.join(TF_E, "timings.json")
SLOT_DIR = os.path.join(TF_E, ".slots")
SLOTS = int(os.environ.get("DZ_TEST_SLOTS") or max(2, min(12, (os.cpu_count() or 8) - 6)))
MIN_FREE_MB = 1500
TIMEOUT = 1500

# suite (tests/<area>/<file>) -> shard count. Only suites that would otherwise set the length of a whole run.
SHARDS = {
    "scale/test_raid_night.py": 4,          # 4 cases of 1-4 minutes
    "regressions/test_final_review.py": 3,
    "patch/test_patch_net.py": 2,
    "sync/test_sync_traffic.py": 2,
    "strategy/test_strategy_3d.py": 2,
}

args = sys.argv[1:]
RUN_ALL = "--all" in args
DRY = "--dry-run" in args
args = [a for a in args if a not in ("--all", "--dry-run")]
jobs = SLOTS
if "-j" in args:
    i = args.index("-j")
    jobs = max(1, int(args[i + 1]))
    del args[i:i + 2]
OUT = os.path.join(TF_E, args[0] if args else "run")
FILTERS = args[1:]
os.makedirs(OUT, exist_ok=True)
os.makedirs(SLOT_DIR, exist_ok=True)


def suite_key(f):
    return os.path.relpath(f, os.path.join(SCRATCH, "tests")).replace("\\", "/")


files = sorted(glob.glob(os.path.join(SCRATCH, "tests", "*", "test_*.py")))
if FILTERS:
    files = [f for f in files if any(s in f.replace("\\", "/") for s in FILTERS)]

tasks = []  # (file, shard index, shard count)
for f in files:
    n = SHARDS.get(suite_key(f), 1)
    tasks.extend((f, i, n) for i in range(n))


def task_name(task):
    f, i, n = task
    name = os.path.basename(os.path.dirname(f)) + "__" + os.path.basename(f)[:-3]
    return name if n == 1 else "%s.s%dof%d" % (name, i + 1, n)


def load_timings():
    try:
        with open(TIMINGS, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


skipped = []
if not RUN_ALL:
    why = [(t, testmap.reason(task_name(t))) for t in tasks]
    skipped = [t for t, r in why if r is None]
    tasks = [t for t, r in why if r is not None]
    if DRY:
        for t, r in why:
            if r is not None:
                print("%-45s %s" % (task_name(t), r))
if DRY:
    print("== would run %d of %d suite run(s)" % (len(tasks), len(tasks) + len(skipped)))
    sys.exit(0)

timings = load_timings()
# unknown suites first (they may be long), then longest first
tasks.sort(key=lambda t: -timings.get(task_name(t), 1e9))


# -- machine-wide slots ----------------------------------------------------------------------------------------------
if os.name == "nt":
    import msvcrt

    def _try_lock(fh):
        try:
            msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
            return True
        except OSError:
            return False

    def _unlock(fh):
        fh.seek(0)
        msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
else:
    import fcntl

    def _try_lock(fh):
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            return False

    def _unlock(fh):
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


class _MemStatus(ctypes.Structure):
    _fields_ = [("dwLength", ctypes.c_ulong), ("dwMemoryLoad", ctypes.c_ulong), ("ullTotalPhys", ctypes.c_ulonglong),
                ("ullAvailPhys", ctypes.c_ulonglong), ("ullTotalPageFile", ctypes.c_ulonglong),
                ("ullAvailPageFile", ctypes.c_ulonglong), ("ullTotalVirtual", ctypes.c_ulonglong),
                ("ullAvailVirtual", ctypes.c_ulonglong), ("ullAvailExtendedVirtual", ctypes.c_ulonglong)]


def free_mb():
    if os.name != "nt":
        return 1e9
    st = _MemStatus()
    st.dwLength = ctypes.sizeof(st)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(st)):
        return 1e9
    return st.ullAvailPhys / 1048576


_running = [0]
_gate = threading.Lock()


def acquire_slot():
    """Blocks until one of the machine's SLOTS slots is free (and there is memory to start a suite); returns the
    locked file."""
    waited = 0.0
    while True:
        with _gate:
            if _running[0] == 0 or free_mb() >= MIN_FREE_MB or waited > 120:
                for k in range(SLOTS):
                    fh = open(os.path.join(SLOT_DIR, "slot_%02d.lock" % k), "a+")
                    if _try_lock(fh):
                        _running[0] += 1
                        return fh
                    fh.close()
        time.sleep(0.25)
        waited += 0.25


def release_slot(fh):
    with _gate:
        _running[0] -= 1
    try:
        _unlock(fh)
    finally:
        fh.close()


# -- running ---------------------------------------------------------------------------------------------------------
def run(task):
    f, i, n = task
    name = task_name(task)
    env = dict(os.environ)
    env.update(testmap.env_for(name))
    if n > 1:
        env["DZ_SHARD"] = "%d/%d" % (i, n)
    slot = acquire_slot()
    t0 = time.time()
    try:
        p = subprocess.run([PY, f], cwd=SCRATCH, capture_output=True, text=True, timeout=TIMEOUT, env=env,
                           encoding="utf-8", errors="replace")
        out = p.stdout + "\n" + p.stderr
        rc = p.returncode
    except subprocess.TimeoutExpired as e:
        out = "TIMEOUT\n" + str(e.stdout or "")
        rc = -1
    finally:
        release_slot(slot)
    dt = time.time() - t0
    out_path = os.path.join(OUT, name + ".txt")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(out)
    summary = [l for l in out.splitlines() if l.startswith("--") and ("passed" in l or "case" in l)]
    if not summary:
        summary = [l for l in out.splitlines() if "passed" in l]
    summary = summary[-1:] if summary else ["(no summary) rc=%s" % rc]
    fails = [l for l in out.splitlines() if l.startswith("FAIL")]
    testmap.finish(name, rc, t0, summary[0], fails, out_path)
    return name, rc, summary, fails, dt


def line(name, rc, summary, dt):
    return "%-45s rc=%s %5.0fs  %s" % (name, rc, dt, " | ".join(summary))


t_start = time.time()
results = []
with ThreadPoolExecutor(max_workers=jobs) as ex:
    for fut in as_completed([ex.submit(run, t) for t in tasks]):
        name, rc, summary, fails, dt = fut.result()
        results.append((name, rc, summary, fails, dt))
        print(line(name, rc, summary, dt))
        for l in fails:
            print("      " + l)
wall = time.time() - t_start

# remember this run's durations for the next run's order (merged: a filtered run keeps the others)
merged = load_timings()
merged.update({name: round(dt, 1) for name, rc, _, _, dt in results if rc != -1})
try:
    tmp = "%s.%d.tmp" % (TIMINGS, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, indent=0, sort_keys=True)
    os.replace(tmp, TIMINGS)
except OSError:
    pass

testmap.prune()
# skipped suites whose last run failed: nothing they depend on changed, so they still fail. Reported, not rerun.
stale_fails = []
for t in skipped:
    c = testmap.cached_result(task_name(t))
    if c and c[0] != 0:
        stale_fails.append((task_name(t), c))
bad = sorted(r for r in results if r[1] != 0)
print("== %d suite run(s), %d failed, %.0fs wall, %.0fs total%s" % (
    len(results), len(bad), wall, sum(r[4] for r in results),
    ("; %d skipped: nothing they depend on changed since their last run (--all runs them)" % len(skipped))
    if skipped else ""))
for name, rc, summary, fails, dt in bad:
    print("   FAILED " + line(name, rc, summary, dt))
for name, (rc, summary, fails, out) in sorted(stale_fails):
    print("   FAILED (last run, unchanged since) %-30s %s  %s" % (name, summary, out))
    for l in fails:
        print("      " + l)
if bad or stale_fails:
    sys.exit(1)

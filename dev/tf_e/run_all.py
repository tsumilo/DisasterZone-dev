"""Runs every tests/*/test_*.py suite in parallel, writes each output to tf_e/<out>/<suite>.txt and prints a summary
line per suite as it finishes. Usage:

    run_all.py [out] [substring filters...] [-j N] [--all] [--dry-run] [-x] [--windows]

- Only what changed: a suite runs when something it depended on changed since its last run (tools/testmap.py: its
  test files and helpers, the harness and mock, and the addon functions it called), or when it has no record yet.
  A suite that failed and whose inputs did not change is listed as failed again (exit code 1) without rerunning.
  --all runs every suite (before a release, or when in doubt); --dry-run only prints what would run and why.
- Release-only suites (RELEASE_ONLY: the 60-member scale suite) run only with --all or when a filter names them.
- Longest first: each run records how long every suite took (tf_e/timings.json) and the next run starts the slowest
  ones first, so one long suite does not start last and hold up the end of the run.
- Shards: the suites in SHARDS are split into n processes run side by side (DZ_SHARD="i/n", see harness.in_shard).
- Machine-wide slots: every run_all on this machine shares SLOTS worker slots (lock files in tf_e/.slots/), so two
  agents running suites at once share the CPU instead of each starting a full set of workers. -j N caps this
  run's own workers (default: all slots).
- A suite is not started while less than MIN_FREE_MB of memory is free (unless nothing of this run is running).
- -x (fail fast): suites that failed last time start first, and after the first failure no new suite starts (the
  ones already running finish). The edit loop: fix, rerun with -x, and hear about a break in a minute, not at the
  end. What did not run stays due for the next run.
- WSL: when the distro of tools/wsl/ is set up, suites run in Linux, where tools/forkrun.py builds each shared
  set-up once and forks a process per case (suites with a shared set-up 2-4x faster). WINDOWS_ONLY suites
  (file-copy heavy, Windows-specific or memory-hungry) and everything with --windows (or DZ_WSL=0) run on Windows as before.
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
# 8 on this machine (12 cores, 20 threads): measured 2026-10-12 on 46 suites, 8 workers finished in 113 s, 12 in 119 s
# (each suite ran 1.6x slower: the Lua heaps fight over memory and caches) and 6 in 126 s.
SLOTS = int(os.environ.get("DZ_TEST_SLOTS") or max(2, min(8, (os.cpu_count() or 8) - 6)))
MIN_FREE_MB = 1500
TIMEOUT = 1500

WSL_DISTRO = os.environ.get("DZ_WSL_DISTRO") or "Ubuntu-26.04"
# Run on Windows even when WSL is there: staging whole addon trees over 9P is slow (patch), they drive Windows
# programs / paths (launcher), or 60 clients a shard need more memory than the WSL VM has to spare (scale: ~3.4 GB a
# shard there, Linux's allocator keeps what the Lua heaps freed).
WINDOWS_ONLY = ("patch/", "launcher/", "scale/")

SHARDS = testmap.SHARDS                  # suite -> shard count (tools/testmap.py)
RELEASE_ONLY = testmap.RELEASE_ONLY      # suites only --all runs (or a filter naming them)

args = sys.argv[1:]
RUN_ALL = "--all" in args
DRY = "--dry-run" in args
FAIL_FAST = "-x" in args or "--fail-fast" in args
FORCE_WINDOWS = "--windows" in args or os.environ.get("DZ_WSL") == "0"
args = [a for a in args if a not in ("--all", "--dry-run", "-x", "--fail-fast", "--windows")]
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


skipped, held = [], []
if not RUN_ALL:
    why = [(t, testmap.reason(task_name(t))) for t in tasks]
    skipped = [t for t, r in why if r is None]
    tasks = [t for t, r in why if r is not None]
    # release-only suites wait for --all, unless a filter names them
    held = [t for t in tasks if suite_key(t[0]) in RELEASE_ONLY
            and not any(s in suite_key(t[0]) or s in t[0].replace("\\", "/") for s in FILTERS)]
    tasks = [t for t in tasks if t not in held]
    if DRY:
        for t, r in why:
            if r is not None:
                print("%-45s %s%s" % (task_name(t), r, "  [release-only: --all]" if t in held else ""))
if DRY:
    print("== would run %d of %d suite run(s)" % (len(tasks), len(tasks) + len(skipped) + len(held)))
    sys.exit(0)

timings = load_timings()
# unknown suites first (they may be long), then longest first
tasks.sort(key=lambda t: -timings.get(task_name(t), 1e9))
if FAIL_FAST:  # what failed last time is most likely what is being fixed: hear about it first
    tasks.sort(key=lambda t: (testmap.cached_result(task_name(t)) or (0,))[0] == 0)


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


# -- WSL -------------------------------------------------------------------------------------------------------------
def to_wsl(path):
    """A Windows path as WSL sees it (drive C: is /mnt/c)."""
    path = os.path.abspath(path)
    return "/mnt/%s%s" % (path[0].lower(), path[2:].replace("\\", "/"))


def wsl_ready():
    if FORCE_WINDOWS or os.name != "nt":
        return False
    try:
        p = subprocess.run(["wsl.exe", "-d", WSL_DISTRO, "-e", "test", "-x", "/opt/dzenv/bin/python"],
                           capture_output=True, timeout=60)
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


USE_WSL = wsl_ready() if not DRY else False
# the environment a suite gets, carried into WSL (/p: a path to translate, /l: a list of paths). Only the ones set:
# WSL hands a listed but unset variable over as an empty string.
WSLENV = ("DZ_COVER/p", "DZ_COVER_SRC/p", "PYTHONPATH/l", "DZ_SHARD", "DZ_FORK", "DZ_SCALE_N",
          "DISASTERZONE_ADDON_DIR/p", "DISASTERZONE_ROOMS_DIR/p", "DISASTERZONE_PATCH_SV/p", "DISASTERZONE_ROOMS",
          "DISASTERZONE_NO_BCCACHE")


def on_wsl(f):
    return USE_WSL and not suite_key(f).startswith(WINDOWS_ONLY)


def command(f, env):
    if not on_wsl(f):
        return [PY, f]
    names = [v for v in WSLENV if env.get(v.split("/")[0])]
    env["WSLENV"] = ":".join(names + ([env["WSLENV"]] if env.get("WSLENV") else []))
    return ["wsl.exe", "-d", WSL_DISTRO, "-e", "bash", to_wsl(os.path.join(SCRATCH, "tools", "wsl", "run.sh")),
            to_wsl(f)]


# -- running ---------------------------------------------------------------------------------------------------------
_failed = threading.Event()  # -x: set by the first failure


def run(task):
    f, i, n = task
    name = task_name(task)
    if FAIL_FAST and _failed.is_set():
        return name, None, [], [], 0.0
    slot = acquire_slot()
    if FAIL_FAST and _failed.is_set():
        release_slot(slot)
        return name, None, [], [], 0.0
    env = dict(os.environ)
    env.update(testmap.env_for(name))
    if n > 1:
        env["DZ_SHARD"] = "%d/%d" % (i, n)
    t0 = time.time()
    try:
        p = subprocess.run(command(f, env), cwd=SCRATCH, capture_output=True, text=True, timeout=TIMEOUT, env=env,
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
    if rc != 0:
        _failed.set()
    return name, rc, summary, fails, dt


def line(name, rc, summary, dt):
    return "%-45s rc=%s %5.0fs  %s" % (name, rc, dt, " | ".join(summary))


t_start = time.time()
results = []
not_run = []  # -x: never started after the first failure
with ThreadPoolExecutor(max_workers=jobs) as ex:
    for fut in as_completed([ex.submit(run, t) for t in tasks]):
        name, rc, summary, fails, dt = fut.result()
        if rc is None:
            not_run.append(name)
            continue
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
if not_run:
    print("   -x: %d suite run(s) not started after the first failure (still due): %s" % (
        len(not_run), ", ".join(sorted(not_run))))
if held:
    print("   release-only, not run (changed since their last run; --all runs them before a release): %s" % (
        ", ".join(sorted({suite_key(t[0]) for t in held}))))
if bad or stale_fails:
    sys.exit(1)

"""Runs every tests/*/test_*.py suite (parallel), writes each output to tf_e/<out>/<suite>.txt and prints the
summary lines. Usage: run_all.py <out> [substring filters...]  (Test & Fix agent dev aid)"""
import glob
import os
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(errors="replace")
except Exception:  # noqa: BLE001
    pass
from concurrent.futures import ThreadPoolExecutor

SCRATCH = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = os.path.join(SCRATCH, "luaenv", "Scripts", "python.exe")
OUT = os.path.join(SCRATCH, "tf_e", sys.argv[1] if len(sys.argv) > 1 else "run")
FILTERS = sys.argv[2:]
os.makedirs(OUT, exist_ok=True)

files = sorted(glob.glob(os.path.join(SCRATCH, "tests", "*", "test_*.py")))
if FILTERS:
    files = [f for f in files if any(s in f.replace("\\", "/") for s in FILTERS)]


def run(f):
    name = os.path.basename(os.path.dirname(f)) + "__" + os.path.basename(f)[:-3]
    t0 = time.time()
    try:
        p = subprocess.run([PY, f], cwd=SCRATCH, capture_output=True, text=True, timeout=1500,
                           encoding="utf-8", errors="replace")
        out = p.stdout + "\n" + p.stderr
        rc = p.returncode
    except subprocess.TimeoutExpired as e:
        out = "TIMEOUT\n" + str(e.stdout or "")
        rc = -1
    with open(os.path.join(OUT, name + ".txt"), "w", encoding="utf-8") as fh:
        fh.write(out)
    summary = [l for l in out.splitlines() if l.startswith("--") and ("passed" in l or "case" in l)]
    if not summary:
        summary = [l for l in out.splitlines() if "passed" in l]
    fails = [l for l in out.splitlines() if l.startswith("FAIL")]
    return name, rc, summary[-1:] if summary else ["(no summary) rc=%s" % rc], fails, time.time() - t0


with ThreadPoolExecutor(max_workers=8) as ex:
    for name, rc, summary, fails, dt in ex.map(run, files):
        print("%-45s rc=%s %5.0fs  %s" % (name, rc, dt, " | ".join(summary)))
        for l in fails:
            print("      " + l)

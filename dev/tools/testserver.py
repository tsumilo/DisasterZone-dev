"""Run-wide test server (POSIX: the WSL runner, tools/wsl/): tf_e/run_all.py starts one per run and hands it every
suite that runs in Linux. It loads the harness once, pre-loads clients (harness.build_templates: the addon's files
already run, for each client number a case is likely to use) and forks a process per suite from there, so a suite
starts with Python, the harness, the bytecode and those clients ready instead of building them again (each client
boot ~140 ms -> ~20 ms; a suite process ~1 s less to start).

    stdin   one job per line: {"id": n, "suite": "tests/x/test_y.py", "args": [...], "env": {name: value},
            "out": "<file for the suite's stdout + stderr>", "timeout": seconds}
    stdout  {"ready": true, "templates": n} once, then one {"id": n, "rc": exit code, "cpu": seconds} per finished
            job (rc -9 = killed at its timeout; cpu = processor time of the suite and its case processes)

A job runs in a fork of the server with its environment applied. When the job's environment differs from the
server's in something the harness reads at import (another addon folder, coverage on/off, ...), the fork starts a
fresh interpreter for the suite instead (exactly as run_all did before). End of stdin: running jobs are killed and
the server exits.
"""
import json
import os
import select
import signal
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# read when the harness / runner modules are imported: a job that sets these differently cannot reuse them
IMPORT_TIME_ENV = ("DISASTERZONE_ADDON_DIR", "DISASTERZONE_PATCH_SV", "DISASTERZONE_ROOMS_DIR", "DISASTERZONE_ROOMS",
                   "DISASTERZONE_NO_BCCACHE", "DZ_NATIVE_CACHE", "DZ_FORK", "DZ_COVER_SRC", "DZ_TEMPLATE_LOG")
# per job: applied to the forked process (and to the harness's own copies)
PER_JOB_ENV = ("DZ_COVER", "DZ_SHARD", "DZ_SCALE_N", "DZ_TEMPLATES")


def _emit(obj):
    data = (json.dumps(obj) + "\n").encode("utf-8")
    while data:
        n = os.write(1, data)
        data = data[n:]


def _fresh_interpreter(suite, args):
    os.execv(sys.executable, [sys.executable, suite] + list(args))


def _run_job(job):
    """In the forked process: runs the suite as `python <suite> <args>` would, then exits with its exit code."""
    os.setsid()                                   # (its case processes too: one group the server can kill)
    fd = os.open(job["out"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    null = os.open(os.devnull, os.O_RDONLY)
    os.dup2(null, 0)
    os.close(null)
    sys.stdout = open(1, "w", encoding="utf-8", errors="replace", buffering=1, closefd=False)
    sys.stderr = open(2, "w", encoding="utf-8", errors="replace", buffering=1, closefd=False)
    env = job.get("env") or {}
    os.chdir(DEV)
    suite = os.path.join(DEV, job["suite"])
    args = job.get("args") or []
    for k in PER_JOB_ENV:
        os.environ.pop(k, None)
    os.environ.update(env)
    if any(os.environ.get(k) != _SERVER_ENV.get(k) for k in IMPORT_TIME_ENV) or \
            bool(os.environ.get("DZ_COVER")) != bool(_SERVER_ENV.get("DZ_COVER")):
        _fresh_interpreter(suite, args)
    import harness
    harness._SHARD = os.environ.get("DZ_SHARD") or ""
    harness.COVER_FILE = os.environ.get("DZ_COVER") or None
    if "DZ_TEMPLATES" in env and not int(env["DZ_TEMPLATES"] or 0):
        harness._TEMPLATES.clear()                # (DZ_TEMPLATES=0: this suite boots every client itself)
    sys.argv = [suite] + list(args)
    sys.path[0] = os.path.dirname(suite)
    code = 0
    try:
        import runpy
        runpy.run_path(suite, run_name="__main__")
    except SystemExit as e:
        c = e.code
        code = c if isinstance(c, int) else (0 if c is None else 1)
        if c is not None and not isinstance(c, int):
            print(c, file=sys.stderr)
    except BaseException:  # noqa: BLE001 - reported like an uncaught exception
        traceback.print_exc()
        code = 1
    try:
        import atexit
        atexit._run_exitfuncs()                   # (testmap_rec writes the suite's record here, as at a normal exit)
    except BaseException:  # noqa: BLE001
        traceback.print_exc()
    for s in (sys.stdout, sys.stderr):
        try:
            s.flush()
        except Exception:  # noqa: BLE001
            pass
    os._exit(code & 0xFF)


_SERVER_ENV = {}


def main():
    _SERVER_ENV.update(os.environ)
    import harness
    import forkrun  # noqa: F401 - imported once here, like the harness
    n = int(os.environ.get("DZ_TEMPLATES") or 0)
    try:
        harness.warm()
        built = harness.build_templates(n) if forkrun.ON else 0
    except Exception:  # noqa: BLE001 - suites still run, booting every client themselves
        traceback.print_exc()
        harness._TEMPLATES.clear()
        built = 0
    print("testserver: %d pre-loaded client(s), pid %d" % (built, os.getpid()), file=sys.stderr, flush=True)
    _emit({"ready": True, "templates": built})

    running = {}        # pid -> (job id, deadline)
    buf = b""
    stdin_open = True
    while stdin_open or running:
        if stdin_open:
            r, _, _ = select.select([0], [], [], 0.05)
            if r:
                data = os.read(0, 65536)
                if not data:
                    stdin_open = False
                    for pid in list(running):     # run_all is gone: nobody will read the results
                        try:
                            os.killpg(pid, signal.SIGKILL)
                        except OSError:
                            pass
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    job = json.loads(line)
                    sys.stdout.flush()
                    sys.stderr.flush()
                    pid = os.fork()
                    if pid == 0:
                        try:
                            _run_job(job)
                        finally:
                            os._exit(70)
                    running[pid] = (job["id"], time.time() + float(job.get("timeout") or 1500))
        else:
            time.sleep(0.05)
        while running:
            try:
                pid, status, usage = os.wait4(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if pid == 0:
                break
            if pid not in running:
                continue
            jid, _ = running.pop(pid)
            rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)
            if stdin_open:      # cpu: the suite's processor time, its case processes included (they were reaped)
                _emit({"id": jid, "rc": rc, "cpu": round(usage.ru_utime + usage.ru_stime, 2)})
        now = time.time()
        for pid, (jid, deadline) in list(running.items()):
            if now > deadline:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except OSError:
                    pass
                running[pid] = (jid, float("inf"))
    os._exit(0)


if __name__ == "__main__":
    main()

"""Records what one test process depended on, for tf_e/run_all.py's change-based selection (tools/testmap.py).

Loaded at start-up by tools/covsite/sitecustomize.py into every Python process that has DZ_COVER set: the suite run_all
starts and any Python child process the suite starts (release.py, generators, ...). At exit it writes
<DZ_COVER>.<pid>.part:

    files  {path: sha1}   every file under dev/ or the addon folder the process opened for reading, plus the dev/
                          Python modules it imported (the suite, its helpers, harness, generators it imports)
    dirs   {path: sha1}   the listing of every such directory it listed (new or removed files change behaviour);
                          "addon:|*.toc" for the harness's look at the addon folder (Client.addon_name: only which
                          .toc files are there matters, not the folders a move adds)
    lua    {rel: sha1}    addon Lua files the harness loaded as chunks (only their called functions count, below)
    funcs  {rel: [line]}  addon functions (by the line they start on) some client called, from harness coverage

Paths are relative to the repo's dev/ folder ("dev:...") or to the addon folder ("addon:...").
A copy of every addon .toc the process read is kept next to the Lua sources (DZ_COVER_SRC/<sha1>.toc): tools/testmap.py
compares the TOC by its header lines and file order, so it needs the version the suite read.
"""
import fnmatch
import atexit
import hashlib
import json
import os
import sys
import time

DEV = os.path.normcase(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_ADDON = os.environ.get("DISASTERZONE_ADDON_DIR") or r"C:\World of Warcraft\_anniversary_\Interface\AddOns\DisasterZone"
ADDON = os.path.normcase(os.path.realpath(_ADDON))
# under dev/: run output, caches and the Python environment are not inputs
_SKIP = tuple(os.path.join(DEV, d) + os.sep for d in ("tf_e", ".luacache", ".testmap", "luaenv", "__pycache__"))
# the recorder itself is instrumentation, not an input: changing it must not rerun every suite
INSTRUMENTATION = ("dev:tools/testmap_rec.py", "dev:tools/covsite/sitecustomize.py")

_files = set()
_dirs = set()
_dir_glob = {}     # path -> glob: listings that only looked for some names (the harness's .toc lookup)


def key_of(path):
    """'dev:<rel>' / 'addon:<rel>' for a path under dev/ or the addon folder, else None."""
    try:
        p = os.path.normcase(os.path.abspath(path))
    except (TypeError, ValueError):
        return None
    if p.startswith(DEV + os.sep):
        if p.startswith(_SKIP) or "__pycache__" in p:
            return None
        k = "dev:" + p[len(DEV) + 1:].replace("\\", "/")
        return None if k in INSTRUMENTATION else k
    if p.startswith(ADDON + os.sep) or p == ADDON:
        return "addon:" + p[len(ADDON) + 1:].replace("\\", "/")
    real = os.path.normcase(os.path.realpath(p))  # dev/../addon/DisasterZone is a junction to the addon folder
    if real != p and real.startswith(ADDON + os.sep):
        return "addon:" + real[len(ADDON) + 1:].replace("\\", "/")
    for q in (p, real):                           # a game pack next to the addon: with its folder (tools/packs.py)
        if q.startswith(_PACKS_UNDER) and os.sep in q[len(_PACKS_UNDER):]:
            return "addon:" + q[len(_PARENT) + 1:].replace("\\", "/")
    return None


_PARENT = os.path.dirname(ADDON)
_PACKS_UNDER = os.path.join(_PARENT, os.path.normcase("DisasterZone_"))


def path_of(key):
    kind, rel = key.split(":", 1)
    if kind != "dev" and rel.lower().startswith("disasterzone_") and "/" in rel:   # (Windows keys are lower case)
        return os.path.join(_PARENT, rel.replace("/", os.sep))
    return os.path.join(DEV if kind == "dev" else ADDON, rel.replace("/", os.sep))


def sha1_file(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha1(fh.read()).hexdigest()
    except OSError:
        return None


def sha1_dir(path, pattern=None):
    try:
        names = sorted(os.listdir(path))
    except OSError:
        return None
    if pattern:
        names = [n for n in names if fnmatch.fnmatch(n.lower(), pattern.lower())]
    return hashlib.sha1("\n".join(names).encode("utf-8")).hexdigest()


def _keep_toc(key, path, sha):
    """Copy of an addon .toc the suite read (tools/testmap.py diffs the TOC by headers and file order)."""
    out = os.environ.get("DZ_COVER_SRC")
    if not out or not sha or not key.startswith("addon:") or not key.lower().endswith(".toc"):
        return
    dst = os.path.join(out, sha + ".toc")
    if os.path.exists(dst):
        return
    try:
        with open(path, "rb") as fh:
            data = fh.read()
        if hashlib.sha1(data).hexdigest() != sha:
            return
        os.makedirs(out, exist_ok=True)
        tmp = "%s.%d.tmp" % (dst, os.getpid())
        with open(tmp, "wb") as fh:
            fh.write(data)
        os.replace(tmp, dst)
    except OSError:
        pass


# Files and folder listings are hashed when they are READ (first time), so the record says what the process really
# saw even if an agent edits the file while the suite runs: the next selection compares against that and reruns the
# suite then, instead of dropping the whole record (which made every concurrent edit cost a full rerun).
_seen_files = {}   # key -> sha1 at first read
_seen_dirs = {}    # key -> sha1 of the listing at first listing
_busy = False      # our own hashing opens / lists files too: don't record those


def _audit(event, args):
    global _busy
    if _busy:
        return
    if event == "open":
        path, mode = args[0], args[1]
        if isinstance(path, (str, bytes)) and (mode is None or ("r" in mode and "+" not in mode)):
            h = sys.modules.get("harness")
            if h is not None and getattr(h, "_READING_CHUNK", False):
                return
            p = path if isinstance(path, str) else os.fsdecode(path)
            _files.add(p)
            _busy = True
            try:
                k = key_of(p)
                if k and k not in _seen_files and os.path.isfile(p):
                    _seen_files[k] = sha1_file(p)
                    _keep_toc(k, p, _seen_files[k])
            finally:
                _busy = False
    elif event in ("os.listdir", "os.scandir"):
        path = args[0]
        if isinstance(path, (str, bytes)):
            h = sys.modules.get("harness")
            if h is not None and getattr(h, "_LISTING", False):  # harness._stamp: file times, not a dependency
                return
            # the import system lists every sys.path folder: not a dependency (a new file there changes nothing)
            f = sys._getframe(1)
            for _ in range(4):
                if f is None:
                    break
                if "importlib" in f.f_code.co_filename or f.f_code.co_filename.startswith("<frozen"):
                    return
                f = f.f_back
            p = path if isinstance(path, str) else os.fsdecode(path)
            pat = None
            f = sys._getframe(1)
            for _ in range(3):
                if f is None:
                    break
                if f.f_code.co_name == "addon_name" and os.path.basename(f.f_code.co_filename) == "harness.py":
                    pat = "*.toc"   # Client.addon_name: which .toc files the folder has, nothing else
                    break
                f = f.f_back
            if pat:
                _dir_glob[p] = pat
            else:
                _dirs.add(p)
            _busy = True
            try:
                k = key_of(p)
                if k and pat:
                    k = k + "|" + pat
                if k and k not in _seen_dirs:
                    _seen_dirs[k] = sha1_dir(p, pat)
            finally:
                _busy = False


_T0 = time.time()


def _write():
    global _busy
    out = os.environ.get("DZ_COVER")
    if not out:
        return
    _busy = True
    files, dirs = dict(_seen_files), dict(_seen_dirs)
    stale = False
    for m in list(sys.modules.values()):
        f = getattr(m, "__file__", None)
        if f and f.endswith(".py"):
            _files.add(f)
    for p in _files:
        k = key_of(p)
        if k and k not in files and os.path.isfile(p):
            # never opened while we watched (a module imported from its cached .pyc): hashed only now, so it
            # proves nothing if it changed after this process started
            files[k] = sha1_file(p)
            try:
                stale = stale or os.path.getmtime(p) >= _T0 - 1
            except OSError:
                stale = True
    for p in _dirs:
        k = key_of(p)
        if k and k not in dirs:
            dirs[k] = sha1_dir(p)
    for p, pat in _dir_glob.items():
        k = key_of(p)
        if k and k + "|" + pat not in dirs:
            dirs[k + "|" + pat] = sha1_dir(p, pat)
    h = sys.modules.get("harness")
    lua = dict(getattr(h, "_COVER_FILES", {}) or {})
    funcs = {k: sorted(v) for k, v in (getattr(h, "_COVER_FUNCS", {}) or {}).items()}
    data = {"files": files, "dirs": dirs, "lua": lua, "funcs": funcs, "stale": stale}
    try:
        tmp = "%s.%d.tmp" % (out, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, separators=(",", ":"), sort_keys=True)
        os.replace(tmp, "%s.%d.part" % (out, os.getpid()))
    except OSError:
        pass


_started = False


def start():
    global _started
    if _started or not os.environ.get("DZ_COVER"):
        return
    _started = True
    sys.addaudithook(_audit)
    atexit.register(_write)

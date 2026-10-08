"""Change-based test selection for tf_e/run_all.py.

Every suite run_all starts records what it depended on (tools/testmap_rec.py + the harness's Lua coverage) in
dev/.testmap/cov/<task>.json, with its exit code. The next run starts a suite only when something it depended on
changed since its last run (a failed suite with unchanged inputs is reported failed again, not rerun):

  - no record yet (or its last run timed out, or a file it read changed while it ran);
  - a file it read changed (its own test file, a helper, harness, the mock, a generator, the TOC, ...) or a folder
    it listed gained/lost files;
  - an addon Lua file changed (diffed against the exact version the suite ran, kept in dev/.testmap/src/<sha1>.lua)
    in the own code of a function the suite called (a change inside a nested function counts for that function, not
    the one around it); in a data table `ns.X.Name = {...}` and the suite called a function that reads `.Name`; or
    in other top-level code (runs every suite that loaded the file). Comment-only and blank lines don't count. A
    function that is only added changes nothing by itself: what calls it changed too, or the test that calls it.

Not seen by the selection: the date and time, randomness, environment variables and files outside dev/ and the addon
folder. `run_all.py --all` runs everything (before a release, after changing the machine, when in doubt).

    python tools/testmap.py [filters...]   what run_all would run now, and why (= run_all.py --dry-run)
"""
import difflib
import glob
import hashlib
import json
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import testmap_rec as rec  # noqa: E402

MAP_DIR = os.environ.get("DZ_TESTMAP_DIR") or os.path.join(DEV, ".testmap")  # override: tools/test_testmap.py
COV_DIR = os.path.join(MAP_DIR, "cov")
SRC_DIR = os.path.join(MAP_DIR, "src")


# suite (tests/<area>/<file>) -> shard count, for tf_e/run_all.py. Only suites that would otherwise set the length
# of a whole run.
SHARDS = {
    "scale/test_raid_night.py": 4,          # 4 cases of 1-4 minutes
    "regressions/test_final_review.py": 3,
    "patch/test_patch_net.py": 2,
    "sync/test_sync_traffic.py": 2,
    "strategy/test_strategy_3d.py": 2,
}

# Release-only: slow scale suites that call nearly everything, so they would rerun on almost any change. A normal
# run_all leaves them out (and says so when they are due); --all, or a filter naming them, runs them. release.py warns
# when one has not passed on the current sources (release_check).
RELEASE_ONLY = {
    "scale/test_raid_night.py",             # 60 members through a raid night: cases up to ~4 minutes
}


def task_names(suite):
    """run_all's task names for a suite ("area/test_x.py"): one per shard."""
    area, f = suite.split("/", 1)
    base = "%s__%s" % (area, f[:-3])
    n = SHARDS.get(suite, 1)
    return [base] if n == 1 else ["%s.s%dof%d" % (base, i + 1, n) for i in range(n)]


def cover_base(task_name):
    return os.path.join(COV_DIR, task_name + ".json")


def env_for(task_name):
    """Environment additions that make a suite (and its child processes) record its dependencies."""
    base = cover_base(task_name)
    for p in glob.glob(base + ".*.part"):  # left over by a killed run
        try:
            os.remove(p)
        except OSError:
            pass
    os.makedirs(COV_DIR, exist_ok=True)
    site = os.path.join(HERE, "covsite")
    pp = os.environ.get("PYTHONPATH")
    return {"DZ_COVER": base, "DZ_COVER_SRC": SRC_DIR, "PYTHONPATH": site + (os.pathsep + pp if pp else "")}


def cached_result(task_name):
    """(rc, summary line, FAIL lines, output file) of the suite's last run, or None."""
    r = load_record(task_name)
    if r is None:
        return None
    return r.get("rc"), r.get("summary", ""), r.get("fails", []), r.get("out", "")


def finish(task_name, rc, started=None, summary="", fails=(), out=""):
    """Merges the parts the suite's processes wrote into its record, with the exit code and its result lines (a suite
    that failed and whose inputs did not change is reported from these instead of run again). A file it read that
    changed while it ran (another agent's edit) leaves it without a record, so it runs again next time."""
    base = cover_base(task_name)
    data = {"files": {}, "dirs": {}, "lua": {}, "funcs": {}}
    parts = sorted(glob.glob(base + ".*.part"))
    for p in parts:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        for k in ("files", "dirs", "lua"):
            data[k].update(d.get(k) or {})
        for rel, lines in (d.get("funcs") or {}).items():
            data["funcs"][rel] = sorted(set(data["funcs"].get(rel, [])) | set(lines))
    for p in parts:
        try:
            os.remove(p)
        except OSError:
            pass
    stale = False
    if started is not None:
        for key in list(data["files"]) + list(data["dirs"]):
            try:
                if os.path.getmtime(rec.path_of(key)) >= started - 1:
                    stale = True
                    break
            except OSError:
                stale = True
                break
    if not parts or stale or rc == -1:  # wrote nothing, ran on a moving target or timed out: runs next time
        try:
            os.remove(base)
        except OSError:
            pass
        return
    data["rc"] = rc
    data["at"] = time.time()
    data["summary"], data["fails"], data["out"] = summary, list(fails), out
    tmp = "%s.%d.tmp" % (base, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, base)


# -- current state (memoized for one selection pass) -----------------------------------------------------------------
_file_sha, _dir_sha, _lua_sha, _ranges, _changes = {}, {}, {}, {}, {}


def file_sha(key):
    if key not in _file_sha:
        _file_sha[key] = rec.sha1_file(rec.path_of(key))
    return _file_sha[key]


def dir_sha(key):
    if key not in _dir_sha:
        _dir_sha[key] = rec.sha1_dir(rec.path_of(key))
    return _dir_sha[key]


def lua_source(rel):
    """Current source of an addon Lua file as the harness hashes it (BOM stripped), or None."""
    try:
        with open(rec.path_of("addon:" + rel), "rb") as fh:
            src = fh.read()
    except OSError:
        return None
    return src[3:] if src.startswith(b"\xef\xbb\xbf") else src


def lua_sha(rel):
    if rel not in _lua_sha:
        src = lua_source(rel)
        _lua_sha[rel] = hashlib.sha1(src).hexdigest() if src is not None else None
    return _lua_sha[rel]


def func_ranges(src):
    """{linedefined: lastlinedefined} of every function in src (main chunk excluded), or None if it doesn't compile."""
    key = hashlib.sha1(src).hexdigest()
    if key not in _ranges:
        import luabc
        bc, err = luabc.compile_chunk(src, "=x")
        if bc is None:
            _ranges[key] = None
        else:
            out, stack = {}, list(luabc.parse_bytecode(bc).protos)
            while stack:
                f = stack.pop()
                out[f.linedefined] = max(out.get(f.linedefined, 0), f.lastlinedefined)
                stack.extend(f.protos)
            _ranges[key] = out
    return _ranges[key]


def _owners(ranges, nlines):
    """owner[line] = linedefined of the innermost function holding that line (0: top-level code)."""
    owner = [0] * (nlines + 2)
    for a, b in sorted(ranges.items(), key=lambda r: r[0] - r[1]):  # largest first, nested ones paint over
        b = min(b, nlines + 1)
        if b >= a:
            owner[a:b + 1] = [a] * (b + 1 - a)
    return owner


def _innermost_around(ranges, line):
    """linedefined of the innermost function holding both line and line + 1 (an insertion between them), or 0."""
    best = None
    for a, b in ranges.items():
        if a <= line and line + 1 <= b and (best is None or b - a < best[1] - best[0]):
            best = (a, b)
    return best[0] if best else 0


def _trivial(line):
    s = line.strip()
    return not s or s.startswith(b"--")


def changes(old_sha, rel):
    """How the addon file rel changed since version old_sha: ("top", line, text) for a change in top-level code, else
    ("funcs", {linedefined}) the functions of the old version whose own code changed. A change inside a nested
    function counts for that function only: the enclosing one runs the same code (it only creates the closure)."""
    new_sha = lua_sha(rel)
    key = (old_sha, new_sha)
    if key in _changes:
        return _changes[key]
    res = None
    try:
        with open(os.path.join(SRC_DIR, old_sha + ".lua"), "rb") as fh:
            old = fh.read()
    except OSError:
        res = ("top", 0, "no copy of the version the suite ran")
    new = lua_source(rel) if res is None else None
    if res is None and new is None:
        res = ("top", 0, "file removed")
    if res is None:
        old_r, new_r = func_ranges(old), func_ranges(new)
        if old_r is None or new_r is None:
            res = ("top", 0, "does not compile")
    if res is None:
        a, b = old.split(b"\n"), new.split(b"\n")
        own_old, own_new = _owners(old_r, len(a)), _owners(new_r, len(b))
        hit, names, local_at = set(), set(), {}

        def top_level(lines, k):
            """A change on top-level line k (0-based): note the field / file locals it defines, else a "top" result."""
            d = _defined_name(lines, k)
            text = lines[k].strip()[:80].decode("utf-8", "replace")
            if d is None:
                return ("top", k + 1, text)
            if d[0] != "local":
                names.update((d[0], n) for n in d[1])
            else:
                for n in d[1]:
                    local_at.setdefault(n, (k + 1, text))
            return None

        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
            if tag == "equal":
                continue
            for i in range(i1, i2):
                if own_old[i + 1]:
                    hit.add(own_old[i + 1])
                elif not _trivial(a[i]):
                    res = top_level(a, i)
                    if res:
                        break
            for j in range(j1, j2):
                if res is None and not own_new[j + 1] and not _trivial(b[j]):
                    res = top_level(b, j)
                    if res:
                        break
            if res is not None:
                break
            if i1 == i2:  # pure insertion between old lines i1 and i1 + 1
                f = _innermost_around(old_r, i1)
                if f:
                    hit.add(f)
        # a file-level local (`local PAGE_H = 38`) is seen only by this file: the functions here that use it, unless
        # other top-level code uses it too (then anything the file sets up may differ)
        for n, (line, text) in sorted(local_at.items()):
            if res is not None:
                break
            m = mentions(old_sha, "local", n)
            if m is None or m[1]:
                res = ("top", line, text)
            else:
                hit |= m[0]
        if res is None:
            res = ("funcs", hit, names)
    _changes[key] = res
    return res


_ASSIGN = re.compile(rb"^([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+)\s*=[^=]")
_GLOBAL = re.compile(rb"^([A-Za-z_][A-Za-z0-9_]*)\s*=[^=]")
_LOCAL = re.compile(rb"^local\s+(?!function\b)([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:=|$|--)")


def _defined_name(lines, k):
    """What the top-level statement holding line k defines: ("field", (Name,)) for `ns.Data.Name = ...` /
    `ns.NAME = ...`, ("local", (a, b)) for `local a, b = ...`; None for anything else (calls, if blocks, ...). The
    statement is the one starting on the nearest line at column 0 at or above k."""
    for i in range(k, -1, -1):
        line = lines[i]
        s = line.strip()
        if not s or s.startswith(b"--"):
            continue  # blank or comment
        if line[:1] in (b" ", b"\t") or line.startswith((b"}", b")", b"]")):
            continue  # inside a statement that starts further up
        m = _ASSIGN.match(line)
        if m:
            return "field", (m.group(1).rsplit(b".", 1)[1].decode("ascii"),)
        m = _GLOBAL.match(line)
        if m and m.group(1) not in (b"local", b"return", b"if", b"for", b"while", b"do", b"end"):
            return "global", (m.group(1).decode("ascii"),)
        m = _LOCAL.match(line.rstrip())
        if m:
            return "local", tuple(n.strip().decode("ascii") for n in m.group(1).split(b","))
        return None
    return None


_mentions = {}


def mentions(sha, scope, name):
    """For the stored source version sha: (linedefined of every function whose own code uses `name`, whether
    top-level code other than its defining statement uses it). scope "field": reads `.name` / `:name` / `["name"]`;
    scope "local": the bare identifier. None when there is no copy of that version."""
    key = (sha, scope, name)
    if key not in _mentions:
        try:
            with open(os.path.join(SRC_DIR, sha + ".lua"), "rb") as fh:
                src = fh.read()
        except OSError:
            _mentions[key] = None
            return None
        n = re.escape(name.encode())
        if scope == "field":
            pat = re.compile(rb"[.:]" + n + rb"\b|\[[\"']" + n + rb"[\"']\]")
        else:
            pat = re.compile(rb"(?<![.:\w])" + n + rb"\b")
        funcs, top = set(), False
        if pat.search(src):
            ranges = func_ranges(src) or {}
            lines = src.split(b"\n")
            own = _owners(ranges, len(lines))
            for i, line in enumerate(lines):
                if pat.search(line) and not line.lstrip().startswith(b"--"):
                    if own[i + 1]:
                        funcs.add(own[i + 1])
                    else:
                        d = _defined_name(lines, i)
                        if not (d and d[0] == scope and name in d[1]):
                            top = True
        _mentions[key] = (funcs, top)
    return _mentions[key]


def load_record(task_name):
    try:
        with open(cover_base(task_name), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def reason(task_name):
    """Why the task must run, or None when nothing it depended on changed since its last run (which may have failed:
    run_all reports that failure again without running it; --all runs it)."""
    r = load_record(task_name)
    if r is None:
        return "no record yet"
    for key, h in r.get("files", {}).items():
        if file_sha(key) != h:
            return "%s changed" % key.split(":", 1)[1]
    for key, h in r.get("dirs", {}).items():
        if dir_sha(key) != h:
            return "files added/removed in %s" % (key.split(":", 1)[1] or "the addon folder")
    funcs = r.get("funcs", {})
    lua = r.get("lua", {})
    for rel, h in lua.items():
        if lua_sha(rel) == h:
            continue
        ch = changes(h, rel)
        if ch[0] == "top":
            return "%s:%d top-level change (%s)" % (rel, ch[1], ch[2])
        both = ch[1].intersection(funcs.get(rel, ()))
        if both:
            return "%s: function at line %d changed" % (rel, min(both))
        # data changed (ns.Data.X = { ... }): the suite is affected if it called a function that reads X, or a file
        # whose top-level code reads X (an alias like `local X = ns.Data.X`) and the suite called anything there
        for scope, name in sorted(ch[2]):
            for rel2, h2 in lua.items():
                m = mentions(h2, scope, name)
                if m is None:
                    return "%s: %s changed (no copy of %s to check)" % (rel, name, rel2)
                called = funcs.get(rel2, ())
                if m[0].intersection(called) or (m[1] and called):
                    return "%s: %s changed, read by %s" % (rel, name, rel2)
    return None


def release_check():
    """Problems with the release-only suites (RELEASE_ONLY) on the current sources: [] when every shard of each passed
    and nothing it depends on changed since. release.py prints these as a warning."""
    out = []
    for suite in sorted(RELEASE_ONLY):
        for n in task_names(suite):
            c = cached_result(n)
            why = reason(n)
            if c is None:
                out.append("%s: no passing run on record" % n)
            elif why:
                out.append("%s: not run since %s" % (n, why))
            elif c[0] != 0:
                out.append("%s: failed its last run (%s)" % (n, c[3]))
    return out


def prune(keep_days=3):
    """Deletes source copies no record refers to (older than keep_days)."""
    used = set()
    for p in glob.glob(os.path.join(COV_DIR, "*.json")):
        try:
            with open(p, encoding="utf-8") as fh:
                used.update(json.load(fh).get("lua", {}).values())
        except (OSError, ValueError):
            pass
    cutoff = time.time() - keep_days * 86400
    for p in glob.glob(os.path.join(SRC_DIR, "*.lua")):
        if os.path.basename(p)[:-4] not in used:
            try:
                if os.path.getmtime(p) < cutoff:
                    os.remove(p)
            except OSError:
                pass
    # the harness's bytecode cache: entries no client loaded for a week (a hit refreshes the file's time)
    cutoff = time.time() - 7 * 86400
    for p in glob.glob(os.path.join(DEV, ".luacache", "*", "*.luac")):
        try:
            if os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass


if __name__ == "__main__":
    sys.argv[1:1] = ["--dry-run"]
    run_all = os.path.join(DEV, "tf_e", "run_all.py")
    sys.exit(__import__("subprocess").call([sys.executable, run_all] + sys.argv[1:]))

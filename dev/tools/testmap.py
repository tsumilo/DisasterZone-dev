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
    in other top-level code (runs every suite that loaded the file; a top-level for/while/do/if block that only fills
    tables counts like a data-table change of the fields it writes). Comment-only and blank lines don't count. A
    function that is only added changes nothing by itself: what calls it changed too, or the test that calls it.

Moves and splits (architecture run P4/P5: files moved to new folders, giant files split into several) do not count
as changes by themselves; see "Moved code" below and tools/testmap_lua.py for the exact rules.

Not seen by the selection: the date and time, randomness, environment variables and files outside dev/ and the addon
folder. `run_all.py --all` runs everything (before a release, after changing the machine, when in doubt).

Moved code
  - Paths: dev/.testmap/moves.json ({old path: new path}, written by tools/move.py) maps a record's old file names to
    today's. A file a record names that no longer exists and is not in moves.json is looked for by content (same
    text but for the line-1 guard) among today's TOC files.
  - The line-1 guard (`if DisasterZoneBoot and DisasterZoneBoot.Run("<path>", ...) ...`) does not count when it names
    the file's own path, in the version the suite ran and in today's.
  - The TOC: a suite whose Lua coverage came from the addon depends on its header lines and on the order of the files
    it ran, not on its bytes. A header change reruns every suite that read the TOC, as before; so does any TOC change
    for a suite that read it without running Lua (a tool test). Comments, files the suite did not run, and a pure
    rename of a file the suite ran change nothing.
  - When files moved/split/were added or reordered in the TOC, or a file's top-level code changed, the suite is
    checked as one program (tools/testmap_lua.py), the version it ran against today's:
      * load-time code (statements other than function definitions, local aliases/constants, data tables and module
        registrations) must be the same statements in the same order (wherever they live now), reading names bound
        the same way: else the suite reruns (as a top-level change did before, but only for suites that ran it);
      * every path (data table, field function, module) defined before a piece of load-time code still is when that
        code may reach it (module paths it reads or calls, followed through the functions it calls), and no module is
        read or extended before the file that creates it: else it reruns;
      * data tables are compared by path (`ns.Data.X = {...}`): a changed one reruns the suites that read `.X`;
      * every function the suite called must still exist with the same identity (qualified name or rename rule,
        identical own code, the names it reads bound the same way): else it reruns.
    With the TOC and file paths unchanged, files are compared one by one as before; a called function whose lines
    changed is looked up by identity (it may have moved), and a top-level change, or load-time code holding a function
    (`ns:On("X", function() ... end)`) that changed, hands the suite to the program check.
  - The harness's look at the addon folder (Client.addon_name) is recorded as "addon:|*.toc": only the .toc names, so a
    move that adds a folder at the top does not rerun everything. Records made before 2026-10-12 (no "rec" field)
    work the same: their listing of the addon folder counts only for the .toc when it is their only listing in the
    addon folder, and a TOC version they read is found in git when no copy of it was kept.

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
import testmap_lua as tl  # noqa: E402

MAP_DIR = os.environ.get("DZ_TESTMAP_DIR") or os.path.join(DEV, ".testmap")  # override: tools/test_testmap.py
COV_DIR = os.path.join(MAP_DIR, "cov")
SRC_DIR = os.path.join(MAP_DIR, "src")
PARSE_DIR = os.path.join(MAP_DIR, "parse")   # tools/testmap_lua.py parse cache
MOVES = os.path.join(MAP_DIR, "moves.json")  # {old addon path: new addon path}, written by tools/move.py
REC_VERSION = 2   # records with "rec" >= 2: the recorder keeps TOC copies and narrows the harness's root listing


# suite (tests/<area>/<file>) -> shard count, for tf_e/run_all.py. Only suites that would otherwise set the length
# of a whole run.
SHARDS = {
    "scale/test_raid_night.py": 4,          # 4 cases of 1-4 minutes
    "regressions/test_final_review.py": 3,
    "patch/test_patch_net.py": 4,           # 25 cases, ~140 s (2026-10-17)
    "patch/test_patch_boot.py": 3,          # 24 cases, ~80 s
    "patch/test_release_tool.py": 3,        # 10 cases, ~120 s (two of 30-40 s)
    "patch/test_patch_scale.py": 2,         # 2 cases: 60-80 s + 25 s
    "strategy/test_standins_gen.py": 3,     # 17 cases: one ~100 s generator run, the rest ~45 s
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
    that failed and whose inputs did not change is reported from these instead of run again). Files and listings are
    hashed when the suite first read them (tools/testmap_rec.py), so an edit made while it ran (another agent's) is
    just a change the next selection sees. Only a run that cannot prove what it read (a process flagged its part
    stale, or two processes saw different versions of one file) keeps the previous record instead: still a true
    account of the run before, and the inputs differ from it, so the suite runs again next time."""
    base = cover_base(task_name)
    data = {"files": {}, "dirs": {}, "lua": {}, "funcs": {}}
    parts = sorted(glob.glob(base + ".*.part"))
    stale = False
    for p in parts:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        stale = stale or bool(d.get("stale"))
        for k in ("files", "dirs", "lua"):
            for key, h in (d.get(k) or {}).items():
                if key in data[k] and data[k][key] != h:
                    stale = True
                data[k][key] = h
        for rel, lines in (d.get("funcs") or {}).items():
            data["funcs"][rel] = sorted(set(data["funcs"].get(rel, [])) | set(lines))
    for p in parts:
        try:
            os.remove(p)
        except OSError:
            pass
    if stale and rc != -1:
        return
    if not parts or stale or rc == -1:  # wrote nothing or timed out: runs next time
        try:
            os.remove(base)
        except OSError:
            pass
        return
    data["rc"] = rc
    data["rec"] = REC_VERSION
    data["at"] = time.time()
    data["summary"], data["fails"], data["out"] = summary, list(fails), out
    tmp = "%s.%d.tmp" % (base, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, base)


# -- current state (memoized for one selection pass) -----------------------------------------------------------------
_file_sha, _dir_sha, _lua_sha, _ranges, _changes = {}, {}, {}, {}, {}


def reset():
    """Forget everything memoized about the current files (a long-lived process, or a test that edits them)."""
    for d in (_file_sha, _dir_sha, _lua_sha, _changes, _mentions, _norm, _toc_copies, _programs):
        d.clear()
    _moves[0] = _toc_now[0] = _by_content[0] = None


def file_sha(key):
    if key not in _file_sha:
        _file_sha[key] = rec.sha1_file(rec.path_of(key))
    return _file_sha[key]


def dir_sha(key):
    """sha1 of a folder listing; "<key>|<glob>" (tools/testmap_rec.py): only the names matching the glob."""
    if key not in _dir_sha:
        _dir_sha[key] = rec.sha1_dir(*_dir_args(key))
    return _dir_sha[key]


def _dir_args(key):
    if "|" in key:
        key, pat = key.split("|", 1)
        return rec.path_of(key), pat
    return (rec.path_of(key),)


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


_GUARD_RE = re.compile(rb'^if DisasterZoneBoot and DisasterZoneBoot\.Run\("([^"]+)", \.\.\.\) then return end')


def norm_guard(src, rel):
    """src with its line-1 guard blanked (made a comment) when the guard names rel, the file's own path: a moved file
    whose guard was rewritten (tools/move.py) runs the same code."""
    if src is None or rel is None:
        return src
    m = _GUARD_RE.match(src)
    if not m or m.group(1).decode("utf-8", "replace") != rel:
        return src
    nl = src.find(b"\n")
    return b"--guard" + (src[nl:] if nl >= 0 else b"")


def old_source(sha):
    """The version of an addon file a suite ran (kept by the harness in SRC_DIR), or None."""
    try:
        with open(os.path.join(SRC_DIR, sha + ".lua"), "rb") as fh:
            return fh.read()
    except OSError:
        return None


def changes(old_sha, rel, cur=None):
    """How the addon file rel changed since version old_sha: ("top", line, text) for a change in top-level code, else
    ("funcs", {linedefined}) the functions of the old version whose own code changed. A change inside a nested
    function counts for that function only: the enclosing one runs the same code (it only creates the closure).
    cur: the file's path today when it moved (rel: the path the suite ran it under). A line-1 guard naming the file's
    own path is blanked on both sides (norm_guard)."""
    cur = cur or rel
    new_sha = lua_sha(cur)
    key = (old_sha, new_sha, rel, cur)
    if key in _changes:
        return _changes[key]
    res = None
    old = norm_guard(old_source(old_sha), rel)
    if old is None:
        res = ("top", 0, "no copy of the version the suite ran")
    new = norm_guard(lua_source(cur), cur) if res is None else None
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
                eff = _block_effects(lines, k)
                if eff is None:
                    return ("top", k + 1, text)
                # a top-level loop / do / if block that only fills tables: like a data-table change of what it writes
                fields, others = eff
                names.update(("field", n) for n in fields)
                for n in others:
                    if _is_file_local(lines, n):
                        local_at.setdefault(n, (k + 1, text))
                    else:
                        names.add(("global", n))
                return None
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
_FIELD_PATH = rb"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+"
_MULTI = re.compile(rb"^(" + _FIELD_PATH + rb"(?:\s*,\s*" + _FIELD_PATH + rb")+)\s*=[^=]")  # `a.X, a.Y = 1, 2`


def _strip(line, keep_strings=False):
    """line without its comment, and with string contents removed unless keep_strings (quotes stay)."""
    out, i, n, q = bytearray(), 0, len(line), None
    while i < n:
        c = line[i:i + 1]
        if q:
            if c == b"\\":
                if keep_strings:
                    out += line[i:i + 2]
                i += 2
                continue
            if c == q:
                q = None
                out += c
            elif keep_strings:
                out += c
            i += 1
            continue
        if c in (b'"', b"'"):
            q = c
            out += c
        elif line[i:i + 2] == b"--":
            break
        else:
            out += c
        i += 1
    return bytes(out)


_KEYWORDS = {b"if", b"elseif", b"while", b"for", b"and", b"or", b"not", b"return", b"function", b"local", b"until",
             b"in", b"then", b"do", b"end", b"else", b"repeat"}
# calls a top-level block may make and still count as "only fills tables": no side effects outside their arguments
_PURE = {b"pairs", b"ipairs", b"next", b"type", b"tostring", b"tonumber", b"select", b"unpack", b"rawget",
         b"rawequal", b"assert", b"format", b"floor", b"ceil", b"min", b"max", b"abs", b"sqrt", b"strsub",
         b"strlower", b"strupper", b"strlen", b"strfind", b"strmatch", b"gsub", b"strrep", b"strbyte", b"strchar",
         b"tconcat", b"table.concat", b"table.getn"}
_PURE_PREFIX = (b"math.", b"string.", b"bit.")
_PURE_METHODS = {b"format", b"gsub", b"sub", b"upper", b"lower", b"match", b"find", b"len", b"rep", b"byte",
                 b"gmatch"}
# calls that change only the table given as their first argument
_MUTATE_ARG = {b"table.insert", b"tinsert", b"table.remove", b"tremove", b"table.sort", b"sort", b"wipe",
               b"setmetatable", b"rawset"}
_CALL = re.compile(rb"([A-Za-z_][A-Za-z0-9_]*(?:[.:][A-Za-z_][A-Za-z0-9_]*)*)\s*\(")
_TARGET = re.compile(rb"(?<![\w.:\]])([A-Za-z_][A-Za-z0-9_]*)((?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\])*)\s*=(?!=)")
_OPENERS = re.compile(rb"\b(do|if|function|repeat)\b")
_CLOSERS = re.compile(rb"\b(end|until)\b")
_HEADER = re.compile(rb"^(for|while|do|if)\b")


def _block_effects(lines, k):
    """For a change on line k inside a top-level `for`/`while`/`do`/`if` block that only fills tables: (fields written,
    other names written). None when line k is not in such a block, or the block calls anything that could have other
    effects (a function of the addon or the game, a frame method ...): then it counts as top-level code."""
    start = None
    for i in range(k, -1, -1):
        line = lines[i]
        s = line.strip()
        if not s or s.startswith(b"--"):
            continue
        if line[:1] in (b" ", b"\t") or line.startswith((b"}", b")", b"]")):
            continue
        if re.match(rb"(else|elseif)\b", line) or (i == k and re.match(rb"end\b", line)):
            continue
        if _HEADER.match(line):
            start = i
        break
    if start is None:
        return None
    depth, end = 0, None
    for i in range(start, len(lines)):
        t = _strip(lines[i])
        depth += len(_OPENERS.findall(t)) - len(_CLOSERS.findall(t))
        if depth <= 0:
            end = i
            break
    if end is None or end < k:
        return None
    text = b"\n".join(_strip(lines[i]) for i in range(start, end + 1))
    if re.search(rb"[\)\]]\s*\(", text) or re.search(rb"\bfunction\b", text):
        return None  # a call through an expression, or a function made at load time: can't tell what it does
    declared = set()
    for m in re.finditer(rb"\blocal\s+([A-Za-z_][\w\s,]*)", text):
        declared.update(x.strip() for x in m.group(1).split(b",") if x.strip())
    for m in re.finditer(rb"\bfor\s+([A-Za-z_][\w\s,]*?)\s*(?:=|\bin\b)", text):
        declared.update(x.strip() for x in m.group(1).split(b",") if x.strip())
    fields, others = set(), set()

    def write(root, path):
        named = re.findall(rb"\.([A-Za-z_][A-Za-z0-9_]*)", path)
        if root in declared:
            return not path  # writing into a table through a block local: can't tell which table
        if named:
            # every field on the way: `UI.TAG_LOOK.live = x` is also read as TAG_LOOK[kind]
            fields.update(f.decode("ascii") for f in named)
        else:
            others.add(root.decode("ascii"))
        return True

    for m in _CALL.finditer(text):
        name = m.group(1)
        if name in _KEYWORDS:
            continue
        if b":" in name:
            if name.rsplit(b":", 1)[1] in _PURE_METHODS:
                continue
            return None
        if name in _PURE or name.startswith(_PURE_PREFIX):
            continue
        if name in _MUTATE_ARG:
            arg = re.match(rb"\s*([A-Za-z_][A-Za-z0-9_]*)((?:\.[A-Za-z_][A-Za-z0-9_]*)*)", text[m.end():])
            if not arg or not write(arg.group(1), arg.group(2)):
                return None
            continue
        return None
    # table constructors don't write anything: drop their contents before looking for assignments
    flat = text
    while True:
        nxt = re.sub(rb"\{[^{}]*\}", b"{}", flat)
        if nxt == flat:
            break
        flat = nxt
    for m in _TARGET.finditer(flat):
        root, path = m.group(1), m.group(2)
        if root in _KEYWORDS:
            continue
        if not write(root, path):
            return None
    return fields, others


def _is_file_local(lines, name):
    pat = re.compile(rb"^local\s+(?!function\b)[\w\s,]*\b" + re.escape(name.encode()) + rb"\b")
    return any(pat.match(l) for l in lines)
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
        m = _MULTI.match(line)
        if m:
            return "field", tuple(t.strip().rsplit(b".", 1)[1].decode("ascii") for t in m.group(1).split(b","))
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
                # a field is read as `.name` or `["name"]` (keep strings); a local only as code (not in "a string")
                if pat.search(_strip(line, keep_strings=(scope == "field"))):
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
    lua = r.get("lua", {})
    toc_key = None
    for key, h in r.get("files", {}).items():
        if key in rec.INSTRUMENTATION:
            continue  # (records written before the recorder left itself out)
        if key.lower() == "addon:" + ADDON_TOC.lower():
            toc_key = key
            continue
        if file_sha(key) != h:
            if key.startswith("addon:"):
                cur = resolve(key[6:])
                if cur and cur != key[6:] and file_sha("addon:" + cur) == h:
                    continue   # moved, same bytes
            return "%s changed" % key.split(":", 1)[1]
    legacy = r.get("rec", 0) < REC_VERSION
    for key, h in r.get("dirs", {}).items():
        if dir_sha(key) != h:
            if key == "addon:" and legacy and _legacy_root_ok(r, toc_key):
                continue
            return "files added/removed in %s" % (key.split(":", 1)[1].split("|")[0] or "the addon folder")
    old_toc = None
    if toc_key:
        h = r["files"][toc_key]
        if file_sha(toc_key) != h:
            if not lua:
                return "%s changed" % ADDON_TOC   # read by a tool, not run: its text is the input
            text = toc_copy(h)
            if text is None:
                return "%s changed (no copy of the version the suite read)" % ADDON_TOC
            old_toc = parse_toc_text(text)
            now = current_toc()
            for k in sorted(set(old_toc[0]) | set(now[0])):
                if old_toc[0].get(k) != now[0].get(k):
                    return "%s: header '%s' changed" % (ADDON_TOC, k)
    return lua_reason(r, old_toc)


def _data_reason(lua, funcs, scope, name, where):
    """Data changed (`ns.Data.X = { ... }`, a global table, ...): the suite is affected if it called a function that
    reads X, or a file whose top-level code reads X (an alias like `local X = ns.Data.X`) and it called anything
    there."""
    for rel2, h2 in lua.items():
        m = mentions(h2, scope, name)
        if m is None:
            return "%s: %s changed (no copy of %s to check)" % (where, name, rel2)
        called = funcs.get(rel2, ())
        if m[0].intersection(called) or (m[1] and called):
            return "%s: %s changed, read by %s" % (where, name, rel2)
    return None


def lua_reason(r, old_toc):
    """The addon-code part of reason(): the Lua files the suite ran against today's. old_toc: (headers, files) of the
    TOC version the suite read when today's differs, else None.

    Same files in the same order (moved ones mapped to their new paths): file by file as before (changes()), with a
    called function whose lines changed looked up by identity (it may have moved within the addon), and a top-level
    change handed to the program check. Otherwise (files moved/split/added/removed/reordered for this suite): the
    program check (SuiteCompare.reason)."""
    lua = r.get("lua", {})
    funcs = r.get("funcs", {})
    if not lua or (old_toc is None and all(lua_sha(rel) == h for rel, h in lua.items())):
        return None
    old_list, new_list, cur_of = program_lists(r, old_toc)
    structural = any(not cur_of.get(x) for x in lua) or new_list != [cur_of[x] for x in old_list]
    cache = {}

    def compare():
        if "c" not in cache:
            cache["c"] = build_compare(lua, old_list, new_list, cur_of)
        return cache["c"]

    if not structural:
        top = None
        for rel, h in lua.items():
            cur = cur_of[rel]
            if cur == rel and lua_sha(cur) == h:
                continue
            if norm_sha(cur) == old_norm_sha(h, rel):
                continue
            ch = changes(h, rel, cur)
            if ch[0] == "top":
                top = "%s:%d top-level change (%s)" % (cur, ch[1], ch[2])
                break
            # load-time code holding a function (`ns:On("X", function() ... end)`): its line belongs to that function
            # for changes(), so a registration added, removed or moved is only seen here
            if _inline_effects(old_source(h)) != _inline_effects(lua_source(cur)):
                top = "%s: load-time code with a function in it changed" % cur
                break
            for line in sorted(ch[1].intersection(funcs.get(rel, ()))):
                c = compare()
                if isinstance(c, str) or not c.found(rel, line):
                    return "%s: function at line %d changed" % (cur, line)
            for scope, name in sorted(ch[2]):
                why = _data_reason(lua, funcs, scope, name, cur)
                if why:
                    return why
        if top is None:
            return None
        c = compare()
        if isinstance(c, str):
            return top
        why = c.reason(funcs)
        return "%s: %s" % (top, why) if why else None
    c = compare()
    if isinstance(c, str):
        return c
    return c.reason(funcs)


def _inline_effects(src):
    """Texts of the top-level statements of src that are load-time code with a function written inside."""
    if src is None:
        return None
    fi = tl.parse(src, PARSE_DIR)
    if not fi.ok:
        return None
    return [s.text for s in fi.stmts if s.kind == "effect" and tl.F in s.toks]


class SuiteCompare(object):
    """A suite's program as it ran against today's (tools/testmap_lua.py)."""

    def __init__(self, lua, old_list, new_list, cur_of, compare):
        self.lua, self.cur_of = lua, cur_of
        self.C = compare
        self.O, self.N = compare.O, compare.N
        self.guards = ({i: rel for i, rel in enumerate(old_list)}, {i: rel for i, rel in enumerate(new_list)})

    def found(self, rel, line):
        """Every function of the old version of rel that starts on line has an equivalent today."""
        oi = self.O.pos.get(rel)
        if oi is None:
            return False
        idx = self.O.files[oi][1].by_line.get(line)
        if not idx:
            return False
        cp = self.N.pos.get(self.cur_of.get(rel))
        return all(self.C.find(oi, k, cp) for k in idx)

    def _same_last(self, path):
        """The last definition of a field function is the same function as before: same function of the same file
        (that file unchanged)."""
        n, o = self.N.fields.get(path), self.O.fields.get(path)
        if n is None or o is None or self.C.back.get(n[0]) != o[0] or n[1] != o[1]:
            return False
        return self.N.files[n[0]][1] is self.O.files[o[0]][1]

    def _shared(self):
        """What does not depend on the suite's calls (computed once per pair of programs): the load-time code verdict
        and the data tables that changed [(path, file today)]."""
        C = self.C
        if getattr(C, "shared", None) is None:
            O, N = self.O, self.N
            data = []
            for p in sorted(set(O.data) | set(N.data)):
                od, nd = O.data.get(p, []), N.data.get(p, [])
                same = O.data_texts(p) == N.data_texts(p)
                for (oi, osi), (ni, nsi) in zip(od, nd) if same else ():
                    if not all(C.eq_binding(oi, osi, ni, nsi, n) for n in O.files[oi][1].stmts[osi].free):
                        same = False
                        break
                if not same:
                    data.append((p, N.files[nd[0][0]][0] if nd else O.files[od[0][0]][0]))
            C.shared = (C.script_problem(self.guards), data)
        return C.shared

    def reason(self, funcs):
        why, data = self._shared()
        if why:
            return why
        O, N = self.O, self.N
        # data tables, by path
        for p, where in data:
            cut = max(p.rfind("."), p.rfind(":"))
            scope, name = ("field", p[cut + 1:]) if cut > 0 else ("global", p)
            why = _data_reason(self.lua, funcs, scope, name, where)
            if why:
                return why
        # every function the suite called
        for rel, lines in sorted(funcs.items()):
            oi = O.pos.get(rel)
            if oi is None:
                continue
            cur = self.cur_of.get(rel)
            ni = N.pos.get(cur)
            unchanged = ni is not None and old_norm_sha(self.lua[rel], rel) == norm_sha(cur)
            ofi = O.files[oi][1]
            for line in lines:
                idx = ofi.by_line.get(line)
                if not idx:
                    return "%s: no function at line %d in the version the suite ran" % (rel, line)
                for k in idx:
                    f = ofi.funcs[k]
                    if unchanged:
                        # same file, same code: only a definition of the same field function elsewhere that now
                        # comes later (or no longer does) matters
                        if not tl.is_field(f) or self._same_last(f.key[2:]):
                            continue
                    if not self.C.find(oi, k, ni):
                        return "%s: function at line %d changed or gone (%s)" % (cur or rel, line, tl.show(f.key)[:70])
        return None


_programs = {}


def build_compare(lua, old_list, new_list, cur_of):
    """SuiteCompare for a record, or a reason (text) when a version is missing or does not parse. Suites that ran the
    same files share the programs (and what was found equivalent)."""
    key = (tuple((rel, lua[rel]) for rel in old_list), tuple(new_list))
    hit = _programs.get(key)
    if hit is None:
        hit = _programs[key] = _build_programs(lua, old_list, new_list, cur_of)
    if isinstance(hit, str):
        return hit
    return SuiteCompare(lua, old_list, new_list, cur_of, hit)


def _build_programs(lua, old_list, new_list, cur_of):
    old_entries, new_entries = [], []
    for rel in old_list:
        src = old_source(lua[rel])
        if src is None:
            return "%s: no copy of the version the suite ran" % rel
        fi = tl.parse(src, PARSE_DIR)
        if not fi.ok:
            return "%s: the version the suite ran does not parse" % rel
        old_entries.append((rel, fi))
    for rel in new_list:
        src = lua_source(rel)
        if src is None:
            return "%s: missing" % rel
        fi = tl.parse(src, PARSE_DIR)
        if not fi.ok:
            return "%s does not parse" % rel
        new_entries.append((rel, fi))
    where = {rel: i for i, rel in enumerate(new_list)}
    back = {where[cur_of[rel]]: i for i, rel in enumerate(old_list) if cur_of.get(rel) in where}
    return tl.Compare(tl.Program(old_entries), tl.Program(new_entries), back)


# -- paths, moves and the TOC -----------------------------------------------------------------------------------------
ADDON_TOC = "DisasterZone.toc"
_moves, _toc_now, _norm, _by_content, _toc_copies = [None], [None], {}, [None], {}


def moves():
    """{old path: new path} from MOVES (tools/move.py)."""
    if _moves[0] is None:
        m = {}
        try:
            with open(MOVES, encoding="utf-8") as fh:
                raw = json.load(fh)
            m = {k: v for k, v in raw.get("moves", raw).items() if isinstance(v, str) and not k.startswith("_")}
        except (OSError, ValueError, AttributeError):
            pass
        _moves[0] = m
    return _moves[0]


def resolve(rel):
    """Where the file a record calls rel is today (moves.json chains followed; rel itself when it did not move), or
    None when it is gone."""
    m = moves()
    seen, cur = set(), rel
    while cur in m and cur not in seen:
        seen.add(cur)
        cur = m[cur]
    if cur != rel and lua_sha(cur) is not None:
        return cur
    if lua_sha(rel) is not None:
        return rel
    return None


def norm_sha(rel):
    """sha1 of today's file rel with its own-path guard blanked, or None."""
    key = ("now", rel)
    if key not in _norm:
        src = lua_source(rel)
        _norm[key] = hashlib.sha1(norm_guard(src, rel)).hexdigest() if src is not None else None
    return _norm[key]


def old_norm_sha(sha, rel):
    """sha1 of version sha of rel (as a suite ran it) with its own-path guard blanked, or None."""
    key = ("old", sha, rel)
    if key not in _norm:
        src = old_source(sha)
        _norm[key] = hashlib.sha1(norm_guard(src, rel)).hexdigest() if src is not None else None
    return _norm[key]


def _find_by_content(sha, rel):
    """Today's TOC file with the code of version sha of rel (a move moves.json does not know about), or None."""
    want = old_norm_sha(sha, rel)
    if want is None:
        return None
    if _by_content[0] is None:
        idx = {}
        for f in current_toc()[1]:
            if f.lower().endswith(".lua"):
                h = norm_sha(f)
                if h:
                    idx.setdefault(h, []).append(f)
        _by_content[0] = idx
    hits = _by_content[0].get(want, [])
    return hits[0] if len(hits) == 1 else None


def parse_toc_text(raw):
    """(headers {lowercase key: value}, [files with forward slashes]) as the harness reads a TOC."""
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8", "replace")
    if raw.startswith("﻿"):
        raw = raw[1:]
    headers, files = {}, []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("##"):
            k, _, v = line[2:].partition(":")
            headers[k.strip().lower()] = v.strip()
        elif line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return headers, files


def current_toc():
    if _toc_now[0] is None:
        try:
            with open(rec.path_of("addon:" + ADDON_TOC), "rb") as fh:
                _toc_now[0] = parse_toc_text(fh.read())
        except OSError:
            _toc_now[0] = ({}, [])
    return _toc_now[0]


def toc_copy(sha):
    """Bytes of the TOC version sha: the recorder's copy (SRC_DIR/<sha>.toc), else found in git history (and kept)."""
    if sha in _toc_copies:
        return _toc_copies[sha]
    try:
        with open(os.path.join(SRC_DIR, sha + ".toc"), "rb") as fh:
            out = fh.read()
    except OSError:
        out = _toc_from_git(sha)
        if out is not None:
            try:
                os.makedirs(SRC_DIR, exist_ok=True)
                with open(os.path.join(SRC_DIR, sha + ".toc"), "wb") as fh:
                    fh.write(out)
            except OSError:
                pass
    _toc_copies[sha] = out
    return out


def _toc_from_git(sha, depth=300):
    import subprocess
    path = rec.path_of("addon:" + ADDON_TOC)
    try:
        top = subprocess.run(["git", "-C", os.path.dirname(path), "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=20).stdout.strip()
        if not top:
            return None
        rel = os.path.relpath(path, top).replace("\\", "/")
        revs = subprocess.run(["git", "-C", top, "log", "--format=%H", "-n", str(depth), "--all", "--", rel],
                              capture_output=True, text=True, timeout=60).stdout.split()
        for rev in revs:
            blob = subprocess.run(["git", "-C", top, "show", "%s:%s" % (rev, rel)], capture_output=True,
                                  timeout=20).stdout
            lf = blob.replace(b"\r\n", b"\n")
            for v in (blob, lf, lf.replace(b"\n", b"\r\n")):
                if hashlib.sha1(v).hexdigest() == sha:
                    return v
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return None


def _legacy_root_ok(r, toc_key):
    """A record from before the recorder narrowed the harness's look at the addon folder (Client.addon_name lists it
    to find the .toc): when that listing is its only one in the addon folder, only the .toc being there matters. (No
    other code in dev/ lists just the addon folder: os.walk users list its subfolders too, and so stay strict.)"""
    if any(k.startswith("addon:") and k != "addon:" for k in r.get("dirs", {})):
        return False
    return bool(toc_key) and os.path.isfile(rec.path_of("addon:" + ADDON_TOC))


def program_lists(r, old_toc):
    """(old file list in load order, new file list in load order, {old path: path today or None}) for a record.
    old_toc: (headers, files) of the TOC version the suite read when it differs from today's, else None."""
    lua = r.get("lua", {})
    now_files = current_toc()[1]
    cur_of = {}
    for rel, h in lua.items():
        c = resolve(rel)
        cur_of[rel] = c if c is not None else _find_by_content(h, rel)
    if old_toc is not None:
        old_files = old_toc[1]
    else:
        # the TOC did not change (or the suite did not read it): today's order, mapped back to the old names
        back = {}
        for rel, c in cur_of.items():
            if c:
                back.setdefault(c, rel)
        old_files = [back[f] for f in now_files if f in back]
    in_toc = set(old_files)
    old_list = [f for f in old_files if f in lua]
    extras = sorted(f for f in lua if f not in in_toc)
    old_list += extras
    # today: the TOC order of what the old files became, plus the files new to the TOC when the suite booted the whole
    # addon from it (load_addon), not a hand-picked list (load_files)
    img = set(cur_of[f] for f in old_list if cur_of.get(f))
    img_all, boots = set(), False
    if old_toc is not None:
        for f in old_files:
            c = cur_of[f] if f in cur_of else resolve(f)
            if c:
                img_all.add(c)
        toc_lua = [f for f in old_files if f.lower().endswith(".lua")]
        boots = bool(toc_lua) and sum(1 for f in toc_lua if f in lua) * 2 >= len(toc_lua)
    new_list = [f for f in now_files if f in img or (boots and f.lower().endswith(".lua") and f not in img_all)]
    seen = set(new_list)
    for f in extras:
        c = cur_of.get(f)
        if c and c not in seen:
            new_list.append(c)
            seen.add(c)
    return old_list, new_list, cur_of


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
    """Deletes source / TOC copies no record refers to (older than keep_days), and their parse cache entries."""
    used = set()
    for p in glob.glob(os.path.join(COV_DIR, "*.json")):
        try:
            with open(p, encoding="utf-8") as fh:
                r = json.load(fh)
            used.update(r.get("lua", {}).values())
            used.update(h for k, h in r.get("files", {}).items() if k.lower().endswith(".toc"))
        except (OSError, ValueError):
            pass
    cutoff = time.time() - keep_days * 86400
    for p in glob.glob(os.path.join(SRC_DIR, "*.lua")) + glob.glob(os.path.join(SRC_DIR, "*.toc")):
        if os.path.basename(p)[:-4] not in used:
            try:
                if os.path.getmtime(p) < cutoff:
                    os.remove(p)
            except OSError:
                pass
    # parse cache (tools/testmap_lua.py): a week after it was written
    for p in glob.glob(os.path.join(PARSE_DIR, "*.pkl")):
        try:
            if os.path.getmtime(p) < time.time() - 7 * 86400:
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

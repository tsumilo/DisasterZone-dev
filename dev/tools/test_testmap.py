"""Self-test of run_all.py's change-based selection (tools/testmap.py) on a throwaway copy of the addon.

Runs two quick suites once to record what they depend on, then edits the copy and checks what --dry-run would run:
a function only suite A called -> A only; top-level code with a call -> both; a comment, or a function nobody calls yet -> none.
Then a real move of one file of the copy (tools/move.py): nothing to run, until a moved body changes. And the
move-aware rules (tools/testmap_lua.py) on synthetic records over a made-up addon (unit_moves): moves, splits, a
promoted helper, TOC reorders and header changes, load-time code moved.
Run: luaenv\\Scripts\\python.exe tools\\test_testmap.py   (~40s)
move.py: keep paths   (the made-up addon paths below are not the real addon's)
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEV = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import harness  # noqa: E402

SUITES = ("tests/boot-ui/test_tooltip.py", "tests/atlas/test_craft_materials.py")
PY = os.path.join(DEV, "luaenv", "Scripts", "python.exe")


OUTER = b"""local M = {}
function M.build(parent)
  local x = 1
  local function onClick(self)
    return x + 1
  end
  return onClick
end
return M
"""
DATA = b"""local _, ns = ...
ns.Data = ns.Data or {}

ns.Data.Foo = {
  a = 1,
  b = { 2 },
}

ns.BAR = {
  c = 3,
}
"""
GLOBAL = b"""DZBuild = {
    id = 1,
}
"""
LOCALS = b"""local _, ns = ...
local PAGE_H, PAGE_X = 38, 12 -- row height, inset
local LIMIT = 5
local SCALE = LIMIT * 2

local function rows(n)
  return n * PAGE_H
end

function ns.Inset()
  return PAGE_X
end
"""


BLOCK = b"""local _, ns = ...
local S = {}
S.C = { gold = 1, grey = 2 }
S.HEX = {}
for name, c in pairs(S.C) do
  S.HEX[name] = tostring(c)
end
local function hex(n)
  return S.HEX[n]
end
function ns.Gold()
  return S.C.gold
end
if ns.RegisterEvent then
  ns:RegisterEvent("PLAYER_LOGIN", ns.Gold)
end
"""
GRID = b"""local _, ns = ...
local EUI = {}
EUI.PAD, EUI.GAP = 10, 8
"""
HEADER = b"""if X and X.Run("UI/Comp/A.lua", ...) then return end -- UI/Comp/A.lua
local addonName, ns = ...
"""


def unit_changes():
    """testmap.changes() on small sources: which functions of the old version count as changed."""
    import hashlib
    import testmap
    tmp = tempfile.mkdtemp(prefix="dz_testmap_unit_")
    saved = testmap.SRC_DIR, testmap.lua_source, testmap.lua_sha
    try:
        testmap.SRC_DIR = tmp
        for src in (OUTER, DATA, LOCALS, GLOBAL, BLOCK, GRID, HEADER):
            with open(os.path.join(tmp, hashlib.sha1(src).hexdigest() + ".lua"), "wb") as fh:
                fh.write(src)
        out = []
        for name, old, new, want in (
            ("nested body", OUTER, OUTER.replace(b"x + 1", b"x + 2"), ("funcs", {4}, set())),
            ("outer body", OUTER, OUTER.replace(b"local x = 1", b"local x = 5"), ("funcs", {2}, set())),
            ("line added to the outer body", OUTER, OUTER.replace(b"  return onClick", b"  x = 2\n  return onClick"),
             ("funcs", {2}, set())),
            ("line added to the nested body", OUTER,
             OUTER.replace(b"    return x + 1", b"    x = 0\n    return x + 1"), ("funcs", {4}, set())),
            ("top-level code", OUTER, OUTER.replace(b"local M = {}", b"local M = { a = 1 }"), "top"),
            ("an entry of a data table", DATA, DATA.replace(b"a = 1", b"a = 2"), ("funcs", set(), {("field", "Foo")})),
            ("an entry added to the second table", DATA, DATA.replace(b"  c = 3,", b"  c = 3,\n  d = 4,"),
             ("funcs", set(), {("field", "BAR")})),
            ("the local above the tables", DATA, DATA.replace(b"local _, ns = ...", b"local _, ns, x = ..."), "top"),
            ("a file-level constant", LOCALS, LOCALS.replace(b"38, 12", b"40, 12"), ("funcs", {6, 10}, set())),
            ("a constant other top-level code uses", LOCALS, LOCALS.replace(b"LIMIT = 5", b"LIMIT = 6"), "top"),
            ("a new constant nobody uses yet", LOCALS, LOCALS.replace(b"local LIMIT", b"local NEW = 1\nlocal LIMIT"),
             ("funcs", set(), set())),
            ("a loop that only fills a table", BLOCK, BLOCK.replace(b"tostring(c)", b"tostring(c) .. \"!\""),
             ("funcs", set(), {("field", "HEX")})),
            ("a loop that calls into the addon", BLOCK, BLOCK.replace(b"tostring(c)", b"ns.Hex(c)"), "top"),
            ("an event registration", BLOCK, BLOCK.replace(b"PLAYER_LOGIN", b"PLAYER_ENTERING_WORLD"), "top"),
            ("two fields set on one line", GRID, GRID.replace(b"10, 8", b"10, 6"),
             ("funcs", set(), {("field", "PAD"), ("field", "GAP")})),
            ("a new local named like a word in the header string", HEADER,
             HEADER + b"local UI = ns.UI\nlocal function f()\n  return UI\nend\n", ("funcs", set(), set())),
            ("an entry of a global table", GLOBAL, GLOBAL.replace(b"id = 1", b"id = 2"),
             ("funcs", set(), {("global", "DZBuild")})),
        ):
            testmap.lua_source = lambda rel, new=new: new
            testmap.lua_sha = lambda rel, new=new: hashlib.sha1(new).hexdigest()
            got = testmap.changes(hashlib.sha1(old).hexdigest(), "X.lua")
            ok = got[0] == want if want == "top" else got == want
            out.append((name, ok, got))
        return out
    finally:
        testmap.SRC_DIR, testmap.lua_source, testmap.lua_sha = saved
        shutil.rmtree(tmp, ignore_errors=True)


def unit_finish():
    """testmap.finish(): an edit made while a suite ran no longer voids its record; a part that can't prove what it
    read keeps the previous record."""
    import testmap
    tmp = tempfile.mkdtemp(prefix="dz_testmap_finish_")
    saved = testmap.COV_DIR
    out = []
    try:
        testmap.COV_DIR = tmp
        base = testmap.cover_base("x__test_y")

        def part(pid, **kw):
            d = {"files": {"dev:a.py": "1"}, "dirs": {}, "lua": {"UI/A.lua": "9"}, "funcs": {"UI/A.lua": [3]}}
            d.update(kw)
            with open("%s.%d.part" % (base, pid), "w") as fh:
                json.dump(d, fh)

        def record():
            return testmap.load_record("x__test_y")

        part(1)
        testmap.finish("x__test_y", 0, time.time() + 100, "ok")  # "started" after every file's mtime: no longer matters
        r = record()
        out.append(("a record survives files changed during the run", bool(r) and r["files"] == {"dev:a.py": "1"}, r))
        part(2, files={"dev:a.py": "2"}, stale=True)
        testmap.finish("x__test_y", 1, None, "failed")
        r = record()
        out.append(("a stale part keeps the previous record", bool(r) and r["rc"] == 0, r and r.get("rc")))
        part(3, files={"dev:a.py": "3"})
        part(4, files={"dev:a.py": "4"})
        testmap.finish("x__test_y", 0, None, "ok")
        r = record()
        out.append(("two processes that saw different versions keep it too", bool(r) and r["files"]["dev:a.py"] == "1",
                    r and r["files"]))
        part(5, files={"dev:a.py": "5"})
        testmap.finish("x__test_y", 0, None, "ok")
        r = record()
        out.append(("a clean run replaces it", bool(r) and r["files"]["dev:a.py"] == "5", r and r["files"]))
        return out
    finally:
        testmap.COV_DIR = saved
        shutil.rmtree(tmp, ignore_errors=True)


# -- moves, splits and TOC changes (architecture run P4/P5): reason() on synthetic records over a small fake addon ----
def G(rel):
    return (b'if DisasterZoneBoot and DisasterZoneBoot.Run("' + rel.encode() + b'", ...) then return end'
            + b" -- DisasterZone: " + rel.encode() + b"\n")


HEAD = b"local addonName, ns = ...\n"
INIT = HEAD + b"""ns.Data = ns.Data or {}
ns.Data.Sizes = { small = 1, big = 2 }
function ns.Hello(x)
  return x
end
"""
UTIL = HEAD + b"""local Util = ns:NewModule("Util")
local PAD = 4
function Util.Pad(n)
  return n + PAD
end
"""
HELPERS = HEAD + b"""function ns.Helper1()
  return 1
end
"""
EXTRA = HEAD + b"""function ns.Extra()
  return 2
end
"""
BIG = HEAD + b"""local Big = ns:NewModule("Big")
local Util = ns.Util
local GAP = 8
local cache = {}
local function helper(x)
  return x * GAP
end
function Big:Build(x)
  cache[x] = helper(x)
  return cache[x]
end
function Big:Show(x)
  return Util.Pad(self:Build(x))
end
function Big:Hide()
  return cache
end
ns:RegisterEvent("PLAYER_LOGIN", function() Big:Build(1) end)
"""
KIT = HEAD + b"""local Big = ns:NewModule("Big")
local GAP = 8
local cache = {}
local function helper(x)
  return x * GAP
end
function Big:Build(x)
  cache[x] = helper(x)
  return cache[x]
end
function Big:Hide()
  return cache
end
"""
VIEWS = HEAD + b"""local Big = ns.Big
local Util = ns.Util
function Big:Show(x)
  return Util.Pad(self:Build(x))
end
ns:RegisterEvent("PLAYER_LOGIN", function() Big:Build(1) end)
"""
# the local helper promoted to a kit table field: called through a local alias / through the field
KIT_PROMOTED = HEAD + b"""local Big = ns:NewModule("Big")
Big._ = {}
local GAP = 8
local cache = {}
function Big._.helper(x)
  return x * GAP
end
function Big:Build(x)
  cache[x] = Big._.helper(x)
  return cache[x]
end
function Big:Hide()
  return cache
end
"""
OTHER = HEAD + b"""local Other = ns:NewModule("Other")
function Other.Ping()
  return "pong"
end
"""
TOC_HEAD = b"## Interface: 20506\n## Title: Fake\n\n# Boot\n"


def toc(files, head=TOC_HEAD):
    return head + b"".join(f.replace("/", "\\").encode() + b"\n" for f in files)


BASE = {"Core/Init.lua": INIT, "Core/Util.lua": UTIL, "Core/Helpers.lua": HELPERS, "UI/Extra.lua": EXTRA,
        "UI/Big.lua": BIG, "UI/Other.lua": OTHER}
ORDER = ["Core/Init.lua", "Core/Util.lua", "Core/Helpers.lua", "UI/Extra.lua", "UI/Big.lua", "UI/Other.lua"]


def lines_of(src, *needles):
    """Line numbers of the `function` keywords on the lines holding each needle."""
    out = []
    for i, l in enumerate(src.split(b"\n")):
        if any(n in l for n in needles):
            out.append(i + 2)  # (+1: 1-based, +1: the guard line written above the file)
    return out


def unit_moves():
    """reason() for three recorded suites: A boots the addon and calls Big's functions + Util.Pad, B boots it and
    calls Other.Ping only, C loads Init + Util by hand (load_files: no TOC) and calls Util.Pad."""
    import hashlib
    import testmap
    import testmap_rec
    tmp = tempfile.mkdtemp(prefix="dz_testmap_moves_")
    addon, mp = os.path.join(tmp, "DisasterZone"), os.path.join(tmp, "map")
    saved = (testmap_rec.ADDON, testmap.MAP_DIR, testmap.COV_DIR, testmap.SRC_DIR, testmap.PARSE_DIR, testmap.MOVES)
    out = []

    def sha(b):
        return hashlib.sha1(b).hexdigest()

    def write_tree(files, order, mv=None, toc_bytes=None):
        shutil.rmtree(addon, ignore_errors=True)
        for rel, body in files.items():
            p = os.path.join(addon, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as fh:
                fh.write(G(rel) + body)
        with open(os.path.join(addon, "DisasterZone.toc"), "wb") as fh:
            fh.write(toc_bytes if toc_bytes is not None else toc(order))
        if os.path.exists(testmap.MOVES):
            os.remove(testmap.MOVES)
        if mv:
            with open(testmap.MOVES, "w") as fh:
                json.dump(mv, fh)
        testmap.reset()

    try:
        testmap_rec.ADDON = addon
        testmap.MAP_DIR = mp
        testmap.COV_DIR, testmap.SRC_DIR = os.path.join(mp, "cov"), os.path.join(mp, "src")
        testmap.PARSE_DIR, testmap.MOVES = os.path.join(mp, "parse"), os.path.join(mp, "moves.json")
        for d in (testmap.COV_DIR, testmap.SRC_DIR):
            os.makedirs(d)
        # the run: records + the sources it ran (as the harness keeps them)
        base_toc = toc(ORDER)
        with open(os.path.join(testmap.SRC_DIR, sha(base_toc) + ".toc"), "wb") as fh:
            fh.write(base_toc)
        for rel, body in BASE.items():
            with open(os.path.join(testmap.SRC_DIR, sha(G(rel) + body) + ".lua"), "wb") as fh:
                fh.write(G(rel) + body)
        lua_all = {rel: sha(G(rel) + body) for rel, body in BASE.items()}
        recs = {
            "a": {"files": {"addon:DisasterZone.toc": sha(base_toc)}, "dirs": {"addon:|*.toc": None}, "lua": lua_all,
                  "funcs": {"UI/Big.lua": lines_of(BIG, b"function Big:Build", b"function Big:Show",
                                                    b"local function helper", b"function() Big:Build"),
                            "Core/Util.lua": lines_of(UTIL, b"function Util.Pad")}},
            "b": {"files": {"addon:DisasterZone.toc": sha(base_toc)}, "dirs": {"addon:|*.toc": None}, "lua": lua_all,
                  "funcs": {"UI/Other.lua": lines_of(OTHER, b"function Other.Ping")}},
            "c": {"files": {}, "dirs": {}, "lua": {k: lua_all[k] for k in ("Core/Init.lua", "Core/Util.lua")},
                  "funcs": {"Core/Util.lua": lines_of(UTIL, b"function Util.Pad")}},
        }
        write_tree(BASE, ORDER)
        toc_listing = testmap.dir_sha("addon:|*.toc")
        # d: b's record as the recorder wrote it before 2026-10-12: the harness's .toc lookup as a full listing of the
        # addon folder, no "rec"
        recs["d"] = dict(recs["b"], dirs={"addon:": testmap.dir_sha("addon:")})
        for n, r in recs.items():
            r.update(rc=0)
            if n != "d":
                r.update(rec=testmap.REC_VERSION)
                r["dirs"] = {k: toc_listing for k in r["dirs"]}
            with open(os.path.join(testmap.COV_DIR, "x__test_%s.json" % n), "w") as fh:
                json.dump(r, fh)

        def check(name, files, order, want, mv=None, toc_bytes=None):
            write_tree(files, order, mv, toc_bytes)
            got = {n: testmap.reason("x__test_" + n) for n in "abcd"}
            want = want + ("d" if "b" in want else "")   # (d is b, recorded the old way)
            ok = sorted(n for n, w in got.items() if w) == sorted(want)
            out.append((name, ok, {n: w for n, w in got.items() if w} or "nothing"))

        moved = dict(BASE)
        moved["Logic/Raids/Big.lua"] = moved.pop("UI/Big.lua")
        order_moved = [("Logic/Raids/Big.lua" if f == "UI/Big.lua" else f) for f in ORDER]
        check("nothing changed", BASE, ORDER, "")
        check("pure file move (moves.json)", moved, order_moved, "", {"UI/Big.lua": "Logic/Raids/Big.lua"})
        check("pure file move (found by content)", moved, order_moved, "")
        datamoved = dict(BASE)
        sizes = b"ns.Data.Sizes = { small = 1, big = 2 }\n"
        datamoved["Core/Init.lua"] = INIT.replace(sizes, b"")
        datamoved["Core/Util.lua"] = UTIL + sizes
        check("data table moved to another file", datamoved, ORDER, "")
        datamoved["Core/Util.lua"] = UTIL + sizes.replace(b"big = 2", b"big = 3")
        check("data table moved and changed (nobody reads it)", datamoved, ORDER, "")
        changed = dict(moved)
        changed["Logic/Raids/Big.lua"] = BIG.replace(b"Util.Pad(self:Build(x))", b"Util.Pad(self:Build(x)) + 1")
        check("function body changed after a move", changed, order_moved, "a", {"UI/Big.lua": "Logic/Raids/Big.lua"})
        split = dict(BASE)
        del split["UI/Big.lua"]
        split.update({"UI/Big/Kit.lua": KIT, "UI/Big/Views.lua": VIEWS})
        order_split = ORDER[:4] + ["UI/Big/Kit.lua", "UI/Big/Views.lua"] + ORDER[5:]
        check("file split into kit + views, identical bodies", split, order_split, "",
              {"UI/Big.lua": "UI/Big/Kit.lua"})
        check("split, the views file loaded before the kit", split,
              ORDER[:4] + ["UI/Big/Views.lua", "UI/Big/Kit.lua"] + ORDER[5:], "ab", {"UI/Big.lua": "UI/Big/Kit.lua"})
        const = dict(split)
        const["UI/Big/Kit.lua"] = KIT.replace(b"local GAP = 8", b"local GAP = 9")
        check("split, a moved function's constant differs in its new file", const, order_split, "a",
              {"UI/Big.lua": "UI/Big/Kit.lua"})
        state = dict(split)
        state["UI/Big/Kit.lua"] = KIT.replace(b"function Big:Hide()\n  return cache\nend\n", b"")
        state["UI/Big/Views.lua"] = VIEWS + b"local cache = {}\nfunction Big:Hide()\n  return cache\nend\n"
        check("split that gives a shared table two copies", dict(state), order_split, "a",
              {"UI/Big.lua": "UI/Big/Kit.lua"})
        promoted = dict(split)
        promoted["UI/Big/Kit.lua"] = KIT_PROMOTED
        check("local helper promoted to a kit table field", promoted, order_split, "",
              {"UI/Big.lua": "UI/Big/Kit.lua"})
        promoted["UI/Big/Kit.lua"] = KIT_PROMOTED.replace(b"x * GAP", b"x * GAP + 1")
        check("promoted helper whose body changed", promoted, order_split, "a", {"UI/Big.lua": "UI/Big/Kit.lua"})
        swapped = ORDER[:2] + ["UI/Extra.lua", "Core/Helpers.lua"] + ORDER[4:]
        check("TOC reorder of unrelated files", BASE, swapped, "")
        check("TOC comments and blank lines", BASE, ORDER, "",
              toc_bytes=TOC_HEAD + b"\n# Core\n" + toc(ORDER[:3], b"") + b"\n# UI\n" + toc(ORDER[3:], b""))
        check("TOC header changed", BASE, ORDER, "ab", toc_bytes=toc(ORDER, TOC_HEAD.replace(b"Fake", b"Fake2")))
        check("TOC reorder of files with load-time code", BASE,
              ["Core/Init.lua", "Core/Helpers.lua", "UI/Extra.lua", "UI/Big.lua", "Core/Util.lua", "UI/Other.lua"],
              "ab")
        moved_code = dict(BASE)
        reg = b'ns:RegisterEvent("PLAYER_LOGIN", function() Big:Build(1) end)\n'
        moved_code["UI/Big.lua"] = BIG.replace(reg, b"")
        moved_code["UI/Other.lua"] = OTHER + b"local Big = ns.Big\n" + reg
        check("load-time code moved to another file (reruns only suites that load them)", moved_code, ORDER, "ab")
        return out
    finally:
        (testmap_rec.ADDON, testmap.MAP_DIR, testmap.COV_DIR, testmap.SRC_DIR, testmap.PARSE_DIR,
         testmap.MOVES) = saved
        testmap.reset()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    failed = []
    for name, ok, got in unit_changes() + unit_finish() + unit_moves():
        print("%s unit: %s: %s" % ("PASS" if ok else "FAIL", name, got))
        if not ok:
            failed.append(name)
    tmp = tempfile.mkdtemp(prefix="dz_testmap_")
    addon = os.path.join(tmp, "DisasterZone")
    for root, _, files in os.walk(harness.ADDON_DIR):
        for f in files:
            if f.lower().endswith((".lua", ".toc", ".xml")):
                src = os.path.join(root, f)
                dst = os.path.join(addon, os.path.relpath(src, harness.ADDON_DIR))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
    env = dict(os.environ, DISASTERZONE_ADDON_DIR=addon, DZ_TESTMAP_DIR=os.path.join(tmp, "map"))
    time.sleep(2)  # a file changed within a second of a suite starting voids its record (testmap.finish)

    def run_all(*extra):
        p = subprocess.run([PY, os.path.join(DEV, "tf_e", "run_all.py"), "tm_selftest"] + list(SUITES) + list(extra),
                           cwd=DEV, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
        return p.stdout + p.stderr

    def would_run():
        out = run_all("--dry-run")
        return {l.split()[0]: l.split(None, 1)[1] for l in out.splitlines() if "__test_" in l}


    def check(name, got, want):
        ok = set(got) == set(want)
        print("%s %s: %s" % ("PASS" if ok else "FAIL", name, got))
        if not ok:
            failed.append(name)

    try:
        out = run_all("--all")
        names = re.findall(r"^(\S+__test_\S+)\s+rc=0", out, re.M)
        if len(names) != 2:
            print(out)
            raise SystemExit("FAIL: the two suites did not pass on the copy")
        a, b = sorted(names)
        check("nothing changed", would_run(), [])

        rec = {n: json.load(open(os.path.join(tmp, "map", "cov", n + ".json"))) for n in (a, b)}
        # a function only suite a called, in a file both loaded
        rel = line = None
        for r, lines in sorted(rec[a]["funcs"].items()):
            only = sorted(set(lines) - set(rec[b]["funcs"].get(r, [])))
            if only and r in rec[b]["lua"]:
                rel, line = r, only[0]
                break
        assert rel, "no function only %s calls" % a
        path = os.path.join(addon, rel)
        orig = open(path, "rb").read()
        lines = orig.split(b"\n")

        def edit(new_lines):
            with open(path, "wb") as fh:
                fh.write(b"\n".join(new_lines))

        edit(lines[:line] + [b"  local _dz_testmap_probe = 1"] + lines[line:])
        check("body of %s:%d (only %s calls it)" % (rel, line, a), would_run(), [a])

        edit(lines + [b"do local _dz_testmap_top = GetTime() end"])  # load-time code with a call
        check("top-level code in %s" % rel, would_run(), [a, b])

        edit([b"-- a comment"] + lines)
        check("comment only", would_run(), [])

        edit(lines + [b"local function _dz_testmap_new()", b"  return 1", b"end"])
        check("a new function nobody calls", would_run(), [])

        with open(path, "wb") as fh:
            fh.write(orig)
        check("edit undone", would_run(), [])

        # a real move (tools/move.py on the copy: TOC line, guard, moves.json): nothing to rerun; then a body change
        import move
        import release
        mrel = next(r for r, ls in sorted(rec[a]["funcs"].items()) if release.is_patchable(r) and r in rec[b]["lua"]
                    and set(ls) - set(rec[b]["funcs"].get(r, [])))
        mline = sorted(set(rec[a]["funcs"][mrel]) - set(rec[b]["funcs"].get(mrel, [])))[0]
        to = "Zmoved/" + mrel
        mapping = os.path.join(tmp, "mapping.json")
        with open(mapping, "w") as fh:
            json.dump([{"from": mrel, "to": to}], fh)
        nodev = os.path.join(tmp, "nodev")
        os.makedirs(nodev)
        move.Mover(mapping, root=tmp, addon=addon, dev=nodev, map_dir=os.path.join(tmp, "map"), use_git=False,
                   log=lambda *x: None).run()
        check("%s moved to %s (tools/move.py)" % (mrel, to), would_run(), [])
        mpath = os.path.join(addon, to)
        morig = open(mpath, "rb").read()
        ml = morig.split(b"\n")
        with open(mpath, "wb") as fh:
            fh.write(b"\n".join(ml[:mline] + [b"  local _dz_testmap_probe = 1"] + ml[mline:]))
        check("then a body only %s calls changed" % a, would_run(), [a])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("-- test_testmap: %d failed" % len(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

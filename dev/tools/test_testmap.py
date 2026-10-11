"""Self-test of run_all.py's change-based selection (tools/testmap.py) on a throwaway copy of the addon.

Runs two quick suites once to record what they depend on, then edits the copy and checks what --dry-run would run:
a function only suite A called -> A only; top-level code with a call -> both; a comment, or a function nobody calls yet -> none.
Run: luaenv\\Scripts\\python.exe tools\\test_testmap.py   (~30s)
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


def main():
    failed = []
    for name, ok, got in unit_changes() + unit_finish():
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
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("-- test_testmap: %d failed" % len(failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

"""Regression cases for the 1.4 refactor's phase 0 bug fixes (dev/docs/REFACTOR_PLAN.md, "Phase 0").

- the main window's seal halo: its texture path lost its backslashes (Lua 5.1 drops an unknown escape), so it never
  loaded; no other texture path in the addon may do the same
- Events: a change made while the guild key is not known yet (GetGuildInfo lags after a login) is refused, not a Lua
  error (Polls and Prized already checked)
- Dungeon runs: the board a member gets before the guild key is known is not lost in the "no guild" bucket

Run: luaenv\\Scripts\\python.exe tests\\regressions\\test_refactor_phase0.py [-k name]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, os.path.join(TESTS, "..", "tools"))

from _common import World, Client, case, run_all, solo  # noqa: E402
import harness  # noqa: E402

LATE_GUILD_NAME = r"""
local real = GetGuildInfo
__LATE_UNTIL = GetTime() + %d
GetGuildInfo = function(unit)
  if GetTime() < __LATE_UNTIL then return nil end
  return real(unit)
end
"""

LUA_ESCAPES = set('abfnrtv\\"\'0123456789\n')


def addon_dir():
    return getattr(harness, "ADDON_DIR", None) or os.environ.get("DISASTERZONE_ADDON_DIR") or os.path.join(
        TESTS, "..", "..", "addon", "DisasterZone")


def bad_escapes(text):
    """(line, literal) for every short string literal holding a backslash Lua 5.1 does not know (it drops it)."""
    out = []
    for no, line in enumerate(text.split("\n"), 1):
        j, n = 0, len(line)
        while j < n:
            ch = line[j]
            if line.startswith("--", j):
                break
            if ch in "\"'":
                q, start, bad = ch, j, False
                j += 1
                while j < n and line[j] != q:
                    if line[j] == "\\" and j + 1 < n:
                        if line[j + 1] not in LUA_ESCAPES and not bad:
                            bad = True
                            out.append((no, line[start:start + 80]))
                        j += 2
                        continue
                    j += 1
            j += 1
    return out


@case
def texture_paths_keep_their_backslashes():
    root = addon_dir()
    assert os.path.isfile(os.path.join(root, "UI", "MainFrame.lua")), root
    found = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d != "Libs"]
        for f in files:
            if not f.endswith(".lua"):
                continue
            p = os.path.join(base, f)
            with open(p, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            for no, lit in bad_escapes(text):
                if re.search(r"Interface\\[A-Za-z]", lit):
                    found.append("%s:%d %s" % (os.path.relpath(p, root), no, lit))
    assert not found, "texture paths with single backslashes:\n" + "\n".join(found)


@case
def the_seal_halo_loads_its_texture():
    w, c = solo("Alice")
    c.eval("ns.MainFrame:Open()")
    w.tick(0.5)
    paths = c.eval_py("""
        local out = {}
        local f = _G.DisasterZoneMainFrame
        for _, r in ipairs({ f:GetRegions() }) do
            local t = r.GetTexture and r:GetTexture()
            if type(t) == 'string' and t:find('Radial') then out[#out + 1] = t end
        end
        return out""") or []
    want = "Interface\\AddOns\\DisasterZone\\Media\\MyBiS\\Radial"
    assert len(paths) >= 2 and all(p == want for p in paths), paths
    w.assert_no_errors()


@case
def an_event_saved_before_the_guild_key_is_known_is_refused_cleanly():
    w, c = solo("Alice", guild_rank=0)
    c.eval("ns.Guild.__realKey = ns.Guild.GetGuildKey; ns.Guild.GetGuildKey = function() return nil end")
    res = c.eval_py("local ok, r = pcall(function() return ns.Events:SaveDef(ns.Events:NewDef(true)) end) "
                    "return { ok = ok, saved = ok and r == true, err = not ok and tostring(r) or nil }")
    assert res["ok"] is True and res["saved"] is False, res
    # once the key is known it saves as before
    c.eval("ns.Guild.GetGuildKey = ns.Guild.__realKey")
    assert c.eval("return ns.Events:SaveDef(ns.Events:NewDef(true))") is True
    assert c.eval("return #ns.Events:GetDefs()") == 1
    w.assert_no_errors()


@case
def the_dungeon_board_survives_a_late_guild_name():
    w = World()
    g = Client(w, "Gina", class_file="PALADIN", guild_rank=0)
    b = Client(w, "Bert", class_file="WARRIOR")
    for x in (g, b):
        x.load_addon()
    w.tick(50)
    rid = g.eval_py("local r, why = ns.DungeonRuns:List({ d = 'BlackMorass', h = true, role = 'healer', at = 0 }) "
                    "return r and r.id or why")
    assert isinstance(rid, str) and ":" in rid, rid
    w.tick(4)
    assert [r["id"] for r in b.eval_py("return ns.DungeonRuns:GetRuns()") or []] == [rid]
    # Bert logs in again; GetGuildInfo("player") answers nil for 20 s. He asks a member he knows for the board as soon
    # as the roster is in (3-8 s after it), long before the guild's name: the board must still be his after that.
    b.preload_lua = LATE_GUILD_NAME % 20
    b.relog(reload=False)
    b.preload_lua = None
    w.tick(12)
    assert b.eval("return ns.Guild:GetGuildKey()") is None
    w.tick(13)                   # (25 s: the name is known, the guild hello - 30-45 s - has not gone out yet)
    assert b.eval("return ns.Guild:GetGuildKey()") is not None
    assert [r["id"] for r in b.eval_py("return ns.DungeonRuns:GetRuns()") or []] == [rid]
    assert b.eval("return ns.db.runs['~'] == nil"), "a guild member's runs went into the no-guild bucket"
    w.tick(30)
    assert [r["id"] for r in b.eval_py("return ns.DungeonRuns:GetRuns()") or []] == [rid]
    w.assert_no_errors()


if __name__ == "__main__":
    run_all()

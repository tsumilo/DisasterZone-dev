"""Azeromon: the guild's marks (Marks.lua, 0.30).

Covers: a guildmate who closes the game leaves a last-seen marker where they stood ("Name · just now", later
"3 h ago"), none while they are still around, forgotten after a week, at most one per tile and PER_MAP per map,
kept on this account; Goldshire's statue goes scaffolding -> plinth -> finished with the week's guild goal tiers,
and last week's finished statue stands on; its base is solid and its plaque reads the goal; the statue and the
markers draw without errors.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_marks.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors, World, Client  # noqa: E402
from _azero_bot import BOT  # noqa: E402

CLOCK = 1790000000


def open_game(c, w, x, y, map_id="town"):
    c.eval(BOT)
    c.eval("T_AZ.seed(5)")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    for _ in range(40):
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        if not c.eval("return ns.Azero.pending ~= nil"):
            break
    c.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))


def two_players():
    w = World()
    a = Client(w, "Alice", guild_rank=3)
    b = Client(w, "Bob", guild_rank=3)
    for c in (a, b):
        c.load_addon()
    w.tick(3)
    open_game(a, w, 8, 10)
    open_game(b, w, 12, 12)
    for c in (a, b):
        c.eval("ns.AzeroUI.tipsOff = true ns.AzeroMarks.clock = %d ns.Azero:Data().lastSeen = nil" % CLOCK)
    w.tick(2)
    return w, a, b


def marks(c, map_id="town"):
    return c.eval_py("""local out = {}
      for _, e in ipairs(ns.AzeroMarks:On(%r)) do out[#out + 1] = { e.name, e.x, e.y, e.label } end
      return out""" % map_id) or []


@case
def a_guildmate_who_leaves_leaves_a_marker_where_they_stood():
    w, a, b = two_players()
    assert marks(b) == [], marks(b)                       # Alice is here: no marker
    a.eval("T_AZ.step('right')")
    w.tick(3)
    a.eval("ns.AzeroUI._Root():Hide()")                    # closes the game: AZL
    w.tick(2)
    assert marks(b) == [["Alice", 9, 10, "Alice · just now"]], marks(b)
    b.eval("ns.AzeroMarks.clock = %d" % (CLOCK + 3 * 3600))
    assert marks(b)[0][3] == "Alice · 3 h ago", marks(b)
    assert marks(b, "route1") == []
    # a week and a day later it's forgotten
    b.eval("ns.AzeroMarks.clock = %d ns.AzeroMarks:Update(5)" % (CLOCK + 8 * 86400))
    assert marks(b) == [] and b.eval("return next(ns.Azero:Data().lastSeen)") is None
    no_errors(w)


@case
def markers_are_one_per_tile_newest_first_and_capped():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.AzeroMarks.clock = %d" % CLOCK)
    r = c.eval_py("""local d = ns.Azero:Data()
      d.lastSeen = {}
      for i = 1, 9 do d.lastSeen['P' .. i] = { m = 'town', x = 10 + (i %% 8), y = 12, t = %d - i * 60, n = 'P' .. i, r = 2 } end
      d.lastSeen.Old = { m = 'town', x = 10, y = 9, t = %d - 99999, n = 'Old', r = 1 }      -- an older Goldshire
      d.lastSeen.Wall = { m = 'town', x = 0, y = 0, t = %d, n = 'Wall', r = 2 }            -- a tree now
      local out = {}
      for _, e in ipairs(ns.AzeroMarks:On('town')) do out[#out + 1] = e.name end
      return out""" % (CLOCK, CLOCK, CLOCK))
    assert r == ["P1", "P2", "P3", "P4", "P5", "P6"], r
    ago = c.eval_py("local A = ns.AzeroMarks.Ago return { A(30), A(25 * 60), A(5 * 3600), A(30 * 3600), A(4 * 86400) }")
    assert ago == ["just now", "25 min ago", "5 h ago", "yesterday", "4 days ago"], ago
    no_errors(w)


@case
def the_statue_follows_the_weekly_goal():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame()")
    stages = c.eval_py("""local B, M = ns.AzeroBounty, ns.AzeroMarks
      local st = B:State()
      local real = B.Tier
      local out = {}
      for _, t in ipairs({ 0, 1, 2, 3 }) do B.Tier = function() return t end out[#out + 1] = M.StatueStage() end
      B.Tier = function() return 1 end
      st.weeks[st.week - 1] = { wn = 5, tiers = { true, true, true } }          -- last week's was finished
      out[#out + 1] = M.StatueStage()
      st.weeks[st.week - 1] = nil
      B.Tier = real
      return out""")
    assert stages == [0, 1, 1, 2, 2], stages
    no_errors(w)


@case
def the_base_is_solid_and_the_plaque_reads_the_goal():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.Azero:EnterMap('town', 24, 15, 'up', true)")
    solid = c.eval_py("""local m = ns.Azero.map local o = {}
      for _, t in ipairs({ { 24, 13 }, { 25, 13 }, { 24, 14 }, { 25, 14 }, { 24, 12 }, { 24, 11 } }) do
        o[#o + 1] = m.solid[m.key(t[1], t[2])] == true end return o""")
    assert solid == [True, True, True, True, False, False], solid
    assert c.eval("return (ns.Azero:InteractHint())") == "Read the plaque"
    c.eval("ns.Azero:PressA()")
    texts = []
    for _ in range(4):
        p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
        if not p:
            break
        texts.append(p[1])
        c.eval("ns.Azero:Advance()")
    assert any("Scaffolding" in t for t in texts), texts
    assert any("This week's guild goal" in t for t in texts), texts
    no_errors(w)


@case
def the_statue_and_markers_draw():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.AzeroMarks.clock = nil local d = ns.Azero:Data() d.lastSeen = { X = { m = 'town', x = 22, y = 15,"
           " t = GetServerTime() - 7200, n = 'Thandor', c = 'MAGE', r = 2 } }")
    c.eval("ns.Azero:EnterMap('town', 24, 16, 'up', true)")
    for _ in range(10):
        w.tick(0.1)
    shown = c.eval_py("return ns.AzeroUI._GuildDrawn()")
    assert shown["statue"] == 8 and shown["marks"] == ["Thandor · 2 h ago"], shown
    no_errors(w)


if __name__ == "__main__":
    run_all()

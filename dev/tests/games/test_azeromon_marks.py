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


PRINCE = 661


def kill(c, days_ago, enc=PRINCE):
    """a guild kill in the raid log (no roster: the log dropped it, so it counts as the guild's)"""
    c.eval("""local now = GetServerTime()
      ns.db.raids.ck = { id = 'ck', start = now - %d, stop = now - %d + 7200, zone = 'Karazhan', att = {},
        bosses = { { enc = %d, ts = now - %d, dur = 245 } } }
      ns.AzeroHideout.Invalidate()""" % (days_ago * 86400 + 600, days_ago * 86400 + 600, enc, days_ago * 86400))


def town(c, hour=12, x=21, y=11, face="up"):
    c.eval("ns.AzeroMarks.clock = nil ns.Azero.clockHour = %r ns.Azero:EnterMap('town', %d, %d, '%s', true)" % (hour, x, y, face))


def npc(c, nid):
    return c.eval_py("for _, n in ipairs(ns.Azero.npcs) do if n.id == %r then return { x = n.x, y = n.y, hidden = n.hidden == true, act = n.act or false } end end" % nid)


def talk_texts(c, x, y, face):
    c.eval("ns.Azero:EnterMap('town', %d, %d, '%s', true) ns.Azero:PressA()" % (x, y, face))
    out = []
    for _ in range(8):
        p = c.eval_py("local p = ns.Azero.pending return p and { p.kind, p.text }")
        if not p or p[0] != "text":
            break
        out.append(p[1])
        c.eval("ns.Azero:Advance()")
    c.eval("ns.Azero.pending = nil ns.Azero.co = nil")
    return out


@case
def a_guild_raid_kill_brings_the_crier_pennants_and_standard_for_a_week():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.db.raids = ns.db.raids or {}")
    town(c)
    assert npc(c, "crier")["hidden"] and c.eval_py("return #ns.AzeroMarks.Props(ns.Azero.map)") == 0
    kill(c, 2)
    town(c)
    cr = npc(c, "crier")
    assert cr == {"x": 21, "y": 9, "hidden": False, "act": "cry"}, cr
    kinds = c.eval_py("local o = {} for _, p in ipairs(ns.AzeroMarks.Props(ns.Azero.map)) do o[#o + 1] = p.kind end return o")
    assert kinds.count("pennant") == 6 and kinds.count("standard_red") == 1, kinds
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert news == ["Hear ye! The guild slew Prince Malchezaar in Karazhan!"], news   # (a first, but two days old)
    kill(c, 0)
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert news == ["A guild first! Prince Malchezaar has fallen in Karazhan!"], news  # (its first kill ever, today)
    lines = talk_texts(c, 21, 10, "up")
    assert lines and lines[0] == "Town Crier: " + news[0], lines
    # the crier's day: the inn at night
    town(c, hour=23)
    assert npc(c, "crier")["hidden"]
    who = c.eval_py("local o = {} for _, e in ipairs(ns.AzeroRoutine.Town('town', 23 * 60)) do o[#o + 1] = e.name .. ':' .. e.where end return o")
    assert "Town Crier:Lion's Pride Inn" in who, who
    # eight days on: gone again
    kill(c, 8)
    town(c)
    assert npc(c, "crier")["hidden"] and c.eval_py("return #ns.AzeroMarks.Props(ns.Azero.map)") == 0
    no_errors(w)


@case
def townsfolk_mention_the_kill_once_each_and_a_toast_says_so_once():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.db.raids = ns.db.raids or {}")
    kill(c, 1)
    boss = c.eval("return ns.AzeroMarks.RecentKills()[1].name")
    c.eval("__TOASTS = 0 local real = ns.AzeroAch.Notify ns.AzeroAch.Notify = function(self, t) __TOASTS = __TOASTS + 1 end")
    c.eval("ns.Azero.clockHour = 12 ns.Azero:EnterMap('town', 20, 18, 'down')")
    c.eval("ns.Azero:EnterMap('town', 20, 18, 'down')")
    assert c.eval("return __TOASTS") == 1
    first = talk_texts(c, 20, 16, "down")                      # Maybell at her stall
    assert first and boss in first[0] and first[0].startswith("Maybell Maclure: "), first
    again = talk_texts(c, 20, 16, "down")
    assert again and boss not in again[0], again
    no_errors(w)


@case
def the_crier_also_cries_echoes_the_statue_and_shinies():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.db.raids = ns.db.raids or {}")
    kill(c, 1)
    c.eval("ns.Azero:RaidRareStore().midnight = GetServerTime() + 3600")
    c.eval("ns.AzeroMarks.AddNews('Grakk tamed a shiny Raptor!')")
    c.eval("ns.AzeroBounty.Tier = function() return 3 end")
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert any(n.startswith("The echo of ") and n.endswith("roams Elwynn Forest!") for n in news), news
    assert "The statue's done! Gold for the guild this week!" in news, news
    assert "Hear ye! Grakk tamed a shiny Raptor!" in news, news
    no_errors(w)


@case
def the_chronicle_draws_in_the_ui():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(7) ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle() ns.db.raids = ns.db.raids or {}")
    kill(c, 1)
    c.eval("ns.AzeroUI.tipsOff = true ns.Azero.clockHour = 12 ns.Azero:EnterMap('town', 21, 11, 'up', true)")
    for _ in range(6):
        w.tick(0.2)
    tiles = c.eval_py("return ns.AzeroUI._PropTiles()") or []
    assert "pennant" in tiles and "standard_red_0_1" in tiles, tiles
    no_errors(w)


def raid_week(c, raid_key, count=None, days_ago=1, old_days=30):
    """the guild's kills of `count` bosses of a raid (all when None) `days_ago`, each also killed `old_days` ago"""
    c.eval("""local H = ns.AzeroHideout H.Build()
      local now, bosses = GetServerTime(), {}
      for _, r in ipairs(H.RAIDS) do if r.key == %r then
        for i, b in ipairs(r.bosses) do if i <= (%s or #r.bosses) then
          bosses[#bosses + 1] = { enc = b.enc, ts = now - %d - i * 300, dur = 200 }
          if %d > 0 then bosses[#bosses + 1] = { enc = b.enc, ts = now - %d - i * 300, dur = 220 } end
        end end
      end end
      ns.db.raids['w' .. %r] = { id = 'w' .. %r, start = now - %d - 9000, stop = now - %d, zone = 'x', att = {}, bosses = bosses }
      H.Invalidate()""" % (raid_key, "nil" if count is None else count, days_ago * 86400, old_days, old_days * 86400,
                           raid_key, raid_key, days_ago * 86400, days_ago * 86400))


@case
def a_raid_week_is_one_headline_not_a_roll_call():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.db.raids = {}")
    kara = c.eval_py("local H = ns.AzeroHideout H.Build() for _, r in ipairs(H.RAIDS) do if #r.bosses > 5 then return { r.key, r.name, #r.bosses } end end")
    gruul = c.eval_py("local H = ns.AzeroHideout for _, r in ipairs(H.RAIDS) do if #r.bosses == 2 then return { r.key, r.name } end end")
    raid_week(c, kara[0])                                   # a full clear, every boss killed before
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert news == ["Hear ye! The guild cleared %s!" % kara[1]], news
    raid_week(c, gruul[0], count=1, days_ago=0)              # tonight: one boss of another raid
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert len(news) == 2 and news[1] == "Hear ye! The guild cleared %s!" % kara[1], news
    assert news[0].startswith("Hear ye! The guild slew ") and news[0].endswith(" in %s!" % gruul[1]), news
    c.eval("ns.db.raids = {}")
    raid_week(c, kara[0], count=4)                          # a part of the raid
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert news == ["Hear ye! The guild felled 4 bosses in %s!" % kara[1]], news
    raid_week(c, gruul[0], days_ago=0, old_days=0)           # killed for the very first time, today
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert len(news) == 3 and news[0].startswith("A guild first! ") and news[1].startswith("A guild first! "), news
    assert news[2] == "Hear ye! The guild felled 4 bosses in %s!" % kara[1], news
    raid_week(c, gruul[0], days_ago=2, old_days=0)           # the firsts, two days on: one raid line like the rest
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert news == ["Hear ye! The guild felled 4 bosses in %s!" % kara[1],
                    "Hear ye! The guild cleared %s!" % gruul[1]], news
    no_errors(w)


@case
def the_crier_cries_a_round_then_rests():
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.started = true ns.db.raids = {}")
    kill(c, 0)
    kill2 = c.eval_py("""local H = ns.AzeroHideout H.Build() local now = GetServerTime()
      for _, r in ipairs(H.RAIDS) do if #r.bosses == 2 then
        ns.db.raids.g = { id = 'g', start = now - 9000, stop = now - 3000, zone = 'x', att = {},
          bosses = { { enc = r.bosses[1].enc, ts = now - 3600, dur = 200 }, { enc = r.bosses[1].enc, ts = now - 40 * 86400, dur = 200 } } }
        H.Invalidate() return r.name end end""")
    news = c.eval_py("return ns.AzeroMarks.News()")
    assert len(news) == 2, (news, kill2)
    seen = c.eval_py("""local real, o = GetTime, {}
      ns.AzeroMarks.roundAt = nil
      for t = 1000, 1000 + 2 * (12 + 180), 0.5 do GetTime = function() return t end o[#o + 1] = ns.AzeroMarks.CrierLine() or false end
      GetTime = real return o""")
    # each line once per round (both rounds), quiet in between: 2 lines x 2 rounds, ~10 shown samples each
    said = [x for x in seen if x]
    assert set(said) == set(news), said
    assert 30 <= len(said) <= 50, len(said)
    first_quiet = seen.index(False, 25)
    assert not any(seen[first_quiet:first_quiet + 300]), "talks during the rest"
    no_errors(w)


if __name__ == "__main__":
    run_all()

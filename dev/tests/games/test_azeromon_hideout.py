"""Azeromon: the Guild Hall (Hideout.lua).

Covers: the stairs under the Lion's Pride Inn; a plinth for every raid boss with an encounter id; trophies read
from the raid log (a kill counts when more than half the roster were guildmates; kills, first date, fight time,
fastest, who was there); the plinth's look follows the log (the map compiles afresh); Space at a plinth opens the
trophy screen with the boss and its plaque, X closes it; the champions' statues name the record holders; the
guild Bestiary board; the raid log records how long a kill took.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_hideout.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

PRINCE = 661          # Prince Malchezaar's encounter id (Data/Items.lua)
DAY = 86400


def game(ui=False):
    w, c = solo("Alice", tick=2, members=[("Bob", "MAGE", 3), ("Cid", "ROGUE", 3)])
    c.eval(BOT)
    c.eval("T_AZ.seed(9)")
    c.eval("ns.Azero:NewGame()")
    if ui:
        c.slash("/cdl play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def seed_kills(c):
    c.eval("""local now = GetServerTime()
      ns.db.raids.k1 = { id = 'k1', start = now - 7 * %d, stop = now - 7 * %d + 7200, zone = 'Karazhan', att = {},
        bosses = { { enc = %d, ts = now - 7 * %d + 5000, roster = { 'Alice', 'Bob', 'Cid', 'Zed' }, dur = 245 } } }
      -- a pug: one guildmate among four does not make it the guild's kill
      ns.db.raids.k2 = { id = 'k2', start = now - %d, stop = now - %d + 7200, zone = 'Karazhan', att = {},
        bosses = { { enc = %d, ts = now - %d + 5000, roster = { 'Alice', 'Xan', 'Yob', 'Zed' }, dur = 100 } } }
      -- an older guild kill, timed slower, the roster already dropped by the log
      ns.db.raids.k3 = { id = 'k3', start = now - 30 * %d, stop = now - 30 * %d + 7200, zone = 'Karazhan', att = {},
        bosses = { { enc = %d, ts = now - 30 * %d + 5000, dur = 300 } } }
      ns.AzeroHideout.Invalidate()""" % (DAY, DAY, PRINCE, DAY, DAY, DAY, PRINCE, DAY, DAY, DAY, PRINCE, DAY))


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def the_stairs_under_the_inn_lead_to_the_hall_and_back():
    w, c = game()
    c.eval("ns.Azero:EnterMap('post', 5, 3, 'up', true)")
    c.eval("T_AZ.step('up')")
    where = c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }")
    assert where == ["hideout", 14, 22], where
    c.eval("T_AZ.step('down')")
    where = c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }")
    assert where == ["post", 5, 3], where
    assert c.eval_py("return ns.AzeroWorld.PlaceOf('hideout').id") == "goldshire"
    no_errors(w)


@case
def every_raid_boss_has_a_plinth():
    w, c = game()
    r = c.eval_py("""local H, G = ns.AzeroHideout, ns.Azero
      G:EnterMap('hideout', 14, 22, 'up', true)
      local m = G.map
      local plinths, empty, raids = 0, 0, {}
      for k, o in pairs(m.object) do
        if o.boss then plinths = plinths + 1 if m.over[k] == 'plinthempty' then empty = empty + 1 end end
      end
      local expected = 0
      for _, raid in ipairs(ns.Data.Raids) do
        local seen = {}
        for _, b in ipairs(raid.bosses) do
          if b.encounterID and not b.isTrash and not b.isChest and not seen[b.encounterID] then
            seen[b.encounterID] = true expected = expected + 1
          end
        end
      end
      for _, raid in ipairs(H.RAIDS) do raids[#raids + 1] = raid.key end
      return { plinths = plinths, empty = empty, expected = expected, raids = raids, prince = H.Boss(661).name,
               display = H.Display(H.Boss(661)) }""")
    assert r["plinths"] == r["expected"] and r["plinths"] > 40, r
    assert r["empty"] == r["plinths"], r                              # nothing killed yet
    assert r["raids"][0] == "Karazhan" and "SunwellPlateau" in r["raids"], r
    assert r["prince"] == "Prince Malchezaar" and r["display"] == 19274, r
    no_errors(w)


@case
def trophies_come_from_the_guilds_kills_in_the_raid_log():
    w, c = game()
    seed_kills(c)
    r = c.eval_py("""local H = ns.AzeroHideout
      local t = H.Trophy(661)
      return { kills = t.kills, first = t.first.dur, best = t.best.dur, roster = t.first.roster, lines = H.Lines(661),
               attumen = H.Lines(652) }""")
    assert r["kills"] == 2, r                                         # k1 and the old k3; not the pug
    assert r.get("roster") is None and r["first"] == 300, r               # the oldest kill's roster is gone
    assert r["best"] == 245, r
    assert r["lines"][0] == "Killed 2 times by the guild.", r
    assert r["lines"][1].startswith("First kill: ") and r["lines"][1].endswith(" in 5:00"), r
    assert r["lines"][2].startswith("Fastest: 4:05 ("), r
    assert r["lines"][3].startswith("Last kill: "), r
    assert r["attumen"][0] == "An empty plinth.", r
    # the plinth's look follows the log
    tile = c.eval_py("""local G = ns.Azero
      G:EnterMap('hideout', 14, 22, 'up', true)
      for k, o in pairs(G.map.object) do if o.boss and o.boss.enc == 661 then return G.map.over[k] end end""")
    assert tile == "plinth", tile
    no_errors(w)


@case
def space_at_a_plinth_shows_the_boss_and_its_plaque():
    w, c = game(ui=True)
    seed_kills(c)
    c.eval("""local G = ns.Azero
      local px, py
      G:EnterMap('hideout', 14, 22, 'up', true)
      for k, o in pairs(G.map.object) do if o.boss and o.boss.enc == 661 then px, py = o.x, o.y end end
      G:EnterMap('hideout', px, py + 1, 'up', true)
      G:PressA()""")
    w.tick(0.5)
    assert c.eval_py("local p = ns.Azero.pending return p and p.kind") == "trophy"
    panel = c.eval_py("return ns.AzeroUI._Trophy()")
    assert panel["title"] == "PRINCE MALCHEZAAR" and panel["lines"][0] == "Killed 2 times by the guild.", panel
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.3)
    assert c.eval_py("local p = ns.Azero.pending return p and p.kind") is None
    assert c.eval_py("return ns.AzeroUI._Trophy()") is None
    # an empty plinth reads as one
    c.eval("""local G = ns.Azero
      local px, py
      for k, o in pairs(G.map.object) do if o.boss and o.boss.enc == 652 then px, py = o.x, o.y end end
      G:EnterMap('hideout', px, py + 1, 'up', true)
      G:PressA()""")
    w.tick(0.5)
    panel = c.eval_py("return ns.AzeroUI._Trophy()")
    assert panel["title"] == "ATTUMEN THE HUNTSMAN" and panel["lines"][0] == "An empty plinth.", panel
    c.eval("ns.AzeroUI._HandleKey('B')")
    w.tick(0.3)
    no_errors(w)


@case
def the_statues_name_the_champions_and_the_board_counts_the_bestiary():
    w, c = game()
    c.eval("T_AZ.choice = 1")
    names = c.eval_py("""local G = ns.Azero
      G:EnterMap('hideout', 4, 18, 'down', true)
      local out = {}
      for _, n in ipairs(G.npcs) do if n.def.statue then out[#out + 1] = G.NpcName(n.def) .. ' <' .. G.NpcTitle(n.def) .. '>' end end
      return out""")
    assert names[0] == "Unclaimed <Champion Tamer>" and len(names) == 5, names
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      G.save.caught.wolfpup, G.save.caught.owlet, G.save.caught.kobling = true, true, true
      G.save.party = { M.New('wolfpup', 5, G.rng) }
      ns.AzeroGuild:MarkDirty()""")
    names = c.eval_py("""local G = ns.Azero
      G:EnterMap('hideout', 4, 18, 'down', true)
      local out = {}
      for _, n in ipairs(G.npcs) do if n.def.statue then out[#out + 1] = G.NpcName(n.def) end end
      return out""")
    assert names[0] == "Alice", names
    c.eval("ns.Azero:EnterMap('hideout', 4, 18, 'down', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    assert "The plaque reads: Alice, Champion Tamer." in log(c), log(c)
    c.eval("T_AZ.log = {} ns.Azero:EnterMap('hideout', 25, 18, 'down', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    text = log(c)
    assert "GUILD BESTIARY" in text and "tamed 3 of" in text and "Still wild: " in text, text
    c.eval("T_AZ.log = {} ns.Azero:EnterMap('hideout', 18, 21, 'left', true) ns.Azero:PressA()")
    c.eval("T_AZ.settle()")
    assert "Steward Marlon: Welcome to the guild hall." in log(c), log(c)
    no_errors(w)


@case
def the_raid_log_times_a_kill_from_pull_to_death():
    w, c = game()
    # (no raid session: the encounter is timed on every client, and the record is only written with one)
    c.eval("""local now = GetServerTime()
      ns.db.raidCurrent = 'live'
      ns.db.raids.live = { id = 'live', start = now - 600, zone = 'Karazhan', att = {}, bosses = {} }""")
    c._fire("ENCOUNTER_START", PRINCE, "Prince Malchezaar", 3, 10)
    w.tick(200, step=10)
    c._fire("ENCOUNTER_END", PRINCE, "Prince Malchezaar", 3, 10, 1)
    r = c.eval_py("local b = ns.db.raids.live.bosses[1] return b and { enc = b.enc, dur = b.dur }")
    assert r and r["enc"] == PRINCE and 195 <= r["dur"] <= 205, r
    assert c.eval_py("return ns.AzeroHideout.Trophy(661).first.dur") == r["dur"]
    no_errors(w)


if __name__ == "__main__":
    run_all()

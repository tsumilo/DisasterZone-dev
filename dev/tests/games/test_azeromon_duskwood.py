"""Azeromon: Duskwood.

Covers: the east road from Sentinel Hill stays closed until VanCleef is beaten (Scout Galiaan), then Raven Hill,
the Duskwood road and Darkshire connect both ways on open ground; the zone's look (dark tiles, iron fences,
gravestones, a gloom that never lifts, its battle backdrop) and music; Morbent Fel can't be fought without
Morbent's Bane, which Sven gives once Mor'Ladim rests; Stalvan waits in Manor Mistmantle; Stitches comes to
Darkshire's gate only after the three haunts and gives the Night Watch Seal (badge, achievements, Althea's thanks);
the gryphons between Darkshire and Sentinel Hill; every new beast can be met in the zone and evolves within its
levels.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_duskwood.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

DUSKWOOD_DAY = (53486, 53487, 53488)
HAUNTED = (53234, 53235)


def game(ui=False):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(9)")
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 12")
    c.eval("""local M = ns.AzeroMon
      local a = M.New('flamescale', 45, ns.Azero.rng) a.moves = M.DefaultMoves('flamescale', 45)
      local b = M.New('tidehunter', 45, ns.Azero.rng) b.moves = M.DefaultMoves('tidehunter', 45)
      ns.Azero.save.party = { a, b }
      ns.Azero.save.money = 1000""")
    if ui:
        c.slash("/dz play azeromon")
        w.tick(0.3)
        c.eval("ns.AzeroUI._HandleKey('A')")
        w.tick(0.3)
        c.eval("T_AZ.settle()")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


def where(c):
    return c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }")


def talk(c, map_id, x, y, face):
    c.eval("ns.Azero:EnterMap(%r, %d, %d, %r, true) ns.Azero:PressA()" % (map_id, x, y, face))
    c.eval("T_AZ.settle()")


@case
def the_road_east_opens_after_vancleef():
    w, c = game()
    c.eval("ns.Azero:EnterMap('sentinel', 17, 9, 'right', true)")
    for _ in range(3):
        c.eval("T_AZ.step('right')")
    c.eval("T_AZ.settle()")
    assert where(c)[0] == "sentinel" and where(c)[1] < 19, where(c)
    assert "Scout Galiaan: The road east runs to Duskwood" in log(c), log(c)
    c.eval("ns.Azero:SetFlag('badge_vancleef')")
    for _ in range(4):
        if where(c)[0] == "ravenhill":
            break
        c.eval("T_AZ.step('right')")
    assert where(c) == ["ravenhill", 0, 9], where(c)
    # Gryan and Galiaan point the way now
    talk(c, "sentinel", 11, 7, "up")
    assert "Scout Galiaan will let you through on the east road." in log(c)
    no_errors(w)


@case
def the_duskwood_maps_connect_both_ways_on_open_ground():
    w, c = game()
    bad = c.eval_py("""local G, Maps = ns.Azero, ns.AzeroMaps
      local bad = {}
      local back = { east = "west", west = "east" }
      for _, id in ipairs({ 'sentinel', 'ravenhill', 'duskwood', 'darkshire' }) do
        local m = G.Compile(id)
        for dir, e in pairs(Maps[id].edges or {}) do
          if back[dir] then
            local t = G.Compile(e.map)
            local ret = Maps[e.map].edges and Maps[e.map].edges[back[dir]]
            if not ret or ret.map ~= id or ret.dy ~= -e.dy then bad[#bad + 1] = id .. ' ' .. dir .. ' not mirrored' end
            local x, tx = dir == 'east' and m.w - 1 or 0, dir == 'east' and 0 or t.w - 1
            for y = 0, m.h - 1 do
              if not m.solid[m.key(x, y)] then
                local ty = y + e.dy
                if ty < 0 or ty >= t.h or t.solid[t.key(tx, ty)] then bad[#bad + 1] = id .. ' ' .. dir .. ' y' .. y end
              end
            end
          end
        end
      end
      return bad""")
    assert bad == [], bad
    # and on foot: Raven Hill -> Duskwood -> Darkshire (the road's trainers fight on the way)
    c.eval("ns.Azero:SetFlag('badge_vancleef') ns.Azero:EnterMap('ravenhill', 0, 10, 'right', true)")
    assert c.eval_py("return { T_AZ.walkTo(23, 10) }")[0] is True
    c.eval("T_AZ.step('right')")
    assert where(c) == ["duskwood", 0, 10], where(c)
    assert c.eval_py("return { T_AZ.walkTo(27, 10) }")[0] is True
    c.eval("T_AZ.step('right')")
    assert where(c) == ["darkshire", 0, 10], where(c)
    assert c.eval("return ns.Azero:Flag('beat_nightblade') and ns.Azero:Flag('beat_dodds') and true or false")
    no_errors(w)


@case
def duskwood_looks_and_sounds_like_duskwood():
    w, c = game(ui=True)
    r = c.eval_py("""local G = ns.Azero
      local m = G.Compile('ravenhill')
      local o = {}
      o.grass = m.base[m.key(1, 1)]
      o.fence = m.over[m.key(3, 13)]
      o.grave = m.over[m.key(4, 14)]
      o.tree = m.over[m.key(0, 0)]
      o.solid = m.solid[m.key(4, 14)] == true
      local d = G.Compile('darkshire')
      o.lamp = d.over[d.key(2, 8)]
      return o""")
    assert r == {"grass": r["grass"], "fence": "ironfence", "grave": "gravestone", "tree": "dtree", "solid": True,
                 "lamp": "lamppost"} and r["grass"].startswith("dgrass"), r
    c.eval("ns.Azero:EnterMap('ravenhill', 1, 9, 'right', true)")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._SkyAlpha()") >= 0.3            # noon, and still dusk
    assert c.eval("return __MOCK.music") in DUSKWOOD_DAY
    c.eval("ns.Azero:EnterMap('route1', 11, 20, 'up', true)")
    w.tick(0.1)
    assert c.eval("return ns.AzeroUI._SkyAlpha()") == 0              # Elwynn at noon: clear
    c.eval("ns.Azero:EnterMap('mistmantle', 4, 6, 'up', true)")
    w.tick(0.1)
    assert c.eval("return __MOCK.music") in HAUNTED
    no_errors(w)


@case
def morbent_fel_needs_his_bane():
    w, c = game()
    talk(c, "duskwood", 10, 18, "right")
    assert "Morbent Fel: Ha! Your beasts' blows pass right through me." in log(c), log(c)
    assert c.eval("return ns.Azero:Flag('beat_morbentfel')") is None
    assert c.eval("return T_AZ.battles") is None
    # Sven won't part with the Bane while Mor'Ladim walks
    talk(c, "ravenhill", 18, 4, "right")
    assert "not while Mor'Ladim walks the cemetery" in log(c) and c.eval("return ns.Azero:Flag('morbentbane')") is None
    talk(c, "ravenhill", 11, 15, "down")                            # Mor'Ladim
    assert c.eval("return ns.Azero:Flag('beat_morladim')") is True
    assert "Mor'Ladim sinks back into his grave." in log(c)
    talk(c, "ravenhill", 18, 4, "right")
    assert "Alice received Morbent's Bane!" in log(c) and c.eval("return ns.Azero:Flag('morbentbane')") is True
    talk(c, "duskwood", 10, 18, "right")
    assert c.eval("return ns.Azero:Flag('beat_morbentfel')") is True
    assert "Morbent Fel's shadows scatter to the wind." in log(c)
    assert c.eval("return ns.AzeroAch.Earned().haunts == nil")         # two of three
    no_errors(w)


@case
def stalvan_waits_in_manor_mistmantle():
    w, c = game()
    c.eval("ns.Azero:EnterMap('duskwood', 22, 8, 'up', true)")
    assert c.eval_py("return { T_AZ.walkTo(22, 6) }")[0] is True
    assert where(c) == ["mistmantle", 4, 6], where(c)
    c.eval("T_AZ.step('up')")                                       # he sees you
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.Azero:Flag('beat_stalvan')") is True
    assert "Stalvan fades into the manor's dust." in log(c), log(c)
    no_errors(w)


@case
def stitches_comes_after_the_haunts_and_gives_the_seal():
    w, c = game()
    c.eval("ns.Azero:EnterMap('darkshire', 1, 10, 'right', true)")
    hidden = "for _, n in ipairs(ns.Azero.npcs) do if n.id == 'stitches' then return n.hidden and true or false end end"
    assert c.eval(hidden) is True
    talk(c, "darkshire", 18, 9, "up")                                # Althea: what's left
    assert "Still out there: Mor'Ladim in the Raven Hill cemetery; Morbent Fel on the Yorgen farm;" in log(c), log(c)
    c.eval("for _, id in ipairs({ 'morladim', 'morbentfel', 'stalvan' }) do ns.Azero:SetFlag('beat_' .. id) end")
    c.eval("ns.Azero:EnterMap('darkshire', 1, 10, 'right', true)")
    assert c.eval(hidden) is False
    c.eval("T_AZ.step('up')")                                       # onto the road: Stitches sees you
    c.eval("T_AZ.settle()")
    assert c.eval("return ns.Azero:Flag('beat_stitches') and ns.Azero:Flag('badge_nightwatch') and true or false")
    text = log(c)
    assert "Alice received Night Watch Seal!" in text and "Stitches falls apart at the seams." in text, text
    earned = c.eval_py("local e = ns.AzeroAch.Earned() return { e.haunts ~= nil, e.nightwatch ~= nil }")
    assert earned == [True, True], earned
    assert c.eval("return ns.Azero:BadgeCount()") == 1              # (the earlier badges were never earned here)
    talk(c, "darkshire", 18, 9, "up")
    assert "Watcher Alice. It has a ring to it." in log(c)
    no_errors(w)


@case
def gryphons_link_darkshire_and_sentinel_hill():
    w, c = game()
    c.eval("T_AZ.choice = 1")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: learn the route, fly west
    assert where(c)[0] == "sentinel" and c.eval("return ns.Azero.save.money") == 970
    assert c.eval("return ns.Azero:Flag('fp_darkshire')") is True
    c.eval("T_AZ.choice = 2")
    talk(c, "sentinel", 17, 4, "right")                              # Thor: now Darkshire too
    assert where(c) == ["darkshire", 17, 14] and c.eval("return ns.Azero.save.money") == 940, where(c)
    no_errors(w)


@case
def every_new_beast_lives_in_the_zone():
    w, c = game()
    r = c.eval_py("""local D, Maps = ns.AzeroData, ns.AzeroMaps
      local met = {}
      for _, id in ipairs({ 'ravenhill', 'duskwood' }) do
        for _, e in ipairs(Maps[id].encounters) do met[e.sp] = true end
      end
      for id in pairs(met) do local evo = D.species[id].evolve if evo then met[evo.into] = true end end
      local out = { missing = {}, late = {}, bosses = {} }
      for id, s in pairs(D.species) do
        if s.num >= 47 and s.num <= 63 then           -- (64 on: the level 100 chains and Stranglethorn)
          if s.boss then out.bosses[#out.bosses + 1] = id
          elseif not met[id] then out.missing[#out.missing + 1] = id end
          -- a Duskwood beast's first evolution comes in the zone; the later forms (num > 63) come after
          if s.evolve and s.evolve.level and s.evolve.level > 32 and D.species[s.evolve.into].num <= 63 then
            out.late[#out.late + 1] = id
          end
        end
      end
      table.sort(out.bosses)
      return out""")
    assert r["missing"] == [] and r["late"] == [], r
    assert r["bosses"] == ["morbentfel", "morladim", "stalvan", "stitches"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()

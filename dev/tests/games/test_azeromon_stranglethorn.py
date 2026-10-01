"""Azeromon: Stranglethorn Vale.

Covers: the road south from Darkshire stays closed until the Night Watch Seal; the vale's maps connect end to end
on open ground (Rebel Camp to Booty Bay, the arena on the road, the caves and the isle); the jungle look and
music; Nesingwary's hunt (the three hunters, then King Bangalash shows himself, then Hemet and his Trophy); the
Bloodsail chain (the captains, then Firallon on his ship and the Blackwater Seal, the Baron's thanks); gryphons
between Booty Bay and Darkshire and the boat to Jaguero Isle; every new beast can be met in the zone; the level
100 chains.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_stranglethorn.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

ROAD = ["rebelcamp", "stvnorth", "zulmamwe", "arena", "stvsouth", "wildshore", "bootybay"]


def game(level=70):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(9)")
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 12")
    c.eval("""local M = ns.AzeroMon
      local a = M.New('emberancient', %d, ns.Azero.rng) a.moves = M.DefaultMoves('emberancient', %d)
      local b = M.New('tidelord', %d, ns.Azero.rng) b.moves = M.DefaultMoves('tidelord', %d)
      ns.Azero.save.party = { a, b }
      ns.Azero.save.money = 1000""" % (level, level, level, level))
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


def where(c):
    return c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }")


def talk(c, map_id, x, y, face):
    c.eval("ns.Azero:EnterMap(%r, %d, %d, %r, true) ns.Azero:PressA()" % (map_id, x, y, face))
    c.eval("T_AZ.settle()")


def npc_hidden(c, map_id, npc):
    return c.eval_py("""ns.Azero:EnterMap(%r, 1, 1, 'down', true)
      for _, n in ipairs(ns.Azero.npcs) do if n.id == %r then return n.hidden == true end end
      return 'no such npc'""" % (map_id, npc))


@case
def the_road_south_opens_with_the_night_watch_seal():
    w, c = game()
    c.eval("ns.Azero:EnterMap('darkshire', 11, 17, 'down', true)")
    c.eval("T_AZ.step('down')")
    c.eval("T_AZ.settle()")
    assert where(c)[0] == "darkshire" and where(c)[2] <= 17, where(c)
    assert "Night Watch Guard: The road south runs into Stranglethorn Vale" in log(c), log(c)
    c.eval("ns.Azero:SetFlag('badge_nightwatch')")
    for _ in range(4):
        if where(c)[0] == "rebelcamp":
            break
        c.eval("T_AZ.step('down')")
    assert where(c) == ["rebelcamp", 11, 0], where(c)
    # and back north
    c.eval("T_AZ.step('up')")
    assert where(c) == ["darkshire", 11, 19], where(c)
    no_errors(w)


@case
def the_vale_connects_end_to_end_on_open_ground():
    w, c = game()
    # south along the road, one edge at a time
    c.eval("ns.Azero:EnterMap('rebelcamp', 11, 0, 'down', true)")
    seen = ["rebelcamp"]
    for i, nxt in enumerate(ROAD[1:]):
        # find the road tile on the bottom row and jump there (the road's own walk is covered by the map test)
        exit_x = c.eval_py("""local m = ns.Azero.map
          for x = 0, m.w - 1 do
            if not m.solid[m.key(x, m.h - 1)] and m.def.edges and m.def.edges.south then return x end
          end""")
        assert exit_x is not None, (seen, "no south exit")
        c.eval("ns.Azero:EnterMap(ns.Azero.save.map, %d, ns.Azero.map.h - 1, 'down', true)" % exit_x)
        c.eval("T_AZ.step('down')")
        assert where(c)[0] == nxt and where(c)[2] == 0, (seen, where(c))
        solid = c.eval_py("local m, s = ns.Azero.map, ns.Azero.save return m.solid[m.key(s.x, s.y)] == true")
        assert solid is False, (nxt, where(c))
        seen.append(nxt)
        # and straight back north lands on open ground too
        c.eval("T_AZ.step('up')")
        assert where(c)[0] == seen[-2], (seen, where(c))
        back_solid = c.eval_py("local m, s = ns.Azero.map, ns.Azero.save return m.solid[m.key(s.x, s.y)] == true")
        assert back_solid is False, (seen[-2], where(c))
        c.eval("T_AZ.step('down')")
    assert seen == ROAD, seen
    # the caves and the isle: every warp lands on open ground (checked by the data test); the isle by boat
    c.eval("T_AZ.choice = 1")
    talk(c, "bootybay", 12, 18, "down")                              # Skipper Zinkle
    assert where(c) == ["jaguero", 4, 14] and c.eval("return ns.Azero.save.money") == 800, where(c)
    talk(c, "jaguero", 4, 14, "left")                                # and back
    assert where(c) == ["bootybay", 12, 18], where(c)
    no_errors(w)


@case
def the_jungle_has_its_own_look_and_music():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      local m = G.Compile('stvnorth')
      local base, tree = m.base[m.key(1, 1)], m.over[m.key(0, 0)]
      local ruin = m.base[m.key(3, 22)]
      local shore = m.tall[m.key(17, 8)]
      local bb = G.Compile('bootybay')
      return { base = base, tree = tree, ruin = ruin, shore = shore, music = ns.AzeroMaps.stvnorth.music,
               deck = bb.base[bb.key(10, 17)], water = bb.water[bb.key(2, 18)] == true,
               house = bb.over[bb.key(2, 1)], door = bb.solid[bb.key(5, 6)] ~= true,
               hut = G.Compile('zulmamwe').over[G.Compile('zulmamwe').key(4, 5)],
               hutdoor = G.Compile('zulmamwe').solid[G.Compile('zulmamwe').key(4, 5)] ~= true,
               platform = ns.AzeroAtlas and ns.AzeroAtlas.jgrass1 ~= nil }""")
    assert r["base"] in ("jgrass1", "jgrass2") and r["tree"] == "jtree", r
    assert r["ruin"] == "ruinwall" and r["shore"] == "coast" and r["music"] == "arena", r
    assert r["deck"] == "deck" and r["water"] and r["house"] == "bbhouse_0_0" and r["door"], r
    assert r["hut"] == "hut_1_2" and r["hutdoor"] and r["platform"], r
    no_errors(w)


@case
def nesingwarys_hunt_ends_with_the_trophy():
    w, c = game()
    c.eval("T_AZ.choice = 1")
    talk(c, "stvnorth", 5, 5, "up")                                  # Hemet: not yet
    assert "Nesingwary's rule" in log(c), log(c)
    assert npc_hidden(c, "stvnorth", "bangalash") is True
    for t in ("ajeck", "erlgadin", "barnil"):
        c.eval("ns.Azero:SetFlag('beat_%s')" % t)
    assert npc_hidden(c, "stvnorth", "bangalash") is False
    c.eval("T_AZ.log = {}")
    talk(c, "stvnorth", 21, 22, "right")                             # King Bangalash
    assert "The great white tiger steps from the trees" in log(c), log(c)
    assert c.eval("return ns.Azero:Flag('beat_bangalash') and true or false"), log(c)[-800:]
    assert npc_hidden(c, "stvnorth", "bangalash") is True             # he leaves
    assert c.eval_py("return ns.AzeroAch.Earned().bangalash ~= nil")
    c.eval("T_AZ.log = {}")
    talk(c, "stvnorth", 5, 5, "up")                                  # Hemet, for the Trophy
    assert "Alice received Nesingwary's Trophy!" in log(c), log(c)[-1200:]
    assert c.eval("return ns.Azero:Flag('badge_nesingwary') and true or false")
    assert c.eval_py("return ns.AzeroAch.Earned().nesingwary ~= nil")
    no_errors(w)


@case
def the_bloodsail_captains_then_firallon_give_the_blackwater_seal():
    w, c = game()
    c.eval("T_AZ.choice = 1")
    talk(c, "bbhall", 4, 4, "up")                                    # the Baron points at the camp
    assert "His captains, Keelhaul and Stillwater" in log(c), log(c)
    c.eval("T_AZ.log = {}")
    talk(c, "wildshore", 19, 14, "right")                            # Firallon: not yet
    assert "My captains first, tamer." in log(c), log(c)
    assert c.eval("return ns.Azero:Flag('beat_firallon')") is None
    c.eval("ns.Azero:SetFlag('beat_keelhaul') ns.Azero:SetFlag('beat_stillwater')")
    c.eval("T_AZ.log = {}")
    talk(c, "bbhall", 4, 4, "up")
    assert "Firallon has nobody left to hide behind" in log(c), log(c)
    c.eval("T_AZ.log = {}")
    talk(c, "wildshore", 19, 14, "right")
    assert "Alice received Blackwater Seal!" in log(c) and "Booty Bay's bells ring out!" in log(c), log(c)[-1500:]
    assert npc_hidden(c, "wildshore", "firallon") is True
    assert c.eval_py("return ns.AzeroAch.Earned().blackwater ~= nil")
    assert c.eval("return ns.Azero:BadgeCount()") == 1
    c.eval("T_AZ.log = {}")
    talk(c, "bbhall", 4, 4, "up")
    assert "You have finished Stranglethorn Vale." in log(c), log(c)
    talk(c, "bootybay", 13, 18, "right")                             # the dockhand
    assert "The Bloodsail fleet turned tail!" in log(c), log(c)
    no_errors(w)


@case
def gryphons_link_booty_bay_and_darkshire():
    w, c = game()
    c.eval("T_AZ.choice = 2")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: no Booty Bay option yet (2 = Stay)
    assert where(c)[0] == "darkshire" and "Mind the dark, then." in log(c), (where(c), log(c))
    c.eval("T_AZ.choice = 1")
    talk(c, "bootybay", 4, 8, "left")                                # Gringer: learn the route, fly north
    assert where(c) == ["darkshire", 17, 14] and c.eval("return ns.Azero.save.money") == 960, where(c)
    assert c.eval("return ns.Azero:Flag('fp_bootybay')") is True
    c.eval("T_AZ.choice = 2")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: Booty Bay is the second option now
    assert where(c) == ["bootybay", 3, 9] and c.eval("return ns.Azero.save.money") == 920, where(c)
    shown = c.eval_py("local W = ns.AzeroWorld return W.FlightShown(W.FLIGHTS[3])")
    assert shown is True
    no_errors(w)


@case
def every_new_beast_lives_in_the_vale_and_the_chains_reach_four_forms():
    w, c = game()
    r = c.eval_py("""local D, Maps = ns.AzeroData, ns.AzeroMaps
      local met = {}
      for _, id in ipairs({ 'rebelcamp', 'kurzen', 'stvnorth', 'zulmamwe', 'moshogg', 'stvsouth', 'crystalvein',
                            'wildshore', 'jaguero' }) do
        for _, e in ipairs(Maps[id].encounters or {}) do met[e.sp] = true end
        for _, e in ipairs(Maps[id].coastEncounters or {}) do met[e.sp] = true end
      end
      for _ = 1, 4 do
        for id in pairs(met) do local evo = D.species[id].evolve if evo then met[evo.into] = true end end
      end
      local out = { missing = {}, bosses = {}, chains = {}, rares = {} }
      for id, s in pairs(D.species) do
        if s.num >= 96 then
          if s.boss then out.bosses[#out.bosses + 1] = id
          elseif s.rare then out.rares[#out.rares + 1] = id
          elseif not met[id] then out.missing[#out.missing + 1] = id end
        end
      end
      -- chain lengths from every first form
      local pre = {}
      for id, s in pairs(D.species) do if s.evolve then pre[s.evolve.into] = true end end
      for id, s in pairs(D.species) do
        if not pre[id] and s.evolve then
          local n, cur, top = 1, id, 0
          while D.species[cur].evolve do
            local e = D.species[cur].evolve
            top = math.max(top, e.level or 0)
            cur = e.into n = n + 1
          end
          out.chains[#out.chains + 1] = { id, n, top }
        end
      end
      table.sort(out.bosses) table.sort(out.rares)
      table.sort(out.chains, function(a, b) return a[1] < b[1] end)
      return out""")
    assert r["missing"] == [], r
    assert r["bosses"] == ["bangalash", "firallon", "ganzulah", "kurzen", "maizoth", "mukla", "zanzil"], r
    assert r["rares"] == ["bhagthera", "tethis"], r
    chains = {ch[0]: (ch[1], ch[2]) for ch in r["chains"]}
    for first in ("emberwhelp", "murkling", "lashling", "wolfpup", "webling", "owlet", "rustgolem", "flesheater",
                  "darkrunner", "tigercub", "pantherkit", "raptorling"):
        assert chains[first][0] == 4, (first, chains[first])
    assert all(top <= 100 for _, top in chains.values()), chains
    four = sum(1 for n, _ in chains.values() if n == 4)
    assert four >= 12 and c.eval("return ns.AzeroData.MAX_LEVEL") == 100, (four, chains)
    no_errors(w)


@case
def a_beast_far_past_its_thresholds_climbs_its_whole_chain():
    w, c = game()
    c.eval("""local G, M = ns.Azero, ns.AzeroMon
      local m = M.New('tigercub', 50, G.rng) m.moves = M.DefaultMoves('tigercub', 50)
      G.save.party = { m }
      G:Run(function(g) g:Evolutions() end)""")
    c.eval("T_AZ.settle()")
    r = c.eval_py("local G = ns.Azero return { sp = G.save.party[1].sp, seen = G.save.seen.eldertiger == true }")
    assert r["sp"] == "eldertiger" and r["seen"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()

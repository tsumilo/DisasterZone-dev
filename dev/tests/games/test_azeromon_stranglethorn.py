"""Azeromon: Stranglethorn Vale.

Covers: the road south from Darkshire stays closed until the Night Watch Seal; the vale's maps connect end to end
on open ground (Rebel Camp to Booty Bay, the arena on the road, the caves and the isle); the jungle look and
music; Nesingwary's hunt (the three hunters, then King Bangalash shows himself, then Hemet and his Trophy); the
Bloodsail chain (the captains, then Firallon on his ship and the Blackwater Seal, the Baron's thanks); gryphons
between Booty Bay and Darkshire and the boat to Jaguero Isle; every new beast can be met in the zone; the level
100 chains.
The redrawn vale (0.48, organic like Blackrock): every map compiles on atlas tiles at revision 2; every edge is
reciprocal and lands on open ground both ways (Darkshire's south road and the arena's gates too); every door and
ladder lands on open ground and leads back where it came from; every NPC, sign, object, chest and gather node can be
reached; Booty Bay's houses stand round the harbour; an old save standing in the vale moves to its nearest road.

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
    assert where(c) == ["rebelcamp", 14, 0], where(c)
    # and back north
    c.eval("T_AZ.step('up')")
    assert where(c) == ["darkshire", 11, 19], where(c)
    no_errors(w)


@case
def the_vale_connects_end_to_end_on_open_ground():
    w, c = game()
    c.eval("ns.Azero:SetFlag('badge_nightwatch')")                 # (the arena's roads open with the Night Watch)
    # south along the road, one edge at a time
    c.eval("ns.Azero:EnterMap('rebelcamp', 14, 0, 'down', true)")
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
    talk(c, "bootybay", 24, 19, "down")                              # Skipper Zinkle, at the east pier's end
    assert where(c) == ["jaguero", 4, 16] and c.eval("return ns.Azero.save.money") == 800, where(c)
    talk(c, "jaguero", 4, 16, "up")                                  # and back, from the jetty
    assert where(c) == ["bootybay", 24, 19], where(c)
    no_errors(w)


@case
def the_jungle_has_its_own_look_and_music():
    w, c = game()
    r = c.eval_py("""local G = ns.Azero
      local m = G.Compile('stvnorth')
      local base, tree = m.base[m.key(1, 1)], m.over[m.key(0, 0)]
      local ruin = m.base[m.key(3, 22)]
      local shore = m.tall[m.key(21, 5)]
      local bb = G.Compile('bootybay')
      return { base = base, tree = tree, ruin = ruin, shore = shore, music = ns.AzeroMaps.stvnorth.music,
               deck = bb.base[bb.key(8, 16)], water = bb.water[bb.key(10, 16)] == true,
               house = bb.over[bb.key(6, 6)], door = bb.solid[bb.key(9, 11)] ~= true,
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
    talk(c, "stvnorth", 6, 5, "up")                                  # Hemet: not yet
    assert "Nesingwary's rule" in log(c), log(c)
    assert npc_hidden(c, "stvnorth", "bangalash") is True
    for t in ("ajeck", "erlgadin", "barnil"):
        c.eval("ns.Azero:SetFlag('beat_%s')" % t)
    assert npc_hidden(c, "stvnorth", "bangalash") is False
    c.eval("T_AZ.log = {}")
    talk(c, "stvnorth", 27, 25, "right")                             # King Bangalash, in his hollow
    assert "The great white tiger steps from the trees" in log(c), log(c)
    assert c.eval("return ns.Azero:Flag('beat_bangalash') and true or false"), log(c)[-800:]
    assert npc_hidden(c, "stvnorth", "bangalash") is True             # he leaves
    assert c.eval_py("return ns.AzeroAch.Earned().bangalash ~= nil")
    c.eval("T_AZ.log = {}")
    talk(c, "stvnorth", 6, 5, "up")                                  # Hemet, for the Trophy
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
    talk(c, "wildshore", 26, 14, "right")                            # Firallon: not yet
    assert "My captains first, tamer." in log(c), log(c)
    assert c.eval("return ns.Azero:Flag('beat_firallon')") is None
    c.eval("ns.Azero:SetFlag('beat_keelhaul') ns.Azero:SetFlag('beat_stillwater')")
    c.eval("T_AZ.log = {}")
    talk(c, "bbhall", 4, 4, "up")
    assert "Firallon has nobody left to hide behind" in log(c), log(c)
    c.eval("T_AZ.log = {}")
    talk(c, "wildshore", 26, 14, "right")
    assert "Alice received Blackwater Seal!" in log(c) and "Booty Bay's bells ring out!" in log(c), log(c)[-1500:]
    assert npc_hidden(c, "wildshore", "firallon") is True
    assert c.eval_py("return ns.AzeroAch.Earned().blackwater ~= nil")
    assert c.eval("return ns.Azero:BadgeCount()") == 1
    c.eval("T_AZ.log = {}")
    talk(c, "bbhall", 4, 4, "up")
    assert "You have finished Stranglethorn Vale." in log(c), log(c)
    c.eval("ns.Azero.clockHour = 7 + 10 / 60")                       # the dockhand starts his pier round at (23, 12)
    talk(c, "bootybay", 23, 13, "up")
    assert "The Bloodsail fleet turned tail!" in log(c), log(c)
    no_errors(w)


@case
def gryphons_link_booty_bay_and_darkshire():
    w, c = game()
    c.eval("T_AZ.choice = 2")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: no Booty Bay option yet (2 = Stay)
    assert where(c)[0] == "darkshire" and "Mind the dark, then." in log(c), (where(c), log(c))
    c.eval("T_AZ.choice = 1")
    talk(c, "bootybay", 22, 5, "right")                              # Gringer: learn the route, fly north
    assert where(c) == ["darkshire", 17, 14] and c.eval("return ns.Azero.save.money") == 960, where(c)
    assert c.eval("return ns.Azero:Flag('fp_bootybay')") is True
    c.eval("T_AZ.choice = 2")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: Booty Bay is the second option now
    assert where(c) == ["bootybay", 22, 5] and c.eval("return ns.Azero.save.money") == 920, where(c)   # by Gringer
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
        if s.num >= 96 and s.num <= 130 then          -- (Blackrock: test_azeromon_blackrock_beasts.py)
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


VALE = ["rebelcamp", "kurzen", "stvnorth", "zulmamwe", "moshogg", "stvsouth", "crystalvein", "wildshore", "bootybay",
        "bootybayinn", "bbhall", "jaguero"]
OPP = {"north": "south", "south": "north", "east": "west", "west": "east"}
DIR = {"north": "up", "south": "down", "east": "right", "west": "left"}


def lua_list(ids):
    return "{ '" + "', '".join(ids) + "' }"


@case
def the_redrawn_maps_compile_on_atlas_tiles_at_revision_two():
    w, c = game()
    r = c.eval_py(r"""local G, A, Maps = ns.Azero, ns.AzeroAtlas, ns.AzeroMaps
      local bad, revs = {}, {}
      for _, id in ipairs(%s) do
        local def = Maps[id]
        local m = G.Compile(id)
        if not m then bad[#bad + 1] = id .. ' does not compile' else
          for i, r in ipairs(def.rows) do if #r ~= #def.rows[1] then bad[#bad + 1] = id .. ' row ' .. i end end
          for _, name in pairs(m.base) do if not A[name] then bad[#bad + 1] = id .. ' base ' .. name end end
          for _, name in pairs(m.over) do if type(name) == 'string' and not A[name] then bad[#bad + 1] = id .. ' over ' .. name end end
          if G.STV_REDRAWN[id] then revs[#revs + 1] = def.rev end
        end
      end
      return { bad = bad, revs = revs }""" % lua_list(VALE))
    assert r["bad"] == [], r["bad"]
    assert r["revs"] == [2] * 10, r["revs"]
    no_errors(w)


@case
def edges_are_reciprocal_and_land_on_open_ground_both_ways():
    w, c = game()
    c.eval("ns.Azero:SetFlag('badge_nightwatch')")
    edges = c.eval_py(r"""local out = {}
      for _, id in ipairs({ 'darkshire', 'rebelcamp', 'stvnorth', 'zulmamwe', 'arena', 'stvsouth', 'wildshore', 'bootybay' }) do
        for side, e in pairs(ns.AzeroMaps[id].edges or {}) do out[#out + 1] = { id, side, e.map } end
      end
      return out""")
    checked = 0
    for mid, side, target in edges:
        if mid == "darkshire" and side != "south":
            continue
        back = c.eval_py("local e = ns.AzeroMaps[%r].edges return e and e[%r] and e[%r].map" % (target, OPP[side], OPP[side]))
        assert back == mid, (mid, side, target, back)
        cells = c.eval_py(r"""local m = ns.Azero.Compile(%r)
          local side, out = %r, {}
          for i = 0, (side == 'north' or side == 'south') and m.w - 1 or m.h - 1 do
            local x = (side == 'west') and 0 or (side == 'east') and m.w - 1 or i
            local y = (side == 'north') and 0 or (side == 'south') and m.h - 1 or i
            if not m.solid[m.key(x, y)] then out[#out + 1] = { x, y } end
          end
          return out""" % (mid, side))
        assert cells, (mid, side, "no open tile on the edge")
        for x, y in cells:
            c.eval("ns.Azero:EnterMap(%r, %d, %d, %r, true)" % (mid, x, y, DIR[side]))
            c.eval("T_AZ.step(%r)" % DIR[side])
            at = where(c)
            assert at[0] == target, (mid, side, x, y, at)
            exp = c.eval_py(r"""local e, m = ns.AzeroMaps[%r].edges[%r], ns.Azero.Compile(%r)
              local x, y = %d, %d
              if %r == 'north' or %r == 'south' then return { x + (e.dx or 0), (%r == 'north') and m.h - 1 or 0 } end
              return { (%r == 'west') and m.w - 1 or 0, y + (e.dy or 0) }""" % (mid, side, target, x, y, side, side, side, side))
            assert at[1:] == exp, ("lands off the road", mid, side, (x, y), at, exp)
            assert c.eval("local m, s = ns.Azero.map, ns.Azero.save return m.solid[m.key(s.x, s.y)] == true") is False, at
            c.eval("T_AZ.step(%r)" % DIR[OPP[side]])
            assert where(c) == [mid, x, y], ("not back where it left", mid, side, (x, y), where(c))
            checked += 1
    assert checked >= 28, checked
    no_errors(w)


@case
def every_door_and_ladder_lands_on_open_ground_and_leads_back():
    w, c = game()
    bad = c.eval_py(r"""local G, out = ns.Azero, {}
      for _, id in ipairs(%s) do
        local m = G.Compile(id)
        for _, wp in ipairs(m.def.warps or {}) do
          local t = G.Compile(wp.map)
          if not t then out[#out + 1] = id .. ' warp to ' .. wp.map
          elseif t.solid[t.key(wp.tx, wp.ty)] or t.warp[t.key(wp.tx, wp.ty)] then out[#out + 1] = id .. ' -> ' .. wp.map .. ' lands badly' end
          if m.solid[m.key(wp.x, wp.y)] then out[#out + 1] = id .. ' warp tile solid ' .. wp.x .. ',' .. wp.y end
        end
      end
      return out""" % lua_list(VALE))
    assert bad == [], bad
    # walk through each one and straight back: out lands beside the door / ladder it came through
    trips = c.eval_py(r"""local out = {}
      for _, id in ipairs({ 'rebelcamp', 'zulmamwe', 'stvsouth', 'bootybay' }) do
        for _, wp in ipairs(ns.AzeroMaps[id].warps) do out[#out + 1] = { id, wp.x, wp.y, wp.map } end
      end
      return out""")
    assert len(trips) == 5, trips
    back = {"up": "down", "down": "up", "left": "right", "right": "left"}
    for mid, x, y, target in trips:
        c.eval("ns.Azero:EnterMap(%r, %d, %d + 1, 'up', true)" % (mid, x, y))
        c.eval("T_AZ.step('up')")
        inside = where(c)
        assert inside[0] == target, (mid, x, y, inside)
        # the way out: the inside warp leading back to this map, stepped onto from where we landed
        out = c.eval_py(r"""local s = ns.Azero.save
          for _, wp in ipairs(ns.AzeroMaps[s.map].warps) do
            if wp.map == %r then
              local dx, dy = wp.x - s.x, wp.y - s.y
              return { (dx > 0 and 'right') or (dx < 0 and 'left') or (dy > 0 and 'down') or 'up', math.abs(dx) + math.abs(dy) }
            end
          end""" % mid)
        assert out and out[1] == 1, (mid, inside, out)
        c.eval("T_AZ.step(%r)" % out[0])
        assert where(c) == [mid, x, y + 1], ("not back by the door", mid, (x, y), where(c))
    no_errors(w)


@case
def every_npc_sign_object_chest_and_node_can_be_reached():
    w, c = game()
    bad = c.eval_py(r"""local G, out = ns.Azero, {}
      for _, id in ipairs(%s) do
        local m = G.Compile(id)
        local def, block = m.def, {}
        for _, n in ipairs(def.npcs or {}) do
          block[m.key(n.x, n.y)] = true
          if m.solid[m.key(n.x, n.y)] then out[#out + 1] = id .. ' npc on a wall ' .. n.id end
        end
        for kind, spots in pairs(def.nodes or {}) do
          for _, p in ipairs(spots) do
            block[m.key(p[1], p[2])] = true
            if m.solid[m.key(p[1], p[2])] then out[#out + 1] = id .. ' node on a wall ' .. p[1] .. ',' .. p[2] end
          end
        end
        local open = function(x, y) return x >= 0 and y >= 0 and x < m.w and y < m.h and not m.solid[m.key(x, y)] and not block[m.key(x, y)] end
        local seen, st = {}, {}
        local function push(x, y) if open(x, y) and not seen[m.key(x, y)] then seen[m.key(x, y)] = true st[#st + 1] = { x, y } end end
        for x = 0, m.w - 1 do push(x, 0) push(x, m.h - 1) end
        for y = 0, m.h - 1 do push(0, y) push(m.w - 1, y) end
        for _, wp in ipairs(def.warps or {}) do push(wp.x, wp.y) end
        -- arrivals by warp, boat or gryphon count as starts too
        for _, d in pairs(ns.AzeroMaps) do
          if type(d) == 'table' then for _, wp in ipairs(d.warps or {}) do if wp.map == id then push(wp.tx, wp.ty) end end end
        end
        if id == 'jaguero' then push(4, 16) end
        while #st > 0 do
          local p = table.remove(st)
          push(p[1] + 1, p[2]) push(p[1] - 1, p[2]) push(p[1], p[2] + 1) push(p[1], p[2] - 1)
        end
        local function near(x, y)
          for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do if seen[m.key(x + d[1], y + d[2])] then return true end end
        end
        local things = {}
        for _, n in ipairs(def.npcs or {}) do things[#things + 1] = { 'npc ' .. n.id, n.x, n.y } end
        for _, s in ipairs(def.signs or {}) do things[#things + 1] = { 'sign', s.x, s.y } end
        for _, o in ipairs(def.objects or {}) do things[#things + 1] = { 'object ' .. tostring(o.tile), o.x, o.y } end
        for _, ch in ipairs(def.chests or {}) do things[#things + 1] = { 'chest ' .. ch.id, ch.x, ch.y } end
        for _, spots in pairs(def.nodes or {}) do for _, p in ipairs(spots) do things[#things + 1] = { 'node', p[1], p[2] } end end
        for _, t in ipairs(things) do
          if not near(t[2], t[3]) then out[#out + 1] = id .. ' ' .. t[1] .. ' unreachable at ' .. t[2] .. ',' .. t[3] end
        end
      end
      return out""" % lua_list(VALE))
    assert bad == [], bad
    no_errors(w)


@case
def booty_bays_houses_stand_round_the_harbour():
    w, c = game()
    r = c.eval_py(r"""local m = ns.Azero.Compile('bootybay')
      local cx, cy, n = 0, 0, 0
      for k in pairs(m.water) do
        local x, y = k % m.w, math.floor(k / m.w)
        if y < 22 then cx, cy, n = cx + x, cy + y, n + 1 end       -- the harbour, not the sea past its mouth
      end
      cx, cy = cx / n, cy / n
      local out = {}
      for _, st in ipairs(m.def.stamps) do
        if st.kind == 'bbhouse' then out[#out + 1] = { st.x + 2.5 - cx, st.y + 3 - cy, st.inn or '' } end
      end
      return out""")
    assert len(r) == 4, r
    west = [h for h in r if h[0] < -5]
    east = [h for h in r if h[0] > 5]
    assert len(west) == 2 and len(east) == 2, r                      # two each side of the water, not a row
    assert any(h[2] == "bootybayinn" for h in west), r                # the Salty Sailor on the west side
    no_errors(w)


@case
def an_old_save_in_the_vale_moves_to_the_nearest_road():
    """Saves from before the redraw (v 3): a spot on the old maps goes to the new map's nearest road, a cave's to the
    foot of its ladder; the Rebel Camp's revive point moves to Brother Nimetz's fire; a gathered node that is no
    longer there is forgotten (one still there, and any elsewhere, are kept)."""
    _, c = solo("Alice", tick=2)
    r = c.eval_py(r"""local G = ns.Azero
      local out = {}
      for _, case in ipairs({
          { map = 'rebelcamp', x = 20, y = 9, respawn = { map = 'rebelcamp', x = 20, y = 9, face = 'up' } },
          { map = 'bootybay', x = 3, y = 9 },
          { map = 'kurzen', x = 12, y = 12 },
          { map = 'jaguero', x = 10, y = 3 },
          { map = 'stvnorth', x = 25, y = 9, respawn = { map = 'bootybayinn', x = 4, y = 5, face = 'up' } },
        }) do
        G:Data().save = { v = 3, map = case.map, x = case.x, y = case.y, face = 'down', party = {},
                          flags = { starter = 'murkling' }, respawn = case.respawn }
        G:Load()
        local s, m = G.save, G.map
        local ch = m.def.rows[s.y + 1]:sub(s.x + 1, s.x + 1)
        out[#out + 1] = { map = s.map, x = s.x, y = s.y, v = s.v, ch = ch, solid = m.solid[m.key(s.x, s.y)] == true,
                          rx = s.respawn and s.respawn.x, ry = s.respawn and s.respawn.y }
      end
      return out""")
    now = c.eval("return ns.AzeroData.SAVE_VERSION")
    assert now == 4 and all(e["v"] == now and not e["solid"] for e in r), r
    assert r[0]["map"] == "rebelcamp" and r[0]["ch"] == "=" and (r[0]["rx"], r[0]["ry"]) == (7, 9), r
    assert r[1]["map"] == "bootybay" and r[1]["ch"] in "=D", r
    assert r[2]["map"] == "kurzen" and (r[2]["x"], r[2]["y"]) == (4, 16), r      # the foot of the ladder
    assert r[3]["map"] == "jaguero" and r[3]["ch"] == "D", r                       # the jetty
    assert r[4]["ch"] == "=" and (r[4]["rx"], r[4]["ry"]) == (4, 5), r           # (the inn's revive point stays)
    # and a save from today stays where it is
    c.eval("""local G = ns.Azero
      G:Data().save = { v = 4, map = 'stvnorth', x = 27, y = 25, face = 'down', party = {}, flags = { starter = 'murkling' } }
      G:Load()""")
    assert c.eval_py("local s = ns.Azero.save return { s.x, s.y }") == [27, 25]
    nodes = c.eval_py(r"""local G = ns.Azero
      local n = ns.AzeroMaps.stvnorth.nodes.herb[1]
      local still = 'stvnorth:' .. n[1] .. ':' .. n[2]
      G:Data().save = { v = 3, map = 'town', x = 7, y = 23, face = 'down', party = {}, flags = { starter = 'murkling' },
                        nodes = { ['stvnorth:26:6'] = { t = 1, n = 2 }, [still] = { t = 1, n = 1 }, ['town:3:3'] = { t = 1, n = 1 } } }
      G:Load()
      local out = {}
      for k in pairs(G.save.nodes) do out[#out + 1] = k end
      table.sort(out)
      return { out, still }""")
    assert nodes[0] == sorted([nodes[1], "town:3:3"]), nodes


@case
def the_poster_film_walks_the_vale_on_open_ground():
    """The hub poster's film (Poster.lua) walks its hero up the redrawn roads: every step on open ground, past nobody."""
    w, c = game()
    bad = c.eval_py(r"""local G, out = ns.Azero, {}
      for _, shot in ipairs(ns.AzeroPoster.SHOTS) do
        if G.STV_REDRAWN[shot.map] then
          local m = G.Compile(shot.map)
          local npc = {}
          for _, n in ipairs(m.def.npcs or {}) do npc[m.key(n.x, n.y)] = n.id end
          local len = 0
          for i = 1, #shot.path - 1 do
            local a, b = shot.path[i], shot.path[i + 1]
            len = len + math.abs(b[1] - a[1]) + math.abs(b[2] - a[2])
            for k = 0, 20 do
              local x, y = a[1] + (b[1] - a[1]) * k / 20, a[2] + (b[2] - a[2]) * k / 20
              for _, tx in ipairs({ math.floor(x - 0.49), math.floor(x + 0.49) }) do
                local key = m.key(tx, math.floor(y + 0.5))
                if m.solid[key] or npc[key] then out[#out + 1] = shot.map .. ' ' .. tx .. ',' .. math.floor(y + 0.5) end
              end
            end
          end
          if len < 8 * 2.2 then out[#out + 1] = shot.map .. ' road too short ' .. len end
        end
      end
      return out""")
    assert bad == [], bad
    no_errors(w)


if __name__ == "__main__":
    run_all()

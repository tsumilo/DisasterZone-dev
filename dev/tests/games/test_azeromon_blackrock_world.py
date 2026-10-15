"""Azeromon: Blackrock, the world half (0.25).

Covers: every Blackrock map compiles on real atlas tiles with its zone's look (red-roofed Lakeshire, lava in the
Steppes, the Gorge and the mountain); the edges are reciprocal and land on open ground both ways (Darkshire's new
north road included); every warp lands on open ground; every NPC, sign, object and gather node stands where the
player can reach it; the gates hold (Darkshire's north road without the Blackwater Seal, Render's Valley without the
Stonewatch Seal, Lothos without the Dark Iron Signet) and open with the badge; the gryphon roosts learn their routes
and Felicia flies to Lakeshire; Magmadar leaves once caught; the baked grounds are fresh, the Core has its own battle
scene and the zones have their moods. Species / trainer ids are checked only once the beasts half is in
(D.species.blackwhelp).

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_blackrock_world.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
DEV = os.path.dirname(TESTS)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(DEV, "generators"))

from _common import case, run_all, solo, no_errors  # noqa: E402
from _azero_bot import BOT  # noqa: E402

MAPS = ["threecorners", "lakeshire", "lakeshireinn", "everstill", "stonewatch", "steppes", "brm", "brd", "moltencore", "gorge"]
OPP = {"north": "south", "south": "north", "east": "west", "west": "east"}
DIR = {"north": "up", "south": "down", "east": "right", "west": "left"}


def game():
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(5)")
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 12 ns.Azero.save.money = 1000")
    return w, c


def log(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


def where(c):
    return c.eval_py("local s = ns.Azero.save return { s.map, s.x, s.y }")


def talk(c, map_id, x, y, face):
    c.eval("ns.Azero:EnterMap(%r, %d, %d, %r, true) ns.Azero:PressA()" % (map_id, x, y, face))
    c.eval("T_AZ.settle()")


def all_badges(c):
    c.eval("""local G = ns.Azero
      for _, f in ipairs({ 'badge_blackwater', 'badge_stonewatch', 'badge_darkiron' }) do G:SetFlag(f) end""")


@case
def every_map_compiles_on_atlas_tiles_with_its_zone_look():
    w, c = game()
    r = c.eval_py(r"""local G, A, Maps = ns.Azero, ns.AzeroAtlas, ns.AzeroMaps
      local bad = {}
      for _, id in ipairs(%s) do
        local def = Maps[id]
        local m = G.Compile(id)
        if not m then bad[#bad + 1] = id .. ' does not compile' else
          for i, r in ipairs(def.rows) do if #r ~= #def.rows[1] then bad[#bad + 1] = id .. ' row ' .. i end end
          for _, name in pairs(m.base) do if not A[name] then bad[#bad + 1] = id .. ' base ' .. name end end
          for _, name in pairs(m.over) do if type(name) == 'string' and not A[name] then bad[#bad + 1] = id .. ' over ' .. name end end
        end
      end
      local ls, st, gg, bm = G.Compile('lakeshire'), G.Compile('steppes'), G.Compile('gorge'), G.Compile('brm')
      return { bad = bad, roof = ls.over[ls.key(3, 3)], door = ls.solid[ls.key(6, 8)] ~= true,
               lgrass = ls.base[ls.key(5, 6)], stree = st.over[st.key(0, 0)], lava = st.water[st.key(8, 7)] == true,
               gwall = gg.base[gg.key(0, 0)], bwall = bm.base[bm.key(0, 3)], cave = Maps.brm.cave and Maps.brm.cave.rate,
               mcave = Maps.moltencore.cave and Maps.moltencore.cave.rate }""" % ("{ '" + "', '".join(MAPS) + "' }"))
    assert r["bad"] == [], r["bad"]
    assert r["roof"] == "rrhouse_0_0" and r["door"], r
    assert r["lgrass"] in ("rgrass1", "rgrass2") and r["stree"] == "stree" and r["lava"], r
    assert r["gwall"] == "gwall" and r["bwall"] == "bwall" and r["cave"] and r["mcave"], r
    no_errors(w)


@case
def edges_are_reciprocal_and_land_on_open_ground_both_ways():
    w, c = game()
    all_badges(c)
    edges = c.eval_py(r"""local out = {}
      for _, id in ipairs({ 'darkshire', 'threecorners', 'lakeshire', 'everstill', 'stonewatch', 'steppes', 'brm', 'gorge' }) do
        for side, e in pairs(ns.AzeroMaps[id].edges or {}) do out[#out + 1] = { id, side, e.map } end
      end
      return out""")
    checked = 0
    for mid, side, target in edges:
        if mid == "darkshire" and side != "north":
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
    assert checked >= 20, checked
    no_errors(w)


@case
def warps_land_on_open_ground_and_lead_back():
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
      return out""" % ("{ '" + "', '".join(MAPS) + "' }"))
    assert bad == [], bad
    # the inn door and back; the Depths' stair and back
    c.eval("ns.Azero:EnterMap('lakeshire', 6, 9, 'up', true)")
    c.eval("T_AZ.step('up')")
    assert where(c) == ["lakeshireinn", 4, 6], where(c)
    c.eval("ns.Azero:EnterMap('lakeshireinn', 4, 6, 'down', true) T_AZ.step('down')")
    assert where(c) == ["lakeshire", 6, 9], where(c)
    c.eval("ns.Azero:EnterMap('brm', 5, 21, 'up', true) T_AZ.step('up')")
    assert where(c) == ["brd", 12, 19], where(c)
    no_errors(w)


@case
def every_npc_sign_object_and_node_is_reachable():
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
        for _, o in ipairs(def.warps or {}) do end
        -- arrivals by warp or flight count as starts too
        for _, d in pairs(ns.AzeroMaps) do
          if type(d) == 'table' then for _, wp in ipairs(d.warps or {}) do if wp.map == id then push(wp.tx, wp.ty) end end end
        end
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
        for _, spots in pairs(def.nodes or {}) do for _, p in ipairs(spots) do things[#things + 1] = { 'node', p[1], p[2] } end end
        for _, t in ipairs(things) do
          if not near(t[2], t[3]) then out[#out + 1] = id .. ' ' .. t[1] .. ' unreachable at ' .. t[2] .. ',' .. t[3] end
        end
      end
      return out""" % ("{ '" + "', '".join(MAPS) + "' }"))
    assert bad == [], bad
    no_errors(w)


@case
def darkshires_north_road_opens_with_the_blackwater_seal():
    w, c = game()
    c.eval("ns.Azero:EnterMap('darkshire', 11, 2, 'up', true)")
    c.eval("T_AZ.step('up')")
    c.eval("T_AZ.settle()")
    assert where(c)[0] == "darkshire" and where(c)[2] >= 2, where(c)
    assert "Night Watch Guard: North is Redridge" in log(c), log(c)
    c.eval("ns.Azero:SetFlag('badge_blackwater')")
    for _ in range(4):
        if where(c)[0] == "threecorners":
            break
        c.eval("T_AZ.step('up')")
    assert where(c) == ["threecorners", 9, 23], where(c)
    no_errors(w)


@case
def renders_valley_needs_the_stonewatch_seal():
    w, c = game()
    c.eval("ns.Azero:EnterMap('stonewatch', 26, 2, 'up', true)")
    c.eval("T_AZ.step('up')")
    c.eval("T_AZ.settle()")
    assert where(c)[0] == "stonewatch" and where(c)[2] >= 2, where(c)
    assert "Not without the Stonewatch Seal" in log(c), log(c)
    c.eval("ns.Azero:SetFlag('badge_stonewatch')")
    for _ in range(4):
        if where(c)[0] == "steppes":
            break
        c.eval("T_AZ.step('up')")
    assert where(c) == ["steppes", 26, 27], where(c)
    no_errors(w)


@case
def lothos_opens_the_molten_core_for_signet_holders_only():
    w, c = game()
    c.eval("T_AZ.choice = 1")
    talk(c, "brm", 27, 6, "up")
    assert where(c)[0] == "brm" and "Only those who bear the Dark Iron Signet" in log(c), (where(c), log(c))
    c.eval("ns.Azero:SetFlag('badge_darkiron') T_AZ.log = {}")
    talk(c, "brm", 27, 6, "up")
    assert where(c) == ["moltencore", 4, 17], (where(c), log(c))
    c.eval("T_AZ.step('down')")                                     # the stair back up
    assert where(c) == ["brm", 27, 6], where(c)
    no_errors(w)


@case
def magmadar_waits_until_caught():
    w, c = game()
    hidden = lambda: c.eval_py("""ns.Azero:EnterMap('moltencore', 19, 5, 'up', true)
      for _, n in ipairs(ns.Azero.npcs) do if n.id == 'magmadar' then return n.hidden == true end end
      return 'no such npc'""")
    assert hidden() is False
    c.eval("ns.Azero:SetFlag('caught_magmadar')")
    assert hidden() is True
    no_errors(w)


@case
def gryphon_roosts_learn_their_routes():
    w, c = game()
    c.eval("T_AZ.choice = 99")                                      # (Stay)
    talk(c, "lakeshire", 17, 22, "right")                            # Ariena: learns Lakeshire
    assert c.eval("return ns.Azero:Flag('fp_lakeshire')") is True, log(c)
    c.eval("T_AZ.choice = 2")
    talk(c, "darkshire", 16, 15, "right")                            # Felicia: Sentinel Hill, Lakeshire, Stay
    assert where(c) == ["lakeshire", 17, 22] and c.eval("return ns.Azero.save.money") == 970, where(c)
    c.eval("T_AZ.choice = 99")
    talk(c, "steppes", 34, 21, "right")                              # Borgus: learns Morgan's Vigil
    talk(c, "gorge", 7, 7, "up")                                     # Lanie: learns Thorium Point
    c.eval("T_AZ.choice = 2")
    talk(c, "gorge", 7, 7, "up")                                     # Lanie: Morgan's Vigil, Lakeshire, Stay
    assert where(c) == ["lakeshire", 17, 22], where(c)
    c.eval("T_AZ.choice = 3")
    talk(c, "lakeshire", 17, 22, "right")                            # Ariena: Darkshire, Vigil, Thorium Point
    assert where(c) == ["gorge", 7, 7], where(c)
    shown = c.eval_py("""local W, n = ns.AzeroWorld, 0
      local g = ns.Azero
      for _, id in ipairs({ 'lakeshire', 'steppes', 'gorge', 'darkshire' }) do g.save.visited[id] = true end
      for _, fl in ipairs(W.FLIGHTS) do if W.FlightShown(fl) and (fl.flag or ''):find('fp_[lmt]') then n = n + 1 end end
      return n""")
    assert shown == 3, shown
    no_errors(w)


@case
def every_new_map_has_a_place_on_the_world_map():
    w, c = game()
    r = c.eval_py("""local W, out = ns.AzeroWorld, {}
      for _, id in ipairs(%s) do out[id] = W.PlaceOf(id) and W.PlaceOf(id).zone or false end
      return out""" % ("{ '" + "', '".join(MAPS) + "' }"))
    assert all(r.values()), r
    assert {r["threecorners"], r["steppes"], r["brm"], r["gorge"]} == {"redridge", "steppes", "blackrock", "gorge"}, r
    no_errors(w)


@case
def encounters_and_trainers_name_real_beasts_once_the_beasts_half_is_in():
    w, c = game()
    if not c.eval("return ns.AzeroData.species.blackwhelp ~= nil"):
        print("    (skipped: species not merged yet)")
        return
    bad = c.eval_py(r"""local D, out = ns.AzeroData, {}
      for _, id in ipairs(%s) do
        local def = ns.AzeroMaps[id]
        for _, list in ipairs({ def.encounters or {}, def.coastEncounters or {} }) do
          for _, e in ipairs(list) do if not D.species[e.sp] then out[#out + 1] = id .. ' species ' .. e.sp end end
        end
        for _, n in ipairs(def.npcs or {}) do
          if n.trainer and not D.trainers[n.trainer] then out[#out + 1] = id .. ' trainer ' .. n.trainer end
        end
      end
      return out""" % ("{ '" + "', '".join(MAPS) + "' }"))
    assert bad == [], bad
    no_errors(w)


@case
def the_grounds_are_baked_and_fresh():
    import gen_azeromon_ground as gg
    maps = gg.load_maps()
    src = gg._src_digest()
    _, c = solo("Alice", tick=2)
    g = c.eval_py("return ns.AzeroGround")
    for mid in MAPS + ["darkshire"]:
        assert mid in g, (mid, "not baked - run generators\\gen_azeromon_ground.py")
        assert g[mid]["v"] == gg.inputs_hash(maps[mid], src), "%s changed since its ground was baked" % mid
    for mid in ("brm", "brd", "moltencore"):
        assert g[mid].get("cave"), mid                               # always dim, lit by torches and lava
    assert len(g["steppes"]["lights"]) > 10                           # the lava glows at night
    art = c.eval_py("return ns.AzeroBattleArt.scenes")
    assert (art["redridge"], art["steppes"], art["gorge"], art["blackrock"], art["moltencore"]) == \
        ("redridge", "steppes", "gorge", "depths", "molten"), art


def play(map_id, x, y):
    w, c = solo("Alice", tick=2)
    c.eval(BOT)
    c.eval("T_AZ.seed(3)")
    c.eval("ns.Azero:NewGame()")
    c.slash("/dz play azeromon")
    w.tick(0.3)
    c.eval("ns.AzeroUI._HandleKey('A')")
    w.tick(0.3)
    c.eval("T_AZ.settle()")
    c.eval("ns.Azero.forceRain = false ns.Azero.clockHour = 12")
    c.eval("ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (map_id, x, y))
    w.tick(0.2)
    return w, c


@case
def the_zones_have_their_moods():
    w, c = play("steppes", 9, 11)                                    # by the big lava lake: ash and embers
    a = c.eval_py("return ns.AzeroUI._Ambient()")
    assert a["mood"] and a["pix"] >= 20, a
    c.eval("ns.Azero:EnterMap('brm', 18, 13, 'down', true)")
    w.tick(0.2)
    a = c.eval_py("return ns.AzeroUI._Ambient()")
    assert a["mood"] and a["dark"] >= 1 and a["pix"] >= 5, a          # a cave: dim, embers off the lava
    c.eval("ns.Azero:EnterMap('lakeshire', 12, 10, 'down', true)")
    w.tick(0.2)
    a = c.eval_py("return ns.AzeroUI._Ambient()")
    assert a["mood"] and a["pix"] >= 16, a                           # falling leaves, chimney smoke
    no_errors(w)


if __name__ == "__main__":
    run_all()

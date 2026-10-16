"""Azeromon: daily routines (Routine.lua, 0.27).

Covers: Darkshire, Booty Bay and Lakeshire's days; every routine path and loop runs on open ground (roads, grass, doors); people stand where the realm clock
puts them on entering Goldshire (Argus at the anvil at noon, Thomas on patrol at night); the inn fills up in the
evening and the cottage at night; walking goes one tile at a time and reaches the spot; a player in the way is walked round (or, in a
doorway, they go back in until the player has passed); the lamps are lit from the lamplighter's dusk round to his dawn round; Maybell's stall opens and shuts
(its tiles and her shop); lines for the bubbles come at their minute; two clients agree.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_routines.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402


def town(hour, x=17, y=12):
    w, c = solo("Alice", tick=2)
    c.eval("ns.Azero:NewGame() ns.Azero.clockHour = %r ns.Azero:EnterMap('town', %d, %d, 'down', true)" % (hour, x, y))
    return w, c


def people(c):
    """id -> { x, y, hidden, act } on the current map"""
    return c.eval_py("""local out = {}
      for _, n in ipairs(ns.Azero.npcs) do
        out[n.id or n.def.name] = { x = n.x, y = n.y, hidden = n.hidden == true, act = n.act or false, visitor = n.visitor == true }
      end
      return out""")


@case
def every_routine_walks_on_open_ground():
    w, c = solo("Alice", tick=2)
    bad = c.eval_py("""
      local R, G = ns.AzeroRoutine, ns.Azero
      local bad = {}
      for _, p in ipairs(R.People()) do
        local m = G.Compile(p.map)
        local rt = R.Of(p.def)
        for _, seg in ipairs(rt.segs) do
          for _, t in ipairs(seg.tiles or seg.loop or {}) do
            local k = m.key(t.x, t.y)
            local open = t.x >= 0 and t.y >= 0 and t.x < m.w and t.y < m.h and (not m.solid[k] or m.warp[k])
            if not open then bad[#bad + 1] = p.def.id .. "@" .. t.x .. "," .. t.y end
          end
        end
      end
      return bad""")
    assert bad == [], bad
    no_errors(w)


@case
def people_stand_where_the_clock_says():
    w, c = town(12)
    p = people(c)
    assert (p["argus"]["x"], p["argus"]["y"], p["argus"]["act"]) == (23, 22, "smith"), p["argus"]
    assert (p["mallory"]["x"], p["mallory"]["y"], p["mallory"]["act"]) == (14, 4, "brew"), p["mallory"]
    assert (p["guard"]["x"], p["guard"]["y"]) == (19, 1) and not p["guard"]["hidden"], p["guard"]
    assert (p["farmer"]["x"], p["farmer"]["y"], p["farmer"]["act"]) == (20, 17, "sell"), p["farmer"]
    for gone in ("nightguard", "lamplighter", "wenna", "pell"):
        assert p[gone]["hidden"], (gone, p[gone])
    w2, c2 = town(23)
    q = people(c2)
    assert q["argus"]["hidden"] and q["guard"]["hidden"] and q["farmer"]["hidden"], q
    assert not q["nightguard"]["hidden"], q["nightguard"]
    no_errors(w)
    no_errors(w2)


@case
def the_inn_fills_up_in_the_evening_and_the_cottage_at_night():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local G = ns.Azero
      G:NewGame()
      local function inside(map, hour)
        G.clockHour = hour
        G:EnterMap(map, 7, 8, 'up', true)
        local ids = {}
        for _, n in ipairs(G.npcs) do if n.visitor then ids[#ids + 1] = n.id end end
        table.sort(ids)
        return ids
      end
      return { noon = inside('post', 12), evening = inside('post', 22), cottage = inside('cottage', 23) }""")
    assert r["noon"] == ["lamplighter", "nightguard"], r                      # Old Tom and Thomas sleep by day
    assert r["evening"] == ["argus", "guard", "lamplighter", "leebrown", "mallory", "pell", "wenna"], r
    assert r["cottage"] == ["farmer", "kid"], r
    no_errors(w)


@case
def a_full_inn_never_walls_the_player_in():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local G = ns.Azero
      G:NewGame()
      G.clockHour = 22
      G:EnterMap('post', 7, 8, 'up', true)
      local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
      local out = { seated = 0, passed = 0 }
      for _, n in ipairs(G.npcs) do
        if n.visitor then
          out.seated = out.seated + 1
          for dir, d in pairs(DIRS) do                       -- from any open tile beside them, step onto their seat
            local fx, fy = n.x - d[1], n.y - d[2]
            if fx >= 0 and fy >= 0 and fx < G.map.w and fy < G.map.h and not G.map.solid[G.map.key(fx, fy)]
               and not G:NpcAt(fx, fy) then
              G.moving = nil
              G.save.x, G.save.y = fx, fy
              if G:TryStep(dir) == "moved" then out.passed = out.passed + 1 end
              G.moving = nil
              break
            end
          end
        end
      end
      G.save.x, G.save.y = 3, 2                              -- Innkeeper Farley still stands her ground
      out.farley = G:TryStep('left')
      return out""")
    assert r["seated"] >= 5 and r["passed"] == r["seated"], r
    assert r["farley"] == "blocked", r
    no_errors(w)


@case
def people_walk_one_tile_at_a_time_and_arrive():
    w, c = town(6 + 10 / 60, 17, 12)                 # Argus leaves the inn for the anvil at 06:10
    seen = []
    for _ in range(90):
        c.eval("ns.Azero.clockHour = ns.Azero.clockHour + 0.08 / 3600 ns.Azero:UpdateNpcs(0.08)")
        p = people(c)["argus"]
        if not p["hidden"] and (not seen or seen[-1] != (p["x"], p["y"])):
            seen.append((p["x"], p["y"]))
    assert seen and seen[-1] == (23, 22), seen
    for a, b in zip(seen, seen[1:]):
        assert abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1, (a, b, seen)
    no_errors(w)


@case
def a_player_in_the_way_is_walked_round():
    w, c = town(6 + 10 / 60, 15, 23)                 # standing on the lane Argus walks
    seen = []
    for _ in range(140):
        c.eval("ns.Azero.clockHour = ns.Azero.clockHour + 0.08 / 3600 ns.Azero:UpdateNpcs(0.08)")
        a = people(c)["argus"]
        if not a["hidden"] and (not seen or seen[-1] != (a["x"], a["y"])):
            seen.append((a["x"], a["y"]))
    assert (15, 23) not in seen, seen                # never on the player's tile
    assert (14, 23) in seen and (16, 23) in seen, seen
    assert (14, 22) in seen or (14, 24) in seen, seen  # one tile to the side, round the player
    for (x0, y0), (x1, y1) in zip(seen, seen[1:]):
        assert abs(x1 - x0) + abs(y1 - y0) == 1, seen  # one tile at a time, no jumps
    assert seen[-1] == (23, 22), seen                # and on to the anvil
    no_errors(w)


@case
def someone_coming_out_of_a_door_goes_back_in_to_let_the_player_pass():
    w, c = town(6 + 10 / 60, 8, 23)                  # right outside the Lion's Pride as Argus comes out
    def step(n):
        for _ in range(n):
            c.eval("ns.Azero.clockHour = ns.Azero.clockHour + 0.08 / 3600 ns.Azero:UpdateNpcs(0.08)")
    step(12)
    a = people(c)["argus"]
    assert a["hidden"], a                            # back inside: the doorway is free for the player
    c.eval("ns.Azero.save.x, ns.Azero.save.y = 12, 24")    # the player walks on
    step(40)
    a = people(c)["argus"]
    assert not a["hidden"] and a["x"] > 8, a         # out again and on his way
    no_errors(w)


def walk_track(c, who, steps, dt=0.08, block=None):
    """steps of the clock and the NPC update; the spots `who` stands on, in order (block = (from, to, x, y): the
    player stands on x, y between those steps)"""
    seen = []
    for k in range(steps):
        if block and k == block[0]:
            c.eval("ns.Azero.save.x, ns.Azero.save.y = %d, %d" % block[2:])
        if block and k == block[1]:
            c.eval("ns.Azero.save.x, ns.Azero.save.y = 30, 23")
        c.eval("ns.Azero.clockHour = ns.Azero.clockHour + %r / 3600 ns.Azero:UpdateNpcs(%r)" % (dt, dt))
        p = people(c)[who]
        if not p["hidden"] and (not seen or seen[-1] != (p["x"], p["y"])):
            seen.append((p["x"], p["y"]))
    return seen


def no_jumps(seen):
    for a, b in zip(seen, seen[1:]):
        assert abs(a[0] - b[0]) + abs(a[1] - b[1]) == 1, ("jumped", a, b, seen)


@case
def billy_runs_lap_after_lap_without_jumping_back():
    # regression: at the start of each lap a walker a few tiles behind was put back at the loop's start
    w, c = town(10, 30, 23)
    seen = walk_track(c, "kid", 400)                     # 32 s: several laps of his 12-tile loop
    assert len(seen) > 30, seen
    no_jumps(seen)
    no_errors(w)


@case
def a_walker_held_up_on_its_loop_hurries_on_instead_of_jumping():
    w, c = town(10, 30, 23)
    seen = walk_track(c, "kid", 300, block=(20, 120, 5, 13))     # the player stands on his loop for 8 s
    no_jumps(seen)
    a = c.eval_py("local n for _, x in ipairs(ns.Azero.npcs) do if x.id == 'kid' then n = x end end "
                  "local st = ns.AzeroRoutine.State(n.def) return { ti = n.ti, i = st.i }")
    assert (a["i"] - a["ti"]) % 12 <= 1, a                        # caught up with the clock again (or mid-step)
    no_errors(w)


@case
def the_night_patrol_goes_round_without_jumping():
    w, c = town(22, 30, 20)
    seen = walk_track(c, "nightguard", 500, dt=0.1)               # 50 s: most of a lap of 70 tiles
    assert len(seen) > 40, seen
    no_jumps(seen)
    no_errors(w)


@case
def a_walk_into_the_inn_ends_at_the_door_even_when_late():
    w, c = town(18, 15, 22)                                       # Argus heads for the inn at 18:00
    seen = walk_track(c, "argus", 120, block=(10, 45, 18, 23))    # the player blocks the lane for 3.5 s
    no_jumps(seen)
    assert seen[-1] in ((8, 22), (8, 23)), seen
    assert people(c)["argus"]["hidden"], people(c)["argus"]       # in through the door, not before
    no_errors(w)


@case
def the_clock_runs_smoothly_through_the_realms_minutes():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local G, R = ns.Azero, ns.AzeroRoutine
      G.clockHour = nil
      local realm = 12 * 60 + 30.9                    -- the realm's minute ticks over 6 s after we first look
      G.Hour = function() return math.floor(realm) / 60 end
      R._ResetClock()
      local t = 1000
      GetTime = function() return t end
      local out, last = {}, R.Now()
      local biggest = 0
      for _ = 1, 600 do
        t = t + 0.1
        realm = realm + 0.1 / 60
        local now = R.Now()
        biggest = math.max(biggest, (now - last) * 60)
        last = now
      end
      return { biggest = biggest, behind = (realm - last) * 60 }""")
    assert r["biggest"] < 0.2, r                         # never more than a step of 0.15 s at a time
    assert abs(r["behind"]) < 60, r                      # within the realm's minute
    no_errors(w)


@case
def lamps_burn_from_the_dusk_round_to_the_dawn_round():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local R = ns.AzeroRoutine
      local out = {}
      for _, h in ipairs({ 12, 17.5, 23, 3, 5.9, 6.5 }) do
        local lit = 0
        for i = 1, 6 do if R.LampLit("town", i, h * 60) then lit = lit + 1 end end
        out[#out + 1] = lit
      end
      local t = R.LampTimes("town")
      return { lit = out, first = t[6].on, last = t[5].on, offFirst = t[6].off }""")
    assert r["lit"] == [0, 0, 6, 6, 0, 0], r
    assert 17 * 60 + 50 < r["first"] < r["last"] < 18 * 60 + 10, r          # one by one, in a few minutes
    assert 5 * 60 + 20 < r["offFirst"] < 5 * 60 + 30, r
    no_errors(w)


@case
def maybells_stall_opens_at_eight_and_shuts_at_six():
    w, c = town(12, 20, 18)
    r = c.eval_py("""
      local G, R = ns.Azero, ns.AzeroRoutine
      local m = G.map
      local open = { R.StallOpen('town'), m.over[m.key(19, 14)] }
      G.save.face = 'up'
      G:PressA()
      for _ = 1, 3 do if G.pending and G.pending.kind ~= 'shop' then G:Advance() end end
      local shop = G.pending and G.pending.kind
      G.pending, G.co = nil, nil
      G.clockHour = 19.5
      G:EnterMap('town', 20, 18, 'up', true)
      local shut = { R.StallOpen('town'), m.over[m.key(19, 14)], G.map.over[G.map.key(19, 14)] }
      return { open = open, shop = shop or false, shut = shut }""")
    assert r["open"] == [True, "stall_0_0"], r
    assert r["shop"] == "shop", r
    assert r["shut"][0] is False and r["shut"][2] == "stallshut_0_0", r
    no_errors(w)


@case
def the_inn_and_cottage_know_how_many_are_home():
    # (UI.lua: the inn's windows glow brighter and its chimneys smoke thicker the fuller it is)
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""local R = ns.AzeroRoutine
      return { R.InsideCount('post', 12 * 60), R.InsideCount('post', 22 * 60), R.InsideCount('cottage', 23 * 60),
               R.InsideCount('cottage', 12 * 60) }""")
    assert r == [2, 7, 2, 0], r
    no_errors(w)


@case
def lines_come_at_their_minute():
    w, c = solo("Alice", tick=2)
    r = c.eval_py("""
      local R, M = ns.AzeroRoutine, ns.AzeroMaps
      local argus
      for _, n in ipairs(M.town.npcs) do if n.id == 'argus' then argus = n end end
      return { R.Says(argus, 7 * 60) or false, R.Says(argus, 7 * 60 + 0.5) or false, R.Says(argus, 7 * 60 + 1) or false }""")
    assert r == ["Forge is hot! Bring me ore.", "Forge is hot! Bring me ore.", False], r
    no_errors(w)


@case
def two_clients_agree():
    spots = []
    for name in ("Alice", "Bob"):
        w, c = solo(name, tick=2)
        c.eval("ns.Azero:NewGame() ns.Azero.clockHour = 18.25 ns.Azero:EnterMap('town', 17, 12, 'down', true)")
        spots.append(people(c))
    assert spots[0] == spots[1], spots


@case
def darkshire_booty_bay_and_lakeshire_keep_their_days_too():
    w, c = solo("Alice", tick=2)
    def at(mapid, hour, x, y):
        c.eval("ns.Azero:NewGame() ns.Azero.clockHour = %r ns.Azero:EnterMap(%r, %d, %d, 'down', true)" % (hour, mapid, x, y))
        return people(c)
    p = at("darkshire", 12, 12, 14)
    assert (p["ello"]["x"], p["ello"]["y"]) == (15, 8) and (p["eva"]["x"], p["eva"]["y"]) == (6, 16), p
    assert (p["dsguard"]["x"], p["dsguard"]["y"]) == (21, 12), p
    p = at("darkshire", 23, 12, 14)
    assert p["ello"]["hidden"] and not p["eva"]["hidden"] and p["dsguard"]["y"] in (9, 10, 11), p
    p = at("bootybay", 12, 12, 12)
    assert (p["heming"]["x"], p["heming"]["y"], p["heming"]["act"]) == (10, 18, "fish"), p
    assert p["dockhand"]["y"] == 17, p
    p = at("bootybayinn", 23, 4, 6)
    assert p["heming"]["visitor"] and p["dockhand"]["visitor"], p
    p = at("lakeshire", 12, 12, 14)
    assert (p["verner"]["x"], p["verner"]["y"], p["verner"]["act"]) == (4, 12, "smith"), p
    assert (p["lamar"]["x"], p["lamar"]["y"]) == (7, 9) and (p["solomon"]["x"], p["solomon"]["y"]) == (11, 9), p
    p = at("lakeshire", 23, 12, 14)
    assert p["verner"]["hidden"] and p["lamar"]["hidden"] and p["marris"]["y"] in (10, 11), p
    p = at("lakeshireinn", 23, 4, 6)
    assert p["verner"]["visitor"] and p["lamar"]["visitor"], p           # the shop and the trainer, still there to talk to
    no_errors(w)


if __name__ == "__main__":
    run_all(globals())

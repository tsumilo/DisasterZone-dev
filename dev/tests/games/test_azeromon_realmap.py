"""Azeromon on the real map (Games/Azeromon/World): Northshire Valley from the client's own terrain.

Covers: the generated data loads (blocks, areas, species, quests, interiors) and every tile the world can draw is in
the atlas; a new game starts on a human's real first step outside Northshire Abbey; NPCs and mobs at their real
spawn points; Eagan Peltskinner's starter; walking into a mob starts its battle and a beaten mob stays gone until
it respawns; a hostile mob notices you; the Abbey door and its floors; the first quests (A Threat Within, Kobold
Camp Cleanup: kill credit, turn-in); an old save is archived, not loaded.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_azeromon_realmap.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

from _azero_bot import BOT  # noqa: E402


def game(seed=7, new=True):
    w, c = solo("Alice", tick=2)
    c.eval("T_AZ_REAL = true")
    c.eval(BOT)
    c.eval("T_AZ.seed(%d)" % seed)
    if new:
        c.eval("ns.Azero:NewGame()")
    return w, c


def logtext(c):
    return "\n".join(c.eval_py("return T_AZ.log") or [])


@case
def world_data_loads():
    w, c = game()
    r = c.eval_py(r"""
      local W, WS, D = ns.AzeroWorldData, ns.AzeroLand, ns.AzeroData
      local n = 0 for _ in pairs(W.blocks) do n = n + 1 end
      local q = 0 for _ in pairs(W.quests or {}) do q = q + 1 end
      local i = 0 for _ in pairs(W.interiors) do i = i + 1 end
      local name, zone = WS.AreaName(4127, 6243)
      return { blocks = n, quests = q, interiors = i, area = name, zone = zone,
               wolf = D.species.young_wolf and D.species.young_wolf.name,
               thug = D.species.defias_thug and D.species.defias_thug.untameable,
               dex = #D.dexOrder }
    """)
    assert r["blocks"] >= 30, r
    assert r["quests"] >= 10, r
    assert r["interiors"] >= 3, r
    assert r["area"] == "Northshire Valley" and r["zone"] == "Elwynn Forest", r
    assert r["wolf"] == "Young Wolf" and r["thug"] is True, r
    no_errors(w)


@case
def every_world_tile_is_in_the_atlas():
    w, c = game()
    missing = c.eval_py(r"""
      local W, WS, A = ns.AzeroWorldData, ns.AzeroLand, ns.AzeroAtlas
      local miss, seen = {}, {}
      for key in pairs(W.blocks) do
        local bx, by = key % 256, math.floor(key / 256)
        for y = by * 32, by * 32 + 31 do
          for x = bx * 32, bx * 32 + 31 do
            for _, name in ipairs({ WS.BaseName(x, y), WS.OverName(x, y) or false }) do
              if name and not A[name] and not seen[name] then seen[name] = true miss[#miss + 1] = name end
            end
          end
        end
      end
      table.sort(miss)
      return miss
    """)
    assert missing == [], missing
    no_errors(w)


@case
def new_game_starts_outside_the_abbey():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      local s = G.save
      return { map = s.map, x = s.x, y = s.y, solid = G.map.solid[G.map.key(s.x, s.y)], npcs = #G.npcs, v = s.v }
    """)
    assert r["map"] == "world" and (r["x"], r["y"]) == (4127, 6243), r
    assert not r["solid"], r
    assert r["npcs"] > 10, r
    assert r["v"] == 2, r
    no_errors(w)


@case
def npcs_stand_where_they_do_in_wow():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      local out = {}
      for _, n in ipairs(G.npcs) do out[n.def.name] = { n.x, n.y, n.def.title or false } end
      local mcb
      for _, e in ipairs(ns.AzeroWorldData.ents) do if e.n == "Marshal McBride" then mcb = e.map end end
      return { willem = out["Deputy Willem"], eagan = out["Eagan Peltskinner"], mcbride = mcb }
    """)
    assert r["willem"] and abs(r["willem"][0] - 4128) <= 1 and abs(r["willem"][1] - 6240) <= 1, r
    assert r["eagan"], r
    assert r["mcbride"] and r["mcbride"].startswith("i10286_"), r      # inside the Abbey
    no_errors(w)


@case
def eagan_gives_a_starter():
    w, c = game()
    r = c.eval_py(r"""
      local G = ns.Azero
      local eagan
      for _, e in ipairs(ns.AzeroWorldData.ents) do if e.n == "Eagan Peltskinner" then eagan = e end end
      G.save.x, G.save.y = eagan.x, eagan.y + 1
      G.save.face = "up"
      ns.AzeroWorldGame.Refresh(G)
      for _, n in ipairs(G.npcs) do if n.def.ent == eagan then n.x, n.y = eagan.x, eagan.y end end
      G:PressA()
      T_AZ.settle()
      local p = G.save.party[1]
      return { sp = p and p.sp, lvl = p and p.lvl, nets = G.save.bag.net, flag = G:Flag("starter") }
    """)
    assert r["sp"] == "young_wolf" and r["lvl"] == 3 and r["nets"] == 5, r
    no_errors(w)


@case
def walking_into_a_mob_fights_it_and_it_stays_gone():
    w, c = game()
    r = c.eval_py(r"""
      local G, WG = ns.Azero, ns.AzeroWorldGame
      table.insert(G.save.party, ns.AzeroMon.New("young_wolf", 10, G.rng))
      local mob
      for _, e in ipairs(ns.AzeroWorldData.ents) do if e.k == "mob" and e.e == 6 then mob = e break end end
      G.save.x, G.save.y = mob.x - 1, mob.y
      WG.Refresh(G)
      local n = WG.live[mob.g]
      n.x, n.y = mob.x, mob.y
      local before = T_AZ.battles or 0
      G:TryStep("right")
      T_AZ.settle()
      return { fought = (T_AZ.battles or 0) - before, hidden = n.hidden, dead = G.save.dead and G.save.dead[mob.g] ~= nil }
    """)
    assert r["fought"] == 1 and r["hidden"] and r["dead"], r
    assert "Kobold Vermin" in logtext(c), logtext(c)[-400:]
    no_errors(w)


@case
def a_hostile_mob_notices_you():
    w, c = game()
    r = c.eval_py(r"""
      local G, WG = ns.Azero, ns.AzeroWorldGame
      table.insert(G.save.party, ns.AzeroMon.New("young_wolf", 3, G.rng))
      local mob
      for _, e in ipairs(ns.AzeroWorldData.ents) do if e.k == "mob" and e.e == 38 then mob = e break end end
      G.save.x, G.save.y = mob.x, mob.y + 3
      WG.Refresh(G)
      local n = WG.live[mob.g]
      n.x, n.y = mob.x, mob.y
      local before = T_AZ.battles or 0
      for _ = 1, 10 do G:Update(0.1) if G.co then break end end
      T_AZ.settle()
      return { fought = (T_AZ.battles or 0) - before }
    """)
    assert r["fought"] == 1, r
    assert "Defias Thug attacks!" in logtext(c), logtext(c)[-400:]
    no_errors(w)


@case
def the_abbey_door_and_its_floors():
    w, c = game()
    r = c.eval_py(r"""
      local G, W = ns.Azero, ns.AzeroWorldData
      local door
      for _, d in pairs(W.doors) do if d.map == "i10286_0" then door = d end end
      G:EnterMap("world", door.x, door.y + 1, "up", true)
      G:TryStep("up")
      for _ = 1, 20 do G:Update(0.05) end
      local inside = G.save.map
      local names = {}
      for _, n in ipairs(G.npcs) do names[#names + 1] = n.def.name end
      local up
      for _, wp in ipairs(G.map.def.warps) do if wp.map ~= "world" then up = wp end end
      local upMap
      if up then
        G:EnterMap(up.map, up.tx, up.ty, "down", true)
        upMap = G.save.map
      end
      return { inside = inside, names = names, upMap = upMap, name = ns.AzeroMaps[inside] and ns.AzeroMaps[inside].name }
    """)
    assert r["inside"] == "i10286_0", r
    assert "Marshal McBride" in r["names"], r
    assert r["name"] == "Northshire Abbey", r
    assert r["upMap"] and r["upMap"].startswith("i10286_"), r
    no_errors(w)


@case
def the_first_quests():
    w, c = game()
    r = c.eval_py(r"""
      local G, WG, W = ns.Azero, ns.AzeroWorldGame, ns.AzeroWorldData
      table.insert(G.save.party, ns.AzeroMon.New("young_wolf", 12, G.rng))
      local function talk(name)
        for _, e in ipairs(W.ents) do
          if e.n == name then
            local npc = { def = { ent = e, name = e.n, title = e.t }, x = e.x, y = e.y }
            G:Run(function(g) WG.Talk(g, npc) end)
            T_AZ.settle()
            return
          end
        end
        error("no " .. name)
      end
      T_AZ.choice = 1
      talk("Deputy Willem")                -- A Threat Within
      local a = G.save.quests and G.save.quests[783] and G.save.quests[783].s
      talk("Marshal McBride")              -- turn it in
      local b = G.save.quests[783] and G.save.quests[783].s
      talk("Marshal McBride")              -- Kobold Camp Cleanup
      local c7 = G.save.quests[7] and G.save.quests[7].s
      G:Run(function(g) for _ = 1, 10 do WG.Credit(g, { e = 6, g = 0 }, "win") end end)
      T_AZ.settle()
      local complete = WG.Complete(G, WG.quests[7])
      talk("Marshal McBride")
      return { a = a, b = b, c7 = c7, complete = complete, done7 = G.save.quests[7] and G.save.quests[7].s }
    """)
    assert r["a"] == "on" and r["b"] == "done" and r["c7"] == "on", r
    assert r["complete"] and r["done7"] == "done", r
    assert "Kobold Camp Cleanup" in logtext(c), logtext(c)[-600:]
    no_errors(w)


@case
def an_old_save_is_archived():
    w, c = game(new=False)
    r = c.eval_py(r"""
      local G = ns.Azero
      local data = G:Data()
      data.save = { v = 1, map = "town", x = 3, y = 3, party = {}, box = {}, bag = {}, flags = {}, seen = {}, caught = {} }
      local had = G:HasSave()
      G:NewGame()
      return { had = had, old = data.oldSaves and #data.oldSaves, map = data.save.map }
    """)
    assert r["had"] is False and r["old"] == 1 and r["map"] == "world", r
    no_errors(w)


if __name__ == "__main__":
    run_all()

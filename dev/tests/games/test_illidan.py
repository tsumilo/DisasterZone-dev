"""The Binding of Illidan (Games/Illidan/): the floors, the run, the bosses, the panel.

Covers: every floor of many seeds has a boss at a dead end, a locked vault and a shop, all its rooms reachable, a
secret room touching two rooms that a bomb opens; the same seed gives the same dungeon (the daily seed's promise)
and the same fight; each class starts with its own stats and items; pickups, the vault's key, the shop's prices, a
fel bargain costs a healthstone; the five bosses run their phases (Magtheridon breaks free and Blast Nova is held on
a cube, Supremus swaps tank and kite, Teron's Shadow of Death makes you a spirit and constructs rise, Shahraz ports
you for Fatal Attraction, Illidan's four phases with the Flames tied to their blades and Maiev's trap); a bot plays a
whole run with god mode to the end without an error; the panel: the title, Enter starts, keys move and shoot, Esc
pauses; the hub's poster.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_illidan.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo  # noqa: E402
from _boi_bot import BOT_LUA  # noqa: E402


def boot(cls="MAGE"):
    w, c = solo("Alice", class_file=cls)
    c.world = w
    c.eval(BOT_LUA)
    return w, c


def new_run(c, seed=12345, cls="MAGE"):
    c.eval("T_BOI.run = ns.BoI.New({ class = ..., seed = ... }) T_BOI.run.mode = 'play'", cls, seed)


@case
def floors_have_a_boss_a_vault_a_shop_and_every_room_reachable():
    w, c = boot()
    bad = c.eval_py(r"""
      local E, out = ns.BoI, {}
      for seed = 1, 40 do
        local run = E.New({ class = 'MAGE', seed = seed * 977 })
        for n = 1, 5 do
          local map = E.GenFloor(run, n)
          local kinds = {}
          for _, r in ipairs(map.list) do kinds[r.type] = (kinds[r.type] or 0) + 1 end
          if kinds.boss ~= 1 or kinds.treasure ~= 1 or kinds.shop ~= 1 then out[#out + 1] = 'kinds ' .. seed .. '/' .. n end
          for _, r in ipairs(map.list) do
            if r.type == 'boss' and #E.Neighbours(map, r, true) ~= 1 then out[#out + 1] = 'boss not a dead end ' .. seed end
            if r.type == 'secret' and #E.Neighbours(map, r, true) < 2 then out[#out + 1] = 'secret ' .. seed end
          end
          -- reachable through doors (the secret room aside)
          local seen, q, qi = { [map.start] = true }, { map.start }, 1
          while q[qi] do
            for _, nb in ipairs(E.Neighbours(map, q[qi])) do
              if not seen[nb.room] then seen[nb.room] = true q[#q + 1] = nb.room end
            end
            qi = qi + 1
          end
          for _, r in ipairs(map.list) do
            if r.type ~= 'secret' and not seen[r] then out[#out + 1] = 'unreachable ' .. seed .. '/' .. n end
          end
          if #map.list < 7 + n * 2 then out[#out + 1] = 'small ' .. seed .. '/' .. n end
        end
      end
      return out
    """)
    assert bad == [], bad[:10]


@case
def the_same_seed_gives_the_same_dungeon_and_the_same_fight():
    w, c = boot()
    sig = r"""
      local E = ns.BoI
      local run = E.New({ class = 'ROGUE', seed = ... })
      local s = {}
      for n = 1, 5 do
        local map = E.GenFloor(run, n)
        for _, r in ipairs(map.list) do s[#s + 1] = r.x .. r.y .. r.type end
      end
      run.mode = 'play'
      T_BOI.Fight(run, 2)
      T_BOI.Play(run, 1500)
      s[#s + 1] = string.format('%.3f %.3f %.3f %d', run.p.x, run.p.y, run.bossF and run.bossF.hp or -1, run.hp)
      return table.concat(s, ';')
    """
    a = c.eval(sig, 4242)
    b = c.eval(sig, 4242)
    d = c.eval(sig, 4243)
    assert a == b
    assert a != d


@case
def each_class_starts_with_its_own_stats_and_items():
    w, c = boot()
    got = c.eval_py(r"""
      local out = {}
      for _, cls in ipairs(ns.BoIData.CLASS_ORDER) do
        local run = ns.BoI.New({ class = cls, seed = 7 })
        out[cls] = { hp = run.hp, soul = run.soul, dmg = run.stats.dmg, items = table.concat(run.items, ',') }
      end
      return out
    """)
    assert got["PALADIN"]["hp"] == 8 and got["WARRIOR"]["hp"] == 8
    assert got["PRIEST"]["items"] == "pws" and got["PRIEST"]["soul"] == 2
    assert got["WARLOCK"]["items"] == "imp"
    assert got["SHAMAN"]["items"] == "chain"
    assert got["DRUID"]["items"] == "thorns"
    assert got["HUNTER"]["dmg"] < got["WARRIOR"]["dmg"]


@case
def pickups_the_vault_key_the_shop_and_a_fel_bargain():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      local out = {}
      -- a healthstone is left lying while you are full; taken when hurt
      local room = run.room
      room.pickups = { { kind = 'heart', x = run.p.x, y = run.p.y, t = 0 }, { kind = 'gold', x = run.p.x, y = run.p.y, t = 0 } }
      E.Step(run, {})
      out.heartLeft = #room.pickups
      out.gold = run.gold
      run.hp = run.hp - 2
      E.Step(run, {})
      out.heartTaken = #room.pickups
      -- the vault: locked; a key opens it
      local vault
      for _, r in ipairs(run.map.list) do if r.type == 'treasure' then vault = r end end
      out.locked = vault.locked and true or false
      local nb = E.Neighbours(run.map, vault, true)[1]
      run.room = nb.room run.room.cleared = true
      local dp = E.DOOR[E.OPP[nb.dir]]
      run.p.x, run.p.y = dp[1], dp[2]
      local keys = run.keys
      E.Step(run, {})
      out.keyUsed = keys - run.keys
      E.Step(run, { mx = E.DIRS[E.OPP[nb.dir]][1], my = E.DIRS[E.OPP[nb.dir]][2] })
      out.inVault = run.room == vault
      -- the shop: too poor, then rich enough
      local shop
      for _, r in ipairs(run.map.list) do if r.type == 'shop' then shop = r end end
      run.room = shop
      run.gold = 2
      local s = shop.shop[3]
      run.p.x, run.p.y = s.x, s.y
      E.Step(run, {})
      out.poorSold = s.sold or false
      run.gold = 20
      E.Step(run, {})
      out.sold, out.goldLeft, out.gotItem = s.sold, run.gold, run.has[s.item] or run.active == s.item
      -- a fel bargain: one healthstone container
      local max0 = run.maxHp
      run.room.deal = { kind = 'bargain', item = 'blade', price = 1, x = run.p.x, y = run.p.y }
      E.Step(run, {})
      out.maxDrop, out.blade, out.bargained = max0 - run.maxHp, run.has.blade or false, run.tookBargain
      return out
    """)
    assert out["heartLeft"] == 1 and out["gold"] == 4, out
    assert out["heartTaken"] == 0, out
    assert out["locked"] and out["keyUsed"] == 1 and out["inVault"], out
    assert out["poorSold"] is False and out["sold"] and out["goldLeft"] == 5 and out["gotItem"], out
    assert out["maxDrop"] == 1 and out["blade"] and out["bargained"], out


@case
def magtheridon_breaks_free_and_a_cube_holds_blast_nova():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      run.god = true
      local f = T_BOI.Fight(run, 1)
      local out = { banished = f.immune and true or false, chans = 0 }
      for _, x in ipairs(run.room.foes) do if x.kind == 'mchan' then out.chans = out.chans + 1 end end
      for _ = 1, 2410 do E.Step(run, {}) end
      out.freeByTime = f.phase == 2 and not f.immune
      f.nova = 1
      E.Step(run, {})
      out.casting = run.cast and run.cast.name
      local cube = run.cubes[1]
      run.p.x, run.p.y = cube.x, cube.y
      for _ = 1, 60 do run.p.x, run.p.y = cube.x, cube.y E.Step(run, {}) end
      out.held = run.cast == nil and cube.ex == 2
      -- the next Nova: that cube is still exhausted
      f.nova = 1
      E.Step(run, {})
      out.exhausted = cube.ex
      f.hp = f.max * 0.29
      E.Step(run, {})
      out.collapse = f.phase == 3 and #run.hz > 0
      return out
    """)
    assert out["banished"] and out["chans"] == 5, out
    assert out["freeByTime"], out
    assert out["casting"] == "Blast Nova", out
    assert out["held"], out
    assert out["exhausted"] == 1, out
    assert out["collapse"], out


@case
def supremus_swaps_tank_and_kite():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      run.god = true
      local f = T_BOI.Fight(run, 2)
      local out = { first = f.mode }
      for _ = 1, 125 do E.Step(run, {}) end
      out.flames = #run.mflames
      f.sw = 1
      E.Step(run, {})
      out.second, out.emote = f.mode, run.say and run.say.text
      for _ = 1, 200 do E.Step(run, {}) end
      out.volcanoes = #run.volcs + #run.hz
      return out
    """)
    assert out["first"] == "tank" and out["flames"] > 0, out
    assert out["second"] == "kite" and out["emote"] == "The ground begins to crack open!", out
    assert out["volcanoes"] > 0, out


@case
def teron_makes_you_a_spirit_and_constructs_rise():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      local f = T_BOI.Fight(run, 3)
      f.sodT = 1
      E.Step(run, {})
      local out = { marked = run.sod }
      for _ = 1, 301 do E.Step(run, {}) end
      out.spirit = run.spirit
      local n, solid = 0, 0
      for _, x in ipairs(run.room.foes) do if x.kind == 'construct' then n = n + 1 if not x.spiritOnly then solid = solid + 1 end end end
      out.constructs, out.solid = n, solid
      -- nothing hurts a spirit
      local hp = run.hp
      E.Hurt(run, { n = 'test' }, 2)
      out.hurt = hp - run.hp
      -- a normal bolt passes a construct; a spirit's does not
      for _ = 1, 700 do E.Step(run, {}) end
      out.back = run.spirit == nil
      return out
    """)
    assert out["marked"] == 300, out
    assert out["spirit"] and out["constructs"] == 4 and out["solid"] == 0, out
    assert out["hurt"] == 0, out
    assert out["back"], out


@case
def shahraz_beams_and_fatal_attraction():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      run.god = true
      local f = T_BOI.Fight(run, 4)
      for _ = 1, 130 do E.Step(run, {}) end
      local out = { beams = #run.beams }
      f.fatal = 1
      local x0, y0 = run.p.x, run.p.y
      E.Step(run, {})
      out.ported = (run.p.x ~= x0 or run.p.y ~= y0)
      out.blasts = #run.hz
      f.hp = f.max * 0.09
      E.Step(run, {})
      out.frenzy = f.frenzy
      return out
    """)
    assert out["beams"] >= 1, out
    assert out["ported"] and out["blasts"] >= 3, out
    assert out["frenzy"], out


@case
def illidan_goes_through_four_phases():
    w, c = boot()
    new_run(c)
    out = c.eval_py(r"""
      local E, run = ns.BoI, T_BOI.run
      run.god = true
      local f = T_BOI.Fight(run, 5)
      local out = {}
      f.hp = f.max * 0.64
      E.Step(run, {})
      local flames = {}
      for _, x in ipairs(run.room.foes) do if x.kind == 'azflame' then flames[#flames + 1] = x end end
      out.p2, out.immune, out.flames = f.phase, f.immune, #flames
      -- a Flame pulled far from its blade enrages
      flames[1].x, flames[1].y = flames[1].blade.x + 300, flames[1].blade.y
      flames[1].x = math.min(flames[1].x, E.X1 - 30)
      flames[1].blade.x = E.X0 + 40
      E.Step(run, {})
      out.enraged = flames[1].enraged
      for _, fl in ipairs(flames) do fl.hp = 0 end
      E.Step(run, {})
      E.Step(run, {})
      out.p3 = f.phase
      f.demonT = 1
      E.Step(run, {})
      out.demon = f.demon > 0
      local demons = 0
      for _, x in ipairs(run.room.foes) do if x.kind == 'sdemon' then demons = demons + 1 end end
      out.demons = demons
      f.demon = 1
      E.Step(run, {})
      f.hp = f.max * 0.29
      E.Step(run, {})
      out.p4, out.maiev = f.phase, run.maiev ~= nil
      run.maiev.trap = 1
      E.Step(run, {})
      local t = run.traps[1]
      for _ = 1, 45 do E.Step(run, {}) end
      f.x, f.y = t.x, t.y
      E.Step(run, {})
      out.caged = f.caged
      return out
    """)
    assert out["p2"] == 2 and out["immune"] and out["flames"] == 2, out
    assert out["enraged"], out
    assert out["p3"] == 3, out
    assert out["demon"] and out["demons"] == 2, out
    assert out["p4"] == 4 and out["maiev"], out
    assert out["caged"] and out["caged"] > 0, out


@case
def a_bot_plays_a_whole_run_with_god_mode():
    w, c = boot("WARLOCK")
    new_run(c, seed=99, cls="WARLOCK")
    out = c.eval_py(r"""
      local run = T_BOI.run
      run.god = true
      run.mode = 'floorcard'
      local floors = {}
      local last = 0
      for _ = 1, 400 do
        T_BOI.Play(run, 600)
        if run.floorN ~= last then floors[#floors + 1] = run.floorN last = run.floorN end
        if run.mode == 'won' then break end
      end
      return { mode = run.mode, floor = run.floorN, floors = floors, kills = run.kills, minutes = run.time / 3600 }
    """)
    assert out["mode"] == "won", out
    assert out["floors"] == [1, 2, 3, 4, 5], out


@case
def the_panel_starts_a_run_moves_shoots_and_pauses():
    w, c = boot("PRIEST")
    c.eval("ns.Games:Open('illidan')")
    w.tick(1.5)
    assert c.eval("return ns.GamesUI:GetSelected()") == "illidan"
    assert c.eval("return ns.BoIUI._Run()") is None
    c.eval("ns.BoIUI._Focus(true) ns.BoIUI._Key('ENTER')")
    assert c.eval("return ns.BoIUI._Run() ~= nil")
    assert c.eval("return ns.BoIUI._Run().class") == "PRIEST"
    w.tick(3.0)  # the floor's card
    assert c.eval("return ns.BoIUI._Run().mode") == "play"
    x0 = c.eval("return ns.BoIUI._Run().p.x")
    c.eval("ns.BoIUI._Key('D') ns.BoIUI._Key('UP')")
    w.tick(0.5)
    st = c.eval_py("local r = ns.BoIUI._Run() return { x = r.p.x, tears = #r.tears, face = r.p.face }")
    assert st["x"] > x0 + 20, st
    assert st["face"] == "up", st
    c.eval("ns.BoIUI._Key('D', true) ns.BoIUI._Key('UP', true) ns.BoIUI._Key('ESCAPE')")
    t0 = c.eval("return ns.BoIUI._Run().time")
    w.tick(0.5)
    assert c.eval("return ns.BoIUI._Run().time") == t0
    # the room and its tokens are drawn
    n = c.eval("local n = 0 for _, o in ipairs(ns.BoIUI._Pools().token.items) do if o.pic:IsShown() then n = n + 1 end end return n")
    assert n >= 1


@case
def death_slows_the_room_then_the_card_holds_the_restart_back():
    w, c = boot()
    c.eval("ns.Games:Open('illidan')")
    w.tick(1.0)
    out = c.eval_py(r"""
      local E, UI = ns.BoI, ns.BoIUI
      UI._Focus(true)
      UI._Key('ENTER')
      local run = UI._Run()
      run.mode = 'play'
      for _, nb in ipairs(E.Neighbours(run.map, run.room)) do if nb.room.type == 'normal' then E.ChangeRoom(run, nb.dir) break end end
      run.mode = 'play'
      local foe = run.room.foes[1]
      foe.x, foe.y = run.p.x + 20, run.p.y
      run.hp, run.soul, run.p.inv = 1, 0, 0
      E.Hurt(run, foe.d)
      local out = { mode = run.mode, killer = run.killer, marked = run.killerFoe == foe }
      -- slow motion: the foe moves on only every third frame, then the room holds
      local x0 = foe.t
      E.Step(run, {}) E.Step(run, {}) E.Step(run, {})
      out.slow = foe.t - x0
      for _ = 1, 80 do E.Step(run, {}) end
      local t1 = foe.t
      for _ = 1, 20 do E.Step(run, {}) end
      out.held = foe.t - t1
      while run.mode == 'dying' do E.Step(run, {}) end
      out.after = run.mode
      UI._Key('R')
      out.earlyR = UI._Run() == run
      return out
    """)
    assert out["mode"] == "dying" and out["marked"], out
    assert out["slow"] == 1 and out["held"] == 0, out
    assert out["after"] == "dead" and out["earlyR"], out
    w.tick(1.5)   # the panel steps the card's own clock; R works after a second
    assert c.eval("return ns.BoIUI._Run().deadT > 60")
    assert c.eval("return ns.Games:PeekData('illidan').last.killer") == c.eval("return ns.BoIUI._Run().killer")
    c.eval("ns.BoIUI._Key('R')")
    assert c.eval("return ns.BoIUI._Run().mode") == "floorcard"


def guild(*names):
    from _common import World, Client
    w = World()
    cs = [Client(w, n, guild_rank=3, class_file=cls) for n, cls in names]
    for x in cs:
        x.load_addon()
    w.tick(3)
    for x in cs:
        x.eval(BOT_LUA)
    return w, cs


DIE_DAILY = r"""
  -- a daily run that dies in the second room of floor 1 (a counted try, unless spent)
  local E, run = ns.BoI, ns.BoIGame:NewRun(..., true)
  run.mode = 'play'
  for _, nb in ipairs(E.Neighbours(run.map, run.room)) do if nb.room.type == 'normal' then E.ChangeRoom(run, nb.dir) break end end
  run.mode = 'play'
  run.p.x, run.p.y = 300, 200
  run.hp, run.soul, run.p.inv = 1, 0, 0
  E.Hurt(run, run.room.foes[1].d)
  while run.mode == 'dying' do E.Step(run, {}) end
  T_BOI.died = run
  return { counted = run.counted, room = { run.room.x, run.room.y }, seed = run.seed }
"""


@case
def todays_dungeon_is_the_guilds_and_only_the_first_try_counts():
    w, (a, b) = guild(("Alice", "MAGE"), ("Bob", "ROGUE"))
    day = a.eval("return ns.BoIBoard:Today()")
    assert len(day) == 10 and day[4] == "-", day
    assert a.eval("return ns.BoIBoard:Seed()") == b.eval("return ns.BoIBoard:Seed()")
    first = a.eval_py(DIE_DAILY, "MAGE")
    assert first["counted"] is True
    again = a.eval_py("local r = ns.BoIGame:NewRun('MAGE', true) return { counted = r.counted, seed = r.seed }")
    assert again["counted"] is False and again["seed"] == first["seed"]
    # Bob's dungeon is the same one (another class)
    same = b.eval_py("""
      local r = ns.BoIGame:NewRun('ROGUE', true)
      local s = {}
      for _, x in ipairs(r.map.list) do s[#s + 1] = x.x .. ',' .. x.y .. x.type end
      return table.concat(s, ';')
    """)
    mine = a.eval_py("""
      local s = {}
      for _, x in ipairs(T_BOI.died.map.list) do s[#s + 1] = x.x .. ',' .. x.y .. x.type end
      return table.concat(s, ';')
    """)
    assert same == mine


@case
def a_result_goes_round_the_guild_and_leaves_a_grave_there():
    w, (a, b) = guild(("Alice", "MAGE"), ("Bob", "ROGUE"))
    died = a.eval_py(DIE_DAILY, "MAGE")
    w.tick(2)
    row = b.eval_py("local l = ns.BoIBoard:Board() return l[1] and { name = l[1].name, f = l[1].e.f, by = l[1].e.by, n = #l }")
    assert row and row["name"] == "Alice" and row["f"] == 1 and row["n"] == 1, row
    # Bob's run of today's dungeon finds the grave in that room; stepping on it tells the story and gives a gold
    out = b.eval_py(r"""
      local E, run = ns.BoI, ns.BoIGame:NewRun('ROGUE', true)
      local g = run.graves[1]
      local out = { graves = #run.graves, who = g and g.who, f = g and g.f }
      run.mode = 'play'
      run.room = run.map.rooms[g.rx .. ',' .. g.ry]
      run.room.cleared, run.room.foes = true, {}
      out.here = #E.GravesHere(run)
      local gold = run.gold
      run.p.x, run.p.y = g.x, g.y
      E.Step(run, {})
      out.gold, out.toast = run.gold - gold, run.toast and run.toast.t
      return out
    """)
    assert out["graves"] == 1 and out["who"] == "Alice" and out["here"] == 1, out
    assert out["gold"] == 1 and "Alice fell here" in out["toast"], out
    # Alice does not see her own grave
    assert a.eval("return #ns.BoIBoard:Graves(ns.BoIBoard:Today())") == 0


@case
def someone_who_missed_it_catches_up_by_asking():
    w, (a, b, c) = guild(("Alice", "MAGE"), ("Bob", "ROGUE"), ("Cara", "PRIEST"))
    a.eval_py(DIE_DAILY, "MAGE")
    b.eval_py(DIE_DAILY, "ROGUE")
    w.tick(2)
    # Cara was not listening: her board is cleared, she asks, one of them answers
    c.eval("ns.Games:GetData('illidan').board = {}")
    assert c.eval("return ns.BoIBoard:Count()") == 0
    c.eval("ns.BoIBoard:Ask()")
    w.tick(5)
    assert c.eval("return ns.BoIBoard:Count()") == 2


@case
def the_board_ranks_wins_by_time_then_depth_and_refuses_nonsense():
    w, c = boot()
    out = c.eval_py(r"""
      local B, day = ns.BoIBoard, ns.BoIBoard:Today()
      local realm = '-' .. ns.Util.GetPlayerRealm()
      B._Store(day, 'Slow' .. realm, { c = 'MAGE', f = 5, w = true, t = 900, k = 50, i = 6 })
      B._Store(day, 'Fast' .. realm, { c = 'ROGUE', f = 5, w = true, t = 600, k = 40, i = 4 })
      B._Store(day, 'Deep' .. realm, { c = 'PRIEST', f = 4, t = 800, k = 30, i = 3, by = 'Mother Shahraz' })
      B._Store(day, 'Shallow' .. realm, { c = 'HUNTER', f = 2, t = 100, k = 5, i = 1 })
      local bad = {
        B._Store(day, 'X' .. realm, { c = 'NOPE', f = 2 }),
        B._Store(day, 'Y' .. realm, { c = 'MAGE', f = 9 }),
        B._Store('yesterday', 'Z' .. realm, { c = 'MAGE', f = 2 }),
        B._Store(day, 'Fast' .. realm, { c = 'ROGUE', f = 5, w = true, t = 1 }),   -- a second result: the first stays
      }
      local names = {}
      for i, r in ipairs(B:Board()) do names[i] = r.name end
      return { names = names, bad = bad, fast = B:Board()[1].e.t, text = B:ResultText(B:Board()[3].e) }
    """)
    assert out["names"] == ["Fast", "Slow", "Deep", "Shallow"], out
    assert out["bad"] == [False, False, False, False], out
    assert out["fast"] == 600
    assert out["text"].startswith("Floor 4"), out


@case
def the_title_shows_todays_board_and_enter_or_n_start_a_run():
    w, c = boot("HUNTER")
    c.eval(r"""
      local day = ns.BoIBoard:Today()
      ns.BoIBoard._Store(day, 'Xiavor-' .. ns.Util.GetPlayerRealm(), { c = 'MAGE', f = 5, w = true, t = 702, k = 61, i = 7 })
    """)
    c.eval("ns.Games:Open('illidan')")
    w.tick(1.0)
    c.eval("ns.BoIUI._Focus(true) ns.BoIUI._Draw()")
    texts = c.eval_py("local t = {} for _, fs in pairs(ns.BoIUI._Hud()) do if type(fs) == 'table' and fs.IsShown and fs:IsShown() then t[#t + 1] = fs:GetText() end end return t")
    assert "Xiavor" in texts and "Won 11:42" in texts, texts
    assert any("today's dungeon (your try counts)" in x for x in texts), texts
    c.eval("ns.BoIUI._Key('N')")
    assert c.eval("return ns.BoIUI._Run().daily") is None
    c.eval("ns.BoIUI._SetRun(nil) ns.BoIUI._Key('ENTER')")
    assert c.eval("return ns.BoIUI._Run().daily") == c.eval("return ns.BoIBoard:Today()")
    assert c.eval("return ns.BoIUI._Run().counted") is True
    c.eval("ns.MainFrame:Open('games')")
    w.tick(0.5)
    foot = c.eval("for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'illidan' then return p.footText and p.footText:GetText() end end")
    assert foot and "Xiavor Won 11:42" in foot, foot


@case
def a_finished_run_is_recorded_and_the_poster_shows_it():
    w, c = boot()
    out = c.eval_py(r"""
      local run = ns.BoIGame:NewRun('MAGE')
      run.floorN, run.mode, run.time, run.items = 3, 'dead', 3600, { 'eye' }
      run.killer = 'Teron Gorefiend'
      ns.BoIGame:Finished(run)
      local d = ns.Games:PeekData('illidan')
      return { best = d.best, eye = d.items.eye, line = ns.BoIGame:BestLine() }
    """)
    assert out["best"] == 3 and out["eye"], out
    assert "Gorefiend" in out["line"], out
    c.eval("ns.MainFrame:Open('games')")
    w.tick(0.5)
    stat = c.eval("for _, p in ipairs(ns.GamesUI.__posters) do if p.id == 'illidan' then return p.stat:GetText() end end")
    assert stat and "Gorefiend" in stat, stat


if __name__ == "__main__":
    run_all()

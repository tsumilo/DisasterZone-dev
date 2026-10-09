"""Disastercraft (Games/Disastercraft): the WoW-like game on the real Northshire map - the engine without the UI.

Covers: the generated data; a new character of each class (start gear, bags, action bar, WoW's level-1 health and
mana); WoW's experience formulas; a warrior's fight with a Kobold Vermin (auto attack, rage, the kill's experience,
loot); a mage's Fireball (cast time, mana, the missile, its burn); aggro range, social pulls and evade; quests from
accept to turn-in (kill credit, quest drops in the bags, the reward choice, the experience); trainers; vendors;
death, the ghost run and coming back; leveling up; the Abbey door.

Run: luaenv\\Scripts\\python.exe tests\\games\\test_craft.py [-k name]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(TESTS, "boot-ui"))
sys.path.insert(0, HERE)

from _common import case, run_all, solo, no_errors  # noqa: E402

HELPER = r"""
T_DC = {}
local Craft = ns.Craft
local seed = 1
Craft.rng = function(a, b)
  seed = (seed * 1103515245 + 12345) % 2147483648
  local f = seed / 2147483648
  if a == nil then return f end
  if b == nil then a, b = 1, a end
  return a + math.floor(f * (b - a + 1))
end
function T_DC.seed(n) seed = n end
local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function(_, dt) if T_DC.on then Craft:Update(dt) end end)
driver:Show()
T_DC.msgs, T_DC.errors, T_DC.notices = {}, {}, {}
Craft:On("msg", function(t) T_DC.msgs[#T_DC.msgs + 1] = t end)
Craft:On("error", function(t) T_DC.errors[#T_DC.errors + 1] = t end)
Craft:On("notice", function(t) T_DC.notices[#T_DC.notices + 1] = t end)
function T_DC.start(cls, sex)
  Craft:NewCharacter(cls, sex or 0)
  Craft:Login(cls)
  Craft.World.Enter(Craft.char)
  T_DC.on = true
  return Craft.player
end
-- the nearest living spawn of `entry` to the player (or to a point)
function T_DC.find(entry, map)
  local p = Craft.player
  local best, bd
  for _, rec in pairs(Craft.World.recs) do
    local u = rec.unit
    if u and u.entry == entry and not u.dead and (map == 'any' or u.map == (map or p.map)) then
      local d = (u.x - p.x) ^ 2 + (u.y - p.y) ^ 2
      if not bd or d < bd then best, bd = u, d end
    end
  end
  return best
end
-- puts the player `yd` yards west of unit u (on a walkable spot nearby)
function T_DC.near(u, yd)
  local p = Craft.player
  local W = Craft.World
  for r = 0, 6 do
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local x, y = u.x + o[1] * (yd / Craft.YARDS) + o[1] * r * 0.3, u.y + o[2] * (yd / Craft.YARDS) + o[2] * r * 0.3
      if W.Fits(u.map, x, y) then p.map, p.x, p.y = u.map, x, y return true end
    end
  end
  p.map, p.x, p.y = u.map, u.x - yd / Craft.YARDS, u.y
  return false
end
-- other creatures stay out of a test fight
function T_DC.calm(except)
  for _, rec in pairs(Craft.World.recs) do
    if rec.unit and rec.unit ~= except then rec.unit.hostile = false end
  end
end
"""


def game(cls=1, seed=7, sex=0):
    w, c = solo("Alice", tick=2)
    c.eval(HELPER)
    c.eval("T_DC.seed(%d)" % seed)
    c.eval("T_DC.start(%d, %d)" % (cls, sex))
    return w, c


@case
def data_loads():
    w, c = solo("Alice", tick=2)
    r = c.eval_py(r"""
      local D = ns.CraftData
      local n = { spells = 0, items = 0, creatures = 0 }
      for _ in pairs(D.spells) do n.spells = n.spells + 1 end
      for _ in pairs(D.items) do n.items = n.items + 1 end
      for _ in pairs(D.creatures) do n.creatures = n.creatures + 1 end
      return { n = n, fireball = D.spells[133].n, sword = D.items[25].n, vermin = D.creatures[6].n,
               xp1 = D.xp[1], xp2 = D.xp[2], warriorBar = D.classes[1].bar[2][2], gy = #D.graveyards }
    """)
    assert r["n"]["spells"] > 60 and r["n"]["items"] > 200 and r["n"]["creatures"] > 30, r
    assert r["fireball"] == "Fireball" and r["sword"] == "Worn Shortsword" and r["vermin"] == "Kobold Vermin", r
    assert r["xp1"] == 400 and r["xp2"] == 900, r
    assert r["warriorBar"] == 78 and r["gy"] == 1, r
    no_errors(w)


@case
def new_characters_start_like_wow():
    for cls, hp, power in ((1, 60, 1000), (8, 52, 165), (5, 72, 123)):
        w, c = game(cls)
        r = c.eval_py(r"""
          local p, c = ns.Craft.player, ns.Craft.char
          local bag = {}
          for s = 1, 16 do local x = c.bags[0][s] if x then bag[#bag + 1] = x.id end end
          return { hp = p.hp, hpMax = p.hpMax, pmax = p.powerMax, power = p.power, mh = c.equip[16], chest = c.equip[5],
                   bag = bag, bar1 = c.bar[1] and c.bar[1][2], bar2 = c.bar[2] and c.bar[2][2], map = p.map,
                   x = math.floor(p.x), y = math.floor(p.y), name = c.name, area = ns.Craft.World.areaName }
        """)
        assert r["hpMax"] == hp and r["hp"] == hp, (cls, r)
        assert r["pmax"] == power, (cls, r)
        assert r["mh"], r
        assert 6948 in r["bag"], r                      # the hearthstone
        assert r["bar1"] == 6603, r                      # Attack
        assert (r["x"], r["y"]) == (4127, 6243), r
        assert r["area"] == "Northshire Valley", r
        no_errors(w)


@case
def experience_formulas_match_wow():
    w, c = solo("Alice", tick=2)
    r = c.eval_py(r"""
      local C = ns.Craft
      return { same = C.KillXP(1, 1), above = C.KillXP(1, 3), below = C.KillXP(6, 4), gray = C.KillXP(10, 3),
               q7 = C.QuestXP(1, 2, 90), q7high = C.QuestXP(9, 2, 90), elite = C.KillXP(5, 5, true) }
    """)
    assert r["same"] == 50, r
    assert r["above"] == 55, r          # +2 levels: (50*22/10+1) / 2
    assert r["gray"] == 0, r
    assert r["elite"] == 2 * 70, r
    assert r["q7"] == 150, r            # Kobold Camp Cleanup: 90 / 0.6
    assert r["q7high"] < r["q7"], r
    no_errors(w)


@case
def warrior_kills_a_kobold_vermin():
    w, c = game(1)
    c.eval(r"""
      local u = T_DC.find(6)
      T_DC.calm(u)
      T_DC.mob = u
      T_DC.near(u, 3)
      ns.Craft.World.SetTarget(u)
      ns.Craft.Combat.StartAttack(ns.Craft.player, u)
    """)
    w.run_until(lambda: c.eval_py("return T_DC.mob.dead"), timeout=60)
    r = c.eval_py(r"""
      local p, c = ns.Craft.player, ns.Craft.char
      return { xp = c.xp, rage = p.power, hp = p.hp, loot = T_DC.mob.rec.loot ~= nil, msgs = T_DC.msgs,
               state = T_DC.mob.rec.state }
    """)
    assert r["xp"] >= 40, r
    assert r["state"] == "dead", r
    assert any("dies, you gain" in m for m in r["msgs"]), r["msgs"]
    no_errors(w)


@case
def warrior_gains_rage_and_heroic_strike_uses_it():
    w, c = game(1, seed=3)
    c.eval(r"""
      local u = T_DC.find(257)
      T_DC.calm(u)
      T_DC.mob = u
      T_DC.near(u, 3)
      ns.Craft.World.SetTarget(u)
      ns.Craft.Combat.StartAttack(ns.Craft.player, u)
    """)
    w.run_until(lambda: c.eval_py("return ns.Craft.player.power >= 150 or T_DC.mob.dead"), timeout=40)
    r = c.eval_py(r"""
      local p = ns.Craft.player
      local before = p.power
      ns.Craft.Combat.CastSpell(p, 78)
      return { before = before, queued = p.nextSwing }
    """)
    if r["queued"]:
        w.run_until(lambda: c.eval_py("return ns.Craft.player.nextSwing == nil"), timeout=5)
        after = c.eval_py("return ns.Craft.player.power")
        assert after < r["before"] + 100, (r, after)
    no_errors(w)


@case
def mage_fireball_casts_flies_and_burns():
    w, c = game(8)
    c.eval(r"""
      local u = T_DC.find(6)
      T_DC.calm(u)
      T_DC.mob = u
      T_DC.near(u, 20)
      ns.Craft.World.SetTarget(u)
      T_DC.mana = ns.Craft.player.power
      T_DC.hp = u.hp
      T_DC.ok = ns.Craft.Combat.CastSpell(ns.Craft.player, 133)
    """)
    r = c.eval_py("return { ok = T_DC.ok, casting = ns.Craft.player.casting ~= nil }")
    assert r["ok"] and r["casting"], r
    w.tick(1.0)
    assert c.eval_py("return T_DC.mob.hp") == c.eval_py("return T_DC.hp"), "no damage before the cast ends"
    w.tick(2.0)
    r = c.eval_py(r"""
      local p, u = ns.Craft.player, T_DC.mob
      return { mana = p.power, start = T_DC.mana, hp = u.hp, hp0 = T_DC.hp, dead = u.dead == true, aura = #u.auras }
    """)
    assert r["mana"] <= r["start"] - 30 + 20, r     # 30 mana (some regen may tick)
    assert r["dead"] or r["hp"] < r["hp0"], r
    no_errors(w)


@case
def out_of_range_and_no_mana_errors():
    w, c = game(8)
    r = c.eval_py(r"""
      local u = T_DC.find(6)
      T_DC.calm(u)
      T_DC.near(u, 60)
      ns.Craft.World.SetTarget(u)
      local ok1 = ns.Craft.Combat.CastSpell(ns.Craft.player, 133)
      T_DC.near(u, 15)
      ns.Craft.player.power = 5
      local ok2 = ns.Craft.Combat.CastSpell(ns.Craft.player, 133)
      return { ok1 = ok1, ok2 = ok2, errors = T_DC.errors }
    """)
    assert r["ok1"] is False and r["ok2"] is False, r
    assert "Out of range." in r["errors"] and "Not enough mana" in r["errors"], r
    no_errors(w)


@case
def hostile_mob_aggroes_and_evades_when_dragged_away():
    w, c = game(1)
    c.eval(r"""
      local u = T_DC.find(6)
      T_DC.calm(u)
      u.hostile = true
      T_DC.mob = u
      T_DC.near(u, 8)
    """)
    w.run_until(lambda: c.eval_py("return T_DC.mob.rec.state == 'combat'"), timeout=5)
    # run far away: it gives up and goes home at full health
    c.eval(r"""
      local u = T_DC.mob
      local p = ns.Craft.player
      p.x, p.y = u.homeX, u.homeY + 30
      u.x, u.y = u.homeX, u.homeY + 16
    """)
    w.run_until(lambda: c.eval_py("return T_DC.mob.rec.state == 'idle' or T_DC.mob.rec.state == 'return'"),
                timeout=40)
    r = c.eval_py("return { hp = T_DC.mob.hp, max = T_DC.mob.hpMax, combat = ns.Craft.player.inCombat }")
    assert r["hp"] == r["max"], r
    no_errors(w)


@case
def quest_from_accept_to_turn_in():
    w, c = game(1)
    r = c.eval_py(r"""
      local Q, Craft = ns.Craft.Quests, ns.Craft
      local done, going, offer = Q.ForNpc(823)     -- Deputy Willem
      local titles = {}
      for _, q in ipairs(offer) do titles[#titles + 1] = q.title end
      Q.Accept(783)                                -- A Threat Within (talk to McBride: done at once)
      local ok = Q.TurnIn(783)
      Q.Accept(7)                                  -- Kobold Camp Cleanup
      return { titles = titles, ok = ok, xp = Craft.char.xp, on = Craft.char.quests[7] ~= nil,
               marker = Q.Marker(197) }
    """)
    assert "A Threat Within" in r["titles"], r
    assert r["ok"] and r["xp"] > 0 and r["on"], r
    # ten kills
    c.eval(r"""
      for i = 1, 10 do ns.Craft.Quests.OnKill({ entry = 6, cr = ns.CraftData.creatures[6] }) end
    """)
    r = c.eval_py(r"""
      local Q, Craft = ns.Craft.Quests, ns.Craft
      local xp0, money0 = Craft.char.xp, Craft.char.money
      local complete = Q.Complete(7)
      local ok = Q.TurnIn(7)
      return { complete = complete, ok = ok, xp = Craft.char.xp - xp0, lvl = Craft.char.level,
               money = Craft.char.money - money0, done = Craft.char.done[7], notices = T_DC.notices }
    """)
    assert r["complete"] and r["ok"] and r["done"], r
    assert r["money"] == 25, r
    assert "Kobold Vermin slain: 10/10" in r["notices"], r
    no_errors(w)


@case
def quest_drops_land_in_the_bags():
    w, c = game(1)
    r = c.eval_py(r"""
      local Q, Craft = ns.Craft.Quests, ns.Craft
      Craft.char.done[783], Craft.char.done[5261] = true, true
      Q.Accept(33)                                  -- Wolves Across the Border: Tough Wolf Meat
      local needs = Q.NeedsItem(750)
      Craft.Items.Add(750, 8, "loot")
      return { needs = needs, complete = Q.Complete(33), count = Craft.Items.Count(750) }
    """)
    assert r["needs"] and r["complete"] and r["count"] == 8, r
    r = c.eval_py(r"""
      local Q, Craft = ns.Craft.Quests, ns.Craft
      local x = Q.Extra(33)
      local nChoice = x.choice and #x.choice or 0
      local ok = Q.TurnIn(33, nChoice > 0 and 1 or nil)
      return { ok = ok, left = Craft.Items.Count(750), nChoice = nChoice }
    """)
    assert r["ok"] and r["left"] == 0, r
    no_errors(w)


@case
def loot_table_rolls_and_takes():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local u = T_DC.find(38) or T_DC.find(6)
      local seenItem, money = false, 0
      for i = 1, 40 do
        local l = Craft.Loot.Generate(u, function() return false end)
        if #l.items > 0 then seenItem = true end
        money = money + l.money
      end
      return { seenItem = seenItem, money = money }
    """)
    assert r["seenItem"] and r["money"] > 0, r
    no_errors(w)


@case
def trainer_teaches_at_level_and_price():
    w, c = game(8)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local u = T_DC.find(198, 'any')       -- Khelden Bremen (in the Abbey)
      local list = Craft.Npc.TrainerList(u)
      local states = {}
      for _, x in ipairs(list) do states[ns.CraftData.spells[x.spell].n .. (x.level)] = x.state end
      local poor = Craft.Npc.Learn(1459, 10)        -- no money yet
      Craft:AddMoney(500, "silent")
      local ok = Craft.Npc.Learn(1459, 10)
      return { states = states, poor = poor, ok = ok, known = Craft.char.spells[1459] == true, money = Craft.char.money }
    """)
    assert r["states"].get("Arcane Intellect1") == "available", r
    assert r["states"].get("Frostbolt4") == "unavailable", r
    assert r["poor"] is False and r["ok"] and r["known"] and r["money"] == 490, r
    no_errors(w)


@case
def vendor_buy_sell_buyback():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft, I = ns.Craft, ns.Craft.Items
      Craft:AddMoney(1000, "silent")
      local ok = I.Buy(159, 1)                      -- Refreshing Spring Water (5 for 25 copper)
      local n = I.Count(159)
      local b, s
      for i = 1, 16 do local x = Craft.char.bags[0][i] if x and x.id == 25 then b, s = 0, i end end
      local before = Craft.char.money
      -- sell something that sells: the first non-hearthstone item
      for i = 1, 16 do local x = Craft.char.bags[0][i] if x and ns.CraftData.items[x.id].sell then b, s = 0, i break end end
      local sold = I.Sell(b, s)
      local gained = Craft.char.money - before
      local back = I.BuyBack(1)
      return { ok = ok, n = n, sold = sold, gained = gained, back = back, money = Craft.char.money }
    """)
    assert r["ok"] and r["n"] >= 5, r
    assert r["sold"] and r["gained"] > 0 and r["back"], r
    no_errors(w)


@case
def equip_and_unequip():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft, I = ns.Craft, ns.Craft.Items
      local armor0 = Craft.player.armor
      local ok = I.Unequip(7)                        -- the pants
      local armor1 = Craft.player.armor
      local b, s
      for i = 1, 16 do local x = Craft.char.bags[0][i] if x and ns.CraftData.items[x.id].inv == 7 then b, s = 0, i end end
      local back = b and I.EquipFromBag(b, s)
      I.Add(56, 1, "silent")                         -- a mage's robe? (Apprentice's Robe: cloth, fine)
      local staff = false
      for i = 1, 16 do local x = Craft.char.bags[0][i] if x and x.id == 35 then staff = I.EquipFromBag(0, i) end end
      return { ok = ok, a0 = armor0, a1 = armor1, back = back, armor2 = Craft.player.armor, errors = T_DC.errors }
    """)
    assert r["ok"] and r["a1"] < r["a0"] and r["back"] and r["armor2"] == r["a0"], r
    no_errors(w)


@case
def death_ghost_and_resurrect():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local p = Craft.player
      local x0, y0 = p.x, p.y
      Craft.Combat.Damage(nil, p, 9999, { school = 1 })
      local dead = p.dead
      Craft.World.ReleaseSpirit()
      local ghost, gx, gy = p.ghost, p.x, p.y
      local far = Craft.World.CorpseDistance()
      p.x, p.y = x0, y0
      local near = Craft.World.CorpseDistance()
      Craft.World.Revive(true)
      return { dead = dead, ghost = ghost, far = far, near = near, alive = not p.dead, hp = p.hp, max = p.hpMax }
    """)
    assert r["dead"] and r["ghost"] and r["near"] < 1 and r["alive"], r
    assert r["hp"] == r["max"] // 2, r
    no_errors(w)


@case
def talents_points_rules_and_effects():
    """A point a level from 10; tiers open with five points in the tree; the ranks really change the spells."""
    w, c = game(8)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local T, p, Combat = Craft.Talents, Craft.player, Craft.Combat
      local out = {}
      Craft.char.level = 9
      out.at9 = T.Points()
      local ok9 = T.Learn(26)
      Craft.char.level, p.level = 12, 12
      out.at12 = T.Points()
      local fb = Craft.D.spells[133]
      out.cast0 = Combat.CastTime(fb, p)
      out.learn1, out.learn2 = T.Learn(26), T.Learn(26)        -- Improved Fireball 2/5
      out.cast2 = Combat.CastTime(fb, p)
      out.left = T.Points()
      -- a tier-2 talent with 2 points in the tree: locked
      local tier2
      for _, t in ipairs(T.Trees(8)[2].talents) do if t.tier == 1 then tier2 = t.id break end end
      out.tier2ok, out.tier2why = T.CanLearn(nil, tier2)
      out.book = false
      for _, tab in ipairs(Craft.Npc.Spellbook()) do for _, id in ipairs(tab.list) do if id == 12338 then out.book = true end end end
      out.ok9 = ok9
      return out
    """)
    assert r["at9"] == 0 and r["ok9"] is False, r
    assert r["at12"] == 3 and r["learn1"] and r["learn2"] and r["left"] == 1, r
    assert abs(r["cast0"] - 1.5) < 1e-6 and abs(r["cast2"] - 1.3) < 1e-6, r       # (0.1 s a rank)
    assert r["tier2ok"] is False and r["tier2why"] == "tier", r
    assert r["book"] is False, r                                                  # (passive talents stay out)
    no_errors(w)
    # a warrior: Cruelty's crit, Improved Heroic Strike's rage, then unlearning at the trainer (1 g)
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local T, p, Combat = Craft.Talents, Craft.player, Craft.Combat
      Craft.char.level, p.level = 11, 11
      Combat.Recalc(p)
      local crit0, cost0 = p.crit, Combat.Cost(Craft.D.spells[78], p)
      T.Learn(157) T.Learn(124)                                 -- Cruelty 1/5, Improved Heroic Strike 1/3
      local crit1, cost1 = p.crit, Combat.Cost(Craft.D.spells[78], p)
      Craft:AddMoney(10000, "silent")
      local cost = T.ResetCost()
      local reset = T.Reset()
      return { crit0 = crit0, crit1 = crit1, cost0 = cost0, cost1 = cost1, resetCost = cost, reset = reset,
               crit2 = p.crit, spent = T.Spent(), money = Craft:Money() }
    """)
    assert abs(r["crit1"] - r["crit0"] - 1) < 1e-6, r
    assert r["cost0"] == 150 and r["cost1"] == 140, r                             # (15 rage, then 14)
    assert r["resetCost"] == 10000 and r["reset"] and r["spent"] == 0, r
    assert abs(r["crit2"] - r["crit0"]) < 1e-6, r
    no_errors(w)


@case
def leveling_up_raises_stats():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local hp0 = Craft.player.hpMax
      Craft:GiveXP(400)
      return { lvl = Craft.char.level, hp = Craft.player.hpMax, hp0 = hp0, msgs = T_DC.msgs, full = Craft.player.hp }
    """)
    assert r["lvl"] == 2 and r["hp"] > r["hp0"] and r["full"] == r["hp"], r
    assert any("reached level 2" in m for m in r["msgs"]), r
    no_errors(w)


@case
def the_abbey_door_leads_inside():
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft, W = ns.Craft, ns.AzeroWorldData
      local d = W.doors[6235 * ns.AzeroLand.WIDTH + 4129]
      local p = Craft.player
      p.x, p.y = d.ox + 0.5, d.oy + 0.5
      Craft.World.input.dx, Craft.World.input.dy = d.x - d.ox, d.y - d.oy
      return { door = d ~= nil, map = d and d.map }
    """)
    assert r["door"], r
    w.run_until(lambda: c.eval_py("return ns.Craft.player.map ~= 'world'"), timeout=3)
    r = c.eval_py("ns.Craft.World.input.dx, ns.Craft.World.input.dy = 0, 0 return { map = ns.Craft.player.map, area = ns.Craft.World.areaName }")
    assert r["map"].startswith("i10286"), r
    assert r["area"] == "Northshire Abbey", r
    no_errors(w)


@case
def the_abbey_doorway_leads_out_from_any_row():
    # (in game you could walk down the hall a row beside the one exit tile, out onto the front steps and never
    # leave: the whole doorway and the steps beyond it lead out now, and you come in on the inner side)
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft, W = ns.Craft, ns.AzeroWorldData
      local d = W.doors[6235 * ns.AzeroLand.WIDTH + 4129]
      local p = Craft.player
      Craft.World.Teleport(p, d.map, d.tx + 0.5, d.ty + 0.5)
      local m = Craft.World.interiors[d.map]
      local inExit = m.warps[d.ty * 1000 + d.tx] ~= nil
      local ux, uy = d.ox - d.x, d.oy - d.y
      -- a row beside the door's own, walking out the way the door faces
      p.x, p.y = d.tx + 0.5 + uy, d.ty + 0.5 + ux
      Craft.World.input.dx, Craft.World.input.dy = ux, uy
      return { inExit = inExit, ok = Craft.World.Walkable(p.map, math.floor(p.x), math.floor(p.y)) }
    """)
    assert not r["inExit"] and r["ok"], r
    w.run_until(lambda: c.eval_py("return ns.Craft.player.map == 'world'"), timeout=3)
    c.eval_py("ns.Craft.World.input.dx, ns.Craft.World.input.dy = 0, 0")
    no_errors(w)


UI_SETUP = r"""
  T_UI = CreateFrame("Frame", nil, UIParent)
  T_UI:SetSize(1100, 700)
  T_UI:SetPoint("CENTER")
  T_UI:Show()
  local def = ns.Games:Get("disastercraft")
  T_PANEL = def.create(T_UI)
  T_PANEL:Show()
  T_PANEL:OnGameShown()
"""


def ui_game(cls=1):
    w, c = solo("Alice", tick=2)
    c.eval(HELPER)
    c.eval(UI_SETUP)
    w.tick(0.2)
    return w, c


@case
def ui_character_screens_and_entering_the_world():
    w, c = ui_game()
    r = c.eval_py(r"""
      local UI = ns.CraftUI
      UI.Glue.ShowCreate()
      ns.CraftUI.Glue.newClass = 8
      ns.CraftUI.Glue.RefreshCreate()
      ns.CraftUI.glue.create.accept:Click()
      local chars = #ns.Craft:Characters()
      UI.Glue.EnterWorld()
      return { chars = chars, inWorld = UI.inWorld == true, cls = ns.Craft.char and ns.Craft.char.class }
    """)
    assert r["chars"] == 1 and r["inWorld"] and r["cls"] == 8, r
    w.tick(3.0)
    no_errors(w)


@case
def ui_windows_open_and_fill():
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(5, 1)
      ns.CraftUI.Glue.selected = 5
      ns.CraftUI.Glue.EnterWorld()
    """)
    w.tick(1.0)
    r = c.eval_py(r"""
      local UI, Craft = ns.CraftUI, ns.Craft
      UI.Toggle("character") UI.Toggle("spellbook") UI.Toggle("questlog") UI.ToggleAllBags() UI.ToggleMenu()
      local shown = {}
      for n, f in pairs(UI.open) do if f:IsShown() then shown[#shown + 1] = n end end
      UI.CloseAll()
      -- talk to Deputy Willem (quests), a vendor, the priest trainer
      local willem = T_DC.find(823, "any")
      Craft.player.map, Craft.player.x, Craft.player.y = willem.map, willem.x + 0.5, willem.y
      UI.OpenGossip(willem)
      local q = UI.open.quest and UI.open.quest:IsShown()
      local danil = T_DC.find(152, "any")
      UI.OpenMerchant(danil)
      local m = UI.open.merchant and UI.open.merchant:IsShown()
      local anetta = T_DC.find(375, "any")
      UI.OpenTrainer(anetta)
      local t = UI.open.trainer and UI.open.trainer:IsShown()
      return { shown = shown, q = q, m = m, t = t }
    """)
    assert len(r["shown"]) >= 4, r          # (a third side panel pushes one out, like WoW)
    assert r["q"] and r["m"] and r["t"], r
    w.tick(1.0)
    no_errors(w)


@case
def ui_blizzard_windows_fill_like_the_client():
    """The quest log, the trainer and the spellbook on the client's own frames: headers, rows, details, tabs."""
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(5, 1)
      ns.CraftUI.Glue.selected = 5
      ns.CraftUI.Glue.EnterWorld()
    """)
    w.tick(1.0)
    r = c.eval_py(r"""
      local UI, Craft = ns.CraftUI, ns.Craft
      Craft.Quests.Accept(783)
      UI.Toggle("questlog")
      local q = UI.QuestLogWindow().refs
      local log = { q.QuestLogTitle1:GetText(), q.QuestLogTitle2:GetText(), q.QuestLogQuestTitle:GetText(),
                    q.QuestLogQuestCount:GetText(), q.QuestLogTitle3:IsShown() }
      UI.CloseAll()
      local anetta = T_DC.find(375, "any")
      UI.OpenTrainer(anetta)
      local t = UI.open.trainer.refs
      local trainer = { t.ClassTrainerSkill1Text:GetText(), t.ClassTrainerSkill2Text:GetText(),
                        t.ClassTrainerSkillName:GetText(), t.ClassTrainerNameText:GetText() }
      UI.CloseAll()
      UI.Toggle("spellbook")
      local s = UI.SpellBookWindow().refs
      local book = { s.SpellBookSkillLineTab1.tooltip, s.SpellBookSkillLineTab2.tooltip, s.SpellButton1SpellName:GetText(),
                     s.SpellBookPageText:GetText(), s.SpellButton2:IsEnabled() and true or false }
      return { log = log, trainer = trainer, book = book }
    """)
    log, trainer, book = r["log"], r["trainer"], r["book"]
    assert log[0] == "Northshire Valley", log                  # (the zone header, then the quest)
    assert log[1].strip() == "A Threat Within" and log[2] == "A Threat Within", log
    assert log[3] == "Quests: 1/20" and not log[4], log
    assert trainer[0] in ("Discipline", "Holy", "Shadow Magic"), trainer   # (a skill-line header first)
    assert trainer[1].strip() and trainer[2] and trainer[3] == "Priestess Anetta", trainer
    assert book[0] == "General" and book[1] in ("Discipline", "Holy"), book
    assert book[2] and book[3] == "Page 1" and book[4] is False, book   # (SpellButton2 is the right column's first)
    w.tick(1.0)
    no_errors(w)


@case
def ui_hero_sprite_wears_its_gear():
    """The pixel hero is a bare body plus one layer per item worn; taking an item off takes its layer away."""
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
    """)
    w.tick(0.5)
    r = c.eval_py(r"""
      local UI, Craft, Items = ns.CraftUI, ns.Craft, ns.Craft.Items
      local p = Craft.player
      local function n(kind, col, face) local l = UI.OutfitLayers(p, kind, col, face) return l and #l or 0 end
      local worn = n("walk", 1, 0)
      local act = n("act", 1, 2)
      local first = UI.OutfitLayers(p, "walk", 1, 0)[1]
      Items.Unequip(4)                              -- (the shirt off)
      local shirtless = n("walk", 1, 0)
      Items.Unequip(16)                             -- (and the sword)
      local unarmed = n("walk", 1, 2)
      return { worn = worn, act = act, shirtless = shirtless, unarmed = unarmed, body = first[1], h = first[9] }
    """)
    assert r["worn"] >= 4 and r["act"] >= 4, r                 # body, shirt, pants, boots, sword, shield
    assert r["shirtless"] == r["worn"] - 1, r
    assert r["unarmed"] < r["worn"], r
    assert "Outfit\\outfit" in r["body"] and r["h"] >= 20, r   # (the body: a whole figure on the sheet)
    no_errors(w)


@case
def ui_fight_shows_numbers_and_loot_window():
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
      local u = T_DC.find(6)
      T_DC.calm(u)
      T_DC.mob = u
      T_DC.near(u, 3)
      ns.Craft.World.SetTarget(u)
      ns.Craft.Combat.StartAttack(ns.Craft.player, u)
    """)
    w.run_until(lambda: c.eval_py("return T_DC.mob.dead"), timeout=60)
    w.tick(0.5)
    r = c.eval_py(r"""
      local u = T_DC.mob
      local can = ns.Craft.Loot.CanLoot(u)
      if can then ns.Craft.World.Interact(u) end
      return { can = can, open = ns.CraftUI.open.loot ~= nil }
    """)
    if r["can"]:
        assert r["open"], r
    w.tick(0.5)
    no_errors(w)


@case
def ui_abbey_railing_draws_in_front_of_you_and_fades():
    # (in game the hero was drawn over every wall: the Abbey's walls are depth slices now - a railing just south
    # of you draws after you, see-through where it covers you; one north of you draws before you)
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
      ns.Craft.World.Teleport(ns.Craft.player, "i10286_0", 9.5, 34.7)
    """)
    w.tick(0.3)
    r = c.eval_py(r"""
      local UI, p = ns.CraftUI, ns.Craft.player
      local sx, sy = UI.ToScreen(p.x, p.y)
      local T = UI.TILE
      local me, front, behind, faded
      for i, q in ipairs(UI.depthOrder) do
        if q.sort == p.y and not me then me = i end
        local over = q.x < sx + T * 0.3 and q.x + q.w > sx - T * 0.3 and q.y < sy and q.y + q.h > sy - T * 0.9
        if over and tostring(q.file):find("northshire_in") then
          if q.sort > p.y then front = front or i faded = faded or q.alpha < 1 or q.see ~= nil
          else behind = i end
        end
      end
      return { me = me, front = front, behind = behind, faded = faded }
    """)
    assert r["me"] and r["front"] and r["front"] > r["me"] and r["faded"], r
    assert r.get("behind") is None or r["behind"] < r["me"], r
    no_errors(w)


@case
def ui_eating_sits_you_down_and_swings_show():
    # food sits you down (the seated pose); a melee blow shows the strike, a corpse lies down
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
    """)
    w.tick(0.2)
    r = c.eval_py(r"""
      local C, UI = ns.Craft, ns.CraftUI
      local p = C.player
      local food
      for id, it in pairs(C.D.items) do
        for _, s in ipairs(it.spells or {}) do
          local sp = C.D.spells[s[1]]
          if sp and sp.n == "Food" and (it.req or 0) <= 1 then food = food or id end
        end
      end
      C.Items.Add(food, 1, "silent")
      C.Items.UseById(food)
      local now = C.Now()
      local sat, pose = p.sitting, UI.UnitPose(p, now)
      p.sitting = false
      p.swungAt = now
      local strike = UI.UnitPose(p, now + 0.2)
      return { food = food, sat = sat, pose = pose, strike = strike }
    """)
    assert r.get("food") and r["sat"] and r["pose"] == 5 and r["strike"] == 1, r
    no_errors(w)


@case
def ui_3d_model_turns_to_the_heros_sex():
    # (in game a male hero's 3D model stayed the player's own female body) - a model that only takes UnitSex's
    # 2 / 3 for SetCustomRace still ends up male, and remembers the convention for the next one
    w, c = ui_game()
    c.eval(r"""
      local m = CreateFrame("DressUpModel", nil, UIParent)
      m.fid = 119563                                         -- the WoW character: a human female
      m.SetUnit = function(self) end
      m.SetCustomRace = function(self, race, g)
        if g == 2 then self.fid = 119940 elseif g == 3 then self.fid = 119563 end
      end
      m.GetModelFileID = function(self) return self.fid end
      T_M = m
      ns.CraftUI.Kit.DressModel(m, 0, {})
    """)
    w.tick(4)
    r = c.eval_py("return { fid = T_M.fid, off = T_M.dzSexOff }")
    assert r["fid"] == 119940 and r["off"] == 2, r
    c.eval("ns.CraftUI.Kit.DressModel(T_M, 1, {})")
    w.tick(3)
    r = c.eval_py("return { fid = T_M.fid }")
    assert r["fid"] == 119563, r
    no_errors(w)


@case
def exploring_goldshire_gives_xp_and_shows_on_the_map():
    # discovering an area: WoW's exploration XP (Goldshire, level 5: 45 at level 1), once; the world map (M) then
    # draws its explored art; Northshire's areas have no exploration level (no XP)
    w, c = ui_game()
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
    """)
    w.tick(0.2)
    r = c.eval_py(r"""
      local C, UI = ns.Craft, ns.CraftUI
      local xp0 = C.char.xp
      C.World.Explore(87, "Goldshire")
      local xp1 = C.char.xp
      C.World.Explore(87, "Goldshire")
      C.World.Explore(59, "Northshire Vineyards")
      UI.ToggleWorldMap()
      local open = UI.open.worldmap ~= nil and UI.open.worldmap:IsShown()
      UI.CloseAll()
      return { gained = xp1 - xp0, again = C.char.xp - xp1, open = open, closed = not (UI.open.worldmap),
               msg = C.log[#C.log] and C.log[#C.log].text, vineyards = C.char.explored[59] }
    """)
    assert r["gained"] == 45 and r["again"] == 0 and r["vineyards"], r
    assert r["open"] and r["closed"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()

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


if __name__ == "__main__":
    run_all()

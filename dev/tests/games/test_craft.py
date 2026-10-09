"""Disastercraft (Games/Disastercraft): the WoW-like game on the real Northshire map - the engine without the UI.

Covers: the generated data; a new character of each class (start gear, bags, action bar, WoW's level-1 health and
mana); WoW's experience formulas; a warrior's fight with a Kobold Vermin (auto attack, rage, the kill's experience,
loot); a mage's Fireball (cast time, mana, the missile, its burn); aggro range, social pulls and evade; quests from
accept to turn-in (kill credit, quest drops in the bags, the reward choice, the experience); trainers; vendors;
death, the ghost run and coming back; leveling up; walking into the Abbey and up its stairs (buildings are walked
in place: no inside maps, no doors that teleport).

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
-- walks the player along the building-aware path to (tx, ty) (height te in building tb) in small steps, the way the
-- keys move you: { ok, maxStep = biggest height change of one step, e, bld = building id, why }
function T_DC.walkTo(tx, ty, te, tb)
  local W, p = Craft.World, Craft.player
  local path = W.PathFine(p.x, p.y, tx, ty, 40000, p.e, p.bld, te, tb)
  if not path then return { ok = false, why = "no path" } end
  local maxStep, prevE, prevB = 0, p.e, p.bld
  for _, q in ipairs(path) do
    for _ = 1, 60 do
      local dx, dy = q[1] - p.x, q[2] - p.y
      local d = math.sqrt(dx * dx + dy * dy)
      if d < 0.01 then break end
      local st = math.min(d, 0.07)
      if W.MoveBy(p, dx / d * st, dy / d * st) < 1e-6 then
        return { ok = false, why = "stuck", x = p.x, y = p.y, e = p.e }
      end
      if p.bld and prevB == p.bld then maxStep = math.max(maxStep, math.abs(p.e - prevE)) end
      prevE, prevB = p.e, p.bld
    end
  end
  return { ok = true, maxStep = maxStep, n = #path, e = p.e, bld = p.bld and p.bld.id }
end
-- the Abbey's NPCs standing indoors: { unit, storey } by storey
function T_DC.abbeyFolk()
  local WS = ns.AzeroLand
  local out = {}
  for _, rec in pairs(Craft.World.recs) do
    local u = rec.unit
    if u and u.kind == "npc" and u.bld and u.bld.id == 10286 then
      local b, li = Craft.World.UnitLayer(u)
      local l = b and WS.Layers(b, math.floor(u.x * 4), math.floor(u.y * 4))[li]
      if l and l.ind then out[#out + 1] = { u = u, st = l.st or 1 } end
    end
  end
  table.sort(out, function(a, b) return a.u.guid < b.u.guid end)
  return out
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
    # (faster than WoW: half the kills - Craft.QUEST_COUNT - and the goal says so)
    assert "Kobold Vermin slain: 5/5" in r["notices"], r
    goal = c.eval("return ns.Craft.Quests.Get(7).goal")
    assert goal.startswith("Kill 5 Kobold Vermin"), goal
    no_errors(w)


@case
def quest_drops_land_in_the_bags():
    w, c = game(1)
    r = c.eval_py(r"""
      local Q, Craft = ns.Craft.Quests, ns.Craft
      Craft.char.done[783], Craft.char.done[5261] = true, true
      Q.Accept(33)                                  -- Wolves Across the Border: Tough Wolf Meat
      local needs = Q.NeedsItem(750)
      Craft.Items.Add(750, 4, "loot")               -- (WoW asks 8: half, Craft.QUEST_COUNT)
      return { needs = needs, complete = Q.Complete(33), count = Craft.Items.Count(750) }
    """)
    assert r["needs"] and r["complete"] and r["count"] == 4, r
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


# (talents: the rows of Games/Disastercraft/Talents.lua - tests/games/test_craft_talents.py)


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
def the_abbey_is_walked_in_and_out():
    # (the old Abbey was inside maps behind teleporting doors: in game you were thrown in and out near the door and
    # could get stuck; now you walk in through the doorway on the same map, and back out again)
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local p = Craft.player
      local x0, y0 = p.x, p.y
      local folk = T_DC.abbeyFolk()
      local ground
      for _, f in ipairs(folk) do if f.st == 1 then ground = ground or f.u end end
      if not ground then return { why = "no ground-floor npc", n = #folk } end
      local tele = 0
      Craft:On("teleport", function() tele = tele + 1 end)
      local inn = T_DC.walkTo(ground.x, ground.y, ground.e, ground.bld)
      local inside = { map = p.map, bld = p.bld and p.bld.id, e = p.e }
      local out = T_DC.walkTo(x0, y0)
      return { n = #folk, inn = inn, inside = inside, out = out, outB = p.bld and p.bld.id or false, tele = tele,
               map = p.map }
    """)
    assert r.get("n", 0) >= 3, r
    assert r["inn"]["ok"] and r["inside"]["bld"] == 10286 and r["inside"]["map"] == "world", r
    assert r["out"]["ok"] and r["outB"] is False and r["map"] == "world" and r["tele"] == 0, r
    no_errors(w)


@case
def the_abbey_stairs_climb_step_by_step():
    # up to the Abbey's upper floors on its own stairs: the height rises a little each step, never a jump
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local top
      for _, f in ipairs(T_DC.abbeyFolk()) do
        if f.st >= 3 and (not top or f.u.e > top.e) then top = f.u end
      end
      if not top then return { why = "no upstairs npc" } end
      local got = T_DC.walkTo(top.x, top.y, top.e, top.bld)
      got.want = top.e
      got.name = top.name
      return got
    """)
    assert r.get("ok"), r
    assert r["maxStep"] <= 1.35 and abs(r["e"] - r["want"]) < 1.5 and r["e"] > 8, r
    no_errors(w)


@case
def every_building_npc_can_walk_out():
    # nobody indoors is walled in: from every NPC's spot in a building there is a way out onto the open ground
    w, c = game(1)
    r = c.eval_py(r"""
      local Craft = ns.Craft
      local W = Craft.World
      local p = Craft.player
      local bad, n = {}, 0
      for _, rec in pairs(W.recs) do
        local u = rec.unit
        if u and u.kind == "npc" and u.bld and not u.bld.cave then
          n = n + 1
          if not W.PathFine(u.x, u.y, p.x, p.y, 40000, u.e, u.bld) then bad[#bad + 1] = u.name end
        end
      end
      return { n = n, bad = bad }
    """)
    assert r["n"] >= 3 and not r["bad"], r
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
def ui_delete_character_on_the_character_screen():
    # (in game the confirmation was the HUD's popup: it only showed after entering the world) - the character
    # screen asks itself, Okay arms on typing DELETE, and the list updates at once
    w, c = ui_game()
    r = c.eval_py(r"""
      local UI, C = ns.CraftUI, ns.Craft
      C:NewCharacter(1, 0)
      C:NewCharacter(8, 1)
      UI.Glue.ShowSelect()
      UI.Glue.selected = 1
      UI.Glue.Refresh()
      UI.glue.select.delete:Click()
      local d = UI.glue.deleteDialog
      local shown, armed0 = d and d:IsShown(), d and d.okay:IsEnabled()
      d.edit:SetText("delete")
      local armed1 = d.okay:IsEnabled()
      d.okay:Click()
      local left = {}
      for _, ch in ipairs(C:Characters()) do left[#left + 1] = ch.class end
      return { shown = shown, armed0 = armed0, armed1 = armed1, hidden = not d:IsShown(), left = left,
               inWorld = UI.inWorld == true, sel = UI.Glue.selected }
    """)
    assert r["shown"] and not r["armed0"] and r["armed1"] and r["hidden"], r
    assert r["left"] == [8] and not r["inWorld"] and r["sel"] == 8, r
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
def ui_inside_the_abbey_its_roof_goes_and_your_storey_shows():
    # step inside and the Abbey's roof fades away to its cut-away picture of your storey; folk upstairs are not
    # drawn; going up, the upper storey's picture shows and you are drawn higher up the screen
    w, c = ui_game()
    c.eval(HELPER)
    c.eval(r"""
      ns.Craft:NewCharacter(1, 0)
      ns.CraftUI.Glue.selected = 1
      ns.CraftUI.Glue.EnterWorld()
      T_DC.on = false
      local f1, up
      for _, f in ipairs(T_DC.abbeyFolk()) do
        if f.st == 1 then f1 = f1 or f.u end
        if f.st >= 3 then up = up or f.u end
      end
      T_F1, T_UP = f1, up
      local p = ns.Craft.player
      ns.Craft.World.Teleport(p, "world", f1.x, f1.y + 0.3, f1.e)
    """)
    w.tick(0.8)
    r = c.eval_py(r"""
      local UI, p = ns.CraftUI, ns.Craft.player
      local cut, roof = 0, 0
      for _, q in ipairs(UI.depthOrder) do
        if q.cut then cut = cut + 1 end
        if q.bld == 10286 and q.alpha > 0.01 then roof = roof + 1 end
      end
      return { inB = p.inB and p.inB.id, st = p.inSt, cut = cut, roof = roof, f1 = UI.Shown(T_F1), up = UI.Shown(T_UP),
               lift = p.lift }
    """)
    assert r["inB"] == 10286 and r["st"] == 1 and r["cut"] > 5 and r["roof"] == 0, r
    assert r["f1"] and not r["up"], r
    c.eval(r"""
      local p = ns.Craft.player
      ns.Craft.World.Teleport(p, "world", T_UP.x, T_UP.y + 0.3, T_UP.e)
    """)
    w.tick(0.8)
    r2 = c.eval_py(r"""
      local UI, p = ns.CraftUI, ns.Craft.player
      return { st = p.inSt, up = UI.Shown(T_UP), f1 = UI.Shown(T_F1), lift = p.lift }
    """)
    assert r2["st"] >= 3 and r2["up"] and not r2["f1"] and r2["lift"] > r["lift"] + 1, (r, r2)
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
    # (in game a male hero's 3D model stayed the player's own female body; then, sent UnitSex 2 = None, a male body
    # in the female skin) - SetCustomRace gets Enum.UnitSex 0 / 1 only; a body that loads late (after the old 0.6 s
    # wait) is waited for, and the unit's own late load putting the female body back is turned again
    w, c = ui_game()
    c.eval(r"""
      local m = CreateFrame("DressUpModel", nil, UIParent)
      m.fid = 119563                                         -- the WoW character: a human female
      m.sent = {}
      m.SetUnit = function(self) self.unitAt = GetTime() + 1.5 end         -- (its load lands late, once)
      m.SetCustomRace = function(self, race, g)
        self.sent[#self.sent + 1] = g
        self.raceAt, self.raceFid = GetTime() + 0.8, (g == 0 and 119940) or (g == 1 and 119563) or 0
      end
      m.GetModelFileID = function(self)
        local now = GetTime()
        if self.raceAt and now >= self.raceAt then self.fid, self.raceAt = self.raceFid, nil end
        if self.unitAt and now >= self.unitAt then self.fid, self.unitAt = 119563, nil end
        return self.fid
      end
      T_M = m
      ns.CraftUI.Kit.DressModel(m, 0, {})
    """)
    w.tick(6)
    r = c.eval_py("local s = {} for i, g in ipairs(T_M.sent) do s[i] = g end return { fid = T_M:GetModelFileID(), sent = s }")
    assert r["fid"] == 119940, r
    sent = list(r["sent"].values()) if isinstance(r["sent"], dict) else r["sent"]
    assert sent and all(g == 0 for g in sent), r
    c.eval("ns.CraftUI.Kit.DressModel(T_M, 1, {})")
    w.tick(4)
    r = c.eval_py("return { fid = T_M:GetModelFileID() }")
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
    assert r["gained"] == 45 * 3 and r["again"] == 0 and r["vineyards"], r      # (Craft.XP_RATE)
    assert r["open"] and r["closed"], r
    no_errors(w)


if __name__ == "__main__":
    run_all()

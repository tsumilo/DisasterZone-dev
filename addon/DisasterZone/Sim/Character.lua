if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Character.lua", ...) then return end -- DisasterZone: Sim/Character.lua
-- ns.GearSim characters: base stats by race (base_stats.go), equipment stats with gems, enchants and socket bonuses
-- (database.go), generic item procs and on-use trinkets from item data (common/shared/shared_utils.go), set bonuses,
-- the target (target.go), metrics, and S.Run (many iterations, one result).
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O = S.ST, S.PM, S.F, S.O

local huge, max, min, floor, sqrt = math.huge, math.max, math.min, math.floor, math.sqrt

-- base_stats_auto_gen.go CritPerAgiMaxLevel / CritPerIntMaxLevel
S.CRIT_PER_AGI = { Warrior = 0.0303, Paladin = 0.04, Hunter = 0.025, Rogue = 0.025, Priest = 0.04, Shaman = 0.04,
  Mage = 0.04, Warlock = 0.0405, Druid = 0.04 }
S.CRIT_PER_INT = { Warrior = 0, Paladin = 0.0125, Hunter = 0.0125, Rogue = 0, Priest = 0.0125, Shaman = 0.0125,
  Mage = 0.0125, Warlock = 0.0122, Druid = 0.0125 }
S.DODGE_RATING_PER_PCT = 18.923079

-- WoWSims proto Stat enum -> our stat index (item / gem / enchant data use the proto numbers)
local WS = {
  [0] = ST.Strength, [1] = ST.Agility, [2] = ST.Stamina, [3] = ST.Intellect, [4] = ST.HealingPower,
  [5] = ST.SpellDamage, [6] = ST.ArcaneDamage, [7] = ST.FireDamage, [8] = ST.FrostDamage, [9] = ST.HolyDamage,
  [10] = ST.NatureDamage, [11] = ST.ShadowDamage, [12] = ST.SpellHitRating, [13] = ST.SpellCritRating,
  [14] = ST.SpellHasteRating, [15] = ST.SpellPenetration, [16] = ST.Spirit, [17] = ST.AttackPower,
  [18] = ST.RangedAttackPower, [19] = ST.FeralAttackPower, [20] = ST.MeleeHitRating, [21] = ST.MeleeCritRating,
  [22] = ST.MeleeHasteRating, [23] = ST.ArmorPenetration, [24] = ST.ExpertiseRating, [25] = ST.DefenseRating,
  [26] = nil, [27] = ST.BlockValue, [28] = ST.DodgeRating, [29] = ST.ParryRating, [30] = ST.ResilienceRating,
  [31] = ST.Armor, [32] = ST.BonusArmor, [33] = ST.Health, [34] = ST.Mana, [35] = ST.MP5,
  [36] = ST.ArcaneResistance, [37] = ST.FireResistance, [38] = ST.FrostResistance, [39] = ST.NatureResistance,
  [40] = ST.ShadowResistance, [41] = ST.PhysicalDamage,
}
S.WS_STAT = WS

local function WSStats(t)
  local out = {}
  if not t then return out end
  for k, v in pairs(t) do
    local i = WS[tonumber(k)]
    if i then out[i] = (out[i] or 0) + v end
  end
  return out
end
S.WSStats = WSStats

-- base_stats.go: class row + ExtraClassBaseStats + race offsets (level 70); the racial resistances
-- (racials.go) ride along with the offsets.
local CLASS_BASE = {
  Warrior = { Health = 4264, Agility = 96, Strength = 145, Intellect = 33, Spirit = 51, Stamina = 133,
    AttackPower = 190, PhysicalCritPercent = 1.14 },
  Paladin = { Strength = 126, Agility = 77, Stamina = 120, Intellect = 83, Spirit = 89, Health = 3197,
    AttackPower = 190, Mana = 2953, SpellCritPercent = 3.3355, PhysicalCritPercent = 0.6520 },
  Hunter = { Health = 3388, Agility = 151, Strength = 64, Intellect = 77, Spirit = 83, Stamina = 108,
    AttackPower = 120, RangedAttackPower = 120, Mana = 3383, SpellCritPercent = 3.6020, PhysicalCritPercent = -1.5320 },
  Rogue = { Health = 3524, Agility = 158, Strength = 95, Intellect = 39, Spirit = 58, Stamina = 89,
    AttackPower = 120, PhysicalCritPercent = -0.2950 },
  Priest = { Health = 3211, Agility = 45, Strength = 39, Intellect = 145, Spirit = 151, Stamina = 58,
    Mana = 2620, SpellCritPercent = 1.2375, PhysicalCritPercent = 3.1830 },
  Shaman = { Health = 2979, Agility = 64, Strength = 102, Intellect = 108, Spirit = 120, Stamina = 114,
    AttackPower = 140, Mana = 2958, SpellCritPercent = 2.2010, PhysicalCritPercent = 1.6750 },
  Mage = { Health = 3213, Agility = 39, Strength = 33, Intellect = 151, Spirit = 145, Stamina = 51,
    Mana = 2241, SpellCritPercent = 0.9075, PhysicalCritPercent = 3.4575 },
  Warlock = { Health = 3310, Agility = 58, Strength = 51, Intellect = 133, Spirit = 139, Stamina = 76,
    AttackPower = -10, Mana = 2615, SpellCritPercent = 1.7000, PhysicalCritPercent = 2.0000 },
  Druid = { Health = 3434, Agility = 70, Strength = 76, Intellect = 120, Spirit = 133, Stamina = 83,
    AttackPower = -20, Mana = 2370, SpellCritPercent = 1.8515, PhysicalCritPercent = 0.9610 },
}
S.CLASS_BASE = CLASS_BASE
local RACE_OFFSETS = {
  Human = {},
  Orc = { Agility = -3, Strength = 3, Intellect = -3, Spirit = 3, Stamina = 2 },
  Dwarf = { Agility = -4, Strength = 2, Intellect = -1, Spirit = -1, Stamina = 3, FrostResistance = 10 },
  NightElf = { Agility = 5, Strength = -3, Stamina = -1, NatureResistance = 10 },
  Undead = { Agility = -2, Strength = -1, Intellect = -2, Spirit = 5, Stamina = 1, ShadowResistance = 10 },
  Tauren = { Agility = -5, Strength = 5, Intellect = -5, Spirit = 2, Stamina = 2, NatureResistance = 10 },
  Gnome = { Agility = 3, Strength = -5, Intellect = 3, Stamina = -1, ArcaneResistance = 10 },
  Troll = { Agility = 2, Strength = 1, Intellect = -4, Spirit = 1, Stamina = 1 },
  BloodElf = { Agility = 2, Strength = -3, Intellect = 4, Spirit = -1, Stamina = -2,
    ArcaneResistance = 5, FireResistance = 5, FrostResistance = 5, NatureResistance = 5, ShadowResistance = 5 },
  Draenei = { Agility = -3, Strength = 1, Intellect = 1, Spirit = 2, Stamina = -1, ShadowResistance = 10 },
}
-- classes with a mana bar (EnableManaBar in their constructors)
S.MANA_CLASSES = { Paladin = true, Hunter = true, Priest = true, Shaman = true, Mage = true, Warlock = true, Druid = true }

-- Item slots in WoWSims EquipmentSpec order.
S.SLOTS = { "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Finger1",
  "Finger2", "Trinket1", "Trinket2", "MainHand", "OffHand", "Ranged" }

-- Gem colours (proto GemColor) and database.go ColorIntersects
local function ColorIntersects(g, o)
  if g == o then return true end
  if g == 8 or o == 8 then return true end
  if g == 1 then return o == 1 end
  if g == 2 then return o == 6 or o == 7 end
  if g == 3 then return o == 5 or o == 7 end
  if g == 4 then return o == 5 or o == 6 end
  if g == 6 then return o == 4 or o == 2 end
  if g == 5 then return o == 4 or o == 3 end
  if g == 7 then return o == 2 or o == 3 end
  return false
end
S.ColorIntersects = ColorIntersects

-- ---------------------------------------------------------------------------------------------------------------
-- Metrics: per spell (or metricsKey) totals over all iterations
-- ---------------------------------------------------------------------------------------------------------------
local Metrics = {}
Metrics.__index = Metrics

function S.NewMetrics()
  return setmetatable({ byKey = {}, totalDamage = 0, iterDamage = 0, iterations = 0, iterDps = {}, mana = {},
    oomTime = 0 }, Metrics)
end

function Metrics:ForSpell(sp)
  local key = sp.metricsKey or sp.id or "?"
  local m = self.byKey[key]
  if not m then
    m = { key = key, damage = 0, casts = 0, hits = 0, crits = 0 }
    self.byKey[key] = m
  end
  return m
end

function Metrics:ManaGain(key, amount)
  self.mana[key] = (self.mana[key] or 0) + amount
end

function Metrics:ResetIteration()
  self.iterStart = 0
  for _, m in pairs(self.byKey) do m.iterDamage0 = m.damage end
end

function Metrics:DoneIteration(sim)
  local dmg = 0
  for _, m in pairs(self.byKey) do dmg = dmg + (m.damage - (m.iterDamage0 or 0)) end
  self.iterations = self.iterations + 1
  self.iterDps[self.iterations] = dmg / sim.duration
  self.totalDamage = self.totalDamage + dmg
  self.totalDuration = (self.totalDuration or 0) + sim.duration
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building a player
-- ---------------------------------------------------------------------------------------------------------------
local Unit = S.UnitMT

function Unit:NewTemporaryStatsAura(label, stats, duration)
  local a = self:RegisterAura({ label = label, duration = duration })
  local bonus = {}
  for k, v in pairs(stats) do bonus[k] = v end
  a:AttachStatsBuff(bonus)
  a.buffStats = bonus -- StatBuffAura.BuffedStatTypes (castAllStatBuffCooldowns)
  return a
end

function Unit:CouldHaveSetBonus(setName, n)
  return (self.setCounts and (self.setCounts[setName] or 0) >= n) or false
end

-- Spell category timers (shared trinket / potion cooldowns), one per category id.
function Unit:CategoryTimer(id)
  self.categoryTimers = self.categoryTimers or {}
  local t = self.categoryTimers[id]
  if not t then
    t = self:NewTimer()
    self.categoryTimers[id] = t
  end
  return t
end

-- Generic stat proc from item data + the trigger settings from WoWSims' generated file.
-- eff: { buffId, durationMs, stats (WS numbers), proc = { ppm, icdMs, procChance } }
-- trig: { callback, procMask, outcome, requireDamage, weaponProc, canProcFromProcs, classSpellsOnly, spellFlagsExclude }
local function AddStatProc(p, itemId, eff, trig, slotHand)
  local buff = p:NewTemporaryStatsAura("proc " .. itemId .. ":" .. (eff.buffId or 0), WSStats(eff.stats), (eff.durationMs or 0) / 1000)
  local proc = eff.proc or {}
  local dpm
  if (proc.ppm or 0) > 0 then
    local mask = trig.procMask or 0
    if mask == 0 then
      -- NewDynamicLegacyProcForWeapon: the hand the item sits in
      mask = (slotHand == "oh") and PM.MeleeOH or PM.MeleeMH
    end
    dpm = S.NewPPM(p, proc.ppm, mask)
  end
  p:MakeProcTriggerAura({
    name = "item " .. itemId, callback = trig.callback or "hit", procMask = trig.procMask, outcome = trig.outcome,
    requireDamageDealt = trig.requireDamage, classSpellsOnly = trig.classSpellsOnly,
    canProcFromProcs = trig.canProcFromProcs, isWeaponProc = trig.weaponProc, spellFlagsExclude = trig.spellFlagsExclude,
    procChance = (proc.procChance and proc.procChance > 0) and proc.procChance or nil, dpm = dpm,
    icd = (proc.icdMs or 0) / 1000,
    handler = function(sim) buff:Activate(sim) end,
  })
end
S.AddStatProc = AddStatProc

-- shared.NewSimpleStatActive: an on-use stat buff, auto-used as a major cooldown (priority 0).
local function AddOnUse(p, itemId, eff)
  local onUse = eff.onUse
  local buff = p:NewTemporaryStatsAura("use " .. itemId, WSStats(eff.stats), (eff.durationMs or 0) / 1000)
  buff.actionId = { itemId = itemId }
  p.aurasByKey = p.aurasByKey or {}
  p.aurasByKey["i" .. itemId .. ":0"] = p.aurasByKey["i" .. itemId .. ":0"] or buff
  local cfg = {
    id = "item:" .. itemId, school = nil, procMask = PM.Empty, flags = F.NoOnCastComplete, relatedSelfBuff = buff,
    cd = (onUse.cooldownMs or 0) / 1000,
    applyEffects = function(sim) buff:Activate(sim) end,
  }
  if onUse.categoryId and onUse.categoryId > 0 then
    local d = (onUse.categoryCooldownMs or 0) / 1000
    if d <= 0 then d = (eff.durationMs or 0) / 1000 end
    cfg.sharedCdTimer = p:CategoryTimer(onUse.categoryId)
    cfg.sharedCd = d
  end
  local spell = p:RegisterSpell(cfg)
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end
S.AddOnUse = AddOnUse

-- loadout: { race, class, talents, gear = { [slotIndex] = { id, enchant, gems = {...} } }, metaActive }
-- db: { items, gems, enchants, itemProcs, onUse }
function S.BuildPlayer(sim, loadout, db)
  local p = S.NewUnit("player", "Player")
  p.class = loadout.class or "Paladin"
  p.race = loadout.race or "BloodElf"
  p.metrics = S.NewMetrics()
  p.auraById = {}
  p.postFinalize = {}
  p.reactionTime = max((loadout.reactionTimeMs or 0), 10) / 1000
  p.distance = loadout.distance or 5
  p.professions = loadout.professions or {}

  -- Base stats
  local base = CLASS_BASE[p.class]
  local off = RACE_OFFSETS[p.race] or {}
  for k, v in pairs(base) do p:AddStat(ST[k], v + (off[k] or 0)) end
  for k, v in pairs(off) do if not base[k] then p:AddStat(ST[k], v) end end
  -- character.go universal deps + EnableManaBar (mana.go)
  p:AddStatDependency(ST.Stamina, ST.Health, 10)
  p:AddStatDependency(ST.Agility, ST.Armor, 2)
  if S.MANA_CLASSES[p.class] then
    p:AddStatDependency(ST.Intellect, ST.SpellCritPercent, S.CRIT_PER_INT[p.class])
    p:AddStat(ST.Mana, 20 - 15 * 20)
    p:AddStatDependency(ST.Intellect, ST.Mana, 15)
    p:EnableManaBar(base.Mana)
  end

  -- Equipment
  p.gear, p.gearIds, p.setCounts = {}, {}, {}
  local equipStats = {}
  local function add(stats) for k, v in pairs(stats) do equipStats[k] = (equipStats[k] or 0) + v end end
  for si, spec in pairs(loadout.gear or {}) do
    local slot = S.SLOTS[si]
    if spec and spec.id and spec.id ~= 0 then
      local item = db.items[spec.id]
      if not item then error("GearSim: unknown item " .. tostring(spec.id)) end
      p.gear[slot] = { item = item, spec = spec }
      p.gearIds[slot] = spec.id
      add(WSStats(item.stats))
      local ench = spec.enchant and db.enchants[spec.enchant]
      if ench then add(WSStats(ench.stats)) end
      local gems = {}
      for gi, gid in ipairs(spec.gems or {}) do
        local g = db.gems[gid]
        if g then
          gems[gi] = g
          local disabled = (g.color == 1) and loadout.metaActive == false
          if not disabled then add(WSStats(g.stats)) end
        end
      end
      if item.sockets and #item.sockets > 0 and #gems >= #item.sockets then
        local all = true
        for i, c in ipairs(item.sockets) do
          if not gems[i] or not ColorIntersects(c, gems[i].color) then all = false; break end
        end
        if all then add(WSStats(item.socketBonus)) end
      end
      if item.setName then p.setCounts[item.setName] = (p.setCounts[item.setName] or 0) + 1 end
    end
  end
  for k, v in pairs(equipStats) do p:AddStat(k, v) end

  -- Weapons and auto attacks (character.go WeaponFromMainHand / OffHand / Ranged)
  local function weapon(item, bonus)
    return S.WeaponFromItem({ min = item.weaponMin, max = item.weaponMax, speed = item.weaponSpeed,
      twoHand = item.handType == 4, dagger = item.weaponType == 2, quality = item.quality,
      weaponType = item.weaponType, handType = item.handType }, bonus)
  end
  local mh = p.gear.MainHand and p.gear.MainHand.item
  local mhWeapon = mh and (mh.weaponSpeed or 0) > 0 and weapon(mh, p.ps.BonusMHDps) or S.UnarmedWeapon()
  local oh = p.gear.OffHand and p.gear.OffHand.item
  local ohWeapon
  if oh and (oh.weaponSpeed or 0) > 0 and oh.weaponType ~= 7 then ohWeapon = weapon(oh, p.ps.BonusOHDps) end
  if oh and oh.weaponType == 7 then p.ps.CanBlock = true end
  local ranged = p.gear.Ranged and p.gear.Ranged.item
  if ranged and (ranged.weaponSpeed or 0) > 0 then
    local w = S.WeaponFromItem({ min = ranged.weaponMin, max = ranged.weaponMax, speed = ranged.weaponSpeed, ranged = true,
      quality = ranged.quality, rangedWeaponType = ranged.rangedWeaponType }, p.ps.BonusRangedDps)
    p.rangedWeapon = w
  end
  p:EnableAutoAttacks({ mainHand = mhWeapon, offHand = ohWeapon, autoSwingMelee = true })

  return p
end

-- Effects that need the class spells registered first: item effects, metas, enchants, set bonuses.
function S.ApplyItemEffects(p, loadout, db)
  local seen = {}
  for si = 1, #S.SLOTS do
    local slot = S.SLOTS[si]
    local g = p.gear[slot]
    if g then
      local id = g.item.id
      local hand = (slot == "OffHand") and "oh" or ((slot == "MainHand") and "mh" or nil)
      if not seen[id] then
        seen[id] = true
        if S.ITEM_EFFECTS[id] then
          S.ITEM_EFFECTS[id](p, slot)
        else
          for _, eff in ipairs(g.item.effects or {}) do
            if eff.onUse and db.onUse and db.onUse[id] then
              AddOnUse(p, id, eff)
            elseif eff.proc and db.itemProcs and db.itemProcs[id] then
              AddStatProc(p, id, eff, db.itemProcs[id], hand)
            end
          end
        end
      end
      -- meta gem and enchant effects
      for _, gid in ipairs(g.spec.gems or {}) do
        local gem = db.gems[gid]
        if gem and gem.color == 1 and loadout.metaActive ~= false and S.ITEM_EFFECTS[gid] and not seen[gid] then
          seen[gid] = true
          S.ITEM_EFFECTS[gid](p, slot)
        end
      end
      local e = g.spec.enchant
      if e and S.ENCHANT_EFFECTS and S.ENCHANT_EFFECTS[e] and not seen["e" .. e] then
        seen["e" .. e] = true
        S.ENCHANT_EFFECTS[e](p, slot)
      end
    end
  end
  for name, n in pairs(p.setCounts) do
    local sb = S.SET_BONUSES[name]
    if sb then
      for need, fn in pairs(sb) do
        if n >= need then
          local a = S.MakePermanent(p:RegisterAura({ label = name .. " " .. need .. "pc" }))
          fn(p, a)
        end
      end
    end
  end
end

-- Relentless Earthstorm Diamond and other crit-damage metas
S.ITEM_EFFECTS = S.ITEM_EFFECTS or {}
S.ITEM_EFFECTS[32409] = function(p) p.ps.CritDamageMultiplier = p.ps.CritDamageMultiplier * 1.03 end
S.ITEM_EFFECTS[34220] = S.ITEM_EFFECTS[32409] -- Chaotic Skyfire Diamond

-- ---------------------------------------------------------------------------------------------------------------
-- Target (target.go NewTarget)
-- ---------------------------------------------------------------------------------------------------------------
function S.BuildTarget(opts)
  local t = S.NewUnit("enemy", "Target 1")
  t.level = opts.level or 73
  t.mobType = opts.mobType or "Mechanical"
  t:AddStat(ST.Armor, opts.armor or 7685)
  t:AddStat(ST.AttackPower, opts.ap or 320)
  t:AddStat(ST.BlockValue, 54)
  t.ps.CanBlock, t.ps.CanParry, t.ps.InFrontOfTarget = true, true, true
  t.metrics = nil
  t.reactionTime = 1.62
  return t
end

-- Attack table for a player defender (self damage from sappers).
function S.NewPlayerDefenderTable(attacker, defender)
  return { attacker = attacker, defender = defender, critMultiplier = 1, damageDealtMultiplier = 1,
    damageTakenMultiplier = 1, armorIgnoreFactor = 0, bonusSpellCritPercent = 0, baseSpellMiss = 0.05,
    baseMiss = 0.05, baseBlock = 0.05, baseDodge = 0, baseParry = 0.05, baseGlance = 0, glanceMultiplier = 1,
    hitSuppression = 0, meleeCritSuppression = 0, spellCritSuppression = 0 }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Run
-- ---------------------------------------------------------------------------------------------------------------
-- Run `iterations` fights; returns { dps, stdev, stderr, abilities = { key -> { dps, casts, hits, crits } } }.
function S.RunIterations(sim, p, from, to)
  for i = from, to do sim:RunOnce(i) end
end

function S.Summarize(sim, p)
  local m = p.metrics
  local n = m.iterations
  local sum, sq = 0, 0
  for i = 1, n do sum = sum + m.iterDps[i]; sq = sq + m.iterDps[i] ^ 2 end
  local mean = sum / n
  local sd = sqrt(max(0, sq / n - mean * mean))
  local abilities = {}
  local dur = m.totalDuration / n
  for k, a in pairs(m.byKey) do
    abilities[k] = { dps = a.damage / n / dur, casts = a.casts / n, hits = a.hits / n, crits = a.crits / n,
      glances = (a.glances or 0) / n, misses = (a.misses or 0) / n, dodges = (a.dodges or 0) / n,
      partials = (a.partials or 0) / n }
  end
  local mana = {}
  for k, v in pairs(m.mana) do mana[k] = v / n end
  return { dps = mean, stdev = sd, stderr = sd / sqrt(n), iterations = n, abilities = abilities, mana = mana }
end

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Items.lua", ...) then return end -- DisasterZone: Sim/Items.lua
-- ns.GearSim hand-written item effects (WoWSims sim/common/tbc/items_*.go, classic/items_trinkets.go): the ones
-- the generic proc / on-use data can't express. Only effects that change melee damage, haste or mana are here;
-- purely defensive ones (absorbs, armor procs, heals) are left out on purpose.
--
-- Deliberate deviation from WoWSims: Hand of Justice procs with any melee weapon (WoWSims only lets it proc when the
-- weapon is a sword, a copy of Sword Specialization's rule; the game has no such limit).
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

S.ITEM_EFFECTS = S.ITEM_EFFECTS or {}
local IE = S.ITEM_EFFECTS

-- The hand an item sits in, for weapon procs (NewDynamicLegacyProcForWeapon).
local function WeaponMask(p, itemId)
  local m = 0
  if p.gearIds.MainHand == itemId then m = m + PM.MeleeMH end
  if p.gearIds.OffHand == itemId then m = m + PM.MeleeOH end
  return m
end

-- itemhelpers.CreateWeaponProcTrigger: a chance-on-hit weapon proc on landed hits.
local function WeaponProc(p, itemId, ppm, handler, immediately)
  p:MakeProcTriggerAura({ name = "weapon " .. itemId, callback = "hit", outcome = O.Landed,
    dpm = S.NewPPM(p, ppm, WeaponMask(p, itemId)), isWeaponProc = true, triggerImmediately = immediately,
    handler = handler })
end

-- An extra main-hand white swing (Hand of Justice, Blinkstrike, Windfury): a copy of the auto attack.
local function ExtraAttackSpell(p, key)
  local aa = p.autoAttacks
  return p:RegisterSpell({
    id = "melee_" .. key, metricsKey = "melee", school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    procMask = PM.MeleeMHAuto, flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete + F.PassiveSpell,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
    end,
  })
end

-- MakeStackingAura: +bonus per stack
local function StackingStatAura(p, label, duration, maxStacks, bonus)
  local a = p:RegisterAura({ label = label, duration = duration, maxStacks = maxStacks })
  a.onStacksChange = function(aura, sim, old, new)
    local d = new - old
    local t = {}
    for k, v in pairs(bonus) do t[k] = v * d end
    p:AddStatsDynamic(sim, t)
  end
  return a
end

-- Hand of Justice: 1.3333% per landed hit, 2 s cooldown, one extra main-hand swing.
IE[11815] = function(p)
  local spell = ExtraAttackSpell(p, "hoj")
  local mask = 0
  if p.gear.MainHand then mask = mask + PM.MeleeMH end
  if p.gear.OffHand and p.gear.OffHand.item.weaponType and p.gear.OffHand.item.weaponType ~= 5 and p.gear.OffHand.item.weaponType ~= 7 then
    mask = mask + PM.MeleeOH
  end
  p:MakeProcTriggerAura({ name = "Hand Of Justice", dpm = S.NewPPM(p, 0, mask, 0.013333), icd = 2,
    triggerImmediately = true, outcome = O.Landed, callback = "hit",
    handler = function(sim, _, result) spell:Cast(sim, result.target) end })
end

-- Despair: 600 physical damage, PPM 1, can't be dodged / parried / blocked.
IE[28573] = function(p)
  local spell = p:RegisterSpell({ id = 34580, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.Empty,
    flags = F.PassiveSpell + F.IgnoreResists + F.NoOnCastComplete + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, target, sp)
      sp:CalcAndDealDamage(sim, target, 600, OUT.MeleeSpecialNoBlockDodgeParry)
    end })
  WeaponProc(p, 28573, 1, function(sim, _, result) spell:Cast(sim, result.target) end, true)
end

-- Bonereaver's Edge: PPM 2, +700 armor penetration per stack (3), 10 s.
IE[17076] = function(p)
  local a = StackingStatAura(p, "Bonereaver's Edge", 10, 3, { [ST.ArmorPenetration] = 700 })
  WeaponProc(p, 17076, 2, function(sim) a:Activate(sim); a:AddStack(sim) end)
end

-- World Breaker: PPM 1, +900 crit rating for the next 2 melee hits (4 s).
IE[30090] = function(p)
  local a = p:RegisterAura({ label = "World Breaker", duration = 4, maxStacks = 2 })
  a:AttachStatBuff(ST.MeleeCritRating, 900)
  S.AttachProcTrigger(a, p, { name = "World Breaker - Consume", procMask = PM.Melee, callback = "hit",
    handler = function(sim) if a.active then a:RemoveStack(sim) end end })
  WeaponProc(p, 30090, 1, function(sim) a:Activate(sim); a:AddStack(sim) end, true)
end

-- Warp Slicer / Devastation: PPM 2, attack speed +20% for 30 s.
local function SpeedInfusion(id)
  IE[id] = function(p)
    local a = p:RegisterAura({ label = "Speed Infusion", duration = 30 })
    a:AttachMultiplyAttackSpeed(1.2)
    WeaponProc(p, id, 2, function(sim) a:Activate(sim) end)
  end
end
SpeedInfusion(30311)
SpeedInfusion(30316)

-- Infinity Blade: PPM 2, target takes +5% magic damage per stack (5), 30 s.
IE[30312] = function(p)
  local t = p.currentTarget
  local schools = { SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Holy, SCHOOL.Nature, SCHOOL.Shadow }
  local a = t:RegisterAura({ label = "Magic Disruption", duration = 30, maxStacks = 5,
    onStacksChange = function(_, _, old, new)
      for _, s in ipairs(schools) do
        local i = S.SCHOOL_INDEX[s]
        t.ps.SchoolDamageTakenMultiplier[i] = t.ps.SchoolDamageTakenMultiplier[i] * (1 + 0.05 * new) / (1 + 0.05 * old)
      end
    end })
  WeaponProc(p, 30312, 2, function(sim) a:Activate(sim); a:AddStack(sim) end)
end

-- Jom Gabbar: use, +65 AP every 2 s for 20 s (10 stacks), 2 min, shares the offensive trinket timer.
IE[23570] = function(p)
  local a = StackingStatAura(p, "Jom Gabbar", 20, 10, { [ST.AttackPower] = 65, [ST.RangedAttackPower] = 65 })
  local og = a.onGain
  a.onGain = function(aura, sim)
    if og then og(aura, sim) end
    for i = 0, 9 do
      sim:Add({ at = sim.now + i * 2, prio = S.PRIO_AUTO, fn = function(s) if aura.active then aura:AddStack(s) end end })
    end
  end
  local spell = p:RegisterSpell({ id = 29602, procMask = PM.Empty, flags = F.NoOnCastComplete, cd = 120,
    sharedCd = 20, sharedCdTimer = p:CategoryTimer(1141),
    applyEffects = function(sim) a:Activate(sim) end })
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end

-- Romulo's Poison Vial: PPM 1 on melee / ranged hits, 222-332 nature damage.
IE[28579] = function(p)
  local spell = p:RegisterSpell({ id = 34587, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
    flags = F.PassiveSpell + F.NoOnCastComplete + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, target, sp) sp:CalcAndDealDamage(sim, target, sim:Roll(222, 332), OUT.MagicHit) end })
  p:MakeProcTriggerAura({ name = "Romulo's Poison Vial", dpm = S.NewPPM(p, 1, PM.MeleeOrRanged), requireDamageDealt = true,
    outcome = O.Landed, callback = "hit", handler = function(sim, _, result) spell:Cast(sim, result.target) end })
end

-- Darkmoon Card: Crusade: +6 AP per landed melee hit (20 stacks, 10 s); +8 spell damage per landed class spell.
IE[31856] = function(p)
  local melee = StackingStatAura(p, "Aura of the Crusader (Melee)", 10, 20, { [ST.AttackPower] = 6, [ST.RangedAttackPower] = 6 })
  local caster = StackingStatAura(p, "Aura of the Crusader (Caster)", 10, 10, { [ST.SpellDamage] = 8 })
  p:MakeProcTriggerAura({ name = "DMC Crusade (Melee)", procMask = PM.MeleeOrRanged, outcome = O.Landed, callback = "hit",
    handler = function(sim) melee:Activate(sim); melee:AddStack(sim) end })
  p:MakeProcTriggerAura({ name = "DMC Crusade (Caster)", procMask = PM.SpellDamage, canProcFromProcs = true,
    classSpellsOnly = true, outcome = O.Landed, callback = "hit",
    handler = function(sim) caster:Activate(sim); caster:AddStack(sim) end })
end

-- Darkmoon Card: Wrath: +17 crit rating per non-crit landed hit (20 stacks, 10 s), reset by a crit.
IE[31857] = function(p)
  local a = StackingStatAura(p, "Aura of Wrath", 10, 20, { [ST.MeleeCritRating] = 17, [ST.SpellCritRating] = 17 })
  p:MakeProcTriggerAura({ name = "Darkmoon Card: Wrath", procMask = PM.Direct, outcome = O.Landed, callback = "hit",
    handler = function(sim, _, result)
      if has(result.outcome, O.Crit) then a:Deactivate(sim) else a:Activate(sim); a:AddStack(sim) end
    end })
end

-- Mark of the Champion: +150 attack power (or +85 spell damage) against undead and demons.
IE[23206] = function(p)
  p.postFinalize[#p.postFinalize + 1] = function()
    for t, at in pairs(p.attackTables) do
      if t.mobType == "Undead" or t.mobType == "Demon" then at.mobBonusAP = (at.mobBonusAP or 0) + 150 end
    end
  end
end
IE[23207] = function(p)
  p.postFinalize[#p.postFinalize + 1] = function()
    for t, at in pairs(p.attackTables) do
      if t.mobType == "Undead" or t.mobType == "Demon" then at.mobBonusSP = (at.mobBonusSP or 0) + 85 end
    end
  end
end

-- Braided Eternium Chain: +28 melee crit rating to the party, the wearer included (exclusive with the party buff).
IE[24114] = function(p) p:AddStat(ST.MeleeCritRating, 28) end
-- Eye of the Night: +34 spell damage to the party.
IE[24116] = function(p) p:AddStat(ST.SpellDamage, 34) end
-- Chain of the Twilight Owl: +2% spell crit to the party.
IE[24121] = function(p) p:AddStat(ST.SpellCritPercent, 2) end

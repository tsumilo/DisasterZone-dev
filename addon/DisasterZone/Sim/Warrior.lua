if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Warrior.lua", ...) then return end -- DisasterZone: Sim/Warrior.lua
-- ns.GearSim Warriors (WoWSims sim/warrior): rage, stances, shouts, the Heroic Strike / Cleave queue, the DPS
-- abilities, Arms and Fury talents (Protection's DPS-relevant ones), tier sets. Built in WoWSims' order:
-- SetupWarrior (constructor) before racials, WarriorApplyTalents after item effects, WarriorInitialize (the
-- class spells) after consumables.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (proto/warrior.proto field order; trees of 23, 21, 22)
-- ---------------------------------------------------------------------------------------------------------------
local TALENTS = {
  { "ImprovedHeroicStrike", "Deflection", "ImprovedRend", "ImprovedCharge", "IronWill", "ImprovedThunderClap",
    "ImprovedOverpower", "AngerManagement", "DeepWounds", "TwoHandedWeaponSpecialization", "Impale",
    "PoleaxeSpecialization", "DeathWish", "MaceSpecialization", "SwordSpecialization", "ImprovedIntercept",
    "ImprovedHamstring", "ImprovedDisciplines", "BloodFrenzy", "MortalStrike", "SecondWind", "ImprovedMortalStrike",
    "EndlessRage" },
  { "BoomingVoice", "Cruelty", "ImprovedDemoralizingShout", "UnbridledWrath", "ImprovedCleave", "PiercingHowl",
    "BloodCraze", "CommandingPresence", "DualWieldSpecialization", "ImprovedExecute", "Enrage", "ImprovedSlam",
    "SweepingStrikes", "WeaponMastery", "ImprovedBerserkerRage", "Flurry", "Precision", "Bloodthirst",
    "ImprovedWhirlwind", "ImprovedBerserkerStance", "Rampage" },
  { "ImprovedBloodrage", "TacticalMastery", "Anticipation", "ShieldSpecialization", "Toughness", "LastStand",
    "ImprovedShieldBlock", "ImprovedRevenge", "Defiance", "ImprovedSunderArmor", "ImprovedDisarm", "ImprovedTaunt",
    "ImprovedShieldWall", "ConcussionBlow", "ImprovedShieldBash", "ShieldMastery", "OneHandedWeaponSpecialization",
    "ImprovedDefensiveStance", "ShieldSlam", "FocusedRage", "Vitality", "Devastate" },
}
S.WARRIOR_TALENTS = TALENTS

-- talentsString "3400502130201-0505..." -> { name = points }
function S.ParseTalentTrees(trees, str)
  local t = {}
  for _, tree in ipairs(trees) do for _, n in ipairs(tree) do t[n] = 0 end end
  local parts = {}
  for part in ((str or "") .. "-"):gmatch("([^%-]*)%-") do parts[#parts + 1] = part end
  for ti, tree in ipairs(trees) do
    local s = parts[ti] or ""
    for i = 1, #s do
      local name = tree[i]
      if name then t[name] = tonumber(s:sub(i, i)) or 0 end
    end
  end
  return t
end

-- ---------------------------------------------------------------------------------------------------------------
-- Class spell masks (warrior.go)
-- ---------------------------------------------------------------------------------------------------------------
local M = {}
do
  local names = { "BattleShout", "CommandingShout", "BerserkerRage", "Recklessness", "DeathWish", "Retaliation",
    "RetaliationHit", "Rampage", "ShieldWall", "LastStand", "Charge", "Intercept", "DemoralizingShout",
    "BattleStance", "BerserkerStance", "DefensiveStance", "Rend", "DeepWounds", "SweepingStrikes",
    "SweepingStrikesHit", "SweepingStrikesNormalizedHit", "HeroicStrike", "Cleave", "Devastate", "Execute",
    "Overpower", "Revenge", "Slam", "SunderArmor", "ThunderClap", "Whirlwind", "WhirlwindOh", "ShieldSlam",
    "ConcussionBlow", "ShieldBash", "Bloodthirst", "MortalStrike", "ShieldBlock", "Hamstring", "Pummel" }
  local bit = 2
  for _, n in ipairs(names) do M[n] = bit; bit = bit * 2 end
  M.Shouts = M.CommandingShout + M.BattleShout + M.DemoralizingShout
  M.DirectDamage = M.SweepingStrikesHit + M.SweepingStrikesNormalizedHit + M.Cleave + M.Execute + M.HeroicStrike +
    M.Overpower + M.Revenge + M.Slam + M.ShieldBash + M.SunderArmor + M.ThunderClap + M.Whirlwind + M.WhirlwindOh +
    M.ShieldSlam + M.Bloodthirst + M.MortalStrike + M.Intercept + M.Devastate + M.RetaliationHit
  M.Damage = M.DirectDamage + M.DeepWounds + M.Rend
end
S.WARRIOR_MASK = M

local BATTLE, DEFENSIVE, BERSERKER = 1, 2, 4

-- The hands holding a weapon type (character.go GetProcMaskForTypes)
local function ProcMaskForTypes(p, ...)
  local aa = p.autoAttacks
  local mh, oh = false, false
  for _, wt in ipairs({ ... }) do
    if aa.mh.weaponType == wt then mh = true end
    if aa.isDualWielding and aa.oh.weaponType == wt then oh = true end
  end
  return (mh and PM.MeleeMH or 0) + (oh and PM.MeleeOH or 0)
end
S.ProcMaskForTypes = ProcMaskForTypes

local WT_AXE, WT_MACE, WT_POLEARM, WT_SWORD = 1, 4, 6, 9

-- MakeStackingAura: +bonus per stack
function S.StackingStatAura(p, label, duration, maxStacks, bonus, actionId)
  local a = p:RegisterAura({ label = label, duration = duration, maxStacks = maxStacks, actionId = actionId })
  local osc = a.onStacksChange
  a.onStacksChange = function(aura, sim, old, new)
    if osc then osc(aura, sim, old, new) end
    local d = new - old
    local t = {}
    for k, v in pairs(bonus) do t[k] = v * d end
    p:AddStatsDynamic(sim, t)
  end
  return a
end

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (warrior.go NewWarrior, dps.go)
-- opts: { startingRage, defaultShout ("Battle" | "Commanding" | "None"), defaultStance, queueDelay (s),
--         stanceSnapshot, hasBsT2, hasBsSolarianSapphire }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupWarrior(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local war = {
    opts = opts, talents = T,
    defaultShout = opts.defaultShout or "Battle", defaultStance = opts.defaultStance or "Berserker",
    queueDelay = opts.queueDelay or 0.25, stanceSnapshot = opts.stanceSnapshot ~= false,
    hasBsT2 = opts.hasBsT2 ~= false, hasBsSolarianSapphire = opts.hasBsSolarianSapphire == true,
    chargeRageGain = 15, berserkerRageRageGain = 0,
  }
  p.warrior = war
  p:EnableRageBar({ maxRage = 100, baseRageMultiplier = 1, startingRage = opts.startingRage or 50 })
  p.ps.CanParry = true
  p:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  p:AddStatDependency(ST.Strength, ST.BlockValue, 1 / 20)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Warrior)
  p:AddStatDependency(ST.BonusArmor, ST.Armor, 1)
  war.sharedShoutsCD = p:NewTimer()
  war.sharedMCD = p:NewTimer()
  war.queuedRealismICD = { timer = p:NewTimer(), duration = war.queueDelay }
  p.autoAttacks.mh.replaceSwing = function(sim, swing) return S.WarriorTryHSOrCleave(p, sim, swing) end
  p:RegisterResetEffect(function()
    war.curQueueAura, war.curQueuedAutoSpell = nil, nil
    war.chargeRageGain, war.berserkerRageRageGain = 15, 0
    war.stance = (war.defaultStance == "Battle" and BATTLE) or (war.defaultStance == "Defensive" and DEFENSIVE) or BERSERKER
  end)
  war.stance = BERSERKER
  return war
end

local function StanceMatches(war, mask) return has(mask, war.stance) end

-- ---------------------------------------------------------------------------------------------------------------
-- Heroic Strike / Cleave queue (heroic_strike_cleave.go)
-- ---------------------------------------------------------------------------------------------------------------
local function ConsumeQueue(p, sim)
  local war = p.warrior
  if war.curQueueAura then war.curQueueAura:Deactivate(sim) end
end

local function MakeQueueSpellAndAura(p, src)
  local war = p.warrior
  local queued = false
  local qa = p:RegisterAura({ label = "HS/Cleave Queue Aura-" .. src.id, actionId = { spellId = src.id, tag = 1 } })
  qa.onReset = function() queued = false end
  qa.onGain = function(a, sim)
    if war.curQueueAura then war.curQueueAura:Deactivate(sim) end
    p.ps.DisableDWMissPenalty = true
    war.curQueueAura = a
    war.curQueuedAutoSpell = src
  end
  qa.onExpire = function()
    p.ps.DisableDWMissPenalty = false
    war.curQueueAura = nil
    war.curQueuedAutoSpell = nil
  end
  local icd = war.queuedRealismICD
  return p:RegisterSpell({ id = src.id, tag = 1, school = SCHOOL.Physical, defenseType = src.defenseType,
    procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics + F.APL + F.NoMetrics, nonEmpty = true,
    extraCastCondition = function(sim)
      return war.curQueueAura == nil and not queued and p.rage >= src:CurrentCost() and icd.timer.readyAt <= sim.now
    end,
    applyEffects = function(sim)
      if icd.timer.readyAt <= sim.now then
        queued = true
        icd.timer.readyAt = sim.now + icd.duration
        sim:Add({ at = sim.now + icd.duration, prio = 0, fn = function(s)
          qa:Activate(s)
          queued = false
        end })
      end
    end })
end

function S.WarriorTryHSOrCleave(p, sim, swing)
  local war = p.warrior
  local qa = war.curQueueAura
  if not (qa and qa.active) or (swing.tag ~= 1 and swing.tag ~= 12281) then
    p.ps.DisableDWMissPenalty = false
    return swing
  end
  if not war.curQueuedAutoSpell:CanCast(sim, p.currentTarget) then
    qa:Deactivate(sim)
    return swing
  end
  return war.curQueuedAutoSpell
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents_arms.go, talents_fury.go, talents_protection.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.WarriorApplyTalents(p)
  local war, T = p.warrior, p.talents
  local aa = p.autoAttacks

  -- Arms
  if T.ImprovedHeroicStrike > 0 then
    p:AddStaticMod({ classMask = M.HeroicStrike, kind = "PowerCost_Flat", value = -T.ImprovedHeroicStrike })
  end
  if T.ImprovedRend > 0 then
    p:AddStaticMod({ classMask = M.Rend, kind = "DamageDone_Flat", value = 0.25 * T.ImprovedRend })
  end
  if T.ImprovedCharge > 0 then war.chargeRageGain = war.chargeRageGain + 3 + T.ImprovedCharge end
  if T.ImprovedThunderClap > 0 then
    p:AddStaticMod({ classMask = M.ThunderClap, kind = "DamageDone_Flat", value = ({ 0, 0.4, 0.7, 1.0 })[T.ImprovedThunderClap + 1] })
    p:AddStaticMod({ classMask = M.ThunderClap, kind = "PowerCost_Flat", value = -({ 0, 1, 2, 4 })[T.ImprovedThunderClap + 1] })
  end
  if T.ImprovedOverpower > 0 then
    local a = S.MakePermanent(p:RegisterAura({ label = "Improved Overpower", actionId = { spellId = 12963, tag = T.ImprovedOverpower } }))
    a:AttachSpellMod({ classMask = M.Overpower, kind = "BonusCrit_Percent", value = 25 * T.ImprovedOverpower })
  end
  if T.AngerManagement > 0 then
    S.Periodic(p, 3, 0, function(sim) if sim.now > 0 then p:AddRage(sim, 1, "anger_management") end end)
  end
  if T.DeepWounds > 0 then
    war.deepWounds = p:RegisterSpell({ id = 12867, school = SCHOOL.Physical, procMask = PM.Empty, classMask = M.DeepWounds,
      flags = F.NoOnCastComplete + F.IgnoreResists + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
      dot = { label = "DeepWounds", numberOfTicks = 6, tickLength = 3,
        onSnapshot = function(sim, target, dot)
          local base = S.WeaponAverageDamage(aa.mh, dot.spell:MeleeAttackPower(target))
          dot:SnapshotPhysical(target, base / dot:HastedTickCount() * 0.2 * T.DeepWounds)
        end,
        onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
      applyEffects = function(sim, target, spell)
        spell:CalcAndDealOutcome(sim, target, OUT.AlwaysHitNoHitCounter)
        spell:Dot(target):Deactivate(sim)
        spell:Dot(target):Apply(sim)
      end })
    p:MakeProcTriggerAura({ name = "Deep Wounds - Trigger", triggerImmediately = true, procMaskExclude = PM.Empty,
      outcome = O.Crit, callback = "hit",
      extraCondition = function(sim, spell) return has(spell.school or 0, SCHOOL.Physical) end,
      handler = function(sim, spell, result) war.deepWounds:Cast(sim, result.target) end })
  end
  if T.TwoHandedWeaponSpecialization > 0 then
    local mod = p:AddDynamicMod({ classMask = M.DirectDamage, school = SCHOOL.Physical, kind = "DamageDone_Pct",
      value = 0.01 * T.TwoHandedWeaponSpecialization })
    if aa.mh.twoHand then mod:Activate() end
  end
  if T.Impale > 0 then
    p:AddStaticMod({ classMask = M.Damage, kind = "CritMultiplier_Flat", value = 0.1 * T.Impale })
  end
  if T.PoleaxeSpecialization > 0 then
    local crit = T.PoleaxeSpecialization
    local function pa(w) return w and (w.weaponType == WT_AXE or w.weaponType == WT_POLEARM) end
    if pa(aa.mh) then
      p:AddStaticMod({ kind = "BonusCrit_Percent", procMask = PM.MeleeMH, value = crit })
      p:AddStaticMod({ kind = "BonusCrit_Percent", classMask = M.WhirlwindOh, value = crit })
    end
    if aa.isDualWielding and pa(aa.oh) then
      p:AddStaticMod({ kind = "BonusCrit_Percent", procMask = PM.MeleeOH, value = crit })
      p:AddStaticMod({ kind = "BonusCrit_Percent", classMask = M.WhirlwindOh, value = -crit })
    end
  end
  if T.DeathWish > 0 then
    local a = p:RegisterAura({ label = "Death Wish", actionId = { spellId = 12292 }, duration = 30 })
    a:AttachMultiplicativePseudoStatBuff("SchoolDamageDealtMultiplier", 1.2, S.SCHOOL_INDEX[SCHOOL.Physical])
    a:AttachMultiplicativePseudoStatBuff("DamageTakenMultiplier", 1.05)
    local spell = p:RegisterSpell({ id = 12292, classMask = M.DeathWish, rageCost = { cost = 10 }, gcd = 1.5,
      ignoreHaste = true, cd = 180, relatedSelfBuff = a,
      applyEffects = function(sim)
        a:Activate(sim)
        p:WaitUntil(sim, sim.now + 1.5)
      end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.MaceSpecialization > 0 then
    local spell = p:RegisterSpell({ id = 5530, defenseType = S.DEF_MAGIC,
      applyEffects = function(sim) p:AddRage(sim, 7, "mace_specialization") end })
    local dpm = S.NewPPM(p, 0.3 * T.MaceSpecialization, ProcMaskForTypes(p, WT_MACE))
    p:MakeProcTriggerAura({ name = "Mace Specialization", dpm = dpm, triggerImmediately = true, outcome = O.Landed,
      callback = "hit", handler = function(sim, _, result) spell:Cast(sim, result.target) end })
  end
  if T.SwordSpecialization > 0 then
    local dpm = S.NewPPM(p, 0, ProcMaskForTypes(p, WT_SWORD), 0.01 * T.SwordSpecialization)
    local swordSpell
    p:MakeProcTriggerAura({ name = "Sword Specialization", procMask = PM.Melee, dpm = dpm, icd = 0.5,
      triggerImmediately = true, outcome = O.Landed, callback = "hit",
      handler = function(sim, spell, result)
        if spell:Matches(M.WhirlwindOh) then return end
        if not swordSpell then swordSpell = S.WarriorExtraSwing(p, 12281) end
        local sp = S.MaybeReplaceMHSwing(p, sim, swordSpell)
        sp:Cast(sim, result.target)
      end })
  end
  if T.ImprovedIntercept > 0 then
    p:AddStaticMod({ classMask = M.Intercept, kind = "Cooldown_Flat", value = -5 * T.ImprovedIntercept })
  end
  if T.ImprovedDisciplines > 0 then
    local cdr = ({ 0, 240, 420, 600 })[T.ImprovedDisciplines + 1]
    p:AddStaticMod({ classMask = M.Retaliation + M.Recklessness + M.ShieldWall, kind = "Cooldown_Flat", value = -cdr })
    p:AddStaticMod({ classMask = M.Retaliation + M.Recklessness + M.ShieldWall, kind = "BuffDuration_Flat",
      value = 2 * T.ImprovedDisciplines })
  end
  if T.BloodFrenzy > 0 then
    p:MakeProcTriggerAura({ name = "Blood Frenzy", canProcFromProcs = true, classMask = M.Rend + M.DeepWounds,
      callback = "hit",
      handler = function(sim, spell, result)
        local a = S.BloodFrenzyAura(result.target, T.BloodFrenzy)
        a.duration = spell:Dot(result.target):RemainingDuration(sim)
        a:Activate(sim)
      end })
  end
  if T.MortalStrike > 0 then
    p:RegisterSpell({ id = 30330, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      flags = F.APL + F.MeleeMetrics, classMask = M.MortalStrike, rageCost = { cost = 30, refund = 0.8 },
      gcd = 1.5, cd = 6, ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = 210 + S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        if not S.Landed(r) then spell:IssueRefund(sim) end
      end })
  end
  if T.ImprovedMortalStrike > 0 then
    p:AddStaticMod({ classMask = M.MortalStrike, kind = "Cooldown_Flat", value = -0.2 * T.ImprovedMortalStrike })
    p:AddStaticMod({ classMask = M.MortalStrike, kind = "DamageDone_Flat", value = 0.01 * T.ImprovedMortalStrike })
  end
  if T.EndlessRage > 0 then p:MultiplyAutoAttackRageGen(1.25) end

  -- Fury
  if T.Cruelty > 0 then p:AddStat(ST.PhysicalCritPercent, T.Cruelty) end
  if T.UnbridledWrath > 0 then
    p:MakeProcTriggerAura({ name = "Unbridled Wrath", dpm = S.NewPPM(p, 3 * T.UnbridledWrath, PM.MeleeWhiteHit),
      requireDamageDealt = true, outcome = O.Landed, callback = "hit",
      handler = function(sim) p:AddRage(sim, 1, "unbridled_wrath") end })
  end
  if T.DualWieldSpecialization > 0 then
    p:AddStaticMod({ procMask = PM.MeleeOH, kind = "DamageDone_Pct", value = 0.05 * T.DualWieldSpecialization })
  end
  if T.ImprovedExecute > 0 then
    p:AddStaticMod({ classMask = M.Execute, kind = "PowerCost_Flat", value = -({ 0, 2, 5 })[T.ImprovedExecute + 1] })
  end
  if T.Enrage > 0 then
    local a = p:RegisterAura({ label = "Enrage", actionId = { spellId = 13048 }, duration = 12, maxStacks = 12 })
    a:AttachSpellMod({ school = SCHOOL.Physical, kind = "DamageDone_Pct", value = 0.05 * T.Enrage })
    S.AttachProcTrigger(a, p, { name = "Enrage - Spend", triggerImmediately = true, procMask = PM.Melee, callback = "hit",
      handler = function(sim) a:RemoveStack(sim) end })
    a:NewExclusiveEffect("Enrage", true, 5 * T.Enrage)
    war.enrageAura = a
    p:MakeProcTriggerAura({ name = "Enrage - Trigger", procMask = PM.Melee, outcome = O.Crit + O.SuppressedCrit,
      callback = "taken", handler = function(sim) a:Activate(sim); a:SetStacks(sim, 12) end })
  end
  if T.ImprovedSlam > 0 then
    p:AddStaticMod({ classMask = M.Slam, kind = "CastTime_Flat", value = -0.5 * T.ImprovedSlam })
  end
  if T.SweepingStrikes > 0 then
    -- single target: never sweeps; the spell exists for the rotation (and as a cooldown)
    local a = p:MakeProcTriggerAura({ name = "Sweeping Strikes", actionId = { spellId = 12723 }, duration = 10,
      callback = "hit", procMask = PM.Melee, outcome = O.Landed, triggerImmediately = true, handler = function() end })
    a.maxStacks = 10
    war.sweepingStrikesAura = a
    local spell = p:RegisterSpell({ id = 12723, classMask = M.SweepingStrikes, school = SCHOOL.Physical,
      rageCost = { cost = 30 }, cd = 30, relatedSelfBuff = a,
      extraCastCondition = function() return StanceMatches(war, BATTLE + BERSERKER) end,
      applyEffects = function(sim) a:Activate(sim); a:SetStacks(sim, 10) end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.WeaponMastery > 0 then p.ps.DodgeReduction = p.ps.DodgeReduction + 0.01 * T.WeaponMastery end
  if T.ImprovedBerserkerRage > 0 then
    local a = S.MakePermanent(p:RegisterAura({ label = "Improved Berserker Rage",
      actionId = { spellId = 20500, tag = T.ImprovedBerserkerRage } }))
    a.onGain = function() war.berserkerRageRageGain = war.berserkerRageRageGain + 5 * T.ImprovedBerserkerRage end
    a.onExpire = function() war.berserkerRageRageGain = war.berserkerRageRageGain - 5 * T.ImprovedBerserkerRage end
  end
  if T.Flurry > 0 then
    local a = p:RegisterAura({ label = "Flurry", actionId = { spellId = 12970 }, duration = 15, maxStacks = 3 })
    a:AttachMultiplyMeleeSpeed(1 + 0.05 * T.Flurry)
    p:MakeProcTriggerAura({ name = "Flurry - Trigger", procMask = PM.Melee, canProcFromProcs = true,
      triggerImmediately = true, callback = "hit", outcome = O.Landed,
      handler = function(sim, spell, result)
        if spell:Matches(M.WhirlwindOh) then return end
        if has(result.outcome, O.Crit) then
          a:Activate(sim)
          a:SetStacks(sim, 3)
          return
        end
        if a.active and has(PM.MeleeWhiteHit, spell.procMask) then a:RemoveStack(sim) end
      end })
  end
  if T.Precision > 0 then p:AddStat(ST.PhysicalHitPercent, T.Precision) end
  if T.Bloodthirst > 0 then
    p:RegisterSpell({ id = 30335, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      flags = F.MeleeMetrics + F.APL, classMask = M.Bloodthirst, rageCost = { cost = 30, refund = 0.8 },
      gcd = 1.5, ignoreHaste = true, cd = 6, damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealDamage(sim, target, spell:MeleeAttackPower(target) * 0.45, OUT.MeleeSpecialHitAndCrit)
        if not S.Landed(r) then spell:IssueRefund(sim) end
      end })
  end
  if T.ImprovedWhirlwind > 0 then
    p:AddStaticMod({ classMask = M.Whirlwind, kind = "Cooldown_Flat", value = -T.ImprovedWhirlwind })
  end
  if T.ImprovedBerserkerStance > 0 then
    war.impBerserkerStanceDep = p:NewDynamicMultiplyStat(ST.AttackPower, 1 + 0.02 * T.ImprovedBerserkerStance)
  end
  if T.Rampage > 0 then
    local validUntil = 0
    local a = S.StackingStatAura(p, "Rampage", 30, 5, { [ST.AttackPower] = 50 }, { spellId = 30033 })
    p:MakeProcTriggerAura({ name = "Rampage - Trigger", triggerImmediately = true, procMask = PM.Melee,
      canProcFromProcs = true, outcome = O.Landed, callback = "hit",
      handler = function(sim, spell, result)
        if has(result.outcome, O.Crit) then validUntil = sim.now + 5 end
        if has(PM.Melee, spell.procMask) and a.active then a:AddStack(sim) end
      end })
    p:RegisterResetEffect(function() validUntil = 0 end)
    local spell = p:RegisterSpell({ id = 30033, classMask = M.Rampage, flags = F.APL, nonEmpty = true, cd = 90,
      rageCost = { cost = 20 }, relatedSelfBuff = a,
      extraCastCondition = function(sim) return sim.now < validUntil end,
      applyEffects = function(sim)
        validUntil = 0
        a:Activate(sim)
        a:AddStack(sim)
      end })
    p:AddMajorCooldown({ spell = spell })
  end

  -- Protection (the parts that change damage)
  if T.Defiance > 0 then p:AddStat(ST.ExpertiseRating, 2 * T.Defiance * S.EXPERTISE_PER_QUARTER) end
  if T.OneHandedWeaponSpecialization > 0 and not aa.mh.twoHand then
    p:AddStaticMod({ school = SCHOOL.Physical, kind = "DamageDone_Pct", value = 0.02 * T.OneHandedWeaponSpecialization })
  end
  if T.Vitality > 0 then
    p:MultiplyStat(ST.Stamina, 1 + 0.01 * T.Vitality)
    p:MultiplyStat(ST.Strength, 1 + 0.02 * T.Vitality)
  end
end

-- An extra main-hand swing that is a copy of the auto attack (Sword Specialization, Windfury).
function S.WarriorExtraSwing(p, tag)
  local aa = p.autoAttacks
  return p:RegisterSpell({ id = "melee_" .. tag, metricsKey = "melee_" .. tag, tag = tag, school = SCHOOL.Physical,
    defenseType = S.DEF_MELEE, procMask = PM.MeleeMHAuto,
    flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete + F.PassiveSpell,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
    end })
end

-- attack.go MaybeReplaceMHSwing: Heroic Strike / Cleave take an extra swing too.
function S.MaybeReplaceMHSwing(p, sim, swing)
  local f = p.autoAttacks.mh.replaceSwing
  if not f then return swing end
  return f(sim, swing)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Class spells (warrior.go Initialize)
-- ---------------------------------------------------------------------------------------------------------------
function S.WarriorInitialize(p)
  local war, T = p.warrior, p.talents
  local aa = p.autoAttacks

  -- Recklessness
  do
    local a = p:RegisterAura({ label = "Recklessness", actionId = { spellId = 1719 }, duration = 15 })
    a:AttachSpellMod({ procMask = PM.MeleeSpecial, kind = "BonusCrit_Percent", value = 100 })
    a:AttachMultiplicativePseudoStatBuff("DamageTakenMultiplier", 1.2)
    local spell = p:RegisterSpell({ id = 1719, defenseType = S.DEF_MELEE, flags = F.APL, classMask = M.Recklessness,
      gcd = 1.5, cd = 1800, sharedCd = 1800, sharedCdTimer = war.sharedMCD, relatedSelfBuff = a,
      extraCastCondition = function() return StanceMatches(war, BERSERKER) end,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = spell })
  end

  -- Berserker Rage
  do
    local a = p:RegisterAura({ label = "Berserker Rage", actionId = { spellId = 18499 }, duration = 10 })
    local spell = p:RegisterSpell({ id = 18499, classMask = M.BerserkerRage, flags = F.APL, gcd = 1.5,
      ignoreHaste = true, cd = 30, relatedSelfBuff = a,
      extraCastCondition = function() return StanceMatches(war, BERSERKER) end,
      applyEffects = function(sim)
        if war.berserkerRageRageGain > 0 then p:AddRage(sim, war.berserkerRageRageGain, "berserker_rage") end
        a:Activate(sim)
      end })
    p:AddMajorCooldown({ spell = spell, shouldActivate = function()
      return war.berserkerRageRageGain > 0 and p.rage + war.berserkerRageRageGain <= p.maxRage
    end })
  end

  -- Bloodrage
  do
    local instant = 10 + 3 * T.ImprovedBloodrage
    local spell = p:RegisterSpell({ id = 2687, nonEmpty = true, cd = 60,
      applyEffects = function(sim)
        p:AddRage(sim, instant, "bloodrage")
        S.StartPeriodicAction(sim, { numTicks = 10, period = 1, onAction = function(s) p:AddRage(s, 1, "bloodrage") end })
      end })
    p:AddMajorCooldown({ spell = spell, shouldActivate = function() return p.rage < 70 end })
  end

  -- Hamstring
  p:RegisterSpell({ id = 25212, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + F.APL, classMask = M.Hamstring, rageCost = { cost = 10, refund = 0.8 }, gcd = 1.5,
    ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1.25,
    extraCastCondition = function() return StanceMatches(war, BERSERKER) end,
    applyEffects = function(sim, target, spell)
      local r = spell:CalcAndDealDamage(sim, target, 63, OUT.MeleeSpecialHitAndCrit)
      if not S.Landed(r) then spell:IssueRefund(sim) end
    end })

  -- Rend
  war.rend = p:RegisterSpell({ id = 25208, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, classMask = M.Rend,
    procMask = PM.MeleeMHSpecial, flags = F.NoOnCastComplete + F.APL, rageCost = { cost = 10, refund = 0.8 },
    gcd = 1.5, ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1,
    extraCastCondition = function() return StanceMatches(war, BATTLE + DEFENSIVE) end,
    dot = { label = "Rend", numberOfTicks = 7, tickLength = 3,
      onSnapshot = function(sim, target, dot)
        dot.snapshotBaseDamage = 26 + S.WeaponAverageDamage(aa.mh, dot.spell:MeleeAttackPower(target)) * 0.00743
        dot.snapshotAttackerMultiplier = dot.spell:AttackerDamageMultiplier(p.attackTables[target], true)
      end,
      onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
    applyEffects = function(sim, target, spell)
      local r = spell:CalcAndDealOutcome(sim, target, OUT.MeleeSpecialHit)
      if S.Landed(r) then spell:Dot(target):Apply(sim) else spell:IssueRefund(sim) end
    end })

  -- Sunder Armor
  do
    local function sunderSpell(cfg, outcome)
      return p:RegisterSpell({ id = 25225, tag = cfg.tag, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
        procMask = PM.MeleeMHSpecial, flags = cfg.flags or 0, classMask = M.SunderArmor, rageCost = cfg.rageCost,
        gcd = cfg.gcd or 0, ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1,
        extraCastCondition = function(sim, target)
          local a = S.SunderArmorAura(target)
          return a.active or not S.CategoryAnyActive(target, "MajorArmorReduction")
        end,
        applyEffects = function(sim, target, spell)
          local r = spell:CalcOutcome(sim, target, outcome)
          if S.Landed(r) then
            local a = S.SunderArmorAura(target)
            a:Activate(sim)
            a:AddStack(sim)
          elseif spell.cost then
            spell:IssueRefund(sim)
          end
          spell:DealDamage(sim, r)
        end })
    end
    sunderSpell({ flags = F.MeleeMetrics + F.APL, rageCost = { cost = 15, refund = 0.8 }, gcd = 1.5 }, OUT.MeleeSpecialNoCrit)
  end

  -- Heroic Strike / Cleave
  do
    local hs = p:RegisterSpell({ id = 29707, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMH,
      flags = F.MeleeMetrics, classMask = M.HeroicStrike, rageCost = { cost = 15, refund = 0.8 }, nonEmpty = true,
      damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = 176 + S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        ConsumeQueue(p, sim)
        spell:DealDamage(sim, r)
        if not S.Landed(r) then spell:IssueRefund(sim) end
      end })
    MakeQueueSpellAndAura(p, hs)
    local flat = 70 * (1 + 0.4 * T.ImprovedCleave)
    local cleave = p:RegisterSpell({ id = 25231, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMH,
      flags = F.MeleeMetrics, classMask = M.Cleave, rageCost = { cost = 20 }, nonEmpty = true,
      damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = flat + S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        ConsumeQueue(p, sim)
        spell:DealDamage(sim, r)
      end })
    MakeQueueSpellAndAura(p, cleave)
  end

  -- Overpower
  do
    local a = p:RegisterAura({ label = "Overpower Aura", actionId = { spellId = 11585 }, duration = 5 })
    p:MakeProcTriggerAura({ name = "Overpower - Trigger", triggerImmediately = true, outcome = O.Dodge, callback = "hit",
      handler = function(sim) a:Activate(sim) end })
    p:RegisterSpell({ id = 11585, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      flags = F.MeleeMetrics + F.APL, classMask = M.Overpower, rageCost = { cost = 5, refund = 0.8 }, gcd = 1.5,
      cd = 5, ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 0.75,
      extraCastCondition = function() return StanceMatches(war, BATTLE) end,
      applyEffects = function(sim, target, spell)
        local base = 35 + S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeSpecialNoBlockDodgeParry)
        a:Deactivate(sim)
        if not S.Landed(r) then spell:IssueRefund(sim) end
      end })
  end

  -- Slam
  p:RegisterSpell({ id = 25242, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + F.APL, classMask = M.Slam, rageCost = { cost = 15, refund = 0.8 }, gcd = 1.5,
    castTime = 1.5, ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1,
    modifyCast = function(sim, spell, gcd, castTime)
      if castTime > 0 then aa:StopMeleeUntil(sim, sim.now + castTime) end
      return gcd, castTime
    end,
    applyEffects = function(sim, target, spell)
      local base = 140 + S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if not S.Landed(r) then spell:IssueRefund(sim) end
    end })

  -- Whirlwind
  do
    local wwOh = p:RegisterSpell({ id = 1680, tag = 2, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      procMask = PM.MeleeOHSpecial, classMask = M.WhirlwindOh,
      flags = F.MeleeMetrics + F.PassiveSpell + F.NoOnCastComplete, damageMultiplier = 1, threatMultiplier = 1.25,
      applyEffects = function(sim, target, spell)
        local base = 0.5 * S.WeaponNormalizedDamage(aa.oh, sim, spell:MeleeAttackPower(target))
        spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      end })
    p:RegisterSpell({ id = 1680, tag = 1, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      classMask = M.Whirlwind, flags = F.MeleeMetrics + F.APL, rageCost = { cost = 25 }, gcd = 1.5, cd = 10,
      ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1.25,
      extraCastCondition = function() return StanceMatches(war, BERSERKER) end,
      applyEffects = function(sim, target, spell)
        local base = S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        if aa.isDualWielding then wwOh:Cast(sim, target) end
      end })
  end

  -- Execute
  p:RegisterSpell({ id = 25236, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + F.APL, classMask = M.Execute, rageCost = { cost = 15, refund = 0.8 }, gcd = 1.5,
    ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1.25,
    extraCastCondition = function(sim) return StanceMatches(war, BERSERKER + BATTLE) and sim:IsExecute20() end,
    applyEffects = function(sim, target, spell)
      local extra = p.rage
      local cost = spell:CurrentCost()
      if extra > p.maxRage - cost then extra = p.maxRage - cost end
      p:SpendRage(sim, extra)
      local r = spell:CalcAndDealDamage(sim, target, 925 + 21 * extra, OUT.MeleeSpecialHitAndCrit)
      if not S.Landed(r) then spell:IssueRefund(sim) end
    end })

  S.WarriorRegisterStances(p)
  S.WarriorRegisterShouts(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stances (stances.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.WarriorRegisterStances(p)
  local war, T = p.warrior, p.talents
  local stanceCD = p:NewTimer()
  local maxRetained = 10 + 5 * T.TacticalMastery
  local function stanceAura(label, id)
    local a = p:RegisterAura({ label = label, actionId = { spellId = id } })
    a:NewExclusiveEffect("Stance", true, 0)
    return a
  end
  local battle = stanceAura("Battle Stance", 2457)
  local defensive = stanceAura("Defensive Stance", 71)
  defensive:AttachMultiplicativePseudoStatBuff("DamageTakenMultiplier", 0.9)
  defensive:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", 0.9)
  local berserker = stanceAura("Berserker Stance", 2458)
  berserker:AttachStatBuff(ST.PhysicalCritPercent, 3)
  if war.impBerserkerStanceDep then
    local dep = war.impBerserkerStanceDep
    local og, oe = berserker.onGain, berserker.onExpire
    berserker.onGain = function(a, sim) og(a, sim); p:EnableDynamicStatDep(sim, dep) end
    berserker.onExpire = function(a, sim) oe(a, sim); p:DisableDynamicStatDep(sim, dep) end
  end
  local function stanceSpell(stance, mask, defenseType, aura)
    return p:RegisterSpell({ id = aura.actionId.spellId, defenseType = defenseType, classMask = mask,
      flags = F.NoOnCastComplete + F.APL, cd = 1, cdTimer = stanceCD, relatedSelfBuff = aura,
      extraCastCondition = function() return war.stance ~= stance end,
      applyEffects = function(sim)
        if war.stanceSnapshot then
          sim:Add({ at = sim.now + 0.01, prio = 0, fn = function(s) aura:Activate(s) end })
        else
          aura:Activate(sim)
        end
        if p.rage > maxRetained then p:SpendRage(sim, p.rage - maxRetained) end
        war.stance = stance
      end })
  end
  stanceSpell(BATTLE, M.BattleStance, S.DEF_MELEE, battle)
  stanceSpell(DEFENSIVE, M.DefensiveStance, nil, defensive)
  stanceSpell(BERSERKER, M.BerserkerStance, S.DEF_MELEE, berserker)
  local def = (war.defaultStance == "Battle" and battle) or (war.defaultStance == "Defensive" and defensive) or berserker
  S.MakePermanent(def)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shouts (shouts.go, buffs.go BattleShoutAura / CommandingShoutAura)
-- ---------------------------------------------------------------------------------------------------------------
function S.BattleShoutValue(cpMult, sapphire, t2, prepull)
  local ap = 306
  if prepull then
    if sapphire then ap = ap + 70 end
    if t2 then ap = ap + 30 end
  end
  return floor(ap * cpMult)
end

function S.WarriorRegisterShouts(p)
  local war, T = p.warrior, p.talents
  local cp = 1 + 0.05 * T.CommandingPresence
  local dur = 120 * (1 + 0.1 * T.BoomingVoice)
  local function shoutAura(label, id, stat, value)
    local a = p:RegisterAura({ label = label, actionId = { spellId = id }, duration = dur })
    local ee
    ee = a:NewExclusiveEffect(label, true, 0,
      function(e, sim) p:AddStatDynamic(sim, stat, e.priority) end,
      function(e, sim) p:AddStatDynamic(sim, stat, -e.priority) end)
    local og = a.onGain
    a.onGain = function(aura, sim)
      if og then og(aura, sim) end
      ee:SetPriority(sim, value(sim.now <= 0))
    end
    return a, ee
  end
  local bs, bsEE = shoutAura("Battle Shout (Player)", 2048, ST.AttackPower,
    function(prepull) return S.BattleShoutValue(cp, war.hasBsSolarianSapphire, war.hasBsT2, prepull) end)
  local hasT6Tank2P = p:CouldHaveSetBonus("Onslaught Armor", 2)
  local cs, csEE = shoutAura("Commanding Shout (Player)", 469, ST.Health,
    function(prepull) return floor((1080 + ((prepull and hasT6Tank2P) and 170 or 0)) * cp) end)
  local function shoutSpell(id, cost, mask, aura, ee, value)
    return p:RegisterSpell({ id = id, classMask = mask, school = SCHOOL.Physical, flags = F.APL + F.Helpful,
      procMask = PM.Empty, rageCost = { cost = cost }, gcd = 1.5, ignoreHaste = true, threatMultiplier = 1,
      extraCastCondition = function(sim)
        return not aura.active or ee.priority <= value(sim.now < 0)
      end,
      applyEffects = function(sim, target, spell)
        spell:CalcAndDealOutcome(sim, target, OUT.AlwaysHit)
        aura:Activate(sim)
      end })
  end
  shoutSpell(2048, 10, M.BattleShout, bs, bsEE,
    function(prepull) return S.BattleShoutValue(cp, war.hasBsSolarianSapphire, war.hasBsT2, prepull) end)
  shoutSpell(469, 10, M.CommandingShout, cs, csEE,
    function(prepull) return floor((1080 + ((prepull and hasT6Tank2P) and 170 or 0)) * cp) end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Set bonuses and items (items.go)
-- ---------------------------------------------------------------------------------------------------------------
local SB = S.SET_BONUSES
SB["Warbringer Battlegear"] = {
  [2] = function(p, a) a:AttachSpellMod({ classMask = M.Whirlwind, kind = "PowerCost_Flat", value = -5 }) end,
  [4] = function(p, a)
    S.AttachProcTrigger(a, p, { name = "Warbringer Battlegear - 4PC", triggerImmediately = true, callback = "hit",
      outcome = O.Parry + O.Dodge, handler = function(sim) p:AddRage(sim, 2, "warbringer") end })
  end,
}
SB["Destroyer Battlegear"] = {
  [2] = function(p, a)
    local buff = p:NewTemporaryStatsAura("Overpower", { [ST.AttackPower] = 100 }, 5)
    S.AttachProcTrigger(buff, p, { name = "Destroyer Battlegear - 2PC - Consume", procMask = PM.MeleeSpecial,
      callback = "hit", outcome = O.Landed, triggerImmediately = true, handler = function(sim) buff:Deactivate(sim) end })
    S.AttachProcTrigger(a, p, { name = "Destroyer Battlegear - 2PC - Trigger", classMask = M.Overpower, callback = "hit",
      handler = function(sim) buff:Activate(sim) end })
  end,
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.MortalStrike + M.Bloodthirst, kind = "PowerCost_Flat", value = -5 }) end,
}
SB["Onslaught Battlegear"] = {
  [2] = function(p, a) a:AttachSpellMod({ classMask = M.Execute, kind = "PowerCost_Flat", value = -3 }) end,
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.MortalStrike + M.Bloodthirst, kind = "DamageDone_Flat", value = 0.05 }) end,
}
SB["Gladiator's Battlegear"] = {
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.Intercept, kind = "Cooldown_Flat", value = -5 }) end,
}

-- Ashtongue Talisman of Valor: 25% on landed Bloodthirst / Mortal Strike, +55 Strength for 12 s.
S.ITEM_EFFECTS[32485] = function(p)
  local buff = p:NewTemporaryStatsAura("Ashtongue Talisman of Valor - Proc", { [ST.Strength] = 55 }, 12)
  p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Valor - Trigger", procChance = 0.25,
    classMask = M.Bloodthirst + M.MortalStrike + M.ShieldSlam, outcome = O.Landed, callback = "hit",
    handler = function(sim) buff:Activate(sim) end })
end

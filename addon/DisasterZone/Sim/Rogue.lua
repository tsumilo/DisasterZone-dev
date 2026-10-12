if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Rogue.lua", ...) then return end -- DisasterZone: Sim/Rogue.lua
-- ns.GearSim Rogues (WoWSims sim/rogue): energy and combo points, poisons, the builders and finishers, Assassination,
-- Combat and Subtlety talents (the ones WoWSims implements), tier sets and rogue items. Built in WoWSims' order:
-- SetupRogue (constructor, poisons' proc triggers) before racials, RogueApplyTalents after item effects,
-- RogueInitialize (the class spells) after consumables.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (proto/rogue.proto field order; trees of 21, 24, 22)
-- ---------------------------------------------------------------------------------------------------------------
local TALENTS = {
  { "ImprovedEviscerate", "RemorselessAttacks", "Malice", "Ruthlessness", "Murder", "PuncturingWounds",
    "RelentlessStrikes", "ImprovedExposeArmor", "Lethality", "VilePoisons", "ImprovedPoisons", "FleetFooted",
    "ColdBlood", "ImprovedKidneyShot", "QuickRecovery", "SealFate", "MasterPoisoner", "Vigor", "DeadenedNerves",
    "FindWeakness", "Mutilate" },
  { "ImprovedGouge", "ImprovedSinisterStrike", "LightningReflexes", "ImprovedSliceAndDice", "Deflection",
    "Precision", "Endurance", "Riposte", "ImprovedSprint", "ImprovedKick", "DaggerSpecialization",
    "DualWieldSpecialization", "MaceSpecialization", "BladeFlurry", "SwordSpecialization",
    "FistWeaponSpecialization", "BladeTwisting", "WeaponExpertise", "Aggression", "Vitality", "AdrenalineRush",
    "NervesOfSteel", "CombatPotency", "SurpriseAttacks" },
  { "MasterOfDeception", "Opportunity", "SleightOfHand", "DirtyTricks", "Camouflage", "Initiative", "GhostlyStrike",
    "ImprovedAmbush", "Setup", "Elusiveness", "SerratedBlades", "HeightenedSenses", "Preparation", "DirtyDeeds",
    "Hemorrhage", "MasterOfSubtlety", "Deadliness", "EnvelopingShadows", "Premeditation", "CheatDeath",
    "SinisterCalling", "Shadowstep" },
}
S.ROGUE_TALENTS = TALENTS

-- ---------------------------------------------------------------------------------------------------------------
-- Class spell masks (rogue.go)
-- ---------------------------------------------------------------------------------------------------------------
local M
do
  local nextBit
  M, nextBit = S.SpellMasks({
    "Ambush", "Backstab", "Envenom", "Eviscerate", "ExposeArmor", "Feint", "Garrote", "Gouge", "Rupture",
    "Shiv", "SinisterStrike", "SliceAndDice", "Stealth", "Vanish", "Hemorrhage", "Premeditation", "Preparation",
    "Shadowstep", "AdrenalineRush", "BladeFlurry", "ColdBlood", "Mutilate", "MutilateHit", "GhostlyStrike",
    "InstantPoison", "WoundPoison", "DeadlyPoison" })
  M.All = nextBit * 2 - 1 - 1 -- RogueSpellLast<<1 - 1, without bit 0
  M.Actives = M.GhostlyStrike * 2 - 1 - 1
  M.Poisons = M.WoundPoison + M.DeadlyPoison + M.InstantPoison
  M.Lethality = M.SinisterStrike + M.Gouge + M.Backstab + M.GhostlyStrike + M.MutilateHit + M.Shiv + M.Hemorrhage
  M.DirectFinisher = M.Envenom + M.Eviscerate
  M.Finisher = M.DirectFinisher + M.SliceAndDice + M.Rupture + M.ExposeArmor
end
S.ROGUE_MASK = M

local BUILDER, FINISHER = F.Agent2, F.Agent3
local INSTANT_IMBUE, WOUND_IMBUE, DEADLY_IMBUE = 26891, 27188, 27186
local WT_DAGGER, WT_FIST, WT_MACE, WT_SWORD = 2, 3, 4, 9

local function HasWeaponType(w, wt) return w and w.weaponType == wt end

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (rogue.go NewRogue): energy, poisons' triggers, stat dependencies
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupRogue(p, talentsStr, opts, consumables)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local rogue = { talents = T, sliceAndDiceBonusFlat = 0.3, sliceAndDiceBonusDuration = 0, deathmantleBonus = 0,
    additiveEnergyRegenBonus = 0, lastFinisherPointSpend = 0, mhImbue = consumables and consumables.mhImbueId or 0,
    ohImbue = consumables and consumables.ohImbueId or 0 }
  p.rogue = rogue
  p.ps.CanParry = true
  local maxEnergy = 100
  if T.Vigor > 0 then maxEnergy = maxEnergy + 10 end
  if (p.setCounts["Gladiator's Vestments"] or 0) >= 4 then maxEnergy = maxEnergy + 10 end
  p:EnableEnergyBar({ maxEnergy = maxEnergy, maxComboPoints = 5 })
  S.RogueApplyPoisons(p)
  p:AddStatDependency(ST.Strength, ST.AttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.AttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Rogue)
  p:AddStatDependency(ST.Agility, ST.DodgeRating, 1 / 20 * S.DODGE_RATING_PER_PCT)
  return rogue
end

-- rogue.go ApplyFinisher: combo points spent, then Relentless Strikes and Ruthlessness.
local function ApplyFinisher(p, sim, spell)
  local rogue, T = p.rogue, p.talents
  local n = p.comboPoints
  rogue.lastFinisherPointSpend = n
  p:SpendComboPoints(sim)
  if T.RelentlessStrikes > 0 and sim:Proc(0.2 * n) then p:AddEnergy(sim, 25, "relentless_strikes") end
  if T.Ruthlessness > 0 and sim:Proc(0.2 * T.Ruthlessness) then p:AddComboPoints(sim, 1, "ruthlessness") end
end
S.RogueApplyFinisher = ApplyFinisher

-- ---------------------------------------------------------------------------------------------------------------
-- Poisons (poisons.go): the imbue's hand(s) proc a fixed chance per landed hit
-- ---------------------------------------------------------------------------------------------------------------
local function PoisonMask(rogue, imbue)
  local m = 0
  if rogue.mhImbue == imbue then m = m + PM.MeleeMH end
  if rogue.ohImbue == imbue then m = m + PM.MeleeOH end
  return m
end

function S.RogueApplyPoisons(p)
  local rogue, T = p.rogue, p.talents
  local function trigger(name, imbue, base, field)
    local mask = PoisonMask(rogue, imbue)
    if mask == 0 then return end
    p:MakeProcTriggerAura({ name = name, outcome = O.Landed, callback = "hit", triggerImmediately = true,
      procMask = mask, isWeaponProc = true, dpm = S.NewPPM(p, 0, mask, base + 0.02 * T.ImprovedPoisons),
      handler = function(sim, _, result) rogue[field]:Cast(sim, result.target) end })
  end
  trigger("Deadly Poison", DEADLY_IMBUE, 0.3, "deadlyPoison")
  trigger("Wound Poison", WOUND_IMBUE, 0.3, "woundPoison")
  trigger("Instant Poison", INSTANT_IMBUE, 0.2, "instantPoison")
end

local function RegisterPoisonSpells(p)
  local rogue = p.rogue
  local poisonFlags = F.Poison + F.PassiveSpell + F.Proc
  if PoisonMask(rogue, DEADLY_IMBUE) ~= 0 then
    local function stack(sim, target)
      local dot = rogue.deadlyPoison:Dot(target)
      if dot:IsActive() then
        dot.aura:Refresh(sim)
        dot.aura:AddStack(sim)
        dot:TakeSnapshot(sim)
      else
        dot:Apply(sim)
        dot.aura:SetStacks(sim, 1)
        dot:TakeSnapshot(sim)
      end
    end
    rogue.deadlyPoison = p:RegisterSpell({ id = 27187, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
      procMask = PM.SpellDamageProc, classMask = M.DeadlyPoison, flags = poisonFlags,
      damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
      dot = { label = "Deadly Poison", maxStacks = 5, numberOfTicks = 4, tickLength = 3,
        onSnapshot = function(sim, target, dot) dot:Snapshot(target, 45 * dot.aura.stacks) end,
        onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHit)
        if S.Landed(r) then stack(sim, target) end
      end })
    rogue.shivDeadlyPoison = p:RegisterSpell({ id = 27187, tag = 1, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
      procMask = PM.SpellDamageProc, classMask = M.DeadlyPoison, flags = poisonFlags,
      damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHit)
        if S.Landed(r) then stack(sim, target) end
      end })
  end
  if PoisonMask(rogue, WOUND_IMBUE) ~= 0 then
    local function wound(tag)
      return p:RegisterSpell({ id = 27189, tag = tag, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
        procMask = PM.SpellDamageProc, classMask = M.WoundPoison, flags = poisonFlags,
        damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
        applyEffects = function(sim, target, spell)
          local r = spell:CalcAndDealDamage(sim, target, 65, OUT.MagicHitAndCrit)
          if S.Landed(r) then
            local a = target:GetOrRegisterAura({ label = "Wound Poison", actionId = { spellId = 27189 }, duration = 15,
              maxStacks = 5 })
            a:Activate(sim)
          end
        end })
    end
    rogue.woundPoison = wound(0)
    rogue.shivWoundPoison = wound(1)
  end
  if PoisonMask(rogue, INSTANT_IMBUE) ~= 0 then
    local function instant(tag)
      return p:RegisterSpell({ id = 26890, tag = tag, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
        procMask = PM.SpellDamageProc, classMask = M.InstantPoison, flags = poisonFlags,
        damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
        applyEffects = function(sim, target, spell)
          spell:CalcAndDealDamage(sim, target, 146 + sim:Rand() * 48, OUT.MagicHitAndCrit)
        end })
    end
    rogue.instantPoison = instant(0)
    rogue.shivInstantPoison = instant(1)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents_assassination.go, talents_combat.go, talents_subtlety.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.RogueApplyTalents(p)
  local rogue, T = p.rogue, p.talents
  local aa = p.autoAttacks

  -- Assassination
  if T.ImprovedEviscerate > 0 then
    p:AddStaticMod({ classMask = M.Eviscerate, kind = "DamageDone_Flat", value = 0.05 * T.ImprovedEviscerate })
  end
  if T.Malice > 0 then p:AddStat(ST.PhysicalCritPercent, T.Malice) end
  if T.Murder > 0 then
    local m = 1 + 0.01 * T.Murder
    p.postFinalize[#p.postFinalize + 1] = function()
      for _, at in pairs(p.attackTables) do
        local mt = at.defender.mobType
        if at.defender.kind == "enemy" and (mt == "Humanoid" or mt == "Giant" or mt == "Beast" or mt == "Dragonkin") then
          at.damageDealtMultiplier = at.damageDealtMultiplier * m
          at.critMultiplier = at.critMultiplier * m
        end
      end
    end
  end
  if T.PuncturingWounds > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", classMask = M.Backstab, value = 10 * T.PuncturingWounds })
    p:AddStaticMod({ kind = "BonusCrit_Percent", classMask = M.MutilateHit, value = 5 * T.PuncturingWounds })
  end
  if T.ImprovedExposeArmor > 0 then
    -- the bonus lives in the Expose Armor debuff; this aura is for the rotation ("Imp EA Talented")
    S.MakePermanent(p:RegisterAura({ label = "Improved Expose Armor", actionId = { spellId = 14168 } }))
  end
  if T.Lethality > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Flat", classMask = M.Lethality, value = 0.06 * T.Lethality })
  end
  if T.VilePoisons > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.Poisons, value = 0.04 * T.VilePoisons })
  end
  if T.ColdBlood > 0 then
    local a = p:RegisterAura({ label = "Cold Blood", actionId = { spellId = 14177 } })
    a.onSpellHitDealt = function(aura, sim, spell) if spell:Matches(M.Actives) then aura:Deactivate(sim) end end
    a:AttachSpellMod({ kind = "BonusCrit_Percent", classMask = M.Actives, value = 100 })
    rogue.coldBlood = p:RegisterSpell({ id = 14177, cd = 180, applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = rogue.coldBlood })
  end
  if T.SealFate > 0 then
    p:MakeProcTriggerAura({ name = "Seal Fate Trigger", actionId = { spellId = 14195 }, procChance = 0.2 * T.SealFate,
      callback = "hit", outcome = O.Crit, spellFlags = BUILDER, icd = 0.5,
      handler = function(sim) p:AddComboPoints(sim, 1, "seal_fate") end })
  end
  if T.MasterPoisoner > 0 then
    p:AddStaticMod({ kind = "BonusHit_Percent", classMask = M.Poisons, value = 5 * T.MasterPoisoner })
  end
  if T.FindWeakness > 0 then
    local a = p:RegisterAura({ label = "Find Weakness", actionId = { spellId = 31242 }, duration = 10 })
    a:AttachSpellMod({ kind = "DamageDone_Flat", classMask = M.All, value = 0.02 * T.FindWeakness })
    p:MakeProcTriggerAura({ name = "Find Weakness Trigger", procChance = 1, callback = "hit", outcome = O.Landed,
      classMask = M.Finisher, handler = function(sim) a:Activate(sim) end })
    p:MakeProcTriggerAura({ name = "Find Weakness SnD Trigger", procChance = 1, callback = "cast",
      classMask = M.SliceAndDice, handler = function(sim) a:Activate(sim) end })
  end
  if T.Mutilate > 0 then S.RogueRegisterMutilate(p) end

  -- Combat
  if T.ImprovedGouge > 0 then
    p:AddStaticMod({ kind = "Cooldown_Flat", classMask = M.Gouge, value = 0.5 * T.ImprovedGouge })
  end
  if T.ImprovedSinisterStrike > 0 then
    p:AddStaticMod({ kind = "PowerCost_Flat", classMask = M.SinisterStrike, value = ({ 0, -3, -5 })[T.ImprovedSinisterStrike + 1] })
  end
  if T.LightningReflexes > 0 then p:AddStat(ST.DodgeRating, T.LightningReflexes * S.DODGE_RATING_PER_PCT) end
  if T.Precision > 0 then p:AddStat(ST.PhysicalHitPercent, T.Precision) end
  local function handMods(kind, value, wt)
    if HasWeaponType(aa.mh, wt) then p:AddStaticMod({ kind = kind, procMask = PM.MeleeMH, value = value }) end
    if aa.isDualWielding and HasWeaponType(aa.oh, wt) then p:AddStaticMod({ kind = kind, procMask = PM.MeleeOH, value = value }) end
  end
  if T.DaggerSpecialization > 0 then handMods("BonusCrit_Percent", T.DaggerSpecialization, WT_DAGGER) end
  if T.DualWieldSpecialization > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", procMask = PM.MeleeOH, value = 0.1 * T.DualWieldSpecialization })
  end
  if T.MaceSpecialization > 0 then handMods("CritMultiplier_Pct", 0.01 * T.MaceSpecialization, WT_MACE) end
  if T.BladeFlurry > 0 then
    local a = p:RegisterAura({ label = "Blade Flurry", actionId = { spellId = 13877 }, duration = 15 })
    a:AttachMultiplyAttackSpeed(1.2) -- one target: no extra hits
    local spell = p:RegisterSpell({ id = 13877, classMask = M.BladeFlurry, gcd = 1, cd = 120, ignoreHaste = true,
      energyCost = { cost = 25 }, relatedSelfBuff = a, applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.SwordSpecialization > 0 then
    local dpm = S.NewPPM(p, 0, S.ProcMaskForTypes(p, WT_SWORD), 0.01 * T.SwordSpecialization)
    local swordSpell
    p:MakeProcTriggerAura({ name = "Sword Spec Proc Trigger", actionId = { spellId = 13964 }, callback = "hit",
      outcome = O.Landed, icd = 0.5, triggerImmediately = true, dpm = dpm,
      handler = function(sim, _, result)
        if not swordSpell then swordSpell = S.WarriorExtraSwing(p, 12281) end
        S.MaybeReplaceMHSwing(p, sim, swordSpell):Cast(sim, result.target)
      end })
  end
  if T.FistWeaponSpecialization > 0 then handMods("BonusCrit_Percent", T.FistWeaponSpecialization, WT_FIST) end
  if T.WeaponExpertise > 0 then p:AddStat(ST.ExpertiseRating, S.EXPERTISE_PER_QUARTER * 5 * T.WeaponExpertise) end
  if T.Aggression > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.SinisterStrike + M.Backstab + M.Eviscerate,
      value = 0.02 * T.Aggression })
  end
  if T.Vitality > 0 then
    p:MultiplyStat(ST.Agility, 1 + 0.01 * T.Vitality)
    p:MultiplyStat(ST.Stamina, 1 + 0.02 * T.Vitality)
  end
  if T.AdrenalineRush > 0 then
    local a = p:RegisterAura({ label = "Adrenaline Rush", actionId = { spellId = 13750 }, duration = 15,
      onGain = function(_, sim) p:MultiplyEnergyRegenSpeed(sim, 2) end,
      onExpire = function(_, sim) p:MultiplyEnergyRegenSpeed(sim, 0.5) end })
    local spell = p:RegisterSpell({ id = 13750, flags = F.APL, classMask = M.AdrenalineRush, gcd = 1, cd = 300,
      ignoreHaste = true, applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.CombatPotency > 0 then
    p:MakeProcTriggerAura({ name = "Combat Potency Trigger", actionId = { spellId = 35553 }, procChance = 0.2,
      callback = "hit", outcome = O.Landed, procMask = PM.MeleeOH, triggerImmediately = true,
      handler = function(sim) p:AddEnergy(sim, 3 * T.CombatPotency, "combat_potency") end })
  end
  if T.SurpriseAttacks > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.SinisterStrike + M.Backstab + M.Shiv + M.Gouge, value = 0.1 })
    local mask = M.Eviscerate + M.Envenom + M.Rupture + M.ExposeArmor
    p:AddStaticMod({ kind = "Custom", classMask = mask,
      apply = function(_, sp) if not has(sp.flags, F.CannotBeDodged) then sp.flags = sp.flags + F.CannotBeDodged end end,
      remove = function(_, sp) if has(sp.flags, F.CannotBeDodged) then sp.flags = sp.flags - F.CannotBeDodged end end })
  end

  -- Subtlety
  if T.Opportunity > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.Backstab + M.Mutilate + M.Ambush, value = 0.04 * T.Opportunity })
  end
  if T.GhostlyStrike > 0 then
    p:RegisterSpell({ id = 14278, classMask = M.GhostlyStrike, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      flags = F.APL + F.MeleeMetrics, procMask = PM.MeleeMHSpecial, gcd = 1, cd = 20, ignoreHaste = true,
      energyCost = { cost = 40, refund = 0.8 }, damageMultiplier = 1.25, threatMultiplier = 1, bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealDamage(sim, target, S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target)),
          OUT.MeleeSpecialHitAndCrit)
        if S.Landed(r) then p:AddComboPoints(sim, 1, "ghostly_strike") end
      end })
  end
  if T.ImprovedAmbush > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", classMask = M.Ambush, value = 15 * T.ImprovedAmbush })
  end
  if T.SerratedBlades > 0 then
    p:AddStat(ST.ArmorPenetration, 186 * T.SerratedBlades)
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.Rupture, value = 0.1 * T.SerratedBlades })
  end
  if T.Preparation > 0 then
    local spell = p:RegisterSpell({ id = 14185, classMask = M.Preparation, gcd = 1, cd = 600, ignoreHaste = true,
      applyEffects = function()
        for _, name in ipairs({ "coldBlood", "shadowstep" }) do
          local sp = rogue[name]
          if sp and sp.cdTimer then sp.cdTimer.readyAt = 0 end
        end
      end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.DirtyDeeds > 0 then
    local a = p:RegisterAura({ label = "Dirty Deeds", actionId = { spellId = 14083 } })
    a:AttachSpellMod({ kind = "DamageDone_Flat", classMask = M.All, value = 0.1 * T.DirtyDeeds })
    p:RegisterResetEffect(function(sim)
      sim.executeCallbacks[#sim.executeCallbacks + 1] = function(s, phase) if phase == 35 then a:Activate(s) end end
    end)
  end
  if T.Hemorrhage > 0 then
    p:RegisterSpell({ id = 26864, classMask = M.Hemorrhage, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      flags = F.APL + F.MeleeMetrics + BUILDER, procMask = PM.MeleeMHSpecial, gcd = 1, ignoreHaste = true,
      energyCost = { cost = 35, refund = 0.8 }, damageMultiplier = 1.1, threatMultiplier = 1, bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealDamage(sim, target, S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target)),
          OUT.MeleeSpecialHitAndCrit)
        if S.Landed(r) then p:AddComboPoints(sim, 1, "hemorrhage") end
      end })
  end
  if T.Deadliness > 0 then p:MultiplyStat(ST.AttackPower, 1 + 0.02 * T.Deadliness) end
  if T.SinisterCalling > 0 then
    p:MultiplyStat(ST.Agility, 1 + 0.03 * T.SinisterCalling)
    p:AddStaticMod({ kind = "DamageDone_Flat", classMask = M.Hemorrhage + M.Backstab, value = 0.01 * T.SinisterCalling })
  end
  if T.Shadowstep > 0 then
    local a = p:RegisterAura({ label = "Shadowstep", actionId = { spellId = 36554 }, duration = 10 })
    a.onSpellHitDealt = function(aura, sim, spell) if has(M.Actives, spell.classMask) and spell.classMask ~= 0 then aura:Deactivate(sim) end end
    a:AttachSpellMod({ kind = "DamageDone_Flat", classMask = M.Actives, value = 0.2 })
    rogue.shadowstep = p:RegisterSpell({ id = 36554, flags = F.APL, classMask = M.Shadowstep, cd = 30,
      ignoreHaste = true, energyCost = { cost = 10 }, relatedSelfBuff = a,
      applyEffects = function(sim) a:Activate(sim) end })
  end
end

-- talents_assassination.go registerMutilate: two weapon hits, +50% while the target is poisoned.
function S.RogueRegisterMutilate(p)
  local rogue = p.rogue
  local aa = p.autoAttacks
  local function daggers()
    return HasWeaponType(aa.mh, WT_DAGGER) and aa.isDualWielding and HasWeaponType(aa.oh, WT_DAGGER)
  end
  local function hit(isMH)
    return p:RegisterSpell({ id = 34413, tag = isMH and 1 or 2, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      procMask = isMH and PM.MeleeMHSpecial or PM.MeleeOHSpecial, flags = F.MeleeMetrics + BUILDER,
      classMask = M.MutilateHit, damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
      bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        -- OHNormalizedWeaponDamage carries the off-hand's 50%
        local base = 101 + (isMH and 1 or 0.5) * S.WeaponNormalizedDamage(isMH and aa.mh or aa.oh, sim, spell:MeleeAttackPower(target))
        local old = spell.damageMultiplier
        local dp = rogue.deadlyPoison and rogue.deadlyPoison:Dot(target):IsActive()
        local wp = target:GetAura("Wound Poison")
        if dp or (wp and wp.active) then spell.damageMultiplier = spell.damageMultiplier + 0.5 end
        spell:CalcAndDealDamage(sim, target, base, OUT.MeleeSpecialBlockAndCrit)
        spell.damageMultiplier = old
      end })
  end
  local mh, oh = hit(true), hit(false)
  p:RegisterSpell({ id = 34413, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + F.APL, classMask = M.Mutilate, energyCost = { cost = 60, refund = 0.8 }, gcd = 1,
    ignoreHaste = true, threatMultiplier = 1,
    extraCastCondition = function() return daggers() end,
    applyEffects = function(sim, target, spell)
      local r = spell:CalcOutcome(sim, target, OUT.MeleeSpecialHit)
      if S.Landed(r) then
        p:AddComboPoints(sim, 2, "mutilate")
        oh:Cast(sim, target)
        mh:Cast(sim, target)
      else
        spell:IssueRefund(sim)
      end
      spell:DealDamage(sim, r)
    end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Class spells (rogue.go Initialize)
-- ---------------------------------------------------------------------------------------------------------------
function S.RogueInitialize(p)
  local rogue, T = p.rogue, p.talents
  local aa = p.autoAttacks
  local quickRecovery = 0.4 * T.QuickRecovery

  -- Backstab
  p:RegisterSpell({ id = 26863, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + BUILDER + F.APL, classMask = M.Backstab, energyCost = { cost = 60, refund = 0.8 },
    gcd = 1, ignoreHaste = true, damageMultiplierAdditive = 1.5, damageMultiplier = 1, threatMultiplier = 1,
    bonusCoefficient = 1,
    extraCastCondition = function() return not p.ps.InFrontOfTarget and HasWeaponType(aa.mh, WT_DAGGER) end,
    applyEffects = function(sim, target, spell)
      local base = 170 + S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if S.Landed(r) then p:AddComboPoints(sim, 1, "backstab") else spell:IssueRefund(sim) end
    end })

  -- Eviscerate
  local evisBonus = 185 + rogue.deathmantleBonus
  p:RegisterSpell({ id = 26865, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + FINISHER + F.APL, classMask = M.Eviscerate,
    energyCost = { cost = 35, refund = quickRecovery }, gcd = 1, ignoreHaste = true,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    extraCastCondition = function() return p.comboPoints > 0 end,
    applyEffects = function(sim, target, spell)
      local cp = p.comboPoints
      local flat = 60 + evisBonus * cp
      local base = sim:Roll(flat, flat + 120) + 0.03 * cp * spell:MeleeAttackPower(target)
      local r = spell:CalcDamage(sim, target, base, OUT.MeleeSpecialHitAndCrit)
      if S.Landed(r) then ApplyFinisher(p, sim, spell) else spell:IssueRefund(sim) end
      spell:DealDamage(sim, r)
    end })

  -- Expose Armor
  local eaMult = 1 + 0.25 * T.ImprovedExposeArmor
  local function eaAura(target) return S.ExposeArmorAura(target, function() return p.comboPoints end, T.ImprovedExposeArmor) end
  if p.currentTarget then eaAura(p.currentTarget) end -- the rotation reads it on the target
  p:RegisterSpell({ id = 26866, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + F.APL, classMask = M.ExposeArmor, energyCost = { cost = 25, refund = quickRecovery },
    gcd = 1, ignoreHaste = true, threatMultiplier = 1,
    extraCastCondition = function() return p.comboPoints > 0 end,
    applyEffects = function(sim, target, spell)
      local a = eaAura(target)
      local ee = a.exclusive and a.exclusive[1]
      if a.active and ee and ee.priority > 410 * p.comboPoints * eaMult then return end
      local r = spell:CalcOutcome(sim, target, OUT.MeleeSpecialHit)
      if S.Landed(r) then
        a:Activate(sim)
        ApplyFinisher(p, sim, spell)
      else
        spell:IssueRefund(sim)
      end
      spell:DealDamage(sim, r)
    end })

  RegisterPoisonSpells(p)

  -- Rupture
  local rupture
  rupture = p:RegisterSpell({ id = 26867, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics + FINISHER + F.APL, classMask = M.Rupture,
    energyCost = { cost = 25, refund = quickRecovery }, gcd = 1, ignoreHaste = true, damageMultiplier = 1,
    threatMultiplier = 1,
    extraCastCondition = function() return p.comboPoints > 0 end,
    dot = { label = "Rupture", numberOfTicks = 0, tickLength = 2,
      onSnapshot = function(sim, target, dot)
        local cp = p.comboPoints
        local ap = ({ 0, 0.01, 0.02, 0.03, 0.03, 0.03 })[cp + 1] * rupture:MeleeAttackPower(target)
        dot:SnapshotPhysical(target, 70 + 11 * cp + ap)
      end,
      onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
    applyEffects = function(sim, target, spell)
      local r = spell:CalcOutcome(sim, target, OUT.MeleeSpecialHit)
      if S.Landed(r) then
        local dot = spell:Dot(target)
        dot.baseTickCount = 3 + p.comboPoints
        dot:Apply(sim)
        ApplyFinisher(p, sim, spell)
        spell:DealDamage(sim, r)
      else
        spell:DealDamage(sim, r)
        spell:IssueRefund(sim)
      end
    end })

  -- Sinister Strike
  p:RegisterSpell({ id = 26862, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    flags = F.MeleeMetrics + BUILDER + F.APL, classMask = M.SinisterStrike, energyCost = { cost = 45, refund = 0.8 },
    gcd = 1, ignoreHaste = true, damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
    bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = 98 + S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if S.Landed(r) then p:AddComboPoints(sim, 1, "sinister_strike") else spell:IssueRefund(sim) end
    end })

  -- Slice and Dice
  do
    local durations = { [0] = 0, 9, 12, 15, 18, 21 }
    local impSnD = 1 + 0.15 * T.ImprovedSliceAndDice
    local mod = 1
    local a = p:RegisterAura({ label = "Slice and Dice", actionId = { spellId = 6774 }, duration = 21,
      onGain = function(_, sim)
        mod = 1 + rogue.sliceAndDiceBonusFlat
        p:MultiplyMeleeSpeed(sim, mod)
      end,
      onExpire = function(_, sim) p:MultiplyMeleeSpeed(sim, 1 / mod) end })
    rogue.sliceAndDiceAura = a
    p:RegisterSpell({ id = 6774, flags = FINISHER + F.APL, classMask = M.SliceAndDice, energyCost = { cost = 25 },
      gcd = 1, ignoreHaste = true, relatedSelfBuff = a,
      extraCastCondition = function() return p.comboPoints > 0 end,
      applyEffects = function(sim)
        local cp = p.comboPoints
        ApplyFinisher(p, sim, nil)
        a:Deactivate(sim)
        a.duration = (durations[cp] + rogue.sliceAndDiceBonusDuration) * impSnD
        a:Activate(sim)
      end })
  end

  -- Shiv
  do
    local ohSpeed = aa.isDualWielding and aa.oh.swingSpeed or 0
    local extra = ohSpeed > 0 and math.modf(10 * ohSpeed) or 0
    local shivPoison = (rogue.ohImbue == DEADLY_IMBUE and rogue.shivDeadlyPoison)
      or (rogue.ohImbue == INSTANT_IMBUE and rogue.shivInstantPoison)
      or (rogue.ohImbue == WOUND_IMBUE and rogue.shivWoundPoison) or nil
    p:RegisterSpell({ id = 5938, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeOHSpecial,
      flags = F.CannotBeDodged + F.MeleeMetrics + BUILDER + F.APL, classMask = M.Shiv, energyCost = { cost = 20 + extra },
      gcd = 1, ignoreHaste = true, damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
      bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        -- OHNormalizedWeaponDamage carries the off-hand's 50%
        local base = 0.5 * S.WeaponNormalizedDamage(aa.isDualWielding and aa.oh or aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialNoParry)
        if S.Landed(r) then
          p:AddComboPoints(sim, 1, "shiv")
          if shivPoison then shivPoison:Cast(sim, target) end
        end
      end })
  end

  -- rogue.go Reset: cooldowns are used by the rotation, not auto-used; the additive regen bonus
  p:RegisterResetEffect(function(sim)
    if rogue.additiveEnergyRegenBonus ~= 0 then p:MultiplyEnergyRegenSpeed(sim, 1 + rogue.additiveEnergyRegenBonus) end
  end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Set bonuses and items (items.go)
-- ---------------------------------------------------------------------------------------------------------------
S.SetBonus("Assassination Armor", {
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.Eviscerate + M.Envenom, kind = "PowerCost_Flat", value = -10 }) end,
})
S.SetBonus("Netherblade", {
  [2] = function(p, a)
    local og, oe = a.onGain, a.onExpire
    a.onGain = function(aura, sim) if og then og(aura, sim) end p.rogue.sliceAndDiceBonusDuration = p.rogue.sliceAndDiceBonusDuration + 3 end
    a.onExpire = function(aura, sim) if oe then oe(aura, sim) end p.rogue.sliceAndDiceBonusDuration = p.rogue.sliceAndDiceBonusDuration - 3 end
  end,
  [4] = function(p, a)
    S.AttachProcTrigger(a, p, { name = "Netherblade Combo Point", procChance = 0.15, classMask = M.Finisher,
      callback = "apply", handler = function(sim) p:AddComboPoints(sim, 1, "netherblade") end })
  end,
})
S.SetBonus("Deathmantle", {
  [2] = function(p) p.rogue.deathmantleBonus = 40 end,
  [4] = function(p, a)
    local cdg = p:RegisterAura({ label = "Coup de Grace", actionId = { spellId = 37171 }, duration = 15 })
    cdg.onApplyEffects = function(aura, sim, target, spell) if spell:Matches(M.Finisher) then aura:Deactivate(sim) end end
    cdg:AttachSpellMod({ kind = "PowerCost_Pct_Add", classMask = M.Finisher, value = -1 })
    S.AttachProcTrigger(a, p, { name = "Deathmantle Proc Trigger", canProcFromProcs = true, procMask = PM.Melee,
      outcome = O.Landed, callback = "hit", dpm = S.NewPPM(p, 0.5, PM.Melee),
      handler = function(sim) cdg:Activate(sim) end })
  end,
})
S.SetBonus("Slayer's Armor", {
  [2] = function(p, a)
    local og, oe = a.onGain, a.onExpire
    a.onGain = function(aura, sim) if og then og(aura, sim) end p.rogue.sliceAndDiceBonusFlat = p.rogue.sliceAndDiceBonusFlat + 0.05 end
    a.onExpire = function(aura, sim) if oe then oe(aura, sim) end p.rogue.sliceAndDiceBonusFlat = p.rogue.sliceAndDiceBonusFlat - 0.05 end
  end,
  [4] = function(p, a)
    a:AttachSpellMod({ kind = "DamageDone_Flat", classMask = M.Backstab + M.SinisterStrike + M.Mutilate + M.Hemorrhage,
      value = 0.06 })
  end,
})

-- Warp-Spring Coil: 25% on landed specials (30 s cooldown), 1000 armor penetration for 15 s.
S.ITEM_EFFECTS[30450] = function(p)
  local buff = p:NewTemporaryStatsAura("Warp-Spring Coil", { [ST.ArmorPenetration] = 1000 }, 15)
  p:MakeProcTriggerAura({ name = "Perceived Weakness", procMask = PM.MeleeSpecial, canProcFromProcs = true, icd = 30,
    requireDamageDealt = true, outcome = O.Landed, callback = "hit", procChance = 0.25,
    handler = function(sim) buff:Activate(sim) end })
end

-- Ashtongue Talisman of Lethality: 20% per combo point spent, 145 crit rating for 10 s.
S.ITEM_EFFECTS[32492] = function(p)
  local buff = p:NewTemporaryStatsAura("Rogue Tier 6 Trinket", { [ST.MeleeCritRating] = 145 }, 10)
  p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Lethality", callback = "apply", classMask = M.Finisher,
    handler = function(sim)
      local chance = 0.2 * (p.rogue and p.rogue.lastFinisherPointSpend or 0)
      if chance == 1 or sim:Proc(chance) then buff:Activate(sim) end
    end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Scenario hooks (Setup.lua S.NewScenario calls them in WoWSims' build order)
-- ---------------------------------------------------------------------------------------------------------------
S.RegisterClass("Rogue", {
  setup = function(p, talents, opts, consumables) S.SetupRogue(p, talents, opts, consumables) end,
  applyTalents = function(p) S.RogueApplyTalents(p) end,
  initialize = function(p) S.RogueInitialize(p) end,
})

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Shaman.lua", ...) then return end -- DisasterZone: Sim/Shaman.lua
-- ns.GearSim Enhancement Shaman (sim/shaman/*.go, enhancement/enhancement.go): totems (twisted Windfury and Grace of
-- Air, Strength of Earth, Mana Spring, Wrath of Air), fire totems (Searing, Magma, Fire Nova), the Fire Elemental
-- (a guardian pet: Sim/Pet.lua), shocks, Stormstrike, Bloodlust, weapon imbues (Windfury, Flametongue,
-- Frostbrand), the off-hand swing delay that keeps Flurry charges, talents of all three trees that reach a melee
-- shaman, totems and tier sets.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

local F_SHAMAN, F_SHOCK, F_INSTANT, F_FOCUSABLE = F.Agent1, F.Agent2, F.Agent3, F.Agent4

-- proto ShamanTalents order (talents string = Wowhead's)
local TALENTS = {
  { "Convection", "Concussion", "EarthsGrasp", "ElementalWarding", "CallOfFlame", "ElementalFocus", "Reverberation",
    "CallOfThunder", "ImprovedFireTotems", "EyeOfTheStorm", "ElementalDevastation", "StormReach", "ElementalFury",
    "UnrelentingStorm", "ElementalPrecision", "LightningMastery", "ElementalMastery", "ElementalShields",
    "LightningOverload", "TotemOfWrath" },
  { "AncestralKnowledge", "ShieldSpecialization", "GuardianTotems", "ThunderingStrikes", "ImprovedGhostWolf",
    "ImprovedLightningShield", "EnhancingTotems", "ShamanisticFocus", "Anticipation", "Flurry", "Toughness",
    "ImprovedWeaponTotems", "SpiritWeapons", "ElementalWeapons", "MentalQuickness", "WeaponMastery",
    "DualWieldSpecialization", "DualWield", "Stormstrike", "UnleashedRage", "ShamanisticRage" },
  { "ImprovedHealingWave", "TidalFocus", "ImprovedReincarnation", "AncestralHealing", "TotemicFocus",
    "NaturesGuidance", "HealingFocus", "TotemicMastery", "HealingGrace", "RestorativeTotems", "TidalMastery",
    "HealingWay", "NaturesSwiftness", "FocusedMind", "Purification", "ManaTideTotem", "NaturesGuardian",
    "NaturesBlessing", "ImprovedChainHeal", "EarthShield" },
}
S.SHAMAN_TALENTS = TALENTS

-- Class spell masks (shaman.go)
local M = {}
do
  local names = { "FireElementalTotem", "EarthElementalTotem", "FireElementalMelee", "FlameShockDirect",
    "FlameShockDot", "LightningBolt", "LightningBoltOverload", "ChainLightning", "ChainLightningOverload",
    "EarthShock", "LightningShield", "MagmaTotem", "SearingTotem", "FireNovaTotem", "FlametongueTotem",
    "StormstrikeCast", "StormstrikeDamage", "EarthShield", "FrostShock", "FlametongueWeapon", "WindfuryWeapon",
    "FrostbrandWeapon", "RockbiterWeapon", "ElementalMastery", "ShamanisticRage", "Bloodlust", "BasicTotem",
    "ShieldSelfProc" }
  local bit = 2
  for _, n in ipairs(names) do M[n] = bit; bit = bit * 2 end
  M.Stormstrike = M.StormstrikeCast + M.StormstrikeDamage
  M.FlameShock = M.FlameShockDirect + M.FlameShockDot
  M.Fire = M.FlameShock
  M.Nature = M.LightningBolt + M.LightningBoltOverload + M.ChainLightning + M.ChainLightningOverload + M.EarthShock
  M.Frost = M.FrostShock
  M.Overload = M.LightningBoltOverload + M.ChainLightningOverload
  M.Shock = M.FlameShock + M.EarthShock + M.FrostShock
  M.FireTotem = M.MagmaTotem + M.SearingTotem + M.FireNovaTotem
  M.Totem = M.FireTotem + M.FireElementalTotem + M.EarthElementalTotem + M.BasicTotem
  M.Imbue = M.FrostbrandWeapon + M.WindfuryWeapon + M.FlametongueWeapon + M.RockbiterWeapon
end
S.SHAMAN_MASK = M

local IMBUE = { NoImbue = 0, WindfuryWeapon = 1, FlametongueWeapon = 2, FrostbrandWeapon = 3, RockbiterWeapon = 4 }

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (shaman.go NewShaman, enhancement.go NewEnhancementShaman)
-- opts: { imbueMh, imbueOh ("WindfuryWeapon" | "FlametongueWeapon" | "FrostbrandWeapon" | "NoImbue"),
--         syncType ("DelayOffhandSwings" | "SyncMainhandOffhandSwings" | "Auto" | "NoSync"), shieldProcrate }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupShaman(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local sh = { opts = opts, talents = T, windfuryAPBonus = 475,
    imbueMh = IMBUE[opts.imbueMh or "WindfuryWeapon"] or 1, imbueOh = IMBUE[opts.imbueOh or "WindfuryWeapon"] or 1 }
  p.shaman = sh
  p:AddStatDependency(ST.BonusArmor, ST.Armor, 1)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Shaman)
  p:AddStatDependency(ST.Agility, ST.DodgeRating, 1 / 25 * S.DODGE_RATING_PER_PCT)
  p:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  p:AddStat(ST.AttackPower, -20)
  p.ps.CanParry = true

  -- totem expirations (shaman.go TotemExpirations), read by the rotation (totemRemainingTime)
  p.totemExpirations = { Air = -36000, Earth = -36000, Fire = -36000, Water = -36000 }
  p:RegisterResetEffect(function()
    local e = p.totemExpirations
    e.Air, e.Earth, e.Fire, e.Water = -36000, -36000, -36000, -36000
    sh.airTotemAura, sh.earthTotemAura, sh.waterTotemAura = nil, nil, nil
    sh.searingReplaced = false
  end)

  local aa = p.autoAttacks
  local hasMH = aa.mh and aa.mh.swingSpeed and aa.mh.baseMax and aa.mh.baseMax > 0
  if not hasMH then sh.imbueMh = 0 end
  if not aa.isDualWielding then sh.imbueOh = 0 end
  if opts.elemental then
    -- elemental.go: no melee swings, no off-hand imbue
    sh.elemental = true
    aa.autoSwingMelee = false
    sh.imbueOh = 0
    return sh
  end

  -- enhancement.go ApplySyncType: keep the off hand from swinging right after the main hand (Flurry charges)
  local FLURRY_ICD = 0.5
  local sync = opts.syncType or "DelayOffhandSwings"
  local function delayOH(sim, swing)
    if aa.oh.swingAt - sim.now > FLURRY_ICD then
      local nextMH = sim.now + aa.mh.curSwingDuration + 0.1
      if nextMH > aa.oh.swingAt then
        aa.oh.swingAt = nextMH
        sim:RescheduleWeaponAttack(aa.oh.swingAt)
      end
    end
    return swing
  end
  local function syncOH(sim, swing)
    if aa.oh.swingAt - sim.now > FLURRY_ICD then
      local nextMH = sim.now + aa.mh.curSwingDuration
      if nextMH ~= aa.oh.swingAt then
        aa.oh.swingAt = nextMH
        sim:RescheduleWeaponAttack(aa.oh.swingAt)
      end
    end
    return swing
  end
  if aa.isDualWielding then
    if sync == "DelayOffhandSwings" then
      aa.mh.replaceSwing = delayOH
    elseif sync == "SyncMainhandOffhandSwings" then
      aa.mh.replaceSwing = syncOH
    elseif sync == "Auto" then
      aa.mh.replaceSwing = function(sim, swing)
        if aa.mh.swingSpeed ~= aa.oh.swingSpeed then return swing end
        return delayOH(sim, swing)
      end
    end
  end
  return sh
end

-- An attack with a weapon's damage (MH or OH at half damage, attack.go MHWeaponDamage / OHWeaponDamage)
local function WeaponDamageFn(p, isMH)
  local aa = p.autoAttacks
  if isMH then return function(sim, ap) return S.WeaponDamage(aa.mh, sim, ap) end end
  return function(sim, ap) return 0.5 * S.WeaponDamage(aa.oh, sim, ap) end
end

-- Attach a periodic action to an aura: starts when the aura is gained, stops when it ends (aura.AttachPeriodicAction).
local function AttachPeriodic(aura, o)
  local og, oe = aura.onGain, aura.onExpire
  local pa
  aura.onGain = function(a, sim)
    if og then og(a, sim) end
    pa = S.StartPeriodicAction(sim, o)
  end
  aura.onExpire = function(a, sim)
    if oe then oe(a, sim) end
    if pa and not pa.consumed and not pa.cancelled then sim:Cancel(pa) end
    pa = nil
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents_elemental.go, talents_enhancement.go, talent_restoration.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanApplyTalents(p)
  local sh, T = p.shaman, p.talents
  local aa = p.autoAttacks

  -- Elemental
  if T.CallOfFlame > 0 then
    p:AddStaticMod({ classMask = M.FireTotem, kind = "DamageDone_Flat", value = 0.05 * T.CallOfFlame })
  end
  if T.CallOfThunder > 0 then
    p:AddStaticMod({ classMask = M.LightningBolt + M.ChainLightning + M.Overload, kind = "BonusCrit_Percent",
      value = T.CallOfThunder })
  end
  if T.Concussion > 0 then
    p:AddStaticMod({ classMask = M.LightningBolt + M.ChainLightning + M.Overload + M.Shock, kind = "DamageDone_Flat",
      value = 0.01 * T.Concussion })
  end
  if T.Convection > 0 then
    p:AddStaticMod({ classMask = M.LightningBolt + M.ChainLightning + M.Overload + M.Shock, kind = "PowerCost_Pct_Add",
      value = -0.02 * T.Convection })
  end
  if T.ElementalDevastation > 0 then
    local a = p:RegisterAura({ label = "Elemental Devastation", actionId = { spellId = 29178 }, duration = 10 })
    a:AttachSpellMod({ kind = "BonusCrit_Percent", value = 3 * T.ElementalDevastation, procMask = PM.Melee })
    p:MakeProcTriggerAura({ name = "Elemental Devastation Trigger", canProcFromProcs = true, callback = "hit",
      procMask = PM.SpellDamage, outcome = O.Crit, handler = function(sim) a:Activate(sim) end })
  end
  if T.ElementalFocus > 0 then
    local consume = M.LightningBolt + M.ChainLightning + M.FlameShockDirect + M.EarthShock + M.FrostShock
    local trigSpell, trigAt
    local cc = p:RegisterAura({ label = "Clearcasting", actionId = { spellId = 16246 }, duration = 15, maxStacks = 2,
      onCastComplete = function(a, sim, spell)
        if not has(spell.classMask, consume) then return end
        if spell == trigSpell and sim.now == trigAt then return end
        a:RemoveStack(sim)
      end })
    cc:AttachSpellMod({ classMask = consume, kind = "PowerCost_Pct_Add", value = -0.4 })
    p:MakeProcTriggerAura({ name = "Elemental Focus", callback = "hit", canProcFromProcs = true, outcome = O.Crit,
      triggerImmediately = true,
      handler = function(sim, spell)
        if not has(spell.school or 0, SCHOOL.Fire + SCHOOL.Frost + SCHOOL.Nature) then return end
        trigSpell, trigAt = spell, sim.now
        cc:Activate(sim)
        cc:SetStacks(sim, 2)
      end })
  end
  if T.ElementalFury > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Flat", value = 1.0,
      classMask = M.FireTotem + M.Fire + M.Nature + M.Frost + M.FlametongueWeapon + M.FrostbrandWeapon })
  end
  if T.ElementalPrecision > 0 then
    local hit = 2 * T.ElementalPrecision
    for _, sc in ipairs({ SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Nature }) do
      local i = S.SCHOOL_INDEX[sc]
      p.ps.SchoolBonusHitChance[i] = p.ps.SchoolBonusHitChance[i] + hit
    end
  end
  if T.Reverberation > 0 then
    p:AddStaticMod({ classMask = M.Shock, kind = "Cooldown_Flat", value = -0.2 * T.Reverberation })
  end
  if T.UnrelentingStorm > 0 then p:AddStatDependency(ST.Intellect, ST.MP5, 0.02 * T.UnrelentingStorm) end
  if T.ElementalMastery > 0 then
    local masks = M.Fire + M.Frost + M.Nature
    local em = p:RegisterAura({ label = "Elemental Mastery", actionId = { spellId = 16166 },
      onCastComplete = function(a, sim, spell) if spell:Matches(masks) then a:Deactivate(sim) end end })
    em:AttachSpellMod({ kind = "BonusCrit_Percent", value = 100, classMask = masks })
    em:AttachSpellMod({ kind = "PowerCost_Pct_Add", value = -1, classMask = masks })
    local spell = p:RegisterSpell({ id = 16166, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
      flags = F.APL + F.NoOnCastComplete + F_INSTANT, cd = 180, applyEffects = function(sim) em:Activate(sim) end })
    p:AddMajorCooldown({ spell = spell })
  end
  if T.LightningMastery > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.1 * T.LightningMastery, classMask = M.LightningBolt + M.ChainLightning })
  end
  sh.overloadChance = 0.04 * T.LightningOverload
  if T.TotemOfWrath > 0 then
    -- the cost is 5% of WoWSims' "initial mana", which isn't set yet when the talent is applied: 0
    local a = p:RegisterAura({ label = "Totem Of Wrath (Self)", actionId = { spellId = 30706 }, duration = 120 })
    a:AttachStatsBuff({ [ST.SpellCritPercent] = 3, [ST.SpellHitPercent] = 3 })
    sh.totemOfWrath = p:RegisterSpell({ id = 30706, defenseType = S.DEF_MAGIC, flags = F.APL + F_INSTANT,
      classMask = M.BasicTotem, manaCost = { flat = 0 }, gcd = 1, relatedSelfBuff = a,
      applyEffects = function(sim)
        S.ShamanCancelFireTotems(p, sim)
        p.totemExpirations.Fire = sim.now + 120
        a:Activate(sim)
      end })
  end

  -- Enhancement
  if T.AncestralKnowledge > 0 then p:MultiplyStat(ST.Mana, 1 + 0.01 * T.AncestralKnowledge) end
  if T.DualWieldSpecialization > 0 and aa.isDualWielding then
    p:AddStat(ST.PhysicalHitPercent, 2 * T.DualWieldSpecialization)
  end
  if T.ElementalWeapons > 0 then
    p:AddStaticMod({ classMask = M.RockbiterWeapon, kind = "DamageDone_Flat", value = ({ 0, 0.07, 0.14, 0.2 })[T.ElementalWeapons + 1] })
    p:AddStaticMod({ classMask = M.WindfuryWeapon, kind = "DamageDone_Flat", value = ({ 0, 0.13, 0.27, 0.4 })[T.ElementalWeapons + 1] })
    p:AddStaticMod({ classMask = M.FlametongueWeapon + M.FrostbrandWeapon, kind = "DamageDone_Flat",
      value = 0.05 * T.ElementalWeapons })
  end
  if T.Flurry > 0 then
    local speed = 1.05 + 0.05 * T.Flurry + (p:CouldHaveSetBonus("Cataclysm Harness", 4) and 0.05 or 0)
    local icd = p:NewTimer()
    local fl = p:RegisterAura({ label = "Flurry", actionId = { spellId = 16284 }, duration = 15, maxStacks = 3 })
    fl:AttachMultiplyMeleeSpeed(speed)
    p:MakeProcTriggerAura({ name = "Flurry Trigger", callback = "hit", procMask = PM.Melee, canProcFromProcs = true,
      handler = function(sim, spell, result)
        if has(result.outcome, O.Crit) then
          fl:Activate(sim)
          fl:SetStacks(sim, 3)
          return
        end
        if fl.active and has(spell.procMask, PM.MeleeWhiteHit) and icd.readyAt <= sim.now then
          icd.readyAt = sim.now + 0.5
          fl:RemoveStack(sim)
        end
      end, triggerImmediately = true })
  end
  if T.ImprovedLightningShield > 0 then
    p:AddStaticMod({ classMask = M.LightningShield, kind = "DamageDone_Flat", value = 0.05 * T.ImprovedLightningShield })
  end
  if T.ImprovedWeaponTotems > 0 then
    p:AddStaticMod({ classMask = M.FlametongueTotem, kind = "DamageDone_Flat", value = 0.06 * T.ImprovedWeaponTotems })
  end
  if T.MentalQuickness > 0 then
    p:AddStaticMod({ spellFlag = F_INSTANT, kind = "PowerCost_Pct_Add", value = -0.02 * T.MentalQuickness })
    p:AddStatDependency(ST.AttackPower, ST.SpellDamage, 0.1 * T.MentalQuickness)
  end
  if T.ShamanisticFocus > 0 then
    local a = p:RegisterAura({ label = "Focused", actionId = { spellId = 43339 }, duration = 15 })
    a:AttachSpellMod({ classMask = M.Shock, kind = "PowerCost_Pct_Add", value = -0.6 })
    p:MakeProcTriggerAura({ name = "Shamanistic Focus Trigger", callback = "hit", procMask = PM.Melee,
      canProcFromProcs = true, outcome = O.Crit, handler = function(sim) a:Activate(sim) end })
    p:MakeProcTriggerAura({ name = "Shamanistic Focus Untrigger", callback = "cast", classMask = M.Shock,
      canProcFromProcs = true, handler = function(sim) a:Deactivate(sim) end, triggerImmediately = true })
  end
  if T.ShamanisticRage > 0 then
    local sr = p:MakeProcTriggerAura({ name = "Shamanistic Rage", duration = 15, actionId = { spellId = 30823 },
      callback = "hit", procMask = PM.MeleeWhiteHit, outcome = O.Landed, requireDamageDealt = true,
      dpm = S.NewPPM(p, 15, PM.MeleeWhiteHit),
      handler = function(sim, spell, result)
        p:AddMana(sim, 0.3 * spell:MeleeAttackPower(result.target), "shamanistic_rage")
      end })
    p:RegisterSpell({ id = 30823, school = SCHOOL.Physical, flags = F_INSTANT + F.APL, classMask = M.ShamanisticRage,
      gcd = 1.5, cd = 120, relatedSelfBuff = sr, applyEffects = function(sim) sr:Activate(sim) end })
  end
  if T.Stormstrike > 0 then S.ShamanStormstrike(p) end
  if T.ThunderingStrikes > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.ThunderingStrikes, procMask = PM.Melee })
  end
  if T.UnleashedRage > 0 then
    -- core UnleashedRageAura: attack power x(1 + 2% per point) for 10 s after a melee crit
    local dep = p:NewDynamicMultiplyStat(ST.AttackPower, 1 + 0.02 * T.UnleashedRage)
    local ur = p:RegisterAura({ label = "Unleashed Rage-1", actionId = { spellId = 30809, tag = 1 }, duration = 10,
      onGain = function(a, sim) p:EnableDynamicStatDep(sim, dep) end,
      onExpire = function(a, sim) p:DisableDynamicStatDep(sim, dep) end })
    p:MakeProcTriggerAura({ name = "Unleashed Rage Trigger", callback = "hit", procMask = PM.Melee,
      canProcFromProcs = true, outcome = O.Crit, requireDamageDealt = true,
      handler = function(sim) ur:Activate(sim) end })
  end
  if T.WeaponMastery > 0 then
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.02 * T.WeaponMastery, procMask = PM.Melee })
  end

  -- Restoration
  if T.NaturesGuidance > 0 then
    p:AddStat(ST.SpellHitPercent, T.NaturesGuidance)
    p:AddStat(ST.PhysicalHitPercent, T.NaturesGuidance)
  end
  if T.TidalMastery > 0 then
    p:AddStaticMod({ classMask = M.ChainLightning + M.LightningBolt + M.LightningShield + M.Overload,
      kind = "BonusCrit_Percent", value = T.TidalMastery })
  end
  if T.TotemicFocus > 0 then
    p:AddStaticMod({ classMask = M.Totem, kind = "PowerCost_Pct_Add", value = -0.05 * T.TotemicFocus })
  end

  S.ShamanItems(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stormstrike (stormstrike.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanStormstrike(p)
  local aa = p.autoAttacks
  local target = p.currentTarget
  local debuff = target:RegisterAura({ label = "Stormstrike-" .. p.label, actionId = { spellId = 17364 }, duration = 12,
    maxStacks = 2,
    onSpellHitTaken = function(a, sim, spell, result)
      if not has(spell.school or 0, SCHOOL.Nature) then return end
      if not S.Landed(result) or result.damage == 0 then return end
      a:RemoveStack(sim)
    end })
  debuff:AttachMultiplicativePseudoStatBuff("SchoolDamageTakenMultiplier", 1.2, S.SCHOOL_INDEX[SCHOOL.Nature])
  local function hit(isMH)
    local dmg = WeaponDamageFn(p, isMH)
    return p:RegisterSpell({ id = 17364, tag = isMH and 1 or 2, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      procMask = isMH and PM.MeleeMHSpecial or PM.MeleeOHSpecial, flags = F.MeleeMetrics,
      classMask = M.StormstrikeDamage, damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, t, spell)
        spell:CalcAndDealDamage(sim, t, dmg(sim, spell:MeleeAttackPower(t)), OUT.MeleeSpecialBlockAndCrit)
      end })
  end
  local mhHit, ohHit = hit(true), hit(false)
  p.shaman.stormstrike = p:RegisterSpell({ id = 17364, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    procMask = PM.Empty, flags = F.MeleeMetrics + F.APL, classMask = M.StormstrikeCast,
    manaCost = { basePct = 8 }, gcd = 1.5, ignoreHaste = true, cd = 10,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealOutcome(sim, t, OUT.MeleeSpecialHitNoHitCounter)
      if S.Landed(r) then
        debuff:Activate(sim)
        debuff:SetStacks(sim, 2)
        mhHit:Cast(sim, t)
        if aa.isDualWielding then ohHit:Cast(sim, t) end
      end
    end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Totems (totems.go)
-- ---------------------------------------------------------------------------------------------------------------
local function TotemSpell(p, id, cost, mask, applyEffects)
  return p:RegisterSpell({ id = id, defenseType = S.DEF_MAGIC, flags = F.APL + F_INSTANT, classMask = mask,
    manaCost = { flat = cost }, gcd = 1, applyEffects = applyEffects })
end

local function SwapTotem(p, sim, slot, field, aura, duration)
  local sh = p.shaman
  if sh[field] then sh[field]:Deactivate(sim) end
  p.totemExpirations[slot] = sim.now + duration
  sh[field] = aura
  aura:Activate(sim)
end

-- A totem's own buff (an exclusive effect: the strongest of a kind applies)
local function TotemStatAura(p, label, id, category, stat, value)
  local a = p:RegisterAura({ label = label, actionId = { spellId = id }, duration = 120 })
  a:NewExclusiveEffect(category, false, value,
    function(ee, sim) p:AddStatDynamic(sim, stat, value) end,
    function(ee, sim) p:AddStatDynamic(sim, stat, -value) end)
  return a
end

function S.ShamanTotems(p)
  local sh, T = p.shaman, p.talents

  -- Windfury Totem (self): a 20% chance on main-hand swings, unless a weapon imbue holds the Windfury slot
  local value = 445 * (1 + 0.15 * T.ImprovedWeaponTotems)
  local wfProc = p:NewTemporaryStatsAura("Windfury Totem Proc (Self)", { [ST.AttackPower] = value }, 1.5)
  wfProc.maxStacks = 2
  S.AttachProcTrigger(wfProc, p, { name = "Windfury Attack (Self)", callback = "hit",
    procMask = PM.MeleeMHAuto + PM.MeleeOHAuto,
    handler = function(sim, spell)
      if wfProc.active and not has(spell.procMask, PM.MeleeSpecial) then wfProc:RemoveStack(sim) end
    end, triggerImmediately = true })
  local wfSpell
  local wfTrigger = p:MakeProcTriggerAura({ name = "Windfury Totem Trigger (Self)", isWeaponProc = true,
    procChance = 0.2, outcome = O.Landed, callback = "hit", procMask = PM.MeleeMHAuto, icd = 1.5,
    triggerImmediately = true,
    handler = function(sim, spell, result)
      wfProc:Activate(sim)
      if spell.procMask == PM.MeleeMHAuto then wfProc:SetStacks(sim, 1) else wfProc:SetStacks(sim, 2) end
      if not wfSpell then
        local aa = p.autoAttacks
        wfSpell = p:RegisterSpell({ id = "melee_wft", tag = 25584, metricsKey = "windfury_totem", school = SCHOOL.Physical,
          defenseType = S.DEF_MELEE, procMask = PM.MeleeMHAuto,
          flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete,
          damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
          applyEffects = function(s, t, sp)
            sp:CalcAndDealDamage(s, t, S.WeaponDamage(aa.mh, s, sp:MeleeAttackPower(t)), OUT.MeleeWhite)
          end })
      end
      local sp = S.MaybeReplaceMHSwing and S.MaybeReplaceMHSwing(p, sim, wfSpell) or wfSpell
      sp:Cast(sim, result.target)
    end })
  -- (permanent proc triggers start active; this one follows the exclusive effect below)
  wfTrigger.onReset = nil
  local wfInter = p:RegisterAura({ label = "Windfury Dummy Aura (self)", duration = 10 })
  local wfTracking = p:RegisterAura({ label = "Windfury Party Weapon Buff Tracking Aura", duration = 10,
    actionId = { spellId = 25580, tag = 1 } })
  local wfAura = p:RegisterAura({ label = "Windfury Totem (Self)", actionId = { spellId = 25587 }, duration = 120 })
  AttachPeriodic(wfAura, { period = 5, tickImmediately = true, prio = S.PRIO_AUTO,
    onAction = function(sim)
      wfTracking:Activate(sim)
      wfInter:Activate(sim)
    end })
  wfInter:NewExclusiveEffect("WindfuryTotem", false, value,
    function(ee, sim) wfTrigger:Activate(sim) end,
    function(ee, sim)
      wfTrigger:Deactivate(sim)
      wfInter:Deactivate(sim)
    end)
  TotemSpell(p, 25587, 325, M.BasicTotem, function(sim) SwapTotem(p, sim, "Air", "airTotemAura", wfAura, 120) end)

  -- Strength of Earth, Grace of Air, Wrath of Air, Mana Spring
  local soe = floor((86 + (p:CouldHaveSetBonus("Cyclone Harness", 2) and 12 or 0)) * ({ 1, 1.08, 1.15 })[T.EnhancingTotems + 1])
  local soeAura = TotemStatAura(p, "Strength Of Earth Totem (Self)", 25528, "StrengthOfEarthTotemStrengthAdd", ST.Strength, soe)
  TotemSpell(p, 25528, 300, M.BasicTotem, function(sim) SwapTotem(p, sim, "Earth", "earthTotemAura", soeAura, 120) end)
  local goa = 77 * ({ 1, 1.08, 1.15 })[T.EnhancingTotems + 1]
  local goaAura = TotemStatAura(p, "Grace Of Air Totem (Self)", 25359, "GraceOfAirTotemAgilityAdd", ST.Agility, goa)
  TotemSpell(p, 25359, 310, M.BasicTotem, function(sim) SwapTotem(p, sim, "Air", "airTotemAura", goaAura, 120) end)
  local woa = 101 + (p:CouldHaveSetBonus("Cyclone Regalia", 2) and 20 or 0)
  local woaAura = p:RegisterAura({ label = "Wrath Of Air Totem (Self)", actionId = { spellId = 3738 }, duration = 120 })
  woaAura:NewExclusiveEffect("WrathOfAirTotemSpellDamageAdd", false, woa,
    function(ee, sim) p:AddStatsDynamic(sim, { [ST.SpellDamage] = woa, [ST.HealingPower] = woa }) end,
    function(ee, sim) p:AddStatsDynamic(sim, { [ST.SpellDamage] = -woa, [ST.HealingPower] = -woa }) end)
  TotemSpell(p, 3738, 320, M.BasicTotem, function(sim) SwapTotem(p, sim, "Air", "airTotemAura", woaAura, 120) end)
  local ms = 50 * (1 + 0.05 * T.RestorativeTotems)
  local msAura = TotemStatAura(p, "Mana Spring Totem (Self)", 25570, "ManaSpringTotemMP5Add", ST.MP5, ms)
  TotemSpell(p, 25570, 120, M.BasicTotem, function(sim) SwapTotem(p, sim, "Water", "waterTotemAura", msAura, 120) end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Fire totems (fire_totems.go) and the Fire Elemental (fire_elemental_*.go)
-- ---------------------------------------------------------------------------------------------------------------
local function CancelFireTotems(p, sim)
  local sh = p.shaman
  if sh.magma then sh.magma:AOEDot():Deactivate(sim) end
  if sh.fireNovaPA and not sh.fireNovaPA.consumed and not sh.fireNovaPA.cancelled then sim:Cancel(sh.fireNovaPA) end
  if sh.searing then
    local d = sh.searing:Dot(p.currentTarget)
    if d then d:Deactivate(sim) end
  end
  sh.searingReplaced = true
  if sh.totemOfWrath then sh.totemOfWrath.relatedSelfBuff:Deactivate(sim) end
  if sh.fireElementalTotem then sh.fireElementalTotem.relatedSelfBuff:Deactivate(sim) end
end
S.ShamanCancelFireTotems = CancelFireTotems

function S.ShamanFireTotems(p)
  local sh, T = p.shaman, p.talents
  -- Searing Totem: ticks at the target every 2.43 s for its 60 s
  local function ticks(offsetMin) return math.ceil(24 * (1 + offsetMin)) - 1 end
  sh.searing = p:RegisterSpell({ id = 25530, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.APL + F_SHAMAN + F_INSTANT, classMask = M.SearingTotem, manaCost = { flat = 205 }, gcd = 1,
    damageMultiplier = 1,
    dot = { label = "Searing Totem", numberOfTicks = ticks(0), tickLength = 2.43, bonusCoefficient = 0.16699999571,
      onTick = function(sim, target, dot)
        local sp = dot.spell
        local r = sp:CalcPeriodicDamage(sim, target, sim:Roll(50, 66), OUT.TickMagicHitAndCrit)
        local delay = p.distance / 19
        sim:Add({ at = sim.now + delay, prio = 0, fn = function(s) sp:DealPeriodicDamage(s, r) end })
      end },
    applyEffects = function(sim, _, spell)
      CancelFireTotems(p, sim)
      local d = spell:Dot(p.currentTarget)
      if sim.now < 0 then
        local dropAt = sim.now
        sh.searingReplaced = false
        sim:Add({ at = sim.now, prio = 0, fn = function(s)
          if sh.searingReplaced then return end
          d.baseTickCount = ticks(dropAt / 60)
          d:Apply(s)
        end })
      else
        d.baseTickCount = ticks(0)
        d:Apply(sim)
      end
      p.totemExpirations.Fire = sim.now + 60
    end })

  -- Magma Totem: 97 fire damage to everything near it every 2 s for 20 s
  sh.magma = p:RegisterSpell({ id = 25550, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.APL + F_SHAMAN + F_INSTANT, classMask = M.MagmaTotem, manaCost = { flat = 800 }, gcd = 1,
    damageMultiplier = 1,
    dot = { label = "Magma Totem", selfOnly = true, numberOfTicks = 10, tickLength = 2, bonusCoefficient = 0.06700000167,
      onTick = function(sim, _, dot)
        local sp = dot.spell
        local results = {}
        for _, t in ipairs(sim.targets) do results[#results + 1] = sp:CalcPeriodicDamage(sim, t, 97, OUT.TickMagicHitAndCrit) end
        for _, r in ipairs(results) do sp:DealPeriodicDamage(sim, r) end
      end },
    applyEffects = function(sim, _, spell)
      CancelFireTotems(p, sim)
      spell:AOEDot():Apply(sim)
      p.totemExpirations.Fire = sim.now + 20
    end })

  -- Fire Nova Totem: rolls its blast when dropped, explodes 4 s later (3 / 2 with Improved Fire Totems)
  local delay = 4 - T.ImprovedFireTotems
  p:RegisterSpell({ id = 25537, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.APL + F_SHAMAN + F_INSTANT, classMask = M.FireNovaTotem, manaCost = { flat = 765 }, gcd = 1, cd = 15,
    damageMultiplier = 1, bonusCoefficient = 0.21400000155,
    applyEffects = function(sim, _, spell)
      CancelFireTotems(p, sim)
      local base = sim:Roll(654, 730)
      local results = {}
      for _, t in ipairs(sim.targets) do results[#results + 1] = spell:CalcDamage(sim, t, base, OUT.MagicHitAndCrit) end
      local pa = { at = sim.now + delay, prio = 0, fn = function(s)
        for _, r in ipairs(results) do spell:DealDamage(s, r) end
      end }
      sim:Add(pa)
      sh.fireNovaPA = pa
      p.totemExpirations.Fire = sim.now + delay
    end })
end

function S.ShamanFireElemental(p)
  local sh = p.shaman
  local MQ = 0.1 * p.talents.MentalQuickness
  -- fire_elemental_pet.go: warrior base stats (no class extras), mana, 5% crits; owner's stamina / intellect x0.3 and
  -- spell damage (nature included, Mental Quickness's share left out), taken when it appears
  local base = { Health = 4264, Agility = 96, Strength = 145, Intellect = 33, Spirit = 51, Stamina = 133,
    AttackPower = 190, Mana = 4910, PhysicalCritPercent = 5, SpellCritPercent = 5 }
  local pet
  pet = S.NewPet(p, { name = "Greater Fire Elemental", key = "fire_elemental", baseStats = base, mana = true,
    mainHand = { baseMin = 134, baseMax = 134, swingSpeed = 2.0, normalizedSpeed = 2.4, apPerDps = 14 },
    inherit = function(o)
      return { [ST.Stamina] = o[ST.Stamina] * 0.3, [ST.Intellect] = o[ST.Intellect] * 0.3,
        [ST.SpellDamage] = o[ST.SpellDamage] + o[ST.NatureDamage] - o[ST.AttackPower] * MQ }
    end,
    rotation = function(sim, u) S.FireElementalRotation(sim, u) end })
  pet:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  pet:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Warrior)
  pet:AddStatDependency(ST.Intellect, ST.Mana, 15)
  -- its melee is fire damage with a share of its spell damage
  local mh = pet.autoAttacks.mhSpell
  mh.school = SCHOOL.Fire
  mh.schoolIndex = S.SCHOOL_INDEX[SCHOOL.Fire]
  mh.procMask = PM.MeleeMHAuto + PM.SpellDamage
  mh.flags = mh.flags + F_SHAMAN
  mh.classMask = M.FireElementalMelee
  mh.bonusCoefficient = 0.412
  local k = 46.977695 / 11.334235
  pet.fireBlast = pet:RegisterSpell({ id = 13339, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, flags = F_SHAMAN, manaCost = { flat = 120 }, nonEmpty = true,
    damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(110 * k, 130 * k), OUT.MagicHitAndCrit) end })
  pet.fireNova = pet:RegisterSpell({ id = 12470, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, flags = F_SHAMAN, manaCost = { flat = 95 }, castTime = 2, ignoreHaste = true,
    damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.332,
    applyEffects = function(sim, _, spell)
      local base = sim:Roll(148 * k, 170 * k)
      local results = {}
      for _, t in ipairs(sim.targets) do results[#results + 1] = spell:CalcDamage(sim, t, base, OUT.MagicHitAndCrit) end
      for _, r in ipairs(results) do spell:DealDamage(sim, r) end
    end })
  pet.fireShield = pet:RegisterSpell({ id = 13376, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, flags = F_SHAMAN, manaCost = { flat = 95 }, nonEmpty = true,
    damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.0109,
    dot = { label = "Fire Shield", selfOnly = true, numberOfTicks = 40, tickLength = 3,
      onTick = function(sim, _, dot)
        local sp = dot.spell
        local results = {}
        for _, t in ipairs(sim.targets) do results[#results + 1] = sp:CalcDamage(sim, t, 1.20000004768 * 69, OUT.MagicHitAndCrit) end
        for _, r in ipairs(results) do sp:DealDamage(sim, r) end
      end },
    applyEffects = function(sim, _, spell) spell:AOEDot():Apply(sim) end })
  sh.fireElemental = pet

  -- Fire Elemental Totem: summons it for 2 minutes; another fire totem dismisses it
  local feAura = p:RegisterAura({ label = "Fire Elemental Totem", actionId = { spellId = 2894 }, duration = 120,
    onExpire = function(a, sim) pet:DisablePet(sim) end })
  sh.elementalSharedTimer = sh.elementalSharedTimer or p:NewTimer()
  sh.fireElementalTotem = p:RegisterSpell({ id = 2894, defenseType = S.DEF_MAGIC, flags = F.APL + F_INSTANT,
    classMask = M.FireElementalTotem, manaCost = { flat = 680 }, gcd = 1, cd = 1200,
    sharedCd = 60, sharedCdTimer = sh.elementalSharedTimer, relatedSelfBuff = feAura,
    applyEffects = function(sim)
      CancelFireTotems(p, sim)
      p.totemExpirations.Fire = sim.now + 120
      pet:DisablePet(sim)
      pet:EnablePetWithTimeout(sim, 120)
      feAura:Activate(sim)
    end })
  p:AddMajorCooldown({ spell = sh.fireElementalTotem, shouldActivate = function() return false end })
end

-- fire_elemental_pet.go ExecuteCustomRotation: Fire Shield when it's down, then an 8% chance each of Fire Blast and
-- Fire Nova; every cast resets the swing timer; it acts again at its next swing (at least 1 s later).
local function TryCast(pet, sim, spell)
  if not spell:Cast(sim, pet.currentTarget) then return false end
  local ct = spell.castTime or 0
  pet.autoAttacks:StopMeleeUntil(sim, sim.now + ct)
  return true
end

function S.FireElementalRotation(sim, pet)
  if not pet.fireShield:AOEDot():IsActive() then TryCast(pet, sim, pet.fireShield) end
  local r = sim:Rand()
  if r >= 0.92 then
    TryCast(pet, sim, pet.fireBlast)
  elseif r >= 0.84 then
    TryCast(pet, sim, pet.fireNova)
  end
  if pet.GCD.readyAt > sim.now then return end
  pet:ExtendGCDUntil(sim, max(sim.now + 1, pet.autoAttacks:NextAttackAt()))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shocks (shocks.go): one shared cooldown
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanShocks(p)
  local timer = p:NewTimer()
  local function shock(id, school, cost, coef, mask, extraFlags)
    return { id = id, school = school, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
      flags = F_SHAMAN + F_SHOCK + F.APL + F_INSTANT + (extraFlags or 0), classMask = mask,
      manaCost = { flat = cost }, gcd = 1.5, cd = 6, cdTimer = timer,
      damageMultiplier = 1, bonusCoefficient = coef, threatMultiplier = 1 }
  end
  local es = shock(25454, SCHOOL.Nature, 535, 0.38600000739097595, M.EarthShock, F.Binary)
  es.applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(661, 696), OUT.MagicHitAndCrit) end
  p:RegisterSpell(es)

  local dotSpell = p:RegisterSpell({ id = 25457, tag = 1, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, flags = F_SHAMAN + F_SHOCK + F_INSTANT + F.PassiveSpell, classMask = M.FlameShockDot,
    damageMultiplier = 1, threatMultiplier = 1,
    dot = { label = "Flame Shock", numberOfTicks = 4, tickLength = 3, bonusCoefficient = 0.10000000149011612,
      onSnapshot = function(sim, target, dot) dot:Snapshot(target, 105) end,
      onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
    applyEffects = function(sim, t, spell) spell:Dot(t):Apply(sim) end })
  local fs = shock(25457, SCHOOL.Fire, 500, 0.21400000154972076, M.FlameShockDirect)
  fs.applyEffects = function(sim, t, spell)
    local r = spell:CalcDamage(sim, t, 377, OUT.MagicHitAndCrit)
    if S.Landed(r) then dotSpell:Cast(sim, t) end
    spell:DealDamage(sim, r)
  end
  p:RegisterSpell(fs)

  local frs = shock(25464, SCHOOL.Frost, 525, 0.38600000739097595, M.FrostShock, F.Binary)
  frs.applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(647, 683), OUT.MagicHitAndCrit) end
  p:RegisterSpell(frs)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Bloodlust (bloodlust.go): the shaman's own, sharing Sated with the raid's
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanBloodlust(p)
  local sated = p:GetAura("Sated") or p:RegisterAura({ label = "Sated", duration = 600 })
  local bl = p:RegisterAura({ label = "Bloodlust-2825:0", duration = 40, actionId = { spellId = 2825 },
    onGain = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1.3)
      a.unit:MultiplyCastSpeed(sim, 1.3)
      sated:Activate(sim)
    end,
    onExpire = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1 / 1.3)
      a.unit:MultiplyCastSpeed(sim, 1 / 1.3)
    end })
  local spell = p:RegisterSpell({ id = 2825, flags = F.APL + F_INSTANT, classMask = M.Bloodlust,
    manaCost = { flat = 750 }, gcd = 1.5, cd = 600, relatedSelfBuff = bl,
    applyEffects = function(sim) if not sated.active then bl:Activate(sim) end end })
  p:AddMajorCooldown({ spell = spell, priority = 1000, shouldActivate = function() return not sated.active end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Weapon imbues (weapon_imbues.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanImbues(p)
  local sh = p.shaman
  local aa = p.autoAttacks
  local function maskFor(imbue)
    local m = 0
    if sh.imbueMh == imbue then m = m + PM.MeleeMH end
    if sh.imbueOh == imbue then m = m + PM.MeleeOH end
    return m
  end

  -- Windfury Weapon: 20% (36% with both hands) per landed hit, 3 s cooldown: two extra attacks with bonus AP
  local wfMask = maskFor(IMBUE.WindfuryWeapon)
  if wfMask ~= 0 then
    local function wfSpell(isMH)
      local dmg = WeaponDamageFn(p, isMH)
      return p:RegisterSpell({ id = 25505, tag = isMH and 1 or 2, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
        procMask = isMH and PM.MeleeMHSpecial or PM.MeleeOHSpecial, classMask = M.WindfuryWeapon,
        flags = F.MeleeMetrics + F.PassiveSpell, damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 1,
        applyEffects = function(sim, t, spell)
          local bonus = sh.windfuryAPBonus
          if not isMH then bonus = bonus * 2 end
          local ap = spell:MeleeAttackPower(t) + bonus
          local b1, b2 = dmg(sim, ap), dmg(sim, ap)
          local r1 = spell:CalcDamage(sim, t, b1, OUT.MeleeSpecialHitAndCrit)
          local r2 = spell:CalcDamage(sim, t, b2, OUT.MeleeSpecialHitAndCrit)
          spell:DealDamage(sim, r1)
          spell:DealDamage(sim, r2)
        end })
    end
    local mhSpell, ohSpell = wfSpell(true), wfSpell(false)
    local both = wfMask == PM.MeleeMH + PM.MeleeOH
    local dpm = S.NewPPM(p, 0, wfMask, both and 0.36 or 0.2)
    local a = p:MakeProcTriggerAura({ name = "Windfury Imbue", callback = "hit", procMask = wfMask, isWeaponProc = true,
      outcome = O.Landed, icd = 3, dpm = dpm, triggerImmediately = true,
      handler = function(sim, spell, result)
        if has(spell.procMask, PM.MeleeMH) then mhSpell:Cast(sim, result.target) else ohSpell:Cast(sim, result.target) end
      end })
    if has(wfMask, PM.MeleeMH) then a:NewExclusiveEffect("WindfuryTotem", false, sh.windfuryAPBonus * 2) end
  end

  -- Flametongue Weapon: fire damage on every landed hit of that hand (35 per weapon speed second)
  local function flametongue(w, handMask, isMH)
    local spell = p:RegisterSpell({ id = 25489, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
      procMask = PM.SpellDamageProc, classMask = M.FlametongueWeapon, flags = F.PassiveSpell + F.Proc + F_SHAMAN,
      damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.10000000149,
      applyEffects = function(sim, t, sp)
        if w.swingSpeed ~= 0 then sp:CalcAndDealDamage(sim, t, w.swingSpeed * 35, OUT.MagicHitAndCrit) end
      end })
    local a = p:MakeProcTriggerAura({ name = "Flametongue Imbue " .. (isMH and "MH" or "OH"), procMask = handMask,
      isWeaponProc = true, outcome = O.Landed, callback = "hit", triggerImmediately = true,
      handler = function(sim, _, result) spell:Cast(sim, result.target) end })
    if isMH then a:NewExclusiveEffect("WindfuryTotem", false, sh.windfuryAPBonus * 2) end
  end
  if sh.imbueMh == IMBUE.FlametongueWeapon then flametongue(aa.mh, PM.MeleeMH, true) end
  if sh.imbueOh == IMBUE.FlametongueWeapon then flametongue(aa.oh, PM.MeleeOH, false) end

  -- Frostbrand Weapon: 9 procs per minute of frost damage (no base damage in WoWSims)
  local fbMask = maskFor(IMBUE.FrostbrandWeapon)
  if fbMask ~= 0 then
    local spell = p:RegisterSpell({ id = 8033, school = SCHOOL.Frost, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
      classMask = M.FrostbrandWeapon, flags = F.PassiveSpell + F.Proc + F_SHAMAN,
      damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.10000000149,
      applyEffects = function(sim, t, sp) sp:CalcAndDealDamage(sim, t, 0, OUT.MagicHitAndCrit) end })
    p:MakeProcTriggerAura({ name = "Frostbrand Imbue", callback = "hit", isWeaponProc = true, outcome = O.Landed,
      dpm = S.NewPPM(p, 9, fbMask), triggerImmediately = true, procMask = fbMask,
      handler = function(sim, _, result) spell:Cast(sim, result.target) end })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items and sets (items.go, item_sets.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.ShamanItems(p)
  local sh = p.shaman
  local function equipped(id)
    for _, gid in pairs(p.gearIds or {}) do if gid == id then return true end end
    return false
  end
  -- Totem of the Astral Winds: Windfury Weapon +80 attack power
  if equipped(27815) then sh.windfuryAPBonus = sh.windfuryAPBonus + 80 end
  -- Totem of Impact (A / H): shocks +46 base damage
  if equipped(27984) or equipped(27947) then
    p:AddStaticMod({ classMask = M.Shock, kind = "BaseDamage_Flat", value = 46 })
  end
  -- Ashtongue Talisman of Vision: Stormstrike, 50% for 275 attack power (10 s)
  if equipped(32491) then
    local a = p:NewTemporaryStatsAura("Power Surge", { [ST.AttackPower] = 275 }, 10)
    p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Vision - Trigger", classMask = M.StormstrikeCast + M.LightningBolt,
      callback = "hit", outcome = O.Landed, canProcFromProcs = true,
      handler = function(sim, spell)
        if has(spell.classMask, M.StormstrikeCast) and sim:Proc(0.5) then a:Activate(sim)
        elseif has(spell.classMask, M.LightningBolt) and sim:Proc(0.15) then p:AddMana(sim, 170, "ashtongue") end
      end, triggerImmediately = true })
  end
  -- lightning totems (items.go): Lightning Bolt / Chain Lightning base damage, Lightning Bolt cost
  local lightning = M.LightningBolt + M.ChainLightning + M.Overload
  for id, v in pairs({ [186071] = 10, [32330] = 85, [23199] = 33, [28248] = 55 }) do
    if equipped(id) then p:AddStaticMod({ classMask = lightning, kind = "BaseDamage_Flat", value = v }) end
  end
  if equipped(28066) then p:AddStaticMod({ classMask = M.LightningBolt, kind = "PowerCost_Flat", value = -15 }) end
  -- Skycall Totem: 15% on Lightning Bolt hits, 100 spell haste rating for 10 s
  if equipped(33506) then
    local a = p:NewTemporaryStatsAura("Energized", { [ST.SpellHasteRating] = 100 }, 10)
    p:MakeProcTriggerAura({ name = "Skycall Totem", callback = "hit", outcome = O.Landed, procChance = 0.15,
      classMask = M.LightningBolt + M.LightningBoltOverload, handler = function(sim) a:Activate(sim) end })
  end
  -- Cyclone Regalia 4: 11% on spell crits, the next spell costs 270 less
  if p:CouldHaveSetBonus("Cyclone Regalia", 4) then
    local a = p:RegisterAura({ label = "Energized (Cyclone Regalia)", actionId = { spellId = 37214 }, duration = 15,
      onCastComplete = function(aura, sim, spell) if spell.classMask ~= 0 then aura:Deactivate(sim) end end })
    a:AttachSpellMod({ kind = "PowerCost_Flat", value = -270 })
    p:MakeProcTriggerAura({ name = "Cyclone Regalia", callback = "hit", outcome = O.Crit, procMask = PM.SpellDamage,
      procChance = 0.11, handler = function(sim) a:Activate(sim) end })
  end
  -- Cataclysm Regalia 4: 25% on Lightning Bolt crits, 120 mana
  if p:CouldHaveSetBonus("Cataclysm Regalia", 4) then
    p:MakeProcTriggerAura({ name = "Lightning Bolt Discount", callback = "hit", outcome = O.Crit, procChance = 0.25,
      classMask = M.LightningBolt, handler = function(sim) p:AddMana(sim, 120, "cataclysm_regalia") end })
  end
  -- Skyshatter Regalia 2: with all four totems down, 15 mp5, 35 spell crit rating and 45 spell damage (checked every
  -- 3 s); 4: Lightning Bolt +5%
  if p:CouldHaveSetBonus("Skyshatter Regalia", 2) then
    local tm = p:RegisterAura({ label = "Totemic Mastery", actionId = { spellId = 38437 } })
    tm:AttachStatsBuff({ [ST.MP5] = 15, [ST.SpellCritRating] = 35, [ST.SpellDamage] = 45 })
    local check = p:RegisterAura({ label = "Totemic Mastery Periodic Check" })
    local pa
    check.onGain = function(_, sim)
      pa = S.StartPeriodicAction(sim, { period = 3, tickImmediately = true, onAction = function(s)
        local e = p.totemExpirations
        if math.min(e.Air, e.Earth, e.Fire, e.Water) < s.now then tm:Deactivate(s)
        elseif not tm.active then tm:Activate(s) end
      end })
      pa.cleanUp = function(s) tm:Deactivate(s) end
    end
    check.onExpire = function(_, sim) if pa and not pa.cancelled and not pa.consumed then sim:Cancel(pa) end end
    S.MakePermanent(check)
  end
  if p:CouldHaveSetBonus("Skyshatter Regalia", 4) then
    p:AddStaticMod({ classMask = M.LightningBolt + M.LightningBoltOverload, kind = "DamageDone_Flat", value = 0.05 })
    local a = S.MakePermanent(p:RegisterAura({ label = "Skyshatter Regalia 4pc", actionId = { spellId = 38436 } }))
  end
  -- Cyclone Harness: 2 = Strength of Earth +12 (totems), 4 = Stormstrike +30 per weapon
  if p:CouldHaveSetBonus("Cyclone Harness", 4) then
    p:AddStaticMod({ classMask = M.StormstrikeDamage, kind = "BaseDamage_Flat", value = 30 })
  end
  -- Skyshatter Harness: 2 = shocks cost 10% less, 4 = Stormstrike gives 70 attack power for 12 s
  if p:CouldHaveSetBonus("Skyshatter Harness", 2) then
    p:AddStaticMod({ classMask = M.Shock, kind = "PowerCost_Pct_Add", value = -0.1 })
  end
  if p:CouldHaveSetBonus("Skyshatter Harness", 4) then
    local a = p:NewTemporaryStatsAura("Stormstrike AP Buff", { [ST.AttackPower] = 70 }, 12)
    p:MakeProcTriggerAura({ name = "Skyshatter Harness 4pc", callback = "cast", classMask = M.StormstrikeCast,
      canProcFromProcs = true, handler = function(sim) a:Activate(sim) end, triggerImmediately = true })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Lightning Bolt and Chain Lightning with their overloads (electric_spell.go, lightning_bolt.go, chain_lightning.go),
-- Water Shield (shields.go)
-- ---------------------------------------------------------------------------------------------------------------
local function ElectricSpell(p, cfg, overload)
  local sh = p.shaman
  local spell = {
    id = cfg.id, tag = overload and 6 or 0, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
    flags = F_SHAMAN + F_FOCUSABLE + (overload and (F.PassiveSpell + F.Proc) or F.APL),
    classMask = overload and cfg.overloadMask or cfg.mask,
    damageMultiplier = overload and 0.5 or 1, bonusCoefficient = cfg.coef, threatMultiplier = overload and 0 or 1,
  }
  if not overload then
    spell.manaCost = { flat = cfg.cost }
    spell.castTime = cfg.castTime
    spell.gcd = 1.5
    spell.modifyCast = function(sim, sp, gcd, castTime)
      local ct = castTime * p.castSpeed
      local aa = p.autoAttacks
      if sim.now + ct > aa:NextAttackAt() then aa:StopMeleeUntil(sim, sim.now + ct) end
      return gcd, castTime
    end
  end
  return spell
end

function S.ShamanElectricSpells(p)
  local sh = p.shaman
  -- Lightning Bolt (rank 12): travels at 20 yards a second; an overload is cast when it lands
  local lbOverload
  local function lb(overload)
    local cfg = ElectricSpell(p, { id = 25449, mask = M.LightningBolt, overloadMask = M.LightningBoltOverload,
      cost = 300, castTime = 2.5, coef = 0.7940000295639038 }, overload)
    cfg.applyEffects = function(sim, target, spell)
      local r = spell:CalcDamage(sim, target, sim:Roll(571, 652), OUT.MagicHitAndCrit)
      local travel = p.distance / 20
      sim:Add({ at = sim.now + travel, prio = 0, fn = function(s)
        if not overload and S.Landed(r) and s:Proc(sh.overloadChance) then lbOverload:Cast(s, target) end
        spell:DealDamage(s, r)
      end })
    end
    return p:RegisterSpell(cfg)
  end
  lb(false)
  lbOverload = lb(true)

  -- Chain Lightning (rank 6): one target here; overloads at a third of the chance
  local clOverload
  local timer = p:NewTimer()
  local function cl(overload)
    local cfg = ElectricSpell(p, { id = 25442, mask = M.ChainLightning, overloadMask = M.ChainLightningOverload,
      cost = 760, castTime = 2, coef = 0.6510000228881836 }, overload)
    if not overload then cfg.cd = 6; cfg.cdTimer = timer end
    local bounce = 0.7 + (p:CouldHaveSetBonus("Tidefury Raiment", 2) and 0.13 or 0)
    cfg.applyEffects = function(sim, target, spell)
      local r = spell:CalcDamage(sim, target, sim:Roll(734, 838), OUT.MagicHitAndCrit)
      spell.damageMultiplier = spell.damageMultiplier * bounce
      if not overload and S.Landed(r) and sim:Proc(sh.overloadChance / 3) then clOverload:Cast(sim, r.target) end
      spell:DealDamage(sim, r)
      spell.damageMultiplier = spell.damageMultiplier / bounce
    end
    return p:RegisterSpell(cfg)
  end
  cl(false)
  clOverload = cl(true)

  -- Water Shield: +50 mana per 5 s while it holds (no hits taken here)
  local ws = p:RegisterAura({ label = "Water Shield", actionId = { spellId = 33736 }, duration = 600, maxStacks = 3 })
  ws:AttachStatBuff(ST.MP5, 50)
  p:RegisterSpell({ id = 33736, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, flags = F.APL + F_INSTANT, gcd = 1.5,
    relatedSelfBuff = ws,
    applyEffects = function(sim)
      ws:Activate(sim)
      ws:SetStacks(sim, 3)
    end })
end

-- shaman.go Initialize + enhancement.go / elemental.go Initialize
function S.ShamanInitialize(p)
  S.ShamanElectricSpells(p)
  S.ShamanFireElemental(p)
  S.ShamanFireTotems(p)
  S.ShamanTotems(p)
  S.ShamanShocks(p)
  S.ShamanBloodlust(p)
  S.ShamanImbues(p)
end

-- Built after the owner (its stats rest on the finished base stats); reset with the owner each iteration.
function S.ShamanFinalizePets(p)
  for _, pet in ipairs(p.pets or {}) do pet:Finalize() end
  local og = p.agentReset
  p.agentReset = function(sim)
    if og then og(sim) end
    S.ResetPets(p, sim)
  end
  local od = p.agentDone
  p.agentDone = function(sim)
    if od then od(sim) end
    S.DonePets(p, sim)
  end
end

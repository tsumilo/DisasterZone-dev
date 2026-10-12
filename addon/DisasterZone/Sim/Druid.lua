if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Druid.lua", ...) then return end -- DisasterZone: Sim/Druid.lua
-- ns.GearSim Druids (WoWSims sim/druid, sim/druid/feralcat): forms (Cat Form's paws and attack power, the energy a
-- shift brings), the talents, Feral Cat's abilities, Omen of Clarity, idols and tier sets. Built in WoWSims' order:
-- SetupDruid (constructor: bars, form auras) before racials, DruidApplyTalents after item effects, DruidInitialize
-- (the class spells) after consumables.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (proto/druid.proto field order; trees of 21, 21, 20)
-- ---------------------------------------------------------------------------------------------------------------
local TALENTS = {
  { "StarlightWrath", "NaturesGrasp", "ImprovedNaturesGrasp", "ControlOfNature", "FocusedStarlight",
    "ImprovedMoonfire", "Brambles", "InsectSwarm", "NaturesReach", "Vengeance", "CelestialFocus", "LunarGuidance",
    "NaturesGrace", "Moonglow", "Moonfury", "BalanceOfPower", "Dreamstate", "MoonkinForm", "ImprovedFaerieFire",
    "WrathOfCenarius", "ForceOfNature" },
  { "Ferocity", "FeralAggression", "FeralInstinct", "BrutalImpact", "ThickHide", "FeralSwiftness", "FeralCharge",
    "SharpenedClaws", "ShreddingAttacks", "PredatoryStrikes", "PrimalFury", "SavageFury", "FaerieFireFeral",
    "NurturingInstinct", "HeartOfTheWild", "SurvivalOfTheFittest", "PrimalTenacity", "LeaderOfThePack",
    "ImprovedLeaderOfThePack", "PredatoryInstincts", "Mangle" },
  { "ImprovedMarkOfTheWild", "Furor", "Naturalist", "NaturesFocus", "NaturalShapeshifter", "Intensity", "Subtlety",
    "OmenOfClarity", "TranquilSpirit", "ImprovedRejuvenation", "NaturesSwiftness", "GiftOfNature",
    "ImprovedTranquility", "EmpoweredTouch", "ImprovedRegrowth", "LivingSpirit", "Swiftmend", "NaturalPerfection",
    "EmpoweredRejuvenation", "TreeOfLife" },
}
S.DRUID_TALENTS = TALENTS

-- ---------------------------------------------------------------------------------------------------------------
-- Class spell masks (druid.go)
-- ---------------------------------------------------------------------------------------------------------------
local M
do
  local nextBit
  M, nextBit = S.SpellMasks({
    "EntanglingRoots", "DemoralizingRoar", "FaerieFire", "FaerieFireFeral", "ForceOfNature",
    "Hurricane", "FerociousBite", "FrenziedRegeneration", "Innervate", "InsectSwarm", "Lacerate", "MangleBear",
    "MangleCat", "Maul", "MoonfireInitial", "MoonfireDoT", "Rake", "Ravage", "Rip", "Shred", "Starfire", "Swipe",
    "Thorns", "Wrath", "Enrage", "TigersFury", "CatForm", "BearForm", "HealingTouch", "Regrowth", "Lifebloom",
    "Rejuvenation", "Tranquility", "MarkOfTheWild", "Swiftmend", "CenarionWard" })
  M.All = nextBit * 2 - 2
  M.Moonfire = M.MoonfireInitial + M.MoonfireDoT
  M.Mangle = M.MangleBear + M.MangleCat
  M.Builder = M.Mangle + M.Shred + M.Rake + M.Ravage
  M.Finisher = M.FerociousBite + M.Rip
  M.Arcane = M.Moonfire + M.Starfire
  M.Nature = M.Wrath + M.Hurricane + M.InsectSwarm
  M.Healing = M.HealingTouch + M.Regrowth + M.Rejuvenation + M.Lifebloom + M.Swiftmend
  M.Damaging = M.Arcane + M.Nature
end
S.DRUID_MASK = M

-- Forms (forms.go)
local HUMANOID, BEAR, CAT, MOONKIN, TREE = 1, 2, 4, 8, 16
local ANY = HUMANOID + BEAR + CAT + MOONKIN + TREE
S.DRUID_FORM = { Humanoid = HUMANOID, Bear = BEAR, Cat = CAT, Moonkin = MOONKIN, Any = ANY }
local ANIMAL_SPIRIT_REGEN = 0.911337

local function InForm(dru, mask) return has(mask, dru.form) end

local function ClearForm(p, sim)
  local dru = p.druid
  if InForm(dru, CAT) and dru.catFormAura then dru.catFormAura:Deactivate(sim)
  elseif InForm(dru, BEAR) and dru.bearFormAura then dru.bearFormAura:Deactivate(sim)
  elseif InForm(dru, MOONKIN) and dru.moonkinFormAura then dru.moonkinFormAura:Deactivate(sim) end
  dru.form = HUMANOID
end
S.DruidClearForm = ClearForm

-- druid.go RegisterSpell: a spell usable in some forms; a caster-form spell drops the animal form when cast.
local function FormSpell(p, mask, cfg)
  local dru = p.druid
  local prev = cfg.extraCastCondition
  cfg.extraCastCondition = function(sim, target)
    if mask ~= ANY and not InForm(dru, mask) and not has(mask, HUMANOID) then return false end
    return prev == nil or prev(sim, target)
  end
  local prevModify = cfg.modifyCast
  cfg.modifyCast = function(sim, spell, gcd, castTime)
    if not InForm(dru, mask) and has(mask, HUMANOID) then ClearForm(p, sim) end
    if prevModify then return prevModify(sim, spell, gcd, castTime) end
    return gcd, castTime
  end
  return p:RegisterSpell(cfg)
end
S.DruidFormSpell = FormSpell

-- forms.go GetCatWeapon: the main hand's damage per second (weightstone included) as a 1.0 speed paw.
local function CatWeapon(p)
  local item = p.gear.MainHand and p.gear.MainHand.item
  local lo, hi, speed = 0, 0, 1
  if item and (item.weaponSpeed or 0) > 0 then
    lo, hi, speed = item.weaponMin + p.ps.BonusMHDps * item.weaponSpeed, item.weaponMax + p.ps.BonusMHDps * item.weaponSpeed,
      item.weaponSpeed
  end
  local imbue = ((p.consumables or {}).mhImbueId == 34340) and 12 or 0
  return { baseMin = (lo + imbue) / speed, baseMax = (hi + imbue) / speed, swingSpeed = 1, normalizedSpeed = 1, apPerDps = 14 }
end

local function MainHandWeapon(p)
  local item = p.gear.MainHand and p.gear.MainHand.item
  if not (item and (item.weaponSpeed or 0) > 0) then return S.UnarmedWeapon() end
  return S.WeaponFromItem({ min = item.weaponMin, max = item.weaponMax, speed = item.weaponSpeed, twoHand = item.handType == 4,
    dagger = item.weaponType == 2, weaponType = item.weaponType, handType = item.handType }, p.ps.BonusMHDps)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (druid.go New, feralcat.go NewFeralCatDruid)
-- opts: { form = "Cat" | "Moonkin" | nil (humanoid) }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupDruid(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local startForm = (opts.form == "Cat" and CAT) or (opts.form == "Moonkin" and MOONKIN) or HUMANOID
  local dru = { talents = T, startForm = startForm, form = startForm, wolfsheadEnergy = 0, furorChance = 0,
    shredFlatBonus = 0, idolFerociousBite = 0, idolMangleCat = 0, idolShred = 0, idolRip = 0 }
  p.druid = dru
  p:AddStatDependency(ST.Strength, ST.AttackPower, 1)
  p:AddStatDependency(ST.BonusArmor, ST.Armor, 1)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Druid)
  p:AddStatDependency(ST.Agility, ST.DodgeRating, 1 / 14.7059 * S.DODGE_RATING_PER_PCT)
  p.ps.BaseDodgeChance = (p.ps.BaseDodgeChance or 0) - 0.0187
  if startForm == MOONKIN then
    -- balance.go: a caster, no melee; back in its starting form at every reset (druid.go Reset)
    dru.moonkin = true
    p.autoAttacks.autoSwingMelee = false
    if T.MoonkinForm > 0 then S.DruidRegisterMoonkinForm(p) end
    p:RegisterResetEffect(function() dru.form = dru.startForm end)
  end
  if startForm == CAT then
    dru.cat = true
    p:EnableEnergyBar({ maxEnergy = 100, maxComboPoints = 5 })
    -- the paws are the main hand from the start (WoWSims builds weapon procs and Omen of Clarity off them)
    p.autoAttacks:SetMH(CatWeapon(p))
    local a = S.DruidRegisterCatFormAura(p)
    -- feralcat.go Reset: back in Cat Form at every reset (after the auras' own reset, as WoWSims' agent reset)
    a.onReset = function(aura, sim)
      dru.form = dru.startForm
      ClearForm(p, sim)
      aura:Activate(sim)
    end
  end
  return dru
end

-- forms.go RegisterCatFormAura
function S.DruidRegisterCatFormAura(p)
  local dru, T = p.druid, p.talents
  local aa = p.autoAttacks
  local agiAp = p:NewDynamicStatDependency(ST.Agility, ST.AttackPower, 1)
  local strAp = p:NewDynamicStatDependency(ST.Strength, ST.AttackPower, 1)
  local feralAp = p:NewDynamicStatDependency(ST.FeralAttackPower, ST.AttackPower, 1)
  local hotw = T.HeartOfTheWild > 0 and p:NewDynamicMultiplyStat(ST.AttackPower, 1 + 0.02 * T.HeartOfTheWild) or nil
  local claw = CatWeapon(p)
  local mainHand = MainHandWeapon(p)
  local bonus, minus = { [ST.AttackPower] = 140 }, { [ST.AttackPower] = -140 }
  local a = p:RegisterAura({ label = "Cat Form", actionId = { spellId = 768 } })
  a.onGain = function(aura, sim)
    if dru.form ~= HUMANOID then ClearForm(p, sim) end
    dru.form = CAT
    p.ps.SpiritRegenMultiplier = p.ps.SpiritRegenMultiplier * ANIMAL_SPIRIT_REGEN
    p:AddStatsDynamic(sim, bonus)
    p:EnableDynamicStatDep(sim, agiAp)
    p:EnableDynamicStatDep(sim, strAp)
    p:EnableDynamicStatDep(sim, feralAp)
    if hotw then p:EnableDynamicStatDep(sim, hotw) end
    aa:SetMH(claw)
    aa:EnableAutoSwing(sim)
    p:UpdateManaRegenRates()
    if sim.now > 0 then
      if p.energy > 0 then p:SpendEnergy(sim, p.energy) end
      local gain = dru.wolfsheadEnergy
      if dru.furorChance == 1 or (dru.furorChance > 0 and sim:Rand() < dru.furorChance) then gain = gain + 40 end
      if gain > 0 then p:AddEnergy(sim, gain, "cat_form") end
    end
  end
  a.onExpire = function(aura, sim)
    dru.form = HUMANOID
    p.ps.SpiritRegenMultiplier = p.ps.SpiritRegenMultiplier / ANIMAL_SPIRIT_REGEN
    p:AddStatsDynamic(sim, minus)
    p:DisableDynamicStatDep(sim, agiAp)
    p:DisableDynamicStatDep(sim, strAp)
    p:DisableDynamicStatDep(sim, feralAp)
    if hotw then p:DisableDynamicStatDep(sim, hotw) end
    if dru.tigersFuryAura then dru.tigersFuryAura:Deactivate(sim) end
    aa:SetMH(mainHand)
    aa:EnableAutoSwing(sim)
    p:UpdateManaRegenRates()
  end
  dru.catFormAura = a
  return a
end

-- feralcat.go AddPartyBuffs: the cat brings Leader of the Pack (improved with Idol of the Raven Goddess) and never
-- procs Windfury Totem.
function S.DruidCatPartyBuffs(p, cfg)
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local party = {}
  for k, v in pairs(cfg.party or {}) do party[k] = v end
  if p.talents.LeaderOfThePack > 0 then
    local want = (p.gearIds.Ranged == 32387) and 2 or 1
    local have = party.leaderOfThePack == true and 1 or (party.leaderOfThePack or 0)
    if have < want then party.leaderOfThePack = want end
  end
  party.windfuryTotem = 0
  out.party = party
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go, omen_of_clarity.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.DruidApplyTalents(p)
  local dru, T = p.druid, p.talents
  local cat = dru.catFormAura

  -- Balance
  if T.StarlightWrath > 0 then
    p:AddStaticMod({ classMask = M.Starfire + M.Wrath, kind = "CastTime_Flat", value = -0.1 * T.StarlightWrath })
  end
  if T.FocusedStarlight > 0 then
    p:AddStaticMod({ classMask = M.Starfire + M.Wrath, kind = "BonusCrit_Percent", value = 2 * T.FocusedStarlight })
  end
  if T.ImprovedMoonfire > 0 then
    p:AddStaticMod({ classMask = M.Moonfire, kind = "DamageDone_Flat", value = 0.05 * T.ImprovedMoonfire })
    p:AddStaticMod({ classMask = M.Moonfire, kind = "BonusCrit_Percent", value = 5 * T.ImprovedMoonfire })
  end
  if T.Vengeance > 0 then
    p:AddStaticMod({ classMask = M.Wrath + M.Starfire + M.Moonfire, kind = "CritMultiplier_Flat", value = 0.2 * T.Vengeance })
  end
  if T.LunarGuidance > 0 then
    p:AddStatDependency(ST.Intellect, ST.SpellDamage, ({ 0.08, 0.16, 0.25 })[T.LunarGuidance])
  end
  if T.Moonglow > 0 then
    p:AddStaticMod({ classMask = M.Moonfire + M.Starfire + M.Wrath + M.HealingTouch + M.Regrowth + M.Rejuvenation,
      kind = "PowerCost_Pct_Add", value = -0.03 * T.Moonglow })
  end
  if T.Moonfury > 0 then
    p:AddStaticMod({ classMask = M.Wrath + M.Starfire + M.Moonfire, kind = "DamageDone_Flat", value = 0.02 * T.Moonfury })
  end
  if T.BalanceOfPower > 0 then
    local a = S.MakePermanent(p:RegisterAura({ label = "Balance of Power", actionId = { spellId = 33596 } }))
    a:AttachSpellMod({ classMask = M.Wrath + M.Starfire + M.Moonfire, kind = "BonusHit_Percent", value = 2 * T.BalanceOfPower })
  end
  if T.Dreamstate > 0 then
    p:AddStatDependency(ST.Intellect, ST.MP5, ({ 0, 0.04, 0.07, 0.1 })[T.LunarGuidance + 1])
  end
  if T.WrathOfCenarius > 0 then
    p:AddStaticMod({ classMask = M.Wrath, kind = "BonusCoefficient_Flat", value = 0.02 * T.WrathOfCenarius })
    p:AddStaticMod({ classMask = M.Starfire, kind = "BonusCoefficient_Flat", value = 0.04 * T.WrathOfCenarius })
  end
  if T.NaturesGrace > 0 then S.DruidNaturesGrace(p) end

  -- Feral
  if T.Furor > 0 then dru.furorChance = 0.2 * T.Furor end
  if T.Ferocity > 0 then
    p:AddStaticMod({ classMask = M.Rake + M.MangleCat, kind = "PowerCost_Flat", value = -T.Ferocity })
    p:AddStaticMod({ classMask = M.MangleBear + M.Maul + M.Swipe, kind = "PowerCost_Flat", value = -T.Ferocity })
  end
  if T.FeralAggression > 0 then
    p:AddStaticMod({ classMask = M.FerociousBite, kind = "DamageDone_Flat", value = 0.03 * T.FeralAggression })
  end
  if T.PredatoryInstincts > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Pct", school = SCHOOL.Physical, value = 0.02 * T.PredatoryInstincts })
  end
  if cat and T.SharpenedClaws > 0 then cat:AttachStatsBuff({ [ST.PhysicalCritPercent] = 2 * T.SharpenedClaws }) end
  if cat and T.FeralSwiftness > 0 then cat:AttachStatsBuff({ [ST.DodgeRating] = S.DODGE_RATING_PER_PCT * 2 * T.FeralSwiftness }) end
  if T.ShreddingAttacks > 0 then
    p:AddStaticMod({ classMask = M.Shred, kind = "PowerCost_Flat", value = -9 * T.ShreddingAttacks })
    p:AddStaticMod({ classMask = M.Lacerate, kind = "PowerCost_Flat", value = -T.ShreddingAttacks })
  end
  if cat and T.PredatoryStrikes > 0 then cat:AttachStatsBuff({ [ST.AttackPower] = T.PredatoryStrikes * 0.5 * 70 }) end
  if T.PrimalFury > 0 then
    p:MakeProcTriggerAura({ name = "Primal Fury (Cat)", actionId = { spellId = 37117 }, callback = "hit",
      classMask = M.Builder, outcome = O.Crit, procChance = 0.5 * T.PrimalFury,
      extraCondition = function() return InForm(dru, CAT) end,
      handler = function(sim) p:AddComboPoints(sim, 1, "primal_fury") end })
  end
  if T.SavageFury > 0 then
    p:AddStaticMod({ classMask = M.MangleCat + M.Rake, kind = "DamageDone_Flat", value = 0.1 * T.SavageFury })
  end
  if T.HeartOfTheWild > 0 then p:MultiplyStat(ST.Intellect, 1 + 0.04 * T.HeartOfTheWild) end
  if T.SurvivalOfTheFittest > 0 then
    local m = 1 + 0.01 * T.SurvivalOfTheFittest
    for _, s in ipairs({ ST.Stamina, ST.Strength, ST.Agility, ST.Intellect, ST.Spirit }) do p:MultiplyStat(s, m) end
  end

  -- Restoration
  if T.NaturalShapeshifter > 0 then
    p:AddStaticMod({ classMask = M.CatForm + M.BearForm, kind = "PowerCost_Pct_Add", value = -0.1 * T.NaturalShapeshifter })
  end
  if T.Naturalist > 0 then
    local i = S.SCHOOL_INDEX[SCHOOL.Physical]
    p.ps.SchoolDamageDealtMultiplier[i] = p.ps.SchoolDamageDealtMultiplier[i] * (1 + 0.02 * T.Naturalist)
  end
  if T.Intensity > 0 then
    p.ps.SpiritRegenRateCasting = p.ps.SpiritRegenRateCasting + 0.1 * T.Intensity
    p:UpdateManaRegenRates()
  end
  if T.OmenOfClarity > 0 then S.DruidOmenOfClarity(p) end
  if T.LivingSpirit > 0 then p:MultiplyStat(ST.Spirit, 1 + 0.05 * T.LivingSpirit) end
  if T.NaturalPerfection > 0 then
    p:AddStaticMod({ classMask = M.All, kind = "BonusCrit_Percent", value = T.NaturalPerfection })
  end
end

-- omen_of_clarity.go: 2 PPM on melee hits off the main hand's real speed, 10 s cooldown; the next ability is free.
function S.DruidOmenOfClarity(p)
  local dru = p.druid
  local cc = M.MangleCat + M.Rake + M.Rip + M.FerociousBite + M.Shred + M.MangleBear + M.Maul + M.Lacerate +
    M.Swipe + M.DemoralizingRoar
  local item = p.gear.MainHand and p.gear.MainHand.item
  local mhSpeed = (item and (item.weaponSpeed or 0) > 0) and item.weaponSpeed or 1
  local autoChance = 2 * p.autoAttacks.mh.swingSpeed / 60
  local specialChance = (item and (item.weaponSpeed or 0) > 0) and 2 * mhSpeed / 60 or autoChance
  local a = p:RegisterAura({ label = "Clearcasting", actionId = { spellId = 16870 }, duration = 15 })
  a.onCastComplete = function(aura, sim, spell) if spell:Matches(cc) then aura:Deactivate(sim) end end
  a:AttachSpellMod({ kind = "PowerCost_Pct_Add", classMask = cc, value = -1 })
  dru.clearcastingAura = a
  p:MakeProcTriggerAura({ name = "Omen of Clarity", actionId = { spellId = 16864 }, callback = "hit",
    procMask = PM.Melee, icd = 10,
    extraCondition = function(sim, spell)
      local chance = has(spell.procMask, PM.MeleeMHAuto) and autoChance or specialChance
      return sim:Rand() < chance
    end,
    handler = function(sim) a:Activate(sim) end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Class spells (druid.go Initialize, RegisterFeralCatSpells)
-- ---------------------------------------------------------------------------------------------------------------
function S.DruidInitialize(p)
  local dru, T = p.druid, p.talents
  -- potions, conjured items and explosives drop an animal form (druid.go registerFormBreakingConsumes)
  p.postFinalize[#p.postFinalize + 1] = function()
    for _, sp in ipairs(p.spellbook) do
      if has(sp.flags, F.Potion) or has(sp.flags, F.Conjured) or has(sp.flags, F.Explosive) then
        local prev = sp.applyEffects
        sp.applyEffects = function(sim, target, spell)
          prev(sim, target, spell)
          if InForm(dru, BEAR + CAT) then ClearForm(p, sim) end
        end
      end
    end
  end
  if dru.cat then S.DruidRegisterCatSpells(p) end
  if dru.moonkin then S.DruidRegisterBalanceSpells(p) end
end

function S.DruidRegisterCatSpells(p)
  local dru, T = p.druid, p.talents
  local aa = p.autoAttacks

  -- Cat Form (forms.go registerCatFormSpell): the powershift
  FormSpell(p, ANY, { id = 768, classMask = M.CatForm, flags = F.NoOnCastComplete + F.APL, manaCost = { basePct = 35 },
    gcd = 1.5, ignoreHaste = true,
    applyEffects = function(sim)
      if dru.catFormAura.active then dru.catFormAura:Deactivate(sim) end
      dru.catFormAura:Activate(sim)
    end })

  local function mangled(target)
    local a = target:GetAura("Mangle")
    return a and a.active
  end

  -- Mangle (Cat)
  if T.Mangle > 0 then
    S.MangleAura(p.currentTarget)
    FormSpell(p, CAT, { id = 33983, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      classMask = M.MangleCat, flags = F.MeleeMetrics + F.APL, energyCost = { cost = 45, refund = 0.8 }, gcd = 1,
      ignoreHaste = true, damageMultiplier = 1.6, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = (165 * 1.6 + dru.idolMangleCat) / 1.6 + S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        if S.Landed(r) then
          p:AddComboPoints(sim, 1, "mangle")
          S.MangleAura(target):Activate(sim)
        else
          spell:IssueRefund(sim)
        end
      end })
  end

  -- Rake
  local rake
  rake = FormSpell(p, CAT, { id = 27003, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    classMask = M.Rake, flags = F.MeleeMetrics + F.APL, energyCost = { cost = 40, refund = 0.8 }, gcd = 1,
    ignoreHaste = true, damageMultiplier = 1, threatMultiplier = 1,
    dot = { label = "Rake", numberOfTicks = 3, tickLength = 3,
      onSnapshot = function(sim, target, dot) dot:SnapshotPhysical(target, 36 + 0.02 * rake:MeleeAttackPower(target)) end,
      onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
    applyEffects = function(sim, target, spell)
      local base = 78 + 0.01 * spell:MeleeAttackPower(target)
      if mangled(target) then base = base * 1.3 end
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if S.Landed(r) then
        p:AddComboPoints(sim, 1, "rake")
        spell:Dot(target):Apply(sim)
      else
        spell:IssueRefund(sim)
      end
    end })

  -- Rip
  local rip
  rip = FormSpell(p, CAT, { id = 27008, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    classMask = M.Rip, flags = F.MeleeMetrics + F.APL, energyCost = { cost = 30 }, gcd = 1, ignoreHaste = true,
    damageMultiplier = 1, threatMultiplier = 1,
    extraCastCondition = function() return p.comboPoints > 0 end,
    dot = { label = "Rip", numberOfTicks = 6, tickLength = 2,
      onSnapshot = function(sim, target, dot)
        local cp = p.comboPoints
        local ap = rip:MeleeAttackPower(target)
        local tick
        if cp <= 3 then tick = 990 + 0.18 * ap elseif cp == 4 then tick = 1272 + 0.24 * ap else tick = 1554 + 0.24 * ap end
        dot:SnapshotPhysical(target, tick / 6 + dru.idolRip * cp)
      end,
      onTick = function(sim, target, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, target, OUT.Tick) end },
    applyEffects = function(sim, target, spell)
      local r = spell:CalcOutcome(sim, target, OUT.MeleeSpecialHitNoHitCounter)
      if S.Landed(r) then
        spell:Dot(target):Apply(sim)
        p:SpendComboPoints(sim)
      end
      spell:DealDamage(sim, r)
    end })

  -- Ferocious Bite
  FormSpell(p, CAT, { id = 24248, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    classMask = M.FerociousBite, flags = F.MeleeMetrics + F.APL, energyCost = { cost = 35 }, gcd = 1, ignoreHaste = true,
    damageMultiplier = 1, threatMultiplier = 1,
    extraCastCondition = function() return p.comboPoints > 0 end,
    applyEffects = function(sim, target, spell)
      local cp = p.comboPoints
      local ap = spell:MeleeAttackPower(target)
      local excess = p.energy
      if excess > 0 then p:SpendEnergy(sim, excess) end
      local base = 57 + (169 + dru.idolFerociousBite) * cp + 4.1 * excess + 0.05 * cp * ap
      base = base + sim:Rand() * (123 - 57)
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if S.Landed(r) then p:SpendComboPoints(sim) end
    end })

  -- Faerie Fire (Feral)
  if T.FaerieFireFeral > 0 then
    S.FaerieFireAura(p.currentTarget, T.ImprovedFaerieFire)
    FormSpell(p, CAT + BEAR, { id = 27011, classMask = M.FaerieFireFeral, school = SCHOOL.Nature,
      defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage, flags = F.APL, gcd = 1, ignoreHaste = true, cd = 6,
      threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHit)
        if S.Landed(r) then S.FaerieFireAura(target, T.ImprovedFaerieFire):Activate(sim) end
      end })
  end

  -- Shred
  FormSpell(p, CAT, { id = 27002, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
    classMask = M.Shred, flags = F.MeleeMetrics + F.APL, energyCost = { cost = 60, refund = 0.8 }, gcd = 1,
    ignoreHaste = true, damageMultiplier = 2.25, threatMultiplier = 1,
    extraCastCondition = function() return not p.ps.InFrontOfTarget and not dru.cannotShred end,
    applyEffects = function(sim, target, spell)
      local base = (180 * 2.25 + dru.idolShred + dru.shredFlatBonus) / 2.25 + S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      if mangled(target) then base = base * 1.3 end
      local r = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
      if S.Landed(r) then p:AddComboPoints(sim, 1, "shred") else spell:IssueRefund(sim) end
    end })

  -- Tiger's Fury: +40 weapon damage for 6 s
  do
    local a = p:RegisterAura({ label = "Tiger's Fury", actionId = { spellId = 9846 }, duration = 6,
      onGain = function() aa.mh.baseMin = aa.mh.baseMin + 40; aa.mh.baseMax = aa.mh.baseMax + 40 end,
      onExpire = function() aa.mh.baseMin = aa.mh.baseMin - 40; aa.mh.baseMax = aa.mh.baseMax - 40 end })
    dru.tigersFuryAura = a
    FormSpell(p, CAT, { id = 9846, classMask = M.TigersFury, flags = F.APL, energyCost = { cost = 30 }, cd = 1,
      ignoreHaste = true, applyEffects = function(sim) a:Activate(sim) end })
  end

  -- feralcat.go Reset: drums used whenever ready and Bloodlust at 5 s, unless the rotation casts them itself
  p:RegisterResetEffect(function(sim)
    local function mcd(key, spellIdOnly)
      for _, m in ipairs(p.majorCooldowns or {}) do
        local k = m.spell.actionKey
        if k == key or (spellIdOnly and k and k:match("^s" .. spellIdOnly .. ":")) then return m end
      end
      return nil
    end
    local drums = mcd("s35476:0") or mcd("s35476:-1")
    if drums then
      local pa
      pa = { at = 0, prio = 0, fn = function(s)
        local cast = drums.spell:IsReady(s) and p:TryActivateMCD(s, drums)
        local nextAt = s.now + drums.spell:TimeToReady(s)
        if not cast then nextAt = max(nextAt, s.now + 1.5) end
        if nextAt < s.duration then pa.at = nextAt; s:Add(pa) end
      end }
      sim:Add(pa)
    end
    local bl = mcd(nil, 2825)
    if bl then
      sim:Add({ at = 5, prio = 0, fn = function(s) if bl.spell:IsReady(s) then p:TryActivateMCD(s, bl) end end })
    end
  end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Idols, items and sets (items.go, item_sets.go)
-- ---------------------------------------------------------------------------------------------------------------
local IE = S.ITEM_EFFECTS
local function DruidBonus(field, v) return function(p) if p.druid then p.druid[field] = p.druid[field] + v end end end
IE[25667] = DruidBonus("idolFerociousBite", 14) -- Idol of the Beast
IE[28064] = DruidBonus("idolMangleCat", 24)     -- Idol of the Wild
IE[28372] = DruidBonus("idolRip", 7)            -- Idol of Feral Shadows
IE[29390] = DruidBonus("idolShred", 88)         -- Everbloom Idol
IE[32387] = function() end                      -- Idol of the Raven Goddess (Leader of the Pack, above)
-- Wolfshead Helm: +20 energy when shifting into Cat Form
IE[8345] = function(p)
  if p.druid then p.druid.wolfsheadEnergy = p.druid.wolfsheadEnergy + 20 end
  S.MakePermanent(p:RegisterAura({ label = "Wolfshead Helm", actionId = { spellId = 17768 } }))
end
-- Idol of Terror: 85% on Mangle hits (10 s cooldown), 65 agility for 10 s.
IE[33509] = function(p)
  local buff = p:NewTemporaryStatsAura("Idol of Terror Proc", { [ST.Agility] = 65 }, 10)
  p:MakeProcTriggerAura({ name = "Idol of Terror", classMask = M.Mangle, callback = "hit", procChance = 0.85, icd = 10,
    handler = function(sim) buff:Activate(sim) end })
end
-- Idol of the White Stag: Mangle hits give 94 attack power for 20 s.
IE[32257] = function(p)
  local buff = p:NewTemporaryStatsAura("Idol of the White Stag Proc", { [ST.AttackPower] = 94 }, 20)
  p:MakeProcTriggerAura({ name = "Idol of the White Stag", classMask = M.Mangle, callback = "hit", procChance = 1,
    handler = function(sim) buff:Activate(sim) end })
end
-- Living Root of the Wildheart: 3% on direct hits, a buff for the form you are in.
IE[30664] = function(p)
  local dru = p.druid
  local buffs = {
    [HUMANOID] = p:NewTemporaryStatsAura("Living Root Humanoid Proc", { [ST.SpellDamage] = 175 }, 15),
    [BEAR] = p:NewTemporaryStatsAura("Living Root Bear Proc", { [ST.Armor] = 4070 }, 15),
    [CAT] = p:NewTemporaryStatsAura("Living Root Cat Proc", { [ST.Strength] = 64 }, 15),
  }
  if p.talents and p.talents.MoonkinForm > 0 then
    buffs[MOONKIN] = p:NewTemporaryStatsAura("Living Root Moonkin Proc", { [ST.SpellDamage] = 209 }, 15)
  end
  p:MakeProcTriggerAura({ name = "Living Root of the Wildheart", procMask = PM.Direct, callback = "hit", procChance = 0.03,
    handler = function(sim) local b = dru and buffs[dru.form]; if b then b:Activate(sim) end end })
end
-- Staff of Natural Fury: shapeshifts cost 200 less mana.
IE[31334] = function(p)
  p:AddStaticMod({ classMask = M.CatForm + M.BearForm, kind = "PowerCost_Flat", value = -200 })
end
-- Ashtongue Talisman of Equilibrium: Mangle 40% for 140 strength, Starfire 25% for 150 spell damage (8 s).
IE[32486] = function(p)
  local str = p:NewTemporaryStatsAura("Ashtongue Talisman of Equilibrium (Mangle)", { [ST.Strength] = 140 }, 8)
  local sd = p:NewTemporaryStatsAura("Ashtongue Talisman of Equilibrium (Starfire)", { [ST.SpellDamage] = 150 }, 8)
  p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Equilibrium", classMask = M.Mangle + M.Starfire, callback = "hit",
    handler = function(sim, spell)
      if spell:Matches(M.Mangle) and sim:Proc(0.4) then str:Activate(sim)
      elseif spell:Matches(M.Starfire) and sim:Proc(0.25) then sd:Activate(sim) end
    end })
end

-- Ivory Idol of the Moongoddess: Starfire +55 base damage; Idol of the Moon: Moonfire +33; Idol of the Avenger:
-- Wrath +25.
IE[27518] = function(p) p:AddStaticMod({ classMask = M.Starfire, kind = "BaseDamage_Flat", value = 55 }) end
IE[23197] = function(p) p:AddStaticMod({ classMask = M.Moonfire, kind = "BaseDamage_Flat", value = 33 }) end
IE[31025] = function(p) p:AddStaticMod({ classMask = M.Wrath, kind = "BaseDamage_Flat", value = 25 }) end

-- Malorne Regalia 2: 5% on a damage spell cast, 120 mana (4: Innervate's cooldown, not used here)
S.SetBonus("Malorne Regalia", {
  [2] = function(p, a)
    S.AttachProcTrigger(a, p, { name = "Malorne Regalia 2pc", callback = "cast", procMask = PM.SpellDamage,
      procChance = 0.05, handler = function(sim) p:AddMana(sim, 120, "malorne_regalia") end })
  end,
})
-- Nordrassil Regalia 4: Starfire +10% on a target with Moonfire or Insect Swarm (any of them fading ends it, as in
-- WoWSims)
S.SetBonus("Nordrassil Regalia", {
  [4] = function(p, a)
    p.postFinalize[#p.postFinalize + 1] = function()
      local target = p.currentTarget
      local at = p.attackTables[target]
      local dummy = target:RegisterAura({ label = "Item - Druid T5 Balance 2P Bonus", actionId = { spellId = 37327 },
        onGain = function() at.damageDoneByCaster = function(spell) return spell:Matches(M.Starfire) and 1.1 or 1 end end,
        onExpire = function() at.damageDoneByCaster = nil end })
      for _, sp in ipairs(p.spellbook) do
        if sp:Matches(M.InsectSwarm + M.Moonfire) and sp.dots then
          local d = sp:Dot(target)
          local og, oe = d.aura.onGain, d.aura.onExpire
          d.aura.onGain = function(au, sim) if og then og(au, sim) end if a.active then dummy:Activate(sim) end end
          d.aura.onExpire = function(au, sim) if oe then oe(au, sim) end dummy:Deactivate(sim) end
        end
      end
    end
  end,
})
-- Thunderheart Regalia 2: Moonfire one tick longer; 4: Starfire +5% crit
S.SetBonus("Thunderheart Regalia", {
  [2] = function(p, a) a:AttachSpellMod({ classMask = M.Moonfire, kind = "DotNumberOfTicks_Flat", value = 1 }) end,
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.Starfire, kind = "BonusCrit_Percent", value = 5 }) end,
})
S.SetBonus("Moonglade Raiment", {
  [4] = function(p, a) a:AttachSpellMod({ classMask = M.CatForm + M.BearForm, kind = "PowerCost_Pct_Add", value = -0.25 }) end,
})
S.SetBonus("Malorne Harness", {
  [2] = function(p, a)
    S.AttachProcTrigger(a, p, { name = "Malorne Harness 2pc", callback = "hit", procMask = PM.Melee, outcome = O.Landed,
      procChance = 0.04,
      handler = function(sim) if p.druid and InForm(p.druid, CAT) then p:AddEnergy(sim, 20, "malorne_harness") end end })
  end,
  [4] = function(p)
    if p.druid and p.druid.catFormAura then p.druid.catFormAura:AttachStatsBuff({ [ST.Strength] = 30 }) end
  end,
})
S.SetBonus("Nordrassil Harness", {
  [4] = function(p) if p.druid then p.druid.shredFlatBonus = p.druid.shredFlatBonus + 75 end end,
})
S.SetBonus("Thunderheart Harness", {
  [2] = function(p, a)
    a.actionId = { spellId = 38447 }
    p.aurasByKey = p.aurasByKey or {}
    p.aurasByKey["s38447:0"] = p.aurasByKey["s38447:0"] or a
    a:AttachSpellMod({ classMask = M.MangleCat, kind = "PowerCost_Flat", value = -5 })
  end,
  [4] = function(p, a)
    a:AttachSpellMod({ classMask = M.Rip + M.Swipe + M.FerociousBite, kind = "DamageDone_Flat", value = 0.15 })
  end,
})

-- ---------------------------------------------------------------------------------------------------------------
-- Balance (balance.go, forms.go Moonkin, starfire.go, wrath.go, moonfire.go, insect_swarm.go, faerie_fire.go,
-- force_of_nature.go, talents.go Nature's Grace). Hurricane (4+ targets) and Innervate (off in WoWSims' list) aren't
-- here: the sim fights one target.
-- ---------------------------------------------------------------------------------------------------------------
-- forms.go RegisterMoonkinFormAura / Spell
function S.DruidRegisterMoonkinForm(p)
  local dru = p.druid
  local a = p:RegisterAura({ label = "Moonkin Form", actionId = { spellId = 24858 },
    onGain = function(_, sim)
      if dru.form ~= MOONKIN then ClearForm(p, sim) end
      dru.form = MOONKIN
    end,
    onExpire = function() dru.form = HUMANOID end })
  dru.moonkinFormAura = a
  FormSpell(p, ANY, { id = 24858, flags = F.NoOnCastComplete + F.APL, manaCost = { basePct = 9.3 }, gcd = 1.5,
    ignoreHaste = true, applyEffects = function(sim) a:Activate(sim) end })
  return a
end

-- druid.go AddPartyBuffs: in Moonkin Form the druid brings Moonkin Aura (improved with Idol of the Raven Goddess).
function S.DruidMoonkinPartyBuffs(p, cfg)
  if not (p.talents.MoonkinForm > 0) then return cfg end
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local party = {}
  for k, v in pairs(cfg.party or {}) do party[k] = v end
  local want = (p.gearIds.Ranged == 32387) and 2 or 1
  local have = party.moonkinAura == true and 1 or (party.moonkinAura or 0)
  if have < want then party.moonkinAura = want end
  out.party = party
  return out
end

-- talents.go applyNaturesGrace: a Wrath / Starfire crit takes 0.5 s off the next Wrath / Starfire cast (15 s). A
-- cast that started before the proc doesn't use it up.
function S.DruidNaturesGrace(p)
  local lastProcAt = -1
  local a = p:RegisterAura({ label = "Nature's Grace", actionId = { spellId = 16886 }, duration = 15,
    onReset = function() lastProcAt = -1 end,
    onCastComplete = function(aura, sim, spell)
      local ct = spell.curCastTime or 0
      if ct == 0 then return end
      if sim.now - aura.startTime < ct - S.TIME_EPS then return end
      if lastProcAt > sim.now - ct + S.TIME_EPS then return end
      aura:Deactivate(sim)
    end })
  a:AttachSpellMod({ classMask = M.Starfire + M.Wrath, kind = "CastTime_Flat", value = -0.5 })
  p:MakeProcTriggerAura({ name = "Nature's Grace Trigger", callback = "hit", classMask = M.Wrath + M.Starfire,
    outcome = O.Crit, triggerImmediately = true,
    handler = function(sim)
      lastProcAt = sim.now
      a:Activate(sim)
    end })
end

local function BalanceSpell(cfg)
  cfg.defenseType = S.DEF_MAGIC
  cfg.procMask = cfg.procMask or PM.SpellDamage
  cfg.flags = (cfg.flags or 0) + F.APL
  cfg.damageMultiplier = 1
  cfg.threatMultiplier = 1
  cfg.gcd = cfg.gcd or 1.5
  return cfg
end

-- force_of_nature.go: three treants (guardians) for 30 s; warrior base stats, 15% of the druid's nature spell
-- damage as attack power, staggered first swings, in front of the boss for their first 1.5 s.
local function ForceOfNature(p)
  local dru = p.druid
  local treants = {}
  for idx = 0, 2 do
    local base = { Health = 4264, Agility = 96, Strength = 145, Intellect = 33, Spirit = 51, Stamina = 133,
      AttackPower = 190, PhysicalCritPercent = 5 }
    local pet = S.NewPet(p, { name = "Treant", key = "treant", baseStats = base,
      mainHand = { baseMin = 220.5, baseMax = 312.375, swingSpeed = 1.75, normalizedSpeed = 1.75, apPerDps = 14 },
      inherit = function(o)
        return { [ST.Stamina] = o[ST.Stamina], [ST.AttackPower] = (o[ST.SpellDamage] + o[ST.NatureDamage]) * 0.15 }
      end,
      rotation = function() end })
    pet:AddStatDependency(ST.Strength, ST.AttackPower, 2)
    pet:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Warrior)
    pet.onEnable = function(sim, u)
      u.autoAttacks:StopMeleeUntil(sim, sim.now - 0.5 * idx)
      u.ps.InFrontOfTarget = true
      sim:Add({ at = sim.now + 1.5, prio = 0, fn = function() u.ps.InFrontOfTarget = false end })
    end
    treants[#treants + 1] = pet
  end
  dru.treants = treants
  local a = p:RegisterAura({ label = "Force of Nature", actionId = { spellId = 33831 }, duration = 30 })
  local spell = FormSpell(p, HUMANOID + MOONKIN, { id = 33831, classMask = M.ForceOfNature, flags = F.APL,
    manaCost = { basePct = 0.12 }, gcd = 1.5, cd = 180,
    applyEffects = function(sim)
      for _, t in ipairs(treants) do t:EnablePetWithTimeout(sim, 30) end
      a:Activate(sim)
    end })
  p:AddMajorCooldown({ spell = spell })
end

function S.DruidRegisterBalanceSpells(p)
  local dru, T = p.druid, p.talents
  local SPELLS = HUMANOID + MOONKIN
  -- Starfire ranks 6 and 8 (the list downranks when mana runs low)
  for _, r in ipairs({ { 9876, 315, 463, 543 }, { 26986, 370, 550, 647 } }) do
    local lo, hi = r[3], r[4]
    FormSpell(p, SPELLS, BalanceSpell({ id = r[1], school = SCHOOL.Arcane, classMask = M.Starfire,
      manaCost = { flat = r[2] }, castTime = 3.5, bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        spell:CalcAndDealDamage(sim, target, sim:Roll(lo, hi), OUT.MagicHitAndCrit)
      end }))
  end
  -- Wrath (rank 10): travels at 20 yards a second
  FormSpell(p, SPELLS, BalanceSpell({ id = 26985, school = SCHOOL.Nature, classMask = M.Wrath, manaCost = { flat = 255 },
    castTime = 2, bonusCoefficient = 0.57099997997283936,
    applyEffects = function(sim, target, spell)
      local r = spell:CalcDamage(sim, target, sim:Roll(383, 432), OUT.MagicHitAndCrit)
      S.Travel(p, sim, 20, function(s) spell:DealDamage(s, r) end)
    end }))
  -- Moonfire (rank 12): the hit, then its DoT (its own spell, 4 ticks over 12 s)
  local dot = p:RegisterSpell({ id = 26988, tag = 1, school = SCHOOL.Arcane, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.MoonfireDoT, flags = F.PassiveSpell, damageMultiplier = 1,
    threatMultiplier = 1,
    dot = S.TickDot("Moonfire", 4, 3, 150, 0.12999999523162842),
    applyEffects = function(sim, target, spell)
      local r = spell:CalcOutcome(sim, target, OUT.AlwaysHitNoHitCounter)
      spell:Dot(target):Apply(sim)
      spell:DealDamage(sim, r)
    end })
  local mf = FormSpell(p, SPELLS, BalanceSpell({ id = 26988, school = SCHOOL.Arcane, classMask = M.Moonfire,
    manaCost = { flat = 495 }, bonusCoefficient = 0.15000000596046448,
    applyEffects = function(sim, target, spell)
      local r = spell:CalcDamage(sim, target, sim:Roll(305, 357), OUT.MagicHitAndCrit)
      if S.Landed(r) then dot:Cast(sim, target) end
      spell:DealDamage(sim, r)
    end }))
  mf.relatedDotSpell = dot
  -- Insect Swarm (talent, rank 6): 6 ticks over 12 s
  if T.InsectSwarm > 0 then
    FormSpell(p, SPELLS, BalanceSpell({ id = 27013, school = SCHOOL.Nature, classMask = M.InsectSwarm,
      flags = F.Binary, manaCost = { flat = 175 },
      dot = S.TickDot("Insect Swarm", 6, 2, 132, 0.12700000405311584),
      applyEffects = function(sim, target, spell)
        local r = spell:CalcOutcome(sim, target, OUT.MagicHit)
        if S.Landed(r) then spell:Dot(target):Apply(sim) end
        spell:DealDamage(sim, r)
      end }))
  end
  -- Faerie Fire (rank 5); its debuff exists from the start, so the rotation can read it
  S.FaerieFireAura(p.currentTarget, T.ImprovedFaerieFire)
  FormSpell(p, SPELLS, BalanceSpell({ id = 26993, school = SCHOOL.Nature, classMask = M.FaerieFire,
    manaCost = { flat = 145 },
    applyEffects = function(sim, target, spell)
      local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHit)
      if S.Landed(r) then S.FaerieFireAura(target, T.ImprovedFaerieFire):Activate(sim) end
    end }))
  if T.ForceOfNature > 0 then ForceOfNature(p) end
end

-- Scenario hooks: Setup.lua S.NewScenario runs them in WoWSims' build order
S.RegisterClass("Druid", {
  setup = function(p, talents, opts, consumables, buffs)
    S.SetupDruid(p, talents, opts)
    if p.druid.cat then buffs = S.DruidCatPartyBuffs(p, buffs) end
    if p.druid.moonkin then buffs = S.DruidMoonkinPartyBuffs(p, buffs) end
    return buffs
  end,
  applyTalents = function(p) S.DruidApplyTalents(p) end,
  initialize = function(p) S.DruidInitialize(p) end,
})

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Warlock.lua", ...) then return end -- DisasterZone: Sim/Warlock.lua
-- ns.GearSim Warlock (sim/warlock/*.go): Shadow Bolt, Incinerate, Immolate, Corruption, Unstable Affliction, Siphon
-- Life, the curses (Agony, Doom, Elements, Recklessness: one assigned, the raid's copy of it dropped), Life Tap, Death
-- Coil, Shadowburn, Conflagrate, Soul Fire, Searing Pain, Shadowfury, Fel / Demon Armor, the demon (Imp or Succubus,
-- a pet of its own: Sim/Pet.lua) or its sacrifice, the talents of all three trees, tier sets 4-6, the Black Book and
-- the Ashtongue Talisman.
--
-- Not here (as in WoWSims or no use to the sim): Seed of Corruption, Hellfire and Rain of Fire (one target), Drain
-- Life / Drain Soul (no list casts them), healing (Soul Leech, Siphon Life, Fel Armor, tier 5 / 6 two-pieces), the
-- Felhunter, Voidwalker and Felguard.
--
-- WoWSims quirks kept on purpose: Empowered Corruption counts only with Improved Corruption, Conflagrate has no
-- cooldown (its cooldown has no timer), Soul Fire's Bane cut is 400 ns a point on top of the 0.4 s spell mod, Shadow
-- Trance is up at the pull (a free instant Shadow Bolt each fight), WoWSims' Affliction talents leave out Unstable
-- Affliction.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min = math.huge, math.max, math.min

-- proto WarlockTalents order (talents string = Wowhead's)
local TALENTS = {
  { "Suppression", "ImprovedCorruption", "ImprovedCurseOfWeakness", "ImprovedDrainSoul", "ImprovedLifeTap", "SoulSiphon",
    "ImprovedCurseOfAgony", "FelConcentration", "AmplifyCurse", "GrimReach", "Nightfall", "EmpoweredCorruption",
    "ShadowEmbrace", "SiphonLife", "CurseOfExhaustion", "ShadowMastery", "Contagion", "DarkPact",
    "ImprovedHowlOfTerror", "Malediction", "UnstableAffliction" },
  { "ImprovedHealthstone", "ImprovedImp", "DemonicEmbrace", "ImprovedHealthFunnel", "ImprovedVoidwalker",
    "FelIntellect", "ImprovedSayaad", "FelDomination", "FelStamina", "DemonicAegis", "MasterSummoner", "UnholyPower",
    "ImprovedSubjugateDemon", "DemonicSacrifice", "MasterConjuror", "ManaFeed", "MasterDemonologist",
    "DemonicResilience", "SoulLink", "DemonicKnowledge", "DemonicTactics", "SummonFelguard" },
  { "ImprovedShadowBolt", "Cataclysm", "Bane", "Aftermath", "ImprovedFirebolt", "ImprovedLashOfPain", "Devastation",
    "Shadowburn", "Intensity", "DestructiveReach", "ImprovedSearingPain", "Pyroclasm", "ImprovedImmolate", "Ruin",
    "NetherProtection", "Emberstorm", "Backlash", "Conflagrate", "SoulLeech", "ShadowAndFlame", "Shadowfury" },
}
S.WARLOCK_TALENTS = TALENTS

-- Class spell masks (warlock.go)
local M
do
  M = S.SpellMasks({
    "Conflagrate", "ShadowBolt", "Immolate", "ImmolateDot", "Incinerate", "SoulFire", "ShadowBurn",
    "LifeTap", "Corruption", "UnstableAffliction", "CurseOfAgony", "CurseOfElements", "DrainLife", "SeedOfCorruption",
    "SeedOfCorruptionExplosion", "Hellfire", "ImmolationAura", "SearingPain", "SummonDoomguard", "DoomguardDoomBolt",
    "SummonFelguard", "SummonImp", "ImpFireBolt", "SummonFelhunter", "FelHunterShadowBite", "SummonSuccubus",
    "SuccubusLashOfPain", "VoidwalkerTorment", "SummonInfernal", "RainOfFire", "CurseOfDoom", "CurseOfRecklessness",
    "CurseOfWeakness", "SiphonLife", "DrainSoul", "ShadowFury", "DeathCoil", "FelguardCleave" })
  M.ShadowDamage = M.Corruption + M.UnstableAffliction + M.DrainLife + M.CurseOfAgony + M.ShadowBolt
    + M.SeedOfCorruptionExplosion + M.SeedOfCorruption + M.ShadowBurn + M.SiphonLife + M.ShadowFury + M.DeathCoil
  M.FireDamage = M.Conflagrate + M.Immolate + M.Incinerate + M.SoulFire + M.SearingPain + M.ImmolateDot + M.ShadowBurn
  M.Contagion = M.CurseOfAgony + M.Corruption + M.SeedOfCorruption + M.SeedOfCorruptionExplosion
  M.Affliction = M.Corruption + M.CurseOfAgony + M.CurseOfDoom + M.CurseOfRecklessness + M.CurseOfElements
    + M.DrainLife + M.SeedOfCorruption + M.DeathCoil
  M.Destruction = M.Hellfire + M.Immolate + M.Incinerate + M.RainOfFire + M.SearingPain + M.ShadowBolt + M.SoulFire
    + M.Conflagrate + M.ShadowFury + M.ShadowBurn
end
S.WARLOCK_MASK = M

-- float32 coefficients as Go reads them (spell_data_auto_gen.go)
local C = {
  Corruption = 0.15600000321865082, Agony = 0.10000000149011612, Immolate = 0.20000000298023224,
  ImmolateDot = 0.12999999523162842, Incinerate = 0.71399998664855957, ShadowBolt = 0.85699999332427979,
  Shadowburn = 0.42899999022483826, Conflagrate = 0.42899999022483826, Soulfire = 1.1499999761581421,
  SearingPain = 0.42899999022483826, SiphonLife = 0.10000000149011612, UA = 0.20000000298023224,
  Shadowfury = 0.19300000369548798,
}

OUT.MagicHitNoHitCounter = OUT.MagicHitNoHitCounter or OUT.MagicHit

local function WarlockSpell(cfg)
  cfg.defenseType = S.DEF_MAGIC
  cfg.procMask = cfg.procMask or PM.SpellDamage
  cfg.flags = (cfg.flags or 0) + F.APL
  cfg.threatMultiplier = 1
  cfg.gcd = cfg.gcd or 1.5
  -- spell.go: whichever multiplier is left out defaults to 1
  cfg.damageMultiplier = cfg.damageMultiplier or 1
  cfg.damageMultiplierAdditive = cfg.damageMultiplierAdditive or 1
  return cfg
end

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (warlock.go NewWarlock)
-- opts: { armor = "FelArmor" | "DemonArmor" | "NoArmor", curse = "Agony" | "Doom" | "Elements" | "Recklessness",
--   summon = "Imp" | "Succubus" | "NoSummon", sacrificeSummon }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupWarlock(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local wl = { opts = opts, talents = T, curse = opts.curse or "Agony", summon = opts.summon or "NoSummon",
    sacrifice = opts.sacrificeSummon == true }
  p.warlock = wl
  p:AddStatDependency(ST.Strength, ST.AttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Warlock)
  p.autoAttacks.autoSwingMelee = false
  if not wl.sacrifice then
    if wl.summon == "Imp" then wl.pet = S.WarlockImp(p)
    elseif wl.summon == "Succubus" then wl.pet = S.WarlockSuccubus(p) end
  end
  return wl
end

-- warlock.go NewWarlock: the raid's copy of the assigned curse goes (the warlock casts his own).
function S.WarlockRaidBuffs(p, cfg)
  local wl = p.warlock
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local d = {}
  for k, v in pairs(cfg.debuffs or {}) do d[k] = v end
  if wl.curse == "Elements" then d.curseOfElements = nil end
  if wl.curse == "Recklessness" then d.curseOfRecklessness = nil end
  out.debuffs = d
  wl.raidDebuffs = d
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Demons (pets.go): base stats of their own, 30% of the warlock's stamina and intellect, 15% of his better school's
-- spell damage as spell damage and 57% as attack power; they cast on their own when they have more mana than the
-- spell's floor, else look again 100 ms later.
-- ---------------------------------------------------------------------------------------------------------------
local function DemonInherit(o)
  local best = max(o[ST.ShadowDamage], o[ST.FireDamage])
  return { [ST.Stamina] = o[ST.Stamina] * 0.3, [ST.Intellect] = o[ST.Intellect] * 0.3, [ST.Armor] = o[ST.Armor] * 0.35,
    [ST.SpellPenetration] = o[ST.SpellPenetration], [ST.SpellDamage] = best * 0.15, [ST.AttackPower] = best * 0.57,
    [ST.ArcaneResistance] = o[ST.ArcaneResistance] * 0.4, [ST.FireResistance] = o[ST.FireResistance] * 0.4,
    [ST.FrostResistance] = o[ST.FrostResistance] * 0.4, [ST.NatureResistance] = o[ST.NatureResistance] * 0.4,
    [ST.ShadowResistance] = o[ST.ShadowResistance] * 0.4 }
end

local function DemonRotation(sim, u)
  for _, sp in ipairs(u.autoCast) do
    if sp:CanCast(sim, u.currentTarget) and u.mana > u.minMana then
      sp:Cast(sim, u.currentTarget)
      return
    end
  end
  u:WaitUntil(sim, sim.now + 0.1)
end

local function NewDemon(p, name, key, base, mainHand, minMana)
  local wl = p.warlock
  local pet = S.NewPet(p, { name = name, key = key, baseStats = base, guardian = false, enabledOnStart = true,
    mana = true, mainHand = mainHand, inherit = DemonInherit, rotation = DemonRotation })
  pet:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Paladin)
  pet:AddStatDependency(ST.Intellect, ST.SpellCritPercent, S.CRIT_PER_INT.Paladin)
  pet:AddStatDependency(ST.Intellect, ST.Mana, 15)
  pet.autoCast = {}
  pet.minMana = minMana
  -- pets.go makePet OnPetEnable: Demonic Knowledge and Master Demonologist come with the demon
  pet.onEnable = function(sim)
    local T = p.talents
    if T.DemonicKnowledge > 0 then
      wl.demonicKnowledgeAura:Activate(sim)
      S.WarlockUpdateDemonicKnowledge(p, sim)
    end
    if T.MasterDemonologist > 0 and wl.masterDemonologistAura then
      local a = wl.masterDemonologistAura
      if a.active then a:Deactivate(sim) end
      a:Activate(sim)
    end
  end
  -- OnPetDisable (at the end of every fight): the bonus is worked out again from what the demon has left (no buffs,
  -- nothing from the warlock) and, never reset, taken off at the next summon: from the second fight on Demonic
  -- Knowledge only counts the demon's buffed and inherited stamina and intellect (as in WoWSims)
  pet.onDisable = function(sim)
    if p.talents.DemonicKnowledge > 0 then
      S.WarlockUpdateDemonicKnowledge(p, sim, true)
      wl.demonicKnowledgeAura:Deactivate(sim)
    end
  end
  return pet
end

function S.WarlockImp(p)
  local pet = NewDemon(p, "Imp", "imp", { Mana = 2988, Stamina = 101, Strength = 153, Agility = 108, Intellect = 327,
    Spirit = 263, AttackPower = 135, MP5 = 123, PhysicalCritPercent = 5, SpellCritPercent = 5 }, nil, 145)
  pet.autoCast[1] = pet:RegisterSpell({ id = 27267, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.ImpFireBolt, manaCost = { flat = 145 }, gcd = 1, gcdMin = 1, castTime = 2,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 0.571,
    applyEffects = function(sim, target, spell)
      local r = spell:CalcDamage(sim, target, sim:Roll(112, 127), OUT.MagicHitAndCrit)
      S.Travel(pet, sim, 16, function(s) spell:DealDamage(s, r) end)
    end })
  pet.distance = p.distance
  return pet
end

function S.WarlockSuccubus(p)
  local pet = NewDemon(p, "Succubus", "succubus", { Mana = 3862, Stamina = 280, Strength = 154, Agility = 108,
    Intellect = 133, Spirit = 122, AttackPower = 286, MP5 = 48, PhysicalCritPercent = 5, SpellCritPercent = 5 },
    { baseMin = 173, baseMax = 216, swingSpeed = 2, normalizedSpeed = 2, apPerDps = 14 }, 190)
  pet.autoCast[1] = pet:RegisterSpell({ id = 27274, school = SCHOOL.Shadow, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.SuccubusLashOfPain, manaCost = { flat = 190 }, gcd = 1.5,
    ignoreHaste = true, cd = 12, damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
    bonusCoefficient = 0.429,
    applyEffects = function(sim, target, spell)
      spell:CalcAndDealDamage(sim, target, 123, OUT.MagicHitAndCrit)
    end })
  return pet
end

-- talents.go updateDemonicKnowledge: spell damage from the demon's stamina and intellect while it is out
function S.WarlockUpdateDemonicKnowledge(p, sim, unbuffed)
  local wl = p.warlock
  if (wl.demonicKnowledgeBonus or 0) ~= 0 then p:AddStatDynamic(sim, ST.SpellDamage, -wl.demonicKnowledgeBonus) end
  local pet = wl.pet
  if not pet then
    wl.demonicKnowledgeBonus = 0
    return
  end
  local s = unbuffed and pet:StatsWithoutBuffs() or pet.stats
  local bonus = 0.04 * p.talents.DemonicKnowledge * (s[ST.Stamina] + s[ST.Intellect])
  wl.demonicKnowledgeBonus = bonus
  p:AddStatDynamic(sim, ST.SpellDamage, bonus)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.WarlockApplyTalents(p)
  local wl, T = p.warlock, p.talents
  local target = p.currentTarget
  local pet = wl.pet

  -- Affliction
  if T.Suppression > 0 then p:AddStaticMod({ kind = "BonusHit_Percent", value = 2 * T.Suppression, classMask = M.Affliction }) end
  if T.ImprovedCorruption > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.4 * T.ImprovedCorruption, classMask = M.Corruption })
  end
  if T.AmplifyCurse > 0 then
    local a = p:RegisterAura({ label = "Amplify Curse", actionId = { spellId = 18288 }, duration = 30,
      onCastComplete = function(aura, sim, spell)
        if has(spell.classMask or 0, M.CurseOfAgony + M.CurseOfDoom) then aura:Deactivate(sim) end
      end })
    wl.amplifyCurseAura = a
    local sp = p:RegisterSpell({ id = 18288, procMask = PM.Empty, flags = F.APL, gcd = 1, cd = 180,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = sp })
  end
  if T.ImprovedCurseOfAgony > 0 then
    p:AddStaticMod({ kind = "DotDamageDone_Pct", value = 0.05 * T.ImprovedCurseOfAgony, classMask = M.CurseOfAgony })
  end
  if T.Nightfall > 0 then
    -- Shadow Trance: the next Shadow Bolt is instant (used up by an instant Shadow Bolt)
    local trance
    trance = p:MakeProcTriggerAura({ name = "Shadow Trance", classMask = M.ShadowBolt, callback = "cast",
      handler = function(sim, spell)
        if (spell.curCastTime or 0) ~= 0 then return end
        trance:Deactivate(sim)
      end })
    trance:AttachSpellMod({ kind = "CastTime_Pct", value = -1, classMask = M.ShadowBolt })
    wl.shadowTrance = trance
    p:MakeProcTriggerAura({ name = "Nightfall", classMask = M.Corruption + M.DrainLife, procChance = 0.02 * T.Nightfall,
      callback = "periodic", handler = function(sim) trance:Activate(sim) end })
  end
  -- talents.go applyEmpoweredCorruption checks Improved Corruption's points
  if T.ImprovedCorruption > 0 and T.EmpoweredCorruption > 0 then
    p:AddStaticMod({ kind = "DotBonusCoefficient_Flat", value = 0.02 * T.EmpoweredCorruption, classMask = M.Corruption })
  end
  if T.ShadowMastery > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.02 * T.ShadowMastery, classMask = M.ShadowDamage })
  end
  if T.Contagion > 0 then p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.01 * T.Contagion, classMask = M.Contagion }) end
  if T.UnstableAffliction > 0 then S.WarlockUnstableAffliction(p) end

  -- Demonology (the demon's talents only with a demon out)
  if T.ImprovedImp > 0 and pet and wl.summon == "Imp" then
    pet:AddStaticMod({ kind = "DamageDone_Flat", value = 0.1 * T.ImprovedImp, classMask = M.ImpFireBolt })
  end
  if T.DemonicEmbrace > 0 then
    p:MultiplyStat(ST.Stamina, 1 + 0.03 * T.DemonicEmbrace)
    p:MultiplyStat(ST.Spirit, 1 - 0.01 * T.DemonicEmbrace)
  end
  if T.FelIntellect > 0 then
    p:MultiplyStat(ST.Mana, 1 + 0.01 * T.FelIntellect)
    if pet then pet:MultiplyStat(ST.Mana, 1 + 0.05 * T.FelIntellect) end
  end
  if T.FelStamina > 0 then
    p:MultiplyStat(ST.Health, 1 + 0.01 * T.FelStamina)
    if pet then pet:MultiplyStat(ST.Health, 1 + 0.05 * T.FelStamina) end
  end
  if T.ImprovedSayaad > 0 and pet and wl.summon == "Succubus" then
    pet:AddStaticMod({ kind = "DamageDone_Flat", value = 0.1 * T.ImprovedSayaad, classMask = M.SuccubusLashOfPain })
  end
  if T.UnholyPower > 0 and pet then
    if wl.summon == "Imp" then
      pet:AddStaticMod({ kind = "DamageDone_Flat", value = 0.04 * T.UnholyPower, classMask = M.ImpFireBolt })
    else
      local i = S.SCHOOL_INDEX[SCHOOL.Physical]
      pet.ps.SchoolDamageDealtMultiplier[i] = pet.ps.SchoolDamageDealtMultiplier[i] * (1 + 0.04 * T.UnholyPower)
    end
  end
  if T.DemonicSacrifice > 0 and wl.sacrifice then
    local function school(s, m)
      local i = S.SCHOOL_INDEX[s]
      p.ps.SchoolDamageDealtMultiplier[i] = p.ps.SchoolDamageDealtMultiplier[i] * m
    end
    if wl.summon == "Succubus" then school(SCHOOL.Shadow, 1.15)
    elseif wl.summon == "Imp" then school(SCHOOL.Fire, 1.15) end
  end
  if T.MasterDemonologist > 0 and pet and wl.summon == "Succubus" then
    -- the warlock's share while the Succubus is out (an aura), the Succubus' own for good
    local m = 1 + 0.02 * T.MasterDemonologist
    local a = p:RegisterAura({ label = "Master Demonologist", actionId = { spellId = 23832 + T.MasterDemonologist },
      duration = huge })
    a:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", m)
    wl.masterDemonologistAura = a
    pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * m
  elseif T.MasterDemonologist > 0 and pet then
    -- the Imp's: threat only
    wl.masterDemonologistAura = p:RegisterAura({ label = "Master Demonologist",
      actionId = { spellId = 23825 + T.MasterDemonologist }, duration = huge })
  end
  if T.SoulLink > 0 then
    p.ps.DamageDealtMultiplier = p.ps.DamageDealtMultiplier * 1.05
    if pet then pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * 1.05 end
  end
  if T.DemonicKnowledge > 0 then
    wl.demonicKnowledgeAura = p:RegisterAura({ label = "Demonic Knowledge", duration = huge })
  end
  if T.DemonicTactics > 0 then
    for _, u in ipairs({ p, pet }) do
      u:AddStat(ST.SpellCritPercent, T.DemonicTactics)
      u:AddStat(ST.PhysicalCritPercent, T.DemonicTactics)
      u:AddStat(ST.RangedCritPercent, T.DemonicTactics)
    end
  end

  -- Destruction
  if T.ImprovedShadowBolt > 0 then
    -- the raid's Improved Shadow Bolt comes first (debuffs before talents in WoWSims); at 5 points it is the same
    -- aura, kept up by the raid and refreshed by the warlock's crits
    local raid = wl.raidDebuffs and wl.raidDebuffs.isbUptime or 0
    if raid > 0 then S.ImprovedShadowBoltAura(target, raid, 5) end
    wl.isbAura = S.ImprovedShadowBoltAura(target, 0, T.ImprovedShadowBolt)
  end
  if T.Cataclysm > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.01 * T.Cataclysm, classMask = M.Destruction })
  end
  if T.Bane > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.1 * T.Bane, classMask = M.ShadowBolt + M.Immolate })
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.4 * T.Bane, classMask = M.SoulFire })
  end
  if T.ImprovedFirebolt > 0 and pet and wl.summon == "Imp" then
    pet:AddStaticMod({ kind = "CastTime_Flat", value = -0.25 * T.ImprovedFirebolt, classMask = M.ImpFireBolt })
  end
  if T.ImprovedLashOfPain > 0 and pet and wl.summon == "Succubus" then
    pet:AddStaticMod({ kind = "Cooldown_Flat", value = -3 * T.ImprovedLashOfPain, classMask = M.SuccubusLashOfPain })
  end
  if T.Devastation > 0 then p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.Devastation, classMask = M.Destruction }) end
  if T.Shadowburn > 0 then S.WarlockShadowburn(p) end
  if T.ImprovedSearingPain > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = ({ 4, 7, 10 })[min(T.ImprovedSearingPain, 3)],
      classMask = M.SearingPain })
  end
  if T.ImprovedImmolate > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.05 * T.ImprovedImmolate, classMask = M.Immolate })
  end
  if T.Ruin > 0 then p:AddStaticMod({ kind = "CritMultiplier_Flat", value = 1, classMask = M.Destruction }) end
  if T.Emberstorm > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.02 * T.Emberstorm, classMask = M.FireDamage })
    p:AddStaticMod({ kind = "CastTime_Pct", value = -0.02 * T.Emberstorm, classMask = M.Incinerate })
  end
  if T.Backlash > 0 then p:AddStat(ST.SpellCritPercent, T.Backlash) end
  if T.Conflagrate > 0 then S.WarlockConflagrate(p) end
  if T.ShadowAndFlame > 0 then
    p:AddStaticMod({ kind = "BonusCoefficient_Flat", value = 0.04 * T.ShadowAndFlame, classMask = M.ShadowBolt + M.Incinerate })
  end
  if T.Shadowfury > 0 then S.WarlockShadowfury(p) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spells
-- ---------------------------------------------------------------------------------------------------------------
-- warlock.go DeactivateOtherCurses: a new curse ends the one before it
local function SwitchCurse(p, sim, spell, target)
  local wl = p.warlock
  local cur = wl.currentCurse
  if cur then
    if cur.dots or cur.relatedDotSpell then cur:Dot(target):Deactivate(sim) end
    if cur.curseAura then cur.curseAura:Deactivate(sim) end
  end
  wl.currentCurse = spell
end

local function Curses(p)
  local wl, T = p.warlock, p.talents
  local target = p.currentTarget
  -- curse_of_elements.go: the warlock's own (Malediction adds 1% a point), 5 min
  local coe = p:RegisterSpell(WarlockSpell({ id = 27228, school = SCHOOL.Shadow, procMask = PM.Empty,
    classMask = M.CurseOfElements, manaCost = { flat = 260 },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then
        SwitchCurse(p, sim, spell, t)
        spell.curseAura:Activate(sim)
      end
      spell:DealDamage(sim, r)
    end }))
  do
    local m = 1.10 + 0.01 * T.Malediction
    local a = target:GetOrRegisterAura({ label = "Curse of the Elements (Self)", actionId = { spellId = 27228, tag = 1 },
      duration = 300 })
    for _, s in ipairs({ SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Shadow }) do
      a:AttachMultiplicativePseudoStatBuff("SchoolDamageTakenMultiplier", m, S.SCHOOL_INDEX[s])
    end
    a:AttachStatsBuff({ [ST.ArcaneResistance] = -88, [ST.FireResistance] = -88, [ST.FrostResistance] = -88,
      [ST.ShadowResistance] = -88 })
    coe.curseAura = a
  end
  -- curse_of_recklessness.go: armor -800, 2 min
  local cor = p:RegisterSpell(WarlockSpell({ id = 27226, school = SCHOOL.Shadow, procMask = PM.Empty,
    classMask = M.CurseOfRecklessness, manaCost = { flat = 160 },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then
        SwitchCurse(p, sim, spell, t)
        spell.curseAura:Activate(sim)
      end
      spell:DealDamage(sim, r)
    end }))
  do
    local a = target:GetOrRegisterAura({ label = "Curse of Recklessness (Self)", actionId = { spellId = 27226, tag = 1 },
      duration = 120 })
    a:AttachStatsBuff({ [ST.Armor] = -800, [ST.AttackPower] = 135 })
    cor.curseAura = a
  end
  local function amplified()
    local a = wl.amplifyCurseAura
    return (a and a.active) and 1.5 or 1
  end
  -- agony.go: 12 ticks of 113 over 24 s (Amplify Curse: +50% when it lands)
  local coa = p:RegisterSpell(WarlockSpell({ id = 27218, school = SCHOOL.Shadow, classMask = M.CurseOfAgony,
    manaCost = { flat = 265 }, bonusCoefficient = C.Agony,
    dot = { label = "Agony", numberOfTicks = 12, tickLength = 2, bonusCoefficient = C.Agony, periodicDamageMultiplier = 1,
      onSnapshot = function(sim, t, dot) dot:Snapshot(t, 113 * amplified()) end,
      onTick = function(sim, t, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then
        SwitchCurse(p, sim, spell, t)
        spell:Dot(t):Apply(sim)
      end
      spell:DealDamage(sim, r)
    end }))
  -- doom.go: one tick of 4200 after a minute
  local cod = p:RegisterSpell(WarlockSpell({ id = 30910, school = SCHOOL.Shadow, classMask = M.CurseOfDoom, cd = 60,
    bonusCoefficient = 2,
    dot = { label = "Doom", numberOfTicks = 1, tickLength = 60, bonusCoefficient = 2, periodicDamageMultiplier = 1,
      onSnapshot = function(sim, t, dot) dot:Snapshot(t, 4200 * amplified()) end,
      onTick = function(sim, t, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then
        SwitchCurse(p, sim, spell, t)
        spell:Dot(t):Apply(sim)
      end
      spell:DealDamage(sim, r)
    end }))
  wl.curses = { Agony = coa, Doom = cod, Elements = coe, Recklessness = cor }
  wl.assignedCurse = wl.curses[wl.curse]
end

function S.WarlockUnstableAffliction(p)
  p:RegisterSpell(WarlockSpell({ id = 30405, school = SCHOOL.Shadow, classMask = M.UnstableAffliction,
    manaCost = { flat = 400 }, castTime = 1.5, damageMultiplier = 1, bonusCoefficient = C.UA,
    dot = S.TickDot("Unstable Affliction", 6, 3, 175, C.UA),
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then spell:Dot(t):Apply(sim) end
    end }))
end

function S.WarlockShadowburn(p)
  p:RegisterSpell(WarlockSpell({ id = 30546, school = SCHOOL.Shadow, flags = F.Binary, classMask = M.ShadowBurn,
    manaCost = { flat = 515 }, cd = 15, bonusCoefficient = C.Shadowburn,
    applyEffects = function(sim, t, spell)
      spell:CalcAndDealDamage(sim, t, sim:Roll(597, 665), OUT.MagicHitAndCrit)
    end }))
end

function S.WarlockConflagrate(p)
  local wl = p.warlock
  -- conflagrate.go: its cooldown has no timer, so WoWSims never puts it on cooldown
  p:RegisterSpell(WarlockSpell({ id = 30912, school = SCHOOL.Fire, classMask = M.Conflagrate, manaCost = { flat = 305 },
    bonusCoefficient = C.Conflagrate,
    extraCastCondition = function(sim, t) return wl.immolate:Dot(t):IsActive() end,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealDamage(sim, t, sim:Roll(579, 721), OUT.MagicHitAndCrit)
      if S.Landed(r) then wl.immolate:Dot(t):Deactivate(sim) end
    end }))
end

function S.WarlockShadowfury(p)
  p:RegisterSpell(WarlockSpell({ id = 30414, school = SCHOOL.Shadow, classMask = M.ShadowFury, manaCost = { flat = 710 },
    gcd = 0.5, gcdMin = 0.5, castTime = 0.5, cd = 20, bonusCoefficient = C.Shadowfury,
    applyEffects = function(sim, t, spell)
      spell:CalcAndDealDamage(sim, t, sim:Roll(612, 728), OUT.MagicHitAndCrit)
    end }))
end

-- warlock.go Initialize: the curses, then the spells in WoWSims' order, then the armor
function S.WarlockInitialize(p)
  local wl, T = p.warlock, p.talents
  Curses(p)

  -- corruption.go: 6 ticks of 150 over 18 s
  wl.corruption = p:RegisterSpell(WarlockSpell({ id = 27216, school = SCHOOL.Shadow, classMask = M.Corruption,
    manaCost = { flat = 370 }, castTime = 2, bonusCoefficient = C.Corruption,
    dot = { label = "Corruption", numberOfTicks = 6, tickLength = 3, bonusCoefficient = C.Corruption,
      onSnapshot = function(sim, t, dot) dot:Snapshot(t, 150) end,
      onTick = function(sim, t, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then spell:Dot(t):Apply(sim) end
      spell:DealDamage(sim, r)
    end }))

  -- death_coil.go: 526, no crit (its travel time is only read by the rotation)
  p:RegisterSpell(WarlockSpell({ id = 27223, school = SCHOOL.Shadow, classMask = M.DeathCoil, manaCost = { flat = 600 },
    cd = 120, bonusCoefficient = 0.214, missileSpeed = 24,
    applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, 526, OUT.MagicHit) end }))

  -- immolate.go: the hit, then its DoT (its own spell, 5 ticks of 123 over 15 s)
  local immoDot = p:RegisterSpell({ id = 27215, tag = 1, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.ImmolateDot, flags = F.PassiveSpell, damageMultiplier = 1,
    damageMultiplierAdditive = 1,
    dot = { label = "Immolate (DoT)", numberOfTicks = 5, tickLength = 3, bonusCoefficient = C.ImmolateDot,
      onSnapshot = function(sim, t, dot) dot:Snapshot(t, 123) end,
      onTick = function(sim, t, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end } })
  wl.immolate = p:RegisterSpell(WarlockSpell({ id = 27215, school = SCHOOL.Fire, classMask = M.Immolate,
    manaCost = { flat = 445 }, castTime = 2, bonusCoefficient = C.Immolate,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(331, 332), OUT.MagicHitAndCrit)
      if S.Landed(r) then immoDot:Dot(t):Apply(sim) end
      spell:DealDamage(sim, r)
    end }))
  wl.immolate.relatedDotSpell = immoDot
  wl.immolateDot = immoDot

  -- incinerate.go: +111-128 with Immolate on the target
  p:RegisterSpell(WarlockSpell({ id = 32231, school = SCHOOL.Fire, classMask = M.Incinerate, manaCost = { flat = 355 },
    castTime = 2.5, bonusCoefficient = C.Incinerate, missileSpeed = 24,
    applyEffects = function(sim, t, spell)
      local base = sim:Roll(444, 514)
      if wl.immolate:Dot(t):IsActive() then base = base + sim:Roll(111, 128) end
      local r = spell:CalcDamage(sim, t, base, OUT.MagicHitAndCrit)
      S.Travel(p, sim, 24, function(s) spell:DealDamage(s, r) end)
    end }))

  -- lifetap.go: 582 health into mana (Improved Life Tap +10% a point) plus 80% of shadow spell damage; Mana Feed gives
  -- the demon a third of it a point
  local restoreBase = 582 * (1 + 0.1 * T.ImprovedLifeTap)
  p:RegisterSpell({ id = 27222, school = SCHOOL.Shadow, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
    flags = F.APL, classMask = M.LifeTap, gcd = 1.5, threatMultiplier = 1,
    applyEffects = function(sim, t, spell)
      local restore = restoreBase + spell:SpellDamage() * 0.8
      p:AddMana(sim, restore, "life_tap")
      local pet = wl.pet
      if T.ManaFeed > 0 and pet and pet.enabled then pet:AddMana(sim, restore * 0.3333 * T.ManaFeed, "life_tap") end
    end })

  -- shadowbolt.go: travels at 20 yards a second; a crit on landing puts up Improved Shadow Bolt (4 charges)
  p:RegisterSpell(WarlockSpell({ id = 27209, school = SCHOOL.Shadow, classMask = M.ShadowBolt, manaCost = { flat = 420 },
    castTime = 3, bonusCoefficient = C.ShadowBolt, missileSpeed = 20,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(544, 607), OUT.MagicHitAndCrit)
      local isb = wl.isbAura
      local existing = isb and t:GetAura("ImprovedShadowBolt-5") or isb
      S.Travel(p, sim, 20, function(s)
        spell:DealDamage(s, r)
        if isb and (not existing or existing.duration ~= huge) and S.Landed(r) and has(r.outcome, O.Crit) then
          if not isb.active then isb:Activate(s) end
          isb:SetStacks(s, 4)
        end
      end)
    end }))

  -- searing_pain.go
  p:RegisterSpell(WarlockSpell({ id = 30459, school = SCHOOL.Fire, classMask = M.SearingPain, manaCost = { flat = 205 },
    castTime = 1.5, bonusCoefficient = C.SearingPain,
    applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(270, 320), OUT.MagicHitAndCrit) end }))

  -- siphon_life.go: its cost is never paid (a base cost without a mana cost); 10 ticks of 63 over 30 s
  p:RegisterSpell(WarlockSpell({ id = 30911, school = SCHOOL.Shadow, classMask = M.SiphonLife, nonEmpty = true,
    bonusCoefficient = C.SiphonLife, dot = S.TickDot("SiphonLife", 10, 3, 63, C.SiphonLife),
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then spell:Dot(t):Apply(sim) end
      spell:DealDamage(sim, r)
    end }))

  -- soulfire.go: 6 s minus Bane (400 ns a point here, plus the talent's 0.4 s mod), travels at 24 yards a second
  p:RegisterSpell(WarlockSpell({ id = 30545, school = SCHOOL.Fire, classMask = M.SoulFire, manaCost = { flat = 250 },
    castTime = 6 - 400e-9 * T.Bane, cd = 60, bonusCoefficient = C.Soulfire, missileSpeed = 24,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(1003, 1257), OUT.MagicHitAndCrit)
      S.Travel(p, sim, 24, function(s) spell:DealDamage(s, r) end)
    end }))

  -- armors.go: Fel Armor +100 spell damage (Demonic Aegis +10% a point), for good
  local aegis = 1 + 0.1 * T.DemonicAegis
  local armor = wl.opts.armor or "FelArmor"
  if armor == "FelArmor" then
    local a = p:RegisterAura({ label = "Fel Armor", actionId = { spellId = 28176 }, duration = 1800 })
    a:AttachStatBuff(ST.SpellDamage, 100 * aegis)
    S.MakePermanent(a)
  elseif armor == "DemonArmor" then
    local a = p:RegisterAura({ label = "Demon Armor", actionId = { spellId = 27260 }, duration = 1800 })
    a:AttachStatsBuff({ [ST.Armor] = 660 * aegis, [ST.ShadowResistance] = 18 * aegis })
    S.MakePermanent(a)
  end

  S.WarlockItems(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items (items.go): tier sets 4-6, the dungeon set's demon mana, the Black Book and the Ashtongue Talisman
-- ---------------------------------------------------------------------------------------------------------------
function S.WarlockItems(p)
  local wl = p.warlock
  -- Oblivion Raiment 2: the demon gets 45 mana per 5 s
  if p:CouldHaveSetBonus("Oblivion Raiment", 2) and wl.pet then wl.pet:AddStat(ST.MP5, 45) end
  -- Voidheart Raiment 2: 5% on a damaging spell hit, +135 to that school's spell damage for 15 s; 4: Corruption and
  -- Immolate one tick longer (a set bonus aura: on from the pull, after the rotation read the DoT's base duration)
  if p:CouldHaveSetBonus("Voidheart Raiment", 2) then
    local shadow = p:NewTemporaryStatsAura("Flameshadow", { [ST.ShadowDamage] = 135 }, 15)
    local fire = p:NewTemporaryStatsAura("Shadowflame Hellfire and RoF", { [ST.FireDamage] = 135 }, 15)
    p:MakeProcTriggerAura({ name = "Voidheart Raiment 2pc", procChance = 0.05, callback = "hit", requireDamageDealt = true,
      handler = function(sim, spell)
        if has(spell.school or 0, SCHOOL.Shadow) then shadow:Activate(sim)
        elseif has(spell.school or 0, SCHOOL.Fire) then fire:Activate(sim) end
      end })
  end
  if p:CouldHaveSetBonus("Voidheart Raiment", 4) then
    local a = p:RegisterAura({ label = "Voidheart Raiment 4pc", actionId = { spellId = 37380 } })
    a:AttachSpellMod({ kind = "DotNumberOfTicks_Flat", value = 1, classMask = M.Corruption + M.ImmolateDot })
    S.MakePermanent(a)
  end
  -- Corruptor Raiment 4: each Shadow Bolt hit makes the running Corruption's base damage 10% bigger (Incinerate:
  -- Immolate's), compounding, back to normal when it is cast anew
  if p:CouldHaveSetBonus("Corruptor Raiment", 4) then
    local target = p.currentTarget
    local mult = {}
    for _, sp in ipairs({ wl.corruption, wl.immolateDot }) do
      local d = sp:Dot(target)
      local og = d.aura.onGain
      d.aura.onGain = function(a, sim)
        mult[sp] = 1
        if og then og(a, sim) end
      end
    end
    p:MakeProcTriggerAura({ name = "Corruptor Raiment 4pc - Improved Corruption and Immolate", outcome = O.Landed,
      classMask = M.ShadowBolt + M.Incinerate, callback = "hit",
      handler = function(sim, spell, result)
        local isSB = has(spell.classMask, M.ShadowBolt)
        local sp = isSB and wl.corruption or wl.immolateDot
        local base = isSB and 150 or 123
        local d = sp:Dot(result.target)
        if d and d:IsActive() then
          local cur = base * (mult[sp] or 0)
          local bonus = d.snapshotBaseDamage - cur
          mult[sp] = (mult[sp] or 0) * 1.10
          d.snapshotBaseDamage = base * mult[sp] + bonus
        end
      end })
  end
  -- Malefic Raiment 4: Shadow Bolt and Incinerate +6%
  if p:CouldHaveSetBonus("Malefic Raiment", 4) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.06, classMask = M.ShadowBolt + M.Incinerate })
  end
  -- The Black Book: the demon +200 spell damage, +325 attack power for 30 s
  if p:IsEquipped(19337) and wl.pet then
    local pet = wl.pet
    local petAura = pet:NewTemporaryStatsAura("Blessing of The Black Book",
      { [ST.SpellDamage] = 200, [ST.AttackPower] = 325, [ST.Armor] = 1600 }, 30)
    local a = p:RegisterAura({ label = "Blessing of The Black Book", actionId = { itemId = 19337 }, duration = 30,
      onGain = function(_, sim) if pet.enabled then petAura:Activate(sim) end end })
    local sp = p:RegisterSpell({ id = "item:19337", actionId = { itemId = 19337 }, defenseType = S.DEF_MAGIC,
      procMask = PM.Empty, flags = F.NoOnCastComplete, cd = 180, sharedCd = 30, sharedCdTimer = p:CategoryTimer(1141),
      relatedSelfBuff = a, extraCastCondition = function() return pet.enabled end,
      applyEffects = function(sim) a:Activate(sim) end })
    a.buffStats = { [ST.SpellDamage] = 200, [ST.AttackPower] = 325, [ST.Armor] = 1600 }
    p:AddMajorCooldown({ spell = sp })
  end
  -- Ashtongue Talisman of Shadows: 20% on a Corruption tick, +220 spell damage for 5 s
  if p:IsEquipped(32493) then
    local a = p:NewTemporaryStatsAura("Ashtongue Talisman of Shadows Proc", { [ST.SpellDamage] = 220 }, 5)
    p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Shadows", classMask = M.Corruption, procChance = 0.2,
      callback = "periodic", handler = function(sim) a:Activate(sim) end })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Scenario hooks (Setup.lua S.NewScenario calls them in WoWSims' build order)
-- ---------------------------------------------------------------------------------------------------------------
S.RegisterClass("Warlock", {
  setup = function(p, talents, opts, consumables, buffs)
    S.SetupWarlock(p, talents, opts)
    return S.WarlockRaidBuffs(p, buffs)
  end,
  applyTalents = function(p) S.WarlockApplyTalents(p) end,
  initialize = function(p) S.WarlockInitialize(p) end,
})

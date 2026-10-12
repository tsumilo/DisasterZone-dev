if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Hunter.lua", ...) then return end -- DisasterZone: Sim/Hunter.lua
-- ns.GearSim Hunter (sim/hunter/*.go): Auto Shot (Attack.lua's ranged hand), Steady / Arcane / Multi / Aimed Shot,
-- Serpent Sting, Kill Command, Rapid Fire, Bestial Wrath, Readiness, the Aspects of the Hawk and the Viper, ammo and
-- quiver, the pet (a ravager or another family: Bite / Claw / Gore / breath / Screech, Kill Command, focus, Dash, its
-- stats following the hunter's at a 5.25 s heartbeat), the talents of all three trees, tier sets 4-6 and the bows.
--
-- Not here: melee weaving (WoWSims' list moves in and out of melee range; the sim keeps the hunter at range), Aimed
-- Shot / Volley / Scorpid Sting in a list (none casts them), the pet's healing. WoWSims quirks kept: Ferocious
-- Inspiration (the talent) does nothing, Aspect of the Viper always gives mana (its full-mana check compares a
-- fraction to 100), Auto Shot's windup is also hastened by spell haste.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

-- proto HunterTalents order (talents string = Wowhead's)
local TALENTS = {
  { "ImprovedAspectOfTheHawk", "EnduranceTraining", "FocusedFire", "ImprovedAspectOfTheMonkey", "ThickHide",
    "ImprovedRevivePet", "Pathfinding", "BestialSwiftness", "UnleashedFury", "ImprovedMendPet", "Ferocity",
    "SpiritBond", "Intimidation", "BestialDiscipline", "AnimalHandler", "Frenzy", "FerociousInspiration",
    "BestialWrath", "CatlikeReflexes", "SerpentsSwiftness", "TheBeastWithin" },
  { "ImprovedConcussiveShot", "LethalShots", "ImprovedHuntersMark", "Efficiency", "GoForTheThroat",
    "ImprovedArcaneShot", "AimedShot", "RapidKilling", "ImprovedStings", "MortalShots", "ConcussiveBarrage",
    "ScatterShot", "Barrage", "CombatExperience", "RangedWeaponSpecialization", "CarefulAim", "TrueshotAura",
    "ImprovedBarrage", "MasterMarksman", "SilencingShot" },
  { "MonsterSlaying", "HumanoidSlaying", "HawkEye", "SavageStrikes", "Entrapment", "Deflection", "ImprovedWingClip",
    "CleverTraps", "Survivalist", "Deterrence", "TrapMastery", "Surefooted", "ImprovedFeignDeath", "SurvivalInstincts",
    "KillerInstinct", "Counterattack", "Resourcefulness", "LightningReflexes", "ThrillOfTheHunt", "WyvernSting",
    "ExposeWeakness", "MasterTactician", "Readiness" },
}
S.HUNTER_TALENTS = TALENTS

-- Class spell masks (hunter.go)
local M
do
  M = S.SpellMasks({
    "SpellRanged", "AutoShot", "AimedShot", "ArcaneShot", "AspectOfTheHawk", "AspectOfTheViper",
    "BestialWrath", "KillCommand", "KillCommandPet", "MultiShot", "RapidFire", "RaptorStrike", "RaptorStrikeQueue",
    "Readiness", "ScorpidSting", "SerpentSting", "SteadyShot", "Volley", "PetDamage" })
  M.All = M.AimedShot + M.ArcaneShot + M.BestialWrath + M.KillCommand + M.MultiShot + M.RapidFire + M.RaptorStrike
    + M.ScorpidSting + M.SerpentSting + M.SteadyShot + M.Volley
  M.ShotsAndStings = M.AimedShot + M.ArcaneShot + M.MultiShot + M.ScorpidSting + M.SerpentSting + M.SteadyShot + M.Volley
end
S.HUNTER_MASK = M

local AMMO_DPS = { TimelessArrow = 53, MysteriousArrow = 46.5, AdamantiteStinger = 43, WardensArrow = 37,
  HalaaniRazorshaft = 34, BlackflightArrow = 32 }
local QUIVER = { Speed10 = 1.1, Speed11 = 1.11, Speed12 = 1.12, Speed13 = 1.13, Speed14 = 1.14, Speed15 = 1.15 }
local THORIDAL = 34334

-- pet.go DefaultPetConfigs: damage multiplier and the two abilities (owl: picked at random)
local PET_CONFIGS = {
  Bat = { mult = 1.07, primary = "Bite", secondary = "Screech" },
  Bear = { mult = 0.91, primary = "Bite", secondary = "Claw" },
  Cat = { mult = 1.1, primary = "Bite", secondary = "Claw" },
  Crab = { mult = 0.95, primary = "Claw" },
  Owl = { mult = 1.07, primary = "Claw", secondary = "Screech", random = true },
  Raptor = { mult = 1.1, primary = "Bite", secondary = "Claw" },
  Ravager = { mult = 1.1, primary = "Bite", secondary = "Gore" },
  WindSerpent = { mult = 1.07, primary = "Bite", secondary = "LightningBreath" },
  Dragonhawk = { mult = 1.0, primary = "Bite", secondary = "FireBreath" },
}
S.HUNTER_PETS = PET_CONFIGS

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (hunter.go NewHunter)
-- opts: { ammo, quiverBonus, petType ("PetNone" for none), petUptime (0-1), petSingleAbility }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupHunter(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local hu = { opts = opts, talents = T, killCommandEnabledUntil = 0 }
  p.hunter = hu
  p.ps.CanParry = true
  p:AddStatDependency(ST.Strength, ST.AttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.AttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.RangedAttackPower, 1)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Hunter)

  local thoridal = (p.gearIds.Ranged == THORIDAL)
  hu.ammoDps = AMMO_DPS[opts.ammo or "AmmoNone"] or 0
  -- quiver haste (none with Thori'dal, which hastes by itself)
  local q = QUIVER[opts.quiverBonus or "QuiverNone"]
  if q and not thoridal then
    local a = p:RegisterAura({ label = "Haste", duration = huge })
    a:AttachMultiplicativePseudoStatBuff("RangedSpeedMultiplier", q)
    S.MakePermanent(a)
    hu.quiverAura = a
  end
  local w = p.rangedWeapon or { baseMin = 0, baseMax = 0, swingSpeed = 3, normalizedSpeed = 2.8, apPerDps = 14 }
  hu.ammoDamageBonus = 0
  if not thoridal then
    hu.ammoDamageBonus = hu.ammoDps * w.swingSpeed
    w.baseMin, w.baseMax = w.baseMin + hu.ammoDamageBonus, w.baseMax + hu.ammoDamageBonus
  end
  -- melee hands only in melee range; Auto Shot from beyond it out to 35 yards (Hawk Eye: further)
  p.autoAttacks:EnableRanged(w, { minRange = 5.01, maxRange = 35 + 2 * T.HawkEye, meleeMaxRange = 5 })
  p.autoAttacks.mh.replaceSwing = function(sim, spell) return S.HunterTryRaptorStrike(p, sim, spell) end

  if (opts.petType or "PetNone") ~= "PetNone" and (opts.petUptime or 1) > 0 and PET_CONFIGS[opts.petType] then
    hu.pet = S.HunterPet(p, opts.petType)
  end
  return hu
end

-- hunter.go NewHunter / AddPartyBuffs: the raid's Expose Weakness goes when the hunter has the talent (he brings his
-- own), a bat or owl brings Screech, Trueshot Aura reaches the party, Windfury Totem is noted (Steady Shot).
function S.HunterRaidBuffs(p, cfg)
  local hu, T = p.hunter, p.talents
  local out = {}
  for k, v in pairs(cfg) do out[k] = v end
  local d, party = {}, {}
  for k, v in pairs(cfg.debuffs or {}) do d[k] = v end
  for k, v in pairs(cfg.party or {}) do party[k] = v end
  local pt = hu.opts.petType
  if pt == "Bat" or pt == "Owl" then d.screech = nil end
  if T.ExposeWeakness > 0 then d.exposeWeaknessUptime, d.exposeWeaknessHunterAgility = nil, nil end
  if T.TrueshotAura > 0 then party.trueshotAura = true end
  hu.windFuryEnabled = ((party.windfuryTotem == true) and 1 or (party.windfuryTotem or 0)) > 0
  out.debuffs, out.party = d, party
  return out
end

-- raptor_strike.go TryRaptorStrike: a main-hand swing becomes Raptor Strike when it is ready
function S.HunterTryRaptorStrike(p, sim, spell)
  local rs = p.hunter.raptorStrike
  if spell.tag ~= 1 or not rs or not rs:CanCast(sim, p.currentTarget) then return spell end
  return rs
end

-- hunter.go RegisterRangedSpell: GCD 1.5 s not hastened; a cast time hastened by ranged haste that pushes Auto Shot
-- past its end; 40 yards a second unless said otherwise
local function RangedSpell(p, cfg)
  cfg.missileSpeed = cfg.missileSpeed or 40
  cfg.gcd = 1.5
  cfg.ignoreHaste = true
  cfg.flags = (cfg.flags or 0)
  cfg.damageMultiplier = cfg.damageMultiplier or 1
  cfg.damageMultiplierAdditive = cfg.damageMultiplierAdditive or 1
  cfg.threatMultiplier = cfg.threatMultiplier or 1
  if (cfg.castTime or 0) > 0 then
    local base = cfg.castTime
    -- spell.go CastTime: what the rotation reads too
    cfg.castTimeFn = function() return base / p:TotalRangedHasteMultiplier() end
    cfg.modifyCast = function(sim, spell, gcd)
      local ct = base / p:TotalRangedHasteMultiplier()
      p.autoAttacks:DelayRangedUntil(sim, sim.now + ct + 1e-9)
      return gcd, ct
    end
  end
  return p:RegisterSpell(cfg)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The pet (pet.go, pet_abilities.go)
-- ---------------------------------------------------------------------------------------------------------------
local function PetRotation(sim, pet)
  local hu = pet.owner.hunter
  if pet.distance > 5 then
    -- at the pull the pet runs in from the hunter's distance (Dash first)
    if pet.dash:CanCast(sim, pet.currentTarget) then pet.dash:Cast(sim, pet.currentTarget) end
    if not pet.moving then pet:MoveTo(4, sim) end
    return
  end
  local remaining = (sim.duration - sim.now) / sim.duration
  if remaining < 1 - pet.uptimePercent then
    pet:DisablePet(sim)
    return
  end
  local t = pet.currentTarget
  local cfg = pet.petConfig
  if cfg.random and sim:Rand() >= 0.5 then
    if pet.secondary and pet.secondary:CanCast(sim, t) then pet.secondary:Cast(sim, t)
    elseif pet.primary and pet.primary:CanCast(sim, t) then pet.primary:Cast(sim, t) end
    return
  end
  if pet.primary and pet.primary:CanCast(sim, t) then pet.primary:Cast(sim, t)
  elseif pet.secondary and pet.secondary:CanCast(sim, t) then pet.secondary:Cast(sim, t) end
end

local function PetAbility(pet, kind)
  local enabled = function() return pet.enabled end
  local function melee(id, cost, cd, lo, hi, extra)
    return pet:RegisterSpell({ id = id, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial,
      flags = F.MeleeMetrics, focusCost = { cost = cost }, gcd = 1.5, ignoreHaste = true, cd = cd,
      damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, extraCastCondition = enabled,
      applyEffects = function(sim, target, spell)
        local base = sim:Roll(lo, hi)
        if extra then base = extra(sim, base) end
        spell:CalcAndDealDamage(sim, target, base, OUT.MeleeSpecialHitAndCrit)
      end })
  end
  if kind == "Bite" then return melee(27050, 35, 10, 108, 132) end
  if kind == "Claw" then return melee(27049, 25, nil, 54, 76) end
  if kind == "Gore" then
    return melee(35298, 25, nil, 37, 61, function(sim, b) if sim:Proc(0.5) then return b * 2 end return b end)
  end
  if kind == "Screech" then
    local sp = melee(27051, 20, nil, 33, 61)
    return sp
  end
  if kind == "LightningBreath" then
    return pet:RegisterSpell({ id = 25012, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
      focusCost = { cost = 50 }, gcd = 1.5, ignoreHaste = true, damageMultiplier = 1, damageMultiplierAdditive = 1,
      threatMultiplier = 1, bonusCoefficient = 0.05, extraCastCondition = enabled,
      applyEffects = function(sim, target, spell)
        spell:CalcAndDealDamage(sim, target, sim:Roll(101, 116), OUT.MagicHitAndCrit)
      end })
  end
  if kind == "FireBreath" then
    return pet:RegisterSpell({ id = 35323, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
      focusCost = { cost = 50 }, gcd = 1.5, ignoreHaste = true, cd = 10, damageMultiplier = 1,
      damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 0.05, extraCastCondition = enabled,
      dot = S.TickDot("Fire Breath", 2, 1, 43.5, 0.05, { selfOnly = true }),
      applyEffects = function(sim, target, spell)
        local d = spell.aoeDot
        d:Apply(sim)
        d:TickOnce(sim)
      end })
  end
end

function S.HunterPet(p, petType)
  local T = p.talents
  local cfg = PET_CONFIGS[petType]
  local pet = S.NewPet(p, { name = petType, key = "pet", guardian = false, enabledOnStart = true, dynamic = true,
    startsAtOwnerDistance = true, class = "Warrior",
    -- Add 1.8% (pets aren't hit by that part of crit suppression); AP -20 as for pets and warriors
    baseStats = { Agility = 127, Strength = 162, AttackPower = -20, MeleeCritRating = (1.1515 + 1.8) * S.CRIT_RATING_PER_PCT },
    mainHand = { baseMin = 42, baseMax = 68, swingSpeed = 2, normalizedSpeed = 2, apPerDps = 14 },
    inherit = function(o)
      return { [ST.Stamina] = o[ST.Stamina] * 0.3, [ST.Armor] = o[ST.Armor] * 0.35,
        [ST.AttackPower] = o[ST.RangedAttackPower] * 0.22, [ST.SpellDamage] = o[ST.RangedAttackPower] * 0.128 }
    end,
    rotation = PetRotation })
  pet.petConfig = cfg
  pet.autoAttacks.mh.maxRange = 5
  pet:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  pet:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Warrior)
  pet:EnableFocusBar(1 + 0.5 * T.BestialDiscipline)
  pet.autoAttacks.mhSpell.damageMultiplier = pet.autoAttacks.mhSpell.damageMultiplier * cfg.mult
  -- happiness
  pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * 1.25
  pet.uptimePercent = 1
  local hu = p.hunter
  local og = pet.agentReset
  pet.agentReset = function(sim)
    if og then og(sim) end
    pet.uptimePercent = min(1, max(0, hu.opts.petUptime or 1))
  end
  return pet
end

-- pet.go ApplyTalents (Cobra Reflexes) and Initialize (abilities, Kill Command, Dash)
local function PetInitialize(p, pet)
  local hu = p.hunter
  local cobra = pet:RegisterAura({ label = "Cobra Reflexes", actionId = { spellId = 25076 }, duration = huge,
    onGain = function() pet.autoAttacks.mhSpell.damageMultiplier = pet.autoAttacks.mhSpell.damageMultiplier * 0.85 end,
    onExpire = function() pet.autoAttacks.mhSpell.damageMultiplier = pet.autoAttacks.mhSpell.damageMultiplier / 0.85 end })
  cobra:AttachMultiplicativePseudoStatBuff("MeleeSpeedMultiplier", 1.3)
  S.MakePermanent(cobra)
  local cfg = pet.petConfig
  if hu.opts.petSingleAbility then
    pet.primary = PetAbility(pet, cfg.secondary)
    pet.petConfig = { mult = cfg.mult, primary = cfg.primary, secondary = cfg.secondary, random = false }
  else
    pet.primary = PetAbility(pet, cfg.primary)
    pet.secondary = cfg.secondary and PetAbility(pet, cfg.secondary) or nil
  end
  -- Kill Command (the pet's part): weapon damage + 127, no focus
  pet.killCommand = pet:RegisterSpell({ id = 34027, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    procMask = PM.Empty, flags = F.APL, classMask = M.KillCommandPet, focusCost = { cost = 0 }, nonEmpty = true,
    damageMultiplier = cfg.mult, damageMultiplierAdditive = 1, threatMultiplier = 1,
    extraCastCondition = function() return pet.distance <= 5 end,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(pet.autoAttacks.mh, sim, spell:MeleeAttackPower(target)) + 127
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeSpecialHitAndCrit)
    end })
  -- Dash: +80% run speed for 15 s
  local dash = pet:RegisterAura({ label = "Dash", actionId = { spellId = 23110 }, duration = 15,
    onGain = function(_, sim) pet:MultiplyMovementSpeed(sim, 1.8) end,
    onExpire = function(_, sim) pet:MultiplyMovementSpeed(sim, 1 / 1.8) end })
  pet.dash = pet:RegisterSpell({ id = 23110, focusCost = { cost = 20 }, gcd = 1.5, cd = 30, procMask = PM.Empty,
    extraCastCondition = function() return pet.enabled end,
    applyEffects = function(sim) dash:Activate(sim) end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.HunterApplyTalents(p)
  local hu, T = p.hunter, p.talents
  local pet = hu.pet
  local target = p.currentTarget

  -- Beast Mastery
  if T.ImprovedAspectOfTheHawk > 0 then
    local q = p:RegisterAura({ label = "Quick Shots", actionId = { spellId = 6150 }, duration = 12 })
    q:AttachMultiplyRangedHaste(1 + 0.03 * T.ImprovedAspectOfTheHawk)
    hu.quickShots = q
  end
  if pet and T.FocusedFire > 0 then
    p.ps.DamageDealtMultiplier = p.ps.DamageDealtMultiplier * (1 + 0.01 * T.FocusedFire)
    pet:AddStaticMod({ kind = "BonusCrit_Percent", value = 10 * T.FocusedFire, classMask = M.KillCommandPet })
  end
  if pet and T.UnleashedFury > 0 then pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * (1 + 0.04 * T.UnleashedFury) end
  if pet and T.Ferocity > 0 then
    pet:AddStat(ST.PhysicalCritPercent, 2 * T.Ferocity)
    pet:AddStat(ST.SpellCritPercent, 2 * T.Ferocity)
  end
  if pet and T.AnimalHandler > 0 then
    pet:AddStat(ST.PhysicalHitPercent, 2 * T.AnimalHandler)
    pet:AddStat(ST.SpellHitPercent, 2 * T.AnimalHandler)
  end
  if pet and T.Frenzy > 0 then
    local fr = pet:RegisterAura({ label = "Frenzy Effect", actionId = { spellId = 19615 }, duration = 8 })
    fr:AttachMultiplyMeleeSpeed(1.3)
    pet:MakeProcTriggerAura({ name = "Frenzy", callback = "hit", outcome = O.Crit, procChance = 0.2 * T.Frenzy,
      handler = function(sim) fr:Activate(sim) end })
  end
  if pet and T.BestialWrath > 0 then
    local bw = pet:RegisterAura({ label = "Bestial Wrath", actionId = { spellId = 19574 }, duration = 18 })
    bw:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", 1.5)
    pet.bestialWrathAura = bw
    hu.bestialWrath = p:RegisterSpell({ id = 19574, school = SCHOOL.Physical, classMask = M.BestialWrath,
      procMask = PM.Empty, manaCost = { basePct = 10 }, nonEmpty = true, cd = 120,
      extraCastCondition = function(sim) return p.GCD.readyAt <= sim.now end,
      applyEffects = function(sim) bw:Activate(sim) end })
    p:AddMajorCooldown({ spell = hu.bestialWrath })
    if T.TheBeastWithin > 0 then
      local tbw = p:RegisterAura({ label = "The Beast Within", actionId = { spellId = 34471 }, duration = 18 })
      tbw:AttachSpellMod({ kind = "PowerCost_Pct", value = -0.2, classMask = M.All })
      tbw:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", 1.1)
      local og = bw.onGain
      bw.onGain = function(a, sim)
        if og then og(a, sim) end
        tbw:Activate(sim)
      end
    end
  end
  if pet and T.SerpentsSwiftness > 0 then
    p.ps.RangedSpeedMultiplier = p.ps.RangedSpeedMultiplier * (1 + 0.04 * T.SerpentsSwiftness)
    pet.ps.MeleeSpeedMultiplier = pet.ps.MeleeSpeedMultiplier * (1 + 0.04 * T.SerpentsSwiftness)
  end

  -- Marksmanship
  if T.LethalShots > 0 then p:AddStat(ST.RangedCritPercent, T.LethalShots) end
  if T.Efficiency > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.02 * T.Efficiency, classMask = M.ShotsAndStings })
  end
  if pet and T.GoForTheThroat > 0 then
    local amount = 25 * T.GoForTheThroat
    p:MakeProcTriggerAura({ name = "Go for the Throat", callback = "hit", outcome = O.Crit, procMask = PM.Ranged,
      handler = function(sim) pet:AddFocus(sim, amount, "go_for_the_throat") end })
  end
  if T.ImprovedArcaneShot > 0 then
    p:AddStaticMod({ kind = "Cooldown_Flat", value = -0.2 * T.ImprovedArcaneShot, classMask = M.ArcaneShot })
  end
  -- Aimed Shot (registered whatever the talent, as WoWSims does)
  hu.aimedShot = RangedSpell(p, { id = 27065, school = SCHOOL.Physical, defenseType = S.DEF_RANGED,
    classMask = M.AimedShot, procMask = PM.RangedSpecial, flags = F.MeleeMetrics + F.APL, manaCost = { flat = 370 },
    castTime = 3, cd = 6, bonusCoefficient = 1,
    applyEffects = function(sim, t, spell)
      local base = 0.2 * spell:RangedAttackPower(t) + S.WeaponBaseDamage(p.autoAttacks.ranged, sim) + S.HunterTalonBonus(p) + 870
      local r = spell:CalcDamage(sim, t, base, OUT.RangedHitAndCrit)
      S.Travel(p, sim, 40, function(s) spell:DealDamage(s, r) end)
    end })
  if T.RapidKilling > 0 then
    p:AddStaticMod({ kind = "Cooldown_Flat", value = -60 * T.RapidKilling, classMask = M.RapidFire })
  end
  if T.ImprovedStings > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.06 * T.ImprovedStings, classMask = M.SerpentSting })
  end
  if T.MortalShots > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Flat", value = 0.06 * T.MortalShots, procMask = PM.Ranged })
  end
  if T.Barrage > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.04 * T.Barrage, classMask = M.MultiShot + M.Volley })
  end
  if T.CombatExperience > 0 then
    p:MultiplyStat(ST.Agility, 1 + 0.01 * T.CombatExperience)
    p:MultiplyStat(ST.Intellect, 1 + 0.03 * T.CombatExperience)
  end
  if T.RangedWeaponSpecialization > 0 then
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.01 * T.RangedWeaponSpecialization, procMask = PM.Ranged })
  end
  if T.CarefulAim > 0 then p:AddStatDependency(ST.Intellect, ST.RangedAttackPower, 0.15 * T.CarefulAim) end
  if T.ImprovedBarrage > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 4 * T.ImprovedBarrage, classMask = M.MultiShot })
  end
  if T.MasterMarksman > 0 then p:MultiplyStat(ST.RangedAttackPower, 1 + 0.02 * T.MasterMarksman) end

  -- Survival
  if (T.MonsterSlaying > 0 or T.HumanoidSlaying > 0) then
    local beast, humanoid = 1 + 0.01 * T.MonsterSlaying, 1 + 0.01 * T.HumanoidSlaying
    p.postFinalize[#p.postFinalize + 1] = function()
      local at = p.attackTables[target]
      local mt = target.mobType
      local m = (mt == "Humanoid" and humanoid) or ((mt == "Beast" or mt == "Giant" or mt == "Dragonkin") and beast) or nil
      if at and m then
        at.damageDealtMultiplier = (at.damageDealtMultiplier or 1) * m
        at.critMultiplier = (at.critMultiplier or 1) * m
      end
    end
  end
  if T.SavageStrikes > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 10 * T.SavageStrikes, classMask = M.RaptorStrike })
  end
  if T.Survivalist > 0 then p:MultiplyStat(ST.Health, 1 + 0.02 * T.Survivalist) end
  if T.Surefooted > 0 then p:AddStat(ST.PhysicalHitPercent, T.Surefooted) end
  if T.SurvivalInstincts > 0 then
    p:MultiplyStat(ST.AttackPower, 1 + 0.02 * T.SurvivalInstincts)
    p:MultiplyStat(ST.RangedAttackPower, 1 + 0.02 * T.SurvivalInstincts)
  end
  if T.KillerInstinct > 0 then p:AddStat(ST.PhysicalCritPercent, T.KillerInstinct) end
  if T.Resourcefulness > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.2 * T.Resourcefulness, classMask = M.RaptorStrike })
  end
  if T.LightningReflexes > 0 then p:MultiplyStat(ST.Agility, 1 + 0.03 * T.LightningReflexes) end
  if T.ThrillOfTheHunt > 0 then
    p:MakeProcTriggerAura({ name = "Thrill of the Hunt", callback = "hit", procMask = PM.RangedSpecial, outcome = O.Crit,
      procChance = T.ThrillOfTheHunt / 3,
      extraCondition = function(sim, spell) return (spell.curCost or 0) > 0 end,
      handler = function(sim, spell) p:AddMana(sim, (spell.curCost or 0) * 0.4, "thrill_of_the_hunt") end })
  end
  if T.ExposeWeakness > 0 then
    -- debuffs.go ExposeWeaknessAura: a quarter of the hunter's agility as attack power against the target
    local ew = S.ExposeWeaknessAura(target, function() return p.stats[ST.Agility] end)
    p:MakeProcTriggerAura({ name = "Expose Weakness", callback = "hit", procMask = PM.Ranged, outcome = O.Crit,
      procChance = T.ExposeWeakness / 3, handler = function(sim) ew:Activate(sim) end })
  end
  if T.MasterTactician > 0 then
    local a = p:NewTemporaryStatsAura("Master Tactician", { [ST.PhysicalCritPercent] = 2 * T.MasterTactician }, 8)
    p:MakeProcTriggerAura({ name = "Master Tactician Trigger", callback = "hit", procMask = PM.Ranged,
      outcome = O.Landed, procChance = 0.06, handler = function(sim) a:Activate(sim) end })
  end
  hu.readinessTalent = T.Readiness > 0
  if pet then PetInitialize(p, pet) end
end

-- debuffs.go ExposeWeaknessAura: stacks = a quarter of the agility when it lands; each stack is attack power (and
-- ranged attack power) against the target
function S.ExposeWeaknessAura(target, agilityFn)
  local tps = target.ps
  local a = target:GetAura("Expose Weakness")
  if a then return a end
  a = target:RegisterAura({ label = "Expose Weakness", actionId = { spellId = 34503 }, duration = 7, maxStacks = 10000,
    onGain = function(aura, sim) aura:SetStacks(sim, floor(agilityFn() * 0.25)) end,
    onStacksChange = function(_, _, old, new)
      local d = new - old
      tps.BonusAttackPower = tps.BonusAttackPower + d
      tps.BonusRangedAttackPower = tps.BonusRangedAttackPower + d
    end })
  return a
end

function S.HunterTalonBonus(p)
  local a = p.hunter.talonAura
  return (a and a.active) and 40 or 0
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spells (hunter.go RegisterSpells)
-- ---------------------------------------------------------------------------------------------------------------
function S.HunterInitialize(p)
  local hu, T = p.hunter, p.talents
  local pet = hu.pet
  local aa = p.autoAttacks

  -- arcane_shot.go
  hu.arcaneShot = RangedSpell(p, { id = 27019, school = SCHOOL.Arcane, defenseType = S.DEF_RANGED,
    classMask = M.ArcaneShot, procMask = PM.RangedSpecial, flags = F.MeleeMetrics + F.APL, manaCost = { flat = 230 },
    cd = 6,
    applyEffects = function(sim, t, spell)
      local base = spell:RangedAttackPower(t) * 0.15 + S.HunterTalonBonus(p) + 273
      local r = spell:CalcDamage(sim, t, base, OUT.RangedHitAndCrit)
      S.Travel(p, sim, 40, function(s) spell:DealDamage(s, r) end)
    end })

  -- aspects.go: Hawk (+155 ranged attack power) or Viper (mana each tick); one at a time
  local hawk, viper
  hawk = p:RegisterAura({ label = "Aspect of the Hawk", actionId = { spellId = 27044 }, duration = huge,
    onGain = function(_, sim) if viper.active then viper:Deactivate(sim) end end })
  hawk:AttachStatBuff(ST.RangedAttackPower, 155)
  viper = p:RegisterAura({ label = "Aspect of the Viper", actionId = { spellId = 34074 }, duration = huge,
    onGain = function(_, sim) if hawk.active then hawk:Deactivate(sim) end end })
  hu.hawkAura, hu.viperAura = hawk, viper
  if hu.quickShots then
    local q = hu.quickShots
    S.AttachProcTrigger(hawk, p, { name = "Improved Aspect of the Hawk", callback = "hit", procMask = PM.RangedAuto,
      outcome = O.Landed, procChance = 0.1, handler = function(sim) q:Activate(sim) end })
  end
  p:RegisterSpell({ id = 27044, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, classMask = M.AspectOfTheHawk,
    procMask = PM.Empty, flags = F.APL, manaCost = { flat = 140 }, gcd = 1.5, ignoreHaste = true, relatedSelfBuff = hawk,
    applyEffects = function(sim) hawk:Activate(sim) end })
  hu.viper = p:RegisterSpell({ id = 34074, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
    classMask = M.AspectOfTheViper, procMask = PM.Empty, flags = F.APL, manaCost = { flat = 40 }, gcd = 1.5,
    ignoreHaste = true, relatedSelfBuff = viper, applyEffects = function(sim) viper:Activate(sim) end })
  -- aspects.go OnManaTick: Viper's mana, more the emptier the hunter is (WoWSims compares the fraction to 100)
  p.onManaTick = function(sim)
    if not viper.active then return end
    local cur = p.mana / p.stats[ST.Mana]
    if cur >= 100 then return end
    local pm = max(0.2, min(0.9, cur))
    local scaling = 22 / 35 * (0.9 - pm) + 0.11
    if hu.gronn2Aura and hu.gronn2Aura.active then scaling = scaling + 0.05 end
    local per5 = p.stats[ST.Intellect] * scaling + 0.35 * 70
    p:AddMana(sim, per5 * 2 / 5, "aspect_of_the_viper")
  end

  -- kill_command.go: ready for 5 s after any crit of the hunter's; the pet strikes
  if pet then
    p:MakeProcTriggerAura({ name = "Kill Command Trigger", callback = "hit", outcome = O.Crit,
      handler = function(sim) hu.killCommandEnabledUntil = sim.now + 5 end })
    hu.killCommand = p:RegisterSpell({ id = 34026, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      procMask = PM.Melee, classMask = M.KillCommand, flags = F.APL + F.MeleeMetrics, manaCost = { flat = 75 },
      nonEmpty = true, cd = 5, damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1,
      extraCastCondition = function(sim, t)
        return hu.killCommandEnabledUntil >= sim.now and pet.killCommand:CanCast(sim, t)
      end,
      applyEffects = function(sim, t)
        hu.killCommandEnabledUntil = 0
        pet.killCommand:Cast(sim, t)
      end })
  end

  -- multi_shot.go: 30 yards a second, one target here
  hu.multiShot = RangedSpell(p, { id = 27021, school = SCHOOL.Physical, defenseType = S.DEF_RANGED,
    classMask = M.MultiShot, procMask = PM.RangedSpecial, flags = F.MeleeMetrics + F.APL, missileSpeed = 30,
    manaCost = { flat = 275 }, castTime = 0.5, cd = 10, bonusCoefficient = 1,
    applyEffects = function(sim, t, spell)
      local base = spell:RangedAttackPower(t) * 0.2 + S.WeaponBaseDamage(aa.ranged, sim) + S.HunterTalonBonus(p) + 205
      local r = spell:CalcDamage(sim, t, base, OUT.RangedHitAndCrit)
      S.Travel(p, sim, 30, function(s) spell:DealDamage(s, r) end)
    end })

  -- raptor_strike.go (melee range only)
  hu.raptorStrike = p:RegisterSpell({ id = 27014, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    classMask = M.RaptorStrike, procMask = PM.MeleeMH, flags = F.MeleeMetrics + F.NoOnCastComplete,
    manaCost = { flat = 120 }, nonEmpty = true, cd = 6, damageMultiplier = 1, damageMultiplierAdditive = 1,
    threatMultiplier = 1, extraCastCondition = function() return p.distance <= 5 end,
    applyEffects = function(sim, t, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(t)) + 170
      spell:CalcAndDealDamage(sim, t, base, OUT.MeleeSpecialHitAndCrit)
    end })

  -- rapid_fire.go: +40% ranged haste for 15 s
  local rf = p:RegisterAura({ label = "Rapid Fire", actionId = { spellId = 3045 }, duration = 15 })
  rf:AttachMultiplyRangedHaste(1.4)
  hu.rapidFire = p:RegisterSpell({ id = 3045, school = SCHOOL.Arcane, classMask = M.RapidFire, procMask = PM.Empty,
    manaCost = { flat = 100 }, nonEmpty = true, cd = 300, relatedSelfBuff = rf,
    extraCastCondition = function(sim) return p.GCD.readyAt <= sim.now and not rf.active end,
    applyEffects = function(sim) rf:Activate(sim) end })
  p:AddMajorCooldown({ spell = hu.rapidFire, shouldActivate = function() return not rf.active end })

  -- serpent_sting.go: 5 ticks of 132 + 2% of ranged attack power over 15 s; lands after travel
  hu.serpentSting = RangedSpell(p, { id = 27016, school = SCHOOL.Nature, defenseType = S.DEF_RANGED,
    classMask = M.SerpentSting, procMask = PM.Empty, flags = F.APL, manaCost = { flat = 275 },
    dot = { label = "Serpent Sting", numberOfTicks = 5, tickLength = 3,
      onSnapshot = function(sim, t, dot) dot:Snapshot(t, dot.spell:RangedAttackPower(t) * 0.02 + 132) end,
      onTick = function(sim, t, dot) dot:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcOutcome(sim, t, OUT.RangedHit)
      S.Travel(p, sim, 40, function(s)
        if S.Landed(r) then spell:Dot(t):Apply(s) end
        spell:DealDamage(s, r)
      end)
    end })

  -- steady_shot.go: 150 + 20% of ranged attack power + weapon damage normalized to 2.8 s, without ammo, scope or
  -- weightstone
  local scope = 0
  local ench = p.gear.Ranged and p.gear.Ranged.spec.enchant or 0
  if ench == 2722 then scope = 10 elseif ench == 2723 then scope = 12 end
  local cons = p.consumables or {}
  local stone = 0
  if cons.ohImbueId == 34340 or cons.ohImbueId == 29453 then stone = stone + 12 end
  if (cons.mhImbueId == 34340 or cons.mhImbueId == 29453) and not hu.windFuryEnabled then stone = stone + 12 end
  hu.steadyShot = RangedSpell(p, { id = 34120, school = SCHOOL.Physical, defenseType = S.DEF_RANGED,
    classMask = M.SteadyShot, procMask = PM.RangedSpecial, flags = F.MeleeMetrics + F.APL, manaCost = { flat = 110 },
    castTime = 1.5,
    applyEffects = function(sim, t, spell)
      local wd = S.WeaponBaseDamage(aa.ranged, sim) - hu.ammoDamageBonus - scope - stone
      local base = 0.2 * spell:RangedAttackPower(t) + wd * 2.8 / aa.ranged.swingSpeed + S.HunterTalonBonus(p) + 150
      local r = spell:CalcDamage(sim, t, base, OUT.RangedHitAndCrit)
      S.Travel(p, sim, 40, function(s) spell:DealDamage(s, r) end)
    end })

  -- talents.go Readiness
  if hu.readinessTalent then
    local rd = p:RegisterSpell({ id = 23989, school = SCHOOL.Physical, classMask = M.Readiness, procMask = PM.Empty,
      gcd = 1, ignoreHaste = true, cd = 300,
      extraCastCondition = function(sim)
        local function busy(sp) return sp and not sp:IsReady(sim) end
        return busy(hu.rapidFire) or busy(hu.multiShot) or busy(hu.arcaneShot) or busy(hu.killCommand)
          or busy(hu.raptorStrike)
      end,
      applyEffects = function()
        for _, sp in ipairs({ hu.rapidFire, hu.multiShot, hu.arcaneShot, hu.killCommand, hu.raptorStrike }) do
          if sp and sp.cdTimer then sp.cdTimer.readyAt = S.STARTING_CD end
        end
      end })
    p:AddMajorCooldown({ spell = rd, shouldActivate = function(sim) return not hu.rapidFire:IsReady(sim) end })
  end

  S.HunterItems(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items (item_sets.go): tier sets 3-6, Thori'dal, the Black Bow, Beast-tamer's Shoulders, Talon of Al'ar, the
-- Ashtongue Talisman, PvP gloves
-- ---------------------------------------------------------------------------------------------------------------
function S.HunterItems(p)
  local hu = p.hunter
  local pet = hu.pet
  -- Cryptstalker Armor 2: Rapid Fire +4 s; 4: +50 attack power for hunter and pet; 6: ranged crits give 50 mana;
  -- 8: Multi-Shot / Aimed Shot cost 20 less
  if p:CouldHaveSetBonus("Cryptstalker Armor", 2) then
    p:AddStaticMod({ kind = "BuffDuration_Flat", value = 4, classMask = M.RapidFire })
  end
  if p:CouldHaveSetBonus("Cryptstalker Armor", 4) and pet then
    local b = { [ST.AttackPower] = 50, [ST.RangedAttackPower] = 50 }
    local oa = p:RegisterAura({ label = "Stalker's Ally", actionId = { spellId = 28757 }, duration = huge })
    oa:AttachStatsBuff(b)
    S.MakePermanent(oa)
    local pa = pet:RegisterAura({ label = "Stalker's Ally", actionId = { spellId = 28758 }, duration = huge })
    pa:AttachStatsBuff(b)
    S.MakePermanent(pa)
  end
  if p:CouldHaveSetBonus("Cryptstalker Armor", 6) then
    p:MakeProcTriggerAura({ name = "Adrenaline Rush", callback = "hit", outcome = O.Crit, procMask = PM.Ranged,
      handler = function(sim) p:AddMana(sim, 50, "adrenaline_rush") end })
  end
  if p:CouldHaveSetBonus("Cryptstalker Armor", 8) then
    p:AddStaticMod({ kind = "PowerCost_Flat", value = -20, classMask = M.MultiShot + M.AimedShot })
  end
  -- Beast Lord Armor 4: Kill Command gives 600 armor penetration for 15 s
  if p:CouldHaveSetBonus("Beast Lord Armor", 4) then
    local a = p:RegisterAura({ label = "Exploited Weakness", actionId = { spellId = 37482 }, duration = 15 })
    a:AttachStatBuff(ST.ArmorPenetration, 600)
    p:MakeProcTriggerAura({ name = "Improved Kill Command", callback = "cast", classMask = M.KillCommand,
      handler = function(sim) a:Activate(sim) end })
  end
  -- Demon Stalker Armor 4: Multi-Shot costs 10% less
  if p:CouldHaveSetBonus("Demon Stalker Armor", 4) then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.1, classMask = M.MultiShot })
  end
  -- Rift Stalker Armor 4: Steady Shot +5% crit
  if p:CouldHaveSetBonus("Rift Stalker Armor", 4) then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 5, classMask = M.SteadyShot })
  end
  -- Gronnstalker's Armor 2: Viper gives more; 4: Steady Shot +10%
  if p:CouldHaveSetBonus("Gronnstalker's Armor", 2) then
    local a = p:RegisterAura({ label = "Gronnstalker's Armor 2pc", duration = huge })
    S.MakePermanent(a)
    hu.gronn2Aura = a
  end
  if p:CouldHaveSetBonus("Gronnstalker's Armor", 4) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.1, classMask = M.SteadyShot })
  end
  -- Thori'dal: 15% ranged speed, no ammo (the quiver's haste goes)
  if p.gearIds.Ranged == THORIDAL then
    local a = p:RegisterAura({ label = "Legendary Bow Haste", actionId = { spellId = 44972 }, duration = huge })
    a:AttachMultiplicativePseudoStatBuff("RangedSpeedMultiplier", 1.15)
    S.MakePermanent(a)
  end
  -- Beast-tamer's Shoulders: the pet +3% damage, +3% crit
  if p:IsEquipped(30892) and pet then
    pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * 1.03
    pet:AddStat(ST.PhysicalCritPercent, 3)
  end
  -- Black Bow of the Betrayer: 8 mana a ranged hit
  if p:IsEquipped(32336) then
    p:MakeProcTriggerAura({ name = "Black Bow of the Betrayer", callback = "hit", outcome = O.Landed, procMask = PM.Ranged,
      spellFlagsExclude = F.SuppressWeaponProcs, handler = function(sim) p:AddMana(sim, 8, "black_bow") end })
  end
  -- Ashtongue Talisman of Swiftness: 15% on a Steady Shot, +275 attack power for 8 s
  if p:IsEquipped(32487) then
    local a = p:NewTemporaryStatsAura("Deadly Aim", { [ST.AttackPower] = 275, [ST.RangedAttackPower] = 275 }, 8)
    p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Swiftness", callback = "hit", classMask = M.SteadyShot,
      outcome = O.Landed, procChance = 0.15, handler = function(sim) a:Activate(sim) end })
  end
  -- Talon of Al'ar: an Arcane Shot makes the next shots +40 damage for 6 s
  if p:IsEquipped(30448) then
    local a = p:RegisterAura({ label = "Shot Power", actionId = { spellId = 37508 }, duration = 6 + 1e-9 })
    hu.talonAura = a
    p:MakeProcTriggerAura({ name = "Improved Shots", callback = "hit", classMask = M.ArcaneShot, outcome = O.Landed,
      handler = function(sim) a:Activate(sim) end })
  end
  -- PvP gloves: Multi-Shot +5%
  for _, id in ipairs({ 23279, 22862, 16463, 16571, 35475, 35377, 28806, 28614, 28335, 31961, 33665, 34991 }) do
    if p.gearIds.Hands == id then
      p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.05, classMask = M.MultiShot })
    end
  end
end

-- enchants.go scopes: hit, crit, or flat damage on the ranged weapon
S.ENCHANT_EFFECTS = S.ENCHANT_EFFECTS or {}
S.ENCHANT_EFFECTS[2523] = function(p) p:AddStat(ST.RangedHitPercent, 30 / S.HIT_RATING_PER_PCT) end
S.ENCHANT_EFFECTS[2724] = function(p) p:AddStat(ST.RangedCritPercent, 28 / S.CRIT_RATING_PER_PCT) end
for id, dmg in pairs({ [2722] = 10, [2723] = 12 }) do
  S.ENCHANT_EFFECTS[id] = function(p)
    local r = p.autoAttacks and p.autoAttacks.ranged
    if r then r.baseMin, r.baseMax = r.baseMin + dmg, r.baseMax + dmg end
  end
end

-- Scenario hooks: Setup.lua S.NewScenario runs them in WoWSims' build order
S.RegisterClass("Hunter", {
  setup = function(p, talents, opts, consumables, buffs)
    S.SetupHunter(p, talents, opts)
    return S.HunterRaidBuffs(p, buffs)
  end,
  applyTalents = function(p) S.HunterApplyTalents(p) end,
  initialize = function(p) S.HunterInitialize(p) end,
})

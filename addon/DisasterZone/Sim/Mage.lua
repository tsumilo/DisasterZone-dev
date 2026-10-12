if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Mage.lua", ...) then return end -- DisasterZone: Sim/Mage.lua
-- ns.GearSim Mage (sim/mage/*.go): Arcane Blast and its charges, Arcane Missiles (a channel), Frostbolt, Fireball,
-- Fire Blast, Scorch, Pyroblast, Blast Wave, Dragon's Breath, Arcane Power, Presence of Mind, Icy Veins, Cold Snap,
-- Combustion, Evocation (a channel), mana gems, armors, the Water Elemental (a pet), Ignite, Clearcasting,
-- Winter's Chill, the talents of all three trees, tier sets and mage items.
--
-- As in WoWSims (kept on purpose so both sims agree): Critical Mass is keyed on a spell flag and so applies to no
-- spell, Master of Elements never switches on, Elemental Precision gives frost spells 2% hit per point, the Water
-- Elemental stays for the whole fight. Not here: area spells (Arcane Explosion, Blizzard, Flamestrike, Cone of Cold,
-- Frost Nova), Slow, Ice Lance (not in WoWSims' build).
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

-- proto MageTalents order (talents string = Wowhead's)
local TALENTS = {
  { "ArcaneSubtlety", "ArcaneFocus", "ImprovedArcaneMissiles", "WandSpecialization", "MagicAbsorption",
    "ArcaneConcentration", "MagicAttunement", "ArcaneImpact", "ArcaneFortitude", "ImprovedManaShield",
    "ImprovedCounterspell", "ArcaneMeditation", "ImprovedBlink", "PresenceOfMind", "ArcaneMind", "PrismaticCloak",
    "ArcaneInstability", "ArcanePotency", "EmpoweredArcaneMissiles", "ArcanePower", "SpellPower", "MindMastery", "Slow" },
  { "ImprovedFireball", "Impact", "Ignite", "FlameThrowing", "ImprovedFireBlast", "Incineration",
    "ImprovedFlamestrike", "Pyroblast", "BurningSoul", "ImprovedScorch", "MoltenShields", "MasterOfElements",
    "PlayingWithFire", "CriticalMass", "BlastWave", "BlazingSpeed", "FirePower", "Pyromaniac", "Combustion",
    "MoltenFury", "EmpoweredFireball", "DragonsBreath" },
  { "FrostWarding", "ImprovedFrostbolt", "ElementalPrecision", "IceShards", "Frostbite", "ImprovedFrostNova",
    "Permafrost", "PiercingIce", "IcyVeins", "ImprovedBlizzard", "ArcticReach", "FrostChanneling", "Shatter",
    "FrozenCore", "ColdSnap", "ImprovedConeOfCold", "IceFloes", "WintersChill", "IceBarrier", "ArcticWinds",
    "EmpoweredFrostbolt", "SummonWaterElemental" },
}
S.MAGE_TALENTS = TALENTS

-- Class spell masks (mage.go)
local M
do
  local nextBit
  M, nextBit = S.SpellMasks({
    "ArcaneBlast", "ArcaneExplosion", "ArcanePower", "ArcaneMissilesCast", "ArcaneMissilesTick",
    "BlastWave", "Blizzard", "ColdSnap", "ConeOfCold", "DragonsBreath", "Evocation", "FireBlast", "Fireball",
    "Flamestrike", "FlamestrikeDot", "FrostArmor", "Frostbolt", "FrostNova", "IceBarrier", "IceBlock", "IceLance",
    "IcyVeins", "Ignite", "MageArmor", "ManaGems", "MoltenArmor", "PresenceOfMind", "Pyroblast", "PyroblastDot",
    "Scorch", "Slow", "ManaGem", "Combustion", "WaterBolt" })
  M.All = nextBit * 2 - 1
  M.Frost = M.Frostbolt + M.Blizzard + M.FrostNova + M.ConeOfCold + M.IceLance
  M.Fire = M.DragonsBreath + M.Fireball + M.Combustion + M.FireBlast + M.Flamestrike + M.Ignite + M.Pyroblast + M.Scorch
  M.AllDamaging = M.ArcaneBlast + M.ArcaneExplosion + M.ArcaneMissilesTick + M.Blizzard + M.DragonsBreath + M.FireBlast
    + M.Fireball + M.Flamestrike + M.Frostbolt + M.IceLance + M.Pyroblast + M.PyroblastDot + M.Scorch
  M.InstantCast = M.ArcaneMissilesCast + M.ArcaneMissilesTick + M.FireBlast + M.ArcaneExplosion + M.PyroblastDot
    + M.Combustion + M.ConeOfCold + M.DragonsBreath + M.IceLance + M.ManaGems + M.PresenceOfMind
  M.Ignitable = M.Fireball + M.Scorch + M.Pyroblast
end
S.MAGE_MASK = M

-- float32 coefficients as Go reads them (spell_data_auto_gen.go)
local C_FROSTBOLT, C_FIREBLAST, C_PYRO, C_WAVE = 0.81400001049041748, 0.42899999022483826, 1.1499999761581421,
  0.19300000369548798

local ARMOR = { MageArmor = "Mage Armor", MoltenArmor = "Molten Armor", FrostArmor = "Frost Armor" }

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (mage.go NewMage); opts: { defaultMageArmor = "MageArmor" | "MoltenArmor" | "FrostArmor" | "None" }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupMage(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local mg = { opts = opts, talents = T }
  p.mage = mg
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Mage)
  p.autoAttacks.autoSwingMelee = false
  if T.SummonWaterElemental > 0 then mg.waterElemental = S.MageWaterElemental(p) end
  return mg
end

-- water_elemental.go: a pet with its own mana that casts Waterbolt; a third of the mage's frost spell damage, his
-- hit rating and spell crit
function S.MageWaterElemental(p)
  -- sleeps: its one spell can only become castable at an event (cast end, mana gain)
  local pet = S.NewPet(p, { name = "Water Elemental", key = "water_elemental", guardian = false, mana = true, sleeps = true,
    baseStats = { Health = 1596, Mana = 1893 },
    inherit = function(o)
      return { [ST.Stamina] = o[ST.Stamina] * 0.3, [ST.SpellDamage] = o[ST.FrostDamage] * 0.33,
        [ST.SpellHitRating] = o[ST.SpellHitRating], [ST.SpellPenetration] = o[ST.SpellPenetration],
        [ST.SpellCritPercent] = o[ST.SpellCritPercent] }
    end,
    rotation = function(sim, u) u.waterbolt:Cast(sim, u.currentTarget) end })
  pet.waterbolt = pet:RegisterSpell({ id = 31707, school = SCHOOL.Frost, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.WaterBolt, manaCost = { basePct = 10 }, gcd = 1.5, gcdMin = 1.5,
    castTime = 2.5, damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.83300000429,
    applyEffects = function(sim, target, spell)
      spell:CalcAndDealDamage(sim, target, sim:Roll(256, 328), OUT.MagicHitAndCrit)
    end })
  return pet
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.MageApplyTalents(p)
  local mg, T = p.mage, p.talents
  local target = p.currentTarget

  -- Arcane
  if T.ArcaneFocus > 0 then
    local i = S.SCHOOL_INDEX[SCHOOL.Arcane]
    p.ps.SchoolBonusHitChance[i] = p.ps.SchoolBonusHitChance[i] + 2 * T.ArcaneFocus
  end
  if T.ArcaneConcentration > 0 then
    -- 2% per point on a landed damage spell: the next damage spell is free (+10% crit per Arcane Potency point)
    local bonusCrit = T.ArcanePotency * 10 * S.CRIT_RATING_PER_PCT
    local proccedAt, proccedSpell
    local cc = p:RegisterAura({ label = "Clearcasting", actionId = { spellId = 12536 }, duration = 15,
      onGain = function(_, sim)
        p:AddStatDynamic(sim, ST.SpellCritRating, bonusCrit)
        p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier - 100
      end,
      onExpire = function(_, sim)
        p:AddStatDynamic(sim, ST.SpellCritRating, -bonusCrit)
        p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier + 100
      end,
      onCastComplete = function(aura, sim, spell)
        if not has(spell.classMask, M.AllDamaging) then return end
        if not spell.cost or spell.cost.base == 0 then return end
        if proccedAt == sim.now and proccedSpell == spell then return end
        aura:Deactivate(sim)
      end })
    mg.clearcasting = cc
    local chance = 0.02 * T.ArcaneConcentration
    S.MakePermanent(p:RegisterAura({ label = "Arcane Concentration",
      onSpellHitDealt = function(_, sim, spell, result)
        if not has(spell.classMask, M.AllDamaging) then return end
        if not S.Landed(result) then return end
        if sim:Proc(chance) then
          proccedAt, proccedSpell = sim.now, spell
          cc:Activate(sim)
        end
      end }))
  end
  if T.ArcaneImpact > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 2 * T.ArcaneImpact, classMask = M.ArcaneBlast + M.ArcaneExplosion })
  end
  if T.ArcaneMeditation > 0 then
    p.ps.SpiritRegenRateCasting = p.ps.SpiritRegenRateCasting + 0.1 * T.ArcaneMeditation
    p:UpdateManaRegenRates()
  end
  if T.ArcaneMind > 0 then p:MultiplyStat(ST.Intellect, 1 + 0.03 * T.ArcaneMind) end
  if T.ArcaneInstability > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.ArcaneInstability, classMask = M.All })
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.01 * T.ArcaneInstability, classMask = M.All })
  end
  if T.EmpoweredArcaneMissiles > 0 then
    p:AddStaticMod({ kind = "BonusCoefficient_Flat", value = 0.03 * T.EmpoweredArcaneMissiles, classMask = M.ArcaneMissilesTick })
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = 0.02 * T.EmpoweredArcaneMissiles, classMask = M.ArcaneMissilesCast })
  end
  if T.SpellPower > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Flat", value = 0.25 * T.SpellPower, classMask = M.All })
  end
  if T.MindMastery > 0 then p:AddStatDependency(ST.Intellect, ST.SpellDamage, 0.05 * T.MindMastery) end

  -- Fire
  if T.ImprovedFireball > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.1 * T.ImprovedFireball, classMask = M.Fireball })
  end
  if T.Ignite > 0 then S.MageIgnite(p) end
  if T.ImprovedFireBlast > 0 then
    p:AddStaticMod({ kind = "Cooldown_Flat", value = -0.5 * T.ImprovedFireBlast, classMask = M.FireBlast })
  end
  if T.Incineration > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 2 * T.Incineration, classMask = M.FireBlast + M.Scorch })
  end
  if T.PlayingWithFire > 0 then
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.01 * T.PlayingWithFire, classMask = M.All })
  end
  if T.CriticalMass > 0 then
    -- WoWSims keys this on SpellFlag(SpellSchoolFire) = SpellFlagIgnoreTargetModifiers: no mage spell has it
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 2 * T.CriticalMass, spellFlag = F.IgnoreTargetModifiers })
  end
  if T.FirePower > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.02 * T.FirePower, school = SCHOOL.Fire })
  end
  if T.Pyromaniac > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.Pyromaniac, school = SCHOOL.Fire })
    p:AddStaticMod({ kind = "PowerCost_Pct", value = -0.01 * T.Pyromaniac, school = SCHOOL.Fire })
  end
  if T.MoltenFury > 0 then
    -- +10% per point below 20% health
    local mf = p:AddDynamicMod({ kind = "DamageDone_Pct", value = 0.1 * T.MoltenFury, classMask = M.All })
    p:RegisterResetEffect(function(sim)
      mf:Deactivate()
      sim.executeCallbacks[#sim.executeCallbacks + 1] = function(_, phase) if phase == 20 then mf:Activate() end end
    end)
  end
  if T.EmpoweredFireball > 0 then
    p:AddStaticMod({ kind = "BonusCoefficient_Flat", value = 0.03 * T.EmpoweredFireball, classMask = M.Fireball })
  end

  -- Frost
  if T.ImprovedFrostbolt > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.1 * T.ImprovedFrostbolt, classMask = M.Frostbolt })
  end
  if T.ElementalPrecision > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct", value = -0.01 * T.ElementalPrecision, school = SCHOOL.Fire + SCHOOL.Frost })
    local fr, fi = S.SCHOOL_INDEX[SCHOOL.Frost], S.SCHOOL_INDEX[SCHOOL.Fire]
    p.ps.SchoolBonusHitChance[fr] = p.ps.SchoolBonusHitChance[fr] + 2 * T.ElementalPrecision
    p.ps.SchoolBonusHitChance[fi] = p.ps.SchoolBonusHitChance[fi] + T.ElementalPrecision
  end
  if T.IceShards > 0 then
    p:AddStaticMod({ kind = "CritMultiplier_Flat", value = 0.2 * T.IceShards, school = SCHOOL.Frost })
  end
  if T.PiercingIce > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.02 * T.PiercingIce, classMask = M.Frost })
  end
  if T.FrostChanneling > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.05 * T.FrostChanneling, classMask = M.Frost })
  end
  if T.IceFloes > 0 then
    p:AddStaticMod({ kind = "Cooldown_Multiplier", value = ({ 0.9, 0.8 })[min(T.IceFloes, 2)],
      classMask = M.ColdSnap + M.ConeOfCold + M.IceBarrier + M.IceBlock })
  end
  if T.WintersChill > 0 then
    local chance = 0.2 * T.WintersChill
    local wc = S.WintersChillAura(target, p, nil)
    p:MakeProcTriggerAura({ name = "Winters Chill Talent", callback = "hit", outcome = O.Landed, classMask = M.Frost,
      procChance = chance, handler = function(sim) wc:Activate(sim); wc:AddStack(sim) end })
  end
  if T.ArcticWinds > 0 then
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.01 * T.ArcticWinds, classMask = M.Frost })
  end
  if T.EmpoweredFrostbolt > 0 then
    p:AddStaticMod({ kind = "BonusCoefficient_Flat", value = 0.02 * T.EmpoweredFrostbolt, classMask = M.Frostbolt })
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.EmpoweredFrostbolt, classMask = M.Frostbolt })
  end
end

-- talents.go registerIgnite: 8% per point of a fire crit's damage over 4 s (two ticks), rolling into the Ignite
-- already on the target
function S.MageIgnite(p)
  local T = p.talents
  local mult = 0.08 * T.Ignite
  local ignite = p:RegisterSpell({ id = 12846, school = SCHOOL.Fire, procMask = PM.SpellDamage, classMask = M.Ignite,
    flags = F.IgnoreAttackerModifiers + F.IgnoreTargetModifiers + F.NoSpellMods + F.IgnoreResists + F.Proc,
    damageMultiplier = 1, threatMultiplier = 1,
    dot = { label = "Ignite", numberOfTicks = 2, tickLength = 2, maxStacks = 2147483647,
      onTick = function(sim, target, d)
        local r = d.spell:CalcPeriodicDamage(sim, target, d.snapshotBaseDamage, OUT.Tick)
        d.spell:DealPeriodicDamage(sim, r)
      end },
    applyEffects = function(sim, target, spell) spell:Dot(target):Apply(sim) end })
  p.mage.ignite = ignite
  p:MakeProcTriggerAura({ name = "Ignite Talent", canProcFromProcs = true, callback = "hit", procMask = PM.SpellDamage,
    classMask = M.Ignitable, outcome = O.Crit, triggerImmediately = true,
    handler = function(sim, _, result)
      local t = result.target
      local d = ignite:Dot(t)
      local outstanding = d:IsActive() and d.snapshotBaseDamage * d.remainingTicks or 0
      if d.remainingTicks <= 0 then outstanding = 0 end
      local perTick = (outstanding + result.damage * mult) / d.baseTickCount
      ignite:Cast(sim, t)
      d.snapshotBaseDamage = perTick
      d.aura:SetStacks(sim, floor(perTick))
    end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spells
-- ---------------------------------------------------------------------------------------------------------------
local function MageSpell(cfg)
  cfg.defenseType = cfg.defenseType or S.DEF_MAGIC
  cfg.procMask = cfg.procMask or PM.SpellDamage
  cfg.flags = (cfg.flags or 0) + F.APL
  cfg.damageMultiplier = cfg.damageMultiplier or 1
  cfg.damageMultiplierAdditive = cfg.damageMultiplierAdditive or 1
  cfg.threatMultiplier = 1
  cfg.gcd = cfg.gcd or 1.5
  return cfg
end

-- arcane_charge.go: each landed Arcane Blast adds a charge (3, 8 s): -0.334 s cast and +75% cost per charge
local function ArcaneCharges(p)
  local cost = p:AddDynamicMod({ classMask = M.ArcaneBlast, kind = "PowerCost_Pct_Add", value = 0.75 })
  local cast = p:AddDynamicMod({ classMask = M.ArcaneBlast, kind = "CastTime_Flat", value = -0.334 })
  local a = p:RegisterAura({ label = "Arcane Charges Aura", actionId = { spellId = 36032 }, duration = 8, maxStacks = 3,
    onGain = function() cast:Activate(); cost:Activate() end,
    onExpire = function() cast:Deactivate(); cost:Deactivate() end,
    onStacksChange = function(_, sim, old, new)
      cast:UpdateValue(-0.334 * new)
      cost:UpdateValue(0.75 * new)
    end })
  return a
end

function S.MageInitialize(p)
  local mg, T = p.mage, p.talents
  local target = p.currentTarget
  S.ImprovedScorchAura(target)
  local charges = ArcaneCharges(p)
  mg.arcaneCharges = charges

  -- Arcane Blast
  p:RegisterSpell(MageSpell({ id = 30451, school = SCHOOL.Arcane, classMask = M.ArcaneBlast, manaCost = { flat = 195 },
    castTime = 2.5, bonusCoefficient = 0.71399998665,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealDamage(sim, t, sim:Roll(668, 772), OUT.MagicHitAndCrit)
      -- BlockPrepull: no charges from a cast that lands before the pull
      if S.Landed(r) and sim.now >= 0 then
        charges:Activate(sim)
        charges:AddStack(sim)
      end
    end }))
  -- Arcane Missiles (rank 10): a 5 s channel of five missiles that travel at 20 yards a second
  local tick = p:RegisterSpell({ id = 38699, tag = 1, school = SCHOOL.Arcane, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.ArcaneMissilesTick, damageMultiplier = 1, threatMultiplier = 1,
    bonusCoefficient = 0.28600001335,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, 265, OUT.TickMagicHitAndCrit)
      S.Travel(p, sim, 20, function(s) spell:DealDamage(s, r) end)
    end })
  p:RegisterSpell(MageSpell({ id = 38699, school = SCHOOL.Arcane, flags = F.Channeled, classMask = M.ArcaneMissilesCast,
    damageMultiplier = 0, manaCost = { flat = 740 },
    dot = { label = "ArcaneMissiles", numberOfTicks = 5, tickLength = 1, hasteReducesDuration = true,
      affectedByCastSpeed = true, onTick = function(sim, t) tick:Cast(sim, t) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealOutcome(sim, t, OUT.MagicHit)
      if S.Landed(r) then spell:Dot(t):Apply(sim) end
    end }))
  -- Frostbolt (rank 13): travels at 28 yards a second
  p:RegisterSpell(MageSpell({ id = 27072, school = SCHOOL.Frost, flags = F.Binary, classMask = M.Frostbolt,
    manaCost = { flat = 330 }, castTime = 3, bonusCoefficient = C_FROSTBOLT,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(600, 647), OUT.MagicHitAndCrit)
      S.Travel(p, sim, 28, function(s) spell:DealDamage(s, r) end)
    end }))
  -- Fireball (rank 13): travels at 24 yards a second, leaves a small DoT
  p:RegisterSpell(MageSpell({ id = 27070, school = SCHOOL.Fire, classMask = M.Fireball, manaCost = { flat = 425 },
    castTime = 3.5, bonusCoefficient = 1,
    dot = { label = "FireballDoT", numberOfTicks = 4, tickLength = 2,
      onSnapshot = function(sim, t, d) d:Snapshot(t, 21) end,
      onTick = function(sim, t, d) d:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(649, 821), OUT.MagicHitAndCrit)
      S.Travel(p, sim, 24, function(s)
        spell:DealDamage(s, r)
        if S.Landed(r) then spell:Dot(t):Apply(s) end
      end)
    end }))
  -- Fire Blast (rank 9)
  p:RegisterSpell(MageSpell({ id = 27079, school = SCHOOL.Fire, classMask = M.FireBlast, manaCost = { flat = 465 },
    cd = 8, bonusCoefficient = C_FIREBLAST,
    applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(664, 786), OUT.MagicHitAndCrit) end }))
  -- Scorch (rank 9): Improved Scorch stacks fire damage taken
  local scorchChance = ({ [0] = 0, 0.33, 0.66, 1 })[min(T.ImprovedScorch, 3)]
  p:RegisterSpell(MageSpell({ id = 27074, school = SCHOOL.Fire, classMask = M.Scorch, manaCost = { flat = 180 },
    castTime = 1.5, bonusCoefficient = C_FIREBLAST,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcAndDealDamage(sim, t, sim:Roll(305, 361), OUT.MagicHitAndCrit)
      if S.Landed(r) and T.ImprovedScorch > 0 and sim:Proc(scorchChance) then
        local a = S.ImprovedScorchAura(t)
        a:Activate(sim)
        a:AddStack(sim)
      end
    end }))
  -- Pyroblast (rank 10): travels at 24 yards a second, then its DoT (its own spell)
  local pyroDot = p:RegisterSpell({ id = 33938, tag = 1, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, classMask = M.PyroblastDot, flags = F.NoOnCastComplete + F.PassiveSpell,
    damageMultiplier = 1, threatMultiplier = 1,
    dot = { label = "PyroblastDoT", numberOfTicks = 4, tickLength = 3, bonusCoefficient = 0.05000000075,
      onSnapshot = function(sim, t, d) d:Snapshot(t, 89) end,
      onTick = function(sim, t, d) d:CalcAndDealPeriodicSnapshotDamage(sim, t, OUT.Tick) end },
    applyEffects = function(sim, t, spell) spell:Dot(t):Apply(sim) end })
  local pyro = p:RegisterSpell(MageSpell({ id = 33938, school = SCHOOL.Fire, classMask = M.Pyroblast,
    manaCost = { flat = 500 }, castTime = 6, bonusCoefficient = C_PYRO,
    applyEffects = function(sim, t, spell)
      local r = spell:CalcDamage(sim, t, sim:Roll(939, 1191), OUT.MagicHitAndCrit)
      S.Travel(p, sim, 24, function(s)
        spell:DealDamage(s, r)
        if S.Landed(r) then pyroDot:Cast(s, t) end
      end)
    end }))
  pyro.relatedDotSpell = pyroDot

  -- armors (armors.go): the default one is on all fight
  local armors = {
    MageArmor = p:RegisterAura({ label = "Mage Armor", actionId = { spellId = 27125 },
      onGain = function() p.ps.SpiritRegenRateCasting = p.ps.SpiritRegenRateCasting + 0.3; p:UpdateManaRegenRates() end,
      onExpire = function() p.ps.SpiritRegenRateCasting = p.ps.SpiritRegenRateCasting - 0.3; p:UpdateManaRegenRates() end }),
    MoltenArmor = p:RegisterAura({ label = "Molten Armor", actionId = { spellId = 30482 } }),
    FrostArmor = p:RegisterAura({ label = "Frost Armor", actionId = { spellId = 27124 } }),
  }
  armors.MoltenArmor:AttachStatBuff(ST.SpellCritPercent, 3)
  local def = armors[mg.opts.defaultMageArmor or "MageArmor"]
  if def then S.MakePermanent(def) end

  -- Evocation: a channel, 15% of maximum mana every 2 s for 8 s
  local perTick = 0
  local evo = p:RegisterSpell({ id = 12051, flags = F.Helpful + F.Channeled + F.APL, classMask = M.Evocation,
    gcd = 1.5, cd = 480,
    dot = { label = "Evocation", selfOnly = true, numberOfTicks = 4, tickLength = 2, affectedByCastSpeed = true,
      hasteReducesDuration = true, onTick = function(sim) p:AddMana(sim, perTick, "evocation") end },
    applyEffects = function(sim, _, spell)
      perTick = p:MaxMana() * 0.15
      spell.aoeDot:Apply(sim)
    end })
  p:AddMajorCooldown({ spell = evo, shouldActivate = function() return p.mana / p:MaxMana() <= 0.1 end })

  -- mana gems (mana_gems.go): three charges of 2340-2460 mana (Serpent-Coil Braid: +25%), 2 min apart
  local gemAura = p:RegisterAura({ label = "Mana Gem Charges", actionId = { itemId = 22044 }, maxStacks = 3 })
  S.MakePermanent(gemAura)
  local og = gemAura.onReset
  gemAura.onReset = function(a, sim) if og then og(a, sim) end a:SetStacks(sim, 3) end
  local function GemGain(sim)
    local g = sim:Roll(2340, 2460)
    if mg.braidActive then g = g * 1.25 end
    return g
  end
  local gem = p:RegisterSpell({ id = "item:22044", procMask = PM.Empty, flags = F.APL + F.Helpful,
    classMask = M.ManaGem, nonEmpty = true, cd = 120, cdTimer = p:CategoryTimer(30), sharedCd = 120,
    sharedCdTimer = p:CategoryTimer(1153),
    extraCastCondition = function() return gemAura.stacks > 0 end,
    applyEffects = function(sim)
      gemAura:RemoveStack(sim)
      p:AddMana(sim, GemGain(sim), "mana_gem")
    end })
  p:AddMajorCooldown({ spell = gem, shouldActivate = function(sim)
    return p.mana + GemGain(sim) + p:SpiritRegenPerSecond() <= p:MaxMana()
  end })

  -- Presence of Mind: the next spell with a cast time is instant
  if T.PresenceOfMind > 0 then
    local mod = p:AddDynamicMod({ kind = "CastTime_Pct", value = -1,
      classMask = M.All - M.InstantCast - M.Blizzard - M.Evocation })
    local pomSpell
    local a = p:RegisterAura({ label = "Presence of Mind", actionId = { spellId = 12043 }, duration = 3600,
      onGain = function() mod:Activate() end,
      onExpire = function(_, sim)
        mod:Deactivate()
        pomSpell.cdTimer.readyAt = sim.now + pomSpell.cdDuration * pomSpell.cdMultiplier
      end,
      onCastComplete = function(aura, sim, spell)
        if not has(spell.classMask, M.All - M.InstantCast - M.Evocation) then return end
        if (spell.castTime or 0) == 0 then return end
        aura:Deactivate(sim)
      end })
    pomSpell = p:RegisterSpell({ id = 12043, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete,
      classMask = M.PresenceOfMind, nonEmpty = true, cd = 180, relatedSelfBuff = a,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = pomSpell })
  end
  -- Arcane Power: +30% damage and +30% cost for 15 s
  if T.ArcanePower > 0 then
    local costMod = p:AddDynamicMod({ kind = "PowerCost_Pct_Add", value = 0.3, classMask = M.All })
    local dmgMod = p:AddDynamicMod({ kind = "DamageDone_Flat", value = 0.3, classMask = M.All })
    local apSpell
    local a = p:RegisterAura({ label = "Arcane Power", actionId = { spellId = 12042 }, duration = 15 })
    a:NewExclusiveEffect("ManaCost", true, 10,
      function() costMod:Activate(); dmgMod:Activate() end,
      function(_, sim)
        costMod:Deactivate(); dmgMod:Deactivate()
        apSpell.cdTimer.readyAt = sim.now + apSpell.cdDuration * apSpell.cdMultiplier
      end)
    mg.arcanePowerAura = a
    apSpell = p:RegisterSpell({ id = 12042, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete,
      classMask = M.ArcanePower, nonEmpty = true, cd = 180, relatedSelfBuff = a,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = apSpell })
  end
  -- Blast Wave / Dragon's Breath (one target)
  if T.BlastWave > 0 then
    p:RegisterSpell(MageSpell({ id = 33933, school = SCHOOL.Fire, classMask = M.BlastWave, manaCost = { flat = 620 },
      cd = 30, bonusCoefficient = C_WAVE,
      applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(616, 724), OUT.MagicHitAndCrit) end }))
  end
  if T.DragonsBreath > 0 then
    p:RegisterSpell(MageSpell({ id = 33043, school = SCHOOL.Fire, classMask = M.DragonsBreath, manaCost = { flat = 700 },
      cd = 20, bonusCoefficient = C_WAVE,
      applyEffects = function(sim, t, spell) spell:CalcAndDealDamage(sim, t, sim:Roll(680, 790), OUT.MagicHitAndCrit) end }))
  end
  -- Combustion: +10% fire crit per fire hit until three crits
  if T.Combustion > 0 then
    local numCrits = 0
    local critMod = p:AddDynamicMod({ kind = "BonusCrit_Percent", value = 0, classMask = M.Fire })
    local combSpell
    local a = p:RegisterAura({ label = "Combustion", actionId = { spellId = 11129 }, maxStacks = 20,
      onGain = function() numCrits = 0; critMod:Activate() end,
      onExpire = function(_, sim)
        critMod:Deactivate()
        combSpell.cdTimer.readyAt = sim.now + combSpell.cdDuration * combSpell.cdMultiplier
        p:UpdateMajorCooldowns()
      end,
      onStacksChange = function(_, sim, old, new) critMod:UpdateValue(10 * new) end,
      onSpellHitDealt = function(aura, sim, spell, result)
        if not has(spell.school or 0, SCHOOL.Fire) then return end
        if spell == mg.ignite then return end
        if not S.Landed(result) then return end
        if numCrits >= 3 then aura:Deactivate(sim); return end
        aura:AddStack(sim)
        if has(result.outcome, O.Crit) then
          numCrits = numCrits + 1
          if numCrits == 3 then aura:Deactivate(sim) end
        end
      end })
    combSpell = p:RegisterSpell({ id = 11129, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete, cd = 180,
      relatedSelfBuff = a, extraCastCondition = function() return not a.active end,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = combSpell })
  end
  -- Icy Veins: 20% faster casts for 20 s
  if T.IcyVeins > 0 then
    local a = p:RegisterAura({ label = "Icy Veins", actionId = { spellId = 12472 }, duration = 20,
      onGain = function(_, sim) p:MultiplyCastSpeed(sim, 1.2) end,
      onExpire = function(_, sim) p:MultiplyCastSpeed(sim, 1 / 1.2) end })
    mg.icyVeins = p:RegisterSpell({ id = 12472, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete,
      classMask = M.IcyVeins, nonEmpty = true, cd = 180, relatedSelfBuff = a,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = mg.icyVeins, shouldActivate = function() return not a.active end })
  end
  -- Cold Snap: Icy Veins and the Water Elemental ready again
  if T.ColdSnap > 0 then
    p:RegisterSpell({ id = 11958, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete + F.APL, classMask = M.ColdSnap,
      cd = 480, applyEffects = function(sim)
        if mg.icyVeins then mg.icyVeins.cdTimer.readyAt = 0 end
        if mg.summonWaterElemental then mg.summonWaterElemental.cdTimer.readyAt = 0 end
      end })
  end
  -- Summon Water Elemental (stays for the fight, as in WoWSims)
  if mg.waterElemental then
    local pet = mg.waterElemental
    mg.summonWaterElemental = p:RegisterSpell({ id = 31687, defenseType = S.DEF_MAGIC,
      flags = F.NoOnCastComplete + F.APL, manaCost = { basePct = 16 }, gcd = 1.5, cd = 180,
      applyEffects = function(sim) pet:EnablePet(sim) end })
  end

  S.MageItems(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items (items.go): tier 5 / 6, Serpent-Coil Braid, Ashtongue Talisman of Insight
-- ---------------------------------------------------------------------------------------------------------------
function S.MageItems(p)
  local mg = p.mage
  -- Tirisfal Regalia 2: Arcane Blast +20% damage and +20% cost; 4: a spell crit gives 70 spell damage for 6 s
  if p:CouldHaveSetBonus("Tirisfal Regalia", 2) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.2, classMask = M.ArcaneBlast })
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = 0.2, classMask = M.ArcaneBlast })
  end
  if p:CouldHaveSetBonus("Tirisfal Regalia", 4) then
    local a = p:NewTemporaryStatsAura("Arcane Madness", { [ST.SpellDamage] = 70 }, 6)
    p:MakeProcTriggerAura({ name = "Tirisfal 4PC", callback = "hit", procMask = PM.SpellDamage, outcome = O.Crit,
      handler = function(sim) a:Activate(sim) end })
  end
  -- Tempest Regalia 2: Evocation one tick longer; 4: Fireball, Frostbolt and Arcane Missiles +5%
  if p:CouldHaveSetBonus("Tempest Regalia", 2) then
    p:AddStaticMod({ kind = "DotNumberOfTicks_Flat", value = 1, classMask = M.Evocation })
  end
  if p:CouldHaveSetBonus("Tempest Regalia", 4) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.05, classMask = M.Fireball + M.Frostbolt + M.ArcaneMissilesTick })
  end
  -- Serpent-Coil Braid: mana gems give 25% more and 225 spell damage for 15 s
  if p:IsEquipped(30720) then
    mg.braidActive = true
    local a = p:NewTemporaryStatsAura("Mana Surge", { [ST.SpellDamage] = 225 }, 15)
    p:MakeProcTriggerAura({ name = "Serpent-Coil Braid", classMask = M.ManaGem, callback = "cast",
      handler = function(sim) a:Activate(sim) end })
  end
  -- Ashtongue Talisman of Insight: 50% on a class spell crit, 145 spell haste rating for 5 s
  if p:IsEquipped(32488) then
    local a = p:NewTemporaryStatsAura("Ashtongue Talisman of Insight - Proc", { [ST.SpellHasteRating] = 145 }, 5)
    p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Insight - Trigger", procChance = 0.5, classSpellsOnly = true,
      outcome = O.Crit, callback = "hit", handler = function(sim) a:Activate(sim) end })
  end
end

-- Scenario hooks: Setup.lua S.NewScenario runs them in WoWSims' build order
S.RegisterClass("Mage", {
  setup = function(p, talents, opts) S.SetupMage(p, talents, opts) end,
  applyTalents = function(p) S.MageApplyTalents(p) end,
  initialize = function(p) S.MageInitialize(p) end,
})

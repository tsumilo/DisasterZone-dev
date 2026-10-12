if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Priest.lua", ...) then return end -- DisasterZone: Sim/Priest.lua
-- ns.GearSim Shadow Priest (sim/priest/*.go): Mind Blast, Shadow Word: Pain / Death, Vampiric Touch (mana to the
-- caster), Mind Flay (a channel: Dot.lua / APL.lua clip it), Shadowfiend (a pet: Sim/Pet.lua), Shadowform, Inner
-- Focus, Misery and Shadow Weaving, the racials Starshards (Night Elf) and Devouring Plague (Undead), the talents of
-- all three trees that reach a damage priest, tier sets and the Ashtongue Talisman.
--
-- Not here (as in WoWSims or no use to the sim): Smite / Holy Fire / Holy Nova, Power Infusion on yourself, Vampiric
-- Embrace's healing, Shadow Word: Death's self damage, Inner Fire's armor.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

-- proto PriestTalents order (talents string = Wowhead's)
local TALENTS = {
  { "UnbreakableWill", "WandSpecialization", "SilentResolve", "ImprovedPowerWordFortitude", "ImprovedPowerWordShield",
    "Martyrdom", "Absolution", "InnerFocus", "Meditation", "ImprovedInnerFire", "MentalAgility", "ImprovedManaBurn",
    "MentalStrength", "DivineSpirit", "ImprovedDivineSpirit", "FocusedPower", "ForceOfWill", "FocusedWill",
    "PowerInfusion", "ReflectiveShield", "Enlightenment", "PainSuppression" },
  { "HealingFocus", "ImprovedRenew", "HolySpecialization", "SpellWarding", "DivineFury", "HolyNova", "BlessedRecovery",
    "Inspiration", "HolyReach", "ImprovedHealing", "SearingLight", "HealingPrayers", "SpiritOfRedemption",
    "SpiritualGuidance", "SurgeOfLight", "SpiritualHealing", "HolyConcentration", "Lightwell", "BlessedResilience",
    "EmpoweredHealing", "CircleOfHealing" },
  { "SpiritTap", "Blackout", "ShadowAffinity", "ImprovedShadowWordPain", "ShadowFocus", "ImprovedPsychicScream",
    "ImprovedMindBlast", "MindFlay", "ImprovedFade", "ShadowReach", "ShadowWeaving", "Silence", "VampiricEmbrace",
    "ImprovedVampiricEmbrace", "FocusedMind", "ShadowResilience", "Darkness", "Shadowform", "ShadowPower", "Misery",
    "VampiricTouch" },
}
S.PRIEST_TALENTS = TALENTS

-- Class spell masks (priest.go)
local M
do
  local nextBit
  M, nextBit = S.SpellMasks({
    "DevouringPlague", "DevouringPlagueDoT", "DevouringPlagueHeal", "HolyNova", "HolyFire", "MindBlast",
    "MindFlay", "PowerInfusion", "Starshards", "Shadowform", "ShadowWordDeath", "ShadowWordPain", "ShadowFiend",
    "VampiricEmbrace", "VampiricTouch", "Fade", "Smite" })
  M.All = nextBit - 1 - 1 -- every bit from 2 up
  M.Instant = M.DevouringPlague + M.Fade + M.HolyNova + M.PowerInfusion + M.ShadowWordDeath + M.ShadowWordPain
    + M.VampiricEmbrace + M.ShadowFiend + M.Starshards + M.Shadowform
  M.Shadow = M.DevouringPlague + M.ShadowWordDeath + M.Shadowform + M.ShadowWordPain + M.MindFlay + M.MindBlast
    + M.VampiricTouch + M.ShadowFiend + M.VampiricEmbrace
  M.Holy = M.Smite + M.HolyFire + M.HolyNova
end
S.PRIEST_MASK = M

-- float32 coefficients as Go reads them
local C429, C183, C200, C190, C167, C100 = 0.42899999022483826, 0.18299999833106995, 0.20000000298023224,
  0.18999999761581421, 0.16699999570846558, 0.10000000149011612

OUT.MagicHitNoHitCounter = OUT.MagicHitNoHitCounter or OUT.MagicHit

-- ---------------------------------------------------------------------------------------------------------------
-- Constructor (priest.go New / NewPriest)
-- opts: { preShadowform (default true) }
-- ---------------------------------------------------------------------------------------------------------------
function S.SetupPriest(p, talentsStr, opts)
  opts = opts or {}
  local T = S.ParseTalentTrees(TALENTS, talentsStr)
  p.talents = T
  local pr = { opts = opts, talents = T, preShadowform = opts.preShadowform ~= false }
  p.priest = pr
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Priest)
  p.autoAttacks.autoSwingMelee = false

  -- shadowfiend_pet.go: shadow melee, attack power from 57% of the priest's shadow spell damage (taken when it
  -- appears), 2.5 mana per point of damage it deals
  local base = { Strength = 153, Agility = 108, Stamina = 297, Intellect = 175, Spirit = 122, AttackPower = -20,
    Armor = 5290 }
  local pet = S.NewPet(p, { name = "Shadowfiend", key = "shadowfiend", baseStats = base, guardian = false,
    mainHand = { baseMin = 68, baseMax = 92, swingSpeed = 1.5, normalizedSpeed = 1.5, apPerDps = 14 },
    inherit = function(o) return { [ST.AttackPower] = (o[ST.SpellDamage] + o[ST.ShadowDamage]) * 0.57 } end,
    rotation = function() end })
  pet:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  local mh = pet.autoAttacks.mhSpell
  mh.school = SCHOOL.Shadow
  mh.schoolIndex = S.SCHOOL_INDEX[SCHOOL.Shadow]
  mh.bonusCoefficient = 1
  local restore = pet:MakeProcTriggerAura({ name = "Shadowfiend Mana Restore", duration = huge, callback = "hit",
    handler = function(sim, _, result) p:AddMana(sim, result.damage * 2.5, "shadowfiend") end })
  pet.onEnable = function(sim) restore:Activate(sim) end
  pr.shadowfiendPet = pet
  return pr
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go)
-- ---------------------------------------------------------------------------------------------------------------
function S.PriestApplyTalents(p)
  local pr, T = p.priest, p.talents
  local target = p.currentTarget

  -- Discipline
  if T.InnerFocus > 0 then
    -- the next priest spell is free and +25% crit; the cooldown starts when it is used up
    local critMod = p:AddDynamicMod({ kind = "BonusCrit_Percent", value = 25, classMask = M.All })
    local ifSpell
    local a = p:RegisterAura({ label = "Inner Focus", actionId = { spellId = 14751 }, duration = 3600,
      onGain = function()
        p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier - 100
        critMod:Activate()
      end,
      onExpire = function(_, sim)
        p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier + 100
        critMod:Deactivate()
        ifSpell.cdTimer.readyAt = sim.now + ifSpell.cdDuration * ifSpell.cdMultiplier
      end,
      onCastComplete = function(aura, sim, spell) if has(spell.classMask, M.All) then aura:Deactivate(sim) end end })
    pr.innerFocusAura = a
    ifSpell = p:RegisterSpell({ id = 14751, defenseType = S.DEF_MAGIC, flags = F.NoOnCastComplete + F.APL,
      nonEmpty = true, cd = 180, relatedSelfBuff = a, applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = ifSpell })
  end
  if T.Meditation > 0 then
    p.ps.SpiritRegenRateCasting = p.ps.SpiritRegenRateCasting + 0.1 * min(T.Meditation, 3)
    p:UpdateManaRegenRates()
  end
  if T.MentalAgility > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.02 * T.MentalAgility, classMask = M.Instant })
  end
  if T.MentalStrength > 0 then p:MultiplyStat(ST.Mana, 1 + 0.02 * T.MentalStrength) end
  if T.Enlightenment > 0 then
    local m = 1 + 0.01 * T.Enlightenment
    p:MultiplyStat(ST.Stamina, m)
    p:MultiplyStat(ST.Intellect, m)
    p:MultiplyStat(ST.Spirit, m)
  end
  if T.FocusedPower > 0 then
    p:AddStaticMod({ kind = "BonusHit_Percent", value = 2 * min(T.FocusedPower, 2), classMask = M.Smite + M.MindBlast })
  end
  if T.ForceOfWill > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.01 * T.ForceOfWill, classMask = M.All })
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.ForceOfWill, classMask = M.All })
  end

  -- Holy
  if T.DivineFury > 0 then
    p:AddStaticMod({ kind = "CastTime_Flat", value = -0.1 * T.DivineFury, classMask = M.Smite + M.HolyFire })
  end
  if T.SearingLight > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.05 * T.SearingLight, classMask = M.Smite + M.HolyFire })
  end
  if T.SpiritualGuidance > 0 then p:AddStatDependency(ST.Spirit, ST.SpellDamage, 0.05 * T.SpiritualGuidance) end
  if T.SpiritOfRedemption > 0 then p:MultiplyStat(ST.Spirit, 1.05) end

  -- Shadow
  if T.MindFlay > 0 then S.PriestMindFlay(p) end
  if T.Darkness > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.02 * T.Darkness, classMask = M.Shadow })
  end
  if T.ShadowFocus > 0 then
    local i = S.SCHOOL_INDEX[SCHOOL.Shadow]
    p.ps.SchoolBonusHitChance[i] = p.ps.SchoolBonusHitChance[i] + 2 * T.ShadowFocus
  end
  if T.ImprovedShadowWordPain > 0 then
    p:AddStaticMod({ kind = "DotNumberOfTicks_Flat", value = T.ImprovedShadowWordPain, classMask = M.ShadowWordPain })
  end
  if T.FocusedMind > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.05 * T.FocusedMind, classMask = M.MindBlast + M.MindFlay })
  end
  if T.ShadowPower > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 3 * T.ShadowPower, classMask = M.MindBlast + M.ShadowWordDeath })
  end
  if T.ShadowWeaving > 0 then
    local sw = S.ShadowWeavingAura(target)
    p:MakeProcTriggerAura({ name = "Shadow Weaving Trigger", canProcFromProcs = true, classMask = M.Shadow,
      callback = "hit", outcome = O.Landed, procChance = 0.2 * T.ShadowWeaving,
      handler = function(sim)
        sw:Activate(sim)
        sw:AddStack(sim)
      end })
  end
  if T.Misery > 0 then
    -- kept up as long as the longest of the DoTs that refreshed it
    p.ownMisery = true
    local misery = S.MiseryAura(target, T.Misery)
    p:MakeProcTriggerAura({ name = "Misery Trigger", classMask = M.ShadowWordPain + M.VampiricTouch + M.MindFlay,
      outcome = O.Landed, callback = "hit",
      handler = function(sim, spell, result)
        local dd = spell:Dot(result.target):RemainingDuration(sim)
        local cr = misery:RemainingDuration(sim)
        misery.duration = (dd > cr) and dd or cr
        misery:Activate(sim)
      end })
  end
  if T.Shadowform > 0 then
    local a = p:RegisterAura({ label = "Shadowform", actionId = { spellId = 15473 },
      onReset = function(aura, sim) if pr.preShadowform then aura:Activate(sim) end end,
      onCastComplete = function(aura, sim, spell) if has(spell.school or 0, SCHOOL.Holy) then aura:Deactivate(sim) end end })
    a:AttachSpellMod({ kind = "DamageDone_Flat", value = 0.15, classMask = M.Shadow })
    p:RegisterSpell({ id = 15473, school = SCHOOL.Shadow, procMask = PM.Empty, flags = F.APL, classMask = M.Shadowform,
      manaCost = { basePct = 32 }, gcd = 1.5, applyEffects = function(sim) a:Activate(sim) end })
  end
  if T.VampiricTouch > 0 then S.PriestVampiricTouch(p) end
  if T.ImprovedMindBlast > 0 then
    p:AddStaticMod({ kind = "Cooldown_Flat", value = -0.5 * T.ImprovedMindBlast, classMask = M.MindBlast })
  end
end

-- debuffs.go MiseryAura: spell damage taken +1% per rank (one Misery: the best one counts)
function S.MiseryAura(target, ranks)
  local mult = 1 + 0.01 * ranks
  local a = target:GetAura("Misery")
  if not a then
    a = target:RegisterAura({ label = "Misery", actionId = { spellId = 33195 } })
    local tps = target.ps
    local idx = {}
    for _, s in ipairs({ SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Holy, SCHOOL.Nature, SCHOOL.Shadow }) do
      idx[#idx + 1] = S.SCHOOL_INDEX[s]
    end
    a.miseryEffect = a:NewExclusiveEffect("MiseryBonus", true, mult,
      function(e) for _, i in ipairs(idx) do tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] * e.priority end end,
      function(e) for _, i in ipairs(idx) do tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] / e.priority end end)
  end
  if a.miseryEffect.priority < mult then a.miseryEffect.priority = mult end
  return a
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spells
-- ---------------------------------------------------------------------------------------------------------------
local function ShadowSpell(cfg)
  cfg.school = cfg.school or SCHOOL.Shadow
  cfg.defenseType = S.DEF_MAGIC
  cfg.procMask = PM.SpellDamage
  cfg.flags = (cfg.flags or 0) + F.APL
  cfg.damageMultiplier = 1
  cfg.damageMultiplierAdditive = 1
  cfg.threatMultiplier = 1
  cfg.gcd = cfg.gcd or 1.5
  return cfg
end

-- mind_flay.go (rank 7): a 3 s channel of three ticks, shortened by haste (ticks keep their number)
function S.PriestMindFlay(p)
  p:RegisterSpell(ShadowSpell({ id = 25387, flags = F.Channeled, classMask = M.MindFlay, manaCost = { flat = 230 },
    dot = S.TickDot("MindFlay-7", 3, 1, 176, C190, { affectedByCastSpeed = true, hasteReducesDuration = true }),
    applyEffects = function(sim, target, spell)
      local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHitNoHitCounter)
      if S.Landed(r) then spell:Dot(target):Apply(sim) end
    end }))
end

-- vampiric_touch.go (rank 3): 5 ticks over 15 s; while it is on the target, 5% of the damage the priest's shadow
-- spells do there comes back as mana
function S.PriestVampiricTouch(p)
  local vt = p:RegisterSpell(ShadowSpell({ id = 34917, classMask = M.VampiricTouch, manaCost = { flat = 425 },
    castTime = 1.5, dot = S.TickDot("VampiricTouch-3", 5, 3, 130, C200),
    applyEffects = function(sim, target, spell)
      local r = spell:CalcAndDealOutcome(sim, target, OUT.MagicHit)
      if S.Landed(r) then spell:Dot(target):Apply(sim) end
    end }))
  local target = p.currentTarget
  local d = vt:Dot(target)
  S.AttachProcTrigger(d.aura, target, { name = "VampiricTouch-ManaReturn", canProcFromProcs = true,
    callback = { "taken", "periodicTaken" }, classMask = M.Shadow, requireDamageDealt = true,
    handler = function(sim, _, result) p:AddMana(sim, result.damage * 0.05, "vampiric_touch_own") end })
end

-- priest.go Initialize: Mind Blast (ranks 10 and 11, one cooldown), Shadow Word: Pain / Death, Shadowfiend and the
-- racial spells
function S.PriestInitialize(p)
  local pr = p.priest
  local mbTimer = p:NewTimer()
  for _, r in ipairs({ { 25372, 380, 571, 602 }, { 25375, 450, 711, 752 } }) do
    local lo, hi = r[3], r[4]
    p:RegisterSpell(ShadowSpell({ id = r[1], classMask = M.MindBlast, manaCost = { flat = r[2] }, castTime = 1.5,
      cd = 8, cdTimer = mbTimer, bonusCoefficient = C429,
      applyEffects = function(sim, target, spell) spell:CalcAndDealDamage(sim, target, sim:Roll(lo, hi), OUT.MagicHitAndCrit) end }))
  end
  p:RegisterSpell(ShadowSpell({ id = 25368, classMask = M.ShadowWordPain, manaCost = { flat = 575 },
    dot = S.TickDot("ShadowWordPain-10", 6, 3, 206, C183),
    applyEffects = function(sim, target, spell)
      local r = spell:CalcOutcome(sim, target, OUT.MagicHitNoHitCounter)
      if S.Landed(r) then spell:Dot(target):Apply(sim) end
      spell:DealDamage(sim, r)
    end }))
  p:RegisterSpell(ShadowSpell({ id = 32996, classMask = M.ShadowWordDeath, manaCost = { flat = 309 }, cd = 12,
    bonusCoefficient = C429,
    applyEffects = function(sim, target, spell) spell:CalcAndDealDamage(sim, target, sim:Roll(572, 664), OUT.MagicHitAndCrit) end }))

  -- shadowfiend.go: the pet for 15 s (Incarnate Regalia: 18 s)
  local pet = pr.shadowfiendPet
  local sfAura = p:RegisterAura({ label = "Shadowfiend", actionId = { spellId = 34433 }, duration = 15 })
  p:RegisterSpell({ id = 34433, school = SCHOOL.Shadow, procMask = PM.Empty, flags = F.APL, classMask = M.ShadowFiend,
    manaCost = { basePct = 6 }, gcd = 1.5, cd = 300, relatedSelfBuff = sfAura,
    applyEffects = function(sim)
      pet:EnablePetWithTimeout(sim, sfAura.duration)
      sfAura:Activate(sim)
    end })

  if p.race == "NightElf" then
    -- starshards.go (rank 8): arcane, 5 ticks over 15 s
    p:RegisterSpell(ShadowSpell({ id = 25446, school = SCHOOL.Arcane, classMask = M.Starshards, cd = 30,
      manaCost = { flat = 0 }, dot = S.TickDot("Starshards-8", 5, 3, 157, C167),
      applyEffects = function(sim, target, spell)
        local r = spell:CalcOutcome(sim, target, OUT.MagicHitNoHitCounter)
        if S.Landed(r) then spell:Dot(target):Apply(sim) end
        spell:DealDamage(sim, r)
      end }))
  end
  if p.race == "Undead" then
    -- devouring_plague.go (rank 7): 8 ticks over 24 s, the first right away
    p:RegisterSpell(ShadowSpell({ id = 25467, classMask = M.DevouringPlague, cd = 180, manaCost = { flat = 1145 },
      dot = S.TickDot("DevouringPlague-7", 8, 3, 152, C100),
      applyEffects = function(sim, target, spell)
        local r = spell:CalcOutcome(sim, target, OUT.MagicHit)
        if S.Landed(r) then
          local d = spell:Dot(target)
          d:Apply(sim)
          d:TickOnce(sim)
        end
        spell:DealDamage(sim, r)
      end }))
  end

  S.PriestItems(p)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items (items.go): tier sets 4-6 and the Ashtongue Talisman of Acumen
-- ---------------------------------------------------------------------------------------------------------------
function S.PriestItems(p)
  -- Incarnate Regalia 2: Shadowfiend lasts 3 s longer (its stamina doesn't matter here); 4: Mind Flay / Smite +5%
  if p:CouldHaveSetBonus("Incarnate Regalia", 2) then
    p:AddStaticMod({ kind = "BuffDuration_Flat", value = 3, classMask = M.ShadowFiend })
  end
  if p:CouldHaveSetBonus("Incarnate Regalia", 4) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.05, classMask = M.MindFlay + M.Smite })
  end
  -- Avatar Regalia 2: 6% on a damage spell cast, the next spell costs 150 less; 4: 40% on a Shadow Word: Pain tick,
  -- +100 spell damage for the next spell
  if p:CouldHaveSetBonus("Avatar Regalia", 2) then
    local a = p:RegisterAura({ label = "Avatar Regalia 2pc Discount", actionId = { spellId = 37601 }, duration = 15,
      onCastComplete = function(aura, sim, spell) if spell.classMask ~= 0 then aura:Deactivate(sim) end end })
    a:AttachSpellMod({ kind = "PowerCost_Flat", value = -150 })
    p:MakeProcTriggerAura({ name = "Avatar Regalia 2pc", procChance = 0.06, procMask = PM.SpellDamage, callback = "cast",
      handler = function(sim) a:Activate(sim) end })
  end
  if p:CouldHaveSetBonus("Avatar Regalia", 4) then
    local a = p:RegisterAura({ label = "Avatar Regalia 4pc", actionId = { spellId = 37604 }, duration = 15,
      onCastComplete = function(aura, sim, spell) if spell.classMask ~= 0 then aura:Deactivate(sim) end end })
    a:AttachStatsBuff({ [ST.SpellDamage] = 100, [ST.HealingPower] = 100 })
    p:MakeProcTriggerAura({ name = "Avatar Regalia 4pc Trigger", procChance = 0.4, classMask = M.ShadowWordPain,
      callback = "periodic", handler = function(sim) a:Activate(sim) end })
  end
  -- Absolution Regalia 2: Shadow Word: Pain one tick longer; 4: Mind Blast +10%
  if p:CouldHaveSetBonus("Absolution Regalia", 2) then
    p:AddStaticMod({ kind = "DotNumberOfTicks_Flat", value = 1, classMask = M.ShadowWordPain })
  end
  if p:CouldHaveSetBonus("Absolution Regalia", 4) then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.10, classMask = M.MindBlast })
  end
  -- Ashtongue Talisman of Acumen: 10% on a Shadow Word: Pain tick, 220 spell damage for 10 s
  if p:IsEquipped(32490) then
    local a = p:NewTemporaryStatsAura("Ashtongue Talisman of Acumen - Proc", { [ST.SpellDamage] = 220 }, 10)
    p:MakeProcTriggerAura({ name = "Ashtongue Talisman of Acumen - Trigger", procChance = 0.1,
      classMask = M.ShadowWordPain, outcome = O.Landed, callback = "periodic", handler = function(sim) a:Activate(sim) end })
  end
end

-- Scenario hooks: Setup.lua S.NewScenario runs them in WoWSims' build order
S.RegisterClass("Priest", {
  setup = function(p, talents, opts) S.SetupPriest(p, talents, opts) end,
  applyTalents = function(p) S.PriestApplyTalents(p) end,
  initialize = function(p) S.PriestInitialize(p) end,
})

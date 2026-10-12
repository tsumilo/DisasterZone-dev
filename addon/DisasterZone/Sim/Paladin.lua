if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Paladin.lua", ...) then return end -- DisasterZone: Sim/Paladin.lua
-- ns.GearSim paladin (sim/paladin/*.go): seals with twisting, Judgement, Crusader Strike, Avenging Wrath,
-- Consecration, Exorcism, Hammer of Wrath, talents, Sanctity Aura, librams, tier sets, Tome of Fiery Redemption.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

-- Class spell masks (spell_masks.go: 1 << iota starting at 1 << 1)
local MASK_NAMES = {
  "Judgement", "Consecration", "Exorcism", "HolyLight", "FlashOfLight", "LayOnHands", "HammerOfJustice", "Cleanse",
  "DivineShield", "DivineProtection", "BlessingOfProtection", "HammerOfWrath", "HolyWrath", "AvengingWrath",
  "SealOfRighteousness", "SealOfCommand", "SealOfLight", "SealOfWisdom", "SealOfJustice", "SealOfTheCrusader",
  "SealOfBlood", "SealOfVengeance", "JudgementOfRighteousness", "JudgementOfCommand", "JudgementOfLight",
  "JudgementOfWisdom", "JudgementOfJustice", "JudgementOfTheCrusader", "JudgementOfBlood", "JudgementOfVengeance",
  "DevotionAura", "RetributionAura", "ConcentrationAura", "FireResistanceAura", "FrostResistanceAura",
  "ShadowResistanceAura", "SanctityAura", "BlessingOfMight", "BlessingOfWisdom", "BlessingOfKings",
  "BlessingOfSalvation", "BlessingOfSanctuary", "DivineFavor", "DivineIllumination", "HolyShock", "HolyShield",
  "HolyShieldProc", "AvengersShield", "CrusaderStrike", "Repentance", "RighteousFury",
}
local M = S.SpellMasks(MASK_NAMES)
M.AllSeals = M.SealOfRighteousness + M.SealOfCommand + M.SealOfLight + M.SealOfWisdom + M.SealOfJustice +
  M.SealOfTheCrusader + M.SealOfBlood + M.SealOfVengeance
M.AllJudgements = M.JudgementOfRighteousness + M.JudgementOfCommand + M.JudgementOfLight + M.JudgementOfWisdom +
  M.JudgementOfJustice + M.JudgementOfTheCrusader + M.JudgementOfBlood + M.JudgementOfVengeance
M.AllAuras = M.DevotionAura + M.RetributionAura + M.ConcentrationAura + M.FireResistanceAura + M.FrostResistanceAura +
  M.ShadowResistanceAura + M.SanctityAura
M.AllBlessings = M.BlessingOfMight + M.BlessingOfWisdom + M.BlessingOfKings + M.BlessingOfSalvation + M.BlessingOfSanctuary
M.HealingSpells = M.HolyLight + M.FlashOfLight + M.LayOnHands + M.HolyShock
M.CanProcTome = M.AllAuras + M.AllBlessings + M.AllSeals + M.AllJudgements + M.AvengersShield + M.AvengingWrath +
  M.Consecration + M.DivineFavor + M.DivineIllumination + M.Exorcism + M.HammerOfWrath + M.HealingSpells +
  M.HolyShield + M.HolyShock + M.HolyWrath + M.RighteousFury
S.PALADIN_MASK = M

-- Talents in WoWSims/Wowhead order (proto/paladin.proto PaladinTalents): 20 holy, 22 protection, 22 retribution.
local TALENTS = {
  { "DivineStrength", "DivineIntellect", "SpiritualFocus", "ImprovedSealOfRighteousness", "HealingLight", "AuraMastery",
    "ImprovedLayOnHands", "UnyieldingFaith", "Illumination", "ImprovedBlessingOfWisdom", "PureOfHeart", "DivineFavor",
    "SanctifiedLight", "PurifyingPower", "HolyPower", "LightsGrace", "HolyShock", "BlessedLife", "HolyGuidance",
    "DivineIllumination" },
  { "ImprovedDevotionAura", "Redoubt", "Precision", "GuardiansFavor", "Toughness", "BlessingOfKings",
    "ImprovedRighteousFury", "ShieldSpecialization", "Anticipation", "Stoicism", "ImprovedHammerOfJustice",
    "ImprovedConcentrationAura", "SpellWarding", "BlessingOfSanctuary", "Reckoning", "SacredDuty",
    "OneHandedWeaponSpecialization", "ImprovedHolyShield", "HolyShield", "ArdentDefender", "CombatExpertise",
    "AvengersShield" },
  { "ImprovedBlessingOfMight", "Benediction", "ImprovedJudgement", "ImprovedSealOfTheCrusader", "Deflection",
    "Vindication", "Conviction", "SealOfCommand", "PursuitOfJustice", "EyeForAnEye", "ImprovedRetributionAura",
    "Crusade", "TwoHandedWeaponSpecialization", "SanctityAura", "ImprovedSanctityAura", "Vengeance",
    "SanctifiedJudgement", "SanctifiedSeals", "Repentance", "DivinePurpose", "Fanaticism", "CrusaderStrike" },
}
S.PALADIN_TALENTS = TALENTS

function S.ParsePaladinTalents(str)
  local t = {}
  for _, tree in ipairs(TALENTS) do for _, n in ipairs(tree) do t[n] = 0 end end
  local trees = {}
  for part in (str .. "-"):gmatch("([^%-]*)%-") do trees[#trees + 1] = part end
  for ti, tree in ipairs(TALENTS) do
    local s = trees[ti] or ""
    for i = 1, #s do
      local name = tree[i]
      if name then t[name] = tonumber(s:sub(i, i)) or 0 end
    end
  end
  return t
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spell data (spell_data_auto_gen.go)
-- ---------------------------------------------------------------------------------------------------------------
local SOC_RANKS = {
  { id = 20375, cost = 65, judgeId = 20425, jmin = 137, jmax = 146 },
  { id = 20915, cost = 110, judgeId = 20962, jmin = 194, jmax = 209 },
  { id = 20918, cost = 140, judgeId = 20961, jmin = 248, jmax = 269 },
  { id = 20919, cost = 180, judgeId = 20967, jmin = 309, jmax = 336 },
  { id = 20920, cost = 210, judgeId = 20968, jmin = 387, jmax = 422 },
  { id = 27170, cost = 280, judgeId = 27172, jmin = 456, jmax = 504 },
}
local SOTC_R7 = { id = 27158, cost = 210, ap = 495, judgeId = 27159 }
local EXORCISM = { [7] = { id = 27138, cost = 340, min = 626, max = 698 } }
local HOW = { [4] = { id = 27180, cost = 440, min = 672, max = 742 } }
local CONSECRATION = {
  { id = 26573, cost = 120, tick = 8 }, { id = 20116, cost = 205, tick = 15 }, { id = 20922, cost = 290, tick = 24 },
  { id = 20923, cost = 390, tick = 35 }, { id = 20924, cost = 505, tick = 48 }, { id = 27173, cost = 660, tick = 64 },
}
local JUDGE_COEF = 0.42899999022483826

-- ---------------------------------------------------------------------------------------------------------------
-- Paladin
-- ---------------------------------------------------------------------------------------------------------------
-- p: the player unit after S.NewCharacter (gear, buffs and base stats are added there).
function S.SetupPaladin(p, talentsStr)
  local T = S.ParsePaladinTalents(talentsStr)
  p.talents = T
  p.paladin = { judgementAuras = {} }
  local pal = p.paladin

  p.ps.CanParry = true
  -- Str -> AP x2, Agi -> crit (CritPerAgiMaxLevel[Paladin]); dodge / armor deps don't affect damage.
  p:AddStatDependency(ST.Strength, ST.AttackPower, 2)
  p:AddStatDependency(ST.Agility, ST.PhysicalCritPercent, S.CRIT_PER_AGI.Paladin)
  p:AddStatDependency(ST.BonusArmor, ST.Armor, 1)

  -- Forbearance
  pal.forbearance = p:RegisterAura({ label = "Forbearance", duration = 60 })

  S.PaladinRegisterSpells(p, T)
  S.PaladinApplyTalents(p, T)
  return p
end

local function Twistable(a) a.twist = true; return a end

-- seals.go applySeal: recasting refreshes; switching away from Command/Righteousness keeps the old seal for 399 ms.
local function ApplySeal(p, sim, newSeal, sealSpell, judgement)
  local pal = p.paladin
  local cur = pal.currentSeal
  if cur and cur.sealId == newSeal.sealId then
    cur:Activate(sim)
    return
  end
  if cur and cur.active then
    if cur.twist then
      pal.previousSealSpell = pal.currentSealSpell
      pal.previousSeal = cur
      pal.previousJudgement = pal.currentJudgement
      -- Go stores the NEW seal spell as PreviousSealSpell (Sanctified Judgement refunds by it).
      pal.previousSealSpell = sealSpell
      -- Go's closure reads PreviousSeal when it fires, not when it was scheduled.
      sim:Add({ at = sim.now + 0.399, prio = S.PRIO_LOW, fn = function(s) pal.previousSeal:Deactivate(s) end })
    else
      cur:Deactivate(sim)
    end
  end
  pal.currentSealSpell = sealSpell
  pal.currentSeal = newSeal
  pal.currentJudgement = judgement
  newSeal:Activate(sim)
end

local function SealCastSpell(p, id, rank, mask, cost, aura, judge)
  local spell
  spell = p:RegisterSpell({
    id = id, rank = rank, classMask = mask, school = SCHOOL.Holy, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.APL, damageMultiplier = 1, threatMultiplier = 1, manaCost = { flat = cost }, gcd = 1.5,
    applyEffects = function(sim, _, sp) ApplySeal(p, sim, aura, sp, judge) end,
  })
  return spell
end

function S.PaladinRegisterSpells(p, T)
  local pal = p.paladin
  local aa = p.autoAttacks

  -- Judgement (judgement.go)
  pal.judgement = p:RegisterSpell({
    id = 20271, classMask = M.Judgement, school = SCHOOL.Holy, procMask = PM.Empty,
    flags = F.MeleeMetrics + F.APL + F.PassiveSpell + F.NoOnCastComplete, damageMultiplier = 1, threatMultiplier = 1,
    nonEmpty = true, cd = 10, manaCost = { basePct = 5 },
    extraCastCondition = function()
      return (pal.currentSeal and pal.currentSeal.active) or (pal.previousSeal and pal.previousSeal.active)
    end,
    applyEffects = function(sim, target, spell)
      if pal.previousSeal and pal.previousSeal.active then
        pal.previousJudgement:Cast(sim, target)
        pal.previousSeal:Deactivate(sim)
      else
        pal.currentJudgement:Cast(sim, target)
        pal.currentSeal:Deactivate(sim)
      end
      sim:Add({ at = sim.now + spell:TimeToReady(sim) + S.SPELL_BATCH, prio = 0, fn = function(s)
        p:ReactToEvent(s, false, false)
      end })
    end,
  })

  -- Seal of Command, every rank (talent)
  if T.SealOfCommand > 0 then
    for rank, r in ipairs(SOC_RANKS) do
      local judge = p:RegisterSpell({
        id = "judge_soc_" .. rank, classMask = M.JudgementOfCommand, school = SCHOOL.Holy, defenseType = S.DEF_MELEE,
        procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics, damageMultiplier = 1, threatMultiplier = 1,
        bonusCoefficient = JUDGE_COEF, metricsKey = "judge_soc",
        applyEffects = function(sim, target, spell)
          local base = sim:Roll(r.jmin, r.jmax)
          if not target.ps.Stunned then base = base / 2 end
          local res = spell:CalcDamage(sim, target, base, OUT.MeleeSpecialCritOnly)
          spell:DealDamageBatched(sim, res)
        end,
      })
      local proc = p:RegisterSpell({
        id = "soc_proc_" .. rank, metricsKey = "soc_proc", classMask = M.SealOfCommand, school = SCHOOL.Holy,
        defenseType = S.DEF_MELEE, procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics + F.PassiveSpell,
        damageMultiplier = 1, threatMultiplier = 1, bonusCoefficient = 0.29,
        applyEffects = function(sim, target, spell)
          local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target)) * 0.70
          local res = spell:CalcDamage(sim, target, base, OUT.MeleeSpecialHitAndCrit)
          spell:DealDamageBatched(sim, res)
        end,
      })
      local aura = Twistable(p:RegisterAura({ label = "Seal of Command " .. rank, duration = 30, sealId = "soc" .. rank }))
      S.AttachProcTrigger(aura, p, {
        name = "Seal of Command " .. rank, outcome = O.Landed, procMask = PM.MeleeWhiteHit, callback = "hit", icd = 1,
        dpm = S.NewPPM(p, 7, PM.MeleeWhiteHit),
        handler = function(sim, _, result) proc:Cast(sim, result.target) end,
      })
      pal["soc" .. rank] = { aura = aura, judge = judge, proc = proc }
      pal["socSpell" .. rank] = SealCastSpell(p, r.id, rank, M.SealOfCommand, r.cost, aura, judge)
      p.auraById[r.id .. ":" .. rank] = aura
      p.auraById[r.id] = p.auraById[r.id] or aura
    end
  end

  -- Seal of the Crusader rank 7
  do
    local percentBonus = p:CouldHaveSetBonus("Justicar Battlegear", 2) and 1.15 or 1
    local flatBonus = 0
    local ranged = p.gearIds and p.gearIds.Ranged
    if ranged == 23203 then flatBonus = 33 elseif ranged == 27949 or ranged == 27983 then flatBonus = 47 end
    local target = p.currentTarget
    local jotc = S.ImprovedSealOfTheCrusaderAura(target, 1, T.ImprovedSealOfTheCrusader, flatBonus, percentBonus)
    pal.judgementAuras[#pal.judgementAuras + 1] = jotc
    local judge = p:RegisterSpell({
      id = SOTC_R7.judgeId, classMask = M.JudgementOfTheCrusader, school = SCHOOL.Holy, defenseType = S.DEF_MAGIC,
      procMask = PM.Empty, flags = F.MeleeMetrics + F.Binary, damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, tgt, spell)
        spell:CalcAndDealOutcome(sim, tgt, OUT.AlwaysHit)
        jotc:Activate(sim)
      end,
    })
    local aura = p:RegisterAura({ label = "Seal of the Crusader 7", duration = 30, sealId = "sotc7" })
    aura:AttachMultiplyMeleeSpeed(1.4)
    aura:AttachSpellMod({ procMask = PM.MeleeMHAuto, kind = "DamageDone_Flat", value = -0.4 })
    aura:AttachStatBuff(ST.AttackPower, SOTC_R7.ap)
    pal.sotcAura = aura
    pal.sotcSpell = SealCastSpell(p, SOTC_R7.id, 7, M.SealOfTheCrusader, SOTC_R7.cost, aura, judge)
    p.auraById[SOTC_R7.id] = aura
  end

  -- Seal of Blood
  do
    local judge = p:RegisterSpell({
      id = 31898, classMask = M.JudgementOfBlood, school = SCHOOL.Holy, defenseType = S.DEF_MELEE,
      procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics, damageMultiplier = 1, threatMultiplier = 1,
      bonusCoefficient = 0.429,
      applyEffects = function(sim, target, spell)
        local res = spell:CalcDamage(sim, target, sim:Roll(295, 325), OUT.MeleeSpecialCritOnly)
        spell:DealDamageBatched(sim, res)
      end,
    })
    local proc = p:RegisterSpell({
      id = 31893, classMask = M.SealOfBlood, school = SCHOOL.Holy, defenseType = S.DEF_MELEE,
      procMask = PM.MeleeMHSpecial, flags = F.MeleeMetrics + F.PassiveSpell + F.Proc + F.SuppressWeaponProcs,
      damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target)) * 0.35
        local res = spell:CalcDamage(sim, target, base, OUT.MeleeSpecialHitAndCrit)
        spell:DealDamageBatched(sim, res)
      end,
    })
    local aura = p:RegisterAura({ label = "Seal of Blood", duration = 30, sealId = "sob" })
    S.AttachProcTrigger(aura, p, {
      name = "Seal of Blood", callback = "hit", outcome = O.Landed,
      handler = function(sim, spell, result)
        if not has(spell.procMask, PM.MeleeWhiteHit) and not has(spell.classMask, M.SealOfCommand) then return end
        proc:Cast(sim, result.target)
      end,
    })
    pal.sobAura = aura
    pal.sobSpell = SealCastSpell(p, 31892, nil, M.SealOfBlood, 210, aura, judge)
    p.auraById[31892] = aura
  end

  -- Crusader Strike (talent)
  if T.CrusaderStrike > 0 then
    pal.cs = p:RegisterSpell({
      id = 35395, classMask = M.CrusaderStrike, school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
      procMask = PM.MeleeMHSpecial, flags = F.APL + F.MeleeMetrics + F.NoOnCastComplete,
      ignoreHaste = true, gcd = 1.5, cd = 6, manaCost = { basePct = 8 }, damageMultiplier = 1.1, threatMultiplier = 1,
      applyEffects = function(sim, target, spell)
        local base = S.WeaponNormalizedDamage(aa.mh, sim, spell:MeleeAttackPower(target))
        local res = spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWeaponSpecialHitAndCrit)
        if S.Landed(res) then
          for _, ja in ipairs(pal.judgementAuras) do
            if ja.active then ja:Refresh(sim) end
          end
        end
      end,
    })
  end

  -- Avenging Wrath (major cooldown)
  do
    local aura = p:RegisterAura({ label = "Avenging Wrath", duration = 20 })
    aura:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", 1.3)
    local spell = p:RegisterSpell({
      id = 31884, classMask = M.AvengingWrath, school = SCHOOL.Holy, procMask = PM.Empty, flags = F.APL,
      nonEmpty = true, cd = 180, manaCost = { basePct = 8 },
      extraCastCondition = function() return not p.paladin.forbearance.active end,
      applyEffects = function(sim)
        aura:Activate(sim)
        p.paladin.forbearance:Activate(sim)
      end,
    })
    pal.awAura = aura
    p.auraById[31884] = aura
    p:AddMajorCooldown({ spell = spell, priority = 4 }) -- int32(CooldownTypeDPS)
  end

  -- Exorcism rank 7 (undead / demon targets only)
  do
    local r = EXORCISM[7]
    p:RegisterSpell({
      id = r.id, rank = 7, classMask = M.Exorcism, school = SCHOOL.Holy, defenseType = S.DEF_MAGIC,
      procMask = PM.SpellDamage, flags = F.APL, damageMultiplier = 1, threatMultiplier = 1,
      manaCost = { flat = r.cost }, gcd = 1.5, cd = 15, bonusCoefficient = JUDGE_COEF,
      extraCastCondition = function(_, target) return target.mobType == "Undead" or target.mobType == "Demon" end,
      applyEffects = function(sim, target, spell)
        spell:CalcAndDealDamage(sim, target, sim:Roll(r.min, r.max), OUT.MagicHitAndCrit)
      end,
    })
  end

  -- Hammer of Wrath rank 4 (execute)
  do
    local r = HOW[4]
    p:RegisterSpell({
      id = r.id, rank = 4, classMask = M.HammerOfWrath, school = SCHOOL.Holy, defenseType = S.DEF_RANGED,
      procMask = PM.RangedSpecial, flags = F.APL, damageMultiplier = 1, threatMultiplier = 1,
      manaCost = { flat = r.cost }, gcd = 0.5, gcdMin = 0.5, castTime = 0.5, cd = 6, bonusCoefficient = JUDGE_COEF,
      modifyCast = function(sim, spell, gcd, castTime)
        local ct = p:ApplyCastSpeed(castTime)
        aa:StopMeleeUntil(sim, sim.now + ct)
        return gcd, castTime
      end,
      extraCastCondition = function(sim) return sim:IsExecute20() end,
      applyEffects = function(sim, target, spell)
        local res = spell:CalcDamage(sim, target, sim:Roll(r.min, r.max), OUT.RangedHitAndCrit)
        S.Travel(p, sim, 35, function(s) spell:DealDamage(s, res) end)
      end,
    })
  end

  -- Consecration, every rank (8 s ground effect, an immediate tick + 7 more each second)
  for rank, r in ipairs(CONSECRATION) do
    local spell
    spell = p:RegisterSpell({
      id = r.id, rank = rank, classMask = M.Consecration, school = SCHOOL.Holy, defenseType = S.DEF_MAGIC,
      procMask = PM.SpellDamage, flags = F.APL, damageMultiplier = 1, threatMultiplier = 1,
      manaCost = { flat = r.cost }, gcd = 1.5, cd = 8, cdTimer = p.consecrationTimer,
      applyEffects = function(sim, target, sp)
        sp:CalcAndDealOutcome(sim, target, OUT.MagicHit)
        S.ConsecrationTicks(p, sim, sp, r.tick)
      end,
    })
    if not p.consecrationTimer then p.consecrationTimer = spell.cdTimer end
  end
end

-- Consecration ticks: periodic AoE damage, coefficient 0.119 per tick, magic hit per tick.
function S.ConsecrationTicks(p, sim, spell, tickDmg)
  local coef = 0.11900000274181366
  local function tick(s)
    for _, t in ipairs(s.targets) do
      local at = p.attackTables[t]
      local mult = spell:AttackerDamageMultiplier(at, true)
      local base = tickDmg + coef * spell:BonusDamage(at) -- BonusDamage includes BonusBaseDamage (librams)
      local res = spell:CalcDamageInternal(s, t, base, mult, true, function(sp, sm, r, a)
        if sm:Proc(1 - sp:SpellChanceToMiss(a)) then r.outcome = O.Hit else r.outcome = O.Miss; r.damage = 0 end
      end)
      spell:DealPeriodicDamage(s, res)
    end
  end
  tick(sim)
  for i = 1, 7 do
    sim:Add({ at = sim.now + i, prio = S.PRIO_DOT, fn = tick })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Talents (talents.go): only the ones with an effect on damage, mana or the rotation.
-- ---------------------------------------------------------------------------------------------------------------
function S.PaladinApplyTalents(p, T)
  local pal = p.paladin
  if T.SanctityAura > 0 then
    local aura = S.SanctityAuraBuff(p, true, T.ImprovedSanctityAura)
    p:RegisterSpell({
      id = 20218, classMask = M.SanctityAura, school = SCHOOL.Holy, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
      flags = F.APL + F.Helpful, gcd = 1.5,
      applyEffects = function(sim) aura:Activate(sim) end,
    })
    p.auraById[20218] = aura
  end
  if T.DivineStrength > 0 then p:MultiplyStat(ST.Strength, 1 + T.DivineStrength * 0.02) end
  if T.DivineIntellect > 0 then p:MultiplyStat(ST.Intellect, 1 + 0.02 * T.DivineIntellect) end
  if T.ImprovedSealOfRighteousness > 0 then
    p:AddStaticMod({ kind = "DamageDone_Flat", value = 0.03 * T.ImprovedSealOfRighteousness,
      classMask = M.SealOfRighteousness + M.JudgementOfRighteousness })
  end
  if T.PurifyingPower > 0 then
    p:AddStaticMod({ kind = "PowerCost_Pct_Add", value = -0.05 * T.PurifyingPower, classMask = M.Consecration })
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 10 * T.PurifyingPower, classMask = M.Exorcism + M.HolyWrath })
  end
  if T.HolyPower > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = T.HolyPower, school = SCHOOL.Holy })
  end
  if T.HolyGuidance > 0 then
    p:AddStatDependency(ST.Intellect, ST.SpellDamage, 0.07 * T.HolyGuidance)
  end
  if T.Precision > 0 then
    p:AddStat(ST.SpellHitPercent, T.Precision)
    p:AddStat(ST.PhysicalHitPercent, T.Precision)
    p:AddStaticMod({ kind = "BonusHit_Percent", value = -T.Precision, classMask = M.AvengersShield + M.HammerOfWrath })
  end
  if T.CombatExpertise > 0 then
    p:AddStat(ST.ExpertiseRating, T.CombatExpertise * S.EXPERTISE_PER_QUARTER)
  end
  if T.OneHandedWeaponSpecialization > 0 then
    p:AddStaticMod({ kind = "DamageDone_Pct", value = 0.01 * T.OneHandedWeaponSpecialization })
  end
  if T.Benediction > 0 then
    p:AddStaticMod({ classMask = M.AllSeals + M.Judgement, kind = "PowerCost_Pct_Add", value = -0.03 * T.Benediction })
  end
  if T.ImprovedJudgement > 0 then
    p:AddStaticMod({ classMask = M.Judgement, kind = "Cooldown_Flat", value = -T.ImprovedJudgement })
  end
  if T.Conviction > 0 then p:AddStat(ST.PhysicalCritPercent, T.Conviction) end
  if T.Crusade > 0 then
    p.postFinalize[#p.postFinalize + 1] = function()
      for t, at in pairs(p.attackTables) do
        local mt = t.mobType
        if mt == "Demon" or mt == "Humanoid" or mt == "Undead" or mt == "Elemental" then
          at.damageDealtMultiplier = at.damageDealtMultiplier * (1 + 0.01 * T.Crusade)
        end
      end
    end
  end
  if T.TwoHandedWeaponSpecialization > 0 then
    local mod = p:AddDynamicMod({ kind = "DamageDone_Pct", procMask = PM.Melee, value = 0.02 * T.TwoHandedWeaponSpecialization })
    if p.autoAttacks.mh.twoHand then mod:Activate() end
  end
  if T.Vengeance > 0 then
    local bonus = 0.01 * T.Vengeance
    local mod = p:AddDynamicMod({ kind = "DamageDone_Pct", value = bonus, school = SCHOOL.Holy + SCHOOL.Physical })
    local aura = p:RegisterAura({
      label = "Vengeance", duration = 30, maxStacks = 3,
      onGain = function() mod:Activate() end,
      onExpire = function() mod:Deactivate() end,
      onStacksChange = function(_, _, _, n) mod:UpdateValue(bonus * n) end,
    })
    p:MakeProcTriggerAura({
      name = "Vengeance - Trigger", callback = "hit", outcome = O.Crit, procChance = 1, canProcFromProcs = true,
      handler = function(sim)
        aura:Activate(sim)
        aura:AddStack(sim)
      end,
    })
    pal.vengeance = aura
  end
  if T.SanctifiedJudgement > 0 then
    local chance = ({ 0.33, 0.66, 1 })[T.SanctifiedJudgement]
    p:MakeProcTriggerAura({
      name = "Sanctified Judgement - Trigger", classMask = M.AllJudgements, callback = "hit", procChance = chance,
      triggerImmediately = true,
      handler = function(sim)
        if pal.previousSeal and pal.previousSeal.active then
          p:AddMana(sim, (pal.previousSealSpell.curCost or 0) * 0.8, "sanctified_judgement")
        else
          p:AddMana(sim, (pal.currentSealSpell.curCost or 0) * 0.8, "sanctified_judgement")
        end
      end,
    })
  end
  if T.SanctifiedSeals > 0 then
    p:AddStat(ST.PhysicalCritPercent, T.SanctifiedSeals)
    p:AddStat(ST.SpellCritPercent, T.SanctifiedSeals)
  end
  if T.Fanaticism > 0 then
    p:AddStaticMod({ kind = "BonusCrit_Percent", value = 3 * T.Fanaticism, classMask = M.AllJudgements })
  end

  -- Spiritual Attunement (spiritual_attunement.go): 10% of damage taken back as mana.
  p:MakeProcTriggerAura({
    name = "Spiritual Attunement", canProcFromProcs = true, callback = "taken", requireDamageDealt = true,
    handler = function(sim, _, result)
      local coeff = 0.10
      if pal.t6ProtAura and pal.t6ProtAura.active then coeff = coeff * 1.1 end
      p:AddMana(sim, result.damage * coeff, "spiritual_attunement")
    end,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Paladin items: librams, tier sets, Tome of Fiery Redemption (item_librams.go, item_sets.go, item_trinkets.go)
-- ---------------------------------------------------------------------------------------------------------------
S.ITEM_EFFECTS = S.ITEM_EFFECTS or {}
local IE = S.ITEM_EFFECTS

local function Permanent(p, label, cfgFn)
  local a = S.MakePermanent(p:RegisterAura({ label = label }))
  if cfgFn then cfgFn(a) end
  return a
end

-- Libram of Avengement: Judgement of Command / Righteousness / Blood / Vengeance hits grant 53 crit rating for 5 s.
IE[27484] = function(p)
  local buff = p:NewTemporaryStatsAura("Justice", { [ST.MeleeCritRating] = 53, [ST.SpellCritRating] = 53 }, 5)
  local a = Permanent(p, "Libram of Avengement")
  S.AttachProcTrigger(a, p, { callback = "hit",
    classMask = M.JudgementOfCommand + M.JudgementOfRighteousness + M.JudgementOfBlood + M.JudgementOfVengeance,
    handler = function(sim) buff:Activate(sim) end })
end
-- Libram of Hope: seals cost 20 less.
IE[22401] = function(p)
  Permanent(p, "Libram of Hope", function(a) a:AttachSpellMod({ classMask = M.AllSeals, kind = "PowerCost_Flat", value = -20 }) end)
end
-- Libram of Fervor / Zeal: +AP while Seal of the Crusader is up (the judgement bonus is in the JotC aura).
local function ZealLibram(ap, label)
  return function(p)
    local buff = p:NewTemporaryStatsAura(label, { [ST.AttackPower] = ap }, huge)
    local sotc = p.paladin.sotcAura
    local og, oe = sotc.onGain, sotc.onExpire
    sotc.onGain = function(a, sim) if og then og(a, sim) end buff:Activate(sim) end
    sotc.onExpire = function(a, sim) if oe then oe(a, sim) end buff:Deactivate(sim) end
  end
end
IE[23203] = ZealLibram(48, "Libram of Fervor")
IE[27949] = ZealLibram(68, "Libram of Zeal")
IE[27983] = ZealLibram(68, "Libram of Zeal")
-- Libram of the Eternal Rest: Consecration +47 (scaled by its own coefficient).
IE[27917] = function(p)
  local coef = 0.09525 / 0.11900000274181366
  Permanent(p, "Libram of the Eternal Rest", function(a)
    a:AttachSpellMod({ classMask = M.Consecration, kind = "BaseDamage_Flat", value = 47 * coef })
  end)
end
-- Libram of Wracking: Exorcism and Holy Wrath +120.
IE[28065] = function(p)
  Permanent(p, "Libram of Wracking", function(a)
    a:AttachSpellMod({ classMask = M.Exorcism + M.HolyWrath, kind = "BaseDamage_Flat", value = 120 })
  end)
end
-- Libram of Righteous Power: Crusader Strike +36.
IE[31033] = function(p)
  Permanent(p, "Libram of Righteous Power", function(a)
    a:AttachSpellMod({ classMask = M.CrusaderStrike, kind = "BaseDamage_Flat", value = 36 })
  end)
end
-- Libram of Divine Judgement: Judgement of Command has a 40% chance to grant 200 AP for 10 s.
IE[33503] = function(p)
  local buff = p:NewTemporaryStatsAura("Crusader's Command", { [ST.AttackPower] = 200 }, 10)
  local a = Permanent(p, "Libram of Divine Judgement")
  S.AttachProcTrigger(a, p, { callback = "hit", classMask = M.JudgementOfCommand, procChance = 0.4,
    handler = function(sim) buff:Activate(sim) end })
end
-- Libram of Divine Purpose: Seal / Judgement of Righteousness +94.
IE[33504] = function(p)
  Permanent(p, "Libram of Divine Purpose", function(a)
    a:AttachSpellMod({ classMask = M.SealOfRighteousness + M.JudgementOfRighteousness, kind = "BaseDamage_Flat", value = 94 })
  end)
end
-- Tome of Fiery Redemption: 15% on casting a non-physical class spell, 290 spell damage for 15 s, 45 s ICD.
IE[30447] = function(p)
  local buff = p:NewTemporaryStatsAura("Blessing of Righteousness", { [ST.SpellDamage] = 290 }, 15)
  p:MakeProcTriggerAura({ name = "Tome of Fiery Redemption", canProcFromProcs = true, callback = "cast",
    classMask = M.CanProcTome, procChance = 0.15, icd = 45,
    extraCondition = function(sim, spell)
      return sim.now >= 0 and not has(spell.school or 0, SCHOOL.Physical) and
        (not has(spell.classMask, M.AllSeals) or has(spell.flags, F.APL))
    end,
    handler = function(sim) buff:Activate(sim) end })
end

S.SetBonus("Justicar Battlegear", {
  [2] = function() end, -- in the Judgement of the Crusader aura
  [4] = function(p, a) a:AttachSpellMod({ kind = "DamageDone_Flat", value = 0.10, classMask = M.JudgementOfCommand }) end,
})
S.SetBonus("Crystalforge Battlegear", {
  [2] = function(p, a) a:AttachSpellMod({ kind = "PowerCost_Flat", classMask = M.Judgement, value = -35 }) end,
  [4] = function() end, -- a party heal
})
S.SetBonus("Lightbringer Battlegear", {
  [2] = function(p, a)
    S.AttachProcTrigger(a, p, { name = "Mana Regen Proc", callback = "hit", procMask = PM.Melee, procChance = 0.20,
      handler = function(sim) p:AddMana(sim, 50, "t6") end })
  end,
  [4] = function(p, a) a:AttachSpellMod({ kind = "DamageDone_Flat", classMask = M.HammerOfWrath, value = 0.10 }) end,
})
S.SetBonus("Justicar Armor", {
  [2] = function(p, a) a:AttachSpellMod({ kind = "DamageDone_Flat", value = 0.10,
    classMask = M.SealOfRighteousness + M.SealOfVengeance + M.SealOfBlood }) end,
})
S.SetBonus("Lightbringer Armor", {
  [2] = function(p, a) p.paladin.t6ProtAura = a end,
  [4] = function(p, a) a:AttachSpellMod({ kind = "DamageDone_Flat", value = 0.10, classMask = M.Consecration }) end,
})

-- APL lookups: castSpell / auraIsActive by { spellId, rank }.
function S.PaladinResolveSpell(p, ref)
  local id, rank = ref.spellId, ref.rank
  for _, sp in ipairs(p.spellbook) do
    if sp.id == id and (not rank or rank == 0 or not sp.rank or sp.rank == rank) then return sp end
  end
  for _, sp in ipairs(p.spellbook) do if sp.id == id then return sp end end
  return nil
end

function S.PaladinResolveAura(p, ref)
  local id, rank = ref.spellId, ref.rank
  return p.auraById[id .. ":" .. (rank or 0)] or p.auraById[id]
end

-- ---------------------------------------------------------------------------------------------------------------
-- Scenario hooks (Setup.lua S.NewScenario calls them in WoWSims' build order)
-- ---------------------------------------------------------------------------------------------------------------
S.RegisterClass("Paladin", {
  order = "afterRacials", -- paladin.go: the constructor (and its talents) after the racials
  setup = function(p, talents) S.SetupPaladin(p, talents) end,
  resolveSpell = function(p, ref) return S.PaladinResolveSpell(p, ref) end,
  resolveAura = function(p, ref) return S.PaladinResolveAura(p, ref) end,
})

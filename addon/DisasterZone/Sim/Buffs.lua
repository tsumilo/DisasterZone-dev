if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Buffs.lua", ...) then return end -- DisasterZone: Sim/Buffs.lua
-- ns.GearSim raid buffs, debuffs, consumables, racials and weapon enchants (buffs.go, debuffs.go, consumes.go,
-- racials.go, common/tbc/enchants.go). Spec with the exact numbers: dev/tools/gearsim/notes/buffs_spec.md.
-- Permanent stat buffs are added as build-phase stats (same totals as WoWSims' auras switched on at reset);
-- anything with a timeline (Grace of Air twisting, Sunder -> Expose Armor, Expose Weakness, Windfury, Bloodlust,
-- drums, potions, explosives) is simulated.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

-- Periodic action started at reset (StartPeriodicAction): first run at reset time + period.
local function Periodic(p, period, prio, fn, numTicks, immediately)
  p:RegisterResetEffect(function(sim)
    local n = 0
    local pa
    pa = { at = (immediately and 0 or period), prio = prio or 0, fn = function(s)
      n = n + 1
      fn(s)
      if not numTicks or n < numTicks then
        pa.at = s.now + period
        s:Add(pa)
      end
    end }
    sim:Add(pa)
  end)
end
S.Periodic = Periodic

-- Starts a periodic action now (core.StartPeriodicAction): first run after one period.
function S.StartPeriodicAction(sim, o)
  local n = 0
  local pa
  pa = { at = sim.now + (o.tickImmediately and 0 or o.period), prio = o.prio or 0, fn = function(s)
    n = n + 1
    o.onAction(s)
    if not o.numTicks or n < o.numTicks then
      pa.at = s.now + o.period
      s:Add(pa)
    end
  end }
  sim:Add(pa)
  return pa
end

-- ---------------------------------------------------------------------------------------------------------------
-- Shared aura builders used by the class code
-- ---------------------------------------------------------------------------------------------------------------
-- buffs.go SanctityAuraBuff: holy x1.1, improved: all damage x(1 + 1% per rank); one Sanctity Aura at a time.
function S.SanctityAuraBuff(p, isPlayer, impRank)
  local a = p:RegisterAura({ label = "Sanctity Aura " .. (isPlayer and "Player" or "External"), duration = huge })
  a:AttachMultiplicativePseudoStatBuff("SchoolDamageDealtMultiplier", 1.1, S.SCHOOL_INDEX[SCHOOL.Holy])
  if impRank > 0 then a:AttachMultiplicativePseudoStatBuff("DamageDealtMultiplier", 1 + 0.01 * impRank) end
  a:NewExclusiveEffect("SanctityAura", true, isPlayer and 1 or 0)
  return a
end

-- debuffs.go ImprovedSealOfTheCrusaderAura (on the target)
function S.ImprovedSealOfTheCrusaderAura(target, casterIndex, points, flatBonus, percentBonus)
  local bonus = 219 * percentBonus + flatBonus
  local label = "Improved Seal of the Crusader " .. (casterIndex == -1 and "External" or "Self")
  local a = target:GetAura(label) or target:RegisterAura({ label = label, duration = 20 })
  local holy = S.SCHOOL_INDEX[SCHOOL.Holy]
  a:NewExclusiveEffect("Improved Seal of the Crusader", true, bonus + casterIndex,
    function()
      target.ps.ReducedCritTakenPercent = target.ps.ReducedCritTakenPercent - points
      target.ps.SchoolBonusSpellDamage[holy] = target.ps.SchoolBonusSpellDamage[holy] + bonus
    end,
    function()
      target.ps.ReducedCritTakenPercent = target.ps.ReducedCritTakenPercent + points
      target.ps.SchoolBonusSpellDamage[holy] = target.ps.SchoolBonusSpellDamage[holy] - bonus
    end)
  return a
end

-- ---------------------------------------------------------------------------------------------------------------
-- Buff configuration. Keys follow WoWSims' proto field names; tristates are 0 (missing), 1 (regular), 2 (improved).
-- ---------------------------------------------------------------------------------------------------------------
S.BUFF_PRESETS = {
  -- The WoWSims Retribution preset (ui/specs/paladin/retribution/presets.ts), P1 settings.
  wowsims_ret = {
    raid = { bloodlust = true, divineSpirit = 2, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2,
      shadowProtection = true, thorns = 2 },
    party = { manaSpringTotem = 1, leaderOfThePack = 2, battleShout = 2, strengthOfEarthTotem = 2, totemTwisting = true,
      windfuryTotem = 2, graceOfAirTotem = 2, drums = "LesserDrumsOfBattle", sanctityAura = 0 },
    individual = { blessingOfKings = true, blessingOfWisdom = 2, blessingOfMight = 2, unleashedRage = true },
    debuffs = { misery = true, curseOfElements = 2, improvedSealOfTheCrusader = 2, jocRetribution2Pt4 = true,
      judgementOfWisdom = true, bloodFrenzy = true, huntersMark = 2, curseOfRecklessness = true, sunderArmor = true,
      faerieFire = 2, exposeArmor = 2, exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1080 },
    consumables = { potId = 22838, flaskId = 22854, foodId = 27658, conjuredId = 12662, superSapper = true,
      goblinSapper = true, scrollAgi = true, scrollStr = true, explosiveId = 30217 },
  },
  -- The WoWSims Warrior preset (ui/specs/warrior/shared/presets.ts, dps/presets.ts P1): the warrior shouts himself.
  wowsims_warrior = {
    raid = { bloodlust = true, powerWordFortitude = 2, giftOfTheWild = 2 },
    party = { ferociousInspiration = 2, braidedEterniumChain = true, graceOfAirTotem = 2, strengthOfEarthTotem = 2,
      windfuryTotem = 2, leaderOfThePack = 1, totemTwisting = true, drums = "LesserDrumsOfBattle" },
    individual = { blessingOfKings = true, blessingOfMight = 2, unleashedRage = true },
    debuffs = { exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1080, improvedSealOfTheCrusader = 2,
      misery = true, bloodFrenzy = true, giftOfArthas = true, mangle = true, exposeArmor = 2, faerieFire = 2,
      sunderArmor = true, curseOfRecklessness = true, huntersMark = 2 },
    consumables = { potId = 22838, flaskId = 22854, foodId = 27658, conjuredId = 22788, explosiveId = 30217,
      superSapper = true, goblinSapper = true, ohImbueId = 29453, scrollAgi = true, scrollStr = true },
  },
}

-- Static consumable data (assets/database/db.json)
local FLASKS = { [22854] = { [ST.AttackPower] = 120, [ST.RangedAttackPower] = 120 } }
local FOODS = { [27658] = { [ST.Strength] = 20, [ST.Spirit] = 20 } }

local function Tri(v) if v == true then return 1 end return v or 0 end

-- Raid + party + individual buffs on the player.
function S.ApplyBuffs(p, cfg)
  local raid, party, ind = cfg.raid or {}, cfg.party or {}, cfg.individual or {}
  local sb = {} -- exclusive "StatBuff" flat categories (scrolls vs raid buffs): highest wins
  local function statBuff(stat, v) sb[stat] = max(sb[stat] or 0, v) end

  if raid.arcaneBrilliance then statBuff(ST.Intellect, 40) end
  if Tri(raid.divineSpirit) > 0 then
    statBuff(ST.Spirit, 50)
    if Tri(raid.divineSpirit) == 2 then
      p:AddStatDependency(ST.Spirit, ST.SpellDamage, 0.1)
      p:AddStatDependency(ST.Spirit, ST.HealingPower, 0.1)
    end
  end
  if Tri(raid.giftOfTheWild) > 0 then
    local mod = Tri(raid.giftOfTheWild) == 2 and 1.35 or 1
    local s = floor(14 * mod)
    for _, n in ipairs({ "Stamina", "Strength", "Agility", "Intellect", "Spirit" }) do p:AddStat(ST[n], s) end
    p:AddStat(ST.Armor, floor(340 * mod))
  end
  if Tri(raid.powerWordFortitude) > 0 then
    p:AddStat(ST.Stamina, Tri(raid.powerWordFortitude) == 2 and floor(79 * 1.3) or 79)
  end

  -- Party
  if Tri(party.manaSpringTotem) > 0 then p:AddStat(ST.MP5, Tri(party.manaSpringTotem) == 2 and 62.5 or 50) end
  if Tri(party.leaderOfThePack) > 0 then
    p:AddStat(ST.PhysicalCritPercent, 5)
    if Tri(party.leaderOfThePack) == 2 then p:AddStat(ST.MeleeCritRating, 20) end
  end
  if Tri(party.battleShout) > 0 then p:AddStat(ST.AttackPower, floor(306 * (Tri(party.battleShout) == 2 and 1.25 or 1))) end
  if Tri(party.strengthOfEarthTotem) > 0 then
    p:AddStat(ST.Strength, floor(86 * ({ 1, 1.15 })[Tri(party.strengthOfEarthTotem)]))
  end
  if Tri(party.graceOfAirTotem) > 0 then
    local agi = Tri(party.graceOfAirTotem) == 2 and floor(77 * 1.15) or 77
    if party.totemTwisting then
      local a = p:RegisterAura({ label = "Grace of Air", duration = 9 })
      a:AttachStatBuff(ST.Agility, agi)
      Periodic(p, 10, S.PRIO_AUTO, function(sim) a:Activate(sim) end)
    else
      p:AddStat(ST.Agility, agi)
    end
  end
  if Tri(party.windfuryTotem) > 0 then S.WindfuryTotem(p, Tri(party.windfuryTotem) == 2) end
  if party.drums and party.drums ~= "DrumsUnknown" and party.drums ~= 0 then S.PartyDrums(p, party.drums) end
  if Tri(party.sanctityAura) > 0 then S.MakePermanent(S.SanctityAuraBuff(p, false, Tri(party.sanctityAura) == 2 and 2 or 0)) end
  if (party.ferociousInspiration or 0) > 0 then
    p.ps.DamageDealtMultiplier = p.ps.DamageDealtMultiplier * (1 + 0.03 * party.ferociousInspiration)
  end
  if party.trueshotAura then p:AddStat(ST.AttackPower, 125); p:AddStat(ST.RangedAttackPower, 125) end
  if party.braidedEterniumChain and p.gearIds.Neck ~= 24114 then p:AddStat(ST.MeleeCritRating, 28) end
  if party.draeneiRacialMelee and p.race ~= "BloodElf" and p.race ~= "Draenei" then p:AddStat(ST.PhysicalHitPercent, 1) end

  -- Individual
  if ind.blessingOfKings then
    for _, n in ipairs({ "Agility", "Strength", "Stamina", "Intellect", "Spirit" }) do p:MultiplyStat(ST[n], 1.1) end
  end
  if Tri(ind.blessingOfWisdom) > 0 then p:AddStat(ST.MP5, Tri(ind.blessingOfWisdom) == 2 and floor(41 * 1.2) or 41) end
  if Tri(ind.blessingOfMight) > 0 then
    local ap = Tri(ind.blessingOfMight) == 2 and 264 or 220
    p:AddStat(ST.AttackPower, ap)
    p:AddStat(ST.RangedAttackPower, ap)
  end
  if ind.unleashedRage then p:MultiplyStat(ST.AttackPower, 1.1) end

  if raid.bloodlust then S.Bloodlust(p) end

  p.statBuffCategory = sb
end

-- Consumables (consumes.go). Run after ApplyBuffs (scrolls share the StatBuff categories).
function S.ApplyConsumables(p, c, cfg)
  local sb = p.statBuffCategory or {}
  if c.flaskId and FLASKS[c.flaskId] then for k, v in pairs(FLASKS[c.flaskId]) do p:AddStat(k, v) end end
  if c.foodId and FOODS[c.foodId] then for k, v in pairs(FOODS[c.foodId]) do p:AddStat(k, v) end end
  if c.scrollAgi then sb[ST.Agility] = max(sb[ST.Agility] or 0, 20) end
  if c.scrollStr then sb[ST.Strength] = max(sb[ST.Strength] or 0, 20) end
  for k, v in pairs(sb) do p:AddStat(k, v) end
  if c.potId == 22838 then S.HastePotion(p) end
  if c.conjuredId == 12662 then S.DemonicRune(p) end
  if c.conjuredId == 22788 then S.FlameCap(p) end
  if c.mhImbueId then S.StaticImbue(p, c.mhImbueId) end
  if c.ohImbueId then S.StaticImbue(p, c.ohImbueId) end
  local eng = p.professions[1] == "Engineering" or p.professions[2] == "Engineering"
  if eng then S.Explosives(p, c) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Windfury Totem (buffs.go 1088-1173)
-- ---------------------------------------------------------------------------------------------------------------
function S.WindfuryTotem(p, improved)
  local ap = improved and floor(445 * 1.3) or 445
  local aa = p.autoAttacks
  local proc = p:NewTemporaryStatsAura("Windfury Totem Proc", { [ST.AttackPower] = ap }, 1.5)
  proc.maxStacks = 2
  S.AttachProcTrigger(proc, p, { name = "Windfury Attack", callback = "hit", procMask = PM.MeleeMHAuto + PM.MeleeOHAuto,
    handler = function(sim, spell)
      if proc.active and not has(spell.procMask, PM.MeleeSpecial) then proc:RemoveStack(sim) end
    end })
  local wfSpell = p:RegisterSpell({
    id = "melee_wf", tag = 25584, metricsKey = "windfury", school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHAuto,
    flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
    end,
  })
  p:MakeProcTriggerAura({ name = "Windfury Totem Trigger", isWeaponProc = true, procChance = 0.2, outcome = O.Landed,
    callback = "hit", procMask = PM.MeleeMHAuto, icd = 1.5, triggerImmediately = true,
    handler = function(sim, spell, result)
      proc:Activate(sim)
      if spell.procMask == PM.MeleeMHAuto then proc:SetStacks(sim, 1) else proc:SetStacks(sim, 2) end
      local sp = S.MaybeReplaceMHSwing and S.MaybeReplaceMHSwing(p, sim, wfSpell) or wfSpell
      sp:Cast(sim, result.target)
    end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Bloodlust, drums, potions, runes, explosives, racials (all auto-used major cooldowns)
-- ---------------------------------------------------------------------------------------------------------------
function S.Bloodlust(p)
  local sated = p:RegisterAura({ label = "Sated", duration = 600 })
  local bl = p:RegisterAura({ label = "Bloodlust", duration = 40, actionId = { spellId = 2825, tag = -1 },
    onGain = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1.3)
      a.unit:MultiplyCastSpeed(sim, 1.3)
      sated:Activate(sim)
    end,
    onExpire = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1 / 1.3)
      a.unit:MultiplyCastSpeed(sim, 1 / 1.3)
    end })
  local spell = p:RegisterSpell({ id = 2825, tag = -1, metricsKey = "bloodlust", flags = F.APL + F.NoOnCastComplete,
    procMask = PM.Empty, cd = 600, relatedSelfBuff = bl,
    applyEffects = function(sim) if not sated.active then bl:Activate(sim) end end })
  p:AddMajorCooldown({ spell = spell, priority = 1000, shouldActivate = function() return not sated.active end })
end

function S.PartyDrums(p, kind)
  local tinnitus = p:RegisterAura({ label = "Tinnitus", duration = 120 })
  local a = p:NewTemporaryStatsAura("Drums of Battle (External)", { [ST.MeleeHasteRating] = 80, [ST.SpellHasteRating] = 80 }, 30)
  a.actionId = { spellId = 35476, tag = -1 }
  p.aurasByKey = p.aurasByKey or {}
  p.aurasByKey[S.ActionKey(a.actionId)] = p.aurasByKey[S.ActionKey(a.actionId)] or a
  local og = a.onGain
  a.onGain = function(aura, sim) og(aura, sim); tinnitus:Activate(sim) end
  local spell = p:RegisterSpell({ id = 35476, tag = -1, metricsKey = "drums", procMask = PM.Empty, cd = 120,
    relatedSelfBuff = a,
    extraCastCondition = function() return not tinnitus.active end,
    applyEffects = function(sim) if not tinnitus.active then a:Activate(sim) end end })
  p:AddMajorCooldown({ spell = spell, priority = 2000 })
end

function S.HastePotion(p)
  local a = p:NewTemporaryStatsAura("Haste Potion", { [ST.MeleeHasteRating] = 400 }, 15)
  local spell = p:RegisterSpell({ id = "item:22838", procMask = PM.Empty, flags = F.Potion + F.NoOnCastComplete,
    cd = 120, sharedCd = 120, sharedCdTimer = p:CategoryTimer("potion"), relatedSelfBuff = a,
    applyEffects = function(sim) a:Activate(sim) end })
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end

-- consumes.go registerStaticImbue
function S.StaticImbue(p, id)
  if id == 29453 or id == 34340 then -- Adamantite Sharpening Stone / Weightstone
    p:AddStat(ST.MeleeCritRating, 14)
    local aa = p.autoAttacks
    for _, w in ipairs({ aa.mh, aa.isDualWielding and aa.oh or nil, p.rangedWeapon }) do
      if w then w.baseMin = w.baseMin + 12; w.baseMax = w.baseMax + 12 end
    end
    p:AddStat(ST.RangedCritPercent, -(14 / S.CRIT_RATING_PER_PCT))
  elseif id == 28017 then p:AddStat(ST.SpellDamage, 42)
  elseif id == 25122 then p:AddStat(ST.SpellDamage, 36); p:AddStat(ST.SpellCritRating, 14)
  elseif id == 25123 then p:AddStat(ST.HealingPower, 25); p:AddStat(ST.MP5, 12)
  end
end

-- Flame Cap (consumes.go registerConjuredCD 22788): +80 fire damage for 60 s and 18.5% on white hits for 40 fire
-- damage; used before the pull it locks its category for its full 3 minutes.
function S.FlameCap(p)
  local proc = p:RegisterSpell({ id = "item:22788", metricsKey = "flame_cap", school = SCHOOL.Fire,
    defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage, flags = F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    actionKey = "i22788:proc",
    applyEffects = function(sim, target, spell) spell:CalcAndDealDamage(sim, target, 40, OUT.MagicHitAndCrit) end })
  local trigger = p:MakeProcTriggerAura({ name = "Flame Cap - Proc", duration = 60, procChance = 0.185,
    procMask = PM.MeleeWhiteHit + PM.RangedAuto, outcome = O.Landed, callback = "hit",
    handler = function(sim, _, result) proc:Cast(sim, result.target) end })
  trigger.onReset = nil
  local a = p:NewTemporaryStatsAura("Flame Cap", { [ST.FireDamage] = 80 }, 60)
  a.actionId = { itemId = 22788 }
  local og, oe = a.onGain, a.onExpire
  a.onGain = function(aura, sim) og(aura, sim); trigger:Activate(sim) end
  a.onExpire = function(aura, sim) oe(aura, sim); trigger:Deactivate(sim) end
  local spell
  spell = p:RegisterSpell({ id = "item:22788", procMask = PM.Empty, flags = F.Conjured + F.APL + F.NoOnCastComplete,
    cd = 120, sharedCd = 120, sharedCdTimer = p:CategoryTimer(1153), relatedSelfBuff = a,
    applyEffects = function(sim)
      a:Activate(sim)
      if sim.now < 0 then
        spell.sharedCdTimer.readyAt = sim.now + 180
        p:UpdateMajorCooldowns()
      end
    end })
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end

function S.DemonicRune(p)
  local spell = p:RegisterSpell({ id = "item:12662", procMask = PM.Empty, flags = F.Conjured + F.NoOnCastComplete,
    cd = 120, sharedCd = 120, sharedCdTimer = p:CategoryTimer(1153),
    applyEffects = function(sim) p:AddMana(sim, 899 + sim:Rand() * 601, "demonic_rune") end })
  p:AddMajorCooldown({ spell = spell, priority = 0, shouldActivate = function()
    local regen = (p.manaTickCasting or 0) / 2 * 5
    return p:MaxMana() - (p.mana + regen) >= 1500
  end })
end

function S.Explosives(p, c)
  local shared = p:NewTimer()
  local function explosive(id, lo, hi, cd, castTime, speed, prio, selfDamage)
    local spell
    spell = p:RegisterSpell({ id = "item:" .. id, school = SCHOOL.Fire, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
      flags = F.Explosive, castTime = castTime, cd = cd, sharedCd = 60, sharedCdTimer = shared,
      bonusHitPercent = 100, damageMultiplier = 1, threatMultiplier = 1,
      applyEffects = function(sim, target, sp)
        local results = {}
        for _, t in ipairs(sim.targets) do
          results[#results + 1] = sp:CalcDamage(sim, t, sim:Roll(lo, hi), OUT.MagicHitAndCrit)
        end
        local function deal(s) for _, r in ipairs(results) do sp:DealDamage(s, r) end end
        if speed > 0 then
          sim:Add({ at = sim.now + p.distance / speed, prio = 0, fn = deal })
        else
          deal(sim)
        end
        if selfDamage then
          local r = sp:CalcDamage(sim, p, sim:Roll(lo, hi), OUT.MagicHitAndCrit)
          sp:DealDamage(sim, r)
        end
      end })
    if spell.metrics then spell.metrics.selfExcluded = true end
    p:AddMajorCooldown({ spell = spell, priority = prio, explosive = true })
  end
  if c.superSapper then explosive(23827, 900, 1500, 300, 0, 0, -970, true) end
  if c.goblinSapper then explosive(10646, 450, 750, 300, 0, 0, -980, true) end
  if c.explosiveId == 30217 then explosive(23737, 450, 750, nil, 1, 14, -990, false)
  elseif c.explosiveId == 30216 then explosive(23736, 330, 770, nil, 1, 14, -990, false) end
end

-- racials.go applyWeaponSpecialization: +5 expertise with these weapon types; an off-hand-only match counts only for
-- off-hand attacks, a main-hand-only one not for them.
local function WeaponSpecialization(p, ...)
  local aa = p.autoAttacks
  local mh, oh = false, false
  for _, wt in ipairs({ ... }) do
    if aa.mh.weaponType == wt then mh = true end
    if aa.isDualWielding and aa.oh.weaponType == wt then oh = true end
  end
  local bonus = 5 * S.EXPERTISE_PER_QUARTER
  local function ohOnly(sp) return has(sp.procMask, PM.MeleeOH) and not has(sp.procMask, PM.MeleeMH) end
  if mh then
    p:AddStat(ST.ExpertiseRating, bonus)
    if not oh and aa.isDualWielding then
      p:AddStaticMod({ kind = "Custom",
        apply = function(_, sp) if ohOnly(sp) then sp.bonusExpertise = sp.bonusExpertise - bonus end end,
        remove = function(_, sp) if ohOnly(sp) then sp.bonusExpertise = sp.bonusExpertise + bonus end end })
    end
  elseif oh then
    p:AddStaticMod({ kind = "Custom",
      apply = function(_, sp) if ohOnly(sp) then sp.bonusExpertise = sp.bonusExpertise + bonus end end,
      remove = function(_, sp) if ohOnly(sp) then sp.bonusExpertise = sp.bonusExpertise - bonus end end })
  end
end

-- RegisterTemporaryStatsOnUseCD: a self buff on a cooldown, auto-used as a major cooldown.
local function StatsOnUse(p, id, label, stats, duration, cd, extra)
  local a = p:NewTemporaryStatsAura(label, stats, duration)
  a.actionId = { spellId = id }
  p.aurasByKey = p.aurasByKey or {}
  p.aurasByKey["s" .. id .. ":0"] = p.aurasByKey["s" .. id .. ":0"] or a
  local cfg = { id = id, procMask = PM.Empty, flags = F.NoOnCastComplete, cd = cd, relatedSelfBuff = a,
    applyEffects = function(sim) a:Activate(sim) end }
  for k, v in pairs(extra or {}) do cfg[k] = v end
  local spell = p:RegisterSpell(cfg)
  p:AddMajorCooldown({ spell = spell })
  return spell, a
end

function S.ApplyRacials(p)
  local cls = p.class
  if p.race == "BloodElf" then
    -- Arcane Torrent: mana or energy; a rage class gets nothing back
    if p.hasMana or p.hasEnergy then
      local energy = p.hasEnergy
      local spell = p:RegisterSpell({ id = energy and 25046 or 28730, procMask = PM.Empty, cd = 120,
        applyEffects = function(sim)
          if energy then p:AddEnergy(sim, 10, "arcane_torrent") else p:AddMana(sim, 10, "arcane_torrent") end
        end })
      p:AddMajorCooldown({ spell = spell, priority = -1000, shouldActivate = function()
        if energy then return p.energy <= p.maxEnergy - 10 end
        return true
      end })
    end
  elseif p.race == "Human" then
    p:MultiplyStat(ST.Spirit, 1.10)
    WeaponSpecialization(p, 4, 9) -- WeaponTypeMace, WeaponTypeSword
  elseif p.race == "Orc" then
    local ap, sp = 0, 0
    if cls == "Warrior" or cls == "Rogue" or cls == "Hunter" then ap = 70 * 4 + 2
    elseif cls == "Shaman" then ap, sp = 70 * 4 + 2, 70 * 2 + 3
    elseif cls == "Warlock" then sp = 70 * 2 + 3 end
    StatsOnUse(p, 33697, "Blood Fury", { [ST.AttackPower] = ap, [ST.RangedAttackPower] = ap, [ST.SpellDamage] = sp }, 15, 120)
    WeaponSpecialization(p, 1) -- WeaponTypeAxe
  elseif p.race == "Troll" then
    local timer = p:NewTimer()
    local id, cost = 20554, nil
    if p.hasEnergy then id, cost = 26297, { energyCost = { cost = 10 } }
    elseif p.hasRage then id, cost = 26296, { rageCost = { cost = 5 } }
    elseif p.hasMana then id, cost = 20554, { manaCost = { flat = floor(p.baseMana * 0.06) } } end
    for i = 1, 5 do
      local pct = 1.10 + 0.05 * (i - 1)
      local a = p:RegisterAura({ label = ("Berserking (%d%%)"):format(floor((pct - 1) * 100 + 0.5)),
        actionId = { spellId = id, tag = i }, duration = 10 })
      a:AttachMultiplyAttackSpeed(pct)
      local og, oe = a.onGain, a.onExpire
      a.onGain = function(aura, sim) og(aura, sim); p:MultiplyCastSpeed(sim, pct) end
      a.onExpire = function(aura, sim) oe(aura, sim); p:MultiplyCastSpeed(sim, 1 / pct) end
      local cfg = { id = id, tag = i, procMask = PM.Empty, cd = 180, cdTimer = timer, relatedSelfBuff = a,
        applyEffects = function(sim) a:Activate(sim) end }
      for k, v in pairs(cost or {}) do cfg[k] = v end
      local spell = p:RegisterSpell(cfg)
      p:AddMajorCooldown({ spell = spell, shouldActivate = function() return i == 1 end })
    end
  elseif p.race == "Gnome" then
    p:MultiplyStat(ST.Intellect, 1.05)
  elseif p.race == "Tauren" then
    p:MultiplyStat(ST.Health, 1.05)
  elseif p.race == "NightElf" then
    p.ps.BaseDodgeChance = (p.ps.BaseDodgeChance or 0) + 0.01
  elseif p.race == "Draenei" then
    p:AddStat(ST.PhysicalHitPercent, 1)
  elseif p.race == "Dwarf" then
    local a = p:RegisterAura({ label = "Stoneform", duration = 8 })
    a:AttachMultiplicativePseudoStatBuff("ArmorMultiplier", 1.1)
    local spell = p:RegisterSpell({ id = 20594, procMask = PM.Empty, gcd = 1.5, cd = 180,
      applyEffects = function(sim) a:Activate(sim) end })
    p:AddMajorCooldown({ spell = spell, priority = 0 })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Debuffs on the target
-- ---------------------------------------------------------------------------------------------------------------
-- debuffs.go: armor reductions share one slot; Sunder's priority is its (negative) armor change, Expose Armor's
-- its reduction, so Expose Armor always wins.
function S.SunderArmorAura(target)
  local a = target:GetAura("Sunder Armor")
  if a then return a end
  local ee
  a = target:RegisterAura({ label = "Sunder Armor", actionId = { spellId = 25225 }, duration = 30, maxStacks = 5,
    onStacksChange = function(_, sim, old, new) ee:SetPriority(sim, -520 * new) end })
  ee = a:NewExclusiveEffect("MajorArmorReduction", true, 0,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, e.priority) end,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, -e.priority) end)
  return a
end

function S.ExposeArmorAura(target, comboPoints, talents)
  local a = target:GetAura("Expose Armor")
  if a then return a end
  local ee
  a = target:RegisterAura({ label = "Expose Armor", actionId = { spellId = 26866 }, duration = 30,
    onGain = function(_, sim) ee:SetPriority(sim, 410 * comboPoints * (1 + 0.25 * talents)) end })
  ee = a:NewExclusiveEffect("MajorArmorReduction", true, 0,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, -e.priority) end,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, e.priority) end)
  return a
end

function S.BloodFrenzyAura(target, points)
  local a = target:GetAura("Blood Frenzy")
  if a then return a end
  local m = 1 + 0.02 * points
  local i = S.SCHOOL_INDEX[SCHOOL.Physical]
  local tps = target.ps
  return target:RegisterAura({ label = "Blood Frenzy", actionId = { spellId = 29859 }, duration = huge,
    onGain = function() tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] * m end,
    onExpire = function() tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] / m end })
end

function S.ApplyDebuffs(p, t, d)
  local tps = t.ps
  local SI = S.SCHOOL_INDEX
  if d.misery then
    for _, s in ipairs({ SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Holy, SCHOOL.Nature, SCHOOL.Shadow }) do
      tps.SchoolDamageTakenMultiplier[SI[s]] = tps.SchoolDamageTakenMultiplier[SI[s]] * 1.05
    end
  end
  if Tri(d.curseOfElements) > 0 then
    local m = 1.10 + (Tri(d.curseOfElements) == 2 and 0.03 or 0)
    for _, s in ipairs({ SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Shadow }) do
      tps.SchoolDamageTakenMultiplier[SI[s]] = tps.SchoolDamageTakenMultiplier[SI[s]] * m
    end
    for _, n in ipairs({ "ArcaneResistance", "FireResistance", "FrostResistance", "ShadowResistance" }) do t:AddStat(ST[n], -88) end
  end
  if Tri(d.improvedSealOfTheCrusader) > 0 then
    local points = Tri(d.improvedSealOfTheCrusader) == 2 and 3 or 0
    S.MakePermanent(S.ImprovedSealOfTheCrusaderAura(t, -1, points, 0, d.jocRetribution2Pt4 and 1.15 or 1))
  end
  if d.judgementOfWisdom then
    local a = t:MakeProcTriggerAura({ name = "Judgement of Wisdom", duration = 20, procChance = 0.5, procMask = PM.Direct,
      callback = "taken",
      handler = function(sim, spell, result)
        if not has(spell.procMask, PM.MeleeOrRanged) and not S.Landed(result) then return end
        local u = spell.unit
        if u.hasMana then u:AddMana(sim, 74, "judgement_of_wisdom") end
      end })
    S.MakePermanent(a)
  end
  if d.bloodFrenzy then S.MakePermanent(S.BloodFrenzyAura(t, 2)) end
  if d.giftOfArthas then
    local a = t:GetOrRegisterAura({ label = "Gift of Arthas", actionId = { spellId = 11374 }, duration = 180 })
    a.onGain = function() tps.BonusPhysicalDamageTaken = tps.BonusPhysicalDamageTaken + 8 end
    a.onExpire = function() tps.BonusPhysicalDamageTaken = tps.BonusPhysicalDamageTaken - 8 end
    S.MakePermanent(a)
  end
  if d.mangle then
    local a = t:GetOrRegisterAura({ label = "Mangle", actionId = { spellId = 33876 }, duration = 12 })
    a.onGain = function() tps.PeriodicPhysicalDamageTakenMultiplier = tps.PeriodicPhysicalDamageTakenMultiplier * 1.3 end
    a.onExpire = function() tps.PeriodicPhysicalDamageTakenMultiplier = tps.PeriodicPhysicalDamageTakenMultiplier / 1.3 end
    S.MakePermanent(a)
  end
  if Tri(d.huntersMark) == 2 then
    -- active from 1 ns; nothing happens between 0 and 1 ns that reads attack power
    tps.BonusAttackPower = tps.BonusAttackPower + 110
  end
  if d.curseOfRecklessness then t:AddStat(ST.Armor, -800) end
  if Tri(d.faerieFire) > 0 then
    t:AddStat(ST.Armor, -610)
    if Tri(d.faerieFire) == 2 then tps.ReducedPhysicalHitTakenChance = tps.ReducedPhysicalHitTakenChance - 3 end
  end
  -- Sunder Armor stacks at 0, 1.5 ... 6 s; Expose Armor replaces it at 10 s (one MajorArmorReduction slot)
  -- (debuffs.go ScheduledAura).
  if Tri(d.exposeArmor) > 0 then
    local a = S.ExposeArmorAura(t, 5, Tri(d.exposeArmor) == 2 and 2 or 0)
    a.onReset = function(aura, sim)
      aura.duration = huge
      S.StartPeriodicAction(sim, { period = 10, numTicks = 1, onAction = function(s) aura:Activate(s) end })
    end
  end
  if d.sunderArmor then
    local a = S.SunderArmorAura(t)
    a.onReset = function(aura, sim)
      aura.duration = huge
      S.StartPeriodicAction(sim, { period = 1.5, numTicks = 5, tickImmediately = true, prio = S.PRIO_DOT,
        onAction = function(s)
          aura:Activate(s)
          if aura.active then aura:AddStack(s) end
        end })
    end
  end
  -- Expose Weakness: 90% chance per 7 s window of +agi/4 attack power against the target.
  if (d.exposeWeaknessUptime or 0) > 0 and (d.exposeWeaknessHunterAgility or 0) > 0 then
    local bonus = floor(d.exposeWeaknessHunterAgility * 0.25)
    local uptime = d.exposeWeaknessUptime
    local a = t:RegisterAura({ label = "Expose Weakness", duration = 7,
      onGain = function() tps.BonusAttackPower = tps.BonusAttackPower + bonus end,
      onExpire = function() tps.BonusAttackPower = tps.BonusAttackPower - bonus end })
    t:RegisterResetEffect(function(sim)
      sim:Add({ at = 1e-9, prio = 0, fn = function(s)
        if s:Rand() < uptime then s:Rand(); a:Activate(s) end
      end })
    end)
    Periodic(t, 7, 0, function(sim) if sim:Rand() < uptime then a:Activate(sim) end end)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Weapon enchants with effects (common/tbc/enchants.go)
-- ---------------------------------------------------------------------------------------------------------------
S.ENCHANT_EFFECTS = S.ENCHANT_EFFECTS or {}
-- Mongoose: PPM 1 weapon proc, 120 agility and 2% attack speed for 15 s (one aura per hand).
S.ENCHANT_EFFECTS[2673] = function(p, slot)
  local function hand(tag)
    local a = p:NewTemporaryStatsAura("Lightning Speed " .. tag, { [ST.Agility] = 120 }, 15)
    local og, oe = a.onGain, a.onExpire
    a.onGain = function(aura, sim) og(aura, sim); p:MultiplyAttackSpeed(sim, 1.02) end
    a.onExpire = function(aura, sim) oe(aura, sim); p:MultiplyAttackSpeed(sim, 1 / 1.02) end
    return a
  end
  local mhA, ohA = hand("MH"), hand("OH")
  local mask = 0
  if p.gear.MainHand and p.gear.MainHand.spec.enchant == 2673 then mask = mask + PM.MeleeMH end
  if p.gear.OffHand and p.gear.OffHand.spec.enchant == 2673 then mask = mask + PM.MeleeOH end
  p:MakeProcTriggerAura({ name = "Enchant Weapon - Mongoose", callback = "hit", isWeaponProc = true,
    dpm = S.NewPPM(p, 1, mask), outcome = O.Landed,
    handler = function(sim, spell)
      if has(spell.procMask, PM.MeleeOH) then ohA:Activate(sim) else mhA:Activate(sim) end
    end })
end

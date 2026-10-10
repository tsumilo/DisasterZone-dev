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
  -- The WoWSims Combat Rogue preset (ui/specs/rogue/dps/spec.ts defaults, presets.ts consumables).
  wowsims_rogue = {
    raid = { bloodlust = true, giftOfTheWild = 2 },
    party = { battleShout = 2, ferociousInspiration = 1, strengthOfEarthTotem = 2, graceOfAirTotem = 2, windfuryTotem = 2,
      leaderOfThePack = 1, totemTwisting = true, drums = "LesserDrumsOfBattle" },
    individual = { blessingOfKings = true, blessingOfMight = 2, unleashedRage = true },
    debuffs = { exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1080, bloodFrenzy = true, huntersMark = 2,
      improvedSealOfTheCrusader = 2, mangle = true, misery = true, curseOfRecklessness = true, faerieFire = 2,
      giftOfArthas = true, sunderArmor = true },
    consumables = { battleElixirId = 22831, guardianElixirId = 32062, foodId = 33872, potId = 22838, conjuredId = 7676,
      ohImbueId = 27186 },
  },
  -- The WoWSims Feral Cat preset (ui/specs/druid/feralcat/spec.ts defaults, presets.ts consumables): the cat brings his
  -- own Leader of the Pack and never procs Windfury Totem (Druid.lua).
  wowsims_cat = {
    raid = { bloodlust = true, arcaneBrilliance = true, divineSpirit = 2, giftOfTheWild = 2, powerWordFortitude = 2,
      shadowProtection = true },
    party = { drums = "LesserDrumsOfBattle", ferociousInspiration = 2, battleShout = 2, graceOfAirTotem = 2,
      windfuryTotem = 2, manaSpringTotem = 1, strengthOfEarthTotem = 2, totemTwisting = true },
    individual = { blessingOfKings = true, blessingOfMight = 2, unleashedRage = true },
    debuffs = { exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1080, bloodFrenzy = true, exposeArmor = 2,
      huntersMark = 2, improvedSealOfTheCrusader = 2, judgementOfWisdom = true, misery = true,
      curseOfRecklessness = true, faerieFire = 2, sunderArmor = true, giftOfArthas = true },
    consumables = { potId = 22838, battleElixirId = 22831, guardianElixirId = 32067, foodId = 27664, mhImbueId = 34340,
      conjuredId = 12662, superSapper = true, goblinSapper = true, scrollAgi = true, scrollStr = true },
  },
  -- The WoWSims Mage preset (ui/specs/mage/dps/presets.ts, phase 3 ISB uptime)
  wowsims_mage = {
    raid = { bloodlust = true, divineSpirit = 2, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2,
      shadowProtection = true },
    party = { manaSpringTotem = 2, manaTideTotems = 1, wrathOfAirTotem = 1 },
    individual = { blessingOfKings = true, blessingOfWisdom = 2, innervates = 1, blessingOfSalvation = true,
      shadowPriestDps = 1400 },
    debuffs = { misery = true, curseOfElements = 2, improvedSealOfTheCrusader = 2, judgementOfWisdom = true,
      isbUptime = 0.72 },
    consumables = { guardianElixirId = 32067, battleElixirId = 28103, foodId = 27657, mhImbueId = 25122, potId = 22832,
      drumsId = "LesserDrumsOfBattle" },
  },
  -- The WoWSims Balance Druid preset (ui/specs/druid/balance/presets.ts); the druid's own Moonkin Aura comes from his
  -- form (Druid.lua).
  wowsims_balance = {
    raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2, divineSpirit = 2 },
    party = { chainOfTheTwilightOwl = true, draeneiRacialCaster = true, eyeOfTheNight = true, totemOfWrath = 1,
      wrathOfAirTotem = 2 },
    individual = { blessingOfKings = true, blessingOfWisdom = 2, shadowPriestDps = 800 },
    debuffs = { bloodFrenzy = true, curseOfElements = 2, curseOfRecklessness = true, exposeArmor = 2, giftOfArthas = true,
      huntersMark = 2, improvedSealOfTheCrusader = 2, judgementOfWisdom = true, mangle = true, misery = true,
      sunderArmor = true },
    consumables = { conjuredId = 12662, flaskId = 22861, foodId = 27657, mhImbueId = 25122, potId = 22832,
      drumsId = "LesserDrumsOfBattle" },
  },
  -- The WoWSims Shadow Priest preset (ui/specs/priest/dps/presets.ts, phase 3 ISB uptime); the priest brings his own
  -- Misery and Shadow Weaving.
  wowsims_spriest = {
    raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2, divineSpirit = 2 },
    party = { manaSpringTotem = 1, wrathOfAirTotem = 2, eyeOfTheNight = true, chainOfTheTwilightOwl = true },
    individual = { blessingOfKings = true, blessingOfWisdom = 2 },
    debuffs = { improvedSealOfTheCrusader = 2, judgementOfWisdom = true, faerieFire = 2, curseOfElements = 2,
      exposeArmor = 2, isbUptime = 0.72 },
    consumables = { flaskId = 22866, foodId = 27657, conjuredId = 12662, mhImbueId = 22522, potId = 22839,
      explosiveId = 30217, drumsId = "LesserDrumsOfBattle" },
  },
  -- The WoWSims Warlock preset (ui/specs/warlock/dps/presets.ts, phase 3 ISB / Expose Weakness); the warlock casts his
  -- own curse (Warlock.lua drops the raid's copy of it). The fire build: Flame Cap and Improved Scorch.
  wowsims_warlock = {
    raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2, divineSpirit = 2 },
    party = { manaSpringTotem = 1, moonkinAura = 1, totemOfWrath = 1, wrathOfAirTotem = 2, eyeOfTheNight = true,
      chainOfTheTwilightOwl = true, drums = "LesserDrumsOfBattle" },
    individual = { blessingOfKings = true, blessingOfWisdom = 2 },
    debuffs = { exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1210, isbUptime = 0.72,
      improvedSealOfTheCrusader = 2, judgementOfWisdom = true, misery = true, shadowWeaving = true, sunderArmor = true,
      faerieFire = 2, curseOfRecklessness = true, curseOfElements = 2, bloodFrenzy = true, giftOfArthas = true,
      mangle = true, exposeArmor = 2, huntersMark = 2 },
    consumables = { flaskId = 22866, foodId = 27657, conjuredId = 12662, mhImbueId = 25122, potId = 22839,
      explosiveId = 30217, petScrollAgi = true, petScrollStr = true },
  },
  -- The WoWSims Elemental preset (ui/specs/shaman/elemental/presets.ts): the shaman drops his own totems.
  wowsims_ele = {
    raid = { bloodlust = true, arcaneBrilliance = true, giftOfTheWild = 2, powerWordFortitude = 2, divineSpirit = 2 },
    party = { moonkinAura = 2, chainOfTheTwilightOwl = true, eyeOfTheNight = true },
    individual = { blessingOfKings = true, blessingOfWisdom = 2, shadowPriestDps = 800 },
    debuffs = { bloodFrenzy = true, curseOfElements = 2, curseOfRecklessness = true, exposeArmor = 2, faerieFire = 2,
      giftOfArthas = true, huntersMark = 2, improvedSealOfTheCrusader = 2, judgementOfWisdom = true, mangle = true,
      misery = true, sunderArmor = true },
    consumables = { conjuredId = 12662, drumsId = "LesserDrumsOfBattle", flaskId = 22861, foodId = 27657,
      mhImbueId = 25122, potId = 22839 },
  },
  -- The WoWSims Enhancement preset (ui/specs/shaman/enhancement/presets.ts, P1): the shaman drops his own totems and
  -- beats his own drums.
  wowsims_enh = {
    raid = { bloodlust = true, powerWordFortitude = 2, giftOfTheWild = 2, arcaneBrilliance = true },
    party = { ferociousInspiration = 2, braidedEterniumChain = true, leaderOfThePack = 1, battleShout = 2 },
    individual = { blessingOfKings = true, blessingOfMight = 2 },
    debuffs = { exposeWeaknessUptime = 0.9, exposeWeaknessHunterAgility = 1080, improvedSealOfTheCrusader = 2,
      judgementOfWisdom = true, misery = true, bloodFrenzy = true, giftOfArthas = true, mangle = true, exposeArmor = 2,
      faerieFire = 2, sunderArmor = true, curseOfElements = 2, curseOfRecklessness = true, huntersMark = 2 },
    consumables = { potId = 22838, flaskId = 22854, foodId = 27658, drumsId = "LesserDrumsOfBattle", conjuredId = 22788,
      explosiveId = 30217, superSapper = true, goblinSapper = true, scrollAgi = true, scrollStr = true },
  },
}
do
  -- the Warlock fire build's preset: Flame Cap instead of the Demonic Rune, Improved Scorch on the target
  local w = S.BUFF_PRESETS.wowsims_warlock
  local fire = {}
  for k, v in pairs(w) do fire[k] = v end
  fire.debuffs, fire.consumables = {}, {}
  for k, v in pairs(w.debuffs) do fire.debuffs[k] = v end
  for k, v in pairs(w.consumables) do fire.consumables[k] = v end
  fire.debuffs.improvedScorch = true
  fire.consumables.conjuredId = 22788
  S.BUFF_PRESETS.wowsims_warlock_fire = fire
end


local function Tri(v) if v == true then return 1 end return v or 0 end
local ALLIANCE = { Draenei = true, Dwarf = true, Gnome = true, Human = true, NightElf = true }
local DRAENEI_CASTER = { Mage = true, Priest = true, Shaman = true }

-- buffs.go applyPetBuffEffects: a pet that isn't a guardian gets the buffs too, less what its owner casts on it in
-- combat (Bloodlust), what can't apply (Windfury, drums, innervates, Power Infusion) and, for one summoned in the
-- fight, the targeted buffs it wasn't there for. The owner's party necklaces reach it as well.
local NECK_PARTY = { [24121] = "chainOfTheTwilightOwl", [24116] = "eyeOfTheNight", [24114] = "braidedEterniumChain",
  [20966] = "jadePendantOfBlasting" }
function S.ApplyPetBuffs(pet, cfg)
  if pet.guardian then return end
  local raid, party, ind = {}, {}, {}
  for k, v in pairs(cfg.raid or {}) do raid[k] = v end
  for k, v in pairs(cfg.party or {}) do party[k] = v end
  for k, v in pairs(cfg.individual or {}) do ind[k] = v end
  raid.bloodlust, raid.thorns = nil, nil
  party.windfuryTotem, party.drums = nil, nil
  local neck = NECK_PARTY[pet.owner.gearIds.Neck or 0]
  if neck then party[neck] = true end
  if Tri(party.leaderOfThePack) > 1 then party.leaderOfThePack = 1 end
  if Tri(party.moonkinAura) > 1 then party.moonkinAura = 1 end
  ind.innervates, ind.powerInfusions = nil, nil
  if not pet.enabledOnStart then
    raid.arcaneBrilliance, raid.divineSpirit, raid.giftOfTheWild, raid.powerWordFortitude = nil, nil, nil, nil
    raid.shadowProtection = nil
    ind = { unleashedRage = ind.unleashedRage }
  end
  S.ApplyBuffs(pet, { raid = raid, party = party, individual = ind })
  -- the exclusive flat stat buffs (Arcane Brilliance, Divine Spirit): a pet has no scrolls to weigh them against
  for k, v in pairs(pet.statBuffCategory or {}) do pet:AddStat(k, v) end
  pet.statBuffCategory = nil
end

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
  local alliance = ALLIANCE[p.race]
  local ownPresence = p.race == "Draenei" and DRAENEI_CASTER[p.class] and "caster" or (p.race == "Draenei" and "melee") or nil
  if party.draeneiRacialMelee and alliance and ownPresence ~= "melee" then p:AddStat(ST.PhysicalHitPercent, 1) end
  if party.draeneiRacialCaster and alliance and ownPresence ~= "caster" then p:AddStat(ST.SpellHitPercent, 1) end
  -- caster party buffs (buffs.go)
  if Tri(party.moonkinAura) > 0 then
    p:AddStat(ST.SpellCritPercent, 5)
    if Tri(party.moonkinAura) == 2 then p:AddStat(ST.SpellCritRating, 20) end
  end
  if party.chainOfTheTwilightOwl and p.gearIds.Neck ~= 24121 then p:AddStat(ST.SpellCritPercent, 2) end
  if party.eyeOfTheNight and p.gearIds.Neck ~= 24116 then p:AddStat(ST.SpellDamage, 34) end
  if party.jadePendantOfBlasting then p:AddStat(ST.SpellDamage, 15) end
  if (party.totemOfWrath or 0) > 0 then
    p:AddStat(ST.SpellCritPercent, 3 * party.totemOfWrath)
    p:AddStat(ST.SpellHitPercent, 3 * party.totemOfWrath)
  end
  if Tri(party.wrathOfAirTotem) > 0 then
    -- one Wrath of Air: a shaman's own totem is the same exclusive effect
    local v = 101 + (Tri(party.wrathOfAirTotem) == 2 and 20 or 0)
    local a = p:RegisterAura({ label = "Wrath of Air Totem", actionId = { spellId = 3738, tag = -1 } })
    a:NewExclusiveEffect("WrathOfAirTotemSpellDamageAdd", false, v,
      function(_, sim) p:AddStatsDynamic(sim, { [ST.SpellDamage] = v, [ST.HealingPower] = v }) end,
      function(_, sim) p:AddStatsDynamic(sim, { [ST.SpellDamage] = -v, [ST.HealingPower] = -v }) end)
    S.MakePermanent(a)
  end
  if (party.atieshMage or 0) > 0 then p:AddStat(ST.SpellCritRating, 28 * party.atieshMage) end
  if (party.atieshWarlock or 0) > 0 then p:AddStat(ST.SpellDamage, 33 * party.atieshWarlock) end
  if (party.atieshDruid or 0) > 0 then p:AddStat(ST.MP5, 11 * party.atieshDruid) end
  if (party.atieshPriest or 0) > 0 then p:AddStat(ST.HealingPower, 62 * party.atieshPriest) end
  if (party.manaTideTotems or 0) > 0 and p.hasMana then S.ManaTideTotems(p, party.manaTideTotems) end

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
  if (ind.shadowPriestDps or 0) > 0 and p.hasMana then
    -- buffs.go ShadowPriestDPSManaAura: Vampiric Touch, 5% of the priest's damage per second as mana
    local gain = ind.shadowPriestDps * 0.05
    p:RegisterResetEffect(function(sim)
      S.StartPeriodicAction(sim, { period = 1, onAction = function(s) p:AddMana(s, gain, "vampiric_touch") end })
    end)
  end
  if (ind.innervates or 0) > 0 and p.hasMana then S.Innervates(p, ind.innervates) end
  if (ind.powerInfusions or 0) > 0 then S.PowerInfusions(p, ind.powerInfusions) end

  if raid.bloodlust then S.Bloodlust(p) end

  p.statBuffCategory = sb
end

-- Consumables (consumes.go). Run after ApplyBuffs (scrolls share the StatBuff categories).
function S.ApplyConsumables(p, c, cfg)
  local sb = p.statBuffCategory or {}
  -- flask, battle and guardian elixirs, food: their stats (db consumables); Elixir of Demonslaying and Gift of
  -- Arthas as guardian elixir have effects of their own (not simmed)
  local cdb = p.db and p.db.consumables
  local function addStats(id)
    local cons = id and id ~= 0 and cdb and cdb[id]
    if cons then p:AddStats(S.WSStats(cons.stats)) end
  end
  -- consumes.go Pet Consumes: scrolls for a pet that isn't a guardian
  for _, pet in ipairs(p.pets or {}) do
    if not pet.guardian then
      if c.petScrollAgi then pet:AddStat(ST.Agility, 20) end
      if c.petScrollStr then pet:AddStat(ST.Strength, 20) end
    end
  end
  addStats(c.flaskId)
  if c.battleElixirId ~= 9224 then addStats(c.battleElixirId) end
  if c.guardianElixirId ~= 9088 then addStats(c.guardianElixirId) end
  addStats(c.foodId)
  if c.scrollAgi then sb[ST.Agility] = max(sb[ST.Agility] or 0, 20) end
  if c.scrollStr then sb[ST.Strength] = max(sb[ST.Strength] or 0, 20) end
  for k, v in pairs(sb) do p:AddStat(k, v) end
  if c.potId == 22838 then S.HastePotion(p) elseif c.potId and c.potId ~= 0 then S.Potion(p, c.potId) end
  if c.conjuredId == 12662 then S.DemonicRune(p) end
  if c.conjuredId == 22788 then S.FlameCap(p) end
  if c.conjuredId == 7676 and p.hasEnergy then S.ThistleTea(p) end
  -- consumes.go: a main-hand imbue only without Windfury Totem
  if c.mhImbueId and Tri((cfg and cfg.party or {}).windfuryTotem) == 0 then S.StaticImbue(p, c.mhImbueId) end
  if c.ohImbueId then S.StaticImbue(p, c.ohImbueId) end
  -- drums and explosives share one cooldown timer (consumes.go drumsBombsSharedTimer)
  p.drumsBombsTimer = p.drumsBombsTimer or p:NewTimer()
  local eng = p.professions[1] == "Engineering" or p.professions[2] == "Engineering"
  if eng then S.Explosives(p, c) end
  if c.drumsId and c.drumsId ~= 0 and c.drumsId ~= "DrumsUnknown" then S.OwnDrums(p, c.drumsId) end
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
-- buffs.go BloodlustAura: the owner's pets that aren't guardians get it too when they are out at the time
local function PetBloodlust(pet)
  return pet:RegisterAura({ label = "Bloodlust", duration = 40, actionId = { spellId = 2825, tag = -1 },
    onGain = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1.3)
      a.unit:MultiplyCastSpeed(sim, 1.3)
    end,
    onExpire = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1 / 1.3)
      a.unit:MultiplyCastSpeed(sim, 1 / 1.3)
    end })
end

function S.Bloodlust(p)
  local sated = p:RegisterAura({ label = "Sated", duration = 600 })
  local petAuras = {}
  for _, pet in ipairs(p.pets or {}) do
    if not pet.guardian then petAuras[#petAuras + 1] = PetBloodlust(pet) end
  end
  local bl = p:RegisterAura({ label = "Bloodlust", duration = 40, actionId = { spellId = 2825, tag = -1 },
    onGain = function(a, sim)
      a.unit:MultiplyAttackSpeed(sim, 1.3)
      a.unit:MultiplyCastSpeed(sim, 1.3)
      for _, pa in ipairs(petAuras) do
        if pa.unit.enabled then pa:Activate(sim) end
      end
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

-- consumes.go registerDrumsCD: your own drums (a GCD; the lesser ones take a 1 s cast), 2 minutes, sharing a
-- cooldown with explosives; Tinnitus stops a second set of drums for 2 minutes.
local DRUMS = { GreaterDrumsOfBattle = 1, GreaterDrumsOfRestoration = 2, GreaterDrumsOfWar = 3, LesserDrumsOfBattle = 4,
  LesserDrumsOfRestoration = 5, LesserDrumsOfWar = 6 }
function S.OwnDrums(p, kind)
  local n = type(kind) == "number" and kind or DRUMS[kind] or 0
  local label, stats, duration, id
  if n == 1 or n == 4 then
    label, stats, duration, id = "Drums of Battle", { [ST.MeleeHasteRating] = 80, [ST.SpellHasteRating] = 80 }, 30, 35476
  elseif n == 3 or n == 6 then
    label, stats, duration, id = "Drums of War", { [ST.AttackPower] = 60, [ST.RangedAttackPower] = 60, [ST.SpellDamage] = 30 }, 30, 35475
  elseif n == 2 or n == 5 then
    label, stats, duration, id = "Drums of Restoration", { [ST.MP5] = 200 }, 15, 35478
  else
    return
  end
  local tinnitus = p:GetAura("Tinnitus") or p:RegisterAura({ label = "Tinnitus", duration = 120 })
  local a = p:NewTemporaryStatsAura(label, stats, duration)
  a.actionId = { spellId = id }
  p.aurasByKey = p.aurasByKey or {}
  p.aurasByKey[S.ActionKey(a.actionId)] = p.aurasByKey[S.ActionKey(a.actionId)] or a
  local og = a.onGain
  a.onGain = function(aura, sim) og(aura, sim); tinnitus:Activate(sim) end
  local spell = p:RegisterSpell({ id = id, metricsKey = "drums_own", procMask = PM.Empty, flags = F.NoOnCastComplete,
    castTime = (n <= 3) and 0 or 1, gcd = 1.5, cd = 120, sharedCd = 120, sharedCdTimer = p.drumsBombsTimer,
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

-- consumes.go makePotionActivationSpell: any other combat potion from WoWSims' data, a stat buff and / or a resource
-- gain; a mana potion waits until its whole gain fits.
function S.Potion(p, id)
  local cons = p.db and p.db.consumables and p.db.consumables[id]
  if not cons then return end
  local cd = (cons.cooldown or 0) > 0 and cons.cooldown or 120
  local catCd = (cons.categoryCooldown or 0) > 0 and cons.categoryCooldown or 120
  local aura
  if (cons.buffDuration or 0) > 0 then aura = p:NewTemporaryStatsAura("Potion " .. id, S.WSStats(cons.stats), cons.buffDuration) end
  local gains = cons.gains or {}
  local spell
  spell = p:RegisterSpell({ id = "item:" .. id, procMask = PM.Empty, flags = F.Potion + F.APL + F.NoOnCastComplete,
    cd = cd, sharedCd = cd, sharedCdTimer = p:CategoryTimer("potion"), relatedSelfBuff = aura,
    applyEffects = function(sim)
      if aura then aura:Activate(sim) end
      for _, g in ipairs(gains) do
        local gain = g.min + sim:Rand() * g.spread
        if g.resource == 1 and p.hasMana then p:AddMana(sim, gain, "potion")
        elseif g.resource == 2 and p.hasEnergy then p:AddEnergy(sim, gain, "potion")
        elseif g.resource == 3 and p.hasRage then p:AddRage(sim, gain, "potion") end
      end
      if sim.now < 0 then
        spell.sharedCdTimer.readyAt = sim.now + catCd
        p:UpdateMajorCooldowns()
      end
    end })
  p:AddMajorCooldown({ spell = spell, priority = 0, shouldActivate = function()
    for _, g in ipairs(gains) do
      if g.resource == 1 then
        local regen = (p.manaTickCasting or 0) / 2 * 5
        if p:MaxMana() - (p.mana + regen) < g.min + g.spread then return false end
      end
    end
    return true
  end })
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

-- Thistle Tea (consumes.go makeConjuredActivationSpell 7676): 100 - 2 * (70 - 40) = 40 energy; 5 min, sharing
-- 2 minutes with runes and Flame Cap; used before the pull it locks the category for its full 2 minutes.
function S.ThistleTea(p)
  local spell
  spell = p:RegisterSpell({ id = "item:7676", procMask = PM.Empty, flags = F.Conjured + F.APL + F.NoOnCastComplete,
    cd = 300, sharedCd = 120, sharedCdTimer = p:CategoryTimer(1153),
    applyEffects = function(sim)
      p:AddEnergy(sim, 40, "thistle_tea")
      if sim.now < 0 then
        spell.sharedCdTimer.readyAt = sim.now + 120
        p:UpdateMajorCooldowns()
      end
    end })
  p:AddMajorCooldown({ spell = spell, priority = 0, shouldActivate = function() return p.maxEnergy - p.energy >= 40 end })
end

-- buffs.go registerExternalConsecutiveCDApproximation: n raid members' cooldowns used one after another.
local function ExternalCDs(p, cfg, n)
  local timers = {}
  for i = 1, n do timers[i] = p:NewTimer() end
  local shared = p:NewTimer()
  local nextIndex = 1
  p:RegisterResetEffect(function() nextIndex = 1 end)
  local spell = p:RegisterSpell({ id = cfg.id, tag = -1, metricsKey = cfg.metricsKey, procMask = PM.Empty,
    flags = F.NoOnCastComplete + F.NoMetrics, cd = cfg.auraDuration, cdTimer = shared, relatedSelfBuff = cfg.aura,
    extraCastCondition = function(sim)
      if timers[nextIndex].readyAt > sim.now then return false end
      if cfg.aura.active then return false end
      return true
    end,
    applyEffects = function(sim)
      cfg.aura:Activate(sim)
      timers[nextIndex].readyAt = sim.now + cfg.auraCD
      nextIndex = nextIndex % n + 1
      if timers[nextIndex].readyAt <= sim.now then
        shared.readyAt = sim.now + cfg.auraDuration
      else
        shared.readyAt = sim.now + (timers[nextIndex].readyAt - sim.now)
      end
    end })
  p:AddMajorCooldown({ spell = spell, shouldActivate = cfg.shouldActivate })
end

-- Mana Tide Totem: 6% of max mana every 3 s for 12 s; first at 40 s or half the fight.
function S.ManaTideTotems(p, n)
  local a = p:RegisterAura({ label = "ManaTideTotem-16190:-1", actionId = { spellId = 16190, tag = -1 }, duration = 12 })
  a.onGain = function(_, sim)
    S.StartPeriodicAction(sim, { period = 3, numTicks = 4,
      onAction = function(s) p:AddMana(s, p:MaxMana() * 0.06, "mana_tide") end })
  end
  ExternalCDs(p, { id = 16190, metricsKey = "mana_tide", aura = a, auraDuration = 12, auraCD = 300,
    shouldActivate = function(sim) return sim.now >= math.min(sim.baseDuration / 2, 40) end }, n)
end

-- Innervate: spirit regen x5 (all of it while casting) for 20 s, used below 1000 mana (mages: 40%).
function S.Innervates(p, n)
  local threshold
  local a = p:RegisterAura({ label = "Innervate-29166:-1", actionId = { spellId = 29166, tag = -1 }, duration = 20,
    onGain = function()
      p.ps.ForceFullSpiritRegen = true
      p.ps.SpiritRegenMultiplier = p.ps.SpiritRegenMultiplier * 5
      p:UpdateManaRegenRates()
    end,
    onExpire = function()
      p.ps.ForceFullSpiritRegen = false
      p.ps.SpiritRegenMultiplier = p.ps.SpiritRegenMultiplier / 5
      p:UpdateManaRegenRates()
    end })
  ExternalCDs(p, { id = 29166, metricsKey = "innervate", aura = a, auraDuration = 20, auraCD = 360,
    shouldActivate = function()
      -- buffs.go InnervateManaThreshold, read after the build: a mage's 40% is of his mana without the raid buffs
      if not threshold then
        threshold = (p.class == "Mage") and p:StatsWithoutBuffs()[ST.Mana] * 0.4 or 1000
      end
      return p.mana <= threshold
    end }, n)
end

-- Power Infusion: spells cost 20% less and cast 20% faster for 15 s; not during Bloodlust.
function S.PowerInfusions(p, n)
  local a = p:RegisterAura({ label = "PowerInfusion-10060:-1", actionId = { spellId = 10060, tag = -1 }, duration = 15 })
  a:NewExclusiveEffect("ManaCost", true, -20,
    function() if p.hasMana then p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier - 20 end end,
    function() if p.hasMana then p.ps.SpellCostPercentModifier = p.ps.SpellCostPercentModifier + 20 end end)
  local og, oe = a.onGain, a.onExpire
  a.onGain = function(aura, sim) if og then og(aura, sim) end p:MultiplyCastSpeed(sim, 1.2) end
  a.onExpire = function(aura, sim) if oe then oe(aura, sim) end p:MultiplyCastSpeed(sim, 1 / 1.2) end
  ExternalCDs(p, { id = 10060, metricsKey = "power_infusion", aura = a, auraDuration = 15, auraCD = 180,
    shouldActivate = function()
      local bl = p:GetAura("Bloodlust") or p:GetAura("Bloodlust-2825:0")
      return not (bl and bl.active)
    end }, n)
end

-- aura_helpers.go ApplyFixedUptimeAura: a debuff kept up a share of the time by someone else.
function S.ApplyFixedUptimeAura(aura, uptime, tickLength, startTime)
  local dur = aura.duration
  local ticks = dur / tickLength
  local chance = (uptime == 1) and 1 or (1 - (1 - uptime) ^ (1 / ticks))
  aura.unit:RegisterResetEffect(function(sim)
    S.StartPeriodicAction(sim, { period = tickLength, onAction = function(s)
      if s:Rand() < chance then
        aura:Activate(s)
        if (aura.maxStacks or 0) > 0 then aura:AddStack(s) end
      end
    end })
    S.StartPeriodicAction(sim, { period = startTime, numTicks = 1, onAction = function(s)
      if s:Rand() < uptime then
        aura.duration = tickLength + (dur - tickLength) * s:Rand()
        aura:Activate(s)
        aura.duration = dur
      end
    end })
  end)
end

-- debuffs.go ScheduledAura: a debuff the raid builds up at the start and keeps up.
local function ScheduledStacks(aura, period, ticks, tickImmediately)
  aura.onReset = function(a, sim)
    a.duration = huge
    S.StartPeriodicAction(sim, { period = period, numTicks = ticks, tickImmediately = tickImmediately, prio = S.PRIO_DOT,
      onAction = function(s)
        a:Activate(s)
        if a.active then a:AddStack(s) end
      end })
  end
end
S.ScheduledStacks = ScheduledStacks

-- school x(1 + per stack) on the target, one exclusive effect (Improved Scorch, Shadow Weaving)
local function StackingSchoolDebuff(target, label, id, duration, school, perStack, category)
  local a = target:GetAura(label)
  if a then return a end
  local ee
  local i = S.SCHOOL_INDEX[school]
  local tps = target.ps
  a = target:RegisterAura({ label = label, actionId = { spellId = id }, duration = duration, maxStacks = 5,
    onStacksChange = function(_, sim, old, new) ee:SetPriority(sim, 1 + perStack * new) end })
  ee = a:NewExclusiveEffect(category, false, 1,
    function(e) tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] * e.priority end,
    function(e) tps.SchoolDamageTakenMultiplier[i] = tps.SchoolDamageTakenMultiplier[i] / e.priority end)
  return a
end
function S.ImprovedScorchAura(target) return StackingSchoolDebuff(target, "Improved Scorch", 12873, 30, SCHOOL.Fire, 0.03, "ImprovedScorch") end
function S.ShadowWeavingAura(target) return StackingSchoolDebuff(target, "Shadow Weaving", 15334, 15, SCHOOL.Shadow, 0.02, "ShadowWeaving") end

-- Winter's Chill: frost crit +2% per stack for the player.
function S.WintersChillAura(target, p, startingStacks)
  local a = target:GetAura("Winter's Chill")
  if a then return a end
  -- debuffs.go: every player and pet gets +2% frost crit per stack
  local mods = {}
  for _, u in ipairs({ p, unpack(p.pets or {}) }) do
    mods[#mods + 1] = u:AddDynamicMod({ kind = "BonusCrit_Percent", value = 0, school = SCHOOL.Frost })
  end
  return target:RegisterAura({ label = "Winter's Chill", actionId = { spellId = 28595 }, duration = 15, maxStacks = 5,
    onGain = function(aura, sim) if startingStacks then aura:SetStacks(sim, startingStacks) end end,
    onStacksChange = function(_, sim, old, new)
      for _, mod in ipairs(mods) do
        mod:Activate()
        mod:UpdateValue(2 * new)
      end
    end })
end

function S.Explosives(p, c)
  local shared = p.drumsBombsTimer or p:NewTimer()
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
    -- racials.go: Heroic Presence for hunters, paladins and warriors, Inspiring Presence for mages, priests and shamans
    if DRAENEI_CASTER[cls] then p:AddStat(ST.SpellHitPercent, 1)
    elseif cls == "Hunter" or cls == "Paladin" or cls == "Warrior" then p:AddStat(ST.PhysicalHitPercent, 1) end
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

-- comboPoints: a number, or a function returning the caster's combo points when the debuff lands (a rogue's own).
function S.ExposeArmorAura(target, comboPoints, talents)
  local a = target:GetAura("Expose Armor")
  if a then return a end
  local ee
  local cp = type(comboPoints) == "function" and comboPoints or function() return comboPoints end
  a = target:RegisterAura({ label = "Expose Armor", actionId = { spellId = 26866 }, duration = 30,
    onGain = function(_, sim) ee:SetPriority(sim, 410 * cp() * (1 + 0.25 * talents)) end })
  ee = a:NewExclusiveEffect("MajorArmorReduction", true, 0,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, -e.priority) end,
    function(e, sim) target:AddStatDynamic(sim, ST.Armor, e.priority) end)
  return a
end

-- debuffs.go FaerieFireAura: 610 armor, and Improved Faerie Fire's points off the target's chance to be missed; one
-- aura per target (a druid's own and the raid's are the same debuff), the higher improvement wins.
function S.FaerieFireAura(target, improvedPoints)
  local a = target:GetAura("Faerie Fire")
  if a then
    local ee = a.exclusive and a.exclusive[1]
    if ee and ee.priority < improvedPoints then ee.priority = improvedPoints end
    return a
  end
  a = target:RegisterAura({ label = "Faerie Fire", actionId = { spellId = 26993 }, duration = 40 })
  a:NewExclusiveEffect("FaerieFireAura", true, improvedPoints,
    function(e, sim)
      target:AddStatDynamic(sim, ST.Armor, -610)
      target.ps.ReducedPhysicalHitTakenChance = target.ps.ReducedPhysicalHitTakenChance - e.priority
    end,
    function(e, sim)
      target:AddStatDynamic(sim, ST.Armor, 610)
      target.ps.ReducedPhysicalHitTakenChance = target.ps.ReducedPhysicalHitTakenChance + e.priority
    end)
  return a
end

-- debuffs.go MangleAura: bleeds x1.3 for 12 s.
function S.MangleAura(target)
  local a = target:GetAura("Mangle")
  if a then return a end
  a = target:RegisterAura({ label = "Mangle", actionId = { spellId = 33876 }, duration = 12 })
  a:NewExclusiveEffect("Mangle", true, 1.3,
    function(e) target.ps.PeriodicPhysicalDamageTakenMultiplier = target.ps.PeriodicPhysicalDamageTakenMultiplier * e.priority end,
    function(e) target.ps.PeriodicPhysicalDamageTakenMultiplier = target.ps.PeriodicPhysicalDamageTakenMultiplier / e.priority end)
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

-- debuffs.go ImprovedShadowBoltAura: shadow damage taken +4% a point, 4 charges, 12 s. Kept up a share of the time
-- by the raid (uptime > 0), or by a warlock's crits (uptime 0: a landed shadow spell hit uses up a charge). One aura
-- per point count. The raid's comes first (debuffs before talents); a warlock's talent asking for the same aura gets
-- it with its charge rule added (GetOrRegisterAura replaces the callbacks): the raid's applications carry 1 charge,
-- so the next shadow hit ends them. A raid call that finds the aura (Lua repeats it in ApplyDebuffs) changes nothing.
local function ISBChargeRule(aura, sim, spell, result)
  if not has(spell.school or 0, SCHOOL.Shadow) or not S.Landed(result) or result.damage == 0
    or not has(spell.procMask or 0, PM.SpellDamage) then return end
  aura:RemoveStack(sim)
end

function S.ImprovedShadowBoltAura(t, uptime, points)
  local label = "ImprovedShadowBolt-" .. points
  local a = t:GetAura(label)
  if a then
    if uptime == 0 then a.onSpellHitTaken = ISBChargeRule end
    return a
  end
  a = t:RegisterAura({ label = label, actionId = { spellId = 17800 }, duration = 12, maxStacks = 4 })
  if uptime == 0 then a.onSpellHitTaken = ISBChargeRule end
  a:AttachMultiplicativePseudoStatBuff("SchoolDamageTakenMultiplier", 1 + 0.04 * points, S.SCHOOL_INDEX[SCHOOL.Shadow])
  S.ApplyFixedUptimeAura(a, uptime, a.duration, 1e-9) -- Go's startTime 1 = 1 ns
  return a
end

function S.ApplyDebuffs(p, t, d)
  local tps = t.ps
  local SI = S.SCHOOL_INDEX
  -- a Shadow Priest with the talent keeps up his own Misery (Priest.lua)
  if d.misery and not p.ownMisery then
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
  if d.mangle then S.MakePermanent(S.MangleAura(t)) end
  if Tri(d.huntersMark) == 2 then
    -- active from 1 ns; nothing happens between 0 and 1 ns that reads attack power
    tps.BonusAttackPower = tps.BonusAttackPower + 110
  end
  if d.curseOfRecklessness then t:AddStat(ST.Armor, -800) end
  if Tri(d.faerieFire) > 0 then S.MakePermanent(S.FaerieFireAura(t, Tri(d.faerieFire) == 2 and 3 or 0)) end
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
  if d.improvedScorch then ScheduledStacks(S.ImprovedScorchAura(t), 1.2, 5, true) end
  if d.shadowWeaving then ScheduledStacks(S.ShadowWeavingAura(t), 1.5, 5, true) end
  if d.wintersChill then S.MakePermanent(S.WintersChillAura(t, p, 5)) end
  if (d.isbUptime or 0) > 0 then S.ImprovedShadowBoltAura(t, d.isbUptime, 5) end
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

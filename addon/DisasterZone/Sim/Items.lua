if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Items.lua", ...) then return end -- DisasterZone: Sim/Items.lua
-- ns.GearSim hand-written item effects (WoWSims sim/common/tbc/items_*.go, classic/items_trinkets.go): the ones
-- the generic proc / on-use data can't express. Only effects that change melee damage, haste or mana are here;
-- purely defensive ones (absorbs, armor procs, heals) are left out on purpose.
--
-- Deliberate deviation from WoWSims: Hand of Justice procs with any melee weapon (WoWSims only lets it proc when the
-- weapon is a sword, a copy of Sword Specialization's rule; the game has no such limit).
-- Also deliberate: Figurine of the Colossus and Argussian Compass do nothing here. WoWSims casts them as holy-school
-- spells, which breaks a Shadow Priest's Shadowform (-10% in its sweep); using an item doesn't do that in the game.
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, O, OUT, SCHOOL = S.ST, S.PM, S.F, S.O, S.OUT, S.SCHOOL
local has = S.has

local huge, max, min, floor = math.huge, math.max, math.min, math.floor

S.ITEM_EFFECTS = S.ITEM_EFFECTS or {}
local IE = S.ITEM_EFFECTS

-- The hand an item sits in, for weapon procs (NewDynamicLegacyProcForWeapon).
local function WeaponMask(p, itemId)
  local m = 0
  if p.gearIds.MainHand == itemId then m = m + PM.MeleeMH end
  if p.gearIds.OffHand == itemId then m = m + PM.MeleeOH end
  return m
end

-- itemhelpers.CreateWeaponProcTrigger: a chance-on-hit weapon proc on landed hits.
local function WeaponProc(p, itemId, ppm, handler, immediately)
  p:MakeProcTriggerAura({ name = "weapon " .. itemId, callback = "hit", outcome = O.Landed,
    dpm = S.NewPPM(p, ppm, WeaponMask(p, itemId)), isWeaponProc = true, triggerImmediately = immediately,
    handler = handler })
end

-- An extra main-hand white swing (Hand of Justice, Blinkstrike, Windfury): a copy of the auto attack.
local function ExtraAttackSpell(p, key)
  local aa = p.autoAttacks
  return p:RegisterSpell({
    id = "melee_" .. key, metricsKey = "melee", school = SCHOOL.Physical, defenseType = S.DEF_MELEE,
    procMask = PM.MeleeMHAuto, flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete + F.PassiveSpell,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
    end,
  })
end

-- MakeStackingAura: +bonus per stack
local function StackingStatAura(p, label, duration, maxStacks, bonus)
  local a = p:RegisterAura({ label = label, duration = duration, maxStacks = maxStacks })
  a.onStacksChange = function(aura, sim, old, new)
    local d = new - old
    local t = {}
    for k, v in pairs(bonus) do t[k] = v * d end
    p:AddStatsDynamic(sim, t)
  end
  return a
end
S.StackingStatAura = StackingStatAura

-- shared.NewProcDamageEffect: a damage spell cast on whatever the trigger hit (CallbackOnSpellHitDealt / periodic).
local function ProcDamage(p, itemId, cfg)
  local spell = p:RegisterSpell({ id = cfg.spellId, school = cfg.school, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.NoOnCastComplete + F.PassiveSpell + F.NoOnDamageDealt + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, target, sp)
      sp:CalcAndDealDamage(sim, target, sim:Roll(cfg.min, cfg.max), OUT.MagicHitAndCrit)
    end })
  p:MakeProcTriggerAura({ name = cfg.name, callback = cfg.callback or "hit", procMask = cfg.procMask, outcome = O.Landed,
    requireDamageDealt = true, procChance = cfg.procChance or 1, icd = cfg.icd, triggerImmediately = true,
    handler = function(sim, _, result) spell:Cast(sim, result.target) end })
end
local MELEE_ALL = PM.MeleeMHAuto + PM.MeleeOHAuto + PM.MeleeMHSpecial + PM.MeleeOHSpecial
-- Blazefury Medallion / Fiery Retributer: 2 fire damage on every landed melee hit
IE[17111] = function(p)
  ProcDamage(p, 17111, { name = "Blazefury Medallion", spellId = 7712, school = SCHOOL.Fire, min = 2, max = 2,
    procMask = MELEE_ALL })
end
IE[19968] = function(p)
  ProcDamage(p, 19968, { name = "Fiery Retributer", spellId = 7712, school = SCHOOL.Fire, min = 2, max = 2,
    procMask = MELEE_ALL })
end
-- Timbal's Focusing Crystal: 10% on periodic spell damage, 285-475 shadow damage (15 s cooldown)
IE[34470] = function(p)
  ProcDamage(p, 34470, { name = "Timbal's Focusing Crystal", spellId = 45055, school = SCHOOL.Shadow, min = 285,
    max = 475, callback = "periodic", procMask = PM.SpellDamage, procChance = 0.1, icd = 15 })
end

-- Thunderfury: PPM 6, 300 nature damage (magic hit and crit); a landed one takes 25 nature resistance off the
-- target for 12 s. The bounce (no damage) and the attack speed debuff don't change the player's damage.
IE[19019] = function(p)
  local spell
  local function resistAura(t)
    return t:GetOrRegisterAura({ label = "Thunderfury", actionId = { spellId = 21992 }, duration = 12,
      onGain = function(_, sim) t:AddStatDynamic(sim, ST.NatureResistance, -25) end,
      onExpire = function(_, sim) t:AddStatDynamic(sim, ST.NatureResistance, 25) end })
  end
  spell = p:RegisterSpell({ id = 21992, tag = 1, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC,
    procMask = PM.SpellDamage, flags = F.Proc, damageMultiplier = 1, threatMultiplier = 0.5,
    applyEffects = function(sim, t, sp)
      local r = sp:CalcAndDealDamage(sim, t, 300, OUT.MagicHitAndCrit)
      if S.Landed(r) then resistAura(r.target):Activate(sim) end
    end })
  WeaponProc(p, 19019, 6, function(sim, _, result) spell:Cast(sim, result.target) end)
end

-- Blinkstrike: PPM 1, an extra main-hand swing (a Heroic Strike queued takes it).
IE[31332] = function(p)
  local swing
  WeaponProc(p, 31332, 1, function(sim, _, result)
    swing = swing or S.WarriorExtraSwing(p, 31332)
    S.MaybeReplaceMHSwing(p, sim, swing):Cast(sim, result.target)
  end, true)
end

-- Rod of the Sun King: PPM 1, 10 energy (rogues, cats) or 5 rage.
IE[29996] = function(p)
  if not p.hasEnergy and not p.hasRage then return end
  WeaponProc(p, 29996, 1, function(sim)
    if p.hasEnergy then p:AddEnergy(sim, 10, "rod_of_the_sun_king")
    elseif p.hasRage then p:AddRage(sim, 5, "rod_of_the_sun_king") end
  end, true)
end

-- Syphon of the Nathrezim: PPM 1 opens Siphon Essence for 6 s: every melee hit deals 20 shadow damage.
IE[32262] = function(p)
  local dmg = p:RegisterSpell({ id = 40293, school = SCHOOL.Shadow, procMask = PM.Empty,
    flags = F.PassiveSpell + F.Proc, damageMultiplier = 1,
    applyEffects = function(sim, t, sp) sp:CalcAndDealDamage(sim, t, 20, OUT.AlwaysHit) end })
  local a = p:MakeProcTriggerAura({ name = "Siphon Essence", duration = 6, procMask = PM.Melee, callback = "hit",
    handler = function(sim, _, result) dmg:Cast(sim, result.target) end })
  WeaponProc(p, 32262, 1, function(sim) a:Activate(sim) end)
end

-- Hand of Justice: 1.3333% per landed hit, 2 s cooldown, one extra main-hand swing.
IE[11815] = function(p)
  local spell = ExtraAttackSpell(p, "hoj")
  local mask = 0
  if p.gear.MainHand then mask = mask + PM.MeleeMH end
  if p.gear.OffHand and p.gear.OffHand.item.weaponType and p.gear.OffHand.item.weaponType ~= 5 and p.gear.OffHand.item.weaponType ~= 7 then
    mask = mask + PM.MeleeOH
  end
  p:MakeProcTriggerAura({ name = "Hand Of Justice", dpm = S.NewPPM(p, 0, mask, 0.013333), icd = 2,
    triggerImmediately = true, outcome = O.Landed, callback = "hit",
    handler = function(sim, _, result) spell:Cast(sim, result.target) end })
end

-- Despair: 600 physical damage, PPM 1, can't be dodged / parried / blocked.
IE[28573] = function(p)
  local spell = p:RegisterSpell({ id = 34580, school = SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.Empty,
    flags = F.PassiveSpell + F.IgnoreResists + F.NoOnCastComplete + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, target, sp)
      sp:CalcAndDealDamage(sim, target, 600, OUT.MeleeSpecialNoBlockDodgeParry)
    end })
  WeaponProc(p, 28573, 1, function(sim, _, result) spell:Cast(sim, result.target) end, true)
end

-- Bonereaver's Edge: PPM 2, +700 armor penetration per stack (3), 10 s.
IE[17076] = function(p)
  local a = StackingStatAura(p, "Bonereaver's Edge", 10, 3, { [ST.ArmorPenetration] = 700 })
  WeaponProc(p, 17076, 2, function(sim) a:Activate(sim); a:AddStack(sim) end)
end

-- Stacking trinkets (shared_utils.go buildProcAura / buildStackingCDAuras): a window aura opens a stacking stat
-- aura with no duration of its own and ends it on expiry; a trigger attached to the window adds the stacks.
local MELEE_RANGED = PM.Melee + PM.Ranged
local function StackWindow(p, label, duration, maxStacks, bonus)
  local stats = StackingStatAura(p, label .. " Stacks", huge, maxStacks, bonus)
  local window = p:RegisterAura({ label = label, duration = duration })
  window.onGain = function(_, sim) stats:Activate(sim) end
  window.onExpire = function(_, sim) stats:Deactivate(sim) end
  return window, stats
end

-- Blackened Naaru Sliver: 10% on landed melee / ranged hits (45 s cooldown) opens Battle Trance for 20 s; every
-- landed hit in it adds 44 attack power, up to 10 stacks.
IE[34427] = function(p)
  local window, stats = StackWindow(p, "Battle Trance", 20, 10, { [ST.AttackPower] = 44, [ST.RangedAttackPower] = 44 })
  S.AttachProcTrigger(window, p, { name = "Blackened Naaru Sliver Stack Trigger", callback = "hit",
    procMask = MELEE_RANGED, outcome = O.Landed, procChance = 1,
    handler = function(sim) if stats.active then stats:AddStack(sim) end end })
  p:MakeProcTriggerAura({ name = "Blackened Naaru Sliver", callback = "hit", procMask = MELEE_RANGED,
    outcome = O.Landed, requireDamageDealt = true, procChance = 0.1, icd = 45,
    handler = function(sim) window:Activate(sim) end })
end

-- Badge of the Swarmguard: use (3 min) opens a 30 s window; landed melee / ranged hits that deal damage add
-- 200 armor penetration at 10 PPM, up to 6 stacks.
IE[21670] = function(p)
  local window, stats = StackWindow(p, "Badge of the Swarmguard", 30, 6, { [ST.ArmorPenetration] = 200 })
  S.AttachProcTrigger(window, p, { name = "Badge of the Swarmguard", callback = "hit", procMask = MELEE_RANGED,
    outcome = O.Landed, requireDamageDealt = true, dpm = S.NewPPM(p, 10, MELEE_RANGED),
    handler = function(sim) if stats.active then stats:AddStack(sim) end end })
  local spell = p:RegisterSpell({ id = "item:21670", procMask = PM.Empty, flags = F.NoOnCastComplete, cd = 180,
    applyEffects = function(sim)
      stats:Activate(sim)
      window:Activate(sim)
    end })
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end

-- Talisman of Ascendance: use (1 min; 20 s shared trinket cooldown) opens a 20 s window; every landed special
-- melee / ranged hit or damage spell adds 40 spell damage / 75 healing, up to 5 stacks.
IE[22678] = function(p)
  local window, stats = StackWindow(p, "Talisman of Ascendance", 20, 5, S.WSStats({ [4] = 75, [5] = 40 }))
  S.AttachProcTrigger(window, p, { name = "Talisman of Ascendance", callback = "hit", outcome = O.Landed,
    procMask = PM.MeleeMHSpecial + PM.MeleeOHSpecial + PM.RangedAuto + PM.RangedSpecial + PM.SpellDamage, procChance = 1,
    handler = function(sim) if stats.active then stats:AddStack(sim) end end })
  local spell = p:RegisterSpell({ id = "item:22678", procMask = PM.Empty, flags = F.NoOnCastComplete, cd = 60,
    sharedCd = 20, sharedCdTimer = p:CategoryTimer(1141), relatedSelfBuff = stats,
    applyEffects = function(sim)
      stats:Activate(sim)
      window:Activate(sim)
    end })
  p:AddMajorCooldown({ spell = spell })
end

-- World Breaker: PPM 1, +900 crit rating for the next 2 melee hits (4 s).
IE[30090] = function(p)
  local a = p:RegisterAura({ label = "World Breaker", duration = 4, maxStacks = 2 })
  a:AttachStatBuff(ST.MeleeCritRating, 900)
  S.AttachProcTrigger(a, p, { name = "World Breaker - Consume", procMask = PM.Melee, callback = "hit",
    handler = function(sim) if a.active then a:RemoveStack(sim) end end })
  WeaponProc(p, 30090, 1, function(sim) a:Activate(sim); a:AddStack(sim) end, true)
end

-- Warp Slicer / Devastation: PPM 2, attack speed +20% for 30 s.
local function SpeedInfusion(id)
  IE[id] = function(p)
    local a = p:RegisterAura({ label = "Speed Infusion", duration = 30 })
    a:AttachMultiplyAttackSpeed(1.2)
    WeaponProc(p, id, 2, function(sim) a:Activate(sim) end)
  end
end
SpeedInfusion(30311)
SpeedInfusion(30316)

-- Infinity Blade: PPM 2, target takes +5% magic damage per stack (5), 30 s.
IE[30312] = function(p)
  local t = p.currentTarget
  local schools = { SCHOOL.Arcane, SCHOOL.Fire, SCHOOL.Frost, SCHOOL.Holy, SCHOOL.Nature, SCHOOL.Shadow }
  local a = t:RegisterAura({ label = "Magic Disruption", duration = 30, maxStacks = 5,
    onStacksChange = function(_, _, old, new)
      for _, s in ipairs(schools) do
        local i = S.SCHOOL_INDEX[s]
        t.ps.SchoolDamageTakenMultiplier[i] = t.ps.SchoolDamageTakenMultiplier[i] * (1 + 0.05 * new) / (1 + 0.05 * old)
      end
    end })
  WeaponProc(p, 30312, 2, function(sim) a:Activate(sim); a:AddStack(sim) end)
end

-- Jom Gabbar: use, +65 AP every 2 s for 20 s (10 stacks), 2 min, shares the offensive trinket timer.
IE[23570] = function(p)
  local a = StackingStatAura(p, "Jom Gabbar", 20, 10, { [ST.AttackPower] = 65, [ST.RangedAttackPower] = 65 })
  local og = a.onGain
  a.onGain = function(aura, sim)
    if og then og(aura, sim) end
    for i = 0, 9 do
      sim:Add({ at = sim.now + i * 2, prio = S.PRIO_AUTO, fn = function(s) if aura.active then aura:AddStack(s) end end })
    end
  end
  local spell = p:RegisterSpell({ id = 29602, procMask = PM.Empty, flags = F.NoOnCastComplete, cd = 120,
    sharedCd = 20, sharedCdTimer = p:CategoryTimer(1141),
    applyEffects = function(sim) a:Activate(sim) end })
  p:AddMajorCooldown({ spell = spell, priority = 0 })
end

-- Romulo's Poison Vial: PPM 1 on melee / ranged hits, 222-332 nature damage.
IE[28579] = function(p)
  local spell = p:RegisterSpell({ id = 34587, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, procMask = PM.SpellDamage,
    flags = F.PassiveSpell + F.NoOnCastComplete + F.Proc, damageMultiplier = 1, threatMultiplier = 1,
    applyEffects = function(sim, target, sp) sp:CalcAndDealDamage(sim, target, sim:Roll(222, 332), OUT.MagicHit) end })
  p:MakeProcTriggerAura({ name = "Romulo's Poison Vial", dpm = S.NewPPM(p, 1, PM.MeleeOrRanged), requireDamageDealt = true,
    outcome = O.Landed, callback = "hit", handler = function(sim, _, result) spell:Cast(sim, result.target) end })
end

-- Darkmoon Card: Crusade: +6 AP per landed melee hit (20 stacks, 10 s); +8 spell damage per landed class spell.
IE[31856] = function(p)
  local melee = StackingStatAura(p, "Aura of the Crusader (Melee)", 10, 20, { [ST.AttackPower] = 6, [ST.RangedAttackPower] = 6 })
  local caster = StackingStatAura(p, "Aura of the Crusader (Caster)", 10, 10, { [ST.SpellDamage] = 8 })
  p:MakeProcTriggerAura({ name = "DMC Crusade (Melee)", procMask = PM.MeleeOrRanged, outcome = O.Landed, callback = "hit",
    handler = function(sim) melee:Activate(sim); melee:AddStack(sim) end })
  p:MakeProcTriggerAura({ name = "DMC Crusade (Caster)", procMask = PM.SpellDamage, canProcFromProcs = true,
    classSpellsOnly = true, outcome = O.Landed, callback = "hit",
    handler = function(sim) caster:Activate(sim); caster:AddStack(sim) end })
end

-- Darkmoon Card: Wrath: +17 crit rating per non-crit landed hit (20 stacks, 10 s), reset by a crit.
IE[31857] = function(p)
  local a = StackingStatAura(p, "Aura of Wrath", 10, 20, { [ST.MeleeCritRating] = 17, [ST.SpellCritRating] = 17 })
  p:MakeProcTriggerAura({ name = "Darkmoon Card: Wrath", procMask = PM.Direct, outcome = O.Landed, callback = "hit",
    handler = function(sim, _, result)
      if has(result.outcome, O.Crit) then a:Deactivate(sim) else a:Activate(sim); a:AddStack(sim) end
    end })
end

-- Mark of the Champion: +150 attack power (or +85 spell damage) against undead and demons.
IE[23206] = function(p)
  p.postFinalize[#p.postFinalize + 1] = function()
    for t, at in pairs(p.attackTables) do
      if t.mobType == "Undead" or t.mobType == "Demon" then at.mobBonusAP = (at.mobBonusAP or 0) + 150 end
    end
  end
end
IE[23207] = function(p)
  p.postFinalize[#p.postFinalize + 1] = function()
    for t, at in pairs(p.attackTables) do
      if t.mobType == "Undead" or t.mobType == "Demon" then at.mobBonusSP = (at.mobBonusSP or 0) + 85 end
    end
  end
end

-- Braided Eternium Chain: +28 melee crit rating to the party, the wearer included (exclusive with the party buff).
IE[24114] = function(p) p:AddStat(ST.MeleeCritRating, 28) end
-- Eye of the Night: +34 spell damage to the party.
IE[24116] = function(p) p:AddStat(ST.SpellDamage, 34) end
-- Chain of the Twilight Owl: +2% spell crit to the party.
IE[24121] = function(p) p:AddStat(ST.SpellCritPercent, 2) end

-- ---------------------------------------------------------------------------------------------------------------
-- Crafted and dungeon set bonuses (common/tbc/items_sets.go). Stat bonuses are part of the gear (build phase).
-- ---------------------------------------------------------------------------------------------------------------
S.SET_BONUSES = S.SET_BONUSES or {}
do
  local SB = S.SET_BONUSES
  local function stats(t, profession)
    return function(p)
      if profession and p.professions[1] ~= profession and p.professions[2] ~= profession then return end
      for k, v in pairs(t) do p:AddStat(ST[k], v) end
    end
  end
  -- "Your attacks have a chance to grant you 160 attack power for 15 sec." (2% on any hit)
  local function heroicResolution(p, a)
    local buff = p:NewTemporaryStatsAura("Heroic Resolution", { [ST.AttackPower] = 160, [ST.RangedAttackPower] = 160 }, 15)
    S.AttachProcTrigger(a, p, { name = "Heroic Resolution", callback = "hit", procChance = 0.02,
      handler = function(sim) buff:Activate(sim) end })
  end
  SB["Doomplate Battlegear"] = { [2] = stats({ MeleeHitRating = 35 }), [4] = heroicResolution }
  SB["Wastewalker Armor"] = { [2] = stats({ MeleeHitRating = 35 }), [4] = heroicResolution }
  SB["Mana-Etched Regalia"] = { [2] = stats({ SpellHitRating = 35 }), [4] = function(p, a)
    local buff = p:NewTemporaryStatsAura("Spell Power Bonus", { [ST.SpellDamage] = 110, [ST.HealingPower] = 110 }, 15)
    S.AttachProcTrigger(a, p, { name = "Mana Etched Regalia 4pc", callback = "hit", procChance = 0.02,
      procMask = PM.SpellDamage, handler = function(sim) buff:Activate(sim) end })
  end }
  SB["Burning Rage"] = { [2] = stats({ MeleeHitRating = 20 }, "Blacksmithing") }
  SB["Khorium Ward"] = { [3] = stats({ HealingPower = 55, SpellDamage = 19 }, "Blacksmithing") }
  SB["Netherstrike Armor"] = { [3] = stats({ SpellDamage = 23, HealingPower = 23 }) }
  SB["Netherscale Armor"] = { [3] = stats({ MeleeHitRating = 20 }) }
  SB["Windhawk Armor"] = { [3] = stats({ MP5 = 8 }) }
  SB["Primal Intent"] = { [3] = stats({ AttackPower = 40 }) }
  SB["Felscale Armor"] = { [2] = stats({ MeleeCritRating = 15 }), [4] = stats({ Stamina = 20 }) }
  SB["Thick Draenic Armor"] = { [2] = stats({ MeleeHitRating = 15 }), [4] = stats({ MeleeCritRating = 15 }) }
  SB["Fel Skin"] = { [3] = stats({ DodgeRating = 20 }, "Leatherworking") }
  SB["Strength of the Clefthoof"] = { [3] = stats({ Strength = 20 }, "Leatherworking") }
  SB["Spellstrike Infusion"] = { [2] = function(p, a)
    if p.professions[1] ~= "Tailoring" and p.professions[2] ~= "Tailoring" then return end
    local buff = p:NewTemporaryStatsAura("Lesser Spell Blasting", { [ST.SpellDamage] = 92 }, 10)
    S.AttachProcTrigger(a, p, { name = "Spellstrike Infusion 2pc", callback = "hit", procChance = 0.05,
      procMask = PM.SpellDamage, canProcFromProcs = true, classSpellsOnly = true,
      handler = function(sim) buff:Activate(sim) end })
  end }
  SB["Wrath of Spellfire"] = { [3] = function(p) p:AddStatDependency(ST.Intellect, ST.SpellDamage, 0.07) end }
  SB["Soulcloth Embrace"] = { [3] = stats({ SpellHitRating = 16 }) }
  SB["Imbued Netherweave"] = { [3] = stats({ SpellCritRating = 28 }) }
  SB["Netherweave Vestments"] = { [2] = stats({ SpellDamage = 23, HealingPower = 23 }), [4] = stats({ SpellCritRating = 14 }) }
  SB["Arcanoweave Vestments"] = { [3] = stats({ SpellHitRating = 16 }) }
  -- Warglaives of Azzinoth (items_weapons.go), Rogues and Warriors: 450 haste rating for 10 s (1 PPM on the sword
  -- hands, 45 s cooldown) and +200 attack power against demons.
  SB["The Twin Blades of Azzinoth"] = { [2] = function(p, a)
    if p.class ~= "Rogue" and p.class ~= "Warrior" then return end
    local buff = p:NewTemporaryStatsAura("The Twin Blades of Azzinoth", { [ST.MeleeHasteRating] = 450 }, 10)
    S.AttachProcTrigger(a, p, { name = "The Twin Blades of Azzinoth - Trigger", dpm = S.NewPPM(p, 1, S.ProcMaskForTypes(p, 9)),
      icd = 45, outcome = O.Landed, callback = "hit", handler = function(sim) buff:Activate(sim) end })
    local function demons(d)
      for t, at in pairs(p.attackTables) do
        if t.mobType == "Demon" then at.mobBonusAP = (at.mobBonusAP or 0) + d end
      end
    end
    local og, oe = a.onGain, a.onExpire
    a.onGain = function(aura, sim) if og then og(aura, sim) end demons(200) end
    a.onExpire = function(aura, sim) if oe then oe(aura, sim) end demons(-200) end
  end }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Caster trinkets, meta gems and weapon enchants (items_trinkets.go, metagems.go, enchants.go)
-- ---------------------------------------------------------------------------------------------------------------
-- The Lightning Capacitor: a charge on each spell crit (2.5 s lockout after a bolt); the third throws a 694-806
-- nature bolt that travels 20 yards a second and can crit.
IE[28785] = function(p)
  local bolt = p:RegisterSpell({ id = 37661, school = SCHOOL.Nature, defenseType = S.DEF_MAGIC, procMask = PM.Empty,
    flags = F.PassiveSpell + F.IgnoreAttackerModifiers, damageMultiplier = 1,
    applyEffects = function(sim, target, spell)
      sim:Add({ at = sim.now + p.distance / 20, prio = 0, fn = function(s)
        spell:CalcAndDealDamage(s, target, s:Roll(694, 806), OUT.MagicHitAndCrit)
      end })
    end })
  local icd = p:NewTimer()
  local charge = p:RegisterAura({ label = "Electrical Charge", actionId = { spellId = 37658 }, maxStacks = 3 })
  p:MakeProcTriggerAura({ name = "The Lightning Capacitor", procMask = PM.SpellDamage, canProcFromProcs = true,
    outcome = O.Crit, callback = "hit",
    handler = function(sim)
      if icd.readyAt > sim.now then return end
      charge:Activate(sim)
      if charge.stacks + 1 >= 3 then
        charge:Deactivate(sim)
        bolt:Cast(sim, p.currentTarget)
        icd.readyAt = sim.now + 2.5
      else
        charge:AddStack(sim)
      end
    end })
end

-- Eye of Magtheridon: a resisted spell gives 170 spell damage for 10 s.
IE[28789] = function(p)
  local a = p:NewTemporaryStatsAura("Recurring Power", { [ST.SpellDamage] = 170, [ST.HealingPower] = 170 }, 10)
  p:MakeProcTriggerAura({ name = "Eye of Magtheridon", classSpellsOnly = true, outcome = O.Miss, callback = "hit",
    handler = function(sim) a:Activate(sim) end })
end

-- Pendant of the Violet Eye: for 20 s every spell that costs mana adds 21 mp5 (up to 20 times).
IE[28727] = function(p)
  local stacks = StackingStatAura(p, "Enlightenment", huge, 20, { [ST.MP5] = 21 })
  local trigger = p:RegisterAura({ label = "Enlightenment Trigger", actionId = { spellId = 29601 }, duration = 20,
    onExpire = function(_, sim) stacks:Deactivate(sim) end })
  S.AttachProcTrigger(trigger, p, { name = "Enlightenment", callback = "cast", procMask = PM.SpellDamage + PM.SpellHealing,
    extraCondition = function(_, spell) return (spell.curCost or 0) > 0 end,
    handler = function(sim) stacks:Activate(sim); stacks:AddStack(sim) end })
  local spell = p:RegisterSpell({ id = "item:28727", procMask = PM.Empty, cd = 120, relatedSelfBuff = trigger,
    applyEffects = function(sim) trigger:Activate(sim) end })
  p:AddMajorCooldown({ spell = spell })
end

-- Shifting Naaru Sliver: 320 spell damage for 15 s (2 min; shares the offensive trinket cooldown for 15 s).
IE[34429] = function(p)
  local a = p:NewTemporaryStatsAura("Power Circle", { [ST.SpellDamage] = 320, [ST.HealingPower] = 320 }, 15)
  local spell = p:RegisterSpell({ id = "item:34429", procMask = PM.Empty, cd = 120, sharedCd = 15,
    sharedCdTimer = p:CategoryTimer(1141), relatedSelfBuff = a,
    applyEffects = function(sim) a:Activate(sim) end })
  p:AddMajorCooldown({ spell = spell })
end

-- Mystical Skyfire Diamond: 15% on a cast, 320 spell haste rating for 4 s (35 s cooldown).
IE[25893] = function(p)
  local a = p:NewTemporaryStatsAura("Focus", { [ST.SpellHasteRating] = 320 }, 4)
  p:MakeProcTriggerAura({ name = "Mystical Skyfire Diamond", procChance = 0.15, classSpellsOnly = true, icd = 35,
    callback = "cast", handler = function(sim) a:Activate(sim) end })
end
-- Bracing Earthstorm Diamond: +26 healing, +9 spell damage
IE[25897] = function(p) p:AddStats({ [ST.HealingPower] = 26, [ST.SpellDamage] = 9 }) end
-- Insightful Earthstorm Diamond: 5% on a cast, 300 mana (15 s cooldown).
IE[25901] = function(p)
  p:MakeProcTriggerAura({ name = "Insightful Earthstorm Diamond", procMask = PM.SpellDamage + PM.SpellHealing,
    procChance = 0.05, icd = 15, callback = "cast", classSpellsOnly = true,
    handler = function(sim) if p.hasMana then p:AddMana(sim, 300, "insightful_earthstorm") end end })
end
-- Thundering Skyfire Diamond: 1.5 PPM on white hits, 240 melee haste rating for 6 s (40 s cooldown).
IE[32410] = function(p)
  local a = p:NewTemporaryStatsAura("Skyfire Swiftness", { [ST.MeleeHasteRating] = 240 }, 6)
  p:MakeProcTriggerAura({ name = "Thundering Skyfire Diamond", dpm = S.NewPPM(p, 1.5, PM.WhiteHit), icd = 40,
    outcome = O.Landed, callback = "hit", handler = function(sim) a:Activate(sim) end })
end
-- Eternal Earthstorm Diamond: block value +10%
IE[35501] = function(p) p.ps.BlockValueMultiplier = p.ps.BlockValueMultiplier * 1.1 end
-- Ember Skyfire Diamond: intellect +2%
IE[35503] = function(p) p:MultiplyStat(ST.Intellect, 1.02) end

S.ENCHANT_EFFECTS = S.ENCHANT_EFFECTS or {}
local function EnchantedHands(p, id)
  local m = 0
  if p.gear.MainHand and p.gear.MainHand.spec.enchant == id then m = m + PM.MeleeMH end
  if p.gear.OffHand and p.gear.OffHand.spec.enchant == id then m = m + PM.MeleeOH end
  return m
end
-- Executioner: 1 PPM, 840 armor penetration for 15 s.
S.ENCHANT_EFFECTS[3225] = function(p)
  local a = p:NewTemporaryStatsAura("Executioner", { [ST.ArmorPenetration] = 840 }, 15)
  p:MakeProcTriggerAura({ name = "Enchant Weapon - Executioner", callback = "hit", isWeaponProc = true,
    dpm = S.NewPPM(p, 1, EnchantedHands(p, 3225)), outcome = O.Landed, handler = function(sim) a:Activate(sim) end })
end
-- Deathfrost: 50% on melee hits or on spell damage (25 s lockout), 150 frost damage that can crit.
S.ENCHANT_EFFECTS[3273] = function(p)
  local spell = p:RegisterSpell({ id = 46579, school = SCHOOL.Frost, defenseType = S.DEF_MAGIC,
    flags = F.NoOnCastComplete + F.PassiveSpell + F.Proc, procMask = PM.SpellDamage, damageMultiplier = 1,
    threatMultiplier = 1,
    applyEffects = function(sim, target, sp) sp:CalcAndDealDamage(sim, target, 150, OUT.MagicCrit) end })
  local lockout = p:NewTimer()
  local melee = S.NewPPM(p, 0, PM.Melee, 0.5)
  local function handler(sim, _, result) spell:Cast(sim, result.target) end
  p:MakeProcTriggerAura({ name = "Enchant Weapon - Deathfrost (Melee)", callback = "hit", isWeaponProc = true,
    outcome = O.Landed,
    extraCondition = function(sim, sp)
      if lockout.readyAt > sim.now or not melee.Proc(sim, sp.procMask) then return false end
      lockout.readyAt = sim.now + 25
      return true
    end, handler = handler })
  p:MakeProcTriggerAura({ name = "Enchant Weapon - Deathfrost (Spell)", callback = { "hit", "periodic" },
    procMask = PM.SpellDamage, outcome = O.Landed,
    extraCondition = function(sim)
      if lockout.readyAt > sim.now or not sim:Proc(0.5) then return false end
      lockout.readyAt = sim.now + 25
      return true
    end, handler = handler })
end
-- +7 weapon damage
S.ENCHANT_EFFECTS[963] = function(p)
  local aa = p.autoAttacks
  if p.gear.MainHand and p.gear.MainHand.spec.enchant == 963 then aa.mh.baseMin = aa.mh.baseMin + 7; aa.mh.baseMax = aa.mh.baseMax + 7 end
  if p.gear.OffHand and p.gear.OffHand.spec.enchant == 963 and aa.isDualWielding then
    aa.oh.baseMin = aa.oh.baseMin + 7; aa.oh.baseMax = aa.oh.baseMax + 7
  end
end

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Attack.lua", ...) then return end -- DisasterZone: Sim/Attack.lua
-- ns.GearSim auto attacks (attack.go) and the unit's GCD / rotation timers and reset (gcd.go, unit.go).
local _, ns = ...
local S = ns.GearSim
local ST, PM, F, OUT = S.ST, S.PM, S.F, S.OUT

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

-- ---------------------------------------------------------------------------------------------------------------
-- Weapons
-- ---------------------------------------------------------------------------------------------------------------
-- item: { min, max, speed, twoHand, dagger, ranged }
function S.WeaponFromItem(item, bonusDps)
  bonusDps = bonusDps or 0
  local norm = 2.4
  if item.dagger then norm = 1.7 elseif item.twoHand then norm = 3.3 elseif item.ranged then norm = 2.8 end
  return {
    baseMin = item.min + bonusDps * item.speed,
    baseMax = item.max + bonusDps * item.speed,
    swingSpeed = item.speed,
    normalizedSpeed = norm,
    apPerDps = 14,
    twoHand = item.twoHand,
    quality = item.quality,
    weaponType = item.weaponType,
    handType = item.handType,
    rangedWeaponType = item.rangedWeaponType,
  }
end

function S.UnarmedWeapon()
  return { baseMin = 0, baseMax = 0, swingSpeed = 1, normalizedSpeed = 1, apPerDps = 14 }
end

local function BaseDamage(w, sim) return w.baseMin + (w.baseMax - w.baseMin) * sim:Rand() end
S.WeaponBaseDamage = BaseDamage
function S.WeaponAverage(w) return (w.baseMin + w.baseMax) / 2 end
function S.WeaponDamage(w, sim, ap) return BaseDamage(w, sim) + (w.swingSpeed * ap) / w.apPerDps end
function S.WeaponNormalizedDamage(w, sim, ap) return BaseDamage(w, sim) + (w.normalizedSpeed * ap) / w.apPerDps end
-- attack.go CalculateAverageWeaponDamage
function S.WeaponAverageDamage(w, ap) return (w.baseMin + w.baseMax) / 2 + (w.swingSpeed * ap) / w.apPerDps end

-- ---------------------------------------------------------------------------------------------------------------
-- Weapon attacks (one per hand)
-- ---------------------------------------------------------------------------------------------------------------
local WA = {}
WA.__index = WA

local function NewWA(unit, weapon)
  local wa = setmetatable({ unit = unit, swingAt = huge, previousSwing = -huge, curSwingSpeed = 1, curSwingDuration = 0,
    enabled = false }, WA)
  for k, v in pairs(weapon) do wa[k] = v end
  return wa
end

function WA:UpdateSwingDuration(speed)
  self.curSwingSpeed = speed
  self.curSwingDuration = self.swingSpeed / speed
end

function WA:TrySwing(sim)
  if sim.now < self.swingAt then return self.swingAt end
  return self:Swing(sim)
end

function WA:Swing(sim)
  local u = self.unit
  local spell = self.spell
  if self.replaceSwing then
    u:ReactToEvent(sim, false, false)
    if self.replaceSwing then spell = self.replaceSwing(sim, spell) end
  end
  self.previousSwing = self.swingAt
  self.swingAt = sim.now + self.curSwingDuration
  spell:Cast(sim, u.currentTarget)
  if u.rotation then u:ReactToEvent(sim, false, true) end
  return self.swingAt
end

-- attack.go IsInRange: a hand with no range set is always in range
function WA:IsInRange()
  local d = self.unit.distance or 0
  local lo, hi = self.minRange or 0, self.maxRange or 0
  return (lo == 0 or lo < d) and (hi == 0 or hi >= d)
end

function WA:AddToSim(sim, speed)
  if not self.enabled then return end
  self:UpdateSwingDuration(speed)
  sim:AddWeaponAttack(self)
  sim:RescheduleWeaponAttack(self.swingAt)
end

local AA = {}
AA.__index = AA
S.AutoAttacksMT = AA

function S.UnitMT:EnableAutoAttacks(opts)
  local aa = setmetatable({ unit = self, autoSwingMelee = opts.autoSwingMelee, isDualWielding = opts.offHand ~= nil,
    randomMeleeOffset = true }, AA)
  aa.mh = NewWA(self, opts.mainHand)
  aa.oh = NewWA(self, opts.offHand or { swingSpeed = 0, baseMin = 0, baseMax = 0, normalizedSpeed = 0, apPerDps = 14 })
  aa.ranged = NewWA(self, { swingSpeed = 0, baseMin = 0, baseMax = 0, normalizedSpeed = 0, apPerDps = 14 })
  self.autoAttacks = aa
  local unit = self
  aa.mhSpell = self:RegisterSpell({
    id = "melee", tag = 1, school = S.SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeMHAuto,
    flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(aa.mh, sim, spell:MeleeAttackPower(target))
      spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
    end,
  })
  aa.mh.spell = aa.mhSpell
  if aa.isDualWielding then
    aa.ohSpell = self:RegisterSpell({
      id = "melee_oh", tag = 2, school = S.SCHOOL.Physical, defenseType = S.DEF_MELEE, procMask = PM.MeleeOHAuto,
      flags = F.MeleeMetrics + F.IncludeTargetBonusDamage + F.NoOnCastComplete,
      damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
      applyEffects = function(sim, target, spell)
        local base = 0.5 * S.WeaponDamage(aa.oh, sim, spell:MeleeAttackPower(target))
        spell:CalcAndDealDamage(sim, target, base, OUT.MeleeWhite)
      end,
    })
    aa.oh.spell = aa.ohSpell
  end
  return aa
end

function AA:MH() return self.mh end
function AA:OH() return self.oh end

-- attack.go ranged auto attack ("Shoot"): a hardcast of the windup (0.5 s over ranged haste, then spell haste and the
-- millisecond rounding as for any cast), no GCD of its own; the shot travels at 40 yards a second. A hunter's melee
-- hands only swing within melee range (opts.meleeMaxRange), the ranged one between opts.minRange and opts.maxRange.
function AA:EnableRanged(weapon, opts)
  opts = opts or {}
  local u = self.unit
  local wa = NewWA(u, weapon)
  wa.minRange, wa.maxRange = opts.minRange, opts.maxRange
  self.ranged = wa
  self.autoSwingRanged = true
  if opts.meleeMaxRange then self.mh.maxRange, self.oh.maxRange = opts.meleeMaxRange, opts.meleeMaxRange end
  local aa = self
  wa.spell = u:RegisterSpell({
    id = "shoot", school = weapon.school or S.SCHOOL.Physical, defenseType = S.DEF_RANGED, procMask = PM.RangedAuto,
    flags = F.MeleeMetrics + F.IncludeTargetBonusDamage, missileSpeed = 40,
    damageMultiplier = 1, damageMultiplierAdditive = 1, threatMultiplier = 1, bonusCoefficient = 1,
    castTime = 1e-9,
    castTimeFn = function() return aa:RangedSwingWindup() end,
    modifyCast = function(sim, spell, gcd) return gcd, aa:RangedSwingWindup() end,
    applyEffects = function(sim, target, spell)
      local base = S.WeaponDamage(wa, sim, spell:RangedAttackPower(target))
      local r = spell:CalcDamage(sim, target, base, OUT.RangedHitAndCrit)
      S.Travel(u, sim, 40, function(s) spell:DealDamage(s, r) end)
      -- attack.go: react once more (movement actions)
      if u.rotation then u:ReactToEvent(sim, false, true) end
    end,
  })
  self.rangedSpell = wa.spell
  return wa
end

function AA:RangedSwingWindup() return 0.5 / self.unit:TotalRangedHasteMultiplier() end
function AA:NextRangedAttackAt() return self.ranged.swingAt end
function AA:RangedSwingSpeed() return self.ranged.curSwingDuration end

function AA:Reset(sim)
  if not self.autoSwingMelee and not self.autoSwingRanged then return end
  local u = self.unit
  self.mh.enabled, self.oh.enabled, self.ranged.enabled = false, false, false
  if self.autoSwingMelee then
    self.mh:UpdateSwingDuration(u:TotalMeleeHasteMultiplier())
    self.mh.previousSwing = -self.mh.curSwingDuration
    self.mh.swingAt = 0
    if self.isDualWielding then
      self.oh:UpdateSwingDuration(u:TotalMeleeHasteMultiplier())
      self.oh.previousSwing = -self.oh.curSwingDuration
      self.oh.swingAt = self.oh.swingSpeed / 2
    else
      self.oh.previousSwing, self.oh.swingAt = -huge, huge
    end
  else
    self.mh.previousSwing, self.mh.swingAt = -huge, huge
    self.oh.previousSwing, self.oh.swingAt = -huge, huge
  end
  self.ranged.previousSwing, self.ranged.swingAt = -huge, huge
  if self.autoSwingRanged then
    self.ranged:UpdateSwingDuration(u:TotalRangedHasteMultiplier())
    self.ranged.previousSwing = -self.ranged.curSwingDuration
    self.ranged.swingAt = 0
  end
end

function AA:StartPull(sim)
  if not self.autoSwingMelee and not self.autoSwingRanged then return end
  if self.mh.enabled or self.oh.enabled or self.ranged.enabled then return end
  local u = self.unit
  if self.autoSwingMelee then
    if self.mh.swingAt == huge then self.mh.swingAt = 0 end
    if self.isDualWielding and self.oh:IsInRange() then
      self.oh.enabled = true
      self.oh:AddToSim(sim, u:TotalMeleeHasteMultiplier())
    end
    if self.mh:IsInRange() then
      self.mh.enabled = true
      self.mh:AddToSim(sim, u:TotalMeleeHasteMultiplier())
    end
  end
  if self.autoSwingRanged then
    if self.ranged.swingAt == huge then self.ranged.swingAt = 0 end
    if self.ranged:IsInRange() then
      self.ranged.enabled = true
      self.ranged:AddToSim(sim, u:TotalRangedHasteMultiplier())
    end
  end
end

function AA:UpdateSwingTimers(sim)
  if not (self.mh.enabled or self.oh.enabled or self.ranged.enabled) then return end
  local u = self.unit
  -- ranged attack speed changes aren't applied mid-swing
  if self.autoSwingRanged and self.ranged.enabled then self.ranged:UpdateSwingDuration(u:TotalRangedHasteMultiplier()) end
  if self.autoSwingMelee and self.mh.enabled then
    local old = self.mh.curSwingSpeed
    self.mh:UpdateSwingDuration(u:TotalMeleeHasteMultiplier())
    local f = old / self.mh.curSwingSpeed
    local rem = self.mh.swingAt - sim.now
    if rem > 0 then self.mh.swingAt = sim.now + rem * f end
    sim:RescheduleWeaponAttack(self.mh.swingAt)
    if self.isDualWielding and self.oh.enabled then
      self.oh:UpdateSwingDuration(u:TotalMeleeHasteMultiplier())
      rem = self.oh.swingAt - sim.now
      if rem > 0 then self.oh.swingAt = sim.now + rem * f end
      sim:RescheduleWeaponAttack(self.oh.swingAt)
    end
  end
end

function AA:NextAttackAt() return min(self.mh.swingAt, self.oh.swingAt) end

-- attack.go SetMH: another weapon in the main hand (a druid's paws), the swing timer kept.
local WEAPON_FIELDS = { "baseMin", "baseMax", "swingSpeed", "normalizedSpeed", "apPerDps", "twoHand", "weaponType", "handType" }
function AA:SetMH(weapon)
  local wa = self.mh
  for _, k in ipairs(WEAPON_FIELDS) do wa[k] = weapon[k] end
  wa:UpdateSwingDuration(wa.curSwingSpeed)
end

-- attack.go EnableMeleeSwing (no ranged swing here): nothing before the pull; in combat a stopped hand starts again.
function AA:EnableAutoSwing(sim)
  self:EnableMeleeSwing(sim)
  self:EnableRangedSwing(sim)
end

function AA:EnableMeleeSwing(sim)
  if not self.autoSwingMelee or sim.isInPrepull then return end
  local u = self.unit
  if not u.currentTarget then return end
  self.mh.swingAt = max(self.mh.swingAt, sim.now, 0)
  if self.mh:IsInRange() and not self.mh.enabled then
    self.mh.enabled = true
    self.mh:AddToSim(sim, u:TotalMeleeHasteMultiplier())
  end
  if self.isDualWielding and not self.oh.enabled then
    -- entering melee range from ranged: the off hand starts half a swing later
    local offset = 0
    if self.autoSwingRanged then
      self.oh:UpdateSwingDuration(u:TotalMeleeHasteMultiplier())
      offset = self.oh.curSwingDuration / 2
    end
    self.oh.swingAt = max(self.oh.swingAt, sim.now + offset, 0)
    if self.oh:IsInRange() then
      self.oh.enabled = true
      self.oh:AddToSim(sim, u:TotalMeleeHasteMultiplier())
    end
  end
end

function AA:EnableRangedSwing(sim)
  if not self.autoSwingRanged or self.ranged.enabled or sim.isInPrepull then return end
  local u = self.unit
  if not u.currentTarget then return end
  self.ranged.swingAt = max(self.ranged.swingAt, sim.now, 0)
  if self.ranged:IsInRange() then
    self.ranged.enabled = true
    self.ranged:AddToSim(sim, u:TotalRangedHasteMultiplier())
  end
end

function AA:CancelMeleeSwing(sim)
  if not self.autoSwingMelee then return end
  if self.mh.enabled then
    sim:RemoveWeaponAttack(self.mh)
    self.mh.enabled = false
  end
  if self.isDualWielding and self.oh.enabled then
    self.oh.enabled = false
    sim:RemoveWeaponAttack(self.oh)
  end
end

function AA:CancelRangedSwing(sim)
  if not self.autoSwingRanged then return end
  if self.ranged.enabled then
    sim:RemoveWeaponAttack(self.ranged)
    self.ranged.enabled = false
  end
end

-- attack.go DelayRangedUntil: a cast pushes the next shot past its end
function AA:DelayRangedUntil(sim, readyAt)
  if readyAt <= self.ranged.swingAt then return end
  self.ranged.swingAt = readyAt
  sim:RescheduleWeaponAttack(readyAt)
end

function AA:DelayMeleeBy(sim, d)
  if d <= 0 then return end
  self.mh.swingAt = self.mh.swingAt + d
  sim:RescheduleWeaponAttack(self.mh.swingAt)
  if self.isDualWielding then
    self.oh.swingAt = self.oh.swingAt + d
    sim:RescheduleWeaponAttack(self.oh.swingAt)
  end
end

function AA:StopMeleeUntil(sim, readyAt)
  if not self.autoSwingMelee then return end
  self.mh.swingAt = readyAt + self.mh.curSwingDuration
  sim:RescheduleWeaponAttack(self.mh.swingAt)
  if self.isDualWielding then
    self.oh.swingAt = readyAt + self.oh.curSwingDuration
    sim:RescheduleWeaponAttack(self.oh.swingAt)
  end
end

-- attack.go RandomizeMeleeTiming: a random whole-millisecond delay below the reaction time.
function AA:RandomizeMeleeTiming(sim)
  if not self.autoSwingMelee then return end
  local rtMs = floor(self.unit.reactionTime * 1000 + 0.5)
  local d = floor(sim:Rand() * rtMs) / 1000
  self:DelayMeleeBy(sim, d)
end

-- ---------------------------------------------------------------------------------------------------------------
-- GCD and rotation timers (gcd.go)
-- ---------------------------------------------------------------------------------------------------------------
local Unit = S.UnitMT

function Unit:SetRotationTimer(sim, at)
  if not self.rotationAction then return end
  self.RotationTimer.readyAt = at
  local pa = self.rotationAction
  if not pa.consumed and not pa.cancelled and pa.queuedIn then sim:Cancel(pa) end
  pa.at = at
  pa.queuedIn = true
  sim:Add(pa)
end

function Unit:SetGCDTimer(sim, at)
  if not self.rotationAction then return end
  self.GCD.readyAt = at
  self:SetRotationTimer(sim, at)
end

function Unit:WaitUntil(sim, at)
  self:SetRotationTimer(sim, at)
end

function Unit:ExtendGCDUntil(sim, at)
  self:SetGCDTimer(sim, at)
end

function Unit:ReactToEvent(sim, randomize, addReaction)
  self.rotation:DoNextAction(sim)
  if self.rotation.waitUntil then return end
  local t = sim.now
  if addReaction then t = t + self.reactionTime end
  if randomize then t = sim.now + sim:Rand() * 2 * self.reactionTime end
  if self.RotationTimer.readyAt > t then self:SetRotationTimer(sim, t) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Reset / pull / end of iteration (unit.go, character.go)
-- ---------------------------------------------------------------------------------------------------------------
function Unit:Reset(sim)
  if self.kind ~= "enemy" then self.enabled = true end
  -- resetCDs: every timer the unit owns
  for _, sp in ipairs(self.spellbook) do
    if sp.cdTimer then sp.cdTimer.readyAt = S.STARTING_CD end
    if sp.sharedCdTimer then sp.sharedCdTimer.readyAt = S.STARTING_CD end
  end
  if self.timers then for _, t in ipairs(self.timers) do t.readyAt = S.STARTING_CD end end
  self.GCD.readyAt = S.STARTING_CD
  self.RotationTimer.readyAt = S.STARTING_CD
  self.hardcastExpires = -huge
  self.hardcastComplete = nil
  self.queued = nil
  self.channeledDot = nil
  -- unit.go reset: back to the starting distance, not moving
  if self.startDistance then self.distance = self.startDistance end
  self.moving, self.movementAction = false, nil
  if self.dynamicPets then for i = #self.dynamicPets, 1, -1 do self.dynamicPets[i] = nil end end
  -- stats back to the initial ones
  for _, d in ipairs(self.deps) do if d.dynamic and d.enabled then d.enabled = false; self.linearCache = nil end end
  S.CopyStats(self.statsWithoutDeps, self.initialStatsWithoutDeps)
  S.CopyStats(self.stats, self.initialStats)
  -- Restore pseudo stats in place: closures hold on to self.ps (and its school arrays).
  for k, v in pairs(self.initialPS) do
    if type(v) == "table" then
      local dst = self.ps[k]
      for i, x in pairs(v) do dst[i] = x end
    else
      self.ps[k] = v
    end
  end
  self:UpdateCastSpeed()
  self:ResetAuras(sim)
  if self.hasMana then
    self.mana = self.stats[ST.Mana]
    self.manaRegenMultiplier = 1
  end
  self:UpdateManaRegenRates()
  if self.autoAttacks then self.autoAttacks:Reset(sim) end
  if self.rotation then self.rotation:Reset(sim) end
  if self.rotationAction then
    self.rotationAction.queuedIn = false
    self.rotationAction.consumed = true
  end
  if self.majorCooldowns then
    self:ResetMajorCooldownOrder()
    self:UpdateMajorCooldowns()
  end
  if self.agentReset then self.agentReset(sim) end
  if self.metrics then self.metrics:ResetIteration(self) end
  sim:AddTracker(self)
  if self.kind ~= "enemy" and self.rotation then
    -- the rotation's first evaluation happens when the GCD timer is set at the pull
  end
end

function Unit:OnEncounterStart(sim)
  if self.agentEncounterStart then self.agentEncounterStart(sim) end
  if self.autoAttacks and self.autoAttacks.autoSwingMelee and self.kind ~= "enemy" and self.autoAttacks.randomMeleeOffset then
    self.autoAttacks:RandomizeMeleeTiming(sim)
  end
  local list = self.onEncounterStart
  for i = 1, #list do local a = list[i]; if a.active then a.onEncounterStart(a, sim) end end
end

function Unit:StartPull(sim)
  if self.autoAttacks then self.autoAttacks:StartPull(sim) end
  if self.kind == "player" then self:SetGCDTimer(sim, max(0, self.GCD.readyAt)) end
end

function Unit:DoneIteration(sim)
  if self.agentDone then self.agentDone(sim) end
  self.hardcastExpires = -huge
  self.hardcastComplete = nil
  self:DeactivateAllAuras(sim)
  if self.metrics then self.metrics:DoneIteration(sim) end
end

-- Deactivate every aura, permanent ones too, so mods and pseudo stats unwind (auraTracker.doneIteration). Pets
-- and targets get this as well: an aura's onStacksChange / onExpire state would otherwise leak into the next
-- iteration (Winter's Chill kept its +10% crit mod for the next fight's first Frostbolt).
function Unit:DeactivateAllAuras(sim)
  local again = true
  while again do
    again = false
    for _, a in ipairs(self.auras) do
      if a.active then
        a:Deactivate(sim)
        again = true
        break
      end
    end
  end
end

function Unit:NewTimer()
  local t = S.NewTimer()
  self.timers = self.timers or {}
  self.timers[#self.timers + 1] = t
  return t
end

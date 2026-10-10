if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Spell.lua", ...) then return end -- DisasterZone: Sim/Spell.lua
-- ns.GearSim spells: the cast pipeline with the 400 ms spell queue (cast.go, spell_queueing.go), mana costs,
-- the attack table and hit outcomes (spell_outcome.go, target.go), the damage pipeline (spell_result.go,
-- spell_resistances.go), spell mods (spell_mod.go) and proc triggers / PPM (aura_helpers.go, procs.go).
local _, ns = ...
local S = ns.GearSim
local ST = S.ST

local floor, huge, max, min = math.floor, math.huge, math.max, math.min
local band = bit and bit.band

-- Bit flags as plain numbers. WoW has the bit library (32 bit only); masks here go past 32 bits (class spell
-- masks), so the test is arithmetic, memoized per (mask, flag) pair - a handful of distinct pairs per fight.
local function hasSlow(mask, flag)
  local f = flag
  local bitv = 1
  while f > 0 do
    if f % 2 == 1 and floor(mask / bitv) % 2 == 1 then return true end
    f = floor(f / 2)
    bitv = bitv * 2
  end
  return false
end
local hasCache = {}
local function has(mask, flag)
  local row = hasCache[mask]
  if not row then
    row = {}
    hasCache[mask] = row
  end
  local v = row[flag]
  if v == nil then
    v = hasSlow(mask, flag)
    row[flag] = v
  end
  return v
end
S.has = has

local function bor(...)
  local r = 0
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    local bitv = 1
    local x, y = r, v
    local out = 0
    while x > 0 or y > 0 do
      if x % 2 == 1 or y % 2 == 1 then out = out + bitv end
      x, y = floor(x / 2), floor(y / 2)
      bitv = bitv * 2
    end
    r = out
  end
  return r
end
S.bor = bor

-- ProcMask (flags.go)
local PM = {}
PM.Empty = 2; PM.MeleeMHAuto = 4; PM.MeleeOHAuto = 8; PM.MeleeMHSpecial = 16; PM.MeleeOHSpecial = 32
PM.RangedAuto = 64; PM.RangedSpecial = 128; PM.SpellDamage = 256; PM.SpellHealing = 512; PM.SpellDamageProc = 1024
PM.MeleeMH = PM.MeleeMHAuto + PM.MeleeMHSpecial
PM.MeleeOH = PM.MeleeOHAuto + PM.MeleeOHSpecial
PM.MeleeWhiteHit = PM.MeleeMHAuto + PM.MeleeOHAuto
PM.WhiteHit = PM.MeleeWhiteHit + PM.RangedAuto
PM.MeleeSpecial = PM.MeleeMHSpecial + PM.MeleeOHSpecial
PM.MeleeOrRangedSpecial = PM.MeleeSpecial + PM.RangedSpecial
PM.Melee = PM.MeleeWhiteHit + PM.MeleeSpecial
PM.Ranged = PM.RangedAuto + PM.RangedSpecial
PM.MeleeOrRanged = PM.Melee + PM.Ranged
PM.Direct = PM.Melee + PM.Ranged + PM.SpellDamage
PM.Special = PM.MeleeOrRangedSpecial + PM.SpellDamage
S.PM = PM

-- HitOutcome
local O = {}
O.Miss = 2; O.Hit = 4; O.Dodge = 8; O.Glance = 16; O.Parry = 32; O.Block = 64; O.Crit = 128; O.SuppressedCrit = 256
O.Crush = 512; O.Partial1 = 1024; O.Partial2 = 2048; O.Partial3 = 4096
O.Partial = O.Partial1 + O.Partial2 + O.Partial3
O.Landed = O.Hit + O.Crit + O.Crush + O.SuppressedCrit + O.Glance + O.Block
S.O = O

-- SpellFlag (only the ones the port reads)
local F = {}
F.IgnoreResists = 1; F.IgnoreTargetModifiers = 2; F.IgnoreAttackerModifiers = 4; F.ApplyArmorReduction = 8
F.CannotBeDodged = 16; F.IncludeTargetBonusDamage = 32; F.Binary = 64; F.Channeled = 128; F.Helpful = 256
F.MeleeMetrics = 512; F.NoOnCastComplete = 1024; F.APL = 2048; F.MCD = 4096; F.Reactive = 8192
F.NoOnDamageDealt = 16384; F.Potion = 32768; F.NoSpellMods = 65536; F.PassiveSpell = 131072
F.SuppressWeaponProcs = 262144; F.Proc = 524288; F.Explosive = 1048576; F.Conjured = 2097152
F.NoMetrics = 4194304; F.Poison = 134217728
-- SpellFlagAgentReserved1-4: the class's own flags (shaman: ShamanSpell, Shock, Instant, Focusable)
F.Agent1 = 8388608; F.Agent2 = 16777216; F.Agent3 = 33554432; F.Agent4 = 67108864
S.F = F

-- SpellSchool and school index (stats.SchoolIndex order: none, physical, arcane, fire, frost, holy, nature, shadow)
local SCHOOL = { Physical = 1, Holy = 2, Fire = 4, Nature = 8, Frost = 16, Shadow = 32, Arcane = 64 }
S.SCHOOL = SCHOOL
local SCHOOL_INDEX = { [1] = 2, [64] = 3, [4] = 4, [16] = 5, [2] = 6, [8] = 7, [32] = 8 }
S.SCHOOL_INDEX = SCHOOL_INDEX
local SCHOOL_DAMAGE_STAT = { [64] = ST.ArcaneDamage, [4] = ST.FireDamage, [16] = ST.FrostDamage, [2] = ST.HolyDamage,
  [8] = ST.NatureDamage, [32] = ST.ShadowDamage }
local RESIST_STAT = { [64] = ST.ArcaneResistance, [4] = ST.FireResistance, [16] = ST.FrostResistance,
  [8] = ST.NatureResistance, [32] = ST.ShadowResistance, [2] = ST.Strength } -- Holy: stat 0 (Strength) in Go

S.DEF_MAGIC, S.DEF_MELEE, S.DEF_RANGED = 1, 2, 3

-- ---------------------------------------------------------------------------------------------------------------
-- Attack tables (target.go NewAttackTable), player level 70 against an enemy.
-- ---------------------------------------------------------------------------------------------------------------
local function LevelValue(level, m2, p0, p1, p2, p3)
  if level == 68 then return m2 elseif level == 70 then return p0 elseif level == 71 then return p1
  elseif level == 72 then return p2 else return p3 end
end

function S.NewAttackTable(attacker, defender)
  local L = defender.level
  local at = {
    attacker = attacker, defender = defender,
    critMultiplier = 1, damageDealtMultiplier = 1, damageTakenMultiplier = 1, armorIgnoreFactor = 0,
    bonusSpellCritPercent = 0,
  }
  at.baseSpellMiss = LevelValue(L, 0.02, 0.04, 0.05, 0.06, 0.17)
  at.baseMiss = LevelValue(L, 0.04, 0.05, 0.055, 0.06, 0.08)
  at.baseBlock = 0.05
  at.baseDodge = LevelValue(L, 0.04, 0.05, 0.055, 0.06, 0.065)
  at.baseParry = LevelValue(L, 0.04, 0.05, 0.055, 0.06, 0.14)
  at.baseGlance = LevelValue(L, 0, 0.06, 0.12, 0.18, 0.24)
  at.glanceMultiplier = LevelValue(L, 0.95, 0.95, 0.95, 0.85, 0.75)
  at.hitSuppression = LevelValue(L, 0, 0, 0, 0, 0.01)
  at.meleeCritSuppression = LevelValue(L, 0, 0, 0.01, 0.02, 0.048)
  at.spellCritSuppression = LevelValue(L, 0, 0, 0, 0.003, 0.021)
  return at
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spells
-- ---------------------------------------------------------------------------------------------------------------
local Spell = {}
Spell.__index = Spell
S.SpellMT = Spell

-- cfg: id (any key for metrics), school, defenseType, procMask, flags, classMask, damageMultiplier,
-- damageMultiplierAdditive, critMultiplierAdditive, bonusCoefficient, bonusCritPercent, bonusHitPercent,
-- threatMultiplier, gcd, gcdMin, castTime, nonEmpty, ignoreHaste, cd (seconds) / cdTimer (shared timer),
-- sharedCd / sharedCdTimer, manaCost = { basePct | flat }, extraCastCondition(sim, target), applyEffects(sim, target, spell)
-- WoWSims ActionIDs: spell / item / other id + tag. ref: { spellId | itemId | otherId, tag }
function S.ActionKey(ref)
  local tag = ref.tag or 0
  if ref.spellId then return "s" .. ref.spellId .. ":" .. tag end
  if ref.itemId then return "i" .. ref.itemId .. ":" .. tag end
  if ref.otherId then return "o" .. ref.otherId .. ":" .. tag end
  return nil
end

-- A spell's own key: cfg.actionId, or from its id (a number is a spell id, "item:N" an item).
local function SpellActionKey(sp)
  if sp.actionId then return S.ActionKey(sp.actionId) end
  local id = sp.id
  if type(id) == "number" then return "s" .. id .. ":" .. sp.tag end
  if type(id) == "string" then
    local item = id:match("^item:(%d+)$")
    if item then return "i" .. item .. ":" .. sp.tag end
  end
  return nil
end

function S.Unit_RegisterSpell(unit, cfg)
  local sp = setmetatable(cfg, Spell)
  sp.unit = unit
  sp.flags = sp.flags or 0
  sp.tag = sp.tag or 0
  sp.actionKey = sp.actionKey or SpellActionKey(sp)
  -- tagged variants of one spell (Heroic Strike's queue, Whirlwind's off hand) report apart
  if sp.metricsKey == nil and type(sp.id) == "number" and sp.tag ~= 0 then sp.metricsKey = sp.id .. ":" .. sp.tag end
  sp.classMask = sp.classMask or 0
  sp.procMask = sp.procMask or 0
  sp.damageMultiplier = sp.damageMultiplier or 0
  sp.damageMultiplierAdditive = sp.damageMultiplierAdditive or 1
  sp.critMultiplierAdditive = sp.critMultiplierAdditive or 0
  sp.critMultiplierPct = 1
  sp.bonusCritPercent = sp.bonusCritPercent or 0
  sp.bonusHitPercent = sp.bonusHitPercent or 0
  sp.bonusCoefficient = sp.bonusCoefficient or 0
  sp.bonusExpertise = sp.bonusExpertise or 0
  sp.bonusSpellDamage = sp.bonusSpellDamage or 0
  sp.cdMultiplier = 1
  sp.schoolIndex = SCHOOL_INDEX[sp.school or 0] or 1
  if sp.school then
    -- multi-school: first matching in Go's switch order
    for _, s in ipairs({ 1, 64, 4, 16, 2, 8, 32 }) do
      if has(sp.school, s) then sp.schoolIndex = SCHOOL_INDEX[s]; break end
    end
  end
  if sp.cd then
    sp.cdTimer = sp.cdTimer or S.NewTimer()
    sp.cdDuration = sp.cd
  end
  if sp.sharedCd then
    sp.sharedCdTimer = sp.sharedCdTimer or S.NewTimer()
    sp.sharedCdDuration = sp.sharedCd
  end
  if sp.manaCost then
    local mc = sp.manaCost
    local base = mc.flat or floor((mc.basePct or 0) * unit.baseMana) / 100
    -- Go: int32(BaseCostPercent * BaseMana) / 100 (integer division)
    if not mc.flat then base = floor(floor((mc.basePct or 0) * unit.baseMana) / 100) end
    sp.cost = { base = base, flatModifier = 0, percentModifier = 1, additivePercentModifier = 1 }
  elseif sp.rageCost then
    sp.cost = { base = sp.rageCost.cost, flatModifier = 0, percentModifier = 1, additivePercentModifier = 1,
      resource = "rage", refund = sp.rageCost.refund or 0 }
  elseif sp.energyCost then
    sp.cost = { base = sp.energyCost.cost, flatModifier = 0, percentModifier = 1, additivePercentModifier = 1,
      resource = "energy", refund = sp.energyCost.refund or 0 }
  end
  sp.gcd = sp.gcd or 0
  sp.castTime = sp.castTime or 0
  local empty = (sp.gcd == 0 and sp.castTime == 0 and not sp.nonEmpty)
  if sp.gcd <= 0 and sp.castTime == 0 then sp.ignoreHaste = true end
  if empty then
    if not sp.extraCastCondition and not sp.cdTimer and not sp.sharedCdTimer then
      sp.castKind = "proc"
    else
      sp.castKind = "simple"
    end
  else
    sp.castKind = "full"
  end
  sp.applyEffects = sp.applyEffects or function() end
  if sp.dot then S.CreateDots(sp, sp.dot) end
  sp.casts = 0
  sp.metrics = unit.metrics and unit.metrics:ForSpell(sp) or nil
  unit.spellbook[#unit.spellbook + 1] = sp
  if sp.id then unit.spellsById = unit.spellsById or {}; unit.spellsById[sp.id] = sp end
  if sp.actionKey then
    unit.spellsByKey = unit.spellsByKey or {}
    if not unit.spellsByKey[sp.actionKey] then unit.spellsByKey[sp.actionKey] = sp end
  end
  for _, h in ipairs(unit.spellRegistered) do h(sp) end
  return sp
end

function S.UnitMT:RegisterSpell(cfg) return S.Unit_RegisterSpell(self, cfg) end
function S.UnitMT:GetSpell(id) return self.spellsById and self.spellsById[id] end

function Spell:Matches(mask) return has(self.classMask, mask) end
function Spell:Dot(target) return S.SpellMT_Dot(self, target or self.unit.currentTarget) end

function Spell:IsReady(sim)
  return (not self.cdTimer or self.cdTimer.readyAt <= sim.now) and (not self.sharedCdTimer or self.sharedCdTimer.readyAt <= sim.now)
end

-- cooldown.go BothTimersReadyAt: 0 without timers; the own timer replaces it; the shared one can only raise it.
function Spell:ReadyAt()
  local r = 0
  if self.cdTimer then r = self.cdTimer.readyAt end
  if self.sharedCdTimer and self.sharedCdTimer.readyAt > r then r = self.sharedCdTimer.readyAt end
  return r
end

-- cooldown.go MaxTimeToReady: per timer, 0 without timers (not ReadyAt - now: ReadyAt is 0 without timers).
function Spell:TimeToReady(sim)
  local r = 0
  if self.cdTimer then r = max(0, self.cdTimer.readyAt - sim.now) end
  if self.sharedCdTimer then r = max(r, self.sharedCdTimer.readyAt - sim.now) end
  return r
end

function Spell:CurrentCost()
  local c = self.cost
  if not c then return 0 end
  local cost = max(0, c.base + c.flatModifier)
  -- cost*SpellCostPercentModifier/100 is integer math in Go (int32)
  cost = max(0, floor(cost * self.unit.ps.SpellCostPercentModifier / 100))
  return max(0, cost * c.percentModifier * c.additivePercentModifier)
end

function Spell:MeetsCost(sim)
  local c = self.cost
  if not c then return true end
  self.curCost = self:CurrentCost()
  local r = c.resource
  if r == "rage" then return self.unit.rage >= self.curCost end
  if r == "energy" then return self.unit.energy >= self.curCost end
  return self.unit.mana >= self.curCost
end

function Spell:CanCompleteCast(sim, target)
  local u = self.unit
  if not u.enabled or not target or not target.enabled then return false end
  if self.extraCastCondition and not self.extraCastCondition(sim, target) then return false end
  if not self:MeetsCost(sim) then return false end
  return true
end

function Spell:CanCast(sim, target)
  if not self:CanCompleteCast(sim, target) then return false end
  local u = self.unit
  if u.hardcastExpires > sim.now then return false end
  if (self.gcd > 0) and u.GCD.readyAt > sim.now then return false end
  if not self:IsReady(sim) then return false end
  return true
end

function Spell:CanQueue(sim, target)
  if not self:CanCompleteCast(sim, target) then return false end
  local u = self.unit
  if self.gcd > 0 and max(0, u.GCD.readyAt - sim.now) > S.QUEUE_WINDOW then return false end
  if self:TimeToReady(sim) > S.QUEUE_WINDOW then return false end
  return true
end

function Spell:CanCastOrQueue(sim, target)
  local u = self.unit
  local canQueueSpell = (not u.queued) or (u.queued.initiatedAt ~= sim.now)
  return canQueueSpell and self:CanQueue(sim, target)
end

function Spell:CastOrQueue(sim, target)
  local u = self.unit
  if self:CanCast(sim, target) then
    self:Cast(sim, target)
  elseif self:CanQueue(sim, target) then
    local at = max(u.hardcastExpires, self:ReadyAt())
    if self.gcd > 0 or has(self.flags, F.MCD) then at = max(at, u.GCD.readyAt) end
    u:QueueSpell(sim, self, target, at)
  else
    self:Cast(sim, target)
  end
end

-- spell_queueing.go: fire 1 ns after the ready time; a new queue replaces the old one.
function S.UnitMT:QueueSpell(sim, spell, target, at)
  local q = self.queued
  if not q then
    q = { initiatedAt = -huge }
    self.queued = q
  end
  if q.pa and not q.pa.consumed and not q.pa.cancelled then sim:Cancel(q.pa) end
  q.spell, q.target = spell, target
  q.pa = { at = at + 1e-9, prio = S.PRIO_GCD, fn = function(s) q.spell:Cast(s, q.target) end }
  sim:Add(q.pa)
  q.initiatedAt = sim.now
end

function S.UnitMT:CancelQueuedSpell(sim)
  local q = self.queued
  if q then
    if q.pa and not q.pa.consumed and not q.pa.cancelled then sim:Cancel(q.pa) end
    q.pa = nil
    q.initiatedAt = -huge
  end
end

function Spell:TriggerCooldown(sim)
  if self.cdTimer then
    local cd = self.cdDuration * self.cdMultiplier
    if cd > 0 then self.cdTimer.readyAt = sim.now + cd end
  end
end

function Spell:ApplyEffectsInternal(sim, target)
  if sim.log then sim:Log("Cast %s", tostring(self.metricsKey or self.id)) end
  self.casts = self.casts + 1
  if self.metrics then self.metrics.casts = self.metrics.casts + 1 end
  if not has(self.flags, F.NoOnCastComplete) then self.unit:OnApplyEffects(sim, target, self) end
  self.applyEffects(sim, target, self)
end

function Spell:SpendCost(sim)
  local c = self.curCost or 0
  local cost = self.cost
  if cost and c > 0 then
    local u = self.unit
    if cost.resource == "rage" then u:SpendRage(sim, c)
    elseif cost.resource == "energy" then u:SpendEnergy(sim, c)
    else
      u:SpendMana(sim, c)
      u.ps.FiveSecondRuleRefreshTime = max(sim.now + 5, u.hardcastExpires)
    end
  end
end

-- rage.go / energy.go IssueRefund: a share of the cost back (attacks that missed).
function Spell:IssueRefund(sim)
  local cost = self.cost
  if not cost or (cost.refund or 0) <= 0 then return end
  local c = self.curCost or 0
  if c <= 0 then return end
  if cost.resource == "rage" then self.unit:AddRage(sim, cost.refund * c, "refund")
  elseif cost.resource == "energy" then self.unit:AddEnergy(sim, cost.refund * c, "refund") end
end

-- gcd.go hardcast action / character.go rotationAction: whichever runs first at the end of a cast completes it
-- (the rotation finishes a due cast before it picks the next action).
function S.CompleteDueHardcast(u, sim)
  local c = u.hardcastComplete
  if c and u.hardcastExpires ~= -huge and u.hardcastExpires <= sim.now then
    u.hardcastExpires = -huge
    u.hardcastComplete = nil
    c(sim)
  end
end

function Spell:Cast(sim, target)
  local u = self.unit
  if (self.gcd > 0 or self.castTime > 0) then u:CancelQueuedSpell(sim) end
  target = target or u.currentTarget
  local kind = self.castKind
  if kind == "proc" then
    self:ApplyEffectsInternal(sim, target)
    if not has(self.flags, F.NoOnCastComplete) then u:OnCastComplete(sim, self) end
    return true
  elseif kind == "simple" then
    if not target or not target.enabled then return false end
    if self.extraCastCondition and not self.extraCastCondition(sim, target) then return false end
    if not self:IsReady(sim) then return false end
    self:TriggerCooldown(sim)
    if self.sharedCdTimer then self.sharedCdTimer.readyAt = sim.now + self.sharedCdDuration * self.cdMultiplier end
    self:ApplyEffectsInternal(sim, target)
    if not has(self.flags, F.NoOnCastComplete) then u:OnCastComplete(sim, self) end
    return true
  end
  -- makeCastFunc
  local gcd, castTime = self.gcd, self.castTime
  if self.modifyCast then gcd, castTime = self.modifyCast(sim, self, gcd, castTime) end
  if not target or not target.enabled then return false end
  if self.extraCastCondition and not self.extraCastCondition(sim, target) then return false end
  if not self:MeetsCost(sim) then return false end
  if not self.ignoreHaste then
    gcd = S.RoundMs(max(0, u:ApplyCastSpeed(gcd)))
    castTime = S.RoundMs(u:ApplyCastSpeed(castTime) * (self.castTimeMultiplier or 1))
  end
  if not self:IsReady(sim) then return false end
  if gcd > 0 and u.GCD.readyAt > sim.now then return false end
  if u.hardcastExpires > sim.now then return false end
  self.curGcd = gcd
  local gcdTime = gcd
  if gcd > 0 then gcdTime = max(self.gcdMin or S.GCD_MIN, gcd) end
  local effective = max(gcdTime, castTime)
  if effective ~= 0 then u:SetGCDTimer(sim, max(sim.now + effective, u.GCD.readyAt)) end
  if castTime > 0 then
    u.hardcastExpires = sim.now + castTime
    local spell = self
    u.hardcastComplete = function(s)
      if not spell:CanCompleteCast(s, target) then return end
      spell:SpendCost(s)
      spell:TriggerCooldown(s)
      if spell.sharedCdTimer then spell.sharedCdTimer.readyAt = s.now + spell.sharedCdDuration * spell.cdMultiplier end
      spell:ApplyEffectsInternal(s, target)
      if not has(spell.flags, F.NoOnCastComplete) then u:OnCastComplete(s, spell) end
    end
    sim:Add({ at = u.hardcastExpires, prio = S.PRIO_GCD, fn = function(s) S.CompleteDueHardcast(u, s) end })
    return true
  end
  self:SpendCost(sim)
  self:TriggerCooldown(sim)
  if self.sharedCdTimer then self.sharedCdTimer.readyAt = sim.now + self.sharedCdDuration * self.cdMultiplier end
  self:ApplyEffectsInternal(sim, target)
  if not has(self.flags, F.NoOnCastComplete) then u:OnCastComplete(sim, self) end
  return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Chances (spell_result.go)
-- ---------------------------------------------------------------------------------------------------------------
function Spell:PhysicalHitChance(at)
  local u = self.unit
  local hit = u.stats[ST.PhysicalHitPercent] + self.bonusHitPercent - at.defender.ps.ReducedPhysicalHitTakenChance
  if has(self.procMask, PM.Ranged) then hit = hit + u.stats[ST.RangedHitPercent] end
  return max(hit / 100 - at.hitSuppression, 0)
end

function Spell:PhysicalCritChance(at)
  local u = self.unit
  local crit = u.stats[ST.PhysicalCritPercent] + self.bonusCritPercent - at.defender.ps.ReducedCritTakenPercent
  if has(self.procMask, PM.Ranged) then crit = crit + u.stats[ST.RangedCritPercent] end
  return max(crit / 100 - at.meleeCritSuppression, 0)
end

function Spell:DodgeParrySuppression()
  local exp = self.unit.stats[ST.ExpertiseRating] + self.bonusExpertise
  return floor(exp / S.EXPERTISE_PER_QUARTER) / 400
end

function Spell:SpellHitChance(target)
  local u = self.unit
  local hit = u.stats[ST.SpellHitPercent] + self.bonusHitPercent
  if self.classMask ~= 0 then hit = hit + u.ps.SchoolBonusHitChance[self.schoolIndex] end
  return hit / 100
end

-- Resist coefficient (spell_resistances.go). Holy has no resistance stat; Go reads stat 0 (Strength) of the target.
local function ResistCoeff(defender, spell, attacker, binary)
  if spell.schoolIndex <= 2 then return 0 end
  local school = spell.school
  local rs = RESIST_STAT[school]
  local res = max(0, (rs and defender.stats[rs] or 0) - attacker.stats[ST.SpellPenetration])
  if res <= 0 then
    if binary then return 0 end
    if defender.kind == "enemy" and defender.level > attacker.level then return 0.02 * (defender.level - attacker.level) end
    return 0
  end
  local coef = res / (attacker.level * 5)
  if not binary and defender.kind == "enemy" and defender.level > attacker.level then
    coef = coef + 0.02 * (defender.level - attacker.level) / 0.75
  end
  return min(1, coef)
end

function Spell:SpellChanceToMiss(at)
  local base = 1 - at.baseSpellMiss
  if has(self.flags, F.Binary) then
    base = base * (1 - 0.75 * ResistCoeff(at.defender, self, self.unit, true))
  end
  local hitChance = base + self:SpellHitChance(at.defender)
  return max(0.01, 1 - hitChance)
end

function Spell:SpellCritChance(target, at)
  local u = self.unit
  local crit = u.stats[ST.SpellCritPercent] + self.bonusCritPercent + at.bonusSpellCritPercent - target.ps.ReducedCritTakenPercent
  return max(crit / 100 - at.spellCritSuppression, 0)
end

function Spell:CritDamageMultiplier(at)
  local base = (self.defenseType == S.DEF_MAGIC) and 1.5 or 2.0
  return (base * self.critMultiplierPct * self.unit.ps.CritDamageMultiplier * at.critMultiplier - 1) * (self.critMultiplierAdditive + 1) + 1
end

-- unit.go getAttackPowerValueImpl (+ mob-type bonuses such as Mark of the Champion)
function Spell:MeleeAttackPower(target)
  local at = self.unit.attackTables[target]
  return self.unit.stats[ST.AttackPower] + target.ps.BonusAttackPower + (at and at.mobBonusAP or 0)
end

function Spell:SpellDamage()
  local u = self.unit
  local sd = u.stats[ST.SpellDamage] + self.bonusSpellDamage
  local ss = SCHOOL_DAMAGE_STAT[self.school]
  if ss then sd = sd + u.stats[ss] end
  return sd
end

function Spell:BonusDamage(at)
  local bonus = self.bonusBaseDamage or 0
  if has(self.school, SCHOOL.Physical) then
    bonus = bonus + self.unit.stats[ST.PhysicalDamage]
  else
    bonus = bonus + self:SpellDamage() + (at.mobBonusSP or 0) + at.defender.ps.SchoolBonusSpellDamage[self.schoolIndex]
  end
  return bonus
end

function Spell:AttackerDamageMultiplier(at, isDot)
  if has(self.flags, F.IgnoreAttackerModifiers) then return 1 end
  local ps = self.unit.ps
  local add = self.damageMultiplierAdditive
  if isDot then add = add + ps.DotDamageMultiplierAdditive - 1 end
  return ps.DamageDealtMultiplier * ps.SchoolDamageDealtMultiplier[self.schoolIndex] * at.damageDealtMultiplier *
    self.damageMultiplier * add
end

function Spell:TargetDamageMultiplier(at, isPeriodic)
  if has(self.flags, F.IgnoreTargetModifiers) then return 1 end
  local dps = at.defender.ps
  local m = dps.DamageTakenMultiplier * dps.SchoolDamageTakenMultiplier[self.schoolIndex] * at.damageTakenMultiplier
  if isPeriodic and has(self.school, SCHOOL.Physical) then m = m * dps.PeriodicPhysicalDamageTakenMultiplier end
  if at.damageDoneByCaster then m = m * at.damageDoneByCaster(self, at) end
  return m
end

function Spell:ArmorModifier(at)
  if at.ignoreArmor then return 1 end
  local f = min(max(at.armorIgnoreFactor, 0), 1)
  local constant = at.attacker.level * 467.5 - 22167.5
  local armor = at.defender:Armor()
  armor = armor - armor * f
  armor = max(armor - at.attacker.stats[ST.ArmorPenetration], 0)
  return max(1 - armor / (armor + constant), 0.25)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Results. One result table per call is reused only where Go reuses it; handlers that defer copy what they need.
-- ---------------------------------------------------------------------------------------------------------------
local function NewResult(target)
  return { target = target, outcome = 0, damage = 0 }
end
S.NewResult = NewResult

local function Landed(r) return has(r.outcome, O.Landed) end
S.Landed = Landed

local function ApplyResistances(sim, spell, r, at, isPeriodic)
  r.armorMult = 1
  if has(spell.flags, F.IgnoreResists) then return end
  if has(spell.school, SCHOOL.Physical) then
    if isPeriodic and not has(spell.flags, F.ApplyArmorReduction) then return end
    local m = spell:ArmorModifier(at)
    r.damage = r.damage * m
    r.armorMult = m
    return
  end
  if has(spell.flags, F.Binary) then return end
  local roll = sim:Rand()
  local val = ResistCoeff(at.defender, spell, spell.unit, false) * 3
  local t00, t25, t50
  if val <= 1 then
    t00, t25, t50 = 0.76 * val, 0.21 * val, 0.03 * val
  elseif val <= 2 then
    val = val - 1
    t00, t25, t50 = 0.76 + 0.24 * val, 0.21 + 0.57 * val, 0.03 + 0.19 * val
  else
    val = val - 2
    t00, t25, t50 = 1, 0.78 + 0.18 * val, 0.22 + 0.58 * val
  end
  if roll > t00 then return
  elseif roll > t25 then r.damage = r.damage * 0.75; r.outcome = O.Partial1; r.armorMult = 0.75
  elseif roll > t50 then r.damage = r.damage * 0.5; r.outcome = O.Partial2; r.armorMult = 0.5
  else r.damage = r.damage * 0.25; r.outcome = O.Partial3; r.armorMult = 0.25 end
end

local function ApplyTargetModifiers(spell, r, at, isPeriodic)
  if has(spell.flags, F.IgnoreTargetModifiers) then return end
  local dps = at.defender.ps
  if has(spell.school, SCHOOL.Physical) then
    r.damage = r.damage + dps.BonusPhysicalDamageTaken
  elseif spell.school and spell.school ~= 0 then
    r.damage = r.damage + dps.BonusSpellDamageTaken
  end
  r.damage = r.damage * spell:TargetDamageMultiplier(at, isPeriodic)
end

function Spell:CalcDamageInternal(sim, target, base, attackerMult, isPeriodic, outcomeFn)
  local at = self.unit.attackTables[target]
  local r = NewResult(target)
  r.damage = base * attackerMult
  local a1 = r.damage
  ApplyResistances(sim, self, r, at, isPeriodic)
  local a2 = r.damage
  r.postArmor = a2
  ApplyTargetModifiers(self, r, at, isPeriodic)
  local a3 = r.damage
  local partial = 0
  if has(r.outcome, O.Partial) then partial = r.outcome end
  r.outcome = 0
  outcomeFn(self, sim, r, at)
  if partial ~= 0 then r.outcome = r.outcome + partial end
  r.postOutcome = r.damage
  if r.damage < 0 then r.damage = 0 end
  if sim.log then
    sim:Log("%s [DEBUG] MAP: %.1f, SP: %.1f, BaseDamage:%.1f, AfterAttackerMods:%.1f, AfterResistances:%.1f, AfterTargetMods:%.1f, AfterOutcome:%.1f",
      tostring(self.metricsKey or self.id), self.unit.stats[ST.AttackPower], self:SpellDamage(), base, a1, a2, a3, r.damage)
  end
  return r
end

function Spell:CalcDamage(sim, target, base, outcomeFn)
  local at = self.unit.attackTables[target]
  local mult = self:AttackerDamageMultiplier(at, false)
  if self.bonusCoefficient > 0 then
    base = base + self.bonusCoefficient * self:BonusDamage(at)
  elseif has(self.school, SCHOOL.Physical) then
    base = base + self:BonusDamage(at)
  end
  return self:CalcDamageInternal(sim, target, base, mult, false, outcomeFn)
end

-- spell_result.go CalcPeriodicDamage: a tick computed live (not snapshotted) with its DoT's coefficient and multiplier.
function Spell:CalcPeriodicDamage(sim, target, base, outcomeFn)
  local at = self.unit.attackTables[target]
  local mult = self:AttackerDamageMultiplier(at, true)
  local dot = self.aoeDot or self:Dot(target)
  if dot.bonusCoefficient > 0 then base = base + dot.bonusCoefficient * self:BonusDamage(at) end
  mult = mult * dot.periodicDamageMultiplier
  return self:CalcDamageInternal(sim, target, base, mult, true, outcomeFn)
end

function Spell:AOEDot() return self.aoeDot end

function Spell:CalcOutcome(sim, target, outcomeFn)
  local at = self.unit.attackTables[target]
  local r = NewResult(target)
  outcomeFn(self, sim, r, at)
  return r
end

function Spell:DealDamageInternal(sim, r, isPeriodic)
  if sim.now >= 0 and self.metrics and r.target.kind == "enemy" then
    local m = self.metrics
    local o = r.outcome
    m.damage = m.damage + r.damage
    if has(o, O.Crit) and not has(o, O.Block) then m.crits = m.crits + 1
    elseif has(o, O.Glance) then m.glances = (m.glances or 0) + 1
    elseif Landed(r) then m.hits = m.hits + 1
    elseif has(o, O.Miss) then m.misses = (m.misses or 0) + 1
    elseif has(o, O.Dodge) then m.dodges = (m.dodges or 0) + 1 end
    if has(o, O.Partial) then m.partials = (m.partials or 0) + 1 end
  end
  if r.target.kind == "enemy" then sim.damageTaken = sim.damageTaken + r.damage end
  if not has(self.flags, F.NoOnDamageDealt) then
    if isPeriodic then
      self.unit:OnPeriodicDamageDealt(sim, self, r)
    else
      self.unit:OnSpellHitDealt(sim, self, r)
      r.target:OnSpellHitTaken(sim, self, r)
    end
  end
end

function Spell:DealDamage(sim, r) self:DealDamageInternal(sim, r, false) end
function Spell:DealPeriodicDamage(sim, r) self:DealDamageInternal(sim, r, true) end

function Spell:CalcAndDealDamage(sim, target, base, outcomeFn)
  local r = self:CalcDamage(sim, target, base, outcomeFn)
  self:DealDamage(sim, r)
  return r
end

function Spell:CalcAndDealOutcome(sim, target, outcomeFn)
  local r = self:CalcOutcome(sim, target, outcomeFn)
  self:DealDamage(sim, r)
  return r
end

-- Deal damage one spell batch window later (seals, judgements; the 10 ms SpellBatchWindow at low priority).
function Spell:DealDamageBatched(sim, r)
  local spell = self
  sim:Add({ at = sim.now + S.SPELL_BATCH, prio = S.PRIO_LOW, fn = function(s) spell:DealDamage(s, r) end })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Outcomes (spell_outcome.go). Signature: fn(spell, sim, result, attackTable).
-- ---------------------------------------------------------------------------------------------------------------
local OUT = {}
S.OUT = OUT

local function MissChance(spell, at, dwPenalty)
  local miss = at.baseMiss - spell:PhysicalHitChance(at)
  local u = spell.unit
  if dwPenalty and u.autoAttacks and u.autoAttacks.isDualWielding and not u.ps.DisableDWMissPenalty then
    miss = miss + 0.19
  end
  return max(0, miss)
end

local function DodgeChance(spell, at)
  -- target GetTotalDodgeChanceAsDefender: base dodge - expertise suppression - attacker's DodgeReduction
  return max(0, at.baseDodge - spell:DodgeParrySuppression() - spell.unit.ps.DodgeReduction)
end

local function ParryChance(spell, at)
  return max(0, at.baseParry - spell:DodgeParrySuppression())
end

local function SetCrit(spell, r, at)
  r.outcome = O.Crit
  r.damage = r.damage * spell:CritDamageMultiplier(at)
end

local function SetMiss(r, o)
  r.outcome = o
  r.damage = 0
end

local function CritSeparateRoll(spell, sim, r, at)
  if sim:Rand() < spell:PhysicalCritChance(at) then
    SetCrit(spell, r, at)
    return true
  end
  return false
end

local function Block(spell, r, at, roll, chance)
  -- GetTotalBlockChanceAsDefender: base block (no block rating on bosses here)
  chance = chance + at.baseBlock
  if roll < chance then
    r.outcome = r.outcome + O.Block
    if has(spell.flags, F.Binary) then r.damage = 0 else r.damage = max(0, r.damage - at.defender.stats[ST.BlockValue] * at.defender.ps.BlockValueMultiplier) end
    return true, chance
  end
  return false, chance
end

function OUT.AlwaysHit(spell, sim, r, at) r.outcome = O.Hit end
function OUT.AlwaysHitNoHitCounter(spell, sim, r, at) r.outcome = O.Hit end

function OUT.MeleeWhite(spell, sim, r, at)
  local roll = sim:Rand()
  local chance = MissChance(spell, at, true)
  if roll < chance then return SetMiss(r, O.Miss) end
  if not has(spell.flags, F.CannotBeDodged) then
    chance = chance + DodgeChance(spell, at)
    if roll < chance then return SetMiss(r, O.Dodge) end
  end
  local front = spell.unit.ps.InFrontOfTarget
  if front then
    chance = chance + ParryChance(spell, at)
    if roll < chance then return SetMiss(r, O.Parry) end
  end
  chance = chance + at.baseGlance
  if roll < chance then
    r.outcome = O.Glance
    r.damage = r.damage * at.glanceMultiplier
    return
  end
  if front then
    local blocked
    blocked, chance = Block(spell, r, at, roll, chance)
    if blocked then return end
  end
  chance = chance + spell:PhysicalCritChance(at)
  if roll < chance then return SetCrit(spell, r, at) end
  r.outcome = O.Hit
end

function OUT.MeleeSpecialHitAndCrit(spell, sim, r, at)
  local roll = sim:Rand()
  local chance = MissChance(spell, at, false)
  if roll < chance then return SetMiss(r, O.Miss) end
  if not has(spell.flags, F.CannotBeDodged) then
    chance = chance + DodgeChance(spell, at)
    if roll < chance then return SetMiss(r, O.Dodge) end
  end
  if spell.unit.ps.InFrontOfTarget then
    chance = chance + ParryChance(spell, at)
    if roll < chance then return SetMiss(r, O.Parry) end
    if CritSeparateRoll(spell, sim, r, at) then
      Block(spell, r, at, roll, chance)
    else
      local blocked = Block(spell, r, at, roll, chance)
      if not blocked then r.outcome = O.Hit end
    end
    return
  end
  if CritSeparateRoll(spell, sim, r, at) then return end
  r.outcome = O.Hit
end

function OUT.MeleeWeaponSpecialHitAndCrit(spell, sim, r, at)
  if spell.unit.ps.InFrontOfTarget then
    local roll = sim:Rand()
    local chance = MissChance(spell, at, false)
    if roll < chance then return SetMiss(r, O.Miss) end
    if not has(spell.flags, F.CannotBeDodged) then
      chance = chance + DodgeChance(spell, at)
      if roll < chance then return SetMiss(r, O.Dodge) end
    end
    chance = chance + ParryChance(spell, at)
    if roll < chance then return SetMiss(r, O.Parry) end
    local blocked
    blocked, chance = Block(spell, r, at, roll, chance)
    if blocked then return end
    if CritSeparateRoll(spell, sim, r, at) then return end
    r.outcome = O.Hit
    return
  end
  return OUT.MeleeSpecialHitAndCrit(spell, sim, r, at)
end

function OUT.MeleeSpecialNoBlockDodgeParry(spell, sim, r, at)
  local roll = sim:Rand()
  if roll < MissChance(spell, at, false) then return SetMiss(r, O.Miss) end
  if CritSeparateRoll(spell, sim, r, at) then return end
  r.outcome = O.Hit
end

function OUT.MeleeSpecialCritOnly(spell, sim, r, at)
  if CritSeparateRoll(spell, sim, r, at) then return end
  r.outcome = O.Hit
end

function OUT.MeleeSpecialHit(spell, sim, r, at)
  local roll = sim:Rand()
  local chance = MissChance(spell, at, false)
  if roll < chance then return SetMiss(r, O.Miss) end
  if not has(spell.flags, F.CannotBeDodged) then
    chance = chance + DodgeChance(spell, at)
    if roll < chance then return SetMiss(r, O.Dodge) end
  end
  if spell.unit.ps.InFrontOfTarget then
    chance = chance + ParryChance(spell, at)
    if roll < chance then return SetMiss(r, O.Parry) end
  end
  r.outcome = O.Hit
end

OUT.MeleeSpecialHitNoHitCounter = OUT.MeleeSpecialHit

-- outcomeMeleeWeaponSpecialNoParry (Shiv): the weapon special table without parry.
function OUT.MeleeWeaponSpecialNoParry(spell, sim, r, at)
  if spell.unit.ps.InFrontOfTarget then
    local roll = sim:Rand()
    local chance = MissChance(spell, at, false)
    if roll < chance then return SetMiss(r, O.Miss) end
    if not has(spell.flags, F.CannotBeDodged) then
      chance = chance + DodgeChance(spell, at)
      if roll < chance then return SetMiss(r, O.Dodge) end
    end
    local blocked
    blocked, chance = Block(spell, r, at, roll, chance)
    if blocked then return end
    if CritSeparateRoll(spell, sim, r, at) then return end
    r.outcome = O.Hit
    return
  end
  return OUT.MeleeSpecialHitAndCrit(spell, sim, r, at)
end

-- outcomeMeleeSpecialBlockAndCrit: an attack that already landed (Stormstrike's weapon hits) can only crit or be
-- blocked.
function OUT.MeleeSpecialBlockAndCrit(spell, sim, r, at)
  if spell.unit.ps.InFrontOfTarget then
    local roll = sim:Rand()
    if CritSeparateRoll(spell, sim, r, at) then return end
    local blocked = Block(spell, r, at, roll, 0)
    if not blocked then r.outcome = O.Hit end
    return
  end
  if CritSeparateRoll(spell, sim, r, at) then return end
  r.outcome = O.Hit
end

function OUT.RangedHitAndCrit(spell, sim, r, at)
  local roll = sim:Rand()
  local chance = MissChance(spell, at, false)
  if roll < chance then return SetMiss(r, O.Miss) end
  if spell.unit.ps.InFrontOfTarget then
    if CritSeparateRoll(spell, sim, r, at) then
      Block(spell, r, at, roll, chance)
    else
      local blocked = Block(spell, r, at, roll, chance)
      if not blocked then r.outcome = O.Hit end
    end
    return
  end
  if CritSeparateRoll(spell, sim, r, at) then return end
  r.outcome = O.Hit
end

function OUT.MagicHit(spell, sim, r, at)
  if sim:Proc(1 - spell:SpellChanceToMiss(at)) then
    r.outcome = O.Hit
  else
    SetMiss(r, O.Miss)
  end
end

function OUT.MagicHitAndCrit(spell, sim, r, at)
  if sim:Proc(1 - spell:SpellChanceToMiss(at)) then
    if sim:Rand() < spell:SpellCritChance(r.target, at) then
      r.outcome = O.Crit
      r.damage = r.damage * spell:CritDamageMultiplier(at)
    else
      r.outcome = O.Hit
    end
  else
    SetMiss(r, O.Miss)
  end
end

-- Dot.OutcomeTickMagicHitAndCrit / spell.OutcomeTickMagicHitAndCrit
function OUT.TickMagicHitAndCrit(spell, sim, r, at)
  if sim:Proc(1 - spell:SpellChanceToMiss(at)) then
    if sim:Rand() < spell:SpellCritChance(r.target, at) then
      r.outcome = O.Crit
      r.damage = r.damage * spell:CritDamageMultiplier(at)
    else
      r.outcome = O.Hit
    end
  else
    SetMiss(r, O.Miss)
  end
end

function OUT.MagicCrit(spell, sim, r, at)
  if sim:Rand() < spell:SpellCritChance(r.target, at) then
    r.outcome = O.Crit
    r.damage = r.damage * spell:CritDamageMultiplier(at)
  else
    r.outcome = O.Hit
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Spell mods (spell_mod.go)
-- ---------------------------------------------------------------------------------------------------------------
local Mod = {}
Mod.__index = Mod

local MOD_KIND = {
  DamageDone_Pct = { function(m, s) s.damageMultiplier = s.damageMultiplier * (1 + m.value) end,
                     function(m, s) s.damageMultiplier = s.damageMultiplier / (1 + m.value) end },
  DamageDone_Flat = { function(m, s) s.damageMultiplierAdditive = s.damageMultiplierAdditive + m.value end,
                      function(m, s) s.damageMultiplierAdditive = s.damageMultiplierAdditive - m.value end },
  PowerCost_Pct = { function(m, s) if s.cost then s.cost.percentModifier = s.cost.percentModifier * (1 + m.value) end end,
                    function(m, s) if s.cost then s.cost.percentModifier = s.cost.percentModifier / (1 + m.value) end end },
  PowerCost_Pct_Add = { function(m, s) if s.cost then s.cost.additivePercentModifier = s.cost.additivePercentModifier + m.value end end,
                        function(m, s) if s.cost then s.cost.additivePercentModifier = s.cost.additivePercentModifier - m.value end end },
  PowerCost_Flat = { function(m, s) if s.cost then s.cost.flatModifier = s.cost.flatModifier + m.value end end,
                     function(m, s) if s.cost then s.cost.flatModifier = s.cost.flatModifier - m.value end end },
  Cooldown_Flat = { function(m, s) if s.cdDuration then s.cdDuration = s.cdDuration + m.value end end,
                    function(m, s) if s.cdDuration then s.cdDuration = s.cdDuration - m.value end end },
  CritMultiplier_Flat = { function(m, s) s.critMultiplierAdditive = s.critMultiplierAdditive + m.value end,
                          function(m, s) s.critMultiplierAdditive = s.critMultiplierAdditive - m.value end },
  CritMultiplier_Pct = { function(m, s) s.critMultiplierPct = s.critMultiplierPct * (1 + m.value) end,
                         function(m, s) s.critMultiplierPct = s.critMultiplierPct / (1 + m.value) end },
  CastTime_Pct = { function(m, s) s.castTimeMultiplier = (s.castTimeMultiplier or 1) + m.value end,
                   function(m, s) s.castTimeMultiplier = (s.castTimeMultiplier or 1) - m.value end },
  BonusCrit_Percent = { function(m, s) s.bonusCritPercent = s.bonusCritPercent + m.value end,
                        function(m, s) s.bonusCritPercent = s.bonusCritPercent - m.value end },
  BonusHit_Percent = { function(m, s) s.bonusHitPercent = s.bonusHitPercent + m.value end,
                       function(m, s) s.bonusHitPercent = s.bonusHitPercent - m.value end },
  BonusSpellDamage_Flat = { function(m, s) s.bonusSpellDamage = s.bonusSpellDamage + m.value end,
                            function(m, s) s.bonusSpellDamage = s.bonusSpellDamage - m.value end },
  BonusCoefficient_Flat = { function(m, s) s.bonusCoefficient = s.bonusCoefficient + m.value end,
                            function(m, s) s.bonusCoefficient = s.bonusCoefficient - m.value end },
  BaseDamage_Flat = { function(m, s) s.bonusBaseDamage = (s.bonusBaseDamage or 0) + m.value end,
                      function(m, s) s.bonusBaseDamage = (s.bonusBaseDamage or 0) - m.value end },
  BonusExpertise_Rating = { function(m, s) s.bonusExpertise = s.bonusExpertise + m.value end,
                            function(m, s) s.bonusExpertise = s.bonusExpertise - m.value end },
  ThreatMultiplier_Pct = { function() end, function() end },
  CastTime_Flat = { function(m, s) s.castTime = s.castTime + m.value end,
                    function(m, s) s.castTime = s.castTime - m.value end },
  BuffDuration_Flat = { function(m, s)
                          if s.sharedCdDuration and s.sharedCdDuration ~= 0 then s.sharedCdDuration = s.sharedCdDuration + m.value end
                          if s.relatedSelfBuff then s.relatedSelfBuff.duration = s.relatedSelfBuff.duration + m.value end
                        end,
                        function(m, s)
                          if s.sharedCdDuration and s.sharedCdDuration ~= 0 then s.sharedCdDuration = s.sharedCdDuration - m.value end
                          if s.relatedSelfBuff then s.relatedSelfBuff.duration = s.relatedSelfBuff.duration - m.value end
                        end },
  DotDamageDone_Pct = { function(m, s) local d = s.dotConfig or (s.aoeDot and s.aoeDot) if s.dots then for _, dt in pairs(s.dots) do dt.periodicDamageMultiplier = dt.periodicDamageMultiplier * (1 + m.value) end end end,
                        function(m, s) if s.dots then for _, dt in pairs(s.dots) do dt.periodicDamageMultiplier = dt.periodicDamageMultiplier / (1 + m.value) end end end },
}

local function ShouldApply(spell, m)
  if has(spell.flags, F.NoSpellMods) then return false end
  if m.manaOnly and not spell.cost then return false end
  if m.classMask and m.classMask > 0 and not has(spell.classMask, m.classMask) then return false end
  if m.school and m.school > 0 and not has(m.school, spell.school or 0) then return false end
  if m.defenseType and m.defenseType > 0 and spell.defenseType ~= m.defenseType then return false end
  if m.procMask and m.procMask > 0 and not has(m.procMask, spell.procMask) then return false end
  if m.spellFlag and m.spellFlag > 0 and not has(m.spellFlag, spell.flags) then return false end
  return true
end

-- cfg: { kind, value, classMask, school, defenseType, procMask, spellFlag, apply, remove (custom) }
function S.UnitMT:AddDynamicMod(cfg)
  local k = MOD_KIND[cfg.kind]
  local m = setmetatable({
    kind = cfg.kind, value = cfg.value or 0, classMask = cfg.classMask, school = cfg.school,
    defenseType = cfg.defenseType, procMask = cfg.procMask, spellFlag = cfg.spellFlag, manaOnly = cfg.manaOnly,
    apply = cfg.apply or (k and k[1]), remove = cfg.remove or (k and k[2]), active = false, spells = {},
  }, Mod)
  if not m.apply then error("spell mod kind not implemented: " .. tostring(cfg.kind)) end
  for _, sp in ipairs(self.spellbook) do
    if ShouldApply(sp, m) then m.spells[#m.spells + 1] = sp end
  end
  self.spellRegistered[#self.spellRegistered + 1] = function(sp)
    if ShouldApply(sp, m) then
      m.spells[#m.spells + 1] = sp
      if m.active then m.apply(m, sp) end
    end
  end
  return m
end

function S.UnitMT:AddStaticMod(cfg)
  local m = self:AddDynamicMod(cfg)
  m:Activate()
  return m
end

function Mod:Activate()
  if self.active then return end
  for i = 1, #self.spells do self.apply(self, self.spells[i]) end
  self.active = true
end

function Mod:Deactivate()
  if not self.active then return end
  for i = 1, #self.spells do self.remove(self, self.spells[i]) end
  self.active = false
end

function Mod:UpdateValue(v)
  if self.active then
    self:Deactivate()
    self.value = v
    self:Activate()
  else
    self.value = v
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- PPM managers (procs.go): chance = base weapon speed * ppm / 60 per hand.
-- ---------------------------------------------------------------------------------------------------------------
function S.NewPPM(unit, ppm, procMask, fixedChance)
  local aa = unit.autoAttacks
  local masks, chances = {}, {}
  local function add(speed, mask)
    if not speed or speed == 0 or mask == 0 then return end
    for i, c in ipairs(chances) do
      if c == speed then masks[i] = bor(masks[i], mask); return end
    end
    masks[#masks + 1] = mask
    chances[#chances + 1] = speed
  end
  -- "everything else" counts as main hand
  local function andNot(a, b) -- a & ~b
    local r, bitv = 0, 1
    local x, y = a, b
    while x > 0 do
      if x % 2 == 1 and y % 2 == 0 then r = r + bitv end
      x, y = floor(x / 2), floor(y / 2)
      bitv = bitv * 2
    end
    return r
  end
  local function andM(a, b)
    local r, bitv = 0, 1
    local x, y = a, b
    while x > 0 and y > 0 do
      if x % 2 == 1 and y % 2 == 1 then r = r + bitv end
      x, y = floor(x / 2), floor(y / 2)
      bitv = bitv * 2
    end
    return r
  end
  add(aa and aa.mh.swingSpeed or 0, andNot(andNot(procMask, PM.Ranged), PM.MeleeOH))
  add(aa and aa.isDualWielding and aa.oh.swingSpeed or 0, andM(procMask, PM.MeleeOH))
  add(aa and aa.ranged and aa.ranged.swingSpeed or 0, andM(procMask, PM.Ranged))
  for i = 1, #chances do
    if fixedChance and fixedChance ~= 0 then chances[i] = fixedChance else chances[i] = chances[i] * ppm / 60 end
  end
  return {
    Proc = function(sim, spellMask)
      for i = 1, #masks do
        if has(masks[i], spellMask) then return sim:Rand() < chances[i] end
      end
      return false
    end,
    Chance = function(spellMask)
      for i = 1, #masks do if has(masks[i], spellMask) then return chances[i] end end
      return 0
    end,
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Proc triggers (aura_helpers.go AttachProcTriggerCallback / MakeProcTriggerAura)
-- cfg: name, callback ("hit" | "taken" | "periodic" | "cast" | "apply" | {list}), procMask, procMaskExclude,
-- spellFlags, spellFlagsExclude, outcome, requireDamageDealt, procChance, dpm, icd, handler(sim, spell, result),
-- triggerImmediately, classMask, classSpellsOnly, extraCondition, canProcFromProcs, isWeaponProc
-- ---------------------------------------------------------------------------------------------------------------
local function CanProcFrom(cfg, spell)
  if cfg.isWeaponProc then return not has(spell.flags, F.SuppressWeaponProcs) end
  return cfg.canProcFromProcs or not has(spell.flags, F.Proc)
end

local function MatchesSpell(cfg, spell)
  if not CanProcFrom(cfg, spell) then return false end
  if cfg.spellFlags and cfg.spellFlags ~= 0 and not has(spell.flags, cfg.spellFlags) then return false end
  if cfg.spellFlagsExclude and cfg.spellFlagsExclude ~= 0 and has(spell.flags, cfg.spellFlagsExclude) then return false end
  if cfg.classMask and cfg.classMask > 0 and not has(cfg.classMask, spell.classMask) then return false end
  if cfg.classSpellsOnly and spell.classMask == 0 then return false end
  if cfg.procMaskExclude and cfg.procMaskExclude ~= 0 and has(spell.procMask, cfg.procMaskExclude) then return false end
  if cfg.procMask and cfg.procMask ~= 0 and not has(spell.procMask, cfg.procMask) then return false end
  return true
end
S.ProcMatchesSpell = MatchesSpell

local function CopyResult(r)
  return { target = r.target, outcome = r.outcome, damage = r.damage }
end

function S.AttachProcTrigger(aura, unit, cfg)
  local icd
  if cfg.icd and cfg.icd ~= 0 then
    icd = { timer = unit:NewTimer(), duration = cfg.icd } -- unit timers reset every iteration
    aura.icd = icd
  end
  local dpm = cfg.dpm
  local handler = cfg.handler
  local procChance = cfg.procChance
  if not procChance or procChance == 0 then procChance = 1 end
  local function apply(sim, spell, result)
    if cfg.triggerImmediately then return handler(sim, spell, result) end
    local snap = result and CopyResult(result) or nil
    sim:Add({ at = sim.now + S.SPELL_BATCH, prio = S.PRIO_DOT, fn = function(s) handler(s, spell, snap) end })
  end
  -- Whether a spell can trigger this depends only on fixed spell properties: cache it per spell.
  local matchCache = {}
  local function callback(a, sim, spell, result)
    local mc = matchCache[spell]
    if mc == nil then
      mc = MatchesSpell(cfg, spell)
      matchCache[spell] = mc
    end
    if not mc then return end
    if cfg.outcome and cfg.outcome ~= 0 then
      local ok = has(result.outcome, cfg.outcome)
      if has(result.outcome, O.SuppressedCrit) and has(cfg.outcome, O.Crit) then
        local rest = cfg.outcome - O.Crit
        ok = rest == 0 or has(result.outcome, rest)
      end
      if not ok then return end
    end
    if cfg.requireDamageDealt and result.damage == 0 then return end
    if icd and icd.timer.readyAt > sim.now then return end
    if cfg.extraCondition and not cfg.extraCondition(sim, spell, result) then return end
    if procChance ~= 1 then
      if sim:Rand() > procChance then return end
    elseif dpm and not dpm.Proc(sim, spell.procMask) then
      return
    end
    if icd then icd.timer.readyAt = sim.now + icd.duration end
    apply(sim, spell, result)
  end
  local cb = cfg.callback or "hit"
  local cbs = type(cb) == "table" and cb or { cb }
  for _, c in ipairs(cbs) do
    if c == "hit" then aura.onSpellHitDealt = callback
    elseif c == "taken" then aura.onSpellHitTaken = callback
    elseif c == "periodic" then aura.onPeriodicDamageDealt = callback
    elseif c == "cast" then
      aura.onCastComplete = function(a, sim, spell)
        if not MatchesSpell(cfg, spell) then return end
        if icd and icd.timer.readyAt > sim.now then return end
        if cfg.extraCondition and not cfg.extraCondition(sim, spell, nil) then return end
        if procChance ~= 1 and sim:Rand() > procChance then return end
        if icd then icd.timer.readyAt = sim.now + icd.duration end
        apply(sim, spell, nil)
      end
    elseif c == "apply" then
      aura.onApplyEffects = function(a, sim, target, spell)
        if not MatchesSpell(cfg, spell) then return end
        if icd and icd.timer.readyAt > sim.now then return end
        local empty = NewResult(target)
        if cfg.extraCondition and not cfg.extraCondition(sim, spell, empty) then return end
        if procChance ~= 1 and sim:Rand() > procChance then return end
        if icd then icd.timer.readyAt = sim.now + icd.duration end
        apply(sim, spell, empty)
      end
    end
  end
  return aura
end

function S.UnitMT:MakeProcTriggerAura(cfg)
  local a = self:RegisterAura({ label = cfg.name, duration = cfg.duration, actionId = cfg.actionId })
  if not cfg.duration or cfg.duration == 0 then
    a.duration = huge
    a.onReset = function(aura, sim) aura:Activate(sim) end
  end
  S.AttachProcTrigger(a, self, cfg)
  return a
end

-- shared.OutcomeMeleeNoCrit
OUT.MeleeSpecialNoCrit = function(spell, sim, r, at) return OUT.MeleeSpecialHit(spell, sim, r, at) end

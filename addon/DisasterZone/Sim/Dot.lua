if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Dot.lua", ...) then return end -- DisasterZone: Sim/Dot.lua
-- ns.GearSim damage over time (dot.go): a DoT is an aura on its target that ticks on its own pending action,
-- snapshots the caster's damage when applied, and fits its ticks to the (hasted) tick period.
--
-- A spell gets its DoT with cfg.dot = { label, numberOfTicks, tickLength, onSnapshot(sim, target, dot),
-- onTick(sim, target, dot), affectedByCastSpeed, hasteReducesDuration, bonusCoefficient, periodicDamageMultiplier,
-- selfOnly }; spell:Dot(target) returns it.
local _, ns = ...
local S = ns.GearSim
local O = S.O

local huge, floor = math.huge, math.floor

local Dot = {}
Dot.__index = Dot
S.DotMT = Dot

-- Go math.RoundToEven
local function RoundToEven(x)
  local f = floor(x)
  local d = x - f
  if d > 0.5 + 1e-9 then return f + 1 end
  if d < 0.5 - 1e-9 then return f end
  return (f % 2 == 0) and f or f + 1
end

function Dot:BaseDuration() return self.baseTickCount * self.baseTickLength * self.baseDurationMultiplier end

function Dot:CalcTickPeriod()
  if self.affectedByCastSpeed then return S.RoundMs(self.spell.unit:ApplyCastSpeed(self.baseTickLength)) end
  return self.baseTickLength
end

function Dot:CalculateTickCount(baseDuration, tickPeriod) return RoundToEven(baseDuration / tickPeriod) end
function Dot:HastedTickCount() return self:CalculateTickCount(self:BaseDuration(), self.tickPeriod) end
function Dot:TickPeriod() return self.tickPeriod end
function Dot:RemainingTicks() return self.remainingTicks end
function Dot:NextTickAt() return (self.aura.active and self.tickAction) and self.tickAction.at or 0 end
function Dot:IsActive() return self.aura.active end
function Dot:RemainingDuration(sim) return self.aura:RemainingDuration(sim) end

function Dot:TakeSnapshot(sim)
  if self.onSnapshot then self.onSnapshot(sim, self.aura.unit, self) end
end

function Dot:RecomputeAuraDuration()
  self.tickPeriod = self:CalcTickPeriod()
  self.remainingTicks = self:CalculateTickCount(self:BaseDuration(), self.baseTickLength)
  if self.affectedByCastSpeed and not self.hasteReducesDuration then self.remainingTicks = self:HastedTickCount() end
  self.extraTicks = 0
  self.aura.duration = self.tickPeriod * self.remainingTicks
end

-- Snapshots and (re)starts the DoT.
function Dot:Apply(sim)
  self.aura:Deactivate(sim)
  self:TakeSnapshot(sim)
  self:RecomputeAuraDuration()
  self.aura:Activate(sim)
end

function Dot:Deactivate(sim) self.aura:Deactivate(sim) end

function Dot:TickOnce(sim)
  if self.onTick then self.onTick(sim, self.aura.unit, self) end
end

function Dot:PeriodicTick(sim)
  self.remainingTicks = self.remainingTicks - 1
  self:TickOnce(sim)
  if self.aura.active then
    local pa = self.tickAction
    pa.at = sim.now + self.tickPeriod
    pa.consumed, pa.cancelled = nil, nil
    sim:Add(pa)
  end
end

-- Snapshots (spell_result.go)
function Dot:Snapshot(target, base)
  local spell = self.spell
  local at = spell.unit.attackTables[target]
  self.snapshotBaseDamage = base
  if self.bonusCoefficient > 0 then self.snapshotBaseDamage = base + self.bonusCoefficient * spell:BonusDamage(at) end
  self.snapshotAttackerMultiplier = spell:AttackerDamageMultiplier(at, true) * self.periodicDamageMultiplier
end

function Dot:SnapshotPhysical(target, base)
  local spell = self.spell
  self.snapshotBaseDamage = base
  self.snapshotAttackerMultiplier = spell:AttackerDamageMultiplier(spell.unit.attackTables[target], true) * self.periodicDamageMultiplier
end

function Dot:CalcSnapshotDamage(sim, target, outcomeFn)
  return self.spell:CalcDamageInternal(sim, target, self.snapshotBaseDamage, self.snapshotAttackerMultiplier, true, outcomeFn)
end

function Dot:CalcAndDealPeriodicSnapshotDamage(sim, target, outcomeFn)
  local r = self:CalcSnapshotDamage(sim, target, outcomeFn)
  self.spell:DealPeriodicDamage(sim, r)
  return r
end

-- spell_result.go MagicHitCheck
if not S.SpellMT.MagicHitCheck then
  function S.SpellMT:MagicHitCheck(sim, at) return sim:Proc(1 - self:SpellChanceToMiss(at)) end
end

-- Tick outcomes (spell_outcome.go Dot.OutcomeTick / OutcomeTickMagicHit)
function S.OUT.Tick(spell, sim, r, at) r.outcome = O.Hit end
function S.OUT.TickMagicHit(spell, sim, r, at)
  if spell:MagicHitCheck(sim, at) then
    r.outcome = O.Hit
  else
    r.outcome = O.Miss
    r.damage = 0
  end
end

local function NewDot(spell, cfg, aura)
  local dot = setmetatable({
    spell = spell, aura = aura,
    baseTickCount = cfg.numberOfTicks, baseTickLength = cfg.tickLength,
    remainingTicks = cfg.numberOfTicks, extraTicks = 0, baseDurationMultiplier = 1,
    onSnapshot = cfg.onSnapshot, onTick = cfg.onTick,
    affectedByCastSpeed = cfg.affectedByCastSpeed, hasteReducesDuration = cfg.hasteReducesDuration,
    bonusCoefficient = cfg.bonusCoefficient or 0, periodicDamageMultiplier = cfg.periodicDamageMultiplier or 1,
    snapshotBaseDamage = 0, snapshotAttackerMultiplier = 0,
  }, Dot)
  dot.tickPeriod = dot.baseTickLength
  aura.duration = dot.tickPeriod * dot.baseTickCount
  aura.dot = dot
  local og, oe = aura.onGain, aura.onExpire
  aura.onGain = function(a, sim)
    if og then og(a, sim) end
    dot.tickAction = { at = sim.now + dot.tickPeriod, prio = 0, fn = function(s) dot:PeriodicTick(s) end }
    sim:Add(dot.tickAction)
  end
  aura.onExpire = function(a, sim)
    if oe then oe(a, sim) end
    local pa = dot.tickAction
    -- an expiry at the time of the last tick runs first: apply that tick here
    if pa and pa.at == sim.now and not pa.consumed and not pa.cancelled then
      dot.remainingTicks = dot.remainingTicks - 1
      dot:TickOnce(sim)
    end
    if pa and not pa.consumed and not pa.cancelled then sim:Cancel(pa) end
    dot.tickAction = nil
    dot.snapshotAttackerMultiplier = 0
    dot.snapshotBaseDamage = 0
  end
  return dot
end

-- spell.go createDots: one DoT per enemy (or one on the caster for self-only / AoE ones).
function S.CreateDots(spell, cfg)
  spell.dots = {}
  local caster = spell.unit
  local label = (cfg.label or tostring(spell.id)) .. "-" .. tostring(caster.label or "player")
  if cfg.selfOnly then
    local aura = caster:RegisterAura({ label = cfg.label or tostring(spell.id), actionId = spell.actionId })
    spell.aoeDot = NewDot(spell, cfg, aura)
    return
  end
  spell.dotConfig = cfg
  spell.dotLabel = label
  if caster.currentTarget then S.SpellMT_Dot(spell, caster.currentTarget) end
end

-- The DoT on a target (made on first use: the targets exist after the player's spells are registered).
function S.SpellMT_Dot(spell, target)
  if spell.aoeDot then return spell.aoeDot end
  local d = spell.dots[target]
  if not d then
    local aura = target:RegisterAura({ label = spell.dotLabel, dotOf = spell })
    d = NewDot(spell, spell.dotConfig, aura)
    spell.dots[target] = d
  end
  return d
end

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Dot.lua", ...) then return end -- DisasterZone: Sim/Dot.lua
-- ns.GearSim damage over time (dot.go): a DoT is an aura on its target that ticks on its own pending action,
-- snapshots the caster's damage when applied, and fits its ticks to the (hasted) tick period.
--
-- A spell gets its DoT with cfg.dot = { label, numberOfTicks, tickLength, onSnapshot(sim, target, dot),
-- onTick(sim, target, dot), affectedByCastSpeed, hasteReducesDuration, bonusCoefficient, periodicDamageMultiplier,
-- selfOnly, maxStacks }; spell:Dot(target) returns it.
--
-- A channeled spell's DoT (flag Channeled: Mind Flay) is the channel: while it runs the rotation only asks whether
-- to clip it (the channel action's interruptIf, at each tick and when the GCD ends); when it ends or is clipped the
-- rotation goes on after the channel clip delay.
local _, ns = ...
local S = ns.GearSim
local O = S.O

local huge, floor, max = math.huge, math.floor, math.max

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
  if self.affectedByCastSpeed then
    local u = self.spell.unit
    if self.isChanneled then
      -- ApplyCastSpeedForSpell
      return S.RoundMs(self.baseTickLength * u.castSpeed * max(0, self.spell.castTimeMultiplier or 1))
    end
    return S.RoundMs(u:ApplyCastSpeed(self.baseTickLength))
  end
  return self.baseTickLength
end

-- Ticks done so far (dot.go TickCount).
function Dot:TickCount()
  if self.hasteReducesDuration then return self.baseTickCount + self.extraTicks - self.remainingTicks end
  return self:HastedTickCount() + self.extraTicks - self.remainingTicks
end

-- dot.go ChannelCanBeInterrupted: ticks left and the channel action's interruptIf holds.
function Dot:ChannelCanBeInterrupted(sim)
  if not self.isChanneled or self.remainingTicks == 0 then return false end
  local rot = self.spell.unit.rotation
  local f = rot and rot.interruptChannelIf
  return f ~= nil and f(sim)
end

-- Clip the channel now: no last tick on the way out; the rotation goes on after the clip delay.
function Dot:Clip(sim)
  local u = self.spell.unit
  self.noFinalTick = true
  self.aura:Deactivate(sim)
  self.noFinalTick = nil
  if u.GCD.readyAt <= sim.now then u:WaitUntil(sim, sim.now + u.channelClipDelay) end
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
  if self.isChanneled then
    local u = self.spell.unit
    if self.remainingTicks == 0 and u.GCD.readyAt <= sim.now then
      -- a WaitUntil even with no clip delay, so the rotation runs after the channel aura fades
      u:WaitUntil(sim, sim.now + u.channelClipDelay)
    else
      local rot = u.rotation
      local gcdLeft = u.GCD.readyAt - sim.now
      -- a clip only because the GCD is inside the queue window is left to the rotation at the GCD
      if rot and rot.ShouldInterruptChannel and rot:ShouldInterruptChannel(sim)
        and (gcdLeft <= 0 or gcdLeft > S.QUEUE_WINDOW) then
        self:Clip(sim)
        return
      end
    end
  end
  if self.aura.active and (not self.isChanneled or self.remainingTicks > 0) then
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
    isChanneled = S.has(spell.flags or 0, S.F.Channeled),
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
    if dot.isChanneled then dot.spell.unit.channeledDot = dot end
  end
  aura.onExpire = function(a, sim)
    if oe then oe(a, sim) end
    local pa = dot.tickAction
    -- an expiry at the time of the last tick runs first: apply that tick here (also when that tick is the event
    -- being run: dot.go cancels it either way, so it doesn't tick again with the snapshot cleared)
    if pa and not pa.cancelled and not dot.noFinalTick and pa.at - sim.now < 1e-9 and sim.now - pa.at < 1e-9 then
      dot.remainingTicks = dot.remainingTicks - 1
      dot:TickOnce(sim)
    end
    if pa and not pa.cancelled then sim:Cancel(pa) end
    dot.tickAction = nil
    if dot.isChanneled then
      local u = dot.spell.unit
      u.channeledDot = nil
      local rot = u.rotation
      if rot then rot.interruptChannelIf, rot.allowChannelRecast = nil, false end
      if u.GCD.readyAt <= sim.now then u:WaitUntil(sim, sim.now + u.channelClipDelay) end
    end
    dot.snapshotAttackerMultiplier = 0
    dot.snapshotBaseDamage = 0
  end
  return dot
end

-- A DoT's aura carries its spell's ActionID (the rotation looks it up by that).
function S.DotActionId(spell)
  if type(spell.id) ~= "number" then return nil end
  return { spellId = spell.id, tag = spell.tag }
end

-- spell.go createDots: one DoT per enemy (or one on the caster for self-only / AoE ones).
function S.CreateDots(spell, cfg)
  spell.dots = {}
  local caster = spell.unit
  local label = (cfg.label or tostring(spell.id)) .. "-" .. tostring(caster.label or "player")
  if cfg.selfOnly then
    local aura = caster:RegisterAura({ label = cfg.label or tostring(spell.id), actionId = spell.actionId or S.DotActionId(spell) })
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
  -- spell.go Dot: a spell whose DoT is another spell's (Moonfire's hit and its DoT)
  if not spell.dots and spell.relatedDotSpell then return S.SpellMT_Dot(spell.relatedDotSpell, target) end
  local d = spell.dots[target]
  if not d then
    local aura = target:RegisterAura({ label = spell.dotLabel, dotOf = spell, actionId = S.DotActionId(spell),
      maxStacks = spell.dotConfig.maxStacks })
    d = NewDot(spell, spell.dotConfig, aura)
    spell.dots[target] = d
  end
  return d
end

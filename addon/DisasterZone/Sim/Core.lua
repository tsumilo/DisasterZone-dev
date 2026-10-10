if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Core.lua", ...) then return end -- DisasterZone: Sim/Core.lua
-- ns.GearSim: an event-driven combat simulator, a Lua port of WoWSims TBC (github.com/wowsims/tbc-new, MIT).
-- Pure Lua 5.1: no WoW API, so it also runs in the dev kit (dev/tools/gearsim) against the real WoWSims.
-- This file: random numbers, the pending-action queue and the fight loop (sim/core/sim.go, pending_action.go).
-- Time is in seconds. Ordering follows sim.go exactly: weapon swings before pending actions at the same time,
-- pending actions by time, then priority (higher first), then first-in-first-out.
local _, ns = ...
local S = ns.GearSim or {}
ns.GearSim = S

local floor, huge, max, min = math.floor, math.huge, math.max, math.min

S.NEVER = huge
S.SPELL_BATCH = 0.010 -- SpellBatchWindow
-- MaxSpellQueueWindow, plus 1 ns: Go's clock is whole nanoseconds, so a spell exactly 400 ms from ready is inside
-- the window there; here float error can put it a hair outside
S.QUEUE_WINDOW = 0.400 + 1e-9
S.GCD_DEFAULT = 1.5
S.GCD_MIN = 1.0

-- Action priorities (pending_action.go).
S.PRIO_LOW, S.PRIO_GCD, S.PRIO_REGEN, S.PRIO_AUTO, S.PRIO_DOT, S.PRIO_PREPULL = -1, 0, 1, 2, 3, 10

-- ---------------------------------------------------------------------------------------------------------------
-- Random numbers: L'Ecuyer's combined generator (two MLCGs, period ~2.3e18). Every product stays below 2^53, so
-- plain double arithmetic is exact; no bit library needed. One stream per iteration, seeded from (seed, i), so
-- two gear sets simmed with the same seed see the same rolls as long as their event order matches.
-- ---------------------------------------------------------------------------------------------------------------
local M1, M2 = 2147483563, 2147483399
local INV = 1 / M1

local function NewRand()
  local r = { s1 = 1, s2 = 1 }
  return r
end

local function Seed(r, seed, iteration)
  local a = (seed * 7919 + iteration * 104729 + 12345) % (M1 - 1) + 1
  local b = (seed * 3301 + iteration * 15485863 + 67890) % (M2 - 1) + 1
  r.s1, r.s2 = a, b
  -- Warm up so nearby seeds decorrelate.
  for _ = 1, 8 do
    r.s1 = (40014 * r.s1) % M1
    r.s2 = (40692 * r.s2) % M2
  end
end
S.NewRand, S.SeedRand = NewRand, Seed

-- ---------------------------------------------------------------------------------------------------------------
-- Simulation
-- ---------------------------------------------------------------------------------------------------------------
local Sim = {}
Sim.__index = Sim
S.SimMT = Sim

function S.NewSim(opts)
  local sim = setmetatable({
    rand = NewRand(),
    seed = opts.seed or 101,
    baseDuration = opts.duration or 180,
    durationVariation = opts.durationVariation or 0,
    execute20 = opts.execute20 or 0.2,
    execute25 = opts.execute25 or 0.25,
    execute35 = opts.execute35 or 0.35,
    execute45 = opts.execute45 or 0.45,
    execute90 = opts.execute90 or 0.9,
    pending = {},       -- sorted, next action LAST (as in Go)
    weaponAttacks = {}, -- WeaponAttack objects currently swinging
    minWeaponAttackTime = huge,
    tasks = {},         -- objects with RunTask(sim) -> next time (energy / focus ticks)
    minTaskTime = huge,
    sleepingPets = {},  -- pets whose rotation sleeps between events (Pet.lua)
    trackers = {},      -- units whose auras expire
    minTrackerTime = huge,
    now = 0,
    units = {},         -- player units (index 1 = the simmed player)
    targets = {},
    prepullActions = {},
    executeCallbacks = {},
    log = opts.log,      -- function(sim, fmt, ...) or nil
    damageTaken = 0,
  }, Sim)
  return sim
end

function Sim:Rand()
  local r = self.rand
  local s1 = (40014 * r.s1) % M1
  local s2 = (40692 * r.s2) % M2
  r.s1, r.s2 = s1, s2
  local z = s1 - s2
  if z < 1 then z = z + M1 - 1 end
  return z * INV
end

function Sim:Roll(lo, hi)
  return lo + (hi - lo) * self:Rand()
end

function Sim:Proc(p)
  if p >= 1 then return true elseif p <= 0 then return false end
  return self:Rand() < p
end

-- Pending actions: { at = time, prio = n, fn = function(sim), cleanUp = fn|nil, cancelled, consumed }.
function Sim:Add(pa)
  pa.consumed, pa.cancelled = false, false
  local pas = self.pending
  local n = #pas
  local k = n + 1
  local at, prio = pa.at, pa.prio
  -- The array is sorted with the next action at the end; scan from the end for the insert point.
  while k > 1 do
    local v = pas[k - 1]
    if v.at < at or (v.at == at and v.prio >= prio) then
      k = k - 1
    else
      break
    end
  end
  table.insert(pas, k, pa)
end

-- A fire-and-forget delayed call.
function Sim:After(delay, prio, fn)
  local pa = { at = self.now + delay, prio = prio, fn = fn }
  self:Add(pa)
  return pa
end

function Sim:At(at, prio, fn)
  local pa = { at = at, prio = prio, fn = fn }
  self:Add(pa)
  return pa
end

function Sim:Cancel(pa)
  if not pa or pa.cancelled then return end
  if pa.cleanUp then
    local c = pa.cleanUp
    pa.cleanUp = nil
    c(self)
  end
  pa.cancelled = true
  local pas = self.pending
  for i = #pas, 1, -1 do
    if pas[i] == pa then
      table.remove(pas, i)
      break
    end
  end
end

function Sim:RescheduleWeaponAttack(t)
  if t < self.minWeaponAttackTime then self.minWeaponAttackTime = t end
end

function Sim:AddWeaponAttack(wa)
  local list = self.weaponAttacks
  for i = 1, #list do if list[i] == wa then return end end
  list[#list + 1] = wa
end

function Sim:RemoveWeaponAttack(wa)
  local list = self.weaponAttacks
  for i = 1, #list do
    if list[i] == wa then
      table.remove(list, i)
      return
    end
  end
end

-- Tasks (sim.go AddTask / RescheduleTask): run before pending actions at the same time, after weapon swings.
function Sim:AddTask(task)
  self.tasks[#self.tasks + 1] = task
end

function Sim:RemoveTask(task)
  local list = self.tasks
  for i = 1, #list do
    if list[i] == task then
      list[i] = list[#list]
      list[#list] = nil
      return
    end
  end
end

function Sim:RescheduleTask(t)
  if t < self.minTaskTime then self.minTaskTime = t end
end

function Sim:AdvanceTasks()
  if self.minTaskTime > self.now then self:Advance(self.minTaskTime) end
  local m = huge
  local list = self.tasks
  for i = 1, #list do
    local t = list[i]:RunTask(self)
    if t < m then m = t end
  end
  self.minTaskTime = m
end

function Sim:RescheduleTracker(t)
  if t < self.minTrackerTime then self.minTrackerTime = t end
end

function Sim:AddTracker(unit)
  self.trackers[#self.trackers + 1] = unit
end

-- Execute phases (sim.go nextExecutePhase), duration-based fights only.
function Sim:NextExecutePhase()
  self.nextExecuteAt = huge
  local p = self.executePhase
  local d = self.duration
  if p == 0 then
    self.executePhase, self.nextExecuteAt = 100, (1 - self.execute90) * d
  elseif p == 100 then
    self.executePhase, self.nextExecuteAt = 90, (1 - self.execute45) * d
  elseif p == 90 then
    self.executePhase, self.nextExecuteAt = 45, (1 - self.execute35) * d
  elseif p == 45 then
    self.executePhase, self.nextExecuteAt = 35, (1 - self.execute25) * d
  elseif p == 35 then
    self.executePhase, self.nextExecuteAt = 25, (1 - self.execute20) * d
  elseif p == 25 then
    self.executePhase = 20
  end
end

function Sim:IsExecute20() return self.executePhase <= 20 end
function Sim:IsExecute35() return self.executePhase <= 35 end

function Sim:Advance(t)
  self.now = t
  while t >= self.nextExecuteAt do
    self:NextExecutePhase()
    for _, cb in ipairs(self.executeCallbacks) do cb(self, self.executePhase) end
  end
  if t + S.TIME_EPS >= self.minTrackerTime then
    local m = huge
    local trackers = self.trackers
    for i = 1, #trackers do
      local e = trackers[i]:AdvanceAuras(self)
      if e < m then m = e end
    end
    self.minTrackerTime = m
  end
end

function Sim:AdvanceWeaponAttacks()
  if self.minWeaponAttackTime > self.now then self:Advance(self.minWeaponAttackTime) end
  local m = huge
  local list = self.weaponAttacks
  local i = 1
  while i <= #list do
    local wa = list[i]
    local nextAt = wa:TrySwing(self)
    if nextAt < m then m = nextAt end
    i = i + 1
  end
  self.minWeaponAttackTime = m
end

-- One step of the event loop; returns true when the fight is over.
function Sim:Step()
  local pas = self.pending
  local last = #pas
  local pa = pas[last]
  local paAt = pa and pa.at or huge
  local mw, mt = self.minWeaponAttackTime, self.minTaskTime
  if paAt >= mw and mw <= mt then
    if mw > self.duration then return true end
    self:WakeRotations(mw, huge, nil)
    if self.sleepingPets[1] then self:WakePets(mw, huge, nil) end
    self:AdvanceWeaponAttacks()
    return false
  end
  if paAt >= mt then
    if mt > self.duration then return true end
    self:WakeRotations(mt, huge, nil)
    if self.sleepingPets[1] then self:WakePets(mt, huge, nil) end
    self:AdvanceTasks()
    return false
  end
  pas[last] = nil
  pa.consumed = true
  if pa.cancelled then return false end
  if paAt > self.duration then return true end
  if not pa.isRotation then self:WakeRotations(paAt, pa.prio, pa) end
  if self.sleepingPets[1] then self:WakePets(paAt, pa.prio, pa) end
  if paAt > self.now then self:Advance(paAt) end
  if pa.cancelled then return false end
  pa.fn(self)
  return false
end

-- A sleeping rotation (APL.lua) wakes at the next poll of its 10 ms grid after any event.
function Sim:WakeRotations(at, prio, pa)
  local units = self.units
  for i = 1, #units do
    local u = units[i]
    local w = u.skipWake
    if w and at < w then S.WakeSleepingRotation(self, u, at, prio) end
  end
end

-- Sleeping pets (Pet.lua cfg.sleeps) wake after any event but their own rotation's, the owner's included.
function Sim:WakePets(at, prio, pa)
  local pets = self.sleepingPets
  for i = 1, #pets do
    local u = pets[i]
    local w = u.skipWake
    if w and at < w and pa ~= u.rotationAction then S.WakeSleepingRotation(self, u, at, prio) end
  end
end

function Sim:Log(fmt, ...)
  if self.log then self.log(self, string.format(fmt, ...)) end
end

-- One iteration: reset everything, schedule the prepull, run to the end (sim.go runOnce).
function Sim:RunOnce(iteration)
  Seed(self.rand, self.seed, iteration)
  self.duration = self.baseDuration
  if self.durationVariation ~= 0 then
    self.duration = self.duration + self:Rand() * self.durationVariation * 2 - self.durationVariation
  end
  self.pending = {}
  self.executePhase = 0
  self:NextExecutePhase()
  self.executeCallbacks = {}
  self.now = 0
  self.trackers = {}
  self.minTrackerTime = huge
  self.weaponAttacks = {}
  self.minWeaponAttackTime = huge
  self.tasks = {}
  self.minTaskTime = huge
  self.damageTaken = 0
  self.isInPrepull = true

  for _, t in ipairs(self.targets) do t:Reset(self) end
  for _, u in ipairs(self.units) do u:Reset(self) end
  self.sleepingPets = {}
  for _, u in ipairs(self.units) do
    for _, pet in ipairs(u.pets or {}) do
      if pet.sleeps then self.sleepingPets[#self.sleepingPets + 1] = pet end
    end
  end
  self:InitManaTick()

  -- PrePull (sim.go): prepull actions in DoAt order, then the encounter start at 0 with the top priority.
  local pre = self.prepullActions
  local start = (pre[1] and pre[1].at) or 0
  if pre[1] then self.now = start end
  for i, ppa in ipairs(pre) do
    self:Add({ at = ppa.at, prio = S.PRIO_PREPULL + (#pre - i + 1), fn = ppa.fn })
  end
  self:Add({ at = 0, prio = S.PRIO_PREPULL + #pre + 1, fn = function(sim)
    for _, u in ipairs(sim.units) do u:OnEncounterStart(sim) end
    for _, u in ipairs(sim.units) do u:StartPull(sim) end
  end })
  self.isInPrepull = false

  while not self:Step() do end

  self.now = self.duration
  for _, pa in ipairs(self.pending) do
    if pa.cleanUp then pa.cleanUp(self) end
  end
  -- sim.go: the raid (each player's pets first), then the encounter's targets
  for _, u in ipairs(self.units) do
    for _, pet in ipairs(u.pets or {}) do pet:DeactivateAllAuras(self) end
    u:DoneIteration(self)
  end
  for _, t in ipairs(self.targets) do t:DeactivateAllAuras(self) end
end

function Sim:PrepullStartTime()
  local pre = self.prepullActions
  return (pre[1] and pre[1].at) or 0
end

-- Mana ticks every 2 s from the prepull start (mana.go initManaTickAction).
function Sim:InitManaTick()
  -- mana.go: players, then their pets with a mana bar (each while enabled)
  local units = {}
  for _, u in ipairs(self.units) do if u.hasMana then units[#units + 1] = u end end
  for _, u in ipairs(self.units) do
    for _, pet in ipairs(u.pets or {}) do if pet.hasMana then units[#units + 1] = pet end end
  end
  if #units == 0 then return end
  local pa
  pa = { at = self:PrepullStartTime() + 2, prio = S.PRIO_REGEN, fn = function(sim)
    for i = 1, #units do
      local u = units[i]
      if u.enabled ~= false then u:ManaTick(sim) end
    end
    pa.at = sim.now + 2
    sim:Add(pa)
  end }
  self:Add(pa)
end

-- Sort prepull actions by time (environment.go keeps them ordered by DoAt).
function Sim:RegisterPrepullAction(at, fn)
  local pre = self.prepullActions
  local k = #pre + 1
  while k > 1 and pre[k - 1].at > at do k = k - 1 end -- stable: equal times keep registration order
  table.insert(pre, k, { at = at, fn = fn })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Timers and cooldowns (cooldown.go): a timer is a ready-at time; a cooldown is a timer plus a duration.
-- ---------------------------------------------------------------------------------------------------------------
S.STARTING_CD = -3600 -- cooldown.go startingCDTime (-60 min): every timer starts "long ready"
function S.NewTimer() return { readyAt = S.STARTING_CD } end

function S.TimerReady(t, sim) return t.readyAt <= sim.now end
function S.TimerTimeToReady(t, sim) return max(0, t.readyAt - sim.now) end

S.floor, S.min, S.max = floor, min, max

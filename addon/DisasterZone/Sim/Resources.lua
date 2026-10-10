if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Resources.lua", ...) then return end -- DisasterZone: Sim/Resources.lua
-- ns.GearSim power bars other than mana: rage (rage.go), energy and combo points (energy.go). Spells name their cost
-- with rageCost / energyCost = { cost, refund } (Spell.lua); rage gains wake the rotation the way WoWSims' AddRage does (ReactToEvent with the reaction time).
local _, ns = ...
local S = ns.GearSim
local PM, O = S.PM, S.O
local has = S.has

local max, min = math.max, math.min

local Unit = S.UnitMT

-- ---------------------------------------------------------------------------------------------------------------
-- Rage (rage.go)
-- ---------------------------------------------------------------------------------------------------------------
S.RAGE_FACTOR = 274.7
S.BASE_RAGE_HIT_FACTOR = 3.5

-- opts: { maxRage, startingRage, baseRageMultiplier }
function Unit:EnableRageBar(opts)
  self.hasRage = true
  self.maxRage = max(100, opts.maxRage or 100)
  self.startingRage = max(0, min(opts.startingRage or 0, self.maxRage))
  self.startingHitFactor = S.BASE_RAGE_HIT_FACTOR * (opts.baseRageMultiplier or 1)
  self.rage = self.startingRage
  self.rageHitFactor = self.startingHitFactor
  self.rageMultiplier = 1
  self.rageGains = {}
  local u = self
  local bar = self:RegisterAura({ label = "RageBar" })
  -- white swings (and dodged / parried ones, on the damage they would have done) generate rage; misses don't
  bar.onSpellHitDealt = function(_, sim, spell, result)
    local o = result.outcome
    if not has(o, O.Landed) and not has(o, O.Dodge + O.Parry) then return end
    local hitFactor = u.rageHitFactor
    local speed
    local pm = spell.procMask
    if pm == PM.MeleeMHAuto then
      speed = u.autoAttacks.mh.swingSpeed
    elseif pm == PM.MeleeOHAuto then
      hitFactor = hitFactor / 2
      speed = u.autoAttacks.oh.swingSpeed
    else
      return
    end
    if has(o, O.Crit) then hitFactor = hitFactor * 2 end
    local damage = result.damage
    if has(o, O.Dodge + O.Parry) then damage = result.postArmor or 0 end
    local gain = min((damage * 7.5 / S.RAGE_FACTOR + hitFactor * speed) / 2, damage * 15 / S.RAGE_FACTOR)
    u:AddRage(sim, gain, "white")
  end
  bar.onSpellHitTaken = function(_, sim, _, result)
    u:AddRage(sim, result.damage * 2.5 / S.RAGE_FACTOR, "damage_taken")
  end
  S.MakePermanent(bar)
  self:RegisterResetEffect(function()
    u.rage = u.startingRage
    u.rageHitFactor = u.startingHitFactor
    u.rageMultiplier = 1
  end)
end

function Unit:CurrentRage() return self.rage end
function Unit:MaximumRage() return self.maxRage end

-- Battle Stance, Endless Rage, ...
function Unit:MultiplyAutoAttackRageGen(m) self.rageHitFactor = self.rageHitFactor * m end
function Unit:MultiplyRageGen(m) self.rageMultiplier = self.rageMultiplier * m end

function Unit:AddRage(sim, amount, metric)
  if amount < 0 then error("negative rage") end
  local gain = amount * self.rageMultiplier
  local new = min(self.rage + gain, self.maxRage)
  if metric then self.rageGains[metric] = (self.rageGains[metric] or 0) + (new - self.rage) end
  if sim.log then sim:Log("Gained %.3f rage from %s (%.3f --> %.3f)", gain, tostring(metric), self.rage, new) end
  self.rage = new
  if self.rotation then self:ReactToEvent(sim, false, true) end
end

function Unit:SpendRage(sim, amount)
  if amount < 0 then error("negative rage spend") end
  if sim.log then sim:Log("Spent %.3f rage (%.3f --> %.3f)", amount, self.rage, self.rage - amount) end
  self.rage = self.rage - amount
end

-- ---------------------------------------------------------------------------------------------------------------
-- Energy and combo points (energy.go): 20.2 energy every 2.02 s as a sim task, the first tick at a random point of
-- the first 2.02 s after the prepull start. Energy changes don't wake the rotation (it polls).
-- ---------------------------------------------------------------------------------------------------------------
S.ENERGY_TICK, S.ENERGY_PER_TICK = 2.02, 20.2

-- opts: { maxEnergy, maxComboPoints }
function Unit:EnableEnergyBar(opts)
  self.hasEnergy = true
  self.maxEnergy = max(10, opts.maxEnergy or 100)
  self.maxComboPoints = opts.maxComboPoints or 0
  self.energy, self.comboPoints = self.maxEnergy, 0
  self.energyRegenMultiplier = 1
  self.nextEnergyTick = 0
  self.energyGains = {}
  local u = self
  local task = {}
  function task.RunTask(_, sim)
    if sim.now < u.nextEnergyTick then return u.nextEnergyTick end
    u:AddEnergy(sim, S.ENERGY_PER_TICK * u.energyRegenMultiplier, "regen")
    u.nextEnergyTick = sim.now + S.ENERGY_TICK
    return u.nextEnergyTick
  end
  self.energyTask = task
  self:RegisterResetEffect(function(sim)
    u.energy, u.comboPoints = u.maxEnergy, 0
    u.energyRegenMultiplier = 1
    sim:AddTask(task)
    u.nextEnergyTick = sim:PrepullStartTime() + sim:Rand() * S.ENERGY_TICK
    sim:RescheduleTask(u.nextEnergyTick)
  end)
end

function Unit:CurrentEnergy() return self.energy end
function Unit:ComboPoints() return self.comboPoints end

function Unit:AddEnergy(sim, amount, metric)
  if amount < 0 then error("negative energy") end
  local new = min(self.energy + amount, self.maxEnergy)
  if metric then self.energyGains[metric] = (self.energyGains[metric] or 0) + (new - self.energy) end
  if sim.log then sim:Log("Gained %.3f energy from %s (%.3f --> %.3f)", amount, tostring(metric), self.energy, new) end
  self.energy = new
end

function Unit:SpendEnergy(sim, amount)
  if amount < 0 then error("negative energy spend") end
  if sim.log then sim:Log("Spent %.3f energy (%.3f --> %.3f)", amount, self.energy, self.energy - amount) end
  self.energy = self.energy - amount
end

function Unit:EnergyIsTicking(sim)
  local n = self.nextEnergyTick
  return n ~= 0 and n - sim.now <= S.ENERGY_TICK and sim.now <= n
end

-- A partial tick for the time since the last one, and the tick timer restarts (ResetEnergyTick).
function Unit:ResetEnergyTick(sim)
  if not self:EnergyIsTicking(sim) then return end
  local since = max(sim.now - (self.nextEnergyTick - S.ENERGY_TICK), 0)
  self:AddEnergy(sim, S.ENERGY_PER_TICK * self.energyRegenMultiplier * (since / S.ENERGY_TICK), "regen")
  self.nextEnergyTick = sim.now + S.ENERGY_TICK
  sim:RescheduleTask(self.nextEnergyTick)
end

function Unit:MultiplyEnergyRegenSpeed(sim, m)
  self:ResetEnergyTick(sim)
  self.energyRegenMultiplier = self.energyRegenMultiplier * m
end

-- ---------------------------------------------------------------------------------------------------------------
-- Focus (focus.go): a hunter pet's resource, 100 at most, 25 every 5 s (Bestial Discipline: more a tick). A pet's
-- ticks start when it is summoned, at a random point of the first 5 s.
-- ---------------------------------------------------------------------------------------------------------------
function Unit:EnableFocusBar(regenMultiplier)
  self.hasFocus = true
  self.maxFocus = 100
  self.focus = 100
  self.focusPerTick = 25 * (regenMultiplier or 1)
  self.nextFocusTick = 0
  self.focusGains = {}
  local u = self
  local task = {}
  function task.RunTask(_, sim)
    if sim.now < u.nextFocusTick then return u.nextFocusTick end
    u:AddFocus(sim, u.focusPerTick, "regen")
    u.nextFocusTick = sim.now + 5
    return u.nextFocusTick
  end
  self.focusTask = task
  self:RegisterResetEffect(function() u.focus = u.maxFocus end)
end

function Unit:EnableFocusTicks(sim, startAt)
  self.focus = self.maxFocus
  sim:AddTask(self.focusTask)
  self.nextFocusTick = startAt + sim:Rand() * 5
  sim:RescheduleTask(self.nextFocusTick)
end

function Unit:DisableFocusTicks(sim)
  self.nextFocusTick = math.huge
  sim:RemoveTask(self.focusTask)
end

function Unit:AddFocus(sim, amount, metric)
  if amount < 0 then error("negative focus") end
  local new = min(self.focus + amount, self.maxFocus)
  if metric then self.focusGains[metric] = (self.focusGains[metric] or 0) + (new - self.focus) end
  if sim.log then sim:Log("Gained %.3f focus from %s (%.3f --> %.3f)", amount, tostring(metric), self.focus, new) end
  self.focus = new
end

function Unit:SpendFocus(sim, amount)
  if amount < 0 then error("negative focus spend") end
  self.focus = self.focus - amount
end

function Unit:AddComboPoints(sim, n, metric)
  local new = min(self.comboPoints + n, self.maxComboPoints)
  if sim.log then sim:Log("Gained %d combo points from %s (%d --> %d)", n, tostring(metric), self.comboPoints, new) end
  self.comboPoints = new
end

function Unit:SpendComboPoints(sim)
  if sim.log then sim:Log("Spent %d combo points", self.comboPoints) end
  self.comboPoints = 0
end

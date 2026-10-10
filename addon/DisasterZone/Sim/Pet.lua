if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Pet.lua", ...) then return end -- DisasterZone: Sim/Pet.lua
-- ns.GearSim pets (pet.go): a unit of its own that the owner summons, with base stats, stats taken from the owner
-- when it appears (not dynamic: a snapshot), its own auto attacks and a custom rotation run like an APL with one
-- CustomRotation action (apl_actions_misc.go). Guardians get no raid buffs. Its damage counts for the owner (the
-- owner's metrics, keys prefixed "pet_").
local _, ns = ...
local S = ns.GearSim
local ST = S.ST

local huge, max, ceil = math.huge, math.max, math.ceil
local EPS = 1e-9

-- The custom rotation (apl.go DoNextAction with the single CustomRotation action: once per timestamp).
local PR = {}
PR.__index = PR

function PR:DoNextAction(sim)
  if sim.now < 0 or self.inLoop then return end
  local u = self.unit
  if not u.enabled then return end
  if u.RotationTimer.readyAt > sim.now then return end
  u.skipWake = nil
  self.inLoop = true
  if self.lastAt ~= sim.now then
    self.lastAt = sim.now
    u.customRotation(sim, u)
  end
  self.inLoop = false
  if u.RotationTimer.readyAt <= sim.now then
    local rt = u.reactionTime
    local target = max(sim.now + rt, u.GCD.readyAt)
    -- A pet whose rotation only changes at events (cfg.sleeps) sleeps like an idle APL (APL.lua): to the first poll
    -- of its 10 ms grid at or after the next aura expiry / execute phase; Sim:Step wakes it after any event.
    local bound = 0
    if u.sleeps and not S.NO_SKIP then
      bound = sim.minTrackerTime
      if sim.nextExecuteAt < bound then bound = sim.nextExecuteAt end
    end
    if bound > target then
      local wake = target + ceil((bound - target) / rt - EPS) * rt
      if wake > sim.duration + 1 then wake = sim.duration + 1 end
      u.skipOrigin, u.skipWake = target, wake
      u:WaitUntil(sim, wake)
    else
      u:WaitUntil(sim, target)
    end
  end
end

function PR:Reset()
  self.inLoop = false
  self.unit.skipWake = nil
  self.lastAt = nil
  self.waitUntil = nil
end

-- cfg = { name, key (metrics prefix), baseStats = { [stat name] = v }, inherit = fn(ownerStats) -> { [ST] = v },
--   mainHand = weapon, rotation = fn(sim, pet), onEnable = fn(sim, pet), guardian (default true: no buffs),
--   enabledOnStart (false: no targeted buffs either) }
function S.NewPet(owner, cfg)
  local pet = S.NewUnit("pet", owner.label .. " - " .. cfg.name)
  pet.owner = owner
  pet.isPet = true
  pet.enabled = false
  pet.metrics = owner.metrics
  pet.metricsPrefix = "pet_" .. (cfg.key or cfg.name) .. "_"
  pet.reactionTime = owner.reactionTime
  pet.auraById = {}
  pet.professions = {}
  pet.gear, pet.gearIds, pet.setCounts = {}, {}, {}
  pet.class = cfg.class or "Warrior"
  pet.inherit = cfg.inherit
  pet.inherited = S.NewStats()
  pet.onEnable = cfg.onEnable
  pet.guardian = cfg.guardian ~= false
  pet.enabledOnStart = cfg.enabledOnStart == true
  pet.sleeps = cfg.sleeps == true
  for k, v in pairs(cfg.baseStats or {}) do pet:AddStat(ST[k], v) end
  pet:AddStatDependency(ST.Stamina, ST.Health, 10)
  pet:AddStatDependency(ST.Agility, ST.Armor, 2)
  if cfg.mana then pet:EnableManaBar(cfg.baseStats.Mana or 0) end
  pet.ps.InFrontOfTarget = owner.ps.InFrontOfTarget
  -- racials.go: an Orc's pets deal 5% more damage (Command)
  if owner.race == "Orc" then pet.ps.DamageDealtMultiplier = pet.ps.DamageDealtMultiplier * 1.05 end
  local target = owner.currentTarget
  pet.currentTarget = target
  pet.attackTables[target] = S.NewAttackTable(pet, target)
  if cfg.mainHand then
    pet:EnableAutoAttacks({ mainHand = cfg.mainHand, autoSwingMelee = true })
    pet.autoAttacks.randomMeleeOffset = false
  end
  pet.customRotation = cfg.rotation
  pet.rotation = setmetatable({ unit = pet }, PR)
  pet.rotationAction = { prio = S.PRIO_GCD, isRotation = true, fn = function(sim)
    S.CompleteDueHardcast(pet, sim)
    pet.rotation:DoNextAction(sim)
  end }
  owner.pets = owner.pets or {}
  owner.pets[#owner.pets + 1] = pet
  return pet
end

-- Spells register their metrics under the owner, prefixed (the pet's metricsKey or id).
local Unit = S.UnitMT
local baseRegister = Unit.RegisterSpell
function Unit:RegisterSpell(cfg)
  if self.isPet then
    cfg.metricsKey = self.metricsPrefix .. tostring(cfg.metricsKey or cfg.id)
  end
  return baseRegister(self, cfg)
end

-- pet.go Enable: stats from the owner, full mana, the GCD loop and auto attacks start.
function Unit:EnablePet(sim)
  if self.enabled then return end
  local o = self.owner
  local inh = self.inherit and self.inherit(o.stats) or {}
  local bonus = {}
  for k, v in pairs(inh) do bonus[k] = v; self.inherited[k] = (self.inherited[k] or 0) + v end
  self:AddStatsDynamic(sim, bonus)
  if self.hasMana then self.mana = self.stats[ST.Mana] end
  self.enabled = true
  if self.onEnable then self.onEnable(sim, self) end
  self:SetGCDTimer(sim, max(0, sim.now))
  local aa = self.autoAttacks
  if aa then
    -- attack.go EnableMeleeSwing: not before now, but a later swing time (onEnable) stands
    aa.mh.swingAt = max(aa.mh.swingAt, sim.now, 0)
    aa:StartPull(sim)
  end
end

function Unit:EnablePetWithTimeout(sim, duration)
  self:EnablePet(sim)
  if self.timeoutAction and not self.timeoutAction.consumed then sim:Cancel(self.timeoutAction) end
  local pet = self
  self.timeoutAction = sim:At(sim.now + duration, S.PRIO_LOW, function(s) pet:DisablePet(s) end)
end

-- pet.go Disable: inherited stats back off, the GCD loop and swings stop, its auras end.
function Unit:DisablePet(sim)
  if not self.enabled then return end
  local back = {}
  for k, v in pairs(self.inherited) do if v ~= 0 then back[k] = -v end end
  self:AddStatsDynamic(sim, back)
  for k in pairs(self.inherited) do self.inherited[k] = 0 end
  -- pet.go Disable: OnPetDisable runs with the owner's share gone, before the pet's own auras end
  if self.onDisable then self.onDisable(sim, self) end
  if self.rotationAction.queuedIn and not self.rotationAction.consumed then sim:Cancel(self.rotationAction) end
  self.skipWake = nil
  local aa = self.autoAttacks
  if aa then
    aa.mh.enabled, aa.oh.enabled = false, false
    sim:RemoveWeaponAttack(aa.mh)
    sim:RemoveWeaponAttack(aa.oh)
  end
  self.hardcastExpires = -huge
  self.hardcastComplete = nil
  self.enabled = false
  if self.timeoutAction and not self.timeoutAction.consumed then sim:Cancel(self.timeoutAction) end
  -- auraTracker.expireAll: the auras with a duration; permanent ones (buffs) stay
  local list = self.activeAuras
  while #list > 0 do
    local a, n = list[1], #list
    a:Deactivate(sim)
    if #list == n and list[1] == a then table.remove(list, 1) end
  end
end

-- Pets reset with their owner (pet.go reset: disabled until summoned).
function S.ResetPets(owner, sim)
  for _, pet in ipairs(owner.pets or {}) do
    local m = pet.metrics
    pet.metrics = nil
    pet:Reset(sim)
    pet.metrics = m
    pet.enabled = false
    for k in pairs(pet.inherited) do pet.inherited[k] = 0 end
    pet.timeoutAction = nil
    -- pet.go reset: a pet out from the start (a warlock's demon) is summoned right away
    if pet.enabledOnStart then pet:EnablePet(sim) end
  end
end

function S.DonePets(owner, sim)
  for _, pet in ipairs(owner.pets or {}) do
    pet:DisablePet(sim)
    local m = pet.metrics
    pet.metrics = nil
    pet:DoneIteration(sim)
    pet.metrics = m
  end
end

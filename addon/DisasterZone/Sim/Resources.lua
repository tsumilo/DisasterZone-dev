if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/Resources.lua", ...) then return end -- DisasterZone: Sim/Resources.lua
-- ns.GearSim power bars other than mana: rage (rage.go). Spells name their cost with rageCost = { cost, refund }
-- (Spell.lua); gains wake the rotation the way WoWSims' AddRage does (ReactToEvent with the reaction time).
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

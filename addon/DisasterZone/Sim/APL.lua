if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/APL.lua", ...) then return end -- DisasterZone: Sim/APL.lua
-- ns.GearSim rotations: an interpreter for WoWSims action priority lists (apl.go and friends). The lists are
-- WoWSims' own JSON (ui/specs/*/apls/*.apl.json) turned into Lua tables by the dev kit, so a spec's rotation is
-- data, not code. Only the node kinds the shipped lists use are implemented; an unknown node is an error.
local _, ns = ...
local S = ns.GearSim

local huge, max, min = math.huge, math.max, math.min

local Rot = {}
Rot.__index = Rot

-- "11s" / ".4s" / "1.5" / "true" -> number or boolean
local function ParseConst(v)
  if v == "true" then return true elseif v == "false" then return false end
  if type(v) == "string" then
    local n = v:match("^(-?[%d%.]+)ms$")
    if n then return tonumber(n) / 1000 end
    n = v:match("^(-?[%d%.]+)s$")
    if n then return tonumber(n) end
    n = v:match("^(-?[%d%.]+)m$")
    if n then return tonumber(n) * 60 end
    return tonumber(v) or v
  end
  return v
end

local function Truthy(v) return v and v ~= 0 end

-- Compile a value node into function(sim) -> value.
function Rot:Value(node, vars)
  if node == nil then return nil end
  local u = self.unit
  if node.const then
    local c = ParseConst(node.const.val)
    return function() return c end
  elseif node.variableRef then
    local name = node.variableRef.name
    local v = (vars and vars[name]) or self.variables[name]
    if not v then error("APL: unknown variable " .. name) end
    return self:Value(v, vars)
  elseif node["and"] then
    local fs = {}
    for i, v in ipairs(node["and"].vals) do fs[i] = self:Value(v, vars) end
    return function(sim)
      for i = 1, #fs do if not Truthy(fs[i](sim)) then return false end end
      return true
    end
  elseif node["or"] then
    local fs = {}
    for i, v in ipairs(node["or"].vals) do fs[i] = self:Value(v, vars) end
    return function(sim)
      for i = 1, #fs do if Truthy(fs[i](sim)) then return true end end
      return false
    end
  elseif node["not"] then
    local f = self:Value(node["not"].val, vars)
    return function(sim) return not Truthy(f(sim)) end
  elseif node.cmp then
    local l, r, op = self:Value(node.cmp.lhs, vars), self:Value(node.cmp.rhs, vars), node.cmp.op
    if op == "OpGe" then return function(sim) return l(sim) >= r(sim) end
    elseif op == "OpGt" then return function(sim) return l(sim) > r(sim) end
    elseif op == "OpLe" then return function(sim) return l(sim) <= r(sim) end
    elseif op == "OpLt" then return function(sim) return l(sim) < r(sim) end
    elseif op == "OpEq" then return function(sim) return l(sim) == r(sim) end
    elseif op == "OpNe" then return function(sim) return l(sim) ~= r(sim) end end
    error("APL: cmp op " .. tostring(op))
  elseif node.math then
    local l, r, op = self:Value(node.math.lhs, vars), self:Value(node.math.rhs, vars), node.math.op
    if op == "OpAdd" then return function(sim) return l(sim) + r(sim) end
    elseif op == "OpSub" then return function(sim) return l(sim) - r(sim) end
    elseif op == "OpMul" then return function(sim) return l(sim) * r(sim) end
    elseif op == "OpDiv" then return function(sim) return l(sim) / r(sim) end end
    error("APL: math op " .. tostring(op))
  elseif node.currentTime then
    return function(sim) return sim.now end
  elseif node.remainingTime then
    return function(sim) return sim.duration - sim.now end
  elseif node.isExecutePhase then
    local th = node.isExecutePhase.threshold
    return function(sim)
      if th == "E20" then return sim:IsExecute20() elseif th == "E35" then return sim:IsExecute35() end
      return false
    end
  elseif node.auraIsActive or node.auraIsInactive then
    local cfg = node.auraIsActive or node.auraIsInactive
    local aura = self.resolveAura(cfg.auraId)
    local want = node.auraIsActive ~= nil
    if not aura then return function() return not want end end
    return function() return aura.active == want end
  elseif node.auraRemainingTime then
    local aura = self.resolveAura(node.auraRemainingTime.auraId)
    return function(sim) return aura and aura:RemainingDuration(sim) or 0 end
  elseif node.autoTimeToNext then
    local aa = u.autoAttacks
    return function(sim) return max(0, aa:NextAttackAt() - sim.now) end
  elseif node.autoTimeSinceLast then
    local aa = u.autoAttacks
    local t = node.autoTimeSinceLast.autoType
    return function(sim)
      local v = sim.now - aa.mh.previousSwing
      if t ~= "MainHandAuto" and aa.oh.enabled then v = min(v, sim.now - aa.oh.previousSwing) end
      return v
    end
  elseif node.gcdIsReady then
    return function(sim) return u.GCD.readyAt <= sim.now or (u.GCD.readyAt - sim.now) <= S.QUEUE_WINDOW end
  elseif node.gcdTimeToReady then
    return function(sim) return max(0, u.GCD.readyAt - sim.now) end
  elseif node.spellIsReady then
    local sp = self.resolveSpell(node.spellIsReady.spellId)
    return function(sim) return sp:IsReady(sim) or sp:TimeToReady(sim) <= S.QUEUE_WINDOW end
  elseif node.spellTimeToReady then
    local sp = self.resolveSpell(node.spellTimeToReady.spellId)
    return function(sim) return sp:TimeToReady(sim) end
  elseif node.spellGcdHastedDuration then
    local sp = self.resolveSpell(node.spellGcdHastedDuration.spellId)
    return function()
      if sp.ignoreHaste then return sp.gcd end
      return max(sp.gcdMin or S.GCD_MIN, S.RoundMs(u:ApplyCastSpeed(sp.gcd)))
    end
  elseif node.currentManaPercent then
    return function() return u.mana / u.stats[S.ST.Mana] end
  end
  local k = next(node)
  error("APL: value node not implemented: " .. tostring(k))
end

-- Compile an action: returns { ready = fn(sim) -> bool, exec = fn(sim) }.
function Rot:Action(node, vars)
  local cond = node.condition and self:Value(node.condition, vars)
  local impl
  if node.castSpell then
    local sp = self.resolveSpell(node.castSpell.spellId)
    if not sp then return nil end
    local u = self.unit
    impl = {
      ready = function(sim)
        local t = u.currentTarget
        return sp:CanCastOrQueue(sim, t) and (not S.has(sp.flags, S.F.MCD) or S.has(sp.flags, S.F.Reactive) or u.GCD.readyAt <= sim.now)
      end,
      exec = function(sim) sp:CastOrQueue(sim, u.currentTarget) end,
    }
    self.directSpells[sp] = true
  elseif node.groupReference then
    local g = self.groups[node.groupReference.groupName]
    if not g then error("APL: unknown group " .. node.groupReference.groupName) end
    local gv = {}
    if vars then for k, v in pairs(vars) do gv[k] = v end end
    for _, v in ipairs(node.groupReference.variables or {}) do gv[v.name] = v.value end
    for _, v in ipairs(g.variables or {}) do if gv[v.name] == nil then gv[v.name] = v.value end end
    local acts = {}
    for _, a in ipairs(g.actions) do
      local c = self:Action(a.action, gv)
      if c then acts[#acts + 1] = c end
    end
    impl = {
      ready = function(sim)
        for i = 1, #acts do if acts[i].ready(sim) then return true end end
        return false
      end,
      exec = function(sim)
        for i = 1, #acts do
          if acts[i].ready(sim) then return acts[i].exec(sim) end
        end
      end,
    }
  elseif node.autocastOtherCooldowns then
    local u = self.unit
    local nextMCD
    impl = {
      ready = function(sim)
        nextMCD = u:FirstReadyMCD(sim)
        if not nextMCD then return false end
        local gcdReady = u.GCD.readyAt <= sim.now
        return (gcdReady ~= (nextMCD.explosive == true)) or S.has(nextMCD.spell.flags, S.F.Reactive)
      end,
      exec = function(sim)
        u:TryActivateMCD(sim, nextMCD)
        u:UpdateMajorCooldowns()
      end,
    }
  else
    local k = next(node)
    if k == "condition" then k = next(node, k) end
    error("APL: action not implemented: " .. tostring(k))
  end
  if cond then
    local r = impl.ready
    return { ready = function(sim) return Truthy(cond(sim)) and r(sim) end, exec = impl.exec }
  end
  return impl
end

-- apl: the JSON table; resolveSpell({spellId, rank}) -> spell; resolveAura({spellId, rank}) -> aura
function S.NewRotation(unit, apl, resolveSpell, resolveAura)
  local rot = setmetatable({ unit = unit, resolveSpell = resolveSpell, resolveAura = resolveAura, variables = {},
    groups = {}, directSpells = {}, list = {} }, Rot)
  for _, v in ipairs(apl.valueVariables or {}) do rot.variables[v.name] = v.value end
  for _, g in ipairs(apl.groups or {}) do rot.groups[g.name] = g end
  for _, item in ipairs(apl.priorityList or {}) do
    if not item.hide then
      local a = rot:Action(item.action)
      if a then rot.list[#rot.list + 1] = a end
    end
  end
  rot.prepull = {}
  for _, item in ipairs(apl.prepullActions or {}) do
    if not item.hide then
      local a = rot:Action(item.action)
      if a then
        local at = ParseConst(item.doAtValue.const.val)
        rot.prepull[#rot.prepull + 1] = { at = at, action = a }
      end
    end
  end
  -- Spells cast by name in the list are no longer auto-used as major cooldowns (apl.go removeFromMajorCooldowns).
  if unit.majorCooldowns then
    local keep = {}
    for _, m in ipairs(unit.majorCooldowns) do
      if not rot.directSpells[m.spell] then keep[#keep + 1] = m end
    end
    unit.majorCooldowns = keep
  end
  unit.rotation = rot
  unit.rotationAction = { prio = S.PRIO_GCD, fn = function(sim)
    if sim.now < 0 then return end
    rot:DoNextAction(sim)
  end }
  return rot
end

function Rot:RegisterPrepull(sim)
  for _, p in ipairs(self.prepull) do
    local a = p.action
    sim:RegisterPrepullAction(p.at, function(s) a.exec(s) end)
  end
end

function Rot:Reset(sim)
  self.inLoop = false
end

-- apl.go DoNextAction: run every ready action in priority order until none is ready, then wait for the GCD or
-- the reaction time, whichever is later.
function Rot:DoNextAction(sim)
  if sim.now < 0 or self.inLoop then return end
  local u = self.unit
  if u.RotationTimer.readyAt > sim.now then return end
  self.inLoop = true
  local list = self.list
  local n = 0
  while true do
    local nextA
    for i = 1, #list do
      if list[i].ready(sim) then nextA = list[i]; break end
    end
    if not nextA then break end
    n = n + 1
    if n > 1000 then error("APL: infinite loop") end
    nextA.exec(sim)
  end
  self.inLoop = false
  if u.RotationTimer.readyAt <= sim.now then
    local t = max(sim.now + u.reactionTime, u.GCD.readyAt)
    u:WaitUntil(sim, t)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Major cooldowns (major_cooldown.go)
-- mcd = { spell, priority, explosive, shouldActivate(sim, unit) }
-- ---------------------------------------------------------------------------------------------------------------
local Unit = S.UnitMT

function Unit:AddMajorCooldown(mcd)
  self.majorCooldowns = self.majorCooldowns or {}
  mcd.priority = mcd.priority or 0
  mcd.spell.flags = mcd.spell.flags + ((S.has(mcd.spell.flags, S.F.APL)) and 0 or S.F.APL)
  if not S.has(mcd.spell.flags, S.F.MCD) then mcd.spell.flags = mcd.spell.flags + S.F.MCD end
  if mcd.reactive and not S.has(mcd.spell.flags, S.F.Reactive) then mcd.spell.flags = mcd.spell.flags + S.F.Reactive end
  self.majorCooldowns[#self.majorCooldowns + 1] = mcd
end

function Unit:UpdateMajorCooldowns()
  local list = self.majorCooldowns
  if not list or #list == 0 then self.mcdMinReady = huge; return end
  -- stable sort by ready time, then priority (higher first)
  for i = 2, #list do
    local x = list[i]
    local j = i - 1
    while j >= 1 do
      local y = list[j]
      local rx, ry = x.spell:ReadyAt(), y.spell:ReadyAt()
      if ry > rx or (ry == rx and y.priority < x.priority) then
        list[j + 1] = y
        j = j - 1
      else
        break
      end
    end
    list[j + 1] = x
  end
  self.mcdMinReady = list[1].spell:ReadyAt()
end

local function ShouldActivate(u, sim, m)
  if not m.spell:CanCast(sim, u.currentTarget) then return false end
  if m.shouldActivate then return m.shouldActivate(sim, u) end
  return true
end

function Unit:FirstReadyMCD(sim)
  if sim.now < (self.mcdMinReady or 0) then return nil end
  for _, m in ipairs(self.majorCooldowns or {}) do
    if m.spell:IsReady(sim) and ShouldActivate(self, sim, m) then return m end
  end
  return nil
end

function Unit:TryActivateMCD(sim, m)
  if ShouldActivate(self, sim, m) then
    if S.has(m.spell.flags, S.F.Helpful) then m.spell:Cast(sim, self) else m.spell:Cast(sim, self.currentTarget) end
    return true
  end
  return false
end

if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/APL.lua", ...) then return end -- DisasterZone: Sim/APL.lua
-- ns.GearSim rotations: an interpreter for WoWSims action priority lists (apl.go and friends). The lists are
-- WoWSims' own JSON (ui/specs/*/apls/*.apl.json) turned into Lua tables by the dev kit, so a spec's rotation is
-- data, not code. Only the node kinds the shipped lists use are implemented; an unknown node is an error.
--
-- Speed: WoWSims re-evaluates an idle rotation every reaction time (10 ms), ~5000 times a fight. Every compiled
-- node also reports when time alone could next change its value, so an idle rotation sleeps straight to the first
-- poll of that same 10 ms grid where something can change; any event in between wakes it at the next grid point
-- (Sim:Step). The polls that act are the ones WoWSims would act on.
local _, ns = ...
local S = ns.GearSim

local huge, max, min, ceil = math.huge, math.max, math.min, math.ceil
local EPS = 1e-9

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
local function NEVER() return huge end
local function ZERO() return 0 end
local function Future(t, now) if t > now then return t end return huge end

-- Node shapes:
--   number:  { num = true, v = fn(sim), slope = fn(sim), disc = fn(sim) }  value changes linearly with time at
--            `slope` until `disc` (the next pure-time discontinuity)
--   boolean: { v = fn(sim), next = fn(sim) }  earliest time > now at which time alone could flip it
local function Num(v, slope, disc) return { num = true, v = v, slope = slope or ZERO, disc = disc or NEVER } end
local function Bool(v, nextFn) return { v = v, next = nextFn or NEVER } end

function Rot:Value(node, vars)
  if node == nil then return nil end
  local u = self.unit
  if node.const then
    local c = ParseConst(node.const.val)
    if type(c) == "number" then return Num(function() return c end) end
    return Bool(function() return c end)
  elseif node.variableRef then
    local name = node.variableRef.name
    local v = (vars and vars[name]) or self.variables[name]
    if not v then error("APL: unknown variable " .. name) end
    return self:Value(v, vars)
  elseif node["and"] or node["or"] then
    local isAnd = node["and"] ~= nil
    local fs = {}
    for i, v in ipairs((node["and"] or node["or"]).vals) do fs[i] = self:Value(v, vars) end
    local n = #fs
    local v
    if isAnd then
      v = function(sim)
        for i = 1, n do if not Truthy(fs[i].v(sim)) then return false end end
        return true
      end
    else
      v = function(sim)
        for i = 1, n do if Truthy(fs[i].v(sim)) then return true end end
        return false
      end
    end
    return Bool(v, function(sim)
      local t = huge
      for i = 1, n do local x = fs[i].next(sim); if x < t then t = x end end
      return t
    end)
  elseif node["not"] then
    local f = self:Value(node["not"].val, vars)
    return Bool(function(sim) return not Truthy(f.v(sim)) end, f.next)
  elseif node.cmp then
    local L, R, op = self:Value(node.cmp.lhs, vars), self:Value(node.cmp.rhs, vars), node.cmp.op
    local l, r = L.v, R.v
    local v
    if op == "OpGe" then v = function(sim) return l(sim) >= r(sim) end
    elseif op == "OpGt" then v = function(sim) return l(sim) > r(sim) end
    elseif op == "OpLe" then v = function(sim) return l(sim) <= r(sim) end
    elseif op == "OpLt" then v = function(sim) return l(sim) < r(sim) end
    elseif op == "OpEq" then v = function(sim) return l(sim) == r(sim) end
    elseif op == "OpNe" then v = function(sim) return l(sim) ~= r(sim) end
    else error("APL: cmp op " .. tostring(op)) end
    if not (L.num and R.num) then return Bool(v, function(sim) return sim.now end) end
    return Bool(v, function(sim)
      local now = sim.now
      local t = min(L.disc(sim), R.disc(sim))
      local d = L.slope(sim) - R.slope(sim)
      if d ~= 0 then
        local tc = now + (r(sim) - l(sim)) / d
        if tc > now and tc - EPS < t then t = max(now, tc - EPS) end
      end
      return t
    end)
  elseif node.math then
    local L, R, op = self:Value(node.math.lhs, vars), self:Value(node.math.rhs, vars), node.math.op
    local l, r = L.v, R.v
    local disc = function(sim) return min(L.disc(sim), R.disc(sim)) end
    if op == "OpAdd" then
      return Num(function(sim) return l(sim) + r(sim) end, function(sim) return L.slope(sim) + R.slope(sim) end, disc)
    elseif op == "OpSub" then
      return Num(function(sim) return l(sim) - r(sim) end, function(sim) return L.slope(sim) - R.slope(sim) end, disc)
    elseif op == "OpMul" then
      -- linear only if one side is constant in time; otherwise re-check every poll
      return Num(function(sim) return l(sim) * r(sim) end,
        function(sim) return L.slope(sim) * r(sim) + R.slope(sim) * l(sim) end,
        function(sim) if L.slope(sim) ~= 0 and R.slope(sim) ~= 0 then return sim.now end return disc(sim) end)
    elseif op == "OpDiv" then
      return Num(function(sim) return l(sim) / r(sim) end,
        function(sim) return L.slope(sim) / r(sim) end,
        function(sim) if R.slope(sim) ~= 0 then return sim.now end return disc(sim) end)
    end
    error("APL: math op " .. tostring(op))
  elseif node.currentTime then
    return Num(function(sim) return sim.now end, function() return 1 end)
  elseif node.remainingTime then
    return Num(function(sim) return sim.duration - sim.now end, function() return -1 end)
  elseif node.isExecutePhase then
    local th = node.isExecutePhase.threshold
    -- phase changes are covered by sim.nextExecuteAt in the rotation's wake bound
    return Bool(function(sim)
      if th == "E20" then return sim:IsExecute20() elseif th == "E35" then return sim:IsExecute35() end
      return false
    end)
  elseif node.auraIsActive or node.auraIsInactive then
    -- expiries are covered by the aura trackers in the wake bound; gains come from events
    local cfg = node.auraIsActive or node.auraIsInactive
    local aura = self.resolveAura(cfg.auraId)
    local want = node.auraIsActive ~= nil
    if not aura then return Bool(function() return not want end) end
    return Bool(function() return aura.active == want end)
  elseif node.auraRemainingTime then
    local aura = self.resolveAura(node.auraRemainingTime.auraId)
    return Num(function(sim) return aura and aura:RemainingDuration(sim) or 0 end,
      function() return (aura and aura.active and aura.expires ~= huge) and -1 or 0 end,
      function(sim) return (aura and aura.active) and Future(aura.expires, sim.now) or huge end)
  elseif node.autoTimeToNext then
    local aa = u.autoAttacks
    return Num(function(sim) return max(0, aa:NextAttackAt() - sim.now) end,
      function(sim) return (aa:NextAttackAt() > sim.now) and -1 or 0 end,
      function(sim) return Future(aa:NextAttackAt(), sim.now) end)
  elseif node.autoTimeSinceLast then
    local aa = u.autoAttacks
    local t = node.autoTimeSinceLast.autoType
    return Num(function(sim)
      local v = sim.now - aa.mh.previousSwing
      if t ~= "MainHandAuto" and aa.oh.enabled then v = min(v, sim.now - aa.oh.previousSwing) end
      return v
    end, function() return 1 end)
  elseif node.gcdIsReady then
    return Bool(function(sim) return u.GCD.readyAt <= sim.now or (u.GCD.readyAt - sim.now) <= S.QUEUE_WINDOW end,
      function(sim) return Future(u.GCD.readyAt - S.QUEUE_WINDOW, sim.now) end)
  elseif node.gcdTimeToReady then
    return Num(function(sim) return max(0, u.GCD.readyAt - sim.now) end,
      function(sim) return (u.GCD.readyAt > sim.now) and -1 or 0 end,
      function(sim) return Future(u.GCD.readyAt, sim.now) end)
  elseif node.spellIsReady then
    local sp = self.resolveSpell(node.spellIsReady.spellId)
    return Bool(function(sim) return sp:IsReady(sim) or sp:TimeToReady(sim) <= S.QUEUE_WINDOW end,
      function(sim) return S.SpellNextReadyChange(sp, sim) end)
  elseif node.spellTimeToReady then
    local sp = self.resolveSpell(node.spellTimeToReady.spellId)
    return Num(function(sim) return sp:TimeToReady(sim) end,
      function(sim) return (sp:TimeToReady(sim) > 0) and -1 or 0 end,
      function(sim) return S.SpellNextReadyChange(sp, sim) end)
  elseif node.spellGcdHastedDuration then
    local sp = self.resolveSpell(node.spellGcdHastedDuration.spellId)
    return Num(function()
      if sp.ignoreHaste then return sp.gcd end
      return max(sp.gcdMin or S.GCD_MIN, S.RoundMs(u:ApplyCastSpeed(sp.gcd)))
    end)
  elseif node.currentManaPercent then
    return Num(function() return u.mana / u.stats[S.ST.Mana] end)
  end
  local k = next(node)
  error("APL: value node not implemented: " .. tostring(k))
end

-- The times at which time alone changes a spell's cooldown readiness (own / shared timer, with and without the
-- spell queue window).
-- (no closures here: these run on every idle evaluation)
local QW = S.QUEUE_WINDOW
function S.SpellNextReadyChange(sp, sim)
  local now, t = sim.now, huge
  local tm = sp.cdTimer
  if tm then
    local x = tm.readyAt
    if x > now and x < t then t = x end
    x = x - QW
    if x > now and x < t then t = x end
  end
  tm = sp.sharedCdTimer
  if tm then
    local x = tm.readyAt
    if x > now and x < t then t = x end
    x = x - QW
    if x > now and x < t then t = x end
  end
  return t
end

local function CastNextChange(sp, u, sim, usesGcd)
  local now = sim.now
  local t = S.SpellNextReadyChange(sp, sim)
  if usesGcd then
    local x = u.GCD.readyAt
    if x > now and x < t then t = x end
    x = x - QW
    if x > now and x < t then t = x end
  end
  local x = u.hardcastExpires
  if x > now and x < t then t = x end
  return t
end

-- Compile an action: returns { ready = fn(sim) -> bool, exec = fn(sim), next = fn(sim) }.
function Rot:Action(node, vars)
  local cond = node.condition and self:Value(node.condition, vars)
  local impl
  if node.castSpell then
    local sp = self.resolveSpell(node.castSpell.spellId)
    if not sp then return nil end
    local u = self.unit
    local isMCD = S.has(sp.flags, S.F.MCD) and not S.has(sp.flags, S.F.Reactive)
    local usesGcd = sp.gcd > 0 or S.has(sp.flags, S.F.MCD)
    impl = {
      ready = function(sim)
        local t = u.currentTarget
        return sp:CanCastOrQueue(sim, t) and (not isMCD or u.GCD.readyAt <= sim.now)
      end,
      exec = function(sim) sp:CastOrQueue(sim, u.currentTarget) end,
      next = function(sim) return CastNextChange(sp, u, sim, usesGcd) end,
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
    local n = #acts
    impl = {
      ready = function(sim)
        for i = 1, n do if acts[i].ready(sim) then return true end end
        return false
      end,
      exec = function(sim)
        for i = 1, n do
          if acts[i].ready(sim) then return acts[i].exec(sim) end
        end
      end,
      next = function(sim)
        local t = huge
        for i = 1, n do local x = acts[i].next(sim); if x < t then t = x end end
        return t
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
      next = function(sim)
        local now = sim.now
        local t = huge
        local x = u.mcdMinReady or 0
        if x > now and x < t then t = x end
        x = u.GCD.readyAt
        if x > now and x < t then t = x end
        x = u.hardcastExpires
        if x > now and x < t then t = x end
        local list = u.majorCooldowns
        if list then
          for i = 1, #list do
            local sp = list[i].spell
            local tm = sp.cdTimer
            if tm then x = tm.readyAt; if x > now and x < t then t = x end end
            tm = sp.sharedCdTimer
            if tm then x = tm.readyAt; if x > now and x < t then t = x end end
          end
        end
        return t
      end,
    }
  else
    local k = next(node)
    if k == "condition" then k = next(node, k) end
    error("APL: action not implemented: " .. tostring(k))
  end
  if cond then
    local r, cv, cn, inext = impl.ready, cond.v, cond.next, impl.next
    return {
      ready = function(sim) return Truthy(cv(sim)) and r(sim) end,
      exec = impl.exec,
      next = function(sim)
        local a, b = cn(sim), inext(sim)
        return (a < b) and a or b
      end,
    }
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
  unit.rotationAction = { prio = S.PRIO_GCD, isRotation = true, fn = function(sim)
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
  self.unit.skipWake = nil
end

-- Earliest time at which time alone could make any action ready (or change what the tracked auras, execute phase
-- or cast in progress are).
function Rot:NextChange(sim)
  local t = huge
  local list = self.list
  for i = 1, #list do
    local x = list[i].next(sim)
    if x < t then t = x end
  end
  if sim.minTrackerTime < t then t = sim.minTrackerTime end
  if sim.nextExecuteAt < t then t = sim.nextExecuteAt end
  return t
end

-- apl.go DoNextAction: run every ready action in priority order until none is ready, then wait for the GCD or
-- the reaction time, whichever is later.
function Rot:DoNextAction(sim)
  if sim.now < 0 or self.inLoop then return end
  local u = self.unit
  if u.RotationTimer.readyAt > sim.now then return end
  u.skipWake = nil
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
    local rt = u.reactionTime
    local target = max(sim.now + rt, u.GCD.readyAt)
    local bound = (not S.NO_SKIP) and self:NextChange(sim) or 0
    if bound > target then
      -- Sleep to the first poll of WoWSims' grid (target + k * reaction time) at or after the bound.
      local k = ceil((bound - target) / rt - EPS)
      local wake = target + k * rt
      if wake > sim.duration + 1 then wake = sim.duration + 1 end
      u.skipOrigin, u.skipWake = target, wake
      u:WaitUntil(sim, wake)
    else
      u:WaitUntil(sim, target)
    end
  end
end

-- Called by Sim:Step before any event at time `at` with priority `prio` (weapon swings: huge): a sleeping
-- rotation wakes at the first grid poll that WoWSims would have run after the event.
function S.WakeSleepingRotation(sim, u, at, prio)
  local origin, rt = u.skipOrigin, u.reactionTime
  local k = ceil((at - origin) / rt - EPS)
  if k < 0 then k = 0 end
  local p = origin + k * rt
  -- An event at exactly a poll time runs before the poll unless it has a lower priority than the rotation.
  if p - at < EPS and at - p < EPS and prio < S.PRIO_GCD then p = p + rt end
  if p < u.skipWake then
    u.skipWake = p
    u:SetRotationTimer(sim, p)
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
  if not S.has(mcd.spell.flags, S.F.APL) then mcd.spell.flags = mcd.spell.flags + S.F.APL end
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

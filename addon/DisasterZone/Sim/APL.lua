if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/APL.lua", ...) then return end -- DisasterZone: Sim/APL.lua
-- ns.GearSim rotations: an interpreter for WoWSims action priority lists (apl.go and friends). The lists are
-- WoWSims' own JSON (ui/specs/*/apls/*.apl.json) turned into Lua tables by the dev kit, so a spec's rotation is
-- data, not code. Only the node kinds the shipped lists use are implemented; an unknown node is an error. Values
-- and actions that name something the character doesn't have are dropped the way WoWSims' builder drops them.
--
-- Speed: WoWSims re-evaluates an idle rotation every reaction time (10 ms), ~5000 times a fight. Every compiled
-- node also reports when time alone could next change its value, so an idle rotation sleeps straight to the first
-- poll of that same 10 ms grid where something can change; any event in between wakes it at the next grid point
-- (Sim:Step). The polls that act are the ones WoWSims would act on.
local _, ns = ...
local S = ns.GearSim

local huge, max, min, ceil, floor = math.huge, math.max, math.min, math.ceil, math.floor
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

local function ConstBool(c)
  local n = Bool(function() return c end)
  n.isConst, n.const = true, c
  return n
end
local function ConstNum(c)
  local n = Num(function() return c end)
  n.isConst, n.const = true, c
  return n
end

-- apl_helpers.go getUnit: the aura's owner (Self by default, or the current target)
function Rot:SourceUnit(ref)
  if ref and ref.type == "CurrentTarget" then return self.unit.currentTarget end
  return self.unit
end

-- Stack counts as the rotation saw them a reaction time ago (APLValueAuraNumStacks stack history)
local function StackHistory(aura, rt)
  if aura.stackHistory then return aura.stackHistory end
  local h = { updateAt = huge, stacks = 0, previous = 0 }
  aura.stackHistory = h
  local osc, ore = aura.onStacksChange, aura.onReset
  aura.onStacksChange = function(a, sim, old, new)
    if osc then osc(a, sim, old, new) end
    if sim.now - h.updateAt >= rt then h.previous = old end
    h.updateAt = sim.now
    h.stacks = new
  end
  aura.onReset = function(a, sim)
    if ore then ore(a, sim) end
    h.updateAt = huge
    h.previous = a.stacks
    h.stacks = a.stacks
  end
  return h
end

-- Compile a value node. Returns nil where WoWSims' builder does (an unknown aura or spell, a missing variable):
-- and / or drop nil children, not / cmp / math of nil are nil, and an action whose condition is nil has none.
function Rot:Value(node, vars)
  if node == nil then return nil end
  local u = self.unit
  if node.const then
    local c = ParseConst(node.const.val)
    if type(c) == "number" then return ConstNum(c) end
    if type(c) == "boolean" then return ConstBool(c) end
    return nil
  elseif node.variableRef then
    local name = node.variableRef.name
    local v = (vars and vars[name]) or self.variables[name]
    if not v then return nil end
    return self:Value(v, vars)
  elseif node["and"] or node["or"] then
    local isAnd = node["and"] ~= nil
    local fs = {}
    for _, v in ipairs((node["and"] or node["or"]).vals or {}) do
      local c = self:Value(v, vars)
      if c then fs[#fs + 1] = c end
    end
    local n = #fs
    if n == 0 then return nil end
    if n == 1 then return fs[1] end
    for i = 1, n do
      if fs[i].isConst and type(fs[i].const) == "boolean" and fs[i].const == not isAnd then return ConstBool(not isAnd) end
    end
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
    if not f then return nil end
    if f.isConst and type(f.const) == "boolean" then return ConstBool(not f.const) end
    return Bool(function(sim) return not Truthy(f.v(sim)) end, f.next)
  elseif node.cmp then
    local L, R, op = self:Value(node.cmp.lhs, vars), self:Value(node.cmp.rhs, vars), node.cmp.op
    if not (L and R) then return nil end
    if (not L.num) and op ~= "OpEq" and op ~= "OpNe" then return nil end
    local l, r = L.v, R.v
    local v
    if op == "OpGe" then v = function(sim) return l(sim) >= r(sim) end
    elseif op == "OpGt" then v = function(sim) return l(sim) > r(sim) end
    elseif op == "OpLe" then v = function(sim) return l(sim) <= r(sim) end
    elseif op == "OpLt" then v = function(sim) return l(sim) < r(sim) end
    elseif op == "OpEq" then v = function(sim) return l(sim) == r(sim) end
    elseif op == "OpNe" then v = function(sim) return l(sim) ~= r(sim) end
    else error("APL: cmp op " .. tostring(op)) end
    if not (L.num and R.num) then
      return Bool(v, function(sim) return min(L.next and L.next(sim) or sim.now, R.next and R.next(sim) or sim.now) end)
    end
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
    if not (L and R) or not (L.num and R.num) then return nil end
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
  elseif node.numberTargets then
    return ConstNum(1)
  elseif node.inputDelay then
    return ConstNum(u.reactionTime)
  elseif node.actionGroupUsed then
    return ConstBool(self.usedGroups[node.actionGroupUsed.name] == true)
  elseif node.auraIsKnown then
    local cfg = node.auraIsKnown
    return ConstBool(self.resolveAura(cfg.auraId, self:SourceUnit(cfg.sourceUnit)) ~= nil)
  elseif node.auraIsActive or node.auraIsInactive then
    -- expiries are covered by the aura trackers in the wake bound; gains come from events
    local cfg = node.auraIsActive or node.auraIsInactive
    local aura = self.resolveAura(cfg.auraId, self:SourceUnit(cfg.sourceUnit))
    if not aura then return nil end
    local want = node.auraIsActive ~= nil
    if cfg.includeReactionTime then
      local rt = u.reactionTime
      local function on(sim) return aura.active and sim.now - aura.startTime >= rt end
      local nf = function(sim)
        if aura.active then return Future(aura.startTime + rt, sim.now) end
        return huge
      end
      if want then return Bool(on, nf) end
      return Bool(function(sim) return not on(sim) end, nf)
    end
    return Bool(function() return aura.active == want end)
  elseif node.auraRemainingTime then
    local cfg = node.auraRemainingTime
    local aura = self.resolveAura(cfg.auraId, self:SourceUnit(cfg.sourceUnit))
    if not aura then return nil end
    return Num(function(sim) return aura.active and aura:RemainingDuration(sim) or 0 end,
      function() return (aura.active and aura.expires ~= huge) and -1 or 0 end,
      function(sim) return aura.active and Future(aura.expires, sim.now) or huge end)
  elseif node.auraNumStacks then
    local cfg = node.auraNumStacks
    local aura = self.resolveAura(cfg.auraId, self:SourceUnit(cfg.sourceUnit))
    if not aura or (aura.maxStacks or 0) == 0 then return nil end
    local rt = u.reactionTime
    local h = StackHistory(aura, rt)
    if cfg.includeReactionTime then
      return Num(function(sim) if sim.now - h.updateAt >= rt then return h.stacks end return h.previous end,
        ZERO, function(sim) return Future(h.updateAt + rt, sim.now) end)
    end
    return Num(function() return h.stacks end)
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
  elseif node.autoSwingTime then
    local aa = u.autoAttacks
    local t = node.autoSwingTime.autoType
    return Num(function()
      if t == "MainHand" then return max(0, aa.mh.curSwingDuration) end
      if t == "OffHand" then return max(0, aa.oh.curSwingDuration) end
      return 0
    end)
  elseif node.gcdIsReady then
    return Bool(function(sim) return u.GCD.readyAt <= sim.now or (u.GCD.readyAt - sim.now) <= S.QUEUE_WINDOW end,
      function(sim) return Future(u.GCD.readyAt - S.QUEUE_WINDOW, sim.now) end)
  elseif node.gcdTimeToReady then
    return Num(function(sim) return max(0, u.GCD.readyAt - sim.now) end,
      function(sim) return (u.GCD.readyAt > sim.now) and -1 or 0 end,
      function(sim) return Future(u.GCD.readyAt, sim.now) end)
  elseif node.spellIsReady then
    local sp = self.resolveSpell(node.spellIsReady.spellId)
    if not sp then return nil end
    return Bool(function(sim) return sp:IsReady(sim) or sp:TimeToReady(sim) <= S.QUEUE_WINDOW end,
      function(sim) return S.SpellNextReadyChange(sp, sim) end)
  elseif node.spellTimeToReady then
    local sp = self.resolveSpell(node.spellTimeToReady.spellId)
    if not sp then return nil end
    return Num(function(sim) return sp:TimeToReady(sim) end,
      function(sim) return (sp:TimeToReady(sim) > 0) and -1 or 0 end,
      function(sim) return S.SpellNextReadyChange(sp, sim) end)
  elseif node.spellGcdHastedDuration then
    local sp = self.resolveSpell(node.spellGcdHastedDuration.spellId)
    if not sp then return nil end
    return Num(function()
      if sp.ignoreHaste then return sp.gcd end
      return max(sp.gcdMin or S.GCD_MIN, S.RoundMs(u:ApplyCastSpeed(sp.gcd)))
    end)
  elseif node.spellCastTime then
    -- spell.go default castTimeFn: ApplyCastSpeedForSpell (haste changes come with events)
    local sp = self.resolveSpell(node.spellCastTime.spellId)
    if not sp then return nil end
    return Num(function() return sp.castTime * u.castSpeed * (sp.castTimeMultiplier or 1) end)
  elseif node.currentManaPercent then
    return Num(function() return u.mana / u.stats[S.ST.Mana] end)
  elseif node.currentMana then
    return Num(function() return u.mana end)
  elseif node.currentRage then
    -- rage changes only through events, which wake the rotation
    return Num(function() return u.rage end)
  elseif node.multipleCdUsages then
    return self:MultipleCdUsages(node.multipleCdUsages, vars)
  end
  local k = next(node)
  error("APL: value node not implemented: " .. tostring(k))
end

-- apl_values_misc.go APLValueMultipleCdUsages: use a cooldown now, or hold it for the base spell (Bloodlust) so
-- both line up, without losing a use over the fight.
function Rot:MultipleCdUsages(cfg, vars)
  local target = self.resolveSpell(cfg.targetSpellId)
  if not target or not target.relatedSelfBuff then return nil end
  local base = cfg.baseSpellId and self.resolveSpell(cfg.baseSpellId) or nil
  if base and not base.relatedSelfBuff then base = nil end
  local off = cfg.offset and self:Value(cfg.offset, vars) or nil
  local offset = off and off.v or ZERO
  local align = cfg.alignCdEnd
  local tCd = target.cdDuration or 0
  local tDur = target.relatedSelfBuff.duration
  local tEff = tCd + tDur
  local v = function(sim)
    local total = sim.duration
    local remaining = total - sim.now
    local castOffset = offset(sim)
    local maxUses = 1 + floor(total / tCd)
    local fullAtEnd = remaining <= tDur
    local secondUptime = remaining >= tEff
    if not base then
      if align then return fullAtEnd or secondUptime end
      return true
    end
    local bAura = base.relatedSelfBuff
    local bReady = (not base.cdTimer) or base.cdTimer.readyAt <= sim.now
    local activeAndCast = bAura.active and sim.now >= castOffset
    local loseUses = bReady and ((maxUses - 1) * tCd + tDur + castOffset > total)
    local castAndAgain = (not bReady) and secondUptime
    local activeAtEnd = castOffset + bAura.duration >= total
    local exceeds = bAura.duration >= remaining - tDur
    if align then
      if maxUses == 1 then
        return fullAtEnd or (activeAtEnd and activeAndCast and not exceeds) or ((not activeAtEnd) and activeAndCast)
      end
      return fullAtEnd or activeAndCast or loseUses or castAndAgain
    end
    return activeAndCast or castAndAgain or loseUses or ((not bReady) and target:IsReady(sim))
  end
  return Bool(v, function(sim)
    local now, t = sim.now, huge
    local total = sim.duration
    local x = Future(total - tDur, now); if x < t then t = x end
    x = Future(total - tEff, now); if x < t then t = x end
    x = Future(offset(sim), now); if x < t then t = x end
    if base and base.cdTimer then x = Future(base.cdTimer.readyAt, now); if x < t then t = x end end
    x = S.SpellNextReadyChange(target, sim); if x < t then t = x end
    return t
  end)
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

-- Compile an action: returns { ready = fn(sim) -> bool, exec = fn(sim), next = fn(sim) }, or nil where WoWSims drops
-- it (an unknown spell or group, an empty action, a condition that is always false).
function Rot:Action(node, vars)
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
      spell = sp,
    }
  elseif node.groupReference then
    local g = self.groups[node.groupReference.groupName]
    if not g then return nil end
    local gv = {}
    if vars then for k, v in pairs(vars) do gv[k] = v end end
    for _, v in ipairs(node.groupReference.variables or {}) do gv[v.name] = v.value end
    for _, v in ipairs(g.variables or {}) do if gv[v.name] == nil then gv[v.name] = v.value end end
    local acts = {}
    for _, a in ipairs(g.actions) do
      if not a.hide then
        local c = self:Action(a.action, gv)
        if c then acts[#acts + 1] = c end
      end
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
  elseif node.wait then
    -- apl_actions_timing.go APLActionWait: a controlling action; the list is not read again until it ends
    local d = self:Value(node.wait.duration, vars)
    if not d or not d.num then return nil end
    local dv, rot, u = d.v, self, self.unit
    impl = {
      ready = function(sim) return dv(sim) > 0 end,
      exec = function(sim)
        rot.waitUntil = sim.now + dv(sim)
        u:WaitUntil(sim, rot.waitUntil)
      end,
      next = function(sim)
        local t = d.disc(sim)
        local slope = d.slope(sim)
        if slope < 0 then
          local x = sim.now + dv(sim) / -slope
          if x > sim.now and x < t then t = x end
        end
        return t
      end,
    }
  else
    local k = next(node)
    if k == "condition" then k = next(node, k) end
    if k == nil then return nil end -- an empty action
    error("APL: action not implemented: " .. tostring(k))
  end
  local cond = node.condition and self:Value(node.condition, vars)
  if cond and cond.isConst then
    if not Truthy(cond.const) then
      -- never fires; its spell still leaves the auto-cast cooldowns (apl.go prunedActions)
      if impl.spell and self.markDirect then self.directSpells[impl.spell] = true end
      return nil
    end
    cond = nil
  end
  if impl.spell and self.markDirect then self.directSpells[impl.spell] = true end
  if cond then
    local r, cv, cn, inext = impl.ready, cond.v, cond.next or NEVER, impl.next
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

-- Groups referenced by a list or group action that is not hidden (APLValueActionGroupUsed).
local function UsedGroups(apl)
  local used = {}
  local function scan(items)
    for _, it in ipairs(items or {}) do
      if not it.hide and it.action and it.action.groupReference then used[it.action.groupReference.groupName] = true end
    end
  end
  scan(apl.priorityList)
  scan(apl.prepullActions)
  for _, g in ipairs(apl.groups or {}) do scan(g.actions) end
  return used
end

-- apl: the JSON table; resolveSpell(actionRef) -> spell; resolveAura(actionRef, sourceUnit) -> aura
function S.NewRotation(unit, apl, resolveSpell, resolveAura)
  local rot = setmetatable({ unit = unit, resolveSpell = resolveSpell, resolveAura = resolveAura, variables = {},
    groups = {}, directSpells = {}, list = {}, usedGroups = UsedGroups(apl) }, Rot)
  for _, v in ipairs(apl.valueVariables or {}) do rot.variables[v.name] = v.value end
  for _, g in ipairs(apl.groups or {}) do rot.groups[g.name] = g end
  rot.markDirect = true
  for _, item in ipairs(apl.priorityList or {}) do
    if not item.hide then
      local a = rot:Action(item.action)
      if a then rot.list[#rot.list + 1] = a end
    end
  end
  -- every group's spells leave the auto-cast cooldowns, referenced or not (apl.go allAPLActions)
  for _, g in ipairs(apl.groups or {}) do
    for _, a in ipairs(g.actions or {}) do
      if not a.hide then rot:Action(a.action, nil) end
    end
  end
  rot.markDirect = false
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
  self.waitUntil = nil
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
    -- a Wait in progress controls the list until it ends (apl.go controllingActions)
    if self.waitUntil then
      if sim.now < self.waitUntil then break end
      self.waitUntil = nil
    end
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

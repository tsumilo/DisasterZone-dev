-- wowmock/core.lua : environment, error capture, WoW Lua extensions, time, C_Timer, event registry.
-- Plain Lua 5.1. Loaded by mock.lua with (M, cfg, PY).
local M, cfg, PY = ...

local _G = _G
local type, tostring, tonumber, select, pairs, ipairs, next = type, tostring, tonumber, select, pairs, ipairs, next
local setmetatable, getmetatable, rawget, rawset, error, pcall, xpcall = setmetatable, getmetatable, rawget, rawset, error, pcall, xpcall
local unpack = unpack
local sformat, sgsub, sfind, ssub, sbyte, schar, srep, slower, supper, smatch =
      string.format, string.gsub, string.find, string.sub, string.byte, string.char, string.rep, string.lower, string.upper, string.match
local tinsert, tremove, tconcat, tsort = table.insert, table.remove, table.concat, table.sort
local traceback = debug.traceback
local os_time, os_date, os_clock, os_difftime = os.time, os.date, os.clock, os.difftime

---------------------------------------------------------------------------------------------------
-- Error capture: errors are NEVER swallowed; every dispatch goes through safecall -> M.errors
---------------------------------------------------------------------------------------------------
M.errors = {}
M.warnings = {}
M.warn_seen = {}

function M.record_error(msg, where, tb)
  local e = { where = where or "?", msg = tostring(msg), traceback = tb or traceback(tostring(msg), 3) }
  M.errors[#M.errors + 1] = e
  return e
end

function M.warn(msg)
  msg = tostring(msg)
  if M.warn_seen[msg] then return end
  M.warn_seen[msg] = true
  M.warnings[#M.warnings + 1] = msg
end

local handler_cache = {}
local function handler_for(where)
  local h = handler_cache[where]
  if not h then
    h = function(e)
      M.record_error(e, where, traceback(tostring(e), 2))
      return e
    end
    handler_cache[where] = h
  end
  return h
end
M.handler_for = handler_for

-- safecall(where, fn, ...) -> ok, results...
function M.safecall(where, fn, ...)
  local n = select("#", ...)
  if n == 0 then
    return xpcall(fn, handler_for(where))
  end
  local args = { ... }
  return xpcall(function() return fn(unpack(args, 1, n)) end, handler_for(where))
end
local safecall = M.safecall

-- WoW's global error handler (AceComm / CallbackHandler / ChatThrottleLib use it)
M.user_errorhandler = nil
M.errorhandler = function(e)
  M.record_error(e, "geterrorhandler()", traceback(tostring(e), 2))
  if M.user_errorhandler then pcall(M.user_errorhandler, e) end
  return e
end
function geterrorhandler() return M.errorhandler end
function seterrorhandler(fn)
  if type(fn) ~= "function" then error("Usage: seterrorhandler(errfunc)", 2) end
  M.user_errorhandler = fn
end

local function call_with_handler(fn, ...)
  local n = select("#", ...)
  local args = { ... }
  local res = { xpcall(function() return fn(unpack(args, 1, n)) end, M.errorhandler) }
  if res[1] then return unpack(res, 2, table.maxn(res)) end
end
function securecall(fn, ...)
  if type(fn) == "string" then fn = _G[fn] end
  if type(fn) ~= "function" then error("securecall: function expected", 2) end
  return call_with_handler(fn, ...)
end
function securecallfunction(fn, ...)
  if type(fn) ~= "function" then error("securecallfunction: function expected", 2) end
  return call_with_handler(fn, ...)
end
function secureexecuterange(tbl, fn, ...)
  for k, v in pairs(tbl) do call_with_handler(fn, k, v, ...) end
end
function issecurevariable(t, k) return true, nil end
function issecure() return false end
function forceinsecure() end
function scrub(...) return ... end

function hooksecurefunc(a, b, c)
  local tbl, name, hook
  if type(a) == "table" then tbl, name, hook = a, b, c else tbl, name, hook = _G, a, b end
  if type(name) ~= "string" or type(hook) ~= "function" then
    error("Usage: hooksecurefunc([table,] \"functionName\", hookfunc)", 2)
  end
  local orig = tbl[name]
  if type(orig) ~= "function" then
    error("hooksecurefunc(): " .. name .. " is not a function", 2)
  end
  local where = "hooksecurefunc:" .. name
  local function pack(...) return { n = select("#", ...), ... } end
  rawset(tbl, name, function(...)
    local r = pack(orig(...))
    safecall(where, hook, ...)
    return unpack(r, 1, r.n)
  end)
end

-- WoW's xpcall forwards extra arguments to the function (Lua 5.2 style); stock 5.1 does not.
local lua_xpcall = xpcall
_G.xpcall = function(f, handler, ...)
  local n = select("#", ...)
  if n == 0 then return lua_xpcall(f, handler) end
  local args = { ... }
  return lua_xpcall(function() return f(unpack(args, 1, n)) end, handler)
end

---------------------------------------------------------------------------------------------------
-- Sandbox: strip what WoW does not have; keep a virtualised os subset
---------------------------------------------------------------------------------------------------
M.real_os = os
M.real_io = io
io = nil
require = nil
dofile = nil
loadfile = nil
module = nil
package = nil
python = nil
arg = nil

---------------------------------------------------------------------------------------------------
-- Time (virtual clock driven by Python)
---------------------------------------------------------------------------------------------------
M.now = tonumber(cfg.time_offset) or 1000.0   -- GetTime()
M.boot = M.now
M.server_time = tonumber(cfg.server_time) or 1790000000
function GetTime() return M.now end
function GetTimePreciseSec() return M.now end
function GetServerTime() return math.floor(M.server_time) end
-- seconds until the daily quest reset (03:00 UTC, like EU realms)
function GetQuestResetTime()
  local left = (3 * 3600 - math.floor(M.server_time) % 86400) % 86400
  if left == 0 then left = 86400 end
  return left
end
function debugprofilestop() return (M.now - M.boot) * 1000 end
function debugprofilestart() end
function GetFramerate() return 60 end
function GetNetStats() return 0, 0, 30, 30 end
function GetSessionTime() return math.floor(M.now - M.boot) end
function time(t)
  if t ~= nil then return os_time(t) end
  return math.floor(M.server_time)
end
function date(fmt, t) return os_date(fmt, t or math.floor(M.server_time)) end
function difftime(a, b) return os_difftime(a, b) end
os = {
  time = time,
  date = date,
  clock = function() return M.now - M.boot end,
  difftime = difftime,
}
function GetGameTime()
  local t = os_date("*t", math.floor(M.server_time))
  return t.hour, t.min
end
C_DateAndTime = {
  GetServerTimeLocal = function() return math.floor(M.server_time) end,
  GetCurrentCalendarTime = function()
    local t = os_date("*t", math.floor(M.server_time))
    return { year = t.year, month = t.month, monthDay = t.day, weekday = t.wday, hour = t.hour, minute = t.min }
  end,
  GetSecondsUntilDailyReset = function() return 3600 end,
  GetSecondsUntilWeeklyReset = function() return 86400 end,
}

---------------------------------------------------------------------------------------------------
-- WoW Lua extensions (strings, tables, math, bit)
---------------------------------------------------------------------------------------------------
local lua_format = string.format
-- WoW's string.format supports positional arguments ("%2$s")
local function wow_format(fmt, ...)
  if type(fmt) == "string" and sfind(fmt, "%%%d+%$") then
    local n = select("#", ...)
    local args = { ... }
    local out, cnt = {}, 0
    local newfmt = sgsub(fmt, "%%(%d+)%$", function(i)
      cnt = cnt + 1
      out[cnt] = args[tonumber(i)]
      return "%"
    end)
    return lua_format(newfmt, unpack(out, 1, cnt))
  end
  return lua_format(fmt, ...)
end
string.format = wow_format
format = wow_format

local function escape_class(s) return (sgsub(s, "[%]%[%^%-%%]", "%%%0")) end

function strsplit(delim, str, pieces)
  if type(delim) ~= "string" then error("bad argument #1 to 'strsplit' (string expected, got " .. type(delim) .. ")", 2) end
  if type(str) == "number" then str = tostring(str) end
  if type(str) ~= "string" then error("bad argument #2 to 'strsplit' (string expected, got " .. type(str) .. ")", 2) end
  local out, n, pos = {}, 0, 1
  local pat = "[" .. escape_class(delim) .. "]"
  pieces = tonumber(pieces)
  while true do
    if pieces and n >= pieces - 1 then break end
    local s, e = sfind(str, pat, pos)
    if not s then break end
    n = n + 1
    out[n] = ssub(str, pos, s - 1)
    pos = e + 1
  end
  n = n + 1
  out[n] = ssub(str, pos)
  return unpack(out, 1, n)
end
function strsplittable(delim, str, pieces) return { strsplit(delim, str, pieces) } end
function strjoin(delim, ...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do
    local v = select(i, ...)
    if type(v) ~= "string" and type(v) ~= "number" then
      error("bad argument #" .. (i + 1) .. " to 'strjoin' (string expected, got " .. type(v) .. ")", 2)
    end
    t[i] = v
  end
  return tconcat(t, delim)
end
function strtrim(str, chars)
  if type(str) ~= "string" then error("bad argument #1 to 'strtrim' (string expected, got " .. type(str) .. ")", 2) end
  if chars then
    local c = escape_class(chars)
    return (sgsub(sgsub(str, "^[" .. c .. "]+", ""), "[" .. c .. "]+$", ""))
  end
  return (sgsub(sgsub(str, "^[ \t\r\n]+", ""), "[ \t\r\n]+$", ""))
end
function strconcat(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  return tconcat(t)
end
function strlenutf8(s)
  local _, n = sgsub(s, "[^\128-\191]", "")
  return n
end
function strcmputf8i(a, b)
  a, b = slower(a), slower(b)
  if a == b then return 0 elseif a < b then return -1 else return 1 end
end
function tostringall(...)
  local n = select("#", ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  return unpack(t, 1, n)
end
string.join = strjoin
string.split = strsplit
string.trim = strtrim
strlen, strlower, strupper, strsub, strbyte, strchar, strrep, strrev =
  string.len, string.lower, string.upper, string.sub, string.byte, string.char, string.rep, string.reverse
strfind, strmatch, gsub, gmatch = string.find, string.match, string.gsub, string.gmatch

function wipe(t)
  if type(t) ~= "table" then error("bad argument #1 to 'wipe' (table expected, got " .. type(t) .. ")", 2) end
  for k in pairs(t) do t[k] = nil end
  return t
end
table.wipe = wipe
_G.tinsert, _G.tremove, _G.sort, _G.getn = table.insert, table.remove, table.sort, table.getn
foreach, foreachi = table.foreach, table.foreachi
function tContains(t, v) for _, x in pairs(t) do if x == v then return true end end return false end
function tInvert(t) local r = {} for k, v in pairs(t) do r[v] = k end return r end
function tIndexOf(t, v) for i = 1, #t do if t[i] == v then return i end end return nil end
function tDeleteItem(t, v)
  local i = 1
  while t[i] do if t[i] == v then tremove(t, i) else i = i + 1 end end
end
function tAppendAll(t, src) for i = 1, #src do t[#t + 1] = src[i] end end
function tUnorderedRemove(t, i) t[i] = t[#t]; t[#t] = nil end
function tFilter(t, pred, isIndexTable)
  local out = {}
  if isIndexTable then for i = 1, #t do if pred(t[i]) then out[#out + 1] = t[i] end end
  else for k, v in pairs(t) do if pred(v) then out[k] = v end end end
  return out
end
function CopyTable(settings, shallow)
  local copy = {}
  for k, v in pairs(settings) do
    if type(v) == "table" and not shallow then copy[k] = CopyTable(v) else copy[k] = v end
  end
  return copy
end
function GetKeysArray(t) local r = {} for k in pairs(t) do r[#r + 1] = k end return r end
function GetValuesArray(t) local r = {} for _, v in pairs(t) do r[#r + 1] = v end return r end
function GetPairsArray(t) local r = {} for k, v in pairs(t) do r[#r + 1] = { key = k, value = v } end return r end
function SafePack(...) return { n = select("#", ...), ... } end
function SafeUnpack(t) return unpack(t, 1, t.n) end
function tCompare(a, b, depth)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not tCompare(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
TableUtil = {
  ContainsValue = tContains,
  CopyUnique = function(t) local r, s = {}, {} for _, v in ipairs(t) do if not s[v] then s[v] = true; r[#r + 1] = v end end return r end,
  Execute = function(t, fn) for _, v in pairs(t) do fn(v) end end,
  FindIndex = function(t, pred) for i, v in ipairs(t) do if pred(v) then return i end end end,
  GetRandomElement = function(t) return t[math.random(#t)] end,
  Transform = function(t, fn) local r = {} for k, v in pairs(t) do r[k] = fn(v) end return r end,
}

-- math: WoW globals, trig in DEGREES like the real client
local m = math
floor, ceil, abs, min, max, sqrt, exp, log, log10, frexp, ldexp, random =
  m.floor, m.ceil, m.abs, m.min, m.max, m.sqrt, m.exp, m.log, m.log10, m.frexp, m.ldexp, m.random
mod = m.fmod
deg, rad = m.deg, m.rad
function sin(x) return m.sin(m.rad(x)) end
function cos(x) return m.cos(m.rad(x)) end
function tan(x) return m.tan(m.rad(x)) end
function asin(x) return m.deg(m.asin(x)) end
function acos(x) return m.deg(m.acos(x)) end
function atan(x) return m.deg(m.atan(x)) end
function atan2(y, x) return m.deg(m.atan2(y, x)) end
fastrandom = m.random
PI = m.pi
function Round(v) if v < 0 then return m.ceil(v - 0.5) end return m.floor(v + 0.5) end
function Clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
function Saturate(v) return Clamp(v, 0, 1) end
function Lerp(a, b, t) return a + (b - a) * t end
function ClampedPercentageBetween(v, lo, hi) if hi == lo then return 0 end return Saturate((v - lo) / (hi - lo)) end
function PercentageBetween(v, lo, hi) if hi == lo then return 0 end return (v - lo) / (hi - lo) end
function WithinRange(v, lo, hi) return v >= lo and v <= hi end
function ApproximatelyEqual(a, b, eps) return abs(a - b) <= (eps or 0.00001) end

-- bit (32-bit, unsigned results like WoW's bitlib)
do
  local MOD = 4294967296
  local function norm(x) x = (tonumber(x) or 0) % MOD; if x < 0 then x = x + MOD end return m.floor(x) end
  local function bitop(a, b, fn)
    a, b = norm(a), norm(b)
    local r, p = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      if fn(x, y) then r = r + p end
      a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
  end
  bit = {}
  function bit.band(a, b, ...)
    local r = bitop(a, b, function(x, y) return x == 1 and y == 1 end)
    if ... then return bit.band(r, ...) end
    return r
  end
  function bit.bor(a, b, ...)
    local r = bitop(a, b or 0, function(x, y) return x == 1 or y == 1 end)
    if ... then return bit.bor(r, ...) end
    return r
  end
  function bit.bxor(a, b, ...)
    local r = bitop(a, b or 0, function(x, y) return x ~= y end)
    if ... then return bit.bxor(r, ...) end
    return r
  end
  function bit.bnot(a) return MOD - 1 - norm(a) end
  function bit.lshift(a, n) return norm(norm(a) * 2 ^ n) end
  function bit.rshift(a, n) return m.floor(norm(a) / 2 ^ n) end
  function bit.arshift(a, n)
    a = norm(a)
    local r = m.floor(a / 2 ^ n)
    if a >= 2147483648 then r = r + (MOD - 2 ^ (32 - n)) end
    return norm(r)
  end
  function bit.mod(a, b) return norm(a) % b end
  function bit.tobit(a) a = norm(a); if a >= 2147483648 then a = a - MOD end return a end
  function bit.tohex(a, n) return sformat("%0" .. (n or 8) .. "x", norm(a)) end
end

-- deterministic random per client
do
  local seed = 0
  local s = tostring(cfg.name or "x") .. tostring(cfg.realm or "")
  for i = 1, #s do seed = (seed * 31 + sbyte(s, i)) % 2147483647 end
  math.randomseed(seed)
end

---------------------------------------------------------------------------------------------------
-- debugstack / debuglocals
---------------------------------------------------------------------------------------------------
function debugstack(start, count1, count2)
  local tb = traceback("", (tonumber(start) or 1) + 1)
  return (sgsub(tb, "^\nstack traceback:\n", ""))
end
function debuglocals() return "" end

---------------------------------------------------------------------------------------------------
-- C_Timer
---------------------------------------------------------------------------------------------------
M.timers = {}
M.timer_seq = 0

local TimerMethods = {}
TimerMethods.__index = TimerMethods
function TimerMethods:Cancel() self._cancelled = true end
function TimerMethods:IsCancelled() return self._cancelled == true end
function TimerMethods:Invoke(...) if self._fn then self._fn(self, ...) end end

local function add_timer(delay, fn, handle, interval, iterations)
  M.timer_seq = M.timer_seq + 1
  local t = { at = M.now + delay, seq = M.timer_seq, fn = fn, handle = handle, interval = interval,
              iterations = iterations, where = "C_Timer" }
  M.timers[#M.timers + 1] = t
  return t
end

local function check_timer_args(name, seconds, fn)
  if type(seconds) ~= "number" or type(fn) ~= "function" then
    error("Usage: C_Timer." .. name .. "(seconds, callback" .. (name == "NewTicker" and "[, iterations]" or "") ..
          ") - got (" .. type(seconds) .. ", " .. type(fn) .. ")", 3)
  end
end

C_Timer = {}
function C_Timer.After(seconds, fn)
  check_timer_args("After", seconds, fn)
  add_timer(seconds, fn, nil)
end
function C_Timer.NewTimer(seconds, fn)
  check_timer_args("NewTimer", seconds, fn)
  local h = setmetatable({ _fn = fn }, TimerMethods)
  add_timer(seconds, fn, h)
  return h
end
function C_Timer.NewTicker(seconds, fn, iterations)
  check_timer_args("NewTicker", seconds, fn)
  local h = setmetatable({ _fn = fn, _remaining = iterations }, TimerMethods)
  add_timer(seconds, fn, h, seconds, iterations)
  return h
end

function M.run_timers()
  if #M.timers == 0 then return end
  local due, keep = {}, {}
  for _, t in ipairs(M.timers) do
    if t.handle and t.handle._cancelled then
      -- drop
    elseif t.at <= M.now + 1e-9 then
      due[#due + 1] = t
    else
      keep[#keep + 1] = t
    end
  end
  M.timers = keep
  tsort(due, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
  for _, t in ipairs(due) do
    if not (t.handle and t.handle._cancelled) then
      if t.handle then
        safecall(t.where, t.fn, t.handle)
      else
        safecall(t.where, t.fn)
      end
      if t.interval and not (t.handle and t.handle._cancelled) then
        local h = t.handle
        if h._remaining then h._remaining = h._remaining - 1 end
        if not h._remaining or h._remaining > 0 then
          t.at = t.at + math.max(t.interval, 0.001)
          M.timer_seq = M.timer_seq + 1
          t.seq = M.timer_seq
          M.timers[#M.timers + 1] = t
        end
      end
    end
  end
end

-- internal timers used by the mock itself (not visible as C_Timer)
M.internal = {}
function M.after(delay, fn, where)
  M.timer_seq = M.timer_seq + 1
  M.internal[#M.internal + 1] = { at = M.now + delay, seq = M.timer_seq, fn = fn, where = where or "mock" }
end
function M.run_internal()
  if #M.internal == 0 then return end
  local due, keep = {}, {}
  for _, t in ipairs(M.internal) do
    if t.at <= M.now + 1e-9 then due[#due + 1] = t else keep[#keep + 1] = t end
  end
  M.internal = keep
  tsort(due, function(a, b) if a.at == b.at then return a.seq < b.seq end return a.at < b.at end)
  for _, t in ipairs(due) do safecall(t.where, t.fn) end
end

---------------------------------------------------------------------------------------------------
-- Event registry (frames register; M.fire dispatches OnEvent in registration order)
---------------------------------------------------------------------------------------------------
M.event_frames = {}     -- event -> array of frames
M.all_event_frames = {} -- frames that called RegisterAllEvents
M.deferred = {}         -- events queued for the next step
M.known_events = {}     -- filled from known_globals.json (Python) + mock events
M.unknown_events = {}

function M.defer(event, ...)
  M.deferred[#M.deferred + 1] = { event = event, n = select("#", ...), ... }
end
function M.run_deferred()
  if #M.deferred == 0 then return end
  local list = M.deferred
  M.deferred = {}
  for _, d in ipairs(list) do M.fire(d.event, unpack(d, 1, d.n)) end
end

-- M.fire is defined in objects.lua (needs frame internals)

---------------------------------------------------------------------------------------------------
-- Serializer for SavedVariables (relog)
---------------------------------------------------------------------------------------------------
local function ser_string(s)
  return '"' .. sgsub(s, '[%c"\\\128-\255]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
    return sformat("\\%03d", sbyte(c))
  end) .. '"'
end
local function ser_number(v)
  if v ~= v then return "(0/0)" end
  if v == math.huge then return "math.huge" end
  if v == -math.huge then return "-math.huge" end
  if v == m.floor(v) and abs(v) < 2 ^ 53 then return sformat("%.0f", v) end
  return sformat("%.17g", v)
end
local ident_ok = {}
local reserved = {}
for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do reserved[w] = true end

function M.serialize(v, indent, stack, path)
  indent = indent or ""
  stack = stack or {}
  path = path or "value"
  local tv = type(v)
  if tv == "string" then return ser_string(v)
  elseif tv == "number" then return ser_number(v)
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "nil" then return "nil"
  elseif tv == "table" then
    if stack[v] then error("SavedVariables: recursive table at " .. path, 0) end
    stack[v] = true
    local keys = {}
    for k in pairs(v) do
      local tk = type(k)
      if tk == "string" or tk == "number" or tk == "boolean" then
        local tvv = type(v[k])
        if tvv == "string" or tvv == "number" or tvv == "boolean" or tvv == "table" then keys[#keys + 1] = k end
      end
    end
    tsort(keys, function(a, b)
      local ta, tb = type(a), type(b)
      if ta ~= tb then return ta < tb end
      if ta == "boolean" then return (a and 1 or 0) < (b and 1 or 0) end
      return a < b
    end)
    if #keys == 0 then stack[v] = nil; return "{}" end
    local inner = indent .. "  "
    local parts = {}
    for _, k in ipairs(keys) do
      local ks
      if type(k) == "string" and smatch(k, "^[%a_][%w_]*$") and not reserved[k] then ks = k
      else ks = "[" .. M.serialize(k, inner, stack, path) .. "]" end
      parts[#parts + 1] = inner .. ks .. " = " .. M.serialize(v[k], inner, stack, path .. "." .. tostring(k)) .. ","
    end
    stack[v] = nil
    return "{\n" .. tconcat(parts, "\n") .. "\n" .. indent .. "}"
  end
  return "nil"  -- functions/userdata/threads are not saved (like WoW)
end

---------------------------------------------------------------------------------------------------
-- helpers for Python <-> Lua binary-safe strings
---------------------------------------------------------------------------------------------------
function M.hex(s)
  return (sgsub(s, ".", function(c) return sformat("%02x", sbyte(c)) end))
end
-- valid UTF-8?
function M.is_utf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = sbyte(s, i)
    if c < 0x80 then i = i + 1
    else
      local len
      if c >= 0xC2 and c <= 0xDF then len = 2
      elseif c >= 0xE0 and c <= 0xEF then len = 3
      elseif c >= 0xF0 and c <= 0xF4 then len = 4
      else return false end
      if i + len - 1 > n then return false end
      for j = i + 1, i + len - 1 do
        local cc = sbyte(s, j)
        if cc < 0x80 or cc > 0xBF then return false end
      end
      i = i + len
    end
  end
  return true
end
function M.safe_str(s)
  s = tostring(s)
  if M.is_utf8(s) then return s end
  return (sgsub(s, "[\128-\255]", function(c) return sformat("\\x%02x", sbyte(c)) end))
end
-- deep export for Python: non-UTF-8 strings become {__bytes = hex}
function M.export(v, seen)
  local tv = type(v)
  if tv == "string" then
    if M.is_utf8(v) then return v end
    return { __bytes = M.hex(v) }
  elseif tv ~= "table" then
    if tv == "function" or tv == "userdata" or tv == "thread" then return "<" .. tv .. ">" end
    return v
  end
  seen = seen or {}
  if seen[v] then return "<cycle>" end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    local kk = k
    if type(k) == "string" and not M.is_utf8(k) then kk = "\\x" .. M.hex(k) end
    if type(k) == "table" or type(k) == "function" or type(k) == "userdata" then kk = tostring(k) end
    out[kk] = M.export(x, seen)
  end
  seen[v] = nil
  return out
end

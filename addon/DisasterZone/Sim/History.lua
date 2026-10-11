if DisasterZoneBoot and DisasterZoneBoot.Run("Sim/History.lua", ...) then return end -- DisasterZone: Sim/History.lua
-- ns.SimHistory: the gear sim's last runs, per character (DisasterZoneDB.simRuns[charKey], never synced).
--   * Runs: the MAX_RUNS latest runs of the Gear sim page (its Run), newest first: the Working set and the set it was
--     compared with, the settings and the numbers. The page lists them (UI/SimHistory.lua), opens one again and
--     compares two.
--   * Results: the summaries of the sets those runs simmed, by a hash of the set's cache key (Sim/Runner.lua CacheKey:
--     the spec, the fight count and the whole scenario with its seed), the fights' DPS packed in a string. ns.SimRunner
--     looks here after its own cache, so a set simmed in an earlier session is not simmed again: it re-sims the first
--     fights only and takes the stored result when they come out the same (an update that changes the numbers makes
--     them differ, and the set is simmed in full). Kept while a run in the list uses them.
--   * Seed: one per character, kept, so a set gets the same fights from session to session (and any two runs pair up:
--     fight i of every set has the same rolls).
local _, ns = ...

local H = {}
ns.SimHistory = H

H.MAX_RUNS = 10
H.CHECK_FIGHTS = 2      -- fights re-simmed before a stored result is used

local floor, abs = math.floor, math.abs

local function CharKey()
  local key = ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or (UnitName("player") or "me")
  return tostring(key)
end

-- This character's store (nil before anything was saved, unless create).
local function Root(create)
  local db = ns.db
  if type(db) ~= "table" then return nil end
  if type(db.simRuns) ~= "table" then
    if not create then return nil end
    db.simRuns = {}
  end
  local key = CharKey()
  local t = db.simRuns[key]
  if type(t) ~= "table" then
    if not create then return nil end
    t = {}
    db.simRuns[key] = t
  end
  if type(t.runs) ~= "table" then t.runs = {} end
  if type(t.results) ~= "table" then t.results = {} end
  t.nextId = tonumber(t.nextId) or 1
  return t
end

-- The seed every run of this character uses (made once, then kept).
function H:Seed()
  local t = Root(true)
  if not t then return nil end
  if type(t.seed) ~= "number" then
    t.seed = floor(((GetTime and GetTime()) or 0) * 1000 + ((time and time()) or 0)) % 1000000
  end
  return t.seed
end

-- ---------------------------------------------------------------------------------------------------------------
-- Packing
-- ---------------------------------------------------------------------------------------------------------------
-- Two rolling hashes under 2^31 (Lua 5.1's %x takes a C long): 16 hex digits for a key of a few kilobytes.
function H.Hash(s)
  local a, b = 5381, 7
  local byte = string.byte
  for i = 1, #s do
    local c = byte(s, i)
    a = (a * 33 + c) % 2147483647
    b = (b * 131 + c) % 2147483629
  end
  return ("%08x%08x"):format(a, b)
end

-- The fights' DPS as 4 characters each (hundredths of a DPS, up to 167,772 DPS).
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
  local ch = B64:sub(i, i)
  ENC[i - 1] = ch
  DEC[ch:byte()] = i - 1
end

function H.PackList(list)
  local out = {}
  for i = 1, #(list or {}) do
    local n = floor((tonumber(list[i]) or 0) * 100 + 0.5)
    if n ~= n or n < 0 then n = 0 elseif n > 16777215 then n = 16777215 end
    out[i] = ENC[floor(n / 262144)] .. ENC[floor(n / 4096) % 64] .. ENC[floor(n / 64) % 64] .. ENC[n % 64]
  end
  return table.concat(out)
end

function H.UnpackList(s)
  local out = {}
  if type(s) ~= "string" then return out end
  local byte = string.byte
  for i = 1, #s - 3, 4 do
    local a, b, c, d = byte(s, i, i + 3)
    out[#out + 1] = ((((DEC[a] or 0) * 64 + (DEC[b] or 0)) * 64 + (DEC[c] or 0)) * 64 + (DEC[d] or 0)) / 100
  end
  return out
end

-- A plain copy for the saved variables: numbers (finite only: an inf would not load back), strings, booleans, tables.
local HUGE = math.huge
local function Copy(v, seen)
  local t = type(v)
  if t == "number" then
    if v ~= v or v == HUGE or v == -HUGE then return 0 end
    return v
  elseif t == "string" or t == "boolean" then
    return v
  elseif t ~= "table" then
    return nil
  end
  if seen[v] then return nil end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    local tk = type(k)
    if (tk == "number" and k == k and k ~= HUGE and k ~= -HUGE) or tk == "string" then out[k] = Copy(x, seen) end
  end
  seen[v] = nil
  return out
end
H.Copy = function(v) return Copy(v, {}) end

local function Pack(summary)
  local s = {}
  for k, v in pairs(summary) do
    if k ~= "iterDps" and k ~= "stored" then s[k] = Copy(v, {}) end
  end
  s.it = H.PackList(summary.iterDps)
  return s
end

local decoded = setmetatable({}, { __mode = "v" })   -- stored result -> summary, while something holds it

local function Unpack(s)
  local hit = decoded[s]
  if hit then return hit end
  local out = {}
  for k, v in pairs(s) do
    if k ~= "it" then out[k] = v end
  end
  out.iterDps = H.UnpackList(s.it)
  out.stored = true
  decoded[s] = out
  return out
end

-- ---------------------------------------------------------------------------------------------------------------
-- Results (ns.SimRunner)
-- ---------------------------------------------------------------------------------------------------------------
-- The stored summary for a cache key, or nil.
function H:Lookup(cacheKey)
  if not cacheKey then return nil end
  local t = Root(false)
  local e = t and t.results[H.Hash(cacheKey)]
  if type(e) ~= "table" or type(e.it) ~= "string" then return nil end
  return Unpack(e)
end

-- A stored result whose first fights came out differently now: dropped (it is simmed again).
function H:Drop(cacheKey)
  local t = Root(false)
  if t and cacheKey then t.results[H.Hash(cacheKey)] = nil end
end

-- Does a fresh fight list match the stored one's first fights? (Stored DPS are rounded to hundredths.)
function H.SameStart(stored, fresh, n)
  for i = 1, n do
    local a, b = stored[i], fresh[i]
    if not (a and b) or abs(a - b) > 0.0051 then return false end
  end
  return true
end

-- ---------------------------------------------------------------------------------------------------------------
-- Runs (ns.SimPanel)
-- ---------------------------------------------------------------------------------------------------------------
-- Newest first; nil-safe (an empty list before the first run).
function H:Runs()
  local t = Root(false)
  return t and t.runs or {}
end

function H:Get(id)
  for _, r in ipairs(self:Runs()) do
    if r.id == id then return r end
  end
  return nil
end

-- A run's summaries ({ work, ref }), nil when one is gone.
function H:Summaries(run)
  local t = Root(false)
  if not (t and run) then return nil end
  local w, r = t.results[run.w], t.results[run.r]
  if type(w) ~= "table" or type(r) ~= "table" then return nil end
  return Unpack(w), Unpack(r)
end

-- Results no run uses any more go.
local function Prune(t)
  local used = {}
  for _, r in ipairs(t.runs) do
    if r.w then used[r.w] = true end
    if r.r then used[r.r] = true end
  end
  for h in pairs(t.results) do
    if not used[h] then t.results[h] = nil end
  end
end

local function SameSet(a, b)
  local R = ns.SimRunner
  for sid = 1, 19 do
    if not R:SameEntry(a and a[sid], b and b[sid]) then return false end
  end
  return true
end
H.SameSet = SameSet

-- Saves a finished run: rec = { spec, specName, target, targetText, settings, work (set), ref (set), workKey, refKey,
-- workSum, refSum, diff, se }. The same sets with the same settings as a run in the list move that run to the top
-- (with the new time) instead of adding a second one. Returns the run.
function H:Add(rec)
  local t = Root(true)
  if not t then return nil end
  local wh, rh = H.Hash(rec.workKey or ""), H.Hash(rec.refKey or "")
  for i, r in ipairs(t.runs) do
    if r.w == wh and r.r == rh then
      table.remove(t.runs, i)
      r.at = time and time() or 0
      table.insert(t.runs, 1, r)
      return r
    end
  end
  if not t.results[wh] then t.results[wh] = Pack(rec.workSum) end
  if not t.results[rh] then t.results[rh] = Pack(rec.refSum) end
  local run = {
    id = t.nextId, at = time and time() or 0, spec = rec.spec, specName = rec.specName,
    target = rec.target, targetText = rec.targetText, settings = Copy(rec.settings or {}, {}), buffsText = rec.buffsText,
    work = Copy(rec.work or {}, {}), ref = Copy(rec.ref or {}, {}), w = wh, r = rh,
    dps = rec.workSum.dps, refDps = rec.refSum.dps, diff = rec.diff, se = rec.se, n = rec.workSum.iterations,
    seed = rec.seed, version = ns.version,
  }
  t.nextId = t.nextId + 1
  table.insert(t.runs, 1, run)
  while #t.runs > self.MAX_RUNS do table.remove(t.runs) end
  Prune(t)
  return run
end

function H:Remove(id)
  local t = Root(false)
  if not t then return end
  for i, r in ipairs(t.runs) do
    if r.id == id then table.remove(t.runs, i) break end
  end
  Prune(t)
end

-- Forgets every run and stored result (the seed stays).
function H:Clear()
  local t = Root(false)
  if not t then return end
  t.runs, t.results = {}, {}
end

-- The paired difference a - b of two summaries (mean, standard error), over the fights both have. Runs of this
-- character share the seed, so fight i of both had the same rolls; `paired` is false for runs on different seeds
-- (then the error is the two runs' own errors together).
function H.Diff(A, B, sameSeed)
  local a, b = A.iterDps or {}, B.iterDps or {}
  local n = math.min(#a, #b)
  if n == 0 then return (A.dps or 0) - (B.dps or 0), 0 end
  if not sameSeed then
    local sa, sb = A.stderr or 0, B.stderr or 0
    return (A.dps or 0) - (B.dps or 0), math.sqrt(sa * sa + sb * sb)
  end
  local sum, sq = 0, 0
  for i = 1, n do
    local d = a[i] - b[i]
    sum, sq = sum + d, sq + d * d
  end
  local mean = sum / n
  local var = math.max(0, sq / n - mean * mean)
  -- (the means themselves stay exact: the stored fights are rounded to hundredths)
  if #a == n and #b == n then mean = (A.dps or 0) - (B.dps or 0) end
  return mean, math.sqrt(var / math.max(1, n - 1))
end

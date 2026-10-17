if DisasterZoneBoot and DisasterZoneBoot.Run("Core/BossLearnMath.lua", ...) then return end -- DisasterZone Core/BossLearnMath.lua
-- The rules boss mods learn by (ns.BossLearnMath): pure functions over the stored pulls, no game API at all, so the dev
-- kit's tools/bossmods_learned.py runs this very file (lupa) and gets the same windows the game does. Core/BossLearn.lua
-- records the pulls and applies what comes out of here; the format is dev/docs/bossmods/LEARNING.md in the dev kit.
--   learnable  a data alert of kind "bar" with a `spell`, a `start` or a `cd`, not `loop`, not `me`, not `learn = false`
--   predicted  "own": the alert's `on` names its spell, the event is that trigger, and its boss lines (YELL / EMOTE)
--              too (Leotheras's demon form reaches our log only as his line); "cast": the earliest
--              SPELL_CAST_START / SPELL_CAST_SUCCESS of its spell (Gruul's Shatter bar starts on Ground Slam's cast)
--   samples    start = the first event after the pull (or after its phase began); cd = from the bar's (re)start to the
--              event it predicts. Only inside one phase: a phase change between two casts never makes a sample.
--   window     >= 3 clean pulls; outliers outside 0.5x..1.5x the median dropped; [p10, p90] from 10 samples, else
--              [min, max]; rounded out to 0.5 s; clamped to [0.75 x source min, 1.25 x source max]. Not applied (the
--              source stays) when it lies wholly outside that ("far") or is wider than max(4 s, 1.25 x the source's
--              width) ("varies"); "fixed" (a follow-up the game times, like Shatter 10 s after Ground Slam) is measured
--              but never applied.
local _, ns = ...
ns = ns or {}

local M = {}
ns.BossLearnMath = M

local floor, ceil, max, min, abs = math.floor, math.ceil, math.max, math.min, math.abs
local type, ipairs, pairs, tonumber, tostring = type, ipairs, pairs, tonumber, tostring
local tsort, tconcat = table.sort, table.concat

M.FORMAT = 1               -- the stored and the wire format (a change makes old pulls and old senders drop out)
M.NEED_PULLS = 3           -- distinct clean pulls before a window is used
M.MIN_PULL = 20            -- s: a shorter pull (a wipe on the pull, a reset) is not counted
M.OUT_LO, M.OUT_HI = 0.5, 1.5
M.PCT_N = 10               -- samples from which the window is [p10, p90] (nearest rank) instead of [min, max]
M.CLAMP_LO, M.CLAMP_HI = 0.75, 1.25
M.WIDE_MIN, M.WIDE_K = 4, 1.25
M.DEBOUNCE = 1.5           -- s: one alert's events closer than this are one event
M.LINE_DEBOUNCE = 5        -- s: the same for an alert whose boss line counts too (the line and the spell a few s apart)
M.STEP = 0.5               -- s: windows are rounded out to this
M.PAIR = 0.25              -- s: a bar start this close before an event is that event's own trigger

local SUBWORD = { CAST = true, SUCCESS = true, AURA = true, AURAGONE = true, SUMMON = true, HIT = true, HEAL = true }
M.SUBWORD = SUBWORD

local function Triggers(v)
    if v == nil then return {} end
    if type(v) == "string" then return { v } end
    if type(v) == "table" then return v end
    return {}
end
M.Triggers = Triggers

-- lo, hi of a number or { min, max } (nil for anything else).
function M.Window(v)
    if type(v) == "number" then return v, v end
    if type(v) == "table" and type(v[1]) == "number" then return v[1], type(v[2]) == "number" and v[2] or v[1] end
    return nil
end

-- Is this alert one the recorder measures, and why not.
function M.Learnable(a)
    if type(a) ~= "table" then return false, "not an alert" end
    if a.kind ~= "bar" then return false, "not a timer bar" end
    if type(a.spell) ~= "number" then return false, "no spell" end
    if a.loop then return false, "loops on its own" end
    if a.learn == false then return false, "learn = false" end
    if a.me then return false, "only on me" end
    if a.start == nil and a.cd == nil then return false, "no timer" end
    return true
end

-- The ids of one trigger string ("CAST 33525 33526" -> word, { 33525, 33526 }).
local function Ids(t)
    local word, rest = tostring(t):match("^(%u+)%s*(.*)$")
    if not word then return nil, {} end
    local ids = {}
    for id in rest:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
    return word, ids
end
M.Ids = Ids

-- What the recorder needs to know of a learnable alert: { key, spell, mode ("own" | "cast"), own = { [word] = ids },
-- chat (an own alert's boss lines are its event too), mixed (a trigger that is not the predicted event restarts the
-- bar too), start / cd = { lo, hi } | nil, ph = set | nil, once, fixed }. nil when it is not learnable.
function M.Spec(a)
    if not M.Learnable(a) then return nil end
    local s = { key = a.key, spell = a.spell, once = a.once and true or nil, own = {} }
    local named, other, chat = false, false, false
    for _, t in ipairs(Triggers(a.on)) do
        local word, ids = Ids(t)
        local hit = false
        if word and SUBWORD[word] then
            for _, id in ipairs(ids) do if id == a.spell then hit = true end end
        end
        if hit then
            named = true
            s.own[word] = s.own[word] or {}
            for _, id in ipairs(ids) do s.own[word][#s.own[word] + 1] = id end
        elseif word == "YELL" or word == "EMOTE" then
            chat = true
        elseif word then
            other = true
        end
    end
    s.mode = named and "own" or "cast"
    s.chat = (named and chat) or nil
    s.mixed = (named and other) or nil
    if a.start ~= nil then local lo, hi = M.Window(a.start); if lo then s.start = { lo, hi } end end
    if a.cd ~= nil then local lo, hi = M.Window(a.cd); if lo then s.cd = { lo, hi } end end
    if type(a.phase) == "number" then s.ph = { [a.phase] = true }
    elseif type(a.phase) == "table" then s.ph = {}; for _, p in ipairs(a.phase) do s.ph[p] = true end end
    -- (a follow-up the game times: started by another spell, one number, no first timer of its own)
    s.fixed = (s.mode == "cast" and a.start == nil and type(a.cd) == "number") or nil
    return s
end

---------------------------------------------------------------------------
-- The boss data's signature: what decides what an observation means (keys, spells, triggers, phases, sources), not
-- the numbers, so baking better numbers into the data keeps the pulls; any other change starts them over.
---------------------------------------------------------------------------

local function Adler32(str)
    local a, b = 1, 0
    for i = 1, #str do
        a = (a + str:byte(i)) % 65521
        b = (b + a) % 65521
    end
    return b * 65536 + a
end
M.Adler32 = Adler32

local function Flat(v)
    if v == nil then return "" end
    if type(v) == "table" then
        local o = {}
        for i, x in ipairs(v) do o[i] = tostring(x) end
        return tconcat(o, "+")
    end
    return tostring(v)
end

function M.Signature(def)
    local parts = { "v" .. M.FORMAT }
    local keys = {}
    for _, a in ipairs(type(def) == "table" and def.alerts or {}) do
        if M.Learnable(a) then keys[#keys + 1] = a end
    end
    tsort(keys, function(p, q) return tostring(p.key) < tostring(q.key) end)
    for _, a in ipairs(keys) do
        parts[#parts + 1] = tconcat({ tostring(a.key), tostring(a.spell), Flat(a.on), Flat(a.phase), Flat(a.src),
            a.once and "1" or "0", (a.start ~= nil) and "s" or "", (a.cd ~= nil) and "c" or "" }, ":")
    end
    return ("%08x"):format(Adler32(tconcat(parts, "|")))
end

---------------------------------------------------------------------------
-- Lists
---------------------------------------------------------------------------

local function Round1(x) return floor(x * 10 + 0.5) / 10 end
M.Round1 = Round1

-- A sorted copy with events closer than d to the previous kept one dropped.
function M.Debounce(list, d)
    local s = {}
    for _, x in ipairs(type(list) == "table" and list or {}) do if type(x) == "number" then s[#s + 1] = x end end
    tsort(s)
    local out, last = {}, nil
    for _, x in ipairs(s) do
        if not last or x - last >= d then out[#out + 1] = x; last = x end
    end
    return out
end

-- The sorted union of two lists, a time of b within tol of one already there counted once.
function M.Union(a, b, tol)
    local out = {}
    for _, x in ipairs(type(a) == "table" and a or {}) do if type(x) == "number" then out[#out + 1] = x end end
    tsort(out)
    for _, x in ipairs(type(b) == "table" and b or {}) do
        if type(x) == "number" then
            local near = false
            for _, y in ipairs(out) do if abs(x - y) <= tol then near = true break end end
            if not near then out[#out + 1] = x end
        end
    end
    tsort(out)
    return out
end

---------------------------------------------------------------------------
-- Samples from one pull
---------------------------------------------------------------------------

-- The pull cut at its phase changes: { { n, s, e, first = true for the pull's own }, ... }.
function M.Segments(rec)
    local dur = tonumber(rec.dur) or 0
    local ph = {}
    for _, p in ipairs(type(rec.ph) == "table" and rec.ph or {}) do
        if type(p) == "table" and type(p.n) == "number" and type(p.t) == "number" then ph[#ph + 1] = p end
    end
    tsort(ph, function(p, q) return p.t < q.t end)
    local segs, n, s = {}, 1, 0
    for _, p in ipairs(ph) do
        segs[#segs + 1] = { n = n, s = s, e = p.t, first = #segs == 0 }
        n, s = p.n, p.t
    end
    segs[#segs + 1] = { n = n, s = s, e = max(s, dur), first = #segs == 0 }
    return segs
end

local function Within(list, s, e)
    local out = {}
    for _, x in ipairs(list) do if x >= s and x < e then out[#out + 1] = x end end
    return out
end

-- start, cd: the sample lists one clean pull gives for spec (times from rec.o / rec.g).
function M.Samples(spec, rec)
    local starts, cds = {}, {}
    if type(rec) ~= "table" or type(rec.o) ~= "table" then return starts, cds end
    local obs = M.Debounce(rec.o[spec.key], spec.chat and M.LINE_DEBOUNCE or M.DEBOUNCE)
    local g = M.Debounce(type(rec.g) == "table" and rec.g[spec.key] or nil, 0)
    local useG = spec.mode == "cast" or spec.mixed
    for _, seg in ipairs(M.Segments(rec)) do
        local active = (not spec.ph) or spec.ph[seg.n]
        if active then
            local o = Within(obs, seg.s, seg.e)
            local gi = useG and Within(g, seg.s - M.PAIR, seg.e) or {}
            -- the first timer: the engine starts it at the pull (phase 1 alerts) or on entering one of its phases
            local startable = spec.start and ((seg.first and (not spec.ph or spec.ph[1]))
                or (not seg.first and spec.ph and spec.ph[seg.n]))
            if startable and o[1] then
                local restarted = false
                if spec.mixed then
                    for _, x in ipairs(gi) do if x >= seg.s and x < o[1] - M.PAIR then restarted = true end end
                end
                if not restarted then starts[#starts + 1] = Round1(o[1] - seg.s) end
            end
            if spec.cd then
                if not useG then
                    for i = 2, #o do
                        cds[#cds + 1] = Round1(o[i] - o[i - 1])
                        if spec.once then break end
                    end
                else
                    local prev = seg.s - 1
                    for _, x in ipairs(o) do
                        local best
                        for _, y in ipairs(gi) do
                            if y >= prev - M.PAIR and y <= x - M.PAIR then best = y end
                        end
                        if best then cds[#cds + 1] = Round1(x - best) end
                        prev = x
                        if spec.once and best then break end
                    end
                end
            end
        end
    end
    return starts, cds
end

---------------------------------------------------------------------------
-- The window of one alert's field over the stored pulls
---------------------------------------------------------------------------

local function Median(s)
    local n = #s
    if n == 0 then return nil end
    if n % 2 == 1 then return s[(n + 1) / 2] end
    return (s[n / 2] + s[n / 2 + 1]) / 2
end
M.Median = Median

-- Nearest rank: the smallest sample with at least q of them at or below it.
local function Rank(s, q)
    local i = max(1, min(#s, ceil(q * #s - 1e-9)))
    return s[i]
end
M.Rank = Rank

local function Down(x) return floor(x / M.STEP + 1e-9) * M.STEP end
local function Up(x) return ceil(x / M.STEP - 1e-9) * M.STEP end

-- samples: { { v = seconds, p = pull id }, ... }; src = { lo, hi } the data's number. Returns nil (no samples) or
-- { state = "ok" | "wait" | "far" | "varies" | "fixed", n, p, lo, hi (what is used: only with applied), mlo, mhi
-- (measured), src, applied, clamped }.
function M.Fit(samples, src, fixed)
    local vals = {}
    for _, x in ipairs(samples) do
        if type(x) == "table" and type(x.v) == "number" and x.v > 0 then vals[#vals + 1] = x end
    end
    if #vals == 0 then return nil end
    local sorted = {}
    for i, x in ipairs(vals) do sorted[i] = x.v end
    tsort(sorted)
    local med = Median(sorted)
    local kept, pulls, np = {}, {}, 0
    for _, x in ipairs(vals) do
        if x.v >= M.OUT_LO * med and x.v <= M.OUT_HI * med then
            kept[#kept + 1] = x.v
            if not pulls[x.p] then pulls[x.p] = true; np = np + 1 end
        end
    end
    tsort(kept)
    local r = { n = #kept, p = np, src = src and { src[1], src[2] } or nil, dropped = #vals - #kept }
    if np < M.NEED_PULLS or #kept == 0 then
        r.state = "wait"
        return r
    end
    local lo, hi
    if #kept >= M.PCT_N then lo, hi = Rank(kept, 0.1), Rank(kept, 0.9)
    else lo, hi = kept[1], kept[#kept] end
    lo, hi = Down(lo), Up(hi)
    r.mlo, r.mhi = lo, hi
    if fixed then r.state = "fixed" return r end
    if not src then r.state = "far" return r end
    local clo, chi = M.CLAMP_LO * src[1], M.CLAMP_HI * src[2]
    if hi < clo or lo > chi then r.state = "far" return r end
    if hi - lo > max(M.WIDE_MIN, M.WIDE_K * (src[2] - src[1])) then r.state = "varies" return r end
    local alo, ahi = max(lo, clo), min(hi, chi)
    if alo <= 0 or alo > ahi then r.state = "far" return r end
    r.state, r.applied, r.lo, r.hi = "ok", true, alo, ahi
    r.clamped = (alo ~= lo or ahi ~= hi) or nil
    return r
end

-- Is the pull usable for learning this boss now: clean, long enough, recorded against the same data signature.
function M.Usable(rec, ds)
    return type(rec) == "table" and rec.clean == true and (tonumber(rec.dur) or 0) >= M.MIN_PULL
        and (ds == nil or rec.ds == ds)
end

-- Every learnable alert of def over pulls: { [key] = { start = fit, cd = fit } } and the number of usable pulls.
function M.LearnBoss(def, pulls, ds)
    local out, used = {}, 0
    local usable = {}
    for _, rec in ipairs(type(pulls) == "table" and pulls or {}) do
        if M.Usable(rec, ds) then usable[#usable + 1] = rec; used = used + 1 end
    end
    for _, a in ipairs(type(def) == "table" and def.alerts or {}) do
        local spec = M.Spec(a)
        if spec then
            local ss, cs = {}, {}
            for _, rec in ipairs(usable) do
                if not (type(rec.hk) == "table" and rec.hk[spec.key]) then
                    local st, cd = M.Samples(spec, rec)
                    for _, v in ipairs(st) do ss[#ss + 1] = { v = v, p = rec.id } end
                    for _, v in ipairs(cd) do cs[#cs + 1] = { v = v, p = rec.id } end
                end
            end
            local e = {}
            if spec.start then e.start = M.Fit(ss, spec.start) or { state = "wait", n = 0, p = 0, src = spec.start } end
            if spec.cd then e.cd = M.Fit(cs, spec.cd, spec.fixed) or { state = "wait", n = 0, p = 0, src = spec.cd } end
            if spec.fixed then e.fixed = true end
            out[spec.key] = e
        end
    end
    return out, used
end

---------------------------------------------------------------------------
-- What the developer reviews (aggregates only; names and suggestions are made in game)
---------------------------------------------------------------------------

-- Alerts whose combat-log triggers never fired in any usable pull: { [key] = pulls } (every pull checks every alert
-- with a combat-log trigger and lists the silent ones in rec.nf; only keys silent in all of at least `need` pulls).
function M.NeverFired(pulls, ds, need)
    local zero, checked = {}, 0
    for _, rec in ipairs(type(pulls) == "table" and pulls or {}) do
        if M.Usable(rec, ds) and type(rec.nf) == "table" then
            checked = checked + 1
            for _, k in ipairs(rec.nf) do zero[k] = (zero[k] or 0) + 1 end
        end
    end
    local out = {}
    for k, n in pairs(zero) do if n == checked and n >= (need or 2) then out[k] = n end end
    return out
end

-- Hostile casts the data doesn't know, over the usable pulls: list of { id, name, pulls, n, first } most pulls first.
function M.Unknown(pulls, ds)
    local by, list = {}, {}
    for _, rec in ipairs(type(pulls) == "table" and pulls or {}) do
        if M.Usable(rec, ds) then
            for _, u in ipairs(type(rec.u) == "table" and rec.u or {}) do
                if type(u) == "table" and type(u.id) == "number" then
                    local e = by[u.id]
                    if not e then e = { id = u.id, pulls = 0, n = 0 }; by[u.id] = e; list[#list + 1] = e end
                    e.pulls = e.pulls + 1
                    e.n = e.n + (tonumber(u.n) or 1)
                    e.name = e.name or (type(u.name) == "string" and u.name or nil)
                    if type(u.t) == "number" and (not e.first or u.t < e.first) then e.first = u.t end
                end
            end
        end
    end
    tsort(list, function(p, q) if p.pulls ~= q.pulls then return p.pulls > q.pulls end return p.id < q.id end)
    return list
end

-- Boss lines no trigger matched: list of { text, pulls, n } most pulls first.
function M.Yells(pulls, ds)
    local by, list = {}, {}
    for _, rec in ipairs(type(pulls) == "table" and pulls or {}) do
        if M.Usable(rec, ds) then
            for _, y in ipairs(type(rec.y) == "table" and rec.y or {}) do
                if type(y) == "table" and type(y.text) == "string" then
                    local e = by[y.text]
                    if not e then e = { text = y.text, pulls = 0, n = 0 }; by[y.text] = e; list[#list + 1] = e end
                    e.pulls = e.pulls + 1
                    e.n = e.n + (tonumber(y.n) or 1)
                end
            end
        end
    end
    tsort(list, function(p, q) if p.pulls ~= q.pulls then return p.pulls > q.pulls end return p.text < q.text end)
    return list
end

-- "34-37 s" / "30 s" (an en dash; whole numbers without ".0").
local function Num(x)
    if x == floor(x) then return tostring(floor(x)) end
    return ("%.1f"):format(x)
end
M.Num = Num
function M.Range(lo, hi)
    if not lo then return "" end
    if not hi or hi == lo then return Num(lo) .. " s" end
    return Num(lo) .. "\226\128\147" .. Num(hi) .. " s"
end

return M

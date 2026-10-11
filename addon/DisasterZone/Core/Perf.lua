if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Perf.lua", ...) then return end -- DisasterZone Core/Perf.lua
-- Performance: what DisasterZone costs this client, for the developer's Performance page (UI/PerfUI.lua). Only the
-- developer's character (DEV, Tsumil) runs any of it; for everybody else this file sets two names and stops.
--
--  * Memory: the addon's memory as the AddOn list shows it (garbage included), sampled every SAMPLE_S for the last
--    hour; "in use" is what is left after a full cleanup (Perf:CleanUp); garbage per minute is the growth between
--    samples (a drop is the game's cleanup, not counted).
--  * CPU: Blizzard's addon profiler (C_AddOnProfiler) when the client has it.
--  * Who makes garbage: Perf:Measure(seconds) times every DisasterZone handler while it runs and weighs the garbage
--    each makes (collectgarbage("count") before and after; a cleanup inside a call makes it negative: not counted).
--    Covered: events and the addon's own messages (Core/Init.lua hands them to Perf.Probe while measuring); every
--    OnUpdate and OnEvent script DisasterZone set (a post-hook on the widgets' SetScript notes which file and line set
--    it; while measuring they are wrapped, and put back after); addon messages (Core/Comm.lua: receive + decode per
--    prefix, the handler per message type); timers scheduled with Util.After / Util.Debounce; the bundled shared
--    libraries' frames (AceComm, ChatThrottleLib). Not covered: C_Timer called directly - the page shows it as the
--    rest of the growth.
--  * What holds memory: widgets and build time of every page built (UI/MainFrame.lua GetPageStats) and the size of
--    each saved variable's sections (an estimate: 56 bytes a table, 40 an entry, 25 + length a string).
--  * Next to the other addons: every loaded addon's memory and CPU, as the game counts them.
--  * Network: addon messages in and out per prefix and per player (Core/Comm.lua hands them to ns.PerfNet), the
--    session and the last full minute; ChatThrottleLib's state.
--  * The session: when it started, the build, an in-game update, the 3D rooms addon.
local addonName, ns = ...

-- (a plain table, not a module: this file loads early, before the modules whose lifecycle order matters; the page,
-- UI/PerfUI.lua, starts the sampling at login)
local Perf = {}
ns.Perf = Perf

local DEV = "Tsumil"             -- (Core/Feedback.lua DEV_NAME, Core/Guild.lua DEBUG_CHAR: the same character)
local SAMPLE_S = 10
local KEEP = 360                 -- samples: an hour
local RATE_WINDOW = 300          -- s: garbage per minute over the last five minutes

local type, tostring, tonumber, pairs, ipairs, next, select = type, tostring, tonumber, pairs, ipairs, next, select
local max = math.max
local gcount = function() return collectgarbage("count") end
local clock = debugprofilestop or function() return 0 end
local function now() return GetTime and GetTime() or 0 end   -- (looked up each time: a test clock may replace it)

local isDev = (UnitName and UnitName("player")) == DEV
Perf.DEV = DEV
function Perf:IsDev() return isDev end

---------------------------------------------------------------------------
-- Where a handler came from: the first DisasterZone file in the stack
---------------------------------------------------------------------------

-- (the helpers that schedule, register and dispatch: the line that called them names the handler)
local SKIP_FILE = { ["Core/Perf.lua"] = true, ["Core/Init.lua"] = true, ["Core/Util.lua"] = true }

local function Where()
    local stack = debugstack and debugstack(1, 12, 0)
    if type(stack) ~= "string" then return nil end
    for file, line in stack:gmatch("AddOns[/\\]DisasterZone[/\\]([^:\"%]]-%.lua)[\"%]]*:(%d+)") do
        file = file:gsub("\\", "/")
        if not SKIP_FILE[file] then return file .. ":" .. line end
    end
    return nil
end
Perf._Where = Where

local noteOf = setmetatable({}, { __mode = "k" })      -- handler fn -> "file:line" that registered it
local scriptOf = setmetatable({}, { __mode = "k" })    -- frame -> { OnUpdate = "file:line", OnEvent = ... } (who set it)

---------------------------------------------------------------------------
-- Measuring (a run of Perf:Measure)
---------------------------------------------------------------------------

local run                        -- the running measurement, or nil
local setting = false            -- (our own SetScript calls: not noted)
local WATCHED = { OnUpdate = true, OnEvent = true }

local function Record(key, what, ms, kb)
    local r = run.rows[key]
    if not r then
        r = { key = key, what = what, calls = 0, ms = 0, kb = 0, gc = 0 }
        run.rows[key] = r
    end
    r.calls = r.calls + 1
    r.ms = r.ms + ms
    if ms > (r.maxMs or 0) then r.maxMs = ms end
    if kb >= 0 then
        r.kb = r.kb + kb
        if kb > (r.maxKb or 0) then r.maxKb = kb end
    else
        r.gc = r.gc + 1
    end
    return r
end

-- Who a message came from or went to (a row's tooltip): name -> { n, rev (the last message's rev, when it had one) }.
local function Party(r, who, rev)
    if not r then return end
    r.who = r.who or {}
    local p = r.who[who]
    if not p then p = { n = 0 } r.who[who] = p end
    p.n = p.n + 1
    if rev ~= nil then p.rev = rev end
end

-- Measured calls nest (an addon message comes in through AceComm's frame, is decoded, its handler fires a message
-- whose handlers run...): each row keeps only its own part - what its calls cost less what was measured inside them.
local SafeCall = ns.SafeCall
local depth, innerKb, innerMs = 0, {}, {}
local function Begin()
    depth = depth + 1
    innerKb[depth], innerMs[depth] = 0, 0
    return gcount(), clock()
end
-- -> the row (nil when the measurement ended meanwhile)
local function Finish(key, what, c0, t0)
    local ms, kb = clock() - t0, gcount() - c0
    local ikb, ims = innerKb[depth], innerMs[depth]
    depth = depth - 1
    if depth > 0 then
        innerMs[depth] = innerMs[depth] + ms
        if kb > 0 then innerKb[depth] = innerKb[depth] + kb end
    end
    if not run then return nil end
    return Record(key, what, max(0, ms - ims), kb >= 0 and max(0, kb - ikb) or kb)
end

-- Core/Init.lua's dispatcher, while measuring: the handlers run here, one at a time, weighed.
local function Probe(kind, name, list, ...)
    for i = 1, #list do
        local fn = list[i]
        local c0, t0 = Begin()
        if kind == "event" then SafeCall(fn, name, ...) else SafeCall(fn, ...) end
        Finish((noteOf[fn] or "?") .. "  " .. name, kind == "event" and "event" or "message", c0, t0)
    end
end
Perf.Probe = Probe

-- A frame's script, wrapped while measuring (kind: OnUpdate / OnEvent; an OnEvent row is per event). The script runs
-- through SafeCall: an error in it is reported as before and the measuring stays in step.
local function Wrap(frame, kind, fn, at, what)
    if run.wrapperOf[fn] then return end           -- (already one of ours)
    local w
    if kind == "OnEvent" then
        w = function(self, event, ...)
            local c0, t0 = Begin()
            SafeCall(fn, self, event, ...)
            Finish(at .. "  " .. tostring(event), what or "OnEvent", c0, t0)
        end
    else
        local key = at .. "  " .. kind
        w = function(self, ...)
            local c0, t0 = Begin()
            SafeCall(fn, self, ...)
            Finish(key, what or kind, c0, t0)
        end
    end
    run.wrapperOf[w] = fn
    run.wrapped[#run.wrapped + 1] = { frame = frame, kind = kind, w = w, fn = fn }
    setting = true
    frame:SetScript(kind, w)
    setting = false
end

-- The widgets' SetScript, after it ran (hooksecurefunc on each widget type's methods): note who set an OnUpdate or
-- OnEvent from a DisasterZone file; while measuring, wrap it at once.
local function OnSetScript(frame, kind, fn)
    if setting or not WATCHED[kind] then return end
    local s = scriptOf[frame]
    if fn == nil then
        if s then s[kind] = nil end
        return
    end
    if run and run.wrapperOf[fn] then return end
    local at = Where()
    if not at then return end
    if not s then s = {} scriptOf[frame] = s end
    s[kind] = at
    if run then Wrap(frame, kind, fn, at) end
end
Perf._OnSetScript = OnSetScript

local TYPES = { "Frame", "Button", "CheckButton", "EditBox", "ScrollFrame", "Slider", "StatusBar", "Cooldown",
                "Model", "PlayerModel", "DressUpModel", "ModelScene", "MessageFrame", "SimpleHTML", "ColorSelect" }
local function HookSetScript()
    if not (hooksecurefunc and CreateFrame and getmetatable) then return 0 end
    local done, n = {}, 0
    for _, t in ipairs(TYPES) do
        local ok, f = pcall(CreateFrame, t)
        local mt = ok and f and getmetatable(f)
        local idx = mt and mt.__index
        if type(idx) == "table" and not done[idx] and type(idx.SetScript) == "function" then
            done[idx] = true
            hooksecurefunc(idx, "SetScript", OnSetScript)
            n = n + 1
        end
        if ok and f and f.Hide then f:Hide() end
    end
    return n
end

-- Timers scheduled through Core/Util.lua (Util.After, Util.Debounce) while measuring: the callback, named by where
-- it was scheduled. (C_Timer called directly is not seen: it stays in "the rest".)
local function TimerProbe(fn)
    if not run or type(fn) ~= "function" then return fn end
    local key = (Where() or "?") .. "  timer"
    return function(...)
        local c0, t0 = Begin()
        SafeCall(fn, ...)
        Finish(key, "timer", c0, t0)
    end
end

-- Addon messages (Core/Comm.lua) while measuring: the receive (sender checks, decoding) per prefix, the handler per
-- message type with who sent it; and what I send, per message type and channel, with whom to.
local function CommHandlerProbe(msgType, handler, sender, msg, dist)
    local c0, t0 = Begin()
    SafeCall(handler, sender, msg, dist)
    Party(Finish("Core/Comm.lua  message " .. tostring(msgType), "comm", c0, t0), tostring(sender),
        type(msg) == "table" and msg.rev or nil)
end

local function WrapComm()
    local Comm = ns.Comm
    local orig = Comm and Comm.OnCommReceived
    if type(orig) ~= "function" then return end
    run.commOrig = orig
    Comm.OnCommReceived = function(self, prefix, ...)
        local c0, t0 = Begin()
        SafeCall(orig, self, prefix, ...)
        Finish("Core/Comm.lua  receive + decode " .. tostring(prefix), "comm", c0, t0)
    end
    ns.PerfComm = CommHandlerProbe
    local send = Comm.Send
    if type(send) == "function" then
        run.sendOrig = send
        Comm.Send = function(self, msg, dist, target, ...)
            local c0, t0 = Begin()
            local ok, a, b, c = SafeCall(send, self, msg, dist, target, ...)
            local r = Finish("Core/Comm.lua  send " .. tostring(type(msg) == "table" and msg.t) .. " " .. tostring(dist),
                "send", c0, t0)
            Party(r, tostring(target or dist), type(msg) == "table" and msg.rev or nil)
            if ok then return a, b, c end
        end
    end
end

-- The shared libraries DisasterZone bundles: LibStub runs one copy for every addon that has them (the newest, or the
-- first loaded), so the copy at work may be DisasterZone's - then its garbage, from every addon's messages, counts as
-- DisasterZone's. Their frames were made before this file: wrapped by name.
local function LibFrames()
    local out = {}
    local LS = LibStub
    local ace = LS and LS("AceComm-3.0", true)
    if ace and ace.frame then out[#out + 1] = { ace.frame, "Libs/AceComm-3.0" } end
    local ctl = ChatThrottleLib
    if type(ctl) == "table" and ctl.Frame then out[#out + 1] = { ctl.Frame, "Libs/ChatThrottleLib" } end
    return out
end

if isDev then
    -- (set before the other files load: every handler they register and every script they set is noted)
    ns.PerfNote = function(fn)
        if noteOf[fn] == nil then noteOf[fn] = Where() or false end
    end
    ns.PerfTimer = TimerProbe
    ns.PerfNet = function(...) return Perf._Net(...) end
    Perf.hooked = HookSetScript()
end

local function AddOnUsage()
    if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return gcount() end
    UpdateAddOnMemoryUsage()
    return GetAddOnMemoryUsage(addonName) or 0
end
Perf._AddOnUsage = AddOnUsage

-- Measures for `seconds` (default 30), then calls onDone(result). A full cleanup first, so the growth after it is
-- what DisasterZone makes. -> false when one is running, in combat (wrapping frames then is not wanted) or this is not
-- the developer.
-- result = { seconds, grew (KB, the AddOn list's number from start to end), rows = { { key, what, calls, ms, kb,
-- gc }, ... } (most garbage first), attributed (KB) }
function Perf:Measure(seconds, onDone)
    if run or not isDev then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    seconds = tonumber(seconds) or 30
    collectgarbage("collect")
    run = { rows = {}, wrapperOf = {}, wrapped = {}, started = now(), seconds = seconds }
    run.usage0 = AddOnUsage()
    for frame, s in pairs(scriptOf) do
        for kind, at in pairs(s) do
            local fn = frame.GetScript and frame:GetScript(kind)
            if fn then Wrap(frame, kind, fn, at) end
        end
    end
    for _, lf in ipairs(LibFrames()) do
        for kind in pairs(WATCHED) do
            local fn = lf[1].GetScript and lf[1]:GetScript(kind)
            if fn then Wrap(lf[1], kind, fn, lf[2], "library") end
        end
    end
    WrapComm()
    ns.PerfProbe = Probe
    C_Timer.After(seconds, function() Perf:FinishMeasure(onDone) end)
    return true
end

function Perf:IsMeasuring() return run ~= nil, run and (now() - run.started) or 0, run and run.seconds or 0 end

function Perf:FinishMeasure(onDone)
    local r = run
    if not r then return end
    ns.PerfProbe, ns.PerfComm = nil, nil
    run = nil
    if r.commOrig and ns.Comm then ns.Comm.OnCommReceived = r.commOrig end
    if r.sendOrig and ns.Comm then ns.Comm.Send = r.sendOrig end
    setting = true
    for _, e in ipairs(r.wrapped) do
        if e.frame:GetScript(e.kind) == e.w then e.frame:SetScript(e.kind, e.fn) end
    end
    setting = false
    local grew = AddOnUsage() - r.usage0
    local rows, attributed = {}, 0
    for _, row in pairs(r.rows) do
        rows[#rows + 1] = row
        attributed = attributed + row.kb
    end
    table.sort(rows, function(a, b)
        if a.kb ~= b.kb then return a.kb > b.kb end
        return a.ms > b.ms
    end)
    -- a message type I both get and send back at least every 5 s while measuring: a sync loop, maybe
    local got, sent = {}, {}
    for _, row in ipairs(rows) do
        local t = tostring(row.key):match("^Core/Comm%.lua  message (%S+)$")
        if t then got[t] = row end
        local s2 = tostring(row.key):match("^Core/Comm%.lua  send (%S+) ")
        if s2 then sent[s2] = (sent[s2] or 0) + row.calls end
    end
    for t, row in pairs(got) do
        local every = r.seconds / 5
        if row.calls >= every and (sent[t] or 0) >= every then row.loop = true row.sent = sent[t] end
    end
    local result = { seconds = r.seconds, grew = grew, rows = rows, attributed = attributed, at = now() }
    Perf.last = result
    ns:Fire("PERF_UPDATED")
    if onDone then onDone(result) end
end

---------------------------------------------------------------------------
-- Memory over time, cleanups, CPU
---------------------------------------------------------------------------

local samples = {}               -- { t, kb, cpu } oldest first (cpu: the profiler's recent average, ms)
Perf.samples = samples
local stats = { peak = 0, cleanups = 0, lastCleanAt = nil, started = now() }
Perf.stats = stats

local function Push(kb, cpu)
    local last = samples[#samples]
    if last and kb < last.kb then         -- (a drop: the game cleaned up)
        stats.cleanups = stats.cleanups + 1
        stats.lastCleanAt = now()
        last.drop = true
    end
    if kb > stats.peak then stats.peak = kb end
    samples[#samples + 1] = { t = now(), kb = kb, cpu = cpu }
    if #samples > KEEP then table.remove(samples, 1) end
end

local NetRoll                    -- (the network section, below: its per-minute windows turn here)

function Perf:Sample()
    local kb = AddOnUsage()
    local cpu = Perf:CPU()
    Push(kb, cpu and cpu.recent or nil)
    if NetRoll then NetRoll() end
    ns:Fire("PERF_UPDATED")
    return kb
end

-- A full cleanup (the game pauses a moment): -> KB before, KB after (what DisasterZone really holds).
function Perf:CleanUp()
    local before = AddOnUsage()
    collectgarbage("collect")
    local after = AddOnUsage()
    Perf.clean = { t = now(), before = before, after = after }
    local cpu = Perf:CPU()
    Push(after, cpu and cpu.recent or nil)
    stats.cleanups = stats.cleanups - 1        -- (ours, not the game's: not counted as one of its cleanups)
    ns:Fire("PERF_UPDATED")
    return before, after
end

-- Garbage per minute (KB) over the last RATE_WINDOW seconds: the growth between samples; a drop (the game's cleanup)
-- is skipped. nil before two samples.
function Perf:GarbageRate()
    local n = #samples
    if n < 2 then return nil end
    local from = samples[n].t - RATE_WINDOW
    local grew, span = 0, 0
    for i = n, 2, -1 do
        local a, b = samples[i - 1], samples[i]
        if a.t < from then break end
        local d = b.kb - a.kb
        if d > 0 then grew = grew + d end
        span = span + (b.t - a.t)
    end
    if span <= 0 then return nil end
    return grew / span * 60
end

-- Blizzard's addon profiler (C_AddOnProfiler; its metrics by name, each optional). nil without it.
local function Profiler()
    local P = C_AddOnProfiler
    local E = Enum and Enum.AddOnProfilerMetric
    if not (type(P) == "table" and type(P.GetAddOnMetric) == "function" and type(E) == "table") then return nil end
    return P, E
end
local function Metric(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    return ok and tonumber(v) or nil
end
local OVER = { 1, 5, 10, 50, 100 }

-- DisasterZone's CPU (ms): { recent, session, boss (in encounters), peak, share (0..1 of the game's frame time, when
-- the client says), over = { { ms, frames }, ... } (frames that took longer than ms), off (the profiler is off) }, or
-- nil without the profiler. name: another addon's instead.
function Perf:CPU(name)
    local P, E = Profiler()
    if not P then return nil end
    if type(P.IsEnabled) == "function" then
        local ok, on = pcall(P.IsEnabled)
        if ok and on == false then return { off = true } end
    end
    name = name or addonName
    local out = {
        recent = E.RecentAverageTime and Metric(P.GetAddOnMetric, name, E.RecentAverageTime),
        session = E.SessionAverageTime and Metric(P.GetAddOnMetric, name, E.SessionAverageTime),
        boss = E.EncounterAverageTime and Metric(P.GetAddOnMetric, name, E.EncounterAverageTime),
        peak = E.PeakTime and Metric(P.GetAddOnMetric, name, E.PeakTime),
    }
    local app = E.RecentAverageTime and Metric(P.GetApplicationMetric, E.RecentAverageTime)
    if out.recent and app and app > 0 then out.share = out.recent / app end
    out.over = {}
    for _, ms in ipairs(OVER) do
        local key = E["CountTimeOver" .. ms .. "Ms"]
        local n = key and Metric(P.GetAddOnMetric, name, key)
        if n then out.over[#out.over + 1] = { ms = ms, n = n } end
    end
    return out
end

-- The frame rate now (frames a second), or nil.
function Perf:FPS() return GetFramerate and GetFramerate() or nil end

---------------------------------------------------------------------------
-- Next to the other addons
---------------------------------------------------------------------------

local function AddOnApi(name) return (C_AddOns and C_AddOns[name]) or _G[name] end

-- Every loaded addon: { name, title, icon (texture path, atlas or nil), kb (as the last sample read it), cpu (ms,
-- the profiler's recent average, or nil), me (DisasterZone) }, the most memory first; and the total KB of them all.
function Perf:Addons()
    local num = AddOnApi("GetNumAddOns")
    local info, loaded = AddOnApi("GetAddOnInfo"), AddOnApi("IsAddOnLoaded")
    local meta = AddOnApi("GetAddOnMetadata")
    local mem = GetAddOnMemoryUsage
    local out, total = {}, 0
    if not (num and info and loaded and mem) then return out, 0 end
    local P, E = Profiler()
    for i = 1, num() or 0 do
        local name, title = info(i)
        if name and loaded(name) then
            local kb = mem(i) or 0
            total = total + kb
            local a = { name = name, title = title, kb = kb, me = name == addonName }
            if meta then
                local ok, icon = pcall(meta, name, "IconTexture")
                a.icon = ok and icon or nil
                if not a.icon then
                    local ok2, atlas = pcall(meta, name, "IconAtlas")
                    a.atlas = ok2 and atlas or nil
                end
            end
            if P and E.RecentAverageTime then a.cpu = Metric(P.GetAddOnMetric, name, E.RecentAverageTime) end
            out[#out + 1] = a
        end
    end
    table.sort(out, function(x, y)
        if x.kb ~= y.kb then return x.kb > y.kb end
        return x.name < y.name
    end)
    return out, total
end

-- The session: { started (GetTime), version, build, update ("#n v" while an in-game update runs, else nil),
-- rooms = { loaded, kb } (the load-on-demand 3D room data) }.
function Perf:Session()
    local boot = ns.Boot
    local applied = boot and boot.applied
    local build = type(DisasterZoneBuild) == "table" and DisasterZoneBuild.id or (boot and boot.buildId) or "dev"
    local r3 = ns.Render3D
    local roomsName = r3 and r3.DATA_ADDON or "DisasterZone_Rooms"
    local loaded = AddOnApi("IsAddOnLoaded")
    local isIn = loaded and loaded(roomsName) and true or false
    return {
        started = stats.started, version = ns.version or "?", build = tostring(build),
        update = applied and ("#%s %s"):format(tostring(applied.seq), tostring(applied.version or "")) or nil,
        rooms = { loaded = isIn, kb = isIn and GetAddOnMemoryUsage and GetAddOnMemoryUsage(roomsName) or nil },
    }
end

---------------------------------------------------------------------------
-- Network: addon messages in and out (Core/Comm.lua hands them to ns.PerfNet, the developer's client only)
---------------------------------------------------------------------------

-- Counted per prefix and per player: the whole session, and minute by minute (the last full minute is what the page
-- shows as "a minute"). No tables are made per message: counts go into tables made once per prefix / player.
local net = { total = { inN = 0, inB = 0, outN = 0, outB = 0 }, prefix = {}, who = {}, cur = {}, last = nil,
              windowAt = now() }
Perf.net = net

local function Bucket(t, key)
    local b = t[key]
    if not b then
        b = { inN = 0, inB = 0, outN = 0, outB = 0 }
        t[key] = b
    end
    return b
end

-- dir "in" | "out"; who: the sender, or the channel / whisper target.
local function PerfNet(dir, prefix, bytes, who)
    bytes = tonumber(bytes) or 0
    local n, b = dir == "in" and "inN" or "outN", dir == "in" and "inB" or "outB"
    local tot = net.total
    tot[n], tot[b] = tot[n] + 1, tot[b] + bytes
    local p = Bucket(net.prefix, tostring(prefix))
    p[n], p[b] = p[n] + 1, p[b] + bytes
    local cur = net.cur
    local cp = Bucket(cur, "p:" .. tostring(prefix))
    cp[n], cp[b] = cp[n] + 1, cp[b] + bytes
    if who then
        local w = Bucket(net.who, tostring(who))
        w[n], w[b] = w[n] + 1, w[b] + bytes
        local cw = Bucket(cur, "w:" .. tostring(who))
        cw[n], cw[b] = cw[n] + 1, cw[b] + bytes
    end
end
Perf._Net = PerfNet

-- Every 60 s: the minute that just ended becomes "the last minute".
NetRoll = function()
    if now() - net.windowAt < 59.5 then return end      -- (the sixth sample of 10 s: a hair under 60)
    net.last = { span = now() - net.windowAt, b = net.cur }
    net.cur, net.windowAt = {}, now()
end

-- The last full minute (or the one running, before the first ends): { span (s), prefixes = { { prefix, inN, inB,
-- outN, outB } } (most traffic first), senders = { { who, inN, inB } } (most messages first) }.
function Perf:Network()
    local src = net.last or { span = max(1, now() - net.windowAt), b = net.cur }
    local out = { span = src.span, prefixes = {}, senders = {} }
    for key, b in pairs(src.b) do
        local kind, name = key:sub(1, 2), key:sub(3)
        if kind == "p:" then
            out.prefixes[#out.prefixes + 1] = { prefix = name, inN = b.inN, inB = b.inB, outN = b.outN, outB = b.outB }
        elseif b.inN > 0 then
            out.senders[#out.senders + 1] = { who = name, inN = b.inN, inB = b.inB }
        end
    end
    table.sort(out.prefixes, function(x, y)
        local tx, ty = x.inB + x.outB, y.inB + y.outB
        if tx ~= ty then return tx > ty end
        return x.prefix < y.prefix
    end)
    table.sort(out.senders, function(x, y)
        if x.inN ~= y.inN then return x.inN > y.inN end
        return x.who < y.who
    end)
    return out
end

-- ChatThrottleLib (the copy at work, whoever loaded it): { avail (bytes it may send now), max (bytes a second),
-- queueing (messages wait) } or nil; and Comm's own: bytes handed over and not sent yet, messages dropped.
function Perf:Throttle()
    local ctl = ChatThrottleLib
    local out = {}
    if type(ctl) == "table" then
        out.avail = tonumber(ctl.avail)
        out.max = tonumber(ctl.MAX_CPS)
        out.queueing = ctl.bQueueing and true or false
        out.version = tonumber(ctl.version)
    end
    local Comm = ns.Comm
    if Comm then
        out.dropped = Comm.stats and Comm.stats.dropped or 0
        out.backlog = Comm.Backlog and Comm:Backlog() or nil
    end
    return out
end

-- The bundled ChatThrottleLib's version (Libs/AceComm-3.0/ChatThrottleLib.lua): equal to the copy at work's when
-- DisasterZone's copy (or the same version) is the one sending.
Perf.ctlOwnVersion = type(ChatThrottleLib) == "table" and tonumber(ChatThrottleLib.version) or nil

---------------------------------------------------------------------------
-- What holds memory
---------------------------------------------------------------------------

local function CountWidgets(f)
    local n = 1 + ((f.GetNumRegions and f:GetNumRegions()) or 0)
    if f.GetNumChildren and f:GetNumChildren() > 0 then
        local kids = { f:GetChildren() }
        for i = 1, #kids do n = n + CountWidgets(kids[i]) end
    end
    return n
end
Perf._CountWidgets = CountWidgets

-- Every page of the main window: { key, label, built, widgets, build (ms), show (ms), maxShow, shows }, the most
-- widgets first; pages not built yet last.
function Perf:Pages()
    local stats = ns.MainFrame and ns.MainFrame.GetPageStats and ns.MainFrame:GetPageStats() or {}
    local seen = {}
    for _, p in ipairs(stats) do
        if p.panel and not seen[p.panel] then
            seen[p.panel] = true
            p.widgets = CountWidgets(p.panel)
        end
    end
    table.sort(stats, function(a, b)
        local wa, wb = a.widgets or -1, b.widgets or -1
        if wa ~= wb then return wa > wb end
        return tostring(a.label) < tostring(b.label)
    end)
    return stats
end

-- The estimated size of a value (bytes) and its entries; strings counted once per call.
local function SizeOf(v, seen)
    local t = type(v)
    if t == "string" then
        if seen[v] then return 0, 0 end
        seen[v] = true
        return 25 + #v, 0
    elseif t ~= "table" or seen[v] then
        return 0, 0
    end
    seen[v] = true
    local bytes, entries = 56, 0
    for k, x in next, v do
        local kb, _ = SizeOf(k, seen)
        local xb, xe = SizeOf(x, seen)
        bytes = bytes + 40 + kb + xb
        entries = entries + 1 + xe
    end
    return bytes, entries
end
Perf._SizeOf = SizeOf

-- The saved variables (the TOC's), by section: { name = "DisasterZoneDB.lists", kb, entries }, biggest first.
function Perf:SavedSizes()
    local meta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local list = meta and meta(addonName, "SavedVariables") or "DisasterZoneDB"
    local out = {}
    for name in tostring(list):gmatch("[%w_]+") do
        local root = _G[name]
        if type(root) == "table" then
            for k, v in pairs(root) do
                local bytes, entries = SizeOf(v, {})
                out[#out + 1] = { name = name .. "." .. tostring(k), kb = bytes / 1024, entries = entries }
            end
        end
    end
    table.sort(out, function(a, b) return a.kb > b.kb end)
    return out
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Perf:Start()
    if not isDev or Perf.ticker then return end
    Perf:Sample()
    if C_Timer and C_Timer.NewTicker then
        Perf.ticker = C_Timer.NewTicker(SAMPLE_S, function() Perf:Sample() end)
    end
end

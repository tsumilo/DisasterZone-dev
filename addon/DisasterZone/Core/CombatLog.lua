if DisasterZoneBoot and DisasterZoneBoot.Run("Core/CombatLog.lua", ...) then return end -- DisasterZone Core/CombatLog.lua
-- One combat-log reader shared by Meters (Core/Meter.lua), My Log (Core/MyLog.lua) and the swing timer
-- (Core/SwingTimer.lua), plus the death-recap recorder Meters and My Log share.
--
-- The reader: COMBAT_LOG_EVENT_UNFILTERED is registered once, and only while someone subscribes (Meters while on,
-- My Log during a pull, the swing timer while it runs). Each event is read once (CombatLogGetCurrentEventInfo) and
-- handed to every subscriber as an event handler gets it: fn(event, timestamp, subevent, hideCaster, srcGUID,
-- srcName, srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags, a12, a13, ...) - the client's
-- positional layout, so each module keeps its own filtering. Nothing is allocated per event: the values travel as
-- arguments, and each subscriber runs through ns.SafeCall (an error in one never stops the others).
--
-- Death recaps: a ring of the last events to someone, each { t, kind, key, amount, src, hp, extra } (kind "d" damage
-- taken, "h" a heal, "m" a miss, "c" one of my casts; hp = health after it; extra = overkill / overheal / absorbed /
-- miss type). Entries are reused as the ring turns. Recap() copies the last seconds out, oldest first, with times
-- relative to the death. Meters store that order; My Log's saved recaps keep their 1.3.5 order (hp at 5, the source
-- at 6), converted where My Log writes them.
local addonName, ns = ...

local CombatLog = ns:NewModule("CombatLog")

local floor = math.floor

local EVENT = "COMBAT_LOG_EVENT_UNFILTERED"
CombatLog.EVENT = EVENT

---------------------------------------------------------------------------
-- The session clock combat timing runs on (GetTime: fight clocks, recaps, swing times). Saved stamps use Util.Now.
---------------------------------------------------------------------------

function CombatLog.Now() return GetTime() end

---------------------------------------------------------------------------
-- The reader
---------------------------------------------------------------------------

local byKey = {}                  -- [key] = fn
local order = {}                  -- keys in subscribe order
local list = {}                   -- the subscribers in order (a new table on every change: safe while dispatching)
local listening = false

local function Fan(l, n, ...)
    local probe = ns.PerfProbe    -- (the Performance page, while it measures: each subscriber weighed apart)
    if probe then return probe("event", EVENT, l, ...) end
    local SafeCall = ns.SafeCall
    for i = 1, n do SafeCall(l[i], EVENT, ...) end
end

local function OnEvent()
    local l = list
    local n = #l
    if n == 0 then return end
    return Fan(l, n, CombatLogGetCurrentEventInfo())
end

local function Rebuild()
    local l = {}
    for i = 1, #order do l[i] = byKey[order[i]] end
    list = l
    local want = #l > 0
    if want == listening then return end
    listening = want
    if want then ns:RegisterEvent(EVENT, OnEvent) else ns:UnregisterEvent(EVENT, OnEvent) end
end

-- fn(event, timestamp, subevent, ...) gets every combat-log event until Unsubscribe(key). Subscribing again under
-- the same key replaces the handler (keeping its place).
function CombatLog:Subscribe(key, fn)
    if type(fn) ~= "function" then error("CombatLog:Subscribe(key, fn): fn must be a function", 2) end
    if byKey[key] == fn then return end
    if byKey[key] == nil then order[#order + 1] = key end
    byKey[key] = fn
    Rebuild()
    -- (a tail call, so the Performance page names the subscriber's file rather than this one)
    if ns.PerfNote then return ns.PerfNote(fn) end
end

function CombatLog:Unsubscribe(key)
    if byKey[key] == nil then return end
    byKey[key] = nil
    for i = #order, 1, -1 do
        if order[i] == key then table.remove(order, i) end
    end
    Rebuild()
end

-- (on / off by one flag, as the modules' Listen(on) switches their events)
function CombatLog:SetSubscribed(key, fn, on)
    if on then return self:Subscribe(key, fn) end
    self:Unsubscribe(key)
end

function CombatLog:IsSubscribed(key) return byKey[key] ~= nil end
function CombatLog:IsListening() return listening end

---------------------------------------------------------------------------
-- Death recaps
---------------------------------------------------------------------------

function CombatLog.NewRing(size) return { pos = 0, size = size } end

-- One event into the ring (overwrites the oldest once it is full).
function CombatLog.Push(ring, t, kind, key, amount, src, hp, extra)
    local pos = ring.pos % ring.size + 1
    ring.pos = pos
    local e = ring[pos]
    if e then
        e[1], e[2], e[3], e[4], e[5], e[6], e[7] = t, kind, key, amount, src, hp, extra
    else
        ring[pos] = { t, kind, key, amount, src, hp, extra }
    end
end

function CombatLog.ClearRing(ring)
    for i = 1, ring.size do ring[i] = nil end
    ring.pos = 0
end

-- The ring's events from `window` seconds before t up to t, oldest first, as new entries whose time is relative to
-- t (rounded to 1 / per s), and the key and source of the last damage among them (the killing blow).
function CombatLog.Recap(ring, t, window, per)
    local out, by, bySrc = {}, nil, nil
    local size, pos = ring.size, ring.pos
    local lo, hi = t - window, t + 0.001
    for i = 1, size do
        local e = ring[(pos + i - 1) % size + 1]
        if e and e[1] >= lo and e[1] <= hi then
            out[#out + 1] = { floor((e[1] - t) * per + 0.5) / per, e[2], e[3], e[4], e[5], e[6], e[7] }
            if e[2] == "d" then by, bySrc = e[3], e[5] end
        end
    end
    return out, by, bySrc
end

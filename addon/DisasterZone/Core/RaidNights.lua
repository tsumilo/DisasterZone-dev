if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidNights.lua", ...) then return end -- DisasterZone: Core/RaidNights.lua
-- A team's raid nights (1.3.5): the nights of the week a team raids, so players see when they are expected before
-- they join it. Stored on the team record (Core/RaidPlan.lua: nt = the nights, nn = one note), written with the team
-- by its organizers. Pure functions; no UI and no network.
--
-- A night on the wire: { w = its start as minutes since Monday 00:00 in realm time (0..10079), m = how long, in
-- minutes (15..1425, steps of 15), o = true when it is optional }. Realm time, not UTC: a raid at 19:30 stays at
-- 19:30 when the clocks change. Shown in each player's own clock (as raid times are): Local / FromLocal move a night
-- between realm time and my clock.
local addonName, ns = ...

local RaidNights = ns:NewModule("RaidNights")

local floor = math.floor
local tsort, tconcat = table.sort, table.concat

local WEEK_MIN = 7 * 1440
RaidNights.MAX = 7                   -- nights a team keeps (one per day of the week)
RaidNights.MAX_NOTE = 120
RaidNights.STEP = 15                 -- start and length move in quarters of an hour
RaidNights.DAYS = { "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" }
RaidNights.SHORT = { "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }
RaidNights.LETTERS = { "M", "T", "W", "T", "F", "S", "S" }

local IsInt = ns.Util.IsInt

-- The nights from the wire (nt): a clean list sorted by start, nil when none is given, false when invalid. An empty
-- list (or false: "no nights", written by a client that knows them) is {}.
function RaidNights:Clean(nt)
    if nt == nil then return nil end
    if nt == false then return {} end
    if type(nt) ~= "table" then return false end
    local out, seen = {}, {}
    for i = 1, self.MAX + 1 do
        local n = nt[i]
        if n == nil then break end
        if i > self.MAX or type(n) ~= "table" then return false end
        if not IsInt(n.w, 0, WEEK_MIN - 1) or n.w % self.STEP ~= 0 then return false end
        if not IsInt(n.m, self.STEP, 1440 - self.STEP) or n.m % self.STEP ~= 0 then return false end
        if n.o ~= nil and n.o ~= true then return false end
        if seen[n.w] then return false end
        seen[n.w] = true
        out[#out + 1] = { w = n.w, m = n.m, o = n.o }
    end
    tsort(out, function(a, b) return a.w < b.w end)
    return out
end

-- The note (nn): one line, at most MAX_NOTE bytes; nil when none or not valid (a bad note is dropped, not refused).
function RaidNights:CleanNote(s)
    if type(s) ~= "string" then return nil end
    s = ns.Util.Trim(s)
    if s == "" or #s > self.MAX_NOTE or s:find("[%c|]") then return nil end
    return s
end

function RaidNights:Copy(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for i, n in ipairs(list) do out[i] = { w = n.w, m = n.m, o = n.o } end
    return out
end

-- Do two lists (nil = none) hold the same nights?
function RaidNights:Same(a, b)
    a, b = a or {}, b or {}
    if #a ~= #b then return false end
    for i, n in ipairs(a) do
        local o = b[i]
        if n.w ~= o.w or n.m ~= o.m or (n.o and true or false) ~= (o.o and true or false) then return false end
    end
    return true
end

-- How far my clock is ahead of realm time, in minutes (a multiple of 15, -720..720): my hour and minute against the
-- realm's (GetGameTime). The same zone (most players): 0.
function RaidNights:Offset()
    if not GetGameTime then return 0 end
    local h, m = GetGameTime()
    if type(h) ~= "number" or type(m) ~= "number" then return 0 end
    local t = date("*t", ns.Util.Now())
    local d = (t.hour * 60 + t.min) - (h * 60 + m)
    d = floor(d / self.STEP + 0.5) * self.STEP
    d = (d + 720) % 1440 - 720
    return d
end

-- A night in my clock: day (1 = Monday .. 7), start and end (minutes into the day; an end before the start runs
-- past midnight), optional.
function RaidNights:Local(n, offset)
    local w = (n.w + (offset or self:Offset())) % WEEK_MIN
    local s = w % 1440
    return floor(w / 1440) + 1, s, (s + n.m) % 1440, n.o and true or false
end

-- A night from my clock (day 1..7, start and end in minutes into the day) -> the wire form, or nil when it lasts no
-- time. Starts and lengths are put on the quarter hour.
function RaidNights:FromLocal(d, s, e, o, offset)
    local step = self.STEP
    s = floor(s / step + 0.5) * step % 1440
    local m = (floor(e / step + 0.5) * step - s) % 1440
    if m == 0 then return nil end
    local w = ((d - 1) * 1440 + s - (offset or self:Offset())) % WEEK_MIN
    return { w = w, m = m, o = o and true or nil }
end

-- The nights in my clock, in week order: { { d, s, e, o, n = the wire night }, ... }.
function RaidNights:LocalList(list, offset)
    offset = offset or self:Offset()
    local out = {}
    for _, n in ipairs(list or {}) do
        local d, s, e, o = self:Local(n, offset)
        out[#out + 1] = { d = d, s = s, e = e, o = o, n = n }
    end
    tsort(out, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.s < b.s
    end)
    return out
end

function RaidNights:Clock(m) return ("%02d:%02d"):format(floor(m / 60) % 24, m % 60) end

-- "Thu + Sun" (two), "Mon · Wed · Fri" (more), "Thursday" (one).
function RaidNights:DaysText(list, offset)
    local loc = self:LocalList(list, offset)
    if #loc == 1 then return self.DAYS[loc[1].d] end
    local parts = {}
    for _, x in ipairs(loc) do parts[#parts + 1] = self.SHORT[x.d] end
    return tconcat(parts, #parts == 2 and " + " or " · ")
end

-- "19:30 – 23:00" when every night has the same hours, else "Thu 19:30 · Sun 20:00"; second value "Sun optional"
-- (or "Fri + Sun optional"), nil when none is.
function RaidNights:TimesText(list, offset)
    local loc = self:LocalList(list, offset)
    if #loc == 0 then return "", nil end
    local same = true
    for i = 2, #loc do
        if loc[i].s ~= loc[1].s or loc[i].e ~= loc[1].e then same = false end
    end
    local times
    if same then
        times = self:Clock(loc[1].s) .. " – " .. self:Clock(loc[1].e)
    else
        local parts = {}
        for _, x in ipairs(loc) do parts[#parts + 1] = self.SHORT[x.d] .. " " .. self:Clock(x.s) end
        times = tconcat(parts, " · ")
    end
    local opt = {}
    for _, x in ipairs(loc) do if x.o then opt[#opt + 1] = self.SHORT[x.d] end end
    return times, #opt > 0 and (tconcat(opt, " + ") .. " optional") or nil
end

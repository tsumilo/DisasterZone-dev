if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Routine.lua", ...) then return end -- DisasterZone Games/Azeromon/Routine.lua
-- ns.AzeroRoutine: daily routines (Azeromon 0.27). A town NPC with a `day` list keeps to it by the realm clock
-- (G:Hour, the same clock as day and night), so every guildmate sees the same town:
--
--   day = {
--     { "00:00", inside = "post", label = "Asleep at the inn" },
--     { "06:10", path = { { 8, 22 }, { 8, 23 }, { 23, 23 }, { 23, 22 } }, face = "left", act = "smith",
--       label = "At the anvil", walk = "Off to the forge" },
--     { "18:00", path = { ... }, enter = "post", label = "Supper at the inn" },     -- walks, then goes inside
--     { "20:20", loop = { ... }, label = "Night patrol" },                          -- walks round and round
--     { "08:30", path = { ... }, away = true },                                     -- walks off the map
--   },
--   says = { { "07:00", "Forge is hot!" }, ... },                                   -- a bubble for that minute
--
-- A path is a list of waypoints (tiles, straight lines between them); a waypoint may hold a wait (seconds), the way
-- to face while waiting and a lamp (the map's def.lamps index): the lamplighter. People walk STEP seconds a tile from
-- the segment's start; whoever arrives late finds them where the clock says. Inside a building they sit at the
-- room's seats (def.seats). A map's lamps are lit from the minute the lamplighter's "on" walk reaches them until his
-- "off" walk does (UI.lua covers an unlit lamp's baked pool of light). A map's stall (def.stall) is open while its
-- keeper's act is "sell".
local addonName, ns = ...

local R = ns:NewModule("AzeroRoutine")
local G = ns.Azero
local Maps = ns.AzeroMaps

R.STEP = 0.32                -- seconds a tile (the player walks 0.24)
R.SEAT_EVERY = 1.0           -- seconds between checks of who is inside a room

local floor, abs, max = math.floor, math.abs, math.max

local function Minutes(t)
    if type(t) == "number" then return t end
    local h, m = tostring(t):match("^(%d+):(%d+)$")
    return (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
end

local DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
local function Dir(ax, ay, bx, by)
    if bx > ax then return "right" elseif bx < ax then return "left" elseif by < ay then return "up" end
    return "down"
end

-- A path's tiles: every tile on the straight lines between waypoints, with each waypoint's wait / face / lamp.
local function Expand(path)
    local tiles = {}
    for i, p in ipairs(path) do
        if i == 1 then
            tiles[1] = { x = p[1], y = p[2] }
        else
            local a = tiles[#tiles]
            local x, y = a.x, a.y
            while x ~= p[1] or y ~= p[2] do
                if x ~= p[1] then x = x + (p[1] > x and 1 or -1) else y = y + (p[2] > y and 1 or -1) end
                tiles[#tiles + 1] = { x = x, y = y, wait = 0 }
            end
        end
        local t = tiles[#tiles]
        t.wait, t.face, t.lamp = p.wait or 0, p.face, p.lamp
    end
    -- when each tile is reached and left (seconds from the segment's start)
    local clock = tiles[1].wait
    tiles[1].at, tiles[1].leave = 0, clock
    for i = 2, #tiles do
        clock = clock + R.STEP
        tiles[i].at = clock
        clock = clock + tiles[i].wait
        tiles[i].leave = clock
    end
    return tiles, clock
end

-- The parsed routine of an NPC definition (cached on the definition).
function R.Of(def)
    if type(def) ~= "table" or type(def.day) ~= "table" then return nil end
    if def._routine then return def._routine end
    local segs = {}
    for _, s in ipairs(def.day) do
        local seg = { t = Minutes(s[1]), src = s, label = s.label, walk = s.walk or s.label, face = s.face, act = s.act,
                      inside = s.inside, enter = s.enter, away = s.away, lamps = s.lamps }
        if s.path then seg.tiles, seg.total = Expand(s.path) end
        if s.loop then seg.loop = Expand(s.loop) end
        segs[#segs + 1] = seg
    end
    table.sort(segs, function(a, b) return a.t < b.t end)
    for i, seg in ipairs(segs) do
        local nxt = segs[i % #segs + 1]
        seg.dur = ((nxt.t - seg.t) % 1440) * 60                          -- seconds until the next segment
        if seg.dur == 0 then seg.dur = 1440 * 60 end
        if seg.loop then
            local n = #seg.loop - 1                                       -- tiles a lap (the loop is closed)
            local laps = max(1, floor(seg.dur / (n * R.STEP) + 0.5))
            seg.loopStep = seg.dur / (laps * n)
        end
    end
    local says = {}
    for _, l in ipairs(def.says or {}) do says[#says + 1] = { t = Minutes(l[1]), text = l[2] } end
    def._routine = { segs = segs, says = says }
    return def._routine
end

-- The clock in minutes since midnight. Tests set G.clockHour (exact). In game the realm only tells the minute, so a
-- local clock runs on GetTime and keeps step with the realm's minute without ever jumping: a little faster while
-- it is behind the realm's minute, a little slower while it is more than a minute ahead. Only when it is far off
-- (the realm clock changed, a long pause) does it take the realm's minute at once.
R.CLOCK_CATCH = 1.5          -- the local clock's pace while behind the realm's minute
R.CLOCK_HOLD = 0.6           -- its pace while more than a minute ahead
local clock, clockAt
function R.Now()
    if G.clockHour then return (G.clockHour * 60) % 1440 end
    local realm = floor(G:Hour() * 60 + 0.5) % 1440
    local t = GetTime and GetTime() or 0
    if not clock then clock, clockAt = realm, t return clock end
    local dt = math.max(0, t - clockAt)
    clockAt = t
    local diff = ((clock - realm + 720) % 1440) - 720                -- local minus realm (minutes, round midnight)
    if diff < -5 or diff > 5 then
        clock = realm
    else
        local rate = (diff < 0 and R.CLOCK_CATCH) or (diff > 1 and R.CLOCK_HOLD) or 1
        clock = (clock + dt * rate / 60) % 1440
    end
    return clock
end

function R._ResetClock() clock, clockAt = nil, nil end

-- The segment at a time, and the seconds since it began.
function R.SegAt(rt, now)
    local segs = rt.segs
    local seg = segs[#segs]
    for _, s in ipairs(segs) do if s.t <= now then seg = s end end
    return seg, ((now - seg.t) % 1440) * 60
end

-- Where an NPC is at a time: { hidden, inside (map id), x, y, face, act, label, walking, seg, i (path tile) }.
function R.State(def, now)
    local rt = R.Of(def)
    if not rt then return nil end
    local seg, e = R.SegAt(rt, now or R.Now())
    if seg.inside then return { hidden = true, inside = seg.inside, label = seg.label, seg = seg } end
    if seg.loop then
        local n = #seg.loop - 1
        local i = floor(e / seg.loopStep) % n + 1
        local a, b = seg.loop[i], seg.loop[i + 1]
        return { x = a.x, y = a.y, face = Dir(a.x, a.y, b.x, b.y), label = seg.label, walking = true, seg = seg, i = i }
    end
    local tiles = seg.tiles
    if not tiles then return { hidden = true, label = seg.label, seg = seg } end
    if e >= seg.total then
        local last = tiles[#tiles]
        if seg.enter then return { hidden = true, inside = seg.enter, label = seg.label, seg = seg } end
        if seg.away then return { hidden = true, away = true, label = seg.label, seg = seg } end
        return { x = last.x, y = last.y, face = seg.face or last.face or "down", act = seg.act, label = seg.label,
                 seg = seg, i = #tiles }
    end
    local i = 1
    for k = 1, #tiles do if tiles[k].at <= e then i = k end end
    local t = tiles[i]
    if e < t.leave and t.wait > 0 then
        return { x = t.x, y = t.y, face = t.face or "down", act = t.lamp and "light" or nil, label = seg.walk,
                 walking = true, seg = seg, i = i }
    end
    local nx = tiles[i + 1] or t
    return { x = t.x, y = t.y, face = Dir(t.x, t.y, nx.x, nx.y), label = seg.walk, walking = true, seg = seg, i = i }
end

-- A line to say now (a bubble), if any: each line shows for the minute it is set at.
function R.Says(def, now)
    local rt = R.Of(def)
    if not rt then return nil end
    now = now or R.Now()
    for _, l in ipairs(rt.says) do
        if ((now - l.t) % 1440) < 1 then return l.text end
    end
end

---------------------------------------------------------------------------
-- Who keeps a routine where, lamps and stalls
---------------------------------------------------------------------------

-- Every NPC with a routine: { map = id, def = def } (built once, from the map definitions).
local people
function R.People()
    if people then return people end
    people = {}
    local ids = {}
    for id, def in pairs(Maps) do if type(def) == "table" and def.npcs then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        for _, n in ipairs(Maps[id].npcs) do if type(n.day) == "table" then people[#people + 1] = { map = id, def = n } end end
    end
    return people
end

-- When each lamp of a map is lit and put out (minutes): the lamplighter's "on" and "off" walks.
function R.LampTimes(mapId)
    local def = Maps[mapId]
    if not (def and def.lamps) then return nil end
    if def._lampTimes then return def._lampTimes end
    local times = {}
    for _, n in ipairs(def.npcs or {}) do
        local rt = R.Of(n)
        for _, seg in ipairs(rt and rt.segs or {}) do
            if seg.lamps and seg.tiles then
                for _, t in ipairs(seg.tiles) do
                    if t.lamp then
                        times[t.lamp] = times[t.lamp] or {}
                        times[t.lamp][seg.lamps] = (seg.t + t.at / 60) % 1440
                    end
                end
            end
        end
    end
    def._lampTimes = times
    return times
end

-- Is the map's lamp i lit now? (a map without a lamplighter keeps its lamps lit)
function R.LampLit(mapId, i, now)
    local times = R.LampTimes(mapId)
    local t = times and times[i]
    if not (t and t.on and t.off) then return true end
    now = (now or R.Now()) % 1440
    if t.on < t.off then return now >= t.on and now < t.off end
    return now >= t.on or now < t.off
end

-- The lamp index on a tile of a map, if one of its def.lamps stands there.
function R.LampAt(mapId, x, y)
    local def = Maps[mapId]
    for i, l in ipairs(def and def.lamps or {}) do if l[1] == x and l[2] == y then return i end end
end

-- How many people's day has them inside a room now (counted once a second per room).
local counts = {}
function R.InsideCount(mapId, now)
    now = now or R.Now()
    local c = counts[mapId]
    if c and math.abs(now - c.at) < 1 / 60 then return c.n end
    local n = 0
    for _, p in ipairs(R.People()) do
        local st = R.State(p.def, now)
        if st and st.inside == mapId then n = n + 1 end
    end
    counts[mapId] = { at = now, n = n }
    return n
end

-- Is the map's stall open (its keeper selling)?
function R.StallOpen(mapId, now)
    local def = Maps[mapId]
    local st = def and def.stall
    if not st then return false end
    for _, n in ipairs(def.npcs or {}) do
        if n.id == st.keeper then
            local s = R.State(n, now)
            return s ~= nil and s.act == "sell"
        end
    end
    return false
end

-- The stall's tiles show it open or shut (stall_x_y / stallshut_x_y).
function R.ApplyStall(m, now)
    local st = m and m.def.stall
    if not st then return end
    local open = R.StallOpen(m.id, now)
    if m.stallOpen == open then return end
    m.stallOpen = open
    for dy = 0, 2 do
        for dx = 0, 1 do
            m.over[m.key(st.x + dx, st.y + dy)] = string.format("%s_%d_%d", open and "stall" or "stallshut", dx, dy)
        end
    end
end

---------------------------------------------------------------------------
-- Moving the NPCs (G:UpdateNpcs calls Step for every NPC with a routine)
---------------------------------------------------------------------------

local function Occupied(x, y, self)
    local s = G.save
    if s.x == x and s.y == y then return true end
    if G.moving and G.moving.fromX == x and G.moving.fromY == y then return true end
    local other = G:NpcAt(x, y)
    return other ~= nil and other ~= self
end

-- Puts a routine NPC where the clock says (on entering a map, or when it is very far behind).
function R.Place(n, now)
    local st = R.State(n.def, now)
    if not st then return end
    n.routine = true
    n.act, n.label = st.act, st.label
    n.seg, n.ti = st.seg, st.i
    if st.hidden then n.hidden = true return end
    n.hidden = false
    n.x, n.y, n.face = st.x, st.y, st.face or n.face
    n.moving = nil
end

R.HURRY = 0.55          -- a step's time (share of STEP) while the walker is more than a tile behind the clock
R.SNAP = 60             -- tiles behind beyond which it is simply placed where the clock says

local function TilesOf(seg) return seg and (seg.tiles or seg.loop) end

-- On its old segment, the index a walker still has to reach before the clock's segment can begin: the end of a
-- path (a door, the end of a walk), or round a loop to the tile where the next walk starts. nil: nothing left.
local function Unfinished(n, nextFirst)
    local seg = n.seg
    if not (seg and n.ti) then return nil end
    if seg.tiles then
        return n.ti < #seg.tiles and #seg.tiles or nil
    end
    if seg.loop and nextFirst then
        for k = 1, #seg.loop - 1 do
            local t = seg.loop[k]
            if t.x == nextFirst.x and t.y == nextFirst.y then return k ~= n.ti and k or nil end
        end
    end
    return nil
end

-- A walker keeps its own place on its path (n.seg, n.ti) and walks it tile by tile, never jumping: it hurries while
-- it is behind the clock (the player stood in the way, someone talked, a slow frame), goes all the way round a loop,
-- finishes a walk to a door before it goes in, and only then starts the clock's next segment.
function R.Step(n, dt, now)
    local st = R.State(n.def, now)
    if not st then return end
    n.label = st.label
    if n.hidden then                        -- comes out of a door / back on the road
        if st.hidden or Occupied(st.x, st.y, n) then return end
        n.hidden = false
        n.x, n.y, n.face, n.seg, n.ti = st.x, st.y, st.face or n.face, st.seg, st.i
        n.act = st.act
        return
    end
    -- what to walk: the rest of the segment it is on, then the clock's
    local seg, want = n.seg, nil
    if st.seg == n.seg then
        want = st.i or (n.seg and n.seg.tiles and n.ti and n.ti < #n.seg.tiles and #n.seg.tiles) or nil
    else
        local nt = TilesOf(st.seg)
        local first = nt and nt[1]
        local rest = Unfinished(n, first)
        if rest then
            want = rest                     -- finish this part of the day first
        elseif first and first.x == n.x and first.y == n.y then
            seg, want, n.seg, n.ti = st.seg, st.i, st.seg, 1
        elseif st.hidden then
            n.hidden = true                 -- walked in through its door, or off the map
            return
        else
            R.Place(n, now)
            return
        end
    end
    if not want then                        -- the clock has it inside / away, and the walk is done
        if st.hidden then n.hidden = true end
        return
    end
    local tiles = TilesOf(seg)
    local L = seg.loop and (#seg.loop - 1)
    local lag = L and ((want - n.ti) % L) or (want - n.ti)
    if lag <= 0 then
        n.blocked = nil
        if seg == st.seg then
            n.act = st.act
            if not st.walking or st.act == "light" then n.face = st.face or n.face end
        end
        if st.hidden and seg == st.seg then n.hidden = true end
        return
    end
    n.act = nil
    if lag > R.SNAP then R.Place(n, now) return end
    if not G:IsFree() then return end       -- someone is talking: the town waits
    local nx = tiles[n.ti + 1]
    if not nx then R.Place(n, now) return end
    if Occupied(nx.x, nx.y, n) then
        n.blocked = (n.blocked or 0) + dt   -- the player stands in the way: wait for them, then hurry on
        return
    end
    n.blocked = nil
    n.face = Dir(n.x, n.y, nx.x, nx.y)
    n.fromX, n.fromY = n.x, n.y
    n.x, n.y = nx.x, nx.y
    n.ti = (L and n.ti + 1 > L) and 1 or n.ti + 1
    n.moving = { t = 0, dur = lag > 1 and R.STEP * R.HURRY or R.STEP }
end

---------------------------------------------------------------------------
-- Inside: the people whose routine has them in this room sit at its seats
---------------------------------------------------------------------------

function R.Visitors(self, m, now)
    local seats = m and m.def.seats
    if not seats then return end
    local keep = {}
    for _, p in ipairs(R.People()) do
        local st = R.State(p.def, now)
        if st and st.inside == m.id then keep[p.def] = true end
    end
    -- those who left
    for i = #self.npcs, 1, -1 do
        local n = self.npcs[i]
        if n.visitor and not keep[n.def] then table.remove(self.npcs, i) end
    end
    local here = {}
    for _, n in ipairs(self.npcs) do if n.visitor then here[n.def] = n end end
    local free = {}
    for _, seat in ipairs(seats) do
        local taken = (self.save.x == seat[1] and self.save.y == seat[2]) or self:NpcAt(seat[1], seat[2])
        if not taken then free[#free + 1] = seat end
    end
    for _, p in ipairs(R.People()) do
        if keep[p.def] and not here[p.def] and #free > 0 then
            local seat = table.remove(free, 1)
            self.npcs[#self.npcs + 1] = { def = p.def, id = p.def.id, x = seat[1], y = seat[2], face = seat[3] or "down",
                homeX = seat[1], homeY = seat[2], visitor = true, wanderIn = 9999 }
        end
    end
end

-- On entering a map: routine NPCs where the clock puts them, visitors in their seats, the stall open or shut.
function R.Enter(self, m)
    local now = R.Now()
    for _, n in ipairs(self.npcs) do if n.def.day then R.Place(n, now) end end
    m.stallOpen = nil
    R.ApplyStall(m, now)
    R.Visitors(self, m, now)
    R.seatT = 0
end

-- Every frame (G:UpdateNpcs): the stall, and now and then who is inside.
function R.Update(self, dt)
    local m = self.map
    if not m then return end
    local now = R.Now()
    R.ApplyStall(m, now)
    if m.def.seats then
        R.seatT = (R.seatT or 0) + dt
        if R.seatT >= R.SEAT_EVERY and self:IsFree() then
            R.seatT = 0
            R.Visitors(self, m, now)
        end
    end
    return now
end

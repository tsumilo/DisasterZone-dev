if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GuildMap.lua", ...) then return end -- DisasterZone: where guildmates are (Guild > Map).
-- Opt-in, and give to get: only members who share see the others (settings.map.share "zone" | "exact"; "off", or
-- "unset" until they choose). What you see matches what you share: sharing your zone only shows everyone by zone.
-- Traffic (prefix CDLq, GUILD) only while somebody looks:
--   MQ  { s }            a sharer opened the map (again every ASK_EVERY s while it stays open): sharers answer
--   MP  { m, x, y, s, i, n, r, a, z, h }   where I am: m the zone's uiMapID, x / y 0..10000 on it (exact only), s
--                        the subzone, i / n the instance's id / name inside one (r: a raid), a away, z zone only, h hidden (in a
--                        battleground or arena: nobody sees me there). Sent on a zone change, an ask, and while
--                        anyone looked in the last VIEW_TTL s whenever I moved (checked every CHECK s), at least
--                        every HEARTBEAT s.
--   MX  {}               I stopped sharing: drop me.
-- What I learn: live[key] (this session, dropped after LIVE_TTL s of silence or when they log off) and the zone they
-- were last seen in, db.mapSeen[guildKey][key] = { m, i, n, t } (the Members card's "Last seen in").
-- Instances have no position: a member inside one stands at its entrance (ENTRANCES, approximate, by instance id).
local addonName, ns = ...

local GuildMap = ns:NewModule("GuildMap")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, floor, abs = type, pairs, ipairs, tonumber, tostring, math.floor, math.abs

local CHECK = 2            -- s between looks at my position while somebody watches
local VIEW_TTL = 75        -- s an ask keeps me streaming
local ASK_EVERY = 45       -- s between my asks while my map is open
local HEARTBEAT = 30       -- s: an unchanged position is sent again at least this often while watched
local LIVE_TTL = 100       -- s of silence before a member leaves the map
local MOVE = 0.0015        -- of the zone map: smaller steps are not sent
local ZONE_GAP = 20        -- s between zone-change sends
local SCALE = 10000        -- x / y on the wire

GuildMap.CONTINENTS = { { id = 1414, name = "Kalimdor" }, { id = 1415, name = "Eastern Kingdoms" },
    { id = 1945, name = "Outland" } }

-- Where an instance's entrance is: { zone uiMapID, x, y } (0..1 on that zone's map; approximate).
local ENTRANCES = {
    -- The Burning Crusade
    [532] = { 1430, 0.469, 0.747 },   -- Karazhan (Deadwind Pass)
    [565] = { 1949, 0.683, 0.240 },   -- Gruul's Lair
    [544] = { 1944, 0.466, 0.528 },   -- Magtheridon's Lair
    [543] = { 1944, 0.476, 0.536 },   -- Hellfire Ramparts
    [542] = { 1944, 0.460, 0.518 },   -- The Blood Furnace
    [540] = { 1944, 0.477, 0.520 },   -- The Shattered Halls
    [548] = { 1946, 0.504, 0.409 },   -- Serpentshrine Cavern
    [547] = { 1946, 0.490, 0.360 },   -- The Slave Pens
    [546] = { 1946, 0.542, 0.344 },   -- The Underbog
    [545] = { 1946, 0.502, 0.333 },   -- The Steamvault
    [550] = { 1953, 0.737, 0.637 },   -- Tempest Keep
    [554] = { 1953, 0.706, 0.697 },   -- The Mechanar
    [553] = { 1953, 0.717, 0.550 },   -- The Botanica
    [552] = { 1953, 0.744, 0.577 },   -- The Arcatraz
    [557] = { 1952, 0.396, 0.577 },   -- Mana-Tombs
    [558] = { 1952, 0.343, 0.656 },   -- Auchenai Crypts
    [556] = { 1952, 0.445, 0.656 },   -- Sethekk Halls
    [555] = { 1952, 0.396, 0.736 },   -- Shadow Labyrinth
    [564] = { 1948, 0.710, 0.464 },   -- Black Temple
    [534] = { 1446, 0.662, 0.493 },   -- Hyjal Summit (Caverns of Time)
    [560] = { 1446, 0.662, 0.493 },   -- Old Hillsbrad Foothills
    [269] = { 1446, 0.662, 0.493 },   -- The Black Morass
    [568] = { 1942, 0.820, 0.643 },   -- Zul'Aman
    [580] = { 1957, 0.443, 0.457 },   -- Sunwell Plateau
    [585] = { 1957, 0.613, 0.309 },   -- Magisters' Terrace
    -- the old world's raids
    [409] = { 1427, 0.348, 0.853 },   -- Molten Core (Blackrock Mountain)
    [469] = { 1427, 0.348, 0.853 },   -- Blackwing Lair
    [249] = { 1445, 0.526, 0.768 },   -- Onyxia's Lair
    [309] = { 1434, 0.539, 0.176 },   -- Zul'Gurub
    [509] = { 1451, 0.286, 0.924 },   -- Ruins of Ahn'Qiraj
    [531] = { 1451, 0.286, 0.924 },   -- Temple of Ahn'Qiraj
}

local live = {}            -- [key] = { m, x, y, s, i, n, a, z, at = GetTime(), ts = Util.Now() (server time) }
local viewers = {}         -- [key] = GetTime() of their last ask
local viewing = false      -- my map is open
local sent                 -- what I sent last: { m, x, y, s, i, a, z, h, at }
local pumping = false
local asking = false
local mapCache = {}        -- [uiMapID] = C_Map.GetMapInfo answer (false: none)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local MODES = { off = true, zone = true, exact = true }

-- "unset" (not asked yet) | "off" | "zone" | "exact"
function GuildMap:GetShare()
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("map.share")
    return MODES[v] and v or "unset"
end

function GuildMap:IsSharing()
    local v = self:GetShare()
    return v == "zone" or v == "exact"
end

-- Am I hidden right now (sharing, but in a battleground or arena)?
function GuildMap:IsHidden()
    local inInst, kind = false, nil
    if IsInInstance then inInst, kind = IsInInstance() end
    return inInst and (kind == "pvp" or kind == "arena") and true or false
end

local SendPosition, Ask, StartPump

function GuildMap:SetShare(mode)
    if not MODES[mode] then return false end
    local was = self:IsSharing()
    if not (ns.DB and ns.DB.SetSetting) then return false end
    ns.DB:SetSetting("map.share", mode)
    local now = self:IsSharing()
    if was and not now then
        wipe(live)
        sent = nil
        if ns.Comm then ns.Comm:Send({ t = "MX" }, "GUILD", nil, "map") end
    elseif now then
        sent = nil
        SendPosition(true)
        if not was or viewing then Ask() end
    end
    ns:Fire("GUILDMAP_UPDATED")
    return true
end

-- Guildmates' dots on Blizzard's world map too (UI/GuildMapUI.lua).
function GuildMap:GetShowOnWorldMap()
    local v = ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("map.blizzard")
    return v ~= false
end

function GuildMap:SetShowOnWorldMap(on)
    if ns.DB and ns.DB.SetSetting then ns.DB:SetSetting("map.blizzard", on and true or false) end
    ns:Fire("GUILDMAP_UPDATED")
end

---------------------------------------------------------------------------
-- Maps
---------------------------------------------------------------------------

local function MapInfo(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local c = mapCache[id]
    if c == nil then
        local ok, info = false, nil
        if C_Map and C_Map.GetMapInfo then ok, info = pcall(C_Map.GetMapInfo, id) end
        c = (ok and type(info) == "table") and info or false
        mapCache[id] = c
    end
    return c or nil
end

function GuildMap:GetMapName(id)
    local info = MapInfo(id)
    return info and info.name or nil
end

-- The continent (uiMap type 2) a map lies on, or nil.
function GuildMap:ContinentOf(id)
    local seen = 0
    local info = MapInfo(id)
    while info and seen < 8 do
        if info.mapType == 2 then return info.mapID end
        info = MapInfo(info.parentMapID)
        seen = seen + 1
    end
    return nil
end

-- (x, y) on map `from` -> (x, y) on map `to` (both 0..1), through world coordinates; nil when they don't share a
-- continent.
function GuildMap:Translate(from, x, y, to)
    from, to = tonumber(from), tonumber(to)
    if not (from and to and x and y) then return nil end
    if from == to then return x, y end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
    local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, from, CreateVector2D(x, y))
    if not ok or not cont or not world then return nil end
    local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, to)
    if not ok2 or not pos then return nil end
    return pos:GetXY()
end

-- Where an entry stands on map `to`: x, y (0..1) or nil. A zone-only entry (or one I may only see by zone) stands
-- in its zone's middle; one in an instance at the instance's entrance.
function GuildMap:PlaceOn(e, to)
    if not e then return nil end
    local m, x, y = e.m, e.x, e.y
    if e.i and ENTRANCES[e.i] then
        local en = ENTRANCES[e.i]
        m, x, y = en[1], en[2], en[3]
    elseif not m then
        return nil
    elseif e.z or not x then
        x, y = 0.5, 0.5
    end
    return self:Translate(m, x, y, to)
end

-- The raids among the instances (a sender older than the r field: their instance id says it): the TBC raids
-- (ns.Data.RaidMeta, through ItemDB) and the classic ones.
local CLASSIC_RAIDS = { [409] = true, [469] = true, [249] = true, [309] = true, [509] = true, [531] = true }

-- Is an entry inside a raid (rather than a dungeon)?
function GuildMap:IsRaid(e)
    return e and e.i and (e.r or CLASSIC_RAIDS[e.i] or ns.ItemDB:GetRaidByInstance(e.i)) and true or false
end

function GuildMap:GetEntrance(instanceID)
    local en = ENTRANCES[tonumber(instanceID) or 0]
    if not en then return nil end
    return en[1], en[2], en[3]
end

---------------------------------------------------------------------------
-- Where I am
---------------------------------------------------------------------------

-- My position as I would send it: { m, x, y, s, i, n, a, z, h } (x / y 0..1), or nil (no map known).
function GuildMap:GetMine()
    local share = self:GetShare()
    local e = { a = (UnitIsAFK and UnitIsAFK("player")) and true or nil, z = share == "zone" or nil }
    if self:IsHidden() then
        e.h = true
        return e
    end
    local inInst, kind = false, nil
    if IsInInstance then inInst, kind = IsInInstance() end
    if inInst and (kind == "party" or kind == "raid" or kind == "scenario") then
        local name, _, _, _, _, _, _, id = GetInstanceInfo()
        e.i, e.n, e.r = tonumber(id), name, kind == "raid" or nil
        return e
    end
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    -- (a cave or a building's micro map: its zone's)
    local info = MapInfo(map)
    local hops = 0
    while info and info.mapType and info.mapType > 3 and hops < 4 do
        info = MapInfo(info.parentMapID)
        hops = hops + 1
    end
    if not info then return nil end
    e.m = info.mapID
    if not e.z and C_Map.GetPlayerMapPosition then
        local ok, pos = pcall(C_Map.GetPlayerMapPosition, e.m, "player")
        if ok and pos then
            local x, y = pos:GetXY()
            if x and y and (x > 0 or y > 0) then e.x, e.y = x, y end
        end
    end
    local sub = GetSubZoneText and GetSubZoneText() or ""
    if sub ~= "" and sub ~= e.n then e.s = sub:sub(1, 40) end
    return e
end

local function Wire(e)
    local msg = { t = "MP" }
    if e.h then msg.h = 1 return msg end
    msg.m, msg.i, msg.n, msg.s = e.m, e.i, e.n and e.n:sub(1, 40), e.s
    if e.r then msg.r = 1 end
    if e.x and e.y and not e.z then msg.x, msg.y = floor(e.x * SCALE + 0.5), floor(e.y * SCALE + 0.5) end
    if e.a then msg.a = 1 end
    if e.z then msg.z = 1 end
    return msg
end

local function Moved(a, b)
    if not a or not b then return true end
    if a.m ~= b.m or a.i ~= b.i or a.h ~= b.h or a.a ~= b.a or a.z ~= b.z or a.s ~= b.s then return true end
    if (a.x == nil) ~= (b.x == nil) then return true end
    if a.x and (abs(a.x - b.x) > MOVE or abs(a.y - b.y) > MOVE) then return true end
    return false
end

-- Sends my position when it changed (or force); true if something went out.
SendPosition = function(force)
    if not GuildMap:IsSharing() or not ns.Comm or not IsInGuild() then return false end
    local e = GuildMap:GetMine()
    if not e then return false end
    local now = GetTime()
    if not force and not Moved(e, sent) and sent and now - sent.at < HEARTBEAT then return false end
    if sent and sent.h and e.h then return false end   -- (hidden: said once)
    if ns.Comm:Send(Wire(e), "GUILD", nil, "map") then
        e.at = now
        sent = e
        return true
    end
    return false
end

local function Watched()
    local now = GetTime()
    for key, t in pairs(viewers) do
        if now - t < VIEW_TTL then return true end
        viewers[key] = nil
    end
    return false
end

local function Pump()
    if not GuildMap:IsSharing() or not Watched() then
        pumping = false
        return
    end
    SendPosition(false)
    Util.After(CHECK, Pump)
end

StartPump = function()
    if pumping then return end
    pumping = true
    Util.After(CHECK, Pump)
end

-- (my own jitter: answers to one ask spread over a few seconds instead of all at once)
local function Jitter(span)
    return Util.Jitter(floor(GetTime()), span)
end

Ask = function()
    if not GuildMap:IsSharing() or not ns.Comm then return end
    ns.Comm:Send({ t = "MQ", s = GuildMap:GetShare() }, "GUILD", nil, "map")
end

local function AskLoop()
    if not viewing or not GuildMap:IsSharing() then
        asking = false
        return
    end
    Ask()
    Util.After(ASK_EVERY, AskLoop)
end

-- The map page opened (true) / closed: while open (and sharing) I ask now and then, so sharers keep streaming.
function GuildMap:SetViewing(on)
    on = on and true or false
    if on == viewing then return end
    viewing = on
    if on and self:IsSharing() and not asking then
        asking = true
        AskLoop()
    end
end

function GuildMap:IsViewing() return viewing end

---------------------------------------------------------------------------
-- What I learn
---------------------------------------------------------------------------

local function SeenBucket(create)
    return (ns.DB:GuildBucket("mapSeen", create))
end

local function Str(v, n)
    return type(v) == "string" and v ~= "" and v:sub(1, n or 40) or nil
end

local function Num(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v < lo or v > hi then return nil end
    return v
end

-- (at most every 0.25 s, also while positions keep coming: a debounce would never fire in a steady stream)
local firePending = false
local function FireSoon()
    if firePending then return end
    firePending = true
    Util.After(0.25, function()
        firePending = false
        ns:Fire("GUILDMAP_UPDATED")
    end)
end

local function OnPosition(key, msg)
    if not GuildMap:IsSharing() then return end   -- (give to get)
    if msg.h then
        if live[key] then
            live[key] = nil
            ns:Fire("GUILDMAP_UPDATED")
        end
        return
    end
    local e = { m = Num(msg.m, 1, 100000), i = Num(msg.i, 1, 100000), n = Str(msg.n), s = Str(msg.s),
                r = msg.r and true or nil, a = msg.a and true or nil, z = msg.z and true or nil,
                at = GetTime(), ts = Util.Now() }
    local x, y = Num(msg.x, 0, SCALE), Num(msg.y, 0, SCALE)
    if x and y and not e.z then e.x, e.y = x / SCALE, y / SCALE end
    if not e.m and not e.i then return end
    live[key] = e
    local seen = SeenBucket(true)
    if seen then seen[key] = { m = e.m, i = e.i, n = e.n, t = e.ts } end
    FireSoon()
end

local function OnAsk(key, msg)
    if not GuildMap:IsSharing() then return end
    if msg.s ~= "zone" and msg.s ~= "exact" then return end   -- (only sharers see the others)
    viewers[key] = GetTime()
    StartPump()
    local delay = 0.3 + Jitter(2.2)
    Util.After(delay, function() SendPosition(true) end)
end

local function OnStop(key)
    if live[key] then
        live[key] = nil
        ns:Fire("GUILDMAP_UPDATED")
    end
    viewers[key] = nil
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- Demo mode: the fake guild spread over the world, crowded like a raid night: the demo roster first (fixed spots),
-- then more made-up sharers (demo only, never in the roster) in cities, raids and zones; some of them walk, so the
-- map's gliding shows. Same layout every time.
local DEMO_SPOTS = {
    { 1955, 0.52, 0.42, "Terrace of Light" }, { 1955, 0.56, 0.47, "Terrace of Light" }, { 1955, 0.47, 0.50 },
    { 1955, 0.75, 0.36, "Lower City" }, { 1955, 0.71, 0.47, "Lower City" }, { 1955, 0.29, 0.30, "Aldor Rise" },
    { 1955, 0.27, 0.46, "Aldor Rise" }, { 1955, 0.44, 0.72, "Scryer's Tier" }, { 1955, 0.51, 0.80, "Scryer's Tier" },
    { 1951, 0.41, 0.44, "Halaa", w = true }, { 1951, 0.55, 0.37, "Garadar" }, { 1951, z = true },
    { 1953, 0.33, 0.64, "Area 52" }, { 1953, 0.55, 0.22, "Manaforge Ultris", w = true },
    { i = 555 }, { i = 555 }, { i = 555 }, { 1948, 0.62, 0.30, "Wildhammer Stronghold", a = true },
    { 1944, 0.56, 0.62, "Honor Hold", w = true },
}
-- (zone, x, y, subzone, how many, spread) for the made-up ones; i = an instance instead
local DEMO_GROUPS = {
    { 1955, 0.50, 0.46, "Terrace of Light", 7, 0.08 }, { 1955, 0.72, 0.42, "Lower City", 4, 0.06 },
    { i = 564, n = 10 }, { i = 532, n = 10 }, { i = 548, n = 6 },
    { 1944, 0.56, 0.38, "Thrallmar", 3, 0.04 }, { 1946, 0.68, 0.48, "Cenarion Refuge", 3, 0.05 },
    { 1946, 0.19, 0.51, "Sporeggar", 2, 0.03 }, { 1949, 0.62, 0.39, "Sylvanaar", 2, 0.04 },
    { 1952, 0.56, 0.53, "Allerian Stronghold", 2, 0.03 }, { 1953, 0.32, 0.66, "Area 52", 3, 0.04 },
    { 1957, 0.48, 0.30, "Sun's Reach", 3, 0.05 }, { 1446, 0.51, 0.29, "Gadgetzan", 2, 0.03 },
}
local DEMO_NAMES = { "Aeli", "Bram", "Cora", "Dusk", "Eldr", "Fenn", "Gael", "Hrot", "Isla", "Jarn", "Kael", "Lyra",
    "Mord", "Nyx", "Orin", "Pell", "Quor", "Rhea", "Syl", "Thal", "Ulda", "Vex", "Wynn", "Xan", "Yri", "Zul" }
local DEMO_ENDS = { "and", "wyn", "ric", "a", "os", "ith", "ar", "elle" }
local DEMO_CLASSES = ns.CLASSES
local DUNGEON_NAMES = { [555] = "Shadow Labyrinth" }   -- (the demo's raids are named by ItemDB)
local demoClass = {}

-- A demo group's instance name: the dungeon's, or the raid's from the item data.
local function InstanceName(i)
    if DUNGEON_NAMES[i] then return DUNGEON_NAMES[i] end
    local _, raid = ns.ItemDB:GetRaidByInstance(i)
    return raid and raid.name or nil
end

local Demoing = Util.DemoOn

function GuildMap:IsDemo() return Demoing() end

-- A made-up demo sharer's class (they are not in the roster).
function GuildMap:GetDemoClass(key) return demoClass[key] end

local function DemoEntries()
    if not Demoing() then return nil end
    local out = {}
    local now, ts = GetTime(), Util.Now()
    local function put(key, spot, k)
        local e = { m = spot[1], x = spot[2], y = spot[3], s = spot[4], z = spot.z, a = spot.a, i = spot.i,
                    at = now - (k % 7) * 3, ts = ts - (k % 7) * 3, demo = true }
        if e.i then e.n, e.m, e.x, e.y = InstanceName(e.i), nil, nil, nil end
        -- walkers go round a small loop (a minute a lap)
        if spot.w and e.x then
            local a = now / 60 * 2 * math.pi + k
            e.x, e.y = e.x + math.cos(a) * 0.03, e.y + math.sin(a) * 0.03
        end
        out[key] = e
    end
    local roster = ns.Demo:GetMembers()
    for i, key in ipairs(roster) do
        if DEMO_SPOTS[i] then put(key, DEMO_SPOTS[i], i) end
    end
    local realm = (Util.PlayerKey() or "-?"):match("%-(.+)$") or "?"
    local k = 0
    for _, g in ipairs(DEMO_GROUPS) do
        for j = 1, g.n or g[5] do
            k = k + 1
            local name = DEMO_NAMES[(k * 7) % #DEMO_NAMES + 1] .. DEMO_ENDS[(k * 3) % #DEMO_ENDS + 1]
            local key = name .. "-" .. realm
            demoClass[key] = DEMO_CLASSES[(k * 5) % #DEMO_CLASSES + 1]
            if g.i then
                put(key, { i = g.i }, k)
            else
                -- (a fixed scatter around the group's spot, from k)
                local a, d = k * 2.39996, g[6] * (0.35 + ((k * 37) % 65) / 100)
                put(key, { g[1], g[2] + math.cos(a) * d, g[3] + math.sin(a) * d * 1.4, g[4], w = (k % 4 == 0) }, k)
            end
        end
    end
    return out
end

-- Everyone I may see now: { [key] = entry } (me included under my key while I share and am not hidden). Empty
-- while I don't share (demo mode shows its fake guild anyway). My own "zone only" makes everyone zone only.
function GuildMap:GetEntries()
    local out = {}
    local demo = Demoing()
    if not self:IsSharing() and not demo then return out end
    local zoneOnly = self:GetShare() == "zone"
    local now = GetTime()
    local Guild = ns.Guild
    local function put(key, e)
        if zoneOnly and not e.z then
            local c = {}
            for k, v in pairs(e) do c[k] = v end
            c.z, c.x, c.y = true, nil, nil
            e = c
        end
        out[key] = e
    end
    for key, e in pairs(live) do
        if now - e.at > LIVE_TTL or (Guild and Guild.IsReady and Guild:IsReady() and not Guild:IsOnline(key, true)) then
            live[key] = nil
        else
            put(key, e)
        end
    end
    for key, e in pairs(DemoEntries() or {}) do
        if not out[key] then put(key, e) end
    end
    local me = Util.PlayerKey()
    local mine = me and self:GetMine()
    if mine and not mine.h then
        mine.at, mine.ts, mine.me = now, Util.Now(), true
        out[me] = mine
    end
    return out
end

-- Where a member is or was, for the Members card: { live = bool, zone = name, sub = subzone, inst = name, t } or
-- nil. Nothing while I don't share (give to get).
function GuildMap:GetWhere(key)
    if type(key) ~= "string" or not self:IsSharing() then return nil end
    local e = self:GetEntries()[key]
    if e then
        return { live = true, zone = self:GetMapName(e.m), sub = (not e.z and self:GetShare() ~= "zone") and e.s or nil,
                 inst = e.i and e.n or nil, t = e.ts, entry = e }
    end
    local seen = SeenBucket(false)
    local s = seen and seen[key]
    if type(s) ~= "table" or not s.t then return nil end
    return { live = false, zone = self:GetMapName(s.m), inst = s.i and s.n or nil, t = s.t }
end

-- Online guild members (real roster) who don't share with me, me left out.
function GuildMap:CountNotSharing()
    local Guild = ns.Guild
    if not (Guild and Guild.GetOnlineMembers) then return 0 end
    local entries = self:GetEntries()
    local n = 0
    for _, key in ipairs(Guild:GetOnlineMembers()) do
        if not Util.IsMe(key) and not entries[key] then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function GuildMap:OnInit()
    if ns.Comm then
        ns.Comm:Register("MP", function(key, msg, dist) if dist == "GUILD" then OnPosition(key, msg) end end)
        ns.Comm:Register("MQ", function(key, msg, dist) if dist == "GUILD" then OnAsk(key, msg) end end)
        ns.Comm:Register("MX", function(key, _, dist) if dist == "GUILD" then OnStop(key) end end)
    end
    ns:On("ROSTER_UPDATED", function() ns:Fire("GUILDMAP_UPDATED") end)
end

function GuildMap:OnLogin()
    -- a new zone goes out even while nobody watches (the Members card's "Last seen in"), at most every ZONE_GAP s
    local function zoneChanged()
        if not self:IsSharing() then return end
        Util.Debounce("guildmap-zone", 3, function()
            if Watched() or (ns.Comm and ns.Comm:RateLimit("guildmap-zone", ZONE_GAP)) then SendPosition(false) end
        end)
    end
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", zoneChanged)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", zoneChanged)
    ns:RegisterEvent("PLAYER_FLAGS_CHANGED", function(_, unit)
        if unit == "player" and Watched() then SendPosition(false) end
    end)
    -- (back in the world after a /reload while sharing: say where I am once)
    if self:IsSharing() then Util.After(8 + Jitter(6), function() SendPosition(true) end) end
end

-- (tests)
function GuildMap:_State() return live, viewers, sent end

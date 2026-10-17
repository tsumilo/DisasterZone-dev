if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Net.lua", ...) then return end -- DisasterZone_Azeromon/Net.lua
-- ns.AzeroNet: seeing guildmates who play Azeromon in the same world.
-- While the game is open, each client tells the guild where it is, at most once a second:
--   { t = "AZP", v, m = map, x, y, f = facing, p = "UDLR..." (steps taken since the last update), c = class,
--     s = what I'm busy with (nil | "pvp" | "battle" | "trade" | "watch"), o = my opponent's key when s = "pvp",
--     r = the map's revision (Maps def.rev; missing = 1) }
-- plus a heartbeat every HEARTBEAT seconds when standing still, and { t = "AZL" } when leaving. Presence yields to
-- the game's own traffic: nothing goes out while the game prefix has a backlog, during a player battle (whose turns
-- share that queue) at most every MATCH_EVERY seconds, and in WoW combat only the heartbeat (so a long fight doesn't
-- make me vanish from the others' screens).
-- Through a door or over a map's edge, the steps still untold on the old map go out first (an update for the old
-- map), then the new map: others see me walk up to the door before I go in, not vanish a few tiles short of it.
-- Receivers replay the steps, so other players walk the same path about a second behind; a map change waits in the
-- queue behind the steps before it. Peers never block movement (like players passing each other in the games) and
-- are forgotten after TIMEOUT seconds of silence. A peer on a map this client can't show (one it doesn't have,
-- another revision of it, a spot off its edge) is kept, on none of my maps.
-- All traffic uses the "game" prefix (CDLg) and GUILD only; nothing here touches loot or council state.
local addonName, ns = ...

local Net = ns:NewModule("AzeroNet")
local G = ns.Azero
local Maps = ns.AzeroMaps

Net.VERSION = 1
Net.SEND_EVERY = 1.0
Net.HEARTBEAT = 8         -- (an update lost now and then must not make me vanish: TIMEOUT is ~4 of these)
Net.TIMEOUT = 30
Net.MAX_STEPS = 16        -- (older clients drop an update with more)
Net.MAX_QUEUE = 48        -- steps a peer may be behind; past that it catches up at once
Net.MATCH_EVERY = 5       -- while I'm in a player battle (I can't walk anyway)
Net.MAX_BACKLOG = 250     -- bytes waiting on the game prefix above which presence waits (a turn goes first)

local STEP_CODE = { up = "U", down = "D", left = "L", right = "R" }
local STATUS = { pvp = true, battle = true, trade = true, watch = true }
local CODE_DIR = { U = "up", D = "down", L = "left", R = "right" }

local peers = {}          -- [senderKey] = peer
local leftAt = {}         -- [senderKey] = when they said goodbye (AZL), until they show up again
local steps = ""          -- my steps since the last update, all on stepsMap
local stepsMap = nil      -- the map those steps were taken on
local stepX, stepY, stepFace = nil, nil, nil   -- where my last step there ended
local walkOut = nil       -- steps on a map I have just left, told before the new map: { m, x, y, f, p }
local lastSent, lastMap, sentAt = nil, nil, -999
local lastStatus = nil    -- what I was busy with in my last update
local active = false      -- the game panel is open and a save is loaded

local function Now() return GetTime() end

local function InCombat() return InCombatLockdown and InCombatLockdown() or false end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

-- Through a door or over an edge since my last step: the steps still untold on the old map wait in walkOut (sent
-- before the new map, Update), and the steps from here on belong to the new map.
local function NoteMap(s)
    if s.map == stepsMap then return end
    if steps ~= "" and stepsMap and stepX then
        walkOut = { m = stepsMap, x = stepX, y = stepY, f = stepFace, p = steps }
    end
    steps, stepsMap = "", s.map
end

function Net:NoteStep(dir)
    local c = STEP_CODE[dir]
    local s = G.save
    if not c or not s then return end
    NoteMap(s)
    steps = steps .. c
    if #steps > Net.MAX_STEPS then steps = steps:sub(-Net.MAX_STEPS) end
    stepX, stepY, stepFace = s.x, s.y, s.face
end

local function CanSend()
    return active and G.started and G.save and IsInGuild and IsInGuild() and ns.Comm ~= nil
end

-- What I'm busy with, for the bubble over my head on other screens (and who I'm battling, so they can watch).
function Net.Status()
    local P = ns.AzeroPvP
    if P and P:InMatch() then return "pvp", P:Match().opp end
    if ns.AzeroWatch and ns.AzeroWatch:Watching() then return "watch" end
    if G.battle then return "battle" end
    if ns.AzeroTrade and ns.AzeroTrade.session then return "trade" end
    return nil
end

local function StateKey(s)
    local st, opp = Net.Status()
    return s.map .. ":" .. s.x .. ":" .. s.y .. ":" .. s.face .. ":" .. (st or "") .. ":" .. (opp or "")
end

-- Where I am now, or (out = walkOut) the last of my walk on the map I have just left.
local function SendPresence(out)
    local s = G.save
    local class
    if UnitClass then
        local _, c = UnitClass("player")
        class = c
    end
    local st, opp = Net.Status()
    local at = out or { m = s.map, x = s.x, y = s.y, f = s.face, p = steps }
    local def = Maps[at.m]
    local ok = ns.Games:Send(G.GAME_ID, { t = "AZP", v = Net.VERSION, m = at.m, x = at.x, y = at.y, f = at.f,
                                          p = at.p, c = class, s = st, o = opp,
                                          r = type(def) == "table" and def.rev or nil }, "GUILD")
    if ok then
        sentAt = Now()
        if out then
            walkOut = nil
        else
            steps = ""
            lastSent = StateKey(s)
            lastMap = s.map
            lastStatus = st
        end
    end
end

function Net:SetActive(on)
    on = on and true or false
    if active == on then return end
    active = on
    if not on then
        -- closing the game mid-match leaves it (a forfeit the opponent hears at once)
        if ns.AzeroPvP and ns.AzeroPvP.Leave then ns.AzeroPvP:Leave() end
        if IsInGuild and IsInGuild() and ns.Comm then
            ns.Games:Send(G.GAME_ID, { t = "AZL", v = Net.VERSION }, "GUILD")
        end
        steps, stepsMap, stepX, walkOut, lastSent, lastMap = "", nil, nil, nil, nil, nil
    else
        sentAt = -999
    end
end

function Net:IsActive() return active end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

-- An update I can use: "here" (a spot on one of my maps), "elsewhere" (well formed, but on a map I don't have, another
-- revision of it - def.rev, e.g. the bigger Goldshire: their spots would be wrong here; no r is revision 1 - or off
-- its edge: that player is around, just on none of my maps), or nil (malformed: ignored).
local function Fit(msg)
    if type(msg.m) ~= "string" or #msg.m > 40 or type(msg.x) ~= "number" or type(msg.y) ~= "number" then return nil end
    if msg.x < 0 or msg.y < 0 or msg.x % 1 ~= 0 or msg.y % 1 ~= 0 then return nil end
    if type(msg.p) ~= "string" or #msg.p > Net.MAX_STEPS or not msg.p:match("^[UDLR]*$") then return nil end
    if not STEP_CODE[msg.f] then return nil end
    -- (the map's own rows, not G.Compile: the Guild Hall is compiled anew on every call)
    local def = Maps[msg.m]
    local rows = type(def) == "table" and type(def.rows) == "table" and def.rows
    if not (rows and rows[1]) or (tonumber(msg.r) or 1) ~= (def.rev or 1) then return "elsewhere" end
    if msg.x >= #rows[1] or msg.y >= #rows then return "elsewhere" end
    return "here"
end

-- The peer stands at (x, y) on map m now, with nothing left to replay (m = false: on none of my maps).
local function Place(p, m, x, y)
    p.map, p.x, p.y, p.moving = m, x, y, nil
    p.queue = {}
end

local function OnPresence(senderKey, msg)
    if type(msg) ~= "table" or msg.v ~= Net.VERSION then return end
    local fit = Fit(msg)
    if not fit then return end
    local p = peers[senderKey]
    if not p then
        p = { key = senderKey, name = ns.Util.ShortName(senderKey, true), queue = {} }
        peers[senderKey] = p
    end
    p.seen = Now()
    leftAt[senderKey] = nil
    p.class = type(msg.c) == "string" and msg.c or p.class
    p.status = STATUS[msg.s] and msg.s or nil
    p.vs = p.status == "pvp" and type(msg.o) == "string" and msg.o or nil
    local m = fit == "here" and msg.m
    -- where the reported path started
    local sx, sy = msg.x, msg.y
    for i = #msg.p, 1, -1 do
        local d = G.DIRS[CODE_DIR[msg.p:sub(i, i)]]
        sx, sy = sx - d[1], sy - d[2]
    end
    -- (endMap/endX/endY: where this peer will be once its queue has played)
    if p.map == nil then
        Place(p, m, sx, sy)                    -- first sighting
    elseif p.endMap ~= m then
        -- through a door or over an edge: the steps still queued play out on this map first
        if p.moving or #p.queue > 0 then p.queue[#p.queue + 1] = { m = m, x = sx, y = sy } else Place(p, m, sx, sy) end
    elseif m and (p.endX ~= sx or p.endY ~= sy) then
        Place(p, m, sx, sy)                    -- a gap (a lost update): start over at the path's start
    end
    if m then
        for i = 1, #msg.p do p.queue[#p.queue + 1] = CODE_DIR[msg.p:sub(i, i)] end
    end
    p.endMap, p.endX, p.endY = m, msg.x, msg.y
    if #p.queue > Net.MAX_QUEUE then Place(p, m, msg.x, msg.y) end   -- far behind: catch up at once
    if #msg.p == 0 and #p.queue == 0 and not p.moving then p.face = msg.f end
    p.face = p.face or msg.f
    p.finalFace = msg.f
end

local function OnLeave(senderKey)
    peers[senderKey] = nil
    leftAt[senderKey] = Now()
end

---------------------------------------------------------------------------
-- Update (called every frame by the UI)
---------------------------------------------------------------------------

function Net:Update(dt)
    local now = Now()
    -- replay peers
    for key, p in pairs(peers) do
        if now - (p.seen or 0) > Net.TIMEOUT then
            peers[key] = nil
        else
            if p.moving then
                p.moving.t = p.moving.t + dt
                if p.moving.t >= p.moving.dur then p.moving = nil end
            end
            if not p.moving and #p.queue > 0 then
                local e = table.remove(p.queue, 1)
                if type(e) == "table" then
                    p.map, p.x, p.y = e.m, e.x, e.y         -- the door (or the edge): on to the other map
                else
                    local d = G.DIRS[e]
                    -- a long backlog plays faster so the peer catches up
                    local dur = G.STEP_TIME * (#p.queue > 4 and 0.5 or 1)
                    p.moving = { fromX = p.x, fromY = p.y, t = 0, dur = dur }
                    p.x, p.y, p.face = p.x + d[1], p.y + d[2], e
                end
            elseif not p.moving and p.finalFace then
                p.face, p.finalFace = p.finalFace, nil
            end
        end
    end
    -- send
    if not CanSend() then return end
    if ns.Comm.Backlog and ns.Comm:Backlog("game") > Net.MAX_BACKLOG then return end
    local s = G.save
    NoteMap(s)                      -- (a map change with no step since)
    local elapsed = now - sentAt
    -- WoW combat (the game lets go of the keyboard): just the heartbeat, so I don't vanish in a long fight
    if InCombat() then
        if elapsed >= Net.HEARTBEAT then SendPresence(walkOut) end
        return
    end
    if walkOut then                 -- the walk up to the door I just went through, before the new map
        SendPresence(walkOut)
        return
    end
    local state = StateKey(s)
    -- in a match only a new status (the bubble others watch for) goes out at the usual pace
    local every = Net.SEND_EVERY
    if ns.AzeroPvP and ns.AzeroPvP:InMatch() and Net.Status() == lastStatus then every = Net.MATCH_EVERY end
    if s.map ~= lastMap and elapsed >= 0.25 then
        SendPresence()
    elseif (state ~= lastSent and elapsed >= every) or elapsed >= Net.HEARTBEAT then
        SendPresence()
    end
end

-- Peers on a map: { key, name, class, x, y, face, moving = { fromX, fromY, t, dur } }
function Net:PeersOn(mapId)
    local out = {}
    for _, p in pairs(peers) do
        if p.map == mapId then out[#out + 1] = p end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

function Net:Peer(key) return peers[key] end

-- Every peer heard from lately, by key (read only: Marks.lua notes where they stand).
function Net:AllPeers() return peers end

-- Did this guildmate close the game (AZL) and not come back since? (Silence alone says little: in WoW combat
-- presence slows to a heartbeat, and an update can be late behind a busy queue.)
function Net:HasLeft(key) return leftAt[key] ~= nil and peers[key] == nil end

function Net:PeerAt(mapId, x, y)
    for _, p in pairs(peers) do
        if p.map == mapId and p.x == x and p.y == y then return p end
    end
end

-- Guildmates heard from lately (whether or not my own game is open), plus me while I play: the hub's
-- "N playing now".
function Net:PlayingNow()
    local n, now = active and 1 or 0, Now()
    for _, p in pairs(peers) do
        if now - (p.seen or 0) <= Net.TIMEOUT then n = n + 1 end
    end
    return n
end

-- The same players' keys (me first while I play, the rest by name): the hub's faces.
function Net:PlayingKeys()
    local out, now = {}, Now()
    for key, p in pairs(peers) do
        if now - (p.seen or 0) <= Net.TIMEOUT then out[#out + 1] = key end
    end
    table.sort(out)
    local me = ns.Util and ns.Util.PlayerKey()
    if active and me then table.insert(out, 1, me) end
    return out
end

function Net:Count()
    local n = 0
    for _ in pairs(peers) do n = n + 1 end
    return n
end

function Net:OnInit()
    if ns.Comm then
        ns.Comm:Register("AZP", OnPresence)
        ns.Comm:Register("AZL", OnLeave)
    end
end

-- For tests
Net._Reset = function()
    peers, leftAt, steps, lastSent, lastMap, sentAt = {}, {}, "", nil, nil, -999
    stepsMap, stepX, stepY, stepFace, walkOut = nil, nil, nil, nil, nil
end

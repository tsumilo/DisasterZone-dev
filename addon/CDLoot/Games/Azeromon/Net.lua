if CDLootBoot and CDLootBoot.Run("Games/Azeromon/Net.lua", ...) then return end -- CDLoot Games/Azeromon/Net.lua
-- ns.AzeroNet: seeing guildmates who play Azeromon in the same world.
-- While the game is open (and out of combat), each client tells the guild where it is, at most once a second:
--   { t = "AZP", v, m = map, x, y, f = facing, p = "UDLR..." (steps taken since the last update), c = class,
--     s = what I'm busy with (nil | "pvp" | "battle" | "trade" | "watch"), o = my opponent's key when s = "pvp" }
-- plus a heartbeat every HEARTBEAT seconds when standing still, and { t = "AZL" } when leaving.
-- Receivers replay the steps, so other players walk the same path about a second behind. Peers never block
-- movement (like players passing each other in the games) and are forgotten after TIMEOUT seconds of silence.
-- All traffic uses the "game" prefix (CDLg) and GUILD only; nothing here touches loot or council state.
local addonName, ns = ...

local Net = ns:NewModule("AzeroNet")
local G = ns.Azero
local Maps = ns.AzeroMaps

Net.VERSION = 1
Net.SEND_EVERY = 1.0
Net.HEARTBEAT = 10
Net.TIMEOUT = 25
Net.MAX_STEPS = 16

local STEP_CODE = { up = "U", down = "D", left = "L", right = "R" }
local STATUS = { pvp = true, battle = true, trade = true, watch = true }
local CODE_DIR = { U = "up", D = "down", L = "left", R = "right" }

local peers = {}          -- [senderKey] = peer
local steps = ""          -- my steps since the last update
local lastSent, lastMap, sentAt = nil, nil, -999
local active = false      -- the game panel is open and a save is loaded

local function Now() return GetTime() end

local function InCombat() return InCombatLockdown and InCombatLockdown() or false end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

function Net:NoteStep(dir)
    local c = STEP_CODE[dir]
    if not c then return end
    steps = steps .. c
    if #steps > Net.MAX_STEPS then steps = steps:sub(-Net.MAX_STEPS) end
end

local function CanSend()
    return active and G.started and G.save and IsInGuild and IsInGuild() and not InCombat() and ns.Comm ~= nil
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

local function SendPresence()
    local s = G.save
    local class
    if UnitClass then
        local _, c = UnitClass("player")
        class = c
    end
    local st, opp = Net.Status()
    local ok = ns.Comm:Send({ t = "AZP", v = Net.VERSION, m = s.map, x = s.x, y = s.y, f = s.face,
                              p = steps, c = class, s = st, o = opp }, "GUILD", nil, "game")
    if ok then
        steps = ""
        sentAt = Now()
        lastSent = StateKey(s)
        lastMap = s.map
    end
end

function Net:SetActive(on)
    on = on and true or false
    if active == on then return end
    active = on
    if not on then
        if IsInGuild and IsInGuild() and ns.Comm and not InCombat() then
            ns.Comm:Send({ t = "AZL", v = Net.VERSION }, "GUILD", nil, "game")
        end
        steps, lastSent, lastMap = "", nil, nil
    else
        sentAt = -999
    end
end

function Net:IsActive() return active end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function ShortName(key)
    return (Ambiguate and Ambiguate(key, "short")) or (key:match("^[^-]+") or key)
end

local function Valid(msg)
    if type(msg.m) ~= "string" or type(msg.x) ~= "number" or type(msg.y) ~= "number" then return false end
    local m = G.Compile(msg.m)
    if not m then return false end
    if msg.x < 0 or msg.y < 0 or msg.x >= m.w or msg.y >= m.h or msg.x % 1 ~= 0 or msg.y % 1 ~= 0 then return false end
    if type(msg.p) ~= "string" or #msg.p > Net.MAX_STEPS or not msg.p:match("^[UDLR]*$") then return false end
    if not STEP_CODE[msg.f] then return false end
    return true
end

local function OnPresence(senderKey, msg)
    if type(msg) ~= "table" or msg.v ~= Net.VERSION or not Valid(msg) then return end
    local p = peers[senderKey]
    if not p then
        p = { key = senderKey, name = ShortName(senderKey), queue = {} }
        peers[senderKey] = p
    end
    p.seen = Now()
    p.class = type(msg.c) == "string" and msg.c or p.class
    p.status = STATUS[msg.s] and msg.s or nil
    p.vs = p.status == "pvp" and type(msg.o) == "string" and msg.o or nil
    -- where the reported path started
    local sx, sy = msg.x, msg.y
    for i = #msg.p, 1, -1 do
        local d = G.DIRS[CODE_DIR[msg.p:sub(i, i)]]
        sx, sy = sx - d[1], sy - d[2]
    end
    -- where this peer will be once its current queue has played
    local ex, ey = p.x, p.y
    for _, dir in ipairs(p.queue) do
        local d = G.DIRS[dir]
        ex, ey = ex + d[1], ey + d[2]
    end
    if p.map ~= msg.m or ex ~= sx or ey ~= sy then
        -- first sighting, another map, or a gap (a lost update): start over at the path's start
        p.map, p.x, p.y, p.moving = msg.m, sx, sy, nil
        p.queue = {}
    end
    for i = 1, #msg.p do p.queue[#p.queue + 1] = CODE_DIR[msg.p:sub(i, i)] end
    if #msg.p == 0 then p.face = msg.f end
    p.face = p.face or msg.f
    p.finalFace = msg.f
end

local function OnLeave(senderKey)
    peers[senderKey] = nil
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
                local dir = table.remove(p.queue, 1)
                local d = G.DIRS[dir]
                -- a long backlog plays faster so the peer catches up
                local dur = G.STEP_TIME * (#p.queue > 4 and 0.5 or 1)
                p.moving = { fromX = p.x, fromY = p.y, t = 0, dur = dur }
                p.x, p.y, p.face = p.x + d[1], p.y + d[2], dir
            elseif not p.moving and p.finalFace then
                p.face, p.finalFace = p.finalFace, nil
            end
        end
    end
    -- send
    if not CanSend() then return end
    local s = G.save
    local state = StateKey(s)
    local elapsed = now - sentAt
    if s.map ~= lastMap and elapsed >= 0.25 then
        steps = ""                 -- a map change is a jump, not a walk
        SendPresence()
    elseif (state ~= lastSent and elapsed >= Net.SEND_EVERY) or elapsed >= Net.HEARTBEAT then
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
    ns:On("GAMES_COMBAT", function(inCombat)
        if inCombat then steps = "" end
    end)
end

-- For tests
Net._Reset = function() peers, steps, lastSent, lastMap, sentAt = {}, "", nil, nil, -999 end

-- CDLoot Games/Murloc/Murloc.lua
-- ns.Murloc: lobby + network loop for Murloc Defense (2-5 players in a party / raid, or solo).
--
-- Sync model (host-relayed lockstep): every client runs MurlocSim from the same seed. Positions are never
-- sent; only player actions. Players send an action request, the host stamps it with a tick DELAY ticks in
-- its future and broadcasts it, so it reaches everyone before that tick. Clients start after the host (the
-- start message travels) and are capped at the host's last heartbeat + CATCHUP, so they never run ahead of
-- an action. Every HEARTBEAT ticks the host sends its tick + state hash; a client whose hash differs (or that
-- got an action for a tick it already ran) asks for a snapshot of the host's state.
--
-- Wire (group channel): MDo open lobby, MDj join, MDv leave, MDl lobby state, MDs start, MDr action request,
-- MDa scheduled action, MDh heartbeat, MDq resync request, MDn snapshot, MDp combat pause, MDx game over.
local addonName, ns = ...

local Murloc = ns:NewModule("Murloc")
local Util = ns.Util
local D = ns.MurlocData
local Sim = ns.MurlocSim

local GAME_ID = "murloc"
local TICK = 1 / D.TICK_RATE
local DELAY = 12            -- ticks between the host stamping an action and it happening
local HEARTBEAT = 10        -- ticks between host heartbeats
local CATCHUP = 9           -- a client may run at most this far past the last heartbeat
local BEHIND = 15           -- a client this far behind the host fast-forwards
local HOST_TIMEOUT = 12     -- seconds of host silence before the game is abandoned

local lobby                 -- { id, host, players = {keys}, heroes = {[key] = hero} }
local game                  -- { id, host, players, me, S, hostTick, hostHash = {}, myHash = {}, paused = {}, ... }
local BroadcastLobby        -- forward (defined with the lobby code)
local loop = CreateFrame("Frame")
loop:Hide()

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Send(msg)
    if game and game.solo and not game.ended then return end
    local ch = Channel()
    if ch and ns.Comm then ns.Comm:Send(msg, ch) end
end

local function Me() return Util.PlayerKey() end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key)
end

local function Changed() ns:Fire("MURLOC_UPDATED") end

local function IndexOf(list, key)
    for i, k in ipairs(list) do if k == key then return i end end
    return nil
end

local DEFAULT_ROLE = {
    WARRIOR = "melee", PALADIN = "healer", HUNTER = "ranged", ROGUE = "melee", PRIEST = "healer",
    SHAMAN = "caster", MAGE = "caster", WARLOCK = "caster", DRUID = "caster",
}

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Average item level of what I have equipped (shirt / tabard / empty slots skipped).
function Murloc:GetAverageItemLevel()
    local total, n = 0, 0
    for slot = 1, 18 do
        if slot ~= 4 then
            local link = GetInventoryItemLink("player", slot)
            local ilvl = link and select(4, ItemInfo(link))
            if ilvl and ilvl > 0 then
                total, n = total + ilvl, n + 1
            end
        end
    end
    if n == 0 then return 0 end
    return math.floor(total / n + 0.5)
end

-- My hero: class + spec role (my CDLoot spec, else talents) + gear power.
function Murloc:GetMyHero()
    local _, class = UnitClass("player")
    local spec = ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec() or ""
    if (spec == "" or not spec) and ns.BiS and ns.BiS.DetectSpec then spec = ns.BiS:DetectSpec() end
    local role = ns.GetSpecRole and ns.GetSpecRole(class, spec) or nil
    role = role or DEFAULT_ROLE[class] or "melee"
    local ilvl = self:GetAverageItemLevel()
    local _, _, race = UnitRace("player")
    local gear = {}
    for i, slot in ipairs(D.HERO_GEAR_SLOTS) do gear[i] = GetInventoryItemID("player", slot) or 0 end
    return { role = role, class = class, power = D.PowerFromItemLevel(ilvl), name = UnitName("player"),
             spec = spec, ilvl = ilvl, tier = self:GetRepTier(), race = tonumber(race) or 1,
             sex = math.max(0, (UnitSex("player") or 2) - 2), gear = gear }
end

---------------------------------------------------------------------------
-- Meta progression (per character): Southshore Militia reputation, achievements, unlocked maps
---------------------------------------------------------------------------

local function Meta()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.rep) ~= "number" then d.rep = 0 end
    if type(d.ach) ~= "table" then d.ach = {} end
    return d
end

function Murloc:GetRep() return Meta().rep end
function Murloc:GetRepTier() return D.RepTier(Meta().rep) end
function Murloc:HasAchievement(id) return Meta().ach[id] ~= nil end

function Murloc:MapUnlocked(i)
    local m = D.maps[i]
    return m ~= nil and self:GetRepTier() >= (m.rep or 0)
end

function Murloc:GetMap() return Meta().map or 1 end

function Murloc:SetMap(i)
    if not self:MapUnlocked(i) then return end
    Meta().map = i
    if lobby and lobby.host == Me() then
        lobby.map = i
        BroadcastLobby()
    end
    Changed()
end

local function Award(id)
    local meta = Meta()
    if meta.ach[id] then return end
    meta.ach[id] = time()
    for _, a in ipairs(D.achievements) do
        if a.id == id then
            ns:Print("|cffffd100Achievement earned:|r [%s] %s", a.name, a.desc)
            if PlaySound and SOUNDKIT and SOUNDKIT.UI_ACHIEVEMENT_TOAST then pcall(PlaySound, SOUNDKIT.UI_ACHIEVEMENT_TOAST) end
        end
    end
end

-- End of a game: reputation + achievements from what this client saw.
local function Reward(S, me)
    local meta = Meta()
    local before = D.RepTier(meta.rep)
    local gain = D.RepForGame(S.wave, S.kills, S.players)
    meta.rep = meta.rep + gain
    ns:Print("+%d reputation with the Southshore Militia (%s).", gain, D.REP_TIERS[D.RepTier(meta.rep) + 1].name)
    local after = D.RepTier(meta.rep)
    if after > before then
        ns:Print("|cff33ff99You are now %s with the Southshore Militia!|r New things unlocked.", D.REP_TIERS[after + 1].name)
    end
    if S.wave >= 5 then Award("wave5") end
    if S.wave >= 10 then Award("wave10") end
    if S.wave >= 20 then Award("wave20") end
    if S.wave >= 10 and S.players >= 5 then Award("party5") end
    if S.wave >= 10 and D.maps[S.map].id == "zangarmarsh" then Award("zanga") end
    for _, kind in ipairs(S.bossKills) do
        if D.murlocs[kind].id == "king" then Award("king") end
        if D.murlocs[kind].id == "tidecaller" then Award("tide") end
    end
    if S.maxGold >= 1000 then Award("rich") end
    if (S.heroLevel[me] or 1) >= D.HERO_MAX_LEVEL then Award("hero10") end
    if after >= #D.REP_TIERS - 1 then Award("exalted") end
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------

function Murloc:GetLobby() return lobby end
function Murloc:GetGame() return game end
function Murloc:IsPlaying() return game ~= nil and not game.ended end

local function LobbyHeroes()
    local out = {}
    for i, key in ipairs(lobby.players) do out[i] = lobby.heroes[key] end
    return out
end

BroadcastLobby = function()
    if not lobby or lobby.host ~= Me() then return end
    Send({ t = "MDl", g = lobby.id, p = lobby.players, hs = LobbyHeroes(), m = lobby.map })
end

function Murloc:Host()
    if self:IsPlaying() then return end
    local me = Me()
    lobby = { id = string.format("%s-%d-%d", ShortName(me), time(), math.random(1000, 9999)), host = me,
              players = { me }, heroes = { [me] = self:GetMyHero() }, map = self:GetMap() }
    Send({ t = "MDo", g = lobby.id, m = lobby.map })
    if Channel() then ns:Print("you opened a Murloc Defense lobby. Your group can join from the Games tab.") end
    Changed()
end

function Murloc:Join()
    if not lobby or lobby.host == Me() or IndexOf(lobby.players, Me()) then return end
    Send({ t = "MDj", g = lobby.id, h = self:GetMyHero() })
end

function Murloc:LeaveLobby()
    if not lobby then return end
    if lobby.host == Me() then
        Send({ t = "MDx", g = lobby.id })
    else
        Send({ t = "MDv", g = lobby.id })
    end
    lobby = nil
    Changed()
end

function Murloc:IsHost()
    if game then return game.host == Me() end
    return lobby ~= nil and lobby.host == Me()
end

---------------------------------------------------------------------------
-- Game start / end
---------------------------------------------------------------------------

local function BeginGame(id, host, seed, players, heroes, map)
    local me = IndexOf(players, Me())
    if not me then return end
    game = {
        id = id, host = host, players = players, me = me, seq = 0, acc = 0, lastScheduled = 0,
        heroInfo = heroes,     -- raw lobby heroes (race / sex / gear for the UI's models)
        S = Sim.New(seed, #players, heroes, map), hostTick = 0, hostHash = {}, myHash = {}, paused = {},
        heardAt = GetTime(), ended = false,
    }
    lobby = nil
    loop:Show()
    if PlaySoundFile then pcall(PlaySoundFile, 416) end    -- "Mrglglgl!"
    ns:Print("Murloc Defense: defend %s! You hold lane %d.", D.maps[game.S.map].name, me)
    Changed()
end

function Murloc:Start()
    if not lobby or lobby.host ~= Me() then return end
    local seed = math.random(1, 2147483646)
    local heroes = LobbyHeroes()
    Send({ t = "MDs", g = lobby.id, seed = seed, p = lobby.players, hs = heroes, m = lobby.map })
    BeginGame(lobby.id, lobby.host, seed, lobby.players, heroes, lobby.map)
end

-- A private one-lane game (nothing is sent to the group).
function Murloc:PlaySolo()
    if self:IsPlaying() then return end
    local me = Me()
    local id = string.format("%s-solo-%d", ShortName(me), time())
    BeginGame(id, me, math.random(1, 2147483646), { me }, { self:GetMyHero() }, self:GetMap())
    game.solo = true
end

local function Finish(reason)
    if not game or game.ended then return end
    game.ended = true
    loop:Hide()
    local S = game.S
    local best = ns.Games:SubmitScore(GAME_ID, S.wave)
    if S.wave > 0 then Reward(S, game.me) end
    if reason then
        ns:Print("Murloc Defense ended: %s", reason)
    else
        ns:Print("%s has fallen at wave %d (%d murlocs slain).%s", D.maps[S.map].name, S.wave, S.kills,
            best and " New personal best!" or "")
    end
    Changed()
end

function Murloc:Quit()
    if not game then return end
    if game.host == Me() and not game.ended then Send({ t = "MDx", g = game.id }) end
    Finish("you left the game.")
    game = nil
    Changed()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function Schedule(p, k, a, b, c)
    local S = game.S
    local delay = (Channel() and not game.solo) and DELAY or 2
    local tick = math.max(S.tick + delay, game.lastScheduled)
    game.lastScheduled = tick
    game.seq = game.seq + 1
    local act = { tick = tick, p = p, k = k, a = a, b = b, c = c, seq = game.seq }
    Sim.Queue(S, act)
    Send({ t = "MDa", g = game.id, x = act })
end

-- k = "b" (lane, col, kind; kind 0 = my hero) | "g" (to player) | "l" (Bloodlust)
function Murloc:Act(k, a, b, c)
    if not self:IsPlaying() or game.S.over then return end
    if game.host == Me() then
        Schedule(game.me, k, a, b, c)
    else
        Send({ t = "MDr", g = game.id, k = k, a = a, b = b, c = c })
    end
    game.pending = { k = k, a = a, b = b, c = c, at = GetTime() }
    Changed()
end

---------------------------------------------------------------------------
-- Loop
---------------------------------------------------------------------------

local function RequestResync()
    if not ns.Comm:RateLimit("murloc.resync", 3) then return end
    game.wantSnapshot = true
    Send({ t = "MDq", g = game.id })
end

local function CheckHash(t)
    local mine, theirs = game.myHash[t], game.hostHash[t]
    if mine and theirs then
        game.myHash[t], game.hostHash[t] = nil, nil
        if mine ~= theirs then
            game.desyncs = (game.desyncs or 0) + 1
            ns:Debug("Murloc: desync at tick %d, requesting a snapshot", t)
            RequestResync()
        end
    end
end

local function StepOnce()
    local S = game.S
    Sim.Step(S)
    if S.tick % HEARTBEAT == 0 then
        local h = Sim.Hash(S)
        if game.host == Me() then
            Send({ t = "MDh", g = game.id, n = S.tick, h = h })
        else
            game.myHash[S.tick] = h
            CheckHash(S.tick)
        end
    end
    if S.over then
        if game.host == Me() then Send({ t = "MDh", g = game.id, n = S.tick, h = Sim.Hash(S) }) end
        Finish()
    end
end

local function HostPaused()
    if InCombatLockdown() then return true end
    for _, on in pairs(game.paused) do if on then return true end end
    return false
end

loop:SetScript("OnUpdate", function(_, elapsed)
    if not game or game.ended then loop:Hide() return end
    local S = game.S
    if game.host == Me() then
        game.isPaused = HostPaused()
        if game.isPaused then
            game.acc = 0
            game.keepalive = (game.keepalive or 0) + elapsed
            if game.keepalive >= 3 then       -- keep clients from timing out while someone is in combat
                game.keepalive = 0
                Send({ t = "MDh", g = game.id, n = S.tick })
            end
            return
        end
        game.acc = game.acc + elapsed
        local n = 0
        while game.acc >= TICK and n < 5 and not game.ended do
            game.acc = game.acc - TICK
            StepOnce()
            n = n + 1
        end
    else
        if GetTime() - game.heardAt > HOST_TIMEOUT then
            Finish("lost contact with the host.")
            return
        end
        game.acc = game.acc + elapsed
        local cap = game.hostTick + CATCHUP
        local fast = S.tick < game.hostTick - BEHIND
        local n = 0
        while (fast or game.acc >= TICK) and S.tick < cap and n < 30 and not game.ended do
            if not fast then game.acc = game.acc - TICK end
            StepOnce()
            n = n + 1
            fast = S.tick < game.hostTick - BEHIND
        end
        if S.tick >= cap then game.acc = 0 end
        game.isPaused = S.tick >= cap
    end
end)

---------------------------------------------------------------------------
-- Receive
---------------------------------------------------------------------------

local function FromGameHost(sender, msg)
    return game and not game.ended and msg.g == game.id and sender == game.host
end

local handlers = {}

handlers.MDo = function(sender, msg)
    if Murloc:IsPlaying() or type(msg.g) ~= "string" then return end
    lobby = { id = msg.g, host = sender, players = { sender }, heroes = {}, map = tonumber(msg.m) or 1 }
    ns:Print("%s is hosting |cffffd100Murloc Defense|r! Join from |cffffd100/cdl play murloc|r.", ShortName(sender))
    Changed()
end

handlers.MDj = function(sender, msg)
    if not lobby or lobby.host ~= Me() or msg.g ~= lobby.id then return end
    if IndexOf(lobby.players, sender) then return end
    if #lobby.players >= D.MAX_PLAYERS then return end
    lobby.players[#lobby.players + 1] = sender
    lobby.heroes[sender] = type(msg.h) == "table" and msg.h or {}
    BroadcastLobby()
    Changed()
end

handlers.MDv = function(sender, msg)
    if not lobby or lobby.host ~= Me() or msg.g ~= lobby.id then return end
    local i = IndexOf(lobby.players, sender)
    if i and i > 1 then
        table.remove(lobby.players, i)
        lobby.heroes[sender] = nil
        BroadcastLobby()
        Changed()
    end
end

handlers.MDl = function(sender, msg)
    if Murloc:IsPlaying() or type(msg.p) ~= "table" then return end
    if lobby and lobby.id ~= msg.g and lobby.host ~= sender then return end
    lobby = { id = msg.g, host = sender, players = {}, heroes = {}, map = tonumber(msg.m) or 1 }
    for i, key in ipairs(msg.p) do
        if type(key) == "string" and i <= D.MAX_PLAYERS then
            lobby.players[#lobby.players + 1] = key
            lobby.heroes[key] = type(msg.hs) == "table" and msg.hs[i] or nil
        end
    end
    Changed()
end

handlers.MDs = function(sender, msg)
    if Murloc:IsPlaying() or type(msg.p) ~= "table" or not lobby or lobby.host ~= sender or lobby.id ~= msg.g then
        return
    end
    if not IndexOf(msg.p, Me()) then
        lobby = nil
        Changed()
        return
    end
    BeginGame(msg.g, sender, tonumber(msg.seed) or 1, msg.p, type(msg.hs) == "table" and msg.hs or {}, tonumber(msg.m))
end

handlers.MDr = function(sender, msg)
    if not game or game.ended or game.host ~= Me() or msg.g ~= game.id then return end
    local p = IndexOf(game.players, sender)
    if not p or type(msg.k) ~= "string" then return end
    Schedule(p, msg.k, tonumber(msg.a), tonumber(msg.b), tonumber(msg.c))
end

handlers.MDa = function(sender, msg)
    if not FromGameHost(sender, msg) or type(msg.x) ~= "table" then return end
    local x = msg.x
    local act = { tick = tonumber(x.tick), p = tonumber(x.p), k = x.k, a = tonumber(x.a), b = tonumber(x.b),
                  c = tonumber(x.c), seq = tonumber(x.seq) or 0 }
    if not act.tick or not act.p then return end
    if act.p == game.me then game.pending = nil end
    if not Sim.Queue(game.S, act) then RequestResync() end
    Changed()
end

handlers.MDh = function(sender, msg)
    if not FromGameHost(sender, msg) then return end
    local n = tonumber(msg.n)
    if not n then return end
    game.heardAt = GetTime()
    if n > game.hostTick then game.hostTick = n end
    game.hostHash[n] = tonumber(msg.h)
    CheckHash(n)
end

handlers.MDq = function(sender, msg)
    if not game or game.ended or game.host ~= Me() or msg.g ~= game.id then return end
    if not IndexOf(game.players, sender) then return end
    if not ns.Comm:RateLimit("murloc.snapshot", 1) then return end
    local S = game.S
    local fx = S.fx
    S.fx = {}
    Send({ t = "MDn", g = game.id, s = S })      -- encoded synchronously; the fx list stays local
    S.fx = fx
end

handlers.MDn = function(sender, msg)
    if not FromGameHost(sender, msg) or not game.wantSnapshot or type(msg.s) ~= "table" then return end
    game.wantSnapshot = false
    game.S = msg.s
    if type(game.S.fx) ~= "table" then game.S.fx = {} end
    game.hostTick = math.max(game.hostTick, tonumber(msg.s.tick) or 0)
    game.myHash, game.hostHash = {}, {}
    game.acc = 0
    Changed()
end

handlers.MDp = function(sender, msg)
    if not game or game.host ~= Me() or msg.g ~= game.id then return end
    game.paused[sender] = msg.on and true or nil
end

handlers.MDx = function(sender, msg)
    if lobby and lobby.host == sender and lobby.id == msg.g then
        lobby = nil
        Changed()
    end
    if FromGameHost(sender, msg) then
        Finish(ShortName(sender) .. " ended the game.")
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Murloc:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "Murloc Defense",
        desc = "Co-op tower defense for 1-5 players: hold your lane against the murlocs of Southshore. "
            .. "Your hero copy fights by your spec and grows with your gear.",
        icon = "Interface\\Icons\\INV_Misc_Fish_18",
        order = 20,
        create = function(parent) return ns.MurlocUI:CreatePanel(parent) end,
    })
    for t, fn in pairs(handlers) do ns.Comm:Register(t, fn) end
    ns:On("GAMES_COMBAT", function(inCombat)
        if game and not game.ended and game.host ~= Me() then
            Send({ t = "MDp", g = game.id, on = inCombat and true or nil })
        end
    end)
end

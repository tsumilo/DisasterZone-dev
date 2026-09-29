-- CDLoot Games/RPG/RPG.lua
-- ns.RPG: lobby + network loop for "Delve" (co-op real-time dungeon RPG, 1-5 players, or solo).
--
-- Sync model (host-relayed lockstep, as in the retired Murloc Defense): every client runs RPGSim from the same
-- seed; only player actions travel. A player's request goes to the host, which stamps it DELAY ticks into its
-- future and broadcasts it. Clients run behind the host and are capped at its last heartbeat + CATCHUP (< DELAY),
-- so an action always arrives before its tick. Every HEARTBEAT ticks the host sends its tick + state hash; a
-- client that differs (or gets an action for a tick it already ran) asks for a snapshot.
--
-- Wire (group channel): DVo open lobby, DVj join, DVv leave, DVl lobby state, DVs start, DVr action request,
-- DVa scheduled action, DVh heartbeat, DVq resync request, DVn snapshot, DVp combat pause, DVx game over.
local addonName, ns = ...

local RPG = ns:NewModule("RPG")
local Util = ns.Util
local D = ns.RPGData
local Sim = ns.RPGSim

local GAME_ID = "rpg"
local TICK = 1 / D.TICK_RATE
local DELAY = 6             -- ticks between the host stamping an action and it happening (~0.6s)
local HEARTBEAT = 5
local CATCHUP = 4           -- must stay below DELAY
local BEHIND = 10
local HOST_TIMEOUT = 12

local lobby                 -- { id, host, players = {keys}, heroes = {[key] = hero}, heroic }
local game
local BroadcastLobby
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
local function ShortName(key) return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key) end
local function Changed() ns:Fire("RPG_UPDATED") end

local function IndexOf(list, key)
    for i, k in ipairs(list) do if k == key then return i end end
    return nil
end

local DEFAULT_ROLE = {
    WARRIOR = "tank", PALADIN = "healer", HUNTER = "ranged", ROGUE = "melee", PRIEST = "healer",
    SHAMAN = "healer", MAGE = "caster", WARLOCK = "caster", DRUID = "healer",
}

local ItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

function RPG:GetAverageItemLevel()
    local total, n = 0, 0
    for slot = 1, 18 do
        if slot ~= 4 then
            local link = GetInventoryItemLink("player", slot)
            local ilvl = link and select(4, ItemInfo(link))
            if ilvl and ilvl > 0 then total, n = total + ilvl, n + 1 end
        end
    end
    return n > 0 and math.floor(total / n + 0.5) or 0
end

-- My hero: class + spec role (my CDLoot spec, else talents) + gear power.
function RPG:GetMyHero()
    local _, class = UnitClass("player")
    local spec = ns.BiS and ns.BiS.GetSpec and ns.BiS:GetSpec() or ""
    if spec == "" and ns.BiS and ns.BiS.DetectSpec then spec = ns.BiS:DetectSpec() end
    local role = ns.GetSpecRole and ns.GetSpecRole(class, spec) or nil
    role = role or DEFAULT_ROLE[class] or "melee"
    local ilvl = self:GetAverageItemLevel()
    return { role = role, class = class, power = D.PowerFromItemLevel(ilvl), name = UnitName("player"),
             spec = spec, ilvl = ilvl }
end

---------------------------------------------------------------------------
-- Meta progression (per character): Westfall Brigade reputation, achievements
---------------------------------------------------------------------------

local function Meta()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.rep) ~= "number" then d.rep = 0 end
    if type(d.ach) ~= "table" then d.ach = {} end
    return d
end

function RPG:GetRep() return Meta().rep end
function RPG:GetRepTier() return D.RepTier(Meta().rep) end
function RPG:HasAchievement(id) return Meta().ach[id] ~= nil end
function RPG:CanHeroic() return self:GetRepTier() >= D.HEROIC.rep end
function RPG:GetHeroic() return Meta().heroic and self:CanHeroic() or false end

function RPG:SetHeroic(on)
    if on and not self:CanHeroic() then return end
    Meta().heroic = on and true or false
    if lobby and lobby.host == Me() then
        lobby.heroic = Meta().heroic
        BroadcastLobby()
    end
    Changed()
end

local function Award(id)
    local meta = Meta()
    if meta.ach[id] then return end
    meta.ach[id] = time()
    for _, a in ipairs(D.achievements) do
        if a.id == id then ns:Print("|cffffd100Achievement earned:|r [%s] %s", a.name, a.desc) end
    end
end

local function Reward(S)
    local meta = Meta()
    local before = D.RepTier(meta.rep)
    local gain = D.RepForRun(S.depth, S.won, S.players) * (S.heroic and D.HEROIC.repMult or 1)
    meta.rep = meta.rep + gain
    local after = D.RepTier(meta.rep)
    ns:Print("+%d reputation with the Westfall Brigade (%s).", gain, D.REP_TIERS[after + 1].name)
    if after > before then
        ns:Print("|cff33ff99You are now %s with the Westfall Brigade!|r", D.REP_TIERS[after + 1].name)
    end
    if S.depth >= 1 then Award("first") end
    for _, kind in ipairs(S.bossKills) do
        local id = D.enemies[kind].id
        if id == "rhahkzor" then Award("rhahk") end
        if id == "smite" then Award("smite") end
        if id == "vancleef" then Award("vancleef") end
    end
    if S.won then
        if S.heroic then Award("heroic") end
        if S.players >= 5 then Award("party5") end
        if S.players == 1 then Award("solo") end
        if S.flawlessBoss then Award("nodeath") end
    end
    if S.interrupts >= 10 then Award("interrupt") end
    if after >= #D.REP_TIERS - 1 then Award("exalted") end
end

---------------------------------------------------------------------------
-- Lobby
---------------------------------------------------------------------------

function RPG:GetLobby() return lobby end
function RPG:GetGame() return game end
function RPG:IsPlaying() return game ~= nil and not game.ended end

local function LobbyHeroes()
    local out = {}
    for i, key in ipairs(lobby.players) do out[i] = lobby.heroes[key] end
    return out
end

BroadcastLobby = function()
    if not lobby or lobby.host ~= Me() then return end
    Send({ t = "DVl", g = lobby.id, p = lobby.players, hs = LobbyHeroes(), hc = lobby.heroic or nil })
end

function RPG:Host()
    if self:IsPlaying() then return end
    local me = Me()
    lobby = { id = string.format("%s-%d-%d", ShortName(me), time(), math.random(1000, 9999)), host = me,
              players = { me }, heroes = { [me] = self:GetMyHero() }, heroic = self:GetHeroic() }
    Send({ t = "DVo", g = lobby.id })
    if Channel() then ns:Print("you opened a Delve lobby. Your group can join from the Games tab.") end
    Changed()
end

function RPG:Join()
    if not lobby or lobby.host == Me() or IndexOf(lobby.players, Me()) then return end
    Send({ t = "DVj", g = lobby.id, h = self:GetMyHero() })
end

function RPG:LeaveLobby()
    if not lobby then return end
    Send({ t = lobby.host == Me() and "DVx" or "DVv", g = lobby.id })
    lobby = nil
    Changed()
end

---------------------------------------------------------------------------
-- Game start / end
---------------------------------------------------------------------------

local function BeginGame(id, host, seed, players, heroes, heroic)
    local me = IndexOf(players, Me())
    if not me then return end
    game = {
        id = id, host = host, players = players, me = me, seq = 0, acc = 0, lastScheduled = 0,
        heroInfo = heroes, S = Sim.New(seed, heroes, { heroic = heroic }),
        hostTick = 0, hostHash = {}, myHash = {}, paused = {}, heardAt = GetTime(), ended = false,
    }
    lobby = nil
    loop:Show()
    ns:Print("Delve: into %s%s! Good luck.", D.dungeons[game.S.dungeon].name, heroic and " (Heroic)" or "")
    Changed()
end

function RPG:Start()
    if not lobby or lobby.host ~= Me() then return end
    local seed = math.random(1, 2147483646)
    local heroes = LobbyHeroes()
    Send({ t = "DVs", g = lobby.id, seed = seed, p = lobby.players, hs = heroes, hc = lobby.heroic or nil })
    BeginGame(lobby.id, lobby.host, seed, lobby.players, heroes, lobby.heroic)
end

function RPG:PlaySolo()
    if self:IsPlaying() then return end
    local me = Me()
    BeginGame(string.format("%s-solo-%d", ShortName(me), time()), me, math.random(1, 2147483646), { me },
        { self:GetMyHero() }, self:GetHeroic())
    game.solo = true
end

local function Finish(reason)
    if not game or game.ended then return end
    game.ended = true
    loop:Hide()
    local S = game.S
    ns.Games:SubmitScore(GAME_ID, S.depth)
    if S.depth > 0 then Reward(S) end
    if reason then
        ns:Print("Delve ended: %s", reason)
    elseif S.won then
        ns:Print("|cff33ff99Victory!|r Edwin VanCleef is defeated. The Deadmines are cleared.")
    else
        ns:Print("Your party fell in %s after %d rooms.", D.dungeons[S.dungeon].name, S.depth)
    end
    Changed()
end

function RPG:Quit()
    if not game then return end
    if game.host == Me() and not game.ended then Send({ t = "DVx", g = game.id }) end
    Finish("you left the dungeon.")
    game = nil
    Changed()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function Schedule(p, k, a, b)
    local S = game.S
    local delay = (Channel() and not game.solo) and DELAY or 1
    local tick = math.max(S.tick + delay, game.lastScheduled)
    game.lastScheduled = tick
    game.seq = game.seq + 1
    local act = { tick = tick, p = p, k = k, a = a, b = b, seq = game.seq }
    Sim.Queue(S, act)
    Send({ t = "DVa", g = game.id, x = act })
end

-- k = "c" (ability, target) | "v" (path option) | "l" (loot offer) | "t" (talent offer)
function RPG:Act(k, a, b)
    if not self:IsPlaying() or game.S.over then return end
    if game.host == Me() then
        Schedule(game.me, k, a, b)
    else
        Send({ t = "DVr", g = game.id, k = k, a = a, b = b })
    end
    game.pending = { k = k, a = a, b = b, at = GetTime() }
end

function RPG:Cast(a, target) self:Act("c", a, target) end

---------------------------------------------------------------------------
-- Loop
---------------------------------------------------------------------------

local function RequestResync()
    if not ns.Comm:RateLimit("rpg.resync", 3) then return end
    game.wantSnapshot = true
    Send({ t = "DVq", g = game.id })
end

local function CheckHash(t)
    local mine, theirs = game.myHash[t], game.hostHash[t]
    if mine and theirs then
        game.myHash[t], game.hostHash[t] = nil, nil
        if mine ~= theirs then
            game.desyncs = (game.desyncs or 0) + 1
            ns:Debug("Delve: desync at tick %d, requesting a snapshot", t)
            RequestResync()
        end
    end
end

local function StepOnce()
    local S = game.S
    local phase = S.phase
    Sim.Step(S)
    if S.tick % HEARTBEAT == 0 then
        local h = Sim.Hash(S)
        if game.host == Me() then
            Send({ t = "DVh", g = game.id, n = S.tick, h = h })
        else
            game.myHash[S.tick] = h
            CheckHash(S.tick)
        end
    end
    if S.phase ~= phase then Changed() end
    if S.over then
        if game.host == Me() then Send({ t = "DVh", g = game.id, n = S.tick, h = Sim.Hash(S) }) end
        Finish()
    end
end

local function HostPaused()
    for _, on in pairs(game.paused) do if on then return true end end
    return InCombatLockdown() and true or false
end

loop:SetScript("OnUpdate", function(_, elapsed)
    if not game or game.ended then loop:Hide() return end
    local S = game.S
    if game.host == Me() then
        game.isPaused = HostPaused()
        if game.isPaused then
            game.acc = 0
            game.keepalive = (game.keepalive or 0) + elapsed
            if game.keepalive >= 3 then
                game.keepalive = 0
                Send({ t = "DVh", g = game.id, n = S.tick })
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

handlers.DVo = function(sender, msg)
    if RPG:IsPlaying() or type(msg.g) ~= "string" then return end
    lobby = { id = msg.g, host = sender, players = { sender }, heroes = {} }
    ns:Print("%s is gathering a party for |cffffd100Delve: The Deadmines|r! Join from |cffffd100/cdl play rpg|r.",
        ShortName(sender))
    Changed()
end

handlers.DVj = function(sender, msg)
    if not lobby or lobby.host ~= Me() or msg.g ~= lobby.id then return end
    if IndexOf(lobby.players, sender) or #lobby.players >= D.MAX_PLAYERS then return end
    lobby.players[#lobby.players + 1] = sender
    lobby.heroes[sender] = type(msg.h) == "table" and msg.h or {}
    BroadcastLobby()
    Changed()
end

handlers.DVv = function(sender, msg)
    if not lobby or lobby.host ~= Me() or msg.g ~= lobby.id then return end
    local i = IndexOf(lobby.players, sender)
    if i and i > 1 then
        table.remove(lobby.players, i)
        lobby.heroes[sender] = nil
        BroadcastLobby()
        Changed()
    end
end

handlers.DVl = function(sender, msg)
    if RPG:IsPlaying() or type(msg.p) ~= "table" then return end
    if lobby and lobby.id ~= msg.g and lobby.host ~= sender then return end
    lobby = { id = msg.g, host = sender, players = {}, heroes = {}, heroic = msg.hc and true or false }
    for i, key in ipairs(msg.p) do
        if type(key) == "string" and i <= D.MAX_PLAYERS then
            lobby.players[#lobby.players + 1] = key
            lobby.heroes[key] = type(msg.hs) == "table" and msg.hs[i] or nil
        end
    end
    Changed()
end

handlers.DVs = function(sender, msg)
    if RPG:IsPlaying() or type(msg.p) ~= "table" or not lobby or lobby.host ~= sender or lobby.id ~= msg.g then return end
    if not IndexOf(msg.p, Me()) then
        lobby = nil
        Changed()
        return
    end
    BeginGame(msg.g, sender, tonumber(msg.seed) or 1, msg.p, type(msg.hs) == "table" and msg.hs or {}, msg.hc and true)
end

handlers.DVr = function(sender, msg)
    if not game or game.ended or game.host ~= Me() or msg.g ~= game.id then return end
    local p = IndexOf(game.players, sender)
    if not p or type(msg.k) ~= "string" then return end
    Schedule(p, msg.k, tonumber(msg.a), tonumber(msg.b))
end

handlers.DVa = function(sender, msg)
    if not FromGameHost(sender, msg) or type(msg.x) ~= "table" then return end
    local x = msg.x
    local act = { tick = tonumber(x.tick), p = tonumber(x.p), k = x.k, a = tonumber(x.a), b = tonumber(x.b),
                  seq = tonumber(x.seq) or 0 }
    if not act.tick or not act.p then return end
    if act.p == game.me then game.pending = nil end
    if not Sim.Queue(game.S, act) then RequestResync() end
end

handlers.DVh = function(sender, msg)
    if not FromGameHost(sender, msg) then return end
    local n = tonumber(msg.n)
    if not n then return end
    game.heardAt = GetTime()
    if n > game.hostTick then game.hostTick = n end
    game.hostHash[n] = tonumber(msg.h)
    CheckHash(n)
end

handlers.DVq = function(sender, msg)
    if not game or game.ended or game.host ~= Me() or msg.g ~= game.id then return end
    if not IndexOf(game.players, sender) or not ns.Comm:RateLimit("rpg.snapshot", 1) then return end
    local S = game.S
    local fx = S.fx
    S.fx = {}
    Send({ t = "DVn", g = game.id, s = S })
    S.fx = fx
end

handlers.DVn = function(sender, msg)
    if not FromGameHost(sender, msg) or not game.wantSnapshot or type(msg.s) ~= "table" then return end
    game.wantSnapshot = false
    game.S = msg.s
    if type(game.S.fx) ~= "table" then game.S.fx = {} end
    game.hostTick = math.max(game.hostTick, tonumber(msg.s.tick) or 0)
    game.myHash, game.hostHash = {}, {}
    game.acc = 0
    Changed()
end

handlers.DVp = function(sender, msg)
    if not game or game.host ~= Me() or msg.g ~= game.id then return end
    game.paused[sender] = msg.on and true or nil
end

handlers.DVx = function(sender, msg)
    if lobby and lobby.host == sender and lobby.id == msg.g then
        lobby = nil
        Changed()
    end
    if FromGameHost(sender, msg) then Finish(ShortName(sender) .. " ended the run.") end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RPG:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "Delve: The Deadmines",
        desc = "Co-op dungeon RPG for 1-5 players. Fight as yourself: your class and spec pick your abilities, "
            .. "your gear sets your power. Roguelite runs with loot, talents and a VanCleef showdown.",
        icon = "Interface\\Icons\\INV_Sword_33",
        order = 20,
        create = function(parent) return ns.RPGUI:CreatePanel(parent) end,
    })
    for t, fn in pairs(handlers) do ns.Comm:Register(t, fn) end
    ns:On("GAMES_COMBAT", function(inCombat)
        if game and not game.ended and game.host ~= Me() then
            Send({ t = "DVp", g = game.id, on = inCombat and true or nil })
        end
    end)
end

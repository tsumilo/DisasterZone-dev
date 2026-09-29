-- CDLoot Games/RPG/RPG.lua
-- ns.RPG: lobby + turn-based network flow for "Delve" (co-op dungeon RPG, 1-5 players, or solo).
--
-- Sync model (host-ordered commits): every client runs RPGSim from the same seed. Players broadcast their choice
-- for the current step (DVc: combat action, path vote, loot pick, talent pick), so everyone can see who is ready.
-- The host turns choices into COMMITS (DVk) and broadcasts them; every client, the host included, applies commits
-- in order. A commit carries the commit counter + state hash it applies to; a client that is out of step asks for a
-- snapshot (DVq -> DVn). Combat rounds commit when every living player has chosen, or after D.PLAN_TIME seconds
-- (missing players do their basic move); path / loot choices time out after D.CHOICE_TIME. That is one message per
-- player per round plus one from the host, well inside the server's addon message limit (~1 per second).
--
-- Wire (group channel): DVo open lobby, DVj join, DVv leave, DVl lobby state, DVs start, DVc choice, DVk commit,
-- DVq resync request, DVn snapshot, DVp combat pause, DVx run over.
local addonName, ns = ...

local RPG = ns:NewModule("RPG")
local Util = ns.Util
local D = ns.RPGData
local Sim = ns.RPGSim

local GAME_ID = "rpg"
local HOST_TIMEOUT = 120    -- seconds without any host message before the run is abandoned

local lobby
local game
local BroadcastLobby
local driver = CreateFrame("Frame")
driver:Hide()

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
    if after > before then ns:Print("|cff33ff99You are now %s with the Westfall Brigade!|r", D.REP_TIERS[after + 1].name) end
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
-- Run start / end
---------------------------------------------------------------------------

-- The deadline for the current step (host decides; everyone shows it).
local function StepTime(S)
    if S.phase == "combat" then return D.PLAN_TIME end
    if S.phase == "path" or S.phase == "loot" then return D.CHOICE_TIME end
    return nil
end

-- A "step" is one decision point (a combat round, a path vote, a loot pick). Talent picks don't start a new one.
local function StepKey(S) return S.phase .. ":" .. S.depth .. ":" .. S.round end

local function NewStep()
    local S = game.S
    local key = StepKey(S)
    if game.stepKey == key then return end
    game.stepKey = key
    game.choices = {}
    local secs = StepTime(S)
    game.deadline = secs and (GetTime() + secs) or nil
end

local function BeginGame(id, host, seed, players, heroes, heroic)
    local me = IndexOf(players, Me())
    if not me then return end
    game = { id = id, host = host, players = players, me = me, heroInfo = heroes,
             S = Sim.New(seed, heroes, { heroic = heroic }), choices = {}, heardAt = GetTime(), ended = false,
             paused = {} }
    lobby = nil
    NewStep()
    driver:Show()
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
    driver:Hide()
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
-- Commits (applied identically everywhere)
---------------------------------------------------------------------------

-- commit = { round = bool, acts = { { p, k, a, b }, ... } }
local function ApplyCommit(commit)
    local S = game.S
    if commit.round then
        local choices = {}
        for _, act in ipairs(commit.acts or {}) do
            local p = tonumber(act.p)
            if p and act.k == "c" then choices[p] = { a = tonumber(act.a), b = tonumber(act.b) } end
        end
        Sim.ResolveRound(S, choices)
    else
        for _, act in ipairs(commit.acts or {}) do
            Sim.Apply(S, { p = tonumber(act.p), k = act.k, a = tonumber(act.a) })
            local p = tonumber(act.p)
            if p and game.choices[p] and game.choices[p].k == act.k then game.choices[p] = nil end   -- done
        end
    end
    NewStep()
    Changed()
    if S.over then Finish() end
end

-- Host: build a commit from the choices that are ready (or forced by the deadline) and send it.
local function HostCommit(force)
    local S = game.S
    local acts = {}
    local round = S.phase == "combat"
    if round then
        for p = 1, S.players do
            local c = game.choices[p]
            if c and c.k == "c" then
                acts[#acts + 1] = { p = p, k = "c", a = c.a, b = c.b }
            elseif Sim.Waiting(S, p) and not force then
                return false                               -- still waiting for someone
            end
        end
    else
        for p = 1, S.players do
            local c = game.choices[p]
            if c and c.k ~= "c" then
                acts[#acts + 1] = { p = p, k = c.k, a = c.a }
            elseif force and Sim.Waiting(S, p) then
                acts[#acts + 1] = { p = p, k = S.phase == "path" and "v" or "l", a = 1 }
            end
        end
        -- talent picks never block, but ride along with any commit
        for p = 1, S.players do
            local t = game.talents and game.talents[p]
            if t then acts[#acts + 1] = { p = p, k = "t", a = t } end
        end
        if game.talents then game.talents = {} end
        if #acts == 0 then return false end
    end
    local msg = { t = "DVk", g = game.id, n = S.commits, h = Sim.Hash(S), round = round or nil, acts = acts }
    Send(msg)
    ApplyCommit(msg)
    return true
end

-- A talent pick outside a round commit (host only; any phase).
local function HostTalent(p, a)
    local S = game.S
    local msg = { t = "DVk", g = game.id, n = S.commits, h = Sim.Hash(S), acts = { { p = p, k = "t", a = a } } }
    Send(msg)
    ApplyCommit(msg)
end

---------------------------------------------------------------------------
-- Player choices
---------------------------------------------------------------------------

local function RecordChoice(p, k, a, b)
    if k == "t" then
        if game.host == Me() then HostTalent(p, a) end
        return
    end
    game.choices[p] = { k = k, a = a, b = b }
    Changed()
end

-- k = "c" (ability, target) | "v" (path option) | "l" (loot offer) | "t" (talent offer)
function RPG:Choose(k, a, b)
    if not self:IsPlaying() or game.S.over then return end
    Send({ t = "DVc", g = game.id, s = game.stepKey, k = k, a = a, b = b })
    RecordChoice(game.me, k, a, b)
    if game.host == Me() and k ~= "t" then HostCommit(false) end
end

-- The UI's names.
function RPG:Cast(a, target) self:Choose("c", a, target) end
function RPG:Act(k, a, b) self:Choose(k, a, b) end

function RPG:GetChoice(p) return game and game.choices[p or game.me] end

function RPG:SecondsLeft()
    if not game or not game.deadline then return nil end
    return math.max(0, math.ceil(game.deadline - GetTime()))
end

---------------------------------------------------------------------------
-- Driver (host timeouts, host-silence watchdog)
---------------------------------------------------------------------------

local function AnyonePaused()
    if InCombatLockdown() then return true end
    for _, on in pairs(game.paused) do if on then return true end end
    return false
end

local acc = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not game or game.ended then driver:Hide() return end
    acc = acc + elapsed
    if acc < 0.25 then return end
    acc = 0
    if game.host == Me() then
        if game.deadline and GetTime() >= game.deadline then
            if AnyonePaused() then
                game.deadline = GetTime() + 5              -- someone is in real combat: wait for them
            else
                HostCommit(true)
            end
        end
    elseif GetTime() - game.heardAt > HOST_TIMEOUT then
        Finish("lost contact with the host.")
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

-- A player's choice: everyone records it (ready markers); the host may commit.
handlers.DVc = function(sender, msg)
    if not game or game.ended or msg.g ~= game.id or type(msg.k) ~= "string" then return end
    local p = IndexOf(game.players, sender)
    if not p then return end
    if msg.k == "t" then
        if game.host == Me() then HostTalent(p, tonumber(msg.a)) end
        return
    end
    if msg.s ~= game.stepKey then return end                     -- a choice for another step
    RecordChoice(p, msg.k, tonumber(msg.a), tonumber(msg.b))
    if game.host == Me() then HostCommit(false) end
end

handlers.DVk = function(sender, msg)
    if not FromGameHost(sender, msg) or type(msg.acts) ~= "table" then return end
    game.heardAt = GetTime()
    if tonumber(msg.n) ~= game.S.commits or tonumber(msg.h) ~= Sim.Hash(game.S) then
        game.desyncs = (game.desyncs or 0) + 1
        if ns.Comm:RateLimit("rpg.resync", 3) then
            game.wantSnapshot = true
            Send({ t = "DVq", g = game.id })
        end
        return
    end
    ApplyCommit(msg)
end

handlers.DVq = function(sender, msg)
    if not game or game.ended or game.host ~= Me() or msg.g ~= game.id then return end
    if not IndexOf(game.players, sender) or not ns.Comm:RateLimit("rpg.snapshot", 2) then return end
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
    game.stepKey = nil
    NewStep()
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
        desc = "Co-op tactical RPG for 1-5 players. Fight as yourself: your class and spec pick your abilities, "
            .. "your gear sets your power. Read the enemies' intents, plan your turn, and bring VanCleef down.",
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

if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/Bingo.lua", ...) then return end -- DisasterZone Games/Bingo/Bingo.lua
-- ns.Bingo: Council Bingo game state + raid sync. The host (raid leader / assistant who started the game)
-- is the only client that detects events (Detect.lua) and broadcasts the shared hit set; every client
-- rebuilds each raider's card from the seed, so bingos are computed locally and can't be faked.
-- Wire: BG = { g = gameId, s = startedAt, h = { squareId, ... }, w = { [squareId] = who }, e = ended }
--       (RAID/PARTY, host only; w = the raider / boss that set each square off, optional)
--       BGQ = {} "send me the current game" (after a /reload or joining mid-raid)
local addonName, ns = ...

local Bingo = ns:NewModule("Bingo")
local Util = ns.Util

local GAME_ID = "bingo"
local STALE_SECONDS = 10 * 3600     -- a game nobody stopped is over after 10 hours

local cards = {}                    -- [key] = card, for the current game id
local cardsFor

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.season) ~= "table" then d.season = {} end
    if d.announce == nil then d.announce = true end
    return d
end

function Bingo:GetGame()
    local g = Data().current
    if type(g) ~= "table" or type(g.hits) ~= "table" then return nil end
    return g
end

function Bingo:IsActive()
    local g = self:GetGame()
    return g ~= nil and not g.ended
end

function Bingo:IsHost()
    local g = self:GetGame()
    return g ~= nil and g.host == Util.PlayerKey()
end

function Bingo:GetCard(key)
    local g = self:GetGame()
    if not g or not key then return nil end
    if cardsFor ~= g.id then
        wipe(cards)
        cardsFor = g.id
    end
    local card = cards[key]
    if not card then
        card = ns.BingoCard.Build(g.id, key, ns.BingoSquares:Ids())
        cards[key] = card
    end
    return card
end

function Bingo:GetMyCard() return self:GetCard(Util.PlayerKey()) end

-- lines, marked, onLine for a player's card in the current game.
function Bingo:GetScore(key)
    local g, card = self:GetGame(), self:GetCard(key)
    if not g or not card then return 0, 0, {} end
    return ns.BingoCard.Score(card, g.hits)
end

function Bingo:GetSeason() return Data().season end

-- Who set a square off in the current game (short name or boss name), or nil.
function Bingo:GetWho(id)
    local g = self:GetGame()
    return g and type(g.who) == "table" and g.who[id] or nil
end

-- The current game's marked squares, newest first: { { id =, t =, who = }, ... }
function Bingo:GetFeed()
    local g = self:GetGame()
    local out = {}
    if not g then return out end
    for id, t in pairs(g.hits) do
        out[#out + 1] = { id = id, t = tonumber(t) or 0, who = self:GetWho(id) }
    end
    table.sort(out, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.id < b.id
    end)
    return out
end

-- Every raider's standing in the current game, best first: { { key =, lines =, marked = }, ... }
function Bingo:GetRace()
    local out = {}
    if not self:GetGame() then return out end
    local keys, seen = Util.GetGroupKeys(), {}
    local me = Util.PlayerKey()
    for _, k in ipairs(keys) do seen[k] = true end
    if me and not seen[me] then keys[#keys + 1] = me end
    for _, key in ipairs(keys) do
        local lines, marked = self:GetScore(key)
        out[#out + 1] = { key = key, lines = lines, marked = marked }
    end
    table.sort(out, function(a, b)
        if a.lines ~= b.lines then return a.lines > b.lines end
        if a.marked ~= b.marked then return a.marked > b.marked end
        return a.key < b.key
    end)
    return out
end

local function GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function Announce(text)
    ns:Print(text)
    if Bingo:IsHost() and Data().announce then
        local ch = GroupChannel()
        if ch then SendChatMessage("[DisasterZone Bingo] " .. text, ch) end
    end
end

---------------------------------------------------------------------------
-- Winners (computed on every client from the shared hit set)
---------------------------------------------------------------------------

local function SeasonRow(key)
    local s = Data().season
    local row = s[key]
    if type(row) ~= "table" then
        row = { bingos = 0, firsts = 0, blackouts = 0 }
        s[key] = row
    end
    return row
end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key)
end

local function Evaluate()
    local g = Bingo:GetGame()
    if not g then return end
    g.awarded = g.awarded or {}
    g.winners = g.winners or {}
    local keys = Util.GetGroupKeys()
    local me = Util.PlayerKey()
    local seen = {}
    for _, k in ipairs(keys) do seen[k] = true end
    if me and not seen[me] then keys[#keys + 1] = me end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local lines, marked = Bingo:GetScore(key)
        local aw = g.awarded[key] or {}
        if lines > 0 and not aw.line then
            aw.line = true
            g.winners[#g.winners + 1] = key
            local row = SeasonRow(key)
            row.bingos = row.bingos + 1
            if #g.winners == 1 then
                row.firsts = row.firsts + 1
                Announce(ShortName(key) .. " got the first BINGO!")
            else
                Announce(ShortName(key) .. " got BINGO! (#" .. #g.winners .. ")")
            end
            if key == me then PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960) end
        end
        if marked >= ns.BingoCard.CELLS and not aw.black then
            aw.black = true
            SeasonRow(key).blackouts = SeasonRow(key).blackouts + 1
            Announce(ShortName(key) .. " filled the whole card. BLACKOUT!")
        end
        g.awarded[key] = aw
    end
end

---------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------

-- Records who set a square off (first one wins). Names are display text only: short and plain.
local function SetWho(g, id, who)
    if type(id) ~= "string" or type(who) ~= "string" or who == "" then return end
    if type(g.who) ~= "table" then g.who = {} end
    if g.who[id] then return end
    g.who[id] = who:gsub("|", ""):sub(1, 24)
end

local function HitList(g)
    local out = {}
    for id in pairs(g.hits) do out[#out + 1] = id end
    table.sort(out)
    return out
end

local function Broadcast()
    local g = Bingo:GetGame()
    local ch = GroupChannel()
    if not g or not ch or not ns.Comm then return end
    local who = type(g.who) == "table" and next(g.who) and g.who or nil
    ns.Comm:Send({ t = "BG", g = g.id, s = g.started, h = HitList(g), w = who, e = g.ended or nil }, ch)
end

local function Changed()
    ns:Fire("BINGO_UPDATED")
end

-- Marks my own new squares in chat so players notice without opening the window.
local function NoteNewHits(before)
    local g = Bingo:GetGame()
    local card = Bingo:GetMyCard()
    if not g or not card then return end
    for _, id in ipairs(card) do
        if g.hits[id] and not before[id] then
            local sq = ns.BingoSquares:Get(id)
            local _, marked = Bingo:GetScore(Util.PlayerKey())
            local who = Bingo:GetWho(id)
            ns:Print("Bingo: |cffffd100%s|r%s (%d/25)", sq and sq.text or id, who and (" - " .. who) or "", marked)
        end
    end
end

local function OnBG(sender, msg)
    if type(msg.g) ~= "string" or type(msg.h) ~= "table" then return end
    local d = Data()
    local g = Bingo:GetGame()
    if not g or g.id ~= msg.g then
        -- A new game: only from the group's leader or an assistant.
        local rank = Util.GetGroupRole(sender)
        if not rank or rank < 1 or msg.e then return end
        g = { id = msg.g, host = sender, started = tonumber(msg.s) or time(), hits = {} }
        d.current = g
        ns:Print("%s started Council Bingo! Type |cffffd100/dz bingo|r to see your card.", ShortName(sender))
    elseif g.host ~= sender then
        return
    end
    local before = {}
    for id in pairs(g.hits) do before[id] = true end
    for _, id in ipairs(msg.h) do
        if type(id) == "string" and ns.BingoSquares:Get(id) and not g.hits[id] then
            g.hits[id] = time()
        end
    end
    if type(msg.w) == "table" then
        for id, who in pairs(msg.w) do
            if g.hits[id] then SetWho(g, id, who) end
        end
    end
    NoteNewHits(before)
    Evaluate()
    if msg.e and not g.ended then
        g.ended = true
        Bingo:Finish()
    end
    Changed()
end

local function OnBGQ(sender)
    if not Bingo:IsHost() or not Bingo:IsActive() then return end
    if not ns.Comm:RateLimit("bingo.reply", 3) then return end
    Broadcast()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Bingo:CanStart()
    if not IsInGroup() then return true end        -- solo practice card
    return Util.IsPlayerLeaderOrAssist()
end

function Bingo:Start()
    if not self:CanStart() then
        ns:Print("only the raid leader or an assistant can start Council Bingo.")
        return false
    end
    local me = Util.PlayerKey()
    local id = string.format("%s-%d-%d", ShortName(me), time(), math.random(1000, 9999))
    Data().current = { id = id, host = me, started = time(), hits = {} }
    Announce("Council Bingo has started! Type /dz bingo to see your card.")
    Broadcast()
    ns.BingoDetect:Reset()
    Changed()
    return true
end

-- Host: mark a square for everyone (called by Detect). who: optional name of whoever set it off.
function Bingo:Hit(id, who)
    local g = self:GetGame()
    if not g or g.ended or not self:IsHost() or g.hits[id] or not ns.BingoSquares:Get(id) then return end
    local before = {}
    for sid in pairs(g.hits) do before[sid] = true end
    g.hits[id] = time()
    SetWho(g, id, who)
    NoteNewHits(before)
    Broadcast()
    Evaluate()
    Changed()
end

function Bingo:Stop()
    local g = self:GetGame()
    if not g or g.ended then return end
    if not self:IsHost() then
        ns:Print("only %s can end this game.", ShortName(g.host))
        return
    end
    g.ended = true
    Broadcast()
    self:Finish()
    Changed()
end

-- Local wrap-up (host and every raider).
function Bingo:Finish()
    local g = self:GetGame()
    if not g then return end
    local _, marked = self:GetScore(Util.PlayerKey())
    ns.Games:SubmitScore(GAME_ID, marked)
    local n = g.winners and #g.winners or 0
    ns:Print("Council Bingo is over: %d bingo%s. You marked %d/25.", n, n == 1 and "" or "s", marked)
end

function Bingo:SetAnnounce(on) Data().announce = on and true or false end
function Bingo:GetAnnounce() return Data().announce end

function Bingo:RequestState()
    if not IsInGroup() or not ns.Comm then return end
    if not ns.Comm:RateLimit("bingo.query", 10) then return end
    ns.Comm:Send({ t = "BGQ" }, GroupChannel())
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Bingo:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "Council Bingo",
        desc = "Raid bingo: squares fill in by themselves as the raid happens. First full line wins.",
        tagline = "Squares fill in by themselves as the raid happens. First full line wins.",
        icon = "Interface\\Icons\\INV_Misc_Note_02",
        order = 10,
        create = function(parent) return ns.BingoUI:CreatePanel(parent) end,
    })
    ns.Comm:Register("BG", OnBG)
    ns.Comm:Register("BGQ", OnBGQ)
    ns:RegisterSlash("bingo", function(rest)
        local cmd = rest and rest:match("^%s*(%S+)") or ""
        cmd = cmd:lower()
        if cmd == "start" then
            Bingo:Start()
        elseif cmd == "stop" or cmd == "end" then
            Bingo:Stop()
        elseif cmd == "announce" then
            Bingo:SetAnnounce(not Bingo:GetAnnounce())
            ns:Print("Bingo raid-chat announcements %s.", Bingo:GetAnnounce() and "on" or "off")
        else
            ns.Games:Open(GAME_ID)
        end
    end, "bingo [start|stop|announce] - Council Bingo")
end

function Bingo:OnLogin()
    local g = self:GetGame()
    if g and not g.ended and (time() - (tonumber(g.started) or 0)) > STALE_SECONDS then
        g.ended = true
    end
    if self:IsActive() and not self:IsHost() then
        C_Timer.After(5, function() Bingo:RequestState() end)
    end
    local wasInGroup = IsInGroup()
    ns:On("GROUP_UPDATED", function()
        local now = IsInGroup()
        if now and not wasInGroup and not Bingo:IsActive() then Bingo:RequestState() end
        wasInGroup = now
    end)
end

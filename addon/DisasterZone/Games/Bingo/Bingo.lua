if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/Bingo.lua", ...) then return end -- DisasterZone Games/Bingo/Bingo.lua
-- ns.Bingo: Council Bingo game state + raid sync. The host (raid leader / assistant who started the game)
-- is the only client that detects events (Detect.lua) and broadcasts the shared hit set; every client
-- deals each raider's card again from the seed, so bingos and points are computed locally and can't be faked.
-- Wire: BG = { g = gameId, s = startedAt, r = raid, h = { squareId, ... }, w = { [squareId] = who },
--              f = { [playerKey] = cell }, e = ended }
--       (RAID/PARTY, host only; r = the raid whose pool the cards use (a plan key, optional); w = the raider / boss
--       that set each square off, optional; f = Fated: the cell each holder of a legendary got daubed with it)
--       BGQ = {} "send me the current game" (after a /reload or joining mid-raid)
-- Points: each marked square its quality's points (BingoSquares.QUALITY), each completed line LINE_POINTS.
-- Fated: when a legendary square is hit, everyone holding it also gets the cell that brings their card closest to a
-- line. The host picks those cells at that moment (the order hits arrive in differs between clients) and sends them.
local addonName, ns = ...

local Bingo = ns:NewModule("Bingo")
local Util = ns.Util

local GAME_ID = "bingo"
local STALE_SECONDS = 10 * 3600     -- a game nobody stopped is over after 10 hours

local cards = {}                    -- [key] = card, for the current game id + raid
local cardsFor

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.season) ~= "table" then d.season = {} end
    if type(d.codex) ~= "table" then d.codex = {} end
    if d.announce == nil then d.announce = true end
    return d
end

-- Demo mode without a game of your own: a made-up game in the Serpentshrine deck, in memory only (never saved, sent
-- or counted): the card half full, a line done, one one square short.
local demoGame
local function DemoGame()
    if demoGame then return demoGame end
    local me = Util.PlayerKey()
    local now = time()
    local g = { id = "demo", host = me, started = now - 2700, hits = {}, who = {}, raid = "ssc", demo = true }
    demoGame = g
    local card = Bingo:GetCard(me)
    local leg = Bingo:GetLegendary(me)
    local who = { "Victhar", "Fazerblue", "Lady Vashj", "Saltykim", "Dyrma", "Lidevna" }
    local n = 0
    for _, i in ipairs({ 11, 12, 14, 15, 5, 10, 20, 1, 7, 22, 18 }) do
        local id = card and card[i]
        if id and id ~= leg then
            n = n + 1
            g.hits[id] = now - 1500 + n * 120
            g.who[id] = who[(n % #who) + 1]
        end
    end
    return g
end

function Bingo:GetGame()
    local g = Data().current
    if type(g) ~= "table" or type(g.hits) ~= "table" or (g.ended and ns.Demo and ns.Demo:IsEnabled()) then
        if ns.Demo and ns.Demo:IsEnabled() then return DemoGame() end
        if type(g) ~= "table" or type(g.hits) ~= "table" then return nil end
    end
    return g
end

-- Is the shown game demo mode's made-up one?
function Bingo:IsDemo()
    local g = self:GetGame()
    return g ~= nil and g.demo == true
end

function Bingo:IsActive()
    local g = self:GetGame()
    return g ~= nil and not g.ended
end

function Bingo:IsHost()
    local g = self:GetGame()
    return g ~= nil and g.host == Util.PlayerKey()
end

-- The raid whose pool the current game deals from (a plan key), or nil.
function Bingo:GetRaid()
    local g = self:GetGame()
    return g and ns.BingoSquares:HasPool(g.raid) and g.raid or nil
end

function Bingo:GetCard(key)
    local g = self:GetGame()
    if not g or not key then return nil end
    local raid = self:GetRaid()
    local tag = g.id .. "|" .. tostring(raid)
    if cardsFor ~= tag then
        wipe(cards)
        cardsFor = tag
    end
    local card = cards[key]
    if not card then
        local Squares = ns.BingoSquares
        card = ns.BingoCard.Deal(g.id, key, Squares:Core(), Squares:Pool(raid))
        cards[key] = card
    end
    return card
end

function Bingo:GetMyCard() return self:GetCard(Util.PlayerKey()) end

-- The cell Fated daubed on a player's card in the current game (nil: none yet).
function Bingo:GetFated(key)
    local g = self:GetGame()
    local cell = g and type(g.fated) == "table" and tonumber(g.fated[key])
    return cell
end

-- marked[cell] for a player's card in the current game (free centre, hits, the fated cell), or nil without a game.
function Bingo:GetMarks(key)
    local g, card = self:GetGame(), self:GetCard(key)
    if not g or not card then return nil end
    local fated = self:GetFated(key)
    return ns.BingoCard.Marks(card, g.hits, fated and { [fated] = true } or nil)
end

-- lines, marked, onLine for a player's card in the current game.
function Bingo:GetScore(key)
    local marks = self:GetMarks(key)
    if not marks then return 0, 0, {} end
    local lines, marked, onLine = ns.BingoCard.Analyze(marks)
    return lines, marked, onLine
end

-- A player's points in the current game: the marked squares by quality + LINE_POINTS a completed line.
function Bingo:GetPoints(key)
    local card, marks = self:GetCard(key), self:GetMarks(key)
    if not card or not marks then return 0 end
    local Squares = ns.BingoSquares
    local pts = 0
    for cell = 1, ns.BingoCard.CELLS do
        if marks[cell] then pts = pts + Squares:Points(card[cell]) end
    end
    local lines = ns.BingoCard.Analyze(marks)
    return pts + lines * Squares.LINE_POINTS
end

-- The legendary square on a player's card: id, cell (nil without a game).
function Bingo:GetLegendary(key)
    local card = self:GetCard(key)
    if not card then return nil end
    for cell, id in ipairs(card) do
        local sq = ns.BingoSquares:Get(id)
        if sq and sq.q == "l" then return id, cell end
    end
    return nil
end

-- How many raiders in the group hold square id on their card.
function Bingo:CountHolders(id)
    local n = 0
    for _, key in ipairs(self:GroupKeys()) do
        local card = self:GetCard(key)
        if card then
            for _, cid in ipairs(card) do
                if cid == id then n = n + 1 break end
            end
        end
    end
    return n
end

function Bingo:GetSeason() return Data().season end

-- What this character has seen happen: { [id] = { n = games it happened in, t = first time, who, raid } }, and the
-- number of games played (both kept across games: the Codex and the odds on a square).
function Bingo:GetCodex() return Data().codex end
function Bingo:GamesPlayed() return tonumber(Data().games) or 0 end

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

-- The group's keys, me included (sorted).
function Bingo:GroupKeys()
    local keys, seen = Util.GetGroupKeys(), {}
    local me = Util.PlayerKey()
    for _, k in ipairs(keys) do seen[k] = true end
    if me and not seen[me] then keys[#keys + 1] = me end
    table.sort(keys)
    return keys
end

-- Every raider's standing in the current game, best first: { { key =, lines =, marked =, points = }, ... }
function Bingo:GetRace()
    local out = {}
    if not self:GetGame() then return out end
    for _, key in ipairs(self:GroupKeys()) do
        local lines, marked = self:GetScore(key)
        out[#out + 1] = { key = key, lines = lines, marked = marked, points = self:GetPoints(key) }
    end
    table.sort(out, function(a, b)
        if a.lines ~= b.lines then return a.lines > b.lines end
        if a.points ~= b.points then return a.points > b.points end
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

-- The raid the host stands in (a plan key with a pool of its own), or nil.
local function RaidHere()
    if not GetInstanceInfo then return nil end
    local _, kind, _, _, _, _, _, instanceID = GetInstanceInfo()
    if kind ~= "raid" or not ns.ItemDB or not ns.ItemDB.GetRaidByInstance then return nil end
    local itemKey = ns.ItemDB:GetRaidByInstance(instanceID)
    local key = itemKey and ns.ItemDB:PlanKeyOf(itemKey)
    return ns.BingoSquares:HasPool(key) and key or nil
end

---------------------------------------------------------------------------
-- Winners and points (computed on every client from the shared hit set)
---------------------------------------------------------------------------

local function SeasonRow(key)
    local s = Data().season
    local row = s[key]
    if type(row) ~= "table" then
        row = { bingos = 0, firsts = 0, blackouts = 0 }
        s[key] = row
    end
    row.points = tonumber(row.points) or 0
    row.legendaries = tonumber(row.legendaries) or 0
    return row
end

local function Evaluate()
    local g = Bingo:GetGame()
    if not g then return end
    g.awarded = g.awarded or {}
    g.winners = g.winners or {}
    local me = Util.PlayerKey()
    for _, key in ipairs(Bingo:GroupKeys()) do
        local lines, marked = Bingo:GetScore(key)
        local aw = g.awarded[key] or {}
        if lines > 0 and not aw.line then
            aw.line = true
            g.winners[#g.winners + 1] = key
            local row = SeasonRow(key)
            row.bingos = row.bingos + 1
            if #g.winners == 1 then
                row.firsts = row.firsts + 1
                Announce(Util.ShortName(key, true) .. " got the first BINGO!")
            else
                Announce(Util.ShortName(key, true) .. " got BINGO! (#" .. #g.winners .. ")")
            end
            if key == me then PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960) end
        end
        if marked >= ns.BingoCard.CELLS and not aw.black then
            aw.black = true
            SeasonRow(key).blackouts = SeasonRow(key).blackouts + 1
            Announce(Util.ShortName(key, true) .. " filled the whole card. BLACKOUT!")
        end
        -- points into the season as they come (a raider who leaves keeps what they had)
        local pts = Bingo:GetPoints(key)
        local delta = pts - (tonumber(aw.pts) or 0)
        if delta > 0 then
            local row = SeasonRow(key)
            row.points = row.points + delta
            aw.pts = pts
        end
        local legId = not aw.leg and Bingo:GetLegendary(key)
        if legId and g.hits[legId] then
            aw.leg = true
            local row = SeasonRow(key)
            row.legendaries = row.legendaries + 1
        end
        g.awarded[key] = aw
    end
end

---------------------------------------------------------------------------
-- The Codex: what this character has seen happen
---------------------------------------------------------------------------

local function Witness(g, id)
    local sq = ns.BingoSquares:Get(id)
    if not sq then return end
    local codex = Data().codex
    local e = codex[id]
    if type(e) ~= "table" then
        e = { n = 0, t = time(), who = Bingo:GetWho(id), raid = g.raid }
        codex[id] = e
    end
    e.n = (tonumber(e.n) or 0) + 1
end

local function CountGame()
    local d = Data()
    d.games = (tonumber(d.games) or 0) + 1
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
    if not g or g.demo or not ch or not ns.Comm then return end
    local who = type(g.who) == "table" and next(g.who) and g.who or nil
    local fated = type(g.fated) == "table" and next(g.fated) and g.fated or nil
    ns.Games:Send(GAME_ID, { t = "BG", g = g.id, s = g.started, r = g.raid, h = HitList(g), w = who, f = fated,
        e = g.ended or nil }, ch)
end

local function Changed()
    ns:Fire("BINGO_UPDATED")
end

-- Host: a legendary went off. Everyone holding it gets the cell closest to a line on their card (Fated).
local function DealFate(g, id)
    local sq = ns.BingoSquares:Get(id)
    if not sq or sq.q ~= "l" then return end
    g.fated = type(g.fated) == "table" and g.fated or {}
    for _, key in ipairs(Bingo:GroupKeys()) do
        local card = Bingo:GetCard(key)
        if card and not g.fated[key] then
            for _, cid in ipairs(card) do
                if cid == id then
                    local cell = ns.BingoCard.BestGap(ns.BingoCard.Marks(card, g.hits))
                    if cell then g.fated[key] = cell end
                    break
                end
            end
        end
    end
end

-- New squares since `before`: a chat line for mine, the Codex, and a BINGO_MOMENT each (the toasts, the takeover)
-- unless quiet (a game this client only just learned about: everything that already happened arrives at once).
local function NoteNewHits(g, before, quiet)
    local card = Bingo:GetMyCard()
    local mine = {}
    for _, id in ipairs(card or {}) do mine[id] = true end
    local fresh = {}
    for id in pairs(g.hits) do
        if not before[id] then fresh[#fresh + 1] = id end
    end
    table.sort(fresh)
    for _, id in ipairs(fresh) do
        Witness(g, id)
        local sq = ns.BingoSquares:Get(id)
        local who = Bingo:GetWho(id)
        if mine[id] and sq then
            local _, marked = Bingo:GetScore(Util.PlayerKey())
            ns:Print("Bingo: |cffffd100%s|r%s (%d/25)", sq.title, who and (" - " .. who) or "", marked)
        end
        if not quiet then ns:Fire("BINGO_MOMENT", id, who, mine[id] == true) end
    end
end

-- Host only: epic and legendary moments go to raid chat (with Announce on).
local function AnnounceMoment(id, who)
    local sq = ns.BingoSquares:Get(id)
    if not sq or (sq.q ~= "e" and sq.q ~= "l") then return end
    local Q = ns.BingoSquares:Quality(sq)
    local holders = Bingo:CountHolders(id)
    local text = string.format("%s moment: %s%s", Q.name, sq.title, who and (" by " .. who) or "")
    if holders > 0 then
        text = text .. string.format(", +%d to %d raider%s", Q.points, holders, holders == 1 and "" or "s")
    end
    if Bingo:IsHost() and Data().announce then
        local ch = GroupChannel()
        if ch then SendChatMessage("[DisasterZone Bingo] " .. text, ch) end
    end
end

local function OnBG(sender, msg)
    if type(msg.g) ~= "string" or type(msg.h) ~= "table" then return end
    local d = Data()
    local g = Bingo:GetGame()
    local quiet = false
    if not g or g.id ~= msg.g then
        -- A new game: only from the group's leader or an assistant.
        local rank = Util.GetGroupRole(sender)
        if not rank or rank < 1 or msg.e then return end
        g = { id = msg.g, host = sender, started = tonumber(msg.s) or time(), hits = {} }
        d.current = g
        CountGame()
        quiet = #msg.h > 0          -- joining a game that's already going: no fireworks for what already happened
        ns:Print("%s started Council Bingo! Type |cffffd100/dz bingo|r to see your card.", Util.ShortName(sender, true))
    elseif g.host ~= sender then
        return
    end
    -- the raid's pool: only while the cards are still untouched (a change re-deals every card)
    if type(msg.r) == "string" and not g.raid and not next(g.hits) and ns.BingoSquares:HasPool(msg.r) then
        g.raid = msg.r
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
    if type(msg.f) == "table" then
        g.fated = type(g.fated) == "table" and g.fated or {}
        for key, cell in pairs(msg.f) do
            cell = tonumber(cell)
            if type(key) == "string" and cell and cell >= 1 and cell <= ns.BingoCard.CELLS and cell % 1 == 0
                    and not g.fated[key] then
                g.fated[key] = cell
            end
        end
    end
    NoteNewHits(g, before, quiet)
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
    local id = string.format("%s-%d-%d", Util.ShortName(me, true), time(), math.random(1000, 9999))
    Data().current = { id = id, host = me, started = time(), hits = {}, raid = RaidHere() }
    CountGame()
    Announce("Council Bingo has started! Type /dz bingo to see your card.")
    Broadcast()
    ns.BingoDetect:Reset()
    Changed()
    return true
end

-- Host: entering a raid with a pool before anything happened deals everyone's cards from it.
function Bingo:CheckRaid()
    local g = self:GetGame()
    if not g or g.ended or g.demo or g.raid or next(g.hits) or not self:IsHost() then return end
    local raid = RaidHere()
    if not raid then return end
    g.raid = raid
    Broadcast()
    Changed()
end

-- Host: mark a square for everyone (called by Detect). who: optional name of whoever set it off.
function Bingo:Hit(id, who)
    local g = self:GetGame()
    if not g or g.ended or g.demo or not self:IsHost() or g.hits[id] or not ns.BingoSquares:Get(id) then return end
    local before = {}
    for sid in pairs(g.hits) do before[sid] = true end
    g.hits[id] = time()
    SetWho(g, id, who)
    DealFate(g, id)
    NoteNewHits(g, before)
    AnnounceMoment(id, self:GetWho(id))
    Broadcast()
    Evaluate()
    Changed()
end

function Bingo:Stop()
    local g = self:GetGame()
    if not g or g.ended or g.demo then return end
    if not self:IsHost() then
        ns:Print("only %s can end this game.", Util.ShortName(g.host, true))
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
    local me = Util.PlayerKey()
    local _, marked = self:GetScore(me)
    local pts = self:GetPoints(me)
    ns.Games:SubmitScore(GAME_ID, marked)
    local d = Data()
    if pts > (tonumber(d.bestPoints) or 0) then d.bestPoints = pts end
    local n = g.winners and #g.winners or 0
    ns:Print("Council Bingo is over: %d bingo%s. You marked %d/25 for %d points.", n, n == 1 and "" or "s", marked, pts)
end

function Bingo:SetAnnounce(on) Data().announce = on and true or false end
function Bingo:GetAnnounce() return Data().announce end

function Bingo:RequestState()
    if not IsInGroup() or not ns.Comm then return end
    if not ns.Comm:RateLimit("bingo.query", 10) then return end
    ns.Games:Send(GAME_ID, { t = "BGQ" }, GroupChannel())
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Bingo:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "Council Bingo",
        desc = "Raid bingo: squares fill in by themselves as the raid happens. First full line wins.",
        tagline = "Squares fill in as the raid happens.",
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
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() Bingo:CheckRaid() end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() Bingo:CheckRaid() end)
end

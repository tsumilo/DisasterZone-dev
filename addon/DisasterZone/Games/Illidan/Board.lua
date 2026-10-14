if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/Board.lua", ...) then return end -- DisasterZone Games/Illidan/Board.lua
-- ns.BoIBoard: The Binding of Illidan's daily dungeon and the guild's board for it.
--
-- Every realm day has one dungeon, the same for the whole guild: its seed comes from the realm's date (the day turns
-- at realm midnight, ns.RaidNights:Offset). Your first try of the day counts: starting it spends it, and when it
-- ends (you die or win) your result goes round the guild. Later tries that day are practice.
-- A counted death leaves a grave where you fell (floor, room, spot): guildmates on today's dungeon find it there.
--
-- Saved (Games:GetData("illidan")): board[day][playerKey] = entry, tried[day] = true (your try is spent).
-- entry = { c = class, f = floor (1..5), w = true (won), t = seconds, k = kills, i = items, by = killer name,
--           g = { f, rx, ry, x, y } (the grave; a death only) }. The last 7 days are kept.
-- Wire (the games' class, ns.Games:Send): BIR { d = day, e = entry } a result, to the guild when a try ends;
-- BIQ { d, n } "I know n results of day d" (opening the game, at most once a minute); BIA { d, l = { [key] = entry } }
-- an answer to the guild from someone who knows more (after a random wait, unless someone else answered first).
local _, ns = ...

local D, E = ns.BoIData, ns.BoI
local B = ns:NewModule("BoIBoard")
ns.BoIBoard = B

local GAME_ID = D.GAME_ID
local KEEP_DAYS = 7
local ASK_EVERY = 60
local CHUNK = 12      -- entries an answer carries (a member's message stays well under the comm's 4 KB)

local function Util() return ns.Util end
local function Me() return Util().PlayerKey() end

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.board) ~= "table" then d.board = {} end
    if type(d.tried) ~= "table" then d.tried = {} end
    return d
end

-- today's realm date, "YYYY-MM-DD"
function B:Today()
    local off = ns.RaidNights and ns.RaidNights.Offset and ns.RaidNights:Offset() or 0
    return date("%Y-%m-%d", Util().Now() - off * 60)
end

function B:Seed(day) return E.SeedOf("BoI:" .. (day or self:Today())) end

function B:Tried(day) return ns.Games:PeekData(GAME_ID).tried and ns.Games:PeekData(GAME_ID).tried[day or self:Today()] == true end

-- a result from the wire or saved data, cleaned; nil when it does not make sense
local function Clean(e)
    if type(e) ~= "table" then return nil end
    local c, f = e.c, tonumber(e.f)
    if type(c) ~= "string" or not D.CLASSES[c] or not f or f < 1 or f > #D.FLOORS then return nil end
    local out = { c = c, f = math.floor(f), w = e.w and true or nil, t = math.max(0, math.min(36000, math.floor(tonumber(e.t) or 0))),
                  k = math.max(0, math.min(9999, math.floor(tonumber(e.k) or 0))), i = math.max(0, math.min(99, math.floor(tonumber(e.i) or 0))) }
    if type(e.by) == "string" then out.by = e.by:sub(1, 40) end
    local g = e.g
    if not out.w and type(g) == "table" then
        local gf, rx, ry, x, y = tonumber(g[1]), tonumber(g[2]), tonumber(g[3]), tonumber(g[4]), tonumber(g[5])
        if gf and rx and ry and x and y and gf >= 1 and gf <= #D.FLOORS and rx >= 0 and rx <= 8 and ry >= 0 and ry <= 8 then
            out.g = { math.floor(gf), math.floor(rx), math.floor(ry), math.max(E.X0, math.min(E.X1, x)), math.max(E.Y0, math.min(E.Y1, y)) }
        end
    end
    return out
end
B.Clean = Clean

local function Prune(d)
    for _, t in ipairs({ d.board, d.tried }) do
        local days = {}
        for day in pairs(t) do days[#days + 1] = day end
        table.sort(days)
        for i = 1, #days - KEEP_DAYS do t[days[i]] = nil end
    end
end

-- stores a result (the first one of a player for a day stays); true when it was new
local function Store(day, key, e)
    if type(day) ~= "string" or not day:match("^%d%d%d%d%-%d%d%-%d%d$") or type(key) ~= "string" then return false end
    e = Clean(e)
    if not e then return false end
    local d = Data()
    d.board[day] = d.board[day] or {}
    if d.board[day][key] then return false end
    d.board[day][key] = e
    Prune(d)
    ns:Fire("GAMES_UPDATED")
    return true
end
B._Store = Store

-- A daily run: today's seed, your try spent now (a new run or a closed window later does not give it back).
function B:NewDailyRun(class)
    local day = self:Today()
    local d = Data()
    local counted = not d.tried[day]
    d.tried[day] = true
    local run = E.New({ class = class, seed = self:Seed(day), daily = day })
    run.counted = counted
    run.graves = self:Graves(day)
    return run
end

-- the graves of today's dungeon (everyone's counted deaths but yours): { f, rx, ry, x, y, who, cls, by }
function B:Graves(day)
    local out = {}
    for key, e in pairs(ns.Games:PeekData(GAME_ID).board and ns.Games:PeekData(GAME_ID).board[day] or {}) do
        if e.g and not Util().IsMe(key) then
            out[#out + 1] = { f = e.g[1], rx = e.g[2], ry = e.g[3], x = e.g[4], y = e.g[5], who = Util().ShortName(key) or key, cls = e.c, by = e.by }
        end
    end
    table.sort(out, function(a, b) return a.who < b.who end)
    return out
end

-- a counted try ended: store it and tell the guild
function B:Finished(run)
    if not run.daily or not run.counted then return end
    local s = E.Summary(run)
    local e = { c = s.class, f = s.floor, w = s.won or nil, t = s.time, k = s.kills, i = s.items, by = not s.won and s.killer or nil }
    if not s.won and s.room and s.at then e.g = { s.floor, s.room[1], s.room[2], s.at[1], s.at[2] } end
    Store(run.daily, Me(), e)
    ns.Games:Send(GAME_ID, { t = "BIR", d = run.daily, e = e }, "GUILD")
end

-- The day's board, best first: wins by time, then the deepest floor (the faster first), then kills.
-- { { key, name, e, me }, ... }
function B:Board(day)
    day = day or self:Today()
    local list = {}
    for key, e in pairs(ns.Games:PeekData(GAME_ID).board and ns.Games:PeekData(GAME_ID).board[day] or {}) do
        list[#list + 1] = { key = key, name = Util().ShortName(key) or key, e = e, me = Util().IsMe(key) }
    end
    table.sort(list, function(a, b)
        local x, y = a.e, b.e
        if (x.w and 1 or 0) ~= (y.w and 1 or 0) then return x.w ~= nil end
        if x.w then if x.t ~= y.t then return x.t < y.t end
        else
            if x.f ~= y.f then return x.f > y.f end
            if x.t ~= y.t then return x.t < y.t end
        end
        if x.k ~= y.k then return x.k > y.k end
        return a.key < b.key
    end)
    return list
end

function B:Count(day)
    local n = 0
    for _ in pairs(ns.Games:PeekData(GAME_ID).board and ns.Games:PeekData(GAME_ID).board[day or self:Today()] or {}) do n = n + 1 end
    return n
end

-- "Won 11:42" / "Floor 3 · Gorefiend's Vigil"
function B:ResultText(e)
    if e.w then return "Won " .. ns.BoIGame.Clock(e.t) end
    local f = D.FLOORS[e.f]
    return string.format("Floor %d \194\183 %s", e.f, f and f.name or "?")
end

---------------------------------------------------------------------------
-- The wire
---------------------------------------------------------------------------

local lastAsk, answering = 0, {}

function B:Ask()
    if InCombatLockdown and InCombatLockdown() then return end    -- never on the guild channel mid-fight
    local now = Util().Now()
    if now - lastAsk < ASK_EVERY then return end
    lastAsk = now
    local day = self:Today()
    ns.Games:Send(GAME_ID, { t = "BIQ", d = day, n = self:Count(day) }, "GUILD")
end

local function Answer(day)
    answering[day] = nil
    local list, n = {}, 0
    for key, e in pairs(Data().board[day] or {}) do
        list[key] = e
        n = n + 1
        if n >= CHUNK then
            ns.Games:Send(GAME_ID, { t = "BIA", d = day, l = list }, "GUILD")
            list, n = {}, 0
        end
    end
    if n > 0 then ns.Games:Send(GAME_ID, { t = "BIA", d = day, l = list }, "GUILD") end
end

local handlers = {}
handlers.BIR = function(sender, msg)
    if type(msg) ~= "table" or Util().IsMe(sender) then return end
    Store(msg.d, sender, msg.e)
end
handlers.BIQ = function(sender, msg)
    if type(msg) ~= "table" or Util().IsMe(sender) or type(msg.d) ~= "string" then return end
    local mine = Data().board[msg.d]
    if not mine or B:Count(msg.d) <= (tonumber(msg.n) or 0) or answering[msg.d] then return end
    -- someone answers: the one whose wait ends first (the others see the answer and stay quiet)
    answering[msg.d] = true
    local wait = 0.5 + math.random() * 2.5
    if Util().After then Util().After(wait, function() if answering[msg.d] then Answer(msg.d) end end) else Answer(msg.d) end
end
handlers.BIA = function(sender, msg)
    if type(msg) ~= "table" or type(msg.l) ~= "table" or Util().IsMe(sender) then return end
    answering[msg.d] = nil
    local n = 0
    for key, e in pairs(msg.l) do
        n = n + 1
        if n > CHUNK then break end
        Store(msg.d, key, e)
    end
end
B._handlers = handlers

function B:OnInit()
    for t, fn in pairs(handlers) do ns.Comm:Register(t, fn) end
end

-- (no query at login: the board asks when the game is opened, UI.lua; nobody is sent anything they did not open)

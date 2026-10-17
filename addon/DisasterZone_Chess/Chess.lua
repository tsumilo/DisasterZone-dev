if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Chess/Chess.lua", ...) then return end -- DisasterZone_Chess/Chess.lua
-- ns.Chess: Karazhan Chess, the Games hub's chess on Medivh's board. Games against the Echo of Medivh (Games/Chess/AI.lua,
-- with his cheats if you like: Games/Chess/Cheats.lua) and correspondence games with guild members: one whisper per
-- move, played whenever both of you are on; a game waits as long as it takes. Results of guild games go round the
-- guild for a ladder (ratings everybody works out the same way from the same list).
--
-- Saved (Games:GetData("chess")):
--   games[id]   = { id, mode = "ai" | "guild", me = 1 | -1 (my colour: 1 the Alliance, white), opp ("Medivh" | key),
--                   strength, cheats, seed, moves = { "e2e4", ... }, events = { cheat events }, created, updated,
--                   result ("1-0" | "0-1" | "1/2-1/2"), reason, status ("invited" | "asked" | "active" | "over"),
--                   cheatNext (his moves to the next cheat), rng (the cheats' random state), acked (guild: plies the
--                   opponent confirmed), drawFrom (who offered a draw), seen (I looked at the end) }
--   results[id] = { w, b, r, at, n }   guild games' results (the ladder)
--   prefs       = { strength, cheats, color, flat }
--   stats       = { [strength] = { w, l, d } }   games against Medivh
--
-- Wire (WHISPER, the "game" prefix): CHI invite { id, c = colour the inviter plays }, CHA answer { id, ok }, CHM move
-- { id, n = its ply, m }, CHK got it { id, n }, CHP how far are you { id, n, r }, CHG the whole game { id, ms, r, why,
-- w, b }, CHR resign { id }, CHD draw { id, d = "offer" | "accept" | "decline" }, CHX gone { id } (deleted / declined).
-- GUILD: CHL a result { id, w, b, r, at, n }, CHQ ladder digest { n, s }, CHN mine is bigger { n }, CHY send me yours,
-- CHZ results { list } (whisper).
local _, ns = ...

local Chess = ns:NewModule("Chess")
local R = ns.ChessRules
local Util = ns.Util

local GAME_ID = "chess"
Chess.GAME_ID = GAME_ID
Chess.VERSION = 1             -- stamped on every message (Games:Send)
ns.Games:SetWireVersion(GAME_ID, Chess.VERSION)
Chess.MEDIVH = "Medivh"
Chess.MAX_ACTIVE = 12          -- open games at once
Chess.KEEP_OVER = 40           -- finished games kept
Chess.KEEP_RESULTS = 400       -- ladder results kept (newest)
Chess.RESEND = 45              -- s between resends of a move the opponent has not confirmed
Chess.THINK_MS = 12            -- ms of Medivh's thinking per frame

local floor, abs, max, min = math.floor, math.abs, math.max, math.min

local cache = setmetatable({}, { __mode = "k" })   -- game -> { key, pos, info }
local jobs = {}                                     -- game id -> AI job (Medivh thinking)

local function Now() return time() end

local function Me() return Util.PlayerKey() end

local function Data()
    local d = ns.Games:GetData(GAME_ID)
    if type(d.games) ~= "table" then d.games = {} end
    if type(d.results) ~= "table" then d.results = {} end
    if type(d.prefs) ~= "table" then d.prefs = {} end
    if type(d.stats) ~= "table" then d.stats = {} end
    local p = d.prefs
    if p.strength == nil then p.strength = "magus" end
    if p.cheats == nil then p.cheats = true end
    if p.color == nil then p.color = 1 end
    return d
end
Chess.Data = Data

-- The saved tables, read only: nothing is created (the hub's poster and the login checks look without writing).
local EMPTY = {}
local function Peek(key)
    local t = ns.Games:PeekData(GAME_ID)[key]
    return type(t) == "table" and t or EMPTY
end

function Chess:Prefs() return Data().prefs end

local function Changed(g, what, info)
    if g then g.updated = Now() end
    ns:Fire("CHESS_UPDATED", g and g.id, what, info)
    ns:Fire("GAMES_UPDATED")
end

local function NewId()
    local me = Me() or "me"
    return string.format("%s-%x-%04x", me:gsub("%-.*", ""), Now(), floor(math.random() * 65535))
end

---------------------------------------------------------------------------
-- Positions: a game's moves (and cheats) played from the start
---------------------------------------------------------------------------

-- The colour Medivh plays in a game against him (else nil).
local function MedivhSide(g) return g.mode == "ai" and -g.me or nil end

-- Plays a game from the start. -> pos, info = { seen (position key -> count), sans, lost (Medivh's pieces the player
-- took: { p, sq }), taken = { [1] = { pieces white lost }, [-1] = { ... } }, last (the last move number),
-- burned = { [ply] = { { sq, v } } } (what the fire took), cheatAt = { [ply] = event } }
local function Replay(g, upto)
    local pos = R.New()
    local info = { seen = {}, sans = {}, lost = {}, taken = { [1] = {}, [-1] = {} }, burned = {}, cheatAt = {},
                   checks = {} }
    info.seen[R.ToFEN(pos, false)] = 1
    local medivh = MedivhSide(g)
    local evAt = {}
    for _, ev in ipairs(g.events or {}) do
        if type(ev) == "table" and tonumber(ev.ply) then
            evAt[ev.ply] = evAt[ev.ply] or {}
            table.insert(evAt[ev.ply], ev)
        end
    end
    local n = upto or #g.moves
    for i = 1, n do
        local m = R.ParseMove(pos, g.moves[i])
        if not m then
            info.broken = i
            break
        end
        local legal = R.Legal(pos)
        info.sans[i] = R.SAN(pos, m, legal)
        local to, flag = R.To(m), R.Flag(m)
        local capSq = flag == 1 and (to - 10 * pos.side) or to
        local cap = pos.b[capSq]
        local mover = pos.side
        R.Make(pos, m)
        info.last = m
        if cap ~= 0 then
            table.insert(info.taken[cap > 0 and 1 or -1], abs(cap))
            if medivh and (cap > 0) == (medivh > 0) then info.lost[#info.lost + 1] = { p = abs(cap), sq = capSq } end
        end
        if medivh then
            local burned = ns.ChessCheats.Tick(pos, mover, medivh)
            if #burned > 0 then
                info.burned[i] = burned
                for _, bu in ipairs(burned) do table.insert(info.taken[bu.v > 0 and 1 or -1], abs(bu.v)) end
            end
            for _, ev in ipairs(evAt[i] or {}) do
                if ns.ChessCheats.Apply(pos, ev, medivh) then
                    info.cheatAt[i] = ev
                    if ev.k == "heal" then
                        -- (the piece is back: no longer among the lost)
                        for j = #info.lost, 1, -1 do
                            if info.lost[j].p == tonumber(ev.p) then table.remove(info.lost, j) break end
                        end
                        local t = info.taken[medivh]
                        for j = #t, 1, -1 do if t[j] == tonumber(ev.p) then table.remove(t, j) break end end
                    end
                end
            end
        end
        local key = R.ToFEN(pos, false)
        info.seen[key] = (info.seen[key] or 0) + 1
    end
    return pos, info
end

-- The game's position now (cached until a move or a cheat). -> pos (do not change it), info
function Chess:Position(g)
    local key = #g.moves .. ":" .. #(g.events or {})
    local c = cache[g]
    if c and c.key == key then return c.pos, c.info end
    local pos, info = Replay(g)
    cache[g] = { key = key, pos = pos, info = info }
    return pos, info
end

-- The position after the first `ply` moves (for looking back through a game).
function Chess:PositionAt(g, ply)
    return Replay(g, ply)
end

function Chess:Get(id) return Peek("games")[id] end

-- Is it my move in g?
function Chess:MyTurn(g)
    if not g or g.status ~= "active" then return false end
    local pos = self:Position(g)
    return pos.side == g.me
end

function Chess:OpponentName(g)
    if g.mode == "ai" then return "Echo of Medivh" end
    return Util.ShortName(g.opp) or g.opp
end

-- My games: open ones first (my move first), then finished, newest first.
function Chess:List()
    local out = {}
    for _, g in pairs(Peek("games")) do out[#out + 1] = g end
    table.sort(out, function(a, b)
        local oa, ob = a.status ~= "over" and 1 or 0, b.status ~= "over" and 1 or 0
        if oa ~= ob then return oa > ob end
        local ma, mb = Chess:MyTurn(a) and 1 or 0, Chess:MyTurn(b) and 1 or 0
        if ma ~= mb then return ma > mb end
        return (a.updated or 0) > (b.updated or 0)
    end)
    return out
end

function Chess:CountActive()
    local n = 0
    for _, g in pairs(Peek("games")) do if g.status ~= "over" then n = n + 1 end end
    return n
end

-- Games where it is my move (for the hub's poster).
function Chess:MyTurnCount()
    local n = 0
    for _, g in pairs(Peek("games")) do if self:MyTurn(g) then n = n + 1 end end
    return n
end

local function Trim()
    local d = Data()
    local over = {}
    for id, g in pairs(d.games) do if g.status == "over" then over[#over + 1] = g end end
    table.sort(over, function(a, b) return (a.updated or 0) > (b.updated or 0) end)
    for i = Chess.KEEP_OVER + 1, #over do d.games[over[i].id] = nil end
end

---------------------------------------------------------------------------
-- Ending a game
---------------------------------------------------------------------------

local function Score(result, side)
    if result == "1/2-1/2" then return 0.5 end
    if (result == "1-0") == (side == 1) then return 1 end
    return 0
end
Chess.Score = Score

-- How a finished game went for me: "win" | "loss" | "draw"
function Chess:MyResult(g)
    if not g.result then return nil end
    local s = Score(g.result, g.me)
    return s == 1 and "win" or (s == 0 and "loss" or "draw")
end

local function Finish(g, result, reason)
    if g.status == "over" then return end
    g.status, g.result, g.reason = "over", result, reason
    jobs[g.id] = nil
    if g.mode == "ai" then
        local st = Data().stats
        local key = g.strength or "magus"
        local s = st[key] or { w = 0, l = 0, d = 0 }
        st[key] = s
        local r = Chess:MyResult(g)
        if r == "win" then s.w = s.w + 1 elseif r == "loss" then s.l = s.l + 1 else s.d = s.d + 1 end
    else
        Chess:Record(g)
    end
    Trim()
    Changed(g, "over")
end

-- Checks a game for its end after a move. -> true when it ended
local function CheckEnd(g)
    local pos, info = Chess:Position(g)
    if info.broken then return false end
    local result, reason = R.Outcome(pos, info.seen)
    if result then
        Finish(g, result, reason)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Playing a move
---------------------------------------------------------------------------

-- Plays the move `text` ("e2e4") for the side to move in g (no turn check: callers know whose it is). -> the move
-- (number), or nil and why not
local function Apply(g, text)
    local pos = Chess:Position(g)
    local m = R.ParseMove(pos, text)
    if not m then return nil, "illegal" end
    g.moves[#g.moves + 1] = R.MoveText(m)
    g.drawFrom = nil
    return m
end

-- The cheat Medivh does after his move, when it is time (the event is stored with the game).
local function MaybeCheat(g)
    if g.mode ~= "ai" or not g.cheats or g.status ~= "active" then return nil end
    local C = ns.ChessCheats
    g.rng = tonumber(g.rng) or tonumber(g.seed) or 1
    local rng = ns.ChessAI.Rng(g.rng)
    local function Draw()
        local x = rng()
        g.rng = floor(x * 2147483646) + 1
        return x
    end
    g.cheatNext = (tonumber(g.cheatNext) or C.NextIn(Draw)) - 1
    if g.cheatNext > 0 then return nil end
    local pos, info = Chess:Position(g)
    local work = R.Copy(pos)
    local ev = C.Choose(work, MedivhSide(g), Draw, info.lost)
    g.cheatNext = C.NextIn(Draw)
    if not ev then return nil end
    ev.ply = #g.moves
    ev.line = floor(Draw() * #C.LINES) + 1
    g.events = g.events or {}
    g.events[#g.events + 1] = ev
    return ev
end

-- What a move did, for the board's animations and sounds. -> { m, from, to, piece, cap, capSq, san, castle, promo,
-- burned, cheat, check, mover }
local function MoveInfo(g, m)
    local _, info = Chess:Position(g)
    local n = #g.moves
    local before = Chess:PositionAt(g, n - 1)
    local to, flag = R.To(m), R.Flag(m)
    local capSq = flag == 1 and (to - 10 * before.side) or to
    local pos = Chess:Position(g)
    return { m = m, from = R.From(m), to = to, piece = before.b[R.From(m)], cap = before.b[capSq], capSq = capSq,
             san = info.sans[n], castle = flag == 2, promo = R.Promo(m), mover = before.side, ply = n,
             burned = info.burned[n], cheat = info.cheatAt[n], check = R.InCheck(pos) }
end

-- I play `text` in game g. -> true, or false and why not
function Chess:Play(g, text)
    if not g or g.status ~= "active" then return false, "over" end
    if not self:MyTurn(g) then return false, "turn" end
    local m, why = Apply(g, text)
    if not m then return false, why end
    local mi = MoveInfo(g, m)
    if g.mode == "guild" then
        self:SendMove(g)
    end
    local ended = CheckEnd(g)
    Changed(g, "move", mi)
    if not ended and g.mode == "ai" then self:StartThinking(g) end
    return true
end

---------------------------------------------------------------------------
-- Medivh's turn
---------------------------------------------------------------------------

local driver

function Chess:StartThinking(g)
    if g.mode ~= "ai" or g.status ~= "active" or self:MyTurn(g) then return end
    local pos, info = self:Position(g)
    -- (his seed per move: the same game thinks the same way again)
    jobs[g.id] = { job = ns.ChessAI.Start(pos, g.strength, info.seen, (tonumber(g.seed) or 1) + #g.moves * 7919),
                   started = GetTime(), game = g }
    if driver then driver:Show() end
    Changed(g, "thinking")
end

function Chess:IsThinking(g) return g and jobs[g.id] ~= nil end

-- Medivh's move found: played, then perhaps a cheat.
local function MedivhMoves(g, m)
    if g.status ~= "active" or Chess:MyTurn(g) then return end
    if not m then return CheckEnd(g) end
    Apply(g, R.MoveText(m))
    local ended = CheckEnd(g)
    local ev = nil
    if not ended then ev = MaybeCheat(g) end
    local mi = MoveInfo(g, m)
    if ev then mi.cheat = ev end
    if not ended and ev then CheckEnd(g) end
    Changed(g, "move", mi)
end

-- Runs Medivh's thinking a slice per frame. The board may hold his answer back (Chess.hold) while it animates.
local function Drive()
    local any = false
    for id, j in pairs(jobs) do
        any = true
        local g = j.game
        if not Peek("games")[id] or g.status ~= "active" then
            jobs[id] = nil
        elseif not j.done then
            local done, m = j.job:Step(Chess.THINK_MS)
            if done then j.done, j.move = true, m end
        end
        -- (he takes at least a moment, and waits while the board still moves a piece)
        if j.done and GetTime() - j.started >= (Chess.minThink or 0.8) and not (Chess.hold and Chess.hold(id)) then
            jobs[id] = nil
            MedivhMoves(g, j.move)
        end
    end
    if not any and driver then driver:Hide() end
end
Chess.Drive = Drive

-- Thinks Medivh's move to the end at once (tests).
function Chess:FinishThinking(g)
    local j = jobs[g.id]
    if not j then return false end
    local done, m = false, nil
    for _ = 1, 100000 do
        done, m = j.job:Step(1000)
        if done then break end
    end
    jobs[g.id] = nil
    MedivhMoves(g, m)
    return true
end

---------------------------------------------------------------------------
-- New games, resigning, draws, deleting
---------------------------------------------------------------------------

-- A game against Medivh. color: 1 (the Alliance, moves first) | -1 | 0 (random); strength; cheats.
function Chess:NewAIGame(color, strength, cheats)
    if self:CountActive() >= self.MAX_ACTIVE then return nil, "full" end
    if color ~= 1 and color ~= -1 then color = (math.random() < 0.5) and 1 or -1 end
    local seed = floor(math.random() * 2000000000) + 1
    local g = { id = NewId(), mode = "ai", me = color, opp = self.MEDIVH, strength = ns.ChessAI.STRENGTH[strength]
                and strength or "magus", cheats = cheats and true or false, seed = seed, rng = seed, moves = {},
                events = {}, created = Now(), updated = Now(), status = "active" }
    Data().games[g.id] = g
    Changed(g, "new")
    if color == -1 then self:StartThinking(g) end
    return g
end

function Chess:Resign(g)
    if not g or g.status == "over" then return end
    if g.status ~= "active" then return self:Delete(g) end
    if g.mode == "guild" then self:Whisper(g.opp, { t = "CHR", id = g.id }) end
    Finish(g, g.me == 1 and "0-1" or "1-0", "resign")
end

function Chess:OfferDraw(g)
    if not g or g.mode ~= "guild" or g.status ~= "active" then return end
    if g.drawFrom and g.drawFrom ~= Me() then return self:AnswerDraw(g, true) end
    g.drawFrom = Me()
    self:Whisper(g.opp, { t = "CHD", id = g.id, d = "offer" })
    Changed(g, "draw")
end

function Chess:AnswerDraw(g, yes)
    if not g or g.status ~= "active" or not g.drawFrom or g.drawFrom == Me() then return end
    self:Whisper(g.opp, { t = "CHD", id = g.id, d = yes and "accept" or "decline" })
    if yes then
        Finish(g, "1/2-1/2", "agreed")
    else
        g.drawFrom = nil
        Changed(g, "draw")
    end
end

-- Takes a game off my list (an open guild game is resigned first; an invite is declined).
function Chess:Delete(g)
    if not g then return end
    if g.mode == "guild" and g.status == "active" then self:Resign(g) end
    if g.mode == "guild" and (g.status == "invited" or g.status == "asked") then
        self:Whisper(g.opp, { t = "CHX", id = g.id })
    end
    jobs[g.id] = nil
    Data().games[g.id] = nil
    Changed(nil, "delete")
end

---------------------------------------------------------------------------
-- Guild games: the wire
---------------------------------------------------------------------------

-- (every chess message carries v = Chess.VERSION: Games:Send stamps it)
function Chess:Whisper(to, msg)
    return ns.Games:Send(GAME_ID, msg, "WHISPER", to)
end

local function Online(key)
    return ns.Guild and ns.Guild:IsOnline(key) or false
end

-- Invites a guild member to a game. color: the colour I play (1, -1, 0 = random). -> the game, or nil and why not
function Chess:Invite(target, color)
    if type(target) ~= "string" or target == "" then return nil, "who" end
    target = Util.NormalizeName and Util.NormalizeName(target) or target
    if Util.IsMe(target) then return nil, "self" end
    if ns.Guild and not ns.Guild:IsInGuild(target) then return nil, "guild" end
    if self:CountActive() >= self.MAX_ACTIVE then return nil, "full" end
    if color ~= 1 and color ~= -1 then color = (math.random() < 0.5) and 1 or -1 end
    local g = { id = NewId(), mode = "guild", me = color, opp = target, moves = {}, created = Now(), updated = Now(),
                status = "asked", acked = 0, sentAt = GetTime() }
    Data().games[g.id] = g
    self:Whisper(target, { t = "CHI", id = g.id, c = color })
    Changed(g, "new")
    return g
end

function Chess:Accept(g)
    if not g or g.status ~= "invited" then return end
    g.status = "active"
    self:Whisper(g.opp, { t = "CHA", id = g.id, ok = true })
    Changed(g, "accept")
end

function Chess:Decline(g)
    if not g or g.status ~= "invited" then return end
    self:Whisper(g.opp, { t = "CHA", id = g.id, ok = false })
    Data().games[g.id] = nil
    Changed(nil, "delete")
end

function Chess:SendMove(g)
    local n = #g.moves
    if n == 0 then return end
    g.sentAt = GetTime()
    self:Whisper(g.opp, { t = "CHM", id = g.id, n = n, m = g.moves[n] })
end

local function SendWhole(g, to)
    Chess:Whisper(to or g.opp, { t = "CHG", id = g.id, ms = table.concat(g.moves, " "), r = g.result, why = g.reason,
                                 w = g.me == 1 and Me() or g.opp, b = g.me == 1 and g.opp or Me() })
end

-- The game with this id from this sender, or nil (a game of mine with someone else is not theirs to touch).
local function Theirs(sender, id)
    local g = type(id) == "string" and Peek("games")[id]
    if not g or g.mode ~= "guild" then return nil end
    if not (Util.NormalizeName and Util.NormalizeName(g.opp) == Util.NormalizeName(sender) or g.opp == sender) then
        return nil
    end
    return g
end

-- Takes the whole move list `ms` from the opponent when it continues mine (never shortens a game).
local function Merge(g, ms, result, reason)
    local list = {}
    for mv in tostring(ms or ""):gmatch("%S+") do list[#list + 1] = mv end
    if #list < #g.moves then return false end
    for i = 1, #g.moves do if list[i] ~= g.moves[i] then return false end end
    local before = #g.moves
    for i = before + 1, #list do
        local m = Apply(g, list[i])
        if not m then
            for k = #g.moves, before + 1, -1 do g.moves[k] = nil end
            return false
        end
    end
    if g.status ~= "over" then
        if (result == "1-0" or result == "0-1" or result == "1/2-1/2") and (reason == "resign" or reason == "agreed") then
            Finish(g, result, reason)
        else
            CheckEnd(g)
        end
    end
    if #list > before then
        local mi = MoveInfo(g, R.ParseMove(Chess:PositionAt(g, #g.moves - 1), g.moves[#g.moves]) or 0)
        Changed(g, "move", mi)
    end
    return true
end

local handlers = {}

handlers.CHI = function(sender, msg)
    if type(msg.id) ~= "string" or Peek("games")[msg.id] then return end
    if Chess:CountActive() >= Chess.MAX_ACTIVE then
        Chess:Whisper(sender, { t = "CHA", id = msg.id, ok = false, full = true })
        return
    end
    local their = tonumber(msg.c) == -1 and -1 or 1
    local g = { id = msg.id, mode = "guild", me = -their, opp = sender, moves = {}, created = Now(), updated = Now(),
                status = "invited", acked = 0 }
    Data().games[g.id] = g
    Changed(g, "invite")
    ns:Print("%s invites you to Karazhan Chess (Guild > Games).", Util.ShortName(sender) or sender)
end

handlers.CHA = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g or g.status ~= "asked" then return end
    if msg.ok then
        g.status = "active"
        Changed(g, "accept")
    else
        Data().games[g.id] = nil
        ns:Print("%s declined your chess game%s.", Util.ShortName(sender) or sender, msg.full and " (too many open games)" or "")
        Changed(nil, "delete")
    end
end

handlers.CHM = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g then return end
    if g.status == "asked" then g.status = "active" end   -- (their accept went missing; the move says it all)
    local n = tonumber(msg.n)
    if not n then return end
    if g.status == "over" or n <= #g.moves then
        Chess:Whisper(sender, { t = "CHK", id = g.id, n = #g.moves })
        return
    end
    if n > #g.moves + 1 or Chess:MyTurn(g) then
        Chess:Whisper(sender, { t = "CHP", id = g.id, n = #g.moves })   -- (out of step: ask for the whole game)
        return
    end
    local m = Apply(g, msg.m)
    if not m then
        Chess:Whisper(sender, { t = "CHP", id = g.id, n = #g.moves })
        return
    end
    g.acked = #g.moves                -- (their move: they have all of mine)
    Chess:Whisper(sender, { t = "CHK", id = g.id, n = #g.moves })
    local mi = MoveInfo(g, m)
    CheckEnd(g)
    Changed(g, "move", mi)
end

handlers.CHK = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g then return end
    g.acked = max(tonumber(g.acked) or 0, min(#g.moves, tonumber(msg.n) or 0))
    if g.status == "asked" then g.status = "active" end
    Changed(g, "ack")
end

handlers.CHP = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g then
        -- (they still have a game I deleted: say so, they can drop it)
        if type(msg.id) == "string" then Chess:Whisper(sender, { t = "CHX", id = msg.id }) end
        return
    end
    local n = tonumber(msg.n) or 0
    if n < #g.moves or (g.result and not msg.r) then
        SendWhole(g, sender)
    elseif n > #g.moves then
        Chess:Whisper(sender, { t = "CHP", id = g.id, n = #g.moves })
    else
        g.acked = #g.moves
    end
    if g.status == "asked" then g.status = "active" Changed(g, "accept") end
end

handlers.CHG = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g then return end
    if g.status == "asked" then g.status = "active" end
    Merge(g, msg.ms, msg.r, msg.why)
    g.acked = #g.moves
end

handlers.CHR = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g or g.status == "over" then return end
    Finish(g, g.me == 1 and "1-0" or "0-1", "resign")
    ns:Print("%s resigned your chess game.", Util.ShortName(sender) or sender)
end

handlers.CHD = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g or g.status ~= "active" then return end
    if msg.d == "offer" then
        g.drawFrom = g.opp
        Changed(g, "draw")
    elseif msg.d == "accept" and g.drawFrom == Me() then
        Finish(g, "1/2-1/2", "agreed")
    elseif msg.d == "decline" then
        g.drawFrom = nil
        Changed(g, "draw")
    end
end

handlers.CHX = function(sender, msg)
    local g = Theirs(sender, msg.id)
    if not g then return end
    if g.status == "active" and #g.moves > 0 then
        -- (they dropped a game in play: it counts as their resignation)
        Finish(g, g.me == 1 and "1-0" or "0-1", "resign")
    elseif g.status ~= "over" then
        Data().games[g.id] = nil
        Changed(nil, "delete")
    end
end

-- Now and then: moves the opponent has not confirmed go again while they are online.
function Chess:Resend()
    local now = GetTime()
    for _, g in pairs(Peek("games")) do
        if g.mode == "guild" and Online(g.opp) then
            if g.status == "active" and #g.moves > (tonumber(g.acked) or 0) and not self:MyTurn(g)
                and now - (g.sentAt or 0) >= self.RESEND then
                self:SendMove(g)
            elseif g.status == "asked" and now - (g.sentAt or 0) >= self.RESEND * 4 then
                g.sentAt = now
                self:Whisper(g.opp, { t = "CHI", id = g.id, c = g.me })
            end
        end
    end
end

-- After logging in: each open guild game asks its opponent (when on) how far they are.
function Chess:SyncAll()
    for _, g in pairs(Peek("games")) do
        if g.mode == "guild" and g.status == "active" and Online(g.opp) then
            self:Whisper(g.opp, { t = "CHP", id = g.id, n = #g.moves, r = g.result })
        end
    end
end

---------------------------------------------------------------------------
-- The guild ladder
---------------------------------------------------------------------------

local function ValidResult(r)
    return type(r) == "table" and type(r.w) == "string" and type(r.b) == "string" and r.w ~= r.b
        and (r.r == "1-0" or r.r == "0-1" or r.r == "1/2-1/2") and tonumber(r.at)
end

local function AddResult(id, r)
    local res = Data().results
    if type(id) ~= "string" or res[id] or not ValidResult(r) then return false end
    res[id] = { w = r.w, b = r.b, r = r.r, at = tonumber(r.at), n = tonumber(r.n) or 0 }
    -- keep the newest
    local count = 0
    for _ in pairs(res) do count = count + 1 end
    if count > Chess.KEEP_RESULTS then
        local oldest, oid
        for k, v in pairs(res) do
            if not oldest or v.at < oldest or (v.at == oldest and k < oid) then oldest, oid = v.at, k end
        end
        res[oid] = nil
    end
    Chess.ratings = nil
    return true
end

-- A finished guild game into the ladder (and round the guild).
function Chess:Record(g)
    if g.mode ~= "guild" or not g.result or #g.moves < 2 then return end   -- (no ladder for a game never played)
    local r = { w = g.me == 1 and Me() or g.opp, b = g.me == 1 and g.opp or Me(), r = g.result, at = Now(),
                n = #g.moves }
    if AddResult(g.id, r) then
        ns.Games:Send(GAME_ID, { t = "CHL", id = g.id, w = r.w, b = r.b, r = r.r, at = r.at, n = r.n }, "GUILD")
        Changed(nil, "ladder")
    end
end

handlers.CHL = function(sender, msg)
    -- (only one of the two players may report a game)
    local function same(a, b) return Util.NormalizeName and Util.NormalizeName(a) == Util.NormalizeName(b) or a == b end
    if not (same(sender, msg.w) or same(sender, msg.b)) then return end
    if AddResult(msg.id, msg) then Changed(nil, "ladder") end
end

-- The ladder's digest: how many results and a checksum of their ids.
function Chess:Digest()
    local n, s = 0, 0
    for id in pairs(Peek("results")) do
        n = n + 1
        local h = 0
        for i = 1, #id do h = (h * 31 + id:byte(i)) % 1000003 end
        s = (s + h) % 1000003
    end
    return n, s
end

handlers.CHQ = function(sender, msg)
    local n, s = Chess:Digest()
    if n > (tonumber(msg.n) or 0) or (n == tonumber(msg.n) and s ~= tonumber(msg.s)) then
        Chess:Whisper(sender, { t = "CHN", n = n })
    end
end

handlers.CHN = function(sender, msg)
    -- the first who has more is asked for theirs (once a session)
    if Chess.askedLadder or (tonumber(msg.n) or 0) <= (Chess:Digest()) then return end
    Chess.askedLadder = true
    Chess:Whisper(sender, { t = "CHY" })
end

handlers.CHY = function(sender)
    if not ns.Comm:RateLimit("chess.ladder." .. tostring(sender), 60) then return end
    local list = {}
    for id, r in pairs(Peek("results")) do list[#list + 1] = { id, r.w, r.b, r.r, r.at, r.n } end
    table.sort(list, function(a, b) return a[5] > b[5] end)
    for i = 1, #list, 40 do
        local part = {}
        for k = i, min(#list, i + 39) do part[#part + 1] = list[k] end
        Chess:Whisper(sender, { t = "CHZ", list = part })
    end
end

handlers.CHZ = function(_, msg)
    local added = false
    for _, e in ipairs(type(msg.list) == "table" and msg.list or {}) do
        if type(e) == "table" and AddResult(e[1], { w = e[2], b = e[3], r = e[4], at = e[5], n = e[6] }) then
            added = true
        end
    end
    if added then Changed(nil, "ladder") end
end

-- Ratings from the results, oldest first (Elo, K 32, everyone starts at 1200): the same list gives everyone the same
-- numbers. -> sorted list of { key, rating, w, l, d, games }
function Chess:Ratings()
    if self.ratings then return self.ratings end
    local list = {}
    for id, r in pairs(Peek("results")) do list[#list + 1] = { id = id, r = r } end
    table.sort(list, function(a, b)
        if a.r.at ~= b.r.at then return a.r.at < b.r.at end
        return a.id < b.id
    end)
    local by = {}
    local function P(key)
        local p = by[key]
        if not p then p = { key = key, rating = 1200, w = 0, l = 0, d = 0, games = 0 } by[key] = p end
        return p
    end
    for _, e in ipairs(list) do
        local w, b = P(e.r.w), P(e.r.b)
        local sw = Score(e.r.r, 1)
        local ew = 1 / (1 + 10 ^ ((b.rating - w.rating) / 400))
        w.rating, b.rating = w.rating + 32 * (sw - ew), b.rating + 32 * ((1 - sw) - (1 - ew))
        w.games, b.games = w.games + 1, b.games + 1
        if sw == 1 then w.w, b.l = w.w + 1, b.l + 1 elseif sw == 0 then w.l, b.w = w.l + 1, b.w + 1
        else w.d, b.d = w.d + 1, b.d + 1 end
    end
    local out = {}
    for _, p in pairs(by) do
        p.rating = floor(p.rating + 0.5)
        out[#out + 1] = p
    end
    table.sort(out, function(a, b)
        if a.rating ~= b.rating then return a.rating > b.rating end
        return a.key < b.key
    end)
    self.ratings = out
    return out
end

function Chess:MyRating()
    for i, p in ipairs(self:Ratings()) do
        if Util.IsMe(p.key) then return p, i end
    end
    return nil
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Chess:OnInit()
    ns.Games:Register(GAME_ID, {
        name = "Karazhan Chess",
        desc = "Chess on Medivh's own board in the Gamesman's Hall: play the Echo of Medivh (he cheats, if you let him) or a guild member, a move whenever you are both on.",
        tagline = "Play Medivh's echo, or a guildmate.",
        icon = "Interface\\Icons\\INV_Misc_Ogrepinata",
        order = 25,
        create = function(parent) return ns.ChessUI and ns.ChessUI:CreatePanel(parent) end,
        status = function()
            local n = Chess:MyTurnCount()
            if n > 0 then return string.format("|cffc9a2ffYour move in %d game%s|r", n, n == 1 and "" or "s") end
            return "|cff888888No game waiting|r"
        end,
    })
    for t, fn in pairs(handlers) do ns.Comm:Register(t, fn) end
    -- the bell: a guildmate moved in one of my games (Core/Notify.lua; here, so it is listed only when Chess is in)
    local N = ns.Notify
    if N and N.RegisterKind then
        N:RegisterKind("chessTurn", {
            section = "Games", page = "games", icon = 51, color = { 1, 0.7, 0.28 },
            label = "Chess: your move", desc = "A guildmate moved in your Karazhan Chess game.",
            needsYou = true, popup = false, sound = false,
            open = function(it)
                if ns.MainFrame then ns.MainFrame:Open("games") end
                if ns.GamesUI and ns.GamesUI.Select then ns.GamesUI:Select(GAME_ID) end
                local g = Chess:Get(it.key)
                if g and ns.ChessUI and ns.ChessUI.OpenGame then ns.ChessUI:OpenGame(g) end
            end,
        })
        N:RegisterSource("chessTurn", function()
            local out = {}
            for _, g in ipairs(Chess:List()) do
                if g.mode ~= "ai" and Chess:MyTurn(g) then
                    out[#out + 1] = { key = g.id, from = g.opp, title = Chess:OpponentName(g) .. " moved: your turn",
                                      text = "Karazhan Chess", time = g.updated }
                end
            end
            return out
        end, { "CHESS_UPDATED" })
    end
    driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", Drive)
    ns:RegisterSlash("chess", function(rest)
        local cmd, arg = (rest or ""):match("^%s*(%S*)%s*(.-)%s*$")
        cmd = (cmd or ""):lower()
        if cmd == "invite" and arg ~= "" then
            local g, why = Chess:Invite(arg, 0)
            if g then ns:Print("Chess invite sent to %s.", arg) else ns:Print("Could not invite %s (%s).", arg, why) end
        elseif cmd == "poster" then
            Chess:PosterReport()
        else
            ns.Games:Open(GAME_ID)
        end
    end, "chess [invite <name>] - Karazhan Chess")
end

-- /dz chess poster: what the hub's 3D poster sees (for a screenshot of a poster that looks wrong).
function Chess:PosterReport()
    local cv
    for _, p in ipairs(ns.GamesUI and ns.GamesUI.__posters or {}) do
        if p.id == GAME_ID then cv = p.cover end
    end
    if not cv then return ns:Print("Chess poster: not made yet (open Guild > Games once).") end
    if not cv.view then return ns:Print("Chess poster: the flat board (no 3D view on this client yet).") end
    local v = cv.view
    local sc = v.scene
    local S = 5.6
    local mx, my = 3.5 * S, 3.5 * S
    local okRaw, rx, ry = pcall(sc.Project3DPointTo2D, sc, mx, v:SY(my), 0)
    local px, py = v:Project(mx, my, 0)
    local function n(x) return type(x) == "number" and string.format("%.1f", x) or tostring(x) end
    ns:Print("Chess poster: shown %s, visible %s, alpha %s; stage tries %s, why %s, calibrated %s, dirty %s",
        tostring(cv:IsShown()), tostring(cv:IsVisible()), n(cv.GetEffectiveAlpha and cv:GetEffectiveAlpha()),
        tostring(cv.tries), tostring(cv.why), tostring(cv.calibrated), tostring(cv.dirty))
    ns:Print("  floor %s of %d tiles shown; camera %s yd; cover %s x %s, scene %s x %s, scale %s",
        tostring(cv.shownTiles), #(cv.tiles or {}), n(cv.dist), n(cv:GetWidth()), n(cv:GetHeight()),
        n(sc:GetWidth()), n(sc:GetHeight()), n(sc:GetEffectiveScale()))
    ns:Print("  board middle: raw %s %s, %s / view %s, %s; mirror %s, pitch sign %s",
        tostring(okRaw), n(rx), n(ry), n(px), n(py), tostring(v.cam.mirror), tostring(v.cam.pitchSign))
    local t = cv.tiles and cv.tiles[1] and cv.tiles[1].tex
    ns:Print("  levels: floor %s, scene %s, plates %s, cover %s; first tile shown %s, layer %s",
        tostring(v.floorFrame:GetFrameLevel()), tostring(sc:GetFrameLevel()), tostring(v.plateFrame:GetFrameLevel()),
        tostring(cv:GetFrameLevel()), tostring(t and t:IsShown()), tostring(t and t:GetDrawLayer()))
end

function Chess:OnLogin()
    -- games against Medivh that were his move when you logged out: he thinks again
    for _, g in pairs(Peek("games")) do
        if g.mode == "ai" and g.status == "active" and not self:MyTurn(g) then self:StartThinking(g) end
    end
    if Util.After then
        Util.After(8 + math.random() * 6, function()
            Chess:SyncAll()
            local n, s = Chess:Digest()
            ns.Games:Send(GAME_ID, { t = "CHQ", n = n, s = s }, "GUILD")
        end)
    end
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(15, function() Chess:Resend() end)
    end
    ns:On("ROSTER_UPDATED", function() Chess:Resend() end)
end

if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Chess/AI.lua", ...) then return end -- DisasterZone_Chess/AI.lua
-- ns.ChessAI: Medivh at the board. An alpha-beta search (iterative deepening, a quiet search of captures at the end,
-- captures and killer moves first) over Games/Chess/Rules.lua, judged by material and where pieces stand (the
-- "simplified evaluation function" tables, the king's own table for the endgame).
--
-- It thinks in slices: AI.Start returns a job, job:Step(ms) works for about that long and returns true with the move
-- when done, so a frame never stalls. AI.Think runs a job to the end at once (tests, the hub's cover).
--
-- Strengths: Apprentice (2 moves ahead, sloppy), Magus (3 ahead, a little noise) and Guardian (deepens as far as
-- 2.5 s of thought allow, up to 6). Each also stops after a number of positions (nodes): a slow computer thinks
-- longer, never deeper. A slice of thinking ends on the clock or after SLICE_NODES positions per ms asked. Noise comes from the job's own seeded numbers, so a game replays the same way.
local _, ns = ...

local AI = {}
ns.ChessAI = AI

local R = ns.ChessRules
local floor, abs, max, min = math.floor, math.abs, math.max, math.min

AI.STRENGTH = {
    apprentice = { name = "Apprentice", depth = 2, time = 0.6, nodes = 40000, noise = 90, all = true },
    magus      = { name = "Magus", depth = 3, time = 1.5, nodes = 150000, noise = 18, all = true },
    guardian   = { name = "Guardian", depth = 6, time = 2.5, nodes = 400000, noise = 0 },
}
AI.ORDER = { "apprentice", "magus", "guardian" }

local MATE = 30000
local SLICE_NODES = 400        -- positions per ms of a slice at most (the clock is checked every 256)
local INF = 1000000
AI.MATE = MATE

---------------------------------------------------------------------------
-- Judging a position
---------------------------------------------------------------------------

local VALUE = { 100, 320, 330, 500, 900, 0 }
AI.VALUE = VALUE

-- Where a piece stands well, white's view, rank 8 first (Tomasz Michniewski's simplified evaluation function).
local PST_TEXT = {
    -- pawn
    [1] = [[ 0  0  0  0  0  0  0  0
            50 50 50 50 50 50 50 50
            10 10 20 30 30 20 10 10
             5  5 10 25 25 10  5  5
             0  0  0 20 20  0  0  0
             5 -5-10  0  0-10 -5  5
             5 10 10-20-20 10 10  5
             0  0  0  0  0  0  0  0]],
    [2] = [[-50-40-30-30-30-30-40-50
           -40-20  0  0  0  0-20-40
           -30  0 10 15 15 10  0-30
           -30  5 15 20 20 15  5-30
           -30  0 15 20 20 15  0-30
           -30  5 10 15 15 10  5-30
           -40-20  0  5  5  0-20-40
           -50-40-30-30-30-30-40-50]],
    [3] = [[-20-10-10-10-10-10-10-20
           -10  0  0  0  0  0  0-10
           -10  0  5 10 10  5  0-10
           -10  5  5 10 10  5  5-10
           -10  0 10 10 10 10  0-10
           -10 10 10 10 10 10 10-10
           -10  5  0  0  0  0  5-10
           -20-10-10-10-10-10-10-20]],
    [4] = [[ 0  0  0  0  0  0  0  0
             5 10 10 10 10 10 10  5
            -5  0  0  0  0  0  0 -5
            -5  0  0  0  0  0  0 -5
            -5  0  0  0  0  0  0 -5
            -5  0  0  0  0  0  0 -5
            -5  0  0  0  0  0  0 -5
             0  0  0  5  5  0  0  0]],
    [5] = [[-20-10-10 -5 -5-10-10-20
           -10  0  0  0  0  0  0-10
           -10  0  5  5  5  5  0-10
            -5  0  5  5  5  5  0 -5
             0  0  5  5  5  5  0 -5
           -10  5  5  5  5  5  0-10
           -10  0  5  0  0  0  0-10
           -20-10-10 -5 -5-10-10-20]],
    [6] = [[-30-40-40-50-50-40-40-30
           -30-40-40-50-50-40-40-30
           -30-40-40-50-50-40-40-30
           -30-40-40-50-50-40-40-30
           -20-30-30-40-40-30-30-20
           -10-20-20-20-20-20-20-10
            20 20  0  0  0  0 20 20
            20 30 10  0  0 10 30 20]],
    [7] = [[-50-40-30-20-20-30-40-50
           -30-20-10  0  0-10-20-30
           -30-10 20 30 30 20-10-30
           -30-10 30 40 40 30-10-30
           -30-10 30 40 40 30-10-30
           -30-10 20 30 30 20-10-30
           -30-30  0  0  0  0-30-30
           -50-30-30-30-30-30-30-50]],      -- the king in the endgame
}

-- PST[p][sq] for white, PST_B[p][sq] for black (mirrored), indexed by mailbox square
local PST, PST_B = {}, {}
for p, text in pairs(PST_TEXT) do
    local nums = {}
    for n in text:gmatch("%-?%d+") do nums[#nums + 1] = tonumber(n) end
    assert(#nums == 64, "ChessAI: a table needs 64 numbers")
    local w, b = {}, {}
    for rank = 0, 7 do
        for file = 0, 7 do
            local sq = R.Square(file, rank)
            w[sq] = nums[(7 - rank) * 8 + file + 1]
            b[sq] = nums[rank * 8 + file + 1]
        end
    end
    PST[p], PST_B[p] = w, b
end

local SQ = R.SQ

-- The position's worth for the side to move (centipawns).
local function Evaluate(pos)
    local b = pos.b
    local score, heavy = 0, 0
    for i = 1, 64 do
        local v = b[SQ[i]]
        if v ~= 0 and abs(v) == 5 then heavy = heavy + 1 end
        if v ~= 0 and (abs(v) == 2 or abs(v) == 3 or abs(v) == 4) then heavy = heavy + 0.34 end
    end
    local endgame = heavy <= 2.1
    local fire, hand = pos.fire, pos.hand
    for i = 1, 64 do
        local sq = SQ[i]
        local v = b[sq]
        if v ~= 0 then
            local p = v > 0 and v or -v
            local t = (p == 6 and endgame) and 7 or p
            local s = VALUE[p] + (v > 0 and PST[t][sq] or PST_B[t][sq])
            if fire and fire[sq] then s = s - floor(VALUE[p] * 0.45) end   -- (in the fire: likely lost)
            if hand and hand[sq] then s = s + 25 end                          -- (empowered: steps any way)
            if v > 0 then score = score + s else score = score - s end
        end
    end
    return score * pos.side
end
AI.Evaluate = Evaluate

---------------------------------------------------------------------------
-- The search
---------------------------------------------------------------------------

-- A seeded random number source (0 <= x < 1), so a game's noise replays the same way.
local function Rng(seed)
    local s = (tonumber(seed) or 1) % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function()
        s = (s * 16807) % 2147483647
        return (s - 1) / 2147483646
    end
end
AI.Rng = Rng

local Clock = function()
    if debugprofilestop then return debugprofilestop() end
    return (GetTime and GetTime() or os.clock()) * 1000
end

local Job = {}
Job.__index = Job

-- Starts thinking about pos (it is copied) at a strength ("apprentice" | "magus" | "guardian"); seen = position key ->
-- count (repetitions: reaching one twice more is a draw); seed = the noise's seed. -> a job.
function AI.Start(pos, strength, seen, seed)
    local cfg = AI.STRENGTH[strength] or AI.STRENGTH.magus
    local job = setmetatable({ pos = R.Copy(pos), cfg = cfg, seen = seen or {}, rng = Rng(seed or 1), nodes = 0,
                               killers = {}, undo = {}, lists = {}, scores = {} }, Job)
    job.co = coroutine.create(function() return job:Root() end)
    return job
end

-- Works for about ms milliseconds. -> true, move (a number; nil when there is none) when done; false while thinking.
function Job:Step(ms)
    if self.done then return true, self.best end
    self.sliceEnd = Clock() + (ms or 10)
    self.sliceBudget = (ms or 10) * SLICE_NODES
    self.sliceNodes = self.nodes + self.sliceBudget
    local ok, err = coroutine.resume(self.co)
    if not ok then
        self.done = true
        self.err = err
        if geterrorhandler then geterrorhandler()(err) end
        return true, self.best
    end
    if coroutine.status(self.co) == "dead" then
        self.done = true
        return true, self.best
    end
    return false
end

-- Thinks to the end at once. -> the move (or nil), the job
function AI.Think(pos, strength, seen, seed)
    local job = AI.Start(pos, strength, seen, seed)
    local done, m = false, nil
    for _ = 1, 100000 do
        done, m = job:Step(1000)
        if done then break end
    end
    return m, job
end

-- Counts a node; now and then hands the frame back (a coroutine yield) and checks the time limit. -> true when the
-- search must stop (out of time after a finished pass): every caller then unwinds, taking its moves back.
function Job:Tick()
    if self.aborted then return true end
    local n = self.nodes + 1
    self.nodes = n
    if n % 256 == 0 then
        local now = Clock()
        if self.depthDone >= 1 and ((self.deadline and now > self.deadline) or n > (self.cfg.nodes or 1e9)) then
            self.aborted = true
            return true
        end
        if now > self.sliceEnd or n > self.sliceNodes then
            coroutine.yield()
            self.sliceNodes = self.nodes + self.sliceBudget
            local back = Clock()
            -- (the time limit counts thinking only, not the frames in between)
            if self.deadline then self.deadline = self.deadline + (back - now) end
        end
    end
    return false
end

local function OrderScore(pos, m, killers, ply, pv)
    if m == pv then return 1000000 end
    local b = pos.b
    local to = floor(m / 128) % 128
    local cap = b[to]
    local promo = floor(m / 16384) % 8
    local s = 0
    if cap ~= 0 or floor(m / 131072) == 1 then
        local victim = cap ~= 0 and abs(cap) or 1
        s = 100000 + VALUE[victim] * 10 - (VALUE[abs(b[m % 128])] or 0) / 10
    end
    if promo > 0 then s = s + 90000 + VALUE[promo] end
    local k = killers[ply]
    if s == 0 and k then
        if k[1] == m then s = 80000 elseif k[2] == m then s = 79000 end
    end
    return s
end

-- Sorts list[1..n] by OrderScore, best first (insertion sort: lists are short).
local function Order(self, pos, list, n, ply, pv)
    local sc = self.scores[ply]
    if not sc then sc = {} self.scores[ply] = sc end
    for i = 1, n do sc[i] = OrderScore(pos, list[i], self.killers, ply, pv) end
    for i = 2, n do
        local m, s = list[i], sc[i]
        local j = i - 1
        while j >= 1 and sc[j] < s do
            list[j + 1], sc[j + 1] = list[j], sc[j]
            j = j - 1
        end
        list[j + 1], sc[j + 1] = m, s
    end
end

function Job:List(ply)
    local l = self.lists[ply]
    if not l then l = {} self.lists[ply] = l end
    return l
end

function Job:U(ply)
    local u = self.undo[ply]
    if not u then u = {} self.undo[ply] = u end
    return u
end

function Job:Quiesce(alpha, beta, ply, qdepth)
    if self:Tick() then return 0 end
    local pos = self.pos
    local stand = Evaluate(pos)
    if stand >= beta then return stand end
    if stand > alpha then alpha = stand end
    if qdepth <= 0 then return stand end
    local list = self:List(ply)
    local _, n = R.Pseudo(pos, list, true)
    Order(self, pos, list, n, ply)
    local side = pos.side
    local u = self:U(ply)
    for i = 1, n do
        local m = list[i]
        R.Make(pos, m, u)
        if not R.Attacked(pos, pos.kings[side], -side) then
            local s = -self:Quiesce(-beta, -alpha, ply + 1, qdepth - 1)
            R.Unmake(pos, u)
            if self.aborted then return 0 end
            if s >= beta then return s end
            if s > alpha then alpha = s end
        else
            R.Unmake(pos, u)
        end
    end
    return alpha
end

-- ext: check extensions left on this line (at most 2: a long run of checks must not deepen without end)
function Job:Search(depth, alpha, beta, ply, ext)
    if self:Tick() then return 0 end
    local pos = self.pos
    local side = pos.side
    local inCheck = R.Attacked(pos, pos.kings[side], -side)
    ext = ext or 2
    if inCheck and ext > 0 then depth, ext = depth + 1, ext - 1 end
    if depth <= 0 then return self:Quiesce(alpha, beta, ply, 8) end
    if ply == 1 and (self.seen[R.ToFEN(pos, false)] or 0) >= 2 then return 0 end   -- (a third time: a draw)
    if pos.half >= 100 then return 0 end
    local list = self:List(ply)
    local _, n = R.Pseudo(pos, list)
    Order(self, pos, list, n, ply)
    local u = self:U(ply)
    local legal, best = 0, -INF
    for i = 1, n do
        local m = list[i]
        R.Make(pos, m, u)
        if not R.Attacked(pos, pos.kings[side], -side) then
            legal = legal + 1
            local s = -self:Search(depth - 1, -beta, -alpha, ply + 1, ext)
            R.Unmake(pos, u)
            if self.aborted then return 0 end
            if s > best then best = s end
            if s > alpha then alpha = s end
            if alpha >= beta then
                if pos.b[floor(m / 128) % 128] == 0 then
                    local k = self.killers[ply]
                    if not k then k = {} self.killers[ply] = k end
                    if k[1] ~= m then k[2], k[1] = k[1], m end
                end
                break
            end
        else
            R.Unmake(pos, u)
        end
    end
    if legal == 0 then return inCheck and (-MATE + ply) or 0 end
    return best
end

-- Iterative deepening at the root. Weaker strengths search every root move with the full window (exact scores)
-- and pick with noise; the Guardian takes the best.
function Job:Root()
    local pos = self.pos
    local cfg = self.cfg
    local moves = R.Legal(pos)
    if #moves == 0 then return nil end
    self.best = moves[1]
    if #moves == 1 then return self.best end
    local noise = {}
    for i = 1, #moves do noise[moves[i]] = (self.rng() * 2 - 1) * (cfg.noise or 0) end
    self.depthDone = 0
    self.deadline = Clock() + (cfg.time or 1) * 1000
    local scores = {}
    local u = {}
    for depth = 1, cfg.depth do
        local alpha = -INF
        local got = {}
        for i = 1, #moves do
            local m = moves[i]
            R.Make(pos, m, u)
            local s = -self:Search(depth - 1, -INF, cfg.all and INF or -alpha, 1, 2)
            R.Unmake(pos, u)
            if self.aborted then break end
            -- (a narrow window's answer no better than alpha is only a bound: rank it under the move that set alpha)
            if not cfg.all and i > 1 and s <= alpha then s = min(s, alpha - 1) end
            got[m] = s
            if s > alpha then alpha = s end
        end
        if self.aborted then break end          -- (out of time mid-pass: the last whole pass stands)
        scores = got
        self.depthDone = depth
        -- the next pass looks at the best first (ties keep their order)
        local at = {}
        for i = 1, #moves do at[moves[i]] = i end
        table.sort(moves, function(a, b)
            if scores[a] ~= scores[b] then return scores[a] > scores[b] end
            return at[a] < at[b]
        end)
        self.best = moves[1]
        self.bestScore = scores[moves[1]]
        if abs(scores[moves[1]]) > MATE - 100 then break end   -- (a mate found: deeper changes nothing)
    end
    if (cfg.noise or 0) > 0 and self.depthDone >= 1 then
        local pick, top = nil, -INF
        for i = 1, #moves do
            local m = moves[i]
            local s = scores[m]
            if s then
                -- (never trades a found mate, or walks into one, for noise)
                if abs(s) < MATE - 100 then s = s + noise[m] end
                if s > top then pick, top = m, s end
            end
        end
        self.best = pick or self.best
    end
    self.scores_root = scores
    return self.best
end

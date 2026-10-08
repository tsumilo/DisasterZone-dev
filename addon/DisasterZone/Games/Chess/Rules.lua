if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Chess/Rules.lua", ...) then return end -- DisasterZone Games/Chess/Rules.lua
-- ns.ChessRules: the laws of chess for Karazhan Chess (Games/Chess/), no UI and no saved state.
--
-- A position is a mutable table: b (the board, a 10 x 12 mailbox: index 21 + file + 10 * rank, file and rank 0..7,
-- a1 = 21, h1 = 28, a8 = 91; squares off the board hold OFF), side (1 = white = the Alliance, -1 = black = the Horde),
-- castle (bits: 1 white king side, 2 white queen side, 4 black king side, 8 black queen side), ep (the square a pawn
-- may take en passant on, 0 when none), half (moves since a capture or a pawn move), full (the move number), kings
-- (side -> square). Pieces are numbers: 1 pawn, 2 knight, 3 bishop, 4 rook, 5 queen, 6 king, white positive, black
-- negative, 0 empty.
--
-- Medivh's cheats (Games/Chess/Cheats.lua) add two things the laws below know about, in games against him only:
--   fire  (square -> turns left): a burning square; nobody may enter it, and a line of fire is a wall (it blocks
--         sliding pieces and their attacks). Pieces standing in it may leave.
--   hand  (square -> turns left): a piece Medivh empowered (Hand of Medivh); it may also step one square any way, as a
--         king does, and so attacks the squares round it. The mark moves with the piece.
--
-- A move is one number: from + 128 * to + 16384 * promo + 131072 * flag (flag: 1 en passant, 2 castling, 3 a pawn's
-- double step, 4 a step of an empowered piece). Text form "e2e4", "e7e8q" (the UCI notation).
local _, ns = ...

local R = {}
ns.ChessRules = R

local floor = math.floor
local abs = math.abs
local tconcat = table.concat

local OFF = 99
R.OFF = OFF
R.PAWN, R.KNIGHT, R.BISHOP, R.ROOK, R.QUEEN, R.KING = 1, 2, 3, 4, 5, 6
R.WHITE, R.BLACK = 1, -1
R.START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

local LETTER = { "p", "n", "b", "r", "q", "k" }
local FROM_LETTER = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
R.LETTER = LETTER

local KNIGHT_D = { -21, -19, -12, -8, 8, 12, 19, 21 }
local BISHOP_D = { -11, -9, 9, 11 }
local ROOK_D = { -10, -1, 1, 10 }
local KING_D = { -11, -10, -9, -1, 1, 9, 10, 11 }
local PAWN_CAP_W, PAWN_CAP_B = { 9, 11 }, { -9, -11 }
R.KING_D = KING_D

-- the 64 squares of the mailbox, a1 .. h8 (file first)
local SQ = {}
for rank = 0, 7 do
    for file = 0, 7 do SQ[#SQ + 1] = 21 + file + 10 * rank end
end
R.SQ = SQ

function R.Square(file, rank) return 21 + file + 10 * rank end
function R.File(sq) return (sq - 21) % 10 end
function R.Rank(sq) return floor((sq - 21) / 10) end

function R.SquareName(sq)
    return string.char(97 + R.File(sq)) .. tostring(R.Rank(sq) + 1)
end

function R.ParseSquare(s)
    if type(s) ~= "string" or #s ~= 2 then return nil end
    local f, r = s:byte(1) - 97, s:byte(2) - 49
    if f < 0 or f > 7 or r < 0 or r > 7 then return nil end
    return R.Square(f, r)
end

---------------------------------------------------------------------------
-- Moves as numbers
---------------------------------------------------------------------------

local function Encode(from, to, promo, flag)
    return from + 128 * to + 16384 * (promo or 0) + 131072 * (flag or 0)
end
R.Encode = Encode

function R.From(m) return m % 128 end
function R.To(m) return floor(m / 128) % 128 end
function R.Promo(m) return floor(m / 16384) % 8 end
function R.Flag(m) return floor(m / 131072) end

function R.MoveText(m)
    local p = R.Promo(m)
    return R.SquareName(R.From(m)) .. R.SquareName(R.To(m)) .. (p > 0 and LETTER[p] or "")
end

---------------------------------------------------------------------------
-- Positions
---------------------------------------------------------------------------

local function Empty()
    local b = {}
    for i = 0, 120 do b[i] = OFF end         -- (0 too: a knight on a1 looks 21 back)
    for i = 1, 64 do b[SQ[i]] = 0 end
    return { b = b, side = 1, castle = 0, ep = 0, half = 0, full = 1, kings = { [1] = 0, [-1] = 0 } }
end

-- A position from FEN text, or nil and why not.
function R.FromFEN(fen)
    if type(fen) ~= "string" then return nil, "no text" end
    local placement, side, castle, ep, half, full = fen:match("^%s*(%S+)%s+([wb])%s*(%S*)%s*(%S*)%s*(%d*)%s*(%d*)")
    if not placement then return nil, "bad FEN" end
    local pos = Empty()
    local rank, file = 7, 0
    for i = 1, #placement do
        local ch = placement:sub(i, i)
        if ch == "/" then
            if file ~= 8 then return nil, "bad rank" end
            rank, file = rank - 1, 0
        elseif ch:match("%d") then
            file = file + tonumber(ch)
        else
            local p = FROM_LETTER[ch:lower()]
            if not p or file > 7 or rank < 0 then return nil, "bad piece" end
            local v = (ch == ch:lower()) and -p or p
            local sq = R.Square(file, rank)
            pos.b[sq] = v
            if p == 6 then pos.kings[v > 0 and 1 or -1] = sq end
            file = file + 1
        end
    end
    if rank ~= 0 or file ~= 8 then return nil, "bad board" end
    if pos.kings[1] == 0 or pos.kings[-1] == 0 then return nil, "a king is missing" end
    pos.side = side == "w" and 1 or -1
    local c = 0
    if castle:find("K", 1, true) then c = c + 1 end
    if castle:find("Q", 1, true) then c = c + 2 end
    if castle:find("k", 1, true) then c = c + 4 end
    if castle:find("q", 1, true) then c = c + 8 end
    pos.castle = c
    pos.ep = (ep and ep ~= "-" and R.ParseSquare(ep)) or 0
    pos.half = tonumber(half) or 0
    pos.full = tonumber(full) or 1
    return pos
end

function R.New() return R.FromFEN(R.START) end

-- FEN text of a position (full = false leaves out the two move counters: a key for repetitions).
function R.ToFEN(pos, full)
    local out = {}
    for rank = 7, 0, -1 do
        local run = 0
        for file = 0, 7 do
            local v = pos.b[R.Square(file, rank)]
            if v == 0 then
                run = run + 1
            else
                if run > 0 then out[#out + 1] = tostring(run) run = 0 end
                local l = LETTER[abs(v)]
                out[#out + 1] = v > 0 and l:upper() or l
            end
        end
        if run > 0 then out[#out + 1] = tostring(run) end
        if rank > 0 then out[#out + 1] = "/" end
    end
    local c = pos.castle
    local cs = (c % 2 >= 1 and "K" or "") .. (c % 4 >= 2 and "Q" or "") .. (c % 8 >= 4 and "k" or "")
        .. (c % 16 >= 8 and "q" or "")
    local s = tconcat(out) .. " " .. (pos.side == 1 and "w" or "b") .. " " .. (cs ~= "" and cs or "-") .. " "
        .. (pos.ep ~= 0 and R.SquareName(pos.ep) or "-")
    if full == false then
        -- (fire and empowered pieces change what can happen: a different position for repetitions)
        local extra = {}
        for _, key in ipairs({ "fire", "hand" }) do
            local t = pos[key]
            if t and next(t) then
                local sqs = {}
                for sq in pairs(t) do sqs[#sqs + 1] = sq end
                table.sort(sqs)
                for i = 1, #sqs do sqs[i] = R.SquareName(sqs[i]) end
                extra[#extra + 1] = key:sub(1, 1) .. tconcat(sqs)
            end
        end
        return s .. (#extra > 0 and (" " .. tconcat(extra, " ")) or "")
    end
    return s .. " " .. pos.half .. " " .. pos.full
end

function R.Copy(pos)
    local b = {}
    for i = 0, 120 do b[i] = pos.b[i] end
    local c = { b = b, side = pos.side, castle = pos.castle, ep = pos.ep, half = pos.half, full = pos.full,
                kings = { [1] = pos.kings[1], [-1] = pos.kings[-1] } }
    for _, key in ipairs({ "fire", "hand" }) do
        if pos[key] then
            c[key] = {}
            for k, v in pairs(pos[key]) do c[key][k] = v end
        end
    end
    return c
end

---------------------------------------------------------------------------
-- Attacks
---------------------------------------------------------------------------

-- Is square `sq` attacked by side `by`?
local function Attacked(pos, sq, by)
    local b, fire = pos.b, pos.fire
    -- pawns: a white pawn attacks up (+9, +11), so it stands at sq - 9 / sq - 11
    local pawn = by
    if by == 1 then
        if b[sq - 9] == pawn or b[sq - 11] == pawn then return true end
    else
        if b[sq + 9] == pawn or b[sq + 11] == pawn then return true end
    end
    local knight, king = 2 * by, 6 * by
    for i = 1, 8 do
        if b[sq + KNIGHT_D[i]] == knight then return true end
    end
    for i = 1, 8 do
        if b[sq + KING_D[i]] == king then return true end
    end
    local bishop, rook, queen = 3 * by, 4 * by, 5 * by
    for i = 1, 4 do
        local d = BISHOP_D[i]
        local t = sq + d
        while true do
            local v = b[t]
            if v == OFF or (fire and fire[t]) then break end
            if v ~= 0 then
                if v == bishop or v == queen then return true end
                break
            end
            t = t + d
        end
    end
    for i = 1, 4 do
        local d = ROOK_D[i]
        local t = sq + d
        while true do
            local v = b[t]
            if v == OFF or (fire and fire[t]) then break end
            if v ~= 0 then
                if v == rook or v == queen then return true end
                break
            end
            t = t + d
        end
    end
    local hand = pos.hand
    if hand then
        for h in pairs(hand) do
            local v = b[h]
            if v ~= 0 and v ~= OFF and (v > 0) == (by > 0) and abs(h - sq) <= 11 then
                local df = abs(R.File(h) - R.File(sq))
                if df <= 1 and h ~= sq and abs(R.Rank(h) - R.Rank(sq)) <= 1 then return true end
            end
        end
    end
    return false
end
R.Attacked = Attacked

function R.InCheck(pos, side)
    side = side or pos.side
    return Attacked(pos, pos.kings[side], -side)
end

---------------------------------------------------------------------------
-- Move generation (pseudo-legal: the king may be left in check; Legal filters)
---------------------------------------------------------------------------

local mark = {}

-- The side to move's moves, written into `out` from its start (a list, reused by the AI; returns it and the count).
-- capturesOnly: captures and promotions alone (the AI's quiet search).
function R.Pseudo(pos, out, capturesOnly)
    out = out or {}
    local n = 0
    local len = #out
    local b, side, fire, hand = pos.b, pos.side, pos.fire, pos.hand
    local fwd = 10 * side
    local lastRank = side == 1 and 7 or 0
    local startRank = side == 1 and 1 or 6
    for i = 1, 64 do
        local from = SQ[i]
        local v = b[from]
        if v ~= 0 and (v > 0) == (side > 0) then
            local p = v * side
            local empowered = hand and hand[from] and p ~= 6
            if empowered then for k in pairs(mark) do mark[k] = nil end end
            if p == 1 then
                local t = from + fwd
                if b[t] == 0 and not (fire and fire[t]) then
                    if R.Rank(t) == lastRank then
                        for promo = 5, 2, -1 do n = n + 1 out[n] = Encode(from, t, promo, 0) end
                        if empowered then mark[t] = true end
                    elseif not capturesOnly then
                        n = n + 1 out[n] = Encode(from, t, 0, 0)
                        if empowered then mark[t] = true end
                        local t2 = t + fwd
                        if R.Rank(from) == startRank and b[t2] == 0 and not (fire and fire[t2]) then
                            n = n + 1 out[n] = Encode(from, t2, 0, 3)
                        end
                    end
                end
                local caps = side == 1 and PAWN_CAP_W or PAWN_CAP_B
                for k = 1, 2 do
                    local c = from + caps[k]
                    local w = b[c]
                    if not (fire and fire[c]) then
                        if w ~= OFF and w ~= 0 and (w > 0) ~= (side > 0) then
                            if R.Rank(c) == lastRank then
                                for promo = 5, 2, -1 do n = n + 1 out[n] = Encode(from, c, promo, 0) end
                            else
                                n = n + 1 out[n] = Encode(from, c, 0, 0)
                            end
                            if empowered then mark[c] = true end
                        elseif w == 0 and c == pos.ep then
                            n = n + 1 out[n] = Encode(from, c, 0, 1)
                            if empowered then mark[c] = true end
                        end
                    end
                end
            elseif p == 2 or p == 6 then
                local D = p == 2 and KNIGHT_D or KING_D
                for k = 1, 8 do
                    local t = from + D[k]
                    local w = b[t]
                    if w ~= OFF and not (fire and fire[t]) and (w == 0 and not capturesOnly or w ~= 0 and (w > 0) ~= (side > 0)) then
                        n = n + 1 out[n] = Encode(from, t, 0, 0)
                        if empowered then mark[t] = true end
                    end
                end
                if p == 6 and not capturesOnly then
                    -- castling: the king and rook unmoved (the rights), the squares between empty and not burning,
                    -- the king not in check and not crossing or landing on an attacked square
                    local rights = pos.castle
                    local kBit, qBit = side == 1 and 1 or 4, side == 1 and 2 or 8
                    local home = side == 1 and 25 or 95
                    if from == home then
                        local rookV = 4 * side
                        if rights % (kBit * 2) >= kBit and b[home + 1] == 0 and b[home + 2] == 0
                            and b[home + 3] == rookV
                            and not (fire and (fire[home + 1] or fire[home + 2]))
                            and not Attacked(pos, home, -side) and not Attacked(pos, home + 1, -side)
                            and not Attacked(pos, home + 2, -side) then
                            n = n + 1 out[n] = Encode(from, home + 2, 0, 2)
                        end
                        if rights % (qBit * 2) >= qBit and b[home - 1] == 0 and b[home - 2] == 0 and b[home - 3] == 0
                            and b[home - 4] == rookV
                            and not (fire and (fire[home - 1] or fire[home - 2] or fire[home - 3]))
                            and not Attacked(pos, home, -side) and not Attacked(pos, home - 1, -side)
                            and not Attacked(pos, home - 2, -side) then
                            n = n + 1 out[n] = Encode(from, home - 2, 0, 2)
                        end
                    end
                end
            else
                local D1, D2 = nil, nil
                if p == 3 then D1 = BISHOP_D elseif p == 4 then D1 = ROOK_D else D1, D2 = BISHOP_D, ROOK_D end
                for pass = 1, D2 and 2 or 1 do
                    local D = pass == 1 and D1 or D2
                    for k = 1, 4 do
                        local d = D[k]
                        local t = from + d
                        while true do
                            local w = b[t]
                            if w == OFF or (fire and fire[t]) then break end
                            if w == 0 then
                                if not capturesOnly then n = n + 1 out[n] = Encode(from, t, 0, 0) end
                                if empowered then mark[t] = true end
                            else
                                if (w > 0) ~= (side > 0) then
                                    n = n + 1 out[n] = Encode(from, t, 0, 0)
                                    if empowered then mark[t] = true end
                                end
                                break
                            end
                            t = t + d
                        end
                    end
                end
            end
            if empowered then
                -- Hand of Medivh: one step any way, where the piece's own moves do not already go (a pawn reaching
                -- the last rank so becomes a queen)
                for k = 1, 8 do
                    local t = from + KING_D[k]
                    local w = b[t]
                    if not mark[t] and w ~= OFF and not (fire and fire[t])
                        and (w == 0 and not capturesOnly or w ~= 0 and (w > 0) ~= (side > 0)) then
                        local promo = (p == 1 and R.Rank(t) == lastRank) and 5 or 0
                        n = n + 1 out[n] = Encode(from, t, promo, 4)
                    end
                end
            end
        end
    end
    for k = n + 1, len do out[k] = nil end
    return out, n
end

---------------------------------------------------------------------------
-- Making and taking back moves (in place)
---------------------------------------------------------------------------

local CASTLE_MASK = {}               -- square -> the rights that stay when a piece leaves or lands there
for i = 1, 120 do CASTLE_MASK[i] = 15 end
CASTLE_MASK[25], CASTLE_MASK[21], CASTLE_MASK[28] = 12, 13, 14
CASTLE_MASK[95], CASTLE_MASK[91], CASTLE_MASK[98] = 3, 7, 11

local function KeepBits(rights, mask)
    -- rights AND mask, for 4-bit numbers (Lua 5.1 has no bit operators of its own here)
    local out, bit = 0, 1
    for _ = 1, 4 do
        if rights % (bit * 2) >= bit and mask % (bit * 2) >= bit then out = out + bit end
        bit = bit * 2
    end
    return out
end

-- Plays move m on pos (no legality check). u: a table to fill with what Unmake needs (made when nil). -> u
function R.Make(pos, m, u)
    u = u or {}
    local b = pos.b
    local from, to = m % 128, floor(m / 128) % 128
    local promo, flag = floor(m / 16384) % 8, floor(m / 131072)
    local v = b[from]
    local side = pos.side
    u.m, u.cap, u.capSq, u.castle, u.ep, u.half, u.full = m, b[to], to, pos.castle, pos.ep, pos.half, pos.full
    u.handFrom, u.handTo = nil, nil
    if flag == 1 then
        u.capSq = to - 10 * side
        u.cap = b[u.capSq]
        b[u.capSq] = 0
    end
    local hand = pos.hand
    if hand then
        u.handFrom, u.handTo = hand[from], hand[to]
        hand[to] = hand[from]
        hand[from] = nil
        if flag == 1 then
            u.handEp = hand[u.capSq]
            hand[u.capSq] = nil
        end
    end
    b[to] = promo > 0 and promo * side or v
    b[from] = 0
    if v == 6 * side then
        pos.kings[side] = to
        if flag == 2 then
            local rf, rt = to > from and from + 3 or from - 4, to > from and from + 1 or from - 1
            b[rt], b[rf] = b[rf], 0
            if hand and hand[rf] then hand[rt], hand[rf] = hand[rf], nil end
        end
    end
    pos.castle = KeepBits(KeepBits(pos.castle, CASTLE_MASK[from]), CASTLE_MASK[to])
    pos.ep = flag == 3 and (from + 10 * side) or 0
    if v == side or u.cap ~= 0 then pos.half = 0 else pos.half = pos.half + 1 end
    if side == -1 then pos.full = pos.full + 1 end
    pos.side = -side
    return u
end

function R.Unmake(pos, u)
    local b = pos.b
    local m = u.m
    local from, to = m % 128, floor(m / 128) % 128
    local promo, flag = floor(m / 16384) % 8, floor(m / 131072)
    local side = -pos.side
    pos.side = side
    local v = b[to]
    if promo > 0 then v = side end
    b[from] = v
    b[to] = 0
    b[u.capSq] = u.cap
    if v == 6 * side then
        pos.kings[side] = from
    end
    local hand = pos.hand
    if v == 6 * side and flag == 2 then
        local rf, rt = to > from and from + 3 or from - 4, to > from and from + 1 or from - 1
        b[rf], b[rt] = b[rt], 0
        if hand and hand[rt] then hand[rf], hand[rt] = hand[rt], nil end
    end
    if hand then
        hand[from] = u.handFrom
        hand[to] = u.handTo
        if flag == 1 then hand[u.capSq] = u.handEp end
    end
    pos.castle, pos.ep, pos.half, pos.full = u.castle, u.ep, u.half, u.full
end

---------------------------------------------------------------------------
-- Legal moves and the end of a game
---------------------------------------------------------------------------

local scratchU = {}

-- The side to move's legal moves (a new list).
function R.Legal(pos)
    local pseudo = R.Pseudo(pos, {})
    local out = {}
    local side = pos.side
    for i = 1, #pseudo do
        local m = pseudo[i]
        R.Make(pos, m, scratchU)
        if not Attacked(pos, pos.kings[side], -side) then out[#out + 1] = m end
        R.Unmake(pos, scratchU)
    end
    return out
end

-- Has the side to move any legal move? (stops at the first)
function R.HasMove(pos)
    local pseudo = R.Pseudo(pos, {})
    local side = pos.side
    for i = 1, #pseudo do
        R.Make(pos, pseudo[i], scratchU)
        local ok = not Attacked(pos, pos.kings[side], -side)
        R.Unmake(pos, scratchU)
        if ok then return true end
    end
    return false
end

-- The legal move from text ("e2e4", "e7e8q"), or nil. A promotion without a letter takes a queen.
function R.ParseMove(pos, text)
    if type(text) ~= "string" then return nil end
    local f, t = R.ParseSquare(text:sub(1, 2)), R.ParseSquare(text:sub(3, 4))
    if not f or not t then return nil end
    local promo = FROM_LETTER[text:sub(5, 5)] or 0
    local fallback
    for _, m in ipairs(R.Legal(pos)) do
        if R.From(m) == f and R.To(m) == t then
            local p = R.Promo(m)
            if p == promo then return m end
            if promo == 0 and p == 5 then fallback = m end
        end
    end
    return fallback
end

-- Is there too little left for either side to mate? (king against king, a lone bishop or knight, bishops all on one
-- colour)
function R.Insufficient(pos)
    local b = pos.b
    local minors, bishopColours, knights = 0, {}, 0
    for i = 1, 64 do
        local v = b[SQ[i]]
        local p = abs(v)
        if p == 1 or p == 4 or p == 5 then return false end
        if p == 2 then
            minors, knights = minors + 1, knights + 1
        elseif p == 3 then
            minors = minors + 1
            bishopColours[(R.File(SQ[i]) + R.Rank(SQ[i])) % 2] = true
        end
    end
    if minors <= 1 then return true end
    if knights == 0 and not (bishopColours[0] and bishopColours[1]) then return true end
    return false
end

-- How the game stands for the side to move: nil (play on) or result ("1-0", "0-1", "1/2-1/2") and reason
-- ("checkmate", "stalemate", "fifty", "repetition", "material"). seen: position key -> count (optional).
function R.Outcome(pos, seen)
    if not R.HasMove(pos) then
        if R.InCheck(pos) then return pos.side == 1 and "0-1" or "1-0", "checkmate" end
        return "1/2-1/2", "stalemate"
    end
    if pos.half >= 100 then return "1/2-1/2", "fifty" end
    if seen and (seen[R.ToFEN(pos, false)] or 0) >= 3 then return "1/2-1/2", "repetition" end
    if R.Insufficient(pos) then return "1/2-1/2", "material" end
    return nil
end

---------------------------------------------------------------------------
-- Notation
---------------------------------------------------------------------------

-- Standard algebraic notation of a legal move m in pos ("Nf3", "exd5", "O-O", "e8=Q+", "Qxf7#").
function R.SAN(pos, m, legal)
    local from, to, promo, flag = R.From(m), R.To(m), R.Promo(m), R.Flag(m)
    local v = pos.b[from]
    local p = abs(v)
    local s
    if flag == 2 then
        s = to > from and "O-O" or "O-O-O"
    else
        local capture = pos.b[to] ~= 0 or flag == 1
        if p == 1 then
            s = (capture and (string.char(97 + R.File(from)) .. "x") or "") .. R.SquareName(to)
        else
            s = LETTER[p]:upper()
            -- another piece of the kind that can go there too: say the file, else the rank, else both
            local sameFile, sameRank, other = false, false, false
            for _, o in ipairs(legal or R.Legal(pos)) do
                local of = R.From(o)
                if o ~= m and R.To(o) == to and of ~= from and pos.b[of] == v then
                    other = true
                    if R.File(of) == R.File(from) then sameFile = true end
                    if R.Rank(of) == R.Rank(from) then sameRank = true end
                end
            end
            if other then
                if not sameFile then s = s .. string.char(97 + R.File(from))
                elseif not sameRank then s = s .. tostring(R.Rank(from) + 1)
                else s = s .. R.SquareName(from) end
            end
            s = s .. (capture and "x" or "") .. R.SquareName(to)
        end
        if promo > 0 then s = s .. "=" .. LETTER[promo]:upper() end
    end
    local u = R.Make(pos, m, {})
    if R.InCheck(pos) then s = s .. (R.HasMove(pos) and "+" or "#") end
    R.Unmake(pos, u)
    return s
end

---------------------------------------------------------------------------
-- Counting (tests: perft)
---------------------------------------------------------------------------

function R.Perft(pos, depth)
    if depth == 0 then return 1 end
    local moves = R.Pseudo(pos, {})
    local side = pos.side
    local total = 0
    local u = {}
    for i = 1, #moves do
        R.Make(pos, moves[i], u)
        if not Attacked(pos, pos.kings[side], -side) then
            total = total + (depth == 1 and 1 or R.Perft(pos, depth - 1))
        end
        R.Unmake(pos, u)
    end
    return total
end

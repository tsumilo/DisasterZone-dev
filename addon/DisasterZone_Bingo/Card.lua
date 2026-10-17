if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Bingo/Card.lua", ...) then return end -- DisasterZone_Bingo/Card.lua
-- ns.BingoCard: pure card logic (no frames, no events). A card is an array of 25 square ids (index 13 is the free
-- centre) dealt from the game seed + the player's name key (+ the raid whose pool the game uses), so every client can
-- deal anyone's card again and count their lines from the shared hit set alone.
-- Dealing, like a pack: every card gets the same quality mix (BingoSquares.QUALITY[q].deal: 1 legendary, 2 epic,
-- 4 rare, 7 uncommon, 10 common); in a raid with a pool of its own, up to RAID_DRAW of them come from that pool first.
local addonName, ns = ...

local Card = ns:NewModule("BingoCard")

local SIZE = 5
local CELLS = SIZE * SIZE
local CENTER = 13
local MOD = 2147483647          -- Park-Miller: 16807 * x stays below 2^53, exact in Lua 5.1 doubles

Card.SIZE, Card.CELLS, Card.CENTER = SIZE, CELLS, CENTER

-- Deterministic string hash in [1, MOD - 1].
function Card.Hash(s)
    s = tostring(s)
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % MOD
    end
    if h == 0 then h = 1 end
    return h
end

-- Returns rand(n) -> integer in [1, n], seeded.
function Card.Rng(seed)
    local x = (tonumber(seed) or 1) % MOD
    if x <= 0 then x = x + MOD - 1 end
    return function(n)
        x = (x * 16807) % MOD
        return (x % n) + 1
    end
end

-- The 12 lines (5 rows, 5 columns, 2 diagonals) as arrays of cell indexes; LINE_KIND[i] = "row" / "col" / "diag",
-- LINE_INDEX[i] = which row / column (1-5; the diagonals 1 = top-left to bottom-right, 2 = top-right to bottom-left).
local LINES, LINE_KIND, LINE_INDEX = {}, {}, {}
for r = 0, SIZE - 1 do
    local row, col = {}, {}
    for c = 0, SIZE - 1 do
        row[#row + 1] = r * SIZE + c + 1
        col[#col + 1] = c * SIZE + r + 1
    end
    LINES[#LINES + 1], LINE_KIND[#LINES + 1], LINE_INDEX[#LINES + 1] = row, "row", r + 1
    LINES[#LINES + 1], LINE_KIND[#LINES + 1], LINE_INDEX[#LINES + 1] = col, "col", r + 1
end
do
    local d1, d2 = {}, {}
    for i = 0, SIZE - 1 do
        d1[#d1 + 1] = i * SIZE + i + 1
        d2[#d2 + 1] = i * SIZE + (SIZE - 1 - i) + 1
    end
    LINES[#LINES + 1], LINE_KIND[#LINES + 1], LINE_INDEX[#LINES + 1] = d1, "diag", 1
    LINES[#LINES + 1], LINE_KIND[#LINES + 1], LINE_INDEX[#LINES + 1] = d2, "diag", 2
end
Card.LINES, Card.LINE_KIND, Card.LINE_INDEX = LINES, LINE_KIND, LINE_INDEX

local function Shuffle(list, rand)
    for i = #list, 2, -1 do
        local j = rand(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

-- Deals a card. core / pool: arrays of squares ({ id, q }); pool = the raid's own (nil / empty: none);
-- deal = { [q] = count } (BingoSquares.QUALITY's deal by default); draw = how many may come from the pool.
-- Returns the 25-cell card.
function Card.Deal(seed, playerKey, core, pool, deal, draw)
    local Squares = ns.BingoSquares
    if not deal then
        deal = {}
        for q, info in pairs(Squares.QUALITY) do deal[q] = info.deal end
    end
    draw = draw or Squares.RAID_DRAW
    local rand = Card.Rng(Card.Hash(tostring(seed) .. "|" .. tostring(playerKey)))
    local want, picked = {}, {}
    for q, n in pairs(deal) do want[q] = n end

    -- the raid's pool first: up to `draw` squares, each into a quality slot still open
    if pool and #pool > 0 and draw > 0 then
        local p = {}
        for i, sq in ipairs(pool) do p[i] = sq end
        Shuffle(p, rand)
        local took = 0
        for _, sq in ipairs(p) do
            if took >= draw then break end
            if (want[sq.q] or 0) > 0 then
                picked[#picked + 1] = sq.id
                want[sq.q] = want[sq.q] - 1
                took = took + 1
            end
        end
    end
    -- then the core set, quality by quality (rarest first, so the order of the draws never changes)
    local spare = {}
    for _, q in ipairs(Squares.ORDER) do
        local of = {}
        for _, sq in ipairs(core) do
            if sq.q == q then of[#of + 1] = sq end
        end
        Shuffle(of, rand)
        for i, sq in ipairs(of) do
            if i <= (want[q] or 0) then picked[#picked + 1] = sq.id else spare[#spare + 1] = sq.id end
        end
    end
    -- (a set too small for the mix: fill up from what's left)
    Shuffle(spare, rand)
    local k = 1
    while #picked < CELLS - 1 and spare[k] do
        picked[#picked + 1] = spare[k]
        k = k + 1
    end
    assert(#picked >= CELLS - 1, "BingoCard: set too small")
    Shuffle(picked, rand)

    local card, n = {}, 1
    for cell = 1, CELLS do
        if cell == CENTER then
            card[cell] = Squares.FREE
        else
            card[cell] = picked[n]
            n = n + 1
        end
    end
    return card
end

function Card.IsMarked(id, hits)
    return id == ns.BingoSquares.FREE or (hits ~= nil and hits[id] ~= nil)
end

-- marked[cell] = true for every marked cell: the free centre, every hit square, and extra cells (a set of cell
-- indexes marked on top: the fated square).
function Card.Marks(card, hits, extra)
    local marked = {}
    for cell = 1, CELLS do
        marked[cell] = Card.IsMarked(card[cell], hits) or (extra ~= nil and extra[cell] == true)
    end
    return marked
end

-- The card in numbers from its marks: lines, marked, onLine[cell] (on a complete line), full (complete line
-- indexes), away[cell] (the missing cell of a line one square short), count[li] (marked cells per line).
function Card.Analyze(marked)
    local lines, n, onLine, full, away, count = 0, 0, {}, {}, {}, {}
    for cell = 1, CELLS do
        if marked[cell] then n = n + 1 end
    end
    for li, line in ipairs(LINES) do
        local have, gap = 0, nil
        for _, cell in ipairs(line) do
            if marked[cell] then have = have + 1 else gap = cell end
        end
        count[li] = have
        if have == SIZE then
            lines = lines + 1
            full[#full + 1] = li
            for _, cell in ipairs(line) do onLine[cell] = true end
        elseif have == SIZE - 1 then
            away[gap] = true
        end
    end
    return lines, n, onLine, full, away, count
end

-- Returns completed lines, marked cells (incl. the free centre), and a set of the cells on completed lines.
function Card.Score(card, hits, extra)
    local lines, marked, onLine = Card.Analyze(Card.Marks(card, hits, extra))
    return lines, marked, onLine
end

-- The unmarked cell that brings this card closest to a line (Fated): the most-filled line through it, then the
-- most lines through it at that fill, then the lowest index. nil when the card is full.
function Card.BestGap(marked)
    local best, bestFill, bestLines
    for cell = 1, CELLS do
        if not marked[cell] then
            local fill, nlines = -1, 0
            for _, line in ipairs(LINES) do
                local has, have = false, 0
                for _, c in ipairs(line) do
                    if c == cell then has = true end
                    if marked[c] then have = have + 1 end
                end
                if has then
                    if have > fill then fill, nlines = have, 1
                    elseif have == fill then nlines = nlines + 1 end
                end
            end
            if not best or fill > bestFill or (fill == bestFill and nlines > bestLines) then
                best, bestFill, bestLines = cell, fill, nlines
            end
        end
    end
    return best
end

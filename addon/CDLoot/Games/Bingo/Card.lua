-- CDLoot Games/Bingo/Card.lua
-- ns.BingoCard: pure card logic (no frames, no events). A card is an array of 25 square ids (index 13 is
-- the free centre) built from the game seed + the player's name key, so every client can rebuild anyone's
-- card and count their lines from the shared hit set alone.
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

-- The 12 lines (5 rows, 5 columns, 2 diagonals) as arrays of cell indexes.
local LINES = {}
for r = 0, SIZE - 1 do
    local row, col = {}, {}
    for c = 0, SIZE - 1 do
        row[#row + 1] = r * SIZE + c + 1
        col[#col + 1] = c * SIZE + r + 1
    end
    LINES[#LINES + 1] = row
    LINES[#LINES + 1] = col
end
do
    local d1, d2 = {}, {}
    for i = 0, SIZE - 1 do
        d1[#d1 + 1] = i * SIZE + i + 1
        d2[#d2 + 1] = i * SIZE + (SIZE - 1 - i) + 1
    end
    LINES[#LINES + 1] = d1
    LINES[#LINES + 1] = d2
end
Card.LINES = LINES

-- pool: array of square ids (needs >= 24). Returns the 25-cell card.
function Card.Build(seed, playerKey, pool)
    local ids = {}
    for i = 1, #pool do ids[i] = pool[i] end
    assert(#ids >= CELLS - 1, "BingoCard: pool too small")
    local rand = Card.Rng(Card.Hash(tostring(seed) .. "|" .. tostring(playerKey)))
    for i = #ids, 2, -1 do          -- Fisher-Yates
        local j = rand(i)
        ids[i], ids[j] = ids[j], ids[i]
    end
    local card, k = {}, 1
    for cell = 1, CELLS do
        if cell == CENTER then
            card[cell] = ns.BingoSquares.FREE
        else
            card[cell] = ids[k]
            k = k + 1
        end
    end
    return card
end

function Card.IsMarked(id, hits)
    return id == ns.BingoSquares.FREE or (hits ~= nil and hits[id] ~= nil)
end

-- Returns completed lines, marked cells (incl. the free centre), and a set of the cells on completed lines.
function Card.Score(card, hits)
    local marked = 0
    for cell = 1, CELLS do
        if Card.IsMarked(card[cell], hits) then marked = marked + 1 end
    end
    local lines, onLine = 0, {}
    for _, line in ipairs(LINES) do
        local full = true
        for _, cell in ipairs(line) do
            if not Card.IsMarked(card[cell], hits) then full = false break end
        end
        if full then
            lines = lines + 1
            for _, cell in ipairs(line) do onLine[cell] = true end
        end
    end
    return lines, marked, onLine
end

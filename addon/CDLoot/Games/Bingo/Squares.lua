-- CDLoot Games/Bingo/Squares.lua
-- ns.BingoSquares: the Council Bingo square pool. Every square is detected automatically from raid events
-- (Games/Bingo/Detect.lua). Deliberately nothing about loot or council decisions.
-- rarity: "c" common, "r" rare, "l" legendary (colour only).
local addonName, ns = ...

local Squares = ns:NewModule("BingoSquares")

Squares.FREE = "FREE"

Squares.list = {
    -- deaths
    { id = "death_trash", text = "Someone dies to trash",              rarity = "c" },
    { id = "death_first", text = "A death in the first 30s of a pull", rarity = "r" },
    { id = "mass_death",  text = "3 deaths within 5 seconds",          rarity = "r" },
    { id = "five_deaths", text = "5+ deaths in one boss fight",        rarity = "c" },
    { id = "ten_deaths",  text = "10 deaths tonight",                  rarity = "c" },
    { id = "pet_death",   text = "A pet bites the dust",               rarity = "c" },
    -- bosses
    { id = "wipe",        text = "Wipe!",                              rarity = "c" },
    { id = "wipe_twice",  text = "Wipe twice on the same boss",        rarity = "r" },
    { id = "boss_kill",   text = "Boss down",                          rarity = "c" },
    { id = "flawless",    text = "Boss kill with no deaths",           rarity = "r" },
    { id = "speed_kill",  text = "Boss dies in under 2 minutes",       rarity = "r" },
    { id = "long_fight",  text = "Boss fight lasts over 6 minutes",    rarity = "r" },
    -- combat
    { id = "bres",        text = "Battle rez mid-fight",               rarity = "r" },
    { id = "lust",        text = "Bloodlust / Heroism popped",         rarity = "c" },
    { id = "interrupts",  text = "10 interrupts in one fight",         rarity = "r" },
    { id = "big_crit",    text = "An 8,000+ crit",                     rarity = "r" },
    -- environment
    { id = "fall",        text = "Someone takes fall damage",          rarity = "c" },
    { id = "fire",        text = "Someone stands in fire / lava",      rarity = "r" },
    { id = "drown",       text = "Someone drowns",                     rarity = "l" },
    -- rolls (any /roll 1-100 in the raid)
    { id = "roll_1",      text = "Someone rolls a 1",                  rarity = "l" },
    { id = "roll_100",    text = "Someone rolls 100",                  rarity = "l" },
    { id = "roll_low",    text = "Someone rolls 5 or lower",           rarity = "r" },
    { id = "roll_69",     text = "Someone rolls 69",                   rarity = "r" },
    -- social
    { id = "not_ready",   text = "Someone isn't ready at a ready check", rarity = "c" },
    { id = "dc",          text = "Someone disconnects",                rarity = "r" },
}

Squares.byId = {}
for _, sq in ipairs(Squares.list) do Squares.byId[sq.id] = sq end

function Squares:Get(id) return self.byId[id] end

-- Array of every square id (pool order).
function Squares:Ids()
    local out = {}
    for i, sq in ipairs(self.list) do out[i] = sq.id end
    return out
end

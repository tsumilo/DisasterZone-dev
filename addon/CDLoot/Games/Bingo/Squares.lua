-- CDLoot Games/Bingo/Squares.lua
-- ns.BingoSquares: the Council Bingo square pool. Every square is detected automatically from raid events
-- (Games/Bingo/Detect.lua). Deliberately nothing about loot or council decisions.
-- rarity: "c" common, "r" rare, "l" legendary (colour only). hint: optional tooltip line.
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
    { id = "late_death",  text = "Someone dies in the last 10s of a kill", rarity = "r" },
    { id = "overkill",    text = "Deleted: 5,000+ overkill on a raider", rarity = "r" },
    { id = "early_release", text = "Premature release",                rarity = "r",
      hint = "Someone dies and releases while the boss is still up." },
    -- bosses
    { id = "wipe",        text = "Wipe!",                              rarity = "c" },
    { id = "wipe_twice",  text = "Wipe twice on the same boss",        rarity = "r" },
    { id = "instant_wipe", text = "Instant wipe (under 20s)",          rarity = "r" },
    { id = "boss_kill",   text = "Boss down",                          rarity = "c" },
    { id = "redemption",  text = "Redemption: kill a boss you wiped on", rarity = "c" },
    { id = "flawless",    text = "Boss kill with no deaths",           rarity = "r" },
    { id = "clutch",      text = "Clutch kill: 5 or fewer alive",      rarity = "l",
      hint = "Counts in groups of 10 or more." },
    { id = "speed_kill",  text = "Boss dies in under 2 minutes",       rarity = "r" },
    { id = "long_fight",  text = "Boss fight lasts over 6 minutes",    rarity = "r" },
    -- combat
    { id = "bres",        text = "Battle rez mid-fight",               rarity = "r" },
    { id = "lust",        text = "Bloodlust / Heroism popped",         rarity = "c" },
    { id = "interrupts",  text = "10 interrupts in one fight",         rarity = "r" },
    { id = "big_crit",    text = "An 8,000+ crit",                     rarity = "r" },
    { id = "crushing",    text = "Someone takes a crushing blow",      rarity = "r" },
    { id = "taunt_resist", text = "A taunt gets resisted",             rarity = "r" },
    -- class moments
    { id = "bubble_hearth", text = "Bubble-hearth",                    rarity = "l",
      hint = "A paladin bubbles, then hearths out." },
    { id = "ankh",        text = "Ankh!",                              rarity = "l",
      hint = "A shaman uses Reincarnation." },
    { id = "feign_wipe",  text = "A hunter feigns out of a wipe",      rarity = "r",
      hint = "Feign Death in the last 20 seconds before a wipe." },
    { id = "drums",       text = "Drums!",                             rarity = "c",
      hint = "Drums of Battle, War, Restoration, Speed or Panic." },
    { id = "loh",         text = "Lay on Hands",                       rarity = "r" },
    { id = "healthstone", text = "Healthstone chugged",                rarity = "c" },
    -- environment
    { id = "fall",        text = "Someone takes fall damage",          rarity = "c" },
    { id = "fall_death",  text = "Death by gravity",                   rarity = "l",
      hint = "Someone dies from fall damage." },
    { id = "fire",        text = "Someone stands in fire / lava",      rarity = "r" },
    { id = "drown",       text = "Someone drowns",                     rarity = "l" },
    -- rolls (any /roll 1-100 in the raid unless noted)
    { id = "roll_1",      text = "Someone rolls a 1",                  rarity = "l" },
    { id = "roll_100",    text = "Someone rolls 100",                  rarity = "l" },
    { id = "roll_low",    text = "Someone rolls 5 or lower",           rarity = "r" },
    { id = "roll_69",     text = "Someone rolls 69",                   rarity = "r" },
    { id = "roll_42",     text = "Someone rolls 42",                   rarity = "r" },
    { id = "roll_doubles", text = "Someone rolls doubles (11, 22 ... 99)", rarity = "c" },
    { id = "roll_twins",  text = "Roll twins: same number twice in a row", rarity = "r",
      hint = "Two different raiders roll the same number back to back." },
    { id = "odd_roll",    text = "Someone does a non-standard roll",   rarity = "c",
      hint = "Anything other than /roll 1-100, like /roll 1000." },
    -- raid logistics
    { id = "not_ready",   text = "Someone isn't ready at a ready check", rarity = "c" },
    { id = "rc_asleep",   text = "Someone sleeps through a ready check", rarity = "c",
      hint = "The check ends while someone online never answered." },
    { id = "rc_all_ready", text = "Everyone ready on the first check", rarity = "r",
      hint = "A ready check where every raider clicks Ready." },
    { id = "rc_pull",     text = "Boss pulled during a ready check",   rarity = "l" },
    { id = "idle",        text = "15 minutes without a pull",          rarity = "c",
      hint = "Nobody in the group fights anything for 15 minutes." },
    { id = "dc",          text = "Someone disconnects",                rarity = "r" },
    -- raid chat
    { id = "caps_warning", text = "ALL-CAPS raid warning",             rarity = "c" },
    { id = "sorry",       text = "Someone says sorry in raid chat",    rarity = "c" },
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

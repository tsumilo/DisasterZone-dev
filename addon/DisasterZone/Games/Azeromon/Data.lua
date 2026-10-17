if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Azeromon/Data.lua", ...) then return end -- DisasterZone Games/Azeromon/Data.lua
-- ns.AzeroData: static game data for Azeromon (a monster-taming game in the Pokemon style, WoW themed).
-- Types, the type chart, moves, species (3D creature displays for battle), items, trainers and text.
-- Mechanics follow Generation III: physical / special split by type, stat stages, 1/16 crits, STAB.
local addonName, ns = ...

local D = {}
ns.AzeroData = D

D.SAVE_VERSION = 3            -- 2: the bigger Goldshire (0.27): old Goldshire / inn spots are moved on load
                              -- 3: battles with cooldowns (0.36): every beast relearns its type's kit
D.MAX_PARTY = 6
D.MAX_LEVEL = 100
D.START_MONEY = 3000       -- copper (30 silver)

-- Formats copper the way the game does: 1g 20s 5c.
function D.Money(c)
    c = math.max(0, math.floor(tonumber(c) or 0))
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if k > 0 or #parts == 0 then parts[#parts + 1] = k .. "c" end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Types. Physical types use Atk/Def, special types use SpA/SpD (the Gen III split).
---------------------------------------------------------------------------

D.types = {
    BEAST  = { name = "Beast",  color = { 0.78, 0.74, 0.60 }, physical = true },
    FIRE   = { name = "Fire",   color = { 0.94, 0.45, 0.20 } },
    WATER  = { name = "Water",  color = { 0.30, 0.55, 0.95 } },
    NATURE = { name = "Nature", color = { 0.40, 0.80, 0.30 } },
    EARTH  = { name = "Earth",  color = { 0.80, 0.65, 0.35 }, physical = true },
    AIR    = { name = "Air",    color = { 0.62, 0.72, 0.95 }, physical = true },
    SHADOW = { name = "Shadow", color = { 0.60, 0.40, 0.75 }, physical = true },
    MECH   = { name = "Mech",   color = { 0.62, 0.62, 0.66 }, physical = true },   -- harvest golems (Gnomish work)
}

D.typeOrder = { "BEAST", "FIRE", "WATER", "NATURE", "EARTH", "AIR", "SHADOW", "MECH" }

-- chart[attacking][defending] = multiplier (missing = 1)
D.chart = {
    BEAST  = { EARTH = 0.5, SHADOW = 0.5, MECH = 0.5 },
    FIRE   = { NATURE = 2, MECH = 2, WATER = 0.5, FIRE = 0.5, EARTH = 0.5 },
    WATER  = { FIRE = 2, EARTH = 2, MECH = 2, WATER = 0.5, NATURE = 0.5 },    -- water rusts metal
    NATURE = { WATER = 2, EARTH = 2, FIRE = 0.5, NATURE = 0.5, AIR = 0.5, SHADOW = 0.5, MECH = 0.5 },
    EARTH  = { FIRE = 2, SHADOW = 2, AIR = 0, NATURE = 0.5 },
    AIR    = { NATURE = 2, BEAST = 2, EARTH = 0.5, MECH = 0.5 },
    SHADOW = { NATURE = 2, SHADOW = 0.5, EARTH = 0.5, MECH = 0.5 },
    MECH   = { BEAST = 2, NATURE = 2, FIRE = 0.5, WATER = 0.5, MECH = 0.5 },
}

function D.Effectiveness(atkType, defType)
    local row = D.chart[atkType]
    return row and row[defType] or 1
end

---------------------------------------------------------------------------
-- Moves. power 0 = status move. acc 0 = never misses.
-- effect: { kind = "stat", who = "foe"|"self", stat, stages, chance }
--         { kind = "status", status = "brn"|"psn"|"par"|"slp", chance }
--         { kind = "drain", pct }
-- prio: move priority (Quick Bite +1).
---------------------------------------------------------------------------

D.moves = {
    tackle     = { name = "Charge",       type = "BEAST",  power = 35, acc = 95,  pp = 35 },
    scratch    = { name = "Claw",         type = "BEAST",  power = 40, acc = 100, pp = 35 },
    growl      = { name = "Demoralizing Roar", type = "BEAST",  power = 0,  acc = 100, pp = 40,
                   effect = { kind = "stat", who = "foe", stat = "atk", stages = -1 } },
    leer       = { name = "Sunder Armor", type = "BEAST",  power = 0,  acc = 100, pp = 30,
                   effect = { kind = "stat", who = "foe", stat = "def", stages = -1 } },
    quickbite  = { name = "Quick Bite",   type = "BEAST",  power = 40, acc = 100, pp = 30, prio = 1 },
    tuskgore   = { name = "Gore",         type = "BEAST",  power = 60, acc = 95,  pp = 20 },
    web        = { name = "Web",          type = "BEAST",  power = 0,  acc = 95,  pp = 40,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -1 } },
    bite       = { name = "Bite",         type = "SHADOW", power = 60, acc = 100, pp = 25 },
    venomsting = { name = "Poison Bite",  type = "SHADOW", power = 15, acc = 100, pp = 35,
                   effect = { kind = "status", status = "psn", chance = 30 } },
    hoot       = { name = "Hibernate",     type = "SHADOW", power = 0, acc = 60,  pp = 15,
                   effect = { kind = "status", status = "slp", chance = 100 } },
    ember      = { name = "Scorch",       type = "FIRE",   power = 40, acc = 100, pp = 25,
                   effect = { kind = "status", status = "brn", chance = 10 } },
    flamebreath = { name = "Flame Breath", type = "FIRE",  power = 65, acc = 95,  pp = 15,
                   effect = { kind = "status", status = "brn", chance = 10 } },
    waterjet   = { name = "Water Bolt",   type = "WATER",  power = 40, acc = 100, pp = 25 },
    bubblebeam = { name = "Frost Shock",  type = "WATER",  power = 65, acc = 100, pp = 20,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -1, chance = 10 } },
    leech      = { name = "Siphon Sap",    type = "NATURE", power = 20, acc = 100, pp = 25,
                   effect = { kind = "drain", pct = 50 } },
    thornwhip  = { name = "Thorns",       type = "NATURE", power = 45, acc = 100, pp = 25 },
    razorpetal = { name = "Razor Petal",  type = "NATURE", power = 55, acc = 95,  pp = 25 },
    stunspore  = { name = "Entangling Roots", type = "NATURE", power = 0,  acc = 75,  pp = 30,
                   effect = { kind = "status", status = "par", chance = 100 } },
    mudslap    = { name = "Dust Cloud",   type = "EARTH",  power = 20, acc = 100, pp = 10 },
    rockthrow  = { name = "Rock Throw",   type = "EARTH",  power = 50, acc = 90,  pp = 15 },
    peck       = { name = "Claw Swipe",   type = "AIR",    power = 35, acc = 100, pp = 35 },
    gust       = { name = "Dive",         type = "AIR",    power = 40, acc = 100, pp = 35 },
    -- Westfall and Forest's Edge
    howl       = { name = "Furious Howl", type = "BEAST",  power = 0,  acc = 0,   pp = 20,
                   effect = { kind = "stat", who = "self", stat = "atk", stages = 1 } },
    rend       = { name = "Rend",         type = "BEAST",  power = 55, acc = 95,  pp = 20 },
    maul       = { name = "Maul",         type = "BEAST",  power = 70, acc = 90,  pp = 15 },
    gears      = { name = "Grinding Gears", type = "MECH", power = 40, acc = 100, pp = 30 },
    scythe     = { name = "Scythe Sweep", type = "MECH",   power = 65, acc = 95,  pp = 15 },
    rust       = { name = "Rusty Haze",   type = "MECH",   power = 0,  acc = 90,  pp = 20,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -1 } },
    whirlwind  = { name = "Whirlwind",    type = "AIR",    power = 60, acc = 95,  pp = 20 },
    sandblast  = { name = "Sandblast",    type = "EARTH",  power = 45, acc = 100, pp = 25 },
    carrion    = { name = "Carrion Peck", type = "SHADOW", power = 50, acc = 100, pp = 20,
                   effect = { kind = "status", status = "psn", chance = 20 } },
    pincer     = { name = "Pincer",       type = "WATER",  power = 45, acc = 100, pp = 25 },
    shell      = { name = "Shell Shield", type = "WATER",  power = 0,  acc = 0,   pp = 20,
                   effect = { kind = "stat", who = "self", stat = "def", stages = 1 } },
    tidal      = { name = "Tidal Charge", type = "WATER",  power = 70, acc = 90,  pp = 15 },
    ragged     = { name = "Gnoll Frenzy", type = "SHADOW", power = 60, acc = 95,  pp = 20 },
    hoggerslam = { name = "Hogger Smash", type = "BEAST",  power = 80, acc = 90,  pp = 10 },
    -- the Deadmines
    ogreslam   = { name = "Ogre Slam",    type = "EARTH",  power = 80, acc = 90,  pp = 10 },
    thrash     = { name = "Thrash",       type = "MECH",   power = 75, acc = 90,  pp = 10 },
    molten     = { name = "Molten Metal", type = "FIRE",   power = 70, acc = 95,  pp = 10,
                   effect = { kind = "status", status = "brn", chance = 20 } },
    smitestomp = { name = "Smite Stomp",  type = "EARTH",  power = 70, acc = 95,  pp = 10,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -1, chance = 30 } },
    cleave     = { name = "Cleave",       type = "BEAST",  power = 70, acc = 95,  pp = 15 },
    cutlass    = { name = "Cutlass Slash", type = "SHADOW", power = 65, acc = 100, pp = 15 },
    stew       = { name = "Rotten Stew",  type = "WATER",  power = 55, acc = 100, pp = 10,
                   effect = { kind = "status", status = "psn", chance = 30 } },
    sprint     = { name = "Sprint",       type = "SHADOW", power = 0,  acc = 0,   pp = 10,
                   effect = { kind = "stat", who = "self", stat = "spe", stages = 2 } },
    fireball   = { name = "Fireball",     type = "FIRE",   power = 75, acc = 95,  pp = 15,
                   effect = { kind = "status", status = "brn", chance = 10 } },
    squawk     = { name = "Squawk",       type = "AIR",    power = 0,  acc = 100, pp = 20,
                   effect = { kind = "stat", who = "foe", stat = "atk", stages = -1 } },
    -- the red drake (Emberwhelp's evolution)
    wingbuffet = { name = "Wing Buffet",  type = "AIR",    power = 60, acc = 95,  pp = 20 },
    flamebuffet = { name = "Flame Buffet", type = "FIRE",  power = 80, acc = 90,  pp = 10,
                   effect = { kind = "status", status = "brn", chance = 20 } },
    -- Duskwood
    shadowbolt = { name = "Shadow Bolt",  type = "SHADOW", power = 75, acc = 95,  pp = 15 },
    curse      = { name = "Curse of Weakness", type = "SHADOW", power = 0, acc = 100, pp = 20,
                   effect = { kind = "stat", who = "foe", stat = "atk", stages = -1 } },
    bonearmor  = { name = "Bone Armor",   type = "SHADOW", power = 0,  acc = 0,   pp = 20,
                   effect = { kind = "stat", who = "self", stat = "def", stages = 1 } },
    plague     = { name = "Disease Cloud", type = "SHADOW", power = 40, acc = 100, pp = 20,
                   effect = { kind = "status", status = "psn", chance = 30 } },
    drainlife  = { name = "Drain Life",   type = "SHADOW", power = 50, acc = 100, pp = 15,
                   effect = { kind = "drain", pct = 50 } },
    terrify    = { name = "Terrify",      type = "SHADOW", power = 0,  acc = 90,  pp = 15,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -2 } },
    ravage     = { name = "Ravage",       type = "BEAST",  power = 75, acc = 90,  pp = 15 },
    burrow     = { name = "Burrow",       type = "EARTH",  power = 65, acc = 95,  pp = 15 },
    corrosive  = { name = "Corrosive Poison", type = "NATURE", power = 50, acc = 100, pp = 20,
                   effect = { kind = "status", status = "psn", chance = 20 } },
    -- Stranglethorn and the level 100 chains
    dragonbreath = { name = "Dragon's Breath", type = "FIRE", power = 90, acc = 95, pp = 10,
                   effect = { kind = "status", status = "brn", chance = 20 } },
    inferno    = { name = "Inferno",      type = "FIRE",   power = 110, acc = 85, pp = 5,
                   effect = { kind = "status", status = "brn", chance = 10 } },
    firestorm  = { name = "Firestorm",    type = "FIRE",   power = 120, acc = 80, pp = 5 },
    riptide    = { name = "Riptide",      type = "WATER",  power = 85, acc = 100, pp = 15 },
    tsunami    = { name = "Tsunami",      type = "WATER",  power = 110, acc = 85, pp = 5 },
    maelstrom  = { name = "Maelstrom",    type = "WATER",  power = 120, acc = 80, pp = 5 },
    deathroll  = { name = "Death Roll",   type = "WATER",  power = 80, acc = 95,  pp = 15 },
    shellspin  = { name = "Shell Spin",   type = "WATER",  power = 70, acc = 100, pp = 15,
                   effect = { kind = "stat", who = "self", stat = "def", stages = 1, chance = 30 } },
    crush      = { name = "Crushing Pincer", type = "WATER", power = 95, acc = 90, pp = 10 },
    thornvolley = { name = "Thorn Volley", type = "NATURE", power = 85, acc = 100, pp = 15 },
    regrowth   = { name = "Regrowth",     type = "NATURE", power = 75, acc = 100, pp = 10,
                   effect = { kind = "drain", pct = 50 } },
    overgrowth = { name = "Overgrowth",   type = "NATURE", power = 110, acc = 85, pp = 5 },
    pounce     = { name = "Pounce",       type = "BEAST",  power = 70, acc = 100, pp = 20, prio = 1 },
    feralrage  = { name = "Feral Rage",   type = "BEAST",  power = 100, acc = 90, pp = 10 },
    roar       = { name = "Terrifying Roar", type = "BEAST", power = 0, acc = 100, pp = 15,
                   effect = { kind = "stat", who = "foe", stat = "atk", stages = -2 } },
    chestbeat  = { name = "Chest Beat",   type = "BEAST",  power = 0,  acc = 0,   pp = 15,
                   effect = { kind = "stat", who = "self", stat = "atk", stages = 2 } },
    crushingbite = { name = "Crushing Bite", type = "BEAST", power = 120, acc = 85, pp = 5 },
    throwaxe   = { name = "Throwing Axe", type = "BEAST",  power = 75, acc = 100, pp = 20 },
    earthquake = { name = "Earthquake",   type = "EARTH",  power = 100, acc = 90, pp = 10 },
    stoneskin  = { name = "Stoneskin",    type = "EARTH",  power = 0,  acc = 0,   pp = 15,
                   effect = { kind = "stat", who = "self", stat = "def", stages = 2 } },
    bouldertoss = { name = "Boulder Toss", type = "EARTH", power = 85, acc = 95,  pp = 15 },
    petrify    = { name = "Petrifying Gaze", type = "EARTH", power = 0, acc = 70, pp = 10,
                   effect = { kind = "status", status = "par", chance = 100 } },
    crystalspines = { name = "Crystal Spines", type = "EARTH", power = 70, acc = 100, pp = 20 },
    groundpound = { name = "Ground Pound", type = "EARTH", power = 85, acc = 95,  pp = 15 },
    cyclone    = { name = "Cyclone",      type = "AIR",    power = 95, acc = 90,  pp = 10 },
    skydive    = { name = "Sky Dive",     type = "AIR",    power = 100, acc = 85, pp = 10 },
    tailwind   = { name = "Tailwind",     type = "AIR",    power = 0,  acc = 0,   pp = 15,
                   effect = { kind = "stat", who = "self", stat = "spe", stages = 2 } },
    talon      = { name = "Talon Rake",   type = "AIR",    power = 70, acc = 100, pp = 20 },
    tempest    = { name = "Tempest",      type = "AIR",    power = 120, acc = 80, pp = 5 },
    shadowclaw = { name = "Shadow Claw",  type = "SHADOW", power = 80, acc = 100, pp = 15 },
    deathcoil  = { name = "Death Coil",   type = "SHADOW", power = 90, acc = 95,  pp = 10,
                   effect = { kind = "drain", pct = 50 } },
    hex        = { name = "Hex",          type = "SHADOW", power = 0,  acc = 75,  pp = 10,
                   effect = { kind = "status", status = "slp", chance = 100 } },
    nightmare  = { name = "Nightmare",    type = "SHADOW", power = 110, acc = 85, pp = 5 },
    venomfang  = { name = "Venom Fang",   type = "SHADOW", power = 75, acc = 100, pp = 15,
                   effect = { kind = "status", status = "psn", chance = 30 } },
    prowl      = { name = "Prowl",        type = "SHADOW", power = 0,  acc = 0,   pp = 20,
                   effect = { kind = "stat", who = "self", stat = "atk", stages = 1 } },
    berserk    = { name = "Berserking",   type = "SHADOW", power = 0,  acc = 0,   pp = 10,
                   effect = { kind = "stat", who = "self", stat = "spe", stages = 2 } },
    headhunt   = { name = "Headhunter's Strike", type = "SHADOW", power = 95, acc = 95, pp = 10 },
    buzzsaw    = { name = "Buzzsaw",      type = "MECH",   power = 90, acc = 95,  pp = 10 },
    overdrive  = { name = "Overdrive",    type = "MECH",   power = 0,  acc = 0,   pp = 15,
                   effect = { kind = "stat", who = "self", stat = "atk", stages = 2 } },
    rocketpunch = { name = "Rocket Punch", type = "MECH",  power = 100, acc = 90, pp = 10 },
    sawstorm   = { name = "Sawblade Storm", type = "MECH", power = 120, acc = 80, pp = 5 },
    cannon     = { name = "Cannon Blast", type = "MECH",   power = 100, acc = 80, pp = 5 },
    -- Blackrock. The kinds after "drain" are handled in Battle.lua (every roll on the battle's rng: player
    -- battles stay the same on both clients):
    --   vsstatus { status, mult }   more power when the foe has that status
    --   consume  { status, mult }   more power when the foe has that status, and the hit ends it
    --   armor    { turns }          the user's skin burns whoever lands a physical hit on it
    --   fear     { turns, chance }  the foe may be too afraid to move on each of its next `turns` moves
    --   flinch   { chance }         a foe that has not moved yet this turn loses its move
    --   trap     { stat, stages, status, chance }  the foe can't switch out or run (plus the stat drop / status)
    --   noresist                    never "not very effective"
    --   panic                       the foe skips its next move (once per beast; Free Action blocks it)
    -- pierce = true on a status effect: burns even a FIRE type (FIRE types can't be burned otherwise, like Gen III).
    lavaburst  = { name = "Lava Burst",   type = "FIRE",   power = 90, acc = 100, pp = 10,
                   effect = { kind = "vsstatus", status = "brn", mult = 1.5 } },
    firenova   = { name = "Fire Nova",    type = "FIRE",   power = 70, acc = 100, pp = 15,
                   effect = { kind = "status", status = "brn", chance = 10 } },
    conflagrate = { name = "Conflagrate", type = "FIRE",   power = 60, acc = 100, pp = 10,
                   effect = { kind = "consume", status = "brn", mult = 2.5 } },
    moltenarmor = { name = "Molten Armor", type = "FIRE",  power = 0,  acc = 0,   pp = 10,
                   effect = { kind = "armor", turns = 4 } },
    bellowingroar = { name = "Bellowing Roar", type = "FIRE", power = 0, acc = 100, pp = 10,
                   effect = { kind = "fear", turns = 2, chance = 50 } },
    shadowflame = { name = "Shadow Flame", type = "SHADOW", power = 80, acc = 95, pp = 15,
                   effect = { kind = "status", status = "brn", chance = 30, pierce = true } },
    warstomp   = { name = "War Stomp",    type = "EARTH",  power = 65, acc = 100, pp = 15,
                   effect = { kind = "flinch", chance = 30 } },
    slagtoss   = { name = "Slag Toss",    type = "EARTH",  power = 75, acc = 90,  pp = 15,
                   effect = { kind = "stat", who = "foe", stat = "spe", stages = -1 } },
    magmashackles = { name = "Magma Shackles", type = "EARTH", power = 0, acc = 90, pp = 10,
                   effect = { kind = "trap", stat = "spe", stages = -1 } },
    steamjet   = { name = "Steam Jet",    type = "MECH",   power = 70, acc = 100, pp = 15,
                   effect = { kind = "noresist" } },
    burningweb = { name = "Burning Web",  type = "FIRE",   power = 40, acc = 100, pp = 15,
                   effect = { kind = "trap", status = "brn", chance = 30 } },
    panic      = { name = "Panic",        type = "SHADOW", power = 0,  acc = 85,  pp = 5,
                   effect = { kind = "panic" } },
}

---------------------------------------------------------------------------
-- Species. base = { hp, atk, def, spa, spd, spe }. display = creature display ID, verified on Wowhead TBC
-- (npc -> displayId): Red Whelp 1042 -> 9583, Murloc Raider 515 -> 441, Bloodpetal Lasher 6509 -> 11634,
-- Bloodpetal Flayer 6510 -> 11635, Young Wolf 299 -> 447, Forest Spider 30 -> 382, Kobold Vermin 6 -> 10913,
-- Strigid Owl 1995 -> 10832, Stonetusk Boar 113 -> 503.
-- learn = { { level, move }, ... }   evolve = { level = n, into = id }   catch = catch rate (3..255)
-- evolveItem = { item, into }: using that item from the bag on the beast evolves it (a branch beside `evolve`).
-- rare = true: a night / day rare (not needed for the Bestiary); legendary = true: met once per save, scripted.
-- cam = model camera distance factor in battle (1 = default; bigger = smaller on screen);
-- yoff = extra pixels to lower the model onto its platform.
---------------------------------------------------------------------------

D.species = {
    emberwhelp = { name = "Emberwhelp", type = "FIRE", num = 1, display = 9583, catch = 45, exp = 62,
        base = { 39, 52, 43, 60, 50, 65 },
        desc = "A whelp of the red dragonflight, Alexstrasza's brood. Some say the Dragonmaw stole its egg from Grim Batol.",
        evolve = { level = 16, into = "flamescale" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 7, "ember" }, { 10, "leer" }, { 16, "flamebreath" } } },
    -- display 6371 = the Red Drake (npc 25695) on Wowhead TBC; numbered after the rest so older guild summaries match
    flamescale = { name = "Flamescale Drake", type = "FIRE", num = 45, display = 6371, catch = 45, exp = 142,
        base = { 58, 68, 58, 82, 66, 78 },
        desc = "An Emberwhelp grown into a drake of Alexstrasza's flight. The Dragonmaw once chained its kin at Grim Batol; this one flies with you by choice.",
        evolve = { level = 36, into = "flamewyrm" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 7, "ember" }, { 10, "leer" }, { 16, "flamebreath" },
                  { 20, "wingbuffet" }, { 24, "flamebuffet" } } },
    murkling = { name = "Murkling", type = "WATER", num = 2, display = 441, catch = 45, exp = 63,
        base = { 44, 48, 65, 50, 64, 43 },
        desc = "A young murloc from the shores of Crystal Lake. Mrgllglgl! Fiercely loyal to whoever feeds it fish.",
        evolve = { level = 16, into = "tidehunter" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 7, "waterjet" }, { 10, "bite" }, { 16, "bubblebeam" } } },
    lashling = { name = "Lashling", type = "NATURE", num = 3, display = 11634, cam = 2.4, catch = 45, exp = 64,
        base = { 45, 49, 49, 65, 65, 45 },
        desc = "A bloodpetal sprout carried from Un'Goro Crater by a goblin trader who should have known better.",
        evolve = { level = 14, into = "flaytrap" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 7, "leech" }, { 10, "thornwhip" }, { 13, "stunspore" },
                  { 16, "razorpetal" } } },
    flaytrap = { name = "Flaytrap", type = "NATURE", num = 4, display = 11635, cam = 2.8, catch = 45, exp = 141,
        base = { 60, 62, 63, 80, 80, 60 },
        desc = "A full-grown bloodpetal. In Un'Goro, whole expeditions have gone missing among these.",
        evolve = { level = 34, into = "thresher" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 7, "leech" }, { 10, "thornwhip" }, { 13, "stunspore" },
                  { 16, "razorpetal" } } },
    wolfpup = { name = "Wolfpup", type = "BEAST", num = 5, display = 447, catch = 190, exp = 55,
        base = { 40, 56, 35, 30, 35, 70 },
        desc = "A young Elwynn wolf. The Stormwind Guard pays a bounty for their paws, but tamed ones are loyal for life.",
        evolve = { level = 16, into = "prowler" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 5, "quickbite" }, { 11, "bite" } } },
    webling = { name = "Webling", type = "SHADOW", num = 6, display = 382, catch = 190, exp = 52,
        base = { 40, 50, 40, 35, 40, 45 },
        desc = "A forest spider from the woods around Goldshire. It strings webs between the tall grass stalks.",
        evolve = { level = 16, into = "minespider" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 9, "bite" } } },
    kobling = { name = "Kobling", type = "EARTH", num = 7, display = 10913, catch = 190, exp = 58,
        base = { 45, 55, 50, 25, 35, 35 },
        desc = "A kobold runt from Fargodeep Mine. You no take candle! It hoards anything that glitters.",
        evolve = { level = 16, into = "tunneler" },
        learn = { { 1, "scratch" }, { 1, "mudslap" }, { 8, "rockthrow" }, { 12, "leer" } } },
    owlet = { name = "Owlet", type = "AIR", num = 8, display = 10832, cam = 1.4, catch = 255, exp = 50,
        base = { 40, 45, 40, 35, 35, 56 },
        desc = "A strigid owl chick from Teldrassil, far from home. Night elf druids say its hooting brings sleep.",
        evolve = { level = 16, into = "screecher" },
        learn = { { 1, "peck" }, { 1, "growl" }, { 6, "hoot" }, { 10, "gust" } } },
    tuskling = { name = "Tuskling", type = "BEAST", num = 9, display = 503, catch = 150, exp = 60,
        base = { 50, 58, 48, 25, 30, 40 },
        desc = "A stonetusk boar piglet from the Brackwell Pumpkin Patch. It charges first and never thinks later.",
        evolve = { level = 16, into = "goretusk" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 8, "mudslap" }, { 12, "tuskgore" } } },

    -- Evolutions of the Elwynn beasts
    -- Murloc Tidehunter 127 -> 1995, Goretusk 157 -> 3027
    tidehunter = { name = "Tidehunter", type = "WATER", num = 10, display = 1995, catch = 45, exp = 142,
        base = { 64, 70, 78, 62, 74, 55 },
        desc = "A murloc grown into a hunter of the Westfall coast. It leads raids on the fishing camps at dusk.",
        evolve = { level = 34, into = "tidecaller" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 7, "waterjet" }, { 10, "bite" }, { 16, "bubblebeam" },
                  { 20, "tidal" } } },
    goretusk = { name = "Goretusk", type = "BEAST", num = 11, display = 3027, catch = 90, exp = 138,
        base = { 75, 84, 70, 30, 45, 55 },
        desc = "A grown boar of the Westfall plains. Farmers say a goretusk can plough a field faster than a horse, badly.",
        evolve = { level = 34, into = "greatgoretusk" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 8, "mudslap" }, { 12, "tuskgore" }, { 18, "rend" } } },

    -- Forest's Edge (Hogger's Riverpaw gnolls)
    -- Riverpaw Runt 97 -> 10791, Riverpaw Brute 124 -> 384, Riverpaw Scout 500 -> 374, Hogger 448 -> 384
    runt = { name = "Riverpaw Runt", type = "SHADOW", num = 12, display = 10791, catch = 150, exp = 60,
        base = { 45, 60, 40, 30, 35, 50 },
        desc = "The smallest of the Riverpaw gnolls. It follows Hogger around and eats whatever he drops.",
        evolve = { level = 16, into = "brute" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 6, "bite" }, { 10, "ragged" }, { 14, "howl" } } },
    brute = { name = "Riverpaw Brute", type = "SHADOW", num = 13, display = 384, catch = 60, exp = 140,
        base = { 70, 90, 65, 35, 50, 60 },
        desc = "A full-grown Riverpaw gnoll. Stormwind posts bounties on these, but a tamed one guards like a mastiff.",
        evolve = { level = 36, into = "taskmaster" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 6, "bite" }, { 10, "ragged" }, { 14, "howl" }, { 20, "maul" } } },
    scout = { name = "Riverpaw Scout", type = "BEAST", num = 14, display = 374, catch = 120, exp = 68,
        base = { 50, 58, 45, 40, 40, 72 },
        desc = "A lean gnoll that runs messages between Hogger's camp and the Riverpaw packs in Westfall.",
        learn = { { 1, "quickbite" }, { 1, "leer" }, { 8, "sandblast" }, { 12, "rend" } } },
    hogger = { name = "Hogger", type = "BEAST", num = 15, display = 384, cam = 0.85, catch = 3, exp = 200, boss = true,
        base = { 95, 100, 80, 45, 60, 55 },
        desc = "The terror of Elwynn Forest. Many adventurers have gone looking for Hogger. Most came back smaller.",
        learn = { { 1, "maul" }, { 1, "howl" }, { 1, "ragged" }, { 1, "hoggerslam" } } },

    -- Westfall
    -- Coyote 834 -> 643, Coyote Packleader 833 -> 161, Fleshripper 1109 -> 2305, Rusty Harvest Golem 480 -> 514,
    -- Harvest Reaper 115 -> 379, Dust Devil 832 -> 5327, Shore Crawler 1216 -> 9570, Sand Crawler 830 -> 342,
    -- Murloc Coastrunner 126 -> 983
    coyote = { name = "Coyote", type = "BEAST", num = 16, display = 643, catch = 190, exp = 62,
        base = { 45, 62, 42, 30, 38, 68 },
        desc = "A Westfall coyote. They howl all night outside the Jansen Stead and steal the Saldeans' chickens.",
        evolve = { level = 18, into = "packleader" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 6, "quickbite" }, { 10, "howl" }, { 13, "bite" } } },
    packleader = { name = "Coyote Packleader", type = "BEAST", num = 17, display = 161, catch = 60, exp = 150,
        base = { 65, 86, 60, 40, 55, 88 },
        desc = "The alpha of a Westfall coyote pack. The others will not eat until it has.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 6, "quickbite" }, { 10, "howl" }, { 13, "bite" }, { 20, "rend" } } },
    fleshripper = { name = "Fleshripper", type = "AIR", num = 18, display = 2305, catch = 150, exp = 70,
        base = { 50, 64, 45, 40, 45, 70 },
        desc = "A Westfall vulture. Where Defias have been, the fleshrippers circle soon after.",
        evolve = { level = 34, into = "greaterripper" },
        learn = { { 1, "peck" }, { 1, "leer" }, { 8, "gust" }, { 12, "carrion" }, { 16, "whirlwind" } } },
    rustgolem = { name = "Rusty Harvest Golem", type = "MECH", num = 19, display = 514, catch = 120, exp = 75,
        base = { 60, 66, 75, 30, 40, 30 },
        desc = "A gnomish harvest golem left to rust. The Defias reprogrammed the working ones to guard their fields.",
        evolve = { level = 18, into = "reaper" },
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" } } },
    reaper = { name = "Harvest Reaper", type = "MECH", num = 20, display = 379, catch = 45, exp = 160,
        base = { 80, 92, 100, 35, 55, 40 },
        desc = "A harvest golem rebuilt for war. Its scythes were meant for wheat.",
        evolve = { level = 36, into = "watcher" },
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" }, { 22, "maul" } } },
    dustdevil = { name = "Dust Devil", type = "AIR", num = 21, display = 5327, cam = 1.3, catch = 90, exp = 80,
        base = { 55, 50, 50, 70, 55, 80 },
        desc = "A whirl of Westfall dust that never quite settles. The drought feeds them.",
        evolve = { level = 36, into = "duststormer" },
        learn = { { 1, "gust" }, { 1, "mudslap" }, { 8, "sandblast" }, { 14, "whirlwind" } } },
    crawler = { name = "Shore Crawler", type = "WATER", num = 22, display = 9570, catch = 190, exp = 58,
        base = { 45, 55, 70, 35, 45, 35 },
        desc = "A crab of the Westfall coast. It pinches anything that stands still long enough.",
        evolve = { level = 18, into = "sandcrawler" },
        learn = { { 1, "tackle" }, { 1, "shell" }, { 7, "pincer" }, { 12, "bubblebeam" } } },
    sandcrawler = { name = "Sand Crawler", type = "WATER", num = 23, display = 342, catch = 60, exp = 140,
        base = { 65, 78, 100, 45, 60, 40 },
        desc = "An old crawler with a shell like a shield. Longshore fishermen use their claws as hooks.",
        evolve = { level = 36, into = "monstrouscrawler" },
        learn = { { 1, "tackle" }, { 1, "shell" }, { 7, "pincer" }, { 12, "bubblebeam" }, { 20, "tidal" } } },
    coastrunner = { name = "Coastrunner", type = "WATER", num = 24, display = 983, catch = 150, exp = 64,
        base = { 48, 58, 50, 48, 50, 62 },
        desc = "A Westfall murloc scout. Mrrrgl! It runs up and down the Longshore warning the others.",
        evolve = { level = 32, into = "netter" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 7, "waterjet" }, { 11, "pincer" }, { 15, "bite" } } },

    -- Rares (rare = true: rare-spawn alert, "A rare ... appeared!", a gold name). Night rares roam after dusk;
    -- raid rares appear for 24 hours after your guild kills the matching raid boss (D.raidRares).
    -- Mother Fang 471 -> 2541, Ghostpaw Alpha 3825 -> 776, Midnight 16151 -> 19640, The Big Bad Wolf 17521 -> 17053,
    -- Nightbane 17225 -> 18062, Gruul 19044 -> 18698, Magtheridon 17257 -> 18527, The Lurker Below 21217 -> 20216,
    -- Al'ar 19514 -> 18945
    motherfang = { name = "Mother Fang", type = "SHADOW", num = 25, display = 2541, catch = 30, exp = 120, rare = true,
        base = { 60, 74, 55, 40, 50, 72 },
        desc = "The broodmother of Jasperlode Mine. She only leaves the dark to hunt when the moon is up.",
        learn = { { 1, "venomsting" }, { 1, "web" }, { 1, "bite" }, { 12, "carrion" } } },
    ghostpaw = { name = "Ghostpaw", type = "SHADOW", num = 26, display = 776, catch = 30, exp = 125, rare = true,
        base = { 58, 72, 50, 60, 55, 88 },
        desc = "A spirit wolf that walks the Westfall fields at night. Farmers leave meat out so it passes them by.",
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 1, "bite" }, { 12, "ragged" } } },
    midnight = { name = "Midnight", type = "BEAST", num = 27, display = 19640, catch = 20, exp = 160, rare = true,
        base = { 72, 88, 62, 45, 55, 92 },
        desc = "Attumen the Huntsman's spectral steed, loose in Elwynn since the Huntsman fell in Karazhan.",
        learn = { { 1, "tackle" }, { 1, "quickbite" }, { 1, "howl" }, { 16, "rend" } } },
    bigbadwolf = { name = "Big Bad Wolf", type = "BEAST", num = 28, display = 17053, catch = 20, exp = 160, rare = true,
        base = { 82, 92, 60, 40, 50, 72 },
        desc = "Escaped from Karazhan's Opera stage. My, what big teeth it has.",
        learn = { { 1, "bite" }, { 1, "howl" }, { 1, "rend" }, { 16, "maul" } } },
    nightbane = { name = "Nightbane Whelp", type = "SHADOW", num = 29, display = 18062, catch = 15, exp = 170, rare = true,
        base = { 70, 72, 66, 88, 66, 70 },
        desc = "A bone-drake hatchling from Karazhan's tower. It smells of ash and old magic.",
        learn = { { 1, "bite" }, { 1, "flamebreath" }, { 1, "ragged" }, { 16, "whirlwind" } } },
    gronnling = { name = "Gronnling", type = "EARTH", num = 30, display = 18698, catch = 15, exp = 170, rare = true,
        base = { 98, 96, 82, 30, 50, 40 },
        desc = "A gronn youngling, carried out of Gruul's Lair by who knows what. Already taller than a Stormwind guard.",
        learn = { { 1, "rockthrow" }, { 1, "maul" }, { 1, "sandblast" }, { 16, "howl" } } },
    pitling = { name = "Pitling", type = "SHADOW", num = 31, display = 18527, catch = 15, exp = 170, rare = true,
        base = { 86, 90, 76, 82, 70, 45 },
        desc = "Spawn of Magtheridon, the pit lord chained beneath Hellfire Citadel. It hates chains.",
        learn = { { 1, "ragged" }, { 1, "flamebreath" }, { 1, "maul" }, { 16, "carrion" } } },
    lurkling = { name = "Lurkling", type = "WATER", num = 32, display = 20216, catch = 15, exp = 170, rare = true,
        base = { 92, 84, 86, 72, 72, 45 },
        desc = "Something from Serpentshrine Cavern found its way to the Longshore. Fishermen are staying home.",
        learn = { { 1, "tidal" }, { 1, "bubblebeam" }, { 1, "bite" }, { 16, "shell" } } },
    ashling = { name = "Ashling", type = "FIRE", num = 33, display = 18945, catch = 15, exp = 170, rare = true,
        base = { 70, 70, 60, 96, 70, 92 },
        desc = "A phoenix spark reborn from Al'ar's ashes after the fall of Tempest Keep.",
        learn = { { 1, "ember" }, { 1, "flamebreath" }, { 1, "gust" }, { 16, "whirlwind" } } },

    -- The Deadmines. Mine Spider 43 -> 368, Kobold Tunneler 475 -> 139, Sneed's Shredder 642 -> 1269,
    -- Defias Companion 3450 -> 5207 (the pirates' parrot)
    tunneler = { name = "Kobold Tunneler", type = "EARTH", num = 34, display = 139, catch = 90, exp = 140,
        base = { 70, 82, 76, 35, 50, 50 },
        desc = "A kobold grown into a real digger. The Defias pay them in candles to widen the mine.",
        evolve = { trade = true, into = "geomancer" },
        learn = { { 1, "scratch" }, { 1, "mudslap" }, { 8, "rockthrow" }, { 12, "leer" }, { 18, "sandblast" } } },
    -- Kobold Geomancer (npc 476, display 163 on Wowhead TBC): a Tunneler evolves into one when it is traded
    geomancer = { name = "Kobold Geomancer", type = "EARTH", num = 46, display = 163, catch = 45, exp = 175,
        base = { 70, 60, 70, 100, 85, 75 },
        desc = "A Tunneler that has seen the world beyond its mine comes back talking to the rock, and setting things on fire.",
        learn = { { 1, "scratch" }, { 1, "mudslap" }, { 1, "ember" }, { 8, "rockthrow" }, { 12, "leer" },
                  { 18, "sandblast" }, { 22, "fireball" } } },
    minespider = { name = "Mine Spider", type = "SHADOW", num = 35, display = 368, catch = 120, exp = 110,
        base = { 60, 76, 58, 45, 55, 70 },
        desc = "A spider of the Deadmines. It nests in the timbers and drops on miners who forget to look up.",
        evolve = { level = 36, into = "tarantula" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 10, "bite" }, { 16, "carrion" } } },
    shredder = { name = "Goblin Shredder", type = "MECH", num = 36, display = 1269, catch = 45, exp = 160,
        base = { 80, 96, 92, 40, 55, 50 },
        desc = "Goblin engineering with saw blades for arms. The Defias bought a fleet of them to cut the ship's timbers.",
        learn = { { 1, "gears" }, { 1, "rust" }, { 14, "scythe" }, { 20, "thrash" } } },
    parrot = { name = "Defias Parrot", type = "AIR", num = 37, display = 5207, cam = 1.3, catch = 150, exp = 105,
        base = { 55, 62, 50, 55, 55, 88 },
        desc = "Every self-respecting Defias pirate has one. It knows more swear words than the crew.",
        learn = { { 1, "peck" }, { 1, "squawk" }, { 10, "gust" }, { 16, "whirlwind" } } },

    -- Deadmines bosses (boss = true: never tamed, not needed for the Bestiary). Rhahk'Zor 644 -> 14403,
    -- Gilnid 1763 -> 7124, Mr. Smite 646 -> 2026, Captain Greenskin 647 -> 7113, Cookie 645 -> 1305,
    -- Edwin VanCleef 639 -> 2029
    rhahkzor = { name = "Rhahk'Zor", type = "EARTH", num = 38, display = 14403, catch = 3, exp = 220, boss = true,
        base = { 110, 105, 90, 30, 55, 40 },
        desc = "The Defias foreman. Big. Angry. VanCleef tells him what to smash.",
        learn = { { 1, "ogreslam" }, { 1, "maul" }, { 1, "rockthrow" }, { 1, "howl" } } },
    sneedshredder = { name = "Sneed's Shredder", type = "MECH", num = 39, display = 1269, catch = 3, exp = 220, boss = true,
        base = { 100, 108, 104, 40, 60, 55 },
        desc = "Sneed's personal shredder, customised with bigger blades and a louder engine.",
        learn = { { 1, "thrash" }, { 1, "scythe" }, { 1, "gears" }, { 1, "rust" } } },
    gilnid = { name = "Gilnid", type = "FIRE", num = 40, display = 7124, catch = 3, exp = 220, boss = true,
        base = { 90, 70, 80, 100, 80, 70 },
        desc = "The goblin smelter who pours the Juggernaut's iron. He smells of hot slag.",
        learn = { { 1, "molten" }, { 1, "flamebreath" }, { 1, "ember" }, { 1, "gears" } } },
    smite = { name = "Mr. Smite", type = "BEAST", num = 41, display = 2026, catch = 3, exp = 230, boss = true,
        base = { 110, 108, 88, 40, 70, 60 },
        desc = "VanCleef's tauren first mate. He switches weapons when he gets angry, which is often.",
        learn = { { 1, "smitestomp" }, { 1, "cleave" }, { 1, "maul" }, { 1, "howl" } } },
    greenskin = { name = "Captain Greenskin", type = "WATER", num = 42, display = 7113, catch = 3, exp = 230, boss = true,
        base = { 100, 96, 84, 80, 76, 72 },
        desc = "The goblin captain of the Juggernaut. He'd sell the ship twice if VanCleef let him.",
        learn = { { 1, "tidal" }, { 1, "cutlass" }, { 1, "bubblebeam" }, { 1, "squawk" } } },
    cookie = { name = "Cookie", type = "WATER", num = 43, display = 1305, catch = 3, exp = 230, boss = true,
        base = { 104, 90, 86, 86, 80, 64 },
        desc = "The Juggernaut's murloc cook. Nobody asks what is in the stew. Nobody.",
        learn = { { 1, "stew" }, { 1, "tidal" }, { 1, "bite" }, { 1, "shell" } } },
    vancleef = { name = "Edwin VanCleef", type = "SHADOW", num = 44, display = 2029, catch = 3, exp = 260, boss = true,
        base = { 120, 115, 90, 70, 85, 100 },
        desc = "Master stonemason of Stormwind, cheated of his wages, now leader of the Defias Brotherhood.",
        learn = { { 1, "cutlass" }, { 1, "sprint" }, { 1, "ragged" }, { 1, "cleave" } } },

    -- Duskwood (Wowhead TBC npc -> displayId): Skeletal Warrior 48 -> 200, Skeletal Horror 202 -> 9786,
    -- Flesh Eater 3 -> 987, Brain Eater 570 -> 569, Pygmy Venom Web Spider 539 -> 958, Venom Web Spider 217 -> 955,
    -- Nightbane Dark Runner 205 -> 736, Nightbane Vile Fang 206 -> 522, Black Ravager 628 -> 741,
    -- Black Ravager Mastiff 1258 -> 9562, Flesh Eating Worm 2462 -> 10996, Splinter Fist Warrior 212 -> 610,
    -- Lupos 521 -> 11412
    skeleton = { name = "Skeletal Warrior", type = "SHADOW", num = 47, display = 200, catch = 120, exp = 112,
        base = { 55, 80, 72, 35, 50, 55 },
        desc = "Raised from Raven Hill's graves by Morbent Fel. It still carries the sword it was buried with.",
        evolve = { level = 30, into = "skelhorror" },
        learn = { { 1, "tackle" }, { 1, "bonearmor" }, { 22, "cutlass" }, { 26, "leer" }, { 28, "cleave" } } },
    skelhorror = { name = "Skeletal Horror", type = "SHADOW", num = 48, display = 9786, catch = 45, exp = 172,
        base = { 80, 102, 92, 45, 65, 60 },
        desc = "A skeleton that has walked long enough to grow a taste for it. The Night Watch burns what's left.",
        evolve = { level = 50, into = "skelfiend" },
        learn = { { 1, "tackle" }, { 1, "bonearmor" }, { 22, "cutlass" }, { 26, "leer" }, { 28, "cleave" },
                  { 30, "terrify" } } },
    flesheater = { name = "Flesh Eater", type = "SHADOW", num = 49, display = 987, catch = 120, exp = 112,
        base = { 72, 80, 55, 40, 50, 48 },
        desc = "A ghoul of the Tranquil Gardens. Keep your lunch, and your fingers, out of its reach.",
        evolve = { level = 29, into = "braineater" },
        learn = { { 1, "scratch" }, { 1, "plague" }, { 22, "bite" }, { 26, "drainlife" } } },
    braineater = { name = "Brain Eater", type = "SHADOW", num = 50, display = 569, catch = 45, exp = 168,
        base = { 98, 100, 70, 45, 65, 48 },
        desc = "A ghoul grown big on Duskwood's dead. It only ever wants one thing, and it's in its name.",
        evolve = { level = 50, into = "rottedone" },
        learn = { { 1, "scratch" }, { 1, "plague" }, { 22, "bite" }, { 26, "drainlife" }, { 29, "terrify" },
                  { 33, "maul" } } },
    pygmyweb = { name = "Pygmy Venom Web Spider", type = "NATURE", num = 51, display = 958, catch = 190, exp = 72,
        base = { 45, 62, 50, 55, 50, 82 },
        desc = "Small, green and everywhere in Duskwood's undergrowth. Its bite is worse than its size.",
        evolve = { level = 27, into = "venomweb" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 22, "corrosive" }, { 25, "leech" } } },
    venomweb = { name = "Venom Web Spider", type = "NATURE", num = 52, display = 955, catch = 90, exp = 150,
        base = { 65, 82, 66, 72, 66, 96 },
        desc = "It webs the trees over the Duskwood road and waits. The Night Watch cuts the webs every morning.",
        evolve = { level = 46, into = "glassweb" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 22, "corrosive" }, { 25, "leech" }, { 30, "bite" } } },
    darkrunner = { name = "Nightbane Dark Runner", type = "SHADOW", num = 53, display = 736, catch = 90, exp = 125,
        base = { 70, 92, 60, 45, 55, 92 },
        desc = "A worgen of the Nightbane pack. They came through Duskwood's woods with the curse, and never left.",
        evolve = { level = 32, into = "vilefang" },
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 22, "bite" }, { 26, "rend" }, { 30, "terrify" } } },
    vilefang = { name = "Nightbane Vile Fang", type = "SHADOW", num = 54, display = 522, catch = 45, exp = 182,
        base = { 90, 112, 76, 50, 65, 96 },
        desc = "The Nightbane's biggest and oldest. Darkshire's Night Watch posts double guards when one is seen.",
        evolve = { level = 52, into = "shadowweaver" },
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 22, "bite" }, { 26, "rend" }, { 30, "terrify" },
                  { 32, "ravage" }, { 36, "ragged" } } },
    ravager = { name = "Black Ravager", type = "BEAST", num = 55, display = 741, catch = 120, exp = 110,
        base = { 65, 86, 60, 35, 50, 86 },
        desc = "Duskwood's black hounds. They hunt in the dark between the trees, which is all of Duskwood.",
        evolve = { level = 30, into = "mastiff" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 22, "bite" }, { 25, "rend" }, { 28, "howl" } } },
    mastiff = { name = "Black Ravager Mastiff", type = "BEAST", num = 56, display = 9562, catch = 45, exp = 170,
        base = { 90, 106, 80, 40, 65, 86 },
        desc = "The leader of a ravager pack. It bites first and doesn't bother asking questions.",
        evolve = { level = 58, into = "corehound" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 22, "bite" }, { 25, "rend" }, { 28, "howl" }, { 30, "ravage" },
                  { 34, "maul" } } },
    worm = { name = "Flesh Eating Worm", type = "EARTH", num = 57, display = 10996, cam = 1.2, catch = 150, exp = 100,
        base = { 82, 72, 86, 30, 50, 30 },
        desc = "It lives in the cemeteries. Nobody asks what it eats, because everyone already knows.",
        learn = { { 1, "mudslap" }, { 1, "bite" }, { 24, "burrow" }, { 28, "sandblast" } } },
    splinterfist = { name = "Splinter Fist Ogre", type = "EARTH", num = 58, display = 610, catch = 60, exp = 162,
        base = { 96, 106, 82, 30, 55, 40 },
        desc = "An ogre of the Splinter Fist clan from Vul'Gol. It hits things. It is very good at hitting things.",
        evolve = { level = 44, into = "mauler" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 25, "rockthrow" }, { 29, "ogreslam" } } },
    lupos = { name = "Lupos", type = "SHADOW", num = 59, display = 11412, catch = 25, exp = 178, rare = true,
        base = { 76, 96, 66, 60, 60, 106 },
        desc = "A spectral hound that stalks Duskwood's roads at night. Watchers swear it has no shadow.",
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 1, "bite" }, { 26, "ravage" } } },

    -- Duskwood's haunts and Stitches (boss = true). Mor'Ladim 522 -> 21691, Morbent Fel 1200 -> 4272,
    -- Stalvan Mistmantle 315 -> 1562, Stitches 412 -> 1693
    morladim = { name = "Mor'Ladim", type = "SHADOW", num = 60, display = 21691, catch = 3, exp = 240, boss = true,
        base = { 130, 118, 100, 60, 85, 70 },
        desc = "A restless warrior who walks the Raven Hill cemetery at night, and cuts down anyone he meets there.",
        learn = { { 1, "cleave" }, { 1, "cutlass" }, { 1, "bonearmor" }, { 1, "terrify" } } },
    morbentfel = { name = "Morbent Fel", type = "SHADOW", num = 61, display = 4272, catch = 3, exp = 245, boss = true,
        base = { 120, 116, 92, 60, 100, 86 },
        desc = "The necromancer who took the Yorgen farm. Blows pass through him, unless you carry Morbent's Bane.",
        learn = { { 1, "shadowbolt" }, { 1, "drainlife" }, { 1, "curse" }, { 1, "terrify" } } },
    stalvan = { name = "Stalvan Mistmantle", type = "SHADOW", num = 62, display = 1562, catch = 3, exp = 250, boss = true,
        base = { 125, 112, 95, 60, 95, 90 },
        desc = "The last master of Manor Mistmantle. What he did there, the Night Watch won't say aloud.",
        learn = { { 1, "shadowbolt" }, { 1, "curse" }, { 1, "drainlife" }, { 1, "cutlass" } } },
    stitches = { name = "Stitches", type = "SHADOW", num = 63, display = 1693, cam = 0.9, catch = 3, exp = 270, boss = true,
        base = { 160, 126, 110, 40, 80, 45 },
        desc = "Abercrombie's creation, sewn from Duskwood's dead. It walks toward Darkshire, and it doesn't stop.",
        learn = { { 1, "cleave" }, { 1, "plague" }, { 1, "maul" }, { 1, "bonearmor" } } },

    ---------------------------------------------------------------------------
    -- Later forms of the Elwynn, Westfall, Deadmines and Duskwood lines (level 100 chains). Display IDs verified
    -- on Wowhead TBC (npc -> displayId): Vaelastrasz 13020 -> 13992, Emberstrife 10321 -> 6374,
    -- Murloc Oracle 517 -> 1079, Saltscale Tide Lord 875 -> 391, Bloodpetal Thresher 6511 -> 11633,
    -- Bloodpetal Trapper 6512 -> 11636, Prowler 118 -> 11415, Worg 1765 -> 11421, Giant Ember Worg 9697 -> 9370,
    -- Tarantula 442 -> 366, Deathstrike Tarantula 769 -> 336, Strigid Screecher 1996 -> 4877,
    -- Strigid Hunter 1997 -> 10830, Thunderhead Hippogryph 6375 -> 6757, Great Goretusk 547 -> 3035,
    -- Riverpaw Taskmaster 98 -> 376, Greater Fleshripper 154 -> 1105, Roc 5428 -> 3248, Harvest Watcher 114 -> 378,
    -- Crowd Pummeler 9-60 6229 -> 6774, Dust Stormer 11744 -> 8715, Cyclonian 6239 -> 5187,
    -- Monstrous Crawler 1088 -> 699, Murloc Netter 513 -> 1994, Murloc Warrior 171 -> 1305,
    -- Skeletal Fiend 531 -> 7550, Rotted One 948 -> 137, Sul'lithuz Abomination 8120 -> 7345,
    -- Nightbane Shadow Weaver 533 -> 203, Nightbane Tainted One 920 -> 1098, Mosh'Ogg Mauler 678 -> 416, Mosh'Ogg Lord 680 -> 11569
    ---------------------------------------------------------------------------
    flamewyrm = { name = "Flamescale Wyrm", type = "FIRE", num = 64, display = 13992, cam = 0.9, catch = 30, exp = 200,
        base = { 80, 88, 78, 110, 90, 95 },
        desc = "A drake grown into a true wyrm of the red flight. Its wings darken the road from Goldshire to Westfall.",
        evolve = { level = 60, into = "emberancient" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 7, "ember" }, { 10, "leer" }, { 16, "flamebreath" },
                  { 20, "wingbuffet" }, { 24, "flamebuffet" }, { 36, "dragonbreath" }, { 46, "cyclone" },
                  { 54, "inferno" } } },
    emberancient = { name = "Ember Ancient", type = "FIRE", num = 65, display = 6374, cam = 0.8, catch = 20, exp = 260,
        base = { 100, 105, 95, 135, 110, 105 },
        desc = "A wyrm old enough to remember Grim Batol's chains. Alexstrasza herself would not call it young.",
        learn = { { 1, "scratch" }, { 1, "growl" }, { 7, "ember" }, { 10, "leer" }, { 16, "flamebreath" },
                  { 20, "wingbuffet" }, { 24, "flamebuffet" }, { 36, "dragonbreath" }, { 46, "cyclone" },
                  { 54, "inferno" }, { 60, "roar" }, { 74, "firestorm" } } },
    tidecaller = { name = "Murloc Tidecaller", type = "WATER", num = 66, display = 1079, catch = 40, exp = 190,
        base = { 84, 80, 92, 96, 98, 70 },
        desc = "A Tidehunter that learned to speak with the tide. The whole shoal listens when it gurgles.",
        evolve = { level = 56, into = "tidelord" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 7, "waterjet" }, { 10, "bite" }, { 16, "bubblebeam" },
                  { 20, "tidal" }, { 34, "riptide" }, { 42, "hex" }, { 50, "tsunami" } } },
    tidelord = { name = "Saltscale Tide Lord", type = "WATER", num = 67, display = 391, catch = 25, exp = 250,
        base = { 105, 100, 110, 115, 115, 85 },
        desc = "Lord of a Stranglethorn shoal. Whole fishing fleets have turned back at the sight of one on the rocks.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 7, "waterjet" }, { 10, "bite" }, { 16, "bubblebeam" },
                  { 20, "tidal" }, { 34, "riptide" }, { 42, "hex" }, { 50, "tsunami" }, { 56, "shell" },
                  { 70, "maelstrom" } } },
    thresher = { name = "Bloodpetal Thresher", type = "NATURE", num = 68, display = 11633, cam = 2.8, catch = 40, exp = 190,
        base = { 80, 85, 84, 100, 100, 75 },
        desc = "A Flaytrap that has grown a third row of thorns. It threshes anything that walks into its reach.",
        evolve = { level = 58, into = "trapper" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 7, "leech" }, { 10, "thornwhip" }, { 13, "stunspore" },
                  { 16, "razorpetal" }, { 34, "thornvolley" }, { 46, "regrowth" } } },
    trapper = { name = "Bloodpetal Trapper", type = "NATURE", num = 69, display = 11636, cam = 3.0, catch = 20, exp = 250,
        base = { 110, 100, 105, 120, 120, 80 },
        desc = "The oldest bloodpetals of Un'Goro. Expeditions mark them on the map and walk the long way round.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 7, "leech" }, { 10, "thornwhip" }, { 13, "stunspore" },
                  { 16, "razorpetal" }, { 34, "thornvolley" }, { 46, "regrowth" }, { 58, "overgrowth" },
                  { 72, "earthquake" } } },
    prowler = { name = "Prowler", type = "BEAST", num = 70, display = 11415, catch = 120, exp = 120,
        base = { 62, 80, 56, 40, 50, 95 },
        desc = "A grown Elwynn wolf. It hunts the Stonecairn shore at dusk and comes home smelling of murloc.",
        evolve = { level = 36, into = "worg" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 5, "quickbite" }, { 11, "bite" }, { 16, "rend" }, { 24, "howl" },
                  { 30, "pounce" } } },
    worg = { name = "Worg", type = "BEAST", num = 71, display = 11421, catch = 60, exp = 175,
        base = { 82, 102, 72, 45, 60, 105 },
        desc = "A wolf grown into a worg, the kind the orcs ride. It no longer fits through the Lion's Pride's door.",
        evolve = { level = 60, into = "emberworg" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 5, "quickbite" }, { 11, "bite" }, { 16, "rend" }, { 24, "howl" },
                  { 30, "pounce" }, { 36, "ravage" }, { 48, "feralrage" } } },
    emberworg = { name = "Ember Worg", type = "FIRE", num = 72, display = 9370, catch = 30, exp = 240,
        base = { 100, 125, 90, 70, 75, 110 },
        desc = "A worg that walked too deep into Blackrock Mountain and came out with fire in its coat.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 5, "quickbite" }, { 11, "bite" }, { 16, "rend" }, { 24, "howl" },
                  { 30, "pounce" }, { 36, "ravage" }, { 48, "feralrage" }, { 60, "flamebreath" }, { 76, "inferno" } } },
    tarantula = { name = "Tarantula", type = "SHADOW", num = 73, display = 366, catch = 60, exp = 165,
        base = { 80, 96, 74, 55, 65, 90 },
        desc = "A mine spider grown fat and hairy in the Redridge hills. Its bite swells a hand to twice its size.",
        evolve = { level = 58, into = "deathstrike" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 9, "bite" }, { 16, "carrion" }, { 36, "shadowclaw" },
                  { 46, "venomfang" } } },
    deathstrike = { name = "Deathstrike Tarantula", type = "SHADOW", num = 74, display = 336, catch = 30, exp = 235,
        base = { 100, 118, 92, 70, 80, 105 },
        desc = "Swamp of Sorrows' worst. One bite, they say, and you have until sundown.",
        learn = { { 1, "venomsting" }, { 1, "web" }, { 9, "bite" }, { 16, "carrion" }, { 36, "shadowclaw" },
                  { 46, "venomfang" }, { 58, "hex" }, { 70, "nightmare" } } },
    screecher = { name = "Strigid Screecher", type = "AIR", num = 75, display = 4877, cam = 1.3, catch = 150, exp = 115,
        base = { 58, 64, 55, 60, 55, 90 },
        desc = "An owlet that found its voice. Teldrassil's sentinels use their screech as an alarm.",
        evolve = { level = 34, into = "strigidhunter" },
        learn = { { 1, "peck" }, { 1, "growl" }, { 6, "hoot" }, { 10, "gust" }, { 16, "talon" }, { 22, "wingbuffet" },
                  { 28, "whirlwind" } } },
    strigidhunter = { name = "Strigid Hunter", type = "AIR", num = 76, display = 10830, cam = 1.2, catch = 80, exp = 170,
        base = { 76, 88, 70, 80, 72, 112 },
        desc = "A full-grown strigid owl. It takes rabbits, rats, and once, a gnome's hat with the gnome still under it.",
        evolve = { level = 58, into = "hippogryph" },
        learn = { { 1, "peck" }, { 1, "growl" }, { 6, "hoot" }, { 10, "gust" }, { 16, "talon" }, { 22, "wingbuffet" },
                  { 28, "whirlwind" }, { 34, "tailwind" }, { 46, "skydive" } } },
    hippogryph = { name = "Hippogryph", type = "AIR", num = 77, display = 6757, catch = 30, exp = 240,
        base = { 98, 108, 90, 95, 90, 125 },
        desc = "The night elves' winged steed, with an owl's head and a stag's legs. It answers to no bridle.",
        learn = { { 1, "peck" }, { 1, "growl" }, { 6, "hoot" }, { 10, "gust" }, { 16, "talon" }, { 22, "wingbuffet" },
                  { 28, "whirlwind" }, { 34, "tailwind" }, { 46, "skydive" }, { 58, "cyclone" }, { 72, "tempest" } } },
    greatgoretusk = { name = "Great Goretusk", type = "BEAST", num = 78, display = 3035, catch = 45, exp = 190,
        base = { 100, 112, 96, 40, 60, 70 },
        desc = "The biggest boar in Westfall. It has flattened three fences, a wagon and a Defias camp.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 8, "mudslap" }, { 12, "tuskgore" }, { 18, "rend" }, { 34, "maul" },
                  { 46, "groundpound" }, { 60, "earthquake" } } },
    taskmaster = { name = "Riverpaw Taskmaster", type = "SHADOW", num = 79, display = 376, catch = 40, exp = 195,
        base = { 96, 118, 88, 50, 70, 80 },
        desc = "A Brute who bullied his way to the top of the Riverpaw pack. Hogger is the only one it still fears.",
        learn = { { 1, "scratch" }, { 1, "growl" }, { 6, "bite" }, { 10, "ragged" }, { 14, "howl" }, { 20, "maul" },
                  { 36, "cleave" }, { 48, "shadowclaw" }, { 62, "feralrage" } } },
    greaterripper = { name = "Greater Fleshripper", type = "AIR", num = 80, display = 1105, catch = 80, exp = 150,
        base = { 72, 90, 64, 55, 60, 96 },
        desc = "A vulture that no longer waits for things to die.",
        evolve = { level = 56, into = "roc" },
        learn = { { 1, "peck" }, { 1, "leer" }, { 8, "gust" }, { 12, "carrion" }, { 16, "whirlwind" }, { 34, "talon" },
                  { 44, "tailwind" } } },
    roc = { name = "Roc", type = "AIR", num = 81, display = 3248, cam = 0.9, catch = 30, exp = 235,
        base = { 100, 116, 88, 70, 80, 118 },
        desc = "The great carrion bird of Tanaris. Its shadow alone sends the Wastewander running for cover.",
        learn = { { 1, "peck" }, { 1, "leer" }, { 8, "gust" }, { 12, "carrion" }, { 16, "whirlwind" }, { 34, "talon" },
                  { 44, "tailwind" }, { 56, "skydive" }, { 68, "cyclone" } } },
    watcher = { name = "Harvest Watcher", type = "MECH", num = 82, display = 378, catch = 30, exp = 210,
        base = { 105, 110, 125, 45, 70, 50 },
        desc = "A harvest golem plated for war. The Defias had it guarding the Dead Acre; now it guards you.",
        evolve = { level = 60, into = "pummeler" },
        evolveItem = { item = "darkironbar", into = "heavygolem" },     -- a branch: a Dark Iron Bar from the bag
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" }, { 22, "maul" }, { 36, "buzzsaw" },
                  { 48, "overdrive" } } },
    pummeler = { name = "Crowd Pummeler", type = "MECH", num = 83, display = 6774, cam = 0.85, catch = 20, exp = 265,
        base = { 125, 130, 140, 50, 85, 60 },
        desc = "Gnomeregan's Crowd Pummeler 9-60, rebuilt from three harvest golems and a lot of copper wire.",
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" }, { 22, "maul" }, { 36, "buzzsaw" },
                  { 48, "overdrive" }, { 60, "rocketpunch" }, { 74, "sawstorm" } } },
    duststormer = { name = "Dust Stormer", type = "AIR", num = 84, display = 8715, cam = 1.3, catch = 60, exp = 170,
        base = { 80, 72, 70, 105, 80, 110 },
        desc = "A dust devil that has drunk a whole drought. It tears roofs off the Westfall farms for sport.",
        evolve = { level = 58, into = "cyclonian" },
        learn = { { 1, "gust" }, { 1, "mudslap" }, { 8, "sandblast" }, { 14, "whirlwind" }, { 36, "cyclone" },
                  { 46, "tailwind" } } },
    cyclonian = { name = "Cyclonian", type = "AIR", num = 85, display = 5187, cam = 1.4, catch = 25, exp = 240,
        base = { 100, 90, 88, 130, 100, 130 },
        desc = "A storm given a name. The Whirlwind Warrior of Alterac was once bound to one of these.",
        learn = { { 1, "gust" }, { 1, "mudslap" }, { 8, "sandblast" }, { 14, "whirlwind" }, { 36, "cyclone" },
                  { 46, "tailwind" }, { 58, "skydive" }, { 72, "tempest" } } },
    monstrouscrawler = { name = "Monstrous Crawler", type = "WATER", num = 86, display = 699, catch = 40, exp = 195,
        base = { 95, 105, 130, 60, 80, 50 },
        desc = "A crab the size of a rowboat. The Longshore fishermen stopped using their claws as hooks.",
        learn = { { 1, "tackle" }, { 1, "shell" }, { 7, "pincer" }, { 12, "bubblebeam" }, { 20, "tidal" },
                  { 36, "riptide" }, { 48, "crush" }, { 62, "tsunami" } } },
    netter = { name = "Murloc Netter", type = "WATER", num = 87, display = 1994, catch = 90, exp = 130,
        base = { 68, 78, 70, 66, 68, 82 },
        desc = "A Coastrunner that took up the net. It catches fish, crabs, and the odd Defias smuggler.",
        evolve = { level = 52, into = "murlocwarrior" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 7, "waterjet" }, { 11, "pincer" }, { 15, "bite" },
                  { 32, "bubblebeam" }, { 40, "riptide" } } },
    murlocwarrior = { name = "Murloc Warrior", type = "WATER", num = 88, display = 1305, catch = 45, exp = 200,
        base = { 92, 106, 90, 80, 84, 96 },
        desc = "A murloc that fights with a spear instead of its teeth. It still bites, mind.",
        learn = { { 1, "scratch" }, { 1, "leer" }, { 7, "waterjet" }, { 11, "pincer" }, { 15, "bite" },
                  { 32, "bubblebeam" }, { 40, "riptide" }, { 52, "cutlass" }, { 64, "tsunami" } } },
    skelfiend = { name = "Skeletal Fiend", type = "SHADOW", num = 89, display = 7550, catch = 30, exp = 230,
        base = { 100, 122, 110, 60, 80, 70 },
        desc = "A skeleton that has gathered other skeletons' bones onto itself. It is mostly claws now.",
        learn = { { 1, "tackle" }, { 1, "bonearmor" }, { 22, "cutlass" }, { 26, "leer" }, { 28, "cleave" },
                  { 30, "terrify" }, { 50, "shadowclaw" }, { 62, "nightmare" }, { 76, "deathcoil" } } },
    rottedone = { name = "Rotted One", type = "SHADOW", num = 90, display = 137, catch = 30, exp = 225,
        base = { 120, 116, 88, 60, 80, 55 },
        desc = "A ghoul so far gone it has stopped falling apart and started growing. Abercrombie takes notes.",
        evolve = { level = 70, into = "abomination" },
        learn = { { 1, "scratch" }, { 1, "plague" }, { 22, "bite" }, { 26, "drainlife" }, { 29, "terrify" },
                  { 33, "maul" }, { 50, "shadowclaw" }, { 60, "deathcoil" } } },
    abomination = { name = "Abomination", type = "SHADOW", num = 91, display = 7345, cam = 0.85, catch = 15, exp = 290,
        base = { 160, 135, 110, 70, 95, 50 },
        desc = "Stitched from a dozen Rotted Ones. It smells worse than it looks, and it looks very bad.",
        learn = { { 1, "scratch" }, { 1, "plague" }, { 22, "bite" }, { 26, "drainlife" }, { 29, "terrify" },
                  { 33, "maul" }, { 50, "shadowclaw" }, { 60, "deathcoil" }, { 70, "cleave" }, { 84, "nightmare" } } },
    shadowweaver = { name = "Nightbane Shadow Weaver", type = "SHADOW", num = 92, display = 203, catch = 30, exp = 230,
        base = { 105, 126, 90, 80, 80, 110 },
        desc = "A worgen that learned the curse's own magic. The Night Watch lost two Watchers finding that out.",
        evolve = { level = 72, into = "taintedone" },
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 22, "bite" }, { 26, "rend" }, { 30, "terrify" },
                  { 32, "ravage" }, { 36, "ragged" }, { 52, "shadowclaw" }, { 62, "hex" } } },
    taintedone = { name = "Nightbane Tainted One", type = "SHADOW", num = 93, display = 1098, catch = 15, exp = 285,
        base = { 125, 145, 105, 95, 95, 120 },
        desc = "The eldest of the Nightbane pack. It was a man once. It remembers, and it doesn't care.",
        learn = { { 1, "quickbite" }, { 1, "howl" }, { 22, "bite" }, { 26, "rend" }, { 30, "terrify" },
                  { 32, "ravage" }, { 36, "ragged" }, { 52, "shadowclaw" }, { 62, "hex" }, { 72, "nightmare" },
                  { 86, "feralrage" } } },
    mauler = { name = "Mosh'Ogg Mauler", type = "EARTH", num = 94, display = 416, catch = 40, exp = 220,
        base = { 120, 128, 100, 45, 70, 55 },
        desc = "An ogre of the Mosh'Ogg mound in Stranglethorn. It carries a tree, and it is not a small tree.",
        evolve = { level = 66, into = "ogrelord" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 25, "rockthrow" }, { 29, "ogreslam" }, { 44, "groundpound" },
                  { 56, "cleave" } } },
    ogrelord = { name = "Mosh'Ogg Lord", type = "EARTH", num = 95, display = 11569, cam = 0.85, catch = 15, exp = 285,
        base = { 150, 145, 120, 90, 95, 60 },
        desc = "Two heads, one club. The heads argue about who gets to swing it.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 25, "rockthrow" }, { 29, "ogreslam" }, { 44, "groundpound" },
                  { 56, "cleave" }, { 66, "earthquake" }, { 80, "fireball" } } },

    ---------------------------------------------------------------------------
    -- Stranglethorn Vale (Wowhead TBC npc -> displayId): Young Stranglethorn Tiger 681 -> 598,
    -- Stranglethorn Tiger 682 -> 320, Elder Stranglethorn Tiger 1085 -> 698, Zulian Tiger 11361 -> 11031,
    -- Young Panther 683 -> 2437, Panther 736 -> 599, Shadowmaw Panther 684 -> 633,
    -- Elder Shadowmaw Panther 1713 -> 11452, Young Lashtail Raptor 856 -> 2571, Lashtail Raptor 686 -> 788,
    -- Jungle Stalker 687 -> 11317, Devilsaur 6498 -> 5239, Mistvale Gorilla 1108 -> 843,
    -- Elder Mistvale Gorilla 1557 -> 838, Silverback Patriarch 1558 -> 844, Crystal Spine Basilisk 689 -> 601,
    -- Cold Eye Basilisk 690 -> 8797, Ironjaw Basilisk 1551 -> 2174, River Crocolisk 1150 -> 1039,
    -- Saltwater Crocolisk 1151 -> 2548, Elder Saltwater Crocolisk 2635 -> 815, Bloodscalp Scout 588 -> 4575,
    -- Bloodscalp Berserker 597 -> 4579, Skullsplitter Berserker 783 -> 4623, Saltwater Snapjaw 2505 -> 5027,
    -- Zanzil Zombie 1488 -> 1065, Bhag'thera 728 -> 613, Tethis 730 -> 8472, King Bangalash 731 -> 616,
    -- Colonel Kurzen 813 -> 637, Gan'zulah 1061 -> 4582, Mai'Zoth 818 -> 11546, Zanzil the Outcast 2534 -> 314,
    -- King Mukla 1559 -> 792, Fleet Master Firallon 2546 -> 797
    ---------------------------------------------------------------------------
    tigercub = { name = "Young Stranglethorn Tiger", type = "BEAST", num = 96, display = 598, catch = 120, exp = 130,
        base = { 70, 90, 60, 45, 55, 100 },
        desc = "A tiger cub of the northern vale. Nesingwary's hunters call them 'practice'. The cubs disagree.",
        evolve = { level = 36, into = "tiger" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 28, "quickbite" }, { 31, "rend" }, { 34, "pounce" } } },
    tiger = { name = "Stranglethorn Tiger", type = "BEAST", num = 97, display = 320, catch = 60, exp = 185,
        base = { 90, 112, 75, 50, 65, 115 },
        desc = "The vale's great striped hunter. Sir Erlgadin has a rug of one, and a scar from another.",
        evolve = { level = 48, into = "eldertiger" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 28, "quickbite" }, { 31, "rend" }, { 34, "pounce" },
                  { 40, "ravage" }, { 46, "roar" } } },
    eldertiger = { name = "Elder Stranglethorn Tiger", type = "BEAST", num = 98, display = 698, catch = 35, exp = 240,
        base = { 105, 128, 88, 55, 75, 125 },
        desc = "An old tiger that has outlived three generations of hunters. It knows every trap in the vale.",
        evolve = { level = 66, into = "zuliantiger" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 28, "quickbite" }, { 31, "rend" }, { 34, "pounce" },
                  { 40, "ravage" }, { 46, "roar" }, { 48, "feralrage" }, { 58, "cleave" } } },
    zuliantiger = { name = "Zulian Tiger", type = "SHADOW", num = 99, display = 11031, catch = 15, exp = 295,
        base = { 120, 145, 100, 80, 90, 135 },
        desc = "A tiger touched by the Gurubashi's loa. High Priest Thekal rode one into battle; this one chose you.",
        learn = { { 1, "scratch" }, { 1, "growl" }, { 28, "quickbite" }, { 31, "rend" }, { 34, "pounce" },
                  { 40, "ravage" }, { 46, "roar" }, { 48, "feralrage" }, { 58, "cleave" }, { 66, "shadowclaw" },
                  { 80, "nightmare" } } },
    pantherkit = { name = "Young Panther", type = "SHADOW", num = 100, display = 2437, catch = 120, exp = 130,
        base = { 62, 88, 58, 55, 55, 110 },
        desc = "A panther kit from the shadows under the vale's canopy. You hear it long before you see it. Usually.",
        evolve = { level = 36, into = "panther" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 28, "quickbite" }, { 31, "bite" }, { 34, "prowl" } } },
    panther = { name = "Panther", type = "SHADOW", num = 101, display = 599, catch = 60, exp = 185,
        base = { 82, 108, 72, 65, 68, 125 },
        desc = "Black as the space between the trees. Ajeck Rouack has hunted them for years and seen four.",
        evolve = { level = 48, into = "shadowmaw" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 28, "quickbite" }, { 31, "bite" }, { 34, "prowl" },
                  { 40, "shadowclaw" }, { 46, "ravage" } } },
    shadowmaw = { name = "Shadowmaw Panther", type = "SHADOW", num = 102, display = 633, catch = 35, exp = 240,
        base = { 96, 124, 84, 80, 80, 138 },
        desc = "The vale's night terror. Its coat drinks the light; its eyes give it back.",
        evolve = { level = 64, into = "eldershadowmaw" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 28, "quickbite" }, { 31, "bite" }, { 34, "prowl" },
                  { 40, "shadowclaw" }, { 46, "ravage" }, { 48, "pounce" }, { 58, "hex" } } },
    eldershadowmaw = { name = "Elder Shadowmaw Panther", type = "SHADOW", num = 103, display = 11452, catch = 15, exp = 290,
        base = { 112, 140, 98, 95, 92, 150 },
        desc = "The Skullsplitter trolls leave meat at the ruins for it. Some of the meat used to be Skullsplitters.",
        learn = { { 1, "scratch" }, { 1, "leer" }, { 28, "quickbite" }, { 31, "bite" }, { 34, "prowl" },
                  { 40, "shadowclaw" }, { 46, "ravage" }, { 48, "pounce" }, { 58, "hex" }, { 64, "feralrage" },
                  { 78, "nightmare" } } },
    raptorling = { name = "Young Lashtail Raptor", type = "BEAST", num = 104, display = 2571, catch = 120, exp = 135,
        base = { 66, 92, 62, 45, 50, 105 },
        desc = "A raptor hatchling from the Lashtail nests by the river. It already knows to go for the ankles.",
        evolve = { level = 38, into = "lashtail" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "quickbite" }, { 33, "rend" }, { 36, "talon" } } },
    lashtail = { name = "Lashtail Raptor", type = "BEAST", num = 105, display = 788, catch = 60, exp = 190,
        base = { 84, 112, 78, 50, 60, 120 },
        desc = "A grown Lashtail. They hunt in threes, and the third one is always behind you.",
        evolve = { level = 50, into = "junglestalker" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "quickbite" }, { 33, "rend" }, { 36, "talon" },
                  { 42, "ravage" }, { 48, "pounce" } } },
    junglestalker = { name = "Jungle Stalker", type = "BEAST", num = 106, display = 11317, catch = 35, exp = 245,
        base = { 100, 130, 90, 55, 70, 130 },
        desc = "The vale's biggest raptor. It stalks the road to the arena, and the crowds stalk the road in groups.",
        evolve = { level = 70, into = "devilsaur" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "quickbite" }, { 33, "rend" }, { 36, "talon" },
                  { 42, "ravage" }, { 48, "pounce" }, { 50, "feralrage" }, { 60, "roar" } } },
    devilsaur = { name = "Devilsaur", type = "BEAST", num = 107, display = 5239, cam = 0.75, catch = 10, exp = 320,
        base = { 150, 160, 110, 60, 85, 105 },
        desc = "The king of Un'Goro Crater. Nobody knows how a Jungle Stalker becomes one. Nobody stays to find out.",
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "quickbite" }, { 33, "rend" }, { 36, "talon" },
                  { 42, "ravage" }, { 48, "pounce" }, { 50, "feralrage" }, { 60, "roar" }, { 70, "crushingbite" },
                  { 86, "earthquake" } } },
    gorilla = { name = "Mistvale Gorilla", type = "BEAST", num = 108, display = 843, catch = 90, exp = 165,
        base = { 90, 100, 80, 45, 60, 70 },
        desc = "A gorilla of the Mistvale Valley. It throws fruit at travellers, and then whatever else is to hand.",
        evolve = { level = 46, into = "eldergorilla" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 34, "chestbeat" }, { 38, "maul" }, { 42, "groundpound" } } },
    eldergorilla = { name = "Elder Mistvale Gorilla", type = "BEAST", num = 109, display = 838, catch = 45, exp = 220,
        base = { 110, 120, 96, 50, 72, 78 },
        desc = "Grey at the temples and twice your weight. The younger gorillas get out of its way, and so should you.",
        evolve = { level = 60, into = "silverback" },
        learn = { { 1, "tackle" }, { 1, "growl" }, { 34, "chestbeat" }, { 38, "maul" }, { 42, "groundpound" },
                  { 46, "cleave" }, { 54, "feralrage" } } },
    silverback = { name = "Silverback Patriarch", type = "BEAST", num = 110, display = 844, cam = 0.9, catch = 20, exp = 280,
        base = { 130, 140, 112, 60, 85, 85 },
        desc = "The patriarch of the Mistvale troop. King Mukla is the only ape in the vale that outweighs it.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 34, "chestbeat" }, { 38, "maul" }, { 42, "groundpound" },
                  { 46, "cleave" }, { 54, "feralrage" }, { 60, "earthquake" }, { 74, "roar" } } },
    crystalspine = { name = "Crystal Spine Basilisk", type = "EARTH", num = 111, display = 601, catch = 90, exp = 160,
        base = { 88, 86, 110, 55, 70, 45 },
        desc = "A basilisk of the northern vale. Its spines are real crystal; Venture Co. pays by the pound.",
        evolve = { level = 44, into = "coldeye" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 32, "rockthrow" }, { 35, "crystalspines" }, { 40, "petrify" } } },
    coldeye = { name = "Cold Eye Basilisk", type = "EARTH", num = 112, display = 8797, catch = 45, exp = 215,
        base = { 104, 100, 130, 70, 85, 50 },
        desc = "Meet its gaze and you'll be a statue in Mistvale until the Silverback knocks you over.",
        evolve = { level = 58, into = "ironjaw" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 32, "rockthrow" }, { 35, "crystalspines" }, { 40, "petrify" },
                  { 44, "stoneskin" }, { 52, "bouldertoss" } } },
    ironjaw = { name = "Ironjaw Basilisk", type = "EARTH", num = 113, display = 2174, catch = 20, exp = 270,
        base = { 120, 118, 150, 80, 100, 55 },
        desc = "Its bite went through a Bloodsail cannon once. The cannon is still at the bottom of the Wild Shore.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 32, "rockthrow" }, { 35, "crystalspines" }, { 40, "petrify" },
                  { 44, "stoneskin" }, { 52, "bouldertoss" }, { 58, "earthquake" }, { 72, "crushingbite" } } },
    rivercroc = { name = "River Crocolisk", type = "WATER", num = 114, display = 1039, catch = 100, exp = 150,
        base = { 85, 92, 95, 40, 55, 50 },
        desc = "A crocolisk of Lake Nazferiti. It lies like a log until a Bloodscalp fisherman steps on it.",
        evolve = { level = 38, into = "saltwatercroc" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 30, "bite" }, { 33, "waterjet" }, { 36, "deathroll" } } },
    saltwatercroc = { name = "Saltwater Crocolisk", type = "WATER", num = 115, display = 2548, catch = 50, exp = 205,
        base = { 100, 112, 110, 50, 65, 55 },
        desc = "A crocolisk that moved down to the coast for the fishing. Booty Bay's docks lost a goblin to one.",
        evolve = { level = 52, into = "eldercroc" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 30, "bite" }, { 33, "waterjet" }, { 36, "deathroll" },
                  { 42, "riptide" }, { 48, "crushingbite" } } },
    eldercroc = { name = "Elder Saltwater Crocolisk", type = "WATER", num = 116, display = 815, cam = 0.9, catch = 25, exp = 265,
        base = { 120, 130, 125, 60, 80, 60 },
        desc = "Old enough to have a name in Booty Bay: 'that one'. Nobody swims off the south pier any more.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 30, "bite" }, { 33, "waterjet" }, { 36, "deathroll" },
                  { 42, "riptide" }, { 48, "crushingbite" }, { 52, "tsunami" }, { 66, "stoneskin" } } },
    trollscout = { name = "Bloodscalp Scout", type = "SHADOW", num = 117, display = 4575, catch = 80, exp = 160,
        base = { 80, 95, 70, 60, 65, 95 },
        desc = "A Bloodscalp troll from Zul'Kunda. It scouts for the tribe and, once tamed, for you. Ya mon.",
        evolve = { level = 42, into = "berserker" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "throwaxe" }, { 34, "bite" }, { 38, "hex" } } },
    berserker = { name = "Bloodscalp Berserker", type = "SHADOW", num = 118, display = 4579, catch = 40, exp = 215,
        base = { 100, 120, 82, 65, 72, 105 },
        desc = "A troll that has stopped scouting and started charging. The loa of blood is loud in its ears.",
        evolve = { level = 56, into = "skullsplitter" },
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "throwaxe" }, { 34, "bite" }, { 38, "hex" },
                  { 42, "berserk" }, { 50, "cleave" } } },
    skullsplitter = { name = "Skullsplitter Berserker", type = "SHADOW", num = 119, display = 4623, catch = 20, exp = 270,
        base = { 118, 140, 95, 75, 85, 115 },
        desc = "The Skullsplitters took the ruins of Zul'Mamwe from the Bloodscalps, and they keep the skulls to prove it.",
        learn = { { 1, "scratch" }, { 1, "leer" }, { 30, "throwaxe" }, { 34, "bite" }, { 38, "hex" },
                  { 42, "berserk" }, { 50, "cleave" }, { 56, "headhunt" }, { 70, "nightmare" } } },
    snapjaw = { name = "Saltwater Snapjaw", type = "WATER", num = 120, display = 5027, catch = 60, exp = 200,
        base = { 120, 80, 140, 60, 110, 30 },
        desc = "A great sea turtle of the Wild Shore. It has bitten through a Bloodsail longboat, slowly.",
        learn = { { 1, "tackle" }, { 1, "shell" }, { 38, "waterjet" }, { 42, "shellspin" }, { 48, "stoneskin" },
                  { 56, "tsunami" } } },
    zombie = { name = "Zanzil Zombie", type = "SHADOW", num = 121, display = 1065, catch = 90, exp = 170,
        base = { 105, 98, 70, 40, 55, 35 },
        desc = "One of Zanzil's mixtures walking around in a dead troll. It does what the last thing it heard told it.",
        learn = { { 1, "scratch" }, { 1, "plague" }, { 38, "bite" }, { 44, "drainlife" }, { 52, "deathcoil" } } },

    -- Stranglethorn's rares (night, like Mother Fang) and its bosses (never tamed)
    bhagthera = { name = "Bhag'thera", type = "SHADOW", num = 122, display = 613, catch = 20, exp = 230, rare = true,
        base = { 98, 120, 80, 70, 75, 140 },
        desc = "The panther Sir Erlgadin has hunted for eleven years. It hunts him back, some nights.",
        learn = { { 1, "shadowclaw" }, { 1, "pounce" }, { 1, "bite" }, { 44, "nightmare" } } },
    tethis = { name = "Tethis", type = "BEAST", num = 123, display = 8472, catch = 20, exp = 235, rare = true,
        base = { 102, 126, 84, 55, 70, 135 },
        desc = "The raptor Ajeck Rouack calls 'the one that got away'. It got away with her boot.",
        learn = { { 1, "ravage" }, { 1, "talon" }, { 1, "rend" }, { 46, "feralrage" } } },
    bangalash = { name = "King Bangalash", type = "BEAST", num = 124, display = 616, cam = 0.85, catch = 3, exp = 300, boss = true,
        base = { 135, 140, 100, 60, 85, 130 },
        desc = "The great white tiger of the vale. Hemet Nesingwary has a wall waiting for its head.",
        learn = { { 1, "feralrage" }, { 1, "pounce" }, { 1, "roar" }, { 1, "ravage" } } },
    kurzen = { name = "Colonel Kurzen", type = "SHADOW", num = 125, display = 637, catch = 3, exp = 290, boss = true,
        base = { 130, 125, 105, 90, 95, 100 },
        desc = "Stormwind sent him to map the vale. The vale, and the trolls' medicine, sent something else back.",
        learn = { { 1, "cutlass" }, { 1, "cleave" }, { 1, "hex" }, { 1, "throwaxe" } } },
    ganzulah = { name = "Gan'zulah", type = "SHADOW", num = 126, display = 4582, catch = 3, exp = 295, boss = true,
        base = { 135, 135, 105, 85, 95, 110 },
        desc = "Chief of the Skullsplitters. His skull collection is arranged by size. He wants yours for the middle.",
        learn = { { 1, "headhunt" }, { 1, "berserk" }, { 1, "hex" }, { 1, "cleave" } } },
    maizoth = { name = "Mai'Zoth", type = "EARTH", num = 127, display = 11546, cam = 0.85, catch = 3, exp = 310, boss = true,
        base = { 150, 140, 115, 110, 100, 60 },
        desc = "The two-headed lord of the Mosh'Ogg. One head hits you; the other sets you on fire.",
        learn = { { 1, "earthquake" }, { 1, "fireball" }, { 1, "ogreslam" }, { 1, "stoneskin" } } },
    zanzil = { name = "Zanzil the Outcast", type = "SHADOW", num = 128, display = 314, catch = 3, exp = 300, boss = true,
        base = { 125, 110, 100, 130, 110, 95 },
        desc = "A witch doctor cast out even by the Bloodscalps. His mixtures raise the dead. Badly.",
        learn = { { 1, "deathcoil" }, { 1, "hex" }, { 1, "plague" }, { 1, "shadowbolt" } } },
    mukla = { name = "King Mukla", type = "BEAST", num = 129, display = 792, cam = 0.85, catch = 3, exp = 320, boss = true,
        base = { 160, 150, 120, 60, 90, 80 },
        desc = "The lord of Jaguero Isle. Goblins visit to steal bananas. Very few goblins visit twice.",
        learn = { { 1, "earthquake" }, { 1, "chestbeat" }, { 1, "feralrage" }, { 1, "cleave" } } },
    firallon = { name = "Fleet Master Firallon", type = "WATER", num = 130, display = 797, catch = 3, exp = 330, boss = true,
        base = { 145, 140, 115, 110, 105, 115 },
        desc = "Master of the Bloodsail fleet. He means to take Booty Bay, and he has three ships that agree.",
        learn = { { 1, "cutlass" }, { 1, "cannon" }, { 1, "tsunami" }, { 1, "cleave" } } },
    ---------------------------------------------------------------------------
    -- Blackrock (Redridge, the Burning Steppes, the Searing Gorge, Blackrock Mountain, the Molten Core). Displays
    -- from the Blackrock deep-dive mockup (zone_mockup/blackrock/region.py, npc -> displayId on Wowhead TBC):
    -- Black Dragon Whelp 387, Black Broodling 397, Black Wyrmkin 8249, Rage Talon Dragonspawn 2554, Redridge Mongrel
    -- 487, Redridge Brute 500, Redridge Alpha 609, Redridge Mystic 10789, Dire Condor 490, Chatter 821, Flamekin
    -- Spitter 10815 / Rager 10814 / Torcher 10817, Firegut Ogre 11549 / Brute 10707 / Ogre Mage 11550, Scalding
    -- Drake 9585, Firetail Scorpid 10985, Burning Imp 4449, Volchan 12232, Glassweb Spider 4456, Searing Lava Spider
    -- 4457, Greater Lava Spider 7510, Blazing Elemental 1070, Inferno Elemental 5488, Magma Elemental 2075, Greater
    -- Obsidian Elemental 5781, Tempered / Heavy / Faulty War Golem 5747 / 10801 / 10800, Thaurissan Firewalker 8170,
    -- Fireguard 2172, Flame Imp 12190, Lava Surger 12239, Core Hound 12168, Magmadar 10193.
    -- Wild beasts here are met at Lv 48-58, so their lists start at 1 and pick up in the 40s like Stranglethorn's.
    ---------------------------------------------------------------------------
    blackwhelp = { name = "Black Dragon Whelp", type = "FIRE", num = 131, display = 387, cam = 1.2, catch = 90, exp = 170,
        base = { 80, 75, 75, 100, 80, 110 },
        desc = "Onyxia's brood hatches in Redridge's hills. Lakeshire counts its sheep every morning, and comes up short.",
        evolve = { level = 50, into = "broodling" },
        learn = { { 1, "scratch" }, { 1, "ember" }, { 44, "flamebreath" }, { 46, "wingbuffet" }, { 48, "flamebuffet" } } },
    broodling = { name = "Black Broodling", type = "FIRE", num = 132, display = 397, catch = 45, exp = 215,
        base = { 92, 85, 88, 115, 92, 108 },
        desc = "A whelp grown into the black flight's foot soldier. It answers to a voice in Blackrock Spire.",
        evolve = { level = 58, into = "blackwyrmkin" },
        learn = { { 1, "scratch" }, { 1, "ember" }, { 44, "flamebreath" }, { 46, "wingbuffet" }, { 48, "flamebuffet" },
                  { 50, "conflagrate" }, { 54, "shadowflame" } } },
    blackwyrmkin = { name = "Black Wyrmkin", type = "FIRE", num = 133, display = 8249, catch = 25, exp = 260,
        base = { 105, 95, 100, 130, 105, 105 },
        desc = "Wyrmkin guard the Spire's upper halls. Nefarius breeds them for loyalty; fire came free.",
        evolve = { level = 72, into = "ragetalon" },
        learn = { { 1, "scratch" }, { 1, "ember" }, { 44, "flamebreath" }, { 46, "wingbuffet" }, { 48, "flamebuffet" },
                  { 50, "conflagrate" }, { 54, "shadowflame" }, { 58, "dragonbreath" }, { 64, "lavaburst" } } },
    ragetalon = { name = "Rage Talon Dragonspawn", type = "FIRE", num = 134, display = 2554, cam = 0.9, catch = 15, exp = 310,
        base = { 118, 102, 105, 140, 112, 103 },
        desc = "Half dragon, half rage, all scales. The Rage Talon held Blackrock Spire for the black flight.",
        learn = { { 1, "scratch" }, { 1, "ember" }, { 44, "flamebreath" }, { 46, "wingbuffet" }, { 48, "flamebuffet" },
                  { 50, "conflagrate" }, { 54, "shadowflame" }, { 58, "dragonbreath" }, { 64, "lavaburst" },
                  { 72, "bellowingroar" }, { 78, "inferno" }, { 86, "firestorm" } } },
    mongrel = { name = "Redridge Mongrel", type = "BEAST", num = 135, display = 487, catch = 120, exp = 165,
        base = { 88, 105, 75, 45, 65, 100 },
        desc = "A Redridge gnoll pup. They travel in threes, and the other two are behind the bush.",
        evolve = { level = 52, into = "rrbrute" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 44, "bite" }, { 46, "ragged" }, { 48, "rend" }, { 50, "maul" } } },
    rrbrute = { name = "Redridge Brute", type = "BEAST", num = 136, display = 500, catch = 60, exp = 210,
        base = { 105, 122, 90, 50, 72, 96 },
        desc = "A grown Redridge gnoll. It knocks the planks out of Lakeshire's bridge for fun.",
        evolve = { level = 62, into = "rralpha" },
        learn = { { 1, "scratch" }, { 1, "growl" }, { 44, "bite" }, { 46, "ragged" }, { 48, "rend" }, { 50, "maul" },
                  { 52, "cleave" }, { 56, "warstomp" } } },
    rralpha = { name = "Redridge Alpha", type = "BEAST", num = 137, display = 609, catch = 30, exp = 265,
        base = { 120, 140, 102, 55, 85, 108 },
        desc = "The pack's alpha. Gath'Ilzogg keeps one on a chain, and the chain is the only thing it respects.",
        learn = { { 1, "scratch" }, { 1, "growl" }, { 44, "bite" }, { 46, "ragged" }, { 48, "rend" }, { 50, "maul" },
                  { 52, "cleave" }, { 56, "warstomp" }, { 62, "feralrage" }, { 70, "roar" }, { 80, "crushingbite" } } },
    rrmystic = { name = "Redridge Mystic", type = "SHADOW", num = 138, display = 10789, catch = 60, exp = 205,
        base = { 95, 108, 80, 100, 90, 92 },
        desc = "A gnoll shaman who talks to things in the dark. The things answer, mostly with curses.",
        learn = { { 1, "curse" }, { 1, "shadowbolt" }, { 48, "hex" }, { 50, "drainlife" }, { 54, "shadowflame" },
                  { 60, "deathcoil" }, { 70, "nightmare" }, { 80, "terrify" } } },
    condor = { name = "Dire Condor", type = "AIR", num = 139, display = 490, cam = 1.1, catch = 75, exp = 195,
        base = { 95, 112, 78, 60, 72, 118 },
        desc = "It rides the updraft off Lake Everstill and drops on whatever the gnolls leave behind.",
        learn = { { 1, "peck" }, { 1, "squawk" }, { 46, "whirlwind" }, { 48, "talon" }, { 52, "tailwind" },
                  { 58, "skydive" }, { 66, "cyclone" }, { 78, "tempest" } } },
    chatter = { name = "Chatter", type = "SHADOW", num = 140, display = 821, catch = 15, exp = 250, rare = true,
        base = { 110, 130, 92, 70, 85, 125 },
        desc = "The spider the Redridge poachers whisper about. Its fangs click in the dark like a gnoll counting coins.",
        learn = { { 1, "venomfang" }, { 1, "shadowclaw" }, { 1, "web" }, { 1, "hex" }, { 58, "nightmare" } } },
    spitter = { name = "Flamekin Spitter", type = "FIRE", num = 141, display = 10815, cam = 1.2, catch = 90, exp = 175,
        base = { 85, 70, 75, 105, 80, 90 },
        desc = "A little living flame of the Steppes. It spits burning tar at anything that walks too close.",
        evolve = { level = 56, into = "rager" },
        learn = { { 1, "ember" }, { 1, "mudslap" }, { 46, "molten" }, { 50, "fireball" }, { 53, "slagtoss" } } },
    rager = { name = "Flamekin Rager", type = "FIRE", num = 142, display = 10814, catch = 45, exp = 225,
        base = { 100, 82, 88, 125, 95, 98 },
        desc = "A Spitter that found the mountain's heart and grew angry with it. The ash around it never settles.",
        evolve = { level = 66, into = "torcher" },
        learn = { { 1, "ember" }, { 1, "mudslap" }, { 46, "molten" }, { 50, "fireball" }, { 53, "slagtoss" },
                  { 56, "firenova" }, { 60, "lavaburst" } } },
    torcher = { name = "Flamekin Torcher", type = "FIRE", num = 143, display = 10817, catch = 20, exp = 285,
        base = { 115, 92, 100, 145, 108, 105 },
        desc = "Thaurissan's fire-priests feed it coal by the cartload. It burns brighter than the Imperial Seat's braziers.",
        learn = { { 1, "ember" }, { 1, "mudslap" }, { 46, "molten" }, { 50, "fireball" }, { 53, "slagtoss" },
                  { 56, "firenova" }, { 60, "lavaburst" }, { 66, "conflagrate" }, { 72, "inferno" }, { 84, "firestorm" } } },
    firegut = { name = "Firegut Ogre", type = "EARTH", num = 144, display = 11549, cam = 0.9, catch = 90, exp = 180,
        base = { 110, 118, 90, 55, 70, 55 },
        desc = "A lookout from Dreadmaul Rock. It looks out for food, mostly.",
        evolve = { level = 56, into = "fgbrute" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 46, "ogreslam" }, { 50, "rockthrow" }, { 53, "groundpound" } } },
    fgbrute = { name = "Firegut Brute", type = "EARTH", num = 145, display = 10707, cam = 0.9, catch = 40, exp = 230,
        base = { 128, 138, 105, 60, 80, 62 },
        desc = "Bigger, louder and closer than a Firegut Ogre. The Blackrock orcs pay it in meat to stand at the gate.",
        evolve = { level = 64, into = "fgmage" },
        learn = { { 1, "tackle" }, { 1, "leer" }, { 46, "ogreslam" }, { 50, "rockthrow" }, { 53, "groundpound" },
                  { 56, "warstomp" }, { 60, "chestbeat" } } },
    fgmage = { name = "Firegut Ogre Mage", type = "EARTH", num = 146, display = 11550, cam = 0.85, catch = 15, exp = 290,
        base = { 135, 135, 110, 115, 100, 65 },
        desc = "Two heads, two spells a turn. One head reads the spellbook; the other eats it.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 46, "ogreslam" }, { 50, "rockthrow" }, { 53, "groundpound" },
                  { 56, "warstomp" }, { 60, "chestbeat" }, { 64, "fireball" }, { 70, "earthquake" }, { 78, "stoneskin" },
                  { 86, "inferno" } } },
    scaldingdrake = { name = "Scalding Drake", type = "FIRE", num = 147, display = 9585, catch = 60, exp = 205,
        base = { 85, 80, 70, 120, 75, 135 },
        desc = "A young drake of the Steppes, fast and frail. Its Flame Buffet has melted Morgan's Vigil's gate twice.",
        learn = { { 1, "ember" }, { 1, "wingbuffet" }, { 48, "flamebreath" }, { 52, "flamebuffet" },
                  { 56, "dragonbreath" }, { 62, "tailwind" }, { 70, "inferno" }, { 82, "firestorm" } } },
    firetail = { name = "Firetail Scorpid", type = "EARTH", num = 148, display = 10985, catch = 75, exp = 195,
        base = { 95, 108, 135, 45, 80, 72 },
        desc = "A scorpid baked hard in the Steppes' ash. Its sting is hot enough to light a pipe.",
        learn = { { 1, "tackle" }, { 1, "leer" }, { 46, "venomsting" }, { 50, "crystalspines" }, { 54, "stoneskin" },
                  { 58, "venomfang" }, { 66, "crushingbite" }, { 76, "earthquake" } } },
    burningimp = { name = "Burning Imp", type = "FIRE", num = 149, display = 4449, cam = 1.3, catch = 120, exp = 165,
        base = { 70, 60, 62, 105, 78, 120 },
        desc = "Small, rude, and on fire. It sets things alight and then complains about the smoke.",
        learn = { { 1, "ember" }, { 1, "growl" }, { 46, "fireball" }, { 50, "firenova" }, { 54, "sprint" },
                  { 60, "shadowflame" }, { 70, "inferno" } } },
    volchan = { name = "Volchan", type = "EARTH", num = 150, display = 12232, cam = 0.85, catch = 15, exp = 260, rare = true,
        base = { 140, 135, 140, 70, 95, 40 },
        desc = "A walking hill of slag that wanders the Steppes by night. Where it sleeps, the ground glows for a week.",
        learn = { { 1, "slagtoss" }, { 1, "warstomp" }, { 1, "earthquake" }, { 1, "stoneskin" }, { 62, "magmashackles" } } },
    glassweb = { name = "Glassweb Spider", type = "SHADOW", num = 151, display = 4456, catch = 60, exp = 205,
        base = { 90, 108, 95, 70, 80, 105 },
        desc = "A spider with a shell like smoked glass. Duskwood's Venom Webs that wander into the Gorge come back as these.",
        evolve = { level = 56, into = "lavaspider" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 22, "corrosive" }, { 25, "leech" }, { 30, "bite" },
                  { 46, "shadowclaw" }, { 50, "burningweb" }, { 53, "venomfang" } } },
    lavaspider = { name = "Searing Lava Spider", type = "FIRE", num = 152, display = 4457, catch = 35, exp = 245,
        base = { 100, 95, 100, 115, 92, 110 },
        desc = "It bathed in the Cauldron and came out burning. The Thorium Brotherhood sweeps its webs off the slag heaps.",
        evolve = { level = 66, into = "greaterlava" },
        learn = { { 1, "venomsting" }, { 1, "web" }, { 22, "corrosive" }, { 25, "leech" }, { 30, "bite" },
                  { 46, "shadowclaw" }, { 50, "burningweb" }, { 53, "venomfang" }, { 56, "molten" }, { 60, "lavaburst" } } },
    greaterlava = { name = "Greater Lava Spider", type = "FIRE", num = 153, display = 7510, cam = 0.9, catch = 15, exp = 295,
        base = { 112, 102, 108, 135, 100, 113 },
        desc = "The mother of the Gorge's lava spiders. Its web hangs over the Cauldron, and nothing caught in it cools.",
        learn = { { 1, "venomsting" }, { 1, "web" }, { 22, "corrosive" }, { 25, "leech" }, { 30, "bite" },
                  { 46, "shadowclaw" }, { 50, "burningweb" }, { 53, "venomfang" }, { 56, "molten" }, { 60, "lavaburst" },
                  { 66, "magmashackles" }, { 72, "inferno" }, { 84, "firestorm" } } },
    blazing = { name = "Blazing Elemental", type = "FIRE", num = 154, display = 1070, cam = 1.1, catch = 60, exp = 200,
        base = { 85, 70, 80, 115, 85, 100 },
        desc = "A spark of Ragnaros's realm that slipped out through the Gorge's vents. It wants to go home, through you.",
        evolve = { level = 60, into = "inferno" },
        learn = { { 1, "ember" }, { 1, "fireball" }, { 46, "flamebreath" }, { 50, "firenova" }, { 54, "moltenarmor" } } },
    inferno = { name = "Inferno Elemental", type = "FIRE", num = 155, display = 5488, catch = 20, exp = 280,
        base = { 110, 85, 98, 145, 105, 112 },
        desc = "A Blazing Elemental that drank the Cauldron dry. Its Fire Nova once took the roof off Thorium Point.",
        learn = { { 1, "ember" }, { 1, "fireball" }, { 46, "flamebreath" }, { 50, "firenova" }, { 54, "moltenarmor" },
                  { 60, "lavaburst" }, { 66, "conflagrate" }, { 74, "inferno" }, { 84, "firestorm" } } },
    magma = { name = "Magma Elemental", type = "EARTH", num = 156, display = 2075, catch = 60, exp = 205,
        base = { 110, 110, 140, 60, 85, 35 },
        desc = "Slow, huge and half molten. The Dark Irons dig around it and hope it doesn't notice.",
        evolve = { level = 62, into = "obsidian" },
        learn = { { 1, "tackle" }, { 1, "stoneskin" }, { 48, "rockthrow" }, { 52, "slagtoss" }, { 56, "molten" } } },
    obsidian = { name = "Greater Obsidian Elemental", type = "EARTH", num = 157, display = 5781, cam = 0.85, catch = 20, exp = 285,
        base = { 135, 130, 170, 70, 105, 40 },
        desc = "Cooled lava with a temper. Thaurissan's sorcerers bind them to the mountain's deepest doors.",
        learn = { { 1, "tackle" }, { 1, "stoneskin" }, { 48, "rockthrow" }, { 52, "slagtoss" }, { 56, "molten" },
                  { 62, "magmashackles" }, { 66, "bouldertoss" }, { 72, "earthquake" }, { 82, "crushingbite" } } },
    temperedgolem = { name = "Tempered War Golem", type = "MECH", num = 158, display = 5747, catch = 60, exp = 200,
        base = { 100, 110, 120, 45, 70, 60 },
        desc = "Dark Iron work, hammered at the Black Forge. It digs by day and guards the dig by night.",
        evolve = { level = 58, into = "heavygolem" },
        learn = { { 1, "gears" }, { 1, "rust" }, { 48, "scythe" }, { 50, "buzzsaw" }, { 54, "steamjet" } } },
    -- a Tempered War Golem at Lv 58, or a Harvest Watcher given a Dark Iron Bar: the list carries both lines' moves
    heavygolem = { name = "Heavy War Golem", type = "MECH", num = 159, display = 10801, cam = 0.9, catch = 25, exp = 270,
        base = { 125, 138, 148, 50, 92, 67 },
        desc = "Dark Iron plate on a war frame. The Anvilrage set them on Shadowforge City's doors; they never got tired.",
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" }, { 22, "maul" }, { 36, "buzzsaw" },
                  { 48, "overdrive" }, { 54, "steamjet" }, { 60, "rocketpunch" }, { 66, "warstomp" }, { 74, "cannon" },
                  { 84, "sawstorm" } } },
    faultygolem = { name = "Faulty War Golem", type = "MECH", num = 160, display = 10800, catch = 15, exp = 255, rare = true,
        base = { 110, 140, 120, 45, 80, 95 },
        desc = "Sparks, stalls, and punches anyway. The Dark Irons threw it on the slag heap; it climbed back down.",
        learn = { { 1, "thrash" }, { 1, "rocketpunch" }, { 1, "steamjet" }, { 1, "overdrive" }, { 62, "sawstorm" } } },
    firewalker = { name = "Thaurissan Firewalker", type = "FIRE", num = 161, display = 8170, catch = 45, exp = 240,
        base = { 100, 90, 92, 125, 95, 98 },
        desc = "Living flame in a Dark Iron's service. It walks the mountain's halls and the halls stay warm behind it.",
        learn = { { 1, "ember" }, { 1, "flamebreath" }, { 50, "fireball" }, { 54, "moltenarmor" }, { 56, "firenova" },
                  { 62, "lavaburst" }, { 72, "inferno" }, { 84, "firestorm" } } },
    fireguard = { name = "Fireguard", type = "FIRE", num = 162, display = 2172, catch = 25, exp = 270,
        base = { 115, 100, 110, 130, 105, 90 },
        desc = "A suit of armour with fire where the knight should be. It guards the Imperial Seat and never sleeps.",
        learn = { { 1, "flamebreath" }, { 1, "molten" }, { 54, "fireball" }, { 58, "moltenarmor" }, { 60, "lavaburst" },
                  { 66, "conflagrate" }, { 76, "inferno" }, { 86, "firestorm" } } },
    flameimp = { name = "Flame Imp", type = "FIRE", num = 163, display = 12190, cam = 1.3, catch = 60, exp = 220,
        base = { 85, 70, 72, 125, 90, 128 },
        desc = "Ragnaros's own imps, born in the Molten Core. They cackle in a language that sounds like kindling.",
        learn = { { 1, "ember" }, { 1, "fireball" }, { 58, "firenova" }, { 60, "shadowflame" }, { 64, "sprint" },
                  { 70, "inferno" }, { 80, "conflagrate" } } },
    lavasurger = { name = "Lava Surger", type = "FIRE", num = 164, display = 12239, catch = 15, exp = 275, rare = true,
        base = { 120, 105, 100, 135, 100, 80 },
        desc = "A wave of the Molten Core's lava that got up and walked. Raiders who drop Al'ar sometimes see one in the Gorge.",
        learn = { { 1, "lavaburst" }, { 1, "firenova" }, { 1, "slagtoss" }, { 1, "moltenarmor" }, { 66, "firestorm" } } },
    corehound = { name = "Core Hound", type = "FIRE", num = 165, display = 12168, cam = 0.9, catch = 30, exp = 270,
        base = { 118, 125, 98, 110, 88, 96 },
        desc = "Magmadar's pack. A Black Ravager Mastiff that finds the mountain's heat turns into one, and never comes back cold.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 22, "bite" }, { 25, "rend" }, { 28, "howl" }, { 30, "ravage" },
                  { 34, "maul" }, { 46, "molten" }, { 52, "feralrage" }, { 58, "flamebreath" }, { 62, "lavaburst" },
                  { 70, "crushingbite" }, { 80, "inferno" } } },
    -- met once per save in the Molten Core (G:LegendaryBattle); never in the grass, never in the arena
    magmadar = { name = "Magmadar", type = "FIRE", num = 166, display = 10193, cam = 0.8, catch = 3, exp = 340,
        legendary = true,
        base = { 150, 135, 125, 145, 115, 90 },
        desc = "The Core Hounds' sire, Ragnaros's hound. Its howl sends grown raiders running; its lava burns the stone.",
        learn = { { 1, "panic" }, { 1, "lavaburst" }, { 1, "conflagrate" }, { 1, "crushingbite" }, { 70, "firestorm" },
                  { 80, "inferno" } } },
}

-- Dex order.
D.dexOrder = {}
for id, s in pairs(D.species) do
    s.id = id
    D.dexOrder[#D.dexOrder + 1] = id
end
table.sort(D.dexOrder, function(a, b) return D.species[a].num < D.species[b].num end)

D.starters = { "emberwhelp", "murkling", "lashling" }
-- The rival takes the starter that beats yours.
D.rivalStarter = { emberwhelp = "murkling", murkling = "lashling", lashling = "emberwhelp" }

---------------------------------------------------------------------------
-- Shinies: about 1 in SHINY_ODDS wild beasts wears another skin of its own model. These are the client's real
-- recolours (creature display IDs from the Anniversary 2.5.6 CreatureDisplayInfo: same model, other textures,
-- never a skin another species here already wears). A species with no other skin shimmers gold instead.
---------------------------------------------------------------------------

D.SHINY_ODDS = 400
D.shinyDisplay = {
    emberwhelp = 6292, flamescale = 6370,         -- the bronze dragonflight
    murkling = 1755, tidehunter = 1761,           -- orange murlocs
    coastrunner = 3615,                           -- white murloc
    lashling = 13172, flaytrap = 16915,           -- turquoise lashers
    wolfpup = 644, packleader = 780,              -- black wolves
    coyote = 4124,                                -- a plagued coyote
    ghostpaw = 1950,                              -- a spectral wolf
    bigbadwolf = 523,                             -- white worgen
    -- (the webling's magma tarantula 4457 and the mine spider's crystal spider 4456 are Blackrock's Searing Lava
    -- Spider and Glassweb Spider now, so those two shimmer gold instead)
    motherfang = 963,                             -- blood-red spider
    -- (the kobolds' only other skin is the Geomancer's own albino one, so a shiny kobold glows instead)
    owlet = 16428,                                -- a spirit owl
    tuskling = 381, goretusk = 8869,              -- blue and yellow boars
    runt = 355, scout = 269, brute = 493,         -- Mosshide, Redridge and Shadowhide gnolls
    fleshripper = 23709,                          -- white carrion bird
    rustgolem = 548, reaper = 17076,              -- blue harvest golems
    dustdevil = 5234,                             -- white air elemental
    crawler = 18117, sandcrawler = 18116,         -- truesilver and dark-diamond crabs
    gronnling = 19667,                            -- a yellow gronn
    lurkling = 22355,                             -- a black kraken
    parrot = 6192,                                -- blue parrot
    darkrunner = 11181, vilefang = 11179,         -- the coats of Nefaru and Fenros, Duskwood's rare worgen
}
D.SHINY_GLOW = { 1.0, 0.82, 0.38 }                -- the light on a shiny that has no skin of its own

---------------------------------------------------------------------------
-- The bounty board (Bounties.lua). Daily templates: on = the event that counts, test(e, arg), n = { lo, hi } goal,
-- args = what "arg" is drawn from (the same for the whole guild that day), pay = copper per unit of goal.
-- Types in args are the ones Elwynn Forest has, so a new player can do every bounty.
---------------------------------------------------------------------------

local function Beasts(n) return n == 1 and "beast" or "beasts" end
local function TypeName(t) return D.types[t] and D.types[t].name or tostring(t) end
local function FoeType(e) local sp = e.foes and D.species[e.foes[1]] return sp and sp.type end
local ELWYNN_TYPES = { "BEAST", "AIR", "EARTH", "SHADOW" }

D.BOUNTIES_PER_DAY = 3
D.bounties = {
    { id = "tame", on = "tame", n = { 2, 3 }, pay = 150,
      text = function(n) return string.format("Tame %d %s", n, Beasts(n)) end,
      test = function(e) return e.how == "caught" end },
    { id = "tametype", on = "tame", n = { 1, 2 }, pay = 250, args = ELWYNN_TYPES,
      text = function(n, t) return string.format("Tame %d %s %s", n, TypeName(t), Beasts(n)) end,
      test = function(e, t) return e.how == "caught" and D.species[e.mon.sp].type == t end },
    { id = "wild", on = "battle", n = { 5, 8 }, pay = 60,
      text = function(n) return string.format("Defeat %d wild %s", n, Beasts(n)) end,
      test = function(e) return e.wild and e.result == "win" end },
    { id = "wildtype", on = "battle", n = { 2, 4 }, pay = 110, args = ELWYNN_TYPES,
      text = function(n, t) return string.format("Defeat %d wild %s %s", n, TypeName(t), Beasts(n)) end,
      test = function(e, t) return e.wild and e.result == "win" and FoeType(e) == t end },
    { id = "steps", on = "step", n = { 400, 700 }, pay = 0.7,
      text = function(n) return string.format("Walk %d steps", n) end,
      test = function() return true end },
    { id = "trainer", on = "battle", n = { 1, 2 }, pay = 260,
      text = function(n) return n == 1 and "Win a trainer battle" or string.format("Win %d trainer battles", n) end,
      test = function(e) return e.trainer ~= nil and e.result == "win" end },
    { id = "level", on = "level", n = { 3, 5 }, pay = 110,
      text = function(n) return string.format("Level up your beasts %d times", n) end,
      test = function() return true end },
}
D.bountyItems = { { "potion", 2 }, { "net", 2 }, { "antidote", 2 }, { "superpotion", 1 }, { "greatnet", 1 } }

-- The weekly guild goal: one per week, in turn. Every tier the guild reaches pays everyone who helped.
D.guildGoals = {
    { id = "tame", name = "Tame beasts", on = "tame", tiers = { 25, 60, 120 },
      test = function(e) return e.how == "caught" end },
    { id = "wild", name = "Defeat wild beasts", on = "battle", tiers = { 60, 150, 300 },
      test = function(e) return e.wild and e.result == "win" end },
    { id = "steps", name = "Walk the roads of Azeroth", on = "step", tiers = { 8000, 20000, 40000 },
      test = function() return true end },
    { id = "level", name = "Train beasts", on = "level", tiers = { 30, 75, 150 },
      test = function() return true end },
}
D.guildTierNames = { "Bronze", "Silver", "Gold" }
D.guildTierRewards = {
    { money = 500, items = { superpotion = 2 } },
    { money = 1500, items = { greatnet = 3 } },
    { money = 3000, items = { illusiondust = 1 } },
}

---------------------------------------------------------------------------
-- Items
---------------------------------------------------------------------------

D.items = {
    potion = { name = "Minor Healing Potion", price = 300, heal = 20, use = "heal",
               icon = "Interface\\Icons\\INV_Potion_51", desc = "Restores 20 HP to one beast." },
    superpotion = { name = "Lesser Healing Potion", price = 700, heal = 50, use = "heal",
               icon = "Interface\\Icons\\INV_Potion_52", desc = "Restores 50 HP to one beast." },
    antidote = { name = "Anti-Venom", price = 100, cures = "psn", use = "cure",
               icon = "Interface\\Icons\\INV_Potion_12", desc = "A First Aid remedy. Cures poison." },
    net = { name = "Taming Rod", price = 200, ball = 1, use = "ball",
               icon = "Interface\\Icons\\Ability_Hunter_BeastTaming", desc = "The hunter's tool of the trade. Use it on a weakened wild beast to tame it." },
    greatnet = { name = "Net-o-Matic", price = 600, ball = 1.5, use = "ball",
               icon = "Interface\\Icons\\Spell_Nature_StrangleVines", desc = "Gnomish engineering! Better odds than a Taming Rod. Usually." },
}
D.items.illusiondust = { name = "Illusion Dust", price = 0, sell = 250, use = "charm", minutes = 30,
    icon = "Interface\\Icons\\INV_Enchant_DustIllusion",
    desc = "Scatter it and the air glimmers: for 30 minutes, shiny beasts are twice as likely.",
    used = "You scatter the Illusion Dust. The air glimmers...\nFor 30 minutes, shiny beasts are twice as likely." }
-- Blackrock
D.items.greatpotion = { name = "Greater Healing Potion", price = 1500, heal = 100, use = "heal",
    icon = "Interface\\Icons\\INV_Potion_53", desc = "Restores 100 HP to one beast." }
D.items.truesilverrod = { name = "Truesilver Taming Rod", price = 1200, ball = 2, use = "ball",
    icon = "Interface\\Icons\\INV_Wand_06",
    desc = "Truesilver from the Searing Gorge, and twice the odds of a Taming Rod. The Thorium Brotherhood swears by it." }
D.items.darkironale = { name = "Dark Iron Ale", price = 0, sell = 100, heal = 9999, use = "heal",
    icon = "Interface\\Icons\\INV_Drink_05",
    desc = "The Grim Guzzler's finest. Restores all of one beast's HP. Plugger Spazzring guards the tap." }
D.itemOrder = { "potion", "superpotion", "greatpotion", "darkironale", "antidote", "net", "greatnet", "truesilverrod",
                "illusiondust" }
D.shopStock = { "net", "potion", "antidote", "greatnet", "superpotion" }
-- Shops with more on the shelf (G:Shop(name, stockId)); a shop without a stock id sells D.shopStock.
-- (fireprotection is an alchemy potion, Crafting.lua; Thorium Point sells it too)
D.shopStocks = {
    maybell = { "potion", "antidote", "net" },                -- Maybell's stall in Goldshire
    lakeshire = { "net", "potion", "antidote", "greatnet", "superpotion", "greatpotion" },
    thorium = { "net", "antidote", "greatnet", "truesilverrod", "superpotion", "greatpotion", "fireprotection" },
}
function D.ShopStock(stockId) return (stockId and D.shopStocks[stockId]) or D.shopStock end

---------------------------------------------------------------------------
-- Status names
---------------------------------------------------------------------------

D.status = {
    brn = { short = "BRN", name = "burned",    color = { 0.94, 0.45, 0.20 } },
    psn = { short = "PSN", name = "poisoned",  color = { 0.62, 0.30, 0.75 } },
    par = { short = "PAR", name = "paralyzed", color = { 0.92, 0.80, 0.20 } },
    slp = { short = "SLP", name = "asleep",    color = { 0.60, 0.60, 0.60 } },
}

D.statNames = { atk = "Attack", def = "Defense", spa = "Sp. Atk", spd = "Sp. Def", spe = "Speed" }

---------------------------------------------------------------------------
-- Trainers. team = { { species, level }, ... }  prize = money per level of the last creature.
---------------------------------------------------------------------------

D.RIVAL_NAME = "Vera"          -- Huntmaster Aldric's granddaughter

D.trainers = {
    rival1 = { name = "Rival Vera", class = "rival", prize = 40, team = "rival",
               intro = "Wait, {PLAYER}! Let's see which of us picked better!",
               lose = "What? I picked the stronger one on purpose!",
               win = "Ha! Better luck next time, {PLAYER}!" },
    hunter1 = { name = "Apprentice Hunter Bram", class = "hunter", prize = 20,
                team = { { "wolfpup", 3 }, { "wolfpup", 4 } },
                intro = "I'm training for my Hunter's trial in Stormwind. You'll do nicely!",
                lose = "Back to Stormwind's Dwarven District for more lessons..." },
    druid1 = { name = "Druid Initiate Ellisara", class = "druid", prize = 24,
               team = { { "owlet", 4 }, { "tuskling", 5 } },
               intro = "Elune guide me! Cenarius himself would want to see how your beasts fight.",
               lose = "Ishnu-alah. You fight well, for a human." },
    miner1 = { name = "Fargodeep Miner Oskar", class = "miner", prize = 24,
               team = { { "kobling", 5 }, { "kobling", 6 } },
               intro = "The kobolds drove us out of Fargodeep Mine, so I tamed a few of them. You no take candle!",
               lose = "Fine. Take the candle." },
    captain = { name = "Deputy Rainer", class = "captain", prize = 50,
                team = { { "webling", 7 }, { "wolfpup", 7 }, { "kobling", 8 } },
                intro = "Westfall is crawling with Defias. By order of Marshal Dughan, nobody passes who can't hold their own!",
                lose = "Light be with you. You can hold your own... but Hogger still blocks the road west." },

    -- Forest's Edge: Hogger's camp
    gnoll1 = { name = "Riverpaw Bandit", class = "gnoll", prize = 30,
               team = { { "runt", 7 }, { "runt", 8 } },
               intro = "Yipyip! Human wants to see Hogger? First you fight me!",
               lose = "Grrr... Hogger will be angry..." },
    gnoll2 = { name = "Riverpaw Mystic", class = "gnoll", prize = 32,
               team = { { "scout", 8 }, { "webling", 9 } },
               intro = "The spirits said a tamer comes. The spirits did not say you were this small!",
               lose = "The spirits... lied." },
    hogger = { name = "Hogger", class = "boss", prize = 90, badge = "hogger",
               team = { { "runt", 10 }, { "scout", 11 }, { "hogger", 13 } },
               intro = "Grrr... fresh meat! More bones to gnaw on!",
               lose = "No hurt Hogger! Hogger... go now. Road is yours, small tamer." },

    -- Westfall
    defias1 = { name = "Defias Pillager", class = "defias", prize = 34,
                team = { { "coyote", 11 }, { "fleshripper", 11 } },
                intro = "Westfall belongs to the Brotherhood now. Hand over your coin!",
                lose = "Edwin VanCleef will hear of this..." },
    defias2 = { name = "Defias Trapper", class = "defias", prize = 36,
                team = { { "rustgolem", 12 }, { "coyote", 12 } },
                intro = "We fixed these golems up ourselves. Want to see what they do to trespassers?",
                lose = "Rusted junk! I told them to oil it." },
    defias3 = { name = "Defias Smuggler", class = "defias", prize = 36,
                team = { { "crawler", 11 }, { "coastrunner", 12 }, { "crawler", 12 } },
                intro = "Nobody sees what comes in off the Longshore. Nobody!",
                lose = "Fine, fine. You didn't see me. I didn't see you." },
    farmer1 = { name = "Farmhand Verna", class = "farmer", prize = 28,
                team = { { "tuskling", 12 }, { "dustdevil", 12 } },
                intro = "Since the Defias took the farms, we've had to learn to fight with whatever we've got!",
                lose = "You'd make a fine member of the People's Militia." },
    -- Moonbrook and the Deadmines (vanish: a boss leaves the passage once beaten)
    defias4 = { name = "Defias Looter", class = "defias", prize = 36,
                team = { { "coyote", 15 }, { "fleshripper", 16 } },
                intro = "Moonbrook belongs to the Brotherhood. Turn around, farmhand!",
                lose = "Fine... but you'll never get past Rhahk'Zor." },
    defias5 = { name = "Defias Taskmaster", class = "defias", prize = 40,
                team = { { "rustgolem", 16 }, { "kobling", 16 }, { "coyote", 17 } },
                intro = "Back to work, all of you! ...Wait, you don't work here.",
                lose = "I'm docking my own pay for this." },
    miner2 = { name = "Defias Miner", class = "defias", prize = 40,
               team = { { "tunneler", 17 }, { "minespider", 17 } },
               intro = "Another intruder in the tunnels? Rhahk'Zor will crush you!",
               lose = "Don't tell the foreman." },
    miner3 = { name = "Defias Overseer", class = "defias", prize = 44,
               team = { { "minespider", 18 }, { "tunneler", 18 } },
               intro = "Nobody gets to the foundry without passing me.",
               lose = "The foundry's ahead. Mind the goblins." },
    goblin1 = { name = "Goblin Engineer", class = "goblin", prize = 48,
                team = { { "shredder", 19 }, { "rustgolem", 19 } },
                intro = "Time is money, friend! And you're wasting both of mine!",
                lose = "Ow! My shredder! Do you know what those cost?" },
    pirate1 = { name = "Defias Pirate", class = "defias", prize = 48,
                team = { { "parrot", 20 }, { "coastrunner", 20 } },
                intro = "Arr! This cove belongs to the Juggernaut!",
                lose = "Polly wants a new captain..." },
    pirate2 = { name = "Defias Squallshaper", class = "defias", prize = 50,
                team = { { "tidehunter", 20 }, { "parrot", 21 } },
                intro = "The tides answer to me, landlubber!",
                lose = "The sea is fickle. So am I, apparently." },
    rhahkzor = { name = "Rhahk'Zor", class = "boss", prize = 70, vanish = true,
                 team = { { "tunneler", 17 }, { "rhahkzor", 19 } },
                 intro = "VanCleef pay big for your head!",
                 lose = "Rhahk'Zor... go tell VanCleef..." },
    sneed = { name = "Sneed", class = "boss", prize = 75, vanish = true,
              team = { { "shredder", 18 }, { "shredder", 19 }, { "sneedshredder", 20 } },
              intro = "Ha! You'll never get my shredder, you hear? NEVER!",
              lose = "Sneed's Shredder... in pieces! VanCleef will have my hide!" },
    gilnid = { name = "Gilnid", class = "boss", prize = 75, vanish = true,
               team = { { "minespider", 19 }, { "gilnid", 21 } },
               intro = "Anyone who comes near my smelter gets melted down!",
               lose = "Too hot... in here..." },
    smite = { name = "Mr. Smite", class = "boss", prize = 80, vanish = true,
              team = { { "parrot", 20 }, { "shredder", 20 }, { "smite", 22 } },
              intro = "We're under attack! A vast, ye swabs! Repel the invaders!",
              lose = "You landlubbers are tougher than I thought. I'll have to improvise!" },
    greenskin = { name = "Captain Greenskin", class = "boss", prize = 80, vanish = true,
                  team = { { "parrot", 21 }, { "coastrunner", 21 }, { "greenskin", 22 } },
                  intro = "Arr! You'll be walking the plank for this!",
                  lose = "Abandon... ship..." },
    cookie = { name = "Cookie", class = "boss", prize = 80, vanish = true,
               team = { { "tidehunter", 21 }, { "cookie", 22 } },
               intro = "Mrrrglglglgl! (Cookie is guarding the galley. The stew smells terrible.)",
               lose = "Mrgl... (Cookie drops his ladle.)" },
    vancleef = { name = "Edwin VanCleef", class = "boss", prize = 150, badge = "vancleef", vanish = true,
                 requires = { "greenskin", "cookie" },
                 notYet = "You'll have to get past my crew first. Greenskin! Cookie! Deal with this one!",
                 team = { { "minespider", 22 }, { "shredder", 23 }, { "vancleef", 25 } },
                 intro = "None may challenge the Brotherhood! Stormwind paid me with lies - I'll take my wages in blood!",
                 lose = "The Brotherhood... will prevail..." },

    -- Duskwood. Raven Hill:
    nightrunner = { name = "Defias Night Runner", class = "defias", prize = 46,
                    team = { { "pygmyweb", 23 }, { "ravager", 24 } },
                    intro = "VanCleef's gone? Then Duskwood's roads belong to whoever's quickest. Tonight, that's me.",
                    lose = "Fine, fine. The road's yours. Watch out for the things that come out after dark." },
    ladimore = { name = "Watcher Ladimore", class = "watch", prize = 48,
                 team = { { "skeleton", 24 }, { "flesheater", 25 } },
                 intro = "I stood watch over these graves in life, and I stand watch still. Prove you mean them no harm!",
                 lose = "Your heart is true. Lay Mor'Ladim to rest, tamer, and maybe I can rest too." },
    morladim = { name = "Mor'Ladim", class = "boss", prize = 90, vanish = true,
                 vanishText = "Mor'Ladim sinks back into his grave. Raven Hill is quiet, for now.",
                 team = { { "skeleton", 25 }, { "skeleton", 26 }, { "morladim", 28 } },
                 intro = "Who... disturbs... the dead of Raven Hill?",
                 lose = "Rest... at last..." },
    -- the Duskwood road
    nightblade = { name = "Defias Night Blade", class = "defias", prize = 48,
                   team = { { "darkrunner", 25 }, { "pygmyweb", 26 } },
                   intro = "A tamer on the Duskwood road? I'll take that purse off your hands.",
                   lose = "Keep your purse. I'm off to Stranglethorn." },
    dodds = { name = "Watcher Dodds", class = "watch", prize = 50,
              team = { { "ravager", 26 }, { "venomweb", 27 } },
              intro = "Halt! The Night Watch tests everyone on this road. Worgen have been known to wear human faces.",
              lose = "No worgen fights like that. Welcome to Duskwood, friend." },
    ogre1 = { name = "Splinter Fist Taskmaster", class = "ogre", prize = 52,
              team = { { "worm", 26 }, { "splinterfist", 28 } },
              intro = "You in Splinter Fist land! You fight, or you go squish!",
              lose = "Ugh. You not squish. Taskmaster... confused." },
    morbentfel = { name = "Morbent Fel", class = "boss", prize = 95, vanish = true, needFlag = "morbentbane",
                   vanishText = "Morbent Fel's shadows scatter to the wind. The Yorgen farm is free.",
                   notYet = "Ha! Your beasts' blows pass right through me. Come back when you know what a Bane is, fool.",
                   team = { { "flesheater", 27 }, { "darkrunner", 28 }, { "morbentfel", 29 } },
                   intro = "Morbent's Bane! Where did you... no matter. The dead of this farm serve ME!",
                   lose = "My... power... fading..." },
    -- Manor Mistmantle
    stalvan = { name = "Stalvan Mistmantle", class = "boss", prize = 100, vanish = true,
                vanishText = "Stalvan fades into the manor's dust. The house is finally still.",
                team = { { "skeleton", 28 }, { "braineater", 29 }, { "stalvan", 30 } },
                intro = "So you found my letters. Then you know what I did... and you will never tell a soul!",
                lose = "Forgive me... all of you..." },
    -- Darkshire
    backus = { name = "Watcher Backus", class = "watch", prize = 54,
               team = { { "venomweb", 28 }, { "mastiff", 30 } },
               intro = "Commander Ebonlocke wants to know what you're made of. So do I!",
               lose = "You'd make a fine Watcher. The Commander will hear of this." },
    paige = { name = "Watcher Paige", class = "watch", prize = 54,
              team = { { "flesheater", 28 }, { "skelhorror", 30 } },
              intro = "I've fought the dead every night for three years. Let's see how you do in daylight.",
              lose = "Well fought. Keep that up and the dead won't stand a chance." },
    stitches = { name = "Stitches", class = "boss", prize = 170, badge = "nightwatch", vanish = true,
                 requires = { "morladim", "morbentfel", "stalvan" },
                 vanishText = "Stitches falls apart at the seams. The Night Watch cheers from the walls!",
                 team = { { "braineater", 30 }, { "vilefang", 31 }, { "stitches", 33 } },
                 intro = "(Stitches shambles toward Darkshire. Its stitched mouth moans one word: DARKSHIRE.)",
                 lose = "(Stitches crashes to the ground and doesn't get up.)" },

    militia1 = { name = "Militia Sergeant Dane", class = "militia", prize = 45,
                 team = { { "packleader", 14 }, { "reaper", 14 } },
                 intro = "Gryan Stoutmantle trained me himself. Show me what Elwynn's tamers are made of!",
                 lose = "Stoutmantle will want to meet you. Go on up to Sentinel Hill." },

    -- Stranglethorn Vale. The Rebel Camp and Kurzen's Compound:
    kaleb = { name = "Corporal Kaleb", class = "militia", prize = 56,
              team = { { "tigercub", 31 }, { "raptorling", 32 } },
              intro = "Deserter, they call me. I call it not wanting to drink troll medicine. Show me you can hold the jungle!",
              lose = "You'll do. Doren wants a word, and Kurzen's cave is east." },
    bluth = { name = "Corporal Bluth", class = "militia", prize = 56,
              team = { { "pantherkit", 32 }, { "rivercroc", 32 } },
              intro = "Rebel Camp rules: nobody goes south who can't fight a panther. Let's see.",
              lose = "Fine. The vale's yours to lose." },
    kfighter = { name = "Kurzen Jungle Fighter", class = "kurzen", prize = 58,
                 team = { { "tigercub", 33 }, { "pantherkit", 34 } },
                 intro = "The Colonel says no one leaves and no one enters. You entered.",
                 lose = "The Colonel... will not be pleased." },
    kmedicine = { name = "Kurzen Medicine Man", class = "kurzen", prize = 60,
                  team = { { "crystalspine", 34 }, { "trollscout", 34 } },
                  intro = "Troll medicine, human hands. Drink deep, the Colonel says. DRINK DEEP!",
                  lose = "Ugh... my head..." },
    kheadshrinker = { name = "Kurzen Headshrinker", class = "kurzen", prize = 62,
                      team = { { "pantherkit", 35 }, { "crystalspine", 35 }, { "tigercub", 35 } },
                      intro = "Your head would look fine on a string, tamer. Small, though.",
                      lose = "Keep your head. For now." },
    kurzen = { name = "Colonel Kurzen", class = "boss", prize = 110, vanish = true,
               vanishText = "Colonel Kurzen staggers back into the dark of his compound. His men lay down their arms.",
               team = { { "pantherkit", 37 }, { "tiger", 38 }, { "kurzen", 40 } },
               intro = "Stormwind sent you? STORMWIND? I am Stormwind in this jungle! Kneel!",
               lose = "The jungle... it was never mine..." },
    -- Nesingwary's Expedition
    ajeck = { name = "Ajeck Rouack", class = "hunter", prize = 60,
              team = { { "tigercub", 34 }, { "tiger", 36 } },
              intro = "A tamer! Hemet says a tamed tiger is a wasted tiger. Let's see if he's right.",
              lose = "Hmph. Maybe not so wasted. Go see Hemet." },
    erlgadin = { name = "Sir S. J. Erlgadin", class = "hunter", prize = 62,
                 team = { { "pantherkit", 35 }, { "panther", 36 } },
                 intro = "Panthers, old chap. Eleven years I've hunted them. Yours won't last eleven minutes.",
                 lose = "Well hunted, well hunted. Tell Hemet I said so, and he'll never believe you." },
    barnil = { name = "Barnil Stonepot", class = "hunter", prize = 60,
               team = { { "raptorling", 35 }, { "rivercroc", 35 }, { "lashtail", 36 } },
               intro = "I cook for the expedition, mostly. But I've a few raptors that'll cook YOU.",
               lose = "Right. Back to the stew pot." },
    bangalash = { name = "King Bangalash", class = "boss", prize = 120, vanish = true,
                  vanishText = "King Bangalash limps into the jungle. Nesingwary's wall stays empty, but the story is yours.",
                  team = { { "tiger", 40 }, { "eldertiger", 42 }, { "bangalash", 43 } },
                  intro = "(The great white tiger steps from the trees. It has been watching you for an hour.)",
                  lose = "(King Bangalash roars once, at the whole vale, and is gone.)" },
    hemet = { name = "Hemet Nesingwary Jr.", class = "boss", prize = 150, badge = "nesingwary",
              requires = { "ajeck", "erlgadin", "barnil", "bangalash" },
              notYet = "Nesingwary's rule: nobody hunts with me who hasn't hunted with my people. Ajeck, Erlgadin and Barnil first. Then King Bangalash, who'll show himself once they've had a look at you. THEN we talk.",
              team = { { "tiger", 42 }, { "panther", 42 }, { "junglestalker", 44 } },
              intro = "Bangalash himself! Father would have wept. Right then: the last hunt of the season. You and me!",
              lose = "By the Great Hunt, you've beaten a Nesingwary. Take the Trophy. Father will never believe it." },
    -- the Bal'lal Ruins and Zul'Mamwe
    bloodscalp1 = { name = "Bloodscalp Headhunter", class = "troll", prize = 62,
                    team = { { "trollscout", 35 }, { "tigercub", 36 } },
                    intro = "Ya come to Bal'lal, mon? Da loa be hungry today.",
                    lose = "Da loa... be full." },
    bloodscalp2 = { name = "Bloodscalp Witch Doctor", class = "troll", prize = 64,
                    team = { { "rivercroc", 36 }, { "trollscout", 36 }, { "pantherkit", 37 } },
                    intro = "Ya beasts got no voodoo, mon. Mine do.",
                    lose = "Bad juju. Very bad juju." },
    skull1 = { name = "Skullsplitter Axe Thrower", class = "troll", prize = 66,
               team = { { "trollscout", 38 }, { "lashtail", 39 } },
               intro = "Zul'Mamwe belong to da Skullsplitters now, mon. Ya skull too, soon.",
               lose = "Keep ya skull, mon. For now." },
    skull2 = { name = "Skullsplitter Spiritchaser", class = "troll", prize = 68,
               team = { { "panther", 39 }, { "berserker", 42 } },
               intro = "Da spirits say a tamer come. Da spirits didn't say ya be so small.",
               lose = "Da spirits... lied again." },
    venture1 = { name = "Venture Co. Geologist", class = "goblin", prize = 64,
                 team = { { "crystalspine", 38 }, { "shredder", 38 } },
                 intro = "These ruins are a Venture Company dig site! Trespassers get billed!",
                 lose = "Fine, fine. I'll bill the trolls instead." },
    venture2 = { name = "Venture Co. Surveyor", class = "goblin", prize = 64,
                 team = { { "shredder", 39 }, { "rustgolem", 38 }, { "crystalspine", 39 } },
                 intro = "I surveyed this whole valley, and nowhere on the map does it say 'tamers welcome'.",
                 lose = "I'll add it. In pencil." },
    ganzulah = { name = "Gan'zulah", class = "boss", prize = 130, vanish = true,
                 vanishText = "Gan'zulah drags himself into the ruins. The Skullsplitters go quiet, for a while.",
                 team = { { "berserker", 42 }, { "panther", 42 }, { "ganzulah", 44 } },
                 intro = "Ya come for my skulls, mon? Gan'zulah be adding one more tonight!",
                 lose = "Da loa... turned from me..." },
    -- the Mosh'Ogg mound
    ogrewd = { name = "Mosh'Ogg Witch Doctor", class = "ogre", prize = 68,
               team = { { "splinterfist", 40 }, { "crystalspine", 40 } },
               intro = "Little thing walk into ogre mound. Little thing make good stew.",
               lose = "Stew... ruined." },
    ogreshaman = { name = "Mosh'Ogg Shaman", class = "ogre", prize = 70,
                   team = { { "tarantula", 41 }, { "splinterfist", 42 } },
                   intro = "Spirits say smash. Shaman always do what spirits say.",
                   lose = "Spirits... wrong this time." },
    maizoth = { name = "Mai'Zoth", class = "boss", prize = 140, vanish = true,
                vanishText = "Mai'Zoth's heads argue all the way back into the mound. The ogres keep to their cave.",
                team = { { "splinterfist", 43 }, { "mauler", 45 }, { "maizoth", 46 } },
                intro = "Me smash! No, ME smash! ...We both smash!",
                lose = "Your fault! No, YOUR fault!" },
    -- Southern Stranglethorn and Crystalvein Mine
    bighunter = { name = "Big Game Hunter Thorne", class = "hunter", prize = 70,
                  team = { { "tiger", 41 }, { "gorilla", 42 } },
                  intro = "Nesingwary's lot are amateurs. I hunt what hunts them.",
                  lose = "Hmph. Tell Nesingwary nothing." },
    venture3 = { name = "Venture Co. Strip Miner", class = "goblin", prize = 68,
                 team = { { "rustgolem", 41 }, { "coldeye", 42 } },
                 intro = "The mine's that way, and it's ours. Time is money, and you're wasting mine!",
                 lose = "Ow. Docked. Again." },
    trollhunter = { name = "Skullsplitter Hunter", class = "troll", prize = 70,
                    team = { { "lashtail", 42 }, { "panther", 42 }, { "trollscout", 43 } },
                    intro = "Ya walk loud, mon. Da whole valley hear ya coming.",
                    lose = "Ya fight quieter than ya walk." },
    venture4 = { name = "Venture Co. Foreman", class = "goblin", prize = 74,
                 team = { { "shredder", 43 }, { "coldeye", 44 } },
                 intro = "This mine produces! Basilisk crystal, top grade! And you're not on the payroll!",
                 lose = "Production's down. Somebody's getting fired. Not me." },
    venture5 = { name = "Venture Co. Tinkerer", class = "goblin", prize = 74,
                 team = { { "shredder", 43 }, { "reaper", 43 }, { "shredder", 44 } },
                 intro = "I modified these shredders myself. Bigger blades. Louder engines. What could go wrong?",
                 lose = "...That. That could go wrong." },
    venture6 = { name = "Venture Co. Mechanic", class = "goblin", prize = 72,
                 team = { { "rustgolem", 43 }, { "tarantula", 44 } },
                 intro = "Nobody touches the drill. NOBODY.",
                 lose = "You touched the drill, didn't you." },
    -- the Wild Shore: Aboraz and the Bloodsail landing
    zanzilwd = { name = "Zanzil Witch Doctor", class = "troll", prize = 76,
                 team = { { "zombie", 45 }, { "zombie", 45 }, { "trollscout", 46 } },
                 intro = "Zanzil's mixture make dem walk. Zanzil's mixture make YOU walk, soon.",
                 lose = "Da mixture... need more work." },
    zanzil = { name = "Zanzil the Outcast", class = "boss", prize = 150, vanish = true,
               vanishText = "Zanzil's zombies fall where they stand. The Ruins of Aboraz are quiet at last.",
               team = { { "zombie", 46 }, { "berserker", 47 }, { "zanzil", 49 } },
               intro = "Cast out by da Bloodscalps, cast out by everyone. But da dead never cast me out!",
               lose = "Even da dead... leave me..." },
    swashbuckler = { name = "Bloodsail Swashbuckler", class = "pirate", prize = 78,
                     team = { { "parrot", 45 }, { "saltwatercroc", 46 } },
                     intro = "Arr! Bloodsail colours fly over this beach, landlubber!",
                     lose = "Polly... wants a new employer." },
    seadog = { name = "Bloodsail Sea Dog", class = "pirate", prize = 78,
               team = { { "snapjaw", 46 }, { "parrot", 46 }, { "tidecaller", 47 } },
               intro = "The Baron's port will be ours by the new moon! Out of the way!",
               lose = "The new moon... can wait." },
    stillwater = { name = "Captain Stillwater", class = "pirate", prize = 90, vanish = true,
                   vanishText = "Captain Stillwater rows out to the fleet without a word.",
                   team = { { "saltwatercroc", 47 }, { "tidecaller", 48 }, { "parrot", 48 } },
                   intro = "Still waters run deep, tamer. Mine run red.",
                   lose = "Firallon will hear of this. Not from me." },
    keelhaul = { name = "Captain Keelhaul", class = "pirate", prize = 90, vanish = true,
                 vanishText = "Captain Keelhaul is dragged below decks by his own crew.",
                 team = { { "parrot", 48 }, { "snapjaw", 48 }, { "murlocwarrior", 49 } },
                 intro = "Keelhauled, that's what you'll be! Under the ship and up the other side!",
                 lose = "Under the ship... and up... urgh." },
    firallon = { name = "Fleet Master Firallon", class = "boss", prize = 200, badge = "blackwater", vanish = true,
                 requires = { "keelhaul", "stillwater" },
                 notYet = "My captains first, tamer. Keelhaul! Stillwater! Deal with this one!",
                 vanishText = "The Bloodsail fleet weighs anchor and slinks south. Booty Bay's bells ring out!",
                 team = { { "tidecaller", 49 }, { "murlocwarrior", 50 }, { "firallon", 52 } },
                 intro = "So the Baron's found a champion. I've sunk champions. Batten down, lads!",
                 lose = "Strike the colours... we'll be back for the bay..." },
    -- Booty Bay and Jaguero Isle
    marine = { name = "Blackwater Marine", class = "pirate", prize = 80,
               team = { { "saltwatercroc", 47 }, { "gorilla", 48 } },
               intro = "Blackwater Raiders! Nobody walks Booty Bay's docks without proving they belong here.",
               lose = "You belong. Welcome to Booty Bay." },
    bruiser = { name = "Booty Bay Bruiser", class = "goblin", prize = 82,
                team = { { "shredder", 48 }, { "coldeye", 48 }, { "panther", 49 } },
                intro = "The Baron pays me to keep the peace. He pays extra for breaking it.",
                lose = "Peace kept. Mostly." },
    castaway = { name = "Castaway Rutger", class = "pirate", prize = 84,
                 team = { { "gorilla", 48 }, { "lashtail", 48 }, { "eldergorilla", 49 } },
                 intro = "Three years on this isle. The gorillas are my only friends. They fight for me. FIGHT FOR ME!",
                 lose = "They... left me. Everybody leaves." },
    mukla = { name = "King Mukla", class = "boss", prize = 170, vanish = true,
              vanishText = "King Mukla thumps his chest one last time and lumbers into the trees. The bananas are yours.",
              team = { { "eldergorilla", 49 }, { "silverback", 51 }, { "mukla", 52 } },
              intro = "(King Mukla drops from the canopy. The ground shakes. So do you.)",
              lose = "(King Mukla sits down, very carefully, and looks at you with something like respect.)" },
    -- Blackrock: Redridge (Three Corners, Lake Everstill, Stonewatch Keep)
    rrpoacher = { name = "Redridge Poacher", class = "redridge", prize = 80,
                  team = { { "mongrel", 49 }, { "condor", 50 } },
                  intro = "Grrr! Lakeshire's road belongs to the pack now!",
                  lose = "Grr... the pack will hear of this. Yip." },
    yowler = { name = "Yowler", class = "boss", prize = 120, vanish = true,
               vanishText = "Yowler yelps and bolts for the hills. Lakeshire's bridge crew can get back to work.",
               team = { { "rrbrute", 51 }, { "rrmystic", 51 }, { "rralpha", 52 } },
               intro = "Yip! You walk on Yowler's bridge? Yowler eats travellers!",
               lose = "Yowler... not hungry any more." },
    bwgrunt = { name = "Blackrock Grunt", class = "blackrock", prize = 84,
                team = { { "emberworg", 52 }, { "firegut", 52 } },
                intro = "Lok'tar! The Warlord sees no one!",
                lose = "The Warlord... will see you. And then you'll wish he hadn't." },
    bwshadow = { name = "Blackrock Shadowcaster", class = "blackrock", prize = 86,
                 team = { { "rrmystic", 52 }, { "broodling", 53 } },
                 intro = "The shadows told me you would come. They lied about how small you are.",
                 lose = "The shadows... said nothing about this." },
    gath = { name = "Gath'Ilzogg", class = "boss", prize = 210, badge = "stonewatch", vanish = true,
             requires = { "bwgrunt", "bwshadow" },
             notYet = "Gath'Ilzogg: You crawl past my guards? No. Beat them first, whelp, and then you may bleed for me.",
             vanishText = "Gath'Ilzogg flings down his banner and storms north into Render's Valley. Stonewatch Keep falls quiet.",
             team = { { "rralpha", 53 }, { "emberworg", 53 }, { "fgbrute", 54 }, { "blackwyrmkin", 55 } },
             intro = "Lakeshire burns because I allow it, whelp. Show me your beasts. Then show me your back as you run.",
             lose = "Blackrock does not forget. Neither will I." },
    -- the Burning Steppes and Blackrock Mountain: Lord Victor Nefarius, twice
    nef1 = { name = "Lord Victor Nefarius", class = "boss", prize = 180, vanish = true,
             vanishText = "Lord Victor Nefarius smiles, bows, and is simply not there any more. Ash drifts where he stood.",
             cache = { needs = { "nef1", "nef2" }, flag = "nef_cache", items = { blackdragonscale = 5 },
                       text = "Nefarius left something behind: a cache of Black Dragonscales, still warm." },
             team = { { "broodling", 55 }, { "scaldingdrake", 55 }, { "greaterlava", 56 } },
             intro = "Such a charming little menagerie. Do keep collecting. I collect too: champions.",
             lose = "Fascinating. We shall meet again on the mountain, little collector." },
    nef2 = { name = "Lord Victor Nefarius", class = "boss", prize = 190, vanish = true,
             vanishText = "Lord Victor Nefarius steps back into the dark of the Spire. Somewhere above, something very large stirs.",
             cache = { needs = { "nef1", "nef2" }, flag = "nef_cache", items = { blackdragonscale = 5 },
                       text = "Nefarius left something behind: a cache of Black Dragonscales, still warm." },
             team = { { "blackwyrmkin", 57 }, { "scaldingdrake", 56 }, { "greaterlava", 57 }, { "ragetalon", 57 } },
             intro = "Again? You do make an excellent experiment. Let us see what fire does to you.",
             lose = "Enough. My sister would have liked you. Briefly." },
    -- the Searing Gorge and Blackrock Depths
    dimaster = { name = "Dark Iron Taskmaster", class = "darkiron", prize = 90,
                 team = { { "temperedgolem", 55 }, { "magma", 56 }, { "glassweb", 56 } },
                 intro = "Back to the dig, slave! ...Oh. You're not one of mine.",
                 lose = "Fine. Dig your own hole, then." },
    senator = { name = "Shadowforge Senator", class = "darkiron", prize = 92,
                team = { { "fireguard", 57 }, { "firewalker", 57 } },
                intro = "The Senate is in session. You are out of order.",
                lose = "The motion... fails." },
    warden = { name = "Anvilrage Warden", class = "darkiron", prize = 92,
               team = { { "heavygolem", 57 }, { "lavaspider", 57 } },
               intro = "Prisoners stay in the Detention Block. Visitors stay dead.",
               lose = "Visitors... may leave." },
    thaurissan = { name = "Emperor Dagran Thaurissan", class = "boss", prize = 230, badge = "darkiron", vanish = true,
                   requires = { "senator", "warden" },
                   notYet = "Emperor Dagran Thaurissan: The Emperor does not fight. My Senator and my Warden will deal with you.",
                   vanishText = "Thaurissan staggers from the throne and is gone in a gout of flame. Princess Moira stays at the Seat.",
                   team = { { "firewalker", 58 }, { "heavygolem", 58 }, { "obsidian", 59 }, { "torcher", 59 }, { "fireguard", 60 } },
                   intro = "You dare stand before the throne of Thaurissan? Ragnaros hears every beast you lose here.",
                   lose = "Ragnaros... my lord... I have failed you..." },
}

---------------------------------------------------------------------------
-- Badges (from gym-leader style bosses)
---------------------------------------------------------------------------

D.badges = {
    hogger = { name = "Hogger's Claw", order = 1,
               text = "Proof that you bested the terror of Elwynn. Deputy Rainer will let you through to Westfall now." },
    vancleef = { name = "VanCleef's Bandana", order = 2,
                 text = "The red bandana of the Defias Brotherhood's leader. Gryan Stoutmantle will want to see this." },
    nightwatch = { name = "Night Watch Seal", order = 3,
                   text = "The seal of Darkshire's Night Watch. Commander Althea Ebonlocke will want to thank you." },
    nesingwary = { name = "Nesingwary's Trophy", order = 4,
                   text = "King Bangalash's paw print, cast in bronze. Every hunter in the vale knows what it means." },
    blackwater = { name = "Blackwater Seal", order = 5,
                   text = "The seal of Booty Bay's Blackwater Raiders. Baron Revilgaz will want to see it." },
    stonewatch = { name = "Stonewatch Seal", order = 6,
                   text = "Gath'Ilzogg's seal from Stonewatch Keep. Lakeshire's guards will let you through Render's Valley now." },
    darkiron = { name = "Dark Iron Signet", order = 7,
                 text = "The Emperor's own signet. Lothos Riftwaker opens the way to the Molten Core for whoever carries it." },
}

---------------------------------------------------------------------------
-- Class perks (your real WoW class). Small bonuses; never used in battles between players (both clients must
-- compute those identically). Keys the engine understands:
--   catch   taming odds multiplier            exp     experience multiplier     prize   trainer money multiplier
--   healAfter  % of max HP healed after a won battle   cureAfter  poison / burns / paralysis cured after battles
--   keepMoney  no money lost on a blackout            startAtk   your lead starts trainer battles at +1 Attack
--   walk    walking/running time multiplier (< 1 = faster)     moreType  that type's wild beasts appear twice as often
---------------------------------------------------------------------------

D.classPerks = {
    HUNTER  = { name = "Tame Beast", catch = 1.25, text = "Hunters tame beasts 25% more easily." },
    DRUID   = { name = "Rejuvenation", healAfter = 10, text = "Druids' beasts recover 10% health after each win." },
    PALADIN = { name = "Cleanse", cureAfter = true, text = "Paladins cleanse poison, burns and paralysis after each battle." },
    PRIEST  = { name = "Spirit of Redemption", keepMoney = true, text = "Priests lose no money when they black out." },
    MAGE    = { name = "Arcane Intellect", exp = 1.1, text = "Mages' beasts earn 10% more experience." },
    WARLOCK = { name = "Demonic Pact", moreType = "SHADOW", text = "Shadow beasts are drawn to warlocks (twice as common)." },
    ROGUE   = { name = "Pick Pocket", prize = 1.2, text = "Rogues collect 20% more money from beaten trainers." },
    WARRIOR = { name = "Battle Shout", startAtk = 1, text = "A warrior's lead beast starts trainer battles with +1 Attack." },
    SHAMAN  = { name = "Ghost Wolf", walk = 0.8, text = "Shamans travel 25% faster on foot." },
}

-- Per-class lines for NPCs (G:ClassSay("npc")). Missing classes simply get no extra line.
D.classLines = {
    aldric = {
        HUNTER = "Huntmaster Aldric: A hunter! Then you already know: a beast is a partner, never a tool.",
        DRUID = "Huntmaster Aldric: A druid of the Cenarion Circle? The beasts will trust you before they trust me.",
        WARLOCK = "Huntmaster Aldric: A warlock... keep your imps away from my crates, please.",
        PALADIN = "Huntmaster Aldric: A paladin! The Light and the wild aren't so different, you'll find.",
    },
    gorvin = {
        HUNTER = "Gorvin Wildhammer: A hunter! Then ye know a pet's worth more than any gold. I'll not waste yer time.",
        DRUID = "Gorvin Wildhammer: A druid? Ha! Ye could teach ME a thing or two about beasts.",
    },
    farley = {
        PRIEST = "Innkeeper Farley: A priest! You'll be wanting the quiet room, I expect.",
        ROGUE = "Innkeeper Farley: Rogues pay up front here. No offence.",
        MAGE = "Innkeeper Farley: Please don't conjure water in the dining room again.",
        WARRIOR = "Innkeeper Farley: Weapons at the door. Well... mind the furniture, at least.",
        SHAMAN = "Innkeeper Farley: A shaman! My grandmother said the spirits liked this inn.",
    },
    dughan = {
        WARRIOR = "Marshal Dughan: A warrior. Good. The Stormwind Guard could use more like you.",
        PALADIN = "Marshal Dughan: Light be with you, paladin.",
        HUNTER = "Marshal Dughan: Keep your pet on a leash in Goldshire, hunter. Last one ate a chicken.",
    },
}

---------------------------------------------------------------------------
-- Raid rares: when you are in a raid that kills one of these bosses (the game's ENCOUNTER_END), its creature
-- roams an Azeromon area for `hours`. `boss` is the key in DisasterZone's raid data (Data/Items.lua), which also gives
-- the encounter ID. `coast` puts it in the shore grass instead of the tall grass.
---------------------------------------------------------------------------

D.RAID_RARE_WEIGHT = 8          -- vs ~100 for the area's normal beasts
D.raidRares = {
    { boss = "Attumen",     sp = "midnight",   map = "route1",     level = 16, hours = 24 },
    { boss = "OperaWolf",   sp = "bigbadwolf", map = "route1",     level = 16, hours = 24 },   -- any Opera kill (655)
    { boss = "Nightbane",   sp = "nightbane",  map = "forestedge", level = 16, hours = 24 },
    { boss = "Gruul",       sp = "gronnling",  map = "westfall",   level = 16, hours = 24 },
    { boss = "Magtheridon", sp = "pitling",    map = "forestedge", level = 16, hours = 24 },
    { boss = "Lurker",      sp = "lurkling",   map = "westfall",   level = 16, hours = 24, coast = true },
    { boss = "Alar",        sp = "ashling",    map = "westfall",   level = 16, hours = 24 },
    -- Blackrock: a second beast for two bosses (both roam once the boss falls)
    { boss = "Magtheridon", sp = "corehound",  map = "steppes",    level = 55, hours = 24 },
    { boss = "Alar",        sp = "lavasurger", map = "gorge",      level = 56, hours = 24 },
}

---------------------------------------------------------------------------
-- 0.36 battles: cooldowns, combos and casts (designed and tuned in the dev kit's balance sim, 2026-10-17:
-- dev/art/casc/combat_mockup, sim.js; "press the strongest" wins 33 % of even duels, good play ~58 %, every slot used).
-- Every type has six moves in six roles; a beast knows four: filler + setup + payoff, and one of big cast / guard /
-- interrupt (Nature: Regrowth instead of an interrupt), swapped at the Pet Trainer.
-- Move fields read by Battle.lua:
--   cd          turns the move rests after use (0 = every turn)
--   role        filler / setup / payoff / nuke / guard / interrupt / heal / buff (the AI and the move box read it)
--   mark        { id, turns, who = "self" }: a timed mark (D.MARKS)
--   payoff      { mark | status, mult, consume, self }: power x mult while the target (or `self`) carries it
--   cast        announced this turn, lands next turn (castVerb: "begins winding up ..."); unstoppable: can't be
--               interrupted
--   guard       damage taken x guard for guardTurns turns, priority 2;  interrupt: breaks the target's cast
--   heal        share of max HP restored;  noImmune: no effect becomes not very effective (thrown rocks vs fliers)
---------------------------------------------------------------------------

D.BATTLE_HP = 1.6           -- battles last ~5 turns: hits do 1 / 1.6 of the Gen III damage (HP fractions unchanged)
-- A boss's own number, from tests/games/azero_balance.py (three beasts at the ace's level, no items, 150 fights):
-- the highest at which the rule list wins 20 points more often than pressing the strongest move did before 0.36
-- (at most 80 %). Mashing now wins less than it used to, or about as often. Unlisted bosses keep D.BATTLE_HP.
D.BOSS_HP = { morladim = 1.0, morbentfel = 1.0, stalvan = 1.0, stitches = 0.5, kurzen = 1.0, ganzulah = 0.8,
              maizoth = 0.8, zanzil = 0.7, mukla = 1.3, firallon = 1.0 }
-- the same for a boss team led by an ordinary beast (by trainer id): the whole team takes it
D.TEAM_HP = { yowler = 1.3, gath = 1.0, nef1 = 1.0, nef2 = 1.3, thaurissan = 1.0 }
D.MARK_DOT = 12             -- a damage-over-time mark with no caster (tests) takes 1/12 of max HP a turn
D.MARK_DOT_POWER = 22      -- otherwise each tick is a power-22 hit of the caster's, fixed when the mark lands
                           -- (~1/12 of max HP between equals; a stronger caster's marks hurt more)

D.MARKS = {
    bleed    = { name = "Bleeding",  short = "BLEED",    dot = true, color = { 0.79, 0.28, 0.24 }, desc = "Bleeds a little each turn." },
    immolate = { name = "Immolated", short = "IMMOLATE", dot = true, color = { 0.91, 0.46, 0.18 }, desc = "Burns a little each turn." },
    corrupt  = { name = "Corrupted", short = "CORRUPT",  dot = true, color = { 0.56, 0.37, 0.77 }, desc = "Withers a little each turn." },
    chill    = { name = "Chilled",   short = "CHILL",    speed = 0.5, color = { 0.37, 0.70, 0.91 }, desc = "Speed halved." },
    rooted   = { name = "Rooted",    short = "ROOTED",   color = { 0.36, 0.61, 0.20 }, desc = "Held in place by roots." },
    exposed  = { name = "Exposed",   short = "EXPOSED",  color = { 0.79, 0.60, 0.17 }, desc = "Marked for the kill." },
    charged  = { name = "Charged",   short = "CHARGED",  color = { 0.18, 0.70, 0.67 }, desc = "Building up power." },
    regrowth = { name = "Regrowth",  short = "REGROWTH", hot = 10, color = { 0.31, 0.62, 0.23 }, desc = "Heals 1/10 of its HP each turn." },
}

do
    local function K(name, typ, role, o)
        o.name, o.type, o.role = name, typ, role
        o.power, o.acc, o.cd, o.prio = o.power or 0, o.acc or 100, o.cd or 0, o.prio or 0
        o.pp = o.pp or ({ filler = 35, setup = 20, payoff = 15, nuke = 10, guard = 15, interrupt = 15, heal = 10 })[role]
        return o
    end
    local function Guard(name, typ) return K(name, typ, "guard", { guard = 0.25, guardTurns = 2, prio = 2, cd = 3 }) end
    local function Int(name, typ) return K(name, typ, "interrupt", { power = 30, prio = 1, cd = 4, interrupt = true }) end
    local function Cast(name, typ, verb) return K(name, typ, "nuke", { power = 100, acc = 95, cd = 3, cast = true, castVerb = verb }) end
    local kit = {
        -- BEAST (physical)
        kclaw       = K("Claw", "BEAST", "filler", { power = 40 }),
        krend       = K("Rend", "BEAST", "setup", { power = 25, cd = 3, mark = { id = "bleed", turns = 3 } }),
        kferobite   = K("Ferocious Bite", "BEAST", "payoff", { power = 50, cd = 3, payoff = { mark = "bleed", mult = 1.8, consume = true } }),
        kmaul       = Cast("Savage Maul", "BEAST", "winding up"),
        khide       = Guard("Thick Hide", "BEAST"),
        kskullbash  = Int("Skull Bash", "BEAST"),
        -- FIRE (special)
        kscorch     = K("Scorch", "FIRE", "filler", { power = 40 }),
        kimmolate   = K("Immolate", "FIRE", "setup", { power = 10, cd = 3, mark = { id = "immolate", turns = 3 } }),
        kincinerate = K("Incinerate", "FIRE", "payoff", { power = 50, cd = 3, payoff = { mark = "immolate", mult = 1.6 } }),
        kpyroblast  = Cast("Pyroblast", "FIRE"),
        kfireward   = Guard("Fire Ward", "FIRE"),
        kcounterspell = Int("Counterspell", "FIRE"),
        -- WATER (special)
        kwaterbolt  = K("Water Bolt", "WATER", "filler", { power = 40 }),
        kfrostshock = K("Frost Shock", "WATER", "setup", { power = 25, cd = 3, mark = { id = "chill", turns = 2 } }),
        kicelance   = K("Ice Lance", "WATER", "payoff", { power = 40, cd = 2, payoff = { mark = "chill", mult = 2.3 } }),
        ktidalwave  = Cast("Tidal Wave", "WATER", "calling"),
        kshellshield = Guard("Shell Shield", "WATER"),
        kwindshear  = Int("Wind Shear", "WATER"),
        -- NATURE (special)
        kthorns     = K("Thorns", "NATURE", "filler", { power = 40 }),
        kroots      = K("Entangling Roots", "NATURE", "setup", { power = 10, acc = 95, cd = 3, mark = { id = "rooted", turns = 3 } }),
        kthornvolley = K("Thorn Volley", "NATURE", "payoff", { power = 50, cd = 3, payoff = { mark = "rooted", mult = 1.8 } }),
        kovergrowth = Cast("Overgrowth", "NATURE", "growing"),
        kbarkskin   = Guard("Barkskin", "NATURE"),
        kregrowth   = K("Regrowth", "NATURE", "heal", { heal = 0.2, cd = 5, mark = { id = "regrowth", turns = 3, who = "self" } }),
        -- SHADOW (physical)
        kshadowbite = K("Shadow Bite", "SHADOW", "filler", { power = 40 }),
        kcorruption = K("Corruption", "SHADOW", "setup", { power = 10, cd = 3, mark = { id = "corrupt", turns = 4 } }),
        kdeathcoil  = K("Death Coil", "SHADOW", "payoff", { power = 50, cd = 3, payoff = { mark = "corrupt", mult = 1.6 },
                                                            effect = { kind = "drain", pct = 50 } }),
        kshadowbolt = Cast("Shadow Bolt", "SHADOW"),
        kbonearmor  = Guard("Bone Armor", "SHADOW"),
        kspelllock  = Int("Spell Lock", "SHADOW"),
        -- EARTH (physical): Crush Armor's Defense drop is the setup, every hit after it the payoff
        -- (thrown rocks reach fliers: resisted instead of no effect, so Earth is never walled off by Air)
        krockthrow  = K("Rock Throw", "EARTH", "filler", { power = 40, noImmune = true }),
        kcrusharmor = K("Crush Armor", "EARTH", "setup", { power = 25, cd = 2, effect = { kind = "stat", who = "foe", stat = "def", stages = -1 } }),
        kboulder    = K("Boulder Toss", "EARTH", "payoff", { power = 65, cd = 3, noImmune = true }),
        kearthquake = Cast("Earthquake", "EARTH", "rumbling into"),
        kstoneskin  = Guard("Stoneskin", "EARTH"),
        kwarstomp   = Int("War Stomp", "EARTH"),
        -- AIR (physical)
        kdive       = K("Dive", "AIR", "filler", { power = 40 }),
        khuntersmark = K("Hunter's Mark", "AIR", "setup", { power = 10, cd = 3, mark = { id = "exposed", turns = 3 } }),
        ktalonrake  = K("Talon Rake", "AIR", "payoff", { power = 50, cd = 3, payoff = { mark = "exposed", mult = 1.8 } }),
        ktempest    = Cast("Tempest", "AIR", "whipping up"),
        kwindwall   = Guard("Wind Wall", "AIR"),
        kscreech    = Int("Screech", "AIR"),
        -- MECH (physical): charges itself, then spends the charge
        kgears      = K("Grinding Gears", "MECH", "filler", { power = 40 }),
        kchargeup   = K("Charge Up", "MECH", "setup", { power = 10, cd = 3, mark = { id = "charged", turns = 3, who = "self" } }),
        krocketpunch = K("Rocket Punch", "MECH", "payoff", { power = 50, cd = 3, payoff = { mark = "charged", self = true, mult = 1.8, consume = true } }),
        ksawstorm   = Cast("Sawblade Storm", "MECH", "spinning up"),
        kdeflector  = Guard("Deflector Shield", "MECH"),
        kshock      = Int("Electroshock", "MECH"),
    }
    for id, mv in pairs(kit) do D.moves[id] = mv end
    -- the six roles of each type, and the level each is learned at (filler, setup, payoff, cast, guard, interrupt)
    D.TYPE_KIT = {
        BEAST  = { "kclaw", "krend", "kferobite", "kmaul", "khide", "kskullbash" },
        FIRE   = { "kscorch", "kimmolate", "kincinerate", "kpyroblast", "kfireward", "kcounterspell" },
        WATER  = { "kwaterbolt", "kfrostshock", "kicelance", "ktidalwave", "kshellshield", "kwindshear" },
        NATURE = { "kthorns", "kroots", "kthornvolley", "kovergrowth", "kbarkskin", "kregrowth" },
        SHADOW = { "kshadowbite", "kcorruption", "kdeathcoil", "kshadowbolt", "kbonearmor", "kspelllock" },
        EARTH  = { "krockthrow", "kcrusharmor", "kboulder", "kearthquake", "kstoneskin", "kwarstomp" },
        AIR    = { "kdive", "khuntersmark", "ktalonrake", "ktempest", "kwindwall", "kscreech" },
        MECH   = { "kgears", "kchargeup", "krocketpunch", "ksawstorm", "kdeflector", "kshock" },
    }
    D.KIT_LEVELS = { 1, 1, 7, 25, 13, 19 }

    -- Bosses bring five moves: their type's filler, setup and payoff, a signature cast that can't be interrupted
    -- (guard it) and a cast that must be interrupted (a heal, or a rally that sharply raises their Attack).
    local HEAL = { BEAST = "Lick Wounds", FIRE = "Cauterize", WATER = "Healing Tide", NATURE = "Rejuvenation",
                   SHADOW = "Dark Mending", EARTH = "Stoneform", AIR = "Second Wind", MECH = "Field Repairs" }
    local SIG = {           -- [boss] = { cast name, verb, second cast name, "rally" = an Attack rally instead of a heal }
        hogger    = { "Hogger Smash", "winding up", "Gnaw Bone" },
        vancleef  = { "Blade Flurry", "readying", "Rally the Brotherhood", "rally" },
        stitches  = { "Crushing Slam", "raising its arms for", "Stitch Flesh" },
        mukla     = { "Earthquake", "rumbling into", "Chest Beat", "rally" },
        smite     = { "Smite Stomp", "winding up", "Smite's Hammer", "rally" },
        firallon  = { "Broadside", "loading a", "Rally the Crew", "rally" },
        bangalash = { "Feral Rage", "working up a", "Lick Wounds" },
        rhahkzor  = { "Ogre Slam", "winding up", "Bellow", "rally" },
    }
    for id, s in pairs(D.species) do
        if s.boss then
            local best, bp
            for _, e in ipairs(s.learn) do
                local mv = D.moves[e[2]]
                if mv and (mv.power or 0) > (bp or -1) then best, bp = mv, mv.power end
            end
            local sig = SIG[id] or {}
            local castId, secondId = "bcast_" .. id, "bsecond_" .. id
            D.moves[castId] = K(sig[1] or (best and best.name) or "Crushing Blow", s.type, "nuke",
                { power = 130, acc = 95, cd = 3, cast = true, unstoppable = true, castVerb = sig[2] or "winding up", pp = 10 })
            if sig[4] == "rally" then
                D.moves[secondId] = K(sig[3], s.type, "buff", { cd = 4, cast = true, castVerb = "shouting",
                    effect = { kind = "stat", who = "self", stat = "atk", stages = 2 }, pp = 10 })
            else
                D.moves[secondId] = K(sig[3] or HEAL[s.type] or "Second Wind", s.type, "heal",
                    { heal = 0.25, cd = 4, cast = true, castVerb = "mending with", pp = 10 })
            end
            local tk = D.TYPE_KIT[s.type]
            s.kit = { tk[1], tk[2], tk[3], castId, secondId }
        end
    end
    -- Signatures: a species keeps its own best moves from before 0.36, folded into the roles so the numbers hold.
    -- Its strongest big hit (power 85+) becomes its own cast (power 100, like the kit's), its best other hit (50+)
    -- its own filler (power 45, the kit's is 40); each keeps its old name, type, accuracy and effect, and comes at
    -- its old level, so beasts keep learning late. A hit of another type than the beast's gets x1.5 (60 / 150): it
    -- lacks the same-type bonus, so it trades evenly in a neutral fight and is there for its coverage. Like the
    -- kit's Rock Throw, an Earth hit still reaches fliers (noImmune), or Earth and Air beasts stall each other.
    local kitName = {}
    for _, mv in pairs(kit) do kitName[mv.name] = true end
    local function Sig(s)
        local cast, hit
        for _, e in ipairs(s.learn) do
            local mv = D.moves[e[2]]
            if mv and not mv.role and (mv.power or 0) >= 85 and not kitName[mv.name]
               and (not cast or mv.power >= cast.mv.power) then cast = { lvl = e[1], id = e[2], mv = mv } end
        end
        for _, e in ipairs(s.learn) do
            local mv = D.moves[e[2]]
            if mv and not mv.role and (mv.power or 0) >= 50 and not kitName[mv.name] and not (cast and cast.id == e[2])
               and (not hit or mv.power >= hit.mv.power) then hit = { lvl = e[1], id = e[2], mv = mv } end
        end
        local out = {}
        if hit then
            local own = hit.mv.type == s.type
            local id = (own and "sf_" or "sfx_") .. hit.id
            D.moves[id] = D.moves[id] or K(hit.mv.name, hit.mv.type, "filler", { power = own and 45 or 60, acc = hit.mv.acc,
                effect = hit.mv.effect, noImmune = kit[D.TYPE_KIT[hit.mv.type][1]].noImmune, sig = true })
            out[#out + 1] = { hit.lvl, id }
        end
        if cast then
            local own = cast.mv.type == s.type
            local id = (own and "sc_" or "scx_") .. cast.id
            local physical = D.types[cast.mv.type] and D.types[cast.mv.type].physical
            D.moves[id] = D.moves[id] or K(cast.mv.name, cast.mv.type, "nuke", { power = own and 100 or 150, cd = 3, cast = true,
                acc = (cast.mv.acc or 0) > 0 and math.min(95, cast.mv.acc) or 95, castVerb = physical and "winding up" or nil,
                effect = cast.mv.effect, noImmune = kit[D.TYPE_KIT[cast.mv.type][1]].noImmune, sig = true })
            out[#out + 1] = { cast.lvl, id }
        end
        return out
    end

    -- learnsets: every beast learns its type's kit and its signatures (bosses: their five moves at level 1)
    for _, s in pairs(D.species) do
        if s.kit then
            s.learn = {}
            for i, mv in ipairs(s.kit) do s.learn[i] = { 1, mv } end
        elseif D.TYPE_KIT[s.type] then
            local order = {}
            for i, mv in ipairs(D.TYPE_KIT[s.type]) do order[#order + 1] = { D.KIT_LEVELS[i], mv, i } end
            for i, e in ipairs(Sig(s)) do order[#order + 1] = { e[1], e[2], 6 + i } end
            table.sort(order, function(a, b) if a[1] ~= b[1] then return a[1] < b[1] end return a[3] < b[3] end)
            s.learn = {}
            for i, e in ipairs(order) do s.learn[i] = { e[1], e[2] } end
        end
    end
end

-- CDLoot Games/Azeromon/Data.lua
-- ns.AzeroData: static game data for Azeromon (a monster-taming game in the Pokemon style, WoW themed).
-- Types, the type chart, moves, species (3D creature displays for battle), items, trainers and text.
-- Mechanics follow Generation III: physical / special split by type, stat stages, 1/16 crits, STAB.
local addonName, ns = ...

local D = {}
ns.AzeroData = D

D.SAVE_VERSION = 1
D.MAX_PARTY = 6
D.MAX_LEVEL = 50
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
}

---------------------------------------------------------------------------
-- Species. base = { hp, atk, def, spa, spd, spe }. display = creature display ID, verified on Wowhead TBC
-- (npc -> displayId): Red Whelp 1042 -> 9583, Murloc Raider 515 -> 441, Bloodpetal Lasher 6509 -> 11634,
-- Bloodpetal Flayer 6510 -> 11635, Young Wolf 299 -> 447, Forest Spider 30 -> 382, Kobold Vermin 6 -> 10913,
-- Strigid Owl 1995 -> 10832, Stonetusk Boar 113 -> 503.
-- learn = { { level, move }, ... }   evolve = { level = n, into = id }   catch = catch rate (3..255)
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
        learn = { { 1, "tackle" }, { 1, "growl" }, { 7, "leech" }, { 10, "thornwhip" }, { 13, "stunspore" },
                  { 16, "razorpetal" } } },
    wolfpup = { name = "Wolfpup", type = "BEAST", num = 5, display = 447, catch = 190, exp = 55,
        base = { 40, 56, 35, 30, 35, 70 },
        desc = "A young Elwynn wolf. The Stormwind Guard pays a bounty for their paws, but tamed ones are loyal for life.",
        learn = { { 1, "tackle" }, { 1, "growl" }, { 5, "quickbite" }, { 11, "bite" } } },
    webling = { name = "Webling", type = "SHADOW", num = 6, display = 382, catch = 190, exp = 52,
        base = { 40, 50, 40, 35, 40, 45 },
        desc = "A forest spider from the woods around Goldshire. It strings webs between the tall grass stalks.",
        learn = { { 1, "venomsting" }, { 1, "web" }, { 9, "bite" } } },
    kobling = { name = "Kobling", type = "EARTH", num = 7, display = 10913, catch = 190, exp = 58,
        base = { 45, 55, 50, 25, 35, 35 },
        desc = "A kobold runt from Fargodeep Mine. You no take candle! It hoards anything that glitters.",
        evolve = { level = 16, into = "tunneler" },
        learn = { { 1, "scratch" }, { 1, "mudslap" }, { 8, "rockthrow" }, { 12, "leer" } } },
    owlet = { name = "Owlet", type = "AIR", num = 8, display = 10832, cam = 1.4, catch = 255, exp = 50,
        base = { 40, 45, 40, 35, 35, 56 },
        desc = "A strigid owl chick from Teldrassil, far from home. Night elf druids say its hooting brings sleep.",
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
        learn = { { 1, "tackle" }, { 1, "leer" }, { 7, "waterjet" }, { 10, "bite" }, { 16, "bubblebeam" },
                  { 20, "tidal" } } },
    goretusk = { name = "Goretusk", type = "BEAST", num = 11, display = 3027, catch = 90, exp = 138,
        base = { 75, 84, 70, 30, 45, 55 },
        desc = "A grown boar of the Westfall plains. Farmers say a goretusk can plough a field faster than a horse, badly.",
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
        learn = { { 1, "peck" }, { 1, "leer" }, { 8, "gust" }, { 12, "carrion" }, { 16, "whirlwind" } } },
    rustgolem = { name = "Rusty Harvest Golem", type = "MECH", num = 19, display = 514, catch = 120, exp = 75,
        base = { 60, 66, 75, 30, 40, 30 },
        desc = "A gnomish harvest golem left to rust. The Defias reprogrammed the working ones to guard their fields.",
        evolve = { level = 18, into = "reaper" },
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" } } },
    reaper = { name = "Harvest Reaper", type = "MECH", num = 20, display = 379, catch = 45, exp = 160,
        base = { 80, 92, 100, 35, 55, 40 },
        desc = "A harvest golem rebuilt for war. Its scythes were meant for wheat.",
        learn = { { 1, "tackle" }, { 1, "rust" }, { 8, "gears" }, { 14, "scythe" }, { 22, "maul" } } },
    dustdevil = { name = "Dust Devil", type = "AIR", num = 21, display = 5327, cam = 1.3, catch = 90, exp = 80,
        base = { 55, 50, 50, 70, 55, 80 },
        desc = "A whirl of Westfall dust that never quite settles. The drought feeds them.",
        learn = { { 1, "gust" }, { 1, "mudslap" }, { 8, "sandblast" }, { 14, "whirlwind" } } },
    crawler = { name = "Shore Crawler", type = "WATER", num = 22, display = 9570, catch = 190, exp = 58,
        base = { 45, 55, 70, 35, 45, 35 },
        desc = "A crab of the Westfall coast. It pinches anything that stands still long enough.",
        evolve = { level = 18, into = "sandcrawler" },
        learn = { { 1, "tackle" }, { 1, "shell" }, { 7, "pincer" }, { 12, "bubblebeam" } } },
    sandcrawler = { name = "Sand Crawler", type = "WATER", num = 23, display = 342, catch = 60, exp = 140,
        base = { 65, 78, 100, 45, 60, 40 },
        desc = "An old crawler with a shell like a shield. Longshore fishermen use their claws as hooks.",
        learn = { { 1, "tackle" }, { 1, "shell" }, { 7, "pincer" }, { 12, "bubblebeam" }, { 20, "tidal" } } },
    coastrunner = { name = "Coastrunner", type = "WATER", num = 24, display = 983, catch = 150, exp = 64,
        base = { 48, 58, 50, 48, 50, 62 },
        desc = "A Westfall murloc scout. Mrrrgl! It runs up and down the Longshore warning the others.",
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
    webling = 4457,                               -- a magma tarantula
    minespider = 4456,                            -- crystal spider
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
D.items.illusiondust = { name = "Illusion Dust", price = 0, use = "charm", minutes = 30,
    icon = "Interface\\Icons\\INV_Enchant_DustIllusion",
    desc = "Scatter it and the air glimmers: for 30 minutes, shiny beasts are twice as likely.",
    used = "You scatter the Illusion Dust. The air glimmers...\nFor 30 minutes, shiny beasts are twice as likely." }
D.itemOrder = { "potion", "superpotion", "antidote", "net", "greatnet", "illusiondust" }
D.shopStock = { "net", "potion", "antidote", "greatnet", "superpotion" }

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

    militia1 = { name = "Militia Sergeant Dane", class = "militia", prize = 45,
                 team = { { "packleader", 14 }, { "reaper", 14 } },
                 intro = "Gryan Stoutmantle trained me himself. Show me what Elwynn's tamers are made of!",
                 lose = "Stoutmantle will want to meet you. Go on up to Sentinel Hill." },
}

---------------------------------------------------------------------------
-- Badges (from gym-leader style bosses)
---------------------------------------------------------------------------

D.badges = {
    hogger = { name = "Hogger's Claw", order = 1,
               text = "Proof that you bested the terror of Elwynn. Deputy Rainer will let you through to Westfall now." },
    vancleef = { name = "VanCleef's Bandana", order = 2,
                 text = "The red bandana of the Defias Brotherhood's leader. Gryan Stoutmantle will want to see this." },
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
-- roams an Azeromon area for `hours`. `boss` is the key in CDLoot's raid data (Data/Items.lua), which also gives
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
}

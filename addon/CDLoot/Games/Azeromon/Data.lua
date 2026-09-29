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
        learn = { { 1, "scratch" }, { 1, "growl" }, { 7, "ember" }, { 10, "leer" }, { 16, "flamebreath" } } },
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
    hogger = { name = "Hogger", type = "BEAST", num = 15, display = 384, cam = 0.85, catch = 3, exp = 200,
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
D.itemOrder = { "potion", "superpotion", "antidote", "net", "greatnet" }
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
}

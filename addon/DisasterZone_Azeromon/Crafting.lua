if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/Crafting.lua", ...) then return end -- DisasterZone_Azeromon/Crafting.lua
-- ns.AzeroCraft: professions, like the real ones.
--   Gathering: Herbalism and Mining. Herb and ore nodes stand on the maps (def.nodes); A on one gathers it, and it
--              grows back RESPAWN seconds later (per player, on realm time) - sometimes as another herb of the map.
--   Crafting:  Alchemy (anywhere), Mining's Smelting (at a forge) and Blacksmithing (at an anvil), from recipes.
--   Gear:      Blacksmithing makes gear a beast wears, one piece per slot (D.gearSlots: claws, shoulders, chest,
--              wrists, waist); Alchemy makes elixirs (a stat up in battle), potions and flasks (a bonus for the
--              beast's next battles, shown as a sixth slot).
-- Skill runs 1 - D.SKILL_MAX, in tiers like the real trainers: Apprentice to 100 (Goldshire), Journeyman to 150
-- (Verner Osgood, Lakeshire) and Expert to 175 (Hansel Heavyhands, Thorium Point); C.Cap(prof) is the player's.
-- Beasts drop materials after won wild battles (D.beastDrops). A node or recipe is orange (always a skill-up) until 10 points past its level, yellow
-- (75%) until 20, green (25%) until 35, then grey (nothing) - the real game's colours.
-- Everything below is data: add a herb, a recipe or a piece of gear by adding a line.
local addonName, ns = ...

local C = ns:NewModule("AzeroCraft")
local G = ns.Azero
local D = ns.AzeroData
local M = ns.AzeroMon

local ICON = "Interface\\Icons\\"

---------------------------------------------------------------------------
-- Data: professions, trainers, resources
---------------------------------------------------------------------------

D.SKILL_MAX = 175
D.PROFESSION_FEE = 50
-- Tiers: what each lets a skill climb to, the skill needed to learn it, the fee, and who teaches it.
D.skillTiers = {
    { id = "apprentice", name = "Apprentice", cap = 100 },
    { id = "journeyman", name = "Journeyman", cap = 150, needs = 75, fee = 500, trainer = "Verner Osgood" },
    { id = "expert", name = "Expert", cap = 175, needs = 125, fee = 1500, trainer = "Hansel Heavyhands" },
}
D.MAX_PROFESSIONS = 2          -- like the real game: forget one to learn another

D.professions = {
    herbalism = { name = "Herbalism", icon = ICON .. "Trade_Herbalism", gather = "herb", trainer = "Alchemist Mallory",
                  howto = "Herbs grow wild on the roads out of town. Face one, or stand on it, and press Space to pick it." },
    alchemy = { name = "Alchemy", icon = ICON .. "Trade_Alchemy", trainer = "Alchemist Mallory",
                howto = "Brew from PROFESSIONS in the menu, wherever you are." },
    mining = { name = "Mining", icon = ICON .. "Trade_Mining", gather = "ore", trainer = "Smith Argus",
               howto = "Face an ore vein (a rock with coloured specks) and press Space to mine it. Smelt the ore into bars at a forge." },
    blacksmithing = { name = "Blacksmithing", icon = ICON .. "Trade_BlackSmithing", trainer = "Smith Argus",
                      howto = "Work your bars into gear for your beasts at an anvil." },
}
D.professionOrder = { "herbalism", "alchemy", "mining", "blacksmithing" }

D.craftTrainers = {
    -- the tier trainers (G:ProfessionTrainer): they also teach any trade from scratch, like Argus and Mallory
    journeyman = { name = "Verner Osgood", tier = "journeyman",
                   teaches = { "herbalism", "alchemy", "mining", "blacksmithing" },
                   hello = "Copper and tin? That's apprentice work. I teach Journeyman, up to 150.",
                   done = "You know all I can teach. For Expert, see the Thorium Brotherhood in the Searing Gorge." },
    expert = { name = "Hansel Heavyhands", tier = "expert",
               teaches = { "herbalism", "alchemy", "mining", "blacksmithing" },
               hello = "The Thorium Brotherhood teaches Expert, up to 175. Dark Iron needs the Black Forge inside the mountain.",
               done = "You know all I can teach. Go dig some Dark Iron." },
    argus = { name = "Smith Argus", teaches = { "mining", "blacksmithing" },
              hello = "Copper from the hills, fire from the forge. Every tamer's beast deserves a good bit of armour.",
              done = "You know all I can teach. The rest is hammer and patience." },
    mallory = { name = "Alchemist Mallory", teaches = { "herbalism", "alchemy" },
                hello = "Peacebloom, Silverleaf, a steady hand... that's half of alchemy. The other half is not blowing up.",
                done = "You know all I can teach. Go on, practise - and mind your eyebrows." },
}

-- kind, the skill a node needs, what one gives (item = the resource's own id unless set), and a sometimes-extra
D.resources = {
    peacebloom = { name = "Peacebloom", kind = "herb", skill = 1, yield = { 1, 2 }, tile = "node_peacebloom" },
    silverleaf = { name = "Silverleaf", kind = "herb", skill = 1, yield = { 1, 3 }, tile = "node_silverleaf" },
    earthroot = { name = "Earthroot", kind = "herb", skill = 15, yield = { 1, 2 }, tile = "node_earthroot" },
    mageroyal = { name = "Mageroyal", kind = "herb", skill = 50, yield = { 1, 2 }, tile = "node_mageroyal" },
    briarthorn = { name = "Briarthorn", kind = "herb", skill = 70, yield = { 1, 2 }, tile = "node_briarthorn" },
    -- Blackrock (the world half puts node_<id> tiles on its maps)
    iron = { name = "Iron Deposit", kind = "ore", skill = 100, yield = { 1, 2 }, item = "ironore",
             extra = { item = "heavystone", chance = 50 }, tile = "node_iron" },
    gold = { name = "Gold Vein", kind = "ore", skill = 115, yield = { 1, 2 }, item = "goldore", tile = "node_gold" },
    mithril = { name = "Mithril Deposit", kind = "ore", skill = 125, yield = { 1, 2 }, item = "mithrilore",
                extra = { item = "heavystone", chance = 30 }, tile = "node_mithril" },
    truesilver = { name = "Truesilver Deposit", kind = "ore", skill = 150, yield = { 1, 2 }, item = "truesilverore",
                   tile = "node_truesilver" },
    darkiron = { name = "Dark Iron Deposit", kind = "ore", skill = 160, yield = { 2, 4 }, item = "darkironore",
                 tile = "node_darkiron" },
    fadeleaf = { name = "Fadeleaf", kind = "herb", skill = 100, yield = { 1, 2 }, tile = "node_fadeleaf" },
    kingsblood = { name = "Kingsblood", kind = "herb", skill = 110, yield = { 1, 2 }, tile = "node_kingsblood" },
    firebloom = { name = "Firebloom", kind = "herb", skill = 140, yield = { 1, 2 }, tile = "node_firebloom" },
    sungrass = { name = "Sungrass", kind = "herb", skill = 150, yield = { 1, 2 }, tile = "node_sungrass" },
    copper = { name = "Copper Vein", kind = "ore", skill = 1, yield = { 1, 3 }, item = "copperore",
               extra = { item = "roughstone", chance = 50 }, tile = "node_copper" },
    tin = { name = "Tin Vein", kind = "ore", skill = 50, yield = { 1, 2 }, item = "tinore",
            extra = { item = "coarsestone", chance = 50 }, tile = "node_tin" },
}

---------------------------------------------------------------------------
-- Data: items (icons from Wowhead TBC)
---------------------------------------------------------------------------

-- The gear slots, in the fixed order bonuses are applied (the same on every client: player battles).
-- inv = the character sheet's slot whose empty icon the gear page shows.
D.gearSlots = {
    { id = "claws", name = "Claws", inv = "MainHandSlot", fallback = "MainHand" },
    { id = "shoulders", name = "Shoulders", inv = "ShoulderSlot", fallback = "Shoulder" },
    { id = "chest", name = "Chest", inv = "ChestSlot", fallback = "Chest" },
    { id = "wrists", name = "Wrists", inv = "WristSlot", fallback = "Wrists" },
    { id = "waist", name = "Waist", inv = "WaistSlot", fallback = "Waist" },
}

local function Mat(name, icon, desc) return { name = name, price = 0, use = "material", icon = ICON .. icon, desc = desc } end

local items = {
    -- herbs, ore, stone, bars
    peacebloom = Mat("Peacebloom", "INV_Misc_Flower_02", "A common flower of Elwynn. Alchemists use it in healing potions."),
    silverleaf = Mat("Silverleaf", "INV_Misc_Herb_10", "A pale herb found almost everywhere. Every alchemist's first ingredient."),
    earthroot = Mat("Earthroot", "INV_Misc_Herb_07", "A thick root that grows near stones. Brewed for strength."),
    mageroyal = Mat("Mageroyal", "INV_Jewelry_Talisman_03", "A violet flower of Westfall, prized for restoring potions."),
    briarthorn = Mat("Briarthorn", "INV_Misc_Root_01", "A thorny bramble. Stronger potions need it."),
    copperore = Mat("Copper Ore", "INV_Ore_Copper_01", "Smelt it at a forge into Copper Bars."),
    tinore = Mat("Tin Ore", "INV_Ore_Tin_01", "Smelt it at a forge into Tin Bars."),
    roughstone = Mat("Rough Stone", "INV_Stone_06", "Found while mining copper. Blacksmiths grind it into sharpening stones."),
    coarsestone = Mat("Coarse Stone", "INV_Stone_09", "Found while mining tin. Harder than Rough Stone."),
    copperbar = Mat("Copper Bar", "INV_Ingot_02", "Blacksmiths work it into gear at an anvil."),
    tinbar = Mat("Tin Bar", "INV_Ingot_05", "Smelted with copper into Bronze."),
    bronzebar = Mat("Bronze Bar", "INV_Ingot_Bronze", "Copper and tin together: stronger gear."),

    -- Blackrock: ore, bars, herbs, and what beasts drop
    ironore = Mat("Iron Ore", "INV_Ore_Iron_01", "Smelt it at a forge into Iron Bars."),
    goldore = Mat("Gold Ore", "INV_Ore_Copper_01", "Smelt it at a forge into Gold Bars."),
    mithrilore = Mat("Mithril Ore", "INV_Ore_Mithril_02", "Smelt it at a forge into Mithril Bars."),
    truesilverore = Mat("Truesilver Ore", "INV_Ore_TrueSilver_01", "Smelt it at a forge into Truesilver Bars."),
    darkironore = Mat("Dark Iron Ore", "INV_Ore_Mithril_01", "Only the Black Forge in Blackrock Mountain is hot enough to smelt it: eight ores a bar."),
    heavystone = Mat("Heavy Stone", "INV_Stone_04", "Found while mining iron. Blacksmiths grind it into heavy sharpening stones."),
    ironbar = Mat("Iron Bar", "INV_Ingot_Iron", "Blacksmiths work it into gear at an anvil."),
    steelbar = Mat("Steel Bar", "INV_Ingot_Steel", "Iron and heavy stone, smelted hard."),
    goldbar = Mat("Gold Bar", "INV_Ingot_03", "Soft, but it makes fine scales."),
    mithrilbar = Mat("Mithril Bar", "INV_Ingot_06", "Light and strong: the best armour in the Steppes."),
    truesilverbar = Mat("Truesilver Bar", "INV_Ingot_08", "Prized by the Thorium Brotherhood."),
    fadeleaf = Mat("Fadeleaf", "INV_Misc_Herb_12", "A pale leaf of Redridge that fades when you look away."),
    kingsblood = Mat("Kingsblood", "INV_Misc_Herb_03", "A red herb of Redridge. Healing potions want it."),
    firebloom = Mat("Firebloom", "INV_Misc_Herb_19", "It grows where the ground is hot. Fire elixirs need it."),
    sungrass = Mat("Sungrass", "INV_Misc_Herb_18", "A golden grass of the Steppes. Elixirs of Agility need it."),
    blackdragonscale = Mat("Black Dragonscale", "INV_Misc_MonsterScales_10", "Shed by the black flight's whelps and wyrmkin."),
    elementalfire = Mat("Elemental Fire", "INV_Elemental_Primal_Fire", "A flame that won't go out, left by fire elementals and flamekin."),
    elementalearth = Mat("Elemental Earth", "INV_Elemental_Primal_Earth", "A stone that hums, left by magma and obsidian elementals."),
    heartoffire = Mat("Heart of Fire", "Spell_Fire_Fire", "The core of an Inferno Elemental. The Black Forge's smiths pay well for it."),
    coreleather = Mat("Core Leather", "INV_Misc_LeatherScrap_02", "A Core Hound's hide. It stays warm for years."),
    fierycore = Mat("Fiery Core", "Spell_Fire_Incinerate", "A heart of the Molten Core's fire. Collectors in Ironforge would kill for one."),
    -- the Dark Iron Bar: a material, and used on a Harvest Watcher it evolves it into a Heavy War Golem
    darkironbar = { name = "Dark Iron Bar", price = 0, use = "evolve", icon = ICON .. "INV_Ingot_Mithril",
                    desc = "Smelted at the Black Forge. Blacksmiths' best metal; use it on a Harvest Watcher and it rebuilds itself as a Heavy War Golem." },

    -- elixirs: in battle, one stat up a stage for the beast fighting
    lionsstrength = { name = "Elixir of Lion's Strength", price = 0, use = "boost", stat = "atk", icon = ICON .. "INV_Potion_56",
                      desc = "In battle: raises your beast's Attack." },
    minordefense = { name = "Elixir of Minor Defense", price = 0, use = "boost", stat = "def", icon = ICON .. "INV_Potion_63",
                     desc = "In battle: raises your beast's Defense." },
    lesseragility = { name = "Elixir of Lesser Agility", price = 0, use = "boost", stat = "spe", icon = ICON .. "INV_Potion_92",
                      desc = "In battle: raises your beast's Speed." },
    rejuv = { name = "Minor Rejuvenation Potion", price = 0, use = "rejuv", heal = 40, icon = ICON .. "INV_Potion_02",
              desc = "Restores 40 HP and cures poison, burns, paralysis and sleep." },
    elixirfirepower = { name = "Elixir of Firepower", price = 0, use = "boost", stat = "spa", typeStages = { FIRE = 2 },
                        icon = ICON .. "INV_Potion_33",
                        desc = "In battle: raises your beast's Sp. Atk (two stages for a Fire beast)." },
    elixiragility = { name = "Elixir of Agility", price = 0, use = "boost", stat = "spe", stages = 2, icon = ICON .. "INV_Potion_93",
                      desc = "In battle: sharply raises your beast's Speed." },
    freeaction = { name = "Free Action Potion", price = 0, use = "freeaction", icon = ICON .. "INV_Potion_04",
                   desc = "Cures paralysis. In battle, the beast that drinks it can't be panicked." },
    -- flasks with a type: resist = damage taken from that type, typePower = damage dealt with it
    fireprotection = { name = "Fire Protection Potion", price = 1500, sell = 300, use = "flask", battles = 5,
                       resist = { FIRE = 0.7 }, icon = ICON .. "INV_Potion_24",
                       desc = "Fire damage to the beast -30% for its next 5 battles (takes the flask slot)." },
    flaskflowing = { name = "Flask of Flowing Water", price = 0, use = "flask", battles = 10, bonus = { hp = 1.2 },
                     typePower = { WATER = 1.1 }, icon = ICON .. "INV_Potion_43",
                     desc = "+20% max HP and Water moves +10% for the beast's next 10 battles." },
    -- flasks: a bonus for the beast's next `battles` battles (never in battles between players)
    flasktitans = { name = "Flask of the Titans", price = 0, use = "flask", battles = 10, bonus = { hp = 1.2 },
                    icon = ICON .. "INV_Potion_62", desc = "+20% max HP for the beast's next 10 battles." },
    flasksupreme = { name = "Flask of Supreme Power", price = 0, use = "flask", battles = 10, bonus = { spa = 1.2 },
                     icon = ICON .. "INV_Potion_41", desc = "+20% Sp. Atk for the beast's next 10 battles." },
    flaskassault = { name = "Flask of Relentless Assault", price = 0, use = "flask", battles = 10, bonus = { atk = 1.2 },
                     icon = ICON .. "INV_Potion_117", desc = "+20% Attack for the beast's next 10 battles." },

    -- gear: one piece per beast
    roughsharpening = { name = "Rough Sharpening Stone", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.1 },
                        icon = ICON .. "INV_Stone_SharpeningStone_01", desc = "Gear: sharpened claws, +10% Attack." },
    copperchainbelt = { name = "Copper Chain Belt", price = 0, use = "gear", slot = "waist", bonus = { spe = 1.1 },
                        icon = ICON .. "INV_Belt_02", desc = "Gear: +10% Speed." },
    runedcopperbracers = { name = "Runed Copper Bracers", price = 0, use = "gear", slot = "wrists", bonus = { spa = 1.1 },
                           icon = ICON .. "INV_Bracer_03", desc = "Gear: +10% Sp. Atk." },
    copperchainvest = { name = "Copper Chain Vest", price = 0, use = "gear", slot = "chest", bonus = { def = 1.1, spd = 1.1 },
                        icon = ICON .. "INV_Chest_Chain", desc = "Gear: +10% Defense and Sp. Def." },
    coarsesharpening = { name = "Coarse Sharpening Stone", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.2 },
                         icon = ICON .. "INV_Stone_SharpeningStone_02", desc = "Gear: +20% Attack." },
    roughbronzeshoulders = { name = "Rough Bronze Shoulders", price = 0, use = "gear", slot = "shoulders",
                             bonus = { def = 1.15, spd = 1.15 },
                             icon = ICON .. "INV_Shoulder_05", desc = "Gear: +15% Defense and Sp. Def." },
    patternedbronzebracers = { name = "Patterned Bronze Bracers", price = 0, use = "gear", slot = "wrists",
                               bonus = { spa = 1.15, spe = 1.15 },
                               icon = ICON .. "INV_Bracer_07", desc = "Gear: +15% Sp. Atk and Speed." },
    -- Blackrock gear. regen = heals 1/regen of max HP a turn; stun = % a hit makes the foe flinch; resist as flasks
    heavysharpening = { name = "Heavy Sharpening Stone", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.3 },
                        icon = ICON .. "INV_Stone_SharpeningStone_03", desc = "Gear: +30% Attack." },
    greenironbracers = { name = "Green Iron Bracers", price = 0, use = "gear", slot = "wrists", bonus = { spa = 1.2, spe = 1.1 },
                         icon = ICON .. "INV_Bracer_02", desc = "Gear: +20% Sp. Atk and +10% Speed." },
    goldenscaleshoulders = { name = "Golden Scale Shoulders", price = 0, use = "gear", slot = "shoulders",
                             bonus = { def = 1.2, spd = 1.2 },
                             icon = ICON .. "INV_Shoulder_25", desc = "Gear: +20% Defense and Sp. Def." },
    mithrilscaleshoulders = { name = "Mithril Scale Shoulders", price = 0, use = "gear", slot = "shoulders",
                              bonus = { def = 1.3, spd = 1.25 },
                              icon = ICON .. "INV_Shoulder_08", desc = "Gear: +30% Defense and +25% Sp. Def." },
    truesilverbreastplate = { name = "Truesilver Breastplate", price = 0, use = "gear", slot = "chest",
                              bonus = { def = 1.3, spd = 1.3 }, regen = 16,
                              icon = ICON .. "INV_Chest_Plate07", desc = "Gear: +30% Defense and Sp. Def; heals 1/16 of max HP every turn." },
    fierychaingirdle = { name = "Fiery Chain Girdle", price = 0, use = "gear", slot = "waist", bonus = { spe = 1.15 },
                         resist = { FIRE = 0.75 },
                         icon = ICON .. "INV_Belt_18", desc = "Gear: +15% Speed; fire damage to the beast -25%." },
    darkironpulverizer = { name = "Dark Iron Pulverizer", price = 0, use = "gear", slot = "claws", bonus = { atk = 1.45 },
                           stun = 10,
                           icon = ICON .. "INV_Hammer_19", desc = "Gear: +45% Attack; a hit stuns the foe (it loses its move) 10% of the time." },
}
local ORDER = { "rejuv", "lionsstrength", "minordefense", "lesseragility", "flasktitans", "flasksupreme", "flaskassault",
                "roughsharpening", "copperchainbelt", "runedcopperbracers", "copperchainvest", "coarsesharpening",
                "roughbronzeshoulders", "patternedbronzebracers",
                "peacebloom", "silverleaf", "earthroot", "mageroyal", "briarthorn",
                "copperore", "tinore", "roughstone", "coarsestone", "copperbar", "tinbar", "bronzebar",
                -- Blackrock
                "elixirfirepower", "elixiragility", "freeaction", "fireprotection", "flaskflowing",
                "heavysharpening", "greenironbracers", "goldenscaleshoulders", "mithrilscaleshoulders",
                "truesilverbreastplate", "fierychaingirdle", "darkironpulverizer",
                "fadeleaf", "kingsblood", "firebloom", "sungrass",
                "ironore", "goldore", "mithrilore", "truesilverore", "darkironore", "heavystone",
                "ironbar", "steelbar", "goldbar", "mithrilbar", "truesilverbar", "darkironbar",
                "blackdragonscale", "elementalfire", "elementalearth", "heartoffire", "coreleather", "fierycore" }
-- what a shop pays (copper each); bought goods sell for half their price
local SELL = {
    peacebloom = 12,
    silverleaf = 10,
    earthroot = 15,
    mageroyal = 30,
    briarthorn = 35,
    copperore = 15,
    tinore = 30,
    roughstone = 8,
    coarsestone = 15,
    copperbar = 30,
    tinbar = 50,
    bronzebar = 60,
    lionsstrength = 60,
    minordefense = 50,
    lesseragility = 90,
    rejuv = 120,
    flasktitans = 400,
    flasksupreme = 450,
    flaskassault = 500,
    roughsharpening = 50,
    copperchainbelt = 150,
    runedcopperbracers = 180,
    copperchainvest = 250,
    coarsesharpening = 120,
    roughbronzeshoulders = 400,
    patternedbronzebracers = 450,
    ironore = 40, goldore = 80, mithrilore = 70, truesilverore = 120, darkironore = 100, heavystone = 25,
    ironbar = 60, steelbar = 90, goldbar = 150, mithrilbar = 120, truesilverbar = 220, darkironbar = 500,
    fadeleaf = 40, kingsblood = 45, firebloom = 60, sungrass = 70,
    blackdragonscale = 150, elementalfire = 120, elementalearth = 120, heartoffire = 400, coreleather = 500, fierycore = 600,
    elixirfirepower = 200, elixiragility = 220, freeaction = 200, flaskflowing = 900,
    heavysharpening = 200, greenironbracers = 500, goldenscaleshoulders = 700, mithrilscaleshoulders = 900,
    truesilverbreastplate = 1500, fierychaingirdle = 2000, darkironpulverizer = 3000,
}
for id, v in pairs(SELL) do items[id].sell = v end
for id, def in pairs(items) do D.items[id] = def end
for _, id in ipairs(ORDER) do D.itemOrder[#D.itemOrder + 1] = id end

---------------------------------------------------------------------------
-- Data: recipes (skill = the recipe's level; station = where it's made)
---------------------------------------------------------------------------

D.recipes = {
    -- Mining: smelting, at a forge
    { id = "smeltcopper", prof = "mining", skill = 1, makes = "copperbar", mats = { copperore = 1 }, station = "forge" },
    { id = "smelttin", prof = "mining", skill = 50, makes = "tinbar", mats = { tinore = 1 }, station = "forge" },
    { id = "smeltbronze", prof = "mining", skill = 55, makes = "bronzebar", n = 2, mats = { copperbar = 1, tinbar = 1 },
      station = "forge" },
    -- Blacksmithing, at an anvil
    { id = "roughsharpening", prof = "blacksmithing", skill = 1, makes = "roughsharpening", mats = { roughstone = 2 }, station = "anvil" },
    { id = "copperchainbelt", prof = "blacksmithing", skill = 10, makes = "copperchainbelt", mats = { copperbar = 3 }, station = "anvil" },
    { id = "runedcopperbracers", prof = "blacksmithing", skill = 25, makes = "runedcopperbracers",
      mats = { copperbar = 3, roughstone = 2 }, station = "anvil" },
    { id = "copperchainvest", prof = "blacksmithing", skill = 35, makes = "copperchainvest",
      mats = { copperbar = 5, roughstone = 2 }, station = "anvil" },
    { id = "coarsesharpening", prof = "blacksmithing", skill = 55, makes = "coarsesharpening", mats = { coarsestone = 2 }, station = "anvil" },
    { id = "roughbronzeshoulders", prof = "blacksmithing", skill = 65, makes = "roughbronzeshoulders",
      mats = { bronzebar = 4 }, station = "anvil" },
    { id = "patternedbronzebracers", prof = "blacksmithing", skill = 80, makes = "patternedbronzebracers",
      mats = { bronzebar = 4, coarsestone = 2 }, station = "anvil" },
    -- Alchemy, anywhere
    { id = "minorhealing", prof = "alchemy", skill = 1, makes = "potion", mats = { peacebloom = 1, silverleaf = 1 } },
    { id = "minordefense", prof = "alchemy", skill = 1, makes = "minordefense", mats = { silverleaf = 2 } },
    { id = "lionsstrength", prof = "alchemy", skill = 10, makes = "lionsstrength", mats = { earthroot = 1, silverleaf = 1 } },
    { id = "rejuv", prof = "alchemy", skill = 40, makes = "rejuv", mats = { mageroyal = 2, peacebloom = 1 } },
    { id = "lesseragility", prof = "alchemy", skill = 50, makes = "lesseragility", mats = { mageroyal = 1, silverleaf = 1 } },
    { id = "lesserhealing", prof = "alchemy", skill = 55, makes = "superpotion", mats = { potion = 1, briarthorn = 1 } },
    { id = "flasktitans", prof = "alchemy", skill = 80, makes = "flasktitans", mats = { earthroot = 3, briarthorn = 2, mageroyal = 2 } },
    { id = "flasksupreme", prof = "alchemy", skill = 85, makes = "flasksupreme", mats = { mageroyal = 3, briarthorn = 2, silverleaf = 1 } },
    { id = "flaskassault", prof = "alchemy", skill = 90, makes = "flaskassault", mats = { briarthorn = 3, earthroot = 2, peacebloom = 1 } },
    -- Blackrock (Journeyman / Expert). Dark Iron is worked only at the Black Forge (station "blackforge").
    { id = "smeltiron", prof = "mining", skill = 100, makes = "ironbar", mats = { ironore = 1 }, station = "forge" },
    { id = "smeltsteel", prof = "mining", skill = 105, makes = "steelbar", mats = { ironbar = 1, heavystone = 1 }, station = "forge" },
    { id = "smeltgold", prof = "mining", skill = 115, makes = "goldbar", mats = { goldore = 1 }, station = "forge" },
    { id = "smeltmithril", prof = "mining", skill = 125, makes = "mithrilbar", mats = { mithrilore = 1 }, station = "forge" },
    { id = "smelttruesilver", prof = "mining", skill = 150, makes = "truesilverbar", mats = { truesilverore = 1 }, station = "forge" },
    { id = "smeltdarkiron", prof = "mining", skill = 160, makes = "darkironbar", mats = { darkironore = 8 }, station = "blackforge" },
    { id = "heavysharpening", prof = "blacksmithing", skill = 105, makes = "heavysharpening", mats = { heavystone = 2 }, station = "anvil" },
    { id = "greenironbracers", prof = "blacksmithing", skill = 115, makes = "greenironbracers",
      mats = { ironbar = 6, fadeleaf = 2 }, station = "anvil" },                          -- (Fadeleaf for the green dye)
    { id = "goldenscaleshoulders", prof = "blacksmithing", skill = 120, makes = "goldenscaleshoulders",
      mats = { steelbar = 6, goldbar = 2 }, station = "anvil" },
    { id = "mithrilscaleshoulders", prof = "blacksmithing", skill = 140, makes = "mithrilscaleshoulders",
      mats = { mithrilbar = 8 }, station = "anvil" },
    { id = "truesilverrod", prof = "blacksmithing", skill = 160, makes = "truesilverrod",
      mats = { truesilverbar = 1, blackdragonscale = 2 }, station = "anvil" },
    { id = "truesilverbreastplate", prof = "blacksmithing", skill = 165, makes = "truesilverbreastplate",
      mats = { truesilverbar = 12, elementalearth = 2 }, station = "anvil" },             -- (Elemental Earth for the pearl)
    { id = "fierychaingirdle", prof = "blacksmithing", skill = 170, makes = "fierychaingirdle",
      mats = { darkironbar = 6, heartoffire = 2 }, station = "blackforge" },
    { id = "darkironpulverizer", prof = "blacksmithing", skill = 175, makes = "darkironpulverizer",
      mats = { darkironbar = 18, heartoffire = 4 }, station = "blackforge" },
    { id = "greaterhealing", prof = "alchemy", skill = 110, makes = "greatpotion", mats = { kingsblood = 1, fadeleaf = 1 } },
    { id = "elixirfirepower", prof = "alchemy", skill = 140, makes = "elixirfirepower", mats = { firebloom = 2 } },
    { id = "fireprotection", prof = "alchemy", skill = 145, makes = "fireprotection", mats = { firebloom = 1, fadeleaf = 1 } },
    { id = "elixiragility", prof = "alchemy", skill = 150, makes = "elixiragility", mats = { sungrass = 1, fadeleaf = 1 } },
    { id = "freeaction", prof = "alchemy", skill = 150, makes = "freeaction", mats = { sungrass = 1, kingsblood = 1 } },
    { id = "flaskflowing", prof = "alchemy", skill = 175, makes = "flaskflowing", mats = { sungrass = 3, elementalfire = 1 } },
}
D.recipeStations = { forge = "a forge", anvil = "an anvil", blackforge = "the Black Forge in Blackrock Mountain" }

-- What beasts drop after a won wild battle (never trainers or player battles): every rule whose species list has
-- the foe rolls its own chance (%), on the game's rng.
D.beastDrops = {
    { item = "blackdragonscale", chance = 8, species = { "blackwhelp", "broodling", "blackwyrmkin", "ragetalon" } },
    { item = "elementalfire", chance = 12, species = { "blazing", "inferno", "spitter", "rager", "torcher", "firewalker",
                                                       "fireguard", "lavasurger" } },
    { item = "elementalearth", chance = 12, species = { "magma", "obsidian" } },
    { item = "heartoffire", chance = 4, species = { "inferno", "volchan" } },
    { item = "coreleather", chance = 10, species = { "corehound" } },
    { item = "fierycore", chance = 5, species = { "flameimp", "lavasurger", "corehound", "magmadar" } },
}

---------------------------------------------------------------------------
-- Skill
---------------------------------------------------------------------------

C.RESPAWN = 600                -- seconds (realm time) before a gathered node grows back
C.SKILLUP = { orange = 100, yellow = 75, green = 25, grey = 0 }
C.clock, C.rng = nil, nil      -- tests

local function Now()
    if C.clock then return C.clock end
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end
local function Rng(a, b) return (C.rng or math.random)(a, b) end

local function Profs()
    local s = G.save
    if type(s.prof) ~= "table" then s.prof = {} end
    return s.prof
end

-- The player's skill in `prof`, nil when not learned.
function C.Skill(prof)
    local s = G.save
    return s and type(s.prof) == "table" and tonumber(s.prof[prof]) or nil
end

function C.Difficulty(req, skill)
    local d = (skill or 0) - req
    if d < 10 then return "orange" elseif d < 20 then return "yellow" elseif d < 35 then return "green" end
    return "grey"
end

-- The player's tier in `prof` (a D.skillTiers entry; Apprentice when none was trained).
function C.Tier(prof)
    local s = G.save
    local id = s and type(s.profTier) == "table" and s.profTier[prof]
    for _, t in ipairs(D.skillTiers) do if t.id == id then return t end end
    return D.skillTiers[1]
end

-- How high the player's skill in `prof` can climb now.
function C.Cap(prof) return math.min(D.SKILL_MAX, C.Tier(prof).cap) end

-- Rolls a skill-up for something of level `req`; returns the new skill when it rose.
function C:SkillUp(prof, req)
    local skill = C.Skill(prof)
    if not skill or skill >= C.Cap(prof) then return nil end
    if Rng(1, 100) > C.SKILLUP[C.Difficulty(req, skill)] then return nil end
    Profs()[prof] = skill + 1
    G:Emit("skillup", { prof = prof, skill = skill + 1 })
    return skill + 1
end

-- The main professions the player knows, in menu order (a secondary one, Fishing, doesn't count toward the two).
function C.Known()
    local out = {}
    for _, id in ipairs(D.professionOrder) do
        if C.Skill(id) and not D.professions[id].secondary then out[#out + 1] = id end
    end
    return out
end

-- Returns ok, message.
function C:Learn(prof)
    local p = D.professions[prof]
    if not p then return false, "?" end
    if C.Skill(prof) then return false, "You already know " .. p.name .. "." end
    if not p.secondary and #C.Known() >= D.MAX_PROFESSIONS then
        return false, "You can only know two professions. Forget one first."
    end
    if G.save.money < D.PROFESSION_FEE then return false, "You can't afford the training (" .. D.Money(D.PROFESSION_FEE) .. ")." end
    G.save.money = G.save.money - D.PROFESSION_FEE
    Profs()[prof] = 1
    G:Emit("learn", { prof = prof })
    return true, "You have learned " .. p.name .. "!"
end

-- Forgets a profession and its skill. Returns ok, message.
function C:Unlearn(prof)
    local p = D.professions[prof]
    if not p or not C.Skill(prof) then return false, "?" end
    Profs()[prof] = nil
    if type(G.save.profTier) == "table" then G.save.profTier[prof] = nil end
    return true, "You have unlearned " .. p.name .. "."
end

-- The hint over a node: "Pick Peacebloom", with what's missing when it can't be gathered yet.
function C:GatherHint(resId)
    local res = D.resources[resId]
    if not res then return nil end
    local profId = res.kind == "herb" and "herbalism" or "mining"
    local prof = D.professions[profId]
    local skill = C.Skill(profId)
    local text = (res.kind == "herb" and "Pick " or "Mine ") .. res.name
    if not skill then
        text = text .. "  (needs " .. prof.name .. ")"
    elseif skill < res.skill then
        text = text .. string.format("  (needs %s %d)", prof.name, res.skill)
    end
    return text
end

-- The trainer's conversation (from the map script).
function C:TrainerTalk(g, id)
    local t = D.craftTrainers[id]
    g:Say(t.name .. ": " .. t.hello)
    local options, profs = {}, {}
    for _, p in ipairs(t.teaches) do
        if not C.Skill(p) then
            options[#options + 1] = "Learn " .. D.professions[p].name
            profs[#profs + 1] = p
        end
    end
    if #options == 0 then
        g:Say(t.name .. ": " .. t.done)
        return
    end
    -- two professions already: offer to forget one first (forgotten only once the new one is picked and paid for)
    local known = C.Known()
    local forgetProf
    if #known >= D.MAX_PROFESSIONS then
        local names, forget = {}, {}
        for i, p in ipairs(known) do
            names[i] = D.professions[p].name
            forget[i] = "Forget " .. D.professions[p].name
        end
        g:Say(string.format("%s: You already know %s. A tamer can only keep two trades.", t.name, table.concat(names, " and ")))
        local which = g:Choose(t.name .. ": Forget one to make room?", forget)
        if not which then
            g:Say(t.name .. ": Wise. Come back if you change your mind.")
            return
        end
        local p = known[which]
        if not g:YesNo(string.format("Forget %s? Your skill of %d will be lost.", D.professions[p].name, C.Skill(p))) then
            g:Say(t.name .. ": Come back if you change your mind.")
            return
        end
        forgetProf = p
    end
    local pick = g:Choose(string.format("%s: Care to learn a trade? %s each.", t.name, D.Money(D.PROFESSION_FEE)), options)
    if not pick then
        g:Say(t.name .. ": Come back anytime.")
        return
    end
    if G.save.money < D.PROFESSION_FEE then
        g:Say("You can't afford the training (" .. D.Money(D.PROFESSION_FEE) .. ").")
        return
    end
    local oldSkill = forgetProf and C.Skill(forgetProf)
    if forgetProf then
        local _, msg = C:Unlearn(forgetProf)
        g:Say(msg)
    end
    local ok, msg = C:Learn(profs[pick])
    if not ok and forgetProf then Profs()[forgetProf] = oldSkill end      -- (can't happen after the checks above)
    g:Say(msg)
    if ok then g:Say(t.name .. ": " .. D.professions[profs[pick]].howto) end
end

-- The tier trainers (Verner Osgood: Journeyman, Hansel Heavyhands: Expert), from a map NPC's script through
-- G:ProfessionTrainer. They offer their tier for the trades you know and have the skill for; with nothing to
-- offer (or by choice) they teach a trade from scratch like Goldshire's trainers.
function C:TierTalk(g, tierId)
    local t = D.craftTrainers[tierId]
    local tier
    for _, x in ipairs(D.skillTiers) do if x.id == tierId then tier = x end end
    if not t or not tier then return end
    g:Say(t.name .. ": " .. t.hello)
    local options, profs, notYet = {}, {}, {}
    for _, p in ipairs(C.Known()) do
        if C.Tier(p).cap < tier.cap then
            if C.Skill(p) >= tier.needs then
                options[#options + 1] = string.format("%s %s (%s)", tier.name, D.professions[p].name, D.Money(tier.fee))
                profs[#profs + 1] = p
            else
                notYet[#notYet + 1] = string.format("%s %d", D.professions[p].name, tier.needs)
            end
        end
    end
    if #options == 0 then
        if #notYet > 0 then
            g:Say(string.format("%s: Come back when you're better at it. %s needs %s.", t.name, tier.name,
                table.concat(notYet, ", ")))
        end
        if #C.Known() < D.MAX_PROFESSIONS then return C:TrainerTalk(g, tierId) end
        if #notYet == 0 then g:Say(t.name .. ": " .. t.done) end
        return
    end
    if #C.Known() < D.MAX_PROFESSIONS then options[#options + 1] = "Learn a new trade" end
    local pick = g:Choose(t.name .. ": What'll it be?", options)
    if not pick then
        g:Say(t.name .. ": Come back anytime.")
        return
    end
    local prof = profs[pick]
    if not prof then return C:TrainerTalk(g, tierId) end
    if G.save.money < tier.fee then
        g:Say("You can't afford the training (" .. D.Money(tier.fee) .. ").")
        return
    end
    G.save.money = G.save.money - tier.fee
    if type(G.save.profTier) ~= "table" then G.save.profTier = {} end
    G.save.profTier[prof] = tier.id
    G:Emit("tier", { prof = prof, tier = tier.id })
    g:Say(string.format("You are now a %s in %s! Your skill can rise to %d.", tier.name, D.professions[prof].name, tier.cap))
end

function G:ProfessionTrainer(tierId) return C:TierTalk(self, tierId) end

---------------------------------------------------------------------------
-- Nodes
---------------------------------------------------------------------------

local function NodeKey(mapId, node) return mapId .. ":" .. node.x .. ":" .. node.y end

-- Whether the node is there to gather, and what it is right now.
function C:NodeState(mapId, node)
    local s = G.save
    -- under a field that was ploughed over (Aftermath.lua): nothing to gather there now
    if ns.AzeroAftermath and ns.AzeroAftermath.Covered(mapId, node.x, node.y) then return false end
    local st = type(s.nodes) == "table" and s.nodes[NodeKey(mapId, node)]
    local up = not st or Now() - (tonumber(st.t) or 0) >= C.RESPAWN
    local list = node.list
    local at = (node.x * 7 + node.y * 13) + (st and tonumber(st.n) or 0)
    local res = list[at % #list + 1]
    -- what grows back is the node's turn in the map's list, skipping what the player's skill can't gather yet
    -- (else a node that turned into one above their skill stayed out of reach for good); same order every time
    for i = 0, #list - 1 do
        local id = list[(at + i) % #list + 1]
        local r = D.resources[id]
        local skill = r and C.Skill(r.kind == "herb" and "herbalism" or "mining")
        if skill and skill >= r.skill then res = id break end
    end
    return up, res
end

local function Give(item, n)
    local bag = G.save.bag
    bag[item] = (bag[item] or 0) + n
end

-- A on a node (inside the game's script).
function C:Gather(g, node)
    local mapId = g.map.id
    local up, resId = C:NodeState(mapId, node)
    local res = D.resources[resId]
    if not up or not res then return end
    local profId = res.kind == "herb" and "herbalism" or "mining"
    local prof = D.professions[profId]
    local skill = C.Skill(profId)
    if not skill then
        g:Say(string.format("%s. It takes %s to gather it: %s in Goldshire teaches it.", res.name, prof.name, prof.trainer))
        return
    end
    if skill < res.skill then
        g:Say(string.format("%s: requires %s (%d). Your skill is %d.", res.name, prof.name, res.skill, skill))
        return
    end
    local n = Rng(res.yield[1], res.yield[2])
    local item = res.item or resId
    Give(item, n)
    local lines = { string.format("You %s %s x%d.", res.kind == "herb" and "picked" or "mined", D.items[item].name, n) }
    if res.extra and Rng(1, 100) <= res.extra.chance then
        Give(res.extra.item, 1)
        lines[#lines + 1] = string.format("You also found %s.", D.items[res.extra.item].name)
    end
    local s = G.save
    if type(s.nodes) ~= "table" then s.nodes = {} end
    local key = NodeKey(mapId, node)
    local st = type(s.nodes[key]) == "table" and s.nodes[key] or {}
    st.t, st.n = Now(), (st.n or 0) + 1
    s.nodes[key] = st
    local rose = C:SkillUp(profId, res.skill)
    if rose then lines[#lines + 1] = string.format("Your skill in %s has increased to %d.", prof.name, rose) end
    G:Emit("gather", { res = resId, item = item, n = n, prof = profId })
    g:Say(table.concat(lines, "\n"))
end

---------------------------------------------------------------------------
-- Crafting
---------------------------------------------------------------------------

C.byProf = {}
for _, r in ipairs(D.recipes) do
    C.byProf[r.prof] = C.byProf[r.prof] or {}
    table.insert(C.byProf[r.prof], r)
end

-- Is a crafting station of `kind` (map objects with station = kind) within two tiles?
function C:NearStation(kind)
    local m = G.map
    if not (m and G.save) then return false end
    for _, o in ipairs(m.def.objects or {}) do
        local fits = o.station == kind or (kind == "forge" and o.station == "blackforge")    -- the Black Forge is a forge
        if fits and math.abs(o.x - G.save.x) <= 2 and math.abs(o.y - G.save.y) <= 2 then return true end
    end
    return false
end

-- How many the bag has materials for.
function C.CanMake(r)
    local bag = G.save.bag
    local most = math.huge
    for item, n in pairs(r.mats) do most = math.min(most, math.floor((bag[item] or 0) / n)) end
    return most == math.huge and 0 or most
end

-- ok, or false and why: "unknown" | "skill" | "station" | "mats"
function C:Check(r)
    local skill = C.Skill(r.prof)
    if not skill then return false, "unknown" end
    if skill < r.skill then return false, "skill" end
    if r.station and not C:NearStation(r.station) then return false, "station" end
    if C.CanMake(r) < 1 then return false, "mats" end
    return true
end

-- Makes one. Returns ok, message.
function C:Craft(r)
    local ok, why = C:Check(r)
    if not ok then
        if why == "skill" then return false, string.format("Requires %s (%d).", D.professions[r.prof].name, r.skill) end
        if why == "station" then return false, "You need to be at " .. D.recipeStations[r.station] .. "." end
        if why == "mats" then return false, "You don't have the materials." end
        return false, "You don't know " .. D.professions[r.prof].name .. "."
    end
    local bag = G.save.bag
    for item, n in pairs(r.mats) do
        bag[item] = bag[item] - n
        if bag[item] <= 0 then bag[item] = nil end
    end
    local n = r.n or 1
    Give(r.makes, n)
    local msg = string.format("You create %s%s.", D.items[r.makes].name, n > 1 and (" x" .. n) or "")
    local rose = C:SkillUp(r.prof, r.skill)
    if rose then msg = msg .. string.format("\nYour skill in %s has increased to %d.", D.professions[r.prof].name, rose) end
    G:Emit("craft", { recipe = r.id, item = r.makes, n = n, prof = r.prof })
    return true, msg
end

-- A forge / anvil / alchemy table on the map opens that profession's recipes.
function G:CraftAt(prof) return self:Wait({ kind = "craft", prof = prof }) end

---------------------------------------------------------------------------
-- Gear and flasks
---------------------------------------------------------------------------

local function Take(item)
    local bag = G.save.bag
    if (bag[item] or 0) <= 0 then return false end
    bag[item] = bag[item] - 1
    if bag[item] <= 0 then bag[item] = nil end
    return true
end

local function ClampHP(mon) mon.hp = math.min(mon.hp, M.MaxHP(mon)) end

-- Puts `item` on party beast `idx` in its slot; what that slot held goes back in the bag. Returns ok, message.
function G:Equip(idx, item)
    local mon = self.save.party[idx]
    local def = D.items[item]
    if not mon or not def or def.use ~= "gear" or not def.slot or not Take(item) then return false, "It won't have any effect." end
    if type(mon.gear) ~= "table" then mon.gear = {} end
    local old = mon.gear[def.slot]
    if old then Give(old, 1) end
    mon.gear[def.slot] = item
    ClampHP(mon)
    self:Emit("equip", { mon = mon, item = item })
    if old then
        return true, string.format("%s took off the %s and put on the %s.", M.Name(mon), D.items[old].name, def.name)
    end
    return true, string.format("%s is now wearing the %s.", M.Name(mon), def.name)
end

function G:Unequip(idx, slot)
    local mon = self.save.party[idx]
    local old = mon and type(mon.gear) == "table" and mon.gear[slot]
    if not old then return false, "Nothing to take off there." end
    Give(old, 1)
    mon.gear[slot] = nil
    if not next(mon.gear) then mon.gear = nil end
    ClampHP(mon)
    return true, string.format("You took the %s off %s.", D.items[old].name, M.Name(mon))
end

function G:UseFlask(idx, item)
    local mon = self.save.party[idx]
    local def = D.items[item]
    if not mon or not def or def.use ~= "flask" or mon.hp <= 0 or not Take(item) then return false, "It won't have any effect." end
    mon.flask = { id = item, n = def.battles }
    return true, string.format("%s drank the %s. (%d battles)", M.Name(mon), def.name, def.battles)
end

-- After a won wild battle: the foes' drops (D.beastDrops), on the game's rng. Returns the items given.
function C:BeastDrops(g, foes)
    local got = {}
    for _, foe in ipairs(foes or {}) do
        for _, rule in ipairs(D.beastDrops) do
            local hit = false
            for _, sp in ipairs(rule.species) do if sp == foe.sp then hit = true end end
            if hit and D.items[rule.item] and (g.rng or math.random)(1, 100) <= rule.chance then
                Give(rule.item, 1)
                got[#got + 1] = rule.item
                G:Emit("drop", { item = rule.item, sp = foe.sp })
                g:Sfx("item")
                g:Say(string.format("The %s dropped %s!", D.species[foe.sp].name, D.items[rule.item].name))
            end
        end
    end
    return got
end

-- After each battle (not between players): flasks count down. Says when one wears off.
function C:AfterBattle(g)
    for _, mon in ipairs(G.save.party) do
        local f = mon.flask
        if f then
            f.n = (f.n or 1) - 1
            if f.n <= 0 then
                mon.flask = nil
                ClampHP(mon)
                if D.items[f.id] then g:Say(string.format("The %s on %s wore off.", D.items[f.id].name, M.Name(mon))) end
            end
        end
    end
end

-- For tests
C._Now = Now

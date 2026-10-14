if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/Data.lua", ...) then return end -- DisasterZone Games/Illidan/Data.lua
-- ns.BoIData: The Binding of Illidan's tables. A Binding of Isaac style run through the Black Temple: five floors,
-- each a random set of rooms ending in a raid boss that fights with its raid mechanics (Games/Illidan/Bosses.lua).
-- You play your own class: its bolt is your tear, its stats your start.
--
-- Art is the client's own, by FileDataID or path: floor and wall textures of the raids' WMOs, spell and item icons,
-- the encounter journal's boss busts (Interface\EncounterJournal\UI-EJ-BOSS-<name>, 128 x 64), loading screens.
-- Spell icon IDs are the client's (SpellMisc.SpellIconFileDataID, build 2.5.6) for the spell named next to them.
local _, ns = ...

local D = {}
ns.BoIData = D

D.GAME_ID = "illidan"
D.W, D.H, D.T = 720, 432, 48                 -- the room in its own units (a wall band T wide all round)

local function icon(name) return "Interface\\Icons\\" .. name end
D.icon = icon

-- your class: the tear (its bolt), its colour, stats and what it starts with.
-- hp: healthstones (two halves each); soul: Soul Shard halves; dmg; delay: frames between tears (60 a second);
-- speed: px a frame; range: frames a tear flies; shot: its speed
D.CLASSES = {
    WARRIOR = { bolt = "Thrown axes", icon = icon("INV_Axe_04"), tear = { 0.78, 0.61, 0.43 }, hp = 4, soul = 0, dmg = 4.6,
                delay = 24, speed = 3.0, range = 34, shot = 7, note = "hits hard, up close" },
    PALADIN = { bolt = "Holy bolts", icon = icon("Spell_Holy_HolyBolt"), tear = { 1, 0.86, 0.45 }, hp = 4, soul = 0, dmg = 3.4,
                delay = 20, speed = 2.9, range = 46, shot = 7, note = "the most healthstones" },
    HUNTER = { bolt = "Arrows", icon = icon("Ability_Marksmanship"), tear = { 0.82, 0.9, 0.55 }, hp = 3, soul = 0, dmg = 2.2,
               delay = 10, speed = 3.2, range = 56, shot = 9.5, note = "fast, light shots" },
    ROGUE = { bolt = "Thrown daggers", icon = icon("INV_Weapon_ShortBlade_05"), tear = { 1, 0.96, 0.41 }, hp = 3, soul = 0,
              dmg = 3.0, delay = 14, speed = 3.6, range = 30, shot = 8.5, note = "the quickest feet" },
    PRIEST = { bolt = "Smites", icon = icon("Spell_Holy_HolySmite"), tear = { 1, 0.96, 0.75 }, hp = 2, soul = 2, dmg = 3.0,
               delay = 20, speed = 3.0, range = 50, shot = 7, items = { "pws" }, note = "starts shielded" },
    SHAMAN = { bolt = "Lightning bolts", icon = icon("Spell_Nature_Lightning"), tear = { 0.45, 0.7, 1 }, hp = 3, soul = 0,
               dmg = 3.0, delay = 19, speed = 3.0, range = 48, shot = 8, items = { "chain" }, note = "hits jump" },
    MAGE = { bolt = "Frostbolts", icon = icon("Spell_Frost_FrostBolt02"), tear = { 0.5, 0.83, 1 }, hp = 3, soul = 0, dmg = 3.0,
             delay = 19, speed = 3.0, range = 66, shot = 7, slow = true, note = "long range, chills" },
    WARLOCK = { bolt = "Shadow bolts", icon = icon("Spell_Shadow_ShadowBolt"), tear = { 0.72, 0.48, 1 }, hp = 2, soul = 2,
                dmg = 3.2, delay = 21, speed = 2.9, range = 50, shot = 6.5, items = { "imp" }, note = "an imp shoots too" },
    DRUID = { bolt = "Wrath", icon = icon("Spell_Nature_AbolishMagic"), tear = { 0.6, 0.95, 0.5 }, hp = 3, soul = 0, dmg = 3.1,
              delay = 19, speed = 3.1, range = 50, shot = 7, items = { "thorns" }, note = "starts with Thorns" },
}
D.CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- items: n name, t the banner's line, i icon, q quality (3 rare, 4 epic, 5 legendary), pool (where it can come from:
-- vault, boss, shop, bargain (costs healthstones), naaru). active: a Space item with charges (rooms to recharge).
D.ITEMS = {
    glaive = { n = "Warglaive of Azzinoth", t = "Out and back, through everything", i = icon("INV_Weapon_Glave_01"), q = 5, pool = "bargain" },
    eye = { n = "Eye of Gruul", t = "Homing tears", i = icon("INV_Misc_Eye_01"), q = 4, pool = "vault" },
    sulfuras = { n = "Sulfuras", t = "The floor burns", i = icon("INV_Hammer_Unique_Sulfuras"), q = 5, pool = "bargain" },
    poly = { n = "Tome of Polymorph", t = "Baa", i = icon("Spell_Nature_Polymorph"), q = 4, pool = "vault" },
    pws = { n = "Power Word: Shield", t = "One free hit per room", i = icon("Spell_Holy_PowerWordShield"), q = 4, pool = "naaru" },
    sprint = { n = "Boots of the Rogue", t = "Speed up", i = icon("Ability_Rogue_Sprint"), q = 3, pool = "shop" },
    soulstone = { n = "Soulstone", t = "Extra life", i = icon("INV_Misc_Bone_HumanSkull_01"), q = 4, pool = "naaru" },
    thorns = { n = "Thorns", t = "They touch, they bleed", i = icon("Spell_Nature_Thorns"), q = 3, pool = "vault" },
    mongoose = { n = "Elixir of the Mongoose", t = "Tears up", i = icon("INV_Potion_54"), q = 3, pool = "shop" },
    imp = { n = "Imp", t = "A friend who shoots", i = icon("Spell_Shadow_SummonImp"), q = 4, pool = "bargain" },
    fiend = { n = "Shadowfiend", t = "A friend who shoots", i = icon("Spell_Shadow_Shadowfiend"), q = 4, pool = "vault" },
    chain = { n = "Chain Lightning", t = "Hits jump", i = icon("Spell_Nature_Lightning"), q = 4, pool = "vault" },
    madness = { n = "Darkmoon Card: Madness", t = "Something new every room", i = icon("INV_Misc_Ticket_Tarot_Madness"), q = 4, pool = "boss" },
    orb = { n = "Fel Orb", t = "Tears grow as they fly", i = icon("INV_Misc_Orb_05"), q = 3, pool = "boss" },
    blade = { n = "Felsteel Longblade", t = "Damage up", i = icon("INV_Sword_39"), q = 3, pool = "boss" },
    elemental = { n = "Water Elemental", t = "It guards you", i = icon("Spell_Frost_SummonWaterElemental"), q = 4, pool = "naaru" },
    meta = { n = "Metamorphosis", t = "Space: six seconds of demon form", i = icon("Spell_Shadow_Metamorphosis"), q = 5, pool = "bargain",
             active = 6 },
    blink = { n = "Blink", t = "Space: jump through anything", i = icon("Spell_Arcane_Blink"), q = 4, pool = "boss", active = 2 },
}
D.QUALITY = { [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 } }

-- pickups (drops on a room's clear, the vendor's shelf)
D.PICKUPS = {
    heart = { i = icon("INV_Stone_04"), n = "Healthstone" },
    soul = { i = icon("INV_Misc_Gem_Amethyst_02"), n = "Soul Shard" },
    gold = { i = "Interface\\MoneyFrame\\UI-GoldIcon", n = "Gold" },
    key = { i = icon("INV_Misc_Key_03"), n = "Key" },
    bomb = { i = icon("INV_Misc_Bomb_04"), n = "Goblin Bomb" },
}

-- enemies: hp, r (radius), ai, sp (speed), trail (fire left behind), hard (contact damage in halves)
D.FOES = {
    spider = { n = "Barrow Spider", i = icon("Ability_Hunter_Pet_Spider"), hp = 6, r = 14, ai = "hop", sp = 5 },
    bat = { n = "Vampire Bat", i = icon("Ability_Hunter_Pet_Bat"), hp = 5, r = 14, ai = "flit", sp = 2.0 },
    dead = { n = "Restless Skeleton", i = icon("Spell_Shadow_RaiseDead"), hp = 9, r = 16, ai = "chase", sp = 1.1 },
    watcher = { n = "Shadowmoon Watcher", i = icon("Spell_Shadow_GatherShadows"), hp = 9, r = 16, ai = "turret", sp = 0, col = { 0.7, 0.55, 1 } },
    imp = { n = "Fel Imp", i = icon("Spell_Shadow_SummonImp"), hp = 7, r = 15, ai = "chase", sp = 1.45 },
    felhunter = { n = "Felhunter", i = icon("Spell_Shadow_SummonFelHunter"), hp = 12, r = 17, ai = "dash", sp = 6 },
    void = { n = "Voidwalker", i = icon("Spell_Shadow_SummonVoidWalker"), hp = 24, r = 21, ai = "chase", sp = 0.75 },
    channeler = { n = "Ashtongue Channeler", i = icon("Spell_Shadow_CurseOfMannoroth"), hp = 11, r = 16, ai = "turret", sp = 0, col = { 1, 0.54, 0.24 } },
    brute = { n = "Bonechewer Brute", i = icon("INV_Misc_Head_Orc_01"), hp = 16, r = 18, ai = "chase", sp = 1.3 },
    priestess = { n = "Priestess of Delight", i = icon("Spell_Shadow_Charm"), hp = 10, r = 16, ai = "turret", sp = 0, col = { 1, 0.45, 0.8 } },
    sheep = { n = "Sheep", i = icon("Spell_Nature_Polymorph"), hp = 1, r = 13, ai = "wander", sp = 0.8 },
    -- the bosses' adds
    mchan = { n = "Hellfire Channeler", i = icon("Spell_Shadow_CurseOfMannoroth"), hp = 12, r = 15, ai = "mchan", sp = 0 },
    abyssal = { n = "Burning Abyssal", i = 135808, hp = 10, r = 15, ai = "chase", sp = 1.0, trail = { 1, 0.42, 0.1 } },
    parasite = { n = "Parasitic Shadowfiend", i = 136214, hp = 3, r = 11, ai = "chase", sp = 1.9 },
    azflame = { n = "Flame of Azzinoth", i = icon("Spell_Fire_FelImmolation"), hp = 60, r = 20, ai = "chase", sp = 0.95, trail = { 0.49, 1, 0.23 } },
    sdemon = { n = "Shadow Demon", i = icon("Spell_Shadow_DemonBreath"), hp = 8, r = 16, ai = "chase", sp = 0.5, hard = 3 },
    construct = { n = "Shadowy Construct", i = icon("Spell_Shadow_CallofBone"), hp = 8, r = 15, ai = "chase", sp = 1.0, spiritOnly = true },
    blossom = { n = "Doom Blossom", i = 136210, hp = 6, r = 13, ai = "blossom", sp = 0.6 },
}

-- the five floors: their art (FileDataIDs: floor, wall, a tint over the floor), their light (the sconces' colour, how
-- strong their pools are, one glow in the room's middle: r, g, b, radius, alpha), enemies and boss
D.FLOORS = {
    { name = "Magtheridon's Lair", floor = 131958, floorK = 0.5, wall = 126953, tint = { 0.86, 0.35, 0.12, 0.10 },
      light = { 1, 0.5, 0.15 }, lightK = 0.30, glow = { 0.9, 0.12, 0.04, 210, 0.16 },
      art = "mag", foes = { "imp", "felhunter", "void", "bat" }, boss = "magtheridon" },
    { name = "Illidari Training Grounds", floor = 128034, floorK = 0.5, wall = 128045, tint = { 0.47, 0.86, 0.24, 0.08 },
      light = { 0.45, 1, 0.22 }, lightK = 0.26, glow = { 0.3, 0.7, 0.1, 200, 0.08 },
      art = "bt", foes = { "brute", "felhunter", "imp", "channeler" }, boss = "supremus" },
    { name = "Gorefiend's Vigil", floor = 127251, floorK = 0.8, wall = 126953, tint = { 0.35, 0.2, 0.6, 0.08 },
      light = { 0.55, 0.5, 1 }, lightK = 0.26, glow = { 0.35, 0.55, 0.9, 220, 0.10 },
      art = "bt", foes = { "dead", "bat", "watcher", "void", "spider" }, boss = "teron" },
    { name = "Den of Mortal Delights", floor = 128037, floorK = 0.55, wall = 127261, tint = { 0.9, 0.3, 0.6, 0.08 },
      light = { 1, 0.35, 0.7 }, lightK = 0.28, glow = { 0.9, 0.5, 0.25, 200, 0.08 },
      art = "bt", foes = { "priestess", "brute", "felhunter", "bat" }, boss = "shahraz" },
    { name = "Temple Summit", floor = 128040, floorK = 0.6, wall = 128045, tint = { 0.6, 0.35, 1, 0.08 },
      light = { 0.45, 1, 0.22 }, lightK = 0.24, glow = { 0.55, 0.3, 1, 230, 0.14 },
      art = "bt", foes = { "brute", "felhunter", "void", "channeler", "bat" }, boss = "illidan" },
}
D.TRIM, D.DOOR, D.PEDESTAL = 126957, 126730, 126722

-- the bosses: EJ bust (FileDataID), health, size, glow
D.BOSSES = {
    magtheridon = { n = "Magtheridon", ej = 1378996, hp = 220, r = 42, glow = { 1, 0.35, 0.08 } },
    supremus = { n = "Supremus", ej = 1379016, hp = 560, r = 40, glow = { 0.47, 0.78, 1 } },
    teron = { n = "Teron Gorefiend", ej = 1379018, hp = 640, r = 38, glow = { 0.55, 0.35, 1 } },
    shahraz = { n = "Mother Shahraz", ej = 1379000, hp = 1300, r = 38, glow = { 1, 0.35, 0.7 } },
    illidan = { n = "Illidan Stormrage", ej = 1378987, hp = 1450, r = 38, glow = { 0.55, 1, 0.31 } },
}

-- spell icons (SpellIconFileDataID) the bosses' cast bars and the hazards use
D.SPELL = {
    blastNova = 135824, debris = 136025, shadowCage = 136121, volley = 136197, abyssal = 135808,
    molten = 135794, geyser = 135830, fixate = 136129,
    incinerate = 135789, crushing = 136224, shadowOfDeath = 135752, blossom = 136210, spiritLance = 135845,
    saberLash = 132373, shriek = 136164, beam = 136197, fatal = 136202,
    flameCrash = 135784, shear = 136158, parasite = 136214, demonForm = 136172, prison = 136192, agonizing = 135785,
}
D.MAIEV_ICON = icon("Spell_Shadow_Possession")
D.METAMORPH = icon("Spell_Shadow_Metamorphosis")
D.BLUE_FLAME = 135782
D.SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
D.TRAPDOOR = icon("Spell_Shadow_Teleport")

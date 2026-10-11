if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Constants.lua", ...) then return end -- DisasterZone: static constants.
-- Slots (DisasterZone's own sid 1..17), phases, classes / specs / roles, TBC armor and weapon
-- proficiencies, colors and textures.
local addonName, ns = ...

---------------------------------------------------------------------------
-- Item class / subclass IDs (Enum.ItemClass, Enum.ItemArmorSubclass, Enum.ItemWeaponSubclass)
---------------------------------------------------------------------------

-- Highest list revision accepted anywhere (Store, Sync and BiS share it).
ns.MAX_REV = 2147483647

-- How a dropped item leads to a wanted one (BiS:MatchItem's `via`), as shown to players.
ns.VIA_TEXT = { token = "via token", upgrade = "via Sunmote upgrade", arena = "via token exchange", craft = "crafting material" }

ns.ITEM_CLASS_WEAPON = 2   -- Enum.ItemClass.Weapon
ns.ITEM_CLASS_ARMOR = 4    -- Enum.ItemClass.Armor

ns.ARMOR_SUB = {           -- Enum.ItemArmorSubclass
    MISC = 0, CLOTH = 1, LEATHER = 2, MAIL = 3, PLATE = 4, COSMETIC = 5,
    SHIELD = 6, LIBRAM = 7, IDOL = 8, TOTEM = 9, SIGIL = 10, RELIC = 11,
}

ns.WEAPON_SUB = {          -- Enum.ItemWeaponSubclass
    AXE1H = 0, AXE2H = 1, BOWS = 2, GUNS = 3, MACE1H = 4, MACE2H = 5, POLEARM = 6,
    SWORD1H = 7, SWORD2H = 8, WARGLAIVE = 9, STAFF = 10, BEARCLAW = 11, CATCLAW = 12,
    UNARMED = 13, GENERIC = 14, DAGGER = 15, THROWN = 16, SPEAR = 17, CROSSBOW = 18,
    WAND = 19, FISHINGPOLE = 20,
}

---------------------------------------------------------------------------
-- Slots (§4.1). sid is DisasterZone's own index; convert with ns.SLOTS[sid].invSlot.
---------------------------------------------------------------------------

local function Set(list)
    local s = {}
    for i = 1, #list do s[list[i]] = true end
    return s
end

-- emptyIcon: fallback empty-slot icon fileIDs (GetInventorySlotInfo's texture is preferred).
ns.SLOTS = {
    { id = 1,  key = "HEAD",     label = "Head",           short = "Hd", invSlot = 1,  slotName = "HeadSlot",          emptyIcon = 136516, invTypes = Set { "INVTYPE_HEAD" } },
    { id = 2,  key = "NECK",     label = "Neck",           short = "Nk", invSlot = 2,  slotName = "NeckSlot",          emptyIcon = 136519, invTypes = Set { "INVTYPE_NECK" } },
    { id = 3,  key = "SHOULDER", label = "Shoulder",       short = "Sh", invSlot = 3,  slotName = "ShoulderSlot",      emptyIcon = 136526, invTypes = Set { "INVTYPE_SHOULDER" } },
    { id = 4,  key = "BACK",     label = "Back",           short = "Bk", invSlot = 15, slotName = "BackSlot",          emptyIcon = 136512, invTypes = Set { "INVTYPE_CLOAK" } },
    { id = 5,  key = "CHEST",    label = "Chest",          short = "Ch", invSlot = 5,  slotName = "ChestSlot",         emptyIcon = 136512, invTypes = Set { "INVTYPE_CHEST", "INVTYPE_ROBE" } },
    { id = 6,  key = "WRIST",    label = "Wrist",          short = "Wr", invSlot = 9,  slotName = "WristSlot",         emptyIcon = 136530, invTypes = Set { "INVTYPE_WRIST" } },
    { id = 7,  key = "HANDS",    label = "Hands",          short = "Hn", invSlot = 10, slotName = "HandsSlot",         emptyIcon = 136515, invTypes = Set { "INVTYPE_HAND" } },
    { id = 8,  key = "WAIST",    label = "Waist",          short = "Wa", invSlot = 6,  slotName = "WaistSlot",         emptyIcon = 136529, invTypes = Set { "INVTYPE_WAIST" } },
    { id = 9,  key = "LEGS",     label = "Legs",           short = "Lg", invSlot = 7,  slotName = "LegsSlot",          emptyIcon = 136517, invTypes = Set { "INVTYPE_LEGS" } },
    { id = 10, key = "FEET",     label = "Feet",           short = "Ft", invSlot = 8,  slotName = "FeetSlot",          emptyIcon = 136513, invTypes = Set { "INVTYPE_FEET" } },
    { id = 11, key = "FINGER1",  label = "Ring 1",         short = "R1", invSlot = 11, slotName = "Finger0Slot",       emptyIcon = 136514, invTypes = Set { "INVTYPE_FINGER" } },
    { id = 12, key = "FINGER2",  label = "Ring 2",         short = "R2", invSlot = 12, slotName = "Finger1Slot",       emptyIcon = 136514, invTypes = Set { "INVTYPE_FINGER" } },
    { id = 13, key = "TRINKET1", label = "Trinket 1",      short = "T1", invSlot = 13, slotName = "Trinket0Slot",      emptyIcon = 136528, invTypes = Set { "INVTYPE_TRINKET" } },
    { id = 14, key = "TRINKET2", label = "Trinket 2",      short = "T2", invSlot = 14, slotName = "Trinket1Slot",      emptyIcon = 136528, invTypes = Set { "INVTYPE_TRINKET" } },
    { id = 15, key = "MAINHAND", label = "Main Hand",      short = "MH", invSlot = 16, slotName = "MainHandSlot",      emptyIcon = 136518, invTypes = Set { "INVTYPE_WEAPON", "INVTYPE_2HWEAPON", "INVTYPE_WEAPONMAINHAND" } },
    { id = 16, key = "OFFHAND",  label = "Off Hand",       short = "OH", invSlot = 17, slotName = "SecondaryHandSlot", emptyIcon = 136524, invTypes = Set { "INVTYPE_WEAPON", "INVTYPE_WEAPONOFFHAND", "INVTYPE_SHIELD", "INVTYPE_HOLDABLE" } },
    { id = 17, key = "RANGED",   label = "Ranged / Relic", short = "Rg", invSlot = 18, slotName = "RangedSlot",        emptyIcon = 136520, invTypes = Set { "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC" } },
}
ns.NUM_SLOTS = #ns.SLOTS   -- 17

ns.SLOT_BY_KEY = {}        -- [key] = sid
ns.INVTYPE_TO_SIDS = {}    -- [invType] = { sid, ... } in sid order
ns.INVSLOT_TO_SID = {}     -- [inventory slot id] = sid
for sid = 1, ns.NUM_SLOTS do
    local slot = ns.SLOTS[sid]
    ns.SLOT_BY_KEY[slot.key] = sid
    ns.INVSLOT_TO_SID[slot.invSlot] = sid
end
do
    -- Deterministic order: walk sids, then each slot's invTypes sorted by name.
    for sid = 1, ns.NUM_SLOTS do
        local types = {}
        for invType in pairs(ns.SLOTS[sid].invTypes) do types[#types + 1] = invType end
        table.sort(types)
        for _, invType in ipairs(types) do
            local list = ns.INVTYPE_TO_SIDS[invType]
            if not list then
                list = {}
                ns.INVTYPE_TO_SIDS[invType] = list
            end
            list[#list + 1] = sid
        end
    end
end

-- Paired slots (rings, trinkets, weapons): sid -> the other sid of the pair.
ns.SLOT_PAIR = { [11] = 12, [12] = 11, [13] = 14, [14] = 13, [15] = 16, [16] = 15 }

-- Slot group per sid (§18): both slots of a pair in slot order, else just the sid itself.
-- Used for "currently wearing" displays (rings / trinkets / weapons show both equipped items).
ns.SLOT_GROUP = {}
for sid = 1, ns.NUM_SLOTS do
    local other = ns.SLOT_PAIR[sid]
    if other then
        ns.SLOT_GROUP[sid] = (sid < other) and { sid, other } or { other, sid }
    else
        ns.SLOT_GROUP[sid] = { sid }
    end
end

-- A slot's label ("Head", "Ring 1", "Ranged / Relic"); "Slot N" for a sid that is not a slot (a number given as
-- text works too).
function ns.SlotLabel(sid)
    local s = ns.SLOTS[sid] or ns.SLOTS[tonumber(sid) or 0]
    return s and s.label or ("Slot " .. tostring(sid))
end

-- Human-readable equip location labels (Picker subtitles etc.).
ns.INVTYPE_LABELS = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder",
    INVTYPE_CLOAK = "Back", INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest",
    INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands", INVTYPE_WAIST = "Waist",
    INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
    INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "One-Hand", INVTYPE_2HWEAPON = "Two-Hand",
    INVTYPE_WEAPONMAINHAND = "Main Hand", INVTYPE_WEAPONOFFHAND = "Off Hand",
    INVTYPE_SHIELD = "Shield", INVTYPE_HOLDABLE = "Held In Off-hand",
    INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Thrown",
    INVTYPE_RELIC = "Relic",
}

-- Paper-doll layout.
ns.DOLL_LEFT = { 1, 2, 3, 4, 5, 6 }
ns.DOLL_RIGHT = { 7, 8, 9, 10, 11, 12, 13, 14 }
ns.DOLL_BOTTOM = { 15, 16, 17 }

---------------------------------------------------------------------------
-- Phases (§4.2)
---------------------------------------------------------------------------

-- ns.PHASES are the raid phases (view phase, group phase, Settings, the council). My BiS lists also have a
-- Pre-raid list (phase 0, ns.PRE_RAID): dungeons, reputation, crafting and badges. It is stored apart from the raid
-- phases (data.pr / data.px, off spec data.opr / data.opx: released validators only accept ph / dx phases 1..5) and
-- only its owner sees it (tooltips, My BiS, Atlas marks, the Dungeons tab); the council never does.
ns.PHASES = { 1, 2, 3, 4, 5 }
ns.MAX_PHASE = 5
ns.PRE_RAID = 0
ns.LIST_PHASES = { 0, 1, 2, 3, 4, 5 }   -- the phases of a My BiS list: Pre-raid, then the raid phases
ns.PHASE_INFO = {
    [0] = { short = "Pre-raid", name = "Pre-raid", raids = "Dungeons · Reputation · Crafting · Badges" },
    [1] = { short = "P1", name = "Phase 1", raids = "Karazhan · Gruul · Magtheridon" },
    [2] = { short = "P2", name = "Phase 2", raids = "Serpentshrine · Tempest Keep" },
    [3] = { short = "P3", name = "Phase 3", raids = "Hyjal · Black Temple" },
    [4] = { short = "P4", name = "Phase 4", raids = "Zul'Aman" },
    [5] = { short = "P5", name = "Phase 5", raids = "Sunwell Plateau" },
}

-- "Pre-raid" for phase 0, else "P<n>".
function ns.PhaseLabel(p)
    if p == 0 then return "Pre-raid" end
    return "P" .. tostring(p)
end

-- The picks { [sid] = { main, alt } } of one phase of a ListData table (nil when it has none). p: 0 (Pre-raid) or
-- 1..5; list "os" = the off-spec list (data may also be a ns.ListView, whose fields already are that list's).
function ns.ListPhase(data, p, list)
    if type(data) ~= "table" then return nil end
    local t
    if p == 0 then
        t = (list == "os") and data.opr or data.pr
    else
        local ph = (list == "os") and data.op or data.ph
        t = type(ph) == "table" and ph[p] or nil
    end
    return type(t) == "table" and t or nil
end

-- The disabled slots { [sid] = true } of one phase of a ListData table (nil when none); same arguments.
function ns.ListDisabled(data, p, list)
    if type(data) ~= "table" then return nil end
    local t
    if p == 0 then
        t = (list == "os") and data.opx or data.px
    else
        local dx = (list == "os") and data.ox or data.dx
        t = type(dx) == "table" and dx[p] or nil
    end
    return type(t) == "table" and t or nil
end

---------------------------------------------------------------------------
-- Classes, specs, roles (§4.3)
---------------------------------------------------------------------------

ns.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- English fallback names; UI may prefer LOCALIZED_CLASS_NAMES_MALE when present.
ns.CLASS_NAMES = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}

-- A class file's name: the client's localized name when `localized` (LOCALIZED_CLASS_NAMES_MALE), else English
-- (ns.CLASS_NAMES); an unknown class file comes back capitalized ("DEATHKNIGHT" -> "Deathknight"). nil for nil / "".
function ns.ClassName(classFile, localized)
    if type(classFile) ~= "string" or classFile == "" then return nil end
    if localized then
        local names = LOCALIZED_CLASS_NAMES_MALE
        local loc = type(names) == "table" and names[classFile]
        if type(loc) == "string" and loc ~= "" then return loc end
    end
    return ns.CLASS_NAMES[classFile] or (classFile:sub(1, 1) .. classFile:sub(2):lower())
end

ns.SPECS = {
    WARRIOR = {
        { label = "Arms", tab = 1, role = "melee" },
        { label = "Fury", tab = 2, role = "melee" },
        { label = "Protection", tab = 3, role = "tank" },
    },
    PALADIN = {
        { label = "Holy", tab = 1, role = "healer" },
        { label = "Protection", tab = 2, role = "tank" },
        { label = "Retribution", tab = 3, role = "melee" },
    },
    HUNTER = {
        { label = "Beast Mastery", tab = 1, role = "ranged" },
        { label = "Marksmanship", tab = 2, role = "ranged" },
        { label = "Survival", tab = 3, role = "ranged" },
    },
    ROGUE = {
        { label = "Assassination", tab = 1, role = "melee" },
        { label = "Combat", tab = 2, role = "melee" },
        { label = "Subtlety", tab = 3, role = "melee" },
    },
    PRIEST = {
        { label = "Discipline", tab = 1, role = "healer" },
        { label = "Holy", tab = 2, role = "healer" },
        { label = "Shadow", tab = 3, role = "caster" },
    },
    SHAMAN = {
        { label = "Elemental", tab = 1, role = "caster" },
        { label = "Enhancement", tab = 2, role = "melee" },
        { label = "Restoration", tab = 3, role = "healer" },
    },
    MAGE = {
        { label = "Arcane", tab = 1, role = "caster" },
        { label = "Fire", tab = 2, role = "caster" },
        { label = "Frost", tab = 3, role = "caster" },
    },
    WARLOCK = {
        { label = "Affliction", tab = 1, role = "caster" },
        { label = "Demonology", tab = 2, role = "caster" },
        { label = "Destruction", tab = 3, role = "caster" },
    },
    DRUID = {
        { label = "Balance", tab = 1, role = "caster" },
        { label = "Feral (Cat)", tab = 2, role = "melee" },
        { label = "Feral (Bear)", tab = 2, role = "tank" },
        { label = "Restoration", tab = 3, role = "healer" },
    },
}

-- Spec icons (each spec's .icon, a full texture path), by class and spec label (the table RaidComp:SpecIcon uses).
do
    local SPEC_ICONS = {
        WARRIOR = { Arms = "Ability_Warrior_SavageBlow", Fury = "Ability_Warrior_InnerRage",
                    Protection = "Ability_Warrior_DefensiveStance" },
        PALADIN = { Holy = "Spell_Holy_HolyBolt", Protection = "Spell_Holy_DevotionAura",
                    Retribution = "Spell_Holy_AuraOfLight" },
        HUNTER = { ["Beast Mastery"] = "Ability_Hunter_BeastTaming", Marksmanship = "Ability_Marksmanship",
                   Survival = "Ability_Hunter_SwiftStrike" },
        ROGUE = { Assassination = "Ability_Rogue_Eviscerate", Combat = "Ability_BackStab", Subtlety = "Ability_Stealth" },
        PRIEST = { Discipline = "Spell_Holy_WordFortitude", Holy = "Spell_Holy_HolyBolt",
                   Shadow = "Spell_Shadow_ShadowWordPain" },
        SHAMAN = { Elemental = "Spell_Nature_Lightning", Enhancement = "Spell_Nature_LightningShield",
                   Restoration = "Spell_Nature_MagicImmunity" },
        MAGE = { Arcane = "Spell_Holy_MagicalSentry", Fire = "Spell_Fire_FireBolt02", Frost = "Spell_Frost_FrostBolt02" },
        WARLOCK = { Affliction = "Spell_Shadow_DeathCoil", Demonology = "Spell_Shadow_Metamorphosis",
                    Destruction = "Spell_Shadow_RainOfFire" },
        DRUID = { Balance = "Spell_Nature_StarFall", ["Feral (Cat)"] = "Ability_Druid_CatForm",
                  ["Feral (Bear)"] = "Ability_Racial_BearForm", Restoration = "Spell_Nature_HealingTouch" },
    }
    for classFile, specs in pairs(ns.SPECS) do
        local icons = SPEC_ICONS[classFile] or {}
        for _, spec in ipairs(specs) do
            local name = icons[spec.label]
            spec.icon = name and ("Interface\\Icons\\" .. name) or nil
        end
    end
end

-- A spec's icon path by class file and spec index (or spec label); nil when unknown.
function ns.SpecIcon(classFile, spec)
    local specs = classFile and ns.SPECS[classFile]
    if not specs then return nil end
    if type(spec) == "number" then
        local s = specs[spec]
        return s and s.icon or nil
    end
    for i = 1, #specs do
        if specs[i].label == spec then return specs[i].icon end
    end
    return nil
end

function ns.GetSpecRole(classFile, specLabel)
    local specs = classFile and ns.SPECS[classFile]
    if not specs or not specLabel then return nil end
    for i = 1, #specs do
        if specs[i].label == specLabel then return specs[i].role end
    end
    return nil
end

ns.ROLES = { "tank", "healer", "melee", "caster", "ranged" }
ns.ROLE_LABELS = { tank = "Tank", healer = "Healer", melee = "Melee", caster = "Caster", ranged = "Ranged" }

---------------------------------------------------------------------------
-- Professions: id = the skill line id (the same on every locale), English name, in Core/Professions.lua's order
---------------------------------------------------------------------------

ns.PROFESSIONS = {
    { id = 171, name = "Alchemy",        primary = true },
    { id = 164, name = "Blacksmithing",  primary = true },
    { id = 333, name = "Enchanting",     primary = true },
    { id = 202, name = "Engineering",    primary = true },
    { id = 755, name = "Jewelcrafting",  primary = true },
    { id = 165, name = "Leatherworking", primary = true },
    { id = 197, name = "Tailoring",      primary = true },
    { id = 186, name = "Mining",         primary = true },
    { id = 182, name = "Herbalism",      primary = true },
    { id = 393, name = "Skinning",       primary = true },
    { id = 185, name = "Cooking" },
    { id = 129, name = "First Aid" },
    { id = 356, name = "Fishing" },
}
ns.PROFESSION_IDS = {}     -- [English name] = skill line id
ns.PROFESSION_NAMES = {}   -- [skill line id] = English name
for _, p in ipairs(ns.PROFESSIONS) do
    ns.PROFESSION_IDS[p.name] = p.id
    ns.PROFESSION_NAMES[p.id] = p.name
end

---------------------------------------------------------------------------
-- Proficiencies at level 70 in TBC (§4.4)
---------------------------------------------------------------------------

local A = ns.ARMOR_SUB
local W = ns.WEAPON_SUB

ns.ARMOR_PRIMARY = {
    WARRIOR = A.PLATE, PALADIN = A.PLATE,
    HUNTER = A.MAIL, SHAMAN = A.MAIL,
    ROGUE = A.LEATHER, DRUID = A.LEATHER,
    PRIEST = A.CLOTH, MAGE = A.CLOTH, WARLOCK = A.CLOTH,
}

-- Misc (0), Cloth (1) and Cosmetic (5) for everyone; heavier armor per class;
-- shields / librams / idols / totems for their classes.
ns.ARMOR_ALLOWED = {
    WARRIOR = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER, A.MAIL, A.PLATE, A.SHIELD },
    PALADIN = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER, A.MAIL, A.PLATE, A.SHIELD, A.LIBRAM },
    HUNTER  = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER, A.MAIL },
    SHAMAN  = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER, A.MAIL, A.SHIELD, A.TOTEM },
    ROGUE   = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER },
    DRUID   = Set { A.MISC, A.CLOTH, A.COSMETIC, A.LEATHER, A.IDOL },
    PRIEST  = Set { A.MISC, A.CLOTH, A.COSMETIC },
    MAGE    = Set { A.MISC, A.CLOTH, A.COSMETIC },
    WARLOCK = Set { A.MISC, A.CLOTH, A.COSMETIC },
}

-- From LootReserve/Libs/ItemCache/ItemCache.lua usableTypes, with its TBC adjustments applied
-- (no one-handed axes for rogues, no polearms for druids). Generic (14) and Fishing Pole (20)
-- are usable by everyone.
ns.WEAPON_ALLOWED = {
    WARRIOR = Set { W.UNARMED, W.AXE1H, W.AXE2H, W.BOWS, W.GUNS, W.MACE1H, W.MACE2H, W.POLEARM,
                    W.SWORD1H, W.SWORD2H, W.STAFF, W.DAGGER, W.CROSSBOW, W.THROWN, W.GENERIC, W.FISHINGPOLE },
    PALADIN = Set { W.AXE1H, W.AXE2H, W.MACE1H, W.MACE2H, W.POLEARM, W.SWORD1H, W.SWORD2H,
                    W.GENERIC, W.FISHINGPOLE },
    HUNTER  = Set { W.UNARMED, W.AXE1H, W.AXE2H, W.BOWS, W.GUNS, W.POLEARM, W.SWORD1H, W.SWORD2H,
                    W.STAFF, W.DAGGER, W.CROSSBOW, W.THROWN, W.GENERIC, W.FISHINGPOLE },
    ROGUE   = Set { W.UNARMED, W.BOWS, W.GUNS, W.MACE1H, W.SWORD1H, W.DAGGER, W.CROSSBOW, W.THROWN,
                    W.GENERIC, W.FISHINGPOLE },
    PRIEST  = Set { W.MACE1H, W.STAFF, W.DAGGER, W.WAND, W.GENERIC, W.FISHINGPOLE },
    SHAMAN  = Set { W.UNARMED, W.AXE1H, W.AXE2H, W.MACE1H, W.MACE2H, W.STAFF, W.DAGGER,
                    W.GENERIC, W.FISHINGPOLE },
    MAGE    = Set { W.SWORD1H, W.STAFF, W.DAGGER, W.WAND, W.GENERIC, W.FISHINGPOLE },
    WARLOCK = Set { W.SWORD1H, W.STAFF, W.DAGGER, W.WAND, W.GENERIC, W.FISHINGPOLE },
    DRUID   = Set { W.UNARMED, W.MACE1H, W.MACE2H, W.STAFF, W.DAGGER, W.GENERIC, W.FISHINGPOLE },
}

-- Weapon subclasses restricted to some classes (anything else, e.g. warglaives, is treated as usable).
ns.WEAPON_RESTRICTED = {}
for _, allowed in pairs(ns.WEAPON_ALLOWED) do
    for sub in pairs(allowed) do ns.WEAPON_RESTRICTED[sub] = true end
end
ns.WEAPON_RESTRICTED[W.GENERIC] = nil
ns.WEAPON_RESTRICTED[W.FISHINGPOLE] = nil

ns.DUAL_WIELD = { WARRIOR = true, ROGUE = true, HUNTER = true, SHAMAN = true }

---------------------------------------------------------------------------
-- Award reasons (Addendum G §40): the `r` field of a loot log entry
---------------------------------------------------------------------------

-- In menu order. counts = the award counts as loot received ("won N" and the award history);
-- owns = the winner keeps the item (a disenchant / guild bank award does not mark it awarded on their list).
ns.AWARD_REASONS = {
    { key = "bis",  label = "BiS",        counts = true,  owns = true,  tip = "Best-in-slot (main pick) for the winner" },
    { key = "alt",  label = "Alt",        counts = true,  owns = true,  tip = "The winner's alt (backup / upgrade-path) pick" },
    { key = "up",   label = "Upgrade",    counts = true,  owns = true,  tip = "A main-spec upgrade that is not on their BiS list" },
    { key = "os",   label = "Offspec",    counts = false, owns = true,  tip = "Off-spec: not counted as loot received" },
    { key = "de",   label = "Disenchant", counts = false, owns = false, tip = "Given to the disenchanter: not counted as loot received" },
    { key = "bank", label = "Guild bank", counts = false, owns = false, tip = "Given to the guild bank character: not counted as loot received" },
}
ns.AWARD_REASON = {}
for _, r in ipairs(ns.AWARD_REASONS) do ns.AWARD_REASON[r.key] = r end

-- 1.3.5: a Loot Log entry counts as loot received ("won N", dry streaks, items received) when its reason counts and
-- the item is gear (ItemDB:IsGear): a bag, a recipe, a mount or materials never do. Unknown items count.
function ns.AwardCounts(e)
    if type(e) ~= "table" then return false end
    local r = e.r and ns.AWARD_REASON[e.r]
    if r and not r.counts then return false end
    local I = ns.ItemDB
    return not (I and I.IsGear and I:IsGear(e.i) == false)
end

-- Label of a reason key ("BiS"), or nil for no / an unknown reason.
function ns.ReasonLabel(key)
    local r = type(key) == "string" and ns.AWARD_REASON[key]
    return r and r.label or nil
end

-- The default reason of a roll winner's BiS tier (1 main, 2 alt, 3 off-spec list, else not listed).
function ns.ReasonForTier(tier)
    if tier == 1 then return "bis" end
    if tier == 2 then return "alt" end
    if tier == 3 then return "os" end
    return "up"
end

---------------------------------------------------------------------------
-- Off-spec lists (Addendum H): data.os = label, data.op = phases, data.ox = disabled slots (Pre-raid: opr / opx)
---------------------------------------------------------------------------

-- The list data has an off spec.
function ns.HasOffSpec(data)
    return type(data) == "table" and (data.os ~= nil or data.op ~= nil or data.ox ~= nil or data.opr ~= nil
        or data.opx ~= nil) or false
end

-- A read-only view of one list of a ListData table, shaped like ListData ({ v, cl, sp, ph, dx, pr, px, ob, eq }):
-- list "os" = the off-spec picks with the shared obtained / equipped state; anything else = data itself.
function ns.ListView(data, list)
    if type(data) ~= "table" or list ~= "os" then return data end
    return {
        v = data.v, cl = data.cl, sp = type(data.os) == "string" and data.os or "",
        ph = type(data.op) == "table" and data.op or {}, dx = type(data.ox) == "table" and data.ox or nil,
        pr = type(data.opr) == "table" and data.opr or nil, px = type(data.opx) == "table" and data.opx or nil,
        ge = type(data.oge) == "table" and data.oge or nil,
        ob = data.ob, eq = data.eq, offSpec = true,
    }
end

-- A record ({ data = }) whose data is the view of `list` (other fields copied), for views that take records.
function ns.ListRecordView(rec, list)
    if type(rec) ~= "table" or list ~= "os" then return rec end
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    out.data = ns.ListView(rec.data, "os")
    return out
end

---------------------------------------------------------------------------
-- Colors & textures (§4.5)
---------------------------------------------------------------------------

ns.COLORS = {
    main     = { 0.98, 0.78, 0.22 },   -- BiS gold (text badges)
    alt      = { 0.41, 0.80, 0.94 },   -- alt blue
    obtained = { 0.30, 0.90, 0.40 },
    needed   = { 1, 1, 1 },
    muted    = { 0.55, 0.55, 0.55 },
    warn     = { 1.00, 0.55, 0.20 },
    bad      = { 1.00, 0.30, 0.30 },
    council  = { 1.00, 0.50, 0.00 },   -- addon accent (#ff8000)
    offspec  = { 0.72, 0.60, 0.92 },   -- off-spec list (Addendum H)
}

ns.TEX = {
    check      = "Interface\\RaidFrame\\ReadyCheck-Ready",
    cross      = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting    = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    slotBg     = "Interface\\Buttons\\UI-Quickslot2",
    border     = "Interface\\Common\\WhiteIconFrame",
    hilight    = "Interface\\Buttons\\ButtonHilight-Square",
    rowHilight = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
    star       = "Interface\\AddOns\\DisasterZone\\Media\\Icons\\bis",
    bag        = "Interface\\Buttons\\Button-Backpack-Up",
    bank       = "Interface\\Icons\\INV_Misc_Bag_10_Blue",
    classIcons = "Interface\\TargetingFrame\\UI-Classes-Circles",   -- with CLASS_ICON_TCOORDS
    question   = 134400,                                            -- INV_Misc_QuestionMark fileID
}

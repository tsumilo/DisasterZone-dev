if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Classes/Paladin.lua", ...) then return end -- DisasterZone: paladin spells.
-- Paladin spell data for the class tools (Core/ClassKit.lua): blessings, auras and their ranks, by spell id, so names
-- come from the client in any language. The indexes are Pally Power's (its wire protocol sends them as digits): see
-- dev/docs/research/pallypower.md §3. Ranks are lowest first, each { spellID, lowest target level }.
local addonName, ns = ...

local ICON = "Interface\\Icons\\"

ns.ClassData = ns.ClassData or {}

ns.ClassData.PALADIN = {
    -- Pally Power's class order (its 9-character class strings); the planner shows them in DISPLAY order
    CLASSES = { "WARRIOR", "ROGUE", "PRIEST", "DRUID", "PALADIN", "HUNTER", "MAGE", "WARLOCK", "SHAMAN" },
    DISPLAY = { "WARRIOR", "ROGUE", "HUNTER", "DRUID", "SHAMAN", "PALADIN", "PRIEST", "MAGE", "WARLOCK" },

    -- 1..6 can be Greater Blessings; 7 (Sacrifice) is for single players only and never on yourself
    BLESSINGS = {
        { key = "wisdom", short = "Wisdom", icon = ICON .. "Spell_Holy_SealOfWisdom",
          gicon = ICON .. "Spell_Holy_GreaterBlessingofWisdom",
          ranks = { { 19742, 4 }, { 19850, 14 }, { 19852, 24 }, { 19853, 34 }, { 19854, 44 }, { 25290, 50 }, { 27142, 55 } },
          granks = { { 25894, 44 }, { 25918, 50 }, { 27143, 55 } } },
        { key = "might", short = "Might", icon = ICON .. "Spell_Holy_FistOfJustice",
          gicon = ICON .. "Spell_Holy_GreaterBlessingofKings",
          ranks = { { 19740, 0 }, { 19834, 4 }, { 19835, 12 }, { 19836, 22 }, { 19837, 32 }, { 19838, 42 }, { 25291, 50 },
                    { 27140, 60 } },
          granks = { { 25782, 42 }, { 25916, 50 }, { 27141, 60 } } },
        { key = "kings", short = "Kings", icon = ICON .. "Spell_Magic_MageArmor",
          gicon = ICON .. "Spell_Magic_GreaterBlessingofKings",
          ranks = { { 20217, 10 } }, granks = { { 25898, 50 } } },
        { key = "salvation", short = "Salvation", icon = ICON .. "Spell_Holy_SealOfSalvation",
          gicon = ICON .. "Spell_Holy_GreaterBlessingofSalvation",
          ranks = { { 1038, 16 } }, granks = { { 25895, 50 } } },
        { key = "light", short = "Light", icon = ICON .. "Spell_Holy_PrayerOfHealing02",
          gicon = ICON .. "Spell_Holy_GreaterBlessingofLight",
          ranks = { { 19977, 30 }, { 19978, 40 }, { 19979, 50 }, { 27144, 59 } },
          granks = { { 25890, 50 }, { 27145, 59 } } },
        { key = "sanctuary", short = "Sanctuary", icon = ICON .. "Spell_Nature_LightningShield",
          gicon = ICON .. "Spell_Holy_GreaterBlessingofSanctuary",
          ranks = { { 20911, 20 }, { 20912, 30 }, { 20913, 40 }, { 20914, 50 }, { 27168, 60 } },
          granks = { { 25899, 50 }, { 27169, 60 } } },
        { key = "sacrifice", short = "Sacrifice", icon = ICON .. "Spell_Holy_SealOfSacrifice", single = true,
          ranks = { { 6940, 36 }, { 20729, 44 }, { 27147, 52 }, { 27148, 60 } } },
    },
    GREATER_MAX = 6,
    GREATER_MIN_LEVEL = 50,      -- Pally Power casts a Greater Blessing only on a target above level 49

    AURAS = {
        { key = "devotion", short = "Devotion", icon = ICON .. "Spell_Holy_DevotionAura",
          ranks = { 465, 10290, 643, 10291, 1032, 10292, 10293, 27149 } },
        { key = "retribution", short = "Retribution", icon = ICON .. "Spell_Holy_AuraOfLight",
          ranks = { 7294, 10298, 10299, 10300, 10301, 27150 } },
        { key = "concentration", short = "Concentration", icon = ICON .. "Spell_Holy_MindSooth", ranks = { 19746 } },
        { key = "shadow", short = "Shadow Resistance", icon = ICON .. "Spell_Shadow_SealOfKings",
          ranks = { 19876, 19895, 19896, 27151 } },
        { key = "frost", short = "Frost Resistance", icon = ICON .. "Spell_Frost_WizardMark",
          ranks = { 19888, 19897, 19898, 27152 } },
        { key = "fire", short = "Fire Resistance", icon = ICON .. "Spell_Fire_SealOfFire",
          ranks = { 19891, 19899, 19900, 27153 } },
        { key = "sanctity", short = "Sanctity", icon = ICON .. "Spell_Holy_MindVision", ranks = { 20218 } },
        { key = "crusader", short = "Crusader", icon = ICON .. "Spell_Holy_CrusaderAura", ranks = { 32223 } },
    },

    -- Talents the planner shows and Pally Power's SELF message carries, found by the talent's icon being the
    -- spell's (as Pally Power does, so both report the same numbers): blessings 1, 2, 6 and auras 1, 2, 3, 7
    BLESSING_TALENTS = { [1] = true, [2] = true, [6] = true },
    AURA_TALENTS = { [1] = true, [2] = true, [3] = true, [7] = true },

    RIGHTEOUS_FURY = 25780,
    RF_ICON = ICON .. "Spell_Holy_SealOfFury",
    SYMBOL_OF_KINGS = 21177,
    SYMBOL_ICON = ICON .. "INV_Misc_Symbolofkings_01",

    DURATION = 600,              -- a normal blessing (TBC)
    GDURATION = 1800,            -- a Greater Blessing
}

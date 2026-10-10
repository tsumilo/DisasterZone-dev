if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Classes/Shaman.lua", ...) then return end -- DisasterZone: shaman spells.
-- Shaman spell data for the class tools (Core/ClassKit.lua): totems by element, Heroism / Bloodlust, Earth Shield and
-- the weapon imbues, by spell id, so names come from the client in any language. Elements and totem indexes are
-- ShamanPower's (its wire protocol sends them as digits): 1 Earth, 2 Fire, 3 Water, 4 Air; see
-- dev/docs/research/shamanpower.md. A totem's spell id is its first rank: casting by name picks the highest one known.
local addonName, ns = ...

local ICON = "Interface\\Icons\\"

ns.ClassData = ns.ClassData or {}

ns.ClassData.SHAMAN = {
    ELEMENTS = {
        { key = "earth", name = "Earth", color = { 0.55, 0.76, 0.32 }, slot = 2 },
        { key = "fire", name = "Fire", color = { 1, 0.48, 0.18 }, slot = 1 },
        { key = "water", name = "Water", color = { 0.24, 0.71, 1 }, slot = 3 },
        { key = "air", name = "Air", color = { 0.70, 0.52, 1 }, slot = 4 },
    },

    -- per element, ShamanPower's index order. fx: what it does, in a few words (menus, tooltips). aura: it puts a
    -- buff on the party that addons can see (range checks; Windfury and Flametongue sit on the weapon and can't be
    -- seen on others). extra: situational (the planner's "More" submenu). dur: seconds (the demo's timers).
    TOTEMS = {
        {   -- Earth
            { key = "soe", id = 8075, short = "Strength of Earth", icon = ICON .. "Spell_Nature_EarthBindTotem",
              fx = "Strength for melee", aura = true, dur = 120 },
            { key = "stoneskin", id = 8071, short = "Stoneskin", icon = ICON .. "Spell_Nature_StoneSkinTotem",
              fx = "Less melee damage taken", aura = true, dur = 120 },
            { key = "tremor", id = 8143, short = "Tremor", icon = ICON .. "Spell_Nature_TremorTotem",
              fx = "Breaks fear, charm, sleep", dur = 120 },
            { key = "earthbind", id = 2484, short = "Earthbind", icon = ICON .. "Spell_Nature_StrengthOfEarthTotem02",
              fx = "Slows enemies nearby", dur = 45 },
            { key = "stoneclaw", id = 5730, short = "Stoneclaw", icon = ICON .. "Spell_Nature_StoneClawTotem",
              fx = "Taunts enemies nearby", dur = 15, extra = true },
            { key = "earthele", id = 2062, short = "Earth Elemental", icon = ICON .. "Spell_Nature_EarthElemental_Totem",
              fx = "A tanking elemental, 20 min cd", dur = 120, extra = true },
        },
        {   -- Fire
            { key = "tow", id = 30706, short = "Totem of Wrath", icon = ICON .. "Spell_Fire_TotemOfWrath",
              fx = "+3% spell hit and crit", aura = true, dur = 120 },
            { key = "searing", id = 3599, short = "Searing", icon = ICON .. "Spell_Fire_SearingTotem",
              fx = "Fire damage", dur = 60 },
            { key = "magma", id = 8190, short = "Magma", icon = ICON .. "Spell_Fire_SelfDestruct",
              fx = "Fire damage around it", dur = 20, extra = true },
            { key = "firenova", id = 1535, short = "Fire Nova", icon = ICON .. "Spell_Fire_SealOfFire",
              fx = "One fire blast", dur = 5, extra = true },
            { key = "ftt", id = 8227, short = "Flametongue", icon = ICON .. "Spell_Nature_GuardianWard",
              fx = "Spell power on weapons", dur = 120 },
            { key = "frostres", id = 8181, short = "Frost Resistance", icon = ICON .. "Spell_FrostResistanceTotem_01",
              fx = "Frost resistance", aura = true, dur = 120 },
            { key = "fireele", id = 2894, short = "Fire Elemental", icon = ICON .. "Spell_Fire_Elemental_Totem",
              fx = "A fire elemental, 20 min cd", dur = 120, extra = true },
        },
        {   -- Water
            { key = "manaspring", id = 5675, short = "Mana Spring", icon = ICON .. "Spell_Nature_ManaRegenTotem",
              fx = "Mana every 2 sec", aura = true, dur = 120 },
            { key = "hstream", id = 5394, short = "Healing Stream", icon = ICON .. "INV_Spear_04",
              fx = "Health every 2 sec", aura = true, dur = 120 },
            { key = "manatide", id = 16190, short = "Mana Tide", icon = ICON .. "Spell_Frost_SummonWaterElemental",
              fx = "Party mana, 5 min cd", dur = 12 },
            { key = "poison", id = 8166, short = "Poison Cleansing", icon = ICON .. "Spell_Nature_PoisonCleansingTotem",
              fx = "Removes poisons", dur = 120, extra = true },
            { key = "disease", id = 8170, short = "Disease Cleansing", icon = ICON .. "Spell_Nature_DiseaseCleansingTotem",
              fx = "Removes diseases", dur = 120, extra = true },
            { key = "fireres", id = 8184, short = "Fire Resistance", icon = ICON .. "Spell_FireResistanceTotem_01",
              fx = "Fire resistance", aura = true, dur = 120 },
        },
        {   -- Air
            { key = "wf", id = 8512, short = "Windfury", icon = ICON .. "Spell_Nature_Windfury",
              fx = "Extra melee attacks", dur = 120 },
            { key = "goa", id = 8835, short = "Grace of Air", icon = ICON .. "Spell_Nature_InvisibilityTotem",
              fx = "Agility", aura = true, dur = 120 },
            { key = "woa", id = 3738, short = "Wrath of Air", icon = ICON .. "Spell_Nature_SlowingTotem",
              fx = "+101 spell power", aura = true, dur = 120 },
            { key = "tranq", id = 25908, short = "Tranquil Air", icon = ICON .. "Spell_Nature_Brilliance",
              fx = "Less threat", aura = true, dur = 120 },
            { key = "grounding", id = 8177, short = "Grounding", icon = ICON .. "Spell_Nature_GroundingTotem",
              fx = "Takes one harmful spell", dur = 45, extra = true },
            { key = "natres", id = 10595, short = "Nature Resistance", icon = ICON .. "Spell_Nature_NatureResistanceTotem",
              fx = "Nature resistance", aura = true, dur = 120 },
            { key = "windwall", id = 15107, short = "Windwall", icon = ICON .. "Spell_Nature_EarthBind",
              fx = "Less ranged damage taken", aura = true, dur = 120, extra = true },
            { key = "sentry", id = 6495, short = "Sentry", icon = ICON .. "Spell_Nature_RemoveCurse",
              fx = "Lets you see around it", dur = 300, extra = true },
        },
    },

    TWIST_WINDOW = 10,           -- Windfury stays on the party's weapons this long after the totem is replaced
    WINDFURY = { 4, 1 },         -- { element, index }
    MANA_TIDE = { 3, 3 },
    TOTEM_OF_WRATH = { 2, 1 },

    HEROISM = 32182, HEROISM_ICON = ICON .. "Ability_Shaman_Heroism",          -- Alliance (Draenei)
    BLOODLUST = 2825, BLOODLUST_ICON = ICON .. "Spell_Nature_Bloodlust",        -- Horde
    -- Heroism / Bloodlust reach the whole raid on the Anniversary client, and Exhaustion / Sated stops a second one
    -- for 10 minutes: one shaman casts it (pull, execute or on call), another can be the backup if they die, the rest
    -- don't. Synced among DisasterZone users only (DZHERO).
    HERO_WHEN = {
        { key = "pull", text = "Pull", long = "Casts it on the pull", casts = true },
        { key = "execute", text = "< 30%", long = "Casts it when the boss is under 30%", casts = true },
        { key = "call", text = "On call", long = "Casts it when the leader calls it", casts = true },
        { key = "backup", text = "Backup", long = "Casts it only if the one who should is dead" },
        { key = "none", text = "", long = "Doesn't cast it (someone else does)" },
    },

    EARTH_SHIELD = 974, EARTH_SHIELD_ICON = ICON .. "Spell_Nature_SkinofEarth", EARTH_SHIELD_CHARGES = 6,

    IMBUES = {
        { key = "wf", id = 8232, short = "Windfury Weapon", icon = ICON .. "Spell_Nature_Cyclone" },
        { key = "ft", id = 8024, short = "Flametongue Weapon", icon = ICON .. "Spell_Fire_FlameTounge" },
        { key = "fb", id = 8033, short = "Frostbrand Weapon", icon = ICON .. "Spell_Frost_FrostBrand" },
        { key = "rb", id = 8017, short = "Rockbiter Weapon", icon = ICON .. "Spell_Nature_RockBiter" },
    },

    SPEC_ICONS = { Elemental = ICON .. "Spell_Nature_Lightning", Enhancement = ICON .. "Spell_Nature_LightningShield",
        Restoration = ICON .. "Spell_Nature_MagicImmunity" },
}

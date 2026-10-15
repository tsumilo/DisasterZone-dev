if DisasterZoneBoot and DisasterZoneBoot.Run("Data/GroupKinds.lua", ...) then return end -- DisasterZone Data/GroupKinds.lua
-- The kinds of groups the Groups tab lists (Core/DungeonRuns.lua) besides 5-man dungeons, and what each kind is made of.
-- Every list here is in wire order (a group goes out as kind index + activity indices): never reorder, only append.
local addonName, ns = ...

ns.Data = ns.Data or {}
ns.Data.GroupKinds = {
    -- kind keys; index 1 is the 5-man dungeon (Core/DungeonRuns.lua COMPLEXES), which keeps its own wire fields
    kinds = { "dungeon", "raid", "quest", "pvp", "other" },

    -- raids by the item data's key (Data/Items.lua, Data/Raids.lua RaidMeta): size = the places a group lists by default
    raids = {
        { key = "Karazhan", size = 10 },
        { key = "GruulsLair", size = 25 },
        { key = "MagtheridonsLair", size = 25 },
        { key = "SerpentshrineCavern", size = 25 },
        { key = "TempestKeep", size = 25 },
        { key = "HyjalSummit", size = 25 },
        { key = "BlackTemple", size = 25 },
        { key = "ZulAman", size = 10 },
        { key = "SunwellPlateau", size = 25 },
    },

    -- PvP: arenas (a bracket), battlegrounds (a premade of the battleground's size), world PvP (a raid, no queue)
    pvp = {
        { key = "arena2", name = "Arena 2v2", size = 2, mode = "arena", bracket = 2 },
        { key = "arena3", name = "Arena 3v3", size = 3, mode = "arena", bracket = 3 },
        { key = "arena5", name = "Arena 5v5", size = 5, mode = "arena", bracket = 5 },
        { key = "wsg", name = "Warsong Gulch", size = 10, mode = "bg" },
        { key = "ab", name = "Arathi Basin", size = 15, mode = "bg" },
        { key = "eots", name = "Eye of the Storm", size = 15, mode = "bg" },
        { key = "av", name = "Alterac Valley", size = 40, mode = "bg" },
        { key = "halaa", name = "Halaa", size = 40, mode = "world" },
        { key = "towers", name = "Spirit Towers", size = 40, mode = "world" },
        { key = "forts", name = "Hellfire Fortifications", size = 40, mode = "world" },
    },

    -- anything else: what it is for (the note says the rest)
    other = {
        { key = "attune", name = "Attunement" },
        { key = "worldboss", name = "World boss" },
        { key = "farm", name = "Farming" },
        { key = "rep", name = "Reputation" },
        { key = "any", name = "Anything else" },
    },

    -- a raid group's loot method: rolls, soft reserves (n each), the loot council (guild members only)
    loot = { "roll", "sr", "lc" },
}

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

    -- PvP: arenas (a bracket), battlegrounds (a premade of the battleground's size), world PvP (a raid, no queue).
    -- screen = its loading screen (2048 x 2048 shown at 4:3; cx, cy = the centre a card shows), icon = its icon
    pvp = {
        { key = "arena2", name = "Arena 2v2", size = 2, mode = "arena", bracket = 2, screen = 131828, cx = 0.5, cy = 0.5, icon = 236329 },
        { key = "arena3", name = "Arena 3v3", size = 3, mode = "arena", bracket = 3, screen = 131853, cx = 0.5, cy = 0.55, icon = 236336 },
        { key = "arena5", name = "Arena 5v5", size = 5, mode = "arena", bracket = 5, screen = 131867, cx = 0.5, cy = 0.5, icon = 236343 },
        { key = "wsg", name = "Warsong Gulch", size = 10, mode = "bg", screen = 131883, cx = 0.5, cy = 0.5, icon = 134420 },
        { key = "ab", name = "Arathi Basin", size = 15, mode = "bg", screen = 131820, cx = 0.5, cy = 0.5, icon = 133282 },
        { key = "eots", name = "Eye of the Storm", size = 15, mode = "bg", screen = 131855, cx = 0.5, cy = 0.45, icon = 136032 },
        { key = "av", name = "Alterac Valley", size = 40, mode = "bg", screen = 131861, cx = 0.5, cy = 0.45, icon = 133308 },
        { key = "halaa", name = "Halaa", size = 40, mode = "world", screen = 131853, cx = 0.3, cy = 0.7, icon = 134422 },
        { key = "towers", name = "Spirit Towers", size = 40, mode = "world", screen = 131821, cx = 0.4, cy = 0.5, icon = 132336 },
        { key = "forts", name = "Hellfire Fortifications", size = 40, mode = "world", screen = 131845, cx = 0.5, cy = 0.45, icon = 132336 },
    },

    -- anything else: what it is for (the note says the rest)
    other = {
        { key = "attune", name = "Attunement" },
        { key = "worldboss", name = "World boss" },
        { key = "farm", name = "Farming" },
        { key = "rep", name = "Reputation" },
        { key = "any", name = "Anything else" },
    },

    -- the art of the kinds that have no instance of their own: a loading screen (cx, cy as above) and an LFG icon
    art = {
        quest = { screen = 131860, cx = 0.5, cy = 0.55, icon = 136349 },
        other = { screen = 131860, cx = 0.35, cy = 0.55, icon = 136366 },
    },

    -- a raid group's loot method: rolls, soft reserves (n each), the loot council (guild members only)
    loot = { "roll", "sr", "lc" },
}

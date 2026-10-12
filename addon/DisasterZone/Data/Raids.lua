if DisasterZoneBoot and DisasterZoneBoot.Run("Data/Raids.lua", ...) then return end -- DisasterZone Data/Raids.lua
-- Raid meta table (short names, planner keys, art, map ids): one home for raid information (refactor 1D).
local addonName, ns = ...

-- Keyed by the item data's raid key (Data/Items.lua ns.Data.Raids[i].key). Read it through ns.ItemDB (GetRaidByInstance,
-- GetRaidByPlanKey, PlanKeyOf, ItemKeyOf, RaidShort, RaidArt), which take either key form.
--   short       the short name the UI shows ("Kara", ..., Sunwell = "SWP": user decision D4)
--   planKey     the raid planner's instance key (Core/RaidPlan.lua INSTANCES). Saved raids and the sync use these keys
--               (and saved records use the item keys): both forms stay valid forever.
--   instanceID  the instance map id (GetInstanceInfo's 8th value, the raid log's key)
--   art         the raid's loading screen (2048 x 2048 texture shown at 4:3): { fdid, l, r, t, b } = the whole picture
--               under the game's logo band, plus cx, cy = the centre a cropped card shows (a share of the width / height)
--   artTop      where the picture starts under the logo band (a share of the height)
--   mapNames    the names the client may give the raid's map (lower case, found as a part of the name)
--   mapIDs      the raid's uiMapIDs as the TBC clients number them (a fallback when the names don't match)
--   icon        the raid's LFG icon (a file id: My BiS's source rows)
ns.Data = ns.Data or {}

local ART_TOP = 0.29

local function Art(fdid, cx, cy)
    return { fdid, 0, 1, ART_TOP, 1, cx = cx, cy = cy }
end

ns.Data.RaidMeta = {
    Karazhan = { icon = 136343, short = "Kara", planKey = "kara", instanceID = 532, art = Art(131849, 0.30, 0.45), artTop = ART_TOP,
                 mapNames = { "karazhan" },
                 mapIDs = { 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366 } },
    GruulsLair = { icon = 136337, short = "Gruul", planKey = "gruul", instanceID = 565, art = Art(131842, 0.30, 0.45), artTop = ART_TOP,
                   mapNames = { "gruul" }, mapIDs = { 330 } },
    MagtheridonsLair = { icon = 136340, short = "Mag", planKey = "mag", instanceID = 544, art = Art(131846, 0.50, 0.42),
                         artTop = ART_TOP, mapNames = { "magtheridon" }, mapIDs = { 331 } },
    SerpentshrineCavern = { icon = 136356, short = "SSC", planKey = "ssc", instanceID = 548, art = Art(131832, 0.32, 0.46),
                            artTop = ART_TOP, mapNames = { "serpentshrine" }, mapIDs = { 332 } },
    TempestKeep = { icon = 136362, short = "TK", planKey = "tk", instanceID = 550, art = Art(131875, 0.50, 0.40), artTop = ART_TOP,
                    mapNames = { "tempest keep", "the eye" }, mapIDs = { 334 } },
    HyjalSummit = { icon = 136341, short = "Hyjal", planKey = "hyjal", instanceID = 534, art = Art(131847, 0.40, 0.45), artTop = ART_TOP,
                    mapNames = { "hyjal" }, mapIDs = { 329 } },
    BlackTemple = { icon = 136328, short = "BT", planKey = "bt", instanceID = 564, art = Art(131826, 0.30, 0.56), artTop = ART_TOP,
                    mapNames = { "black temple" }, mapIDs = { 339, 340, 341, 342, 343, 344, 345, 346 } },
    ZulAman = { icon = 136367, short = "ZA", planKey = "za", instanceID = 568, art = Art(131884, 0.30, 0.45), artTop = ART_TOP,
                mapNames = { "zul'aman", "zul aman" }, mapIDs = { 333 } },
    SunwellPlateau = { icon = 136361, short = "SWP", planKey = "swp", instanceID = 580, art = Art(131873, 0.55, 0.50), artTop = ART_TOP,
                       mapNames = { "sunwell" }, mapIDs = { 335, 336 } },
    -- (not an instance: no planner key, map or art of its own)
    WorldBosses = { short = "World" },
}

-- Anything else (the raid planner's "other", an unknown key): no short name, a generic loading screen.
ns.Data.RaidMetaOther = { planKey = "other", art = Art(131860, 0.50, 0.45), artTop = ART_TOP }

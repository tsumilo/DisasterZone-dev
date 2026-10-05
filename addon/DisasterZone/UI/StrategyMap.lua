if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategyMap.lua", ...) then return end -- DisasterZone: UI/StrategyMap.lua
-- The map canvas of a strategy page (Addendum K): the background (a built-in instance map, panned and zoomed by the
-- author, or a blank grid) and the drawn elements (zones, arrows / lines, icons, text, slot tokens). Everything is in
-- board units (1000 x 666) so a board looks the same at any size.
-- Editing: one tool at a time (select / move, pan the map, circle, rectangle, arrow, line, icon, text). Selection
-- takes several drawings (Shift-click, a box on empty map) and groups (Ctrl+G) move and link as one. Shift-drag a
-- drawing onto a table to link it to a job; linked drawings show the assigned players' names. Keyboard (from the
-- board): Del, Ctrl+C / X / V / D / A / G, arrows. All mouse input goes through the canvas itself, which hit-tests
-- the drawings (small ones before zones).
-- Also the shared look of the board: colours, icons (raid marks, roles, classes, spells, items) and the map list.
local addonName, ns = ...

local MapUI = ns:NewModule("StrategyMapUI")

local floor, max, min, abs, sqrt, ceil = math.floor, math.max, math.min, math.abs, math.sqrt, math.ceil
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\"
local TEX_DISC, TEX_RING, TEX_ARROW = MEDIA .. "disc", MEDIA .. "ring", MEDIA .. "arrow"
MapUI.TEX = { disc = TEX_DISC, ring = TEX_RING, arrow = TEX_ARROW }

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function SO() return ns.StrategyObjects end

local BW, BH = 1000, 666

-- An encounter asset's icon on the map (a texture: a path or a file ID): its definition's (icon: a file under
-- Interface\Icons or a file ID; item: that item's icon); else a game object a gear, a creature nil (its portrait).
local function AssetIcon(key)
    local def = SO().DefOf(key)
    if def and def.item and GetItemIcon then
        local icon = GetItemIcon(def.item)
        if icon then return icon end
    end
    local icon = def and def.icon
    if type(icon) == "number" then return icon end
    if type(icon) == "string" then return "Interface\\Icons\\" .. icon end
    return SO().Parse(key) == "obj" and "Interface\\Icons\\INV_Misc_Gear_01" or nil
end

---------------------------------------------------------------------------
-- Colours and icons (shared with the blocks and the board)
---------------------------------------------------------------------------

MapUI.COLORS = {
    { 0.90, 0.22, 0.22, "Red" },
    { 0.25, 0.60, 1.00, "Blue" },
    { 1.00, 0.60, 0.10, "Orange" },
    { 0.30, 0.85, 0.30, "Green" },
    { 0.70, 0.40, 1.00, "Purple" },
    { 1.00, 0.90, 0.20, "Yellow" },
    { 0.20, 0.90, 0.90, "Cyan" },
    { 1.00, 0.45, 0.75, "Pink" },
    { 1.00, 1.00, 1.00, "White" },
    { 0.60, 0.60, 0.60, "Grey" },
    { 0.60, 0.40, 0.22, "Brown" },
    { 0.05, 0.05, 0.05, "Black" },
}
local COLORS = MapUI.COLORS

function MapUI:Color(i)
    local c = COLORS[i or 1] or COLORS[1]
    return c[1], c[2], c[3]
end

function MapUI:ColorHex(i)
    local r, g, b = self:Color(i)
    return ("%02x%02x%02x"):format(floor(r * 255), floor(g * 255), floor(b * 255))
end

-- A coloured square for menus.
function MapUI:Swatch(i)
    return "|cff" .. self:ColorHex(i) .. "\226\150\160|r"
end

local ROLE_ICON = {
    tank = "Ability_Warrior_DefensiveStance", healer = "Spell_Holy_FlashHeal",
    melee = "Ability_DualWield", ranged = "Ability_Marksmanship",
}
local ROLE_NAME = { tank = "Tank", healer = "Healer", melee = "Melee", ranged = "Ranged" }
MapUI.ROLE_NAME = ROLE_NAME

local RT_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

-- Common raid tactics icons (Interface\Icons file names).
MapUI.SPELL_ICONS = {
    { "Spell_Fire_SelfDestruct", "Fire / Flamestrike" },
    { "Spell_Frost_IceStorm", "Blizzard / frost" },
    { "Spell_Holy_InnerFire", "Consecration" },
    { "Spell_Nature_CorrosiveBreath", "Poison" },
    { "Spell_Shadow_ShadowWordPain", "Shadow" },
    { "Spell_Nature_Lightning", "Lightning / Innervate" },
    { "Spell_Nature_BloodLust", "Bloodlust / Heroism" },
    { "Spell_Holy_PowerInfusion", "Power Infusion" },
    { "Ability_Hunter_Misdirection", "Misdirection" },
    { "Ability_Kick", "Interrupt" },
    { "Spell_Frost_IceShock", "Counterspell" },
    { "Spell_Shadow_CurseOfTounges", "Curse of Tongues" },
    { "Spell_Shadow_CurseOfMannoroth", "Curse of Weakness" },
    { "Spell_Holy_SealOfProtection", "Blessing of Protection" },
    { "Spell_Holy_DivineIntervention", "Divine Shield" },
    { "Spell_Holy_DispelMagic", "Dispel" },
    { "Spell_Holy_Excorcism", "Fear Ward" },
    { "Spell_Holy_PrayerOfHealing02", "Group heal" },
    { "Ability_Warrior_ShieldWall", "Shield Wall / cooldown" },
    { "Spell_Nature_Reincarnation", "Taunt" },
    { "Spell_Nature_ResistNature", "Nature resistance" },
    { "Spell_Shadow_AntiShadow", "Shadow resistance" },
    { "Spell_Fire_FireArmor", "Fire resistance" },
    { "Spell_Frost_WizardMark", "Frost resistance" },
    { "INV_Potion_76", "Potion" },
    { "INV_Misc_Bomb_05", "Bomb / explosion" },
    { "Ability_Rogue_Sprint", "Run / move" },
    { "Spell_Arcane_Blink", "Blink / teleport" },
    { "Spell_ChargePositive", "Plus charge" },
    { "Spell_ChargeNegative", "Minus charge" },
    { "INV_Misc_Bone_HumanSkull_01", "Danger" },
    { "INV_Misc_QuestionMark", "Question mark" },
}

-- Sets a Texture region to an icon key (see Core/Strategy.lua). Returns true when known.
function MapUI:SetIcon(tex, key)
    tex:SetTexCoord(0, 1, 0, 1)
    tex:SetVertexColor(1, 1, 1, 1)
    if tex.SetDesaturated then tex:SetDesaturated(false) end
    if type(key) ~= "string" then
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        return false
    end
    local rt = key:match("^rt([1-8])$")
    if rt then
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. rt)
        return true
    end
    local disp = key:match("^boss:(%d+)$")
    if disp then
        if SetPortraitTextureFromCreatureDisplayID then
            SetPortraitTextureFromCreatureDisplayID(tex, tonumber(disp))
            return true
        end
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        return false
    end
    local cls = key:match("^cls:(%u+)$")
    if cls then
        UI():ClassIcon(tex, cls)
        return true
    end
    local role = key:match("^role:(%l+)$")
    if role and ROLE_ICON[role] then
        tex:SetTexture("Interface\\Icons\\" .. ROLE_ICON[role])
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return true
    end
    if SO().Parse(key) then
        local icon = AssetIcon(key)
        local disp = not icon and SO().Creature(key)
        if disp and SetPortraitTextureFromCreatureDisplayID then
            SetPortraitTextureFromCreatureDisplayID(tex, disp)
            return true
        end
        tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return icon ~= nil
    end
    local sp = key:match("^sp:(%d+)$")
    if sp then
        local icon = GetSpellTexture and GetSpellTexture(tonumber(sp))
        tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return icon ~= nil
    end
    local it = key:match("^it:(%d+)$")
    if it then
        local icon = GetItemIcon and GetItemIcon(tonumber(it))
        tex:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        return icon ~= nil
    end
    local file = key:match("^i:(.+)$")
    tex:SetTexture("Interface\\Icons\\" .. (file or "INV_Misc_QuestionMark"))
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    return file ~= nil
end

-- An icon key as an inline text texture.
function MapUI:IconString(key, size)
    size = size or 14
    if type(key) ~= "string" then return "" end
    local rt = key:match("^rt([1-8])$")
    if rt then return ("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%s:%d|t"):format(rt, size) end
    local cls = key:match("^cls:(%u+)$")
    if cls then
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
        if c then
            return ("|TInterface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes:%d:%d:0:0:256:256:%d:%d:%d:%d|t")
                :format(size, size, c[1] * 256, c[2] * 256, c[3] * 256, c[4] * 256)
        end
        return ""
    end
    local path
    local role = key:match("^role:(%l+)$")
    if role and ROLE_ICON[role] then path = "Interface\\Icons\\" .. ROLE_ICON[role] end
    local sp = key:match("^sp:(%d+)$")
    if sp then path = GetSpellTexture and GetSpellTexture(tonumber(sp)) end
    local it = key:match("^it:(%d+)$")
    if it then path = GetItemIcon and GetItemIcon(tonumber(it)) end
    local file = key:match("^i:(.+)$")
    if file then path = "Interface\\Icons\\" .. file end
    local asset = SO().Parse(key) and AssetIcon(key)
    if asset then path = asset end
    if not path then return "" end
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(path), size, size)
end

-- A short name of an icon key (tooltips, menus).
function MapUI:IconName(key, bossRef)
    if type(key) ~= "string" then return "" end
    local rt = key:match("^rt([1-8])$")
    if rt then return RT_NAMES[tonumber(rt)] end
    local disp = key:match("^boss:(%d+)$")
    if disp then return self:PortraitName(disp, bossRef) or "Boss portrait" end
    local cls = key:match("^cls:(%u+)$")
    if cls then return ns.CLASS_NAMES and ns.CLASS_NAMES[cls] or cls end
    local role = key:match("^role:(%l+)$")
    if role then return ROLE_NAME[role] or role end
    local sp = key:match("^sp:(%d+)$")
    if sp then return (GetSpellInfo and GetSpellInfo(tonumber(sp))) or ("Spell " .. sp) end
    local it = key:match("^it:(%d+)$")
    if it then return (ns.ItemDB and ns.ItemDB:GetName(tonumber(it))) or ("Item " .. it) end
    if SO().Parse(key) then return SO().KeyName(key) end
    local file = key:match("^i:(.+)$")
    for _, e in ipairs(self.SPELL_ICONS) do
        if e[1] == file then return e[2] end
    end
    return file or key
end

-- The creatures of an encounter (Data/BossPortraits.lua: the boss first, then its adds): { { d = display id,
-- n = name, id = npc id } }, { } when none.
function MapUI:BossPortraits(bossRef)
    local data = ns.Data and ns.Data.BossPortraits
    return (type(bossRef) == "string" and data and data[bossRef]) or {}
end

-- The creature name of a portrait display id: from the given encounter first (two creatures can share a model),
-- else from any encounter; nil when unknown.
local portraitNames
function MapUI:PortraitName(displayID, bossRef)
    local d = tonumber(displayID)
    for _, c in ipairs(self:BossPortraits(bossRef)) do
        if c.d == d then return c.n end
    end
    if not portraitNames then
        portraitNames = {}
        for _, list in pairs(ns.Data and ns.Data.BossPortraits or {}) do
            for _, c in ipairs(list) do portraitNames[c.d] = portraitNames[c.d] or c.n end
        end
    end
    return portraitNames[tonumber(displayID)]
end

-- Adds an icon picker to a menu description: onPick(key, extra). prompt(title, default, cb) asks for a spell / item
-- id. models (the map's drawings, not table cells): also the encounter's assets and a creature or object by its ID
-- (extra = { label, ms }: Core/StrategyObjects.lua SO.Resolve); models.onGroup(group): a group of the encounter's
-- assets placed at their own spots (Data/EncounterSpawns.lua).
function MapUI:BuildIconMenu(root, current, onPick, prompt, bossRef, models)
    local function radio(parent, key, label)
        local icon = self:IconString(key, 14)
        parent:CreateRadio((icon ~= "" and (icon .. " ") or "") .. label, function() return current == key end,
            function() onPick(key) end)
    end
    -- the creatures of the encounter this strategy is for (the boss and its adds; no other encounter's)
    local portraits = self:BossPortraits(bossRef)
    if #portraits > 0 then
        local sub = root:CreateButton("This boss: " .. S():GetBossName(bossRef))
        for _, c in ipairs(portraits) do radio(sub, "boss:" .. c.d, c.n) end
    end
    -- the encounter's assets (Data/EncounterObjects.lua): one here, or a group where the script puts them
    local objects = models and SO().ForEncounter(bossRef) or {}
    local spawns = type(models) == "table" and models.onGroup and SO().Spawns(bossRef)
    if #objects > 0 or spawns then
        local sub = root:CreateButton("Encounter objects")
        for _, key in ipairs(objects) do radio(sub, key, SO().KeyName(key)) end
        if spawns then
            if #objects > 0 then sub:CreateDivider() end
            for _, grp in ipairs(spawns.groups or {}) do
                sub:CreateButton(("%s at their spots (%d)"):format(grp.n, #grp.e), function() models.onGroup(grp) end)
            end
        end
    end
    local marks = root:CreateButton("Raid marks")
    for i = 1, 8 do radio(marks, "rt" .. i, RT_NAMES[i]) end
    local roles = root:CreateButton("Roles")
    for _, r in ipairs(S().ROLES) do radio(roles, "role:" .. r, ROLE_NAME[r]) end
    local classes = root:CreateButton("Classes")
    for _, cls in ipairs(ns.CLASSES or {}) do radio(classes, "cls:" .. cls, ns.CLASS_NAMES[cls] or cls) end
    local spells = root:CreateButton("Tactics")
    for _, e in ipairs(self.SPELL_ICONS) do radio(spells, "i:" .. e[1], e[2]) end
    if prompt then
        root:CreateButton("From a spell ID...", function()
            prompt("Spell ID (e.g. 10278 for Blessing of Protection)", "", function(text)
                local id = tonumber(text)
                if id and id > 0 and id < 1000000 then onPick("sp:" .. floor(id)) end
            end)
        end)
        root:CreateButton("From an item ID...", function()
            prompt("Item ID (e.g. 22847 for Major Nature Protection Potion)", "", function(text)
                local id = tonumber(text)
                if id and id > 0 and id < 1000000 then onPick("it:" .. floor(id)) end
            end)
        end)
        if models then
            -- a creature or game object as its 3D model, by an ID or a pasted Wowhead link
            local sub = root:CreateButton("From a model ID")
            for _, k in ipairs({ { "npc", "NPC ID...", "NPC ID or Wowhead link (e.g. 21212 for Lady Vashj)" },
                                 { "obj", "Object ID...", "Object ID or Wowhead link (e.g. 185051 for a Shield Generator)" },
                                 { "display", "Display ID...", "Creature display ID (e.g. 20748 for Lady Vashj)" } }) do
                sub:CreateButton(k[2], function()
                    prompt(k[3], "", function(text)
                        local key, extra = SO().Resolve(k[1], text)
                        if key then onPick(key, extra) else ns:Print(extra) end
                    end)
                end)
            end
        end
    end
end

-- A new icon drawing at a board point from a picked key (BuildIconMenu's onPick: key, extra): a portrait large with
-- the creature's name, an object with its name; extra.label when the name is not known, extra.ms its size.
function MapUI:NewIcon(x, y, key, extra, bossRef)
    extra = extra or {}
    local portrait = key:match("^boss:(%d+)$")
    local kind = SO().Parse(key)
    local label = portrait and (self:PortraitName(portrait, bossRef) or extra.label)
        or kind and (extra.label or SO().KeyName(key)) or nil
    local z = portrait and 48 or (kind == "npc" and 40) or 32
    return { t = "i", x = x, y = y, i = key, z = z, l = label, ms = extra.ms }
end

---------------------------------------------------------------------------
-- Instance maps (C_Map): every dungeon floor with map art, found once
---------------------------------------------------------------------------

local mapCache

-- The names the client may give a raid's map, per ItemDB raid key.
local MAP_NAMES = {
    Karazhan = { "karazhan" },
    GruulsLair = { "gruul" },
    MagtheridonsLair = { "magtheridon" },
    SerpentshrineCavern = { "serpentshrine" },
    TempestKeep = { "tempest keep", "the eye" },
    HyjalSummit = { "hyjal" },
    BlackTemple = { "black temple" },
    ZulAman = { "zul'aman", "zul aman" },
    SunwellPlateau = { "sunwell" },
}

-- The raids' uiMapIDs as the TBC clients number them (a fallback when the names don't match).
local MAP_IDS = {
    Karazhan = { 350, 351, 352, 353, 354, 355, 356, 357, 358, 359, 360, 361, 362, 363, 364, 365, 366 },
    GruulsLair = { 330 },
    MagtheridonsLair = { 331 },
    SerpentshrineCavern = { 332 },
    TempestKeep = { 334 },
    HyjalSummit = { 329 },
    BlackTemple = { 339, 340, 341, 342, 343, 344, 345, 346 },
    ZulAman = { 333 },
    SunwellPlateau = { 335, 336 },
}

-- DisasterZone's own raid maps (Data/RaidMaps.lua: Blizzard's floor maps, see NOTICE.md; the client has no raid map art).
-- Each is two textures, Media/Maps/<file>_a (1024 x 512) and _b (1024 x 256, 171 rows used), of a 1024 x 683 map.
-- Ids 900101+ so they never meet a uiMapID; a page stores the id.
local SHIPPED = (ns.Data and ns.Data.RaidMaps) or {}
local SHIPPED_BY_ID = {}
for _, m in ipairs(SHIPPED) do SHIPPED_BY_ID[m.id] = m end
local SHIPPED_LAYER = { layerWidth = 1024, layerHeight = 683, tileWidth = 1024, tileHeight = 512, shipped = true }

-- The Atlas maps of the first test builds (900001-900012) -> the floor that replaced them.
local OLD_IDS = {
    [900001] = "Kara01", [900002] = "Kara11", [900003] = "Gruul", [900004] = "Magtheridon",
    [900005] = "Serpentshrine", [900006] = "TheEye", [900007] = "Hyjal", [900008] = "BT00", [900009] = "BT03",
    [900010] = "BT06", [900011] = "ZulAman", [900012] = "Sunwell",
}
for old, file in pairs(OLD_IDS) do
    for _, m in ipairs(SHIPPED) do
        if m.file == file then SHIPPED_BY_ID[old] = m end
    end
end

-- The map a new strategy of a boss starts with: the floor the boss is on.
local BOSS_MAP = {}
for _, m in ipairs(SHIPPED) do
    for _, boss in ipairs(m.bosses or {}) do BOSS_MAP[m.raid .. ":" .. boss] = BOSS_MAP[m.raid .. ":" .. boss] or m.id end
end

local function ArtLayer(mapID)
    if SHIPPED_BY_ID[mapID] then return SHIPPED_LAYER end
    if not (C_Map and C_Map.GetMapArtLayers) or type(mapID) ~= "number" or mapID <= 0 then return nil end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local L = ok and type(layers) == "table" and layers[1] or nil
    if L and (L.layerWidth or 0) > 0 and (L.tileWidth or 0) > 0 then return L end
    return nil
end

local function raidOfName(name)
    name = (name or ""):lower()
    for key, list in pairs(MAP_NAMES) do
        for _, want in ipairs(list) do
            if name:find(want, 1, true) then return key end
        end
    end
    return nil
end

-- { { id, name, floor, raid } } of every TBC raid map with art: maps named like a raid (any map type), plus the
-- known ids of each raid.
function MapUI:GetMaps()
    if mapCache then return mapCache end
    mapCache = {}
    for _, m in ipairs(SHIPPED) do mapCache[#mapCache + 1] = { id = m.id, name = m.name, raid = m.raid, shipped = true } end
    if not (C_Map and C_Map.GetMapInfo) then return mapCache end
    local seen = {}
    local function add(id, raid)
        if seen[id] or not ArtLayer(id) then return end
        local ok, info = pcall(C_Map.GetMapInfo, id)
        info = ok and type(info) == "table" and info or {}
        local floorName
        local gid = C_Map.GetMapGroupID and C_Map.GetMapGroupID(id)
        if gid and C_Map.GetMapGroupMembersInfo then
            for _, m in ipairs(C_Map.GetMapGroupMembersInfo(gid) or {}) do
                if m.mapID == id then floorName = m.name end
            end
        end
        seen[id] = true
        mapCache[#mapCache + 1] = { id = id, name = info.name or ("Map " .. id), floor = floorName,
                                    raid = raid or raidOfName(info.name) }
    end
    for id = 1, 2500 do
        local ok, info = pcall(C_Map.GetMapInfo, id)
        if ok and type(info) == "table" then
            local raid = raidOfName(info.name)
            if raid then add(id, raid) end
        end
    end
    for raid, ids in pairs(MAP_IDS) do
        for _, id in ipairs(ids) do add(id, raid) end
    end
    tsort(mapCache, function(a, b)
        if (a.shipped or false) ~= (b.shipped or false) then return a.shipped == true end
        return a.id < b.id
    end)
    return mapCache
end

function MapUI:MapLabel(m)
    if m.floor and m.floor ~= "" and m.floor ~= m.name then return m.name .. " - " .. m.floor end
    return m.name
end

-- The maps of a boss' raid ({ id, name, floor }, in map id order).
function MapUI:MapsFor(bossRef)
    local out = {}
    local raidKey = type(bossRef) == "string" and bossRef:match("^(%w+):") or nil
    if not raidKey then return out end
    for _, m in ipairs(self:GetMaps()) do
        if m.raid == raidKey then out[#out + 1] = m end
    end
    return out
end

-- /dz maps [text]: what the client reports (map id, type, art) for maps whose name contains the text.
function MapUI:PrintMaps(text)
    text = (text or ""):lower()
    local n = 0
    for id = 1, 2500 do
        local ok, info = pcall(C_Map.GetMapInfo, id)
        if ok and type(info) == "table" and info.name and (text == "" and raidOfName(info.name) or
                (text ~= "" and info.name:lower():find(text, 1, true))) then
            n = n + 1
            if n <= 40 then
                local L = ArtLayer(id)
                ns:Print("map %d: %s (type %s)%s", id, info.name, tostring(info.mapType),
                    L and (" art %dx%d"):format(L.layerWidth, L.layerHeight) or " no art")
            end
        end
    end
    mapCache = nil
    ns:Print("%d map(s) matched; %d raid map(s) usable (%d shipped with DisasterZone).", n, #self:GetMaps(), #SHIPPED)
end

function MapUI:DefaultMap(bossRef)
    if BOSS_MAP[bossRef] then return BOSS_MAP[bossRef] end
    local list = self:MapsFor(bossRef)
    return list[1] and list[1].id or 0
end

-- The shipped map (Data/RaidMaps.lua entry: id, file, raid, name) a page's map id stands for, or nil.
function MapUI:ShippedMap(mapID)
    return mapID and SHIPPED_BY_ID[mapID] or nil
end

function MapUI:MapName(mapID)
    if not mapID or mapID == 0 then return "Blank" end
    if SHIPPED_BY_ID[mapID] then return SHIPPED_BY_ID[mapID].name end
    for _, m in ipairs(self:GetMaps()) do
        if m.id == mapID then return self:MapLabel(m) end
    end
    return "Map " .. tostring(mapID)
end

-- Adds a map picker: this raid's floors, the other TBC raids' maps, a map id, blank.
function MapUI:BuildMapMenu(root, bossRef, current, onPick, prompt)
    local mine = self:MapsFor(bossRef)
    for _, m in ipairs(mine) do
        root:CreateRadio(self:MapLabel(m), function() return current == m.id end, function() onPick(m.id) end)
    end
    if #mine == 0 then root:CreateTitle("No map of this raid found") end
    local seen = {}
    for _, m in ipairs(mine) do seen[m.id] = true end
    local other = root:CreateButton("Other raids")
    local any = false
    for key in pairs(MAP_NAMES) do
        for _, m in ipairs(self:MapsFor(key .. ":x")) do
            if not seen[m.id] then
                seen[m.id] = true
                any = true
                other:CreateRadio(self:MapLabel(m), function() return current == m.id end, function() onPick(m.id) end)
            end
        end
    end
    if not any then other:CreateTitle("none") end
    if prompt then
        root:CreateButton("Map ID...", function()
            prompt("Map ID (uiMapID of any map with art)", current and current > 0 and tostring(current) or "",
                function(text)
                    local id = tonumber(text)
                    if id and ArtLayer(floor(id)) then onPick(floor(id))
                    else ns:Print("No map art found for map %s.", tostring(text)) end
                end)
        end)
    end
    root:CreateRadio("Blank (grid)", function() return not current or current == 0 end, function() onPick(0) end)
end

---------------------------------------------------------------------------
-- Canvas
---------------------------------------------------------------------------

local Canvas = {}
Canvas.__index = Canvas

local TOOLS = {
    { key = "select", label = "Select", tip = "Click to select (Shift adds, drag on empty map for a box). Drag to move, Alt snaps. Shift-drag onto a table cell to link. Right-click for options." },
    { key = "pan", label = "Pan map", tip = "Drag to move the map; the mouse wheel zooms. Set the map first, then draw: drawings stay where they are when the map moves." },
    { key = "circle", label = "Circle", tip = "Drag from the centre outwards to draw a circular zone." },
    { key = "rect", label = "Rectangle", tip = "Drag from one corner to the other to draw a zone." },
    { key = "arrow", label = "Arrow", tip = "Drag from start to end." },
    { key = "line", label = "Line", tip = "Drag from start to end." },
    { key = "icon", label = "Icon", tip = "Click where the icon goes, then pick it (the boss and its adds are under This boss)." },
    { key = "text", label = "Text", tip = "Click where the text goes, then type it." },
}
MapUI.TOOLS = TOOLS

local RM_TEX = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"

local function fontPath()
    local f = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
    return f or "Fonts\\FRIZQT__.TTF"
end
MapUI.FontPath = fontPath

-- The clipboard (copies of drawings), shared by every board.
MapUI.clipboard = nil

-- Creates a canvas of `width` pixels (height follows the board's 3:2). opts:
--   editable()          -> bool
--   onChange()          the page was changed (by the canvas)
--   onSelect(el)        selection changed (the primary element, nil = none)
--   slotText(ref)       -> text shown on a slot token (a player's name, or the slot's label)
--   slotTip(ref, tt)    adds tooltip lines for a token / linked drawing
--   linkText(ref)       -> the text shown under a linked drawing (players' names, or the link in edit mode), or nil
--   linkLabel(ref)      -> the link in words (menus, tooltips)
--   onHover(linkRef)    the mouse is over something linked to a block ("blk", "blk.col", "blk.row.col"), or nil
--   slots()             -> { { ref, label, blockName } } of the strategy
--   links()             -> { { ref, label } } blocks and columns
--   validRef(ref)       -> does the link / slot exist in this strategy (paste from another one)
--   dropRef()           -> the block reference under the cursor (link drags onto the tables), or nil
--   prompt(title, default, cb, multiline, maxLen)
--   bossRef()           -> the strategy's boss (map list, portraits)
function MapUI:CreateCanvas(parent, width, opts)
    local self = setmetatable({}, Canvas)
    self.opts = opts or {}
    self.tool = "select"
    self.color = 1
    self.sel = {}
    self.pools = { zone = {}, arrow = {}, icon = {}, text = {}, slot = {}, link = {}, box = {}, beam = {} }
    self.used = {}
    local f = CreateFrame("Frame", nil, parent)
    self.frame = f
    f:SetClipsChildren(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    self.bg = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    self.bg:SetAllPoints()
    self.bg:SetColorTexture(0.06, 0.06, 0.08, 1)
    self.art = CreateFrame("Frame", nil, f)
    self.art:SetAllPoints()
    self.tiles = {}
    self.grid = {}
    self.layer = CreateFrame("Frame", nil, f)
    self.layer:SetAllPoints()
    self.layer:SetFrameLevel(self.art:GetFrameLevel() + 2)
    -- every drawing gets its own frame on the layer (the frame level is its place in the stacking order); the
    -- selection, handles and names of linked drawings sit on a frame above them all
    self.top = CreateFrame("Frame", nil, f)
    self.top:SetAllPoints()
    self.top:SetFrameLevel(self.layer:GetFrameLevel() + 400)
    self.handles = {}
    for i = 1, 2 do
        local h = self.top:CreateTexture(nil, "OVERLAY", nil, 7)
        h:SetColorTexture(1, 0.85, 0.1, 1)
        h:SetSize(8, 8)
        h:Hide()
        self.handles[i] = h
    end
    -- the selection box being dragged
    self.marq = self.top:CreateTexture(nil, "OVERLAY", nil, 5)
    self.marq:SetColorTexture(1, 0.85, 0.1, 0.15)
    self.marq:Hide()
    self.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.hint:SetPoint("BOTTOMLEFT", 6, 4)
    self.hint:SetPoint("RIGHT", -6, 0)
    self.hint:SetJustifyH("LEFT")
    self:SetWidth(width)

    f:SetScript("OnMouseDown", function(_, button) self:OnMouseDown(button) end)
    f:SetScript("OnMouseUp", function(_, button) self:OnMouseUp(button) end)
    f:SetScript("OnMouseWheel", function(_, delta) self:OnWheel(delta) end)
    f:SetScript("OnEnter", function() self.hovering = true end)
    f:SetScript("OnLeave", function()
        self.hovering = false
        self:SetHover(nil)
    end)
    local acc = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        if self.drag then
            self:OnDragUpdate()
        elseif self.hovering then
            acc = acc + elapsed
            if acc > 0.06 then
                acc = 0
                self:UpdateHover()
            end
        end
    end)
    return self
end

function Canvas:SetWidth(width)
    self.w = width
    self.s = width / BW
    self.h = floor(BH * self.s + 0.5)
    self.frame:SetSize(width, self.h)
end

function Canvas:SetPage(page)
    if page ~= self.page then
        self.sel = {}
        self.selected = nil
        self.drag = nil
    end
    self.page = page
    -- a page that cannot be drawn in the room shows the map; back in the room on one that can (if that was the view);
    -- another boss' room (a new strategy opened while in 3D) replaces the one shown
    if self.v3 then
        local can = self:Room3D()
        if self:Is3D() and not can then
            self.v3:Close(false)
            self:Show2D()
            return
        elseif can and (self.want3d and not self:Is3D() or self:Is3D() and can ~= self.v3.room) then
            self:Enter3D(false)
        end
    end
    self:Render()
end

function Canvas:SetTool(tool)
    self.tool = tool or "select"
    if self.tool ~= "select" then self:ClearSelection() end
    self:UpdateHint()
end

function Canvas:SetColor(i) self.color = i end

function Canvas:Editable()
    return self.opts.editable and self.opts.editable() or false
end

function Canvas:Changed()
    if self.opts.onChange then self.opts.onChange() end
    self:Render()
end

-- What the mouse does in the room, per tool (the 3D view shows it).
local TIPS3D = {
    select = "Click to select, drag to move it on the floor. Right-drag turns the view, the wheel zooms, middle-drag "
        .. "moves it; double-click the floor to look there.",
    pan = "Drag to move the view. Right-drag turns it, the wheel zooms.",
    circle = "Drag on the floor from the centre outwards to draw a circular zone.",
    rect = "Drag on the floor from one corner to the other to draw a zone.",
    arrow = "Drag on the floor from start to end.",
    line = "Drag on the floor from start to end.",
    icon = "Click the floor where the icon goes, then pick it.",
    text = "Click the floor where the text goes, then type it.",
}
local READ3D = "Drag to move the view, right-drag to turn it, the wheel zooms; double-click the floor to look there."

function Canvas:UpdateHint()
    if self:Is3D() then
        self.v3:SetHint(self:Editable() and TIPS3D[self.tool] or READ3D)
        return
    end
    if not self:Editable() then
        self.hint:SetText("")
        return
    end
    for _, t in ipairs(TOOLS) do
        if t.key == self.tool then self.hint:SetText(t.tip) end
    end
end

---------------------------------------------------------------------------
-- 3D (UI/StrategyMap3D.lua): the same page in the boss' own room. The drawings stay in board units; in the room the
-- canvas asks the view for the floor under the mouse and for what is under it, and lets it draw.
---------------------------------------------------------------------------

function Canvas:Is3D() return self.v3 ~= nil and self.v3:IsOn() end

-- The room this page can be drawn in, or nil and why not ("restart" / "none" / "map": StrategyMap3D:RoomFor).
function Canvas:Room3D()
    local M3 = ns.StrategyMap3D
    if not (M3 and M3.RoomFor) then return nil, "restart" end
    return M3:RoomFor(self.opts.bossRef and self.opts.bossRef(), self.page)
end

-- The page in the room (on) or on the map; animate: the map tilts up into the room, or back down to it.
-- -> true when that is the view (or it is on its way there).
function Canvas:Set3D(on, animate)
    if on then
        if self:Is3D() then return true end
        if not self:Room3D() then return false end
        self.v3 = self.v3 or ns.StrategyMap3D:Create(self)
        if not self.v3 then return false end
        self.want3d = true
        return self:Enter3D(animate)
    end
    self.want3d = false
    if not self:Is3D() then return true end
    if animate then
        self.v3:Close(true, function() self:Show2D() end)
    else
        self.v3:Close(false)
        self:Show2D()
    end
    return true
end

function Canvas:Enter3D(animate)
    self.drag = nil
    self.marq:Hide()
    if not self.v3:Open(animate) then return false end
    self.art:Hide()
    self.layer:Hide()
    self.top:Hide()
    self.hint:SetText("")
    self:SetHover(nil)
    self:UpdateHint()
    if self.opts.on3D then self.opts.on3D(true) end
    return true
end

function Canvas:Show2D()
    self.drag = nil
    self.art:Show()
    self.layer:Show()
    self.top:Show()
    self:Render()
    if self.opts.on3D then self.opts.on3D(false) end
end

-- Stands at a drawing in the room, at eye height (going 3D first).
function Canvas:ViewFrom3D(e)
    if not self:Is3D() and not self:Set3D(true, false) then return end
    self.v3:ViewFrom(e)
end

-- Cursor position in board units (clamped to the board unless raw). In the room: the floor under the mouse (where
-- it meets none, over the horizon, the last floor point it met); while a drawing is moved, floors over 3 yd above
-- the one it was picked up from are looked through (it slides past pillars and railings instead of catching on them).
function Canvas:Cursor(raw)
    if self:Is3D() then
        local d, fromZ = self.drag, nil
        if d and (d.mode == "move" or d.mode == "pending") then
            d.fromZ = d.fromZ or self.v3:GroundAtBoard(d.sx, d.sy)
            fromZ = d.fromZ
        end
        local bx, by = self.v3:CursorBoard(fromZ)
        if bx then
            self.last3D = self.last3D or {}
            self.last3D[1], self.last3D[2] = bx, by
        elseif self.last3D then
            bx, by = self.last3D[1], self.last3D[2]
        else
            bx, by = BW / 2, BH / 2
        end
        if raw then return bx, by end
        return max(0, min(BW, floor(bx + 0.5))), max(0, min(BH, floor(by + 0.5)))
    end
    local x, y = GetCursorPosition()
    local es = self.frame:GetEffectiveScale() or 1
    x, y = x / es, y / es
    local l, t = self.frame:GetLeft() or 0, self.frame:GetTop() or 0
    local bx, by = (x - l) / self.s, (t - y) / self.s
    if raw then return bx, by end
    return max(0, min(BW, floor(bx + 0.5))), max(0, min(BH, floor(by + 0.5)))
end

-- Pixel offset of a board point from the canvas' top left.
function Canvas:P(x, y)
    return x * self.s, -y * self.s
end

---------------------------------------------------------------------------
-- Background
---------------------------------------------------------------------------

function Canvas:RenderBackground()
    for _, t in ipairs(self.tiles) do t:Hide() end
    for _, t in ipairs(self.grid) do t:Hide() end
    local page = self.page
    local L = page and ArtLayer(page.m)
    local shipped = page and SHIPPED_BY_ID[page.m]
    local textures
    if shipped then
        local base = "Interface\\AddOns\\DisasterZone\\Media\\Maps\\" .. shipped.file
        textures = { base .. "_a", base .. "_b" }
    else
        textures = L and C_Map.GetMapArtLayerTextures and C_Map.GetMapArtLayerTextures(page.m, 1)
    end
    if not (L and type(textures) == "table" and #textures > 0) then
        -- a blank grid every 100 units
        local n = 0
        local function line(horizontal, pos)
            n = n + 1
            local t = self.grid[n]
            if not t then
                t = self.art:CreateTexture(nil, "BACKGROUND", nil, -6)
                self.grid[n] = t
            end
            t:ClearAllPoints()
            t:SetColorTexture(1, 1, 1, 0.06)
            if horizontal then
                t:SetPoint("TOPLEFT", self.art, "TOPLEFT", 0, -pos * self.s)
                t:SetSize(self.w, 1)
            else
                t:SetPoint("TOPLEFT", self.art, "TOPLEFT", pos * self.s, 0)
                t:SetSize(1, self.h)
            end
            t:Show()
        end
        for x = 100, BW - 1, 100 do line(false, x) end
        for y = 100, BH - 1, 100 do line(true, y) end
        return
    end
    local base = min(self.w / L.layerWidth, self.h / L.layerHeight)
    local sc = base * ((page.vz or 100) / 100)
    local cx = (page.vx or 500) / 1000 * L.layerWidth
    local cy = (page.vy or 500) / 1000 * L.layerHeight
    local ox, oy = self.w / 2 - cx * sc, self.h / 2 - cy * sc
    local cols = ceil(L.layerWidth / L.tileWidth)
    local rows = ceil(L.layerHeight / L.tileHeight)
    local tw, th = L.tileWidth * sc, L.tileHeight * sc
    local n = 0
    for r = 1, rows do
        for c = 1, cols do
            local file = textures[(r - 1) * cols + c]
            if file then
                n = n + 1
                local t = self.tiles[n]
                if not t then
                    t = self.art:CreateTexture(nil, "BACKGROUND", nil, -7)
                    self.tiles[n] = t
                end
                t:ClearAllPoints()
                t:SetTexture(file)
                if L.shipped and r == 2 then
                    local rows = L.layerHeight - L.tileHeight
                    t:SetTexCoord(0, 1, 0, rows / 256)
                    t:SetSize(tw, rows * sc)
                else
                    t:SetTexCoord(0, 1, 0, 1)
                    t:SetSize(tw, th)
                end
                t:SetPoint("TOPLEFT", self.art, "TOPLEFT", ox + (c - 1) * tw, -(oy + (r - 1) * th))
                t:Show()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Elements
---------------------------------------------------------------------------

-- A pooled drawing object with its own frame (on the top frame when `top`). create(frame) makes its regions.
local function acquire(self, kind, create, top)
    self.used[kind] = (self.used[kind] or 0) + 1
    local pool = self.pools[kind]
    local o = pool[self.used[kind]]
    if not o then
        local holder = CreateFrame("Frame", nil, top and self.top or self.layer)
        holder:SetAllPoints(self.layer)
        o = create(holder)
        o.holder = holder
        pool[self.used[kind]] = o
    end
    o.holder:Show()
    self.lastObj = o
    return o
end

local function newFS(layer)
    return layer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
end

function Canvas:FontSize(base)
    return max(8, floor(base * self.s / 0.7 + 0.5))
end

-- A raid mark badge at a point (the top right corner of an icon or zone).
function Canvas:Badge(o, e, x, y, size)
    if not o.badge then o.badge = o.holder:CreateTexture(nil, "OVERLAY", nil, 2) end
    if not e.rm then
        o.badge:Hide()
        return
    end
    o.badge:ClearAllPoints()
    o.badge:SetTexture(RM_TEX .. e.rm)
    o.badge:SetSize(size, size)
    o.badge:SetPoint("CENTER", self.layer, "TOPLEFT", x * self.s, -y * self.s)
    o.badge:Show()
end

function Canvas:RenderZone(e)
    local L = self.layer
    local o = acquire(self, "zone", function(L)
        local z = {}
        z.fill = L:CreateTexture(nil, "BACKGROUND", nil, 1)
        z.ring = L:CreateTexture(nil, "BORDER", nil, 1)
        z.edges = {}
        for i = 1, 4 do z.edges[i] = L:CreateTexture(nil, "BORDER", nil, 1) end
        z.fs = newFS(L)
        return z
    end)
    local r, g, b = MapUI:Color(e.c or 1)
    local px, py = self:P(e.x - e.w / 2, e.y - e.h / 2)
    local w, h = e.w * self.s, e.h * self.s
    local lit = self.lit and self.lit[e] and 1 or 0
    o.fill:ClearAllPoints()
    o.fill:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px, py)
    o.fill:SetSize(w, h)
    if e.s == "c" then
        o.fill:SetTexture(TEX_DISC)
        o.fill:SetVertexColor(r, g, b, 0.30 + 0.2 * lit)
        o.ring:ClearAllPoints()
        o.ring:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px, py)
        o.ring:SetSize(w, h)
        o.ring:SetTexture(TEX_RING)
        o.ring:SetVertexColor(r, g, b, 0.9)
        o.ring:Show()
        for _, t in ipairs(o.edges) do t:Hide() end
    else
        o.fill:SetColorTexture(r, g, b, 0.26 + 0.2 * lit)
        o.fill:SetVertexColor(1, 1, 1, 1)
        o.ring:Hide()
        local th = max(1, floor(2 * self.s / 0.7))
        for i, t in ipairs(o.edges) do
            t:ClearAllPoints()
            t:SetColorTexture(r, g, b, 0.9)
            t:Show()
            if i == 1 then t:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px, py); t:SetSize(w, th)
            elseif i == 2 then t:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px, py - h + th); t:SetSize(w, th)
            elseif i == 3 then t:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px, py); t:SetSize(th, h)
            else t:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px + w - th, py); t:SetSize(th, h) end
        end
    end
    o.fill:Show()
    o.fs:SetFont(fontPath(), self:FontSize(13), "OUTLINE")
    o.fs:ClearAllPoints()
    o.fs:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    o.fs:SetWidth(max(40, w + 40))
    o.fs:SetText(e.l or "")
    o.fs:SetTextColor(1, 1, 1)
    o.fs:Show()
    local corner = e.s == "c" and 0.35 or 0.5
    self:Badge(o, e, e.x + e.w * corner, e.y - e.h * corner, 18 * self.s / 0.7)
    o.hide = function()
        o.fill:Hide()
        o.ring:Hide()
        for _, t in ipairs(o.edges) do t:Hide() end
        o.fs:Hide()
        if o.badge then o.badge:Hide() end
    end
end

function Canvas:RenderArrow(e)
    local L = self.layer
    local o = acquire(self, "arrow", function(L)
        local a = {}
        a.line = L:CreateLine(nil, "ARTWORK", nil, 1)
        a.head = L:CreateTexture(nil, "ARTWORK", nil, 2)
        a.head:SetTexture(TEX_ARROW)
        return a
    end)
    local r, g, b = MapUI:Color(e.c or 9)
    if self.lit and self.lit[e] then r, g, b = 1, 0.85, 0.1 end
    local x1, y1 = self:P(e.x, e.y)
    local x2, y2 = self:P(e.x2, e.y2)
    local th = max(2, floor(3 * self.s / 0.7 + 0.5))
    o.line:SetStartPoint("TOPLEFT", self.layer, x1, y1)
    o.line:SetEndPoint("TOPLEFT", self.layer, x2, y2)
    o.line:SetThickness(th)
    o.line:SetColorTexture(r, g, b, 0.95)
    o.line:Show()
    if e.h then
        local size = th * 5
        o.head:ClearAllPoints()
        o.head:SetSize(size, size)
        o.head:SetPoint("CENTER", self.layer, "TOPLEFT", x2, y2)
        o.head:SetVertexColor(r, g, b, 0.95)
        -- the texture points up; screen y grows upwards for rotations
        o.head:SetRotation(atan2(y2 - y1, x2 - x1) - math.pi / 2)
        o.head:Show()
    else
        o.head:Hide()
    end
    o.hide = function()
        o.line:Hide()
        o.head:Hide()
    end
end

function Canvas:RenderIcon(e)
    local L = self.layer
    local o = acquire(self, "icon", function(L)
        local i = {}
        i.glow = L:CreateTexture(nil, "ARTWORK", nil, 2)
        i.glow:SetColorTexture(1, 0.85, 0.1, 0.6)
        i.tex = L:CreateTexture(nil, "ARTWORK", nil, 3)
        i.fs = newFS(L)
        return i
    end)
    local size = (e.z or 32) * self.s
    o.tex:ClearAllPoints()
    o.tex:SetSize(size, size)
    o.tex:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    MapUI:SetIcon(o.tex, e.i)
    local _, st = SO().StateOf(e)
    if st and st.dim then                                -- a game object in a state that greys it (switched off)
        o.tex:SetDesaturated(true)
        o.tex:SetVertexColor(0.6, 0.6, 0.6, 0.85)
    end
    o.tex:Show()
    o.glow:ClearAllPoints()
    o.glow:SetPoint("TOPLEFT", o.tex, "TOPLEFT", -3, 3)
    o.glow:SetPoint("BOTTOMRIGHT", o.tex, "BOTTOMRIGHT", 3, -3)
    o.glow:SetShown(self.lit and self.lit[e] and true or false)
    if e.l and self.opts.iconLabels ~= false then
        local r, g, b = MapUI:Color(e.c or 9)
        o.fs:SetFont(fontPath(), self:FontSize(11), "OUTLINE")
        o.fs:ClearAllPoints()
        o.fs:SetPoint("TOP", o.tex, "BOTTOM", 0, -1)
        o.fs:SetWidth(0)
        o.fs:SetText(e.l)
        o.fs:SetTextColor(r, g, b)
        o.fs:Show()
    else
        o.fs:Hide()
    end
    local half = (e.z or 32) / 2
    self:Badge(o, e, e.x + half * 0.8, e.y - half * 0.8, max(10, size * 0.45))
    o.hide = function()
        o.tex:Hide()
        o.glow:Hide()
        o.fs:Hide()
        if o.badge then o.badge:Hide() end
    end
end

-- A game object's beam to its target (Core/StrategyObjects.lua SO.Beams: an active Shield Generator to Lady Vashj).
function Canvas:RenderBeam(b)
    local o = acquire(self, "beam", function(L)
        return { line = L:CreateLine(nil, "ARTWORK", nil, 1) }
    end)
    local c = b.beam.color or { 1, 1, 1 }
    local x1, y1 = self:P(b.src.x, b.src.y)
    local x2, y2 = self:P(b.dst.x, b.dst.y)
    o.line:SetStartPoint("TOPLEFT", self.layer, x1, y1)
    o.line:SetEndPoint("TOPLEFT", self.layer, x2, y2)
    o.line:SetThickness(max(2, floor(2.5 * self.s / 0.7 + 0.5)))
    o.line:SetColorTexture(c[1], c[2], c[3], 0.8)
    o.line:Show()
    o.hide = function() o.line:Hide() end
end

local TEXT_SIZES = { 10, 13, 17 }
local TEXT_WRAP_W = 320     -- board units: a text on the map wider than this wraps (at the normal size)

local JUSTIFY = { l = "LEFT", r = "RIGHT" }

-- The font size of a text: e.z is 1-3 (small / normal / large) or the size itself (dragged at the corner).
local function textSize(e)
    local z = e.z or 2
    return TEXT_SIZES[z] or z
end

-- The width of a text's box in board units: its own (Shift-drag the corner), else one that grows with its size.
local function textBox(e)
    return e.w or TEXT_WRAP_W * textSize(e) / TEXT_SIZES[2]
end
MapUI.TextSize, MapUI.TextBox = textSize, textBox

function Canvas:RenderText(e)
    local o = acquire(self, "text", function(L)
        return { fs = newFS(L) }
    end)
    local r, g, b = MapUI:Color(e.c or 9)
    if self.lit and self.lit[e] then r, g, b = 1, 0.85, 0.1 end
    o.fs:SetFont(fontPath(), self:FontSize(textSize(e)), "OUTLINE")
    o.fs:ClearAllPoints()
    o.fs:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    o.fs:SetWidth(0)
    o.fs:SetJustifyH(JUSTIFY[e.j] or "CENTER")
    o.fs:SetText(e.l or "")
    o.fs:SetTextColor(r, g, b)
    o.fs:Show()
    -- a long text wraps onto several lines
    local w = o.fs:GetStringWidth() or 40
    local wrapW = textBox(e) * self.s
    if w > wrapW then
        o.fs:SetWidth(wrapW)
        w = wrapW
    end
    local lines = max(1, floor((o.fs:GetStringHeight() or 0) / max(1, o.fs:GetLineHeight() or 12) + 0.5))
    e._w = w / self.s
    e._h = textSize(e) * 1.4 / 0.7 * lines
    o.hide = function() o.fs:Hide() end
end

function Canvas:RenderSlot(e)
    local L = self.layer
    local o = acquire(self, "slot", function(L)
        local t = {}
        t.bg = L:CreateTexture(nil, "OVERLAY", nil, 1)
        t.edge = L:CreateTexture(nil, "OVERLAY", nil, 0)
        t.fs = newFS(L)
        return t
    end)
    local text = self.opts.slotText and self.opts.slotText(e.r) or e.r
    o.fs:SetFont(fontPath(), self:FontSize(11), "OUTLINE")
    o.fs:ClearAllPoints()
    o.fs:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    o.fs:SetWidth(0)
    o.fs:SetText(text)
    o.fs:Show()
    local w = (o.fs:GetStringWidth() or 40) + 10
    local h = self:FontSize(11) + 6
    o.bg:ClearAllPoints()
    o.bg:SetPoint("CENTER", o.fs, "CENTER")
    o.bg:SetSize(w, h)
    o.bg:SetColorTexture(0, 0, 0, 0.72)
    o.bg:Show()
    local lit = self.lit and self.lit[e]
    o.edge:ClearAllPoints()
    o.edge:SetPoint("CENTER", o.fs, "CENTER")
    o.edge:SetSize(w + 2, h + 2)
    o.edge:SetColorTexture(lit and 1 or 0.85, lit and 0.85 or 0.7, lit and 0.1 or 0.3, lit and 1 or 0.8)
    o.edge:Show()
    e._w, e._h = w / self.s, h / self.s
    o.hide = function()
        o.bg:Hide()
        o.edge:Hide()
        o.fs:Hide()
    end
end

local RENDER = { z = "RenderZone", a = "RenderArrow", i = "RenderIcon", x = "RenderText", s = "RenderSlot" }

---------------------------------------------------------------------------
-- Geometry, groups
---------------------------------------------------------------------------

local function segDist(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local len2 = dx * dx + dy * dy
    local t = len2 > 0 and max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / len2)) or 0
    local qx, qy = x1 + t * dx, y1 + t * dy
    return sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

-- The element bounds (board units): left, top, right, bottom.
local function bounds(e)
    if e.t == "z" then return e.x - e.w / 2, e.y - e.h / 2, e.x + e.w / 2, e.y + e.h / 2 end
    if e.t == "a" then return min(e.x, e.x2), min(e.y, e.y2), max(e.x, e.x2), max(e.y, e.y2) end
    if e.t == "i" then
        local r = (e.z or 32) / 2
        return e.x - r, e.y - r, e.x + r, e.y + r + (e.l and 18 or 0)
    end
    local w, h = (e._w or 60) / 2, (e._h or 20) / 2
    return e.x - w, e.y - h, e.x + w, e.y + h
end

local function unionBounds(list)
    local l, t, r, b
    for _, e in ipairs(list) do
        local a, bb, c, d = bounds(e)
        l, t = l and min(l, a) or a, t and min(t, bb) or bb
        r, b = r and max(r, c) or c, b and max(b, d) or d
    end
    return l, t, r, b
end

local function hits(e, x, y, tol)
    if e.t == "a" then return segDist(x, y, e.x, e.y, e.x2, e.y2) <= tol end
    if e.t == "z" and e.s == "c" then
        local rx, ry = e.w / 2, e.h / 2
        return ((x - e.x) / rx) ^ 2 + ((y - e.y) / ry) ^ 2 <= 1
    end
    local l, t, r, b = bounds(e)
    return x >= l - tol / 2 and x <= r + tol / 2 and y >= t - tol / 2 and y <= b + tol / 2
end
MapUI.Hits = hits

-- An element and the rest of its group (page order).
function Canvas:GroupOf(e)
    if not e or not e.g then return { e } end
    local out = {}
    for _, x in ipairs(self.page and self.page.e or {}) do
        if x.g == e.g then out[#out + 1] = x end
    end
    return out
end

-- The link of an element's group (the first member with one).
function Canvas:LinkOf(e)
    for _, x in ipairs(self:GroupOf(e)) do
        if x.ln then return x.ln end
        if x.t == "s" then return x.r end
    end
    return nil
end

---------------------------------------------------------------------------
-- Render
---------------------------------------------------------------------------

-- The names (or, editing, the link) under linked drawings: once per group.
function Canvas:RenderLinks()
    if not self.opts.linkText then return end
    local done = {}
    for _, e in ipairs(self.page.e or {}) do
        if e.ln and e.t ~= "s" and not (e.g and done[e.g]) then
            local members = self:GroupOf(e)
            if e.g then done[e.g] = true end
            local text = self.opts.linkText(e.ln)
            if text and text ~= "" then
                local l, _, r, b = unionBounds(members)
                if e.t == "z" and not e.g then b = e.y + (e.l and 14 or 0) end
                local o = acquire(self, "link", function(L)
                    return { fs = newFS(L) }
                end, true)
                o.fs:SetFont(fontPath(), self:FontSize(11), "OUTLINE")
                o.fs:ClearAllPoints()
                o.fs:SetPoint("TOP", self.layer, "TOPLEFT", (l + r) / 2 * self.s, -(b + 2) * self.s)
                o.fs:SetWidth(0)
                o.fs:SetText(text)
                o.fs:Show()
                o.hide = function() o.fs:Hide() end
            end
        end
    end
end

function Canvas:Render()
    if self:Is3D() then
        -- the room draws itself on its next frame (the small map in its corner too)
        self.v3:Invalidate()
        self.v3.insetStale = true
        self:UpdateHint()
        return
    end
    self:RenderBackground()
    for _, pool in pairs(self.pools) do
        for i = 1, #pool do
            if pool[i].hide then pool[i].hide() end
            if pool[i].holder then pool[i].holder:Hide() end
        end
    end
    self.used = {}
    local page = self.page
    if page then
        -- stacking: zones under everything else, each band in page order (Bring to front / Send to back move a
        -- drawing to the end / start of the page's list)
        local base = self.layer:GetFrameLevel()
        local zi, oi = 0, 0
        for _, e in ipairs(page.e or {}) do
            if e.t == "z" then
                zi = zi + 1
                self:RenderZone(e)
                self.lastObj.holder:SetFrameLevel(base + zi)
            end
        end
        -- game objects' beams: over the zones, under every icon
        for _, b in ipairs(SO().Beams(page)) do
            self:RenderBeam(b)
            self.lastObj.holder:SetFrameLevel(base + 99)
        end
        for _, e in ipairs(page.e or {}) do
            if e.t ~= "z" and RENDER[e.t] then
                oi = oi + 1
                self[RENDER[e.t]](self, e)
                self.lastObj.holder:SetFrameLevel(base + 100 + oi)
            end
        end
        self:RenderLinks()
    end
    self:RenderSelection()
    self:UpdateHint()
end

---------------------------------------------------------------------------
-- Selection
---------------------------------------------------------------------------

-- The topmost element at a board point (small elements before zones). In the room: what is under the mouse.
function Canvas:HitTest(x, y)
    if self:Is3D() then return self.v3:HitTest() end
    local list = self.page and self.page.e or {}
    local tol = 6 / self.s
    for i = #list, 1, -1 do
        local e = list[i]
        if e.t ~= "z" and hits(e, x, y, tol) then return e, i end
    end
    for i = #list, 1, -1 do
        local e = list[i]
        if e.t == "z" and hits(e, x, y, tol) then return e, i end
    end
    return nil
end

-- The selected elements, in page order.
function Canvas:Selection()
    local out = {}
    for _, e in ipairs(self.page and self.page.e or {}) do
        if self.sel[e] then out[#out + 1] = e end
    end
    return out
end

function Canvas:SelectionCount()
    local n = 0
    for _ in pairs(self.sel) do n = n + 1 end
    return n
end

function Canvas:NotifySelect()
    self:RenderSelection()
    if self.opts.onSelect then self.opts.onSelect(self.selected) end
end

function Canvas:ClearSelection()
    self.sel, self.selected = {}, nil
    self:NotifySelect()
end

-- Selects an element with its group (add = keep the current selection).
function Canvas:Select(e, add)
    if not add then self.sel = {} end
    if e then
        for _, x in ipairs(self:GroupOf(e)) do self.sel[x] = true end
    end
    self.selected = e or (add and self.selected) or nil
    self:NotifySelect()
end

function Canvas:ToggleSelect(e)
    if self.sel[e] then
        for _, x in ipairs(self:GroupOf(e)) do self.sel[x] = nil end
        if self.selected and not self.sel[self.selected] then self.selected = self:Selection()[1] end
        self:NotifySelect()
    else
        self:Select(e, true)
    end
end

function Canvas:SelectAll()
    self.sel = {}
    for _, e in ipairs(self.page and self.page.e or {}) do self.sel[e] = true end
    self.selected = self.page and self.page.e[1] or nil
    self:NotifySelect()
end

function Canvas:GetSelected() return self.selected end

-- How the selected texts are aligned: "l" | "c" | "r" (nil: no text selected, or they differ).
function Canvas:TextAlign()
    local j, any
    for _, e in ipairs(self:Selection()) do
        if e.t == "x" then
            local ej = e.j or "c"
            if any and ej ~= j then return nil, true end
            j, any = ej, true
        end
    end
    return j, any or false
end

-- Aligns the lines of the selected texts inside their boxes: "l" | "c" | "r".
function Canvas:SetTextAlign(j)
    local changed = false
    for _, e in ipairs(self:Selection()) do
        if e.t == "x" and (e.j or "c") ~= j then
            e.j = (j == "l" or j == "r") and j or nil
            changed = true
        end
    end
    if changed then self:Changed() end
end

-- A handle of the only selected element under the point: "end1" | "end2" | "size" | "isize" | "xsize" | nil.
-- (In the room only a zone's size and an arrow's ends have one; icons and texts size from their menu.)
function Canvas:HandleAt(x, y)
    if self:Is3D() then return self.v3:HandleAt() end
    local e = self.selected
    if not e or self:SelectionCount() ~= 1 then return nil end
    local tol = 8 / self.s
    if e.t == "a" then
        if abs(x - e.x2) <= tol and abs(y - e.y2) <= tol then return "end2" end
        if abs(x - e.x) <= tol and abs(y - e.y) <= tol then return "end1" end
    elseif e.t == "z" then
        if abs(x - (e.x + e.w / 2)) <= tol and abs(y - (e.y + e.h / 2)) <= tol then return "size" end
    elseif e.t == "i" then
        local r = (e.z or 32) / 2
        if abs(x - (e.x + r)) <= tol and abs(y - (e.y + r)) <= tol then return "isize" end
    elseif e.t == "x" then
        local w, h = (e._w or 60) / 2, (e._h or 20) / 2
        if abs(x - (e.x + w)) <= tol and abs(y - (e.y + h)) <= tol then return "xsize" end
    end
    return nil
end

-- color (r, g, b) and name: the box of what another member has selected (a live board), in their colour.
function Canvas:SelBox(l, t, r, b, grouped, color, name)
    local o = acquire(self, "box", function(L)
        local edges = {}
        for i = 1, 4 do edges[i] = L:CreateTexture(nil, "OVERLAY", nil, 6) end
        return { edges = edges, tag = newFS(L) }
    end, true)
    local px, py = self:P(l, t)
    local w, h = (r - l) * self.s, (b - t) * self.s
    local E = o.edges
    local a = grouped and 0.55 or 0.95
    for i = 1, 4 do
        E[i]:ClearAllPoints()
        if color then
            E[i]:SetColorTexture(color[1], color[2], color[3], 0.9)
        else
            E[i]:SetColorTexture(1, 0.85, 0.1, a)
        end
        E[i]:Show()
    end
    if name then
        o.tag:SetFont(fontPath(), self:FontSize(10), "OUTLINE")
        o.tag:ClearAllPoints()
        o.tag:SetPoint("BOTTOMLEFT", self.layer, "TOPLEFT", px - 2, py + 3)
        o.tag:SetTextColor(color[1], color[2], color[3])
        o.tag:SetText(name)
        o.tag:Show()
    else
        o.tag:Hide()
    end
    E[1]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py + 2); E[1]:SetSize(w + 4, 1)
    E[2]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py - h - 2); E[2]:SetSize(w + 4, 1)
    E[3]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py + 2); E[3]:SetSize(1, h + 4)
    E[4]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px + w + 2, py + 2); E[4]:SetSize(1, h + 4)
    o.hide = function()
        for i = 1, 4 do E[i]:Hide() end
        o.tag:Hide()
    end
end

function Canvas:RenderSelection()
    if self:Is3D() then
        if self.page then
            -- (drop selected elements that are gone, as below)
            local present = {}
            for _, e in ipairs(self.page.e) do present[e] = true end
            for e in pairs(self.sel) do if not present[e] then self.sel[e] = nil end end
            if self.selected and not self.sel[self.selected] then self.selected = self:Selection()[1] end
        end
        self.v3:Invalidate()
        return
    end
    local pool = self.pools.box
    for i = 1, #pool do
        pool[i].hide()
        pool[i].holder:Hide()
    end
    self.used.box = 0
    for _, h in ipairs(self.handles) do h:Hide() end
    if not self:Editable() or not self.page then return end
    -- drop selected elements that are gone (undo, delete)
    local present = {}
    for _, e in ipairs(self.page.e) do present[e] = true end
    for e in pairs(self.sel) do if not present[e] then self.sel[e] = nil end end
    if self.selected and not self.sel[self.selected] then self.selected = self:Selection()[1] end
    local groups = {}
    for _, e in ipairs(self:Selection()) do
        local l, t, r, b = bounds(e)
        self:SelBox(l, t, r, b, e.g ~= nil)
        if e.g then groups[e.g] = true end
    end
    -- a group gets one box around all its members
    for g in pairs(groups) do
        local l, t, r, b = unionBounds(self:GroupOf({ g = g }))
        if l then self:SelBox(l - 4, t - 4, r + 4, b + 4) end
    end
    -- what the members on the same live board have selected: one box each, with the name
    for _, other in ipairs(self.opts.remoteSel and self.opts.remoteSel() or {}) do
        local list = {}
        for _, e in ipairs(self.page.e) do
            if e._u and other.sel[e._u] then list[#list + 1] = e end
        end
        if #list > 0 then
            local l, t, r, b = unionBounds(list)
            self:SelBox(l - 3, t - 3, r + 3, b + 3, false, { other.r, other.g, other.b },
                ns.Util.ShortName(other.key))
        end
    end
    local e = self.selected
    if not e or self:SelectionCount() ~= 1 then return end
    local function handle(i, x, y)
        local hd = self.handles[i]
        hd:ClearAllPoints()
        hd:SetPoint("CENTER", self.layer, "TOPLEFT", x * self.s, -y * self.s)
        hd:Show()
    end
    if e.t == "a" then
        handle(1, e.x, e.y)
        handle(2, e.x2, e.y2)
    elseif e.t == "z" then
        handle(1, e.x + e.w / 2, e.y + e.h / 2)
    elseif e.t == "i" then
        handle(1, e.x + (e.z or 32) / 2, e.y + (e.z or 32) / 2)
    elseif e.t == "x" then
        handle(1, e.x + (e._w or 60) / 2, e.y + (e._h or 20) / 2)
    end
end

-- "blk" | "blk.col" | "blk.row.col" -> block, row|nil, col|nil
local function parseRef(ref)
    if type(ref) ~= "string" then return nil end
    local b, r, c = ref:match("^(%w+)%.(%d+)%.(%d+)$")
    if b then return b, tonumber(r), tonumber(c) end
    b, c = ref:match("^(%w+)%.(%d+)$")
    if b then return b, nil, tonumber(c) end
    return ref:match("^(%w+)$"), nil, nil
end
MapUI.ParseRef = parseRef

-- Do two block references overlap (same block; a missing row / column matches any)?
function MapUI:RefsOverlap(a, b)
    local ab, ar, ac = parseRef(a)
    local bb, br, bc = parseRef(b)
    if not ab or ab ~= bb then return false end
    if ar and br and ar ~= br then return false end
    if ac and bc and ac ~= bc then return false end
    return true
end

-- Highlights the drawings linked to a block reference (from the blocks panel), nil clears.
function Canvas:Highlight(ref)
    local lit
    if ref then
        for _, e in ipairs(self.page and self.page.e or {}) do
            local other = self:LinkOf(e)
            if other and MapUI:RefsOverlap(ref, other) then
                lit = lit or {}
                lit[e] = true
            end
        end
    end
    self.lit = lit
    self:Render()
end

function Canvas:SetHover(e)
    if e == self.hoverEl then return end
    self.hoverEl = e
    GameTooltip:Hide()
    local link = e and self:LinkOf(e) or nil
    if e then
        local tip = self.opts.slotTip
        if link and tip then
            GameTooltip:SetOwner(self.frame, "ANCHOR_CURSOR")
            if e.t == "i" or e.l then GameTooltip:AddLine(e.l or MapUI:IconName(e.i)) end
            tip(link, GameTooltip)
            GameTooltip:Show()
        elseif e.t == "i" and not self:Editable() then
            GameTooltip:SetOwner(self.frame, "ANCHOR_CURSOR")
            GameTooltip:AddLine(e.l or MapUI:IconName(e.i))
            GameTooltip:Show()
        elseif self:Editable() and self.tool == "select" then
            GameTooltip:SetOwner(self.frame, "ANCHOR_CURSOR")
            GameTooltip:AddLine("Not linked", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Shift-drag it onto a table cell or column to link it.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end
    end
    if self.opts.onHover then self.opts.onHover(link) end
end

function Canvas:UpdateHover()
    if not self.frame:IsVisible() then return end
    local x, y = self:Cursor()
    self:SetHover((self:HitTest(x, y)))
end

---------------------------------------------------------------------------
-- Editing
---------------------------------------------------------------------------

local function room(self, n)
    if #self.page.e + (n or 1) > S().MAX_ELEMENTS then
        ns:Print("A page holds at most %d drawings.", S().MAX_ELEMENTS)
        return false
    end
    return true
end

function Canvas:Add(e)
    if not room(self) then return nil end
    tinsert(self.page.e, e)
    return e
end

-- The icon menu's models option for this canvas: the encounter's assets, and their groups placed at their spots.
function Canvas:SpawnMenu()
    return { onGroup = function(grp) self:PlaceSpawns(grp) end }
end

-- A group of the encounter's assets (Data/EncounterSpawns.lua) onto the page where the script puts them (the page
-- must show the group's floor map; the save check's 50 units past an edge is as far as they may lie), selected.
function Canvas:PlaceSpawns(grp)
    local bossRef = self.opts.bossRef and self.opts.bossRef()
    local spawns = SO().Spawns(bossRef)
    local page = self.page
    local m = page and MapUI:ShippedMap(page.m)
    if not (spawns and m and m.file == spawns.map) then
        local name = spawns and spawns.map
        for _, sm in ipairs(SHIPPED) do if sm.file == name then name = sm.name end end
        ns:Print("These spots are on the %s map: pick it for this page first.", tostring(name))
        return
    end
    -- (the board's own map math, as R3.BoardToRoom: the map pixel at the board's middle, board units per pixel)
    local LW, LH = SHIPPED_LAYER.layerWidth, SHIPPED_LAYER.layerHeight
    local cx, cy = (page.vx or 500) / 1000 * LW, (page.vy or 500) / 1000 * LH
    local k = min(BW / LW, BH / LH) * (page.vz or 100) / 100
    local function board(mx, my)
        return floor((mx / 1000 * LW - cx) * k + BW / 2 + 0.5), floor((my / 1000 * LH - cy) * k + BH / 2 + 0.5)
    end
    local function inside(bx, by) return bx >= -50 and bx <= BW + 50 and by >= -50 and by <= BH + 50 end
    local list = {}
    for _, s in ipairs(grp.e) do
        local bx, by = board(s.mx, s.my)
        if s.a then                                  -- an arrow (a route, a line the boss draws)
            local bx2, by2 = board(s.mx2, s.my2)
            if inside(bx, by) and inside(bx2, by2) then
                list[#list + 1] = { t = "a", x = bx, y = by, x2 = bx2, y2 = by2, h = true, c = s.c }
            end
        elseif s.z then                              -- a zone (a radius, an area the boss uses)
            if inside(bx, by) then
                local w = min(BW, max(4, floor(2 * s.hx / 1000 * LW * k + 0.5)))
                local h = min(BW, max(4, floor(2 * s.hy / 1000 * LH * k + 0.5)))
                list[#list + 1] = { t = "z", s = s.z, x = bx, y = by, w = w, h = h, c = s.c, l = s.l }
            end
        elseif inside(bx, by) then
            local label = s.l or grp.l
            local e = MapUI:NewIcon(bx, by, s.i, { label = label }, bossRef)
            if label then e.l = label end
            e.f, e.st = s.f, s.st
            list[#list + 1] = e
        end
    end
    if #list == 0 then
        ns:Print("None of these spots is in this page's view: zoom out or move the map.")
        return
    end
    if not room(self, #list) then return end
    for _, e in ipairs(list) do tinsert(page.e, e) end
    self:SetTool("select")
    self:Changed()
    self:ClearSelection()
    for _, e in ipairs(list) do self:Select(e, true) end
end

-- Adds an element and selects it (tools and menus).
function Canvas:Place(e)
    e = self:Add(e)
    if not e then return nil end
    self:SetTool("select")
    self:Changed()
    self:Select(e)
    return e
end

function Canvas:RemoveList(list)
    local gone = {}
    for _, e in ipairs(list) do gone[e] = true end
    local keep = {}
    for _, e in ipairs(self.page.e) do
        if not gone[e] then keep[#keep + 1] = e end
    end
    -- in place: the page table is shared with the board's draft
    for i = #self.page.e, 1, -1 do self.page.e[i] = nil end
    for i, e in ipairs(keep) do self.page.e[i] = e end
    self.sel, self.selected = {}, nil
    self:NotifySelect()
    self:Changed()
end

function Canvas:Remove(e) self:RemoveList(self:GroupOf(e)) end

function Canvas:DeleteSelection()
    local list = self:Selection()
    if #list == 0 then return false end
    self:RemoveList(list)
    return true
end

local function copyElement(e)
    local c = {}
    for k, v in pairs(e) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" then c[k] = v end
    end
    return c
end

function Canvas:Copy()
    local list = self:Selection()
    if #list == 0 then return false end
    local clip = {}
    for _, e in ipairs(list) do clip[#clip + 1] = copyElement(e) end
    MapUI.clipboard = clip
    self.pasteCount = 0
    return true
end

-- A group id not used on the page.
function Canvas:NewGroupId()
    local used = {}
    for _, e in ipairs(self.page.e) do if e.g then used[e.g] = true end end
    for i = 1, 999 do
        if not used["g" .. i] then return "g" .. i end
    end
end

-- Pastes the clipboard (offset a little each time; groups stay groups, links to blocks this strategy lacks go).
function Canvas:Paste(atX, atY)
    local clip = MapUI.clipboard
    if not clip or #clip == 0 or not self.page then return false end
    if not room(self, #clip) then return false end
    self.pasteCount = (self.pasteCount or 0) + 1
    local dx, dy = 20 * self.pasteCount, 20 * self.pasteCount
    if atX then
        local l, t, r, b = unionBounds(clip)
        dx, dy = atX - (l + r) / 2, atY - (t + b) / 2
    end
    local groups = {}
    self.sel = {}
    local valid = self.opts.validRef
    for _, src in ipairs(clip) do
        local e = copyElement(src)
        e.x, e.y = floor(max(0, min(BW, e.x + dx))), floor(max(0, min(BH, e.y + dy)))
        if e.x2 then e.x2, e.y2 = floor(max(0, min(BW, e.x2 + dx))), floor(max(0, min(BH, e.y2 + dy))) end
        if e.g then
            groups[e.g] = groups[e.g] or self:NewGroupId()
            e.g = groups[e.g]
            -- reserve it before the next NewGroupId call
            tinsert(self.page.e, e)
        else
            tinsert(self.page.e, e)
        end
        if e.ln and valid and not valid(e.ln) then e.ln = nil end
        if e.t == "s" and valid and not valid(e.r) then
            tremove(self.page.e)
        else
            self.sel[e] = true
            self.selected = e
        end
    end
    self:Changed()
    self:NotifySelect()
    return true
end

function Canvas:Duplicate()
    if not self:Copy() then return false end
    return self:Paste()
end

function Canvas:GroupSelection()
    local list = self:Selection()
    if #list < 2 then return false end
    local g = self:NewGroupId()
    for _, e in ipairs(list) do e.g = g end
    -- one link for the whole group: the first member's
    local ln
    for _, e in ipairs(list) do ln = ln or e.ln end
    for _, e in ipairs(list) do if e.t ~= "s" then e.ln = ln end end
    self:Changed()
    self:NotifySelect()
    return true
end

function Canvas:UngroupSelection()
    local any = false
    for _, e in ipairs(self:Selection()) do
        if e.g then
            e.g = nil
            any = true
        end
    end
    if any then self:Changed() end
    return any
end

-- Links the selection (or an element's group) to a block reference (nil = unlink).
function Canvas:LinkList(list, ref)
    for _, e in ipairs(list) do
        if e.t == "s" then
            if ref and ref:find("^%w+%.%d+%.%d+$") then e.r = ref end
        else
            e.ln = ref
        end
    end
    self:Changed()
end

function Canvas:Nudge(dx, dy)
    local list = self:Selection()
    if #list == 0 then return false end
    for _, e in ipairs(list) do
        e.x, e.y = max(0, min(BW, e.x + dx)), max(0, min(BH, e.y + dy))
        if e.x2 then e.x2, e.y2 = max(0, min(BW, e.x2 + dx)), max(0, min(BH, e.y2 + dy)) end
    end
    self:Changed()
    return true
end

function Canvas:Reorder(list, toFront)
    local set = {}
    for _, e in ipairs(list) do set[e] = true end
    local rest, moved = {}, {}
    for _, e in ipairs(self.page.e) do
        if set[e] then moved[#moved + 1] = e else rest[#rest + 1] = e end
    end
    local out = {}
    if toFront then
        for _, e in ipairs(rest) do out[#out + 1] = e end
        for _, e in ipairs(moved) do out[#out + 1] = e end
    else
        for _, e in ipairs(moved) do out[#out + 1] = e end
        for _, e in ipairs(rest) do out[#out + 1] = e end
    end
    for i = #self.page.e, 1, -1 do self.page.e[i] = nil end
    for i, e in ipairs(out) do self.page.e[i] = e end
    self:Changed()
end

-- A block reference dropped on the map (a player cell dragged from a table): links the drawing under the cursor,
-- or places a name marker there.
function Canvas:DropRefAtCursor(ref)
    if not self.page or not self:Editable() then return false end
    local x, y = self:Cursor()
    local e = self:HitTest(x, y)
    if e then
        self:LinkList(self:GroupOf(e), ref)
        self:Select(e)
        return true
    end
    if not ref:find("^%w+%.%d+%.%d+$") then return false end
    return self:Place({ t = "s", x = x, y = y, r = ref }) ~= nil
end

-- Keyboard (the board calls this while editing). Returns true when the key was used.
function Canvas:OnKey(key)
    if not self:Editable() or not self.page then return false end
    local ctrl, shift = IsControlKeyDown(), IsShiftKeyDown()
    if key == "DELETE" or key == "BACKSPACE" then return self:DeleteSelection() end
    if key == "ESCAPE" then
        if self:SelectionCount() > 0 or self.tool ~= "select" then
            self:SetTool("select")
            self:ClearSelection()
            return true
        end
        return false
    end
    local step = shift and 10 or 2
    if key == "LEFT" then return self:Nudge(-step, 0) end
    if key == "RIGHT" then return self:Nudge(step, 0) end
    if key == "UP" then return self:Nudge(0, -step) end
    if key == "DOWN" then return self:Nudge(0, step) end
    if self:Is3D() and not ctrl and self.v3:OnKey(key) then return true end
    if not ctrl then return false end
    if key == "A" then self:SelectAll(); return true end
    if key == "C" then return self:Copy() end
    if key == "X" then return self:Copy() and self:DeleteSelection() end
    if key == "V" then return self:Paste() end
    if key == "D" then return self:Duplicate() end
    if key == "G" then
        if shift then return self:UngroupSelection() end
        return self:GroupSelection()
    end
    return false
end

local function snap(v)
    return floor(v / 10 + 0.5) * 10
end

local ghost
local function linkGhost()
    if ghost then return ghost end
    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetSize(10, 18)
    ghost:SetFrameStrata("TOOLTIP")
    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints()
    ghost.bg:SetColorTexture(0, 0, 0, 0.8)
    ghost.fs = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ghost.fs:SetPoint("LEFT", 4, 0)
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", x / s + 12, y / s)
        self:SetWidth((self.fs:GetStringWidth() or 60) + 8)
    end)
    ghost:Hide()
    return ghost
end

local function editLabel(self, e)
    if not (e.t == "z" or e.t == "i" or e.t == "x") then return end
    self.opts.prompt(e.t == "x" and "Text" or "Label", e.l or "", function(text)
        if e.t == "x" then
            text = S().TidyText(text, S().MAX_TEXT)
        else
            text = ns.Util.Trim(text or ""):gsub("|", ""):sub(1, S().MAX_LABEL)
        end
        if text == "" then
            if e.t == "x" then return end
            e.l = nil
        else
            e.l = text
        end
        self:Changed()
    end, e.t == "x", e.t == "x" and S().MAX_TEXT or nil)
end

-- A right click (in the room: a right button released without turning the view): the drawing's menu or the map's;
-- reading, only "View from here" on a drawing whose page has a room.
function Canvas:RightClick(x, y)
    local e = self:HitTest(x, y)
    if not self:Editable() then
        if e and self:Room3D() then
            local names = { z = "Zone", a = "Arrow", i = "Icon", x = "Text", s = "Name marker" }
            ns.UI:ContextMenu(self.frame, function(root)
                root:CreateTitle((e.l and (e.l:gsub("\n", " "))) or names[e.t] or "Drawing")
                root:CreateButton(self:Is3D() and "View from here" or "View from here in 3D", function() self:ViewFrom3D(e) end)
            end)
        end
        return
    end
    if e then
        if not self.sel[e] then self:Select(e) end
        self.selected = e
        self:ElementMenu(e)
    else
        self:BackgroundMenu(x, y)
    end
end

function Canvas:OnMouseDown(button)
    if not self.page then return end
    -- in the room the camera takes the right and middle buttons (and the left one to move the view)
    if self:Is3D() and self.v3:MouseDown(button, self:Editable(), self.tool) then return end
    local x, y = self:Cursor()
    if button == "RightButton" then
        self:RightClick(x, y)
        return
    end
    if not self:Editable() then return end
    if button ~= "LeftButton" then return end
    local tool = self.tool
    if tool == "select" then
        local h = self:HandleAt(x, y)
        if h then
            local e = self.selected
            self.drag = { mode = h, el = e }
            if h == "xsize" then
                -- a text grows from its centre: the corner's distance at the start is its size now
                self.drag.z0, self.drag.w0 = textSize(e), e.w
                self.drag.r0 = max(4, sqrt(((e._w or 60) / 2) ^ 2 + ((e._h or 20) / 2) ^ 2))
            end
            return
        end
        local e = self:HitTest(x, y)
        if not e then
            if not (IsShiftKeyDown() or IsControlKeyDown()) then self:ClearSelection() end
            self.drag = { mode = "marquee", sx = x, sy = y }
            return
        end
        -- double click: edit the label / text
        local now = GetTime()
        if self.lastClick and self.lastClick.e == e and now - self.lastClick.at < 0.35 then
            self.lastClick = nil
            editLabel(self, e)
            return
        end
        self.lastClick = { e = e, at = now }
        if IsShiftKeyDown() then
            -- Shift: a drag links it (to a table), a click adds / removes it from the selection
            self.drag = { mode = "pending", el = e, sx = x, sy = y }
            return
        end
        if IsControlKeyDown() then
            self:ToggleSelect(e)
            return
        end
        if not self.sel[e] then self:Select(e) else self.selected = e end
        local orig = {}
        for _, m in ipairs(self:Selection()) do orig[m] = { m.x, m.y, m.x2, m.y2 } end
        self.drag = { mode = "move", el = e, sx = x, sy = y, orig = orig }
    elseif tool == "pan" then
        local L = ArtLayer(self.page.m)
        if not L then
            ns:Print("Pick a map first (right-click the map).")
            return
        end
        self.drag = { mode = "pan", sx = x, sy = y, vx = self.page.vx or 500, vy = self.page.vy or 500, L = L }
    elseif tool == "circle" or tool == "rect" then
        local e = self:Add({ t = "z", s = tool == "circle" and "c" or "r", x = x, y = y, w = 4, h = 4, c = self.color })
        if e then self.drag = { mode = "create", el = e, sx = x, sy = y } end
    elseif tool == "arrow" or tool == "line" then
        local e = self:Add({ t = "a", x = x, y = y, x2 = x, y2 = y, c = self.color, h = tool == "arrow" or nil })
        if e then self.drag = { mode = "create", el = e, sx = x, sy = y } end
    elseif tool == "icon" then
        self:IconAt(x, y)
    elseif tool == "text" then
        self:TextAt(x, y)
    end
end

function Canvas:IconAt(x, y)
    if not room(self) then return end
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle("Icon")
        local bossRef = self.opts.bossRef and self.opts.bossRef()
        MapUI:BuildIconMenu(root, nil, function(key, extra)
            self:Place(MapUI:NewIcon(x, y, key, extra, bossRef))
        end, self.opts.prompt, bossRef, self:SpawnMenu())
    end)
end

function Canvas:TextAt(x, y)
    if not room(self) then return end
    self.opts.prompt("Text", "", function(text)
        text = S().TidyText(text, S().MAX_TEXT)
        if text == "" then return end
        self:Place({ t = "x", x = x, y = y, l = text, c = self.color == 1 and 9 or self.color, z = 2 })
    end, true, S().MAX_TEXT)
end

function Canvas:OnDragUpdate()
    local d = self.drag
    if not d then return end
    if not IsMouseButtonDown("LeftButton") then
        self:OnMouseUp("LeftButton")
        return
    end
    local x, y = self:Cursor()
    local e = d.el
    if d.mode == "pending" then
        if abs(x - d.sx) + abs(y - d.sy) > 6 then
            d.mode = "link"
            local g = linkGhost()
            g.fs:SetText("Link " .. ((e.l and e.l:gsub("\n", " ")) or MapUI:IconName(e.i) or "drawing")
                .. ": drop on a player, a target or a column")
            g:Show()
        end
        return
    elseif d.mode == "link" then
        return
    elseif d.mode == "move" then
        local dx, dy = x - d.sx, y - d.sy
        if IsAltKeyDown() then
            local o = d.orig[e]
            dx, dy = snap(o[1] + dx) - o[1], snap(o[2] + dy) - o[2]
        end
        for m, o in pairs(d.orig) do
            m.x, m.y = o[1] + dx, o[2] + dy
            if m.t == "a" then m.x2, m.y2 = o[3] + dx, o[4] + dy end
        end
    elseif d.mode == "marquee" then
        d.ex, d.ey = x, y
        if self:Is3D() then
            self:Render()                                -- (the room draws the box on the floor)
            return
        end
        local l, t = min(x, d.sx), min(y, d.sy)
        self.marq:ClearAllPoints()
        self.marq:SetPoint("TOPLEFT", self.layer, "TOPLEFT", l * self.s, -t * self.s)
        self.marq:SetSize(max(1, abs(x - d.sx) * self.s), max(1, abs(y - d.sy) * self.s))
        self.marq:Show()
        return
    elseif d.mode == "end1" then
        e.x, e.y = x, y
    elseif d.mode == "end2" then
        e.x2, e.y2 = x, y
    elseif d.mode == "size" then
        local l, t = e.x - e.w / 2, e.y - e.h / 2
        local w, h = max(8, x - l), max(8, y - t)
        if e.s == "c" and not IsShiftKeyDown() then w, h = max(w, h), max(w, h) end
        e.w, e.h = floor(w), floor(h)
        e.x, e.y = floor(l + e.w / 2), floor(t + e.h / 2)
    elseif d.mode == "mturn" or d.mode == "msize" then
        if self.v3 then self.v3:DragModelKnob(d, e, x, y) end
    elseif d.mode == "isize" then
        -- icons stay square around their centre
        e.z = max(12, min(96, floor(2 * max(abs(x - e.x), abs(y - e.y)) + 0.5)))
    elseif d.mode == "xsize" then
        if IsShiftKeyDown() then
            -- Shift: the width of the box (the text wraps inside), the size stays
            e.w = max(S().TEXT_BOX_MIN, min(S().BOARD_W, floor(2 * abs(x - e.x) + 0.5)))
        else
            -- the text grows and shrinks with the corner; a box set by hand scales along
            local z = floor(d.z0 * sqrt((x - e.x) ^ 2 + (y - e.y) ^ 2) / d.r0 + 0.5)
            e.z = max(S().TEXT_MIN, min(S().TEXT_MAX, z))
            if d.w0 then e.w = max(S().TEXT_BOX_MIN, min(S().BOARD_W, floor(d.w0 * e.z / d.z0 + 0.5))) end
        end
    elseif d.mode == "create" then
        if e.t == "a" then
            e.x2, e.y2 = x, y
        elseif e.s == "c" then
            local r = floor(sqrt((x - d.sx) ^ 2 + (y - d.sy) ^ 2))
            e.w, e.h = max(4, r * 2), max(4, r * 2)
        else
            e.x, e.y = floor((x + d.sx) / 2), floor((y + d.sy) / 2)
            e.w, e.h = max(4, abs(x - d.sx)), max(4, abs(y - d.sy))
        end
    elseif d.mode == "pan" then
        local L = d.L
        local base = min(self.w / L.layerWidth, self.h / L.layerHeight)
        local sc = base * ((self.page.vz or 100) / 100)
        -- board units -> layer pixels -> per-mille of the layer
        local dx = (x - d.sx) * self.s / sc / L.layerWidth * 1000
        local dy = (y - d.sy) * self.s / sc / L.layerHeight * 1000
        self.page.vx = max(0, min(1000, floor(d.vx - dx + 0.5)))
        self.page.vy = max(0, min(1000, floor(d.vy - dy + 0.5)))
        self.page.vz = self.page.vz or 100
    end
    self:Render()
end

function Canvas:OnMouseUp(button)
    if self:Is3D() then
        local r = self.v3:MouseUp(button)
        if r == "click" then
            local x, y = self:Cursor()
            self:RightClick(x, y)
            return
        elseif r then
            return
        end
    end
    local d = self.drag
    if not d then return end
    self.drag = nil
    local e = d.el
    if d.mode == "pending" then
        self:ToggleSelect(e)
        return
    elseif d.mode == "link" then
        if ghost then ghost:Hide() end
        local ref, target
        if self.opts.dropRef then ref, target = self.opts.dropRef() end
        local list = self.sel[e] and self:Selection() or self:GroupOf(e)
        if target and self.opts.onDropTarget then
            self.opts.onDropTarget(list, e, target)
            self:Select(e)
        elseif ref then
            self:LinkList(list, ref)
            self:Select(e)
        end
        return
    elseif d.mode == "marquee" then
        self.marq:Hide()
        if self:Is3D() then self:Render() end
        if not d.ex then return end
        local l, t, r, b = min(d.sx, d.ex), min(d.sy, d.ey), max(d.sx, d.ex), max(d.sy, d.ey)
        for _, x in ipairs(self.page.e) do
            local a, bb, c, dd = bounds(x)
            if c >= l and a <= r and dd >= t and bb <= b then
                for _, m in ipairs(self:GroupOf(x)) do self.sel[m] = true end
                self.selected = self.selected or x
            end
        end
        self:NotifySelect()
        return
    end
    if d.mode == "create" and e then
        -- a click without a drag makes a default-size shape
        if e.t == "a" and abs(e.x2 - e.x) + abs(e.y2 - e.y) < 10 then
            e.x2 = min(BW, e.x + 120)
        elseif e.t == "z" and e.w < 12 and e.h < 12 then
            e.w, e.h = 100, 100
        end
        self:SetTool("select")
        self:Select(e)
    end
    local moved = d.orig or (e and { [e] = true }) or {}
    for m in pairs(moved) do
        m.x, m.y = floor(max(0, min(BW, m.x)) + 0.5), floor(max(0, min(BH, m.y)) + 0.5)
        if m.x2 then m.x2, m.y2 = floor(max(0, min(BW, m.x2)) + 0.5), floor(max(0, min(BH, m.y2)) + 0.5) end
    end
    if d.mode == "move" and d.orig[e] and d.orig[e][1] == e.x and d.orig[e][2] == e.y then
        self:Render()     -- a click, not a move: nothing changed
        return
    end
    self:Changed()
end

function Canvas:OnWheel(delta)
    if self:Is3D() then
        self.v3:Wheel(delta)                             -- (the camera, for everyone: the page stays as it is)
        return
    end
    if not self:Editable() or not self.page or not ArtLayer(self.page.m) then return end
    local z = self.page.vz or 100
    z = max(100, min(1000, floor(z * (delta > 0 and 1.15 or 1 / 1.15) + 0.5)))
    self.page.vz = z
    self.page.vx, self.page.vy = self.page.vx or 500, self.page.vy or 500
    self:Changed()
end

-- Link targets as menu entries: every block, its player columns and its player slots.
function Canvas:BuildLinkMenu(root, current, onPick)
    root:CreateRadio("Not linked", function() return current == nil end, function() onPick(nil) end)
    local slots = self.opts.slots and self.opts.slots() or {}
    local byBlock, order = {}, {}
    for _, s in ipairs(slots) do
        if not byBlock[s.block] then
            byBlock[s.block] = { name = s.blockName, list = {} }
            order[#order + 1] = s.block
        end
        tinsert(byBlock[s.block].list, s)
    end
    for _, l in ipairs(self.opts.links and self.opts.links() or {}) do
        if not l.ref:find("%.") and not byBlock[l.ref] then
            byBlock[l.ref] = { name = l.label, list = {} }
            order[#order + 1] = l.ref
        end
    end
    for _, b in ipairs(order) do
        local info = byBlock[b]
        local sub = root:CreateButton(info.name)
        sub:CreateRadio("The whole block", function() return current == b end, function() onPick(b) end)
        for _, l in ipairs(self.opts.links and self.opts.links() or {}) do
            if l.ref:match("^" .. b .. "%.%d+$") then
                sub:CreateRadio("Column: " .. (l.col or l.label), function() return current == l.ref end, function() onPick(l.ref) end)
            end
        end
        for _, s in ipairs(info.list) do
            sub:CreateRadio(s.label, function() return current == s.ref end, function() onPick(s.ref) end)
        end
    end
end

function Canvas:ElementMenu(e)
    local list = self:Selection()
    if #list == 0 then list = { e } end
    local names = { z = "Zone", a = e.h and "Arrow" or "Line", i = "Icon", x = "Text", s = "Name marker" }
    local many = #list > 1
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle(many and (#list .. " selected" .. (e.g and " (group)" or "")) or (names[e.t] or "Element"))
        if not many and (e.t == "z" or e.t == "i" or e.t == "x") then
            root:CreateButton(e.t == "x" and "Edit text..." or "Label...", function() editLabel(self, e) end)
        end
        local col = root:CreateButton("Colour")
        for i, c in ipairs(COLORS) do
            col:CreateRadio(MapUI:Swatch(i) .. " " .. c[4], function() return (e.c or (e.t == "z" and 1 or 9)) == i end,
                function()
                    for _, m in ipairs(list) do if m.t ~= "s" then m.c = i end end
                    self.color = i
                    self:Changed()
                end)
        end
        -- raid mark badge (icons and zones)
        local markable = {}
        for _, m in ipairs(list) do if m.t == "i" or m.t == "z" then markable[#markable + 1] = m end end
        if #markable > 0 then
            local rm = root:CreateButton("Raid mark")
            rm:CreateRadio("None", function() return e.rm == nil end, function()
                for _, m in ipairs(markable) do m.rm = nil end
                self:Changed()
            end)
            for i = 1, 8 do
                rm:CreateRadio(MapUI:IconString("rt" .. i, 14) .. " " .. RT_NAMES[i], function() return e.rm == i end,
                    function()
                        for _, m in ipairs(markable) do m.rm = i end
                        self:Changed()
                    end)
            end
        end
        -- a game object's state (Data/EncounterObjects.lua): every selected object of the same kind together
        local def = e.t == "i" and SO().DefOf(e.i)
        if def and def.states and #def.states > 1 then
            local same = {}
            for _, m in ipairs(list) do
                if m.t == "i" and SO().DefOf(m.i) == def then same[#same + 1] = m end
            end
            local stm = root:CreateButton("State: " .. def.states[(SO().StateOf(e))].name)
            for n, st in ipairs(def.states) do
                stm:CreateRadio(st.name, function() return (SO().StateOf(e)) == n end, function()
                    for _, m in ipairs(same) do m.st = n > 1 and n or nil end
                    self:Changed()
                end)
            end
        end
        local link = root:CreateButton(e.t == "s" and "Shows the player of" or "Link to assignment")
        self:BuildLinkMenu(link, self:LinkOf(e), function(ref) self:LinkList(list, ref) end)
        if not many then
            if e.t == "z" then
                local shape = root:CreateButton("Shape")
                shape:CreateRadio("Circle", function() return e.s == "c" end, function() e.s = "c"; self:Changed() end)
                shape:CreateRadio("Rectangle", function() return e.s == "r" end, function() e.s = "r"; self:Changed() end)
            elseif e.t == "a" then
                root:CreateCheckbox("Arrowhead", function() return e.h == true end, function()
                    e.h = not e.h or nil
                    self:Changed()
                end)
            elseif e.t == "i" then
                local ic = root:CreateButton("Icon")
                MapUI:BuildIconMenu(ic, e.i, function(key, extra)
                    e.i, e.st = key, nil
                    if extra then e.ms = extra.ms end
                    self:Changed()
                end, self.opts.prompt, self.opts.bossRef and self.opts.bossRef(), true)
                local size = root:CreateButton("Size")
                for _, z in ipairs({ { 20, "Small" }, { 32, "Medium" }, { 48, "Large" }, { 72, "Huge" }, { 96, "Largest" } }) do
                    size:CreateRadio(z[2], function() return (e.z or 32) == z[1] end, function() e.z = z[1]; self:Changed() end)
                end
            elseif e.t == "x" then
                local size = root:CreateButton("Size")
                for i, label in ipairs({ "Small", "Normal", "Large" }) do
                    size:CreateRadio(label, function() return textSize(e) == TEXT_SIZES[i] end, function()
                        e.z = i
                        self:Changed()
                    end)
                end
                local align = root:CreateButton("Align")
                for _, a in ipairs({ { "l", "Left" }, { "c", "Centre" }, { "r", "Right" } }) do
                    align:CreateRadio(a[2], function() return (e.j or "c") == a[1] end, function() self:SetTextAlign(a[1]) end)
                end
                if e.w then
                    root:CreateButton("Fit the box to the text", function() e.w = nil; self:Changed() end)
                end
            end
        end
        root:CreateDivider()
        if many then
            root:CreateButton("Group  |cff808080Ctrl+G|r", function() self:GroupSelection() end)
        end
        local grouped = false
        for _, m in ipairs(list) do if m.g then grouped = true end end
        if grouped then root:CreateButton("Ungroup  |cff808080Ctrl+Shift+G|r", function() self:UngroupSelection() end) end
        root:CreateButton("Copy  |cff808080Ctrl+C|r", function() self:Copy() end)
        root:CreateButton("Duplicate  |cff808080Ctrl+D|r", function() self:Duplicate() end)
        root:CreateButton("Bring to front", function() self:Reorder(list, true) end)
        root:CreateButton("Send to back", function() self:Reorder(list, false) end)
        if not many and self:Room3D() then
            -- stand there in the room (an arrow: at its start, looking along it)
            root:CreateButton(self:Is3D() and "View from here" or "View from here in 3D", function() self:ViewFrom3D(e) end)
        end
        -- a boss / add model: back to facing the nearest player marker, back to its real size
        if not many and e.t == "i" and (e.f or e.ms) then
            if e.f then root:CreateButton("Face the nearest player marker", function() e.f = nil self:Changed() end) end
            if e.ms then root:CreateButton("Real size", function() e.ms = nil self:Changed() end) end
        end
        root:CreateButton("|cffff6060Delete|r  |cff808080Del|r", function() self:RemoveList(list) end)
    end)
end

function Canvas:BackgroundMenu(x, y)
    local page = self.page
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle("Add here")
        local ic = root:CreateButton("Icon")
        local ref = self.opts.bossRef and self.opts.bossRef()
        MapUI:BuildIconMenu(ic, nil, function(key, extra)
            self:Place(MapUI:NewIcon(x, y, key, extra, ref))
        end, self.opts.prompt, ref, self:SpawnMenu())
        root:CreateButton("Text...", function() self:TextAt(x, y) end)
        root:CreateButton("Circle zone", function()
            self:Place({ t = "z", s = "c", x = x, y = y, w = 100, h = 100, c = self.color })
        end)
        root:CreateButton("Rectangle zone", function()
            self:Place({ t = "z", s = "r", x = x, y = y, w = 140, h = 100, c = self.color })
        end)
        if MapUI.clipboard and #MapUI.clipboard > 0 then
            root:CreateButton("Paste here  |cff808080Ctrl+V|r", function() self:Paste(x, y) end)
        end
        root:CreateButton("Select all  |cff808080Ctrl+A|r", function() self:SelectAll() end)
        if self:Is3D() then
            -- the camera: look at this spot, or stand on it
            local v3 = self.v3
            root:CreateDivider()
            root:CreateButton("Look here", function()
                local rx, ry = ns.Render3D.BoardToRoom(v3.room, page, x, y)
                v3:LookAt(rx, ry, true)
            end)
            root:CreateButton("View from here", function() v3:ViewFrom({ t = "spot", x = x, y = y }) end)
            return                                       -- (the map is picked on the 2D map, where it shows)
        end
        root:CreateDivider()
        local map = root:CreateButton("Map: " .. MapUI:MapName(page.m))
        local bossRef = self.opts.bossRef and self.opts.bossRef()
        MapUI:BuildMapMenu(map, bossRef, page.m, function(id)
            page.m = id
            page.vx, page.vy, page.vz = 500, 500, 100
            self:Changed()
        end, self.opts.prompt)
        if ArtLayer(page.m) then
            root:CreateButton("Reset zoom", function()
                page.vx, page.vy, page.vz = 500, 500, 100
                self:Changed()
            end)
        end
    end)
end

function MapUI:OnInit()
    ns:RegisterSlash("maps", function(rest) MapUI:PrintMaps(rest) end,
        "list the raid maps the strategy boards can use (/dz maps <name> searches every map)")
end

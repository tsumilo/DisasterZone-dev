-- CDLoot: UI/StrategyMap.lua
-- The map canvas of a strategy page (Addendum K): the background (a built-in instance map, panned and zoomed by the
-- author, or a blank grid) and the drawn elements (zones, arrows / lines, icons, text, slot tokens). Everything is in
-- board units (1000 x 666) so a board looks the same at any size.
-- Editing: one tool at a time (select / move, pan the map, circle, rectangle, arrow, line, icon, text, slot token);
-- right-click an element for its menu, the mouse wheel zooms the map. All input goes through the canvas itself, which
-- hit-tests the elements (small ones before zones).
-- Also the shared look of the board: colours, icons (raid marks, roles, classes, spells, items) and the map list.
local addonName, ns = ...

local MapUI = ns:NewModule("StrategyMapUI")

local floor, max, min, abs, sqrt, ceil = math.floor, math.max, math.min, math.abs, math.sqrt, math.ceil
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

local MEDIA = "Interface\\AddOns\\CDLoot\\Media\\Strategy\\"
local TEX_DISC, TEX_RING, TEX_ARROW = MEDIA .. "disc", MEDIA .. "ring", MEDIA .. "arrow"

local function S() return ns.Strategy end
local function UI() return ns.UI end

local BW, BH = 1000, 666

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
    if not path then return "" end
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(path), size, size)
end

-- A short name of an icon key (tooltips, menus).
function MapUI:IconName(key)
    if type(key) ~= "string" then return "" end
    local rt = key:match("^rt([1-8])$")
    if rt then return RT_NAMES[tonumber(rt)] end
    if key:find("^boss:") then return "Boss portrait" end
    local cls = key:match("^cls:(%u+)$")
    if cls then return ns.CLASS_NAMES and ns.CLASS_NAMES[cls] or cls end
    local role = key:match("^role:(%l+)$")
    if role then return ROLE_NAME[role] or role end
    local sp = key:match("^sp:(%d+)$")
    if sp then return (GetSpellInfo and GetSpellInfo(tonumber(sp))) or ("Spell " .. sp) end
    local it = key:match("^it:(%d+)$")
    if it then return (ns.ItemDB and ns.ItemDB:GetName(tonumber(it))) or ("Item " .. it) end
    local file = key:match("^i:(.+)$")
    for _, e in ipairs(self.SPELL_ICONS) do
        if e[1] == file then return e[2] end
    end
    return file or key
end

-- The creature display ids of a boss' portraits (Data/BossPortraits.lua), { } when none.
function MapUI:BossPortraits(bossRef)
    local data = ns.Data and ns.Data.BossPortraits
    return (type(bossRef) == "string" and data and data[bossRef]) or {}
end

-- Adds an icon picker to a menu description: onPick(key). prompt(title, default, cb) asks for a spell / item id.
function MapUI:BuildIconMenu(root, current, onPick, prompt, bossRef)
    local function radio(parent, key, label)
        local icon = self:IconString(key, 14)
        parent:CreateRadio((icon ~= "" and (icon .. " ") or "") .. label, function() return current == key end,
            function() onPick(key) end)
    end
    -- the portraits of the encounter this strategy is for (only that boss' creatures)
    local portraits = self:BossPortraits(bossRef)
    if #portraits > 0 then
        local bossName = S():GetBossName(bossRef)
        local sub = root:CreateButton("This boss: " .. bossName)
        for i, id in ipairs(portraits) do
            radio(sub, "boss:" .. id, #portraits > 1 and (bossName .. " " .. i) or bossName)
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
    end
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

local function ArtLayer(mapID)
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
    tsort(mapCache, function(a, b) return a.id < b.id end)
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

-- /cdl maps [text]: what the client reports (map id, type, art) for maps whose name contains the text.
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
    ns:Print("%d map(s) matched; %d raid map(s) with art usable.", n, #self:GetMaps())
end

function MapUI:DefaultMap(bossRef)
    local list = self:MapsFor(bossRef)
    return list[1] and list[1].id or 0
end

function MapUI:MapName(mapID)
    if not mapID or mapID == 0 then return "Blank" end
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
    { key = "select", label = "Select", tip = "Click an element to select it, drag to move it. Drag the yellow handles to resize (zones, icons, arrow ends). Right-click an element for its options." },
    { key = "pan", label = "Pan map", tip = "Drag to move the map; the mouse wheel zooms. Set the map first, then draw: drawings stay where they are when the map moves." },
    { key = "circle", label = "Circle", tip = "Drag from the centre outwards to draw a circular zone." },
    { key = "rect", label = "Rectangle", tip = "Drag from one corner to the other to draw a zone." },
    { key = "arrow", label = "Arrow", tip = "Drag from start to end." },
    { key = "line", label = "Line", tip = "Drag from start to end." },
    { key = "icon", label = "Icon", tip = "Click where the icon goes, then pick it." },
    { key = "text", label = "Text", tip = "Click where the text goes, then type it." },
    { key = "slot", label = "Slot", tip = "Click where it goes, then pick a player slot: the assigned player's name shows there." },
}
MapUI.TOOLS = TOOLS

local function fontPath()
    local f = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
    return f or "Fonts\\FRIZQT__.TTF"
end

-- Creates a canvas of `width` pixels (height follows the board's 3:2). opts:
--   editable()         -> bool
--   onChange()         the page was changed (by the canvas)
--   onSelect(el)       selection changed (nil = none)
--   slotText(ref)      -> text shown on a slot token (a player's name, or the slot's label)
--   slotTip(ref, tt)   adds tooltip lines for a token
--   onHover(linkRef)   the mouse is over an element linked to a block ("blk", "blk.col", "blk.row.col"), or nil
--   slots()            -> { { ref, label } } for placing tokens
--   links()            -> { { ref, label } } for linking zones
--   prompt(title, default, cb)
--   bossRef()          -> the strategy's boss (map list)
function MapUI:CreateCanvas(parent, width, opts)
    local self = setmetatable({}, Canvas)
    self.opts = opts or {}
    self.tool = "select"
    self.color = 1
    self.pools = { zone = {}, arrow = {}, icon = {}, text = {}, slot = {} }
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
    -- selection box + handles
    self.sel = {}
    for i = 1, 4 do
        local t = self.layer:CreateTexture(nil, "OVERLAY", nil, 6)
        t:SetColorTexture(1, 0.85, 0.1, 0.95)
        t:Hide()
        self.sel[i] = t
    end
    self.handles = {}
    for i = 1, 2 do
        local h = self.layer:CreateTexture(nil, "OVERLAY", nil, 7)
        h:SetColorTexture(1, 0.85, 0.1, 1)
        h:SetSize(8, 8)
        h:Hide()
        self.handles[i] = h
    end
    self.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.hint:SetPoint("BOTTOMLEFT", 6, 4)
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
        self.selected = nil
        self.drag = nil
    end
    self.page = page
    self:Render()
end

function Canvas:SetTool(tool)
    self.tool = tool or "select"
    if self.tool ~= "select" then self:Select(nil) end
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

function Canvas:UpdateHint()
    if not self:Editable() then
        self.hint:SetText("")
        return
    end
    for _, t in ipairs(TOOLS) do
        if t.key == self.tool then self.hint:SetText(t.tip) end
    end
end

-- Cursor position in board units.
function Canvas:Cursor()
    local x, y = GetCursorPosition()
    local es = self.frame:GetEffectiveScale() or 1
    x, y = x / es, y / es
    local l, t = self.frame:GetLeft() or 0, self.frame:GetTop() or 0
    local bx, by = (x - l) / self.s, (t - y) / self.s
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
    local textures = L and C_Map.GetMapArtLayerTextures and C_Map.GetMapArtLayerTextures(page.m, 1)
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
                t:SetTexCoord(0, 1, 0, 1)
                t:SetSize(tw, th)
                t:SetPoint("TOPLEFT", self.art, "TOPLEFT", ox + (c - 1) * tw, -(oy + (r - 1) * th))
                t:Show()
            end
        end
    end
end

---------------------------------------------------------------------------
-- Elements
---------------------------------------------------------------------------

local function acquire(self, kind, create)
    self.used[kind] = (self.used[kind] or 0) + 1
    local pool = self.pools[kind]
    local o = pool[self.used[kind]]
    if not o then
        o = create()
        pool[self.used[kind]] = o
    end
    return o
end

local function newFS(layer, sub)
    local fs = layer:CreateFontString(nil, "OVERLAY", "GameFontHighlight", sub)
    return fs
end

function Canvas:FontSize(base)
    return max(8, floor(base * self.s / 0.7 + 0.5))
end

function Canvas:RenderZone(e)
    local L = self.layer
    local o = acquire(self, "zone", function()
        local z = {}
        z.fill = L:CreateTexture(nil, "BACKGROUND", nil, 1)
        z.ring = L:CreateTexture(nil, "BORDER", nil, 1)
        z.edges = {}
        for i = 1, 4 do z.edges[i] = L:CreateTexture(nil, "BORDER", nil, 1) end
        z.fs = newFS(L, 1)
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
        local E = o.edges
        local th = max(1, floor(2 * self.s / 0.7))
        for i, t in ipairs(E) do
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
    o.hide = function()
        o.fill:Hide()
        o.ring:Hide()
        for _, t in ipairs(o.edges) do t:Hide() end
        o.fs:Hide()
    end
end

function Canvas:RenderArrow(e)
    local L = self.layer
    local o = acquire(self, "arrow", function()
        local a = {}
        a.line = L:CreateLine(nil, "ARTWORK", nil, 1)
        a.head = L:CreateTexture(nil, "ARTWORK", nil, 2)
        a.head:SetTexture(TEX_ARROW)
        return a
    end)
    local r, g, b = MapUI:Color(e.c or 9)
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
    local o = acquire(self, "icon", function()
        local i = {}
        i.tex = L:CreateTexture(nil, "ARTWORK", nil, 3)
        i.fs = newFS(L, 2)
        return i
    end)
    local size = (e.z or 32) * self.s
    o.tex:ClearAllPoints()
    o.tex:SetSize(size, size)
    o.tex:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    MapUI:SetIcon(o.tex, e.i)
    o.tex:Show()
    if e.l then
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
    o.hide = function()
        o.tex:Hide()
        o.fs:Hide()
    end
end

local TEXT_SIZES = { 10, 13, 17 }

function Canvas:RenderText(e)
    local o = acquire(self, "text", function()
        return { fs = newFS(self.layer, 3) }
    end)
    local r, g, b = MapUI:Color(e.c or 9)
    o.fs:SetFont(fontPath(), self:FontSize(TEXT_SIZES[e.z or 2] or 13), "OUTLINE")
    o.fs:ClearAllPoints()
    o.fs:SetPoint("CENTER", self.layer, "TOPLEFT", e.x * self.s, -e.y * self.s)
    o.fs:SetWidth(0)
    o.fs:SetText(e.l or "")
    o.fs:SetTextColor(r, g, b)
    o.fs:Show()
    e._w = (o.fs:GetStringWidth() or 40) / self.s
    e._h = TEXT_SIZES[e.z or 2] * 1.4 / 0.7
    o.hide = function() o.fs:Hide() end
end

function Canvas:RenderSlot(e)
    local L = self.layer
    local o = acquire(self, "slot", function()
        local t = {}
        t.bg = L:CreateTexture(nil, "OVERLAY", nil, 1)
        t.edge = L:CreateTexture(nil, "OVERLAY", nil, 0)
        t.fs = newFS(L, 4)
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
local POOL_OF = { z = "zone", a = "arrow", i = "icon", x = "text", s = "slot" }

function Canvas:Render()
    self:RenderBackground()
    for kind, pool in pairs(self.pools) do
        for i = 1, #pool do
            if pool[i].hide then pool[i].hide() end
        end
    end
    self.used = {}
    local page = self.page
    if page then
        -- zones first (under everything), then the rest in page order
        for _, e in ipairs(page.e or {}) do
            if e.t == "z" then self:RenderZone(e) end
        end
        for _, e in ipairs(page.e or {}) do
            if e.t ~= "z" and RENDER[e.t] then self[RENDER[e.t]](self, e) end
        end
    end
    self:RenderSelection()
    self:UpdateHint()
end

---------------------------------------------------------------------------
-- Hit testing and selection
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

local function hits(e, x, y, tol)
    if e.t == "a" then return segDist(x, y, e.x, e.y, e.x2, e.y2) <= tol end
    if e.t == "z" and e.s == "c" then
        local rx, ry = e.w / 2, e.h / 2
        return ((x - e.x) / rx) ^ 2 + ((y - e.y) / ry) ^ 2 <= 1
    end
    local l, t, r, b = bounds(e)
    return x >= l - tol / 2 and x <= r + tol / 2 and y >= t - tol / 2 and y <= b + tol / 2
end

-- The topmost element at a board point (small elements before zones).
function Canvas:HitTest(x, y)
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

-- A handle of the selected element under the point: "end1" | "end2" | "size" | nil.
function Canvas:HandleAt(x, y)
    local e = self.selected
    if not e then return nil end
    local tol = 8 / self.s
    if e.t == "a" then
        if abs(x - e.x2) <= tol and abs(y - e.y2) <= tol then return "end2" end
        if abs(x - e.x) <= tol and abs(y - e.y) <= tol then return "end1" end
    elseif e.t == "z" then
        local rx, by = e.x + e.w / 2, e.y + e.h / 2
        if abs(x - rx) <= tol and abs(y - by) <= tol then return "size" end
    elseif e.t == "i" then
        local r = (e.z or 32) / 2
        if abs(x - (e.x + r)) <= tol and abs(y - (e.y + r)) <= tol then return "isize" end
    end
    return nil
end

function Canvas:Select(e)
    self.selected = e
    self:RenderSelection()
    if self.opts.onSelect then self.opts.onSelect(e) end
end

function Canvas:GetSelected() return self.selected end

function Canvas:RenderSelection()
    for _, t in ipairs(self.sel) do t:Hide() end
    for _, h in ipairs(self.handles) do h:Hide() end
    local e = self.selected
    if not e or not self:Editable() then return end
    local found = false
    for _, x in ipairs(self.page and self.page.e or {}) do
        if x == e then found = true end
    end
    if not found then
        self.selected = nil
        return
    end
    local l, t, r, b = bounds(e)
    local px, py = self:P(l, t)
    local w, h = (r - l) * self.s, (b - t) * self.s
    local S1 = self.sel
    for i = 1, 4 do S1[i]:ClearAllPoints() end
    S1[1]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py + 2); S1[1]:SetSize(w + 4, 1)
    S1[2]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py - h - 2); S1[2]:SetSize(w + 4, 1)
    S1[3]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px - 2, py + 2); S1[3]:SetSize(1, h + 4)
    S1[4]:SetPoint("TOPLEFT", self.layer, "TOPLEFT", px + w + 2, py + 2); S1[4]:SetSize(1, h + 4)
    for i = 1, 4 do S1[i]:Show() end
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
    end
end

-- Highlights the elements linked to a block reference (from the blocks panel), nil clears.
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

function Canvas:Highlight(ref)
    local lit
    if ref then
        for _, e in ipairs(self.page and self.page.e or {}) do
            local other = (e.t == "z" and e.ln) or (e.t == "s" and e.r) or nil
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
    local link
    if e then
        if e.t == "z" and e.ln then link = e.ln
        elseif e.t == "s" then link = e.r end
        if e.t == "s" and self.opts.slotTip then
            GameTooltip:SetOwner(self.frame, "ANCHOR_CURSOR")
            self.opts.slotTip(e.r, GameTooltip)
            GameTooltip:Show()
        elseif e.t == "i" and not self:Editable() then
            GameTooltip:SetOwner(self.frame, "ANCHOR_CURSOR")
            GameTooltip:AddLine(e.l or MapUI:IconName(e.i))
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

local function room(self)
    if #self.page.e >= S().MAX_ELEMENTS then
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

function Canvas:Remove(e)
    for i, x in ipairs(self.page.e) do
        if x == e then
            tremove(self.page.e, i)
            break
        end
    end
    if self.selected == e then self:Select(nil) end
    self:Changed()
end

function Canvas:Duplicate(e)
    if not room(self) then return end
    local c = {}
    for k, v in pairs(e) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" then c[k] = v end
    end
    c.x, c.y = min(BW, c.x + 20), min(BH, c.y + 20)
    if c.x2 then c.x2, c.y2 = min(BW, c.x2 + 20), min(BH, c.y2 + 20) end
    tinsert(self.page.e, c)
    self:Changed()
    self:Select(c)
end

function Canvas:Reorder(e, toFront)
    for i, x in ipairs(self.page.e) do
        if x == e then
            tremove(self.page.e, i)
            break
        end
    end
    if toFront then tinsert(self.page.e, e) else tinsert(self.page.e, 1, e) end
    self:Changed()
end

function Canvas:OnMouseDown(button)
    if not self.page then return end
    local x, y = self:Cursor()
    if not self:Editable() then return end
    if button == "RightButton" then
        local e = self:HitTest(x, y)
        if e then
            self:Select(e)
            self:ElementMenu(e)
        else
            self:BackgroundMenu()
        end
        return
    end
    if button ~= "LeftButton" then return end
    local tool = self.tool
    if tool == "select" then
        local h = self:HandleAt(x, y)
        if h then
            self.drag = { mode = h, el = self.selected }
            return
        end
        local e = self:HitTest(x, y)
        self:Select(e)
        if e then self.drag = { mode = "move", el = e, sx = x, sy = y, ox = e.x, oy = e.y, ox2 = e.x2, oy2 = e.y2 } end
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
        if not room(self) then return end
        ns.UI:ContextMenu(self.frame, function(root)
            root:CreateTitle("Icon")
            MapUI:BuildIconMenu(root, nil, function(key)
                local e = self:Add({ t = "i", x = x, y = y, i = key, z = key:find("^boss:") and 48 or 32 })
                self:SetTool("select")
                self:Changed()
                self:Select(e)
            end, self.opts.prompt, self.opts.bossRef and self.opts.bossRef())
        end)
    elseif tool == "text" then
        if not room(self) then return end
        self.opts.prompt("Text", "", function(text)
            text = ns.Util.Trim(text or ""):gsub("|", "")
            if text == "" then return end
            local e = self:Add({ t = "x", x = x, y = y, l = text:sub(1, S().MAX_LABEL), c = self.color == 1 and 9 or self.color, z = 2 })
            self:SetTool("select")
            self:Changed()
            self:Select(e)
        end)
    elseif tool == "slot" then
        if not room(self) then return end
        self:SlotMenu(nil, function(ref)
            local e = self:Add({ t = "s", x = x, y = y, r = ref })
            self:SetTool("select")
            self:Changed()
            self:Select(e)
        end)
    end
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
    if d.mode == "move" then
        local dx, dy = x - d.sx, y - d.sy
        e.x, e.y = d.ox + dx, d.oy + dy
        if e.t == "a" then e.x2, e.y2 = d.ox2 + dx, d.oy2 + dy end
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
    elseif d.mode == "isize" then
        -- icons stay square around their centre
        e.z = max(12, min(96, floor(2 * max(abs(x - e.x), abs(y - e.y)) + 0.5)))
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
    local d = self.drag
    if not d then return end
    self.drag = nil
    local e = d.el
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
    if e then
        e.x, e.y = floor(max(0, min(BW, e.x))), floor(max(0, min(BH, e.y)))
        if e.x2 then e.x2, e.y2 = floor(max(0, min(BW, e.x2))), floor(max(0, min(BH, e.y2))) end
    end
    self:Changed()
end

function Canvas:OnWheel(delta)
    if not self:Editable() or not self.page or not ArtLayer(self.page.m) then return end
    local z = self.page.vz or 100
    z = max(100, min(1000, floor(z * (delta > 0 and 1.15 or 1 / 1.15) + 0.5)))
    self.page.vz = z
    self.page.vx, self.page.vy = self.page.vx or 500, self.page.vy or 500
    self:Changed()
end

function Canvas:SlotMenu(current, onPick)
    local slots = self.opts.slots and self.opts.slots() or {}
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle("Show the player of")
        if #slots == 0 then root:CreateTitle("|cff808080No player slots yet: add a block first.|r") end
        local byBlock, order = {}, {}
        for _, s in ipairs(slots) do
            if not byBlock[s.blockName] then
                byBlock[s.blockName] = {}
                order[#order + 1] = s.blockName
            end
            tinsert(byBlock[s.blockName], s)
        end
        for _, name in ipairs(order) do
            local sub = root:CreateButton(name)
            for _, s in ipairs(byBlock[name]) do
                sub:CreateRadio(s.label, function() return current == s.ref end, function() onPick(s.ref) end)
            end
        end
    end)
end

function Canvas:ElementMenu(e)
    local names = { z = "Zone", a = e.h and "Arrow" or "Line", i = "Icon", x = "Text", s = "Slot" }
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle(names[e.t] or "Element")
        if e.t == "z" or e.t == "i" or e.t == "x" then
            root:CreateButton(e.t == "x" and "Edit text..." or "Label...", function()
                self.opts.prompt(e.t == "x" and "Text" or "Label", e.l or "", function(text)
                    text = ns.Util.Trim(text or ""):gsub("|", ""):sub(1, S().MAX_LABEL)
                    if text == "" then
                        if e.t == "x" then return end
                        e.l = nil
                    else
                        e.l = text
                    end
                    self:Changed()
                end)
            end)
        end
        if e.t ~= "s" then
            local col = root:CreateButton("Colour")
            for i, c in ipairs(COLORS) do
                col:CreateRadio(MapUI:Swatch(i) .. " " .. c[4], function() return (e.c or (e.t == "z" and 1 or 9)) == i end,
                    function() e.c = i; self.color = i; self:Changed() end)
            end
        end
        if e.t == "z" then
            local shape = root:CreateButton("Shape")
            shape:CreateRadio("Circle", function() return e.s == "c" end, function() e.s = "c"; self:Changed() end)
            shape:CreateRadio("Rectangle", function() return e.s == "r" end, function() e.s = "r"; self:Changed() end)
            local link = root:CreateButton("Link to assignments")
            link:CreateRadio("Not linked", function() return e.ln == nil end, function() e.ln = nil; self:Changed() end)
            for _, l in ipairs(self.opts.links and self.opts.links() or {}) do
                link:CreateRadio(l.label, function() return e.ln == l.ref end, function() e.ln = l.ref; self:Changed() end)
            end
        elseif e.t == "a" then
            root:CreateCheckbox("Arrowhead", function() return e.h == true end, function()
                e.h = not e.h or nil
                self:Changed()
            end)
        elseif e.t == "i" then
            local ic = root:CreateButton("Icon")
            MapUI:BuildIconMenu(ic, e.i, function(key) e.i = key; self:Changed() end, self.opts.prompt,
                self.opts.bossRef and self.opts.bossRef())
            local size = root:CreateButton("Size")
            for _, z in ipairs({ { 20, "Small" }, { 32, "Medium" }, { 48, "Large" }, { 72, "Huge" }, { 96, "Largest" } }) do
                size:CreateRadio(z[2], function() return (e.z or 32) == z[1] end, function() e.z = z[1]; self:Changed() end)
            end
        elseif e.t == "x" then
            local size = root:CreateButton("Size")
            for i, label in ipairs({ "Small", "Normal", "Large" }) do
                size:CreateRadio(label, function() return (e.z or 2) == i end, function() e.z = i; self:Changed() end)
            end
        elseif e.t == "s" then
            root:CreateButton("Change slot...", function()
                self:SlotMenu(e.r, function(ref) e.r = ref; self:Changed() end)
            end)
        end
        root:CreateDivider()
        root:CreateButton("Duplicate", function() self:Duplicate(e) end)
        root:CreateButton("Bring to front", function() self:Reorder(e, true) end)
        root:CreateButton("Send to back", function() self:Reorder(e, false) end)
        root:CreateButton("|cffff6060Delete|r", function() self:Remove(e) end)
    end)
end

function Canvas:BackgroundMenu()
    local page = self.page
    ns.UI:ContextMenu(self.frame, function(root)
        root:CreateTitle("Map")
        local bossRef = self.opts.bossRef and self.opts.bossRef()
        MapUI:BuildMapMenu(root, bossRef, page.m, function(id)
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
        "list the raid maps the strategy boards can use (/cdl maps <name> searches every map)")
end

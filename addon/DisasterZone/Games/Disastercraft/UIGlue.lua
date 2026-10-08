if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Disastercraft/UIGlue.lua", ...) then return end -- DisasterZone Games/Disastercraft/UIGlue.lua
-- CraftUI's character screens, like WoW's glue screens: the character list (your Disastercraft characters - one per
-- class, each carrying your name), Enter World, Create New Character and Delete; and character creation (the class,
-- male or female, what the class is about, your character in its starting outfit). What's new sits on the left.
local addonName, ns = ...

local UI = ns.CraftUI
local K = UI.Kit
local Craft = ns.Craft
local D = Craft.D

local floor, max, min = math.floor, math.max, math.min
local Glue = {}
UI.Glue = Glue

local CLASS_TEXT = {
    [1] = { "Warriors charge into the fray and hold the line. They fight with weapons and shields, build Rage by "
            .. "dealing and taking blows, and spend it on mighty strikes.", "Tank, Melee Damage", "Rage" },
    [8] = { "Mages wield fire, frost and arcane magic from a distance. Fragile up close, they freeze, burn and "
            .. "blast their enemies, and conjure food and water for their friends.", "Ranged Damage", "Mana" },
    [5] = { "Priests call on the Light to heal their allies and shield them from harm, and on the shadows to "
            .. "smite their foes.", "Healer, Ranged Damage", "Mana" },
}
local CLASS_ICON = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

local function GlueBox(parent, w, h)
    local f = K.Frame(parent, w, h, { bgFile = "Interface\\Glues\\Common\\Glue-Tooltip-Background",
        edgeFile = "Interface\\Glues\\Common\\Glue-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 10, right = 5, top = 4, bottom = 9 } })
    if f.SetBackdropColor then f:SetBackdropColor(0.1, 0.1, 0.1, 0.85) end
    return f
end

local function Model(parent, w, h)
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, parent)
    if not ok or not m then return nil end
    m:SetSize(w, h)
    return m
end

-- the 3D model in an outfit: what the character wears (equip), or the class's start gear for a new one
local function Dress(m, cls, sex, equip)
    if not m then return end
    local items = {}
    if equip then
        for s = 1, 19 do if equip[s] then items[#items + 1] = equip[s] end end
    else
        local cd = D.classes[cls]
        for _, id in ipairs(cd and cd.gear or {}) do
            local it = D.items[id]
            if it and it.inv then items[#items + 1] = id end
        end
    end
    K.DressModel(m, sex or 0, items)
end

-- the centre column (between What's new and the character list): the model, the name, Enter World
local MID_X = 40

function UI.BuildGlue(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints()
    g:SetFrameLevel(parent:GetFrameLevel() + 40)
    g:EnableMouse(true)
    g.bg = K.Tex(g, "BACKGROUND")
    g.bg:SetAllPoints()
    g.bg:SetColorTexture(0.02, 0.03, 0.05, 1)
    -- Elwynn's map, dimmed, behind it all
    g.map = K.Tex(g, "BACKGROUND", "Interface\\WorldMap\\Elwynn\\Elwynn6", 1)
    g.map:SetAllPoints()
    g.map:SetVertexColor(0.25, 0.25, 0.28)
    g.logo = K.Tex(g, "ARTWORK", "Interface\\Glues\\Common\\Glues-WoW-ClassicLogo")
    g.logo:SetSize(256, 128)
    g.logo:SetPoint("TOPLEFT", 8, 4)
    g.name = K.Font(g, 30, "THICKOUTLINE")
    g.name:SetPoint("TOPLEFT", 24, -108)
    g.name:SetTextColor(1, 0.82, 0)
    g.name:SetText("Disastercraft")
    g.tag = K.Font(g, 12, "OUTLINE")
    g.tag:SetPoint("TOPLEFT", g.name, "BOTTOMLEFT", 2, -4)
    g.tag:SetText("Northshire Abbey - " .. (Craft.CLASS_NAMES and "a little World of Warcraft" or ""))
    -- the 3D model stands in the middle, high and large like the client's; the name and Enter World under it
    g.model = Model(g, 300, 380)
    if g.model then g.model:SetPoint("CENTER", MID_X, 60) end
    -- the hero as it walks the world (the pixel sprite in its gear), a small badge by the name
    g.badge = CreateFrame("Frame", nil, g)
    g.badge:SetSize(48, 48)
    g.badge.layers = {}
    g.sprite = K.Tex(g.badge, "ARTWORK", K.MEDIA .. "mobs.blp")
    g.sprite:SetAllPoints()
    UI.glue = g
    Glue.BuildSelect(g)
    Glue.BuildCreate(g)
    Glue.BuildNews(g)
    return g
end

-- the badge: the pixel hero standing, facing you - the bare body and its gear layers (Outfit.lua) when there is
-- outfit data, else the class's start-outfit sprite
local function SetSpriteFor(t, cls, sex, char)
    local badge = t:GetParent()
    for _, l in ipairs(badge.layers) do l:Hide() end
    local layers = UI.OutfitLayers and UI.OutfitLayers(char or { sex = sex, equip = {} }, "walk", 1, 0)
    if layers and layers[1] then
        t:Hide()
        local k = badge:GetWidth() / 32
        for i, L in ipairs(layers) do
            local x = badge.layers[i]
            if not x then x = badge:CreateTexture(nil, "ARTWORK", nil, min(7, i)) badge.layers[i] = x end
            x:SetTexture(L[1])
            x:SetTexCoord(L[2], L[3], L[4], L[5])
            x:ClearAllPoints()
            x:SetPoint("TOPLEFT", badge, "TOPLEFT", L[6] * k, -L[7] * k)
            x:SetSize(L[8] * k, L[9] * k)
            x:Show()
        end
        return
    end
    t:Show()
    local spr = ns.AzeroData and ns.AzeroData.CLASS_SPR
    local s = spr and spr[(Craft.CLASS_TOKENS[cls] or "WARRIOR") .. (sex or 0)] or 35
    local H = (ns.AzeroData and ns.AzeroData.MOB_SHEET_H) or 2048
    local c = (s % 5) * 3 + 1
    local r = floor(s / 5) * 4
    t:SetTexCoord(c * 32 / 512, (c + 1) * 32 / 512, r * 32 / H, (r + 1) * 32 / H)
end

---------------------------------------------------------------------------
-- Character select
---------------------------------------------------------------------------

function Glue.BuildSelect(g)
    local s = CreateFrame("Frame", nil, g)
    s:SetAllPoints()
    g.select = s
    local list = GlueBox(s, 260, 330)
    list:SetPoint("TOPRIGHT", -20, -24)
    s.list = list
    local t = K.Text(list, "GameFontNormalLarge", "OVERLAY", "CENTER")
    t:SetPoint("TOP", 0, -14)
    t:SetText("Characters")
    s.rows = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, list)
        b:SetSize(232, 66)
        b:SetPoint("TOPLEFT", 14, -42 - (i - 1) * 70)
        b.hl = K.Tex(b, "BACKGROUND", "Interface\\Glues\\CharacterSelect\\Glue-CharacterSelect-Highlight")
        b.hl:SetAllPoints()
        b.hl:SetBlendMode("ADD")
        b.hl:Hide()
        b.icon = K.Tex(b, "ARTWORK", CLASS_ICON)
        b.icon:SetSize(32, 32)
        b.icon:SetPoint("LEFT", 6, 0)
        b.name = K.Text(b, "GameFontNormalLarge", "OVERLAY", "LEFT")
        b.name:SetPoint("TOPLEFT", 46, -10)
        b.info = K.Text(b, "GameFontHighlightSmall", "OVERLAY", "LEFT")
        b.info:SetPoint("TOPLEFT", b.name, "BOTTOMLEFT", 0, -1)
        b.where = K.Text(b, "GameFontDisableSmall", "OVERLAY", "LEFT")
        b.where:SetPoint("TOPLEFT", b.info, "BOTTOMLEFT", 0, -1)
        b:SetScript("OnClick", function(self) Glue.selected = self.cls Glue.Refresh() end)
        b:SetScript("OnDoubleClick", function(self) Glue.selected = self.cls Glue.EnterWorld() end)
        s.rows[i] = b
    end
    s.create = K.Button(list, "Create New Character", 200, 24, function() Glue.ShowCreate() end)
    s.create:SetPoint("BOTTOM", 0, 48)
    s.delete = K.Button(list, "Delete Character", 200, 24, function()
        local cls = Glue.selected
        if not cls then return end
        UI.Popup("delete", "Delete your level " .. (Craft:Data().chars[cls].level or 1) .. " " .. Craft.CLASS_NAMES[cls] .. "?",
            { "Delete", function() Craft:DeleteCharacter(cls) Glue.selected = nil Glue.Refresh() end },
            { "Cancel", function() end })
    end)
    s.delete:SetPoint("BOTTOM", 0, 18)
    s.enter = K.Button(s, "Enter World", 180, 34, function() Glue.EnterWorld() end)
    s.enter:SetPoint("BOTTOM", MID_X, 30)
    s.whoInfo = K.Font(s, 13, "OUTLINE")
    s.whoInfo:SetPoint("BOTTOM", s.enter, "TOP", 0, 14)
    s.who = K.Font(s, 22, "THICKOUTLINE")
    s.who:SetPoint("BOTTOM", s.whoInfo, "TOP", 0, 4)
    s.who:SetTextColor(1, 0.82, 0)
end

function Glue.Refresh()
    local g = UI.glue
    local s = g.select
    local chars = Craft:Characters()
    if not Glue.selected and #chars > 0 then
        Glue.selected = Craft:Data().last
        local ok = false
        for _, c in ipairs(chars) do if c.class == Glue.selected then ok = true end end
        if not ok then Glue.selected = chars[1].class end
    end
    local sel
    for i, b in ipairs(s.rows) do
        local c = chars[i]
        if c then
            b.cls = c.class
            b.name:SetText(c.name)
            b.info:SetText(string.format("Level %d %s", c.level, Craft.CLASS_NAMES[c.class]))
            b.where:SetText(Craft.World and Craft.World.built and Craft.World.MapName(c.map or "world", c.x or 0, c.y or 0)
                            or "Northshire Valley")
            local co = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[Craft.CLASS_TOKENS[c.class]]
            if co then b.icon:SetTexCoord(co[1], co[2], co[3], co[4]) end
            b.hl:SetShown(c.class == Glue.selected)
            if c.class == Glue.selected then sel = c end
            b:Show()
        else
            b:Hide()
        end
    end
    s.create:SetEnabled(#chars < #Craft.PLAYABLE)
    s.delete:SetEnabled(sel ~= nil)
    s.enter:SetEnabled(sel ~= nil)
    if sel then
        s.who:SetText(sel.name)
        s.whoInfo:SetText(string.format("Level %d Human %s", sel.level, Craft.CLASS_NAMES[sel.class]))
        Dress(g.model, sel.class, sel.sex, sel.equip)
        SetSpriteFor(g.sprite, sel.class, sel.sex, sel)
        -- (left of the wider of the two lines, standing on the lower one)
        local w = max(s.who:GetStringWidth() or 0, s.whoInfo:GetStringWidth() or 0)
        g.badge:ClearAllPoints()
        g.badge:SetPoint("BOTTOMRIGHT", s.whoInfo, "BOTTOM", -w / 2 - 8, -4)
        g.badge:Show()
    else
        s.who:SetText(#chars == 0 and "Create your first character" or "")
        s.whoInfo:SetText("")
        g.badge:Hide()
        if g.model then g.model:Hide() end
    end
    if g.model and sel then g.model:Show() end
end

function Glue.EnterWorld()
    local cls = Glue.selected
    if not cls then return end
    K.Play(K.SFX.start)
    UI.EnterWorld(cls)
end

---------------------------------------------------------------------------
-- Character creation
---------------------------------------------------------------------------

function Glue.BuildCreate(g)
    local c = CreateFrame("Frame", nil, g)
    c:SetAllPoints()
    c:Hide()
    g.create = c
    local box = GlueBox(c, 280, 380)
    box:SetPoint("TOPRIGHT", -20, -24)
    local t = K.Text(box, "GameFontNormalLarge", "OVERLAY", "CENTER")
    t:SetPoint("TOP", 0, -14)
    t:SetText("Create Character")
    local race = K.Text(box, "GameFontHighlight", "OVERLAY", "CENTER")
    race:SetPoint("TOP", 0, -36)
    race:SetText("Human - Northshire Abbey")
    c.classBtns = {}
    for i, cls in ipairs(Craft.PLAYABLE) do
        local b = CreateFrame("Button", nil, box)
        b:SetSize(56, 56)
        b:SetPoint("TOPLEFT", 26 + (i - 1) * 78, -62)
        b.icon = K.Tex(b, "ARTWORK", CLASS_ICON)
        b.icon:SetAllPoints()
        local co = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[Craft.CLASS_TOKENS[cls]]
        if co then b.icon:SetTexCoord(co[1], co[2], co[3], co[4]) end
        b.ring = K.Tex(b, "OVERLAY", "Interface\\Buttons\\CheckButtonHilight")
        b.ring:SetPoint("TOPLEFT", -6, 6)
        b.ring:SetPoint("BOTTOMRIGHT", 6, -6)
        b.ring:SetBlendMode("ADD")
        b.label = K.Text(b, "GameFontNormalSmall", "OVERLAY", "CENTER")
        b.label:SetPoint("TOP", b, "BOTTOM", 0, -3)
        b.label:SetText(Craft.CLASS_NAMES[cls])
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b.cls = cls
        b:SetScript("OnClick", function(self) Glue.newClass = self.cls Glue.RefreshCreate() end)
        c.classBtns[i] = b
    end
    c.sexBtns = {}
    for i, sex in ipairs({ 0, 1 }) do
        local b = K.Button(box, sex == 0 and "Male" or "Female", 100, 22, function() Glue.newSex = sex Glue.RefreshCreate() end)
        b:SetPoint("TOPLEFT", 34 + (i - 1) * 110, -150)
        c.sexBtns[i] = b
    end
    c.desc = K.Text(box, "GameFontHighlightSmall", "OVERLAY", "LEFT")
    c.desc:SetPoint("TOPLEFT", 22, -186)
    c.desc:SetWidth(240)
    if c.desc.SetSpacing then c.desc:SetSpacing(2) end
    c.roles = K.Text(box, "GameFontNormalSmall", "OVERLAY", "LEFT")
    c.roles:SetPoint("TOPLEFT", c.desc, "BOTTOMLEFT", 0, -10)
    c.roles:SetWidth(240)
    c.taken = K.Text(box, "GameFontRedSmall", "OVERLAY", "LEFT")
    c.taken:SetPoint("BOTTOMLEFT", 22, 18)
    c.taken:SetWidth(240)
    c.accept = K.Button(c, "Accept", 140, 30, function()
        local cls, sex = Glue.newClass, Glue.newSex or 0
        if Craft:Data().chars and Craft:Data().chars[cls] then return end
        Craft:NewCharacter(cls, sex)
        Glue.selected = cls
        Glue.ShowSelect()
    end)
    c.accept:SetPoint("BOTTOMRIGHT", -40, 30)
    c.back = K.Button(c, "Back", 140, 30, function() Glue.ShowSelect() end)
    c.back:SetPoint("BOTTOMLEFT", 40, 30)
end

function Glue.RefreshCreate()
    local g = UI.glue
    local c = g.create
    Glue.newClass = Glue.newClass or Craft.PLAYABLE[1]
    Glue.newSex = Glue.newSex or 0
    for _, b in ipairs(c.classBtns) do b.ring:SetShown(b.cls == Glue.newClass) end
    for i, b in ipairs(c.sexBtns) do if (i - 1) == Glue.newSex then b:LockHighlight() else b:UnlockHighlight() end end
    local info = CLASS_TEXT[Glue.newClass]
    c.desc:SetText(info[1])
    c.roles:SetText("Roles: |cffffffff" .. info[2] .. "|r\nUses: |cffffffff" .. info[3] .. "|r")
    local taken = Craft:Data().chars and Craft:Data().chars[Glue.newClass]
    c.taken:SetText(taken and ("You already have a " .. Craft.CLASS_NAMES[Glue.newClass] .. ".") or "")
    c.accept:SetEnabled(not taken)
    Dress(g.model, Glue.newClass, Glue.newSex)
    if g.model then g.model:Show() end
    -- (a new character wears its class's start outfit)
    local start = {}
    for _, id in ipairs(D.classes[Glue.newClass] and D.classes[Glue.newClass].gear or {}) do
        local it = D.items[id]
        local slot = it and it.inv and Craft.Items.SlotFor and Craft.Items.SlotFor(it, { equip = start })
        if slot then start[slot] = id end
    end
    SetSpriteFor(g.sprite, Glue.newClass, Glue.newSex, { sex = Glue.newSex, equip = start })
    g.badge:ClearAllPoints()
    g.badge:SetPoint("BOTTOM", g, "BOTTOM", MID_X, 72)
    g.badge:Show()
end

function Glue.ShowCreate()
    local g = UI.glue
    g.select:Hide()
    g.create:Show()
    if g.news then g.news:Hide() end           -- (WoW's create screen has no news)
    Glue.newClass = nil
    for _, cls in ipairs(Craft.PLAYABLE) do
        if not (Craft:Data().chars and Craft:Data().chars[cls]) then Glue.newClass = cls break end
    end
    Glue.RefreshCreate()
end

function Glue.ShowSelect()
    local g = UI.glue
    g.create:Hide()
    g.select:Show()
    if g.news then g.news:Show() end
    Glue.Refresh()
end

---------------------------------------------------------------------------
-- What's new (Changelog.lua), on the left
---------------------------------------------------------------------------

function Glue.BuildNews(g)
    local box = GlueBox(g, 270, 250)
    box:SetPoint("BOTTOMLEFT", 20, 24)
    local t = K.Text(box, "GameFontNormal", "OVERLAY", "LEFT")
    t:SetPoint("TOPLEFT", 16, -12)
    t:SetText("What's new")
    -- the releases, newest first, in a box that scrolls with the wheel (clipped to it)
    local sf = CreateFrame("ScrollFrame", nil, box)
    sf:SetPoint("TOPLEFT", 14, -32)
    sf:SetPoint("BOTTOMRIGHT", -10, 12)
    if sf.SetClipsChildren then sf:SetClipsChildren(true) end
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(240, 10)
    sf:SetScrollChild(child)
    box.text = K.Text(child, "GameFontHighlightSmall", "OVERLAY", "LEFT")
    box.text:SetPoint("TOPLEFT", 2, 0)
    box.text:SetWidth(236)
    if box.text.SetSpacing then box.text:SetSpacing(2) end
    g.news = box
    local log = ns.CraftChangelog or {}
    local lines = {}
    for i, rel in ipairs(log) do
        if i > 3 then break end
        if i > 1 then lines[#lines + 1] = " " end
        lines[#lines + 1] = "|cffffd100" .. rel.version .. "|r  |cff808080" .. (rel.date or "") .. "|r"
        for _, l in ipairs(rel.changes or {}) do lines[#lines + 1] = "- " .. l end
    end
    box.text:SetText(table.concat(lines, "\n"))
    child:SetHeight(max(10, (box.text:GetStringHeight() or 100) + 6))
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, d)
        local range = max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(max(0, min(range, self:GetVerticalScroll() - d * 24)))
    end)
    local data = Craft:Data()
    if log[1] then data.newsSeen = log[1].version end
end

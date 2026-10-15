if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ProfilesUI.lua", ...) then return end -- DisasterZone UI/ProfilesUI.lua
-- Settings > Interface > Profiles (the card that was Layout): the approved mockup's direction A "Profile cards"
-- (claude.ai/artifact/WpLrGBdDo6LW2GA3RqwCz3, 2026-10-15). A row of profile cards (a raid's art, the name, which parts
-- it holds as three small chips, the specs that use it, "In use"), a dashed New card; under them the open profile:
-- its art strip with the name, In use or Use now, copy / share / rename / delete; a row per part (Looks with a sample
-- of its look, Layout with Edit layout, Key binds with Key binds), each with its switch; Use when I play (my class's
-- specs: a spec another profile has says which); Characters (my account's characters: give the profile to my main or
-- an alt; mine switches now, the others at their next login); a line saying changes save by themselves.
-- The data: Core/Profiles.lua (ns.Profiles); demo mode shows its made-up profiles.
local addonName, ns = ...

local PUI = ns:NewModule("ProfilesUI")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local ipairs, pairs, tostring = ipairs, pairs, tostring

local CARD_W, CARD_H, CARD_ART, GAP = 104, 96, 58, 8
local ROW_H = 46
local GOLD = S.C.GOLD
local GOLD_DEEP = S.C.GOLD_DEEP
local ART = { "SerpentshrineCavern", "BlackTemple", "TempestKeep", "Karazhan", "HyjalSummit", "ZulAman",
              "SunwellPlateau", "GruulsLair", "MagtheridonsLair" }
local PART_INFO = {
    looks = { icon = 31, title = "Looks" },
    layout = { icon = 35, title = "Layout" },
    keys = { icon = UI.ICON.keys, title = "Key binds" },
}

local function P() return ns.Profiles end

-- A profile's art: a raid's loading screen, the same one for the same profile.
local function ArtOf(p)
    if p.art then return p.art end
    if p.id == "default" then return "Karazhan" end
    local h = 0
    for i = 1, #tostring(p.id) do h = (h * 31 + tostring(p.id):byte(i)) % 9973 end
    return ART[h % #ART + 1]
end

local function SetArt(tex, p, w, h, fw)
    local file, l, r, t, b
    if ns.ItemDB then file, l, r, t, b = ns.ItemDB:RaidArt(ArtOf(p), w, h, fw or 0.5, true) end
    if file and l then
        tex:SetTexture(file)
        tex:SetTexCoord(l, r, t, b)
    else
        tex:SetColorTexture(S:Color("INSET"))
    end
end

local function Glyph(parent, size, icon, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetSize(size, size)
    UI:SetGlyph(t, icon)
    return t
end

---------------------------------------------------------------------------
-- A card
---------------------------------------------------------------------------

local function Chip(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(16, 16)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    UI:AddEdges(c, "BORDER")
    c.g = Glyph(c, 10, 1)
    c.g:SetPoint("CENTER")
    function c:Paint(icon, on)
        UI:SetGlyph(self.g, icon)
        if on then
            self.bg:SetColorTexture(0.08, 0.06, 0.02, 0.8)
            UI:SetEdgeColor(self, GOLD_DEEP[1], GOLD_DEEP[2], GOLD_DEEP[3], 0.55)
            self.g:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
        else
            self.bg:SetColorTexture(0, 0, 0, 0.45)
            UI:SetEdgeColor(self, S:Alpha("EDGE", 0.6))
            self.g:SetVertexColor(S:Alpha("DIM", 0.8))
        end
    end
    return c
end

local function NewProfileCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(CARD_W, CARD_H)
    c.bg = UI:Fill(c, "INSET")
    c.art = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.art:SetPoint("TOPLEFT", 1, -1)
    c.art:SetPoint("TOPRIGHT", -1, -1)
    c.art:SetHeight(CARD_ART)
    c.fade = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.fade:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT")
    c.fade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
    c.fade:SetHeight(34)
    UI:Gradient(c.fade, "VERTICAL", S:WithAlpha("INSET", 1), S:WithAlpha("INSET", 0))
    c.hover = c:CreateTexture(nil, "ARTWORK")
    c.hover:SetAllPoints()
    c.hover:SetColorTexture(S:Color("HOVER"))
    c.hover:Hide()
    UI:AddEdges(c, "OVERLAY")
    c.glow = CreateFrame("Frame", nil, c)
    c.glow:SetPoint("TOPLEFT", -2, 2)
    c.glow:SetPoint("BOTTOMRIGHT", 2, -2)
    UI:AddEdges(c.glow, "OVERLAY")
    c.name = UI:Text(c, "small", "TEXT", { shadow = true })
    c.name:SetPoint("BOTTOMLEFT", c, "TOPLEFT", 7, -(CARD_ART + 14))
    c.name:SetPoint("RIGHT", c, "RIGHT", -6, 0)
    UI:SetTextSize(c.name, 11.5)
    c.chips = {}
    for i, part in ipairs(P().PARTS) do
        local ch = Chip(c)
        ch:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 6 + (i - 1) * 19, 6)
        ch.part = part
        c.chips[i] = ch
    end
    c.use = UI:CreatePill(c, "ok", "In use", 14)
    c.use:SetPoint("TOPLEFT", 5, -5)
    c.specs = {}
    for i = 1, 4 do
        local t = c:CreateTexture(nil, "OVERLAY")
        t:SetSize(16, 16)
        t:SetPoint("TOPRIGHT", c, "TOPRIGHT", -5 - (i - 1) * 18, -5)
        t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        c.specs[i] = t
    end
    c:SetScript("OnEnter", function(self) self.hover:Show() end)
    c:SetScript("OnLeave", function(self) self.hover:Hide() end)
    return c
end

local function PaintCard(c, p, selected, inUse)
    c.p = p
    SetArt(c.art, p, (c.w or CARD_W) - 2, CARD_ART, 0.42)
    c.name:SetText(p.name or "Profile")
    local parts = P().Parts(p)
    for _, ch in ipairs(c.chips) do ch:Paint(PART_INFO[ch.part].icon, parts[ch.part]) end
    c.use:SetShown(inUse)
    local specs = P():SpecsOf(p.id)
    for i, t in ipairs(c.specs) do
        local s = specs[#specs - i + 1]
        if s and s.icon then t:SetTexture(s.icon); t:Show() else t:Hide() end
    end
    UI:SetEdgeColor(c, selected and GOLD_DEEP[1] or 0.34, selected and GOLD_DEEP[2] or 0.34,
        selected and GOLD_DEEP[3] or 0.38, selected and 1 or 0.7)
    UI:SetEdgeColor(c.glow, GOLD_DEEP[1], GOLD_DEEP[2], GOLD_DEEP[3], selected and 0.35 or 0)
    c.name:SetTextColor(S:RGB(selected and "GOLD" or "TEXT"))
end

local function NewPlusCard(parent, onClick)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(CARD_W, CARD_H)
    c.hover = c:CreateTexture(nil, "BACKGROUND")
    c.hover:SetAllPoints()
    c.hover:SetColorTexture(S:Color("HOVER"))
    c.hover:Hide()
    -- (a dashed edge: Edit layout's dash tiles)
    local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\Edit\\"
    local function dash(p1, p2, horiz)
        local t = c:CreateTexture(nil, "BORDER")
        t:SetPoint(p1); t:SetPoint(p2)
        if horiz then
            t:SetHeight(1); t:SetTexture(MEDIA .. "dash_h", "REPEAT", "CLAMP"); t:SetHorizTile(true)
        else
            t:SetWidth(1); t:SetTexture(MEDIA .. "dash_v", "CLAMP", "REPEAT"); t:SetVertTile(true)
        end
        t:SetVertexColor(0.6, 0.58, 0.54, 0.7)
    end
    dash("TOPLEFT", "TOPRIGHT", true); dash("BOTTOMLEFT", "BOTTOMRIGHT", true)
    dash("TOPLEFT", "BOTTOMLEFT"); dash("TOPRIGHT", "BOTTOMRIGHT")
    c.g = Glyph(c, 16, UI.ICON.plus)
    c.g:SetPoint("CENTER", 0, 8)
    c.g:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    c.fs = UI:Text(c, "small", "SUB", { text = "New" })
    c.fs:SetPoint("TOP", c.g, "BOTTOM", 0, -6)
    c:SetScript("OnEnter", function(self) self.hover:Show(); self.fs:SetTextColor(S:RGB("TEXT")) end)
    c:SetScript("OnLeave", function(self) self.hover:Hide(); self.fs:SetTextColor(S:RGB("SUB")) end)
    c:SetScript("OnClick", onClick)
    UI:AttachTooltip(c, "New profile", { "A copy of everything as it is now: looks, layout and key binds." })
    return c
end

---------------------------------------------------------------------------
-- The open profile
---------------------------------------------------------------------------

local function PartRow(parent, part)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(ROW_H)
    r.part = part
    r.tile = CreateFrame("Frame", nil, r)
    r.tile:SetSize(26, 26)
    r.tile:SetPoint("LEFT", 10, 0)
    UI:Fill(r.tile, "CARD")
    UI:AddEdges(r.tile, "BORDER")
    UI:SetEdgeColor(r.tile, S:Alpha("EDGE", 0.8))
    r.g = Glyph(r.tile, 14, PART_INFO[part].icon)
    r.g:SetPoint("CENTER")
    r.title = UI:Text(r, "emph", "TEXT", { text = PART_INFO[part].title })
    r.title:SetPoint("TOPLEFT", r.tile, "TOPRIGHT", 12, -1)
    r.desc = UI:Text(r, "small", "SUB")
    r.desc:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -3)
    r.sw = UI:CreateSwitch(r, nil, function(on) PUI:SetPart(part, on) end)
    r.sw:SetPoint("RIGHT", r, "RIGHT", -10, 0)
    r.rule = r:CreateTexture(nil, "BORDER")
    r.rule:SetPoint("BOTTOMLEFT", 10, 0)
    r.rule:SetPoint("BOTTOMRIGHT", -10, 0)
    r.rule:SetHeight(1)
    r.rule:SetColorTexture(S:Color("HAIRLINE"))
    if part == "looks" then
        r.thumb = CreateFrame("Frame", nil, r)
        r.thumb:SetSize(96, 38)
        r.thumb:SetPoint("RIGHT", r.sw, "LEFT", -12, 0)
        UI:Fill(r.thumb, "INSET")
        UI:AddEdges(r.thumb, "BORDER")
        UI:SetEdgeColor(r.thumb, S:Alpha("EDGE", 0.8))
        r.thumb.preview = CreateFrame("Frame", nil, r.thumb)
        r.thumb.preview:SetPoint("TOPLEFT", r.thumb, "TOPLEFT", 4, -2)
        r.thumb.clip = r.thumb
        if r.thumb.SetClipsChildren then r.thumb:SetClipsChildren(true) end
        r.right = r.thumb
    else
        local label = part == "layout" and "Edit layout" or "Key binds"
        r.btn = UI:CreateSleekButton(r, label, 92, 22, function()
            if part == "layout" then
                if ns.EditMode then ns.EditMode:Open() end
            elseif ns.KeyBinds then ns.KeyBinds:Open() end
        end)
        UI:SetTextSize(r.btn:GetFontString(), "small")
        r.btn:SetPoint("RIGHT", r.sw, "LEFT", -12, 0)
        r.right = r.btn
    end
    r.desc:SetPoint("RIGHT", r.right, "LEFT", -10, 0)
    r.desc:SetWordWrap(false)
    return r
end

local function PaintPartRow(r, p, inUse)
    local on = P():Has(p, r.part)
    r.sw:SetChecked(on)
    local desc
    if not on then
        desc = "Off: left as it is when this profile comes on."
    elseif r.part == "looks" then
        desc = P():LooksText(p)
    elseif r.part == "layout" then
        local n = 0
        for _ in pairs(p.frames or {}) do n = n + 1 end
        desc = n > 1 and (n .. " frames placed") or n == 1 and "1 frame placed" or "Every frame where it goes by default"
    else
        local n = P():CountKeys(p.keys)
        desc = type(p.keys) ~= "table" and "Saved when it is in use" or n > 0 and (n .. " keys on the bars") or "No keys yet"
    end
    r.desc:SetText(desc)
    r.title:SetTextColor(S:RGB(on and "TEXT" or "SUB"))
    r.g:SetVertexColor(S:Alpha(on and "GOLD" or "DIM", 1))
    r.right:SetAlpha(on and 1 or 0.35)
    if r.btn then r.btn:SetEnabled(on and inUse) end
    if r.thumb then
        local key = P():LooksKey(p)
        local look = ns.Look and ns.Look.BY_KEY and ns.Look.BY_KEY[key]
        if look and ns.Look.PaintTile then
            r.thumb.preview:SetSize(88, 34)
            pcall(ns.Look.PaintTile, r.thumb, look)
        end
    end
end

local function SpecButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(26)
    b.bg = UI:Fill(b, "INSET")
    UI:AddEdges(b, "BORDER")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("LEFT", 3, 0)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.fs = UI:Text(b, "small", "TEXT")
    b.fs:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
    b.other = UI:Text(b, "small", "DIM")
    b.other:SetPoint("LEFT", b.fs, "RIGHT", 5, 0)
    b:SetScript("OnEnter", function(self) self.over = true; self:Paint() end)
    b:SetScript("OnLeave", function(self) self.over = nil; self:Paint() end)
    function b:Paint()
        local on = self.on
        if on then
            UI:Gradient(self.bg, "VERTICAL", { 0.10, 0.09, 0.05, 1 }, { 0.14, 0.13, 0.06, 1 })
        else
            self.bg:SetColorTexture(S:Color(self.over and "CARD" or "INSET"))
        end
        UI:SetEdgeColor(self, on and GOLD_DEEP[1] or 0.34, on and GOLD_DEEP[2] or 0.34, on and GOLD_DEEP[3] or 0.38,
            on and 1 or (self.over and 0.9 or 0.6))
        self.fs:SetTextColor(S:RGB(on and "GOLD" or "TEXT"))
        self.icon:SetDesaturated(not on)
        self.icon:SetAlpha(on and 1 or 0.7)
    end
    return b
end

---------------------------------------------------------------------------
-- The block
---------------------------------------------------------------------------

function PUI:SetPart(part, on)
    local f = self.block
    if not f or not f.sel then return end
    P():SetPart(f.sel, part, on)
    self:Paint()
end

local function Width(f)
    local w = f:GetWidth() or 0
    if w < 200 then w = PUI.bodyW or 534 end
    return w
end

-- Builds the block in a Settings section (SettingsUI:BuildLayout). Returns it.
function PUI:Build(SU, sec)
    local f = CreateFrame("Frame", nil, sec)
    self.block = f
    f.cards = {}
    f.plus = NewPlusCard(f, function() PUI:New() end)
    -- the open profile
    local d = CreateFrame("Frame", nil, f)
    f.detail = d
    d.bg = UI:Fill(d, { 0.04, 0.04, 0.05, 0.55 })
    UI:AddEdges(d, "BORDER")
    UI:SetEdgeColor(d, S:Alpha("EDGE", 0.7))
    d.head = CreateFrame("Frame", nil, d)
    d.head:SetPoint("TOPLEFT", 1, -1)
    d.head:SetPoint("TOPRIGHT", -1, -1)
    d.head:SetHeight(40)
    d.art = d.head:CreateTexture(nil, "BACKGROUND")
    d.art:SetAllPoints()
    d.shade = d.head:CreateTexture(nil, "BACKGROUND", nil, 1)
    d.shade:SetAllPoints()
    UI:Gradient(d.shade, "HORIZONTAL", { 0.04, 0.04, 0.05, 0.94 }, { 0.04, 0.04, 0.05, 0.5 })
    d.name = UI:Text(d.head, "title", "GOLD")
    d.name:SetPoint("LEFT", 10, 0)
    UI:SetTextSize(d.name, 14)
    d.use = UI:CreatePill(d.head, "ok", "In use", 16)
    d.use:SetPoint("LEFT", d.name, "RIGHT", 10, 0)
    d.useNow = UI:CreateSleekButton(d.head, "Use now", 76, 22, function() PUI:UseNow() end, "primary")
    UI:SetTextSize(d.useNow:GetFontString(), "small")
    d.useNow:SetPoint("LEFT", d.name, "RIGHT", 10, 0)
    d.del = UI:CreateTipIconButton(d.head, 18, UI.ICON.trash, "Delete", "Characters using it go back to Default.",
        function() PUI:Delete() end)
    d.del:SetPoint("RIGHT", -8, 0)
    d.share = UI:CreateTipIconButton(d.head, 18, 18, "Share", "A link in chat: who clicks it gets the whole profile "
        .. "and picks which parts to use.", function(b) PUI:Share(b) end)
    d.share:SetPoint("RIGHT", d.del, "LEFT", -4, 0)
    d.rename = UI:CreateTipIconButton(d.head, 18, UI.ICON.notes, "Rename", nil, function() PUI:Rename() end)
    d.rename:SetPoint("RIGHT", d.share, "LEFT", -4, 0)
    d.copy = UI:CreateTipIconButton(d.head, 18, UI.ICON.export, "Copy", "A new profile with the same parts.",
        function() PUI:CopySel() end)
    d.copy:SetPoint("RIGHT", d.rename, "LEFT", -4, 0)
    d.rows = {}
    for i, part in ipairs(P().PARTS) do
        local r = PartRow(d, part)
        r:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -41 - (i - 1) * ROW_H)
        r:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, -41 - (i - 1) * ROW_H)
        d.rows[part] = r
    end
    -- Use when I play
    local sy = -41 - 3 * ROW_H
    d.specTitle = UI:Text(d, "emph", "TEXT", { text = "Use when I play" })
    d.specTitle:SetPoint("TOPLEFT", d, "TOPLEFT", 48, sy - 10)
    d.specDesc = UI:Text(d, "small", "SUB", { text = "Switches on by itself when you change to that spec." })
    d.specDesc:SetPoint("TOPLEFT", d.specTitle, "BOTTOMLEFT", 0, -3)
    d.specTile = CreateFrame("Frame", nil, d)
    d.specTile:SetSize(26, 26)
    d.specTile:SetPoint("TOPLEFT", d, "TOPLEFT", 10, sy - 9)
    UI:Fill(d.specTile, "CARD")
    UI:AddEdges(d.specTile, "BORDER")
    UI:SetEdgeColor(d.specTile, S:Alpha("EDGE", 0.8))
    d.specG = Glyph(d.specTile, 14, UI.ICON.gear)
    d.specG:SetPoint("CENTER")
    d.specG:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    d.specBtns = {}
    d.specY = sy - 46
    -- Characters
    d.charTitle = UI:Text(d, "emph", "TEXT", { text = "Characters" })
    d.charDesc = UI:Text(d, "small", "SUB", { text = "Yours switches now; another character at its next login." })
    d.charTile = CreateFrame("Frame", nil, d)
    d.charTile:SetSize(26, 26)
    UI:Fill(d.charTile, "CARD")
    UI:AddEdges(d.charTile, "BORDER")
    UI:SetEdgeColor(d.charTile, S:Alpha("EDGE", 0.8))
    d.charG = Glyph(d.charTile, 14, 46)
    d.charG:SetPoint("CENTER")
    d.charG:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    d.charBtns = {}
    f.foot = UI:Text(f, "small", "DIM", { wrap = true,
        text = "Changes you make while a profile is in use save into it: a look picked, a frame moved, a key bound." })
    self.SU, self.sec = nil, nil
    self.bodyW = SU.BodyWidth and SU:BodyWidth() or 534
    f:SetWidth(self.bodyW)
    self:Paint()
    SU:Place(sec, f, f.h or 400)
    f:SetScript("OnSizeChanged", function() PUI:Paint() end)
    self.SU, self.sec = SU, sec
    if not self.hooked then
        self.hooked = true
        local function repaint() if PUI.block and PUI.block:IsVisible() then PUI:Paint() end end
        ns:On("PROFILE_CHANGED", repaint)
        ns:On("LAYOUT_CHANGED", repaint)
        ns:On("DEMO_TOGGLED", function() if PUI.block then PUI.block.sel = nil end repaint() end)
    end
    return f
end

function PUI:Selected() return self.block and self.block.sel end
function PUI:Select(id)
    if not self.block then return end
    self.block.sel = id
    self:Paint()
end

function PUI:Paint()
    local f = self.block
    if not f then return end
    local list = P():List()
    local using = P():CurrentId()
    if not f.sel or not P():Get(f.sel) then f.sel = using end
    local W = Width(f)
    -- (as many cards across as fit at 96 px or more, sharing the width: no gap left at the row's end)
    local cols = max(3, floor((W + GAP) / (96 + GAP)))
    local cw = floor((W - (cols - 1) * GAP) / cols)
    local n = #list + 1
    for i, p in ipairs(list) do
        local c = f.cards[i]
        if not c then
            c = NewProfileCard(f)
            c:SetScript("OnClick", function(self) PUI:Select(self.p.id) end)
            f.cards[i] = c
        end
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", f, "TOPLEFT", col * (cw + GAP), -row * (CARD_H + GAP))
        c:SetWidth(cw)
        c.w = cw
        PaintCard(c, p, p.id == f.sel, p.id == using)
        c:Show()
    end
    for i = #list + 1, #f.cards do f.cards[i]:Hide() end
    do
        local col, row = (n - 1) % cols, floor((n - 1) / cols)
        f.plus:ClearAllPoints()
        f.plus:SetPoint("TOPLEFT", f, "TOPLEFT", col * (cw + GAP), -row * (CARD_H + GAP))
        f.plus:SetWidth(cw)
    end
    local rows = floor((n - 1) / cols) + 1
    local top = rows * (CARD_H + GAP) + 4
    -- the open profile
    local p = P():Get(f.sel)
    local d = f.detail
    d:ClearAllPoints()
    d:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -top)
    d:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -top)
    SetArt(d.art, p, floor(W), 40, 0.7)
    d.name:SetText(p.name or "Profile")
    local inUse = p.id == using
    d.use:SetShown(inUse)
    d.useNow:SetShown(not inUse)
    d.del:SetEnabled(p.id ~= "default")
    d.rename:SetEnabled(p.id ~= "default")
    for _, part in ipairs(P().PARTS) do PaintPartRow(d.rows[part], p, inUse) end
    -- the specs
    local specs = P():MySpecs()
    local x = 48
    for i, s in ipairs(specs) do
        local b = d.specBtns[i]
        if not b then
            b = SpecButton(d)
            b:SetScript("OnClick", function(self) PUI:ToggleSpec(self.spec) end)
            d.specBtns[i] = b
        end
        b.spec = s.label
        b.icon:SetTexture(s.icon or 134400)
        b.fs:SetText(s.label)
        local other = P():ProfileOfSpec(s.label)
        local op = other and other ~= p.id and P():Get(other)
        b.on = other == p.id
        b.other:SetText(op and op.name or "")
        local w = 3 + 20 + 6 + (b.fs:GetStringWidth() or 40) + (op and (5 + (b.other:GetStringWidth() or 40)) or 0) + 9
        b:SetWidth(floor(w + 0.5))
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", d, "TOPLEFT", x, d.specY)
        x = x + b:GetWidth() + 5
        b:Paint()
        b:Show()
    end
    for i = #specs + 1, #d.specBtns do d.specBtns[i]:Hide() end
    -- the characters (wrapping onto more lines when there are many)
    local cy = d.specY - 26 - 14
    d.charTile:ClearAllPoints()
    d.charTile:SetPoint("TOPLEFT", d, "TOPLEFT", 10, cy - 1)
    d.charTitle:ClearAllPoints()
    d.charTitle:SetPoint("TOPLEFT", d, "TOPLEFT", 48, cy - 2)
    d.charDesc:ClearAllPoints()
    d.charDesc:SetPoint("TOPLEFT", d.charTitle, "BOTTOMLEFT", 0, -3)
    cy = cy - 38
    local chars = P():MyCharacters()
    local me = ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey()
    x = 48
    local lineW = W - 10
    for i, ch in ipairs(chars) do
        local b = d.charBtns[i]
        if not b then
            b = SpecButton(d)
            b:SetScript("OnClick", function(self) PUI:ToggleChar(self.key) end)
            d.charBtns[i] = b
        end
        b.key = ch.key
        local file, l, r, t, bt
        if ns.Look and ns.Look.ClassIcon then file, l, r, t, bt = ns.Look.ClassIcon(ch.class, true) end
        if file and l then
            b.icon:SetTexture(file); b.icon:SetTexCoord(l, r, t, bt); b.icon:SetVertexColor(1, 1, 1)
        else
            -- (class unknown: the addon's person glyph, not the game's question mark)
            UI:SetGlyph(b.icon, 61); b.icon:SetVertexColor(S:RGB("SUB"))
        end
        local short = ns.Util and ns.Util.ShortName and ns.Util.ShortName(ch.key) or ch.key
        b.fs:SetText(short .. (ch.key == me and " (you)" or ""))
        local use = P():ProfileOfChar(ch.key)
        local op = use ~= p.id and use ~= "default" and P():Get(use)
        b.on = use == p.id
        b.other:SetText(op and op.name or "")
        local w = 3 + 20 + 6 + (b.fs:GetStringWidth() or 40) + (op and (5 + (b.other:GetStringWidth() or 40)) or 0) + 9
        b:SetWidth(floor(w + 0.5))
        if x + b:GetWidth() > lineW and x > 48 then x = 48; cy = cy - 31 end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", d, "TOPLEFT", x, cy)
        x = x + b:GetWidth() + 5
        b:Paint()
        if ch.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[ch.class] and not b.on then
            local c = RAID_CLASS_COLORS[ch.class]
            b.fs:SetTextColor(c.r, c.g, c.b)
        end
        b.icon:SetDesaturated(false)
        b.icon:SetAlpha(b.on and 1 or 0.8)
        b:Show()
    end
    for i = #chars + 1, #d.charBtns do d.charBtns[i]:Hide() end
    local dh = -cy + 26 + 10
    d:SetHeight(dh)
    f.foot:ClearAllPoints()
    f.foot:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 2, -8)
    f.foot:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    local h = top + dh + 30
    if f.h ~= h then
        local was = f.h
        f.h = h
        f:SetHeight(h)
        if f.item then f.item.h = h; f.item.span = h end
        -- (a row of cards more or less: the section grows with it and the page lays itself out again)
        local sec = self.sec
        if was and sec and sec.height then
            sec.height = sec.height + (h - was)
            if self.SU and self.SU.Refresh then ns.Util.Debounce("profiles-relayout", 0, function() PUI.SU:Refresh() end) end
        end
    end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function PUI:UseNow()
    local id = self:Selected()
    if not id then return end
    if P().demo then P():UseDemo(id) else P():Use(id) end
    self:Paint()
end

function PUI:ToggleSpec(spec)
    local id = self:Selected()
    if not id then return end
    P():SetSpec(spec, P():ProfileOfSpec(spec) ~= id and id or nil)
    self:Paint()
end

function PUI:ToggleChar(key)
    local id = self:Selected()
    if not id or not key then return end
    local cur = P():ProfileOfChar(key)
    if cur == id then
        if id == "default" then return end
        P():SetCharacter(key, "default")
    else
        P():SetCharacter(key, id)
    end
    self:Paint()
end

function PUI:New()
    ns.Popup:Prompt({ title = "New profile", text = "A copy of everything as it is now: looks, layout and key binds.",
        default = ns.Layout.UniqueName("Profile"), maxLetters = 32, trim = true,
        validate = function(v)
            if v == "" then return false end
            if not P().demo and ns.Layout:NameTaken(v) then return "A profile has that name already." end
        end,
        onAccept = function(v)
            local id = P():New(v)
            if id then PUI:Select(id) end
        end })
end

function PUI:CopySel()
    local id = P():Copy(self:Selected())
    if id then self:Select(id) end
end

function PUI:Rename()
    local p = P():Get(self:Selected())
    if not p or p.id == "default" then return end
    ns.Popup:Prompt({ title = "Rename", default = p.name, maxLetters = 32, trim = true,
        validate = function(v)
            if v == "" then return false end
            if not P().demo and ns.Layout:NameTaken(v, p.id) then return "A profile has that name already." end
        end,
        onAccept = function(v)
            if P().demo then p.name = v else ns.Layout:Rename(p.id, v) end
            PUI:Paint()
        end })
end

function PUI:Delete()
    local p = P():Get(self:Selected())
    if not p or p.id == "default" then return end
    ns.Popup:Confirm({ title = "Delete " .. (p.name or "profile") .. "?", danger = true, ok = "Delete", key = "PROFILE_DELETE",
        text = "Characters using it go back to Default. Its specs keep what they have.",
        onAccept = function()
            P():Delete(p.id)
            PUI.block.sel = nil
            PUI:Paint()
        end })
end

function PUI:Share(anchor)
    local id = self:Selected()
    if not id or P().demo then return end
    local ref = ns.Layout:ShareRef(id)
    if ref and ns.ShareWindow and ns.ShareWindow.Open then ns.ShareWindow:Open(ref, anchor) end
end

---------------------------------------------------------------------------
-- The profile menu (Edit layout's and Key binds' bars): switch, or a new one
---------------------------------------------------------------------------

function PUI:FillMenu(root)
    local using = P():CurrentId()
    for _, p in ipairs(P():List()) do
        local b = root:CreateButton(p.name or p.id, function()
            if P().demo then P():UseDemo(p.id) else P():Use(p.id) end
        end)
        if b and b.SetChecked and p.id == using then b:SetChecked(true) end
    end
    root:CreateDivider()
    root:CreateButton("New profile\226\128\166", function() PUI:New() end)
    root:CreateButton("Profiles in Settings", function()
        if ns.MainFrame and ns.MainFrame.Open then ns.MainFrame:Open("settings") end
        if ns.SettingsUI then ns.SettingsUI:SelectSection("layout") end
    end)
end

function PUI:InUseName()
    local p = P() and P():Get(P():CurrentId())
    return p and p.name or "Default"
end

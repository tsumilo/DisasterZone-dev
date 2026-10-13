if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LookBars.lua", ...) then return end -- DisasterZone UI/LookBars.lua
-- Action bars in the addon's looks (UI/Look.lua part "bars"): reskinned, not replaced. The buttons stay the game's
-- secure action buttons (paging, stances, macros, key binds, the cast-on-key-down setting, every protected action:
-- nothing changes there); only their faces change, and only by drawing: the icon's crop or the game's own icon mask
-- (a disc for Halo), the slot art hidden, an edge / ring / rim of the look's, the key bind and count fonts and places,
-- the out-of-range colour, and a plate behind each bar. Their places and sizes stay the game's Edit Mode's (Edit
-- layout moves them through it). Hooks run after the game's own (hooksecurefunc): nothing is replaced in its code.
-- The rest of the game's bottom bar belongs to the part too: the bag slots are reskinned like the buttons, the micro
-- menu and the bags (with the key ring) sit on plates of the look, and the experience and reputation bars are ours
-- (UI/LookBars.lua XP: the game's status bars retired, not protected): rested experience, numbers on mouse-over.
-- Halo's round icons: a mask texture of the game's portrait disc on the icon (the round portrait cut does nothing to
-- the file ids action icons come as: in game they stayed square in the ring); the hover, pressed, checked and flash
-- states take the look's shape too (discs in Halo), re-applied after the game's own updates.
-- (the old note: SetPortraitToTexture, chosen because masks striped on meter rows; it never cut action icons
-- on this client, the meters found out).
-- Options (ui.bars.*): keys (show the key binds), macros (macro names), cooldown ("theme" | "numbers" | "sweep"),
-- range ("icon" red icon | "key" red key bind), xp (our experience / reputation bar).
local addonName, ns = ...

local Bars = ns:NewModule("LookBars")
local UI = ns.UI

local pairs, ipairs, type = pairs, ipairs, type

local function Look() return ns.Look end

-- bar frame -> the buttons' global name prefix and count
local BARS = {
    { "MainActionBar", "ActionButton", 12 }, { "MultiBarBottomLeft", "MultiBarBottomLeftButton", 12 },
    { "MultiBarBottomRight", "MultiBarBottomRightButton", 12 }, { "MultiBarRight", "MultiBarRightButton", 12 },
    { "MultiBarLeft", "MultiBarLeftButton", 12 }, { "StanceBar", "StanceButton", 10 },
    { "PetActionBar", "PetActionButton", 10 },
}
-- the strips that get a plate in looks with plates
local STRIPS = { "MicroMenuContainer", "BagsBar" }
-- The menu and the bags: their art hidden, our tile drawn over each (the look's icon shape, the same as the action
-- buttons'), the button itself the game's (its click, tooltip and menu). The menu's tiles show these icons; a bag
-- slot shows its bag (read from the game's own icon); the rest keep their own art.
local MICRO = { "CharacterMicroButton", "SpellbookMicroButton", "PlayerSpellsMicroButton", "TalentMicroButton",
    "QuestLogMicroButton", "SocialsMicroButton", "GuildMicroButton", "WorldMapMicroButton", "LFGMicroButton",
    "LFDMicroButton", "PVPMicroButton", "MainMenuMicroButton", "HelpMicroButton" }
local TILED = { "KeyRingButton", "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot",
    "CharacterBag2Slot", "CharacterBag3Slot" }
for _, n in ipairs(MICRO) do TILED[#TILED + 1] = n end
-- the backpack's picture (the bag slots show their bags)
local TILE_ICON = { MainMenuBarBackpackButton = "Interface\\Buttons\\Button-Backpack-Up" }
-- the menu's glyphs: { sheet, index } (sheet 2 = Media/Strategy/uiglyphs, art pack 8; else the main atlas's
-- nearest) - the addon's own flat glyphs, as every button of the addon has
local GLYPHS = {
    CharacterMicroButton = { 1, 61 }, SpellbookMicroButton = { 2, 1, 25 }, PlayerSpellsMicroButton = { 2, 1, 25 },
    TalentMicroButton = { 2, 2, 58 }, QuestLogMicroButton = { 2, 3, 50 }, SocialsMicroButton = { 1, 46 },
    GuildMicroButton = { 1, 26 }, WorldMapMicroButton = { 2, 6, 31 }, LFGMicroButton = { 1, 15 },
    LFDMicroButton = { 1, 15 }, PVPMicroButton = { 2, 4, 62 }, MainMenuMicroButton = { 1, 13 },
    HelpMicroButton = { 1, 11 }, KeyRingButton = { 2, 5, 38 },
}
local SHEET2 = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\uiglyphs"

-- the stone art of the classic main bar
local ART = { "MainMenuBarTexture0", "MainMenuBarTexture1", "MainMenuBarTexture2", "MainMenuBarTexture3",
    "MainMenuBarTextureExtender", "MainMenuBarLeftEndCap", "MainMenuBarRightEndCap", "MainMenuMaxLevelBar0",
    "MainMenuMaxLevelBar1", "MainMenuMaxLevelBar2", "MainMenuMaxLevelBar3" }

local skinned = {}       -- button -> its skin
local plates = {}        -- bar name -> plate
Bars.skinned = skinned

local RED = { 0.85, 0.2, 0.15 }

---------------------------------------------------------------------------
-- A button
---------------------------------------------------------------------------

local function Skin(b)
    local s = skinned[b]
    if s then return s end
    local L = Look()
    s = { b = b }
    -- the ring (Halo) behind the icon, the edges over it
    s.ring = L.Tex(b, "BACKGROUND", -6, L.DISC)
    s.ring:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2); s.ring:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
    s.ringIn = L.Tex(b, "BACKGROUND", -5, L.DISC)
    s.ringIn:SetPoint("TOPLEFT", b, "TOPLEFT", -0.5, 0.5); s.ringIn:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0.5, -0.5)
    s.edge = L.Edges(b, "OVERLAY", 6); s.edge:Place(b, 0)
    s.edge2 = L.Edges(b, "OVERLAY", 7); s.edge2:Place(b, -1)
    s.sheen = L.Tex(b, "OVERLAY", 5)
    s.bezel = L.Tex(b, "OVERLAY", 7, L.GILT .. "bezel")      -- (Gilded's worked frame)
    s.bezel:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1); s.bezel:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
    s.sheen:SetPoint("TOPLEFT", b, "TOPLEFT", 2, -2)
    s.sheen:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -2)
    skinned[b] = s
    -- after the game's own updates: our range colour, the hidden art
    if b.UpdateUsable then hooksecurefunc(b, "UpdateUsable", function(self) Bars:Range(self) end) end
    if b.Update then hooksecurefunc(b, "Update", function(self) Bars:Art(self) end) end
    s.icon = b.icon or b.Icon or _G[(b:GetName() or "") .. "IconTexture"]
    return s
end

-- Hides the game's slot art and frame (they come back on some updates: called again after them).
function Bars:Art(b)
    local s = skinned[b]
    if not s or not s.look then return end
    if b.NormalTexture then b.NormalTexture:SetAlpha(0) end
    local nt = b.GetNormalTexture and b:GetNormalTexture()
    if nt then nt:SetAlpha(0) end
    if b.SlotBackground then b.SlotBackground:SetAlpha(0) end
    if b.SlotArt then b.SlotArt:SetAlpha(0) end
    if b.Border then b.Border:SetAlpha(s.look.key == "flat" and 0.5 or 0) end
    Bars:States(b)
end

-- The button's states in the look's shape, over the icon: hover (light), pressed (dark), checked (gold), the attack
-- flash (red), the spell highlight (gold). Discs in Halo, squares in the rest.
local function StateTex(t, icon, round, r, g, bl, a, blend)
    if not t or not icon then return end
    local L = Look()
    t:SetTexture(round and L.DISC or L.WHITE)
    t:SetTexCoord(0, 1, 0, 1)
    t:SetVertexColor(r, g, bl, a)
    if t.SetBlendMode then t:SetBlendMode(blend or "BLEND") end
    t:ClearAllPoints()
    t:SetAllPoints(icon)
end

function Bars:States(b)
    local s = skinned[b]
    if not s or not s.look or not s.icon then return end
    local round = s.look.key == "halo"
    local icon = s.icon
    StateTex(b.HighlightTexture or (b.GetHighlightTexture and b:GetHighlightTexture()), icon, round, 1, 1, 1, 0.18, "ADD")
    StateTex(b.PushedTexture or (b.GetPushedTexture and b:GetPushedTexture()), icon, round, 0, 0, 0, 0.4)
    StateTex(b.CheckedTexture or (b.GetCheckedTexture and b:GetCheckedTexture()), icon, round, 1, 0.82, 0, 0.35, "ADD")
    StateTex(b.Flash, icon, round, 1, 0.15, 0.1, 0.45, "ADD")
    StateTex(b.SpellHighlightTexture, icon, round, 1, 0.82, 0, 0.45, "ADD")
end

local function Font(fs, size, r, g, b)
    if not fs then return end
    UI:SetTextSize(fs, size)
    if r then fs:SetTextColor(r, g, b) end
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
end

function Bars:Apply(b, look)
    local L = Look()
    local s = Skin(b)
    s.look = look
    local k = look.key
    local icon = s.icon
    -- the icon: square crop without the game's mask; Halo: our disc mask over the whole button (round, filling the
    -- ring: the crop zooms past the icon's own border)
    if icon then
        if b.IconMask and s.masked ~= false then
            pcall(icon.RemoveMaskTexture, icon, b.IconMask)
            s.masked = false
        end
        icon:ClearAllPoints()
        local inset = (k == "sigil" or k == "gilded") and 2 or ((k == "flat") and 1 or 0)
        icon:SetPoint("TOPLEFT", b, "TOPLEFT", inset, -inset)
        icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -inset, inset)
        s.round = k == "halo"
        if s.round then
            if not s.mask and b.CreateMaskTexture then
                s.mask = b:CreateMaskTexture()
                s.mask:SetTexture(L.DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            end
            if s.mask then
                s.mask:ClearAllPoints()
                s.mask:SetAllPoints(icon)
                if not s.maskOn then pcall(icon.AddMaskTexture, icon, s.mask); s.maskOn = true end
            end
            icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
        else
            if s.mask and s.maskOn then pcall(icon.RemoveMaskTexture, icon, s.mask); s.maskOn = false end
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    -- ring / edges / sheen
    local round = k == "halo"
    s.ring:SetShown(round); s.ringIn:SetShown(round)
    if round then L.Color(s.ring, { 1, 1, 1, 0.14 }); L.Color(s.ringIn, { 0, 0, 0, 1 }) end
    if k == "flat" then s.edge:Paint({ 0, 0, 0, 1 }); s.edge2:Paint(nil)
    elseif k == "sigil" then s.edge:Paint({ 0, 0, 0, 1 }); s.edge2:Paint({ 1, 1, 1, 0.2 })
    elseif k == "gilded" then s.edge:Paint(nil); s.edge2:Paint(nil)
    else s.edge:Paint(nil); s.edge2:Paint(nil) end
    s.bezel:SetShown(k == "gilded")
    if k == "sigil" then
        s.sheen:SetHeight(b:GetHeight() > 0 and b:GetHeight() / 2 or 16)
        L.Gradient(s.sheen, { 1, 1, 1, 0 }, { 1, 1, 1, 0.18 })
    else s.sheen:Hide() end
    -- the cooldown: round for Halo
    local cd = b.cooldown
    if cd then
        if cd.SetSwipeTexture then pcall(cd.SetSwipeTexture, cd, round and L.DISC or L.WHITE) end
        if cd.SetUseCircularEdge then pcall(cd.SetUseCircularEdge, cd, round) end
        local mode = L:Opt("bars", "cooldown", "theme")
        if cd.SetHideCountdownNumbers then pcall(cd.SetHideCountdownNumbers, cd, mode == "sweep") end
        if cd.SetDrawSwipe then pcall(cd.SetDrawSwipe, cd, mode ~= "numbers") end
    end
    -- key bind, count, macro name
    local hk, ct, nm = b.HotKey, b.Count, b.Name
    if hk then
        hk:ClearAllPoints()
        if k == "halo" then
            hk:SetPoint("BOTTOM", b, "BOTTOM", 0, 1); hk:SetJustifyH("CENTER"); Font(hk, "caps", 0.86, 0.84, 0.78)
        elseif k == "sigil" then
            hk:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -3); hk:SetJustifyH("LEFT"); Font(hk, "caps", 1, 0.82, 0)
        elseif k == "slate" then
            hk:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 2, 2); hk:SetJustifyH("LEFT"); Font(hk, "caps", 0.74, 0.72, 0.65)
        elseif k == "gilded" then
            hk:SetPoint("TOPRIGHT", b, "TOPRIGHT", -3, -3); hk:SetJustifyH("RIGHT"); Font(hk, "small", 0.96, 0.9, 0.75)
        else
            hk:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -2); hk:SetJustifyH("RIGHT"); Font(hk, "small", 0.85, 0.85, 0.85)
        end
        hk:SetAlpha(L:Opt("bars", "keys", true) and 1 or 0)
    end
    if ct then
        ct:ClearAllPoints()
        if k == "slate" then ct:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -2)
        else ct:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2) end
        Font(ct, "body")
    end
    if nm then nm:SetAlpha(L:Opt("bars", "macros", false) and 1 or 0) end
    self:Art(b)
    self:Range(b)
end

-- Out of range: the icon red (or the key bind, the game's way).
function Bars:Range(b)
    local s = skinned[b]
    if not s or not s.look then return end
    local icon = b.icon
    if not icon or not b.action or not IsActionInRange then return end
    if Look():Opt("bars", "range", "icon") ~= "icon" then return end
    local inRange = IsActionInRange(b.action)
    if inRange == false then
        icon:SetVertexColor(RED[1], RED[2], RED[3])
        s.oor = true
    elseif s.oor then
        s.oor = nil
        -- (back in range: the game's own usable colour again)
        if b.UpdateUsable then b:UpdateUsable() end
    end
end

---------------------------------------------------------------------------
-- Tiles: the menu and the bags in the look
---------------------------------------------------------------------------

local tiles = {}          -- button -> tile
Bars.tiles = tiles

-- The texture the game shows on a button now: a bag's icon (the game sets button.Icon first), else its own art.
local function GameTexture(b)
    local icon = b.Icon or b.icon or _G[(b:GetName() or "") .. "IconTexture"]
    if icon and icon.GetTexture and icon:GetTexture() then return icon:GetTexture() end
    local nt = b.GetNormalTexture and b:GetNormalTexture()
    return nt and nt.GetTexture and nt:GetTexture() or nil
end

-- Hides every texture of the game's on a button (they come back on state changes: done again on each tick).
local function HideArt(b)
    for _, r in ipairs({ b:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then r:SetAlpha(0) end
    end
    local port = _G.MicroButtonPortrait
    if port and port.GetParent and port:GetParent() == b then port:SetAlpha(0) end
end

-- A glyph on a texture: the main atlas's (UI.ICON_ATLAS) or the second sheet's (art pack 8; else the fallback).
local function SetGlyph(tex, g)
    if g[1] == 2 and ns:HasAssets(8) then
        local i = g[2] - 1
        tex:SetTexture(SHEET2)
        tex:SetTexCoord((i % 4) / 4, (i % 4 + 1) / 4, math.floor(i / 4) / 4, (math.floor(i / 4) + 1) / 4)
    else
        local c = UI:IconCoords(g[1] == 2 and g[3] or g[2])
        tex:SetTexture(UI.ICON_ATLAS)
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    end
end

-- a glyph tile's faces per look: ground, its edges, the glyph's colour
local GLYPH_C = { flat = { 0.86, 0.84, 0.78 }, halo = { 0.88, 0.86, 0.8 }, sigil = { 1, 0.86, 0.45 },
    slate = { 0.8, 0.79, 0.74 }, gilded = { 0.96, 0.9, 0.75 } }

local function PaintGlyphTile(t, hover)
    local L, look = Look(), t.look
    local k = look.key
    local gold = { 1, 0.82, 0, 1 }
    local c = hover and gold or GLYPH_C[k] or GLYPH_C.flat
    t.glyph:SetVertexColor(c[1], c[2], c[3], t.enabled and 1 or 0.35)
    if k == "halo" then
        L.Color(t.ring, hover and gold or { 1, 1, 1, 0.16 })
    elseif k == "sigil" then
        t.edge2:Paint(hover and gold or { 1, 0.82, 0, 0.55 })
    elseif k == "gilded" then
        t.edge2:Paint(hover and { 1, 0.88, 0.54, 1 } or look.rim)
    elseif k == "flat" then
        t.edge:Paint(hover and { 1, 0.82, 0, 0.8 } or { 0, 0, 0, 1 })
    end
end

function Bars:Tile(b, look)
    local L = Look()
    local name = b.dzName or b:GetName() or ""   -- (dzName: a sample button standing for one of the game's)
    local g = GLYPHS[name]
    local t = tiles[b]
    if not t then
        t = { b = b, g = g, enabled = true }
        t.f = CreateFrame("Frame", nil, b)
        t.f:SetFrameLevel(b:GetFrameLevel() + 2)
        if g then
            t.ring = L.Tex(t.f, "BACKGROUND", 1, L.DISC)
            t.ring:SetPoint("TOPLEFT", -2, 2); t.ring:SetPoint("BOTTOMRIGHT", 2, -2)
            t.ringIn = L.Tex(t.f, "BACKGROUND", 2, L.DISC)
            t.ringIn:SetPoint("TOPLEFT", -0.5, 0.5); t.ringIn:SetPoint("BOTTOMRIGHT", 0.5, -0.5)
            t.bg = L.Tex(t.f, "BACKGROUND", 3)
            t.bg:SetAllPoints(t.f)
            t.sheen = L.Tex(t.f, "ARTWORK", 1)
            t.sheen:SetPoint("TOPLEFT", 2, -2); t.sheen:SetPoint("TOPRIGHT", -2, -2)
            t.edge = L.Edges(t.f, "BORDER", 1); t.edge:Place(t.f, 0)
            t.edge2 = L.Edges(t.f, "BORDER", 2); t.edge2:Place(t.f, -1)
            t.glyph = t.f:CreateTexture(nil, "OVERLAY")
            t.glyph:SetPoint("CENTER")
            SetGlyph(t.glyph, g)
        else
            t.icon = L:Icon(t.f)
            t.icon.f:SetAllPoints(t.f)
            t.hl = L.Tex(t.f, "OVERLAY", 7)
            t.hl:SetAllPoints(t.f)
            t.hl:SetVertexColor(1, 1, 1, 0.14)
            t.hl:Hide()
        end
        b:HookScript("OnEnter", function()
            if not t.look then return end
            if t.g then PaintGlyphTile(t, true) elseif t.hl then t.hl:Show() end
        end)
        b:HookScript("OnLeave", function()
            if not t.look then return end
            if t.g then PaintGlyphTile(t, false) elseif t.hl then t.hl:Hide() end
        end)
        -- the count (free bag slots) over our tile
        local ct = b.Count or _G[name .. "Count"]
        if ct and ct.SetParent then ct:SetParent(t.f); ct:SetDrawLayer("OVERLAY", 7) end
        tiles[b] = t
    end
    t.look = look
    local k = look.key
    -- the size: the action buttons' (the look's), within the button (a menu button is tall: its tile sits low)
    local w, h = b:GetWidth() or 0, b:GetHeight() or 0
    if w <= 0 then w = 32 end
    if h <= 0 then h = 32 end
    -- (a square in the middle of the button: the menu's buttons are taller than wide, the key ring thin)
    local size = math.max(14, math.min(w, h) - ((k == "halo") and 3 or 1))
    if name == "KeyRingButton" then size = math.max(16, math.min(h * 0.62, 26)) end
    t.f:ClearAllPoints()
    t.f:SetSize(size, size)
    t.f:SetPoint("CENTER", b, "CENTER", 0, 0)
    if t.g then
        local round = k == "halo"
        t.ring:SetShown(round); t.ringIn:SetShown(round)
        if round then L.Color(t.ringIn, { 0, 0, 0, 1 }) end
        t.bg:SetTexture(round and L.DISC or L.WHITE)
        if k == "slate" then t.bg:Hide()
        elseif k == "gilded" then L.Gradient(t.bg, look.panel.bg2, look.panel.bg)
        else L.Color(t.bg, round and { 0.031, 0.031, 0.043, 0.92 } or { 0.039, 0.039, 0.051, 0.88 }) end
        t.edge:Paint((k == "flat" or k == "sigil" or k == "gilded") and { 0, 0, 0, 1 } or nil)
        t.edge2:Paint(nil)
        if k == "sigil" then
            t.sheen:SetHeight(size / 2)
            L.Gradient(t.sheen, { 1, 1, 1, 0 }, { 1, 1, 1, 0.14 })
        else t.sheen:Hide() end
        t.glyph:SetSize(size * ((k == "slate") and 0.78 or 0.58), size * ((k == "slate") and 0.78 or 0.58))
        PaintGlyphTile(t, false)
    else
        t.icon:Apply(look, look.icon == "none" and "small" or look.icon)
        -- (Halo: the same faint light ring as the action buttons and the menu)
        if k == "halo" then Look().Color(t.icon.ring, { 1, 1, 1, 0.16 }) end
        t.shown = nil
    end
    t.f:Show()
    self:TileIcon(b)
end

-- Our tile: the art hidden again, a bag's picture (from the game's own icon), the glyph dim while disabled.
function Bars:TileIcon(b)
    local t = tiles[b]
    if not t or not t.look then return end
    HideArt(b)
    local enabled = not b.IsEnabled or b:IsEnabled()
    if t.g then
        if t.enabled ~= enabled then t.enabled = enabled; PaintGlyphTile(t, false) end
        return
    end
    local tex = TILE_ICON[b:GetName() or ""] or GameTexture(b)
    if tex and tex ~= t.shown then t.icon:SetTexture(tex); t.shown = tex end
    if t.icon.tex.SetDesaturated then t.icon.tex:SetDesaturated(not enabled) end
    t.f:SetAlpha(enabled and 1 or 0.55)
end

-- (twice a second: a bag changed, a menu button came back with its art)
local tileTick = CreateFrame("Frame")
tileTick.t = 0
tileTick:SetScript("OnUpdate", function(self, dt)
    self.t = self.t + (dt or 0)
    if self.t < 0.5 then return end
    self.t = 0
    for b in pairs(tiles) do Bars:TileIcon(b) end
end)

---------------------------------------------------------------------------
-- Plates behind the bars
---------------------------------------------------------------------------

local function Plate(barName)
    local p = plates[barName]
    if p then return p end
    local bar = _G[barName]
    if not bar then return nil end
    local L = Look()
    local f = CreateFrame("Frame", nil, bar)
    f:SetFrameLevel(math.max(0, bar:GetFrameLevel() - 1))
    f:SetPoint("TOPLEFT", bar, "TOPLEFT", -4, 4)
    f:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 4, -4)
    f.panel = L:Panel(f)
    f.studs = {}
    for i = 1, 2 do
        local t = L.Tex(f, "OVERLAY", 4)
        t:SetSize(7, 7)
        if t.SetRotation then t:SetRotation(math.pi / 4) end
        t:SetPoint("CENTER", f, i == 1 and "LEFT" or "RIGHT", 0, 0)
        f.studs[i] = t
    end
    plates[barName] = f
    return f
end

function Bars:Restyle()
    local L = Look()
    if not L:IsOn("bars") then return end
    local look = L:For("bars")
    for _, def in ipairs(BARS) do
        local p = _G[def[1]] and Plate(def[1])
        if p then
            if look.plate then
                p.panel:Apply(look)
                p:Show()
            else p:Hide() end
            for _, t in ipairs(p.studs) do
                if look.studs and look.plate then Look().Color(t, look.panel.corners) else t:Hide() end
            end
        end
        for i = 1, def[3] do
            local b = _G[def[2] .. i]
            if b then self:Apply(b, look) end
        end
    end
    for _, name in ipairs(TILED) do
        local b = _G[name]
        if b then self:Tile(b, look) end
    end
    for _, name in ipairs(STRIPS) do
        local p = _G[name] and Plate(name)
        if p then
            if look.plate then p.panel:Apply(look); p:Show() else p:Hide() end
            for _, t in ipairs(p.studs) do
                if look.studs and look.plate then Look().Color(t, look.panel.corners) else t:Hide() end
            end
        end
    end
    self:XP()
    for _, name in ipairs(ART) do
        local t = _G[name]
        if t and t.SetAlpha then t:SetAlpha(0) end
    end
    local mab = _G.MainActionBar
    if mab and mab.EndCaps then mab.EndCaps:SetAlpha(0) end
end

---------------------------------------------------------------------------
-- Experience and reputation: our bar (the game's status bars retired while the part has a look)
---------------------------------------------------------------------------

local XP_BLIZZ = { "MainStatusTrackingBarContainer", "SecondaryStatusTrackingBarContainer", "StatusTrackingBarManager",
    "MainMenuExpBar", "ReputationWatchBar", "MainMenuBarMaxLevelBar" }
local XP_C, REST_C = { 0.58, 0.3, 0.9 }, { 0.25, 0.55, 1 }

local function XPData()
    local d = {}
    local maxLevel = (GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()) or (MAX_PLAYER_LEVEL or 70)
    if UnitLevel and UnitLevel("player") < maxLevel and not (IsXPUserDisabled and IsXPUserDisabled()) then
        d.xp, d.xpMax = UnitXP("player") or 0, UnitXPMax("player") or 1
        d.rest = GetXPExhaustion and GetXPExhaustion() or nil
    end
    if GetWatchedFactionInfo then
        local name, standing, lo, hi, value = GetWatchedFactionInfo()
        if name then d.rep, d.standing, d.repMin, d.repMax, d.repV = name, standing, lo, hi, value end
    end
    return d
end

function Bars:XPUpdate()
    local f = self.xp
    if not f or not f.look then return end
    local d = XPData()
    local any = false
    if d.xp then
        any = true
        f.main:SetColor(XP_C[1], XP_C[2], XP_C[3])
        f.main:SetValue(d.xp / math.max(1, d.xpMax))
        if d.rest and d.rest > 0 then
            f.main:SetEnd(math.min(1 - d.xp / math.max(1, d.xpMax), d.rest / math.max(1, d.xpMax)), REST_C[1], REST_C[2], REST_C[3], 0.45)
            -- (the rested stretch sits right after the fill: SetEnd draws from the bar's end, so turn it round)
            if f.main.endPart then
                local w = f.main.w or 0
                f.main.endPart:ClearAllPoints()
                f.main.endPart:SetPoint("TOPLEFT", f.main.f, "TOPLEFT", w * d.xp / math.max(1, d.xpMax), 0)
                f.main.endPart:SetPoint("BOTTOMLEFT", f.main.f, "BOTTOMLEFT", w * d.xp / math.max(1, d.xpMax), 0)
            end
        else
            f.main:SetEnd(nil)
        end
        f.text:SetText(("XP %s / %s  (%d%%)%s"):format(BreakUpLargeNumbers and BreakUpLargeNumbers(d.xp) or d.xp,
            BreakUpLargeNumbers and BreakUpLargeNumbers(d.xpMax) or d.xpMax, math.floor(d.xp / math.max(1, d.xpMax) * 100),
            (d.rest and d.rest > 0) and ("  \194\183  rested " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(d.rest) or d.rest)) or ""))
    end
    local repBar = d.xp and f.rep or f.main
    if d.rep then
        any = true
        local c = FACTION_BAR_COLORS and FACTION_BAR_COLORS[d.standing] or { r = 0, g = 0.6, b = 0.1 }
        repBar:SetColor(c.r, c.g, c.b)
        local span = math.max(1, (d.repMax or 1) - (d.repMin or 0))
        repBar:SetValue(((d.repV or 0) - (d.repMin or 0)) / span)
        if repBar == f.main then
            f.main:SetEnd(nil)
            f.text:SetText(("%s  %s / %s"):format(d.rep, (d.repV or 0) - (d.repMin or 0), span))
        end
    end
    f.rep.f:SetShown(d.xp ~= nil and d.rep ~= nil)
    f:SetShown(any)
end

function Bars:XP()
    local L = Look()
    if not L:Opt("bars", "xp", true) then
        if self.xp then self.xp:Hide() end
        return
    end
    local look = L:For("bars")
    if not self.xp then
        for _, name in ipairs(XP_BLIZZ) do
            local b = _G[name]
            if b then L:Retire(b) end
            if ns.Layout and ns.Layout.Unregister then ns.Layout:Unregister("blizz:" .. name) end
        end
        local f = CreateFrame("Frame", "DisasterZoneXPBar", UIParent)
        f:SetFrameStrata("LOW")
        f.panel = L:Panel(f)
        f.main = L:Bar(f); f.main.fixedW = true
        f.rep = L:Bar(f); f.rep.fixedW = true
        f.text = L:Text(f, "small", "TEXT", { justify = "CENTER" })
        f.text:SetPoint("BOTTOM", f, "TOP", 0, 3)
        f.text:Hide()
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self) self.text:Show() end)
        f:SetScript("OnLeave", function(self) self.text:Hide() end)
        for _, e in ipairs({ "PLAYER_XP_UPDATE", "UPDATE_EXHAUSTION", "PLAYER_LEVEL_UP", "UPDATE_FACTION",
                             "PLAYER_ENTERING_WORLD", "PLAYER_UPDATE_RESTING" }) do
            pcall(f.RegisterEvent, f, e)
        end
        f:SetScript("OnEvent", function() Bars:XPUpdate() end)
        self.xp = f
        if ns.Layout then
            ns.Layout:Register("bars.xp", { name = "Experience bar", group = "Game frames", order = 12, noHide = true,
                default = { "BOTTOM", 0, 4 }, frame = function() return Bars.xp end,
                stretch = { x = { 200, 1800 }, apply = function() Bars:XP() end },
                mine = function() return Bars.xp and Bars.xp:IsShown() or false end })
            ns.Layout:Place("bars.xp")
        end
    end
    local f = self.xp
    f.look = look
    local k = look.key
    local bar = _G.MainActionBar
    local w = (bar and bar:GetWidth() and bar:GetWidth() > 100) and bar:GetWidth() or 520
    w = (ns.Layout and ns.Layout:Size("bars.xp")) or w                     -- (stretched in Edit layout)
    local h = (k == "slate") and 3 or ((k == "halo") and 8 or 9)
    f:SetSize(w, h * 2 + 6)
    f.panel:Apply((k ~= "halo" and k ~= "slate") and look or nil)
    f.main:Apply(look, nil, h)
    f.main.f:ClearAllPoints()
    f.main.f:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
    f.main:SetWidthNow(w - 4)
    f.rep:Apply(look, nil, math.max(2, h - 3))
    f.rep.f:ClearAllPoints()
    f.rep.f:SetPoint("TOPLEFT", f.main.f, "BOTTOMLEFT", 0, -2)
    f.rep:SetWidthNow(w - 4)
    self:XPUpdate()
end

function Bars:OnLogin()
    local L = Look()
    L:SetApplied("bars", L:Key("bars"))
    self:Restyle()
    if ActionButton_UpdateRangeIndicator then
        hooksecurefunc("ActionButton_UpdateRangeIndicator", function(b) if skinned[b] then Bars:Range(b) end end)
    end
    ns:On("UI_LOOK_CHANGED", function(part)
        if part ~= "bars" then return end
        if Look():IsOn("bars") then Bars:Restyle() else Bars:Off() end
    end)
end

-- Back to the game's look without a reload: the art shown again, our parts hidden.
function Bars:Off()
    for b, s in pairs(skinned) do
        s.look = nil
        if s.round then
            s.round = false
            if s.mask and s.maskOn and s.icon then pcall(s.icon.RemoveMaskTexture, s.icon, s.mask); s.maskOn = false end
        end
        s.ring:Hide(); s.ringIn:Hide(); s.edge:Paint(nil); s.edge2:Paint(nil); s.sheen:Hide()
        if b.NormalTexture then b.NormalTexture:SetAlpha(1) end
        if b.SlotBackground then b.SlotBackground:SetAlpha(0.4) end
        if b.Border then b.Border:SetAlpha(1) end
        if b.HotKey then b.HotKey:SetAlpha(1) end
        if b.Name then b.Name:SetAlpha(1) end
        local icon = b.icon
        if icon then
            icon:SetTexCoord(0, 1, 0, 1)
            icon:ClearAllPoints()
            icon:SetAllPoints(b)
            if b.IconMask then
                pcall(b.IconMask.SetAtlas, b.IconMask, "UI-HUD-ActionBar-IconFrame-Mask")
                if s.masked == false then pcall(icon.AddMaskTexture, icon, b.IconMask) end
                s.masked = nil
            end
        end
    end
    for _, p in pairs(plates) do p:Hide() end
    for b, t in pairs(tiles) do
        t.look, t.shown = nil, nil
        t.f:Hide()
        for _, r in ipairs({ b:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" then r:SetAlpha(1) end
        end
        local port = _G.MicroButtonPortrait
        if port and port.GetParent and port:GetParent() == b then port:SetAlpha(1) end
    end
    if Bars.xp then Bars.xp:Hide() end
    for _, name in ipairs(ART) do
        local t = _G[name]
        if t and t.SetAlpha then t:SetAlpha(1) end
    end
    local mab = _G.MainActionBar
    if mab and mab.EndCaps then mab.EndCaps:SetAlpha(1) end
end

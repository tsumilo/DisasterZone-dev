if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/Themes.lua", ...) then return end -- DisasterZone UI/Comp/Themes.lua
-- theme registry and theme tile picker (meters, class bars) (refactor phase 2).
local addonName, ns = ...

-- ns.Themes: one registry for the looks that come as a set of named themes (the meter panels' meters.theme, the class
-- tool bars' classbar.theme). A kind is a list of theme tables ({ key, name, tip, ... }: the rest is the kind's own),
-- a default key and the setting that holds the chosen key. A hovered tile previews a theme without saving it; the
-- kind's onPreview repaints what wears it.
--   ns.Themes:Define(kind, list, defaultKey, opts)   opts { setting = "meters.theme", onPreview = function(key) }
--   ns.Themes:Get(kind, key)        the theme by key (the default's for an unknown key)
--   ns.Themes:Saved(kind)           the saved key (the default when none)
--   ns.Themes:Current(kind)         the theme in use: the previewed one, else the saved one
--   ns.Themes:SetPreview(kind, key) preview a theme (nil: back to the saved one)
--   ns.Themes:Preview(kind)         the previewed key or nil
--   ns.Themes:SettingsRow(S, sec, kind, label, desc, opts)   the picker as a Settings row
-- UI:CreateThemeTiles(parent, kind, opts): the picker, a tile per theme (below).
local Themes = { kinds = {} }
ns.Themes = Themes

local C = ns.Style.C
local GOLD = C.GOLD
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Registers a kind; returns its record { list, byKey, default, setting, onPreview, preview }.
function Themes:Define(kind, list, defaultKey, opts)
    opts = opts or {}
    local k = self.kinds[kind] or { byKey = {} }
    for key in pairs(k.byKey) do k.byKey[key] = nil end
    for _, t in ipairs(list) do k.byKey[t.key] = t end
    k.list, k.default = list, defaultKey
    k.setting, k.onPreview = opts.setting, opts.onPreview
    self.kinds[kind] = k
    return k
end

function Themes:Kind(kind)
    return self.kinds[kind]
end

function Themes:Get(kind, key)
    local k = self.kinds[kind]
    if not k then return nil end
    return k.byKey[key] or k.byKey[k.default]
end

function Themes:Saved(kind)
    local k = self.kinds[kind]
    if not k then return nil end
    local v = k.setting and ns.DB and ns.DB:GetSetting(k.setting)
    if v == nil or v == false then return k.default end
    return v
end

function Themes:Current(kind)
    local k = self.kinds[kind]
    if not k then return nil end
    return self:Get(kind, k.preview or self:Saved(kind))
end

function Themes:Preview(kind)
    local k = self.kinds[kind]
    return k and k.preview
end

-- Previews a theme (nil: none). quiet: only drops it, no repaint (a pick that saves follows).
function Themes:SetPreview(kind, key, quiet)
    local k = self.kinds[kind]
    if not k or k.preview == key then return end
    k.preview = key
    if not quiet and k.onPreview then k.onPreview(key) end
end

---------------------------------------------------------------------------
-- The picker: a row of tiles, one per theme. A tile: a dark ground with a 1 px edge (gold on the saved theme), the
-- theme's name at its foot and tile.preview, a frame the kind's paint draws a little sample in. Pointing at a tile
-- previews the theme (and shows its tip); a click saves it.
--   opts { tileW, tileH, gap, paint = function(tile, theme) (on every Refresh), onPick = function(key) (after the
--          save), hint = the tooltip's last line, clip = clip the tile's children, band = a dark band under the name,
--          nameY = the name's offset from the bottom (5), previewAt = { x, y } (the preview's top left in the tile;
--          else paint places it) }
-- Returns the strip: strip.tiles (each with .key, .theme, .preview, .name, .bg, .hl), strip:Refresh().
---------------------------------------------------------------------------
local function Tex(parent, layer, sub, r, g, b, a)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(WHITE)
    t:SetVertexColor(r, g, b, a)
    return t
end

local function CreateThemeTiles(UI, parent, kind, opts)
    opts = opts or {}
    local k = Themes.kinds[kind]
    local W, H, G = opts.tileW or 84, opts.tileH or 74, opts.gap or 6
    local strip = CreateFrame("Frame", nil, parent)
    strip:SetHeight(H)
    strip.tiles = {}
    strip.kind = kind
    for i, t in ipairs(k and k.list or {}) do
        local tile = CreateFrame("Button", nil, strip)
        tile:SetSize(W, H)
        tile:SetPoint("TOPLEFT", strip, "TOPLEFT", (i - 1) * (W + G), 0)
        if opts.clip and tile.SetClipsChildren then tile:SetClipsChildren(true) end
        tile.bg = Tex(tile, "BACKGROUND", -8, 0.05, 0.05, 0.063, 1)
        tile.bg:SetAllPoints()
        UI:AddEdges(tile)
        UI:SetEdgeColor(tile, 0.17, 0.17, 0.2, 1)
        tile.hl = Tex(tile, "HIGHLIGHT", 0, C.QUIET[1], C.QUIET[2], C.QUIET[3], C.QUIET[4])
        tile.hl:SetAllPoints()
        if opts.band then
            tile.band = Tex(tile, "OVERLAY", 0, 0.05, 0.05, 0.063, 1)
            tile.band:SetPoint("BOTTOMLEFT", 1, 1)
            tile.band:SetPoint("BOTTOMRIGHT", -1, 1)
            tile.band:SetHeight(17)
        end
        tile.name = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tile.name:SetPoint("BOTTOM", tile, "BOTTOM", 0, opts.nameY or 5)
        tile.name:SetText(t.name)
        tile.preview = CreateFrame("Frame", nil, tile)
        if opts.previewAt then
            tile.preview:SetPoint("TOPLEFT", tile, "TOPLEFT", opts.previewAt[1], opts.previewAt[2])
        end
        tile.key = t.key
        tile.theme = t
        tile:SetScript("OnClick", function()
            Themes:SetPreview(kind, nil, true)
            if k.setting and ns.DB then ns.DB:SetSetting(k.setting, t.key) end
            strip:Refresh()
            if opts.onPick then opts.onPick(t.key) end
        end)
        tile:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(t.name)
            GameTooltip:AddLine(t.tip, 0.85, 0.85, 0.85, true)
            if opts.hint then GameTooltip:AddLine(opts.hint, 0.6, 0.6, 0.6, true) end
            GameTooltip:Show()
            Themes:SetPreview(kind, t.key)
        end)
        tile:SetScript("OnLeave", function()
            GameTooltip:Hide()
            Themes:SetPreview(kind, nil)
        end)
        strip.tiles[i] = tile
    end
    function strip:Refresh()
        local saved = Themes:Get(kind, Themes:Saved(kind))
        local cur = saved and saved.key
        for _, tile in ipairs(self.tiles) do
            if opts.paint then opts.paint(tile, tile.theme) end
            local on = tile.key == cur
            UI:SetEdgeColor(tile, on and GOLD[1] or 0.17, on and GOLD[2] or 0.17, on and GOLD[3] or 0.2, 1)
            tile.name:SetTextColor(on and GOLD[1] or 0.85, on and GOLD[2] or 0.82, on and GOLD[3] or 0.75)
        end
    end
    strip:Refresh()
    return strip
end

-- The picker as a Settings row: label + desc, the tiles under it and a rule below like every row's. S = the Settings
-- UI, sec = its section (sec.y moves down past the tiles). Returns strip, row.
function Themes:SettingsRow(S, sec, kind, label, desc, opts)
    local row = S:Row(sec, label, desc)
    row.line:Hide()
    local H = (opts and opts.tileH) or 74
    local strip = ns.UI:CreateThemeTiles(sec, kind, opts)
    strip:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y + 4)
    strip:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y + 4)
    strip:SetHeight(H + 14)
    S.refreshers[#S.refreshers + 1] = strip
    sec.y = sec.y - (H + 14)
    local line = strip:CreateTexture(nil, "BORDER")
    line:SetColorTexture(C.HAIRLINE[1], C.HAIRLINE[2], C.HAIRLINE[3], 0.06)    -- (a shade under the hairline: as before)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    sec.rows[#sec.rows + 1] = { line = line }
    return strip, row
end

function ns.UI:CreateThemeTiles(parent, kind, opts)
    return CreateThemeTiles(self, parent, kind, opts)
end

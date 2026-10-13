if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterTheme.lua", ...) then return end -- DisasterZone: meter themes.
-- The look of the meter panels (UI/MeterPanels.lua): themes and the overrides on top of them. Mockup
-- dev/art/casc/meters_mockup/build_meter_themes.py (the user approved all six and every override, 2026-10-11).
-- The rule: one panel code; a theme only changes the face (the stack's fill and edge, the header, the fight line, the
-- rows: their height, icon, bar and text). Docking, tabs, the fight line, + / x and resizing never change.
-- The themes live in the shared theme registry (ns.Themes, kind "meters", UI/Comp/Themes.lua) next to the class tool
-- bars'; this file is that kind's painter: the one place the panels' faces are drawn. Its colours are the design
-- tokens (ns.Style) wherever a theme uses one (gold, the hairlines, hovers and quiet lifts); the rest are the themes'
-- own face colours (data). Text sizes are on the type scale (D2: a theme's size is snapped by ns.Style:Size).
-- Themes (setting meters.theme; its own picker, apart from the class tool bars' classbar.theme):
--   flat    today's look: full-height class bars, a square spec icon
--   halo    round spec icons in a class ring, rounded bars with a soft fade; names and numbers padded inside the bar
--   sigil   framed square icons, solid bars with a lit top edge (like action buttons), uppercase headers
--   slate   no filled bars: names in class colour, a 2 px hairline shows the share
--   gilded  a gold-trimmed frame with corners, textured bars (the game's status bar), gold-rimmed icons
--   pips    dense 13 px rows, rank numbers, no icons, per second only in the header
--   classic the game's own (UI/Look.lua's Classic): the tooltip's edge round the stack, the game's status bar texture
--           in class colour, the round class icons, your row in the quest log's gold
-- Overrides (Settings > Meters > Look): meters.barColor (class / role / one), meters.icons (theme / spec / class /
-- none), meters.rowSize (theme / compact / roomy), meters.numbers (short 380.1k / full 380,112 / round 380k),
-- meters.bg (theme or an opacity). No new art: the round parts use the game's portrait disc.
local addonName, ns = ...

local MT = ns:NewModule("MeterTheme")
local UI = ns.UI
local S = ns.Style
local C = S.C
local K = ns.MeterWindow.K

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local WHITE, DISC, BAR = K.WHITE, K.DISC, K.BAR
local FRIZ, NARROW = K.FRIZ, K.NARROW
local GOLD = C.GOLD
local NONE = { 1, 1, 1, 0 }               -- (a ground a theme leaves bare)

-- head / fl / row / gap / pad: heights and spacing; icon: square | round | framed | small | none; bar: flat | pill |
-- lit | hair | gilt; bg: the stack's fill (rgb + alpha); edge: its 1 px edge while locked; headBg: { bottom, top }
-- (a gradient) or one colour; headLine: a line under the header; title: font size and case; nameSize / value / sub:
-- text sizes on the type scale (nameFont NARROW for the dense theme); fillA: the bar's opacity; trackInset: a threat
-- bar's top/bottom inset; rank: list numbers; rate: the per-second column.
MT.THEMES = {
    { key = "flat", name = "Flat", tip = "Today's look: full-height class bars and a square spec icon.",
      head = 24, fl = 18, row = 19, gap = 1, pad = 3, icon = "square", bar = "flat",
      bg = { 0.039, 0.039, 0.051, 0.66 }, edge = NONE, headBg = C.QUIET, flBg = 0.28,
      title = 12, nameSize = 12, value = 13, sub = 12, fillA = 0.74, trackInset = 4, rate = true },
    { key = "halo", name = "Halo", tip = "Round spec icons in a class ring, rounded bars with a soft fade.",
      head = 24, fl = 18, row = 18, gap = 3, pad = 5, icon = "round", bar = "pill",
      bg = { 0.031, 0.031, 0.043, 0.56 }, edge = NONE, headBg = NONE, flBg = 0.18,
      titleColor = { 0.96, 0.86, 0.56 }, title = 12, nameSize = 12, value = 13, sub = 11, fillA = 0.9, trackInset = 5,
      rate = true },
    { key = "sigil", name = "Sigil", tip = "Framed square icons and solid bars with a lit top edge, like action buttons.",
      head = 24, fl = 18, row = 19, gap = 2, pad = 4, icon = "framed", bar = "lit",
      bg = { 0.035, 0.035, 0.043, 0.82 }, edge = C.HAIRLINE,
      headBg = { C.SURFACE_WINDOW, { 0.145, 0.145, 0.17, 1 } }, headLine = { 0, 0, 0, 1 }, flBg = 0.45,
      upper = true, title = 10, nameSize = 12, value = 13, sub = 12, fillA = 1, trackInset = 4, rate = true },
    { key = "slate", name = "Slate", tip = "No filled bars: names in class colour and a thin line for the share. Calmest.",
      head = 24, fl = 18, row = 20, gap = 0, pad = 2, icon = "small", bar = "hair",
      bg = { 0.051, 0.051, 0.067, 0.78 }, edge = C.HAIRLINE, headBg = NONE,
      headLine = C.HOVER, flBg = 0.2, noHeadIcon = true, titleColor = { 0.91, 0.89, 0.82 },
      title = 12, nameSize = 12, value = 13, sub = 12, fillA = 1, trackInset = 0, nameClass = true, rate = true },
    { key = "gilded", name = "Gilded", tip = "A gold-trimmed frame, textured bars and gold-rimmed icons. Most 'WoW'.",
      head = 26, fl = 18, row = 19, gap = 2, pad = 5, icon = "framed", bar = "gilt", corners = true,
      bg = { 0.071, 0.055, 0.027, 0.88 }, edge = { 0.43, 0.33, 0.13, 1 },
      headBg = { { 0.106, 0.078, 0.031, 1 }, { 0.231, 0.169, 0.059, 1 } }, headLine = { 0.54, 0.42, 0.15, 1 },
      flBg = 0.3, frameC = { 0.66, 0.51, 0.17 }, titleColor = { 1, 0.84, 0.42 }, title = 13, nameSize = 12, value = 13,
      sub = 12, fillA = 1, trackInset = 3, rate = true },
    { key = "pips", name = "Pips", tip = "Dense: small rows, rank numbers, no icons. For a crowded screen.",
      head = 18, fl = 15, row = 13, gap = 1, pad = 2, icon = "none", bar = "flat",
      bg = { 0, 0, 0, 0.5 }, edge = NONE, headBg = C.QUIET, flBg = 0.25,
      title = 10, nameSize = 10, nameFont = NARROW, value = 11, sub = 10, fillA = 0.55, trackInset = 3, rank = true,
      rate = false, small = true },
    { key = "classic", name = "Classic", tip = "The game's own: the tooltip's edge, the status bar texture in class colour, round class icons.",
      head = 24, fl = 18, row = 17, gap = 1, pad = 5, icon = "circle", bar = "game", game = true,
      bg = { 0.035, 0.035, 0.075, 0.9 }, edge = NONE, headBg = NONE, headLine = { 0.36, 0.36, 0.4, 0.5 }, flBg = 0.3,
      frameC = { 0.36, 0.36, 0.4 }, titleColor = { 1, 0.82, 0 }, title = 12, nameSize = 12, value = 13, sub = 12,
      fillA = 1, trackInset = 3, rate = true },
}
MT.DEFAULT = "flat"
-- (one registry with the class tool bars' themes: UI/Comp/Themes.lua; a hovered tile previews on the panels)
MT.BY_KEY = ns.Themes:Define("meters", MT.THEMES, MT.DEFAULT, { setting = "meters.theme", onPreview = function()
    if ns.MeterPanels and ns.MeterPanels.Restyle then ns.MeterPanels:Restyle() end
end }).byKey

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end

-- The theme in use (a hovered tile in Settings previews another one).
function MT:Theme()
    return ns.Themes:Current("meters")
end

function MT:SetPreview(key)
    ns.Themes:SetPreview("meters", key)
end

-- The sizes the panel code lays out with (the theme's, the row override on top). A key that changes when any of it
-- does, so rows made earlier know to restyle. t: another theme's (a tile's sample), else the one in use.
function MT:Metrics(t)
    t = t or self:Theme()
    local size = Setting("rowSize", "theme")
    local row = t.row + ((size == "compact") and -3 or (size == "roomy") and 3 or 0)
    row = max(11, row)
    local icon = Setting("icons", "theme")
    local kind = t.icon
    if icon == "none" then kind = "none"
    elseif (icon == "spec" or icon == "class") and kind == "none" then kind = "square"
    elseif icon == "spec" and kind == "circle" then kind = "square" end
    local m = { t = t, head = t.head, fl = t.fl, row = row, gap = t.gap, pad = t.pad, icon = kind, iconSrc = icon,
                bar = t.bar }
    if kind == "square" or kind == "circle" then m.iconW = row + 1
    elseif kind == "round" then m.iconW = row + 2
    elseif kind == "framed" then m.iconW = row + 2
    elseif kind == "small" then m.iconW = min(row, 16) + 4
    else m.iconW = t.rank and 15 or 3 end
    m.barL = m.iconW + ((kind == "round") and 2 or 0) + ((kind == "circle") and 1 or 0)
    if t.bar == "hair" then m.barL = m.iconW + 2 end
    if kind == "none" then m.barL = 0 end
    -- room the bar keeps for its ends: a pill's two round caps, an edged bar's two edge pixels
    m.barRes = (t.bar == "pill") and row or ((t.bar == "lit" or t.bar == "gilt") and 2 or 0)
    m.nameL = (t.bar == "pill") and (m.barL + 9) or (kind == "none" and m.iconW + 2 or m.barL + 5)
    if t.bar == "hair" then m.nameL = m.iconW + 2 end
    m.valR = (t.bar == "pill") and 10 or ((t.bar == "hair") and 2 or 6)
    m.nameW = t.small and 80 or 96
    m.key = strformat("%s:%d:%s:%s:%s:%s", t.key, row, kind, icon, Setting("barColor", "class"), tostring(Setting("bg", "theme")))
    return m
end

---------------------------------------------------------------------------
-- Numbers and colours
---------------------------------------------------------------------------

-- An amount in the chosen format: short 380.1k / 5.03M, full 380,112, round 380k / 5.0M.
function MT:Num(v)
    v = tonumber(v) or 0
    local f = Setting("numbers", "short")
    if f == "full" then return K.Int(v) end
    if f == "round" then
        if v >= 1e6 then return strformat("%.1fM", v / 1e6) end
        if v >= 1e3 then return strformat("%dk", floor(v / 1e3 + 0.5)) end
        return K.Int(v)
    end
    return K.Fmt(v)
end

-- Roles by spec label (Core/Meter.lua's labels, ns.SPECS' roles): tank, healer, else damage.
local ROLE_C = { tank = { 0.33, 0.58, 0.9 }, heal = { 0.3, 0.78, 0.45 }, dps = { 0.85, 0.36, 0.3 } }
local ONE_C = { 0.6, 0.65, 0.74 }
function MT:RoleOf(cls, spec)
    local role = cls and spec and ns.GetSpecRole and ns.GetSpecRole(cls, spec)
    if role == "tank" then return "tank" end
    if role == "healer" then return "heal" end
    return "dps"
end

-- A row's bar colour: the class's, the role's or one colour for all.
function MT:BarColor(cls, spec)
    local how = Setting("barColor", "class")
    if how == "role" then local c = ROLE_C[self:RoleOf(cls, spec)]; return c[1], c[2], c[3] end
    if how == "one" then return ONE_C[1], ONE_C[2], ONE_C[3] end
    return K.ClassColor(cls)
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------

-- (a theme part: a texture made once, coloured by the theme each time it is skinned)
local function Part(parent, layer, sub, path)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(path or WHITE)
    return t
end

-- (a theme colour on a part; a = an alpha over the colour's own)
local function Paint(t, c, a)
    t:SetTexture(WHITE)
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

-- A meter text in a theme's size (snapped to the type scale) and font, with its halo copies (MeterPanels' Halo).
local function FontAll(fs, font, size)
    size = S:Size(size)
    fs:SetFont(font, size, "")
    if fs.halo then for _, h in ipairs(fs.halo) do h:SetFont(font, size, "") end end
end

-- The face of a stack (MeterPanels' NewStack): a black outer pixel, the fill and the 1 px edge the themes colour
-- (f.outer, f.fill, f:SetEdge(r, g, b, a)), made from the shared primitives.
function MT:NewStackFace(f)
    f.outer = UI:Fill(f, { 0, 0, 0, 0.9 }, "BACKGROUND", -8)
    f.outer:ClearAllPoints()
    f.outer:SetPoint("TOPLEFT", -1, 1)
    f.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    f.fill = Part(f, "BACKGROUND", -7)                  -- (white: the theme tints it with SetVertexColor)
    f.fill:SetAllPoints()
    UI:AddEdges(f, "BORDER")
    UI:SetEdgeColor(f, S:Color("HAIRLINE"))
    function f:SetEdge(r, g, b, a) UI:SetEdgeColor(self, r, g, b, a) end
end

-- The stack: fill, edge, Gilded's corners.
function MT:SkinStack(f, m, locked)
    local t = m.t
    local a = t.bg[4]
    local o = Setting("bg", "theme")
    if type(o) == "number" then a = o / 100 end
    f.fill:SetVertexColor(t.bg[1], t.bg[2], t.bg[3], a)
    f.outer:SetAlpha(min(1, a + 0.25))
    -- (Gilded: the looks' worked gold moulding, filigree corners and grain, UI/Look.lua)
    if t.corners and not f.gilt and ns.Look and ns.Look.Gilt then f.gilt = ns.Look:Gilt(f) end
    if f.gilt then f.gilt:Show(t.corners and true or false) end
    -- (Classic: the game's tooltip edge round the stack, no black outer pixel)
    if t.game and not f.e9 and ns.Look and ns.Look.Edge9 then f.e9 = ns.Look:Edge9(f, "tip", "BORDER", 6) end
    if f.e9 then f.e9:Show(t.game and true or false) end
    if t.game then f.outer:SetAlpha(0) end
    MT:StackEdge(f, m, locked)
end

-- The stack's edge at rest: the theme's while locked, a gold one while the panels can be moved.
function MT:StackEdge(f, m, locked)
    local e = (m or self:Metrics()).t.edge
    if locked then f:SetEdge(e[1], e[2], e[3], e[4]) else
        local r, g, b = S:Color("GOLD")
        f:SetEdge(r, g, b, 0.45)
    end
end

-- A panel: the header's ground and line, the title's look, the fight line's ground.
function MT:SkinPanel(pf, m)
    local t = m.t
    local head = pf.head
    head:SetHeight(m.head)
    if type(t.headBg[1]) == "table" then
        UI:Gradient(head.bg, "VERTICAL", t.headBg[1], t.headBg[2])
    else
        Paint(head.bg, t.headBg)
    end
    if not head.line then
        head.line = UI:Rule(head, { bottom = 0, layer = "BORDER", sublevel = 2 })
    end
    if t.headLine then Paint(head.line, t.headLine); head.line:Show() else head.line:Hide() end
    local tc = t.titleColor or GOLD
    pf.mode.text:SetFont(FRIZ, S:Size(t.title), "")
    pf.mode.text:SetTextColor(tc[1], tc[2], tc[3])
    pf.mode.icon:SetShown(not t.noHeadIcon)
    pf.mode.icon:SetSize(t.small and 12 or 14, t.small and 12 or 14)
    pf.mode.text:ClearAllPoints()
    if t.noHeadIcon then pf.mode.text:SetPoint("LEFT", pf.mode, "LEFT", 5, 0)
    else pf.mode.text:SetPoint("LEFT", pf.mode.icon, "RIGHT", 6, 0) end
    UI:SetTextStyle(pf.totV, t.small and "body" or "title", "TEXT", nil, NARROW)
    UI:SetTextStyle(pf.tot, t.small and "small" or "emph", "SUB", nil, NARROW)
    pf.fl:SetHeight(m.fl)
    pf.fl.bg:SetVertexColor(0, 0, 0, t.flBg)
    pf.fl.name:SetFont(FRIZ, S:Size(t.small and "small" or "body"), "")
    pf.fl.meta:SetFont(NARROW, S:Size(t.small and "small" or "emph"), "")
    for _, a in ipairs({ pf.fl.prev, pf.fl.next }) do a:SetHeight(m.fl) end
    if t.frameC then pf.sep:SetVertexColor(t.frameC[1], t.frameC[2], t.frameC[3], 0.6)
    else pf.sep:SetVertexColor(S:Color("HAIRLINE")) end
    pf.styleKey = m.key
end

-- The label as the theme writes it (Sigil: capitals).
function MT:Label(text)
    if self:Theme().upper and text then return text:upper() end
    return text
end

-- Theme-only parts of a row (made once, shown by the theme that needs them).
local function Parts(row)
    if row.capL then return end
    row.capL = Part(row, "BORDER", 1, DISC)
    row.capL:SetTexCoord(0, 0.5, 0, 1)
    row.capR = Part(row, "BORDER", 1, DISC)
    row.capR:SetTexCoord(0.5, 1, 0, 1)
    row.tcapL = Part(row, "BACKGROUND", 1, DISC)
    row.tcapL:SetTexCoord(0, 0.5, 0, 1)
    row.tcapR = Part(row, "BACKGROUND", 1, DISC)
    row.tcapR:SetTexCoord(0.5, 1, 0, 1)
    row.back = Part(row, "BACKGROUND", -2)
    row.lit = Part(row, "ARTWORK", 2)
    row.lit:SetHeight(1)
    row.shade = Part(row, "ARTWORK", 1)
    row.ring = Part(row, "BACKGROUND", 3, DISC)
    row.ringIn = Part(row, "BACKGROUND", 4, DISC)
    row.frame = Part(row, "BACKGROUND", 3)
    row.sepLine = Part(row, "BORDER", 3)
    row.sepLine:SetHeight(1)
    row.meBg = Part(row, "BACKGROUND", 2)
end
MT.Parts = Parts

local function HideAll(...)
    for i = 1, select("#", ...) do local x = select(i, ...); if x then x:Hide() end end
end

-- A row's icon, by the icon setting: spec (else class), class, or none.
function MT:SetIcon(row, cls, spec, m)
    local tex = row.icon
    if m.icon == "none" then tex:Hide() return end
    local path = (m.iconSrc ~= "class") and K.SpecIcon(cls, spec) or nil
    local key = tostring(path) .. ":" .. tostring(cls) .. ":" .. m.icon
    tex:Show()
    if tex.iconKey == key then return end
    tex.iconKey = key
    if m.icon == "circle" then
        local c = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) else tex:SetTexCoord(0, 0.25, 0, 0.25) end
        return
    end
    if m.icon == "round" and path and SetPortraitToTexture then
        tex:SetTexCoord(0, 1, 0, 1)
        SetPortraitToTexture(tex, path)
        return
    end
    local c = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
    if path then
        tex:SetTexture(path)
        tex:SetTexCoord(0.12, 0.88, 0.12, 0.88)
    elseif c and m.icon == "round" then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    elseif c then
        local ix, iy = (c[2] - c[1]) * 0.08, (c[4] - c[3]) * 0.08
        tex:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
        tex:SetTexCoord(c[1] + ix, c[2] - ix, c[3] + iy, c[4] - iy)
    else
        tex:SetTexture(134400)
        tex:SetTexCoord(0.12, 0.88, 0.12, 0.88)
    end
end

-- A meter row (or a threat row: threat = true): heights, the icon's frame, the bar's parts and the text places.
-- The bar's width stays the panel code's (row.fill:SetWidth); everything else hangs on the fill.
function MT:SkinRow(row, m, threat)
    Parts(row)
    local t = m.t
    local h = m.row
    row:SetHeight(h)
    row.styleKey = m.key
    -- the icon
    local ic = row.icon
    ic:ClearAllPoints()
    row.iconLine:SetShown(m.icon == "square")
    HideAll(row.ring, row.ringIn, row.frame)
    if m.icon == "square" then
        ic:SetSize(h, h)
        ic:SetPoint("LEFT", row, "LEFT", 0, 0)
    elseif m.icon == "circle" then
        ic:SetSize(h - 1, h - 1)
        ic:SetPoint("LEFT", row, "LEFT", 0, 0)
    elseif m.icon == "round" then
        local s = h - 3
        ic:SetSize(s, s)
        ic:SetPoint("CENTER", row, "LEFT", (m.iconW - 2) / 2, 0)
        row.ring:ClearAllPoints()
        row.ring:SetSize(s + 4, s + 4)
        row.ring:SetPoint("CENTER", ic, "CENTER")
        row.ringIn:ClearAllPoints()
        row.ringIn:SetSize(s + 2, s + 2)
        row.ringIn:SetPoint("CENTER", ic, "CENTER")
        row.ringIn:SetVertexColor(0, 0, 0, 1)
        row.ring:Show(); row.ringIn:Show()
    elseif m.icon == "framed" then
        ic:SetSize(h - 4, h - 4)
        ic:SetPoint("LEFT", row, "LEFT", 2, 0)
        row.frame:ClearAllPoints()
        row.frame:SetPoint("TOPLEFT", ic, "TOPLEFT", -2, 2)
        row.frame:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 2, -2)
        row.frame:Show()
    elseif m.icon == "small" then
        local s = min(h, 16) - 2
        ic:SetSize(s, s)
        ic:SetPoint("LEFT", row, "LEFT", 1, 0)
    else
        ic:Hide()
    end
    -- text
    local nameFont = t.nameFont or FRIZ
    FontAll(row.name, nameFont, t.nameSize)
    FontAll(row.value, NARROW, t.value)
    if row.sub then FontAll(row.sub, NARROW, t.sub) end
    if not row.rank then
        row.rank = UI:Text(row, "small", "SUB", { font = NARROW, justify = "RIGHT", shadow = true })
    end
    UI:SetTextStyle(row.rank, t.small and "caps" or "body", "SUB", nil, NARROW)
    row.rank:ClearAllPoints()
    row.rank:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.rank:SetWidth(m.iconW - 3)
    row.rank:SetShown(t.rank and m.icon == "none")
    -- the bar
    local fill, bg = row.fill, row.bg
    HideAll(row.capL, row.capR, row.tcapL, row.tcapR, row.back, row.lit, row.shade, row.sepLine, row.meBg)
    fill:SetTexture((t.bar == "gilt" or t.bar == "game") and BAR or WHITE)
    if threat then
        local ins = t.trackInset
        row.trackTop, row.trackBot = -ins, ins
        if t.bar == "hair" then row.trackTop, row.trackBot = -(h - 4), 2 end
        if t.bar == "lit" then Paint(row.track, C.INSET, 1)
        elseif t.bar == "gilt" or t.bar == "game" then Paint(row.track, { 0, 0, 0, 0.4 })
        elseif t.bar == "hair" then Paint(row.track, C.HAIRLINE)
        else Paint(row.track, C.HOVER) end
        if t.bar == "lit" or t.bar == "gilt" then
            row.lit:ClearAllPoints()
            row.lit:SetPoint("TOPLEFT", fill, "TOPLEFT")
            row.lit:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
            row.lit:SetVertexColor(1, 1, 1, t.bar == "lit" and 0.35 or 0.12)
            row.lit:Show()
        end
        return
    end
    local L = m.barL
    fill:ClearAllPoints()
    bg:ClearAllPoints()
    bg:SetTexture(WHITE)
    if t.bar == "pill" then
        local r = h / 2
        fill:SetPoint("TOPLEFT", row, "TOPLEFT", L + r, 0)
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L + r, 0)
        row.capL:ClearAllPoints()
        row.capL:SetSize(r, h)
        row.capL:SetPoint("RIGHT", fill, "LEFT")
        row.capR:ClearAllPoints()
        row.capR:SetSize(r, h)
        row.capR:SetPoint("LEFT", fill, "RIGHT")
        row.capL:Show(); row.capR:Show()
        -- the track: the same pill, faint, the bar's whole length
        bg:SetPoint("TOPLEFT", row, "TOPLEFT", L + r, 0)
        bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -r, 0)
        bg:SetVertexColor(S:Color("QUIET"))
        row.tcapL:ClearAllPoints()
        row.tcapL:SetSize(r, h)
        row.tcapL:SetPoint("RIGHT", bg, "LEFT")
        row.tcapR:ClearAllPoints()
        row.tcapR:SetSize(r, h)
        row.tcapR:SetPoint("LEFT", bg, "RIGHT")
        row.tcapL:SetVertexColor(S:Color("QUIET"))
        row.tcapR:SetVertexColor(S:Color("QUIET"))
        row.tcapL:Show(); row.tcapR:Show()
    elseif t.bar == "lit" or t.bar == "gilt" then
        fill:SetPoint("TOPLEFT", row, "TOPLEFT", L + 1, -1)
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L + 1, 1)
        row.back:ClearAllPoints()
        row.back:SetPoint("TOPLEFT", row, "TOPLEFT", L, 0)
        row.back:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        row.back:SetVertexColor(0, 0, 0, 1)
        row.back:Show()
        bg:SetPoint("TOPLEFT", row, "TOPLEFT", L + 1, -1)
        bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
        if t.bar == "lit" then bg:SetVertexColor(S:Color("INSET")) else bg:SetVertexColor(0, 0, 0, 0.35) end
        row.lit:ClearAllPoints()
        row.lit:SetPoint("TOPLEFT", fill, "TOPLEFT")
        row.lit:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
        row.lit:SetVertexColor(1, 1, 1, t.bar == "lit" and 0.35 or 0.14)
        row.lit:Show()
        if t.bar == "lit" then
            row.shade:ClearAllPoints()
            row.shade:SetAllPoints(fill)
            UI:Gradient(row.shade, "VERTICAL", { 0, 0, 0, 0.32 }, { 1, 1, 1, 0.1 })
            row.shade:Show()
        end
    elseif t.bar == "game" then
        -- (Classic: the status bar texture as tall as the row, on a faint dark track)
        fill:SetPoint("TOPLEFT", row, "TOPLEFT", L, 0)
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 0)
        bg:SetPoint("TOPLEFT", row, "TOPLEFT", L, 0)
        bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        bg:SetVertexColor(0, 0, 0, 0.3)
    elseif t.bar == "hair" then
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 2)
        fill:SetHeight(2)
        bg:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 2)
        bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 2)
        bg:SetHeight(2)
        bg:SetVertexColor(S:Color("HAIRLINE"))
        row.sepLine:ClearAllPoints()
        row.sepLine:SetPoint("BOTTOMLEFT")
        row.sepLine:SetPoint("BOTTOMRIGHT")
        row.sepLine:SetVertexColor(S:Color("QUIET"))
        row.sepLine:Show()
    else
        fill:SetPoint("TOPLEFT", row, "TOPLEFT", L, 0)
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 0)
        bg:SetAllPoints()
        bg:SetVertexColor(S:Color("QUIET"))
    end
    if row.foot then row.foot:SetShown(t.bar == "flat") end
    if row.ext then
        row.ext:ClearAllPoints()
        local after = (t.bar == "pill") and row.capR or fill
        row.ext:SetPoint("TOPLEFT", after, "TOPRIGHT")
        row.ext:SetPoint("BOTTOMLEFT", after, "BOTTOMRIGHT")
        if t.bar == "hair" then row.ext:SetHeight(2) end
    end
end

-- A row's colours: the bar (class / role / one), Slate's names, my row's mark (the theme's way).
function MT:Paint(row, m, r, g, b, me)
    local t = m.t
    local a = t.fillA
    local fill = row.fill
    if t.bar == "pill" then
        local c1 = { r * 0.45, g * 0.45, b * 0.45, a }
        local c2 = { r * 0.92, g * 0.92, b * 0.92, a }
        UI:Gradient(fill, "HORIZONTAL", c1, c2)
        row.capL:SetVertexColor(c1[1], c1[2], c1[3], a)
        row.capR:SetVertexColor(c2[1], c2[2], c2[3], a)
    elseif t.bar == "gilt" or t.bar == "game" then
        fill:SetTexture(BAR)
        fill:SetVertexColor(r, g, b, a)
    else
        fill:SetTexture(WHITE)
        fill:SetVertexColor(r, g, b, a)
    end
    if row.ext then row.ext:SetVertexColor(r, g, b, 0.28) end
    if t.nameClass then row.name:SetTextColor(r, g, b) else row.name:SetTextColor(1, 1, 1) end
    self:Me(row, m, me)
end

-- My row: a gold left edge (flat, pips), a gold ring (halo), a gold bar edge (sigil, gilded), a soft gold wash (slate).
function MT:Me(row, m, me)
    local t = m.t
    me = me and true or false
    row.you:SetShown(me and (t.bar == "flat"))
    if row.ring and m.icon == "round" then
        if me then row.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1) else
            local r, g, b = K.ClassColor(row.cls)
            row.ring:SetVertexColor(r, g, b, 1)
        end
    end
    if row.frame and m.icon == "framed" then
        local fc = t.frameC
        if me then row.frame:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
        elseif fc then row.frame:SetVertexColor(fc[1], fc[2], fc[3], 1)
        else row.frame:SetVertexColor(0.42, 0.42, 0.45, 1) end
    end
    if row.back and (t.bar == "lit" or t.bar == "gilt") then
        if me then row.back:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1) else row.back:SetVertexColor(0, 0, 0, 1) end
    end
    if row.bg and t.bar == "pill" then              -- (threat rows have no pill track)
        local c = me and C.SELECT or C.QUIET          -- (mine: the shared picked wash)
        local a = me and 0.16 or c[4]
        row.bg:SetVertexColor(c[1], c[2], c[3], a)
        row.tcapL:SetVertexColor(c[1], c[2], c[3], a)
        row.tcapR:SetVertexColor(c[1], c[2], c[3], a)
    end
    if row.meBg and t.bar == "hair" then
        if me then
            row.meBg:ClearAllPoints()
            row.meBg:SetAllPoints()
            row.meBg:SetTexture(WHITE)
            if row.meBg.SetBlendMode then row.meBg:SetBlendMode("BLEND") end
            row.meBg:SetDrawLayer("BACKGROUND", 2)
            UI:Gradient(row.meBg, "HORIZONTAL", "SELECT", { GOLD[1], GOLD[2], GOLD[3], 0 })
            row.meBg:Show()
        else
            row.meBg:Hide()
        end
    elseif row.meBg and t.game then
        if me then
            row.meBg:ClearAllPoints()
            row.meBg:SetPoint("TOPLEFT", row, "TOPLEFT", m.barL, 1)
            row.meBg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, -1)
            row.meBg:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.meBg:SetTexCoord(0, 1, 0, 1)
            row.meBg:SetVertexColor(1, 1, 1, 0.9)
            row.meBg:SetDrawLayer("ARTWORK", 3)
            if row.meBg.SetBlendMode then row.meBg:SetBlendMode("ADD") end
            row.meBg:Show()
        else
            row.meBg:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Settings > Meters > Look: a tile per theme (a little panel drawn in it), hover previews it on the panels
---------------------------------------------------------------------------

local TILE_W, TILE_H = 84, 74
local PREVIEW = { { "Quentrell", "HUNTER", "Beast Mastery", 1 }, { "Tsumil", "WARRIOR", "Fury", 0.87, true },
                  { "Dreadhex", "WARLOCK", "Destruction", 0.74 } }

-- (the sample panel's row: the parts a meter row has, the theme skins them)
local function PreviewRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row.bg = Part(row, "BACKGROUND", 0)
    row.fill = Part(row, "BORDER", 0)
    row.you = UI:Fill(row, "GOLD", "OVERLAY", 0)
    row.you:ClearAllPoints()
    row.you:SetPoint("TOPLEFT")
    row.you:SetPoint("BOTTOMLEFT")
    row.you:SetWidth(2)
    row.icon = Part(row, "ARTWORK", 0, 134400)
    row.iconLine = UI:Fill(row, { 0, 0, 0, 0.85 }, "ARTWORK", 1)
    row.iconLine:ClearAllPoints()
    row.iconLine:SetPoint("TOPLEFT", row.icon, "TOPRIGHT")
    row.iconLine:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT")
    row.iconLine:SetWidth(1)
    row.name = UI:Text(row, "emph", { 1, 1, 1 }, { shadow = true })
    row.value = UI:Text(row, "title", { 1, 1, 1 }, { font = NARROW, shadow = true })
    return row
end

local function FillPreview(holder, t)
    local m = MT:Metrics(t)           -- (the overrides apply as on the panels)
    local W = 150
    holder:SetSize(W, 60)
    holder.bg = holder.bg or Part(holder, "BACKGROUND", -6)
    holder.bg:SetAllPoints()
    local a = t.bg[4]
    holder.bg:SetVertexColor(t.bg[1], t.bg[2], t.bg[3], max(0.6, a))
    holder.head = holder.head or Part(holder, "BACKGROUND", -5)
    holder.head:ClearAllPoints()
    holder.head:SetPoint("TOPLEFT")
    holder.head:SetPoint("TOPRIGHT")
    holder.head:SetHeight(m.head - 6)
    if type(t.headBg[1]) == "table" then UI:Gradient(holder.head, "VERTICAL", t.headBg[1], t.headBg[2])
    else Paint(holder.head, t.headBg) end
    holder.title = holder.title or UI:Text(holder, "small", "GOLD", { shadow = true })
    holder.title:ClearAllPoints()
    holder.title:SetPoint("LEFT", holder.head, "LEFT", 5, 0)
    UI:SetTextStyle(holder.title, "small", t.titleColor or "GOLD")
    holder.title:SetText(t.upper and "DAMAGE DONE" or "Damage done")
    holder.rows = holder.rows or {}
    local y = -(m.head - 6) - m.pad
    local inner = W - 2 * m.pad
    for i, p in ipairs(PREVIEW) do
        local row = holder.rows[i] or PreviewRow(holder)
        holder.rows[i] = row
        MT:SkinRow(row, m)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", holder, "TOPLEFT", m.pad, y)
        row:SetPoint("RIGHT", holder, "RIGHT", -m.pad, 0)
        row.cls = p[2]
        MT:SetIcon(row, p[2], p[3], m)
        row.name:SetText(p[1])
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", m.nameL, 0)
        row.value:SetText("")
        row.rank:SetText(tostring(i))
        local r, g, b = MT:BarColor(p[2], p[3])
        MT:Paint(row, m, r, g, b, p[5])
        row.fill:SetWidth(max(1, (inner - m.barL - m.barRes) * p[4]))
        y = y - m.row - m.gap
    end
    holder:SetHeight(-y + m.pad)
    holder:SetScale(min(1, (TILE_W - 8) / W))
end

-- The theme picker: a tile per theme (UI:CreateThemeTiles through the registry's Settings row). Returns the strip
-- (Refresh redraws the tiles).
function MT:SettingsTiles(SU, sec)
    local strip, row = ns.Themes:SettingsRow(SU, sec, "meters", "Theme",
        "How every meter panel looks. Point at a theme to try it on your panels.",
        { tileW = TILE_W, tileH = TILE_H, gap = 6, clip = true, band = true, nameY = 5, previewAt = { 4, -4 },
          hint = "Your panels show it while you point at it (turn on demo data to try it alone).",
          paint = function(tile, t) FillPreview(tile.preview, t) end })
    return strip, row
end

MT._FillPreview = FillPreview

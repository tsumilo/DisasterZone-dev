if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterTheme.lua", ...) then return end -- DisasterZone: meter themes.
-- The look of the meter panels (UI/MeterPanels.lua): themes and the overrides on top of them. Mockup
-- dev/art/casc/meters_mockup/build_meter_themes.py (the user approved all six and every override, 2026-10-11).
-- The rule: one panel code; a theme only changes the face (the stack's fill and edge, the header, the fight line, the
-- rows: their height, icon, bar and text). Docking, tabs, the fight line, + / x and resizing never change.
-- Themes (setting meters.theme; its own picker, apart from the class tool bars' classbar.theme):
--   flat    today's look: full-height class bars, a square spec icon
--   halo    round spec icons in a class ring, rounded bars with a soft fade; names and numbers padded inside the bar
--   sigil   framed square icons, solid bars with a lit top edge (like action buttons), uppercase headers
--   slate   no filled bars: names in class colour, a 2 px hairline shows the share
--   gilded  a gold-trimmed frame with corners, textured bars (the game's status bar), gold-rimmed icons
--   pips    dense 13 px rows, rank numbers, no icons, per second only in the header
-- Overrides (Settings > Meters > Look): meters.barColor (class / role / one), meters.icons (theme / spec / class /
-- none), meters.rowSize (theme / compact / roomy), meters.numbers (short 380.1k / full 380,112 / round 380k),
-- meters.bg (theme or an opacity). No new art: the round parts use the game's portrait disc.
local addonName, ns = ...

local MT = ns:NewModule("MeterTheme")

local floor, max, min = math.floor, math.max, math.min
local strformat = string.format

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local FRIZ = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local NARROW = "Fonts\\ARIALN.TTF"
local GOLD = { 1, 0.82, 0 }

-- head / fl / row / gap / pad: heights and spacing; icon: square | round | framed | small | none; bar: flat | pill |
-- lit | hair | gilt; bg: the stack's fill (rgb + alpha); edge: its 1 px edge while locked; headBg: { bottom, top }
-- (a gradient) or one colour; headLine: a line under the header; title: font size and case; nameSize / value / sub:
-- text sizes (nameFont NARROW for the dense theme); fillA: the bar's opacity; trackInset: a threat bar's top/bottom
-- inset; rank: list numbers; rate: the per-second column.
MT.THEMES = {
    { key = "flat", name = "Flat", tip = "Today's look: full-height class bars and a square spec icon.",
      head = 24, fl = 18, row = 19, gap = 1, pad = 3, icon = "square", bar = "flat",
      bg = { 0.039, 0.039, 0.051, 0.66 }, edge = { 1, 1, 1, 0 }, headBg = { 1, 1, 1, 0.035 }, flBg = 0.28,
      title = 12.5, nameSize = 12, value = 13.5, sub = 12, fillA = 0.74, trackInset = 4, rate = true },
    { key = "halo", name = "Halo", tip = "Round spec icons in a class ring, rounded bars with a soft fade.",
      head = 24, fl = 18, row = 18, gap = 3, pad = 5, icon = "round", bar = "pill",
      bg = { 0.031, 0.031, 0.043, 0.56 }, edge = { 1, 1, 1, 0 }, headBg = { 1, 1, 1, 0 }, flBg = 0.18,
      titleColor = { 0.96, 0.86, 0.56 }, title = 12.5, nameSize = 12, value = 13, sub = 11.5, fillA = 0.9, trackInset = 5,
      rate = true },
    { key = "sigil", name = "Sigil", tip = "Framed square icons and solid bars with a lit top edge, like action buttons.",
      head = 24, fl = 18, row = 19, gap = 2, pad = 4, icon = "framed", bar = "lit",
      bg = { 0.035, 0.035, 0.043, 0.82 }, edge = { 1, 1, 1, 0.07 },
      headBg = { { 0.078, 0.078, 0.09, 1 }, { 0.145, 0.145, 0.17, 1 } }, headLine = { 0, 0, 0, 1 }, flBg = 0.45,
      upper = true, title = 10.5, nameSize = 12, value = 13.5, sub = 12, fillA = 1, trackInset = 4, rate = true },
    { key = "slate", name = "Slate", tip = "No filled bars: names in class colour and a thin line for the share. Calmest.",
      head = 24, fl = 18, row = 20, gap = 0, pad = 2, icon = "small", bar = "hair",
      bg = { 0.051, 0.051, 0.067, 0.78 }, edge = { 1, 1, 1, 0.08 }, headBg = { 1, 1, 1, 0 },
      headLine = { 1, 1, 1, 0.06 }, flBg = 0.2, noHeadIcon = true, titleColor = { 0.91, 0.89, 0.82 },
      title = 12, nameSize = 12, value = 13, sub = 12, fillA = 1, trackInset = 0, nameClass = true, rate = true },
    { key = "gilded", name = "Gilded", tip = "A gold-trimmed frame, textured bars and gold-rimmed icons. Most 'WoW'.",
      head = 26, fl = 18, row = 19, gap = 2, pad = 5, icon = "framed", bar = "gilt", corners = true,
      bg = { 0.071, 0.055, 0.027, 0.88 }, edge = { 0.43, 0.33, 0.13, 1 },
      headBg = { { 0.106, 0.078, 0.031, 1 }, { 0.231, 0.169, 0.059, 1 } }, headLine = { 0.54, 0.42, 0.15, 1 },
      flBg = 0.3, frameC = { 0.66, 0.51, 0.17 }, titleColor = { 1, 0.84, 0.42 }, title = 13, nameSize = 12, value = 13.5,
      sub = 12, fillA = 1, trackInset = 3, rate = true },
    { key = "pips", name = "Pips", tip = "Dense: small rows, rank numbers, no icons. For a crowded screen.",
      head = 18, fl = 15, row = 13, gap = 1, pad = 2, icon = "none", bar = "flat",
      bg = { 0, 0, 0, 0.5 }, edge = { 1, 1, 1, 0 }, headBg = { 1, 1, 1, 0.03 }, flBg = 0.25,
      title = 10.5, nameSize = 10.5, nameFont = NARROW, value = 11, sub = 10, fillA = 0.55, trackInset = 3, rank = true,
      rate = false, small = true },
}
MT.BY_KEY = {}
for _, t in ipairs(MT.THEMES) do MT.BY_KEY[t.key] = t end
MT.DEFAULT = "flat"

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end

-- The theme in use (a hovered tile in Settings previews another one).
function MT:Theme()
    local key = self.preview or Setting("theme", MT.DEFAULT)
    return MT.BY_KEY[key] or MT.BY_KEY[MT.DEFAULT]
end

function MT:SetPreview(key)
    if self.preview == key then return end
    self.preview = key
    if ns.MeterPanels and ns.MeterPanels.Restyle then ns.MeterPanels:Restyle() end
end

-- The sizes the panel code lays out with (the theme's, the row override on top). A key that changes when any of it
-- does, so rows made earlier know to restyle.
function MT:Metrics()
    local t = self:Theme()
    local size = Setting("rowSize", "theme")
    local row = t.row + ((size == "compact") and -3 or (size == "roomy") and 3 or 0)
    row = max(11, row)
    local icon = Setting("icons", "theme")
    local kind = t.icon
    if icon == "none" then kind = "none"
    elseif (icon == "spec" or icon == "class") and kind == "none" then kind = "square" end
    local m = { t = t, head = t.head, fl = t.fl, row = row, gap = t.gap, pad = t.pad, icon = kind, iconSrc = icon,
                bar = t.bar }
    if kind == "square" then m.iconW = row + 1
    elseif kind == "round" then m.iconW = row + 2
    elseif kind == "framed" then m.iconW = row + 2
    elseif kind == "small" then m.iconW = min(row, 16) + 4
    else m.iconW = t.rank and 15 or 3 end
    m.barL = m.iconW + ((kind == "round") and 2 or 0)
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

local function Int(v)
    v = floor((tonumber(v) or 0) + 0.5)
    local s = tostring(math.abs(v))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return (v < 0 and "-" or "") .. out
end

-- An amount in the chosen format: short 380.1k / 5.03M, full 380,112, round 380k / 5.0M.
function MT:Num(v)
    v = tonumber(v) or 0
    local f = Setting("numbers", "short")
    if f == "full" then return Int(v) end
    if f == "round" then
        if v >= 1e6 then return strformat("%.1fM", v / 1e6) end
        if v >= 1e3 then return strformat("%dk", floor(v / 1e3 + 0.5)) end
        return Int(v)
    end
    if v >= 1e6 then return strformat("%.2fM", v / 1e6) end
    if v >= 1e4 then return strformat("%.1fk", v / 1e3) end
    return Int(v)
end

-- Roles by spec label (Core/Meter.lua's labels): tank, healer, else damage.
local TANK = { Protection = { WARRIOR = true, PALADIN = true }, ["Feral (Bear)"] = { DRUID = true } }
local HEAL = { Holy = { PALADIN = true, PRIEST = true }, Discipline = { PRIEST = true },
               Restoration = { SHAMAN = true, DRUID = true } }
local ROLE_C = { tank = { 0.33, 0.58, 0.9 }, heal = { 0.3, 0.78, 0.45 }, dps = { 0.85, 0.36, 0.3 } }
local ONE_C = { 0.6, 0.65, 0.74 }
function MT:RoleOf(cls, spec)
    if spec and TANK[spec] and TANK[spec][cls] then return "tank" end
    if spec and HEAL[spec] and HEAL[spec][cls] then return "heal" end
    return "dps"
end

-- A row's bar colour: the class's, the role's or one colour for all.
function MT:BarColor(cls, spec)
    local how = Setting("barColor", "class")
    if how == "role" then local c = ROLE_C[self:RoleOf(cls, spec)]; return c[1], c[2], c[3] end
    if how == "one" then return ONE_C[1], ONE_C[2], ONE_C[3] end
    local K = ns.MeterWindow.K
    return K.ClassColor(cls)
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------

local function Tex(parent, layer, sub, path)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(path or WHITE)
    return t
end

local function Grad(t, orient, c1, c2)
    ns.MeterWindow.K.Gradient(t, orient, c1, c2)
end

local function Color(t, c, a)
    t:SetTexture(WHITE)
    t:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
end

local function FontAll(fs, font, size)
    fs:SetFont(font, size, "")
    if fs.halo then for _, h in ipairs(fs.halo) do h:SetFont(font, size, "") end end
end

-- The stack: fill, edge, Gilded's corners.
function MT:SkinStack(f, m, locked)
    local t = m.t
    local a = t.bg[4]
    local o = Setting("bg", "theme")
    if type(o) == "number" then a = o / 100 end
    f.fill:SetVertexColor(t.bg[1], t.bg[2], t.bg[3], a)
    f.outer:SetAlpha(min(1, a + 0.25))
    if not f.corners then
        f.corners = {}
        for i, c in ipairs({ { "TOPLEFT", 1, -1 }, { "TOPRIGHT", -1, -1 }, { "BOTTOMLEFT", 1, 1 }, { "BOTTOMRIGHT", -1, 1 } }) do
            local h = Tex(f, "OVERLAY", 6)
            local v = Tex(f, "OVERLAY", 6)
            h:SetSize(9, 2)
            v:SetSize(2, 9)
            h:SetPoint(c[1], f, c[1], -2 * c[2], 2 * -c[3])
            v:SetPoint(c[1], f, c[1], -2 * c[2], 2 * -c[3])
            f.corners[i] = { h, v }
        end
    end
    for _, c in ipairs(f.corners) do
        for _, x in ipairs(c) do
            x:SetVertexColor(0.89, 0.73, 0.33, 1)
            x:SetShown(t.corners and true or false)
        end
    end
    if locked then f:SetEdge(t.edge[1], t.edge[2], t.edge[3], t.edge[4]) else f:SetEdge(1, 0.82, 0, 0.45) end
end

-- A panel: the header's ground and line, the title's look, the fight line's ground.
function MT:SkinPanel(pf, m)
    local t = m.t
    local head = pf.head
    head:SetHeight(m.head)
    if type(t.headBg[1]) == "table" then
        Grad(head.bg, "VERTICAL", t.headBg[1], t.headBg[2])
    else
        Color(head.bg, t.headBg)
    end
    if not head.line then
        head.line = Tex(head, "BORDER", 2)
        head.line:SetPoint("BOTTOMLEFT")
        head.line:SetPoint("BOTTOMRIGHT")
        head.line:SetHeight(1)
    end
    if t.headLine then Color(head.line, t.headLine); head.line:Show() else head.line:Hide() end
    local tc = t.titleColor or GOLD
    pf.mode.text:SetFont(FRIZ, t.title, "")
    pf.mode.text:SetTextColor(tc[1], tc[2], tc[3])
    pf.mode.icon:SetShown(not t.noHeadIcon)
    pf.mode.icon:SetSize(t.small and 12 or 14, t.small and 12 or 14)
    pf.mode.text:ClearAllPoints()
    if t.noHeadIcon then pf.mode.text:SetPoint("LEFT", pf.mode, "LEFT", 5, 0)
    else pf.mode.text:SetPoint("LEFT", pf.mode.icon, "RIGHT", 6, 0) end
    pf.totV:SetFont(NARROW, t.small and 11 or 13, "")
    pf.tot:SetFont(NARROW, t.small and 10 or 12, "")
    pf.fl:SetHeight(m.fl)
    pf.fl.bg:SetVertexColor(0, 0, 0, t.flBg)
    pf.fl.name:SetFont(FRIZ, t.small and 10 or 11.5, "")
    pf.fl.meta:SetFont(NARROW, t.small and 10.5 or 12, "")
    for _, a in ipairs({ pf.fl.prev, pf.fl.next }) do a:SetHeight(m.fl) end
    pf.sep:SetVertexColor(t.frameC and t.frameC[1] or 1, t.frameC and t.frameC[2] or 1, t.frameC and t.frameC[3] or 1,
        t.frameC and 0.6 or 0.08)
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
    row.capL = Tex(row, "BORDER", 1, DISC)
    row.capL:SetTexCoord(0, 0.5, 0, 1)
    row.capR = Tex(row, "BORDER", 1, DISC)
    row.capR:SetTexCoord(0.5, 1, 0, 1)
    row.tcapL = Tex(row, "BACKGROUND", 1, DISC)
    row.tcapL:SetTexCoord(0, 0.5, 0, 1)
    row.tcapR = Tex(row, "BACKGROUND", 1, DISC)
    row.tcapR:SetTexCoord(0.5, 1, 0, 1)
    row.back = Tex(row, "BACKGROUND", -2)
    row.lit = Tex(row, "ARTWORK", 2)
    row.lit:SetHeight(1)
    row.shade = Tex(row, "ARTWORK", 1)
    row.ring = Tex(row, "BACKGROUND", 3, DISC)
    row.ringIn = Tex(row, "BACKGROUND", 4, DISC)
    row.frame = Tex(row, "BACKGROUND", 3)
    row.sepLine = Tex(row, "BORDER", 3)
    row.sepLine:SetHeight(1)
    row.meBg = Tex(row, "BACKGROUND", 2)
end
MT.Parts = Parts

local function HideAll(...)
    for i = 1, select("#", ...) do local x = select(i, ...); if x then x:Hide() end end
end

-- A row's icon, by the icon setting: spec (else class), class, or none.
function MT:SetIcon(row, cls, spec, m)
    local tex = row.icon
    if m.icon == "none" then tex:Hide() return end
    local K = ns.MeterWindow.K
    local path = (m.iconSrc ~= "class") and K.SpecIcon(cls, spec) or nil
    local key = tostring(path) .. ":" .. tostring(cls) .. ":" .. m.icon
    tex:Show()
    if tex.iconKey == key then return end
    tex.iconKey = key
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

local function SetSize(fs, font, size)
    FontAll(fs, font, size)
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
    SetSize(row.name, nameFont, t.nameSize)
    SetSize(row.value, NARROW, t.value)
    if row.sub then SetSize(row.sub, NARROW, t.sub) end
    if not row.rank then
        row.rank = row:CreateFontString(nil, "OVERLAY")
        row.rank:SetJustifyH("RIGHT")
        row.rank:SetShadowOffset(1, -1)
    end
    row.rank:SetFont(NARROW, t.small and 9.5 or 11, "")
    row.rank:SetTextColor(0.62, 0.6, 0.55)
    row.rank:ClearAllPoints()
    row.rank:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.rank:SetWidth(m.iconW - 3)
    row.rank:SetShown(t.rank and m.icon == "none")
    -- the bar
    local fill, bg = row.fill, row.bg
    HideAll(row.capL, row.capR, row.tcapL, row.tcapR, row.back, row.lit, row.shade, row.sepLine, row.meBg)
    fill:SetTexture(t.bar == "gilt" and BAR or WHITE)
    if threat then
        local ins = t.trackInset
        row.trackTop, row.trackBot = -ins, ins
        if t.bar == "hair" then row.trackTop, row.trackBot = -(h - 4), 2 end
        row.track:SetTexture(WHITE)
        if t.bar == "lit" then row.track:SetVertexColor(0.07, 0.07, 0.08, 1)
        elseif t.bar == "gilt" then row.track:SetVertexColor(0, 0, 0, 0.4)
        elseif t.bar == "hair" then row.track:SetVertexColor(1, 1, 1, 0.07)
        else row.track:SetVertexColor(1, 1, 1, (t.bar == "pill") and 0.06 or 0.05) end
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
        bg:SetVertexColor(1, 1, 1, 0.035)
        row.tcapL:ClearAllPoints()
        row.tcapL:SetSize(r, h)
        row.tcapL:SetPoint("RIGHT", bg, "LEFT")
        row.tcapR:ClearAllPoints()
        row.tcapR:SetSize(r, h)
        row.tcapR:SetPoint("LEFT", bg, "RIGHT")
        row.tcapL:SetVertexColor(1, 1, 1, 0.035)
        row.tcapR:SetVertexColor(1, 1, 1, 0.035)
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
        if t.bar == "lit" then bg:SetVertexColor(0.07, 0.07, 0.083, 1) else bg:SetVertexColor(0, 0, 0, 0.35) end
        row.lit:ClearAllPoints()
        row.lit:SetPoint("TOPLEFT", fill, "TOPLEFT")
        row.lit:SetPoint("TOPRIGHT", fill, "TOPRIGHT")
        row.lit:SetVertexColor(1, 1, 1, t.bar == "lit" and 0.35 or 0.14)
        row.lit:Show()
        if t.bar == "lit" then
            row.shade:ClearAllPoints()
            row.shade:SetAllPoints(fill)
            Grad(row.shade, "VERTICAL", { 0, 0, 0, 0.32 }, { 1, 1, 1, 0.1 })
            row.shade:Show()
        end
    elseif t.bar == "hair" then
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 2)
        fill:SetHeight(2)
        bg:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 2)
        bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 2)
        bg:SetHeight(2)
        bg:SetVertexColor(1, 1, 1, 0.07)
        row.sepLine:ClearAllPoints()
        row.sepLine:SetPoint("BOTTOMLEFT")
        row.sepLine:SetPoint("BOTTOMRIGHT")
        row.sepLine:SetVertexColor(1, 1, 1, 0.04)
        row.sepLine:Show()
    else
        fill:SetPoint("TOPLEFT", row, "TOPLEFT", L, 0)
        fill:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", L, 0)
        bg:SetAllPoints()
        bg:SetVertexColor(1, 1, 1, 0.03)
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
        Grad(fill, "HORIZONTAL", c1, c2)
        row.capL:SetVertexColor(c1[1], c1[2], c1[3], a)
        row.capR:SetVertexColor(c2[1], c2[2], c2[3], a)
    elseif t.bar == "gilt" then
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
            local r, g, b = 0.6, 0.6, 0.6
            if row.cls then r, g, b = ns.MeterWindow.K.ClassColor(row.cls) end
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
        local a = me and 0.16 or 0.035
        local r, g, b = me and GOLD[1] or 1, me and GOLD[2] or 1, me and GOLD[3] or 1
        row.bg:SetVertexColor(r, g, b, a)
        row.tcapL:SetVertexColor(r, g, b, a)
        row.tcapR:SetVertexColor(r, g, b, a)
    end
    if row.meBg and t.bar == "hair" then
        if me then
            row.meBg:ClearAllPoints()
            row.meBg:SetAllPoints()
            Grad(row.meBg, "HORIZONTAL", { 1, 0.82, 0, 0.11 }, { 1, 0.82, 0, 0 })
            row.meBg:Show()
        else
            row.meBg:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Settings > Meters > Look: a tile per theme (a little panel drawn in it), hover previews it on the panels
---------------------------------------------------------------------------

local TILE_W, TILE_H, TILE_GAP = 84, 74, 6
local PREVIEW = { { "Quentrell", "HUNTER", "Beast Mastery", 1 }, { "Tsumil", "WARRIOR", "Fury", 0.87, true },
                  { "Dreadhex", "WARLOCK", "Destruction", 0.74 } }

local function PreviewRow(parent)
    local K = ns.MeterWindow.K
    local row = CreateFrame("Frame", nil, parent)
    row.bg = Tex(row, "BACKGROUND", 0)
    row.fill = Tex(row, "BORDER", 0)
    row.you = Tex(row, "OVERLAY", 0)
    row.you:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
    row.you:SetPoint("TOPLEFT")
    row.you:SetPoint("BOTTOMLEFT")
    row.you:SetWidth(2)
    row.icon = Tex(row, "ARTWORK", 0, 134400)
    row.iconLine = Tex(row, "ARTWORK", 1)
    row.iconLine:SetVertexColor(0, 0, 0, 0.85)
    row.iconLine:SetPoint("TOPLEFT", row.icon, "TOPRIGHT")
    row.iconLine:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT")
    row.iconLine:SetWidth(1)
    row.name = K.Font(row, FRIZ, 12, { 1, 1, 1 })
    row.value = K.Font(row, NARROW, 13, { 1, 1, 1 })
    return row
end

local function FillPreview(holder, t)
    local saved = MT.preview
    MT.preview = t.key                -- (Metrics reads the theme in use; the overrides apply as on the panels)
    local m = MT:Metrics()
    MT.preview = saved
    local W = 150
    holder:SetSize(W, 60)
    holder.bg = holder.bg or Tex(holder, "BACKGROUND", -6)
    holder.bg:SetAllPoints()
    local a = t.bg[4]
    holder.bg:SetVertexColor(t.bg[1], t.bg[2], t.bg[3], max(0.6, a))
    holder.head = holder.head or Tex(holder, "BACKGROUND", -5)
    holder.head:ClearAllPoints()
    holder.head:SetPoint("TOPLEFT")
    holder.head:SetPoint("TOPRIGHT")
    holder.head:SetHeight(m.head - 6)
    if type(t.headBg[1]) == "table" then Grad(holder.head, "VERTICAL", t.headBg[1], t.headBg[2])
    else Color(holder.head, t.headBg) end
    holder.title = holder.title or ns.MeterWindow.K.Font(holder, FRIZ, 10, GOLD)
    holder.title:ClearAllPoints()
    holder.title:SetPoint("LEFT", holder.head, "LEFT", 5, 0)
    local tc = t.titleColor or GOLD
    holder.title:SetTextColor(tc[1], tc[2], tc[3])
    holder.title:SetFont(FRIZ, 10, "")
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
        row.value:SetText(t.rank and "" or "")
        row.rank:SetText(tostring(i))
        local r, g, b = MT:BarColor(p[2], p[3])
        MT:Paint(row, m, r, g, b, p[5])
        row.fill:SetWidth(max(1, (inner - m.barL - m.barRes) * p[4]))
        y = y - m.row - m.gap
    end
    holder:SetHeight(-y + m.pad)
    holder:SetScale(min(1, (TILE_W - 8) / W))
end

-- The theme picker: a tile per theme. Returns the strip (Refresh redraws the tiles).
function MT:SettingsTiles(S, sec)
    local row = S:Row(sec, "Theme", "How every meter panel looks. Point at a theme to try it on your panels.")
    row.line:Hide()
    local strip = CreateFrame("Frame", nil, sec)
    strip:SetPoint("TOPLEFT", sec, "TOPLEFT", 0, sec.y + 4)
    strip:SetPoint("TOPRIGHT", sec, "TOPRIGHT", 0, sec.y + 4)
    strip:SetHeight(TILE_H + 14)
    strip.tiles = {}
    for i, t in ipairs(MT.THEMES) do
        local tile = CreateFrame("Button", nil, strip)
        tile:SetSize(TILE_W, TILE_H)
        tile:SetPoint("TOPLEFT", strip, "TOPLEFT", (i - 1) * (TILE_W + TILE_GAP), 0)
        if tile.SetClipsChildren then tile:SetClipsChildren(true) end
        tile.bg = Tex(tile, "BACKGROUND", -8)
        tile.bg:SetVertexColor(0.05, 0.05, 0.063, 1)
        tile.bg:SetAllPoints()
        ns.UI:AddEdges(tile)
        tile.hl = Tex(tile, "HIGHLIGHT", 0)
        tile.hl:SetVertexColor(1, 1, 1, 0.03)
        tile.hl:SetAllPoints()
        tile.band = Tex(tile, "OVERLAY", 0)
        tile.band:SetVertexColor(0.05, 0.05, 0.063, 1)
        tile.band:SetPoint("BOTTOMLEFT", 1, 1)
        tile.band:SetPoint("BOTTOMRIGHT", -1, 1)
        tile.band:SetHeight(17)
        tile.name = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tile.name:SetPoint("BOTTOM", tile, "BOTTOM", 0, 5)
        tile.name:SetText(t.name)
        tile.preview = CreateFrame("Frame", nil, tile)
        tile.preview:SetPoint("TOPLEFT", tile, "TOPLEFT", 4, -4)
        tile.key = t.key
        tile.theme = t
        tile:SetScript("OnClick", function()
            MT.preview = nil
            ns.DB:SetSetting("meters.theme", t.key)
            strip:Refresh()
        end)
        tile:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(t.name)
            GameTooltip:AddLine(t.tip, 0.85, 0.85, 0.85, true)
            GameTooltip:AddLine("Your panels show it while you point at it (turn on demo data to try it alone).",
                0.6, 0.6, 0.6, true)
            GameTooltip:Show()
            MT:SetPreview(t.key)
        end)
        tile:SetScript("OnLeave", function()
            GameTooltip:Hide()
            MT:SetPreview(nil)
        end)
        strip.tiles[i] = tile
    end
    function strip:Refresh()
        local cur = Setting("theme", MT.DEFAULT)
        for _, tile in ipairs(self.tiles) do
            FillPreview(tile.preview, tile.theme)
            local on = tile.key == cur
            ns.UI:SetEdgeColor(tile, on and GOLD[1] or 0.17, on and GOLD[2] or 0.17, on and GOLD[3] or 0.2, 1)
            tile.name:SetTextColor(on and GOLD[1] or 0.85, on and GOLD[2] or 0.82, on and GOLD[3] or 0.75)
        end
    end
    strip:Refresh()
    S.refreshers[#S.refreshers + 1] = strip
    sec.y = sec.y - (TILE_H + 14)
    local line = strip:CreateTexture(nil, "BORDER")
    line:SetColorTexture(1, 1, 1, 0.06)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    sec.rows[#sec.rows + 1] = { line = line }
    return strip, row
end

MT._FillPreview = FillPreview

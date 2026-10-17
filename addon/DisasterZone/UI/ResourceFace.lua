if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ResourceFace.lua", ...) then return end -- DisasterZone: resource bar faces.
-- The looks of the resource bar (UI/ResourceBar.lua, Core/Resource.lua; feedback #26): the six class tool themes in
-- three shapes. Mockup dev/art/casc/resource_mockup (v2, the user's answers 2026-10-17). The rule of the timer themes
-- (UI/RingFace.lua) holds: the parts and their colours stay, only the face changes.
--   bar      the number (in its theme's holder), a bar beside it, combo points and druid mana under it
--   upright  the bar's layout turned a quarter: it fills from the bottom, marks on its left, combo points on its right;
--            numbers stay level (they are placed, not turned)
--   globe    the power as liquid in the theme's round (Sigil: square) face, marks as pointers on its left rim, combo
--            points on an arc under it
-- Parts every face has (painted by RF:Paint from a Core/Resource.lua snapshot):
--   fill          the power; a warrior's rage over the Heroic Strike line in the brighter "over" colours
--   held          a queued Heroic Strike's rage: darkened, its edge lit
--   ghost         the next tick's gain (or, opt-in, the next swing's rage): the power's colour, faint
--   marks         per picked press: a line in the fill and a peg (or its icon) on the edge; lit = you can press it
--   timer         the 2 s tick / the five-second rule: the ring of strokes round the number (Halo, Gilded), the tile's
--                 frame (Sigil), a hairline (Slate, Pips), the cast bar's spark (Classic)
--   cap           a glow while the power is about to spill over
--   RF:Build(parent, theme, shape)   -> face { root, theme, shape, W, H }; face:Layout(len) for bars (Edit layout
--                                      stretches them)
--   RF:Paint(face, s, o)             s = Resource:Snapshot(), o = { num, marks, tick, color, class, own, now }
local addonName, ns = ...

local RF = {}
ns.ResourceFace = RF

local UI = ns.UI
local S = ns.Style

local floor, max, min, pi, cos, sin, abs = math.floor, math.max, math.min, math.pi, math.cos, math.sin, math.abs
local ipairs, pairs, type = ipairs, pairs, type

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local RINGTEX = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\ring"
local BEZEL = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\bezel"
local FLUID = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\fluid"
local GLASS_SHADE = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\glass_shade"
local GLASS_SPEC = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\glass_spec"
local TANK_SHADE = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\tank_shade"
local TANK_SPEC = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\tank_spec"
local NARROW = S.FONT_NUM

RF.THEMES = {
    { key = "halo", name = "Halo", tip = "A capsule bar beside a ring that holds the number; the ring keeps the tick." },
    { key = "sigil", name = "Sigil", tip = "A square tile and a framed bar: the tile's frame keeps the tick." },
    { key = "slate", name = "Slate", tip = "A quiet glass card: a flat line, the number on the right. Calmest look." },
    { key = "gilded", name = "Gilded", tip = "A small globe in a gold bezel and a gold-framed bar." },
    { key = "pips", name = "Pips", tip = "One pip is 5; four pips are one energy tick." },
    { key = "classic", name = "Classic", tip = "The game's own status bar in a cast bar's border, with its spark." },
}
RF.SHAPES = {
    { key = "bar", name = "Bar" }, { key = "upright", name = "Upright" }, { key = "globe", name = "Globe" },
}

-- ---------------------------------------------------------------------------------------------------------------
-- Colours: each power's fill (top, middle, bottom), the brighter top over the Heroic Strike line, its light (rings,
-- ghosts, glows), the game's own colour (Classic) and the globe's liquid
-- ---------------------------------------------------------------------------------------------------------------
local function C(hex)
    return { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255 }
end
RF.PAL = {
    rage = { under = { C("d23a26"), C("a8180f"), C("5e0804") }, over = { C("ffa05a"), C("ff5a2a"), C("c8361a") },
             light = C("ff5a2a"), game = { 1, 0, 0 }, liq = { C("b81c12"), C("861009"), C("5a0805") } },
    energy = { under = { C("fff07a"), C("e6c000"), C("8f7200") }, light = C("ffe250"), game = { 1, 1, 0 },
               liq = { C("f2d22a"), C("c9a200"), C("6e5800") } },
    mana = { under = { C("8ab8ff"), C("2f62e0"), C("163691") }, light = C("6aa0ff"), game = { 0, 0, 1 },
             liq = { C("4f86f0"), C("2449b8"), C("122a70") } },
}
local RULE_LIGHT = { 0.89, 0.93, 1 }      -- the five-second rule (pale)
local GOLD = { 1, 0.84, 0.42 }
local DIM = { 0.36, 0.33, 0.27 }

local function Shade(c, k) return { min(1, c[1] * k), min(1, c[2] * k), min(1, c[3] * k) } end

-- The colours for a power: the game's (default), the class's, or the player's own.
function RF:Palette(kind, mode, classFile, own)
    local base = self.PAL[kind] or self.PAL.mana
    local c
    if mode == "class" then
        local cc = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
        if cc then c = { cc.r, cc.g, cc.b } end
    elseif mode == "own" and type(own) == "table" then
        c = { own.r or 1, own.g or 1, own.b or 1 }
    end
    if not c then return base end
    return { under = { Shade(c, 1.2), c, Shade(c, 0.45) }, over = base.over and { Shade(c, 1.45), Shade(c, 1.2), c },
             light = Shade(c, 1.15), game = c, liq = { c, Shade(c, 0.75), Shade(c, 0.4) } }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Building blocks
-- ---------------------------------------------------------------------------------------------------------------
local function Part(parent, layer, path, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetTexture(path or WHITE)
    if r then t:SetVertexColor(r, g, b, a or 1) end
    return t
end

local function Round(holder, tex)
    if not holder.CreateMaskTexture then return end
    local m = holder:CreateMaskTexture()
    m:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    m:SetAllPoints(tex)
    tex:AddMaskTexture(m)
end

local function Bezel(parent, layer, size, sub)
    local hasArt = ns.HasAssets and ns:HasAssets(7)
    local t = Part(parent, layer, hasArt and BEZEL or RINGTEX, nil, nil, nil, nil, sub)
    if not hasArt then t:SetVertexColor(0.86, 0.68, 0.3, 1) end
    t:SetSize(size, size)
    return t
end

-- A gradient along the bar's thickness: light at the top of a bar, at the left of an upright one.
local function ShadeAcross(t, c3, vertical)
    if vertical then UI:GradientRGBA(t, "HORIZONTAL", c3[1][1], c3[1][2], c3[1][3], 1, c3[3][1], c3[3][2], c3[3][3], 1)
    else UI:GradientRGBA(t, "VERTICAL", c3[3][1], c3[3][2], c3[3][3], 1, c3[1][1], c3[1][2], c3[1][3], 1) end
end

-- A ring of strokes round (cx, cy) of a frame, N cells from radius r0 to r1 (the Halo look of a timer).
local function Strokes(f, cx, cy, r0, r1, n, layer, sub)
    local out = {}
    for i = 1, n do
        local a = pi / 2 - 2 * pi * (i - 0.5) / n
        local l = f:CreateLine(nil, layer or "ARTWORK", nil, sub)
        l:SetColorTexture(1, 1, 1, 1)
        l:SetThickness(2 * pi * r1 / n + 0.6)
        l:SetStartPoint("TOPLEFT", f, cx + r0 * cos(a), -cy + r0 * sin(a))
        l:SetEndPoint("TOPLEFT", f, cx + r1 * cos(a), -cy + r1 * sin(a))
        l.f = (i - 0.5) / n
        out[i] = l
    end
    return out
end

-- Cells round a square (the Sigil tile's frame): from the top's middle, clockwise.
local function SquareCells(f, cx, cy, half, band, n, layer, sub)
    local out = {}
    for i = 1, n do
        local fr = (i - 0.5) / n
        local s = fr * 8 * half
        local x, y, vert
        if s < half then x, y = s, half
        elseif s < 3 * half then x, y, vert = half, half - (s - half), true
        elseif s < 5 * half then x, y = half - (s - 3 * half), -half
        elseif s < 7 * half then x, y, vert = -half, -half + (s - 5 * half), true
        else x, y = -half + (s - 7 * half), half end
        local t = Part(f, layer or "ARTWORK", WHITE, nil, nil, nil, nil, sub)
        local cell = 8 * half / n + 0.6
        if vert then t:SetSize(band, cell) else t:SetSize(cell, band) end
        t:SetPoint("CENTER", f, "TOPLEFT", cx + x, -cy + y)
        t.f = fr
        out[i] = t
    end
    return out
end

-- Colours a timer's cells: lit up to phase (the tick, or the five-second rule in pale), the rest dark; no timer: all
-- in the power's light, dimmer.
local function PaintTimer(cells, phase, light, rule, gold)
    for _, d in ipairs(cells) do
        if phase == nil then
            local c = gold or light
            d:SetVertexColor(c[1], c[2], c[3], 0.8)
        elseif d.f <= phase then
            local c = rule and RULE_LIGHT or light
            d:SetVertexColor(c[1], c[2], c[3], 1)
        else
            d:SetVertexColor(1, 1, 1, 0.13)
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The bar (and upright): geometry per theme, in "along" (the bar's length) and "across" (its thickness) coordinates
-- ---------------------------------------------------------------------------------------------------------------
--   holder   what holds the number before the bar: disc (Halo), tile (Sigil), globe (Gilded), text (Pips), nil
--   C        the holder's size along; gap: between it and the bar; th: the bar's thickness; ch: across of the holder
--   peg      the marks' pegs: dot | tick; cp: the combo points' style
RF.BAR = {
    halo = { holder = "disc", C = 26, ch = 26, gap = 5, th = 12, peg = "dot", cp = "disc", round = true, len = 180 },
    sigil = { holder = "tile", C = 24, ch = 24, gap = 5, th = 12, peg = "tick", cp = "sq", len = 180 },
    slate = { holder = nil, C = 0, ch = 0, gap = 0, th = 5, peg = "tick", cp = "dash", flat = true, card = true,
              len = 198, line = true },
    gilded = { holder = "globe", C = 32, ch = 32, gap = 5, th = 10, peg = "dot", cp = "gild", gold = true, len = 180 },
    pips = { holder = "text", C = 24, ch = 12, gap = 2, th = 9, peg = "tick", cp = "pip", pips = true, len = 147,
             line = true },
    classic = { holder = nil, C = 0, ch = 0, gap = 0, th = 10, peg = "tick", cp = "classic", game = true, len = 172,
                spark = true, pad = 9 },
}
RF.BAR.halo.minLen, RF.BAR.slate.minLen = 60, 60

local Face = {}
Face.__index = Face

-- Puts texture t at (a, c) along / across, aLen x cLen, on the face's axis.
function Face:Put(t, a, c, aLen, cLen)
    t:ClearAllPoints()
    if self.vertical then
        t:SetPoint("TOPLEFT", self.root, "TOPLEFT", c + self.c0, -(self.total - a - aLen))
        t:SetSize(max(0.01, cLen), max(0.01, aLen))
    else
        t:SetPoint("TOPLEFT", self.root, "TOPLEFT", a, -(c + self.c0))
        t:SetSize(max(0.01, aLen), max(0.01, cLen))
    end
end

-- A point (a, c) on the face in TOPLEFT offsets.
function Face:At(a, c)
    if self.vertical then return c + self.c0, -(self.total - a) end
    return a, -(c + self.c0)
end

function Face:Center(fs, a, c)
    local x, y = self:At(a, c)
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", self.root, "TOPLEFT", x, y)
end

local function NewTex(face, layer, sub, path)
    return Part(face.root, layer, path or WHITE, nil, nil, nil, nil, sub)
end

local function BuildBar(parent, theme, vertical)
    local g = RF.BAR[theme] or RF.BAR.halo
    local root = CreateFrame("Frame", nil, parent)
    local face = setmetatable({ root = root, theme = theme, shape = vertical and "upright" or "bar", g = g,
                                vertical = vertical, c0 = 14, total = 1 }, Face)
    local p = {}
    face.p = p
    -- the cap glow (behind everything)
    p.capGlow = Part(root, "BACKGROUND", SOFT, 1, 0.56, 0.2, 0, -8)
    p.capGlow:SetBlendMode("ADD")
    if g.card then
        p.card = Part(root, "BACKGROUND", WHITE, 0.047, 0.047, 0.059, 0.84, -7)
        p.cardEdge = {}
        local hl = S.C.HAIRLINE
        for i = 1, 4 do p.cardEdge[i] = Part(root, "BACKGROUND", WHITE, hl[1], hl[2], hl[3], hl[4], -6) end
        p.label = UI:Text(root, "caps", { 0.56, 0.54, 0.49 }, { font = NARROW })
        UI:SetTextSize(p.label, 8)
    end
    -- the holder
    if g.holder == "disc" then
        p.well = Part(root, "BORDER", DISC, 0.04, 0.03, 0.025, 0.95, -2)
        p.ring = {}
    elseif g.holder == "tile" then
        p.well = Part(root, "BORDER", WHITE, 0, 0, 0, 1, -2)
        p.tileIn = Part(root, "ARTWORK", WHITE, 0, 0, 0, 1, 3)
        p.tileEdge = Part(root, "ARTWORK", WHITE, 0.91, 0.89, 0.82, 0.25, 2)
    elseif g.holder == "globe" then
        p.well = Part(root, "BORDER", DISC, 0, 0, 0, 1, -3)
        p.bezel = Bezel(root, "BORDER", g.C, -2)
        p.groove = Part(root, "BORDER", DISC, 0.08, 0.055, 0.016, 1, -1)
    end
    -- the track
    if g.round then
        p.trackL = Part(root, "BORDER", DISC, 0, 0, 0, 0.62, 0)
        p.trackM = Part(root, "BORDER", WHITE, 0, 0, 0, 0.62, 0)
        p.trackR = Part(root, "BORDER", DISC, 0, 0, 0, 0.62, 0)
        p.rim = Part(root, "BORDER", WHITE, 0.91, 0.89, 0.82, 0.18, -1)
    elseif g.gold then
        p.frame = Part(root, "BORDER", WHITE, 1, 1, 1, 1, -1)
        UI:GradientRGBA(p.frame, g.vertical and "HORIZONTAL" or "VERTICAL", 0.48, 0.33, 0.07, 1, 1, 0.94, 0.72, 1)
        p.frameL = Part(root, "BORDER", DISC, 0.79, 0.6, 0.2, 1, -1)
        p.frameR = Part(root, "BORDER", DISC, 0.79, 0.6, 0.2, 1, -1)
        p.track = Part(root, "BORDER", WHITE, 0.08, 0.055, 0.016, 1, 0)
    elseif g.pips then
        p.pips, p.pipBacks = {}, {}
        for i = 1, 20 do
            p.pipBacks[i] = Part(root, "BORDER", WHITE, 0, 0, 0, 1, 0)
            p.pips[i] = Part(root, "ARTWORK", WHITE, 1, 1, 1, 0.1, 0)
        end
    else
        p.frameBack = Part(root, "BORDER", WHITE, 0, 0, 0, g.game and 0.55 or 1, -1)
        p.track = Part(root, "BORDER", WHITE, g.flat and 1 or 0.157, g.flat and 1 or 0.141, g.flat and 1 or 0.118,
                       g.flat and 0.08 or 0.85, 0)
        if theme == "sigil" then p.trackEdge = Part(root, "BORDER", WHITE, 0.91, 0.89, 0.82, 0.22, 1) end
    end
    if not g.pips then
        -- the fill: under the line, over it, a queued Heroic Strike, the ghost; a disc cap on round bars
        p.fill = Part(root, "ARTWORK", g.game and ns.Look.SBAR or WHITE, nil, nil, nil, nil, 0)
        if g.round then p.fillCap = Part(root, "ARTWORK", DISC, nil, nil, nil, nil, 0) end
        p.over = Part(root, "ARTWORK", g.game and ns.Look.SBAR or WHITE, nil, nil, nil, nil, 1)
        p.held = Part(root, "ARTWORK", WHITE, 0, 0, 0, 0.55, 2)
        p.ghost = Part(root, "ARTWORK", WHITE, 1, 1, 1, 0.35, 1)
        p.ghostEdge = Part(root, "ARTWORK", WHITE, 1, 1, 1, 0.8, 3)
        p.heldEdge = Part(root, "ARTWORK", WHITE, 1, 1, 1, 0.9, 3)
        if not g.flat and not g.game then
            p.sheen = Part(root, "ARTWORK", WHITE, 1, 1, 1, 0.22, 4)
        end
    end
    if g.game then
        p.border = ns.Look:GameSlice3(root, "cast", 12, 12, "ARTWORK", 5)
    end
    -- the Heroic Strike line and its pointer
    p.hsl = Part(root, "OVERLAY", WHITE, GOLD[1], GOLD[2], GOLD[3], 1, 1)
    p.hsp = Part(root, "OVERLAY", WHITE, GOLD[1], GOLD[2], GOLD[3], 1, 1)
    -- marks (made as needed), the timer line / spark, the number
    p.marks = {}
    if g.line then
        p.tLine0 = Part(root, "ARTWORK", WHITE, S.C.HAIRLINE[1], S.C.HAIRLINE[2], S.C.HAIRLINE[3], S.C.HAIRLINE[4], 0)
        p.tLine = Part(root, "ARTWORK", WHITE, 1, 1, 1, 1, 1)
    end
    if g.spark or theme ~= "classic" then
        p.spark = Part(root, "OVERLAY", g.game and nil or WHITE, 1, 0.98, 0.9, 1, 2)
        if g.game then ns.Look:GameTex(p.spark, "spark"); p.spark:SetBlendMode("ADD") end
    end
    -- (the numbers on a frame of their own, over the Gilded holder's little globe)
    local over = CreateFrame("Frame", nil, root)
    over:SetAllPoints()
    over:SetFrameLevel(root:GetFrameLevel() + 3)
    face.over = over
    p.num = UI:Text(over, "emph", { 1, 0.95, 0.84 }, { font = (g.card or g.pips or g.game) and NARROW or nil, flags = "OUTLINE" })
    p.num:SetDrawLayer("OVERLAY", 7)
    p.barNum = UI:Text(over, "small", { 1, 0.95, 0.84 }, { flags = "OUTLINE" })
    p.barNum:SetDrawLayer("OVERLAY", 7)
    -- combo points (#27) and druid mana
    p.cp = {}
    for i = 1, 5 do
        if g.cp == "gild" then
            local ring = Part(root, "ARTWORK", DISC, 0.63, 0.48, 0.15, 1, 1)
            p.cp[i] = Part(root, "ARTWORK", DISC, nil, nil, nil, nil, 2)
            p.cp[i].ring = ring
        elseif g.cp == "disc" or g.cp == "classic" then
            p.cp[i] = Part(root, "ARTWORK", DISC, nil, nil, nil, nil, 2)
            p.cp[i].ring = Part(root, "ARTWORK", DISC, 0, 0, 0, 1, 1)
        else
            p.cp[i] = Part(root, "ARTWORK", WHITE, nil, nil, nil, nil, 2)
            p.cp[i].ring = Part(root, "ARTWORK", WHITE, 0, 0, 0, 1, 1)
        end
    end
    p.mana0 = Part(root, "ARTWORK", WHITE, 0, 0, 0, 0.62, 0)
    p.mana = Part(root, "ARTWORK", WHITE, 1, 1, 1, 1, 1)
    p.manaMarks = {}
    face:Layout(g.len)
    return face
end

-- Lays the bar out for a length (Edit layout stretches it): everything's place, nothing's colour.
function Face:Layout(len)
    local g, p = self.g, self.p
    if self.shape == "globe" then return end
    len = max(g.minLen or 40, floor((len or g.len) + 0.5))
    self.len = len
    local bx = g.C + g.gap + (g.pad or 0)
    local tail = (self.vertical and not g.holder) and 16 or 0      -- (the number's slot above an upright bar)
    local total = bx + len + (g.pad or 0) + tail
    self.tail = tail
    -- across: the holder's middle is the bar's middle
    local mid = max(g.ch, g.th) / 2
    local cTop = g.card and 16 or (mid - g.th / 2)
    if g.pips then cTop = 1 end
    self.bx, self.by, self.total = bx, cTop, total
    -- under the bar: the timer line, druid mana, combo points
    local y = cTop + g.th + 3
    if g.line then self.lineY = y; y = y + 4 end
    self.manaY = y
    self.cpY = y + 6
    local across = max(g.ch, self.cpY + 8)
    if g.card then across = self.cpY + 12 end
    self.across = across
    self.c0 = 0
    local W, H = total, across
    if self.vertical then W, H = across, total end
    self.root:SetSize(W, H)
    self.W, self.H = W, H

    p.capGlow:ClearAllPoints()
    local gx, gy = self:At(bx + len / 2, cTop + g.th / 2)
    p.capGlow:SetPoint("CENTER", self.root, "TOPLEFT", gx, gy)
    if self.vertical then p.capGlow:SetSize(g.th * 4, len * 1.25) else p.capGlow:SetSize(len * 1.25, g.th * 4) end
    if p.card then
        self:Put(p.card, 0, 0, total, across)
        local e = p.cardEdge
        self:Put(e[1], 0, 0, total, 1); self:Put(e[2], 0, across - 1, total, 1)
        self:Put(e[3], 0, 0, 1, across); self:Put(e[4], total - 1, 0, 1, across)
        p.label:SetShown(not self.vertical)
        if not self.vertical then
            p.label:ClearAllPoints()
            p.label:SetPoint("TOPLEFT", self.root, "TOPLEFT", 8, -4)
        end
    end
    local hc = g.C / 2
    if g.holder == "disc" then
        self:Put(p.well, 0, mid - hc, g.C, g.C)
        if #p.ring == 0 then
            local cx, cy = self:At(hc, mid)
            p.ring = Strokes(self.root, cx, -cy, g.C / 2 - 3.6, g.C / 2 - 1.2, 36, "ARTWORK", 1)
        end
    elseif g.holder == "tile" then
        self:Put(p.well, 0, mid - hc, g.C, g.C)
        self:Put(p.tileIn, 4, mid - hc + 4, g.C - 8, g.C - 8)
        self:Put(p.tileEdge, 4, mid - hc + 4, g.C - 8, g.C - 8)
        if not p.ring then
            local cx, cy = self:At(hc, mid)
            p.ring = SquareCells(self.root, cx, -cy, hc - 2.5, 3, 32, "ARTWORK", 1)
        end
    elseif g.holder == "globe" then
        local cx, cy = self:At(hc, mid)
        p.well:ClearAllPoints(); p.well:SetPoint("CENTER", self.root, "TOPLEFT", cx, cy); p.well:SetSize(g.C + 2, g.C + 2)
        p.bezel:ClearAllPoints(); p.bezel:SetPoint("CENTER", self.root, "TOPLEFT", cx, cy)
        p.groove:ClearAllPoints(); p.groove:SetPoint("CENTER", self.root, "TOPLEFT", cx, cy)
        p.groove:SetSize(g.C - 6, g.C - 6)
        if not p.ring then
            p.ring = Strokes(self.root, cx, -cy, g.C / 2 - 6.3, g.C / 2 - 4.1, 36, "ARTWORK", 1)
            p.mini = RF:Liquid(self.root, g.C - 14, false)
            p.mini:SetFrameLevel(self.root:GetFrameLevel() + 1)
        end
        p.mini:ClearAllPoints()
        p.mini:SetPoint("CENTER", self.root, "TOPLEFT", cx, cy)
    end
    -- the track
    if g.round then
        self:Put(p.trackL, bx, cTop, g.th, g.th)
        self:Put(p.trackM, bx + g.th / 2, cTop, len - g.th, g.th)
        self:Put(p.trackR, bx + len - g.th, cTop, g.th, g.th)
        self:Put(p.rim, bx + g.th / 2, cTop - 1, len - g.th, 1)
    elseif g.gold then
        self:Put(p.frame, bx + 2, cTop - 2, len - 4, g.th + 4)
        self:Put(p.frameL, bx - 2, cTop - 2, g.th + 4, g.th + 4)
        self:Put(p.frameR, bx + len - g.th - 2, cTop - 2, g.th + 4, g.th + 4)
        self:Put(p.track, bx + 2, cTop, len - 4, g.th)
        UI:GradientRGBA(p.frame, self.vertical and "HORIZONTAL" or "VERTICAL", 0.48, 0.33, 0.07, 1, 1, 0.94, 0.72, 1)
    elseif g.pips then
        local gaps = 4 * 2
        local pw = (len - gaps - 19) / 20
        self.pipW = pw
        for i = 1, 20 do
            local a = bx + (i - 1) * (pw + 1) + floor((i - 1) / 4) * 2
            self:Put(p.pipBacks[i], a, cTop, pw, g.th)
            self:Put(p.pips[i], a + 1, cTop + 1, pw - 2, g.th - 2)
            p.pips[i].a0, p.pips[i].a1 = a, a + pw
        end
    else
        self:Put(p.frameBack, bx - 1, cTop - 1, len + 2, g.th + 2)
        self:Put(p.track, bx, cTop, len, g.th)
        if p.trackEdge then self:Put(p.trackEdge, bx, cTop, len, 1) end
    end
    if p.border then
        if self.vertical then
            p.border:Show(false)
        else
            local k = g.th / 14
            p.border:Show(true)
            p.border:Place(self.root, bx - 9 * k, cTop - 10 * k, len + 19 * k, 34 * k, k)
        end
    end
    if p.sheen then self:Put(p.sheen, bx, cTop, len, g.th * 0.45) end
    if p.tLine0 then self:Put(p.tLine0, bx, self.lineY, len, g.pips and 2 or 1) end
    -- the number
    p.num:ClearAllPoints()
    if g.holder == "text" then
        if self.vertical then
            local x, y = self:At(hc, mid)
            p.num:SetPoint("CENTER", self.root, "TOPLEFT", x, y)
            p.num:SetJustifyH("CENTER")
        else
            p.num:SetPoint("RIGHT", self.root, "TOPLEFT", g.C - 2, -(cTop + g.th / 2))
            p.num:SetJustifyH("RIGHT")
        end
    elseif g.holder then
        self:Center(p.num, hc, mid)
        p.num:SetJustifyH("CENTER")
    elseif self.vertical then
        self:Center(p.num, total - tail / 2, cTop + g.th / 2)
        p.num:SetJustifyH("CENTER")
    elseif g.card then
        do
            p.num:SetPoint("TOPRIGHT", self.root, "TOPRIGHT", -8, -2)
            p.num:SetJustifyH("RIGHT")
        end
    else
        self:Center(p.num, bx + len / 2, cTop + g.th / 2)
        p.num:SetJustifyH("CENTER")
    end
    UI:SetTextSize(p.num, g.holder == "globe" and 9 or (g.card or g.pips) and 11 or g.game and 9 or 10)
    p.barNum:ClearAllPoints()
    local nx, ny = self:At(bx + 5, cTop + g.th / 2)
    p.barNum:SetPoint(self.vertical and "CENTER" or "LEFT", self.root, "TOPLEFT", nx, ny)
    UI:SetTextSize(p.barNum, max(7, min(9, g.th - 2)))
    -- combo points and mana
    local cpSize = (g.cp == "dash") and 2 or (g.cp == "pip") and 6 or (g.cp == "gild" or g.cp == "classic") and 8 or 7
    local cpLen = (g.cp == "dash") and 12 or cpSize
    local step = cpLen + (g.cp == "pip" and 1 or 3)
    local a0 = g.game and (bx + len / 2 - 2.5 * step) or bx + 2
    for i = 1, 5 do
        local t = p.cp[i]
        self:Put(t, a0 + (i - 1) * step, self.cpY, cpLen, cpSize)
        if t.ring then
            local grow = (g.cp == "gild") and 2 or 1
            self:Put(t.ring, a0 + (i - 1) * step - grow, self.cpY - grow, cpLen + 2 * grow, cpSize + 2 * grow)
        end
    end
    self:Put(p.mana0, bx + 2, self.manaY, len - 4, 3)
end

-- The face's thickness for the rows it shows: under the bar the timer line, druid mana, combo points. Those follow
-- the class, the form and the settings (a rogue's points show at 0 too), so the face does not jump in a fight.
function Face:Fit(hasMana, hasCp)
    if self.shape == "globe" then return end
    local g, p = self.g, self.p
    local need = self.by + g.th + 2 + (g.line and 4 or 0)
    if hasMana then need = self.manaY + 5 end
    if hasCp then need = self.cpY + 8 end
    need = max(g.ch, need) + (g.card and 6 or 0)
    if need == self.across then return end
    self.across = need
    local W, H = self.total, need
    if self.vertical then W, H = need, self.total end
    self.root:SetSize(W, H)
    self.W, self.H = W, H
    if p.card then
        self:Put(p.card, 0, 0, self.total, need)
        local e = p.cardEdge
        self:Put(e[1], 0, 0, self.total, 1); self:Put(e[2], 0, need - 1, self.total, 1)
        self:Put(e[3], 0, 0, 1, need); self:Put(e[4], self.total - 1, 0, 1, need)
    end
end

-- The span of the bar a value covers (a fraction 0..1 of the length).
function Face:Span(t, f0, f1, c, h)
    f0, f1 = max(0, min(1, f0)), max(0, min(1, f1))
    if f1 - f0 <= 0.0005 then t:Hide() return end
    t:Show()
    self:Put(t, self.bx + self.len * f0, c or self.by, self.len * (f1 - f0), h or self.g.th)
end

local function MarkParts(face, i)
    local p = face.p
    local m = p.marks[i]
    if m then return m end
    m = {}
    m.line = Part(face.root, "ARTWORK", WHITE, 1, 1, 1, 0.3, 5)
    m.peg = Part(face.root, "OVERLAY", face.g.peg == "dot" and DISC or WHITE, 1, 1, 1, 1, 0)
    local ic = CreateFrame("Frame", nil, face.root)
    ic:SetSize(10, 10)
    ic.tex = Part(ic, "ARTWORK")
    ic.tex:SetAllPoints()
    ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    Round(ic, ic.tex)
    ic.rim = Part(ic, "BACKGROUND", DISC, 0, 0, 0, 1)
    ic.rim:SetPoint("CENTER"); ic.rim:SetSize(12, 12)
    m.icon = ic
    p.marks[i] = m
    return m
end

local function NumText(s, o)
    local mode = o.num or "ring"
    if mode == "off" then return nil end
    if mode == "pct" or (s.kind == "mana" and mode ~= "full") then
        return floor(100 * s.v / max(1, s.mx) + 0.5) .. "%"
    end
    if mode == "full" then return floor(s.v + 0.5) .. " / " .. floor(s.mx + 0.5) end
    return tostring(floor(s.v + 0.5))
end
RF.NumText = NumText

local function Pulse(now) return 0.5 + 0.5 * sin((now or 0) * 9) end

function RF:PaintBar(face, s, o)
    local g, p = face.g, face.p
    face:Fit(s.mana ~= nil, s.cp ~= nil)
    local pal = self:Palette(s.kind, o.color, o.class, o.own)
    local mx = max(1, s.mx)
    local cur = s.v - (s.held or 0)
    local fc, fv = cur / mx, s.v / mx
    local line = s.line and s.line / mx
    local light = pal.light
    local vert = face.vertical
    -- the fill
    if g.pips then
        local ghost = s.ghost or s.swing or 0
        for i, t in ipairs(p.pips) do
            local u = i * 5 / 100
            local col
            if fc >= u - 0.025 then
                col = (line and u > line and pal.over) and pal.over[2] or pal.under[2]
                t:SetVertexColor(col[1], col[2], col[3], 1)
            elseif fv >= u - 0.025 then
                t:SetVertexColor(light[1] * 0.45, light[2] * 0.45, light[3] * 0.45, 1)
            elseif (s.v + ghost) / mx >= u - 0.025 then
                t:SetVertexColor(light[1], light[2], light[3], 0.38)
            else
                t:SetVertexColor(1, 1, 1, 0.1)
            end
        end
    else
        local top = (line and fc > line) and line or fc
        local col = g.game and pal.game
        if g.game then
            p.fill:SetVertexColor(col[1], col[2], col[3], 1)
            p.over:SetVertexColor(min(1, col[1] + 0.25), min(1, col[2] + 0.25), min(1, col[3] + 0.25), 1)
        elseif g.flat then
            p.fill:SetColorTexture(pal.under[2][1], pal.under[2][2], pal.under[2][3], 1)
            local o2 = pal.over or pal.under
            p.over:SetColorTexture(o2[2][1], o2[2][2], o2[2][3], 1)
        else
            ShadeAcross(p.fill, pal.under, vert)
            ShadeAcross(p.over, pal.over or pal.under, vert)
        end
        local f0 = 0
        if g.round then
            -- (a disc caps the fill's start, so the round track shows no square corner)
            if fc > 0.001 then
                p.fillCap:Show()
                face:Put(p.fillCap, face.bx, face.by, g.th, g.th)
                ShadeAcross(p.fillCap, pal.under, vert)
            else
                p.fillCap:Hide()
            end
            f0 = (g.th / 2) / face.len
        end
        face:Span(p.fill, f0, max(f0, top))
        if line and fc > line then face:Span(p.over, line, fc) else p.over:Hide() end
        -- a queued Heroic Strike's rage: darkened, its edge lit
        if s.held and s.held > 0 then
            face:Span(p.held, fc, fv)
            face:Span(p.heldEdge, fc, fc + 1 / face.len)
            p.heldEdge:SetVertexColor(light[1], light[2], light[3], 0.9)
        else
            p.held:Hide(); p.heldEdge:Hide()
        end
        local ghost = s.ghost or s.swing
        if ghost and ghost > 0 and fv < 1 then
            local gEnd = min(1, (s.v + ghost) / mx)
            face:Span(p.ghost, fv, gEnd)
            p.ghost:SetVertexColor(light[1], light[2], light[3], 0.35)
            face:Span(p.ghostEdge, gEnd - 1 / face.len, gEnd)
            p.ghostEdge:SetVertexColor(light[1], light[2], light[3], 0.75)
        else
            p.ghost:Hide(); p.ghostEdge:Hide()
        end
        if p.sheen then p.sheen:SetShown(fc > 0.001) end
    end
    -- the Heroic Strike line
    if line and o.marks ~= "off" then
        local lit = fc > line
        p.hsl:Show(); p.hsp:Show()
        face:Put(p.hsl, face.bx + face.len * line - 0.75, face.by, 1.5, g.th)
        face:Put(p.hsp, face.bx + face.len * line - 1, face.by - 5, 2, 5)
        local c = lit and GOLD or { 0.54, 0.42, 0.11 }
        p.hsl:SetVertexColor(c[1], c[2], c[3], lit and 1 or 0.7)
        p.hsp:SetVertexColor(c[1], c[2], c[3], 1)
    else
        p.hsl:Hide(); p.hsp:Hide()
    end
    -- marks
    local n = (o.marks == "off") and 0 or #s.marks
    for i = 1, n do
        local mk = s.marks[i]
        local m = MarkParts(face, i)
        local f = mk.cost / mx
        local lit = cur >= mk.cost
        if f <= 0 or f >= 1 then
            m.line:Hide(); m.peg:Hide(); m.icon:Hide()
        else
            m.line:Show()
            face:Put(m.line, face.bx + face.len * f - 0.5, face.by, 1, g.th)
            if lit then m.line:SetVertexColor(0, 0, 0, 0.6) else m.line:SetVertexColor(1, 1, 1, 0.26) end
            if o.marks == "icons" and mk.icon then
                m.peg:Hide()
                m.icon:Show()
                m.icon.tex:SetTexture(mk.icon)
                m.icon.tex:SetDesaturated(not lit)
                m.icon:SetAlpha(lit and 1 or 0.55)
                local x, y = face:At(face.bx + face.len * f, face.by - 7)
                m.icon:ClearAllPoints()
                m.icon:SetPoint("CENTER", face.root, "TOPLEFT", x, y)
            else
                m.icon:Hide()
                m.peg:Show()
                if g.peg == "dot" then face:Put(m.peg, face.bx + face.len * f - 1.5, face.by - 5, 3, 3)
                else face:Put(m.peg, face.bx + face.len * f - 0.5, face.by - 4, 1, 4) end
                if lit then m.peg:SetVertexColor(1, 0.91, 0.63, 1) else m.peg:SetVertexColor(DIM[1], DIM[2], DIM[3], 1) end
            end
        end
    end
    for i = n + 1, #p.marks do
        local m = p.marks[i]
        m.line:Hide(); m.peg:Hide(); m.icon:Hide()
    end
    -- the timer: the tick, or the five-second rule
    local phase = (o.tick ~= "off") and (s.rule or s.tick) or nil
    local tickOn = o.tick ~= "off" and phase ~= nil
    if p.ring then
        if o.tick == "ring" or not (g.line or g.spark) then
            PaintTimer(p.ring, o.tick == "ring" and phase or nil, light, s.rule, g.gold and GOLD or nil)
        else
            PaintTimer(p.ring, nil, light, nil, g.gold and GOLD or nil)
        end
    end
    if p.tLine then
        if tickOn then
            face:Span(p.tLine, 0, phase, face.lineY, g.pips and 2 or 1)
            local c = s.rule and RULE_LIGHT or light
            p.tLine:SetVertexColor(c[1], c[2], c[3], 0.95)
        else
            p.tLine:Hide()
        end
        p.tLine0:SetShown(tickOn)
    end
    if p.spark then
        local sparkOn = tickOn and (o.tick == "spark" or g.spark)
        if sparkOn then
            p.spark:Show()
            if g.game then
                face:Put(p.spark, face.bx + face.len * phase - 8, face.by - 6, 16, g.th + 12)
            else
                face:Put(p.spark, face.bx + face.len * phase - 1, face.by, 2, g.th)
            end
            local c = s.rule and RULE_LIGHT or { 1, 0.98, 0.9 }
            p.spark:SetVertexColor(c[1], c[2], c[3], 1)
        else
            p.spark:Hide()
        end
    end
    -- the number
    local text = NumText(s, o)
    if g.game and o.num == "ring" and not vert and s.kind ~= "mana" then text = floor(s.v + 0.5) .. " / " .. floor(mx + 0.5) end
    if g.holder == "disc" or g.holder == "tile" then UI:SetTextSize(p.num, (text and #text >= 3) and 8 or 10)
    elseif g.holder == "globe" then UI:SetTextSize(p.num, (text and #text >= 3) and 7 or 9) end
    if o.num == "bar" then
        p.num:Hide()
        p.barNum:SetShown(text ~= nil)
        p.barNum:SetText(text or "")
    else
        p.barNum:Hide()
        p.num:SetShown(text ~= nil)
        p.num:SetText(text or "")
        if s.cap then p.num:SetTextColor(1, 0.7, 0.36)
        elseif g.card or g.pips then p.num:SetTextColor(light[1], light[2], light[3])
        else p.num:SetTextColor(1, 0.95, 0.84) end
    end
    if p.label then p.label:SetText(((s.kind == "rage" and "Rage") or (s.kind == "energy" and "Energy") or "Mana"):upper()) end
    if p.mini then RF:PaintLiquid(p.mini, s, pal) end
    -- edges that warm while rage is over the line
    local hot = line and fc > line
    if p.cardEdge then
        for _, e in ipairs(p.cardEdge) do
            if hot then e:SetVertexColor(1, 0.67, 0.35, 0.7) else e:SetVertexColor(S:Color("HAIRLINE")) end
        end
    end
    if p.rim then
        if hot then p.rim:SetVertexColor(light[1], light[2], light[3], 0.55) else p.rim:SetVertexColor(0.91, 0.89, 0.82, 0.18) end
    end
    -- capping: a glow that pulses
    p.capGlow:SetAlpha(s.cap and (0.35 + 0.45 * Pulse(o.now)) or 0)
    -- combo points (#27)
    for i, t in ipairs(p.cp) do
        local show = s.cp ~= nil
        t:SetShown(show)
        if t.ring then t.ring:SetShown(show) end
        if show then
            local on = i <= s.cp
            if g.cp == "classic" then
                if on then t:SetVertexColor(1, 0.45, 0.1, 1) else t:SetVertexColor(1, 1, 1, 0.12) end
            elseif on then t:SetVertexColor(S:Color("GOLD"))
            else t:SetVertexColor(1, 1, 1, 0.12) end
            if t.ring and g.cp == "gild" then
                if on then t.ring:SetVertexColor(0.91, 0.76, 0.35, 1) else t.ring:SetVertexColor(0.63, 0.48, 0.15, 1) end
            end
        end
    end
    -- druid mana under the forms, a mark per shapeshift it pays for
    local mana = s.mana
    p.mana0:SetShown(mana ~= nil)
    if mana then
        local f = max(0, min(1, mana.pct / 100))
        if f > 0.001 then
            p.mana:Show()
            face:Put(p.mana, face.bx + 2, face.manaY, (face.len - 4) * f, 3)
            ShadeAcross(p.mana, self.PAL.mana.under, vert)
        else
            p.mana:Hide()
        end
        local k, i = mana.shift, 0
        while k and k > 0 and k < 100 and i < 8 do
            i = i + 1
            local mt = p.manaMarks[i] or Part(face.root, "ARTWORK", WHITE, 1, 1, 1, 1, 3)
            p.manaMarks[i] = mt
            mt:Show()
            face:Put(mt, face.bx + 2 + (face.len - 4) * k / 100 - 0.5, face.manaY, 1, 3)
            if mana.pct >= k then mt:SetVertexColor(0, 0, 0, 0.6) else mt:SetVertexColor(1, 1, 1, 0.3) end
            k = k + mana.shift
        end
        for j = i + 1, #p.manaMarks do p.manaMarks[j]:Hide() end
    else
        p.mana:Hide()
        for _, mt in ipairs(p.manaMarks) do mt:Hide() end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Liquid (the globes, the Gilded holder): the warrior globe's art (Media/Warrior, art pack 14) in any colour
-- ---------------------------------------------------------------------------------------------------------------
function RF:Liquid(parent, D, square)
    local gl = CreateFrame("Frame", nil, parent)
    gl:SetSize(D, D)
    gl.D, gl.square = D, square
    local mask
    if not square and gl.CreateMaskTexture then
        mask = gl:CreateMaskTexture()
        mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints()
    end
    local art = ns.HasAssets and ns:HasAssets(14)
    gl.art = art
    local function T(layer, path, sub, add)
        local t = Part(gl, layer, path or WHITE, nil, nil, nil, nil, sub)
        if add then t:SetBlendMode("ADD") end
        if mask then t:AddMaskTexture(mask) end
        return t
    end
    gl.back = T("BACKGROUND")
    gl.back:SetAllPoints()
    UI:GradientRGBA(gl.back, "VERTICAL", 0.03, 0.02, 0.02, 1, 0.08, 0.06, 0.05, 1)
    gl.liq = T("BORDER", art and FLUID or WHITE, 0)
    gl.over = T("BORDER", art and FLUID or WHITE, 1)
    gl.held = T("ARTWORK", WHITE, 0)
    gl.ghost = T("ARTWORK", WHITE, 1)
    gl.men = T("ARTWORK", WHITE, 3)
    gl.surf = T("ARTWORK", SOFT, 2, true)
    gl.hsl = T("OVERLAY", WHITE, 1)
    if art then
        gl.shade = T("OVERLAY", square and TANK_SHADE or GLASS_SHADE, 2)
        gl.shade:SetAllPoints()
        gl.spec = T("OVERLAY", square and TANK_SPEC or GLASS_SPEC, 3, true)
        gl.spec:SetAllPoints()
    else
        gl.shine = T("OVERLAY", SOFT, 3, true)
        gl.shine:SetVertexColor(1, 1, 1, 0.25)
        gl.shine:SetPoint("CENTER", gl, "CENTER", -D * 0.16, D * 0.22)
        gl.shine:SetSize(D * 0.55, D * 0.35)
    end
    return gl
end

local function Band(gl, t, f0, f1)
    local D = gl.D
    f0, f1 = max(0, min(1, f0)), max(0, min(1, f1))
    if f1 - f0 <= 0.002 then t:Hide() return end
    t:Show()
    t:ClearAllPoints()
    t:SetPoint("BOTTOMLEFT", gl, "BOTTOMLEFT", 0, D * f0)
    t:SetSize(D, D * (f1 - f0))
    if gl.art and (t == gl.liq or t == gl.over) then t:SetTexCoord(0, 1, 1 - f1, 1 - f0) end
end

-- flat: Slate's flat colours, no glass.
function RF:PaintLiquid(gl, s, pal, flat)
    local mx = max(1, s.mx)
    local cur = s.v - (s.held or 0)
    local fc, fv = cur / mx, s.v / mx
    local line = s.line and s.line / mx
    local liq = flat and pal.under or pal.liq
    if gl.art and not flat then
        gl.liq:SetVertexColor(liq[1][1], liq[1][2], liq[1][3], 1)
        local o = pal.over or pal.liq
        gl.over:SetVertexColor(o[1][1], o[1][2], o[1][3], 1)
    elseif flat then
        gl.liq:SetColorTexture(liq[2][1], liq[2][2], liq[2][3], 1)
        local o = pal.over or pal.under
        gl.over:SetColorTexture(o[2][1], o[2][2], o[2][3], 1)
    else
        UI:GradientRGBA(gl.liq, "VERTICAL", liq[3][1], liq[3][2], liq[3][3], 1, liq[1][1], liq[1][2], liq[1][3], 1)
        local o = pal.over or pal.liq
        UI:GradientRGBA(gl.over, "VERTICAL", o[3][1], o[3][2], o[3][3], 1, o[1][1], o[1][2], o[1][3], 1)
    end
    local top = (line and fc > line) and line or fc
    Band(gl, gl.liq, 0, top)
    if line and fc > line then Band(gl, gl.over, line, fc) else gl.over:Hide() end
    if s.held and s.held > 0 then
        Band(gl, gl.held, fc, fv)
        gl.held:SetVertexColor(0, 0, 0, 0.55)
    else
        gl.held:Hide()
    end
    local ghost = s.ghost or s.swing
    if ghost and ghost > 0 and fv < 1 then
        Band(gl, gl.ghost, fv, (s.v + ghost) / mx)
        gl.ghost:SetVertexColor(pal.light[1], pal.light[2], pal.light[3], 0.3)
    else
        gl.ghost:Hide()
    end
    local D = gl.D
    if fc > 0.02 and fc < 0.99 then
        gl.men:Show(); gl.surf:SetShown(not flat)
        gl.men:ClearAllPoints()
        gl.men:SetPoint("BOTTOMLEFT", gl, "BOTTOMLEFT", 0, D * fc - 0.5)
        gl.men:SetSize(D, 1)
        gl.men:SetVertexColor(pal.light[1], pal.light[2], pal.light[3], flat and 0.6 or 0.8)
        gl.surf:ClearAllPoints()
        gl.surf:SetPoint("CENTER", gl, "BOTTOM", 0, D * fc - D * 0.02)
        gl.surf:SetSize(D * 1.1, D * 0.12)
        gl.surf:SetVertexColor(pal.light[1], pal.light[2], pal.light[3], 0.45)
    else
        gl.men:Hide(); gl.surf:Hide()
    end
    if line then
        gl.hsl:Show()
        gl.hsl:ClearAllPoints()
        gl.hsl:SetPoint("BOTTOMLEFT", gl, "BOTTOMLEFT", 0, D * line - 0.5)
        gl.hsl:SetSize(D, 1)
        local lit = fc > line
        gl.hsl:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], lit and 0.9 or 0.45)
    else
        gl.hsl:Hide()
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The globe shape, per theme
-- ---------------------------------------------------------------------------------------------------------------
RF.GLOBE = {
    halo = { S = 70, D = 54, ring = { 31.5, 34.3, 60 }, cp = "disc", cpR = 41 },
    sigil = { S = 60, D = 48, square = true, cp = "sq" },
    slate = { S = 62, D = 52, flat = true, ring = { 28, 29.2, 72 }, cp = "dash" },
    gilded = { S = 68, D = 41, ring = { 25.6, 28, 60 }, gold = true, cp = "gild", cpR = 41 },
    pips = { S = 64, D = 0, pips = 27, ring = { 17.2, 18.8, 48 }, cp = "pip" },
    classic = { S = 78, D = 34, game = true, ring = { 15.6, 17, 48 }, cp = "classic", cpR = 41 },
}

local function BuildGlobe(parent, theme)
    local g = RF.GLOBE[theme] or RF.GLOBE.halo
    local root = CreateFrame("Frame", nil, parent)
    local Sz = g.S
    local face = setmetatable({ root = root, theme = theme, shape = "globe", gg = g, g = RF.BAR[theme] }, Face)
    local p = {}
    face.p = p
    local c = Sz / 2
    local cpRow = (g.cpR == nil) and 12 or 12
    root:SetSize(Sz, Sz + cpRow)
    face.W, face.H = Sz, Sz + cpRow
    p.capGlow = Part(root, "BACKGROUND", SOFT, 1, 0.56, 0.2, 0, -8)
    p.capGlow:SetBlendMode("ADD")
    p.capGlow:SetPoint("CENTER", root, "TOPLEFT", c, -c)
    p.capGlow:SetSize(Sz * 1.9, Sz * 1.9)
    if theme == "halo" then
        p.well = Part(root, "BACKGROUND", DISC, 0, 0, 0, 0.62, -6)
        p.well:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.well:SetSize(Sz, Sz)
    elseif theme == "sigil" then
        p.well = Part(root, "BACKGROUND", WHITE, 0, 0, 0, 1, -6)
        p.well:SetPoint("TOPLEFT"); p.well:SetSize(Sz, Sz)
        p.ring = SquareCells(root, c, c, Sz / 2 - 2.5, 3, 56, "BORDER", 0)
        p.inner = Part(root, "BORDER", WHITE, 0, 0, 0, 1, 2)
        p.inner:SetPoint("TOPLEFT", 4, -4); p.inner:SetSize(Sz - 8, Sz - 8)
        p.edge = Part(root, "OVERLAY", WHITE, 0.91, 0.89, 0.82, 0.3, 5)
    elseif theme == "slate" then
        p.well = Part(root, "BACKGROUND", DISC, 0.047, 0.047, 0.059, 0.84, -6)
        p.well:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.well:SetSize(Sz, Sz)
        p.edge = Part(root, "BACKGROUND", RINGTEX, 1, 1, 1, 0.12, -5)
        p.edge:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.edge:SetSize(Sz + 1, Sz + 1)
        p.label = UI:Text(root, "caps", { 0.81, 0.78, 0.68 }, { font = NARROW })
        UI:SetTextSize(p.label, 7)
        p.label:SetPoint("CENTER", root, "TOPLEFT", c, -c - 9)
    elseif theme == "gilded" then
        p.well = Part(root, "BACKGROUND", DISC, 0, 0, 0, 1, -7)
        p.well:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.well:SetSize(Sz + 2, Sz + 2)
        p.bezel = Bezel(root, "BACKGROUND", Sz, -6)
        p.bezel:SetPoint("CENTER", root, "TOPLEFT", c, -c)
        p.groove = Part(root, "BORDER", DISC, 0.08, 0.055, 0.016, 1, -1)
        p.groove:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.groove:SetSize(Sz - 8, Sz - 8)
        p.inner = Part(root, "BORDER", DISC, 0, 0, 0, 1, 1)
        p.inner:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.inner:SetSize(g.D + 6, g.D + 6)
        p.bezel2 = Bezel(root, "ARTWORK", g.D + 5, 6)
        p.bezel2:SetPoint("CENTER", root, "TOPLEFT", c, -c)
    elseif theme == "pips" then
        p.dial = {}
        local R = g.pips
        for i = 1, 20 do
            local a = pi / 2 - 2 * pi * (i - 0.5) / 20
            local back = root:CreateLine(nil, "BORDER")
            back:SetColorTexture(0, 0, 0, 1)
            back:SetThickness(7)
            back:SetStartPoint("TOPLEFT", root, c + (R - 5.5) * cos(a), -c + (R - 5.5) * sin(a))
            back:SetEndPoint("TOPLEFT", root, c + (R + 5.5) * cos(a), -c + (R + 5.5) * sin(a))
            local l = root:CreateLine(nil, "ARTWORK")
            l:SetColorTexture(1, 1, 1, 1)
            l:SetThickness(5)
            l:SetStartPoint("TOPLEFT", root, c + (R - 4.5) * cos(a), -c + (R - 4.5) * sin(a))
            l:SetEndPoint("TOPLEFT", root, c + (R + 4.5) * cos(a), -c + (R + 4.5) * sin(a))
            p.dial[i] = l
        end
    elseif theme == "classic" then
        p.well = Part(root, "BACKGROUND", DISC, 0, 0, 0, 0.75, -6)
        p.well:SetPoint("CENTER", root, "TOPLEFT", c, -c); p.well:SetSize(g.D + 2, g.D + 2)
        -- (the tracking border: its ring's middle 19.5 px in from its top left, the hole 17 px across)
        local k = (g.D + 3) / 17
        p.track = root:CreateTexture(nil, "OVERLAY", nil, 4)
        ns.Look:GameTex(p.track, "tracking")
        p.track:SetSize(64 * k, 64 * k)
        p.track:SetPoint("TOPLEFT", root, "TOPLEFT", c - 19.5 * k, -(c - 19.5 * k))
    end
    if g.ring then
        local r = g.ring
        p.ring = p.ring or Strokes(root, c, c, r[1], r[2], r[3], "BORDER", 3)
    end
    if g.D > 0 then
        local D = g.square and (Sz - 12) or g.D
        p.liq = RF:Liquid(root, D, g.square)
        p.liq:SetFrameLevel(root:GetFrameLevel() + 1)
        p.liq:SetPoint("CENTER", root, "TOPLEFT", c, -c)
        face.D = D
        if p.edge and g.square then
            p.edge:SetPoint("TOPLEFT", p.liq, "TOPLEFT"); p.edge:SetPoint("BOTTOMRIGHT", p.liq, "BOTTOMRIGHT")
            p.edge:SetAlpha(0)       -- (the inner outline: a 1 px edge drawn by four lines would do; the tank's art has one)
        end
    end
    -- over the liquid: notches, the number
    local over = CreateFrame("Frame", nil, root)
    over:SetAllPoints()
    over:SetFrameLevel(root:GetFrameLevel() + 3)
    face.over = over
    p.notches = {}
    p.num = UI:Text(over, "page", { 1, 0.95, 0.84 }, { font = (theme == "slate" or theme == "pips" or theme == "classic") and NARROW or nil,
                                                   flags = "OUTLINE" })
    p.num:SetPoint("CENTER", root, "TOPLEFT", c, -c)
    UI:SetTextSize(p.num, theme == "classic" and 11 or 13)
    p.cp = {}
    for i = 1, 5 do
        local t
        if g.cp == "disc" or g.cp == "gild" or g.cp == "classic" then
            t = Part(over, "ARTWORK", DISC, nil, nil, nil, nil, 2)
            t.ring = Part(over, "ARTWORK", DISC, 0, 0, 0, 1, 1)
        else
            t = Part(over, "ARTWORK", WHITE, nil, nil, nil, nil, 2)
            t.ring = Part(over, "ARTWORK", WHITE, 0, 0, 0, 1, 1)
        end
        local size = (g.cp == "gild" or g.cp == "classic") and 8 or g.cp == "pip" and 6 or g.cp == "dash" and 2 or 7
        local w = g.cp == "dash" and 12 or size
        local x, y
        if g.cpR then
            local a = pi / 2 + (2 - (i - 1)) * 15 * pi / 180
            x, y = c + g.cpR * cos(a), c + g.cpR * sin(a)
        else
            local step = w + (g.cp == "pip" and 1 or 3)
            x, y = c - 2 * step + (i - 1) * step, Sz + 5
        end
        t:SetSize(w, size)
        t:SetPoint("CENTER", root, "TOPLEFT", x, -y)
        local grow = g.cp == "gild" and 2 or 1
        t.ring:SetSize(w + 2 * grow, size + 2 * grow)
        t.ring:SetPoint("CENTER", t, "CENTER")
        p.cp[i] = t
    end
    p.mana0 = Part(over, "ARTWORK", WHITE, 0, 0, 0, 0.62, 0)
    p.mana0:SetSize(Sz - 16, 3)
    p.mana0:SetPoint("TOP", root, "TOPLEFT", c, -(Sz + 1))
    p.mana = Part(over, "ARTWORK", WHITE, 1, 1, 1, 1, 1)
    return face
end

function RF:PaintGlobe(face, s, o)
    local g, p = face.gg, face.p
    local pal = self:Palette(s.kind, o.color, o.class, o.own)
    local mx = max(1, s.mx)
    local cur = s.v - (s.held or 0)
    local c = g.S / 2
    if p.liq then
        if g.game then
            -- (Classic: the game's colour, flat)
            local gc = pal.game
            local flatPal = { under = { gc, gc, gc }, over = pal.over, light = pal.light, liq = { gc, gc, gc } }
            self:PaintLiquid(p.liq, s, flatPal, true)
        else
            self:PaintLiquid(p.liq, s, pal, g.flat)
        end
    end
    if p.dial then
        local fc, fv = cur / mx, s.v / mx
        local line = s.line and s.line / mx
        local ghost = s.ghost or s.swing or 0
        for i, l in ipairs(p.dial) do
            local u = i * 5 / 100
            if fc >= u - 0.025 then
                local col = (line and u > line and pal.over) and pal.over[2] or pal.under[2]
                l:SetVertexColor(col[1], col[2], col[3], 1)
            elseif fv >= u - 0.025 then
                l:SetVertexColor(pal.light[1] * 0.45, pal.light[2] * 0.45, pal.light[3] * 0.45, 1)
            elseif (s.v + ghost) / mx >= u - 0.025 then
                l:SetVertexColor(pal.light[1], pal.light[2], pal.light[3], 0.35)
            else
                l:SetVertexColor(1, 1, 1, 0.1)
            end
        end
    end
    local phase = (o.tick ~= "off") and (s.rule or s.tick) or nil
    if p.ring then PaintTimer(p.ring, phase, pal.light, s.rule, g.gold and GOLD or nil) end
    -- notches: the marks (and the Heroic Strike line) on the left rim
    local items = {}
    if o.marks ~= "off" then
        for _, mk in ipairs(s.marks) do items[#items + 1] = { cost = mk.cost, lit = cur >= mk.cost } end
        if s.line then items[#items + 1] = { cost = s.line, lit = cur > s.line, gold = true } end
    end
    local D = face.D or (g.pips and (g.pips - 6) * 2) or g.D
    local R = D / 2
    for i, it in ipairs(items) do
        local t = p.notches[i] or Part(face.over, "OVERLAY", WHITE, 1, 1, 1, 1, 4)
        p.notches[i] = t
        local f = it.cost / mx
        if f <= 0 or f >= 1 then
            t:Hide()
        else
            t:Show()
            local yy = R - 2 * R * f                -- (from the middle, down positive)
            local half = g.square and R or math.sqrt(max(0, R * R - yy * yy))
            t:ClearAllPoints()
            t:SetSize(5, it.gold and 2 or 1.5)
            t:SetPoint("RIGHT", face.root, "TOPLEFT", c - half + 2, -(c + yy))
            local col = it.gold and (it.lit and GOLD or { 0.54, 0.42, 0.11 }) or (it.lit and { 1, 0.91, 0.63 } or DIM)
            t:SetVertexColor(col[1], col[2], col[3], 1)
        end
    end
    for i = #items + 1, #p.notches do p.notches[i]:Hide() end
    -- the number
    local text = NumText(s, o)
    if o.num == "bar" then text = NumText(s, { num = "ring" }) end
    if g.game and text and o.num == "full" then text = tostring(floor(s.v + 0.5)) end
    p.num:SetShown(text ~= nil)
    p.num:SetText(text or "")
    if s.cap then p.num:SetTextColor(1, 0.7, 0.36)
    elseif g.flat or g.pips then p.num:SetTextColor(pal.light[1], pal.light[2], pal.light[3])
    else p.num:SetTextColor(1, 0.95, 0.84) end
    if p.label then p.label:SetText(((s.kind == "rage" and "Rage") or (s.kind == "energy" and "Energy") or "Mana"):upper()) end
    p.capGlow:SetAlpha(s.cap and (0.3 + 0.4 * Pulse(o.now)) or 0)
    for i, t in ipairs(p.cp) do
        local show = s.cp ~= nil
        t:SetShown(show); t.ring:SetShown(show)
        if show then
            local on = i <= s.cp
            if g.cp == "classic" then
                if on then t:SetVertexColor(1, 0.45, 0.1, 1) else t:SetVertexColor(1, 1, 1, 0.12) end
            elseif on then t:SetVertexColor(S:Color("GOLD")) else t:SetVertexColor(1, 1, 1, 0.12) end
            if g.cp == "gild" then
                if on then t.ring:SetVertexColor(0.91, 0.76, 0.35, 1) else t.ring:SetVertexColor(0.63, 0.48, 0.15, 1) end
            end
        end
    end
    local mana = s.mana
    p.mana0:SetShown(mana ~= nil and s.cp == nil)
    if mana and s.cp == nil then
        local f = max(0, min(1, mana.pct / 100))
        p.mana:SetShown(f > 0.001)
        p.mana:ClearAllPoints()
        p.mana:SetPoint("TOPLEFT", p.mana0, "TOPLEFT")
        p.mana:SetSize(max(0.01, (g.S - 16) * f), 3)
        ShadeAcross(p.mana, self.PAL.mana.under, false)
    else
        p.mana:Hide()
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------------------------------------------
function RF:Build(parent, theme, shape)
    if shape == "globe" then return BuildGlobe(parent, theme) end
    return BuildBar(parent, theme, shape == "upright")
end

function RF:Paint(face, s, o)
    if not (face and s) then return end
    if face.shape == "globe" then self:PaintGlobe(face, s, o) else self:PaintBar(face, s, o) end
end

-- The default length of a theme's bar (Edit layout stretches it from there).
function RF:DefaultLength(theme) return (self.BAR[theme] or self.BAR.halo).len end

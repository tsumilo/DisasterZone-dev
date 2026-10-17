if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RingFace.lua", ...) then return end -- DisasterZone: timer ring faces.
-- The looks of the timer ring (ns.SwingRing, UI/SwingTimerHUD.lua: the Ret swing timer and the Hunter shot timer) in
-- the class tool themes. Mockup dev/art/casc/timer_themes/build_timer_themes.py (the user approved it 2026-10-13).
-- The rule, as for the bars (UI/BarFace.lua): the parts and their colours never change, only the face.
--   halo    the ring of 200 flat strokes around the round next press (as built before the themes)
--   sigil   a square action-button tile: the cycle runs round its square frame
--   slate   a quiet glass card: the next press on the left, the cycle a flat bar beside it, the queue small above it
--   gilded  the ring inside a gold bezel (Media/Blessings/bezel, art pack 7), the cycle in its groove
--   pips    small and dense: a 28 px next press over a row of 20 pips
--   classic the swing drawn as the game draws a cast (UI/Look.lua's Classic): the cast bar's border round the cycle
--           in its status bar texture, its spark at the swing, the next press an action button with the spell alert
--           while its window is open, the presses after it small above the bar, the badge in a minimap button's ring
-- Each timer has its own (<prefix>.theme, kind "ring_<prefix>", default Halo); a hovered tile previews. Twist practice
-- always uses Halo (its parts sit round it).
--   RingFace:BuildFace(parent, key)    the face: { root (= the ring frame: .dots, .head, .tip, .glow, .flash),
--                                       big, seal, small[3], geo }
--   RingFace:BuildLane(parent, key)    the lane: the lane frame (.W, .bg, .ticks, .windows, .blocks, .now, .gain)
--   RingFace:Paint(face, p)            colours the cycle: p { frac, z0, z1, s0, hot, inZone, pulse, fade }
--   RingFace:Key(prefix, practicing)   the theme key a timer wears now
--   RingFace:BuildChip(parent)         the situation chip (Core/Situation.lua) under the face; PaintChip colours it
-- A press's icon (big, small[i]) carries .stance: the stance it needs (warrior stance dancing), :Set(texture | nil).
local addonName, ns = ...

local RF = { rings = {} }
ns.RingFace = RF

local UI = ns.UI
local S = ns.Style

local floor, max, min, pi, cos, sin = math.floor, math.max, math.min, math.pi, math.cos, math.sin

local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local RINGTEX = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\ring"
local BEZEL = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\bezel"
local NARROW = S.FONT_NUM
local ZONE = { 1.0, 0.56, 0.20 }

-- The faces' measures (the mockup's, at 1x). path: how the cycle runs; R / half: its middle line; band: its
-- thickness; N: cells; big / badge: { size, x, y } from the face's centre; queue: where the next presses sit.
RF.GEO = {
    halo = { W = 128, H = 128, path = "circle", R = 54, band = 6, N = 200, round = true,
             big = { 70, 0, 0 }, badge = { 22, 38.9, -38.9 }, queue = "left", queueGap = 4, glow = 1.9,
             lane = { 500, 46 } },
    sigil = { W = 110, H = 110, path = "square", half = 51, band = 6, N = 160,
              big = { 92, 0, 0 }, badge = { 26, 43, -43 }, queue = "left", queueGap = 6, glow = 1.7,
              lane = { 500, 46 } },
    slate = { W = 230, H = 46, path = "bar", x0 = -65, len = 150, y = -5, band = 8, N = 75,
              big = { 36, -92, 0 }, badge = { 17, 101, 0 }, queue = "top", queueAt = { 150, -6, 13, 16 },
              name = { 50, -6 }, lane = { 500, 40 } },
    gilded = { W = 128, H = 128, path = "circle", R = 51, band = 6, N = 200, round = true,
               big = { 84, 0, 0 }, badge = { 22, 45, -45 }, queue = "left", queueGap = 6, glow = 1.8, bezel = true,
               lane = { 500, 48 } },
    pips = { W = 150, H = 44, path = "pips", x0 = -75, step = 7.5, y = -17, N = 20,
             big = { 28, -60, 7 }, badge = { 12, -47, 20 }, queue = "top", queueAt = { 42, -8, 16, 19 },
             lane = { 320, 26 }, small = true },
    -- (the border's inside, x 65..280 and 17 tall round y -8, is the cycle; the border reaches 9 / 10 px past it)
    classic = { W = 290, H = 62, path = "bar", x0 = -80, len = 215, y = -8, band = 17, N = 72, game = true,
                big = { 44, -123, -8 }, badge = { 16, 131, -8 }, queue = "top", queueAt = { 65, -1, 20, 24 },
                name = { 71, -34 }, lane = { 500, 40 } },
}

-- Variants of a face (BuildFace's third argument): fields over the theme's GEO. The warrior's (Core/WarriorSwing.lua,
-- mockup dev/art/casc/warrior_mockup):
--   oh       the off-hand cycle: the main cycle's path with these fields (R / half / y, band, N, pip)
--   globe    { size, size with no off hand } of the rage globe in the middle (round and tile themes; square = a tank)
--   rage     instead of a globe: { kind = "bar" | "pips", y, h, num } a third row under the swings (flat themes)
--   lamp     { size, x, y } the Heroic Strike lamp (round / tile themes: on the main-hand landing point)
--   padL     room the face takes left of its frame (the next press and the queue sit there): the frame grows by it
--   queueFromBig  the queue continues left of the next press (instead of left of the ring)
RF.VARIANT = {
    warrior = {
        halo = { big = { 36, -86, 0 }, queueFromBig = true, queueGap = 5, oh = { R = 45, band = 4, N = 150 },
                 globe = { 74, 86 }, lamp = { 18, 0, 57 }, padL = 100 },
        sigil = { big = { 36, -82, 0 }, queueFromBig = true, queueGap = 6, oh = { half = 44, band = 4, N = 140 },
                  globe = { 78, 90 }, square = true, lamp = { 18, 0, 55 }, padL = 106 },
        gilded = { big = { 34, -82, 0 }, queueFromBig = true, queueGap = 8, oh = { R = 43, band = 4, N = 150 },
                   globe = { 70, 80 }, lamp = { 18, 0, 54 }, padL = 104, bigBezel = true },
        slate = { W = 250, H = 54, x0 = -75, len = 150, y = 1, big = { 36, -101, 0 }, badge = { 17, 112, 6 },
                  name = { 50, -7 }, queueAt = { 140, -5, 13, 16 }, oh = { y = -8, band = 4 },
                  rage = { kind = "bar", y = -17, h = 6, num = true }, lamp = { 14, 71, 16 } },
        pips = { H = 58, y = -13, big = { 28, -60, 14 }, badge = { 12, -47, 27 }, oh = { y = -19.5, pip = { 5, 2 } },
                 rage = { kind = "pips", y = -26 }, lamp = { 14, 65, 14 } },
        classic = { W = 330, H = 86, y = 4, big = { 44, -123, -6 }, badge = { 16, 131, 4 }, oh = { y = -14, band = 7 },
                    rage = { kind = "bar", y = -29, h = 9, num = true }, lamp = { 18, 154, -22 } },
    },
}

-- The timer themes: the class tool themes' names, with tips for a timer.
RF.THEMES = {
    { key = "halo", name = "Halo", tip = "A ring of flat strokes around the round next press." },
    { key = "sigil", name = "Sigil", tip = "A square action-button tile: the cycle runs round its frame." },
    { key = "slate", name = "Slate", tip = "A quiet glass card with the cycle as a flat bar. Calmest look." },
    { key = "gilded", name = "Gilded", tip = "The ring in a worked gold bezel, the next press gold-rimmed." },
    { key = "pips", name = "Pips", tip = "Small and dense: a little next press over a row of 20 pips." },
    { key = "classic", name = "Classic", tip = "The swing as the game's cast bar: its border and spark, the next press an action button." },
}

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
    t:SetPoint("CENTER")
    t:SetSize(size, size)
    return t
end

-- The next press's name under it when the press sits beside the ring (the warrior's faces): centred under the icon,
-- pushed left as far as it has to so it never runs into the ring ("Sweeping Strikes" is wider than the room).
function RF:FitName(face)
    local g, big = face.geo, face.big
    if not (g.queueFromBig and big.under) then return end
    local w = UI:TextWidth(big.name)
    if w == big.fitW then return end
    big.fitW = w
    local room = -g.W / 2 - g.big[2] - 4          -- from the press's centre to the ring's left edge
    big.name:ClearAllPoints()
    big.name:SetPoint("TOP", big, "BOTTOM", -max(0, floor(w / 2 - room + 0.5)), -3)
end

-- The stance a press needs (the warrior's stance dancing, Core/WarriorSwing.lua): the stance's icon small in the
-- press's bottom-left corner, rimmed gold on black. m:Set(texture) shows it, m:Set(nil) hides it.
local STANCE_RIM = { 0.79, 0.64, 0.15 }
local function StanceMark(holder, size)
    local m = {}
    m.out = Part(holder, "OVERLAY", WHITE, 0, 0, 0, 1, 4)
    m.rim = Part(holder, "OVERLAY", WHITE, STANCE_RIM[1], STANCE_RIM[2], STANCE_RIM[3], 1, 5)
    m.icon = Part(holder, "OVERLAY", WHITE, nil, nil, nil, nil, 6)
    m.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    m.icon:SetSize(size, size)
    m.icon:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", -floor(size * 0.25), -floor(size * 0.25))
    m.rim:SetPoint("TOPLEFT", m.icon, "TOPLEFT", -1, 1)
    m.rim:SetPoint("BOTTOMRIGHT", m.icon, "BOTTOMRIGHT", 1, -1)
    m.out:SetPoint("TOPLEFT", m.icon, "TOPLEFT", -2, 2)
    m.out:SetPoint("BOTTOMRIGHT", m.icon, "BOTTOMRIGHT", 2, -2)
    function m:Set(tex)
        if tex then self.icon:SetTexture(tex) end
        local on = tex ~= nil
        if self.shown == on then return end
        self.shown = on
        self.icon:SetShown(on); self.rim:SetShown(on); self.out:SetShown(on)
    end
    m.shown = true
    m:Set(nil)
    return m
end
RF.StanceMark = StanceMark

-- A point on the cycle at f (0..1), `off` out from its middle line (WoW coordinates from the face's centre).
function RF.Pos(g, f, off)
    off = off or 0
    if g.path == "circle" then
        local a = pi / 2 - 2 * pi * f
        local r = g.R + off
        return r * cos(a), r * sin(a)
    elseif g.path == "square" then
        local h = g.half
        local s = f * 8 * h
        if s < h then return s, h + off
        elseif s < 3 * h then return h + off, h - (s - h)
        elseif s < 5 * h then return h - (s - 3 * h), -h - off
        elseif s < 7 * h then return -h - off, -h + (s - 5 * h)
        else return -h + (s - 7 * h), h + off end
    elseif g.path == "pips" then
        return g.x0 + f * g.N * g.step, g.y + off
    end
    return g.x0 + f * g.len, g.y + off
end

-- ---------------------------------------------------------------------------------------------------------------
-- The face
-- ---------------------------------------------------------------------------------------------------------------
-- A cycle's cells: g.N along g's path, `layer` (the main cycle ARTWORK; the off-hand's OVERLAY, over the frames
-- drawn inside the main one). Pips are g.pip = { w, h } (back 2 px larger), default 5 x 4.
local function Cells(ring, g, layer, sub)
    local dots = {}
    local pw, ph = (g.pip and g.pip[1]) or 5, (g.pip and g.pip[2]) or 4
    for i = 1, g.N do
        local f = (i - 0.5) / g.N
        local d
        if g.path == "circle" then
            d = ring:CreateLine(nil, layer, nil, sub)
            d:SetColorTexture(1, 1, 1, 1)
            d:SetThickness(2 * pi * (g.R + g.band / 2) / g.N + 0.7)   -- (a little overlap: no gaps on the outer edge)
            local x0, y0 = RF.Pos(g, f, -g.band / 2)
            local x1, y1 = RF.Pos(g, f, g.band / 2)
            d:SetStartPoint("CENTER", ring, x0, y0)
            d:SetEndPoint("CENTER", ring, x1, y1)
        elseif g.path == "pips" then
            local back = Part(ring, layer == "ARTWORK" and "BORDER" or layer, WHITE, 0, 0, 0, 1, layer == "ARTWORK" and 0 or sub)
            back:SetSize(pw + 2, ph + 2)
            local x, y = RF.Pos(g, (i - 1) / g.N)
            back:SetPoint("CENTER", ring, "CENTER", x + 3.5, y)
            d = Part(ring, layer, WHITE, nil, nil, nil, nil, (sub or 0) + 1)
            d:SetSize(pw, ph)
            d:SetPoint("CENTER", back, "CENTER")
            d.back = back
        else
            d = Part(ring, layer, g.game and ns.Look.SBAR or WHITE, nil, nil, nil, nil, sub)
            local x, y = RF.Pos(g, f)
            if g.path == "square" then
                local cell = 8 * g.half / g.N + 0.6
                local s = f * 8
                local vertical = (s >= 1 and s < 3) or (s >= 5 and s < 7)
                if vertical then d:SetSize(g.band, cell) else d:SetSize(cell, g.band) end
            else
                d:SetSize(g.len / g.N + 0.5, g.band)
            end
            d:SetPoint("CENTER", ring, "CENTER", x, y)
        end
        d.f = f
        dots[i] = d
    end
    return dots
end

local function Merge(base, over)
    local g = {}
    for k, v in pairs(base) do g[k] = v end
    for k, v in pairs(over or {}) do g[k] = v end
    return g
end

-- variant (optional): "warrior" adds the off-hand cycle, the rage globe / bar and the Heroic Strike lamp
-- (RF.VARIANT; painted by PaintExtra).
function RF:BuildFace(parent, key, variant)
    local g = self.GEO[key] or self.GEO.halo
    if variant and self.VARIANT[variant] then
        local v = self.VARIANT[variant]
        key = v[key] and key or "halo"
        g = Merge(self.GEO[key], v[key])
    end
    local face = { key = key, geo = g, variant = variant }
    local ring = CreateFrame("Frame", nil, parent)
    ring:SetSize(g.W, g.H)
    face.root = ring
    local big0 = max(g.W, g.H)

    ring.glow = Part(ring, "BACKGROUND", SOFT, ZONE[1], ZONE[2], ZONE[3], 0, -8)
    ring.glow:SetBlendMode("ADD")
    ring.glow:SetPoint("CENTER")
    ring.glow:SetSize(g.glow and g.W * g.glow or 1, g.glow and g.H * g.glow or 1)
    ring.flash = Part(ring, "BACKGROUND", SOFT, 1, 0.86, 0.5, 0, 2)
    ring.flash:SetBlendMode("ADD")
    ring.flash:SetPoint("CENTER")
    ring.flash:SetSize(g.W * (g.glow or 1.2), g.H * (g.glow or 2))

    -- the ground under the cycle
    if key == "halo" then
        ring.well = Part(ring, "BACKGROUND", DISC, 0, 0, 0, 0.55, -6)
        ring.well:SetPoint("CENTER")
        ring.well:SetSize(g.R * 2 + 12, g.R * 2 + 12)
    elseif key == "gilded" then
        ring.well = Part(ring, "BACKGROUND", DISC, 0, 0, 0, 1, -7)
        ring.well:SetPoint("CENTER")
        ring.well:SetSize(g.W + 2, g.W + 2)
        ring.bezel = Bezel(ring, "BACKGROUND", g.W, -6)
        ring.groove = Part(ring, "BACKGROUND", DISC, 0.08, 0.055, 0.016, 1, -5)
        ring.groove:SetPoint("CENTER")
        ring.groove:SetSize(g.W - 18, g.W - 18)
    elseif key == "sigil" then
        ring.well = Part(ring, "BACKGROUND", WHITE, 0, 0, 0, 1, -7)
        ring.well:SetAllPoints()
    elseif key == "slate" then
        ring.well = UI:Fill(ring, { 0.047, 0.047, 0.059, 0.84 }, "BACKGROUND", -7)
        UI:AddEdges(ring, "BACKGROUND")
        UI:SetEdgeColor(ring, 1, 1, 1, 0.09)
        local sh = Part(ring, "BACKGROUND", WHITE, 0, 0, 0, 0.8, -4)
        sh:SetSize(g.len + 2, g.band + 2)
        sh:SetPoint("CENTER", ring, "CENTER", g.x0 + g.len / 2, g.y)
    end

    -- the cycle: N cells along its path, coloured by Paint
    ring.dots = Cells(ring, g, "ARTWORK")
    ring.head = Part(ring, "OVERLAY", SOFT, 1, 0.92, 0.66, 0.9)
    ring.head:SetBlendMode("ADD")
    local hs = g.path == "bar" and 22 or 30
    ring.head:SetSize(hs, hs)
    if g.game then
        ring.head:SetTexture(ns.Look.GAME.spark[1])
        ring.head:SetSize(32, g.band + 18)
        -- the border round the cycle, over its cells
        ring.border = ns.Look:GameSlice3(ring, "cast", 12, 12, "ARTWORK", 4)
        local cx = g.W / 2 + g.x0 - 9
        ring.border:Place(ring, cx, g.H / 2 - g.y - 17, g.len + 19, 34)
    end
    ring.tip = ring:CreateLine(nil, "OVERLAY", nil, 1)   -- a flat bright edge where the fill ends
    ring.tip:SetColorTexture(1, 1, 1, 1)
    ring.tip:SetThickness(2)
    if g.path == "pips" then ring.noHead = true end

    -- frames over the cycle
    if key == "sigil" then
        local inner = Part(ring, "ARTWORK", WHITE, 0, 0, 0, 1, 2)
        inner:SetPoint("TOPLEFT", 7, -7); inner:SetPoint("BOTTOMRIGHT", -7, 7)
        ring.edge = Part(ring, "ARTWORK", WHITE, 0.91, 0.89, 0.82, 0.25, 3)
        ring.edge:SetPoint("TOPLEFT", 8, -8); ring.edge:SetPoint("BOTTOMRIGHT", -8, 8)
    elseif key == "gilded" then
        -- (round the next press; the warrior's round the globe)
        local mid = g.globe and g.globe[1] or g.big[1]
        local inner = Part(ring, "ARTWORK", DISC, 0, 0, 0, 1, 2)
        inner:SetPoint("CENTER"); inner:SetSize(mid + 10, mid + 10)
        ring.bezel2 = Bezel(ring, "ARTWORK", mid + 8, 3)
        ring.inner = inner
    end

    -- the next press
    local bs = g.big[1]
    local big = CreateFrame("Frame", nil, ring)
    big:SetSize(bs, bs)
    big:SetPoint("CENTER", ring, "CENTER", g.big[2], g.big[3])
    big:SetFrameLevel(ring:GetFrameLevel() + 2)
    if key == "pips" then
        big.frame = Part(big, "BACKGROUND", WHITE, 0, 0, 0, 1)
        big.frame:SetPoint("TOPLEFT", -1, 1); big.frame:SetPoint("BOTTOMRIGHT", 1, -1)
    elseif key == "slate" then
        big.frame = Part(big, "BACKGROUND", WHITE, 0, 0, 0, 1)
        big.frame:SetPoint("TOPLEFT", -1, 1); big.frame:SetPoint("BOTTOMRIGHT", 1, -1)
    end
    big.icon = Part(big, "ARTWORK")
    big.icon:SetAllPoints()
    big.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if g.round then Round(big, big.icon) end
    big.shade = Part(big, "OVERLAY", g.round and DISC or WHITE, 0, 0, 0, 0)
    big.shade:SetAllPoints()
    big.cd = CreateFrame("Cooldown", nil, big, "CooldownFrameTemplate")
    big.cd:SetAllPoints(big.icon)
    if big.cd.SetSwipeTexture then big.cd:SetSwipeTexture(g.round and DISC or WHITE) end
    if big.cd.SetSwipeColor then big.cd:SetSwipeColor(0, 0, 0, 0.66) end
    if big.cd.SetDrawEdge then big.cd:SetDrawEdge(false) end
    if big.cd.SetDrawBling then big.cd:SetDrawBling(false) end
    if big.cd.SetHideCountdownNumbers then big.cd:SetHideCountdownNumbers(true) end
    big.cd:EnableMouse(false)
    big.cd:Hide()
    if g.game then
        big.qs = big:CreateTexture(nil, "OVERLAY", nil, 2)
        ns.Look:QuickFrame(big.qs, big)
        big.alert = big:CreateTexture(nil, "OVERLAY", nil, 3)
        ns.Look:GameTex(big.alert, "alert")
        big.alert:SetBlendMode("ADD")
        big.alert:SetPoint("CENTER")
        big.alert:SetSize(bs * 64 / 36, bs * 64 / 36)
        big.alert:SetAlpha(0)
    end
    big.name = UI:Text(ring, key == "slate" and "small" or "page", { 1, 0.88, 0.54 }, { shadow = true })
    big.hint = UI:Text(ring, "emph", "SUB", { font = NARROW, shadow = true })
    -- (Classic: the name inside the bar where a cast bar writes it, from the bar's own place: the warrior's face is
    -- wider, a fixed spot put it outside the bar)
    local namePt = g.game and { g.W / 2 + g.x0 + 6, -(g.H / 2 - g.y) + 5 } or g.name
    if namePt then
        big.name:SetPoint("TOPLEFT", ring, "TOPLEFT", namePt[1], namePt[2])
        big.name:SetWidth(96)
        big.name:SetJustifyH("LEFT")
        big.showName = true
    elseif not g.game then
        -- (style A, the user's pick 2026-10-17: the name under the face, centred on the next press)
        UI:SetTextSize(big.name, "body")
        -- (a next press beside the ring, the warrior's: under that icon; else under the ring, the lane moves down for it)
        -- (Pips: starting where the pips start, in line with them)
        if g.queueFromBig then big.name:SetPoint("TOP", big, "BOTTOM", 0, -3); big.name:SetJustifyH("CENTER")
        elseif g.path == "pips" then
            big.name:SetPoint("TOPLEFT", ring, "BOTTOMLEFT", g.W / 2 + g.x0, -3)
            big.name:SetJustifyH("LEFT")
            big.underRing = true
        else
            big.name:SetPoint("TOP", ring, "BOTTOM", g.big[2], -3)
            big.name:SetJustifyH("CENTER")
            big.underRing = true
        end
        big.under, big.showName = true, true
    end
    -- the key it is on, in the top right corner as on an action button (round icons: in from the rim)
    big.key = UI:Text(big, bs >= 50 and "emph" or "small", { 0.9, 0.9, 0.9 }, { font = NARROW, flags = "OUTLINE" })
    big.key:SetDrawLayer("OVERLAY", 7)
    big.key:SetPoint("TOPRIGHT", big, "TOPRIGHT", g.round and -floor(bs * 0.14) or -2, g.round and -floor(bs * 0.1) or -2)
    big.key:SetJustifyH("RIGHT")
    big.hint:SetPoint("TOPLEFT", big.name, "BOTTOMLEFT", 0, -2)
    big.stance = StanceMark(big, max(11, floor(bs * 0.42)))
    big.name:SetShown(big.showName or false)
    big.hint:Hide()
    if g.game then
        -- (the name and the time in the bar, as a cast bar writes them)
        UI:SetTextSize(big.name, "body")
        big.name:SetWidth(g.len - 70)
        big.hint:ClearAllPoints()
        big.hint:SetPoint("RIGHT", ring, "CENTER", g.x0 + g.len - 24, g.y)     -- (clear of the badge's ring)
        big.hint:SetJustifyH("RIGHT")
        big.hint:Show()
    end
    face.big = big

    -- the badge (the seal, the aspect)
    local bd = g.badge[1]
    local seal = CreateFrame("Frame", nil, ring)
    seal:SetSize(bd, bd)
    seal:SetPoint("CENTER", ring, "CENTER", g.badge[2], g.badge[3])
    seal:SetFrameLevel(ring:GetFrameLevel() + 4)
    if key == "gilded" then
        local sb = Part(seal, "BACKGROUND", DISC, 0, 0, 0, 1)
        sb:SetPoint("CENTER"); sb:SetSize(bd + 8, bd + 8)
        Bezel(seal, "BORDER", bd + 6)
    elseif g.game then
        -- (the tracking border is 53 px for a 17 px icon, its ring's middle 16.6 px in from its top left)
        local sb = Part(seal, "BACKGROUND", DISC, 0, 0, 0, 1)
        sb:SetPoint("CENTER"); sb:SetSize(bd + 4, bd + 4)
        local bs2 = bd * 53 / 17
        seal.ring = seal:CreateTexture(nil, "OVERLAY")
        ns.Look:GameTex(seal.ring, "tracking")
        seal.ring:SetSize(bs2, bs2)
        seal.ring:SetPoint("TOPLEFT", seal, "CENTER", -bs2 * 16.6 / 53, bs2 * 16.6 / 53)
    else
        local sb = Part(seal, "BACKGROUND", g.round and DISC or WHITE, 0, 0, 0, 1)
        sb:SetPoint("CENTER")
        sb:SetSize(bd + (g.round and 4 or 2), bd + (g.round and 4 or 2))
    end
    seal.icon = Part(seal, "ARTWORK")
    seal.icon:SetAllPoints()
    seal.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if g.round or g.game then Round(seal, seal.icon) end
    seal.text = UI:Text(seal, "small", { 1, 1, 1 }, { font = NARROW, flags = "OUTLINE", justify = "CENTER" })
    seal.text:SetPoint("CENTER", 0, 0)
    face.seal = seal

    -- the presses after it, small and fading
    face.small = {}
    for i = 1, 3 do
        local s = CreateFrame("Frame", nil, ring)
        local size
        if g.queue == "top" then size = g.queueAt[3]
        else size = i == 1 and 28 or 22 end
        s:SetSize(size, size)
        if not g.round then
            local back = Part(s, "BACKGROUND", WHITE, 0, 0, 0, 1)
            back:SetPoint("TOPLEFT", -1, 1); back:SetPoint("BOTTOMRIGHT", 1, -1)
        end
        s.icon = Part(s, "ARTWORK")
        s.icon:SetAllPoints()
        s.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if g.round then Round(s, s.icon) end
        s.text = UI:Text(s, "small", { 1, 1, 1 }, { font = NARROW, shadow = true })
        s.key = UI:Text(s, "caps", { 0.9, 0.9, 0.9 }, { font = NARROW, flags = "OUTLINE" })
        s.key:SetDrawLayer("OVERLAY", 7)
        s.key:SetPoint("TOPRIGHT", s, "TOPRIGHT", g.round and -floor(size * 0.08) or 0, g.round and -floor(size * 0.04) or 0)
        s.key:SetJustifyH("RIGHT")
        s.stance = StanceMark(s, max(8, floor(size * 0.45)))
        if g.game then
            s.qs = s:CreateTexture(nil, "OVERLAY")
            ns.Look:QuickFrame(s.qs, s)
        end
        if g.queue == "top" then
            s:SetAlpha(0.85 - (i - 1) * 0.2)
            s:SetPoint("TOPLEFT", ring, "TOPLEFT", g.queueAt[1] + (i - 1) * g.queueAt[4], g.queueAt[2])
        else
            s:SetAlpha(i == 1 and 0.8 or 0.45)
            if i == 1 then s:SetPoint("RIGHT", g.queueFromBig and big or ring, "LEFT", -g.queueGap, 0)
            else s:SetPoint("RIGHT", face.small[i - 1], "LEFT", -6, 0) end
        end
        face.small[i] = s
    end
    if variant then RF:BuildExtra(face) end
    return face
end

-- ---------------------------------------------------------------------------------------------------------------
-- The situation chip (Core/Situation.lua; look A of the mockup claude.ai/artifact/F7uzKaTkq9oHbjqk2CQNj3): a small
-- plate under the face, hidden for one target. Its edge takes the situation's colour (ember a pack, frost crowd
-- control holding the pack presses back, red a player), an icon, a few words, a key when the switch key picked it.
-- ---------------------------------------------------------------------------------------------------------------
RF.SIT_COLORS = { pack = { 1, 0.56, 0.2 }, held = { 0.5, 0.71, 1 }, player = { 0.89, 0.28, 0.2 },
                  single = { 0.91, 0.89, 0.82 } }
local CHIP_H, CHIP_ICON, CHIP_KEY = 16, 12, "Interface\\Icons\\INV_Misc_Key_03"
RF.CHIP_H = CHIP_H

function RF:BuildChip(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(60, CHIP_H)
    c.glow = Part(c, "BACKGROUND", SOFT, 1, 1, 1, 0.35, -2)
    c.glow:SetBlendMode("ADD")
    c.glow:SetPoint("TOPLEFT", c, "TOPLEFT", -8, 6)
    c.glow:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 8, -6)
    c.bg = UI:Fill(c, { 0.04, 0.03, 0.02, 0.88 }, "BACKGROUND")
    UI:AddEdges(c, "BORDER")
    c.icon = Part(c, "ARTWORK")
    c.icon:SetSize(CHIP_ICON, CHIP_ICON)
    c.icon:SetPoint("LEFT", c, "LEFT", 2, 0)
    c.text = UI:Text(c, "small", { 0.96, 0.92, 0.82 }, { shadow = true })
    c.text:SetPoint("LEFT", c.icon, "RIGHT", 4, 0)
    c.lock = Part(c, "ARTWORK", CHIP_KEY)
    c.lock:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.lock:SetSize(11, 11)
    c.lock:SetPoint("LEFT", c.text, "RIGHT", 4, 0)
    c:Hide()
    return c
end

-- kind: a key of SIT_COLORS; icon + coords (nil: an icon's inner part); text; locked: the switch key picked it.
function RF:PaintChip(c, kind, icon, coords, text, locked)
    local col = self.SIT_COLORS[kind] or self.SIT_COLORS.single
    UI:SetEdgeColor(c, col[1], col[2], col[3], 0.9)
    c.glow:SetVertexColor(col[1], col[2], col[3], 0.35)
    c.icon:SetTexture(icon)
    if coords then c.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    c.text:SetText(text or "")
    c.lock:SetShown(locked and true or false)
    c:SetWidth(floor(2 + CHIP_ICON + 4 + UI:TextWidth(c.text) + (locked and 15 or 0) + 6 + 0.5))
    c:Show()
end

-- ---------------------------------------------------------------------------------------------------------------
-- The lane: the same parts in every theme, its ground and edges the theme's
-- ---------------------------------------------------------------------------------------------------------------
local LANE_LOOK = {
    halo = { bg = "HUD_BG", edge = { 0, 0, 0, 0.9 } },
    sigil = { bg = { 0, 0, 0, 0.82 }, edge = { 0.91, 0.89, 0.82, 0.32 } },
    slate = { bg = { 0.047, 0.047, 0.059, 0.82 }, edge = { 1, 1, 1, 0.09 } },
    gilded = { bg = { 0.08, 0.055, 0.02, 0.92 }, edge = { 0.64, 0.48, 0.14, 1 }, line = { 0.54, 0.42, 0.13, 1 } },
    pips = { bg = { 0, 0, 0, 0.7 }, edge = { 0, 0, 0, 1 } },
    classic = { bg = { 0.035, 0.035, 0.075, 0.9 }, edge = { 0.36, 0.36, 0.4, 1 } },
}

function RF:BuildLane(parent, key, opts)
    local g = self.GEO[key] or self.GEO.halo
    local look = LANE_LOOK[key] or LANE_LOOK.halo
    local W, H = g.lane[1], g.lane[2]
    local span, back = opts.span, opts.back
    local lane = CreateFrame("Frame", nil, parent)
    lane:SetSize(W, H)
    lane.W, lane.H, lane.look = W, H, look
    lane.bg = UI:Fill(lane, look.bg, "BACKGROUND", -5)
    UI:AddEdges(lane, "BACKGROUND")
    UI:SetEdgeColor(lane, look.edge[1], look.edge[2], look.edge[3], look.edge[4])
    for s = 1, 7 do
        lane["grid" .. s] = UI:Rule(lane, { vertical = true, color = "HOVER", layer = "BORDER",
            left = (s + back) / span * W })
    end
    lane.now = UI:Fill(lane, { 1, 1, 1, 1 }, "OVERLAY")
    lane.now:ClearAllPoints()
    lane.now:SetWidth(2)
    lane.now:SetPoint("TOP", 0, 4)
    lane.now:SetPoint("BOTTOM", 0, -4)
    lane.now:SetPoint("LEFT", lane, "LEFT", back / span * W, 0)
    lane.gain = UI:Text(lane, "body", "OK", { shadow = true })
    lane.gain:SetPoint("TOPRIGHT", lane, "BOTTOMRIGHT", 0, -6)
    lane.ticks, lane.windows, lane.blocks = {}, {}, {}
    local gold = opts.gold
    for i = 1, 4 do
        local w = lane:CreateTexture(nil, "BORDER")
        local dim, bright = { ZONE[1], ZONE[2], ZONE[3], 0.04 }, { ZONE[1], ZONE[2], ZONE[3], 0.38 }
        if opts.fade then UI:Gradient(w, "HORIZONTAL", bright, dim) else UI:Gradient(w, "HORIZONTAL", dim, bright) end
        lane.windows[i] = w
        local t = Part(lane, "OVERLAY", WHITE, gold[1], gold[2], gold[3], 1)
        t:SetWidth(2)
        lane.ticks[i] = t
    end
    local inset = g.small and 8 or 12
    for i = 1, 6 do
        local b = CreateFrame("Frame", nil, lane)
        b:SetHeight(H - inset)
        b.bg = Part(b, "BACKGROUND")
        b.bg:SetAllPoints()
        b.line = Part(b, "BORDER")
        b.line:SetPoint("TOPLEFT")
        b.line:SetPoint("TOPRIGHT")
        b.line:SetHeight(key == "sigil" and 2 or 1)
        b.icon = Part(b, "ARTWORK")
        b.icon:SetSize(H - inset - 6, H - inset - 6)
        b.icon:SetPoint("LEFT", 3, 0)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.name = UI:Text(b, "emph", "TEXT", { font = NARROW, shadow = true })
        b.name:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
        b.name:SetPoint("RIGHT", b, "RIGHT", -3, 0)
        if g.small then b.name:Hide() end
        lane.blocks[i] = b
    end
    lane.noNames = g.small
    return lane
end

-- ---------------------------------------------------------------------------------------------------------------
-- Painting the cycle (the colours are the ring's from before the themes, for every theme)
-- ---------------------------------------------------------------------------------------------------------------
function RF:Paint(face, p)
    local ring, g = face.root, face.geo
    local frac, z0, z1, s0, pulse = p.frac, p.z0, p.z1, p.s0, p.pulse or 0.5
    local zw = max(0.001, z1 - z0)
    for _, d in ipairs(ring.dots) do
        local f = d.f
        local inside = f >= z0 and f <= z1
        local k = (inside and p.fade) and 1 - 0.65 * (f - z0) / zw or 1
        if f <= frac then
            if inside then d:SetVertexColor(0.30 + 0.70 * k, 0.19 + (0.43 + 0.2 * pulse) * k, 0.10 + 0.20 * k)
            elseif g.game then d:SetVertexColor(1, 0.7, 0)                -- (the game's casting yellow)
            else d:SetVertexColor(0.62 + 0.36 * f, 0.46 + 0.36 * f, 0.18 + 0.30 * f) end
        elseif inside then
            if p.hot then d:SetVertexColor(0.30 + 0.32 * k, 0.19 + 0.13 * k, 0.10)
            else d:SetVertexColor(0.30, 0.19, 0.10) end
        elseif f >= s0 then
            d:SetVertexColor(0.30, 0.09, 0.07)
        else
            d:SetVertexColor(0.13, 0.13, 0.14)
        end
    end
    local open = p.inZone and p.hot
    if ring.noHead then
        ring.head:Hide(); ring.tip:Hide()
    else
        local hx, hy = RF.Pos(g, frac)
        ring.head:ClearAllPoints()
        ring.head:SetPoint("CENTER", ring, "CENTER", hx, hy)
        local x0, y0 = RF.Pos(g, frac, -g.band / 2)
        local x1, y1 = RF.Pos(g, frac, g.band / 2)
        ring.tip:SetStartPoint("CENTER", ring, x0, y0)
        ring.tip:SetEndPoint("CENTER", ring, x1, y1)
        ring.head:Show(); ring.tip:Show()
        if open then ring.head:SetVertexColor(1, 0.6, 0.25, 1) else ring.head:SetVertexColor(1, 0.92, 0.66, 0.9) end
    end
    -- the window is open on the next press: the glow (slate: its edge, pips: the next press's frame)
    if g.glow then ring.glow:SetAlpha(open and 0.25 + 0.25 * pulse or 0) end
    if face.key == "slate" then
        if open then UI:SetEdgeColor(ring, 1, 0.67, 0.35, 0.5 + 0.3 * pulse) else UI:SetEdgeColor(ring, 1, 1, 1, 0.09) end
    elseif face.key == "pips" then
        if open then face.big.frame:SetVertexColor(1, 0.82, 0, 1) else face.big.frame:SetVertexColor(0, 0, 0, 1) end
    elseif face.key == "sigil" then
        if open then ring.edge:SetVertexColor(1, 0.67, 0.35, 0.9) else ring.edge:SetVertexColor(0.91, 0.89, 0.82, 0.25) end
    elseif g.game and face.big.alert then
        face.big.alert:SetAlpha(open and 0.75 + 0.25 * pulse or 0)
    end
end

-- Resting: the cycle empty and dim.
function RF:Rest(face)
    local ring = face.root
    ring:SetAlpha(0.35)
    for _, d in ipairs(ring.dots) do d:SetVertexColor(0.13, 0.13, 0.14) end
    ring.head:Hide()
    ring.tip:Hide()
    ring.glow:SetAlpha(0)
    ring.flash:SetAlpha(0)
    if face.key == "slate" then UI:SetEdgeColor(ring, 1, 1, 1, 0.09)
    elseif face.key == "pips" then face.big.frame:SetVertexColor(0, 0, 0, 1)
    elseif face.key == "sigil" then ring.edge:SetVertexColor(0.91, 0.89, 0.82, 0.25)
    elseif face.big.alert then face.big.alert:SetAlpha(0) end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The warrior's extras: the off-hand cycle, rage, the Heroic Strike lamp (RF.VARIANT.warrior)
-- ---------------------------------------------------------------------------------------------------------------
local OH_FILL, OH_BRIGHT = { 0.81, 0.76, 0.63 }, { 0.98, 0.93, 0.78 }
local GOLDLINE = { 1, 0.84, 0.42 }
local RIM = { 1, 1, 1 }            -- (the glass light of older art)
local HS_ICON = "Interface\\Icons\\Ability_Rogue_Ambush"

local FLUID = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\fluid"
local GLASS_SHADE = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\glass_shade"
local GLASS_SPEC = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\glass_spec"
local TANK_SHADE = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\tank_shade"
local TANK_SPEC = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\tank_spec"
local NOTCH = "Interface\\AddOns\\DisasterZone\\Media\\Warrior\\notch"

-- The globe's size changed: the flat rim light of older art (a short arc of strokes round its upper left, a tank: two
-- edges). The baked glass fills the globe by itself.
local function PlaceGlass(gl, D)
    if not gl.rim then return end
    local n = #gl.rim
    if gl.square then
        local a, b = gl.rim[1], gl.rim[2]
        a:SetStartPoint("TOPLEFT", gl, 2, -2); a:SetEndPoint("TOPLEFT", gl, D * 0.55, -2)
        b:SetStartPoint("TOPLEFT", gl, 2, -2); b:SetEndPoint("TOPLEFT", gl, 2, -D * 0.45)
        a:SetVertexColor(RIM[1], RIM[2], RIM[3], 0.22); b:SetVertexColor(RIM[1], RIM[2], RIM[3], 0.16)
        return
    end
    local r = D / 2 - 2.2
    local a0, a1 = math.rad(105), math.rad(170)
    for i = 1, n do
        local t0, t1 = a0 + (a1 - a0) * (i - 1) / n, a0 + (a1 - a0) * i / n
        local l = gl.rim[i]
        l:SetStartPoint("CENTER", gl, r * cos(t0), r * sin(t0))
        l:SetEndPoint("CENTER", gl, r * cos(t1), r * sin(t1))
        l:SetVertexColor(RIM[1], RIM[2], RIM[3], 0.08 + 0.22 * sin(pi * (i - 0.5) / n))
    end
end

-- The Heroic Strike markers at height y (from the globe's bottom): one on each side, inside the glass with its back on
-- the rim (clipped to the glass, so nothing reaches the off-hand ring round it). lit = rage is over the line: full gold
-- with a glow; under it they dim.
local function PlaceNotches(gl, D, y, lit)
    local cy = y - D / 2
    local half
    if gl.square then half = D / 2
    else half = math.sqrt(max(0, (D / 2) ^ 2 - cy * cy)) end
    if gl.art then
        -- (the pointer's body is 0.04 .. 0.88 of its texture's width: its back 0.46 of it from the middle)
        local w = max(10, D * 0.15)
        for side = 1, 2 do
            local s = side == 1 and -1 or 1
            local n = gl.notch[side]
            local cx = s * (half - 0.46 * w)
            n.tex:ClearAllPoints()
            n.tex:SetSize(w, w)
            n.tex:SetPoint("CENTER", gl, "CENTER", cx, cy)
            n.glow:ClearAllPoints()
            n.glow:SetSize(w * 2.2, w * 1.5)
            n.glow:SetPoint("CENTER", gl, "CENTER", cx, cy)
            if lit then
                n.tex:SetVertexColor(1, 1, 1, 1)
                n.glow:SetAlpha(0.55)
            else
                n.tex:SetVertexColor(0.62, 0.55, 0.46, 0.9)
                n.glow:SetAlpha(0)
            end
        end
        return
    end
    half = half - (gl.square and 1 or 1.5)
    local len = max(4, D * 0.09)
    for side = 1, 2 do
        local s = side == 1 and -1 or 1
        local x0, x1 = s * half, s * (half - len)
        local dark, gold = gl.notch[side], gl.notch[side + 2]
        dark:SetStartPoint("CENTER", gl, x0 + s * 0.5, cy); dark:SetEndPoint("CENTER", gl, x1 - s * 1, cy)
        gold:SetStartPoint("CENTER", gl, x0, cy); gold:SetEndPoint("CENTER", gl, x1, cy)
        dark:SetVertexColor(0, 0, 0, 0.75)
        local c = GOLDLINE
        gold:SetVertexColor(c[1], c[2], c[3], lit and 1 or 0.7)
    end
end

function RF:BuildExtra(face)
    local ring, g = face.root, face.geo
    local x = {}
    face.extra = x
    local round = g.round
    -- the off-hand cycle (over the frames inside the main one)
    local og = Merge(g, g.oh)
    x.ohGeo = og
    x.oh = Cells(ring, og, "OVERLAY", -3)
    if face.key == "slate" then
        x.ohShadow = Part(ring, "BACKGROUND", WHITE, 0, 0, 0, 0.8, -4)
        x.ohShadow:SetSize(og.len + 2, og.band + 2)
        x.ohShadow:SetPoint("CENTER", ring, "CENTER", og.x0 + og.len / 2, og.y)
    end
    if g.game then
        x.ohBorder = ns.Look:GameSlice3(ring, "cast", 10, 10, "OVERLAY", 2)
        x.ohBorder:Place(ring, g.W / 2 + g.x0 - 7, g.H / 2 - og.y - og.band - 2, g.len + 14, og.band * 2 + 4)
    end

    -- rage
    local r = g.rage
    if not r then
        local D = g.globe[1]
        local gl = CreateFrame("Frame", nil, ring)
        gl:SetFrameLevel(ring:GetFrameLevel() + 1)
        gl:SetPoint("CENTER", ring, "CENTER", 0, 0)
        gl:SetSize(D, D)
        local mask
        if not g.square and gl.CreateMaskTexture then
            mask = gl:CreateMaskTexture()
            mask:SetTexture(DISC, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints()
        end
        local function T(layer, path, sub, add)
            local t = Part(gl, layer, path or WHITE, nil, nil, nil, nil, sub)
            if add then t:SetBlendMode("ADD") end
            if mask then t:AddMaskTexture(mask) end
            return t
        end
        -- art pack 14: a baked liquid and glass (gen_rage_globe.py); older art: the same parts, flat
        local art = ns.HasAssets and ns:HasAssets(14)
        gl.art, gl.square = art, g.square
        gl.back = T("BACKGROUND")
        gl.back:SetAllPoints()
        UI:GradientRGBA(gl.back, "VERTICAL", 0.03, 0.01, 0.01, 1, 0.08, 0.028, 0.024, 1)
        -- the rage: one body of liquid (the part over the Heroic Strike line a warmer, brighter top of it)
        local function Liquid(sub)
            local t = T("BORDER", nil, sub)
            if art then t:SetTexture(FLUID, "REPEAT", "REPEAT") end
            return t
        end
        gl.liq, gl.spare = Liquid(0), Liquid(1)
        -- its top: a thin bright meniscus and two glows just under it; bubbles rising (PaintExtra moves them)
        gl.surf = T("ARTWORK", SOFT, 0, true)
        gl.surf:SetVertexColor(1, 0.55, 0.38, 0.45)
        gl.surf2 = T("ARTWORK", SOFT, 1, true)
        gl.surf2:SetVertexColor(1, 0.72, 0.55, 0.3)
        gl.men = T("ARTWORK", WHITE, 3)
        gl.men:SetHeight(1)
        gl.bubbles = {}
        for i = 1, 4 do
            local b = T("ARTWORK", SOFT, 1, true)
            b:SetVertexColor(1, 0.72, 0.55, 0)
            gl.bubbles[i] = b
        end
        -- the glass over it: shading that makes it a sphere (a tank: its edges), and its light
        if art then
            gl.shade = T("OVERLAY", g.square and TANK_SHADE or GLASS_SHADE, -2)
            gl.shade:SetAllPoints()
            gl.spec = T("OVERLAY", g.square and TANK_SPEC or GLASS_SPEC, -1, true)
            gl.spec:SetAllPoints()
        else
            gl.rim = {}
            for i = 1, (g.square and 2 or 9) do
                local l = gl:CreateLine(nil, "OVERLAY")
                l:SetColorTexture(1, 1, 1, 1)
                l:SetThickness(1.4)
                gl.rim[i] = l
            end
        end
        -- the Heroic Strike line: a gold pointer on each side of the rim (a line across read as a crack); older art:
        -- short gold ticks
        gl.notch = {}
        if art then
            for i = 1, 2 do
                -- (masked like the liquid: they belong to the glass)
                local glow = T("OVERLAY", SOFT, 2, true)
                glow:SetVertexColor(1, 0.78, 0.35, 1)
                glow:SetAlpha(0)
                local t = T("OVERLAY", NOTCH, 3)
                if i == 2 then t:SetTexCoord(1, 0, 0, 1) end          -- (the right one points left)
                gl.notch[i] = { tex = t, glow = glow }
            end
        else
            for i = 1, 4 do
                local l = gl:CreateLine(nil, "OVERLAY", nil, i <= 2 and 2 or 3)
                l:SetColorTexture(1, 1, 1, 1)
                l:SetThickness(i <= 2 and 4 or 2)
                gl.notch[i] = l
            end
        end
        PlaceGlass(gl, D)
        gl.num = UI:Text(gl, "emph", { 1, 0.95, 0.84 }, { font = NARROW, shadow = true, justify = "CENTER" })
        gl.num:SetPoint("CENTER", 0, 0)
        x.globe, x.D = gl, D
    elseif r.kind == "bar" then
        local b = CreateFrame("Frame", nil, ring)
        b:SetFrameLevel(ring:GetFrameLevel() + 1)
        b:SetSize(g.len, r.h)
        b:SetPoint("CENTER", ring, "CENTER", g.x0 + g.len / 2, r.y)
        b.track = Part(b, "BACKGROUND", WHITE, 0.16, 0.07, 0.06, 0.9)
        b.track:SetAllPoints()
        b.fill = Part(b, "BORDER", g.game and ns.Look.SBAR or WHITE, 0.66, 0.09, 0.06, 1)
        b.fill:SetPoint("TOPLEFT"); b.fill:SetPoint("BOTTOMLEFT")
        b.spare = Part(b, "BORDER", g.game and ns.Look.SBAR or WHITE, 1, 0.36, 0.16, 1, 1)
        b.spare:SetPoint("TOP"); b.spare:SetPoint("BOTTOM")
        b.line = Part(b, "ARTWORK", WHITE)
        b.line:SetSize(1, r.h + 4)
        if face.key == "slate" then
            local sh = Part(ring, "BACKGROUND", WHITE, 0, 0, 0, 0.8, -4)
            sh:SetSize(g.len + 2, r.h + 2)
            sh:SetPoint("CENTER", b, "CENTER")
        end
        if g.game then
            b.border = ns.Look:GameSlice3(b, "cast", 10, 10, "OVERLAY", 2)
            b.border:Place(b, -7, -(r.h / 2 + 2), g.len + 14, r.h * 2 + 4)
            b.num = UI:Text(b, "small", { 1, 1, 1 }, { font = NARROW, shadow = true, justify = "CENTER" })
            b.num:SetPoint("CENTER", 0, 0)
        elseif r.num then
            -- (beside the bar: on the face, not the bar)
            b.num = UI:Text(ring, "small", { 1, 0.54, 0.36 }, { font = NARROW, shadow = true, justify = "RIGHT" })
            b.num:SetPoint("LEFT", b, "RIGHT", 3, 0)
            b.num:SetWidth(22)
        end
        b.W = g.len
        x.bar = b
    else
        local pg = Merge(g, { y = r.y })
        x.pips = Cells(ring, pg, "ARTWORK", 2)
        x.pipLine = Part(ring, "OVERLAY", WHITE)
        x.pipLine:SetSize(1, 10)
        x.pipGeo = pg
    end

    -- the Heroic Strike lamp
    local l = g.lamp
    local s = l[1]
    local lf = CreateFrame("Frame", nil, ring)
    lf:SetSize(s, s)
    lf:SetPoint("CENTER", ring, "CENTER", l[2], l[3])
    lf:SetFrameLevel(ring:GetFrameLevel() + 6)
    lf.glow = Part(lf, "BACKGROUND", SOFT, 1, 0.56, 0.2, 0)
    lf.glow:SetBlendMode("ADD")
    lf.glow:SetPoint("CENTER"); lf.glow:SetSize(s * 2.8, s * 2.8)
    lf.edge = Part(lf, "BORDER", round and DISC or WHITE, 0, 0, 0, 1)
    lf.edge:SetPoint("CENTER"); lf.edge:SetSize(s + 4, s + 4)
    lf.back = Part(lf, "BORDER", round and DISC or WHITE, 0, 0, 0, 1, 1)
    lf.back:SetPoint("CENTER"); lf.back:SetSize(s + 2, s + 2)
    lf.icon = Part(lf, "ARTWORK", HS_ICON)
    lf.icon:SetAllPoints()
    lf.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if round then Round(lf, lf.icon) end
    lf:Hide()
    x.lamp = lf

    -- (gilded: the next press, now beside the ring, gets its own bezel)
    if g.bigBezel then
        local bb = CreateFrame("Frame", nil, ring)
        bb:SetFrameLevel(face.big:GetFrameLevel() - 1)
        bb:SetPoint("CENTER", face.big, "CENTER")
        bb:SetSize(g.big[1] + 8, g.big[1] + 8)
        local d = Part(bb, "BACKGROUND", DISC, 0, 0, 0, 1)
        d:SetAllPoints()
        Bezel(bb, "BORDER", g.big[1] + 6)
    end
end

-- e = { oh = { frac, bright } (nil: no off hand), rage = { v, line } (0..1), num (the rage in numbers or nil),
--       lamp = "queue" | "queued" | "hold" | nil, lampIcon, pulse, still (no motion: drawn at rest, or turned off) }
-- Rage moves: the level eases toward it, the globe's surface sways and sloshes after a change, bubbles rise and the
-- rage over the line pulses softly (a few anchors a frame; drawn still at rest).
function RF:PaintExtra(face, e)
    local x = face.extra
    if not x then return end
    local g = face.geo
    local has = e.oh ~= nil
    if x.ohShown ~= has then
        x.ohShown = has
        for _, d in ipairs(x.oh) do
            d:SetShown(has)
            if d.back then d.back:SetShown(has) end
        end
        if x.ohShadow then x.ohShadow:SetShown(has) end
        if x.ohBorder then x.ohBorder:Show(has) end
        -- a bigger globe with no off-hand ring round it
        if x.globe then
            local D = has and g.globe[1] or g.globe[2]
            x.D = D
            x.globe:SetSize(D, D)
            PlaceGlass(x.globe, D)
            local ring = face.root
            if ring.inner then
                ring.inner:SetSize(D + 10, D + 10)
                ring.bezel2:SetSize(D + 8, D + 8)
            end
        end
    end
    if has then
        local frac = e.oh[1]
        local c = e.oh[2] and OH_BRIGHT or OH_FILL
        for _, d in ipairs(x.oh) do
            if d.f <= frac then d:SetVertexColor(c[1], c[2], c[3], 1) else d:SetVertexColor(0.13, 0.13, 0.14, 1) end
        end
    end

    local v, line = e.rage and e.rage[1] or 0, e.rage and e.rage[2] or 1
    v, line = max(0, min(1, v)), max(0, min(1, line))
    -- (the level eases toward the rage, a change sloshes the surface; still: drawn at rest, no motion)
    local now = GetTime()
    local dt = x.at and max(0, min(0.25, now - x.at)) or 0
    x.at = now
    local still = e.still or not x.lv
    if still then
        x.lv, x.slosh = v, 0
    else
        local before = x.lv
        x.lv = x.lv + (v - x.lv) * (1 - math.exp(-dt * 7))
        local moved = dt > 0 and math.abs(x.lv - before) / dt or 0
        x.slosh = max((x.slosh or 0) * math.exp(-dt * 1.4), min(1, moved * 1.5))
    end
    v = x.lv
    local over = v > line
    local lc = over and 1 or 0.6
    if x.globe then
        local gl, D = x.globe, x.D
        local h = D * v
        local lh = D * line
        -- the liquid: dark at the bottom, warming to the line; over it a brighter top. Its texture drifts and is laid
        -- out in globe space, so the two parts run on as one
        local drift = still and 0 or now * 0.018
        local tile = D / 72
        local function Lay(t, y0, y1, r0, g0, b0, r1, g1, b1)
            t:SetShown(y1 - y0 >= 0.5)
            if y1 - y0 < 0.5 then return end
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", gl, "BOTTOMLEFT", 0, y0)
            t:SetPoint("BOTTOMRIGHT", gl, "BOTTOMRIGHT", 0, y0)
            t:SetHeight(y1 - y0)
            if gl.art then
                t:SetTexCoord(drift, drift + tile, (1 - y1 / D) * tile + drift * 0.4, (1 - y0 / D) * tile + drift * 0.4)
            end
            UI:GradientRGBA(t, "VERTICAL", r0, g0, b0, 1, r1, g1, b1, 1, gl.art)
        end
        local under = min(h, lh)
        local k = lh > 0 and under / lh or 1
        Lay(gl.liq, 0, under, 0.30, 0.025, 0.02, 0.30 + 0.30 * k, 0.025 + 0.04 * k, 0.02 + 0.03 * k)
        if h > lh then
            Lay(gl.spare, lh, h, 0.60, 0.065, 0.05, 0.95, 0.25, 0.12)
        else
            gl.spare:Hide()
        end
        -- the surface: the meniscus, two glows just under it swaying against each other and bobbing (more after a
        -- change: never above it); bubbles rising
        local sl = still and 0 or (x.slosh or 0)
        local sway = still and 0 or math.sin(now * 1.7) * D * (0.06 + 0.16 * sl)
        local bob = still and 0 or math.sin(now * 2.6) * (0.5 + 2.2 * sl)
        local live = h >= 2 and h <= D - 1
        gl.men:SetShown(live)
        if live then
            gl.men:ClearAllPoints()
            gl.men:SetPoint("BOTTOMLEFT", gl, "BOTTOMLEFT", 0, h - 1)
            gl.men:SetPoint("BOTTOMRIGHT", gl, "BOTTOMRIGHT", 0, h - 1)
            if h > lh then gl.men:SetVertexColor(1, 0.72, 0.5, 0.85) else gl.men:SetVertexColor(1, 0.45, 0.32, 0.6) end
        end
        gl.surf:SetShown(h >= 2)
        gl.surf:ClearAllPoints()
        gl.surf:SetSize(D * 1.1, D * 0.12)
        gl.surf:SetPoint("TOP", gl, "BOTTOM", sway, h - 1 - math.abs(bob))
        gl.surf2:SetShown(live and not still)
        if live and not still then
            gl.surf2:ClearAllPoints()
            gl.surf2:SetSize(D * 0.55, D * 0.07)
            gl.surf2:SetPoint("TOP", gl, "BOTTOM", -sway * 1.4, h - 2 - math.abs(bob) * 0.7)
        end
        local bs = max(1.5, D * 0.05)
        for i, b in ipairs(gl.bubbles) do
            if still or h < 8 then
                b:Hide()
            else
                local period = 1.9 + 0.37 * i
                local f = ((now + i * 0.71) % period) / period
                local y = 2 + f * (h - 5)
                local bx = (i - 2.5) * D * 0.17 + math.sin(now * 3 + i * 1.3) * D * 0.03
                b:ClearAllPoints()
                b:SetSize(bs * (0.7 + 0.3 * f), bs * (0.7 + 0.3 * f))
                b:SetPoint("CENTER", gl, "BOTTOM", bx, y)
                b:SetAlpha(0.4 * math.sin(f * math.pi))
                b:Show()
            end
        end
        gl.spare:SetAlpha(still and 1 or 0.9 + 0.1 * math.sin(now * 4))
        PlaceNotches(gl, D, lh, over)
        gl.num:SetText(e.num and tostring(e.num) or "")
    elseif x.bar then
        local b = x.bar
        local W = b.W
        b.fill:SetShown(v > 0.004)
        b.fill:SetWidth(max(0.5, W * min(v, line)))
        b.spare:SetShown(over)
        if over then
            b.spare:ClearAllPoints()
            b.spare:SetPoint("TOPLEFT", b, "TOPLEFT", W * line, 0)
            b.spare:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", W * line, 0)
            b.spare:SetWidth(max(0.5, W * (v - line)))
        end
        b.line:ClearAllPoints()
        b.line:SetPoint("CENTER", b, "LEFT", W * line, 0)
        b.line:SetVertexColor(GOLDLINE[1], GOLDLINE[2], GOLDLINE[3], lc)
        if b.num then b.num:SetText(e.num and tostring(e.num) or "") end
    elseif x.pips then
        for _, d in ipairs(x.pips) do
            if d.f > v then d:SetVertexColor(0.16, 0.08, 0.07, 1)
            elseif d.f >= line then d:SetVertexColor(1, 0.36, 0.16, 1)
            else d:SetVertexColor(0.66, 0.09, 0.06, 1) end
        end
        local pg = x.pipGeo
        local lx = RF.Pos(pg, line)
        x.pipLine:ClearAllPoints()
        x.pipLine:SetPoint("CENTER", face.root, "CENTER", lx - 0.75, pg.y)
        x.pipLine:SetVertexColor(GOLDLINE[1], GOLDLINE[2], GOLDLINE[3], lc)
    end

    local lf, st = x.lamp, e.lamp
    lf:SetShown(st ~= nil)
    if st then
        local pulse = e.pulse or 0.5
        lf.icon:SetTexture(e.lampIcon or HS_ICON)
        if st == "queue" then
            lf.edge:SetVertexColor(1, 0.56, 0.2, 1)
            lf.glow:SetVertexColor(1, 0.56, 0.2, 1)
            lf.glow:SetAlpha(0.35 + 0.45 * pulse)
            lf.icon:SetDesaturated(false); lf.icon:SetAlpha(1)
        elseif st == "queued" then
            local gd = S.C.GOLD
            lf.edge:SetVertexColor(gd[1], gd[2], gd[3], 1)
            lf.glow:SetVertexColor(gd[1], gd[2], gd[3], 1)
            lf.glow:SetAlpha(0.4)
            lf.icon:SetDesaturated(false); lf.icon:SetAlpha(1)
        else
            lf.edge:SetVertexColor(0, 0, 0, 1)
            lf.glow:SetAlpha(0)
            lf.icon:SetDesaturated(true); lf.icon:SetAlpha(0.5)
        end
    end
end

-- Resting: the off-hand cycle empty, rage as it is (it fades out of combat), the lamp off.
function RF:RestExtra(face, oh, rage, line)
    if not face.extra then return end
    self:PaintExtra(face, { oh = oh and { 0, false } or nil, rage = { rage or 0, line or 0.4 }, still = true })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Which theme a timer wears; the pickers
-- ---------------------------------------------------------------------------------------------------------------
local function KindOf(prefix) return "ring_" .. prefix end

-- Registers a timer (its own theme kind; previews repaint it). ring = the SwingRing (its :Refresh()).
function RF:Register(prefix, ring)
    self.rings[prefix] = ring
    ns.Themes:Define(KindOf(prefix), RF.THEMES, "halo", { setting = prefix .. ".theme",
        onPreview = function() ring:Refresh() end })
end

function RF:Key(prefix, practicing)
    if practicing then return "halo" end
    local t = ns.Themes:Current(KindOf(prefix))
    local key = t and t.key or "halo"
    return self.GEO[key] and key or "halo"
end

-- A tile's sample: the face at the mockup's moment (the window open, the next press due), scaled into the tile.
local TILE_W, TILE_H = 96, 84
local SAMPLE = {
    swing = { big = "Interface\\Icons\\Spell_Holy_SealOfBlood", badge = "Interface\\Icons\\Ability_Warrior_InnerRage",
              small = { "Interface\\Icons\\Spell_Holy_CrusaderStrike", "Interface\\Icons\\Ability_Warrior_InnerRage" },
              p = { frac = 0.8, z0 = 0.8, z1 = 0.93, s0 = 0.93, hot = true, inZone = true, pulse = 0.5 } },
    shot = { big = "Interface\\Icons\\Ability_Hunter_SteadyShot", badge = "Interface\\Icons\\Spell_Nature_RavenForm",
             small = { "Interface\\Icons\\Ability_ImpalingBolt", "Interface\\Icons\\Ability_Hunter_SteadyShot" },
             p = { frac = 0.22, z0 = 0.06, z1 = 0.62, s0 = 0.84, hot = true, inZone = true, pulse = 0.5, fade = true } },
    war = { big = "Interface\\Icons\\Spell_Nature_BloodLust", badge = "Interface\\Icons\\Ability_Warrior_Rampage",
            small = { "Interface\\Icons\\Ability_Whirlwind", "Interface\\Icons\\Ability_Warrior_BattleShout" },
            name = "Bloodthirst", variant = "warrior",
            p = { frac = 0.84, z0 = 0.8, z1 = 0.95, s0 = 0.95, hot = true, inZone = true, pulse = 0.5 },
            e = { oh = { 0.38, false }, rage = { 0.62, 0.4 }, num = 62, lamp = "queue", pulse = 0.5 } },
}
-- A face at the mockup's moment (the window open, the next press due) in parent: face, and the room it takes (its
-- size and, for faces whose queue sits outside their left, the queue's width).
local function SampleFace(parent, key, prefix)
    local sm = SAMPLE[prefix] or SAMPLE.swing
    local face = RF:BuildFace(parent, key, sm.variant)
    local g = face.geo
    face.big.icon:SetTexture(sm.big)
    face.seal.icon:SetTexture(sm.badge)
    for i, s2 in ipairs(face.small) do
        if sm.small[i] then s2.icon:SetTexture(sm.small[i]); s2:Show() else s2:Hide() end
    end
    face.big.name:SetText(face.big.showName and (sm.name or (prefix == "shot" and "Steady Shot" or "Seal of Blood")) or "")
    RF:Paint(face, sm.p)
    if sm.e then RF:PaintExtra(face, sm.e) end
    return face, g.W, g.H, g.padL or (g.queue == "left" and 56 or 0)
end

-- (Settings > Interface > Looks > Timers: the part's tile and stage) root, w, h, the queue's width
function RF:Sample(parent, key, prefix)
    local face, w, h, qw = SampleFace(parent, key, prefix)
    return face.root, w, h, qw
end

local function PaintTile(prefix)
    return function(tile, t)
        if not tile.face then
            local face, w, h, qw = SampleFace(tile, t.key, prefix)
            -- the queue sits outside the left of round / square faces: fit the face and that
            local s = min((TILE_W - 10) / (w + qw), (TILE_H - 26) / h)
            face.root:SetScale(s)
            face.root:SetPoint("CENTER", tile, "TOPLEFT", (TILE_W / 2 + qw * s / 2) / s, -((TILE_H - 18) / 2 + 1) / s)
            tile.face = face
        end
    end
end

-- The timer's theme row (Settings > Interface > Looks > Timers): label ("Theme" by default) and a tile per theme.
function RF:SettingsRow(S, sec, prefix, label)
    ns.Themes:SettingsRow(S, sec, KindOf(prefix), label or "Theme", "The look of this timer.",
        { tileW = TILE_W, tileH = TILE_H, gap = 8, nameY = 6, clip = true, paint = PaintTile(prefix),
          hint = "Your timer shows it while you point at it.",
          onPick = function()
              local r = RF.rings[prefix]
              if r then r:Refresh() end
          end })
end

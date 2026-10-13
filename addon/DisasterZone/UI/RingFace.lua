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
local addonName, ns = ...

local RF = { rings = {} }
ns.RingFace = RF

local UI = ns.UI
local S = ns.Style

local max, min, pi, cos, sin = math.max, math.min, math.pi, math.cos, math.sin

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
function RF:BuildFace(parent, key)
    local g = self.GEO[key] or self.GEO.halo
    local face = { key = key, geo = g }
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
    ring.dots = {}
    for i = 1, g.N do
        local f = (i - 0.5) / g.N
        local d
        if g.path == "circle" then
            d = ring:CreateLine(nil, "ARTWORK")
            d:SetColorTexture(1, 1, 1, 1)
            d:SetThickness(2 * pi * (g.R + g.band / 2) / g.N + 0.7)   -- (a little overlap: no gaps on the outer edge)
            local x0, y0 = RF.Pos(g, f, -g.band / 2)
            local x1, y1 = RF.Pos(g, f, g.band / 2)
            d:SetStartPoint("CENTER", ring, x0, y0)
            d:SetEndPoint("CENTER", ring, x1, y1)
        elseif g.path == "pips" then
            local back = Part(ring, "BORDER", WHITE, 0, 0, 0, 1)
            back:SetSize(7, 6)
            local x, y = RF.Pos(g, (i - 1) / g.N)
            back:SetPoint("CENTER", ring, "CENTER", x + 3.5, y)
            d = Part(ring, "ARTWORK", WHITE)
            d:SetSize(5, 4)
            d:SetPoint("CENTER", back, "CENTER")
        else
            d = Part(ring, "ARTWORK", g.game and ns.Look.SBAR or WHITE)
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
        ring.dots[i] = d
    end
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
        local inner = Part(ring, "ARTWORK", DISC, 0, 0, 0, 1, 2)
        inner:SetPoint("CENTER"); inner:SetSize(g.big[1] + 10, g.big[1] + 10)
        ring.bezel2 = Bezel(ring, "ARTWORK", g.big[1] + 8, 3)
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
    if g.name then
        big.name:SetPoint("TOPLEFT", ring, "TOPLEFT", g.name[1], g.name[2])
        big.name:SetWidth(96)
        big.name:SetJustifyH("LEFT")
        big.showName = true
    else
        big.name:SetPoint("LEFT", ring, "RIGHT", 6, 7)
    end
    big.hint:SetPoint("TOPLEFT", big.name, "BOTTOMLEFT", 0, -2)
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
        if g.game then
            s.qs = s:CreateTexture(nil, "OVERLAY")
            ns.Look:QuickFrame(s.qs, s)
        end
        if g.queue == "top" then
            s:SetAlpha(0.85 - (i - 1) * 0.2)
            s:SetPoint("TOPLEFT", ring, "TOPLEFT", g.queueAt[1] + (i - 1) * g.queueAt[4], g.queueAt[2])
        else
            s:SetAlpha(i == 1 and 0.8 or 0.45)
            if i == 1 then s:SetPoint("RIGHT", ring, "LEFT", -g.queueGap, 0)
            else s:SetPoint("RIGHT", face.small[i - 1], "LEFT", -6, 0) end
        end
        face.small[i] = s
    end
    return face
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
}
local function PaintTile(prefix)
    local sm = SAMPLE[prefix] or SAMPLE.swing
    return function(tile, t)
        if not tile.face then
            local face = RF:BuildFace(tile, t.key)
            local g = face.geo
            -- the queue sits outside the left of round / square faces: fit the face and that
            local qw = g.queue == "left" and 56 or 0
            local s = min((TILE_W - 10) / (g.W + qw), (TILE_H - 26) / g.H)
            face.root:SetScale(s)
            face.root:SetPoint("CENTER", tile, "TOPLEFT", (TILE_W / 2 + qw * s / 2) / s, -((TILE_H - 18) / 2 + 1) / s)
            face.big.icon:SetTexture(sm.big)
            face.seal.icon:SetTexture(sm.badge)
            for i, s2 in ipairs(face.small) do
                if sm.small[i] then s2.icon:SetTexture(sm.small[i]); s2:Show() else s2:Hide() end
            end
            face.big.name:SetText(face.big.showName and (prefix == "shot" and "Steady Shot" or "Seal of Blood") or "")
            RF:Paint(face, sm.p)
            tile.face = face
        end
    end
end

-- The timer's Theme row in its Settings card (this timer only).
function RF:SettingsRow(S, sec, prefix)
    ns.Themes:SettingsRow(S, sec, KindOf(prefix), "Theme", "The look of this timer.",
        { tileW = TILE_W, tileH = TILE_H, gap = 8, nameY = 6, clip = true, paint = PaintTile(prefix),
          hint = "Your timer shows it while you point at it.",
          onPick = function()
              local r = RF.rings[prefix]
              if r then r:Refresh() end
          end })
end

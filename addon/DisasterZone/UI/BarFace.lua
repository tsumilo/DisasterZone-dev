if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BarFace.lua", ...) then return end -- DisasterZone: class tool bar faces.
-- The look of the class tool bars (UI/BlessingsBar.lua, UI/TotemBar.lua): themes, one face per cell, one way to lay
-- the cells out, and the motion. Mockup dev/art/casc/bar_themes/build_themes.py (the user approved it 2026-10-11).
-- The rule: a theme draws ONE face, and the rail (vertical) and the strip (horizontal) use that same face, the same
-- cell size and the same gap; only the axis turns. The header cells (aura, Symbols / Heroism, Mana Tide) come first
-- on the axis, then a divider, then the rows. The thing to do next lifts out of the line toward its chip: up in the
-- strip, left in the rail; the chip is the same chip in both. Colours everywhere: calm, red when it runs short, gold
-- on the next one (and on a header that is on / ready).
-- Themes (setting classbar.theme, one for every class tool bar on the account):
--   halo    round icons, a thin ring that drains (the cooldown swipe on Media/Blessings/ring)
--   sigil   square action-button tiles; the spent time darkens the icon (a reversed cooldown swipe); edge = state
--   slate   quiet glass cards; a hairline under the icon shrinks with the time left
--   gilded  a gold bezel around each round icon (Media/Blessings/bezel, art pack 7); the time runs in a groove
--   pips    small and dense: 24 px icons, a 2 px bar beneath, a class dot
-- Everything here is looks: faces sit on the bars' secure buttons and never touch them, so they move in combat too.
local addonName, ns = ...

local Face = ns:NewModule("BarFace")

local floor, max, min, exp, abs = math.floor, math.max, math.min, math.exp, math.abs

local RING = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\ring"
local BEZEL = "Interface\\AddOns\\DisasterZone\\Media\\Blessings\\bezel"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local GOLD = { 1, 0.82, 0, 1 }
local RED = { 0.91, 0.38, 0.3, 1 }
local CALM = { 0.91, 0.89, 0.82, 0.75 }
local DIM = { 0.6, 0.6, 0.62, 0.5 }
local PALE = { 0.96, 0.9, 0.72, 0.9 }          -- gilded's calm: pale gold
local GLASS = { 0.047, 0.047, 0.059 }
Face.GOLD, Face.RED, Face.CALM = GOLD, RED, CALM

-- W x H: the cell; GAP between cells on either axis; corner / miss: the corner icon's and the red count's centre
-- from the cell's centre; glow: the soft gold light behind the next one (0: none, the theme lights its edge).
Face.THEMES = {
    { key = "halo", name = "Halo", tip = "Round icons with a thin ring that drains.",
      W = 34, H = 34, GAP = 10, round = true, corner = { 12, 12 }, cs = 13, miss = { -12, 12 }, glow = 2.4, num = 10 },
    { key = "sigil", name = "Sigil", tip = "Square tiles like action buttons: the spent time darkens the icon.",
      W = 32, H = 32, GAP = 8, corner = { 12, 12 }, cs = 13, miss = { -12, 12 }, glow = 2.2, num = 10 },
    { key = "slate", name = "Slate", tip = "Quiet glass cards: a hairline under the icon shrinks with the time left.",
      W = 34, H = 34, GAP = 6, corner = { 11, 14 }, cs = 13, miss = { -14, 14 }, glow = 0, num = 10 },
    { key = "gilded", name = "Gilded", tip = "A gold bezel around each round icon; the time runs in a groove inside it.",
      W = 38, H = 38, GAP = 9, round = true, corner = { 13, 13 }, cs = 14, miss = { -13, 13 }, glow = 2.4, num = 11 },
    { key = "pips", name = "Pips", tip = "Small and dense: little icons with a bar beneath and a class dot.",
      W = 24, H = 28, GAP = 4, corner = { 9, 12 }, cs = 8, miss = { -10, 12 }, glow = 0, num = 9, dot = true },
}
Face.DEFAULT = "halo"
-- (one registry with the meter themes: UI/Comp/Themes.lua; a hovered tile previews on the bars)
Face.BY_KEY = ns.Themes:Define("classbar", Face.THEMES, Face.DEFAULT, { setting = "classbar.theme",
    onPreview = function() Face:Refresh() end }).byKey
local PAD, LIFT = 8, 6

-- The theme in use (a hovered tile in Settings previews another one).
function Face:Theme()
    return ns.Themes:Current("classbar")
end

local function UI() return ns.UI end

local function Fill(tex, r, g, b, a)
    tex:SetTexture(WHITE8)
    tex:SetVertexColor(r, g, b, a or 1)
    return tex
end

local function Edge(f, r, g, b, a)
    if not f.edges then UI():AddEdges(f) end
    UI():SetEdgeColor(f, r, g, b, a)
end

local function Mix(a, b, t) return a + (b - a) * t end

-- A round icon the way the game makes portraits round (a mask on an icon came out in stripes on this client).
local function SetRoundIcon(tex, path)
    if tex.iconKey == "r" .. tostring(path) then return end
    tex.iconKey = "r" .. tostring(path)
    tex:SetVertexColor(1, 1, 1, 1)
    tex:SetTexture(path)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if SetPortraitToTexture and type(path) == "string" then
        tex:SetTexCoord(0, 1, 0, 1)
        SetPortraitToTexture(tex, path)
    end
end
Face.SetRoundIcon = SetRoundIcon

local function SetSquareIcon(tex, path)
    if tex.iconKey == "s" .. tostring(path) then return end
    tex.iconKey = "s" .. tostring(path)
    tex:SetVertexColor(1, 1, 1, 1)
    tex:SetTexture(path)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
end

local function Cooldown(parent, swipe)
    local cd = CreateFrame("Cooldown", nil, parent, "CooldownFrameTemplate")
    if swipe and cd.SetSwipeTexture then cd:SetSwipeTexture(swipe) end
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end
    if cd.SetDrawBling then cd:SetDrawBling(false) end
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
    cd:EnableMouse(false)
    return cd
end

local function SetSwipe(cd, start, total)
    if start and total and total > 0 then
        local s = floor(start * 2 + 0.5) / 2
        if cd.cdStart ~= s or cd.cdDur ~= total then
            cd.cdStart, cd.cdDur = s, total
            cd:SetCooldown(s, total)
        end
    elseif cd.cdStart then
        cd.cdStart, cd.cdDur = nil, nil
        if cd.Clear then cd:Clear() else cd:SetCooldown(0, 0) end
    end
end

-- ---------------------------------------------------------------------------------------------------------------
-- A face: every part any theme needs (Skin shows the theme's); row = the button it sits on.
-- ---------------------------------------------------------------------------------------------------------------
function Face:New(row)
    local f = CreateFrame("Frame", nil, row)
    f:SetSize(34, 34)
    f:SetPoint("CENTER")
    f.row = row
    f.glow = f:CreateTexture(nil, "BACKGROUND")
    f.glow:SetTexture(SOFT)
    f.glow:SetPoint("CENTER")
    f.glow:SetVertexColor(1, 0.78, 0.16, 0.55)
    f.glow:SetAlpha(0)
    f.halo = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.halo:SetTexture(SOFT)
    f.halo:SetPoint("CENTER")
    f.halo:SetBlendMode("ADD")
    f.halo:SetVertexColor(1, 1, 1)
    f.halo:SetAlpha(0)
    f.bloom = f:CreateTexture(nil, "OVERLAY", nil, 2)
    f.bloom:SetPoint("CENTER")
    f.bloom:SetBlendMode("ADD")
    f.bloom:Hide()
    -- slate: the card
    f.card = Fill(f:CreateTexture(nil, "BACKGROUND", nil, 2), GLASS[1], GLASS[2], GLASS[3], 0.82)
    f.cardEdge = CreateFrame("Frame", nil, f)
    -- round: the black disc (the edge), gilded's bezel and groove
    f.disc = f:CreateTexture(nil, "BORDER", nil, -2)
    f.disc:SetTexture(DISC)
    f.disc:SetVertexColor(0, 0, 0, 1)
    f.bezel = f:CreateTexture(nil, "BORDER", nil, -1)
    f.groove = f:CreateTexture(nil, "BORDER", nil, 0)
    f.groove:SetTexture(DISC)
    f.groove:SetVertexColor(0.078, 0.055, 0.016, 1)
    -- square: black, the state's edge, black, the icon
    f.sq1 = Fill(f:CreateTexture(nil, "BORDER", nil, -2), 0, 0, 0, 1)
    f.sq2 = Fill(f:CreateTexture(nil, "BORDER", nil, -1), CALM[1], CALM[2], CALM[3], 0.32)
    f.sq3 = Fill(f:CreateTexture(nil, "BORDER", nil, 0), 0, 0, 0, 1)
    -- the ring's track and the draining ring (a cooldown swipe)
    f.track = f:CreateTexture(nil, "BORDER", nil, 1)
    f.track:SetTexture(RING)
    f.cd = Cooldown(f, RING)
    if f.cd.SetUseCircularEdge then f.cd:SetUseCircularEdge(true) end
    f.cd:SetFrameLevel(f:GetFrameLevel() + 1)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    -- a flat atlas icon (UI.ICON) on a dark face instead of a spell's icon: the cells that open something
    f.glyph = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.glyph:SetVertexColor(0.96, 0.9, 0.72, 0.85)
    f.glyph:Hide()
    -- a dark swipe over the icon: sigil's spent time, a header's cooldown
    f.cdDark = Cooldown(f)
    f.cdDark:SetFrameLevel(f:GetFrameLevel() + 2)
    f.top = CreateFrame("Frame", nil, f)
    f.top:SetAllPoints()
    f.top:SetFrameLevel(f:GetFrameLevel() + 4)
    f.bezelHot = f.top:CreateTexture(nil, "BACKGROUND")
    f.bezelHot:SetBlendMode("ADD")
    f.barBg = Fill(f.top:CreateTexture(nil, "BORDER"), 1, 1, 1, 0.1)
    f.barFill = Fill(f.top:CreateTexture(nil, "ARTWORK"), CALM[1], CALM[2], CALM[3], 1)
    f.cornerBg = f.top:CreateTexture(nil, "OVERLAY", nil, -1)
    f.cornerBg:SetTexture(DISC)
    f.cornerBg:SetVertexColor(0, 0, 0, 1)
    f.corner = f.top:CreateTexture(nil, "OVERLAY")
    f.num = f.top:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.num:SetJustifyH("RIGHT")
    f.miss = UI():CreateCountBadge(f.top, 12)
    for _, t in ipairs(f.miss.body or {}) do t:SetVertexColor(RED[1], RED[2], RED[3], 1) end
    if f.miss.fs then f.miss.fs:SetTextColor(1, 1, 1) end
    if f.miss.SetCutout then f.miss:SetCutout(GLASS[1], GLASS[2], GLASS[3]) end
    f.miss:SetFrameLevel(f.top:GetFrameLevel() + 2)
    -- the chip (the thing to do next says what it needs)
    f.label = CreateFrame("Frame", nil, f)
    f.label:SetHeight(15)
    f.label:SetFrameLevel(f.top:GetFrameLevel() + 3)
    f.label.bg = Fill(f.label:CreateTexture(nil, "BACKGROUND"), GOLD[1], GOLD[2], GOLD[3], 1)
    f.label.bg:SetAllPoints()
    f.label.text = f.label:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    local path, _, flags = f.label.text:GetFont()
    if path then f.label.text:SetFont(path, 10, flags) end
    f.label.text:SetPoint("CENTER", 0, 0)
    f.label:Hide()
    f.st = {}
    return f
end

local PARTS = { "card", "cardEdge", "disc", "bezel", "groove", "sq1", "sq2", "sq3", "track", "cd", "cdDark", "bezelHot",
    "barBg", "barFill" }

local function Box(tex, f, x, y, w, h)
    tex:ClearAllPoints()
    tex:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    tex:SetSize(w, h)
end

local function Centered(tex, f, size, dy)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", f, "CENTER", 0, dy or 0)
    tex:SetSize(size, size)
end

-- Lays a face out for a theme and an axis ("v" rail | "h" strip). Only when one of them changes: re-anchoring a
-- cooldown ring redraws it (it blinked every second in game when it was done on each update).
function Face:Skin(f, t, axis)
    f.theme, f.axis = t, axis
    f.atX, f.atY, f.iconAt = nil, nil, nil
    f:SetSize(t.W, t.H)
    for _, k in ipairs(PARTS) do f[k]:Hide() end
    f.glow:SetSize(t.W * (t.glow > 0 and t.glow or 2), t.W * (t.glow > 0 and t.glow or 2))
    f.halo:SetSize(t.W * 2, t.W * 2)
    if t.round then
        f.bloom:SetTexture(RING)
        f.bloom:SetVertexColor(1, 0.86, 0.4)
    else
        f.bloom:SetTexture(SOFT)
        f.bloom:SetVertexColor(1, 0.9, 0.55)
    end
    local key, W, H = t.key, t.W, t.H
    -- the icon box: where the icon sits (the corner, the count and the number go by it)
    f.cdDark:ClearAllPoints()
    if key == "halo" then
        Centered(f.disc, f, W + 2)
        Centered(f.track, f, W)
        Centered(f.cd, f, W)
        f.iconSize = W - 8
        f.disc:Show(); f.track:Show(); f.cd:Show()
    elseif key == "gilded" then
        local hasArt = ns.HasAssets and ns:HasAssets(7)
        f.bezel:SetTexture(hasArt and BEZEL or RING)
        f.bezel:SetVertexColor(1, 1, 1, 1)
        if not hasArt then f.bezel:SetVertexColor(0.86, 0.68, 0.3, 1) end
        f.bezelHot:SetTexture(hasArt and BEZEL or RING)
        Centered(f.disc, f, W + 2)
        Centered(f.bezel, f, W)
        Centered(f.bezelHot, f, W)
        Centered(f.groove, f, W - 8)
        Centered(f.track, f, W - 8)
        Centered(f.cd, f, W - 8)
        f.iconSize = W - 14
        f.disc:Show(); f.bezel:Show(); f.groove:Show(); f.track:Show(); f.cd:Show(); f.bezelHot:Show()
    elseif key == "sigil" then
        f.sq1:SetAllPoints(f)
        Box(f.sq2, f, 1, 1, W - 2, H - 2)
        Box(f.sq3, f, 2, 2, W - 4, H - 4)
        f.iconSize = W - 6
        f.sq1:Show(); f.sq2:Show(); f.sq3:Show()
    elseif key == "slate" then
        f.card:SetAllPoints(f)
        f.cardEdge:SetAllPoints(f)
        Edge(f.cardEdge, 1, 1, 1, 0.09)
        Box(f.sq3, f, 3, 2, W - 6, H - 8)
        Box(f.barBg, f, 4, H - 5, W - 8, 2)
        f.barW = W - 8
        f.card:Show(); f.cardEdge:Show(); f.sq3:Show(); f.barBg:Show(); f.barFill:Show()
    elseif key == "pips" then
        Box(f.sq1, f, 0, 0, W, W)
        Box(f.barBg, f, 0, W + 1, W, 3)
        f.barBg:SetVertexColor(0, 0, 0, 1)
        f.barW = W - 2
        f.sq1:Show(); f.barBg:Show(); f.barFill:Show()
    end
    if key ~= "pips" then f.barBg:SetVertexColor(1, 1, 1, 0.1) end
    -- the icon
    f.icon:ClearAllPoints()
    if key == "slate" then
        Box(f.icon, f, 4, 3, W - 8, H - 10)
    elseif key == "pips" then
        Box(f.icon, f, 1, 1, W - 2, W - 2)
    else
        Centered(f.icon, f, f.iconSize)
    end
    f.cdDark:SetAllPoints(f.icon)
    local gs = floor(((key == "slate" and H - 10) or (key == "pips" and W - 2) or f.iconSize) * 0.62)
    f.glyph:ClearAllPoints()
    f.glyph:SetPoint("CENTER", f.icon, "CENTER")
    f.glyph:SetSize(gs, gs)
    if f.cdDark.SetSwipeTexture then f.cdDark:SetSwipeTexture(t.round and DISC or WHITE8) end
    if key == "slate" or key == "pips" then
        f.barFill:ClearAllPoints()
        f.barFill:SetPoint("TOPLEFT", f.barBg, "TOPLEFT", key == "pips" and 1 or 0, key == "pips" and -1 or 0)
        f.barFill:SetHeight(key == "pips" and 1 or 2)
    end
    -- the corner, the red count, the number
    local cs = t.cs
    f.corner:ClearAllPoints()
    f.corner:SetPoint("CENTER", f, "CENTER", t.corner[1], t.corner[2])
    f.cornerBg:ClearAllPoints()
    f.cornerBg:SetPoint("CENTER", f.corner, "CENTER")
    f.miss:ClearAllPoints()
    f.miss:SetPoint("CENTER", f, "CENTER", t.miss[1], t.miss[2])
    local path, _, flags = f.num:GetFont()
    if path then f.num:SetFont(path, t.num, "OUTLINE") end
    f.num:ClearAllPoints()
    f.num:SetPoint("BOTTOMRIGHT", f.icon, "BOTTOMRIGHT", t.round and 4 or 2, t.round and -3 or -1)
    f.cornerKind = nil
    f.cs = cs
    -- the chip: each theme's own
    local lb = f.label
    local text, fpath = lb.text, nil
    fpath = select(1, text:GetFont())
    if fpath then text:SetFont(fpath, key == "pips" and 9 or 10, "") end
    lb:SetHeight(key == "pips" and 13 or 15)
    if key == "slate" then
        lb.bg:SetVertexColor(GLASS[1], GLASS[2], GLASS[3], 0.92)
        text:SetTextColor(1, 0.88, 0.54)
        Edge(lb, GOLD[1], GOLD[2], GOLD[3], 0.6)
    elseif key == "gilded" then
        lb.bg:SetVertexColor(0.16, 0.11, 0.03, 0.95)
        text:SetTextColor(1, 0.88, 0.54)
        Edge(lb, 0.78, 0.6, 0.2, 1)
    else
        lb.bg:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1)
        text:SetTextColor(0.1, 0.08, 0.01)
        Edge(lb, 0, 0, 0, 1)
    end
    self:Set(f, f.st)
    Face.Apply(f)
end

-- What a face shows. st = { icon, desat, alpha (out of reach: lower), cornerClass = "MAGE" | cornerIcon = path,
-- missing = n, num = text, numColor = { r, g, b }, start, total (the time left runs on its own), frac (0..1, when
-- there is no clock, e.g. Earth Shield's charges), short (red), tone = "on" (gold: on / ready) | "warn" (red) |
-- "dim" (cooling down: cdStart, cdDur), chip = text (shown while it is the next one), glyph = a UI.ICON index drawn
-- flat on a dark face in place of the icon }.
function Face:Set(f, st)
    st = st or {}
    f.st = st
    local t = f.theme or Face.BY_KEY[Face.DEFAULT]
    local key = t.key
    if st.glyph then
        if f.icon.iconKey ~= "glyph" .. tostring(t.round) then
            f.icon.iconKey = "glyph" .. tostring(t.round)
            f.icon:SetTexture(t.round and DISC or WHITE8)
            f.icon:SetTexCoord(0, 1, 0, 1)
        end
        f.icon:SetVertexColor(0.09, 0.09, 0.11, 1)
        local c = UI():IconCoords(st.glyph)
        f.glyph:SetTexture(UI().ICON_ATLAS)
        f.glyph:SetTexCoord(c[1], c[2], c[3], c[4])
        f.glyph:Show()
    else
        f.glyph:Hide()
        if st.icon then
            if t.round then SetRoundIcon(f.icon, st.icon) else SetSquareIcon(f.icon, st.icon) end
        end
    end
    f.icon:SetDesaturated(st.desat and true or false)
    f.icon:SetAlpha(st.alpha or 1)
    -- the corner: a class (a circle, or a dot in pips) or a second icon, on a black disc
    local cs = f.cs or t.cs
    if st.cornerClass then
        local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[st.cornerClass]
        if t.dot then
            local cr, cg, cb = UI():ClassColor(st.cornerClass)
            f.corner:SetTexture(DISC)
            f.corner:SetTexCoord(0, 1, 0, 1)
            f.corner:SetVertexColor(cr, cg, cb, 1)
            f.corner.iconKey = nil
        else
            f.corner:SetTexture(CIRCLES)
            f.corner:SetVertexColor(1, 1, 1, 1)
            f.corner.iconKey = nil
            if c then f.corner:SetTexCoord(c[1], c[2], c[3], c[4]) end
        end
        f.corner:SetSize(cs, cs)
        f.cornerBg:SetSize(cs + (t.dot and 2 or 4), cs + (t.dot and 2 or 4))
        f.corner:Show()
        f.cornerBg:Show()
    elseif st.cornerIcon then
        local s = t.dot and 11 or cs
        f.corner:SetVertexColor(1, 1, 1, 1)
        SetRoundIcon(f.corner, st.cornerIcon)
        f.corner:SetSize(s, s)
        f.cornerBg:SetSize(s + 3, s + 3)
        f.corner:Show()
        f.cornerBg:Show()
    else
        f.corner:Hide()
        f.cornerBg:Hide()
    end
    if key == "gilded" then f.cornerBg:SetVertexColor(0.7, 0.54, 0.17, 1) else f.cornerBg:SetVertexColor(0, 0, 0, 1) end
    f.miss:SetCount(st.missing or 0)
    f.num:SetText(st.num or "")
    f.num:SetShown(st.num ~= nil)
    local nc = st.numColor or { 1, 1, 1 }
    f.num:SetTextColor(nc[1], nc[2], nc[3])
    -- time: the ring (halo, gilded) or the dark swipe (sigil) runs on its own; the bars (slate, pips) take a width
    local timed = st.start ~= nil and st.total ~= nil
    f.timed = timed or st.frac ~= nil
    local ring = (key == "halo" or key == "gilded")
    SetSwipe(f.cd, ring and timed and st.start or nil, st.total)
    f.cd:SetAlpha(st.alpha or 1)
    if key == "sigil" and timed then
        if f.cdDark.SetReverse then f.cdDark:SetReverse(true) end
        if f.cdDark.SetSwipeColor then f.cdDark:SetSwipeColor(0, 0, 0, 0.66) end
        SetSwipe(f.cdDark, st.start, st.total)
        f.cdDark:Show()
    elseif st.tone == "dim" and st.cdStart then
        if f.cdDark.SetReverse then f.cdDark:SetReverse(false) end
        if f.cdDark.SetSwipeColor then f.cdDark:SetSwipeColor(0, 0, 0, 0.7) end
        SetSwipe(f.cdDark, st.cdStart, st.cdDur)
        f.cdDark:Show()
    else
        SetSwipe(f.cdDark, nil)
        f.cdDark:Hide()
    end
    if key == "slate" or key == "pips" then
        local frac = st.frac
        if timed then frac = max(0, min(1, (st.start + st.total - GetTime()) / st.total)) end
        if st.tone == "on" then frac = 1 end
        f.frac = frac
        -- (no clock and no state, e.g. the planner, Symbols: no bar at all, not an empty one)
        local none = frac == nil and not st.tone
        f.barBg:SetShown(not none)
        if none then
            f.barFill:Hide()
        else
            f.barFill:SetWidth(max(0.5, f.barW * ((frac and frac > 0) and frac or 1)))
            f.barFill:Show()
        end
    end
    f.label.text:SetText(st.chip or "")
    if st.chip then f.label:SetWidth((f.label.text:GetStringWidth() or 30) + 12) end
    f.labelOff = st.chip == nil
end

-- A bar theme's time bar (slate, pips: a width, not a cooldown that runs on its own) drawn again from the clock, for
-- a bar that ticks without a new look each second.
function Face:Drain(f)
    local st = f.st
    local t = f.theme or Face.BY_KEY[Face.DEFAULT]
    if not st or (t.key ~= "slate" and t.key ~= "pips") then return end
    if not (st.start and st.total and st.total > 0) or st.tone == "on" or f.frac == nil then return end
    local frac = max(0, min(1, (st.start + st.total - GetTime()) / st.total))
    if frac == f.frac then return end
    f.frac = frac
    f.barFill:SetWidth(max(0.5, f.barW * ((frac > 0) and frac or 1)))
    if frac <= 0 then Face.Apply(f) end         -- (run out: the red empty bar)
end

-- The state's colour before the "next" gold is mixed in.
local function Base(f)
    local st = f.st or {}
    local t = f.theme
    if st.tone == "on" then return GOLD end
    if st.tone == "warn" or st.short then return RED end
    if st.tone == "dim" then return DIM end
    if not f.timed then return nil end
    return (t and t.key == "gilded") and PALE or CALM
end

-- ---------------------------------------------------------------------------------------------------------------
-- Motion: each face eases its "hot" (next) look, its lift and its hover toward targets (an exponential approach:
-- quick at first, settling softly), and plays a bloom when it is done again.
-- ---------------------------------------------------------------------------------------------------------------
local TAU = { hot = 0.11, lift = 0.09, hover = 0.07 }
local BLOOM_TAU = 0.3

-- Places and colours what moves, from the face's current values.
function Face.Apply(f)
    local t = f.theme
    if not t then return end
    local m = f.motion
    local cur = m and m.cur or {}
    local hot, lift, hover = cur.hot or 0, cur.lift or 0, cur.hover or 0
    local key = t.key
    -- out of the line toward the chip: up in the strip, left in the rail (re-anchored only when it moves)
    local o = lift + 2 * hover
    local x, y = 0, 0
    if f.axis == "v" then x = -o else y = o end
    if f.atX ~= x or f.atY ~= y or f.atRow ~= f.row then
        f.atX, f.atY, f.atRow = x, y, f.row
        f:ClearAllPoints()
        f:SetPoint("CENTER", f.row, "CENTER", x, y)
    end
    f.glow:SetAlpha((t.glow > 0 and 0.55 or 0) * hot)
    f.glow:SetShown(t.glow > 0)
    f.halo:SetAlpha(0.16 * hover)
    f.halo:SetShown(hover > 0.01)
    f.glyph:SetAlpha(0.8 + 0.2 * hover)
    -- the chip
    f.label:SetAlpha(hot)
    f.label:SetShown(hot > 0.01 and not f.labelOff)
    f.label:ClearAllPoints()
    if f.axis == "v" then f.label:SetPoint("RIGHT", f, "LEFT", -6 - (1 - hot) * 8, 0)
    else f.label:SetPoint("BOTTOM", f, "TOP", 0, 6 - (1 - hot) * 5) end
    -- round icons grow a little on hover
    if t.round and f.iconSize then
        local s = floor((f.iconSize + 2 * hover) * 2 + 0.5) / 2
        if f.iconAt ~= s then
            f.iconAt = s
            f.icon:SetSize(s, s)
        end
    end
    local base = Base(f)
    local function Col(c, a)
        c = c or CALM
        return Mix(c[1], GOLD[1], hot), Mix(c[2], GOLD[2], hot), Mix(c[3], GOLD[3], hot), Mix(a or c[4] or 1, 1, hot)
    end
    if key == "halo" or key == "gilded" then
        if f.timed then
            if f.cd.SetSwipeColor then f.cd:SetSwipeColor(Col(base)) end
            if key == "halo" then
                f.track:SetVertexColor(Mix(0.08, 0.47, hot), Mix(0.08, 0.38, hot), Mix(0.09, 0.04, hot), 0.85 + 0.15 * hover)
            else
                f.track:SetVertexColor(0.96, 0.9, 0.72, 0.14 + 0.1 * hover)
            end
        else
            -- no clock (a header, Symbols): the whole ring in the state's colour, faint when it has none
            if base then f.track:SetVertexColor(Col(base, 1))
            else f.track:SetVertexColor(0.91, 0.89, 0.82, 0.28 + 0.2 * hover) end
        end
        if key == "gilded" then f.bezelHot:SetAlpha(0.6 * hot) end
    elseif key == "sigil" then
        local quiet = f.timed and not (f.st.short or f.st.tone)
        if quiet then f.sq2:SetVertexColor(Col(CALM, 0.32 + 0.25 * hover))
        else f.sq2:SetVertexColor(Col(base or { CALM[1], CALM[2], CALM[3], 0.32 })) end
    elseif key == "slate" then
        f.card:SetVertexColor(Mix(GLASS[1], 0.18, hot), Mix(GLASS[2], 0.14, hot), Mix(GLASS[3], 0.03, hot), Mix(0.82, 0.92, hot))
        Edge(f.cardEdge, Mix(1, GOLD[1], hot), Mix(1, GOLD[2], hot), Mix(1, GOLD[3], hot), Mix(0.09 + 0.12 * hover, 0.85, hot))
    elseif key == "pips" then
        f.sq1:SetVertexColor(Mix(0, GOLD[1], hot), Mix(0, GOLD[2], hot), Mix(0, GOLD[3], hot), 1)
    end
    if key == "slate" or key == "pips" then
        local missing = f.frac ~= nil and f.frac <= 0 and not (f.st and f.st.tone)
        local c = missing and RED or base
        local r, g, b, a = Col(c)
        f.barFill:SetVertexColor(r, g, b, missing and 0.55 or a)
    end
    -- the bloom when it is done again
    local bl = m and m.bloom
    if bl and bl > 0.01 then
        local size = (t.round and t.W + 4 or t.W * 1.6) * (1 + 0.65 * (1 - bl))
        f.bloom:SetSize(size, size)
        f.bloom:SetAlpha(0.85 * bl)
        f.bloom:Show()
    else
        f.bloom:Hide()
    end
end

function Face.Step(f, dt)
    local m = f.motion
    local settled = true
    for k, target in pairs(m.tgt) do
        local v = m.cur[k] or target
        v = v + (target - v) * (1 - exp(-dt / (TAU[k] or 0.12)))
        if abs(v - target) < 0.003 then v = target else settled = false end
        m.cur[k] = v
    end
    if m.bloom then
        m.bloom = m.bloom * exp(-dt / BLOOM_TAU)
        if m.bloom < 0.01 then m.bloom = nil else settled = false end
    end
    Face.Apply(f)
    return settled
end

local function Run(f)
    if f.moving then return end
    f.moving = true
    f:SetScript("OnUpdate", function(self, elapsed)
        if Face.Step(self, min(elapsed or 0, 0.1)) then
            self.moving = false
            self:SetScript("OnUpdate", nil)
        end
    end)
end

-- New targets for a face (hot 0..1, lift px, hover 0..1); bloom: play the "done again" bloom. The first targets are
-- taken as they are (no motion when the bar first shows).
function Face.Aim(f, tgt, bloom)
    local m = f.motion
    if not m then
        f.motion = { cur = {}, tgt = tgt }
        for k, v in pairs(tgt) do f.motion.cur[k] = v end
        Face.Apply(f)
        return
    end
    m.tgt = tgt
    if bloom then m.bloom = 1 end
    local moving = m.bloom ~= nil
    for k, v in pairs(tgt) do
        if abs((m.cur[k] or v) - v) > 0.003 then moving = true end
    end
    if moving then Run(f) else Face.Apply(f) end
end

-- The usual targets: next (hot + lift out of the line), the mouse over it.
function Face:Targets(f, isNext)
    return { hot = isNext and 1 or 0, lift = isNext and LIFT or 0, hover = f.hoverOn and 1 or 0 }
end

-- The mouse over a face: it eases into its hover look (and back when it leaves).
function Face:Hover(f, on)
    f.hoverOn = on and true or false
    local m = f.motion
    if not m then return end
    local t = {}
    for k, v in pairs(m.tgt) do t[k] = v end
    t.hover = on and 1 or 0
    Face.Aim(f, t)
end

-- The first cell of a class tool bar: opens its planner (never casts: a plain button, the flat notes icon). title =
-- "Blessings planner" ...; open() opens it. The bar places it with its header and calls Face:ShowPlanner(b) on update.
function Face:PlannerCell(parent, title, open)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(34, 34)
    b:RegisterForClicks("LeftButtonUp")
    b.face = self:New(b)
    b.isPlanner = true
    b:SetScript("OnClick", function() open() end)
    b:SetScript("OnEnter", function(self)
        Face:Hover(self.face, true)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine("Click: open it", 0.85, 0.85, 0.85)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        Face:Hover(self.face, false)
        GameTooltip:Hide()
    end)
    return b
end

function Face:ShowPlanner(b)
    self:Set(b.face, { glyph = UI().ICON.notes })
    Face.Aim(b.face, self:Targets(b.face, false))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Layout (out of combat: it moves secure buttons). cells = the buttons in order, each with .face; the first nHead are
-- the header (a divider after them). axis "v" (rail, top to bottom) | "h" (strip, left to right).
-- ---------------------------------------------------------------------------------------------------------------
function Face:Place(frame, cells, nHead, axis, t)
    t = t or self:Theme()
    local W, H, G = t.W, t.H, t.GAP
    if not frame.faceDiv then frame.faceDiv = Fill(frame:CreateTexture(nil, "ARTWORK"), CALM[1], CALM[2], CALM[3], 0.2) end
    local div = frame.faceDiv
    local along = axis == "v" and H or W
    local cross = axis == "v" and W or H
    local pos = PAD
    div:Hide()
    for i, b in ipairs(cells) do
        if i == nHead + 1 and nHead > 0 then
            div:ClearAllPoints()
            if axis == "v" then
                div:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + floor(W * 0.15), -pos)
                div:SetSize(W - 2 * floor(W * 0.15), 1)
            else
                div:SetPoint("TOPLEFT", frame, "TOPLEFT", pos, -(PAD + floor(H * 0.15)))
                div:SetSize(1, H - 2 * floor(H * 0.15))
            end
            div:Show()
            pos = pos + G + 1
        end
        b:ClearAllPoints()
        b:SetSize(W, H)
        if axis == "v" then b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -pos)
        else b:SetPoint("TOPLEFT", frame, "TOPLEFT", pos, -PAD) end
        self:Skin(b.face, t, axis)
        pos = pos + along + G
    end
    local length = pos - G + PAD
    if axis == "v" then frame:SetSize(cross + 2 * PAD, max(length, 2 * PAD)) else frame:SetSize(max(length, 2 * PAD), cross + 2 * PAD) end
    frame.faceTheme = t.key
end

-- ---------------------------------------------------------------------------------------------------------------
-- Settings: the theme picker (a tile per theme with a live preview: three cells of the strip)
-- ---------------------------------------------------------------------------------------------------------------
local TILE_W, TILE_H = 96, 66
local PREVIEW = {
    { icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings", cornerClass = "WARRIOR", frac = 0.86 },
    { icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings", cornerClass = "MAGE", frac = 0, missing = 2 },
    { icon = "Interface\\Icons\\Spell_Magic_GreaterBlessingofKings", cornerClass = "PRIEST", frac = 0.11, short = true },
}

-- Repaints the bars that use the faces (the theme changed or a tile is hovered).
function Face:Refresh()
    if InCombatLockdown() then return end
    if ns.BlessingsBar and ns.BlessingsBar.Update then ns.BlessingsBar:Update() end
    if ns.TotemBar and ns.TotemBar.Update then ns.TotemBar:Update() end
end

function Face:SetPreview(key)
    ns.Themes:SetPreview("classbar", key)
end

local function FillPreview(holder, t)
    holder.cells = holder.cells or {}
    holder:SetSize(3 * t.W + 2 * t.GAP, t.H)
    for i, p in ipairs(PREVIEW) do
        local cell = holder.cells[i]
        if not cell then
            cell = CreateFrame("Frame", nil, holder)
            cell.face = Face:New(cell)
            holder.cells[i] = cell
        end
        cell:ClearAllPoints()
        cell:SetSize(t.W, t.H)
        cell:SetPoint("TOPLEFT", holder, "TOPLEFT", (i - 1) * (t.W + t.GAP), 0)
        Face:Skin(cell.face, t, "h")
        local total = 1800
        local st = { icon = p.icon, cornerClass = p.cornerClass, missing = p.missing, short = p.short, total = total }
        if p.frac > 0 then st.start = GetTime() - (1 - p.frac) * total else st.frac, st.total = 0, nil end
        Face:Set(cell.face, st)
        cell.face.motion = nil
        Face.Aim(cell.face, { hot = 0, lift = 0, hover = 0 })
    end
    local s = min(1, (TILE_W - 12) / (3 * t.W + 2 * t.GAP))
    holder:SetScale(s)
end

-- A tile's sample: three cells of the strip, centred above the name.
local function PaintTile(tile, t)
    FillPreview(tile.preview, t)
    local s = tile.preview:GetScale() or 1
    local pw = (3 * t.W + 2 * t.GAP) * s
    tile.preview:ClearAllPoints()
    tile.preview:SetPoint("TOPLEFT", tile, "TOPLEFT", ((TILE_W - pw) / 2) / s, -((TILE_H - 18 - t.H * s) / 2 + 2) / s)
end

-- One row in a class tool's Settings card: "Theme" and a tile per theme under it.
function Face:SettingsRow(S, sec)
    local strip = ns.Themes:SettingsRow(S, sec, "classbar", "Theme",
        "One look for every class tool bar on this account; the rail and the strip share it.",
        { tileW = TILE_W, tileH = TILE_H, gap = 8, nameY = 6, paint = PaintTile,
          hint = "Your bar shows it while you point at it.", onPick = function() Face:Refresh() end })
    return strip
end

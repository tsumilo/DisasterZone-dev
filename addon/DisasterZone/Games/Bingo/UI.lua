if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/UI.lua", ...) then return end -- DisasterZone Games/Bingo/UI.lua
-- ns.BingoUI: the Council Bingo panel and a small movable counter ("Bingo 12/25") shown while a game runs and
-- the main window is closed.
-- The panel, in the hub's look: a header banner (the raid's loading screen, LIVE, host, your marked / lines /
-- one-away numbers, Start / End), the B-I-N-G-O card filling the stage (square icon + who set it off on top, the
-- square's text under it, rarity on the edge; your raid-marker "dauber" stamped on every marked square, a pulse on
-- squares one away from a line, a glowing gold line through every completed line with a BINGO! slam), and a right
-- column with the live race, the feed of marked squares and the season leaderboard. Everything is laid out from
-- the panel's size (the stage under the hub's strip).
local addonName, ns = ...

local BingoUI = ns:NewModule("BingoUI")
local Util = ns.Util

local floor, min, max = math.floor, math.min, math.max

local PAD, GAP = 10, 8                       -- the page's spacing grid
local HERO_H, SIDE_W, FOOT_H = 78, 236, 24   -- header banner, right column, dauber row under the card
local LETTER_H, CARD_PAD, CELL_GAP = 22, 8, 4
local FALLBACK_W, FALLBACK_H = 786, 518     -- the stage before the client has laid it out
local RACE_ROWS, FEED_ROWS, SEASON_ROWS = 5, 5, 3
local FONT = "Fonts\\FRIZQT__.TTF"
local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local CIRCLE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RADIAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\MyBiS\\Radial"
local SEAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\Launcher\\seal"
local STAMP_ALPHA = 1

local RARITY = {
    c = { 0.86, 0.86, 0.86, name = "Common", edge = 0.10 },
    r = { 0.35, 0.65, 1.0, name = "Rare", edge = 0.45 },
    l = { 1.0, 0.5, 0.0, name = "Legendary", edge = 0.7 },
}
local GOLD = { 1, 0.82, 0 }
local LETTERS = {
    { "B", 0.35, 0.65, 1 }, { "I", 1, 0.35, 0.35 }, { "N", 1, 1, 1 }, { "G", 0.35, 1, 0.35 }, { "O", 1, 0.82, 0 },
}
local MARKER_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

local panel, hero, card, grid, cells, overlay, lineTex, lineGlow, slam, statusText, startBtn, stopBtn, announceBox
local dauberBar, dauberBtns, side, raceRows, feedRows, seasonRows, raceEmpty, feedEmpty, seasonEmpty, stats
local mini

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function View()
    local d = ns.Games:GetData("bingo")
    if type(d.view) ~= "table" then d.view = {} end
    return d.view
end

local function Dauber()
    local n = tonumber(ns.Games:GetData("bingo").dauber) or 1
    if n < 1 or n > 8 then n = 1 end
    return n
end

-- Lines, marked, cells on a complete line, complete line indexes, cells one square away from a line.
local function Analyze(cardIds, hits)
    local Card = ns.BingoCard
    local lines, marked, onLine, full, away = 0, 0, {}, {}, {}
    for cell = 1, Card.CELLS do
        if Card.IsMarked(cardIds[cell], hits) then marked = marked + 1 end
    end
    for li, line in ipairs(Card.LINES) do
        local missing, gap = 0, nil
        for _, cell in ipairs(line) do
            if not Card.IsMarked(cardIds[cell], hits) then
                missing = missing + 1
                gap = cell
            end
        end
        if missing == 0 then
            lines = lines + 1
            full[#full + 1] = li
            for _, cell in ipairs(line) do onLine[cell] = true end
        elseif missing == 1 then
            away[gap] = true
        end
    end
    return lines, marked, onLine, full, away
end

local function ShortName(key)
    return (type(key) == "string" and key:match("^([^%-]+)")) or tostring(key)
end

-- A name coloured by class when it's someone in the group (bosses and pets stay gold).
local function WhoText(who)
    if type(who) ~= "string" then return "" end
    for key, info in pairs(Util.group or {}) do
        if ShortName(key) == who and info.classFile then
            return "|c" .. Util.ClassColorHex(info.classFile) .. who .. "|r"
        end
    end
    return "|cffffd100" .. who .. "|r"
end

local function ClassOf(key)
    local info = Util.group and Util.group[key]
    if info and info.classFile then return info.classFile end
    return ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key) or nil
end

local function KeyText(key)
    local cls = ClassOf(key)
    local name = ShortName(key)
    if cls then return "|c" .. Util.ClassColorHex(cls) .. name .. "|r" end
    return name
end

local function ClassRGB(key)
    local cls = ClassOf(key)
    local c = cls and RAID_CLASS_COLORS and RAID_CLASS_COLORS[cls]
    if c then return c.r, c.g, c.b end
    return 0.6, 0.6, 0.6
end

local function Label(parent, size, font, layer, flags)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, f = fs:GetFont()
        if path then fs:SetFont(path, size, flags or f) end
    end
    return fs
end

local gradA = CreateColor and CreateColor(0, 0, 0, 0)
local gradB = CreateColor and CreateColor(0, 0, 0, 0)
-- A gradient (orient "VERTICAL": colour 1 at the bottom) or, without SetGradient, its midpoint.
local function Gradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    tex:SetColorTexture(1, 1, 1, 1)
    if gradA and tex.SetGradient then
        gradA:SetRGBA(r1, g1, b1, a1)
        gradB:SetRGBA(r2, g2, b2, a2)
        tex:SetGradient(orient, gradA, gradB)
    else
        tex:SetColorTexture((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
    end
end

-- A cell's fill, top colour then bottom colour.
local function Fill(c, top, bottom)
    Gradient(c.bg, "VERTICAL", bottom[1], bottom[2], bottom[3], bottom[4] or 0.95, top[1], top[2], top[3], top[4] or 0.95)
end

local function SetScaleAnim(a, from, to)
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from)
        a:SetScaleTo(to, to)
    else
        a:SetScale(to / from, to / from)
    end
end

local function Kicker(parent, text)
    local fs = Label(parent, 9.5)
    fs:SetTextColor(0.62, 0.62, 0.62)
    fs:SetText(text)
    return fs
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

-- The dauber's ink: the colour of each raid marker (star, circle, diamond, triangle, moon, square, cross, skull).
local INK = {
    { 1, 0.86, 0.25 }, { 1, 0.56, 0.16 }, { 0.78, 0.4, 1 }, { 0.35, 0.9, 0.4 },
    { 0.72, 0.82, 1 }, { 0.3, 0.62, 1 }, { 1, 0.3, 0.25 }, { 0.92, 0.92, 0.92 },
}

-- A square: one calm tile for every square (icon centred, the words under it); rarity is a small dot in the
-- corner. Marked: a soft blot of your dauber's ink behind it and the marker in its corner. Who set it off is in
-- the tooltip (and the Latest list).
local function CreateCell(parent, i)
    local b = CreateFrame("Frame", nil, parent)
    b.index = i
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    ns.UI:AddEdges(b, "BORDER", true)
    -- a completed line: a gold bar along the top
    b.rare = b:CreateTexture(nil, "BORDER", nil, 1)
    b.rare:SetPoint("TOPLEFT", 1, 0)
    b.rare:SetPoint("TOPRIGHT", -1, 0)
    b.rare:SetHeight(2)
    b.rare:SetColorTexture(1, 0.82, 0, 1)
    b.rare:Hide()

    -- the ink blot (marked), behind everything else on the square
    b.ink = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.ink:SetTexture(RADIAL)
    b.ink:SetPoint("CENTER", 0, 0)
    b.ink:SetSize(70, 70)
    b.ink:Hide()

    -- "one away" pulse
    b.pulse = b:CreateTexture(nil, "BACKGROUND", nil, 3)
    b.pulse:SetPoint("TOPLEFT", 1, -1)
    b.pulse:SetPoint("BOTTOMRIGHT", -1, 1)
    b.pulse:SetColorTexture(1, 0.82, 0, 1)
    b.pulse:SetBlendMode("ADD")
    b.pulse:SetAlpha(0)
    b.pulse:Hide()
    b.pulseAnim = b.pulse:CreateAnimationGroup()
    b.pulseAnim:SetLooping("BOUNCE")
    local p = b.pulseAnim:CreateAnimation("Alpha")
    p:SetFromAlpha(0.02)
    p:SetToAlpha(0.14)
    p:SetDuration(0.9)
    p:SetSmoothing("IN_OUT")

    -- the words, on a frame above the gold threads of completed lines (CreateCard sets its level)
    b.top = CreateFrame("Frame", nil, b)
    b.top:SetAllPoints()
    b.icon = b.top:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("TOP", 0, -7)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.iconEdge = b.top:CreateTexture(nil, "ARTWORK", nil, -1)
    b.iconEdge:SetPoint("TOPLEFT", b.icon, "TOPLEFT", -1, 1)
    b.iconEdge:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 1, -1)
    b.iconEdge:SetColorTexture(0, 0, 0, 0.9)
    -- the rarity ring round the icon (a 1px border, so an icon-less square stays dark inside)
    b.ring = CreateFrame("Frame", nil, b.top)
    b.ring:SetPoint("TOPLEFT", b.icon, "TOPLEFT", -2, 2)
    b.ring:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 2, -2)
    ns.UI:AddEdges(b.ring, "OVERLAY")
    b.ring:Hide()
    b.icon2 = b.top:CreateTexture(nil, "ARTWORK", nil, 2)
    b.icon2:SetSize(10, 10)
    b.icon2:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", -4, -2)
    b.badge = b.top:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    b.badge:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 3, -1)
    -- rarity, like item quality: the icon's border in its colour, a soft wash of it from the top of the square, and
    -- on a legendary square a light that sweeps across now and then (BingoUI's OnUpdate)
    b.wash = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.wash:SetPoint("TOPLEFT", 1, -1)
    b.wash:SetPoint("TOPRIGHT", -1, -1)
    b.wash:Hide()
    b.sheen1 = b:CreateTexture(nil, "BORDER", nil, 2)
    b.sheen2 = b:CreateTexture(nil, "BORDER", nil, 2)
    for _, t in ipairs({ b.sheen1, b.sheen2 }) do
        t:SetBlendMode("ADD")
        t:Hide()
    end

    b.text = Label(b.top, 10, "GameFontHighlightSmall")
    b.text:SetWordWrap(true)
    b.text:SetJustifyH("CENTER")
    b.text:SetJustifyV("TOP")
    b.text:SetPoint("TOP", b.icon, "BOTTOM", 0, -5)
    b.text:SetPoint("LEFT", 5, 0)
    b.text:SetPoint("RIGHT", -5, 0)
    b.text:SetPoint("BOTTOM", 0, 3)
    -- (who set it off: kept for the tooltip and the tests, not drawn on the square)
    b.who = Label(b.top, 10, "GameFontHighlightSmall")
    b.who:Hide()
    b.ribbon = b.who

    -- the dauber's marker in the corner, landing with a stamp and a flash
    b.stamp = b.top:CreateTexture(nil, "OVERLAY", nil, 5)
    b.stamp:SetSize(16, 16)
    b.stamp:SetPoint("TOPRIGHT", -4, -4)
    b.stampAnim = b.stamp:CreateAnimationGroup()
    local s = b.stampAnim:CreateAnimation("Scale")
    SetScaleAnim(s, 2.8, 1)
    s:SetDuration(0.22)
    s:SetSmoothing("IN")
    if s.SetOrigin then s:SetOrigin("CENTER", 0, 0) end
    local a = b.stampAnim:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(STAMP_ALPHA)
    a:SetDuration(0.12)
    b.stampAnim:SetScript("OnFinished", function() b.stamp:SetAlpha(STAMP_ALPHA) end)
    b.stampParts = { s, a }

    b.flash = b.top:CreateTexture(nil, "OVERLAY", nil, 6)
    b.flash:SetAllPoints()
    b.flash:SetColorTexture(1, 0.9, 0.5, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAlpha(0)
    b.flashAnim = b.flash:CreateAnimationGroup()
    local f = b.flashAnim:CreateAnimation("Alpha")
    f:SetFromAlpha(0.35)
    f:SetToAlpha(0)
    f:SetDuration(0.5)
    b.flashAnim:SetScript("OnFinished", function() b.flash:SetAlpha(0) end)
    b.flashPart = f

    b:EnableMouse(true)
    b:SetScript("OnEnter", function(self)
        self.hl:Show()
        if self.tip then ns.UI:SetTextTooltip(self, self.tip) end
    end)
    b:SetScript("OnLeave", function(self)
        self.hl:Hide()
        ns.UI:HideTooltip()
    end)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.035)
    b.hl:Hide()
    return b
end

-- Plays the stamp landing on a cell, after delay seconds.
-- The legendary light at e (0..1) across cell c: two ADD gradient halves, cut at the square's edges by hand.
local SHEEN_EVERY, SHEEN_TIME, SHEEN_W = 5.5, 1.1, 40
local function PlaceSheen(c, e)
    local w = c:GetWidth() or 0
    if w <= 0 then return end
    local x = -SHEEN_W / 2 + (w + SHEEN_W) * e
    local a = 0.16
    for k, half in ipairs({ { x - SHEEN_W / 2, x, 0, a }, { x, x + SHEEN_W / 2, a, 0 } }) do
        local tex = c["sheen" .. k]
        local x0, x1, a0, a1 = half[1], half[2], half[3], half[4]
        local l, r = max(1, x0), min(w - 1, x1)
        if r - l < 0.5 then
            tex:Hide()
        else
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", c, "TOPLEFT", l, -1)
            tex:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", l, 1)
            tex:SetWidth(r - l)
            local span = x1 - x0
            Gradient(tex, "HORIZONTAL", 1, 0.75, 0.4, a0 + (a1 - a0) * (l - x0) / span,
                1, 0.75, 0.4, a0 + (a1 - a0) * (r - x0) / span)
            tex:SetBlendMode("ADD")
            tex:Show()
        end
    end
end

local function StampIn(c, delay)
    c.stamp:SetAlpha(0)
    for _, anim in ipairs(c.stampParts) do anim:SetStartDelay(delay) end
    c.stampAnim:Stop()
    c.stampAnim:Play()
    c.flash:SetAlpha(0)
    c.flashPart:SetStartDelay(delay + 0.18)
    c.flashAnim:Stop()
    c.flashAnim:Play()
end

local function SetPulse(c, on)
    if on then
        if not c.pulse:IsShown() then
            c.pulse:Show()
            c.pulseAnim:Play()
        end
    elseif c.pulse:IsShown() then
        c.pulseAnim:Stop()
        c.pulse:Hide()
    end
end

local function ShowStamp(c, who, isNew, delay)
    local n = Dauber()
    c.stamp:SetTexture(RAID_ICON .. n)
    c.stamp:Show()
    local ink = INK[n] or INK[1]
    c.ink:SetVertexColor(ink[1], ink[2], ink[3], 0.22)
    c.ink:Show()
    c.who:SetText(who or "")
    if isNew then
        StampIn(c, delay)
    elseif not c.stampAnim:IsPlaying() then
        c.stamp:SetAlpha(STAMP_ALPHA)
    end
end

local function HideStamp(c)
    c.stampAnim:Stop()
    c.stamp:Hide()
    c.ink:Hide()
    c.who:SetText("")
end

---------------------------------------------------------------------------
-- BINGO! slam
---------------------------------------------------------------------------

local function CreateSlam(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:SetFrameLevel(parent:GetFrameLevel() + 8)     -- (over the squares' words, which sit over the lines)
    f.band = f:CreateTexture(nil, "BACKGROUND")
    f.band:SetPoint("LEFT")
    f.band:SetPoint("RIGHT")
    f.band:SetHeight(84)
    f.bandL = f:CreateTexture(nil, "BACKGROUND")
    f.bandL:SetPoint("TOPLEFT", f.band, "TOPLEFT")
    f.bandL:SetPoint("BOTTOMRIGHT", f.band, "BOTTOM")
    Gradient(f.bandL, "HORIZONTAL", 0, 0, 0, 0, 0, 0, 0, 0.82)
    f.bandR = f:CreateTexture(nil, "BACKGROUND")
    f.bandR:SetPoint("TOPLEFT", f.band, "TOP")
    f.bandR:SetPoint("BOTTOMRIGHT", f.band, "BOTTOMRIGHT")
    Gradient(f.bandR, "HORIZONTAL", 0, 0, 0, 0.82, 0, 0, 0, 0)
    f.edgeT = f:CreateTexture(nil, "BORDER")
    f.edgeT:SetPoint("BOTTOMLEFT", f.band, "TOPLEFT", 40, 0)
    f.edgeT:SetPoint("BOTTOMRIGHT", f.band, "TOPRIGHT", -40, 0)
    f.edgeT:SetHeight(1)
    f.edgeB = f:CreateTexture(nil, "BORDER")
    f.edgeB:SetPoint("TOPLEFT", f.band, "BOTTOMLEFT", 40, 0)
    f.edgeB:SetPoint("TOPRIGHT", f.band, "BOTTOMRIGHT", -40, 0)
    f.edgeB:SetHeight(1)
    f.burst = f:CreateTexture(nil, "ARTWORK")
    f.burst:SetTexture(RADIAL)
    f.burst:SetBlendMode("ADD")
    f.burst:SetSize(340, 160)
    f.burst:SetPoint("CENTER", 0, 4)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(FONT, 44, "OUTLINE")
    f.text:SetShadowOffset(2, -2)
    f.text:SetShadowColor(0, 0, 0, 1)
    f.text:SetPoint("CENTER", 0, 6)
    f.sub = Label(f, 11)
    f.sub:SetJustifyH("CENTER")
    f.sub:SetPoint("TOP", f.text, "BOTTOM", 0, -3)
    f.anim = f:CreateAnimationGroup()
    local fadeIn = f.anim:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.1)
    local grow = f.anim:CreateAnimation("Scale")
    SetScaleAnim(grow, 2.5, 1)
    grow:SetDuration(0.25)
    grow:SetSmoothing("IN")
    if grow.SetOrigin then grow:SetOrigin("CENTER", 0, 0) end
    local fadeOut = f.anim:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(1)
    fadeOut:SetToAlpha(0)
    fadeOut:SetStartDelay(2)
    fadeOut:SetDuration(0.6)
    f.anim:SetScript("OnFinished", function() f:Hide() end)
    f:Hide()

    function f:Slam(text, color, sub)
        self.text:SetText(text)
        self.text:SetTextColor(color[1], color[2], color[3])
        self.burst:SetVertexColor(color[1], color[2], color[3], 0.55)
        self.edgeT:SetColorTexture(color[1], color[2], color[3], 0.7)
        self.edgeB:SetColorTexture(color[1], color[2], color[3], 0.7)
        self.sub:SetText(sub or "")
        self:Show()
        self.anim:Stop()
        self.anim:Play()
    end
    return f
end

---------------------------------------------------------------------------
-- Right column
---------------------------------------------------------------------------

-- A list row: a quiet plate, a coloured edge on the left (mine / a bingo), a progress line along its foot,
-- left and right text; r.icon when withIcon.
local function CreateRow(parent, height, withIcon)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(height)
    r.plate = r:CreateTexture(nil, "BACKGROUND")
    r.plate:SetAllPoints()
    r.plate:SetColorTexture(1, 1, 1, 0.025)
    r.mark = r:CreateTexture(nil, "BORDER")
    r.mark:SetPoint("TOPLEFT")
    r.mark:SetPoint("BOTTOMLEFT")
    r.mark:SetWidth(2)
    r.mark:Hide()
    r.bar = r:CreateTexture(nil, "BORDER", nil, 1)
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetHeight(2)
    r.bar:SetWidth(1)
    local x = 8
    if withIcon then
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(14, 14)
        r.icon:SetPoint("LEFT", 6, 0)
        r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        x = 26
    end
    r.left = Label(r, 11, "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", x, 0)
    r.right = Label(r, 11, "GameFontHighlightSmall")
    r.right:SetJustifyH("RIGHT")
    r.right:SetPoint("RIGHT", -8, 0)
    r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        self.plate:SetColorTexture(1, 1, 1, 0.06)
        if self.tip then ns.UI:SetTextTooltip(self, self.tip, "ANCHOR_LEFT") end
    end)
    r:SetScript("OnLeave", function(self)
        self.plate:SetColorTexture(1, 1, 1, 0.025)
        ns.UI:HideTooltip()
    end)
    r:Hide()
    return r
end

local function SeasonRows()
    local rows = {}
    for key, r in pairs(ns.Bingo:GetSeason()) do
        rows[#rows + 1] = { key = key, b = r.bingos or 0, f = r.firsts or 0, x = r.blackouts or 0 }
    end
    table.sort(rows, function(a, b)
        if a.b ~= b.b then return a.b > b.b end
        if a.f ~= b.f then return a.f > b.f end
        return a.key < b.key
    end)
    return rows
end

local function RefreshSeason()
    local rows = SeasonRows()
    local top = rows[1] and max(1, rows[1].b) or 1
    for i, row in ipairs(seasonRows) do
        local r = rows[i]
        if r then
            local medal = i == 1 and "|cffffd100" or i == 2 and "|cffc0c0c8" or i == 3 and "|cffcd7f32" or "|cff8a8a8a"
            row.left:SetText(medal .. i .. "|r   " .. KeyText(r.key))
            row.right:SetText("|cffffffff" .. r.b .. "|r |cff8a8a8a" .. (r.b == 1 and "bingo" or "bingos") .. "|r")
            row.bar:SetWidth(max(1, (row:GetWidth() > 0 and row:GetWidth() or SIDE_W) * r.b / top))
            row.bar:SetColorTexture(1, 0.82, 0, i == 1 and 0.7 or 0.35)
            local tip = { ShortName(r.key), string.format("%d bingo%s this season", r.b, r.b == 1 and "" or "s") }
            if r.f > 0 then tip[#tip + 1] = { r.f .. " first of the game", 0.2, 1, 0.6 } end
            if r.x > 0 then tip[#tip + 1] = { r.x .. " blackout" .. (r.x == 1 and "" or "s"), 1, 0.5, 0 } end
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    seasonEmpty:SetShown(#rows == 0)
end

local function RefreshRace(g)
    local race = g and ns.Bingo:GetRace() or {}
    local me = Util.PlayerKey()
    local shown = {}
    for i = 1, min(#race, RACE_ROWS) do shown[i] = race[i] end
    if #race > RACE_ROWS then
        local mine
        for i = RACE_ROWS + 1, #race do if race[i].key == me then mine = race[i] end end
        if mine then shown[RACE_ROWS] = mine end
    end
    local winnerAt = {}
    for i, k in ipairs(g and g.winners or {}) do winnerAt[k] = i end
    for i, row in ipairs(raceRows) do
        local r = shown[i]
        if r then
            local pos = i
            for j, x in ipairs(race) do if x == r then pos = j end end
            row.left:SetText("|cff8a8a8a" .. pos .. "|r   " .. KeyText(r.key))
            local w = row:GetWidth() > 0 and row:GetWidth() or SIDE_W
            if r.lines > 0 then
                row.right:SetText("|cffffd100BINGO" .. (r.lines > 1 and (" x" .. r.lines) or "") .. "|r")
                row.bar:SetColorTexture(1, 0.82, 0, 0.8)
            else
                row.right:SetText(r.marked .. "|cff8a8a8a/25|r")
                local cr, cg, cb = ClassRGB(r.key)
                row.bar:SetColorTexture(cr, cg, cb, 0.65)
            end
            row.bar:SetWidth(max(1, w * r.marked / 25))
            row.mark:SetShown(r.key == me)
            row.mark:SetColorTexture(1, 0.82, 0, 1)
            local tip = { ShortName(r.key), string.format("%d/25 marked, %d line%s", r.marked, r.lines,
                r.lines == 1 and "" or "s") }
            if winnerAt[r.key] then
                tip[#tip + 1] = { winnerAt[r.key] == 1 and "First BINGO of the game!" or
                    ("BINGO #" .. winnerAt[r.key]), 1, 0.82, 0 }
            end
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    raceEmpty:SetShown(#shown == 0)
end

local function RefreshFeed(g)
    local feed = g and ns.Bingo:GetFeed() or {}
    for i, row in ipairs(feedRows) do
        local e = feed[i]
        if e then
            local sq = ns.BingoSquares:Get(e.id)
            local icon = ns.BingoSquares:Icon(sq)
            row.icon:SetTexture(icon)
            local col = RARITY[sq and sq.rarity] or RARITY.c
            row.left:SetText(e.who and WhoText(e.who) or "|cff8a8a8asomeone|r")
            row.right:SetText("|cff8a8a8a" .. date("%H:%M", e.t) .. "|r")
            row.mark:SetShown(sq and sq.rarity ~= "c")
            row.mark:SetColorTexture(col[1], col[2], col[3], 1)
            row.bar:SetWidth(1)
            row.bar:SetColorTexture(0, 0, 0, 0)
            local tip = { { sq and sq.text or e.id, col[1], col[2], col[3], wrap = true } }
            if e.who then tip[#tip + 1] = "Set off by " .. e.who end
            tip[#tip + 1] = "Marked at " .. date("%H:%M", e.t)
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    feedEmpty:SetShown(#feed == 0)
end

---------------------------------------------------------------------------
-- Layout: everything from the panel's size
---------------------------------------------------------------------------

local function Layout()
    if not panel then return end
    local W, H = panel:GetWidth() or 0, panel:GetHeight() or 0
    if W < 300 or H < 300 then W, H = FALLBACK_W, FALLBACK_H end
    hero:SetHeight(HERO_H)
    local cardW = W - 2 * PAD - GAP - SIDE_W
    local cardH = H - HERO_H - 2 * PAD
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(HERO_H + PAD))
    card:SetSize(cardW, cardH)
    local gw = cardW - 2 * CARD_PAD
    local gh = cardH - 2 * CARD_PAD - LETTER_H
    local cw = floor((gw - 4 * CELL_GAP) / 5)
    local ch = floor((gh - 4 * CELL_GAP) / 5)
    gw, gh = 5 * cw + 4 * CELL_GAP, 5 * ch + 4 * CELL_GAP
    grid:ClearAllPoints()
    grid:SetPoint("TOP", card, "TOP", 0, -(CARD_PAD + LETTER_H))
    grid:SetSize(gw, gh)
    for i, c in ipairs(cells) do
        local row, col = floor((i - 1) / 5), (i - 1) % 5
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", grid, "TOPLEFT", col * (cw + CELL_GAP), -row * (ch + CELL_GAP))
        c:SetSize(cw, ch)
        c.ink:SetSize(min(cw, ch) * 1.3, min(cw, ch) * 1.3)
    end
    for col, fs in ipairs(card.letters) do
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOM", grid, "TOPLEFT", (col - 1) * (cw + CELL_GAP) + cw / 2, 4)
    end
    side:ClearAllPoints()
    side:SetPoint("TOPLEFT", card, "TOPRIGHT", GAP, 0)
    side:SetSize(SIDE_W, H - HERO_H - 2 * PAD)
    -- your dauber and the announce switch close the right column
    announceBox:ClearAllPoints()
    announceBox:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", -4, 0)
    dauberBar:ClearAllPoints()
    dauberBar:SetPoint("BOTTOMLEFT", announceBox, "TOPLEFT", 4, 2)
    if hero.art:IsShown() and ns.GamesUI and ns.GamesUI.CropArt then
        ns.GamesUI.CropArt(hero.art, W, HERO_H, hero.focus)
    end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function CellTip(sq, hit, g, away)
    local col = RARITY[sq.rarity] or RARITY.c
    local tip = { { sq.text, col[1], col[2], col[3], wrap = true }, { col.name .. " square", 1, 1, 1 } }
    if sq.hint then tip[#tip + 1] = { "\"" .. sq.hint .. "\"", 1, 0.82, 0, wrap = true } end
    if hit then
        local who = ns.Bingo:GetWho(sq.id)
        tip[#tip + 1] = { "Marked at " .. date("%H:%M", g.hits[sq.id]) .. (who and (" by " .. who) or ""), 0.2, 1, 0.6 }
    else
        tip[#tip + 1] = { "Not yet...", 0.55, 0.55, 0.55 }
        if away then tip[#tip + 1] = { "One away from a line!", 1, 0.82, 0 } end
    end
    return tip
end

local DARK_TOP, DARK_BOTTOM = { 0.12, 0.12, 0.138 }, { 0.085, 0.085, 0.1 }
local HIT_TOP, HIT_BOTTOM = { 0.15, 0.13, 0.08 }, { 0.09, 0.08, 0.05 }
local LINE_TOP, LINE_BOTTOM = { 0.25, 0.19, 0.05 }, { 0.14, 0.105, 0.03 }

local function PaintStat(s, value, label, r, g, b)
    s.value:SetText(value)
    s.value:SetTextColor(r or 1, g or 1, b or 1)
    s.label:SetText(label)
    s:Show()
end

local function RefreshHero(g, active, marked, lines, awayCount)
    local Bingo = ns.Bingo
    -- the art: the raid you're in while it runs, else Karazhan
    local key = active and ns.GamesUI and ns.GamesUI.InstanceHere and ns.GamesUI:InstanceHere()
    if ns.GamesUI and ns.GamesUI.RaidArt then
        local file, focus = ns.GamesUI:RaidArt(key or "kara")
        if hero.file ~= file then
            hero.file, hero.focus = file, focus
            hero.art:SetTexture(file)
            hero.art:Show()
            Layout()
        end
    end
    local inst = active and GetInstanceInfo and select(2, GetInstanceInfo()) == "raid" and GetInstanceInfo()
    if active then
        hero.kicker:SetText(inst and ("LIVE   \194\183   " .. inst:upper()) or "LIVE")
        hero.kicker:SetTextColor(1, 1, 1)
    elseif g then
        hero.kicker:SetText("FINISHED")
        hero.kicker:SetTextColor(0.62, 0.62, 0.62)
    else
        hero.kicker:SetText("RAID NIGHT")
        hero.kicker:SetTextColor(0.62, 0.62, 0.62)
    end
    hero.dot:SetShown(active and true or false)
    hero.dotGlow:SetShown(active and true or false)
    hero.kicker:ClearAllPoints()
    hero.kicker:SetPoint("TOPLEFT", active and 31 or 16, -14)
    hero.edge:SetShown(active and true or false)

    if not g then
        statusText:SetText("No game yet. The raid leader starts one with |cffffd100/dz bingo start|r.")
    else
        local parts = { "host " .. ShortName(g.host or "?") }
        if g.started then parts[#parts + 1] = "started " .. date("%H:%M", g.started) end
        if active and awayCount > 0 then
            parts[#parts + 1] = string.format("|cffffd100%d one away!|r", awayCount)
        end
        statusText:SetText(table.concat(parts, "   \194\183   "))
    end

    -- the numbers (right), then the buttons that apply
    local showStart = Bingo:CanStart() and not active
    local showStop = active and Bingo:IsHost()
    startBtn:SetShown(showStart)
    startBtn:SetEnabled(showStart)
    stopBtn:SetShown(showStop)
    stopBtn:SetEnabled(showStop)
    local right = hero
    local rx = -16
    for _, b in ipairs({ startBtn, stopBtn }) do
        if b:IsShown() then
            b:ClearAllPoints()
            b:SetPoint("RIGHT", right, right == hero and "RIGHT" or "LEFT", rx, 0)
            right, rx = b, -8
        end
    end
    if g then
        stats[1]:Hide()
        PaintStat(stats[2], tostring(lines), lines == 1 and "LINE" or "LINES", 1, lines > 0 and 0.82 or 1, lines > 0 and 0 or 1)
        PaintStat(stats[3], marked .. "|cff8a8a8a/25|r", "MARKED")
        local anchor, ax = right, right == hero and -18 or -22
        for i = 3, 2, -1 do
            local s = stats[i]
            s:ClearAllPoints()
            s:SetPoint("RIGHT", anchor, anchor == hero and "RIGHT" or "LEFT", ax, 0)
            anchor, ax = s, -18
        end
    else
        for _, s in ipairs(stats) do s:Hide() end
    end
end

function BingoUI:Refresh()
    if mini then mini:Update() end
    if not panel or not panel:IsVisible() then return end
    local Bingo = ns.Bingo
    local g = Bingo:GetGame()
    local active = Bingo:IsActive()
    local cardIds = g and Bingo:GetMyCard()
    local hits = g and g.hits or {}
    local lines, marked, onLine, full, away = 0, 0, {}, {}, {}
    if cardIds then lines, marked, onLine, full, away = Analyze(cardIds, hits) end

    -- what's new since this card was last on screen
    local view = View()
    if g and view.g ~= g.id then
        view.g, view.hits, view.lines, view.black = g.id, {}, 0, false
    end
    if type(view.hits) ~= "table" then view.hits = {} end
    local newCount, awayCount = 0, 0

    local inkC = INK[Dauber()] or INK[1]
    for i = 1, 25 do
        local c = cells[i]
        local id = cardIds and cardIds[i]
        c.rare:Hide()
        c.wash:Hide()
        c.legendary = nil
        c.sheen1:Hide()
        c.sheen2:Hide()
        c.ring:Hide()
        if not id then
            c.icon:SetTexture(nil)
            c.iconEdge:Hide()
            c.icon2:Hide()
            c.badge:SetText("")
            c.text:SetText("")
            c.tip = nil
            HideStamp(c)
            SetPulse(c, false)
            Fill(c, { 0.09, 0.09, 0.105, 0.7 }, { 0.06, 0.06, 0.07, 0.7 })
            ns.UI:SetEdgeColor(c, 1, 1, 1, 0.04)
        elseif id == ns.BingoSquares.FREE then
            c.icon:SetTexture(SEAL)
            c.icon:SetTexCoord(0, 1, 0, 1)
            c.icon:SetAlpha(1)
            if c.icon.SetDesaturated then c.icon:SetDesaturated(false) end
            c.iconEdge:Hide()
            c.icon2:Hide()
            c.badge:SetText("")
            c.text:SetText("|cffffd100FREE|r")
            c.tip = { { "Casual Disaster", 1, 0.5, 0 }, "Free square: everyone starts with the centre." }
            HideStamp(c)
            c.who:SetText("FREE")
            SetPulse(c, false)
            if onLine[i] then
                Fill(c, LINE_TOP, LINE_BOTTOM)
                ns.UI:SetEdgeColor(c, 1, 0.82, 0, 0.9)
                c.rare:Show()
            else
                Fill(c, { 0.16, 0.13, 0.06 }, { 0.09, 0.075, 0.035 })
                ns.UI:SetEdgeColor(c, 1, 0.82, 0, 0.3)
            end
        else
            local sq = ns.BingoSquares:Get(id)
            local col = RARITY[sq.rarity] or RARITY.c
            local hit = hits[id] ~= nil
            local icon, icon2 = ns.BingoSquares:Icon(sq)
            c.icon:SetTexture(icon)
            c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            c.icon:SetAlpha(1)
            if c.icon.SetDesaturated then c.icon:SetDesaturated(false) end
            c.iconEdge:Show()
            if icon2 then
                c.icon2:SetTexture(icon2)
                c.icon2:Show()
            else
                c.icon2:Hide()
            end
            c.badge:SetText(sq.badge or "")
            c.text:SetText(sq.text)
            c.text:SetTextColor(hit and 1 or 0.78, hit and 1 or 0.78, hit and 1 or 0.8)
            c.tip = CellTip(sq, hit, g, away[i])
            local rare = sq.rarity == "r" or sq.rarity == "l"
            if rare then
                ns.UI:SetEdgeColor(c.ring, col[1], col[2], col[3], 1)
                c.ring:Show()
                if not hit then
                    c.wash:SetHeight(max(1, (c:GetHeight() > 0 and c:GetHeight() or 70) * 0.62))
                    Gradient(c.wash, "VERTICAL", col[1], col[2], col[3], 0, col[1], col[2], col[3],
                        sq.rarity == "l" and 0.2 or 0.14)
                    c.wash:Show()
                    c.legendary = sq.rarity == "l" or nil
                end
            end
            if hit then
                local isNew = not view.hits[id]
                if isNew then
                    view.hits[id] = true
                    newCount = newCount + 1
                end
                local who = Bingo:GetWho(id)
                ShowStamp(c, who and WhoText(who) or "marked", isNew, (newCount - 1) * 0.12)
            else
                HideStamp(c)
            end
            SetPulse(c, away[i] and active)
            if away[i] then awayCount = awayCount + 1 end
            if onLine[i] then
                Fill(c, LINE_TOP, LINE_BOTTOM)
                ns.UI:SetEdgeColor(c, 1, 0.82, 0, 0.9)
                c.rare:Show()
            elseif hit then
                Fill(c, { 0.13 + inkC[1] * 0.04, 0.13 + inkC[2] * 0.04, 0.14 + inkC[3] * 0.04 }, DARK_BOTTOM)
                ns.UI:SetEdgeColor(c, inkC[1], inkC[2], inkC[3], 0.35)
            elseif away[i] and active then
                Fill(c, DARK_TOP, DARK_BOTTOM)
                ns.UI:SetEdgeColor(c, 1, 0.82, 0, 0.7)
            elseif rare then
                Fill(c, DARK_TOP, DARK_BOTTOM)
                ns.UI:SetEdgeColor(c, col[1], col[2], col[3], sq.rarity == "l" and 0.3 or 0.2)
            else
                Fill(c, DARK_TOP, DARK_BOTTOM)
                ns.UI:SetEdgeColor(c, 1, 1, 1, 0.06)
            end
        end
    end

    -- gold lines through completed lines
    local isFull = {}
    for _, li in ipairs(full) do isFull[li] = true end
    for li, tex in ipairs(lineTex) do
        tex:SetShown(isFull[li] == true)
        lineGlow[li]:SetShown(isFull[li] == true)
    end

    -- the slam, once per new line / blackout (waits until the card is on screen)
    if g and cardIds then
        local delay = newCount > 0 and min(1.5, newCount * 0.12 + 0.2) or 0
        local function Celebrate(text, color, sub)
            if delay > 0 then
                C_Timer.After(delay, function() slam:Slam(text, color, sub) end)
            else
                slam:Slam(text, color, sub)
            end
        end
        if marked >= 25 and not view.black then
            view.black = true
            view.lines = lines
            Celebrate("BLACKOUT!", { 1, 0.5, 0 }, "The whole card!")
        elseif lines > (tonumber(view.lines) or 0) then
            local gained = lines - (tonumber(view.lines) or 0)
            view.lines = lines
            Celebrate(gained > 1 and ("BINGO x" .. gained .. "!") or "BINGO!", GOLD,
                lines > 1 and (lines .. " lines on your card") or nil)
        end
    end

    RefreshHero(g, active, marked, lines, awayCount)
    announceBox:SetChecked(Bingo:GetAnnounce())
    local dauber = Dauber()
    for i, b in ipairs(dauberBtns) do
        b.sel:SetShown(i == dauber)
        b.selEdge:SetShown(i == dauber)
        b.tex:SetAlpha(i == dauber and 1 or 0.4)
    end
    RefreshRace(g)
    RefreshFeed(g)
    RefreshSeason()
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function CreateHero(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT")
    f:SetPoint("TOPRIGHT")
    f:SetHeight(HERO_H)
    f.base = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.base:SetAllPoints()
    f.base:SetColorTexture(0.078, 0.078, 0.09, 1)
    f.art = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    f.art:SetAllPoints()
    f.art:SetVertexColor(0.85, 0.85, 0.88)
    f.art:Hide()
    f.fade = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    f.fade:SetPoint("TOPLEFT")
    f.fade:SetPoint("BOTTOMLEFT")
    f.fade:SetPoint("RIGHT", f, "CENTER", 60, 0)
    Gradient(f.fade, "HORIZONTAL", 0.078, 0.078, 0.09, 0.97, 0.078, 0.078, 0.09, 0.35)
    f.fadeR = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    f.fadeR:SetPoint("TOPLEFT", f.fade, "TOPRIGHT")
    f.fadeR:SetPoint("BOTTOMRIGHT")
    Gradient(f.fadeR, "HORIZONTAL", 0.078, 0.078, 0.09, 0.35, 0.078, 0.078, 0.09, 0.9)
    f.line = f:CreateTexture(nil, "BORDER")
    f.line:SetPoint("BOTTOMLEFT")
    f.line:SetPoint("BOTTOMRIGHT")
    f.line:SetHeight(1)
    f.line:SetColorTexture(1, 1, 1, 0.07)
    f.edge = f:CreateTexture(nil, "BORDER", nil, 1)
    f.edge:SetPoint("TOPLEFT")
    f.edge:SetPoint("TOPRIGHT")
    f.edge:SetHeight(2)
    Gradient(f.edge, "HORIZONTAL", 1, 0.29, 0.24, 1, 1, 0.82, 0, 1)
    f.edge:Hide()

    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetTexture(CIRCLE)
    f.dot:SetSize(7, 7)
    f.dot:SetVertexColor(1, 0.29, 0.24)
    f.dot:SetPoint("TOPLEFT", 16, -15)
    f.dotGlow = f:CreateTexture(nil, "ARTWORK")
    f.dotGlow:SetTexture(RADIAL)
    f.dotGlow:SetBlendMode("ADD")
    f.dotGlow:SetVertexColor(1, 0.29, 0.24, 0.6)
    f.dotGlow:SetSize(22, 22)
    f.dotGlow:SetPoint("CENTER", f.dot, "CENTER")
    f.kicker = Label(f, 9.5)
    f.title = Label(f, 22, "GameFontHighlightLarge")
    f.title:SetText("Council Bingo")
    f.title:SetPoint("TOPLEFT", 16, -30)
    f.title:SetShadowOffset(1, -1)
    return f
end

local function CreateStat(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(64, 40)
    s.value = Label(s, 20, "GameFontHighlightLarge")
    s.value:SetJustifyH("RIGHT")
    s.value:SetPoint("TOPRIGHT", 0, -2)
    s.label = Label(s, 9)
    s.label:SetJustifyH("RIGHT")
    s.label:SetTextColor(0.55, 0.55, 0.55)
    s.label:SetPoint("TOPRIGHT", s.value, "BOTTOMRIGHT", 0, -3)
    s:Hide()
    return s
end

local function CreateCard(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    Gradient(f.bg, "VERTICAL", 0.05, 0.05, 0.06, 0.92, 0.085, 0.085, 0.1, 0.92)
    ns.UI:AddEdges(f, "BORDER")
    ns.UI:SetEdgeColor(f, 1, 1, 1, 0.07)

    grid = CreateFrame("Frame", nil, f)
    f.letters = {}
    for c, l in ipairs(LETTERS) do
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, 15, "")
        fs:SetText(l[1])
        fs:SetTextColor(0.62, 0.62, 0.65)
        fs:SetShadowOffset(1, -1)
        f.letters[c] = fs
    end

    cells = {}
    for i = 1, 25 do cells[i] = CreateCell(grid, i) end

    -- lines and the slam sit above the cells
    overlay = CreateFrame("Frame", nil, grid)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(grid:GetFrameLevel() + 10)
    for _, c in ipairs(cells) do c.top:SetFrameLevel(grid:GetFrameLevel() + 12) end
    lineTex, lineGlow = {}, {}
    for li, line in ipairs(ns.BingoCard.LINES) do
        local a, b = cells[line[1]], cells[line[#line]]
        -- a completed line: a gold thread behind the squares, seen in the gaps between them
        local glow = grid:CreateLine(nil, "BACKGROUND")
        glow:SetThickness(10)
        glow:SetColorTexture(1, 0.82, 0, 0.25)
        glow:SetStartPoint("CENTER", a)
        glow:SetEndPoint("CENTER", b)
        glow:Hide()
        lineGlow[li] = glow
        local t = grid:CreateLine(nil, "ARTWORK")
        t:SetThickness(3)
        t:SetColorTexture(1, 0.86, 0.2, 1)
        t:SetStartPoint("CENTER", a)
        t:SetEndPoint("CENTER", b)
        t:Hide()
        lineTex[li] = t
    end
    slam = CreateSlam(overlay)
    return f
end

local function CreateDauberBar(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(SIDE_W, FOOT_H)
    local label = Kicker(f, "DAUBER")
    label:SetPoint("LEFT", 2, 0)
    dauberBtns = {}
    for i = 1, 8 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(20, 20)
        b:SetPoint("LEFT", 54 + (i - 1) * 22, 0)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetPoint("TOPLEFT", -2, 2)
        b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
        b.sel:SetColorTexture(1, 0.82, 0, 0.22)
        b.selEdge = CreateFrame("Frame", nil, b)
        b.selEdge:SetPoint("TOPLEFT", -2, 2)
        b.selEdge:SetPoint("BOTTOMRIGHT", 2, -2)
        ns.UI:AddEdges(b.selEdge, "BORDER")
        ns.UI:SetEdgeColor(b.selEdge, 1, 0.82, 0, 0.8)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetPoint("TOPLEFT", 2, -2)
        b.tex:SetPoint("BOTTOMRIGHT", -2, 2)
        b.tex:SetTexture(RAID_ICON .. i)
        b:SetScript("OnClick", function()
            ns.Games:GetData("bingo").dauber = i
            BingoUI:Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            self.tex:SetAlpha(1)
            ns.UI:SetTextTooltip(self, { "Dauber: " .. MARKER_NAMES[i], "Stamps your marked squares with this marker." })
        end)
        b:SetScript("OnLeave", function(self)
            ns.UI:HideTooltip()
            self.tex:SetAlpha(i == Dauber() and 1 or 0.4)
        end)
        dauberBtns[i] = b
    end
    return f
end

-- A section of the right column: its kicker and n rows of height h under it; returns the rows and the empty text.
local function Section(y, title, n, h, withIcon, emptyText)
    local head = Kicker(side, title)
    head:SetPoint("TOPLEFT", side, "TOPLEFT", 2, y)
    local rule = side:CreateTexture(nil, "BORDER")
    rule:SetHeight(1)
    rule:SetPoint("LEFT", head, "RIGHT", 8, 0)
    rule:SetPoint("RIGHT", side, "RIGHT", 0, 0)
    rule:SetColorTexture(1, 1, 1, 0.06)
    local rows = {}
    for i = 1, n do
        local r = CreateRow(side, h, withIcon)
        r:SetPoint("TOPLEFT", side, "TOPLEFT", 0, y - 16 - (i - 1) * (h + 2))
        r:SetPoint("RIGHT", side, "RIGHT", 0, 0)
        rows[i] = r
    end
    local empty = Label(side, 11, "GameFontHighlightSmall")
    empty:SetText("|cff6f6f6f" .. emptyText .. "|r")
    empty:SetPoint("TOPLEFT", side, "TOPLEFT", 2, y - 20)
    return rows, empty, y - 16 - n * (h + 2)
end

function BingoUI:CreatePanel(parent)
    panel = CreateFrame("Frame", nil, parent)

    hero = CreateHero(panel)
    statusText = Label(hero, 11, "GameFontHighlightSmall")
    statusText:SetTextColor(0.72, 0.72, 0.72)
    statusText:SetPoint("TOPLEFT", hero.title, "BOTTOMLEFT", 0, -6)
    startBtn = ns.UI:CreateSleekButton(hero, "Start game", 104, 24, function() ns.Bingo:Start() end, "primary")
    stopBtn = ns.UI:CreateSleekButton(hero, "End game", 90, 24, function() ns.Bingo:Stop() end)
    stats = { CreateStat(hero), CreateStat(hero), CreateStat(hero) }
    statusText:SetPoint("RIGHT", hero, "CENTER", 80, 0)

    card = CreateCard(panel)
    dauberBar = CreateDauberBar(panel)
    announceBox = ns.UI:CreateCheckbox(panel, "Announce bingos in raid chat",
        function() return ns.Bingo:GetAnnounce() end,
        function(v) ns.Bingo:SetAnnounce(v) end)

    -- right column: race, feed, season
    side = CreateFrame("Frame", nil, panel)
    local y
    raceRows, raceEmpty, y = Section(0, "RACE", RACE_ROWS, 22, false, "No game running.")
    feedRows, feedEmpty, y = Section(y - 14, "LATEST", FEED_ROWS, 20, true, "Nothing marked yet.")
    seasonRows, seasonEmpty = Section(y - 14, "SEASON", SEASON_ROWS, 20, false, "No bingos yet.")

    Layout()
    panel:SetScript("OnSizeChanged", function() Layout() BingoUI:Refresh() end)
    panel:SetScript("OnShow", function() BingoUI:Refresh() end)
    panel:SetScript("OnUpdate", function()
        local now = GetTime()
        if hero.dot:IsShown() then hero.dotGlow:SetAlpha(0.35 + 0.35 * math.sin(now * 4)) end
        -- legendary squares: a light sweeps across each every SHEEN_EVERY seconds (staggered by square)
        for i, c in ipairs(cells) do
            if c.legendary then
                local t = ((now + i * 0.83) % SHEEN_EVERY) / SHEEN_TIME
                if t < 1 then PlaceSheen(c, t) else c.sheen1:Hide() c.sheen2:Hide() end
            end
        end
    end)
    panel.OnGameShown = function() Layout() BingoUI:Refresh() end
    return panel
end

---------------------------------------------------------------------------
-- Mini counter
---------------------------------------------------------------------------

local function CreateMini()
    local f = CreateFrame("Button", "DisasterZoneBingoMini", UIParent)
    f:SetSize(170, 26)
    f:SetPoint("TOP", 0, -120)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    Gradient(f.bg, "VERTICAL", 0.05, 0.05, 0.06, 0.9, 0.12, 0.12, 0.14, 0.9)
    ns.UI:AddEdges(f, "BORDER", true)
    ns.UI:SetEdgeColor(f, 1, 1, 1, 0.12)
    f.accent = f:CreateTexture(nil, "BORDER", nil, 1)
    f.accent:SetPoint("TOPLEFT", 1, -1)
    f.accent:SetPoint("BOTTOMLEFT", 1, 1)
    f.accent:SetWidth(2)
    f.accent:SetColorTexture(1, 0.82, 0, 1)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("LEFT", 9, 0)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        if point then ns.Games:GetData("bingo").miniPos = { point, relPoint, x, y } end
    end)
    f:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            self.dismissed = true
            self:Hide()
        else
            ns.Games:Open("bingo")
        end
    end)
    f:SetScript("OnEnter", function(self)
        ns.UI:SetEdgeColor(self, 1, 0.82, 0, 0.5)
        ns.UI:SetTextTooltip(self, { "Council Bingo", "Left-click: open your card", "Right-click: hide until the next game" })
    end)
    f:SetScript("OnLeave", function(self)
        ns.UI:SetEdgeColor(self, 1, 1, 1, 0.12)
        ns.UI:HideTooltip()
    end)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", f.icon, "RIGHT", 7, 0)
    f.text:SetPoint("RIGHT", -8, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(false)
    local pos = ns.Games:GetData("bingo").miniPos
    if type(pos) == "table" and type(pos[1]) == "string" then
        f:ClearAllPoints()
        f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    end
    -- Follows the main window (hidden while it is open) without forcing it to be created.
    local elapsed = 0
    f.driver = CreateFrame("Frame")
    f.driver:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.5 then return end
        elapsed = 0
        if ns.Bingo:IsActive() then f:Update() elseif f:IsShown() then f:Hide() end
    end)

    function f:Update()
        local Bingo = ns.Bingo
        local main = ns.MainFrame and ns.MainFrame:IsShown()
        if not Bingo:IsActive() or main or self.dismissed then
            self:Hide()
            return
        end
        local g, cardIds = Bingo:GetGame(), Bingo:GetMyCard()
        local lines, marked, awayCount = 0, 0, 0
        if g and cardIds then
            local _, away
            lines, marked, _, _, away = Analyze(cardIds, g.hits)
            for _ in pairs(away) do awayCount = awayCount + 1 end
        end
        local extra = ""
        if lines > 0 then extra = "   |cffffd100BINGO|r"
        elseif awayCount > 0 then extra = "   |cffffd1001 away!|r" end
        self.icon:SetTexture(RAID_ICON .. Dauber())
        self.accent:SetColorTexture(lines > 0 and 1 or 1, lines > 0 and 0.82 or 0.29, lines > 0 and 0 or 0.24, 1)
        self.text:SetText(string.format("Bingo  |cffffffff%d|r|cff8a8a8a/25|r%s", marked, extra))
        self:Show()
    end
    f:Hide()
    return f
end

-- For the test harness.
function BingoUI:GetWidgets()
    return { panel = panel, cells = cells, lines = lineTex, slam = slam, race = raceRows, feed = feedRows,
        season = seasonRows, dauber = dauberBtns, status = statusText, card = card, hero = hero, side = side,
        start = startBtn, stop = stopBtn }
end

function BingoUI:OnInit()
    ns:On("BINGO_UPDATED", function() BingoUI:Refresh() end)
    ns:On("GAMES_UPDATED", function() BingoUI:Refresh() end)
    ns:On("GROUP_UPDATED", function() BingoUI:Refresh() end)
end

function BingoUI:OnLogin()
    mini = CreateMini()
    local lastGame
    ns:On("BINGO_UPDATED", function()
        local g = ns.Bingo:GetGame()
        if g and g.id ~= lastGame then
            lastGame = g.id
            mini.dismissed = false
        end
    end)
    C_Timer.After(1, function() BingoUI:Refresh() end)
end

if CDLootBoot and CDLootBoot.Run("Games/Bingo/UI.lua", ...) then return end -- CDLoot Games/Bingo/UI.lua
-- ns.BingoUI: the Council Bingo panel and a small movable counter ("Bingo 12/25") shown while a game runs and
-- the main window is closed. The panel: a B-I-N-G-O card with square icons, your raid-marker "dauber" stamped on
-- every marked square with who set it off, a pulse on squares one away from a line, a gold line through every
-- completed line with a BINGO! slam, and a right column with the live race, the feed of marked squares and
-- the season leaderboard.
local addonName, ns = ...

local BingoUI = ns:NewModule("BingoUI")
local Util = ns.Util

local CELL_W, CELL_H, GAP = 78, 72, 3
local GRID_W, GRID_H = 5 * CELL_W + 4 * GAP, 5 * CELL_H + 4 * GAP
local CARD_PAD, CARD_HEAD = 8, 24
local CARD_W, CARD_H = GRID_W + 2 * CARD_PAD, GRID_H + 2 * CARD_PAD + CARD_HEAD
local SIDE_W = 150
local RACE_ROWS, FEED_ROWS, SEASON_ROWS = 8, 8, 5
local FONT = "Fonts\\FRIZQT__.TTF"
local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local STAMP_ALPHA = 0.9

local RARITY = {
    c = { 0.85, 0.85, 0.85, name = "Common" },
    r = { 0.35, 0.65, 1.0, name = "Rare" },
    l = { 1.0, 0.5, 0.0, name = "Legendary" },
}
local GOLD = { 1, 0.82, 0 }
local LETTERS = {
    { "B", 0.35, 0.65, 1 }, { "I", 1, 0.35, 0.35 }, { "N", 1, 1, 1 }, { "G", 0.35, 1, 0.35 }, { "O", 1, 0.82, 0 },
}
local MARKER_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }

local panel, card, cells, overlay, lineTex, slam, statusText, startBtn, stopBtn, announceBox
local dauberBtns, raceRows, feedRows, seasonText, raceEmpty, feedEmpty
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

local function KeyText(key)
    local info = Util.group and Util.group[key]
    local name = ShortName(key)
    if info and info.classFile then return "|c" .. Util.ClassColorHex(info.classFile) .. name .. "|r" end
    return name
end

local function Glow(frame, on)
    local lib = LibStub and LibStub("LibCustomGlow-1.0", true)
    if not lib or not lib.PixelGlow_Start then return end
    if on and not frame.glowing then
        pcall(lib.PixelGlow_Start, frame, { 1, 0.5, 0, 0.9 }, 8, 0.12, 10, 1, 0, 0, false, "cdlBingo")
        frame.glowing = true
    elseif not on and frame.glowing then
        pcall(lib.PixelGlow_Stop, frame, "cdlBingo")
        frame.glowing = nil
    end
end

local function SetScaleAnim(a, from, to)
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from)
        a:SetScaleTo(to, to)
    else
        a:SetScale(to / from, to / from)
    end
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

local function CreateCell(parent, i)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetSize(CELL_W, CELL_H)
    local row, col = math.floor((i - 1) / 5), (i - 1) % 5
    b:SetPoint("TOPLEFT", col * (CELL_W + GAP), -row * (CELL_H + GAP))
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(26, 26)
    b.icon:SetPoint("TOP", 0, -5)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.icon2 = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.icon2:SetSize(13, 13)
    b.icon2:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", -4, -2)
    b.badge = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    b.badge:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 3, -1)

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("TOPLEFT", 3, -33)
    b.text:SetPoint("BOTTOMRIGHT", -3, 3)
    b.text:SetJustifyH("CENTER")
    b.text:SetJustifyV("MIDDLE")

    -- "one away" pulse
    b.pulse = b:CreateTexture(nil, "BACKGROUND", nil, 2)
    b.pulse:SetPoint("TOPLEFT", 1, -1)
    b.pulse:SetPoint("BOTTOMRIGHT", -1, 1)
    b.pulse:SetColorTexture(1, 0.82, 0, 1)
    b.pulse:SetBlendMode("ADD")
    b.pulse:SetAlpha(0)
    b.pulse:Hide()
    b.pulseAnim = b.pulse:CreateAnimationGroup()
    b.pulseAnim:SetLooping("BOUNCE")
    local p = b.pulseAnim:CreateAnimation("Alpha")
    p:SetFromAlpha(0.04)
    p:SetToAlpha(0.32)
    p:SetDuration(0.7)
    p:SetSmoothing("IN_OUT")

    -- the dauber stamp, the name ribbon and a flash when the stamp lands
    b.stamp = b:CreateTexture(nil, "OVERLAY", nil, 5)
    b.stamp:SetSize(34, 34)
    b.stamp:SetPoint("CENTER", b.icon, "CENTER", 3, -3)
    b.stampAnim = b.stamp:CreateAnimationGroup()
    local s = b.stampAnim:CreateAnimation("Scale")
    SetScaleAnim(s, 2.6, 1)
    s:SetDuration(0.22)
    s:SetSmoothing("IN")
    if s.SetOrigin then s:SetOrigin("CENTER", 0, 0) end
    local a = b.stampAnim:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(STAMP_ALPHA)
    a:SetDuration(0.12)
    b.stampAnim:SetScript("OnFinished", function() b.stamp:SetAlpha(STAMP_ALPHA) end)
    b.stampParts = { s, a }

    b.flash = b:CreateTexture(nil, "OVERLAY", nil, 6)
    b.flash:SetAllPoints()
    b.flash:SetColorTexture(1, 1, 1, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAlpha(0)
    b.flashAnim = b.flash:CreateAnimationGroup()
    local f = b.flashAnim:CreateAnimation("Alpha")
    f:SetFromAlpha(0.55)
    f:SetToAlpha(0)
    f:SetDuration(0.45)
    b.flashAnim:SetScript("OnFinished", function() b.flash:SetAlpha(0) end)
    b.flashPart = f

    b.ribbon = b:CreateTexture(nil, "OVERLAY", nil, 3)
    b.ribbon:SetPoint("BOTTOMLEFT", 1, 1)
    b.ribbon:SetPoint("BOTTOMRIGHT", -1, 1)
    b.ribbon:SetHeight(13)
    b.ribbon:SetColorTexture(0, 0, 0, 0.8)
    b.who = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.who:SetPoint("CENTER", b.ribbon, "CENTER", 0, 0)
    b.who:SetPoint("LEFT", b.ribbon, "LEFT", 2, 0)
    b.who:SetPoint("RIGHT", b.ribbon, "RIGHT", -2, 0)
    b.who:SetWordWrap(false)
    b.who:SetDrawLayer("OVERLAY", 4)

    b:EnableMouse(true)
    b:SetScript("OnEnter", function(self)
        if self.tip then ns.UI:SetTextTooltip(self, self.tip) end
    end)
    b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return b
end

-- Plays the stamp landing on a cell, after delay seconds.
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
    c.stamp:SetTexture(RAID_ICON .. Dauber())
    if c.stamp.SetRotation then c.stamp:SetRotation(c.angle or 0) end
    c.stamp:Show()
    c.ribbon:Show()
    c.who:SetText(who or "")
    c.who:Show()
    c.text:SetPoint("BOTTOMRIGHT", -3, 14)
    if isNew then
        StampIn(c, delay)
    elseif not c.stampAnim:IsPlaying() then
        c.stamp:SetAlpha(STAMP_ALPHA)
    end
end

local function HideStamp(c)
    c.stampAnim:Stop()
    c.stamp:Hide()
    c.ribbon:Hide()
    c.who:Hide()
    c.text:SetPoint("BOTTOMRIGHT", -3, 3)
end

---------------------------------------------------------------------------
-- BINGO! slam
---------------------------------------------------------------------------

local function CreateSlam(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:SetFrameLevel(parent:GetFrameLevel() + 5)
    f.band = f:CreateTexture(nil, "BACKGROUND")
    f.band:SetPoint("LEFT")
    f.band:SetPoint("RIGHT")
    f.band:SetHeight(70)
    f.band:SetColorTexture(0, 0, 0, 0.75)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(FONT, 46, "THICKOUTLINE")
    f.text:SetPoint("CENTER", 0, 4)
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.sub:SetPoint("TOP", f.text, "BOTTOM", 0, -2)
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

local function CreateRow(parent, height)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(SIDE_W, height)
    r.bar = r:CreateTexture(nil, "BACKGROUND")
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(1)
    r.left = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.left:SetPoint("LEFT", 3, 0)
    r.left:SetJustifyH("LEFT")
    r.left:SetWordWrap(false)
    r.right = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", -3, 0)
    r.right:SetJustifyH("RIGHT")
    r.left:SetPoint("RIGHT", r.right, "LEFT", -4, 0)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if self.tip then ns.UI:SetTextTooltip(self, self.tip, "ANCHOR_LEFT") end
    end)
    r:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    r:Hide()
    return r
end

local function SeasonBoard()
    local rows = {}
    for key, r in pairs(ns.Bingo:GetSeason()) do
        rows[#rows + 1] = { key = key, b = r.bingos or 0, f = r.firsts or 0, x = r.blackouts or 0 }
    end
    table.sort(rows, function(a, b)
        if a.b ~= b.b then return a.b > b.b end
        if a.f ~= b.f then return a.f > b.f end
        return a.key < b.key
    end)
    local lines = {}
    for i = 1, math.min(#rows, SEASON_ROWS) do
        local r = rows[i]
        lines[#lines + 1] = string.format("%d. %s  |cffffffff%d|r%s%s", i, KeyText(r.key), r.b,
            r.f > 0 and ("  |cff33ff99" .. r.f .. " first|r") or "",
            r.x > 0 and ("  |cffff8000" .. r.x .. " blackout|r") or "")
    end
    if #rows == 0 then lines[#lines + 1] = "|cff888888No bingos yet.|r" end
    return table.concat(lines, "\n")
end

local function RefreshRace(g)
    local race = g and ns.Bingo:GetRace() or {}
    local me = Util.PlayerKey()
    local shown = {}
    for i = 1, math.min(#race, RACE_ROWS) do shown[i] = race[i] end
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
            local nameText = KeyText(r.key)
            if r.key == me then nameText = "|cffffd100>|r " .. nameText end
            row.left:SetText(pos .. ". " .. nameText)
            if r.lines > 0 then
                row.right:SetText("|cffffd100BINGO" .. (r.lines > 1 and (" x" .. r.lines) or "") .. "|r")
                row.bar:SetColorTexture(0.6, 0.45, 0, 0.45)
            else
                row.right:SetText(r.marked .. "/25")
                row.bar:SetColorTexture(0.2, 0.55, 0.2, r.key == me and 0.5 or 0.3)
            end
            row.bar:SetWidth(math.max(1, SIDE_W * r.marked / 25))
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
            local who = e.who and WhoText(e.who) or "|cff888888someone|r"
            row.left:SetText(string.format("|T%s:12:12:0:0:64:64:5:59:5:59|t %s", tostring(icon), who))
            row.right:SetText("|cff888888" .. date("%H:%M", e.t) .. "|r")
            row.bar:SetColorTexture(0, 0, 0, 0)
            local col = RARITY[sq and sq.rarity] or RARITY.c
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

    for i = 1, 25 do
        local c = cells[i]
        local id = cardIds and cardIds[i]
        c.angle = ((i * 37) % 60 - 30) / 100
        if not id then
            c.icon:SetTexture(nil)
            c.icon2:Hide()
            c.badge:SetText("")
            c.text:SetText("")
            c.tip = nil
            HideStamp(c)
            SetPulse(c, false)
            Glow(c, false)
            c:SetBackdropColor(0.05, 0.05, 0.05, 0.6)
            c:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.6)
        elseif id == ns.BingoSquares.FREE then
            c.icon:SetTexture(ns.BingoSquares.FREE_ICON)
            c.icon:SetAlpha(0.55)
            c.icon2:Hide()
            c.badge:SetText("")
            c.text:SetText("|cffff8000Casual Disaster|r")
            c.tip = { { "Casual Disaster", 1, 0.5, 0 }, "Free square: everyone starts with the centre." }
            ShowStamp(c, "|cffff8000FREE|r", false)
            SetPulse(c, false)
            Glow(c, false)
            if onLine[i] then
                c:SetBackdropColor(0.35, 0.26, 0.03, 0.95)
                c:SetBackdropBorderColor(1, 0.82, 0, 1)
            else
                c:SetBackdropColor(0.3, 0.14, 0, 0.9)
                c:SetBackdropBorderColor(1, 0.5, 0, 1)
            end
        else
            local sq = ns.BingoSquares:Get(id)
            local col = RARITY[sq.rarity] or RARITY.c
            local hit = hits[id] ~= nil
            local icon, icon2 = ns.BingoSquares:Icon(sq)
            c.icon:SetTexture(icon)
            c.icon:SetAlpha(hit and 0.55 or 1)
            if icon2 then
                c.icon2:SetTexture(icon2)
                c.icon2:Show()
            else
                c.icon2:Hide()
            end
            c.badge:SetText(sq.badge or "")
            c.text:SetText(sq.text)
            c.text:SetTextColor(hit and 1 or col[1], hit and 1 or col[2], hit and 1 or col[3])
            c.tip = CellTip(sq, hit, g, away[i])
            if hit then
                local isNew = not view.hits[id]
                if isNew then
                    view.hits[id] = true
                    newCount = newCount + 1
                end
                local who = Bingo:GetWho(id)
                ShowStamp(c, who and WhoText(who) or "|cff888888marked|r", isNew, (newCount - 1) * 0.12)
            else
                HideStamp(c)
            end
            SetPulse(c, away[i] and active)
            if away[i] then awayCount = awayCount + 1 end
            Glow(c, sq.rarity == "l" and not hit)
            if onLine[i] then
                c:SetBackdropColor(0.35, 0.26, 0.03, 0.95)
                c:SetBackdropBorderColor(1, 0.82, 0, 1)
            elseif hit then
                c:SetBackdropColor(0.1, 0.24, 0.1, 0.92)
                c:SetBackdropBorderColor(col[1], col[2], col[3], 1)
            elseif away[i] and active then
                c:SetBackdropColor(0.06, 0.06, 0.07, 0.92)
                c:SetBackdropBorderColor(1, 0.82, 0, 0.9)
            else
                c:SetBackdropColor(0.06, 0.06, 0.07, 0.92)
                c:SetBackdropBorderColor(col[1], col[2], col[3], 0.6)
            end
        end
    end

    -- gold lines through completed lines
    local isFull = {}
    for _, li in ipairs(full) do isFull[li] = true end
    for li, tex in ipairs(lineTex) do tex:SetShown(isFull[li] == true) end

    -- the slam, once per new line / blackout (waits until the card is on screen)
    if g and cardIds then
        local delay = newCount > 0 and math.min(1.5, newCount * 0.12 + 0.2) or 0
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

    -- header
    if not g then
        statusText:SetText("No game yet. The raid leader starts one with |cffffd100/cdl bingo start|r.")
    else
        local host = ShortName(g.host or "?")
        statusText:SetText(string.format("%s  ·  host %s  ·  %d/25 marked  ·  %d line%s%s",
            active and "|cff33ff99Live|r" or "|cff888888Finished|r", host, marked, lines, lines == 1 and "" or "s",
            (active and awayCount > 0) and string.format("  ·  |cffff8000%d one away!|r", awayCount) or ""))
    end
    startBtn:SetEnabled(Bingo:CanStart() and not active)
    stopBtn:SetEnabled(active and Bingo:IsHost())
    announceBox:SetChecked(Bingo:GetAnnounce())
    local dauber = Dauber()
    for i, b in ipairs(dauberBtns) do
        b.sel:SetShown(i == dauber)
        b.tex:SetAlpha(i == dauber and 1 or 0.45)
    end
    RefreshRace(g)
    RefreshFeed(g)
    seasonText:SetText(SeasonBoard())
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function CreateCard(parent)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(CARD_W, CARD_H)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = false, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    f:SetBackdropColor(0.17, 0.05, 0.04, 0.95)

    local grid = CreateFrame("Frame", nil, f)
    grid:SetSize(GRID_W, GRID_H)
    grid:SetPoint("TOPLEFT", CARD_PAD, -(CARD_PAD + CARD_HEAD))

    for c, l in ipairs(LETTERS) do
        local fs = f:CreateFontString(nil, "OVERLAY")
        fs:SetFont(FONT, 20, "THICKOUTLINE")
        fs:SetText(l[1])
        fs:SetTextColor(l[2], l[3], l[4])
        fs:SetPoint("BOTTOM", grid, "TOPLEFT", (c - 1) * (CELL_W + GAP) + CELL_W / 2, 3)
    end

    cells = {}
    for i = 1, 25 do cells[i] = CreateCell(grid, i) end

    -- lines and the slam sit above the cells
    overlay = CreateFrame("Frame", nil, grid)
    overlay:SetAllPoints()
    overlay:SetFrameLevel(grid:GetFrameLevel() + 10)
    lineTex = {}
    for li, line in ipairs(ns.BingoCard.LINES) do
        local a, b = cells[line[1]], cells[line[#line]]
        local t = overlay:CreateLine(nil, "OVERLAY")
        t:SetThickness(5)
        t:SetColorTexture(1, 0.82, 0, 0.85)
        t:SetStartPoint("CENTER", a)
        t:SetEndPoint("CENTER", b)
        t:Hide()
        lineTex[li] = t
    end
    slam = CreateSlam(overlay)
    return f
end

local function CreateDauberPicker(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(48 + 8 * 20, 20)
    local label = ns.UI:CreateLabel(f, "Dauber", "GameFontNormalSmall")
    label:SetPoint("LEFT", 2, 0)
    dauberBtns = {}
    for i = 1, 8 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(18, 18)
        b:SetPoint("LEFT", 44 + (i - 1) * 20, 0)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetPoint("TOPLEFT", -2, 2)
        b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
        b.sel:SetColorTexture(1, 0.82, 0, 0.5)
        b.tex = b:CreateTexture(nil, "ARTWORK")
        b.tex:SetAllPoints()
        b.tex:SetTexture(RAID_ICON .. i)
        b:SetScript("OnClick", function()
            ns.Games:GetData("bingo").dauber = i
            BingoUI:Refresh()
        end)
        b:SetScript("OnEnter", function(self)
            ns.UI:SetTextTooltip(self, { "Dauber: " .. MARKER_NAMES[i], "Stamps your marked squares with this marker." })
        end)
        b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
        dauberBtns[i] = b
    end
    return f
end

local function SideHeader(parent, text)
    return ns.UI:CreateLabel(parent, text, "GameFontNormal")
end

function BingoUI:CreatePanel(parent)
    panel = CreateFrame("Frame", nil, parent)

    local title = ns.UI:CreateLabel(panel, "Council Bingo", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 10, -10)

    startBtn = ns.UI:CreateButton(panel, "Start game", 100, 22, function() ns.Bingo:Start() end)
    startBtn:SetPoint("TOPRIGHT", -10, -8)
    stopBtn = ns.UI:CreateButton(panel, "End game", 90, 22, function() ns.Bingo:Stop() end)
    stopBtn:SetPoint("RIGHT", startBtn, "LEFT", -4, 0)

    statusText = ns.UI:CreateLabel(panel, "", "GameFontHighlightSmall")
    statusText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    statusText:SetPoint("RIGHT", -10, 0)

    card = CreateCard(panel)
    card:SetPoint("TOPLEFT", 4, -48)

    local dauber = CreateDauberPicker(panel)
    dauber:SetPoint("TOPLEFT", card, "BOTTOMLEFT", 6, -4)
    announceBox = ns.UI:CreateCheckbox(panel, "Announce bingos in raid chat (host)",
        function() return ns.Bingo:GetAnnounce() end,
        function(v) ns.Bingo:SetAnnounce(v) end)
    announceBox:SetPoint("LEFT", dauber, "RIGHT", 14, 0)

    -- right column: race, feed, season
    local side = CreateFrame("Frame", nil, panel)
    side:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, -4)
    side:SetSize(SIDE_W, CARD_H)

    local raceHead = SideHeader(side, "Race")
    raceHead:SetPoint("TOPLEFT", 0, 0)
    raceRows = {}
    for i = 1, RACE_ROWS do
        local r = CreateRow(side, 15)
        r:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 0, -3 - (i - 1) * 16)
        raceRows[i] = r
    end
    raceEmpty = ns.UI:CreateLabel(side, "|cff888888No game running.|r", "GameFontHighlightSmall")
    raceEmpty:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 3, -4)

    local feedHead = SideHeader(side, "Latest")
    feedHead:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 0, -10 - RACE_ROWS * 16)
    feedRows = {}
    for i = 1, FEED_ROWS do
        local r = CreateRow(side, 15)
        r:SetPoint("TOPLEFT", feedHead, "BOTTOMLEFT", 0, -3 - (i - 1) * 16)
        feedRows[i] = r
    end
    feedEmpty = ns.UI:CreateLabel(side, "|cff888888Nothing yet...|r", "GameFontHighlightSmall")
    feedEmpty:SetPoint("TOPLEFT", feedHead, "BOTTOMLEFT", 3, -4)

    local seasonHead = SideHeader(side, "Season")
    seasonHead:SetPoint("TOPLEFT", feedHead, "BOTTOMLEFT", 0, -10 - FEED_ROWS * 16)
    seasonText = ns.UI:CreateLabel(side, "", "GameFontHighlightSmall")
    seasonText:SetPoint("TOPLEFT", seasonHead, "BOTTOMLEFT", 3, -4)
    seasonText:SetWidth(SIDE_W)
    seasonText:SetJustifyH("LEFT")
    seasonText:SetJustifyV("TOP")

    panel:SetScript("OnShow", function() BingoUI:Refresh() end)
    panel.OnGameShown = function() BingoUI:Refresh() end
    return panel
end

---------------------------------------------------------------------------
-- Mini counter
---------------------------------------------------------------------------

local function CreateMini()
    local f = CreateFrame("Button", "CDLootBingoMini", UIParent, "BackdropTemplate")
    f:SetSize(150, 24)
    f:SetPoint("TOP", 0, -120)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, 0.7)
    f:SetBackdropBorderColor(1, 0.5, 0, 0.8)
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
        ns.UI:SetTextTooltip(self, { "Council Bingo", "Left-click: open your card", "Right-click: hide until the next game" })
    end)
    f:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("CENTER")
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
        if lines > 0 then extra = "  |cff33ff99BINGO|r"
        elseif awayCount > 0 then extra = "  |cffff80001 away!|r" end
        self.text:SetText(string.format("Bingo %d/25%s", marked, extra))
        self:Show()
    end
    f:Hide()
    return f
end

-- For the test harness.
function BingoUI:GetWidgets()
    return { panel = panel, cells = cells, lines = lineTex, slam = slam, race = raceRows, feed = feedRows,
        dauber = dauberBtns, status = statusText, card = card }
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

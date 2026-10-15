if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/UI.lua", ...) then return end -- DisasterZone Games/Bingo/UI.lua
-- ns.BingoUI: the Council Bingo panel, its moments (toasts, the legendary takeover) and a small movable counter
-- ("Bingo 12/25") shown while a game runs and the main window is closed.
-- The panel: a page banner (the raid's loading screen, LIVE, the raid's deck, host, the line that is one away, your
-- points / bingos / marked, Start / End) over two views picked on the hub's strip (Card | Codex):
--   Card: the B-I-N-G-O card (each square a named moment: its spell's icon in the item-quality frame of its quality, a
--   quality bar and wash, your legendary burning; your raid-marker dauber's ink and marker on marked squares; a gold
--   thread through the gaps of a line one square short, broken where the square you need is, and glowing on a full
--   line; 1 AWAY on that square) and a right column: your legendary, the race (everyone's card as a 5x5 dot map),
--   the moments of the game as quality-coloured links, your dauber.
--   Codex: the season ladder (points, bingos, legendaries), the legendaries this character has witnessed, and every
--   square of the set: in its quality frame once seen, a silhouette until then.
-- How a square arrives depends on its quality: a stamp (common), a green flash (uncommon), a toast (rare, on your
-- card), a toast for the whole raid (epic), the takeover in the panel or a legendary toast on screen (legendary).
local addonName, ns = ...

local BingoUI = ns:NewModule("BingoUI")
local Util = ns.Util
local S = ns.Style

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max

local PAD, GAP = S.PAD, S.GAP
local HERO_H, SIDE_W = 70, 232
local LETTER_H, CARD_PAD, CELL_GAP = 20, 8, 5
local FALLBACK_W, FALLBACK_H = 786, 518     -- the stage before the client has laid it out
local RACE_ROWS, FEED_ROWS, LADDER_ROWS, WITNESS_ROWS = 5, 5, 8, 4
local ICON = 28                              -- a square's icon
local CODEX_ICON, CODEX_GAP = 20, 5
local TAKEOVER_TIME = 6                      -- the legendary takeover stays this long (a click ends it sooner)
local FONT = "Fonts\\FRIZQT__.TTF"
local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local RADIAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\MyBiS\\Radial"
local SEAL = "Interface\\AddOns\\" .. addonName .. "\\Media\\Launcher\\seal"
local STAR4 = "Interface\\Cooldown\\star4"
-- The client's loot toasts: the item-quality icon frames (1024 x 256 atlas, a 60 px frame each along its foot) and the
-- legendary toast (the dragon frame and its starburst, 512 x 512).
local TOAST_ATLAS = "Interface\\LootFrame\\LootToastAtlas"
local LEGENDARY_TOAST = "Interface\\LootFrame\\LegendaryToast"
local function AtlasFrame(i) return { (568 + 60 * i) / 1024, (628 + 60 * i) / 1024, 180 / 256, 240 / 256 } end
local QFRAME = { r = AtlasFrame(0), u = AtlasFrame(1), l = AtlasFrame(3), e = AtlasFrame(4) }
local DRAGON = { 202 / 512, 504 / 512, 0, 117 / 512 }
local BURST = { 14 / 512, 190 / 512, 12 / 512, 194 / 512 }

local GOLD = S.C.GOLD
local LETTERS = { "B", "I", "N", "G", "O" }
local MARKER_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
-- The dauber's ink: the colour of each raid marker (star, circle, diamond, triangle, moon, square, cross, skull).
local INK = {
    { 1, 0.86, 0.25 }, { 1, 0.56, 0.16 }, { 0.78, 0.4, 1 }, { 0.35, 0.9, 0.4 },
    { 0.72, 0.82, 1 }, { 0.3, 0.62, 1 }, { 1, 0.3, 0.25 }, { 0.92, 0.92, 0.92 },
}
local MOMENT_SOUND = { r = "UI_LOOT_TOAST_LESSER_ITEM_WON", e = "UI_EPICLOOT_TOAST", l = "UI_LEGENDARY_LOOT_TOAST" }

local panel, hero, stats, startBtn, stopBtn, seg
local card, grid, cells, threads, slam
local side, yourLeg, raceHead, raceRows, feedHead, feedRows, raceEmpty, feedEmpty, dauberBar, dauberBtns, announceBox
local codex, ladderHead, ladderRows, ladderEmpty, witnessHead, witnessRows, witnessEmpty, codexHead, codexBar
local codexGroups, codexCells
local takeover
local mini
local view = "card"

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Squares() return ns.BingoSquares end
local function Q(q) return ns.BingoSquares.QUALITY[q] or ns.BingoSquares.QUALITY.c end

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



-- A grey tooltip line (the SUB colour).
local function Grey(text, wrap)
    local r, g, b = S:RGB("SUB")
    return { text, r, g, b, wrap = wrap }
end

-- A name coloured by class when it's someone in the group (bosses and pets stay gold).
local function WhoText(who)
    if type(who) ~= "string" then return "" end
    for key, info in pairs(Util.group or {}) do
        if Util.ShortName(key, true) == who and info.classFile then
            return "|c" .. Util.ClassColorHex(info.classFile) .. who .. "|r"
        end
    end
    return S:Wrap("GOLD", who)
end

local function KeyText(key) return ns.UI:ColoredName(key, ns.UI:ClassOf(key)) end

-- "[Title]" in its quality's colour: how moments read (like item links).
local function LinkText(sq)
    return S:Hex(Q(sq.q).color) .. "[" .. sq.title .. "]|r"
end

-- A raid's name ("Serpentshrine Cavern") from its plan key.
local function RaidName(key)
    if not key or not ns.ItemDB then return nil end
    local _, raid = ns.ItemDB:GetRaidByPlanKey(key)
    return raid and raid.name or ns.ItemDB:RaidShort(key)
end

local function PlaySoundKit(name, fallback)
    local id = SOUNDKIT and SOUNDKIT[name] or fallback
    if id and PlaySound then pcall(PlaySound, id) end
end

-- How often this character has seen square id happen: "seen in N of M games" (nil before the first game).
local function SeenText(id)
    local Bingo = ns.Bingo
    local games = Bingo:GamesPlayed()
    if games <= 0 then return nil end
    local e = Bingo:GetCodex()[id]
    local n = type(e) == "table" and tonumber(e.n) or 0
    return string.format("Seen in %d of %d game%s", n, games, games == 1 and "" or "s")
end

local function SetScaleAnim(a, from, to)
    if a.SetScaleFrom then
        a:SetScaleFrom(from, from)
        a:SetScaleTo(to, to)
    else
        a:SetScale(to / from, to / from)
    end
end

local function Desaturate(tex, amount)
    if tex.SetDesaturation then tex:SetDesaturation(amount) elseif tex.SetDesaturated then tex:SetDesaturated(amount > 0.5) end
end

-- An icon in its item-quality frame (the loot toast's), as a frame: f.icon, f:SetSquare(sq, silhouette).
local function CreateQualityIcon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.rim = ns.UI:Fill(f, { 1, 1, 1, 0.18 }, "ARTWORK", -2)      -- a common square: a plain 1 px rim
    f.rim:ClearAllPoints()
    f.rim:SetPoint("TOPLEFT", -2, 2)
    f.rim:SetPoint("BOTTOMRIGHT", 2, -2)
    f.back = ns.UI:Fill(f, { 0, 0, 0, 1 }, "ARTWORK", -1)
    f.back:ClearAllPoints()
    f.back:SetPoint("TOPLEFT", -1, 1)
    f.back:SetPoint("BOTTOMRIGHT", 1, -1)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints()
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local pad = floor(size * 0.22 + 0.5)
    f.frame = f:CreateTexture(nil, "OVERLAY")
    f.frame:SetTexture(TOAST_ATLAS)
    f.frame:SetPoint("TOPLEFT", -pad, pad)
    f.frame:SetPoint("BOTTOMRIGHT", pad, -pad)
    f.qm = ns.UI:Text(f, "body", "DIM", { justify = "CENTER" })
    f.qm:SetPoint("CENTER", 0, 0)
    f.qm:SetText("?")
    f.qm:Hide()
    function f:SetSquare(sq, silhouette)
        self.icon:SetTexture(Squares():Icon(sq))
        local tc = sq and not silhouette and QFRAME[sq.q]
        if tc then
            self.frame:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            self.frame:Show()
            self.rim:Hide()
        else
            self.frame:Hide()
            self.rim:Show()
        end
        if silhouette then
            Desaturate(self.icon, 1)
            self.icon:SetVertexColor(0.22, 0.22, 0.24)
        else
            Desaturate(self.icon, 0)
            self.icon:SetVertexColor(1, 1, 1)
        end
        self.qm:SetShown(silhouette and true or false)
    end
    return f
end

-- The legendary edge: the cell's own edges in orange and a spark that runs round it (BingoUI's OnUpdate moves it).
local function PlaceSpark(spark, host, t)
    local w, h = host:GetWidth() or 0, host:GetHeight() or 0
    if w <= 0 or h <= 0 then spark:Hide() return end
    local per = 2 * (w + h)
    local d = (t % 1) * per
    local x, y
    if d < w then x, y = d, 0
    elseif d < w + h then x, y = w, -(d - w)
    elseif d < 2 * w + h then x, y = w - (d - w - h), -h
    else x, y = 0, -(h - (d - 2 * w - h)) end
    spark:ClearAllPoints()
    spark:SetPoint("CENTER", host, "TOPLEFT", x, y)
    spark:Show()
end

local function CreateTwinkles(host, n, layer)
    local list = {}
    for i = 1, n do
        local t = host:CreateTexture(nil, layer or "OVERLAY")
        t:SetTexture(STAR4)
        t:SetBlendMode("ADD")
        t:SetVertexColor(1, 0.75, 0.35)
        local size = ({ 16, 11, 9 })[(i - 1) % 3 + 1]
        t:SetSize(size, size)
        local ag = t:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(0.1)
        a:SetToAlpha(0.95)
        a:SetDuration(1.2 + i * 0.35)
        a:SetSmoothing("IN_OUT")
        t.anim = ag
        t:Hide()
        list[i] = t
    end
    return list
end

local function ShowTwinkles(list, on)
    for _, t in ipairs(list) do
        if on then
            if not t:IsShown() then t:Show() t.anim:Play() end
        elseif t:IsShown() then
            t.anim:Stop()
            t:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Cells
---------------------------------------------------------------------------

local function CreateCell(parent, i)
    local c = CreateFrame("Frame", nil, parent)
    c.index = i
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 0)
    c.bg:SetAllPoints()
    -- the quality's wash from the top; epic / legendary: a glow at the top (legendary: embers at the foot too)
    c.wash = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.wash:SetPoint("TOPLEFT", 1, -1)
    c.wash:SetPoint("TOPRIGHT", -1, -1)
    -- (the lower half of the radial texture from the top edge down / the upper half from the foot up: they stay inside
    -- the square)
    c.glow = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.glow:SetTexture(RADIAL)
    c.glow:SetTexCoord(0, 1, 0.5, 1)
    c.glow:SetBlendMode("ADD")
    c.glow:SetPoint("TOPLEFT", 1, -1)
    c.glow:SetPoint("TOPRIGHT", -1, -1)
    c.ember = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.ember:SetTexture(RADIAL)
    c.ember:SetTexCoord(0.15, 0.85, 0, 0.5)
    c.ember:SetBlendMode("ADD")
    c.ember:SetPoint("BOTTOMLEFT", 1, 1)
    c.ember:SetPoint("BOTTOMRIGHT", -1, 1)
    -- your dauber's ink behind the icon (marked)
    c.ink = c:CreateTexture(nil, "BACKGROUND", nil, 3)
    c.ink:SetTexture(RADIAL)
    c.ink:Hide()
    -- "one away": a soft gold pulse
    c.pulse = c:CreateTexture(nil, "BACKGROUND", nil, 4)
    c.pulse:SetPoint("TOPLEFT", 1, -1)
    c.pulse:SetPoint("BOTTOMRIGHT", -1, 1)
    c.pulse:SetColorTexture(S:Alpha("GOLD", 1))
    c.pulse:SetBlendMode("ADD")
    c.pulse:SetAlpha(0.07)
    c.pulse:Hide()
    c.pulseAnim = c.pulse:CreateAnimationGroup()
    c.pulseAnim:SetLooping("BOUNCE")
    local p = c.pulseAnim:CreateAnimation("Alpha")
    p:SetFromAlpha(0.02)
    p:SetToAlpha(0.13)
    p:SetDuration(0.9)
    p:SetSmoothing("IN_OUT")
    ns.UI:AddEdges(c, "BORDER", true)
    c.qbar = c:CreateTexture(nil, "BORDER", nil, 2)
    c.qbar:SetPoint("TOPLEFT", 1, -1)
    c.qbar:SetPoint("TOPRIGHT", -1, -1)
    c.qbar:SetHeight(2)

    -- the words, the icon and the marks, above the gold threads (CreateCard sets its level)
    c.top = CreateFrame("Frame", nil, c)
    c.top:SetAllPoints()
    c.qi = CreateQualityIcon(c.top, ICON)
    c.qi:SetPoint("TOP", 0, -9)
    c.seal = c.top:CreateTexture(nil, "ARTWORK")
    c.seal:SetTexture(SEAL)
    c.seal:SetSize(40, 40)
    c.seal:SetPoint("TOP", 0, -6)
    c.seal:Hide()
    c.text = ns.UI:Text(c.top, "small", "TEXT", { wrap = true, justify = "CENTER" })
    c.text:SetJustifyV("TOP")
    c.text:SetPoint("TOP", c.qi, "BOTTOM", 0, -6)
    c.text:SetPoint("LEFT", 4, 0)
    c.text:SetPoint("RIGHT", -4, 0)
    c.text:SetPoint("BOTTOM", 0, 2)
    c.away = ns.UI:CreatePill(c.top, 12)
    c.away:Set("1 AWAY", "rank")
    c.away:SetPoint("TOPLEFT", 4, -5)
    c.away:Hide()

    -- the dauber's marker in the corner, landing with a stamp and a flash in the square's quality colour
    c.stamp = c.top:CreateTexture(nil, "OVERLAY", nil, 5)
    c.stamp:SetSize(15, 15)
    c.stamp:SetPoint("TOPRIGHT", -4, -5)
    c.stampAnim = c.stamp:CreateAnimationGroup()
    local s = c.stampAnim:CreateAnimation("Scale")
    SetScaleAnim(s, 2.8, 1)
    s:SetDuration(0.22)
    s:SetSmoothing("IN")
    if s.SetOrigin then s:SetOrigin("CENTER", 0, 0) end
    local a = c.stampAnim:CreateAnimation("Alpha")
    a:SetFromAlpha(0)
    a:SetToAlpha(1)
    a:SetDuration(0.12)
    c.stampAnim:SetScript("OnFinished", function() c.stamp:SetAlpha(1) end)
    c.stampParts = { s, a }
    c.flash = c.top:CreateTexture(nil, "OVERLAY", nil, 6)
    c.flash:SetAllPoints()
    c.flash:SetColorTexture(1, 1, 1, 1)
    c.flash:SetBlendMode("ADD")
    c.flash:SetAlpha(0)
    c.flashAnim = c.flash:CreateAnimationGroup()
    local f = c.flashAnim:CreateAnimation("Alpha")
    f:SetFromAlpha(0.45)
    f:SetToAlpha(0)
    f:SetDuration(0.6)
    c.flashAnim:SetScript("OnFinished", function() c.flash:SetAlpha(0) end)
    c.flashPart = f

    -- legendary: a spark running round the edge and a few twinkles
    c.spark = c.top:CreateTexture(nil, "OVERLAY", nil, 7)
    c.spark:SetTexture(STAR4)
    c.spark:SetBlendMode("ADD")
    c.spark:SetVertexColor(1, 0.78, 0.4)
    c.spark:SetSize(14, 14)
    c.spark:Hide()
    c.twinkles = CreateTwinkles(c.top, 3)
    c.twinkles[1]:SetPoint("TOPLEFT", 8, -6)
    c.twinkles[2]:SetPoint("RIGHT", -8, 6)
    c.twinkles[3]:SetPoint("BOTTOMLEFT", 18, 6)

    c:EnableMouse(true)
    c.hl = c:CreateTexture(nil, "HIGHLIGHT")
    c.hl:SetAllPoints()
    c.hl:SetColorTexture(S:Alpha("HAIRLINE", 0.035))
    c:SetScript("OnEnter", function(self)
        if self.tip then ns.UI:SetTextTooltip(self, self.tip) end
    end)
    c:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return c
end

local function StampIn(c, delay, color)
    c.stamp:SetAlpha(0)
    for _, anim in ipairs(c.stampParts) do anim:SetStartDelay(delay) end
    c.stampAnim:Stop()
    c.stampAnim:Play()
    c.flash:SetVertexColor(color[1], color[2], color[3])
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

local DARK_TOP, DARK_BOTTOM = { 0.11, 0.115, 0.135, 1 }, { 0.078, 0.082, 0.098, 1 }
local INK_TOP = { 0.125, 0.12, 0.105, 1 }
local LEG_TOP, LEG_BOTTOM = { 0.13, 0.10, 0.075, 1 }, { 0.085, 0.07, 0.06, 1 }

-- Paints one square. st = { id, sq, marked, isNew, delay, onLine, away, active, fated, mine (it's my card) }
local function PaintCell(c, st)
    local ink = INK[Dauber()] or INK[1]
    c.legendary = nil
    c.spark:Hide()
    ShowTwinkles(c.twinkles, false)
    c.glow:Hide()
    c.ember:Hide()
    c.away:Hide()
    if not st.id then
        c.qi:Hide()
        c.seal:Hide()
        c.text:SetText("")
        c.tip = nil
        c.stamp:Hide()
        c.ink:Hide()
        c.wash:Hide()
        c.qbar:Hide()
        SetPulse(c, false)
        ns.UI:Gradient(c.bg, "VERTICAL", { 0.06, 0.06, 0.07, 0.7 }, { 0.09, 0.09, 0.105, 0.7 })
        ns.UI:SetEdgeColor(c, S:Alpha("HAIRLINE", 0.04))
        return
    end
    if st.id == Squares().FREE then
        c.qi:Hide()
        c.seal:Show()
        c.text:SetText(S:Wrap("GOLD", "FREE"))
        c.text:ClearAllPoints()
        c.text:SetPoint("TOP", c.seal, "BOTTOM", 0, -3)
        c.text:SetPoint("LEFT", 4, 0)
        c.text:SetPoint("RIGHT", -4, 0)
        c.tip = { { "Casual Disaster", 1, 0.5, 0 }, "Free square: everyone starts with the centre." }
        c.stamp:Hide()
        c.ink:Hide()
        c.wash:Hide()
        c.qbar:Hide()
        SetPulse(c, false)
        ns.UI:Gradient(c.bg, "VERTICAL", { 0.09, 0.075, 0.035, 1 }, { 0.15, 0.125, 0.06, 1 })
        ns.UI:SetEdgeColor(c, S:Alpha("GOLD", st.onLine and 0.6 or 0.3))
        return
    end
    local sq = st.sq
    local qual = Q(sq.q)
    local col = qual.color
    c.seal:Hide()
    c.qi:Show()
    c.qi:SetSquare(sq)
    c.text:ClearAllPoints()
    c.text:SetPoint("TOP", c.qi, "BOTTOM", 0, -6)
    c.text:SetPoint("LEFT", 4, 0)
    c.text:SetPoint("RIGHT", -4, 0)
    c.text:SetPoint("BOTTOM", 0, 2)
    c.text:SetText(sq.title)
    local w, h = c:GetWidth(), c:GetHeight()
    if not w or w <= 0 then w, h = 98, 76 end

    -- quality: bar on top, a wash (not on commons), a glow for epic and legendary
    if sq.q ~= "c" then
        c.qbar:SetColorTexture(col[1], col[2], col[3], 0.9)
        c.qbar:Show()
        c.wash:SetHeight(max(1, h * 0.46))
        ns.UI:GradientRGBA(c.wash, "VERTICAL", col[1], col[2], col[3], 0, col[1], col[2], col[3],
            sq.q == "u" and 0.07 or 0.1)
        c.wash:Show()
    else
        c.qbar:Hide()
        c.wash:Hide()
    end
    if sq.q == "e" or sq.q == "l" then
        c.glow:SetHeight(h * 0.62)
        c.glow:SetVertexColor(col[1], col[2], col[3], sq.q == "l" and 0.32 or 0.26)
        c.glow:Show()
    end
    if sq.q == "l" then
        c.ember:SetHeight(h * 0.4)
        c.ember:SetVertexColor(1, 0.43, 0, 0.3)
        c.ember:Show()
        c.legendary = true
        ShowTwinkles(c.twinkles, not st.marked)
    end

    -- marked or not
    if st.marked then
        local n = Dauber()
        c.stamp:SetTexture(RAID_ICON .. n)
        c.stamp:Show()
        local size = min(w, h) * 1.15
        c.ink:ClearAllPoints()
        c.ink:SetPoint("CENTER", c.qi, "CENTER")
        c.ink:SetSize(size, size)
        c.ink:SetVertexColor(ink[1], ink[2], ink[3], 0.55)
        c.ink:Show()
        if st.isNew then
            StampIn(c, st.delay or 0, sq.q == "c" and { 1, 0.9, 0.55 } or col)
        elseif not c.stampAnim:IsPlaying() then
            c.stamp:SetAlpha(1)
        end
        c.text:SetTextColor(1, 0.97, 0.88)
        c.qi.icon:SetVertexColor(1, 1, 1)
        Desaturate(c.qi.icon, 0)
    else
        c.stampAnim:Stop()
        c.stamp:Hide()
        c.ink:Hide()
        c.text:SetTextColor(0.64, 0.62, 0.55)
        if sq.q ~= "l" then
            Desaturate(c.qi.icon, 0.55)
            c.qi.icon:SetVertexColor(0.66, 0.66, 0.68)
        end
    end
    SetPulse(c, st.away and st.active)
    c.away:SetShown(st.away and st.active and true or false)

    -- the ground and the edge
    if sq.q == "l" then
        ns.UI:Gradient(c.bg, "VERTICAL", LEG_BOTTOM, LEG_TOP)
    elseif st.marked then
        ns.UI:Gradient(c.bg, "VERTICAL", DARK_BOTTOM, INK_TOP)
    else
        ns.UI:Gradient(c.bg, "VERTICAL", DARK_BOTTOM, DARK_TOP)
    end
    if st.away and st.active then
        ns.UI:SetEdgeColor(c, S:Alpha("GOLD", 0.85))
    elseif st.onLine then
        ns.UI:SetEdgeColor(c, S:Alpha("GOLD", 0.55))
    elseif sq.q == "l" then
        ns.UI:SetEdgeColor(c, 1, 0.5, 0, 0.75)
    elseif sq.q == "e" then
        ns.UI:SetEdgeColor(c, col[1], col[2], col[3], 0.3)
    elseif st.marked then
        ns.UI:SetEdgeColor(c, ink[1], ink[2], ink[3], 0.3)
    else
        ns.UI:SetEdgeColor(c, S:Alpha("HAIRLINE", 0.07))
    end

    -- the tooltip: the name in its colour, the rule, then the state
    local tip = { { sq.title, col[1], col[2], col[3] },
        Grey(string.format("%s  \194\183  %d point%s", qual.name, qual.points, qual.points == 1 and "" or "s")),
        { sq.text, 1, 1, 1, wrap = true } }
    if sq.raid then tip[#tip + 1] = { (RaidName(sq.raid) or sq.raid) .. " deck", 0.5, 0.75, 1 } end
    if sq.hint then tip[#tip + 1] = Grey(sq.hint, true) end
    if st.marked then
        local g = ns.Bingo:GetGame()
        local who = ns.Bingo:GetWho(sq.id)
        if st.fated and not (g and g.hits[sq.id]) then
            tip[#tip + 1] = { "Fated: daubed by your legendary", 1, 0.5, 0 }
        elseif g and g.hits[sq.id] then
            tip[#tip + 1] = { "Marked at " .. date("%H:%M", g.hits[sq.id]) .. (who and (" by " .. who) or ""), 0.2, 1, 0.6 }
        end
    else
        tip[#tip + 1] = { "Not yet...", 0.55, 0.55, 0.55 }
        if st.away and st.active then tip[#tip + 1] = { "One away from a line!", GOLD[1], GOLD[2], GOLD[3] } end
    end
    local seen = SeenText(sq.id)
    if seen then tip[#tip + 1] = { seen, 0.55, 0.55, 0.55 } end
    c.tip = tip
end

---------------------------------------------------------------------------
-- BINGO! slam
---------------------------------------------------------------------------

local function CreateSlam(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints()
    f:SetFrameLevel(parent:GetFrameLevel() + 8)     -- (over the squares' words)
    f.band = f:CreateTexture(nil, "BACKGROUND")
    f.band:SetPoint("LEFT")
    f.band:SetPoint("RIGHT")
    f.band:SetHeight(84)
    f.bandL = f:CreateTexture(nil, "BACKGROUND")
    f.bandL:SetPoint("TOPLEFT", f.band, "TOPLEFT")
    f.bandL:SetPoint("BOTTOMRIGHT", f.band, "BOTTOM")
    ns.UI:Gradient(f.bandL, "HORIZONTAL", { 0, 0, 0, 0 }, { 0, 0, 0, 0.82 })
    f.bandR = f:CreateTexture(nil, "BACKGROUND")
    f.bandR:SetPoint("TOPLEFT", f.band, "TOP")
    f.bandR:SetPoint("BOTTOMRIGHT", f.band, "BOTTOMRIGHT")
    ns.UI:Gradient(f.bandR, "HORIZONTAL", { 0, 0, 0, 0.82 }, { 0, 0, 0, 0 })
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
    f.text:SetFont(FONT, S:Size(44), "OUTLINE")   -- (the slam's display letters)
    f.text:SetShadowOffset(2, -2)
    f.text:SetShadowColor(0, 0, 0, 1)
    f.text:SetPoint("CENTER", 0, 6)
    f.sub = ns.UI:Text(f, "body", nil, { justify = "CENTER" })
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
-- The right column
---------------------------------------------------------------------------

-- Your legendary: the one square on your card that can win you the night.
local function CreateYourLegendary(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(64)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    ns.UI:Gradient(f.bg, "HORIZONTAL", { 0.16, 0.10, 0.05, 1 }, { 0.085, 0.07, 0.055, 1 })
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.glow:SetTexture(RADIAL)
    f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.5, 0, 0.4)
    f.glow:SetSize(130, 110)
    f.glow:SetPoint("CENTER", f, "LEFT", 30, 0)
    ns.UI:AddEdges(f, "BORDER")
    ns.UI:SetEdgeColor(f, 1, 0.5, 0, 0.55)
    f.qi = CreateQualityIcon(f, 34)
    f.qi:SetPoint("LEFT", 14, 0)
    f.kicker = ns.UI:Text(f, "caps", { 1, 0.6, 0.18 })
    f.kicker:SetPoint("TOPLEFT", 60, -9)
    f.title = ns.UI:Text(f, "emph", { 1, 0.86, 0.66 })
    f.title:SetPoint("TOPLEFT", f.kicker, "BOTTOMLEFT", 0, -3)
    f.title:SetPoint("RIGHT", -8, 0)
    f.sub = ns.UI:Text(f, "small", "SUB")
    f.sub:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.sub:SetPoint("RIGHT", -8, 0)
    f.spark = f:CreateTexture(nil, "OVERLAY")
    f.spark:SetTexture(STAR4)
    f.spark:SetBlendMode("ADD")
    f.spark:SetVertexColor(1, 0.78, 0.4)
    f.spark:SetSize(14, 14)
    f.spark:Hide()
    f.twinkles = CreateTwinkles(f, 1)
    f.twinkles[1]:SetPoint("CENTER", f.qi, "TOPRIGHT", -2, -2)
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self) if self.tip then ns.UI:SetTextTooltip(self, self.tip, "ANCHOR_LEFT") end end)
    f:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
    return f
end

local function RefreshYourLegendary(g)
    local f = yourLeg
    local Bingo = ns.Bingo
    local me = Util.PlayerKey()
    local id = g and Bingo:GetLegendary(me)
    local sq = id and Squares():Get(id)
    f.hasLegendary = sq ~= nil
    if not sq then
        f.qi:SetSquare(nil, true)
        f.kicker:SetText("YOUR LEGENDARY")
        f.title:SetText(S:Wrap("SUB", "Dealt with your card"))
        f.sub:SetText("Every card holds one.")
        f.tip = nil
        ShowTwinkles(f.twinkles, false)
        return
    end
    f.qi:SetSquare(sq)
    local hit = g.hits[id] ~= nil
    f.kicker:SetText(hit and "YOUR LEGENDARY WENT OFF" or "YOUR LEGENDARY")
    f.title:SetText(sq.title)
    local holders = Bingo:CountHolders(id)
    local parts = { string.format("%d raider%s hold%s it", holders, holders == 1 and "" or "s", holders == 1 and "s" or "") }
    local seen = SeenText(id)
    if seen then parts[#parts + 1] = seen:gsub("^Seen", "seen") end
    f.sub:SetText(table.concat(parts, "  \194\183  "))
    ShowTwinkles(f.twinkles, not hit)
    local tip = { { sq.title, 1, 0.5, 0 }, { sq.text, 1, 1, 1, wrap = true },
        Grey("Legendary  \194\183  10 points"),
        { "Fated: when it goes off, it also daubs the square that brings you closest to a line.", GOLD[1], GOLD[2], GOLD[3], wrap = true } }
    local fated = Bingo:GetFated(me)
    if hit and fated then
        local card = Bingo:GetMyCard()
        local fsq = card and Squares():Get(card[fated])
        if fsq then tip[#tip + 1] = { "Fated daubed " .. fsq.title .. ".", 1, 0.5, 0 } end
    end
    f.tip = tip
end

-- A list row of the right column / the ladder: rank, a class icon, the name, a pill, a slot at the right.
local function CreateListRow(parent, h, opts)
    opts = opts or {}
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(h)
    ns.UI:DecorateRow(r, { hover = true, you = true })
    local x = 6
    if opts.rank then
        r.rank = ns.UI:Text(r, "small", "DIM", { justify = "RIGHT" })
        r.rank:SetWidth(12)
        r.rank:SetPoint("LEFT", 2, 0)
        x = 20
    end
    if opts.class then
        r.class = r:CreateTexture(nil, "ARTWORK")
        r.class:SetSize(14, 14)
        r.class:SetPoint("LEFT", x, 0)
        x = x + 20
    end
    if opts.qi then
        r.qi = CreateQualityIcon(r, 16)
        r.qi:SetPoint("LEFT", x + 4, 0)
        x = x + 30
    end
    r.right = ns.UI:Text(r, "small", "GOLD", { justify = "RIGHT" })
    r.right:SetPoint("RIGHT", -6, 0)
    r.left = ns.UI:Text(r, "body")
    r.left:SetPoint("LEFT", x, 0)
    r.left:SetWordWrap(false)
    r.left:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
    r:EnableMouse(true)
    r:HookScript("OnEnter", function(self) if self.tip then ns.UI:SetTextTooltip(self, self.tip, "ANCHOR_LEFT") end end)
    r:HookScript("OnLeave", function() ns.UI:HideTooltip() end)
    r:Hide()
    return r
end

-- A race row: + the BINGO pill and the raider's card as a 5x5 dot map.
local function CreateRaceRow(parent)
    local r = CreateListRow(parent, 24, { rank = true, class = true })
    r.map = CreateFrame("Frame", nil, r)
    r.map:SetSize(19, 19)
    r.map:SetPoint("RIGHT", -30, 0)
    r.dots = {}
    for i = 1, 25 do
        local d = r.map:CreateTexture(nil, "ARTWORK")
        d:SetSize(3, 3)
        d:SetPoint("TOPLEFT", ((i - 1) % 5) * 4, -floor((i - 1) / 5) * 4)
        r.dots[i] = d
    end
    r.pill = ns.UI:CreatePill(r, 12)
    r.pill:SetPoint("RIGHT", r.map, "LEFT", -6, 0)
    r.pill:Hide()
    r.left:SetPoint("RIGHT", r.pill, "LEFT", -4, 0)
    return r
end

local function RefreshRace(g)
    local Bingo = ns.Bingo
    local race = g and Bingo:GetRace() or {}
    local me = Util.PlayerKey()
    local shown = {}
    for i = 1, min(#race, RACE_ROWS) do shown[i] = race[i] end
    if #race > RACE_ROWS then
        for i = RACE_ROWS + 1, #race do
            if race[i].key == me then shown[RACE_ROWS] = race[i] end
        end
    end
    local winnerAt = {}
    for i, k in ipairs(g and g.winners or {}) do winnerAt[k] = i end
    for i, row in ipairs(raceRows) do
        local r = shown[i]
        if r then
            local pos = i
            for j, x in ipairs(race) do if x == r then pos = j end end
            row.rank:SetText(pos)
            ns.UI:ClassIcon(row.class, ns.UI:ClassOf(r.key))
            row.left:SetText(KeyText(r.key))
            row.right:SetText(r.points)
            if r.lines > 0 then
                row.pill:Set(r.lines > 1 and ("BINGO x" .. r.lines) or "BINGO", "rank")
                row.pill:Show()
            else
                row.pill:Hide()
            end
            local marks = Bingo:GetMarks(r.key) or {}
            local _, _, onLine = ns.BingoCard.Analyze(marks)
            for cell, d in ipairs(row.dots) do
                if onLine[cell] then d:SetColorTexture(S:Alpha("GOLD", 1))
                elseif marks[cell] then d:SetColorTexture(0.72, 0.65, 0.42, 1)
                else d:SetColorTexture(0.17, 0.18, 0.2, 1) end
            end
            row:SetYou(r.key == me)
            local tip = { Util.ShortName(r.key, true), string.format("%d points  \194\183  %d/25 marked  \194\183  %d line%s",
                r.points, r.marked, r.lines, r.lines == 1 and "" or "s") }
            if winnerAt[r.key] then
                tip[#tip + 1] = { winnerAt[r.key] == 1 and "First BINGO of the game!" or ("BINGO #" .. winnerAt[r.key]),
                    GOLD[1], GOLD[2], GOLD[3] }
            end
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    raceEmpty:SetShown(#shown == 0)
    raceHead:SetRight(#race > 0 and (#race .. " playing") or "")
end

local function RefreshFeed(g)
    local feed = g and ns.Bingo:GetFeed() or {}
    for i, row in ipairs(feedRows) do
        local e = feed[i]
        local sq = e and Squares():Get(e.id)
        if sq then
            local qual = Q(sq.q)
            row.qi:SetSquare(sq)
            row.left:SetText(LinkText(sq) .. (e.who and ("  " .. WhoText(e.who)) or ""))
            row.right:SetText(S:Hex(qual.color) .. "+" .. qual.points .. "|r")
            local tip = { { sq.title, qual.color[1], qual.color[2], qual.color[3] }, { sq.text, 1, 1, 1, wrap = true } }
            if e.who then tip[#tip + 1] = "Set off by " .. e.who end
            tip[#tip + 1] = Grey("Marked at " .. date("%H:%M", e.t))
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    feedEmpty:SetShown(#feed == 0)
end

local function CreateDauberBar(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(SIDE_W, 24)
    local label = ns.UI:Text(f, "caps", "SUB")
    label:SetText("DAUBER")
    label:SetPoint("LEFT", 2, 0)
    dauberBtns = {}
    for i = 1, 8 do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(20, 20)
        b:SetPoint("LEFT", 58 + (i - 1) * 21, 0)
        b.sel = b:CreateTexture(nil, "BACKGROUND")
        b.sel:SetPoint("TOPLEFT", -1, 1)
        b.sel:SetPoint("BOTTOMRIGHT", 1, -1)
        b.sel:SetColorTexture(S:Alpha("GOLD", 0.18))
        b.selEdge = CreateFrame("Frame", nil, b)
        b.selEdge:SetPoint("TOPLEFT", -1, 1)
        b.selEdge:SetPoint("BOTTOMRIGHT", 1, -1)
        ns.UI:SetEdges(b.selEdge, S:Alpha("GOLD", 0.8))
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

---------------------------------------------------------------------------
-- The Codex view
---------------------------------------------------------------------------

local function LadderRows()
    local rows = {}
    for key, r in pairs(ns.Bingo:GetSeason()) do
        if type(r) == "table" then
            rows[#rows + 1] = { key = key, p = tonumber(r.points) or 0, b = tonumber(r.bingos) or 0,
                l = tonumber(r.legendaries) or 0, f = tonumber(r.firsts) or 0, x = tonumber(r.blackouts) or 0 }
        end
    end
    table.sort(rows, function(a, b)
        if a.p ~= b.p then return a.p > b.p end
        if a.b ~= b.b then return a.b > b.b end
        return a.key < b.key
    end)
    return rows
end

local function RefreshLadder()
    local rows = LadderRows()
    local me = Util.PlayerKey()
    for i, row in ipairs(ladderRows) do
        local r = rows[i]
        if r then
            local medal = i == 1 and "ffd100" or i == 2 and "c0c0c8" or i == 3 and "cd7f32" or "8a8a8a"
            row.rank:SetText("|cff" .. medal .. i .. "|r")
            ns.UI:ClassIcon(row.class, ns.UI:ClassOf(r.key))
            row.left:SetText(KeyText(r.key))
            row.bingos:SetText(r.b)
            row.legs:SetText(r.l > 0 and r.l or "")
            row.right:SetText(r.p)
            row:SetYou(r.key == me)
            local tip = { Util.ShortName(r.key, true), string.format("%d points  \194\183  %d bingo%s", r.p, r.b, r.b == 1 and "" or "s") }
            if r.l > 0 then tip[#tip + 1] = { r.l .. " legendary square" .. (r.l == 1 and "" or "s") .. " went off", 1, 0.5, 0 } end
            if r.f > 0 then tip[#tip + 1] = { r.f .. " first BINGO" .. (r.f == 1 and "" or "s") .. " of the game", 0.2, 1, 0.6 } end
            if r.x > 0 then tip[#tip + 1] = { r.x .. " blackout" .. (r.x == 1 and "" or "s"), 1, 0.5, 0 } end
            row.tip = tip
            row:Show()
        else
            row:Hide()
        end
    end
    ladderEmpty:SetShown(#rows == 0)
    ladderHead:SetRight(ns.Bingo:GamesPlayed() .. " games")
end

local function RefreshWitnessed()
    local codexData = ns.Bingo:GetCodex()
    local list, total = {}, 0
    for _, sq in ipairs(Squares().list) do
        if sq.q == "l" then
            total = total + 1
            local e = codexData[sq.id]
            if type(e) == "table" then list[#list + 1] = { sq = sq, e = e } end
        end
    end
    table.sort(list, function(a, b) return (tonumber(a.e.t) or 0) > (tonumber(b.e.t) or 0) end)
    for i, row in ipairs(witnessRows) do
        local w = list[i]
        if w then
            row.qi:SetSquare(w.sq)
            local parts = {}
            if w.e.who then parts[#parts + 1] = WhoText(w.e.who) end
            if w.e.raid then parts[#parts + 1] = ns.ItemDB:RaidShort(w.e.raid) or w.e.raid end
            if w.e.t then parts[#parts + 1] = date("%b %d", w.e.t) end
            row.left:SetText(S:Hex(Q("l").color) .. w.sq.title .. "|r")
            row.sub:SetText(table.concat(parts, "  \194\183  "))
            row.right:SetText("")
            row.tip = { { w.sq.title, 1, 0.5, 0 }, { w.sq.text, 1, 1, 1, wrap = true },
                Grey("First witnessed " .. date("%d %b %Y, %H:%M", w.e.t or time())) }
            row:Show()
        else
            row:Hide()
        end
    end
    witnessEmpty:SetShown(#list == 0)
    witnessHead:SetRight(#list .. " of " .. total)
end

local function CodexTip(sq, e)
    local qual = Q(sq.q)
    local tip = { { e and sq.title or "???", qual.color[1], qual.color[2], qual.color[3] },
        Grey(string.format("%s  \194\183  %d point%s", qual.name, qual.points, qual.points == 1 and "" or "s")),
        { sq.text, 1, 1, 1, wrap = true } }
    if sq.raid then tip[#tip + 1] = { (RaidName(sq.raid) or sq.raid) .. " deck", 0.5, 0.75, 1 } end
    if e then
        local parts = { "First seen " .. date("%d %b", e.t or time()) }
        if e.who then parts[#parts + 1] = e.who end
        if e.raid then parts[#parts + 1] = RaidName(e.raid) or e.raid end
        tip[#tip + 1] = { table.concat(parts, "  \194\183  "), 0.2, 1, 0.6 }
        local seen = SeenText(sq.id)
        if seen then tip[#tip + 1] = Grey(seen) end
    else
        tip[#tip + 1] = Grey("Not seen yet. It shows here once it happens in a game you play.", true)
    end
    return tip
end

local function LayoutCodexGrid(width)
    local perRow = max(1, floor((width + CODEX_GAP) / (CODEX_ICON + 4 + CODEX_GAP)))
    local step = CODEX_ICON + 4 + CODEX_GAP
    local y = 0
    for _, grp in ipairs(codexGroups) do
        grp.head:ClearAllPoints()
        grp.head:SetPoint("TOPLEFT", grp.host, "TOPLEFT", 0, -y)
        grp.count:ClearAllPoints()
        grp.count:SetPoint("TOPRIGHT", grp.host, "TOPRIGHT", 0, -y)
        y = y + 15
        for k, cell in ipairs(grp.cells) do
            local col, row = (k - 1) % perRow, floor((k - 1) / perRow)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", grp.host, "TOPLEFT", col * step + 2, -(y + row * step + 2))
        end
        y = y + ceil(#grp.cells / perRow) * step + 4
    end
end

local function RefreshCodex()
    RefreshLadder()
    RefreshWitnessed()
    local codexData = ns.Bingo:GetCodex()
    local found, total = 0, 0
    for _, grp in ipairs(codexGroups) do
        local n = 0
        for _, cell in ipairs(grp.cells) do
            local e = codexData[cell.sq.id]
            e = type(e) == "table" and e or nil
            cell.qi:SetSquare(cell.sq, not e)
            cell.tip = CodexTip(cell.sq, e)
            if e then n = n + 1 end
        end
        grp.count:SetText(n .. " / " .. #grp.cells)
        found, total = found + n, total + #grp.cells
    end
    codexHead:SetRight(found .. " of " .. total .. " discovered")
    codexBar:Set(total > 0 and found / total or 0)
end

local function CreateCodexView(parent)
    local f = CreateFrame("Frame", nil, parent)
    -- left: the season ladder and the legendaries witnessed
    f.left = ns.UI:CreateCard(f, { tone = "inset" })
    local L = f.left
    ladderHead = ns.UI:CreateSectionHeader(L, "Season", { style = "caps" })
    ladderHead:SetPoint("TOPLEFT", 10, -8)
    ladderHead:SetPoint("TOPRIGHT", -10, -8)
    local cols = CreateFrame("Frame", nil, L)
    cols:SetHeight(12)
    cols:SetPoint("TOPLEFT", ladderHead, "BOTTOMLEFT", 0, -2)
    cols:SetPoint("TOPRIGHT", ladderHead, "BOTTOMRIGHT", 0, -2)
    local function ColHead(text, x)
        local fs = ns.UI:Text(cols, "caps", "DIM", { justify = "RIGHT" })
        fs:SetText(text)
        fs:SetPoint("RIGHT", x, 0)
        return fs
    end
    ColHead("PTS", -6)
    local star = ns.UI:CreateStar(cols, 11)
    star:SetLit(true)
    star:SetPoint("RIGHT", -43, 0)
    ColHead("BINGO", -78)
    ladderRows = {}
    for i = 1, LADDER_ROWS do
        local r = CreateListRow(L, 22, { rank = true, class = true })
        r:SetPoint("TOPLEFT", cols, "BOTTOMLEFT", 0, -2 - (i - 1) * 22)
        r:SetPoint("TOPRIGHT", cols, "BOTTOMRIGHT", 0, -2 - (i - 1) * 22)
        r:SetStripe(i)
        r.legs = ns.UI:Text(r, "small", { 1, 0.5, 0 }, { justify = "RIGHT" })
        r.legs:SetPoint("RIGHT", -44, 0)
        r.bingos = ns.UI:Text(r, "small", "TEXT", { justify = "RIGHT" })
        r.bingos:SetPoint("RIGHT", -80, 0)
        r.left:SetPoint("RIGHT", r.bingos, "LEFT", -20, 0)
        ladderRows[i] = r
    end
    ladderEmpty = ns.UI:Text(L, "body", "DIM")
    ladderEmpty:SetText("No points yet. They come with the first game.")
    ladderEmpty:SetPoint("TOPLEFT", cols, "BOTTOMLEFT", 4, -8)
    witnessHead = ns.UI:CreateSectionHeader(L, "Legendaries witnessed", { style = "caps" })
    witnessHead:SetPoint("TOPLEFT", cols, "BOTTOMLEFT", 0, -(LADDER_ROWS * 22 + 14))
    witnessHead:SetPoint("TOPRIGHT", cols, "BOTTOMRIGHT", 0, -(LADDER_ROWS * 22 + 14))
    witnessRows = {}
    for i = 1, WITNESS_ROWS do
        local r = CreateListRow(L, 32, { qi = true })
        r:SetPoint("TOPLEFT", witnessHead, "BOTTOMLEFT", 0, -2 - (i - 1) * 32)
        r:SetPoint("TOPRIGHT", witnessHead, "BOTTOMRIGHT", 0, -2 - (i - 1) * 32)
        r.left:ClearAllPoints()
        r.left:SetPoint("TOPLEFT", 36, -4)
        r.left:SetPoint("RIGHT", -6, 0)
        r.sub = ns.UI:Text(r, "small", "SUB")
        r.sub:SetPoint("TOPLEFT", r.left, "BOTTOMLEFT", 0, -3)
        r.sub:SetPoint("RIGHT", -6, 0)
        r.sub:SetWordWrap(false)
        witnessRows[i] = r
    end
    witnessEmpty = ns.UI:Text(L, "body", "DIM", { wrap = true })
    witnessEmpty:SetText("None yet. Most seasons never see one.")
    witnessEmpty:SetPoint("TOPLEFT", witnessHead, "BOTTOMLEFT", 4, -8)
    witnessEmpty:SetPoint("RIGHT", L, "RIGHT", -10, 0)

    -- right: every square of the set
    f.right = ns.UI:CreateCard(f, { tone = "inset" })
    local R = f.right
    codexHead = ns.UI:CreateSectionHeader(R, "The Codex", { style = "caps" })
    codexHead:SetPoint("TOPLEFT", 12, -8)
    codexHead:SetPoint("TOPRIGHT", -12, -8)
    codexBar = ns.UI:CreateProgressBar(R, { height = 3, gradient = { S.C.GOLD, { 1, 0.5, 0, 1 } } })
    codexBar:SetPoint("TOPLEFT", codexHead, "BOTTOMLEFT", 0, -3)
    codexBar:SetPoint("TOPRIGHT", codexHead, "BOTTOMRIGHT", 0, -3)
    local host = CreateFrame("Frame", nil, R)
    host:SetPoint("TOPLEFT", codexBar, "BOTTOMLEFT", 0, -9)
    host:SetPoint("BOTTOMRIGHT", R, "BOTTOMRIGHT", -12, 8)
    codexGroups, codexCells = {}, {}
    for _, q in ipairs(Squares().ORDER) do
        local grp = { host = host, cells = {} }
        grp.head = ns.UI:Text(host, "caps", Q(q).color)
        grp.head:SetText(Q(q).name:upper())
        grp.count = ns.UI:Text(host, "caps", "DIM", { justify = "RIGHT" })
        for _, sq in ipairs(Squares().list) do
            if sq.q == q then
                local cell = CreateFrame("Frame", nil, host)
                cell:SetSize(CODEX_ICON, CODEX_ICON)
                cell.sq = sq
                cell.qi = CreateQualityIcon(cell, CODEX_ICON)
                cell.qi:SetAllPoints()
                cell:EnableMouse(true)
                cell:SetScript("OnEnter", function(self) ns.UI:SetTextTooltip(self, self.tip or { sq.title }) end)
                cell:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
                grp.cells[#grp.cells + 1] = cell
                codexCells[#codexCells + 1] = cell
            end
        end
        codexGroups[#codexGroups + 1] = grp
    end
    f.host = host
    f:Hide()
    return f
end

---------------------------------------------------------------------------
-- The legendary takeover (in the panel) and the moments' toasts
---------------------------------------------------------------------------

local function CreateTakeover(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetAllPoints()
    f:SetFrameLevel(parent:GetFrameLevel() + 40)
    f:RegisterForClicks("AnyUp")
    f.veil = ns.UI:Fill(f, { 0.02, 0.016, 0.012, 0.88 }, "BACKGROUND", 0)
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    f.glow:SetTexture(RADIAL)
    f.glow:SetBlendMode("ADD")
    f.glow:SetVertexColor(1, 0.45, 0, 0.42)
    f.glow:SetSize(560, 460)
    -- turning rays (the legendary toast's starburst, large) and the burst itself
    f.rays = f:CreateTexture(nil, "BORDER")
    f.rays:SetTexture(LEGENDARY_TOAST)
    f.rays:SetTexCoord(BURST[1], BURST[2], BURST[3], BURST[4])
    f.rays:SetBlendMode("ADD")
    f.rays:SetVertexColor(1, 0.6, 0.2, 0.55)
    f.rays:SetSize(520, 520)
    local spin = f.rays:CreateAnimationGroup()
    spin:SetLooping("REPEAT")
    local rot = spin:CreateAnimation("Rotation")
    rot:SetDegrees(-360)
    rot:SetDuration(40)
    f.spin = spin
    f.burst = f:CreateTexture(nil, "ARTWORK", nil, -1)
    f.burst:SetTexture(LEGENDARY_TOAST)
    f.burst:SetTexCoord(BURST[1], BURST[2], BURST[3], BURST[4])
    f.burst:SetBlendMode("ADD")
    f.burst:SetSize(300, 310)

    -- the card that flew out of the square
    local c = CreateFrame("Frame", nil, f)
    c:SetSize(180, 252)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    ns.UI:Gradient(c.bg, "VERTICAL", { 0.07, 0.05, 0.035, 0.98 }, { 0.16, 0.10, 0.05, 0.98 })
    c.wash = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.wash:SetTexture(RADIAL)
    c.wash:SetBlendMode("ADD")
    c.wash:SetVertexColor(1, 0.5, 0, 0.35)
    c.wash:SetSize(220, 170)
    c.wash:SetPoint("CENTER", c, "TOP", 0, -70)
    ns.UI:AddEdges(c, "BORDER")
    ns.UI:SetEdgeColor(c, 1, 0.55, 0.1, 0.95)
    ns.UI:SoftShadow(c, 18, 0.6, 6, 0)
    c.kicker = ns.UI:Text(c, "caps", { 1, 0.6, 0.18 }, { justify = "CENTER" })
    c.kicker:SetText("L E G E N D A R Y")
    c.kicker:SetPoint("TOP", 0, -12)
    c.qi = CreateQualityIcon(c, 50)
    c.qi:SetPoint("TOP", 0, -36)
    c.twinkles = CreateTwinkles(c, 2)
    c.twinkles[1]:SetPoint("CENTER", c.qi, "TOPLEFT", 0, 0)
    c.twinkles[2]:SetPoint("CENTER", c.qi, "BOTTOMRIGHT", 6, 18)
    c.title = ns.UI:Text(c, "page", { 1, 0.85, 0.63 }, { justify = "CENTER" })
    c.title:SetPoint("TOP", c.qi, "BOTTOM", 0, -14)
    c.title:SetWidth(166)
    c.rule = ns.UI:Text(c, "small", { 0.85, 0.79, 0.66 }, { justify = "CENTER", wrap = true })
    c.rule:SetPoint("TOP", c.title, "BOTTOM", 0, -6)
    c.rule:SetWidth(152)
    c.lineL = c:CreateTexture(nil, "ARTWORK")
    c.lineL:SetHeight(1)
    c.lineL:SetPoint("TOPLEFT", 30, -170)
    c.lineL:SetPoint("TOPRIGHT", c, "TOP", 0, -170)
    ns.UI:GradientRGBA(c.lineL, "HORIZONTAL", 1, 0.5, 0, 0, 1, 0.5, 0, 0.9)
    c.lineR = c:CreateTexture(nil, "ARTWORK")
    c.lineR:SetHeight(1)
    c.lineR:SetPoint("TOPLEFT", c, "TOP", 0, -170)
    c.lineR:SetPoint("TOPRIGHT", -30, -170)
    ns.UI:GradientRGBA(c.lineR, "HORIZONTAL", 1, 0.5, 0, 0.9, 1, 0.5, 0, 0)
    c.who = ns.UI:Text(c, "small", "TEXT", { justify = "CENTER" })
    c.who:SetPoint("TOP", 0, -178)
    c.who:SetWidth(170)
    c.points = ns.UI:Text(c, "hero", "GOLD", { justify = "CENTER" })
    c.points:SetPoint("TOP", c.who, "BOTTOM", 0, -6)
    c.holders = ns.UI:Text(c, "caps", "SUB", { justify = "CENTER" })
    c.holders:SetPoint("TOP", c.points, "BOTTOM", 0, -3)
    c.pop = c:CreateAnimationGroup()
    local grow = c.pop:CreateAnimation("Scale")
    SetScaleAnim(grow, 0.55, 1)
    grow:SetDuration(0.45)
    grow:SetSmoothing("OUT")
    if grow.SetOrigin then grow:SetOrigin("CENTER", 0, 0) end
    f.card = c

    -- the client's legendary toast across the top
    local t = CreateFrame("Frame", nil, f)
    t:SetSize(302, 117)
    t.art = t:CreateTexture(nil, "ARTWORK")
    t.art:SetAllPoints()
    t.art:SetTexture(LEGENDARY_TOAST)
    t.art:SetTexCoord(DRAGON[1], DRAGON[2], DRAGON[3], DRAGON[4])
    t.icon = t:CreateTexture(nil, "BORDER")
    t.icon:SetSize(47, 47)
    t.icon:SetPoint("TOPLEFT", 53, -34)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    t.kicker = ns.UI:Text(t, "caps", { 1, 0.6, 0.18 })
    t.kicker:SetPoint("TOPLEFT", 118, -30)
    t.kicker:SetText("LEGENDARY MOMENT")
    t.title = ns.UI:Text(t, "title", { 1, 0.85, 0.63 })
    t.title:SetPoint("TOPLEFT", 118, -44)
    t.title:SetWidth(170)
    t.sub = ns.UI:Text(t, "small", "SUB")
    t.sub:SetPoint("TOPLEFT", 118, -64)
    t.sub:SetWidth(172)
    t.sub:SetWordWrap(false)
    f.toast = t

    -- Fated: the square it also daubed, lit over the veil
    local fate = CreateFrame("Frame", nil, f)
    fate:SetFrameLevel(f:GetFrameLevel() + 4)
    fate.glow = fate:CreateTexture(nil, "BACKGROUND")
    fate.glow:SetTexture(RADIAL)
    fate.glow:SetBlendMode("ADD")
    fate.glow:SetVertexColor(1, 0.7, 0.1, 0.38)
    fate.glow:SetPoint("TOPLEFT", -26, 26)
    fate.glow:SetPoint("BOTTOMRIGHT", 26, -26)
    ns.UI:SetEdges(fate, S:Alpha("GOLD", 1))
    fate.label = ns.UI:Text(f, "caps", "GOLD", { justify = "RIGHT" })
    fate.label:SetText("F A T E D")
    fate.text = ns.UI:Text(f, "small", "TEXT", { justify = "RIGHT", wrap = true })
    fate.text:SetWidth(170)
    f.fate = fate

    f:SetScript("OnClick", function() BingoUI:EndTakeover() end)
    f:Hide()
    return f
end

function BingoUI:EndTakeover(instant)
    local f = takeover
    if not f or not f:IsShown() then return end
    local function Gone()
        f:Hide()
        f.spin:Stop()
        local pending = f.pendingSlam
        f.pendingSlam = nil
        if pending and not instant and slam then slam:Slam(pending[1], pending[2], pending[3]) end
    end
    if instant then
        ns.UI:StopTween("bingoTakeover")
        Gone()
        return
    end
    ns.UI:Tween("bingoTakeover", 0.4, function(e)
        f:SetAlpha(1 - e)
        if e >= 1 then Gone() end
    end)
end

-- Shows the takeover for legendary square id (who set it off).
function BingoUI:ShowTakeover(id, who)
    local sq = Squares():Get(id)
    if not sq or not takeover or not panel or not panel:IsVisible() then return false end
    local f = takeover
    local Bingo = ns.Bingo
    local me = Util.PlayerKey()
    local W, H = panel:GetWidth() or 0, panel:GetHeight() or 0
    if W < 300 or H < 300 then W, H = FALLBACK_W, FALLBACK_H end
    local cx, cy = (W - SIDE_W) / 2 - 20, -(HERO_H + (H - HERO_H) / 2) + 6
    f.glow:ClearAllPoints()
    f.glow:SetPoint("CENTER", panel, "TOPLEFT", cx, cy)
    f.rays:ClearAllPoints()
    f.rays:SetPoint("CENTER", panel, "TOPLEFT", cx, cy)
    f.burst:ClearAllPoints()
    f.burst:SetPoint("CENTER", panel, "TOPLEFT", cx, cy)
    local c = f.card
    c:ClearAllPoints()
    c:SetPoint("CENTER", panel, "TOPLEFT", cx, cy - 4)
    c.qi:SetSquare(sq)
    c.title:SetText(sq.title)
    c.rule:SetText(sq.text)
    c.who:SetText(who and (WhoText(who)) or S:Wrap("SUB", "the raid"))
    c.points:SetText("+" .. Q("l").points)
    local holders = Bingo:CountHolders(id)
    c.holders:SetText(holders > 0 and string.format("TO THE %d RAIDER%s HOLDING IT", holders, holders == 1 and "" or "S")
        or "NOBODY HELD IT TONIGHT")
    f.toast:ClearAllPoints()
    f.toast:SetPoint("BOTTOM", c, "TOP", 0, 2)
    f.toast.icon:SetTexture(Squares():Icon(sq))
    f.toast.title:SetText(sq.title)
    local seenParts = {}
    local seen = SeenText(id)
    if seen then seenParts[#seenParts + 1] = seen end
    local e = Bingo:GetCodex()[id]
    if type(e) == "table" and tonumber(e.n) == 1 then seenParts[#seenParts + 1] = "first time" end
    f.toast.sub:SetText(table.concat(seenParts, "  \194\183  "))
    -- Fated (my card held it): light the cell it daubed
    local fate = f.fate
    local fated = Bingo:GetFated(me)
    local myCard = Bingo:GetMyCard()
    local mine = false
    for _, cid in ipairs(myCard or {}) do if cid == id then mine = true end end
    if mine and fated and cells[fated] then
        local fsq = Squares():Get(myCard[fated])
        fate:ClearAllPoints()
        fate:SetAllPoints(cells[fated])
        fate:Show()
        fate.label:ClearAllPoints()
        fate.label:SetPoint("BOTTOMRIGHT", cells[fated], "BOTTOMLEFT", -12, 26)
        fate.text:ClearAllPoints()
        fate.text:SetPoint("TOPRIGHT", fate.label, "BOTTOMRIGHT", 0, -3)
        fate.text:SetText("Your legendary also daubs your best gap: " .. (fsq and LinkText(fsq) or "a square"))
        fate.label:Show()
        fate.text:Show()
    else
        fate:Hide()
        fate.label:Hide()
        fate.text:Hide()
    end
    f:SetAlpha(0)
    f:Show()
    f.spin:Play()
    c.pop:Stop()
    c.pop:Play()
    ShowTwinkles(c.twinkles, true)
    ns.UI:Tween("bingoTakeover", 0.35, function(k) f:SetAlpha(k) end)
    PlaySoundKit(MOMENT_SOUND.l, 8959)
    f.shownAt = GetTime()
    C_Timer.After(TAKEOVER_TIME, function()
        if f:IsShown() and f.shownAt and GetTime() - f.shownAt >= TAKEOVER_TIME - 0.05 then BingoUI:EndTakeover() end
    end)
    return true
end

-- A moment's toast on screen: rare (only my squares), epic (everyone in the game), legendary (when the panel isn't
-- open to show the takeover).
function BingoUI:ToastMoment(id, who)
    local sq = Squares():Get(id)
    if not sq then return nil end
    local qual = Q(sq.q)
    local holders = ns.Bingo:CountHolders(id)
    local text = sq.text
    if who then text = WhoText(who) .. "  \194\183  " .. text end
    local o = {
        key = "bingo:" .. id,
        kind = qual.color,
        kicker = qual.name:upper() .. " MOMENT",
        title = sq.title,
        text = text,
        icon = Squares():Icon(sq),
        sound = MOMENT_SOUND[sq.q],
        duration = sq.q == "l" and 10 or sq.q == "e" and 7 or 5,
        combat = sq.q == "r" and false or nil,
        onClick = function() ns.Games:Open("bingo") end,
    }
    if sq.q ~= "r" and holders > 0 then
        o.text = o.text .. "\n" .. S:Wrap("GOLD", string.format("+%d to %d raider%s", qual.points, holders, holders == 1 and "" or "s"))
    end
    if sq.q == "l" then
        -- the legendary toast's starburst behind the icon
        o.onFill = function(t)
            local burst = t.slot.bingoBurst
            if not burst then
                burst = t.slot:CreateTexture(nil, "BACKGROUND")
                burst:SetTexture(LEGENDARY_TOAST)
                burst:SetTexCoord(BURST[1], BURST[2], BURST[3], BURST[4])
                burst:SetBlendMode("ADD")
                burst:SetVertexColor(1, 0.6, 0.2, 0.7)
                t.slot.bingoBurst = burst
            end
            burst:ClearAllPoints()
            burst:SetSize(90, 90)
            burst:SetPoint("CENTER", t, "LEFT", 26, 0)
            burst:Show()
        end
    end
    return ns.UI:Toast(o)
end

-- Demo mode: how a square of quality q arrives, on the made-up game (nothing is marked, saved or sent).
function BingoUI:DemoMoment(q)
    local Bingo = ns.Bingo
    local me = Util.PlayerKey()
    local card = Bingo:GetMyCard() or {}
    local pick, cell
    for i, id in ipairs(card) do
        local sq = Squares():Get(id)
        if sq and sq.q == q and not (Bingo:GetGame() and Bingo:GetGame().hits[id]) then pick, cell = id, i break end
    end
    if not pick then
        for _, sq in ipairs(Squares().list) do
            if sq.q == q then pick = sq.id break end
        end
    end
    if not pick then return end
    local who = ({ "Lainatukka", "Saltykim", "Dyrma", "Fazerblue", "Victhar" })[(#pick % 5) + 1]
    if q == "l" then
        if not self:ShowTakeover(pick, who) then self:ToastMoment(pick, who) end
    elseif q == "e" or q == "r" then
        self:ToastMoment(pick, who)
    end
    if cell and cells and q ~= "l" then
        local col = q == "c" and { 1, 0.9, 0.55 } or Q(q).color
        StampIn(cells[cell], 0, col)
        cells[cell].stamp:SetTexture(RAID_ICON .. Dauber())
        cells[cell].stamp:Show()
        C_Timer.After(1.2, function() BingoUI:Refresh() end)
    end
    return pick
end

local function OnMoment(id, who, mine)
    local sq = Squares():Get(id)
    if not sq then return end
    if sq.q == "l" then
        if not BingoUI:ShowTakeover(id, who) then BingoUI:ToastMoment(id, who) end
    elseif sq.q == "e" then
        BingoUI:ToastMoment(id, who)
    elseif sq.q == "r" and mine then
        BingoUI:ToastMoment(id, who)
    end
end

---------------------------------------------------------------------------
-- Layout: everything from the panel's size
---------------------------------------------------------------------------

-- The numbers sit left of the banner's action.
local function PlaceStats()
    local act = hero.actions and hero.actions[1]
    stats:ClearAllPoints()
    stats:SetPoint("RIGHT", hero, "RIGHT", -((act and act:IsShown() and act:GetWidth() or 0) + 28), 2)
end

local function Layout()
    if not panel then return end
    local W, H = panel:GetWidth() or 0, panel:GetHeight() or 0
    if W < 300 or H < 300 then W, H = FALLBACK_W, FALLBACK_H end
    hero:ClearAllPoints()
    hero:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    hero:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    hero:SetHeight(HERO_H)
    local bodyH = H - HERO_H - 2 * PAD
    local cardW = W - 2 * PAD - GAP - SIDE_W
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(HERO_H + PAD))
    card:SetSize(cardW, bodyH)
    local gw = cardW - 2 * CARD_PAD
    local gh = bodyH - 2 * CARD_PAD - LETTER_H
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
    end
    for col, fs in ipairs(card.letters) do
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOM", grid, "TOPLEFT", (col - 1) * (cw + CELL_GAP) + cw / 2, 4)
    end
    side:ClearAllPoints()
    side:SetPoint("TOPLEFT", card, "TOPRIGHT", GAP, 0)
    side:SetSize(SIDE_W, bodyH)
    codex:ClearAllPoints()
    codex:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(HERO_H + PAD))
    codex:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PAD, PAD)
    codex.left:ClearAllPoints()
    codex.left:SetPoint("TOPLEFT")
    codex.left:SetPoint("BOTTOMLEFT")
    codex.left:SetWidth(270)
    codex.right:ClearAllPoints()
    codex.right:SetPoint("TOPLEFT", codex.left, "TOPRIGHT", GAP, 0)
    codex.right:SetPoint("BOTTOMRIGHT")
    LayoutCodexGrid(W - 2 * PAD - 270 - GAP - 24)
    PlaceStats()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function LineName(li)
    local kind, idx = ns.BingoCard.LINE_KIND[li], ns.BingoCard.LINE_INDEX[li]
    if kind == "row" then return "row " .. idx end
    if kind == "col" then return "column " .. LETTERS[idx] end
    return "a diagonal"
end

local function PaintStat(s, value, label, color)
    s.value:SetText(value)
    s.value:SetTextColor(S:Color(color or "TEXT"))
    s.label:SetText(label)
    s:Show()
end

local function RefreshHero(g, active, marked, lines, nearLines)
    local Bingo = ns.Bingo
    local raid = g and Bingo:GetRaid()
    local here = active and ns.GamesUI and ns.GamesUI.InstanceHere and ns.GamesUI:InstanceHere()
    local art = raid or here or "kara"
    if hero.artKey ~= art then hero:SetArt(art) end
    if active then
        hero:SetPill("live", "LIVE")
        hero:SetKicker(raid and ((RaidName(raid) or raid) .. " deck") or "Core deck")
    elseif g then
        hero:SetPill("ended", "FINISHED")
        hero:SetKicker(raid and ((RaidName(raid) or raid) .. " deck") or "Core deck")
    else
        hero:SetPill(nil, nil)
        hero:SetKicker("Raid night")
    end
    if not g then
        hero:SetSub("No game yet. The raid leader starts one with " .. S:Wrap("GOLD", "/dz bingo start") .. ".")
    else
        local parts = { "host " .. Util.ShortName(g.host or "?", true) }
        if g.started then parts[#parts + 1] = "started " .. date("%H:%M", g.started) end
        if active and #nearLines == 1 then
            parts[#parts + 1] = S:Wrap("GOLD", LineName(nearLines[1]) .. " is one away")
        elseif active and #nearLines > 1 then
            parts[#parts + 1] = S:Wrap("GOLD", #nearLines .. " lines are one away")
        end
        hero:SetSub(table.concat(parts, "  \194\183  "))
    end
    local actions = {}
    if g and g.demo then
        hero:SetKicker("Demo  \194\183  " .. ((RaidName(raid) or raid or "Core") .. " deck"))
        actions[#actions + 1] = { text = "Try a moment", menu = function(root)
            root:CreateTitle("How each quality arrives")
            for _, q in ipairs(Squares().ORDER) do
                root:CreateButton(S:Hex(Q(q).color) .. Q(q).name .. "|r", function() BingoUI:DemoMoment(q) end)
            end
        end }
    elseif Bingo:CanStart() and not active then
        actions[#actions + 1] = { text = "Start game", kind = "primary", onClick = function() Bingo:Start() end }
    elseif active and Bingo:IsHost() then
        actions[#actions + 1] = { text = "End game", onClick = function() Bingo:Stop() end }
    end
    hero:SetActions(actions)
    startBtn = actions[1] and actions[1].text == "Start game" and hero.actions[1] or nil
    stopBtn = actions[1] and actions[1].text == "End game" and hero.actions[1] or nil
    if g then
        PaintStat(stats[1], tostring(Bingo:GetPoints(Util.PlayerKey())), "POINTS", "GOLD")
        PaintStat(stats[2], tostring(lines), lines == 1 and "BINGO" or "BINGOS", lines > 0 and "GOLD" or "TEXT")
        PaintStat(stats[3], marked .. S:Wrap("DIM", "/25"), "MARKED")
        stats:Show()
    else
        stats:Hide()
    end
    PlaceStats()
end

local function RefreshCard(g, active)
    local Bingo = ns.Bingo
    local me = Util.PlayerKey()
    local cardIds = g and Bingo:GetMyCard()
    local marks = cardIds and Bingo:GetMarks(me) or {}
    local lines, marked, onLine, _, away, count = 0, 0, {}, {}, {}, {}
    if cardIds then lines, marked, onLine, _, away, count = ns.BingoCard.Analyze(marks) end
    local fated = g and Bingo:GetFated(me)
    if card.logo then
        card.logo:SetShown(cardIds == nil)
        grid:SetAlpha(cardIds and 1 or 0.4)
    end

    -- what's new since this card was last on screen
    local v = View()
    if g and v.g ~= g.id then
        v.g, v.hits, v.lines, v.black = g.id, {}, 0, false
    end
    if type(v.hits) ~= "table" then v.hits = {} end
    local newCount = 0

    for i = 1, 25 do
        local id = cardIds and cardIds[i]
        local st = { id = id, sq = id and Squares():Get(id), marked = marks[i] == true, onLine = onLine[i],
            away = away[i], active = active, fated = fated == i }
        if id and id ~= Squares().FREE and not st.sq then st.id = nil end
        if st.sq and st.marked then
            local key = st.fated and ("fated:" .. id) or id
            if not v.hits[key] then
                v.hits[key] = true
                newCount = newCount + 1
                st.isNew, st.delay = true, (newCount - 1) * 0.12
            end
        end
        PaintCell(cells[i], st)
    end

    -- the threads: a line one short (gold, broken at the gap) or full (gold, glowing), only between marked neighbours
    local nearLines = {}
    for li, line in ipairs(ns.BingoCard.LINES) do
        local n = count[li] or 0
        if n == 4 and cardIds then nearLines[#nearLines + 1] = li end
        for k = 1, 4 do
            local t = threads[li][k]
            local on = cardIds and n >= 4 and marks[line[k]] and marks[line[k + 1]]
            t.core:SetShown(on and true or false)
            t.glow:SetShown(on and n == 5 or false)
            if on then t.core:SetColorTexture(S:Alpha("GOLD", n == 5 and 1 or 0.75)) end
        end
    end

    -- the slam, once per new line / blackout (waits until the card is on screen)
    if g and cardIds then
        local delay = newCount > 0 and min(1.5, newCount * 0.12 + 0.2) or 0
        local function Celebrate(text, color, sub)
            if takeover and takeover:IsShown() then
                takeover.pendingSlam = { text, color, sub }     -- (after the takeover: a Fated line lands under it)
            elseif delay > 0 then
                C_Timer.After(delay, function() slam:Slam(text, color, sub) end)
            else
                slam:Slam(text, color, sub)
            end
        end
        if marked >= 25 and not v.black then
            v.black = true
            v.lines = lines
            Celebrate("BLACKOUT!", { 1, 0.5, 0 }, "The whole card!")
        elseif lines > (tonumber(v.lines) or 0) then
            local gained = lines - (tonumber(v.lines) or 0)
            v.lines = lines
            Celebrate(gained > 1 and ("BINGO x" .. gained .. "!") or "BINGO!", GOLD,
                lines > 1 and (lines .. " lines on your card") or nil)
        end
    end
    return marked, lines, nearLines
end

function BingoUI:Refresh()
    if mini then mini:Update() end
    if not panel or not panel:IsVisible() then return end
    local Bingo = ns.Bingo
    local g = Bingo:GetGame()
    local active = Bingo:IsActive()
    local marked, lines, nearLines = RefreshCard(g, active)
    RefreshHero(g, active, marked, lines, nearLines)
    if view == "codex" then
        RefreshCodex()
    else
        RefreshYourLegendary(g)
        RefreshRace(g)
        RefreshFeed(g)
        announceBox:SetChecked(Bingo:GetAnnounce())
        local dauber = Dauber()
        for i, b in ipairs(dauberBtns) do
            b.sel:SetShown(i == dauber)
            b.selEdge:SetShown(i == dauber)
            b.tex:SetAlpha(i == dauber and 1 or 0.4)
        end
    end
end

-- "card" | "codex"
function BingoUI:SetView(key)
    view = key == "codex" and "codex" or "card"
    if not panel then return end
    card:SetShown(view == "card")
    side:SetShown(view == "card")
    codex:SetShown(view == "codex")
    if seg and seg:GetSelected() ~= view then seg:Select(view) end
    if view == "codex" then self:EndTakeover(true) end
    self:Refresh()
end

function BingoUI:GetView() return view end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function CreateStat(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(56, 40)
    s.value = ns.UI:Text(s, "hero", nil, { justify = "CENTER" })
    s.value:SetPoint("TOP", 0, -2)
    s.label = ns.UI:Text(s, "caps", "SUB", { justify = "CENTER" })
    s.label:SetPoint("TOP", s.value, "BOTTOM", 0, -4)
    s:Hide()
    return s
end

local function CreateStats(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(3 * 56 + 2 * 10, 40)
    f:SetFrameLevel(parent:GetFrameLevel() + 5)
    for i = 1, 3 do
        local s = CreateStat(f)
        s:SetPoint("LEFT", (i - 1) * 66, 0)
        f[i] = s
    end
    f:Hide()
    return f
end

local function CreateCardView(parent)
    local f = ns.UI:CreateCard(parent, { tone = "inset" })
    grid = CreateFrame("Frame", nil, f)
    f.letters = {}
    for col, l in ipairs(LETTERS) do
        local fs = ns.UI:Text(f, "title", { 0.79, 0.71, 0.48 }, { justify = "CENTER" })
        fs:SetText(l)
        f.letters[col] = fs
    end
    cells = {}
    for i = 1, 25 do cells[i] = CreateCell(grid, i) end
    for _, c in ipairs(cells) do c.top:SetFrameLevel(grid:GetFrameLevel() + 12) end
    -- with no card yet the game's logo stands over the faded grid, its title screen (art pack 14)
    f.logo = ns.GamesUI and ns.GamesUI.CreateLogo and ns.GamesUI:CreateLogo(f, "bingo", 1.6)
    if f.logo then
        f.logo:SetPoint("CENTER", grid, "CENTER", 0, 8)
        f.logo:SetFrameLevel(grid:GetFrameLevel() + 20)
        f.logo:Hide()
    end
    -- the gold threads: a segment between each pair of neighbours on every line, behind the squares (they show in
    -- the gaps between them)
    threads = {}
    for li, line in ipairs(ns.BingoCard.LINES) do
        threads[li] = {}
        for k = 1, 4 do
            local a, b = cells[line[k]], cells[line[k + 1]]
            local glow = grid:CreateLine(nil, "BACKGROUND")
            glow:SetThickness(9)
            glow:SetColorTexture(S:Alpha("GOLD", 0.22))
            glow:SetStartPoint("CENTER", a)
            glow:SetEndPoint("CENTER", b)
            glow:Hide()
            local core = grid:CreateLine(nil, "ARTWORK")
            core:SetThickness(2)
            core:SetColorTexture(S:Alpha("GOLD", 1))
            core:SetStartPoint("CENTER", a)
            core:SetEndPoint("CENTER", b)
            core:Hide()
            threads[li][k] = { core = core, glow = glow }
        end
    end
    local over = CreateFrame("Frame", nil, grid)
    over:SetAllPoints()
    over:SetFrameLevel(grid:GetFrameLevel() + 20)
    slam = CreateSlam(over)
    return f
end

local function CreateSide(parent)
    local f = CreateFrame("Frame", nil, parent)
    yourLeg = CreateYourLegendary(f)
    yourLeg:SetPoint("TOPLEFT")
    yourLeg:SetPoint("TOPRIGHT")
    raceHead = ns.UI:CreateSectionHeader(f, "Race", { style = "caps" })
    raceHead:SetPoint("TOPLEFT", yourLeg, "BOTTOMLEFT", 0, -10)
    raceHead:SetPoint("TOPRIGHT", yourLeg, "BOTTOMRIGHT", 0, -10)
    raceRows = {}
    for i = 1, RACE_ROWS do
        local r = CreateRaceRow(f)
        r:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 0, -2 - (i - 1) * 24)
        r:SetPoint("TOPRIGHT", raceHead, "BOTTOMRIGHT", 0, -2 - (i - 1) * 24)
        r:SetStripe(i)
        raceRows[i] = r
    end
    raceEmpty = ns.UI:Text(f, "body", "DIM")
    raceEmpty:SetText("No game running.")
    raceEmpty:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 4, -8)
    feedHead = ns.UI:CreateSectionHeader(f, "Moments", { style = "caps", right = "newest first" })
    feedHead:SetPoint("TOPLEFT", raceHead, "BOTTOMLEFT", 0, -(RACE_ROWS * 24 + 10))
    feedHead:SetPoint("TOPRIGHT", raceHead, "BOTTOMRIGHT", 0, -(RACE_ROWS * 24 + 10))
    feedRows = {}
    for i = 1, FEED_ROWS do
        local r = CreateListRow(f, 22, { qi = true })
        r:SetPoint("TOPLEFT", feedHead, "BOTTOMLEFT", 0, -2 - (i - 1) * 22)
        r:SetPoint("TOPRIGHT", feedHead, "BOTTOMRIGHT", 0, -2 - (i - 1) * 22)
        feedRows[i] = r
    end
    feedEmpty = ns.UI:Text(f, "body", "DIM")
    feedEmpty:SetText("Nothing has happened yet.")
    feedEmpty:SetPoint("TOPLEFT", feedHead, "BOTTOMLEFT", 4, -8)
    -- your dauber and the announce switch close the column
    announceBox = ns.UI:CreateCheckbox(f, "Announce bingos in raid chat",
        function() return ns.Bingo:GetAnnounce() end,
        function(on) ns.Bingo:SetAnnounce(on) end)
    announceBox:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", -4, -2)
    dauberBar = CreateDauberBar(f)
    dauberBar:SetPoint("BOTTOMLEFT", announceBox, "TOPLEFT", 4, 2)
    return f
end

function BingoUI:CreatePanel(parent)
    panel = CreateFrame("Frame", nil, parent)

    hero = ns.UI:CreatePageBanner(panel, { size = HERO_H, art = "kara", title = "Council Bingo", kicker = "Raid night",
        width = FALLBACK_W, rightW = function() return (stats and stats:IsShown() and stats:GetWidth() or 0) + 12 end })
    stats = CreateStats(hero)

    card = CreateCardView(panel)
    side = CreateSide(panel)
    codex = CreateCodexView(panel)
    takeover = CreateTakeover(panel)

    -- Card | Codex: on the hub's strip after the game's name (HubUI places panel.stripTool)
    seg = ns.UI:CreateSegments(panel, { { key = "card", label = "Card" }, { key = "codex", label = "Codex" } },
        function(key) BingoUI:SetView(key) end, { look = "pill", h = 20, textSize = "small", selected = "card" })
    panel.stripTool = seg

    Layout()
    panel:SetScript("OnSizeChanged", function() Layout() BingoUI:Refresh() end)
    panel:SetScript("OnShow", function() BingoUI:Refresh() end)
    panel:SetScript("OnHide", function() BingoUI:EndTakeover(true) end)
    panel:SetScript("OnUpdate", function()
        local now = GetTime()
        -- legendary squares: a spark runs round the edge (once every 3 s)
        for i, c in ipairs(cells) do
            if c.legendary and c:IsVisible() then PlaceSpark(c.spark, c, now / 3 + i * 0.13) end
        end
        if yourLeg and yourLeg.hasLegendary and yourLeg:IsVisible() then PlaceSpark(yourLeg.spark, yourLeg, now / 4) end
    end)
    panel.OnGameShown = function() Layout() BingoUI:SetView(view) end
    return panel
end

---------------------------------------------------------------------------
-- Mini counter
---------------------------------------------------------------------------

local MINI_POS = "bingoMini"    -- its place on the screen (UI:SavePosition)

local function CreateMini()
    local f = CreateFrame("Button", "DisasterZoneBingoMini", UIParent)
    f:SetSize(196, 26)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    ns.UI:Gradient(f.bg, "VERTICAL", { 0.05, 0.05, 0.06, 0.9 }, { 0.12, 0.12, 0.14, 0.9 })
    ns.UI:AddEdges(f, "BORDER", true)
    ns.UI:SetEdgeColor(f, 1, 1, 1, 0.12)
    f.accent = f:CreateTexture(nil, "BORDER", nil, 1)
    f.accent:SetPoint("TOPLEFT", 1, -1)
    f.accent:SetPoint("BOTTOMLEFT", 1, 1)
    f.accent:SetWidth(2)
    f.accent:SetColorTexture(S:Alpha("GOLD", 1))
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(16, 16)
    f.icon:SetPoint("LEFT", 9, 0)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        ns.UI:SavePosition(self, MINI_POS)
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
        ns.UI:SetEdgeColor(self, S:Alpha("GOLD", 0.5))
        ns.UI:SetTextTooltip(self, { "Council Bingo", "Left-click: open your card", "Right-click: hide until the next game" })
    end)
    f:SetScript("OnLeave", function(self)
        ns.UI:SetEdgeColor(self, 1, 1, 1, 0.12)
        ns.UI:HideTooltip()
    end)
    f.text = ns.UI:Text(f, "small", "TEXT")
    f.text:SetPoint("LEFT", f.icon, "RIGHT", 7, 0)
    f.text:SetPoint("RIGHT", -8, 0)
    -- (1.3.x kept the place in the game's saved data: it moves to the one window-position store)
    local old = ns.Games:PeekData("bingo").miniPos
    if old ~= nil then
        local moved = ns.UI:SavedPosition(MINI_POS) ~= nil or type(old) ~= "table" or type(old[1]) ~= "string"
        if not moved and pcall(f.SetPoint, f, old[1], UIParent, old[2] or old[1], tonumber(old[3]) or 0,
                tonumber(old[4]) or 0) then
            moved = ns.UI:SavePosition(f, MINI_POS)
        end
        if moved then ns.Games:GetData("bingo").miniPos = nil end
    end
    ns.UI:RestorePosition(f, MINI_POS, "TOP", UIParent, "TOP", 0, -120)
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
        local me = Util.PlayerKey()
        local marks = Bingo:GetMarks(me)
        local lines, marked, awayCount = 0, 0, 0
        if marks then
            local _, away
            lines, marked, _, _, away = ns.BingoCard.Analyze(marks)
            for _ in pairs(away) do awayCount = awayCount + 1 end
        end
        local extra = ""
        if lines > 0 then extra = "  " .. S:Wrap("GOLD", "BINGO")
        elseif awayCount > 0 then extra = "  " .. S:Wrap("GOLD", "1 away!") end
        self.icon:SetTexture(RAID_ICON .. Dauber())
        if lines > 0 then self.accent:SetColorTexture(S:Alpha("GOLD", 1)) else self.accent:SetColorTexture(1, 0.29, 0.24, 1) end
        self.text:SetText(string.format("Bingo  |cffffffff%d|r|cff8a8a8a/25|r  %s%s", marked,
            S:Wrap("GOLD", Bingo:GetPoints(me) .. " pts"), extra))
        self:Show()
    end
    f:Hide()
    return f
end

-- For the test harness.
function BingoUI:GetWidgets()
    return { panel = panel, cells = cells, threads = threads, slam = slam, race = raceRows, feed = feedRows,
        ladder = ladderRows, witnessed = witnessRows, codexCells = codexCells, dauber = dauberBtns, status = hero and hero.sub,
        card = card, hero = hero, side = side, codex = codex, takeover = takeover, seg = seg, yourLegendary = yourLeg,
        stats = stats, start = startBtn, stop = stopBtn, mini = mini }
end

function BingoUI:OnInit()
    ns:On("BINGO_UPDATED", function() BingoUI:Refresh() end)
    ns:On("GAMES_UPDATED", function() BingoUI:Refresh() end)
    ns:On("GROUP_UPDATED", function() BingoUI:Refresh() end)
    ns:On("BINGO_MOMENT", OnMoment)
    ns:On("DEMO_TOGGLED", function() BingoUI:Refresh() end)
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

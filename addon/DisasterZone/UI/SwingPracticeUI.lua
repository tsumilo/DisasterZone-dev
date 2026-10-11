if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingPracticeUI.lua", ...) then return end -- DisasterZone: twist practice UI.
-- The screens of twist practice (Core/SwingPractice.lua):
--   window     banner (Karazhan art, your latency, stars earned), the lessons as rows (icon, title, goal, stars;
--              locked ones dim), your keys (click one, press a key to change it), Start
--   result     the same window after a lesson: stars popping in, % of a perfect run, tiles (twists, early, late,
--              missed, strikes, judgements), every Seal of Blood on the timing ruler, one tip, Try again / Next
--   overlay    around the swing ring while practice runs: a coach card over it (lesson, what to press now with
--              your key, a pip per swing), 3-2-1-Go in the ring, a big word beside it after each swing (Perfect,
--              Early 62 ms, ...), the timing ruler and the lesson's keys under it (they light up when it is their
--              turn, shade while cooling down, and can be clicked)
-- Open with /dz swing practice or Practice on the swing timer's card in Settings > Class tools.
local addonName, ns = ...

local PUI = ns:NewModule("SwingPracticeUI")

local floor, max, min, abs, sin = math.floor, math.max, math.min, math.abs, math.sin
local strformat = string.format

local W = 560
local PAD, GAP = 10, 8
local BANNER_H = 84
local ROW_H, ROW_GAP = 52, 4
local KEYS_H = 64
local CONTENT_H = PAD + BANNER_H + GAP + 6 * ROW_H + 5 * ROW_GAP + GAP + KEYS_H + PAD
local H = CONTENT_H + 26 + 6
local CHIP_W, CHIP_ICON = 100, 30          -- 4 chips + Start = the content width (530)
local GOLD = { 1, 0.82, 0 }
local SOFTGOLD = { 0.95, 0.74, 0.30 }
local GREY = { 0.62, 0.62, 0.64 }
local DIM = { 0.47, 0.47, 0.5 }
local WHITE8 = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local STAR = "Interface\\COMMON\\ReputationStar"
local FREE_ICON = "Interface\\Icons\\Spell_Holy_AuraOfLight"
local KIND_RGB = {
    perfect = { 1, 0.82, 0.25 }, twist = { 0.38, 0.86, 0.46 }, early = { 1, 0.56, 0.22 }, late = { 1, 0.56, 0.22 },
    miss = { 0.95, 0.34, 0.30 }, clip = { 0.95, 0.34, 0.30 }, nocmd = { 0.95, 0.34, 0.30 },
}
-- (names come from the client: Seal of the Martyr for the Alliance)
local function Label(spell) return ns.SwingPractice:Label(spell) end
local function Say(text) return ns.SwingPractice:Say(text) end
-- the ruler: Seal of Blood from 0.9 s before the swing to 0.45 s after
local DMIN, DMAX = -0.9, 0.45

local function UI() return ns.UI end
local function SP() return ns.SwingPractice end
local function ST() return ns.SwingTimer end
local function EUI() return ns.EventUI end

local frame, overlay

local function Text(parent, size, color, layer, flags)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlight")
    local path = fs:GetFont()
    fs:SetFont(path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, flags or "")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    fs:SetShadowOffset(1, -1)
    fs:SetShadowColor(0, 0, 0, 1)
    return fs
end

local function Fill(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetTexture(WHITE8)
    t:SetVertexColor(r, g, b, a or 1)
    return t
end

local function Edge(f, r, g, b, a)
    if not f.edges then UI():AddEdges(f) end
    UI():SetEdgeColor(f, r, g, b, a)
end

local function Tip(owner, title, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 0.82, 0)
    for _, l in ipairs(lines or {}) do
        if type(l) == "table" then GameTooltip:AddLine(l[1], l[2], l[3], l[4], true)
        else GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
    end
    GameTooltip:Show()
end

local function Star(parent, size)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(STAR)
    t:SetTexCoord(0, 0.5, 0, 0.5)
    t:SetSize(size, size)
    function t:SetLit(on)
        self:SetDesaturated(not on)
        if on then self:SetVertexColor(1, 1, 1, 1) else self:SetVertexColor(0.35, 0.35, 0.38, 0.9) end
    end
    return t
end

local function LessonIcon(L)
    if L.spell == "lust" then return SP().Lust().icon end
    if L.spell == "free" then return FREE_ICON end
    return ST().ICONS[L.spell]
end

local function KeyText(k)
    if not k then return "|cffff6a5a?|r" end
    return SP():Short(k)
end

local function Ease(x) x = min(1, max(0, x)); return 1 - (1 - x) * (1 - x) end

-- ---------------------------------------------------------------------------------------------------------------
-- The timing ruler: where Seal of Blood landed against the swing, the window in orange
-- ---------------------------------------------------------------------------------------------------------------
local function X(rw, d) return (min(DMAX, max(DMIN, d)) - DMIN) / (DMAX - DMIN) * rw end

local function NewRuler(parent, rw, rh, labels)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(rw, rh)
    r.rw = rw
    local track = Fill(r, "BACKGROUND", 0.06, 0.06, 0.07, 0.9)
    track:SetAllPoints()
    Edge(r, 0.2, 0.2, 0.22, 1)
    local o = ST().OVERLAP
    local win = Fill(r, "BORDER", 1, 0.56, 0.2, 0.32)
    win:SetPoint("TOPLEFT", r, "TOPLEFT", X(rw, -o), 0)
    win:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", X(rw, 0), 0)
    local safe = Fill(r, "BORDER", 1, 0.62, 0.25, 0.5, 1)
    safe:SetPoint("TOPLEFT", r, "TOPLEFT", X(rw, -o + 0.05), -3)
    safe:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", X(rw, -0.05), 3)
    local swing = Fill(r, "ARTWORK", SOFTGOLD[1], SOFTGOLD[2], SOFTGOLD[3], 1)
    swing:SetWidth(2)
    swing:SetPoint("TOP", r, "TOPLEFT", X(rw, 0), 3)
    swing:SetPoint("BOTTOM", r, "BOTTOMLEFT", X(rw, 0), -3)
    if labels then
        local e = Text(r, 9.5, DIM)
        e:SetPoint("TOPLEFT", r, "BOTTOMLEFT", 0, -3)
        e:SetText("TOO EARLY")
        local w = Text(r, 9.5, { 1, 0.66, 0.34 })
        w:SetPoint("TOP", r, "BOTTOMLEFT", X(rw, -o / 2), -3)
        w:SetText("TWIST")
        local s = Text(r, 9.5, SOFTGOLD)
        s:SetPoint("TOP", r, "BOTTOMLEFT", X(rw, 0) + 14, -3)
        s:SetText("SWING")
        local l = Text(r, 9.5, DIM)
        l:SetPoint("TOPRIGHT", r, "BOTTOMRIGHT", 0, -3)
        l:SetText("LATE")
    end
    r.dots = {}
    function r:SetMarks(list, keep)
        local from = keep and max(1, #list - keep + 1) or 1
        local n = 0
        for i = from, #list do
            n = n + 1
            local d = self.dots[n]
            if not d then
                d = self:CreateTexture(nil, "OVERLAY")
                d:SetTexture(DISC)
                self.dots[n] = d
            end
            local m = list[i]
            local c = KIND_RGB[m.kind] or GREY
            local latest = i == #list
            local size = latest and min(rh - 2, 10) or min(rh - 6, 7)
            d:SetSize(size, size)
            d:ClearAllPoints()
            d:SetPoint("CENTER", self, "LEFT", X(self.rw, m.d), 0)
            local fade = keep and (0.35 + 0.65 * (i - from + 1) / max(1, #list - from + 1)) or 0.9
            d:SetVertexColor(c[1], c[2], c[3], latest and 1 or fade)
            d:Show()
        end
        for i = n + 1, #self.dots do self.dots[i]:Hide() end
    end
    return r
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window: lessons
-- ---------------------------------------------------------------------------------------------------------------
local selected

local function BuildBanner(c)
    local bn = CreateFrame("Frame", nil, c)
    bn:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -PAD)
    bn:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PAD, -PAD)
    bn:SetHeight(BANNER_H)
    bn:SetClipsChildren(true)
    bn.art = bn:CreateTexture(nil, "BACKGROUND")
    bn.art:SetAllPoints()
    bn.art:SetVertexColor(0.62, 0.62, 0.62)
    local PlanUI = ns.RaidPlanUI
    if PlanUI and PlanUI.RaidArt then
        local path, l, r, t, b = PlanUI:RaidArt("kara", W - 10 - 2 * PAD, BANNER_H, 0.62)
        bn.art:SetTexture(path)
        bn.art:SetTexCoord(l, r, t, b)
    end
    if EUI() then EUI():AddShade(bn) end
    Edge(bn, 0.16, 0.16, 0.18, 1)
    bn.title = Text(bn, 19, GOLD)
    bn.title:SetPoint("TOPLEFT", bn, "TOPLEFT", 14, -14)
    bn.title:SetText("Twist practice")
    bn.sub = Text(bn, 11, { 0.78, 0.78, 0.8 })
    bn.sub:SetPoint("TOPLEFT", bn, "TOPLEFT", 14, -42)
    bn.sub:SetText("Learn the seal twist one step at a time.")
    bn.sub2 = Text(bn, 11, { 0.6, 0.6, 0.63 })
    bn.sub2:SetPoint("TOPLEFT", bn.sub, "BOTTOMLEFT", 0, -3)
    bn.sub2:SetText("Nothing is cast: your keys are caught while you practice.")
    -- stars earned, latency
    bn.starCount = Text(bn, 13, GOLD)
    bn.starCount:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -14)
    bn.starCount:SetJustifyH("RIGHT")
    bn.star = Star(bn, 16)
    bn.star:SetPoint("RIGHT", bn.starCount, "LEFT", -4, 0)
    bn.star:SetLit(true)
    bn.lat = Text(bn, 9.5, GREY)
    bn.lat:SetPoint("TOPRIGHT", bn, "TOPRIGHT", -12, -36)
    bn.lat:SetJustifyH("RIGHT")
    local hit = CreateFrame("Frame", nil, bn)
    hit:SetPoint("TOPLEFT", bn.lat, "TOPLEFT", -4, 4)
    hit:SetPoint("BOTTOMRIGHT", bn.lat, "BOTTOMRIGHT", 4, -4)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self)
        Tip(self, "Your latency", { "Practice delays every press by it, the way the server hears you, so the "
            .. "timing you learn here is the timing of a real fight. Settings > Class tools > Swing timer > Latency." })
    end)
    hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return bn
end

local function NewRow(c, i)
    local row = CreateFrame("Button", nil, c)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + BANNER_H + GAP + (i - 1) * (ROW_H + ROW_GAP)))
    row:SetPoint("TOPRIGHT", c, "TOPRIGHT", -PAD, -(PAD + BANNER_H + GAP + (i - 1) * (ROW_H + ROW_GAP)))
    row.bg = Fill(row, "BACKGROUND", 0.09, 0.09, 0.1, 0.92)
    row.bg:SetAllPoints()
    row.glow = Fill(row, "BACKGROUND", GOLD[1], GOLD[2], GOLD[3], 0, 1)
    row.glow:SetAllPoints()
    if row.glow.SetGradient and CreateColor then
        row.glow:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.12), CreateColor(1, 0.82, 0, 0))
    end
    row.glow:Hide()
    Edge(row, 0.17, 0.17, 0.19, 1)
    row.iconBox = CreateFrame("Frame", nil, row)
    row.iconBox:SetSize(36, 36)
    row.iconBox:SetPoint("LEFT", row, "LEFT", 8, 0)
    Edge(row.iconBox, 0, 0, 0, 1)
    row.icon = row.iconBox:CreateTexture(nil, "ARTWORK")
    row.icon:SetAllPoints()
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.num = CreateFrame("Frame", nil, row.iconBox)
    row.num:SetSize(16, 16)
    row.num:SetPoint("CENTER", row.iconBox, "BOTTOMRIGHT", -2, 2)
    row.num:SetFrameLevel(row.iconBox:GetFrameLevel() + 2)
    local nb = row.num:CreateTexture(nil, "ARTWORK")
    nb:SetTexture(DISC)
    nb:SetVertexColor(0.05, 0.05, 0.06, 1)
    nb:SetAllPoints()
    row.numRing = row.num:CreateTexture(nil, "BORDER")
    row.numRing:SetTexture(DISC)
    row.numRing:SetPoint("CENTER")
    row.numRing:SetSize(18, 18)
    row.numRing:SetVertexColor(SOFTGOLD[1], SOFTGOLD[2], SOFTGOLD[3], 1)
    row.numText = Text(row.num, 9.5, GOLD)
    row.numText:SetPoint("CENTER", 0, 0)
    row.lock = row:CreateTexture(nil, "OVERLAY")
    row.lock:SetSize(18, 18)
    row.lock:SetPoint("CENTER", row.iconBox, "CENTER")
    row.lock:SetTexture(UI().ICON_ATLAS)
    local lc = UI():IconCoords(UI().ICON.lock)
    row.lock:SetTexCoord(lc[1], lc[2], lc[3], lc[4])
    row.lock:Hide()
    row.title = Text(row, 14, { 0.95, 0.95, 0.96 })
    row.title:SetPoint("TOPLEFT", row.iconBox, "TOPRIGHT", 12, -2)
    row.goal = Text(row, 11, GREY)
    row.goal:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
    row.goal:SetPoint("RIGHT", row, "RIGHT", -96, 0)
    row.stars = {}
    for s = 1, 3 do
        local st = Star(row, 16)
        st:SetPoint("RIGHT", row, "RIGHT", -12 - (3 - s) * 19, 6)
        row.stars[s] = st
    end
    row.best = Text(row, 9.5, DIM)
    row.best:SetPoint("TOPRIGHT", row, "RIGHT", -12, -6)
    row.best:SetJustifyH("RIGHT")
    row:SetScript("OnEnter", function(self)
        if not self.selected then Edge(self, 0.36, 0.33, 0.24, 1) end
        if self.locked then
            Tip(self, self.L.title, { strformat("Get a star in lesson %d first.", self.L.n - 1) })
        elseif self.L then
            local lines = { Say(self.L.intro) }
            local b = SP():Best(self.L.key)
            if b then lines[#lines + 1] = { strformat("Best: %d %% of a perfect run", floor((b.grade or 0) * 100 + 0.5)),
                0.6, 0.6, 0.62 } end
            lines[#lines + 1] = { "Click: pick · Double-click: start", 0.6, 0.6, 0.62 }
            Tip(self, self.L.title, lines)
        end
    end)
    row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        PUI:PaintRow(self)
    end)
    row:SetScript("OnClick", function(self)
        if self.locked then return end
        selected = self.L.key
        PUI:Refresh()
    end)
    row:SetScript("OnDoubleClick", function(self)
        if self.locked then return end
        selected = self.L.key
        PUI:StartSelected()
    end)
    return row
end

function PUI:PaintRow(row)
    if row.selected then
        Edge(row, GOLD[1], GOLD[2], GOLD[3], 0.85)
        row.glow:Show()
        row.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    else
        Edge(row, 0.17, 0.17, 0.19, 1)
        row.glow:Hide()
        row.title:SetTextColor(0.95, 0.95, 0.96)
    end
end

local function NewChip(parent, spell)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetSize(CHIP_W, 38)
    chip.spell = spell
    chip.bg = Fill(chip, "BACKGROUND", 0.09, 0.09, 0.1, 0.92)
    chip.bg:SetAllPoints()
    Edge(chip, 0.2, 0.2, 0.22, 1)
    chip.icon = chip:CreateTexture(nil, "ARTWORK")
    chip.icon:SetSize(CHIP_ICON, CHIP_ICON)
    chip.icon:SetPoint("LEFT", chip, "LEFT", 4, 0)
    chip.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- the key cap, the spell's short name under it
    chip.cap = CreateFrame("Frame", nil, chip)
    chip.cap:SetSize(34, 18)
    chip.cap:SetPoint("TOPLEFT", chip.icon, "TOPRIGHT", 7, 0)
    chip.capBg = Fill(chip.cap, "BACKGROUND", 0.16, 0.16, 0.18, 1)
    chip.capBg:SetAllPoints()
    Edge(chip.cap, 0.36, 0.36, 0.4, 1)
    chip.capLip = Fill(chip.cap, "BORDER", 0, 0, 0, 0.5)
    chip.capLip:SetPoint("BOTTOMLEFT")
    chip.capLip:SetPoint("BOTTOMRIGHT")
    chip.capLip:SetHeight(3)
    chip.key = Text(chip.cap, 11, { 1, 1, 1 })
    chip.key:SetPoint("CENTER", 0, 1)
    chip.key:SetJustifyH("CENTER")
    chip.what = Text(chip, 9.5, DIM)
    chip.what:SetPoint("BOTTOMLEFT", chip.icon, "BOTTOMRIGHT", 7, 0)
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chip:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            SP():SetKey(self.spell, nil)
            PUI:Refresh()
            return
        end
        if SP():Assigning() == self.spell then SP():CancelAssign() return end
        SP():AssignKey(self.spell, function() PUI:Refresh() end)
        PUI:Refresh()
    end)
    chip:SetScript("OnEnter", function(self)
        Edge(self, 0.5, 0.46, 0.34, 1)
        local keys, auto = SP():Keys()
        local lines = { "Click, then press the key you use for it in fights." }
        if auto[self.spell] and keys[self.spell] ~= auto[self.spell] then
            lines[#lines + 1] = { "Your bars: " .. SP():Short(auto[self.spell]) .. " · Right-click: back to that", 0.6, 0.6, 0.62 }
        elseif auto[self.spell] then
            lines[#lines + 1] = { "Found on your action bars.", 0.6, 0.6, 0.62 }
        else
            lines[#lines + 1] = { "Not found on your action bars: set it here. Mouse buttons can't be caught: pick a key.",
                0.6, 0.6, 0.62 }
        end
        Tip(self, Label(self.spell), lines)
    end)
    chip:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        Edge(self, 0.2, 0.2, 0.22, 1)
    end)
    return chip
end

local function BuildKeys(c)
    local k = CreateFrame("Frame", nil, c)
    k:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", PAD, PAD)
    k:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PAD, PAD)
    k:SetHeight(KEYS_H)
    local rule = Fill(k, "ARTWORK", 1, 1, 1, 0.08)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT")
    rule:SetPoint("TOPRIGHT")
    k.cap = Text(k, 9.5, GREY)
    k.cap:SetPoint("TOPLEFT", k, "TOPLEFT", 0, -8)
    k.cap:SetText("YOUR KEYS")
    k.chips = {}
    for i, s in ipairs(SP().SPELLS) do
        local chip = NewChip(k, s)
        chip:SetPoint("BOTTOMLEFT", k, "BOTTOMLEFT", (i - 1) * (CHIP_W + 6), 0)
        chip.icon:SetTexture(ST().ICONS[s])
        k.chips[i] = chip
    end
    k.start = UI():CreateSleekButton(k, "Start", 104, 38, function() PUI:StartSelected() end, "primary")
    k.start:HookScript("OnEnter", function(self)
        Tip(self, "Start", { "The ring shows up where your swing timer sits. 3, 2, 1, then the swings start.",
            { "Esc stops. Entering combat stops it too.", 0.6, 0.6, 0.62 } })
    end)
    k.start:HookScript("OnLeave", function() GameTooltip:Hide() end)
    k.start:SetPoint("BOTTOMRIGHT", k, "BOTTOMRIGHT", 0, 0)
    return k
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window: result
-- ---------------------------------------------------------------------------------------------------------------
local TILE_W, TILE_H = 78, 50

local function BuildResult(c)
    local r = CreateFrame("Frame", nil, c)
    r:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -(PAD + BANNER_H + GAP))
    r:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -PAD, PAD)
    r:Hide()
    local bg = Fill(r, "BACKGROUND", 0.07, 0.07, 0.08, 0.9)
    bg:SetAllPoints()
    Edge(r, 0.17, 0.17, 0.19, 1)
    r.glow = r:CreateTexture(nil, "BORDER")
    r.glow:SetTexture(SOFT)
    r.glow:SetBlendMode("ADD")
    r.glow:SetVertexColor(1, 0.75, 0.3, 0.22)
    r.glow:SetSize(360, 200)
    r.glow:SetPoint("CENTER", r, "TOP", 0, -64)
    r.cap = Text(r, 9.5, GREY)
    r.cap:SetPoint("TOP", r, "TOP", 0, -14)
    r.cap:SetJustifyH("CENTER")
    r.stars = {}
    for s = 1, 3 do
        local st = Star(r, 44)
        st:SetPoint("CENTER", r, "TOP", (s - 2) * 54, -56 + (s == 2 and 6 or 0))
        r.stars[s] = st
    end
    r.grade = Text(r, 28, { 1, 1, 1 })
    r.grade:SetPoint("TOP", r, "TOP", 0, -92)
    r.grade:SetJustifyH("CENTER")
    r.gradeSub = Text(r, 11, GREY)
    r.gradeSub:SetPoint("TOP", r.grade, "BOTTOM", 0, -3)
    r.gradeSub:SetJustifyH("CENTER")
    r.best = UI():CreateTagPill(r, 16)
    r.best:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -10)
    r.best:Hide()
    r.tiles = {}
    for i = 1, 6 do
        local t = CreateFrame("Frame", nil, r)
        t:SetSize(TILE_W, TILE_H)
        local tb = Fill(t, "BACKGROUND", 0.11, 0.11, 0.12, 1)
        tb:SetAllPoints()
        Edge(t, 0.2, 0.2, 0.22, 1)
        t.bar = Fill(t, "BORDER", 1, 1, 1, 1)
        t.bar:SetPoint("TOPLEFT", 1, -1)
        t.bar:SetPoint("TOPRIGHT", -1, -1)
        t.bar:SetHeight(2)
        t.num = Text(t, 17, { 1, 1, 1 })
        t.num:SetPoint("TOP", t, "TOP", 0, -10)
        t.num:SetJustifyH("CENTER")
        t.label = Text(t, 9.5, GREY)
        t.label:SetPoint("BOTTOM", t, "BOTTOM", 0, 8)
        t.label:SetJustifyH("CENTER")
        r.tiles[i] = t
    end
    r.rulerCap = Text(r, 9.5, GREY)
    r.rulerCap:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -218)
    r.ruler = NewRuler(r, W - 10 - 2 * PAD - 32, 20, true)
    r.ruler:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -234)
    r.tipCap = Text(r, 9.5, GOLD)
    r.tipCap:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -286)
    r.tipCap:SetText("TRY THIS")
    r.tip = Text(r, 12, { 0.92, 0.92, 0.94 })
    r.tip:SetPoint("TOPLEFT", r.tipCap, "BOTTOMLEFT", 0, -5)
    r.tip:SetPoint("RIGHT", r, "RIGHT", -16, 0)
    r.tip:SetWordWrap(true)
    r.lessons = UI():CreateSleekButton(r, "All lessons", 104, 30, function() PUI:ShowLessons() end)
    r.lessons:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 14, 14)
    r.next = UI():CreateSleekButton(r, "Next lesson", 124, 30, function()
        if r.nextKey then selected = r.nextKey; PUI:StartSelected() end
    end, "primary")
    r.next:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -14, 14)
    r.again = UI():CreateSleekButton(r, "Try again", 104, 30, function()
        if r.res then selected = r.res.lesson; PUI:StartSelected() end
    end)
    r.again:SetPoint("RIGHT", r.next, "LEFT", -8, 0)
    r:SetScript("OnUpdate", function(self) PUI:AnimateResult(self) end)
    return r
end

function PUI:ShowResult(res)
    if not frame then self:Build() end
    local r = frame.result
    r.res = res
    r.shownAt = GetTime()
    local L = SP().LESSONS[res.n]
    r.cap:SetText(res.free and "FREE PLAY" or strformat("LESSON %d · %s", res.n, res.title:upper()))
    for _, st in ipairs(r.stars) do st:SetShown(not res.free); st:SetLit(false) end
    r.grade:SetText(strformat("%d %%", floor(res.grade * 100 + 0.5)))
    r.gradeSub:SetText("of a perfect run on the same swings")
    if res.newBest and res.done then
        r.best:Set(res.free and "Best run" or "New best", "ok")
        r.best:Show()
    else r.best:Hide() end
    -- tiles
    local c = res.counts
    local missed = (c.miss or 0) + (c.clip or 0) + (c.nocmd or 0)
    local tiles = {
        { strformat("%d/%d", c.twist or 0, max(res.expected or 0, c.twist or 0)), "Twists", KIND_RGB.twist },
        { tostring(c.perfect or 0), "Perfect", KIND_RGB.perfect },
        { tostring(c.early or 0), "Early", KIND_RGB.early },
        { tostring(c.late or 0), "Late", KIND_RGB.late },
        { tostring(missed), "Missed", KIND_RGB.miss },
    }
    if L and L.keys.cs then
        tiles[#tiles + 1] = { strformat("%d/%d", c.cs or 0, max(res.ghostCs or 0, c.cs or 0)), "Strikes", { 0.45, 0.72, 1 } }
    end
    if L and L.keys.judge and #tiles < 6 then
        tiles[#tiles + 1] = { strformat("%d/%d", c.judge or 0, max(res.ghostJudge or 0, c.judge or 0)), "Judgements", { 0.45, 0.72, 1 } }
    end
    if #tiles > 6 then table.remove(tiles, 2) end
    local n = #tiles
    local total = n * TILE_W + (n - 1) * 6
    local x0 = -total / 2
    for i, t in ipairs(r.tiles) do
        local d = tiles[i]
        if d then
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", r, "TOP", x0 + (i - 1) * (TILE_W + 6), -150)
            t.num:SetText(d[1])
            t.label:SetText(d[2]:upper())
            local zero = d[1] == "0"
            local col = zero and DIM or d[3]
            t.bar:SetVertexColor(col[1], col[2], col[3], zero and 0.4 or 1)
            t.num:SetTextColor(zero and 0.5 or 1, zero and 0.5 or 1, zero and 0.52 or 1)
            t:Show()
        else t:Hide() end
    end
    r.ruler:SetMarks(res.offsets or {})
    r.tip:SetText(SP():Tip(res))
    r.rulerCap:SetText("WHERE YOUR " .. Label("sob"):upper() .. " LANDED")
    -- the next lesson
    local nextL = not res.free and SP().LESSONS[res.n + 1] or nil
    r.nextKey = nextL and SP():IsUnlocked(nextL) and nextL.key or nil
    if res.free then
        r.next:SetText("Play again")
        r.nextKey = "free"
        r.next:Show()
        r.again:Hide()
    else
        r.next:SetText(nextL and (nextL.key == "free" and "Free play" or "Next lesson") or "Next lesson")
        r.next:SetShown(r.nextKey ~= nil)
        r.again:Show()
        r.again:ClearAllPoints()
        if r.nextKey then r.again:SetPoint("RIGHT", r.next, "LEFT", -8, 0)
        else r.again:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -14, 14) end
        r.again:SetText(res.stars < 1 and "Try again" or "Again")
    end
    for _, row in ipairs(frame.rows) do row:Hide() end
    frame.keys:Hide()
    r:Show()
    frame:Show()
    if res.stars >= 3 and not res.free then pcall(PlaySound, 888, "SFX") end
end

-- Stars pop in one after another, the glow breathes.
function PUI:AnimateResult(r)
    local res = r.res
    if not res then return end
    local t = GetTime() - (r.shownAt or 0)
    for s, st in ipairs(r.stars) do
        local at = 0.25 + (s - 1) * 0.28
        local p = (t - at) / 0.22
        local lit = not res.free and s <= res.stars
        if lit and p >= 0 then
            st:SetLit(true)
            local k = p < 1 and (1.35 - 0.35 * Ease(p)) or 1
            local base = 44
            st:SetSize(base * k, base * k)
            if p >= 0 and p < 0.1 and not st.played then
                st.played = true
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "SFX")
            end
        else
            st:SetLit(false)
            st:SetSize(44, 44)
            st.played = nil
        end
    end
    r.glow:SetAlpha(0.6 + 0.4 * sin(GetTime() * 2))
end

function PUI:ShowLessons()
    if not frame then return end
    frame.result:Hide()
    for _, st in ipairs(frame.result.stars) do st.played = nil end
    frame.keys:Show()
    self:Refresh()
end

-- ---------------------------------------------------------------------------------------------------------------
-- Build, refresh, start
-- ---------------------------------------------------------------------------------------------------------------
function PUI:Build()
    frame = UI():CreateWindow("DisasterZoneSwingPractice", "Twist practice", W, H)
    frame:Hide()
    frame:HookScript("OnShow", function() if not frame.result:IsShown() then PUI:Refresh() end end)
    frame:HookScript("OnHide", function() if SP():Assigning() then SP():CancelAssign() end end)
    local c = frame.content
    frame.banner = BuildBanner(c)
    frame.rows = {}
    for i in ipairs(SP().LESSONS) do frame.rows[i] = NewRow(c, i) end
    frame.keys = BuildKeys(c)
    frame.result = BuildResult(c)
    ns:On("SWING_PRACTICE_KEYS", function() if frame:IsShown() then PUI:Refresh() end end)
end

function PUI:Refresh()
    if not frame then return end
    local sp = SP()
    if not selected or not sp:IsUnlocked(selected) then selected = sp:NextLesson().key end
    -- banner
    local earned, total = 0, 0
    for _, L in ipairs(sp.LESSONS) do
        if L.key ~= "free" then
            total = total + 3
            local b = sp:Best(L.key)
            earned = earned + (b and b.stars or 0)
        end
    end
    frame.banner.starCount:SetText(strformat("%d of %d", earned, total))
    local lat = ST():Latency() or 0
    frame.banner.lat:SetText(strformat("YOUR LATENCY %d MS", floor(lat * 1000 + 0.5)))
    -- rows
    for i, L in ipairs(sp.LESSONS) do
        local row = frame.rows[i]
        row.L = L
        row:Show()
        row.locked = not sp:IsUnlocked(L)
        row.selected = L.key == selected
        row.icon:SetTexture(LessonIcon(L))
        row.icon:SetDesaturated(row.locked)
        row.icon:SetAlpha(row.locked and 0.35 or 1)
        row.lock:SetShown(row.locked)
        row.num:SetShown(L.key ~= "free")
        row.numText:SetText(i)
        row.title:SetText(L.title)
        row.goal:SetText(row.locked and strformat("Get a star in lesson %d to open it.", i - 1) or Say(L.goal))
        row:SetAlpha(row.locked and 0.6 or 1)
        local b = sp:Best(L.key)
        for s, st in ipairs(row.stars) do
            st:SetShown(L.key ~= "free")
            st:SetLit(b ~= nil and (b.stars or 0) >= s)
        end
        if b then
            row.best:SetText(L.key == "free" and strformat("Best %d %%", floor((b.grade or 0) * 100 + 0.5))
                or strformat("%d %%", floor((b.grade or 0) * 100 + 0.5)))
        else
            row.best:SetText(L.key == "free" and "Not played" or "")
        end
        if L.key == "free" then
            row.best:ClearAllPoints()
            row.best:SetPoint("RIGHT", row, "RIGHT", -12, 0)
        end
        self:PaintRow(row)
    end
    -- keys: the selected lesson's spells lit, the others dim
    local keys = sp:Keys()
    local L = nil
    for _, l in ipairs(sp.LESSONS) do if l.key == selected then L = l end end
    local assigning = sp:Assigning()
    local missing
    for _, chip in ipairs(frame.keys.chips) do
        local inL = L and L.keys[chip.spell]
        chip:SetAlpha(inL and 1 or 0.4)
        local k = keys[chip.spell]
        if assigning == chip.spell then
            chip.key:SetText("...")
            Edge(chip.cap, GOLD[1], GOLD[2], GOLD[3], 1)
            chip.what:SetText("Press a key")
            chip.what:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        else
            chip.key:SetText(KeyText(k))
            Edge(chip.cap, k and 0.36 or 0.7, k and 0.36 or 0.3, k and 0.4 or 0.26, 1)
            chip.what:SetText(SP():ShortLabel(chip.spell))
            chip.what:SetTextColor(DIM[1], DIM[2], DIM[3])
        end
        local w = chip.key:GetStringWidth() or 0
        chip.cap:SetWidth(max(24, min(52, w + 12)))
        if inL and not k and not missing then missing = chip.spell end
    end
    frame.keys.cap:SetText(assigning and ("PRESS THE KEY YOU USE FOR " .. Label(assigning):upper() .. " · ESC CANCELS")
        or missing and ("SET A KEY FOR " .. Label(missing):upper() .. ": CLICK IT")
        or "YOUR KEYS · CLICK ONE TO CHANGE IT")
    if assigning then frame.keys.cap:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    elseif missing then frame.keys.cap:SetTextColor(1, 0.5, 0.42)
    else frame.keys.cap:SetTextColor(GREY[1], GREY[2], GREY[3]) end
    frame.keys.start:SetText(L and L.key == "free" and "Play" or "Start")
    frame.missing = missing
end

-- Start: first any key the lesson still needs (asked one after another), then the lesson.
function PUI:StartSelected()
    if not frame then self:Build() end
    local sp = SP()
    local ok, why = sp:CanPractice()
    if not ok then ns:Print(why) return end
    local L
    for _, l in ipairs(sp.LESSONS) do if l.key == selected then L = l end end
    if not L then return end
    local keys = sp:Keys()
    for _, s in ipairs(sp.SPELLS) do
        if L.keys[s] and not keys[s] then
            if not frame:IsShown() or frame.result:IsShown() then
                frame:Show()
                self:ShowLessons()
            end
            sp:AssignKey(s, function(k)
                PUI:Refresh()
                if k then PUI:StartSelected() end
            end)
            self:Refresh()
            return
        end
    end
    frame:Hide()
    sp:Start(L.key)
end

function PUI:Open()
    if not frame then self:Build() end
    local ok, why = SP():CanPractice()
    if not ok and not (ST() and ST():IsRet()) then ns:Print(why) return end
    frame.result:Hide()
    frame.keys:Show()
    frame:Show()
    self:Refresh()
end

function PUI:Close() if frame then frame:Hide() end end
function PUI:Frame() return frame end

-- ---------------------------------------------------------------------------------------------------------------
-- The overlay around the ring while practice runs
-- ---------------------------------------------------------------------------------------------------------------
local CARD_W, CARD_H = 300, 60
local RULER_W = 240

local function BuildOverlay(ring)
    local hud = ring:GetParent()
    local o = CreateFrame("Frame", nil, hud)
    o:SetAllPoints(hud)
    o:SetFrameLevel(ring:GetFrameLevel() + 6)
    o.ring = ring

    -- the coach card over the ring
    local card = CreateFrame("Frame", nil, o)
    card:SetSize(CARD_W, CARD_H)
    local cb = Fill(card, "BACKGROUND", 0.04, 0.04, 0.05, 0.86)
    cb:SetAllPoints()
    Edge(card, 0.2, 0.2, 0.22, 1)
    local accent = Fill(card, "BORDER", SOFTGOLD[1], SOFTGOLD[2], SOFTGOLD[3], 0.9)
    accent:SetPoint("TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", -1, -1)
    accent:SetHeight(2)
    card.cap = Text(card, 9.5, SOFTGOLD)
    card.cap:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -9)
    card.count = Text(card, 9.5, GREY)
    card.count:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)
    card.count:SetJustifyH("RIGHT")
    card.line = Text(card, 13, { 1, 1, 1 })
    card.line:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -24)
    card.line:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    card.pips = {}
    o.card = card
    -- the toast above the card (Bloodlust)
    local toast = CreateFrame("Frame", nil, o)
    toast:SetSize(CARD_W, 26)
    toast:SetPoint("BOTTOM", card, "TOP", 0, 6)
    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(22, 22)
    toast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    toast.text = Text(toast, 13, { 1, 0.62, 0.42 }, nil, "OUTLINE")
    toast.text:SetPoint("CENTER", 13, 0)
    toast.icon:SetPoint("RIGHT", toast.text, "LEFT", -6, 0)
    toast:Hide()
    o.toast = toast

    -- 3, 2, 1, Go in the ring
    o.count = Text(o, 44, { 1, 0.9, 0.6 }, nil, "OUTLINE")
    o.count:SetPoint("CENTER", ring, "CENTER", 0, 0)
    o.count:SetJustifyH("CENTER")

    -- the word after each swing, beside the ring
    o.pop = Text(o, 24, { 1, 1, 1 }, nil, "OUTLINE")
    o.pop:SetJustifyH("LEFT")
    o.popSub = Text(o, 12, { 0.85, 0.85, 0.87 }, nil, "OUTLINE")
    o.popSub:SetJustifyH("LEFT")
    o.burst = o:CreateTexture(nil, "BACKGROUND")
    o.burst:SetTexture(SOFT)
    o.burst:SetBlendMode("ADD")
    o.burst:SetPoint("CENTER", ring, "CENTER")
    o.burst:SetAlpha(0)

    -- the ruler and the keys under the ring
    o.ruler = NewRuler(o, RULER_W, 14, false)
    o.ruler:SetPoint("TOP", ring, "BOTTOM", 0, -12)
    o.chips = {}
    for i, s in ipairs(SP().SPELLS) do
        local chip = CreateFrame("Button", nil, o)
        chip:SetSize(40, 40)
        chip.spell = s
        local back = Fill(chip, "BACKGROUND", 0, 0, 0, 1)
        back:SetPoint("TOPLEFT", -1, 1)
        back:SetPoint("BOTTOMRIGHT", 1, -1)
        chip.glow = chip:CreateTexture(nil, "BACKGROUND", nil, -1)
        chip.glow:SetTexture(SOFT)
        chip.glow:SetBlendMode("ADD")
        chip.glow:SetVertexColor(1, 0.8, 0.35, 1)
        chip.glow:SetPoint("CENTER")
        chip.glow:SetSize(78, 78)
        chip.glow:SetAlpha(0)
        chip.icon = chip:CreateTexture(nil, "ARTWORK")
        chip.icon:SetAllPoints()
        chip.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        chip.icon:SetTexture(ST().ICONS[s])
        chip.shade = Fill(chip, "ARTWORK", 0, 0, 0, 0.62, 1)
        chip.shade:SetPoint("TOPLEFT")
        chip.shade:SetPoint("TOPRIGHT")
        chip.shade:SetHeight(1)
        chip.cd = Text(chip, 12, { 1, 1, 1 }, nil, "OUTLINE")
        chip.cd:SetPoint("CENTER", 0, 2)
        chip.cd:SetJustifyH("CENTER")
        chip.flash = Fill(chip, "OVERLAY", 1, 1, 1, 0)
        chip.flash:SetAllPoints()
        chip.flash:SetBlendMode("ADD")
        chip.cap = CreateFrame("Frame", nil, chip)
        chip.cap:SetSize(24, 16)
        chip.cap:SetPoint("TOP", chip, "BOTTOM", 0, 6)
        chip.cap:SetFrameLevel(chip:GetFrameLevel() + 2)
        local capBg = Fill(chip.cap, "BACKGROUND", 0.13, 0.13, 0.15, 1)
        capBg:SetAllPoints()
        Edge(chip.cap, 0.42, 0.42, 0.46, 1)
        chip.key = Text(chip.cap, 11, { 1, 1, 1 })
        chip.key:SetPoint("CENTER", 0, 0)
        chip.key:SetJustifyH("CENTER")
        chip.note = Text(chip, 10, { 1, 0.45, 0.4 }, nil, "OUTLINE")
        chip.note:SetPoint("BOTTOM", chip, "TOP", 0, 3)
        chip.note:SetJustifyH("CENTER")
        chip:SetScript("OnClick", function(self) SP():Press(self.spell) end)
        chip:SetScript("OnEnter", function(self)
            Tip(self, Label(self.spell), { "Press " .. SP():Short(SP().run and SP().run.keyOf[self.spell] or "") ..
                " (or click here)." })
        end)
        chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
        o.chips[i] = chip
    end
    o.esc = Text(o, 9.5, DIM)
    o.esc:SetText("ESC STOPS")
    o:SetScript("OnUpdate", function(self) PUI:UpdateOverlay(self) end)
    return o
end

-- Lays out the parts that depend on the lesson: the pips and the keys in play.
local function LayoutOverlay(o, L, keyOf)
    local n = L.swings or 0
    local card = o.card
    for i = 1, max(n, #card.pips) do
        local p = card.pips[i]
        if i <= n then
            if not p then
                p = Fill(card, "ARTWORK", 1, 1, 1, 1)
                card.pips[i] = p
            end
            local pw = min(18, floor((CARD_W - 20 - (n - 1) * 3) / max(1, n)))
            p:SetSize(pw, 4)
            p:ClearAllPoints()
            local total = n * pw + (n - 1) * 3
            p:SetPoint("BOTTOMLEFT", card, "BOTTOM", -total / 2 + (i - 1) * (pw + 3), 8)
            p:SetVertexColor(0.2, 0.2, 0.22, 1)
            p:Show()
        elseif p then
            p:Hide()
        end
    end
    local shown = {}
    for _, chip in ipairs(o.chips) do
        if L.keys[chip.spell] then shown[#shown + 1] = chip; chip:Show() else chip:Hide() end
        chip.key:SetText(KeyText(keyOf[chip.spell]))
        chip.cap:SetWidth(max(20, (chip.key:GetStringWidth() or 8) + 10))
        chip.note:SetText("")
        chip.flash:SetAlpha(0)
    end
    local total = #shown * 40 + (#shown - 1) * 12
    for i, chip in ipairs(shown) do
        chip:ClearAllPoints()
        chip:SetPoint("TOPLEFT", o.ruler, "BOTTOM", -total / 2 + (i - 1) * 52, -14)
    end
    o.esc:ClearAllPoints()
    o.esc:SetPoint("TOP", o.ruler, "BOTTOM", 0, -76)
    -- the coach card over the ring, or under the keys when the ring sits too close to the top of the screen
    local card, ring = o.card, o.ring
    local top, es = ring:GetTop(), ring:GetEffectiveScale() or 1
    local screen = UIParent:GetTop() and UIParent:GetTop() * (UIParent:GetEffectiveScale() or 1)
    card:ClearAllPoints()
    if top and screen and top * es + (12 + CARD_H + 34) * es > screen then
        card:SetPoint("TOP", o.esc, "BOTTOM", 0, -10)
    else
        card:SetPoint("BOTTOM", ring, "TOP", 0, 12)
    end
    o.cap = strformat(L.key == "free" and "FREE PLAY" or "LESSON %d · %s", L.n, L.title:upper())
    o.card.cap:SetText(o.cap)
    o.seen = SP().run and SP().run.popSeq or 0
    o.pop:SetText("")
    o.popSub:SetText("")
    o.toast:Hide()
end

-- What the coach says now: the next press, with the player's key.
local function CoachLine(run, now)
    if now < run.go then return "Get ready", { 1, 0.9, 0.6 } end
    if run.L.key == "free" then
        local me = run.me
        return strformat("Streak %d · best %d", me.streak, me.bestStreak), { 0.9, 0.9, 0.92 }
    end
    local cur = ST():Current()
    local first = cur and cur.plan.steps[1]
    if not first or first.key == "wait" then return "Wait for the next swing", { 0.75, 0.75, 0.78 } end
    local k = run.keyOf[first.key]
    local kt = k and ("|cffffd27a" .. SP():Short(k) .. "|r  ") or ""
    local dt = first.at - now
    if dt <= 0.05 then
        return "Now: " .. kt .. Label(first.key), { 1, 0.86, 0.45 }
    end
    if first.key == "sob" and first.twist then
        return "Next: " .. kt .. Label("sob") .. " when the ring turns orange", { 0.9, 0.9, 0.92 }
    end
    if first.key == "soc" then return "Next: " .. kt .. "Seal of Command, after the swing", { 0.9, 0.9, 0.92 } end
    if first.key == "judge" then return "Next: " .. kt .. "Judgement, right after the swing", { 0.9, 0.9, 0.92 } end
    return "Next: " .. kt .. Label(first.key), { 0.9, 0.9, 0.92 }
end

function PUI:UpdateOverlay(o)
    local sp = SP()
    local run = sp.run
    if not run then o:Hide() return end
    local now = GetTime()
    if o.lesson ~= run then
        o.lesson = run
        LayoutOverlay(o, run.L, run.keyOf)
    end
    -- countdown
    local left = run.go - now
    if left > 0 then
        local n = math.ceil(left)
        o.count:SetText(n)
        local f = 1 - (left - floor(left))
        o.count:SetAlpha(1 - 0.5 * f)
        o.count:SetTextColor(1, 0.9, 0.6)
    elseif left > -0.6 then
        o.count:SetText("Go!")
        o.count:SetAlpha(1 + left / 0.6)
        o.count:SetTextColor(1, 0.82, 0.3)
    else
        o.count:SetText("")
    end
    -- coach card
    local line, col = CoachLine(run, now)
    o.card.line:SetText(line)
    o.card.line:SetTextColor(col[1], col[2], col[3])
    local me = run.me
    if run.L.swings then
        o.card.count:SetText(strformat("%d / %d", #run.results, run.L.swings))
        for i, p in ipairs(o.card.pips) do
            local res = run.results[i]
            if res then
                local c = KIND_RGB[res.kind] or GREY
                p:SetVertexColor(c[1], c[2], c[3], 1)
            elseif i <= run.L.swings then
                p:SetVertexColor(0.2, 0.2, 0.22, 1)
            end
        end
    else
        local tl = sp:Tally()
        o.card.count:SetText(tl and tl.ideal > 0 and strformat("%d %%", floor(tl.grade * 100 + 0.5)) or "")
    end
    -- new pops
    for _, p in ipairs(run.pops) do
        if p.seq > (o.seen or 0) then
            o.seen = p.seq
            self:OnPop(o, p, now)
        end
    end
    -- the big word: rises and fades
    if o.popAt then
        local t = now - o.popAt
        if t > 1.1 then
            o.pop:SetText("")
            o.popSub:SetText("")
            o.popAt = nil
        else
            local a = t < 0.6 and 1 or (1 - (t - 0.6) / 0.5)
            local rise = 16 * Ease(t / 1.1)
            o.pop:ClearAllPoints()
            o.pop:SetPoint("LEFT", o.ring, "RIGHT", 10, 12 + rise)
            o.pop:SetAlpha(a)
            o.popSub:ClearAllPoints()
            o.popSub:SetPoint("TOPLEFT", o.pop, "BOTTOMLEFT", 1, -2)
            o.popSub:SetAlpha(a)
        end
    end
    if o.burstAt then
        local t = (now - o.burstAt) / 0.45
        if t >= 1 then o.burst:SetAlpha(0); o.burstAt = nil
        else
            local s = o.ring:GetWidth() > 0 and o.ring:GetWidth() or 128
            o.burst:SetSize(s * (1.1 + 0.8 * Ease(t)), s * (1.1 + 0.8 * Ease(t)))
            o.burst:SetAlpha(0.75 * (1 - t))
        end
    end
    if o.toastAt then
        local t = now - o.toastAt
        if t > 2.6 then o.toast:Hide(); o.toastAt = nil
        else o.toast:SetAlpha(t < 2 and 1 or (1 - (t - 2) / 0.6)) end
    end
    -- the ruler: the last Seal of Bloods
    o.ruler:SetMarks(me.offsets, 6)
    -- keys: whose turn, cooldowns, flashes
    local cur = now >= run.go and ST():Current() or nil
    local first = cur and cur.plan.steps[1]
    local due = first and first.key ~= "wait" and first.at - now <= 0.05 and first.key or nil
    local pulse = 0.65 + 0.35 * sin(now * 10)
    for _, chip in ipairs(o.chips) do
        if chip:IsShown() then
            local s = chip.spell
            chip.glow:SetAlpha(due == s and pulse or 0)
            local left, dur = 0, 1
            if s == "cs" and me.cd.cs > now then left, dur = me.cd.cs - now, run.cds.cs or 6
            elseif s == "judge" and me.cd.judge > now then left, dur = me.cd.judge - now, run.cds.judge or 10 end
            if s ~= "judge" and me.gcdEnd > now and me.gcdEnd - now > left then left, dur = me.gcdEnd - now, run.gcd end
            if left > 0 then
                chip.shade:SetHeight(max(1, 40 * min(1, left / dur)))
                chip.shade:Show()
                chip.cd:SetText(left >= 1.6 and strformat("%d", math.ceil(left)) or "")
            else
                chip.shade:Hide()
                chip.cd:SetText("")
            end
            if chip.flashAt then
                local t = (now - chip.flashAt) / 0.25
                chip.flash:SetAlpha(t < 1 and 0.55 * (1 - t) or 0)
                if t >= 1 then chip.flashAt = nil end
            end
            if chip.noteAt then
                local t = now - chip.noteAt
                chip.note:SetAlpha(t < 0.5 and 1 or max(0, 1 - (t - 0.5) / 0.4))
                if t > 0.9 then chip.noteAt = nil; chip.note:SetText("") end
            end
        end
    end
end

local SWING_KINDS = { perfect = true, twist = true, early = true, late = true, miss = true, clip = true, nocmd = true }

function PUI:OnPop(o, p, now)
    if SWING_KINDS[p.kind] then
        local c = KIND_RGB[p.kind]
        local text = p.text
        if (p.kind == "perfect" or p.kind == "twist") and (p.streak or 0) >= 2 then
            text = text .. strformat("  |cffffd27ax%d|r", p.streak)
        end
        o.pop:SetText(text)
        o.pop:SetTextColor(c[1], c[2], c[3])
        o.popSub:SetText(p.sub or "")
        o.popAt = now
        o.burst:SetVertexColor(c[1], c[2], c[3], 1)
        o.burstAt = (p.kind == "perfect" or p.kind == "twist") and now or nil
        if p.kind == "perfect" then
            pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856, "SFX")
        end
    elseif p.kind == "buff" then
        o.toast.icon:SetTexture(p.icon)
        o.toast.text:SetText(p.text .. "  |cffd8d8dc" .. (p.sub or "") .. "|r")
        o.toast:Show()
        o.toastAt = now
    elseif p.kind == "deny" or p.kind == "queued" then
        for _, chip in ipairs(o.chips) do
            if chip.spell == p.spell then
                chip.note:SetText(p.text)
                if p.kind == "queued" then chip.note:SetTextColor(0.6, 0.85, 1) else chip.note:SetTextColor(1, 0.45, 0.4) end
                chip.noteAt = now
            end
        end
    end
end

function PUI:OnCast(spell)
    if not overlay then return end
    for _, chip in ipairs(overlay.chips) do
        if chip.spell == spell then chip.flashAt = GetTime() end
    end
end

function PUI:EnsureOverlay()
    local ring = ns.SwingTimerHUD and ns.SwingTimerHUD:Ring()
    if not ring then return nil end
    if not overlay then overlay = BuildOverlay(ring) end
    overlay.lesson = nil
    overlay:Show()
    return overlay
end

function PUI:Overlay() return overlay end

function PUI:OnLogin()
    ns:On("SWING_PRACTICE", function(what, reason, res)
        if what == "start" then
            -- (the HUD builds its ring on SWING_STATE, fired just before)
            PUI:EnsureOverlay()
        elseif what == "stop" then
            if overlay then overlay:Hide() end
            if res then PUI:ShowResult(res)
            elseif reason == "esc" and frame then PUI:Open() end
        end
    end)
    ns:On("SWING_PRACTICE_CAST", function(spell) PUI:OnCast(spell) end)
end

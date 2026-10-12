if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SwingPracticeUI.lua", ...) then return end -- DisasterZone: twist practice UI.
-- The screens of twist practice (Core/SwingPractice.lua):
--   window     a tool window (UI:CreateWindow + the "tool" layout): the tool banner (Karazhan art, the seal, stars
--              earned as its pill, your latency as its kicker and tool), an info notice (nothing is cast), the tool
--              row (the picked lesson, Start as the main action), the lessons as rows with the shared row looks
--              (icon tile and number badge, title, goal, stars; locked ones dim with a lock) under a caps section
--              header, your keys (click one, press a key to change it) under another
--   result     the same window after a lesson: a card with stars popping in, % of a perfect run, tiles (twists,
--              early, late, missed, strikes, judgements), every Seal of Blood on the timing ruler, one tip; the
--              way back as a back link, Try again / Next lesson in the tool row
--   overlay    around the swing ring while practice runs: a coach card over it (the pop-ups' card look: lesson, what
--              to press now with your key, a pip per swing), 3-2-1-Go in the ring, a big word beside it after each
--              swing (Perfect, Early 62 ms, ...), the timing ruler and the lesson's keys under it (they light up when
--              it is their turn, shade while cooling down, and can be clicked)
-- Open with /dz swing practice or Practice on the swing timer's card in Settings > Class tools.
-- Drawn here, with no shared component for them: the timing ruler (a chart of its own), the key caps, the rating
-- stars and the ring's action keys (the game's action-button look).
local addonName, ns = ...

local PUI = ns:NewModule("SwingPracticeUI")
local S = ns.Style

local floor, max, min, sin = math.floor, math.max, math.min, math.sin
local strformat = string.format

local W = 560
local LAYOUT_W = W - 10                    -- the window's content width
local BODY_W = LAYOUT_W - 2 * S.PAD        -- the tool layout's body (530)
local ROW_H = S.ROW.art
local HEAD_H = 18                          -- a caps section header
local LESSONS_Y = HEAD_H + 4               -- the first lesson row under its header
local CHIP_H = 38
local BODY_H = LESSONS_Y + 6 * ROW_H + S.GAP + HEAD_H + 6 + CHIP_H
local H = (ns.UI.WIN_HEAD + 6) + S.PAD + S.BANNER.tool + S.GAP + 26 + S.GAP + 26 + S.GAP + BODY_H + S.PAD
local CHIP_ICON = 30
local GOLD = S.C.GOLD
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
local FREE_ICON = "Interface\\Icons\\Spell_Holy_AuraOfLight"
local KIND_RGB = {
    perfect = { 1, 0.82, 0.25 }, twist = { 0.38, 0.86, 0.46 }, early = { 1, 0.56, 0.22 }, late = { 1, 0.56, 0.22 },
    miss = { 0.95, 0.34, 0.30 }, clip = { 0.95, 0.34, 0.30 }, nocmd = { 0.95, 0.34, 0.30 },
}
local ZONE = { 1, 0.56, 0.2 }              -- the twist window on the ruler (the ring's orange)
-- (names come from the client: Seal of the Martyr for the Alliance)
local function Label(spell) return ns.SwingPractice:Label(spell) end
local function Say(text) return ns.SwingPractice:Say(text) end
-- the ruler: Seal of Blood from 0.9 s before the swing to 0.45 s after
local DMIN, DMAX = -0.9, 0.45

local function UI() return ns.UI end
local function SP() return ns.SwingPractice end
local function ST() return ns.SwingTimer end

local frame, overlay

local function LessonIcon(L)
    if L.spell == "lust" then return SP().Lust().icon end
    if L.spell == "free" then return FREE_ICON end
    return ST().ICONS[L.spell]
end

local function KeyText(k)
    if not k then return S:Wrap("BAD", "?") end
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
    UI():Fill(r, "INSET", "BACKGROUND")
    UI():AddEdges(r, "BORDER")
    UI():SetEdgeColor(r, S:Color("EDGE_QUIET"))
    local o = ST().OVERLAP
    local win = UI():Fill(r, { ZONE[1], ZONE[2], ZONE[3], 0.32 }, "BORDER")
    win:ClearAllPoints()
    win:SetPoint("TOPLEFT", r, "TOPLEFT", X(rw, -o), 0)
    win:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", X(rw, 0), 0)
    local safe = UI():Fill(r, { ZONE[1], 0.62, 0.25, 0.5 }, "BORDER", 1)
    safe:ClearAllPoints()
    safe:SetPoint("TOPLEFT", r, "TOPLEFT", X(rw, -o + 0.05), -3)
    safe:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT", X(rw, -0.05), 3)
    local swing = UI():Fill(r, "GOLD_DEEP", "ARTWORK")
    swing:ClearAllPoints()
    swing:SetWidth(2)
    swing:SetPoint("TOP", r, "TOPLEFT", X(rw, 0), 3)
    swing:SetPoint("BOTTOM", r, "BOTTOMLEFT", X(rw, 0), -3)
    if labels then
        local e = UI():Text(r, "caps", "DIM", { text = "Too early" })
        e:SetPoint("TOPLEFT", r, "BOTTOMLEFT", 0, -3)
        local w = UI():Text(r, "caps", { 1, 0.66, 0.34 }, { text = "Twist" })
        w:SetPoint("TOP", r, "BOTTOMLEFT", X(rw, -o / 2), -3)
        local s = UI():Text(r, "caps", "GOLD", { text = "Swing" })
        s:SetPoint("TOP", r, "BOTTOMLEFT", X(rw, 0) + 14, -3)
        local l = UI():Text(r, "caps", "DIM", { text = "Late" })
        l:SetPoint("TOPRIGHT", r, "BOTTOMRIGHT", 0, -3)
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
            local c = KIND_RGB[m.kind] or S.C.SUB
            local latest = i == #list
            local size = latest and min(rh - 2, 10) or min(rh - 6, 7)
            d:SetSize(size, size)
            d:ClearAllPoints()
            d:SetPoint("CENTER", self, "LEFT", X(self.rw, m.d), 0)
            local fade = keep and (0.35 + 0.65 * (i - from + 1) / max(1, #list - from + 1)) or 0.9
            d:SetVertexColor(c[1], c[2], c[3], latest and 1 or fade)
            d:Show()
        end
        UI():HideFrom(self.dots, n + 1)
    end
    return r
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window: lessons
-- ---------------------------------------------------------------------------------------------------------------
local selected

-- A lesson: the shared row looks (hover, the picked one's gold wash and bar, a hairline under it), the lesson's icon
-- in an icon tile with its number as a count badge, title and goal, its stars and best on the right.
local function NewRow(body, i)
    local row = CreateFrame("Button", nil, body)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(LESSONS_Y + (i - 1) * ROW_H))
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(LESSONS_Y + (i - 1) * ROW_H))
    UI():DecorateRow(row, { hover = true, selectable = true, rule = true })
    row.iconBox = UI():CreateIconTile(row, 34)
    row.iconBox:SetPoint("LEFT", row, "LEFT", 10, 0)
    row.icon = row.iconBox.tex
    row.num = UI():CreateCountBadge(row.iconBox, 14)
    row.num:SetPoint("CENTER", row.iconBox, "BOTTOMRIGHT", -2, 2)
    row.num:SetFrameLevel(row.iconBox:GetFrameLevel() + 2)
    row.lock = row:CreateTexture(nil, "OVERLAY")
    row.lock:SetSize(18, 18)
    row.lock:SetPoint("CENTER", row.iconBox, "CENTER")
    row.lock:SetTexture(UI().ICON_ATLAS)
    local lc = UI():IconCoords(UI().ICON.lock)
    row.lock:SetTexCoord(lc[1], lc[2], lc[3], lc[4])
    row.lock:Hide()
    row.title = UI():Text(row, "title", "TEXT")
    row.title:SetPoint("BOTTOMLEFT", row.iconBox, "RIGHT", 12, 1)
    row.goal = UI():Text(row, "body", "SUB")
    row.goal:SetPoint("TOPLEFT", row.iconBox, "RIGHT", 12, -3)
    row.goal:SetPoint("RIGHT", row, "RIGHT", -96, 0)
    row.stars = {}
    for s = 1, 3 do
        local st = UI():CreateStar(row, 16)
        st:SetPoint("RIGHT", row, "RIGHT", -12 - (3 - s) * 19, 6)
        row.stars[s] = st
    end
    row.best = UI():Text(row, "small", "DIM", { justify = "RIGHT" })
    row.best:SetPoint("TOPRIGHT", row, "RIGHT", -12, -6)
    UI():AttachTooltip(row, function(self, tt)
        if not self.L then return false end
        tt:AddLine(self.L.title, S:RGB("GOLD"))
        local sr, sg, sb = S:Color("SUB")
        if self.locked then
            tt:AddLine(strformat("Get a star in lesson %d first.", self.L.n - 1), 1, 1, 1, true)
            return
        end
        tt:AddLine(Say(self.L.intro), 1, 1, 1, true)
        local b = SP():Best(self.L.key)
        if b then tt:AddLine(strformat("Best: %d %% of a perfect run", floor((b.grade or 0) * 100 + 0.5)), sr, sg, sb, true) end
        tt:AddLine("Click: pick · Double-click: start", sr, sg, sb, true)
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
    row:SetSelected(row.selected)
    row.title:SetTextColor(S:Color(row.selected and "GOLD" or "TEXT"))
end

-- A key of the lesson: the spell's icon, its key cap and short name; click, then press the key to change it.
local function NewKeyBind(parent, spell, w)   -- (not a tag chip: a key binding control, icon + key cap)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetSize(w, CHIP_H)
    chip.spell = spell
    chip.bg = UI():Fill(chip, "INSET", "BACKGROUND")
    UI():AddEdges(chip, "BORDER")
    UI():SetEdgeColor(chip, S:Color("EDGE_QUIET"))
    UI():DecorateRow(chip, { hover = true })
    chip.tile = UI():CreateIconTile(chip, CHIP_ICON)
    chip.tile:SetPoint("LEFT", chip, "LEFT", 4, 0)
    chip.icon = chip.tile.tex
    -- the key cap, the spell's short name under it
    chip.cap = UI():CreateKeyCap(chip, 34, 18)
    chip.cap:SetPoint("TOPLEFT", chip.tile, "TOPRIGHT", 7, 0)
    chip.key = chip.cap.key
    chip.what = UI():Text(chip, "caps", "DIM")
    chip.what:SetPoint("BOTTOMLEFT", chip.tile, "BOTTOMRIGHT", 7, 0)
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
    UI():AttachTooltip(chip, function(self, tt)
        tt:AddLine(Label(self.spell), S:RGB("GOLD"))
        tt:AddLine("Click, then press the key you use for it in fights.", 1, 1, 1, true)
        local keys, auto = SP():Keys()
        local sr, sg, sb = S:Color("SUB")
        if auto[self.spell] and keys[self.spell] ~= auto[self.spell] then
            tt:AddLine("Your bars: " .. SP():Short(auto[self.spell]) .. " · Right-click: back to that", sr, sg, sb, true)
        elseif auto[self.spell] then
            tt:AddLine("Found on your action bars.", sr, sg, sb, true)
        else
            tt:AddLine("Not found on your action bars: set it here. Mouse buttons can't be caught: pick a key.",
                sr, sg, sb, true)
        end
    end)
    return chip
end

-- Your keys: a caps section header (it says what to do), then a chip per spell.
local function BuildKeys(body)
    local k = CreateFrame("Frame", nil, body)
    k:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(LESSONS_Y + 6 * ROW_H + S.GAP))
    k:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(LESSONS_Y + 6 * ROW_H + S.GAP))
    k:SetHeight(HEAD_H + 6 + CHIP_H)
    k.head = UI():CreateSectionHeader(k, "Your keys", { style = "caps" })
    k.head:SetPoint("TOPLEFT", k, "TOPLEFT", 0, 0)
    k.head:SetPoint("TOPRIGHT", k, "TOPRIGHT", 0, 0)
    k.cap = k.head.title
    k.chips = {}
    local n = #SP().SPELLS
    local cw = floor((BODY_W - (n - 1) * S.GAP) / n)
    for i, s in ipairs(SP().SPELLS) do
        local chip = NewKeyBind(k, s, cw)
        chip:SetPoint("BOTTOMLEFT", k, "BOTTOMLEFT", (i - 1) * (cw + S.GAP), 0)
        chip.icon:SetTexture(ST().ICONS[s])
        k.chips[i] = chip
    end
    return k
end

-- The tool row's main action: Start (Play for free play) on the lessons; Next lesson / Play again on a result, with
-- Try again beside it.
local START_TIP = { "The ring shows up where your swing timer sits. 3, 2, 1, then the swings start.",
    { "Esc stops. Entering combat stops it too.", "SUB" } }
local function SetMain(text, onClick, kind, tip)
    local bar = frame.layout.toolbar
    local b = bar:SetPrimary({ text = text, onClick = onClick, kind = kind or "primary", tip = tip, tipTitle = text })
    frame.keys.start = b
    return b
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window: result
-- ---------------------------------------------------------------------------------------------------------------
local TILE_W, TILE_H = 78, 50

local function BuildResult(body)
    local r = UI():CreateCard(body, { tone = "card" })
    r:SetAllPoints(body)
    r:Hide()
    r.glow = r:CreateTexture(nil, "BORDER")
    r.glow:SetTexture(SOFT)
    r.glow:SetBlendMode("ADD")
    r.glow:SetVertexColor(1, 0.75, 0.3, 0.22)
    r.glow:SetSize(360, 200)
    r.glow:SetPoint("CENTER", r, "TOP", 0, -64)
    r.back = UI():CreateBackLink(r, "All lessons", function() PUI:ShowLessons() end)
    r.back:SetPoint("TOPLEFT", r, "TOPLEFT", 12, -12)
    r.lessons = r.back
    r.cap = UI():Text(r, "caps", "SUB", { justify = "CENTER" })
    r.cap:SetPoint("TOP", r, "TOP", 0, -14)
    r.stars = {}
    for s = 1, 3 do
        local st = UI():CreateStar(r, 44)
        st:SetPoint("CENTER", r, "TOP", (s - 2) * 54, -56 + (s == 2 and 6 or 0))
        r.stars[s] = st
    end
    r.grade = UI():Text(r, 28, { 1, 1, 1 }, { justify = "CENTER" })     -- (a display numeral, above the type scale)
    r.grade:SetPoint("TOP", r, "TOP", 0, -92)
    r.gradeSub = UI():Text(r, "body", "SUB", { justify = "CENTER" })
    r.gradeSub:SetPoint("TOP", r.grade, "BOTTOM", 0, -3)
    r.best = UI():CreatePill(r, 16)
    r.best:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -10)
    r.best:Hide()
    r.tiles = {}
    for i = 1, 6 do
        local t = UI():CreateCard(r, { tone = "inset", width = TILE_W, height = TILE_H })
        t.bar = UI():Rule(t, { color = { 1, 1, 1, 1 }, size = 2, left = 1, right = 1, top = 1, layer = "ARTWORK" })
        t.num = UI():Text(t, "page", { 1, 1, 1 }, { justify = "CENTER" })
        t.num:SetPoint("TOP", t, "TOP", 0, -10)
        t.label = UI():Text(t, "caps", "SUB", { justify = "CENTER" })
        t.label:SetPoint("BOTTOM", t, "BOTTOM", 0, 8)
        r.tiles[i] = t
    end
    r.rulerHead = UI():CreateSectionHeader(r, "", { style = "caps" })
    r.rulerHead:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -212)
    r.rulerHead:SetPoint("TOPRIGHT", r, "TOPRIGHT", -16, -212)
    r.rulerCap = r.rulerHead.title
    r.ruler = NewRuler(r, BODY_W - 32, 20, true)
    r.ruler:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -234)
    r.tipHead = UI():CreateSectionHeader(r, "Try this", { style = "caps" })
    r.tipHead:SetPoint("TOPLEFT", r, "TOPLEFT", 16, -280)
    r.tipHead:SetPoint("TOPRIGHT", r, "TOPRIGHT", -16, -280)
    r.tipHead.title:SetTextColor(S:Color("GOLD"))
    r.tipCap = r.tipHead.title
    r.tip = UI():Text(r, "emph", "TEXT", { wrap = true })
    r.tip:SetPoint("TOPLEFT", r.tipHead, "BOTTOMLEFT", 0, -5)
    r.tip:SetPoint("RIGHT", r, "RIGHT", -16, 0)
    -- Try again: beside the main action in the tool row (a filter-slot button)
    r.again = UI():CreateSleekButton(frame.layout.toolbar, "Try again", 104, S.BTN_H, function()
        if r.res then selected = r.res.lesson; PUI:StartSelected() end
    end)
    frame.layout.toolbar:SetFilters({ r.again })
    r.again:Hide()
    r:SetScript("OnUpdate", function(self) PUI:AnimateResult(self) end)
    return r
end

-- The tool row's text: the picked lesson.
local function SetRowText()
    local L
    for _, l in ipairs(SP().LESSONS) do if l.key == selected then L = l end end
    if not L then frame.layout.toolbar:SetText("") return end
    frame.layout.toolbar:SetText(L.key == "free" and "Free play" or strformat("Lesson %d · %s", L.n, L.title))
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
    local blue = S.C.YOU
    local tiles = {
        { strformat("%d/%d", c.twist or 0, max(res.expected or 0, c.twist or 0)), "Twists", KIND_RGB.twist },
        { tostring(c.perfect or 0), "Perfect", KIND_RGB.perfect },
        { tostring(c.early or 0), "Early", KIND_RGB.early },
        { tostring(c.late or 0), "Late", KIND_RGB.late },
        { tostring(missed), "Missed", KIND_RGB.miss },
    }
    if L and L.keys.cs then
        tiles[#tiles + 1] = { strformat("%d/%d", c.cs or 0, max(res.ghostCs or 0, c.cs or 0)), "Strikes", blue }
    end
    if L and L.keys.judge and #tiles < 6 then
        tiles[#tiles + 1] = { strformat("%d/%d", c.judge or 0, max(res.ghostJudge or 0, c.judge or 0)), "Judgements", blue }
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
            local col = zero and S.C.DIM or d[3]
            t.bar:SetVertexColor(col[1], col[2], col[3], zero and 0.4 or 1)
            if zero then t.num:SetTextColor(S:Color("DIM")) else t.num:SetTextColor(1, 1, 1) end
            t:Show()
        else t:Hide() end
    end
    r.ruler:SetMarks(res.offsets or {})
    r.tip:SetText(SP():Tip(res))
    r.rulerHead:SetTitle("Where your " .. Label("sob") .. " landed")
    -- the next lesson: the tool row's main action (Try again beside it)
    local nextL = not res.free and SP().LESSONS[res.n + 1] or nil
    r.nextKey = nextL and SP():IsUnlocked(nextL) and nextL.key or nil
    local function goNext() if r.nextKey then selected = r.nextKey; PUI:StartSelected() end end
    if res.free then
        r.nextKey = "free"
        r.next = SetMain("Play again", goNext)
        r.again:Hide()
    elseif r.nextKey then
        r.next = SetMain(nextL.key == "free" and "Free play" or "Next lesson", goNext)
        r.again:SetText(res.stars < 1 and "Try again" or "Again")
        r.again:Show()
    else
        -- (no lesson open after it: Try again is the main action)
        r.next = SetMain(res.stars < 1 and "Try again" or "Again", function()
            if r.res then selected = r.res.lesson; PUI:StartSelected() end
        end, "secondary")
        r.again:Hide()
    end
    frame.layout.toolbar:SetText(res.free and "Free play" or strformat("Lesson %d · %s", res.n, res.title))
    for _, row in ipairs(frame.rows) do row:Hide() end
    frame.lessonsHead:Hide()
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
    frame.result.again:Hide()
    for _, st in ipairs(frame.result.stars) do st.played = nil end
    frame.lessonsHead:Show()
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
    local L = UI():CreateLayout("tool", frame.content, { width = LAYOUT_W, toolbar = true, banner = {
        size = "tool", art = "kara", icon = ST().ICONS.sob, title = "Twist practice",
        sub = "Learn the seal twist one step at a time.",
        kickerTip = { "Your latency", { "Practice delays every press by it, the way the server hears you, so the timing "
            .. "you learn here is the timing of a real fight. Settings > Class tools > Swing timer > Latency." } } } })
    frame.layout = L
    -- (the note that keys are only caught: the layout's info notice)
    L:ShowNotice("info", "Nothing is cast: your keys are caught while you practice.")
    local bn = L.banner
    -- stars earned (the banner's pill) and your latency (its kicker; its tooltip explains it)
    bn.starCount = { SetText = function(_, t) bn:SetPill("rank", t and (t .. " stars") or nil) end }
    bn.lat = { SetText = function(_, t) bn:SetKicker(t) end }
    frame.banner = bn
    local body = L.body
    frame.lessonsHead = UI():CreateSectionHeader(body, "Lessons", { style = "caps" })
    frame.lessonsHead:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    frame.lessonsHead:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    frame.rows = {}
    for i in ipairs(SP().LESSONS) do frame.rows[i] = NewRow(body, i) end
    frame.keys = BuildKeys(body)
    frame.result = BuildResult(body)
    SetMain("Start", function() PUI:StartSelected() end, "primary", START_TIP)
    ns:On("SWING_PRACTICE_KEYS", function() if frame:IsShown() then PUI:Refresh() end end)
end

function PUI:Refresh()
    if not frame then return end
    local sp = SP()
    if not selected or not sp:IsUnlocked(selected) then selected = sp:NextLesson().key end
    -- banner
    local earned, total, open = 0, 0, 0
    for _, L in ipairs(sp.LESSONS) do
        if L.key ~= "free" then
            total = total + 3
            local b = sp:Best(L.key)
            earned = earned + (b and b.stars or 0)
        end
        if sp:IsUnlocked(L) then open = open + 1 end
    end
    frame.banner.starCount:SetText(strformat("%d of %d", earned, total))
    local lat = ST():Latency() or 0
    frame.banner.lat:SetText(strformat("Your latency %d ms", floor(lat * 1000 + 0.5)))
    frame.lessonsHead:SetCount(strformat("%d of %d open", open, #sp.LESSONS))
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
        row.num:SetCount(L.key ~= "free" and i or 0)
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
            UI():SetEdgeColor(chip.cap, S:Color("GOLD"))
            chip.what:SetText("Press a key")
            chip.what:SetTextColor(S:Color("GOLD"))
        else
            chip.key:SetText(KeyText(k))
            UI():SetEdgeColor(chip.cap, S:Color(k and "EDGE_STRONG" or "BAD"))
            chip.what:SetText(SP():ShortLabel(chip.spell))
            chip.what:SetTextColor(S:Color("DIM"))
        end
        local w = UI():TextWidth(chip.key)
        chip.cap:SetWidth(max(24, min(52, w + 12)))
        if inL and not k and not missing then missing = chip.spell end
    end
    frame.keys.head:SetTitle(assigning and ("Press the key you use for " .. Label(assigning) .. " · Esc cancels")
        or missing and ("Set a key for " .. Label(missing) .. ": click it")
        or "Your keys · click one to change it")
    if assigning then frame.keys.cap:SetTextColor(S:Color("GOLD"))
    elseif missing then frame.keys.cap:SetTextColor(S:Color("BAD"))
    else frame.keys.cap:SetTextColor(S:Color("SUB")) end
    if not frame.result:IsShown() then
        SetMain(L and L.key == "free" and "Play" or "Start", function() PUI:StartSelected() end, "primary", START_TIP)
        SetRowText()
    end
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
    frame.result.again:Hide()
    frame.lessonsHead:Show()
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

    -- the coach card over the ring: the pop-ups' card (UI:CreateHudFrame "card"), carried by the overlay
    local card = UI():CreateHudFrame(nil, { width = CARD_W, height = CARD_H, look = "card", movable = false,
        position = false })
    card:SetParent(o)
    card:SetFrameLevel(o:GetFrameLevel() + 1)
    card:EnableMouse(false)
    card.cap = UI():Text(card, "caps", "GOLD")
    card.cap:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -9)
    card.count = UI():Text(card, "caps", "SUB", { justify = "RIGHT" })
    card.count:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)
    card.line = UI():Text(card, "title", { 1, 1, 1 })
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
    toast.text = UI():Text(toast, "title", "WARN", { flags = "OUTLINE" })
    toast.text:SetPoint("CENTER", 13, 0)
    toast.icon:SetPoint("RIGHT", toast.text, "LEFT", -6, 0)
    toast:Hide()
    o.toast = toast

    -- 3, 2, 1, Go in the ring (display numerals: above the type scale)
    o.count = UI():Text(o, 44, { 1, 0.9, 0.6 }, { flags = "OUTLINE", justify = "CENTER" })
    o.count:SetPoint("CENTER", ring, "CENTER", 0, 0)

    -- the word after each swing, beside the ring
    o.pop = UI():Text(o, 24, { 1, 1, 1 }, { flags = "OUTLINE" })
    o.popSub = UI():Text(o, "emph", "TEXT", { flags = "OUTLINE" })
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
        -- (an action key: the game's action-button look, its icon on a black frame)
        local chip = CreateFrame("Button", nil, o)
        chip:SetSize(40, 40)
        chip.spell = s
        local back = UI():Fill(chip, { 0, 0, 0, 1 }, "BACKGROUND")
        back:ClearAllPoints()
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
        chip.shade = UI():Fill(chip, { 0, 0, 0, 0.62 }, "ARTWORK", 1)
        chip.shade:ClearAllPoints()
        chip.shade:SetPoint("TOPLEFT")
        chip.shade:SetPoint("TOPRIGHT")
        chip.shade:SetHeight(1)
        chip.cd = UI():Text(chip, "emph", { 1, 1, 1 }, { flags = "OUTLINE", justify = "CENTER" })
        chip.cd:SetPoint("CENTER", 0, 2)
        chip.flash = UI():Fill(chip, { 1, 1, 1, 0 }, "OVERLAY")
        chip.flash:SetBlendMode("ADD")
        chip.cap = UI():CreateKeyCap(chip, 24, 16)
        chip.cap:SetPoint("TOP", chip, "BOTTOM", 0, 6)
        chip.cap:SetFrameLevel(chip:GetFrameLevel() + 2)
        chip.key = chip.cap.key
        chip.note = UI():Text(chip, "small", "BAD", { flags = "OUTLINE", justify = "CENTER" })
        chip.note:SetPoint("BOTTOM", chip, "TOP", 0, 3)
        chip:SetScript("OnClick", function(self) SP():Press(self.spell) end)
        UI():AttachTooltip(chip, function(self, tt)
            tt:AddLine(Label(self.spell), S:RGB("GOLD"))
            tt:AddLine("Press " .. SP():Short(SP().run and SP().run.keyOf[self.spell] or "") .. " (or click here).",
                1, 1, 1, true)
        end)
        o.chips[i] = chip
    end
    o.esc = UI():Text(o, "caps", "DIM", { text = "Esc stops" })
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
                p = card:CreateTexture(nil, "ARTWORK")
                p:SetTexture("Interface\\Buttons\\WHITE8X8")
                card.pips[i] = p
            end
            local pw = min(18, floor((CARD_W - 20 - (n - 1) * 3) / max(1, n)))
            p:SetSize(pw, 4)
            p:ClearAllPoints()
            local total = n * pw + (n - 1) * 3
            p:SetPoint("BOTTOMLEFT", card, "BOTTOM", -total / 2 + (i - 1) * (pw + 3), 8)
            p:SetVertexColor(S:Color("EDGE_QUIET"))
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
        return strformat("Streak %d · best %d", me.streak, me.bestStreak), S.C.TEXT
    end
    local cur = ST():Current()
    local first = cur and cur.plan.steps[1]
    if not first or first.key == "wait" then return "Wait for the next swing", S.C.SUB end
    local k = run.keyOf[first.key]
    local kt = k and (S:Wrap("GOLD", SP():Short(k)) .. "  ") or ""
    local dt = first.at - now
    if dt <= 0.05 then
        return "Now: " .. kt .. Label(first.key), { 1, 0.86, 0.45 }
    end
    if first.key == "sob" and first.twist then
        return "Next: " .. kt .. Label("sob") .. " when the ring turns orange", S.C.TEXT
    end
    if first.key == "soc" then return "Next: " .. kt .. "Seal of Command, after the swing", S.C.TEXT end
    if first.key == "judge" then return "Next: " .. kt .. "Judgement, right after the swing", S.C.TEXT end
    return "Next: " .. kt .. Label(first.key), S.C.TEXT
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
                local c = KIND_RGB[res.kind] or S.C.SUB
                p:SetVertexColor(c[1], c[2], c[3], 1)
            elseif i <= run.L.swings then
                p:SetVertexColor(S:Color("EDGE_QUIET"))
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
            text = text .. "  " .. S:Wrap("GOLD", strformat("x%d", p.streak))
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
        o.toast.text:SetText(p.text .. "  " .. S:Wrap("TEXT", p.sub or ""))
        o.toast:Show()
        o.toastAt = now
    elseif p.kind == "deny" or p.kind == "queued" then
        for _, chip in ipairs(o.chips) do
            if chip.spell == p.spell then
                chip.note:SetText(p.text)
                chip.note:SetTextColor(S:Color(p.kind == "queued" and "YOU" or "BAD"))
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

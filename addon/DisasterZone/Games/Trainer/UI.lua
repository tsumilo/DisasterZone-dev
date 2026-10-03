if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/UI.lua", ...) then return end -- DisasterZone Games/Trainer/UI.lua
-- ns.TrainerUI: the Raid Trainer's panel. A toolbar (encounter, difficulty, start), the arena drawn top-down from
-- the running sim, an action bar and the briefing / result overlay. The panel takes the keyboard only while a try
-- is running: Esc pauses and gives it back (same as Azeromon), combat pauses too.
local addonName, ns = ...

local UI = ns:NewModule("TrainerUI")
local T = ns.Trainer

local floor, min, max = math.floor, math.min, math.max

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local TOOLBAR_H, BAR_H, PAD = 30, 64, 6
local MOVE_KEYS = {
    W = "up", UP = "up", S = "down", DOWN = "down",
    A = "left", LEFT = "left", Q = "left", D = "right", RIGHT = "right", E = "right",
}

local root, arena, overlay, focusOverlay
local R = {}                 -- widgets
local unitFrames = {}        -- pool, by index
local fxFrames = {}
local zoneFrames = {}
local labelFonts = {}
local abilityButtons = {}
local held = {}
local sim, encId, diffId
local focused = false
local px = 4                 -- pixels per yard

local function Data() return ns.Games:GetData(T.GAME_ID) end

local function Encounter() return T:GetEncounter(encId) end

---------------------------------------------------------------------------
-- Focus and keys
---------------------------------------------------------------------------

local function ApplyMove()
    if not sim then return end
    local dx = (held.right and 1 or 0) - (held.left and 1 or 0)
    local dy = (held.up and 1 or 0) - (held.down and 1 or 0)
    sim:SetMove(dx, dy)
end

local function SetFocus(on)
    focused = on and true or false
    if root then
        pcall(root.EnableKeyboard, root, focused)
        focusOverlay:SetShown(not focused and sim ~= nil and sim.state == "run")
    end
    wipe(held)
    ApplyMove()
end

local ShowBriefing, ShowResult

local function StartTry(seed)
    local enc = Encounter()
    if not enc then return end
    if ns.Games:InCombat() then ns:Print("The Raid Trainer waits until you leave combat.") return end
    sim = T:NewSim(encId, diffId, seed)
    overlay:Hide()
    R.start:SetText("Restart")
    SetFocus(true)
end

local function HandleKey(key, down)
    local dir = MOVE_KEYS[key]
    if dir then
        held[dir] = down or nil
        ApplyMove()
        return true
    end
    if not down then return false end
    if key == "TAB" then
        if sim then sim:TabTarget() end
        return true
    end
    if key == "R" or ((key == "SPACE" or key == "ENTER") and not (sim and sim.state == "run")) then
        StartTry()
        return true
    end
    if sim and sim:GetAbility(key) then
        sim:Use(key)
        return true
    end
    return false
end

local function OnKeyDown(self, key)
    if key == "ESCAPE" then
        -- the first Escape pauses and lets the keyboard go; the next one reaches the client and closes the window
        SetFocus(false)
        pcall(self.SetPropagateKeyboardInput, self, false)
        return
    end
    local used = HandleKey(key, true)
    if not InCombatLockdown() and self.SetPropagateKeyboardInput then
        pcall(self.SetPropagateKeyboardInput, self, not used)
    end
end

local function OnKeyUp(self, key)
    HandleKey(key, false)
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function Place(f, x, y)
    f:ClearAllPoints()
    f:SetPoint("CENTER", arena, "BOTTOMLEFT", x * px, y * px)
end

local function UnitFrame(i)
    local f = unitFrames[i]
    if f then return f end
    f = CreateFrame("Button", nil, arena)
    f:SetFrameLevel(arena:GetFrameLevel() + 5)
    f.ring = f:CreateTexture(nil, "BACKGROUND")
    f.ring:SetTexture(DISC)
    f.ring:SetVertexColor(1, 0.85, 0.1, 0.9)
    f.ring:SetPoint("TOPLEFT", -3, 3)
    f.ring:SetPoint("BOTTOMRIGHT", 3, -3)
    f.disc = f:CreateTexture(nil, "ARTWORK")
    f.disc:SetTexture(DISC)
    f.disc:SetAllPoints()
    f.hpBg = f:CreateTexture(nil, "OVERLAY")
    f.hpBg:SetColorTexture(0, 0, 0, 0.8)
    f.hpBg:SetSize(30, 4)
    f.hpBg:SetPoint("BOTTOM", f, "TOP", 0, 3)
    f.hp = f:CreateTexture(nil, "OVERLAY", nil, 1)
    f.hp:SetColorTexture(0.8, 0.15, 0.15, 1)
    f.hp:SetHeight(4)
    f.hp:SetPoint("LEFT", f.hpBg, "LEFT", 0, 0)
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("TOP", f, "BOTTOM", 0, -1)
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.state:SetPoint("BOTTOM", f.hpBg, "TOP", 0, 1)
    f:SetScript("OnClick", function(self)
        if sim and self.unit then sim:SetTarget(self.unit) end
    end)
    unitFrames[i] = f
    return f
end

local function DrawUnits()
    local n = 0
    for _, u in ipairs(sim.units) do
        if not u.dead then
            n = n + 1
            local f = UnitFrame(n)
            f.unit = u
            local size = max(10, u.radius * 2 * px)
            f:SetSize(size, size)
            Place(f, u.x, u.y)
            local c = u.color or { 1, 1, 1 }
            local flash = u.hitAt and (sim.time - u.hitAt) < 0.12
            if flash then f.disc:SetVertexColor(1, 1, 1, 1) else f.disc:SetVertexColor(c[1], c[2], c[3], u.ghost and 0.75 or 1) end
            f.ring:SetShown(sim.target == u)
            f:EnableMouse(u.targetable and true or false)
            local showHp = u.hp ~= nil and u.targetable
            f.hpBg:SetShown(showHp)
            f.hp:SetShown(showHp)
            if showHp then f.hp:SetWidth(max(0.1, 30 * u.hp / u.hpMax)) end
            f.label:SetText((u.kind == "boss" or u.kind == "player") and u.name or "")
            local state = ""
            if sim:HasAura(u, "chains") then
                state = "|cff80b0ffChained|r"
            else
                local lance = sim:HasAura(u, "lance")
                if lance then state = string.format("|cffa0e0ffSlow x%d|r", lance.stacks) end
            end
            f.state:SetText(state)
            f:Show()
        end
    end
    for i = n + 1, #unitFrames do
        unitFrames[i].unit = nil
        unitFrames[i]:Hide()
    end
end

local function DrawZones()
    for i, z in ipairs(sim.zones) do
        local f = zoneFrames[i]
        if not f then
            f = CreateFrame("Frame", nil, arena)
            f:SetFrameLevel(arena:GetFrameLevel() + 2)
            f.disc = f:CreateTexture(nil, "BACKGROUND")
            f.disc:SetTexture(DISC)
            f.disc:SetAllPoints()
            f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            f.label:SetPoint("BOTTOM", f, "TOP", 0, 1)
            f.dots = {}
            zoneFrames[i] = f
        end
        local c = z.color or { 0.3, 0.6, 1 }
        f:SetSize(z.r * 2 * px, z.r * 2 * px)
        Place(f, z.x, z.y)
        f.disc:SetVertexColor(c[1], c[2], c[3], 0.22)
        f.label:SetText(z.label or "")
        -- the raid: a fixed sunflower of dots, so it reads as a group of players
        for d = 1, (z.dots or 0) do
            local dot = f.dots[d]
            if not dot then
                dot = f:CreateTexture(nil, "ARTWORK")
                dot:SetTexture(DISC)
                f.dots[d] = dot
            end
            local rr = z.r * 0.85 * math.sqrt(d / z.dots) * px
            local ang = d * 2.39996
            dot:SetSize(max(5, 1.6 * px), max(5, 1.6 * px))
            dot:SetVertexColor(c[1] + 0.2, c[2] + 0.2, c[3], 0.95)
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", f, "CENTER", math.cos(ang) * rr, math.sin(ang) * rr)
            dot:Show()
        end
        f:Show()
    end
    for i = #sim.zones + 1, #zoneFrames do zoneFrames[i]:Hide() end
end

local function DrawFx()
    local n = 0
    for _, fx in ipairs(sim.fx) do
        n = n + 1
        local f = fxFrames[n]
        if not f then
            f = CreateFrame("Frame", nil, arena)
            f:SetFrameLevel(arena:GetFrameLevel() + 3)
            f.disc = f:CreateTexture(nil, "ARTWORK")
            f.disc:SetTexture(DISC)
            f.disc:SetAllPoints()
            if f.CreateLine then f.line = f:CreateLine(nil, "OVERLAY") end
            fxFrames[n] = f
        end
        local k = min(1, (sim.time - fx.at) / fx.dur)
        local c = fx.color or { 1, 1, 1 }
        if fx.kind == "ring" then
            local size = fx.r * 2 * px * (0.4 + 0.6 * k)
            f:SetSize(size, size)
            Place(f, fx.x, fx.y)
            f.disc:SetVertexColor(c[1], c[2], c[3], 0.45 * (1 - k))
            f.disc:Show()
            if f.line then f.line:Hide() end
        else
            f:SetSize(1, 1)
            Place(f, fx.x, fx.y)
            f.disc:Hide()
            if f.line then
                f.line:SetThickness(3)
                f.line:SetColorTexture(c[1], c[2], c[3], 1 - k)
                f.line:SetStartPoint("BOTTOMLEFT", arena, fx.x * px, fx.y * px)
                f.line:SetEndPoint("BOTTOMLEFT", arena, fx.x2 * px, fx.y2 * px)
                f.line:Show()
            end
        end
        f:Show()
    end
    for i = n + 1, #fxFrames do fxFrames[i]:Hide() end
end

local function DrawCorpse()
    local c = sim.corpse
    R.corpse:SetShown(c ~= nil)
    if c then
        R.corpse:ClearAllPoints()
        R.corpse:SetPoint("CENTER", arena, "BOTTOMLEFT", c.x * px, c.y * px)
    end
end

local function DrawHud()
    R.objective:SetText(sim.objective or "")
    local bar = sim.bars[1]
    R.timer:SetShown(bar ~= nil)
    if bar then
        local c = bar.color or { 1, 1, 1 }
        R.timer.fill:SetColorTexture(c[1], c[2], c[3], 0.9)
        R.timer.fill:SetWidth(max(0.1, R.timer:GetWidth() * bar.remain / bar.total))
        R.timer.text:SetText(string.format("%s  %.0f", bar.label, bar.remain))
    end
    local b = sim.banner
    if b and sim.time - b.at < b.dur then
        R.banner:SetText(b.text)
        R.banner:SetTextColor(b.color[1], b.color[2], b.color[3])
        R.banner:SetAlpha(min(1, (b.dur - (sim.time - b.at)) / 0.6))
        R.banner:Show()
    else
        R.banner:Hide()
    end
    local e = sim.error
    if e and sim.time - e.at < 1.5 then
        R.error:SetText(e.text)
        R.error:Show()
    else
        R.error:Hide()
    end
    for _, btn in ipairs(abilityButtons) do
        if btn.ab then
            local remain = sim:Cooldown(btn.ab)
            local usable = not btn.ab.usable or btn.ab.usable(sim)
            btn.icon:SetDesaturated(not usable)
            btn.shade:SetShown(remain > 0 or not usable)
            btn.cd:SetText(remain >= 1.05 and string.format("%d", remain + 0.5) or "")
        end
    end
end

local function Draw()
    if not sim then return end
    DrawZones()
    DrawUnits()
    DrawFx()
    DrawCorpse()
    DrawHud()
end

local function LayoutArena()
    local enc = Encounter()
    if not (enc and root) then return end
    local w, h = root:GetWidth() or 0, root:GetHeight() or 0
    local availW, availH = w - PAD * 2, h - TOOLBAR_H - BAR_H - PAD * 3
    if availW <= 0 or availH <= 0 then return end
    px = max(1, min(availW / enc.arena.w, availH / enc.arena.h))
    arena:SetSize(enc.arena.w * px, enc.arena.h * px)
    for i, l in ipairs(enc.arena.labels or {}) do
        local fs = labelFonts[i]
        if not fs then
            fs = arena:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            labelFonts[i] = fs
        end
        fs:SetText(l.text)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", arena, "BOTTOMLEFT", l.x * px, l.y * px)
        fs:Show()
    end
    for i = #(enc.arena.labels or {}) + 1, #labelFonts do labelFonts[i]:Hide() end
    Draw()
end

local function LayoutAbilities()
    local enc = Encounter()
    local list = enc and enc.abilities or {}
    for i, ab in ipairs(list) do
        local b = abilityButtons[i]
        if not b then
            b = CreateFrame("Button", nil, R.bar)
            b:SetSize(40, 40)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            ns.UI:AddEdges(b, "OVERLAY")
            ns.UI:SetEdgeColor(b, 0, 0, 0, 1)
            b.shade = b:CreateTexture(nil, "OVERLAY")
            b.shade:SetAllPoints()
            b.shade:SetColorTexture(0, 0, 0, 0.6)
            b.cd = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            b.cd:SetPoint("CENTER")
            b.key = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            b.key:SetPoint("TOPRIGHT", -2, -2)
            b.name = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.name:SetPoint("TOP", b, "BOTTOM", 0, -2)
            b:SetScript("OnClick", function(self)
                if sim and self.ab then sim:Use(self.ab.id) end
            end)
            b:SetScript("OnEnter", function(self)
                if self.ab then ns.UI:SetTextTooltip(self, { self.ab.name .. "  (" .. self.ab.key .. ")", self.ab.tip }) end
            end)
            b:SetScript("OnLeave", function() ns.UI:HideTooltip() end)
            abilityButtons[i] = b
        end
        b.ab = ab
        b.icon:SetTexture(ab.icon)
        b.key:SetText(ab.key)
        b.name:SetText(ab.name)
        b.shade:Hide()
        b.cd:SetText("")
        b:ClearAllPoints()
        b:SetPoint("TOP", R.bar, "TOP", (i - (#list + 1) / 2) * 96, -2)
        b:Show()
    end
    for i = #list + 1, #abilityButtons do
        abilityButtons[i].ab = nil
        abilityButtons[i]:Hide()
    end
end

---------------------------------------------------------------------------
-- Briefing / result overlay
---------------------------------------------------------------------------

local function BestLine()
    local enc = Encounter()
    local rec = Data().enc and Data().enc[encId] and Data().enc[encId][diffId]
    if not (rec and rec.bestScore) then return "|cff888888No clear yet on this difficulty.|r" end
    return string.format("Best: |cffffd100%d|r points, fastest clear %.1f sec (%d of %d tries).",
        rec.bestScore, rec.bestTime or 0, rec.clears or 0, rec.tries or 0)
end

function ShowBriefing()
    local enc = Encounter()
    if not enc then return end
    overlay.title:SetText(enc.name)
    overlay.title:SetTextColor(1, 0.82, 0.2)
    local lines = {}
    for i, l in ipairs(enc.howTo or { enc.desc }) do lines[#lines + 1] = i .. ". " .. l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Move: WASD or the arrow keys. Target: Tab or click. Esc pauses."
    lines[#lines + 1] = BestLine()
    overlay.body:SetText(table.concat(lines, "\n"))
    overlay.go:SetText("Start  (Space)")
    overlay:Show()
    focusOverlay:Hide()
end

function ShowResult(score, best)
    local enc = Encounter()
    local won = sim.state == "won"
    overlay.title:SetText(won and "Constructs down!" or "Wipe")
    if enc.resultTitle then overlay.title:SetText(enc.resultTitle(sim)) end
    if won then overlay.title:SetTextColor(0.4, 0.9, 0.4) else overlay.title:SetTextColor(0.95, 0.3, 0.3) end
    local lines = {}
    if not won and sim.reason then lines[#lines + 1] = sim.reason end
    for _, l in ipairs(enc.summary and enc.summary(sim) or {}) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Score: |cffffd100%d|r%s", score, best and "  |cff5fd35fNew best!|r" or "")
    lines[#lines + 1] = BestLine()
    overlay.body:SetText(table.concat(lines, "\n"))
    overlay.go:SetText("Try again  (Space)")
    overlay:Show()
    focusOverlay:Hide()
end

local function OnUpdate(self, elapsed)
    if not sim then return end
    if sim.state == "run" and focused then
        sim:Update(elapsed)
        if sim.state ~= "run" then
            local score, best = T:Finish(sim)
            wipe(held)
            Draw()
            ShowResult(score, best)
            return
        end
    end
    Draw()
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function PickDifficulty(enc)
    local want = Data().diff and Data().diff[enc.id] or enc.defaultDifficulty
    diffId = T:GetDifficulty(enc, want).id
    if want ~= diffId and enc.defaultDifficulty then diffId = T:GetDifficulty(enc, enc.defaultDifficulty).id end
end

local function SelectEncounter(id)
    local enc = T:GetEncounter(id)
    if not enc then return end
    encId = id
    Data().last = id
    PickDifficulty(enc)
    sim = nil
    SetFocus(false)
    for _, f in ipairs(unitFrames) do f:Hide() end
    for _, f in ipairs(fxFrames) do f:Hide() end
    for _, f in ipairs(zoneFrames) do f:Hide() end
    R.corpse:Hide()
    R.timer:Hide()
    R.banner:Hide()
    R.error:Hide()
    R.objective:SetText("")
    R.start:SetText("Start")
    R.encounter:Refresh()
    R.difficulty:Refresh()
    LayoutAbilities()
    LayoutArena()
    ShowBriefing()
end

local function SelectDifficulty(id)
    local enc = Encounter()
    if not enc then return end
    diffId = T:GetDifficulty(enc, id).id
    local d = Data()
    if type(d.diff) ~= "table" then d.diff = {} end
    d.diff[enc.id] = diffId
    SelectEncounter(enc.id)
end

function UI:CreatePanel(parent)
    root = CreateFrame("Frame", nil, parent)

    R.encounter = ns.UI:CreateSleekDropdown(root, 170, function()
        local out = {}
        for _, e in ipairs(T:GetEncounters()) do out[#out + 1] = { text = e.name, value = e.id } end
        return out
    end, function() return encId end, SelectEncounter)
    R.encounter:SetPoint("TOPLEFT", PAD, -PAD)

    R.difficulty = ns.UI:CreateSleekDropdown(root, 100, function()
        local out, enc = {}, Encounter()
        for _, d in ipairs(enc and enc.difficulties or {}) do out[#out + 1] = { text = d.name, value = d.id } end
        return out
    end, function() return diffId end, SelectDifficulty)
    R.difficulty:SetPoint("LEFT", R.encounter, "RIGHT", 6, 0)

    R.start = ns.UI:CreateSleekButton(root, "Start", 80, 22, function() StartTry() end, "primary")
    R.start:SetPoint("LEFT", R.difficulty, "RIGHT", 6, 0)

    R.objective = ns.UI:CreateLabel(root, "", "GameFontHighlightSmall")
    R.objective:SetPoint("LEFT", R.start, "RIGHT", 10, 0)
    R.objective:SetPoint("RIGHT", root, "RIGHT", -PAD, 0)
    R.objective:SetJustifyH("LEFT")

    arena = CreateFrame("Frame", nil, root)
    arena:SetPoint("TOP", root, "TOP", 0, -(TOOLBAR_H + PAD))
    arena:SetSize(280, 360)
    local floorTex = arena:CreateTexture(nil, "BACKGROUND")
    floorTex:SetAllPoints()
    floorTex:SetColorTexture(0.09, 0.08, 0.11, 1)
    ns.UI:AddEdges(arena)
    ns.UI:SetEdgeColor(arena, 0.4, 0.3, 0.5, 1)
    arena:SetClipsChildren(true)

    R.corpse = arena:CreateTexture(nil, "ARTWORK")
    R.corpse:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    R.corpse:SetSize(18, 18)
    R.corpse:Hide()

    R.timer = CreateFrame("Frame", nil, arena)
    R.timer:SetFrameLevel(arena:GetFrameLevel() + 8)
    R.timer:SetSize(200, 14)
    R.timer:SetPoint("TOP", arena, "TOP", 0, -6)
    local tbg = R.timer:CreateTexture(nil, "BACKGROUND")
    tbg:SetAllPoints()
    tbg:SetColorTexture(0, 0, 0, 0.7)
    R.timer.fill = R.timer:CreateTexture(nil, "ARTWORK")
    R.timer.fill:SetPoint("LEFT")
    R.timer.fill:SetHeight(14)
    R.timer.text = R.timer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    R.timer.text:SetPoint("CENTER")
    R.timer:Hide()

    local hud = CreateFrame("Frame", nil, arena)
    hud:SetAllPoints()
    hud:SetFrameLevel(arena:GetFrameLevel() + 8)
    R.banner = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    R.banner:SetPoint("TOP", R.timer, "BOTTOM", 0, -8)
    R.banner:SetWidth(260)
    R.banner:Hide()
    R.error = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    R.error:SetTextColor(1, 0.2, 0.2)
    R.error:SetPoint("BOTTOM", arena, "BOTTOM", 0, 26)
    R.error:Hide()

    R.bar = CreateFrame("Frame", nil, root)
    R.bar:SetPoint("TOP", arena, "BOTTOM", 0, -PAD)
    R.bar:SetSize(320, BAR_H)

    -- briefing / result
    overlay = CreateFrame("Frame", nil, root)
    overlay:SetAllPoints(arena)
    overlay:SetFrameLevel(arena:GetFrameLevel() + 20)
    overlay:EnableMouse(true)
    local dim = overlay:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetColorTexture(0, 0, 0, 0.82)
    overlay.title = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    overlay.title:SetPoint("TOP", 0, -24)
    overlay.body = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    overlay.body:SetPoint("TOPLEFT", 16, -64)
    overlay.body:SetPoint("TOPRIGHT", -16, -64)
    overlay.body:SetJustifyH("LEFT")
    overlay.body:SetSpacing(4)
    overlay.go = ns.UI:CreateSleekButton(overlay, "Start  (Space)", 150, 26, function() StartTry() end, "primary")
    overlay.go:SetPoint("BOTTOM", 0, 20)

    -- paused
    focusOverlay = CreateFrame("Button", nil, root)
    focusOverlay:SetAllPoints(arena)
    focusOverlay:SetFrameLevel(arena:GetFrameLevel() + 18)
    local fdim = focusOverlay:CreateTexture(nil, "BACKGROUND")
    fdim:SetAllPoints()
    fdim:SetColorTexture(0, 0, 0, 0.55)
    local fl = focusOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fl:SetText("PAUSED")
    fl:SetPoint("CENTER")
    local fl2 = focusOverlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fl2:SetText("Click to go on. Esc pauses; Esc again closes DisasterZone.")
    fl2:SetPoint("TOP", fl, "BOTTOM", 0, -6)
    fl2:SetWidth(240)
    focusOverlay:SetScript("OnClick", function()
        if InCombatLockdown() then ns:Print("The Raid Trainer waits until you leave combat.") return end
        SetFocus(true)
    end)
    focusOverlay:Hide()

    root:SetScript("OnKeyDown", OnKeyDown)
    root:SetScript("OnKeyUp", OnKeyUp)
    root:SetScript("OnUpdate", OnUpdate)
    root:SetScript("OnSizeChanged", LayoutArena)
    root:SetScript("OnHide", function() SetFocus(false) end)
    root.OnGameShown = function() LayoutArena() end
    root.OnGameHidden = function() SetFocus(false) end

    local encs = T:GetEncounters()
    local first = T:GetEncounter(Data().last) or encs[1]
    if first then SelectEncounter(first.id) end
    return root
end

function UI:OnInit()
    ns:On("GAMES_COMBAT", function(inCombat)
        if inCombat then SetFocus(false) end
    end)
end

-- Tests
UI._Key = function(key, down) return HandleKey(key, down ~= false) end
UI._Sim = function() return sim end
UI._Start = function(seed) StartTry(seed) end
UI._Select = function(enc, diff)
    SelectEncounter(enc)
    if diff then SelectDifficulty(diff) end
end
UI._Tick = function(elapsed) if root then OnUpdate(root, elapsed) end end
UI._State = function()
    return {
        focused = focused, enc = encId, diff = diffId,
        overlay = overlay and overlay:IsShown() and overlay.title:GetText() or false,
        body = overlay and overlay:IsShown() and overlay.body:GetText() or false,
        paused = focusOverlay and focusOverlay:IsShown() or false,
        state = sim and sim.state or false, phase = sim and sim.phase or false,
    }
end

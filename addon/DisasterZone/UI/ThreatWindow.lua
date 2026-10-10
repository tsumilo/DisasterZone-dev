if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ThreatWindow.lua", ...) then return end -- DisasterZone: the threat window.
-- The on-screen part of Core/Threat.lua (the approved mockup): the enemy's portrait and name, a line about me ("You:
-- 68% · you pull at 110%"), then a bar per player with their threat as a share of the tank's on a 0..SCALE track. A
-- gold line marks where I pull (110% in melee, 130% at range), a faint one the tank, and the stretch from the warning
-- (meters.warn of my pull point) to the line is tinted red. Over the warning my bar turns red, the window's edge pulses
-- and (meters.flash) the screen edges flash.
-- Tank view: the bars are each player's share of their own pull point (the line at the end = they pull), closest
-- first, and the line about me names who is next.
local addonName, ns = ...

local TW = ns:NewModule("ThreatWindow")

local floor, max, min, abs, exp, sin = math.floor, math.max, math.min, math.abs, math.exp, math.sin
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local strformat = string.format

local HEAD_H, TOP_PAD, ROW_H, ROW_STEP = 40, 15, 19, 21
local DEFAULT_W, DEFAULT_ROWS = 312, 7
local MIN_W, MAX_W = 220, 520
local SCALE = 135                 -- the track runs from 0 to 135% of the tank's threat
local NAME_W, VALUE_W = 86, 36
local TRACK_L = 3 + 15 + 5 + NAME_W + 5
local TRACK_R = 6 + VALUE_W + 5
local FADED, FADE_AFTER = 0.38, 3
local EASE = 0.09
local LOW_HEALTH = "Interface\\FullScreenTextures\\LowHealth"

local Threat, K
local frame, flash
local rowsByKey, pool = {}, {}
local alpha, lastSeen, userHidden = 1, 0, false
local state

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end
local function Set(path, v) ns.DB:SetSetting("meters." .. path, v) end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

local function WindowMenu(owner)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateCheckbox("Lock window", function() return Setting("locked", true) end,
            function() Set("locked", not Setting("locked", true)) end)
        local tv = root:CreateButton("Tank view")
        for _, o in ipairs({ { "auto", "While I tank" }, { "always", "Always" }, { "never", "Never" } }) do
            tv:CreateRadio(o[2], function() return Setting("tankView", "auto") == o[1] end,
                function() Set("tankView", o[1]) end, o[1])
        end
        root:CreateCheckbox("Warning sound", function() return Setting("sound", true) end,
            function() Set("sound", not Setting("sound", true)) end)
        root:CreateCheckbox("Flash the screen edges", function() return Setting("flash", true) end,
            function() Set("flash", not Setting("flash", true)) end)
        root:CreateDivider()
        root:CreateButton(ns.UI:AtlasIconText(ns.UI.ICON.gear, 14) .. " Settings", function()
            if ns.MeterWindow then ns.MeterWindow.OpenSettings() end
        end)
        root:CreateButton("Hide until /dz threat", function() userHidden = true; TW:UpdateVisibility() end)
    end)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function NewRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)
    row.icon = K.Tex(row, "ARTWORK", 134400)
    row.icon:SetSize(15, 15)
    row.icon:SetPoint("LEFT", row, "LEFT", 3, 0)
    row.name = K.Font(row, K.FRIZ, 12, { 1, 1, 1 })
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
    row.name:SetWidth(NAME_W)
    row.name:SetJustifyH("LEFT")
    row.value = K.Font(row, K.NARROW, 13.5, { 1, 1, 1 })
    row.value:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.value:SetWidth(VALUE_W)
    row.value:SetJustifyH("RIGHT")
    row.track = K.Tex(row, "BACKGROUND", K.WHITE, 1, 1, 1, 0.04)
    row.track:SetPoint("TOPLEFT", row, "TOPLEFT", TRACK_L, -3)
    row.track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -TRACK_R, 3)
    row.fill = K.Tex(row, "BORDER", K.BAR)
    row.fill:SetPoint("TOPLEFT", row.track, "TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT")
    row.y, row.w = nil, 0
    return row
end

local function TakeRow(key)
    local row = rowsByKey[key]
    if row then return row, false end
    row = table.remove(pool) or NewRow(frame.rows)
    rowsByKey[key] = row
    row.y = nil
    return row, true
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function NumRows()
    local h = frame:GetHeight() or 0
    return max(2, floor((h - HEAD_H - TOP_PAD - 6 + (ROW_STEP - ROW_H)) / ROW_STEP))
end

function TW:Draw()
    if not frame then return end
    local st = Threat:GetState() or { rows = {} }
    state = st
    local h = frame.head
    local view = st.view or st.rows or {}
    local empty
    if not st.mob then
        empty = { "No target", "Target an enemy in combat to see the threat table." }
    elseif #view == 0 and not st.tankView then
        empty = { "Not in combat", "The threat table fills in once the fight starts." }
    elseif #view == 0 then
        empty = { "Only you", "Nobody else has threat on it yet." }
    end

    -- header: the enemy, and the line about me
    if st.mob and not st.demo and SetPortraitTexture then
        SetPortraitTexture(h.portrait, st.mob)
        h.portrait:SetTexCoord(0, 1, 0, 1)
        h.portraitBg:Show()
    elseif st.demo then
        h.portrait:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        h.portrait:SetVertexColor(0.22, 0.16, 0.34)
        h.portraitBg:Show()
    else
        h.portrait:SetTexture(nil)
        h.portraitBg:Hide()
    end
    -- (no enemy: the header just says Threat, the body says why it is empty)
    h.name:ClearAllPoints()
    h.name:SetPoint("TOPLEFT", h, "TOPLEFT", h.portraitBg:IsShown() and 45 or 10, st.mob and -7 or -13)
    h.name:SetPoint("RIGHT", h, "RIGHT", -30, 0)
    h.name:SetText(st.mob and (st.name or "?") or "Threat")
    local sub = ""
    local me = st.me
    if st.tankView then
        local nx = view[1]
        sub = nx and strformat("You're tanking · next: |cffecdfc8%s %d%%|r of pull", nx.name or "?", floor(nx.scaled + 0.5))
            or "You're tanking"
    elseif me then
        if st.hot then
            sub = strformat("|cffff8a70%d%% of the tank|r · you pull at %d%%", floor(me.raw + 0.5), st.pull or 110)
        else
            sub = strformat("You: |cffecdfc8%d%%|r · you pull at %d%%", floor(me.raw + 0.5), st.pull or 110)
        end
    elseif st.mob then
        sub = "You have no threat on it"
    end
    h.sub:SetText(sub)

    frame.emptyBig:SetShown(empty ~= nil)
    frame.emptySmall:SetShown(empty ~= nil)
    if empty then
        frame.emptyBig:SetText(empty[1])
        frame.emptySmall:SetText(empty[2])
    end

    -- rows
    local n = NumRows()
    local rowsW = (frame.rows:GetWidth() or 0)
    if rowsW <= 0 then rowsW = (frame:GetWidth() or DEFAULT_W) - 6 end
    local trackW = max(10, rowsW - TRACK_L - TRACK_R)
    local list = {}
    for i = 1, #view do list[i] = view[i] end
    -- my own bar stays in view
    local meIdx
    for i, r in ipairs(list) do if r.me then meIdx = i end end
    if meIdx and meIdx > n then
        local m = table.remove(list, meIdx)
        table.insert(list, n, m)
    end
    local seen = {}
    for i, r in ipairs(list) do
        local key = r.guid or r.name
        seen[key] = true
        local row, fresh = TakeRow(key)
        local cr, cg, cb = K.ClassColor(r.cls)
        K.SetPlayerIcon(row.icon, r.cls, ns.Meter and ns.Meter:SpecOf(r.name))
        row.name:SetText(r.name or "?")
        if r.me then row.name:SetTextColor(K.GOLD[1], K.GOLD[2], K.GOLD[3]) else row.name:SetTextColor(cr, cg, cb) end
        local share = st.tankView and r.scaled or r.raw
        local hot = (st.tankView and r.scaled >= (tonumber(Setting("warn", 85)) or 85)) or (r.me and st.hot)
        if hot then row.fill:SetVertexColor(1, 0.35, 0.24, 0.9) else row.fill:SetVertexColor(cr, cg, cb, 0.85) end
        row.value:SetText(floor(share + 0.5) .. "%")
        if hot then row.value:SetTextColor(1, 0.54, 0.44) else row.value:SetTextColor(1, 1, 1) end
        local frac = st.tankView and min(1, share / 100) or min(1, share / SCALE)
        row.tw = max(1, frac * trackW)
        row.ty = -(TOP_PAD + (i - 1) * ROW_STEP)
        if fresh or not row.y then row.y, row.w = row.ty, row.tw end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", 0, row.y)
        row:SetPoint("RIGHT", frame.rows, "RIGHT", 0, 0)
        row.fill:SetWidth(max(1, row.w))
        row:SetShown(i <= n)
    end
    for key, row in pairs(rowsByKey) do
        if not seen[key] then
            row:Hide()
            rowsByKey[key] = nil
            pool[#pool + 1] = row
        end
    end

    -- the pull line, the tank line, the warning stretch
    local showLines = not empty
    local lineX
    if st.tankView then lineX = TRACK_L + trackW
    else lineX = TRACK_L + trackW * min(1, (st.pull or 110) / SCALE) end
    frame.pull:SetShown(showLines and (st.tankView or me ~= nil))
    frame.pullLabel:SetShown(showLines and (st.tankView or me ~= nil))
    frame.pull:ClearAllPoints()
    frame.pull:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", lineX - 1, -(TOP_PAD - 3))
    frame.pull:SetHeight(min(#list, n) * ROW_STEP + 2)
    frame.pullLabel:SetText(st.tankView and "pulls" or "you pull")
    local tankOn = showLines and not st.tankView
    frame.tankLine:SetShown(tankOn)
    frame.tankLine:ClearAllPoints()
    frame.tankLine:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", TRACK_L + trackW * (100 / SCALE), -(TOP_PAD - 3))
    frame.tankLine:SetHeight(min(#list, n) * ROW_STEP + 2)
    local warn = (tonumber(Setting("warn", 85)) or 85) / 100
    local zoneOn = showLines and not st.tankView and me ~= nil and warn > 0
    frame.zone:SetShown(zoneOn)
    if zoneOn then
        local z0 = TRACK_L + trackW * min(1, (st.pull or 110) * warn / SCALE)
        frame.zone:ClearAllPoints()
        frame.zone:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", z0, -(TOP_PAD - 2))
        frame.zone:SetSize(max(1, lineX - z0), min(#list, n) * ROW_STEP)
    end
    frame.warn = st.hot and true or false
    if #view > 0 then lastSeen = GetTime() end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

local function Build()
    K = ns.MeterWindow.K
    frame = CreateFrame("Frame", "DisasterZoneThreat", UIParent)
    local size = Setting("tsize")
    local w = DEFAULT_W
    local h = HEAD_H + TOP_PAD + DEFAULT_ROWS * ROW_STEP + 6
    if type(size) == "table" then w, h = tonumber(size[1]) or w, tonumber(size[2]) or h end
    frame:SetSize(min(MAX_W, max(MIN_W, w)), max(HEAD_H + TOP_PAD + 2 * ROW_STEP + 6, h))
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    K.SetResizeBounds(frame, MIN_W, HEAD_H + TOP_PAD + 2 * ROW_STEP + 6, MAX_W, HEAD_H + TOP_PAD + 25 * ROW_STEP + 6)
    frame:EnableMouse(true)
    K.RestorePlace(frame, "tpos", { "BOTTOMRIGHT", "BOTTOMRIGHT", -60, 460 })
    K.Panel(frame)

    local head = CreateFrame("Button", nil, frame)
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:SetHeight(HEAD_H)
    head:RegisterForDrag("LeftButton")
    head:RegisterForClicks("RightButtonUp")
    head:SetScript("OnDragStart", function() if not Setting("locked", true) then frame:StartMoving() end end)
    head:SetScript("OnDragStop", function() frame:StopMovingOrSizing(); K.SavePlace(frame, "tpos") end)
    head:SetScript("OnClick", function(self, button) if button == "RightButton" then WindowMenu(self) end end)
    head.bg = head:CreateTexture(nil, "BACKGROUND", nil, -6)
    head.bg:SetAllPoints()
    K.Gradient(head.bg, "VERTICAL", { 0.09, 0.09, 0.11, 0.95 }, { 0.125, 0.125, 0.153, 0.95 })
    local line = K.Tex(head, "BORDER", K.WHITE, 1, 1, 1, 0.06)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    line:SetHeight(1)
    head.portraitBg = K.Tex(head, "ARTWORK", K.DISC, 0.55, 0.42, 0.13, 1, -1)
    head.portraitBg:SetSize(30, 30)
    head.portraitBg:SetPoint("LEFT", head, "LEFT", 7, 0)
    head.portrait = head:CreateTexture(nil, "ARTWORK", nil, 1)
    head.portrait:SetSize(28, 28)
    head.portrait:SetPoint("CENTER", head.portraitBg, "CENTER")
    head.name = K.Font(head, K.FRIZ, 13.5, { 1, 1, 1 })
    head.name:SetPoint("TOPLEFT", head, "TOPLEFT", 45, -7)
    head.name:SetPoint("RIGHT", head, "RIGHT", -30, 0)
    head.name:SetJustifyH("LEFT")
    head.sub = K.Font(head, K.FRIZ, 11.5, K.DIM)
    head.sub:SetPoint("TOPLEFT", head.name, "BOTTOMLEFT", 0, -3)
    head.sub:SetPoint("RIGHT", head, "RIGHT", -30, 0)
    head.sub:SetJustifyH("LEFT")
    local more = K.HeadButton(head)
    more:SetSize(22, 22)
    more:SetPoint("RIGHT", head, "RIGHT", -4, 0)
    more.icon = more:CreateTexture(nil, "ARTWORK")
    K.Glyph(more.icon, "more")
    more.icon:SetSize(14, 14)
    more.icon:SetPoint("CENTER")
    more.icon:SetVertexColor(0.62, 0.6, 0.56)
    more:SetScript("OnClick", WindowMenu)
    frame.head = head

    local rows = CreateFrame("Frame", nil, frame)
    rows:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 3, -4)
    rows:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
    if rows.SetClipsChildren then rows:SetClipsChildren(true) end
    frame.rows = rows
    -- (lines drawn over the rows: a frame of their own above them)
    local over = CreateFrame("Frame", nil, rows)
    over:SetAllPoints()
    over:SetFrameLevel(rows:GetFrameLevel() + 5)
    frame.zone = K.Tex(over, "BACKGROUND", K.WHITE)
    K.Gradient(frame.zone, "HORIZONTAL", { 1, 0.35, 0.24, 0 }, { 1, 0.35, 0.24, 0.16 })
    frame.tankLine = K.Tex(over, "ARTWORK", K.WHITE, 1, 1, 1, 0.28)
    frame.tankLine:SetWidth(1)
    frame.pull = K.Tex(over, "OVERLAY", K.WHITE, K.GOLD[1], K.GOLD[2], K.GOLD[3], 1)
    frame.pull:SetWidth(2)
    frame.pullLabel = K.Font(over, K.NARROW, 10.5, K.GOLD)
    frame.pullLabel:SetPoint("BOTTOM", frame.pull, "TOP", 0, 1)
    frame.emptyBig = K.Font(rows, K.FRIZ, 14, K.INK)
    frame.emptyBig:SetPoint("BOTTOM", rows, "CENTER", 0, 2)
    frame.emptySmall = K.Font(rows, K.FRIZ, 12, K.DIM)
    frame.emptySmall:SetPoint("TOP", rows, "CENTER", 0, -2)
    frame.emptySmall:SetWidth(DEFAULT_W - 40)
    frame.emptySmall:SetWordWrap(true)
    frame.emptySmall:SetJustifyH("CENTER")

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        K.SavePlace(frame, "tpos", "tsize")
        TW:Draw()
    end)
    frame.grip = grip
    frame.hint = K.Font(frame, K.FRIZ, 12, K.GOLD)
    frame.hint:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    frame.hint:SetText("Drag the header to move · the corner to resize")
    frame:SetScript("OnSizeChanged", function()
        frame.emptySmall:SetWidth(max(120, (frame:GetWidth() or DEFAULT_W) - 40))
    end)
    frame:SetScript("OnUpdate", function(_, elapsed) TW:OnUpdate(elapsed) end)

    -- the screen-edge flash
    flash = CreateFrame("Frame", nil, UIParent)
    flash:SetAllPoints(UIParent)
    flash:SetFrameStrata("BACKGROUND")
    flash.tex = flash:CreateTexture(nil, "BACKGROUND")
    flash.tex:SetAllPoints()
    flash.tex:SetTexture(LOW_HEALTH)
    flash.tex:SetBlendMode("ADD")
    flash.tex:SetVertexColor(1, 0.25, 0.15)
    flash:EnableMouse(false)
    flash:Hide()
    frame:Hide()
end

function TW:OnUpdate(elapsed)
    local now = GetTime()
    frame.hint:SetShown(not Setting("locked", true) and frame:IsMouseOver())
    -- the warning: the edge pulses, the screen edges flash
    local pulse = 0.5 + 0.5 * sin(now * 5.7)
    if frame.warn then
        frame:SetEdge(1, 0.36 + 0.07 * pulse, 0.3, 0.55 + 0.45 * pulse)
    elseif Setting("locked", true) then
        frame:SetEdge(1, 1, 1, 0.07)
    else
        frame:SetEdge(1, 0.82, 0, 0.55)
    end
    local flashOn = frame.warn and Setting("flash", true) and frame:IsShown()
    flash:SetShown(flashOn and true or false)
    if flashOn then flash.tex:SetAlpha(0.15 + 0.4 * pulse) end
    -- fade while there is nothing to show
    local want = 1
    if Setting("ooc", "fade") == "fade" and Setting("locked", true) and now - lastSeen > FADE_AFTER
        and not frame:IsMouseOver() and not ns.UI:GetOpenMenu() then
        want = FADED
    end
    if abs(alpha - want) > 0.005 then
        alpha = alpha + (want - alpha) * (1 - exp(-elapsed / 0.25))
        frame:SetAlpha(alpha)
    end
    -- bars glide
    local k = 1 - exp(-elapsed / EASE)
    for _, row in pairs(rowsByKey) do
        if row.ty and (abs(row.ty - row.y) > 0.3 or abs(row.tw - row.w) > 0.3) then
            row.y = row.y + (row.ty - row.y) * k
            row.w = row.w + (row.tw - row.w) * k
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", frame.rows, "TOPLEFT", 0, row.y)
            row:SetPoint("RIGHT", frame.rows, "RIGHT", 0, 0)
            row.fill:SetWidth(max(1, row.w))
        end
    end
end

---------------------------------------------------------------------------
-- Showing
---------------------------------------------------------------------------

local function ShowWanted()
    if not Threat:IsEnabled() then return false end          -- (demo mode only fills a window that is on)
    if userHidden then return false end
    if not Setting("locked", true) or Threat:IsDemo() then return true end
    local show = Setting("show", "group")
    if show == "group" and not (IsInGroup and IsInGroup()) then return false end
    if show == "instance" and not (IsInInstance and IsInInstance()) then return false end
    if Setting("ooc", "fade") == "hide" and not (UnitAffectingCombat and UnitAffectingCombat("player")) then return false end
    return true
end

function TW:UpdateVisibility()
    local want = ShowWanted()
    if want and not frame then Build() end
    if not frame then return end
    if want then
        frame.grip:SetShown(not Setting("locked", true))
        frame.hint:Hide()
        frame:SetScale(({ small = 0.9, normal = 1, large = 1.15 })[Setting("size", "normal")] or 1)
        if not frame:IsShown() then
            alpha = 1
            frame:SetAlpha(1)
            frame:Show()
        end
        self:Draw()
    else
        frame:Hide()
        if flash then flash:Hide() end
    end
end

function TW:Toggle()
    if frame and frame:IsShown() then
        userHidden = true
    else
        userHidden = false
        if not Threat:IsEnabled() then
            ns:Print("the threat meter is off: turn it on in Settings > Meters (or /dz threat on).")
            return
        end
    end
    self:UpdateVisibility()
    if frame and not userHidden and not frame:IsShown() then frame:Show(); self:Draw() end
end

function TW:GetFrame() return frame end
function TW:GetState() return state end

function TW:OnLogin()
    Threat = ns.Threat
    K = ns.MeterWindow.K
    Threat:OnChange(function()
        if frame and frame:IsShown() then TW:Draw() end
    end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and path:sub(1, 7) == "meters." then TW:UpdateVisibility() end
    end)
    ns:On("DEMO_TOGGLED", function() TW:UpdateVisibility() end)
    for _, ev in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                          "PLAYER_TARGET_CHANGED" }) do
        ns:RegisterEvent(ev, function() TW:UpdateVisibility() end)
    end
    self:UpdateVisibility()
end

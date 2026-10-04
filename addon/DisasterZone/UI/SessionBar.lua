if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SessionBar.lua", ...) then return end -- DisasterZone: UI/SessionBar.lua
-- The raid session bar (Addendum I §51): a small movable bar every raider with DisasterZone sees while the raid's
-- authority runs a session ("(live dot) Karazhan  1:42:13 · 4/11 bosses  [BIS LOCKED]"); the authority gets an End raid
-- button on it (with a confirmation). Same slim style as the encounter reminder (UI:StyleHud). It can't be closed while the session runs: only ending the raid hides it.
-- Idle state: the authority inside a raid instance with no session sees "No raid session" with a Start raid
-- button (the visible prompt; it can be dismissed until the next instance).
-- 1.2: Start raid opens a window asking what the session runs (loot distribution, rolls, the BiS lock); the
-- authority changes that later with the bar's Options button. 1.3: "loot distribution" is the loot council; loot is
-- recorded whatever runs, and the lock needs the loot council.
local addonName, ns = ...

local SessionBar = ns:NewModule("SessionBar")

local FRAME_NAME = "DisasterZoneSessionBar"
local HEIGHT = 28
local floor = math.floor

local bar
local idleDismissed = false
local elapsed = 0

local function FormatDuration(sec)
    sec = floor(math.max(0, sec or 0))
    return ("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60)
end

local function Session()
    return ns.GroupRules and ns.GroupRules.GetSession and ns.GroupRules:GetSession() or nil
end

local function IsAuthority()
    return ns.GroupRules and ns.GroupRules.IsAuthority and ns.GroupRules:IsAuthority() or false
end

-- "Karazhan · 1:42:13 · 4/11 bosses · BiS locked" for the running session.
function SessionBar:GetText()
    local s = Session()
    if not s then return "No raid session" end
    local RL = ns.RaidLog
    local rec = RL and RL:GetRaid(s.id)
    local parts = { (rec and rec.zone) or "Raid" }
    parts[#parts + 1] = FormatDuration(GetServerTime() - (s.at or GetServerTime()))
    local kills = rec and #(rec.bosses or {}) or 0
    local total = rec and RL:GetBossTotal(rec.instID)
    parts[#parts + 1] = total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses"))
    if ns.GroupRules:IsLocked() then parts[#parts + 1] = "BiS locked" end
    return table.concat(parts, " · ")
end

---------------------------------------------------------------------------
-- The Start raid window: what the raid session runs. Loot distribution and rolls are off in a raid until the raid
-- leader starts the session, and the leader picks here which of them it runs (GroupRules:IsFeatureOn). The same
-- window changes the features of a running session ("Options" on the bar). In demo mode outside a raid it opens as
-- a preview, so the flow can be shown without a raid.
---------------------------------------------------------------------------

-- 1.3: loot handed out is recorded in the loot log whatever runs; "loot" is the loot council (wire letter l as
-- before). Without it, rolls are plain (the highest roll wins) and the BiS lock has nothing to protect.
local FEATURES = {
    { key = "loot", label = "Loot council",
      tip = "The council sees who has each drop on their BiS list, votes, and rolls rank BiS lists first. "
          .. "Off: no BiS candidates or votes; rolls (when on) go to the highest roll. "
          .. "Loot handed out is recorded in the loot log either way." },
    { key = "rolls", label = "Rolls",
      tip = "The drop panel opens for the raid leader and the council to start rolls; raiders get the Roll / Pass "
          .. "popup, players without DisasterZone type /roll. Off: no roll popups." },
    { key = "lock", label = "Lock everyone's BiS lists",
      tip = "Nobody changes their BiS list while the raid runs (it unlocks when the raid ends). "
          .. "Needs the loot council." },
}

local startWin

-- What I picked the last time (everything, the first time): { loot=, rolls=, lock= }.
local function LastFeatures()
    local saved = ns.db and ns.db.settings and ns.db.settings.raidStart
    local f = {}
    for _, feat in ipairs(FEATURES) do
        f[feat.key] = type(saved) ~= "table" or saved[feat.key] ~= false
    end
    return f
end

local function CreateStartWindow()
    local UI = ns.UI
    local w = UI:CreateWindow("DisasterZoneRaidStart", "Start raid", 380, 250, { noSavePosition = true })
    local c = w.content
    w.f = LastFeatures()
    w.head = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.head:SetPoint("TOPLEFT", 14, -12)
    w.head:SetPoint("RIGHT", -14, 0)
    w.head:SetJustifyH("LEFT")
    w.boxes = {}
    for i, feat in ipairs(FEATURES) do
        local cb = UI:CreateCheckbox(c, feat.label, function() return w.f[feat.key] end,
            function(on)
                w.f[feat.key] = on and true or false
                if feat.key == "loot" then SessionBar:SyncLockBox() end
            end)
        cb:SetPoint("TOPLEFT", 14, -24 - i * 26)
        cb.tooltipText = feat.tip
        w.boxes[feat.key] = cb
    end
    w.note = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.note:SetPoint("TOPLEFT", 16, -138)
    w.note:SetPoint("RIGHT", -14, 0)
    w.note:SetJustifyH("LEFT")
    w.startBtn = UI:CreateButton(c, "Start raid", 110, 22, function() SessionBar:ConfirmStart() end)
    w.startBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    w.cancelBtn = UI:CreateButton(c, "Cancel", 80, 22, function() w:Hide() end)
    w.cancelBtn:SetPoint("BOTTOMLEFT", 10, 10)
    w:Hide()
    startWin = w
    return w
end

-- The BiS lock needs the loot council (1.3): greyed out and off while the loot council is.
function SessionBar:SyncLockBox()
    local w = startWin
    local cb = w and w.boxes and w.boxes.lock
    if not cb then return end
    local on = w.f.loot and true or false
    if not on then w.f.lock = false end
    cb:SetEnabled(on)
    if cb.label and cb.label.SetFontObject then
        cb.label:SetFontObject(on and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    cb:Refresh()
end

-- mode: "start" | "change" | "demo".
local function ShowStartWindow(mode, features)
    local w = startWin or CreateStartWindow()
    w.mode = mode
    w.f = features
    w:SetWindowTitle(mode == "change" and "Raid options" or (mode == "demo" and "Start raid (demo)" or "Start raid"))
    w.head:SetText(mode == "change" and "What this raid runs. Changes reach the raid at once."
        or "Pick what DisasterZone runs for this raid. Until you start, it leaves the council and rolls alone.")
    w.note:SetText((mode == "demo" and "Demo: this only shows the window; nothing is started.\n" or "")
        .. "Attendance, boss kills and the loot handed out are always logged.")
    w.startBtn:SetText(mode == "change" and "Apply" or "Start raid")
    for _, cb in pairs(w.boxes) do
        if cb.Refresh then cb:Refresh() end
    end
    SessionBar:SyncLockBox()
    if not w:IsShown() then
        w:ClearAllPoints()
        w:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    end
    w:Show()
    w:Raise()
    return w
end

-- The Start raid button (the bar, the Raids tab): asks what the session runs, then starts it. true when the window
-- opened.
function SessionBar:OpenStart()
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    if not IsInRaid() then
        if demo then
            ShowStartWindow("demo", LastFeatures())
            return true
        end
        ns:Print("A raid session can only run in a raid. (/dz demo on, then /dz raid options, shows the window.)")
        return false
    end
    if not IsAuthority() then
        ns:Print("Only the raid leader (the raid's loot authority) can start the raid.")
        return false
    end
    if Session() then return self:OpenOptions() end
    ShowStartWindow("start", LastFeatures())
    return true
end

-- The features of the running session (the authority); without a session the Start raid window.
function SessionBar:OpenOptions()
    if not (IsInRaid() and Session()) then return self:OpenStart() end
    if not IsAuthority() then
        ns:Print("Only the raid leader (the raid's loot authority) can change what the raid runs.")
        return false
    end
    local cur = ns.GroupRules:GetSessionFeatures() or LastFeatures()
    ShowStartWindow("change", { loot = cur.loot, rolls = cur.rolls, lock = cur.lock })
    return true
end

-- The window's Start raid / Apply button.
function SessionBar:ConfirmStart()
    local w = startWin
    if not w then return false end
    local f = { loot = w.f.loot and true or false, rolls = w.f.rolls and true or false,
                lock = (w.f.loot and w.f.lock) and true or false }
    if w.mode == "demo" then
        ns:Print("Demo: a real raid would start now with %s.", SessionBar:DescribeFeatures(f))
        w:Hide()
        return true
    end
    if ns.db and ns.db.settings then ns.db.settings.raidStart = f end
    local ok, err
    if w.mode == "change" then
        ok, err = ns.GroupRules:SetSessionFeatures(f)
        if not ok then ns:Print("%s", tostring(err)) end
    else
        ok = ns.RaidLog:Start(nil, f)
    end
    if ok then w:Hide() end
    return ok and true or false
end

function SessionBar:GetStartWindow()
    return startWin
end

-- "loot council and rolls on, BiS lists locked" / "loot council and rolls off, BiS lists open".
function SessionBar:DescribeFeatures(f)
    local on, off = {}, {}
    for _, feat in ipairs({ { "loot", "loot council" }, { "rolls", "rolls" } }) do
        local list = f[feat[1]] and on or off
        list[#list + 1] = feat[2]
    end
    local parts = {}
    if #on > 0 then parts[#parts + 1] = table.concat(on, " and ") .. " on" end
    if #off > 0 then parts[#parts + 1] = table.concat(off, " and ") .. " off" end
    parts[#parts + 1] = f.lock and "BiS lists locked" or "BiS lists open"
    return table.concat(parts, ", ")
end

local function ConfirmEnd()
    local dialogs = _G.StaticPopupDialogs
    if not (dialogs and _G.StaticPopup_Show) then
        ns.RaidLog:End()
        return
    end
    if not dialogs.DISASTERZONE_RAID_END then
        dialogs.DISASTERZONE_RAID_END = {
            text = "End the raid?\n%s\n\nThis finishes the raid log and unlocks the BiS lists.",
            button1 = "End raid",
            button2 = _G.CANCEL or "Cancel",
            OnAccept = function() ns.RaidLog:End() end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    _G.StaticPopup_Show("DISASTERZONE_RAID_END", SessionBar:GetText())
end

local function SavePosition(f)
    if not (ns.db and ns.db.settings) then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    ns.db.settings.windows = ns.db.settings.windows or {}
    ns.db.settings.windows[FRAME_NAME] = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end

local GREEN, GREY = { 0.25, 0.85, 0.35 }, { 0.55, 0.55, 0.55 }
local END_TINT, START_TINT = { 0.85, 0.22, 0.15 }, { 0.25, 0.75, 0.3 }

-- The zone and the details of the running session, apart (the bar shows the zone as its title).
function SessionBar:GetParts()
    local s = Session()
    if not s then return nil end
    local RL = ns.RaidLog
    local rec = RL and RL:GetRaid(s.id)
    local kills = rec and #(rec.bosses or {}) or 0
    local total = rec and RL:GetBossTotal(rec.instID)
    return (rec and rec.zone) or "Raid", FormatDuration(GetServerTime() - (s.at or GetServerTime())),
        total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses")),
        ns.GroupRules:IsLocked()
end

local function Create()
    if bar then return bar end
    local UI = ns.UI
    local f = CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
    f.cdlName = FRAME_NAME
    f:SetSize(360, HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    UI:StyleHud(f)

    -- a live dot, the zone, the details; a pill (BiS locked) and one flat button on the right
    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetSize(12, 12)
    f.dot:SetPoint("LEFT", 9, 0)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("LEFT", f.dot, "RIGHT", 6, 0)
    f.title:SetWordWrap(false)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.text:SetPoint("LEFT", f.title, "RIGHT", 8, 0)
    f.text:SetJustifyH("LEFT")
    f.text:SetWordWrap(false)
    f.text:SetTextColor(0.62, 0.62, 0.62)

    f.button = UI:CreateFlatButton(f, "End raid", 64, 18, function()
        if Session() then
            ConfirmEnd()
        else
            SessionBar:OpenStart()
        end
    end, END_TINT)
    f.button:SetPoint("RIGHT", -7, 0)
    f.options = UI:CreateFlatButton(f, "Options", 58, 18, function() SessionBar:OpenOptions() end)
    f.options:SetPoint("RIGHT", f.button, "LEFT", -4, 0)

    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(16, 16)
    f.close:SetPoint("RIGHT", f.button, "LEFT", -4, 0)   -- (the idle bar: Options is hidden there)
    f.close.fs = f.close:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    f.close.fs:SetPoint("CENTER")
    f.close.fs:SetText("x")
    f.close:SetScript("OnEnter", function(self) self.fs:SetFontObject("GameFontHighlight") end)
    f.close:SetScript("OnLeave", function(self) self.fs:SetFontObject("GameFontDisable") end)
    f.close:SetScript("OnClick", function()
        idleDismissed = true
        SessionBar:Update()
    end)

    f.pill = UI:CreatePill(f)

    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if self.live then self.dot:SetAlpha(0.55 + 0.45 * math.abs(math.sin(GetTime() * 2))) end
        if elapsed >= 1 then
            elapsed = 0
            SessionBar:Update()
        end
    end)
    f:SetScript("OnEnter", function(self)
        local lines = { "|cffff8000DisasterZone|r raid session" }
        local s = Session()
        if s then
            lines[#lines + 1] = "Started by " .. (ns.Util.ShortName(s.by) or "?") .. " at " .. date("%H:%M", s.at)
            lines[#lines + 1] = "Attendance and boss kills are being logged."
            local feats = ns.GroupRules:GetSessionFeatures()
            if feats then lines[#lines + 1] = "This raid: " .. SessionBar:DescribeFeatures(feats) .. "." end
            if IsAuthority() then
                lines[#lines + 1] = "Options changes what the raid runs. End the raid when you are done."
            end
        else
            lines[#lines + 1] = "The loot council and rolls stay off until you start the raid."
            lines[#lines + 1] = "Start raid asks what to run: loot council, rolls, the BiS lock."
        end
        lines[#lines + 1] = "|cff808080Drag to move.|r"
        UI:SetTextTooltip(self, lines)
    end)
    f:SetScript("OnLeave", function() UI:HideTooltip() end)

    UI:RestorePosition(f)
    local windows = ns.db and ns.db.settings and ns.db.settings.windows
    if not (type(windows) == "table" and windows[FRAME_NAME]) then
        f:ClearAllPoints()
        f:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    f:Hide()
    bar = f
    return f
end

-- "session" | "idle" | nil: what the bar shows now.
function SessionBar:GetState()
    if not IsInRaid() then return nil end
    if Session() then return "session" end
    if IsAuthority() and ns.Util.InRaidInstance() and not idleDismissed then return "idle" end
    return nil
end

function SessionBar:Update()
    local state = self:GetState()
    if not state then
        if bar then bar:Hide() end
        return
    end
    local f = Create()
    local locked = false
    if state == "session" then
        local zone, dur, bosses
        zone, dur, bosses, locked = self:GetParts()
        f.live = true
        f.dot:SetTexture("Interface\COMMON\Indicator-Green")
        f.title:SetText(zone)
        local feats = ns.GroupRules:GetSessionFeatures()
        local off = feats and ((not feats.loot and not feats.rolls and "council and rolls off")
            or (not feats.loot and "council off") or (not feats.rolls and "rolls off")) or nil
        f.text:SetText(dur .. "  \194\183  " .. bosses .. (off and ("  \194\183  " .. off) or ""))
        f.button:SetText("End raid")
        f.button:SetTint(END_TINT)
        f.button:SetShown(IsAuthority())
        f.options:SetShown(IsAuthority())
        f.close:Hide()
    else
        f.live = false
        f.dot:SetAlpha(1)
        f.dot:SetTexture("Interface\COMMON\Indicator-Gray")
        f.title:SetText("No raid session")
        f.text:SetText("council and rolls are off until you start")
        f.button:SetText("Start raid")
        f.button:SetTint(START_TINT)
        f.button:Show()
        f.options:Hide()
        f.close:Show()
    end
    -- the right side: [pill] [x] [button]
    local anchor, gap = nil, 0
    if f.button:IsShown() then anchor = f.button end
    if f.options:IsShown() then anchor = f.options end
    if f.close:IsShown() then anchor = f.close end
    f.pill:ClearAllPoints()
    if locked then
        f.pill:Set("BIS LOCKED", { 1, 0.6, 0.15 })
        if anchor then f.pill:SetPoint("RIGHT", anchor, "LEFT", -6, 0) else f.pill:SetPoint("RIGHT", -8, 0) end
        f.pill:Show()
    else
        f.pill:Hide()
    end
    local right = 10
    if f.button:IsShown() then right = right + f.button:GetWidth() + 4 end
    if f.options:IsShown() then right = right + f.options:GetWidth() + 4 end
    if f.close:IsShown() then right = right + 20 end
    if f.pill:IsShown() then right = right + f.pill:GetWidth() + 8 end
    local left = 9 + 12 + 6 + (f.title:GetStringWidth() or 60) + 8 + (f.text:GetStringWidth() or 100)
    f:SetWidth(math.max(220, floor(left + right + 8)))
    f:Show()
end

function SessionBar:ConfirmEnd()
    ConfirmEnd()
end

function SessionBar:GetFrame()
    return bar
end

function SessionBar:OnInit()
    local function update() SessionBar:Update() end
    ns:On("GROUP_RULES_CHANGED", update)
    ns:On("RAIDLOG_CHANGED", update)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", update)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        if not ns.Util.InRaidInstance() then idleDismissed = false end
        update()
    end)
end

function SessionBar:OnLogin()
    self:Update()
end

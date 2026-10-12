if DisasterZoneBoot and DisasterZoneBoot.Run("UI/SessionBar.lua", ...) then return end -- DisasterZone: UI/SessionBar.lua
-- The raid session bar (Addendum I §51): a small movable bar every raider with DisasterZone sees while the raid's
-- authority runs a session ("Karazhan  1:42:13 · 4/11 bosses  [BiS locked]"); the authority gets a gear (the raid's
-- options) and an End raid button on it (with a confirmation). The flat in-raid look: a dark bar with a soft gold edge,
-- nothing animated. It can't be closed while the session runs: only ending the raid hides it.
-- Idle state: the authority inside a raid instance with no session sees "No raid session" with a Start raid
-- button (the visible prompt; it can be dismissed until the next instance).
-- 1.2: Start raid opens a window asking what the session runs (loot distribution, rolls, the BiS lock); the
-- authority changes that later with the bar's gear. 1.3: "loot distribution" is the loot council; loot is
-- recorded whatever runs, and the lock needs the loot council.
-- 1.4: the bar is a HUD frame (UI:CreateHudFrame, the pop-ups' card look, its place kept under its old key) and the
-- Start raid window is a tool window (UI:CreateLayout "tool": the raid's banner with the one action, the switches
-- under a caps header); the end confirmation is a Popup:Confirm.
local addonName, ns = ...

local SessionBar = ns:NewModule("SessionBar")

local S = ns.Style
local FRAME_NAME = "DisasterZoneSessionBar"
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local floor = math.floor

-- (the bar's sizes: a HUD row; the controls are the compact row height)
local BAR = { H = 30, X = 11, GAP = 8, CTRL = S.ROW.compact, CTRL_GAP = 5, MIN_W = 180, W = 360 }

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
    local total = rec and RL:GetRecordBossTotal(rec)
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
    { key = "loot", label = "Loot council", desc = "BiS candidates and council votes on every drop",
      tip = "The council sees who has each drop on their BiS list, votes, and rolls rank BiS lists first. "
          .. "Off: no BiS candidates or votes; rolls (when on) go to the highest roll. "
          .. "Loot handed out is recorded in the loot log either way." },
    { key = "rolls", label = "Rolls", desc = "Roll / Pass popups for everyone in the raid",
      tip = "The drop panel opens for the raid leader and the council to start rolls; raiders get the Roll / Pass "
          .. "popup, players without DisasterZone type /roll. Off: no roll popups." },
    { key = "lock", label = "Lock everyone's BiS lists", desc = "Nobody edits their list until the raid ends",
      off = "Needs the loot council",
      tip = "Nobody changes their BiS list while the raid runs (it unlocks when the raid ends). "
          .. "Needs the loot council." },
}

-- The window: a tool window of W (its content W - 10), the switches as rich rows under a caps header (18 high).
local START = { W = 420, SWITCH_W = 34, HEAD_H = 18 }
START.H = ns.UI.WIN_HEAD + 1 + S.PAD + S.BANNER.tool + S.GAP + START.HEAD_H + S.GAP
    + #FEATURES * S.ROW.rich + (#FEATURES - 1) * S.GAP + S.GAP + 14 + S.PAD + 5

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

-- The raid the window is about: the instance I stand in (its art on the banner) and its name; nil outside a raid
-- instance.
local function CurrentRaid()
    if not (GetInstanceInfo and ns.ItemDB and ns.ItemDB.GetRaidByInstance) then return nil end
    local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    local key = ns.ItemDB:GetRaidByInstance(tonumber(instanceID))
    if not key then return nil end
    return key, name
end

-- One switch row: the switch, its name (emph) and a one-line description under it (sub).
local function NewSwitchRow(w, body, i, feat)
    local UI = ns.UI
    local key = feat.key
    local y = START.HEAD_H + S.GAP + (i - 1) * (S.ROW.rich + S.GAP)
    local row = CreateFrame("Frame", nil, body)
    row:SetHeight(S.ROW.rich)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    local get = function() return w.f[key] end
    local set = function(on)
        w.f[key] = on and true or false
        if key == "loot" then SessionBar:SyncLockBox() end
    end
    local cb = UI.CreateSwitch and UI:CreateSwitch(row, get, set) or UI:CreateCheckbox(row, "", get, set)
    cb:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
    local textX = START.SWITCH_W + 12
    local label = UI:Text(row, "emph", "TEXT", { text = feat.label })
    label:SetPoint("TOPLEFT", row, "TOPLEFT", textX, 0)
    local desc = UI:Text(row, "sub", nil, { text = feat.desc })
    desc:SetPoint("TOPLEFT", row, "TOPLEFT", textX, -17)
    desc:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    cb.label = label
    if cb.SetHitRectInsets then cb:SetHitRectInsets(-2, -((label:GetStringWidth() or 0) + 14), -3, -3) end
    cb.tooltipText = feat.tip
    -- (the checkbox fallback has its own tooltip from tooltipText)
    if UI.CreateSwitch and cb.SetHover then UI:AttachTooltip(cb, feat.label, { feat.tip }) end
    w.boxes[key], w.labels[key], w.descs[key], w.rows[key] = cb, label, desc, row
end

-- The tool window: the raid's banner (what the session is, the note, the one action: Start raid / Apply), then the
-- three switches under "This raid runs". The window's X cancels.
local function CreateStartWindow()
    local UI = ns.UI
    local w = UI:CreateWindow("DisasterZoneRaidStart", "Start raid", START.W, START.H, { noSavePosition = true })
    w.f = LastFeatures()
    w.boxes, w.labels, w.descs, w.rows = {}, {}, {}, {}
    w.layout = UI:CreateLayout("tool", w.content, {
        width = START.W - 10,
        banner = { icon = UI.ICON.crown, kicker = "Raid session", title = "Start raid" },
    })
    local body = w.layout.body
    w.head = UI:CreateSectionHeader(body, "This raid runs", { style = "caps" })
    w.head:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    w.head:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    for i, feat in ipairs(FEATURES) do NewSwitchRow(w, body, i, feat) end
    -- one quiet line under the switches: what is always logged / what Apply does / that the demo starts nothing
    w.note = UI:Text(body, "small", "DIM")
    w.note:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    w.note:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    w:Hide()
    startWin = w
    return w
end

-- The BiS lock needs the loot council (1.3): off and dimmed while the loot council is, its line says why.
function SessionBar:SyncLockBox()
    local w = startWin
    local cb = w and w.boxes and w.boxes.lock
    if not cb then return end
    local on = w.f.loot and true or false
    if not on then w.f.lock = false end
    cb:SetEnabled(on)
    if w.labels and w.labels.lock then w.labels.lock:SetTextColor(S:Color(on and "TEXT" or "DIM")) end
    if w.descs and w.descs.lock then
        for _, feat in ipairs(FEATURES) do
            if feat.key == "lock" then w.descs.lock:SetText(on and feat.desc or feat.off) end
        end
    end
    cb:Refresh()
end

-- mode: "start" | "change" | "demo".
local function ShowStartWindow(mode, features)
    local w = startWin or CreateStartWindow()
    w.mode = mode
    w.f = features
    local title = mode == "change" and "Raid options" or (mode == "demo" and "Start raid (demo)" or "Start raid")
    w:SetWindowTitle(title)
    local banner = w.layout.banner
    local raidKey, zone = CurrentRaid()
    banner:SetArt(raidKey)
    banner:SetTitle(title)
    banner:SetSub(mode == "demo" and "Demo preview" or zone or "What this raid runs")
    w.note:SetText(mode == "demo" and "Demo: this only shows the window; nothing is started."
        or (mode == "change" and "Changes reach the raid at once." or
            "Attendance, boss kills and the loot handed out are always logged."))
    banner:SetActions({ { text = mode == "change" and "Apply" or "Start raid", kind = "primary", width = 110,
                          onClick = function() SessionBar:ConfirmStart() end } })
    w.startBtn = banner.actions[1]
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
    if not IsInRaid() then
        if ns.Util.DemoOn() then
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
    if not (ns.Popup and ns.Popup.Confirm) then
        ns.RaidLog:End()
        return
    end
    ns.Popup:Confirm({
        key = "RAID_END",
        title = "End the raid",
        text = SessionBar:GetText() .. "\n\nThis finishes the raid log and unlocks the BiS lists.",
        ok = "End raid",
        onAccept = function() ns.RaidLog:End() end,
    })
end

-- The zone and the details of the running session, apart (the bar shows the zone as its title).
function SessionBar:GetParts()
    local s = Session()
    if not s then return nil end
    local RL = ns.RaidLog
    local rec = RL and RL:GetRaid(s.id)
    local kills = rec and #(rec.bosses or {}) or 0
    local total = rec and RL:GetRecordBossTotal(rec)
    return (rec and rec.zone) or "Raid", FormatDuration(GetServerTime() - (s.at or GetServerTime())),
        total and ("%d/%d bosses"):format(kills, total) or (kills == 1 and "1 boss" or (kills .. " bosses")),
        ns.GroupRules:IsLocked()
end

-- The bar's tooltip lines (built when the mouse comes).
local function BarTipLines()
    local lines = {}
    local s = Session()
    if s then
        lines[#lines + 1] = "Started by " .. (ns.Util.ShortName(s.by) or "?") .. " at " .. date("%H:%M", s.at)
        lines[#lines + 1] = "Attendance and boss kills are being logged."
        local feats = ns.GroupRules:GetSessionFeatures()
        if feats then lines[#lines + 1] = "This raid: " .. SessionBar:DescribeFeatures(feats) .. "." end
        if IsAuthority() then
            lines[#lines + 1] = "The gear changes what the raid runs. End the raid when you are done."
        end
    else
        lines[#lines + 1] = "The loot council and rolls stay off until you start the raid."
        lines[#lines + 1] = "Start raid asks what to run: loot council, rolls, the BiS lock."
    end
    lines[#lines + 1] = { "Drag to move.", "DIM" }
    return lines
end

-- A compact icon tool of the bar (the HUD's control height, the icon inset 3 px).
local function BarTool(f, icon, title, text, onClick)
    local b = ns.UI:CreateTipIconButton(f, BAR.CTRL, icon, title, text, onClick)
    b.icon:ClearAllPoints()
    b.icon:SetPoint("TOPLEFT", 3, -3)
    b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
    return b
end

local function Create()
    if bar then return bar end
    local UI = ns.UI
    -- (the place stays under the bar's frame name in settings.windows, as before 1.4)
    local f = UI:CreateHudFrame(FRAME_NAME, {
        width = BAR.W, height = BAR.H, position = FRAME_NAME, look = "card",
        -- (its default spot sits just above the pop-ups' stack, UI.TOAST.TOP: a toast never covers it)
        default = { "TOP", UIParent, "TOP", 0, ns.UI.TOAST.TOP + BAR.H + 6 },
    })
    f.cdlName = FRAME_NAME

    -- the zone (gold), the facts (grey); on the right a BiS locked pill, the tools and one button
    f.title = UI:Text(f, "title", "GOLD")
    f.title:SetPoint("LEFT", f, "LEFT", BAR.X, 0)
    f.text = UI:Text(f, "sub")
    f.text:SetPoint("LEFT", f.title, "RIGHT", BAR.GAP, 0)

    f.button = UI:CreateSleekButton(f, "End raid", 70, BAR.CTRL, function()
        if Session() then
            ConfirmEnd()
        else
            SessionBar:OpenStart()
        end
    end, "danger")
    UI:SetTextStyle(f.button:GetFontString(), "body")
    f.button:SetPoint("RIGHT", f, "RIGHT", -(BAR.H - BAR.CTRL) / 2, 0)
    f.options = BarTool(f, UI.ICON.gear, "Raid options",
        "Change what the raid runs: the loot council, rolls and the BiS lock.", function() SessionBar:OpenOptions() end)
    f.options:SetPoint("RIGHT", f.button, "LEFT", -BAR.CTRL_GAP, 0)
    -- 1.3.5: the raid's attendance (UI/AttendanceUI.lua): who left, who is not here yet
    f.att = BarTool(f, UI.ICON.team or 46, "Attendance",
        "Who left the raid and who is not here yet: tick what they said, swap someone in or leave it to the officers.",
        function() if ns.AttendanceUI then ns.AttendanceUI:ShowLeaderPrompt() end end)
    f.att:SetPoint("RIGHT", f.options, "LEFT", -BAR.CTRL_GAP, 0)

    -- (the idle bar: hide it until the next instance)
    f.close = UI:CreateIconButton(f, 16, NO_TEX, nil, function()
        idleDismissed = true
        SessionBar:Update()
    end)
    f.close.bg:SetAlpha(0)
    f.close.icon:SetDesaturated(true)
    f.close:SetPoint("RIGHT", f.button, "LEFT", -BAR.CTRL_GAP, 0)

    f.pill = UI:CreatePill(f, 18)
    f.pill:SetBase(S:Color("HUD_BG"))

    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            SessionBar:Update()
        end
    end)
    UI:AttachTooltip(f, S:Wrap("WARN", "DisasterZone") .. " raid session", BarTipLines)

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
        f.title:SetText(zone)
        f.title:SetTextColor(S:Color("GOLD"))
        local feats = ns.GroupRules:GetSessionFeatures()
        local off = feats and ((not feats.loot and not feats.rolls and "council and rolls off")
            or (not feats.loot and "council off") or (not feats.rolls and "rolls off")) or nil
        f.text:SetText(dur .. "  \194\183  " .. bosses .. (off and ("  \194\183  " .. off) or ""))
        f.button:SetText("End raid")
        f.button:SetKind("danger")
        f.button:SetWidth(70)
        f.button:SetShown(IsAuthority())
        f.options:SetShown(IsAuthority())
        f.att:SetShown(IsAuthority())
        f.close:Hide()
    else
        f.title:SetText("No raid session")
        f.title:SetTextColor(S:Color("TEXT"))
        f.text:SetText("council and rolls are off until you start")
        f.button:SetText("Start raid")
        f.button:SetKind("primary")
        f.button:SetWidth(76)
        f.button:Show()
        f.options:Hide()
        f.att:Hide()
        f.close:Show()
    end
    -- the right side, from the edge: [pill] [att] [gear | x] [button]
    local anchor
    if f.button:IsShown() then anchor = f.button end
    if f.options:IsShown() then anchor = f.options end
    if f.att:IsShown() then anchor = f.att end
    if f.close:IsShown() then anchor = f.close end
    f.pill:ClearAllPoints()
    if locked then
        f.pill:Set("BiS locked", "warn", ns.UI.ICON_LOCK)
        if anchor then f.pill:SetPoint("RIGHT", anchor, "LEFT", -BAR.GAP, 0) else f.pill:SetPoint("RIGHT", f, "RIGHT", -BAR.GAP, 0) end
        f.pill:Show()
    else
        f.pill:Hide()
    end
    local right = 0
    for _, c in ipairs({ f.button, f.options, f.att, f.close }) do
        if c:IsShown() then right = right + c:GetWidth() + BAR.CTRL_GAP end
    end
    if f.pill:IsShown() then right = right + f.pill:GetWidth() + BAR.GAP end
    local left = BAR.X + (f.title:GetStringWidth() or 60) + BAR.GAP + (f.text:GetStringWidth() or 100)
    -- (a raider's bar holds the facts alone: the same margin on both sides)
    f:SetWidth(math.max(BAR.MIN_W, floor(left + (right > 0 and (2 * BAR.GAP + right) or BAR.X))))
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

if CDLootBoot and CDLootBoot.Run("UI/SessionBar.lua", ...) then return end -- CDLoot: UI/SessionBar.lua
-- The raid session bar (Addendum I §51): a small movable bar every raider with CDLoot sees while the raid's
-- authority runs a session ("(live dot) Karazhan  1:42:13 · 4/11 bosses  [BIS LOCKED]"); the authority gets an End raid
-- button on it (with a confirmation). Same slim style as the encounter reminder (UI:StyleHud). It can't be closed while the session runs: only ending the raid hides it.
-- Idle state: the authority inside a raid instance with no session sees "No raid session" with a Start raid
-- button (the visible prompt; it can be dismissed until the next instance).
local addonName, ns = ...

local SessionBar = ns:NewModule("SessionBar")

local FRAME_NAME = "CDLootSessionBar"
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

local function ConfirmEnd()
    local dialogs = _G.StaticPopupDialogs
    if not (dialogs and _G.StaticPopup_Show) then
        ns.RaidLog:End()
        return
    end
    if not dialogs.CDLOOT_RAID_END then
        dialogs.CDLOOT_RAID_END = {
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
    _G.StaticPopup_Show("CDLOOT_RAID_END", SessionBar:GetText())
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
            ns.RaidLog:Start()
        end
    end, END_TINT)
    f.button:SetPoint("RIGHT", -7, 0)

    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(16, 16)
    f.close:SetPoint("RIGHT", f.button, "LEFT", -4, 0)
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
        local lines = { "|cffff8000CDLoot|r raid session" }
        local s = Session()
        if s then
            lines[#lines + 1] = "Started by " .. (ns.Util.ShortName(s.by) or "?") .. " at " .. date("%H:%M", s.at)
            lines[#lines + 1] = "Attendance, boss kills and awards are being logged."
            if IsAuthority() then lines[#lines + 1] = "End the raid when you are done to finish the log." end
        else
            lines[#lines + 1] = "Start a raid session to log attendance, boss kills and awards."
            lines[#lines + 1] = "Starting also locks everyone's BiS lists."
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
        f.text:SetText(dur .. "  \194\183  " .. bosses)
        f.button:SetText("End raid")
        f.button:SetTint(END_TINT)
        f.button:SetShown(IsAuthority())
        f.close:Hide()
    else
        f.live = false
        f.dot:SetAlpha(1)
        f.dot:SetTexture("Interface\COMMON\Indicator-Gray")
        f.title:SetText("No raid session")
        f.text:SetText("this raid is not being logged")
        f.button:SetText("Start raid")
        f.button:SetTint(START_TINT)
        f.button:Show()
        f.close:Show()
    end
    -- the right side: [pill] [x] [button]
    local anchor, gap = nil, 0
    if f.button:IsShown() then anchor = f.button end
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

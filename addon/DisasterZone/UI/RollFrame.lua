if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RollFrame.lua", ...) then return end -- DisasterZone UI/RollFrame.lua
-- The raider roll popup (ADDENDUM A §19.3): when a DisasterZone roll starts, everyone in the raid (or in a
-- 5-man party with dungeon mode, ADDENDUM B §22.2) gets a small group-loot style frame with the item,
-- their own BiS status and gear, a countdown and Roll / Pass. Once the item is awarded or looted it
-- shows the winner and fades (ADDENDUM C §23.3).
local addonName, ns = ...

local RollFrame = ns:NewModule("RollFrame")

local _G = _G
local CreateFrame = CreateFrame
local GetTime = GetTime
local format = string.format
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min
local ipairs, pairs, type, tonumber, tostring, pcall = ipairs, pairs, type, tonumber, tostring, pcall

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------
local FRAME_NAME = "DisasterZoneRollFrame"
local FRAME_W, FRAME_H = 400, 82
local DEFAULT_POINT, DEFAULT_Y = "TOP", -228   -- (under the BiS toast)
local PAD = 14
local ICON_SIZE, WEAR_SIZE = 40, 16
local TEXT_X = PAD + ICON_SIZE + 12
local ROLL_W, PASS_W, BTN_H = 60, 52, 24
local MID_Y = 46                          -- the buttons' (and my answer's) middle, from the top: beside lines 2-3
local STATUS_W = 126
local NAME_W = FRAME_W - TEXT_X - 26       -- the item's name runs to the X
local TEXT_W = FRAME_W - TEXT_X - PAD - ROLL_W - 6 - PASS_W - 12
local BG = { 0.043, 0.043, 0.051 }
local PIP_MAX, PIP_SIZE = 5, 7    -- a crafting material: the holdings squares
local NO_TEX = "Interface\\RaidFrame\\ReadyCheck-NotReady"
local TICK = 0.1                 -- countdown bar refresh while a roll is open
local FADE_AFTER_AWARD = 5       -- seconds the result stays before fading out
local FADE_AFTER_CANCEL = 3
local LINGER_AFTER_CLOSE = 45    -- "Rolls closed" without an award: fade after this long
local FADE_TIME = 1
local RESUME_AFTER_LEAVE = 1     -- a fade held by the mouse resumes this long after it left the popup
local HOVER_POLL = 0.2           -- how often a held fade checks whether the mouse is still over it
local RESPONDED_MAX = 100        -- remembered own responses (session ids), cleared beyond this

local BAR_TEXTURE = "Interface\\Buttons\\WHITE8X8"

local SLOT_GROUP_FALLBACK = {
    [11] = { 11, 12 }, [12] = { 11, 12 }, [13] = { 13, 14 }, [14] = { 13, 14 }, [15] = { 15, 16 }, [16] = { 15, 16 },
}

local FALLBACK_COLORS = {
    main     = { 0.98, 0.78, 0.22 },
    alt      = { 0.41, 0.80, 0.94 },
    obtained = { 0.30, 0.90, 0.40 },
    muted    = { 0.55, 0.55, 0.55 },
    warn     = { 1.00, 0.55, 0.20 },
    bad      = { 1.00, 0.30, 0.30 },
}

---------------------------------------------------------------------------
-- Helpers (nil-safe: other modules may be missing or not ready)
---------------------------------------------------------------------------
local function Color(key)
    local c = ns.COLORS and ns.COLORS[key]
    return c or FALLBACK_COLORS[key] or FALLBACK_COLORS.muted
end

local function Paint(text, key)
    local c = Color(key)
    return format("|cff%02x%02x%02x%s|r", floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5),
        floor(c[3] * 255 + 0.5), text)
end

local function Setting(path, default)
    if ns.db and ns.DB and ns.DB.GetSetting then
        local v = ns.DB:GetSetting(path)
        if v ~= nil then return v end
    end
    return default
end

local function DemoEnabled()
    return (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) and true or false
end

-- Dungeon mode (ADDENDUM B §22.1): a 5-man party that shares drops and rolls. Guarded: older cores
-- have no Util.IsDungeonModeActive.
local function DungeonModeActive()
    local fn = ns.Util and ns.Util.IsDungeonModeActive
    if type(fn) ~= "function" then return false end
    local ok, active = pcall(fn)
    return (ok and active) and true or false
end

-- The popup shows in a raid, in a dungeon-mode party and in demo mode.
local function InRaidOrDemo()
    return (_G.IsInRaid and _G.IsInRaid()) or DemoEnabled() or DungeonModeActive()
end

local function PlayerKey()
    return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil
end

local function IsMe(key)
    return ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) or false
end

local function ShortName(key)
    if type(key) ~= "string" then return "?" end
    if ns.Util and ns.Util.ShortName then return ns.Util.ShortName(key) or key end
    return key
end

local function ColoredName(key)
    if type(key) ~= "string" then return "?" end
    if ns.UI and ns.UI.ColoredName then return ns.UI:ColoredName(key) .. ns.UI:GuestTag(key) end
    return ShortName(key)
end

local function ItemText(itemID)
    if ns.UI and ns.UI.ItemText then
        local text = ns.UI:ItemText(itemID)   -- drop the extra "loading" return value
        return text
    end
    return (ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(itemID)) or ("item " .. tostring(itemID))
end

local function ItemIcon(itemID)
    if ns.ItemDB and ns.ItemDB.GetIcon then return ns.ItemDB:GetIcon(itemID) end
    return 134400
end

local function SlotLabel(sid)
    local s = ns.SLOTS and ns.SLOTS[sid]
    return s and s.label or "?"
end

local function SlotGroup(sid)
    sid = tonumber(sid)
    if not sid then return nil end
    local g = ns.SLOT_GROUP and ns.SLOT_GROUP[sid]
    if type(g) == "table" and #g > 0 then return g end
    return SLOT_GROUP_FALLBACK[sid] or { sid }
end

local function HideTooltip()
    _G.GameTooltip:Hide()
end

local function Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
    return fs
end

local function Text(parent, font, size)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then Sized(fs, size) end
    return fs
end

-- The item's name: 13 px, smaller when a long name would not fit.
local function FitName(fs, text, width)
    for _, size in ipairs({ 13, 12, 11 }) do
        Sized(fs, size)
        fs:SetText(text)
        if (fs:GetStringWidth() or 0) <= width then return end
    end
end

-- Calls ns.Roll:<method>(...) if it exists. An error inside Roll is reported once per method and the
-- popup keeps working (a broken popup must never block the raid).
local reported = {}
local function CallRoll(method, ...)
    local R = ns.Roll
    local fn = R and R[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, R, ...)
    if ok then return a, b end
    if not reported[method] then
        reported[method] = true
        local handler = _G.geterrorhandler and _G.geterrorhandler()
        if handler then handler(a) end
    end
    ns:Debug("Roll:%s failed: %s", method, tostring(a))
    return nil
end

local function FormatLeft(sec)
    sec = max(0, ceil((tonumber(sec) or 0) - 0.05))
    return format("%d:%02d", floor(sec / 60), sec % 60)
end

-- Best own BiS match for the popup: the first one not obtained yet, else the first one.
local function OwnMatch(itemID)
    if not (ns.BiS and ns.BiS.MatchItem) then return nil end
    local matches = ns.BiS:MatchItem(itemID)
    if type(matches) ~= "table" then return nil end
    local first
    for _, m in ipairs(matches) do
        if type(m) == "table" then
            first = first or m
            if not m.obtained then return m end
        end
    end
    return first
end

-- What the item is to me: the pill's text and kind (nil: not on my lists) and the line after it ("Head · P1").
local function OwnStatus(m)
    if not m then return nil, nil, "Not on your BiS list" end
    local parts = { SlotLabel(m.sid), "P" .. tostring(tonumber(m.phase) or 0) }
    local text, kind
    if m.os then
        -- Addendum H: only on my off-spec list.
        text, kind = "OS", "os"
        local sp = ns.BiS.GetSpec and ns.BiS:GetSpec("os") or ""
        if sp ~= "" then parts[#parts + 1] = sp end
    elseif m.which == "alt" then
        text, kind = "Alt", "alt"
    else
        text, kind = "BiS", "bis"
    end
    if m.via then parts[#parts + 1] = (ns.VIA_TEXT and ns.VIA_TEXT[m.via]) or "via token" end
    local detail = table.concat(parts, " \194\183 ")
    if m.obtained then detail = detail .. Paint(" \194\183 obtained", "obtained") end
    return text, kind, detail
end

-- The slot group whose currently worn items the popup shows.
local function ItemSlotGroup(itemID, m)
    if m and m.sid then return SlotGroup(m.sid) end
    local sids = ns.ItemDB and ns.ItemDB.GetSlotsForItem and ns.ItemDB:GetSlotsForItem(itemID)
    if type(sids) == "table" and sids[1] then return SlotGroup(sids[1]) end
    return nil
end

---------------------------------------------------------------------------
-- Position (saved like ns.UI windows: settings.windows[name] = { point, relPoint, x, y })
---------------------------------------------------------------------------
local function SavePosition(f)
    if not (ns.db and ns.db.settings) then return end
    local point, _, relPoint, x, y = f:GetPoint(1)
    if not point then return end
    if type(ns.db.settings.windows) ~= "table" then ns.db.settings.windows = {} end
    ns.db.settings.windows[FRAME_NAME] = { point, relPoint or point, floor((x or 0) + 0.5), floor((y or 0) + 0.5) }
end

local function RestorePosition(f)
    f:ClearAllPoints()
    local windows = ns.db and ns.db.settings and ns.db.settings.windows
    local pos = type(windows) == "table" and windows[FRAME_NAME]
    if type(pos) == "table" and type(pos[1]) == "string" then
        local ok = pcall(f.SetPoint, f, pos[1], _G.UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
        if ok then return end
        f:ClearAllPoints()
    end
    f:SetPoint(DEFAULT_POINT, _G.UIParent, DEFAULT_POINT, 0, DEFAULT_Y)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
function RollFrame:OnInit()
    self.responded = {}    -- [sessionID] = "roll" | "pass" (clicked here; the session may lag behind)
    self.respondedCount = 0

    ns:On("ROLL_STARTED", function(session) RollFrame:OnRollStarted(session) end)
    ns:On("ROLL_UPDATED", function(id) RollFrame:OnRollUpdated(id) end)
    ns:On("ITEMINFO_READY", function() RollFrame:RefreshItem() end)
    ns:On("OWNED_UPDATED", function() RollFrame:RefreshItem() end)
    ns:On("MYLIST_CHANGED", function() RollFrame:RefreshItem() end)
    ns:On("MATERIALS_UPDATED", function() RollFrame:RefreshItem() end)
    ns:On("SETTINGS_CHANGED", function(key)
        if key == "roll.popup" and not Setting("roll.popup", true) then RollFrame:Hide() end
    end)
    ns:On("DEMO_TOGGLED", function()
        if not InRaidOrDemo() then RollFrame:Hide() end
    end)
    ns:On("GROUP_UPDATED", function()
        if not InRaidOrDemo() then RollFrame:Hide() end
    end)
    ns:On("DUNGEON_MODE_CHANGED", function()
        if not InRaidOrDemo() then RollFrame:Hide() end
    end)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function WearOnEnter(self)
    if not self.itemID then return end
    local tt = _G.GameTooltip
    tt:SetOwner(self, "ANCHOR_RIGHT")
    local shown = false
    if self.invSlot and tt.SetInventoryItem then
        shown = tt:SetInventoryItem("player", self.invSlot) and true or false
    end
    if not shown then tt:SetItemByID(self.itemID) end
    tt:AddLine("Currently wearing (" .. tostring(self.label or "?") .. ")", 0.6, 0.6, 0.6)
    tt:Show()
end

local function WearOnClick(self)
    if self.itemID and ns.UI and ns.UI.HandleModifiedItemClick then
        ns.UI:HandleModifiedItemClick(self.itemID)
    end
end

local function NewWearButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(WEAR_SIZE, WEAR_SIZE)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b:SetScript("OnEnter", WearOnEnter)
    b:SetScript("OnLeave", HideTooltip)
    b:SetScript("OnClick", WearOnClick)
    b:Hide()
    return b
end

-- text: a string, or a function returning one (read when the tooltip opens).
local function ButtonTooltip(btn, text)
    btn:HookScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        _G.GameTooltip:AddLine(type(text) == "function" and text() or text, 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    btn:HookScript("OnLeave", HideTooltip)
end

function RollFrame:GetFrame()
    if self.frame then return self.frame end
    local UI = ns.UI
    -- The look of the Dungeons tab's ping: a dark card with a gold edge. The item and what it is to me on the left,
    -- Roll / Pass on the right (my result once I answered), the time left as a thin bar along the bottom.
    local f = CreateFrame("Frame", FRAME_NAME, _G.UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(frame) frame:StartMoving() end)
    f:SetScript("OnDragStop", function(frame)
        frame:StopMovingOrSizing()
        SavePosition(frame)
    end)
    f:Hide()
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(BG[1], BG[2], BG[3], 0.95)
    UI:AddEdges(f, "BORDER")
    UI:SetEdgeColor(f, 1, 0.82, 0, 0.55)
    self.frame = f
    RestorePosition(f)

    f.item = UI:CreateItemButton(f, ICON_SIZE)
    f.item:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -14)

    f.close = UI:CreateIconButton(f, 16, NO_TEX, nil, function() RollFrame:Dismiss() end)
    f.close.bg:SetAlpha(0)
    f.close.icon:SetDesaturated(true)
    f.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)

    f.name = Text(f, "GameFontNormal", 13)
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -13)
    f.name:SetWidth(NAME_W)

    -- what the item is to me: a BiS / Alt / OS pill and where it goes ("Head · P1"), or "Not on your BiS list"
    f.bisPill = UI:CreateTagPill(f, 16)
    f.bisPill:SetBase(BG[1], BG[2], BG[3])
    f.bisPill:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -30)
    f.bisPill:Hide()
    f.bis = Text(f, "GameFontHighlightSmall", 11)
    f.bis:SetTextColor(0.62, 0.62, 0.62)

    -- a crafting material: "for Belt of Blasting" is a button when more than one craft on my lists uses it (pick the
    -- one I want it for), and the wearing line becomes my holdings: squares + "You have 1 of 2 · completes it"
    f.forBtn = CreateFrame("Button", nil, f)
    f.forBtn:SetScript("OnClick", function(self) RollFrame:OpenCraftMenu(self) end)
    f.forBtn:SetScript("OnEnter", function(self)
        _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
        _G.GameTooltip:AddLine("Click: pick the craft you want it for (the council sees your pick)", 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    f.forBtn:SetScript("OnLeave", HideTooltip)
    f.forBtn:Hide()
    f.pips = {}
    for i = 1, PIP_MAX do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(PIP_SIZE, PIP_SIZE)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X + (i - 1) * (PIP_SIZE + 2), -56)
        t:Hide()
        f.pips[i] = t
    end

    f.wearLabel = Text(f, "GameFontHighlightSmall", 11)
    f.wearLabel:SetTextColor(0.62, 0.62, 0.62)
    f.wearLabel:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -54)
    f.wearLabel:SetText("Wearing:")
    f.wear = { NewWearButton(f), NewWearButton(f) }
    f.wear[1]:SetPoint("LEFT", f.wearLabel, "RIGHT", 5, 0)
    f.wear[2]:SetPoint("LEFT", f.wear[1], "RIGHT", 3, 0)

    f.pass = UI:CreateButton(f, _G.PASS or "Pass", PASS_W, BTN_H, function() RollFrame:DoPass() end)
    f.pass:SetPoint("RIGHT", f, "TOPRIGHT", -PAD, -MID_Y)
    ButtonTooltip(f.pass, "Pass on this item.")
    f.roll = UI:CreateSleekButton(f, "Roll", ROLL_W, BTN_H, function() RollFrame:DoRoll() end, "primary")
    f.roll:SetPoint("RIGHT", f.pass, "LEFT", -6, 0)
    ButtonTooltip(f.roll, function()
        -- 1.3: a plain roll (the raid runs without the loot council): the highest roll, the master looter confirms
        local s = RollFrame:GetSession()
        if type(s) == "table" and s.plain then
            return "Roll 1-100 (a normal /roll). The loot council is off for this raid: the highest roll is "
                .. "suggested (BiS lists don't count). The master looter confirms."
        end
        return "Roll 1-100 (a normal /roll). DisasterZone suggests the winner: BiS main first, "
            .. "then BiS alt, then everyone else; the highest roll wins within each group. The council confirms."
    end)

    -- my answer, where the buttons were (two lines at most)
    f.status = Text(f, "GameFontNormal", 12)
    f.status:SetPoint("RIGHT", f, "TOPRIGHT", -PAD, -MID_Y)
    f.status:SetWidth(STATUS_W)
    f.status:SetJustifyH("RIGHT")
    f.status:SetWordWrap(true)
    if f.status.SetMaxLines then f.status:SetMaxLines(2) end

    -- the time left: a thin bar along the bottom edge and the seconds under the buttons
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
    bar:SetHeight(3)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetStatusBarColor(1, 0.82, 0)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints(bar)
    bar.bg:SetColorTexture(1, 1, 1, 0.06)
    f.bar = bar
    f.timeText = Text(f, "GameFontHighlightSmall", 11)
    f.timeText:SetTextColor(0.62, 0.62, 0.62)
    f.timeText:SetJustifyH("RIGHT")
    f.timeText:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(MID_Y + BTN_H / 2 + 5))

    local ag = f:CreateAnimationGroup()
    local fade = ag:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0)
    fade:SetDuration(FADE_TIME)
    ag:SetScript("OnFinished", function()
        f:Hide()
        f:SetAlpha(1)
    end)
    -- The mouse came back while fading (possibly straight onto a child button, which gives the frame no
    -- OnEnter): hold the fade.
    ag:SetScript("OnUpdate", function()
        if f.IsMouseOver and f:IsMouseOver() then RollFrame:HoldFade() end
    end)
    f.fadeAnim = ag

    -- Hovering pauses the fade only while the mouse is over the popup (§23.3).
    f:SetScript("OnEnter", function() RollFrame:OnMouseEnter() end)
    f:SetScript("OnLeave", function() RollFrame:OnMouseLeave() end)
    f:SetScript("OnHide", function()
        RollFrame.mouseInside = false
        RollFrame:StopTimers()
    end)
    return f
end

function RollFrame:ResetPosition()
    if ns.db and ns.db.settings and type(ns.db.settings.windows) == "table" then
        ns.db.settings.windows[FRAME_NAME] = nil
    end
    if self.frame then RestorePosition(self.frame) end
end

---------------------------------------------------------------------------
-- Timers
---------------------------------------------------------------------------
function RollFrame:StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- A fade that is due but held by the mouse ends here (the popup stays).
function RollFrame:StopHold()
    if self.holdTicker then
        self.holdTicker:Cancel()
        self.holdTicker = nil
    end
    self.fadeHeld = false
    self.leftAt = nil
end

function RollFrame:CancelFade()
    if self.fadeTimer then
        self.fadeTimer:Cancel()
        self.fadeTimer = nil
    end
    self:StopHold()
    local f = self.frame
    if f and f.fadeAnim and f.fadeAnim:IsPlaying() then f.fadeAnim:Stop() end
    if f then f:SetAlpha(1) end
end

function RollFrame:StopTimers()
    self:StopTicker()
    if self.fadeTimer then
        self.fadeTimer:Cancel()
        self.fadeTimer = nil
    end
    self:StopHold()
    self.fadeFor = nil
end

-- Fades the popup out after `seconds` (only schedules once per state). A new state (e.g. "closed" ->
-- "awarded") restarts the countdown, also when a fade was already running or held.
function RollFrame:ScheduleFade(seconds, reason)
    if self.fadeFor == reason then return end
    if self.fadeTimer then self.fadeTimer:Cancel() end
    self:StopHold()
    local f = self.frame
    if f and f.fadeAnim and f.fadeAnim:IsPlaying() then f.fadeAnim:Stop() end
    if f then f:SetAlpha(1) end
    self.fadeFor = reason
    self.fadeTimer = C_Timer.NewTimer(seconds, function()
        RollFrame.fadeTimer = nil
        RollFrame:StartFade()
    end)
end

-- True while the mouse is over the popup or one of its buttons.
function RollFrame:IsHovered()
    local f = self.frame
    if not f or not f:IsShown() then return false end
    if self.mouseInside then return true end
    return (f.IsMouseOver and f:IsMouseOver()) and true or false
end

function RollFrame:StartFade()
    local f = self.frame
    if not f or not f:IsShown() then return end
    if self:IsHovered() then
        self:HoldFade()
        return
    end
    f.fadeAnim:Play()
end

-- The fade is due (or running) but the mouse is on the popup: keep it fully visible and poll until the
-- mouse has been away for RESUME_AFTER_LEAVE seconds, then fade.
function RollFrame:HoldFade()
    local f = self.frame
    if not f then return end
    if f.fadeAnim and f.fadeAnim:IsPlaying() then f.fadeAnim:Stop() end
    f:SetAlpha(1)
    self.fadeHeld = true
    if self:IsHovered() then
        self.leftAt = nil
    elseif not self.leftAt then
        self.leftAt = GetTime()
    end
    if not self.holdTicker then
        self.holdTicker = C_Timer.NewTicker(HOVER_POLL, function() RollFrame:CheckHold() end)
    end
end

function RollFrame:CheckHold()
    local f = self.frame
    if not self.fadeHeld or not f or not f:IsShown() then
        self:StopHold()
        return
    end
    if self:IsHovered() then
        self.leftAt = nil
        return
    end
    local now = GetTime()
    if not self.leftAt then
        self.leftAt = now     -- left over a child button (no OnLeave on the frame itself)
        return
    end
    if now - self.leftAt >= RESUME_AFTER_LEAVE - 0.01 then
        self:StopHold()
        f.fadeAnim:Play()
    end
end

function RollFrame:OnMouseEnter()
    self.mouseInside = true
    self.leftAt = nil
    local f = self.frame
    if f and f.fadeAnim and f.fadeAnim:IsPlaying() then self:HoldFade() end
end

function RollFrame:OnMouseLeave()
    self.mouseInside = false
    if self.fadeHeld then self.leftAt = GetTime() end
end

function RollFrame:EnsureTicker()
    if self.ticker then return end
    self.ticker = C_Timer.NewTicker(TICK, function() RollFrame:UpdateTimer() end)
end

---------------------------------------------------------------------------
-- Sessions
---------------------------------------------------------------------------
function RollFrame:GetSession()
    local id = self.sessionID
    if not id then return nil end
    local s = CallRoll("Get", id)
    if type(s) == "table" then
        self.session = s
        return s
    end
    return self.session
end

function RollFrame:GetSessionID()
    return self.sessionID
end

function RollFrame:OnRollStarted(session)
    if type(session) == "string" then session = CallRoll("Get", session) end
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    if not Setting("roll.popup", true) or not InRaidOrDemo() then return end
    if session.state ~= nil and session.state ~= "open" then return end
    self:ShowSession(session)
end

-- A session the popup is not showing was awarded to me (Roll all: the next item's popup replaced it before the
-- award): say so once in chat, and bring the popup back when it is free.
function RollFrame:TellWinOfOtherSession(id)
    local s = CallRoll("Get", id)
    if type(s) ~= "table" or s.state ~= "awarded" or not IsMe(s.winner) then return end
    self.wonTold = self.wonTold or {}
    if self.wonTold[id] then return end
    self.wonTold[id] = true
    self.wonToldCount = (self.wonToldCount or 0) + 1
    if self.wonToldCount > RESPONDED_MAX then
        self.wonTold, self.wonToldCount = { [id] = true }, 1
    end
    ns:Print("%s", Paint("You won ", "main") .. ItemText(tonumber(s.i)) .. Paint("!", "main"))
    local kit, play = _G.SOUNDKIT, _G.PlaySound
    if kit and play and kit.RAID_WARNING then pcall(play, kit.RAID_WARNING) end
    local f = self.frame
    if not (f and f:IsShown()) and Setting("roll.popup", true) and InRaidOrDemo() then
        self:ShowSession(s)
    end
end

function RollFrame:OnRollUpdated(id)
    if type(id) ~= "string" then return end
    if id ~= self.sessionID then
        self:TellWinOfOtherSession(id)
        return
    end
    local f = self.frame
    if f and f:IsShown() then
        self:Refresh()
        return
    end
    -- Closed with the X (or faded) earlier: come back once to tell a winner they won.
    local s = self:GetSession()
    if s and s.state == "awarded" and IsMe(s.winner) and not self.wonShown
        and Setting("roll.popup", true) and InRaidOrDemo() then
        self:ShowSession(s)
    end
end

function RollFrame:ShowSession(session)
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    local f = self:GetFrame()
    if session.id ~= self.sessionID then self.wonShown = false end
    self.sessionID = session.id
    self.session = session
    self:StopTimers()
    self:CancelFade()
    f:Show()
    f:Raise()
    self:RefreshItem()
    self:Refresh()
end

function RollFrame:Hide()
    self:StopTimers()
    local f = self.frame
    if f then
        if f.fadeAnim and f.fadeAnim:IsPlaying() then f.fadeAnim:Stop() end
        f:Hide()
        f:SetAlpha(1)
    end
end

-- The X button. The roll itself goes on (use Pass to pass).
function RollFrame:Dismiss()
    self:Hide()
end

local function RememberResponse(self, id, r)
    if self.respondedCount >= RESPONDED_MAX then
        self.responded = {}
        self.respondedCount = 0
    end
    if self.responded[id] == nil then self.respondedCount = self.respondedCount + 1 end
    self.responded[id] = r
end

function RollFrame:DoRoll()
    local id = self.sessionID
    if not id then return end
    local s = self:GetSession()
    if s and s.state ~= nil and s.state ~= "open" then
        self:Refresh()
        return
    end
    RememberResponse(self, id, "roll")
    if ns.Roll and ns.Roll.RespondRoll then
        CallRoll("RespondRoll", id)
    elseif _G.RandomRoll then
        _G.RandomRoll(1, 100)
    end
    self:Refresh()
end

function RollFrame:DoPass()
    local id = self.sessionID
    if not id then return end
    RememberResponse(self, id, "pass")
    CallRoll("RespondPass", id)
    self:Refresh()
end

---------------------------------------------------------------------------
-- Painting
---------------------------------------------------------------------------
-- Item, own BiS status and own worn items (changes rarely).
function RollFrame:RefreshItem()
    local f = self.frame
    local s = self.session
    if not f or not f:IsShown() or type(s) ~= "table" then return end
    local itemID = tonumber(s.i)
    if not itemID then return end
    f.item:SetItem(itemID)
    f.item:SetState(nil)
    FitName(f.name, ItemText(itemID), NAME_W)

    local m = OwnMatch(itemID)
    local pill, kind, detail = OwnStatus(m)
    -- a crafting material: what it is for on my lists
    local M = ns.Materials
    local craft, crafts
    if not m and M and M.IsMaterial and M:IsMaterial(itemID) then craft, crafts = M:GetOwnPick(itemID) end
    if craft then
        pill, kind = OwnStatus(craft.match)
        detail = "for " .. ItemText(craft.use.item)
        if #crafts > 1 then detail = detail .. Paint(format(" +%d", #crafts - 1), "muted") end
    end
    f.bis:ClearAllPoints()
    if pill then
        f.bisPill:Set(pill, kind)
        f.bisPill:Show()
        f.bis:SetPoint("LEFT", f.bisPill, "RIGHT", 6, 0)
        f.bis:SetWidth(max(40, TEXT_W - f.bisPill:GetWidth() - 6))
    else
        f.bisPill.fs:SetText("")
        f.bisPill:Hide()
        f.bis:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -32)
        f.bis:SetWidth(TEXT_W)
    end
    f.bis:SetText(detail)
    f.forBtn:SetShown(craft ~= nil and #crafts > 1)
    if craft then
        f.forBtn:ClearAllPoints()
        f.forBtn:SetPoint("TOPLEFT", f.bis, "TOPLEFT", 0, 2)
        f.forBtn:SetSize(max(40, min(TEXT_W, (f.bis:GetStringWidth() or 0) + 4)), 16)
        self:ShowHoldings(craft)
        return
    end
    for _, t in ipairs(f.pips) do t:Hide() end
    f.wearLabel:ClearAllPoints()
    f.wearLabel:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -54)

    local group = ItemSlotGroup(itemID, m)
    local getItem = _G.GetInventoryItemID
    local shown = 0
    if group and getItem then
        for _, sid in ipairs(group) do
            local slot = ns.SLOTS and ns.SLOTS[sid]
            -- GetInventoryItemID returns two values; the extra parens keep the second one from
            -- becoming tonumber's `base` argument ("base out of range").
            local id = slot and tonumber((getItem("player", slot.invSlot)))
            if id and id > 0 and shown < 2 then
                shown = shown + 1
                local b = f.wear[shown]
                b.itemID, b.invSlot, b.label = id, slot.invSlot, SlotLabel(sid)
                b.icon:SetTexture(ItemIcon(id))
                b:Show()
            end
        end
    end
    for i = shown + 1, #f.wear do
        f.wear[i].itemID = nil
        f.wear[i]:Hide()
    end
    if not group then
        f.wearLabel:SetText("")
    elseif shown == 0 then
        f.wearLabel:SetText("Wearing: nothing")
    else
        f.wearLabel:SetText("Wearing:")
    end
end

-- The holdings line of a crafting material: a square per material the craft takes (held gold, this one half gold,
-- missing grey), then "You have 1 of 2", green "· completes it" when this one finishes the craft.
function RollFrame:ShowHoldings(w)
    local f = self.frame
    for i = 1, #f.wear do
        f.wear[i].itemID = nil
        f.wear[i]:Hide()
    end
    local need, held = w.use.count, min(w.held, w.use.count)
    local n = min(need, PIP_MAX)
    for i, t in ipairs(f.pips) do
        if i > n then
            t:Hide()
        else
            if i <= held then
                t:SetColorTexture(0.84, 0.66, 0.14, 1)
            elseif i == held + 1 then
                t:SetColorTexture(0.84, 0.66, 0.14, 0.4)
            else
                t:SetColorTexture(0.30, 0.30, 0.33, 1)
            end
            t:Show()
        end
    end
    f.wearLabel:ClearAllPoints()
    f.wearLabel:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X + n * (PIP_SIZE + 2) + 4, -54)
    f.wearLabel:SetText(format("You have %d of %d", held, need) .. (w.completes and Paint(" · completes it", "obtained") or ""))
end

-- The crafts on my lists that use the material: pick the one I want it for.
function RollFrame:OpenCraftMenu(owner)
    local s = self.session
    local M = ns.Materials
    local itemID = type(s) == "table" and tonumber(s.i)
    if not (itemID and M and ns.UI and ns.UI.ContextMenu) then return end
    local cur, list = M:GetOwnPick(itemID)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("I want it for")
        for _, w in ipairs(list or {}) do
            local item = w.use.item
            local text = ItemText(item) .. Paint(format("  %d/%d", min(w.held, w.use.count), w.use.count), "muted")
            if cur and cur.use.item == item then text = text .. Paint("  (picked)", "obtained") end
            root:CreateButton(text, function()
                M:SetOwnPick(itemID, item)
                RollFrame:RefreshItem()
            end)
        end
    end)
end

function RollFrame:SetButtonsShown(shown)
    local f = self.frame
    f.roll:SetShown(shown)
    f.pass:SetShown(shown)
    f.status:SetShown(not shown)
end

function RollFrame:UpdateTimer()
    local f = self.frame
    local s = self.session
    if not f or not f:IsShown() or type(s) ~= "table" or (s.state ~= nil and s.state ~= "open") then
        self:StopTicker()
        return
    end
    local duration = tonumber(s.duration) or 30
    if duration <= 0 then duration = 30 end
    local left = (tonumber(s.endsAt) or 0) - GetTime()
    f.bar:SetMinMaxValues(0, duration)
    f.bar:SetValue(max(0, min(duration, left)))
    if left <= 5 then
        f.bar:SetStatusBarColor(1, 0.3, 0.3)
        f.timeText:SetTextColor(1, 0.4, 0.4)
    elseif left <= 10 then
        f.bar:SetStatusBarColor(1, 0.55, 0.2)
        f.timeText:SetTextColor(1, 0.6, 0.3)
    else
        f.bar:SetStatusBarColor(1, 0.82, 0)
        f.timeText:SetTextColor(0.62, 0.62, 0.62)
    end
    f.timeText:SetText(left > 0 and (FormatLeft(left) .. " left") or "")
end

-- Own result: text, kind ("rolled" | "pass" | "pending"); nil when not responded yet.
local function OwnResult(s, me, response)
    local r = me and type(s.rolls) == "table" and s.rolls[me]
    local n = type(r) == "table" and tonumber(r.roll)
    if n then
        local text
        if r.invalid then
            text = Paint(format("You rolled %d (%s-%s): not counted", n, tostring(r.min or "?"),
                tostring(r.max or "?")), "bad")
        else
            text = Paint(format("You rolled %d", n), "main")
        end
        if (tonumber(r.count) or 1) > 1 then text = text .. Paint(" (first roll counts)", "muted") end
        return text, "rolled"
    end
    if response == "pass" then return Paint("Passed", "muted"), "pass" end
    if response == "roll" then return Paint("Rolling...", "muted"), "pending" end
    return nil
end

function RollFrame:Refresh()
    local f = self.frame
    if not f or not f:IsShown() then return end
    local s = self:GetSession()
    if type(s) ~= "table" then
        self:Hide()
        return
    end
    local id = s.id or self.sessionID
    local me = PlayerKey()
    local response = (me and type(s.responses) == "table" and s.responses[me]) or self.responded[id]
    local state = s.state or "open"

    if state == "awarded" then
        self:StopTicker()
        self:SetButtonsShown(false)
        f.bar:Hide()
        f.timeText:SetText("")
        -- via "loot": resolved by the loot message (handed out without a DisasterZone award click)
        local looted = (s.via == "loot") and Paint(" (looted)", "muted") or ""
        if IsMe(s.winner) then
            self.wonShown = true   -- told once; later updates of this session do not bring it back
            self.wonTold = self.wonTold or {}
            self.wonTold[s.id] = true
            -- The item is named on the first line; long names did not fit here.
            f.status:SetText(Paint("You won it!", "main") .. looted)
        elseif type(s.winner) == "string" then
            f.status:SetText(Paint("Won by ", "muted") .. ColoredName(s.winner) .. looted)
        else
            f.status:SetText(Paint("Awarded", "muted") .. looted)
        end
        self:ScheduleFade(FADE_AFTER_AWARD, "awarded")
    elseif state == "cancelled" then
        self:StopTicker()
        self:SetButtonsShown(false)
        f.bar:Hide()
        f.timeText:SetText("")
        f.status:SetText(Paint("Roll cancelled", "muted"))
        self:ScheduleFade(FADE_AFTER_CANCEL, "cancelled")
    elseif state == "closed" then
        self:StopTicker()
        self:SetButtonsShown(false)
        f.bar:Hide()
        f.timeText:SetText("")
        local own, kind = OwnResult(s, me, response)
        if own and kind ~= "pending" then
            f.status:SetText(own .. Paint(" - rolls closed", "muted"))
        else
            f.status:SetText(Paint("Rolls closed", "warn"))
        end
        self:ScheduleFade(LINGER_AFTER_CLOSE, "closed")
    else
        f.bar:Show()
        local own = OwnResult(s, me, response)
        if own then
            self:SetButtonsShown(false)
            f.status:SetText(own)
        else
            self:SetButtonsShown(true)
            f.status:SetText("")
        end
        self:UpdateTimer()
        self:EnsureTicker()
    end
end

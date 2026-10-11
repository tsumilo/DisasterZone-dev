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
    ns:On("PRIZED_UPDATED", function() RollFrame:RefreshItem() end)
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

-- 1.3.5: a prized item rolled out that I clearly don't qualify for: no roll window (all I could do is pass) unless the
-- GM's loot rules say to show it (q = "s"); PRIZED_NOT_ELIGIBLE (session id, item, why, free again) tells the
-- notification center instead. Unknown standing (c.ok == nil): the window as usual.
function RollFrame:SkipsPrized(session)
    local P = ns.Prized
    local itemID = tonumber(session.i)
    local rec = not session.plain and itemID and P and P.ForItem and P:ForItem(itemID)
    if not rec then return false end
    local G = ns.Guild
    local lr = G and G.GetLootRules and G:GetLootRules()
    if lr and lr.q == "s" then return false end
    local c = P:Check(rec, ns.Util.PlayerKey())
    if not c or c.ok ~= false then return false end
    local res = c.by and c.by[c.failKey]
    ns:Fire("PRIZED_NOT_ELIGIBLE", session.id, itemID, tostring(c.fail or "a loot rule"), res and res.free or nil)
    return true
end

function RollFrame:OnRollStarted(session)
    if type(session) == "string" then session = CallRoll("Get", session) end
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    if not Setting("roll.popup", true) or not InRaidOrDemo() then return end
    if session.state ~= nil and session.state ~= "open" then return end
    if self:SkipsPrized(session) then return end
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

-- 1.3.5 (the user: "a bit more exciting"): a prized item's roll window wears the prized look - the PRIZED ITEM ribbon
-- of its tooltip (Tooltip.Ribbon), the amber glow and sheens of its drop panel card (DropPanel.PrzGlow), a warm flash
-- when it opens and a soft glow breathing behind the Roll / I want it button. fresh: a new roll (flash + sound).
local PZ = { FLASH = 0.7, PULSE = 1.6 }
function RollFrame:SetPrizedLook(on, fresh)
    local f = self.frame
    if not f then return end
    local DP, TT = ns.DropPanel, ns.Tooltip
    if DP and DP.PrzGlow and (on or f.przGlow) then DP.PrzGlow(f, on, FRAME_W, { 1, 0.82, 0, 0.55 }) end
    if on and TT and TT.Ribbon and not f.dzPrized then TT.Ribbon.Build(f) end
    if f.dzPrized then f.dzPrized:SetShown(on and true or false) end
    if not f.przFx then
        if not on then return end
        local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
        local fx = CreateFrame("Frame", nil, f)
        fx:SetAllPoints()
        fx:SetFrameLevel(f:GetFrameLevel() + 1)
        fx.flash = fx:CreateTexture(nil, "OVERLAY", nil, 3)
        fx.flash:SetAllPoints()
        fx.flash:SetColorTexture(1, 0.62, 0.2, 1)
        fx.flash:SetBlendMode("ADD")
        fx.flash:SetAlpha(0)
        fx.pulse = f:CreateTexture(nil, "BACKGROUND", nil, 3)
        fx.pulse:SetTexture(SOFT)
        fx.pulse:SetBlendMode("ADD")
        fx.pulse:SetVertexColor(1, 0.7, 0.2, 1)
        fx.pulse:SetPoint("CENTER", f.roll, "CENTER", 0, 0)
        fx.pulse:SetSize(ROLL_W + 46, BTN_H + 30)
        fx.t, fx.flashT = 0, nil
        fx:SetScript("OnUpdate", function(self, dt)
            self.t = self.t + (dt or 0)
            if self.flashT then
                self.flashT = self.flashT + (dt or 0)
                local k = self.flashT / PZ.FLASH
                if k >= 1 then
                    self.flash:SetAlpha(0)
                    self.flashT = nil
                else
                    self.flash:SetAlpha(0.45 * (1 - k) * (1 - k))
                end
            end
            -- the button's glow breathes while I may still answer
            local can = f.roll:IsShown() and f.roll:IsEnabled()
            self.pulseOn = can
            self.pulse:SetShown(can)
            if can then self.pulse:SetAlpha(0.28 + 0.22 * math.sin(self.t / PZ.PULSE * 2 * math.pi)) end
        end)
        f.przFx = fx
    end
    local fx = f.przFx
    fx:SetShown(on and true or false)
    fx.pulse:SetShown(on and f.roll:IsShown() and f.roll:IsEnabled() and true or false)
    if on and fresh then
        fx.flashT = 0
        local kit, play = _G.SOUNDKIT, _G.PlaySound
        local snd = kit and (kit.UI_EPICLOOT_TOAST or kit.UI_LEGENDARY_LOOT_TOAST or kit.READY_CHECK)
        if snd and play then pcall(play, snd) end
    end
end

function RollFrame:ShowSession(session)
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    local f = self:GetFrame()
    local fresh = session.id ~= self.sessionID
    if session.id ~= self.sessionID then self.wonShown = false end
    self.sessionID = session.id
    self.session = session
    self:StopTimers()
    self:CancelFade()
    f:Show()
    f:Raise()
    self:RefreshItem()
    self:Refresh()
    local P = ns.Prized
    local prized = not session.plain and P and P.ForItem and P:ForItem(tonumber(session.i)) ~= nil
    self:SetPrizedLook(prized and true or false, fresh)
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
    if self.przBlocked then return end
    local s = self:GetSession()
    if s and s.state ~= nil and s.state ~= "open" then
        self:Refresh()
        return
    end
    RememberResponse(self, id, "roll")
    if s then self:DiceRolling(s, true) end
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
    self.przBlocked, self.przDecides = false, false
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
    -- 1.3.5: a prized item (Raids > Loot rules): how I stand against its rules; one I don't meet can't be rolled for
    self.przBlocked, self.przDecides = false, false
    local P = ns.Prized
    local rec = not s.plain and P and P.ForItem and P:ForItem(itemID)
    if rec then
        local me = ns.Util.PlayerKey()
        local c = P:Check(rec, me)
        self.przDecides = P:CouncilDecides(rec)
        local text
        if c.ok == false then
            self.przBlocked = true
            local res = c.by and c.by[c.failKey]
            text = Paint("Not this time: ", "warn") .. tostring(c.fail or "a loot rule")
            if res and res.free then text = text .. Paint(" (free again " .. date("%d %b", res.free) .. ")", "muted") end
        elseif c.ok == nil then
            text = Paint("Prized item: ", "warn") .. "the council checks its rules"
        else
            text = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t " .. Paint("You meet all " .. c.required .. " loot rules", "main")
        end
        f.wearLabel:SetText(text)
        f.wearLabel:SetWidth(TEXT_W)
        if f.roll:IsShown() then f.roll:SetEnabled(not self.przBlocked) end
        for i = 1, #f.wear do
            f.wear[i].itemID = nil
            f.wear[i]:Hide()
        end
        return
    end

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
    if shown then self:HideDice() end
    -- (while the dice come in, the buttons fade out on their own: StepDice hides them)
    local fading = not shown and f.dice and f.dice.out
    if not fading then
        f.roll:SetShown(shown)
        f.pass:SetShown(shown)
    end
    f.status:SetShown(not shown and not self:DiceShowing())
end

---------------------------------------------------------------------------
-- 1.3.5 the dice (the user: "a cool dice animation when you press roll, with super elegant transitions"): pressing
-- Roll fades the buttons out as a die pops in where they were; it tumbles (spinning, a little bounce) while numbers
-- flicker; when my roll arrives (after at least DICE.MIN) the flicker slows, the number lands with a pop and a soft
-- glow (gold, red for a roll that doesn't count) and the die settles. "You rolled" / "Highest so far!" beside it.
-- Opening the window on a roll already made shows it settled, without the show.
---------------------------------------------------------------------------
local DICE = { TEX = "Interface\\Buttons\\UI-GroupLoot-Dice-Up", SIZE = 24, OUT = 0.18, IN = 0.22, MIN = 0.75,
               SLOW = 0.4, POP = 0.32, GLOW = 0.6, SPIN = 13, FLICK = 0.055 }
local SOFT_GLOW = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"

local function EaseOut(k) return 1 - (1 - k) * (1 - k) end
local function EaseBack(k)   -- overshoots a little, then settles
    local c = 1.7
    k = k - 1
    return 1 + (c + 1) * k * k * k + c * k * k
end

function RollFrame:GetDice()
    local f = self.frame
    if f.dice then return f.dice end
    local d = CreateFrame("Frame", nil, f)
    d:SetSize(ROLL_W + 6 + PASS_W + 20, BTN_H + 8)
    d:SetPoint("RIGHT", f, "TOPRIGHT", -PAD, -MID_Y + 1)
    d:SetFrameLevel(f:GetFrameLevel() + 3)
    d.glow = d:CreateTexture(nil, "BACKGROUND")
    d.glow:SetTexture(SOFT_GLOW)
    d.glow:SetBlendMode("ADD")
    d.glow:SetAlpha(0)
    d.num = CreateFrame("Frame", nil, d)
    d.num:SetSize(44, 30)
    d.num:SetPoint("RIGHT", d, "RIGHT", 0, 0)
    d.text = d.num:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    local path, _, flags = d.text:GetFont()
    if path then d.text:SetFont(path, 22, flags) end
    d.text:SetPoint("RIGHT", d.num, "RIGHT", 0, 0)
    d.text:SetJustifyH("RIGHT")
    d.glow:SetPoint("CENTER", d.text, "CENTER", 0, 0)
    d.die = d:CreateTexture(nil, "ARTWORK")
    d.die:SetTexture(DICE.TEX)
    d.die:SetSize(DICE.SIZE, DICE.SIZE)
    d.die:SetPoint("RIGHT", d.num, "LEFT", -4, 0)
    d.caption = d:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local cp, _, cf = d.caption:GetFont()
    if cp then d.caption:SetFont(cp, 11, cf) end
    d.caption:SetPoint("RIGHT", d.die, "LEFT", -6, 0)
    d.caption:SetJustifyH("RIGHT")
    d.caption:SetTextColor(0.62, 0.62, 0.62)
    d:Hide()
    d:SetScript("OnUpdate", function(_, dt) RollFrame:StepDice(dt or 0) end)
    f.dice = d
    return d
end

local function SetDieAngle(d, a)
    if d.die.SetRotation then d.die:SetRotation(a) end
end

-- Shows the die for my roll in session s: animated = I just pressed Roll here (the whole show), else settled.
function RollFrame:DiceRolling(s, animated)
    local f, d = self.frame, self:GetDice()
    if d.sid == s.id and d.phase ~= nil then return end
    d.sid, d.phase, d.t, d.flickT, d.final, d.landT = s.id, "tumble", 0, 0, nil, nil
    d.animated = animated and true or false
    d.angle = 0
    d.text:SetText(tostring(math.random(100)))
    d.text:SetTextColor(0.85, 0.85, 0.88)
    d.caption:SetText(Paint("Rolling...", "muted"))
    d.glow:SetAlpha(0)
    d.die:SetVertexColor(1, 1, 1)
    d.num:SetScale(1)
    d:Show()
    if animated then
        d:SetAlpha(0)
        f.roll:Show()
        f.pass:Show()
        d.out = 0
    else
        d:SetAlpha(1)
        d.out = nil
    end
end

-- My roll arrived: land on n (bad = it doesn't count; best = the highest so far).
function RollFrame:DiceLand(s, n, bad, best)
    local d = self:GetDice()
    if d.sid ~= s.id or d.phase == nil then
        self:DiceRolling(s, false)
    end
    if d.final == n and d.phase ~= "tumble" then
        -- (someone rolled higher since: the caption follows)
        if d.phase == "done" and d.best ~= best then
            d.best = best
            self:DiceSettle()
        end
        return
    end
    d.final, d.bad, d.best = n, bad, best
    if not d.animated then
        d.phase = "done"
        self:DiceSettle()
        return
    end
    if d.phase == "tumble" then d.landWait = true end
end

function RollFrame:DiceSettle()
    local d = self.frame.dice
    d.text:SetText(tostring(d.final))
    if d.bad then d.text:SetTextColor(1, 0.35, 0.35) else d.text:SetTextColor(1, 0.85, 0.25) end
    d.die:SetVertexColor(d.bad and 1 or 1, d.bad and 0.55 or 0.85, d.bad and 0.55 or 0.4)
    SetDieAngle(d, 0)
    d.num:SetScale(1)
    d.glow:SetAlpha(0)
    d:SetAlpha(1)
    local cap = d.bad and Paint("Not counted", "bad") or (d.best and Paint("Highest so far!", "obtained")
        or Paint("You rolled", "muted"))
    d.caption:SetText(cap)
end

-- The dice for my answer in s: kind "pending" (I pressed Roll, no number yet) / "rolled" / other (none).
function RollFrame:DiceFor(s, me, kind)
    if kind == "pending" then
        local d = self.frame.dice
        if not (d and d.sid == s.id and d.phase) then self:DiceRolling(s, false) end
        return
    end
    if kind ~= "rolled" then
        self:HideDice()
        return
    end
    local r = me and type(s.rolls) == "table" and s.rolls[me]
    local n = type(r) == "table" and tonumber(r.roll)
    if not n then return end
    local best = not r.invalid
    for k, o in pairs(type(s.rolls) == "table" and s.rolls or {}) do
        if k ~= me and type(o) == "table" and not o.invalid and (tonumber(o.roll) or 0) >= n then best = false end
    end
    self:DiceLand(s, n, r.invalid and true or false, best)
end

function RollFrame:HideDice()
    local f = self.frame
    local d = f and f.dice
    if not d then return end
    d:Hide()
    d.phase, d.sid, d.out = nil, nil, nil
    f.roll:SetAlpha(1)
    f.pass:SetAlpha(1)
end

function RollFrame:DiceShowing()
    local d = self.frame and self.frame.dice
    return d and d:IsShown() and d.phase ~= nil or false
end

function RollFrame:StepDice(dt)
    local f = self.frame
    local d = f.dice
    if not d or not d.phase then return end
    d.t = d.t + dt
    -- the buttons fade and slide away, the die comes in
    if d.out then
        d.out = d.out + dt
        local k = math.min(1, d.out / DICE.OUT)
        f.roll:SetAlpha(1 - k)
        f.pass:SetAlpha(1 - k)
        local kin = math.max(0, math.min(1, (d.out - DICE.OUT * 0.4) / DICE.IN))
        d:SetAlpha(EaseOut(kin))
        d.num:SetScale(0.6 + 0.4 * EaseOut(kin))
        if k >= 1 and kin >= 1 then
            f.roll:Hide()
            f.pass:Hide()
            f.roll:SetAlpha(1)
            f.pass:SetAlpha(1)
            d.out = nil
        end
    end
    if d.phase == "tumble" then
        d.angle = d.angle + DICE.SPIN * dt
        SetDieAngle(d, d.angle)
        d.die:ClearAllPoints()
        d.die:SetPoint("RIGHT", d.num, "LEFT", -4, math.abs(math.sin(d.t * 9)) * 3)
        d.flickT = d.flickT + dt
        if d.flickT >= DICE.FLICK then
            d.flickT = 0
            d.text:SetText(tostring(math.random(100)))
        end
        if d.landWait and d.t >= DICE.MIN then
            d.landWait, d.phase, d.landT, d.spin0 = nil, "land", 0, DICE.SPIN
        end
    elseif d.phase == "land" then
        d.landT = d.landT + dt
        local k = d.landT
        if k < DICE.SLOW then
            -- the flicker slows, the die winds down
            local q = k / DICE.SLOW
            d.angle = d.angle + DICE.SPIN * (1 - q) * (1 - q) * dt
            SetDieAngle(d, d.angle)
            d.flickT = d.flickT + dt
            if d.flickT >= DICE.FLICK + q * 0.16 then
                d.flickT = 0
                d.text:SetText(tostring(math.random(100)))
            end
        else
            local p = k - DICE.SLOW
            if not d.popped then
                d.popped = true
                d.text:SetText(tostring(d.final))
                if d.bad then d.text:SetTextColor(1, 0.35, 0.35) else d.text:SetTextColor(1, 1, 1) end
                d.caption:SetText(d.bad and Paint("Not counted", "bad")
                    or (d.best and Paint("Highest so far!", "obtained") or Paint("You rolled", "muted")))
                d.glow:SetVertexColor(d.bad and 1 or 1, d.bad and 0.3 or 0.75, d.bad and 0.3 or 0.2)
                local kit, play = _G.SOUNDKIT, _G.PlaySound
                local snd = kit and (kit.UI_BONUS_LOOT_ROLL_END or kit.IG_QUEST_LIST_COMPLETE)
                if snd and play then pcall(play, snd) end
            end
            local kp = math.min(1, p / DICE.POP)
            d.num:SetScale(1.6 - 0.6 * EaseBack(kp))
            -- white flash easing to gold
            if not d.bad then d.text:SetTextColor(1, 1 - 0.15 * kp, 1 - 0.75 * kp) end
            local kg = math.min(1, p / DICE.GLOW)
            d.glow:SetSize(30 + 70 * EaseOut(kg), 20 + 40 * EaseOut(kg))
            d.glow:SetAlpha(0.85 * (1 - kg))
            -- the die settles upright
            local target = math.floor(d.angle / (2 * math.pi) + 0.5) * 2 * math.pi
            d.angle = d.angle + (target - d.angle) * math.min(1, dt * 10)
            SetDieAngle(d, d.angle)
            d.die:ClearAllPoints()
            d.die:SetPoint("RIGHT", d.num, "LEFT", -4, 0)
            if kp >= 1 and kg >= 1 then
                d.phase, d.popped = "done", nil
                self:DiceSettle()
            end
        end
    end
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
        self:HideDice()
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
        self:HideDice()
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
        -- (rolls closed: the dice step aside for the result line)
        self:HideDice()
        self:SetButtonsShown(false)
        if own and kind ~= "pending" then
            f.status:SetText(own .. Paint(" - rolls closed", "muted"))
        else
            f.status:SetText(Paint("Rolls closed", "warn"))
        end
        self:ScheduleFade(LINGER_AFTER_CLOSE, "closed")
    else
        f.bar:Show()
        local own, kind = OwnResult(s, me, response)
        if own then
            self:DiceFor(s, me, kind)
            self:SetButtonsShown(false)
            f.status:SetText(own)
        else
            self:SetButtonsShown(true)
            -- 1.3.5: prized items (RefreshItem worked it out)
            f.roll:SetText(self.przDecides and "I want it" or "Roll")
            f.roll:SetEnabled(not self.przBlocked)
            f.status:SetText("")
        end
        self:UpdateTimer()
        self:EnsureTicker()
    end
end

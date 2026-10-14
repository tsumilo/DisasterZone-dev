if DisasterZoneBoot and DisasterZoneBoot.Run("UI/RollFrame.lua", ...) then return end -- DisasterZone UI/RollFrame.lua
-- The raider roll popup (ADDENDUM A §19.3): when a DisasterZone roll starts, everyone in the raid (or in a
-- 5-man party with dungeon mode, ADDENDUM B §22.2) gets a small group-loot style frame with the item,
-- their own BiS status and gear, a countdown and Roll / Pass. Once the item is awarded or looted it
-- shows the winner and fades (ADDENDUM C §23.3).
-- 1.4: a HUD frame (UI:CreateHudFrame: the pop-ups' card, the one position store under its old key, the flat X),
-- the type scale and colour tokens of ns.Style, the shared text / item / tooltip helpers.
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
local UI, S = ns.UI, ns.Style
local FRAME_NAME = "DisasterZoneRollFrame"
local FRAME_W, FRAME_H = 400, 82
local DEFAULT_POINT, DEFAULT_Y = "TOP", -228   -- (under the BiS toast)
local PAD = UI.TOAST.PAD                       -- the pop-ups' inner margin (the toasts')
local ICON_SIZE, WEAR_SIZE = 40, 16
local TEXT_X = PAD + ICON_SIZE + S.PAD
local ROLL_W, PASS_W, BTN_H = 60, 52, S.BTN_H
local MID_Y = 46                          -- the buttons' (and my answer's) middle, from the top: beside lines 2-3
local STATUS_W = 126
local NAME_W = FRAME_W - TEXT_X - 26       -- the item's name runs to the X
local TEXT_W = FRAME_W - TEXT_X - PAD - ROLL_W - 6 - PASS_W - 12
local BG = UI.TOAST.BG                     -- (the card's slate: the pills sit on it)
local PIP_MAX, PIP_SIZE = 5, 7    -- a crafting material: the holdings squares
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

---------------------------------------------------------------------------
-- Helpers (nil-safe: other modules may be missing or not ready)
---------------------------------------------------------------------------
-- text in a ns.COLORS colour (main / alt / obtained / muted / warn / bad).
local function Paint(text, key)
    return UI:Colorize(text, ns.COLORS[key] or ns.COLORS.muted)
end

local function Setting(path, default)
    if ns.db and ns.DB and ns.DB.GetSetting then
        local v = ns.DB:GetSetting(path)
        if v ~= nil then return v end
    end
    return default
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
    return (_G.IsInRaid and _G.IsInRaid()) or ns.Util.DemoOn() or DungeonModeActive()
end

local function PlayerKey()
    return ns.Util and ns.Util.PlayerKey and ns.Util.PlayerKey() or nil
end

local function IsMe(key)
    return ns.Util and ns.Util.IsMe and ns.Util.IsMe(key) or false
end

local function ColoredName(key)
    if type(key) ~= "string" then return "?" end
    return UI:ColoredName(key) .. UI:GuestTag(key)
end

-- (one value: UI:ItemText's second return says the name is still loading)
local function ItemText(itemID)
    local text = UI:ItemText(itemID)
    return text
end

local function SlotGroup(sid)
    sid = tonumber(sid)
    if not sid then return nil end
    local g = ns.SLOT_GROUP and ns.SLOT_GROUP[sid]
    if type(g) == "table" and #g > 0 then return g end
    return SLOT_GROUP_FALLBACK[sid] or { sid }
end

-- The item's name: the title style, a step smaller (emph, body) when a long name would not fit. (The colour comes
-- from the item link.)
local NAME_STEPS = { "title", "emph", "body" }
local function FitName(fs, text, width)
    for _, style in ipairs(NAME_STEPS) do
        UI:SetTextStyle(fs, style, "GOLD")
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
    local parts = { ns.SlotLabel(m.sid), "P" .. tostring(tonumber(m.phase) or 0) }
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
-- Lifecycle
---------------------------------------------------------------------------
-- Edit layout: the frame as it shows in a roll, while none is up (Core/Layout.lua "roll").
function RollFrame:Preview(on)
    local f = self:GetFrame()
    if not on then
        if self.previewing then
            self.previewing = nil
            f.name:SetText("")
            f:Hide()
        end
        return
    end
    if f:IsShown() then return end
    self.previewing = true
    f.name:SetText("An item up for a roll")
    f:SetAlpha(1)
    f:Show()
end

function RollFrame:OnInit()
    ns.Layout:Register("roll", { name = "Roll frame", group = "Loot", order = 20, when = "when a roll starts",
        frame = function() return self.frame end, default = { DEFAULT_POINT, 0, DEFAULT_Y },
        legacy = function()
            local p = ns.UI:SavedPosition(FRAME_NAME)
            if p then return p[1], p[2], p[3], p[4] end
        end,
        preview = function(on) RollFrame:Preview(on) end })
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
-- (the worn item's own tooltip, from the inventory slot: UI:AttachTooltip's title function)
local function WearTooltip(self, tt)
    if not self.itemID then return false end
    local shown = false
    if self.invSlot and tt.SetInventoryItem then
        shown = tt:SetInventoryItem("player", self.invSlot) and true or false
    end
    if not shown then tt:SetItemByID(self.itemID) end
    tt:AddLine("Currently wearing (" .. tostring(self.label or "?") .. ")", S:RGB("SUB"))
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
    b:SetScript("OnClick", WearOnClick)
    UI:AttachTooltip(b, WearTooltip)
    b:Hide()
    return b
end

-- text: a string, or a function returning one (read when the tooltip opens).
local function ButtonTooltip(btn, text)
    UI:AttachTooltip(btn, nil, function() return { type(text) == "function" and text() or text } end,
        { anchor = "AUTO_Y" })
end

function RollFrame:GetFrame()
    if self.frame then return self.frame end
    -- A HUD frame in the pop-ups' card look (a dark card with a gold edge, like the toasts). The item and what it is to
    -- me on the left, Roll / Pass on the right (my result once I answered), the time left as a thin bar along the
    -- bottom; the flat X dismisses it (the roll goes on). Its place is kept under its frame name.
    local f = UI:CreateHudFrame(FRAME_NAME, {
        width = FRAME_W, height = FRAME_H, position = FRAME_NAME, look = "card", strata = "DIALOG", toplevel = true,
        layout = "roll",
        default = { DEFAULT_POINT, _G.UIParent, DEFAULT_POINT, 0, DEFAULT_Y },
        close = function() RollFrame:Dismiss() end,
    })
    f:Hide()
    self.frame = f

    f.item = UI:CreateItemButton(f, ICON_SIZE)
    f.item:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - 2)

    f.name = UI:Text(f, "title", "GOLD")
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -PAD - 1)
    f.name:SetWidth(NAME_W)

    -- what the item is to me: a BiS / Alt / OS pill and where it goes ("Head · P1"), or "Not on your BiS list"
    f.bisPill = UI:CreatePill(f, 16)
    f.bisPill:SetBase(BG[1], BG[2], BG[3])
    f.bisPill:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -30)
    f.bisPill:Hide()
    f.bis = UI:Text(f, "sub")

    -- a crafting material: "for Belt of Blasting" is a button when more than one craft on my lists uses it (pick the
    -- one I want it for), and the wearing line becomes my holdings: squares + "You have 1 of 2 · completes it"
    f.forBtn = CreateFrame("Button", nil, f)
    f.forBtn:SetScript("OnClick", function(self) RollFrame:OpenCraftMenu(self) end)
    UI:AttachTooltip(f.forBtn, nil, { "Click: pick the craft you want it for (the council sees your pick)" },
        { anchor = "AUTO_Y" })
    f.forBtn:Hide()
    f.pips = {}
    for i = 1, PIP_MAX do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(PIP_SIZE, PIP_SIZE)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X + (i - 1) * (PIP_SIZE + 2), -56)
        t:Hide()
        f.pips[i] = t
    end

    f.wearLabel = UI:Text(f, "sub")
    f.wearLabel:SetPoint("TOPLEFT", f, "TOPLEFT", TEXT_X, -54)
    f.wearLabel:SetText("Wearing:")
    f.wear = { NewWearButton(f), NewWearButton(f) }
    f.wear[1]:SetPoint("LEFT", f.wearLabel, "RIGHT", 5, 0)
    f.wear[2]:SetPoint("LEFT", f.wear[1], "RIGHT", 3, 0)

    f.pass = UI:CreateSleekButton(f, _G.PASS or "Pass", PASS_W, BTN_H, function() RollFrame:DoPass() end)
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
    f.status = UI:Text(f, "emph", "GOLD")
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
    bar:SetStatusBarColor(S:Color("GOLD"))
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar.bg = UI:Fill(bar, "HAIRLINE", "BACKGROUND")
    f.bar = bar
    f.timeText = UI:Text(f, "sub", nil, { justify = "RIGHT" })
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
    if self.frame then
        self.frame:ResetPlace()
    elseif ns.db and ns.db.settings and type(ns.db.settings.windows) == "table" then
        ns.db.settings.windows[FRAME_NAME] = nil
    end
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

-- 1.4.3: loot reserves: how a roll stands for me. "mine" (I reserved it), "solo" (only I did: no roll needed),
-- "other" (others reserved it, not me: no pop-up), "guild" (held for the guild and I'm a guest: no pop-up), "grabs"
-- (up for grabs), "council" (held for the guild, I'm in it); nil without reserves.
function RollFrame:ReserveStand(session)
    local kind = type(session) == "table" and session.rv
    if not kind then return nil end
    if kind == "o" then return "grabs" end
    if kind == "g" then
        -- a guest: in no guild at all, or not in the guild of whoever started the roll
        local G = ns.Guild
        local guildless = _G.IsInGuild and not _G.IsInGuild()
        local guest = guildless or (G and G.IsInGuild and session.starter and not IsMe(session.starter)
            and (not G.IsReady or G:IsReady()) and not G:IsInGuild(session.starter))
        return guest and "guild" or "council"
    end
    local me = ns.Util.PlayerKey()
    for _, k in ipairs(type(session.rk) == "table" and session.rk or {}) do
        if k == me then return #session.rk == 1 and "solo" or "mine" end
    end
    return "other"
end

-- The short line instead of the pop-up (5 s, no buttons).
function RollFrame:ReserveLine(session, stand)
    if not (UI and UI.Toast) then return end
    local itemID = tonumber(session.i)
    local n = type(session.rk) == "table" and #session.rk or 0
    UI:Toast({ key = "dz-reserve-line", title = ItemText(itemID), duration = 5,
        icon = UI.ItemIcon and UI:ItemIcon(itemID) or nil,
        text = stand == "guild" and "Held for the guild: the loot council decides it."
            or (n == 1 and "Reserved by someone else: not yours to roll." or format("Reserved by %d others: only they roll.", n)) })
end

function RollFrame:OnRollStarted(session)
    if type(session) == "string" then session = CallRoll("Get", session) end
    if type(session) ~= "table" or type(session.id) ~= "string" then return end
    if not Setting("roll.popup", true) or not InRaidOrDemo() then return end
    if session.state ~= nil and session.state ~= "open" then return end
    if self:SkipsPrized(session) then return end
    local stand = self:ReserveStand(session)
    if stand == "other" or stand == "guild" then
        self:ReserveLine(session, stand)
        return
    end
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
    if DP and DP.PrzGlow and (on or f.przGlow) then DP.PrzGlow(f, on, FRAME_W, { S.C.GOLD[1], S.C.GOLD[2], S.C.GOLD[3], 0.55 }) end   -- (off: the card look's edge)
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
    -- 1.4.3: loot reserves: what this roll is to me in place of the list line (the pill still says BiS / Alt)
    local stand = self:ReserveStand(s)
    if stand then
        local others = {}
        for _, k in ipairs(type(s.rk) == "table" and s.rk or {}) do
            if not IsMe(k) then others[#others + 1] = ns.Util.ShortName(k) end
        end
        local line = ({
            mine = Paint("Your reserve", "main") .. Paint(#others == 1 and "  ·  you and " .. others[1] .. " roll"
                or format("  ·  %d others roll", #others), "muted"),
            solo = Paint("Only you reserved it", "main") .. Paint("  ·  no roll needed", "muted"),
            grabs = Paint("Nobody reserved it", "main") .. Paint("  ·  up for grabs", "muted"),
            council = Paint("Held for the guild", "warn") .. Paint("  ·  the loot council decides", "muted"),
        })[stand]
        if line then f.bis:SetText(line) end
    end
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
                b.itemID, b.invSlot, b.label = id, slot.invSlot, ns.SlotLabel(sid)
                b.icon:SetTexture(UI:ItemIcon(id))
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
            local r, g, b = S:Color("GOLD_DEEP")
            if i <= held then
                t:SetColorTexture(r, g, b, 1)
            elseif i == held + 1 then
                t:SetColorTexture(r, g, b, 0.4)
            else
                t:SetColorTexture(S:Color("EDGE_STRONG"))
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
               SLOW = 0.4, POP = 0.32, GLOW = 0.6, SPIN = 13, FLICK = 0.055, NUM = 22 }
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
    UI:SetTextStyle(d.text, DICE.NUM)            -- (a display numeral: above the type scale, kept as is)
    d.text:SetPoint("RIGHT", d.num, "RIGHT", 0, 0)
    d.text:SetJustifyH("RIGHT")
    d.glow:SetPoint("CENTER", d.text, "CENTER", 0, 0)
    d.die = d:CreateTexture(nil, "ARTWORK")
    d.die:SetTexture(DICE.TEX)
    d.die:SetSize(DICE.SIZE, DICE.SIZE)
    d.die:SetPoint("RIGHT", d.num, "LEFT", -4, 0)
    d.caption = UI:Text(d, "sub", nil, { justify = "RIGHT" })
    d.caption:SetPoint("RIGHT", d.die, "LEFT", -6, 0)
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
    local tone = (left <= 5 and "BAD") or (left <= 10 and "WARN") or nil
    f.bar:SetStatusBarColor(S:Color(tone or "GOLD"))
    f.timeText:SetTextColor(S:Color(tone or "SUB"))
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

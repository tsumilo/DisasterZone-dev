if DisasterZoneBoot and DisasterZoneBoot.Run("UI/DatePicker.lua", ...) then return end -- DisasterZone: UI/DatePicker.lua
-- A calendar date picker (DisasterZone extension, Addendum J §58): a button showing the date; clicking it drops a
-- flat month calendar (Monday first) with the addon's chevrons for the previous / next month. Days outside
-- [minDate, maxDate] are greyed out, today is outlined, the picked day is gold, and days the caller marks (e.g. a
-- raid is planned) get a gold dot with a tooltip. A click outside, Escape on the owner window or hiding the button
-- closes it.
local addonName, ns = ...

local UI = ns.UI
local S = ns.Style

local floor = math.floor

local CELL_W, CELL_H = 30, 26
local PAD = 10
local HEAD_H, WEEK_H = 32, 16
local WEEKDAYS = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" }
local PICKED_BG = { 0.17, 0.14, 0.05, 0.95 }
local GOLD = S.C.GOLD_DEEP
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

local function EventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) and true or false end
    return true
end

-- Noon of a calendar day (noon keeps DST shifts from moving the day).
local function DayTime(y, m, d)
    return time({ year = y, month = m, day = d, hour = 12, min = 0, sec = 0 })
end

-- { year, month, day } of a day `n` days after y-m-d (normalised through time()).
local function AddDays(y, m, d, n)
    local t = date("*t", DayTime(y, m, d + n))
    return t.year, t.month, t.day
end

local function DaysInMonth(y, m)
    return date("*t", DayTime(y, m + 1, 0)).day
end

-- Day index for comparisons: yyyymmdd.
local function Key(y, m, d) return y * 10000 + m * 100 + d end

-- opts = {
--   get()        -> y, m, d            (required: the current date)
--   set(y, m, d)                       (required: a day was picked)
--   minDate()    -> y, m, d | nil      (earliest pickable day)
--   maxDate()    -> y, m, d | nil      (latest pickable day)
--   mark(y, m, d) -> text | nil        (a dot on the day; text = tooltip lines, "\n"-separated)
--   width = 220
--   center = true                      (the calendar drops centred under the button, else from its left edge)
-- }
-- Returns the button; button.popup is the calendar; button:Refresh(), button:Open(), button:Close(),
-- button:ShowMonth(y, m), button:PickDay(d) (in the shown month; for tests).
function UI:CreateDatePicker(parent, opts)
    local b = UI:CreateButton(parent, "", opts.width or 220, 22)
    b.opts = opts

    local p = CreateFrame("Frame", nil, b)
    b.popup = p
    p:SetSize(7 * CELL_W + 2 * PAD, HEAD_H + WEEK_H + 6 * CELL_H + PAD)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    -- (the panel every dropdown drops: UI.DROP_*)
    p.bg:SetColorTexture(UI.DROP_BG[1], UI.DROP_BG[2], UI.DROP_BG[3], UI.DROP_BG[4])
    UI:AddEdges(p, "BORDER")
    UI:SetEdgeColor(p, UI.DROP_EDGE[1], UI.DROP_EDGE[2], UI.DROP_EDGE[3], UI.DROP_EDGE[4])
    p:Hide()

    local function place(dx, dy)
        p:ClearAllPoints()
        if opts.center then p:SetPoint("TOP", b, "BOTTOM", dx, -UI.DROP_GAP + dy)
        else p:SetPoint("TOPLEFT", b, "BOTTOMLEFT", dx, -UI.DROP_GAP + dy) end
    end
    place(0, 0)

    -- the month between the two chevrons
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.title:SetPoint("TOP", 0, -10)
    p.prev = UI:CreateArrowButton(p, false, 26, 24, function() b:ShowMonth(b.shownY, b.shownM - 1) end)
    p.prev:SetPoint("TOPLEFT", 4, -4)
    p.next = UI:CreateArrowButton(p, true, 26, 24, function() b:ShowMonth(b.shownY, b.shownM + 1) end)
    p.next:SetPoint("TOPRIGHT", -4, -4)

    for i, label in ipairs(WEEKDAYS) do
        local fs = UI:Text(p, "caps", i >= 6 and "DIM" or "SUB", { justify = "CENTER", width = CELL_W })
        fs:SetPoint("TOPLEFT", PAD + (i - 1) * CELL_W, -HEAD_H)
        fs:SetText(label)
    end
    p.rule = UI:Rule(p, { left = PAD, right = PAD, top = HEAD_H + WEEK_H - 3, layer = "BORDER" })

    p.cells = {}
    for i = 1, 42 do
        local c = CreateFrame("Button", nil, p)
        c:SetSize(CELL_W - 2, CELL_H - 2)
        local col, row = (i - 1) % 7, floor((i - 1) / 7)
        c:SetPoint("TOPLEFT", PAD + col * CELL_W + 1, -(HEAD_H + WEEK_H + 1) - row * CELL_H)
        c.sel = c:CreateTexture(nil, "BACKGROUND")
        c.sel:SetAllPoints()
        c.sel:SetColorTexture(PICKED_BG[1], PICKED_BG[2], PICKED_BG[3], PICKED_BG[4])
        c.today = c:CreateTexture(nil, "BACKGROUND", nil, -1)
        c.today:SetAllPoints()
        c.today:SetColorTexture(S:Color("HOVER"))
        UI:AddEdges(c, "BORDER")
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(S:Color("HAIRLINE"))
        c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.fs:SetPoint("CENTER", 0, 1)
        c.dot = c:CreateTexture(nil, "OVERLAY")
        c.dot:SetTexture(DISC)
        c.dot:SetSize(4, 4)
        c.dot:SetPoint("BOTTOM", 0, 2)
        c.dot:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
        c:SetScript("OnClick", function(self) if self.day then b:PickDay(self.day) end end)
        c:SetScript("OnEnter", function(self)
            if not self.markText then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for line in self.markText:gmatch("[^\n]+") do GameTooltip:AddLine(line, 1, 1, 1) end
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p.cells[i] = c
    end

    local function bounds()
        local lo = opts.minDate and Key(opts.minDate()) or nil
        local hi = opts.maxDate and Key(opts.maxDate()) or nil
        return lo, hi
    end

    function b:Refresh()
        local y, m, d = opts.get()
        if y then self:SetText(date("%A %d %B %Y", DayTime(y, m, d))) else self:SetText("Pick a day") end
        if p:IsShown() then self:ShowMonth(self.shownY, self.shownM) end
    end

    function b:ShowMonth(y, m)
        local t = date("*t", DayTime(y, m, 1))       -- normalises month 0 / 13
        y, m = t.year, t.month
        self.shownY, self.shownM = y, m
        p.title:SetText(date("%B %Y", DayTime(y, m, 1)))
        local lo, hi = bounds()
        local selY, selM, selD = opts.get()
        local sel = selY and Key(selY, selM, selD)
        local now = date("*t", GetServerTime())
        local today = Key(now.year, now.month, now.day)
        local lead = (t.wday + 5) % 7                -- Monday first
        local days = DaysInMonth(y, m)
        for i, c in ipairs(p.cells) do
            local d = i - lead
            if d >= 1 and d <= days then
                local k = Key(y, m, d)
                local ok = (not lo or k >= lo) and (not hi or k <= hi)
                local picked, isToday = k == sel, k == today
                c.day = ok and d or nil
                c.fs:SetText(d)
                if picked then c.fs:SetTextColor(1, 0.88, 0.54)
                elseif ok then c.fs:SetTextColor(0.92, 0.92, 0.92)
                else c.fs:SetTextColor(0.34, 0.34, 0.36) end
                c:EnableMouse(true)
                c.sel:SetShown(picked)
                c.today:SetShown(isToday)
                if picked then UI:SetEdgeColor(c, GOLD[1], GOLD[2], GOLD[3], 1)
                elseif isToday then UI:SetEdgeColor(c, 0.62, 0.62, 0.66, 0.9)
                else UI:SetEdgeColor(c, 0, 0, 0, 0) end
                c.markText = opts.mark and opts.mark(y, m, d) or nil
                c.dot:SetShown(c.markText ~= nil)
                c.dot:SetAlpha(ok and 1 or 0.4)
                c:Show()
            else
                c.day, c.markText = nil, nil
                c:Hide()
            end
        end
        local firstKey, lastKey = Key(y, m, 1), Key(y, m, days)
        p.prev:SetEnabled(not lo or firstKey > lo)
        p.next:SetEnabled(not hi or lastKey < hi)
    end

    function b:PickDay(d)
        opts.set(self.shownY, self.shownM, d)
        self:Close()
        self:Refresh()
    end

    function b:Open()
        local y, m = opts.get()
        if not y then
            local now = date("*t", GetServerTime())
            y, m = now.year, now.month
        end
        -- it drops in (UI:DropIn): falls the last few px while it fades up, like every menu
        p:Show()
        UI:DropIn(p, place)
        self:ShowMonth(y, m)
        if self.OnCalendarShown then self:OnCalendarShown(true) end
    end

    function b:Close()
        if not p:IsShown() then return end
        p:Hide()
    end

    b:SetScript("OnClick", function(self)
        if p:IsShown() then self:Close() else self:Open() end
    end)
    p:SetScript("OnShow", function(self)
        if EventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
    end)
    p:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if b.OnCalendarShown then b:OnCalendarShown(false) end
    end)
    p:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not b:IsMouseOver() then b:Close() end
    end)
    b:HookScript("OnHide", function() b:Close() end)

    b:Refresh()
    return b
end

UI.DatePickerAddDays = AddDays

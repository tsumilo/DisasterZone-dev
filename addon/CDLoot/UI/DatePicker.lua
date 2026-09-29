-- CDLoot: UI/DatePicker.lua
-- A calendar date picker (CDLoot extension, Addendum J §58): a button showing the date; clicking it opens a month
-- calendar (Monday first) with previous / next month arrows. Days outside [minDate, maxDate] are greyed out, today is
-- outlined, the picked day highlighted, and days the caller marks (e.g. a raid is planned) get a dot with a tooltip.
-- A click outside, Escape on the owner window or hiding the button closes it.
local addonName, ns = ...

local UI = ns.UI

local floor = math.floor

local CELL_W, CELL_H = 28, 20
local PAD = 8
local WEEKDAYS = { "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }

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
-- }
-- Returns the button; button.popup is the calendar; button:Refresh(), button:Open(), button:Close(),
-- button:ShowMonth(y, m), button:PickDay(d) (in the shown month; for tests).
function UI:CreateDatePicker(parent, opts)
    local b = UI:CreateButton(parent, "", opts.width or 220, 22)
    b.opts = opts

    local p = CreateFrame("Frame", nil, b, "BackdropTemplate")
    b.popup = p
    p:SetSize(7 * CELL_W + 2 * PAD, 28 + 16 + 6 * CELL_H + PAD + 4)
    p:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    if p.SetBackdrop then
        p:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        p:SetBackdropColor(0.05, 0.05, 0.05, 1)
        p:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    end
    -- a solid layer under the backdrop: the tooltip texture alone lets the window behind show through
    p.bg = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    p.bg:SetPoint("TOPLEFT", 4, -4)
    p.bg:SetPoint("BOTTOMRIGHT", -4, 4)
    p.bg:SetColorTexture(0.06, 0.06, 0.07, 1)
    p:Hide()

    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOP", 0, -9)
    local function arrow(dir)
        local a = CreateFrame("Button", nil, p)
        a:SetSize(24, 24)
        local tex = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage"
        a:SetNormalTexture(tex .. "-Up")
        a:SetPushedTexture(tex .. "-Down")
        a:SetDisabledTexture(tex .. "-Disabled")
        a:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        a:SetScript("OnClick", function() b:ShowMonth(b.shownY, b.shownM + dir) end)
        return a
    end
    p.prev = arrow(-1)
    p.prev:SetPoint("TOPLEFT", 6, -4)
    p.next = arrow(1)
    p.next:SetPoint("TOPRIGHT", -6, -4)

    for i, label in ipairs(WEEKDAYS) do
        local fs = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", PAD + (i - 1) * CELL_W, -30)
        fs:SetWidth(CELL_W)
        fs:SetJustifyH("CENTER")
        fs:SetText(label)
    end

    p.cells = {}
    for i = 1, 42 do
        local c = CreateFrame("Button", nil, p)
        c:SetSize(CELL_W - 2, CELL_H - 2)
        local col, row = (i - 1) % 7, floor((i - 1) / 7)
        c:SetPoint("TOPLEFT", PAD + col * CELL_W + 1, -46 - row * CELL_H)
        c.sel = c:CreateTexture(nil, "BACKGROUND")
        c.sel:SetAllPoints()
        c.sel:SetColorTexture(1, 0.82, 0, 0.45)
        c.today = c:CreateTexture(nil, "BORDER")
        c.today:SetAllPoints()
        c.today:SetColorTexture(0.2, 0.8, 1, 0.25)
        local hl = c:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.15)
        c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.fs:SetPoint("CENTER", 0, 1)
        c.dot = c:CreateTexture(nil, "OVERLAY")
        c.dot:SetSize(4, 4)
        c.dot:SetPoint("BOTTOM", 0, 1)
        c.dot:SetColorTexture(1, 0.5, 0.1, 1)
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
                c.day = ok and d or nil
                c.fs:SetText(d)
                c.fs:SetTextColor(ok and 1 or 0.4, ok and 1 or 0.4, ok and 1 or 0.4)
                c:EnableMouse(true)
                c.sel:SetShown(k == sel)
                c.today:SetShown(k == today)
                c.markText = opts.mark and opts.mark(y, m, d) or nil
                c.dot:SetShown(c.markText ~= nil)
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
        p:Show()
        self:ShowMonth(y, m)
    end

    function b:Close() p:Hide() end

    b:SetScript("OnClick", function(self)
        if p:IsShown() then self:Close() else self:Open() end
    end)
    p:SetScript("OnShow", function(self)
        if EventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
    end)
    p:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
    p:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not b:IsMouseOver() then b:Close() end
    end)
    b:HookScript("OnHide", function() b:Close() end)

    b:Refresh()
    return b
end

UI.DatePickerAddDays = AddDays

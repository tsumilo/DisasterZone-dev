-- CDLoot: UI/Changelog.lua
-- The Changelog tab (everyone): the releases of Data/Changelog.lua in a list on the left (newest first, with
-- "Your version", "In testing" and "New" badges) and the notes of the selected release on the right, grouped by
-- section. Opening the tab marks the installed release as read (settings.changelogSeen), which clears the
-- "What's new" chip on Home.
local addonName, ns = ...

local ChangelogUI = ns:NewModule("ChangelogUI")

local floor, max = math.floor, math.max

local LIST_W = 206
local ROW_H = 40
local PAD = 12

local panel
local selected       -- version string of the release shown
local seenBefore     -- settings.changelogSeen when the tab was first opened this session (false = never read)

local function UI() return ns.UI end
local function Entries() return ns.CHANGELOG or {} end
local function Compare(a, b) return ns.Util.CompareVersions(a, b) end

local function Settings() return ns.db and ns.db.settings end

-- The newest release that is installed or older (the one "What's new" is about), or nil.
local function LatestReleased()
    for _, e in ipairs(Entries()) do
        if Compare(e.version, ns.version) <= 0 then return e end
    end
    return nil
end

local function SeenVersion()
    local s = Settings()
    return s and type(s.changelogSeen) == "string" and s.changelogSeen or nil
end

-- Is a release new to me: newer than what I had read before opening the tab this session (never read: only the
-- installed release)?
local function IsNew(e)
    local seen = seenBefore
    if seen == nil then seen = SeenVersion() or false end
    if Compare(e.version, ns.version) > 0 then return false end
    if seen == false then return Compare(e.version, ns.version) == 0 end
    return Compare(seen, e.version) < 0
end

-- "In testing" | "Your version" | "New" | nil, with its colour.
local function Badge(e)
    local c = Compare(e.version, ns.version)
    if c > 0 then return "In testing", "ff9933" end
    if c == 0 then return IsNew(e) and "New · your version" or "Your version", "33ff33" end
    if IsNew(e) then return "New", "33ff33" end
    return nil
end

local function ShortDate(e)
    local d, m = tostring(e.date or ""):match("^(%d+) (%a%a%a)")
    return d and (d .. " " .. m) or (e.date or "")
end

---------------------------------------------------------------------------
-- Public helpers (Home)
---------------------------------------------------------------------------

-- The installed release when its notes haven't been read yet, else nil.
function ChangelogUI:GetUnread()
    local e = LatestReleased()
    if not e then return nil end
    local seen = SeenVersion()
    if seen and Compare(seen, e.version) >= 0 then return nil end
    return e
end

function ChangelogUI:MarkRead()
    local e = LatestReleased()
    local s = Settings()
    if not (e and s) then return end
    if s.changelogSeen ~= e.version then
        s.changelogSeen = e.version
        ns:Fire("CHANGELOG_READ")
    end
end

function ChangelogUI:Open(version)
    if version then selected = version end
    if ns.MainFrame then ns.MainFrame:Open("changelog") end
end

function ChangelogUI:GetSelected() return selected end

---------------------------------------------------------------------------
-- Detail (right)
---------------------------------------------------------------------------

local function Pool(parent, list, i, make)
    local x = list[i]
    if not x then
        x = make(parent)
        list[i] = x
    end
    return x
end

local function NewHeading(parent)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetJustifyH("LEFT")
    return fs
end

local function NewLine(parent)
    local line = {}
    line.dot = parent:CreateTexture(nil, "ARTWORK")
    line.dot:SetSize(4, 4)
    line.dot:SetColorTexture(1, 0.5, 0, 0.9)
    line.fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    line.fs:SetJustifyH("LEFT")
    line.fs:SetWordWrap(true)
    return line
end

local function RenderDetail()
    local d = panel.detail
    local entry
    for _, e in ipairs(Entries()) do
        if e.version == selected then entry = e end
    end
    local child = d.child
    local width = max(200, floor((d.scroll:GetWidth() or 520) - 8))
    child:SetWidth(width)
    for _, h in ipairs(d.headings) do h:Hide() end
    for _, l in ipairs(d.lines) do l.dot:Hide(); l.fs:Hide() end
    if not entry then
        d.title:SetText("")
        d.sub:SetText("")
        child:SetHeight(10)
        return
    end
    d.title:SetText(UI():SafeText("CDLoot " .. entry.version .. "  |cffffffff" .. (entry.title or "") .. "|r"))
    local sub = entry.date or ""
    local badge, color = Badge(entry)
    if badge then sub = sub .. "   |cff" .. color .. badge .. "|r" end
    if Compare(entry.version, ns.version) > 0 then
        sub = sub .. "   |cff808080(you have " .. tostring(ns.version) .. ")|r"
    end
    d.sub:SetText(UI():SafeText(sub))

    local y = -4
    local hi, li = 0, 0
    for s, section in ipairs(entry.sections or {}) do
        if s > 1 then y = y - 10 end
        hi = hi + 1
        local h = Pool(child, d.headings, hi, NewHeading)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
        h:SetText(UI():SafeText(section.heading or ""))
        h:Show()
        y = y - 20
        for _, text in ipairs(section.lines or {}) do
            li = li + 1
            local line = Pool(child, d.lines, li, NewLine)
            line.fs:SetWidth(width - 16)
            line.fs:ClearAllPoints()
            line.fs:SetPoint("TOPLEFT", child, "TOPLEFT", 14, y)
            line.fs:SetText(UI():SafeText(text))
            line.dot:ClearAllPoints()
            line.dot:SetPoint("TOPLEFT", child, "TOPLEFT", 4, y - 5)
            line.fs:Show()
            line.dot:Show()
            local hgt = max(14, tonumber(line.fs:GetStringHeight()) or 14)
            y = y - hgt - 4
        end
    end
    child:SetHeight(max(10, -y + 8))
    if d.scroll.SetVerticalScroll then d.scroll:SetVerticalScroll(0) end
end

---------------------------------------------------------------------------
-- Version list (left)
---------------------------------------------------------------------------

local function InitRow(row, data)
    if not row.version then
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.5, 0, 0.18)
        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -3)
        row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 3)
        row.bar:SetWidth(3)
        row.bar:SetColorTexture(1, 0.5, 0, 1)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.06)
        row.version = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.version:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -5)
        row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.badge:SetPoint("TOPRIGHT", row, "TOPRIGHT", -6, -6)
        row.badge:SetJustifyH("RIGHT")
        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -22)
        row.title:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.title:SetJustifyH("LEFT")
        row.title:SetWordWrap(false)
        row:SetScript("OnClick", function(self)
            local e = self.__cdlData and self.__cdlData.entry
            if e then ChangelogUI:Select(e.version) end
        end)
    end
    local e = data.entry
    local on = e.version == selected
    row.sel:SetShown(on)
    row.bar:SetShown(on)
    row.version:SetText(e.version)
    local badge, color = Badge(e)
    row.badge:SetText(badge and ("|cff" .. color .. badge .. "|r") or ("|cff808080" .. ShortDate(e) .. "|r"))
    row.title:SetText(UI():SafeText(badge and (ShortDate(e) .. " · " .. (e.title or "")) or (e.title or "")))
end

function ChangelogUI:Select(version)
    selected = version
    if not panel then return end
    panel.list:Refresh()
    RenderDetail()
end

function ChangelogUI:Refresh()
    if not panel then return end
    local rows = {}
    local found = false
    for _, e in ipairs(Entries()) do
        rows[#rows + 1] = { entry = e }
        if e.version == selected then found = true end
    end
    if not found then
        local e = LatestReleased() or Entries()[1]
        selected = e and e.version or nil
    end
    panel.list:SetData(rows)
    RenderDetail()
end

function ChangelogUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p

    local left = UI():CreatePanel(p)
    left:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -4)
    left:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 4)
    left:SetWidth(LIST_W)
    local head = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", left, "TOPLEFT", 10, -9)
    head:SetText("Versions")
    local mine = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mine:SetPoint("TOPRIGHT", left, "TOPRIGHT", -10, -10)
    mine:SetText("you have " .. tostring(ns.version))
    p.list = UI():CreateScrollList(left, ROW_H, InitRow)
    p.list.frame:SetPoint("TOPLEFT", left, "TOPLEFT", 5, -28)
    p.list.frame:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -5, 6)

    local right = UI():CreatePanel(p)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
    right:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 4)
    local d = { headings = {}, lines = {} }
    p.detail = d
    d.title = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOPLEFT", right, "TOPLEFT", PAD, -PAD)
    d.title:SetPoint("RIGHT", right, "RIGHT", -PAD, 0)
    d.title:SetJustifyH("LEFT")
    d.title:SetWordWrap(false)
    d.sub = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d.sub:SetPoint("TOPLEFT", d.title, "BOTTOMLEFT", 0, -5)
    d.sub:SetJustifyH("LEFT")
    d.sub:SetTextColor(0.7, 0.7, 0.7)
    local rule = right:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 1, 1, 0.15)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", right, "TOPLEFT", PAD, -52)
    rule:SetPoint("TOPRIGHT", right, "TOPRIGHT", -PAD, -52)
    d.scroll = CreateFrame("ScrollFrame", "CDLootChangelogScroll", right, "UIPanelScrollFrameTemplate")
    d.scroll:SetPoint("TOPLEFT", right, "TOPLEFT", PAD, -60)
    d.scroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -28, 8)
    d.child = CreateFrame("Frame", nil, d.scroll)
    d.child:SetSize(500, 10)
    d.scroll:SetScrollChild(d.child)
    d.scroll:HookScript("OnSizeChanged", function() RenderDetail() end)

    function p:OnPanelShown()
        if seenBefore == nil then seenBefore = SeenVersion() or false end
        ChangelogUI:MarkRead()
        ChangelogUI:Refresh()
    end
    return p
end

function ChangelogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("changelog", "Changelog", 5, function(parent) return ChangelogUI:CreatePanel(parent) end)
    end
    ns:RegisterSlash("changelog", function() ChangelogUI:Open() end, "open the Changelog: what's new in each version")
end

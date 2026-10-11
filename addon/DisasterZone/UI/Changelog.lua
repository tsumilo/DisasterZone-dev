if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Changelog.lua", ...) then return end -- DisasterZone: UI/Changelog.lua
-- The Changelog tab (everyone), in three layers (2026-10-11, dev/art/casc/changelog_mockup): a release's highlights as
-- cards, its other sections folded to one line each (open one for its lines), and the lines themselves.
--   Left: a search over every release, two pinned views (Since your last visit when two or more releases are unread,
--   From your feedback when something I asked for shipped) and the releases grouped by series (older ones fold).
--   Right: a fixed banner and a filter row (area chips, "Just for me"), then what scrolls.
-- Data/Changelog.lua sections may carry (all optional; old releases show as they always did):
--   area = "raids" | "loot" | "gear" | "guild" | "games" | "class" | "look" | "speed" | "fixes" (else: from the
--   heading's prefix), kind = "new" | "changed" | "fixed", lead = one line (else the first line), hi = true (a
--   highlight card), art = a raid key for its card, open = where Show me goes (a page key, a share-link ref, or
--   "settings/<section>"), spot = a spot a page registered (ChangelogUI:RegisterSpot), ["for"] = "council officers
--   leaders gm PALADIN ..." (who it is for: "Just for me" folds the rest away). A line may be { "text", ["for"] = ... }
--   and lines starting "Fixed: " move to the release's Fixes. A line from the guild's feedback ({ text, fb, by, mt, k },
--   Core/Feedback.lua) names who asked for it; mine glows.
-- Opening the tab marks the installed release as read (settings.changelogSeen). Home's What's new chip opens a short
-- pop-up of the highlights (ChangelogUI:OpenPopup); Show me opens the page and lights the new part (UI/Tour.lua).
local addonName, ns = ...

local ChangelogUI = ns:NewModule("ChangelogUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tinsert, tconcat, sort = table.insert, table.concat, table.sort
local strlower, strfind, strmatch, strgsub = string.lower, string.find, string.match, string.gsub

local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local OUTLAND = "Interface\\Glues\\LoadingScreens\\LoadScreenOutland"

-- sizes (one grid for the page)
local L = {
    PAD = 6, GAP = 8, LIST_W = 200, BAN_H = 75, TB_H = 22, CARD_H = 150, ROW_H = 37, LINE_GAP = 3, HEAD_H = 20,
    GROUP_H = 22, VROW_PAD = 5, PIN_H = 40,
}

-- area key -> label, atlas icon, the art set that icon needs (else fallback icon), the raid painting of its cards
local AREAS = {
    raids = { "Raids", 45, 4, 25, "kara" }, loot = { "Loot", 60, 7, 26, "bt" }, gear = { "Gear", 58, 6, 40, "gruul" },
    guild = { "Guild", 46, 4, 25, "ssc" }, games = { "Games", 21, 0, 21, "za" }, class = { "Class tools", 62, 7, 13, "hyjal" },
    look = { "Look", 15, 0, 15, "tk" }, speed = { "Speed", 59, 7, 13, "mag" }, fixes = { "Fixes", 13, 0, 13, "other" },
    other = { "Other", 25, 0, 25, "other" },
}
local AREA_ORDER = { "raids", "loot", "gear", "guild", "games", "class", "look", "speed", "other", "fixes" }
-- a heading's prefix ("Raids: ...", "Gear sim: ...") -> area, for sections without one
local PREFIX_AREA = {
    ["raids"] = "raids", ["raid"] = "raids", ["loot council"] = "loot", ["loot"] = "loot", ["my bis"] = "gear",
    ["gear sim"] = "gear", ["atlas"] = "gear", ["strategy boards"] = "raids", ["strategy"] = "raids",
    ["dungeons"] = "guild", ["paladins"] = "class", ["swing timer"] = "class", ["azeromon"] = "games",
    ["home"] = "raids", ["members"] = "guild", ["guild"] = "guild", ["games"] = "games",
}
-- prefixes the area tag already says: "Raids: hide a raid" shows as "Hide a raid"
local DROP_PREFIX = { ["raids"] = true, ["loot council"] = true }
local KIND = { new = { "New", "bis" }, changed = { "Changed", "alt" }, fixed = { "Fixed", "mute" } }
local AUD_LABEL = { council = "the loot council", officers = "officers", leaders = "raid leaders",
                    gm = "the Guild Master" }

local panel
local st = { view = nil, query = "", area = nil, open = {}, card = nil, collapsed = {} }
local seenBefore     -- settings.changelogSeen when the tab was first opened this session (false = never read)
local spots = {}     -- name -> function() return frame end (ChangelogUI:RegisterSpot)

local function UI() return ns.UI end
local function Util() return ns.Util end
local function Entries() return ns.CHANGELOG or {} end
local function Compare(a, b) return ns.Util.CompareVersions(a, b) end
local function Settings() return ns.db and ns.db.settings end

---------------------------------------------------------------------------
-- Releases: which are read, which are new
---------------------------------------------------------------------------

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

-- The releases I haven't read (newest first), as of opening the tab this session.
local function Unread()
    local out = {}
    for _, e in ipairs(Entries()) do
        if IsNew(e) then out[#out + 1] = e end
    end
    return out
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
-- Who a section or line is for ("Just for me")
---------------------------------------------------------------------------

local roles     -- { gm, officers, council, leaders, class }, worked out once per refresh

local function MyRoles()
    if roles then return roles end
    local r = {}
    local G, me = ns.Guild, Util().PlayerKey and Util().PlayerKey()
    if G and me then
        r.gm = select(2, pcall(G.IsGM, G, me)) == true
        r.officers = r.gm or select(2, pcall(G.IsOfficer, G, me)) == true
        r.council = r.gm or select(2, pcall(G.AmICouncil, G)) == true
        r.leaders = r.officers or (G.IsRaidLeader and select(2, pcall(G.IsRaidLeader, G, me)) == true)
    end
    r.class = select(2, UnitClass("player"))
    roles = r
    return r
end

-- "officers leaders" -> { "officers", "leaders" } (nil: everyone).
local function ParseFor(v)
    if type(v) == "table" then return #v > 0 and v or nil end
    if type(v) ~= "string" or v == "" then return nil end
    local out = {}
    for w in v:gmatch("[%w_]+") do out[#out + 1] = w end
    return #out > 0 and out or nil
end

local function IsForMe(aud)
    if not aud then return true end
    local r = MyRoles()
    for _, tag in ipairs(aud) do
        if r[tag] == true or tag == r.class then return true end
    end
    return false
end

local function ForMeOn()
    local s = Settings()
    return not (s and s.changelogForMe == false)
end

-- "the loot council and paladins" from a set of audience tags.
local function WhoText(tags)
    local list = {}
    for _, t in ipairs(tags) do
        local label = AUD_LABEL[t]
        if not label then
            local name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[t]) or t
            label = strlower(name) .. "s"
        end
        list[#list + 1] = label
    end
    if #list == 0 then return "others" end
    if #list == 1 then return list[1] end
    return tconcat(list, ", ", 1, #list - 1) .. " and " .. list[#list]
end

---------------------------------------------------------------------------
-- The notes, normalized once: sections with an area, a kind, a title, a lead and their lines
---------------------------------------------------------------------------

local index

local function AreaOf(sec)
    if AREAS[sec.area or ""] then return sec.area end
    local h = strlower(tostring(sec.heading or ""))
    local pre = strmatch(h, "^(.-):") or strmatch(h, "^(.-) >")
    if pre and PREFIX_AREA[pre] then return PREFIX_AREA[pre] end
    if strfind(h, "^fix") or strfind(h, "fixes$") or strfind(h, "fixed$") then return "fixes" end
    if strfind(h, "raid") or strfind(h, "strateg") or strfind(h, "team") or strfind(h, "guest") then return "raids" end
    if strfind(h, "loot") or strfind(h, "council") or strfind(h, "roll") or strfind(h, "vote") then return "loot" end
    if strfind(h, "bis") or strfind(h, "gear") or strfind(h, "item") then return "gear" end
    if strfind(h, "game") or strfind(h, "bingo") or strfind(h, "azeromon") then return "games" end
    return "other"
end

local function TitleOf(heading)
    local h = tostring(heading or "")
    local pre, rest = strmatch(h, "^([^:]+): (.+)$")
    if pre and DROP_PREFIX[strlower(pre)] then return (rest:gsub("^%l", string.upper)) end
    return h
end

local function LineText(raw)
    if type(raw) == "table" then return tostring(raw[1] or "") end
    return tostring(raw or "")
end

local function Norm()
    local src = Entries()
    if index and index.src == src and index.n == #src then return index end
    index = { src = src, n = #src, list = {}, by = {} }
    for _, e in ipairs(src) do
        local ne = { version = e.version, date = e.date, title = e.title, entry = e, sections = {} }
        local fixes = {}
        for i, sec in ipairs(e.sections or {}) do
            local area = AreaOf(sec)
            local isFix = sec.kind == "fixed" or area == "fixes"
            local lines = {}
            for _, raw in ipairs(sec.lines or {}) do
                local text = LineText(raw)
                local ln = { text = text, raw = raw, aud = type(raw) == "table" and ParseFor(raw["for"]) or nil }
                local fixed = strmatch(text, "^Fixed: (.+)$")
                if fixed then
                    ln.text = fixed:gsub("^%l", string.upper)
                    fixes[#fixes + 1] = ln
                elseif isFix then
                    fixes[#fixes + 1] = ln
                else
                    lines[#lines + 1] = ln
                end
            end
            if not isFix and #lines > 0 then
                ne.sections[#ne.sections + 1] = {
                    id = e.version .. "#" .. i, version = e.version, heading = sec.heading, title = TitleOf(sec.heading),
                    area = area, kind = KIND[sec.kind or ""] and sec.kind or nil, lead = sec.lead, hi = sec.hi and true,
                    art = sec.art, open = sec.open, spot = sec.spot, aud = ParseFor(sec["for"]), lines = lines,
                }
            end
        end
        if #fixes > 0 then
            ne.sections[#ne.sections + 1] = { id = e.version .. "#fixes", version = e.version, heading = "Fixes",
                title = "Fixes", area = "fixes", kind = "fixed", lines = fixes, isFix = true }
        end
        index.list[#index.list + 1] = ne
        index.by[e.version] = ne
    end
    return index
end

-- A section as I see it: its lines for me, how many are left out, whether it is for me at all.
local function View(sec)
    local forMe = ForMeOn()
    local mine = not forMe or IsForMe(sec.aud)
    local shown, hidden, hiddenTags = {}, 0, {}
    local credited = false
    for _, ln in ipairs(sec.lines) do
        if not forMe or IsForMe(ln.aud) then
            shown[#shown + 1] = ln
        else
            hidden = hidden + 1
            for _, t in ipairs(ln.aud or {}) do hiddenTags[t] = true end
        end
        if ns.Feedback and ns.Feedback.LineIsMine and ns.Feedback:LineIsMine(ln.raw) then credited = true end
    end
    local lead = sec.lead or (shown[1] and shown[1].text) or (sec.lines[1] and sec.lines[1].text) or ""
    return { mine = mine and #shown > 0, lines = shown, hidden = hidden, hiddenTags = hiddenTags, lead = lead,
             credited = credited }
end

local function AreaIcon(area, size, color)
    local a = AREAS[area] or AREAS.other
    local i = ns:HasAssets(a[3]) and a[2] or a[4]
    return UI():AtlasIconText(i, size or 12, color)
end

local function AreaAtlas(area)
    local a = AREAS[area] or AREAS.other
    return ns:HasAssets(a[3]) and a[2] or a[4]
end

---------------------------------------------------------------------------
-- Public helpers (Home, notifications, links)
---------------------------------------------------------------------------

-- The installed release when its notes haven't been read yet, else nil.
function ChangelogUI:GetUnread()
    local e = LatestReleased()
    if not e then return nil end
    local seen = SeenVersion()
    if seen and Compare(seen, e.version) >= 0 then return nil end
    return e
end

-- The installed or older releases I haven't read (as saved now, newest first).
function ChangelogUI:GetUnreadList()
    local out = {}
    local seen = SeenVersion()
    for _, e in ipairs(Entries()) do
        if Compare(e.version, ns.version) <= 0 then
            if seen and Compare(seen, e.version) >= 0 then break end
            out[#out + 1] = e
            if not seen then break end      -- never read: only the installed release is news
        end
    end
    return out
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

-- Opens the tab on a release (a version string), on "since" / "feedback", or on its default view.
function ChangelogUI:Open(version)
    if version then
        st.view = version
        st.query = ""
        st.area = nil
        if panel and panel.search then panel.search:SetText("") end
    end
    if ns.MainFrame then ns.MainFrame:Open("changelog") end
end

-- The release shown (a version), nil on a pinned view or a search.
function ChangelogUI:GetSelected()
    if st.view and st.view ~= "since" and st.view ~= "feedback" then return st.view end
    return nil
end

function ChangelogUI:GetView() return st.view end

-- A page names a control Show me can light: fn() returns the frame (or nil while it isn't on screen).
function ChangelogUI:RegisterSpot(name, fn) spots[name] = fn end

ChangelogUI.Norm = function() return Norm() end
ChangelogUI.View = View
ChangelogUI.IsForMe = IsForMe
ChangelogUI.ResetRoles = function() roles = nil end

---------------------------------------------------------------------------
-- Show me: open the page a section is about and light its new part
---------------------------------------------------------------------------

local backbar

local function Route(open)
    if type(open) ~= "string" or open == "" then return false end
    local MF = ns.MainFrame
    local page, sub = strmatch(open, "^(%a+)/(%a+)$")
    if page == "settings" then
        MF:Open("settings")
        if ns.SettingsUI and ns.SettingsUI.SelectSection then ns.SettingsUI:SelectSection(sub) end
        return MF:GetSelectedTab() == "settings"
    end
    local Share = ns.Share
    if Share and ((Share.PAGES and Share.PAGES[open]) or strfind(open, ":")) then
        return (Share:Open(open)) and true or false
    end
    if MF:IsPageShown(open) or MF:GetPageLabel(open) then
        MF:Open(open)
        return true
    end
    return false
end

local function HideBackBar()
    if backbar then backbar:Hide() end
end

local function ShowBackBar(sec, view)
    local host = ns.MainFrame and ns.MainFrame:GetFrame()
    if not host then return end
    if not backbar then
        local b = CreateFrame("Frame", nil, host)
        b:SetHeight(24)
        b:SetFrameStrata("DIALOG")
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetAllPoints()
        b.bg:SetColorTexture(0.08, 0.07, 0.06, 0.97)
        UI():AddEdges(b)
        UI():SetEdgeColor(b, 0.56, 0.45, 0.13, 1)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(12, 12)
        b.icon:SetPoint("LEFT", 9, 0)
        b.icon:SetTexture(UI().ICON_ATLAS)
        local c = UI():IconCoords(UI().ICON.notes)
        b.icon:SetTexCoord(c[1], c[2], c[3], c[4])
        b.icon:SetVertexColor(1, 0.82, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.back = UI():CreateSleekButton(b, "Back", 50, 18, function()
            HideBackBar()
            ChangelogUI:Open(b.view)
        end)
        b.back:SetPoint("LEFT", b.text, "RIGHT", 10, 0)
        b.close = UI():CreateCloseButton(b, 16, HideBackBar)
        b.close:SetPoint("LEFT", b.back, "RIGHT", 4, 0)
        b:SetScript("OnUpdate", function(self, dt)
            self.t = (self.t or 0) + dt
            if self.t < 0.3 then return end
            self.t = 0
            local tab = ns.MainFrame:GetSelectedTab()
            if not tab or (self.tab and tab ~= self.tab) then self:Hide() end
        end)
        backbar = b
    end
    backbar.view = view
    backbar.text:SetText("From What's new: |cffffffff" .. UI():SafeText(sec.title) .. "|r")
    backbar:SetWidth(floor((backbar.text:GetStringWidth() or 120) + 9 + 12 + 6 + 10 + 50 + 4 + 16 + 10))
    backbar:ClearAllPoints()
    backbar:SetPoint("TOP", host, "TOP", 0, -76)
    backbar.tab = ns.MainFrame:GetSelectedTab()
    backbar.t = 0
    backbar:Show()
end

-- Show me for a section: its page, then the tour box over it (its spot lit, or over the dimmed window).
function ChangelogUI:ShowMe(sec)
    if type(sec) == "string" then
        for _, ne in ipairs(Norm().list) do
            for _, s in ipairs(ne.sections) do if s.id == sec then sec = s end end
        end
    end
    if type(sec) ~= "table" or not sec.open then return false end
    local fromView = st.view or sec.version
    if ns.ChangelogPopup then ns.ChangelogPopup:Hide() end
    if not Route(sec.open) then
        ns:Print("That page isn't open to you.")
        return false
    end
    ShowBackBar(sec, fromView)
    local T = ns.Tour
    if not T then return true end
    local v = View(sec)
    local text = v.lead
    local more = {}
    for i = 1, min(2, #v.lines) do
        if v.lines[i].text ~= v.lead then more[#more + 1] = v.lines[i].text end
    end
    if #more > 0 then text = text .. "\n\n" .. tconcat(more, "\n") end
    local spot = sec.spot and spots[sec.spot]
    T:Register("whatsnew", {
        title = "What's new", quiet = true, nosave = true,
        host = function() return ns.MainFrame:GetFrame() end,
        alive = function() return ns.MainFrame:GetSelectedTab() ~= nil end,
        chapters = { { key = "show", title = sec.title, steps = { {
            title = sec.title, text = text, hint = "New in " .. sec.version,
            anchor = spot and function() return spot() end or nil, side = "left",
        } } } },
    })
    T:Start("whatsnew")
    return true
end

---------------------------------------------------------------------------
-- Small parts
---------------------------------------------------------------------------

local function Text(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

-- The height of a wrapped string at width w (the mock doesn't wrap: count the lines from the width).
local function WrapH(fs, w, lineH)
    lineH = lineH or 13
    local h = tonumber(fs:GetStringHeight()) or 0
    local uw = tonumber(fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 0
    if w > 0 and uw > w and h <= lineH + 1 then h = ceil(uw / w) * lineH end
    return max(lineH, h)
end

local function Tex(parent, layer, r, g, b, a, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetColorTexture(r or 1, g or 1, b or 1, a or 1)
    return t
end

local function AtlasTex(tex, i, r, g, b)
    tex:SetTexture(UI().ICON_ATLAS)
    local c = UI():IconCoords(i)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
    tex:SetVertexColor(r or 1, g or 1, b or 1)
end

-- A face: a gold ring on a dark disc around an icon (the Events pages' look).
local function Face(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.disc = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.disc:SetTexture(MEDIA .. "Strategy\\disc")
    f.disc:SetVertexColor(0.05, 0.05, 0.06, 0.95)
    f.disc:SetAllPoints()
    f.ring = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.ring:SetTexture(MEDIA .. "Events\\ring")
    f.ring:SetVertexColor(1, 0.82, 0)
    f.ring:SetPoint("CENTER")
    f.ring:SetSize(size + 4, size + 4)
    f.icon = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.icon:SetSize(floor(size * 0.46), floor(size * 0.46))
    f.icon:SetPoint("CENTER")
    function f:SetIcon(i) AtlasTex(self.icon, i, 1, 0.86, 0.4) end
    return f
end

-- A raid's painting (RaidPlanUI's crop, under the logo band) on a texture for a w x h box.
local function PaintRaid(tex, key, w, h)
    local PlanUI = ns.RaidPlanUI
    if PlanUI and PlanUI.RaidArt then
        local file, l, r, t, b = PlanUI:RaidArt(key or "other", w, h, 0.95)
        if t < 0.29 then t, b = 0.29, b + 0.29 - t end
        if b > 1 then t, b = t - (b - 1), 1 end
        tex:SetTexture(file)
        tex:SetTexCoord(l, r, t, b)
    else
        tex:SetColorTexture(0.1, 0.1, 0.12, 1)
    end
end

local function PaintOutland(tex, w, h)
    local E = ns.EventUI
    if E and E.ArtCoords then
        local path, l, r, t, b = E:ArtCoords("outland", w, h, 0.5, 0.55, 0.95)
        tex:SetTexture(OUTLAND or path)
        tex:SetTexCoord(l, r, t, b)
    else
        tex:SetColorTexture(0.1, 0.1, 0.12, 1)
    end
end

local function Shade(f)
    if ns.EventUI and ns.EventUI.AddShade then return ns.EventUI:AddShade(f) end
end

-- A gold "Show me" link with a chevron.
local function NewGoLink(parent, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(16)
    b.fs = Text(b, "GameFontNormalSmall")
    b.fs:SetPoint("LEFT", 0, 0)
    b.fs:SetText(label or "Show me")
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(9, 9)
    b.chev:SetPoint("LEFT", b.fs, "RIGHT", 3, 0)
    UI():SetChevron(b.chev, true)
    b.chev:SetVertexColor(1, 0.82, 0)
    function b:SetLabel(t)
        self.fs:SetText(t)
        self:SetWidth(floor((self.fs:GetStringWidth() or 40) + 14))
    end
    b:SetLabel(label or "Show me")
    b:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 0.95, 0.6) end)
    b:SetScript("OnLeave", function(self) self.fs:SetTextColor(1, 0.82, 0) end)
    return b
end

local function Pool(list, i, make)
    local x = list[i]
    if not x then
        x = make()
        list[i] = x
    end
    return x
end

---------------------------------------------------------------------------
-- The credits of a line from the guild's feedback
---------------------------------------------------------------------------

-- The text of a changelog line, the credit after it, and whether one of my characters is credited.
local function LineParts(entry)
    if type(entry) ~= "table" then return tostring(entry or ""), nil, false end
    local text = tostring(entry[1] or "")
    local F = ns.Feedback
    local credit
    local names = type(entry.by) == "table" and entry.by or {}
    if #names > 0 or (tonumber(entry.mt) or 0) > 0 then
        local info = F and F.KIND_INFO and F.KIND_INFO[entry.k or "idea"]
        local icon = info and ("|T%d:12:12:0:-1:64:64:5:59:5:59|t "):format(info.icon) or ""
        local who = #names > 0 and tconcat(names, ", ") or "the guild"
        if (tonumber(entry.mt) or 0) > 0 then who = who .. " +" .. entry.mt end
        credit = icon .. "|cffa8a8a8" .. who .. "|r"
    end
    local mine = F and F.LineIsMine and F:LineIsMine(entry) or false
    return text, credit, mine
end
ChangelogUI.LineParts = LineParts

-- "Thanks to A and B for the ideas behind 3 of these changes." from an entry's credits (only the credited lines are
-- theirs, so it says how many: one release of many changes is not all theirs), or nil.
local function ThanksLine(entry)
    local seen, names = {}, {}
    local lines, bugs = 0, 0
    for _, section in ipairs(entry.sections or {}) do
        for _, l in ipairs(section.lines or {}) do
            if type(l) == "table" and type(l.by) == "table" then
                local any = false
                for _, n in ipairs(l.by) do
                    if type(n) == "string" then
                        any = true
                        if not seen[n] then seen[n] = true; names[#names + 1] = n end
                    end
                end
                if any then
                    lines = lines + 1
                    if l.k == "bug" then bugs = bugs + 1 end
                end
            end
        end
    end
    if #names == 0 then return nil end
    sort(names)
    local shown = {}
    for i = 1, min(#names, 8) do shown[i] = names[i] end
    local rest = #names - #shown
    local list
    if rest > 0 then
        list = tconcat(shown, ", ") .. " and " .. rest .. (rest == 1 and " other" or " others")
    elseif #shown == 1 then
        list = shown[1]
    else
        list = tconcat(shown, ", ", 1, #shown - 1) .. " and " .. shown[#shown]
    end
    local what
    if bugs == lines then
        what = lines == 1 and "the bug report behind" or "the bug reports behind"
    elseif bugs == 0 then
        what = lines == 1 and "the idea behind" or "the ideas behind"
    else
        what = "the bug reports and ideas behind"
    end
    local count = lines == 1 and "one of these changes" or (lines .. " of these changes")
    return "Thanks to " .. list .. " for " .. what .. " " .. count .. "."
end
ChangelogUI.ThanksLine = ThanksLine

local function CreditTooltip(owner, data)
    if type(data) ~= "table" then return end
    GameTooltip:SetOwner(owner, "ANCHOR_TOPRIGHT")
    local F = ns.Feedback
    local names = {}
    for _, n in ipairs(data.by or {}) do names[#names + 1] = n end
    GameTooltip:AddLine(#names > 0 and ("Asked for by " .. tconcat(names, ", ")) or "From the guild's feedback",
        1, 0.82, 0, true)
    if (tonumber(data.mt) or 0) > 0 then
        GameTooltip:AddLine(data.mt == 1 and "and 1 more said me too" or ("and " .. data.mt .. " more said me too"),
            0.8, 0.8, 0.8)
    end
    for _, no in ipairs(data.fb or {}) do
        local item = F and F.GetByNumber and F:GetByNumber(no)
        if item then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("#" .. no .. "  " .. Util().ShortName(item.author), 0.7, 0.7, 0.7)
            GameTooltip:AddLine(item.text, 1, 1, 1, true)
        end
    end
    if F and F.LineIsMine and F:LineIsMine(data) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("You asked for this. Thank you!", 0.45, 0.85, 0.45)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Section rows: one line folded (title, kind, area, lead, count), the lines when open
---------------------------------------------------------------------------

local function NewLine(parent)
    local line = {}
    line.dot = Tex(parent, "ARTWORK", 1, 0.5, 0, 0.9)
    line.dot:SetSize(4, 4)
    line.fs = Text(parent, "GameFontHighlight")
    line.fs:SetWordWrap(true)
    line.credit = Text(parent, "GameFontHighlightSmall")
    line.credit:SetJustifyH("RIGHT")
    line.bg = Tex(parent, "BACKGROUND", 1, 0.82, 0, 0.08, 1)
    line.bar = Tex(parent, "ARTWORK", 1, 0.82, 0, 0.9)
    line.bar:SetWidth(2)
    line.hover = CreateFrame("Frame", nil, parent)
    line.hover:SetScript("OnEnter", function(self) CreditTooltip(self, self.data) end)
    line.hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return line
end

local function HideLine(l)
    l.dot:Hide(); l.fs:Hide(); l.credit:Hide(); l.bg:Hide(); l.bar:Hide(); l.hover:Hide()
end

-- Lays out lines from y (negative, from the frame's top) at x within width w; returns the new y.
local function LayLines(f, list, lines, x, y, w, marks)
    for i, ln in ipairs(lines) do
        local line = Pool(list, i, function() return NewLine(f) end)
        local text, credit, mine = LineParts(ln.raw)
        text = ln.text or text
        if marks then text = marks(text) end
        if mine then
            local you = "|cffffd100you asked for this|r"
            if credit then credit = credit .. "   " .. you else text = text .. "   " .. you end
        end
        local creditW = 0
        if credit then
            line.credit:SetText(UI():SafeText(credit))
            local cw = (tonumber(line.credit:GetStringWidth()) or 0) + 1
            line.fs:SetWidth(w - 12)
            line.fs:SetText(UI():SafeText(text))
            local tw = tonumber(line.fs.GetUnboundedStringWidth and line.fs:GetUnboundedStringWidth()
                or line.fs:GetStringWidth()) or 0
            line.credit:SetWidth(cw)
            line.credit:ClearAllPoints()
            if tw + 18 + cw <= w - 12 then
                line.credit:SetPoint("TOPLEFT", f, "TOPLEFT", x + 10 + tw + 18, y - 1)
            else
                line.credit:SetPoint("TOPRIGHT", f, "TOPLEFT", x + w - 4, y - 1)
                creditW = cw + 14
            end
            line.credit:Show()
        else
            line.credit:Hide()
        end
        local tw = w - 12 - creditW
        line.fs:SetWidth(tw)
        line.fs:ClearAllPoints()
        line.fs:SetPoint("TOPLEFT", f, "TOPLEFT", x + 10, y)
        line.fs:SetText(UI():SafeText(text))
        line.fs:Show()
        line.dot:ClearAllPoints()
        line.dot:SetPoint("TOPLEFT", f, "TOPLEFT", x + 1, y - 5)
        line.dot:Show()
        local hgt = WrapH(line.fs, tw, 13)
        if type(ln.raw) == "table" and (ln.raw.by or ln.raw.fb or ln.raw.mt) then
            line.hover.data = ln.raw
            line.hover:ClearAllPoints()
            line.hover:SetPoint("TOPLEFT", f, "TOPLEFT", x - 4, y + 2)
            line.hover:SetSize(w + 4, hgt + 4)
            line.hover:Show()
        else
            line.hover:Hide()
        end
        line.bg:SetShown(mine)
        line.bar:SetShown(mine)
        if mine then
            line.bg:ClearAllPoints()
            line.bg:SetPoint("TOPLEFT", f, "TOPLEFT", x - 4, y + 3)
            line.bg:SetSize(w + 4, hgt + 5)
            line.bar:ClearAllPoints()
            line.bar:SetPoint("TOPLEFT", f, "TOPLEFT", x - 4, y + 3)
            line.bar:SetHeight(hgt + 5)
        end
        y = y - hgt - L.LINE_GAP - 2
    end
    for i = #lines + 1, #list do HideLine(list[i]) end
    return y
end

local function NewRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r.bg = Tex(r, "BACKGROUND", 0.07, 0.07, 0.085, 0.86)
    r.bg:SetAllPoints()
    r.hl = Tex(r, "HIGHLIGHT", 1, 1, 1, 0.03)
    r.hl:SetPoint("TOPLEFT")
    r.hl:SetPoint("TOPRIGHT")
    r.hl:SetHeight(L.ROW_H)
    r.rule = Tex(r, "BORDER", 0.12, 0.12, 0.14, 1)
    r.rule:SetHeight(1)
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.bar = Tex(r, "ARTWORK", 1, 0.82, 0, 1)
    r.bar:SetWidth(3)
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.tile = CreateFrame("Frame", nil, r)
    r.tile:SetSize(23, 23)
    r.tile:SetPoint("TOPLEFT", 8, -7)
    r.tile.bg = Tex(r.tile, "BACKGROUND", 0.094, 0.094, 0.11, 1)
    r.tile.bg:SetAllPoints()
    UI():AddEdges(r.tile)
    UI():SetEdgeColor(r.tile, 0.2, 0.2, 0.23, 1)
    r.tile.icon = r.tile:CreateTexture(nil, "ARTWORK")
    r.tile.icon:SetSize(13, 13)
    r.tile.icon:SetPoint("CENTER")
    r.title = Text(r, "GameFontHighlight")
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", 40, -6)
    r.kind = UI():CreateTagPill(r, 13)
    r.tag = Text(r, "GameFontDisableSmall")
    r.you = UI():CreateTagPill(r, 13)
    r.lead = Text(r, "GameFontDisableSmall")
    r.lead:SetPoint("TOPLEFT", r, "TOPLEFT", 40, -22)
    r.count = Text(r, "GameFontHighlight")
    r.count:SetTextColor(0.74, 0.74, 0.76)
    r.chev = r:CreateTexture(nil, "ARTWORK")
    r.chev:SetSize(9, 9)
    r.chev:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -14)
    r.count:SetPoint("RIGHT", r.chev, "LEFT", -4, 0)
    r.more = Text(r, "GameFontDisableSmall")
    r.go = NewGoLink(r)
    r.lines = {}
    r:SetScript("OnClick", function(self)
        if not self.sec then return end
        if self.isCard then
            st.card = nil
        else
            st.open[self.sec.id] = not st.open[self.sec.id] or nil
        end
        ChangelogUI:Render(true)
    end)
    r.go:SetScript("OnClick", function(self) ChangelogUI:ShowMe(self:GetParent().sec) end)
    return r
end

-- Fills a section row; returns its height. opts: { version = show the version tag, open = lines shown }
local function FillRow(r, sec, v, w, opts)
    r.sec = sec
    r:SetWidth(w)
    local open = opts.open
    r.bar:SetShown(open)
    r.bg:SetColorTexture(open and 0.1 or 0.07, open and 0.098 or 0.07, open and 0.086 or 0.085, open and 0.92 or 0.86)
    AtlasTex(r.tile.icon, AreaAtlas(sec.area), 0.81, 0.81, 0.81)
    r.title:SetText(UI():SafeText(sec.title))
    local x = 40 + (tonumber(r.title:GetStringWidth()) or 0) + 8
    local kinfo = sec.kind and KIND[sec.kind]
    if kinfo then
        r.kind:Set(kinfo[1], kinfo[2])
        r.kind:ClearAllPoints()
        r.kind:SetPoint("LEFT", r, "TOPLEFT", x, -12)
        r.kind:Show()
        x = x + (r.kind:GetWidth() or 40) + 7
    else
        r.kind:Hide()
    end
    local tag = opts.version and ("|cff9e9e9e" .. sec.version .. "|r")
        or (AreaIcon(sec.area, 10, { 0.55, 0.55, 0.57 }) .. " " .. (AREAS[sec.area] or AREAS.other)[1])
    r.tag:SetText(tag)
    r.tag:ClearAllPoints()
    r.tag:SetPoint("LEFT", r, "TOPLEFT", x, -12)
    r.tag:Show()
    x = x + (tonumber(r.tag:GetStringWidth()) or 30) + 8
    -- the right side: count + chevron, Show me, what Just for me left out
    local right = 10 + 9 + 4
    r.count:SetText(tostring(#v.lines))
    right = right + (tonumber(r.count:GetStringWidth()) or 8) + 10
    UI():SetChevron(r.chev, not open)
    if open then
        r.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    end
    r.chev:SetVertexColor(0.74, 0.74, 0.76)
    if sec.open then
        r.go:ClearAllPoints()
        r.go:SetPoint("RIGHT", r, "TOPRIGHT", -right, -18)
        r.go:Show()
        right = right + (r.go:GetWidth() or 50) + 12
    else
        r.go:Hide()
    end
    if v.hidden > 0 then
        local tags = {}
        for t in pairs(v.hiddenTags) do tags[#tags + 1] = t end
        sort(tags)
        r.more:SetText(("+%d for %s"):format(v.hidden, WhoText(tags)))
        r.more:ClearAllPoints()
        r.more:SetPoint("RIGHT", r, "TOPRIGHT", -right, -18)
        r.more:Show()
        right = right + (tonumber(r.more:GetStringWidth()) or 40) + 12
    else
        r.more:Hide()
    end
    if v.credited and x + 120 < w - right then
        local F = ns.Feedback
        local info = F and F.KIND_INFO and F.KIND_INFO.idea
        r.you:Set("You asked for this", "bis", info and info.icon or nil)
        if r.you.icon then r.you.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        r.you:ClearAllPoints()
        r.you:SetPoint("LEFT", r, "TOPLEFT", x, -12)
        r.you:Show()
    else
        r.you:Hide()
    end
    r.lead:SetWidth(max(60, w - 40 - right))
    r.lead:SetText(UI():SafeText(v.lead))
    local h = L.ROW_H
    if open then
        local y = LayLines(r, r.lines, v.lines, 44, -L.ROW_H - 6, w - 44 - 14)
        h = -y + 4
    else
        for _, l in ipairs(r.lines) do HideLine(l) end
    end
    r:SetHeight(h)
    r:Show()
    return h
end

---------------------------------------------------------------------------
-- Highlight cards
---------------------------------------------------------------------------

local function NewCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(L.CARD_H)
    c.bg = Tex(c, "BACKGROUND", 0.07, 0.07, 0.085, 1)
    c.bg:SetAllPoints()
    UI():AddEdges(c)
    c.artF = CreateFrame("Frame", nil, c)
    c.artF:SetPoint("TOPLEFT", 1, -1)
    c.artF:SetPoint("TOPRIGHT", -1, -1)
    c.artF:SetHeight(65)
    c.art = c.artF:CreateTexture(nil, "BACKGROUND")
    c.art:SetAllPoints()
    if ns.EventUI and ns.EventUI.AddShade then ns.EventUI:AddShade(c.artF, "card") end
    c.face = Face(c, 40)
    c.face:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -39)
    c.ver = UI():CreateTagPill(c, 14)
    c.ver:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -6)
    c.title = Text(c, "GameFontHighlight", 12)
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 9, -84)
    c.title:SetPoint("RIGHT", c, "RIGHT", -8, 0)
    c.pitch = Text(c, "GameFontDisableSmall")
    c.pitch:SetWordWrap(true)
    c.pitch:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)
    c.pitch:SetPoint("RIGHT", c, "RIGHT", -8, 0)
    if c.pitch.SetMaxLines then c.pitch:SetMaxLines(2) end
    c.go = UI():CreateSleekButton(c, "Show me", 70, 18, function(self) ChangelogUI:ShowMe(self:GetParent().sec) end,
        "primary")
    c.go:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 9, 8)
    c.area = Text(c, "GameFontDisableSmall")
    c.area:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -8, 12)
    c:SetScript("OnEnter", function(self) UI():SetEdgeColor(self, 0.54, 0.45, 0.13, 1) end)
    c:SetScript("OnLeave", function(self) UI():SetEdgeColor(self, 0.18, 0.18, 0.2, 1) end)
    c:SetScript("OnClick", function(self)
        st.card = st.card ~= self.sec.id and self.sec.id or nil
        ChangelogUI:Render(true)
    end)
    return c
end

local function FillCard(c, sec, v, w, showVer)
    c.sec = sec
    c:SetWidth(w)
    PaintRaid(c.art, sec.art or (AREAS[sec.area] or AREAS.other)[5], w, 65)
    c.face:SetIcon(AreaAtlas(sec.area))
    if showVer then
        c.ver:Set(sec.version, "mute")
        c.ver:Show()
    else
        c.ver:Hide()
    end
    c.title:SetText(UI():SafeText(sec.title))
    c.pitch:SetText(UI():SafeText(v.lead))
    c.go:SetShown(sec.open ~= nil)
    c.area:SetText(AreaIcon(sec.area, 10, { 0.55, 0.55, 0.57 }) .. " " .. (AREAS[sec.area] or AREAS.other)[1])
    local on = st.card == sec.id
    UI():SetEdgeColor(c, on and 0.54 or 0.18, on and 0.45 or 0.18, on and 0.13 or 0.2, 1)
    c:Show()
end

---------------------------------------------------------------------------
-- The scroll content: headers, cards, rows, the "for others" row, search results, feedback cards
---------------------------------------------------------------------------

local function NewHeader(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(L.HEAD_H)
    h.icon = h:CreateTexture(nil, "ARTWORK")
    h.icon:SetSize(10, 10)
    h.icon:SetPoint("LEFT", 0, 0)
    h.fs = Text(h, "GameFontDisableSmall")
    h.right = Text(h, "GameFontDisableSmall")
    h.right:SetPoint("RIGHT", 0, 0)
    h.rule = Tex(h, "ARTWORK", 0.17, 0.17, 0.19, 1)
    h.rule:SetHeight(1)
    return h
end

-- kind "grey" (HIGHLIGHTS ——— 3 of 13) | "area" (gold, an icon, a fading rule)
local function FillHeader(h, text, right, kind, icon)
    h.fs:ClearAllPoints()
    if kind == "area" then
        AtlasTex(h.icon, icon, 1, 0.82, 0)
        h.icon:Show()
        h.fs:SetPoint("LEFT", h.icon, "RIGHT", 6, 0)
        h.fs:SetTextColor(1, 0.82, 0)
        h.rule:SetColorTexture(0.35, 0.29, 0.1, 1)
        if h.rule.SetGradient and CreateColor then
            h.rule:SetGradient("HORIZONTAL", CreateColor(0.35, 0.29, 0.1, 1), CreateColor(0.35, 0.29, 0.1, 0))
        end
    else
        h.icon:Hide()
        h.fs:SetPoint("LEFT", 0, 0)
        h.fs:SetTextColor(0.55, 0.55, 0.55)
        h.rule:SetColorTexture(0.17, 0.17, 0.19, 1)
    end
    h.fs:SetText(text)
    h.right:SetText(right or "")
    h.rule:ClearAllPoints()
    h.rule:SetPoint("LEFT", h.fs, "RIGHT", 8, 0)
    h.rule:SetPoint("RIGHT", h.right, "LEFT", (right and right ~= "") and -8 or 0, 0)
    h:Show()
end

local function NewNote(parent)   -- the dashed "for others" row, and "Still open" on the feedback view
    local n = CreateFrame("Button", nil, parent)
    n:SetHeight(32)
    n.bg = Tex(n, "BACKGROUND", 0.063, 0.063, 0.075, 0.6)
    n.bg:SetAllPoints()
    UI():AddEdges(n)
    UI():SetEdgeColor(n, 0.2, 0.2, 0.23, 1)
    n.icon = n:CreateTexture(nil, "ARTWORK")
    n.icon:SetSize(12, 12)
    n.icon:SetPoint("LEFT", 9, 0)
    n.fs = Text(n, "GameFontHighlightSmall")
    n.fs:SetPoint("LEFT", n.icon, "RIGHT", 8, 0)
    n.go = NewGoLink(n, "Show them")
    n.go:SetPoint("RIGHT", n, "RIGHT", -10, 0)
    n.go:SetScript("OnClick", function(self) local p = self:GetParent(); if p.onClick then p.onClick() end end)
    n:SetScript("OnClick", function(self) if self.onClick then self.onClick() end end)
    return n
end

local function FillNote(n, w, iconIndex, text, linkText, onClick)
    n:SetWidth(w)
    AtlasTex(n.icon, iconIndex, 0.55, 0.55, 0.57)
    n.fs:SetText(text)
    n.go:SetLabel(linkText)
    n.onClick = onClick
    n:Show()
end

-- a result group's head (a search): the release's painting as a strip
local function NewStrip(parent)
    local s = CreateFrame("Button", nil, parent)
    s:SetHeight(26)
    s.art = s:CreateTexture(nil, "BACKGROUND")
    s.art:SetAllPoints()
    s.shade = Tex(s, "BORDER", 0.04, 0.04, 0.047, 0.78)
    s.shade:SetAllPoints()
    UI():AddEdges(s)
    UI():SetEdgeColor(s, 0.17, 0.17, 0.2, 1)
    s.v = Text(s, "GameFontNormal")
    s.v:SetPoint("LEFT", 9, 0)
    s.t = Text(s, "GameFontHighlight")
    s.t:SetPoint("LEFT", s.v, "RIGHT", 7, 0)
    s.r = Text(s, "GameFontDisableSmall")
    s.r:SetPoint("RIGHT", -9, 0)
    s:SetScript("OnClick", function(self) ChangelogUI:Select(self.version) end)
    return s
end

-- a result block (a search): a section's title line and its matching lines
local function NewBlock(parent)
    local b = CreateFrame("Frame", nil, parent)
    b.bg = Tex(b, "BACKGROUND", 0.07, 0.07, 0.085, 0.86)
    b.bg:SetAllPoints()
    b.rule = Tex(b, "BORDER", 0.12, 0.12, 0.14, 1)
    b.rule:SetHeight(1)
    b.rule:SetPoint("BOTTOMLEFT")
    b.rule:SetPoint("BOTTOMRIGHT")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(11, 11)
    b.icon:SetPoint("TOPLEFT", 9, -8)
    b.title = Text(b, "GameFontHighlight")
    b.title:SetPoint("TOPLEFT", 25, -7)
    b.kind = UI():CreateTagPill(b, 13)
    b.tag = Text(b, "GameFontDisableSmall")
    b.go = NewGoLink(b)
    b.go:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -6)
    b.go:SetScript("OnClick", function(self) ChangelogUI:ShowMe(self:GetParent().sec) end)
    b.more = Text(b, "GameFontDisableSmall")
    b.lines = {}
    return b
end

-- a shipped item of mine (From your feedback): my words | the line that shipped it
local function NewFeedbackCard(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.bg = Tex(c, "BACKGROUND", 0.063, 0.063, 0.075, 0.92)
    c.bg:SetAllPoints()
    UI():AddEdges(c)
    UI():SetEdgeColor(c, 0.17, 0.17, 0.2, 1)
    c.div = Tex(c, "BORDER", 0.14, 0.14, 0.15, 1)
    c.div:SetWidth(1)
    c.kicon = c:CreateTexture(nil, "ARTWORK")
    c.kicon:SetSize(12, 12)
    c.kicon:SetPoint("TOPLEFT", 10, -10)
    c.kicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.head = Text(c, "GameFontDisableSmall")
    c.head:SetPoint("LEFT", c.kicon, "RIGHT", 6, 0)
    c.quote = Text(c, "GameFontHighlight")
    c.quote:SetWordWrap(true)
    c.quote:SetTextColor(0.86, 0.86, 0.88)
    c.quote:SetPoint("TOPLEFT", 10, -30)
    c.metoo = Text(c, "GameFontDisableSmall")
    c.kick = Text(c, "GameFontNormalSmall")
    c.kick:SetTextColor(0.37, 0.88, 0.48)
    c.sec = Text(c, "GameFontHighlight", 12)
    c.lineBg = Tex(c, "ARTWORK", 1, 0.82, 0, 0.09)
    c.lineBar = Tex(c, "ARTWORK", 1, 0.82, 0, 0.9, 1)
    c.lineBar:SetWidth(2)
    c.line = Text(c, "GameFontHighlight")
    c.line:SetWordWrap(true)
    c.go = UI():CreateSleekButton(c, "Show me", 70, 18, function(self) ChangelogUI:ShowMe(self:GetParent().secRef) end,
        "primary")
    c.notes = NewGoLink(c, "Read the notes")
    c.notes:SetScript("OnClick", function(self)
        local p = self:GetParent()
        st.open[p.secRef.id] = true
        ChangelogUI:Select(p.secRef.version)
    end)
    return c
end

---------------------------------------------------------------------------
-- Building the views
---------------------------------------------------------------------------

local pools          -- per kind: { list, used }

local function Take(kind, make)
    local p = pools[kind]
    p.used = p.used + 1
    local x = p.list[p.used]
    if not x then
        x = make(panel.child)
        p.list[p.used] = x
    end
    x:ClearAllPoints()
    return x
end

local function ResetPools()
    for _, p in pairs(pools) do
        for i = 1, #p.list do p.list[i]:Hide() end
        p.used = 0
    end
end

-- The sections a view lists for me, after the area chip: highlights, the rest, those for others.
local function Gather(entries)
    local out = { hi = {}, rest = {}, others = {}, otherTags = {}, counts = {}, total = 0, fixes = {} }
    for _, ne in ipairs(entries) do
        for _, sec in ipairs(ne.sections) do
            local v = View(sec)
            if not v.mine and ForMeOn() then
                out.others[#out.others + 1] = sec
                for _, t in ipairs(sec.aud or {}) do out.otherTags[t] = true end
            else
                out.counts[sec.area] = (out.counts[sec.area] or 0) + 1
                out.total = out.total + 1
                if not st.area or st.area == sec.area then
                    local item = { sec = sec, v = v }
                    if sec.isFix then
                        out.fixes[#out.fixes + 1] = item
                    elseif sec.hi then
                        out.hi[#out.hi + 1] = item
                    else
                        out.rest[#out.rest + 1] = item
                    end
                end
            end
        end
    end
    return out
end

local function TagList(set)
    local tags = {}
    for t in pairs(set) do tags[#tags + 1] = t end
    sort(tags, function(a, b)
        local ca, cb = AUD_LABEL[a] ~= nil, AUD_LABEL[b] ~= nil
        if ca ~= cb then return ca end
        return a < b
    end)
    return tags
end

local function PutRow(y, w, sec, v, opts)
    local r = Take("rows", NewRow)
    r.isCard = opts.isCard
    r:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
    return y - FillRow(r, sec, v, w, opts)
end

local function PutHeader(y, w, text, right, kind, icon)
    local h = Take("heads", NewHeader)
    h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
    h:SetWidth(w)
    FillHeader(h, text, right, kind, icon)
    return y - L.HEAD_H - 4
end

local function PutCards(y, w, items, showVer)
    local n = min(#items, 4)
    if n == 0 then return y end
    local cw = floor((w - (n - 1) * 7) / n)
    for i = 1, n do
        local c = Take("cards", NewCard)
        c:SetPoint("TOPLEFT", panel.child, "TOPLEFT", (i - 1) * (cw + 7), y)
        FillCard(c, items[i].sec, items[i].v, cw, showVer)
    end
    y = y - L.CARD_H - 8
    for i = 1, n do
        if st.card == items[i].sec.id then
            y = PutRow(y, w, items[i].sec, items[i].v, { open = true, version = showVer, isCard = true }) - 8
        end
    end
    return y
end

local function PutOthers(y, w, g)
    if #g.others == 0 then return y end
    local n = Take("notes", NewNote)
    n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 6)
    FillNote(n, w, UI().ICON.eye, ("|cffffffff%d section%s for others:|r for %s"):format(#g.others,
        #g.others == 1 and "" or "s", WhoText(TagList(g.otherTags))), "Show them", function()
        local s = Settings()
        if s then s.changelogForMe = false end
        if panel and panel.forMe then panel.forMe:SetChecked(false) end
        ChangelogUI:Render()
    end)
    return y - 32 - 12
end

local function ReleaseView(ne, w)
    local g = Gather({ ne })
    local y = -2
    if #g.hi > 0 then
        y = PutHeader(y, w, "HIGHLIGHTS", ("%d of %d"):format(min(#g.hi, 4), g.total))
        y = PutCards(y, w, g.hi, false)
        y = y - 4
    end
    for i = 5, #g.hi do g.rest[#g.rest + 1] = g.hi[i] end
    if #g.rest > 0 then
        y = PutHeader(y, w, #g.hi > 0 and "EVERYTHING ELSE" or "WHAT CHANGED", #g.rest .. " sections")
        for _, it in ipairs(g.rest) do
            y = PutRow(y, w, it.sec, it.v, { open = st.open[it.sec.id] == true })
        end
    end
    y = PutOthers(y, w, g)
    for _, it in ipairs(g.fixes) do
        y = PutRow(y, w, it.sec, it.v, { open = st.open[it.sec.id] == true })
    end
    local thanks = ThanksLine(ne.entry)
    if thanks then
        local h = Take("texts", function(p) return Text(p, "GameFontHighlightSmall") end)
        h:SetWordWrap(true)
        h:SetWidth(w)
        h:SetTextColor(0.85, 0.75, 0.45)
        h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 12)
        h:SetText(thanks)
        h:Show()
        y = y - 12 - WrapH(h, w, 12)
    end
    if #g.hi + #g.rest + #g.fixes == 0 and #g.others == 0 then
        local h = Take("texts", function(p) return Text(p, "GameFontDisable") end)
        h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 10)
        h:SetText("Nothing in this area.")
        h:Show()
        y = y - 30
    end
    return y, g
end

local function SinceView(list, w)
    local g = Gather(list)
    local y = -2
    if #g.hi > 0 then
        y = PutHeader(y, w, "HIGHLIGHTS", ("%d of %d"):format(min(#g.hi, 4), g.total))
        y = PutCards(y, w, g.hi, true)
        y = y - 4
    end
    for i = 5, #g.hi do g.rest[#g.rest + 1] = g.hi[i] end
    for _, it in ipairs(g.fixes) do g.rest[#g.rest + 1] = it end
    if #g.rest > 0 then
        y = PutHeader(y, w, "EVERYTHING ELSE, BY AREA", "click a section to read it")
        local byArea = {}
        for _, it in ipairs(g.rest) do
            byArea[it.sec.area] = byArea[it.sec.area] or {}
            tinsert(byArea[it.sec.area], it)
        end
        for _, area in ipairs(AREA_ORDER) do
            local items = byArea[area]
            if items then
                y = PutHeader(y - 2, w, strlower((AREAS[area] or AREAS.other)[1]):upper(), tostring(#items), "area",
                    AreaAtlas(area))
                for _, it in ipairs(items) do
                    y = PutRow(y, w, it.sec, it.v, { open = st.open[it.sec.id] == true, version = true })
                end
            end
        end
    end
    y = PutOthers(y, w, g)
    return y, g
end

-- Marks a word in a line gold.
local function Marker(q)
    local pat = q:gsub("%W", "%%%0")
    return function(text)
        local out, i, lower = {}, 1, strlower(text)
        while true do
            local a, b = strfind(lower, pat, i)
            if not a then break end
            out[#out + 1] = text:sub(i, a - 1)
            out[#out + 1] = "|cffffd100" .. text:sub(a, b) .. "|r"
            i = b + 1
        end
        out[#out + 1] = text:sub(i)
        return tconcat(out)
    end
end

-- Every line matching the search: { { ne, { { sec, lines, more } } }, ... }, the count, hidden lines, counts per area.
local function Search(q)
    local needle = strlower(q)
    local out, total, hidden, hiddenTags, areas, versions = {}, 0, 0, {}, {}, 0
    for _, ne in ipairs(Norm().list) do
        local secs = {}
        for _, sec in ipairs(ne.sections) do
            local hits = {}
            local secForMe = not ForMeOn() or IsForMe(sec.aud)
            local titleHit = strfind(strlower(sec.title), needle, 1, true) ~= nil
            for _, ln in ipairs(sec.lines) do
                if strfind(strlower(ln.text), needle, 1, true) then
                    if secForMe and (not ForMeOn() or IsForMe(ln.aud)) then
                        hits[#hits + 1] = ln
                    else
                        hidden = hidden + 1
                        for _, t in ipairs(ln.aud or sec.aud or {}) do hiddenTags[t] = true end
                    end
                end
            end
            if #hits > 0 or (titleHit and secForMe) then
                areas[sec.area] = (areas[sec.area] or 0) + #hits
                if not st.area or st.area == sec.area then
                    secs[#secs + 1] = { sec = sec, lines = hits }
                    total = total + #hits
                end
            end
        end
        if #secs > 0 then
            out[#out + 1] = { ne = ne, secs = secs }
            versions = versions + 1
        end
    end
    return out, total, hidden, hiddenTags, areas, versions
end

local function SearchView(w)
    local res, total, hidden, hiddenTags = Search(st.query)
    local mark = Marker(strlower(st.query))
    local y = -2
    for _, grp in ipairs(res) do
        local s = Take("strips", NewStrip)
        s:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        s:SetWidth(w)
        s.version = grp.ne.version
        local key = "other"
        for _, it in ipairs(grp.secs) do key = it.sec.art or (AREAS[it.sec.area] or AREAS.other)[5]; break end
        PaintRaid(s.art, key, w, 26)
        s.v:SetText(grp.ne.version)
        s.t:SetText(UI():SafeText(grp.ne.title or ""))
        local n = 0
        for _, it in ipairs(grp.secs) do n = n + #it.lines end
        s.r:SetText(ShortDate(grp.ne) .. " · " .. (n == 1 and "1 line" or (n .. " lines")))
        s:Show()
        y = y - 26
        for _, it in ipairs(grp.secs) do
            local b = Take("blocks", NewBlock)
            b:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
            b:SetWidth(w)
            b.sec = it.sec
            AtlasTex(b.icon, AreaAtlas(it.sec.area), 0.81, 0.81, 0.81)
            b.title:SetText(mark(UI():SafeText(it.sec.title)))
            local x = 25 + (tonumber(b.title:GetStringWidth()) or 0) + 8
            local kinfo = it.sec.kind and KIND[it.sec.kind]
            if kinfo then
                b.kind:Set(kinfo[1], kinfo[2])
                b.kind:ClearAllPoints()
                b.kind:SetPoint("LEFT", b, "TOPLEFT", x, -13)
                b.kind:Show()
                x = x + (b.kind:GetWidth() or 40) + 7
            else
                b.kind:Hide()
            end
            b.tag:SetText(AreaIcon(it.sec.area, 10, { 0.55, 0.55, 0.57 }) .. " " .. (AREAS[it.sec.area] or AREAS.other)[1])
            b.tag:ClearAllPoints()
            b.tag:SetPoint("LEFT", b, "TOPLEFT", x, -13)
            b.go:SetShown(it.sec.open ~= nil)
            local shown = {}
            for i = 1, min(4, #it.lines) do shown[i] = it.lines[i] end
            local by = LayLines(b, b.lines, shown, 14, -24, w - 28, mark)
            if #it.lines > 4 then
                b.more:SetText(("+ %d more lines in this section"):format(#it.lines - 4))
                b.more:ClearAllPoints()
                b.more:SetPoint("TOPLEFT", b, "TOPLEFT", 24, by)
                b.more:Show()
                by = by - 14
            else
                b.more:Hide()
            end
            b:SetHeight(-by + 6)
            b:Show()
            y = y + by - 6
        end
        y = y - 10
    end
    if hidden > 0 then
        local n = Take("notes", NewNote)
        n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        FillNote(n, w, UI().ICON.eye, ("|cffffffff%d more line%s|r for %s"):format(hidden, hidden == 1 and "" or "s",
            WhoText(TagList(hiddenTags))), "Show them", function()
            local s = Settings()
            if s then s.changelogForMe = false end
            if panel and panel.forMe then panel.forMe:SetChecked(false) end
            ChangelogUI:Render()
        end)
        y = y - 44
    end
    if #res == 0 then
        local h = Take("texts", function(p) return Text(p, "GameFontDisable") end)
        h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 10)
        h:SetText("Nothing in any version says that.")
        h:Show()
        y = y - 30
    end
    return y, total
end

-- The lines of the notes that credit me: { { sec, ln }, ... } newest first.
local function MyShipped()
    local out = {}
    local F = ns.Feedback
    if not (F and F.LineIsMine) then return out end
    for _, ne in ipairs(Norm().list) do
        if Compare(ne.version, ns.version) <= 0 then
            for _, sec in ipairs(ne.sections) do
                for _, ln in ipairs(sec.lines) do
                    if F:LineIsMine(ln.raw) then out[#out + 1] = { sec = sec, ln = ln } end
                end
            end
        end
    end
    return out
end

local function MyOpen()
    local F = ns.Feedback
    if not (F and F.List) then return {} end
    local ok, list = pcall(F.List, F, { mine = true, open = true }, "new")
    return ok and list or {}
end
ChangelogUI.MyShipped = MyShipped

local function FeedbackView(w)
    local y = -2
    local F = ns.Feedback
    for _, it in ipairs(MyShipped()) do
        local c = Take("fcards", NewFeedbackCard)
        c:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        c:SetWidth(w)
        c.secRef = it.sec
        local raw = it.ln.raw
        local item = type(raw) == "table" and type(raw.fb) == "table" and F.GetByNumber and F:GetByNumber(raw.fb[1])
        local kind = (item and item.kind) or (type(raw) == "table" and raw.k) or "idea"
        local info = F.KIND_INFO and F.KIND_INFO[kind] or F.KIND_INFO.idea
        c.kicon:SetTexture(info.icon)
        local head = (item and item.no) and ("|cffffffff#" .. item.no .. "|r · ") or ""
        head = head .. info.short
        if item and item.at then head = head .. " · " .. date("%d %b", item.at) end
        c.head:SetText(head)
        local leftW = floor(w * 0.38)
        c.quote:SetWidth(leftW - 20)
        c.quote:SetText(item and ("“" .. UI():SafeText(item.text or "") .. "”") or "|cff8c8c91Your words aren't here yet.|r")
        local qh = min(WrapH(c.quote, leftW - 20, 13), 13 * 5)
        local votes = item and tonumber(item.voteCount) or (type(raw) == "table" and tonumber(raw.mt)) or 0
        c.metoo:SetText(votes > 0 and (votes == 1 and "1 more said me too" or (votes .. " more said me too"))
            or "Only you asked")
        c.metoo:ClearAllPoints()
        c.metoo:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -30 - qh - 6)
        c.div:ClearAllPoints()
        c.div:SetPoint("TOPLEFT", c, "TOPLEFT", leftW, -1)
        c.div:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", leftW, 1)
        local rx, rw = leftW + 12, w - leftW - 24
        c.kick:ClearAllPoints()
        c.kick:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -10)
        c.kick:SetText("|TInterface\\RaidFrame\\ReadyCheck-Ready:11:11|t SHIPPED IN " .. it.sec.version)
        c.sec:ClearAllPoints()
        c.sec:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -26)
        c.sec:SetText(AreaIcon(it.sec.area, 11, { 0.81, 0.81, 0.81 }) .. " " .. UI():SafeText(it.sec.title))
        c.line:SetWidth(rw - 14)
        c.line:SetText(UI():SafeText(it.ln.text))
        local lh = WrapH(c.line, rw - 14, 13)
        c.line:ClearAllPoints()
        c.line:SetPoint("TOPLEFT", c, "TOPLEFT", rx + 8, -48)
        c.lineBg:ClearAllPoints()
        c.lineBg:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -44)
        c.lineBg:SetSize(rw, lh + 8)
        c.lineBar:ClearAllPoints()
        c.lineBar:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -44)
        c.lineBar:SetHeight(lh + 8)
        local by = -44 - lh - 8 - 8
        c.go:ClearAllPoints()
        c.go:SetPoint("TOPLEFT", c, "TOPLEFT", rx, by)
        c.go:SetShown(it.sec.open ~= nil)
        c.notes:ClearAllPoints()
        if it.sec.open then
            c.notes:SetPoint("LEFT", c.go, "RIGHT", 10, 0)
        else
            c.notes:SetPoint("TOPLEFT", c, "TOPLEFT", rx, by - 2)
        end
        local h = max(-by + 18 + 10, 30 + qh + 6 + 14 + 10)
        c:SetHeight(h)
        c:Show()
        y = y - h - 7
    end
    local open = MyOpen()
    if #open > 0 then
        local it = open[1]
        local n = Take("notes", NewNote)
        n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        local words = UI():SafeText(tostring(it.text or ""))
        if #words > 60 then words = words:sub(1, 57) .. "..." end
        FillNote(n, w, UI().ICON.notes, ("|cffffffffStill open:|r %s“%s”%s"):format(it.no and ("#" .. it.no .. " · ") or "",
            words, #open > 1 and (" and " .. (#open - 1) .. " more") or ""), "Feedback", function()
            if ns.FeedbackUI and ns.FeedbackUI.Open then ns.FeedbackUI:Open("mine") else ns.MainFrame:Open("feedback") end
        end)
        y = y - 32 - 8
    end
    return y
end

---------------------------------------------------------------------------
-- The banner and the filter row
---------------------------------------------------------------------------

local function SetBanner(kicker, title, sub, artFn, icon)
    local b = panel.banner
    b.kicker:SetText(kicker)
    b.title:SetText(UI():SafeText(title))
    b.sub:SetText(sub)
    artFn(b.art)
    b.face:SetIcon(icon)
    b:Show()
end

local function NewChip(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(L.TB_H - 4)
    UI():AddPillShape(c, L.TB_H - 4)
    c.fs = Text(c, "GameFontHighlightSmall")
    c.fs:SetPoint("LEFT", 9, 0)
    c.n = Text(c, "GameFontDisableSmall")
    c.n:SetPoint("LEFT", c.fs, "RIGHT", 4, 0)
    c:SetScript("OnClick", function(self)
        st.area = self.area
        st.card = nil
        ChangelogUI:Render()
    end)
    c:SetScript("OnEnter", function(self) if not self.on then self:SetPillColors({ 0.13, 0.13, 0.15, 1 }, { 0.35, 0.35, 0.4, 1 }) end end)
    c:SetScript("OnLeave", function(self) self:Paint() end)
    function c:Paint()
        if self.on then
            self:SetPillColors({ 0.18, 0.15, 0.09, 1 }, { 0.54, 0.45, 0.13, 1 })
            self.fs:SetTextColor(0.95, 0.85, 0.54)
        else
            self:SetPillColors({ 0.1, 0.1, 0.115, 1 }, { 0.23, 0.23, 0.26, 1 })
            self.fs:SetTextColor(0.86, 0.86, 0.86)
        end
    end
    return c
end

local function FillChips(counts, total)
    local list = { { nil, "All", total } }
    for _, a in ipairs(AREA_ORDER) do
        if (counts[a] or 0) > 0 then list[#list + 1] = { a, AREAS[a][1], counts[a] } end
    end
    if st.area and not counts[st.area] then st.area = nil end
    local x = 0
    local maxX = (panel.toolbar:GetWidth() or 560) - 150
    for i, d in ipairs(list) do
        local c = Pool(panel.chips, i, function() return NewChip(panel.toolbar) end)
        c.area = d[1]
        c.on = st.area == d[1]
        c.fs:SetText(d[2])
        c.n:SetText(tostring(d[3]))
        local w = floor((c.fs:GetStringWidth() or 30) + 4 + (c.n:GetStringWidth() or 10) + 18)
        c:SetWidth(w)
        c:ClearAllPoints()
        c:SetPoint("LEFT", panel.toolbar, "LEFT", x, 0)
        c:Paint()
        c:SetShown(x + w <= maxX or i == 1)
        x = x + w + 5
    end
    for i = #list + 1, #panel.chips do panel.chips[i]:Hide() end
end

---------------------------------------------------------------------------
-- The version list (left)
---------------------------------------------------------------------------

local function SeriesOf(v)
    local a, b = tostring(v):match("^(%d+)%.(%d+)")
    return tonumber(a) or 0, tonumber(b) or 0
end

-- The list's groups: the newest series, the other 1.x+ series together, then everything before 1.0.
local function Groups()
    local list = Norm().list
    if #list == 0 then return {} end
    local ma, mi = SeriesOf(list[1].version)
    local first = { key = ma .. "." .. mi, label = ma .. "." .. mi, items = {} }
    local older = { key = "older", items = {}, series = {} }
    local earlier = { key = "earlier", items = {} }
    for _, ne in ipairs(list) do
        local a, b = SeriesOf(ne.version)
        if a == ma and b == mi then
            first.items[#first.items + 1] = ne
        elseif a >= 1 then
            older.items[#older.items + 1] = ne
            local s = a .. "." .. b
            if older.series[#older.series] ~= s then older.series[#older.series + 1] = s end
        else
            earlier.items[#earlier.items + 1] = ne
        end
    end
    older.label = tconcat(older.series, " · ")
    if #earlier.items > 0 then
        local lo, hi = earlier.items[#earlier.items].version, earlier.items[1].version
        earlier.label = ("EARLIER · %s – %s"):format(lo:match("^%d+%.%d+") or lo, hi:match("^%d+%.%d+") or hi)
    end
    local out = { first }
    if #older.items > 0 then out[#out + 1] = older end
    if #earlier.items > 0 then out[#out + 1] = earlier end
    return out
end

local function HasMine(ne)
    local F = ns.Feedback
    if not (F and F.LineIsMine) then return false end
    for _, sec in ipairs(ne.sections) do
        for _, ln in ipairs(sec.lines) do
            if type(ln.raw) == "table" and F:LineIsMine(ln.raw) then return true end
        end
    end
    return false
end

local function NewPin(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(L.PIN_H)
    p.sel = Tex(p, "BACKGROUND", 1, 0.82, 0, 0.12)
    p.sel:SetAllPoints()
    p.bar = Tex(p, "ARTWORK", 1, 0.82, 0, 1)
    p.bar:SetWidth(3)
    p.bar:SetPoint("TOPLEFT", 0, -3)
    p.bar:SetPoint("BOTTOMLEFT", 0, 3)
    p.hl = Tex(p, "HIGHLIGHT", 1, 1, 1, 0.05)
    p.hl:SetAllPoints()
    p.tile = CreateFrame("Frame", nil, p)
    p.tile:SetSize(25, 25)
    p.tile:SetPoint("LEFT", 8, 0)
    p.tile.bg = Tex(p.tile, "BACKGROUND", 0.094, 0.094, 0.11, 1)
    p.tile.bg:SetAllPoints()
    UI():AddEdges(p.tile)
    p.icon = p.tile:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(14, 14)
    p.icon:SetPoint("CENTER")
    p.t = Text(p, "GameFontHighlight")
    p.t:SetPoint("TOPLEFT", p.tile, "TOPRIGHT", 8, 0)
    p.s = Text(p, "GameFontDisableSmall")
    p.s:SetPoint("BOTTOMLEFT", p.tile, "BOTTOMRIGHT", 8, 0)
    p.badge = UI():CreateCountBadge(p, 15)
    p.badge:SetPoint("RIGHT", -8, 0)
    p:SetScript("OnClick", function(self) ChangelogUI:Select(self.view) end)
    return p
end

local function NewVRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r.sel = Tex(r, "BACKGROUND", 1, 0.82, 0, 0.12)
    r.sel:SetAllPoints()
    r.bar = Tex(r, "ARTWORK", 1, 0.82, 0, 1)
    r.bar:SetWidth(3)
    r.bar:SetPoint("TOPLEFT", 0, -3)
    r.bar:SetPoint("BOTTOMLEFT", 0, 3)
    r.hl = Tex(r, "HIGHLIGHT", 1, 1, 1, 0.05)
    r.hl:SetAllPoints()
    r.version = Text(r, "GameFontNormal")
    r.version:SetPoint("TOPLEFT", 10, -L.VROW_PAD)
    r.mine = r:CreateTexture(nil, "ARTWORK")
    r.mine:SetSize(10, 10)
    r.mine:SetPoint("LEFT", r.version, "RIGHT", 5, 0)
    r.mine:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.badge = Text(r, "GameFontHighlightSmall")
    r.badge:SetJustifyH("RIGHT")
    r.badge:SetPoint("TOPRIGHT", -8, -L.VROW_PAD - 1)
    r.hits = UI():CreateCountBadge(r, 14)
    r.hits:SetPoint("TOPRIGHT", -8, -L.VROW_PAD)
    r.title = Text(r, "GameFontDisableSmall")
    r.title:SetWordWrap(true)
    r.title:SetJustifyV("TOP")
    r.title:SetPoint("TOPLEFT", 10, -L.VROW_PAD - 16)
    if r.title.SetMaxLines then r.title:SetMaxLines(2) end
    r:SetScript("OnClick", function(self) ChangelogUI:Select(self.view) end)
    return r
end

local function NewVGroup(parent)
    local g = CreateFrame("Button", nil, parent)
    g:SetHeight(L.GROUP_H)
    g.rule = Tex(g, "ARTWORK", 0.14, 0.14, 0.15, 1)
    g.rule:SetHeight(1)
    g.rule:SetPoint("TOPLEFT")
    g.rule:SetPoint("TOPRIGHT")
    g.fs = Text(g, "GameFontDisableSmall")
    g.fs:SetPoint("LEFT", 9, 0)
    g.r = Text(g, "GameFontDisableSmall")
    g.chev = g:CreateTexture(nil, "ARTWORK")
    g.chev:SetSize(8, 8)
    g.chev:SetPoint("RIGHT", -8, 0)
    g.r:SetPoint("RIGHT", g.chev, "LEFT", -4, 0)
    g.hl = Tex(g, "HIGHLIGHT", 1, 1, 1, 0.04)
    g.hl:SetAllPoints()
    g:SetScript("OnClick", function(self)
        st.collapsed[self.key] = not self.collapsedNow
        ChangelogUI:RenderList()
    end)
    return g
end

local vpools

local function VTake(kind, make)
    local p = vpools[kind]
    p.used = p.used + 1
    local x = p.list[p.used]
    if not x then
        x = make(panel.vchild)
        p.list[p.used] = x
    end
    x:ClearAllPoints()
    return x
end

function ChangelogUI:RenderList()
    if not panel then return end
    for _, p in pairs(vpools) do
        for i = 1, #p.list do p.list[i]:Hide() end
        p.used = 0
    end
    local w = max(120, floor((panel.vscroll:GetWidth() or (L.LIST_W - 22))))
    if w < 50 then w = L.LIST_W - 22 end
    panel.vchild:SetWidth(w)
    local y = 0
    local searching = st.query ~= ""
    local hitsBy = {}
    if searching then
        local res, total, _, _, _, versions = Search(st.query)
        for _, grp in ipairs(res) do
            local n = 0
            for _, it in ipairs(grp.secs) do n = n + #it.lines end
            hitsBy[grp.ne.version] = max(1, n)
        end
        panel.searchCount:SetText(("%d line%s in %d version%s"):format(total, total == 1 and "" or "s", versions,
            versions == 1 and "" or "s"))
        panel.searchCount:Show()
        y = -18
    else
        panel.searchCount:Hide()
        local unread = Unread()
        if #unread >= 2 then
            local p = VTake("pins", NewPin)
            p:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
            p:SetWidth(w)
            p.view = "since"
            local on = st.view == "since"
            p.sel:SetShown(on)
            p.bar:SetShown(on)
            AtlasTex(p.icon, UI().ICON.notes, 1, 0.82, 0)
            UI():SetEdgeColor(p.tile, on and 0.54 or 0.23, on and 0.45 or 0.23, on and 0.13 or 0.26, 1)
            p.t:SetText("Since your last visit")
            p.s:SetText(("%s to %s"):format(unread[#unread].version, unread[1].version))
            p.badge:SetKind("alert")
            p.badge:SetCount(#unread)
            p:Show()
            y = y - L.PIN_H - 2
        end
        if #MyShipped() > 0 then
            local p = VTake("pins", NewPin)
            p:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
            p:SetWidth(w)
            p.view = "feedback"
            local on = st.view == "feedback"
            p.sel:SetShown(on)
            p.bar:SetShown(on)
            local F = ns.Feedback
            p.icon:SetTexture(F.KIND_INFO.idea.icon)
            p.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            p.icon:SetVertexColor(1, 1, 1)
            UI():SetEdgeColor(p.tile, on and 0.54 or 0.23, on and 0.45 or 0.23, on and 0.13 or 0.26, 1)
            p.t:SetText("From your feedback")
            local shipped, open = #MyShipped(), #MyOpen()
            p.s:SetText(shipped .. " shipped" .. (open > 0 and (" · " .. open .. " still open") or ""))
            p.badge:SetKind("muted")
            p.badge:SetCount(shipped)
            p:Show()
            y = y - L.PIN_H - 2
        end
    end
    for _, grp in ipairs(Groups()) do
        local hits, n = 0, #grp.items
        local holdsView = false
        for _, ne in ipairs(grp.items) do
            if hitsBy[ne.version] then hits = hits + 1 end
            if ne.version == st.view then holdsView = true end
        end
        local collapsed = st.collapsed[grp.key]
        if collapsed == nil then collapsed = grp.key == "older" or grp.key == "earlier" end
        if holdsView and st.collapsed[grp.key] == nil then collapsed = false end
        if searching then collapsed = hits == 0 end
        local g = VTake("groups", NewVGroup)
        g:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y - 3)
        g:SetWidth(w)
        g.key = grp.key
        g.collapsedNow = collapsed
        g.fs:SetText(grp.label)
        if searching and grp.key ~= Groups()[1].key then
            g.r:SetText(("%d of %d match"):format(hits, n))
        else
            g.r:SetText(n == 1 and "1 version" or (n .. " versions"))
        end
        UI():SetChevron(g.chev, collapsed)
        if not collapsed then g.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron))) end
        g.chev:SetVertexColor(0.55, 0.55, 0.57)
        g:Show()
        y = y - L.GROUP_H - 5
        if not collapsed then
            for _, ne in ipairs(grp.items) do
                local hide = searching and grp.key ~= Groups()[1].key and not hitsBy[ne.version]
                if not hide then
                    local r = VTake("rows", NewVRow)
                    r:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
                    r:SetWidth(w)
                    r.view = ne.version
                    local on = st.view == ne.version and not searching
                    r.sel:SetShown(on)
                    r.bar:SetShown(on)
                    r.version:SetText(ne.version)
                    local mine = not searching and HasMine(ne)
                    if mine then r.mine:SetTexture(ns.Feedback.KIND_INFO.idea.icon) end
                    r.mine:SetShown(mine)
                    if searching then
                        r.badge:Hide()
                        r.hits:SetCount(hitsBy[ne.version] or 0)
                        r:SetAlpha(hitsBy[ne.version] and 1 or 0.4)
                    else
                        r.hits:SetCount(0)
                        local badge, color = Badge(ne)
                        r.badge:SetText(badge and ("|cff" .. color .. badge .. "|r") or ("|cff808080" .. ShortDate(ne) .. "|r"))
                        r.badge:Show()
                        r:SetAlpha(1)
                    end
                    r.title:SetWidth(w - 18)
                    r.title:SetText(UI():SafeText(ne.title or ""))
                    local th = min(WrapH(r.title, w - 18, 11), 22)
                    local h = L.VROW_PAD + 16 + th + L.VROW_PAD + 2
                    r:SetHeight(h)
                    r:Show()
                    y = y - h
                end
            end
        end
    end
    panel.vchild:SetHeight(max(10, -y + 6))
end

---------------------------------------------------------------------------
-- Rendering the right side
---------------------------------------------------------------------------

local function Layout(searching)
    local b, tb, sf = panel.banner, panel.toolbar, panel.scroll
    local top = -L.PAD
    tb:ClearAllPoints()
    sf:ClearAllPoints()
    if searching then
        b:Hide()
        panel.shead:Show()
        tb:SetPoint("TOPLEFT", panel.right, "TOPLEFT", 0, top - 26)
    else
        panel.shead:Hide()
        tb:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -L.GAP)
    end
    tb:SetPoint("RIGHT", panel.right, "RIGHT", 0, 0)
    sf:SetPoint("TOPLEFT", tb, "BOTTOMLEFT", 0, -L.GAP)
    sf:SetPoint("BOTTOMRIGHT", panel.right, "BOTTOMRIGHT", -12, L.PAD)
end

function ChangelogUI:Render(keepScroll)
    if not panel then return end
    roles = nil
    local scrollY = keepScroll and panel.scroll:GetVerticalScroll() or 0
    ResetPools()
    local w = floor((panel.scroll:GetWidth() or 0))
    if w < 100 then w = floor((panel.right:GetWidth() or 0) - 12) end
    if w < 100 then w = 556 end
    panel.child:SetWidth(w)
    local searching = st.query ~= ""
    Layout(searching)
    local y, g = -2, nil
    if searching then
        local _, total, _, _, areas, versions = Search(st.query)
        panel.shead:SetText(("|cffffffff%d line%s match|r |cffffd100%s|r   |cff9e9e9ein %d version%s, newest first|r")
            :format(total, total == 1 and "" or "s", UI():SafeText(st.query), versions, versions == 1 and "" or "s"))
        local all = 0
        for _, n in pairs(areas) do all = all + n end
        FillChips(areas, all)
        y = SearchView(w)
    elseif st.view == "feedback" then
        local shipped = MyShipped()
        local me = Util().ShortName and Util().ShortName(Util().PlayerKey() or "") or ""
        SetBanner("FROM YOUR FEEDBACK", (#shipped == 1 and "1 thing you asked for made it in")
            or (#shipped .. " things you asked for made it in"),
            ("Thank you, %s. Each one says where it shipped."):format(me),
            function(t) PaintRaid(t, "mag", 560, L.BAN_H) end, UI().ICON.trophy)
        FillChips({}, #shipped)
        y = FeedbackView(w)
    elseif st.view == "since" then
        local list = {}
        local unread = Unread()
        for _, e in ipairs(unread) do list[#list + 1] = Norm().by[e.version] end
        y, g = SinceView(list, w)
        local vers = {}
        for i = #unread, 1, -1 do vers[#vers + 1] = unread[i].version end
        local vtext = #vers > 1 and (tconcat(vers, ", ", 1, #vers - 1) .. " and " .. vers[#vers]) or (vers[1] or "")
        local dates = ""
        if #unread > 0 then
            local d1, d2 = ShortDate(unread[#unread]), ShortDate(unread[1])
            dates = " · " .. (d1 == d2 and d1 or (d1 .. " to " .. d2))
        end
        SetBanner("WHILE YOU WERE AWAY", ("%d new versions since you last looked"):format(#unread),
            ("%s%s · %d changes for you"):format(vtext, dates, g.total),
            function(t) PaintOutland(t, 560, L.BAN_H) end, UI().ICON.notes)
        FillChips(g.counts, g.total)
    else
        local ne = Norm().by[st.view or ""]
        if ne then
            y, g = ReleaseView(ne, w)
            local badge = Badge(ne)
            local kicker = ne.version .. (badge and (" · " .. badge:upper()) or "") .. " · " .. strlower(ne.date or ""):upper()
            local sub = ("%d sections for you"):format(g.total)
            if #g.others > 0 then sub = sub .. (" · %d more for %s"):format(#g.others, WhoText(TagList(g.otherTags))) end
            if Compare(ne.version, ns.version) > 0 then sub = sub .. "   |cff808080(you have " .. tostring(ns.version) .. ")|r" end
            local art, icon = "other", UI().ICON.notes
            for _, s in ipairs(ne.sections) do
                if s.hi then art = s.art or (AREAS[s.area] or AREAS.other)[5]; icon = AreaAtlas(s.area); break end
            end
            SetBanner(kicker, ne.title or "", sub, function(t) PaintRaid(t, art, 560, L.BAN_H) end, icon)
            FillChips(g.counts, g.total)
        end
    end
    local hiddenN = g and #g.others or 0
    panel.hidden:SetText(ForMeOn() and hiddenN > 0 and (hiddenN .. " hidden") or "")
    panel.child:SetHeight(max(10, -y + 8))
    panel.scroll:SetVerticalScroll(min(scrollY, max(0, -y + 8 - (panel.scroll:GetHeight() or 0))))
end

function ChangelogUI:Select(view)
    st.view = view
    st.card = nil
    st.area = nil
    if st.query ~= "" then
        st.query = ""
        if panel and panel.search then panel.search:SetText("") end
    end
    if not panel then return end
    self:RenderList()
    self:Render()
end

local function DefaultView()
    if #Unread() >= 2 then return "since" end
    local e = LatestReleased() or Entries()[1]
    return e and e.version or nil
end

function ChangelogUI:Refresh()
    if not panel then return end
    local valid = st.view == "since" and #Unread() >= 2 or st.view == "feedback" and #MyShipped() > 0
        or (st.view and Norm().by[st.view])
    if not valid then st.view = DefaultView() end
    self:RenderList()
    self:Render()
end

function ChangelogUI:SetSearch(text)
    st.query = ns.Util.Trim and (ns.Util.Trim(text or "") or "") or (text or "")
    if #st.query < 2 then st.query = "" end
    st.area = nil
    self:RenderList()
    self:Render()
end

function ChangelogUI:GetState() return st end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

function ChangelogUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    pools = { rows = { list = {}, used = 0 }, cards = { list = {}, used = 0 }, heads = { list = {}, used = 0 },
              notes = { list = {}, used = 0 }, strips = { list = {}, used = 0 }, blocks = { list = {}, used = 0 },
              fcards = { list = {}, used = 0 }, texts = { list = {}, used = 0 } }
    vpools = { pins = { list = {}, used = 0 }, groups = { list = {}, used = 0 }, rows = { list = {}, used = 0 } }

    -- left: search, pinned views, the releases
    local left = UI():CreatePanel(p)
    left:SetPoint("TOPLEFT", p, "TOPLEFT", L.PAD, -L.PAD)
    left:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", L.PAD, L.PAD)
    left:SetWidth(L.LIST_W)
    p.list = left
    p.search = UI():CreateSearchBox(left, L.LIST_W - 16, function(text) ChangelogUI:SetSearch(text) end,
        "Search every version")
    p.search:SetPoint("TOPLEFT", left, "TOPLEFT", 8, -8)
    p.searchCount = Text(left, "GameFontDisableSmall")
    p.searchCount:SetPoint("TOPLEFT", p.search, "BOTTOMLEFT", 2, -6)
    p.vscroll = UI():CreateScrollFrame(left, "DisasterZoneChangelogList")
    p.vscroll:SetPoint("TOPLEFT", p.search, "BOTTOMLEFT", -4, -6)
    p.vscroll:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -14, 6)
    p.vchild = CreateFrame("Frame", nil, p.vscroll)
    p.vchild:SetSize(L.LIST_W - 22, 10)
    p.vscroll:SetScrollChild(p.vchild)

    -- right: the banner, the filter row, what scrolls
    local right = CreateFrame("Frame", nil, p)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", L.GAP, 0)
    right:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -L.PAD, 0)
    p.right = right
    local b = CreateFrame("Frame", nil, right)
    b:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
    b:SetPoint("RIGHT", right, "RIGHT", 0, 0)
    b:SetHeight(L.BAN_H)
    b.art = b:CreateTexture(nil, "BACKGROUND")
    b.art:SetAllPoints()
    Shade(b)
    UI():AddEdges(b)
    UI():SetEdgeColor(b, 0.17, 0.17, 0.2, 1)
    b.face = Face(b, 46)
    b.face:SetPoint("RIGHT", b, "RIGHT", -14, 0)
    b.kicker = Text(b, "GameFontNormalSmall")
    b.kicker:SetPoint("TOPLEFT", b, "TOPLEFT", 13, -15)
    b.title = Text(b, "GameFontHighlightLarge", 16)
    b.title:SetPoint("TOPLEFT", b.kicker, "BOTTOMLEFT", 0, -4)
    b.title:SetPoint("RIGHT", b.face, "LEFT", -10, 0)
    b.sub = Text(b, "GameFontHighlightSmall")
    b.sub:SetTextColor(0.78, 0.78, 0.8)
    b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -4)
    b.sub:SetPoint("RIGHT", b.face, "LEFT", -10, 0)
    p.banner = b
    p.shead = Text(right, "GameFontHighlightLarge", 14)
    p.shead:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -L.PAD - 2)
    local tb = CreateFrame("Frame", nil, right)
    tb:SetHeight(L.TB_H)
    p.toolbar = tb
    p.chips = {}
    p.forMe = UI():CreateSwitch(tb, ForMeOn, function(on)
        local s = Settings()
        if s then s.changelogForMe = on and true or false end
        ChangelogUI:RenderList()
        ChangelogUI:Render()
    end)
    p.forMe:SetPoint("RIGHT", tb, "RIGHT", 0, 0)
    p.forMeLabel = Text(tb, "GameFontHighlightSmall")
    p.forMeLabel:SetText("Just for me")
    p.forMeLabel:SetPoint("RIGHT", p.forMe, "LEFT", -7, 0)
    p.hidden = Text(tb, "GameFontDisableSmall")
    p.hidden:SetPoint("RIGHT", p.forMeLabel, "LEFT", -7, 0)
    p.forMe:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Just for me", 1, 0.82, 0)
        GameTooltip:AddLine("Folds away what is only for the loot council, officers, raid leaders or other classes.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.forMe:HookScript("OnLeave", function() GameTooltip:Hide() end)
    p.scroll = UI():CreateScrollFrame(right, "DisasterZoneChangelogScroll")
    p.child = CreateFrame("Frame", nil, p.scroll)
    p.child:SetSize(556, 10)
    p.scroll:SetScrollChild(p.child)
    Layout(false)
    p.scroll:HookScript("OnSizeChanged", function() ChangelogUI:Render(true) end)

    function p:OnPanelShown()
        if seenBefore == nil then seenBefore = SeenVersion() or false end
        ChangelogUI:MarkRead()
        p.forMe:SetChecked(ForMeOn())
        ChangelogUI:Refresh()
    end
    return p
end

function ChangelogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("changelog", "Changelog", 3.9, function(parent) return ChangelogUI:CreatePanel(parent) end)
    end
    ns:RegisterSlash("changelog", function() ChangelogUI:Open() end, "open the Changelog: what's new in each version")
    ns:On("FEEDBACK_UPDATED", function() if panel and panel:IsVisible() then ChangelogUI:Refresh() end end)
end

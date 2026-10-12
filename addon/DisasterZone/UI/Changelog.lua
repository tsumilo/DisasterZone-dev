if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Changelog.lua", ...) then return end -- DisasterZone: UI/Changelog.lua
-- The Changelog tab (everyone), in three layers (2026-10-11, dev/art/casc/changelog_mockup): a release's highlights as
-- cards, its other sections folded to one line each (open one for its lines), and the lines themselves.
-- A list + detail page (UI:CreateLayout "listdetail"):
--   Toolbar: the areas as tabs with their counts (the ones that don't fit in its ··· menu), "Just for me" as its filter.
--   List: a search over every release, two pinned views (Since your last visit when two or more releases are unread,
--   From your feedback when something I asked for shipped) and the releases grouped by series (older ones fold).
--   Detail: the view's banner (the layout's tool banner), then what scrolls: caps section headers, highlight cards,
--   section rows with the shared row looks, inset notes, the shared empty state.
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
local S = ns.Style

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tinsert, tconcat, sort = table.insert, table.concat, table.sort
local strlower, strfind, strmatch, strgsub = string.lower, string.find, string.match, string.gsub

local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local OUTLAND = "Interface\\Glues\\LoadingScreens\\LoadScreenOutland"

-- the page's own sizes (the rest are ns.Style's and the list + detail layout's)
local L = { LIST_W = 230, CARD_H = 150, ART_H = 65, LINE_GAP = 3, GROUP_H = 22, VROW_PAD = 5, PIN_H = 40 }

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

-- "In testing" | "Your version" | "New" | nil, with its colour (a ns.Style token).
local function Badge(e)
    local c = Compare(e.version, ns.version)
    if c > 0 then return "In testing", "WARN" end
    if c == 0 then return IsNew(e) and "New · your version" or "Your version", "OK" end
    if IsNew(e) then return "New", "OK" end
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
ChangelogUI.ResetIndex = function() index = nil end
ChangelogUI.ResetSession = function() seenBefore = nil end     -- (tests, renders: as if the tab wasn't opened yet)

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

-- Is open a place Route knows (a page, a share-link page, a settings section)? For the data's tests.
function ChangelogUI.RouteKnown(open)
    if type(open) ~= "string" then return false end
    local page, sub = strmatch(open, "^(%a+)/(%a+)$")
    if page then return page == "settings" and sub ~= nil end
    if ns.Share and ns.Share.PAGES and ns.Share.PAGES[open] then return true end
    return ns.MainFrame ~= nil and ns.MainFrame:GetPageLabel(open) ~= nil
end

local function HideBackBar()
    if backbar then backbar:Hide() end
end

-- The way back after Show me: a card along the foot of the main window with a back link to the notes, the section's
-- name and an X. It goes when another page is picked.
local function ShowBackBar(sec, view)
    local host = ns.MainFrame and ns.MainFrame:GetFrame()
    if not host then return end
    if not backbar then
        local b = UI():CreateCard(host, { tone = "card", height = S.ROW.list + 4 })
        b:SetFrameStrata("DIALOG")
        b:EnableMouse(true)
        UI():SetEdgeColor(b, S:Color("GOLD_DEEP"))
        b.back = UI():CreateBackLink(b, "What's new", function()
            HideBackBar()
            ChangelogUI:Open(b.view)
        end)
        b.back:SetPoint("LEFT", b, "LEFT", S.PAD, 0)
        b.text = UI():Text(b, "body", "TEXT")
        b.text:SetPoint("LEFT", b.back, "RIGHT", S.GAP, 0)
        b.close = UI():CreateCloseButton(b, 16, HideBackBar)
        b.close:SetPoint("RIGHT", b, "RIGHT", -6, 0)
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
    backbar.text:SetText(UI():SafeText(sec.title))
    backbar:SetWidth(floor(S.PAD + backbar.back:GetWidth() + S.GAP + UI():TextWidth(backbar.text) + S.GAP + 22 + 0.5))
    backbar:ClearAllPoints()
    backbar:SetPoint("BOTTOM", host, "BOTTOM", 0, S.PAD)
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
        title = "What's new", quiet = true,
        host = function() return ns.MainFrame:GetFrame() end,
        alive = function() return ns.MainFrame:GetSelectedTab() ~= nil end,
        chapters = { { key = "show", title = "New in " .. sec.version, steps = { {
            title = sec.title, text = text, side = "left",
            -- no spot (or not on screen): nothing is dimmed, the box waits at the bottom of the window
            anchor = function() return spot and spot() or nil end,
        } } } },
    })
    T:Start("whatsnew")
    return true
end

---------------------------------------------------------------------------
-- Small parts
---------------------------------------------------------------------------

-- The height of a wrapped string at width w (the mock doesn't wrap: count the lines from the width).
local function WrapH(fs, w, lineH)
    lineH = lineH or 13
    local h = tonumber(fs:GetStringHeight()) or 0
    local uw = tonumber(fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()) or 0
    if w > 0 and uw > w and h <= lineH + 1 then h = ceil(uw / w) * lineH end
    return max(lineH, h)
end

-- The painting of an area / a section (a raid key; "other": Outland) as UI:SetArtTexture / a banner's art takes it.
local function ArtOf(key, w, h)
    local IDB = ns.ItemDB
    if key and key ~= "other" and IDB and IDB.GetRaidMeta and IDB:GetRaidMeta(key) then return key end
    local E = ns.EventUI
    if E and E.ArtCoords then
        local path, l, r, t, b = E:ArtCoords("outland", w, h, 0.5, 0.55, 0.95)
        return { OUTLAND or path, l, r, t, b }
    end
    return nil
end

-- A gold text link with a chevron ("Show me >"): UI:CreateTextLink, white under the mouse (the chevron stays gold).
local function NewGoLink(parent, label)
    return UI():CreateTextLink(parent, label or "Show me", nil, { style = "small", color = "GOLD", hover = "TEXT",
        chevron = "right", chevSize = 9, chevColor = "GOLD", pad = 2 })
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
        credit = icon .. S:Wrap("SUB", who)
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

-- The tooltip of a credited line (UI:AttachTooltip's title function; the line's box carries the data).
local function CreditTooltip(owner, tt)
    local data = owner.data
    if type(data) ~= "table" then return false end
    local F = ns.Feedback
    local names = {}
    for _, n in ipairs(data.by or {}) do names[#names + 1] = n end
    local r, g, b = S:Color("GOLD")
    tt:AddLine(#names > 0 and ("Asked for by " .. tconcat(names, ", ")) or "From the guild's feedback", r, g, b, true)
    if (tonumber(data.mt) or 0) > 0 then
        r, g, b = S:Color("TEXT")
        tt:AddLine(data.mt == 1 and "and 1 more said me too" or ("and " .. data.mt .. " more said me too"), r, g, b)
    end
    for _, no in ipairs(data.fb or {}) do
        local item = F and F.GetByNumber and F:GetByNumber(no)
        if item then
            tt:AddLine(" ")
            r, g, b = S:Color("SUB")
            tt:AddLine("#" .. no .. "  " .. Util().ShortName(item.author), r, g, b)
            tt:AddLine(item.text, 1, 1, 1, true)
        end
    end
    if F and F.LineIsMine and F:LineIsMine(data) then
        tt:AddLine(" ")
        r, g, b = S:Color("OK")
        tt:AddLine("You asked for this. Thank you!", r, g, b)
    end
end

---------------------------------------------------------------------------
-- Section rows: one line folded (title, kind, area, lead, count), the lines when open
---------------------------------------------------------------------------

-- A line: a dot, its text, the credit; its box carries the picked look when I asked for it, and the credit tooltip.
local function NewLine(parent)
    local line = {}
    line.box = CreateFrame("Frame", nil, parent)
    UI():DecorateRow(line.box, { hover = false, selectable = true })
    UI():AttachTooltip(line.box, CreditTooltip, nil, { anchor = "ANCHOR_TOPRIGHT" })
    line.dot = parent:CreateTexture(nil, "ARTWORK")
    line.dot:SetColorTexture(S:Color("WARN"))
    line.dot:SetSize(4, 4)
    line.fs = UI():Text(parent, "body", "TEXT", { wrap = true })
    line.credit = UI():Text(parent, "small", "SUB", { justify = "RIGHT" })
    return line
end

local function HideLine(l)
    l.dot:Hide(); l.fs:Hide(); l.credit:Hide(); l.box:Hide()
end

-- Lays out lines from y (negative, from the frame's top) at x within width w; returns the new y.
local function LayLines(f, list, lines, x, y, w, marks)
    for i, ln in ipairs(lines) do
        local line = list[i]
        if not line then
            line = NewLine(f)
            list[i] = line
        end
        local text, credit, mine = LineParts(ln.raw)
        text = ln.text or text
        if marks then text = marks(text) end
        if mine then
            local you = S:Wrap("GOLD", "you asked for this")
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
        local box = line.box
        box.data = (type(ln.raw) == "table" and (ln.raw.by or ln.raw.fb or ln.raw.mt)) and ln.raw or nil
        box:EnableMouse(box.data ~= nil)
        box:ClearAllPoints()
        box:SetPoint("TOPLEFT", f, "TOPLEFT", x - 4, y + 3)
        box:SetSize(w + 4, hgt + 5)
        box:SetSelected(mine)
        box:Show()
        y = y - hgt - L.LINE_GAP - 2
    end
    for i = #lines + 1, #list do HideLine(list[i]) end
    return y
end

-- An area's glyph in a small inset tile (a row's, a search block's).
local function NewTile(parent, size, iconSize)
    local t = UI():CreateCard(parent, { tone = "inset", width = size, height = size })
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(iconSize, iconSize)
    t.icon:SetPoint("CENTER")
    return t
end

local function NewRow(parent)
    local r = CreateFrame("Button", nil, parent)
    UI():DecorateRow(r, { selectable = true, rule = true })
    r.tile = NewTile(r, 24, 13)
    r.tile:SetPoint("TOPLEFT", 8, -7)
    r.title = UI():Text(r, "body", "TEXT")
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", 42, -7)
    r.kind = UI():CreatePill(r, nil, nil, 14)
    r.tag = UI():Text(r, "small", "SUB")
    r.you = UI():CreatePill(r, nil, nil, 14)
    r.lead = UI():Text(r, "small", "SUB", { wrap = true })
    r.lead:SetJustifyV("TOP")
    r.lead:SetPoint("TOPLEFT", r, "TOPLEFT", 42, -23)
    r.count = UI():Text(r, "body", "SUB")
    r.chev = r:CreateTexture(nil, "ARTWORK")
    r.chev:SetSize(9, 9)
    r.chev:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -14)
    r.count:SetPoint("RIGHT", r.chev, "LEFT", -4, 0)
    r.more = UI():Text(r, "small", "DIM")
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
    r:SetSelected(open)
    UI():SetGlyph(r.tile.icon, AreaAtlas(sec.area), "TEXT")
    r.title:SetText(UI():SafeText(sec.title))
    local x = 42 + UI():TextWidth(r.title) + 8
    local kinfo = sec.kind and KIND[sec.kind]
    if kinfo then
        r.kind:Set(kinfo[1], kinfo[2])
        r.kind:ClearAllPoints()
        r.kind:SetPoint("LEFT", r, "TOPLEFT", x, -13)
        r.kind:Show()
        x = x + (r.kind:GetWidth() or 40) + 7
    else
        r.kind:Hide()
    end
    local tag = opts.version and S:Wrap("SUB", sec.version)
        or (AreaIcon(sec.area, 10, S.C.SUB) .. " " .. (AREAS[sec.area] or AREAS.other)[1])
    r.tag:SetText(tag)
    r.tag:ClearAllPoints()
    r.tag:SetPoint("LEFT", r, "TOPLEFT", x, -13)
    r.tag:Show()
    x = x + UI():TextWidth(r.tag) + 8
    -- the right side: count + chevron, Show me, what Just for me left out
    local right = 10 + 9 + 4
    r.count:SetText(tostring(#v.lines))
    right = right + UI():TextWidth(r.count) + 10
    UI():SetChevron(r.chev, not open)
    if open then
        r.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    end
    r.chev:SetVertexColor(S:Color("SUB"))
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
        right = right + UI():TextWidth(r.more) + 12
    else
        r.more:Hide()
    end
    if v.credited and x + 120 < w - right then
        local F = ns.Feedback
        local info = F and F.KIND_INFO and F.KIND_INFO.idea
        r.you:Set("You asked for this", "bis", info and info.icon or nil)
        if r.you.icon then r.you.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
        r.you:ClearAllPoints()
        r.you:SetPoint("LEFT", r, "TOPLEFT", x, -13)
        r.you:Show()
    else
        r.you:Hide()
    end
    local lw = max(60, w - 42 - right)
    r.lead:SetWidth(lw)
    r.lead:SetText(UI():SafeText(v.lead))
    local showLead = not open or (sec.lead ~= nil and not (v.lines[1] and v.lines[1].text == sec.lead))
    r.lead:SetShown(showLead)
    local head = showLead and (S.ROW.rich + min(WrapH(r.lead, lw, 12), 24) - 12) or 28
    local h = head
    if open then
        local y = LayLines(r, r.lines, v.lines, 44, -head - 6, w - 44 - 14)
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

-- The card's edge: the picked one (its lines open under the cards) in the deep gold, else the card's own.
local function PaintCardEdge(c)
    local on = c.sec and st.card == c.sec.id
    UI():SetEdgeColor(c, S:Color(on and "GOLD_DEEP" or "EDGE"))
end

local function NewHighlight(parent)
    local c = UI():CreateCard(parent, { tone = "card", height = L.CARD_H })
    c:EnableMouse(true)
    c.artF = CreateFrame("Frame", nil, c)
    c.artF:SetPoint("TOPLEFT", 1, -1)
    c.artF:SetPoint("TOPRIGHT", -1, -1)
    c.artF:SetHeight(L.ART_H)
    c.art = c.artF:CreateTexture(nil, "BACKGROUND")
    c.art:SetAllPoints()
    if ns.EventUI and ns.EventUI.AddShade then ns.EventUI:AddShade(c.artF, "card") end
    c.face = UI():CreateFace(c, 40)
    c.face:SetPoint("TOPLEFT", c, "TOPLEFT", 8, -39)
    c.ver = UI():CreatePill(c, nil, nil, 14)
    c.ver:SetPoint("TOPRIGHT", c, "TOPRIGHT", -6, -6)
    c.title = UI():Text(c, "emph", "TEXT", { wrap = true })
    c.title:SetPoint("TOPLEFT", c, "TOPLEFT", 9, -84)
    c.pitch = UI():Text(c, "small", "SUB", { wrap = true })
    c.pitch:SetJustifyV("TOP")
    c.go = UI():CreateSleekButton(c, "Show me", 76, S.BTN_H, function(self) ChangelogUI:ShowMe(self:GetParent().sec) end,
        "primary")
    c.go:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 9, 8)
    -- the area at the top left, over the shaded art (the version pill takes the top right)
    c.area = UI():Text(c.artF, "small", "TEXT", { shadow = true })
    c.area:SetPoint("TOPLEFT", c, "TOPLEFT", 9, -8)
    c:SetScript("OnEnter", function(self) UI():SetEdgeColor(self, S:Color("EDGE_FOCUS")) end)
    c:SetScript("OnLeave", PaintCardEdge)
    c:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or not self.sec then return end
        st.card = st.card ~= self.sec.id and self.sec.id or nil
        ChangelogUI:Render(true)
    end)
    return c
end

local function FillHighlight(c, sec, v, w, showVer)
    c.sec = sec
    c:SetWidth(w)
    UI():SetArtTexture(c.art, ArtOf(sec.art or (AREAS[sec.area] or AREAS.other)[5], w, L.ART_H), w, L.ART_H)
    c.face:SetGlyph(AreaAtlas(sec.area))
    if showVer then
        c.ver:Set(sec.version, "mute")
        c.ver:Show()
    else
        c.ver:Hide()
    end
    local tw = w - 17
    c.title:SetWidth(tw)
    c.title:SetText(UI():SafeText(sec.title))
    local th = WrapH(c.title, tw, 14)
    c.pitch:SetWidth(tw)
    c.pitch:SetText(UI():SafeText(v.lead))
    c.pitch:ClearAllPoints()
    c.pitch:SetPoint("TOPLEFT", c, "TOPLEFT", 9, -84 - th - 3)
    local ph = WrapH(c.pitch, tw, 12)
    c.need = 84 + th + 3 + ph + 10 + S.BTN_H + 8
    c.go:SetShown(sec.open ~= nil)
    c.area:SetText(AreaIcon(sec.area, 10, S.C.TEXT) .. " " .. (AREAS[sec.area] or AREAS.other)[1])
    PaintCardEdge(c)
    c:Show()
end

---------------------------------------------------------------------------
-- The scroll content: headers, cards, rows, the "for others" note, search results, feedback cards
---------------------------------------------------------------------------

-- the dashed "for others" note, and "Still open" on the feedback view: an inset card with a link
local function NewNote(parent)
    local n = UI():CreateCard(parent, { tone = "inset", height = 32 })
    n:EnableMouse(true)
    n.icon = n:CreateTexture(nil, "ARTWORK")
    n.icon:SetSize(12, 12)
    n.icon:SetPoint("LEFT", 10, 0)
    n.fs = UI():Text(n, "small", "SUB")
    n.fs:SetPoint("LEFT", n.icon, "RIGHT", 8, 0)
    n.go = NewGoLink(n, "Show them")
    n.go:SetPoint("RIGHT", n, "RIGHT", -10, 0)
    n.go:SetScript("OnClick", function(self) local p = self:GetParent(); if p.onClick then p.onClick() end end)
    n:SetScript("OnMouseUp", function(self, button) if button == "LeftButton" and self.onClick then self.onClick() end end)
    return n
end

local function FillNote(n, w, iconIndex, text, linkText, onClick)
    n:SetWidth(w)
    UI():SetGlyph(n.icon, iconIndex, "SUB")
    n.fs:SetText(text)
    n.go:SetLabel(linkText)
    n.onClick = onClick
    n:Show()
end

-- a result group's head (a search): the release as a strip banner over its painting
local function NewStrip(parent)
    local s = UI():CreatePageBanner(parent, { size = "strip", width = 520 })
    s:EnableMouse(true)
    s:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.version then ChangelogUI:Select(self.version) end
    end)
    s:SetActions({ { text = "Read", onClick = function() if s.version then ChangelogUI:Select(s.version) end end } })
    return s
end

-- a result block (a search): a section's title line and its matching lines
local function NewBlock(parent)
    local b = CreateFrame("Frame", nil, parent)
    UI():DecorateRow(b, { hover = false, rule = true })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(11, 11)
    b.icon:SetPoint("TOPLEFT", 9, -8)
    b.title = UI():Text(b, "body", "TEXT")
    b.title:SetPoint("TOPLEFT", 25, -7)
    b.kind = UI():CreatePill(b, nil, nil, 14)
    b.tag = UI():Text(b, "small", "SUB")
    b.go = NewGoLink(b)
    b.go:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -6)
    b.go:SetScript("OnClick", function(self) ChangelogUI:ShowMe(self:GetParent().sec) end)
    b.more = UI():Text(b, "small", "DIM")
    b.lines = {}
    return b
end

-- a shipped item of mine (From your feedback): my words | the line that shipped it (in the picked look)
local function NewFeedbackCard(parent)
    local c = UI():CreateCard(parent, { tone = "card" })
    c.div = UI():Rule(c, { vertical = true, layer = "BORDER" })
    c.kicon = c:CreateTexture(nil, "ARTWORK")
    c.kicon:SetSize(12, 12)
    c.kicon:SetPoint("TOPLEFT", 10, -10)
    c.kicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    c.head = UI():Text(c, "small", "SUB")
    c.head:SetPoint("LEFT", c.kicon, "RIGHT", 6, 0)
    c.quote = UI():Text(c, "body", "TEXT", { wrap = true })
    c.quote:SetPoint("TOPLEFT", 10, -30)
    c.metoo = UI():Text(c, "small", "SUB")
    c.kick = UI():Text(c, "small", "OK")
    c.secText = UI():Text(c, "emph", "TEXT")
    c.lineBox = CreateFrame("Frame", nil, c)
    UI():DecorateRow(c.lineBox, { hover = false, selectable = true })
    c.lineBox:SetSelected(true)
    c.line = UI():Text(c.lineBox, "body", "TEXT", { wrap = true })
    c.go = UI():CreateSleekButton(c, "Show me", 76, S.BTN_H, function(self) ChangelogUI:ShowMe(self:GetParent().secRef) end,
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

-- What the scroll content is made of (UI:Pool each, on panel.child): kind -> function(parent) -> frame
local MAKE = {
    rows = NewRow, cards = NewHighlight, notes = NewNote, strips = NewStrip, blocks = NewBlock,
    fcards = NewFeedbackCard,
    heads = function(p) return UI():CreateSectionHeader(p, "", { style = "caps" }) end,
    aheads = function(p) return UI():CreateSectionHeader(p, "", { style = "title" }) end,
    texts = function(p) return UI():Text(p, "small", "GOLD", { wrap = true }) end,
}
local pools          -- kind -> UI:Pool

local function Take(kind)
    local x = pools[kind]:Acquire()
    x:ClearAllPoints()
    return x
end

local function ResetPools()
    for _, p in pairs(pools) do p:ReleaseAll() end
    if panel and panel.empty then panel.empty:Hide() end
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
    local r = Take("rows")
    r.isCard = opts.isCard
    r:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
    return y - FillRow(r, sec, v, w, opts)
end

-- A section header: "caps" (HIGHLIGHTS ... 4 of 21) or an area's (its glyph and name in gold, a count).
local function PutHeader(y, w, text, right, kind, icon)
    local area = kind == "area"
    local h = Take(area and "aheads" or "heads")
    h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
    h:SetWidth(w)
    if area then
        h:SetTitle(UI():AtlasIconText(icon, 12, S.C.GOLD) .. " " .. text)
        h:SetCount(right)
    else
        h:SetTitle(text)
        h:SetRight(right)
    end
    return y - floor(h:GetHeight() + 0.5) - 6
end

local function PutCards(y, w, items, showVer)
    local n = min(#items, 4)
    if n == 0 then return y end
    local cw = floor((w - (n - 1) * S.GAP) / n)
    local cards, ch = {}, L.CARD_H
    for i = 1, n do
        local c = Take("cards")
        c:SetPoint("TOPLEFT", panel.child, "TOPLEFT", (i - 1) * (cw + S.GAP), y)
        FillHighlight(c, items[i].sec, items[i].v, cw, showVer)
        cards[i] = c
        ch = max(ch, c.need or 0)
    end
    for _, c in ipairs(cards) do c:SetHeight(ch) end
    y = y - ch - S.GAP
    for i = 1, n do
        if st.card == items[i].sec.id then
            y = PutRow(y, w, items[i].sec, items[i].v, { open = true, version = showVer, isCard = true }) - S.GAP
        end
    end
    return y
end

-- Just for me's "Show them": every section and line again.
local function ShowEverything()
    local s = Settings()
    if s then s.changelogForMe = false end
    if panel and panel.forMe then panel.forMe:SetChecked(false) end
    ChangelogUI:Render()
end

local function PutOthers(y, w, g)
    if #g.others == 0 then return y end
    local n = Take("notes")
    n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 6)
    FillNote(n, w, UI().ICON.eye, ("%s for %s"):format(S:Wrap("TEXT", ("%d section%s for others:"):format(#g.others,
        #g.others == 1 and "" or "s")), WhoText(TagList(g.otherTags))), "Show them", ShowEverything)
    return y - 32 - 12
end

-- Nothing to list: the illustrated empty state in the scroll content at y; returns the y under it.
local function PutEmpty(y, w, title, text)
    local e = panel.empty
    if not e then
        e = UI():CreateEmptyState(panel.child, { compact = true, glyph = UI().ICON.notes })
        panel.empty = e
    end
    e:SetContent({ glyph = UI().ICON.notes, title = title, text = text })
    e:SetBoxWidth(min(w, 360))
    e:ClearAllPoints()
    e:SetPoint("TOP", panel.child, "TOPLEFT", floor(w / 2), y - 30)
    e:Show()
    return y - 30 - e:GetHeight() - 10
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
        local h = Take("texts")
        h:SetWidth(w)
        h:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y - 12)
        h:SetText(thanks)
        y = y - 12 - WrapH(h, w, 12)
    end
    if #g.hi + #g.rest + #g.fixes == 0 and #g.others == 0 then
        y = PutEmpty(y, w, "Nothing in this area.")
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
                y = PutHeader(y - 2, w, (AREAS[area] or AREAS.other)[1], tostring(#items), "area", AreaAtlas(area))
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
        local s = Take("strips")
        s:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        s:SetWidth(w)
        s.version = grp.ne.version
        local key = "other"
        for _, it in ipairs(grp.secs) do key = it.sec.art or (AREAS[it.sec.area] or AREAS.other)[5]; break end
        s:SetArt(ArtOf(key, w, S.BANNER.strip))
        s:SetKicker(grp.ne.version)
        s:SetTitle(UI():SafeText(grp.ne.title or ""))
        local n = 0
        for _, it in ipairs(grp.secs) do n = n + #it.lines end
        s:SetSub(ShortDate(grp.ne) .. " · " .. (n == 1 and "1 line" or (n .. " lines")))
        y = y - S.BANNER.strip - 2
        for _, it in ipairs(grp.secs) do
            local b = Take("blocks")
            b:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
            b:SetWidth(w)
            b.sec = it.sec
            UI():SetGlyph(b.icon, AreaAtlas(it.sec.area), "TEXT")
            b.title:SetText(mark(UI():SafeText(it.sec.title)))
            local x = 25 + UI():TextWidth(b.title) + 8
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
            b.tag:SetText(AreaIcon(it.sec.area, 10, S.C.SUB) .. " " .. (AREAS[it.sec.area] or AREAS.other)[1])
            b.tag:ClearAllPoints()
            b.tag:SetPoint("LEFT", b, "TOPLEFT", x, -13)
            b.go:SetShown(it.sec.open ~= nil)
            local shown = {}
            for i = 1, min(4, #it.lines) do shown[i] = it.lines[i] end
            local by = LayLines(b, b.lines, shown, 14, -26, w - 28, mark)
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
        y = y - S.GAP - 2
    end
    if hidden > 0 then
        local n = Take("notes")
        n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        FillNote(n, w, UI().ICON.eye, ("%s for %s"):format(S:Wrap("TEXT", ("%d more line%s"):format(hidden,
            hidden == 1 and "" or "s")), WhoText(TagList(hiddenTags))), "Show them", ShowEverything)
        y = y - 44
    end
    if #res == 0 then
        y = PutEmpty(y, w, "Nothing in any version says that.")
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
        local c = Take("fcards")
        c:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        c:SetWidth(w)
        c.secRef = it.sec
        local raw = it.ln.raw
        local item = type(raw) == "table" and type(raw.fb) == "table" and F.GetByNumber and F:GetByNumber(raw.fb[1])
        local kind = (item and item.kind) or (type(raw) == "table" and raw.k) or "idea"
        local info = F.KIND_INFO and F.KIND_INFO[kind] or F.KIND_INFO.idea
        c.kicon:SetTexture(info.icon)
        local head = (item and item.no) and (S:Wrap("TEXT", "#" .. item.no) .. " · ") or ""
        head = head .. info.short
        if item and item.at then head = head .. " · " .. date("%d %b", item.at) end
        c.head:SetText(head)
        local leftW = floor(w * 0.38)
        c.quote:SetWidth(leftW - 20)
        c.quote:SetText(item and ("“" .. UI():SafeText(item.text or "") .. "”")
            or S:Wrap("DIM", "Your words haven't reached this character yet."))
        local qh = min(WrapH(c.quote, leftW - 20, 13), 13 * 5)
        local votes = item and tonumber(item.voteCount) or (type(raw) == "table" and tonumber(raw.mt)) or 0
        c.metoo:SetText(votes > 0 and (votes == 1 and "1 more said me too" or (votes .. " more said me too"))
            or "Only you asked")
        c.metoo:ClearAllPoints()
        c.metoo:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -30 - qh - 6)
        c.div:ClearAllPoints()
        c.div:SetPoint("TOPLEFT", c, "TOPLEFT", leftW, -1)
        c.div:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", leftW, 1)
        c.div:SetWidth(1)
        local rx, rw = leftW + 12, w - leftW - 24
        c.kick:ClearAllPoints()
        c.kick:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -10)
        c.kick:SetText("|TInterface\\RaidFrame\\ReadyCheck-Ready:11:11|t SHIPPED IN " .. it.sec.version)
        c.secText:ClearAllPoints()
        c.secText:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -26)
        c.secText:SetText(AreaIcon(it.sec.area, 11, S.C.TEXT) .. " " .. UI():SafeText(it.sec.title))
        c.line:SetWidth(rw - 14)
        c.line:SetText(UI():SafeText(it.ln.text))
        local lh = WrapH(c.line, rw - 14, 13)
        c.lineBox:ClearAllPoints()
        c.lineBox:SetPoint("TOPLEFT", c, "TOPLEFT", rx, -44)
        c.lineBox:SetSize(rw, lh + 8)
        c.line:ClearAllPoints()
        c.line:SetPoint("TOPLEFT", c.lineBox, "TOPLEFT", 8, -4)
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
        local h = max(-by + S.BTN_H + 10, 30 + qh + 6 + 14 + 10)
        c:SetHeight(h)
        c:Show()
        y = y - h - S.GAP
    end
    local open = MyOpen()
    if #open > 0 then
        local it = open[1]
        local n = Take("notes")
        n:SetPoint("TOPLEFT", panel.child, "TOPLEFT", 0, y)
        local words = UI():SafeText(tostring(it.text or ""))
        if #words > 60 then words = words:sub(1, 57) .. "..." end
        FillNote(n, w, UI().ICON.notes, ("%s %s“%s”%s"):format(S:Wrap("TEXT", "Still open:"),
            it.no and ("#" .. it.no .. " · ") or "", words, #open > 1 and (" and " .. (#open - 1) .. " more") or ""),
            "Feedback", function()
            if ns.FeedbackUI and ns.FeedbackUI.Open then ns.FeedbackUI:Open("mine") else ns.MainFrame:Open("feedback") end
        end)
        y = y - 32 - 8
    end
    return y
end

---------------------------------------------------------------------------
-- The banner and the toolbar (the areas as its tabs, Just for me as its filter)
---------------------------------------------------------------------------

local function SetBanner(kicker, title, sub, art, icon)
    local b = panel.banner
    b:SetKicker(kicker)
    b:SetTitle(UI():SafeText(title))
    b:SetSub(sub)
    b:SetArt(art)
    b:SetIcon(icon)
end

local function PickArea(area)
    st.area = area
    st.card = nil
    ChangelogUI:Render()
end

-- The areas as the toolbar's tabs (All first, each with its count); the ones that don't fit go into its ··· menu
-- (a pick from there takes the last place in the row). panel.chips = the tab buttons (tab.area = its area, nil: All);
-- panel.moreChip = the menu button (.over = the areas in it, .on = the pick came from it).
local function FillAreas(counts, total)
    local list = { { "all", "All", total } }
    for _, a in ipairs(AREA_ORDER) do
        if (counts[a] or 0) > 0 then list[#list + 1] = { a, AREAS[a][1], counts[a] } end
    end
    if st.area and not counts[st.area] then st.area = nil end
    local bar = panel.toolbar
    local tabs = { selected = st.area or "all" }
    for i, d in ipairs(list) do tabs[i] = { key = d[1], text = d[2], count = d[3], kind = "muted" } end
    bar:SetTabs(tabs)
    -- what fits left of the filter and the menu
    local bw = floor(bar:GetWidth() or 0)
    local room = (bw > 200 and bw or S.PAGE_W) - UI().LAYOUT.TAB_X - (panel.filter:GetWidth() or 150) - S.BTN_H - 40
    local x, fit, over = 0, {}, {}
    for i, d in ipairs(list) do
        local b = bar:GetTab(d[1])
        b.area = d[1] ~= "all" and d[1] or nil
        local w = (b:GetWidth() or 60) + UI().LAYOUT.TAB_GAP
        if i == 1 or (#over == 0 and x + w <= room - ((i < #list) and S.BTN_H or 0)) then
            fit[#fit + 1] = d
            x = x + w
        else
            over[#over + 1] = d
        end
    end
    -- the pick sits in the row even when it came from the menu (in the last place)
    local pickAt
    for i, d in ipairs(over) do
        if d[1] == st.area then pickAt = i end
    end
    if pickAt then
        local d = table.remove(over, pickAt)
        if #fit > 1 then tinsert(over, 1, table.remove(fit)) end
        fit[#fit + 1] = d
    end
    local inRow = {}
    for _, d in ipairs(fit) do inRow[d[1]] = true end
    for _, d in ipairs(list) do bar:SetTabShown(d[1], inRow[d[1]] == true) end
    panel.chips = bar.tabButtons
    if #over == 0 then
        bar:SetMore(nil)
        return
    end
    local more = bar:SetMore(function(root)
        for _, d in ipairs(panel.moreChip.over or {}) do
            root:CreateRadio(d[2] .. "  " .. S:Wrap("DIM", d[3]), function() return st.area == d[1] end,
                function() PickArea(d[1]) end)
        end
    end, "More areas")
    more.over = over
    more.on = pickAt ~= nil
    panel.moreChip = more
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
        earlier.label = ("%s – %s"):format(lo:match("^%d+%.%d+") or lo, hi:match("^%d+%.%d+") or hi)
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

-- A pinned view (Since your last visit, From your feedback): an icon tile, two lines, a count.
local function NewPin(parent)
    local p = CreateFrame("Button", nil, parent)
    p:SetHeight(L.PIN_H)
    UI():DecorateRow(p, { selectable = true })
    p.tile = UI():CreateIconTile(p, 24)
    p.tile:SetPoint("LEFT", 8, 0)
    p.icon = p.tile.tex
    p.t = UI():Text(p, "body", "TEXT")
    p.t:SetPoint("TOPLEFT", p.tile, "TOPRIGHT", 8, 0)
    p.s = UI():Text(p, "small", "SUB")
    p.s:SetPoint("BOTTOMLEFT", p.tile, "BOTTOMRIGHT", 8, 0)
    p.badge = UI():CreateCountBadge(p, 15)
    p.badge:SetPoint("RIGHT", -8, 0)
    p:SetScript("OnClick", function(self) ChangelogUI:Select(self.view) end)
    return p
end

local function NewVRow(parent)
    local r = CreateFrame("Button", nil, parent)
    UI():DecorateRow(r, { selectable = true })
    r.version = UI():Text(r, "body", "GOLD")
    r.version:SetPoint("TOPLEFT", 10, -L.VROW_PAD)
    r.mine = r:CreateTexture(nil, "ARTWORK")
    r.mine:SetSize(10, 10)
    r.mine:SetPoint("LEFT", r.version, "RIGHT", 5, 0)
    r.mine:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.badge = UI():Text(r, "small", "SUB", { justify = "RIGHT" })
    r.badge:SetPoint("TOPRIGHT", -8, -L.VROW_PAD - 1)
    r.hits = UI():CreateCountBadge(r, 14)
    r.hits:SetPoint("TOPRIGHT", -8, -L.VROW_PAD)
    r.title = UI():Text(r, "small", "SUB", { wrap = true })
    r.title:SetJustifyV("TOP")
    r.title:SetPoint("TOPLEFT", 10, -L.VROW_PAD - 16)
    if r.title.SetMaxLines then r.title:SetMaxLines(3) end
    r:SetScript("OnClick", function(self) ChangelogUI:Select(self.view) end)
    return r
end

-- A series of releases (1.3; 1.2 · 1.1 · 1.0; 0.1 - 0.12): a caps heading with how many, folded with a click.
local function NewVGroup(parent)
    local g = CreateFrame("Button", nil, parent)
    g:SetHeight(L.GROUP_H)
    UI():DecorateRow(g, {})
    g.rule = UI():Rule(g, { top = 0 })
    g.head = UI():CreateSectionHeader(g, "", { style = "caps", rule = false })
    g.head:SetPoint("LEFT", g, "LEFT", 6, 0)
    g.head:SetPoint("RIGHT", g, "RIGHT", -18, 0)
    g.chev = g:CreateTexture(nil, "ARTWORK")
    g.chev:SetSize(8, 8)
    g.chev:SetPoint("RIGHT", -8, 0)
    g:SetScript("OnClick", function(self)
        st.collapsed[self.key] = not self.collapsedNow
        ChangelogUI:RenderList()
    end)
    return g
end

local VMAKE = { pins = NewPin, groups = NewVGroup, rows = NewVRow }
local vpools         -- kind -> UI:Pool on panel.vchild

local function VTake(kind)
    local x = vpools[kind]:Acquire()
    x:ClearAllPoints()
    return x
end

function ChangelogUI:RenderList()
    if not panel then return end
    for _, p in pairs(vpools) do p:ReleaseAll() end
    local w = floor(tonumber(panel.vscroll:GetWidth()) or 0)
    if w < 120 then w = L.LIST_W - 12 end
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
            local p = VTake("pins")
            p:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
            p:SetWidth(w)
            p.view = "since"
            p:SetSelected(st.view == "since")
            UI():SetGlyph(p.icon, UI().ICON.notes, "GOLD")
            p.t:SetText("Since your last visit")
            p.s:SetText(("%s to %s"):format(unread[#unread].version, unread[1].version))
            p.badge:SetKind("alert")
            p.badge:SetCount(#unread)
            y = y - L.PIN_H - 2
        end
        if #MyShipped() > 0 then
            local p = VTake("pins")
            p:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
            p:SetWidth(w)
            p.view = "feedback"
            p:SetSelected(st.view == "feedback")
            local F = ns.Feedback
            p.icon:SetTexture(F.KIND_INFO.idea.icon)
            p.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            p.icon:SetVertexColor(1, 1, 1)
            p.t:SetText("From your feedback")
            local shipped, open = #MyShipped(), #MyOpen()
            p.s:SetText(shipped .. " shipped" .. (open > 0 and (" · " .. open .. " still open") or ""))
            p.badge:SetKind("muted")
            p.badge:SetCount(shipped)
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
        local g = VTake("groups")
        g:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y - 3)
        g:SetWidth(w)
        g.key = grp.key
        g.collapsedNow = collapsed
        g.head:SetTitle(grp.label)
        if searching and grp.key ~= Groups()[1].key then
            g.head:SetRight(("%d of %d match"):format(hits, n))
        else
            g.head:SetRight(n == 1 and "1 version" or (n .. " versions"))
        end
        UI():SetChevron(g.chev, collapsed)
        if not collapsed then g.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron))) end
        g.chev:SetVertexColor(S:Color("SUB"))
        y = y - L.GROUP_H - 5
        if not collapsed then
            for _, ne in ipairs(grp.items) do
                local hide = searching and grp.key ~= Groups()[1].key and not hitsBy[ne.version]
                if not hide then
                    local r = VTake("rows")
                    r:SetPoint("TOPLEFT", panel.vchild, "TOPLEFT", 0, y)
                    r:SetWidth(w)
                    r.view = ne.version
                    r:SetSelected(st.view == ne.version and not searching)
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
                        r.badge:SetText(badge and S:Wrap(color, badge) or S:Wrap("DIM", ShortDate(ne)))
                        r.badge:Show()
                        r:SetAlpha(1)
                    end
                    r.title:SetWidth(w - 18)
                    r.title:SetText(UI():SafeText(ne.title or ""))
                    local th = min(WrapH(r.title, w - 18, 12), 36)
                    local h = L.VROW_PAD + 16 + th + L.VROW_PAD + 2
                    r:SetHeight(h)
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

function ChangelogUI:Render(keepScroll)
    if not panel then return end
    roles = nil
    local scrollY = keepScroll and panel.scroll:GetVerticalScroll() or 0
    ResetPools()
    local w = floor((panel.scroll:GetWidth() or 0))
    if w < 100 then w = floor((panel.layout.detailW or 532) - 12) end
    panel.child:SetWidth(w)
    local bw = panel.layout.detailW or 532
    local y, g = -2, nil
    if st.query ~= "" then
        local _, total, _, _, areas, versions = Search(st.query)
        SetBanner("Search", ("%d line%s match %s"):format(total, total == 1 and "" or "s", S:Wrap("GOLD",
            UI():SafeText(st.query))), ("in %d version%s, newest first"):format(versions, versions == 1 and "" or "s"),
            ArtOf("other", bw, S.BANNER.tool), UI().ICON.notes)
        local all = 0
        for _, n in pairs(areas) do all = all + n end
        FillAreas(areas, all)
        y = SearchView(w)
    elseif st.view == "feedback" then
        local shipped = MyShipped()
        local me = Util().ShortName and Util().ShortName(Util().PlayerKey() or "") or ""
        SetBanner("From your feedback", (#shipped == 1 and "1 thing you asked for made it in")
            or (#shipped .. " things you asked for made it in"),
            ("Thank you, %s. Each one says where it shipped."):format(me), ArtOf("mag", bw, S.BANNER.tool),
            UI().ICON.trophy)
        FillAreas({}, #shipped)
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
        SetBanner("While you were away", ("%d new versions since you last looked"):format(#unread),
            ("%s%s · %d sections for you"):format(vtext, dates, g.total), ArtOf("other", bw, S.BANNER.tool),
            UI().ICON.notes)
        FillAreas(g.counts, g.total)
    else
        local ne = Norm().by[st.view or ""]
        if ne then
            y, g = ReleaseView(ne, w)
            local badge = Badge(ne)
            local kicker = ne.version .. (badge and (" · " .. badge:upper()) or "") .. " · " .. strlower(ne.date or ""):upper()
            local sub = ("%d sections for you"):format(g.total)
            if #g.others > 0 then sub = sub .. (" · %d more for %s"):format(#g.others, WhoText(TagList(g.otherTags))) end
            if Compare(ne.version, ns.version) > 0 then
                sub = sub .. "   " .. S:Wrap("DIM", "(you have " .. tostring(ns.version) .. ")")
            end
            local art, icon = "other", UI().ICON.notes
            for _, s in ipairs(ne.sections) do
                if s.hi then art = s.art or (AREAS[s.area] or AREAS.other)[5]; icon = AreaAtlas(s.area); break end
            end
            SetBanner(kicker, ne.title or "", sub, ArtOf(art, bw, S.BANNER.tool), icon)
            FillAreas(g.counts, g.total)
        end
    end
    local hiddenN = g and #g.others or 0
    panel.hidden:SetText(ForMeOn() and hiddenN > 0 and (hiddenN .. " hidden") or "")
    panel:FitFilter()
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
-- The panel: a list + detail page (the releases in the list, the release under its banner in the detail)
---------------------------------------------------------------------------

function ChangelogUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    local lay = UI():CreateLayout("listdetail", p, { listWidth = L.LIST_W, banner = { size = "tool",
        titleSteps = { "hero", "page", "title" } } })   -- (a long release title steps down before it is cut)
    p.layout = lay
    p.banner = lay.banner
    p.toolbar = lay.toolbar
    p.chips = {}

    -- the toolbar: the areas as tabs (FillAreas), Just for me as its filter
    lay.toolbar:SetTabs({ { key = "all", text = "All" } }, function(key)
        PickArea(key ~= "all" and key or nil)
    end)
    local f = CreateFrame("Frame", nil, lay.toolbar)
    f:SetSize(150, S.BTN_H)
    p.filter = f
    p.forMe = UI():CreateSwitch(f, ForMeOn, function(on)
        local s = Settings()
        if s then s.changelogForMe = on and true or false end
        ChangelogUI:RenderList()
        ChangelogUI:Render()
    end)
    p.forMe:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    UI():AttachTooltip(p.forMe, "Just for me",
        "Folds away what is only for the loot council, officers, raid leaders or other classes.", { anchor = "ANCHOR_TOP" })
    p.forMeLabel = UI():Text(f, "body", "TEXT", { text = "Just for me" })
    p.forMeLabel:SetPoint("RIGHT", p.forMe, "LEFT", -7, 0)
    p.hidden = UI():Text(f, "small", "DIM")
    p.hidden:SetPoint("RIGHT", p.forMeLabel, "LEFT", -S.GAP, 0)
    function p:FitFilter()
        local hw = UI():TextWidth(self.hidden)
        self.filter:SetWidth(floor((self.forMe:GetWidth() or 34) + 7 + UI():TextWidth(self.forMeLabel)
            + (hw > 0 and (S.GAP + hw) or 0) + 0.5))
    end
    lay.toolbar:SetFilters({ f })

    -- the list column: the search, the pinned views, the releases
    local left = lay.list
    p.list = left
    p.search = UI():CreateSearchBox(left, L.LIST_W, function(text) ChangelogUI:SetSearch(text) end,
        "Search every version")
    p.search:SetPoint("TOPLEFT", left, "TOPLEFT", 0, 0)
    p.search:SetPoint("TOPRIGHT", left, "TOPRIGHT", 0, 0)
    p.searchCount = UI():Text(left, "small", "SUB")
    p.searchCount:SetPoint("TOPLEFT", p.search, "BOTTOMLEFT", 2, -S.GAP)
    p.vscroll = UI():CreateScrollFrame(left, "DisasterZoneChangelogList")
    p.vscroll:SetPoint("TOPLEFT", p.search, "BOTTOMLEFT", 0, -S.GAP)
    p.vscroll:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -12, 0)
    p.vchild = CreateFrame("Frame", nil, p.vscroll)
    p.vchild:SetSize(L.LIST_W - 12, 10)
    p.vscroll:SetScrollChild(p.vchild)

    -- the detail: the release's banner (the layout's), what scrolls under it
    p.right = lay.detail
    p.scroll = UI():CreateScrollFrame(lay.body, "DisasterZoneChangelogScroll")
    p.scroll:SetPoint("TOPLEFT", lay.body, "TOPLEFT", 0, 0)
    p.scroll:SetPoint("BOTTOMRIGHT", lay.body, "BOTTOMRIGHT", -12, 0)
    p.child = CreateFrame("Frame", nil, p.scroll)
    p.child:SetSize((lay.detailW or 532) - 12, 10)
    p.scroll:SetScrollChild(p.child)

    pools, vpools = {}, {}
    for kind, make in pairs(MAKE) do pools[kind] = UI():Pool(p.child, make) end
    for kind, make in pairs(VMAKE) do vpools[kind] = UI():Pool(p.vchild, make) end
    p.scroll:HookScript("OnSizeChanged", function() ChangelogUI:Render(true) end)

    function p:OnPanelShown()
        if seenBefore == nil then seenBefore = SeenVersion() or false end
        ChangelogUI:MarkRead()
        p.forMe:SetChecked(ForMeOn())
        ChangelogUI:Refresh()
    end
    return p
end

---------------------------------------------------------------------------
-- Home's What's new: a short pop-up of the highlights, a sheet over the dimmed window
---------------------------------------------------------------------------

local POP_W, POP_ROW = 470, 48

-- What the pop-up shows: the unread releases (saved state; else the installed one) and up to four sections for me.
local function PopupItems()
    local list = ChangelogUI:GetUnreadList()
    if #list == 0 then
        local e = LatestReleased()
        if e then list = { e } end
    end
    local items, total, rest = {}, 0, {}
    for _, e in ipairs(list) do
        local ne = Norm().by[e.version]
        for _, sec in ipairs(ne and ne.sections or {}) do
            local v = View(sec)
            if v.mine and not sec.isFix then
                total = total + 1
                if sec.hi and #items < 4 then
                    items[#items + 1] = { sec = sec, v = v }
                elseif not sec.hi then
                    rest[#rest + 1] = { sec = sec, v = v }
                end
            end
        end
    end
    if #items == 0 then      -- no highlights: the first sections
        for i = 1, min(4, #rest) do items[i] = rest[i] end
    end
    return list, items, total
end

local function NewPopRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(POP_ROW)
    UI():DecorateRow(r, { hover = false, rule = true })
    r.face = UI():CreateFace(r, 32)
    r.face:SetPoint("LEFT", 4, 0)
    r.title = UI():Text(r, "emph", "TEXT")
    r.title:SetPoint("TOPLEFT", r, "TOPLEFT", 48, -10)
    r.ver = UI():Text(r, "small", "SUB")
    r.ver:SetPoint("LEFT", r.title, "RIGHT", 6, 0)
    r.pitch = UI():Text(r, "small", "SUB", { wrap = true })
    r.pitch:SetJustifyV("TOP")
    r.pitch:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -4)
    r.go = UI():CreateSleekButton(r, "Show me", 76, S.BTN_H, function(self) ChangelogUI:ShowMe(self:GetParent().sec) end)
    r.go:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    return r
end

local function BuildPopup()
    local host = ns.MainFrame and ns.MainFrame:GetFrame()
    if not host then return nil end
    local sh = UI():CreateSheet(host, { title = "What's new", width = POP_W, height = 360,
        ok = { text = "Read everything", width = 130, onClick = function(self)
            self:Close()
            local list = PopupItems()
            ChangelogUI:Open(#list >= 2 and "since" or (list[1] and list[1].version))
        end },
        cancel = "Later", withWindow = true })      -- (hides and comes back with the window, like before)
    sh.box = sh
    sh.read, sh.later = sh.ok, sh.cancel
    -- (a click on the dimmed window closes it, as Later)
    if sh.dim then sh.dim:SetScript("OnMouseUp", function() sh:Close() end) end
    sh.top = UI():CreatePageBanner(sh.body, { size = "tool", width = POP_W - 2 * UI().SHEET.PAD })
    sh.top:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, 0)
    sh.top:SetPoint("TOPRIGHT", sh.body, "TOPRIGHT", 0, 0)
    sh.rows = {}
    sh.auto = UI():CreateCheckbox(sh, "Open by itself after an update",
        function() local s = Settings(); return s and s.changelogPopup == true end,
        function(on) local s = Settings(); if s then s.changelogPopup = on and true or false end end)
    sh.auto:SetPoint("BOTTOMLEFT", sh, "BOTTOMLEFT", UI().SHEET.PAD, 13)
    return sh
end

-- Opens the pop-up (over the main window, which it opens if needed). false when there is nothing to show: then the
-- tab opens instead.
function ChangelogUI:OpenPopup()
    local list, items, total = PopupItems()
    if #items == 0 then
        self:Open(list[1] and list[1].version)
        return false
    end
    if ns.MainFrame and ns.MainFrame:GetSelectedTab() == nil then ns.MainFrame:Open() end
    local sh = ns.ChangelogPopup or BuildPopup()
    if not sh then return false end
    ns.ChangelogPopup = sh
    local bw = POP_W - 2 * UI().SHEET.PAD
    sh.top:SetArt(ArtOf("other", bw, S.BANNER.tool))
    sh.top:SetKicker(#list >= 2 and "WHAT'S NEW SINCE YOU LAST LOOKED"
        or ("WHAT'S NEW IN " .. (list[1] and list[1].version or "")))
    sh.top:SetTitle(#list >= 2 and ("%d versions, %d changes for you"):format(#list, total)
        or UI():SafeText(list[1] and list[1].title or ""))
    sh.top:SetSub(#items == 1 and "The one you'll notice first:" or ("The %s you'll notice first:"):format(
        ({ "one", "two", "three", "four" })[#items] or tostring(#items)))
    local y = -S.BANNER.tool - 4
    for i, it in ipairs(items) do
        local r = sh.rows[i]
        if not r then
            r = NewPopRow(sh.body)
            sh.rows[i] = r
        end
        r.sec = it.sec
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, y)
        r:SetPoint("RIGHT", sh.body, "RIGHT", 0, 0)
        r.face:SetGlyph(AreaAtlas(it.sec.area))
        r.title:SetText(UI():SafeText(it.sec.title))
        r.ver:SetText(#list >= 2 and it.sec.version or "")
        r.pitch:SetWidth(bw - 48 - 90)
        r.pitch:SetText(UI():SafeText(it.v.lead))
        local rh = max(POP_ROW, 10 + 14 + 4 + min(WrapH(r.pitch, bw - 138, 12), 24) + 10)
        r:SetHeight(rh)
        r.go:SetShown(it.sec.open ~= nil)
        r:Show()
        y = y - rh
    end
    UI():HideFrom(sh.rows, #items + 1)
    local s = Settings()
    sh.auto:SetChecked(s and s.changelogPopup == true)
    sh:SetHeight(floor(UI().SHEET.HEAD_H + UI().SHEET.PAD - y + UI().SHEET.PAD + UI().SHEET.FOOT_H + 0.5))
    sh:Open()
    return true
end

function ChangelogUI:ClosePopup()
    if ns.ChangelogPopup then ns.ChangelogPopup:Close() end
end

function ChangelogUI:OnLogin()
    -- opt-in: after an update the pop-up opens by itself, once, out of combat
    local s = Settings()
    if not (s and s.changelogPopup == true and self:GetUnread()) then return end
    local function try(n)
        if InCombatLockdown() then
            if n < 20 then C_Timer.After(15, function() try(n + 1) end) end
            return
        end
        if self:GetUnread() then self:OpenPopup() end
    end
    C_Timer.After(8, function() try(0) end)
end

function ChangelogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("changelog", "Changelog", 3.9, function(parent) return ChangelogUI:CreatePanel(parent) end,
            nil, { layout = "listdetail" })
    end
    ns:RegisterSlash("changelog", function() ChangelogUI:Open() end, "open the Changelog: what's new in each version")
    ns:On("FEEDBACK_UPDATED", function() if panel and panel:IsVisible() then ChangelogUI:Refresh() end end)
end

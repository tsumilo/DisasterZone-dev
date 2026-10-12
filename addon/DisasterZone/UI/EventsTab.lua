if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventsTab.lua", ...) then return end -- DisasterZone: the Events tab.
-- The Events tab (dev/docs/EVENTS.md; mockup shots 0-2 and 11-14): the guild's own events, built from pieces.
--   Upcoming: the banner (what is live, else what is next) with its stages and the one thing to do; the week's
--     events and the last results below it; my season on the right.
--   An event's page (a click on a row or the banner): the event in plain words stage by stage (part 2's blocks as
--     chips: tags in their colours, what wins, places and "open world only", asks, buttons, walked lists, Matches'
--     "won by"; an Always row for what runs the whole event), its rewards (badges, the scores that decide them, season
--     points) and its entrants; Join / Leave, the host's Start, Edit and Cancel. Once it is over the page is its
--     results: the podium (from Matches, else the first score on the board), the awards, each score's table, the tags
--     at the end, the night's moments, the last four and its numbers.
--   Library: every event the guild saved, as cards with their kinds (Sign-up, Matches, Tags, Places, Asks ...);
--     hovering one shows Host / Copy / Edit / Share. Examples (beside New event) starts from one of the eight.
--   Season: the standings with titles and badges, my season and the ranked events that paid out.
--   Review (GM, officers, guild council): what waits for a decision and, piece by piece, what changed.
--
-- What other modules call:
--   EventsUI:Open(view)                  the tab on a view: "upcoming" (default) | "library" | "season" | "review"
--   EventsUI:OpenEvent(occId)            the tab on a calendar event's page (its results once it is over)
--   EventsUI:Refresh(), EventsUI:GetPanel()
--   EventsUI:OpenSchedule(defId [, occId])         the sheet that puts a library event on the calendar (with occId: a
--                                                  calendar event of mine moved to a new time / place)
--   EventsUI:OpenSubmit(defId)                     the Send for review sheet (the checks, a note for the reviewers)
--   EventsUI:OpenBadgeDesigner(def, badgeId, onSave)   the badge designer; Save calls onSave(badgeId, { n, i, f, ti })
--                                                  (badgeId: the one edited, or a new free id) and the caller saves
-- The sheets are dialogs of their own (strata DIALOG, over the main window or the builder, Escape closes them).
-- Test / audit hooks at the end of the file (GetState, SetLibraryHover, SelectReview, GetSheet, ...).
local addonName, ns = ...

local EventsUI = ns:NewModule("EventsUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tinsert, tsort, tconcat, tremove = table.insert, table.sort, table.concat, table.remove
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber

local S = ns.Style
local DAY = 86400
local PAD, GAP = S.PAD, S.GAP
local PAGE_W, PAGE_H = S.PAGE_W, S.PAGE_H
local NUM_FONT = S.FONT_NUM
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local READY = "Interface\\RAIDFRAME\\ReadyCheck-Ready"
local NOTREADY = "Interface\\RAIDFRAME\\ReadyCheck-NotReady"
local STAR = "Interface\\COMMON\\ReputationStar"
local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local WARN = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

-- The colours: ns.Style tokens (read-only: shared tables), plus white for names over art and black for the icon
-- tiles' edges. pts: the season points' warm gold (the gold the badges are drawn in).
local C = {
    gold = S.C.GOLD, white = { 1, 1, 1 }, text = S.C.TEXT, grey = S.C.SUB, dim = S.C.DIM,
    meta = S.C.TEXT, desc = S.C.TEXT, soft = S.C.TEXT, label = S.C.TEXT, chip = S.C.TEXT,
    pts = { 1, 0.88, 0.54 }, green = S.C.OK, red = S.C.BAD, orange = S.C.WARN, black = { 0, 0, 0, 1 },
}
local CARD = S.C.CARD

local panel
local state = { view = "upcoming", occ = nil, lib = "guild", q = "", hover = nil, review = nil, scroll = {} }

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function Ev() return ns.Events end
local function Live() return ns.EventLive end
local function B() return ns.EventBlocks end
local function Me() return ns.Util.PlayerKey() end
local function IsMe(key) return type(key) == "string" and ns.Util.IsMe(key) or false end

local function Tip(owner, lines, anchor)
    UI():SetTextTooltip(owner, lines, anchor or "ANCHOR_TOP")
end
local function HideTip() GameTooltip:Hide() end
local function Name(key) return EUI():Name(key) end

---------------------------------------------------------------------------
-- Small pieces: text fitting, edges, glyphs, buttons, faces, pills, headers
-- (1.4: the page's old widget kit "H" is retired onto the shared UI: texts are UI:Text on the type scale (sizes snap,
-- D2), fills UI:Fill, gradients UI:Gradient, colours ns.Style tokens (S:Color / S:Wrap), times ns.Util.Now. What stays
-- in H is page logic (the fitting of names that are never cut, the page's geometry, the event menus) and thin aliases
-- of shared parts (UI:CreateSectionHeader, UI:CreatePill, UI:CreateIconTile, UI:CreateSleekButton ...), kept as one
-- local table because the file is near the client's 200-locals limit and has many call sites; what the shared parts
-- do not cover yet is marked TODO(refactor).)
---------------------------------------------------------------------------

local H = {}

-- The page's width / height (the mock's anchored frames have none: the window's page then).
function H.W()
    local w = panel and panel:GetWidth() or 0
    if not w or w < 300 then w = PAGE_W end
    return floor(w)
end
function H.Hgt()
    local h = panel and panel:GetHeight() or 0
    if not h or h < 300 then h = PAGE_H end
    return floor(h)
end
-- A layout's body height (before the first layout pass: what the page's height leaves under the toolbar, a banner
-- of bannerH and the gap).
function H.BodyH(L, bannerH)
    local h = L.body and L.body:GetHeight() or 0
    if not h or h < 50 then
        h = H.Hgt() - UI().LAYOUT.TOP - (bannerH or S.BANNER.hero) - GAP - UI().LAYOUT.BOTTOM
    end
    return floor(h)
end

-- A wrapped text w wide: sets it and returns its height (the client's own, at least what the text's width says).
local function Wrap(fs, text, w, size)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    fs:SetWidth(w)
    fs:SetText(text or "")
    local real = fs:GetStringHeight() or 0
    local uw = (fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth() or 0
    local lines = max(1, ceil(uw / max(1, w)))
    local h = ceil(max(real, lines * ((size or 12) + 3)))
    fs:SetHeight(h)
    return h
end
H.Wrap = Wrap

local function SW(fs) return fs:GetStringWidth() or 0 end

-- A text's width for fitting decisions: the client's, at least what its letters at its size need (a mock without
-- fonts measures every size alike).
local function TextW(fs)
    local _, size = fs:GetFont()
    local plain = (fs:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "WW")
    return max(SW(fs), #plain * (tonumber(size) or 12) * 0.56)
end
H.TextW = TextW

-- A text's whole width on one line, also when it was given a width (GetStringWidth stops there on this client).
local function NatW(fs) return UI():TextWidth(fs) end

-- A text that has to fit in w: at the first size that fits (sizes: a number or a list, largest first), else on two
-- lines at the last one (wrap = false: nil then). Its width is set every time (a reused text may have wrapped before;
-- nothing is cut with "..."). Returns the width its words take, its height and its lines.
local function FitText(fs, text, w, sizes, wrap)
    if type(sizes) ~= "table" then sizes = { sizes or 12 } end
    w = max(10, floor(w))
    fs:SetWordWrap(false)
    fs:SetJustifyV("MIDDLE")
    fs:SetWidth(w)
    for _, size in ipairs(sizes) do
        local s = S:Size(size)
        UI():SetTextSize(fs, s)
        fs:SetText(text or "")
        local tw = NatW(fs)
        if tw <= w + 0.5 then
            fs:SetHeight(s + 3)
            return ceil(tw), s + 3, 1
        end
    end
    if wrap == false then return nil end
    local s = S:Size(sizes[#sizes])
    UI():SetTextSize(fs, s)
    return w, Wrap(fs, text, w, s), 2
end
H.NatW, H.FitText = NatW, FitText

local function Edges(f, c, layer)
    UI():AddEdges(f, layer or "BORDER")
    UI():SetEdgeColor(f, S:Color(c))
end

-- A coloured texture the caller anchors (a hairline, a bar); UI:Rule when it runs along a whole edge.
local function Line(parent, c, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(S:Color(c or "HAIRLINE"))
    return t
end

local function Disc(parent, size, c, layer, sub)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
    return t
end

-- The rules' glyphs (EventBlocks:Describe): atlas icons, the reputation star for ranks.
local GLYPH = { group = "team", clock = "calendar", swords = "bracket", trophy = "trophy", eyeo = "eye" }
function H.Glyph(tex, g, c)
    c = c or C.white
    if g == "rank" or g == "star" then
        tex:SetTexture(STAR)
        tex:SetTexCoord(0, 0.5, 0, 0.5)
        tex:SetVertexColor(1, 1, 1, c[4] or 1)
        return
    end
    local key = GLYPH[g] or g
    local idx = type(key) == "number" and key or UI().ICON[key] or UI().ICON.calendar
    EUI():Glyph(tex, idx, c[1], c[2], c[3], c[4] or 1)
end

-- An event's icon in the shared icon tile (UI:CreateIconTile: the icon with its border cut, a 1 px black edge);
-- f:Set(path) shows the question mark for none.
function H.Icon(parent, size)
    local f = UI():CreateIconTile(parent, size)
    local set = f.Set
    function f:Set(path) set(self, path or QUESTION) end
    return f
end

-- The events' class circle (UI:CreateAvatar): f:Set(key, dim), f:SetEmpty() (an open seat); the tooltip adds the
-- player's title and season rank.
local function FaceTip(self, tt)
    local title = Ev():GetTitle(self.key)
    if title then tt:AddLine(title, S:RGB("GOLD")) end
    local rank = Ev():RankOf(self.key)
    if rank then tt:AddLine("Season rank #" .. rank, S:RGB("SUB")) end
end
function H.Face(parent, size)
    return UI():CreateAvatar(parent, size, { tip = FaceTip })
end

-- A flat button, optionally with an atlas glyph (UI.ICON key / index) or a texture before its text.
function H.Button(parent, text, w, h, kind, onClick, glyph)
    local b = UI():CreateSleekButton(parent, text, w, h, onClick, kind)
    local fs = b:GetFontString()
    if (h or 22) <= 22 then UI():SetTextSize(fs, 11) end
    if glyph then
        b.glyph = b:CreateTexture(nil, "OVERLAY")
        b.glyph:SetSize(12, 12)
        H.SetButtonGlyph(b, glyph)
    end
    return b
end

function H.SetButtonGlyph(b, glyph)
    if not b.glyph then return end
    local fs = b:GetFontString()
    if not glyph then
        b.glyph:Hide()
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 0, 0)
        return
    end
    if type(glyph) == "string" and glyph:find("\\") then
        b.glyph:SetTexture(glyph)
        b.glyph:SetTexCoord(0, 1, 0, 1)
        b.glyph:SetVertexColor(1, 1, 1, 1)
    else
        H.Glyph(b.glyph, glyph, { 0.92, 0.92, 0.92, 0.9 })
    end
    b.glyph:Show()
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", 8, 0)
    b.glyph:ClearAllPoints()
    b.glyph:SetPoint("RIGHT", fs, "LEFT", -6, 0)
end

-- Sizes a button to its text (and glyph): at least minW.
function H.Fit(b, minW, pad)
    local w = SW(b:GetFontString()) + (pad or 26) + ((b.glyph and b.glyph:IsShown()) and 18 or 0)
    b:SetWidth(max(minW or 0, ceil(w)))
    return b:GetWidth()
end

-- A frame whose tooltip is its .tip field at the time ({ title, line ... }; nil: none), above it.
local function FieldTip(self, tt)
    if not self.tip then return false end
    for i, line in ipairs(self.tip) do
        if type(line) == "table" then
            tt:AddLine(line[1], line[2] or 1, line[3] or 1, line[4] or 1, line.wrap)
        elseif i == 1 then
            tt:AddLine(line, S:RGB("GOLD"))
        else
            tt:AddLine(line, 1, 1, 1, true)
        end
    end
end
function H.TipFromField(f)
    UI():AttachTooltip(f, FieldTip, nil, { anchor = "ANCHOR_TOP" })
    return f
end

-- A small rounded chip with an icon (a smart block on a library card): UI:CreatePill (p:Set(text, look, icon)).
function H.Mini(parent)
    local p = UI():CreatePill(parent, 17)
    p:SetBase(CARD[1], CARD[2], CARD[3])
    return p
end

-- A pill (Live, Ranked, In review ...) over dark art: UI:CreatePill (p:SetKind(text, kind)).
function H.Pill(parent, h)
    local p = UI():CreatePill(parent, h or 16)
    if p.SetBase then p:SetBase(0.05, 0.05, 0.06) end
    return p
end

-- A section header (UI:CreateSectionHeader, "title": gold, a grey text at the right, a hairline under it).
-- s:Set(title, right); s.t / s.r / s.line = its title, right text and rule.
local function SectSet(self, t, r)
    self:SetTitle(t or "")
    self:SetRight(r)
    self:Show()
end
function H.Sect(parent)
    local s = UI():CreateSectionHeader(parent, "", { style = "title", width = 100 })
    s.t, s.r, s.line = s.title, s.right, s.rule
    s.Set = SectSet
    return s
end

-- A header's link at its right ("All >"): the section header's own action (grey, gold under the mouse).
function H.Link(sect, text, onClick)
    sect:SetAction({ text = text, onClick = onClick })
    return sect.action
end

-- A panel box (the Season cards): UI:CreateCard; with head, a 28 high header (gold title, a right text, a rule):
-- b.ht / b.hr / b.hline.
function H.Box(parent, head)
    local b = UI():CreateCard(parent, { tone = "card" })
    if head then
        b.ht = UI():Text(b, "title", C.gold)
        b.ht:SetPoint("TOPLEFT", 10, -8)
        b.hr = UI():Text(b, "body", C.desc)
        b.hr:SetJustifyH("RIGHT")
        b.hr:SetPoint("TOPRIGHT", -10, -9)
        b.hline = UI():Rule(b, { top = 28, left = 1, right = 1 })
    end
    return b
end

-- A badge (EventUI) whose icon is `size` across (its metal ring adds about an eighth each side).
function H.Badge(parent, size)
    return EUI():CreateBadge(parent, size)
end

-- The i-th frame of a list, made on first use.
local function Pool(list, i, make)
    local f = list[i]
    if not f then
        f = make()
        list[i] = f
    end
    return f
end
local function HideFrom(list, i) UI():HideFrom(list, i) end
H.Pool, H.HideFrom = Pool, HideFrom

-- A More menu: entries { icon (UI.ICON key / index, or a texture path: an item icon), text, tip, fn, color, danger }.
function H.Menu(owner, entries, title)
    local Ui = UI()
    return Ui:ContextMenu(owner, function(root)
        if title and root.CreateTitle then root:CreateTitle(title) end
        for _, e in ipairs(entries) do
            if e.divider then
                if root.CreateDivider then root:CreateDivider() end
            else
                local mark
                if type(e.icon) == "string" and e.icon:find("\\") then
                    mark = "|T" .. e.icon .. ":16:16:0:0:64:64:5:59:5:59|t"
                else
                    local icon = type(e.icon) == "number" and e.icon or Ui.ICON[e.icon] or Ui.ICON.more
                    mark = Ui:AtlasIconText(icon, 14, e.color or (e.danger and { 1, 0.4, 0.35 }) or C.gold)
                end
                local b = root:CreateButton(mark .. "  " .. e.text, e.fn)
                if b and b.SetTooltip and e.tip then
                    b:SetTooltip(function(tt)
                        tt:AddLine(e.text, S:RGB("GOLD"))
                        tt:AddLine(e.tip, 1, 1, 1, true)
                    end)
                end
            end
        end
    end)
end

H.Tip = Tip

---------------------------------------------------------------------------
-- Words and numbers about events
---------------------------------------------------------------------------

local W = {}

function W.Ord(n)
    n = tonumber(n) or 0
    local s = (n % 100 >= 11 and n % 100 <= 13) and "th" or ({ "st", "nd", "rd" })[n % 10] or "th"
    return n .. s
end

function W.Clock(t) return t and date("%H:%M", t) or "" end
-- Noon of t's day (a day on from noon is the next day, also when the clocks change).
function W.Noon(t)
    local x = date("*t", t)
    return time({ year = x.year, month = x.month, day = x.day, hour = 12 })
end
function W.Day(t) return t and (date("%a ", t) .. date("%d %b", t)) or "" end

-- "Today", "Tomorrow", "Sat" (this week) or "Sat 10 Oct".
function W.DayWord(t)
    local now = ns.Util.Now()
    if date("%Y%m%d", t) == date("%Y%m%d", now) then return "Today" end
    if date("%Y%m%d", t) == date("%Y%m%d", now + DAY) then return "Tomorrow" end
    if t > now and t - now < 6 * DAY then return date("%a", t) end
    return W.Day(t)
end

-- "2 h 12 min", "48 min".
function W.Span(sec)
    sec = max(0, floor(tonumber(sec) or 0))
    local h, m = floor(sec / 3600), floor((sec % 3600) / 60)
    if h > 0 then return h .. " h " .. m .. " min" end
    return max(1, m) .. " min"
end

function W.MinSec(sec)
    sec = max(0, floor(tonumber(sec) or 0))
    return ("%d:%02d"):format(floor(sec / 60), sec % 60)
end

function W.Has(def, kind) return def ~= nil and #B():BlocksOf(def, kind) > 0 end

-- Who takes part: duelists in a bracket, players otherwise.
-- Who takes part, in the event's own word (the mockups' "16 duelists", "9 of 20 racers", "12 anglers"): Matches'
-- duelists, a route's racers, a fishing contest's anglers, else players.
local WALK = { ["lo.lnext"] = true, ["lo.lmine"] = true, ["lo.lpos"] = true, ["lo.lend"] = true }
function W.Noun(def, n)
    local one, many = "player", "players"
    if W.Has(def, "bracket") then
        one, many = "duelist", "duelists"
    elseif type(def) == "table" then
        local s = B():Senses(def) or {}
        local walked = false
        for _, sc in ipairs(def.scripts or {}) do
            B():Walk(sc.top, function(p) if WALK[p.k] then walked = true end end)
        end
        if s.happen and s.happen.fish then one, many = "angler", "anglers"
        elseif walked then one, many = "racer", "racers" end
    end
    return n == 1 and one or many
end

function W.Spots(def)
    for _, bid in ipairs(B():BlocksOf(def, "signup")) do
        return tonumber(B():SmartSetting(def.blocks[bid], "spots"))
    end
    return nil
end

function W.Bracket(def)
    local bid = B():BlocksOf(def, "bracket")[1]
    return bid and def.blocks[bid] or nil
end

-- The kind of event in one word (the rows' second line): what tells it apart most, from its blocks and definitions
-- (Matches, Asks, a route of places, Tags, Places, Lists, Scores, Sign-up).
function W.Kind(def)
    if type(def) ~= "table" then return "Event" end
    local has = {}
    for _, k in ipairs(B():Kinds(def, true)) do has[k] = true end
    if has.bracket then return B():KindLabel("bracket") end
    if has.asks then return B():KindLabel("asks") end
    for _, l in ipairs(has.lists and B():Defs(def, "lists", true) or {}) do
        if l.kind == "place" then return B():KindLabel("places") end
    end
    for _, k in ipairs({ "tags", "places", "lists", "scores", "signup" }) do
        if has[k] then return B():KindLabel(k) end
    end
    return "Event"
end

-- The kinds a card / banner shows as chips, in B:Kinds order: { { k, label, icon } }. Smart blocks have their own
-- icons; a definition kind gets the one that reads as it.
local KIND_ICON = {
    tags = "Interface\\Icons\\Spell_Holy_PrayerOfSpirit", scores = "Interface\\Icons\\INV_Misc_Note_06",
    places = "Interface\\Icons\\INV_Misc_Map_01", lists = "Interface\\Icons\\INV_Scroll_03",
    asks = "Interface\\Icons\\INV_Letter_15",
}
-- (the first to go when they don't all fit: the least telling)
local KIND_DROP = { scores = 1, lists = 2, signup = 3, places = 4, tags = 5, asks = 6, bracket = 7 }
function W.KindChips(def)
    local out = {}
    for _, k in ipairs(type(def) == "table" and B():Kinds(def, true) or {}) do
        local sm = B().SMART[k]
        out[#out + 1] = { k = k, label = B():KindLabel(k), icon = (sm and sm.icon) or KIND_ICON[k] or QUESTION,
            drop = KIND_DROP[k] or 0 }
    end
    return out
end

-- Tooltip words for a kind chip.
local KIND_TIP = {
    signup = "Members join it before it starts.", bracket = "Players meet one on one, round after round.",
    tags = "Players are put in groups (Hiders, Seekers ...) as it runs.", scores = "Players collect points, times or "
        .. "gold; the best win.", places = "Spots in the world: the event knows who is there (open world only).",
    lists = "Lists it goes through: a route, questions ...", asks = "It asks players: votes, answers, scores.",
}

-- A score's words: "most Fish", "fastest Time", "longest Hidden" (what wins), from its definition.
local SCORE_WAY = { num = { "most", "fewest" }, time = { "longest", "fastest" }, gold = { "most", "least" } }
function W.Way(sc)
    if type(sc) ~= "table" then return "most" end
    local way = SCORE_WAY[sc.fmt] or SCORE_WAY.num
    return way[sc.high == false and 2 or 1]
end

-- Who leads a score in words: "most Finds", "longest Hidden"; a score named so already keeps its own words ("Most
-- mushrooms", not "most Most mushrooms").
local SAID = { most = true, longest = true, fastest = true, fewest = true, least = true, highest = true, lowest = true,
    best = true, shortest = true }
function W.Leader(sc)
    local name = type(sc) == "table" and sc.n or ""
    local first = (tostring(name):match("^(%a+)") or ""):lower()
    if SAID[first] then return name end
    return W.Way(sc) .. " " .. name
end

-- A score's number in its look (a time m:ss, gold 1g 20s, a number). sc: a definition or a result's score table.
function W.ScoreText(sc, n)
    if type(sc) ~= "table" then return tostring(n or "") end
    return B():FormatScore({ scores = { x = { fmt = sc.fmt } } }, "x", n)
end

-- A player's score said with its name: "31 Fish", "Time 4:01" (a time reads after the name).
function W.ScoreLine(sc, n)
    local v = W.ScoreText(sc, n)
    if sc and sc.fmt == "time" then return (sc.n or "") .. " " .. v end
    return v .. " " .. (sc and sc.n or "")
end

-- A result's score table ranked: { { key, n, place } } best first (ties share a place: 1, 2, 2, 4).
function W.RankRows(s)
    local rows = {}
    local high = s.high ~= false
    for k, n in pairs(type(s.v) == "table" and s.v or {}) do
        if type(k) == "string" and tonumber(n) then rows[#rows + 1] = { key = k, n = tonumber(n) } end
    end
    tsort(rows, function(a, b)
        if a.n ~= b.n then
            if high then return a.n > b.n end
            return a.n < b.n
        end
        return a.key < b.key
    end)
    for i, r in ipairs(rows) do
        r.place = (i > 1 and rows[i - 1].n == r.n) and rows[i - 1].place or i
    end
    return rows
end

-- How the bracket seeds ("seeded by season rank"), or nil.
function W.SeedText(def)
    local b = W.Bracket(def)
    if not b then return nil end
    local seed = B():SmartSetting(b, "seed")
    if seed == "season" then return "seeded by season rank" end
    if seed == "random" then return "seeded at random" end
    return "seeded in sign-up order"
end

-- A calendar event's entrants: the bracket's seeds or the run's entrants once it runs, else the sign-ups (in the
-- order the bracket will seed them). Returns keys, the run's state.
function W.Entrants(o)
    local L = Live()
    local st = L and L:GetState(o.id)
    if st then
        local bk = ns.EventEngine and ns.EventEngine:BracketOf(o.def, st)
        if bk and bk.seeds and #bk.seeds > 0 then return bk.seeds, st end
        if st.entrants and #st.entrants > 0 then return st.entrants, st end
        for _, b in pairs(st.blocks or {}) do
            if b.kind == "signup" and b.list then return b.list, st end
        end
    end
    local list = {}
    for i, k in ipairs(Ev():GetSignups(o.id)) do list[i] = k end
    local b = W.Bracket(o.def)
    if b and B():SmartSetting(b, "seed") == "season" then
        local order = {}
        for i, k in ipairs(list) do order[k] = i end
        tsort(list, function(x, y)
            local rx, ry = Ev():RankOf(x), Ev():RankOf(y)
            if rx and ry and rx ~= ry then return rx < ry end
            if rx and not ry then return true end
            if ry and not rx then return false end
            return order[x] < order[y]
        end)
    end
    return list, st
end

-- Before it starts, the stage line shows its sign-up as the open stage: a stand-in state for the progress line.
function W.OpenSignup(def)
    local bid = B():BlocksOf(def, "signup")[1]
    return bid and { stage = def.blocks[bid].stage, phase = "planned" } or nil
end

-- Before it starts: can I still join? false + why: "closed" (its sign-up closes before the start, and that time
-- passed) or "full". (A sign-up that closes at the start stays open while the host is late: the run takes who is in.)
function W.CanJoin(o)
    local closes = Ev():ClosesAt(o)
    if closes and closes < o.at and closes <= ns.Util.Now() then return false, "closed" end
    local spots = W.Spots(o.def)
    if spots and #Ev():GetSignups(o.id) >= spots then return false, "full" end
    return true
end

-- The rewards an event gives, from its pieces: { { id, b = badge, label = "1st" | "Biggest upset" ..., pts } } in
-- placing order, and the season points a match won adds (the bracket's "match ends" scripts).
local TARGET_LABEL = { ["bk.champ"] = "1st", ["bk.second"] = "2nd", ["bk.third"] = "3rd", ["pl.host"] = "the host" }
local TARGET_ORDER = { ["bk.champ"] = 1, ["bk.second"] = 2, ["bk.third"] = 3 }

local function TargetSig(v)
    if type(v) ~= "table" then return tostring(v) end
    if v.k then return v.k .. "|" .. tostring(v.a and v.a[1]) .. "|" .. tostring(v.a and v.a[2]) end
    return "?"
end

local function TargetLabel(v)
    if type(v) ~= "table" or not v.k then return "" end
    if TARGET_LABEL[v.k] then return TARGET_LABEL[v.k] end
    if v.k == "var" then return tostring(v.a and v.a[1] or "") end
    if v.k == "ctx" then
        local c = B().CTX[v.a and v.a[1]]
        return c and c.label or ""
    end
    local pd = B().PIECES[v.k]
    return pd and (pd.text or ""):gsub("{%d}", ""):gsub("^%s+", ""):gsub("%s+$", "") or ""
end

-- Where a players value goes, as a reward's place: { label, order, place, sid } (ctx: the stack's surroundings: an
-- enclosing "if each player's place by S = n" gives place n by S).
local function Where(v, ctx)
    if type(v) ~= "table" or not v.k then return { label = "", order = 9 } end
    local p = TARGET_ORDER[v.k]
    if p then return { label = W.Ord(p), order = p, place = p } end
    local a = v.a or {}
    if v.k == "ctx" and a[1] == "each" and ctx.place then
        return { label = W.Ord(ctx.place), order = ctx.place, place = ctx.place, sid = ctx.sid }
    end
    if v.k == "pl.top" and tonumber(a[1]) == 1 and type(a[2]) == "string" then
        return { label = "1st", order = 1, place = 1, sid = a[2] }
    end
    if v.k == "ctx" and a[1] == "each" and ctx.each == "top" and ctx.sid then
        return { label = "top " .. (ctx.n or 3), order = 4, sid = ctx.sid }
    end
    if v.k == "as.top" then return { label = "most picked", order = 7 } end
    if v.k == "var" then return { label = tostring(a[1] or ""), order = 8 } end
    return { label = TargetLabel(v), order = 9 }
end

-- An "if" whose condition is "X's place by S = n" (either way round): n, S.
local function PlaceCond(c)
    if type(c) ~= "table" or c.k ~= "lo.eq" then return nil end
    local x, y = c.a and c.a[1], c.a and c.a[2]
    if type(y) == "table" and type(x) ~= "table" then x, y = y, x end
    if type(x) == "table" and x.k == "pt.place" and tonumber(y) and type(x.a and x.a[2]) == "string" then
        return tonumber(y), x.a[2]
    end
    return nil
end

-- "for each player in ..." of everyone in it (every entrant, a sign-up's list, the Entrants tag).
local function AllPlayers(v)
    if type(v) ~= "table" then return false end
    return v.k == "pl.all" or v.k == "su.list" or (v.k == "pl.tagged" and v.a and v.a[1] == B().ENTRANTS)
end

-- The rewards an event gives, from its pieces: its badges, where each goes (a placing by Matches or by a score, a
-- variable's player ...) and the season points the same pieces give with it; and the other season points.
-- Returns list, extra:
--   list = { { id, b = badge, label = "1st" | "most Finds" | "Biggest upset" ..., order, place, sid, pts } }, in
--     placing order (badges no piece gives yet come last);
--   extra = { match = n (each match won), play = n (playing), other = { { label, pts } } (points no badge goes with) }.
function W.Rewards(def)
    local list, byBadge, extra = {}, {}, { match = 0, play = 0, other = {} }
    if type(def) ~= "table" then return list, extra end
    local SEASON = B().SEASON
    local function scanStack(first, ctx)
        local stack = {}
        local p = first
        while type(p) == "table" and p.k and #stack < 400 do
            stack[#stack + 1] = p
            p = p.n
        end
        -- the season points of this stack, by whom they go to
        local season, sigs = {}, {}
        for _, q in ipairs(stack) do
            if q.k == "pt.add" and q.a and q.a[2] == SEASON and type(q.a[1]) == "number" then
                local sig = TargetSig(q.a[3])
                if not season[sig] then sigs[#sigs + 1] = { sig = sig, v = q.a[3] } end
                season[sig] = (season[sig] or 0) + q.a[1]
            end
        end
        local used = {}
        for _, q in ipairs(stack) do
            if q.k == "pt.badge" and q.a and type(q.a[1]) == "string" then
                local id = q.a[1]
                if def.badges and def.badges[id] and not byBadge[id] then
                    local w = Where(q.a[2], ctx)
                    local sig = TargetSig(q.a[2])
                    byBadge[id] = { id = id, b = def.badges[id], label = w.label, order = w.order, place = w.place,
                        sid = w.sid, pts = season[sig] }
                    used[sig] = true
                    list[#list + 1] = byBadge[id]
                end
            end
        end
        for _, x in ipairs(sigs) do
            if not used[x.sig] then
                local n = season[x.sig]
                local v = x.v
                if ctx.hat == "bk.end" and x.sig:find("^ctx|winner") then
                    extra.match = extra.match + n
                elseif ctx.each == "all" and type(v) == "table" and v.k == "ctx" and v.a and v.a[1] == "each" then
                    extra.play = max(extra.play, n)
                else
                    local w = Where(v, ctx)
                    extra.other[#extra.other + 1] = { label = w.label, pts = n, order = w.order }
                end
            end
        end
        -- what the pieces hold (an if's condition, a "for each"'s players)
        for _, q in ipairs(stack) do
            if q.c1 or q.c2 then
                local sub = {}
                for k, x in pairs(ctx) do sub[k] = x end
                if q.k == "lo.if" or q.k == "lo.ifelse" then
                    local n, sid = PlaceCond(q.a and q.a[1])
                    if n then sub.place, sub.sid = n, sid end
                elseif q.k == "lo.each" then
                    local v = q.a and q.a[1]
                    sub.place, sub.sid, sub.n = nil, nil, nil
                    if AllPlayers(v) then
                        sub.each = "all"
                    elseif type(v) == "table" and v.k == "pl.top" and type(v.a and v.a[2]) == "string" then
                        sub.each, sub.sid, sub.n = "top", v.a[2], tonumber(v.a[1])
                    else
                        sub.each = "some"
                    end
                end
                if q.c1 then scanStack(q.c1, sub) end
                if q.c2 then
                    -- (the else of "if place = n": not that place)
                    if q.k == "lo.ifelse" then sub.place, sub.sid = ctx.place, ctx.sid end
                    scanStack(q.c2, sub)
                end
            end
        end
    end
    for _, s in ipairs(def.scripts or {}) do scanStack(s.top, { hat = s.top and s.top.k }) end
    -- placings by more than one score: say which ("most Finds", "2nd by Hidden")
    local sids, nSids = {}, 0
    for _, r in ipairs(list) do
        if r.sid and not sids[r.sid] then sids[r.sid] = true; nSids = nSids + 1 end
    end
    if nSids > 1 then
        for _, r in ipairs(list) do
            local sc = r.sid and B():Definition(def, "scores", r.sid)
            if sc and r.place == 1 then
                r.label = W.Leader(sc)
            elseif sc and r.place then
                r.label = W.Ord(r.place) .. " by " .. (sc.n or "")
            end
        end
    end
    -- badges no piece gives (designed, not placed yet) still show
    for _, x in ipairs(B():BadgeList(def)) do
        if not byBadge[x.id] then list[#list + 1] = { id = x.id, b = x.b, label = "", order = 10 } end
    end
    tsort(list, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        if (a.sid or "") ~= (b.sid or "") then return (a.sid or "") < (b.sid or "") end
        return (a.b.n or "") < (b.b.n or "")
    end)
    return list, extra
end

-- The season points no badge goes with, in a few words: "5 for playing, 5 a match won" (nil: none).
function W.ExtraText(extra)
    if type(extra) ~= "table" then return nil end
    local parts = {}
    if (extra.play or 0) > 0 then parts[#parts + 1] = extra.play .. " for playing" end
    if (extra.match or 0) > 0 then parts[#parts + 1] = extra.match .. " a match won" end
    if #parts == 0 then return nil end
    return tconcat(parts, ", ")
end

-- The reward of a badge given in a result (matched by name), for its points.
function W.RewardOf(def, badgeName)
    for _, r in ipairs((W.Rewards(def))) do
        if r.b.n == badgeName then return r end
    end
    return nil
end

-- How many pieces an event has (every script, every smart block's own).
function W.PieceCount(def)
    local n = 0
    for _ in pairs(def and def.blocks or {}) do n = n + 1 end
    for _, s in ipairs(def and def.scripts or {}) do n = n + B():Count(s.top) end
    for _, b in pairs(def and def.blocks or {}) do
        for _, s in ipairs(b.inner or {}) do n = n + B():Count(s.top) end
    end
    return n
end

-- How many "post in guild chat" pieces an event has (the review's chat check).
function W.GuildPosts(def)
    local n = 0
    B():EachScript(def, function(s)
        B():Walk(s.top, function(p) if p.k == "ch.guild" then n = n + 1 end end)
    end)
    return n
end

-- The season points one piece hands out (distinct, largest first): "50 / 30 / 20 / 10".
function W.Grants(def)
    local seen, list = {}, {}
    for _, s in ipairs(def and def.scripts or {}) do
        B():Walk(s.top, function(p)
            if p.k == "pt.add" and p.a[2] == B().SEASON and type(p.a[1]) == "number" and not seen[p.a[1]] then
                seen[p.a[1]] = true
                list[#list + 1] = p.a[1]
            end
        end)
    end
    tsort(list, function(a, b) return a > b end)
    return list
end

-- A result's first three: its record's (Matches, or the run's own placings), else, without Matches, the first score
-- on the board ranked (as EventEngine's Result places them). Returns champ, second, third, the score table (or nil).
function W.Placings(r)
    if r.champ or r.second or r.third then return r.champ, r.second, r.third, nil end
    local def = W.DefOfResult(r)
    if W.Has(def, "bracket") or #(r.last4 or {}) > 0 then return nil end
    local by = W.BoardScores(r, def)[1]
    if not by then return nil end
    local rows = W.RankRows(by)
    return rows[1] and rows[1].key, rows[2] and rows[2].key, rows[3] and rows[3].key, by
end

-- My place in a result: "you won", "you placed 2nd", by a score "you placed 7th", "you played" or nil.
function W.MyPlace(r)
    local me = Me()
    local c, s, t, by = W.Placings(r)
    if c == me then return "you won", 1 end
    if s == me then return "you placed 2nd", 2 end
    if t == me then return "you placed 3rd", 3 end
    for _, x in ipairs(by and W.RankRows(by) or {}) do
        if x.key == me then return "you placed " .. W.Ord(x.place), x.place end
    end
    if r.points and r.points[me] then return "you played", nil end
    -- (in a score's table, or with a tag at the end)
    for _, sc in ipairs(r.scores or {}) do
        if type(sc.v) == "table" and sc.v[me] ~= nil then return "you played", nil end
    end
    for _, tg in ipairs(r.tags or {}) do
        for _, k in ipairs(type(tg.k) == "table" and tg.k or {}) do
            if k == me then return "you played", nil end
        end
    end
    return nil
end

-- The banner's kicker of a live run: "ROUND 2 OF 4 · QUARTERFINALS", else the stage.
function W.Kicker(def, st)
    local E = ns.EventEngine
    local bk = E and st and E:BracketOf(def, st)
    if bk and not bk.done and bk.r and bk.r > 0 then
        local rn = EUI():RoundName(bk, bk.r)
        local base = "ROUND " .. bk.r .. " OF " .. (bk.last or "?")
        if rn == "ROUND " .. bk.r then return base end
        return base .. " · " .. rn
    end
    local s = st and B():Stage(def, st.stage)
    local words = s and string.upper(s.name or "") or "LIVE"
    -- (a timer the event shows on its board: the time it has left, "SEEK · 14 MIN LEFT")
    local left = W.TimeLeft(st)
    return left and (words .. " · " .. string.upper(left)) or words
end

-- The time a live run's shown timer has left (the event's board shows it): "14 min left", "40 sec left" (nil: none,
-- or paused).
function W.TimeLeft(st)
    local now = ns.Util.Now()
    if type(st) ~= "table" or st.paused or type(st.shown) ~= "table" then return nil end
    for _, t in ipairs(type(st.timers) == "table" and st.timers or {}) do
        if type(t) == "table" and not t.p and t.n and st.shown[t.n] and tonumber(t.at) and t.at > now then
            local left = t.at - now
            return left >= 60 and (ceil(left / 60) .. " min left") or (floor(left) .. " sec left")
        end
    end
    return nil
end

-- A demo result as the mockups show it (the core's demo results leave the night's details out): made-up moments,
-- the last four and the numbers, kept on the demo record (demo mode only, never sent).
function W.DemoDress(r)
    if not (ns.Util.DemoOn() and r and not r.dressed) then return r end
    r.dressed = true
    -- (the demo's cup results are of its Friday duel cup; its derby comes with its own moments and Fish table)
    if not r.dk then
        for _, d in ipairs(Ev():GetDefs()) do
            if d.name == r.name then r.dk = d.id end
        end
    end
    if not W.Has(W.DefOfResult(r), "bracket") then return r end
    local D = ns.Demo
    local names = D and D.GetMembers and D:GetMembers() or {}
    local others = {}
    for _, k in ipairs(names) do
        if k ~= r.champ and k ~= r.second and k ~= r.third then others[#others + 1] = k end
    end
    local a, b = others[1] or r.champ, others[2] or r.second
    if #r.last4 == 0 and r.champ and r.second then
        r.last4 = {
            { a = r.champ, b = a, wa = 2, wb = 1, win = r.champ, r = 3, sa = 1, sb = 4 },
            { a = r.third or b, b = r.second, wa = 1, wb = 2, win = r.second, r = 3, sa = 3, sb = 2 },
            { a = r.champ, b = r.second, wa = 3, wb = 2, win = r.champ, r = 4, sa = 1, sb = 2, final = true },
            { a = r.third or b, b = a, wa = 2, wb = 1, win = r.third or b, r = 4, sa = 3, sb = 4, bronze = true },
        }
    end
    if #r.moments == 0 then
        local L = Live()
        local function dn(k)
            if IsMe(k) then return "you" end
            return L and L.DisplayName and L.DisplayName(k) or tostring(k)
        end
        r.moments = {
            { at = r.t1 - 480, text = dn(r.champ) .. " came back from 1-2 in the final", i = "Interface\\Icons\\Ability_DualWield" },
            { at = r.at + 1860, text = "Seed 11 " .. dn(others[3] or a) .. " knocked out seed 6",
              i = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
            { at = r.at + 1080, text = "Fastest duel: " .. dn(r.second) .. ", 0:48", i = "Interface\\Icons\\Ability_Rogue_Sprint" },
            { at = r.at + 3120, text = "One dispute, settled by the host", i = "Interface\\Icons\\Spell_Holy_SealOfValor" },
        }
    end
    r.nums = r.nums or {}
    r.nums.watch = r.nums.watch or 23
    if not next(r.mw or {}) then
        r.mw = { [r.champ or ""] = 4, [r.second or ""] = 3, [r.third or ""] = 2 }
    end
    return r
end

-- Every demo result dressed (once): the library's run counts and the rows see them as the pages do.
function W.DressAll()
    if not ns.Util.DemoOn() then return end
    for _, r in ipairs(Ev():GetResults()) do W.DemoDress(r) end
end

-- The event a result was of (its calendar event's copy, else the library's).
function W.DefOfResult(r)
    local o = Ev():GetOcc(r.id)
    return (o and o.def) or (r.dk and Ev():GetDef(r.dk)) or nil
end

---------------------------------------------------------------------------
-- Actions (shared by the views)
---------------------------------------------------------------------------

local A = {}

function A.Watch(occId)
    local Board = ns.EventBoard
    if Board and Board.Open then
        Board:Open(occId)
    else
        ns:Print("the live board isn't available in this version.")
    end
end

function A.Join(occId, on)
    -- (what the button showed may be old: it filled up or its sign-up closed since)
    local o = Ev():GetOcc(occId)
    if on and o and Ev():OccState(o) == "planned" and not Ev():IsSignedUp(occId) then
        local can, why = W.CanJoin(o)
        if not can then
            ns:Print(why == "full" and "%s is full." or "the sign-up for %s has closed.", o.def.name or "that event")
            EventsUI:RequestRefresh()
            return
        end
    end
    local ok, why = Ev():SignUp(occId, on)
    if not ok then ns:Print("%s", why or "that event is gone from the calendar.") end
    EventsUI:RequestRefresh()
end

function A.Builder(def)
    local EB = ns.EventBuilder
    if not (EB and EB.Open) then
        ns:Print("the event builder isn't available in this version.")
        return
    end
    EB:Open(def)
end

-- (the builder opened on nothing starts a new event)
function A.NewEvent() A.Builder(nil) end

function A.Copy(d)
    local copy = Ev():CopyDef(d)
    if copy then A.Builder(copy) end
end

-- The builder on one of the examples (B:Examples), as my own new event (not saved until the builder saves it): the
-- same way the builder's own "Start from" loads one (closed untouched, nothing is kept).
function A.FromExample(key)
    local EB = ns.EventBuilder
    if EB and EB.OpenExample then return EB:OpenExample(key) and true or false end
    local ex = B():Example(key)
    local d = ex and Ev():CopyDef(ex)
    if not d then return false end
    A.Builder(d)
    return true
end

-- "Examples": the eight examples to start from, with their icons (the tooltip says what each one shows).
function A.ExamplesMenu(owner)
    local entries = {}
    for _, e in ipairs(B():Examples()) do
        local key = e.key
        entries[#entries + 1] = { icon = e.icon, text = e.name, tip = e.desc .. ". Opens in the builder as your own "
            .. "event: change anything, then save it.", fn = function() A.FromExample(key) end }
    end
    return H.Menu(owner, entries, "Start from an example")
end

-- The "Examples" button beside a New event (one word and an icon; its tooltip says what it does).
function A.ExamplesButton(parent, h)
    local b = H.Button(parent, "Examples", nil, h, "secondary", function(self) A.ExamplesMenu(self) end, 22)
    H.Fit(b, 90, h >= 26 and 30 or 26)
    UI():AttachTooltip(b, "Start from an example", "Eight ready events, each showing a few blocks at work: a duel cup, "
        .. "hide and seek, a race, a fishing derby, a quiz... Pick one to open it in the builder as your own.",
        { anchor = "ANCHOR_BOTTOM" })
    return b
end

-- The share reference of a calendar event / a library event, when the share links know events.
function A.OccRef(occId)
    local Share = ns.Share
    local ref = Share and Share.EventRef and occId and Share:EventRef(occId)
    return ref and Share:Describe(ref) and ref or nil
end
function A.DefRef(defId)
    local Share = ns.Share
    local ref = Share and Share.EventDefRef and defId and Share:EventDefRef(defId)
    return ref and Share:Describe(ref) and ref or nil
end

-- A share icon button (nil when the share links can't carry events).
function A.ShareButton(parent, size, getRef, title)
    local Share = ns.Share
    if not (Share and Share.CreateButton and (Share.EventRef or Share.EventDefRef)) then return nil end
    return Share:CreateButton(parent, size, getRef, title)
end

-- May I remove anyone's events, calendar events, results and review rows (the GM, officers, the guild council)?
function W.CanRemove()
    local E = Ev()
    if E.CanRemove then return E:CanRemove(Me()) end
    return E:CanModerate(Me())
end

-- Can a calendar event be taken off the calendar (by me)? Not while it runs, nor once it ran (its results go then).
function W.CanRemoveOcc(o)
    local st = o and Ev():OccState(o)
    return o ~= nil and Ev():CanManageOcc(o) and st ~= "live" and st ~= "done"
end

-- Takes a calendar event off the calendar for everyone (asked first). Cancel is the other way: it stays, as cancelled.
function A.RemoveOcc(occId)
    local o = Ev():GetOcc(occId)
    if not W.CanRemoveOcc(o) then return false end
    local name = o.def.name or "the event"
    return EventsUI:Confirm({ title = "Remove " .. name .. "?", text = "It comes off the calendar for everyone, with "
        .. "its sign-ups. (Cancel keeps it listed as cancelled.)", yes = "Remove", danger = true, fn = function()
            if Ev():DeleteOcc(occId) then ns:Print("%s is off the calendar.", name) end
            EventsUI:RequestRefresh()
        end })
end

-- Removes a past event's results for everyone (asked first), and its calendar entry: without its results it would
-- show as not run yet.
function A.RemoveResult(id)
    local r = Ev():GetResult(id)
    if not (r and W.CanRemove()) then return false end
    local name = r.name or "the event"
    return EventsUI:Confirm({ title = "Remove " .. name .. "?", text = "Its results go for everyone, with the season "
        .. "points and badges they gave.", yes = "Remove", danger = true, fn = function()
            if Ev():DeleteResult(id) then
                if Ev():GetOcc(id) then Ev():DeleteOcc(id) end
                ns:Print("%s is removed.", name)
                if state.occ == id then state.occ = nil end
            end
            EventsUI:RequestRefresh()
        end })
end

-- Removes a library event for everyone (mine, or the GM / officers / guild council), asked first.
function A.RemoveDef(d)
    if not (d and (Ev():IsMine(d) or W.CanRemove())) then return false end
    local name = d.name or "the event"
    return EventsUI:Confirm({ title = "Remove " .. name .. "?", text = "Removes it from the guild's library for "
        .. "everyone. Calendar events made from it stay.", yes = "Remove", danger = true, fn = function()
            if Ev():DeleteDef(d.id) then ns:Print("%s is out of the library.", name) end
            EventsUI:RequestRefresh()
        end })
end

-- Takes an event off the review's Waiting list without deciding (asked first); its creator can send it in again.
function A.DismissReview(d)
    if not (d and W.CanRemove() and Ev().DismissReview) then return false end
    local name = d.name or "the event"
    return EventsUI:Confirm({ title = "Remove " .. name .. "?", text = "It comes off the Waiting list without a "
        .. "decision. Its creator can send it in again.", yes = "Remove", danger = true, fn = function()
            Ev():DismissReview(d.id)
            EventsUI:RequestRefresh()
        end })
end

-- Clears an event from the review's Decided list (nothing to ask: the decision stays in force).
function A.HideDecision(d)
    if not (d and W.CanRemove() and Ev().HideDecision) then return false end
    local ok = Ev():HideDecision(d.id)
    EventsUI:RequestRefresh()
    return ok
end

-- The More menu of a calendar event (the banner's, the page's).
function A.OccMenu(owner, o)
    local entries = {}
    local page = state.occ == o.id
    if not page then
        entries[#entries + 1] = { icon = "eye", text = "Details", tip = "Opens the event's page: how it runs, its rewards "
            .. "and who's in.", fn = function() EventsUI:OpenEvent(o.id) end }
    end
    local d = o.def
    entries[#entries + 1] = { icon = "notes", text = "Pieces", tip = "Shows how the event is built, piece by piece, in "
        .. "the builder.", fn = function() A.Builder(Ev():GetDef(o.dk) or d) end }
    local st = Ev():OccState(o)
    if Ev():HostOf(o) == Me() and (st == "planned" or st == "missed") then
        entries[#entries + 1] = { icon = "calendar", text = "Edit", tip = "Moves it to another time or place, or changes "
            .. "the note.", fn = function() EventsUI:OpenSchedule(o.dk, o.id) end }
    end
    if Ev():CanManageOcc(o) and (st == "planned" or st == "missed") then
        entries[#entries + 1] = { divider = true }
        entries[#entries + 1] = { icon = "flag", text = "Cancel", danger = true, tip = "Calls it off: it stays on the "
            .. "calendar as cancelled, so those who signed up see it, and why.", fn = function() EventsUI:ConfirmCancel(o.id) end }
    end
    if W.CanRemoveOcc(o) then
        if not (entries[#entries] and entries[#entries].danger) then entries[#entries + 1] = { divider = true } end
        entries[#entries + 1] = { icon = "trash", text = "Remove", danger = true, tip = "Takes it off the calendar for "
            .. "everyone.", fn = function() A.RemoveOcc(o.id) end }
    end
    H.Menu(owner, entries)
end

---------------------------------------------------------------------------
-- The banner (Upcoming's hero, an event's page, its results)
---------------------------------------------------------------------------

-- 1.4: the event banner IS the shared page banner (UI:CreatePageBanner, "hero": its art under the one shade, the ringed
-- icon, kicker / title / sub stack, the ··· tool at the top right, the actions at S.BTN_H at the bottom right, the
-- back link). What an event adds is laid out after the banner's own layout (H.BannerLayout): the Live pill and a
-- second pill after the title, the share button and the kind chips left of the tools, the stage line or the
-- entrants' meter at the bottom left, a chip / note / why left of the actions.
-- TODO(refactor): move into UI:CreatePageBanner (more than one pill after the title; a slot at the bottom left;
-- frames kept left of the tools and of the actions; a chip beside the actions)

local BAN = { X = 14, EDGE = 12, CHIP_GAP = 8, ACT_Y = 12 }

-- (the art of an event's banner: its loading screen cropped to the banner, as the shared banner takes a crop)
function H.BannerArt(key, w, h, cy)
    return { EUI():ArtCoords(key, max(1, w - 2), max(1, h - 2), 0.55, cy or 0.62, 0.98) }
end

-- A chip of the bottom row: "you" (my match, my tag, my place: the board's blue chip) or "track" (when the sign-up
-- closes, what to fix). b.chip is the one shown (or the last one, hidden).
function H.BannerChip(b, kind, text, o)
    o = o or {}
    local c = kind == "you" and b.chipYou or b.chipInfo
    local other = kind == "you" and b.chipInfo or b.chipYou
    other:Hide()
    c:SetIcon(o.icon)
    c:Set(text, o.rgb, o.key)
    c.key, c.tip = o.key, o.tip
    c:Show()
    b.chip = c
end

function H.BannerChipsOff(b)
    b.chipYou:Hide()
    b.chipInfo:Hide()
    b.chip = b.chipYou
end

-- The banner's actions: btn (the main one, at the far right), btn2, btn3 (b.acts[slot] = { text, kind, fn, tip }).
-- b.btn / b.btn2 / b.btn3 are the banner's buttons that show them (a hidden spare when a slot is empty).
function H.BannerAction(b, slot, text, kind, fn, tip)
    b.acts[slot] = text and { text = text, kind = kind or "secondary", onClick = fn, tip = tip } or nil
end

function H.BannerActionsOff(b)
    b.acts = {}
end

function H.CommitActions(b)
    local list, slots = {}, {}
    for _, slot in ipairs({ "btn", "btn2", "btn3", "shareText" }) do
        if b.acts[slot] then
            list[#list + 1] = b.acts[slot]
            slots[#list] = slot
        end
    end
    b:SetActions(list)
    for _, slot in ipairs({ "btn", "btn2", "btn3", "shareText" }) do b[slot] = b.spare[slot] end
    for i, slot in pairs(slots) do b[slot] = b.actions[i] end
end

-- The share button and the kind chips left of the tools; the pills after the title; the bottom row.
function H.BannerLayout(b)
    b:BaseLayout()
    if not b.acts then return end
    local W = b:GetWidth()
    if not W or W <= 1 then W = b.opts.width or S.INNER_W end
    -- the top right: [kinds] [share] [tools]
    local anchor = b.tools[#b.tools]
    local iconsW = 0
    for i, t in ipairs(b.tools) do iconsW = iconsW + t:GetWidth() + (i > 1 and 4 or 0) end
    if b.share and b.share:IsShown() then
        b.share:ClearAllPoints()
        if anchor then
            b.share:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
        else
            b.share:SetPoint("TOPRIGHT", b, "TOPRIGHT", -BAN.EDGE, -9)
        end
        anchor = b.share
        iconsW = iconsW + (iconsW > 0 and 4 or 0) + b.share:GetWidth()
    end
    b.iconsLeft, b.iconsW = anchor, iconsW
    H.BannerKinds(b, b.kindsDef, W)
    -- the pills after the title: [Live] [pill] [pill2], the title cut to the room they leave
    local pills = {}
    for _, p in ipairs({ b.live, b.pill, b.pill2 }) do if p:IsShown() then pills[#pills + 1] = p end end
    if #pills > 0 and b.titleText then
        local pw = 0
        for _, p in ipairs(pills) do pw = pw + p:GetWidth() + 10 end
        local room = max(40, W - (b.textX or BAN.X) - (iconsW > 0 and (iconsW + BAN.EDGE + 8) or 16) - pw)
        UI():FitText(b.title, b.titleText, room)
        b.title:SetWidth(floor(min(UI():TextWidth(b.title), room) + 1))
        local prev = b.title
        for _, p in ipairs(pills) do
            p:ClearAllPoints()
            p:SetPoint("LEFT", prev, "RIGHT", 10, 0)
            prev = p
        end
    end
    -- the bottom row: [prog | meter] ... [why] [note] [chip] [actions]
    local left = b.actions[#b.actions]
    local used = 0
    for i, a in ipairs(b.actions) do used = used + a:GetWidth() + (i > 1 and 6 or 0) end
    for _, f in ipairs({ b.chip, b.note, b.why }) do
        if f:IsShown() then
            f:ClearAllPoints()
            if left then
                f:SetPoint("RIGHT", left, "LEFT", -BAN.CHIP_GAP, 0)
            else
                f:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -BAN.X, (f == b.why and b.whyLines == 2) and 12 or 18)
            end
            used = used + (left and BAN.CHIP_GAP or 0) + ((f.GetObjectType and f:GetObjectType() == "FontString")
                and NatW(f) or f:GetWidth())
            left = f
        end
    end
    b.prog:ClearAllPoints()
    b.prog:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", BAN.X, BAN.ACT_Y + 5)
    b.meter:ClearAllPoints()
    b.meter:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", BAN.X, BAN.ACT_Y + 1)
    if b.prog:IsShown() and b.progArgs then
        local a = b.progArgs
        b.prog:SetMaxWidth(max(60, W - BAN.X - BAN.EDGE - used - 16))
        b.prog:Set(a[1], a[2], a[3], a[4])
    end
end

-- Makes page banner b an event banner (see above). Its extras: b.live, b.pill2 (pills), b.share, b.kinds (the kind
-- chips), b.prog / b.meter (the bottom left), b.chip (b.chipYou / b.chipInfo), b.note, b.why, the actions b.btn /
-- b.btn2 / b.btn3 / b.shareText (H.BannerAction + H.CommitActions), b.more (its ··· tool: b.onMore(button)).
-- Fields of the shared banner under their old names: b.kick (kicker), b.meta (sub), b.title, b.icon, b.back.
function H.EventBanner(b)
    b.kick, b.meta, b.bh = b.kicker, b.sub, b.m.h
    b.BaseLayout = b.Layout
    b.Layout = H.BannerLayout
    b.live = H.Pill(b, 16)
    b.live:SetKind("Live", "live")
    b.live:Hide()
    b.pill2 = H.Pill(b, 16)
    b.pill2:Hide()
    b.toolList = { { icon = "more", title = "More", text = "What else you can do with this event.",
        onClick = function(self) if b.onMore then b.onMore(self) end end } }
    b:SetTools(b.toolList)
    b.more = b.tools[1]
    b.share = A.ShareButton(b, 22, function() return b.ref end, "Share this event")
    b.kinds = {}
    -- the bottom left: the stages (or the entrants' meter)
    b.prog = EUI():CreateProgress(b)
    b.meter = CreateFrame("Frame", nil, b)
    b.meter:SetSize(300, 22)
    b.meter.faces = {}
    b.meter.fs = UI():Text(b.meter, "body", C.label)
    b.meter.track = b.meter:CreateTexture(nil, "ARTWORK")
    b.meter.track:SetColorTexture(1, 1, 1, 0.12)
    b.meter.track:SetSize(120, 4)
    b.meter.fill = b.meter:CreateTexture(nil, "ARTWORK", nil, 1)
    b.meter.fill:SetHeight(4)
    UI():Gradient(b.meter.fill, "HORIZONTAL", { 0.18, 0.6, 0.3, 1 }, "OK")
    b.meter:Hide()
    -- left of the actions: a chip, a note, why it was called off
    b.chipYou = UI():CreateChip(b, { kind = "you" })
    b.chipInfo = UI():CreateChip(b, { kind = "track" })
    for _, c in ipairs({ b.chipYou, b.chipInfo }) do
        c:EnableMouse(true)
        H.TipFromField(c)
        c:Hide()
    end
    b.chip = b.chipYou
    b.note = UI():Text(b, "body", C.grey)
    b.note:SetJustifyH("RIGHT")
    b.note:Hide()
    b.why = UI():Text(b, "body", C.grey)
    b.why:SetJustifyH("RIGHT")
    b.why:Hide()
    -- the actions (the banner's own buttons; a hidden spare per slot while it is empty)
    b.acts, b.spare = {}, {}
    for _, slot in ipairs({ "btn", "btn2", "btn3", "shareText" }) do
        local s = UI():CreateSleekButton(b, "", 60, S.BTN_H, nil, "secondary")
        s:Hide()
        b.spare[slot] = s
        b[slot] = s
    end
    return b
end

-- A new event banner on parent (the event page's own; Upcoming's is its board layout's hero).
function H.NewBanner(parent, back)
    local b = UI():CreatePageBanner(parent, { size = "hero", back = back })
    return H.EventBanner(b)
end

-- Fills one banner in one go (its setters lay it out once, at the end: H.EndBanner).
function H.BeginBanner(b)
    b.building = true
    H.BannerActionsOff(b)
    H.BannerChipsOff(b)
    b.note:Hide()
    b.why:Hide()
    b.meter:Hide()
    b.live:Hide()
    b.progArgs = nil
end

function H.EndBanner(b)
    H.CommitActions(b)
    b.building = nil
    b:Layout()
end

-- The banner's art, icon, title (+ pills) and meta. pills: { { text, kind } ... } after the title (b.live comes
-- before them when it shows).
function H.BannerHead(b, w, art, icon, name, pills, meta, cy)
    b:SetArt(H.BannerArt(art, w, b.bh, cy or 0.62))
    b:SetIcon(icon or QUESTION)
    local p1, p2 = pills and pills[1], pills and pills[2]
    if p1 then b:SetPill(p1[2], p1[1]) else b:SetPill(nil, nil) end
    b.pill2:SetShown(p2 ~= nil)
    if p2 then b.pill2:SetKind(p2[1], p2[2]) end
    b:SetTitle(name or "")
    b:SetSub(meta or "")
end

-- The stage line of a banner (it gives up its names when the bottom row's right side leaves it short).
function H.SetProg(b, def, st, sub, done)
    b.progArgs = { def, st, sub, done }
    b.prog:SetMaxWidth(nil)
    b.prog:Set(def, st, sub, done)
    b.prog:Show()
end

-- Why it was called off, at the bottom right (two lines when long); nil hides it.
function H.BannerWhy(b, text, maxW)
    if not text or text == "" then
        b.why:Hide()
        return
    end
    local _, _, lines = FitText(b.why, text, maxW, 11)
    b.whyLines = lines
    b.why:Show()
end

-- The top row's right side: share (when the event has a share link) and More.
function H.BannerIcons(b, showMore, ref)
    b.ref = ref
    if showMore then b:SetTools(b.toolList) else b:SetTools(nil) end
    if b.share then b.share:SetShown(ref ~= nil) end
end

-- A kind chip (Sign-up, Matches, Tags, Places ...): a small pill with its icon; hovering says what it means.
function H.KindMini(parent)
    local m = H.Mini(parent)
    m:EnableMouse(true)
    H.TipFromField(m)
    return m
end

-- Kind chips for def in a pool: as many as fit in room (the least telling go first); place(list) puts the ones
-- shown. noTip: chips without a tooltip of their own (a library card's: its hover shows its actions). Returns the
-- width they take.
function H.LayKinds(pool, parent, def, room, place, noTip)
    local chips = W.KindChips(def)
    for i, c in ipairs(chips) do
        local m = Pool(pool, i, function() return noTip and H.Mini(parent) or H.KindMini(parent) end)
        m:Set(c.label, "mute", c.icon)
        m.tip = { c.label, KIND_TIP[c.k] or "" }
        c.m, c.w = m, m:GetWidth()
    end
    HideFrom(pool, #chips + 1)
    local function total()
        local t = 0
        for i, c in ipairs(chips) do if not c.off then t = t + c.w + (i > 1 and 4 or 0) end end
        return t
    end
    while total() > room do
        local worst
        for _, c in ipairs(chips) do
            if not c.off and (not worst or c.drop < worst.drop) then worst = c end
        end
        if not worst then break end
        worst.off = true
    end
    local shown = {}
    for _, c in ipairs(chips) do
        if c.off then c.m:Hide() else shown[#shown + 1] = c.m end
    end
    place(shown)
    return total()
end

-- The banner's kind chips, at the top right left of its icons, in the room the kicker (or the back link) leaves.
function H.BannerKinds(b, def, w)
    if type(def) ~= "table" then
        HideFrom(b.kinds, 1)
        return
    end
    local left = b.textX or BAN.X
    if b.kicker:IsShown() then left = left + NatW(b.kicker) end
    if b.back and b.back:IsShown() then left = max(left, BAN.X + b.back:GetWidth()) end
    local iconsW = b.iconsW or 0
    local room = w - left - 24 - BAN.EDGE - iconsW - (iconsW > 0 and 8 or 0)
    H.LayKinds(b.kinds, b, def, room, function(list)
        local anchor = b.iconsLeft
        -- (from the right: the last first, so they read in their order)
        for i = #list, 1, -1 do
            local m = list[i]
            m:ClearAllPoints()
            if anchor then
                m:SetPoint("RIGHT", anchor, "LEFT", anchor == b.iconsLeft and -8 or -4, 0)
            else
                m:SetPoint("RIGHT", b, "TOPRIGHT", -BAN.EDGE, -20)
            end
            m:Show()
            anchor = m
        end
    end)
end

-- The entrants' meter: up to six faces, "12 of 16 duelists", a bar.
function H.BannerMeter(b, keys, spots, noun)
    local m = b.meter
    local x = 0
    local n = #keys
    for i = 1, 6 do
        local f = Pool(m.faces, i, function()
            local face = H.Face(m, 18)
            face.ring:SetSize(21, 21)
            return face
        end)
        if keys[i] then
            f:Set(keys[i])
            f.ring:SetVertexColor(0.07, 0.07, 0.086, 1)
            f.ring:SetSize(21, 21)
            f:ClearAllPoints()
            f:SetPoint("LEFT", m, "LEFT", x, 0)
            f:SetFrameLevel(m:GetFrameLevel() + 7 - i)
            f:Show()
            x = x + 13
        else
            f:Hide()
        end
    end
    if n > 0 then x = x + 5 + 8 end
    m.fs:SetText((spots and (n .. " of " .. spots) or tostring(n)) .. " " .. noun)
    m.fs:ClearAllPoints()
    m.fs:SetPoint("LEFT", m, "LEFT", x, 0)
    m.track:ClearAllPoints()
    m.track:SetPoint("LEFT", m.fs, "RIGHT", 8, 0)
    local frac = spots and spots > 0 and min(1, n / spots) or 0
    m.track:SetShown(spots ~= nil)
    m.fill:ClearAllPoints()
    m.fill:SetPoint("LEFT", m.track, "LEFT", 0, 0)
    m.fill:SetWidth(max(0.5, 120 * frac))
    m.fill:SetShown(spots ~= nil and frac > 0)
    m:Show()
end

---------------------------------------------------------------------------
-- Upcoming (shot 0): the banner, the week, my season
---------------------------------------------------------------------------

local Up = {}
-- 1.4: Upcoming is a Board page (UI:CreateLayout "board"): the event banner as its hero, the week as art rows
-- (UI:CreateArtRow) under section headers in its body, my season in its side card.
local SEASON_W = (ns.UI.LAYOUT and ns.UI.LAYOUT.SIDE_W) or 250   -- (the board's side card)

function Up.Create(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.layout = UI():CreateLayout("board", v, { toolbar = false, top = UI().LAYOUT.TOP, hero = { size = "hero" },
        side = SEASON_W })
    local L = v.layout
    v.hero = H.EventBanner(L.banner)
    -- (a click on the banner opens the event, as a click on a row does)
    v.hero:EnableMouse(true)
    v.hero:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.occId and self:IsMouseOver() then EventsUI:OpenEvent(self.occId) end
    end)
    v.hero.onMore = function(self)
        local o = v.hero.occId and Ev():GetOcc(v.hero.occId)
        if o then A.OccMenu(self, o) end
    end
    v.scroll = UI():CreateScrollFrame(L.body)
    v.scroll:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
    v.scroll:SetPoint("BOTTOMLEFT", L.body, "BOTTOMLEFT", 0, 0)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(400, 10)
    v.scroll:SetScrollChild(v.content)
    v.heads, v.rows = {}, {}
    v.empty = UI():CreateEmptyState(v.content, { compact = true, glyph = UI().ICON.calendar })
    v.empty:Hide()
    v.card = Up.CreateSeason(v, L.side)
    return v
end

-- A row of the week: UI:CreateArtRow (the event's art and icon, its name with the Ranked pill, what it is / how
-- full / when / who hosts), one action at the right (Join, Joined, Watch, Results) or why there is none.
function Up.NewRow(parent)
    local r = UI():CreateArtRow(parent, { onClick = function(self) if self.occId then EventsUI:OpenEvent(self.occId) end end })
    r.l1, r.l2, r.when = r.title, r.sub, r.rightText
    r.btn = H.Button(r.right, "Join", 60, S.BTN_H, "secondary")
    r.btn:SetPoint("RIGHT", r.right, "RIGHT", 0, 0)
    H.TipFromField(r.btn)
    -- the bin, on hover, for who may take it off (r.remove; its tooltip: r.del.tipText)
    r.del = UI():CreateRemoveButton(r, "Remove")
    r.del:Hide()
    r.del:SetScript("OnClick", function() if r.remove then r.remove() end end)
    r.del:HookScript("OnLeave", function() if not r:IsMouseOver() then r.del:Hide() end end)
    r:SetScript("OnEnter", function(self) if self.remove then self.del:Show() end end)
    r:SetScript("OnLeave", function(self) if not self:IsMouseOver() then self.del:Hide() end end)
    return r
end

-- The row's action button: text, kind, click (nil text: none).
function Up.RowButton(r, text, kind, fn, tip)
    r.btn.tip = tip
    if not text then
        r.btn:Hide()
        return
    end
    r.btn:SetText(text)
    r.btn:SetKind(kind or "secondary")
    H.Fit(r.btn, 56, 26)
    r.btn:SetScript("OnClick", fn)
    r.btn:Show()
end

-- The room the row's right side takes (its action or its words, the bin left of them), kept clear of the title.
function Up.RowRight(r)
    local right = r.btn:IsShown() and r.btn:GetWidth() or 0
    r.del:ClearAllPoints()
    r.del:SetPoint("RIGHT", r, "RIGHT", -(8 + right + 6), 0)
    if not r.remove then r.del:Hide() end
    r:SetRightWidth(8 + right + (r.remove and (6 + 18) or 0) + 6)
end

-- A calendar event's row: the art, its name, when / what it is / how full / who hosts, one action.
function Up.FillOcc(r, o)
    local d = o.def
    r.occId = o.id
    local spots = W.Spots(d)
    local n = #Ev():GetSignups(o.id)
    local st = Ev():OccState(o)
    -- (its day: the row's own words now, where the date stood in a column of its own before 1.4)
    local parts = { W.Kind(d), spots and (n .. " of " .. spots .. " " .. W.Noun(d, spots)) or (n .. " " .. W.Noun(d, n)),
        date("%a %d", o.at) .. " " .. W.Clock(o.at), Name(Ev():HostOf(o)) }
    if st == "live" then
        local keys = W.Entrants(o)
        parts[2] = #keys .. " " .. W.Noun(d, #keys)
    end
    r.remove = W.CanRemoveOcc(o) and function() A.RemoveOcc(o.id) end or nil
    r.del.tipText = "Takes it off the calendar for everyone."
    local signed = Ev():IsSignedUp(o.id)
    local right
    if st == "live" then
        Up.RowButton(r, "Watch", "secondary", function() A.Watch(o.id) end)
    elseif st == "cancelled" then
        Up.RowButton(r, nil)
        right = "Cancelled"
    elseif signed then
        Up.RowButton(r, "Joined", "chosen", function() A.Join(o.id, false) end, { "You're in", "Click to leave." })
    else
        local can, why = W.CanJoin(o)
        if can then
            Up.RowButton(r, "Join", "secondary", function() A.Join(o.id, true) end)
        else
            Up.RowButton(r, nil)
            right = why == "full" and "Full" or "Sign-up closed"
        end
    end
    r:SetData({ art = d.art, icon = d.icon or QUESTION, title = d.name or "Event", sub = tconcat(parts, S:Wrap("SUB", " · ")),
        pill = o.ranked and { "rank", "Ranked" } or nil, right = right })
    Up.RowRight(r)
end

-- A past event's row: its winner, my place, how many took part; Results.
function Up.FillResult(r, res)
    r.occId = res.id
    local parts = {}
    local champ = W.Placings(res)
    if res.cancel then
        parts[#parts + 1] = "Cancelled"
    elseif champ then
        parts[#parts + 1] = "Won by " .. Name(champ)
    end
    local mine = W.MyPlace(res)
    if mine then parts[#parts + 1] = mine end
    if (res.n or 0) > 0 then parts[#parts + 1] = res.n .. " " .. W.Noun(W.DefOfResult(res), res.n) end
    parts[#parts + 1] = date("%a %d", res.at)
    r.remove = W.CanRemove() and function() A.RemoveResult(res.id) end or nil
    r.del.tipText = "Removes its results for everyone, with the season points and badges they gave."
    Up.RowButton(r, "Results", "secondary", function() EventsUI:OpenEvent(res.id) end)
    r:SetData({ art = res.art, icon = res.icon or QUESTION, title = res.name or "Event",
        sub = tconcat(parts, S:Wrap("SUB", " · ")) })
    Up.RowRight(r)
end

-- A live event's chip for me, when it has no Matches: my tag that I see ("You: Hiders", its colour), else my place
-- by its first score on the board ("You're 3rd", my face). Returns words, tint, face (nil: nothing to say).
function W.MyLiveChip(occId)
    local L = Live()
    local tags = L and L.MyTags and L:MyTags(occId) or {}
    for _, t in ipairs(tags) do
        if t.n then return "You: " .. t.n, B():TagColor(t.c), false end
    end
    for _, s in ipairs(L and L.MyScores and L:MyScores(occId) or {}) do
        if s.board and s.place then return "You're " .. W.Ord(s.place), nil, true end
    end
    return nil
end

-- The banner: what is live, else the next event, else the last result.
function Up.PickHero()
    local L = Live()
    for _, id in ipairs(L and L:GetLiveList() or {}) do
        local o = Ev():GetOcc(id)
        if o and Ev():OccState(o) == "live" then return o, "live" end
    end
    local now = ns.Util.Now()
    for _, o in ipairs(Ev():GetOccurrences(now - 6 * 3600, now + 30 * DAY)) do
        if Ev():OccState(o) == "planned" then return o, "planned" end
    end
    local r = Ev():GetResults(now - 7 * DAY, now + 60)[1]
    if r then return r, "done" end
    return nil, "empty"
end

function Up.FillHero(v, w)
    local b = v.hero
    local x, kind = Up.PickHero()
    b.occId = nil
    H.BeginBanner(b)
    local me = Me()
    if kind == "empty" then
        H.BannerHead(b, w, "nagrand", "Interface\\Icons\\Ability_DualWield", "Nothing on the calendar", nil,
            "Pick an event in the Library and host it, or build one of your own.")
        b:SetKicker(nil)
        b.prog:Hide()
        b.kindsDef = nil
        H.BannerIcons(b, false, nil)
        H.BannerAction(b, "btn", "Library", "primary", function() EventsUI:SetView("library") end)
        H.EndBanner(b)
        return nil
    end
    if kind == "done" then
        local r = W.DemoDress(x)
        local o = Ev():GetOcc(r.id)
        b.occId = r.id
        local meta = {}
        local champ = W.Placings(r)
        if champ then meta[#meta + 1] = "Won by " .. Name(champ) end
        meta[#meta + 1] = (r.n or 0) .. " " .. W.Noun(W.DefOfResult(r), r.n)
        if r.hosts and r.hosts[1] then meta[#meta + 1] = "hosted by " .. Name(r.hosts[1]) end
        H.BannerHead(b, w, r.art, r.icon, r.name, { { r.cancel and "Cancelled" or ("Ended " .. W.Clock(r.t1)), "ended" } },
            tconcat(meta, " · "))
        b:SetKicker(W.DayWord(r.at))
        if o then
            H.SetProg(b, o.def, nil, nil, true)
        else
            b.prog:Hide()
        end
        H.BannerIcons(b, false, A.OccRef(r.id))
        b.kindsDef = (o and o.def) or W.DefOfResult(r)
        H.BannerAction(b, "btn", "Results", "primary", function() EventsUI:OpenEvent(r.id) end)
        H.EndBanner(b)
        return r.id
    end
    local o = x
    local d = o.def
    b.occId = o.id
    local pills = o.ranked and { { "Ranked", "rank" } } or nil
    local host = Ev():HostOf(o)
    local where = o.where and o.where ~= "" and o.where or nil
    if kind == "live" then
        local keys, st = W.Entrants(o)
        local meta = { #keys .. " " .. W.Noun(d, #keys) }
        if where then meta[#meta + 1] = where end
        meta[#meta + 1] = "hosted by " .. Name(host)
        H.BannerHead(b, w, d.art, d.icon, d.name, pills, tconcat(meta, " · "), 0.66)
        b.live:Show()
        b:SetKicker(W.Kicker(d, st))
        H.SetProg(b, d, st, EUI():StageSub(d, st))
        -- my match: who I meet and when; else my tag ("You: Hiders") or my place by its first score ("You're 3rd")
        local m = Live():MyMatch(o.id)
        if m then
            local opp = (m.a == me) and m.b or m.a
            local words = m.st == "play" and "You're on now" or "You're up next"
            if opp then words = words .. ", vs " .. Name(opp) end
            H.BannerChip(b, "you", words, { key = opp })
        else
            local words, tint, face = W.MyLiveChip(o.id)
            if words then H.BannerChip(b, "you", words, { rgb = tint, key = face and Me() or nil }) end
        end
        H.BannerAction(b, "btn", "Watch", "primary", function() A.Watch(o.id) end)
    else
        local spots = W.Spots(d)
        local n = #Ev():GetSignups(o.id)
        local meta = { (spots and (n .. " of " .. spots) or tostring(n)) .. " " .. W.Noun(d, spots or n) }
        if where then meta[#meta + 1] = where end
        meta[#meta + 1] = "hosted by " .. Name(host)
        H.BannerHead(b, w, d.art, d.icon, d.name, pills, tconcat(meta, " · "), 0.66)
        b:SetKicker(W.DayWord(o.at) .. " " .. W.Clock(o.at) .. " · " .. EUI():Relative(o.at))
        local can, why = W.CanJoin(o)
        local open = W.OpenSignup(d)
        H.SetProg(b, d, open, (open and can) and "open" or nil)
        local closes = Ev():ClosesAt(o)
        if closes and closes > ns.Util.Now() then
            H.BannerChip(b, "track", "Sign-up closes " .. (W.DayWord(closes) == "Today" and "" or
                (W.DayWord(closes) .. " ")) .. W.Clock(closes))
        end
        if Ev():IsSignedUp(o.id) then
            H.BannerAction(b, "btn", "Joined", "chosen", function() A.Join(o.id, false) end)
        elseif not can then
            b.note:SetText(why == "full" and "Full" or "Sign-up closed")
            b.note:Show()
        else
            H.BannerAction(b, "btn", "Join", "primary", function() A.Join(o.id, true) end)
        end
    end
    H.BannerIcons(b, true, A.OccRef(o.id))
    b.kindsDef = d
    H.EndBanner(b)
    return o.id
end

-- The week below the banner: this week, later, the last results (each a section with its count).
function Up.FillList(v, heroId, listW)
    local now = ns.Util.Now()
    local planned, later = {}, {}
    for _, o in ipairs(Ev():GetOccurrences(now - 6 * 3600, now + 30 * DAY)) do
        local st = Ev():OccState(o)
        if o.id ~= heroId and (st == "planned" or st == "live" or st == "cancelled") then
            if o.at < now + 7 * DAY then planned[#planned + 1] = o else later[#later + 1] = o end
        end
    end
    local recent, older = {}, {}
    for _, r in ipairs(Ev():GetResults(now - 30 * DAY, now + 60)) do
        if r.id ~= heroId then
            if r.at >= now - 8 * DAY then recent[#recent + 1] = r elseif #older < 3 then older[#older + 1] = r end
        end
    end
    -- the rows' height first: is there a scroll bar?
    local ROW_H, HEAD_H = S.ROW.art, 24 + 4
    local n = #planned + #later + #recent + #older
    local heads = (#planned > 0 and 1 or 0) + (#later > 0 and 1 or 0) + (#recent > 0 and 1 or 0) + (#older > 0 and 1 or 0)
    local total = n * ROW_H + heads * HEAD_H + (heads > 1 and (heads - 1) * GAP or 0)
    local avail = H.BodyH(v.layout)
    local cw = total > avail and (listW - 12) or listW
    v.scroll:SetWidth(cw)
    v.content:SetWidth(cw)
    local y, hi, ri = 0, 0, 0
    local function head(text, count)
        hi = hi + 1
        local s = Pool(v.heads, hi, function() return H.Sect(v.content) end)
        s:SetWidth(cw)
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -(y + (hi > 1 and GAP or 0)))
        s:Set(text)
        s:SetCount(count)
        y = y + HEAD_H + (hi > 1 and GAP or 0)
    end
    local function row(fill, x)
        ri = ri + 1
        local r = Pool(v.rows, ri, function() return Up.NewRow(v.content) end)
        r:SetWidth(cw)
        r.cw = cw
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
        r:Show()
        fill(r, x)
        y = y + ROW_H
    end
    if #planned > 0 then
        head("This week", #planned)
        for _, o in ipairs(planned) do row(Up.FillOcc, o) end
    end
    if #later > 0 then
        head("Later", #later)
        for _, o in ipairs(later) do row(Up.FillOcc, o) end
    end
    if #recent > 0 then
        head("Last week", #recent)
        for _, r in ipairs(recent) do row(Up.FillResult, r) end
    end
    if #older > 0 then
        head("Earlier", #older)
        for _, r in ipairs(older) do row(Up.FillResult, r) end
    end
    HideFrom(v.heads, hi + 1)
    HideFrom(v.rows, ri + 1)
    if n == 0 then
        local s = Pool(v.heads, 1, function() return H.Sect(v.content) end)
        s:SetWidth(cw)
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, 0)
        s:Set("This week")
        s:SetCount(nil)
        v.empty:SetContent({ glyph = UI().ICON.calendar, text = "Nothing else on the calendar this week." })
        v.empty:SetBoxWidth(min(360, cw - 40))
        v.empty:ClearAllPoints()
        v.empty:SetPoint("TOP", v.content, "TOP", 0, -(HEAD_H + 16))
        v.empty:Show()
        y = HEAD_H + 16 + v.empty:GetHeight()
    else
        v.empty:Hide()
    end
    v.content:SetHeight(max(1, y))
end

-- My season (the board's side card): the season and its days left, rank, points, who is just above, badges, the
-- top five.
function Up.CreateSeason(v, s)
    local inner = SEASON_W - 2 * S.IN
    s.head = H.Sect(s)
    s.head:SetPoint("TOPLEFT", S.IN, -4)
    s.head:SetPoint("TOPRIGHT", -S.IN, -4)
    s.ht, s.hr = s.head.title, s.head.right
    s.rk = UI():Text(s, 30, C.white, { font = NUM_FONT })
    s.rk:SetPoint("TOPLEFT", 24, -42)
    s.hash = UI():Text(s, "page", C.grey, { font = NUM_FONT })
    s.hash:SetPoint("BOTTOMRIGHT", s.rk, "BOTTOMLEFT", -1, 3)
    s.hash:SetText("#")
    s.pt = UI():Text(s, "title", C.white)
    s.pt:SetPoint("TOPLEFT", s.rk, "TOPRIGHT", 12, -3)
    s.pt2 = UI():Text(s, "body", C.grey)
    s.pt2:SetPoint("TOPLEFT", s.pt, "BOTTOMLEFT", 0, -3)
    s.track = s:CreateTexture(nil, "ARTWORK")
    s.track:SetColorTexture(1, 1, 1, 0.12)
    s.track:SetPoint("TOPLEFT", S.IN, -86)
    s.track:SetSize(inner, 4)
    s.fill = s:CreateTexture(nil, "ARTWORK", nil, 1)
    s.fill:SetPoint("TOPLEFT", s.track, "TOPLEFT")
    s.fill:SetHeight(4)
    UI():Gradient(s.fill, "HORIZONTAL", S.C.GOLD_DEEP, "GOLD")
    s.badges = {}
    s.bcount = UI():Text(s, "body", C.grey)
    s.sect = H.Sect(s)
    s.sect:SetPoint("TOPLEFT", S.IN, -128)
    s.sect:SetPoint("TOPRIGHT", -S.IN, -128)
    s.all = H.Link(s.sect, "All", function() EventsUI:SetView("season") end)
    s.rows = {}
    for i = 1, 5 do
        local r = CreateFrame("Frame", nil, s)
        r:SetSize(SEASON_W - 2, S.ROW.list)
        r:SetPoint("TOPLEFT", 1, -156 - (i - 1) * S.ROW.list)
        UI():DecorateRow(r, { selectable = true })
        r.bg, r.bar = r.dzSelFill, r.dzSelBar
        r.p = UI():Text(r, "title", C.grey, { font = NUM_FONT })
        r.p:SetJustifyH("RIGHT")
        r.p:SetPoint("RIGHT", r, "LEFT", 26, 0)
        r.face = H.Face(r, 18)
        r.face:SetPoint("LEFT", 34, 0)
        r.n = UI():Text(r, "emph", C.white)
        r.n:SetPoint("LEFT", r.face, "RIGHT", 8, 0)
        r.v = UI():Text(r, "title", C.chip, { font = NUM_FONT })
        r.v:SetJustifyH("RIGHT")
        r.v:SetPoint("RIGHT", -S.IN, 0)
        s.rows[i] = r
    end
    s.none = UI():Text(s, "body", C.grey)
    s.none:SetPoint("TOPLEFT", S.IN + 2, -160)
    return s
end

-- The rank I hold, the one above me (or below when I lead): row, above, below.
function W.MyStanding(rows)
    local me = Me()
    for i, r in ipairs(rows) do
        if r.key == me then return r, rows[i - 1], rows[i + 1] end
    end
    return nil
end

-- "12 behind Bert" / "5 ahead of Bert" / "tied with Bert" (the same points).
function W.Gap(mine, other, ahead)
    if not other then return nil end
    if other.pts == mine.pts then return "tied with " .. Name(other.key) end
    if ahead then return (mine.pts - other.pts) .. " ahead of " .. Name(other.key) end
    return (other.pts - mine.pts) .. " behind " .. Name(other.key)
end

function Up.FillSeason(s)
    local season = Ev():GetSeason()
    local left = max(0, ceil((season.to - ns.Util.Now()) / DAY))
    -- (a long season name is cut; the days left go when it still doesn't fit: the Season page says them)
    local room = SEASON_W - 2 * S.IN - 4
    local days = left == 1 and "1 day left" or (left .. " days left")
    local name = season.n or "Season"
    local fits = UI():TextWidth(name, "emph") + UI():TextWidth(days, "body") + 10 <= room
    s.head:Set(name, fits and days or nil)
    if not fits then UI():FitText(s.ht, name, room) end
    local rows = Ev():Standings(season)
    local mine, above, below = W.MyStanding(rows)
    if mine then
        s.rk:SetText(mine.rank)
        s.pt:SetText(mine.pts .. (mine.pts == 1 and " point" or " points"))
        if above then
            s.pt2:SetText(W.Gap(mine, above))
        elseif below then
            s.pt2:SetText(W.Gap(mine, below, true))
        else
            s.pt2:SetText("the only one on the board")
        end
        local frac = above and above.pts > 0 and min(1, mine.pts / above.pts) or 1
        s.fill:SetWidth(max(1, (SEASON_W - 2 * S.IN) * frac))
        s.fill:Show()
    else
        s.rk:SetText("-")
        s.pt:SetText("No points yet")
        s.pt2:SetText("Ranked events give season points")
        s.fill:Hide()
    end
    local badges = Ev():BadgesOf(Me())
    local x = S.IN
    for i = 1, 5 do
        local bd = Pool(s.badges, i, function() return H.Badge(s, 19) end)
        if badges[i] then
            bd:SetBadge(badges[i])
            bd:ClearAllPoints()
            bd:SetPoint("TOPLEFT", s, "TOPLEFT", x, -98)
            x = x + bd:GetWidth() + 6
        else
            bd:Hide()
        end
    end
    s.bcount:ClearAllPoints()
    s.bcount:SetPoint("TOPLEFT", s, "TOPLEFT", #badges > 0 and (x + 2) or S.IN, -106)
    s.bcount:SetText(#badges == 0 and "No badges yet" or (#badges == 1 and "1 badge" or (#badges .. " badges")))
    s.sect:Set("Standings")
    -- the top five, me in it (in the fifth place when I'm further down)
    local list = {}
    for i = 1, min(5, #rows) do list[i] = rows[i] end
    if mine and mine.rank > 5 then list[5] = mine end
    for i, r in ipairs(s.rows) do
        local x2 = list[i]
        if x2 then
            r:SetSelected(x2.key == Me())
            r.p:SetText(x2.rank)
            r.face:Set(x2.key)
            r.n:SetText(Name(x2.key))
            r.v:SetText(x2.pts)
            r:Show()
        else
            r:Hide()
        end
    end
    s.none:SetShown(#rows == 0)
    s.none:SetText("No ranked event has paid out yet.")
end

function Up.Fill(v)
    local L = v.layout
    local w = L.innerW
    local heroId = Up.FillHero(v, w)
    Up.FillList(v, heroId, L.bodyW)
    Up.FillSeason(v.card)
end

---------------------------------------------------------------------------
-- An event's page (shot 1): how it runs, its rewards, who's in
---------------------------------------------------------------------------

local Pg = {}
local RIGHT_W, COL_GAP = 286, 16

-- 1.4: an event's page (and its results) is a Detail page (UI:CreateLayout "detail") under the tab's toolbar: the
-- event banner with the way back, then the body (no tabs: the strip stays hidden).
function Pg.Create(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.layout = UI():CreateLayout("detail", v, { toolbar = false, top = UI().LAYOUT.TOP, banner = { size = "hero" },
        back = { text = "Events", onClick = function() EventsUI:Back() end } })
    local L = v.layout
    L.tabs:Hide()
    L:Layout()
    v.ban = H.EventBanner(L.banner)
    v.ban.onMore = function(self)
        local o = state.occ and Ev():GetOcc(state.occ)
        if v.mode == "results" then
            Pg.ResultsMenu(self, state.occ)
        elseif o then
            A.OccMenu(self, o)
        end
    end
    v.scroll = UI():CreateScrollFrame(L.body)
    v.scroll:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
    v.scroll:SetPoint("BOTTOMLEFT", L.body, "BOTTOMLEFT", 0, 0)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(700, 10)
    v.scroll:SetScrollChild(v.content)
    v.lsect = H.Sect(v.content)
    v.stages = {}
    v.rsect = H.Sect(v.content)
    v.rewards = {}
    v.esect = H.Sect(v.content)
    v.ents = {}
    v.wsect = H.Sect(v.content)
    v.wsect:Hide()
    v.res = Pg.CreateResults(v)
    return v
end

-- Where an event is (Where to go): its places with coordinates on a map most of them are on, the meeting place
-- first. { map, list = { place ... }, meet = pid } or nil (no places on a map).
local WHERE_H = 150
function Pg.Places(d, meet)
    local list, count, best, bestN = {}, {}, nil, 0
    for _, p in ipairs(B():Defs(d, "places", true)) do
        local m = tonumber(p.map)
        if m and tonumber(p.x) and tonumber(p.y) then
            list[#list + 1] = p
            count[m] = (count[m] or 0) + 1
            if count[m] > bestN or (p.id == meet) then best, bestN = m, max(bestN, count[m]) end
        end
    end
    if not best then return nil end
    local on = {}
    for _, p in ipairs(list) do if tonumber(p.map) == best then on[#on + 1] = p end end
    return { map = best, list = on, meet = meet }
end

-- The "Where" section's map: the places (the meeting place in gold), my own arrow, the zone's name; a place's card
-- on hover, and a click shows me the way there.
function Pg.FillWhere(v, o, wh, x, y)
    local m = v.wmap
    if not m then
        m = EUI():CreateZoneMap(v.content, RIGHT_W, WHERE_H)
        v.wmap = m
    end
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", v.content, "TOPLEFT", x, -y)
    m:SetSize2(RIGHT_W, WHERE_H)
    m:SetMap(wh.map)
    local pts = {}
    for _, p in ipairs(wh.list) do pts[#pts + 1] = { tonumber(p.x), tonumber(p.y), tonumber(p.r) or 30 } end
    -- (close in: places a few hundred yards apart keep their names apart)
    m:Fit(pts, 0.12)
    for i, p in ipairs(wh.list) do
        m:Place(i, tonumber(p.x), tonumber(p.y), tonumber(p.r) or 30, p.n, p.id == wh.meet and "hot" or "place")
        local pid = p.id
        m:PlaceInfo(i, { place = p, click = function() EUI():ShowTheWay(o.id, pid, o.def) end })
    end
    m:Done(#wh.list)
    m:ShowZone(true)
    m:ShowMe(true)
    m:Show()
end

-- A rule of a stage ("best of 3", "5 min no-show"): a small flat chip with its glyph. look: nil (the glyph g), or
-- { dot = rgb } (a tag: its colour), { ring = rgb } (a place), { box = true } (a button: a small button's shape).
-- TODO(refactor): move into UI:CreateChip (a square look; an atlas glyph, a ring or a button's shape in front)
local PLACE_C = { 0.34, 0.84, 0.94 }    -- Places' colour (EventBlocks' pc edge)
function Pg.NewRule(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(18)
    UI():Fill(c, "QUIET")
    Edges(c, { 1, 1, 1, 0.1 })
    c.glyph = c:CreateTexture(nil, "ARTWORK")
    c.glyph:SetSize(11, 11)
    c.glyph:SetPoint("LEFT", 7, 0)
    c.dot = Disc(c, 8, C.white, "ARTWORK")
    c.dot:SetPoint("CENTER", c, "LEFT", 12, 0)
    c.box = CreateFrame("Frame", nil, c)
    c.box:SetSize(13, 9)
    c.box:SetPoint("LEFT", 6, 0)
    UI():Fill(c.box, { 0.22, 0.22, 0.25, 1 })
    Edges(c.box, { 1, 1, 1, 0.5 })
    c.fs = UI():Text(c, "body", C.meta)
    c.fs:SetPoint("LEFT", 23, 0)
    c:EnableMouse(true)
    H.TipFromField(c)
    function c:Set(g, t, look, tip)
        self.tip = tip
        self.glyph:Hide()
        self.dot:Hide()
        self.box:Hide()
        if look and look.dot then
            local k = look.dot
            self.dot:SetTexture(DISC)
            self.dot:SetSize(8, 8)
            self.dot:SetVertexColor(k[1], k[2], k[3], 1)
            self.dot:Show()
            UI():SetEdgeColor(self, k[1], k[2], k[3], 0.3)
        elseif look and look.ring then
            local k = look.ring
            self.dot:SetTexture(EUI().RING)
            self.dot:SetSize(11, 11)
            self.dot:SetVertexColor(k[1], k[2], k[3], 1)
            self.dot:Show()
            UI():SetEdgeColor(self, k[1], k[2], k[3], 0.3)
        elseif look and look.box then
            self.box:Show()
            UI():SetEdgeColor(self, 1, 1, 1, 0.1)
        else
            H.Glyph(self.glyph, g, { 1, 1, 1, 0.8 })
            self.glyph:Show()
            UI():SetEdgeColor(self, 1, 1, 1, 0.1)
        end
        self.fs:SetText(t or "")
        self:SetWidth(ceil(23 + SW(self.fs) + 8))
    end
    return c
end

-- What the page says to a tag's / place's / list's chip on hover.
local SHOWN_WORDS = { all = "Everyone sees who has it.", self = "Only the players who have it see it.",
    host = "Only the host sees who has it." }
local LIST_GLYPH = { place = 36, question = 11, text = 25 }

-- A stage's rules (EventBlocks:DescribeStage) as the page's chips: { { g, t, look, tip } }. A tags rule is a chip per
-- tag in its colour; a place has its ring; asks, buttons and lists their own glyphs; after the places (and a route
-- of them), "open world only" (places don't work in dungeons).
function Pg.Chips(d, s)
    local out, world = {}, nil
    for _, r in ipairs(s.rules or {}) do
        if type(r.tags) == "table" then
            for _, tid in ipairs(r.tags) do
                local tg = B():Definition(d, "tags", tid)
                if tg then
                    out[#out + 1] = { t = tg.n, look = { dot = B():TagColor(tg.c) },
                        tip = { tg.n, "A tag: a group of players. " .. (SHOWN_WORDS[tg.shown or "all"] or "") } }
                end
            end
        elseif r.place then
            local pl = B():Definition(d, "places", r.place)
            local size = pl and tonumber(pl.r) and (" · " .. floor(pl.r) .. " yd") or ""
            local where = pl and (pl.sz or pl.z) or nil
            out[#out + 1] = { t = r.t, look = { ring = PLACE_C }, tip = { r.t, (where and (where .. size) or ("A place"
                .. size)), "The event knows who is in it. The game doesn't say where players are." } }
            world = #out
        elseif r.list then
            local l = B():Definition(d, "lists", r.list)
            out[#out + 1] = { g = l and LIST_GLYPH[l.kind] or 25, t = r.t }
            if l and l.kind == "place" then world = #out end
        elseif r.ask then
            out[#out + 1] = { g = 42, t = r.t, tip = { "Asks", "The addon asks the players and shows the answers: no "
                .. "chat needed." } }
        elseif r.button then
            out[#out + 1] = { t = r.t, look = { box = true }, tip = { r.button, "A button in the event's tracker, under "
                .. "the minimap, for the players who get it." } }
        else
            out[#out + 1] = { g = r.g, t = r.t }
        end
    end
    if world then
        tinsert(out, world + 1, { g = 7, t = "open world only", tip = { "Open world only", "Places work in the open "
            .. "world, not in dungeons or raids." } })
    end
    return out
end

function Pg.NewStage(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(400, 60)
    r.glow = Disc(r, 33, S:WithAlpha("GOLD", 0.18), "BACKGROUND", 0)
    r.glow:SetPoint("CENTER", r, "TOPLEFT", 12, -19)
    r.ring = Disc(r, 23, { 0.44, 0.44, 0.46, 1 }, "BACKGROUND", 1)
    r.ring:SetPoint("CENTER", r, "TOPLEFT", 12, -19)
    r.hole = Disc(r, 21, { 0.07, 0.07, 0.08, 1 }, "BACKGROUND", 2)
    r.hole:SetPoint("CENTER", r.ring, "CENTER")
    r.nb = UI():Text(r, "emph", C.chip)
    r.nb:SetJustifyH("CENTER")
    r.nb:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.check = r:CreateTexture(nil, "ARTWORK")
    r.check:SetSize(14, 14)
    r.check:SetPoint("CENTER", r.ring, "CENTER")
    r.check:SetTexture(CHECK)
    r.check:SetVertexColor(0.45, 0.9, 0.55)
    r.vline = Line(r, { 1, 1, 1, 0.12 }, "BACKGROUND")
    r.vline:SetWidth(1)
    r.t1 = UI():Text(r, "title", C.white)
    r.t1:SetPoint("TOPLEFT", 35, -9)
    r.when = UI():Text(r, "body", C.grey)
    r.when:SetJustifyH("RIGHT")
    r.when:SetPoint("TOPRIGHT", 0, -11)
    r.t2 = UI():Text(r, "body", C.desc)
    r.t2:SetPoint("TOPLEFT", 35, -28)
    r.rules = {}
    return r
end

-- Fills a stage row (w wide): number, name, when, the plain words and the rules; returns its height. i = "*": the
-- Always row (what runs the whole event): an infinity in its ring.
function Pg.FillStage(r, i, s, w, how, when, last)
    r:SetWidth(w)
    r.nb:SetText(i == "*" and "" or i)
    if not r.inf then
        r.inf = r:CreateTexture(nil, "ARTWORK")
        r.inf:SetSize(13, 13)
        r.inf:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    end
    r.inf:SetShown(i == "*")
    if i == "*" then H.Glyph(r.inf, "infinity", { 0.85, 0.85, 0.87, 0.9 }) end
    r.t1:SetText(s.name or "")
    r.when:SetText(when or "")
    r.glow:SetShown(how == "now")
    if how == "now" then
        r.ring:SetVertexColor(S:Color("GOLD"))
        r.hole:Hide()
        r.nb:SetTextColor(0.16, 0.11, 0)
        r.nb:SetShadowColor(0, 0, 0, 0)
        r.nb:Show()
        r.check:Hide()
    elseif how == "done" then
        r.ring:SetVertexColor(0.35, 0.86, 0.47, 0.9)
        r.hole:SetVertexColor(0.06, 0.14, 0.08, 1)
        r.hole:Show()
        r.nb:Hide()
        r.check:Show()
    else
        r.ring:SetVertexColor(0.44, 0.44, 0.46, 1)
        r.hole:SetVertexColor(0.07, 0.07, 0.08, 1)
        r.hole:Show()
        r.nb:SetTextColor(0.91, 0.91, 0.91)
        r.nb:SetShadowColor(0, 0, 0, 1)
        r.nb:Show()
        r.check:Hide()
    end
    local th = 0
    if s.text and s.text ~= "" then
        th = Wrap(r.t2, s.text, w - 35, 11)
        r.t2:Show()
    else
        r.t2:SetText("")
        r.t2:Hide()
    end
    local y = 28 + th + (th > 0 and 5 or 2)
    local x, ri, rows = 35, 0, 0
    for _, rule in ipairs(s.chips or s.rules or {}) do
        ri = ri + 1
        local c = Pool(r.rules, ri, function() return Pg.NewRule(r) end)
        c:Set(rule.g, rule.t, rule.look, rule.tip)
        local cw = c:GetWidth()
        if x > 35 and x + cw > w then
            x = 35
            rows = rows + 1
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", r, "TOPLEFT", x, -(y + rows * 22))
        c:Show()
        x = x + cw + 4
    end
    HideFrom(r.rules, ri + 1)
    local h = ri > 0 and (y + (rows + 1) * 22 - 4 + 9) or (28 + th + (th > 0 and 9 or 4))
    r:SetHeight(h)
    r.vline:ClearAllPoints()
    r.vline:SetPoint("TOP", r, "TOPLEFT", 12, -31)
    r.vline:SetPoint("BOTTOM", r, "BOTTOMLEFT", 12, -8)
    r.vline:SetShown(not last)
    return h
end

function Pg.NewReward(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(90, 120)
    c.big = H.Badge(c, 42)
    c.big:SetPoint("TOP", 0, -6)
    c.small = H.Badge(c, 36)
    c.small:SetPoint("TOP", 0, -6)
    c.place = UI():Text(c, "small", C.grey)
    c.place:SetJustifyH("CENTER")
    c.n = UI():Text(c, "emph", C.white)
    c.n:SetJustifyH("CENTER")
    c.s = UI():Text(c, "body", { 0.88, 0.77, 0.42 })
    c.s:SetJustifyH("CENTER")
    return c
end

-- A reward: its badge, where it goes ("1ST", "BIGGEST UPSET"), its name, its points and title. Returns its height.
-- Where a reward goes ("1ST", "MOST FINDS", "BIGGEST UPSET"), in its cell: smaller, else two lines. Its height.
function Pg.RewardLabel(c, rw, cellW)
    local _, ph = FitText(c.place, string.upper(rw.label ~= "" and rw.label or "badge"), cellW - 6, { 10, 9 })
    c.place:SetJustifyH("CENTER")
    return max(12, ph or 12)
end

-- labelH: the row's tallest label (its names line up under it).
function Pg.FillReward(c, rw, d, cellW, cols, labelH)
    local four = cols > 3
    local badge, other = four and c.small or c.big, four and c.big or c.small
    other:Hide()
    badge:SetBadge({ n = rw.b.n, i = rw.b.i, f = rw.b.f, ti = rw.b.ti, ev = d.name })
    local ph = Pg.RewardLabel(c, rw, cellW)
    ph = max(ph, labelH or 0)
    c.place:ClearAllPoints()
    c.place:SetPoint("TOP", badge, "BOTTOM", 0, -7)
    UI():SetTextSize(c.n, four and 11 or 12)
    local nh = Wrap(c.n, rw.b.n or "Badge", cellW - 6, four and 11 or 12)
    c.n:ClearAllPoints()
    c.n:SetPoint("TOP", badge, "BOTTOM", 0, -(7 + ph + 3))
    local sub = rw.pts and ("+" .. rw.pts) or nil
    if rw.b.ti and rw.b.ti ~= "" then sub = sub and (sub .. (four and ", title" or " and a title")) or "a title" end
    c.s:SetText(sub or "")
    c.s:ClearAllPoints()
    c.s:SetPoint("TOP", c.n, "TOP", 0, -nh - 1)
    c.s:SetShown(sub ~= nil)
    return 6 + badge:GetHeight() + 7 + ph + 3 + nh + (sub and 15 or 0) + 8
end


function Pg.NewEntrant(parent)
    local e = CreateFrame("Frame", nil, parent)
    e:SetSize(138, 24)
    e.face = H.Face(e, 17)
    e.face:SetPoint("LEFT", 0, 0)
    e.n = UI():Text(e, "body", C.white)
    e.n:SetPoint("LEFT", e.face, "RIGHT", 7, 0)
    e.sd = UI():Text(e, "body", C.dim, { font = NUM_FONT })
    e.sd:SetJustifyH("RIGHT")
    e.sd:SetPoint("RIGHT", 0, 0)
    return e
end

-- What each stage's "when" says: sign-up open / its close, the start, "after ..."; live: done / now / next.
function Pg.StageWhen(o, desc, st)
    local out, how = {}, {}
    local d = o.def
    local closes = Ev():ClosesAt(o)
    local cur
    if st then
        local _, i = B():Stage(d, st.stage)
        cur = i
    end
    local bracketStage
    for _, bid in ipairs(B():BlocksOf(d, "bracket")) do bracketStage = bracketStage or d.blocks[bid].stage end
    local signupStage
    for _, bid in ipairs(B():BlocksOf(d, "signup")) do signupStage = signupStage or d.blocks[bid].stage end
    local started = false
    -- (called off or its time long gone: nothing is open; a sign-up that closed before the start says so)
    local occState = Ev():OccState(o)
    local over = occState == "cancelled" or occState == "missed"
    local _, why = W.CanJoin(o)
    local closed = why == "closed"
    for i, s in ipairs(desc) do
        if over and not st then
            how[i] = "next"
            if s.id == signupStage then
                out[i] = ""
            elseif not started and (s.id == bracketStage or i == 1 or (i == 2 and not bracketStage)) then
                started = true
                out[i] = W.DayWord(o.at) .. " " .. W.Clock(o.at)
            else
                out[i] = desc[i - 1] and ("after " .. string.lower(desc[i - 1].name or "")) or ""
            end
        elseif closed and not st and s.id == signupStage then
            how[i], out[i] = "done", "closed " .. W.Clock(closes)
        elseif st then
            if cur and i < cur then
                how[i], out[i] = "done", "done"
            elseif cur and i == cur then
                how[i] = "now"
                local sub = EUI():StageSub(d, st) or W.TimeLeft(st)

                out[i] = "now" .. (sub and (" · " .. sub) or "")
            else
                how[i], out[i] = "next", (cur and i == cur + 1) and "next" or "later"
            end
        else
            if s.id == signupStage then
                how[i] = "now"
                out[i] = "Open now" .. (closes and (" · closes " .. W.DayWord(closes) .. " " .. W.Clock(closes)) or "")
            elseif not started and (s.id == bracketStage or i == 1 or (i == 2 and not bracketStage)) then
                started = true
                how[i], out[i] = "next", W.DayWord(o.at) .. " " .. W.Clock(o.at)
            else
                how[i] = "next"
                out[i] = desc[i - 1] and ("after " .. string.lower(desc[i - 1].name or "")) or ""
            end
        end
    end
    return out, how
end

-- The page's body for a calendar event (not over): the stages left, the rewards and the entrants right.
function Pg.FillBody(v, o, keys, st)
    local d = o.def
    local W0 = v.layout.bodyW
    local desc = B():Describe(d, { closesAt = Ev():ClosesAt(o) })
    for _, s in ipairs(desc) do s.chips = Pg.Chips(d, s) end
    -- what runs the whole event (the builder's Always): a row of its own after the stages, when it does something
    local always = B():DescribeStage(d, { id = "*", name = "Always" })
    always.chips = Pg.Chips(d, always)
    if #always.chips == 0 and (always.text or "") == "" then always = nil end
    -- the right column first: its height decides the scroll bar
    local rewards, extra = W.Rewards(d)
    local spots = W.Spots(d)
    -- (open seats only while one can still take them)
    local occState = Ev():OccState(o)
    local seats = #keys
    if (occState == "planned" and W.CanJoin(o)) or (occState == "live" and Pg.LiveSignupOpen(st)) then
        seats = max(#keys, spots or 0)
    end
    local nr = #rewards
    local cols = nr <= 3 and 3 or 4
    -- the rewards' cells first (their words wrap): the rows' heights
    local cellW = floor(RIGHT_W / cols)
    local rowH, cellH, labelH = {}, {}, {}
    -- (where each goes first: a row's names line up under its tallest label)
    for i = 1, nr do
        local c = Pool(v.rewards, i, function() return Pg.NewReward(v.content) end)
        local row = floor((i - 1) / cols) + 1
        labelH[row] = max(labelH[row] or 0, Pg.RewardLabel(c, rewards[i], cellW))
    end
    for i = 1, max(nr, #v.rewards) do
        local c = Pool(v.rewards, i, function() return Pg.NewReward(v.content) end)
        local rw = rewards[i]
        if rw then
            local row = floor((i - 1) / cols) + 1
            cellH[i] = Pg.FillReward(c, rw, d, cellW, cols, labelH[row])
            rowH[row] = max(rowH[row] or 0, cellH[i])
        else
            c:Hide()
        end
    end
    local rh = 0
    for _, h in ipairs(rowH) do rh = rh + h end
    if nr == 0 then rh = 26 end
    local entH = ceil(seats / 2) * 24
    -- (where it is: a map of its places, when it has any)
    local wh = Pg.Places(d, Ev():MeetOf(o))
    local whereH = wh and (28 + WHERE_H + 8) or 0
    local rightH = 28 + rh + 8 + whereH + 28 + max(24, entH)
    local avail = H.BodyH(v.layout)
    -- the left column's height needs its width: measure with the full width first
    local lw = W0 - RIGHT_W - COL_GAP
    local cw = W0
    local function layoutLeft(width)
        v.lsect:ClearAllPoints()
        v.lsect:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, 0)
        v.lsect:SetWidth(width)
        v.lsect:Set("How it runs")
        local when, how = Pg.StageWhen(o, desc, st)
        local y = 28
        for i, s in ipairs(desc) do
            local r = Pool(v.stages, i, function() return Pg.NewStage(v.content) end)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
            local h = Pg.FillStage(r, i, s, width, how[i], when[i], i == #desc)
            r:Show()
            y = y + h
        end
        local n = #desc
        if always then
            n = n + 1
            local r = Pool(v.stages, n, function() return Pg.NewStage(v.content) end)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
            y = y + Pg.FillStage(r, "*", always, width, "always", "the whole event", true)
            r:Show()
        end
        HideFrom(v.stages, n + 1)
        return y
    end
    local leftH = layoutLeft(lw)
    if max(leftH, rightH) > avail then
        cw = W0 - 12
        lw = cw - RIGHT_W - COL_GAP
        leftH = layoutLeft(lw)
    end
    v.scroll:SetWidth(cw)
    v.content:SetWidth(cw)
    -- rewards
    local rx = cw - RIGHT_W
    v.rsect:ClearAllPoints()
    v.rsect:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx, 0)
    v.rsect:SetWidth(RIGHT_W)
    -- (the season points no badge goes with at the right; an event that isn't ranked gives none of it)
    local more = W.ExtraText(extra)
    local right = ((#rewards > 0 or more) and not o.ranked) and "if it were ranked" or (more and ("plus " .. more))
    v.rsect:Set("Rewards", right)
    -- (a short row of rewards sits in the middle of the column)
    local ry = 28
    for i = 1, nr do
        local c = v.rewards[i]
        local col, row = (i - 1) % cols, floor((i - 1) / cols) + 1
        local inRow = min(cols, nr - (row - 1) * cols)
        local x0 = floor((RIGHT_W - inRow * cellW) / 2)
        c:SetSize(cellW, rowH[row])
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx + x0 + col * cellW, -ry)
        c:Show()
        if col == cols - 1 or i == nr then ry = ry + rowH[row] end
    end
    v.noRewards = v.noRewards or UI():Text(v.content, "body", C.grey)
    v.noRewards:SetShown(nr == 0)
    v.noRewards:ClearAllPoints()
    v.noRewards:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx + 2, -32)
    v.noRewards:SetText(more and "No badges: season points only." or "No badges: it's for the fun of it.")
    -- where (the map), then the entrants
    if wh then
        local wy = 28 + rh + 8
        v.wsect:ClearAllPoints()
        v.wsect:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx, -wy)
        v.wsect:SetWidth(RIGHT_W)
        local mp = wh.meet and B():Definition(d, "places", wh.meet)
        v.wsect:Set("Where", mp and ("meet at " .. (mp.n or "the place")) or nil)
        Pg.FillWhere(v, o, wh, rx, wy + 28)
    else
        v.wsect:Hide()
        if v.wmap then v.wmap:Hide() end
    end
    local ey = 28 + rh + 8 + whereH
    v.esect:ClearAllPoints()
    v.esect:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx, -ey)
    v.esect:SetWidth(RIGHT_W)
    local noun = W.Noun(d, 2)
    v.esect:Set(noun:sub(1, 1):upper() .. noun:sub(2), W.SeedText(d))
    local seeded = W.Has(d, "bracket")
    -- (a live event without Matches: its first score on the board next to each name)
    local liveScore
    if not seeded and st and st.phase == "live" and type(st.scores) == "table" then
        for _, sc in ipairs(B():Defs(d, "scores", true)) do
            if sc.board and not liveScore then
                liveScore = { sc = sc, rows = type(st.scores[sc.id]) == "table" and st.scores[sc.id] or {} }
            end
        end
    end
    local colW = floor((RIGHT_W - 10) / 2)
    for i = 1, max(seats, #v.ents) do
        local e = Pool(v.ents, i, function() return Pg.NewEntrant(v.content) end)
        if i <= seats then
            local col, row = (i - 1) % 2, floor((i - 1) / 2)
            e:SetWidth(colW)
            e:ClearAllPoints()
            e:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx + col * (colW + 10), -(ey + 28 + row * 24))
            local k = keys[i]
            if k then
                e.face:Set(k)
                e.n:SetText(Name(k))
                -- (a seed in Matches; while a score chase runs, the player's score; else nothing to number)
                local right
                if seeded then
                    right = "#" .. i
                elseif liveScore and liveScore.rows[k] ~= nil then
                    right = W.ScoreText(liveScore.sc, liveScore.rows[k])
                end
                e.sd:SetText(right or "")
                e.sd:SetShown(right ~= nil)
            else
                e.face:SetEmpty()
                e.n:SetText(S:Wrap("DIM", "Open seat"))
                e.sd:Hide()
            end
            e:Show()
        else
            e:Hide()
        end
    end
    if seats == 0 then
        v.noEnt = v.noEnt or UI():Text(v.content, "body", C.grey)
        v.noEnt:ClearAllPoints()
        v.noEnt:SetPoint("TOPLEFT", v.content, "TOPLEFT", rx + 2, -(ey + 32))
        v.noEnt:SetText(occState == "planned" and "Nobody yet." or "Nobody signed up.")
        v.noEnt:Show()
    elseif v.noEnt then
        v.noEnt:Hide()
    end
    v.content:SetHeight(max(leftH, rightH) + 4)
end

-- The banner of a calendar event's page.
function Pg.FillBanner(v, o, keys, st)
    local b = v.ban
    local d = o.def
    local w = v.layout.innerW
    local occState = Ev():OccState(o)
    local host = Ev():HostOf(o)
    local me = Me()
    local pills = {}
    if occState == "live" then pills[#pills + 1] = { "Live", "live" } end
    if occState == "cancelled" then pills[#pills + 1] = { "Cancelled", "mute" } end
    if o.ranked then pills[#pills + 1] = { "Ranked", "rank" } end
    local meta = {}
    local where = o.where and o.where ~= "" and o.where or nil
    if occState == "live" then
        meta[1] = "Started " .. EUI():Relative(st and st.t0 or o.at)
    elseif occState == "cancelled" then
        -- (why: at the bottom right, it may be long)
        meta[1] = W.Day(o.at) .. " · " .. W.Clock(o.at)
    else
        meta[1] = W.Day(o.at)
        meta[2] = W.Clock(o.at)
    end
    -- (where everyone meets, for an event with places: its zone and coordinates; else the host's own words)
    local meetId = Ev():MeetOf(o)
    local mp = meetId and B():Definition(d, "places", meetId)
    if mp then
        local zone, xy = EUI():PlaceZone(mp), EUI():Coords(mp, 0)
        local at = (zone and xy) and (zone .. " " .. xy) or zone or xy
        meta[#meta + 1] = "Meet at " .. (mp.n or "the place") .. (at and (" · " .. at) or "")
    elseif where then
        meta[#meta + 1] = where
    end
    meta[#meta + 1] = "hosted by " .. Name(host)
    local k = o.ranked and Ev():GetReview(o.dk)
    if k and k.ok then meta[#meta + 1] = "reviewed by " .. Name(k.by) end
    H.BeginBanner(b)
    H.BannerHead(b, w, d.art, d.icon, d.name, pills, tconcat(meta, " · "), 0.58)
    H.BannerIcons(b, true, A.OccRef(o.id))
    b.kindsDef = d
    local spots = W.Spots(d)
    if occState == "live" then
        H.SetProg(b, d, st, EUI():StageSub(d, st))
    else
        b.prog:Hide()
        H.BannerMeter(b, keys, spots, W.Noun(d, spots or #keys))
    end
    local signed = Ev():IsSignedUp(o.id)
    local full = spots and #Ev():GetSignups(o.id) >= spots
    if occState == "live" then
        H.BannerAction(b, "btn", "Watch", "primary", function() A.Watch(o.id) end)
        if Pg.LiveSignupOpen(st) and not signed and not full then
            H.BannerAction(b, "btn2", "Join", "secondary", function() A.Join(o.id, true) end)
        end
    elseif occState == "planned" then
        local closes = Ev():ClosesAt(o)
        if closes and closes > ns.Util.Now() then
            H.BannerChip(b, "track", "Sign-up closes " .. (W.DayWord(closes) == "Today" and "" or
                (W.DayWord(closes) .. " ")) .. W.Clock(closes))
        end
        local starting = false
        if host == me then
            local ok, why = Live():CanStart(o.id)
            if ok then
                H.BannerAction(b, "btn", "Start", "primary", function() Pg.Start(o.id) end)
                starting = true
            elseif why and why:find("pieces") then
                H.BannerChip(b, "track", "Fix it in the builder", { icon = WARN, tip = { "It can't start yet", why } })
            end
        end
        -- Start is the host's main action; everyone else's is Join (or Leave, once in)
        local target = starting and "btn2" or "btn"
        local can, why = W.CanJoin(o)
        if signed then
            H.BannerAction(b, target, "Leave", "secondary", function() A.Join(o.id, false) end)
        elseif why == "full" then
            b.note:SetText("Full: " .. spots .. " of " .. spots)
            b.note:Show()
        elseif not can then
            b.note:SetText("Sign-up closed")
            b.note:Show()
        else
            H.BannerAction(b, target, "Join", starting and "secondary" or "primary", function() A.Join(o.id, true) end)
        end
    elseif occState == "missed" then
        b.note:SetText("It didn't run")
        b.note:Show()
    elseif occState == "cancelled" and o.cancel ~= "Cancelled" then
        H.BannerWhy(b, o.cancel, w - 14 - 330 - 24)
    end
    -- the way to where everyone meets (the tracker's arrow and the minimap's ring, for me only)
    if mp and (occState == "planned" or occState == "live") then
        H.BannerAction(b, "btn3", "Show the way", "secondary", function() EUI():ShowTheWay(o.id, meetId, d) end,
            { "Show the way", "An arrow under your minimap and a ring on it point you to " .. (mp.n or "the place")
            .. ", where everyone meets. Only you see it." })
    end
    H.EndBanner(b)
end

-- Is a live run's sign-up still open (one its host closes)?
function Pg.LiveSignupOpen(st)
    for _, blk in pairs(st and st.blocks or {}) do
        if blk.kind == "signup" and blk.open then return true end
    end
    return false
end

function Pg.Start(occId)
    local ok, why = Live():Start(occId)
    if not ok then
        if why then ns:Print("%s", why) end
        return
    end
    A.Watch(occId)
    EventsUI:RequestRefresh()
end

function Pg.Fill(v)
    local id = state.occ
    local o = id and Ev():GetOcc(id)
    local r = id and Ev():GetResult(id)
    if r or (o and Ev():OccState(o) == "done") then
        v.mode = "results"
        -- (the scroll bar is the page's, not the scroll frame's: it goes too)
        v.scroll:Hide()
        v.scroll.ScrollBar:Hide()
        v.rscroll:Show()
        v.res:Show()
        Pg.FillResults(v, W.DemoDress(r), o)
        return true
    end
    if not o then return false end
    v.mode = "event"
    v.res:Hide()
    v.rscroll:Hide()
    v.rscroll.ScrollBar:Hide()
    v.scroll:Show()
    local keys, st = W.Entrants(o)
    Pg.FillBanner(v, o, keys, st)
    Pg.FillBody(v, o, keys, st)
    v.scroll.ScrollBar:Update()
    return true
end

---------------------------------------------------------------------------
-- Results (shot 11): the podium, the awards, the night; the scores' tables and who had each tag at the end
---------------------------------------------------------------------------

local POD_H, AW_W, RECAP_Y = 196, 296, 208
local PED = { { "p2", 44, 46, { 0.86, 0.89, 0.95 } }, { "p1", 58, 72, C.gold }, { "p3", 40, 30, { 0.86, 0.56, 0.32 } } }
local TROW_RH, TAG_RH = 22, 26     -- a score table's row, a tag's row
local TABLE_MIN, MOM_MIN = 220, 250

function Pg.CreateResults(v)
    -- (its own scroll frame: long score tables scroll; its bar is the page's, as the event page's)
    local L = v.layout
    v.rscroll = UI():CreateScrollFrame(L.body)
    v.rscroll:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
    v.rscroll:SetPoint("BOTTOMLEFT", L.body, "BOTTOMLEFT", 0, 0)
    v.rscroll:SetWidth(L.bodyW)
    v.rscroll:Hide()
    local f = CreateFrame("Frame", nil, v.rscroll)
    f:SetSize(L.bodyW, H.BodyH(L))
    v.rscroll:SetScrollChild(f)
    f.stand = CreateFrame("Frame", nil, f)
    f.stand:SetPoint("TOPLEFT", 0, 0)
    f.stand:SetSize(400, POD_H)
    f.peds = {}
    for i, def in ipairs(PED) do
        local p = CreateFrame("Frame", nil, f.stand)
        p:SetSize(112, POD_H - 6)
        p.blk = CreateFrame("Frame", nil, p)
        p.blk:SetSize(112, def[3])
        p.blk:SetPoint("BOTTOM", 0, 0)
        p.blk.fill = p.blk:CreateTexture(nil, "BACKGROUND")
        p.blk.fill:SetAllPoints()
        local c = def[4]
        UI():Gradient(p.blk.fill, "VERTICAL", { c[1], c[2], c[3], 0.03 }, { c[1], c[2], c[3], i == 2 and 0.22 or 0.19 })
        p.blk.top = Line(p.blk, { c[1], c[2], c[3], 0.75 })
        p.blk.top:SetHeight(1)
        p.blk.top:SetPoint("TOPLEFT")
        p.blk.top:SetPoint("TOPRIGHT")
        p.blk.n = UI():Text(p.blk, 22, i == 2 and C.pts or { 1, 1, 1, 0.85 }, { font = NUM_FONT })
        p.blk.n:SetJustifyH("CENTER")
        p.blk.n:SetPoint("TOP", 0, -8)
        p.blk.n:SetText(i == 2 and "1" or (i == 1 and "2" or "3"))
        p.sb = UI():Text(p, "body", C.grey)
        p.sb:SetJustifyH("CENTER")
        p.sb:SetPoint("BOTTOM", p.blk, "TOP", 0, 8)
        p.nm = UI():Text(p, "title", C.white)
        p.nm:SetJustifyH("CENTER")
        p.nm:SetPoint("BOTTOM", p.sb, "TOP", 0, 2)
        p.face = H.Face(p, def[2])
        p.face:SetPoint("BOTTOM", p.nm, "TOP", 0, 8)
        p.face.ring:SetSize(def[2] + 4, def[2] + 4)
        if i == 2 then
            p.glows = {}
            for g = 1, 3 do
                local t = Disc(p.face, def[2] + 6 + g * 7, S:WithAlpha("GOLD", 0.16 - g * 0.04), "BACKGROUND", -g)
                t:SetPoint("CENTER")
                p.glows[g] = t
            end
            p.gold = Disc(p.face, def[2] + 6, S:WithAlpha("GOLD", 0.92), "BACKGROUND", 0)
            p.gold:SetPoint("CENTER")
        end
        f.peds[i] = p
    end
    f.aw = CreateFrame("Frame", nil, f)
    f.aw:SetPoint("TOPRIGHT", 0, 0)
    f.aw:SetSize(AW_W, POD_H)
    f.awSect = H.Sect(f.aw)
    f.awSect:SetPoint("TOPLEFT")
    f.awSect:SetPoint("TOPRIGHT")
    f.awards = {}
    -- the night: moments, the last four, the numbers
    f.mom = CreateFrame("Frame", nil, f)
    f.mom:SetSize(300, 170)
    f.momSect = H.Sect(f.mom)
    f.momSect:SetPoint("TOPLEFT")
    f.momSect:SetPoint("TOPRIGHT")
    f.moments = {}
    f.l4 = CreateFrame("Frame", nil, f)
    f.l4:SetSize(300, 170)
    f.l4Sect = H.Sect(f.l4)
    f.l4Sect:SetPoint("TOPLEFT")
    f.l4Sect:SetPoint("TOPRIGHT")
    f.l4.full = H.Link(f.l4Sect, "Full bracket", function() if state.occ then A.Watch(state.occ) end end)
    f.l4.box = CreateFrame("Frame", nil, f.l4)
    f.l4.box:SetPoint("TOPLEFT", 0, -34)
    f.l4.box:SetSize(300, 124)
    f.l4.matches = {}
    f.l4.lines = {}
    for i = 1, 6 do
        f.l4.lines[i] = Line(f.l4.box, { 1, 1, 1, 0.34 })
    end
    f.num = CreateFrame("Frame", nil, f)
    f.num:SetSize(150, 170)
    f.numSect = H.Sect(f.num)
    f.numSect:SetPoint("TOPLEFT")
    f.numSect:SetPoint("TOPRIGHT")
    f.nums = {}
    -- the scores' tables (each score on the board, ranked) and who had each tag at the end
    f.tables = {}
    f.tags = CreateFrame("Frame", nil, f)
    f.tags:SetSize(400, 60)
    f.tagSect = H.Sect(f.tags)
    f.tagSect:SetPoint("TOPLEFT")
    f.tagSect:SetPoint("TOPRIGHT")
    f.tagRows = {}
    f.nobody = UI():Text(f, "body", C.grey)
    return f
end

function Pg.NewAward(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(AW_W, 44)
    UI():DecorateRow(r, { rule = true })
    r.line = r.dzRule
    r.badge = H.Badge(r, 30)
    r.badge:SetPoint("LEFT", -1, 0)
    r.face = H.Face(r, 30)
    r.face:SetPoint("LEFT", 4, 0)
    r.l1 = UI():Text(r, "emph", C.white)
    r.l1:SetPoint("BOTTOMLEFT", r, "LEFT", 50, 1)
    r.l2 = UI():Text(r, "body", C.grey)
    r.l2:SetPoint("TOPLEFT", r, "LEFT", 50, -2)
    r.pts = UI():Text(r, 14, C.pts, { font = NUM_FONT })
    r.pts:SetJustifyH("RIGHT")
    r.pts:SetPoint("RIGHT", -2, 0)
    return r
end

function Pg.NewMoment(parent)
    local m = CreateFrame("Frame", nil, parent)
    m:SetSize(200, 30)
    m.icon = m:CreateTexture(nil, "ARTWORK")
    m.icon:SetSize(16, 16)
    m.icon:SetPoint("TOPLEFT", 0, 0)
    m.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    m.fs = UI():Text(m, "body", C.meta)
    m.fs:SetPoint("TOPLEFT", 24, 0)
    m.t2 = UI():Text(m, "small", C.dim)
    return m
end

-- A match box of the last four: two players (seed, face, name, games won), the winner lit.
local MATCH_W = 136
function Pg.NewMatch(parent)
    local m = UI():CreateCard(parent, { tone = "card", width = MATCH_W, height = 39 })
    m.sep = Line(m, "HAIRLINE")
    m.sep:SetHeight(1)
    m.sep:SetPoint("LEFT", 1, 0)
    m.sep:SetPoint("RIGHT", -1, 0)
    m.p = {}
    for i = 1, 2 do
        local p = CreateFrame("Frame", nil, m)
        p:SetSize(MATCH_W, 19)
        p:SetPoint("TOPLEFT", 0, -(i - 1) * 20)
        p.sd = UI():Text(p, "small", { 0.37, 0.37, 0.4 }, { font = NUM_FONT })
        p.sd:SetJustifyH("RIGHT")
        p.sd:SetPoint("RIGHT", p, "LEFT", 15, 0)
        p.face = H.Face(p, 13)
        p.face:SetPoint("LEFT", 19, 0)
        p.n = UI():Text(p, "body", C.grey)
        p.n:SetPoint("LEFT", p.face, "RIGHT", 5, 0)
        p.sc = UI():Text(p, "emph", { 0.47, 0.47, 0.49 }, { font = NUM_FONT })
        p.sc:SetJustifyH("RIGHT")
        p.sc:SetPoint("RIGHT", -6, 0)
        m.p[i] = p
    end
    function m:Set(x)
        for i = 1, 2 do
            local p = self.p[i]
            local key = i == 1 and x.a or x.b
            local won = key and key == x.win
            p.sd:SetText(i == 1 and (x.sa or "") or (x.sb or ""))
            p.n:ClearAllPoints()
            p.n:SetPoint("LEFT", p.face, "RIGHT", 5, 0)
            if key then
                p.face:Set(key, not won)
                p.face.noTip = false
                -- (a long name: a size or two smaller between the face and the score; else in the face's place)
                local text = IsMe(key) and S:Wrap(won and "YOU" or "SUB", "You")
                    or S:Wrap(won and "TEXT" or "SUB", EUI():Plain(key))
                if not FitText(p.n, text, MATCH_W - 37 - 18, { 11, 10, 9 }, false) then
                    p.face:Hide()
                    p.n:ClearAllPoints()
                    p.n:SetPoint("LEFT", p, "LEFT", 19, 0)
                    FitText(p.n, text, MATCH_W - 19 - 18, { 10, 9 })
                end
            else
                p.face:SetEmpty()
                FitText(p.n, S:Wrap("DIM", "-"), MATCH_W - 37 - 18, 11)
            end
            p.sc:SetText(i == 1 and (x.wa or 0) or (x.wb or 0))
            p.sc:SetTextColor(S:Color(won and C.white or { 0.47, 0.47, 0.49 }))
        end
        self:Show()
    end
    return m
end

-- A score's table on the results: its name and what wins, then every player ranked (place, face, name, the
-- number in the score's look); mine lit.
function Pg.NewTable(parent)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(240, 60)
    t.sect = H.Sect(t)
    t.sect:SetPoint("TOPLEFT")
    t.sect:SetPoint("TOPRIGHT")
    t.rows = {}
    t.none = UI():Text(t, "body", C.grey)
    t.none:SetPoint("TOPLEFT", 2, -34)
    t.none:SetText("Nobody scored.")
    return t
end

function Pg.NewTableRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(240, TROW_RH)
    UI():DecorateRow(r, { selectable = true, rule = true })
    r.bg, r.bar, r.line = r.dzSelFill, r.dzSelBar, r.dzRule
    r.rk = UI():Text(r, "emph", C.grey, { font = NUM_FONT })
    r.rk:SetJustifyH("RIGHT")
    r.rk:SetPoint("RIGHT", r, "LEFT", 22, 0)
    r.face = H.Face(r, 16)
    r.face:SetPoint("LEFT", 30, 0)
    r.n = UI():Text(r, "body", C.white)
    r.n:SetPoint("LEFT", r.face, "RIGHT", 7, 0)
    r.v = UI():Text(r, "title", { 0.93, 0.93, 0.93 }, { font = NUM_FONT })
    r.v:SetJustifyH("RIGHT")
    r.v:SetPoint("RIGHT", -6, 0)
    return r
end

-- Fills a score's table w wide; returns its height.
function Pg.FillTable(t, s, w)
    t:SetWidth(w)
    t.sect:Set(s.n or "Score", W.Way(s) .. " wins")
    local rows = W.RankRows(s)
    local y = 28
    for i = 1, max(#rows, #t.rows) do
        local x = rows[i]
        if x and i <= 40 then
            local r = Pool(t.rows, i, function() return Pg.NewTableRow(t) end)
            r:SetWidth(w)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", t, "TOPLEFT", 0, -y)
            r:SetSelected(IsMe(x.key))
            r.rk:SetText(x.place)
            r.rk:SetTextColor(S:Color(x.place <= 3 and C.gold or C.grey))
            r.face:Set(x.key)
            r.v:SetText(W.ScoreText(s, x.n))
            -- (a long name: a point smaller between the face and the number; never cut)
            FitText(r.n, Name(x.key), w - 53 - NatW(r.v) - 14, { 11, 10, 9 })
            r:Show()
            y = y + TROW_RH
        elseif t.rows[i] then
            t.rows[i]:Hide()
        end
    end
    t.none:SetShown(#rows == 0)
    if #rows == 0 then y = y + 26 end
    t:SetHeight(y)
    t:Show()
    return y
end

-- A tag's row at the end: its colour and name, how many had it of how many played, and who (a tag only some see:
-- just the count, and me when I had it).
function Pg.NewTagRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(300, TAG_RH)
    r.dot = Disc(r, 9, C.white, "ARTWORK")
    r.dot:SetPoint("CENTER", r, "LEFT", 6, 0)
    r.n = UI():Text(r, "emph", C.white)
    r.n:SetPoint("LEFT", 18, 0)
    r.c = UI():Text(r, "body", C.grey)
    r.c:SetPoint("LEFT", r.n, "RIGHT", 8, 0)
    r.faces = {}
    r.more = UI():Text(r, "body", C.grey)
    return r
end

function Pg.FillTagRow(r, t, n, w, host)
    r:SetWidth(w)
    local k = B():TagColor(t.c)
    r.dot:SetVertexColor(k[1], k[2], k[3], 1)
    r.n:SetText(t.n or "Tag")
    local keys = type(t.k) == "table" and t.k or {}
    r.c:SetText(#keys .. ((n or 0) > 0 and (" of " .. n) or ""))
    -- who: everyone when the tag is everyone's to see (or the host's and I hosted it), else only me
    local show = {}
    local all = (t.shown or "all") == "all" or (t.shown == "host" and host)
    for _, key in ipairs(keys) do
        if all or IsMe(key) then show[#show + 1] = key end
    end
    local x = 18 + NatW(r.n) + 8 + NatW(r.c) + 12
    local fit = max(0, floor((w - x - 30) / 18))
    for i = 1, max(#show, #r.faces) do
        local f = Pool(r.faces, i, function() return H.Face(r, 15) end)
        if show[i] and i <= fit then
            f:Set(show[i])
            f:ClearAllPoints()
            f:SetPoint("LEFT", r, "LEFT", x + (i - 1) * 18, 0)
            f:Show()
        else
            f:Hide()
        end
    end
    local left = #show - min(#show, fit)
    r.more:SetShown(left > 0)
    if left > 0 then
        r.more:SetText("+" .. left)
        r.more:ClearAllPoints()
        r.more:SetPoint("LEFT", r, "LEFT", x + fit * 18 + 2, 0)
    end
    r:Show()
end

-- The line under a placing on the podium: "won the final 3-2", "lost the final 2-3", "won the bronze 2-1"; by a
-- score: "31 Fish", "Time 4:01".
function W.PodiumLine(r, key, place, sc)
    if sc then
        local n = sc.v and sc.v[key]
        if n ~= nil then return W.ScoreLine(sc, n) end
    end
    for _, m in ipairs(r.last4 or {}) do
        if (m.final and (place == 1 or place == 2)) or (m.bronze and place == 3) then
            if m.a == key or m.b == key then
                local mine, theirs = (m.a == key) and m.wa or m.wb, (m.a == key) and m.wb or m.wa
                return (m.win == key and "won the " or "lost the ") .. (m.bronze and "bronze " or "final ") .. mine .. "-" .. theirs
            end
        end
    end
    return place == 1 and "champion" or (place == 2 and "runner-up" or "third place")
end

-- A result's score table by its id (nil: none).
function W.ResultScore(r, sid)
    for _, s in ipairs(sid and r.scores or {}) do
        if s.id == sid then return s end
    end
    return nil
end

-- An award's second line: the title it gives, how the final went, whom the bronze was won against; for a badge a
-- score decides, the player's score ("31 Fish").
function W.AwardLine(r, a, reward)
    if a.ti and a.ti ~= "" then return "and the title \"" .. a.ti .. "\"" end
    for _, m in ipairs(r.last4 or {}) do
        if (m.a == a.p or m.b == a.p) and (m.final or m.bronze) then
            local mine, theirs = (m.a == a.p) and m.wa or m.wb, (m.a == a.p) and m.wb or m.wa
            local other = (m.a == a.p) and m.b or m.a
            if m.final then
                return (m.win == a.p and "won " or "lost ") .. mine .. "-" .. theirs .. " in the final"
            end
            if m.win == a.p then return "beat " .. EUI():Plain(other) .. " for bronze" end
        end
    end
    local sc = reward and W.ResultScore(r, reward.sid)
    if sc and sc.v and sc.v[a.p] ~= nil then return W.ScoreLine(sc, sc.v[a.p]) end
    if reward and reward.label and reward.label ~= "" and not reward.label:find("^%d") then
        return string.lower(reward.label)
    end
    return ""
end

function Pg.ResultsMenu(owner, occId)
    local entries = {}
    if Live() and Live():GetState(occId) then
        local o = Ev():GetOcc(occId)
        local matches = o and W.Has(o.def, "bracket")
        entries[#entries + 1] = { icon = matches and "bracket" or "eye", text = "Board", tip = matches
            and "Opens the live board on the final bracket." or "Opens the live board as the event ended.",
            fn = function() A.Watch(occId) end }
    end
    if W.CanRemove() then
        entries[#entries + 1] = { icon = "trash", text = "Remove", danger = true, tip = "Removes these results for "
            .. "everyone, with the season points and badges they gave.", fn = function() A.RemoveResult(occId) end }
    end
    if #entries > 0 then H.Menu(owner, entries) end
end

-- The result's tables of the scores on the board (its event's board flags; all of them when the event is gone).
function W.BoardScores(r, def)
    local out = {}
    for _, s in ipairs(r.scores or {}) do
        local sc = def and B():Definition(def, "scores", s.id)
        if not def or not sc or sc.board then out[#out + 1] = s end
    end
    return out
end

-- The moments column (up to n), x / y in the results frame, w wide: its height.
function Pg.LayMoments(f, r, moments, x, y, w, n)
    f.mom:ClearAllPoints()
    f.mom:SetPoint("TOPLEFT", f, "TOPLEFT", x, -y)
    f.mom:SetWidth(w)
    f.mom:SetShown(#moments > 0)
    f.momSect:Set("Moments")
    -- (the players named in them in their class colours, me in blue: the mockup's moments)
    local keys, seen = {}, {}
    local function add(k) if type(k) == "string" and not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
    add(r.champ); add(r.second); add(r.third)
    for k in pairs(type(r.points) == "table" and r.points or {}) do add(k) end
    for k in pairs(type(r.mw) == "table" and r.mw or {}) do add(k) end
    for _, g in ipairs(type(r.last4) == "table" and r.last4 or {}) do add(g.a); add(g.b) end
    local H2 = ns.EventBoard and ns.EventBoard.H
    local my = 30
    for i = 1, max(#moments, #f.moments) do
        local m = Pool(f.moments, i, function() return Pg.NewMoment(f.mom) end)
        local x2 = moments[i]
        if x2 and i <= n then
            m:SetWidth(w)
            m:ClearAllPoints()
            m:SetPoint("TOPLEFT", f.mom, "TOPLEFT", 0, -my)
            m.icon:SetTexture(x2.i or r.icon or "Interface\\Icons\\INV_Misc_Note_01")
            local text = x2.text or ""
            if H2 and H2.ColorNames then
                text = H2.ColorNames(text, keys):gsub("%f[%w]you%f[^%w]", S:Wrap("YOU", "you"))
            end
            local th = Wrap(m.fs, text, w - 24, 11)
            m.t2:ClearAllPoints()
            m.t2:SetPoint("TOPLEFT", m.fs, "TOPLEFT", 0, -th)
            m.t2:SetText(x2.at and W.Clock(x2.at) or "")
            m:SetHeight(th + 12)
            m:Show()
            my = my + th + 12 + 8
        else
            m:Hide()
        end
    end
    f.mom:SetHeight(my)
    return #moments > 0 and my or 0
end

function Pg.FillResults(v, r, o)
    local f = v.res
    local b = v.ban
    local w = v.layout.bodyW
    local def = (o and o.def) or W.DefOfResult(r)
    local host = (r.hosts and r.hosts[1]) or r.by
    local meta = { W.Day(r.at) }
    if (r.n or 0) > 0 then meta[#meta + 1] = r.n .. " " .. W.Noun(def, r.n) end
    if r.t1 and r.t1 > r.at then meta[#meta + 1] = W.Span(r.t1 - r.at) end
    meta[#meta + 1] = "hosted by " .. Name(host)
    local pills = { { r.cancel and "Cancelled" or ("Ended " .. W.Clock(r.t1 or r.at)), "ended" } }
    H.BeginBanner(b)
    H.BannerHead(b, w, r.art, r.icon, r.name, pills, tconcat(meta, " · "), 0.6)
    local canMore = (Live() and Live():GetState(r.id)) or W.CanRemove()
    -- (no share icon here: Share results is the page's action)
    H.BannerIcons(b, canMore and true or false, nil)
    local ref = A.OccRef(r.id)
    b.ref = ref
    if ref then
        H.BannerAction(b, "shareText", "Share results", "secondary", function(self)
            if IsShiftKeyDown() and ns.Share and ns.Share.PutInChat then
                ns.Share:PutInChat(ref)
            elseif ns.ShareWindow and ns.ShareWindow.Open then
                ns.ShareWindow:Open(ref, self)
            end
        end, { "Share results", { "Posts a link to these results in chat: the podium, the awards, the night.",
            { "Shift-click: into your chat box", "SUB" } } })
    end
    b.kindsDef = def
    if def then
        H.SetProg(b, def, nil, nil, true)
    else
        b.prog:Hide()
    end
    -- why it was called off (the pill already says it was)
    H.BannerWhy(b, r.cancel ~= "Cancelled" and r.cancel or nil, floor(w * 0.45))
    H.EndBanner(b)
    -- what it has: Matches (the podium from them, the last four), else the placings of its first score on the board
    -- (the run's own: EventEngine's Result); the tables of its scores; who had each tag at the end
    local matches = (def and W.Has(def, "bracket")) or #(r.last4 or {}) > 0
    local boards = W.BoardScores(r, def)
    local by = (not matches) and boards[1] or nil
    local champ, second, third = r.champ, r.second, r.third
    if by and not champ then
        local rows = W.RankRows(by)
        champ, second, third = rows[1] and rows[1].key, rows[2] and rows[2].key, rows[3] and rows[3].key
    end
    local placed = { second, champ, third }
    local placeOf = { 2, 1, 3 }
    local anyPlaced = (champ or second or third) ~= nil
    -- awards
    local rewards, extra = W.Rewards(def)
    local rows = {}
    if r.ranked then
        for _, a in ipairs(r.badges or {}) do
            local rw
            for _, x in ipairs(rewards) do
                if x.b.n == a.n then rw = x end
            end
            rows[#rows + 1] = { badge = a, key = a.p, title = a.n, l2 = W.AwardLine(r, a, rw), pts = rw and rw.pts }
        end
    end
    if #rows == 0 and not matches and #boards > 1 then
        -- (no badges, several scores: who leads each, "Most Finds", "Longest Hidden")
        for _, s in ipairs(boards) do
            local rr = W.RankRows(s)
            local top = rr[1]
            if top and #rows < 4 then
                local tied = {}
                for i = 2, #rr do if rr[i].place == 1 then tied[#tied + 1] = rr[i].key end end
                local l2 = W.ScoreLine(s, top.n)
                if #tied > 0 then
                    l2 = l2 .. ", tied with " .. EUI():Plain(tied[1]) .. (#tied > 1 and (" and " .. (#tied - 1) .. " more")
                        or "")
                end
                local title = W.Leader(s)
                rows[#rows + 1] = { key = top.key, title = title:gsub("^%l", string.upper), l2 = l2 }
            end
        end
    elseif #rows == 0 then
        for i, key in ipairs({ champ, second, third }) do
            if key then
                rows[#rows + 1] = { key = key, title = ({ "Champion", "Runner-up", "Third place" })[i],
                    l2 = W.PodiumLine(r, key, i, by) }
            end
        end
    end
    local hasTop = anyPlaced or #rows > 0
    -- the night: moments, the last four, the numbers (each only when the result has it)
    local moments = {}
    for _, m in ipairs(r.moments or {}) do moments[#moments + 1] = m end
    tsort(moments, function(a, c) return (a.at or 0) > (c.at or 0) end)
    local semis, final = {}, nil
    for _, m in ipairs(r.last4 or {}) do
        if m.final then final = m elseif not m.bronze then semis[#semis + 1] = m end
    end
    local hasL4 = final ~= nil or #semis > 0
    local nums = {}
    local n = r.nums or {}
    if n.matches then nums[#nums + 1] = { "Matches", n.matches } end
    if n.duels then nums[#nums + 1] = { "Duels", n.duels } end
    if n.longest and n.longest > 0 then nums[#nums + 1] = { "Longest duel", W.MinSec(n.longest) } end
    if n.watch and n.watch > 0 then nums[#nums + 1] = { "Watching, at most", n.watch } end
    local tags = r.tags or {}
    local hosted = false
    for _, k in ipairs(r.hosts or {}) do if IsMe(k) then hosted = true end end


    -- lays it all out cw wide (the scroll bar's room taken when it doesn't fit): returns its height
    local function layout(cw)
        f:SetWidth(cw)
        local y = 0
        -- the podium
        local standW = cw - AW_W - COL_GAP
        f.stand:SetWidth(standW)
        f.stand:SetShown(anyPlaced)
        local x0 = floor((standW - (3 * 112 + 2 * 14)) / 2)
        for i, p in ipairs(f.peds) do
            local key = placed[i]
            p:ClearAllPoints()
            p:SetPoint("BOTTOMLEFT", f.stand, "BOTTOMLEFT", x0 + (i - 1) * 126, 6)
            if key then
                p.face:Set(key)
                FitText(p.nm, Name(key), 124, { 13, 12, 11 })
                p.nm:SetJustifyH("CENTER")
                FitText(p.sb, W.PodiumLine(r, key, placeOf[i], by), 124, { 11, 10 })
                p.sb:SetJustifyH("CENTER")
                p:Show()
            else
                p:Hide()
            end
        end
        -- awards
        local right
        if not r.ranked then
            right = "not ranked"
        else
            local more = W.ExtraText(extra)
            right = more and ("plus " .. more) or nil
        end
        f.aw:SetShown(hasTop)
        f.awSect:Set("Awards", right)
        for i = 1, max(#rows, #f.awards) do
            local a = Pool(f.awards, i, function() return Pg.NewAward(f.aw) end)
            local x = rows[i]
            if x and i <= 4 then
                a:ClearAllPoints()
                a:SetPoint("TOPLEFT", f.aw, "TOPLEFT", 0, -(28 + (i - 1) * 44))
                if x.badge then
                    a.badge:SetBadge(x.badge)
                    a.face:Hide()
                else
                    a.badge:Hide()
                    a.face:Set(x.key)
                end
                a.pts:SetText(x.pts and ("+" .. x.pts) or "")
                -- (a long badge name: smaller, else two lines over the second)
                local room = AW_W - 50 - (x.pts and (NatW(a.pts) + 10) or 4)
                local _, _, lines = FitText(a.l1, x.title .. S:Wrap("SUB", " · ") .. Name(x.key), room, { 12, 11 })
                a.l1:ClearAllPoints()
                a.l2:ClearAllPoints()
                if lines == 1 then
                    a.l1:SetPoint("BOTTOMLEFT", a, "LEFT", 50, 1)
                    a.l2:SetPoint("TOPLEFT", a, "LEFT", 50, -2)
                else
                    a.l1:SetPoint("TOPLEFT", a, "TOPLEFT", 50, -2)
                    a.l2:SetPoint("TOPLEFT", a.l1, "BOTTOMLEFT", 0, -1)
                end
                FitText(a.l2, x.l2 or "", room, { 11, 10 })
                a:Show()
            else
                a:Hide()
            end
        end
        if hasTop then y = RECAP_Y end
        -- Matches: the moments, the last four and the numbers in a row; the score tables under them
        local tablesY
        f.l4:SetShown(matches and hasL4)
        f.num:SetShown(matches and #nums > 0)
        if matches then
            local numW, l4W = #nums > 0 and 150 or 0, hasL4 and 300 or 0
            local momW = cw - numW - l4W - (numW > 0 and COL_GAP or 0) - (l4W > 0 and COL_GAP or 0)
            local mh = Pg.LayMoments(f, r, moments, 0, y, momW, 4)
            -- the last four
            f.l4:ClearAllPoints()
            f.l4:SetPoint("TOPLEFT", f, "TOPLEFT", momW + COL_GAP, -y)
            f.l4Sect:Set("The last four")
            f.l4.full:SetShown(Live() and Live():GetState(r.id) ~= nil)
            local spots = { { 0, 6 }, { 0, 70 }, { 164, 38 } }
            local list = { semis[1], semis[2], final }
            for i = 1, 3 do
                local m = Pool(f.l4.matches, i, function() return Pg.NewMatch(f.l4.box) end)
                if list[i] then
                    m:ClearAllPoints()
                    m:SetPoint("TOPLEFT", f.l4.box, "TOPLEFT", spots[i][1], -spots[i][2])
                    m:Set(list[i])
                else
                    m:Hide()
                end
            end
            -- the connectors: each semi's middle to the final's
            local L = f.l4.lines
            local function hline(t, x1, x2, ly)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", f.l4.box, "TOPLEFT", x1, -ly)
                t:SetSize(x2 - x1, 1)
                t:Show()
            end
            local function vline(t, x, y1, y2)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", f.l4.box, "TOPLEFT", x, -y1)
                t:SetSize(1, y2 - y1)
                t:Show()
            end
            for _, t in ipairs(L) do t:Hide() end
            if final and #semis > 0 then
                local x1, x2 = MATCH_W, MATCH_W + floor((164 - MATCH_W) / 2)
                if semis[1] then hline(L[1], x1, x2, 25); vline(L[2], x2, 25, 58) end
                if semis[2] then hline(L[3], x1, x2, 89); vline(L[4], x2, 57, 90) end
                hline(L[5], x2, 164, 57)
            end
            -- the numbers
            f.num:ClearAllPoints()
            f.num:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -y)
            f.numSect:Set("Night in numbers")
            for i = 1, max(#nums, #f.nums) do
                local row = Pool(f.nums, i, function()
                    local x = CreateFrame("Frame", nil, f.num)
                    x:SetSize(150, 22)
                    x.l = UI():Text(x, "body", C.label)
                    x.l:SetPoint("LEFT", 0, 0)
                    x.v = UI():Text(x, "title", C.white, { font = NUM_FONT })
                    x.v:SetJustifyH("RIGHT")
                    x.v:SetPoint("RIGHT", -2, 0)
                    return x
                end)
                local x = nums[i]
                if x then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", f.num, "TOPLEFT", 0, -(30 + (i - 1) * 28))
                    row.l:SetText(x[1])
                    row.v:SetText(x[2])
                    row:Show()
                else
                    row:Hide()
                end
            end
            local rowH = max(mh, hasL4 and 162 or 0, #nums > 0 and (30 + #nums * 28) or 0)
            if rowH > 0 then y = y + rowH + 12 end
            tablesY = y
        end
        -- the scores' tables: beside the moments (without Matches), as many as fit in a row, the rest under them
        local ty = tablesY or y
        local showMom = not matches and #moments > 0
        local perRow = max(1, min(#boards, floor((cw - (showMom and (MOM_MIN + COL_GAP) or 0) + COL_GAP)
            / (TABLE_MIN + COL_GAP))))
        local tw = #boards > 0 and floor((cw - (showMom and (MOM_MIN + COL_GAP) or 0) - (perRow - 1) * COL_GAP) / perRow)
            or 0
        -- (one table: no wider than reads well; the moments and the tags in a column beside it)
        local lone = not matches and #boards == 1
        if lone then tw = min(tw, 340) end
        local rowTop, rowH = ty, 0
        for i = 1, max(#boards, #f.tables) do
            local t = Pool(f.tables, i, function() return Pg.NewTable(f) end)
            local s = boards[i]
            if s then
                local col = (i - 1) % perRow
                if i > 1 and col == 0 then
                    rowTop = rowTop + rowH + 12
                    rowH = 0
                end
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", f, "TOPLEFT", col * (tw + COL_GAP), -rowTop)
                rowH = max(rowH, Pg.FillTable(t, s, tw))
            else
                t:Hide()
            end
        end
        local momH, mx = 0, 0
        if not matches then
            mx = #boards > 0 and (min(#boards, perRow) * (tw + COL_GAP)) or 0
            momH = Pg.LayMoments(f, r, moments, mx, ty, cw - mx, 8)
        end
        -- who had each tag at the end: under the moments beside a lone table, else under everything
        local tx, tagsY, tagsW = 0, nil, cw
        if lone then
            tx, tagsW = mx, cw - mx
            tagsY = ty + (momH > 0 and (momH + 4) or 0)
        end
        if #boards > 0 or momH > 0 then
            y = max(rowTop + rowH, ty + momH) + 12
        end
        f.tags:SetShown(#tags > 0)
        if #tags > 0 then
            local atY = tagsY or y
            f.tags:ClearAllPoints()
            f.tags:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -atY)
            f.tags:SetWidth(tagsW)
            f.tagSect:Set("Tags at the end")
            local cols = tagsW >= 600 and 2 or 1
            local colW = floor((tagsW - (cols - 1) * COL_GAP) / cols)
            for i = 1, max(#tags, #f.tagRows) do
                local tr = Pool(f.tagRows, i, function() return Pg.NewTagRow(f.tags) end)
                local t = tags[i]
                if t then
                    local col, row = (i - 1) % cols, floor((i - 1) / cols)
                    tr:ClearAllPoints()
                    tr:SetPoint("TOPLEFT", f.tags, "TOPLEFT", col * (colW + COL_GAP), -(30 + row * TAG_RH))
                    Pg.FillTagRow(tr, t, r.n, colW, hosted)
                else
                    tr:Hide()
                end
            end
            local th = 30 + ceil(#tags / cols) * TAG_RH
            f.tags:SetHeight(th)
            if tagsY then
                y = max(y, atY + th + 12)
            else
                y = y + th + 8
            end
        end

        -- nothing to show at all (a cancelled event): say so
        local empty = not hasTop and #boards == 0 and #moments == 0 and #tags == 0 and not hasL4
        f.nobody:SetShown(empty)
        if empty then
            f.nobody:ClearAllPoints()
            f.nobody:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -6)
            f.nobody:SetText(r.cancel and "It was called off before anyone placed." or "Nobody placed.")
            y = 30
        end
        return y
    end
    local avail = H.BodyH(v.layout)
    local cw = w
    local h = layout(cw)
    if h > avail then
        cw = w - 12
        h = layout(cw)
    end
    f:SetHeight(max(1, h))
    v.rscroll:SetWidth(cw)
    v.rscroll.ScrollBar:Update()
end

---------------------------------------------------------------------------
-- Library (shot 2): the guild's events as cards
---------------------------------------------------------------------------

local Lib = {}
local CARD_H = 146
local FILTERS = { { key = "guild", label = "Guild" }, { key = "mine", label = "Mine" }, { key = "ranked", label = "Ranked" } }

-- 1.4: the Library is a Board page (UI:CreateLayout "board"): its filter row (the search, Guild / Mine / Ranked as
-- UI:CreateSegments) over a grid of event cards (UI:CreateCard with the event's art at the top); New event and
-- Examples are the tab toolbar's.
function Lib.Create(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.layout = UI():CreateLayout("board", v, { toolbar = false, top = UI().LAYOUT.TOP })
    local body = v.layout.body
    v.search = UI():CreateSearchBox(body, 220, function(text)
        state.q = text or ""
        EventsUI:Refresh()
    end, "Search events")
    v.search:SetHeight(S.BTN_H)
    v.search:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    v.seg = UI():CreateSegments(body, FILTERS, function(key)
        state.lib = key
        EventsUI:Refresh()
    end, { h = S.BTN_H, selected = state.lib })
    v.seg:SetPoint("LEFT", v.search, "RIGHT", GAP * 2, 0)
    -- (the filters' buttons by key: the tests and the tour click them)
    v.filters = {}
    for i, fdef in ipairs(FILTERS) do v.filters[fdef.key] = v.seg.buttons[i] end
    -- (New event and, beside it, Examples: the page's toolbar's, shown on the Library)
    v.new, v.examples = p.newBtn, p.libExBtn
    v.scroll = UI():CreateScrollFrame(body)
    v.scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(S.BTN_H + S.GAP + 4))
    v.scroll:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(700, 10)
    v.scroll:SetScrollChild(v.content)
    v.cards = {}
    v.empty = UI():CreateEmptyState(body, { glyph = UI().ICON.calendar })
    v.empty:SetPoint("TOP", body, "TOP", 0, -(S.BTN_H + 60))
    v.empty:Hide()
    return v
end

-- A card under the mouse (or picked by the audit's hover): its edge lit, its actions in place of its kind chips.
local function CardHover(c, on)
    c.hovered = on or nil
    local hot = on or state.hover == (c.def and c.def.id)
    c:SetTone("card")
    if hot then UI():SetEdgeColor(c, S:Color("EDGE_FOCUS")) end
    for _, m in ipairs(c.minis) do m:SetShown(not hot and m.used) end
    c.acts:SetShown(hot and true or false)
end

local function CardLeave(c)
    if c:IsMouseOver() then return end
    CardHover(c, false)
end

-- An event card: UI:CreateCard, the event's art along its top (shaded into the card), its review pill, its icon tile,
-- name, creator and runs, the kind chips; on hover Host / Copy / Edit / Share / Remove. A click opens it in the builder.
function Lib.NewCard(parent)
    local c = UI():CreateCard(parent, { tone = "card", width = 250, height = CARD_H })
    c.artF = CreateFrame("Frame", nil, c)
    c.artF:SetPoint("TOPLEFT", 1, -1)
    c.artF:SetPoint("TOPRIGHT", -1, -1)
    c.artF:SetHeight(64)
    c.art = c.artF:CreateTexture(nil, "BACKGROUND")
    c.art:SetAllPoints()
    EUI():AddShade(c.artF, "card")
    c.pill = H.Pill(c.artF, 16)
    c.pill:SetPoint("TOPRIGHT", -S.IN, -S.IN)
    c.icon = H.Icon(c, 32)
    c.icon:SetPoint("TOPLEFT", S.PAD, -44)
    c.icon:SetFrameLevel(c.artF:GetFrameLevel() + 3)
    c.n = UI():Text(c, "title", C.white)
    c.n:SetPoint("TOPLEFT", S.PAD, -84)
    c.a = UI():Text(c, "body", C.grey)
    c.a:SetPoint("TOPLEFT", c.n, "BOTTOMLEFT", 0, -4)
    c.minis = {}
    c.acts = CreateFrame("Frame", nil, c)
    c.acts:SetSize(186, 22)
    c.acts:SetPoint("BOTTOMRIGHT", -S.IN, S.IN)
    c.acts:SetFrameLevel(c:GetFrameLevel() + 4)
    c.share = A.ShareButton(c.acts, 22, function() return c.def and A.DefRef(c.def.id) end, "Share this event")
    c.edit = UI():CreateTipIconButton(c.acts, 22, 16, "Edit", "Opens it in the builder to change it.", function()
        if c.def then A.Builder(c.def) end
    end)
    c.copy = UI():CreateTipIconButton(c.acts, 22, 17, "Copy", "Makes your own copy of it to change.", function()
        if c.def then A.Copy(c.def) end
    end)
    c.host = H.Button(c.acts, "Host", 50, 22, "secondary", function()
        if c.def then EventsUI:OpenSchedule(c.def.id) end
    end)
    c.del = UI():CreateTipIconButton(c.acts, 22, UI().ICON.trash, "Remove", "Removes it from the guild's library for everyone. Calendar "
        .. "events made from it stay.", function() if c.def then A.RemoveDef(c.def) end end)
    for _, b in ipairs({ c.share, c.edit, c.copy, c.host, c.del }) do
        if b then b:HookScript("OnLeave", function() CardLeave(c) end) end
    end
    c.acts:Hide()
    c:EnableMouse(true)
    c:SetScript("OnEnter", function(self) CardHover(self, true) end)
    c:SetScript("OnLeave", function(self) CardLeave(self) end)
    c:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.def and self:IsMouseOver() then A.Builder(self.def) end
    end)
    return c
end

function Lib.FillCard(c, d, w)
    c.def = d
    c:SetSize(w, CARD_H)
    EUI():SetArt(c.art, d.art, w - 2, 64, nil, nil, 0.7)
    local text, kind = EUI():ReviewPill(Ev():ReviewState(d))
    c.pill:SetShown(text ~= nil)
    if text then c.pill:SetKind(text, kind) end
    c.icon:Set(d.icon)
    -- the name: smaller when it is long, else two lines (from the icon's foot, the creator's line close under them)
    local _, _, lines = FitText(c.n, d.name or "Event", w - 2 * S.PAD, { 13, 12, 11, 10 })
    c.n:ClearAllPoints()
    c.a:ClearAllPoints()
    if lines == 1 then
        c.n:SetPoint("TOPLEFT", S.PAD, -84)
        c.a:SetPoint("TOPLEFT", c.n, "BOTTOMLEFT", 0, -4)
    else
        c.n:SetPoint("TOPLEFT", S.PAD, -80)
        c.a:SetPoint("TOPLEFT", c.n, "BOTTOMLEFT", 0, -1)
    end
    local n = Ev():RunCount(d.id)
    local ran = n == 0 and "not run yet" or (n == 1 and "ran once" or (n == 2 and "ran twice" or ("ran " .. n .. " times")))
    c.a:SetText(Name(d.by) .. S:Wrap("SUB", " · " .. ran))
    -- what kind of event it is: its smart blocks and definitions (Sign-up, Matches, Tags, Places, Asks ...), as many
    -- as the card's width takes (the least telling go first)
    for _, m in ipairs(c.minis) do m.used = nil end
    H.LayKinds(c.minis, c, d, w - 2 * S.PAD, function(list)
        local x = S.PAD
        for _, m in ipairs(list) do
            m:ClearAllPoints()
            m:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", x, S.PAD)
            m.used = true
            x = x + m:GetWidth() + 4
        end
    end, true)
    -- the actions on hover: Host, Copy, Edit (mine), Share
    local anchor
    local function place(b, on)
        if not b then return end
        b:SetShown(on)
        if not on then return end
        b:ClearAllPoints()
        if anchor then b:SetPoint("RIGHT", anchor, "LEFT", -4, 0) else b:SetPoint("RIGHT", c.acts, "RIGHT", 0, 0) end
        anchor = b
    end
    place(c.del, Ev():IsMine(d) or W.CanRemove())
    place(c.share, A.DefRef(d.id) ~= nil)
    place(c.edit, Ev():IsMine(d))
    place(c.copy, true)
    place(c.host, true)
    CardHover(c, c.hovered)
    c:Show()
end

function Lib.List()
    local q = state.q and ns.Util.Trim(state.q):lower() or ""
    local all, mine, ranked = {}, 0, 0
    local runs = {}
    for _, d in ipairs(Ev():GetDefs()) do
        local isMine = Ev():IsMine(d)
        local isRanked = Ev():ReviewState(d) == "ranked"
        if isMine then mine = mine + 1 end
        if isRanked then ranked = ranked + 1 end
        local ok = state.lib == "guild" or (state.lib == "mine" and isMine) or (state.lib == "ranked" and isRanked)
        if ok and q ~= "" then
            local by = EUI():Plain(d.by):lower()
            ok = (d.name or ""):lower():find(q, 1, true) ~= nil or by:find(q, 1, true) ~= nil
        end
        if ok then
            all[#all + 1] = d
            runs[d.id] = Ev():RunCount(d.id)
        end
    end
    -- the ones the guild runs most first
    tsort(all, function(a, b)
        if runs[a.id] ~= runs[b.id] then return runs[a.id] > runs[b.id] end
        return (a.name or "") < (b.name or "")
    end)
    return all, #Ev():GetDefs(), mine, ranked
end

function Lib.Fill(v)
    local list, nGuild, nMine, nRanked = Lib.List()
    local counts = { guild = nGuild, mine = nMine, ranked = nRanked }
    for _, fdef in ipairs(FILTERS) do
        v.seg:SetLabel(fdef.key, fdef.label .. "  " .. S:Wrap("DIM", counts[fdef.key]))
    end
    v.seg:Select(state.lib)
    local W0 = v.layout.bodyW
    local rows = ceil(#list / 3)
    local need = rows * CARD_H + max(0, rows - 1) * GAP
    local avail = H.BodyH(v.layout, 0) - (S.BTN_H + S.GAP + 4)
    local cw = need > avail and (W0 - 12) or W0
    v.scroll:SetWidth(cw)
    v.content:SetWidth(cw)
    local w = floor((cw - 2 * GAP) / 3)
    for i, d in ipairs(list) do
        local c = Pool(v.cards, i, function() return Lib.NewCard(v.content) end)
        local col, row = (i - 1) % 3, floor((i - 1) / 3)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", v.content, "TOPLEFT", col * (w + GAP), -row * (CARD_H + GAP))
        Lib.FillCard(c, d, col == 2 and (cw - 2 * (w + GAP)) or w)
    end
    HideFrom(v.cards, #list + 1)
    v.content:SetHeight(max(1, need))
    v.empty:SetShown(#list == 0)
    if #list == 0 then
        local searching = (state.q or "") ~= ""
        v.empty:SetContent({ glyph = UI().ICON.calendar,
            title = searching and "Nothing found" or (state.lib == "mine" and "No events of yours yet"
                or (state.lib == "ranked" and "No ranked events" or "No events yet")),
            text = searching and "No event matches that." or (state.lib == "mine"
                and "You haven't built an event yet: Examples or New event start one." or (state.lib == "ranked"
                and "No event is ranked yet." or "The guild has no events yet: Examples or New event start one.")) })
    end
end

---------------------------------------------------------------------------
-- Season (shot 12): standings, my season, the ranked events that paid out
---------------------------------------------------------------------------

local Sea = {}
local SIDE_W, TROW_H = 250, S.ROW.list
-- the table's columns: x (from the row's left), width
local COL = { rk = { 8, 34 }, pl = { 42, 146 }, ev = { 188, 54 }, wins = { 242, 54 }, bd = { 296, 118 }, pts = { 414, 66 },
              tr = { 480, 34 } }
local TABLE_W = 522
-- (the number columns hang from the row's right edge: a scroll bar takes the room from the players' column)
local function FromRight(key) return COL[key][1] + COL[key][2] - TABLE_W end
local COL_TITLES = { { "rk", "#" }, { "pl", "Player" }, { "ev", "Events" }, { "wins", "Wins" }, { "bd", "Badges" },
    { "pts", "Points" } }

-- 1.4: the Season is a Board page (UI:CreateLayout "board"): the season as its hero banner (the arena's art, its
-- name, days and the three numbers, the ··· to set it), the standings as a table under the shared column titles in
-- its body, me and the ranked events in its side card.
-- TODO(refactor): move into UI:CreatePageBanner (numbers at the banner's bottom right: the season's days left,
-- ranked events, players)
function Sea.Create(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.layout = UI():CreateLayout("board", v, { toolbar = false, top = UI().LAYOUT.TOP, hero = { size = "hero" },
        side = SIDE_W })
    local L = v.layout
    local hd = L.banner
    hd.t, hd.t2 = hd.title, hd.sub
    hd.stats = {}
    for i = 1, 3 do
        local s = CreateFrame("Frame", nil, hd)
        s:SetSize(70, 40)
        s.b = UI():Text(s, 21, C.white, { font = NUM_FONT })
        s.b:SetPoint("TOPLEFT", 0, 0)
        s.l = UI():Text(s, "body", C.soft)
        s.l:SetPoint("TOPLEFT", s.b, "BOTTOMLEFT", 0, -2)
        hd.stats[i] = s
    end
    hd.toolList = { { icon = "more", title = "The season", text = "Rename it, or set its first and last day.",
        onClick = function(self)
            H.Menu(self, { { icon = "calendar", text = "Season", tip = "Renames the season or sets its first and last "
                .. "day. Only ranked events between them count.", fn = function() EventsUI:OpenSeasonSheet() end } })
        end } }
    hd:SetTools(hd.toolList)
    hd.more = hd.tools[1]
    v.head = hd
    v.main = L.body
    -- the table: the column titles, the rows
    v.th = UI():CreateColumnHeader(L.body, 24)
    v.th:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, 0)
    v.th:SetPoint("TOPRIGHT", L.body, "TOPRIGHT", 0, 0)
    v.th.line = UI():Rule(v.th, { bottom = 0 })
    v.th.cols = {}
    for _, ct in ipairs(COL_TITLES) do
        local key = ct[1]
        v.th.cols[key] = v.th:AddColumn(ct[2], COL[key][1], COL[key][2], {
            justify = (key == "rk" or key == "pl") and "LEFT" or "RIGHT" })
    end
    v.scroll = UI():CreateScrollFrame(L.body)
    v.scroll:SetPoint("TOPLEFT", L.body, "TOPLEFT", 0, -24)
    v.scroll:SetPoint("BOTTOMLEFT", L.body, "BOTTOMLEFT", 0, 0)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(522, 10)
    v.scroll:SetScrollChild(v.content)
    v.rows = {}
    v.none = UI():CreateEmptyState(L.body, { compact = true, glyph = UI().ICON.trophy,
        text = "No ranked event has paid out this season yet." })
    v.none:SetPoint("TOP", L.body, "TOP", 0, -60)
    v.none:Hide()
    -- the side card: me (my title to pick at the right of its header), then the ranked events
    local side = L.side
    v.side = side
    v.you = CreateFrame("Frame", nil, side)
    v.you:SetPoint("TOPLEFT", 0, 0)
    v.you:SetPoint("TOPRIGHT", 0, 0)
    v.you:SetHeight(128)
    v.you.head = H.Sect(v.you)
    v.you.head:SetPoint("TOPLEFT", S.IN, -4)
    v.you.head:SetPoint("TOPRIGHT", -S.IN, -4)
    v.you.head:Set("You")
    v.you.ht = v.you.head.title
    v.you.head:SetAction({ text = "No title", menu = function(root) Sea.TitleItems(root) end,
        tip = { "Your title", "Shown after your name on tooltips and in DisasterZone. Your badges gave you these." } })
    v.you.title = v.you.head.action
    v.you.title.fs = v.you.title.fs or v.you.title.label
    v.you.rk = UI():Text(v.you, 30, C.white, { font = NUM_FONT })
    v.you.rk:SetPoint("TOPLEFT", 24, -42)
    v.you.hash = UI():Text(v.you, "page", C.grey, { font = NUM_FONT })
    v.you.hash:SetPoint("BOTTOMRIGHT", v.you.rk, "BOTTOMLEFT", -1, 3)
    v.you.hash:SetText("#")
    v.you.pt = UI():Text(v.you, "title", C.white)
    v.you.pt:SetPoint("TOPLEFT", v.you.rk, "TOPRIGHT", 12, -2)
    v.you.pt2 = UI():Text(v.you, "body", C.grey)
    v.you.badges = {}
    v.ev = CreateFrame("Frame", nil, side)
    v.ev:SetPoint("TOPLEFT", v.you, "BOTTOMLEFT", 0, 0)
    v.ev:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 0)
    v.ev.head = H.Sect(v.ev)
    v.ev.head:SetPoint("TOPLEFT", S.IN, 0)
    v.ev.head:SetPoint("TOPRIGHT", -S.IN, 0)
    v.ev.head:Set("Ranked events")
    v.ev.ht = v.ev.head.title
    v.ev.rows = {}
    v.ev.foot = UI():Text(v.ev, "body", C.grey)
    v.ev.none = UI():Text(v.ev, "body", C.grey)
    v.ev.none:SetPoint("TOPLEFT", S.IN + 2, -34)
    return v
end

function Sea.NewRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(522, TROW_H)
    UI():DecorateRow(r, { selectable = true, rule = true })
    r.bg, r.bar, r.line = r.dzSelFill, r.dzSelBar, r.dzRule
    r.rk = UI():Text(r, "title", C.label, { font = NUM_FONT })
    r.rk:SetPoint("LEFT", COL.rk[1], 0)
    r.face = H.Face(r, 18)
    r.face:SetPoint("LEFT", COL.pl[1], 0)
    r.n = UI():Text(r, "emph", C.white)
    r.n:SetPoint("LEFT", r.face, "RIGHT", 8, 0)
    r.ti = UI():Text(r, "body", C.dim)
    r.ti:SetPoint("LEFT", r.n, "RIGHT", 7, 0)
    local function num(key, style, c)
        local fs = UI():Text(r, style, c, { font = NUM_FONT })
        fs:SetJustifyH("RIGHT")
        fs:SetPoint("RIGHT", r, "RIGHT", FromRight(key), 0)
        return fs
    end
    r.ev = num("ev", "title", C.label)
    r.wins = num("wins", "title", C.label)
    r.pts = num("pts", "title", C.white)
    r.badges = {}
    for i = 1, 3 do
        r.badges[i] = H.Badge(r, 13)
        r.badges[i]:SetPoint("RIGHT", r, "RIGHT", FromRight("bd") - 2 - (i - 1) * 25, 0)
    end
    r.trI = r:CreateTexture(nil, "ARTWORK")
    r.trI:SetSize(9, 9)
    r.trI:SetTexture(UI().ICON_ATLAS)
    r.tr = UI():Text(r, "body", C.dim)
    r.tr:SetJustifyH("RIGHT")
    r.tr:SetPoint("RIGHT", r, "RIGHT", FromRight("tr"), 0)
    r.trI:SetPoint("RIGHT", r.tr, "LEFT", -1, 0)
    return r
end

-- Who moved since the season's last ranked event: [key] = places up (+) or down (-).
function Sea.Trends(season, rows)
    local latest
    for _, r in ipairs(Ev():GetResults(season.from, season.to)) do
        if r.ranked and not r.cancel then latest = r; break end
    end
    if not latest then return {} end
    local before = Ev():Standings({ n = season.n, from = season.from, to = latest.at - 1 })
    local prev = {}
    for _, x in ipairs(before) do prev[x.key] = x.rank end
    local out = {}
    for _, x in ipairs(rows) do
        if prev[x.key] then out[x.key] = prev[x.key] - x.rank end
    end
    return out
end

-- My title's choices (the You header's link drops them).
function Sea.TitleItems(root)
    local me = Me()
    local titles = Ev():TitlesOf(me)
    local cur = Ev():GetTitle(me)
    if root.CreateTitle then root:CreateTitle("Your title") end
    for _, ti in ipairs(titles) do
        root:CreateRadio(ti, function() return cur == ti end, function()
            Ev():SetTitle(ti)
            EventsUI:RequestRefresh()
        end)
    end
    root:CreateRadio("No title", function() return cur == nil end, function()
        Ev():SetTitle("")
        EventsUI:RequestRefresh()
    end)
end

-- The banner: the season's name, its days, the three numbers at its bottom right.
function Sea.FillHead(v, season, results, rows)
    local hd = v.head
    local L = v.layout
    local w = L.innerW
    hd.building = true
    hd:SetArt(H.BannerArt("blades", w, S.BANNER.hero, 0.62))
    hd:SetSub(date("%d %b", season.from):gsub("^0", "") .. " - " .. date("%d %b", season.to):gsub("^0", "")
        .. " · ranked events only")
    local left = max(0, ceil((season.to - ns.Util.Now()) / DAY))
    local stats = { { left, left == 1 and "day left" or "days left" }, { #results, #results == 1 and "ranked event" or
        "ranked events" }, { #rows, #rows == 1 and "player" or "players" } }
    local canSet = Ev():CanModerate(Me())
    if canSet then hd:SetTools(hd.toolList) else hd:SetTools(nil) end
    local x = -14
    for i = 3, 1, -1 do
        local s = hd.stats[i]
        s.b:SetText(stats[i][1])
        s.l:SetText(stats[i][2])
        local sw = max(SW(s.b), SW(s.l))
        s:SetWidth(ceil(sw) + 2)
        s:ClearAllPoints()
        s:SetPoint("BOTTOMRIGHT", hd, "BOTTOMRIGHT", x, 12)
        x = x - (ceil(sw) + 2) - 22
    end
    hd:SetTitle(season.n or "Season")
    hd.building = nil
    hd:Layout()
end

function Sea.Fill(v)
    local L = v.layout
    local mw = L.bodyW
    local season = Ev():GetSeason()
    local rows = Ev():Standings(season)
    local results = {}
    for _, r in ipairs(Ev():GetResults(season.from, season.to)) do
        if r.ranked and not r.cancel then results[#results + 1] = r end
    end
    Sea.FillHead(v, season, results, rows)
    -- the table
    local trends = Sea.Trends(season, rows)
    local need = #rows * TROW_H
    local avail = H.BodyH(L) - 24
    local cw = need > avail and (mw - 12) or mw
    v.scroll:SetWidth(cw)
    v.content:SetWidth(cw)
    -- (the number columns' titles over their numbers: from the table's right edge)
    for _, ct in ipairs(COL_TITLES) do
        local key = ct[1]
        if key ~= "rk" and key ~= "pl" then
            local b = v.th.cols[key]
            b:ClearAllPoints()
            b:SetPoint("RIGHT", v.th, "LEFT", cw + FromRight(key) - (key == "bd" and 2 or 0), 0)
        end
    end
    for i, x2 in ipairs(rows) do
        local r = Pool(v.rows, i, function() return Sea.NewRow(v.content) end)
        r:SetWidth(cw)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -(i - 1) * TROW_H)
        r:SetSelected(x2.key == Me())
        r.rk:SetText(x2.rank)
        r.rk:SetTextColor(S:Color(x2.rank <= 3 and C.gold or C.label))
        r.face:Set(x2.key)
        r.n:SetText(Name(x2.key))
        local ti = Ev():GetTitle(x2.key)
        r.ti:SetText(ti or "")
        r.ti:SetShown(ti ~= nil and TextW(r.n) + TextW(r.ti) + 36 <= COL.pl[2] - (TABLE_W - cw))
        r.ev:SetText(x2.events)
        r.wins:SetText(x2.wins)
        r.pts:SetText(x2.pts)
        for j, bd in ipairs(r.badges) do
            -- the newest on the right
            local badge = x2.badges[j]
            if badge then bd:SetBadge(badge) else bd:Hide() end
        end
        local t = trends[x2.key]
        if t and t ~= 0 then
            local c = t > 0 and C.green or C.red
            r.tr:SetText(tostring(t > 0 and t or -t))
            r.tr:SetTextColor(S:Color(c))
            r.trI:Show()
            UI():SetChevronUp(r.trI, t > 0)
            r.trI:SetVertexColor(c[1], c[2], c[3])
        else
            r.tr:SetText("–")
            r.tr:SetTextColor(S:Color(C.dim))
            r.trI:Hide()
        end
        r:Show()
    end
    HideFrom(v.rows, #rows + 1)
    v.content:SetHeight(max(1, need))
    v.none:SetShown(#rows == 0)
    -- me
    local you = v.you
    local mine, above, below = W.MyStanding(rows)
    local titles = Ev():TitlesOf(Me())
    local cur = Ev():GetTitle(Me())
    if #titles > 0 then
        you.head:SetAction({ text = cur or "No title", menu = function(root) Sea.TitleItems(root) end,
            tip = { "Your title", "Shown after your name on tooltips and in DisasterZone. Your badges gave you these." } })
    else
        you.head:SetAction(nil)
    end
    you.title:SetShown(#titles > 0)
    if mine then
        you.rk:SetText(mine.rank)
        you.pt:SetText(mine.pts .. (mine.pts == 1 and " point" or " points"))
        local parts = {}
        parts[#parts + 1] = W.Gap(mine, above)
        parts[#parts + 1] = W.Gap(mine, below, true)
        you.pt2Text = #parts > 0 and tconcat(parts, ", ") or "the only one on the board"
    else
        you.rk:SetText("-")
        you.pt:SetText("No points yet")
        you.pt2Text = "A ranked event puts you on the board."
    end
    you.pt2:ClearAllPoints()
    you.pt2:SetPoint("TOPLEFT", you.pt, "BOTTOMLEFT", 0, -3)
    Wrap(you.pt2, you.pt2Text, SIDE_W - 90, 11)
    local badges = Ev():BadgesOf(Me())
    local bx = S.IN
    for i = 1, 6 do
        local bd = Pool(you.badges, i, function() return H.Badge(you, 19) end)
        if badges[i] then
            bd:SetBadge(badges[i])
            bd:ClearAllPoints()
            bd:SetPoint("BOTTOMLEFT", you, "BOTTOMLEFT", bx, 10)
            bx = bx + bd:GetWidth() + 6
        else
            bd:Hide()
        end
    end
    you:SetHeight(#badges > 0 and 128 or 96)
    -- the ranked events, newest first (as many as fit over the card's foot)
    local ev = v.ev
    local sideH = H.BodyH(L)
    local maxRows = floor((sideH - you:GetHeight() - 28 - 56) / S.ROW.art)
    for i = 1, max(#results, #ev.rows) do
        local row = Pool(ev.rows, i, function() return Sea.NewEventRow(ev) end)
        local r = results[i]
        if r and i <= maxRows then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", ev, "TOPLEFT", 1, -(28 + (i - 1) * S.ROW.art))
            row:SetPoint("TOPRIGHT", ev, "TOPRIGHT", -1, -(28 + (i - 1) * S.ROW.art))
            Sea.FillEventRow(row, r)
            row:Show()
        else
            row:Hide()
        end
    end
    ev.none:SetShown(#results == 0)
    ev.none:SetText("None this season yet.")
    ev.foot:ClearAllPoints()
    ev.foot:SetPoint("BOTTOMLEFT", ev, "BOTTOMLEFT", S.IN, S.IN)
    Wrap(ev.foot, "Only ranked events count: placings, badges and matches won, as each event's pieces say.",
        SIDE_W - 2 * S.IN, 11)
end

-- A ranked event that paid out: UI:CreateArtRow (its art, name, day and my place; my points at the right).
function Sea.NewEventRow(parent)
    local r = UI():CreateArtRow(parent, { onClick = function(self) if self.id then EventsUI:OpenEvent(self.id) end end })
    r.n, r.l2, r.p = r.title, r.sub, r.rightText
    r.hl = r.dzHover
    return r
end

function Sea.FillEventRow(row, r)
    row.id = r.id
    local me = Me()
    local mine, n = W.MyPlace(r)
    local place = (n == 1 and "you won") or (n and W.Ord(n)) or (mine and "played") or (r.points[me] and "played")
        or "not in it"
    local p = r.points[me]
    row:SetData({ art = r.art, icon = r.icon, title = r.name or "Event",
        sub = date("%a ", r.at) .. date("%d %b", r.at) .. " · " .. place, right = p and ("+" .. p) or "-" })
    row.p:SetTextColor(S:Color(p and C.pts or C.dim))
end

---------------------------------------------------------------------------
-- Review (shot 14): what waits for a decision, and what changed
---------------------------------------------------------------------------

local Rv = {}
local QL_W, RVCOL_W, DIFF_MAX = 280, 250, 4
local DIFF_LOOK = { add = { 0.35, 0.86, 0.47 }, del = { 0.89, 0.36, 0.31 }, chg = C.gold }

-- A piece in words, its blanks filled ("best of 3 ...", "give badge Giant slayer to Biggest upset").
function W.PieceText(p, def, depth)
    local pd = p and B().PIECES[p.k]
    if not pd then return p and tostring(p.k) or "" end
    depth = depth or 0
    local function value(v, a, n)
        -- (a filter its choice doesn't have isn't there: "when an entrant dies")
        if a and a.t == "filter" and B():ArgType(p, n) == nil then return "" end
        if v == nil then return (a and a.opt) and "any" or "___" end
        if type(v) == "table" then
            if v.k then return depth < 3 and W.PieceText(v, def, depth + 1) or "a value" end
            if type(v.j) == "table" then
                local out = {}
                for _, x in ipairs(v.j) do
                    out[#out + 1] = type(x) == "table" and W.PieceText(x, def, depth + 1) or tostring(x)
                end
                return "\"" .. tconcat(out) .. "\""
            end
            return "?"
        end
        local t = a and a.t
        if t == "text" then return "\"" .. tostring(v) .. "\"" end
        -- (a definition's name, a choice's words: "Hiders", "catches a fish", "Raid warning")
        local words = B().BlankWords and B():BlankWords(def, p, n)
        if words then return words end
        if t == "block" then return B():BlockLabel(def, v) end
        if t == "stage" then return B():StageName(def, v) end
        if t == "badge" then
            local bd = def and def.badges and def.badges[v]
            return bd and bd.n or tostring(v)
        end
        if t == "dur" then return B():DurationText(v) end
        if t == "ctxname" then
            local c = B().CTX[v]
            return c and c.label or tostring(v)
        end
        if t == "channel" then
            for _, ch in ipairs(B().CHANNELS) do if ch[1] == v then return ch[2] end end
        end
        if t == "text" then return "\"" .. tostring(v) .. "\"" end
        return tostring(v)
    end
    return ((pd.text or ""):gsub("{(%d)}", function(n)
        n = tonumber(n)
        return value(p.a and p.a[n], pd.args and pd.args[n], n)
    end):gsub("%s+$", ""):gsub("  +", " "))
end


-- 1.4: the Review is a List + detail page (UI:CreateLayout "listdetail"): Waiting / Decided as art rows under
-- counted section headers in its list; the picked event opens with a banner (D3: its art, icon, name and state pill,
-- who sent it; Mark ranked as the main action, Send back beside it, the eye to look inside as its tool), then what
-- changed, the note and my reply, what it gives, the checks and the last decision.
function Rv.Create(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.layout = UI():CreateLayout("listdetail", v, { toolbar = false, top = UI().LAYOUT.TOP, listWidth = QL_W,
        banner = { size = "tool", titleColor = C.white } })
    local L = v.layout
    v.ql = L.list
    v.wsect = H.Sect(v.ql)
    v.dsect = H.Sect(v.ql)
    v.qrows = {}
    v.qnone = UI():Text(v.ql, "body", C.grey)
    v.qd = L.body
    -- the picked event's banner: its art, icon, name and pill, who sent it; Mark ranked / Send back; the eye
    local ban = L.banner
    v.ban = ban
    ban:SetTools({ { icon = "eye", title = "Look inside", text = "Opens it in the builder, read only: every piece, "
        .. "every stage.", onClick = function() if v.def then A.Builder(v.def) end end } })
    -- (its buttons made once: v.head.rank / .back are the banner's two actions, v.head.eye its tool)
    ban:SetActions({ { text = "Mark ranked" }, { text = "Send back" } })
    v.head = { rank = ban.btnPool[1], back = ban.btnPool[2], eye = ban.tools[1], t = ban.title, t2 = ban.sub,
        pill = ban.pill, banner = ban }
    v.rankAction = { text = "Mark ranked", kind = "primary", onClick = function() Rv.Decide(v, true) end }
    v.backAction = { text = "Send back", onClick = function() Rv.Decide(v, false) end }
    ban:SetActions(nil)
    -- what changed since the ranked version, piece by piece
    v.csect = H.Sect(v.qd)
    v.csect:SetPoint("TOPLEFT", 0, 0)
    v.csect:SetPoint("TOPRIGHT", 0, 0)
    v.dscroll = UI():CreateScrollFrame(v.qd)
    v.dscroll:SetPoint("TOPLEFT", 0, -28)
    v.dcontent = CreateFrame("Frame", nil, v.dscroll)
    v.dcontent:SetSize(400, 10)
    v.dscroll:SetScrollChild(v.dcontent)
    v.diffs = {}
    -- below: the note, my reply; the rewards, the checks, the last decision
    v.left = CreateFrame("Frame", nil, v.qd)
    v.left:SetHeight(200)
    v.nsect = H.Sect(v.left)
    v.nsect:SetPoint("TOPLEFT")
    v.nsect:SetPoint("TOPRIGHT")
    v.note = UI():CreateCard(v.left, { tone = "inset" })
    v.note:SetPoint("TOPLEFT", 0, -28)
    v.note:SetPoint("TOPRIGHT", 0, -28)
    v.note.fs = UI():Text(v.note, "body", C.text)
    v.note.fs:SetPoint("TOPLEFT", S.IN + 2, -7)
    v.rsect = H.Sect(v.left)
    v.reply = UI():CreateSleekEditBox(v.left, 200, S.BTN_H + 2, "GameFontHighlightSmall")
    v.reply:SetMaxLetters(200)
    v.reply:SetScript("OnTextChanged", function(self)
        if (self:GetText() or "") ~= "" and v.rsect.r:IsShown() then v.rsect.r:Hide() end
    end)
    UI():SetEditPlaceholder(v.reply, "Say why if you send it back")
    v.right = CreateFrame("Frame", nil, v.qd)
    v.right:SetSize(RVCOL_W, 200)
    v.gsect = H.Sect(v.right)
    v.gsect:SetPoint("TOPLEFT")
    v.gsect:SetPoint("TOPRIGHT")
    v.gives = {}
    v.checks = CreateFrame("Frame", nil, v.right)
    v.checks:SetSize(RVCOL_W, 22)
    v.checks.icon = v.checks:CreateTexture(nil, "ARTWORK")
    v.checks.icon:SetSize(13, 13)
    v.checks.icon:SetPoint("LEFT", 2, 0)
    v.checks.fs = UI():Text(v.checks, "emph", C.label)
    v.checks.fs:SetPoint("LEFT", 22, 0)
    v.checks.r = UI():Text(v.checks, "body", C.grey)
    v.checks.r:SetJustifyH("RIGHT")
    v.checks.r:SetPoint("RIGHT", 0, 0)
    v.lsect = H.Sect(v.right)
    v.last = UI():Text(v.right, "body", C.label)
    v.lastR = UI():Text(v.right, "body", C.grey)
    v.lastR:SetJustifyH("RIGHT")
    v.lastNote = UI():Text(v.right, "body", C.grey)
    v.empty = UI():CreateEmptyState(L.detail, { glyph = UI().ICON.trophy, title = "Nothing to review",
        text = "Events sent in for review show up here." })
    v.empty:SetPoint("TOP", L.detail, "TOP", 0, -90)
    return v
end

-- A row of Waiting / Decided: UI:CreateArtRow (the event's art and icon, its name, new or changed / who decided);
-- its mark (ranked, sent back) at the right, the bin in its place on hover for who may clear it.
function Rv.NewQRow(parent)
    local r = UI():CreateArtRow(parent, { selectable = true, onClick = function(self)
        state.review = self.id
        EventsUI:Refresh()
    end })
    r.l1, r.l2 = r.title, r.sub
    r.sel, r.bar, r.hl = r.dzSelFill, r.dzSelBar, r.dzHover
    r.mark = r.right:CreateTexture(nil, "ARTWORK")
    r.mark:SetSize(14, 14)
    r.mark:SetPoint("RIGHT", -2, 0)
    -- the bin, on hover, where the mark is (r.remove; its tooltip: r.del.tipText)
    r.del = UI():CreateRemoveButton(r, "Remove")
    r.del:SetPoint("RIGHT", -8, 0)
    r.del:Hide()
    r.del:SetScript("OnClick", function() if r.remove then r.remove() end end)
    local function leave()
        if r:IsMouseOver() then return end
        r.del:Hide()
        r.mark:SetShown(r.hasMark and true or false)
    end
    r.del:HookScript("OnLeave", leave)
    r:SetScript("OnEnter", function(self)
        if not self.remove then return end
        self.del:Show()
        self.mark:Hide()
    end)
    r:SetScript("OnLeave", leave)
    return r
end

-- "18:02" today, "Thu" this week, "02 Oct" before.
function W.Ago(t)
    if not t then return "" end
    local now = ns.Util.Now()
    if date("%Y%m%d", t) == date("%Y%m%d", now) then return W.Clock(t) end
    if now - t < 6 * DAY then return date("%a", t) end
    return date("%d %b", t)
end

-- Is it new (never ranked) or changed since it was?
function W.NewOrChanged(d)
    local k = Ev():GetReview(d.id)
    return (k and k.ok) and "changed" or "new"
end

function Rv.NewDiff(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(400, 34)
    r.bg = UI():Fill(r, "HOVER")
    r.bar = Line(r, { 1, 1, 1, 1 })
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.bar:SetWidth(2)
    r.stage = UI():Text(r, "small", C.grey)
    r.stage:SetPoint("LEFT", 9, 0)
    r.fs = UI():Text(r, "body", C.white)
    r.fs:SetPoint("LEFT", 62, 0)
    r.dot = Disc(r, 8, C.white, "ARTWORK")
    r.dot:Hide()
    r:EnableMouse(true)
    H.TipFromField(r)
    return r
end

-- A change's stage label ("Bracket", "Badges").
function W.DiffStage(ch)
    return ch.stage or (ch.badge and "Badges") or (ch.def and B():KindLabel(ch.def)) or ""
end

-- A definition in a few plain words (the review's rows): "everyone sees it", "lower wins, a time, on the board",
-- "250 yd, Terrace of Light", "8 places", "a vote, 3 each, secret".
local ASK_WORDS = { player = "a vote for a player", choice = "a vote", text = "a typed answer", yesno = "yes or no",
    number = "1 to 10" }
local FMT_WORDS = { num = "a number", time = "a time", gold = "gold" }
function W.DefWords(kind, x)
    if type(x) ~= "table" then return "" end
    if kind == "tags" then
        return (string.lower(SHOWN_WORDS[x.shown or "all"] or ""):gsub("%.$", ""))

    elseif kind == "scores" then
        local parts = { (x.high == false) and "lower wins" or "higher wins", FMT_WORDS[x.fmt or "num"] or "a number" }
        if x.board then parts[#parts + 1] = "on the board" end
        if tonumber(x.cap) and tonumber(x.cap) > 0 then parts[#parts + 1] = "at most " .. x.cap end
        return tconcat(parts, ", ")
    elseif kind == "places" then
        local parts = { floor(tonumber(x.r) or 30) .. " yd" }
        if x.sz or x.z then parts[#parts + 1] = x.sz or x.z end
        return tconcat(parts, ", ")
    elseif kind == "lists" then
        local n = type(x.items) == "table" and #x.items or 0
        local noun = ({ place = { "place", "places" }, question = { "question", "questions" } })[x.kind or "text"]
            or { "item", "items" }
        return n .. " " .. (n == 1 and noun[1] or noun[2])
    elseif kind == "asks" then
        local parts = { ASK_WORDS[x.kind or "player"] or "a question" }
        if (tonumber(x.votes) or 1) > 1 then parts[#parts + 1] = x.votes .. " each" end
        if x.secret then parts[#parts + 1] = "secret" end
        return tconcat(parts, ", ")
    end
    return ""
end

-- What changed in a definition, in plain words: "250 yd, was 600 yd"; "colour red, was green" ... (nil: nothing
-- the words show).
function W.DefChange(kind, old, new)
    if type(old) ~= "table" or type(new) ~= "table" then return nil end
    local parts = {}
    local function was(now, before) parts[#parts + 1] = now .. " (was " .. before .. ")" end
    if kind == "tags" then
        if old.c ~= new.c then was("colour " .. tostring(new.c or "blue"), tostring(old.c or "blue")) end
        if (old.shown or "all") ~= (new.shown or "all") then
            was(W.DefWords("tags", new), W.DefWords("tags", old))
        end
    elseif kind == "scores" then
        if (old.high == false) ~= (new.high == false) then
            was(new.high == false and "lower wins" or "higher wins", old.high == false and "lower" or "higher")
        end
        if (old.fmt or "num") ~= (new.fmt or "num") then was(FMT_WORDS[new.fmt or "num"] or "?", FMT_WORDS[old.fmt or "num"] or "?") end
        if (old.board and true or false) ~= (new.board and true or false) then
            parts[#parts + 1] = new.board and "on the board now" or "off the board now"
        end
        if tonumber(old.cap) ~= tonumber(new.cap) then
            was(tonumber(new.cap) and ("at most " .. new.cap) or "no cap", tonumber(old.cap) and tostring(old.cap) or "none")
        end
    elseif kind == "places" then
        if tonumber(old.r) ~= tonumber(new.r) then
            was(floor(tonumber(new.r) or 30) .. " yd", floor(tonumber(old.r) or 30) .. " yd")
        end
        if old.map ~= new.map or old.x ~= new.x or old.y ~= new.y or old.sz ~= new.sz or old.z ~= new.z then
            parts[#parts + 1] = "moved" .. ((new.sz or new.z) and (" to " .. (new.sz or new.z)) or "")
        end
    elseif kind == "lists" then
        local a, b = W.DefWords("lists", old), W.DefWords("lists", new)
        if a ~= b then was(b, a) else parts[#parts + 1] = "items changed" end
    elseif kind == "asks" then
        if (old.q or "") ~= (new.q or "") then parts[#parts + 1] = "new question" end
        local a, b = W.DefWords("asks", old), W.DefWords("asks", new)
        if a ~= b then was(b, a) end
        if tonumber(old.time) ~= tonumber(new.time) then
            was(B():DurationText(tonumber(new.time) or 60), B():DurationText(tonumber(old.time) or 60))
        end
        if old.from ~= new.from then parts[#parts + 1] = "others to pick from" end
    end
    return #parts > 0 and tconcat(parts, "; ") or nil
end

-- One change: its colour bar, the stage (in a column colX wide), the piece drawn (or its words, wrapped). Returns
-- the row's height.
function Rv.FillDiff(r, ch, def, w, colX)
    local EP = ns.EventPieces
    if r.pf and EP and EP.Release then EP:Release(r.pf) end
    r.pf = nil
    colX = colX or 62
    r:SetWidth(w)
    local c = DIFF_LOOK[ch.kind] or DIFF_LOOK.chg
    r.bg:SetColorTexture(c[1], c[2], c[3], ch.kind == "chg" and 0.05 or 0.07)
    r.bar:SetColorTexture(c[1], c[2], c[3], 0.8)
    local _, sh = FitText(r.stage, W.DiffStage(ch), colX - 19, 10)
    local h = max(34, sh + 10)
    r.tip = nil
    local room = w - colX - 8
    if ch.piece and EP and EP.Draw then
        local p = ch.piece
        if p.c1 or p.c2 then
            -- a C piece: its own row, without what it holds
            local q = {}
            for k, x in pairs(p) do q[k] = x end
            q.c1, q.c2 = nil, nil
            p = q
        end
        local ok, f = pcall(EP.Draw, EP, r, p, { static = true, scale = 0.85, def = def })
        if ok and f then
            -- (a long piece: drawn smaller to fit the row; too small to read: its words instead)
            local pw = f.w or f:GetWidth() or 0
            local sc = 0.85
            if pw * sc > room then sc = room / max(1, pw) end
            if sc >= 0.6 then
                r.pf = f
                f:SetScale(sc)
                f:ClearAllPoints()
                f:SetPoint("LEFT", r, "LEFT", colX / sc, 0)
                h = max(h, ceil((f:GetHeight() or 24) * sc) + 8)
                r.fs:Hide()
            elseif EP.Release then
                EP:Release(f)
            end
        end
    end
    r.dot:Hide()
    if not r.pf then
        local text = ch.text or (ch.piece and W.PieceText(ch.piece, def)) or ""
        -- (a tag's row: its colour before the words)
        local dx = ch.dot and 14 or 0
        if ch.dot then
            r.dot:ClearAllPoints()
            r.dot:SetPoint("CENTER", r, "LEFT", colX + 4, 0)
            r.dot:SetVertexColor(ch.dot[1], ch.dot[2], ch.dot[3], 1)
            r.dot:Show()
        end
        r.fs:ClearAllPoints()
        r.fs:SetPoint("LEFT", r, "LEFT", colX + dx, 0)
        h = max(h, Wrap(r.fs, (text:gsub("→", "to")), room - dx, 11) + 16)
        r.fs:Show()
    end

    if ch.kind == "chg" and ch.old then r.tip = { "Changed", "Was: " .. W.PieceText(ch.old, def) } end
    if ch.kind == "del" and ch.piece then r.tip = { "Taken out", W.PieceText(ch.piece, def) } end
    r:SetHeight(h)
    r:Show()
    return h
end

-- The changes to show: the diff from the ranked snapshot, or (new) the stages in plain words.
function Rv.Changes(d)
    local snap = Ev():RankedSnapshot(d.id)
    local rs = Ev():ReviewState(d)
    if snap and rs ~= "ranked" then
        local changes, same = B():Diff(snap, d)
        -- a definition's row says what it is (new) or what changed in it, in words; a tag's has its colour
        for _, ch in ipairs(changes) do
            if ch.def and ch.id then
                local now = type(d[ch.def]) == "table" and d[ch.def][ch.id]
                local was = type(snap[ch.def]) == "table" and snap[ch.def][ch.id]
                local words
                if ch.kind == "add" then words = W.DefWords(ch.def, now)
                elseif ch.kind == "chg" then words = W.DefChange(ch.def, was, now) end
                if words and words ~= "" then ch.text = (ch.text or "") .. ", " .. words end
                local tg = ch.def == "tags" and (now or was)
                if type(tg) == "table" then ch.dot = B():TagColor(tg.c) end
            end
        end
        local order = {}
        for i, ch in ipairs(changes) do order[ch] = i end
        tsort(changes, function(a, c)
            local ta, tc = a.piece == nil, c.piece == nil
            if ta ~= tc then return ta end
            return order[a] < order[c]
        end)
        return changes, ("What changed since it was ranked"), (same .. (same == 1 and " other piece is" or
            " other pieces are") .. " the same"), snap
    end
    local out = {}
    for _, s in ipairs(B():Describe(d)) do
        out[#out + 1] = { kind = "add", stage = s.name, text = (s.text ~= "" and s.text) or "(nothing in it yet)" }
    end
    local always = B():DescribeStage(d, { id = "*", name = "Always" })
    if (always.text or "") ~= "" then out[#out + 1] = { kind = "add", stage = "Always", text = always.text } end
    local label = (rs == "review" or rs == "draft") and (W.NewOrChanged(d) == "changed" and "Changed since it was ranked"
        or "New event") or "How it runs"
    local n = W.PieceCount(d)
    return out, label, n .. (n == 1 and " piece" or " pieces"), snap
end

-- The four checks: practice run, blanks, chat, season cap. Returns passed, total, practice time (or false).
function W.Checks(d)
    local EB = ns.EventBuilder
    local practiced = false
    if EB and EB.WasPracticed then
        local ok, at = EB:WasPracticed(d.id, d.rev)
        practiced = ok and (tonumber(at) or true) or false
    end
    local blanks = #B():Problems(d) == 0
    local cap = B():MaxSeasonGrant(d) <= B().SEASON_CAP
    local n = 1 + (practiced and 1 or 0) + (blanks and 1 or 0) + (cap and 1 or 0)
    return n, 4, practiced, blanks, cap
end

-- The "Rewards it gives" rows: { { kind = badge | score | season, rw, sc, n, l2, right, new, h } }, five at most:
-- the badges (new ones first; each with where it goes: "1st by Fish", "most Finds", "Biggest upset"), a score on
-- the board no badge names, the season points no badge goes with ("5 for playing, 5 a match won").
function Rv.Gives(d, snap, waiting)
    local rewards, extra = W.Rewards(d)
    local function isNew(rw)
        return waiting and ((snap and not (snap.badges and snap.badges[rw.id])) or
            (not snap and W.NewOrChanged(d) == "new")) or false
    end
    local out, named = {}, {}
    for _, rw in ipairs(rewards) do
        local sc = rw.sid and B():Definition(d, "scores", rw.sid)
        if sc then named[rw.sid] = true end
        local l2 = rw.label or ""
        if sc and not l2:find(sc.n or "", 1, true) then l2 = l2 .. " by " .. (sc.n or "") end
        local right = {}
        if rw.pts then right[#right + 1] = "+" .. rw.pts end
        if rw.b.ti and rw.b.ti ~= "" then right[#right + 1] = "title" end
        out[#out + 1] = { kind = "badge", rw = rw, n = rw.b.n or "Badge", l2 = l2 ~= "" and l2 or nil,
            right = tconcat(right, " · "), new = isNew(rw) }
    end
    -- (the new ones first, else in placing order)
    local order = {}
    for i, x in ipairs(out) do order[x] = i end
    tsort(out, function(a, c)
        if a.new ~= c.new then return a.new end
        return order[a] < order[c]
    end)
    for _, sc in ipairs(B():Defs(d, "scores", true)) do
        if sc.board and not named[sc.id] then
            out[#out + 1] = { kind = "score", sc = sc, n = sc.n or "Score", l2 = W.Way(sc) .. " wins, on the board",
                right = "" }
        end
    end
    local more = W.ExtraText(extra)
    if more then out[#out + 1] = { kind = "season", n = "Season points", l2 = more, right = "" } end
    while #out > 5 do tremove(out, #out - (out[#out].kind == "season" and 1 or 0)) end
    for _, x in ipairs(out) do x.h = x.l2 and 34 or 28 end
    return out
end

function Rv.NewGive(parent)
    local x = CreateFrame("Frame", nil, parent)
    x:SetSize(RVCOL_W, 28)
    x.badge = H.Badge(x, 18)
    x.badge:SetPoint("LEFT", 0, 0)
    x.glyph = x:CreateTexture(nil, "ARTWORK")
    x.glyph:SetSize(15, 15)
    x.glyph:SetPoint("CENTER", x, "LEFT", 12, 0)
    x.n = UI():Text(x, "emph", C.white)
    x.l2 = UI():Text(x, "small", C.grey)
    x.pill = H.Pill(x, 16)
    x.r = UI():Text(x, "body", C.grey)
    x.r:SetJustifyH("RIGHT")
    x.r:SetPoint("RIGHT", 0, 0)
    return x
end

-- Fills a "Rewards it gives" row; returns its height.
function Rv.FillGive(g, x, d)
    local rw = x.rw
    g.glyph:Hide()
    if x.kind == "badge" then
        g.badge:SetBadge({ n = rw.b.n, i = rw.b.i, f = rw.b.f, ti = rw.b.ti, ev = d.name })
    else
        g.badge:Hide()
        if x.kind == "season" then
            g.glyph:SetTexture(STAR)
            g.glyph:SetTexCoord(0, 0.5, 0, 0.5)
            g.glyph:SetVertexColor(1, 1, 1, 1)
        else
            H.Glyph(g.glyph, "trophy", { 0.85, 0.85, 0.87, 0.9 })
        end
        g.glyph:Show()
    end
    g.pill:SetShown(x.new and true or false)
    if x.new then g.pill:SetKind("new", "warn") end
    g.r:SetText(x.right or "")
    -- the name in the room the pill and the points leave: smaller, never cut
    local rtw = (x.right or "") ~= "" and (NatW(g.r) + 8) or 0
    local room = RVCOL_W - 32 - rtw - (x.new and (g.pill:GetWidth() + 6) or 0)
    local tw, nh, lines = FitText(g.n, x.n, room, { 12, 11, 10 })
    g.n:ClearAllPoints()
    g.l2:ClearAllPoints()
    local h = x.h
    g.pill:ClearAllPoints()
    if lines == 2 then
        -- (a long name on two lines from the top; its "new" and where it goes under them; the row grows)
        g.n:SetPoint("TOPLEFT", g, "TOPLEFT", 32, -3)
        h = 3 + nh + ((x.l2 or x.new) and 17 or 0) + 4
        if x.new then g.pill:SetPoint("TOPLEFT", g.n, "BOTTOMLEFT", 0, -1) end
        if x.l2 then
            FitText(g.l2, x.l2, RVCOL_W - 32 - rtw - (x.new and (g.pill:GetWidth() + 6) or 0), { 10, 9 })
            if x.new then
                g.l2:SetPoint("LEFT", g.pill, "RIGHT", 6, 0)
            else
                g.l2:SetPoint("TOPLEFT", g.n, "BOTTOMLEFT", 0, -2)
            end
            g.l2:Show()
        else
            g.l2:Hide()
        end
    elseif x.l2 then
        g.n:SetPoint("BOTTOMLEFT", g, "LEFT", 32, 0)
        FitText(g.l2, x.l2, RVCOL_W - 32 - rtw, { 10, 9 })
        g.l2:SetPoint("TOPLEFT", g, "LEFT", 32, -2)
        g.l2:Show()
    else
        g.n:SetPoint("LEFT", g, "LEFT", 32, 0)
        g.l2:Hide()
    end
    if lines ~= 2 then g.pill:SetPoint("LEFT", g.n, "LEFT", tw + 6, 0) end
    g:SetHeight(h)
    g:Show()
    return h
end


function Rv.Decide(v, ok)
    local d = v.def
    if not d then return end
    local note = ns.Util.Trim(v.reply:GetText() or "")
    if not ok and note == "" then
        v.rsect.r:SetText(S:Wrap("WARN", "say why first"))
        v.rsect.r:Show()
        v.reply:SetFocus()
        return
    end
    if Ev():Review(d.id, ok, note ~= "" and note or nil) then
        v.reply:SetText("")
        v.reply:ClearFocus()
        state.review = nil
        ns:Print(ok and "%s is ranked now." or "%s went back to its creator.", d.name or "The event")
    end
    EventsUI:RequestRefresh()
end

function Rv.Fill(v)
    local qw = v.layout.detailW
    local queue = Ev():GetReviewQueue()
    local decided = Ev():GetDecided(4)
    -- the pick: kept while it is listed, else the first waiting / decided
    local listed = {}
    for _, d in ipairs(queue) do listed[d.id] = true end
    for _, x in ipairs(decided) do listed[x.d.id] = true end
    if not (state.review and listed[state.review]) then
        state.review = (queue[1] and queue[1].id) or (decided[1] and decided[1].d.id) or nil
    end
    -- the lists
    v.wsect:ClearAllPoints()
    v.wsect:SetPoint("TOPLEFT", v.ql, "TOPLEFT", 0, 0)
    v.wsect:SetWidth(QL_W)
    v.wsect:Set("Waiting")
    v.wsect:SetCount(#queue)
    local y, ri = 28, 0
    local function qrow(d, l2, mark, markColor, remove, tip)
        ri = ri + 1
        local r = Pool(v.qrows, ri, function() return Rv.NewQRow(v.ql) end)
        r.id = d.id
        r.remove, r.hasMark = remove, mark ~= nil
        r.del.tipText = tip
        r.del:Hide()
        r:SetWidth(QL_W)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.ql, "TOPLEFT", 0, -y)
        -- (room for the mark; the bin takes the mark's place, over the name's end, while the mouse is on the row)
        r:SetRightWidth(mark and 22 or 6)
        r:SetData({ art = d.art, icon = d.icon or QUESTION, title = d.name or "Event", sub = l2,
            selected = state.review == d.id })
        if mark then
            r.mark:SetTexture(mark)
            r.mark:SetDesaturated(markColor ~= nil)
            if markColor then r.mark:SetVertexColor(markColor[1], markColor[2], markColor[3]) else r.mark:SetVertexColor(1, 1, 1) end
            r.mark:Show()
        else
            r.mark:Hide()
        end
        r:Show()
        y = y + S.ROW.art
    end
    local canRemove = W.CanRemove()
    for _, d in ipairs(queue) do
        qrow(d, W.NewOrChanged(d) .. S:Wrap("SUB", " · ") .. Name(d.by) .. S:Wrap("SUB", " · " .. W.Ago(d.review and d.review.at)), nil, nil,
            (canRemove and Ev().DismissReview) and function() A.DismissReview(d) end or nil,
            "Takes it off the list without deciding: it can be sent in again.")
    end
    v.qnone:ClearAllPoints()
    v.qnone:SetPoint("TOPLEFT", v.ql, "TOPLEFT", 2, -(y + 6))
    v.qnone:SetText("Nothing waits for a decision.")
    v.qnone:SetShown(#queue == 0)
    if #queue == 0 then y = y + 28 end
    if #decided > 0 then
        y = y + 10
        v.dsect:ClearAllPoints()
        v.dsect:SetPoint("TOPLEFT", v.ql, "TOPLEFT", 0, -y)
        v.dsect:SetWidth(QL_W)
        v.dsect:Set("Decided")
        v.dsect:SetCount(#decided)
        y = y + 28
        for _, x in ipairs(decided) do
            local words = x.k.ok and "ranked by " or "sent back by "
            qrow(x.d, S:Wrap("SUB", words) .. Name(x.k.by) .. (x.k.ok and S:Wrap("SUB", " · " .. W.Ago(x.k.rev)) or ""),
                x.k.ok and CHECK or NOTREADY, (not x.k.ok) and { 0.7, 0.7, 0.7 } or nil,
                (canRemove and Ev().HideDecision) and function() A.HideDecision(x.d) end or nil,
                "Clears it from this list. The decision stays: a ranked event stays ranked.")
        end
    else
        v.dsect:Hide()
    end
    HideFrom(v.qrows, ri + 1)
    -- the picked one
    local d = state.review and Ev():GetDef(state.review)
    v.def = d
    local showDetail = d ~= nil
    v.ban:SetShown(showDetail)
    v.qd:SetShown(showDetail)
    v.empty:SetShown(not showDetail)
    -- (the diff list's scroll bar and its "nothing changed" are the view's: they go with it)
    if v.nochange then v.nochange:SetShown(false) end
    v.dscroll.ScrollBar:Hide()
    -- a reply typed for another event is not this one's
    if v.replyFor ~= (d and d.id) then
        v.reply:SetText("")
        v.replyFor = d and d.id
    end
    if not d then return end
    local rs = Ev():ReviewState(d)
    local waiting = rs == "review"
    -- the banner: the event's art, icon, name and pill, who sent it and when; Mark ranked / Send back while it waits
    local ban = v.ban
    ban.building = true
    ban:SetArt(H.BannerArt(d.art, qw, S.BANNER.tool, 0.6))
    ban:SetIcon(d.icon or QUESTION)
    if waiting then
        ban:SetPill("warn", W.NewOrChanged(d))
    else
        local text, kind = EUI():ReviewPill(rs)
        ban:SetPill(kind or "draft", text or "Draft")
    end
    ban:SetTitle(d.name or "Event")
    local sentAt = d.review and d.review.at or d.at
    local when = date("%Y%m%d", sentAt or 0) == date("%Y%m%d", ns.Util.Now()) and ("today " .. W.Clock(sentAt))
        or (W.Day(sentAt) .. " " .. W.Clock(sentAt))
    ban:SetSub("From " .. Name(d.by) .. S:Wrap("SUB", " · " .. when))
    ban:SetActions(waiting and { v.rankAction, v.backAction } or nil)
    ban.building = nil
    ban:Layout()
    -- the changes
    local changes, label, right, snap = Rv.Changes(d)
    v.csect:Set(label, right)
    local cw = qw
    local dy = 0
    local heights = {}
    -- one stage column for every row: as wide as its longest word (two lines past 110)
    v.meas = v.meas or UI():Text(v.qd, "small", C.grey)
    v.meas:Hide()
    local colX = 62
    for _, ch in ipairs(changes) do
        v.meas:SetText(W.DiffStage(ch))
        colX = max(colX, min(9 + 110 + 10, 9 + ceil(NatW(v.meas)) + 10))
    end
    for i, ch in ipairs(changes) do
        local r = Pool(v.diffs, i, function() return Rv.NewDiff(v.dcontent) end)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", v.dcontent, "TOPLEFT", 0, -dy)
        heights[i] = Rv.FillDiff(r, ch, d, cw, colX)
        dy = dy + heights[i] + 3
    end
    for i = #changes + 1, #v.diffs do
        local r = v.diffs[i]
        if r.pf and ns.EventPieces and ns.EventPieces.Release then ns.EventPieces:Release(r.pf) end
        r.pf = nil
        r:Hide()
    end
    if #changes == 0 then dy = 0 end
    -- the rows shown at once: what leaves the columns under them their room (the rest scroll)
    -- (what it gives first: its rows' heights, a long badge name on two lines, decide the room left)
    local gives = Rv.Gives(d, snap, waiting)
    local givesH = 0
    for i = 1, max(#gives, #v.gives) do
        local g = Pool(v.gives, i, function() return Rv.NewGive(v.right) end)
        local x = gives[i]
        if x then
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", v.right, "TOPLEFT", 0, -(28 + givesH))
            givesH = givesH + Rv.FillGive(g, x, d)
        else
            g:Hide()
        end
    end
    local k = Ev():GetReview(d.id)
    local rightH = 28 + max(28, givesH) + 6 + 22 + (k and (10 + 28 + 22 + (k.note and 18 or 0)) or 0)
    local leftH = 28 + 46 + 10 + (waiting and 56 or 0)
    local room = H.BodyH(v.layout, S.BANNER.tool) - 28 - 8 - max(rightH, leftH)
    local shownH, shown = 0, 0
    for i = 1, min(#changes, DIFF_MAX) do
        if i > 1 and shownH + heights[i] + 3 > room then break end
        shownH = shownH + heights[i] + 3
        shown = i
    end
    local scrolls = #changes > shown
    if scrolls then
        cw = qw - 12
        dy = 0
        for i, ch in ipairs(changes) do
            local r = v.diffs[i]
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", v.dcontent, "TOPLEFT", 0, -dy)
            heights[i] = Rv.FillDiff(r, ch, d, cw, colX)
            dy = dy + heights[i] + 3
        end
    end
    v.dscroll:SetSize(cw, max(1, shownH))
    v.dcontent:SetSize(cw, max(1, dy))
    v.dscroll.ScrollBar:Update()
    v.nochange = v.nochange or UI():Text(v.qd, "body", C.grey)
    v.nochange:ClearAllPoints()
    v.nochange:SetPoint("TOPLEFT", v.qd, "TOPLEFT", 2, -32)
    v.nochange:SetText("Nothing changed in its pieces.")
    v.nochange:SetShown(#changes == 0)
    -- the columns under them
    local top = 28 + (#changes == 0 and 24 or shownH) + 8
    local lw = qw - RVCOL_W - 12
    v.left:ClearAllPoints()
    v.left:SetPoint("TOPLEFT", v.qd, "TOPLEFT", 0, -top)
    v.left:SetWidth(lw)
    v.right:ClearAllPoints()
    v.right:SetPoint("TOPRIGHT", v.qd, "TOPRIGHT", 0, -top)
    local note = d.review and d.review.note
    local from = IsMe(d.by) and "Your note" or ("Note from " .. EUI():Plain(d.by))
    v.nsect:Set(from)
    v.nsect:SetShown(waiting or note ~= nil)
    local nh = 0
    if waiting or note then
        nh = Wrap(v.note.fs, note or S:Wrap("SUB", "No note."), lw - 20, 11) + 14
        v.note:SetHeight(nh)
        v.note:Show()
    else
        v.note:Hide()
    end
    local ry = 28 + nh + 10
    v.rsect:ClearAllPoints()
    v.rsect:SetPoint("TOPLEFT", v.left, "TOPLEFT", 0, -ry)
    v.rsect:SetWidth(lw)
    v.rsect:Set("Your reply")
    v.rsect.r:Hide()
    v.reply:ClearAllPoints()
    v.reply:SetPoint("TOPLEFT", v.left, "TOPLEFT", 0, -(ry + 28))
    v.reply:SetWidth(lw)
    v.rsect:SetShown(waiting)
    v.reply:SetShown(waiting)
    -- what it gives: its badges (the new ones first: they are what is asked), the scores that decide them, the
    -- season points no badge goes with
    v.gsect:Set("Rewards it gives")
    local gy = 28 + givesH
    if #gives == 0 then
        v.noGive = v.noGive or UI():Text(v.right, "body", C.grey)
        v.noGive:ClearAllPoints()
        v.noGive:SetPoint("TOPLEFT", v.right, "TOPLEFT", 2, -32)
        v.noGive:SetText("No badges, no season points.")
        v.noGive:Show()
        gy = gy + 22
    elseif v.noGive then
        v.noGive:Hide()
    end

    local passed, total, practiced = W.Checks(d)
    v.checks:ClearAllPoints()
    v.checks:SetPoint("TOPLEFT", v.right, "TOPLEFT", 0, -(gy + 6))
    v.checks.icon:SetTexture(passed == total and READY or WARN)
    v.checks.fs:SetText(passed == total and ("All " .. total .. " checks passed") or (passed .. " of " .. total
        .. " checks passed"))
    if practiced then
        v.checks.r:SetText(type(practiced) == "number" and ("practice run " .. W.Ago(practiced)) or "practice run")
        v.checks.r:SetTextColor(S:Color(C.grey))
    else
        v.checks.r:SetText("no practice run")
        v.checks.r:SetTextColor(S:Color(C.orange))
    end
    -- the last decision on it
    local k = Ev():GetReview(d.id)
    local ly = gy + 6 + 22 + 10
    v.lsect:SetShown(k ~= nil)
    v.last:SetShown(k ~= nil)
    v.lastR:SetShown(k ~= nil)
    v.lastNote:SetShown(k ~= nil and k.note ~= nil)
    if k then
        v.lsect:ClearAllPoints()
        v.lsect:SetPoint("TOPLEFT", v.right, "TOPLEFT", 0, -ly)
        v.lsect:SetWidth(RVCOL_W)
        v.lsect:Set("Last decision")
        v.last:ClearAllPoints()
        v.last:SetPoint("TOPLEFT", v.right, "TOPLEFT", 0, -(ly + 32))
        v.last:SetText((k.ok and "Ranked by " or "Sent back by ") .. Name(k.by))
        v.lastR:ClearAllPoints()
        v.lastR:SetPoint("TOPRIGHT", v.right, "TOPRIGHT", 0, -(ly + 32))
        v.lastR:SetText(W.Ago(k.rev))
        if k.note then
            v.lastNote:ClearAllPoints()
            v.lastNote:SetPoint("TOPLEFT", v.right, "TOPLEFT", 0, -(ly + 50))
            Wrap(v.lastNote, "\"" .. k.note .. "\"", RVCOL_W, 11)
        end
    end
end

---------------------------------------------------------------------------
-- Sheets: dialogs of their own over the main window or the builder (the mockup's sheet look)
---------------------------------------------------------------------------

local Sh = {}
local sheets = {}
-- The window a sheet opens over: the builder when it is open, else the main window (nil: the screen).
function Sh.Owner()
    local EB = ns.EventBuilder
    local cands = { _G.DisasterZoneEventBuilder or false, EB and EB.frame or false, EB and EB.win or false,
        EB and EB.window or false, _G.DisasterZoneMainFrame or false }
    for i = 1, #cands do
        local f = cands[i]
        if type(f) == "table" and f.IsShown and f:IsShown() then return f end
    end
    return nil
end

-- A sheet (UI:CreateSheet: over the window it belongs to, dimmed under it; Escape closes it) with the page's foot:
-- Save / Cancel, an error left of them, a grey line (f.foot, f.footIcon) at the left. f.tpill: a pill after the title;
-- f.x: its close button. The caller places its fields on f and sets f.ok's click.
function Sh.New(key, name, w, h)
    local f = UI():CreateSheet(UIParent, { name = name, width = w, height = h, owner = Sh.Owner,
        ok = { text = "Save", width = 110 }, cancel = "Cancel", foot = "" })
    f.key, f.sw, f.sh = key, w, h
    f.x = f.close
    f.tpill = H.Pill(f, 16)
    f.tpill:SetPoint("LEFT", f.title, "RIGHT", 9, 0)
    f.tpill:Hide()
    sheets[key] = f
    return f
end

-- A form label (grey) at the sheet's left.
local function FormLabel(parent, text, x, y)
    local fs = UI():Text(parent, "body", C.grey)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Field(f, w, h, maxLetters, hint)
    local eb = UI():CreateSleekEditBox(f, w, h or 26, "GameFontHighlightSmall")
    if maxLetters then eb:SetMaxLetters(maxLetters) end
    f.fields = f.fields or {}
    f.fields[#f.fields + 1] = eb
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if hint then UI():SetEditPlaceholder(eb, hint) end
    return eb
end

-- Day / time (the local clock): day 0 = today.
local DAYS_AHEAD = 13
local function NowMinutes()
    local t = date("*t", ns.Util.Now())
    return t.hour * 60 + t.min
end
local function MinMinutes(day)
    if day > 0 then return 0 end
    return ceil((NowMinutes() + 15) / 15) * 15
end
local function DayTime(day, mins)
    local t = date("*t", ns.Util.Now())
    return time({ year = t.year, month = t.month, day = t.day + day, hour = floor(mins / 60), min = mins % 60, sec = 0 })
end
local function DayOf(at)
    local t, n = date("*t", at), date("*t", ns.Util.Now())
    return floor((time({ year = t.year, month = t.month, day = t.day, hour = 12 })
        - time({ year = n.year, month = n.month, day = n.day, hour = 12 })) / DAY + 0.5), t.hour * 60 + t.min
end
local function ClampWhen(s)
    -- (s.maxDay: a calendar event moved from further out than DAYS_AHEAD keeps its day)
    s.day = min(max(s.day or 0, 0), s.maxDay or DAYS_AHEAD)
    if MinMinutes(s.day) >= 24 * 60 then s.day = s.day + 1 end
    s.mins = min(max(s.mins or 0, MinMinutes(s.day)), 24 * 60 - 15)
end
local function DayText(day)
    if day == 0 then return "Today" end
    if day == 1 then return "Tomorrow" end
    local t = DayTime(day, 12 * 60)
    return date("%a ", t) .. tonumber(date("%d", t)) .. date(" %b", t)
end

-- The event strip at the top of a sheet: a strip page banner (UI:CreatePageBanner, 56 high: the event's art, icon,
-- name with its review pill, a second line). s:Set(d) says what it is; s:SetEvent(d, sub) any second line.
local function SheetStrip(f, y, w)
    local s = UI():CreatePageBanner(f, { size = 56, width = w })
    s:SetPoint("TOPLEFT", 12, y)
    s:SetSize(w, 56)
    function s:SetEvent(d, sub)
        self.building = true
        self:SetArt(H.BannerArt(d.art, w, 56, 0.6))
        self:SetIcon(d.icon or QUESTION)
        local text, kind = EUI():ReviewPill(Ev():ReviewState(d))
        self:SetPill(kind, text)
        self:SetTitle(d.name or "Event")
        self:SetSub(sub)
        self.building = nil
        self:Layout()
    end
    function s:Set(d)
        local parts = {}
        for _, k in ipairs(B():Kinds(d)) do parts[#parts + 1] = B().SMART[k].label end
        local spots = W.Spots(d)
        if spots then parts[#parts + 1] = spots .. " spots" end
        local n = #(d.stages or {})
        parts[#parts + 1] = n .. (n == 1 and " stage" or " stages")
        self:SetEvent(d, tconcat(parts, " · "))
    end
    return s
end

-- Host it: the day, the time, where, a note --------------------------------

function Sh.Schedule()
    if sheets.schedule then return sheets.schedule end
    local f = Sh.New("schedule", "DisasterZoneEventSchedule", 460, 330)
    f.strip = SheetStrip(f, -52, 436)
    local LX, FX = 12, 76
    FormLabel(f, "When", LX, -128)
    local tip = { "Pick the time", "Click the arrows or scroll. Your clock: everybody sees it in theirs." }
    f.day = UI():CreateStepper(f, 160, function(dir)
        local s = f.s
        s.day = (s.day or 0) + dir
        ClampWhen(s)
        Sh.RefreshSchedule()
    end, { tip = tip })
    f.day:SetPoint("TOPLEFT", FX, -121)
    f.time = UI():CreateStepper(f, 96, function(dir)
        local s = f.s
        s.mins = (s.mins or 0) + dir * 15
        ClampWhen(s)
        Sh.RefreshSchedule()
    end, { tip = tip })
    f.time:SetPoint("LEFT", f.day, "RIGHT", 6, 0)
    f.whereLabel = FormLabel(f, "Where", LX, -162)
    f.where = Field(f, 372, 26, 48, "Ring of Trials, Nagrand")
    f.where:SetPoint("TOPLEFT", FX, -155)
    -- (an event with places: where everyone meets is one of them, picked here; the free text is for the others)
    f.meet = UI():CreateSleekDropdown(f, 372, function() return Sh.MeetOptions(f.s) end,
        function() return f.s and f.s.meet end, function(v)
            if f.s then f.s.meet = v end
        end)
    f.meet:SetHeight(26)
    f.meet:SetPoint("TOPLEFT", FX, -155)
    UI():AttachTooltip(f.meet, "Meet at", "Where everyone gathers before it starts: their tracker points them there "
        .. "from 30 minutes before, and the event's page shows the way.", { anchor = "ANCHOR_TOP" })
    f.meet:Hide()
    FormLabel(f, "Note", LX, -196)
    f.note = Field(f, 372, 26, 200, "Optional, e.g. \"bring a flask\"")
    f.note:SetPoint("TOPLEFT", FX, -189)
    f.info = CreateFrame("Frame", nil, f)
    f.info:SetPoint("TOPLEFT", FX, -226)
    f.info:SetSize(372, 32)
    f.info.glyph = f.info:CreateTexture(nil, "ARTWORK")
    f.info.glyph:SetSize(12, 12)
    f.info.glyph:SetPoint("TOPLEFT", 0, -1)
    f.info.fs = UI():Text(f.info, "body", C.grey)
    f.info.fs:SetPoint("TOPLEFT", 18, 0)
    f.foot:SetText("Everyone sees it on Upcoming")
    f.ok:SetScript("OnClick", function() Sh.SubmitSchedule() end)
    return f
end

-- The schedule sheet's "Meet at" choices: the event's places ("Start line · Nagrand 40, 44"), its own first.
function Sh.MeetOptions(s)
    local out = {}
    local d = s and s.def
    if not d then return out end
    local own = {}
    for _, p in ipairs(B():Defs(d, "places", true)) do
        local zone, xy = EUI():PlaceZone(p), EUI():Coords(p, 0)
        local at = (zone and xy) and (zone .. " " .. xy) or zone or xy
        local o = { value = p.id, text = (p.n or "A place") .. (at and (" · " .. at) or "") }
        if p.id == d.meet then tinsert(own, 1, o) else own[#own + 1] = o end
    end
    return own
end

function Sh.RefreshSchedule()
    local f = sheets.schedule
    local s = f and f.s
    if not s then return end
    ClampWhen(s)
    -- (Meet at for an event with places, Where for the rest)
    local places = #Sh.MeetOptions(s) > 0
    f.meet:SetShown(places)
    f.where:SetShown(not places)
    f.whereLabel:SetText(places and "Meet at" or "Where")
    if places then f.meet:Refresh() end
    local minDay = MinMinutes(0) >= 24 * 60 and 1 or 0
    f.day:Set(DayText(s.day), s.day > minDay, s.day < (s.maxDay or DAYS_AHEAD))
    f.time:Set(("%02d:%02d"):format(floor(s.mins / 60), s.mins % 60), s.mins > MinMinutes(s.day), s.mins < 24 * 60 - 15)
    -- when its sign-up closes, from its Sign-up block
    local d = s.def
    local at = DayTime(s.day, s.mins)
    local closes
    for _, bid in ipairs(B():BlocksOf(d, "signup")) do
        closes = closes or B():SmartSetting(d.blocks[bid], "closes")
    end
    local text
    if closes == "early" then
        text = "Sign-up closes 15 min before it starts, at " .. W.Clock(at - 900) .. "."
    elseif closes == "start" then
        text = "Sign-up closes when it starts. You're in it too: leave on its page if you only host."
    elseif closes == "host" then
        text = "Sign-up stays open until you close it, while it runs."
    else
        text = "It has no sign-up: whoever is there when you start it plays."
    end
    if s.occ then text = "Everyone who signed up stays in. " .. text:gsub(" You're in it too.*$", "") end
    H.Glyph(f.info.glyph, "clock", S:WithAlpha("SUB", 0.85))
    Wrap(f.info.fs, text, 354, 11)
end

function Sh.SubmitSchedule()
    local f = sheets.schedule
    local s = f and f.s
    if not s then return false end
    -- (the sheet may have stood open a while: a time that passed since moves to the first one left, and says so)
    local before = (s.day or 0) * 1440 + (s.mins or 0)
    ClampWhen(s)
    if s.day * 1440 + s.mins ~= before then
        Sh.RefreshSchedule()
        f:Error("That time has passed: moved to " .. ("%02d:%02d"):format(floor(s.mins / 60), s.mins % 60) .. ".")
        return false
    end
    local at = DayTime(s.day, s.mins)
    local where = ns.Util.Trim(f.where:GetText() or "")
    local note = ns.Util.Trim(f.note:GetText() or "")
    where = where ~= "" and where or nil
    note = note ~= "" and note or nil
    -- (an event with places meets at one of them: no free text then; its own meeting place is kept as its own)
    local places = #Sh.MeetOptions(s) > 0
    local meet
    if places then
        where = nil
        meet = s.meet
        if meet == (s.def and s.def.meet) then meet = nil end
    end
    if s.occ then
        -- (it may have changed while the sheet was open: removed, called off, started)
        local o = Ev():GetOcc(s.occ)
        local st = o and Ev():OccState(o)
        local why = (not o and "It's gone from the calendar.") or (st == "cancelled" and "It was cancelled.")
            or (st == "live" and "It's running: it can't move now.") or (st == "done" and "It's over.")
            or (Ev():HostOf(o) ~= Me() and "Only its host can move it.") or nil
        -- (meet: a place of its own, false back to the event's own, nil as it was: events without places)
        local meetArg
        if places then meetArg = meet or false end
        if why or not Ev():EditOcc(s.occ, at, where, note, meetArg) then
            f:Error(why or "Only its host can move it.")
            return false
        end
        f:Close()
        EventsUI:RequestRefresh()
        return s.occ
    end
    local d = Ev():GetDef(s.defId)
    if not d then
        f:Error("It's gone from the library.")
        return false
    end
    -- (it couldn't start: the builder's Host says the same)
    if #B():Problems(d) > 0 then
        f:Error("Some of its pieces need fixing first: open it in the builder.")
        return false
    end
    local occ = Ev():Schedule(s.defId, at, { where = where, note = note, meet = meet })
    if not occ then
        f:Error("The calendar is full right now.")
        return false
    end
    f:Close()
    ns:Print("%s is on the calendar: %s %s.", s.def.name or "The event", DayText(s.day), W.Clock(at))
    if ns.MainFrame and ns.MainFrame:IsShown() and ns.MainFrame:GetSelectedTab() == "events" then
        EventsUI:OpenEvent(occ)
    end
    return occ
end

function EventsUI:OpenSchedule(defId, occId)
    local o = occId and Ev():GetOcc(occId)
    local d = (o and o.def) or Ev():GetDef(defId)
    if not d then
        ns:Print("save the event first: only events in the library can be hosted.")
        return false
    end
    local f = Sh.Schedule()
    local s = { defId = defId or (o and o.dk), occ = o and o.id or nil, def = d }
    if o then
        s.day, s.mins = DayOf(o.at)
        s.mins = s.mins - s.mins % 15
        s.maxDay = max(DAYS_AHEAD, s.day)
    else
        -- the first suggestion: 20:00 today, or tomorrow when that is too close
        s.day, s.mins = 0, 20 * 60
        if MinMinutes(0) > 20 * 60 then s.day = 1 end
    end
    f.s = s
    f.title:SetText(o and "Move your event" or "Host an event")
    f.ok:SetText(o and "Save" or "Put it on the calendar")
    H.Fit(f.ok, 110, 30)
    f.strip:Set(d)
    f.where:SetText(o and o.where or "")
    f.note:SetText(o and o.note or "")
    -- (where everyone meets: the calendar event's own choice, else its event's, else its first place)
    s.meet = (o and Ev():MeetOf(o)) or d.meet
    if not s.meet then
        local first = Sh.MeetOptions(s)[1]
        s.meet = first and first.value or nil
    end
    f:Open()
    Sh.RefreshSchedule()
    return true
end

-- Send for review: the checks and a note ------------------------------------

function Sh.Submit()
    if sheets.submit then return sheets.submit end
    local f = Sh.New("submit", "DisasterZoneEventSubmit", 560, 352)
    f.title:SetText("Send for review")
    f.strip = SheetStrip(f, -52, 536)
    f.csect = H.Sect(f)
    f.csect:SetPoint("TOPLEFT", 14, -114)
    f.csect:SetPoint("TOPRIGHT", -14, -114)
    f.csect:Set("Checks")
    f.rows = {}
    for i = 1, 4 do
        local r = CreateFrame("Frame", nil, f)
        r:SetHeight(22)
        r:SetPoint("TOPLEFT", 14, -(142 + (i - 1) * 22))
        r:SetPoint("TOPRIGHT", -14, -(142 + (i - 1) * 22))
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(13, 13)
        r.icon:SetPoint("LEFT", 2, 0)
        r.fs = UI():Text(r, "emph", C.label)
        r.fs:SetPoint("LEFT", 24, 0)
        r.r = UI():Text(r, "body", C.grey)
        r.r:SetJustifyH("RIGHT")
        r.r:SetPoint("RIGHT", 0, 0)
        f.rows[i] = r
    end
    f.nsect = H.Sect(f)
    f.nsect:SetPoint("TOPLEFT", 14, -236)
    f.nsect:SetPoint("TOPRIGHT", -14, -236)
    f.nsect:Set("Note for the reviewers")
    f.note = Field(f, 532, 26, 200, "What's new, what to look at")
    f.note:SetPoint("TOPLEFT", 14, -266)
    f.foot:SetText("Goes to the GM, officers and the guild council")
    f.ok:SetText("Send for review")
    H.Fit(f.ok, 110, 30)
    f.ok:SetScript("OnClick", function() Sh.SubmitReview() end)
    return f
end

function Sh.SubmitReview()
    local f = sheets.submit
    local d = f and f.def and Ev():GetDef(f.def.id)
    if not d then
        f:Error("Save the event in the builder first.")
        return false
    end
    if Ev():ReviewState(d) == "ranked" then
        f:Error("It's ranked already.")
        return false
    end
    if #B():Problems(d) > 0 then
        f:Error("Fix the pieces marked in the builder first.")
        return false
    end
    if B():MaxSeasonGrant(d) > B().SEASON_CAP then
        f:Error("One piece gives more than " .. B().SEASON_CAP .. " season points.")
        return false
    end
    local note = ns.Util.Trim(f.note:GetText() or "")
    if not Ev():SubmitForReview(d.id, note ~= "" and note or nil) then
        f:Error("Only its creator sends it in.")
        return false
    end
    f:Close()
    ns:Print("%s went to the reviewers.", d.name or "The event")
    EventsUI:RequestRefresh()
    return true
end

function EventsUI:OpenSubmit(defId)
    local d = Ev():GetDef(defId)
    if not d then
        ns:Print("save the event first, then send it in.")
        return false
    end
    local f = Sh.Submit()
    f.def = d
    local snap = Ev():RankedSnapshot(d.id)
    local nb, newB, titles = 0, 0, 0
    for id, bd in pairs(d.badges or {}) do
        nb = nb + 1
        if snap and not (snap.badges and snap.badges[id]) then newB = newB + 1 end
        if bd.ti and bd.ti ~= "" then titles = titles + 1 end
    end
    local stages, pieces = #(d.stages or {}), W.PieceCount(d)
    local parts = { stages .. (stages == 1 and " stage" or " stages"), pieces .. (pieces == 1 and " piece" or " pieces"),
        nb == 0 and "no badges" or (nb .. (nb == 1 and " badge" or " badges") .. ((snap and newB > 0) and (" (" .. newB
        .. " new)") or "")) }
    if titles > 0 then parts[#parts + 1] = titles .. (titles == 1 and " title" or " titles") end
    f.strip:SetEvent(d, tconcat(parts, " · "))
    local _, _, practiced, blanks, cap = W.Checks(d)
    local probs = #B():Problems(d)
    local grants = W.Grants(d)
    local rows = {
        { practiced and true or false, practiced and ("Practice run went through all " .. stages .. " stages")
            or "No practice run of this version yet", practiced and (type(practiced) == "number" and W.Ago(practiced)
            or "") or "start one in the builder" },
        { blanks, blanks and "Every blank is filled" or (probs .. (probs == 1 and " piece needs" or " pieces need")
            .. " fixing"), blanks and "" or "marked in the builder" },
        -- (the addon shows its messages itself; guild chat is its one way out, held to a post every 10 s, 20 a run)
        { true, "Guild chat stays under the limit", W.GuildPosts(d) == 0 and "no guild posts"
            or "a post every 10 s at most" },
        { cap, cap and "Points stay under the season cap" or "A piece gives too many season points",
            #grants > 0 and tconcat(grants, " / ", 1, min(#grants, 5)) or "no season points" },
    }
    for i, r in ipairs(f.rows) do
        local x = rows[i]
        r.icon:SetTexture(x[1] and READY or WARN)
        r.fs:SetText(x[2])
        r.fs:SetTextColor(S:Color(x[1] and C.label or { 1, 0.78, 0.55 }))
        r.r:SetText(x[3] or "")
    end
    f.note:SetText(d.review and d.review.note or "")
    f:Open()
    return true
end

-- The badge designer --------------------------------------------------------

-- Icons to pick from: weapons and duels, shields, crowns and medals, banners, mounts, fishing, pirates, dragons...
-- (the words after each help the search).
local BADGE_ICONS = {
    { "Ability_Warrior_Challange", "duel sword challenge" }, { "Ability_DualWield", "duel swords" },
    { "INV_Sword_39", "sword blade" }, { "INV_Sword_27", "sword blade" }, { "INV_Sword_04", "sword blade" },
    { "Ability_Parry", "parry sword duel" }, { "Ability_Warrior_Riposte", "riposte sword duel" },
    { "INV_Axe_09", "axe weapon" }, { "INV_Weapon_Bow_07", "bow weapon hunt" }, { "INV_Staff_13", "staff weapon" },
    { "INV_Shield_06", "shield" }, { "INV_Gauntlets_04", "fist gauntlet brawl" }, { "INV_Helmet_66", "helm" },
    { "INV_Crown_01", "crown king queen" }, { "INV_Crown_02", "crown king queen" },
    { "INV_Jewelry_TrinketPVP_01", "medal pvp trinket" }, { "INV_Jewelry_TrinketPVP_02", "medal pvp trinket" },
    { "INV_Jewelry_Talisman_07", "medal talisman" }, { "INV_Misc_Coin_01", "coin gold" },
    { "INV_BannerPVP_01", "banner flag" }, { "INV_BannerPVP_02", "banner flag" }, { "INV_Banner_03", "banner flag" },
    { "Achievement_Arena_2v2_7", "arena pvp" }, { "Spell_Holy_SealOfValor", "holy valor" },
    { "Spell_Holy_Heroism", "hero holy" }, { "Spell_Holy_ChampionsGrace", "champion holy" },
    { "Ability_Warrior_BattleShout", "shout battle" }, { "Ability_Warrior_RallyingCry", "rally cry" },
    { "Ability_Mount_RidingHorse", "mount horse race ride" }, { "Ability_Mount_WhiteTiger", "mount tiger race ride" },
    { "Ability_Mount_JungleTiger", "mount tiger race ride" }, { "Ability_Mount_Raptor", "mount raptor race ride" },
    { "Ability_Mount_Gryphon_01", "mount gryphon flying race" }, { "Ability_Mount_NightmareHorse", "mount horse race" },
    { "Trade_Fishing", "fishing fish" }, { "INV_Misc_Fish_02", "fish fishing" }, { "INV_Misc_Fish_14", "fish fishing" },
    { "INV_Misc_Bandana_03", "pirate bandana" }, { "INV_Misc_Spyglass_02", "pirate spyglass" },
    { "INV_Misc_Map_01", "pirate treasure map hunt" }, { "INV_Misc_Bomb_01", "bomb" },
    { "INV_Misc_Head_Dragon_01", "dragon upset" }, { "INV_Misc_MonsterHead_02", "monster head" },
    { "INV_Misc_Bone_ElfSkull_01", "skull bone" }, { "Ability_Rogue_Sprint", "sprint race fast run" },
    { "Ability_Stealth", "stealth hide seek" }, { "INV_Misc_Gift_01", "gift prize" },
    { "INV_Misc_Ticket_Darkmoon_01", "ticket fair darkmoon" },
}
local ICON_COLS, ICON_SIZE, ICON_GAP = 8, 30, 4

function Sh.Badge()
    if sheets.badge then return sheets.badge end
    local f = Sh.New("badge", "DisasterZoneBadgeDesigner", 600, 506)
    f.tpill:SetKind("needs review", "warn")
    -- the preview: the badge big, its name and title, how it reads on a player's tooltip
    local pv = CreateFrame("Frame", nil, f)
    pv:SetPoint("TOPLEFT", 1, -41)
    pv:SetPoint("BOTTOMLEFT", 1, 47)
    pv:SetWidth(236)
    -- a soft gold light from the top, strongest behind the badge (kept inside the panel)
    pv.light = pv:CreateTexture(nil, "BACKGROUND", nil, 0)
    pv.light:SetPoint("TOPLEFT")
    pv.light:SetPoint("TOPRIGHT")
    pv.light:SetHeight(260)
    UI():Gradient(pv.light, "VERTICAL", S:WithAlpha("GOLD", 0), S:WithAlpha("GOLD", 0.05))
    pv.glows = {}
    for i, size in ipairs({ 140, 118, 100 }) do
        local t = Disc(pv, size, S:WithAlpha("GOLD", 0.045), "BACKGROUND", i)
        t:SetPoint("CENTER", pv, "TOP", 0, -70)
        pv.glows[i] = t
    end
    pv.line = Line(f, "HAIRLINE")
    pv.line:SetWidth(1)
    pv.line:SetPoint("TOPLEFT", pv, "TOPRIGHT", 0, 0)
    pv.line:SetPoint("BOTTOMLEFT", pv, "BOTTOMRIGHT", 0, 0)
    pv.badge = H.Badge(pv, 72)
    pv.badge:SetPoint("TOP", 0, -24)
    pv.badge.noTip = true
    pv.n = UI():Text(pv, 15, C.white)
    pv.n:SetJustifyH("CENTER")
    pv.n:SetPoint("TOP", pv.badge, "BOTTOM", 0, -14)
    pv.ti = UI():Text(pv, "body", C.gold)
    pv.ti:SetJustifyH("CENTER")
    pv.ti:SetPoint("TOP", pv.n, "BOTTOM", 0, -5)
    local tt = CreateFrame("Frame", nil, pv)
    tt:SetSize(196, 92)
    tt:SetPoint("TOP", pv.badge, "BOTTOM", 0, -64)
    UI():Fill(tt, { 0.03, 0.03, 0.047, 0.96 })
    Edges(tt, { 0.59, 0.59, 0.67, 0.85 })
    tt.l1 = UI():Text(tt, "emph", C.white)
    tt.l1:SetPoint("TOPLEFT", 10, -9)
    tt.l2 = UI():Text(tt, "emph", { 0.66, 0.66, 0.66 })
    tt.l2:SetPoint("TOPLEFT", tt.l1, "BOTTOMLEFT", 0, -3)
    tt.sep = Line(tt, { 1, 1, 1, 0.12 })
    tt.sep:SetHeight(1)
    tt.sep:SetPoint("TOPLEFT", 10, -45)
    tt.sep:SetPoint("TOPRIGHT", -10, -45)
    tt.l3 = UI():Text(tt, "emph", C.gold)
    tt.l3:SetPoint("TOPLEFT", 10, -53)
    tt.l4 = UI():Text(tt, "body", { 0.66, 0.66, 0.66 })
    tt.l4:SetPoint("TOPLEFT", tt.l3, "BOTTOMLEFT", 0, -3)
    pv.tt = tt
    f.pv = pv
    -- the form
    local FX, LX = 236 + 16 + 62, 236 + 16
    local FW = 600 - FX - 16
    FormLabel(f, "Name", LX, -62)
    f.name = Field(f, FW, 26, 32, "What it's for")
    f.name:SetPoint("TOPLEFT", FX, -55)
    f.name:SetScript("OnTextChanged", function(self)
        if f.s then f.s.n = self:GetText() end
        Sh.RefreshBadge()
    end)
    FormLabel(f, "Icon", LX, -99)
    f.search = UI():CreateSearchBox(f, FW, function(text)
        if f.s then f.s.q = text end
        Sh.RefreshBadge()
    end, "Search icons: sword, mount, fish ...")
    f.search:SetHeight(24)
    f.search:SetPoint("TOPLEFT", FX, -93)
    f.search:SetWidth(FW)
    f.cells = {}
    f.gridY = -127
    f.gridX = FX
    f.frameLabel = FormLabel(f, "Frame", LX, -350)
    f.swatches = {}
    for i, fr in ipairs(B().FRAMES) do
        local key = fr[1]
        local sw = CreateFrame("Button", nil, f)
        sw:SetSize(31, 31)
        sw:SetPoint("TOPLEFT", FX + (i - 1) * 38, -341)
        sw.sel = Disc(sw, 33, S:WithAlpha("GOLD_DEEP", 0.9), "BACKGROUND", 1)
        sw.sel:SetPoint("CENTER")
        sw.hole = Disc(sw, 31, { 0.09, 0.09, 0.11, 1 }, "BACKGROUND", 2)
        sw.hole:SetPoint("CENTER")
        sw.badge = H.Badge(sw, 19)
        sw.badge:SetPoint("CENTER")
        sw.badge:EnableMouse(false)
        sw:SetScript("OnClick", function()
            if f.s then f.s.f = key end
            Sh.RefreshBadge()
        end)
        UI():AttachTooltip(sw, fr[2] .. " frame", nil, { anchor = "ANCHOR_TOP" })
        sw.key = key
        f.swatches[i] = sw
    end
    FormLabel(f, "Title", LX, -393)
    f.tiSwitch = UI():CreateSwitch(f, function() return f.s and f.s.tiOn end, function(on)
        if f.s then f.s.tiOn = on end
        if on and ns.Util.Trim(f.title2:GetText() or "") == "" then f.title2:SetFocus() end
        Sh.RefreshBadge()
    end)
    f.tiSwitch:SetPoint("TOPLEFT", FX, -390)
    f.title2 = Field(f, FW - 46, 26, 24, "the Duelist")
    f.title2:SetPoint("TOPLEFT", FX + 46, -386)
    f.title2:SetScript("OnTextChanged", function(self)
        if f.s then f.s.ti = self:GetText() end
        Sh.RefreshBadge()
    end)
    f.hint = UI():Text(f, "body", C.grey)
    f.hint:SetPoint("TOPLEFT", FX, -420)
    Wrap(f.hint, "Shown after the name on tooltips. Players pick the one they show on the Season page.", FW, 11)
    f.footIcon:Show()
    f.foot:ClearAllPoints()
    f.foot:SetPoint("LEFT", f.footIcon, "RIGHT", 7, 0)
    f.ok:SetText("Save badge")
    H.Fit(f.ok, 100, 30)
    f.ok:SetScript("OnClick", function() Sh.SaveBadge() end)
    return f
end

-- The icons the search keeps (the badge's own icon first when it is not one of them).
function Sh.BadgeIcons(s)
    local q = ns.Util.Trim(s.q or ""):lower()
    local out, seen = {}, {}
    local function add(path)
        if not seen[path:lower()] then
            seen[path:lower()] = true
            out[#out + 1] = path
        end
    end
    if s.i and q == "" then add(s.i) end
    for _, x in ipairs(BADGE_ICONS) do
        local path = "Interface\\Icons\\" .. x[1]
        if q == "" or (x[1] .. " " .. x[2]):lower():find(q, 1, true) then add(path) end
    end
    return out
end

-- A badge's name / title as the guild stores it (no colour or texture codes, no line breaks), trimmed.
function W.CleanText(t)
    return (ns.Util.Trim(((t or ""):gsub("[%c|]", ""))))
end

function Sh.RefreshBadge()
    local f = sheets.badge
    local s = f and f.s
    if not s then return end
    local bd = { n = W.CleanText(s.n), i = s.i, f = s.f, ti = s.tiOn and W.CleanText(s.ti) or nil }
    local pv = f.pv
    pv.badge:SetBadge({ n = bd.n, i = bd.i, f = bd.f })
    local _, nh = FitText(pv.n, bd.n ~= "" and bd.n or S:Wrap("DIM", "Badge name"), 220, { 15, 13 })
    pv.ti:SetText((bd.ti and bd.ti ~= "") and ("\"" .. bd.ti .. "\"") or "")
    local me = Me()
    local who = EUI():Plain(me)
    pv.tt.l1:SetText(who .. ((bd.ti and bd.ti ~= "") and (" " .. S:Wrap("GOLD", bd.ti)) or ""))
    local race = UnitRace and UnitRace("player") or ""
    local cls = UnitClass and UnitClass("player") or ""
    pv.tt.l2:SetText(("Level %d %s %s"):format(UnitLevel and UnitLevel("player") or 70, race or "", cls or ""))
    pv.tt.l3:SetText(bd.n ~= "" and bd.n or "Badge name")
    pv.tt.l4:SetText((s.def and s.def.name or "Event") .. " · " .. date("%d %b", ns.Util.Now()))
    -- (the tooltip as the game draws one: as wide as its longest line, up to the panel's; a longer line wraps)
    local tt = pv.tt
    local need = 176
    for _, fs in ipairs({ tt.l1, tt.l2, tt.l3, tt.l4 }) do need = max(need, ceil(NatW(fs))) end
    local inner = min(196, need)
    tt:SetWidth(inner + 20)
    tt:ClearAllPoints()
    tt:SetPoint("TOP", pv.badge, "BOTTOM", 0, -(14 + nh + 32))
    local y = 9
    for i, fs in ipairs({ tt.l1, tt.l2, tt.l3, tt.l4 }) do
        local _, h = FitText(fs, fs:GetText(), inner, i == 4 and 11 or 12)
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", tt, "TOPLEFT", 10, -y)
        y = y + h + 3
        if i == 2 then
            tt.sep:ClearAllPoints()
            tt.sep:SetPoint("TOPLEFT", tt, "TOPLEFT", 10, -y)
            tt.sep:SetPoint("TOPRIGHT", tt, "TOPRIGHT", -10, -y)
            y = y + 8
        end
    end
    tt:SetHeight(y + 4)
    -- the icons
    local icons = Sh.BadgeIcons(s)
    for i = 1, max(#icons, #f.cells) do
        local c = Pool(f.cells, i, function()
            local b = CreateFrame("Button", nil, f)
            b:SetSize(ICON_SIZE, ICON_SIZE)
            b.sel = UI():Fill(b, S.C.GOLD, "BACKGROUND")
            b.sel:ClearAllPoints()
            b.sel:SetPoint("TOPLEFT", -2, 2)
            b.sel:SetPoint("BOTTOMRIGHT", 2, -2)
            b.edge = UI():Fill(b, C.black, "BACKGROUND", 1)
            b.edge:ClearAllPoints()
            b.edge:SetPoint("TOPLEFT", -1, 1)
            b.edge:SetPoint("BOTTOMRIGHT", 1, -1)
            b.tex = b:CreateTexture(nil, "ARTWORK")
            b.tex:SetAllPoints()
            b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            b.hl = b:CreateTexture(nil, "HIGHLIGHT")
            b.hl:SetAllPoints()
            b.hl:SetColorTexture(1, 1, 1, 0.15)
            b:SetScript("OnClick", function(self)
                if f.s then f.s.i = self.path end
                Sh.RefreshBadge()
            end)
            return b
        end)
        local path = icons[i]
        if path and i <= ICON_COLS * 6 then
            local col, row = (i - 1) % ICON_COLS, floor((i - 1) / ICON_COLS)
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", f, "TOPLEFT", f.gridX + col * (ICON_SIZE + ICON_GAP), f.gridY - row * (ICON_SIZE + ICON_GAP))
            c.path = path
            c.tex:SetTexture(path)
            c.sel:SetShown(s.i and path:lower() == s.i:lower())
            c:Show()
        else
            c:Hide()
        end
    end
    f.noIcon = f.noIcon or UI():Text(f, "body", C.grey)
    f.noIcon:ClearAllPoints()
    f.noIcon:SetPoint("TOPLEFT", f, "TOPLEFT", f.gridX + 2, f.gridY - 6)
    f.noIcon:SetText("No icon matches that word.")
    f.noIcon:SetShown(#icons == 0)
    for _, sw in ipairs(f.swatches) do
        sw.badge:SetBadge({ i = s.i, f = sw.key })
        sw.badge.noTip = true
        sw.sel:SetShown(s.f == sw.key)
    end
    f.tiSwitch:SetOn(s.tiOn and true or false)
    f.title2:SetAlpha(s.tiOn and 1 or 0.45)
end

function Sh.SaveBadge()
    local f = sheets.badge
    local s = f and f.s
    if not s then return false end
    local n = W.CleanText(s.n)
    if n == "" then
        f:Error("Give it a name.")
        f.name:SetFocus()
        return false
    end
    -- (two badges of one event by the same name: the results and the standings couldn't tell them apart)
    for id, other in pairs(s.def and s.def.badges or {}) do
        if id ~= s.id and W.CleanText(other.n):lower() == n:lower() then
            f:Error("Another badge of this event has that name.")
            f.name:SetFocus()
            return false
        end
    end
    local ti = s.tiOn and W.CleanText(s.ti) or ""
    local id = s.id
    if not id then
        local used = s.def and s.def.badges or {}
        local i = 1
        while used["b" .. i] do i = i + 1 end
        id = "b" .. i
    end
    local out = { n = n, i = s.i or QUESTION, f = s.f or "gold", ti = ti ~= "" and ti or nil }
    local cb = s.onSave
    f.s = nil
    f:Close()
    if cb then cb(id, out) end
    return id, out
end

function EventsUI:OpenBadgeDesigner(def, badgeId, onSave)
    local f = Sh.Badge()
    local cur = def and def.badges and badgeId and def.badges[badgeId]
    f.s = { def = def, id = cur and badgeId or nil, n = cur and cur.n or "", i = cur and cur.i or
        "Interface\\Icons\\Ability_Warrior_Challange", f = cur and cur.f or "gold", ti = cur and cur.ti or "",
        tiOn = cur and cur.ti and cur.ti ~= "" or false, q = "", onSave = onSave }
    f.title:SetText(cur and "Edit badge" or "New badge")
    f.tpill:Show()
    f.name:SetText(f.s.n)
    f.title2:SetText(f.s.ti or "")
    f.search:SetText("")
    f.footIcon:SetTexture(def and def.icon or QUESTION)
    f.foot:SetText("Given by " .. (def and def.name or "this event"))
    f:Open()
    Sh.RefreshBadge()
    if not cur then f.name:SetFocus() end
    return true
end

-- The season (officers): its name, first and last day --------------------

function Sh.Season()
    if sheets.season then return sheets.season end
    local f = Sh.New("season", "DisasterZoneEventSeason", 420, 244)
    f.title:SetText("The season")
    local LX, FX = 14, 76
    FormLabel(f, "Name", LX, -62)
    f.name = Field(f, 330, 26, 32, "Season 1")
    f.name:SetPoint("TOPLEFT", FX, -55)
    local tip = { "Pick the day", "Click the arrows or scroll." }
    FormLabel(f, "From", LX, -100)
    f.from = UI():CreateStepper(f, 160, function(dir)
        f.s.from = W.Noon(f.s.from + dir * DAY)
        if f.s.from > f.s.to - DAY then f.s.from = f.s.to - DAY end
        Sh.RefreshSeason()
    end, { tip = tip })
    f.from:SetPoint("TOPLEFT", FX, -93)
    FormLabel(f, "To", LX, -134)
    f.to = UI():CreateStepper(f, 160, function(dir)
        f.s.to = W.Noon(f.s.to + dir * DAY)
        if f.s.to < f.s.from + DAY then f.s.to = f.s.from + DAY end
        Sh.RefreshSeason()
    end, { tip = tip })
    f.to:SetPoint("TOPLEFT", FX, -127)
    f.info = UI():Text(f, "body", C.grey)
    f.info:SetPoint("TOPLEFT", FX, -166)
    f.foot:SetText("Ranked events in it count")
    f.ok:SetText("Save")
    f.ok:SetScript("OnClick", function()
        local s = f.s
        local name = ns.Util.Trim(f.name:GetText() or "")
        if name == "" then
            f:Error("Give it a name.")
            return
        end
        local from = time({ year = tonumber(date("%Y", s.from)), month = tonumber(date("%m", s.from)),
            day = tonumber(date("%d", s.from)), hour = 0 })
        local to = time({ year = tonumber(date("%Y", s.to)), month = tonumber(date("%m", s.to)),
            day = tonumber(date("%d", s.to)), hour = 23, min = 59, sec = 59 })
        -- (the standings only ever show the season today is in: one that isn't wouldn't show)
        if from > ns.Util.Now() or to < ns.Util.Now() then
            f:Error("Pick days that take in today.")
            return
        end
        if Ev():SetSeason(name, from, to) then
            f:Close()
            EventsUI:RequestRefresh()
        else
            f:Error("Only the GM and officers set the season.")
        end
    end)
    return f
end

function Sh.RefreshSeason()
    local f = sheets.season
    local s = f and f.s
    if not s then return end
    f.from:Set(date("%a %d %b %Y", s.from), true, true)
    f.to:Set(date("%a %d %b %Y", s.to), true, true)
    local days = floor((W.Noon(s.to) - W.Noon(s.from)) / DAY + 0.5) + 1
    f.info:SetText(days .. " days")
end

function EventsUI:OpenSeasonSheet()
    if not Ev():CanModerate(Me()) then
        ns:Print("only the GM and officers set the season.")
        return false
    end
    local season = Ev():GetSeason()
    local f = Sh.Season()
    f.s = { from = W.Noon(season.from), to = W.Noon(season.to) }
    f.name:SetText(season.n or "")
    f:Open()
    Sh.RefreshSeason()
    return true
end

-- A confirm (Cancel an event, Delete results): title, text, an optional reason, the button --------

function Sh.Confirm()
    if sheets.confirm then return sheets.confirm end
    local f = Sh.New("confirm", "DisasterZoneEventConfirm", 420, 200)
    f.text = UI():Text(f, "emph", C.text)
    f.text:SetPoint("TOPLEFT", 14, -56)
    f.reasonLabel = FormLabel(f, "Why", 14, -112)
    f.reason = Field(f, 344, 26, 80, "Not enough players")
    f.reason:SetPoint("TOPLEFT", 62, -105)
    f.cancel:SetText("Keep it")
    f.ok:SetScript("OnClick", function()
        local o = f.opts
        f:Close()
        if o and o.fn then o.fn(ns.Util.Trim(f.reason:GetText() or "")) end
    end)
    return f
end

-- opts = { title, text, yes, danger, reason (a placeholder: asks why), fn(reason) }.
function EventsUI:Confirm(opts)
    local f = Sh.Confirm()
    f.opts = opts
    FitText(f.title, opts.title or "Sure?", 420 - 12 - 34, { 14, 13, 12 })
    Wrap(f.text, opts.text or "", 392, 12)
    f.reason:SetText("")
    f.reason:SetShown(opts.reason ~= nil)
    f.reasonLabel:SetShown(opts.reason ~= nil)
    if opts.reason then UI():SetEditPlaceholder(f.reason, opts.reason) end
    f.ok:SetText(opts.yes or "OK")
    f.ok:SetKind(opts.danger and "danger" or "primary")
    H.Fit(f.ok, 100, 30)
    f.foot:SetText("")
    f:Open()
    return true
end

function EventsUI:ConfirmCancel(occId)
    local o = Ev():GetOcc(occId)
    if not o then return false end
    return self:Confirm({ title = "Cancel " .. (o.def.name or "the event") .. "?", text = "It comes off the calendar for "
        .. "everyone. Those who signed up see it was cancelled, and why.", yes = "Cancel event", danger = true,
        reason = "Not enough players", fn = function(reason)
            -- (it may have started or ended while the sheet was open: a run isn't cancelled from here)
            local cur = Ev():GetOcc(occId)
            local st = cur and Ev():OccState(cur)
            if st ~= "planned" and st ~= "missed" then
                if st == "live" then ns:Print("%s has started: it can't be cancelled now.", o.def.name or "The event") end
                EventsUI:RequestRefresh()
                return
            end
            if Ev():CancelOcc(occId, reason ~= "" and reason or nil) then
                ns:Print("%s is cancelled.", o.def.name or "The event")
            end
            EventsUI:RequestRefresh()
        end })
end

---------------------------------------------------------------------------
-- The panel: the views' tabs, Refresh, what other modules call
---------------------------------------------------------------------------

local VIEWS = { "upcoming", "library", "season", "review" }
local VIEW_LABEL = { upcoming = "Upcoming", library = "Library", season = "Season", review = "Review" }
local MAKE = { upcoming = Up.Create, library = Lib.Create, season = Sea.Create, review = Rv.Create, event = Pg.Create }
local FILL = { upcoming = Up.Fill, library = Lib.Fill, season = Sea.Fill, review = Rv.Fill }

-- The Review tab's count of events waiting: a small raised pill after its word (the toolbar's SetTabCount).
local function ReviewCount(bar, n)
    bar:SetTabCount("review", n)
end

-- The Review tab's tooltip: how many wait.
local function ReviewTip(self, tt)
    local n = #Ev():GetReviewQueue()
    tt:AddLine("Review", S:RGB("GOLD"))
    tt:AddLine(n > 0 and (n .. (n == 1 and " event waits" or " events wait") .. " for a decision: ranked or sent back.")
        or "Events members send in for review show up here.", 1, 1, 1, true)
end

-- 1.4: the tab is a Board page (UI:CreateLayout): its toolbar holds the views as tabs, Examples and the main action
-- New event at the far right; each view under it is a layout of its own (Upcoming / Library / Season: boards, Review:
-- a list + detail, an event's page: a detail page under the same toolbar).
function EventsUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneEventsPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.views = {}
    p.layout = UI():CreateLayout("board", p)
    local bar = p.layout.toolbar
    p.toolbar = bar
    local items = {}
    for _, view in ipairs(VIEWS) do items[#items + 1] = { key = view, text = VIEW_LABEL[view] } end
    bar:SetTabs(items, function(key) EventsUI:SetView(key) end)
    p.tabs = {}
    for _, view in ipairs(VIEWS) do p.tabs[view] = bar:GetTab(view) end
    bar:SetTabCount("review", 0)
    UI():AttachTooltip(p.tabs.review, ReviewTip, nil, { anchor = "ANCHOR_BOTTOM" })
    -- (its plus as a glyph beside the words: the button's text stays "New event")
    p.newBtn = bar:SetPrimary({ text = "New event", icon = "plus", onClick = A.NewEvent,
        tip = "Opens the builder on an empty event: drag pieces in, practice it, save it." })
    H.Fit(p.newBtn, 90, 30)
    -- Examples beside it: Upcoming's (p.exBtn) and the Library's (its view's .examples)
    p.exBtn = A.ExamplesButton(bar, S.BTN_H)
    p.libExBtn = A.ExamplesButton(bar, S.BTN_H)
    p.libExBtn:Hide()
    bar:SetFilters({ p.exBtn, p.libExBtn })
    p:SetScript("OnShow", function() EventsUI:Refresh() end)
    p.OnPanelShown = function() EventsUI:Refresh() end
    p.elapsed = 0
    p:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed >= 30 then
            self.elapsed = 0
            EventsUI:Refresh()
        end
    end)
    return p
end

local function ViewFrame(key)
    local v = panel.views[key]
    if not v then
        v = MAKE[key](panel)
        panel.views[key] = v
    end
    return v
end

function EventsUI:Refresh()
    if not panel or not panel:IsVisible() then return end
    W.DressAll()
    local reviewer = Ev():AmIReviewer()
    if state.view == "review" and not reviewer then state.view = "upcoming" end
    local onPage = state.occ ~= nil
    local bar = panel.toolbar
    for _, view in ipairs(VIEWS) do
        bar:SetTabShown(view, view ~= "review" or reviewer)
    end
    -- (an event's page keeps the toolbar: the view it was opened from stays lit, its banner has the way back)
    bar:SelectTab(state.view)
    if reviewer then ReviewCount(bar, #Ev():GetReviewQueue()) end
    panel.newBtn:SetShown(not onPage and (state.view == "upcoming" or state.view == "library"))
    panel.exBtn:SetShown(not onPage and state.view == "upcoming")
    panel.libExBtn:SetShown(not onPage and state.view == "library")
    bar:LayoutRight()

    local key = onPage and "event" or state.view
    for k, v in pairs(panel.views) do
        if k ~= key then v:Hide() end
    end
    local v = ViewFrame(key)
    v:Show()
    if onPage then
        if not Pg.Fill(v) then
            -- (the event is gone: back to the view it was opened from)
            state.occ = nil
            return self:Refresh()
        end
        return
    end
    FILL[key](v)
end

local refreshDue   -- (a refresh waits: the latest it runs)
function EventsUI:RequestRefresh(delay)
    if panel and panel:IsVisible() then
        -- (each request pushes the wait back, but no further than a second after the first one)
        local now = GetTime()
        refreshDue = refreshDue or (now + 1)
        ns.Util.Debounce("events-ui", min(delay or 0.15, max(0, refreshDue - now)), function()
            refreshDue = nil
            EventsUI:Refresh()
        end)
    end
end

-- "upcoming" | "library" | "season" | "review" (reviewers): the tab's view (the event page closes).
function EventsUI:SetView(view)
    if view ~= "library" and view ~= "season" and view ~= "review" then view = "upcoming" end
    state.view = view
    state.occ = nil
    self:Refresh()
end

function EventsUI:GetView() return state.occ and "event" or state.view end

-- The event page's back link.
function EventsUI:Back()
    state.occ = nil
    self:Refresh()
end

-- Opens the Events tab (on a view).
function EventsUI:Open(view)
    state.occ = nil
    if view then
        state.view = (view == "library" or view == "season" or view == "review") and view or "upcoming"
    end
    if ns.MainFrame then ns.MainFrame:Open("events") end
    self:Refresh()
    return panel ~= nil and panel:IsVisible()
end

-- Opens a calendar event's page (its results once it is over).
function EventsUI:OpenEvent(occId)
    if type(occId) ~= "string" then return false end
    if not (Ev():GetOcc(occId) or Ev():GetResult(occId)) then
        ns:Print("that event isn't on the calendar any more.")
        return false
    end
    state.occ = occId
    if ns.MainFrame then ns.MainFrame:Open("events") end
    self:Refresh()
    return panel ~= nil and panel:IsVisible() and state.occ == occId
end

function EventsUI:GetPanel() return panel end

-- For the test harness and the UI audit.
function EventsUI:GetState() return state end
function EventsUI:GetViewFrame(key) return panel and panel.views[key] end
function EventsUI:GetSheet(key) return sheets[key] end
function EventsUI:CloseSheets()
    for _, f in pairs(sheets) do f:Hide() end
end
function EventsUI:SetLibraryHover(defId)
    state.hover = defId
    self:Refresh()
end
function EventsUI:SelectReview(defId)
    state.review = defId
    self:Refresh()
end
function EventsUI:SetSchedule(fields)
    local f = sheets.schedule
    if not (f and f.s) then return false end
    for k, x in pairs(fields or {}) do
        if k == "where" then f.where:SetText(x)
        elseif k == "note" then f.note:SetText(x)
        else f.s[k] = x end
    end
    Sh.RefreshSchedule()
    return true
end
function EventsUI:SubmitSchedule() return Sh.SubmitSchedule() end
function EventsUI:SubmitReview() return Sh.SubmitReview() end
function EventsUI:SetBadge(fields)
    local f = sheets.badge
    if not (f and f.s) then return false end
    for k, x in pairs(fields or {}) do
        f.s[k] = x
        if k == "n" then f.name:SetText(x) elseif k == "ti" then f.title2:SetText(x) elseif k == "q" then f.search:SetText(x) end
    end
    Sh.RefreshBadge()
    return true
end
function EventsUI:SaveBadge() return Sh.SaveBadge() end

function EventsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("events", "Events", 3.57,
            function(parent) return EventsUI:CreatePanel(parent) end,
            function() return (IsInGuild() or ns.Util.DemoOn()) and true or false end, { layout = "board" })
    end
    local function refresh() EventsUI:RequestRefresh() end
    for _, msg in ipairs({ "EVENTS_UPDATED", "DEMO_TOGGLED", "CONFIG_UPDATED", "ROSTER_UPDATED" }) do
        ns:On(msg, refresh)
    end
    -- a live run changes every few seconds: a slower refresh
    ns:On("EVENT_LIVE_UPDATED", function() EventsUI:RequestRefresh(0.4) end)
end

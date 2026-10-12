if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Feedback.lua", ...) then return end -- DisasterZone: UI/Feedback.lua
-- The Feedback page (an icon at the right of the strip, everyone): what the guild told the developer (Core/Feedback.lua),
-- as in the approved mockup (dev/art/casc/feedback_mockup).
--   Banner: a loading screen behind "Tell Tsumil", one line on how it works, the guild's numbers (open, planned, shipped,
--           from the guild), and the four tiles (Something broke / I have an idea / Change something / I love this):
--           a click opens the form (UI/FeedbackSheet.lua) with that kind picked.
--   Tabs:   Everything | Yours (a gold dot: news on my items) | Inbox n (staff: open, nobody planned or answered);
--           a sort link, the kind toggles (All and the four icons) and a search box on the right.
--   Left:   the items, open first then "Done lately": kind icon, two lines, "#14 · Name · 2 days" and a status pill,
--           the me-too counter (gold: I said it).
--   Right:  the picked item as a ticket: a band in the kind's colour (icon, kind, number, author, status), the words,
--           chips (what it is about, version, where, spec, a Lua error: hover for it), the tracker with dates, Me too
--           with the faces of who wants it too, the answers as bubbles (staff in gold); at the bottom the answer box
--           (author and staff) and for staff Plan it / Already in the addon / Not planned / Same as...
--   A guild where nobody sent anything yet: the three steps of how it works.
-- 1.4: the page banner on UI:CreatePageBanner (the tiles on the sleek surface, the numbers), the rest a list + detail
-- layout (UI:CreateLayout): the tabs in its toolbar with the sort, the kinds (UI:CreateSegments) and the search as its
-- filters; the list's rows with the shared looks and section headers; the item opens with the layout's banner (D3:
-- the kind's icon, kind and number, author, the status pill; Status as its tool, Withdraw as its action, asking first
-- with ns.Popup:Confirm); chips are pills, answers inset cards (staff ones in the picked look), the shared empty
-- states and text styles, colours from ns.Style.
local addonName, ns = ...

local FeedbackUI = ns:NewModule("FeedbackUI")
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local W_FALLBACK = S.INNER_W  -- the page's inner width (the mock's anchored frames have no size)
local PAD, GAP = S.PAD, S.GAP
local BAN_H = 100
local TABS_Y = 114             -- the tabs row (from the page's top): the layout starts here
local BODY_H = S.PAGE_H - TABS_Y - 36 - PAD   -- the list and the item (under the layout's toolbar)
local LIST_W = 336
local LIST_LANE = 20           -- a scroll list's bar lane (UI:CreateScrollList)
local ROW_H, GROUP_H = 56, 24
local IN = 0                   -- the item's body from the detail column's edges (the layout keeps the margins)
local SCROLL_LANE = 12         -- the item's scroll bar
local TILE_W, TILE_H = 84, 76
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CHECK = "Interface\\RAIDFRAME\\ReadyCheck-Ready"
local BANNER_ART = 131832      -- Serpentshrine Cavern's loading screen

local GOLD = S.C.GOLD
local GREEN = { 0.56, 0.89, 0.62 }
local GREY = { 0.47, 0.47, 0.49 }

local state = { tab = "all", kind = nil, sort = nil, search = "", sel = nil }
local panel

local function UI() return ns.UI end
local function FB() return ns.Feedback end
local function Short(key) return ns.Util.ShortName(key) end
local function KindInfo(kind) return FB().KIND_INFO[kind] or FB().KIND_INFO.idea end

local WRAP = { wrap = true }   -- (a wrapped text: a row's two lines, an answer)

-- A round class portrait (UI-Classes-Circles) for key on tex; a grey disc when the class is unknown.
local CIRCLES = "Interface\\TargetingFrame\\UI-Classes-Circles"
local function Face(tex, key)
    local cls = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    local c = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
    if c then
        tex:SetTexture(CIRCLES)
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
        tex:SetVertexColor(1, 1, 1)
    else
        tex:SetTexture(DISC)
        tex:SetTexCoord(0, 1, 0, 1)
        tex:SetVertexColor(0.3, 0.3, 0.33)
    end
    tex:Show()
end

-- The same portrait inside a line of text ("|T...|t"), 14 px.
local function FaceText(key)
    local cls = ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key)
    local c = cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls]
    if not c then return "" end
    return ("|T%s:14:14:0:0:256:256:%d:%d:%d:%d|t"):format(CIRCLES, floor(c[1] * 256), floor(c[2] * 256),
        floor(c[3] * 256), floor(c[4] * 256))
end

-- "just now", "12 min", "3 hours", "2 days", "3 weeks" (ago is added by the caller where it reads better).
local function Age(ts)
    local d = ns.Util.Now() - (tonumber(ts) or 0)
    if d < 90 then return "just now" end
    if d < 3600 then return floor(d / 60) .. " min" end
    if d < 86400 then local h = floor(d / 3600) return h == 1 and "1 hour" or (h .. " hours") end
    local days = floor(d / 86400)
    if days < 14 then return days == 1 and "1 day" or (days .. " days") end
    if days < 60 then return floor(days / 7) .. " weeks" end
    return date("%b %Y", ts)
end
local function Ago(ts)
    local a = Age(ts)
    return a == "just now" and a or (a .. " ago")
end
FeedbackUI.Ago = Ago

-- "Tue 7 Oct".
local function Day(ts)
    if not ts then return "" end
    return (date("%a %d %b", ts):gsub(" 0", " "))
end

-- The status pill of an item: text, tag kind.
local function Pill(item)
    local F = FB()
    local shipped = F:ShippedText(item)
    if shipped then return shipped, "ok" end
    local s = item.state
    if s == "planned" then return "Planned", "bis" end
    if s == "exists" then return "Already in the addon", "ok" end
    if s == "notnow" then return "Not planned", "mute" end
    if s == "removed" then return "Removed", "warn" end
    if s == "dup" then
        local other = item.dup and F:Get(item.dup)
        return (other and other.no) and ("Same as #" .. other.no) or "Same as another", "mute"
    end
    if item.no then return "Received", "mute" end
    return "Sent", "mute"
end
FeedbackUI.Pill = Pill

---------------------------------------------------------------------------
-- "Seen": my items with news (an answer, a status) since I last looked
---------------------------------------------------------------------------

local demoSeen = {}

local function Signature(item)
    return (item.state or "") .. "/" .. #item.replies .. "/" .. (item.shipped or "")
end

local function SeenStore()
    if FB().DemoOn() then return demoSeen end
    local db = ns.db
    if not db then return {} end
    if type(db.feedbackSeen) ~= "table" then db.feedbackSeen = {} end
    return db.feedbackSeen
end

-- Has my item news I haven't looked at? (Never looked at: news once staff answered or set a status.)
function FeedbackUI:HasNews(item)
    if not item.mine then return false end
    local seen = SeenStore()[item.id]
    if seen == nil then return item.answered or (item.state ~= nil and item.state ~= "open") end
    return seen ~= Signature(item)
end

function FeedbackUI:MarkSeen(item)
    if item and item.mine then SeenStore()[item.id] = Signature(item) end
end

function FeedbackUI:NewsCount()
    local F = FB()
    if not F then return 0 end
    local n = 0
    for _, item in ipairs(F:List({ mine = true })) do
        if self:HasNews(item) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- Small pieces
---------------------------------------------------------------------------

local function Refresh() if panel then FeedbackUI:Refresh() end end

-- A kind's icon: the shared icon tile (UI:CreateIconTile) in a ring of the kind's colour.
local function KindIcon(parent, size, ring)
    local f = UI():CreateIconTile(parent, size)
    f.ring = f:CreateTexture(nil, "BACKGROUND", nil, -1)
    f.ring:SetPoint("TOPLEFT", -2, 2)
    f.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    function f:SetKind(kind, dim)
        local info = KindInfo(kind)
        self:Set(info.icon)
        self.tex:SetDesaturated(dim and true or false)
        self.tex:SetVertexColor(dim and 0.8 or 1, dim and 0.8 or 1, dim and 0.8 or 1)
        self.ring:SetColorTexture(info.color[1], info.color[2], info.color[3], ring or 0.3)
    end
    return f
end

local function VoteTip(owner, item)
    local names = {}
    for key in pairs(item.votes) do names[#names + 1] = UI():ColoredName(key) end
    table.sort(names)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if item.mine then
        GameTooltip:AddLine(item.voteCount == 0 and "Nobody said me too yet" or "They want it too", S:Color("GOLD"))
    else
        GameTooltip:AddLine(item.voted and "You said me too" or "Me too", S:Color("GOLD"))
        GameTooltip:AddLine(item.voted and "Click to take it back." or "Click if you want this too: the developer sees how "
            .. "many asked for it.", 1, 1, 1, true)
    end
    if #names > 0 then GameTooltip:AddLine(tconcat(names, ", "), 1, 1, 1, true) end
    GameTooltip:Show()
end

-- The me-too counter of a row: the sleek button ("chosen" when I said it, the chevron and count gold then), a chevron
-- up and the count.
local function NewCounter(parent)
    local b = UI():CreateSleekButton(parent, "", 32, 36, function(self)
        local item = self.item
        if item and not item.mine then FB():Vote(item.id, not item.voted) end
    end)
    b.chev = b:CreateTexture(nil, "OVERLAY")
    b.chev:SetSize(12, 12)
    b.chev:SetPoint("TOP", 0, -5)
    b.chev:SetTexture(UI().ICON_ATLAS)
    b.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    UI():SetChevronUp(b.chev, true)
    b.n = UI():Text(b, "body", "TEXT")
    b.n:SetJustifyH("CENTER")
    b.n:SetPoint("BOTTOM", 0, 5)
    function b:Set(item)
        self.item = item
        self.n:SetText(item.voteCount)
        local on = item.voted
        self:SetKind(on and "chosen" or "secondary")
        local r, g, bl = S:Color(on and "GOLD" or "SUB")
        self.chev:SetVertexColor(r, g, bl)
        self.n:SetTextColor(r, g, bl)
        self:SetAlpha(item.mine and 0.55 or 1)
    end
    b:HookScript("OnEnter", function(self) if self.item then VoteTip(self, self.item) end end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

---------------------------------------------------------------------------
-- Banner
---------------------------------------------------------------------------

local TILE_LABEL = { bug = "Something\nbroke", idea = "I have\nan idea", change = "Change\nsomething", love = "I love\nthis" }

local function NewTile(parent, kind)
    local info = KindInfo(kind)
    local c = info.color
    -- the sleek button's surface (UI:PaintSleek), its edge and label in the kind's colour under the mouse
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(TILE_W, TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.icon = KindIcon(t, 30, 0.35)
    t.icon:SetPoint("TOP", 0, -9)
    t.icon:SetKind(kind)
    t.label = UI():Text(t, "small", "TEXT", WRAP)
    t.label:SetJustifyH("CENTER")
    t.label:SetPoint("TOP", t.icon, "BOTTOM", 0, -7)
    t.label:SetWidth(TILE_W - 6)
    t.label:SetText(TILE_LABEL[kind])
    local function look(self)
        local hot = self:IsMouseOver()
        UI():PaintSleek(self, "secondary", hot)
        UI():SetEdgeColor(self, c[1], c[2], c[3], hot and 0.85 or 0.32)
        if hot then self.label:SetTextColor(c[1], c[2], c[3]) else self.label:SetTextColor(S:Color("TEXT")) end
    end
    t:SetScript("OnEnter", function(self)
        look(self)
        UI():SetTextTooltip(self, { info.label, "Opens the form with this picked. Tip: Ctrl+right-click anything in "
            .. "DisasterZone to say what it's about." }, "ANCHOR_BOTTOM")
    end)
    t:SetScript("OnLeave", function(self) look(self); GameTooltip:Hide() end)
    t:SetScript("OnClick", function()
        if ns.FeedbackSheet then ns.FeedbackSheet:Open({ kind = kind }) end
    end)
    look(t)
    return t
end

-- The page banner (UI:CreatePageBanner): Serpentshrine's loading screen behind "Feedback", how it works, the numbers;
-- the four tiles at its right.
local function BannerArt(w)
    w = (w and w > 100) and w or W_FALLBACK
    local fw = 0.98
    local fh = fw * (4 / 3) * (BAN_H / w)
    return { BANNER_ART, 0.01, 0.99, 0.52 - fh / 2, 0.52 + fh / 2 }
end

local function CreateTopBanner(p)
    local b = UI():CreatePageBanner(p, { size = BAN_H, art = BannerArt(W_FALLBACK), artTint = 0.85, title = "Feedback",
        width = W_FALLBACK })
    b:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -8)
    b:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -8)
    b:HookScript("OnSizeChanged", function(self, w) if w and w > 100 then self:SetArt(BannerArt(w)) end end)
    b.desc = UI():Text(b, "body", "TEXT", WRAP)
    b.desc:SetPoint("TOPLEFT", 14, -40)
    b.desc:SetWidth(380)
    b.desc:SetText("Bugs, ideas and changes reach the addon's developer, even while the developer is offline. What "
        .. "ships carries your name.")
    b.stats = UI():Text(b, "emph", "TEXT")
    b.stats:SetPoint("BOTTOMLEFT", 14, 10)
    b.tiles = {}
    local kinds = FB().KINDS
    for i = #kinds, 1, -1 do
        local t = NewTile(b, kinds[i])
        local right = #kinds - i
        t:SetPoint("TOPRIGHT", b, "TOPRIGHT", -12 - right * (TILE_W + 6), -12)
        b.tiles[kinds[i]] = t
    end
    return b
end

local function StatsText()
    local c = FB():Counts()
    local function stat(n, word, col) return UI():Colorize(tostring(n), col or { 1, 1, 1 }) .. " " .. S:Wrap("SUB", word) end
    return stat(c.open, "open") .. "     " .. stat(c.planned, "planned") .. "     "
        .. stat(c.shipped, "shipped", GREEN) .. "     " .. stat(c.total, "from the guild")
end

---------------------------------------------------------------------------
-- List
---------------------------------------------------------------------------

local function InitRow(row, data)
    if not row.built then
        row.built = true
        UI():DecorateRow(row, { selectable = true, rule = true })
        row.hl, row.rule = row.dzHover, row.dzRule
        row.icon = KindIcon(row, 28)
        row.icon:SetPoint("TOPLEFT", 10, -8)
        row.text = UI():Text(row, "body", "TEXT", WRAP)
        row.text:SetPoint("TOPLEFT", 48, -8)
        row.text:SetWidth(LIST_W - LIST_LANE - 48 - 48)
        if row.text.SetMaxLines then row.text:SetMaxLines(2) end
        row.text:SetHeight(2 * (S.FONT.body + 2))   -- (two lines at most: the meta line sits under them)
        row.text:SetJustifyV("TOP")
        row.meta = UI():Text(row, "small", "TEXT")
        row.meta:SetPoint("BOTTOMLEFT", 48, 7)
        row.pill = UI():CreatePill(row, nil, nil, 14)
        row.pill:SetBase(S.C.CARD[1], S.C.CARD[2], S.C.CARD[3])
        row.pill:SetPoint("LEFT", row.meta, "RIGHT", 5, 0)
        row.news = row:CreateTexture(nil, "OVERLAY")
        row.news:SetSize(8, 8)
        row.news:SetPoint("TOPLEFT", 3, -5)
        row.news:SetTexture("Interface\\COMMON\\Indicator-Yellow")
        row.vote = NewCounter(row)
        row.vote:SetPoint("RIGHT", -8, 0)
        -- a group's heading ("Open 5", "Done lately 4"): the shared section header
        row.head = UI():CreateSectionHeader(row, "", { style = "title", rule = false })
        row.head:SetPoint("BOTTOMLEFT", 4, 0)
        row.head:SetPoint("BOTTOMRIGHT", -4, 0)
        row:SetScript("OnClick", function(self)
            local d = self.__cdlData
            if d and d.item then FeedbackUI:Select(d.item.id) end
        end)
    end
    local item = data.item
    local isHead = data.header ~= nil
    row.head:SetShown(isHead)
    row:EnableMouse(not isHead)
    for _, r in ipairs({ row.rule, row.icon, row.text, row.meta, row.pill, row.news, row.vote }) do
        r:SetShown(not isHead)
    end
    if row.hl then row.hl:SetShown(not isHead) end
    if isHead then
        row:SetSelected(false)
        row.head:SetTitle(data.header)
        row.head:SetCount(data.count)
        return
    end
    row:SetSelected(item.id == state.sel)
    local done = item.closed
    row.icon:SetKind(item.kind, done and item.state ~= "done")
    row.text:SetText(UI():SafeText(item.text or ""))
    local tc = done and 0.66 or 0.94
    row.text:SetTextColor(tc, tc, tc)
    local parts = {}
    if item.no then parts[#parts + 1] = S:Wrap("SUB", "#" .. item.no) end
    parts[#parts + 1] = UI():ColoredName(item.author)
    parts[#parts + 1] = S:Wrap("SUB", Age(item.at))
    row.meta:SetText(tconcat(parts, S:Wrap("SUB", " · ")))
    row.pill:Set(Pill(item))
    row.news:SetShown(FeedbackUI:HasNews(item))
    row.vote:Set(item)
end

local function RowHeight(data) return data.header and GROUP_H or ROW_H end

---------------------------------------------------------------------------
-- The item
---------------------------------------------------------------------------

-- The tracker: dots on a line with a label and a date under each.
local function NewSteps(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetHeight(46)
    s.nodes, s.bars = {}, {}
    for i = 1, 4 do
        local n = {}
        n.ring = s:CreateTexture(nil, "ARTWORK", nil, 1)
        n.ring:SetTexture(DISC)
        n.ring:SetSize(14, 14)
        n.fill = s:CreateTexture(nil, "ARTWORK", nil, 2)
        n.fill:SetTexture(DISC)
        n.fill:SetSize(10, 10)
        n.check = s:CreateTexture(nil, "ARTWORK", nil, 3)
        n.check:SetTexture(CHECK)
        n.check:SetSize(11, 11)
        n.glow = s:CreateTexture(nil, "ARTWORK", nil, 0)
        n.glow:SetTexture(DISC)
        n.glow:SetSize(22, 22)
        n.glow:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.25)
        n.label = UI():Text(s, "body", "TEXT")
        n.label:SetJustifyH("CENTER")
        n.date = UI():Text(s, S.FONT.caps, "DIM")
        n.date:SetJustifyH("CENTER")
        s.nodes[i] = n
        if i > 1 then
            local b = s:CreateTexture(nil, "ARTWORK", nil, 0)
            b:SetHeight(2)
            s.bars[i - 1] = b
        end
    end
    -- steps = { { text, date, st = "done" | "now" | "todo" | "closed" } }; width = the line's width
    function s:Set(steps, width)
        local count = #steps
        local span = max(60, width - 100)
        local xs = {}
        for i, n in ipairs(self.nodes) do
            local st = steps[i]
            local shown = st ~= nil
            for _, r in ipairs({ n.ring, n.fill, n.check, n.glow, n.label, n.date }) do r:SetShown(shown) end
            if shown then
                local x = 50 + (count > 1 and (i - 1) * span / (count - 1) or span / 2)
                xs[i] = x
                for _, r in ipairs({ n.ring, n.fill, n.check, n.glow }) do
                    r:ClearAllPoints()
                    r:SetPoint("CENTER", self, "TOPLEFT", x, -7)
                end
                n.label:ClearAllPoints()
                n.label:SetPoint("TOP", self, "TOPLEFT", x, -19)
                n.date:ClearAllPoints()
                n.date:SetPoint("TOP", n.label, "BOTTOM", 0, -2)
                n.label:SetText(st.text)
                n.date:SetText(st.date or "")
                n.glow:SetShown(st.st == "now")
                n.check:SetShown(st.st == "done")
                if st.st == "done" then
                    n.ring:SetVertexColor(0.44, 0.86, 0.53)
                    n.fill:SetVertexColor(0.18, 0.68, 0.30)
                    n.label:SetTextColor(GREEN[1], GREEN[2], GREEN[3])
                elseif st.st == "now" then
                    n.ring:SetVertexColor(S:Color("GOLD"))
                    n.fill:SetVertexColor(0.24, 0.21, 0.07)
                    n.label:SetTextColor(S:Color("GOLD"))
                elseif st.st == "closed" then
                    n.ring:SetVertexColor(0.62, 0.62, 0.65)
                    n.fill:SetVertexColor(0.30, 0.30, 0.33)
                    n.label:SetTextColor(0.8, 0.8, 0.82)
                else
                    n.ring:SetVertexColor(0.33, 0.33, 0.36)
                    n.fill:SetVertexColor(0.105, 0.105, 0.125)
                    n.label:SetTextColor(GREY[1], GREY[2], GREY[3])
                end
            end
        end
        for i, b in ipairs(self.bars) do
            local a, z = xs[i], xs[i + 1]
            b:SetShown(a ~= nil and z ~= nil)
            if a and z then
                b:ClearAllPoints()
                b:SetPoint("LEFT", self, "TOPLEFT", a + 9, -7)
                b:SetPoint("RIGHT", self, "TOPLEFT", z - 9, -7)
                local st = steps[i + 1].st
                if st == "done" or st == "closed" then
                    UI():Gradient(b, "HORIZONTAL", { 0.24, 0.81, 0.36, 1 }, { 0.44, 0.86, 0.53, 1 })
                elseif st == "now" then
                    UI():Gradient(b, "HORIZONTAL", { 0.44, 0.86, 0.53, 1 }, { GOLD[1], GOLD[2], GOLD[3], 0.85 })
                else
                    b:SetColorTexture(0.23, 0.23, 0.25, 1)
                end
            end
        end
    end
    return s
end

local function Steps(item)
    local F = FB()
    local stage = F:Stage(item)
    local steps = {
        { text = "Sent", date = Day(item.at), st = "done" },
        { text = "Received", date = item.no and Day(item.seenAt) or "", st = stage >= 2 and "done" or "now" },
    }
    if item.closed and item.state ~= "done" then
        local label = Pill(item)
        steps[3] = { text = label, date = Day(item.stateAt), st = "closed" }
        return steps
    end
    steps[3] = { text = "Planned", date = stage >= 3 and item.state == "planned" and Day(item.stateAt) or "",
                 st = stage >= 3 and "done" or (stage == 2 and "now" or "todo") }
    local last = F:ShippedText(item) or (item.kind == "bug" and "Fixed" or "In a release")
    steps[4] = { text = last, date = stage >= 4 and "" or (stage == 3 and "next release" or ""),
                 st = stage >= 4 and "done" or (stage == 3 and "now" or "todo") }
    return steps
end

-- A chip of what came with an item: the shared pill (UI:CreatePill), its look from the chip's kind ("about" gold, a
-- Lua error red, the rest quiet); chip:Set(text, kind) (the form's chips too, UI/FeedbackSheet.lua).
local CHIP_LOOK = { about = "bis", err = "live" }
local function NewContextPill(parent)
    local c = UI():CreatePill(parent, nil, nil, 18)
    local set = c.Set
    function c:Set(text, kind, icon)
        set(self, text, CHIP_LOOK[kind] or (UI().PILL_LOOK[kind] and kind) or "mute", icon)
    end
    return c
end

FeedbackUI.NewContextPill, FeedbackUI.NewSteps = NewContextPill, NewSteps

local function ErrorTip(owner, item)
    local e = item.err
    if not e then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Lua error" .. ((e.n or 1) > 1 and (" (" .. e.n .. " times)") or "")
        .. (e.v and ("  ·  " .. e.v) or ""), 0.88, 0.42, 0.38)
    GameTooltip:AddLine(e.m, 1, 1, 1, true)
    if e.s then GameTooltip:AddLine(e.s, 0.7, 0.7, 0.7, true) end
    GameTooltip:Show()
end

local function ContextTip(owner, item)
    local c = item.ctx or {}
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Sent with it", S:Color("GOLD"))
    local function row(label, value)
        if value and value ~= "" then GameTooltip:AddDoubleLine(label, value, 0.7, 0.7, 0.7, 1, 1, 1) end
    end
    row("Version", c.v)
    row("Build", c.b)
    row("Where", c.z)
    row("Class", ns.ClassName(c.cl))
    row("Spec", c.sp)
    row("Page open", c.p)
    row("Language", c.lo)
    GameTooltip:Show()
end

-- An answer: the class circle, then a card (UI:CreateCard, inset) with the name, a tag and when, and the text; a
-- staff answer wears the picked look (the gold wash and bar).
local function NewBubble(parent)
    local b = CreateFrame("Frame", nil, parent)
    b.face = b:CreateTexture(nil, "ARTWORK")
    b.face:SetSize(20, 20)
    b.face:SetPoint("TOPLEFT", 0, -1)
    b.card = UI():CreateCard(b, { tone = "inset", pad = 0 })
    b.card:SetPoint("TOPLEFT", 29, 0)
    b.card:SetPoint("BOTTOMRIGHT")
    UI():DecorateRow(b.card, { hover = false, selectable = true })
    b.name = UI():Text(b.card, "body", "TEXT")
    b.name:SetPoint("TOPLEFT", 10, -6)
    b.tag = UI():CreatePill(b.card, nil, nil, 13)
    b.tag:SetPoint("LEFT", b.name, "RIGHT", 6, 0)
    b.when = UI():Text(b.card, "small", "DIM")
    b.when:SetPoint("TOPRIGHT", -8, -7)
    b.when:SetJustifyH("RIGHT")
    b.text = UI():Text(b.card, "body", "TEXT", WRAP)
    b.text:SetPoint("TOPLEFT", 10, -21)
    function b:Set(rep, width)
        Face(self.face, rep.author)
        self.name:SetText(UI():ColoredName(rep.author))
        local staff = rep.staff
        self.tag:SetShown(staff and true or false)
        if staff then
            self.tag:SetBase(S:Color("INSET"))
            self.tag:Set(FB():IsDev(rep.author) and "Developer" or "Officer", "bis")
        end
        self.card:SetSelected(staff and true or false)
        self.when:SetText(Day(rep.at))
        self.text:SetWidth(width - 39 - 10)
        self.text:SetText(UI():SafeText(rep.text))
        local h = 21 + max(14, tonumber(self.text:GetStringHeight()) or 14) + 8
        self:SetSize(width, h)
        return h
    end
    return b
end

local StatusMenu

-- The header's Status menu (staff, outside the Inbox): every status, and Same as... as a submenu.
local function FullStatusMenu(root, item)
    local F = FB()
    local function set(s)
        return function()
            local ok, err = F:SetState(item.id, s)
            if not ok and err then ns:Print(err) end
        end
    end
    local function entry(s, label, tip)
        local b = root:CreateRadio(label, function() return item.state == s end, set(s))
        if b and b.SetTooltip and tip then
            b:SetTooltip(function(tt) tt:AddLine(label, S:Color("GOLD")); tt:AddLine(tip, 1, 1, 1, true) end)
        end
    end
    entry("planned", "Planned", "It will be done.")
    entry("exists", "Already in the addon", "Answer how to find it too: in the Inbox, or as the author's answer box.")
    entry("notnow", "Not planned", "Not now.")
    local sub = root:CreateButton("Same as...")
    StatusMenu(sub, item, true)
end

StatusMenu = function(root, item, only)
    local F = FB()
    local d = panel.detail
    local function set(s, opts)
        return function()
            opts = opts or {}
            local txt = d.reply:GetText() or ""
            if txt ~= "" then opts.reply = txt end
            local ok, err = F:SetState(item.id, s, opts)
            if ok then d.reply:SetText("") elseif err then ns:Print(err) end
        end
    end
    local others = {}
    local seen = {}
    for _, other in ipairs(F:Similar(item.text, item.about, 12)) do
        if other.id ~= item.id then others[#others + 1] = other; seen[other.id] = true end
    end
    for _, other in ipairs(F:List({ open = true }, "asked")) do
        if #others >= 12 then break end
        if not seen[other.id] and other.id ~= item.id then others[#others + 1] = other end
    end
    if not only then root:CreateTitle("It repeats...") end
    if #others == 0 then
        local none = root:CreateButton("No other open items")
        if none and none.SetEnabled then none:SetEnabled(false) end
    end
    for _, other in ipairs(others) do
        local t = other.text or ""
        if #t > 46 then t = t:sub(1, 44):gsub("%s+%S*$", "") .. "..." end
        root:CreateButton((other.no and ("#" .. other.no .. "  ") or "") .. t, set("dup", { dup = other.id }))
    end
    if only then return end
    root:CreateDivider()
    if item.state and item.state ~= "open" then root:CreateButton("Open again", set(nil)) end
    local rm = root:CreateButton("|cffe06b60Remove|r", set("removed"))
    if rm and rm.SetTooltip then
        rm:SetTooltip(function(tt)
            tt:AddLine("Remove", S:Color("GOLD"))
            tt:AddLine("Hides it from the guild's lists (spam, or something that doesn't belong here). Staff still see "
                .. "it in the Inbox.", 1, 1, 1, true)
        end)
    end
end

-- Three steps for a guild where nobody sent anything yet.
local function BuildHow(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.title = UI():Text(f, "title", "GOLD")
    f.title:SetJustifyH("CENTER")
    f.title:SetPoint("TOP", 0, -60)
    f.title:SetText("Nothing sent yet")
    f.sub = UI():Text(f, "body", "SUB")
    f.sub:SetJustifyH("CENTER")
    f.sub:SetPoint("TOP", f.title, "BOTTOM", 0, -5)
    f.sub:SetText("Pick a tile above: it takes a minute.")
    local steps = {
        { "You send it", "A bug, an idea, a change, or what you love." },
        { "The guild carries it", "It reaches the developer, even while offline." },
        { "It ships with your name", "In the changelog, with everyone who said me too." },
    }
    f.cols = {}
    for i, s in ipairs(steps) do
        local c = CreateFrame("Frame", nil, f)
        c:SetSize(110, 90)
        c.ring = c:CreateTexture(nil, "ARTWORK")
        c.ring:SetTexture(DISC)
        c.ring:SetSize(26, 26)
        c.ring:SetPoint("TOP")
        c.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.6)
        c.in_ = c:CreateTexture(nil, "ARTWORK", nil, 1)
        c.in_:SetTexture(DISC)
        c.in_:SetSize(24, 24)
        c.in_:SetPoint("CENTER", c.ring)
        c.in_:SetVertexColor(0.13, 0.12, 0.07)
        c.n = UI():Text(c, "title", "GOLD")
        c.n:SetPoint("CENTER", c.ring, "CENTER", 0, 0)
        c.n:SetText(i)
        c.t = UI():Text(c, "body", "TEXT")
        c.t:SetJustifyH("CENTER")
        c.t:SetPoint("TOP", c.ring, "BOTTOM", 0, -8)
        c.t:SetText(s[1])
        c.d = UI():Text(c, "small", "SUB", WRAP)
        c.d:SetJustifyH("CENTER")
        c.d:SetPoint("TOP", c.t, "BOTTOM", 0, -3)
        c.d:SetWidth(110)
        c.d:SetText(s[2])
        f.cols[i] = c
    end
    function f:Layout(width)
        local w = max(300, width)
        local gap = (w - 3 * 110) / 4
        for i, c in ipairs(self.cols) do
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", self, "TOPLEFT", gap + (i - 1) * (110 + gap), -112)
        end
    end
    return f
end

local function DetailWidth()
    local w = panel and panel.detailBox and panel.detailBox:GetWidth()
    if w and w > 100 then return w end
    local pw = panel and panel:GetWidth()
    pw = (pw and pw > 100) and pw or (W_FALLBACK + 2 * PAD)
    return pw - 2 * PAD - LIST_W - GAP
end

-- The item card's height (the layout's detail column; the mock's anchored frames have none).
local function DetailHeight()
    local h = panel and panel.detailBox and panel.detailBox:GetHeight()
    if h and h > 100 then return h end
    return BODY_H
end

-- The item's Status menu (staff, outside the Inbox): every status, Open again, Remove.
local function ItemStatusMenu(root, item)
    FullStatusMenu(root, item)
    root:CreateDivider()
    if item.state and item.state ~= "open" then
        root:CreateButton("Open again", function() FB():SetState(item.id, nil) end)
    end
    root:CreateButton(S:Wrap("BAD", "Remove"), function() FB():SetState(item.id, "removed") end)
end

-- Withdraw (my own open item): asks first (ns.Popup:Confirm), then takes it back.
local function ConfirmWithdraw(item)
    ns.Popup:Confirm({ title = "Withdraw", text = "Take your feedback back? It leaves everyone's lists.", ok = "Withdraw",
        danger = true, key = "dz-feedback-withdraw", onAccept = function()
            local ok, err = FB():Withdraw(item.id)
            if not ok and err then ns:Print(err) end
            if state.sel == item.id then state.sel = nil end
            Refresh()
        end })
end

-- The item: the layout's detail banner (D3: the kind's icon in a ring of its colour, the kind and number, the author
-- and when, the status pill; Status as its tool for staff, Withdraw as its action for the author), under it the body.
local function BuildDetail(box, banner)
    local d = { chips = {}, bubbles = {}, faces = {}, banner = banner }
    -- (stands in for a banner button that is not shown: d.status / d.withdraw)
    d.none = CreateFrame("Button", nil, banner)
    d.none:Hide()
    d.status, d.withdraw = d.none, d.none

    -- the body scrolls; the answer box and the staff buttons stay at the bottom
    d.scroll = UI():CreateScrollFrame(box, "DisasterZoneFeedbackDetailScroll")
    d.scroll:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
    d.child = CreateFrame("Frame", nil, d.scroll)
    d.child:SetSize(300, 10)
    d.scroll:SetScrollChild(d.child)
    local c = d.child
    d.text = UI():Text(c, "title", "TEXT", WRAP)
    d.text:SetSpacing(3)
    d.steps = NewSteps(c)
    d.vote = UI():CreateSleekButton(c, "Me too", 76, S.BTN_H, function()
        if d.item and not d.item.mine then FB():Vote(d.item.id, not d.item.voted) end
    end)
    d.vote.up = d.vote:CreateTexture(nil, "OVERLAY")
    d.vote.up:SetSize(10, 10)
    d.vote.up:SetTexture(UI().ICON_ATLAS)
    d.vote.up:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
    UI():SetChevronUp(d.vote.up, true)
    d.vote.up:SetPoint("LEFT", 8, 0)
    d.vote:GetFontString():ClearAllPoints()
    d.vote:GetFontString():SetPoint("LEFT", 22, 0)
    d.vote:HookScript("OnEnter", function(self) if d.item then VoteTip(self, d.item) end end)
    d.vote:HookScript("OnLeave", function() GameTooltip:Hide() end)
    d.votes = UI():Text(c, "body", "SUB")
    d.votesHover = CreateFrame("Frame", nil, c)
    d.votesHover:SetScript("OnEnter", function(self) if d.item then VoteTip(self, d.item) end end)
    d.votesHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the answers' heading: the shared section header (the count at its right)
    d.ansHead = UI():CreateSectionHeader(c, "Answers", { style = "title" })
    d.noAns = UI():Text(c, "body", "DIM", WRAP)

    -- bottom: answer box, staff buttons
    d.reply = UI():CreateSleekEditBox(box, 200, 24, "GameFontHighlightSmall")
    d.reply:SetMaxLetters(300)
    local function sendReply()
        local text = d.reply:GetText() or ""
        if not d.item or ns.Util.Trim(text) == "" then return end
        local rid, err = FB():Reply(d.item.id, text)
        if rid then
            d.reply:SetText("")
            d.reply:ClearFocus()
        elseif err then
            ns:Print(err)
        end
    end
    d.reply:SetScript("OnEnterPressed", sendReply)
    d.answer = UI():CreateSleekButton(box, "Answer", 68, S.BTN_H, sendReply)
    local function staffButton(text, w, s, kind)
        local b = UI():CreateSleekButton(box, text, w, S.BTN_H, function()
            if not d.item then return end
            local opts = {}
            local txt = d.reply:GetText() or ""
            if txt ~= "" then opts.reply = txt end
            local ok, err = FB():SetState(d.item.id, s, opts)
            if ok then d.reply:SetText("") elseif err then ns:Print(err) end
        end, kind)
        return b
    end
    d.plan = staffButton("Plan it", 64, "planned", "primary")
    d.exists = staffButton("Already in the addon", 132, "exists")
    d.notnow = staffButton("Not planned", 86, "notnow")
    d.same = UI():CreateSleekMenuButton(box, "Same as", 82, function(root)
        if d.item then StatusMenu(root, d.item) end
    end)
    d.staffNote = UI():Text(box, "small", "DIM")

    d.how = BuildHow(box)
    d.how:SetAllPoints(box)
    d.empty = UI():CreateEmptyState(box, { glyph = UI().ICON.notes, title = "Nothing here." })
    d.empty:SetPoint("TOP", 0, -60)
    d.empty:Hide()
    return d
end

local function ChipPool(d, i)
    local ch = d.chips[i]
    if not ch then
        ch = NewContextPill(d.child)
        ch:EnableMouse(true)
        ch:SetScript("OnEnter", function(self)
            if not d.item then return end
            if self.kind == "err" then ErrorTip(self, d.item) else ContextTip(self, d.item) end
        end)
        ch:SetScript("OnLeave", function() GameTooltip:Hide() end)
        d.chips[i] = ch
    end
    return ch
end

local function FacePool(d, i)
    local f = d.faces[i]
    if not f then
        f = d.child:CreateTexture(nil, "ARTWORK", nil, 7 - min(i, 7))
        f:SetSize(18, 18)
        d.faces[i] = f
    end
    return f
end

local function RenderDetail()
    local d = panel.detail
    local F = FB()
    local item = state.sel and F:Get(state.sel)
    d.item = item
    local width = DetailWidth()
    local inner = width - 2 * IN - SCROLL_LANE
    local hasAny = F:Counts().total > 0
    local shown = item ~= nil
    for _, r in ipairs({ d.scroll, d.reply, d.answer, d.plan, d.exists, d.notnow, d.same, d.staffNote }) do
        r:SetShown(shown)
    end
    if d.banner:IsShown() ~= shown then
        d.banner:SetShown(shown)
        panel.layout:Layout()
    end
    d.how:SetShown(not shown and not hasAny and state.tab ~= "inbox")
    d.empty:SetShown(not shown and not d.how:IsShown())
    if not shown then
        d.how:Layout(width)
        d.empty:SetBoxWidth(width - 48)
        if state.tab == "inbox" then
            d.empty:SetContent({ glyph = UI().ICON.notes, title = "All caught up.",
                text = "New feedback lands here until somebody answers or plans it." })
        else
            d.empty:SetContent({ glyph = UI().ICON.notes, title = "Nothing here." })
        end
        return
    end
    FeedbackUI:MarkSeen(item)
    local info = KindInfo(item.kind)
    local kc = info.color

    -- the banner
    local b = d.banner
    b:SetIcon(info.icon)
    b.icon.ring:SetColorTexture(kc[1], kc[2], kc[3], 0.55)
    local label = item.kind == "bug" and "Something broke" or info.short
    b:SetTitle(UI():Colorize(label, kc) .. (item.no and ("  " .. S:Wrap("SUB", "#" .. item.no)) or ""))
    b:SetSub(FaceText(item.author) .. " " .. UI():ColoredName(item.author) .. S:Wrap("SUB", "  ·  " .. Ago(item.at)))
    local pillText, pillKind = Pill(item)
    b:SetPill(pillKind, pillText)
    -- TODO(refactor): Banner:SetPill should take every UI.PILL_LOOK kind (it goes through the event pill's SetKind,
    -- which reads "bis" as mute): the pill's own SetPill gives it its look
    b.pill:SetPill(pillKind, pillText)
    local inbox = state.tab == "inbox"
    local staff = F:AmIStaff()
    local tools, actions = {}, {}
    if staff and not inbox then
        tools[1] = { icon = "more", title = "Status", text = "Planned, already in the addon, not planned, same as another, "
            .. "open again or remove.", menu = function(root) if d.item then ItemStatusMenu(root, d.item) end end }
    end
    if item.mine and not item.closed then
        actions[1] = { text = "Withdraw", tip = { "Withdraw", "Takes your feedback back: it leaves everyone's lists." },
            onClick = function() if d.item then ConfirmWithdraw(d.item) end end }
    end
    b:SetTools(tools)
    b:SetActions(actions)
    d.status = b.tools[1] or d.none
    d.withdraw = b.actions[1] or d.none

    -- the body
    d.child:SetWidth(inner)
    local y = 0
    d.text:ClearAllPoints()
    d.text:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
    d.text:SetWidth(inner)
    d.text:SetText(UI():SafeText(item.text or ""))
    y = y - max(16, tonumber(d.text:GetStringHeight()) or 16) - 10

    -- chips (they wrap)
    local chips = {}
    if item.about and item.about ~= "" then chips[#chips + 1] = { item.about, "about" } end
    local cx = item.ctx or {}
    if cx.v then chips[#chips + 1] = { cx.v } end
    if cx.z then chips[#chips + 1] = { cx.z } end
    local who = ns.Util.Trim(((cx.sp or "") .. " " .. (ns.ClassName(cx.cl) or "")))
    if who ~= "" then chips[#chips + 1] = { who } end
    if item.err then
        chips[#chips + 1] = { "Lua error" .. ((item.err.n or 1) > 1 and (" ×" .. item.err.n) or ""), "err" }
    end
    for _, ch in ipairs(d.chips) do ch:Hide() end
    local x = 0
    for i, cdef in ipairs(chips) do
        local ch = ChipPool(d, i)
        ch.kind = cdef[2]
        ch:Set(cdef[1], cdef[2])
        local w = ch:GetWidth()
        if x > 0 and x + w > inner then
            x = 0
            y = y - 23
        end
        ch:ClearAllPoints()
        ch:SetPoint("TOPLEFT", d.child, "TOPLEFT", x, y)
        ch:Show()
        x = x + w + 5
    end
    if #chips > 0 then y = y - 18 end
    y = y - 16

    -- the tracker
    d.steps:ClearAllPoints()
    d.steps:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
    d.steps:SetWidth(inner)
    d.steps:Set(Steps(item), inner)
    y = y - 58

    -- me too: the button (others' items), the faces, who
    local fx = 0
    d.vote:SetShown(not item.mine)
    if not item.mine then
        d.vote:ClearAllPoints()
        d.vote:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
        d.vote:SetText(item.voted and "You too" or "Me too")
        d.vote:SetKind(item.voted and "chosen" or "secondary")
        d.vote.up:SetVertexColor(item.voted and 1 or 0.8, item.voted and 1 or 0.8, item.voted and 1 or 0.8)
        fx = 76 + 10
    end
    local keys = {}
    for key in pairs(item.votes) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b)
        local am, bm = ns.Util.IsMe(a), ns.Util.IsMe(b)
        if am ~= bm then return am end
        return a < b
    end)
    for _, f in ipairs(d.faces) do f:Hide() end
    for i = 1, min(6, #keys) do
        local f = FacePool(d, i)
        Face(f, keys[i])
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", d.child, "TOPLEFT", fx + (i - 1) * 13, y - 2)
    end
    local facesW = #keys > 0 and (min(6, #keys) - 1) * 13 + 18 + 8 or 0
    local others = item.voteCount - (item.voted and 1 or 0)
    local text
    if item.voteCount == 0 then
        text = item.mine and "Nobody said me too yet" or "Be the first to say me too"
    elseif item.mine then
        text = item.voteCount == 1 and (Short(keys[1]) .. " wants this too")
            or (item.voteCount .. " members want this too")
    elseif item.voted then
        if others == 0 then text = "You want this"
        elseif others == 1 then
            local other = keys[1] ~= nil and ns.Util.IsMe(keys[1]) and keys[2] or keys[1]
            text = "You and " .. Short(other) .. " want this"
        elseif others == 2 then
            text = "You, " .. Short(keys[2]) .. " and " .. Short(keys[3]) .. " want this too"
        else text = "You and " .. others .. " others want this" end
    else
        text = item.voteCount == 1 and (Short(keys[1]) .. " wants this too")
            or (item.voteCount .. " members want this too")
    end
    d.votes:SetText(text)
    d.votes:ClearAllPoints()
    d.votes:SetPoint("LEFT", d.child, "TOPLEFT", fx + facesW, y - 11)
    d.votesHover:ClearAllPoints()
    d.votesHover:SetPoint("TOPLEFT", d.child, "TOPLEFT", fx, y)
    d.votesHover:SetSize(max(10, inner - fx), 22)
    y = y - 34

    -- answers
    d.ansHead:ClearAllPoints()
    d.ansHead:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
    d.ansHead:SetWidth(inner)
    d.ansHead:SetRight(#item.replies > 0 and #item.replies or nil)
    y = y - 24 - 3
    for _, b in ipairs(d.bubbles) do b:Hide() end
    d.noAns:SetShown(#item.replies == 0)
    if #item.replies == 0 then
        d.noAns:ClearAllPoints()
        d.noAns:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
        d.noAns:SetWidth(inner)
        local canReply = F:CanReply(item)
        d.noAns:SetText(item.mine and "No answers yet. The developer and the officers answer here."
            or (canReply and ("No answers yet. " .. Short(item.author) .. " sees yours at once, or at the next login.")
            or "No answers yet."))
        y = y - 20
    end
    for i, rep in ipairs(item.replies) do
        local b = d.bubbles[i]
        if not b then
            b = NewBubble(d.child)
            d.bubbles[i] = b
        end
        local h = b:Set(rep, inner)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", d.child, "TOPLEFT", 0, y)
        b:Show()
        y = y - h - 8
    end
    d.child:SetHeight(max(10, -y + 4))

    -- bottom
    -- (staff answer and decide in the Inbox; elsewhere the box is the author's and the header has Status)
    local canReply = F:CanReply(item) and (inbox or item.mine)
    local bottom = 12
    local bar = staff and inbox
    d.staffNote:SetShown(bar)
    for _, b in ipairs({ d.plan, d.exists, d.notnow, d.same }) do b:SetShown(bar) end
    if bar then
        d.staffNote:ClearAllPoints()
        d.staffNote:SetPoint("BOTTOMLEFT", panel.detailBox, "BOTTOMLEFT", IN, bottom)
        d.staffNote:SetText((item.stateBy and item.state and item.state ~= "open")
            and ("What you type goes out with the status you pick.  Status set by " .. Short(item.stateBy) .. ".")
            or "What you type goes out with the status you pick.")
        bottom = bottom + 16
        d.plan:SetShown(item.state ~= "planned" and not item.closed)
        local bx = IN
        for _, b in ipairs({ d.plan, d.exists, d.notnow, d.same }) do
            if b:IsShown() then
                b:ClearAllPoints()
                b:SetPoint("BOTTOMLEFT", panel.detailBox, "BOTTOMLEFT", bx, bottom)
                bx = bx + b:GetWidth() + 6
            end
        end
        bottom = bottom + S.BTN_H + S.GAP
    end
    d.reply:SetShown(canReply)
    d.answer:SetShown(canReply)
    if canReply then
        d.answer:ClearAllPoints()
        d.answer:SetPoint("BOTTOMRIGHT", panel.detailBox, "BOTTOMRIGHT", -IN, bottom)
        d.reply:ClearAllPoints()
        d.reply:SetPoint("BOTTOMLEFT", panel.detailBox, "BOTTOMLEFT", IN, bottom)
        d.reply:SetWidth(width - 2 * IN - 68 - 6)
        UI():SetEditPlaceholder(d.reply, item.mine and "Add something" or ("Answer " .. Short(item.author)))
        bottom = bottom + 24 + 10
    end
    d.scroll:SetSize(width - 2 * IN - SCROLL_LANE, max(40, DetailHeight() - bottom))
end

---------------------------------------------------------------------------
-- Page
---------------------------------------------------------------------------

local TABS = {
    { key = "all", label = "Everything" },
    { key = "mine", label = "Yours" },
    { key = "inbox", label = "Inbox", staff = true },
}

local function CurrentSort()
    return state.sort or (state.tab == "mine" and "new" or "asked")
end

local function Rows()
    local F = FB()
    local filter = { kind = state.kind, text = state.search }
    if state.tab == "mine" then filter.mine = true end
    if state.tab == "inbox" then filter.inbox = true end
    local items = F:List(filter, CurrentSort())
    local rows = {}
    if state.tab == "inbox" then
        if #items > 0 then rows[1] = { header = "Waiting for an answer", count = #items } end
        for _, item in ipairs(items) do rows[#rows + 1] = { item = item } end
        return rows, items
    end
    local open, done = {}, {}
    for _, item in ipairs(items) do
        if item.closed then done[#done + 1] = item else open[#open + 1] = item end
    end
    if #open > 0 then
        rows[#rows + 1] = { header = "Open", count = #open }
        for _, item in ipairs(open) do rows[#rows + 1] = { item = item } end
    end
    if #done > 0 then
        rows[#rows + 1] = { header = state.tab == "mine" and "Done" or "Done lately", count = #done }
        for _, item in ipairs(done) do rows[#rows + 1] = { item = item } end
    end
    return rows, items
end

function FeedbackUI:Refresh()
    if not panel then return end
    local F = FB()
    local staff = F:AmIStaff()
    if state.tab == "inbox" and not staff then state.tab = "all" end
    panel.banner.stats:SetText(StatsText())
    -- tabs (the layout's toolbar)
    local bar = panel.layout.toolbar
    for _, t in ipairs(TABS) do
        local on = not t.staff or staff
        bar:SetTabShown(t.key, on)
        if on then
            local label = t.label
            if t.key == "inbox" then
                local n = F:InboxCount()
                if n > 0 then label = label .. "  " .. S:Wrap("GOLD", n) end
            elseif t.key == "mine" and self:NewsCount() > 0 then
                label = label .. " |TInterface\\COMMON\\Indicator-Yellow:12:12:0:0|t"
            end
            bar:SetTabLabel(t.key, label)
        end
    end
    bar:SelectTab(state.tab)
    panel.kindBar:Select(state.kind or "all")
    panel.sortLink:Refresh()
    -- list
    local rows, items = Rows()
    local found = false
    for _, item in ipairs(items) do
        if item.id == state.sel then found = true end
    end
    if not found then state.sel = items[1] and items[1].id or nil end
    local empty
    if state.tab == "inbox" then
        empty = { title = "All caught up", text = "All caught up: nothing waits for an answer." }
    elseif state.tab == "mine" then
        empty = { title = "Nothing yet", text = "What you send, and what you say me too to, shows here." }
    elseif state.search ~= "" or state.kind then
        empty = { title = "No match", text = "Nothing matches." }
    end
    if empty then empty.glyph = UI().ICON.notes end
    panel.list:SetEmptyState(empty)
    panel.list:SetData(rows)
    RenderDetail()
end

function FeedbackUI:Select(id)
    state.sel = id
    if not panel then return end
    panel.list:Refresh()
    RenderDetail()
    panel.layout.toolbar:SetTabLabel("mine",
        self:NewsCount() > 0 and "Yours |TInterface\\COMMON\\Indicator-Yellow:12:12:0:0|t" or "Yours")
end

-- Opens the page on a tab ("all" | "mine" | "inbox"), an item picked when given.
function FeedbackUI:Open(tab, id)
    if tab then state.tab = tab end
    if id then
        state.sel = id
        state.kind, state.search = nil, ""
        if panel and panel.search then panel.search:SetText("") end
    end
    if ns.MainFrame then ns.MainFrame:Open("feedback") end
end

function FeedbackUI:GetState() return state end
function FeedbackUI:GetPanel() return panel end

function FeedbackUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p

    p.banner = CreateTopBanner(p)

    -- a list + detail page under the banner: the toolbar (the tabs; the sort, the kinds and the search as its
    -- filters), the list and the item (its band is the item's banner)
    local L = UI():CreateLayout("listdetail", p, { top = TABS_Y, listWidth = LIST_W, bottom = PAD,
        banner = { size = "tool", icon = "notes" } })
    L.banner:Hide()
    p.layout = L
    local bar = L.toolbar
    local tabs = {}
    for _, t in ipairs(TABS) do tabs[#tabs + 1] = { key = t.key, text = t.label } end
    tabs.selected = state.tab
    bar:SetTabs(tabs, function(key)
        state.tab = key
        state.sel = nil
        FeedbackUI:Refresh()
    end)
    p.tabs = {}
    for _, t in ipairs(TABS) do p.tabs[t.key] = bar:GetTab(t.key) end

    -- right of the tabs: sort, kinds, search
    p.search = UI():CreateSearchBox(bar, 130, function(text)
        state.search = text or ""
        FeedbackUI:Refresh()
    end, "Search")
    -- the kinds: All and the four icons (the shared segments); a click on the picked kind goes back to All
    local kindItems = { { key = "all", label = "All", tip = "Every kind." } }
    for _, k in ipairs({ "bug", "idea", "change", "love" }) do
        local info = FB().KIND_INFO[k]
        kindItems[#kindItems + 1] = { key = k, label = "|T" .. info.icon .. ":14:14:0:0:64:64:5:59:5:59|t",
            tip = (info.short == "Love" and "Love" or (info.short .. "s")) .. ": only these. Click again for every kind." }
    end
    local kinds = UI():CreateSegments(bar, kindItems, function(key)
        if key ~= "all" and state.kind == key then
            state.kind = nil
        else
            state.kind = key ~= "all" and key or nil
        end
        FeedbackUI:Refresh()
    end, { h = 22, itemW = 28, selected = "all" })
    p.kindBar = kinds
    p.sortLink = UI():CreateLinkDropdown(bar, {
        font = "GameFontHighlightSmall", size = 11, color = { 0.81, 0.81, 0.81 },
        options = function() return { { value = "asked", text = "Most asked" }, { value = "new", text = "Newest" } } end,
        selected = CurrentSort,
        select = function(v)
            state.sort = v
            FeedbackUI:Refresh()
        end,
    })
    bar:SetFilters({ p.sortLink, kinds, p.search })

    -- the list in the list column (the shared rows), the item in the detail: its banner, its body
    p.list = UI():CreateScrollList(L.list, ROW_H, InitRow, RowHeight)
    p.list.frame:SetAllPoints(L.list)
    p.detailBox = L.body
    p.detail = BuildDetail(L.body, L.banner)
    L.body:SetScript("OnSizeChanged", function() if p:IsVisible() then RenderDetail() end end)

    function p:OnPanelShown()
        FeedbackUI:Refresh()
    end
    return p
end

function FeedbackUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("feedback", "Feedback", 3.85, function(parent) return FeedbackUI:CreatePanel(parent) end,
            nil, { layout = "listdetail" })
    end
    local function soon()
        if panel and panel:IsVisible() then
            ns.Util.Debounce("feedback-ui", 0.1, function() FeedbackUI:Refresh() end)
        end
    end
    ns:On("FEEDBACK_UPDATED", soon)
    ns:On("DEMO_TOGGLED", function()
        state.sel = nil
        soon()
    end)
    ns:RegisterSlash("feedback", function(rest)
        rest = ns.Util.Trim(rest or "")
        if rest ~= "" and ns.FeedbackSheet then ns.FeedbackSheet:Open({ text = rest }) else FeedbackUI:Open() end
    end, "send feedback: a bug, an idea or a change (/dz feedback <text> opens the form with it)")
end

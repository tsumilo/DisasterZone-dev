if DisasterZoneBoot and DisasterZoneBoot.Run("UI/FeedbackPlan.lua", ...) then return end -- DisasterZone: UI/FeedbackPlan.lua
-- The Feedback page's Plan tab (staff) and the planning bits around it (Core/FeedbackPlan.lua), as in the approved
-- mockup (dev/art/casc/planner_mockup):
--   Board    a column per open release (its version, date, theme, an hours bar against its budget) between "To sort"
--            (open items nobody placed) and "Later"; cards (kind, words, size, number, me-toos, group, who) drag
--            between columns (a group moves together); a right-click opens the card's menu; the column's ··· holds
--            Release check and the release's settings.
--   Sort     the unplaced items one at a time: how big, which release, Save and next; items that look like it.
--   Roadmap  the releases in order with their themes and items; "Guild sees it" per release (Coming next).
-- Only the developer edits (P:CanEdit); officers see the same views read-only. Plan it in the Inbox opens a small
-- popover (size, release, group, note) for the developer; Release check is a sheet. Demo mode works on the demo plan.
local addonName, ns = ...

local PlanUI = ns:NewModule("FeedbackPlanUI")
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local function UI() return ns.UI end
local function P() return ns.FeedbackPlan end
local function F() return ns.Feedback end
local function FUI() return ns.FeedbackUI end

local WRAP = { wrap = true }
local LATER = "later"
local CARD_H = 52
local HEAD_H = 62
local MIN_COL = 180         -- a release column never gets narrower: releases past what fits page with the arrows
local SIDE_W = 160          -- To sort and Later: narrower, the releases get the room
local GAP = S.GAP
local DEV_ICON = "Interface\\Icons\\INV_Misc_Note_01"
local SIZE_PILL = { S = "ok", M = "bis", L = "warn", XL = "bad" }
local DEV_KIND_LABEL = { idea = "Idea", change = "Change", bug = "Bug", chore = "Chore" }

local state = { view = "board" }
local host           -- the Plan tab's frame (inside the Feedback page)

local function Refresh() if host and host:IsShown() then PlanUI:Refresh() end end

local function Say(ok, err) if not ok and err then ns:Print(err) end end

-- "Sun 18 Oct".
local function Day(ts)
    if not ts then return nil end
    return (date("%a %d %b", ts):gsub(" 0", " "))
end

-- A release's name for a column / a chip: "1.5.3", "Later", "To sort".
local function RelName(rl)
    if rl == nil then return "To sort" end
    if rl == LATER then return "Later" end
    return rl
end

---------------------------------------------------------------------------
-- Small pieces
---------------------------------------------------------------------------

-- The kind icon of a card: the feedback's kind icon (a ring of its colour), or a note for the developer's own items.
local function NewKindIcon(parent, size)
    local f = FUI().KindIcon(parent, size)
    function f:SetCard(c)
        if c.dev then
            self:Set(DEV_ICON)
            self.tex:SetDesaturated(false)
            self.tex:SetVertexColor(1, 1, 1)
            self.ring:SetColorTexture(S:Alpha("GOLD", 0.55))
        else
            self:SetKind(c.kind, c.done)
        end
    end
    return f
end

local function SizeText(sz) return sz or "?" end

-- The card's words for a tooltip / a menu: "#21 Auto-sell junk..." cut to n characters.
local function Short(c, n)
    local t = (c.text or ""):gsub("\n", " ")
    if #t > n then t = t:sub(1, n - 3):gsub("%s+%S*$", "") .. "..." end
    local ref = c.dev and ("D-" .. (c.dno or "?")) or (c.no and ("#" .. c.no) or "")
    return (ref ~= "" and (ref .. "  ") or "") .. t
end
PlanUI.Short = Short

-- The segments' items for a release pick: every open release, Later, and (opts) To sort / Not planned.
local function ReleaseItems(withSort)
    local items = {}
    for _, r in ipairs(P():Releases()) do
        local h = P():Load(r.v)
        items[#items + 1] = { key = r.v, label = r.v, tip = (r.th or r.v) .. (r.bg and (": " .. h .. " of " .. r.bg .. " h")
            or "") }
    end
    items[#items + 1] = { key = LATER, label = "Later", tip = "Planned, no release yet." }
    if withSort then items[#items + 1] = { key = "none", label = "To sort", tip = "Back to the items nobody placed." } end
    return items
end

local function SizeItems()
    local items = {}
    for _, sz in ipairs(P().SIZES) do
        items[#items + 1] = { key = sz, label = sz, tip = sz .. ": " .. P().SIZE_INFO[sz].hint }
    end
    return items
end

---------------------------------------------------------------------------
-- A card's menu (the developer): size, release, group, note, done, take off
---------------------------------------------------------------------------

local function AskGroup(c)
    ns.Popup:Prompt({ title = "New group", text = "A name for the items that go together (\"Merchant helpers\").",
        ok = "Group", onAccept = function(v)
            if v and ns.Util.Trim(v) ~= "" then Say(P():SetGroup(c.key, v)) end
        end })
end

local function AskNote(c)
    ns.Popup:Prompt({ title = "Note", text = "Only staff see it.", default = c.nt or "", ok = "Save",
        onAccept = function(v) Say(P():SetNote(c.key, v)) end })
end

function PlanUI:CardMenu(root, c)
    local Plan = P()
    root:CreateTitle(Short(c, 40))
    if not Plan:CanEdit() then
        if c.item then root:CreateButton("Open it", function() FUI():Open("all", c.key) end) end
        return
    end
    local size = root:CreateButton("Size")
    for _, sz in ipairs(Plan.SIZES) do
        size:CreateRadio(sz .. "  " .. S:Wrap("SUB", Plan.SIZE_INFO[sz].hint), function() return c.sz == sz end,
            function() Say(Plan:SetSize(c.key, sz)) end)
    end
    local move = root:CreateButton("Move to")
    for _, it in ipairs(ReleaseItems(true)) do
        local rl = it.key ~= "none" and it.key or nil
        move:CreateRadio(it.label, function() return c.rl == rl end, function() Say(Plan:Place(c.key, rl)) end)
    end
    local grp = root:CreateButton("Group")
    for _, g in ipairs(Plan:Groups()) do
        grp:CreateRadio(g, function() return c.g == g end, function() Say(Plan:SetGroup(c.key, g)) end)
    end
    grp:CreateButton("New group...", function() AskGroup(c) end)
    if c.g then grp:CreateButton("No group", function() Say(Plan:SetGroup(c.key, nil)) end) end
    root:CreateButton(c.nt and "Note..." or "Add a note...", function() AskNote(c) end)
    if c.item then root:CreateButton("Open it", function() FUI():Open("all", c.key) end) end
    root:CreateDivider()
    if c.dev then
        root:CreateButton(c.done and "Not done" or "Done", function() Say(Plan:SetDone(c.key, not c.done)) end)
        root:CreateButton(S:Wrap("BAD", "Delete"), function() Say(Plan:Remove(c.key)) end)
    elseif P():Entry(c.key) then
        root:CreateButton("Take off the plan", function() Say(Plan:Remove(c.key)) end)
    end
end

---------------------------------------------------------------------------
-- Cards and dragging
---------------------------------------------------------------------------

local drag = { card = nil, ghost = nil, over = nil }
local columns = {}    -- the board's columns (the drop targets)

local function ColumnUnderCursor()
    for _, col in ipairs(columns) do
        if col:IsShown() and col:IsMouseOver() then return col end
    end
    return nil
end

local function Ghost()
    local g = drag.ghost
    if g then return g end
    g = CreateFrame("Frame", nil, UIParent)
    g:SetFrameStrata("TOOLTIP")
    g:SetSize(170, 30)
    g.bg = UI():Fill(g, "DROP_BG")
    UI():SetEdges(g, S:Alpha("GOLD", 0.8))
    g.text = UI():Text(g, "body", "TEXT")
    g.text:SetPoint("LEFT", 8, 0)
    g.text:SetPoint("RIGHT", -8, 0)
    g:EnableMouse(false)
    g:Hide()
    drag.ghost = g
    return g
end

local function MarkDrop(col)
    if drag.over == col then return end
    if drag.over then drag.over:SetDrop(false) end
    drag.over = col
    if col then col:SetDrop(true) end
end

local function EndDrag(cancel)
    local c = drag.card
    if not c then return end
    drag.card = nil
    local g = Ghost()
    g:SetScript("OnUpdate", nil)
    g:Hide()
    local col = drag.over
    MarkDrop(nil)
    if not cancel and col and col.rl ~= c.rl then
        Say(P():Place(c.key, col.rl))
    end
    Refresh()
end

local function BeginDrag(btn)
    local c = btn.card
    if not (c and P():CanEdit()) or drag.card then return end
    drag.card = c
    btn:SetAlpha(0.3)
    local g = Ghost()
    g.text:SetText(Short(c, 30))
    g:SetScript("OnUpdate", function(self)
        if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return EndDrag() end
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / s + 10, y / s - 6)
        MarkDrop(ColumnUnderCursor())
    end)
    g:Show()
    if GameTooltip then GameTooltip:Hide() end
end

local function CardTip(btn)
    local c = btn.card
    if not c then return end
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    local info = (not c.dev) and F().KIND_INFO[c.kind]
    GameTooltip:AddLine((c.dev and ("Your own " .. (DEV_KIND_LABEL[c.kind] or "item"):lower()) or (info and info.short or ""))
        .. (c.no and ("  #" .. c.no) or (c.dno and ("  D-" .. c.dno) or "")), S:RGB("GOLD"))
    GameTooltip:AddLine(c.text or "", 1, 1, 1, true)
    if c.sz then GameTooltip:AddDoubleLine("Size", c.sz .. ", " .. P().SIZE_INFO[c.sz].hint, 0.7, 0.7, 0.7, 1, 1, 1) end
    if c.g then GameTooltip:AddDoubleLine("Group", c.g, 0.7, 0.7, 0.7, 1, 1, 1) end
    if c.nt then GameTooltip:AddDoubleLine("Note", c.nt, 0.7, 0.7, 0.7, 1, 1, 1) end
    if c.author then GameTooltip:AddDoubleLine("From", ns.Util.ShortName(c.author), 0.7, 0.7, 0.7, 1, 1, 1) end
    if (c.votes or 0) > 0 then GameTooltip:AddDoubleLine("Me too", c.votes, 0.7, 0.7, 0.7, 1, 1, 1) end
    GameTooltip:AddLine(P():CanEdit() and "Drag to move it. Right-click for size, group and note."
        or "The developer plans: you see the plan.", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function NewPlanCard(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(CARD_H)
    b.bg = UI():Fill(b, "CARD")
    UI():AddEdges(b, "BORDER")
    UI():DecorateRow(b, { selectable = false })
    b.icon = NewKindIcon(b, 18)
    b.icon:SetPoint("TOPLEFT", 6, -6)
    b.text = UI():Text(b, "body", "TEXT", WRAP)
    b.text:SetPoint("TOPLEFT", 30, -6)
    b.text:SetHeight(2 * (S.FONT.body + 3))
    b.text:SetJustifyV("TOP")
    if b.text.SetMaxLines then b.text:SetMaxLines(2) end
    b.size = UI():CreatePill(b, nil, nil, 14)
    b.size:SetPoint("BOTTOMLEFT", 30, 5)
    b.meta = UI():Text(b, "small", "SUB")
    b.meta:SetPoint("LEFT", b.size, "RIGHT", 5, 0)
    b.grp = b:CreateTexture(nil, "OVERLAY")
    b.grp:SetSize(11, 11)
    b.who = UI():Text(b, "small", "SUB")
    b.who:SetPoint("BOTTOMRIGHT", -6, 6)
    b.who:SetJustifyH("RIGHT")
    b.who:SetWordWrap(false)
    b.slip = b:CreateTexture(nil, "OVERLAY")
    b.slip:SetPoint("TOPLEFT")
    b.slip:SetPoint("BOTTOMLEFT")
    b.slip:SetWidth(2)
    b.slip:SetColorTexture(S:Color("WARN"))
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", BeginDrag)
    b:SetScript("OnDragStop", function() EndDrag() end)
    b:SetScript("OnEnter", CardTip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self, button)
        local c = self.card
        if not c then return end
        if button == "RightButton" or c.dev then
            UI():ContextMenu(self, function(root) PlanUI:CardMenu(root, c) end)
        else
            FUI():Open("all", c.key)
        end
    end)
    function b:Set(c, width)
        self.card = c
        self:SetAlpha(1)
        self:SetWidth(width)
        self.icon:SetCard(c)
        -- (two lines at most: cut to about two widths before it wraps)
        local tw = width - 36
        self.text:SetWidth(tw)
        UI():FitText(self.text, UI():SafeText((c.text or ""):gsub("\n", " ")), floor(tw * 1.7))
        -- (as tall as the words need, so the pill row never sits on them)
        local th = min(self.text:GetStringHeight() or 0, 2 * (S.FONT.body + 3))
        self:SetHeight(max(CARD_H, floor(6 + th + 6 + 18 + 5)))
        local tc = c.done and 0.6 or 0.92
        self.text:SetTextColor(tc, tc, tc)
        self.size:Set(c.done and "Done" or SizeText(c.sz), c.done and "ok" or (SIZE_PILL[c.sz] or "mute"))
        local parts = {}
        if c.no then parts[#parts + 1] = "#" .. c.no elseif c.dno then parts[#parts + 1] = "D-" .. c.dno end
        if (c.votes or 0) > 0 then parts[#parts + 1] = S:Wrap("GOLD", "+" .. c.votes) end
        self.meta:SetText(tconcat(parts, "  "))
        self.grp:SetShown(c.g ~= nil)
        if c.g then
            UI():SetGlyph(self.grp, UI().ICON.pair, "SUB")
            self.grp:ClearAllPoints()
            self.grp:SetPoint("LEFT", self.meta, "RIGHT", 5, 0)
        end
        if c.author then
            self.who:SetText(UI():ColoredName(c.author))
        else
            self.who:SetText(S:Wrap("DIM", c.dev and "only staff" or ""))
        end
        -- (the name gets what the pill, number and group mark leave: cut with "...", never drawn over them)
        local left = 30 + (self.size:GetWidth() or 20) + 5 + (self.meta:GetStringWidth() or 0) + (c.g and 16 or 0) + 8
        self.who:SetWidth(max(20, min((self.who:GetStringWidth() or 0) + 2, width - left - 6)))
        UI():SetEdgeColor(self, S:Color("EDGE"))
        self.slip:SetShown(c.slipped and true or false)
    end
    return b
end

---------------------------------------------------------------------------
-- Board
---------------------------------------------------------------------------

local function NewColumn(parent)
    local col = CreateFrame("Frame", nil, parent)
    col.bg = UI():Fill(col, "INSET")
    UI():AddEdges(col, "BORDER")
    UI():SetEdgeColor(col, S:Color("EDGE_QUIET"))
    col.title = UI():Text(col, "title", "GOLD")
    col.title:SetPoint("TOPLEFT", 8, -8)
    col.date = UI():Text(col, "small", "SUB")
    col.date:SetPoint("BOTTOMLEFT", col.title, "BOTTOMRIGHT", 8, 1)
    col.date:SetJustifyH("LEFT")
    col.date:SetWordWrap(false)
    -- (the arrows through the releases when they don't all fit: on the first and the last release column)
    col.prev = UI():CreateArrowButton(col, false, 18, 18, function() PlanUI:PageReleases(-1) end)
    col.prev:SetPoint("TOPLEFT", 5, -6)
    UI():AttachTooltip(col.prev, "Earlier releases", nil, { anchor = "ANCHOR_TOP" })
    col.prev:Hide()
    col.next = UI():CreateArrowButton(col, true, 18, 18, function() PlanUI:PageReleases(1) end)
    col.next:SetPoint("TOPRIGHT", -25, -6)
    UI():AttachTooltip(col.next, "Later releases", nil, { anchor = "ANCHOR_TOP" })
    col.next:Hide()
    col.more = UI():CreateTipIconButton(col, 18, UI().ICON.more, "Release", "Release check, and the release's settings.",
        function(self) if col.rl and col.rl ~= LATER then PlanUI:ReleaseMenu(self, col.rl) end end)
    col.more:SetPoint("TOPRIGHT", -4, -5)
    col.theme = UI():Text(col, "small", "SUB")
    col.theme:SetPoint("TOPLEFT", 8, -25)
    col.theme:SetPoint("RIGHT", col, "RIGHT", -8, 0)
    col.theme:SetJustifyH("LEFT")
    col.bar = UI():CreateProgressBar(col, { height = 3 })
    col.bar:SetPoint("TOPLEFT", 8, -41)
    col.bar:SetPoint("TOPRIGHT", -8, -41)
    col.load = UI():Text(col, "small", "SUB")
    col.load:SetPoint("TOPLEFT", 8, -47)
    col.items = UI():Text(col, "small", "DIM")
    col.items:SetPoint("TOPRIGHT", -8, -47)
    col.items:SetJustifyH("RIGHT")
    col.sf = UI():CreateScrollFrame(col)
    col.sf:SetPoint("TOPLEFT", 6, -HEAD_H)
    col.child = CreateFrame("Frame", nil, col.sf)
    col.child:SetSize(100, 10)
    col.sf:SetScrollChild(col.child)
    col.empty = UI():Text(col.child, "small", "DIM")
    col.empty:SetJustifyH("CENTER")
    col.empty:SetText("Nothing here")
    col.foot = UI():CreateSleekButton(col, "Sort them", 100, 22, function() PlanUI:SetView("sort") end)
    col.foot:SetPoint("BOTTOMLEFT", 6, 6)
    col.foot:SetPoint("BOTTOMRIGHT", -6, 6)
    col.cards = {}
    function col:SetDrop(on)
        if on then
            self.bg:SetColorTexture(S:Color("SELECT"))
            UI():SetEdgeColor(self, S:Alpha("GOLD", 0.7))
        else
            self.bg:SetColorTexture(S:Color("INSET"))
            UI():SetEdgeColor(self, S:Color("EDGE_QUIET"))
        end
    end
    return col
end

-- Lays out one column for release r (nil: To sort; { v = LATER }: Later) at width w, height h.
local function FillColumn(col, rl, rel, w, h, page)
    local Plan = P()
    col.rl = rl
    col:SetSize(w, h)
    col.title:SetText(RelName(rl))
    col.title:SetTextColor(S:Color(rel and "GOLD" or "TEXT"))
    col.date:SetText(rel and rel.dt and Day(rel.dt) or "")
    col.more:SetShown(rel ~= nil)
    col.title:ClearAllPoints()
    col.title:SetPoint("TOPLEFT", (page == -1) and 28 or 8, -8)
    col.prev:SetShown(page == -1)
    col.next:SetShown(page == 1)
    -- (the date after the version, cut before the buttons on the right)
    local right = (rel and 26 or 8) + (page == 1 and 21 or 0)
    col.date:SetWidth(max(10, w - ((page == -1) and 28 or 8) - (col.title:GetStringWidth() or 0) - 8 - right))
    col.theme:SetText(rel and (rel.th or "") .. (rel.pub and "" or S:Wrap("DIM", rel.th and "  · staff only" or "Staff only"))
        or (rl == nil and "New, not placed yet" or "Good ideas, no date yet"))
    local cards = Plan:Cards(rl)
    local hours, unsized = Plan:Load(rl)
    col.bar:SetShown(rel ~= nil and rel.bg ~= nil)
    if rel and rel.bg then
        local over = hours > rel.bg
        col.bar:Set(rel.bg > 0 and min(1, hours / rel.bg) or 1, over and "BAD" or "GOLD")
        col.load:SetText((over and S:Wrap("BAD", hours .. " h") or S:Wrap("TEXT", hours .. " h")) .. S:Wrap("SUB", " of " .. rel.bg .. " h")
            .. (unsized > 0 and S:Wrap("DIM", "  · " .. unsized .. " unsized") or ""))
    else
        col.load:SetText(hours > 0 and S:Wrap("SUB", "~" .. hours .. " h") or "")
    end
    col.items:SetText(#cards == 1 and "1 item" or (#cards .. " items"))
    local footH = (rl == nil and #cards > 0) and 34 or 6
    col.foot:SetShown(rl == nil and #cards > 0)
    col.sf:SetSize(w - 12 - 6, max(20, h - HEAD_H - footH))
    local cw = w - 12 - 8
    col.child:SetWidth(cw)
    local y = 0
    for i, c in ipairs(cards) do
        local b = col.cards[i]
        if not b then
            b = NewPlanCard(col.child)
            col.cards[i] = b
        end
        b:Set(c, cw)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", col.child, "TOPLEFT", 0, y)
        b:Show()
        y = y - b:GetHeight() - 5
    end
    for i = #cards + 1, #col.cards do col.cards[i]:Hide() end
    col.empty:SetShown(#cards == 0)
    if #cards == 0 then
        col.empty:ClearAllPoints()
        col.empty:SetPoint("TOP", col.child, "TOP", 0, -14)
        col.empty:SetWidth(cw)
        col.empty:SetText(Plan:CanEdit() and "Drop items here" or "Nothing here")
    end
    col.child:SetHeight(max(10, -y))
    col:SetDrop(false)
    col:Show()
end

-- Steps the board's releases one column on (dir 1) or back (-1).
function PlanUI:PageReleases(dir)
    state.relFirst = (state.relFirst or 1) + (dir or 1)
    Refresh()
end

local function RenderBoard(frame, w, h)
    local rels = P():Releases()
    -- (To sort and Later always show; as many releases between them as fit at MIN_COL, at least one)
    local side = min(SIDE_W, floor((w - 3 * GAP) / 3))
    local slots = max(1, min(4, floor((w - 2 * side - GAP) / (MIN_COL + GAP))))
    local first = max(1, min(state.relFirst or 1, #rels - slots + 1))
    state.relFirst = first
    local last = min(#rels, first + slots - 1)
    local list = { { rl = nil } }
    for i = first, last do
        local it = { rl = rels[i].v, rel = rels[i] }
        if i == first and first > 1 then it.page = -1 end
        if i == last and last < #rels then it.page = 1 end
        list[#list + 1] = it
    end
    list[#list + 1] = { rl = LATER }
    local n = #list
    local rw = floor((w - 2 * side - (n - 1) * GAP) / (n - 2))
    local x = 0
    for i, it in ipairs(list) do
        local col = columns[i]
        if not col then
            col = NewColumn(frame)
            columns[i] = col
        end
        local cw = (i == 1 or i == n) and side or rw
        col:ClearAllPoints()
        col:SetPoint("TOPLEFT", frame, "TOPLEFT", x, 0)
        FillColumn(col, it.rl, it.rel, cw, h, it.page)
        x = x + cw + GAP
    end
    for i = n + 1, #columns do columns[i]:Hide() end
end

---------------------------------------------------------------------------
-- Sort: the unplaced items one at a time
---------------------------------------------------------------------------

local function BuildSort(frame)
    local v = CreateFrame("Frame", nil, frame)
    v:SetAllPoints()
    v.box = UI():CreateCard(v, { tone = "card", pad = 0 })
    v.box:SetPoint("TOPLEFT")
    v.box:SetPoint("BOTTOMLEFT")
    v.side = CreateFrame("Frame", nil, v)
    v.side:SetPoint("TOPRIGHT")
    v.side:SetPoint("BOTTOMRIGHT")
    local b = v.box
    v.prog = UI():Text(b, "small", "SUB")
    v.prog:SetPoint("TOPLEFT", 12, -10)
    v.keys = UI():Text(b, "small", "DIM")
    v.keys:SetPoint("TOPRIGHT", -12, -10)
    v.keys:SetJustifyH("RIGHT")
    v.icon = FUI().KindIcon(b, 32)
    v.icon:SetPoint("TOPLEFT", 12, -30)
    v.kind = UI():Text(b, "title", "GOLD")
    v.kind:SetPoint("TOPLEFT", 54, -31)
    v.who = UI():Text(b, "small", "SUB")
    v.who:SetPoint("TOPLEFT", 54, -48)
    v.text = UI():Text(b, "emph", "TEXT", WRAP)
    v.text:SetPoint("TOPLEFT", 12, -72)
    v.text:SetSpacing(2)
    v.chips = UI():Text(b, "small", "SUB")
    v.sizeLbl = UI():Text(b, "caps", "SUB")
    v.sizeLbl:SetText("How big")
    v.size = UI():CreateSegments(b, SizeItems(), function(key) v.pickSize = key end, { h = 26, itemW = 64 })
    v.relLbl = UI():Text(b, "caps", "SUB")
    v.relLbl:SetText("Which release")
    v.rel = UI():CreateSegments(b, ReleaseItems(), function(key) v.pickRel = key; PlanUI:RenderSortSide() end,
        { h = 26 })
    v.save = UI():CreateSleekButton(b, "Save and next", 110, S.BTN_H, function() PlanUI:SortSave() end, "primary")
    v.save:SetPoint("BOTTOMLEFT", 12, 12)
    v.answer = UI():CreateSleekButton(b, "Answer first", 96, S.BTN_H, function()
        if v.item then FUI():Open("inbox", v.item.id) end
    end)
    v.answer:SetPoint("LEFT", v.save, "RIGHT", 6, 0)
    v.skip = UI():CreateSleekButton(b, "Skip", 60, S.BTN_H, function() PlanUI:SortStep(1) end)
    v.skip:SetPoint("LEFT", v.answer, "RIGHT", 6, 0)
    v.none = UI():CreateEmptyState(v, { glyph = UI().ICON.notes, title = "All sorted",
        text = "Every open item has a place. New feedback shows up here." })
    v.none:SetPoint("TOP", 0, -60)
    v.none:Hide()
    -- the side: looks like, the release with this, who asked
    local function card(title)
        local c = UI():CreateCard(v.side, { tone = "card", pad = 0 })
        c.head = UI():CreateSectionHeader(c, title, { style = "caps", rule = false })
        c.head:SetPoint("TOPLEFT", 10, -6)
        c.head:SetPoint("TOPRIGHT", -10, -6)
        c.text = UI():Text(c, "small", "TEXT", WRAP)
        c.text:SetPoint("TOPLEFT", 10, -28)
        c.text:SetPoint("RIGHT", c, "RIGHT", -10, 0)
        c.text:SetJustifyH("LEFT")
        c.text:SetSpacing(3)
        return c
    end
    v.like = card("Looks like")
    v.like:SetPoint("TOPLEFT", v.side, "TOPLEFT")
    v.like:SetPoint("TOPRIGHT", v.side, "TOPRIGHT")
    v.like:SetHeight(120)
    v.group = UI():CreateSleekButton(v.like, "Group with it", 110, 22, function() PlanUI:SortGroup() end)
    v.group:SetPoint("BOTTOMLEFT", 10, 10)
    v.load = card("The release with this")
    v.load:SetPoint("TOPLEFT", v.like, "BOTTOMLEFT", 0, -GAP)
    v.load:SetPoint("TOPRIGHT", v.like, "BOTTOMRIGHT", 0, -GAP)
    v.load:SetHeight(84)
    v.load.bar = UI():CreateProgressBar(v.load, { height = 3 })
    v.load.bar:SetPoint("TOPLEFT", 10, -30)
    v.load.bar:SetPoint("TOPRIGHT", -10, -30)
    v.load.text:SetPoint("TOPLEFT", 10, -40)
    v.asker = card("Asked by")
    v.asker:SetPoint("TOPLEFT", v.load, "BOTTOMLEFT", 0, -GAP)
    v.asker:SetPoint("TOPRIGHT", v.load, "BOTTOMRIGHT", 0, -GAP)
    v.asker:SetHeight(56)
    v.idx = 1
    return v
end

function PlanUI:SortQueue()
    local q = {}
    for _, c in ipairs(P():Cards(nil)) do q[#q + 1] = c end
    return q
end

function PlanUI:RenderSortSide()
    local v = host and host.sort
    if not (v and v.item) then return end
    local Plan = P()
    local sz = v.pickSize
    local rl = v.pickRel
    local rel = rl and rl ~= LATER and Plan:Release(rl)
    v.load.head:SetTitle(rel and (rl .. " with this") or (RelName(rl) .. " with this"))
    local h = Plan:Load(rl) + (sz and Plan.SIZE_H[sz] or 0)
    if rel and rel.bg then
        local over = h > rel.bg
        v.load.bar:Show()
        v.load.bar:Set(rel.bg > 0 and min(1, h / rel.bg) or 1, over and "BAD" or "GOLD")
        v.load.text:SetText((over and S:Wrap("BAD", h .. " h") or (h .. " h")) .. S:Wrap("SUB", " of " .. rel.bg .. " h")
            .. (over and S:Wrap("BAD", "  · " .. (h - rel.bg) .. " h over") or ""))
    else
        v.load.bar:Hide()
        v.load.text:SetText(S:Wrap("SUB", "~" .. h .. " h, no budget"))
    end
end

function PlanUI:RenderSort(w, h)
    local v = host.sort
    local Plan = P()
    local q = self:SortQueue()
    if v.idx > #q then v.idx = 1 end
    local c = q[v.idx]
    v.item = c and c.item or nil
    local sideW = 236
    v.box:SetWidth(w - sideW - GAP)
    v.side:SetWidth(sideW)
    v.box:SetShown(c ~= nil)
    v.side:SetShown(c ~= nil)
    v.none:SetShown(c == nil)
    if not c then return end
    v.prog:SetText(("Sorting %d new item%s  ·  %d of %d"):format(#q, #q == 1 and "" or "s", v.idx, #q))
    v.keys:SetText(Plan:CanEdit() and "Right-click a card on the Board for more" or "Only the developer plans")
    local info = F().KIND_INFO[c.kind] or F().KIND_INFO.idea
    v.icon:SetKind(c.kind)
    v.kind:SetText(UI():Colorize(info.label, info.color) .. (c.no and S:Wrap("SUB", "  #" .. c.no) or ""))
    v.who:SetText(UI():ColoredName(c.author) .. S:Wrap("SUB", "  ·  " .. (FUI().Ago and FUI().Ago(c.at) or "")))
    local tw = w - sideW - GAP - 24
    v.text:SetWidth(tw)
    v.text:SetText(UI():SafeText(c.text or ""))
    local th = min(110, max(16, tonumber(v.text:GetStringHeight()) or 16))
    local y = -72 - th - 8
    local cx = c.item and c.item.ctx or {}
    local chips = {}
    if c.item and c.item.about then chips[#chips + 1] = S:Wrap("GOLD", c.item.about) end
    if cx.v then chips[#chips + 1] = cx.v end
    if cx.z then chips[#chips + 1] = cx.z end
    if (c.votes or 0) > 0 then chips[#chips + 1] = S:Wrap("GOLD", "+" .. c.votes .. " me too") end
    v.chips:ClearAllPoints()
    v.chips:SetPoint("TOPLEFT", 12, y)
    v.chips:SetText(tconcat(chips, S:Wrap("DIM", "  ·  ")))
    y = y - 22
    v.sizeLbl:ClearAllPoints()
    v.sizeLbl:SetPoint("TOPLEFT", 12, y)
    v.size:ClearAllPoints()
    v.size:SetPoint("TOPLEFT", 12, y - 14)
    y = y - 14 - 26 - 12
    v.relLbl:ClearAllPoints()
    v.relLbl:SetPoint("TOPLEFT", 12, y)
    v.rel:SetItems(ReleaseItems())
    v.rel:ClearAllPoints()
    v.rel:SetPoint("TOPLEFT", 12, y - 14)
    if v.shownKey ~= c.key then
        v.shownKey = c.key
        v.pickSize = c.sz or "M"
        local nxt = Plan:NextRelease()
        v.pickRel = c.rl or (nxt and nxt.v) or LATER
    end
    v.size:Select(v.pickSize)
    v.rel:Select(v.pickRel)
    local edit = Plan:CanEdit()
    v.size:SetEnabled(edit)
    v.rel:SetEnabled(edit)
    v.save:SetEnabled(edit)
    v.skip:SetEnabled(#q > 1)
    -- the side
    local like = {}
    v.likeKey = nil
    for _, other in ipairs(F():Similar(c.text, c.item and c.item.about, 4)) do
        if other.id ~= c.key and #like < 3 then
            local e = Plan:Entry(other.id)
            like[#like + 1] = Short({ text = other.text, no = other.no }, 34) .. S:Wrap("DIM", "  · " .. RelName(e and e.rl))
            v.likeKey = v.likeKey or other.id
        end
    end
    v.like.text:SetText(#like > 0 and tconcat(like, "\n") or S:Wrap("DIM", "Nothing like it on the list."))
    v.group:SetShown(edit and v.likeKey ~= nil)
    v.asker.text:SetText(UI():ColoredName(c.author))
    self:RenderSortSide()
end

function PlanUI:SortStep(d)
    local v = host and host.sort
    if not v then return end
    v.idx = v.idx + d
    v.shownKey = nil
    Refresh()
end

function PlanUI:SortSave()
    local v = host and host.sort
    if not (v and v.item and P():CanEdit()) then return end
    local key = v.item.id
    Say(P():SetSize(key, v.pickSize))
    Say(P():Place(key, v.pickRel))
    v.shownKey = nil
    Refresh()
end

function PlanUI:SortGroup()
    local v = host and host.sort
    if not (v and v.item and v.likeKey) then return end
    local e = P():Entry(v.likeKey)
    if e and e.g then
        Say(P():SetGroup(v.item.id, e.g))
    else
        local other = F():Get(v.likeKey)
        local name = other and Short({ text = other.text }, 24) or "Together"
        Say(P():SetGroup(v.likeKey, name))
        Say(P():SetGroup(v.item.id, name))
    end
end

---------------------------------------------------------------------------
-- Roadmap
---------------------------------------------------------------------------

local function NewStop(parent)
    local s = CreateFrame("Frame", nil, parent)
    s.pin = s:CreateTexture(nil, "ARTWORK", nil, 2)
    s.pin:SetSize(11, 11)
    s.pin:SetPoint("TOPLEFT", 3, -10)
    if s.pin.SetRotation then s.pin:SetRotation(math.pi / 4) end
    s.pinIn = s:CreateTexture(nil, "ARTWORK", nil, 3)
    s.pinIn:SetSize(7, 7)
    s.pinIn:SetPoint("CENTER", s.pin)
    if s.pinIn.SetRotation then s.pinIn:SetRotation(math.pi / 4) end
    s.v = UI():Text(s, "page", "GOLD")
    s.v:SetPoint("TOPLEFT", 0, -30)
    s.when = UI():Text(s, "small", "SUB")
    s.when:SetPoint("TOPLEFT", 0, -50)
    s.th = UI():Text(s, "body", "TEXT", WRAP)
    s.th:SetPoint("TOPLEFT", 0, -66)
    s.list = UI():Text(s, "small", "TEXT", WRAP)
    s.list:SetSpacing(4)
    s.list:SetJustifyH("LEFT")
    s.rule = UI():Rule(s, { bottom = 32 })
    s.sw = UI():CreateSwitch(s, function() return s.pub end, function(on)
        if s.rl then Say(P():SetRelease(s.rl, { pub = on })) end
    end)
    s.sw:SetPoint("BOTTOMLEFT", 0, 8)
    s.swLabel = UI():Text(s, "small", "TEXT")
    s.swLabel:SetPoint("LEFT", s.sw, "RIGHT", 8, 0)
    s.swLabel:SetText("Guild sees it")
    s.note = UI():Text(s, "small", "DIM")
    s.note:SetPoint("BOTTOMLEFT", 0, 12)
    return s
end

local function RenderRoad(frame, w, h)
    local Plan = P()
    local road = frame.road
    if not road then
        road = CreateFrame("Frame", nil, frame)
        road:SetAllPoints()
        road.card = UI():CreateCard(road, { tone = "inset", pad = 0 })
        road.card:SetAllPoints()
        road.line = road.card:CreateTexture(nil, "ARTWORK")
        road.line:SetHeight(2)
        road.lineDone = road.card:CreateTexture(nil, "ARTWORK", nil, 1)
        road.lineDone:SetHeight(2)
        road.stops = {}
        frame.road = road
    end
    road:Show()
    local list = {}
    local all = Plan:Releases(true)
    local last
    for _, r in ipairs(all) do if r.done then last = r end end
    if last then list[1] = { rl = last.v, rel = last } end
    for _, r in ipairs(Plan:Releases()) do if #list < 4 then list[#list + 1] = { rl = r.v, rel = r } end end
    list[#list + 1] = { rl = LATER }
    local n = #list
    local pad = 12
    local sw = floor((w - 2 * pad - (n - 1) * 12) / n)
    road.line:ClearAllPoints()
    road.line:SetPoint("TOPLEFT", pad + 4, -16)
    road.line:SetPoint("TOPRIGHT", -pad, -16)
    road.line:SetColorTexture(S:Color("EDGE_QUIET"))
    road.lineDone:SetShown(last ~= nil)
    if last then
        road.lineDone:ClearAllPoints()
        road.lineDone:SetPoint("TOPLEFT", pad + 4, -16)
        road.lineDone:SetWidth(sw + 6)
        road.lineDone:SetColorTexture(S:Color("GOLD"))
    end
    local edit = Plan:CanEdit()
    for i, it in ipairs(list) do
        local s = road.stops[i]
        if not s then
            s = NewStop(road)
            s:SetFrameLevel(road.card:GetFrameLevel() + 2)
            road.stops[i] = s
        end
        s:ClearAllPoints()
        s:SetPoint("TOPLEFT", road, "TOPLEFT", pad + (i - 1) * (sw + 12), -4)
        s:SetSize(sw, h - 8)
        local rel = it.rel
        s.rl = it.rl
        s.pub = rel and rel.pub or false
        local done = rel and rel.done
        s.pin:SetColorTexture(S:Color(rel and "GOLD" or "DIM"))
        s.pinIn:SetColorTexture(S:Color(done and "GOLD" or "INSET"))
        s.v:SetText(RelName(it.rl))
        s.v:SetTextColor(S:Color(rel and "GOLD" or "TEXT"))
        local when
        if done then when = "Released " .. Day(done)
        elseif rel then
            local hrs = Plan:Load(it.rl)
            when = (rel.dt and Day(rel.dt) or "No date") .. (rel.bg and ("  ·  " .. hrs .. " of " .. rel.bg .. " h") or "")
        else when = "No date" end
        s.when:SetText(when)
        s.th:SetWidth(sw)
        s.th:SetText(rel and (rel.th or "") or "Good ideas, waiting")
        local lines = {}
        for _, c in ipairs(Plan:Cards(it.rl)) do
            if #lines >= 9 then lines[#lines + 1] = S:Wrap("DIM", "and more"); break end
            local t = Short({ text = c.text }, 34)
            if c.dev then t = S:Wrap("DIM", t .. " · only staff") end
            lines[#lines + 1] = (c.done and "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:11:11|t " or "· ") .. t
        end
        s.list:ClearAllPoints()
        s.list:SetPoint("TOPLEFT", s.th, "BOTTOMLEFT", 0, -8)
        s.list:SetWidth(sw)
        s.list:SetText(#lines > 0 and tconcat(lines, "\n") or S:Wrap("DIM", "Nothing yet"))
        local open = rel and not done
        s.sw:SetShown(open and true or false)
        s.swLabel:SetShown(open and true or false)
        if open then
            s.sw:SetChecked(s.pub)
            if s.sw.SetEnabled then s.sw:SetEnabled(edit) end
            s.swLabel:SetTextColor(S:Color(edit and "TEXT" or "SUB"))
        end
        s.note:SetShown(not open)
        s.note:SetText(done and "In the Changelog" or "Never shown to the guild")
        s:Show()
    end
    for i = n + 1, #road.stops do road.stops[i]:Hide() end
end

---------------------------------------------------------------------------
-- A release's menu, its settings, the release check
---------------------------------------------------------------------------

function PlanUI:ReleaseMenu(owner, v)
    local Plan = P()
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(v)
        root:CreateButton("Release check", function() PlanUI:OpenCheck(v) end)
        if Plan:CanEdit() then
            root:CreateButton("Settings...", function() PlanUI:OpenRelease(v) end)
            local r = Plan:Release(v)
            root:CreateCheckbox("Guild sees it", function() return r and r.pub == 1 end, function()
                Say(Plan:SetRelease(v, { pub = not (r and r.pub == 1) }))
            end)
            root:CreateDivider()
            root:CreateButton(S:Wrap("BAD", "Delete"), function()
                ns.Popup:Confirm({ title = "Delete " .. v, text = "Its items go back to To sort.", ok = "Delete",
                    danger = true, onAccept = function()
                        for _, c in ipairs(Plan:Cards(v)) do Plan:Place(c.key, nil, true) end
                        Say(Plan:DeleteRelease(v))
                    end })
            end)
        end
    end)
end

-- The settings sheet (also "+ Release" from the toolbar's ··· menu: v nil).
function PlanUI:OpenRelease(v)
    local Plan = P()
    if not Plan:CanEdit() then return end
    local sh = self.relSheet
    if not sh then
        sh = UI():CreateSheet(UIParent, { title = "Release", width = 360, height = 300, ok = { text = "Save",
            onClick = function(s) PlanUI:SaveRelease(s) end }, cancel = "Cancel" })
        local b = sh.body
        local function label(text, y)
            local l = UI():Text(b, "caps", "SUB")
            l:SetPoint("TOPLEFT", 0, y)
            l:SetText(text)
            return l
        end
        label("Version", 0)
        sh.ver = UI():CreateSleekEditBox(b, 90, 24)
        sh.ver:SetPoint("TOPLEFT", 0, -14)
        sh.fields[#sh.fields + 1] = sh.ver
        label("Theme", -46)
        sh.th = UI():CreateSleekEditBox(b, 330, 24)
        sh.th:SetPoint("TOPLEFT", 0, -60)
        sh.th:SetMaxLetters(40)
        sh.fields[#sh.fields + 1] = sh.th
        label("Target", -92)
        sh.when = UI():CreateStepper(b, 150, function(d)
            local base = sh.dt or (ns.Util.Now() - 86400)
            sh.dt = base + d * 86400
            if sh.dt < ns.Util.Now() - 86400 then sh.dt = nil end
            PlanUI:ShowReleaseDate(sh)
        end)
        sh.when:SetPoint("TOPLEFT", 0, -106)
        label("Budget (hours)", -138)
        sh.bg = UI():CreateSleekEditBox(b, 60, 24)
        sh.bg:SetPoint("TOPLEFT", 0, -152)
        sh.bg:SetNumeric(true)
        sh.fields[#sh.fields + 1] = sh.bg
        sh.pub = UI():CreateCheckbox(b, "The guild sees it (Coming next)", function() return sh.pubOn end,
            function(on) sh.pubOn = on end)
        sh.pub:SetPoint("TOPLEFT", 0, -190)
        self.relSheet = sh
    end
    local r = v and Plan:Release(v)
    sh.editing = v
    sh:SetTitle(v and ("Release " .. v) or "New release")
    local nxt = Plan:Releases()
    local suggest = #nxt > 0 and Plan.Bump(nxt[#nxt].v) or Plan.Bump(ns.version)
    sh.ver:SetText(v or suggest)
    sh.ver:SetEnabled(v == nil)
    sh.th:SetText(r and r.th or "")
    sh.bg:SetText(r and r.bg and tostring(r.bg) or "8")
    sh.dt = r and r.dt or nil
    sh.pubOn = r and r.pub == 1 or false
    if sh.pub.SetChecked then sh.pub:SetChecked(sh.pubOn) end
    self:ShowReleaseDate(sh)
    sh:Open()
end

function PlanUI:ShowReleaseDate(sh)
    sh.when:Set(sh.dt and Day(sh.dt) or "No date", true, true)
end

function PlanUI:SaveRelease(sh)
    local v = sh.editing or ns.Util.Trim(sh.ver:GetText() or "")
    local ok, err = P():SetRelease(v, { th = sh.th:GetText() or "", bg = tonumber(sh.bg:GetText() or ""), dt = sh.dt or false,
        pub = sh.pubOn })
    if not ok then sh:Error(err) return end
    sh:Close()
end

-- Release check: what the release holds, shipped or not, a changelog draft, then Mark released.
function PlanUI:OpenCheck(v)
    local Plan = P()
    local sh = self.checkSheet
    if not sh then
        sh = UI():CreateSheet(UIParent, { title = "Release check", width = 540, height = 470,
            ok = { text = "Mark released", onClick = function(s) PlanUI:Release(s) end }, cancel = "Later" })
        local b = sh.body
        sh.head = UI():Text(b, "emph", "TEXT")
        sh.head:SetPoint("TOPLEFT", 0, 0)
        sh.sub = UI():Text(b, "small", "SUB")
        sh.sub:SetPoint("TOPLEFT", 0, -20)
        -- the items: their words on the left, how far they got in a column on the right (one line each)
        sh.rows = UI():Text(b, "body", "TEXT")
        sh.rows:SetPoint("TOPLEFT", 0, -46)
        sh.rows:SetJustifyH("LEFT")
        sh.rows:SetSpacing(6)
        sh.marks = UI():Text(b, "body", "TEXT")
        sh.marks:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, -46)
        sh.marks:SetJustifyH("RIGHT")
        sh.marks:SetSpacing(6)
        sh.draftHead = UI():CreateSectionHeader(b, "Changelog draft", { style = "caps" })
        sh.draft = UI():CreateTextArea(b, 96, { selectOnFocus = true })
        sh.move = UI():CreateCheckbox(b, "", function() return sh.moveOn end, function(on) sh.moveOn = on end)
        self.checkSheet = sh
    end
    local r = Plan:Release(v)
    if not r then return end
    local chk = Plan:Check(v)
    sh.v = v
    sh.head:SetText(S:Wrap("GOLD", v) .. "  " .. (r.th or ""))
    sh.sub:SetText(("%d of %d done  ·  %d h planned%s%s"):format(chk.done, chk.total, chk.hours,
        r.bg and (" of " .. r.bg) or "", r.dt and ("  ·  target " .. Day(r.dt)) or ""))
    local lines, marks = {}, {}
    for i, row in ipairs(chk.rows) do
        if i > 10 then lines[#lines + 1] = S:Wrap("DIM", ("and %d more"):format(#chk.rows - 10)); break end
        local mark = row.shipped and S:Wrap("OK", "In the changelog") or S:Wrap("SUB", "Not in the changelog yet")
        if row.card.dev then mark = row.shipped and S:Wrap("OK", "Done") or S:Wrap("WARN", "Not done") end
        lines[#lines + 1] = S:Wrap(row.shipped and "TEXT" or "SUB", Short(row.card, 42))
        marks[#marks + 1] = mark
    end
    sh.rows:SetText(#lines > 0 and tconcat(lines, "\n") or S:Wrap("DIM", "Nothing in this release yet."))
    sh.marks:SetText(tconcat(marks, "\n"))
    local rowsH = max(16, tonumber(sh.rows:GetStringHeight()) or 16)
    sh:SetHeight(UI().SHEET.HEAD_H + UI().SHEET.FOOT_H + 2 * UI().SHEET.PAD + 46 + rowsH + 14 + 24 + 6 + 96 + 40)
    sh.draftHead:ClearAllPoints()
    sh.draftHead:SetPoint("TOPLEFT", sh.body, "TOPLEFT", 0, -46 - rowsH - 14)
    sh.draftHead:SetPoint("RIGHT", sh.body, "RIGHT", 0, 0)
    sh.draft:ClearAllPoints()
    sh.draft:SetPoint("TOPLEFT", sh.draftHead, "BOTTOMLEFT", 0, -6)
    sh.draft:SetPoint("RIGHT", sh.body, "RIGHT", 0, 0)
    sh.draft.eb:SetText(#chk.draft > 0 and tconcat(chk.draft, "\n") or "-- every item is in the changelog")
    local left = chk.total - chk.done
    local nxt = Plan:NextRelease(v)
    sh.moveTo = nxt and nxt.v or LATER
    sh.moveOn = left > 0
    sh.move:SetShown(left > 0 and Plan:CanEdit())
    if sh.move.SetLabel then
        sh.move:SetLabel(("Move the %d unfinished to %s"):format(left, RelName(sh.moveTo)))
    elseif sh.move.label then
        sh.move.label:SetText(("Move the %d unfinished to %s"):format(left, RelName(sh.moveTo)))
    end
    if sh.move.SetChecked then sh.move:SetChecked(sh.moveOn) end
    sh.move:ClearAllPoints()
    sh.move:SetPoint("TOPLEFT", sh.draft, "BOTTOMLEFT", 0, -10)
    if sh.ok then sh.ok:SetShown(Plan:CanEdit()) end
    sh:Open()
end

function PlanUI:Release(sh)
    local ok, err = P():MarkReleased(sh.v, sh.moveOn and sh.moveTo or nil)
    if not ok then sh:Error(err) return end
    sh:Close()
end

---------------------------------------------------------------------------
-- My own item
---------------------------------------------------------------------------

function PlanUI:OpenOwnItem()
    local Plan = P()
    if not Plan:CanEdit() then return end
    local sh = self.ownSheet
    if not sh then
        sh = UI():CreateSheet(UIParent, { title = "My own item", width = 380, height = 300, ok = { text = "Add",
            onClick = function(s)
                local key, err = P():AddDevItem(s.title:GetText(), s.kind, s.size, s.rel)
                if not key then s:Error(err) return end
                s:Close()
            end }, cancel = "Cancel", foot = "Only staff see it." })
        local b = sh.body
        sh.title = UI():CreateSleekEditBox(b, 350, 24)
        sh.title:SetPoint("TOPLEFT", 0, 0)
        sh.title:SetMaxLetters(80)
        UI():SetEditPlaceholder(sh.title, "What is it?")
        sh.fields[#sh.fields + 1] = sh.title
        local function label(text, y)
            local l = UI():Text(b, "caps", "SUB")
            l:SetPoint("TOPLEFT", 0, y)
            l:SetText(text)
        end
        label("What is it", -36)
        sh.kindSeg = UI():CreateSegments(b, { { key = "idea", label = "Idea" }, { key = "change", label = "Change" },
            { key = "bug", label = "Bug" }, { key = "chore", label = "Chore" } }, function(k) sh.kind = k end,
            { h = 24, itemW = 70 })
        sh.kindSeg:SetPoint("TOPLEFT", 0, -50)
        label("How big", -86)
        sh.sizeSeg = UI():CreateSegments(b, SizeItems(), function(k) sh.size = k end, { h = 24, itemW = 60 })
        sh.sizeSeg:SetPoint("TOPLEFT", 0, -100)
        label("Which release", -136)
        sh.relSeg = UI():CreateSegments(b, ReleaseItems(), function(k) sh.rel = k end, { h = 24 })
        sh.relSeg:SetPoint("TOPLEFT", 0, -150)
        self.ownSheet = sh
    end
    sh.title:SetText("")
    sh.kind, sh.size = "idea", "M"
    local nxt = Plan:NextRelease()
    sh.rel = nxt and nxt.v or LATER
    sh.kindSeg:Select(sh.kind)
    sh.sizeSeg:Select(sh.size)
    sh.relSeg:SetItems(ReleaseItems())
    sh.relSeg:Select(sh.rel)
    sh:Open()
end

---------------------------------------------------------------------------
-- Plan it (the Inbox): a popover over the button
---------------------------------------------------------------------------

function PlanUI:OpenPlanIt(owner, item)
    local Plan = P()
    local pop = self.planIt
    if not pop then
        pop = UI():CreatePopover(300, 236)
        pop.title = UI():Text(pop, "title", "GOLD")
        pop.title:SetPoint("TOPLEFT", 12, -10)
        pop.title:SetText("Plan it")
        pop.num = UI():Text(pop, "small", "SUB")
        pop.num:SetPoint("LEFT", pop.title, "RIGHT", 8, 0)
        local function label(text, y)
            local l = UI():Text(pop, "caps", "SUB")
            l:SetPoint("TOPLEFT", 12, y)
            l:SetText(text)
        end
        label("How big", -34)
        pop.size = UI():CreateSegments(pop, SizeItems(), function(k) pop.sz = k end, { h = 26, width = 276 })
        pop.size:SetPoint("TOPLEFT", 12, -48)
        label("Which release", -84)
        pop.rel = UI():CreateSegments(pop, ReleaseItems(), function(k) pop.rl = k end, { h = 24 })
        pop.rel:SetPoint("TOPLEFT", 12, -98)
        label("Group and note (only staff see them)", -132)
        pop.group = UI():CreateSleekDropdown(pop, 120, function()
            local opts = { { value = "", text = "No group" } }
            for _, g in ipairs(P():Groups()) do opts[#opts + 1] = { value = g, text = g } end
            return opts
        end, function() return pop.g or "" end, function(v) pop.g = v ~= "" and v or nil end)
        pop.group:SetPoint("TOPLEFT", 12, -146)
        pop.note = UI():CreateSleekEditBox(pop, 150, 24)
        pop.note:SetPoint("TOPLEFT", 138, -146)
        pop.note:SetMaxLetters(120)
        UI():SetEditPlaceholder(pop.note, "A note")
        pop.tell = UI():Text(pop, "small", "SUB", WRAP)
        pop.tell:SetPoint("TOPLEFT", 12, -180)
        pop.tell:SetWidth(276)
        pop.ok = UI():CreateSleekButton(pop, "Plan it", 72, S.BTN_H, function() PlanUI:SavePlanIt() end, "primary")
        pop.ok:SetPoint("BOTTOMRIGHT", -12, 10)
        pop.cancel = UI():CreateSleekButton(pop, "Cancel", 64, S.BTN_H, function() pop:Hide() end)
        pop.cancel:SetPoint("RIGHT", pop.ok, "LEFT", -6, 0)
        self.planIt = pop
    end
    local e = Plan:Entry(item.id)
    pop.item = item
    pop.num:SetText(item.no and ("#" .. item.no) or "")
    pop.sz = e and e.sz or "M"
    local nxt = Plan:NextRelease()
    pop.rl = e and e.rl or (nxt and nxt.v) or LATER
    pop.g = e and e.g or nil
    pop.size:Select(pop.sz)
    pop.rel:SetItems(ReleaseItems())
    pop.rel:Select(pop.rl)
    pop.note:SetText(e and e.nt or "")
    local function tell()
        local r = pop.rl ~= LATER and Plan:Release(pop.rl)
        pop.tell:SetText(ns.Util.ShortName(item.author) .. " sees " .. S:Wrap("GOLD", r and r.pub and ("Planned for " .. pop.rl)
            or "Planned") .. (r and not r.pub and S:Wrap("DIM", " (" .. pop.rl .. " is staff only)") or ""))
    end
    pop.rel.onChange = function(k) pop.rl = k; tell() end
    tell()
    pop.owner = owner
    pop:ClearAllPoints()
    pop:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, 6)
    pop:Show()
    pop:Raise()
end

function PlanUI:SavePlanIt()
    local pop = self.planIt
    if not (pop and pop.item) then return end
    local id = pop.item.id
    local Plan = P()
    Say(Plan:SetSize(id, pop.sz))
    Say(Plan:SetGroup(id, pop.g))
    Say(Plan:SetNote(id, pop.note:GetText() or ""))
    Say(Plan:Place(id, pop.rl, true))
    pop:Hide()
end

---------------------------------------------------------------------------
-- The Plan tab
---------------------------------------------------------------------------

local VIEWS = { { key = "board", label = "Board" }, { key = "sort", label = "Sort" }, { key = "road", label = "Roadmap" } }

-- The toolbar's controls for the Plan tab (the Feedback page swaps them in): the views, My own item.
function PlanUI:Filters(bar)
    if self.filters then return self.filters end
    local items = {}
    for _, v in ipairs(VIEWS) do items[#items + 1] = { key = v.key, label = v.label } end
    self.viewSeg = UI():CreateSegments(bar, items, function(key) PlanUI:SetView(key) end, { h = 22, selected = state.view })
    self.ownBtn = UI():CreateSleekButton(bar, "My own item", 96, 22, function() PlanUI:OpenOwnItem() end)
    self.relBtn = UI():CreateSleekButton(bar, "New release", 96, 22, function() PlanUI:OpenRelease(nil) end)
    self.filters = { self.viewSeg, self.relBtn, self.ownBtn }
    return self.filters
end

function PlanUI:SetView(key)
    state.view = key
    if self.viewSeg then self.viewSeg:Select(key) end
    Refresh()
end

function PlanUI:GetState() return state end

-- The Plan tab's frame inside `region` (the Feedback page's content area).
function PlanUI:Create(region)
    if host then return host end
    local f = CreateFrame("Frame", nil, region:GetParent())
    f:SetAllPoints(region)
    f:Hide()
    f.board = CreateFrame("Frame", nil, f)
    f.board:SetAllPoints()
    f.sort = BuildSort(f)
    f.roadHost = CreateFrame("Frame", nil, f)
    f.roadHost:SetAllPoints()
    f:SetScript("OnSizeChanged", function() Refresh() end)
    -- (the sheets and the popover close with the Feedback page)
    region:GetParent():HookScript("OnHide", function() PlanUI:CloseAll() end)
    host = f
    return f
end

function PlanUI:CloseAll()
    for _, sh in ipairs({ self.checkSheet, self.relSheet, self.ownSheet }) do
        if sh and sh:IsShown() then sh:Close() end
    end
    if self.planIt then self.planIt:Hide() end
    if drag.card then EndDrag(true) end
end

function PlanUI:GetFrame() return host end

function PlanUI:Refresh()
    if not host then return end
    local w, h = host:GetWidth(), host:GetHeight()
    if not w or w < 100 then w = S.INNER_W end
    if not h or h < 100 then h = S.PAGE_H - 114 - 36 - S.PAD end
    local view = state.view
    local edit = P():CanEdit()
    if self.ownBtn then
        self.ownBtn:SetShown(edit)
        self.relBtn:SetShown(edit)
        local n = #P():Cards(nil)
        if self.viewSeg.SetLabel then self.viewSeg:SetLabel("sort", n > 0 and ("Sort " .. S:Wrap("GOLD", n)) or "Sort") end
        self.viewSeg:Select(view)
    end
    host.board:SetShown(view == "board")
    host.sort:SetShown(view == "sort")
    host.roadHost:SetShown(view == "road")
    if view == "board" then RenderBoard(host.board, w, h)
    elseif view == "sort" then self:RenderSort(w, h)
    else RenderRoad(host.roadHost, w, h) end
end

function PlanUI:OnInit()
    local function soon()
        if host and host:IsVisible() then
            ns.Util.Debounce("feedback-plan-ui", 0.1, function() PlanUI:Refresh() end)
        end
    end
    ns:On("FEEDBACK_PLAN_UPDATED", soon)
    ns:On("FEEDBACK_UPDATED", soon)
end

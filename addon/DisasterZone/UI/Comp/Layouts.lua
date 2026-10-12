if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Comp/Layouts.lua", ...) then return end -- DisasterZone UI/Comp/Layouts.lua
-- page layouts: Board, List + detail, Detail page, Side menu, Tool window (refactor phase 3).
local addonName, ns = ...

-- UI:CreateLayout(kind, parent, opts) -> layout: the five page structures every page and window of 1.4 is built on
-- (REFACTOR_API.md "Layouts.lua", REFACTOR_PLAN.md phase 3). The layout owns the toolbar row (tabs on the left, the
-- filters, then a "···" more menu and the ONE primary action at the far right, S.BTN_H high), the margins, and the
-- empty / notice slots; the page fills the regions it hands out:
--   "board"       toolbar -> [hero banner for the top item] -> body (grouped sections) [+ side card on the right]
--                 (Upcoming, Events, Polls, Dungeons, Strategies, Teams board)
--   "listdetail"  toolbar -> [nav column] + list column + detail (banner, [tabs on its foot], body)
--                 (Guests, Raid log, Prized, Members, Feedback, Loot rules, Sim recent runs; Atlas with a nav column)
--   "detail"      hero banner (back link in it) -> tabs strip on its foot -> tool row (a toolbar) -> body
--                 (the raid page, event page, team page, poll page, loot-rule item)
--   "rail"        side menu (UI:CreateRailNav) | a hairline | body (titled sections of rows; optionally scrolling)
--                 (Settings, Notifications)
--   "tool"        a tool window's content: tool banner (84) -> [tool row] -> body
--                 (Blessings / Totems planners, Swing practice, drop panel, meter detail)
-- The geometry is today's (1.3.5) so a page moved onto a layout keeps its positions: the Raids tab's view row (tabs
-- at y -6, views from 36), the Guest book's list + profile, the raid page's hero (128) with its tabs (34) and tool row,
-- the Settings rail, the Swing practice window's banner. UI.LAYOUT holds the numbers.
--
-- opts (all optional):
--   width      the page width the regions are sized for while the frame has none (GetWidth is 0 before a layout):
--              S.PAGE_W for a page; a tool window passes its content width (540 by default)
--   pad        the side margins (S.PAD); 0 when the layout sits inside a region that has its margins already
--   top        where the layout starts (0)
--   bottom     the bottom margin (4 on board / listdetail / detail, as under the Raids tab's views; S.PAD otherwise)
--   toolbar    false = no toolbar row (board / listdetail / detail have one by default; rail / tool only when true)
--   noAnchor   the caller anchors the layout frame (default: all points of the parent)
--   board:      hero = true | banner opts (UI:CreatePageBanner, size "hero"); side = true | a width; sideTone
--   listdetail: listWidth (UI.LAYOUT.LIST_W), navWidth (adds a nav column on the left: Atlas), banner = false |
--               banner opts (D3: a detail has one; size "hero" unless given), tabs = list (a tabs strip on its foot),
--               onTab, tabStyle ("block" | "underline")
--   detail:     banner opts (size "hero"), back = { text, onClick } (the banner's back link), tabs, onTab, tabStyle
--   rail:       items, onSelect, selected, railWidth (150), rowH (28), scroll = true (the body scrolls: layout.scroll,
--               layout.body = its child)
--   tool:       banner opts (size "tool")
--
-- layout.toolbar (when it has one):
--   :SetTabs(tabs, onSelect)   tabs = { "key" | { key, text, count, kind, small, sep, group, tip } ..., selected =
--                              key }; small tabs after a separator are a second group (the Raid log's Raids /
--                              Attendance / Reviews): picking one leaves the other group's pick. onSelect(key, item, b)
--   :SelectTab(key [, fire]) / :GetSelectedTab([group]) / :GetTab(key) / :SetTabCount(key, n [, kind]) /
--   :SetTabShown(key, shown) / :SetTabLabel(key, text)
--   :SetPrimary{ text, onClick, width, kind ("primary"), icon (UI.ICON index), tip, enabled } (nil hides it)
--   :SetFilters(frames)        the page's filter controls (built by the page), left to right, before the more menu
--   :SetMore(menuFn [, tip])   the "···" menu (menuFn(root), UI:ContextMenu); nil hides it
--   :SetText(text)             a quiet line at the left, after the tabs (a detail's tool row: "6 accepted")
--   .primary, .more, .label, .tabButtons
-- layout.tabs (detail; listdetail with opts.tabs): a strip with the same tab methods; a block tab's count may be
--   a number or { have, of } (a bar along its foot).
-- layout regions: .content, .body, .side, .list, .nav, .detail, .banner (.hero), .tabs, .rail, .rule, .scroll;
--   widths .innerW, .bodyW, .sideW, .listW, .navW, .detailW, .railW
-- layout:ShowEmpty(opts) / :HideEmpty() / :IsEmptyShown(): UI:CreateEmptyState's opts + region = "content" |
--   "body" | "list" | "detail" | "side" | "nav" (default: "content" on board / listdetail, which hides the whole
--   content, "body" otherwise, which hides the body), y (60), width (430)
-- layout:ShowNotice(kind, text) / :HideNotice(): UI:CreateNotice above the content (board / listdetail) or the body
--   (detail / rail / tool); what is under it moves down. layout:Layout() re-places the regions.

local UI = ns.UI
local S = ns.Style

local CreateFrame = CreateFrame
local floor, max, min = math.floor, math.max, math.min
local type, ipairs, pairs, tostring, tonumber = type, ipairs, pairs, tostring, tonumber

-- The numbers (today's pages'; see the header).
local G = {
    TOP = 36,                 -- a toolbar page: the views start under the view row (UI/RaidsTab.lua)
    TAB_X = 6, TAB_Y = 6,     -- the first tab
    TAB_GAP = 4,              -- between page tabs
    SMALL_GAP = 2,            -- between small tabs
    SEP_GAP = 8,              -- a separator after a page tab, and again before the next (small) tab
    ROW_MID = 17,             -- the toolbar row's middle (the tabs' 22 px from y -6)
    CTRL_GAP = 6,             -- between the controls on the right
    BOTTOM = 4,               -- under a toolbar page's views
    LIST_W = 300,             -- a list + detail page's list (Guests 250, Raid log 236, Prized 300, Members 356,
                              -- Feedback 336: the middle one; pages pass listWidth to keep theirs)
    NAV_W = 180,              -- the third column of a 3-column list + detail (Atlas)
    SIDE_W = 250,             -- a board's side card (Events' season card)
    HERO_H = S.BANNER.hero,   -- 128: the detail's banner (raid page, guest profile)
    TABS_H = 34,              -- the tabs on a detail banner's foot (the raid page's)
    TAB_MIN = 170,            -- a block tab's least width
    ROW_H = 26,               -- a detail's / tool window's tool row (the raid page's)
    ROW_GAP = 10,             -- above that row
    RAIL_W = 150, RAIL_ROW = 28, RAIL_TOP = 8, RAIL_GAP = 18,   -- Settings: its nav, the gap to the body
    TOOL_W = 540,             -- a tool window's content width when none is given
    EMPTY_Y = 60,             -- an empty state below its region's top
    EMPTY_W = 430,
}
UI.LAYOUT = G

-- (a block tab's surfaces: the raid page's)
local BLOCK_BG = { 0.125, 0.125, 0.145, 1 }
local STRIP_BG = { 0.085, 0.085, 0.1, 1 }

local H = {}           -- helpers (one local: keeps the main chunk's locals few)
local Tabs = {}        -- the tab methods (a toolbar, a detail's tabs strip)
local Toolbar = {}     -- the toolbar's own
local Layout = {}      -- every layout's
local Place = {}       -- kind -> function(layout, shift): (re)anchors the regions
local Build = {}       -- kind -> function(layout, opts): creates the regions

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------

-- A block tab (the raid page's tabs on its banner's foot): the name on the left, a count on the right, a bar along
-- the bottom showing have / of; the open one lit, with a gold top edge.
local Block = {}

function Block:SetLabel(t)
    self.label = t
    self.name:SetText(t or "")
    self:Paint()
end

function Block:GetText() return self.label end

function Block:SetActive(on)
    self.active = on and true or false
    self:Paint()
end

-- SetCount(have [, of]): "have/of" with a bar along the foot, or a bare number; nil clears it.
function Block:SetCount(have, of)
    self.have, self.of = have, of
    self:Paint()
end

function Block:Paint()
    local on = self.active
    self.bg:SetShown(on)
    self.top:SetShown(on)
    self.name:SetTextColor(S:Color(on and "TEXT" or "SUB"))
    local have, of = self.have, self.of
    local full = of and of > 0 and have and have >= of
    if have and of then
        self.count:SetText(S:Wrap(full and "OK" or (on and "TEXT" or "SUB"), have) .. S:Wrap("DIM", "/" .. tostring(of)))
    elseif have then
        self.count:SetText(S:Wrap(on and "TEXT" or "SUB", have))
    else
        self.count:SetText("")
    end
    local w = max(G.TAB_MIN, floor(14 + UI:TextWidth(self.name) + 24 + UI:TextWidth(self.count) + 16 + 0.5))
    self:SetWidth(w)
    local share = (have and of and of > 0) and min(1, have / of) or 0
    self.fill:SetShown(share > 0)
    self.fill:SetWidth(max(1, floor(w * share + 0.5)))
    local c = full and S.C.OK or S.C.GOLD
    self.fill:SetColorTexture(c[1], c[2], c[3], on and 1 or (full and 0.5 or 0.35))
end

function H.BlockTab(host)
    local c = CreateFrame("Button", nil, host)
    c:SetHeight(G.TABS_H)
    c.bg = UI:Fill(c, BLOCK_BG, "BACKGROUND", 1)
    c.top = c:CreateTexture(nil, "ARTWORK", nil, 3)
    c.top:SetPoint("TOPLEFT", 0, 0)
    c.top:SetPoint("TOPRIGHT", 0, 0)
    c.top:SetHeight(2)
    c.top:SetColorTexture(S:Color("GOLD"))
    c.sep = UI:Rule(c, { vertical = true, right = 0, alpha = 0.06, layer = "BORDER" })
    c.hl = c:CreateTexture(nil, "HIGHLIGHT")
    c.hl:SetAllPoints()
    c.hl:SetColorTexture(S:Color("HOVER"))
    c.name = UI:Text(c, "title", "TEXT")
    c.name:SetPoint("LEFT", 14, 0)
    c.count = UI:Text(c, "emph", "TEXT", { justify = "RIGHT" })
    c.count:SetPoint("RIGHT", -16, 0)
    c.fill = c:CreateTexture(nil, "ARTWORK", nil, 2)
    c.fill:SetPoint("BOTTOMLEFT", 0, 0)
    c.fill:SetHeight(2)
    for k, fn in pairs(Block) do c[k] = fn end
    c:Paint()
    return c
end

function H.TabTipEnter(b)
    if b.tip and GameTooltip then
        GameTooltip:SetOwner(b, b.tabKind == "block" and "ANCHOR_BOTTOM" or "ANCHOR_TOP")
        GameTooltip:AddLine(b.label or "")
        GameTooltip:AddLine(b.tip, 1, 1, 1, true)
        GameTooltip:Show()
    end
end

function H.TabTipLeave(b)
    if b.tip and GameTooltip then GameTooltip:Hide() end
end

-- A button for tab item `it` from the host's pools (block / page / small).
function H.AcquireTab(host, it)
    local kind = host.tabStyle == "block" and "block" or (it.small and "small" or "page")
    local pool = host.tabPools[kind]
    if not pool then
        pool = { used = 0 }
        host.tabPools[kind] = pool
    end
    pool.used = pool.used + 1
    local b = pool[pool.used]
    if not b then
        if kind == "block" then
            b = H.BlockTab(host)
            b:SetScript("OnClick", function(self) host:SelectTab(self.key, true) end)
        else
            b = UI:CreateUnderlineTab(host, "", function(self) host:SelectTab(self.key, true) end,
                kind == "small" and "small" or nil)
        end
        b:HookScript("OnEnter", H.TabTipEnter)
        b:HookScript("OnLeave", H.TabTipLeave)
        pool[pool.used] = b
    end
    b.tabKind = kind
    return b
end

function H.TabCount(b, n, kind)
    if b.tabKind == "block" then
        if type(n) == "table" then b:SetCount(n[1] or n.have, n[2] or n.of) else b:SetCount(n) end
    elseif n ~= nil and UI.SetTabCount then
        UI:SetTabCount(b, tonumber(n) or 0, kind)
    elseif b.cnt then
        UI:SetTabCount(b, 0)
    end
end

function H.Separator(host, i)
    local s = host.tabSeps[i]
    if not s then
        s = host:CreateTexture(nil, "ARTWORK")
        s:SetColorTexture(1, 1, 1, 0.15)
        s:SetSize(1, 14)
        host.tabSeps[i] = s
    end
    return s
end

-- The tab methods go on a host frame: a toolbar (underline tabs) or a detail's strip (block tabs).
function H.InitTabs(host, style)
    host.tabStyle = style or "underline"
    host.tabPools, host.tabSeps, host.tabButtons, host.tabByKey, host.tabSelected = {}, {}, {}, {}, {}
    for k, fn in pairs(Tabs) do host[k] = fn end
end

function Tabs:SetTabs(list, onSelect)
    for _, pool in pairs(self.tabPools) do
        for i = 1, #pool do pool[i]:Hide() end
        pool.used = 0
    end
    for _, s in ipairs(self.tabSeps) do s:Hide() end
    if onSelect then self.onTabSelect = onSelect end
    self.tabButtons, self.tabByKey = {}, {}
    local firstOf = {}
    for i, it in ipairs(list or {}) do
        if type(it) ~= "table" then it = { key = it, text = tostring(it) } end
        local key = it.key or it.text or i
        local b = H.AcquireTab(self, it)
        b.key, b.item, b.tip, b.hidden = key, it, it.tip, nil
        b.group = it.group or (it.small and "sub" or "main")
        b.label = it.text or tostring(key)
        b:SetLabel(b.label)
        H.TabCount(b, it.count, it.kind)
        b:Show()
        self.tabButtons[#self.tabButtons + 1] = b
        self.tabByKey[key] = b
        firstOf[b.group] = firstOf[b.group] or key
    end
    -- keep what was open where it still exists (no click fired); else the list's selected one, else the first
    local sel = {}
    for group, key in pairs(self.tabSelected) do
        local b = self.tabByKey[key]
        if b and b.group == group then sel[group] = key end
    end
    local want = list and list.selected and self.tabByKey[list.selected]
    if want then sel[want.group] = want.key end
    for group, key in pairs(firstOf) do
        if not sel[group] then sel[group] = key end
    end
    self.tabSelected = sel
    self:PaintTabs()
    self:LayoutTabs()
    return self.tabButtons
end

function Tabs:PaintTabs()
    for _, b in ipairs(self.tabButtons) do
        b:SetActive(self.tabSelected[b.group] == b.key)
    end
end

function Tabs:SelectTab(key, fire)
    local b = self.tabByKey[key]
    if not b then return end
    self.tabSelected[b.group] = key
    self:PaintTabs()
    if fire and self.onTabSelect then self.onTabSelect(key, b.item, b) end
end

function Tabs:GetSelectedTab(group) return self.tabSelected[group or "main"] end
function Tabs:GetTab(key) return self.tabByKey[key] end

function Tabs:SetTabCount(key, n, kind)
    local b = self.tabByKey[key]
    if not b then return end
    b.item.count = n
    H.TabCount(b, n, kind)
    self:LayoutTabs()
end

function Tabs:SetTabLabel(key, text)
    local b = self.tabByKey[key]
    if not b then return end
    b.label = text
    b:SetLabel(text)
    self:LayoutTabs()
end

function Tabs:SetTabShown(key, shown)
    local b = self.tabByKey[key]
    if not b then return end
    b.hidden = not shown or nil
    b:SetShown(shown and true or false)
    self:LayoutTabs()
end

-- Underline tabs from (tabX, -tabY), page tabs TAB_GAP apart, a separator before a small tab that follows a page
-- tab (or an item with sep = true), small tabs SMALL_GAP apart and 1 px lower (the Raids tab's row); block tabs side
-- by side from the strip's left edge.
function Tabs:LayoutTabs()
    local prev, sepN = nil, 0
    local block = self.tabStyle == "block"
    for _, b in ipairs(self.tabButtons) do
        if not b.hidden then
            b:ClearAllPoints()
            local small, prevSmall = b.tabKind == "small", prev and prev.tabKind == "small"
            if block then
                if prev then
                    b:SetPoint("TOPLEFT", prev, "TOPRIGHT", 0, 0)
                else
                    b:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
                end
            elseif not prev then
                b:SetPoint("TOPLEFT", self, "TOPLEFT", self.tabX or G.TAB_X, -(self.tabY or G.TAB_Y))
            elseif b.item.sep or (small and not prevSmall) then
                sepN = sepN + 1
                local s = H.Separator(self, sepN)
                s:ClearAllPoints()
                s:SetPoint("LEFT", prev, "RIGHT", G.SEP_GAP, (small and not prevSmall) and -1 or 0)
                s:Show()
                b:SetPoint("LEFT", prev, "RIGHT", 2 * G.SEP_GAP, (small and not prevSmall) and -1
                    or ((prevSmall and not small) and 1 or 0))
            else
                b:SetPoint("LEFT", prev, "RIGHT", small and G.SMALL_GAP or G.TAB_GAP, (prevSmall and not small) and 1 or 0)
            end
            prev = b
        end
    end
    self.lastTab = prev
    -- (rawget: the hook is copied onto the frame by NewToolbar; plain tab rows have none)
    local onLaidOut = rawget(self, "OnTabsLaidOut")
    if onLaidOut then onLaidOut(self) end
end

---------------------------------------------------------------------------
-- Toolbar
---------------------------------------------------------------------------

-- o: { height (G.TOP), tabX, tabY, rightX (S.PAD), mid (the row's middle, from its top), labelX }
function H.NewToolbar(parent, o)
    local t = CreateFrame("Frame", nil, parent)
    t:SetHeight(o.height or G.TOP)
    t.tabX, t.tabY = o.tabX or G.TAB_X, o.tabY or G.TAB_Y
    t.rightX, t.mid, t.labelX = o.rightX or S.PAD, o.mid or G.ROW_MID, o.labelX or o.tabX or S.PAD
    H.InitTabs(t, "underline")
    for k, fn in pairs(Toolbar) do t[k] = fn end
    t.filters = {}
    t.label = UI:Text(t, "body", "SUB")
    t.label:Hide()
    t:LayoutLeft()
    return t
end

function Toolbar:OnTabsLaidOut() self:LayoutLeft() end

-- The quiet line at the left (after the tabs, if any).
function Toolbar:SetText(text)
    self.label:SetText(text or "")
    self.label:SetShown(text ~= nil and text ~= "")
    self:LayoutLeft()
end

function Toolbar:LayoutLeft()
    local l = self.label
    l:ClearAllPoints()
    if self.lastTab then
        l:SetPoint("LEFT", self.lastTab, "RIGHT", 12, 0)
    else
        l:SetPoint("LEFT", self, "TOPLEFT", self.labelX, -self.mid)
    end
end

function Toolbar:SetPrimary(o)
    local b = self.primary
    if not o then
        if b then b:Hide() end
        self:LayoutRight()
        return nil
    end
    local text = o.text or ""
    if o.icon and UI.AtlasIconText then text = UI:AtlasIconText(o.icon, 13) .. "  " .. text end
    if not b then
        b = UI:CreateSleekButton(self, text, 90, S.BTN_H, function(btn, ...)
            if self.onPrimary then self.onPrimary(btn, ...) end
        end, o.kind or "primary")
        self.primary = b
    else
        b:SetText(text)
        if b.SetKind then b:SetKind(o.kind or "primary") end
    end
    b:SetHeight(S.BTN_H)
    b:SetWidth(o.width or max(90, floor(UI:TextWidth(o.text or "", "body") + (o.icon and 52 or 32) + 0.5)))
    self.onPrimary = o.onClick
    b:SetEnabled(o.enabled ~= false)
    if o.tip then UI:AttachTooltip(b, o.tipTitle or o.text, o.tip) else UI:AttachTooltip(b, nil, nil) end
    b:Show()
    self:LayoutRight()
    return b
end

function Toolbar:SetMore(menuFn, tip)
    self.moreFn = menuFn
    if not menuFn then
        if self.more then self.more:Hide() end
        self:LayoutRight()
        return nil
    end
    if not self.more then
        self.more = UI:CreateTipIconButton(self, S.BTN_H, UI.ICON.more, "More", tip, function(b)
            if self.moreFn then UI:ContextMenu(b, self.moreFn) end
        end)
    end
    self.more.tipText = tip
    self.more:Show()
    self:LayoutRight()
    return self.more
end

function H.FilterShown(f) if f.dzLayoutBar then f.dzLayoutBar:LayoutRight() end end

function Toolbar:SetFilters(frames)
    for _, f in ipairs(self.filters) do
        if f.dzLayoutBar == self then f.dzLayoutBar = false end
    end
    self.filters = frames or {}
    for _, f in ipairs(self.filters) do
        if f:GetParent() ~= self then f:SetParent(self) end
        if f.dzLayoutBar == nil then
            f:HookScript("OnShow", H.FilterShown)
            f:HookScript("OnHide", H.FilterShown)
        end
        f.dzLayoutBar = self
    end
    self:LayoutRight()
end

-- From the right: the primary action, the more menu, then the filters (the last one nearest), on the row's middle.
function Toolbar:LayoutRight()
    local order = {}
    if self.primary and self.primary:IsShown() then order[#order + 1] = self.primary end
    if self.more and self.more:IsShown() then order[#order + 1] = self.more end
    for i = #self.filters, 1, -1 do
        local f = self.filters[i]
        if f:IsShown() then order[#order + 1] = f end
    end
    local prev
    for _, f in ipairs(order) do
        f:ClearAllPoints()
        if prev then
            f:SetPoint("RIGHT", prev, "LEFT", -G.CTRL_GAP, 0)
        else
            f:SetPoint("RIGHT", self, "TOPRIGHT", -self.rightX, -self.mid)
        end
        prev = f
    end
end

---------------------------------------------------------------------------
-- Building blocks of the layouts
---------------------------------------------------------------------------

function H.Region(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(1, 1)
    return f
end

-- A banner from opts (true -> {}), its size defaulting to `size`, laid out at width w.
function H.Banner(parent, o, size, w, back)
    local bo = {}
    for k, v in pairs(type(o) == "table" and o or {}) do bo[k] = v end
    bo.size = bo.size or size
    bo.width = bo.width or w
    bo.back = bo.back or back
    return UI:CreatePageBanner(parent, bo)
end

-- The tabs strip under a detail's banner: block tabs (or underline ones) on the strip's slate, a hairline under it.
function H.TabStrip(parent, style)
    local s = CreateFrame("Frame", nil, parent)
    s:SetHeight(G.TABS_H)
    s.bg = UI:Fill(s, STRIP_BG, "BACKGROUND")
    s.rule = UI:Rule(s, { bottom = 0, alpha = 0.08, layer = "BORDER" })
    H.InitTabs(s, style or "block")
    if s.tabStyle ~= "block" then s.tabX, s.tabY = 6, floor((G.TABS_H - 22) / 2) end
    return s
end

function H.Height(f) return f and f:IsShown() and floor((f:GetHeight() or 0) + 0.5) or 0 end

function H.Fill(f, parent, l, t, r, b)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", l, -t)
    f:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -r, b)
end

function H.Top(f, parent, l, t, r)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", l, -t)
    f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -r, -t)
end

-- The toolbar across the top of the layout; returns its height.
function H.TopToolbar(L)
    local t = H.NewToolbar(L, { rightX = L.pad })
    H.Top(t, L, 0, L.top, 0)
    L.toolbar = t
    return G.TOP
end

-- The tool row of a detail page / a tool window (inside the margins).
function H.ToolRow(L)
    return H.NewToolbar(L, { height = G.ROW_H, tabX = 0, tabY = 2, rightX = 0, mid = G.ROW_H / 2, labelX = 0 })
end

---------------------------------------------------------------------------
-- The kinds
---------------------------------------------------------------------------

-- Board: toolbar -> [hero] -> body [+ side card].
function Build.board(L, o)
    L.y0 = L.top + ((o.toolbar ~= false) and H.TopToolbar(L) or 0)
    L.content = H.Region(L)
    if o.hero then
        L.banner = H.Banner(L.content, o.hero, "hero", L.innerW)
        L.hero = L.banner
    end
    if o.side then
        L.sideW = type(o.side) == "number" and o.side or (o.sideWidth or G.SIDE_W)
        L.side = UI:CreateCard(L.content, { tone = o.sideTone or "card" })
        L.side:SetWidth(L.sideW)
    else
        L.sideW = 0
    end
    L.body = H.Region(L.content)
    L.bodyW = L.innerW - (L.side and (L.sideW + S.GAP) or 0)
    L.emptyRegion = "content"
end

function Place.board(L, shift)
    H.Fill(L.content, L, L.pad, L.y0 + shift, L.pad, L.bottom)
    local y = 0
    if L.banner then
        H.Top(L.banner, L.content, 0, 0, 0)
        local h = H.Height(L.banner)
        y = h > 0 and (h + S.GAP) or 0
    end
    if L.side then
        L.side:ClearAllPoints()
        L.side:SetPoint("TOPRIGHT", L.content, "TOPRIGHT", 0, -y)
        L.side:SetPoint("BOTTOMRIGHT", L.content, "BOTTOMRIGHT", 0, 0)
    end
    H.Fill(L.body, L.content, 0, y, L.side and (L.sideW + S.GAP) or 0, 0)
    L.noticeX, L.noticeY = L.pad, L.y0
end

-- List + detail: toolbar -> [nav] + list + detail (banner, [tabs], body).
function Build.listdetail(L, o)
    L.y0 = L.top + ((o.toolbar ~= false) and H.TopToolbar(L) or 0)
    L.content = H.Region(L)
    L.navW = o.navWidth == true and G.NAV_W or (o.navWidth or 0)
    if L.navW > 0 then L.nav = H.Region(L.content) end
    L.listW = o.listWidth or G.LIST_W
    L.list = H.Region(L.content)
    L.detail = H.Region(L.content)
    L.detailW = L.innerW - L.listW - S.GAP - (L.nav and (L.navW + S.GAP) or 0)
    if o.banner ~= false then L.banner = H.Banner(L.detail, o.banner, "hero", L.detailW) end
    if o.tabs then
        L.tabs = H.TabStrip(L.detail, o.tabStyle)
        L.tabs:SetTabs(o.tabs, o.onTab)
    end
    L.body = H.Region(L.detail)
    L.bodyW = L.detailW
    L.emptyRegion = "content"
end

function Place.listdetail(L, shift)
    H.Fill(L.content, L, L.pad, L.y0 + shift, L.pad, L.bottom)
    local x = 0
    if L.nav then
        L.nav:ClearAllPoints()
        L.nav:SetPoint("TOPLEFT", L.content, "TOPLEFT", 0, 0)
        L.nav:SetPoint("BOTTOMLEFT", L.content, "BOTTOMLEFT", 0, 0)
        L.nav:SetWidth(L.navW)
        x = L.navW + S.GAP
    end
    L.list:ClearAllPoints()
    L.list:SetPoint("TOPLEFT", L.content, "TOPLEFT", x, 0)
    L.list:SetPoint("BOTTOMLEFT", L.content, "BOTTOMLEFT", x, 0)
    L.list:SetWidth(L.listW)
    H.Fill(L.detail, L.content, x + L.listW + S.GAP, 0, 0, 0)
    local y = 0
    if L.banner then
        H.Top(L.banner, L.detail, 0, 0, 0)
        y = H.Height(L.banner)
    end
    if L.tabs then
        H.Top(L.tabs, L.detail, 0, y, 0)
        y = y + G.TABS_H
    end
    H.Fill(L.body, L.detail, 0, y > 0 and (y + S.GAP) or 0, 0, 0)
    L.noticeX, L.noticeY = L.pad, L.y0
end

-- Detail page: hero banner (back link) -> tabs on its foot -> tool row -> body.
function Build.detail(L, o)
    L.y0 = L.top
    L.banner = H.Banner(L, o.banner, "hero", L.innerW, o.back)
    L.hero = L.banner
    L.tabs = H.TabStrip(L, o.tabStyle)
    if o.tabs then L.tabs:SetTabs(o.tabs, o.onTab) end
    if o.toolbar ~= false then L.toolbar = H.ToolRow(L) end
    L.body = H.Region(L)
    L.bodyW = L.innerW
    L.emptyRegion = "body"
end

function Place.detail(L, shift)
    H.Top(L.banner, L, L.pad, L.y0, L.pad)
    local y = L.y0 + H.Height(L.banner)
    H.Top(L.tabs, L, L.pad, y, L.pad)
    y = y + H.Height(L.tabs)
    if L.toolbar then
        H.Top(L.toolbar, L, L.pad, y + G.ROW_GAP, L.pad)
        y = y + G.ROW_GAP + G.ROW_H
    end
    L.noticeX, L.noticeY = L.pad, y + S.GAP
    H.Fill(L.body, L, L.pad, y + S.GAP + shift, L.pad, L.bottom)
end

-- Rail: side menu | hairline | body.
function Build.rail(L, o)
    L.y0 = L.top + (o.toolbar and H.TopToolbar(L) or G.RAIL_TOP)
    L.railW = o.railWidth or G.RAIL_W
    L.rail = UI:CreateRailNav(L, o.items or {}, o.onSelect,
        { width = L.railW, rowH = o.rowH or G.RAIL_ROW, selected = o.selected })
    L.rule = UI:Rule(L, { vertical = true, alpha = 0.08, layer = "BORDER" })
    L.bodyX = L.pad + L.railW + G.RAIL_GAP
    L.bodyW = L.pageW - L.pad - L.bodyX
    if o.scroll then
        L.scroll = UI:CreateScrollFrame(L)
        L.body = CreateFrame("Frame", nil, L.scroll)
        L.body:SetSize(L.bodyW, 10)
        L.scroll:SetScrollChild(L.body)
        L.scroll:HookScript("OnSizeChanged", function(_, w)
            if w and w > 0 then L.body:SetWidth(w) end
        end)
    else
        L.body = H.Region(L)
    end
    L.emptyRegion = "body"
end

function Place.rail(L, shift)
    L.rail:ClearAllPoints()
    L.rail:SetPoint("TOPLEFT", L, "TOPLEFT", L.pad, -L.y0)
    L.rail:SetWidth(L.railW)
    L.rule:ClearAllPoints()
    L.rule:SetPoint("TOPLEFT", L, "TOPLEFT", L.pad + L.railW, -L.y0)
    L.rule:SetPoint("BOTTOMLEFT", L, "BOTTOMLEFT", L.pad + L.railW, L.bottom)
    L.rule:SetWidth(1)
    L.noticeX, L.noticeY = L.bodyX, L.y0
    H.Fill(L.scroll or L.body, L, L.bodyX, L.y0 + shift, L.pad, L.bottom)
end

-- Tool window: banner (84) -> [tool row] -> body.
function Build.tool(L, o)
    L.y0 = L.top + L.pad
    L.banner = H.Banner(L, o.banner, "tool", L.innerW)
    if o.toolbar then L.toolbar = H.ToolRow(L) end
    L.body = H.Region(L)
    L.bodyW = L.innerW
    L.emptyRegion = "body"
end

function Place.tool(L, shift)
    H.Top(L.banner, L, L.pad, L.y0, L.pad)
    local y = L.y0 + H.Height(L.banner) + S.GAP
    if L.toolbar then
        H.Top(L.toolbar, L, L.pad, y, L.pad)
        y = y + G.ROW_H + S.GAP
    end
    L.noticeX, L.noticeY = L.pad, y
    H.Fill(L.body, L, L.pad, y + shift, L.pad, L.bottom)
end

---------------------------------------------------------------------------
-- Layout methods
---------------------------------------------------------------------------

-- Re-places the regions (a notice shown or hidden moves what is under it).
function Layout:Layout()
    local n = self.notice
    local on = n and n:IsShown()
    Place[self.kind](self, on and (H.Height(n) + S.GAP) or 0)
    if on then
        n:ClearAllPoints()
        n:SetPoint("TOPLEFT", self, "TOPLEFT", self.noticeX, -self.noticeY)
        n:SetPoint("TOPRIGHT", self, "TOPRIGHT", -self.pad, -self.noticeY)
    end
end

-- A read-only / locked / loading / info strip above the content (it only SHOWS what the page decided).
function Layout:ShowNotice(kind, text)
    local n = self.notice
    if not n then
        n = UI:CreateNotice(self, kind, text)
        n:SetFrameLevel(self:GetFrameLevel() + 6)
        self.notice = n
        n:HookScript("OnSizeChanged", function(f, _, h)
            if f:IsShown() and f.laidH ~= h then
                f.laidH = h
                self:Layout()
            end
        end)
    else
        n:SetNotice(kind, text)
    end
    n:SetWidth(self.kind == "rail" and self.bodyW or self.innerW)
    n:Show()
    n:Fit()
    n.laidH = n:GetHeight()
    self:Layout()
    return n
end

function Layout:HideNotice()
    if self.notice and self.notice:IsShown() then
        self.notice:Hide()
        self:Layout()
    end
end

function Layout:RegionWidth(which)
    if which == "list" then return self.listW end
    if which == "side" then return self.sideW end
    if which == "nav" then return self.navW end
    if which == "detail" then return self.detailW end
    if which == "body" then return self.bodyW end
    return self.innerW
end

-- The empty state (see the header): "content" hides the whole content, "body" hides the body; inside list / detail
-- / side / nav nothing hides.
function Layout:ShowEmpty(o)
    o = o or {}
    self:HideEmpty()
    local which = o.region or self.emptyRegion
    if which == "content" and not self.content then which = "body" end
    local host = self[which] or self.body
    if which == "body" and self.scroll then host = self.scroll end
    local w = self:RegionWidth(which) or self.innerW
    local copy = {}
    for k, v in pairs(o) do copy[k] = v end
    copy.compact = o.compact or (w < G.EMPTY_W)
    self.empties = self.empties or {}
    local e = self.empties[which]
    local hides = which == "content" or which == "body"
    if not e then
        -- (on the layout itself when its region is the one that hides)
        e = UI:CreateEmptyState(hides and self or host, copy)
        self.empties[which] = e
    else
        e:SetContent(copy)
    end
    e:SetBoxWidth(min(o.width or G.EMPTY_W, max(120, w - 40)))
    e:ClearAllPoints()
    e:SetPoint("TOP", host, "TOP", 0, -(o.y or G.EMPTY_Y))
    e:SetFrameLevel(host:GetFrameLevel() + 5)
    self.hidden = {}
    if hides and host:IsShown() then
        host:Hide()
        self.hidden[1] = host
    end
    e:Show()
    self.empty = e
    return e
end

function Layout:HideEmpty()
    if self.empty then self.empty:Hide() end
    self.empty = nil
    for _, f in ipairs(self.hidden or {}) do f:Show() end
    self.hidden = nil
end

function Layout:IsEmptyShown() return self.empty ~= nil and self.empty:IsShown() end

---------------------------------------------------------------------------
-- UI:CreateLayout
---------------------------------------------------------------------------

UI.LAYOUT_KINDS = { "board", "listdetail", "detail", "rail", "tool" }

function UI:CreateLayout(kind, parent, opts)
    if not Build[kind] then error("UI:CreateLayout: unknown layout kind " .. tostring(kind), 2) end
    opts = type(opts) == "table" and opts or {}
    local L = CreateFrame("Frame", nil, parent)
    if not opts.noAnchor then L:SetAllPoints(parent) end
    L.kind, L.opts = kind, opts
    L.pad = opts.pad or S.PAD
    L.top = opts.top or 0
    L.bottom = opts.bottom or ((kind == "board" or kind == "listdetail" or kind == "detail") and G.BOTTOM or S.PAD)
    L.pageW = opts.width or (kind == "tool" and G.TOOL_W or S.PAGE_W)
    L.innerW = L.pageW - 2 * L.pad
    for k, fn in pairs(Layout) do L[k] = fn end
    Build[kind](L, opts)
    L:Layout()
    -- (a banner's height may change later: keep what is under it in place)
    if L.banner then
        L.bannerH = L.banner:GetHeight()
        L.banner:HookScript("OnSizeChanged", function(_, _, h)
            if L.bannerH ~= h then
                L.bannerH = h
                L:Layout()
            end
        end)
    end
    return L
end

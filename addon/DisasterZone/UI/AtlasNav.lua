if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AtlasNav.lua", ...) then return end -- DisasterZone UI/AtlasNav.lua
-- ns.AtlasNav: the Atlas tab's path of drop-downs along its toolbar (UI/Atlas.lua shows the page under it):
--   era      "TBC ▾" / "Classic ▾": a menu of the two (only with the Classic data)
--   category its words open the category as art tiles; its arrow the jump panel at that category
--   place    the jump panel: Recent (both eras, Heroic remembered) over every place of a category (raids by phase,
--            Classic dungeons by level, each with its phase / levels and my BiS stars), the categories down the left
--            and the era at the bottom: one panel reaches anything
--   boss     a raid's / dungeon's bosses as Encounter Journal portraits with my stars, and "All bosses"; another
--            source's pages (a set's classes, a faction's standings, a profession's lists) as a menu
-- While searching, the search field takes the path's place. On the right: the search and the shopping list's bag
-- (with its count). In the shopping list: "Shopping list › Everyone ▾" (whose crafts).
local addonName, ns = ...

local Nav = {}
ns.AtlasNav = Nav

local S = ns.Style
local ipairs, type, tonumber, tostring = ipairs, type, tonumber, tostring
local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local PAD, GAP = S.PAD, S.GAP
local CRUMB_H, SEP_W, SEARCH_MIN, SEARCH_MAX, BAG_W = 24, 14, 140, 220, 28
local JUMP_W, CATS_W, ROW_H, HEAD_H = 640, 158, 24, 22
local BOSS_W, BOSS_H, BOSS_COLS = 112, 62, 4
local DOT = "  ·  "

local panel, bar, searchBox, bagBtn, bagBadge
local crumbs, seps = {}, {}
local blocker, jump, bosses
local searching = false
local jumpState = { era = nil, cat = nil }   -- what the jump panel shows (not where I am)

local function UI() return ns.UI end
local function A() return ns.Atlas end
local function AUI() return ns.AtlasUI end

---------------------------------------------------------------------------
-- Popovers: the jump panel and the bosses (a click outside closes them)
---------------------------------------------------------------------------

local function CloseAll()
    if jump then jump:Hide() end
    if bosses then bosses:Hide() end
    if blocker then blocker:Hide() end
    for _, c in ipairs(crumbs) do c:SetOpen(false) end
end
Nav.Close = function() CloseAll() end

local function Blocker()
    if blocker then return blocker end
    blocker = CreateFrame("Button", nil, panel)
    blocker:SetAllPoints(panel)
    blocker:SetFrameLevel(panel:GetFrameLevel() + 40)
    blocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    blocker:SetScript("OnClick", CloseAll)
    blocker:Hide()
    return blocker
end

-- A popover's frame: the dropdown's own look (UI.DROP_BG, a gold edge), over the blocker.
local function Popover(w)
    local U = UI()
    local f = CreateFrame("Frame", nil, panel)
    f:SetSize(w, 100)
    f:SetFrameLevel(panel:GetFrameLevel() + 50)
    f:EnableMouse(true)
    U:Fill(f, "DROP_BG")
    U:AddEdges(f, "BORDER")
    U:SetEdgeColor(f, S:Color(S:WithAlpha("GOLD", 0.45)))
    if U.SoftShadow then U:SoftShadow(f, 16, 0.55, 3, 2) end
    f:Hide()
    return f
end

-- Puts a popover under its crumb, kept inside the tab.
local function Place(f, crumb)
    f:ClearAllPoints()
    local pl = panel:GetLeft() or 0
    local pw = panel:GetWidth() or S.PAGE_W
    local cl = crumb:GetLeft() or (pl + PAD)
    local x = cl - pl
    if x + f:GetWidth() > pw - PAD then x = max(PAD, pw - PAD - f:GetWidth()) end
    f:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -(ns.UI.LAYOUT.TOP - 2))
end

---------------------------------------------------------------------------
-- The jump panel
---------------------------------------------------------------------------

local function SourceTag(src)
    local tag = AUI():PhaseTag(src)
    if tag then return tag end
    if src.size then return tostring(src.size) end
    return nil
end

local function SetupSourceRow(b)
    local U = UI()
    b:RegisterForClicks("LeftButtonUp")
    U:DecorateRow(b, { selectable = true })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("LEFT", 4, 0)
    b.name = U:Text(b, "body", "TEXT")
    b.name:SetPoint("LEFT", 28, 0)
    b.tag = U:Text(b, "small", "DIM")
    b.stars = U:Text(b, "small", "GOLD", { justify = "RIGHT" })
    b.stars:SetPoint("RIGHT", -6, 0)
    b:SetScript("OnClick", function(self)
        if self.place then AUI():OpenSource(self.place.cat.key, self.place.src.key, nil, self.place.heroic) end
    end)
end

local function FillSourceRow(b, cat, src, w)
    if not b.icon then SetupSourceRow(b) end
    b.place = { cat = cat, src = src }
    b:SetSize(w, ROW_H)
    b.icon:SetTexture(AUI():SourceIcon(src, cat))
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local n = AUI():SourceStars(src)
    b.stars:SetText(n > 0 and (AUI():StarText(9) .. " " .. n) or "")
    local tag = SourceTag(src)
    b.tag:SetText(tag or "")
    local room = w - 28 - 8 - (n > 0 and 30 or 0) - (tag and (ceil(b.tag:GetStringWidth() or 14) + 6) or 0)
    UI():FitText(b.name, src.name or "?", room)
    b.tag:ClearAllPoints()
    b.tag:SetPoint("LEFT", b.name, "LEFT", min(ceil(b.name:GetStringWidth() or 0), room) + 6, 0)
    local st = AUI():GetState()
    local here = st.cat == cat.key and st.src == src.key
    b:SetSelected(here)
    b.name:SetTextColor(S:Color(here and "GOLD" or "TEXT"))
    b:Show()
end

local function SetupRecent(b)
    local U = UI()
    b:RegisterForClicks("LeftButtonUp")
    U:Fill(b, "CARD")
    U:AddEdges(b, "BORDER")
    U:SetEdgeColor(b, S:Color("EDGE_STRONG"))
    b.thumb = b:CreateTexture(nil, "ARTWORK")
    b.thumb:SetSize(38, 22)
    b.thumb:SetPoint("LEFT", 4, 0)
    b.name = U:Text(b, "body", "TEXT")
    b.name:SetPoint("LEFT", b.thumb, "RIGHT", 7, 0)
    b.tag = U:CreatePill(b, nil, nil, 16)
    b.tag:SetPoint("LEFT", b.name, "RIGHT", 7, 0)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(S:Color("HOVER"))
    b:SetScript("OnClick", function(self)
        if self.place then AUI():OpenSource(self.place.cat, self.place.src, nil, self.place.heroic) end
    end)
end

local function FillRecent(b, r)
    if not b.thumb then SetupRecent(b) end
    local src = A():GetSource(r.cat, r.src)
    local cat = A():GetCategory(r.cat)
    b.place = r
    local file, l, rr, t, bb = AUI():SourceArt(src, 38, 22, 0.9)
    if file then
        b.thumb:SetTexture(file)
        b.thumb:SetTexCoord(l, rr, t, bb)
    else
        b.thumb:SetTexture(AUI():SourceIcon(src, cat))
        b.thumb:SetTexCoord(0.08, 0.92, 0.25, 0.75)
    end
    b.name:SetText(src.name or "?")
    local tagText, kind
    if cat.era ~= A():GetEra() then
        tagText, kind = A().ERA_NAMES[cat.era], "alt"
    elseif r.heroic then
        tagText, kind = "Heroic", "bad"
    else
        tagText, kind = cat.name, "mute"
    end
    b.tag:SetPill(kind, tagText)
    local w = 4 + 38 + 7 + ceil(b.name:GetStringWidth() or 40) + 7 + b.tag:GetWidth() + 8
    b:SetSize(w, 30)
    local st = AUI():GetState()
    UI():SetEdgeColor(b, S:Color((st.cat == r.cat and st.src == r.src) and "GOLD" or "EDGE_STRONG"))
    b:Show()
end

-- A category's places in groups: { { label, sources }, ... } (raids by phase, places with levels by level).
local function Groups(cat)
    local list = {}
    for _, src in ipairs(cat.sources) do list[#list + 1] = src end
    local function lo(src) return tonumber((src.lv or ""):match("^(%d+)")) or 0 end
    if list[1] and list[1].lv then
        table.sort(list, function(a, b)
            if lo(a) ~= lo(b) then return lo(a) < lo(b) end
            return (a.name or "") < (b.name or "")
        end)
        return { { label = "By level", sources = list } }
    end
    local byPhase, phases = {}, {}
    for _, src in ipairs(list) do
        local p = tonumber(src.phase) or 0
        if not byPhase[p] then
            byPhase[p] = {}
            phases[#phases + 1] = p
        end
        local g = byPhase[p]
        g[#g + 1] = src
    end
    if #phases < 2 then return { { label = cat.name, sources = list } } end
    table.sort(phases)
    local out = {}
    for _, p in ipairs(phases) do out[#out + 1] = { label = p > 0 and ("Phase " .. p) or cat.name, sources = byPhase[p] } end
    return out
end

local function CreateJump()
    local U = UI()
    local f = Popover(JUMP_W)
    f.catRows, f.rows, f.heads, f.recent = {}, {}, {}, {}
    f.rule = f:CreateTexture(nil, "ARTWORK")
    f.rule:SetWidth(1)
    f.rule:SetPoint("TOPLEFT", CATS_W, -8)
    f.rule:SetPoint("BOTTOMLEFT", CATS_W, 8)
    f.rule:SetColorTexture(S:Color("HAIRLINE"))
    f.recentLabel = U:Text(f, "caps", "GOLD", { text = "Recent" })
    f.allBtn = U:CreateSleekButton(f, "All as tiles ›", 100, 18, function()
        if jumpState.cat then AUI():OpenCategory(jumpState.cat) end
    end)
    if A():HasEra("classic") then
        f.era = U:CreateSegments(f, {
            { key = "classic", label = A().ERA_NAMES.classic }, { key = "tbc", label = A().ERA_NAMES.tbc },
        }, function(key)
            jumpState.era = key
            local cur = jumpState.cat and A():GetCategory(jumpState.cat)
            local base = cur and cur.key:gsub("^c_", "")
            jumpState.cat = nil
            for _, c in ipairs(A():GetCategories(true)) do
                if c.era == key and c.key:gsub("^c_", "") == base then jumpState.cat = c.key end
            end
            Nav:FillJump()
        end, { h = 20, width = CATS_W - 16 })
        f.era:SetPoint("BOTTOMLEFT", 8, 8)
    end
    return f
end

function Nav:FillJump()
    local f = jump
    local U = UI()
    local Atlas = A()
    local era = jumpState.era or Atlas:GetEra()
    -- the left: the era's categories
    local cats = {}
    for _, c in ipairs(Atlas:GetCategories(true)) do
        if c.era == era then cats[#cats + 1] = c end
    end
    if not jumpState.cat or not Atlas:GetCategory(jumpState.cat) or Atlas:EraOf(jumpState.cat) ~= era then
        jumpState.cat = cats[1] and cats[1].key
    end
    for i, c in ipairs(cats) do
        local b = f.catRows[i]
        if not b then
            b = CreateFrame("Button", nil, f)
            b:RegisterForClicks("LeftButtonUp")
            U:DecorateRow(b, { selectable = true })
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetSize(20, 20)
            b.icon:SetPoint("LEFT", 6, 0)
            b.name = U:Text(b, "body", "TEXT")
            b.name:SetPoint("LEFT", 32, 0)
            b:SetScript("OnClick", function(self)
                jumpState.cat = self.key
                Nav:FillJump()
            end)
            f.catRows[i] = b
        end
        b.key = c.key
        b:SetSize(CATS_W - 12, 26)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -8 - (i - 1) * 27)
        b.icon:SetTexture(AUI():CatIcon(c))
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.name:SetText(c.name or "?")
        local on = c.key == jumpState.cat
        b:SetSelected(on)
        b.name:SetTextColor(S:Color(on and "GOLD" or "TEXT"))
        b:Show()
    end
    for i = #cats + 1, #f.catRows do f.catRows[i]:Hide() end
    local leftH = 8 + #cats * 27 + (f.era and 36 or 8)
    if f.era then f.era:Select(era) end

    -- the right: Recent, then the category's places in groups
    local x0, w = CATS_W + 12, JUMP_W - CATS_W - 24
    local y = 10
    local st = AUI():GetState()
    local shown = 0
    f.recentLabel:ClearAllPoints()
    f.recentLabel:SetPoint("TOPLEFT", f, "TOPLEFT", x0, -y)
    local rx, ry = 0, y + 16
    for _, r in ipairs(st.recent or {}) do
        if A():GetSource(r.cat, r.src) then
            shown = shown + 1
            local b = f.recent[shown]
            if not b then
                b = CreateFrame("Button", nil, f)
                f.recent[shown] = b
            end
            FillRecent(b, r)
            if rx > 0 and rx + b:GetWidth() > w then
                rx = 0
                ry = ry + 36
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + rx, -ry)
            rx = rx + b:GetWidth() + 6
        end
    end
    for i = shown + 1, #f.recent do f.recent[i]:Hide() end
    f.recentLabel:SetShown(shown > 0)
    if shown > 0 then y = ry + 30 + 12 end

    local cat = jumpState.cat and Atlas:GetCategory(jumpState.cat)
    local groups = cat and Groups(cat) or {}
    local total = 0
    for _, g in ipairs(groups) do total = total + #g.sources end
    local ncol = total > 30 and 3 or 2
    local cw = floor((w - (ncol - 1) * 10) / ncol)
    local ri, hi = 0, 0
    f.allBtn:ClearAllPoints()
    f.allBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(y - 2))
    f.allBtn:SetShown(cat ~= nil)
    for gi, g in ipairs(groups) do
        hi = hi + 1
        local h = f.heads[hi]
        if not h then
            h = U:Text(f, "caps", "GOLD")
            f.heads[hi] = h
        end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", f, "TOPLEFT", x0, -y)
        h:SetText((#groups == 1 and cat.name or g.label):upper())
        h:Show()
        y = y + HEAD_H
        for i, src in ipairs(g.sources) do
            ri = ri + 1
            local b = f.rows[ri]
            if not b then
                b = CreateFrame("Button", nil, f)
                f.rows[ri] = b
            end
            local col = (i - 1) % ncol
            local line = floor((i - 1) / ncol)
            FillSourceRow(b, cat, src, cw)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + col * (cw + 10), -(y + line * (ROW_H + 1)))
        end
        y = y + ceil(#g.sources / ncol) * (ROW_H + 1) + (gi < #groups and 10 or 0)
    end
    for i = ri + 1, #f.rows do f.rows[i]:Hide() end
    for i = hi + 1, #f.heads do f.heads[i]:Hide() end
    f:SetHeight(max(leftH, y + 12))
end

function Nav:OpenJump(catKey, crumb)
    if not panel then return end
    jump = jump or CreateJump()
    local st = AUI():GetState()
    jumpState.era = A():GetEra()
    jumpState.cat = catKey or st.cat
    self:FillJump()
    Blocker():Show()
    if bosses then bosses:Hide() end
    Place(jump, crumb or crumbs[1] or bar)
    jump:Show()
    jump:Raise()
    if crumb and crumb.SetOpen then crumb:SetOpen(true) end
end

---------------------------------------------------------------------------
-- The bosses
---------------------------------------------------------------------------

local function SetupBossCard(b)
    local U = UI()
    b:RegisterForClicks("LeftButtonUp")
    U:Fill(b, "CARD")
    U:AddEdges(b, "BORDER")
    b.port = b:CreateTexture(nil, "ARTWORK")
    b.port:SetSize(64, 32)
    b.port:SetPoint("TOP", 0, -3)
    b.name = U:Text(b, "small", "TEXT", { justify = "CENTER" })
    b.name:SetPoint("TOP", b.port, "BOTTOM", 0, -3)
    b.name:SetWidth(BOSS_W - 6)
    b.name:SetWordWrap(true)
    if b.name.SetMaxLines then b.name:SetMaxLines(2) end
    b.stars = U:Text(b, "small", "GOLD", { justify = "RIGHT" })
    b.stars:SetPoint("TOPRIGHT", -4, -3)
    b.big = U:Text(b, "title", "TEXT")
    b.big:SetPoint("TOPLEFT", 12, -14)
    b.small = U:Text(b, "small", "SUB")
    b.small:SetPoint("TOPLEFT", b.big, "BOTTOMLEFT", 0, -3)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(S:Color("HOVER"))
    b:SetScript("OnClick", function(self)
        if self.all then AUI():OpenAll() else AUI():OpenPage(self.key) end
    end)
end

function Nav:OpenBosses(crumb)
    local st = AUI():GetState()
    local src = st.cat and A():GetSource(st.cat, st.src)
    if not src then return end
    if not AUI():HasBosses(src) then
        -- another source's pages: a menu
        UI():ContextMenu(crumb or panel, function(root)
            for _, pr in ipairs(AUI():VisiblePages(src)) do
                root:CreateRadio(pr.page.name or "?", function(v) return st.page == v end, function(v)
                    AUI():OpenPage(v)
                end, pr.page.key)
            end
        end)
        return
    end
    if not bosses then
        bosses = Popover(BOSS_COLS * (BOSS_W + 4) + 12)
        bosses.cards = {}
        bosses.hint = UI():Text(bosses, "small", "DIM")
    end
    local f = bosses
    local list = {}
    if AUI():OpensOnAll(src) then list[1] = { all = true } end
    for _, pr in ipairs(AUI():VisiblePages(src)) do list[#list + 1] = { page = pr.page } end
    local slot = 0
    for i, e in ipairs(list) do
        local b = f.cards[i]
        if not b then
            b = CreateFrame("Button", nil, f)
            SetupBossCard(b)
            f.cards[i] = b
        end
        local span = e.all and 2 or 1
        b.all = e.all
        b.key = e.page and e.page.key
        local col, line = slot % BOSS_COLS, floor(slot / BOSS_COLS)
        if col + span > BOSS_COLS then
            slot = slot + (BOSS_COLS - col)
            col, line = 0, line + 1
        end
        b:SetSize(span * BOSS_W + (span - 1) * 4, BOSS_H)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 8 + col * (BOSS_W + 4), -(8 + line * (BOSS_H + 4)))
        slot = slot + span
        b.port:SetShown(not e.all)
        b.name:SetShown(not e.all)
        b.big:SetShown(e.all == true)
        b.small:SetShown(e.all == true)
        local on
        if e.all then
            b.big:SetText("All bosses")
            local n = 0
            for _, p in ipairs(src.pages) do n = n + #(p.items or {}) end
            b.small:SetText(("Every item on one page"):format(n))
            b.stars:SetText("")
            on = st.view == "source"
        else
            -- (no Journal portrait: the name alone, in the card's middle)
            local tex, own = AUI():PortraitOf(e.page)
            b.port:SetShown(own)
            if own then b.port:SetTexture(tex) end
            b.name:ClearAllPoints()
            if own then
                b.name:SetPoint("TOP", b.port, "BOTTOM", 0, -3)
            else
                b.name:SetPoint("CENTER", b, "CENTER", 0, 0)
            end
            b.name:SetText(e.page.name or "?")
            local n = AUI():PickCount(e.page)
            b.stars:SetText(n > 0 and (AUI():StarText(9) .. n) or "")
            on = st.view == "page" and st.page == e.page.key
        end
        UI():SetEdgeColor(b, S:Color(on and "GOLD" or "EDGE_QUIET"))
        b.name:SetTextColor(S:Color(on and "GOLD" or "TEXT"))
        b:Show()
    end
    for i = #list + 1, #f.cards do f.cards[i]:Hide() end
    local lines = ceil(slot / BOSS_COLS)
    f.hint:Hide()
    f:SetHeight(8 + lines * (BOSS_H + 4) + 4)
    Blocker():Show()
    if jump then jump:Hide() end
    Place(f, crumb or bar)
    f:Show()
    f:Raise()
    if crumb and crumb.SetOpen then crumb:SetOpen(true) end
end

---------------------------------------------------------------------------
-- The crumbs
---------------------------------------------------------------------------

local Crumb = {}

function Crumb:SetOpen(on)
    self.open = on and true or false
    self:Paint()
end

function Crumb:Paint()
    local U = UI()
    local gold = self.kind == "cur" or self.open or self.kind == "era"
    self.label:SetTextColor(S:Color(gold and "GOLD" or "TEXT"))
    self.bg:SetShown(self.open or self.kind == "era")
    if self.kind == "era" then
        self.bg:SetColorTexture(S:Color("SELECT"))
        U:SetEdgeColor(self, S:Color(S:WithAlpha("GOLD", 0.5)))
    elseif self.open then
        self.bg:SetColorTexture(S:Color("CARD"))
        U:SetEdgeColor(self, S:Color("EDGE_FOCUS"))
    else
        U:SetEdgeColor(self, 0, 0, 0, 0)
    end
end

local function NewCrumb()
    local U = UI()
    local c = CreateFrame("Button", nil, bar)
    c:SetHeight(CRUMB_H)
    c:RegisterForClicks("LeftButtonUp")
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    U:AddEdges(c, "BORDER")
    c.hl = c:CreateTexture(nil, "HIGHLIGHT")
    c.hl:SetAllPoints()
    c.hl:SetColorTexture(S:Color("HOVER"))
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(18, 18)
    c.icon:SetPoint("LEFT", 6, 0)
    c.label = U:Text(c, "title", "TEXT")
    c.chev = c:CreateTexture(nil, "ARTWORK")
    c.chev:SetSize(10, 10)
    c.chev:SetTexture(U.ICON_ATLAS)
    local co = U:IconCoords(U.ICON.chevron)
    c.chev:SetTexCoord(co[1], co[2], co[3], co[4])
    c.chev:SetVertexColor(S:Color("GOLD"))
    -- (the category's arrow: its own button, the words open the tiles)
    c.arrow = CreateFrame("Button", nil, c)
    c.arrow:SetPoint("TOPRIGHT")
    c.arrow:SetPoint("BOTTOMRIGHT")
    c.arrow:SetWidth(20)
    c.arrow:RegisterForClicks("LeftButtonUp")
    local ahl = c.arrow:CreateTexture(nil, "HIGHLIGHT")
    ahl:SetAllPoints()
    ahl:SetColorTexture(S:Color("HOVER"))
    c.arrow:SetScript("OnClick", function() if c.onArrow then c.onArrow(c) end end)
    c:SetScript("OnClick", function(self) if self.onClick then self.onClick(self) end end)
    U:AttachTooltip(c, function(self, tt)
        if not self.tip then return false end
        tt:AddLine(self.tip[1], S:RGB("GOLD"))
        tt:AddLine(self.tip[2], 1, 1, 1, true)
    end)
    for k, fn in pairs(Crumb) do c[k] = fn end
    return c
end

-- items: { { text, kind = "era" | "mid" | "cur", icon, onClick, onArrow, tip } ... }
-- The toolbar's room for the path: what the search (at its narrowest) and the bag leave.
local function PathRoom()
    local w = bar:GetWidth()
    w = (w and w > 1) and w or S.PAGE_W
    return w - PAD - BAG_W - 8 - SEARCH_MIN - 12
end

-- items: { { text, kind = "era" | "mid" | "cur", icon, onClick, onArrow, tip } ... }. The path never runs under the
-- search: too long, the place's icon goes first, then the last crumb's name is cut to what is left.
local function LayoutCrumbs(items)
    local U = UI()
    local room = PathRoom()
    local widths, total = {}, PAD
    for i, it in ipairs(items) do
        local c = crumbs[i] or NewCrumb()
        crumbs[i] = c
        c.kind, c.onClick, c.onArrow, c.tip = it.kind, it.onClick, it.onArrow, it.tip
        c.open = false
        U:SetTextStyle(c.label, it.kind == "era" and "small" or "emph", it.kind == "era" and "GOLD" or "TEXT")
        c.label:SetText(it.text or "")
        c.iconOn = it.icon ~= nil
        if it.icon then
            c.icon:SetTexture(it.icon)
            c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        c.textW = ceil(c.label:GetStringWidth() or 40)
        c.chevOn = (it.onClick ~= nil or it.onArrow ~= nil) and not it.back
        local w = (c.iconOn and 28 or 8) + c.textW + (c.chevOn and 16 or 0) + 8 + (it.onArrow and 4 or 0)
        widths[i] = w
        total = total + w + (i < #items and SEP_W or 0)
    end
    -- too long: the place's icon goes, then the last crumb is cut
    if total > room then
        for i, it in ipairs(items) do
            local c = crumbs[i]
            if c.iconOn and total > room then
                c.iconOn = false
                widths[i] = widths[i] - 20
                total = total - 20
            end
        end
    end
    local cutTo
    if total > room and #items > 0 then
        local last = crumbs[#items]
        cutTo = max(40, last.textW - (total - room))
        widths[#items] = widths[#items] - (last.textW - cutTo)
    end
    local x = PAD
    for i, it in ipairs(items) do
        local c = crumbs[i]
        c.icon:SetShown(c.iconOn)
        local lx = c.iconOn and 28 or 8
        c.label:ClearAllPoints()
        c.label:SetPoint("LEFT", c, "LEFT", lx, 0)
        local tw = c.textW
        if i == #items and cutTo then
            U:FitText(c.label, it.text or "", cutTo)
            tw = cutTo
        end
        c.chev:SetShown(c.chevOn)
        c.chev:ClearAllPoints()
        if c.chevOn then c.chev:SetPoint("LEFT", c, "LEFT", lx + tw + 6, 0) end
        c.arrow:SetShown(it.onArrow ~= nil)
        c:SetSize(widths[i], it.kind == "era" and 20 or CRUMB_H)
        c:ClearAllPoints()
        c:SetPoint("LEFT", bar, "TOPLEFT", x, -ns.UI.LAYOUT.ROW_MID)
        c:Paint()
        c:Show()
        x = x + widths[i]
        local sp = seps[i]
        if i < #items then
            if not sp then
                sp = U:Text(bar, "title", "SUB", { justify = "CENTER", width = SEP_W })
                sp:SetText("›")
                seps[i] = sp
            end
            sp:ClearAllPoints()
            sp:SetPoint("LEFT", bar, "TOPLEFT", x, -ns.UI.LAYOUT.ROW_MID)
            sp:Show()
            x = x + SEP_W
        end
    end
    for i = #items + 1, #crumbs do crumbs[i]:Hide() end
    for i, sp in ipairs(seps) do
        if i >= #items then sp:Hide() end
    end
    Nav.pathEnd = x
end

local function EraMenu(crumb)
    UI():ContextMenu(crumb, function(root)
        root:CreateTitle("Era")
        for _, e in ipairs({ "classic", "tbc" }) do
            local tip = e == "classic"
                and "Levels 1-60: the old world's raids, dungeons, professions, factions, battlegrounds and sets."
                or "The Burning Crusade: Outland's raids, dungeons, professions, factions, PvP and sets."
            local b = root:CreateRadio(A().ERA_LONG[e], function(v) return A():GetEra() == v end, function(v)
                CloseAll()
                AUI():SetEra(v)
            end, e)
            if b and b.SetTooltip then b:SetTooltip(function(tt) tt:AddLine(tip, 1, 1, 1, true) end) end
        end
    end)
end

local function ShopMenu(crumb)
    local Shop = ns.AtlasShopUI
    if not Shop then return end
    UI():ContextMenu(crumb, function(root)
        for _, g in ipairs(Shop:GetGroupChoices()) do
            root:CreateRadio(g.label, function(v) return Shop:GetState().group == v end, function(v)
                Shop:Select(v)
                Nav:Update()
            end, g.id)
        end
    end)
end

-- "‹ Karazhan": back to where I was (out of a search, out of the shopping list).
function Nav.BackItem()
    local label = AUI():BackLabel()
    return { text = "‹  " .. label, kind = "mid", back = true, onClick = function() AUI():GoBack() end,
             tip = { "Back", "Back to " .. label .. "." } }
end

-- The crumbs of where I am.
local function Items()
    local st = AUI():GetState()
    local Atlas = A()
    local out = {}
    if st.view == "shop" then
        out[1] = Nav.BackItem()
        out[2] = { text = "Shopping list", kind = "mid", icon = nil }
        local label = ns.AtlasShopUI and ns.AtlasShopUI:GetGroupLabel() or "Everyone"
        out[3] = { text = label, kind = "cur", onClick = ShopMenu }
        return out
    end
    if Atlas:HasEra("classic") then
        out[#out + 1] = { text = Atlas.ERA_NAMES[Atlas:GetEra()], kind = "era", onClick = EraMenu,
                          tip = { "Era", "Classic (levels 1-60) or The Burning Crusade." } }
    end
    local cat = st.cat and Atlas:GetCategory(st.cat)
    if not cat then return out end
    out[#out + 1] = { text = cat.name, kind = st.view == "category" and "cur" or "mid",
                      onClick = function() AUI():OpenCategory(cat.key) end,
                      onArrow = function(c) Nav:OpenJump(cat.key, c) end,
                      tip = { cat.name, "Click: every place as tiles. Arrow: jump anywhere." } }
    if st.view == "category" then return out end
    local src = Atlas:GetSource(st.cat, st.src)
    if not src then return out end
    local single = #src.pages <= 1
    out[#out + 1] = { text = src.name, kind = single and "cur" or "mid", icon = AUI():SourceIcon(src, cat),
                      onClick = function(c) Nav:OpenJump(cat.key, c) end,
                      tip = { "Places", "Every place of " .. (cat.name or "the category") .. ", your recent ones and the other categories." } }
    if single then return out end
    local pageText
    if st.view == "source" then
        pageText = "All bosses"
    else
        local page = Atlas:GetPage(st.cat, st.src, st.page)
        pageText = page and (page.name or "?") or "?"
    end
    out[#out + 1] = { text = pageText, kind = "cur", onClick = function(c) Nav:OpenBosses(c) end }
    return out
end

---------------------------------------------------------------------------
-- The search field and the bag
---------------------------------------------------------------------------

local function LayoutRight()
    if not (searchBox and bagBtn) then return end
    bagBtn:ClearAllPoints()
    bagBtn:SetPoint("RIGHT", bar, "TOPRIGHT", -PAD + 2, -ns.UI.LAYOUT.ROW_MID)
    searchBox:ClearAllPoints()
    if searching then
        searchBox:SetPoint("LEFT", bar, "TOPLEFT", (Nav.pathEnd or PAD) + 6, -ns.UI.LAYOUT.ROW_MID)
        searchBox:SetPoint("RIGHT", bagBtn, "LEFT", -8, 0)
    else
        -- what the path leaves, between its narrowest and widest
        local w = bar:GetWidth()
        w = (w and w > 1) and w or S.PAGE_W
        local free = w - PAD - BAG_W - 8 - (Nav.pathEnd or PAD) - 12
        searchBox:SetPoint("RIGHT", bagBtn, "LEFT", -8, 0)
        searchBox:SetWidth(max(SEARCH_MIN, min(SEARCH_MAX, free)))
    end
end

-- The shopping list: the bag as an icon button like the bell, its count on the icon's corner (the addon's count
-- badge, ringed in the toolbar's colour); gold while the list is open.
local function PaintBag()
    if not bagBtn then return end
    local on = AUI():GetState().view == "shop" and not AUI():IsSearching()
    local c = (on or bagBtn.hovered) and "GOLD" or "TEXT"
    bagBtn.icon:SetVertexColor(S:Color(c))
    bagBtn.icon:SetAlpha((on or bagBtn.hovered) and 1 or 0.8)
end

local function CreateBag()
    local U = UI()
    local b = CreateFrame("Button", nil, bar)
    b:SetSize(BAG_W, 26)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("CENTER", 0, 1)
    b.icon:SetTexture(U.ICON_ATLAS)
    local co = U:IconCoords(U.ICON.bag)
    b.icon:SetTexCoord(co[1], co[2], co[3], co[4])
    bagBadge = U:CreateCountBadge(b, 14)
    bagBadge:SetCutout()
    bagBadge:SetPoint("LEFT", b.icon, "TOPRIGHT", -7, -2)
    bagBadge:SetFrameLevel(b:GetFrameLevel() + 2)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function()
        GameTooltip:Hide()
        if AUI():GetState().view == "shop" and not AUI():IsSearching() then
            AUI():GoBack()
        else
            AUI():OpenShop()
        end
    end)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        PaintBag()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        PaintBag()
    end)
    U:AttachTooltip(b, function(_, tt)
        local n = ns.Shop and ns.Shop:Count() or 0
        tt:AddLine("Shopping list", S:RGB("GOLD"))
        tt:AddLine(n == 0 and "Nothing on it yet: hover a craft and click + List."
            or (n == 1 and "1 craft on it." or (n .. " crafts on it.")), 1, 1, 1, true)
    end, nil, { anchor = "ANCHOR_BOTTOM" })
    return b
end

local function UpdateBag()
    if not bagBtn then return end
    bagBadge:SetCount(ns.Shop and ns.Shop:Count() or 0)
    PaintBag()
end

---------------------------------------------------------------------------
-- API (UI/Atlas.lua)
---------------------------------------------------------------------------

function Nav:Create(atlasPanel, toolbar, box)
    panel, bar, searchBox = atlasPanel, toolbar, box
    bagBtn = CreateBag()
    panel.bag = bagBtn
    panel:HookScript("OnHide", CloseAll)
    LayoutRight()
end

-- (search mode follows the search text alone: Update reads it; kept for callers)
function Nav:SetSearching()
    self:Update()
end

function Nav:Update()
    if not bar then return end
    -- (a drop-down is open: it stays, with its crumb)
    if (jump and jump:IsShown()) or (bosses and bosses:IsShown()) then
        UpdateBag()
        return
    end
    -- search mode is "there is a search": a field that only has the focus, or a result opened, keeps the path
    searching = AUI():IsSearching() and true or false
    if searching then
        LayoutCrumbs({ Nav.BackItem() })
    else
        LayoutCrumbs(Items())
    end
    LayoutRight()
    UpdateBag()
end

-- For tests and the UI audit: the crumbs shown ({ text, kind } ...), the crumb frames.
function Nav:GetCrumbs()
    local out = {}
    for _, c in ipairs(crumbs) do
        if c:IsShown() then out[#out + 1] = { (c.label:GetText() or ""), c.kind } end
    end
    return out
end

function Nav:GetCrumbFrames() return crumbs end
function Nav:GetJump() return jump end
function Nav:GetBosses() return bosses end

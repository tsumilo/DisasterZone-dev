-- CDLoot: UI/StrategyBlocks.lua
-- The assignment blocks of a strategy page (Addendum K): small tables with a coloured title bar, optional column
-- headers and rows of cells. Column types: player slot (p), target (g: icon + label, or another slot's player),
-- order number (o) and text (x).
-- Modes: "edit" (authors shape the blocks: title-bar gear menu, click headers / cells), "fill" (raid leaders put players
-- into the slots: click a slot for the list of players, or drag a player onto it; right-click clears) and "view".
local addonName, ns = ...

local BlocksUI = ns:NewModule("StrategyBlocksUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tinsert, tremove = table.insert, table.remove

local TITLE_H, HEAD_H, ROW_H, GAP = 20, 16, 18, 8
local COL_WEIGHT = { p = 2, g = 2, x = 3 }
local ORDER_W = 20
local CARD_H = 36

local function S() return ns.Strategy end
local function MapUI() return ns.StrategyMapUI end
local function UI() return ns.UI end

local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end

-- Block templates for "Add block".
BlocksUI.TEMPLATES = {
    { label = "Players with targets", sub = "tank on boss, healer on tank",
      make = function() return { n = "Assignments", r = 4, c = { { t = "p", n = "Player" }, { t = "g", n = "Target" } } } end },
    { label = "Rotation (ordered)", sub = "interrupts, misdirects",
      make = function() return { n = "Rotation", r = 3, c = { { t = "o" }, { t = "p", n = "Player" }, { t = "g", n = "Target" } } } end },
    { label = "Groups / zones", sub = "players split into columns",
      make = function() return { n = "Zones", r = 5, c = { { t = "p", n = "Zone 1" }, { t = "p", n = "Zone 2" } } } end },
    { label = "Pairs", sub = "innervates, Power Infusion: from -> to",
      make = function() return { n = "Innervates", r = 3, c = { { t = "p", n = "From", f = "DRUID" }, { t = "p", n = "To" } } } end },
    { label = "Single job", sub = "Bloodlust with a timing",
      make = function() return { n = "Bloodlust", r = 1, c = { { t = "p", n = "Player" }, { t = "x", n = "When" } } } end },
    { label = "Notes", sub = "text only",
      make = function() return { n = "Notes", r = 3, c = { { t = "x" } } } end },
}

local COL_TYPE_NAME = { p = "Player slot", g = "Target", o = "Order #", x = "Text" }
BlocksUI.COL_TYPE_NAME = COL_TYPE_NAME

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local Panel = {}
Panel.__index = Panel

-- opts: mode() -> "edit"|"fill"|"view"; page(); strat(); assigned(ref) -> key; memberInfo(key) -> { c, missing };
-- isDup(ref); onAssign(ref, key|nil); members() -> { {key, c, sp} }; onChange(); onHover(ref|nil); prompt(title, def, cb,
-- multiline, maxLen); slotName(ref) -> coloured player name or nil.
function BlocksUI:Create(parent, opts)
    local self = setmetatable({}, Panel)
    self.opts = opts
    self.blocks = {}
    local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    self.scroll = sf
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(10, 10)
    sf:SetScrollChild(child)
    self.child = child
    self.notes = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.notes:SetJustifyH("LEFT")
    self.notes:SetJustifyV("TOP")
    self.notesBtn = UI():CreateSleekButton(child, "Page notes...", 100, 22, function() self:EditNotes() end)
    self.addBtn = UI():CreateSleekButton(child, "+ Add block", 110, 22, function(btn) self:AddMenu(btn) end, "primary")
    self.empty = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.empty:SetJustifyH("LEFT")
    -- editing an empty page: a heading, a line of help, and cards that add a block in one click
    self.emptyTitle = child:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.emptyTitle:SetJustifyH("LEFT")
    self.emptyTitle:SetText("Jobs on this page")
    self.emptyText = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.emptyText:SetJustifyH("LEFT")
    self.emptyText:SetTextColor(0.7, 0.7, 0.7)
    self.emptyText:SetText("Blocks are small tables of jobs: who tanks what, who kicks, who stands where. "
        .. "They hold the job slots; the names go in when a raid is assigned.")
    self.suggestHead = child:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.suggestHead:SetJustifyH("LEFT")
    self.suggestHead:SetText("SUGGESTED FROM THE MAP")
    self.templateHead = child:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.templateHead:SetJustifyH("LEFT")
    self.cards = {}
    return self
end

-- A clickable card: icon (optional), title, grey line under it.
local function newCard(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    UI():AddEdges(c)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(24, 24)
    c.icon:SetPoint("LEFT", 6, 0)
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.title:SetJustifyH("LEFT")
    c.title:SetWordWrap(false)
    c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.sub:SetJustifyH("LEFT")
    c.sub:SetWordWrap(false)
    local function paint(self)
        local v = self.hovered and 0.19 or 0.1
        self.bg:SetColorTexture(v, v, v + 0.02, 0.92)
        if self.hovered then UI():SetEdgeColor(self, 1, 0.82, 0, 0.8) else UI():SetEdgeColor(self, 0.3, 0.3, 0.34, 0.9) end
    end
    c:SetScript("OnEnter", function(self) self.hovered = true; paint(self) end)
    c:SetScript("OnLeave", function(self) self.hovered = false; paint(self) end)
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", function(self) if self.onPick then self.onPick() end end)
    function c:Set(title, sub, iconKey)
        self.title:SetText(title)
        self.sub:SetText(sub or "")
        self.icon:SetShown(iconKey ~= nil)
        if iconKey then MapUI():SetIcon(self.icon, iconKey) end
        local left = iconKey and 36 or 10
        self.title:ClearAllPoints()
        self.title:SetPoint("TOPLEFT", left, -5)
        self.title:SetPoint("RIGHT", -8, 0)
        self.sub:ClearAllPoints()
        self.sub:SetPoint("TOPLEFT", self.title, "BOTTOMLEFT", 0, -2)
        self.sub:SetPoint("RIGHT", -8, 0)
        paint(self)
    end
    return c
end

-- Blocks a page's map suggests: one per creature on it that isn't linked to a job yet (all the same-named ones in
-- one block, a row each, numbered clockwise from the top), each linked to its row so the names show on the map.
function Panel:Suggestions(page)
    local strat = self.opts.strat()
    local groups, order = {}, {}
    for _, e in ipairs(page.e or {}) do
        if e.t == "i" and e.l and e.l ~= "" and not e.ln then
            local g = groups[e.l]
            if not g then
                g = { label = e.l, icon = e.i, list = {} }
                groups[e.l] = g
                order[#order + 1] = g
            end
            g.list[#g.list + 1] = e
        end
    end
    local bossName = strat and strat.b and S():GetBossName(strat.b)
    local out = {}
    for _, g in ipairs(order) do
        local list = g.list
        while #list > S().MAX_ROWS do tremove(list) end
        local n = #list
        if n > 1 then
            local cx, cy = 0, 0
            for _, e in ipairs(list) do cx, cy = cx + e.x, cy + e.y end
            cx, cy = cx / n, cy / n
            local function ang(e)
                local a = math.atan2(e.x - cx, cy - e.y)
                return a < 0 and a + 2 * math.pi or a
            end
            table.sort(list, function(a, b) return ang(a) < ang(b) end)
        end
        local isBoss = g.label == bossName
        out[#out + 1] = {
            title = isBoss and ("Tanks on " .. g.label) or (g.label .. (n > 1 and ("  x" .. n) or "")),
            sub = n > 1 and ("%d rows, one per %s, linked on the map"):format(n, g.label)
                or "1 row, linked to it on the map",
            icon = g.icon,
            apply = function()
                local k = { n = (isBoss and "Tanks" or g.label):sub(1, S().MAX_NAME_LEN), r = n,
                            c = { { t = "p", n = isBoss and "Tank" or "Player" }, { t = "g", n = "Target" } }, d = {} }
                k.id = S():NewPartId(strat, "k")
                for i, e in ipairs(list) do
                    local label = n > 1 and (g.label .. " " .. i) or g.label
                    k.d[i] = { [2] = { i = g.icon, l = label:sub(1, S().MAX_CELL) } }
                    e.ln = S().SlotRef(k.id, i, 1)
                end
                tinsert(page.k, k)
                self:Changed()
            end,
        }
    end
    return out
end

-- The empty page while editing. Returns the height used.
function Panel:RenderEmpty(page, width, y)
    local child = self.child
    local used = 0
    local function card()
        used = used + 1
        local c = self.cards[used]
        if not c then
            c = newCard(child)
            self.cards[used] = c
        end
        c:ClearAllPoints()
        c:Show()
        return c
    end
    self.emptyTitle:ClearAllPoints()
    self.emptyTitle:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -(y + 4))
    self.emptyTitle:Show()
    y = y + 28
    self.emptyText:ClearAllPoints()
    self.emptyText:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
    self.emptyText:SetWidth(width - 4)
    self.emptyText:Show()
    y = y + (self.emptyText:GetStringHeight() or 24) + 16
    local sugg = self:Suggestions(page)
    self.suggestHead:SetShown(#sugg > 0)
    if #sugg > 0 then
        self.suggestHead:ClearAllPoints()
        self.suggestHead:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
        y = y + 16
        for _, sg in ipairs(sugg) do
            local c = card()
            c:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            c:SetWidth(width)
            c:Set(sg.title, sg.sub, sg.icon)
            c.onPick = sg.apply
            y = y + CARD_H + 4
        end
        y = y + 12
    end
    self.templateHead:SetText(#sugg > 0 and "OR START FROM A TEMPLATE" or "START FROM A TEMPLATE")
    self.templateHead:ClearAllPoints()
    self.templateHead:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
    self.templateHead:Show()
    y = y + 16
    local colW = floor((width - 6) / 2)
    for i, t in ipairs(BlocksUI.TEMPLATES) do
        local c = card()
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        c:SetPoint("TOPLEFT", child, "TOPLEFT", col * (colW + 6), -(y + row * (CARD_H + 4)))
        c:SetWidth(colW)
        c:Set(t.label, t.sub)
        c.onPick = function()
            local k = t.make()
            k.id = S():NewPartId(self.opts.strat(), "k")
            tinsert(page.k, k)
            self:Changed()
        end
    end
    y = y + math.ceil(#BlocksUI.TEMPLATES / 2) * (CARD_H + 4) + 10
    for i = used + 1, #self.cards do self.cards[i]:Hide() end
    return y
end

function Panel:Width()
    local w = self.scroll:GetWidth() or 0
    if w < 50 then w = self.width or 420 end
    return w
end

function Panel:Mode() return self.opts.mode() end

function Panel:Changed()
    if self.opts.onChange then self.opts.onChange() end
end

function Panel:EditNotes()
    local page = self.opts.page()
    if not page then return end
    self.opts.prompt("Page notes (shown under the blocks)", page.no or "", function(text)
        text = ns.Util.Trim((text or ""):gsub("|", ""))
        page.no = text ~= "" and text:sub(1, S().MAX_NOTES) or nil
        self:Changed()
    end, true, S().MAX_NOTES)
end

function Panel:AddMenu(owner)
    local page = self.opts.page()
    if not page then return end
    if #page.k >= S().MAX_BLOCKS then
        ns:Print("A page holds at most %d blocks.", S().MAX_BLOCKS)
        return
    end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Add block")
        for _, t in ipairs(BlocksUI.TEMPLATES) do
            root:CreateButton(t.label .. "  " .. grey(t.sub), function()
                local k = t.make()
                k.id = S():NewPartId(self.opts.strat(), "k")
                tinsert(page.k, k)
                self:Changed()
            end)
        end
    end)
end

---------------------------------------------------------------------------
-- Menus (edit mode)
---------------------------------------------------------------------------

local function filterSet(f)
    local set = {}
    for tok in (f or ""):gmatch("[^,]+") do set[tok] = true end
    return set
end

local function filterString(set)
    local out = {}
    for _, r in ipairs(S().ROLES) do if set[r] then out[#out + 1] = r end end
    for _, c in ipairs(ns.CLASSES) do if set[c] then out[#out + 1] = c end end
    return #out > 0 and table.concat(out, ",") or nil
end

function Panel:ColumnMenu(root, page, k, ci)
    local col = k.c[ci]
    root:CreateButton("Header...", function()
        self.opts.prompt("Column header", col.n or "", function(text)
            text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_HEADER)
            col.n = text ~= "" and text or nil
            self:Changed()
        end)
    end)
    if col.t == "p" then
        local fm = root:CreateButton("Who fits (" .. S():FilterText(col.f) .. ")")
        fm:CreateTitle("Roles")
        for _, r in ipairs(S().ROLES) do
            fm:CreateCheckbox(MapUI():IconString("role:" .. r, 12) .. " " .. MapUI().ROLE_NAME[r],
                function() return filterSet(col.f)[r] == true end,
                function()
                    local set = filterSet(col.f)
                    set[r] = not set[r] or nil
                    col.f = filterString(set)
                    self:Changed()
                end)
        end
        fm:CreateTitle("Classes")
        for _, c in ipairs(ns.CLASSES) do
            fm:CreateCheckbox(MapUI():IconString("cls:" .. c, 12) .. " " .. (ns.CLASS_NAMES[c] or c),
                function() return filterSet(col.f)[c] == true end,
                function()
                    local set = filterSet(col.f)
                    set[c] = not set[c] or nil
                    col.f = filterString(set)
                    self:Changed()
                end)
        end
        fm:CreateButton("Anyone", function() col.f = nil; self:Changed() end)
    end
    local ty = root:CreateButton("Type")
    for _, t in ipairs({ "p", "g", "o", "x" }) do
        ty:CreateRadio(COL_TYPE_NAME[t], function() return col.t == t end, function()
            if col.t == t then return end
            col.t = t
            col.f = nil
            -- the cells of the old type don't fit the new one
            for _, cells in pairs(k.d or {}) do cells[ci] = nil end
            self:Changed()
        end)
    end
    if ci > 1 then
        root:CreateButton("Move left", function()
            k.c[ci], k.c[ci - 1] = k.c[ci - 1], k.c[ci]
            for _, cells in pairs(k.d or {}) do cells[ci], cells[ci - 1] = cells[ci - 1], cells[ci] end
            self:Remap(k, function(r, c)
                if c == ci then return r, ci - 1 elseif c == ci - 1 then return r, ci end
                return r, c
            end)
            self:Changed()
        end)
    end
    if #k.c > 1 then
        root:CreateButton("|cffff6060Delete column|r", function()
            tremove(k.c, ci)
            for row, cells in pairs(k.d or {}) do
                local n = {}
                for c, v in pairs(cells) do
                    if c < ci then n[c] = v elseif c > ci then n[c - 1] = v end
                end
                k.d[row] = n
            end
            self:Remap(k, function(r, c)
                if c == ci then return nil end
                return r, c > ci and c - 1 or c
            end)
            self:Changed()
        end)
    end
end

-- Keeps drawings, name markers and target cells pointing at the same cells after rows / columns moved.
function Panel:Remap(k, fn)
    S():RemapBlockRefs(self.opts.strat(), k.id, function(r, c)
        if r == nil then
            local _, nc = fn(1, c)
            return nil, nc
        end
        return fn(r, c)
    end)
end

-- The backup rows of an interrupt rotation (block.bk) follow their rows: fn(row) -> new row or nil.
local function RemapBackups(k, fn)
    if not k.bk then return end
    local out = {}
    for _, row in ipairs(k.bk) do
        local n = fn(row)
        if n then out[#out + 1] = n end
    end
    table.sort(out)
    k.bk = #out > 0 and out or nil
end

local function IsBackup(k, row)
    for _, r in ipairs(k.bk or {}) do
        if r == row then return true end
    end
    return false
end
BlocksUI.IsBackup = IsBackup

-- Row operations (edit mode): insert before / after, move, delete.
function Panel:InsertRow(k, at)
    if k.r >= S().MAX_ROWS then
        ns:Print("A block holds at most %d rows.", S().MAX_ROWS)
        return
    end
    local d = {}
    for row, cells in pairs(k.d or {}) do d[row >= at and row + 1 or row] = cells end
    k.d = next(d) and d or nil
    k.r = k.r + 1
    self:Remap(k, function(r, c) return r >= at and r + 1 or r, c end)
    RemapBackups(k, function(r) return r >= at and r + 1 or r end)
    self:Changed()
end

function Panel:DeleteRow(k, row)
    if k.r <= 1 then return end
    local d = {}
    for r, cells in pairs(k.d or {}) do
        if r < row then d[r] = cells elseif r > row then d[r - 1] = cells end
    end
    k.d = next(d) and d or nil
    k.r = k.r - 1
    self:Remap(k, function(r, c)
        if r == row then return nil end
        return r > row and r - 1 or r, c
    end)
    RemapBackups(k, function(r)
        if r == row then return nil end
        return r > row and r - 1 or r
    end)
    self:Changed()
end

function Panel:SwapRows(k, a, b)
    if a < 1 or b < 1 or a > k.r or b > k.r then return end
    if k.d then k.d[a], k.d[b] = k.d[b], k.d[a] end
    self:Remap(k, function(r, c)
        if r == a then return b, c elseif r == b then return a, c end
        return r, c
    end)
    RemapBackups(k, function(r)
        if r == a then return b elseif r == b then return a end
        return r
    end)
    self:Changed()
end

function Panel:RowMenu(owner, k, row)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(k.n .. " · row " .. row)
        if S().TrackKind(k) == "rot" then
            -- a backup kicker only kicks when no designated kicker will be ready for the boss' next cast
            root:CreateCheckbox("Backup kicker", function() return IsBackup(k, row) end, function()
                if IsBackup(k, row) then
                    RemapBackups(k, function(r) return r ~= row and r or nil end)
                else
                    k.bk = k.bk or {}
                    k.bk[#k.bk + 1] = row
                    table.sort(k.bk)
                end
                self:Changed()
            end)
        end
        root:CreateButton("Insert a row above", function() self:InsertRow(k, row) end)
        root:CreateButton("Insert a row below", function() self:InsertRow(k, row + 1) end)
        if row > 1 then root:CreateButton("Move up", function() self:SwapRows(k, row, row - 1) end) end
        if row < k.r then root:CreateButton("Move down", function() self:SwapRows(k, row, row + 1) end) end
        if k.r > 1 then root:CreateButton("|cffff6060Delete row|r", function() self:DeleteRow(k, row) end) end
    end)
end

function Panel:AddColumn(k, t)
    if #k.c >= S().MAX_COLS then
        ns:Print("A block holds at most %d columns.", S().MAX_COLS)
        return
    end
    tinsert(k.c, { t = t, n = t == "p" and "Player" or (t == "g" and "Target" or nil) })
    self:Changed()
end

-- Puts a copy of block k on page p (at position at, else last): same title, columns, rows and cells, a new id, so
-- its slots are filled on their own. A duplicate on the same page gets "(copy)" in its title.
function Panel:CopyBlock(k, p, at, quiet)
    if #p.k >= S().MAX_BLOCKS then
        ns:Print("Page %s already holds %d blocks.", p.n or "?", S().MAX_BLOCKS)
        return
    end
    local c = S():CopyBlock(self.opts.strat(), k)
    if not c then return end
    if at then
        c.n = (k.n .. " (copy)"):sub(1, S().MAX_NAME_LEN)
        tinsert(p.k, at, c)
    else
        tinsert(p.k, c)
    end
    if not quiet then self:Changed() end
end

function Panel:BlockMenu(owner, page, k, index)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(k.n)
        root:CreateButton("Rename...", function()
            self.opts.prompt("Block title", k.n, function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
                if text ~= "" then k.n = text; self:Changed() end
            end)
        end)
        local ic = root:CreateButton("Icon")
        ic:CreateRadio("None", function() return k.i == nil end, function() k.i = nil; self:Changed() end)
        MapUI():BuildIconMenu(ic, k.i, function(key) k.i = key; self:Changed() end, self.opts.prompt,
            self.opts.strat() and self.opts.strat().b)
        local col = root:CreateButton("Colour")
        col:CreateRadio("Default (dark red)", function() return k.cl == nil end, function() k.cl = nil; self:Changed() end)
        for i, c in ipairs(MapUI().COLORS) do
            col:CreateRadio(MapUI():Swatch(i) .. " " .. c[4], function() return k.cl == i end,
                function() k.cl = i; self:Changed() end)
        end
        -- what the encounter helpers follow for this table (Core/StrategyLive.lua)
        local Live = ns.StrategyLive
        if Live then
            local eff = S().TrackKind(k)
            local trm = root:CreateButton("Track in fight" .. (eff and (": " .. Live.KIND_NAME[eff]) or ""))
            trm:CreateRadio("Not tracked", function() return S().TrackKind(k) == nil end,
                function() k.tr = nil; self:Changed() end)
            for _, kind in ipairs(Live.KIND_ORDER) do
                trm:CreateRadio(Live.KIND_NAME[kind], function() return S().TrackKind(k) == kind end,
                    function() k.tr = kind; self:Changed() end)
            end
        end
        local rows = root:CreateButton("Rows (" .. k.r .. ")")
        rows:CreateButton("Add a row", function() self:InsertRow(k, k.r + 1) end)
        if k.r > 1 then rows:CreateButton("Remove the last row", function() self:DeleteRow(k, k.r) end) end
        if #k.c < S().MAX_COLS then
            local add = root:CreateButton("Add column")
            for _, t in ipairs({ "p", "g", "o", "x" }) do
                add:CreateButton(COL_TYPE_NAME[t], function() self:AddColumn(k, t) end)
            end
        end
        for ci, c in ipairs(k.c) do
            local sub = root:CreateButton(("Column %d: %s"):format(ci, c.n or COL_TYPE_NAME[c.t]))
            self:ColumnMenu(sub, page, k, ci)
        end
        root:CreateDivider()
        if index > 1 then
            root:CreateButton("Move up", function()
                page.k[index], page.k[index - 1] = page.k[index - 1], page.k[index]
                self:Changed()
            end)
        end
        if index < #page.k then
            root:CreateButton("Move down", function()
                page.k[index], page.k[index + 1] = page.k[index + 1], page.k[index]
                self:Changed()
            end)
        end
        root:CreateButton("Duplicate", function() self:CopyBlock(k, page, index + 1) end)
        local strat = self.opts.strat()
        if strat and #strat.p > 1 then
            local to = root:CreateButton("Copy to page")
            for pi, p in ipairs(strat.p) do
                if p ~= page then
                    to:CreateButton(("%d. %s"):format(pi, p.n or ""), function() self:CopyBlock(k, p) end)
                end
            end
            to:CreateButton("All other pages", function()
                for _, p in ipairs(strat.p) do
                    if p ~= page then self:CopyBlock(k, p, nil, true) end
                end
                self:Changed()
            end)
        end
        root:CreateButton("|cffff6060Delete block|r", function()
            tremove(page.k, index)
            self:Changed()
        end)
    end)
end

local function setCell(k, row, ci, v)
    k.d = k.d or {}
    k.d[row] = k.d[row] or {}
    k.d[row][ci] = v
    if not next(k.d[row]) then k.d[row] = nil end
end

-- Editing: who fits one player slot (overrides the column's rule).
function Panel:SlotFilterMenu(owner, k, row, ci)
    local col = k.c[ci]
    local cur = k.d and k.d[row] and k.d[row][ci]
    local own = type(cur) == "table" and cur.f or nil
    local function set(f)
        setCell(k, row, ci, f and { f = f } or nil)
        self:Changed()
    end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Who fits this slot")
        root:CreateRadio("Same as the column (" .. S():FilterText(col.f) .. ")", function() return own == nil end,
            function() set(nil) end)
        local function toggle(tok)
            local set0 = filterSet(own or col.f)
            set0[tok] = not set0[tok] or nil
            set(filterString(set0))
        end
        root:CreateTitle("Roles")
        for _, r in ipairs(S().ROLES) do
            root:CreateCheckbox(MapUI():IconString("role:" .. r, 12) .. " " .. MapUI().ROLE_NAME[r],
                function() return own ~= nil and filterSet(own)[r] == true end, function() toggle(r) end)
        end
        root:CreateTitle("Classes")
        for _, c in ipairs(ns.CLASSES) do
            root:CreateCheckbox(MapUI():IconString("cls:" .. c, 12) .. " " .. (ns.CLASS_NAMES[c] or c),
                function() return own ~= nil and filterSet(own)[c] == true end, function() toggle(c) end)
        end
    end)
end

function Panel:CellMenu(owner, k, row, ci)
    local col = k.c[ci]
    local cell = k.d and k.d[row] and k.d[row][ci]
    if col.t == "x" then
        self.opts.prompt("Text", cell or "", function(text)
            text = S().TidyText(text, S().MAX_TEXT)
            setCell(k, row, ci, text ~= "" and text or nil)
            self:Changed()
        end, true, S().MAX_TEXT)
        return
    end
    if col.t ~= "g" then return end
    local cur = type(cell) == "table" and cell or {}
    local function put(v)
        local n = {}
        for key, val in pairs(cur) do n[key] = val end
        for key, val in pairs(v) do
            if val == false then n[key] = nil else n[key] = val end
        end
        setCell(k, row, ci, next(n) and n or nil)
        self:Changed()
    end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Target")
        root:CreateButton("Label...", function()
            self.opts.prompt("Label (e.g. a boss or a player's job)", cur.l or "", function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_CELL)
                put({ l = text ~= "" and text or false })
            end)
        end)
        local ic = root:CreateButton("Icon")
        ic:CreateRadio("None", function() return cur.i == nil end, function() put({ i = false }) end)
        MapUI():BuildIconMenu(ic, cur.i, function(key) put({ i = key }) end, self.opts.prompt,
            self.opts.strat() and self.opts.strat().b)
        -- the boss' abilities this row is about (interrupt tables: which casts to kick) and when the row applies
        local strat = self.opts.strat()
        local known = strat and ns.Data and ns.Data.BossAbilities and ns.Data.BossAbilities[strat.b]
        local chosen = {}
        for _, id in ipairs(cur.a or {}) do chosen[id] = true end
        local function setAbilities(set)
            local list = {}
            for id in pairs(set) do list[#list + 1] = id end
            table.sort(list)
            if #list > 0 and not k.tr then k.tr = "rot" end
            put({ a = #list > 0 and list or false })
        end
        -- a curse table: which curse this row keeps up (by spell id, so the combat log can check it)
        -- a table tracked as curses, or named / columned for warlocks, offers the curse picker; picking tracks it
        local isCurse = S().TrackKind(k) == "curse"
        if not k.tr and not isCurse then
            isCurse = (k.n or ""):lower():find("curse", 1, true) ~= nil
            for _, c in ipairs(k.c) do
                if c.t == "p" and c.f == "WARLOCK" then isCurse = true end
            end
        end
        if isCurse then
            local function putCurse(id)
                if not k.tr then k.tr = "curse" end
                put({ a = { id } })
            end
            local curses = {}
            for id in pairs(ns.StrategyLive and ns.StrategyLive.SPELLS.curse or {}) do curses[#curses + 1] = id end
            table.sort(curses, function(x, y) return (GetSpellInfo(x) or "") < (GetSpellInfo(y) or "") end)
            local pickedId = cur.a and cur.a[1]
            local cm = root:CreateButton("Curse" .. (pickedId and (": " .. (GetSpellInfo(pickedId) or pickedId)) or ""))
            for _, id in ipairs(curses) do
                cm:CreateRadio(MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id)),
                    function() return pickedId == id end, function() putCurse(id) end)
            end
            cm:CreateButton("By spell ID...", function()
                self.opts.prompt("Spell ID of the curse", "", function(text)
                    local id = tonumber(text)
                    if id and id > 0 and id < 10000000 then putCurse(floor(id)) end
                end)
            end)
            cm:CreateButton("None", function() put({ a = false }) end)
        end
        if not isCurse then
            local ab = root:CreateButton("Abilities" .. (cur.a and (" (" .. #cur.a .. ")") or ""))
            local listed = {}
            for _, c in ipairs(known and known.c or {}) do
                listed[c.id] = true
                local name = GetSpellInfo(c.id) or ("Spell " .. c.id)
                local extra = (c.int and " |cff33ff99(interrupt)|r" or "") .. (c.cd and grey("  ~" .. c.cd .. " s") or "")
                ab:CreateCheckbox(MapUI():IconString("sp:" .. c.id, 14) .. " " .. name .. extra,
                    function() return chosen[c.id] == true end,
                    function()
                        chosen[c.id] = not chosen[c.id] or nil
                        setAbilities(chosen)
                    end)
            end
            -- abilities added by id (not in the boss' list)
            for id in pairs(chosen) do
                if not listed[id] then
                    ab:CreateCheckbox(MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id)),
                        function() return chosen[id] == true end,
                        function()
                            chosen[id] = nil
                            setAbilities(chosen)
                        end)
                end
            end
            if not known then ab:CreateTitle(grey("No ability list for this boss")) end
            ab:CreateButton("By spell ID...", function()
                self.opts.prompt("Spell ID of the ability (e.g. 41472 for Divine Wrath)", "", function(text)
                    local id = tonumber(text)
                    if id and id > 0 and id < 10000000 then
                        chosen[floor(id)] = true
                        setAbilities(chosen)
                    end
                end)
            end)
            local Live = ns.StrategyLive
            local cond = Live and Live.ParseCond(cur.w)
            local wm = root:CreateButton("Only when" .. (cond and (": " .. Live:CondShort(cond)) or ""))
            wm:CreateRadio("Any time", function() return cur.w == nil end, function() put({ w = false }) end)
            local auras = wm:CreateButton("The boss has...")
            local any = false
            for _, id in ipairs(known and known.a or {}) do
                any = true
                auras:CreateRadio(MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id)),
                    function() return cur.w == ("a:" .. id) end, function() put({ w = "a:" .. id }) end)
            end
            if not any then auras:CreateTitle(grey("No buffs listed for this boss")) end
            auras:CreateButton("By spell ID...", function()
                self.opts.prompt("Spell ID of the buff on the boss (e.g. 41450 Blessing of Protection)", "", function(text)
                    local id = tonumber(text)
                    if id and id > 0 and id < 10000000 then put({ w = "a:" .. floor(id) }) end
                end)
            end)
            wm:CreateButton("Below health...", function()
                self.opts.prompt("Health % of the boss (1-99), e.g. 30", "", function(text)
                    local v = tonumber(text)
                    if v and v >= 1 and v <= 99 then put({ w = "hp:" .. floor(v) }) end
                end)
            end)
        end
        local shown = cur.s and self.opts.slotLabel and self.opts.slotLabel(cur.s)
        local sl = root:CreateButton("Show a slot's player" .. (shown and (": " .. grey(shown)) or ""))
        sl:CreateRadio("None", function() return cur.s == nil end, function() put({ s = false }) end)
        local tables, byBlock = {}, {}
        for _, s in ipairs(S():GetSlots(self.opts.strat())) do
            if not byBlock[s.block] then
                byBlock[s.block] = {}
                tables[#tables + 1] = s
            end
            local list = byBlock[s.block]
            list[#list + 1] = s
        end
        for _, first in ipairs(tables) do
            local list = byBlock[first.block]
            local has = false
            for _, s in ipairs(list) do
                if s.ref == cur.s then has = true end
            end
            local sub = sl:CreateButton((has and "|cffffd100" or "") .. (first.blockName or first.block)
                .. (has and "|r" or ""))
            local prefix = (first.blockName or "") .. " · "
            for _, s in ipairs(list) do
                local label = s.label
                if label:sub(1, #prefix) == prefix then label = label:sub(#prefix + 1) end
                sub:CreateRadio(label, function() return cur.s == s.ref end, function() put({ s = s.ref }) end)
            end
        end
        root:CreateButton("|cffff6060Clear|r", function()
            setCell(k, row, ci, nil)
            self:Changed()
        end)
    end)
end

---------------------------------------------------------------------------
-- Fill (raid leaders)
---------------------------------------------------------------------------

function Panel:SlotMenu(owner, ref, filter)
    local members = self.opts.members() or {}
    local cur = self.opts.assigned(ref)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(S():FilterText(filter))
        local fits, others = {}, {}
        for _, m in ipairs(members) do
            if S():MatchFilter(filter, m.c, m.sp) then fits[#fits + 1] = m else others[#others + 1] = m end
        end
        local function add(parent, m)
            local label = UI():ColoredName(m.key, m.c)
            local n = self.opts.countOf and self.opts.countOf(m.key) or 0
            if n > 0 then label = label .. grey("  (" .. n .. ")") end
            parent:CreateRadio(label, function() return cur == m.key end, function() self.opts.onAssign(ref, m.key) end)
        end
        for _, m in ipairs(fits) do add(root, m) end
        if #fits == 0 then root:CreateTitle(grey("Nobody in this raid fits")) end
        if #others > 0 then
            local sub = root:CreateButton("Others")
            for _, m in ipairs(others) do add(sub, m) end
        end
        if cur then
            root:CreateDivider()
            root:CreateButton("|cffff6060Clear|r", function() self.opts.onAssign(ref, nil) end)
        end
    end)
end

-- What a drawing dragged onto the tables links to: a player slot, a column (its header) or a block (its title bar).
-- Over a Target cell: nil, { k = block, row, col } (the board fills the cell from the drawing).
function Panel:RefUnderCursor()
    for _, b in ipairs(self.blocks) do
        if b:IsShown() then
            for _, cell in ipairs(b.cells) do
                if cell:IsShown() and cell:IsMouseOver() then
                    if cell.targetInfo then return nil, cell.targetInfo end
                    if cell.slotRef then return cell.slotRef end
                    if cell.headRef then return cell.headRef end
                    if cell.blockId then return cell.blockId end
                end
            end
            if b.title:IsMouseOver() and b.blockId then return b.blockId end
        end
    end
    return nil
end

-- The slot button under the cursor (drag and drop), or nil.
function Panel:SlotUnderCursor()
    for _, b in ipairs(self.blocks) do
        if b:IsShown() then
            for _, cell in ipairs(b.cells) do
                if cell:IsShown() and cell.slotRef and cell:IsMouseOver() then return cell.slotRef end
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function cellTooltip(cell)
    local self = cell.panel
    if not self then return end
    if cell.hoverRef and self.opts.onHover then self.opts.onHover(cell.hoverRef) end
    local lines = cell.tip
    if not lines then return end
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    for i, l in ipairs(lines) do
        if i == 1 then GameTooltip:AddLine(l) else GameTooltip:AddLine(l, 0.85, 0.85, 0.85, true) end
    end
    GameTooltip:Show()
end

local function cellLeave(cell)
    GameTooltip:Hide()
    if cell.panel and cell.panel.opts.onHover then cell.panel.opts.onHover(nil) end
end

local function newCell(parent, panel)
    local c = CreateFrame("Button", nil, parent)
    c.panel = panel
    c:SetHeight(ROW_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.lit = c:CreateTexture(nil, "BORDER")
    c.lit:SetAllPoints()
    c.lit:SetColorTexture(1, 0.85, 0.1, 0.25)
    c.lit:Hide()
    local hl = c:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(14, 14)
    c.icon:SetPoint("LEFT", 3, 0)
    c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.fs:SetJustifyH("LEFT")
    c.fs:SetWordWrap(false)
    -- a target cell's link to a slot: a pill at the right edge, never cut off (the label gives way instead)
    c.pill = CreateFrame("Frame", nil, c)
    c.pill:SetHeight(ROW_H - 4)
    c.pill:SetPoint("RIGHT", -2, 0)
    c.pill.bg = c.pill:CreateTexture(nil, "BACKGROUND")
    c.pill.bg:SetAllPoints()
    c.pill.bg:SetColorTexture(0.2, 0.2, 0.24, 0.95)
    c.pill.fs = c.pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.pill.fs:SetPoint("CENTER")
    c.pill:Hide()
    function c:SetPill(text)
        if not text then
            self.pill:Hide()
            self.fs:SetPoint("RIGHT", -2, 0)
            return
        end
        self.pill.fs:SetText(text)
        self.pill:SetWidth((self.pill.fs:GetStringWidth() or 20) + 10)
        self.pill:Show()
        self.fs:SetPoint("RIGHT", self.pill, "LEFT", -4, 0)
    end
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c:SetScript("OnEnter", cellTooltip)
    c:SetScript("OnLeave", cellLeave)
    c:SetScript("OnClick", function(self, button)
        -- editing: right-click a row for insert / move / delete
        if button == "RightButton" and self.rowMenu then return self.rowMenu(self) end
        if self.onClick then self.onClick(self, button) end
    end)
    -- editing: drag a player cell onto the map to show that player there
    c:RegisterForDrag("LeftButton")
    c:SetScript("OnDragStart", function(self)
        local p = self.panel
        if not (p and p:Mode() == "edit" and self.slotRef) then return end
        p.dragRef = self.slotRef
        if p.opts.onCellDragStart then p.opts.onCellDragStart(self.slotRef) end
    end)
    c:SetScript("OnDragStop", function(self)
        local p = self.panel
        local ref = p and p.dragRef
        if not ref then return end
        p.dragRef = nil
        if p.opts.onCellDrop then p.opts.onCellDrop(ref) end
    end)
    return c
end

local function newBlock(parent, panel)
    local b = CreateFrame("Frame", nil, parent)
    b.title = CreateFrame("Button", nil, b)
    b.title:SetHeight(TITLE_H)
    b.title:SetPoint("TOPLEFT")
    b.title:SetPoint("TOPRIGHT")
    -- a dark title bar with the block's colour as a strip on the left
    b.title.bg = b.title:CreateTexture(nil, "BACKGROUND")
    b.title.bg:SetAllPoints()
    b.title.bg:SetColorTexture(0.14, 0.14, 0.16, 0.97)
    b.title.accent = b.title:CreateTexture(nil, "BORDER")
    b.title.accent:SetPoint("TOPLEFT")
    b.title.accent:SetPoint("BOTTOMLEFT")
    b.title.accent:SetWidth(3)
    local hl = b.title:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.04)
    b.title.icon = b.title:CreateTexture(nil, "ARTWORK")
    b.title.icon:SetSize(16, 16)
    b.title.icon:SetPoint("LEFT", 8, 0)
    b.title.fs = b.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.title.fs:SetJustifyH("LEFT")
    b.title.fs:SetTextColor(1, 1, 1)
    b.title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.gear = CreateFrame("Button", nil, b.title)
    b.gear:SetSize(14, 14)
    b.gear:SetPoint("RIGHT", -5, 0)
    b.gear.tex = b.gear:CreateTexture(nil, "ARTWORK")
    b.gear.tex:SetAllPoints()
    b.gear.tex:SetTexture(UI().ICON_ATLAS)
    b.gear.tex:SetTexCoord(unpack(UI():IconCoords(13)))
    b.gear.tex:SetVertexColor(0.6, 0.6, 0.6)
    b.gear:SetScript("OnEnter", function(self) self.tex:SetVertexColor(1, 0.82, 0) end)
    b.gear:SetScript("OnLeave", function(self) self.tex:SetVertexColor(0.6, 0.6, 0.6) end)
    b.cells = {}
    b.heads = {}
    b.body = b:CreateTexture(nil, "BACKGROUND")
    b.body:SetPoint("TOPLEFT", 0, -TITLE_H)
    b.body:SetPoint("BOTTOMRIGHT")
    b.body:SetColorTexture(0.05, 0.05, 0.06, 0.9)
    return b
end

-- Widths of a block's columns for the panel width.
local function colWidths(k, width)
    local fixed, weight = 0, 0
    for _, c in ipairs(k.c) do
        if c.t == "o" then fixed = fixed + ORDER_W else weight = weight + (COL_WEIGHT[c.t] or 2) end
    end
    local per = weight > 0 and (width - fixed) / weight or 0
    local out, sum = {}, 0
    for i, c in ipairs(k.c) do
        out[i] = c.t == "o" and ORDER_W or floor(per * (COL_WEIGHT[c.t] or 2))
        sum = sum + out[i]
    end
    -- the rounding remainder goes to the last column so the table reaches its right edge
    if #out > 0 then out[#out] = out[#out] + (width - sum) end
    return out
end

-- A slot reference in short, seen from block k: "#2" in the same block, "Tanks #2" from another; the column's name
-- follows when that block has several player columns.
function Panel:ShortSlot(ref, k, page)
    local b, row, col = S().SplitSlot(ref)
    if not b then return tostring(ref) end
    local kb = (k and k.id == b) and k or S():FindBlock(self.opts.strat(), b)
    local text = "#" .. row
    if kb then
        local pcols = 0
        for _, c in ipairs(kb.c) do if c.t == "p" then pcols = pcols + 1 end end
        if pcols > 1 and kb.c[col] then text = text .. " " .. (kb.c[col].n or ("col " .. col)) end
        if kb ~= k then text = kb.n .. " " .. text end
    end
    return text
end

-- The text of a player slot.
function Panel:SlotText(ref, col)
    local mode = self:Mode()
    if mode == "edit" then return grey("(" .. S():FilterText(col.f) .. ")"), nil end
    local key = self.opts.assigned(ref)
    if not key then return mode == "fill" and grey("-  " .. S():FilterText(col.f)) or grey("-"), nil end
    local info = self.opts.memberInfo(key) or {}
    local name = UI():ColoredName(key, info.c)
    if info.missing then name = "|cffff5050" .. ns.Util.ShortName(key) .. "|r" end
    return name, info
end

function Panel:Render()
    local page = self.opts.page()
    local mode = self:Mode()
    local width = self:Width() - 22
    local y = 0
    local child = self.child
    child:SetWidth(width)
    for _, b in ipairs(self.blocks) do b:Hide() end
    if not page then
        child:SetHeight(10)
        return
    end
    self.cellByRef = {}
    for index, k in ipairs(page.k or {}) do
        local b = self.blocks[index]
        if not b then
            b = newBlock(child, self)
            self.blocks[index] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        b:SetWidth(width)
        -- title bar
        local r, g, bl = 1, 0.82, 0
        if k.cl then r, g, bl = MapUI():Color(k.cl) end
        b.title.accent:SetColorTexture(r, g, bl, 1)
        b.title.fs:ClearAllPoints()
        if k.i then
            MapUI():SetIcon(b.title.icon, k.i)
            b.title.icon:Show()
            b.title.fs:SetPoint("LEFT", b.title.icon, "RIGHT", 5, 0)
        else
            b.title.icon:Hide()
            b.title.fs:SetPoint("LEFT", 10, 0)
        end
        b.title.fs:SetPoint("RIGHT", -22, 0)
        local trackName = S().TrackKind(k) and ns.StrategyLive and ns.StrategyLive.KIND_NAME[S().TrackKind(k)]
        b.title.fs:SetText(k.n .. (trackName and ("  |cffb0ffb0(tracked: " .. trackName .. ")|r") or ""))
        b.gear:SetShown(mode == "edit")
        b.gear:SetScript("OnClick", function(btn) self:BlockMenu(btn, page, k, index) end)
        b.title:SetScript("OnClick", function(btn, button)
            if mode == "edit" then self:BlockMenu(btn, page, k, index) end
        end)
        b.title:SetScript("OnEnter", function()
            if self.opts.onHover then self.opts.onHover(k.id) end
        end)
        b.title:SetScript("OnLeave", function()
            if self.opts.onHover then self.opts.onHover(nil) end
        end)
        local by = TITLE_H
        b.blockId = k.id
        -- column headers
        local widths = colWidths(k, width)
        local hasHead = mode == "edit"
        for _, c in ipairs(k.c) do if c.n then hasHead = true end end
        for _, h in ipairs(b.heads) do h:Hide() end
        local used = 0
        local function cell(x, cy, w, last)
            used = used + 1
            local c = b.cells[used]
            if not c then
                c = newCell(b, self)
                b.cells[used] = c
            end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", b, "TOPLEFT", x, -cy)
            -- a 1px gap between columns, none after the last
            c:SetSize(max(1, last and w or w - 1), ROW_H)
            c.bg:SetColorTexture(0.10, 0.10, 0.11, 0.9)
            c.icon:Hide()
            c.fs:ClearAllPoints()
            c.fs:SetPoint("LEFT", 4, 0)
            c.fs:SetPoint("RIGHT", -2, 0)
            c.fs:SetWordWrap(false)
            c.lit:Hide()
            c:SetPill(nil)
            c.slotRef, c.hoverRef, c.tip, c.onClick, c.rowMenu, c.headRef, c.blockId = nil, nil, nil, nil, nil, nil, nil
            c.targetInfo = nil
            c:Show()
            return c
        end
        if hasHead then
            local x = 0
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci], ci == #k.c)
                c:SetHeight(HEAD_H)
                c.bg:SetColorTexture(0.08, 0.08, 0.09, 0.95)
                c.fs:SetText("|cffffd100" .. (col.n or (mode == "edit" and grey(COL_TYPE_NAME[col.t]) or "")) .. "|r")
                c.hoverRef = k.id .. "." .. ci
                c.headRef = c.hoverRef
                if mode == "edit" then
                    c.tip = { COL_TYPE_NAME[col.t], "Click to change this column. Drop a drawing here to link it to the column." }
                    c.onClick = function(btn)
                        UI():ContextMenu(btn, function(root)
                            root:CreateTitle(col.n or COL_TYPE_NAME[col.t])
                            self:ColumnMenu(root, page, k, ci)
                        end)
                    end
                end
                self.cellByRef[c.hoverRef] = self.cellByRef[c.hoverRef] or {}
                tinsert(self.cellByRef[c.hoverRef], c)
                x = x + widths[ci]
            end
            by = by + HEAD_H
        end
        for row = 1, k.r do
            local x = 0
            local rowH, rowFirst = ROW_H, used + 1
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci], ci == #k.c)
                local v = k.d and k.d[row] and k.d[row][ci]
                -- striped rows
                if row % 2 == 0 then c.bg:SetColorTexture(0.13, 0.13, 0.14, 0.9) end
                if mode == "edit" then c.rowMenu = function(btn) self:RowMenu(btn, k, row) end end
                if col.t == "o" then
                    if S().TrackKind(k) == "rot" and IsBackup(k, row) then
                        c.fs:SetText("|cffb08cffB|r")
                        c.tip = { "Backup kicker", "Kicks only when no designated kicker's interrupt will be ready for the "
                            .. "boss' next cast." .. (mode == "edit" and " Right-click the row to change." or "") }
                    else
                        c.fs:SetText(grey(row))
                    end
                elseif col.t == "x" then
                    -- a long text wraps: the row grows with it
                    c.fs:ClearAllPoints()
                    c.fs:SetPoint("LEFT", 4, 0)
                    c.fs:SetWidth(max(10, widths[ci] - 8))
                    c.fs:SetWordWrap(true)
                    c.fs:SetText(v or (mode == "edit" and grey("click to type") or ""))
                    rowH = max(rowH, ceil(c.fs:GetStringHeight() or 0) + 8)
                    if mode == "edit" then c.onClick = function(btn) self:CellMenu(btn, k, row, ci) end end
                elseif col.t == "g" then
                    local text = v and v.l or ""
                    local linkTip
                    if v and v.s then
                        local name = self.opts.slotName and self.opts.slotName(v.s)
                        local slotLabel = self.opts.slotLabel and self.opts.slotLabel(v.s) or v.s
                        if mode == "edit" or not name then
                            -- the slot in short: "-> #2" in this block, "-> Tanks #2" from another one
                            c:SetPill(grey("-> ") .. self:ShortSlot(v.s, k, page))
                            linkTip = "Shows the player of " .. slotLabel ..
                                (mode == "edit" and " here. Right-click > Clear removes it." or ".")
                        else
                            c:SetPill(name)
                            linkTip = slotLabel
                        end
                        c.hoverRef = v.s
                    end
                    if v and v.i then
                        MapUI():SetIcon(c.icon, v.i)
                        c.icon:Show()
                        c.fs:ClearAllPoints()
                        c.fs:SetPoint("LEFT", c.icon, "RIGHT", 3, 0)
                        c.fs:SetPoint("RIGHT", -2, 0)
                    end
                    if v and v.a and S().TrackKind(k) == "curse" then
                        -- a curse row: the curse's icon, and its name when there's no label
                        local id = v.a[1]
                        text = MapUI():IconString("sp:" .. id, 13) .. " " .. (text ~= "" and text or (GetSpellInfo(id) or id))
                    elseif v and v.a then
                        local icons = ""
                        for _, id in ipairs(v.a) do icons = icons .. MapUI():IconString("sp:" .. id, 13) end
                        text = (text ~= "" and (text .. " ") or "") .. icons
                    end
                    local cond = v and v.w and ns.StrategyLive and ns.StrategyLive.ParseCond(v.w)
                    if cond then text = text .. " |cffffd100when " .. ns.StrategyLive:CondShort(cond) .. "|r" end
                    if v and (v.a or v.w) then
                        local tip = { "On" }
                        for _, id in ipairs(v.a or {}) do tip[#tip + 1] = MapUI():IconString("sp:" .. id, 13) .. " " .. (GetSpellInfo(id) or id) end
                        if cond then tip[#tip + 1] = "Only when " .. (cond.kind == "hp" and ("the boss is below " .. cond.v .. "%")
                            or ("the boss has " .. (GetSpellInfo(cond.id) or cond.id))) end
                        c.tip = tip
                    end
                    if text == "" and mode == "edit" then
                        text = grey(v and v.s and "drop an icon here" or "click to set, or drop an icon here")
                    end
                    if linkTip then
                        c.tip = c.tip or { text ~= "" and v and v.l or "Target" }
                        c.tip[#c.tip + 1] = linkTip
                    end
                    c.fs:SetText(text)
                    c.targetInfo = { k = k, row = row, col = ci }
                    if mode == "edit" then c.onClick = function(btn) self:CellMenu(btn, k, row, ci) end end
                elseif col.t == "p" then
                    local ref = S().SlotRef(k.id, row, ci)
                    -- the slot's own rule, else the column's
                    local slotCol = { f = (type(v) == "table" and v.f) or col.f }
                    local text, info = self:SlotText(ref, slotCol)
                    c.fs:SetText(text)
                    c.slotRef, c.hoverRef = ref, ref
                    -- player slots: a faint blue cast on the stripe
                    if row % 2 == 0 then c.bg:SetColorTexture(0.13, 0.13, 0.17, 0.95)
                    else c.bg:SetColorTexture(0.10, 0.10, 0.14, 0.95) end
                    local tip = { self.opts.slotLabel and self.opts.slotLabel(ref) or ref, "Fits: " .. S():FilterText(slotCol.f) ..
                        (type(v) == "table" and v.f and "  (this slot only)" or "") }
                    if info and info.missing then tip[#tip + 1] = "|cffff5050Not signed up for this raid / not in the raid.|r" end
                    if self.opts.isDup and self.opts.isDup(ref) then
                        c.bg:SetColorTexture(0.35, 0.18, 0.02, 0.95)
                        tip[#tip + 1] = "|cffff9933This player has another slot in this block.|r"
                    end
                    if mode == "fill" then
                        tip[#tip + 1] = "Click to pick a player (or drag one here). Right-click clears."
                        c.onClick = function(btn, button)
                            local picked = self.opts.picked and self.opts.picked()
                            if button == "RightButton" then self.opts.onAssign(ref, nil)
                            elseif picked then self.opts.onAssign(ref, picked)
                            else self:SlotMenu(btn, ref, slotCol.f) end
                        end
                    elseif mode == "edit" then
                        tip[#tip + 1] = "The raid leader fills this slot per raid. Click to set who fits this slot; drag it onto the map to show the player there; right-click for row options."
                        c.onClick = function(btn) self:SlotFilterMenu(btn, k, row, ci) end
                    end
                    c.tip = tip
                    self.cellByRef[ref] = self.cellByRef[ref] or {}
                    tinsert(self.cellByRef[ref], c)
                end
                x = x + widths[ci]
            end
            if rowH > ROW_H then
                for i = rowFirst, used do b.cells[i]:SetHeight(rowH) end
            end
            by = by + rowH
        end
        for i = used + 1, #b.cells do b.cells[i]:Hide() end
        -- editing: + row / + column under the table
        if mode == "edit" then
            if not b.addRow then
                b.addRow = UI():CreateSleekButton(b, "+ row", 56, 18, function() self:InsertRow(b.cdlK, b.cdlK.r + 1) end)
                b.addRow:GetFontString():SetFontObject("GameFontHighlightSmall")
                b.addCol = UI():CreateSleekMenuButton(b, "+ column", 84, function(root)
                    for _, t in ipairs({ "p", "g", "o", "x" }) do
                        root:CreateButton(COL_TYPE_NAME[t], function() self:AddColumn(b.cdlK, t) end)
                    end
                end, 18)
            end
            b.cdlK = k
            b.addRow:ClearAllPoints()
            b.addRow:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -(by + 3))
            b.addCol:ClearAllPoints()
            b.addCol:SetPoint("LEFT", b.addRow, "RIGHT", 3, 0)
            b.addRow:Show()
            b.addCol:Show()
            by = by + 22
        elseif b.addRow then
            b.addRow:Hide()
            b.addCol:Hide()
        end
        b:SetHeight(by)
        b:Show()
        y = y + by + GAP
    end
    -- page notes
    self.notes:ClearAllPoints()
    self.notes:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
    self.notes:SetWidth(width - 4)
    if page.no then
        self.notes:SetText("|cffffd100Notes|r\n" .. page.no)
        self.notes:Show()
        y = y + (self.notes:GetStringHeight() or 14) + GAP
    else
        self.notes:Hide()
    end
    local editing = mode == "edit"
    local noBlocks = #(page.k or {}) == 0
    local cardsShown = editing and noBlocks
    self.addBtn:SetShown(editing and not noBlocks)
    self.notesBtn:SetShown(editing)
    self.empty:SetShown(not editing and noBlocks and not page.no)
    self.empty:ClearAllPoints()
    self.empty:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
    self.empty:SetWidth(width - 4)
    self.empty:SetText("No assignments on this page.")
    if not editing and noBlocks and not page.no then y = y + 30 end
    if cardsShown then
        y = self:RenderEmpty(page, width, y)
    else
        self.emptyTitle:Hide()
        self.emptyText:Hide()
        self.suggestHead:Hide()
        self.templateHead:Hide()
        for _, c in ipairs(self.cards) do c:Hide() end
    end
    if editing then
        self.notesBtn:ClearAllPoints()
        if cardsShown then
            self.notesBtn:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        else
            self.addBtn:ClearAllPoints()
            self.addBtn:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            self.notesBtn:SetPoint("LEFT", self.addBtn, "RIGHT", 6, 0)
        end
        y = y + 26
    end
    child:SetHeight(max(10, y))
    self:ApplyHighlight()
end

function Panel:Highlight(ref)
    self.lit = ref
    self:ApplyHighlight()
end

function Panel:ApplyHighlight()
    for _, b in ipairs(self.blocks) do
        for _, c in ipairs(b.cells) do c.lit:Hide() end
    end
    if not self.lit or not self.cellByRef then return end
    for ref, cells in pairs(self.cellByRef) do
        if MapUI():RefsOverlap(self.lit, ref) then
            for _, c in ipairs(cells) do c.lit:Show() end
        end
    end
end

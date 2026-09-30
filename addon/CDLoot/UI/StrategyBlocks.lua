-- CDLoot: UI/StrategyBlocks.lua
-- The assignment blocks of a strategy page (Addendum K): small tables with a coloured title bar, optional column
-- headers and rows of cells. Column types: player slot (p), target (g: icon + label, or another slot's player),
-- order number (o) and text (x).
-- Modes: "edit" (authors shape the blocks: title-bar gear menu, click headers / cells), "fill" (raid leaders put players
-- into the slots: click a slot for the list of players, or drag a player onto it; right-click clears) and "view".
local addonName, ns = ...

local BlocksUI = ns:NewModule("StrategyBlocksUI")

local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove = table.insert, table.remove

local TITLE_H, HEAD_H, ROW_H, GAP = 20, 16, 18, 8
local COL_WEIGHT = { p = 2, g = 2, x = 3 }
local ORDER_W = 20

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
-- multiline); slotName(ref) -> coloured player name or nil.
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
    self.notesBtn = UI():CreateButton(child, "Page notes...", 100, 20, function() self:EditNotes() end)
    self.addBtn = UI():CreateButton(child, "+ Add block", 110, 22, function(btn) self:AddMenu(btn) end)
    self.empty = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    self.empty:SetJustifyH("LEFT")
    return self
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
        page.no = text ~= "" and text:sub(1, 400) or nil
        self:Changed()
    end, true)
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
    self:Changed()
end

function Panel:SwapRows(k, a, b)
    if a < 1 or b < 1 or a > k.r or b > k.r then return end
    if k.d then k.d[a], k.d[b] = k.d[b], k.d[a] end
    self:Remap(k, function(r, c)
        if r == a then return b, c elseif r == b then return a, c end
        return r, c
    end)
    self:Changed()
end

function Panel:RowMenu(owner, k, row)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(k.n .. " · row " .. row)
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
            local trm = root:CreateButton("Track in fight" .. (k.tr and (": " .. Live.KIND_NAME[k.tr]) or ""))
            trm:CreateRadio("Not tracked", function() return k.tr == nil end, function() k.tr = nil; self:Changed() end)
            for _, kind in ipairs(Live.KIND_ORDER) do
                trm:CreateRadio(Live.KIND_NAME[kind], function() return k.tr == kind end,
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
            text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_CELL)
            setCell(k, row, ci, text ~= "" and text or nil)
            self:Changed()
        end)
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
        local sl = root:CreateButton("Show a slot's player")
        sl:CreateRadio("None", function() return cur.s == nil end, function() put({ s = false }) end)
        for _, s in ipairs(S():GetSlots(self.opts.strat())) do
            sl:CreateRadio(s.label, function() return cur.s == s.ref end, function() put({ s = s.ref }) end)
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
    b.title.bg = b.title:CreateTexture(nil, "BACKGROUND")
    b.title.bg:SetAllPoints()
    b.title.icon = b.title:CreateTexture(nil, "ARTWORK")
    b.title.icon:SetSize(16, 16)
    b.title.icon:SetPoint("LEFT", 3, 0)
    b.title.fs = b.title:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.title.fs:SetJustifyH("LEFT")
    b.title.fs:SetTextColor(1, 1, 1)
    b.title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.gear = CreateFrame("Button", nil, b.title)
    b.gear:SetSize(16, 16)
    b.gear:SetPoint("RIGHT", -3, 0)
    b.gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    b.gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    b.cells = {}
    b.heads = {}
    b.body = b:CreateTexture(nil, "BACKGROUND")
    b.body:SetPoint("TOPLEFT", 0, -TITLE_H)
    b.body:SetPoint("BOTTOMRIGHT")
    b.body:SetColorTexture(0.07, 0.07, 0.07, 0.9)
    return b
end

-- Widths of a block's columns for the panel width.
local function colWidths(k, width)
    local fixed, weight = 0, 0
    for _, c in ipairs(k.c) do
        if c.t == "o" then fixed = fixed + ORDER_W else weight = weight + (COL_WEIGHT[c.t] or 2) end
    end
    local per = weight > 0 and (width - fixed) / weight or 0
    local out = {}
    for i, c in ipairs(k.c) do out[i] = c.t == "o" and ORDER_W or floor(per * (COL_WEIGHT[c.t] or 2)) end
    return out
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
        local r, g, bl = 0.45, 0.05, 0.05
        if k.cl then
            r, g, bl = MapUI():Color(k.cl)
            r, g, bl = r * 0.55, g * 0.55, bl * 0.55
        end
        b.title.bg:SetColorTexture(r, g, bl, 0.95)
        b.title.fs:ClearAllPoints()
        if k.i then
            MapUI():SetIcon(b.title.icon, k.i)
            b.title.icon:Show()
            b.title.fs:SetPoint("LEFT", b.title.icon, "RIGHT", 4, 0)
        else
            b.title.icon:Hide()
            b.title.fs:SetPoint("LEFT", 6, 0)
        end
        b.title.fs:SetPoint("RIGHT", -22, 0)
        local trackName = k.tr and ns.StrategyLive and ns.StrategyLive.KIND_NAME[k.tr]
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
        local function cell(x, cy, w)
            used = used + 1
            local c = b.cells[used]
            if not c then
                c = newCell(b, self)
                b.cells[used] = c
            end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", b, "TOPLEFT", x, -cy)
            c:SetSize(max(1, w - 1), ROW_H)
            c.bg:SetColorTexture(0.12, 0.12, 0.12, 0.9)
            c.icon:Hide()
            c.fs:ClearAllPoints()
            c.fs:SetPoint("LEFT", 4, 0)
            c.fs:SetPoint("RIGHT", -2, 0)
            c.lit:Hide()
            c.slotRef, c.hoverRef, c.tip, c.onClick, c.rowMenu, c.headRef, c.blockId = nil, nil, nil, nil, nil, nil, nil
            c.targetInfo = nil
            c:Show()
            return c
        end
        if hasHead then
            local x = 0
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci])
                c:SetHeight(HEAD_H)
                c.bg:SetColorTexture(0.18, 0.18, 0.18, 0.95)
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
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci])
                local v = k.d and k.d[row] and k.d[row][ci]
                if mode == "edit" then c.rowMenu = function(btn) self:RowMenu(btn, k, row) end end
                if col.t == "o" then
                    c.fs:SetText(grey(row))
                elseif col.t == "x" then
                    c.fs:SetText(v or (mode == "edit" and grey("click to type") or ""))
                    if mode == "edit" then c.onClick = function(btn) self:CellMenu(btn, k, row, ci) end end
                    if v and #v > 18 then c.tip = { v } end
                elseif col.t == "g" then
                    local text = v and v.l or ""
                    if v and v.s then
                        local name = self.opts.slotName and self.opts.slotName(v.s)
                        local slotLabel = self.opts.slotLabel and self.opts.slotLabel(v.s) or v.s
                        if mode == "edit" or not name then
                            text = (text ~= "" and (text .. " ") or "") .. grey("-> " .. slotLabel)
                        else
                            text = (text ~= "" and (text .. " ") or "") .. name
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
                    if text == "" and mode == "edit" then text = grey("click to set, or drop an icon here") end
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
                    c.bg:SetColorTexture(0.10, 0.10, 0.14, 0.95)
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
            by = by + ROW_H
        end
        for i = used + 1, #b.cells do b.cells[i]:Hide() end
        -- editing: + row / + column under the table
        if mode == "edit" then
            if not b.addRow then
                b.addRow = UI():CreateButton(b, "+ row", 56, 16, function() self:InsertRow(b.cdlK, b.cdlK.r + 1) end)
                b.addCol = UI():CreateMenuButton(b, "+ column", 84, function(root)
                    for _, t in ipairs({ "p", "g", "o", "x" }) do
                        root:CreateButton(COL_TYPE_NAME[t], function() self:AddColumn(b.cdlK, t) end)
                    end
                end)
            end
            b.cdlK = k
            b.addRow:ClearAllPoints()
            b.addRow:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -(by + 2))
            b.addCol:ClearAllPoints()
            b.addCol:SetPoint("LEFT", b.addRow, "RIGHT", 4, 0)
            b.addCol:SetHeight(16)
            b.addRow:Show()
            b.addCol:Show()
            by = by + 20
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
    self.addBtn:SetShown(editing)
    self.notesBtn:SetShown(editing)
    self.empty:SetShown(#(page.k or {}) == 0 and not page.no)
    self.empty:ClearAllPoints()
    self.empty:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -y)
    self.empty:SetWidth(width - 4)
    self.empty:SetText(editing and "No blocks on this page yet. Add one: each block is a small table of jobs." or
        "No assignments on this page.")
    if #(page.k or {}) == 0 and not page.no then y = y + 30 end
    if editing then
        self.addBtn:ClearAllPoints()
        self.addBtn:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        self.notesBtn:ClearAllPoints()
        self.notesBtn:SetPoint("LEFT", self.addBtn, "RIGHT", 6, 0)
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

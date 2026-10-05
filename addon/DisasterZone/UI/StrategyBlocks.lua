if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategyBlocks.lua", ...) then return end -- DisasterZone: UI/StrategyBlocks.lua
-- The assignment blocks of a strategy page (Addendum K): small tables with a coloured title bar, optional column
-- headers and rows of cells. Column types: player slot (p), target (g: icon + label, or another slot's player),
-- order number (o) and text (x).
-- Modes: "edit" (authors shape the blocks: title-bar gear menu, click headers / cells), "fill" (raid leaders put players
-- into the slots: click a slot for the list of players, or drag a player onto it; right-click clears) and "view".
local addonName, ns = ...

local BlocksUI = ns:NewModule("StrategyBlocksUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tinsert, tremove = table.insert, table.remove

-- The panel's look (the raid page's flat cards): a block is one card with its title row (the block's colour as a bar
-- on that row only), its column titles in small gold and rows of 22 px over hairlines; GAP between cards.
local TITLE_H, HEAD_H, ROW_H, GAP = 26, 18, 22, 8
local FOOT_H, PAD_B = 22, 6           -- under the rows: + Row / + Column while editing, else a little room
local INSET = 10                      -- the table inside its card
local STRIP_H = 22                    -- a dispel table's line under the title
local COL_WEIGHT = { p = 2, g = 2, x = 3 }
local ORDER_W = 22
local CARD_BG = { 0.10, 0.10, 0.12, 0.92 }
local CARD_EDGE = { 0.34, 0.34, 0.38, 0.35 }
local ADD_BG, ADD_EDGE = { 0.10, 0.10, 0.12, 0.6 }, { 0.34, 0.34, 0.38, 0.45 }
local ADD_BG_HOT, ADD_EDGE_HOT = { 0.18, 0.18, 0.21, 0.85 }, { 1, 0.82, 0, 0.8 }
local SUG_H, TPL_H = 38, 28           -- Add a block: a suggestion from the map, a template

local function S() return ns.Strategy end
local function MapUI() return ns.StrategyMapUI end
local function UI() return ns.UI end

local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end

-- A text in the game's font at a size.
local function newText(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, size, flags) end
    end
    return fs
end

local function setSize(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
end

-- A fill and 1px edges (f.bg, f.edges).
local function cardLook(f, bg, edge)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    UI():AddEdges(f, "BORDER")
    UI():SetEdgeColor(f, edge[1], edge[2], edge[3], edge[4])
end

-- A menu entry: an atlas icon (or the room of one, so the words line up), the words, a value in grey; red: Delete.
local MENU_SPACER = "|TInterface\\Common\\spacer:12:12|t"
local function menuEntry(icon, text, value, red)
    local i = icon and UI():AtlasIconText(icon, 12, red and { 1, 0.55, 0.55 } or nil) or MENU_SPACER
    return i .. "  " .. (red and ("|cffff8a8a" .. text .. "|r") or text) .. (value and ("  |cff8a8a8a" .. value .. "|r") or "")
end

-- The block templates of Add a block: the addon's own glyph (UI.ICON_ATLAS), the name, what it is for (its tooltip).
BlocksUI.TEMPLATES = {
    { label = "Players with targets", icon = 5, sub = "Who takes what: a tank on the boss, a healer on a tank.",
      make = function() return { n = "Assignments", r = 4, c = { { t = "p", n = "Player" }, { t = "g", n = "Target" } } } end },
    { label = "Rotation", icon = 10, sub = "Players taking turns in order: interrupts, misdirects.",
      make = function() return { n = "Rotation", r = 3, c = { { t = "o" }, { t = "p", n = "Player" }, { t = "g", n = "Target" } } } end },
    { label = "Groups / zones", icon = 4, sub = "Players split into columns, a group or a spot each.",
      make = function() return { n = "Zones", r = 5, c = { { t = "p", n = "Zone 1" }, { t = "p", n = "Zone 2" } } } end },
    { label = "Pairs", icon = 6, sub = "From one player to another: Innervate, Power Infusion.",
      make = function() return { n = "Innervates", r = 3, c = { { t = "p", n = "From", f = "DRUID" }, { t = "p", n = "To" } } } end },
    { label = "Single job", icon = 7, sub = "One job with its timing: Bloodlust.",
      make = function() return { n = "Bloodlust", r = 1, c = { { t = "p", n = "Player" }, { t = "x", n = "When" } } } end },
    { label = "Dispels", icon = 22, sub = "Who removes what: curses, magic, poison, enrage.",
      make = function() return { n = "Dispels", r = 3, tr = "dsp", dy = "m", i = "i:Spell_Holy_DispelMagic",
                                 c = { { t = "p", n = "Player", f = S().DispelFilter("m", false) } } } end },
    { label = "Text only", icon = 8, sub = "A table of plain text.",
      make = function() return { n = "Notes", r = 3, c = { { t = "x" } } } end },
}

local COL_TYPE_NAME = { p = "Player slot", g = "Target", o = "Order #", x = "Text" }
BlocksUI.COL_TYPE_NAME = COL_TYPE_NAME

-- What a tracked table follows, in a word (the green tag on its title row, the block menu's Track in fight).
local TRACK_TAG = { rot = "Interrupts", md = "Misdirects", bl = "Bloodlust", pi = "Power Infusion", iv = "Innervate",
                    curse = "Curses", dsp = "Dispels" }
BlocksUI.TRACK_TAG = TRACK_TAG

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local Panel = {}
Panel.__index = Panel

local createNotes

-- opts: mode() -> "edit"|"fill"|"view"; page(); strat(); assigned(ref) -> key; memberInfo(key) -> { c, missing };
-- isDup(ref); isMine(ref); raidBoard() (a raid's board: names, or a dash); onAssign(ref, key|nil); members() ->
-- { {key, c, sp} }; onChange(); onHover(ref|nil); prompt(title, def, cb, multiline, maxLen); slotName(ref) -> coloured
-- player name or nil; dragging() -> the player being dragged.
function BlocksUI:Create(parent, opts)
    local self = setmetatable({}, Panel)
    self.opts = opts
    self.blocks = {}
    local sf = UI():CreateScrollFrame(parent)
    self.scroll = sf
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(10, 10)
    sf:SetScrollChild(child)
    self.child = child
    -- an empty page: one quiet line (editing: what goes here; reading: that nothing does)
    self.empty = newText(child, "GameFontHighlight", 11.5)
    self.empty:SetWordWrap(true)
    self.empty:SetJustifyV("TOP")
    -- Add a block, under the tables while editing: the map's suggestions, then the templates and the page's notes
    self.addHead = newText(child, "GameFontNormal", 10)
    self.addHead:SetText("ADD A BLOCK")
    self.cards = {}
    self.sugCards, self.tplCards = {}, {}
    self.notesCard = createNotes(child, self)
    return self
end

-- A card of Add a block: a suggestion (its picture, a title and a grey line) or a template (a glyph and its name).
local function newAddCard(parent, big)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(big and SUG_H or TPL_H)
    cardLook(c, ADD_BG, ADD_EDGE)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(big and 24 or 14, big and 24 or 14)
    c.icon:SetPoint("LEFT", 10, 0)
    c.title = newText(c, "GameFontHighlight", big and 12 or 11.5)
    if big then
        c.title:SetPoint("TOPLEFT", 43, -6)
        c.sub = newText(c, "GameFontHighlight", 10.5)
        c.sub:SetTextColor(0.62, 0.62, 0.62)
        c.sub:SetPoint("TOPLEFT", c.title, "BOTTOMLEFT", 0, -3)
    else
        c.title:SetPoint("LEFT", 32, 0)
        c.title:SetTextColor(0.9, 0.9, 0.9)
    end
    local function paint(self)
        local bg, edge = self.hovered and ADD_BG_HOT or ADD_BG, self.hovered and ADD_EDGE_HOT or ADD_EDGE
        self.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
        UI():SetEdgeColor(self, edge[1], edge[2], edge[3], edge[4])
    end
    c:SetScript("OnEnter", function(self)
        self.hovered = true
        paint(self)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.tipTitle or "")
            GameTooltip:AddLine(self.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    c:SetScript("OnLeave", function(self)
        self.hovered = false
        paint(self)
        GameTooltip:Hide()
    end)
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", function(self) if self.onPick then self.onPick() end end)
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
            title = isBoss and ("Tanks on " .. g.label) or (g.label .. (n > 1 and ("  |cff9e9e9ex" .. n .. "|r") or "")),
            sub = isBoss and ("One row, linked to " .. (n > 1 and "them" or "it") .. " on the map")
                or (n > 1 and ("One row per " .. g.label:lower() .. ", linked to it on the map")
                or "One row, linked to it on the map"),
            icon = g.icon,
            apply = function()
                -- (the table wears the creature's picture, as on the map)
                local k = { n = (isBoss and "Tanks" or g.label):sub(1, S().MAX_NAME_LEN), r = n, i = g.icon,
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

-- A block from a template onto the page (Add a block's cards; the tutorial).
function Panel:AddTemplate(t, page)
    page = page or self.opts.page()
    if not page then return end
    if #page.k >= S().MAX_BLOCKS then
        ns:Print("A page holds at most %d blocks.", S().MAX_BLOCKS)
        return
    end
    local k = t.make()
    k.id = S():NewPartId(self.opts.strat(), "k")
    tinsert(page.k, k)
    self:Changed()
end

-- Add a block (editing, under the tables): the map's suggestions as cards with their picture, the templates in two
-- columns and the page's notes as the eighth (while the page has none). Returns the height used.
function Panel:RenderAddSection(page, width, y)
    local child = self.child
    self.cards = {}
    local full = #page.k >= S().MAX_BLOCKS
    self.addHead:ClearAllPoints()
    self.addHead:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(y + 4))
    self.addHead:Show()
    y = y + 4 + 18
    local sugg = full and {} or self:Suggestions(page)
    for i, sg in ipairs(sugg) do
        local c = self.sugCards[i]
        if not c then
            c = newAddCard(child, true)
            self.sugCards[i] = c
        end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        c:SetWidth(width)
        MapUI():SetIcon(c.icon, sg.icon)
        c.icon:Show()
        c.title:SetText(sg.title)
        c.sub:SetText(sg.sub)
        c.onPick = sg.apply
        c.tip, c.tipTitle = nil, nil
        c:Show()
        self.cards[#self.cards + 1] = c
        y = y + SUG_H + 6
    end
    for i = #sugg + 1, #self.sugCards do self.sugCards[i]:Hide() end
    if #sugg > 0 then y = y + 4 end
    local cells = {}
    if not full then
        for _, t in ipairs(BlocksUI.TEMPLATES) do cells[#cells + 1] = { t.icon, t.label, t.sub, function() self:AddTemplate(t, page) end } end
    end
    if not page.no and not self.notesOpen then
        cells[#cells + 1] = { 25, "Page notes", "Free text under the tables, for what doesn't fit one.",
                              function() self:OpenNotes() end, notes = true }
    end
    local colW = floor((width - 8) / 2)
    self.notesCell = nil
    for i, cell in ipairs(cells) do
        local c = self.tplCards[i]
        if not c then
            c = newAddCard(child, false)
            self.tplCards[i] = c
        end
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", child, "TOPLEFT", col * (colW + 8), -(y + row * (TPL_H + 6)))
        c:SetWidth(colW)
        c.icon:SetTexture(UI().ICON_ATLAS)
        c.icon:SetTexCoord(unpack(UI():IconCoords(cell[1])))
        c.icon:SetAlpha(0.7)
        c.title:SetText(cell[2])
        c.tipTitle, c.tip = cell[2], cell[3]
        c.onPick = cell[4]
        c:Show()
        self.cards[#self.cards + 1] = c
        if cell.notes then self.notesCell = c end
    end
    for i = #cells + 1, #self.tplCards do self.tplCards[i]:Hide() end
    y = y + ceil(#cells / 2) * (TPL_H + 6) - 6 + 8
    -- (the tutorial points at the section's first card)
    self.addBtn = self.cards[1] or self.addHead
    return y
end

function Panel:HideAddSection()
    self.addHead:Hide()
    self.notesCell = nil
    for _, c in ipairs(self.sugCards) do c:Hide() end
    for _, c in ipairs(self.tplCards) do c:Hide() end
    self.cards = {}
    self.addBtn = nil
end

function Panel:Width()
    local w = self.scroll:GetWidth() or 0
    if w < 50 then w = self.width or 462 end
    return w
end

function Panel:Mode() return self.opts.mode() end

function Panel:Changed()
    if self.opts.onChange then self.opts.onChange() end
end

---------------------------------------------------------------------------
-- The page's notes: a card at the end; editing, a click turns its text into a field (typed in place)
---------------------------------------------------------------------------

local NOTES_TOP = TITLE_H            -- the text under the title row
local NOTES_PAD = 12

createNotes = function(parent, panel)
    local n = CreateFrame("Frame", nil, parent)
    cardLook(n, CARD_BG, CARD_EDGE)
    n.icon = n:CreateTexture(nil, "ARTWORK")
    n.icon:SetSize(14, 14)
    n.icon:SetPoint("TOPLEFT", NOTES_PAD, -6)
    n.icon:SetTexture(UI().ICON_ATLAS)
    n.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.notes)))
    n.icon:SetAlpha(0.7)
    n.title = newText(n, "GameFontHighlight", 12.5)
    n.title:SetPoint("LEFT", n.icon, "RIGHT", 7, 0)
    n.title:SetText("Notes")
    n.text = newText(n, "GameFontHighlight", 12)
    n.text:SetTextColor(0.86, 0.86, 0.86)
    n.text:SetWordWrap(true)
    n.text:SetJustifyV("TOP")
    n.text:SetSpacing(3)
    n.text:SetPoint("TOPLEFT", NOTES_PAD, -NOTES_TOP)
    -- editing: a click on the text types in place
    n.hit = CreateFrame("Button", nil, n)
    n.hit:SetPoint("TOPLEFT", 0, -NOTES_TOP + 4)
    n.hit:SetPoint("BOTTOMRIGHT")
    n.hit:SetScript("OnClick", function() panel:OpenNotes() end)
    n.hit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Notes")
        GameTooltip:AddLine("Click to type. Enter starts a new line; a click elsewhere keeps it, Esc goes back.",
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    n.hit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the field: a dark well with a gold edge while typing
    n.well = CreateFrame("Frame", nil, n)
    n.well:SetPoint("TOPLEFT", 8, -NOTES_TOP + 6)
    n.well:SetPoint("BOTTOMRIGHT", -8, 8)
    cardLook(n.well, { 0.04, 0.04, 0.05, 0.7 }, { 1, 0.82, 0, 0.75 })
    n.well:Hide()
    n.edit = CreateFrame("EditBox", nil, n)
    n.edit:SetMultiLine(true)
    n.edit:SetAutoFocus(false)
    n.edit:SetFontObject("GameFontHighlight")
    setSize(n.edit, 12)
    n.edit:SetSpacing(3)
    n.edit:SetMaxLetters(S().MAX_NOTES)
    n.edit:SetPoint("TOPLEFT", NOTES_PAD, -NOTES_TOP)
    n.edit:SetFrameLevel(n:GetFrameLevel() + 5)
    n.edit:Hide()
    -- (measures the text as it will wrap, so the card grows while typing)
    n.measure = newText(n, "GameFontHighlight", 12)
    n.measure:SetWordWrap(true)
    n.measure:SetSpacing(3)
    n.measure:SetAlpha(0)
    n.measure:SetPoint("TOPLEFT", NOTES_PAD, -NOTES_TOP)
    local function finish(keep)
        if n.done then return end
        n.done = true
        local id, was = n.pageId, n.was
        local text = keep and ns.Util.Trim((n.edit:GetText() or ""):gsub("|", "")) or nil
        n.edit:ClearFocus()
        n.edit:Hide()
        n.well:Hide()
        panel.notesOpen = nil
        -- (by the page's id: a live board may have moved the pages while this was typed)
        local p
        for _, x in ipairs(panel.opts.strat() and panel.opts.strat().p or {}) do
            if x.id == id then p = x end
        end
        if p and text and text ~= (was or "") and panel:Mode() == "edit" then
            p.no = text ~= "" and text:sub(1, S().MAX_NOTES) or nil
            panel:Changed()
        else
            panel:Render()
        end
    end
    n.edit:SetScript("OnEscapePressed", function() finish(false) end)
    n.edit:SetScript("OnEditFocusLost", function() finish(true) end)
    n.edit:SetScript("OnTextChanged", function(self)
        if n.done then return end
        n.measure:SetText((self:GetText() or "") .. " ")
        local h = max(17, ceil(n.measure:GetStringHeight() or 17))
        if h ~= n.editH then
            n.editH = h
            panel:Render()
        end
    end)
    n.edit:SetScript("OnEditFocusGained", function()
        UI():SetEdgeColor(n.well, 1, 0.82, 0, 0.75)
    end)
    return n
end

-- Starts typing the open page's notes (the Page notes card, a click on the notes).
function Panel:OpenNotes()
    local page = self.opts.page()
    if not page or self:Mode() ~= "edit" then return end
    local n = self.notesCard
    n.pageId, n.was, n.done = page.id, page.no, false
    self.notesOpen = page.id
    n.editH = nil
    n.edit:Show()
    n.well:Show()
    n.edit:SetText(page.no or "")
    self:Render()
    n.edit:SetFocus()
    n.edit:SetCursorPosition(#(page.no or ""))
end

-- The notes card at y (shown with notes, or while they are typed). Returns the height used.
function Panel:RenderNotes(page, width, y)
    local n = self.notesCard
    local typing = self.notesOpen == page.id and n.edit:IsShown()
    if not page.no and not typing then
        n:Hide()
        return 0
    end
    local textW = width - 2 * NOTES_PAD
    n:ClearAllPoints()
    n:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -y)
    n:SetWidth(width)
    n.text:SetWidth(textW)
    n.measure:SetWidth(textW)
    n.edit:SetWidth(textW)
    local h
    if typing then
        -- (the field's text is the member's while they type: a refresh never sets it)
        n.text:Hide()
        if not n.editH then
            n.measure:SetText((n.edit:GetText() or "") .. " ")
            n.editH = max(17, ceil(n.measure:GetStringHeight() or 17))
        end
        n.edit:SetHeight(n.editH)
        h = NOTES_TOP + n.editH + 14
    else
        n.text:SetText(page.no)
        n.text:Show()
        h = NOTES_TOP + ceil(n.text:GetStringHeight() or 14) + 10
    end
    n.hit:SetShown(self:Mode() == "edit" and not typing)
    n:SetHeight(h)
    n:Show()
    return h
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
    root:CreateButton(menuEntry(16, "Header"), function()
        self.opts.prompt("Column header", col.n or "", function(text)
            text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_HEADER)
            col.n = text ~= "" and text or nil
            self:Changed()
        end)
    end)
    if col.t == "p" then
        local fm = root:CreateButton(menuEntry(nil, "Who fits", S():FilterText(col.f)))
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
    local ty = root:CreateButton(menuEntry(nil, "Type", COL_TYPE_NAME[col.t]))
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
        root:CreateButton(menuEntry(nil, "Move left"), function()
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
        root:CreateDivider()
        root:CreateButton(menuEntry(UI().ICON.trash, "Delete column", nil, true), function()
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
        if k.r > 1 then
            root:CreateDivider()
            root:CreateButton("|cffff8a8aDelete row|r", function() self:DeleteRow(k, row) end)
        end
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

-- A dispel table's type / side changed: its player columns take the classes that can remove such an effect.
local function ApplyDispelFilter(k)
    local dy = k.dy or "m"
    k.en = S().DispelSide(dy, k.en) or nil
    local f = S().DispelFilter(dy, k.en)
    for _, col in ipairs(k.c) do
        if col.t == "p" then col.f = f end
    end
end

-- A dispel table in a line: "Curse, on our raid" / "Magic, on the enemy".
local function DispelWhere(k)
    local dy = k.dy or "m"
    return S().DISPEL_NAME[dy] .. (S().DispelSide(dy, k.en) and ", on the enemy" or ", on our raid")
end
BlocksUI.DispelWhere = DispelWhere

-- The menu of a dispel table: the effects to remove (the removable ones of the boss, or any spell id), their type,
-- and whether they sit on our raid or on the enemy. One type per table: picking an effect of another type starts over.
function Panel:DispelMenu(root, k)
    local strat = self.opts.strat()
    local chosen = {}
    for _, id in ipairs(k.ds or {}) do chosen[id] = true end
    local function setEffects()
        local list = {}
        for id in pairs(chosen) do list[#list + 1] = id end
        table.sort(list)
        k.ds = #list > 0 and list or nil
        ApplyDispelFilter(k)
        self:Changed()
    end
    local function toggle(id, t, en)
        if chosen[id] then
            chosen[id] = nil
        else
            if t and (t ~= (k.dy or "m") or not k.ds) then
                -- another type (or the first pick): the table becomes that type, on the side that effect sits
                if t ~= (k.dy or "m") then chosen = {} end
                k.dy = t
                k.en = en or nil
            end
            local n = 0
            for _ in pairs(chosen) do n = n + 1 end
            if n >= S().MAX_DISPELS then
                ns:Print("A dispel table holds at most %d effects.", S().MAX_DISPELS)
                return
            end
            chosen[id] = true
        end
        setEffects()
    end
    local function label(id, t)
        return MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id))
            .. (t and grey("  " .. S().DISPEL_NAME[t]) or "")
    end
    local em = root:CreateButton(menuEntry(nil, "Effects to remove", k.ds and tostring(#k.ds) or nil))
    local listed = {}
    local known = S():GetBossDispels(strat and strat.b)
    for _, t in ipairs(S().DISPEL_ORDER) do
        for _, e in ipairs(known) do
            if e.t == t then
                listed[e.id] = true
                em:CreateCheckbox(label(e.id, e.t) .. (e.en and grey(" (on the enemy)") or ""),
                    function() return chosen[e.id] == true end, function() toggle(e.id, e.t, e.en) end)
            end
        end
    end
    for _, id in ipairs(k.ds or {}) do
        if not listed[id] then
            em:CreateCheckbox(label(id), function() return chosen[id] == true end, function() toggle(id) end)
        end
    end
    if #known == 0 then em:CreateTitle(grey("No removable effects listed for this boss")) end
    em:CreateButton("By spell ID", function()
        self.opts.prompt("Spell ID of the effect to remove (e.g. 43095 for Creeping Paralysis)", "", function(text)
            local id = tonumber(text)
            if id and id > 0 and id < 10000000 then
                id = floor(id)
                if not chosen[id] then toggle(id, S():DispelTypeOf(id)) end
            end
        end)
    end)
    local tm = root:CreateButton(menuEntry(nil, "Type", S().DISPEL_NAME[k.dy or "m"]))
    for _, t in ipairs(S().DISPEL_ORDER) do
        tm:CreateRadio(S().DISPEL_NAME[t], function() return (k.dy or "m") == t end, function()
            k.dy = t
            ApplyDispelFilter(k)
            self:Changed()
        end)
    end
    if (k.dy or "m") == "m" then
        local wm = root:CreateButton(menuEntry(nil, "Where", k.en and "on the enemy" or "on our raid"))
        wm:CreateRadio("On our raid (dispel it off a player)", function() return not k.en end, function()
            k.en = nil
            ApplyDispelFilter(k)
            self:Changed()
        end)
        wm:CreateRadio("On the enemy (purge / spellsteal)", function() return k.en == true end, function()
            k.en = true
            ApplyDispelFilter(k)
            self:Changed()
        end)
    end
end

function Panel:BlockMenu(owner, page, k, index)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(k.n)
        -- what it is
        root:CreateButton(menuEntry(16, "Rename"), function()
            self.opts.prompt("Block title", k.n, function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
                if text ~= "" then k.n = text; self:Changed() end
            end)
        end)
        local ic = root:CreateButton(menuEntry(nil, "Icon"))
        ic:CreateRadio("None", function() return k.i == nil end, function() k.i = nil; self:Changed() end)
        MapUI():BuildIconMenu(ic, k.i, function(key) k.i = key; self:Changed() end, self.opts.prompt,
            self.opts.strat() and self.opts.strat().b)
        local col = root:CreateButton(menuEntry(nil, "Colour"))
        col:CreateRadio("Default (gold)", function() return k.cl == nil end, function() k.cl = nil; self:Changed() end)
        for i, c in ipairs(MapUI().COLORS) do
            col:CreateRadio(MapUI():Swatch(i) .. " " .. c[4], function() return k.cl == i end,
                function() k.cl = i; self:Changed() end)
        end
        -- what the encounter helpers follow for this table (Core/StrategyLive.lua)
        local Live = ns.StrategyLive
        if Live then
            local eff = S().TrackKind(k)
            local trm = root:CreateButton(menuEntry(nil, "Track in fight", eff and (TRACK_TAG[eff] or Live.KIND_NAME[eff])
                or nil))
            trm:CreateRadio("Not tracked", function() return S().TrackKind(k) == nil end,
                function() k.tr = nil; self:Changed() end)
            for _, kind in ipairs(Live.KIND_ORDER) do
                local radio = trm:CreateRadio(TRACK_TAG[kind] or Live.KIND_NAME[kind],
                    function() return S().TrackKind(k) == kind end, function() k.tr = kind; self:Changed() end)
                if radio and radio.SetTooltip then
                    radio:SetTooltip(function(tt) tt:AddLine(Live.KIND_NAME[kind], 1, 0.82, 0) end)
                end
            end
            if eff == "dsp" then self:DispelMenu(root, k) end
        end
        -- its shape
        root:CreateDivider()
        local cols = root:CreateButton(menuEntry(nil, "Columns", tostring(#k.c)))
        if #k.c < S().MAX_COLS then
            local add = cols:CreateButton("Add a column")
            for _, t in ipairs({ "p", "g", "o", "x" }) do
                add:CreateButton(COL_TYPE_NAME[t], function() self:AddColumn(k, t) end)
            end
        end
        for ci, c in ipairs(k.c) do
            local sub = cols:CreateButton(("%d. %s"):format(ci, c.n or COL_TYPE_NAME[c.t]))
            self:ColumnMenu(sub, page, k, ci)
        end
        local rows = root:CreateButton(menuEntry(nil, "Rows", tostring(k.r)))
        rows:CreateButton("Add a row", function() self:InsertRow(k, k.r + 1) end)
        if k.r > 1 then rows:CreateButton("Remove the last row", function() self:DeleteRow(k, k.r) end) end
        -- where it is
        root:CreateDivider()
        root:CreateButton(menuEntry(17, "Duplicate"), function() self:CopyBlock(k, page, index + 1) end)
        local strat = self.opts.strat()
        if strat and #strat.p > 1 then
            local to = root:CreateButton(menuEntry(nil, "Copy to page"))
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
        if index > 1 then
            root:CreateButton(menuEntry(nil, "Move up"), function()
                page.k[index], page.k[index - 1] = page.k[index - 1], page.k[index]
                self:Changed()
            end)
        end
        if index < #page.k then
            root:CreateButton(menuEntry(nil, "Move down"), function()
                page.k[index], page.k[index + 1] = page.k[index + 1], page.k[index]
                self:Changed()
            end)
        end
        root:CreateDivider()
        root:CreateButton(menuEntry(UI().ICON.trash, "Delete", nil, true), function()
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
        root:CreateButton(menuEntry(16, "Label"), function()
            self.opts.prompt("Label (e.g. a boss or a player's job)", cur.l or "", function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_CELL)
                put({ l = text ~= "" and text or false })
            end)
        end)
        local ic = root:CreateButton(menuEntry(nil, "Icon"))
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
            local cm = root:CreateButton(menuEntry(nil, "Curse", pickedId and (GetSpellInfo(pickedId) or tostring(pickedId)) or nil))
            for _, id in ipairs(curses) do
                cm:CreateRadio(MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id)),
                    function() return pickedId == id end, function() putCurse(id) end)
            end
            cm:CreateButton("By spell ID", function()
                self.opts.prompt("Spell ID of the curse", "", function(text)
                    local id = tonumber(text)
                    if id and id > 0 and id < 10000000 then putCurse(floor(id)) end
                end)
            end)
            cm:CreateButton("None", function() put({ a = false }) end)
        end
        if not isCurse then
            local ab = root:CreateButton(menuEntry(nil, "Abilities", cur.a and tostring(#cur.a) or nil))
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
            ab:CreateButton("By spell ID", function()
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
            local wm = root:CreateButton(menuEntry(nil, "Only when", cond and Live:CondShort(cond) or nil))
            wm:CreateRadio("Any time", function() return cur.w == nil end, function() put({ w = false }) end)
            local auras = wm:CreateButton("The boss has")
            local any = false
            for _, id in ipairs(known and known.a or {}) do
                any = true
                auras:CreateRadio(MapUI():IconString("sp:" .. id, 14) .. " " .. (GetSpellInfo(id) or ("Spell " .. id)),
                    function() return cur.w == ("a:" .. id) end, function() put({ w = "a:" .. id }) end)
            end
            if not any then auras:CreateTitle(grey("No buffs listed for this boss")) end
            auras:CreateButton("By spell ID", function()
                self.opts.prompt("Spell ID of the buff on the boss (e.g. 41450 Blessing of Protection)", "", function(text)
                    local id = tonumber(text)
                    if id and id > 0 and id < 10000000 then put({ w = "a:" .. floor(id) }) end
                end)
            end)
            wm:CreateButton("Below health", function()
                self.opts.prompt("Health % of the boss (1-99), e.g. 30", "", function(text)
                    local v = tonumber(text)
                    if v and v >= 1 and v <= 99 then put({ w = "hp:" .. floor(v) }) end
                end)
            end)
        end
        local shown = cur.s and self.opts.slotLabel and self.opts.slotLabel(cur.s)
        local sl = root:CreateButton(menuEntry(nil, "Show a slot's player", shown))
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
        root:CreateDivider()
        root:CreateButton(menuEntry(UI().ICON.trash, "Clear", nil, true), function()
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
            root:CreateButton("|cffff8a8aClear|r", function() self.opts.onAssign(ref, nil) end)
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

-- A slot's rule as a role (its icon goes in front of "Tank", "Melee"): the rule when it is one role, else nil.
local ROLE_ICON = { tank = "tank", healer = "healer", melee = "damager", ranged = "ranged", caster = "ranged" }
local function roleOfFilter(f)
    if not f or f == "" or f:find(",", 1, true) then return nil end
    return ROLE_ICON[f]
end

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
    -- (layers: a row's tint (mine, twice), an empty slot's soft well, the light of a hovered link, the drop spot)
    c.bg = c:CreateTexture(nil, "BACKGROUND", nil, 1)
    c.bg:SetAllPoints()
    c.well = c:CreateTexture(nil, "BACKGROUND", nil, 2)
    c.well:SetPoint("TOPLEFT", 0, -3)
    c.well:SetPoint("BOTTOMRIGHT", -4, 3)
    c.well:SetColorTexture(1, 1, 1, 0.035)
    c.lit = c:CreateTexture(nil, "BORDER")
    c.lit:SetAllPoints()
    c.lit:SetColorTexture(1, 0.82, 0, 0.16)
    c.lit:Hide()
    UI():AddEdges(c, "OVERLAY")
    UI():SetEdgeColor(c, 1, 0.82, 0, 0)
    -- my row: a gold bar on the card's left edge
    c.bar = c:CreateTexture(nil, "ARTWORK")
    c.bar:SetSize(2, ROW_H - 6)
    c.bar:SetPoint("LEFT", c, "LEFT", -INSET, 0)
    c.bar:SetColorTexture(1, 0.82, 0, 1)
    c.bar:Hide()
    -- the hairline under the row
    c.line = c:CreateTexture(nil, "BORDER")
    c.line:SetPoint("BOTTOMLEFT")
    c.line:SetPoint("BOTTOMRIGHT")
    c.line:SetHeight(1)
    c.line:SetColorTexture(1, 1, 1, 0.045)
    local hl = c:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.06)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(14, 14)
    c.icon:SetPoint("LEFT", 2, 0)
    c.fs = newText(c, "GameFontHighlight", 12)
    -- a target cell's link to a slot: a pill at the right end, never cut off (the label gives way instead)
    c.pill = UI():CreateTagPill(c, 15)
    c.pill:SetBase(CARD_BG[1], CARD_BG[2], CARD_BG[3])
    c.pill:SetPoint("RIGHT", -2, 0)
    c.pill:Hide()
    function c:SetPill(text)
        if not text then
            self.pill:Hide()
            self.fs:SetPoint("RIGHT", -2, 0)
            return
        end
        self.pill:Set(text, "mute")
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

-- A quiet text link in a card's foot: a gold "+" and grey words ("+ Row", "+ Column").
local function footLink(parent, text, chevron, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(FOOT_H)
    b.fs = newText(b, "GameFontHighlight", 11)
    b.fs:SetPoint("LEFT", 0, 0)
    b.fs:SetText("|cffffd100+|r " .. text)
    b.fs:SetTextColor(0.56, 0.56, 0.56)
    local w = (b.fs:GetStringWidth() or 40)
    if chevron then
        b.chev = b:CreateTexture(nil, "ARTWORK")
        b.chev:SetSize(9, 9)
        b.chev:SetTexture(UI().ICON_ATLAS)
        b.chev:SetTexCoord(unpack(UI():IconCoords(UI().ICON.chevron)))
        b.chev:SetVertexColor(0.8, 0.8, 0.8, 0.7)
        b.chev:SetPoint("LEFT", b.fs, "RIGHT", 4, -1)
        w = w + 4 + 9
    end
    b:SetWidth(floor(w + 0.5))
    b:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) end)
    b:SetScript("OnLeave", function(self) self.fs:SetTextColor(0.56, 0.56, 0.56) end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", onClick)
    return b
end

local function newBlock(parent, panel)
    local b = CreateFrame("Frame", nil, parent)
    cardLook(b, CARD_BG, CARD_EDGE)
    -- the title row: the block's colour as a bar on its left, its icon and title, what it is tracked as, its menu
    b.title = CreateFrame("Button", nil, b)
    b.title:SetHeight(TITLE_H)
    b.title:SetPoint("TOPLEFT")
    b.title:SetPoint("TOPRIGHT")
    b.title.accent = b.title:CreateTexture(nil, "ARTWORK")
    b.title.accent:SetPoint("TOPLEFT")
    b.title.accent:SetPoint("BOTTOMLEFT")
    b.title.accent:SetWidth(3)
    local hl = b.title:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.03)
    b.title.icon = b.title:CreateTexture(nil, "ARTWORK")
    b.title.icon:SetSize(16, 16)
    b.title.icon:SetPoint("LEFT", 12, 0)
    b.title.fs = newText(b.title, "GameFontHighlight", 12.5)
    b.tag = UI():CreateTagPill(b.title, 15)
    b.tag:SetBase(CARD_BG[1], CARD_BG[2], CARD_BG[3])
    b.tag:SetPoint("LEFT", b.title.fs, "RIGHT", 7, 0)
    b.tag:Hide()
    b.title:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.gear = CreateFrame("Button", nil, b.title)
    b.gear:SetSize(20, 20)
    b.gear:SetPoint("RIGHT", -6, 0)
    b.gear.hl = b.gear:CreateTexture(nil, "BACKGROUND")
    b.gear.hl:SetAllPoints()
    b.gear.hl:SetColorTexture(1, 1, 1, 0.08)
    b.gear.hl:Hide()
    b.gear.tex = b.gear:CreateTexture(nil, "ARTWORK")
    b.gear.tex:SetPoint("TOPLEFT", 2, -2)
    b.gear.tex:SetPoint("BOTTOMRIGHT", -2, 2)
    b.gear.tex:SetTexture(UI().ICON_ATLAS)
    b.gear.tex:SetTexCoord(unpack(UI():IconCoords(UI().ICON.more)))
    b.gear.tex:SetAlpha(0.6)
    b.gear:SetScript("OnEnter", function(self)
        self.tex:SetAlpha(1)
        self.hl:Show()
    end)
    b.gear:SetScript("OnLeave", function(self)
        self.tex:SetAlpha(0.6)
        self.hl:Hide()
    end)
    -- a dispel table's line: what it removes, under the title
    b.cells = {}
    b.heads = {}
    -- editing: the foot's links
    b.addRow = footLink(b, "Row", false, function() panel:InsertRow(b.cdlK, b.cdlK.r + 1) end)
    b.addCol = footLink(b, "Column", true, function(btn)
        UI():ContextMenu(btn, function(root)
            for _, t in ipairs({ "p", "g", "o", "x" }) do
                root:CreateButton(COL_TYPE_NAME[t], function() panel:AddColumn(b.cdlK, t) end)
            end
        end)
    end)
    return b
end

-- Widths of a block's columns for the table's width.
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

-- Who fits a slot, in grey, the role's icon in front ("Tank", "Melee", "Anyone").
local function placeholder(f)
    local role = roleOfFilter(f)
    return (role and (UI():RoleIconText(role, 13) .. " ") or "") .. "|cff8a8a8a" .. S():FilterText(f) .. "|r"
end

-- The text of a player slot: who fits (editing, and a strategy read on its own), the player (a class circle in front)
-- or, empty, who fits in a soft well (assigning) or a dash (a raid's board). -> text, info, classFile, well
function Panel:SlotText(ref, col)
    local mode = self:Mode()
    local raid = self.opts.raidBoard and self.opts.raidBoard()
    if mode == "edit" or (mode == "view" and not raid) then return placeholder(col.f), nil end
    local key = self.opts.assigned(ref)
    if not key then
        if mode == "fill" then return placeholder(col.f), nil, nil, true end
        return "|cff8a8a8a\226\128\148|r", nil
    end
    local info = self.opts.memberInfo(key) or {}
    local name = UI():ColoredName(key, info.c)
    if info.missing then name = "|cffff5050" .. ns.Util.ShortName(key) .. "|r" end
    return name, info, info.c
end

function Panel:Render()
    local page = self.opts.page()
    local mode = self:Mode()
    local width = self:Width()
    local inner = width - 2 * INSET
    local y = 0
    local child = self.child
    child:SetWidth(width)
    for _, b in ipairs(self.blocks) do b:Hide() end
    if not page then
        child:SetHeight(10)
        self.notesCard:Hide()
        self:HideAddSection()
        -- a raid's boss without any strategy (the header's switch makes one)
        self.empty:SetShown(self.opts.strat() == nil)
        self.empty:ClearAllPoints()
        self.empty:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -6)
        self.empty:SetWidth(width - 4)
        self.empty:SetText("No strategy for this boss yet.")
        self.empty:SetTextColor(0.54, 0.54, 0.54)
        return
    end
    self.cellByRef = {}
    self.cellY = {}
    local editing = mode == "edit"
    local noBlocks = #(page.k or {}) == 0
    -- an empty page: one quiet line (editing: what goes here, above Add a block; reading: that nothing does)
    if noBlocks and (editing or not page.no) then
        self.empty:ClearAllPoints()
        self.empty:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -(editing and 2 or 6))
        self.empty:SetWidth(width - 4)
        if editing then
            self.empty:SetText("Jobs for this page: who tanks what, who kicks, who stands where. Names go in when a "
                .. "raid is assigned.")
            self.empty:SetTextColor(0.66, 0.66, 0.66)
        else
            self.empty:SetText("No jobs on this page.")
            self.empty:SetTextColor(0.54, 0.54, 0.54)
        end
        self.empty:Show()
        y = (editing and 2 or 6) + ceil(self.empty:GetStringHeight() or 14) + (editing and 10 or 6)
    else
        self.empty:Hide()
    end
    for index, k in ipairs(page.k or {}) do
        local b = self.blocks[index]
        if not b then
            b = newBlock(child, self)
            self.blocks[index] = b
        end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        b:SetWidth(width)
        -- the title row
        local r, g, bl = 1, 0.82, 0
        if k.cl then r, g, bl = MapUI():Color(k.cl) end
        b.title.accent:SetColorTexture(r, g, bl, 1)
        b.title.fs:ClearAllPoints()
        if k.i then
            MapUI():SetIcon(b.title.icon, k.i)
            b.title.icon:Show()
            b.title.fs:SetPoint("LEFT", b.title.icon, "RIGHT", 7, 0)
        else
            b.title.icon:Hide()
            b.title.fs:SetPoint("LEFT", 12, 0)
        end
        b.title.fs:SetText(k.n)
        local kind = S().TrackKind(k)
        b.tag:SetShown(kind ~= nil)
        if kind then b.tag:Set(TRACK_TAG[kind] or kind, "ok") end
        b.gear:SetShown(editing)
        b.gear:SetScript("OnClick", function(btn) self:BlockMenu(btn, page, k, index) end)
        b.title:SetScript("OnClick", function(btn)
            if editing then self:BlockMenu(b.gear, page, k, index) end
        end)
        b.title:SetScript("OnEnter", function()
            if self.opts.onHover then self.opts.onHover(k.id) end
        end)
        b.title:SetScript("OnLeave", function()
            if self.opts.onHover then self.opts.onHover(nil) end
        end)
        local by = TITLE_H
        b.blockId = k.id
        local widths = colWidths(k, inner)
        local hasHead = editing
        for _, c in ipairs(k.c) do if c.n then hasHead = true end end
        local used = 0
        local function cell(x, cy, w)
            used = used + 1
            local c = b.cells[used]
            if not c then
                c = newCell(b, self)
                b.cells[used] = c
            end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", b, "TOPLEFT", INSET + x, -cy)
            c:SetSize(max(1, w), ROW_H)
            c.bg:SetColorTexture(0, 0, 0, 0)
            c.well:Hide()
            c.bar:Hide()
            c.line:Show()
            c.line:SetColorTexture(1, 1, 1, 0.045)
            c.icon:Hide()
            c.fs:ClearAllPoints()
            c.fs:SetPoint("LEFT", 2, 0)
            c.fs:SetPoint("RIGHT", -2, 0)
            c.fs:SetWordWrap(false)
            c.fs:SetJustifyH("LEFT")
            setSize(c.fs, 12)
            c.fs:SetTextColor(1, 1, 1)
            c.lit:Hide()
            UI():SetEdgeColor(c, 1, 0.82, 0, 0)
            c:SetPill(nil)
            c.slotRef, c.hoverRef, c.tip, c.onClick, c.rowMenu, c.headRef, c.blockId = nil, nil, nil, nil, nil, nil, nil
            c.targetInfo = nil
            c.cdlY = y + cy
            c:Show()
            return c
        end
        if kind == "dsp" then
            -- a dispel table: what to remove, of which type and where, in a line under the title
            local c = cell(0, by, inner)
            c:SetHeight(STRIP_H)
            c.line:Hide()
            setSize(c.fs, 11)
            local icons, tip = "", { "Remove: " .. DispelWhere(k) }
            for _, id in ipairs(k.ds or {}) do
                icons = icons .. MapUI():IconString("sp:" .. id, 14) .. " "
                tip[#tip + 1] = MapUI():IconString("sp:" .. id, 13) .. " " .. (GetSpellInfo(id) or ("Spell " .. id))
            end
            local first = k.ds and k.ds[1]
            local text = first and (icons .. (GetSpellInfo(first) or ("Spell " .. first))
                .. (#k.ds > 1 and (" +" .. (#k.ds - 1)) or "") .. grey("  " .. DispelWhere(k)))
                or grey(editing and "click to pick the effect to remove" or ("any " .. DispelWhere(k)))
            c.fs:SetText(text)
            local who = {}
            for _, cl in ipairs(S().DispelClasses(k.dy or "m", S().DispelSide(k.dy or "m", k.en))) do
                who[#who + 1] = ns.CLASS_NAMES and ns.CLASS_NAMES[cl] or cl
            end
            tip[#tip + 1] = "Can remove it: " .. (#who > 0 and table.concat(who, ", ") or "nobody")
            tip[#tip + 1] = "Everyone in this table is told at once when it is up. Left empty, everyone who can remove it is."
            c.tip = tip
            c.blockId = k.id
            if editing then
                c.onClick = function(btn)
                    UI():ContextMenu(btn, function(root)
                        root:CreateTitle(k.n)
                        self:DispelMenu(root, k)
                    end)
                end
            end
            by = by + STRIP_H
        end
        if hasHead then
            local x = 0
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci])
                c:SetHeight(HEAD_H)
                c.line:SetColorTexture(1, 1, 1, 0.08)
                setSize(c.fs, 10.5)
                -- the order column is only ORDER_W wide: "#" (its name stays in the tooltip and menu)
                local label = col.t == "o" and grey("#") or col.n or (editing and grey(COL_TYPE_NAME[col.t]) or "")
                c.fs:SetText(label)
                c.fs:SetTextColor(1, 0.82, 0, 0.9)
                if col.t == "o" then c.fs:SetJustifyH("CENTER") end
                c.hoverRef = k.id .. "." .. ci
                c.headRef = c.hoverRef
                if editing then
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
            local mine = false
            for ci, col in ipairs(k.c) do
                local c = cell(x, by, widths[ci])
                local v = k.d and k.d[row] and k.d[row][ci]
                if editing then c.rowMenu = function(btn) self:RowMenu(btn, k, row) end end
                if col.t == "o" then
                    c.fs:SetJustifyH("CENTER")
                    if S().TrackKind(k) == "rot" and IsBackup(k, row) then
                        setSize(c.fs, 10.5)
                        c.fs:SetText("|cffc7a6ffB|r")
                        c.tip = { "Backup kicker", "Kicks only when no designated kicker's interrupt will be ready for the "
                            .. "boss' next cast." .. (editing and " Right-click the row to change." or "") }
                    else
                        setSize(c.fs, 11)
                        c.fs:SetText("|cff8a8a8a" .. row .. "|r")
                    end
                elseif col.t == "x" then
                    -- a long text wraps: the row grows with it
                    c.fs:ClearAllPoints()
                    c.fs:SetPoint("LEFT", 2, 0)
                    c.fs:SetWidth(max(10, widths[ci] - 6))
                    c.fs:SetWordWrap(true)
                    setSize(c.fs, 11.5)
                    c.fs:SetTextColor(0.9, 0.9, 0.9)
                    c.fs:SetText(v or (editing and grey("click to type") or ""))
                    rowH = max(rowH, ceil(c.fs:GetStringHeight() or 0) + 8)
                    if editing then c.onClick = function(btn) self:CellMenu(btn, k, row, ci) end end
                elseif col.t == "g" then
                    local text = v and v.l or ""
                    local linkTip
                    if v and v.s then
                        local name = self.opts.slotName and self.opts.slotName(v.s)
                        local slotLabel = self.opts.slotLabel and self.opts.slotLabel(v.s) or v.s
                        if editing or not name then
                            -- the slot in short: "-> #2" in this block, "-> Tanks #2" from another one
                            c:SetPill("-> " .. self:ShortSlot(v.s, k, page))
                            linkTip = "Shows the player of " .. slotLabel ..
                                (editing and " here. Right-click > Clear removes it." or ".")
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
                        c.fs:SetPoint("LEFT", c.icon, "RIGHT", 6, 0)
                        if c.pill:IsShown() then c.fs:SetPoint("RIGHT", c.pill, "LEFT", -4, 0) else c.fs:SetPoint("RIGHT", -2, 0) end
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
                    if text == "" and not c.icon:IsShown() and not c.pill:IsShown() then
                        -- (editing: its tooltip says what goes here)
                        text = editing and "|cff8a8a8aclick to set|r" or "|cff8a8a8a\226\128\148|r"
                        if editing then setSize(c.fs, 11) end
                        c.tip = c.tip or (editing and { "Target", "Click to type a label or pick an icon, or drop an "
                            .. "icon from the map here." } or nil)
                    end
                    if linkTip then
                        c.tip = c.tip or { text ~= "" and v and v.l or "Target" }
                        c.tip[#c.tip + 1] = linkTip
                    end
                    c.fs:SetText(text)
                    c.targetInfo = { k = k, row = row, col = ci }
                    if editing then c.onClick = function(btn) self:CellMenu(btn, k, row, ci) end end
                elseif col.t == "p" then
                    local ref = S().SlotRef(k.id, row, ci)
                    -- the slot's own rule, else the column's
                    local slotCol = { f = (type(v) == "table" and v.f) or col.f }
                    local text, info, classFile, well = self:SlotText(ref, slotCol)
                    if classFile then
                        UI():ClassIcon(c.icon, classFile)
                        c.fs:ClearAllPoints()
                        c.fs:SetPoint("LEFT", c.icon, "RIGHT", 6, 0)
                        c.fs:SetPoint("RIGHT", -2, 0)
                    elseif not info then
                        setSize(c.fs, 11)
                    end
                    c.well:SetShown(well and true or false)
                    if well then
                        c.fs:ClearAllPoints()
                        c.fs:SetPoint("LEFT", 6, 0)
                        c.fs:SetPoint("RIGHT", -6, 0)
                    end
                    c.fs:SetText(text)
                    c.slotRef, c.hoverRef = ref, ref
                    if self.opts.isMine and self.opts.isMine(ref) then mine = true end
                    local tip = { self.opts.slotLabel and self.opts.slotLabel(ref) or ref, "Fits: " .. S():FilterText(slotCol.f) ..
                        (type(v) == "table" and v.f and "  (this slot only)" or "") }
                    if info and info.missing then tip[#tip + 1] = "|cffff5050Not signed up for this raid / not in the raid.|r" end
                    if self.opts.isDup and self.opts.isDup(ref) then
                        c.bg:SetColorTexture(0.55, 0.28, 0.03, 0.45)
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
                    elseif editing then
                        tip[#tip + 1] = "The raid leader fills this slot per raid. Click to set who fits this slot; drag it onto the map to show the player there; right-click for row options."
                        c.onClick = function(btn) self:SlotFilterMenu(btn, k, row, ci) end
                    end
                    c.tip = tip
                    self.cellByRef[ref] = self.cellByRef[ref] or {}
                    tinsert(self.cellByRef[ref], c)
                    self.cellY[ref] = y + by
                end
                x = x + widths[ci]
            end
            for i = rowFirst, used do
                local c = b.cells[i]
                if rowH > ROW_H then c:SetHeight(rowH) end
                -- (no hairline under the last row)
                if row == k.r then c.line:Hide() end
                -- my row (a raid's board): the gold tint and a bar on the card's edge
                if mine then
                    c.bg:SetColorTexture(1, 0.82, 0, 0.12)
                    if i == rowFirst then c.bar:Show() end
                end
            end
            by = by + rowH
        end
        for i = used + 1, #b.cells do b.cells[i]:Hide() end
        -- editing: + Row and + Column as quiet links in the card's foot
        if editing then
            b.cdlK = k
            b.addRow:ClearAllPoints()
            b.addRow:SetPoint("TOPLEFT", b, "TOPLEFT", 12, -by)
            b.addCol:ClearAllPoints()
            b.addCol:SetPoint("LEFT", b.addRow, "RIGHT", 16, 0)
            b.addRow:SetShown(k.r < S().MAX_ROWS)
            b.addCol:SetShown(#k.c < S().MAX_COLS)
            if not b.addRow:IsShown() then b.addCol:SetPoint("TOPLEFT", b, "TOPLEFT", 12, -by) end
            by = by + FOOT_H
        else
            b.addRow:Hide()
            b.addCol:Hide()
            by = by + PAD_B
        end
        b:SetHeight(by)
        b:Show()
        y = y + by + GAP
    end
    -- the page's notes, then (editing) Add a block; the tutorial points at the notes card or the Page notes cell
    local nh = self:RenderNotes(page, width, y)
    if nh > 0 then y = y + nh + GAP end
    if editing then
        y = self:RenderAddSection(page, width, y)
    else
        self:HideAddSection()
    end
    self.notesBtn = (editing and self.notesCell) or self.notesCard
    child:SetHeight(max(10, y))
    self:ApplyHighlight()
end

-- Scrolls the panel so a slot's row shows (a job of mine clicked in the dock).
function Panel:ScrollTo(ref)
    local y = self.cellY and self.cellY[ref]
    if not y then return end
    local sf = self.scroll
    local range = sf:GetVerticalScrollRange() or 0
    local h = sf:GetHeight() or 0
    local cur = sf:GetVerticalScroll() or 0
    if y >= cur and y + ROW_H <= cur + h then return end
    sf:SetVerticalScroll(max(0, min(range, y - 40)))
end

function Panel:Highlight(ref)
    self.lit = ref
    self:ApplyHighlight()
end

-- A player being dragged: the slot under the mouse lights as the drop spot.
function Panel:SetDrop(ref)
    if self.drop == ref then return end
    self.drop = ref
    self:ApplyHighlight()
end

function Panel:ApplyHighlight()
    for _, b in ipairs(self.blocks) do
        for _, c in ipairs(b.cells) do
            c.lit:Hide()
            UI():SetEdgeColor(c, 1, 0.82, 0, 0)
        end
    end
    if not self.cellByRef then return end
    for ref, cells in pairs(self.cellByRef) do
        local lit = self.lit and MapUI():RefsOverlap(self.lit, ref)
        local drop = self.drop ~= nil and self.drop == ref
        for _, c in ipairs(cells) do
            c.lit:SetShown((lit or drop) and true or false)
            if drop then UI():SetEdgeColor(c, 1, 0.82, 0, 0.85) end
        end
    end
end

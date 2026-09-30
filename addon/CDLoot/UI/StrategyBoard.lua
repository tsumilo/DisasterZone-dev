-- CDLoot: UI/StrategyBoard.lua
-- The strategy board window (Addendum K): a strategy's pages, each a map (UI/StrategyMap.lua) with the assignment
-- blocks beside it (UI/StrategyBlocks.lua).
-- Modes:
--   view  - anyone: the board as drawn; opened from a raid it shows that raid's names and "your jobs".
--   edit  - authors (GM, guild council, raid leaders): draw on the map, shape the blocks, add pages, then Save.
--   fill  - authors, from a raid: pick the strategy for the boss and put players into the slots (carry over last
--           raid's names, drag from the raid's players, Suggest fill), then Save.
-- Unsaved work stays in the window while it is closed; opening something else asks before dropping it.
-- Editing and assigning keep an undo history (Ctrl+Z, Ctrl+Y / Ctrl+Shift+Z); while editing the keyboard also drives
-- the map (Del, Ctrl+C / X / V / D / A / G, arrows; see UI/StrategyMap.lua). Keys the board doesn't use go on to the
-- game as usual.
local addonName, ns = ...

local Board = ns:NewModule("StrategyBoard")

local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat

local WIN_W, WIN_H = 1180, 720
local MAP_W = 700
local TOP_H = 56
local POOL_COLS, CHIP_W, CHIP_H = 5, 136, 17

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function MapUI() return ns.StrategyMapUI end
local function grey(t) return "|cff808080" .. tostring(t) .. "|r" end
local function shortName(key) return ns.Util.ShortName(key) or tostring(key) end

-- The toolbar icons (the atlas and its order: UI/Widgets.lua, UI.ICON_ATLAS).
local TOOL_ATLAS = "Interface\\AddOns\\CDLoot\\Media\\Strategy\\tools"
local TOOL_SIZE = 26
local TOOL_ICON = { select = 1, pan = 2, circle = 3, rect = 4, arrow = 5, line = 6, icon = 7, text = 8 }
local function atlasCoords(i) return UI():IconCoords(i) end

-- The editing keys, shown on the toolbar's "?" button.
local SHORTCUTS = {
    { "Del", "delete the selection" },
    { "Ctrl+C / Ctrl+V", "copy, paste" },
    { "Ctrl+D", "duplicate" },
    { "Ctrl+G / Ctrl+Shift+G", "group, ungroup" },
    { "Ctrl+Z / Ctrl+Y", "undo, redo" },
    { "Arrows", "nudge the selection" },
    { "Alt (while dragging)", "snap" },
    { "Double-click text", "edit it" },
    { "Shift-drag onto a table", "link to a job" },
    { "Right-click the map", "add, pick the map" },
    { "Mouse wheel", "zoom" },
}

local win
local st = {
    mode = "view",      -- view | edit | fill
    strat = nil,        -- the strategy shown (a copy; the draft while editing)
    occ = nil,          -- the raid (fill / view with names)
    boss = nil,         -- the boss (raid view: even before a strategy exists)
    page = 1,
    assign = {},        -- slot -> player key (view: the saved fill; fill: the draft)
    dirty = false,
    picked = nil,       -- fill: a player clicked in the pool, placed by clicking a slot
}

---------------------------------------------------------------------------
-- Prompt (single- or multi-line text)
---------------------------------------------------------------------------

local prompt

local function ensurePrompt()
    if prompt then return prompt end
    local f = CreateFrame("Frame", "CDLootStrategyPrompt", UIParent, "BackdropTemplate")
    f:SetSize(360, 130)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetPoint("CENTER", 0, 120)
    f:EnableMouse(true)
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 16, -16)
    f.title:SetPoint("RIGHT", -16, 0)
    f.title:SetJustifyH("LEFT")
    f.edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    f.edit:SetAutoFocus(false)
    f.edit:SetHeight(22)
    f.edit:SetPoint("TOPLEFT", 22, -40)
    f.edit:SetPoint("RIGHT", -20, 0)
    f.edit:SetMaxLetters(64)
    f.scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.scroll:SetPoint("TOPLEFT", 18, -40)
    f.scroll:SetPoint("BOTTOMRIGHT", -36, 44)
    f.multi = CreateFrame("EditBox", nil, f.scroll)
    f.multi:SetMultiLine(true)
    f.multi:SetAutoFocus(false)
    f.multi:SetFontObject("ChatFontNormal")
    f.multi:SetWidth(300)
    f.multi:SetMaxLetters(400)
    f.scroll:SetScrollChild(f.multi)
    f.multiBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.multiBg:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", -4, 4)
    f.multiBg:SetPoint("BOTTOMRIGHT", f.scroll, "BOTTOMRIGHT", 4, -4)
    f.multiBg:SetColorTexture(0, 0, 0, 0.5)
    local function accept()
        local text = f.isMulti and f.multi:GetText() or f.edit:GetText()
        local cb = f.cb
        f.cb = nil
        f:Hide()
        if cb then cb(text) end
    end
    f.ok = UI():CreateButton(f, _G.OKAY or "OK", 90, 22, accept)
    f.ok:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -4, 14)
    f.cancel = UI():CreateButton(f, _G.CANCEL or "Cancel", 90, 22, function() f.cb = nil; f:Hide() end)
    f.cancel:SetPoint("BOTTOMLEFT", f, "BOTTOM", 4, 14)
    f.edit:SetScript("OnEnterPressed", accept)
    f.edit:SetScript("OnEscapePressed", function() f.cb = nil; f:Hide() end)
    f.multi:SetScript("OnEscapePressed", function() f.cb = nil; f:Hide() end)
    f:Hide()
    prompt = f
    return f
end

-- Asks for a text: cb(text) on OK.
function Board:Prompt(title, default, cb, multiline)
    local f = ensurePrompt()
    f.title:SetText(title or "")
    f.cb = cb
    f.isMulti = multiline and true or false
    f:SetSize(360, multiline and 220 or 120)
    f.edit:SetShown(not multiline)
    f.scroll:SetShown(multiline and true or false)
    f.multiBg:SetShown(multiline and true or false)
    if multiline then
        f.multi:SetText(default or "")
        f.multi:SetFocus()
    else
        f.edit:SetText(default or "")
        f.edit:SetFocus()
        f.edit:HighlightText()
    end
    f:Show()
    f:Raise()
end

local function promptFn(title, default, cb, multiline) Board:Prompt(title, default, cb, multiline) end

---------------------------------------------------------------------------
-- State helpers
---------------------------------------------------------------------------

local function page() return st.strat and st.strat.p and st.strat.p[st.page] or nil end

local slotLabels = {}
local function rebuildSlots()
    slotLabels = {}
    for _, s in ipairs(S():GetSlots(st.strat)) do slotLabels[s.ref] = s.label end
end

local memberSet, memberList = {}, {}
local function rebuildMembers()
    memberSet, memberList = {}, {}
    if not st.occ then return end
    memberList = S():GetRaidMembers(st.occ)
    for _, m in ipairs(memberList) do memberSet[m.key] = m end
end

local function classOf(key)
    local m = memberSet[key]
    if m and m.c then return m.c end
    return ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key) or nil
end

local function coloredName(key)
    return UI():ColoredName(key, classOf(key))
end

local function countOf(key)
    local n = 0
    for _, k in pairs(st.assign) do if k == key then n = n + 1 end end
    return n
end

local dups = {}
local function rebuildDups()
    dups = S():FindDuplicates(st.strat, st.assign)
end

local function canEdit() return S():CanEdit() end

-- Opening a raid needs a planned raid I can still see.
local function raidView()
    return st.occ and ns.RaidPlan and ns.RaidPlan:GetRaid(st.occ) or nil
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function tipButton(b, title, text)
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local ghost
local function ensureGhost()
    if ghost then return ghost end
    ghost = CreateFrame("Frame", nil, UIParent)
    ghost:SetSize(CHIP_W, CHIP_H)
    ghost:SetFrameStrata("TOOLTIP")
    ghost.fs = ghost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ghost.fs:SetPoint("LEFT", 2, 0)
    ghost.bg = ghost:CreateTexture(nil, "BACKGROUND")
    ghost.bg:SetAllPoints()
    ghost.bg:SetColorTexture(0, 0, 0, 0.7)
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", x / s + 8, y / s)
    end)
    ghost:Hide()
    return ghost
end

local function createPoolChip(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetSize(CHIP_W - 4, CHIP_H - 1)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(14, 14)
    c.icon:SetPoint("LEFT", 1, 0)
    c.fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.fs:SetPoint("LEFT", c.icon, "RIGHT", 3, 0)
    c.fs:SetPoint("RIGHT", -18, 0)
    c.fs:SetJustifyH("LEFT")
    c.fs:SetWordWrap(false)
    c.count = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.count:SetPoint("RIGHT", -2, 0)
    c.picked = c:CreateTexture(nil, "BACKGROUND")
    c.picked:SetAllPoints()
    c.picked:SetColorTexture(1, 0.82, 0, 0.35)
    local hl = c:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    c:RegisterForDrag("LeftButton")
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", function(self)
        st.picked = st.picked ~= self.key and self.key or nil
        Board:RefreshPool()
    end)
    c:SetScript("OnDragStart", function(self)
        local g = ensureGhost()
        g.fs:SetText(coloredName(self.key))
        g:Show()
        st.dragging = self.key
    end)
    c:SetScript("OnDragStop", function()
        if ghost then ghost:Hide() end
        local key = st.dragging
        st.dragging = nil
        local ref = key and win.blocks:SlotUnderCursor()
        if ref then Board:Assign(ref, key) end
    end)
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(coloredName(self.key))
        local m = memberSet[self.key]
        if m then
            local label = ns.RaidComp and ns.RaidComp:SpecLabel(m.c, m.sp)
            GameTooltip:AddLine((label and (label .. " ") or "") .. (ns.CLASS_NAMES[m.c] or ""), 1, 1, 1)
            if m.st == "T" then GameTooltip:AddLine("Tentative", 1, 0.82, 0)
            elseif m.st == "B" then GameTooltip:AddLine("Bench", 1, 0.82, 0)
            elseif m.inRaid then GameTooltip:AddLine("In your raid, no sign-up", 0.7, 0.7, 0.7) end
        end
        for _, s in ipairs(S():GetPlayerSlots(st.strat, st.assign, self.key)) do
            GameTooltip:AddLine(s.label, 0.85, 0.85, 0.85)
        end
        GameTooltip:AddLine("Drag onto a slot, or click and then click a slot.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

local function createWindow()
    local f = UI():CreateWindow("CDLootStrategyBoard", "Strategy board", WIN_W, WIN_H)
    f:SetFrameStrata("HIGH")
    local c = f.content
    win = f

    f.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOPLEFT", 4, -4)
    f.title:SetJustifyH("LEFT")
    f.title:SetWordWrap(false)
    -- editing: the title is the rename control (click it)
    f.titleBtn = CreateFrame("Button", nil, c)
    f.titleBtn:SetPoint("TOPLEFT", f.title, "TOPLEFT", -2, 2)
    f.titleBtn:SetPoint("BOTTOMRIGHT", f.title, "BOTTOMRIGHT", 2, -2)
    f.titleBtn.hl = f.titleBtn:CreateTexture(nil, "BACKGROUND")
    f.titleBtn.hl:SetAllPoints()
    f.titleBtn.hl:SetColorTexture(1, 1, 1, 0.08)
    f.titleBtn.hl:Hide()
    f.titleBtn:SetScript("OnClick", function() Board:RenameStrategy() end)
    f.titleBtn:SetScript("OnEnter", function(self)
        self.hl:Show()
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Click to rename the strategy")
        GameTooltip:Show()
    end)
    f.titleBtn:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
    f.sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.sub:SetPoint("TOPLEFT", 4, -24)
    f.sub:SetPoint("RIGHT", c, "RIGHT", -420, 0)
    f.sub:SetJustifyH("LEFT")
    f.sub:SetWordWrap(false)

    -- right side actions (laid out right to left in Refresh: layoutHeader)
    f.saveBtn = UI():CreateSleekButton(c, "Save", 80, 24, function() Board:Save() end, "primary")
    f.cancelBtn = UI():CreateSleekButton(c, "Cancel", 70, 24, function() Board:CancelChanges() end)
    f.editBtn = UI():CreateSleekButton(c, "Edit strategy", 110, 24, function() Board:SetMode("edit") end)
    tipButton(f.editBtn, "Edit strategy", "Draw on the map, change the blocks and pages. Changes reach everyone when you Save.")
    f.fillBtn = UI():CreateSleekButton(c, "Assign players", 116, 24, function() Board:SetMode("fill") end, "primary")
    tipButton(f.fillBtn, "Assign players", "Put this raid's players into the slots.")
    -- the raid leader's client marks the mobs from the portraits' raid mark badges (Core/StrategyLive.lua)
    f.autoMark = UI():CreateCheckbox(c, "Auto-mark", function() return st.strat and st.strat.am ~= false end,
        function()
            if not st.strat then return end
            if st.strat.am == false then st.strat.am = nil else st.strat.am = false end
            Board:MarkDirty(true)
        end)
    tipButton(f.autoMark, "Auto-mark", "In the raid, the raid leader's CDLoot puts the raid marks shown on the boss "
        .. "portraits (right-click a portrait > Raid mark) on the mobs as their nameplates appear.")
    f.stratDD = UI():CreateSleekMenuButton(c, "Strategy", 200, function(root) Board:StrategyMenu(root) end, 24)
    -- try the encounter helpers of this strategy alone (Core/StrategyPractice.lua)
    f.practiceBtn = UI():CreateSleekButton(c, "Practice", 80, 24, function()
        if st.strat and ns.StrategyPractice then ns.StrategyPractice:Start(st.strat) end
    end)
    tipButton(f.practiceBtn, "Practice", "Try this strategy's in-fight helpers alone: your jobs panel, whose kick it "
        .. "is, marks on what you target. Demo players fill the other slots; use your real spells on a target dummy.")

    -- page tabs; right above the map: the map picker (editing) or its name
    f.tabs = {}
    f.addPage = UI():CreateSleekButton(c, "+", 24, 20, function() Board:AddPage() end)
    tipButton(f.addPage, "Add a page", "For another phase of the fight. It starts with the same map.")
    f.mapLabel = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.mapLabel:SetPoint("TOPRIGHT", c, "TOPLEFT", MAP_W, -40)
    f.mapLabel:SetJustifyH("RIGHT")
    f.mapBtn = UI():CreateSleekMenuButton(c, "Map", 240, function(root)
        local p = page()
        if not p then return end
        MapUI():BuildMapMenu(root, st.strat.b, p.m, function(id)
            p.m = id
            p.vx, p.vy, p.vz = 500, 500, 100
            Board:MarkDirty(true)
        end, promptFn)
    end)
    f.mapBtn:SetPoint("TOPRIGHT", c, "TOPLEFT", MAP_W, -33)

    -- the map
    f.canvas = MapUI():CreateCanvas(c, MAP_W, {
        editable = function() return st.mode == "edit" end,
        onChange = function() Board:MarkDirty(true) end,
        onSelect = function() Board:RefreshTools() end,
        slotText = function(ref) return Board:SlotTokenText(ref) end,
        slotTip = function(ref, tt) Board:LinkTooltip(ref, tt) end,
        linkText = function(ref) return Board:LinkText(ref) end,
        dropRef = function() return win.blocks:RefUnderCursor() end,
        onDropTarget = function(list, e, t) Board:DropOnTarget(list, e, t) end,
        validRef = function(ref) return Board:ValidRef(ref) end,
        onHover = function(ref) win.blocks:Highlight(ref) end,
        slots = function() return S():GetSlots(st.strat) end,
        links = function() return Board:LinkTargets() end,
        prompt = promptFn,
        bossRef = function() return st.strat and st.strat.b end,
    })
    f.canvas.frame:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -TOP_H)
    local border = CreateFrame("Frame", nil, c, "BackdropTemplate")
    border:SetPoint("TOPLEFT", f.canvas.frame, "TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", f.canvas.frame, "BOTTOMRIGHT", 2, -2)
    if border.SetBackdrop then
        border:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
        border:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
    end
    border:SetFrameLevel(f.canvas.frame:GetFrameLevel() + 5)
    border:EnableMouse(false)

    -- the blocks
    f.blocks = ns.StrategyBlocksUI:Create(c, {
        mode = function() return st.mode end,
        page = page,
        strat = function() return st.strat end,
        assigned = function(ref) return st.assign[ref] end,
        memberInfo = function(key)
            return { c = classOf(key), missing = st.occ ~= nil and memberSet[key] == nil }
        end,
        isDup = function(ref) return dups[ref] == true end,
        onAssign = function(ref, key) Board:Assign(ref, key) end,
        picked = function() return st.picked end,
        members = function() return memberList end,
        countOf = countOf,
        onChange = function() Board:MarkDirty(true) end,
        onHover = function(ref) win.canvas:Highlight(ref) end,
        prompt = promptFn,
        slotName = function(ref) return st.assign[ref] and coloredName(st.assign[ref]) or nil end,
        slotLabel = function(ref) return slotLabels[ref] or ref end,
        onCellDragStart = function(ref)
            local g = ensureGhost()
            g.fs:SetText("Show " .. (slotLabels[ref] or ref) .. " on the map")
            g:SetWidth((g.fs:GetStringWidth() or 100) + 8)
            g:Show()
        end,
        onCellDrop = function(ref)
            if ghost then ghost:Hide() end
            local _, target = win.blocks:RefUnderCursor()
            if target then
                Board:TargetShowsSlot(target, ref)
            elseif win.canvas.frame:IsMouseOver() then
                win.canvas:DropRefAtCursor(ref)
            end
        end,
    })
    f.blocks.width = WIN_W - MAP_W - 30
    f.blocks.scroll:SetPoint("TOPLEFT", c, "TOPLEFT", MAP_W + 10, -TOP_H)
    f.blocks.scroll:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -24, 2)

    -- below the map: tools (edit) / the raid's players (fill) / your jobs (view)
    local below = CreateFrame("Frame", nil, c)
    below:SetPoint("TOPLEFT", f.canvas.frame, "BOTTOMLEFT", 0, -8)
    below:SetPoint("BOTTOMRIGHT", c, "BOTTOMLEFT", MAP_W, 2)
    f.below = below

    local tools = CreateFrame("Frame", nil, below)
    tools:SetAllPoints()
    f.tools = tools
    -- row 1: the tools as icons (select / pan | shapes), undo / redo, the colours, and the keyboard help
    tools.btns = {}
    local prev
    for i, t in ipairs(MapUI().TOOLS) do
        local b = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(TOOL_ICON[t.key] or 11), function()
            win.canvas:SetTool(t.key)
            Board:RefreshTools()
        end)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", i == 3 and 10 or 2, 0)
        else
            b:SetPoint("TOPLEFT", 0, 0)
        end
        b.key = t.key
        tipButton(b, t.label, t.tip)
        tools.btns[#tools.btns + 1] = b
        prev = b
    end
    tools.undoBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(9), function() Board:Undo() end)
    tools.undoBtn:SetPoint("LEFT", prev, "RIGHT", 16, 0)
    tipButton(tools.undoBtn, "Undo", "Ctrl+Z")
    tools.redoBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(10), function() Board:Redo() end)
    tools.redoBtn:SetPoint("LEFT", tools.undoBtn, "RIGHT", 2, 0)
    tipButton(tools.redoBtn, "Redo", "Ctrl+Y or Ctrl+Shift+Z")
    tools.swatches = {}
    for i = 1, #MapUI().COLORS do
        local sw = CreateFrame("Button", nil, tools)
        sw:SetSize(20, 20)
        if i == 1 then
            sw:SetPoint("LEFT", tools.redoBtn, "RIGHT", 16, 0)
        else
            sw:SetPoint("LEFT", tools.swatches[i - 1], "RIGHT", 1, 0)
        end
        sw.tex = sw:CreateTexture(nil, "ARTWORK")
        sw.tex:SetPoint("TOPLEFT", 3, -3)
        sw.tex:SetPoint("BOTTOMRIGHT", -3, 3)
        sw.tex:SetColorTexture(MapUI():Color(i))
        sw.sel = sw:CreateTexture(nil, "BACKGROUND")
        sw.sel:SetAllPoints()
        sw.sel:SetColorTexture(1, 0.82, 0, 1)
        tipButton(sw, "Colour", "For new drawings, and the selected one.")
        sw:SetScript("OnClick", function()
            win.canvas:SetColor(i)
            local e = win.canvas:GetSelected()
            if e and e.t ~= "s" then
                e.c = i
                win.canvas:Changed()
            end
            Board:RefreshTools()
        end)
        tools.swatches[i] = sw
    end
    tools.helpBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(11), nil)
    tools.helpBtn:SetPoint("TOPRIGHT", 0, 0)
    tools.helpBtn:SetScript("OnEnter", function(self)
        self.hovered = true
        self:SetActive(false)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Keyboard and mouse")
        for _, row in ipairs(SHORTCUTS) do GameTooltip:AddDoubleLine(row[1], row[2], 1, 0.82, 0, 1, 1, 1) end
        GameTooltip:Show()
    end)
    tools.helpBtn:SetScript("OnLeave", function(self)
        self.hovered = false
        self:SetActive(false)
        GameTooltip:Hide()
    end)

    -- row 2: what is selected (or the drawing count), and the selection's actions
    tools.info = tools:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tools.info:SetPoint("TOPLEFT", 0, -TOOL_SIZE - 12)
    tools.info:SetPoint("RIGHT", tools, "RIGHT", -70, 0)
    tools.info:SetWordWrap(false)
    tools.info:SetJustifyH("LEFT")
    tools.delBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(12), function()
        local e = win.canvas:GetSelected()
        if e then win.canvas:Remove(e) end
    end)
    tools.delBtn:SetPoint("TOPRIGHT", 0, -TOOL_SIZE - 6)
    tipButton(tools.delBtn, "Delete", "Removes the selected drawings (Del).")
    tools.optBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(13), function()
        local e = win.canvas:GetSelected()
        if e then win.canvas:ElementMenu(e) end
    end)
    tools.optBtn:SetPoint("RIGHT", tools.delBtn, "LEFT", -2, 0)
    tipButton(tools.optBtn, "Options", "Label, size, link to a job... (also on right-click).")

    local pool = CreateFrame("Frame", nil, below)
    pool:SetAllPoints()
    f.pool = pool
    pool.label = pool:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pool.label:SetPoint("TOPLEFT", 0, -4)
    pool.carryBtn = UI():CreateSleekButton(pool, "Carry over", 86, 22, function() Board:CarryOver() end)
    pool.carryBtn:SetPoint("TOPRIGHT", 0, 0)
    tipButton(pool.carryBtn, "Carry over", "Start from the names of the last raid that used this strategy. Players who aren't in this raid are shown in red.")
    pool.suggestBtn = UI():CreateSleekButton(pool, "Suggest fill", 90, 22, function() Board:Suggest() end)
    pool.suggestBtn:SetPoint("RIGHT", pool.carryBtn, "LEFT", -4, 0)
    tipButton(pool.suggestBtn, "Suggest fill", "Fills the empty slots that are limited to a class or role with players who fit, spreading the jobs. Slots open to anyone stay for you.")
    pool.clearBtn = UI():CreateSleekButton(pool, "Clear all", 76, 22, function() Board:ClearAll() end)
    pool.clearBtn:SetPoint("RIGHT", pool.suggestBtn, "LEFT", -4, 0)
    pool.chips = {}
    pool.empty = pool:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    pool.empty:SetPoint("TOPLEFT", 0, -34)
    pool.empty:SetJustifyH("LEFT")

    local view = CreateFrame("Frame", nil, below)
    view:SetAllPoints()
    f.view = view
    view.mine = view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    view.mine:SetPoint("TOPLEFT", 0, -4)
    view.mine:SetPoint("RIGHT", 0, 0)
    view.mine:SetJustifyH("LEFT")
    view.mine:SetJustifyV("TOP")

    -- keyboard: only while editing / assigning; unused keys go on to the game
    f:EnableKeyboard(false)
    f:SetScript("OnKeyDown", function(self, key)
        local handled = false
        local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
        if not focus then handled = Board:OnKey(key) end
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(not handled) end
    end)
    f:SetScript("OnHide", function()
        if prompt then prompt:Hide() end
        if ghost then ghost:Hide() end
    end)
    f:Hide()
    return f
end

local function ensureWindow()
    return win or createWindow()
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

-- Runs fn now, or after the user agrees to drop unsaved changes.
local function whenClean(fn)
    if not st.dirty then return fn() end
    ns.RaidPlanUI:Confirm("Drop the unsaved changes on the strategy board?", function()
        st.dirty = false
        fn()
    end)
end

local function show()
    ensureWindow()
    -- the board is big: shrink it to fit smaller screens / larger UI scales (the tool rows sit at its bottom)
    local sw, sh = UIParent:GetWidth() or WIN_W, UIParent:GetHeight() or WIN_H
    win:SetScale(math.min(1, (sw - 20) / WIN_W, (sh - 20) / WIN_H))
    win:Show()
    win:Raise()
    Board:Refresh()
end

-- A strategy on its own (view; authors can Edit).
function Board:OpenStrategy(id, mode)
    if st.dirty and st.strat and st.strat.id == id and not st.occ then return show() end
    whenClean(function()
        local s = S():GetStrategy(id)
        if not s then
            ns:Print("That strategy no longer exists.")
            return
        end
        st.strat, st.occ, st.boss, st.page = s, nil, s.b, 1
        st.assign, st.dirty, st.picked = {}, false, nil
        st.mode = (mode == "edit" and canEdit()) and "edit" or "view"
        Board:ResetHistory()
        show()
    end)
end

-- The starter strategy of a boss (Data/StarterStrategies.lua) as a draft: map file names -> map ids, "@Creature"
-- icon keys -> that creature's portrait. nil when the boss has none.
function Board:StarterDraft(bossRef)
    local src = ns.Data and ns.Data.StarterStrategies and ns.Data.StarterStrategies[bossRef]
    if not src then return nil end
    local d = ns.Util.CopyTable(src)
    d.b = bossRef
    local portraits = {}
    local raidKey = bossRef:match("^(%w+):")
    for ref, list in pairs(ns.Data.BossPortraits or {}) do
        if ref:match("^(%w+):") == raidKey then
            for _, c in ipairs(list) do portraits[c.n] = portraits[c.n] or c.d end
        end
    end
    local function icon(key)
        local name = type(key) == "string" and key:match("^@(.+)$")
        if not name then return key end
        return portraits[name] and ("boss:" .. portraits[name]) or "rt8"
    end
    for _, p in ipairs(d.p or {}) do
        if p.map then
            p.m = 0
            for _, m in ipairs(ns.Data.RaidMaps or {}) do
                if m.file == p.map then p.m = m.id end
            end
            p.map = nil
        end
        p.m = p.m or 0
        for _, e in ipairs(p.e or {}) do
            if e.i then e.i = icon(e.i) end
        end
        for _, k in ipairs(p.k or {}) do
            if k.i then k.i = icon(k.i) end
            for _, cells in pairs(k.d or {}) do
                for _, v in pairs(cells) do
                    if type(v) == "table" and v.i then v.i = icon(v.i) end
                end
            end
        end
    end
    return d
end

-- A new strategy for a boss (authors): its starter (the floor map framed on the room, the creatures where they
-- stand) when it has one, else a blank page on the boss' floor.
function Board:NewStrategy(bossRef, name)
    if not canEdit() then
        ns:Print("Only the Guild Master, the guild council and the raid leaders can build strategies.")
        return
    end
    whenClean(function()
        local d = self:StarterDraft(bossRef)
        if d then
            d.n = name or "Strategy"
        else
            d = S():NewDraft(bossRef, name or "Strategy", MapUI():DefaultMap(bossRef))
        end
        st.strat = d
        st.occ, st.boss, st.page, st.assign, st.picked = nil, bossRef, 1, {}, nil
        st.mode = "edit"
        st.dirty = true
        Board:ResetHistory()
        show()
    end)
end

-- A raid's board for a boss: the chosen (or only) strategy with that raid's names.
function Board:OpenRaid(occId, bossRef, mode)
    if st.dirty and st.occ == occId and st.boss == bossRef then return show() end
    whenClean(function()
        local s, fill = S():GetRaidStrategy(occId, bossRef)
        st.occ, st.boss, st.page, st.picked = occId, bossRef, 1, nil
        st.strat = s
        st.assign = (s and fill and fill.s == s.id) and S():ValidAssignments(s, fill.a) or {}
        st.dirty = false
        st.mode = (mode == "fill" and canEdit() and s) and "fill" or "view"
        Board:ResetHistory()
        show()
    end)
end

function Board:Close()
    if win then win:Hide() end
end

function Board:IsShown() return win ~= nil and win:IsShown() end

function Board:GetState() return st end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Board:MarkDirty(repaint)
    st.dirty = true
    self:Record()
    if repaint ~= false then self:Refresh() end
end

---------------------------------------------------------------------------
-- Undo / redo: snapshots of the draft (editing) or of the names (assigning)
---------------------------------------------------------------------------

local HISTORY_MAX = 60

local function snapshot()
    if st.mode == "edit" then return st.strat and ns.Util.CopyTable(st.strat) end
    if st.mode == "fill" then return ns.Util.CopyTable(st.assign) end
    return nil
end

function Board:ResetHistory()
    st.hist, st.histI = {}, 0
    local snap = snapshot()
    if snap then st.hist[1], st.histI = snap, 1 end
end

function Board:Record()
    local snap = snapshot()
    if not snap then return end
    st.hist = st.hist or {}
    for i = #st.hist, (st.histI or 0) + 1, -1 do st.hist[i] = nil end
    st.hist[#st.hist + 1] = snap
    if #st.hist > HISTORY_MAX then tremove(st.hist, 1) end
    st.histI = #st.hist
end

local function restore(i)
    local snap = st.hist and st.hist[i]
    if not snap then return false end
    st.histI = i
    if st.mode == "edit" then
        st.strat = ns.Util.CopyTable(snap)
        if not st.strat.p[st.page] then st.page = 1 end
    elseif st.mode == "fill" then
        st.assign = ns.Util.CopyTable(snap)
    end
    st.dirty = true
    Board:Refresh()
    return true
end

function Board:Undo()
    if (st.histI or 0) <= 1 then return false end
    return restore(st.histI - 1)
end

function Board:Redo()
    if not st.hist or (st.histI or 0) >= #st.hist then return false end
    return restore(st.histI + 1)
end

function Board:CanUndo() return (st.histI or 0) > 1 end
function Board:CanRedo() return st.hist ~= nil and (st.histI or 0) < #st.hist end

-- A key while the board has the keyboard. Returns true when used.
function Board:OnKey(key)
    if st.mode ~= "edit" and st.mode ~= "fill" then return false end
    if IsControlKeyDown() then
        if key == "Z" then
            if IsShiftKeyDown() then return self:Redo() end
            return self:Undo()
        end
        if key == "Y" then return self:Redo() end
    end
    if st.mode == "edit" and win then
        -- the arrows move the character unless something is selected; Del only with a selection
        return win.canvas:OnKey(key)
    end
    return false
end

function Board:SetMode(mode)
    if not canEdit() then return end
    if mode == "edit" then
        if st.occ then
            -- edit the strategy itself (the raid's names stay)
            st.occ = nil
            st.assign = {}
        end
        st.mode = "edit"
    elseif mode == "fill" then
        if not (st.occ and st.strat) then return end
        st.mode = "fill"
    end
    self:ResetHistory()
    self:Refresh()
end

function Board:RenameStrategy()
    if st.mode ~= "edit" or not st.strat then return end
    self:Prompt("Strategy name", st.strat.n, function(text)
        text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
        if text ~= "" then
            st.strat.n = text
            Board:MarkDirty()
        end
    end)
end

function Board:CancelChanges()
    local occ, boss, id = st.occ, st.boss, st.strat and st.strat.id
    st.dirty = false
    if occ then
        self:OpenRaid(occ, boss)
    elseif id then
        self:OpenStrategy(id)
    else
        self:Close()
    end
end

function Board:Save()
    if st.mode == "edit" then
        local ok, res = S():SaveStrategy(st.strat)
        if not ok then
            ns:Print("Could not save the strategy: %s", tostring(res))
            return false
        end
        st.dirty = false
        local s = S():GetStrategy(res)
        st.strat = s or st.strat
        st.mode = "view"
        ns:Print("Strategy saved: %s.", st.strat.n)
    elseif st.mode == "fill" then
        local ok, err = S():SaveFill(st.occ, st.boss, st.strat.id, st.assign)
        if not ok then
            ns:Print("Could not save the assignments: %s", tostring(err))
            return false
        end
        st.dirty = false
        st.mode = "view"
        st.picked = nil
        ns:Print("Assignments saved for %s.", S():GetBossName(st.boss))
    end
    self:ResetHistory()
    self:Refresh()
    return true
end

function Board:Assign(ref, key)
    if st.mode ~= "fill" then return end
    st.assign[ref] = key
    st.picked = nil
    self:MarkDirty(true)
end

function Board:CarryOver()
    if st.mode ~= "fill" then return end
    local a = S():GetLastFill(st.strat.id, st.occ)
    if not a then
        ns:Print("No earlier raid used this strategy yet.")
        return
    end
    st.assign = S():ValidAssignments(st.strat, a)
    self:MarkDirty(true)
end

function Board:Suggest()
    if st.mode ~= "fill" then return end
    local a, n = S():SuggestFill(st.strat, st.assign, memberList)
    st.assign = a
    if n == 0 then ns:Print("No empty class / role slot could be filled from this raid's players.") end
    self:MarkDirty(true)
end

function Board:ClearAll()
    if st.mode ~= "fill" then return end
    st.assign = {}
    self:MarkDirty(true)
end

-- fill: switch the raid to another strategy of the boss (names of matching slots are kept).
function Board:UseStrategy(id)
    local s = S():GetStrategy(id)
    if not s then return end
    st.strat = s
    st.page = 1
    st.assign = S():ValidAssignments(s, st.assign)
    if st.mode ~= "fill" then
        st.mode = canEdit() and "fill" or "view"
    end
    self:MarkDirty(true)
end

function Board:StrategyMenu(root)
    root:CreateTitle(S():GetBossName(st.boss))
    for _, s in ipairs(S():GetStrategies(st.boss)) do
        root:CreateRadio(s.n, function() return st.strat and st.strat.id == s.id end, function() Board:UseStrategy(s.id) end)
    end
    if canEdit() then
        root:CreateDivider()
        root:CreateButton("New strategy for this boss...", function()
            Board:Prompt("Name of the new strategy", "", function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_NAME_LEN)
                if text ~= "" then Board:NewStrategy(st.boss, text) end
            end)
        end)
    end
end

-- Pages
function Board:AddPage()
    if st.mode ~= "edit" then return end
    local pages = st.strat.p
    if #pages >= S().MAX_PAGES then
        ns:Print("A strategy holds at most %d pages.", S().MAX_PAGES)
        return
    end
    local cur = page()
    local id = S():NewPartId(st.strat, "p")
    tinsert(pages, { id = id, n = "P" .. (#pages + 1), m = cur and cur.m or 0, vx = cur and cur.vx, vy = cur and cur.vy,
                     vz = cur and cur.vz, e = {}, k = {} })
    st.page = #pages
    self:MarkDirty(true)
end

function Board:PageMenu(owner, i)
    local pages = st.strat.p
    local p = pages[i]
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(p.n)
        root:CreateButton("Rename...", function()
            Board:Prompt("Page name (e.g. P2, Transition)", p.n, function(text)
                text = ns.Util.Trim((text or ""):gsub("|", "")):sub(1, S().MAX_PAGE_NAME)
                if text ~= "" then p.n = text; Board:MarkDirty(true) end
            end)
        end)
        if #pages < S().MAX_PAGES then
            root:CreateButton("Duplicate (drawings only)", function()
                local c = ns.Util.CopyTable(p)
                c.id = S():NewPartId(st.strat, "p")
                c.n = (p.n .. " copy"):sub(1, S().MAX_PAGE_NAME)
                c.k = {}
                -- the blocks stay on the original page: tokens keep pointing at them
                tinsert(pages, i + 1, c)
                st.page = i + 1
                Board:MarkDirty(true)
            end)
        end
        if i > 1 then
            root:CreateButton("Move left", function()
                pages[i], pages[i - 1] = pages[i - 1], pages[i]
                st.page = i - 1
                Board:MarkDirty(true)
            end)
        end
        if i < #pages then
            root:CreateButton("Move right", function()
                pages[i], pages[i + 1] = pages[i + 1], pages[i]
                st.page = i + 1
                Board:MarkDirty(true)
            end)
        end
        if #pages > 1 then
            root:CreateButton("|cffff6060Delete page|r", function()
                tremove(pages, i)
                st.page = min(st.page, #pages)
                Board:MarkDirty(true)
            end)
        end
    end)
end

-- Link targets for zones: every block, and every block's columns.
function Board:LinkTargets()
    local out = {}
    for _, p in ipairs(st.strat and st.strat.p or {}) do
        for _, k in ipairs(p.k or {}) do
            out[#out + 1] = { ref = k.id, label = k.n }
            for ci, c in ipairs(k.c) do
                if c.t == "p" then
                    local col = c.n or ("column " .. ci)
                    out[#out + 1] = { ref = k.id .. "." .. ci, label = k.n .. " · " .. col, col = col }
                end
            end
        end
    end
    return out
end

function Board:SlotTokenText(ref)
    local key = st.assign[ref]
    if key and st.mode ~= "edit" then
        local name = coloredName(key)
        if st.occ and not memberSet[key] then name = "|cffff5050" .. shortName(key) .. "|r" end
        return name
    end
    local label = slotLabels[ref]
    if not label then return "|cffff5050?|r" end
    -- no name yet: the job without the table's name, kept short (the tooltip has the rest)
    local sep = label:find(" \194\183 ", 1, true)
    if sep then label = label:sub(sep + 4) end
    if #label > 26 then label = label:sub(1, 24) .. "..." end
    return "|cffd0d0d0" .. label .. "|r"
end

-- A block reference in words: "Tanks · Gathios · Player", "Zones · Zone 1", "Tanks".
function Board:LinkLabel(ref)
    if slotLabels[ref] then return slotLabels[ref] end
    local b, c = tostring(ref):match("^(%w+)%.(%d+)$")
    local k = S():FindBlock(st.strat, b or ref)
    if not k then return tostring(ref) end
    if c then
        local col = k.c[tonumber(c)]
        return k.n .. " · " .. ((col and col.n) or ("column " .. c))
    end
    return k.n
end

-- The player slots a reference covers (one slot, a column's slots, or a block's).
local function slotsOf(ref)
    local out = {}
    for _, sl in ipairs(S():GetSlots(st.strat)) do
        if MapUI():RefsOverlap(ref, sl.ref) then out[#out + 1] = sl end
    end
    return out
end

-- The text under a linked drawing: editing, the link itself; otherwise the names assigned to it.
function Board:LinkText(ref)
    if not st.strat then return nil end
    if st.mode == "edit" then return "|cffb0b0b0-> " .. self:LinkLabel(ref) .. "|r" end
    local names = {}
    for _, sl in ipairs(slotsOf(ref)) do
        local key = st.assign[sl.ref]
        if key then
            local name = coloredName(key)
            if st.occ and not memberSet[key] then name = "|cffff5050" .. shortName(key) .. "|r" end
            names[#names + 1] = name
        end
    end
    if #names == 0 then return nil end
    if #names > 6 then
        local n = #names
        for i = n, 6, -1 do names[i] = nil end
        names[#names + 1] = grey("+" .. (n - 5))
    end
    return tconcat(names, ", ")
end

function Board:LinkTooltip(ref, tt)
    tt:AddLine(self:LinkLabel(ref), 1, 0.82, 0)
    local any = false
    for _, sl in ipairs(slotsOf(ref)) do
        local key = st.assign[sl.ref]
        if key then
            any = true
            tt:AddLine(coloredName(key) .. (sl.ref ~= ref and grey("  " .. sl.label) or ""))
        end
    end
    if not any and st.mode ~= "edit" then tt:AddLine("Not assigned", 0.6, 0.6, 0.6) end
    if st.mode == "edit" then tt:AddLine("Right-click > Link to assignment to change it.", 0.6, 0.6, 0.6, true) end
end

function Board:SlotTooltip(ref, tt) return self:LinkTooltip(ref, tt) end

-- A player cell dropped on a Target cell: the target also shows that slot's player (e.g. a misdirect row's
-- "Attumen -> <tank 1>"); its icon and label stay.
function Board:TargetShowsSlot(t, ref)
    if st.mode ~= "edit" then return end
    local k, row, ci = t.k, t.row, t.col
    local cur = k.d and k.d[row] and k.d[row][ci]
    local cell = {}
    for key, v in pairs(type(cur) == "table" and cur or {}) do cell[key] = v end
    cell.s = ref
    k.d = k.d or {}
    k.d[row] = k.d[row] or {}
    k.d[row][ci] = cell
    self:MarkDirty(true)
end

-- A drawing dropped on a Target cell: the cell shows its icon and name, and the drawing (with its group) links to
-- that row's player, so the map shows who handles it (e.g. Attumen -> the tank of that row).
function Board:DropOnTarget(list, e, t)
    if st.mode ~= "edit" then return end
    local k, row, ci = t.k, t.row, t.col
    local cur = k.d and k.d[row] and k.d[row][ci]
    local cell = {}
    for key, v in pairs(type(cur) == "table" and cur or {}) do cell[key] = v end
    local icon
    for _, m in ipairs(list) do
        if not icon and m.t == "i" then icon = m end
    end
    local src = (e.t == "i" and e) or icon
    if src then cell.i = src.i end
    local label = e.l or (src and src.l) or (src and MapUI():IconName(src.i))
    if label and label ~= "" then cell.l = label:sub(1, S().MAX_CELL) end
    k.d = k.d or {}
    k.d[row] = k.d[row] or {}
    k.d[row][ci] = next(cell) and cell or nil
    local ref
    for c2, col in ipairs(k.c) do
        if col.t == "p" then
            ref = S().SlotRef(k.id, row, c2)
            break
        end
    end
    if ref then
        win.canvas:LinkList(list, ref)      -- repaints and records the change
    else
        self:MarkDirty(true)
    end
end

-- Does a block reference exist in the shown strategy (pasting from another one)?
function Board:ValidRef(ref)
    local b, r, c = MapUI().ParseRef(ref)
    local k = b and S():FindBlock(st.strat, b)
    if not k then return false end
    if r and r > k.r then return false end
    if c and not k.c[c] then return false end
    return true
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function Board:RefreshTools()
    if not win then return end
    local tools = win.tools
    for _, b in ipairs(tools.btns) do b:SetActive(b.key == win.canvas.tool) end
    for i, sw in ipairs(tools.swatches) do sw.sel:SetShown(i == win.canvas.color) end
    local p = page()
    local mapText = "Map: " .. MapUI():MapName(p and p.m)
    if win.mapBtn.SetDefaultText then win.mapBtn:SetDefaultText(mapText) end
    if win.mapBtn.SetText and not win.mapBtn.SetDefaultText then win.mapBtn:SetText(mapText) end
    local e = win.canvas:GetSelected()
    local count = win.canvas:SelectionCount()
    -- the selection's actions only while something is selected
    tools.delBtn:SetShown(e ~= nil)
    tools.optBtn:SetShown(e ~= nil)
    tools.undoBtn:SetEnabled(self:CanUndo())
    tools.redoBtn:SetEnabled(self:CanRedo())
    local n = p and #p.e or 0
    local info
    if e and count > 1 then
        info = ("Selected: %d drawings%s"):format(count, e.g and " (a group)" or "") ..
            grey("  \194\183  Ctrl+G groups them")
    elseif e then
        local names = { z = "Zone", a = e.h and "Arrow" or "Line", i = "Icon", x = "Text", s = "Name marker" }
        local link = win.canvas:LinkOf(e)
        info = "Selected: " .. (names[e.t] or "?") .. (e.l and (" \"" .. e.l .. "\"") or "") ..
            (link and ("  |cff33ff99-> " .. self:LinkLabel(link) .. "|r") or grey("  not linked"))
    else
        info = grey(("%d / %d drawings  \194\183  right-click the map to add"):format(n, S().MAX_ELEMENTS))
    end
    tools.info:SetText(info)
end

function Board:RefreshPool()
    if not win then return end
    local pool = win.pool
    local list = {}
    for _, m in ipairs(memberList) do list[#list + 1] = m end
    tsort(list, function(a, b)
        local ra = ns.RaidComp and ns.RaidComp:RoleOf(a.c, a.sp) or "z"
        local rb = ns.RaidComp and ns.RaidComp:RoleOf(b.c, b.sp) or "z"
        local order = { tank = 1, healer = 2, melee = 3, ranged = 4, z = 5 }
        if order[ra] ~= order[rb] then return order[ra] < order[rb] end
        if (a.c or "") ~= (b.c or "") then return (a.c or "") < (b.c or "") end
        return a.key < b.key
    end)
    local filled, total = 0, 0
    for _, s in ipairs(S():GetSlots(st.strat)) do
        total = total + 1
        if st.assign[s.ref] then filled = filled + 1 end
    end
    pool.label:SetText(("This raid's players  " .. grey("(%d / %d slots filled)")):format(filled, total))
    for i, m in ipairs(list) do
        local chip = pool.chips[i]
        if not chip then
            chip = createPoolChip(pool)
            pool.chips[i] = chip
        end
        chip.key = m.key
        chip:ClearAllPoints()
        local col, row = (i - 1) % POOL_COLS, floor((i - 1) / POOL_COLS)
        chip:SetPoint("TOPLEFT", pool, "TOPLEFT", col * CHIP_W, -28 - row * CHIP_H)
        UI():ClassIcon(chip.icon, m.c)
        local name = coloredName(m.key)
        if m.st == "T" or m.st == "B" then name = name .. grey(m.st == "T" and " (T)" or " (B)") end
        chip.fs:SetText(name)
        local n = countOf(m.key)
        chip.count:SetText(n > 0 and tostring(n) or "")
        chip.picked:SetShown(st.picked == m.key)
        chip:Show()
    end
    for i = #list + 1, #pool.chips do pool.chips[i]:Hide() end
    pool.empty:SetShown(#list == 0)
    pool.empty:SetText("Nobody has signed up for this raid yet (and you're not in a raid group).")
end

function Board:RefreshTabs()
    local c = win.content
    local pages = st.strat and st.strat.p or {}
    local x = 0
    for i, p in ipairs(pages) do
        local b = win.tabs[i]
        if not b then
            b = UI():CreateSleekButton(c, "", 60, 20, nil)
            b:GetFontString():SetFontObject("GameFontHighlightSmall")
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            win.tabs[i] = b
        end
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" and st.mode == "edit" then
                Board:PageMenu(self, i)
            else
                st.page = i
                Board:Refresh()
            end
        end)
        b:SetText(p.n)
        local w = max(40, (b:GetFontString() and b:GetFontString():GetStringWidth() or 30) + 20)
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", c, "TOPLEFT", x, -34)
        -- the page shown is the gold tab; a single page needs no tab strip unless it can grow
        b:SetKind(i == st.page and "primary" or "secondary")
        b:SetShown(#pages > 1 or st.mode == "edit")
        x = x + w + 3
    end
    for i = #pages + 1, #win.tabs do win.tabs[i]:Hide() end
    win.addPage:ClearAllPoints()
    win.addPage:SetPoint("TOPLEFT", c, "TOPLEFT", x + 2, -34)
    win.addPage:SetShown(st.mode == "edit")
end

function Board:Refresh()
    if not win or not win:IsShown() then return end
    if st.strat and not st.strat.p[st.page] then st.page = 1 end
    rebuildSlots()
    rebuildMembers()
    rebuildDups()
    local s = st.strat
    local mode = st.mode
    local editor = canEdit()
    local v = raidView()
    -- title
    local bossName = S():GetBossName(st.boss or (s and s.b))
    if s then
        win.title:SetText(bossName .. grey("  \194\183  ") .. "|cffffffff" .. s.n .. "|r" ..
            (mode == "edit" and "  |cff33ff99editing|r" or (mode == "fill" and "  |cff33ff99assigning|r" or "")))
    else
        win.title:SetText(bossName .. "  " .. grey("no strategy yet"))
    end
    win.title:SetWidth(0)
    if (win.title:GetStringWidth() or 0) > 560 then win.title:SetWidth(560) end
    win.titleBtn:SetShown(mode == "edit" and s ~= nil)
    local sub = {}
    if v then sub[#sub + 1] = ns.RaidPlan:GetRaidName(v) .. " · " .. date("%a %d %b %H:%M", v.t) end
    if s and s.by then sub[#sub + 1] = "strategy by " .. shortName(s.by) .. (s.rev and (", " .. date("%d %b", s.rev)) or "") end
    if st.dirty then sub[#sub + 1] = "|cffff9933unsaved changes|r" end
    win.sub:SetText(grey(tconcat(sub, "  ·  ")))
    win:SetWindowTitle("Strategy board")

    -- header actions, right to left: the main action (gold) at the far right
    local header
    if mode == "edit" then
        header = { win.saveBtn, win.cancelBtn, s and win.practiceBtn, win.autoMark }
    elseif mode == "fill" then
        header = { win.saveBtn, win.cancelBtn, win.stratDD, s and win.practiceBtn }
    else
        local canFill = editor and s ~= nil and st.occ ~= nil
        header = { canFill and win.fillBtn, editor and s and win.editBtn, st.occ and win.stratDD, s and win.practiceBtn }
        -- the edit button is the main action when there is nothing to assign
        win.editBtn:SetKind(canFill and "secondary" or "primary")
    end
    for _, w in ipairs({ win.saveBtn, win.cancelBtn, win.practiceBtn, win.autoMark, win.editBtn, win.fillBtn,
                         win.stratDD }) do
        w:Hide()
    end
    local prev
    for i = 1, 4 do
        local w = header[i]
        if w then
            w:ClearAllPoints()
            local gap = (w == win.practiceBtn or w == win.stratDD) and 14 or 6
            if w == win.autoMark then
                -- a checkbox: its label reaches to the right of the box
                w:SetPoint("RIGHT", prev, "LEFT", -((w.label:GetStringWidth() or 60) + 18), 0)
            elseif prev then
                w:SetPoint("RIGHT", prev, "LEFT", -gap, 0)
            else
                w:SetPoint("TOPRIGHT", -2, -2)
            end
            w:Show()
            prev = w
        end
    end
    if win.autoMark.Refresh then win.autoMark:Refresh() end
    if win.stratDD:IsShown() then
        local label = s and ("Strategy: " .. s.n) or "Pick a strategy"
        if win.stratDD.SetDefaultText then win.stratDD:SetDefaultText(label) end
        if win.stratDD.Refresh then win.stratDD:Refresh() end
    end

    self:RefreshTabs()
    local p = page()
    win.mapLabel:SetText(p and grey(MapUI():MapName(p.m)) or "")
    win.mapLabel:SetShown(mode ~= "edit")
    win.mapBtn:SetShown(mode == "edit")
    win.canvas:SetPage(p)
    win.canvas:UpdateHint()
    win.blocks:Render()

    win.tools:SetShown(mode == "edit")
    win:EnableKeyboard((mode == "edit" or mode == "fill") and not InCombatLockdown())
    win.pool:SetShown(mode == "fill")
    win.view:SetShown(mode == "view")
    if mode == "edit" then
        self:RefreshTools()
    elseif mode == "fill" then
        self:RefreshPool()
    else
        local lines = {}
        if not s then
            lines[1] = grey("There is no strategy for this boss yet.") ..
                (editor and "\nUse the Strategy menu (top right) to make one." or "")
        elseif st.occ then
            local me = ns.Util.PlayerKey()
            local jobs = {}
            for _, slot in ipairs(S():GetPlayerSlots(s, st.assign, me)) do
                jobs[#jobs + 1] = (#s.p > 1 and (slot.pageName .. ": ") or "") .. slot.label
            end
            lines[1] = "|cffffd100Your jobs|r  " .. (#jobs > 0 and tconcat(jobs, "\n") or grey("none on this board"))
            local filled = 0
            for _ in pairs(st.assign) do filled = filled + 1 end
            if filled == 0 then lines[2] = grey("No players assigned for this raid yet.") end
        else
            lines[1] = grey("This is the strategy on its own. Open it from a raid (Raids > Upcoming > Assignments) to see who does what.")
        end
        win.view.mine:SetText(tconcat(lines, "\n"))
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Board:OnInit()
    local function refresh()
        if not (win and win:IsShown()) then return end
        -- a newer saved copy of what I'm looking at replaces it (never my unsaved draft)
        if not st.dirty and st.strat and st.strat.id then
            if st.occ then
                local s, fill = S():GetRaidStrategy(st.occ, st.boss)
                if s then
                    st.strat = s
                    st.assign = (fill and fill.s == s.id) and S():ValidAssignments(s, fill.a) or {}
                end
            else
                local s = S():GetStrategy(st.strat.id)
                if s then st.strat = s end
            end
        end
        ns.Util.Debounce("strategy-board", 0.2, function() Board:Refresh() end)
    end
    ns:On("STRATEGY_CHANGED", refresh)
    ns:On("RAIDPLAN_CHANGED", refresh)
    ns:On("ROSTER_UPDATED", refresh)
end

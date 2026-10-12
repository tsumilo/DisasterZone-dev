if DisasterZoneBoot and DisasterZoneBoot.Run("UI/StrategyBoard.lua", ...) then return end -- DisasterZone: UI/StrategyBoard.lua
-- The strategy board window (Addendum K): a strategy's pages, each a map (UI/StrategyMap.lua) with the assignment
-- blocks beside it (UI/StrategyBlocks.lua).
-- Modes:
--   view  - anyone: the board as drawn; opened from a raid it shows that raid's names and "your jobs".
--   edit  - its owner, the collaborators the owner invited, the GM and the guild council: draw on the map, shape the
--           blocks, add pages, then Save.
--   fill  - who leads the raid (its own leader, else the raid leaders) and the GM, from a raid: pick the strategy for
--           the boss and put players into the slots (carry over last raid's names, drag from the raid's players,
--           Suggest fill), then Save.
-- Unsaved work is a draft: it stays in the window while it is closed, stays behind (Raids > Strategies lists the
-- drafts) when something else is opened, and survives a /reload, a logout and a disconnect with its undo history.
-- Editing and assigning keep an undo history (Ctrl+Z, Ctrl+Y / Ctrl+Shift+Z); while editing the keyboard also drives
-- the map (Del, Ctrl+C / X / V / D / A / G, arrows; see UI/StrategyMap.lua). Keys the board doesn't use go on to the
-- game as usual.
local addonName, ns = ...

local Board = ns:NewModule("StrategyBoard")

local Style = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tinsert, tremove, tsort, tconcat = table.insert, table.remove, table.sort, table.concat

-- One grid, in the window's content (1330 x 698), on the tool layout (UI:CreateLayout "tool": PAD at the sides, GAP
-- between blocks). Its strip banner on top (the boss, the strategy, its state, the actions), the page tabs under it on
-- one rule, then the map and the panel of jobs side by side down to the dock's bottom; the dock (the tools, your
-- jobs, the raid's actions, the 2D / 3D switch) under the map. The map is the same size in every mode: nothing moves
-- when Edit or Assign players is clicked.
local WIN_W, WIN_H = 1340, 730
local CONTENT_W, CONTENT_H = WIN_W - 10, WIN_H - 32   -- (UI:CreateWindow's content: 5 in from the sides, 27 / 5)
local PAD, GAP = Style.PAD, Style.GAP
local HDR_Y, HDR_H = PAD, Style.BANNER.strip          -- the tool layout's banner: (10, 10), 46 high
local HDR_W = CONTENT_W - 2 * PAD                     -- 1310
local TABS_X, TABS_Y, TABS_H = 14, HDR_Y + HDR_H + GAP, 22   -- 64: where the tool layout's body starts
local RULE_Y = TABS_Y + TABS_H                        -- 86
local MAP_Y, MAP_W = RULE_Y + GAP, 840                -- the map: 840 x 559 at (10, 94)
local DOCK_H = 26
local DOCK_Y = CONTENT_H - 11 - DOCK_H                -- 651: the dock ends where the panel ends
local PANEL_X = PAD + MAP_W + GAP                     -- 858
local PANEL_W = PAD + HDR_W - PANEL_X                 -- 462: to the header's right edge
local PANEL_H = DOCK_Y + DOCK_H - MAP_Y               -- 593

local function S() return ns.Strategy end
local function UI() return ns.UI end
local function MapUI() return ns.StrategyMapUI end
local function Collab() return ns.StrategyCollab end

-- The toolbar icons (the atlas and its order: UI/Widgets.lua, UI.ICON_ATLAS).
local TOOL_ATLAS = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\tools"
local TOOL_SIZE = 26
local TOOL_ICON = { select = 1, pan = 2, circle = 3, rect = 4, arrow = 5, line = 6, icon = 7, text = 8 }
local function atlasCoords(i) return UI():IconCoords(i) end
-- The dock's places (dock coordinates): the tools (select / pan, a gap, the six drawing tools), the colours, undo /
-- redo, the 2D / 3D switch at its right end; the selection's own controls right-aligned before the switch.
local TOOL_X = { 0, 28, 64, 92, 120, 148, 176, 204 }
local SW_X, SW_STEP = 244, 20
local UNDO_X, REDO_X = 496, 524
local SEG_X = MAP_W - 67                              -- 773

-- The keys and the mouse, on the ? menu's Keyboard and mouse card: { heading, { { keys ("A|B": two keycaps), what } } }.
local SHORTCUTS = {
    { "Drawing", { { "Del", "delete the selection" }, { "Ctrl+C|Ctrl+V", "copy, paste" }, { "Ctrl+X", "cut" },
                   { "Ctrl+D", "duplicate" }, { "Ctrl+A", "select all" }, { "Ctrl+G|Ctrl+Shift+G", "group, ungroup" },
                   { "Arrows", "nudge the selection" }, { "Alt", "snap while dragging" } } },
    { "History", { { "Ctrl+Z", "undo" }, { "Ctrl+Y", "redo" } } },
    { "Texts and links", { { "Double-click", "edit a text" }, { "Drag a corner", "resize (Shift: box width)" },
                           { "Shift-drag", "onto a table: link to a job" } } },
    { "Map", { { "Right-click", "add here, the map" }, { "Wheel", "zoom" } } },
    { "3D", { { "Right-drag", "turn and tilt" }, { "Middle-drag", "move the view" }, { "Q|E", "turn 45 degrees" },
              { "Home", "the whole room" }, { "Double-click", "look there" } } },
}

-- "Wed 15 · 20:00" (a raid's day and time).
local function raidWhen(t)
    return (date("%a %d", t):gsub(" 0", " ")) .. " \194\183 " .. date("%H:%M", t)
end

-- A menu entry: an atlas icon (or the room of one, so the words line up) and one word or two; red: Delete.
local MENU_SPACER = "|TInterface\\Common\\spacer:12:12|t"
local function menuEntry(icon, text, red)
    local i = icon and UI():AtlasIconText(icon, 12, red and Style.C.BAD or nil) or MENU_SPACER
    return i .. "  " .. (red and Style:Wrap("BAD", text) or text)
end

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
    base = nil,         -- edit: what the saved strategy said when this draft started (Collab:ContentHash)
    liveK = nil,        -- edit: the live session this draft was last part of (Core/StrategyCollab.lua)
    sandbox = nil,      -- edit: the tutorial's practice board (never a draft, never saved; Board:OpenSandbox)
}

---------------------------------------------------------------------------
-- Prompt (single- or multi-line text)
---------------------------------------------------------------------------

local prompt                -- the shown prompt (ns.Popup:Prompt's dialog)
local PROMPT_LEN = 64       -- letters a prompt takes unless the caller asks for more

-- Asks for a text: cb(text) on OK. multiline: a box of several lines (texts, notes; Ctrl+Enter is OK); maxLen: the
-- letters it takes. The addon's prompt (UI/Popup.lua), above the board and everything drawn on its map.
function Board:Prompt(title, default, cb, multiline, maxLen)
    local notes = maxLen or S().MAX_NOTES
    prompt = ns.Popup:Prompt({
        key = "STRAT", title = title or "", default = default or "",
        multiline = multiline and true or nil,
        -- (a short text gets a smaller box than the page notes)
        multiHeight = multiline and (notes > S().MAX_TEXT and 180 or 110) or nil,
        maxLetters = multiline and notes or (maxLen or PROMPT_LEN),
        onAccept = function(text, dlg)
            -- (closed before cb runs: cb may ask the next question in the same dialog)
            dlg:Hide()
            if cb then cb(text) end
            return true
        end,
    })
    return prompt
end

-- The prompt while it is shown (tests, the tutorial), else nil.
function Board:GetPrompt()
    return prompt and prompt:IsShown() and prompt or nil
end

-- The board's questions (ns.Popup:Confirm, one key each: asking again replaces the shown one); fn runs on the first
-- button.
local ASK = {
    DISCARD = { ok = "Discard", cancel = "Keep editing", title = "Discard changes", danger = true },
    DELETE_PAGE = { ok = DELETE or "Delete", title = "Delete page", danger = true },
    NEWER = { ok = "Save mine", title = "Saved by someone else" },
    SWITCH = { ok = "Use it" },
    MAP3D = { ok = "Use it" },
}
local function ask(kind, text, fn)
    local d = ASK[kind]
    return ns.Popup:Confirm({ key = "STRAT_" .. kind, title = d.title, text = text, ok = d.ok, cancel = d.cancel,
        danger = d.danger, onAccept = function() fn() end })
end

local function promptFn(title, default, cb, multiline, maxLen)
    Board:Prompt(title, default, cb, multiline, maxLen)
end

---------------------------------------------------------------------------
-- State helpers
---------------------------------------------------------------------------

local function page() return st.strat and st.strat.p and st.strat.p[st.page] or nil end

local slotLabels = {}
local function rebuildSlots()
    slotLabels = {}
    for _, s in ipairs(S():GetSlots(st.strat)) do slotLabels[s.ref] = s.label end
end

-- The practice board's raid (Board:SandboxMode): me and nine made-up players, a spec each so the roles show.
local SANDBOX_OCC = "sandbox"
local SANDBOX_RAID = { { "Aldren", "WARRIOR", "tank" }, { "Brisa", "PALADIN", "tank" }, { "Corvin", "PRIEST", "healer" },
                       { "Dessa", "SHAMAN", "healer" }, { "Eldor", "DRUID", "healer" }, { "Fenna", "ROGUE", "melee" },
                       { "Gorim", "HUNTER", "ranged" }, { "Halvi", "MAGE", "ranged" }, { "Isolde", "WARLOCK", "ranged" } }
local sandboxMembers
local function sandboxRaid()
    if sandboxMembers then return sandboxMembers end
    local out = {}
    local me = ns.Util.PlayerKey()
    if me then
        local _, class = UnitClass("player")
        out[1] = { key = me, c = class, sp = ns.RaidPlan and ns.RaidPlan:GetMemberSpec(me) or nil }
    end
    for _, d in ipairs(SANDBOX_RAID) do
        local sp
        for i, spec in pairs(ns.SPECS and ns.SPECS[d[2]] or {}) do
            local role = type(spec) == "table" and (spec.role == "caster" and "ranged" or spec.role)
            if role == d[3] and (sp == nil or i < sp) then sp = i end
        end
        out[#out + 1] = { key = ns.Util.NormalizeName(d[1]), c = d[2], sp = sp }
    end
    tsort(out, function(a, b) return a.key < b.key end)
    sandboxMembers = out
    return out
end

local memberSet, memberList = {}, {}
local function rebuildMembers()
    memberSet, memberList = {}, {}
    if not st.occ then return end
    memberList = st.sandbox and sandboxRaid() or S():GetRaidMembers(st.occ)
    for _, m in ipairs(memberList) do memberSet[m.key] = m end
end

local function memberClass(key)
    local m = memberSet[key]
    if m and m.c then return m.c end
    return ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key) or nil
end

local function coloredName(key)
    return UI():ColoredName(key, memberClass(key))
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

-- Building strategies is for every guild member (each changes only their own and the ones shared with them);
-- a raid's names are for who leads that raid (default: the raid on the board) and the GM: its own leader, or on a
-- raid without one the raid leaders (RaidPlan:CanAssignStrategies).
local function canBuild() return S():CanBuild() end
local function canAssign(occ)
    occ = occ or st.occ
    if occ == nil or occ == SANDBOX_OCC then return S():CanAssign() end
    return S():CanAssign(occ)
end
local function canEditStrat(s)
    if type(s) ~= "table" then return false end
    if not s.id then return canBuild() end       -- not saved yet: mine
    return S():CanEditStrategy(s.id)
end

-- Opening a raid needs a planned raid I can still see.
local function raidView()
    return st.occ and ns.RaidPlan and ns.RaidPlan:GetRaid(st.occ) or nil
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function tipButton(b, title, text)
    UI():AttachTooltip(b, title, text and { { text, 1, 1, 1, wrap = true } } or nil, { anchor = "ANCHOR_TOP" })
end

-- What follows the mouse while something is dragged onto the tables or the map: a player (the shared chip with the
-- class circle, its place in the list empties) or a slot ("Show ... on the map"); gold-edged, on top of everything.
local ghost
local function ensureGhost()
    if ghost then return ghost end
    ghost = UI():CreateChip(UIParent, { kind = "you", selected = true })
    ghost:SetFrameStrata("TOOLTIP")
    ghost:SetScript("OnUpdate", function(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("LEFT", UIParent, "BOTTOMLEFT", x / s + 8, y / s)
        -- a player carried over the tables: the slot under the mouse lights gold
        if st.dragging and win then win.blocks:SetDrop(win.blocks:SlotUnderCursor()) end
    end)
    ghost:SetScript("OnHide", function()
        if win then win.blocks:SetDrop(nil) end
    end)
    ghost:Hide()
    return ghost
end

-- The ghost with a text (and a class circle in front of it when classFile is given).
local function showGhost(text, classFile)
    local g = ensureGhost()
    g:SetIcon(classFile and TOOL_ATLAS or nil)      -- (a placeholder: ClassIcon paints it)
    g:Set(text)
    if classFile then UI():ClassIcon(g.icon, classFile) end
    g:Show()
    return g
end

-- A player of the raid in the panel's roster: the class circle and the name; once placed it fades (two jobs or more:
-- the count on the circle), picked it lights gold.
local ROSTER_ROW = 19
local function createPoolChip(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(ROSTER_ROW)
    -- (the shared row looks: the hover; picked, the gold wash and bar)
    UI():DecorateRow(c, { selectable = true })
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(13, 13)
    c.icon:SetPoint("LEFT", 4, 0)
    c.fs = UI():Text(c, "body", "TEXT")
    c.fs:SetPoint("LEFT", c.icon, "RIGHT", 5, 0)
    c.count = UI():Text(c, "caps", "TEXT", { shadow = true })
    c.count:SetPoint("BOTTOMRIGHT", c.icon, "BOTTOMRIGHT", 3, -2)
    c:RegisterForDrag("LeftButton")
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", function(self)
        st.picked = st.picked ~= self.key and self.key or nil
        Board:RefreshPool()
    end)
    c:SetScript("OnDragStart", function(self)
        showGhost(coloredName(self.key), memberClass(self.key))
        st.dragging = self.key
        -- (its place in the list empties while it is carried)
        self:SetAlpha(0)
    end)
    c:SetScript("OnDragStop", function(self)
        if ghost then ghost:Hide() end
        local key = st.dragging
        st.dragging = nil
        local ref = key and win.blocks:SlotUnderCursor()
        if ref then Board:Assign(ref, key) else Board:RefreshPool() end
    end)
    c:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(coloredName(self.key))
        local m = memberSet[self.key]
        if m then
            local label = ns.RaidComp and ns.RaidComp:SpecLabel(m.c, m.sp)
            GameTooltip:AddLine((label and (label .. " ") or "") .. (ns.CLASS_NAMES[m.c] or ""), 1, 1, 1)
            if m.st == "T" then GameTooltip:AddLine("Tentative", Style:RGB("GOLD"))
            elseif m.st == "B" then GameTooltip:AddLine("Bench", Style:RGB("GOLD"))
            elseif m.inRaid then GameTooltip:AddLine("In your raid, no sign-up", Style:RGB("SUB")) end
        end
        for _, s in ipairs(S():GetPlayerSlots(st.strat, st.assign, self.key)) do
            GameTooltip:AddLine(s.label, Style:RGB("TEXT"))
        end
        GameTooltip:AddLine("Drag onto a slot, or click and then click a slot.", Style.C.SUB[1], Style.C.SUB[2],
            Style.C.SUB[3], true)
        GameTooltip:Show()
    end)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

-- A chip in the dock (UI:CreateChip): a job of mine (gold: picked look), a raid that uses the strategy; an icon, the
-- text (a raid's day in gold before it), a grey note after it, a chevron for a link. It says what it opens in its
-- tooltip. b:Set(iconKey, pre, text, note, chevron); b.fs, b.note, b.chev.
local function dockChip(parent, gold)
    local b = UI():CreateChip(parent, { kind = gold and "you" or "track", selected = gold, onClick = function() end })
    b.note = UI():Text(b, "small", "SUB")
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(9, 9)
    UI():SetChevron(b.chev, true)
    b.chev:SetVertexColor(Style:Color("SUB"))
    local chipSet = b.Set
    function b:Set(iconKey, pre, text, note, chevron)
        self:SetIcon(iconKey and TOOL_ATLAS or nil)
        chipSet(self, (pre and (Style:Wrap("GOLD", pre) .. "  ") or "") .. (text or ""))
        if iconKey then MapUI():SetIcon(self.icon, iconKey) end
        local w = self:GetWidth() or 40
        local last = self.fs
        self.note:SetShown(note ~= nil)
        if note then
            self.note:SetText(note)
            self.note:ClearAllPoints()
            self.note:SetPoint("LEFT", self.fs, "RIGHT", 6, 0)
            w = w + 6 + floor(UI():TextWidth(self.note) + 0.5)
            last = self.note
        end
        self.chev:SetShown(chevron and true or false)
        if chevron then
            self.chev:ClearAllPoints()
            self.chev:SetPoint("LEFT", last, "RIGHT", 5, 0)
            w = w + 5 + 9
        end
        self:SetWidth(w)
    end
    return b
end

-- (a dock chip's hover look, kept when its tooltip scripts are set)
local function chipHover(self, on)
    self.hovered = on
    if self.Paint then self:Paint() end
end

-- The rename field that takes a name's place (the strategy's in the header, a page's on its tab): Enter or a click
-- elsewhere keeps the text, Esc goes back. onDone(text) gets the text once, when typing ends (never per key: a live
-- board sends it as one change).
local function inlineEdit(parent, height, size, maxLen)
    local eb = UI():CreateSleekEditBox(parent, 120, height)
    local path, _, flags = eb:GetFont()
    if path and size then eb:SetFont(path, Style:Size(size), flags) end
    eb:SetMaxLetters(maxLen)
    eb:SetFrameLevel(parent:GetFrameLevel() + 20)
    eb:Hide()
    local function finish(self, keep)
        if self.cdlDone then return end
        self.cdlDone = true
        local cb = self.cdlCb
        self.cdlCb = nil
        self:ClearFocus()
        self:Hide()
        if cb then cb(keep and self:GetText() or nil) end
    end
    eb:SetScript("OnEnterPressed", function(self) finish(self, true) end)
    eb:SetScript("OnEscapePressed", function(self) finish(self, false) end)
    eb:HookScript("OnEditFocusLost", function(self) finish(self, true) end)
    -- starts typing: the field over `over` (as wide as the text and some), the text selected
    function eb:Begin(over, text, minW, onDone)
        self.cdlCb, self.cdlDone = onDone, false
        self:ClearAllPoints()
        self:SetPoint("LEFT", over, "LEFT", -6, 0)
        self:SetText(text or "")
        self:Show()
        local w = (over.GetStringWidth and over:GetStringWidth()) or (over.GetWidth and over:GetWidth()) or 80
        self:SetWidth(max(minW or 80, floor(w + 40 + 0.5)))
        self:SetFocus()
        self:HighlightText()
    end
    return eb
end

local function createWindow()
    local f = UI():CreateWindow("DisasterZoneStrategyBoard", "Strategy board", WIN_W, WIN_H)
    f:SetFrameStrata("HIGH")
    local c = f.content
    win = f

    ---------------------------------------------------------------------------------------------- the header
    -- the tool layout's strip banner (the raid's loading screen under the banners' shade): the boss, the strategy's
    -- name, a line about it and its state on the left; the actions on the right (Board:RefreshHeader lays them out)
    local L = UI():CreateLayout("tool", c, { width = CONTENT_W, bottom = 0,
        banner = { size = "strip", width = HDR_W, artFw = 0.72 } })
    f.layout = L
    local hdr = L.banner
    f.header = hdr

    f.bossFs = UI():Text(hdr, "title", "GOLD")
    f.title = UI():Text(hdr, "page", "TEXT")
    -- editing: the name is the rename control (a click types in place); a faint pencil says so
    f.pencil = hdr:CreateTexture(nil, "ARTWORK")
    f.pencil:SetSize(12, 12)
    f.pencil:SetTexture(TOOL_ATLAS)
    f.pencil:SetTexCoord(unpack(atlasCoords(16)))
    f.pencil:SetVertexColor(Style:Color("DIM"))
    f.titleBtn = CreateFrame("Button", nil, hdr)
    f.titleBtn:SetPoint("TOPLEFT", f.title, "TOPLEFT", -4, 4)
    f.titleBtn:SetPoint("BOTTOMRIGHT", f.pencil, "BOTTOMRIGHT", 4, -4)
    f.titleBtn:SetScript("OnClick", function() Board:RenameStrategy() end)
    f.titleBtn:SetScript("OnEnter", function(self)
        f.pencil:SetVertexColor(Style:Color("GOLD"))
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Rename")
        GameTooltip:Show()
    end)
    f.titleBtn:SetScript("OnLeave", function()
        f.pencil:SetVertexColor(Style:Color("DIM"))
        GameTooltip:Hide()
    end)
    f.titleEdit = inlineEdit(hdr, 24, 16, S().MAX_NAME_LEN)
    -- a raid's board, for who picks its strategies: the name switches the raid to another strategy of the boss
    f.stratDD = UI():CreateLinkDropdown(hdr, { size = 16, height = 24, build = function(root) Board:StrategyMenu(root) end })
    f.meta = UI():Text(hdr, "body", "SUB")
    -- (hover: who made it, who builds it with them, when it was saved)
    f.metaBtn = CreateFrame("Frame", nil, hdr)
    f.metaBtn:SetPoint("TOPLEFT", f.meta, "TOPLEFT", -2, 4)
    f.metaBtn:SetPoint("BOTTOMRIGHT", f.meta, "BOTTOMRIGHT", 2, -4)
    f.metaBtn:EnableMouse(true)
    f.metaBtn:SetScript("OnEnter", function(self) Board:MetaTooltip(self) end)
    f.metaBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- one state at a time: Unsaved, Joining ...'s board, Newer version by ..., Practice
    f.stateTag = UI():CreatePill(hdr, 16)
    f.stateTag:SetBase(Style:Color("SURFACE_WINDOW"))
    f.stateTag:EnableMouse(true)
    f.stateTag:SetScript("OnEnter", function(self) Board:StateTooltip(self) end)
    f.stateTag:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- the actions, laid out right to left in Board:RefreshHeader: the text buttons (the main one gold), then the icons
    local BH = Style.BTN_H
    f.saveBtn = UI():CreateSleekButton(hdr, "Save", 72, BH, function() Board:Save() end, "primary")
    f.cancelBtn = UI():CreateSleekButton(hdr, "Discard", nil, BH, function() Board:Discard() end)
    f.doneBtn = UI():CreateSleekButton(hdr, "Done", nil, BH, function() Board:CancelChanges() end, "primary")
    tipButton(f.doneBtn, "Done", "Nothing is changed: back to reading the board.")
    f.editBtn = UI():CreateSleekButton(hdr, "Edit", 64, BH, function() Board:SetMode("edit") end, "primary")
    tipButton(f.editBtn, "Edit", "Draw on the map, change the jobs and pages. Changes reach everyone when you Save.")
    f.fillBtn = UI():CreateSleekButton(hdr, "Assign players", nil, BH, function() Board:SetMode("fill") end, "primary")
    tipButton(f.fillBtn, "Assign players", "Put this raid's players into the slots.")
    f.moreBtn = UI():CreateTipIconButton(hdr, BH, UI().ICON.more, "More", nil, function(self) Board:OpenMore(self) end)
    -- a link for the chat (UI/Share.lua): a raid's board for this boss (with its names), else the strategy
    f.shareBtn = ns.Share:CreateButton(hdr, BH, function()
        if st.occ and st.boss then return ns.Share:BoardRef(st.occ, st.boss) end
        return st.strat and st.strat.id and ns.Share:StrategyRef(st.strat.id) or nil
    end, "Share this board")
    f.helpBtn = UI():CreateTipIconButton(hdr, BH, 11, "Help", nil, function(self) Board:OpenHelp(self) end)
    -- who else has it open: a green Live and their class circles (a reader's faded); the tooltip says who is where
    local live = CreateFrame("Frame", nil, hdr)
    live:SetHeight(24)
    live:EnableMouse(true)
    live.dot = live:CreateTexture(nil, "ARTWORK")
    live.dot:SetSize(6, 6)
    live.dot:SetTexture(MapUI().TEX.disc)
    live.dot:SetVertexColor(Style:Color("OK"))
    live.dot:SetPoint("LEFT", 0, 0)
    live.fs = UI():Text(live, "body", "OK")
    live.fs:SetText("Live")
    live.fs:SetPoint("LEFT", live.dot, "RIGHT", 6, 0)
    live.faces = {}
    live:SetScript("OnEnter", function(self) Board:PresenceTooltip(self) end)
    live:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.live = live

    ---------------------------------------------------------------------------------------------- the tab row
    -- the pages as underline tabs (built in Board:RefreshTabs), + adds one; the page's map at the map's right edge;
    -- one rule under the row
    f.tabs = {}
    f.addPage = UI():CreateUnderlineTab(c, "+", function() Board:AddPage() end, "page")
    do
        local fs = f.addPage:GetFontString()
        local path, _, flags = fs:GetFont()
        if path then fs:SetFont(path, Style:Size(15), flags) end
        f.addPage:SetSize(24, TABS_H)
    end
    tipButton(f.addPage, "Add a page", "For another phase of the fight. It starts with the same map.")
    f.tabEdit = inlineEdit(c, 20, 12, S().MAX_PAGE_NAME)
    f.rule = UI():Rule(c, { top = RULE_Y, left = PAD, right = PAD })
    f.mapBtn = UI():CreateLinkDropdown(c, { icon = 31, iconSize = 12, size = Style.FONT.body, color = Style.C.TEXT,
        height = TABS_H, build = function(root) Board:MapMenu(root) end, title = "This page's map",
        tip = "The floors of the raid, with who is fought on each; Other raids has the rest." })
    f.mapBtn:SetPoint("RIGHT", c, "TOPLEFT", PAD + MAP_W, -(TABS_Y + TABS_H / 2))
    -- the drawings of the page, once there are many (from 60 of the 80)
    f.countBtn = CreateFrame("Frame", nil, c)
    f.countBtn:SetHeight(TABS_H)
    f.countBtn:SetPoint("RIGHT", f.mapBtn, "LEFT", -14, 0)
    f.countBtn:EnableMouse(true)
    f.countFs = UI():Text(f.countBtn, "body", "TEXT")
    f.countFs:SetPoint("RIGHT", 0, 0)
    f.countBtn:SetScript("OnEnter", function(self) Board:CountTooltip(self) end)
    f.countBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- assigning: how many slots have a name, at the row's right end
    f.slotsFs = UI():Text(c, "body", "SUB")
    f.slotsFs:SetJustifyH("RIGHT")
    f.slotsFs:SetPoint("RIGHT", c, "TOPLEFT", PAD + HDR_W, -(TABS_Y + TABS_H / 2))

    ---------------------------------------------------------------------------------------------- the map
    f.canvas = MapUI():CreateCanvas(c, MAP_W, {
        editable = function() return st.mode == "edit" end,
        onChange = function() Board:MarkDirty(true) end,
        onSelect = function()
            Board:RefreshTools()
            Board:ShareSelection()
        end,
        remoteSel = function()
            local p = page()
            return p and Collab():RemoteSelections(p.id) or {}
        end,
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
        -- the 3D view: a player marker's ring is its player's class colour; "My spot" stands on mine
        slotClass = function(ref) local key = st.assign[ref] return key and st.mode ~= "edit" and memberClass(key) or nil end,
        mySlots = function()
            local me, out = ns.Util.PlayerKey(), {}
            for ref, key in pairs(st.assign) do if key == me then out[ref] = true end end
            return out
        end,
        on3D = function() Board:RefreshMode() end,
    })
    f.canvas.frame:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -MAP_Y)
    -- a 1px edge round it (over the 3D view too, which stacks several hundred levels above the canvas)
    local border = CreateFrame("Frame", nil, c)
    border:SetPoint("TOPLEFT", f.canvas.frame, "TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", f.canvas.frame, "BOTTOMRIGHT", 1, -1)
    UI():AddEdges(border, "OVERLAY")
    UI():SetEdgeColor(border, Style:Color("EDGE"))
    border:SetFrameLevel(f.canvas.frame:GetFrameLevel() + 1100)
    border:EnableMouse(false)

    ---------------------------------------------------------------------------------------------- the panel
    -- assigning: the raid's players on the panel's top (Board:RefreshPool), the tables under them
    local pool = UI():CreateCard(c, { tone = "card" })
    pool:SetPoint("TOPLEFT", c, "TOPLEFT", PANEL_X, -MAP_Y)
    pool:SetSize(PANEL_W, 60)
    pool.chips, pool.heads = {}, {}
    pool.empty = UI():Text(pool, "body", "SUB", { wrap = true })
    pool.empty:SetPoint("TOPLEFT", 12, -10)
    pool.empty:SetPoint("RIGHT", pool, "RIGHT", -12, 0)
    pool.empty:SetText("Nobody has signed up for this raid yet, and you are not in a raid group.")
    f.pool = pool
    f.blocks = ns.StrategyBlocksUI:Create(c, {
        mode = function() return st.mode end,
        page = page,
        strat = function() return st.strat end,
        assigned = function(ref) return st.assign[ref] end,
        memberInfo = function(key)
            return { c = memberClass(key), missing = st.occ ~= nil and memberSet[key] == nil }
        end,
        isDup = function(ref) return dups[ref] == true end,
        isMine = function(ref) return st.occ ~= nil and st.mode == "view" and st.assign[ref] == ns.Util.PlayerKey() end,
        raidBoard = function() return st.occ ~= nil end,
        onAssign = function(ref, key) Board:Assign(ref, key) end,
        picked = function() return st.picked end,
        dragging = function() return st.dragging end,
        members = function() return memberList end,
        countOf = countOf,
        onChange = function() Board:MarkDirty(true) end,
        onHover = function(ref) win.canvas:Highlight(ref) end,
        prompt = promptFn,
        slotName = function(ref) return st.assign[ref] and coloredName(st.assign[ref]) or nil end,
        slotLabel = function(ref) return slotLabels[ref] or ref end,
        onCellDragStart = function(ref)
            showGhost("Show " .. (slotLabels[ref] or ref) .. " on the map")
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
    f.blocks.width = PANEL_W
    f.blocks.scroll:SetPoint("TOPLEFT", c, "TOPLEFT", PANEL_X, -MAP_Y)
    f.blocks.scroll:SetSize(PANEL_W, PANEL_H)

    ---------------------------------------------------------------------------------------------- the dock
    -- one row under the map in every mode: the tools (editing), your jobs or the raids that use it (reading), the
    -- actions on the names (assigning); the 2D / 3D switch at its right end
    local dock = CreateFrame("Frame", nil, c)
    dock:SetPoint("TOPLEFT", c, "TOPLEFT", PAD, -DOCK_Y)
    dock:SetSize(MAP_W, DOCK_H)
    f.dock = dock
    -- (the handle the tutorial and older code know)
    f.below = dock

    local tools = CreateFrame("Frame", nil, dock)
    tools:SetAllPoints()
    f.tools = tools
    tools.btns = {}
    for i, t in ipairs(MapUI().TOOLS) do
        local b = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(TOOL_ICON[t.key] or 11), function(self)
            -- a full page: a drawing tool says why it does nothing
            if t.key ~= "select" and t.key ~= "pan" and Board:PageFull() then
                Board:CountTooltip(self)
                return
            end
            win.canvas:SetTool(t.key)
            Board:RefreshTools()
        end)
        b:SetPoint("LEFT", tools, "LEFT", TOOL_X[i] or (i - 1) * 28, 0)
        b.key = t.key
        tipButton(b, t.label, t.tip)
        tools.btns[#tools.btns + 1] = b
    end
    -- the colours: 12 px squares in 18 px cells, the current one ringed gold (a colour picker of the board's own: no
    -- shared component draws swatches)
    tools.swatches = {}
    for i = 1, #MapUI().COLORS do
        local sw = CreateFrame("Button", nil, tools)
        sw:SetSize(18, 18)
        sw:SetPoint("LEFT", tools, "LEFT", SW_X + (i - 1) * SW_STEP, 0)
        sw.tex = sw:CreateTexture(nil, "ARTWORK")
        sw.tex:SetPoint("TOPLEFT", 3, -3)
        sw.tex:SetPoint("BOTTOMRIGHT", -3, 3)
        sw.tex:SetColorTexture(MapUI():Color(i))
        sw.edge = CreateFrame("Frame", nil, sw)
        sw.edge:SetPoint("TOPLEFT", 2, -2)
        sw.edge:SetPoint("BOTTOMRIGHT", -2, 2)
        UI():AddEdges(sw.edge, "OVERLAY")
        local r, g, b = MapUI():Color(i)
        -- (black shows on the dark window by a light edge)
        if r + g + b < 0.3 then UI():SetEdgeColor(sw.edge, 0.59, 0.59, 0.63, 0.7)
        else UI():SetEdgeColor(sw.edge, 0, 0, 0, 0.6) end
        -- (the ring: 2 px round the cell)
        sw.ring = {}
        for k, a in ipairs({ { "TOPLEFT", -2, 2, "TOPRIGHT", 2, 2, "h" }, { "BOTTOMLEFT", -2, -2, "BOTTOMRIGHT", 2, -2, "h" },
                             { "TOPLEFT", -2, 2, "BOTTOMLEFT", -2, -2, "w" }, { "TOPRIGHT", 2, 2, "BOTTOMRIGHT", 2, -2, "w" } }) do
            local t = sw:CreateTexture(nil, "OVERLAY")
            t:SetPoint(a[1], sw, a[1], a[2], a[3])
            t:SetPoint(a[4], sw, a[4], a[5], a[6])
            if a[7] == "h" then t:SetHeight(2) else t:SetWidth(2) end
            t:SetColorTexture(Style:Color("GOLD"))
            sw.ring[k] = t
        end
        tipButton(sw, MapUI().COLORS[i][4] or "Colour", "For new drawings, and the selected one.")
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
    -- undo / redo at the colours' end, each only while it can do something (nothing shifts when they come)
    tools.undoBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(9), function() Board:Undo() end)
    tools.undoBtn:SetPoint("LEFT", tools, "LEFT", UNDO_X, 0)
    tipButton(tools.undoBtn, "Undo", "Ctrl+Z")
    tools.redoBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(10), function() Board:Redo() end)
    tools.redoBtn:SetPoint("LEFT", tools, "LEFT", REDO_X, 0)
    tipButton(tools.redoBtn, "Redo", "Ctrl+Y or Ctrl+Shift+Z")
    -- the selection's own controls, right-aligned before the switch: its options (the right-click menu) and Delete;
    -- a text adds its alignment
    tools.delBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(12), function()
        local e = win.canvas:GetSelected()
        if e then win.canvas:Remove(e) end
    end)
    tools.delBtn:SetPoint("LEFT", tools, "LEFT", SEG_X - 14 - TOOL_SIZE, 0)
    tipButton(tools.delBtn, "Delete", "Removes the selected drawings (Del).")
    tools.optBtn = UI():CreateIconButton(tools, TOOL_SIZE, TOOL_ATLAS, atlasCoords(13), function()
        local e = win.canvas:GetSelected()
        if e then win.canvas:ElementMenu(e) end
    end)
    tools.optBtn:SetPoint("RIGHT", tools.delBtn, "LEFT", -2, 0)
    tipButton(tools.optBtn, "Options", "Label, colour, raid mark, link to a job, shape. Also on right-click.")
    tools.alignBtns = {}
    local anchor = tools.optBtn
    for _, a in ipairs({ { "r", "Align right", "RIGHT" }, { "c", "Centre", "CENTER" }, { "l", "Align left", "LEFT" } }) do
        local b = UI():CreateIconButton(tools, TOOL_SIZE, nil, nil, function() win.canvas:SetTextAlign(a[1]) end)
        b.align = a[1]
        -- the icon: three lines of text, aligned that way
        for i, w in ipairs({ 14, 8, 11 }) do
            local line = b:CreateTexture(nil, "OVERLAY")
            line:SetColorTexture(0.85, 0.85, 0.85, 1)
            line:SetSize(w, 2)
            line:SetPoint(a[3], b, a[3], a[3] == "LEFT" and 6 or (a[3] == "RIGHT" and -6 or 0), 9 - i * 5 + 1)
        end
        b:SetPoint("RIGHT", anchor, "LEFT", anchor == tools.optBtn and -10 or -2, 0)
        tipButton(b, a[2], "The lines of the selected text (several lines, or a box narrower than the text).")
        tools.alignBtns[#tools.alignBtns + 1] = b
        anchor = b
    end

    -- reading a raid's board: my jobs, a click goes to the page and lights the row and its drawing
    local jobs = CreateFrame("Frame", nil, dock)
    jobs:SetAllPoints()
    jobs.label = UI():Text(jobs, "small", "GOLD", { text = "YOUR JOBS" })
    jobs.label:SetPoint("LEFT", jobs, "LEFT", 0, 0)
    jobs.chips = {}
    f.jobs = jobs
    -- reading a strategy on its own: the raids coming up that use it, as links to their boards
    local inRaids = CreateFrame("Frame", nil, dock)
    inRaids:SetAllPoints()
    inRaids.label = UI():Text(inRaids, "small", "GOLD", { text = "IN RAIDS" })
    inRaids.label:SetPoint("LEFT", inRaids, "LEFT", 0, 0)
    inRaids.chips = {}
    f.inRaids = inRaids
    -- assigning: the actions on the names (the pool's buttons)
    local fillBar = CreateFrame("Frame", nil, dock)
    fillBar:SetAllPoints()
    f.fillBar = fillBar
    pool.carryBtn = UI():CreateSleekButton(fillBar, "Carry over", nil, Style.BTN_H, function() Board:CarryOver() end)
    tipButton(pool.carryBtn, "Carry over", "Start from the names of the last raid that used this strategy. Players "
        .. "who aren't in this raid are shown in red.")
    pool.suggestBtn = UI():CreateSleekButton(fillBar, "Suggest fill", nil, Style.BTN_H, function() Board:Suggest() end)
    tipButton(pool.suggestBtn, "Suggest fill", "Fills the empty slots that are limited to a class or role with "
        .. "players who fit, spreading the jobs. Slots open to anyone stay for you.")
    pool.clearBtn = UI():CreateSleekButton(fillBar, "Clear all", nil, Style.BTN_H, function() Board:ClearAll() end)
    tipButton(pool.clearBtn, "Clear all", "Empties every slot.")

    -- the page on the 2D map or in the boss' room in 3D (UI/StrategyMap3D.lua): one page, the same drawings
    f.mode2d = UI():CreateSleekButton(dock, "2D", 34, DOCK_H, function() Board:Set3D(false) end)
    f.mode2d:SetPoint("LEFT", dock, "LEFT", SEG_X, 0)
    f.mode3d = UI():CreateSleekButton(dock, "3D", 34, DOCK_H, function() Board:Click3D() end)
    f.mode3d:SetPoint("LEFT", f.mode2d, "RIGHT", -1, 0)
    for _, b in ipairs({ f.mode2d, f.mode3d }) do
        b:GetFontString():SetFontObject("GameFontHighlightSmall")
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(self == f.mode3d and "3D" or "2D")
            GameTooltip:AddLine(self.tip or "", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

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
        if Board.keys then Board.keys:Hide() end
        Collab():BoardChanged()
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

-- Unsaved work is kept in the saved variables (per character) as drafts, so a /reload, a logout or a disconnect
-- doesn't lose it, and several can wait at once: [draft id] = { did, mode, strat, occ, boss, page, assign, hist,
-- histI, at }. The draft on the board is the board's state itself (stored by reference); the others are parked
-- records. Save and Cancel take a draft out. Raids > Strategies lists them under their boss (UI/StrategiesView.lua).
local MAX_DRAFTS = 12
local checkStale, setBase
local HIST_DRAFTS = 3       -- the parked drafts that keep their undo history (the latest; it is the bulk of a draft)

local function validDraft(d)
    if type(d) ~= "table" then return false end
    local s = d.strat
    if not ((d.mode == "edit" or d.mode == "fill") and type(s) == "table" and type(s.n) == "string"
        and type(s.b) == "string" and type(s.p) == "table" and type(s.p[1]) == "table"
        and type(d.assign) == "table") then return false end
    if d.mode == "fill" and not (type(d.occ) == "string" and type(d.boss) == "string" and s.id) then return false end
    return true
end

local draftsChecked = false
local function draftStore()
    local root, me = ns.db and ns.db.strategyDraft, ns.Util.PlayerKey()
    if type(root) ~= "table" or not me then return nil end
    local store = root[me]
    if type(store) ~= "table" then
        store = {}
        root[me] = store
    end
    if not draftsChecked then
        -- once per session: what the last one left behind, damaged entries dropped
        draftsChecked = true
        if store.mode then
            store = { d0 = store }      -- the first version kept a single draft here
            root[me] = store
        end
        for did, d in pairs(store) do
            if d ~= st then
                if type(did) == "string" and validDraft(d) then
                    d.did, d.dirty, d.picked, d.dragging = did, nil, nil, nil
                    d.at = tonumber(d.at) or 0
                else
                    store[did] = nil
                end
            end
        end
    end
    return store
end

local function draftsChanged() ns:Fire("STRATEGY_DRAFTS_CHANGED") end

-- The board's unsaved work is a draft; once nothing is unsaved (Save, Cancel) the draft is gone.
local function keepDraft()
    if st.sandbox then return end
    local store = draftStore()
    if not store then return end
    if st.dirty and st.strat and (st.mode == "edit" or st.mode == "fill") then
        if not st.did then
            local n = 0
            repeat
                n = n + 1
                st.did = ("d%x%d"):format(time(), n)
            until not store[st.did]
        end
        st.at = time()
        store[st.did] = st
        draftsChanged()
    elseif st.did then
        store[st.did] = nil
        st.did = nil
        draftsChanged()
    end
end

-- The board moves on to something else: its unsaved work stays behind as a draft of its own.
local function park()
    st.sandbox = nil        -- a practice board is simply left behind
    local store = draftStore()
    if not (store and st.did and st.dirty) then return end
    store[st.did] = { did = st.did, mode = st.mode, strat = st.strat, occ = st.occ, boss = st.boss, page = st.page,
        assign = st.assign, hist = st.hist, histI = st.histI, at = st.at or time(), base = st.base,
        liveK = st.liveK }
    st.did, st.dirty, st.hist, st.histI = nil, false, nil, nil
    st.base, st.liveK, st.stale = nil, nil, nil
    st.strat, st.assign = ns.Util.CopyTable(st.strat), ns.Util.CopyTable(st.assign)
    local list = {}
    for _, d in pairs(store) do
        if d ~= st and d.hist then list[#list + 1] = d end
    end
    tsort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    for i = HIST_DRAFTS + 1, #list do list[i].hist, list[i].histI = nil, nil end
    draftsChanged()
end

local function findDraft(pred)
    local store = draftStore()
    local best
    for _, d in pairs(store or {}) do
        if pred(d) and (not best or (d.at or 0) > (best.at or 0)) then best = d end
    end
    return best
end

local function editDraftOf(id)
    return id and findDraft(function(d) return d.mode == "edit" and d.strat.id == id end) or nil
end

-- The drafts of strategies (of one boss, or all), latest first: { did, n, b, id (of the saved strategy it changes),
-- at, pages, blocks, open (it is the one on the board) }.
function Board:GetDrafts(bossRef)
    local out = {}
    if not canBuild() then return out end
    for _, d in pairs(draftStore() or {}) do
        if d.mode == "edit" and (bossRef == nil or d.strat.b == bossRef) then
            local blocks = 0
            for _, p in ipairs(d.strat.p) do blocks = blocks + #(p.k or {}) end
            out[#out + 1] = { did = d.did, n = d.strat.n, b = d.strat.b, id = d.strat.id, at = d.at or 0,
                pages = #d.strat.p, blocks = blocks, open = d == st }
        end
    end
    tsort(out, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.did > b.did
    end)
    return out
end

-- Unsaved names for a raid's boss: the draft's id, or nil.
function Board:FillDraft(occId, bossRef)
    if not canAssign(occId) then return nil end
    local d = findDraft(function(d) return d.mode == "fill" and d.occ == occId and d.boss == bossRef end)
    return d and d.did or nil
end

function Board:HasDraft() return canBuild() and next(draftStore() or {}) ~= nil end

-- The saved strategy as it is now, when it no longer says what it said when this draft started (someone else saved
-- in between); nil otherwise.
local function savedSince()
    if not (st.mode == "edit" and st.base and st.strat and st.strat.id) then return nil end
    local cur = S():GetStrategy(st.strat.id)
    if cur and not ns.Util.IsMe(cur.by) and Collab():ContentHash(cur) ~= st.base then return cur end
    return nil
end

-- st.stale: who saved a version my unsaved draft doesn't build on (shown in the header).
checkStale = function()
    local cur = st.dirty and savedSince()
    st.stale = cur and not Collab():SameContent(cur, st.strat) and cur.by or nil
end

-- An edit starts from the saved strategy on the board: remember what it says.
setBase = function()
    st.liveK, st.stale = nil, nil
    st.base = (st.mode == "edit" and st.strat and st.strat.id and not st.dirty) and Collab():ContentHash(st.strat) or nil
end

-- Who else has this strategy open: { live = { { key, pg = page index or nil } } (their boards are mine), editing =
-- { keys }, looking = { keys }, joining = the share of the live board that arrived while I join one (or nil) }.
local function presence()
    local out = { live = {}, editing = {}, looking = {} }
    local id = st.strat and st.strat.id
    if not id then return out end
    for _, e in ipairs(Collab():GetPresence(id)) do
        if e.live then
            local pg
            for i, p in ipairs(st.strat.p) do
                if p.id == e.pg then pg = i end
            end
            out.live[#out.live + 1] = { key = e.key, pg = pg }
        elseif e.m == "e" then
            out.editing[#out.editing + 1] = e.key
        else
            out.looking[#out.looking + 1] = e.key
        end
    end
    local joining, progress = Collab():IsJoining()
    if joining and st.mode == "edit" then out.joining = progress or 0 end
    return out
end

local function presenceName(key)
    local r, g, b = Collab():ColorOf(key)
    -- uniformity: the member's own live colour (data-driven)
    return ("|cff%02x%02x%02x"):format(floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
        .. ns.Util.ShortName(key) .. "|r"
end

-- The same in a line ("live with A, B (P3)  ·  C is editing  ·  D is looking"), or nil: the Live tooltip's words.
function Board:PresenceText()
    local pr = presence()
    local liveWith, editing, looking = {}, {}, {}
    for _, e in ipairs(pr.live) do
        local p = e.pg and e.pg ~= st.page and st.strat.p[e.pg]
        liveWith[#liveWith + 1] = presenceName(e.key) .. (p and (" " .. Style:Wrap("SUB", "(" .. p.n .. ")")) or "")
    end
    for _, key in ipairs(pr.editing) do editing[#editing + 1] = presenceName(key) end
    for _, key in ipairs(pr.looking) do looking[#looking + 1] = presenceName(key) end
    local parts = {}
    if pr.joining then
        parts[#parts + 1] = ("|cffffd100joining the live board... %d%%|r"):format(pr.joining * 100)
    end
    if #liveWith > 0 then parts[#parts + 1] = Style:Wrap("OK", "live with") .. " " .. tconcat(liveWith, ", ") end
    if #editing > 0 then parts[#parts + 1] = tconcat(editing, ", ") .. (#editing == 1 and " is" or " are") .. " editing" end
    if #looking > 0 then parts[#parts + 1] = tconcat(looking, ", ") .. (#looking == 1 and " is" or " are") .. " looking" end
    return #parts > 0 and tconcat(parts, "  \194\183  ") or nil
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

-- Goes on with a draft (did nil: the latest one). What the board held unsaved stays behind as its own draft.
function Board:OpenDraft(did)
    if not canBuild() then
        ns:Print("Your guild is not known yet; try again in a moment.")
        return false
    end
    local store = draftStore()
    local d
    if did == nil then
        d = findDraft(function(x) return x.mode == "edit" or canAssign(x.occ) end)
    else
        d = store and store[did]
    end
    if not d then
        ns:Print(did and "That draft is gone." or "No unsaved work on the strategy board.")
        return false
    end
    if d.mode == "fill" and not canAssign(d.occ) then
        local RP = ns.RaidPlan
        ns:Print((RP and RP.GetRaidLeader and RP:GetRaidLeader(d.occ))
            and "Only this raid's leader and the Guild Master assign its players."
            or "Only the raid leaders and the Guild Master assign a raid's players.")
        return false
    end
    -- an edit of a strategy I may no longer change (the owner took me off it, it was deleted): the draft goes
    if d.mode == "edit" and d.strat.id and not S():CanEditStrategy(d.strat.id) then
        local id = d.strat.id
        if S():GetStrategy(id) and not (ns.Guild and ns.Guild:IsReady()) then
            ns:Print("Your guild is not known yet; try again in a moment.")
            return false
        end
        if d == st then
            st.dirty, st.base, st.liveK, st.stale = false, nil, nil, nil
            keepDraft()
        else
            store[d.did] = nil
            draftsChanged()
        end
        ns:Print(("You can no longer change \"%s\", so your unsaved changes to it are dropped."):format(d.strat.n))
        if S():GetStrategy(id) then self:OpenStrategy(id) elseif d == st then self:Close() end
        return false
    end
    if d ~= st then
        park()
        local s = d.strat
        st.did, st.dirty, st.at = d.did, true, d.at
        st.mode, st.strat, st.assign = d.mode, s, d.assign
        st.occ = d.mode == "fill" and d.occ or nil
        st.boss = type(d.boss) == "string" and d.boss or s.b
        st.page = s.p[d.page] and d.page or 1
        st.picked, st.dragging = nil, nil
        st.base, st.liveK = d.base, d.liveK
        -- the undo history, when it is there and whole
        local hist, ok = d.hist, type(d.hist) == "table" and #d.hist > 0
        if ok then
            for _, snap in ipairs(hist) do
                if type(snap) ~= "table" or (d.mode == "edit" and type(snap.p) ~= "table") then ok = false end
            end
        end
        store[st.did] = st
        if ok and type(d.histI) == "number" and hist[d.histI] then
            st.hist, st.histI = hist, d.histI
        else
            self:ResetHistory()
        end
        draftsChanged()
    end
    checkStale()
    show()
    return true
end

-- Throws a draft away.
function Board:DiscardDraft(did)
    if not canBuild() then return end
    local store = draftStore()
    local d = store and store[did]
    if not d then return end
    if d == st then
        if self:IsShown() then return self:CancelChanges() end
        st.dirty, st.mode = false, "view"
        keepDraft()
    else
        store[did] = nil
        draftsChanged()
    end
end

-- A strategy on its own (view; its owner and collaborators can Edit).
function Board:OpenStrategy(id, mode)
    if st.dirty and st.strat and st.strat.id == id and not st.occ then return show() end
    park()
    local mine = S():CanEditStrategy(id)
    if mode == "edit" and not mine then
        ns:Print("Only its owner, the collaborators the owner invited, the Guild Master and the guild council can change this strategy. Copy makes one of your own.")
    end
    -- editing goes on where its draft stopped
    local d = mode == "edit" and mine and editDraftOf(id)
    if d then return self:OpenDraft(d.did) end
    local s = S():GetStrategy(id)
    if not s then
        ns:Print("That strategy no longer exists.")
        return
    end
    st.strat, st.occ, st.boss, st.page = s, nil, s.b, 1
    st.assign, st.dirty, st.picked = {}, false, nil
    st.mode = (mode == "edit" and mine) and "edit" or "view"
    setBase()
    Board:ResetHistory()
    show()
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

-- A new strategy for a boss (mine): its starter (the floor map framed on the room, the creatures where they
-- stand) when it has one, else a blank page on the boss' floor.
function Board:NewStrategy(bossRef, name)
    if not canBuild() then
        ns:Print("Your guild is not known yet; try again in a moment.")
        return
    end
    park()
    local count = 0
    for _ in pairs(draftStore() or {}) do count = count + 1 end
    if count >= MAX_DRAFTS then
        ns:Print("You have %d unsaved drafts. Save or discard one first (Raids > Strategies).", count)
        return
    end
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
    setBase()
    Board:ResetHistory()
    show()
end

-- The tutorial's practice board (UI/Tour.lua, Data/Tours/Strategy.lua): a new strategy for a boss, as New strategy
-- opens it, that is never kept as a draft, never saved and never shared. What the board held unsaved stays behind
-- as its draft. keep: the practice board of earlier this session, when the board still holds it, comes back as it was.
function Board:OpenSandbox(bossRef, keep)
    if not canBuild() then
        ns:Print("Your guild is not known yet; try again in a moment.")
        return false
    end
    if keep and st.sandbox and st.strat and st.strat.b == bossRef then
        show()
        return true
    end
    park()
    local d = self:StarterDraft(bossRef) or S():NewDraft(bossRef, "Practice board", MapUI():DefaultMap(bossRef))
    d.n = "Practice board"
    st.strat = d
    st.occ, st.boss, st.page, st.assign, st.picked = nil, bossRef, 1, {}, nil
    st.mode, st.dirty, st.sandbox = "edit", false, true
    setBase()
    Board:ResetHistory()
    show()
    return true
end

-- A raid's board for a boss: the chosen (or only) strategy with that raid's names.
function Board:OpenRaid(occId, bossRef, mode)
    if st.dirty and st.occ == occId and st.boss == bossRef then return show() end
    park()
    -- unsaved names for this raid's boss: go on with them
    local did = canAssign(occId) and self:FillDraft(occId, bossRef)
    if did then return self:OpenDraft(did) end
    local s, fill = S():GetRaidStrategy(occId, bossRef)
    st.occ, st.boss, st.page, st.picked = occId, bossRef, 1, nil
    st.strat = s
    st.assign = (s and fill and fill.s == s.id) and S():ValidAssignments(s, fill.a) or {}
    st.dirty = false
    st.mode = (mode == "fill" and canAssign(occId) and s) and "fill" or "view"
    setBase()
    Board:ResetHistory()
    show()
end

function Board:Close()
    if win then win:Hide() end
end

function Board:IsShown() return win ~= nil and win:IsShown() end

-- The window (nil until the board was opened once): the tutorial points at its controls.
function Board:GetWindow() return win end

function Board:GetState() return st end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Board:MarkDirty(repaint)
    st.dirty = true
    self:Record()
    keepDraft()
    if st.mode == "edit" then Collab():LocalChange() end
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
    keepDraft()
end

function Board:Record()
    -- a live board keeps my own actions instead (Core/StrategyCollab.lua)
    if st.mode == "edit" and Collab():IsLive() then return end
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
    keepDraft()
    Board:Refresh()
    return true
end

local function live() return st.mode == "edit" and Collab():IsLive() end

function Board:Undo()
    if live() then return Collab():Undo() end
    if (st.histI or 0) <= 1 then return false end
    return restore(st.histI - 1)
end

function Board:Redo()
    if live() then return Collab():Redo() end
    if not st.hist or (st.histI or 0) >= #st.hist then return false end
    return restore(st.histI + 1)
end

function Board:CanUndo()
    if live() then return Collab():CanUndo() end
    return (st.histI or 0) > 1
end

function Board:CanRedo()
    if live() then return Collab():CanRedo() end
    return st.hist ~= nil and (st.histI or 0) < #st.hist
end

-- What I have selected on the map, for the members who share a live board with me.
function Board:ShareSelection()
    if not (win and live()) then return end
    local uids = {}
    for _, e in ipairs(win.canvas:Selection()) do
        if e._u then uids[#uids + 1] = e._u end
    end
    Collab():SetSelection(uids)
end

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

-- The practice board in another mode (the tutorial's chapters): "edit", "fill" (assigning its demo raid) or "view"
-- (reading the plan with that raid's names). The names stay through the modes.
function Board:SandboxMode(mode)
    if not st.sandbox then return false end
    if mode ~= "fill" and mode ~= "view" then mode = "edit" end
    st.mode = mode
    st.occ = mode ~= "edit" and SANDBOX_OCC or nil
    st.picked = nil
    self:ResetHistory()
    self:Refresh()
    return true
end

function Board:SetMode(mode)
    if st.sandbox then return self:SandboxMode(mode) end
    if mode == "edit" then
        if not canEditStrat(st.strat) then return end
        if st.mode ~= "edit" then
            park()
            local d = editDraftOf(st.strat and st.strat.id)
            if d then return self:OpenDraft(d.did) end
        end
        if st.occ then
            -- edit the strategy itself (the raid's names stay)
            st.occ = nil
            st.assign = {}
        end
        st.mode = "edit"
        if not st.dirty then setBase() end
    elseif mode == "fill" then
        if not (canAssign() and st.occ and st.strat) then return end
        st.mode = "fill"
    else
        return
    end
    self:ResetHistory()
    self:Refresh()
end

-- The name in the header turns into a field (Enter keeps it, Esc goes back). A live board's refresh leaves the field
-- alone while it is typed in; the name goes out as one change when typing ends (a name someone else gave it in the
-- meantime shows once the field closes without a change of mine).
function Board:RenameStrategy()
    if st.mode ~= "edit" or not st.strat or not win or st.sandbox then return end
    local was = st.strat.n
    win.title:Hide()
    win.pencil:Hide()
    win.titleBtn:Hide()
    win.titleEdit:Begin(win.title, was, 160, function(text)
        text = text and ns.Util.Trim((text:gsub("|", ""))):sub(1, S().MAX_NAME_LEN) or ""
        if text ~= "" and text ~= was and st.mode == "edit" and st.strat then
            st.strat.n = text
            Board:MarkDirty()
        else
            Board:Refresh()
        end
    end)
end

-- Discard (the header): asks first. A practice board just closes.
function Board:Discard()
    if st.sandbox then return self:CancelChanges() end
    if not st.dirty then return self:CancelChanges() end
    local name = "|cffffd100" .. (st.strat and st.strat.n or "?") .. "|r"
    local text
    if st.mode == "fill" then
        local v = raidView()
        text = ("Discard the names you put in for %s?\n|cff9e9e9eThe saved names stay as they are.|r")
            :format(v and raidWhen(v.t) or "this raid")
    elseif st.strat and st.strat.id then
        text = ("Discard your changes to %s?\n|cff9e9e9eThe saved version stays as it is.|r"):format(name)
    else
        text = ("Discard %s?\n|cff9e9e9eIt was never saved: it is gone for good.|r"):format(name)
    end
    ask("DISCARD", text, function() Board:CancelChanges() end)
end

function Board:CancelChanges()
    if st.sandbox then
        st.dirty = false
        return self:Close()
    end
    local occ, boss, id = st.occ, st.boss, st.strat and st.strat.id
    st.dirty = false
    st.base, st.liveK, st.stale = nil, nil, nil
    keepDraft()
    if occ then
        self:OpenRaid(occ, boss)
    elseif id then
        self:OpenStrategy(id)
    else
        self:Close()
    end
end

-- force: save over a version someone else saved since this draft started.
function Board:Save(force)
    if st.sandbox then
        ns:Print("This is the tutorial's practice board: nothing here is saved. New strategy (Raids > Strategies) starts a real one.")
        return false
    end
    if st.mode == "edit" then
        local newer = not force and savedSince()
        if newer then
            ask("NEWER",
                ("%s saved a newer version of |cffffd100%s|r at %s, after you started.\n|cff9e9e9eSaving puts yours in its place.|r")
                    :format(presenceName(newer.by), st.strat.n, date("%H:%M", newer.rev)),
                function() Board:Save(true) end)
            return false
        end
        local ok, res = S():SaveStrategy(st.strat)
        if not ok then
            ns:Print("Could not save the strategy: %s", tostring(res))
            return false
        end
        st.dirty = false
        local s = S():GetStrategy(res)
        st.strat = s or st.strat
        st.mode = "view"
        st.base, st.liveK, st.stale = nil, nil, nil
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

-- fill: switch the raid to another strategy of the boss (names of matching slots are kept). Only who may assign the
-- raid's players; for everyone else a raid's board is read-only.
-- force: the names that have no slot in it are cleared (asked first when there are any).
function Board:UseStrategy(id, force)
    local s = S():GetStrategy(id)
    if not s or (st.occ and not st.sandbox and not canAssign()) then return end
    local kept = S():ValidAssignments(s, st.assign)
    local lost = 0
    for ref in pairs(st.assign) do
        if kept[ref] == nil then lost = lost + 1 end
    end
    if lost > 0 and not force then
        local v = raidView()
        ask("SWITCH",
            ("Use |cffffd100%s|r for %s?\n|cff9e9e9e%s no slot there and %s cleared.|r"):format(s.n,
                v and raidWhen(v.t) or "this raid", lost == 1 and "1 of your names has" or (lost .. " of your names have"),
                lost == 1 and "is" or "are"), function() Board:UseStrategy(id, true) end)
        return
    end
    st.strat = s
    st.page = 1
    st.assign = kept
    if st.mode ~= "fill" then
        st.mode = canAssign() and "fill" or "view"
    end
    self:MarkDirty(true)
end

-- A raid's strategy switch (the name in the header): the boss' strategies (the one the guild used last time, and who
-- made the others), and a new one.
function Board:StrategyMenu(root)
    root:CreateTitle(S():GetBossName(st.boss))
    local last = st.occ and S():GetLastPick(st.boss, st.occ)
    for _, s in ipairs(S():GetStrategies(st.boss)) do
        local note = s.id == last and "used last time" or ns.Util.ShortName(s.ow or s.by)
        root:CreateRadio(s.n .. "  " .. Style:Wrap("DIM", note), function() return st.strat and st.strat.id == s.id end,
            function() Board:UseStrategy(s.id) end)
    end
    if canBuild() then
        root:CreateDivider()
        root:CreateButton(UI():AtlasIconText(UI().ICON.plus, 12) .. "  New strategy", function()
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

-- A page's tab turns into a field with its name (the page menu's Rename, a double-click on the tab).
function Board:RenamePage(i)
    if st.mode ~= "edit" or not win then return end
    local p = st.strat.p[i]
    local tab = win.tabs[i]
    if not (p and tab and tab:IsShown()) then return end
    local id, was = p.id, p.n
    tab:SetAlpha(0)
    win.tabEdit:Begin(tab:GetFontString(), was, max(60, tab:GetWidth() or 60), function(text)
        tab:SetAlpha(1)
        text = text and ns.Util.Trim((text:gsub("|", ""))):sub(1, S().MAX_PAGE_NAME) or ""
        -- (by its id: a live board may have moved the pages meanwhile)
        local cur
        for _, x in ipairs(st.strat and st.strat.p or {}) do
            if x.id == id then cur = x end
        end
        if cur and text ~= "" and text ~= was and st.mode == "edit" then
            cur.n = text
            Board:MarkDirty(true)
        else
            Board:Refresh()
        end
    end)
end

-- What a page takes along when it goes ("9 drawings and 1 table"), and whether that is more than one thing.
local function pageContents(p)
    local parts = {}
    local n, k = #(p.e or {}), #(p.k or {})
    if n > 0 then parts[#parts + 1] = n == 1 and "1 drawing" or (n .. " drawings") end
    if k > 0 then parts[#parts + 1] = k == 1 and "1 table" or (k .. " tables") end
    if p.no then parts[#parts + 1] = "notes" end
    if #parts == 0 then return nil end
    local many = #parts > 1 or n > 1 or k > 1 or (n == 0 and k == 0)
    if #parts == 1 then return parts[1], many end
    return tconcat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts], many
end

-- The open tab's chevron (or a right-click on any tab): rename, duplicate, move, delete.
function Board:PageMenu(owner, i)
    local pages = st.strat.p
    local p = pages[i]
    win.pageMenu = UI():ContextMenu(owner, function(root)
        root:CreateTitle(p.n)
        root:CreateButton(menuEntry(16, "Rename"), function() Board:RenamePage(i) end)
        if #pages < S().MAX_PAGES then
            local dup = root:CreateButton(menuEntry(17, "Duplicate"), function()
                local c = ns.Util.CopyTable(p)
                c.id = S():NewPartId(st.strat, "p")
                c.n = (p.n .. " copy"):sub(1, S().MAX_PAGE_NAME)
                c.k = {}
                -- the blocks stay on the original page: tokens keep pointing at them
                tinsert(pages, i + 1, c)
                st.page = i + 1
                Board:MarkDirty(true)
            end)
            if dup and dup.SetTooltip then
                dup:SetTooltip(function(tt)
                    tt:AddLine("Duplicate", Style:RGB("GOLD"))
                    tt:AddLine("A new page with the same map and drawings. The tables stay on this one: the drawings "
                        .. "keep showing their names.", 1, 1, 1, true)
                end)
            end
        end
        if i > 1 then
            root:CreateButton(menuEntry(nil, "Move left"), function()
                pages[i], pages[i - 1] = pages[i - 1], pages[i]
                st.page = i - 1
                Board:MarkDirty(true)
            end)
        end
        if i < #pages then
            root:CreateButton(menuEntry(nil, "Move right"), function()
                pages[i], pages[i + 1] = pages[i + 1], pages[i]
                st.page = i + 1
                Board:MarkDirty(true)
            end)
        end
        if #pages > 1 then
            root:CreateDivider()
            root:CreateButton(menuEntry(UI().ICON.trash, "Delete", true), function() Board:DeletePage(i) end)
        end
    end)
end

-- Deletes a page, after asking (what goes with it, and that Ctrl+Z brings it back).
function Board:DeletePage(i, force)
    local pages = st.strat and st.strat.p
    local p = pages and pages[i]
    if not p or #pages < 2 or st.mode ~= "edit" then return end
    local what, many = pageContents(p)
    if not force and what then
        local id = p.id
        ask("DELETE_PAGE",
            ("Delete the page |cffffd100%s|r?\n|cff9e9e9eIts %s %s with it. Ctrl+Z brings %s back.|r"):format(p.n,
                what, many and "go" or "goes", many and "them" or "it"), function()
                for j, x in ipairs(st.strat and st.strat.p or {}) do
                    if x.id == id then return Board:DeletePage(j, true) end
                end
            end)
        return
    end
    tremove(pages, i)
    st.page = min(st.page, #pages)
    self:MarkDirty(true)
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
        if st.occ and not memberSet[key] then name = Style:Wrap("BAD", ns.Util.ShortName(key)) end
        return name
    end
    local label = slotLabels[ref]
    if not label then return Style:Wrap("BAD", "?") end
    -- no name yet: the job without the table's name, kept short (the tooltip has the rest)
    local sep = label:find(" \194\183 ", 1, true)
    if sep then label = label:sub(sep + 4) end
    if #label > 26 then label = label:sub(1, 24) .. "..." end
    return Style:Wrap("TEXT", label)
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
    if st.mode == "edit" then return Style:Wrap("SUB", "-> " .. self:LinkLabel(ref)) end
    local names = {}
    for _, sl in ipairs(slotsOf(ref)) do
        local key = st.assign[sl.ref]
        if key then
            local name = coloredName(key)
            if st.occ and not memberSet[key] then name = Style:Wrap("BAD", ns.Util.ShortName(key)) end
            names[#names + 1] = name
        end
    end
    if #names == 0 then return nil end
    if #names > 6 then
        local n = #names
        for i = n, 6, -1 do names[i] = nil end
        names[#names + 1] = Style:Wrap("DIM", "+" .. (n - 5))
    end
    return tconcat(names, ", ")
end

function Board:LinkTooltip(ref, tt)
    tt:AddLine(self:LinkLabel(ref), Style:RGB("GOLD"))
    local any = false
    for _, sl in ipairs(slotsOf(ref)) do
        local key = st.assign[sl.ref]
        if key then
            any = true
            tt:AddLine(coloredName(key) .. (sl.ref ~= ref and Style:Wrap("DIM", "  " .. sl.label) or ""))
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
-- Refresh helpers
---------------------------------------------------------------------------

-- The planned raid's instance key (its loading screen in the header): the raid on the board, else the boss' raid.
local function instOfBoss(bossRef)
    local key = type(bossRef) == "string" and bossRef:match("^(%w+):") or nil
    local raid = key and ns.ItemDB and ns.ItemDB.GetRaid and ns.ItemDB:GetRaid(key)
    local id = raid and raid.instanceID
    for _, inst in ipairs(ns.RaidPlan and ns.RaidPlan:GetInstances() or {}) do
        if id and inst.instID == id then return inst.key end
    end
    return "other"
end

local function raidInst()
    local v = raidView()
    local own = instOfBoss(st.boss or (st.strat and st.strat.b))
    if v and v.i then
        -- (a raid of several instances: the one of the open boss)
        for _, key in ipairs(ns.RaidPlan:GetRaidInstances(v)) do
            if key == own then return own end
        end
        return v.i
    end
    return own
end

-- A class circle inside text.
local function classIconText(classFile, size)
    local c = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if not c then return "" end
    size = size or 13
    local function px(v) return floor(v * 256 + 0.5) end
    return ("|TInterface\\TargetingFrame\\UI-Classes-Circles:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(size, size,
        px(c[1]), px(c[2]), px(c[3]), px(c[4]))
end

-- The page on the map or in the room (the 2D / 3D switch at the dock's right end; the map tilts up into the room and
-- back).
function Board:Set3D(on)
    if not win then return end
    win.canvas:Set3D(on, true)
    self:RefreshMode()
end

-- The room's floor (Data/RaidMaps.lua's entry) when this page is drawn on another map, or nil.
local function roomFloor()
    local _, why, room = win.canvas:Room3D()
    if why ~= "map" or not room then return nil end
    for _, m in ipairs(ns.Data and ns.Data.RaidMaps or {}) do
        if m.file == room.map then return m end
    end
    return nil
end

-- 3D: the room. On a page drawn on another map, editing asks to put the page on the room's floor and opens the room;
-- reading, the button's tooltip says why it can't.
function Board:Click3D()
    if not win then return end
    local room, why = win.canvas:Room3D()
    if room then return self:Set3D(true) end
    local m = why == "map" and roomFloor()
    local p = page()
    if not (m and p) then return end
    if st.mode ~= "edit" then
        local b = win.mode3d
        local fn = b:GetScript("OnEnter")
        if fn then fn(b) end
        return
    end
    local bossRef = st.strat and st.strat.b or st.boss
    ask("MAP3D",
        ("This page is drawn on |cffffd100%s|r; %s's room is on |cffffd100%s|r.\n|cff9e9e9eUse that map for this page "
            .. "and open the room?|r"):format(MapUI():MapShortName(p.m, bossRef), S():GetBossName(bossRef),
            MapUI():MapShortName(m.id, bossRef)), function() Board:UseRoomMap() end)
end

function Board:UseRoomMap()
    local p, m = page(), win and roomFloor()
    if not (p and m and st.mode == "edit") then return end
    p.m, p.vx, p.vy, p.vz = m.id, 500, 500, 100
    self:MarkDirty(true)
    self:Set3D(true)
end

-- The 2D / 3D switch: there for a boss that has a room (Render3D/Rooms.lua), 3D chosen while the page shows in it.
local restartSaid = false
function Board:RefreshMode()
    if not win then return end
    local cv = win.canvas
    local room, why, other = cv:Room3D()
    if why == "restart" and not restartSaid and ns.StrategyMap3D == nil then
        -- the update brought new files, which only a client restart reads
        restartSaid = true
        ns:Print("Restart the game client once (a /reload is not enough) to get the strategy board's 3D view.")
    elseif why == "rooms" and not restartSaid then
        restartSaid = true
        local r3 = ns.Render3D
        local text = r3 and r3.DataProblem and r3.DataProblem()
        if text then ns:Print(text) end
    end
    local show = page() ~= nil and (room ~= nil or why == "map")
    win.mode2d:SetShown(show)
    win.mode3d:SetShown(show)
    if not show then return end
    local on = cv:Is3D()
    win.mode3d:SetKind(on and "chosen" or "secondary")
    win.mode2d:SetKind(on and "secondary" or "chosen")
    local where = S():GetBossName(st.strat and st.strat.b or st.boss) .. "'s room"
    if room then
        win.mode3d.tip = "This page in " .. where .. ", as the game draws it, with the boss and its adds. "
            .. "Everything on the map is there; draw and move things in the room too."
    else
        local r = other or {}
        local mapName = r.map
        for _, m in ipairs(ns.Data and ns.Data.RaidMaps or {}) do
            if m.file == r.map then mapName = MapUI():MapShortName(m.id, st.strat and st.strat.b) end
        end
        if st.mode == "edit" then
            win.mode3d.tip = where .. " is on the " .. tostring(mapName) .. " map, and this page is drawn on another. "
                .. "Click to put the page on that map and open the room."
        else
            win.mode3d.tip = "3D shows " .. where .. ", which is on the " .. tostring(mapName) .. " map. This page is "
                .. "drawn on another map."
        end
    end
    win.mode2d.tip = "This page on the map."
end

-- The page's drawings, from 60 of the 80 on (grey, orange from 72, red and "P1 is full" at 80).
function Board:PageFull()
    local p = page()
    return p ~= nil and #p.e >= S().MAX_ELEMENTS
end

function Board:RefreshCount()
    if not win then return end
    local p = page()
    local n, limit = p and #p.e or 0, S().MAX_ELEMENTS
    local show = st.mode == "edit" and p ~= nil and n >= floor(limit * 0.75)
    win.countBtn:SetShown(show)
    if not show then return end
    local fs = win.countFs
    if n >= limit then
        fs:SetText(("%s is full: %d drawings"):format(p.n, limit))
        fs:SetTextColor(Style:Color("BAD"))
    else
        fs:SetText(("%d of %d drawings"):format(n, limit))
        fs:SetTextColor(Style:Color(n >= floor(limit * 0.9) and "WARN" or "SUB"))
    end
    win.countBtn:SetWidth(floor((fs:GetStringWidth() or 100) + 0.5))
end

function Board:CountTooltip(owner)
    local p = page()
    if not p then return end
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    local limit = S().MAX_ELEMENTS
    if #p.e >= limit then
        GameTooltip:AddLine(p.n .. " is full")
        GameTooltip:AddLine(("A page holds %d drawings. Delete some, or put the next phase on a new page."):format(limit),
            1, 1, 1, true)
    else
        GameTooltip:AddLine(("%d of %d drawings"):format(#p.e, limit))
        GameTooltip:AddLine(("A page holds %d drawings."):format(limit), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

function Board:RefreshTools()
    if not win then return end
    local tools = win.tools
    for _, b in ipairs(tools.btns) do b:SetActive(b.key == win.canvas.tool) end
    for i, sw in ipairs(tools.swatches) do
        for _, t in ipairs(sw.ring) do t:SetShown(i == win.canvas.color) end
    end
    local e = win.canvas:GetSelected()
    -- the selection's controls only while something is selected; undo / redo only while they can do something
    tools.delBtn:SetShown(e ~= nil)
    tools.optBtn:SetShown(e ~= nil)
    local align, anyText = win.canvas:TextAlign()
    for _, b in ipairs(tools.alignBtns) do
        b:SetShown(e ~= nil and anyText)
        b:SetActive(b.align == align)
    end
    tools.undoBtn:SetShown(self:CanUndo())
    tools.redoBtn:SetShown(self:CanRedo())
    self:RefreshCount()
end

---------------------------------------------------------------------------
-- The raid's players (assigning): four role columns on the panel's top
---------------------------------------------------------------------------

local ROLE_COLS = { { "tank", "Tanks" }, { "healer", "Healers" }, { "melee", "Melee" }, { "ranged", "Ranged" } }
-- (a player whose spec isn't known: the role the class plays most)
local CLASS_ROLE = { WARRIOR = "melee", ROGUE = "melee", HUNTER = "ranged", MAGE = "ranged", WARLOCK = "ranged",
                     PRIEST = "healer", PALADIN = "healer", SHAMAN = "healer", DRUID = "healer" }
local ROSTER_HEAD = 22
local ROSTER_COL_W = floor((PANEL_W - 20 - 3 * GAP) / 4)

function Board:RefreshPool()
    if not win then return end
    local pool = win.pool
    local cols, at = { {}, {}, {}, {} }, { tank = 1, healer = 2, melee = 3, ranged = 4 }
    for _, m in ipairs(memberList) do
        local role = ns.RaidComp and ns.RaidComp:RoleOf(m.c, m.sp) or nil
        tinsert(cols[at[role or CLASS_ROLE[m.c] or "ranged"] or 4], m)
    end
    for _, list in ipairs(cols) do
        tsort(list, function(a, b) return ns.Util.ShortName(a.key) < ns.Util.ShortName(b.key) end)
    end
    local rows = 0
    for i, c in ipairs(ROLE_COLS) do
        local h = pool.heads[i]
        if not h then
            h = CreateFrame("Frame", nil, pool)
            h:SetSize(ROSTER_COL_W, ROSTER_HEAD)
            h.icon = h:CreateTexture(nil, "ARTWORK")
            h.icon:SetSize(14, 14)
            h.icon:SetPoint("LEFT", 0, 0)
            -- (the ranged role's own icon where the client has it: UI:SetRoleIcon)
            if UI().SetRoleIcon then
                UI():SetRoleIcon(h.icon, c[1])
            else
                h.icon:SetTexture(UI().ROLE_TEX)
                h.icon:SetTexCoord(UI():RoleCoords(c[1] == "melee" and "damager" or c[1]))
            end
            h.fs = UI():Text(h, "body", "GOLD")
            h.fs:SetPoint("LEFT", h.icon, "RIGHT", 5, 0)
            h.fs:SetText(c[2])
            h.line = UI():Rule(h, { bottom = 0 })
            h:SetPoint("TOPLEFT", pool, "TOPLEFT", 10 + (i - 1) * (ROSTER_COL_W + GAP), -6)
            pool.heads[i] = h
        end
        h:SetShown(#memberList > 0)
        rows = max(rows, #cols[i])
    end
    local n = 0
    for i, list in ipairs(cols) do
        for r, m in ipairs(list) do
            n = n + 1
            local chip = pool.chips[n]
            if not chip then
                chip = createPoolChip(pool)
                pool.chips[n] = chip
            end
            chip.key = m.key
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", pool, "TOPLEFT", 10 + (i - 1) * (ROSTER_COL_W + GAP),
                -(6 + ROSTER_HEAD + 2 + (r - 1) * ROSTER_ROW))
            chip:SetWidth(ROSTER_COL_W)
            UI():ClassIcon(chip.icon, m.c)
            local name = coloredName(m.key)
            if m.st == "T" or m.st == "B" then name = name .. " " .. Style:Wrap("SUB", m.st) end
            chip.fs:SetText(name)
            -- never cut: a long name takes a size smaller
            UI():SetTextStyle(chip.fs, "body")
            if (chip.fs:GetStringWidth() or 0) > ROSTER_COL_W - 22 then UI():SetTextStyle(chip.fs, "caps", "TEXT") end
            local jobs = countOf(m.key)
            chip.count:SetText(jobs > 1 and tostring(jobs) or "")
            local picked = st.picked == m.key
            chip:SetSelected(picked)
            chip:SetAlpha(st.dragging == m.key and 0 or ((jobs > 0 and not picked) and 0.5 or 1))
            chip:Show()
        end
    end
    for i = n + 1, #pool.chips do pool.chips[i]:Hide() end
    pool.empty:SetShown(#memberList == 0)
    local h = #memberList == 0 and floor(20 + (pool.empty:GetStringHeight() or 14) + 0.5)
        or (6 + ROSTER_HEAD + 2 + rows * ROSTER_ROW + 6)
    pool.h = h
    pool:SetHeight(h)
    -- how many slots have a name: on the tab row's right end (green once all have one; who has two in one table)
    local filled, total = 0, 0
    for _, s in ipairs(S():GetSlots(st.strat)) do
        total = total + 1
        if st.assign[s.ref] then filled = filled + 1 end
    end
    local twice = {}
    for ref in pairs(dups) do if st.assign[ref] then twice[st.assign[ref]] = true end end
    local nTwice = 0
    for _ in pairs(twice) do nTwice = nTwice + 1 end
    local text = (filled == total and total > 0) and Style:Wrap("OK", ("%d of %d slots filled"):format(filled, total))
        or (Style:Wrap("TEXT", filled) .. (" of %d slots filled"):format(total))
    if nTwice > 0 then text = text .. "  \194\183  " .. Style:Wrap("WARN", nTwice .. " twice") end
    win.slotsFs:SetText(text)
end

---------------------------------------------------------------------------
-- The tab row
---------------------------------------------------------------------------

local function createTab(i)
    local c = win.content
    local b = UI():CreateUnderlineTab(c, "", nil, "page")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.chev = b:CreateTexture(nil, "ARTWORK")
    b.chev:SetSize(9, 9)
    b.chev:SetTexture(TOOL_ATLAS)
    b.chev:SetTexCoord(unpack(atlasCoords(UI().ICON.chevron)))
    b.chev:SetVertexColor(Style:Color("GOLD"))
    b.chev:SetPoint("LEFT", b:GetFontString(), "RIGHT", 4, -1)
    b.dots = {}
    b:SetScript("OnClick", function(self, button)
        local idx = self.index
        if button == "RightButton" then
            if st.mode == "edit" then Board:PageMenu(self, idx) end
            return
        end
        if idx == st.page then
            if st.mode == "edit" then Board:PageMenu(self, idx) end
        else
            st.page = idx
            Board:Refresh()
        end
    end)
    b:SetScript("OnDoubleClick", function(self)
        if st.mode ~= "edit" then return end
        if win.pageMenu and win.pageMenu.Close then win.pageMenu:Close() end
        Board:RenamePage(self.index)
    end)
    win.tabs[i] = b
    return b
end

function Board:RefreshTabs()
    local c = win.content
    local pages = st.strat and st.strat.p or {}
    local editing = st.mode == "edit"
    -- the pages the others on my live board are on: a dot in their colour on that tab
    local dots = {}
    for _, e in ipairs(presence().live) do
        if e.pg and e.pg ~= st.page then
            dots[e.pg] = dots[e.pg] or {}
            tinsert(dots[e.pg], e.key)
        end
    end
    -- the map link (and the count) while editing, the slots count while assigning: the tabs end before them
    local p = page()
    local limit = PAD + HDR_W
    if editing then
        win.mapBtn:SetLabel(MapUI():MapShortName(p and p.m, st.strat and st.strat.b))
        self:RefreshCount()
        limit = PAD + MAP_W - (win.mapBtn:GetWidth() or 160) - 16
        if win.countBtn:IsShown() then limit = limit - (win.countBtn:GetWidth() or 100) - 14 end
    elseif st.mode == "fill" then
        limit = PAD + HDR_W - (win.slotsFs:GetStringWidth() or 120) - 16
    end
    local function lay(small)
        local x = TABS_X
        for i, pg in ipairs(pages) do
            local b = win.tabs[i] or createTab(i)
            b.index = i
            local fs = b:GetFontString()
            fs:SetFontObject(small and "GameFontHighlightSmall" or "GameFontHighlight")
            b:SetText(pg.n)
            local chev = editing and i == st.page
            local w = floor((fs:GetStringWidth() or 30) + (small and 12 or 16) + (chev and 13 or 0) + 0.5)
            b:SetSize(w, TABS_H)
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", chev and -6 or 0, 1)
            b.chev:SetShown(chev)
            b:SetActive(i == st.page)
            for k, d in ipairs(b.dots) do d:SetShown(dots[i] ~= nil and dots[i][k] ~= nil) end
            for k, key in ipairs(dots[i] or {}) do
                if k <= 3 then
                    local d = b.dots[k]
                    if not d then
                        d = b:CreateTexture(nil, "OVERLAY")
                        d:SetSize(6, 6)
                        d:SetTexture(MapUI().TEX.disc)
                        d:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1 - (k - 1) * 7, -3)
                        b.dots[k] = d
                    end
                    d:SetVertexColor(Collab():ColorOf(key))
                    d:Show()
                end
            end
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", c, "TOPLEFT", x, -(TABS_Y + TABS_H))
            b:Show()
            x = x + w
        end
        local add = editing and #pages < S().MAX_PAGES
        if add then x = x + 24 end
        return x, add
    end
    local x, add = lay(false)
    if x > limit then x, add = lay(true) end
    for i = #pages + 1, #win.tabs do win.tabs[i]:Hide() end
    win.addPage:ClearAllPoints()
    win.addPage:SetPoint("BOTTOMLEFT", c, "TOPLEFT", x - 24, -(TABS_Y + TABS_H))
    win.addPage:SetShown(add and true or false)
    win.mapBtn:SetShown(editing and p ~= nil)
    if not editing then win.countBtn:Hide() end
    win.slotsFs:SetShown(st.mode == "fill")
end

---------------------------------------------------------------------------
-- The header
---------------------------------------------------------------------------

-- The line about the strategy beside its name: for which raid (assigning), the raid and who assigned it (a raid's
-- board), who made it and when (someone else's), when I saved it (mine); nothing while editing.
local function metaText(s)
    if st.sandbox or not s or st.mode == "edit" then return nil end
    local v = raidView()
    if st.mode == "fill" then return v and ("for " .. Style:Wrap("TEXT", raidWhen(v.t))) or nil end
    if v then
        local f = S():GetFill(st.occ, st.boss)
        local by = f and f.by and not ns.Util.IsMe(f.by) and f.by
        return raidWhen(v.t) .. (by and (" \194\183 by " .. coloredName(by)) or "")
    end
    local owner = s.ow or s.by
    if owner and ns.Util.IsMe(owner) then
        if not s.rev then return nil end
        local now = GetServerTime and GetServerTime() or time()
        if now - s.rev < 120 then return Style:Wrap("OK", "Saved just now") end
        if date("%Y%m%d", s.rev) == date("%Y%m%d", now) then return "Saved " .. date("%H:%M", s.rev) end
        return "Saved " .. (date("%d %b", s.rev):gsub("^0", ""))
    end
    if owner then
        return "by " .. coloredName(owner) .. (s.rev and (" \194\183 " .. (date("%d %b", s.rev):gsub("^0", ""))) or "")
    end
    return nil
end

-- The state tag: one at a time. -> kind, text (or nil).
local function stateOf(pr)
    if st.sandbox then return "alt", "Practice \194\183 nothing is saved or shared", "practice" end
    if pr.joining then
        local from = pr.live[1] and ns.Util.ShortName(pr.live[1].key)
        return "bis", (from and ("Joining " .. from .. "'s board") or "Joining the live board")
            .. (" \194\183 %d%%"):format(pr.joining * 100), "joining"
    end
    if st.mode == "edit" and st.stale then return "warn", "Newer version by " .. ns.Util.ShortName(st.stale), "stale" end
    if st.dirty and (st.mode == "edit" or st.mode == "fill") then return "warn", "Unsaved", "unsaved" end
    -- (1.4: reading a strategy I can neither change nor assign: say so instead of only leaving the buttons out)
    if st.mode == "view" and st.strat and not canEditStrat(st.strat) and not (st.occ and canAssign()) then
        return "mute", "Read only", "readonly"
    end
    return nil
end

function Board:StateTooltip(owner)
    local why = win.stateTag.why
    if not why then return end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    if why == "practice" then
        GameTooltip:AddLine("Practice")
        GameTooltip:AddLine("The tutorial's practice board: nothing here is saved or shared. New strategy (Raids > "
            .. "Strategies) starts a real one.", 1, 1, 1, true)
    elseif why == "joining" then
        GameTooltip:AddLine("Joining a live board")
        GameTooltip:AddLine("Someone is editing this strategy: your board becomes theirs, and your changes and theirs "
            .. "show at once on both.", 1, 1, 1, true)
    elseif why == "readonly" then
        GameTooltip:AddLine("Read only")
        GameTooltip:AddLine("Its owner, the guild members they invited, the GM and the guild council change this "
            .. "strategy. Copy (the ... menu) makes one that is yours.", 1, 1, 1, true)
    elseif why == "stale" then
        local cur = st.strat and st.strat.id and S():GetStrategy(st.strat.id)
        GameTooltip:AddLine("Newer version by " .. ns.Util.ShortName(st.stale))
        GameTooltip:AddLine(("%s saved this strategy%s, after you started. Save puts your version in its place; "
            .. "Discard keeps theirs."):format(ns.Util.ShortName(st.stale), cur and cur.rev and (" at " .. date("%H:%M", cur.rev))
            or ""), 1, 1, 1, true)
    elseif st.mode == "fill" then
        GameTooltip:AddLine("Unsaved")
        GameTooltip:AddLine("Your names for this raid are a draft: they stay when you close the board, /reload or "
            .. "disconnect.", 1, 1, 1, true)
        GameTooltip:AddLine("Save shares them with the raid; Discard throws them away.", 0.6, 0.6, 0.6, true)
    else
        GameTooltip:AddLine("Unsaved")
        GameTooltip:AddLine("A draft: it stays when you close the board, /reload or disconnect, and waits in Raids > "
            .. "Strategies.", 1, 1, 1, true)
        GameTooltip:AddLine("Save shares it with the guild; Discard throws it away.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

function Board:MetaTooltip(owner)
    local s = st.strat
    if not s then return end
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine(s.n)
    if win.metaHidden and win.metaHidden ~= "" then GameTooltip:AddLine(win.metaHidden, 1, 1, 1) end
    local v = raidView()
    if v then GameTooltip:AddLine(ns.RaidPlan:GetRaidName(v) .. ", " .. date("%a %d %b %H:%M", v.t), 1, 1, 1) end
    local owner2 = s.ow or s.by
    if owner2 then GameTooltip:AddLine("Made by " .. coloredName(owner2), 1, 1, 1) end
    if s.co and #s.co > 0 then
        local names = {}
        for _, key in ipairs(s.co) do names[#names + 1] = coloredName(key) end
        GameTooltip:AddLine("Built with " .. tconcat(names, ", "), 1, 1, 1, true)
    end
    if s.rev then
        GameTooltip:AddLine("Saved " .. date("%d %b %H:%M", s.rev) .. ((s.by and s.by ~= owner2) and (" by " ..
            coloredName(s.by)) or ""), 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

-- Who is here: a green Live and the class circles of the members on my live board; the others who have it open as
-- circles too (a reader's faded).
function Board:RefreshPresence()
    local live, pr = win.live, presence()
    local faces = {}
    for _, e in ipairs(pr.live) do faces[#faces + 1] = { e.key, false } end
    for _, key in ipairs(pr.editing) do faces[#faces + 1] = { key, false } end
    for _, key in ipairs(pr.looking) do faces[#faces + 1] = { key, true } end
    if #faces == 0 then
        live:Hide()
        return 0
    end
    local isLive = #pr.live > 0
    live.dot:SetShown(isLive)
    live.fs:SetShown(isLive)
    local x = isLive and floor(6 + 6 + (live.fs:GetStringWidth() or 24) + 6 + 0.5) or 0
    for i = 1, max(#faces, #live.faces) do
        local f = live.faces[i]
        if i <= 5 and faces[i] then
            if not f then
                f = CreateFrame("Frame", nil, live)
                f:SetSize(24, 24)
                f.ring = f:CreateTexture(nil, "ARTWORK", nil, 1)
                f.ring:SetAllPoints()
                f.ring:SetTexture(MapUI().TEX.disc)
                f.ring:SetVertexColor(0.1, 0.1, 0.11, 1)
                f.icon = f:CreateTexture(nil, "ARTWORK", nil, 2)
                f.icon:SetSize(20, 20)
                f.icon:SetPoint("CENTER")
                live.faces[i] = f
            end
            f:ClearAllPoints()
            f:SetPoint("LEFT", live, "LEFT", x + (i - 1) * 15 - 2, 0)
            f:SetFrameLevel(live:GetFrameLevel() + i)
            UI():ClassIcon(f.icon, ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(faces[i][1]) or nil)
            f:SetAlpha(faces[i][2] and 0.55 or 1)
            f:Show()
        elseif f then
            f:Hide()
        end
    end
    local w = x + 20 + (min(#faces, 5) - 1) * 15
    live:SetWidth(w)
    live:Show()
    return w
end

function Board:PresenceTooltip(owner)
    local pr = presence()
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    local function line(key, where)
        GameTooltip:AddLine(classIconText(ns.Guild and ns.Guild.GetClass and ns.Guild:GetClass(key), 13) .. " "
            .. presenceName(key) .. "  " .. Style:Wrap("SUB", where), 1, 1, 1)
    end
    if #pr.live > 0 then
        GameTooltip:AddLine("Live")
        GameTooltip:AddLine("Your boards are one board: changes show at once.", 0.6, 0.6, 0.6, true)
        for _, e in ipairs(pr.live) do
            local p = e.pg and st.strat.p[e.pg]
            line(e.key, e.pg == st.page and "on this page" or (p and ("on " .. p.n) or ""))
        end
    else
        GameTooltip:AddLine(st.strat and st.strat.n or "Here now")
    end
    for _, key in ipairs(pr.editing) do line(key, "editing") end
    for _, key in ipairs(pr.looking) do line(key, "looking") end
    if #pr.live > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Undo takes back your own changes. One Save saves it for all of you.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

function Board:RefreshHeader()
    local s, mode = st.strat, st.mode
    local hdr = win.header
    local bossRef = st.boss or (s and s.b)
    local inst = raidInst()
    if hdr.artKey ~= inst then hdr:SetArt(inst ~= "other" and inst or nil) end
    win.bossFs:SetText(S():GetBossName(bossRef))
    local assigner = canAssign() or st.sandbox == true
    -- the right side, right to left: the text buttons (the main one gold), then the icons, then who is here
    local texts, icons = {}, {}
    win.cancelBtn:SetText(st.sandbox and "Close" or "Discard")
    win.cancelBtn:SetWidth(floor((win.cancelBtn:GetFontString():GetStringWidth() or 50) + 24 + 0.5))
    if st.sandbox then
        texts = { win.cancelBtn }
    elseif mode == "edit" or mode == "fill" then
        texts = st.dirty and { win.saveBtn, win.cancelBtn } or { win.doneBtn }
    elseif s and st.occ and assigner then
        texts = { win.fillBtn }
    elseif s and not st.occ and canEditStrat(s) then
        texts = { win.editBtn }
    end
    if s then icons[#icons + 1] = win.moreBtn end
    if mode == "view" and s and s.id and not st.sandbox then icons[#icons + 1] = win.shareBtn end
    icons[#icons + 1] = win.helpBtn
    for _, w in ipairs({ win.saveBtn, win.cancelBtn, win.doneBtn, win.editBtn, win.fillBtn, win.moreBtn, win.shareBtn,
                         win.helpBtn }) do
        w:Hide()
    end
    local x = HDR_W - 6
    for _, w in ipairs(texts) do
        w:ClearAllPoints()
        w:SetPoint("RIGHT", hdr, "LEFT", x, 0)
        w:Show()
        x = x - (w:GetWidth() or 60) - 6
    end
    if #texts > 0 then x = x - 12 end
    for _, w in ipairs(icons) do
        w:ClearAllPoints()
        w:SetPoint("RIGHT", hdr, "LEFT", x, 0)
        w:Show()
        x = x - 24 - 6
    end
    local liveW = self:RefreshPresence()
    if liveW > 0 then
        x = x - 4
        win.live:ClearAllPoints()
        win.live:SetPoint("RIGHT", hdr, "LEFT", x, 0)
        x = x - liveW
    end
    local limit = x - 16

    -- the left side: the boss, the name (the strategy switch for who assigns the raid; a click renames it while
    -- editing), the line about it, the state tag; what doesn't fit moves into the tooltips, never "..."
    local switch = st.occ ~= nil and not st.sandbox and mode ~= "edit" and (assigner or s == nil)
    local typing = win.titleEdit:IsShown()
    win.stratDD:SetShown(switch)
    win.title:SetShown(not switch and not typing)
    win.titleBtn:SetShown(mode == "edit" and s ~= nil and not typing and not st.sandbox)
    win.pencil:SetShown(mode == "edit" and s ~= nil and not typing and not st.sandbox)
    local nameText = s and s.n or nil
    local nameW
    if switch then
        win.stratDD:SetLabel(nameText or "|cff9e9e9eNo strategy yet|r")
        nameW = win.stratDD:GetWidth() or 120
    elseif typing then
        nameW = win.titleEdit:GetWidth() or 160
    else
        win.title:SetText(nameText or "|cff9e9e9eNo strategy yet|r")
        nameW = floor((win.title:GetStringWidth() or 120) + 0.5)
        if win.pencil:IsShown() then nameW = nameW + 5 + 12 end
    end
    local meta = metaText(s)
    local kind, tag, why = stateOf(presence())
    win.stateTag.why = why
    local function place(showMeta, tagWords)
        local px = 12
        win.bossFs:ClearAllPoints()
        win.bossFs:SetPoint("LEFT", hdr, "LEFT", px, 0)
        px = px + floor((win.bossFs:GetStringWidth() or 80) + 0.5) + 10
        win.stratDD:ClearAllPoints()
        win.stratDD:SetPoint("LEFT", hdr, "LEFT", px, 0)
        win.title:ClearAllPoints()
        win.title:SetPoint("LEFT", hdr, "LEFT", px, 0)
        win.pencil:ClearAllPoints()
        win.pencil:SetPoint("LEFT", win.title, "RIGHT", 5, 0)
        px = px + nameW
        win.meta:SetShown(showMeta and meta ~= nil)
        if showMeta and meta then
            win.meta:SetText(meta)
            win.meta:ClearAllPoints()
            win.meta:SetPoint("LEFT", hdr, "LEFT", px + 10, 0)
            px = px + 10 + floor((win.meta:GetStringWidth() or 80) + 0.5)
        end
        win.stateTag:SetShown(kind ~= nil)
        if kind then
            win.stateTag:Set(tagWords and tag or "", kind)
            win.stateTag:ClearAllPoints()
            win.stateTag:SetPoint("LEFT", hdr, "LEFT", px + 10, 0)
            px = px + 10 + (win.stateTag:GetWidth() or 60)
        end
        return px
    end
    win.metaHidden = nil
    if place(true, true) > limit then
        win.metaHidden = meta and meta or nil
        if place(false, true) > limit then place(false, false) end
    end
    -- the line's tooltip: over the line, else (moved out of the way) over the name
    win.metaBtn:ClearAllPoints()
    local over = win.meta:IsShown() and win.meta or (switch and win.stratDD or win.title)
    win.metaBtn:SetPoint("TOPLEFT", over, "TOPLEFT", -2, 4)
    win.metaBtn:SetPoint("BOTTOMRIGHT", over, "BOTTOMRIGHT", 2, -4)
    -- (never over the strategy switch: it takes the clicks)
    win.metaBtn:SetShown(mode ~= "edit" and s ~= nil and (win.meta:IsShown() or (not switch and win.metaHidden ~= nil)))
end

---------------------------------------------------------------------------
-- The dock's left end while reading: my jobs (a raid's board), the raids that use it (a strategy on its own)
---------------------------------------------------------------------------

-- The raids coming up (the next 14 days) whose board for this strategy's boss shows this strategy.
function Board:RaidsUsing(id)
    local s = id and S():GetStrategy(id)
    local RP = ns.RaidPlan
    if not (s and RP and RP.GetRaids) then return {} end
    local inst = instOfBoss(s.b)
    local now = GetServerTime and GetServerTime() or time()
    local out = {}
    for _, v in ipairs(RP:GetRaids(now - 4 * 3600, now + 14 * 86400)) do
        local holds = false
        for _, key in ipairs(RP:GetRaidInstances(v)) do
            if key == inst then holds = true end
        end
        if not v.cancelled and holds then
            local used = S():GetRaidStrategy(v.id, s.b)
            if used and used.id == id then out[#out + 1] = v end
        end
    end
    return out
end

-- A job of mine as the dock shows it: its row's target icon (else the table's), the job, the page.
local function jobParts(s, slot)
    local k = S():FindBlock(s, slot.block)
    if not k then return nil, slot.label end
    local icon, rowLabel
    for ci, col in ipairs(k.c) do
        local v = k.d and k.d[slot.row] and k.d[slot.row][ci]
        if col.t == "g" and type(v) == "table" then
            icon = icon or v.i
            rowLabel = rowLabel or v.l
        elseif col.t == "x" and type(v) == "string" and not rowLabel then
            rowLabel = v:gsub("\n", " ")
        end
    end
    local pcols = 0
    for _, col in ipairs(k.c) do if col.t == "p" then pcols = pcols + 1 end end
    local colName = pcols > 1 and k.c[slot.col] and k.c[slot.col].n
    local text = rowLabel or colName or (k.r > 1 and (k.n .. " " .. slot.row) or k.n)
    return icon or k.i, text
end

-- Opens the page of a job of mine and lights its row and its drawing.
function Board:ShowJob(ref)
    local s = st.strat
    if not s then return end
    for _, slot in ipairs(S():GetSlots(s)) do
        if slot.ref == ref then
            if st.page ~= slot.page then
                st.page = slot.page
                self:Refresh()
            end
            win.blocks:ScrollTo(ref)
            win.blocks:Highlight(ref)
            win.canvas:Highlight(ref)
            return
        end
    end
end

local function dockChips(holder, n, gold)
    holder.chips = holder.chips or {}
    for i = 1, n do
        if not holder.chips[i] then holder.chips[i] = dockChip(holder, gold) end
    end
    return holder.chips
end

function Board:RefreshDock()
    local s, mode = st.strat, st.mode
    local jobs, inRaids = win.jobs, win.inRaids
    jobs:Hide()
    inRaids:Hide()
    if mode ~= "view" or not s then return end
    local room = SEG_X - 14
    if st.occ then
        local me = ns.Util.PlayerKey()
        local mine = S():GetPlayerSlots(s, st.assign, me)
        local any = next(st.assign) ~= nil
        jobs:Show()
        -- (no job of mine: one quiet line instead of the label)
        jobs.label:SetText(#mine > 0 and "YOUR JOBS" or (any and "No job for you on this board" or
            "No names for this raid yet"))
        UI():SetTextStyle(jobs.label, #mine > 0 and "small" or "body", #mine > 0 and "GOLD" or "SUB")
        local x = floor((jobs.label:GetStringWidth() or 60) + 0.5) + 10
        local chips = dockChips(jobs, #mine, true)
        local shown = 0
        for i, slot in ipairs(mine) do
            local c = chips[i]
            local icon, text = jobParts(s, slot)
            c:Set(icon, nil, text, #s.p > 1 and slot.pageName or nil)
            local w = c:GetWidth() or 100
            -- the rest in one "+n" chip when they don't all fit
            if x + w > room - (i < #mine and 44 or 0) and i > 1 then
                c:Set(nil, nil, "+" .. (#mine - i + 1))
                c.ref, c.rest = nil, { unpack(mine, i) }
                c:ClearAllPoints()
                c:SetPoint("LEFT", jobs, "LEFT", x, 0)
                c:Show()
                shown = i
                break
            end
            c.ref, c.rest = slot.ref, nil
            c:ClearAllPoints()
            c:SetPoint("LEFT", jobs, "LEFT", x, 0)
            c:Show()
            x = x + w + 6
            shown = i
        end
        for i = 1, #chips do
            local c = chips[i]
            if i > shown then c:Hide() end
            c:SetScript("OnClick", function(self) if self.ref then Board:ShowJob(self.ref) end end)
            c:SetScript("OnEnter", function(self)
                chipHover(self, true)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                if self.rest then
                    for _, sl in ipairs(self.rest) do
                        GameTooltip:AddLine(sl.label .. (#s.p > 1 and Style:Wrap("DIM", "  " .. sl.pageName) or ""), 1, 1, 1)
                    end
                else
                    GameTooltip:AddLine(slotLabels[self.ref] or "")
                    GameTooltip:AddLine("Shows its page and lights the row and its drawing.", 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            c:SetScript("OnLeave", function(self)
                chipHover(self, false)
                GameTooltip:Hide()
            end)
        end
        return
    end
    if not s.id or st.sandbox then return end
    local raids = self:RaidsUsing(s.id)
    if #raids == 0 then return end
    inRaids:Show()
    local x = floor((inRaids.label:GetStringWidth() or 60) + 0.5) + 10
    local chips = dockChips(inRaids, #raids, false)
    local shown = 0
    for i, v in ipairs(raids) do
        local c = chips[i]
        c:Set(nil, (date("%a %d", v.t):gsub(" 0", " ")):upper(), ns.RaidPlan:GetRaidName(v), nil, true)
        local w = c:GetWidth() or 120
        if x + w > room then break end
        c.occ = v.id
        c:ClearAllPoints()
        c:SetPoint("LEFT", inRaids, "LEFT", x, 0)
        c:SetScript("OnClick", function(self) Board:OpenRaid(self.occ, s.b) end)
        c:SetScript("OnEnter", function(self)
            chipHover(self, true)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(ns.RaidPlan:GetRaidName(v))
            GameTooltip:AddLine(date("%A %d %B, %H:%M", v.t), 1, 1, 1)
            GameTooltip:AddLine("Opens the raid's board with its names.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function(self)
            chipHover(self, false)
            GameTooltip:Hide()
        end)
        c:Show()
        x = x + w + 6
        shown = i
    end
    for i = shown + 1, #chips do chips[i]:Hide() end
end

-- Assigning: the actions on the names, left to right (Carry over only when an earlier raid used the strategy, Clear
-- all only when something is filled).
function Board:RefreshFillBar()
    local pool, x = win.pool, 0
    local carry = st.mode == "fill" and st.strat and st.strat.id and not st.sandbox
        and S():GetLastFill(st.strat.id, st.occ) ~= nil
    local clear = next(st.assign) ~= nil
    for _, e in ipairs({ { pool.carryBtn, carry }, { pool.suggestBtn, true }, { pool.clearBtn, clear } }) do
        local b, on = e[1], e[2]
        b:SetShown(on and true or false)
        if on then
            b:ClearAllPoints()
            b:SetPoint("LEFT", win.fillBar, "LEFT", x, 0)
            x = x + (b:GetWidth() or 80) + 6
        end
    end
end

---------------------------------------------------------------------------
-- Menus: ? (help) and ⋯ (the strategy's occasional things)
---------------------------------------------------------------------------

function Board:OpenHelp(owner)
    UI():ContextMenu(owner, function(root) Board:HelpMenu(root) end)
end

function Board:HelpMenu(root)
    root:CreateTitle("Help")
    if ns.Tour and ns.Tour.BuildMenu then ns.Tour:BuildMenu(root, "strategy") end
    root:CreateDivider()
    root:CreateButton(menuEntry(UI().ICON.keys, "Keyboard and mouse"), function() Board:ShowKeys() end)
end

function Board:OpenMore(owner)
    UI():ContextMenu(owner, function(root) Board:MoreMenu(root) end)
end

local function menuButton(root, icon, word, tip, fn, red)
    local b = root:CreateButton(menuEntry(icon, word, red), fn)
    if tip and b and b.SetTooltip then
        b:SetTooltip(function(tt)
            tt:AddLine(word, unpack(Style.C.GOLD))
            tt:AddLine(tip, 1, 1, 1, true)
        end)
    end
    return b
end

local PRACTICE_TIP = "Try this strategy's in-fight helpers alone: your jobs panel, whose kick it is, marks on what you "
    .. "target. Demo players fill the other slots; use your real spells on a target dummy."

function Board:MoreMenu(root)
    local s = st.strat
    if not s then return end
    root:CreateTitle(s.n)
    local function practice()
        menuButton(root, UI().ICON.practice, "Practice", PRACTICE_TIP, function()
            if st.strat and ns.StrategyPractice then ns.StrategyPractice:Start(st.strat) end
        end)
    end
    if st.mode == "edit" then
        -- the raid leader's client marks the mobs from the portraits' raid mark badges (Core/StrategyLive.lua)
        local am = root:CreateCheckbox("Auto-mark", function() return st.strat and st.strat.am ~= false end, function()
            if not st.strat then return end
            if st.strat.am == false then st.strat.am = nil else st.strat.am = false end
            Board:MarkDirty(true)
        end)
        if am and am.SetTooltip then
            am:SetTooltip(function(tt)
                tt:AddLine("Auto-mark", Style:RGB("GOLD"))
                tt:AddLine("In the raid, the raid leader's DisasterZone puts the raid marks shown on the boss portraits "
                    .. "on the mobs as their nameplates appear.", 1, 1, 1, true)
            end)
        end
        practice()
        if s.id and not st.sandbox and ns.Util.IsMe(s.ow or s.by) then
            root:CreateDivider()
            menuButton(root, 19, "Collaborators", "Pick the guild members who build it with you.",
                function() ns.StrategiesUI:OpenShare(s.id) end)
        end
        return
    end
    practice()
    if st.mode ~= "view" or st.sandbox or not s.id then return end
    local entries = ns.StrategiesUI and ns.StrategiesUI.StrategyMoreEntries and ns.StrategiesUI:StrategyMoreEntries(s) or {}
    local function add(e) menuButton(root, e[1], e[2], e[3], e[4], e[5]) end
    for _, e in ipairs(entries) do
        if not e[5] then add(e) end
    end
    -- a raid's board: Edit changes the strategy itself, for who may
    if st.occ and canEditStrat(s) then
        menuButton(root, 16, "Edit", "Change the strategy itself: the map, the jobs, the pages. The raid's names "
            .. "stay.", function() Board:SetMode("edit") end)
    end
    for _, e in ipairs(entries) do
        if e[5] then
            root:CreateDivider()
            add(e)
        end
    end
end

-- The page's map (the link at the map's right edge).
function Board:MapMenu(root)
    local p = page()
    if not p then return end
    MapUI():BuildMapMenu(root, st.strat.b, p.m, function(id)
        p.m = id
        p.vx, p.vy, p.vz = 500, 500, 100
        Board:MarkDirty(true)
    end, promptFn, {
        title = "Map of " .. p.n,
        reset = function()
            p.vx, p.vy, p.vz = 500, 500, 100
            Board:MarkDirty(true)
        end,
    })
end

---------------------------------------------------------------------------
-- Keyboard and mouse: a card under ? (Esc, its x or ? again close it)
---------------------------------------------------------------------------

local KEY_ROW, KEY_COL = 21, 118

local function createKeys()
    -- (on UIParent like the prompt: over the board and everything drawn on its map) a card with its title, the
    -- window's close X, caps headers over the groups and the keys as pills
    local k = CreateFrame("Frame", "DisasterZoneStrategyKeys", UIParent)
    k:SetFrameStrata("FULLSCREEN_DIALOG")
    k:SetToplevel(true)
    k:EnableMouse(true)
    k.card = UI():CreateCard(k, { tone = "card", title = "Keyboard and mouse", pad = 14 })
    k.card:SetAllPoints()
    k.card.bg:SetColorTexture(Style:Color("SURFACE_WINDOW"))      -- (opaque: over the map and the panel)
    k.title = k.card.title
    k.close = UI():CreateCloseButton(k, 16, function() k:Hide() end)
    k.close:SetPoint("TOPRIGHT", -10, -10)
    local colW = floor((612 - 28 - 22) / 2)
    local function column(groups, x)
        local y = 13 + 16 + 4
        for _, g in ipairs(groups) do
            local h = UI():CreateSectionHeader(k, g[1], { style = "caps", width = colW })
            h:SetPoint("TOPLEFT", x, -(y + 6))
            y = y + 8 + 13 + 3
            for _, row in ipairs(g[2]) do
                local kx = 0
                for part in row[1]:gmatch("[^|]+") do
                    local cap = UI():CreatePill(k, "mute", part)
                    cap:SetPoint("LEFT", k, "TOPLEFT", x + kx, -(y + KEY_ROW / 2))
                    kx = kx + (cap:GetWidth() or 30) + 3
                end
                local d = UI():Text(k.card, "body", "TEXT")
                d:SetPoint("LEFT", k, "TOPLEFT", x + KEY_COL + 8, -(y + KEY_ROW / 2))
                d:SetText(row[2])
                y = y + KEY_ROW
            end
        end
        return y
    end
    local a = column({ SHORTCUTS[1], SHORTCUTS[2] }, 14)
    local b = column({ SHORTCUTS[3], SHORTCUTS[4], SHORTCUTS[5] }, 14 + colW + 22)
    k:SetSize(612, max(a, b) + 12)
    -- Esc closes the card only (the board stays); the other keys go on as usual
    k:EnableKeyboard(true)
    k:SetScript("OnKeyDown", function(self, key)
        local used = key == "ESCAPE"
        if used then self:Hide() end
        if not InCombatLockdown() and self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(not used) end
    end)
    k:Hide()
    return k
end

function Board:ShowKeys()
    if not win then return end
    self.keys = self.keys or createKeys()
    local k = self.keys
    if k:IsShown() then return k:Hide() end
    k:SetScale(win:GetScale() or 1)
    k:ClearAllPoints()
    k:SetPoint("TOPRIGHT", win.header, "BOTTOMRIGHT", 0, -4)
    k:Show()
    k:Raise()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function Board:Refresh()
    keepDraft()
    if not win or not win:IsShown() then return end
    if st.strat and not st.strat.p[st.page] then st.page = 1 end
    rebuildSlots()
    rebuildMembers()
    rebuildDups()
    local mode = st.mode
    win:SetWindowTitle("Strategy board")
    self:RefreshHeader()
    if mode == "fill" then self:RefreshPool() end
    self:RefreshTabs()
    win.canvas:SetPage(page())
    win.canvas:UpdateHint()
    self:RefreshMode()
    self:Layout(mode)
    win.blocks:Render()
    win.tools:SetShown(mode == "edit")
    win:EnableKeyboard((mode == "edit" or mode == "fill") and not InCombatLockdown())
    win.pool:SetShown(mode == "fill")
    win.fillBar:SetShown(mode == "fill")
    if mode == "edit" then self:RefreshTools() elseif mode == "fill" then self:RefreshFillBar() end
    self:RefreshDock()
    Collab():BoardChanged()
end

-- Places what moves between modes: the map stays 840 x 559 at (10, 84) in every mode; while assigning, the raid's
-- players take the panel's top and the tables scroll under them.
function Board:Layout(mode)
    local top = MAP_Y
    if mode == "fill" then top = MAP_Y + (win.pool.h or 0) + GAP end
    local sf = win.blocks.scroll
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", win.content, "TOPLEFT", PANEL_X, -top)
    sf:SetSize(PANEL_W, MAP_Y + PANEL_H - top)
    win.blocks.width = PANEL_W
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Board:OnLogin()
    -- unsaved work of the last session
    local n = 0
    for _ in pairs(draftStore() or {}) do n = n + 1 end
    if n > 0 then
        C_Timer.After(6, function()
            if Board:HasDraft() and not Board:IsShown() then
                ns:Print("You have %d unsaved strategy draft%s: Raids > Strategies lists %s under %s boss "
                    .. "(/dz strat draft opens the latest).", n, n == 1 and "" or "s", n == 1 and "it" or "them",
                    n == 1 and "its" or "their")
            end
        end)
    end
end

function Board:OnInit()
    local function refresh()
        if not (win and win:IsShown()) then return end
        -- a newer saved copy of what I'm looking at replaces it (never my unsaved draft)
        if st.mode == "edit" and st.strat and st.strat.id and not st.occ then
            local s = S():GetStrategy(st.strat.id)
            if s and (s.rev ~= st.strat.rev or s.by ~= st.strat.by) then
                if Collab():SameContent(s, st.strat) then
                    -- what was saved is what my board says (someone on the same live board saved it): nothing
                    -- of mine is unsaved any more, and the board stays the tables it is
                    st.strat.rev, st.strat.by, st.strat.ow, st.strat.co = s.rev, s.by, s.ow, s.co
                    st.dirty, st.base, st.stale = false, Collab():ContentHash(s), nil
                elseif not st.dirty then
                    st.strat = s
                    st.base, st.stale = Collab():ContentHash(s), nil
                    Collab():Adopted()
                else
                    checkStale()
                end
            end
        elseif not st.dirty and st.strat and st.strat.id then
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
    ns:On("STRATEGY_PRESENCE_CHANGED", function()
        if win and win:IsShown() then ns.Util.Debounce("strategy-board", 0.2, function() Board:Refresh() end) end
    end)
    ns:On("RAIDPLAN_CHANGED", refresh)
    ns:On("ROSTER_UPDATED", refresh)
end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterPanels.lua", ...) then return end -- DisasterZone: meter panels that dock.
-- The on-screen part of the meters (the approved "new look & docking" mockup, 2026-10-10). Everything is a panel and
-- any panel shows any view: a meter mode of Core/Meter.lua (Damage done, DPS, Healing, ...) or Threat
-- (Core/Threat.lua). Panels live in stacks: a stack is one frame with one border, its panels one under the other
-- with a hairline between them, and it moves, fades and locks as one.
--   Header (24 px): the view's icon and name with a chevron (a menu of views and fights), or the panel's tabs; a dim
--   note (an older fight's name, "no target", "nobody died"); the total on the right; + (a new panel) and x (close
--   the tab or panel). Right-click: the panel menu.
--   Fight line (meter views, 18 px): "<  Al'ar  5:12 · 5 of 6  >": the arrows (or the wheel over it) step to an
--   older / newer fight, the name opens the fight list. The fight belongs to the panel: every tab shows it.
--   Body: as tall as its rows, up to the panel's own row limit (the stack's corner sets it, and the width): no empty
--   boxes; a panel with nothing to show is just its header.
-- Docking (while Edit layout is open, /dz edit: the panels are unlocked and raised over its overlay, and a moving stack
-- snaps to the screen's centre and the other frames like everything else there): drag the top header to move a stack; drag a lower header (or the top one
-- with Shift) to pull that panel out; drag a tab out to make it a panel. While dragging, the stack it would join gets a
-- gold outline and a gold line shows where: over its top or bottom half it joins the stack (one under the other);
-- beside it, it joins its row (stacks side by side that move together, s.g = the row's number; Shift-drag a top
-- header to take that stack out of its row); over a panel's header it becomes a tab there ("Drop to add as a tab").
-- Growing: a stack in the lower half of the screen is held by its bottom edge (b) and grows upward, one in the upper
-- half by its top (y) and grows downward; in a fight a panel only grows (it shrinks back after), so nothing jumps.
-- Layout (meters.layout, saved): { v = 2, stacks = { { x, y (top) | b (bottom), in the holder's units, w, panels = {
--   { tabs = { { view, seg } }, active, rows } } } } }. Views whose meter is off are left out (a panel with none
-- left hides) and come back when it is turned on again; turning a meter on adds a panel for it when there is none.
-- Bars: flat class colour, my bar with a gold edge and kept in view (below the fold it takes the last row with its
-- real rank). Hover: top abilities; click: the breakdown (UI/MeterDetail.lua), in Deaths the death recap.
-- Looks: UI/MeterTheme.lua (meters.theme and its overrides) sets the sizes below (ApplyMetrics) and skins the stacks,
-- panels and rows; a row made under another look restyles when it is next drawn (row.styleKey).
-- Built from the shared parts: texts are UI:Text on the type scale, fills / rules / gradients the UI primitives,
-- hovers and the picked look UI:DecorateRow, tooltips UI:AttachTooltip, the close X UI:CreateCloseButton, the fight
-- list's zones UI:CreateSectionHeader, the bar tooltip a card-look UI:CreateHudFrame, colours the ns.Style tokens.
-- The faces (stack, header, bars) are the themes' (UI/MeterTheme.lua through ns.Themes). A meter panel is a HUD
-- panel that docks, not a page: it sits on no page layout (its place is the meters.layout setting).
local addonName, ns = ...

local MP = ns:NewModule("MeterPanels")
local UI = ns.UI
local S = ns.Style

local floor, max, min, abs, exp, sin = math.floor, math.max, math.min, math.abs, math.exp, math.sin
local pairs, ipairs, type, tonumber, tostring, next = pairs, ipairs, type, tonumber, tostring, next
local strformat = string.format
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

-- (sizes: the theme's, set by ApplyMetrics; these are Flat's)
local HEAD_H, ROW_H, ROW_GAP, PAD = 24, 19, 1, 3
local FL_H = 18                   -- a meter panel's fight line, under its header (the user's pick A, 2026-10-11)
local BAR_L, BAR_RES, NAME_L, VAL_R = 20, 0, 25, 6   -- a bar's left edge, the room kept for its ends, text places
local M                           -- the look in use (MeterTheme:Metrics)
local BOSS_C = { 1, 0.71, 0.27 }   -- (a boss fight's name: the meters' amber)
local HOT_C = { 1, 0.35, 0.24 }    -- (threat: the warning stretch and a bar past it)
local MT_ICON = "|TInterface\\GroupFrame\\UI-Group-MainTankIcon:0|t "   -- (threat: before a main tank's name)
local DEFAULT_W, MIN_W, MAX_W = 300, 170, 640
local DEFAULT_ROWS, MAX_ROWS = 8, 40
local NEAR, SIDE_Y = 40, 60      -- docking: how far past an edge a drop still joins; how far apart tops may be beside
local FADED, FADE_AFTER = 0.38, 3
local EASE = 0.09
local ENTER_DUR, ENTER_STAGGER = 0.36, 0.024   -- a view switch: each bar grows in this long, one row after another
local SCALES = { small = 0.9, normal = 1, large = 1.15 }
-- Threat bars: the track is 0 to 100% of the tank's threat, so a bar is as long as its number (the tank's is full);
-- after it a short pull zone runs from 100% to my pull point (110% melee, 130% ranged), ending in the gold line.
-- (Before: one scale to 135%, so the tank's 100% filled three quarters of the track and looked like ~60%; in-game
-- report 2026-10-11.)
local PULL_ZONE_W = 26
local T_NAME_W, T_VALUE_W = 96, 34
local ICON_W = ROW_H + 1          -- a row's icon: square, the row's full height, flush left, then a 1 px divider
local T_TRACK_L = ICON_W + 5 + T_NAME_W + 5
local T_TRACK_R = 6 + T_VALUE_W + 5

-- The sizes of the look in use (UI/MeterTheme.lua).
local function ApplyMetrics()
    M = ns.MeterTheme:Metrics()
    HEAD_H, ROW_H, ROW_GAP, PAD, FL_H = M.head, M.row, M.gap, M.pad, M.fl
    ICON_W, BAR_L, BAR_RES, NAME_L, VAL_R, T_NAME_W = M.iconW, M.barL, M.barRes, M.nameL, M.valR, M.nameW
    T_TRACK_L = NAME_L + T_NAME_W + 5
    T_TRACK_R = VAL_R + T_VALUE_W + 5
    return M
end
local LOW_HEALTH = "Interface\\FullScreenTextures\\LowHealth"

-- The views a panel can show (meter modes, then Threat)
local VIEWS = { "damage", "dps", "healing", "taken", "deaths", "kicks", "dispels", "active", "threat" }
local THREAT_VIEW = { key = "threat", label = "Threat", icon = "Interface\\Icons\\Ability_Warrior_DefensiveStance" }

local Meter, Threat
local K = ns.MeterWindow.K
local holder, guide, outline, flash, driver
local stackFrames = {}            -- [i] = the frame of layout.stacks[i]
local frameOf = {}                -- [layout panel table] = its panel frame
local allPanels = {}              -- every panel frame made
local panelPool = {}
local drag, resize
local userHidden = false
local alpha, combatEndedAt = 1, 0
local dirty, lastDraw = true, 0

local function Setting(path, default)
    local v = ns.DB and ns.DB:GetSetting("meters." .. path)
    if v == nil then return default end
    return v
end
local function Set(path, v) ns.DB:SetSetting("meters." .. path, v) end
-- (unlocked only while Edit layout is open: the meters.locked setting of before 1.4.2 is no longer read)
local function Locked() return not (ns.EditMode and ns.EditMode:IsActive()) end

local function ViewInfo(v)
    if v == "threat" then return THREAT_VIEW end
    return Meter.MODE[v] or Meter.MODE.damage
end
local function IsThreat(v) return v == "threat" end
local function Avail(v)
    if IsThreat(v) then return Threat:IsEnabled() end
    return Meter:IsEnabled()
end

---------------------------------------------------------------------------
-- The layout
---------------------------------------------------------------------------

local function Layout()
    local m = ns.DB:GetSetting("meters.layout")
    if type(m) ~= "table" or type(m.stacks) ~= "table" then
        m = { v = 3, stacks = {} }
        ns.DB:SetSetting("meters.layout", m)
    end
    return m
end
MP.Layout = Layout

-- The tab a panel shows: its active one if its meter is on, else its first one that is.
local function ShownTab(p)
    local a = p.tabs[p.active or 1]
    if a and Avail(a.view) then return p.active or 1 end
    for i, t in ipairs(p.tabs) do if Avail(t.view) then return i end end
    return nil
end
local function AvailTabs(p)
    local out = {}
    for i, t in ipairs(p.tabs) do if Avail(t.view) then out[#out + 1] = i end end
    return out
end

local function HasView(pred)
    for _, s in ipairs(Layout().stacks) do
        for _, p in ipairs(s.panels) do
            for _, t in ipairs(p.tabs) do if pred(t.view) then return true end end
        end
    end
    return false
end

local function NewPanelData(view) return { tabs = { { view = view, seg = "cur" } }, active = 1 } end

-- Turning a meter on gives it a panel when it has none: Threat on top of the first stack, a meter mode under it.
function MP:EnsureViews()
    if not Meter:IsEnabled() and not Threat:IsEnabled() then return end   -- (nothing saved while both are off)
    local L = Layout()
    local function add(view)
        local s = L.stacks[1]
        if not s then
            s = { w = DEFAULT_W, panels = {} }
            L.stacks[1] = s
        end
        if IsThreat(view) then tinsert(s.panels, 1, NewPanelData(view)) else s.panels[#s.panels + 1] = NewPanelData(view) end
    end
    if Meter:IsEnabled() and not HasView(function(v) return not IsThreat(v) end) then add("damage") end
    if Threat:IsEnabled() and not HasView(IsThreat) then add("threat") end
end

function MP:ResetLayout()
    ns.DB:SetSetting("meters.layout", { v = 3, stacks = {} })
    self:EnsureViews()
    self:Rebuild()
end

---------------------------------------------------------------------------
-- Frames: the holder, stacks, panels
---------------------------------------------------------------------------

local function HolderSize()
    local w, h = holder:GetWidth() or 0, holder:GetHeight() or 0
    if w <= 0 then w, h = 1600, 900 end
    return w, h
end

local function NewStack()
    local f = CreateFrame("Frame", nil, holder)
    f:SetSize(DEFAULT_W, HEAD_H)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    ns.MeterTheme:NewStackFace(f)           -- (fill, outer pixel and edge: the theme colours them)
    f.panels = {}
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(12, 12)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(f:GetFrameLevel() + 20)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() MP:StartResize(f) end)
    grip:SetScript("OnMouseUp", function() MP:EndResize() end)
    f.grip = grip
    -- (as wide as the stack, wrapping: centred and one line it ran off the screen's edge)
    f.hint = UI:Text(f, "emph", "GOLD", { wrap = true, shadow = true })
    f.hint:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2, 4)
    f.hint:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -2, 4)
    f.hint:SetText("Drag a header to move or dock · Shift to pull one out · the corner to resize")
    f.hint:Hide()
    f:SetScript("OnMouseUp", function(_, button) if button == "RightButton" and f.panels[1] then MP:PanelMenu(f.panels[1], f) end end)
    return f
end

-- Header pieces ---------------------------------------------------------------------------------------------------

local function HeadDragStart(pf, tabIndex)
    if Locked() or not pf.layout then return end
    local si, pi = pf.si, pf.pi
    local s = Layout().stacks[si]
    if not s then return end
    if tabIndex and #AvailTabs(pf.layout) > 1 then
        MP:Detach(si, pi, tabIndex)
    elseif pf.first and not IsShiftKeyDown() then
        MP:StartDrag(si)
    elseif pf.first and s.g then
        MP:StartDrag(si, true)                -- (Shift on a stack in a row: it alone, out of the row)
    elseif #s.panels > 1 then
        MP:Detach(si, pi)
    else
        MP:StartDrag(si)
    end
end

-- A flat header button (a text and / or a glyph): the shared hover (UI:DecorateRow), held lit while its menu is open.
local function HeadButton(parent, w, h)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w or 22, h or 22)
    UI:DecorateRow(b, { hover = true })
    function b:SetLit(on) self.lit = on; self:SetHover(on) end
    function b:OnMenuShown(on) self:SetLit(on) end
    return b
end

-- A tab in a panel's header: its view's icon and name (the name gives way to the icon alone when they don't fit), a
-- gold underline on the open one. The theme sets the header's height and fonts.
-- TODO(refactor): move into a compact HUD tab (UI:CreateUnderlineTab has no icon, drag-out or theme font).
local function NewTab(pf)
    local b = CreateFrame("Button", nil, pf.head)
    b:SetHeight(HEAD_H)
    b:SetHitRectInsets(-6, -6, 0, 0)          -- (the 12 px between tabs is clickable too: an icon-only tab is 13 px)
    b:RegisterForDrag("LeftButton")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexture(134400)
    b.icon:SetSize(13, 13)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.text = UI:Text(b, "emph", "SUB", { shadow = true })
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
    b.line = UI:Rule(b, { color = "GOLD", size = 2, bottom = 0, layer = "OVERLAY" })
    b:SetScript("OnClick", function(self, button)
        if button == "RightButton" then MP:PanelMenu(pf, self) return end
        pf.layout.active = self.index
        MP:Draw()
    end)
    -- (a tab shrunk to its icon still says what it is)
    UI:AttachTooltip(b, function(self, tt)
        if (self.text:GetText() or "") ~= "" then return false end
        tt:AddLine(self.label or "")
    end, nil, { anchor = "AUTO_Y" })
    -- (a tab dragged out stays alive, invisible, until the drop: a hidden frame never gets its OnDragStop)
    b:SetScript("OnDragStart", function(self)
        self.dragging = true
        HeadDragStart(pf, self.index)
    end)
    b:SetScript("OnDragStop", function(self)
        self.dragging = nil
        self:SetAlpha(1)
        MP:EndDrag()
    end)
    return b
end

-- A texture the themes colour (a white texture: SetVertexColor gives it its colour).
local function Tinted(parent, layer, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetTexture(K.WHITE)
    return t
end

local function NewPanel()
    local pf = CreateFrame("Frame", nil, holder)
    pf:SetHeight(HEAD_H)
    pf.sep = UI:Rule(pf, { color = { 1, 1, 1, 1 }, layer = "OVERLAY" })    -- (the theme tints it: SkinPanel)

    local head = CreateFrame("Button", nil, pf)
    head:SetPoint("TOPLEFT")
    head:SetPoint("TOPRIGHT")
    head:SetHeight(HEAD_H)
    head:RegisterForDrag("LeftButton")
    head:RegisterForClicks("RightButtonUp")
    head.bg = Tinted(head, "BACKGROUND")
    head.bg:SetAllPoints()
    -- (a dock target under the dragged stack: the shared picked wash)
    head.drop = UI:Fill(head, "SELECT", "OVERLAY")
    head.dropText = UI:Text(head, "body", "GOLD", { shadow = true })
    head.dropText:SetPoint("RIGHT", head, "RIGHT", -50, 0)
    head.dropText:SetText("Drop to add as a tab")
    head.drop:Hide()
    head.dropText:Hide()
    head:SetScript("OnDragStart", function() HeadDragStart(pf) end)
    head:SetScript("OnDragStop", function() MP:EndDrag() end)
    head:SetScript("OnClick", function(self, button) if button == "RightButton" then MP:PanelMenu(pf, self) end end)
    pf.head = head

    local mode = HeadButton(head)
    mode:SetPoint("LEFT", head, "LEFT", 3, 0)
    mode:RegisterForDrag("LeftButton")
    mode.icon = mode:CreateTexture(nil, "ARTWORK")
    mode.icon:SetTexture(134400)
    mode.icon:SetSize(14, 14)
    mode.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    mode.icon:SetPoint("LEFT", mode, "LEFT", 4, 0)
    mode.text = UI:Text(mode, "emph", "GOLD", { shadow = true })
    mode.text:SetPoint("LEFT", mode.icon, "RIGHT", 6, 0)
    mode.chev = mode:CreateTexture(nil, "OVERLAY")
    K.Glyph(mode.chev, "chevron")
    mode.chev:SetSize(9, 9)
    mode.chev:SetVertexColor(S:Color("GOLD"))
    mode.chev:SetPoint("LEFT", mode.text, "RIGHT", 5, -1)
    mode:SetScript("OnClick", function(self) MP:ViewMenu(pf, self) end)
    mode:SetScript("OnDragStart", function() HeadDragStart(pf) end)
    mode:SetScript("OnDragStop", function() MP:EndDrag() end)
    pf.mode = mode
    pf.tabs = {}

    local note = HeadButton(head)
    note:RegisterForDrag("LeftButton")
    note.text = UI:Text(note, "body", "SUB", { shadow = true })
    note.text:SetPoint("LEFT", note, "LEFT", 3, 0)
    note:SetScript("OnClick", function(self) if not IsThreat(MP:TabOf(pf).view) then MP:FightMenu(pf, self) end end)
    note:SetScript("OnDragStart", function() HeadDragStart(pf) end)
    note:SetScript("OnDragStop", function() MP:EndDrag() end)
    pf.note = note

    pf.close = UI:CreateCloseButton(head, 20, function() MP:Close(pf) end)
    pf.close:SetPoint("RIGHT", head, "RIGHT", -2, 0)
    UI:AttachTooltip(pf.close, function(_, tt)
        tt:AddLine(#AvailTabs(pf.layout or { tabs = {} }) > 1 and "Close this tab" or "Close this panel")
    end, nil, { anchor = "AUTO_Y" })
    pf.plus = HeadButton(head, 20, 20)
    pf.plus:SetPoint("RIGHT", pf.close, "LEFT", 0, 0)
    pf.plus.icon = pf.plus:CreateTexture(nil, "ARTWORK")
    K.Glyph(pf.plus.icon, "plus")
    pf.plus.icon:SetSize(12, 12)
    pf.plus.icon:SetPoint("CENTER")
    pf.plus.icon:SetVertexColor(S:Color("SUB"))
    pf.plus:SetScript("OnClick", function(self) MP:SpawnMenu(pf, self) end)
    UI:AttachTooltip(pf.plus, "New panel", { "Pick what it shows. Drag its header onto this one to dock it." },
        { anchor = "AUTO_Y" })
    pf.tot = UI:Text(head, "emph", "SUB", { font = K.NARROW, justify = "RIGHT", shadow = true })
    pf.tot:SetPoint("RIGHT", pf.plus, "LEFT", -5, 0)
    pf.totV = UI:Text(head, "title", "TEXT", { font = K.NARROW, justify = "RIGHT", shadow = true })
    pf.totV:SetPoint("RIGHT", pf.tot, "LEFT", -6, 0)

    -- the fight line
    local fl = CreateFrame("Frame", nil, pf)
    fl:SetPoint("TOPLEFT", head, "BOTTOMLEFT")
    fl:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT")
    fl:SetHeight(FL_H)
    fl.bg = Tinted(fl, "BACKGROUND")
    fl.bg:SetAllPoints()
    fl.top = UI:Rule(fl, { color = "HOVER" })
    fl:EnableMouseWheel(true)
    fl:SetScript("OnMouseWheel", function(_, delta) MP:StepFight(pf, delta > 0 and 1 or -1) end)
    local function Arrow(right, dir, tipText)
        local a = UI:CreateArrowButton(fl, right, 22, FL_H, function() MP:StepFight(pf, dir) end)
        UI:AttachTooltip(a, tipText, nil, { anchor = "AUTO_Y" })
        return a
    end
    fl.prev = Arrow(false, -1, "Older fight")
    fl.prev:SetPoint("LEFT")
    fl.next = Arrow(true, 1, "Newer fight")
    fl.next:SetPoint("RIGHT")
    fl.lab = CreateFrame("Button", nil, fl)
    fl.lab:SetPoint("TOPLEFT", fl.prev, "TOPRIGHT")
    fl.lab:SetPoint("BOTTOMRIGHT", fl.next, "BOTTOMLEFT")
    fl.lab:RegisterForDrag("LeftButton")
    fl.lab:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    UI:DecorateRow(fl.lab, { hover = true })
    fl.name = UI:Text(fl.lab, "body", "TEXT", { shadow = true })
    fl.meta = UI:Text(fl.lab, "emph", "SUB", { font = K.NARROW, shadow = true })
    fl.name:SetPoint("LEFT", fl.lab, "LEFT", 0, 0)
    fl.meta:SetPoint("LEFT", fl.name, "RIGHT", 0, 0)
    fl.lab:SetScript("OnClick", function(self, button)
        if button == "RightButton" then MP:PanelMenu(pf, self) else MP:FightMenu(pf, self) end
    end)
    fl.lab:SetScript("OnDragStart", function() HeadDragStart(pf) end)
    fl.lab:SetScript("OnDragStop", function() MP:EndDrag() end)
    fl:Hide()
    pf.fl = fl

    local rows = CreateFrame("Frame", nil, pf)
    rows:SetPoint("TOPLEFT", head, "BOTTOMLEFT", PAD, -PAD)
    rows:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", -PAD, -PAD)
    rows:SetHeight(1)
    if rows.SetClipsChildren then rows:SetClipsChildren(true) end
    pf.rows = rows
    -- threat lines over the rows
    local over = CreateFrame("Frame", nil, rows)
    over:SetAllPoints()
    over:SetFrameLevel(rows:GetFrameLevel() + 5)
    pf.zone = over:CreateTexture(nil, "BACKGROUND")
    UI:Gradient(pf.zone, "HORIZONTAL", { HOT_C[1], HOT_C[2], HOT_C[3], 0 }, { HOT_C[1], HOT_C[2], HOT_C[3], 0.16 })
    pf.tankLine = UI:Fill(over, { 1, 1, 1, 0.28 }, "ARTWORK")
    pf.tankLine:ClearAllPoints()
    pf.tankLine:SetWidth(1)
    pf.pull = UI:Fill(over, "GOLD", "OVERLAY")
    pf.pull:ClearAllPoints()
    pf.pull:SetWidth(2)
    pf.rowsByKey, pf.rowPool, pf.trowsByKey, pf.trowPool = {}, {}, {}, {}
    -- the mouse wheel scrolls past the panel's last row (rows don't take the wheel, so it reaches the panel)
    pf.thumb = UI:Fill(over, { 1, 1, 1, 0.3 }, "OVERLAY")
    pf.thumb:ClearAllPoints()
    pf.thumb:SetWidth(2)
    pf.thumb:Hide()
    pf:EnableMouseWheel(true)
    pf:SetScript("OnMouseWheel", function(self, delta)
        if (self.maxOff or 0) <= 0 then return end
        self.offset = min(self.maxOff, max(0, (self.offset or 0) - delta))
        MP:Draw()
    end)
    allPanels[#allPanels + 1] = pf
    return pf
end

-- A panel's width: its frame's, else (before the first layout) its stack's.
local function PanelWidth(pf)
    local w = pf:GetWidth() or 0
    if w <= 0 then
        local s = Layout().stacks[pf.si or 0]
        w = s and s.w or DEFAULT_W
    end
    return w
end

function MP:TabOf(pf)
    local p = pf.layout
    local i = p and ShownTab(p)
    return i and p.tabs[i] or { view = "damage", seg = "cur" }, i
end

-- A panel's fight, for all its tabs (the user switches tabs to compare views of one fight).
function MP:SetFight(pf, sel)
    local p = pf.layout
    if not p then return end
    for _, t in ipairs(p.tabs) do if not IsThreat(t.view) then t.seg = sel end end
    self:Draw()
end

-- Fights in order, oldest first, then the whole raid; where the panel's fight is among them.
local function FightOrder(sel)
    local fights, all = Meter:GetFights()                -- (newest first)
    local order = {}
    for i = #fights, 1, -1 do order[#order + 1] = (i == 1) and "cur" or fights[i].id end
    if all then order[#order + 1] = "all" end
    local at
    for i, k in ipairs(order) do if k == (sel or "cur") then at = i break end end
    return order, at or (#fights > 0 and #fights or nil), #fights
end

-- The arrows and the wheel: an older (-1) or newer (+1) fight; past the newest is the whole raid.
function MP:StepFight(pf, dir)
    local tab = self:TabOf(pf)
    if IsThreat(tab.view) then return end
    local order, at = FightOrder(tab.seg)
    if not at then return end
    local to = order[min(#order, max(1, at + dir))]
    if to and to ~= (tab.seg or "cur") then self:SetFight(pf, to) end
end

---------------------------------------------------------------------------
-- Rebuild: frames for the layout (after any change to it)
---------------------------------------------------------------------------

-- Does a stack show anything (a panel whose meter is on)?
local function Visible(s)
    for _, p in ipairs(s.panels) do if ShownTab(p) then return true end end
    return false
end
local function Width(s) return min(MAX_W, max(MIN_W, tonumber(s.w) or DEFAULT_W)) end

-- Rows (stacks docked side by side, same s.g): left to right by x, each one's left edge on the one before's right
-- edge (their borders overlap into one line), all held by the leftmost one's edge. A row of one is no row.
local function PackRows(L)
    local rows = {}
    for _, s in ipairs(L.stacks) do
        if s.g then
            local r = rows[s.g] or {}
            rows[s.g] = r
            r[#r + 1] = s
        end
    end
    for _, r in pairs(rows) do
        local shown = {}
        for _, s in ipairs(r) do if Visible(s) then shown[#shown + 1] = s end end
        if #r < 2 then
            r[1].g = nil
        elseif #shown >= 2 then
            tsort(shown, function(a, c) return (a.x or 0) < (c.x or 0) end)
            local a = shown[1]
            for i = 2, #shown do
                local s, prev = shown[i], shown[i - 1]
                s.x = (prev.x or 0) + Width(prev) - 1
                if a.b then s.b, s.y = a.b, nil else s.y, s.b = a.y, nil end
            end
        end
    end
end

local function Moving(f) return drag and drag.moving and drag.moving[f] end

local function Anchor(f, s)
    if Moving(f) then return end
    f:ClearAllPoints()
    if s.b then f:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", s.x, s.b)
    else f:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", s.x, s.y) end
end

local function ReleasePanel(pf)
    if pf.layout then frameOf[pf.layout] = nil end
    pf.layout = nil
    pf:Hide()
    for key, row in pairs(pf.rowsByKey) do row:Hide(); pf.rowsByKey[key] = nil; pf.rowPool[#pf.rowPool + 1] = row end
    for key, row in pairs(pf.trowsByKey) do row:Hide(); pf.trowsByKey[key] = nil; pf.trowPool[#pf.trowPool + 1] = row end
    panelPool[#panelPool + 1] = pf
end

function MP:Rebuild()
    if not holder then return end
    local L = Layout()
    -- (layouts from before the resize fix: a panel left at 1 row by a touch of the corner gets its default back)
    if (L.v or 1) == 2 then
        for _, s in ipairs(L.stacks) do
            for _, p in ipairs(s.panels) do if p.rows == 1 then p.rows = nil end end
        end
        L.v = 3
    end
    local used = {}
    local hw, hh = HolderSize()
    for si, s in ipairs(L.stacks) do
        s.w = Width(s)
        if not s.x or (not s.y and not s.b) then
            s.x = hw - s.w - 60 - (si - 1) * (s.w + 12)
            s.b, s.y = 220, nil
        end
    end
    PackRows(L)
    for si, s in ipairs(L.stacks) do
        local f = stackFrames[si]
        if not f then f = NewStack(); stackFrames[si] = f end
        f.si, f.layout = si, s
        Anchor(f, s)
        f.up = s.b ~= nil
        f.grip:ClearAllPoints()
        if f.up then
            f.grip:SetPoint("TOPRIGHT", -1, -1)
            f.grip:GetNormalTexture():SetTexCoord(0, 1, 1, 0)
            f.grip:GetHighlightTexture():SetTexCoord(0, 1, 1, 0)
            f.grip:GetPushedTexture():SetTexCoord(0, 1, 1, 0)
        else
            f.grip:SetPoint("BOTTOMRIGHT", -1, 1)
            f.grip:GetNormalTexture():SetTexCoord(0, 1, 0, 1)
            f.grip:GetHighlightTexture():SetTexCoord(0, 1, 0, 1)
            f.grip:GetPushedTexture():SetTexCoord(0, 1, 0, 1)
        end
        f:SetWidth(s.w)
        f.panels = {}
        for pi, p in ipairs(s.panels) do
            if ShownTab(p) then
                local pf = frameOf[p]
                if not pf then
                    pf = tremove(panelPool) or NewPanel()
                    frameOf[p] = pf
                end
                pf:SetParent(f)
                pf.layout, pf.si, pf.pi = p, si, pi
                pf.first = #f.panels == 0
                f.panels[#f.panels + 1] = pf
                used[pf] = true
                pf:Show()
            end
        end
        f:SetShown(#f.panels > 0)
    end
    for i = #L.stacks + 1, #stackFrames do
        stackFrames[i].panels = {}
        stackFrames[i].layout = nil
        if not Moving(stackFrames[i]) then stackFrames[i]:Hide() end
    end
    for _, pf in ipairs(allPanels) do
        if not used[pf] and pf.layout ~= nil then ReleasePanel(pf)
        elseif not used[pf] then pf:Hide() end
    end
    self:ApplyLook()
    self:Draw()
end

function MP:ApplyLook()
    if not holder then return end
    holder:SetScale(SCALES[Setting("size", "normal")] or 1)
    local locked = Locked()
    ApplyMetrics()
    for _, f in ipairs(stackFrames) do
        f.grip:SetShown(not locked)
        ns.MeterTheme:SkinStack(f, M, locked)
    end
    for _, pf in ipairs(allPanels) do
        if pf.styleKey ~= M.key then
            ns.MeterTheme:SkinPanel(pf, M)
            pf.flShown = nil                  -- (the rows' place under the header / fight line: set again on the draw)
            pf.peak = nil
        end
    end
end

-- Another look (a theme picked or pointed at in Settings, an override): skin everything again and redraw.
function MP:Restyle()
    if not holder then return end
    self:ApplyLook()
    self:Draw()
end

---------------------------------------------------------------------------
-- Meter rows
---------------------------------------------------------------------------

local function RowSeg(pf)
    local tab = MP:TabOf(pf)
    return Meter:GetSegment(tab.seg or "cur"), tab.view, tab
end

-- The bar's tooltip (the mockup's): the player's spec in an icon tile with the name and spec, up to three big numbers
-- with small captions, a hairline, the top abilities (icon, name, amount, share), a red line when they died, and a
-- green hint. A card-look HUD frame: GameTooltip cannot lay out columns.
local TIP_W, TIP_PAD, TIP_LINE = 272, 11, 21
local TIP_HEAD = 30
local tip

local function Tip()
    if tip then return tip end
    -- (the pop-ups' card: UI:CreateHudFrame's "card" look; it follows the bar, nothing to drag or save)
    tip = UI:CreateHudFrame("DisasterZoneMeterTip", { width = TIP_W, height = 120, look = "card", movable = false,
        position = false, strata = "TOOLTIP" })
    tip:EnableMouse(false)
    -- header: the class in the shared icon tile, the name, the spec
    tip.ring = UI:CreateIconTile(tip, 30)
    tip.ring:SetPoint("TOPLEFT", tip, "TOPLEFT", TIP_PAD, -TIP_PAD)
    tip.cls = tip.ring.tex
    tip.name = UI:Text(tip, "page", { 1, 1, 1 }, { shadow = true })
    tip.name:SetPoint("TOPLEFT", tip.ring, "TOPRIGHT", 9, 1)
    tip.spec = UI:Text(tip, "body", "SUB", { shadow = true })
    tip.spec:SetPoint("TOPLEFT", tip.name, "BOTTOMLEFT", 0, -3)
    -- the big numbers
    tip.stats = {}
    for i = 1, 3 do
        local s = {}
        s.num = UI:Text(tip, "page", { 1, 1, 1 }, { font = K.NARROW, shadow = true })
        s.lab = UI:Text(tip, "small", "SUB", { shadow = true })
        s.lab:SetPoint("TOPLEFT", s.num, "BOTTOMLEFT", 0, -2)
        tip.stats[i] = s
    end
    tip.rule = UI:Rule(tip, { left = TIP_PAD, right = TIP_PAD })
    tip.lines = {}
    tip.foot = UI:Text(tip, "body", "OK", { shadow = true })
    tip:Hide()
    return tip
end

local function TipLine(i)
    local l = tip.lines[i]
    if l then return l end
    l = {}
    l.tile = UI:CreateIconTile(tip, 16)
    l.icon = l.tile.tex
    l.name = UI:Text(tip, "emph", { 1, 1, 1 }, { shadow = true })
    l.amount = UI:Text(tip, "title", { 1, 1, 1 }, { font = K.NARROW, justify = "RIGHT", shadow = true })
    l.pct = UI:Text(tip, "emph", "SUB", { font = K.NARROW, justify = "RIGHT", shadow = true })
    l.pct:SetWidth(38)
    tip.lines[i] = l
    return l
end

local function ShowRowTip(row)
    local r, pf = row.data, row.pf
    if not r then return end
    Tip()
    local seg, mode = RowSeg(pf)
    local a = r.a
    local dur = Meter:Duration(seg)
    local act = Meter:RateTime(seg, a)

    -- header
    K.SetPlayerIcon(tip.cls, a.c, a.s)
    tip.name:SetText(a.n or "?")
    tip.name:SetTextColor(K.ClassColor(a.c))
    tip.spec:SetText(K.SpecText(a))

    -- what each mode shows: the big numbers and the lines { key, name, amount text, share, colour }
    local stats, lines, red, hint = {}, {}, nil, "Click for the full breakdown"
    local function top(list, total)
        local arr = {}
        for k, s in pairs(list or {}) do arr[#arr + 1] = { k, type(s) == "table" and s.a or s } end
        tsort(arr, function(x, y) return x[2] > y[2] end)
        for i = 1, min(5, #arr) do
            local k, v = arr[i][1], arr[i][2]
            lines[#lines + 1] = { k, K.SpellName(k, a.pn), K.Fmt(v), total > 0 and floor(v / total * 100 + 0.5) .. "%" or "" }
        end
    end
    if mode == "deaths" and r.d then
        local d = r.d
        stats = { { K.Clock(d.t), "died at" }, { d.hpMax and d.hpMax > 0 and K.Int(d.hpMax) or "?", "health" } }
        red = { d.by, "Killed by " .. (d.by and K.SpellName(d.by) or "?") .. (d.src and (" · " .. d.src) or "") }
        for i = #(d.ev or {}), max(1, #(d.ev or {}) - 3), -1 do
            local e = d.ev[i]
            lines[#lines + 1] = { e[3], K.SpellName(e[3]), (e[2] == "d" and S:Hex("BAD") .. "-" or S:Hex("OK") .. "+") .. K.Int(e[4]) .. "|r",
                                  strformat("%.1f s", e[1]) }
        end
        hint = "Click for the death recap"
    elseif mode == "healing" then
        stats = { { K.Fmt(a.h), "healing" }, { K.Int(a.h / act), "per second" },
                  { strformat("%d%%", (a.h + a.oh) > 0 and floor(a.oh / (a.h + a.oh) * 100 + 0.5) or 0), "overhealing" } }
        top(a.hs, a.h)
    elseif mode == "taken" then
        stats = { { K.Fmt(a.t), "taken" }, { K.Int(a.t / dur), "per second" } }
        top(a.ts, a.t)
    elseif mode == "kicks" or mode == "dispels" then
        local by, cut = mode == "kicks" and a.ks or a.ds, mode == "kicks" and a.kx or a.dx
        local n = mode == "kicks" and a.k or a.dp
        stats = { { tostring(n or 0), mode == "kicks" and "interrupts" or "dispels" } }
        for k, c in pairs(by or {}) do lines[#lines + 1] = { k, K.SpellName(k), tostring(c), "" } end
        for k, c in pairs(cut or {}) do
            lines[#lines + 1] = { k, (mode == "kicks" and "Cut: " or "Removed: ") .. K.SpellName(k), tostring(c), "" }
        end
        hint = nil
    else
        stats = { { K.Fmt(a.d), "damage" }, { K.Int(a.d / act), "per second" },
                  { strformat("%d%%", floor(min(dur, a.act or 0) / dur * 100 + 0.5)), "active" } }
        top(a.sp, a.d)
    end
    if mode ~= "deaths" and Meter:IsDead(seg, r.g) then
        for _, d in ipairs(seg.deaths) do
            if d.g == r.g then red = { d.by, strformat("Died at %s · %s", K.Clock(d.t), d.by and K.SpellName(d.by) or "?") } break end
        end
        hint = "Click for the full breakdown"
    end

    -- lay it out
    local y = -TIP_PAD - TIP_HEAD - 10
    local x = TIP_PAD
    for i, s in ipairs(tip.stats) do
        local st = stats[i]
        s.num:SetShown(st ~= nil)
        s.lab:SetShown(st ~= nil)
        if st then
            s.num:SetText(st[1])
            s.lab:SetText(st[2])
            s.num:ClearAllPoints()
            s.num:SetPoint("TOPLEFT", tip, "TOPLEFT", x, y)
            x = x + max(s.num:GetStringWidth(), s.lab:GetStringWidth()) + 16
        end
    end
    y = y - (#stats > 0 and 40 or 0)
    tip.rule:ClearAllPoints()
    tip.rule:SetPoint("TOPLEFT", tip, "TOPLEFT", TIP_PAD, y + 4)
    tip.rule:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -TIP_PAD, y + 4)
    tip.rule:SetShown(#lines > 0 or red ~= nil)
    for _, l in pairs(tip.lines) do l.tile:Hide(); l.name:Hide(); l.amount:Hide(); l.pct:Hide() end
    local function place(i, key, name, amount, pct, color)
        local l = TipLine(i)
        l.icon:SetTexture(K.SpellIcon(key, a))
        l.tile:ClearAllPoints()
        l.tile:SetPoint("TOPLEFT", tip, "TOPLEFT", TIP_PAD, y - 2)
        l.pct:SetText(pct or "")
        l.pct:ClearAllPoints()
        l.pct:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -TIP_PAD, y - 3)
        l.amount:SetText(amount or "")
        l.amount:ClearAllPoints()
        l.amount:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -TIP_PAD - ((pct or "") ~= "" and 42 or 0), y - 3)
        l.name:SetText(name)
        l.name:ClearAllPoints()
        l.name:SetPoint("TOPLEFT", l.tile, "TOPRIGHT", 7, -1)
        l.name:SetPoint("RIGHT", l.amount, "LEFT", -8, 0)
        if color then l.name:SetTextColor(color[1], color[2], color[3]) else l.name:SetTextColor(1, 1, 1) end
        l.tile:Show(); l.name:Show(); l.amount:Show(); l.pct:Show()
        y = y - TIP_LINE
    end
    for i, ln in ipairs(lines) do place(i, ln[1], ln[2], ln[3], ln[4]) end
    if red then place(#lines + 1, red[1], red[2], "", "", S.C.BAD) end
    tip.foot:SetShown(hint ~= nil)
    if hint then
        tip.foot:SetText(hint)
        tip.foot:ClearAllPoints()
        tip.foot:SetPoint("TOPLEFT", tip, "TOPLEFT", TIP_PAD, y - 5)
        y = y - 5 - 16
    end
    tip:SetHeight(-y + TIP_PAD - 4)

    -- beside the bar, on the side with room
    tip:ClearAllPoints()
    local left = (row:GetLeft() or 0) * (row:GetEffectiveScale() or 1)
    if left > (UIParent:GetWidth() or 1000) * (UIParent:GetEffectiveScale() or 1) / 2 then
        tip:SetPoint("TOPRIGHT", row, "TOPLEFT", -10, 4)
    else
        tip:SetPoint("TOPLEFT", row, "TOPRIGHT", 10, 4)
    end
    tip:Show()
end
MP.ShowRowTip = ShowRowTip
local function HideRowTip() if tip then tip:Hide() end end
MP._Tip = function() return tip end

local function RowClick(row, button)
    if button == "RightButton" then MP:PanelMenu(row.pf, row) return end
    local r = row.data
    if not r or not ns.MeterDetail then return end
    HideRowTip()
    local _, mode, tab = RowSeg(row.pf)
    if mode == "deaths" and r.d then ns.MeterDetail:OpenDeath(tab.seg or "cur", r.d)
    else ns.MeterDetail:Open(tab.seg or "cur", r.g, mode) end
end

-- A soft dark halo under a bar's text, under the usual 1 px shadow: white on a pale bar (priests, rogues) was hard
-- to read (asked 2026-10-11). Four faint black copies of the text, 1 px left / right / up / down, in the SAME font:
-- an OUTLINE copy (the first try) is wider than the plain text and drifted off it. SetT sets them all (the copies
-- without colour codes, or they would tint them).
local HALO = { { -1, 0 }, { 1, 0 }, { 0, 1 }, { 0, -1 } }
local function Halo(fs, parent)
    local font, size, flags = fs:GetFont()
    fs.halo = {}
    for i, o in ipairs(HALO) do
        local h = parent:CreateFontString(nil, "ARTWORK", nil, 7)
        h:SetFont(font or K.FRIZ, size or 12, flags or "")
        h:SetTextColor(0, 0, 0, 0.36)
        h:SetShadowOffset(0, 0)
        h:SetJustifyH(fs:GetJustifyH() or "LEFT")
        h:SetWordWrap(false)
        h:SetPoint("TOPLEFT", fs, "TOPLEFT", o[1], o[2])
        h:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", o[1], o[2])
        fs.halo[i] = h
    end
end
local function SetT(fs, t)
    fs:SetText(t)
    if fs.halo then
        local plain = t and (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) or ""
        for _, h in ipairs(fs.halo) do h:SetText(plain) end
    end
end

-- A row's icon (set by MeterTheme:SetIcon: spec, else the class's square icon, or the theme's round / framed one).
local function RowIcon(row)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetTexture(134400)
    row.icon:SetSize(ROW_H, ROW_H)
    row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.iconLine = UI:Rule(row, { vertical = true, color = { 0, 0, 0, 0.85 }, sublevel = 1 })
    row.iconLine:ClearAllPoints()
    row.iconLine:SetPoint("TOPLEFT", row.icon, "TOPRIGHT")
    row.iconLine:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT")
end

local function NewRow(pf)
    local row = CreateFrame("Button", nil, pf.rows)
    row:SetHeight(ROW_H)
    row.pf = pf
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.bg = Tinted(row, "BACKGROUND")
    row.bg:SetAllPoints()
    row.fill = Tinted(row, "BORDER")
    row.fill:SetPoint("TOPLEFT", ICON_W, 0)
    row.fill:SetPoint("BOTTOMLEFT", ICON_W, 0)
    row.foot = UI:Fill(row, { 0, 0, 0, 0.35 }, "BORDER", 1)
    row.foot:ClearAllPoints()
    row.foot:SetPoint("BOTTOMLEFT", row.fill, "BOTTOMLEFT")
    row.foot:SetPoint("BOTTOMRIGHT", row.fill, "BOTTOMRIGHT")
    row.foot:SetHeight(1)
    row.ext = Tinted(row, "BORDER")
    row.ext:SetPoint("TOPLEFT", row.fill, "TOPRIGHT")
    row.ext:SetPoint("BOTTOMLEFT", row.fill, "BOTTOMRIGHT")
    row.you = UI:Rule(row, { vertical = true, color = "SELECT_BAR", size = 2, layer = "OVERLAY" })   -- (mine: the picked bar)
    row.pinLine = UI:Rule(row, { color = "GOLD", alpha = 0.5 })
    row.pinLine:ClearAllPoints()
    row.pinLine:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 0)
    row.pinLine:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", 0, 0)
    UI:DecorateRow(row, { hover = true })
    row.hover = row.dzHover
    row.rank = UI:Text(row, "body", { 1, 1, 1, 0.7 }, { font = K.NARROW, justify = "RIGHT", shadow = true })
    row.rank:SetPoint("LEFT", row, "LEFT", 2, 0)
    row.rank:SetWidth(13)
    row.rank:Hide()                   -- (no list numbers: the bars' order says it; my pinned bar names its place)
    RowIcon(row)
    row.value = UI:Text(row, "title", { 1, 1, 1 }, { font = K.NARROW, justify = "RIGHT", shadow = true })
    row.sub = UI:Text(row, "emph", { 1, 1, 1, 0.72 }, { font = K.NARROW, justify = "RIGHT", shadow = true })
    row.kb = row:CreateTexture(nil, "ARTWORK")
    row.kb:SetTexture(134400)
    row.kb:SetSize(14, 14)
    row.kb:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.skull = row:CreateTexture(nil, "ARTWORK")
    row.skull:SetTexture(K.SKULL)
    row.skull:SetSize(11, 11)
    row.name = UI:Text(row, "emph", { 1, 1, 1 }, { shadow = true })
    Halo(row.name, row)
    Halo(row.value, row)
    Halo(row.sub, row)
    row:SetScript("OnEnter", ShowRowTip)
    row:SetScript("OnLeave", HideRowTip)
    row:SetScript("OnClick", RowClick)
    ns.MeterTheme:SkinRow(row, M or ApplyMetrics())
    return row
end

local function PlaceRight(row, hasSub, hasKb)
    row.value:ClearAllPoints()
    row.sub:ClearAllPoints()
    row.sub:SetPoint("RIGHT", row, "RIGHT", -VAL_R, 0)
    if hasSub then
        row.sub:Show()
        row.sub:SetWidth(max(M.t.small and 30 or 40, row.sub:GetStringWidth() + 2))
        row.value:SetPoint("RIGHT", row.sub, "LEFT", -6, 0)
    else
        row.sub:Hide()
        row.value:SetPoint("RIGHT", row, "RIGHT", -VAL_R, 0)
    end
    row.kb:ClearAllPoints()
    if hasKb then
        row.kb:Show()
        row.kb:SetPoint("RIGHT", row.value, "LEFT", -5, 0)
    else
        row.kb:Hide()
    end
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row, "LEFT", NAME_L, 0)
    row.name:SetPoint("RIGHT", hasKb and row.kb or row.value, "LEFT", -16, 0)
end

-- (per second: Meter:RateTime, the fight's length or the player's active time; taken by the fight's length)
local function Num(v) return ns.MeterTheme:Num(v) end   -- (amounts in the chosen format: 380.1k, 380,112 or 380k)
local RATE_SUB = { damage = true, healing = true, taken = true }   -- (the per-second column a dense look drops)
local VALUE = {
    damage = function(r, dur, seg) return Num(r.v), K.Int(r.v / Meter:RateTime(seg, r.a)) end,
    dps = function(r) return K.Int(r.v), Num(r.a.d) end,
    healing = function(r, dur, seg) return Num(r.v), K.Int(r.v / Meter:RateTime(seg, r.a)) end,
    taken = function(r, dur) return Num(r.v), K.Int(r.v / dur) end,
    deaths = function(r) return K.Clock(r.v), nil end,
    kicks = function(r) return tostring(r.v), nil end,
    dispels = function(r) return tostring(r.v), nil end,
    active = function(r, dur) return K.Pct(min(100, r.v / dur * 100)), K.Clock(r.v) end,
}

local function TopKey(map)
    local best, bv = nil, -1
    for k, v in pairs(map or {}) do if v > bv then best, bv = k, v end end
    return best
end

-- The header's total: value, dim part. Per second = the players' own per-second values added up (each by their
-- active time, as on their rows), so a solo fight shows the same number in the header and on the bar.
local function TotalText(mode, rows, total, dur, seg)
    local function perSecond(field)
        local s = 0
        for _, r in ipairs(rows) do s = s + (r.a[field] or 0) / Meter:RateTime(seg, r.a) end
        return s
    end
    if mode == "damage" then return Num(total), K.Int(perSecond("d")) .. "/s" end
    if mode == "dps" then
        local s = 0
        for _, r in ipairs(rows) do s = s + r.v end
        return K.Int(s), "raid"
    end
    if mode == "healing" then
        local oh = 0
        for _, r in ipairs(rows) do oh = oh + (r.ext or 0) end
        return Num(total), (total + oh) > 0 and strformat("%d%% over", floor(oh / (total + oh) * 100 + 0.5)) or ""
    end
    if mode == "taken" then return Num(total), K.Int(total / dur) .. "/s" end
    if mode == "deaths" then return tostring(total), total == 1 and "death" or "deaths" end
    if mode == "kicks" then return tostring(total), "" end
    if mode == "dispels" then return tostring(total), "" end
    return K.Pct(min(100, total / dur * 100)), "average"
end

local EMPTY_NOTE = { deaths = "nobody died", kicks = "no interrupts", dispels = "no dispels" }

-- A view switch (another tab, view or fight): every row starts in its place, empty and clear, and its bar grows in
-- (ease-out) while it fades in, row after row from the top. (Before, the players in both views slid from their old
-- places and the rest flew in from below: a shuffle, not a change of view.)
local function Enter(row, i)
    row.y, row.w, row.ew = row.ty, 0, 0
    row.anim = { t = 0, delay = (i - 1) * ENTER_STAGGER }
    row:SetAlpha(0)
end

-- The rows a panel shows: V of them from its scroll offset (the mouse wheel moves it); my own row, when it is out of
-- that window, takes the last slot (pinned, with its real place).
local function Window(pf, list, V, isMe)
    local maxOff = max(0, #list - V)
    local off = min(maxOff, max(0, floor(pf.offset or 0)))
    pf.offset, pf.maxOff = off, maxOff
    local out = {}
    for i = off + 1, min(#list, off + V) do out[#out + 1] = list[i] end
    local meIdx
    for i, r in ipairs(list) do if isMe(r) then meIdx = i break end end
    if meIdx and (meIdx <= off or meIdx > off + V) and V >= 2 then
        out[#out] = list[meIdx]
        out.pinned = list[meIdx]
    end
    pf.jump = pf.lastOff ~= nil and pf.lastOff ~= off      -- (scrolled: rows take their places at once)
    pf.lastOff = off
    return out
end

-- The scroll thumb on the panel's right edge while it has more rows than it shows.
local function Thumb(pf, total, V)
    local t = pf.thumb
    if not t or (pf.maxOff or 0) <= 0 or total <= V then
        if t then t:Hide() end
        return
    end
    local h = V * (ROW_H + ROW_GAP) - ROW_GAP
    t:ClearAllPoints()
    t:SetPoint("TOPRIGHT", pf.rows, "TOPRIGHT", 0, -floor(h * (pf.offset or 0) / total + 0.5))
    t:SetHeight(max(6, h * V / total))
    t:Show()
end

local function DrawMeter(pf, tab)
    local mode = tab.view
    local seg = Meter:GetSegment(tab.seg or "cur")
    if not seg and tab.seg ~= "cur" then tab.seg = "cur"; seg = Meter:GetSegment("cur") end
    local dur = Meter:Duration(seg)
    local rows, total = Meter:Rows(seg, mode)
    local p = pf.layout
    local V = min(#rows, p.rows or DEFAULT_ROWS)

    -- the note: an older fight, or why the panel is empty
    local note = ""
    if not seg then note = "no fights yet"
    elseif #rows == 0 then note = EMPTY_NOTE[mode] or "nothing yet" end      -- (the fight: the fight line)
    pf.noteText = note
    if seg and #rows > 0 then
        local v, s = TotalText(mode, rows, total, dur, seg)
        pf.totV:SetText(v)
        pf.tot:SetText(s or "")
    else
        pf.totV:SetText("")
        pf.tot:SetText("")
    end

    for i, r in ipairs(rows) do
        r.rank = i
        r.me = ns.MeterWindow.IsMe(r.d and r.d.g or r.g)
    end
    local order = Window(pf, rows, V, function(r) return r.me end)
    for _, r in ipairs(rows) do r.pinned = (r == order.pinned) or nil end
    Thumb(pf, #rows, V)
    local topV = 0
    for _, r in ipairs(rows) do topV = max(topV, r.v + (r.ext or 0)) end
    if mode == "active" then topV = dur end
    if topV <= 0 then topV = 1 end
    local rowW = (pf.rows:GetWidth() or 0)
    if rowW <= 0 then rowW = PanelWidth(pf) - PAD * 2 end
    rowW = max(10, rowW - BAR_L - BAR_RES)           -- (the bar starts right of the icon; a look's bar ends take room)
    local valueFn = VALUE[mode] or VALUE.damage
    local seen = {}
    for i = 1, #order do
        local r = order[i]
        local key = r.d and ("d" .. tostring(r.d.t) .. tostring(r.d.g)) or r.g
        seen[key] = true
        local row = pf.rowsByKey[key]
        local fresh = false
        if not row then
            row = tremove(pf.rowPool) or NewRow(pf)
            pf.rowsByKey[key] = row
            row.y = nil
            fresh = true
        end
        if row.styleKey ~= M.key then ns.MeterTheme:SkinRow(row, M) end
        row.data = r
        local a = r.a
        row.cls = a.c
        local cr, cg, cb = ns.MeterTheme:BarColor(a.c, a.s)
        ns.MeterTheme:Paint(row, M, cr, cg, cb, r.me)
        ns.MeterTheme:SetIcon(row, a.c, a.s, M)
        if M.t.rank then row.rank:SetText(r.rank) end
        -- my bar pinned below the fold says where I really am ("10th"), the others need no number
        SetT(row.name, (r.pinned and not M.t.rank) and strformat("%s  %s", a.n or "?", S:Wrap("SUB", K.Ordinal(r.rank))) or (a.n or "?"))
        local v1, v2 = valueFn(r, dur, seg)
        if not M.t.rate and RATE_SUB[mode] then v2 = nil end
        SetT(row.value, v1)
        SetT(row.sub, v2 or "")
        local kbKey = r.d and r.d.by or (mode == "kicks" and TopKey(a.ks)) or (mode == "dispels" and TopKey(a.ds)) or nil
        if kbKey then row.kb:SetTexture(K.SpellIcon(kbKey, a)) end
        PlaceRight(row, v2 ~= nil, kbKey ~= nil)
        local dead = r.d == nil and Meter:IsDead(seg, r.g)
        row.name:SetAlpha(dead and 0.7 or 1)
        row.skull:SetShown(dead and true or false)
        if dead then
            row.skull:ClearAllPoints()
            row.skull:SetPoint("LEFT", row.name, "LEFT", min(row.name:GetStringWidth() + 4, max(10, (row.name:GetWidth() or 100) + 2)), 0)
        end
        row.pinLine:SetShown(r.pinned and true or false)
        row.ty = -((i - 1) * (ROW_H + ROW_GAP))
        row.tw = max(1, (mode == "deaths") and rowW or (r.v / topV * rowW))
        row.tew = (r.ext and r.ext > 0) and (r.ext / topV * rowW) or 0
        if fresh then row.anim = nil; row:SetAlpha(1) end
        if pf.switched then
            Enter(row, i)
        elseif fresh or not row.y or pf.jump then
            if pf.drawn and mode ~= "deaths" and not pf.jump then
                row.y, row.w, row.ew = -(V * (ROW_H + ROW_GAP)), 0, 0   -- a new player comes in from below
            else
                row.y, row.w, row.ew = row.ty, row.tw, row.tew
            end
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", 0, row.y)
        row:SetPoint("RIGHT", pf.rows, "RIGHT", 0, 0)
        row.fill:SetWidth(max(1, row.w))
        row.ext:SetWidth(max(0.01, row.ew))
        row.ext:SetShown(row.ew > 0.5)
        row:Show()
    end
    for key, row in pairs(pf.rowsByKey) do
        if not seen[key] then
            row:Hide()
            row.data = nil
            pf.rowsByKey[key] = nil
            pf.rowPool[#pf.rowPool + 1] = row
        end
    end
    for key, row in pairs(pf.trowsByKey) do row:Hide(); pf.trowsByKey[key] = nil; pf.trowPool[#pf.trowPool + 1] = row end
    pf.drawn = true
    pf.zone:Hide(); pf.tankLine:Hide(); pf.pull:Hide()
    pf.hot = false
    return V
end

---------------------------------------------------------------------------
-- Threat rows
---------------------------------------------------------------------------

-- A threat row in the look in use: the theme's parts, then the name's place (its column ends where the track starts).
local function StyleThreatRow(row)
    ns.MeterTheme:SkinRow(row, M, true)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row, "LEFT", NAME_L, 0)
    row.name:SetWidth(T_NAME_W)
    row.value:ClearAllPoints()
    row.value:SetPoint("RIGHT", row, "RIGHT", -VAL_R, 0)
end

local function NewThreatRow(pf)
    local row = CreateFrame("Frame", nil, pf.rows)
    row:SetHeight(ROW_H)
    RowIcon(row)
    row.name = UI:Text(row, "emph", { 1, 1, 1 }, { width = T_NAME_W, shadow = true })
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.value = UI:Text(row, "title", { 1, 1, 1 }, { font = K.NARROW, justify = "RIGHT", width = T_VALUE_W, shadow = true })
    row.value:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    Halo(row.name, row)
    Halo(row.value, row)
    row.you = UI:Rule(row, { vertical = true, color = "SELECT_BAR", size = 2, layer = "OVERLAY" })
    row.track = Tinted(row, "BACKGROUND")
    row.track:SetPoint("TOPLEFT", row, "TOPLEFT", T_TRACK_L, -4)
    row.track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -T_TRACK_R, 4)
    row.fill = Tinted(row, "BORDER")
    row.fill:SetPoint("TOPLEFT", row.track, "TOPLEFT")
    row.fill:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT")
    StyleThreatRow(row)
    return row
end

local function DrawThreat(pf)
    local st = Threat:GetState() or { rows = {} }
    local view = st.view or st.rows or {}
    local p = pf.layout
    local warn = (tonumber(Setting("warn", 85)) or 85)
    local me = st.me
    local note
    if not st.mob then note = "no target"
    elseif #view == 0 then note = st.tankView and "only you" or "not in combat"
    else note = st.name or "" end
    pf.noteText = note
    if #view > 0 and st.tankView then
        pf.totV:SetText("tanking")
        pf.tot:SetText("")
    elseif #view > 0 and me then
        -- "You 68%  · pull at 110%": how much room I have (was "68% pull 110%")
        pf.totV:SetText("You " .. (st.hot and S:Hex("BAD") or "") .. floor(me.raw + 0.5) .. "%" .. (st.hot and "|r" or ""))
        pf.tot:SetText(strformat("\194\183 pull at %d%%", st.pull or 110))
    else
        pf.totV:SetText("")
        pf.tot:SetText("")
    end
    local V = min(#view, p.rows or DEFAULT_ROWS)
    local rowsW = (pf.rows:GetWidth() or 0)
    if rowsW <= 0 then rowsW = PanelWidth(pf) - PAD * 2 end
    local trackW = max(10, rowsW - T_TRACK_L - T_TRACK_R)
    -- where a share lands: 0-100% on the track, past 100% into the pull zone (none in tank view: nobody passes the
    -- tank there, or they would be tanking)
    local pullAt = max(101, st.pull or 110)
    local zoneW = (st.tankView or not me) and 0 or min(PULL_ZONE_W, floor(trackW * 0.2))
    local mainW = trackW - zoneW
    local function X(v)
        if v <= 100 or zoneW == 0 then return mainW * min(1, max(0, v) / 100) end
        return mainW + zoneW * min(1, (v - 100) / (pullAt - 100))
    end
    local list = Window(pf, view, V, function(r) return r.me end)
    Thumb(pf, #view, V)
    local seen = {}
    for i = 1, #list do
        local r = list[i]
        local key = r.guid or r.name
        seen[key] = true
        local row = pf.trowsByKey[key]
        local fresh = false
        if not row then
            row = tremove(pf.trowPool) or NewThreatRow(pf)
            pf.trowsByKey[key] = row
            fresh = true
        end
        if row.styleKey ~= M.key then StyleThreatRow(row) end
        local spec = Meter:SpecOf(r.name)
        local cr, cg, cb = ns.MeterTheme:BarColor(r.cls, spec)
        row.cls = r.cls
        ns.MeterTheme:SetIcon(row, r.cls, spec, M)
        ns.MeterTheme:Me(row, M, r.me)
        if M.t.rank then row.rank:SetText(i + (pf.offset or 0)) end
        -- (a main tank: the game's shield before the name, Core/Tanks.lua)
        local mtN = r.name and ns.Tanks and ns.Tanks:Number(ns.Util.NormalizeName(r.name))
        SetT(row.name, (mtN and MT_ICON or "") .. (r.name or "?"))
        local nr, ng, nb = K.ClassColor(r.cls)
        if r.me then row.name:SetTextColor(S:Color("GOLD")) else row.name:SetTextColor(nr, ng, nb) end
        row.you:SetShown(r.me and true or false)
        row.track:ClearAllPoints()                    -- (the track: 0-100%; the pull zone after it is drawn once)
        row.track:SetPoint("TOPLEFT", row, "TOPLEFT", T_TRACK_L, row.trackTop or -4)
        row.track:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", T_TRACK_L, row.trackBot or 4)
        row.track:SetWidth(max(1, mainW))
        local share = st.tankView and r.scaled or r.raw
        -- (in tank view the one holding aggro is the 100% reference, in their colour, not a warning)
        local hot = (st.tankView and r.scaled >= warn and not r.tank) or (r.me and st.hot)
        if hot then row.fill:SetVertexColor(HOT_C[1], HOT_C[2], HOT_C[3], 0.9) else row.fill:SetVertexColor(cr, cg, cb, M.t.bar == "hair" and 1 or 0.8) end
        SetT(row.value, floor(share + 0.5) .. "%")
        if hot then row.value:SetTextColor(S:Color("BAD")) else row.value:SetTextColor(1, 1, 1) end
        row.tw = max(1, X(share))
        row.ty = -((i - 1) * (ROW_H + ROW_GAP))
        if fresh then row.anim = nil; row:SetAlpha(1) end
        if pf.switched then Enter(row, i)
        elseif fresh or not row.y or pf.jump then row.y, row.w = row.ty, row.tw end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", 0, row.y)
        row:SetPoint("RIGHT", pf.rows, "RIGHT", 0, 0)
        row.fill:SetWidth(max(1, row.w))
        row:Show()
    end
    for key, row in pairs(pf.trowsByKey) do
        if not seen[key] then row:Hide(); pf.trowsByKey[key] = nil; pf.trowPool[#pf.trowPool + 1] = row end
    end
    for key, row in pairs(pf.rowsByKey) do row:Hide(); row.data = nil; pf.rowsByKey[key] = nil; pf.rowPool[#pf.rowPool + 1] = row end

    -- the pull line, the tank line, the warning stretch
    local h = V * (ROW_H + ROW_GAP) - ROW_GAP
    local on = V > 0
    local lineX = T_TRACK_L + mainW + zoneW
    pf.pull:SetShown(on and (st.tankView or me ~= nil))
    pf.pull:ClearAllPoints()
    pf.pull:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", lineX - 1, 1)
    pf.pull:SetHeight(h + 2)
    pf.tankLine:Hide()                                -- (the track's end is the tank's 100%)
    local zoneOn = on and not st.tankView and me ~= nil and warn > 0
    pf.zone:SetShown(zoneOn)
    if zoneOn then
        -- the red stretch starts where the warning does (warn% of my pull point) and runs to the pull line
        local z0 = T_TRACK_L + X(pullAt * warn / 100)
        pf.zone:ClearAllPoints()
        pf.zone:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", z0, 0)
        pf.zone:SetSize(max(1, lineX - z0), h)
    end
    pf.hot = st.hot and true or false
    return V
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

-- The header: tabs or the view's name on the left, the note, the total, + and x on the right.
local function DrawHead(pf, tab)
    local p = pf.layout
    local avail = AvailTabs(p)
    local W = PanelWidth(pf)
    -- the right side: the total, + and x
    local function rightW()
        local tw = (pf.tot:GetText() or "") ~= "" and (pf.tot:GetStringWidth() or 0) + 6 or 0
        local vw = (pf.totV:GetText() or "") ~= "" and (pf.totV:GetStringWidth() or 0) or 0
        return 2 + 20 + 20 + 5 + tw + vw + 8
    end
    local x = 3
    -- only the tabs not used now are hidden: hiding a shown one each draw (4 a second in a fight) made it flicker
    -- under the mouse and lose clicks (in-game report 2026-10-11)
    for n, b in ipairs(pf.tabs) do
        if #avail < 2 or n > #avail then
            if b.dragging then b:SetAlpha(0) else b:Hide() end
        end
    end
    if #avail > 1 then
        pf.mode:Hide()
        local shown = ShownTab(p)
        -- full labels when they fit; else the inactive tabs keep only their icon; else the total gives way
        local full, compact = 8, 8
        for _, ti in ipairs(avail) do
            local info = ViewInfo(p.tabs[ti].view)
            local lw = 13 + 5 + UI:TextWidth(ns.MeterTheme:Label(info.label), "emph")
            full = full + lw + 12
            compact = compact + ((ti == shown) and lw or 13) + 12
        end
        local room = W - rightW()
        local iconsOnly = full > room
        if iconsOnly and compact > room then
            pf.totV:SetText("")
            pf.tot:SetText("")
        end
        x = 8
        for n, ti in ipairs(avail) do
            local b = pf.tabs[n]
            if not b then b = NewTab(pf); pf.tabs[n] = b end
            local info = ViewInfo(p.tabs[ti].view)
            local on = ti == shown
            b.index = ti
            b:SetHeight(HEAD_H)
            b.icon:SetTexture(info.icon)
            b.text:SetText((iconsOnly and not on) and "" or ns.MeterTheme:Label(info.label))
            b.text:SetTextColor(S:Color(on and "GOLD" or "SUB"))
            b.line:SetShown(on)
            b.icon:SetAlpha(on and 1 or 0.75)
            b.label = info.label
            local w = 13 + ((b.text:GetText() or "") ~= "" and (5 + b.text:GetStringWidth()) or 0)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("LEFT", pf.head, "LEFT", x, 0)
            if not b:IsShown() then b:Show() end
            x = x + w + 12
        end
    else
        local info = ViewInfo(tab.view)
        pf.mode:Show()
        pf.mode.icon:SetTexture(info.icon)
        pf.mode.text:SetText(ns.MeterTheme:Label(info.label))
        local w = (M.t.noHeadIcon and 5 or (4 + 14 + 6)) + pf.mode.text:GetStringWidth() + 5 + 9 + 5
        pf.mode:SetWidth(w)
        x = 3 + w + 4
    end
    -- the note between the left part and the total: shown only when it fits whole
    local room = W - x - rightW()
    local text = pf.noteText or ""
    pf.note.text:SetText(text)
    local need = pf.note.text:GetStringWidth() + 7
    local fits = text ~= "" and need <= room
    pf.note:SetShown(fits)
    if fits then
        pf.note.text:SetWidth(need)
        pf.note:SetWidth(need)
        pf.note:SetHeight(20)
        pf.note:ClearAllPoints()
        pf.note:SetPoint("LEFT", pf.head, "LEFT", x, 0)
    end
end

-- The fight line: the fight's name and, as room allows, its length and place ("5 of 6"); a name too long for the line
-- gives way to "Fight 5", never to a cut-off name. The live fight's name is gold, a boss's amber. Returns its height.
local function DrawFightLine(pf, tab)
    local fl = pf.fl
    local seg = not IsThreat(tab.view) and Meter:GetSegment(tab.seg or "cur")
    if not seg then fl:Hide() return 0 end
    local order, at, nFights = FightOrder(tab.seg)
    if not at then fl:Hide() return 0 end
    local isAll = seg.kind == "all"
    local name = Meter:SegName(seg)
    local where = isAll and "all fights" or strformat("%d of %d", at, nFights)
    local length = K.Clock(Meter:Duration(seg))
    if seg.live then length = length .. " \194\183 live" end
    local room = PanelWidth(pf) - 44 - 8
    local tries = { { name, "  " .. length .. " \194\183 " .. where }, { name, "  " .. length }, { name, "" },
                    { isAll and "All fights" or ("Fight " .. at), "" } }
    local pick = tries[#tries]
    for _, t in ipairs(tries) do
        fl.name:SetText(t[1])
        fl.meta:SetText(t[2])
        if (fl.name:GetStringWidth() or 0) + (fl.meta:GetStringWidth() or 0) <= room then pick = t break end
    end
    fl.name:SetText(pick[1])
    fl.meta:SetText(pick[2])
    local c = ((tab.seg or "cur") == "cur") and K.GOLD or (seg.kind == "boss" and BOSS_C) or K.INK
    fl.name:SetTextColor(c[1], c[2], c[3])
    local w = (fl.name:GetStringWidth() or 0) + (fl.meta:GetStringWidth() or 0)
    fl.name:ClearAllPoints()
    fl.name:SetPoint("LEFT", fl.lab, "LEFT", max(0, floor((room + 8 - w) / 2)), 0)
    fl.prev:SetEnabled(at > 1)
    fl.prev:SetAlpha(at > 1 and 1 or 0.25)
    fl.next:SetEnabled(at < #order)
    fl.next:SetAlpha(at < #order and 1 or 0.25)
    fl:Show()
    return FL_H
end

function MP:Draw()
    if not holder or not holder:IsShown() then dirty = true return end
    dirty = false
    if not M then ApplyMetrics() end
    local fight = (Meter:GetLive() ~= nil) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
    local migrated = false
    lastDraw = GetTime()
    for _, f in ipairs(stackFrames) do
        if f:IsShown() and f.layout then
            local y = 0
            local hot = false
            for i, pf in ipairs(f.panels) do
                local tab, ti = self:TabOf(pf)
                local viewKey = tostring(tab.view) .. "|" .. tostring(tab.seg) .. "|" .. tostring(ti)
                pf.switched = pf.drawn and pf.viewKey ~= nil and pf.viewKey ~= viewKey or false
                if pf.switched then pf.peak, pf.offset = nil, 0 end   -- (the new view's own height, from its top)
                pf.viewKey = viewKey
                if pf.styleKey ~= M.key then ns.MeterTheme:SkinPanel(pf, M); pf.flShown = nil end
                pf:ClearAllPoints()
                pf:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -y)
                pf:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -y)
                pf.sep:SetShown(i > 1)
                local n
                if IsThreat(tab.view) then n = DrawThreat(pf) else n = DrawMeter(pf, tab) end
                local flH = DrawFightLine(pf, tab)
                if pf.flShown ~= (flH > 0) then
                    pf.flShown = flH > 0
                    local above = pf.flShown and pf.fl or pf.head
                    pf.rows:ClearAllPoints()
                    pf.rows:SetPoint("TOPLEFT", above, "BOTTOMLEFT", PAD, -PAD)
                    pf.rows:SetPoint("TOPRIGHT", above, "BOTTOMRIGHT", -PAD, -PAD)
                end
                if fight then
                    n = max(n, pf.peak or 0)
                    pf.peak = n
                else
                    pf.peak = nil
                end
                DrawHead(pf, tab)
                local body = n > 0 and (PAD * 2 + n * ROW_H + (n - 1) * ROW_GAP) or 0
                pf.rows:SetHeight(max(1, body - PAD * 2))
                pf.rows:SetShown(n > 0)
                local h = HEAD_H + flH + body
                pf:SetHeight(h)
                y = y + h
                if pf.hot then hot = true end
            end
            f:SetHeight(max(HEAD_H, y))
            f.warn = hot
            -- (layouts saved before stacks could hang from their bottom edge: a stack low on the screen switches to
            -- its bottom edge once, where it is now, so it stays put and grows upward from here on)
            local s = f.layout
            if (Layout().v or 1) < 2 and s.y and not s.b and not drag then
                local h = max(HEAD_H, y)
                local _, hh = HolderSize()
                if s.y - h / 2 < hh / 2 then
                    s.b, s.y = s.y - h, nil
                    migrated = true
                end
            end
        end
    end
    if (Layout().v or 1) < 2 and holder:IsShown() then
        Layout().v = 2                 -- (and Rebuild's step brings it to 3)
        if migrated then self:Rebuild() end
    end
end

-- Bars glide (exponential ease) toward their places.
-- A row entering after a view switch: its bar grows (ease-out cubic) and it fades in, after its turn in the cascade.
local function StepEnter(pf, row, elapsed)
    local an = row.anim
    an.t = an.t + elapsed
    local q = (an.t - an.delay) / ENTER_DUR
    local e
    if q >= 1 then
        row.anim = nil
        e = 1
        row:SetAlpha(1)
    elseif q > 0 then
        e = 1 - (1 - q) ^ 3
        row:SetAlpha(min(1, q * 1.7))
    else
        return
    end
    row.w = (row.tw or 0) * e
    row.ew = (row.tew or 0) * e
    row.y = row.ty or row.y
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", 0, row.y)
    row:SetPoint("RIGHT", pf.rows, "RIGHT", 0, 0)
    row.fill:SetWidth(max(1, row.w))
    if row.ext then
        row.ext:SetWidth(max(0.01, row.ew))
        row.ext:SetShown(row.ew > 0.5)
    end
end

local function Animate(elapsed)
    local k = 1 - exp(-elapsed / EASE)
    for _, pf in ipairs(allPanels) do
        if pf:IsShown() then
            for _, row in pairs(pf.rowsByKey) do
                if row.anim then StepEnter(pf, row, elapsed)
                elseif row.ty and (abs(row.ty - row.y) > 0.3 or abs(row.tw - row.w) > 0.3 or abs((row.tew or 0) - (row.ew or 0)) > 0.3) then
                    row.y = row.y + (row.ty - row.y) * k
                    row.w = row.w + (row.tw - row.w) * k
                    row.ew = (row.ew or 0) + ((row.tew or 0) - (row.ew or 0)) * k
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", 0, row.y)
                    row:SetPoint("RIGHT", pf.rows, "RIGHT", 0, 0)
                    row.fill:SetWidth(max(1, row.w))
                    row.ext:SetWidth(max(0.01, row.ew))
                    row.ext:SetShown(row.ew > 0.5)
                end
            end
            for _, row in pairs(pf.trowsByKey) do
                if row.anim then StepEnter(pf, row, elapsed)
                elseif row.ty and (abs(row.ty - row.y) > 0.3 or abs(row.tw - row.w) > 0.3) then
                    row.y = row.y + (row.ty - row.y) * k
                    row.w = row.w + (row.tw - row.w) * k
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", pf.rows, "TOPLEFT", 0, row.y)
                    row:SetPoint("RIGHT", pf.rows, "RIGHT", 0, 0)
                    row.fill:SetWidth(max(1, row.w))
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Docking: dragging, detaching, snapping, tabs
---------------------------------------------------------------------------

function MP:StartDrag(si, alone)
    local f = stackFrames[si]
    if not f then return end
    GameTooltip:Hide(); HideRowTip()
    ns.UI:CloseMenus()
    f:SetFrameLevel(holder:GetFrameLevel() + 50)
    -- a stack in a row takes the row along (alone: it leaves the row)
    local s = f.layout
    local members, moving = {}, { [f] = true }
    if s and s.g and alone then
        s.g = nil
    elseif s and s.g then
        for _, g in ipairs(stackFrames) do
            if g ~= f and g:IsShown() and g.layout and g.layout.g == s.g then
                g:SetFrameLevel(holder:GetFrameLevel() + 50)
                members[#members + 1] = { frame = g, ox = (g:GetLeft() or 0) - (f:GetLeft() or 0),
                                          oy = (g:GetTop() or 0) - (f:GetTop() or 0) }
                moving[g] = true
            end
        end
    end
    -- the stack follows the cursor (set each frame in UpdateDrag) instead of StartMoving: no client frame-moving
    -- state to depend on. In game the docking never happened: the drag ended on its first frame (see ButtonUp).
    local sc = f:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / sc, cy / sc
    drag = { si = si, frame = f, dx = cx - (f:GetLeft() or 0), dy = cy - (f:GetTop() or 0), members = members,
             moving = moving }
end

-- Is the left button up again? Only once IsMouseButtonDown has said it was down during this drag / resize: in this
-- client it may never say so (a drag that ended on its first frame), and then the drag ends on OnDragStop or
-- GLOBAL_MOUSE_UP instead.
local function ButtonUp(state)
    local down = IsMouseButtonDown and IsMouseButtonDown("LeftButton")
    if down then state.sawDown = true return false end
    return state.sawDown == true
end

-- Pulls a panel (or one of its tabs) out of its stack into a stack of its own and starts dragging that.
function MP:Detach(si, pi, tabIndex)
    local L = Layout()
    local s = L.stacks[si]
    local p = s and s.panels[pi]
    if not p then return end
    local f = stackFrames[si]
    local pf = frameOf[p]
    local x, y = f:GetLeft() or s.x, (pf and pf:GetTop()) or s.y
    local newp
    if tabIndex then
        newp = { tabs = { tremove(p.tabs, tabIndex) }, active = 1, rows = p.rows }
        p.active = min(p.active or 1, #p.tabs)
        local cx, cy = GetCursorPosition()
        local sc = holder:GetEffectiveScale()
        x, y = cx / sc - 40, cy / sc + 12
    else
        tremove(s.panels, pi)
        newp = p
    end
    L.stacks[#L.stacks + 1] = { x = x, y = y, w = s.w, panels = { newp } }
    if #s.panels == 0 then tremove(L.stacks, si) end
    self:Rebuild()
    self:StartDrag(#L.stacks)
end

local function Rect(fr) return fr:GetLeft() or 0, fr:GetTop() or 0, fr:GetWidth() or 0, fr:GetHeight() or 0 end

-- The gold line where it joins and the outline of what it joins: frames of their own above every stack (as textures
-- of the holder they were drawn under the stacks, and a line on a stack's top or bottom edge never showed).
local function ShowGuide(x, y, w, h)
    guide:ClearAllPoints()
    guide:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", x, y)
    guide:SetSize(max(3, w), max(3, h))
    guide:Show()
end
local function ShowOutline(l, t, w, h)
    outline:ClearAllPoints()
    outline:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", l, t)
    outline:SetSize(max(2, w), max(2, h))
    outline:Show()
end
local function HideGuides()
    guide:Hide()
    outline:Hide()
    for _, pf in ipairs(allPanels) do pf.head.drop:Hide(); pf.head.dropText:Hide() end
end

-- Where a stack dropped now would go (no frames involved, so it can be tested with plain numbers): m = the moving
-- stack (or row) { l, t, w, h }, cx / cy = the cursor, others = { { stack, l, t, w, h, heads = { { panel, l, t, r, b
-- } } } }, sides = only beside (a whole row moving). Returns the target ({ kind = "tab" | "below" | "above" | "right"
-- | "left", stack, panel, rect = { l, t, w, h } }) and the guide ({ x, y, w, h }) or nil.
--   Over a header: a tab there. Over a stack, or just past its top or bottom edge (NEAR), lined up with it (they
--   overlap by 40% of the narrower one): above or below it, by which half its middle is in (2026-10-11: an exact
--   edge, 18 px, was too hard to hit). Beside it (its edge within NEAR, tops within SIDE_Y or overlapping): its row.
function MP.FindTarget(m, cx, cy, others, sides)
    if not sides then
        for _, o in ipairs(others) do
            for _, hd in ipairs(o.heads) do
                if cx >= hd[2] and cx <= hd[4] and cy <= hd[3] and cy >= hd[5] then
                    return { kind = "tab", stack = o[1], panel = hd[1], head = hd, rect = { o[2], o[3], o[4], o[5] } }
                end
            end
        end
    end
    local l, t, w, h = m[1], m[2], m[3], m[4]
    local mc = t - h / 2
    for _, o in ipairs(others) do
        local gl, gt, gw, gh = o[2], o[3], o[4], o[5]
        local gb = gt - gh
        local rect = { gl, gt, gw, gh }
        local across = min(l + w, gl + gw) - max(l, gl)          -- horizontal overlap
        local upDown = min(t, gt) - max(t - h, gb)               -- vertical overlap
        if not sides and across >= min(w, gw) * 0.4 then
            if mc < gt - gh / 2 and t >= gb - NEAR then
                return { kind = "below", stack = o[1], rect = rect }, { gl, gb + 1, gw, 3 }
            elseif mc >= gt - gh / 2 and t - h <= gt + NEAR then
                return { kind = "above", stack = o[1], rect = rect }, { gl, gt + 2, gw, 3 }
            end
        end
        local level = abs(t - gt) < SIDE_Y or abs((t - h) - gb) < SIDE_Y or upDown > 0
        if level and across < min(w, gw) * 0.4 then
            if abs(l - (gl + gw)) < NEAR then
                return { kind = "right", stack = o[1], rect = rect }, { gl + gw - 2, gt, 3, max(gh, h) }
            elseif abs((l + w) - gl) < NEAR then
                return { kind = "left", stack = o[1], rect = rect }, { gl - 1, gt, 3, max(gh, h) }
            end
        end
    end
    return nil
end

local function UpdateDrag()
    local d = drag
    local f = d.frame
    if ButtonUp(d) then MP:EndDrag() return end
    HideGuides()
    local sc = f:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / sc, cy / sc
    local nx, ny = cx - (d.dx or 0), cy - (d.dy or 0)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", nx, ny)
    for _, mb in ipairs(d.members or {}) do
        mb.frame:ClearAllPoints()
        mb.frame:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", nx + mb.ox, ny + mb.oy)
    end
    local others = {}
    for _, g in ipairs(stackFrames) do
        if not d.moving[g] and g:IsShown() and g.layout then
            local gl, gt, gw, gh = Rect(g)
            local o = { g.layout, gl, gt, gw, gh, heads = {} }
            for _, pf in ipairs(g.panels) do
                local hd = pf.head
                o.heads[#o.heads + 1] = { pf.layout, hd:GetLeft() or 0, hd:GetTop() or 0, hd:GetRight() or 0,
                                          hd:GetBottom() or 0, frame = pf }
            end
            others[#others + 1] = o
        end
    end
    -- (a row moving: its whole box, and only beside another stack)
    local l, t, w, h = Rect(f)
    local r, bt = l + w, t - h
    for _, mb in ipairs(d.members or {}) do
        local ml, mt, mw, mh = Rect(mb.frame)
        l, t, r, bt = min(l, ml), max(t, mt), max(r, ml + mw), min(bt, mt - mh)
    end
    local target, g = MP.FindTarget({ l, t, r - l, t - bt }, cx, cy, others, #(d.members or {}) > 0)
    d.target = target
    -- Edit layout: not docking anywhere, the stack (or its row) snaps like the other frames
    local EM = ns.EditMode
    if EM and EM:IsActive() then
        if target then EM:ClearGuides()
        else
            local sx, sy = EM:SnapBox(f, l, t, r - l, t - bt)
            local ddx, ddy = sx - l, sy - t
            if ddx ~= 0 or ddy ~= 0 then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", nx + ddx, ny + ddy)
                for _, mb in ipairs(d.members or {}) do
                    mb.frame:ClearAllPoints()
                    mb.frame:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", nx + ddx + mb.ox, ny + ddy + mb.oy)
                end
            end
        end
    end
    if target and target.kind == "tab" then
        target.head.frame.head.drop:Show()
        target.head.frame.head.dropText:Show()
    elseif target then
        local q = target.rect
        ShowOutline(q[1], q[2], q[3], q[4])
        if g then ShowGuide(g[1], g[2], g[3], g[4]) end
    end
end

local function IndexOf(list, item) for i, x in ipairs(list) do if x == item then return i end end end

function MP:EndDrag()
    local d = drag
    if not d then return end
    drag = nil
    if ns.EditMode then ns.EditMode:ClearGuides() end
    local f = d.frame
    HideGuides()
    local L = Layout()
    local s = f.layout
    if not s then self:Rebuild() return end
    -- where it was let go: held by the edge nearer the screen's edge, so it grows away from it (a row: all of it)
    local _, hh = HolderSize()
    local top, bottom = f:GetTop() or s.y or 0, f:GetBottom() or s.b or 0
    local byBottom = (top + bottom) / 2 < hh / 2
    local moved = { s }
    for _, mb in ipairs(d.members or {}) do if mb.frame.layout then moved[#moved + 1] = mb.frame.layout end end
    for _, fr in ipairs(d.members or {}) do fr.frame:SetFrameLevel(holder:GetFrameLevel() + 1) end
    local frames = { f }
    for _, mb in ipairs(d.members or {}) do frames[#frames + 1] = mb.frame end
    for _, fr in ipairs(frames) do
        local st = fr.layout
        if st then
            st.x = fr:GetLeft() or st.x
            if byBottom then st.b, st.y = fr:GetBottom() or st.b or 0, nil else st.y, st.b = fr:GetTop() or st.y or 0, nil end
        end
    end
    local tg = d.target
    if tg then
        local si = IndexOf(L.stacks, s)
        if tg.kind == "tab" then
            local into = tg.panel
            for _, p in ipairs(s.panels) do
                for _, t in ipairs(p.tabs) do into.tabs[#into.tabs + 1] = t end
            end
            into.active = #into.tabs
            if si then tremove(L.stacks, si) end
        elseif tg.kind == "below" then
            for _, p in ipairs(s.panels) do tg.stack.panels[#tg.stack.panels + 1] = p end
            if tg.stack.b then tg.stack.b = bottom end          -- (held by its bottom: that edge moves down)
            if si then tremove(L.stacks, si) end
        elseif tg.kind == "above" then
            for i = #s.panels, 1, -1 do tinsert(tg.stack.panels, 1, s.panels[i]) end
            if tg.stack.y then tg.stack.y = top end             -- (held by its top: that edge moves up)
            if si then tremove(L.stacks, si) end
        elseif tg.kind == "right" or tg.kind == "left" then
            -- into the target's row, right beside it: the row's order is set here (x from the target outward) and
            -- PackRows keeps it
            local gid = tg.stack.g
            if not gid then
                gid = 0
                for _, st in ipairs(L.stacks) do gid = max(gid, st.g or 0) end
                gid = gid + 1
                tg.stack.g = gid
            end
            local isMoved = {}
            for _, st in ipairs(moved) do isMoved[st] = true end
            local row = {}
            for _, st in ipairs(L.stacks) do
                if st.g == gid and not isMoved[st] and Visible(st) then row[#row + 1] = st end
            end
            tsort(row, function(a, c) return (a.x or 0) < (c.x or 0) end)
            tsort(moved, function(a, c) return (a.x or 0) < (c.x or 0) end)
            local at = (IndexOf(row, tg.stack) or #row) + (tg.kind == "right" and 1 or 0)
            for i, st in ipairs(moved) do
                st.g = gid
                tinsert(row, at + i - 1, st)
            end
            local ti = IndexOf(row, tg.stack)
            for i = ti - 1, 1, -1 do row[i].x = row[i + 1].x - Width(row[i]) + 1 end
            for i = ti + 1, #row do row[i].x = row[i - 1].x + Width(row[i - 1]) - 1 end
            for _, st in ipairs(row) do
                if tg.stack.b then st.b, st.y = tg.stack.b, nil else st.y, st.b = tg.stack.y, nil end
            end
        end
    end
    f:SetFrameLevel(holder:GetFrameLevel() + 1)
    self:Rebuild()
end

-- The corner sets the width and the row count of the panel next to it (the bottom one, or the top one of a stack
-- held by its bottom edge, whose corner is at the top).
function MP:StartResize(f)
    if Locked() or not f.layout then return end
    local pf = f.up and f.panels[1] or f.panels[#f.panels]
    local sc = f:GetEffectiveScale()
    local _, cy = GetCursorPosition()
    resize = { frame = f, panel = pf and pf.layout, pf = pf, up = f.up, y0 = cy / sc,
               rows0 = pf and pf.layout and (pf.layout.rows or DEFAULT_ROWS) or DEFAULT_ROWS }
end

local function UpdateResize()
    local r = resize
    if ButtonUp(r) then MP:EndResize() return end
    local f = r.frame
    local sc = f:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / sc, cy / sc
    local w = min(MAX_W, max(MIN_W, cx - (f:GetLeft() or 0)))
    f:SetWidth(w)
    f.layout.w = floor(w + 0.5)
    if f.layout.g then                  -- (the stacks right of it in its row move along)
        PackRows(Layout())
        for _, g in ipairs(stackFrames) do
            if g ~= f and g.layout and g.layout.g == f.layout.g then Anchor(g, g.layout) end
        end
    end
    -- rows change by how far the corner moved (away from the stack's held edge = more), from the count it had: a
    -- width-only drag never touches them. (Measured from the panel's own edge, a panel showing no rows, like Threat
    -- out of combat, went to 1 row the moment the corner was touched; in-game report 2026-10-10.)
    if r.panel and r.pf then
        local dy = cy - r.y0
        if not r.up then dy = -dy end
        local steps = (dy >= 0 and floor or math.ceil)(dy / (ROW_H + ROW_GAP))
        local rows = min(MAX_ROWS, max(1, r.rows0 + steps))
        if steps ~= 0 or r.panel.rows ~= nil then r.panel.rows = rows end
    end
    MP:Draw()
end

function MP:EndResize()
    if not resize then return end
    resize = nil
    self:Draw()
end

---------------------------------------------------------------------------
-- Menus and buttons
---------------------------------------------------------------------------

local function ViewText(v)
    local info = ViewInfo(v)
    return strformat("|T%s:14:14:0:0:64:64:5:59:5:59|t  %s", info.icon, info.label)
end

local function SetView(pf, v)
    local tab = MP:TabOf(pf)
    tab.view = v
    if IsThreat(v) and not Threat:IsEnabled() then Set("thr", true) end
    if not IsThreat(v) and not Meter:IsEnabled() then Set("dmg", true) end
    MP:Rebuild()
end

local function EJText(seg)
    local key = seg.name and ns.MyLog and ns.MyLog.BossDataKey and ns.MyLog:BossDataKey(seg.name)
    local fid = key and ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[key]
    if fid then return strformat("|T%s:16:32:0:0:128:64:0:128:0:64|t ", tostring(fid)) end
    return ""
end

local function FightEntries(root, pf)
    local fights, all = Meter:GetFights()
    local tab = MP:TabOf(pf)
    if #fights == 0 then root:CreateTitle("No fights yet") return end
    for i, seg in ipairs(fights) do
        local key = EJText(seg)
        local e = root:CreateRadio(key .. (seg.live and "Current fight" or Meter:SegName(seg)), function()
            if (tab.seg or "cur") == "cur" then return i == 1 end
            return tab.seg == seg.id
        end, function() MP:SetFight(pf, (i == 1) and "cur" or seg.id) end, seg.id)
        e:SetSubtext(MP.FightSub(seg))
        if seg.live then e:SetBadge("Live", S.C.LIVE) end
    end
    if all then
        root:CreateDivider()
        local e = root:CreateRadio(Meter:SegName(all), function() return tab.seg == "all" end,
            function() MP:SetFight(pf, "all") end, "all")
        local since = all.at and date and (" · since " .. date("%H:%M", all.at)) or ""
        e:SetSubtext((all.zone or "") .. since .. " · " .. K.Clock(Meter:Duration(all)))
    end
end

function MP.FightSub(seg)
    local parts = {}
    if seg.kind == "boss" then
        if seg.live then parts[#parts + 1] = "Live"
        elseif seg.kill then parts[#parts + 1] = S:Wrap("OK", "Kill")
        else parts[#parts + 1] = S:Wrap("BAD", "Wipe" .. (seg.pct and strformat(" %d%%", floor(seg.pct + 0.5)) or "")) end
    elseif seg.kind == "trash" then
        parts[#parts + 1] = seg.live and "Live" or "Trash"
    end
    parts[#parts + 1] = K.Clock(Meter:Duration(seg))
    if seg.at and date then parts[#parts + 1] = date("%H:%M", seg.at) end
    if seg.cut then parts[#parts + 1] = "cut short" end
    return table.concat(parts, " · ")
end

-- The view's name: views (and, for a meter mode, the fight).
function MP:ViewMenu(pf, owner)
    local tab = self:TabOf(pf)
    ns.UI:ContextMenu(owner, function(root)
        for i, v in ipairs(VIEWS) do
            if (i == 3 or i == 5 or i == 6 or i == 9) then root:CreateDivider() end
            root:CreateRadio(ViewText(v), function() return tab.view == v end, function() SetView(pf, v) end, v)
        end
        if not IsThreat(tab.view) then
            root:CreateDivider()
            local f = root:CreateButton("Fight")
            FightEntries(f, pf)
        end
    end)
end

---------------------------------------------------------------------------
-- The fight list (the fight line's name opens it; the user's pick C of the fight list mockup, 2026-10-11)
---------------------------------------------------------------------------
-- Newest first, by zone: the whole raid on top, then each zone's bosses as rows (Encounter Journal picture, Kill /
-- Wipe 38% / Live, length) and each run of trash between them as one row of squares, one per pull, oldest to newest
-- (hover: the enemy, length and time; click: that fight). A night of 25 fights fits in a dozen lines. The list is as
-- wide as its longest row (never a cut-off name), opens under the line (over it when the panel is low on the
-- screen), scrolls past FLIST_MAX_H, and closes on a pick, a click elsewhere or Escape. Own frame: the dropdown
-- menus (UI/Menu.lua) have no row of squares; it borrows their colours and edges.
local FLIST_PAD, FLIST_ROW, FLIST_ZONE, FLIST_DOT, FLIST_GAP = 4, 24, 18, 12, 3
local FLIST_MIN_W, FLIST_MAX_W, FLIST_MAX_H = 240, 380, 440
local FLIST_IX, FLIST_TX = 6, 42           -- the picture column, then the text
local WHOLE_C = { 0.61, 0.76, 1 }
-- a boss fight's result as an icon (asked 2026-10-11): a kill the ready-check tick, a wipe the skull the meters use
-- for deaths (with the boss's health left); trash runs take the crossed swords of combat, not the skull
local KILL_TEX = "Interface\\RaidFrame\\ReadyCheck-Ready"
local SWORDS_TEX, SWORDS_TC = "Interface\\CharacterFrame\\UI-StateIcon", { 0.5, 1, 0, 0.49 }
local flist

local function BossArt(seg)
    local key = seg.name and ns.MyLog and ns.MyLog.BossDataKey and ns.MyLog:BossDataKey(seg.name)
    return key and ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[key]
end

local function ListTime(seg) return (seg.at and date) and date("%H:%M", seg.at) or nil end

local function NewListRow(f)
    local r = CreateFrame("Button", nil, f.canvas)
    r:RegisterForClicks("LeftButtonUp")
    -- the shared row looks: hover, and the picked fight's gold bar (the wash stays off: the dropdowns' look)
    UI:DecorateRow(r, { hover = true, selectable = true })
    r.hl = r.dzHover
    r.sel = r.dzSelBar
    r.dzSelFill:SetAlpha(0)
    r.sel:ClearAllPoints()
    r.sel:SetPoint("TOPLEFT", 0, -5)
    r.sel:SetPoint("BOTTOMLEFT", 0, 5)
    r.pic = r:CreateTexture(nil, "ARTWORK")
    r.bars = {}
    for i, hgt in ipairs({ 6, 12, 9 }) do
        local t = UI:Fill(r, WHOLE_C, "ARTWORK")
        t:ClearAllPoints()
        t:SetSize(4, hgt)
        r.bars[i] = t
    end
    r.name = UI:Text(r, "emph", "TEXT", { shadow = true })
    r.small = UI:Text(r, "body", "SUB", { font = K.NARROW, shadow = true })
    r.len = UI:Text(r, "emph", "SUB", { font = K.NARROW, justify = "RIGHT", shadow = true })
    r.status = UI:Text(r, "body", "SUB", { font = K.NARROW, shadow = true })
    r.stIcon = r:CreateTexture(nil, "ARTWORK")
    r.stIcon:SetSize(14, 14)
    r.line = UI:Rule(r, { color = "HAIRLINE" })
    r.line:ClearAllPoints()
    -- a zone's heading: the shared caps section header (its fading rule runs to the row's end)
    r.head = UI:CreateSectionHeader(r, "", { style = "caps" })
    r.head:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 8, 0)
    r.head:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -8, 0)
    r.head:Hide()
    -- a boss row says in words what its icon means
    UI:AttachTooltip(r, function(self, tt)
        local seg = self.seg
        if not seg or seg.kind ~= "boss" then return false end
        tt:AddLine(Meter:SegName(seg), S:RGB("GOLD"))
        local what
        if seg.live then what = S:Wrap("BAD", "Live")
        elseif seg.kill then what = S:Wrap("OK", "Kill")
        else what = S:Wrap("BAD", "Wipe" .. (seg.pct and strformat(" at %d%%", floor(seg.pct + 0.5)) or "")) end
        local t = ListTime(seg)
        tt:AddLine(what .. "  \194\183  " .. K.Clock(Meter:Duration(seg)) .. (t and ("  \194\183  " .. t) or ""), 1, 1, 1)
    end)
    r.dots = {}
    r:SetScript("OnClick", function(self) if self.sel_key then MP:PickFromList(self.sel_key) end end)
    return r
end

-- A trash pull's square: the quiet lift, brighter under the mouse, gold when it is the panel's fight.
-- TODO(refactor): move into a shared "pip" control (no component draws a row of clickable squares).
local function PaintDot(d, hot)
    if d.on then d.fill:SetVertexColor(S:Color("GOLD")) else d.fill:SetVertexColor(1, 1, 1, hot and 0.45 or 0.16) end
end

local function NewDot(r)
    local d = CreateFrame("Button", nil, r)
    d:SetSize(FLIST_DOT, FLIST_DOT)
    d:RegisterForClicks("LeftButtonUp")
    d.fill = d:CreateTexture(nil, "ARTWORK")
    d.fill:SetTexture(K.WHITE)
    d.fill:SetAllPoints()
    d:SetScript("OnEnter", function(self) PaintDot(self, true) end)
    d:SetScript("OnLeave", function(self) PaintDot(self, false) end)
    UI:AttachTooltip(d, function(self, tt)
        local seg = self.seg
        if not seg then return false end
        local t = ListTime(seg)
        local sr, sg, sb = S:Color("SUB")
        tt:AddDoubleLine(Meter:SegName(seg), K.Clock(Meter:Duration(seg)) .. (t and ("  \194\183  " .. t) or ""),
            1, 1, 1, sr, sg, sb)
        if seg.live then tt:AddLine("Live", S:RGB("BAD")) end
    end, nil, { anchor = "AUTO_Y" })
    d:SetScript("OnClick", function(self) if self.sel_key then MP:PickFromList(self.sel_key) end end)
    return d
end

local function ListFrame()
    if flist then return flist end
    -- (the dropdowns' surface and edge: UI:CreateHudFrame with no look of its own, then the menu tokens)
    local f = UI:CreateHudFrame("DisasterZoneFightList", { look = "none", movable = false, position = false,
        strata = "FULLSCREEN_DIALOG", toplevel = true })
    f:EnableMouseWheel(true)
    f:Hide()
    f.bg = UI:Fill(f, "DROP_BG", "BACKGROUND")
    UI:AddEdges(f, "BORDER")
    UI:SetEdgeColor(f, S:Color("DROP_EDGE"))
    f.clip = CreateFrame("Frame", nil, f)
    f.clip:SetPoint("TOPLEFT", FLIST_PAD, -FLIST_PAD)
    f.clip:SetPoint("BOTTOMRIGHT", -FLIST_PAD, FLIST_PAD)
    if f.clip.SetClipsChildren then f.clip:SetClipsChildren(true) end
    f.canvas = CreateFrame("Frame", nil, f.clip)
    f.canvas:SetSize(1, 1)
    f.thumb = UI:Fill(f, { 1, 1, 1, 0.22 }, "OVERLAY")
    f.thumb:ClearAllPoints()
    f.thumb:SetWidth(2)
    f.thumb:Hide()
    f.rows, f.offset = {}, 0
    f:SetScript("OnMouseWheel", function(self, delta)
        if (self.contentH or 0) <= (self.viewH or 0) then return end
        self.offset = max(0, min(self.contentH - self.viewH, self.offset - delta * FLIST_ROW * 2))
        MP:PlaceList()
    end)
    f:SetScript("OnShow", function(self)
        self:RegisterEvent("GLOBAL_MOUSE_DOWN")
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:SetScript("OnHide", function(self)
        self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        if not InCombatLockdown() then self:EnableKeyboard(false) end
        GameTooltip:Hide()
    end)
    f:SetScript("OnKeyDown", function(self, key)
        if key ~= "ESCAPE" then return end
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
        self:Hide()
    end)
    -- a press anywhere else closes it (a press on the name that opened it: its click closes it, MP:FightMenu)
    f:SetScript("OnEvent", function(self)
        if self:IsMouseOver() then return end
        local o = self.owner
        if o and o:IsVisible() and o:IsMouseOver() then return end
        self:Hide()
    end)
    flist = f
    return f
end

function MP:PlaceList()
    local f = flist
    if not f then return end
    f.canvas:ClearAllPoints()
    f.canvas:SetPoint("TOPLEFT", f.clip, "TOPLEFT", 0, f.offset)
    local scrolls = f.contentH > f.viewH
    f.thumb:SetShown(scrolls)
    if scrolls then
        local h = f.viewH
        f.thumb:ClearAllPoints()
        f.thumb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -FLIST_PAD - floor(h * f.offset / f.contentH + 0.5))
        f.thumb:SetHeight(max(10, h * h / f.contentH))
    end
end

function MP:PickFromList(key)
    local f = flist
    if not f or not f.pf then return end
    local pf = f.pf
    f:Hide()
    self:SetFight(pf, key)
end

-- The list's lines: { kind = "whole" | "zone" | "boss" | "trash", seg | text | pulls }.
local function ListLines()
    local fights, all = Meter:GetFights()           -- (newest first)
    local lines = {}
    if all then
        lines[#lines + 1] = { kind = "whole", seg = all }
        lines[#lines + 1] = { kind = "sep" }
    end
    local zone
    for i, seg in ipairs(fights) do
        local z = seg.zone or "Unknown place"
        if z ~= zone then
            zone = z
            lines[#lines + 1] = { kind = "zone", text = z }
        end
        local key = (i == 1) and "cur" or seg.id
        if seg.kind == "boss" then
            lines[#lines + 1] = { kind = "boss", seg = seg, key = key }
        else
            local last = lines[#lines]
            if not (last and last.kind == "trash") then
                last = { kind = "trash", pulls = {} }
                lines[#lines + 1] = last
            end
            tinsert(last.pulls, 1, { seg = seg, key = key })      -- (oldest first, left to right)
        end
    end
    return lines
end

local function FillList(f, pf)
    local tab = MP:TabOf(pf)
    local selKey = tab.seg or "cur"
    local lines = ListLines()
    for _, r in ipairs(f.rows) do r:Hide() end
    -- the width: the widest row's needs
    -- (text, its colour, icon): Live in words, a kill the tick, a wipe the skull and the boss's health left
    local function status(seg)
        if seg.live then return "Live", S.C.BAD end
        if seg.kind ~= "boss" then return nil end
        if seg.kill then return nil, nil, "kill" end
        return seg.pct and strformat("%d%%", floor(seg.pct + 0.5)) or nil, S.C.BAD, "wipe"
    end
    local need = FLIST_MIN_W
    for _, ln in ipairs(lines) do
        if ln.kind == "whole" or ln.kind == "boss" then
            local st, _, icon = status(ln.seg)
            local w = FLIST_TX + UI:TextWidth(Meter:SegName(ln.seg), "emph") + 10
                + (st and (UI:TextWidth(st, "body") + 8) or 0) + (icon and 17 or 0) + 34 + 8
            need = max(need, w)
        end
    end
    local width = min(FLIST_MAX_W, math.ceil(need)) + FLIST_PAD * 2
    local inner = width - FLIST_PAD * 2
    local y, n = 0, 0
    local function Row()
        n = n + 1
        local r = f.rows[n]
        if not r then r = NewListRow(f); f.rows[n] = r end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f.canvas, "TOPLEFT", 0, -y)
        r:SetWidth(inner)
        r.sel_key = nil
        r:EnableMouse(true)
        r.hl:SetShown(true)
        r:SetSelected(false)
        r.pic:Hide()
        for _, t in ipairs(r.bars) do t:Hide() end
        for _, d in ipairs(r.dots) do d:Hide() end
        r.name:SetText(""); r.small:SetText(""); r.len:SetText(""); r.status:SetText("")
        r.stIcon:Hide()
        r.seg = nil
        r.name:SetTextColor(S:Color("TEXT"))
        r.line:Hide()
        r.head:Hide()
        r:Show()
        return r
    end
    -- the right side: [icon] [text] length
    local function Right(r, seg, st, stc, icon)
        r.len:ClearAllPoints()
        r.len:SetPoint("RIGHT", r, "RIGHT", -8, 0)
        r.len:SetText(K.Clock(Meter:Duration(seg)))
        r.status:ClearAllPoints()
        r.status:SetPoint("RIGHT", r.len, "LEFT", -8, 0)
        r.status:SetText(st or "")
        if stc then r.status:SetTextColor(stc[1], stc[2], stc[3]) end
        if icon then
            r.stIcon:ClearAllPoints()
            if st then r.stIcon:SetPoint("RIGHT", r.status, "LEFT", -3, 0)
            else r.stIcon:SetPoint("RIGHT", r.len, "LEFT", -8, 0) end
            if icon == "kill" then
                r.stIcon:SetTexture(KILL_TEX)
                r.stIcon:SetTexCoord(0, 1, 0, 1)
                r.stIcon:SetVertexColor(1, 1, 1, 1)
            else
                r.stIcon:SetTexture(K.SKULL)
                r.stIcon:SetTexCoord(0, 1, 0, 1)
                r.stIcon:SetVertexColor(1, 1, 1, 1)
            end
            r.stIcon:Show()
        end
    end
    for _, ln in ipairs(lines) do
        if ln.kind == "sep" then
            local r = Row()
            r:SetHeight(9)
            r:EnableMouse(false)
            r.line:ClearAllPoints()
            r.line:SetPoint("LEFT", r, "LEFT", 2, 0)
            r.line:SetPoint("RIGHT", r, "RIGHT", -2, 0)
            r.line:SetHeight(1)
            r.line:Show()
            y = y + 9
        elseif ln.kind == "zone" then
            local r = Row()
            r:SetHeight(FLIST_ZONE)
            r:EnableMouse(false)
            r.head:SetTitle(ln.text)
            r.head:Show()
            y = y + FLIST_ZONE
        elseif ln.kind == "whole" or ln.kind == "boss" then
            local r = Row()
            r:SetHeight(FLIST_ROW)
            local seg = ln.seg
            local key = ln.kind == "whole" and "all" or ln.key
            r.sel_key = key
            local on = key == selKey
            r:SetSelected(on)
            r.name:ClearAllPoints()
            r.name:SetPoint("LEFT", r, "LEFT", FLIST_TX, 0)
            r.name:SetText(Meter:SegName(seg))
            if on then r.name:SetTextColor(S:Color("GOLD")) end
            if ln.kind == "whole" then
                for i, t in ipairs(r.bars) do
                    t:ClearAllPoints()
                    t:SetPoint("BOTTOMLEFT", r, "LEFT", FLIST_IX + 8 + (i - 1) * 5, -6)
                    t:Show()
                end
                local since = ListTime(seg)
                Right(r, seg)
                if since then
                    r.small:ClearAllPoints()
                    r.small:SetPoint("LEFT", r.name, "RIGHT", 6, 0)
                    r.small:SetText("since " .. since)
                    if FLIST_TX + r.name:GetStringWidth() + 6 + r.small:GetStringWidth() + 8 + 42 > inner then r.small:SetText("") end
                end
            else
                local fid = BossArt(seg)
                r.pic:ClearAllPoints()
                r.pic:SetPoint("LEFT", r, "LEFT", FLIST_IX, 0)
                if fid then
                    r.pic:SetTexture(fid)
                    r.pic:SetTexCoord(0, 1, 0.06, 0.94)
                    r.pic:SetSize(28, 14)
                    r.pic:SetVertexColor(1, 1, 1, 1)
                else
                    r.pic:SetTexture(SWORDS_TEX)
                    r.pic:SetTexCoord(SWORDS_TC[1], SWORDS_TC[2], SWORDS_TC[3], SWORDS_TC[4])
                    r.pic:SetSize(16, 16)
                    r.pic:SetVertexColor(1, 0.71, 0.27, 0.9)
                end
                r.pic:Show()
                r.seg = seg
                Right(r, seg, status(seg))
            end
            y = y + FLIST_ROW
        elseif ln.kind == "trash" then
            local r = Row()
            r:EnableMouse(false)
            r.hl:SetShown(false)
            local avail = inner - FLIST_TX - 50
            local per = max(1, floor((avail + FLIST_GAP) / (FLIST_DOT + FLIST_GAP)))
            local nLines = math.ceil(#ln.pulls / per)
            local h = max(FLIST_ROW, nLines * (FLIST_DOT + FLIST_GAP) - FLIST_GAP + 10)
            r:SetHeight(h)
            r.pic:ClearAllPoints()
            r.pic:SetPoint("TOPLEFT", r, "TOPLEFT", FLIST_IX + 7, -floor((FLIST_ROW - 14) / 2))
            r.pic:SetTexture(SWORDS_TEX)
            r.pic:SetTexCoord(SWORDS_TC[1], SWORDS_TC[2], SWORDS_TC[3], SWORDS_TC[4])
            r.pic:SetSize(16, 16)
            r.pic:SetVertexColor(1, 1, 1, 0.5)
            r.pic:Show()
            local total = 0
            for i, pull in ipairs(ln.pulls) do
                local d = r.dots[i]
                if not d then d = NewDot(r); r.dots[i] = d end
                local col, row = (i - 1) % per, floor((i - 1) / per)
                d:ClearAllPoints()
                d:SetPoint("TOPLEFT", r, "TOPLEFT", FLIST_TX + col * (FLIST_DOT + FLIST_GAP), -5 - row * (FLIST_DOT + FLIST_GAP))
                d.seg, d.sel_key = pull.seg, pull.key
                d.on = pull.key == selKey
                PaintDot(d, false)
                d:Show()
                total = total + Meter:Duration(pull.seg)
            end
            r.len:ClearAllPoints()
            r.len:SetPoint("TOPRIGHT", r, "TOPRIGHT", -8, -6)
            r.len:SetText(K.Clock(total))
            y = y + h
        end
    end
    f.contentH = y
    f.viewH = min(y, FLIST_MAX_H)
    f.offset = 0
    f:SetSize(width, f.viewH + FLIST_PAD * 2)
    f.canvas:SetSize(inner, max(1, y))
    MP:PlaceList()
end

-- The fight line's name: the list under it (over it when the panel is low on the screen); a second click closes it.
function MP:FightMenu(pf, owner)
    local f = ListFrame()
    if f:IsShown() and f.owner == owner then f:Hide() return end
    ns.UI:CloseMenus()
    GameTooltip:Hide()
    f.pf, f.owner = pf, owner
    f:SetScale((owner:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1))
    FillList(f, pf)
    f:ClearAllPoints()
    local bottom = (owner:GetBottom() or 0) * owner:GetEffectiveScale() / f:GetEffectiveScale()
    if bottom - f:GetHeight() - 2 < 0 then
        f:SetPoint("BOTTOM", owner, "TOP", 0, 2)
    else
        f:SetPoint("TOP", owner, "BOTTOM", 0, -2)
    end
    f:Show()
end
MP._FightList = function() return flist end

-- + : a new panel beside this stack.
function MP:SpawnMenu(pf, owner)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateTitle("New panel")
        for i, v in ipairs(VIEWS) do
            if (i == 3 or i == 5 or i == 6 or i == 9) then root:CreateDivider() end
            root:CreateButton(ViewText(v), function() MP:Spawn(pf, v) end)
        end
    end)
end

function MP:Spawn(pf, v)
    local L = Layout()
    local s = pf and pf.layout and L.stacks[pf.si]
    local hw = HolderSize()
    local w = s and s.w or DEFAULT_W
    local x, y, bt
    if s then
        x = (s.x > hw / 2) and (s.x - w - 12) or (s.x + w + 12)
        y, bt = s.y, s.b
    end
    L.stacks[#L.stacks + 1] = { x = x, y = y, b = bt, w = w, panels = { NewPanelData(v) } }
    if IsThreat(v) and not Threat:IsEnabled() then Set("thr", true) end
    if not IsThreat(v) and not Meter:IsEnabled() then Set("dmg", true) end
    self:Rebuild()
end

-- x : closes the shown tab (with others left) or the panel.
function MP:Close(pf)
    local L = Layout()
    local s = L.stacks[pf.si]
    local p = pf.layout
    if not s or not p then return end
    local shown = ShownTab(p)
    if #p.tabs > 1 and shown then
        tremove(p.tabs, shown)
        p.active = min(p.active or 1, #p.tabs)
    else
        local pi = IndexOf(s.panels, p)
        if pi then tremove(s.panels, pi) end
        if #s.panels == 0 then tremove(L.stacks, pf.si) end
    end
    GameTooltip:Hide(); HideRowTip()
    self:Rebuild()
end

-- Right-click on a header: the panel menu.
function MP:PanelMenu(pf, owner)
    ns.UI:ContextMenu(owner, function(root)
        root:CreateButton(Locked() and "Move, dock and resize (Edit layout)" or "Done editing the layout",
            function() if ns.EditMode then ns.EditMode:Toggle() end end)
        root:CreateCheckbox("Fade out of combat", function() return Setting("ooc", "fade") == "fade" end,
            function() Set("ooc", Setting("ooc", "fade") == "fade" and "stay" or "fade") end)
        root:CreateDivider()
        local new = root:CreateButton(ns.UI:AtlasIconText(ns.UI.ICON.plus, 14) .. " New panel")
        for i, v in ipairs(VIEWS) do
            if (i == 3 or i == 5 or i == 6 or i == 9) then new:CreateDivider() end
            new:CreateButton(ViewText(v), function() MP:Spawn(pf, v) end)
        end
        root:CreateButton(ns.UI:AtlasIconText(ns.UI.ICON.gear, 14) .. " Settings", ns.MeterWindow.OpenSettings)
        local clear = root:CreateButton(S:Hex("BAD") .. UI:AtlasIconText(UI.ICON.trash, 14, S.C.BAD) .. " Clear all fights|r")
        clear:CreateButton(S:Wrap("BAD", "Yes, clear every fight"), function() Meter:ClearAll() end)
        local reset = root:CreateButton("Reset layout")
        reset:CreateButton("Yes, one stack again", function() MP:ResetLayout() end)
        root:CreateDivider()
        local s = pf.layout and Layout().stacks[pf.si or 0]
        if s and s.g then
            root:CreateButton("Undock from the row", function()
                s.g = nil
                s.x = s.x + 24
                MP:Rebuild()
            end)
        end
        root:CreateButton("Close this panel", function() MP:Close(pf) end)
        root:CreateButton("Hide all until /dz meter", function() userHidden = true; MP:UpdateVisibility() end)
    end)
end

---------------------------------------------------------------------------
-- Showing, fading, the warning
---------------------------------------------------------------------------

local function InCombat()
    return (Meter and Meter:GetLive() ~= nil) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
end

local function ShowWanted()
    if not Meter:IsEnabled() and not Threat:IsEnabled() then return false end
    if userHidden then return false end
    if not Locked() or Meter:IsDemo() then return true end
    local show = Setting("show", "group")
    if show == "group" and not (IsInGroup and IsInGroup()) and not Meter:GetLive() then return false end
    if show == "instance" and not (IsInInstance and IsInInstance()) then return false end
    if Setting("ooc", "fade") == "hide" and not InCombat() then return false end
    return true
end

function MP:UpdateVisibility()
    local want = ShowWanted()
    if want and not holder then self:Build() end
    if not holder then return end
    if want then
        if not holder:IsShown() then
            alpha = 1
            holder:SetAlpha(1)
            holder:Show()
            self:Rebuild()
        end
    else
        holder:Hide()
        if flash then flash:Hide() end
    end
end

local function OnUpdate(_, elapsed)
    if drag then UpdateDrag() end
    if resize then UpdateResize() end
    local now = GetTime()
    if InCombat() then combatEndedAt = now end
    local hovered = false
    for _, f in ipairs(stackFrames) do if f:IsShown() and f:IsMouseOver() then hovered = true end end
    local want = 1
    if not InCombat() and Setting("ooc", "fade") == "fade" and Locked() and now - combatEndedAt > FADE_AFTER
        and not hovered and not ns.UI:GetOpenMenu() and not drag then
        want = FADED
    end
    if abs(alpha - want) > 0.005 then
        alpha = alpha + (want - alpha) * (1 - exp(-elapsed / 0.25))
        holder:SetAlpha(alpha)
    end
    -- the warning: the stack's edge pulses, the screen edges flash
    local pulse = 0.5 + 0.5 * sin(now * 5.7)
    local anyHot = false
    local locked = Locked()
    for _, f in ipairs(stackFrames) do
        if f:IsShown() then
            if f.warn then
                anyHot = true
                f:SetEdge(HOT_C[1], 0.36 + 0.07 * pulse, 0.3, 0.55 + 0.45 * pulse)
            elseif M then
                ns.MeterTheme:StackEdge(f, M, locked)          -- (the theme's edge; gold while unlocked)
            end
            f.hint:SetShown(not locked and f:IsMouseOver() and not drag)
        end
    end
    local flashOn = anyHot and Setting("flash", true)
    flash:SetShown(flashOn and true or false)
    if flashOn then flash.tex:SetAlpha(0.15 + 0.4 * pulse) end
    -- redraw at most 4 times a second while numbers change
    if (dirty or (Meter:GetLive() and now - lastDraw > 0.25)) and now - lastDraw > 0.1 then MP:Draw() end
    Animate(elapsed)
end

-- The stacks' frames (Edit layout outlines them and lines other frames up with them).
function MP:StackFrames() return stackFrames end

-- Edit layout opened / closed: unlocked and over its overlay while it is open (the docking needs the mouse).
function MP:OnEditLayout(on)
    if not holder then
        if on then self:UpdateVisibility() end
        if not holder then return end
    end
    holder:SetFrameStrata(on and "FULLSCREEN" or "MEDIUM")
    holder:SetFrameLevel(on and 5 or 1)
    for _, f in ipairs(stackFrames) do f:SetFrameLevel(holder:GetFrameLevel() + 1) end
    self:ApplyLook()
    self:UpdateVisibility()
end

function MP:Build()
    if holder then return end
    holder = CreateFrame("Frame", "DisasterZoneMeters", UIParent)
    holder:SetAllPoints(UIParent)
    holder:SetFrameStrata("MEDIUM")
    holder:SetScale(SCALES[Setting("size", "normal")] or 1)
    -- where a dragged stack would dock: a gold line, and the stack it joins in the picked look (wash + focus edge)
    guide = CreateFrame("Frame", nil, holder)
    guide:SetFrameLevel(holder:GetFrameLevel() + 100)
    guide.tex = UI:Fill(guide, "GOLD", "OVERLAY")
    guide:Hide()
    outline = CreateFrame("Frame", nil, holder)
    outline:SetFrameLevel(holder:GetFrameLevel() + 99)
    outline.fill = UI:Fill(outline, "SELECT", "BACKGROUND")
    UI:AddEdges(outline, "OVERLAY")
    UI:SetEdgeColor(outline, S:Color("EDGE_FOCUS"))
    outline:Hide()
    flash = CreateFrame("Frame", nil, UIParent)
    flash:SetAllPoints(UIParent)
    flash:SetFrameStrata("BACKGROUND")
    flash.tex = flash:CreateTexture(nil, "BACKGROUND")
    flash.tex:SetAllPoints()
    flash.tex:SetTexture(LOW_HEALTH)
    flash.tex:SetBlendMode("ADD")
    flash.tex:SetVertexColor(1, 0.25, 0.15)
    flash:Hide()
    holder:SetScript("OnUpdate", OnUpdate)
    holder:Hide()
end

function MP:Toggle()
    if holder and holder:IsShown() then
        userHidden = true
        self:UpdateVisibility()
        return
    end
    userHidden = false
    if not Meter:IsEnabled() and not Threat:IsEnabled() then
        ns:Print("the meters are off: turn them on in Settings > Combat (or /dz meter on).")
        return
    end
    self:EnsureViews()
    if not holder then self:Build() end
    holder:Show()
    self:Rebuild()
end

function MP:Refresh()
    dirty = true
    self:UpdateVisibility()
    if holder and holder:IsShown() then self:Rebuild() end
end

function MP:OnLogin()
    Meter, Threat = ns.Meter, ns.Threat
    self:EnsureViews()
    ns.Layout:Register("meters", { name = "Meters", group = "Raid", order = 10, kind = "meters", noHide = true,
        mine = function() return (Meter:IsEnabled() or Threat:IsEnabled()) and true or false end })
    ns:On("EDIT_LAYOUT", function(on) MP:OnEditLayout(on) end)
    Meter:OnChange(function(what)
        if what == "start" then
            -- a new fight: tabs on an older fight go back to the current one
            for _, s in ipairs(Layout().stacks) do
                for _, p in ipairs(s.panels) do
                    for _, t in ipairs(p.tabs) do if t.seg ~= "all" then t.seg = "cur" end end
                end
            end
            for _, pf in ipairs(allPanels) do pf.offset = 0 end
            combatEndedAt = GetTime()
            MP:UpdateVisibility()
        elseif what == "end" then
            combatEndedAt = GetTime()
            MP:UpdateVisibility()
        end
        dirty = true
    end)
    Threat:OnChange(function() dirty = true end)
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) ~= "string" or path:sub(1, 7) ~= "meters." or path == "meters.layout" then return end
        if (path == "meters.dmg" and Meter:IsEnabled()) or (path == "meters.thr" and Threat:IsEnabled()) then
            userHidden = false
            MP:EnsureViews()
        end
        MP:Refresh()
    end)
    ns:On("DEMO_TOGGLED", function() if ns.MeterDemo then ns.MeterDemo:Reset() end MP:Refresh() end)
    for _, ev in ipairs({ "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED" }) do
        ns:RegisterEvent(ev, function() MP:UpdateVisibility() end)
    end
    -- the left button let go anywhere: a drag or a resize ends (a hidden tab never gets its OnDragStop)
    ns:RegisterEvent("GLOBAL_MOUSE_UP", function(_, button)
        if button and button ~= "LeftButton" then return end
        if drag then MP:EndDrag() end
        if resize then MP:EndResize() end
    end)
    self:UpdateVisibility()
end

-- Test hooks
MP._Stacks = function() return stackFrames end
MP._Panels = function() return allPanels end
MP._Holder = function() return holder end
-- the first shown panel showing view v
MP._Panel = function(v)
    for _, f in ipairs(stackFrames) do
        if f:IsShown() then
            for _, pf in ipairs(f.panels) do if MP:TabOf(pf).view == v then return pf end end
        end
    end
end
MP._Target = function() return drag and drag.target end
MP._Dragging = function() return drag ~= nil end
MP._DragRow = function() return drag and #(drag.members or {}) or 0 end
MP._UpdateDrag = function() if drag then UpdateDrag() end end
MP._SetTarget = function(t) if drag then drag.target = t end end

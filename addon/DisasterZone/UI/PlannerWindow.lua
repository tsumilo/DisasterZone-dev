if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PlannerWindow.lua", ...) then return end -- DisasterZone UI/PlannerWindow.lua
-- the class planner window shared by Blessings and Totems (refactor phase 4).
local addonName, ns = ...

-- The class planners' window (UI/BlessingsUI.lua, UI/TotemsUI.lua) on the Tool window layout (UI:CreateLayout("tool")):
-- the window, a tool banner (the raid's art, the planner's name, who assigns as its kicker, where and how many as its
-- sub line, the main action Auto-assign and the planner's icon actions), then the body each planner fills with its
-- grid. Shared here too: the player card, the grid cell, the swap chip (what one player gets instead: was -> now),
-- the caps rule with its "+", the drag ghost, the tooltips, the refresh while open, Open / Close / Toggle.
--
--   local win = ns.PlannerWindow:Install(uiModule, def)
--     def { name, title, width, core = function() -> the planner module (Core/ClassPlanner.lua), event (refresh on),
--           every (seconds between live refreshes while open), autoTip, actions = { the banner's icon actions after
--           Auto-assign ... }, empty = { title, text, icon }, build = function(frame, body) }
--   uiModule gets Open / Close / Toggle / IsShown / GetFrame; its own Refresh() fills the window.
--   frame.layout, .banner, .body, .empty (an empty state in the body, placed by the planner)
--   PW:Head(frame, core, sub, art)    the banner's kicker (who assigns), sub line, art; Auto-assign / Report enabled
--   PW:Fit(frame, bodyH)              the window's height for a body that tall
--   PW.Tip(frame, fn)                 fn(frame) -> title, lines: the tooltip (nil title: none)
--   PW.NewCard(parent, o) / PW.NewCell(parent, w, h) / PW.NewSwapChip(parent, w, h) / PW.NewRule(parent, title, w)
--   PW.NewDrag(frame, size)           the dragged icon and its gold mark over a target
local PW = {}
ns.PlannerWindow = PW

local UI = ns.UI
local S = ns.Style
local C = S.C
local GOLD = C.GOLD

local floor = math.floor
local type, ipairs, tostring = type, ipairs, tostring

PW.CELL_BG = { 0.1, 0.1, 0.118, 1 }
PW.CELL_EDGE = { 0.15, 0.15, 0.17, 1 }
PW.CARD_EDGE = { 0.17, 0.17, 0.19, 1 }
PW.CHIP_BG = { 0.11, 0.11, 0.13, 1 }
PW.HINT = { 0.6, 0.6, 0.6 }              -- the tooltips' "Click: ..." line
PW.CROP = { 0.07, 0.93, 0.07, 0.93 }     -- an icon's border trimmed

local function Crop(tex) tex:SetTexCoord(PW.CROP[1], PW.CROP[2], PW.CROP[3], PW.CROP[4]) end
PW.Crop = Crop

local function SetEdge(f, c, a)
    if not f.edges then UI:AddEdges(f) end
    UI:SetEdgeColor(f, c[1], c[2], c[3], a or c[4] or 1)
end
PW.SetEdge = SetEdge

-- An icon inside text, its border trimmed: "|T...|t".
function PW.IconText(tex, size)
    size = size or 16
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(tex), size, size)
end

-- "|cffrrggbb" of r, g, b.
function PW.ColorCode(r, g, b) return "|c" .. UI:ColorHex(r, g, b) end

-- A class's name, plural ("Warriors", "Wolves" stay ...).
function PW.Plural(cls)
    local n = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls]) or cls
    return n:sub(-1) == "f" and n or (n .. "s")
end

-- ---------------------------------------------------------------------------------------------------------------
-- Tooltips: fn(frame) -> title, lines (strings, or { text, r, g, b }); no title: none this time
-- ---------------------------------------------------------------------------------------------------------------
local function TipTitle(f, tt)
    local title, lines = f.pwTip(f)
    if not title then return false end
    tt:AddLine(title, 1, 1, 1)
    for _, l in ipairs(lines or {}) do
        if type(l) == "table" then tt:AddLine(l[1], l[2] or 1, l[3] or 1, l[4] or 1, true)
        else tt:AddLine(l, 0.85, 0.85, 0.85, true) end
    end
end

-- (attach after the frame's own OnEnter / OnLeave are set: UI:AttachTooltip hooks them)
function PW.Tip(frame, fn)
    frame.pwTip = fn
    UI:AttachTooltip(frame, TipTitle, nil)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Parts
-- ---------------------------------------------------------------------------------------------------------------
-- A player's card: o { w, h, from, to (the gradient's colours, left to right), bar (the class colour), name (its
-- colour), lineRight (room kept on the right of the talent line) }. card.bg, .bar, .spec, .name, .crown, .line.
function PW.NewCard(parent, o)
    local card = CreateFrame("Button", nil, parent)
    card:SetSize(o.w, o.h)
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    UI:Gradient(card.bg, "HORIZONTAL", o.from, o.to)
    SetEdge(card, PW.CARD_EDGE)
    card.bar = UI:Fill(card, o.bar, "BORDER")
    card.bar:ClearAllPoints()
    card.bar:SetPoint("TOPLEFT")
    card.bar:SetPoint("BOTTOMLEFT")
    card.bar:SetWidth(2)
    card.spec = card:CreateTexture(nil, "ARTWORK")
    card.spec:SetSize(26, 26)
    card.spec:SetPoint("LEFT", card, "LEFT", 8, 0)
    Crop(card.spec)
    local mid = floor(o.h / 2)
    card.name = UI:Text(card, "emph", o.name, { shadow = true })
    card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -(mid - 17))
    card.crown = card:CreateTexture(nil, "OVERLAY")
    card.crown:SetSize(11, 11)
    card.crown:SetPoint("LEFT", card.name, "RIGHT", 4, 0)
    card.crown:SetTexture(UI.ICON_ATLAS)
    local cc = UI:IconCoords(UI.ICON.crown)
    card.crown:SetTexCoord(cc[1], cc[2], cc[3], cc[4])
    card.crown:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    card.line = UI:Text(card, "small", "SUB", { shadow = true })
    card.line:SetPoint("TOPLEFT", card, "TOPLEFT", 40, -(mid + 2))
    card.line:SetPoint("RIGHT", card, "RIGHT", -(o.lineRight or 6), 0)
    return card
end

-- A grid cell: a dark tile, an icon in its middle (cell.empty when it has none) and a gold count badge on the icon
-- (players missing it). Its edge turns gold under the mouse while it can be changed (cell.canEdit()).
function PW.NewCell(parent, w, h, iconY)
    local cell = CreateFrame("Button", nil, parent)
    cell:SetSize(w, h)
    cell.bg = UI:Fill(cell, PW.CELL_BG, "BACKGROUND")
    SetEdge(cell, PW.CELL_EDGE)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetSize(32, 32)
    cell.icon:SetPoint("CENTER", 0, iconY or 0)
    Crop(cell.icon)
    cell.empty = cell:CreateTexture(nil, "ARTWORK")
    cell.empty:SetSize(26, 26)
    cell.empty:SetPoint("CENTER", 0, iconY or 0)
    cell.empty:SetColorTexture(S:Color("QUIET"))
    cell.miss = UI:CreateCountBadge(cell, 13)
    cell.miss:SetPoint("CENTER", cell.icon, "TOPRIGHT", -1, -1)
    return cell
end

-- The hover edge of a cell (gold while it can be changed) and back.
function PW.HoverEdge(f, on, canEdit)
    if on then
        if canEdit then UI:SetEdgeColor(f, GOLD[1], GOLD[2], GOLD[3], 0.9) end
    else
        local c = f.pwEdge or PW.CELL_EDGE
        UI:SetEdgeColor(f, c[1], c[2], c[3], c[4] or 1)
    end
end

-- A swap chip: a player (or a boss) and who, then what changes: the usual faded, a hairline warming from grey to
-- gold into a gold chevron, and the new one in a thin gold frame. chip.bar (the class / element colour), .name,
-- .sub, .was, .line, .tip (the chevron), .now (.now.icon).
function PW.NewSwapChip(parent, w, h)
    local chip = CreateFrame("Button", nil, parent)
    chip:SetSize(w, h)
    chip.bg = UI:Fill(chip, PW.CHIP_BG, "BACKGROUND")
    SetEdge(chip, PW.CARD_EDGE)
    chip.pwEdge = PW.CARD_EDGE
    chip.bar = chip:CreateTexture(nil, "BORDER")
    chip.bar:SetColorTexture(1, 1, 1, 1)
    chip.bar:SetPoint("TOPLEFT")
    chip.bar:SetPoint("BOTTOMLEFT")
    chip.bar:SetWidth(2)
    chip.name = UI:Text(chip, "body", nil, { shadow = true })
    chip.name:SetPoint("TOPLEFT", chip, "TOPLEFT", 8, -4)
    chip.name:SetPoint("RIGHT", chip, "RIGHT", -63, 0)
    chip.sub = UI:Text(chip, "caps", "SUB", { shadow = true })
    chip.sub:SetPoint("TOPLEFT", chip, "TOPLEFT", 8, -20)
    chip.sub:SetPoint("RIGHT", chip, "RIGHT", -63, 0)
    chip.now = CreateFrame("Frame", nil, chip)
    chip.now:SetSize(18, 18)
    chip.now:SetPoint("RIGHT", chip, "RIGHT", -7, 0)
    SetEdge(chip.now, GOLD, 0.9)
    chip.now.icon = chip.now:CreateTexture(nil, "ARTWORK")
    chip.now.icon:SetPoint("TOPLEFT", 1, -1)
    chip.now.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    Crop(chip.now.icon)
    chip.tip = chip:CreateTexture(nil, "OVERLAY")
    chip.tip:SetSize(9, 9)
    chip.tip:SetPoint("RIGHT", chip.now, "LEFT", -3, 0)
    UI:SetChevron(chip.tip, true)
    chip.tip:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.95)
    chip.was = chip:CreateTexture(nil, "ARTWORK")
    chip.was:SetSize(13, 13)
    chip.was:SetPoint("RIGHT", chip, "RIGHT", -46, 0)
    Crop(chip.was)
    chip.was:SetDesaturated(true)
    chip.was:SetAlpha(0.5)
    chip.line = chip:CreateTexture(nil, "ARTWORK")
    chip.line:SetHeight(1)
    chip.line:SetPoint("LEFT", chip.was, "RIGHT", 3, 0)
    chip.line:SetPoint("RIGHT", chip.tip, "LEFT", 3, 0)
    UI:Gradient(chip.line, "HORIZONTAL", { 0.55, 0.55, 0.58, 0.35 }, { GOLD[1], GOLD[2], GOLD[3], 0.95 })
    chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    return chip
end

-- What the chip shows: was (icon or nil: no swap line), now (icon), the bar's colour, name (and its colour), sub.
function PW.FillSwapChip(chip, was, now, rgb, name, nameRGB, sub)
    chip.bar:SetVertexColor(rgb[1], rgb[2], rgb[3], 1)
    chip.name:SetText(name)
    if nameRGB then chip.name:SetTextColor(nameRGB[1], nameRGB[2], nameRGB[3]) end
    chip.sub:SetText(sub)
    chip.was:SetShown(was ~= nil)
    chip.line:SetShown(was ~= nil)
    chip.tip:SetShown(was ~= nil)
    if was then chip.was:SetTexture(was) end
    chip.now.icon:SetTexture(now)
end

-- The caps rule over the chips ("EXCEPTIONS 12 ---- +"): UI:CreateSectionHeader, its "+" an icon action.
-- rule:SetAdd(action or nil) shows or hides the "+" (rule.add: its button while shown).
function PW.NewRule(parent, title, w)
    local h = UI:CreateSectionHeader(parent, title, { style = "caps", width = w })
    function h:SetAdd(a)
        if a == self.addAction then return end
        self.addAction = a
        self:SetAction(a)
        self.add = a and self.action or nil
    end
    return h
end

-- The dragged icon (it follows the cursor) and a gold mark over the target under it.
-- drag:Begin(icon, payload, target) (target() -> frame or nil, each frame), drag:Finish() -> target, payload.
function PW.NewDrag(win, size)
    local d = CreateFrame("Frame", nil, UIParent)
    d:SetSize(size, size)
    d:SetFrameStrata("TOOLTIP")
    d.icon = d:CreateTexture(nil, "ARTWORK")
    d.icon:SetAllPoints()
    Crop(d.icon)
    d.mark = CreateFrame("Frame", nil, win)
    d.mark:SetFrameStrata("DIALOG")
    SetEdge(d.mark, GOLD, 1)
    d.mark.fill = UI:Fill(d.mark, { GOLD[1], GOLD[2], GOLD[3], 0.08 }, "BACKGROUND")
    d.mark:EnableMouse(false)
    d:Hide()
    local function Follow(self)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self:ClearAllPoints()
        self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / s, y / s)
        local t = self.target and self.target()
        if t then
            self.mark:ClearAllPoints()
            self.mark:SetAllPoints(t)
            self.mark:Show()
        else
            self.mark:Hide()
        end
    end
    function d:Begin(icon, payload, target)
        self.payload, self.target = payload, target
        self.icon:SetTexture(icon)
        self:Show()
        self:SetScript("OnUpdate", Follow)
    end
    function d:Finish()
        if not self:IsShown() then return nil end
        local t = self.target and self.target()
        self:Hide()
        self:SetScript("OnUpdate", nil)
        self.mark:Hide()
        return t, self.payload
    end
    return d
end

-- ---------------------------------------------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------------------------------------------
-- Who assigns, the banner's kicker: "DEMO MODE · YOU ASSIGN", "SOLO", "YOU ASSIGN", "CAELITH ASSIGNS".
function PW.Who(core)
    if core:IsDemo() then return "Demo mode · you assign" end
    if not IsInGroup() then return "Solo" end
    if core:AmLeader() or ns.Util.IsPlayerLeaderOrAssist() then return "You assign" end
    local lead = core:LeaderName()
    return lead and (lead .. " assigns") or ""
end

-- The banner for now: who (kicker), sub, art; Auto-assign while I may change anyone (and autoOk), Report in a group.
function PW:Head(frame, core, sub, art, autoOk)
    local bn = frame.banner
    if bn.pwArt ~= art then
        bn.pwArt = art
        bn:SetArt(art)
    end
    bn:SetKicker(PW.Who(core))
    bn:SetSub(sub)
    if frame.auto then frame.auto:SetEnabled(core:CanEditAny() and autoOk ~= false) end
    if frame.report then frame.report:SetEnabled(core:InGroup()) end
end

-- The window's height for a body bodyH tall (the content's top margin, the banner and its gap above it).
function PW:Fit(frame, bodyH)
    local top = S.PAD + floor(frame.banner:GetHeight() + 0.5) + S.GAP
    frame:SetHeight(top + bodyH + S.PAD + UI.WIN_HEAD + 8)
end

function PW:Install(ui, def)
    local frame
    local function Build()
        frame = UI:CreateWindow(def.name, def.title, def.width, 420)
        frame:Hide()
        frame:SetScript("OnShow", function() ui:Refresh() end)
        local actions = { { text = "Auto-assign", kind = "primary", width = 100,
            onClick = function() local c = def.core(); if c:CanEditAny() then c:AutoAssign() end end,
            tip = { "Auto-assign", def.autoTip } } }
        for _, a in ipairs(def.actions or {}) do actions[#actions + 1] = a end
        frame.layout = UI:CreateLayout("tool", frame.content, { width = def.width - 10, banner = { title = def.title,
            artFw = 0.62, artTint = 0.62, actions = actions } })
        frame.banner, frame.body = frame.layout.banner, frame.layout.body
        for i, a in ipairs(actions) do
            local b = frame.banner.actions[i]
            if a.key then frame[a.key] = b end
        end
        frame.auto = frame.banner.actions[1]
        if def.empty then
            frame.empty = UI:CreateEmptyState(frame.body, { compact = true, icon = def.empty.icon,
                title = def.empty.title, text = def.empty.text })
            frame.empty:Hide()
        end
        def.build(frame, frame.body)
        -- live timers: refresh while open
        local acc = 0
        frame:SetScript("OnUpdate", function(_, elapsed)
            acc = acc + (elapsed or 0)
            if acc >= def.every then
                acc = 0
                ui:Refresh()
            end
        end)
        ns:On(def.event, function() if frame:IsShown() then ui:Refresh() end end)
        ns:On("GROUP_UPDATED", function() if frame:IsShown() then ui:Refresh() end end)
    end

    function ui:Open()
        if not frame then Build() end
        frame:Show()
        self:Refresh()
        local core = def.core()
        if core and IsInGroup() then core.Hello() end
    end
    function ui:Close() if frame then frame:Hide() end end
    function ui:Toggle()
        if frame and frame:IsShown() then self:Close() else self:Open() end
    end
    function ui:IsShown() return frame and frame:IsShown() or false end
    function ui:GetFrame() return frame end
    return ui
end

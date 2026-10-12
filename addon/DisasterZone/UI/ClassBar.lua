if DisasterZoneBoot and DisasterZoneBoot.Run("UI/ClassBar.lua", ...) then return end -- DisasterZone UI/ClassBar.lua
-- the class tool bar shared by the Blessings and Totem bars (refactor phase 4).
local addonName, ns = ...

-- A class tool bar (UI/BlessingsBar.lua, UI/TotemBar.lua): an in-raid strip of secure buttons whose looks are the
-- theme's faces (UI/BarFace.lua). Both bars share their frame and its chrome (no panel; a faint glass one while
-- unlocked, to drag it by), the two layouts (Rail, a column; Strip, a row) with a saved place per layout, the header
-- cells, the players / party popout's frame, and the common rows of their Settings card. Each bar keeps what it shows
-- and casts.
--
--   local cb = ns.ClassBar:New(opts)
--     opts { name = the frame's global name, setting = "bless" (settings prefix), railPos = { point, x, y },
--            stripPos = { point, x, y } (the default places) }
--   cb:Build() -> frame       the bar's frame (cb.frame): chrome, dragging (unlocked, out of combat) saves its place
--   cb:Layout()               "vertical" | "horizontal" (setting <prefix>.layout)
--   cb:SavePos() / cb:RestorePos() / cb:ApplyChrome()
--   cb:Secure(parent, name)   a secure button that hears press and release
--   cb:HeaderIcon(name, unit) a secure header cell with a face (aura, Heroism ...)
--   cb:Place(head, cells)     head: header cells (the shown ones lead), cells: the rest, on the theme's axis
--   cb:NewPop(name, width)    the popout's frame: glass, edge, .title, .hint, .rows
--   cb:OnSettings(update)     SETTINGS_CHANGED for <prefix>.* and classbar.theme (not .pos); .locked re-places
--   ns.ClassBar.Text(parent, size, color)   the bars' small shadowed text (UI:Text)
--   ns.ClassBar.SettingsHead(S, sec, prefix, label, desc) / SettingsTail(S, sec, prefix)   the Settings card's rows
local CB = {}
ns.ClassBar = CB

local UI = ns.UI
local LINE = ns.Style.C.HAIRLINE          -- (the glass's faint white edges)

local floor = math.floor
local type, pairs, ipairs, tonumber = type, pairs, ipairs, tonumber

local SOFT = "Interface\\AddOns\\DisasterZone\\Media\\SoftGlow"
CB.GLASS = { 0.047, 0.047, 0.059, 0.78 }
CB.POP_BG = { 0.047, 0.047, 0.059, 0.94 }
CB.POP_TITLE = { 0.6, 0.6, 0.65 }
CB.POP_HINT = { 0.47, 0.47, 0.51 }
CB.LAYOUTS = { { value = "vertical", text = "Rail (vertical)" }, { value = "horizontal", text = "Strip (horizontal)" } }

local function Face() return ns.BarFace end

-- The bars' small text: one line, the game's 1 px shadow.
function CB.Text(parent, size, color)
    return UI:Text(parent, size, color, { shadow = true })
end

local Bar = {}

function CB:New(opts)
    local b = { opts = opts, setting = opts.setting }
    for k, fn in pairs(Bar) do b[k] = fn end
    return b
end

function Bar:Get(key, default)
    local v = ns.DB and ns.DB:GetSetting(self.setting .. "." .. key)
    if v == nil then return default end
    return v
end

function Bar:Layout()
    return self:Get("layout", "vertical") == "horizontal" and "horizontal" or "vertical"
end

-- (a place per layout: the rail at the side, the strip over the action bars)
function Bar:SavePos()
    local point, _, rel, x, y = self.frame:GetPoint(1)
    if not point then return end
    local pos = self:Get("pos")
    pos = (type(pos) == "table" and not pos[1]) and pos or {}
    local copy = {}
    for k, v in pairs(pos) do copy[k] = v end
    copy[self:Layout()] = { point, rel, floor(x + 0.5), floor(y + 0.5) }
    ns.DB:SetSetting(self.setting .. ".pos", copy)
end

function Bar:RestorePos()
    local frame = self.frame
    frame:ClearAllPoints()
    local pos = self:Get("pos")
    local p = type(pos) == "table" and pos[self:Layout()]
    local d = self:Layout() == "horizontal" and self.opts.stripPos or self.opts.railPos
    if type(p) == "table" and p[1] then
        frame:SetPoint(p[1], UIParent, p[2] or p[1], p[3] or 0, p[4] or 0)
    else
        frame:SetPoint(d[1], UIParent, d[1], d[2], d[3])
    end
end

-- No panel: the faces float on the world. While unlocked a faint panel shows what to drag.
function Bar:ApplyChrome()
    local frame = self.frame
    local unlocked = not self:Get("locked", true)
    frame.bg:SetShown(unlocked)
    frame.shadow:SetShown(unlocked)
    for _, e in ipairs(frame.edges or {}) do e:SetShown(unlocked) end
    frame:EnableMouse(unlocked)
end

-- A secure button that casts on a click. It takes the press and the release: with "cast on key down" on (the
-- client's default) the secure template acts on the press only and ignores a button that hears only releases.
function Bar:Secure(parent, name)
    local b = CreateFrame("Button", name, parent, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    return b
end

-- A header cell (an aura, Heroism ...): secure, the same face as the rest.
function Bar:HeaderIcon(name, unit)
    local b = self:Secure(self.frame, name)
    b:SetSize(34, 34)
    b.face = Face():New(b)
    b:HookScript("OnEnter", function(f) Face():Hover(f.face, true) end)
    b:HookScript("OnLeave", function(f) Face():Hover(f.face, false) end)
    b:SetAttribute("type", "spell")
    if unit then b:SetAttribute("unit", unit) end
    return b
end

function Bar:Build()
    local frame = CreateFrame("Frame", self.opts.name, UIParent)
    self.frame = frame
    frame:SetSize(50, 100)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame.bg = UI:Fill(frame, CB.GLASS, "BACKGROUND")
    UI:AddEdges(frame)
    UI:SetEdgeColor(frame, LINE[1], LINE[2], LINE[3], 0.08)
    frame.shadow = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    frame.shadow:SetTexture(SOFT)
    frame.shadow:SetVertexColor(0, 0, 0, 0.55)
    frame.shadow:SetPoint("TOPLEFT", -14, 10)
    frame.shadow:SetPoint("BOTTOMRIGHT", 14, -18)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    local bar = self
    frame:SetScript("OnDragStart", function(f)
        if not bar:Get("locked", true) and not InCombatLockdown() then f:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(f)
        f:StopMovingOrSizing()
        bar:SavePos()
    end)
    return frame
end

-- The cells in order: the header cells that are shown, then the rest, on the theme's axis.
function Bar:Place(head, rest, axis, theme)
    local cells = {}
    for _, b in ipairs(head) do
        if b:IsShown() then cells[#cells + 1] = b end
    end
    local nHead = #cells
    for _, b in ipairs(rest) do cells[#cells + 1] = b end
    Face():Place(self.frame, cells, nHead, axis, theme)
end

-- The popout next to a cell (players of a class, a totem's party): glass, a faint edge, a caps title and a hint.
function Bar:NewPop(name, width)
    local pop = CreateFrame("Frame", name, UIParent)
    pop:SetSize(width, 40)
    pop:SetFrameStrata("DIALOG")
    pop.bg = UI:Fill(pop, CB.POP_BG, "BACKGROUND")
    UI:AddEdges(pop)
    UI:SetEdgeColor(pop, LINE[1], LINE[2], LINE[3], 0.09)
    pop.title = CB.Text(pop, 8.5, CB.POP_TITLE)
    pop.title:SetPoint("TOPLEFT", pop, "TOPLEFT", 12, -9)
    pop.hint = CB.Text(pop, 8.5, CB.POP_HINT)
    pop.rows = {}
    pop:Hide()
    self.pop = pop
    return pop
end

-- Settings: the bar's own (not its saved place) and the account's theme update it; unlocking puts it back in place.
function Bar:OnSettings(update)
    local prefix = "^" .. self.setting
    local pos, locked = self.setting .. ".pos", self.setting .. ".locked"
    local bar = self
    ns:On("SETTINGS_CHANGED", function(path)
        if type(path) == "string" and (path:find(prefix) or path == "classbar.theme") and path ~= pos then
            if bar.frame and path == locked and not InCombatLockdown() then bar:RestorePos() end
            update()
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The Settings card's common rows (Settings > Class tools)
-- ---------------------------------------------------------------------------------------------------------------
-- When the bar shows, its layout and the account's theme.
function CB.SettingsHead(S, sec, prefix, label, desc)
    S:DropdownSetting(sec, label, desc, prefix .. ".bar", "group", { { value = "group", text = "Party and raid" },
        { value = "raid", text = "Raids only" }, { value = "always", text = "Always" }, { value = "off", text = "Off" } })
    S:DropdownSetting(sec, "Bar layout", "A column at the side or a row over your action bars: the same cells.",
        prefix .. ".layout", "vertical", CB.LAYOUTS)
    if ns.BarFace then ns.BarFace:SettingsRow(S, sec) end
end

-- Locked and size, and the card's end.
function CB.SettingsTail(S, sec, prefix)
    S:SwitchSetting(sec, "Locked", "Unlock to drag the bar where you want it.", prefix .. ".locked", true)
    local scales = {}
    for _, n in ipairs({ 0.8, 0.9, 1, 1.15, 1.3 }) do scales[#scales + 1] = { value = n, text = floor(n * 100) .. "%" } end
    S:DropdownSetting(sec, "Size", "", prefix .. ".scale", 1, scales)
    S:EndSection(sec)
end

-- (the scale setting as a number)
function Bar:Scale() return tonumber(self:Get("scale", 1)) or 1 end

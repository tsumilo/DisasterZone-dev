if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Menu.lua", ...) then return end -- DisasterZone: UI/Menu.lua
-- Every dropdown and right-click menu of the addon, drawn by the addon itself in the look of the New raid calendar
-- and the invite search (Blizzard's own menu looked like no page of ours).
--   UI:ContextMenu(owner, build): build(root) adds the entries with the calls the pages make on MenuUtil's root
--     (CreateButton / CreateCheckbox / CreateRadio / CreateTitle / CreateDivider / CreateSpacer, an entry's own
--     Create... calls for a submenu, SetEnabled, SetTooltip, SetScrollMode, SetResponse; a callback may answer
--     MenuResponse.Open / Refresh / Close / CloseAll). Shown as: the shared dark panel with its 1px edge, dropping
--     in (it fades up while it falls the last few px), 20px rows with a gold hover, the invite list's square check
--     boxes, round radio dots (the picked one gold), gold titles, hairline dividers, submenus sliding out to the
--     side. A button closes the menu, a check box keeps it open.
--   Where: a dropdown's menu hangs under it, at least as wide (over it when there is no room below); a right-click
--     menu, or one of a large frame (a row, the map), opens at the cursor. The owner lights up while its menu is
--     open (owner:SetLit(on) and owner:OnMenuShown(on), when it has them).
--   A click outside, Escape or the owner hiding closes it; a click on an open dropdown closes it again.
--   UI:CloseMenus(), UI:GetOpenMenu(). ContextMenu returns { root, owner, Close, IsShown } (nil: nothing to show).
-- UI.menuObserver(root) (the test harness's hook) sees each menu's entries as it opens.
local addonName, ns = ...

local UI = ns.UI

local floor, min, max = math.floor, math.min, math.max

local RESP = MenuResponse or { Open = 1, Refresh = 2, Close = 3, CloseAll = 4 }
local MOUSE = MenuInputContext and MenuInputContext.MouseButton or 2
local NOOP = function() end

local ROW_H, DIV_H, SPACER_H = 20, 9, 6
local PAD = 5                  -- inside the panel, around the rows (the invite list's)
local MARK_X, MARK = 4, 12     -- a check box / radio dot at the row's left
local TEXT_X = 6               -- a row's text; after the marks when the menu has any
local SUB_W = 14               -- a submenu's chevron after the text
local MIN_W = 110
local SIDE_GAP = 2             -- between a menu and its submenu
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local GOLD = { 1, 0.82, 0 }

---------------------------------------------------------------------------
-- The entries (what build(root) makes; the same fields the test mock's menus have)
---------------------------------------------------------------------------

local Desc = {}
local DESC_MT = { __index = function(_, k)
    local m = Desc[k]
    if m ~= nil then return m end
    -- (any other MenuUtil description call does nothing here)
    if type(k) == "string" and k:match("^%u") then return NOOP end
end }

local function NewDesc(kind, text)
    return setmetatable({ kind = kind, text = text, children = {}, enabled = true }, DESC_MT)
end

local function Add(self, d)
    d.parent = self
    self.children[#self.children + 1] = d
    return d
end

function Desc:CreateButton(text, callback, data)
    local d = NewDesc("button", text)
    d.callback, d.data = callback, data
    return Add(self, d)
end

function Desc:CreateCheckbox(text, isSelected, setSelected, data)
    local d = NewDesc("checkbox", text)
    d.isSelected, d.setSelected, d.data = isSelected, setSelected, data
    return Add(self, d)
end

function Desc:CreateRadio(text, isSelected, setSelected, data)
    local d = NewDesc("radio", text)
    d.isSelected, d.setSelected, d.data = isSelected, setSelected, data
    return Add(self, d)
end

function Desc:CreateTitle(text) return Add(self, NewDesc("title", text)) end
function Desc:CreateDivider() return Add(self, NewDesc("divider")) end
function Desc:CreateSpacer() return Add(self, NewDesc("spacer")) end

-- (queued: only shown between two entries)
function Desc:QueueDivider()
    local d = Add(self, NewDesc("divider"))
    d.queued = true
    return d
end

function Desc:QueueSpacer()
    local d = Add(self, NewDesc("spacer"))
    d.queued = true
    return d
end

function Desc:Insert(d) return Add(self, d) end
function Desc:SetEnabled(v) self.enabled = v end

function Desc:IsEnabled()
    if type(self.enabled) == "function" then return self.enabled(self) and true or false end
    return self.enabled ~= false
end

function Desc:SetData(v) self.data = v end
function Desc:GetData() return self.data end
function Desc:SetTooltip(fn) self.tooltip = fn end

function Desc:SetTitleAndTextTooltip(title, text)
    self.tooltip = function(tt)
        tt:AddLine(title or "")
        if text then tt:AddLine(text, 1, 1, 1, true) end
    end
end

function Desc:SetIsSelected(fn) self.isSelected = fn end

function Desc:IsSelected()
    if not self.isSelected then return false end
    return self.isSelected(self.data) and true or false
end

function Desc:SetResponse(r) self.response = r end
function Desc:SetOnEnter(fn) self.onEnter = fn end
function Desc:SetOnLeave(fn) self.onLeave = fn end
function Desc:SetScrollMode(height) self.scrollH = tonumber(height) end
function Desc:GetChildren() return self.children end
function Desc:HasElements() return #self.children > 0 end
function Desc:EnumerateElementDescriptions() return ipairs(self.children) end

-- The entries a panel shows: queued dividers / spacers only between two others.
local function Visible(desc)
    local out = {}
    for _, c in ipairs(desc.children) do
        if not c.queued or (#out > 0 and not out[#out].queued) then out[#out + 1] = c end
    end
    while #out > 0 and out[#out].queued do out[#out] = nil end
    return out
end

local function RootOf(d)
    while d.parent do d = d.parent end
    return d
end

-- 1 for an entry of the root's panel, 2 for one in a submenu, ...
local function LevelOf(d)
    local n, p = 0, d.parent
    while p and p.parent do
        n = n + 1
        p = p.parent
    end
    return n + 1
end

---------------------------------------------------------------------------
-- The panels
---------------------------------------------------------------------------

local menu                     -- the open menu (UI:ContextMenu's answer)
local frames = {}              -- the panels: [1] the root's, [2] its submenu's, ...
local depth = 0                -- panels shown
local closing = false
local CloseAll, CloseFrom, OpenLevel

local function Lit(owner, on)
    if not owner then return end
    if owner.SetLit then owner:SetLit(on) end
    if owner.OnMenuShown then owner:OnMenuShown(on) end
end

local function Disc(r, layer, size, c)
    local t = r:CreateTexture(nil, layer)
    t:SetTexture(DISC)
    t:SetSize(size, size)
    t:SetVertexColor(c[1], c[2], c[3], 1)
    return t
end

local function PaintRow(r)
    local d = r.desc
    if not d then return end
    local k = d.kind
    local en = d:IsEnabled()
    local pick = k == "button" or k == "checkbox" or k == "radio"
    local hot = pick and en and (r.hovered or r.open)
    r.hl:SetShown(hot and true or false)
    local on = (k == "checkbox" or k == "radio") and d:IsSelected()
    r.box:SetShown(k == "checkbox")
    r.boxIn:SetShown(k == "checkbox")
    r.check:SetShown(k == "checkbox" and on)
    r.ring:SetShown(k == "radio")
    r.ringIn:SetShown(k == "radio")
    r.dot:SetShown(k == "radio" and on)
    if on then r.ring:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 1) else r.ring:SetVertexColor(0.45, 0.45, 0.5, 1) end
    if k == "title" then r.fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    elseif not en then r.fs:SetTextColor(0.5, 0.5, 0.52)
    elseif k == "radio" and on then r.fs:SetTextColor(1, 0.88, 0.54)
    elseif hot then r.fs:SetTextColor(1, 1, 1)
    else r.fs:SetTextColor(0.9, 0.9, 0.9) end
    local a = (k == "title" or en) and 1 or 0.45
    r.fs:SetAlpha(a)
    for _, t in ipairs(r.marks) do t:SetAlpha(a) end
    local c = hot and 1 or 0.7
    r.arrow:SetVertexColor(c, c, c + 0.03, a)
end

local function PaintLevels()
    for i = 1, depth do
        for _, r in ipairs(frames[i].rows) do
            if r.desc then PaintRow(r) end
        end
    end
end

-- What the menu does after a pick: resp = a MenuResponse.
local function Respond(d, resp)
    if resp == RESP.Open then return end
    if resp == RESP.Refresh then return PaintLevels() end
    if resp == RESP.Close then
        local lvl = LevelOf(d)
        if lvl > 1 then return CloseFrom(lvl) end
    end
    CloseAll()
end

-- What a click on the entry does (the test harness's menu_select calls it too): its callback / setSelected with
-- (data, { context, buttonName }, menu); then the menu does what the callback answered (a MenuResponse), else what
-- the entry was set to (SetResponse), else a check box keeps it open (Refresh) and anything else closes it.
function Desc:cdlPick(button)
    if not self:IsEnabled() then return nil end
    local m = menu
    local fn = self.callback or self.setSelected
    local r
    if fn then r = fn(self.data, { context = MOUSE, buttonName = button or "LeftButton" }, m) end
    if m and menu == m and RootOf(self) == m.root then
        local resp = r
        if type(resp) ~= "number" or resp < 1 or resp > 4 then resp = self.response end
        if type(resp) ~= "number" then resp = (self.kind == "checkbox") and RESP.Refresh or RESP.CloseAll end
        Respond(self, resp)
    end
    return r
end

local function RowEnter(r)
    local d = r.desc
    if not d or not menu then return end
    r.hovered = true
    local f = frames[r.level]
    -- a submenu opens beside its row; any other row closes a deeper one
    if r.hasKids and d:IsEnabled() then
        if not (r.open and depth > r.level) then
            for _, x in ipairs(f.rows) do
                if x ~= r and x.open then
                    x.open = false
                    PaintRow(x)
                end
            end
            r.open = true
            OpenLevel(r.level + 1, d, r)
        end
    elseif depth > r.level then
        CloseFrom(r.level + 1)
    end
    PaintRow(r)
    if d.tooltip and GameTooltip then
        GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
        d.tooltip(GameTooltip, d)
        GameTooltip:Show()
        menu.tip = r
    end
    if d.onEnter then d.onEnter(r, d) end
end

local function RowLeave(r)
    r.hovered = false
    PaintRow(r)
    if menu and menu.tip == r then
        menu.tip = nil
        GameTooltip:Hide()
    end
    if r.desc and r.desc.onLeave then r.desc.onLeave(r, r.desc) end
end

local function RowClick(r, button)
    local d = r.desc
    if not d then return end
    local k = d.kind
    if k ~= "button" and k ~= "checkbox" and k ~= "radio" then return end
    -- (a submenu's own row only opens it, unless it does something itself)
    if r.hasKids and not d.callback then
        if not r.open then RowEnter(r) end
        return
    end
    d:cdlPick(button)
end

local function NewRow(f)
    local r = CreateFrame("Button", nil, f.canvas)
    r:SetHeight(ROW_H)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.hl = r:CreateTexture(nil, "BACKGROUND")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.14)
    r.hl:Hide()
    -- the invite list's check box: a 1px frame around a dark square, the check mark over it
    r.box = r:CreateTexture(nil, "BORDER")
    r.box:SetSize(MARK, MARK)
    r.box:SetPoint("LEFT", MARK_X, 0)
    r.box:SetColorTexture(0.45, 0.45, 0.5, 1)
    r.boxIn = r:CreateTexture(nil, "ARTWORK")
    r.boxIn:SetPoint("TOPLEFT", r.box, "TOPLEFT", 1, -1)
    r.boxIn:SetPoint("BOTTOMRIGHT", r.box, "BOTTOMRIGHT", -1, 1)
    r.boxIn:SetColorTexture(0.03, 0.03, 0.04, 1)
    r.check = r:CreateTexture(nil, "OVERLAY")
    r.check:SetSize(16, 16)
    r.check:SetPoint("CENTER", r.box, "CENTER", 0, 0)
    r.check:SetTexture(CHECK)
    -- a radio: the same, round, with a gold dot (and a gold ring) when picked
    r.ring = Disc(r, "BORDER", MARK, { 0.45, 0.45, 0.5 })
    r.ring:SetPoint("LEFT", MARK_X, 0)
    r.ringIn = Disc(r, "ARTWORK", MARK - 2, { 0.03, 0.03, 0.04 })
    r.ringIn:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.dot = Disc(r, "OVERLAY", 6, GOLD)
    r.dot:SetPoint("CENTER", r.ring, "CENTER", 0, 0)
    r.marks = { r.box, r.boxIn, r.check, r.ring, r.ringIn, r.dot }
    r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.fs:SetJustifyH("LEFT")
    r.fs:SetWordWrap(false)
    r.arrow = r:CreateTexture(nil, "ARTWORK")
    r.arrow:SetSize(10, 10)
    r.arrow:SetPoint("RIGHT", -4, 0)
    UI:SetChevron(r.arrow, true)
    r.line = r:CreateTexture(nil, "BORDER")
    r.line:SetHeight(1)
    r.line:SetPoint("LEFT", 2, 0)
    r.line:SetPoint("RIGHT", -2, 0)
    r.line:SetColorTexture(1, 1, 1, 0.08)
    r:SetScript("OnEnter", RowEnter)
    r:SetScript("OnLeave", RowLeave)
    r:SetScript("OnClick", RowClick)
    return r
end

-- The canvas at its scroll offset, the scroll thumb, and which rows can be clicked (the ones in view).
local function PlaceCanvas(f)
    f.canvas:ClearAllPoints()
    f.canvas:SetPoint("TOPLEFT", f.clip, "TOPLEFT", 0, f.offset)
    if f.scrolls then
        local range = f.contentH - f.viewH
        local th = max(16, floor(f.viewH * f.viewH / f.contentH + 0.5))
        local y = (range > 0 and f.offset / range or 0) * (f.viewH - th)
        f.thumb:ClearAllPoints()
        f.thumb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -(PAD + y))
        f.thumb:SetSize(2, th)
        f.thumb:Show()
    else
        f.thumb:Hide()
    end
    local y = 0
    for _, r in ipairs(f.rows) do
        if not r.desc then break end
        r:EnableMouse(y + r.h > f.offset + 1 and y < f.offset + f.viewH - 1)
        y = y + r.h
    end
end

-- Fills panel f with desc's entries and sizes it (at least minW wide; a scroll mode or the screen's height caps it).
local function Layout(f, desc, minW)
    local list = Visible(desc)
    local marks = false
    for _, d in ipairs(list) do
        if d.kind == "checkbox" or d.kind == "radio" then marks = true end
    end
    local textX = marks and (MARK_X + MARK + 6) or TEXT_X
    local w, h = max(minW or 0, MIN_W), 0
    for i, d in ipairs(list) do
        local r = f.rows[i] or NewRow(f)
        f.rows[i] = r
        local k = d.kind
        r.desc, r.level, r.hovered, r.open = d, f.level, false, false
        r.hasKids = #d.children > 0
        r.h = (k == "divider" and DIV_H) or (k == "spacer" and SPACER_H) or ROW_H
        r:SetHeight(r.h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f.canvas, "TOPLEFT", 0, -h)
        r:SetPoint("TOPRIGHT", f.canvas, "TOPRIGHT", 0, -h)
        h = h + r.h
        local x = (k == "title") and TEXT_X or textX
        r.fs:SetFontObject(k == "title" and "GameFontNormalSmall" or "GameFontHighlightSmall")
        r.fs:ClearAllPoints()
        r.fs:SetPoint("LEFT", r, "LEFT", x, 0)
        if r.hasKids then r.fs:SetPoint("RIGHT", r.arrow, "LEFT", -4, 0) else r.fs:SetPoint("RIGHT", r, "RIGHT", -6, 0) end
        r.fs:SetText((k == "divider" or k == "spacer") and "" or (d.text or ""))
        r.line:SetShown(k == "divider")
        r.arrow:SetShown(r.hasKids)
        local tw = r.fs:GetStringWidth() or 0
        if tw > 0 then
            w = max(w, x + tw + (r.hasKids and (SUB_W + 4) or 0) + 8 + 2 * PAD)
        end
        PaintRow(r)
        r:Show()
    end
    for i = #list + 1, #f.rows do
        f.rows[i]:Hide()
        f.rows[i].desc = nil
    end
    local scale = f:GetScale() or 1
    w = floor(min(w, (UIParent:GetWidth() or 1024) / scale - 40) + 0.5)
    local viewH = h
    if desc.scrollH and viewH > desc.scrollH then viewH = desc.scrollH end
    viewH = min(viewH, (UIParent:GetHeight() or 768) / scale - 40 - 2 * PAD)
    f.contentH, f.viewH, f.offset = h, viewH, 0
    f.scrolls = h > viewH + 0.5
    f.canvas:SetSize(w - 2 * PAD, max(h, 1))
    f:SetSize(w, floor(viewH + 2 * PAD + 0.5))
    PlaceCanvas(f)
end

local function OverMenu()
    for i = 1, depth do
        local f = frames[i]
        if f and f:IsShown() and f:IsMouseOver() then return true end
    end
    return false
end

local function EventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then return C_EventUtils.IsEventValid(event) and true or false end
    return true
end

local function LevelFrame(i)
    if frames[i] then return frames[i] end
    local f = CreateFrame("Frame", i == 1 and "DisasterZoneMenu" or nil, UIParent)
    f.level = i
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:EnableMouseWheel(true)
    f:Hide()
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(UI.DROP_BG[1], UI.DROP_BG[2], UI.DROP_BG[3], UI.DROP_BG[4])
    UI:AddEdges(f, "BORDER")
    UI:SetEdgeColor(f, UI.DROP_EDGE[1], UI.DROP_EDGE[2], UI.DROP_EDGE[3], UI.DROP_EDGE[4])
    f.clip = CreateFrame("Frame", nil, f)
    f.clip:SetPoint("TOPLEFT", PAD, -PAD)
    f.clip:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    if f.clip.SetClipsChildren then f.clip:SetClipsChildren(true) end
    f.canvas = CreateFrame("Frame", nil, f.clip)
    f.canvas:SetSize(1, 1)
    f.thumb = f:CreateTexture(nil, "OVERLAY")
    f.thumb:SetColorTexture(1, 1, 1, 0.22)
    f.thumb:Hide()
    f.rows = {}
    f.offset, f.contentH, f.viewH = 0, 0, 0
    f:SetScript("OnMouseWheel", function(self, delta)
        if not self.scrolls then return end
        if depth > self.level then CloseFrom(self.level + 1) end
        self.offset = max(0, min(self.contentH - self.viewH, self.offset - (delta or 0) * ROW_H * 2))
        PlaceCanvas(self)
    end)
    if i == 1 then
        f:SetScript("OnShow", function(self)
            if EventValid("GLOBAL_MOUSE_DOWN") then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
            -- Escape closes the menu only (the key goes no further); keys stay locked in combat
            if not InCombatLockdown() then
                self:EnableKeyboard(true)
                self:SetPropagateKeyboardInput(true)
            end
        end)
        f:SetScript("OnHide", function(self)
            self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            if not InCombatLockdown() then self:EnableKeyboard(false) end
            if not closing then CloseAll() end
        end)
        f:SetScript("OnKeyDown", function(self, key)
            if key ~= "ESCAPE" then return end
            if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
            CloseAll()
        end)
        f:SetScript("OnEvent", function(_, event)
            local m = menu
            if not m or event ~= "GLOBAL_MOUSE_DOWN" or OverMenu() then return end
            local o = m.owner
            -- (a press on an open dropdown: its click closes the menu, UI:ContextMenu)
            if m.anchored and o and o:IsVisible() and o:IsMouseOver() then
                m.ownerDown = true
                return
            end
            CloseAll()
        end)
        f:SetScript("OnUpdate", function()
            local o = menu and menu.owner
            if o and o.IsVisible and not o:IsVisible() then CloseAll() end
        end)
    end
    frames[i] = f
    return f
end

CloseFrom = function(i)
    for j = #frames, i, -1 do
        if frames[j]:IsShown() then frames[j]:Hide() end
    end
    if depth >= i then depth = i - 1 end
    local p = frames[i - 1]
    if p and p:IsShown() then
        for _, r in ipairs(p.rows) do
            if r.open then
                r.open = false
                PaintRow(r)
            end
        end
    end
end

CloseAll = function()
    if closing then return end
    closing = true
    local m = menu
    menu = nil
    for j = #frames, 1, -1 do
        if frames[j]:IsShown() then frames[j]:Hide() end
    end
    depth = 0
    closing = false
    if m then
        if m.tip and GameTooltip then GameTooltip:Hide() end
        Lit(m.owner, false)
    end
end

-- In the panel's units: a frame's edge v (in that frame's own units).
local function Units(f, frame, v)
    return v * (frame:GetEffectiveScale() or 1) / (f:GetEffectiveScale() or 1)
end

-- Opens panel i with desc's entries: the root under its dropdown or at the cursor, a submenu beside row.
OpenLevel = function(i, desc, row)
    if i > 1 then CloseFrom(i) end
    local m = menu
    local f = LevelFrame(i)
    f.desc = desc
    f:SetScale(m.scale)
    local o = m.owner
    local minW = (i == 1 and m.anchored) and (o:GetWidth() or 0) or 0
    Layout(f, desc, minW)
    local place, dx, dy
    if i > 1 then
        -- beside its row, to the right unless the screen ends there
        local right = true
        local rr, sr = row:GetRight(), UIParent:GetRight()
        if rr and sr and Units(f, row, rr) + PAD + SIDE_GAP + f:GetWidth() > Units(f, UIParent, sr) then right = false end
        place = function(x, y)
            f:ClearAllPoints()
            if right then f:SetPoint("TOPLEFT", row, "TOPRIGHT", PAD + SIDE_GAP + x, PAD + y)
            else f:SetPoint("TOPRIGHT", row, "TOPLEFT", -(PAD + SIDE_GAP) + x, PAD + y) end
        end
        dx, dy = right and -UI.DROP_FALL or UI.DROP_FALL, 0
    elseif m.anchored then
        -- under the dropdown (over it when the screen ends below and there is more room above); its right edges
        -- line up when it sits in the screen's right half and is wider than the dropdown
        local gap = UI.DROP_GAP
        local up, alignRight = false, false
        local ob, ot, st = o:GetBottom(), o:GetTop(), UIParent:GetTop()
        if ob and ot and st then
            local below, above = Units(f, o, ob), Units(f, UIParent, st) - Units(f, o, ot)
            up = f:GetHeight() + gap > below and above > below
        end
        local ol, orr, sw = o:GetLeft(), o:GetRight(), UIParent:GetWidth()
        if ol and orr and sw then
            alignRight = (Units(f, o, ol) + Units(f, o, orr)) / 2 > Units(f, UIParent, sw) / 2
                and f:GetWidth() > (o:GetWidth() or 0) + 1
        end
        local a = alignRight and "RIGHT" or "LEFT"
        place = function(x, y)
            f:ClearAllPoints()
            if up then f:SetPoint("BOTTOM" .. a, o, "TOP" .. a, x, gap + y)
            else f:SetPoint("TOP" .. a, o, "BOTTOM" .. a, x, -gap + y) end
        end
        dx, dy = 0, up and -UI.DROP_FALL or UI.DROP_FALL
    else
        local cx, cy = 0, 0
        if GetCursorPosition then cx, cy = GetCursorPosition() end
        local s = f:GetEffectiveScale() or 1
        cx, cy = (cx or 0) / s, (cy or 0) / s
        place = function(x, y)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx + 2 + x, cy - 2 + y)
        end
        dx, dy = 0, UI.DROP_FALL
    end
    f:Show()
    f:Raise()
    depth = i
    UI:DropIn(f, place, dx, dy)
end

-- Does owner's menu hang under it (a dropdown or a small button) or open at the cursor (a right-click, a row, the
-- map)? owner.cdlDrop = true / owner.cdlMenuAt = "cursor" decide it outright.
local function Anchored(owner)
    if not owner or not owner.GetObjectType or not owner:IsVisible() then return false end
    if owner.cdlMenuAt == "cursor" then return false end
    if GetMouseButtonClicked and GetMouseButtonClicked() == "RightButton" then return false end
    if owner.cdlDrop then return true end
    local t = owner:GetObjectType()
    if t ~= "Button" and t ~= "CheckButton" then return false end
    local w, h = owner:GetWidth() or 0, owner:GetHeight() or 0
    return w > 0 and w <= 240 and h > 0 and h <= 40
end

---------------------------------------------------------------------------
-- The calls
---------------------------------------------------------------------------

function UI:ContextMenu(owner, build)
    -- a click on an open dropdown closes it
    if menu and owner and menu.owner == owner and menu.anchored and menu.ownerDown then
        CloseAll()
        return nil
    end
    local root = NewDesc("root")
    root.owner = owner
    build(root)
    if UI.menuObserver then UI.menuObserver(root) end
    CloseAll()
    if #Visible(root) == 0 then return nil end
    local m = { root = root, owner = owner }
    function m:Close() if menu == self then CloseAll() end end
    function m:IsShown() return menu == self end
    menu = m
    m.anchored = Anchored(owner)
    m.scale = 1
    if owner and owner.GetEffectiveScale then
        m.scale = (owner:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    end
    OpenLevel(1, root)
    Lit(owner, true)
    return m
end

function UI:CloseMenus() CloseAll() end
function UI:GetOpenMenu() return menu end
-- (tests: the panels, [1] the root's)
function UI:GetMenuFrames() return frames, depth end

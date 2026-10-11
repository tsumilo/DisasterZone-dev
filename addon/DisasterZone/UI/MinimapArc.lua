if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MinimapArc.lua", ...) then return end -- DisasterZone UI/MinimapArc.lua
-- ns.MinimapArc: a left-click on the minimap button fans the member's pinned sections out around it in an arc, and
-- a click on one opens the window on that page. The arc opens toward the middle of the screen (so it never leaves
-- it), the pins slide out one after another with a small overshoot and fold back in reverse. The last pin, a "+",
-- picks the pinned sections; a right-click on a pin unpins or moves it. Pins live in settings.minimapPins (the
-- account's saved data, so every character shares them). The arc closes on Escape, on a click elsewhere, after a
-- section is picked, and a few seconds after the mouse leaves it.
local addonName, ns = ...

local Arc = ns:NewModule("MinimapArc")

local MAX_PINS = 6
local DEFAULT_PINS = { "home", "raids", "atlas", "mybis" }
local PIN = 34               -- a pin's size (px)
local RADIUS = 64            -- from the button's centre to a pin's
local STEP = math.rad(33)    -- between two pins on the arc
local OPEN_TIME = 0.22       -- one pin's slide (s)
local STAGGER = 0.035        -- between two pins starting
local LINGER = 3             -- the arc closes this long after the mouse left it (s)

local GOLD = { 0.84, 0.69, 0.36 }
local CREAM = { 0.96, 0.9, 0.72 }
local BODY = { 0.10, 0.12, 0.16 }

-- Each page's atlas icon (UI.ICON_ATLAS); art pack 4 icons have an older stand-in ({ icon, stand-in, pack = 4 }).
local PAGE_ICON = {
    home = 30, raids = { 45, 26 }, council = 26, mybis = { 51, 15 }, atlas = 31, members = { 46, 19 },
    events = { 50, 37 }, games = 21, dungeons = 36, changelog = 25, settings = 13, polls = { 55, 25, 6 },
    gearsim = { 58, 25, 6 }, consumables = { 57, 40, 6 }, blessings = 25, totems = 25,
}

local holder, halo, track, label, plus
local pins = {}              -- the pin buttons (reused), [n + 1] is the "+"
local shown = {}             -- the page keys on the arc now, in order
local state = "closed"       -- "closed" | "opening" | "open" | "closing"
local clock, anchorBtn, lastInside = 0, nil, 0

local function UI() return ns.UI end

---------------------------------------------------------------------------
-- Pins (saved data)
---------------------------------------------------------------------------

function Arc:GetPins()
    local s = ns.db and ns.db.settings
    if not s then return DEFAULT_PINS end
    if type(s.minimapPins) ~= "table" then
        s.minimapPins = {}
        for i, k in ipairs(DEFAULT_PINS) do s.minimapPins[i] = k end
    end
    return s.minimapPins
end

local function IndexOf(list, key)
    for i, k in ipairs(list) do if k == key then return i end end
end

function Arc:IsPinned(key) return IndexOf(self:GetPins(), key) ~= nil end

function Arc:SetPinned(key, on)
    local list = self:GetPins()
    local i = IndexOf(list, key)
    if on and not i and #list < MAX_PINS then
        list[#list + 1] = key
    elseif not on and i then
        table.remove(list, i)
    end
    self:Rebuild()
end

function Arc:MovePin(key, delta)
    local list = self:GetPins()
    local i = IndexOf(list, key)
    local j = i and i + delta
    if not j or j < 1 or j > #list then return end
    list[i], list[j] = list[j], list[i]
    self:Rebuild()
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function IconIndex(key)
    local i = PAGE_ICON[key] or UI().ICON.more
    if type(i) == "table" then i = ns:HasAssets(i[3] or 4) and i[1] or i[2] end
    return i
end

-- A page's atlas icon index (UI.ICON_ATLAS), for other views that show the pages.
function Arc:GetPageIcon(key) return IconIndex(key) end

local function SetIcon(tex, i)
    local c = UI():IconCoords(i)
    tex:SetTexture(UI().ICON_ATLAS)
    tex:SetTexCoord(c[1], c[2], c[3], c[4])
end

local function ShowLabel(pin)
    if not pin.text then label:Hide() return end
    label.title:SetText(pin.text)
    label.hint:SetText(pin.hint or "")
    label.hint:SetShown(pin.hint ~= nil)
    local w = math.max(label.title:GetStringWidth(), pin.hint and label.hint:GetStringWidth() or 0)
    label:SetSize(w + 18, pin.hint and 34 or 20)
    label:ClearAllPoints()
    -- beside the pin, on the side the arc points to
    if math.cos(pin.angle) >= 0 then
        label:SetPoint("LEFT", pin, "RIGHT", 6, 0)
    else
        label:SetPoint("RIGHT", pin, "LEFT", -6, 0)
    end
    label:Show()
end

local function PinMenu(pin)
    local key = pin.key
    UI():ContextMenu(pin, function(root)
        root:CreateTitle(ns.MainFrame:GetPageLabel(key) or key)
        local list = Arc:GetPins()
        local i = IndexOf(list, key) or 0
        local e = root:CreateButton("Move earlier", function() Arc:MovePin(key, -1) end)
        e:SetEnabled(i > 1)
        local l = root:CreateButton("Move later", function() Arc:MovePin(key, 1) end)
        l:SetEnabled(i < #list)
        root:CreateDivider()
        root:CreateButton("Unpin", function() Arc:SetPinned(key, false) end)
    end)
end

local function PickMenu(owner)
    UI():ContextMenu(owner, function(root)
        local list = Arc:GetPins()
        root:CreateTitle(("Pinned sections (%d of %d)"):format(#list, MAX_PINS))
        local keys = {}
        for _, key in ipairs(ns.MainFrame:GetShownPages()) do keys[#keys + 1] = key end
        -- (my class's planners too: a pin opens its window)
        for _, key in ipairs(ns.MainFrame.GetShownTools and ns.MainFrame:GetShownTools() or {}) do keys[#keys + 1] = key end
        for _, key in ipairs(keys) do
            local on = Arc:IsPinned(key)
            local item = root:CreateCheckbox(UI():AtlasIconText(IconIndex(key), 14)
                    .. "  " .. (ns.MainFrame:GetPageLabel(key) or key),
                function() return Arc:IsPinned(key) end,
                function() Arc:SetPinned(key, not Arc:IsPinned(key)) end)
            if not on and #list >= MAX_PINS then
                item:SetEnabled(false)
                item:SetTooltip(function(tt) tt:AddLine(("Up to %d pins: unpin one first."):format(MAX_PINS)) end)
            end
        end
    end)
end

local function MakePin(i)
    local b = CreateFrame("Button", nil, holder)
    b:SetSize(PIN, PIN)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.body = b:CreateTexture(nil, "BACKGROUND")
    b.body:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc")
    b.body:SetAllPoints()
    b.body:SetVertexColor(BODY[1], BODY[2], BODY[3], 0.96)
    b.ring = b:CreateTexture(nil, "BORDER")
    b.ring:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\ring")
    b.ring:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("CENTER")
    b.dot = b:CreateTexture(nil, "OVERLAY")       -- under the page the window shows now
    b.dot:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc")
    b.dot:SetSize(5, 5)
    b.dot:SetPoint("BOTTOM", 0, 3)
    b.dot:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    b.hover, b.t = 0, 0
    b:SetScript("OnEnter", function(self) self.over = true ShowLabel(self) end)
    b:SetScript("OnLeave", function(self) self.over = false label:Hide() end)
    b:SetScript("OnClick", function(self, button)
        if self.isPlus then
            PickMenu(self)
        elseif button == "RightButton" then
            PinMenu(self)
        else
            Arc:Close()
            ns.MainFrame:Open(self.key)
        end
    end)
    pins[i] = b
    return b
end

-- Lays the pins out for the pages pinned (and shown) now; the arc keeps its state.
function Arc:Rebuild()
    if not holder then return end
    wipe(shown)
    for _, key in ipairs(self:GetPins()) do
        if ns.MainFrame:IsPageShown(key) then shown[#shown + 1] = key end
    end
    local n = #shown + 1
    for i = 1, math.max(n, #pins) do
        local b = pins[i] or (i <= n and MakePin(i))
        if b then
            if i <= n then
                b.isPlus = i == n
                b.key = shown[i]
                if b.isPlus then
                    SetIcon(b.icon, UI().ICON.plus)
                    b.text, b.hint = "Pin a section", nil
                else
                    SetIcon(b.icon, IconIndex(b.key))
                    b.text, b.hint = ns.MainFrame:GetPageLabel(b.key) or b.key, "Right-click: move or unpin"
                end
                b:Show()
                if b.over then ShowLabel(b) end
            else
                b:Hide()
            end
        end
    end
    self:Place()
end

-- The arc's direction: from the button toward the middle of the screen.
function Arc:Place()
    if not (holder and anchorBtn) then return end
    local bx, by = anchorBtn:GetCenter()
    local s = anchorBtn:GetEffectiveScale() / UIParent:GetEffectiveScale()
    bx, by = (bx or 0) * s, (by or 0) * s
    holder:ClearAllPoints()
    holder:SetPoint("CENTER", UIParent, "BOTTOMLEFT", bx, by)
    local mx, my = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
    local base = math.atan2(my - by, mx - bx)
    local n = #shown + 1
    for i = 1, n do
        pins[i].angle = base + (i - (n + 1) / 2) * STEP
    end
end

---------------------------------------------------------------------------
-- Motion
---------------------------------------------------------------------------

local function EaseOutBack(t)
    local c1 = 1.5
    local c3 = c1 + 1
    t = t - 1
    return 1 + c3 * t * t * t + c1 * t * t
end

local function Inside()
    if anchorBtn and anchorBtn:IsMouseOver() then return true end
    for i = 1, #shown + 1 do
        if pins[i] and pins[i]:IsShown() and pins[i]:IsMouseOver(4, -4, -4, 4) then return true end
    end
    return label:IsShown() and label:IsMouseOver()
end

local function OnUpdate(_, elapsed)
    clock = clock + elapsed
    local n = #shown + 1
    local done = true
    local current = ns.MainFrame:GetSelectedTab()
    for i = 1, n do
        local b = pins[i]
        -- opening: first pin first; closing: last pin first
        local delay = (state == "closing" and (n - i) or (i - 1)) * STAGGER
        local p = math.min(1, math.max(0, (clock - delay) / OPEN_TIME))
        if state == "closing" then p = 1 - p end
        b.t = p
        if (state == "closing" and p > 0) or (state ~= "closing" and p < 1) then done = false end
        b.hover = b.hover + ((b.over and 1 or 0) - b.hover) * math.min(1, elapsed * 14)
        local e = state == "closing" and p * p or EaseOutBack(p)
        local a = b.angle - (1 - e) * 0.45           -- a little swirl on the way out
        local scale = (0.35 + 0.65 * math.min(e, 1.08)) * (1 + 0.14 * b.hover)
        b:SetScale(math.max(scale, 0.05))
        b:SetAlpha(math.min(1, p * 1.8))
        b:ClearAllPoints()
        b:SetPoint("CENTER", holder, "CENTER", RADIUS * e * math.cos(a) / b:GetScale(),
            RADIUS * e * math.sin(a) / b:GetScale())
        local lit = 0.55 + 0.45 * b.hover
        b.ring:SetVertexColor(GOLD[1] * lit + (1 - lit) * 0.3, GOLD[2] * lit + (1 - lit) * 0.3,
            GOLD[3] * lit + (1 - lit) * 0.3)
        b.icon:SetVertexColor(CREAM[1], CREAM[2], CREAM[3], 0.8 + 0.2 * b.hover)
        b.dot:SetShown(not b.isPlus and current == b.key)
    end
    local whole = n > 0 and pins[1].t or 0
    halo:SetAlpha(0.55 * whole)
    track:SetAlpha(0.35 * whole)
    if state == "opening" and done then state = "open" end
    if state == "closing" and done then
        state = "closed"
        holder:Hide()
        return
    end
    if state == "open" then
        if Inside() then
            lastInside = clock
        elseif clock - lastInside > LINGER and not UI():GetOpenMenu() then
            Arc:Close()
        end
    end
end

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------

local function Build()
    holder = CreateFrame("Frame", "DisasterZoneMinimapArc", UIParent)
    holder:SetFrameStrata("DIALOG")
    holder:SetSize(1, 1)
    holder:Hide()
    holder:SetScript("OnUpdate", OnUpdate)
    -- a soft dark pool behind the arc and the gold track the pins ride on
    halo = holder:CreateTexture(nil, "BACKGROUND")
    halo:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\disc")
    halo:SetVertexColor(0.02, 0.03, 0.05)
    halo:SetSize((RADIUS + PIN) * 2, (RADIUS + PIN) * 2)
    halo:SetPoint("CENTER")
    track = holder:CreateTexture(nil, "BORDER")
    track:SetTexture("Interface\\AddOns\\DisasterZone\\Media\\Strategy\\ring")
    track:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    track:SetSize(RADIUS * 2 + 4, RADIUS * 2 + 4)
    track:SetPoint("CENTER")
    -- the flat label pill
    label = CreateFrame("Frame", nil, holder)
    label:SetFrameLevel(holder:GetFrameLevel() + 20)
    label.bg = label:CreateTexture(nil, "BACKGROUND")
    label.bg:SetAllPoints()
    label.bg:SetColorTexture(0.04, 0.05, 0.07, 0.94)
    label.edge = label:CreateTexture(nil, "BORDER")
    label.edge:SetPoint("TOPLEFT")
    label.edge:SetPoint("BOTTOMLEFT")
    label.edge:SetWidth(2)
    label.edge:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.9)
    label.title = label:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label.title:SetPoint("TOPLEFT", 10, -4)
    label.title:SetTextColor(CREAM[1], CREAM[2], CREAM[3])
    label.hint = label:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label.hint:SetPoint("TOPLEFT", label.title, "BOTTOMLEFT", 0, -3)
    label:Hide()
    holder:SetScript("OnHide", function()
        state = "closed"
        label:Hide()
    end)
    tinsert(UISpecialFrames, "DisasterZoneMinimapArc")   -- Escape closes it
    holder:RegisterEvent("GLOBAL_MOUSE_DOWN")
    holder:SetScript("OnEvent", function()
        if state ~= "closed" and state ~= "closing" and not Inside() and not UI():GetOpenMenu() then Arc:Close() end
    end)
end

function Arc:IsOpen() return state == "opening" or state == "open" end

function Arc:Open(btn)
    if not holder then Build() end
    anchorBtn = btn or anchorBtn
    if not anchorBtn then return end
    GameTooltip:Hide()
    self:Rebuild()
    if state == "closing" then
        -- turn around from where the pins are
        clock = math.max(0, OPEN_TIME * (pins[1] and pins[1].t or 0))
    else
        clock = 0
        for i = 1, #shown + 1 do pins[i].t, pins[i].hover = 0, 0 end
    end
    state, lastInside = "opening", 0
    holder:Show()
end

-- now = true hides it at once (the window is opening over it).
function Arc:Close(now)
    if not holder or state == "closed" then return end
    UI():CloseMenus()
    label:Hide()
    if now then holder:Hide() return end
    if state == "closing" then return end
    clock = math.max(0, OPEN_TIME * (1 - (pins[#shown + 1] and pins[#shown + 1].t or 1)))
    state = "closing"
end

function Arc:Toggle(btn)
    if self:IsOpen() then self:Close() else self:Open(btn) end
end

ns:On("CONFIG_UPDATED", function() if Arc:IsOpen() then Arc:Rebuild() end end)

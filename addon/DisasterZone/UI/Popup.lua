if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Popup.lua", ...) then return end -- DisasterZone: UI/Popup.lua
-- The addon's own confirm dialogs (1.3.5), in the window frame's look instead of the game's StaticPopup (red
-- buttons, gilded border): a slate panel with a soft shadow, a gold title, the text, an optional field, and flat
-- buttons along the foot (the first is the gold one, red for a deletion). It dims the window it opens over.
--
-- The same contract as StaticPopup, so a dialog moves over unchanged: Popup:Register(which, def) with def's text
-- ("%s" filled by text1 / text2), button1..3, OnShow(dialog, data), OnAccept(dialog, data, data2), OnCancel(dialog,
-- data, reason), OnAlt, OnHide, hasEditBox (+ maxLetters, EditBoxOnEnterPressed(eb) / EditBoxOnEscapePressed(eb),
-- eb:GetParent() = the dialog), hideOnEscape, noCancelOnEscape, noCancelOnReuse, showAlert, timeout; and ours:
-- title, danger (the first button red). Popup:Show(which, text1, text2, data) / Hide / Visible / FindVisible /
-- HideAll / Click(dialog, index) / EscapePressed. Escape closes the top dialog (it goes no further); a click on a
-- button runs its callback, then the dialog closes unless the callback returned true.
-- 1.4: a def may also take width (wider than 380), multiline (+ multiHeight, hint: a box of several lines instead of
-- the field; Enter is a new line, Ctrl+Enter is OK) and EditBoxOnTextChanged(eb, data); Popup:SetError(dialog, text)
-- shows a line in the warning colour under the field. And the two dialogs everybody needs, without a Register:
-- Popup:Confirm(opts) and Popup:Prompt(opts) (further down).
local addonName, ns = ...

local Popup = ns:NewModule("Popup")

local floor, max = math.floor, math.max

local W = 380                       -- the dialog's width
local PAD = 16                      -- inside
local NUM = 4                       -- dialogs shown at once (as the game's)
local defs = {}
local frames = {}
Popup.dialogs = defs                -- the definitions by name (as StaticPopupDialogs: callers may write it directly)

local function UI() return ns.UI end

local function text(parent, font, size, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", font)
    local path, _, flags = fs:GetFont()
    if path and size then fs:SetFont(path, size, flags) end
    if r then fs:SetTextColor(r, g, b) end
    fs:SetJustifyH("LEFT")
    return fs
end

local function safe(name, fn, ...)
    if type(fn) ~= "function" then return true, nil end
    local ok, r = pcall(fn, ...)
    if not ok then
        local h = geterrorhandler and geterrorhandler()
        if h then h(("Popup %s: %s"):format(name, tostring(r))) end
    end
    return ok, r
end

-- The window a dialog opens over (dimmed under it): the top shown one of ours, nil for the screen.
local function Owner()
    for _, f in ipairs({ _G.DisasterZoneMainFrame or false }) do
        if type(f) == "table" and f.IsShown and f:IsShown() then return f end
    end
    return nil
end

-- The dialogs' panel on any frame (the strategy board's text prompt uses it too): the window frame's soft shadow,
-- the slate, a 1 px edge, f.title (gold, 14) and f.glint (the gold line under a title; the caller places both).
function Popup:SkinPanel(f)
    if UI().SoftShadow then
        UI():SoftShadow(f, 30, 0.5, 8, 6)
        UI():SoftShadow(f, 8, 0.35, 2, 1)
    end
    f.bg = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(1, 1, 1, 1)
    if f.bg.SetGradient and CreateColor then
        f.bg:SetGradient("VERTICAL", CreateColor(0.075, 0.075, 0.088, 1), CreateColor(0.105, 0.105, 0.122, 1))
    else
        f.bg:SetColorTexture(0.09, 0.09, 0.105, 1)
    end
    UI():AddEdges(f, "BORDER")
    UI():SetEdgeColor(f, 0.30, 0.30, 0.33, 1)
    f.glint = f:CreateTexture(nil, "ARTWORK")
    f.glint:SetHeight(1)
    f.glint:SetColorTexture(1, 1, 1, 1)
    if f.glint.SetGradient and CreateColor then
        f.glint:SetGradient("HORIZONTAL", CreateColor(0.79, 0.64, 0.15, 0.7), CreateColor(0.79, 0.64, 0.15, 0))
    end
    f.title = text(f, "GameFontNormal", 14, 1, 0.82, 0)
    f.title:SetWordWrap(false)
end

local function New(i)
    local f = CreateFrame("Frame", "DisasterZonePopup" .. i, UIParent)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(100 + i * 20)
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetSize(W, 120)
    f:Hide()
    -- the window behind it, dimmed (a frame of its own, under the dialog)
    local dim = CreateFrame("Frame", nil, UIParent)
    dim:SetFrameStrata("FULLSCREEN_DIALOG")
    dim:SetFrameLevel(100 + i * 20 - 5)
    dim:EnableMouse(true)
    dim.bg = dim:CreateTexture(nil, "BACKGROUND")
    dim.bg:SetAllPoints()
    dim.bg:SetColorTexture(0, 0, 0, 0.55)
    dim:Hide()
    f.dim = dim

    Popup:SkinPanel(f)
    f.close = CreateFrame("Button", nil, f)
    f.close:SetSize(20, 20)
    f.close:SetPoint("TOPRIGHT", -8, -9)
    f.close.lines = {}
    for k = 1, 2 do
        local l = f.close:CreateLine(nil, "ARTWORK")
        l:SetThickness(1.5)
        l:SetColorTexture(0.66, 0.66, 0.68, 1)
        f.close.lines[k] = l
    end
    f.close.lines[1]:SetStartPoint("CENTER", -5, 5)
    f.close.lines[1]:SetEndPoint("CENTER", 5, -5)
    f.close.lines[2]:SetStartPoint("CENTER", -5, -5)
    f.close.lines[2]:SetEndPoint("CENTER", 5, 5)
    f.close:SetScript("OnEnter", function(self) for _, l in ipairs(self.lines) do l:SetColorTexture(1, 1, 1, 1) end end)
    f.close:SetScript("OnLeave", function(self) for _, l in ipairs(self.lines) do l:SetColorTexture(0.66, 0.66, 0.68, 1) end end)
    f.close:SetScript("OnClick", function() Popup:Dismiss(f) end)

    f.alert = f:CreateTexture(nil, "ARTWORK")
    f.alert:SetSize(22, 22)
    f.alert:SetTexture(UI().ICON_WARN or "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    do
        local path, _, flags = f.text:GetFont()
        if path then f.text:SetFont(path, 13, flags) end
    end
    f.text:SetJustifyH("LEFT")
    f.text:SetJustifyV("TOP")
    f.text:SetSpacing(3)
    f.text:SetWordWrap(true)
    f.Text = f.text

    f.editBox = UI():CreateSleekEditBox(f, W - 2 * PAD, 26, "GameFontHighlight")
    f.EditBox = f.editBox
    f.editBox:SetTextColor(0.92, 0.92, 0.92)
    f.editBox:SetScript("OnEnterPressed", function(eb)
        local def = defs[f.which]
        if def and def.EditBoxOnEnterPressed then
            safe(f.which .. " EditBoxOnEnterPressed", def.EditBoxOnEnterPressed, eb, f.data)
        else
            Popup:Click(f, 1)
        end
    end)
    f.editBox:SetScript("OnEscapePressed", function(eb)
        local def = defs[f.which]
        if def and def.EditBoxOnEscapePressed then
            safe(f.which .. " EditBoxOnEscapePressed", def.EditBoxOnEscapePressed, eb, f.data)
        else
            Popup:Dismiss(f)
        end
    end)
    f.editBox:HookScript("OnTextChanged", function(eb)
        local def = f.which and defs[f.which]
        if def and def.EditBoxOnTextChanged and f:IsShown() then
            safe(f.which .. " EditBoxOnTextChanged", def.EditBoxOnTextChanged, eb, f.data)
        end
    end)
    -- the error line under the field (Popup:SetError)
    f.err = text(f, "GameFontHighlightSmall", 11, 1, 0.55, 0.2)
    f.err:SetWordWrap(true)
    f.err:Hide()

    f.rule = f:CreateTexture(nil, "ARTWORK")
    f.rule:SetHeight(1)
    f.rule:SetColorTexture(1, 1, 1, 0.07)
    for b = 1, 3 do
        local btn = UI():CreateSleekButton(f, "", 90, 26, function() Popup:Click(f, b) end, b == 1 and "primary" or nil)
        f["button" .. b] = btn
    end
    function f:GetEditBox() return self.editBox end
    function f:GetButton1() return self.button1 end
    function f:GetButton2() return self.button2 end
    function f:GetTextFontString() return self.text end

    -- Escape closes the dialog and goes no further; other keys go on to the game
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
            Popup:Dismiss(self)
        elseif not InCombatLockdown() then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:SetScript("OnShow", function(self)
        if not InCombatLockdown() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:SetScript("OnHide", function(self)
        if not InCombatLockdown() then self:EnableKeyboard(false) end
        self.dim:Hide()
        self.editBox:ClearFocus()
        if self.multi then self.multi:ClearFocus() end
        self.expires = nil
        local which = self.which
        local def = which and defs[which]
        if def and def.OnHide and not self.silent then safe(which .. " OnHide", def.OnHide, self, self.data) end
        self.silent = nil
    end)
    f:SetScript("OnUpdate", function(self)
        if self.expires and GetTime() >= self.expires then
            self.expires = nil
            Popup:Dismiss(self, "timeout")
        end
    end)
    frames[i] = f
    return f
end

local function Frame(i) return frames[i] or New(i) end

-- The box of several lines (a def with multiline), made the first time one is needed: a dark well with a scroll
-- frame; the view follows the cursor, a click anywhere in the well types there, Ctrl+Enter is OK.
local function Multi(f)
    if f.multi then return f.multi end
    local sf = UI():CreateScrollFrame(f)
    f.multiScroll = sf
    sf.scrollBarHideable = true
    if sf.ScrollBar then sf.ScrollBar:Hide() end
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetFontObject("ChatFontNormal")
    eb:SetTextColor(0.92, 0.92, 0.92)          -- (as the field)
    eb:SetWidth(W - 2 * PAD - 22)
    sf:SetScrollChild(eb)
    sf:EnableMouse(true)
    sf:SetScript("OnMouseDown", function() eb:SetFocus() end)
    eb:SetScript("OnCursorChanged", function(_, _, y, _, h)
        local top, view = sf:GetVerticalScroll() or 0, sf:GetHeight() or 0
        y, h = -(y or 0), h or 0
        if y < top then
            sf:SetVerticalScroll(y)
        elseif y + h > top + view then
            sf:SetVerticalScroll(y + h - view)
        end
    end)
    eb:SetScript("OnEscapePressed", function() Popup:Dismiss(f) end)
    eb:SetScript("OnEnterPressed", function(self)
        if IsControlKeyDown() then Popup:Click(f, 1) else self:Insert("\n") end
    end)
    eb:SetScript("OnTextChanged", function(self)
        local def = f.which and defs[f.which]
        if def and def.EditBoxOnTextChanged and f:IsShown() then
            safe(f.which .. " EditBoxOnTextChanged", def.EditBoxOnTextChanged, self, f.data)
        end
    end)
    f.multiBg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.multiBg:SetColorTexture(0, 0, 0, 0.6)
    f.multiHint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.multiHint:SetJustifyH("LEFT")
    f.multi = eb
    return eb
end

-- Lays the dialog out for its definition and text: title (or none), the alert icon, the text, the field, the
-- buttons right to left (the first on the right).
local function Layout(f, def)
    local w = def.width or W
    f:SetWidth(w)
    local y = PAD
    local hasTitle = def.title ~= nil
    f.title:SetShown(hasTitle)
    f.close:SetShown(hasTitle)
    f.glint:SetShown(hasTitle)
    if hasTitle then
        f.title:SetText(def.title)
        f.title:ClearAllPoints()
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -14)
        f.title:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
        f.glint:ClearAllPoints()
        f.glint:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -40)
        f.glint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -40)
        y = 40 + 14
    end
    local tx = PAD
    f.alert:SetShown(def.showAlert and true or false)
    if def.showAlert then
        f.alert:ClearAllPoints()
        f.alert:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y - 3))
        tx = PAD + 22 + 10
    end
    -- (a dialog without words, a bare prompt, goes straight to its field)
    local words = f.text:GetText()
    local hasText = words ~= nil and words ~= ""
    f.text:SetShown(hasText)
    if hasText then
        f.text:ClearAllPoints()
        f.text:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -y)
        f.text:SetWidth(w - tx - PAD)
        local th = f.text:GetStringHeight() or 16
        if th < 1 then th = 16 end
        y = y + max(th, def.showAlert and 18 or 0) + 14
    elseif def.showAlert then
        y = y + 18 + 14
    end
    f.editBox:SetShown(def.hasEditBox and true or false)
    if def.hasEditBox then
        f.editBox:ClearAllPoints()
        f.editBox:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
        f.editBox:SetWidth(w - 2 * PAD)
        f.editBox:SetMaxLetters(def.maxLetters or 0)
        y = y + 26 + 14
    end
    local multi = def.multiline and Multi(f) or f.multi
    if multi then
        local on = def.multiline and true or false
        f.multiScroll:SetShown(on)
        f.multiBg:SetShown(on)
        f.multiHint:SetShown(on and def.hint ~= false)
        if not on and f.multiScroll.ScrollBar then f.multiScroll.ScrollBar:Hide() end
        if on then
            local mh = def.multiHeight or 120
            f.multiScroll:ClearAllPoints()
            f.multiScroll:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -(y + 4))
            f.multiScroll:SetSize(w - 2 * PAD - 22, mh - 8)
            f.multiBg:ClearAllPoints()
            f.multiBg:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -y)
            f.multiBg:SetSize(w - 2 * PAD, mh)
            multi:SetWidth(w - 2 * PAD - 22)
            multi:SetMaxLetters(def.maxLetters or 0)
            f.multiHint:SetText(type(def.hint) == "string" and def.hint or ("Ctrl+Enter: " .. tostring(def.button1 or "OK")))
            y = y + mh + 14
        end
    end
    f.err:SetShown(f.errText ~= nil)
    if f.errText then
        f.err:SetText(f.errText)
        f.err:ClearAllPoints()
        f.err:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(y - 8))
        f.err:SetWidth(w - 2 * PAD)
        local eh = f.err:GetStringHeight() or 12
        if eh < 1 then eh = 12 end
        y = y + eh + 6
    end
    f.rule:ClearAllPoints()
    f.rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -y)
    f.rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -y)
    local prev
    for b = 1, 3 do
        local btn = f["button" .. b]
        local label = def["button" .. b]
        btn:SetShown(label ~= nil)
        if label then
            btn:SetText(label)
            local fs = btn:GetFontString()
            btn:SetWidth(max(84, floor((fs and fs:GetStringWidth() or 60) + 30 + 0.5)))
            btn.kind = b == 1 and (def.danger and "danger" or "primary") or "secondary"
            if btn.cdlPaint then btn:cdlPaint(true) end
            btn:ClearAllPoints()
            if prev then btn:SetPoint("RIGHT", prev, "LEFT", -6, 0)
            else btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -(y + 11)) end
            prev = btn
        end
    end
    if f.multiHint and f.multiHint:IsShown() then
        f.multiHint:ClearAllPoints()
        f.multiHint:SetPoint("LEFT", f, "TOPLEFT", PAD, -(y + 11 + 13))
    end
    f:SetHeight(y + 11 + 26 + 12)
end

-- Places the dialog over the window it belongs to (or the screen), the n-th one a little lower, and the dim.
local function Place(f, i)
    local owner = Owner()
    f:ClearAllPoints()
    if owner then
        f:SetPoint("CENTER", owner, "CENTER", 0, 40 - (i - 1) * 24)
        f.dim:ClearAllPoints()
        f.dim:SetAllPoints(owner)
        f.dim:SetShown(i == 1)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 120 - (i - 1) * 24)
        f.dim:Hide()
    end
end

function Popup:Register(which, def)
    if type(which) ~= "string" or type(def) ~= "table" then error("Popup:Register(which, def)", 2) end
    defs[which] = def
end

function Popup:Get(which) return defs[which] end

-- Shows dialog `which` (text1 / text2 fill the text's %s, data goes to the callbacks). A shown one of the same kind
-- is used again (its OnCancel(dialog, data, "override") first, unless noCancelOnReuse). Returns the dialog, nil
-- when none is free (OnCancel(nil, data) then, as the game does).
function Popup:Show(which, text1, text2, data)
    local def = defs[which]
    if not def then return nil end
    local f
    for i = 1, NUM do
        local x = frames[i]
        if x and x:IsShown() and x.which == which then f = x break end
    end
    if f then
        local old = f.data
        f.silent = true
        f:Hide()
        if not def.noCancelOnReuse and def.OnCancel then safe(which .. " OnCancel", def.OnCancel, f, old, "override") end
    else
        for i = 1, NUM do
            local x = Frame(i)
            if not x:IsShown() then f = x break end
        end
    end
    if not f then
        if def.OnCancel then safe(which .. " OnCancel", def.OnCancel, nil, data) end
        return nil
    end
    f.which, f.data, f.data2 = which, data, nil
    local t = def.text or ""
    local ok, s = pcall(string.format, t, text1 or "", text2 or "")
    f.text:SetText(ok and s or t)
    f.editBox:SetText("")
    if f.multi then f.multi:SetText("") end
    f.errText = nil
    for b = 1, 3 do f["button" .. b]:Enable() end
    Layout(f, def)
    local index = 1
    for i = 1, NUM do if frames[i] == f then index = i end end
    Place(f, index)
    f.expires = (def.timeout and def.timeout > 0) and (GetTime() + def.timeout) or nil
    f:Show()
    f:Raise()
    if def.OnShow then safe(which .. " OnShow", def.OnShow, f, data) end
    if def.hasEditBox and not f.editBox:HasFocus() then f.editBox:SetFocus() end
    if def.multiline and f.multi and not f.multi:HasFocus() then f.multi:SetFocus() end
    return f
end

-- Closes shown dialogs of kind `which` (with that data when given) without a callback but OnHide.
function Popup:Hide(which, data)
    for i = 1, NUM do
        local f = frames[i]
        if f and f:IsShown() and f.which == which and (data == nil or f.data == data) then f:Hide() end
    end
end

function Popup:HideAll()
    for i = 1, NUM do
        local f = frames[i]
        if f and f:IsShown() then f:Hide() end
    end
end

-- name, dialog of a shown dialog of kind `which` (as StaticPopup_Visible), else nil.
function Popup:Visible(which)
    for i = 1, NUM do
        local f = frames[i]
        if f and f:IsShown() and f.which == which then return f:GetName(), f end
    end
    return nil
end

function Popup:FindVisible(which, data)
    for i = 1, NUM do
        local f = frames[i]
        if f and f:IsShown() and f.which == which and (data == nil or f.data == data) then return f end
    end
    return nil
end

-- Button `index` of the dialog: 1 OnAccept, 2 OnCancel ("clicked"), 3 OnAlt; then it closes unless the callback
-- returned true.
function Popup:Click(f, index)
    local which = f and f.which
    local def = which and defs[which]
    if not def or not f:IsShown() then return end
    local keep
    if index == 1 and def.OnAccept then
        local ok, r = safe(which .. " OnAccept", def.OnAccept, f, f.data, f.data2)
        keep = ok and r
    elseif index == 2 and def.OnCancel then
        local ok, r = safe(which .. " OnCancel", def.OnCancel, f, f.data, "clicked")
        keep = ok and r
    elseif index == 3 and def.OnAlt then
        safe(which .. " OnAlt", def.OnAlt, f, f.data, "clicked")
    end
    if not keep and f:IsShown() and f.which == which then f:Hide() end
end

-- Escape, the X or the timeout, as the game's StaticPopup_EscapePressed: a dialog that closes on Escape
-- (hideOnEscape) gets OnCancel (reason "clicked", as the game passes; "timeout" for the timeout) unless
-- noCancelOnEscape, and closes; one that doesn't stays.
function Popup:Dismiss(f, reason)
    local which = f and f.which
    local def = which and defs[which]
    if not def or not f:IsShown() then return false end
    if reason ~= "timeout" and not def.hideOnEscape then return false end
    if def.OnCancel and not def.noCancelOnEscape then
        safe(which .. " OnCancel", def.OnCancel, f, f.data, reason or "clicked")
    end
    if f:IsShown() and f.which == which then f:Hide() end
    return true
end

-- Escape pressed with dialogs shown: the top one closes. True if one did.
function Popup:EscapePressed()
    for i = NUM, 1, -1 do
        local f = frames[i]
        if f and f:IsShown() then return self:Dismiss(f) end
    end
    return false
end

function Popup:IsShown()
    for i = 1, NUM do
        if frames[i] and frames[i]:IsShown() then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Errors and values
---------------------------------------------------------------------------

-- Shows text (in the warning colour) under the dialog's field; nil takes it away. The dialog grows to fit.
function Popup:SetError(f, text)
    if not (f and f.which and defs[f.which]) then return end
    if text ~= nil then text = tostring(text) end
    if f.errText == text then return end
    f.errText = text
    Layout(f, defs[f.which])
end

-- What was typed in the dialog's field (or its box of several lines).
function Popup:GetValue(f)
    if not f then return nil end
    local def = f.which and defs[f.which]
    if def and def.multiline and f.multi then return f.multi:GetText() or "" end
    return f.editBox:GetText() or ""
end

---------------------------------------------------------------------------
-- Confirm / Prompt: the dialogs everybody asks, without a Register
---------------------------------------------------------------------------

-- The def of a ready-made dialog, made the first time and filled anew each time it is asked.
local function ReadyDef(prefix, key)
    local which = prefix .. (key ~= nil and ("_" .. tostring(key)) or "")
    local def = defs[which]
    if not def then
        def = {}
        defs[which] = def
    end
    for k in pairs(def) do def[k] = nil end
    return which, def
end

-- Popup:Confirm(opts) -> dialog: a question with a yes and a no.
-- opts: { title, text (shown as is), ok (OKAY), cancel (CANCEL; false: none), danger (the ok red), alert (the
--   warning icon), alt + onAlt (a third button), width, timeout, key (a second Confirm with the same key replaces
--   the shown one: its onCancel gets "override"),
--   onAccept(dialog) (return true to keep the dialog open), onCancel(dialog, reason) (Cancel / Escape / its X:
--   "clicked", "timeout", "override") }
function Popup:Confirm(o)
    o = o or {}
    local which, def = ReadyDef("DISASTERZONE_CONFIRM", o.key)
    def.title = o.title
    def.text = "%s"
    def.button1 = o.ok or _G.OKAY or "OK"
    if o.cancel ~= false then def.button2 = o.cancel or _G.CANCEL or "Cancel" end
    def.button3 = o.alt
    def.danger = o.danger and true or nil
    def.showAlert = o.alert and true or nil
    def.width = o.width
    def.timeout = o.timeout or 0
    def.whileDead = true
    def.hideOnEscape = true
    def.OnAccept = function(dlg, data)
        if type(data) == "table" and data.onAccept then return data.onAccept(dlg) end
    end
    def.OnCancel = function(dlg, data, reason)
        if type(data) == "table" and data.onCancel then data.onCancel(dlg, reason) end
    end
    def.OnAlt = function(dlg, data)
        if type(data) == "table" and data.onAlt then data.onAlt(dlg) end
    end
    return self:Show(which, o.text ~= nil and tostring(o.text) or "", nil, o)
end

-- Checks a prompt's value: true, or false and the reason (nil: no words, the OK just stays grey).
local function CheckPrompt(o, v)
    if type(o) ~= "table" or not o.validate then return true end
    local ok, r = pcall(o.validate, v)
    if not ok then return false, nil end
    if r == nil or r == true then return true end
    return false, type(r) == "string" and r or nil
end

local function PromptValue(o, f)
    local v = Popup:GetValue(f)
    if type(o) == "table" and o.trim and ns.Util and ns.Util.Trim then v = ns.Util.Trim(v) or "" end
    return v
end

-- Popup:Prompt(opts) -> dialog: asks for a text.
-- opts: { title, text (over the field), default, ok (OKAY), cancel (CANCEL), maxLetters, width, trim (spaces off
--   both ends), multiline (a box of several lines: multiHeight, hint; Ctrl+Enter is OK), key (as Confirm's),
--   validate(value) -> true / nil (fine) | false (the OK stays grey) | "why not" (and that shows under the field),
--   onAccept(value, dialog) (return true to keep it open), onCancel(dialog, reason) }
-- Enter is OK; a value validate turns down keeps the dialog open with its reason.
function Popup:Prompt(o)
    o = o or {}
    local which, def = ReadyDef("DISASTERZONE_PROMPT", o.key)
    def.title = o.title
    def.text = "%s"
    def.button1 = o.ok or _G.OKAY or "OK"
    def.button2 = o.cancel or _G.CANCEL or "Cancel"
    def.hasEditBox = not o.multiline or nil
    def.multiline = o.multiline and true or nil
    def.multiHeight = o.multiHeight
    def.hint = o.hint
    def.maxLetters = o.maxLetters
    def.width = o.width or (o.multiline and 520 or nil)
    def.timeout = 0
    def.whileDead = true
    def.hideOnEscape = true
    def.OnShow = function(dlg, data)
        local box = (def.multiline and dlg.multi) or dlg.editBox
        local d = type(data) == "table" and data.default
        box:SetText(d ~= nil and tostring(d) or "")
        if def.multiline then
            if dlg.multiScroll then dlg.multiScroll:SetVerticalScroll(0) end
            box:SetCursorPosition(#(box:GetText() or ""))
        else
            box:HighlightText()
        end
        Popup:CheckPromptButton(dlg)
    end
    def.EditBoxOnTextChanged = function(eb)
        local dlg = eb:GetParent()
        if dlg and dlg.which == which then
            Popup:CheckPromptButton(dlg)
        elseif frames then
            for i = 1, NUM do
                local x = frames[i]
                if x and x.which == which and x:IsShown() then Popup:CheckPromptButton(x) end
            end
        end
    end
    def.OnAccept = function(dlg, data)
        local v = PromptValue(data, dlg)
        local ok, why = CheckPrompt(data, v)
        if not ok then
            Popup:SetError(dlg, why)
            return true
        end
        if type(data) == "table" and data.onAccept then return data.onAccept(v, dlg) end
    end
    def.OnCancel = function(dlg, data, reason)
        if type(data) == "table" and data.onCancel then data.onCancel(dlg, reason) end
    end
    return self:Show(which, o.text ~= nil and tostring(o.text) or "", nil, o)
end

-- The prompt's OK follows its validate (grey while the value is turned down; the reason once something is typed).
function Popup:CheckPromptButton(f)
    if not (f and f.data and f:IsShown()) then return end
    local v = PromptValue(f.data, f)
    local ok, why = CheckPrompt(f.data, v)
    f.button1:SetEnabled(ok)
    if f.button1.cdlPaint then f.button1:cdlPaint(true) end
    self:SetError(f, (not ok and v ~= "") and why or nil)
end

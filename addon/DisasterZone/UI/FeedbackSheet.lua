if DisasterZoneBoot and DisasterZoneBoot.Run("UI/FeedbackSheet.lua", ...) then return end -- DisasterZone: UI/FeedbackSheet.lua
-- Telling Tsumil (Core/Feedback.lua), from anywhere:
--   The sheet: four tiles (Something broke / I have an idea / Change something / I love this), a box for a few words,
--   "About" (what it is about: Point at it, or Ctrl+right-click anything in DisasterZone), what goes with it (version,
--   zone, spec, the last Lua error for a bug), the guild's open items that sound the same (Me too instead of a
--   duplicate), "Name me in the changelog", Send. After Send it says where the feedback goes and offers See it.
--   Point at it: the screen dims, the DisasterZone frame under the mouse lights up, a click picks it.
--   Ctrl+right-click on any DisasterZone frame opens the sheet about that frame.
--   News, through the notification center (its bell, pop-ups and Settings > Notifications): DisasterZone hit a Lua
--   error (Tell Tsumil, the error attached); your feedback is in a release you have; somebody answered your feedback.
--   Without the notification center they are this file's own pop-ups (one at a time, never in combat).
local addonName, ns = ...

local Sheet = ns:NewModule("FeedbackSheet")

local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local SHEET_W, SHEET_H = 470, 478
local CW = SHEET_W - 30          -- the content's width inside the window
local TILE_H = 72
local BOX_H = 92
local GOLD = { 1, 0.82, 0 }

local PLACEHOLDER = {
    bug = "What happened, and what did you expect instead?",
    idea = "What would you like DisasterZone to do?",
    change = "What should work differently, and why?",
    love = "What do you enjoy? Tsumil reads every one.",
}

local sheet, pointer, toast
local draft = { kind = nil, about = nil, ref = nil }

local function UI() return ns.UI end
local function FB() return ns.Feedback end
local function grey(text) return "|cff808080" .. tostring(text) .. "|r" end

local function newText(parent, font, wrap)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(wrap and true or false)
    return fs
end

---------------------------------------------------------------------------
-- What a frame is: "Raids › Award to" (the page or window, then the button / text under the mouse)
---------------------------------------------------------------------------

-- Standalone DisasterZone windows by global name (others: their title, else their name without "DisasterZone").
local WINDOW_NAMES = {
    DisasterZoneRollFrame = "Roll popup", DisasterZoneDropPanel = "Drop panel", DisasterZoneSessionBar = "Session bar",
    DisasterZoneSwingTimer = "Swing timer", DisasterZoneRunToast = "Dungeon pop-up",
    DisasterZoneStrategyReminder = "Strategy reminder", DisasterZoneEventTracker = "Event tracker",
}

local function OwnText(f)
    if f.GetText and f:GetObjectType() ~= "EditBox" then
        local t = f:GetText()
        if type(t) == "string" and t ~= "" then return t end
    end
    for _, r in ipairs({ f:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "FontString" and r:IsVisible() then
            local t = r:GetText()
            if type(t) == "string" and t ~= "" then return t end
        end
    end
    return nil
end

local function Plain(t)
    t = tostring(t or ""):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")
    t = t:gsub("\n", " "):gsub("%s+", " ")
    return ns.Util.Trim(t)
end

-- The top window a frame sits in and a name for it.
local function WindowOf(f)
    local top, cur = f, f
    while cur do
        local name = cur.GetName and cur:GetName()
        if name == "DisasterZoneMainFrame" then
            local MF = ns.MainFrame
            local key = MF and MF:GetSelectedTab()
            return cur, key and MF:GetPageLabel(key) or "DisasterZone", key
        end
        if name and WINDOW_NAMES[name] then return cur, WINDOW_NAMES[name] end
        top = cur
        local parent = cur.GetParent and cur:GetParent()
        if not parent or parent == UIParent then break end
        cur = parent
    end
    local name = top.GetName and top:GetName()
    if name and name:find("^DisasterZone") then
        local title = top.titleText and top.titleText:GetText()
        if type(title) == "string" and title ~= "" then return top, Plain(title) end
        return top, (name:gsub("^DisasterZone", ""):gsub("(%l)(%u)", "%1 %2"))
    end
    return top, nil
end

-- "Page › element" for a frame, and the page ref (Share) when it is in the main window.
function Sheet:Describe(f)
    if not f then return nil end
    local win, place, pageKey = WindowOf(f)
    if not place then return nil end
    local what
    local cur = f
    for _ = 1, 4 do
        if not cur or cur == win then break end
        local t = OwnText(cur)
        if t then what = Plain(t) break end
        cur = cur:GetParent()
    end
    if what and #what > 34 then what = what:sub(1, 32):gsub("%s+%S*$", "") .. "..." end
    local about = place
    if what and what ~= "" and what ~= place then about = place .. " › " .. what end
    local ref = pageKey and ns.Share and ns.Share.CurrentRef and ns.Share:CurrentRef() or nil
    return about:sub(1, 60), ref
end

-- The deepest shown DisasterZone frame under the mouse (skipping the sheet and the pointer).
local function Roots()
    local out = {}
    local mf = _G.DisasterZoneMainFrame
    if mf and mf:IsVisible() then out[#out + 1] = mf end
    for name in pairs(WINDOW_NAMES) do
        local f = _G[name]
        if f and f.IsVisible and f:IsVisible() then out[#out + 1] = f end
    end
    return out
end

local function Deepest(f, depth)
    if depth > 30 then return f end
    local best
    for _, ch in ipairs({ f:GetChildren() }) do
        if ch ~= sheet and ch ~= pointer and ch:IsVisible() and ch:IsMouseOver() then
            local w, h = ch:GetSize()
            if (w or 0) >= 6 and (h or 0) >= 6 then best = ch end
        end
    end
    if best then return Deepest(best, depth + 1) end
    return f
end

function Sheet:FrameUnderMouse()
    for _, root in ipairs(Roots()) do
        if root:IsMouseOver() then return Deepest(root, 0) end
    end
    return nil
end

---------------------------------------------------------------------------
-- Point at it: a mode, not a wall. The form steps aside and DisasterZone works as usual (left-clicks open pages,
-- tabs, raids...), whatever is under the mouse lights up gold with its name, and a right-click picks it. A bar at the
-- top of the screen says so and has Cancel; Escape cancels too.
---------------------------------------------------------------------------

local function StopPointing(picked)
    if not pointer then return end
    pointer:Hide()
    pointer.box:Hide()
    pointer.bar:Hide()
    if sheet then
        if picked then
            local about, ref = Sheet:Describe(picked)
            if about then draft.about, draft.ref = about, ref end
        end
        sheet:Show()
        sheet:Raise()
        Sheet:Layout()
    end
end
Sheet.StopPointing = StopPointing

local function BuildPointer()
    -- (no mouse: clicks go through to DisasterZone)
    local p = CreateFrame("Frame", "DisasterZoneFeedbackPointer", UIParent)
    p:SetAllPoints(UIParent)
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:EnableMouse(false)
    p.box = CreateFrame("Frame", nil, p)
    p.box:SetFrameStrata("FULLSCREEN_DIALOG")
    p.box:EnableMouse(false)
    UI():AddEdges(p.box, "OVERLAY")
    UI():SetEdgeColor(p.box, 1, 0.82, 0, 1)
    p.box.fill = p.box:CreateTexture(nil, "ARTWORK")
    p.box.fill:SetAllPoints()
    p.box.fill:SetColorTexture(1, 0.82, 0, 0.12)
    p.box:Hide()
    p.tip = CreateFrame("Frame", nil, p, "BackdropTemplate")
    p.tip:EnableMouse(false)
    UI():StyleHud(p.tip)
    p.tip:SetSize(250, 40)
    p.tip.a = newText(p.tip, "GameFontNormal")
    p.tip.a:SetPoint("TOPLEFT", 10, -7)
    p.tip.a:SetWidth(230)
    p.tip.b = newText(p.tip, "GameFontHighlightSmall")
    p.tip.b:SetPoint("TOPLEFT", 10, -23)
    p.tip.b:SetText(grey("Right-click: pick it"))

    -- the bar at the top: what to do, and Cancel (it takes the mouse and Escape)
    local bar = CreateFrame("Frame", "DisasterZoneFeedbackPointerBar", UIParent, "BackdropTemplate")
    bar:SetSize(470, 40)
    bar:SetPoint("TOP", UIParent, "TOP", 0, -60)
    bar:SetFrameStrata("FULLSCREEN_DIALOG")
    bar:EnableMouse(true)
    UI():StyleHud(bar)
    bar.icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon:SetSize(18, 18)
    bar.icon:SetPoint("LEFT", 12, 0)
    bar.icon:SetTexture(UI().ICON_ATLAS)
    bar.icon:SetTexCoord(unpack(UI():IconCoords(UI().ICON.practice)))
    bar.icon:SetVertexColor(1, 0.82, 0)
    bar.a = newText(bar, "GameFontNormal")
    bar.a:SetPoint("TOPLEFT", 38, -7)
    bar.a:SetText("Point at it")
    bar.b = newText(bar, "GameFontHighlightSmall")
    bar.b:SetPoint("TOPLEFT", 38, -23)
    bar.b:SetText("Go to what you mean as usual, then right-click it.")
    bar.cancel = UI():CreateSleekButton(bar, "Cancel", 72, 22, function() StopPointing(nil) end)
    bar.cancel:SetPoint("RIGHT", -9, 0)
    bar:EnableKeyboard(true)
    bar:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            if self.SetPropagateKeyboardInput then self:SetPropagateKeyboardInput(false) end
            StopPointing(nil)
        elseif self.SetPropagateKeyboardInput then
            self:SetPropagateKeyboardInput(true)
        end
    end)
    bar:Hide()
    p.bar = bar

    p:SetScript("OnUpdate", function(self, dt)
        if InCombatLockdown and InCombatLockdown() then return StopPointing(nil) end
        self.t = (self.t or 0) + (dt or 0)
        local x, y = GetCursorPosition()
        local s = UIParent:GetEffectiveScale()
        self.tip:ClearAllPoints()
        self.tip:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 18, y / s + 14)
        if self.t < 0.08 then return end
        self.t = 0
        local f = Sheet:FrameUnderMouse()
        self.target = f
        if f then
            self.box:ClearAllPoints()
            self.box:SetPoint("TOPLEFT", f, "TOPLEFT", -2, 2)
            self.box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 2, -2)
            self.box:Show()
            self.tip.a:SetText((Sheet:Describe(f)) or "DisasterZone")
            self.tip:Show()
        else
            self.box:Hide()
            self.tip:Hide()
        end
    end)
    p:Hide()
    return p
end

function Sheet:StartPointing()
    if InCombatLockdown and InCombatLockdown() then return end
    pointer = pointer or BuildPointer()
    pointer.t = 1
    pointer:Show()          -- (before the form hides: its OnHide keeps the draft while pointing)
    pointer.bar:Show()
    if sheet then sheet:Hide() end
    -- the main window comes up where it was, so there is something to point at
    if ns.MainFrame and not ns.MainFrame:IsShown() then ns.MainFrame:Open() end
end

function Sheet:IsPointing() return pointer ~= nil and pointer:IsShown() end

-- While pointing: a right-click on DisasterZone picks what is under the mouse (its own menu, if any, is closed).
local function PickUnderMouse()
    local f = Sheet:FrameUnderMouse()
    if not f then return false end
    C_Timer.After(0, function() if UI().CloseMenus then UI():CloseMenus() end end)
    StopPointing(f)
    return true
end
Sheet.PickUnderMouse = PickUnderMouse

---------------------------------------------------------------------------
-- The sheet
---------------------------------------------------------------------------

local function NewTile(parent, kind, onClick)
    local info = FB().KIND_INFO[kind]
    local c = info.color
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(floor((CW - 3 * 8) / 4), TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.black = t:CreateTexture(nil, "ARTWORK", nil, 0)
    t.black:SetSize(32, 32)
    t.black:SetPoint("TOP", 0, -8)
    t.black:SetColorTexture(0, 0, 0, 1)
    t.icon = t:CreateTexture(nil, "ARTWORK", nil, 1)
    t.icon:SetSize(30, 30)
    t.icon:SetPoint("CENTER", t.black)
    t.icon:SetTexture(info.icon)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.label:SetPoint("TOP", t.black, "BOTTOM", 0, -5)
    t.label:SetWidth(t:GetWidth() - 8)
    t.label:SetText(({ bug = "Something\nbroke", idea = "I have\nan idea", change = "Change\nsomething",
        love = "I love\nthis" })[kind])
    t.kind = kind
    function t:Paint()
        local on = draft.kind == kind
        local dim = draft.kind ~= nil and not on and not self.hovered
        self.bg:SetColorTexture(c[1], c[2], c[3], on and 0.16 or (self.hovered and 0.09 or 0.03))
        UI():SetEdgeColor(self, c[1], c[2], c[3], on and 0.95 or (self.hovered and 0.6 or 0.22))
        self.icon:SetDesaturated(dim)
        self.icon:SetVertexColor(dim and 0.65 or 1, dim and 0.65 or 1, dim and 0.65 or 1)
        if on then self.label:SetTextColor(c[1], c[2], c[3])
        elseif dim then self.label:SetTextColor(0.62, 0.62, 0.62)
        else self.label:SetTextColor(0.9, 0.9, 0.9) end
    end
    t:SetScript("OnEnter", function(self) self.hovered = true; self:Paint() end)
    t:SetScript("OnLeave", function(self) self.hovered = false; self:Paint() end)
    t:SetScript("OnClick", function() onClick(kind) end)
    return t
end

local function ClassName(cl)
    if not cl then return nil end
    return (ns.CLASS_NAMES and ns.CLASS_NAMES[cl]) or (cl:sub(1, 1) .. cl:sub(2):lower())
end

-- What goes with the words: { text, kind } chips, the context, the error (a bug only).
local function AttachedParts()
    local F = FB()
    local c = F:Context()
    local chips = { { c.v } }
    if c.z then chips[#chips + 1] = { c.z } end
    local who = ns.Util.Trim((c.sp or "") .. " " .. (ClassName(c.cl) or ""))
    if who ~= "" then chips[#chips + 1] = { who } end
    local err = draft.kind == "bug" and F:RecentError() or nil
    if err then
        local mins = floor((time() - (err.at or time())) / 60)
        chips[#chips + 1] = { "Lua error, " .. (mins < 1 and "just now" or (mins .. " min ago")), "err" }
    end
    return c, chips, err
end

local function SimilarRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(CW - 20, 30)
    r.black = r:CreateTexture(nil, "ARTWORK", nil, 0)
    r.black:SetSize(20, 20)
    r.black:SetPoint("LEFT", 0, 0)
    r.black:SetColorTexture(0, 0, 0, 1)
    r.icon = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.icon:SetSize(18, 18)
    r.icon:SetPoint("CENTER", r.black)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.text = newText(r, "GameFontHighlightSmall", true)
    r.text:SetPoint("LEFT", 29, 0)
    r.text:SetWidth(CW - 20 - 29 - 86)
    if r.text.SetMaxLines then r.text:SetMaxLines(2) end
    r.btn = UI():CreateSleekButton(r, "Me too", 72, 22, function()
        local item = r.item
        if not item then return end
        FB():Vote(item.id, not item.voted)
        Sheet:Layout()
    end)
    r.btn:GetFontString():SetFontObject("GameFontHighlightSmall")
    r.btn:SetPoint("RIGHT", 0, 0)
    return r
end

local function Build()
    local f = UI():CreateWindow("DisasterZoneFeedbackSheet", "Tell Tsumil", SHEET_W, SHEET_H)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    local c = CreateFrame("Frame", nil, f)
    c:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -36)
    c:SetSize(CW, SHEET_H - 48)
    f.body = c
    local FUI = ns.FeedbackUI

    f.q = newText(c, "GameFontNormal")
    f.q:SetPoint("TOPLEFT", 0, 0)
    f.q:SetText("What is it?")
    -- the four kinds
    f.tiles = {}
    for i, kind in ipairs(FB().KINDS) do
        local t = NewTile(c, kind, function(k)
            draft.kind = k
            Sheet:Layout()
            f.edit:SetFocus()
        end)
        t:SetPoint("TOPLEFT", c, "TOPLEFT", (i - 1) * (t:GetWidth() + 8), -19)
        f.tiles[i] = t
    end

    -- the words
    local y = -(19 + TILE_H + 10)
    f.boxBg = c:CreateTexture(nil, "BACKGROUND")
    f.boxBg:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
    f.boxBg:SetSize(CW, BOX_H)
    f.boxBg:SetColorTexture(0.055, 0.055, 0.067, 0.92)
    f.boxEdge = CreateFrame("Frame", nil, c)
    f.boxEdge:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
    f.boxEdge:SetSize(CW, BOX_H)
    UI():AddEdges(f.boxEdge)
    UI():SetEdgeColor(f.boxEdge, 0.34, 0.34, 0.38, 0.9)
    f.scroll = CreateFrame("ScrollFrame", nil, c)
    f.scroll:SetPoint("TOPLEFT", c, "TOPLEFT", 8, y - 7)
    f.scroll:SetSize(CW - 16, BOX_H - 24)
    f.edit = CreateFrame("EditBox", nil, f.scroll)
    f.edit:SetMultiLine(true)
    f.edit:SetAutoFocus(false)
    f.edit:SetFontObject("ChatFontNormal")
    f.edit:SetWidth(CW - 16)
    f.edit:SetMaxLetters(400)
    f.scroll:SetScrollChild(f.edit)
    f.scroll:EnableMouse(true)
    f.scroll:SetScript("OnMouseDown", function() f.edit:SetFocus() end)
    f.edit:SetScript("OnCursorChanged", function(_, _, cy, _, ch)
        local top, view = f.scroll:GetVerticalScroll() or 0, f.scroll:GetHeight() or 0
        cy, ch = -(cy or 0), ch or 0
        if cy < top then f.scroll:SetVerticalScroll(cy) elseif cy + ch > top + view then
            f.scroll:SetVerticalScroll(cy + ch - view) end
    end)
    f.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.edit:SetScript("OnEditFocusGained", function() UI():SetEdgeColor(f.boxEdge, 1, 0.82, 0, 0.75) end)
    f.edit:SetScript("OnEditFocusLost", function() UI():SetEdgeColor(f.boxEdge, 0.34, 0.34, 0.38, 0.9) end)
    f.hint = newText(c, "GameFontDisable", true)
    f.hint:SetPoint("TOPLEFT", c, "TOPLEFT", 9, y - 8)
    f.hint:SetWidth(CW - 18)
    f.count = newText(c, "GameFontDisableSmall")
    f.count:SetPoint("BOTTOMRIGHT", f.boxEdge, "BOTTOMRIGHT", -8, 6)
    f.count:SetJustifyH("RIGHT")
    f.edit:SetScript("OnTextChanged", function(self)
        local n = #(self:GetText() or "")
        f.hint:SetShown(n == 0)
        f.count:SetText(n .. " / 400")
        f.err:SetText("")
        ns.Util.Debounce("feedback-similar", 0.4, function() Sheet:LayoutSimilar() end)
    end)
    y = y - BOX_H - 9

    -- about: a field (typed, or filled by Point at it)
    f.aboutLabel = newText(c, "GameFontNormalSmall")
    f.aboutLabel:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 5)
    f.aboutLabel:SetText("About")
    f.about = UI():CreateSleekEditBox(c, CW - 54 - 96, 22, "GameFontHighlightSmall")
    f.about:SetPoint("TOPLEFT", c, "TOPLEFT", 54, y)
    f.about:SetMaxLetters(60)
    f.about:SetTextColor(1, 1, 1)
    f.about:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        local t = ns.Util.Trim(self:GetText() or "")
        draft.about = t ~= "" and t or nil
        draft.ref = nil
        ns.Util.Debounce("feedback-similar", 0.4, function() Sheet:LayoutSimilar() end)
    end)
    f.about:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    UI():SetEditPlaceholder(f.about, "A page, a button, a window... or point at it")
    f.point = UI():CreateSleekButton(c, "Point at it", 88, 22, function() Sheet:StartPointing() end)
    f.point:GetFontString():SetFontObject("GameFontHighlightSmall")
    f.point:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, y)
    f.point:HookScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Point at it", "The form steps aside: go to the page, button or window you mean "
            .. "as usual, then right-click it. Tip: Ctrl+right-click anything in DisasterZone to start from it." },
            "ANCHOR_TOP")
    end)
    f.point:HookScript("OnLeave", function() GameTooltip:Hide() end)
    y = y - 30

    -- what goes with it
    f.sentLabel = newText(c, "GameFontNormalSmall")
    f.sentLabel:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 5)
    f.sentLabel:SetText("With it")
    f.withY = y
    f.withChips = {}
    y = y - 30

    -- the guild's items that sound the same
    f.simBox = CreateFrame("Frame", nil, c)
    f.simBox:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 2)
    f.simBox:SetSize(CW, 50)
    f.simBox.bg = f.simBox:CreateTexture(nil, "BACKGROUND")
    f.simBox.bg:SetAllPoints()
    f.simBox.bg:SetColorTexture(1, 1, 1, 0.03)
    UI():AddEdges(f.simBox, "BORDER")
    UI():SetEdgeColor(f.simBox, 1, 1, 1, 0.1)
    f.simTitle = newText(f.simBox, "GameFontNormalSmall")
    f.simTitle:SetPoint("TOPLEFT", 10, -8)
    f.sim = { SimilarRow(f.simBox), SimilarRow(f.simBox) }

    -- bottom: credit, buttons, and where it goes
    f.err = newText(c, "GameFontNormalSmall")
    f.err:SetTextColor(1, 0.35, 0.3)
    f.err:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 58)
    f.credit = UI():CreateCheckbox(c, "Name me in the changelog", function()
        local s = ns.db and ns.db.settings
        return not (s and s.feedbackAnon)
    end, function(on)
        local s = ns.db and ns.db.settings
        if s then s.feedbackAnon = (not on) or nil end
    end)
    f.credit:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", -4, 28)
    f.credit:HookScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Name me in the changelog", "When it makes it into a release, the line in the "
            .. "changelog says it came from you." }, "ANCHOR_TOP")
    end)
    f.credit:HookScript("OnLeave", function() GameTooltip:Hide() end)
    f.send = UI():CreateSleekButton(c, "Send", 84, 26, function() Sheet:Send() end, "primary")
    f.send:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 26)
    f.cancel = UI():CreateSleekButton(c, "Cancel", 84, 26, function() f:Hide() end)
    f.cancel:SetPoint("RIGHT", f.send, "LEFT", -8, 0)
    f.foot = newText(c, "GameFontDisableSmall", true)
    f.foot:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    f.foot:SetWidth(CW)
    f.foot:SetText("Everyone in the guild can see it. It reaches Tsumil even while Tsumil is offline: whoever is "
        .. "online carries it.")

    -- after Send
    f.done = CreateFrame("Frame", nil, f)
    f.done:SetAllPoints(c)
    f.done.check = f.done:CreateTexture(nil, "ARTWORK")
    f.done.check:SetSize(46, 46)
    f.done.check:SetPoint("TOP", 0, -50)
    f.done.check:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
    f.done.title = f.done:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.done.title:SetPoint("TOP", f.done.check, "BOTTOM", 0, -12)
    f.done.title:SetText("Sent")
    f.done.text = f.done:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.done.text:SetPoint("TOP", f.done.title, "BOTTOM", 0, -10)
    f.done.text:SetWidth(CW - 80)
    f.done.text:SetSpacing(3)
    f.done.steps = FUI.NewSteps(f.done)
    f.done.steps:SetPoint("TOP", f.done.text, "BOTTOM", 0, -26)
    f.done.steps:SetWidth(380)
    f.done.see = UI():CreateSleekButton(f.done, "See it", 90, 26, function()
        f:Hide()
        if ns.FeedbackUI then ns.FeedbackUI:Open("mine", f.sentId) end
    end, "primary")
    f.done.see:SetPoint("BOTTOM", f.done, "BOTTOM", -50, 50)
    f.done.close = UI():CreateSleekButton(f.done, "Close", 90, 26, function() f:Hide() end)
    f.done.close:SetPoint("LEFT", f.done.see, "RIGHT", 10, 0)
    f.done:Hide()

    f:HookScript("OnHide", function()
        if pointer and pointer:IsShown() then return end
        if f.done:IsShown() then
            f.done:Hide()
            f.body:Show()
            f.edit:SetText("")
            draft.kind, draft.about, draft.ref = nil, nil, nil
        end
    end)
    return f
end

function Sheet:LayoutSimilar()
    local f = sheet
    if not f or not f:IsShown() then return end
    local text = f.edit:GetText() or ""
    local items = #text >= 8 and FB():Similar(text, draft.about, 2) or {}
    f.simBox:SetShown(#items > 0)
    f.simTitle:SetText(#items == 1 and "Sounds like this one" or "Sounds like these")
    for i, r in ipairs(f.sim) do
        local item = items[i]
        r.item = item
        r:SetShown(item ~= nil)
        if item then
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f.simBox, "TOPLEFT", 10, -22 - (i - 1) * 32)
            local info = FB().KIND_INFO[item.kind]
            r.icon:SetTexture(info.icon)
            r.text:SetText(UI():SafeText(item.text) .. grey("  · " .. ns.Util.ShortName(item.author)
                .. (item.voteCount > 0 and (" +" .. item.voteCount) or "")))
            r.btn:SetText(item.voted and "You too" or "Me too")
            r.btn:SetKind(item.voted and "chosen" or "secondary")
        end
    end
    f.simBox:SetHeight(22 + #items * 32)
end

function Sheet:Layout()
    local f = sheet
    if not f then return end
    for _, t in ipairs(f.tiles) do t:Paint() end
    f.hint:SetText(draft.kind and PLACEHOLDER[draft.kind] or "Pick one above, then say it in a few words.")
    f.hint:SetShown((f.edit:GetText() or "") == "")
    f.count:SetText(#(f.edit:GetText() or "") .. " / 400")
    if not f.about:HasFocus() and (f.about:GetText() or "") ~= (draft.about or "") then
        f.about:SetText(draft.about or "")
    end
    local _, chips = AttachedParts()
    for _, ch in ipairs(f.withChips) do ch:Hide() end
    local x = 54
    for i, cdef in ipairs(chips) do
        local ch = f.withChips[i]
        if not ch then
            ch = ns.FeedbackUI.NewChip(f.body)
            ch:SetHeight(20)
            ch:EnableMouse(true)
            ch:SetScript("OnEnter", function(self)
                local ctx, _, err = AttachedParts()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Sent with your words", 1, 0.82, 0)
                GameTooltip:AddLine("So Tsumil knows where and on what it happened. Nothing else about you is sent.",
                    1, 1, 1, true)
                GameTooltip:AddDoubleLine("Version", ctx.v, 0.7, 0.7, 0.7, 1, 1, 1)
                if ctx.z then GameTooltip:AddDoubleLine("Where", ctx.z, 0.7, 0.7, 0.7, 1, 1, 1) end
                if ctx.sp then GameTooltip:AddDoubleLine("Spec", ctx.sp, 0.7, 0.7, 0.7, 1, 1, 1) end
                if ctx.p then GameTooltip:AddDoubleLine("Page open", ctx.p, 0.7, 0.7, 0.7, 1, 1, 1) end
                if err then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Lua error", 0.88, 0.42, 0.38)
                    GameTooltip:AddLine(err.m, 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            ch:SetScript("OnLeave", function() GameTooltip:Hide() end)
            f.withChips[i] = ch
        end
        ch:Set(cdef[1], cdef[2])
        if x + ch:GetWidth() > CW then break end
        ch:ClearAllPoints()
        ch:SetPoint("TOPLEFT", f.body, "TOPLEFT", x, f.withY - 1)
        ch:Show()
        x = x + ch:GetWidth() + 6
    end
    self:LayoutSimilar()
end

-- Opens the sheet. opts: { kind, text, about, ref } (anything given is filled in).
function Sheet:Open(opts)
    opts = opts or {}
    sheet = sheet or Build()
    if sheet.done:IsShown() then
        sheet.done:Hide()
        sheet.body:Show()
        sheet.edit:SetText("")
    end
    if opts.kind then draft.kind = opts.kind end
    if opts.about then draft.about, draft.ref = opts.about, opts.ref end
    if opts.text then sheet.edit:SetText(opts.text) end
    sheet.err:SetText("")
    sheet:Show()
    sheet:Raise()
    self:Layout()
    if draft.kind then sheet.edit:SetFocus() end
end

function Sheet:IsOpen() return sheet ~= nil and sheet:IsShown() end
function Sheet:GetFrame() return sheet end
function Sheet:GetDraft() return draft end

function Sheet:Send()
    local f = sheet
    if not f then return end
    if not draft.kind then
        f.err:SetText("Pick what it is first: one of the four at the top.")
        return
    end
    local F = FB()
    local err = draft.kind == "bug" and F:RecentError() or nil
    local s = ns.db and ns.db.settings
    local id, why = F:Submit(draft.kind, f.edit:GetText(), { about = draft.about, ref = draft.ref, err = err,
        anon = s and s.feedbackAnon or nil })
    if not id then
        f.err:SetText((why or "Could not send it."):gsub("^%l", string.upper))
        return
    end
    if ns.FeedbackUI then ns.FeedbackUI:MarkSeen(F:Get(id)) end
    f.sentId = id
    f.body:Hide()
    f.done:Show()
    local online = ns.Guild and ns.Guild.GetOnlineMembers and #ns.Guild:GetOnlineMembers() or 1
    f.done.text:SetText((online > 1 or F.DemoOn()) and "Thanks! It's on its way to Tsumil through the guild. Follow it "
        .. "under Feedback > Yours." or "Thanks! It's saved, and goes out as soon as guildmates come online. Follow "
        .. "it under Feedback > Yours.")
    f.done.steps:Set({
        { text = "Sent", date = "now", st = "done" }, { text = "Tsumil has it", st = "now" },
        { text = "Planned", st = "todo" }, { text = draft.kind == "bug" and "Fixed" or "In a release", st = "todo" },
    }, 380)
end

---------------------------------------------------------------------------
-- Pop-ups
---------------------------------------------------------------------------

local queue = {}

local function BuildToast()
    local t = CreateFrame("Button", "DisasterZoneFeedbackToast", UIParent)
    t:SetSize(372, 74)
    t:SetPoint("TOP", UIParent, "TOP", 0, -150)
    t:SetFrameStrata("DIALOG")
    t:SetClampedToScreen(true)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(0.043, 0.043, 0.051, 0.95)
    UI():AddEdges(t, "BORDER")
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(34, 34)
    t.icon:SetPoint("LEFT", 12, 0)
    t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    t.t1 = newText(t, "GameFontNormal")
    t.t1:SetPoint("TOPLEFT", 56, -12)
    t.t1:SetWidth(204)
    t.t2 = newText(t, "GameFontHighlightSmall", true)
    t.t2:SetPoint("TOPLEFT", t.t1, "BOTTOMLEFT", 0, -4)
    t.t2:SetWidth(204)
    if t.t2.SetMaxLines then t.t2:SetMaxLines(3) end
    t.btn = UI():CreateSleekButton(t, "", 92, 24, function()
        local fn = t.fn
        t:Hide()
        if fn then fn() end
    end, "primary")
    t.btn:SetPoint("RIGHT", -12, 0)
    t.x = UI():CreateIconButton(t, 16, "Interface\\Buttons\\UI-StopButton", nil, function() t:Hide() end)
    t.x:SetPoint("TOPRIGHT", -3, -3)
    t:SetScript("OnUpdate", function(self, dt)
        if self:IsMouseOver() then return end
        self.left = (self.left or 12) - (dt or 0)
        if self.left <= 0 then self:Hide() end
    end)
    t:SetScript("OnHide", function() C_Timer.After(0.5, function() Sheet:NextToast() end) end)
    t:Hide()
    return t
end

local function InCombat() return InCombatLockdown and InCombatLockdown() end

function Sheet:NextToast()
    if (toast and toast:IsShown()) or #queue == 0 or InCombat() then return end
    local q = table.remove(queue, 1)
    toast = toast or BuildToast()
    toast.icon:SetTexture(q.icon)
    UI():SetEdgeColor(toast, q.color[1], q.color[2], q.color[3], 0.6)
    toast.t1:SetText(q.title)
    toast.t2:SetText(q.text)
    toast.btn:SetText(q.button)
    toast.fn = q.fn
    toast.left = q.seconds or 12
    toast:Show()
    if PlaySound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then PlaySound(SOUNDKIT.TELL_MESSAGE) end
end

function Sheet:Toast(q)
    q.color = q.color or GOLD
    queue[#queue + 1] = q
    self:NextToast()
end

function Sheet:GetToast() return toast end
function Sheet:GetQueue() return queue end

-- The notification center (Core/Notify.lua) carries feedback's news: its bell, pop-ups (queued, never in combat) and
-- the player's own choices in Settings > Notifications. Three kinds:
--   feedbackAnswer   a source: my items with news (staff answered, a status) until I look at them on the page
--   feedbackShipped  posted at login: lines of an installed release that credit me
--   feedbackError    posted when DisasterZone hits a Lua error: Tell Tsumil (the error goes with it)
-- Without the notification center, the same go out as this file's own pop-ups.
local function N() return ns.Notify end

local function OpenItem(id) if ns.FeedbackUI then ns.FeedbackUI:Open("mine", id) end end

-- What's new on one of my items: who, and what they said or set.
local function News(item)
    local F = FB()
    local last
    for _, r in ipairs(item.replies) do if r.staff then last = r end end
    local who = last and last.author or item.stateBy
    local text = last and ("\"" .. last.text .. "\"") or ("It's now: " .. (F.STATE_LABEL[item.state] or "open") .. ".")
    return who, text, last and last.at or item.stateAt
end

local function AnswerItems()
    local F, FUI = FB(), ns.FeedbackUI
    local out = {}
    -- (in demo mode too: the notification center keeps demo items in memory, never in the saved variables)
    if not (F and FUI) then return out end
    for _, item in ipairs(F:List({ mine = true }, "new")) do
        if item.mine and FUI:HasNews(item) then
            local who, text, at = News(item)
            out[#out + 1] = { key = item.id, title = (who and ns.Util.ShortName(who) or "Tsumil") .. " answered your "
                .. "feedback", text = UI():SafeText(text), from = who, time = at,
                short = "Answer: " .. (item.text or ""):sub(1, 30) }
        end
    end
    return out
end

local function RegisterKinds()
    local Nf = N()
    if not (Nf and Nf.RegisterKind) or Sheet.kindsRegistered then return end
    Sheet.kindsRegistered = true
    local F = FB()
    local gold = { 1, 0.82, 0 }
    Nf:RegisterKind("feedbackAnswer", {
        section = "Feedback", page = "feedback", icon = 42, color = gold,
        label = "Answers to your feedback", desc = "Tsumil or an officer answered your feedback, or set where it stands.",
        needsYou = false, popup = true, sound = true,
        open = function(it) OpenItem(it.key) end,
    })
    Nf:RegisterSource("feedbackAnswer", AnswerItems, { "FEEDBACK_UPDATED" })
    Nf:RegisterKind("feedbackShipped", {
        section = "Feedback", page = "changelog", icon = 25, color = { 0.45, 0.85, 0.45 },
        label = "Your feedback in a release", desc = "Something you asked for (or said me too to) is in a release you have.",
        needsYou = false, popup = true, sound = true,
        open = function(it) if ns.ChangelogUI then ns.ChangelogUI:Open(it.data and it.data.version) end end,
    })
    Nf:RegisterKind("feedbackError", {
        section = "Feedback", page = "feedback", icon = 42, color = F.KIND_INFO.bug.color,
        label = "DisasterZone errors", desc = "DisasterZone hit a Lua error: tell Tsumil what you were doing.",
        needsYou = false, popup = true, sound = false,
        open = function() Sheet:Open({ kind = "bug" }) end,
        actions = function() return { { text = "Tell Tsumil", primary = true, fn = function() Sheet:Open({ kind = "bug" })
            end } } end,
    })
end

local function OnError(e)
    if Sheet:IsOpen() then return end
    local Nf = N()
    if Nf and Nf.Post and Sheet.kindsRegistered then
        Nf:Post("feedbackError", { key = e and e.m or "error", title = "DisasterZone hit an error",
            text = "Tell Tsumil what you were doing? The error goes with it.", expires = time() + 1800 })
        return
    end
    Sheet:Toast({
        icon = FB().KIND_INFO.bug.icon, color = FB().KIND_INFO.bug.color,
        title = "DisasterZone hit an error",
        text = "Tell Tsumil what you were doing? The error goes with it.",
        button = "Tell Tsumil", seconds = 15,
        fn = function() Sheet:Open({ kind = "bug" }) end,
    })
end

-- (without the notification center: one pop-up per new answer, compared with the last one shown)
local lastAnswer = {}
local function CheckAnswers()
    if Sheet.kindsRegistered then return end
    local shown = 0
    for _, a in ipairs(AnswerItems()) do
        if lastAnswer[a.key] ~= a.text and shown < 2 then
            shown = shown + 1
            lastAnswer[a.key] = a.text
            local item = FB():Get(a.key)
            Sheet:Toast({ icon = item and FB().KIND_INFO[item.kind].icon, title = a.title, text = a.text,
                button = "See it", fn = function() OpenItem(a.key) end })
        end
    end
end

local function CheckShipped()
    local F = FB()
    local lines = F and not F.DemoOn() and F:UntoldShipped() or {}
    if #lines == 0 then return end
    F:MarkToldShipped()
    local first = lines[1]
    local text = type(first.line) == "table" and first.line[1] or ""
    local title = #lines == 1 and ("Yours is in " .. first.version) or (#lines .. " of yours are in " .. first.version)
    local Nf = N()
    if Nf and Nf.Post and Sheet.kindsRegistered then
        Nf:Post("feedbackShipped", { key = first.version, title = title, text = UI():SafeText(text),
            data = { version = first.version } })
        return
    end
    Sheet:Toast({
        icon = F.KIND_INFO[(type(first.line) == "table" and first.line.k) or "idea"].icon,
        color = { 0.45, 0.85, 0.45 }, title = title, text = UI():SafeText(text), button = "See it", seconds = 20,
        fn = function() if ns.ChangelogUI then ns.ChangelogUI:Open(first.version) end end,
    })
end

---------------------------------------------------------------------------
-- Ctrl+right-click on anything in DisasterZone
---------------------------------------------------------------------------

local function OnGlobalMouseDown(_, button)
    if button ~= "RightButton" or InCombat() then return end
    if pointer and pointer:IsShown() then
        PickUnderMouse()
        return
    end
    if not (IsControlKeyDown and IsControlKeyDown()) then return end
    local f = Sheet:FrameUnderMouse()
    if not f then return end
    local about, ref = Sheet:Describe(f)
    if not about then return end
    -- the right-click may open the frame's own menu as well: close it once it is up
    C_Timer.After(0, function() if UI().CloseMenus then UI():CloseMenus() end end)
    Sheet:Open({ about = about, ref = ref })
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Sheet:OnInit()
    ns:On("FEEDBACK_ERROR", OnError)
    ns:On("FEEDBACK_UPDATED", function()
        if sheet and sheet:IsShown() then ns.Util.Debounce("feedback-sheet", 0.2, function() Sheet:LayoutSimilar() end) end
        ns.Util.Debounce("feedback-answers", 1, CheckAnswers)
    end)
    ns:RegisterSlash("bug", function(rest)
        rest = ns.Util.Trim(rest or "")
        Sheet:Open({ kind = "bug", text = rest ~= "" and rest or nil })
    end, "tell Tsumil something broke (the last Lua error goes with it)")
    ns:RegisterSlash("idea", function(rest)
        rest = ns.Util.Trim(rest or "")
        Sheet:Open({ kind = "idea", text = rest ~= "" and rest or nil })
    end, "send Tsumil an idea for DisasterZone")
end

function Sheet:OnLogin()
    RegisterKinds()
    ns:RegisterEvent("GLOBAL_MOUSE_DOWN", OnGlobalMouseDown)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Sheet:NextToast() end)
    -- after the login rush: what shipped since I last looked
    ns.Util.After(45, CheckShipped)
end

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
-- 1.4: the form is a tool window (UI:CreateLayout "tool": its banner over the body), its pop-ups are UI:Toast; the
-- kinds and the words on the shared surfaces (sleek tiles, icon tiles, inset cards), the chips are pills;
-- text on the type scale (UI:Text), colours from ns.Style.
local addonName, ns = ...

local Sheet = ns:NewModule("FeedbackSheet")
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat = table.concat

local BAN_H = S.BANNER.tool      -- the form's banner (the tool layout's)
local SHEET_W, SHEET_H = 470, 478 + BAN_H + S.GAP - 19
local DONE_H = 330                -- "Sent": the check down to the buttons (1.3.5's block, centred in the window)
local CW = SHEET_W - 30          -- the content's width inside the window
local TILE_H = 72
local BOX_H = 92
local GOLD = S.C.GOLD
local TOAST_KEY = "dz-feedback"  -- this file's pop-up (UI:Toast): one at a time

local PLACEHOLDER = {
    bug = "What happened, and what did you expect instead?",
    idea = "What would you like DisasterZone to do?",
    change = "What should work differently, and why?",
    love = "What do you enjoy? Every one is read.",
}

local sheet, pointer, toast
local draft = { kind = nil, about = nil, ref = nil }

local function UI() return ns.UI end
local function FB() return ns.Feedback end
local WRAP = { wrap = true }   -- (a wrapped text)

---------------------------------------------------------------------------
-- What a frame is: "Raids › Award to" (the page or window, then the button / text under the mouse)
---------------------------------------------------------------------------

-- Standalone DisasterZone windows by global name (others: their title, else their name without "DisasterZone").
local WINDOW_NAMES = {
    DisasterZoneRollFrame = "Roll popup", DisasterZoneDropPanel = "Drop panel", DisasterZoneSessionBar = "Session bar",
    DisasterZoneSwingTimer = "Swing timer", DisasterZoneShotTimer = "Shot timer", DisasterZoneRunToast = "Dungeon pop-up",
    DisasterZoneToast1 = "Pop-up", DisasterZoneToast2 = "Pop-up", DisasterZoneToast3 = "Pop-up",
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
    UI():SetEdgeColor(p.box, GOLD[1], GOLD[2], GOLD[3], 1)
    p.box.fill = UI():Fill(p.box, { GOLD[1], GOLD[2], GOLD[3], 0.12 }, "ARTWORK")
    p.box:Hide()
    p.tip = CreateFrame("Frame", nil, p, "BackdropTemplate")
    p.tip:EnableMouse(false)
    UI():StyleHud(p.tip)
    p.tip:SetSize(250, 40)
    p.tip.a = UI():Text(p.tip, "emph", "GOLD")
    p.tip.a:SetPoint("TOPLEFT", 10, -7)
    p.tip.a:SetWidth(230)
    p.tip.b = UI():Text(p.tip, "small", "TEXT")
    p.tip.b:SetPoint("TOPLEFT", 10, -23)
    p.tip.b:SetText(S:Wrap("DIM", "Right-click: pick it"))

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
    bar.icon:SetVertexColor(S:Color("GOLD"))
    bar.a = UI():Text(bar, "emph", "GOLD")
    bar.a:SetPoint("TOPLEFT", 38, -7)
    bar.a:SetText("Point at it")
    bar.b = UI():Text(bar, "small", "TEXT")
    bar.b:SetPoint("TOPLEFT", 38, -23)
    bar.b:SetText("Go to what you mean as usual, then right-click it.")
    bar.cancel = UI():CreateSleekButton(bar, "Cancel", 72, S.BTN_H, function() StopPointing(nil) end)
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

-- A kind to pick: the kind's icon (the shared icon tile) and its words on the sleek surface (UI:PaintSleek); its
-- edge and words in the kind's colour while picked or under the mouse (the Feedback page's tiles).
local function NewTile(parent, kind, onClick)
    local info = FB().KIND_INFO[kind]
    local c = info.color
    local t = CreateFrame("Button", nil, parent)
    t:SetSize(floor((CW - 3 * 8) / 4), TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER")
    t.tile = UI():CreateIconTile(t, 30)
    t.tile:SetPoint("TOP", 0, -9)
    t.tile:Set(info.icon)
    t.icon = t.tile.tex
    t.label = UI():Text(t, "small", "TEXT", { justify = "CENTER" })
    t.label:SetPoint("TOP", t.tile, "BOTTOM", 0, -6)
    t.label:SetWidth(t:GetWidth() - 8)
    t.label:SetText(({ bug = "Something\nbroke", idea = "I have\nan idea", change = "Change\nsomething",
        love = "I love\nthis" })[kind])
    t.kind = kind
    function t:Paint()
        local on = draft.kind == kind
        local dim = draft.kind ~= nil and not on and not self.hovered
        UI():PaintSleek(self, "secondary", self.hovered or on)
        UI():SetEdgeColor(self, c[1], c[2], c[3], on and 0.95 or (self.hovered and 0.6 or 0.22))
        self.icon:SetDesaturated(dim)
        self.icon:SetVertexColor(dim and 0.65 or 1, dim and 0.65 or 1, dim and 0.65 or 1)
        if on then self.label:SetTextColor(c[1], c[2], c[3])
        elseif dim then self.label:SetTextColor(S:Color("SUB"))
        else self.label:SetTextColor(S:Color("TEXT")) end
    end
    t:SetScript("OnEnter", function(self) self.hovered = true; self:Paint() end)
    t:SetScript("OnLeave", function(self) self.hovered = false; self:Paint() end)
    t:SetScript("OnClick", function() onClick(kind) end)
    return t
end

-- What goes with the words: { text, kind } chips, the context, the error (a bug only).
local function AttachedParts()
    local F = FB()
    local c = F:Context()
    local chips = { { c.v } }
    if c.z then chips[#chips + 1] = { c.z } end
    local who = ns.Util.Trim((c.sp or "") .. " " .. (ns.ClassName(c.cl) or ""))
    if who ~= "" then chips[#chips + 1] = { who } end
    local err = draft.kind == "bug" and F:RecentError() or nil
    if err then
        local mins = floor((time() - (err.at or time())) / 60)
        chips[#chips + 1] = { "Lua error, " .. (mins < 1 and "just now" or (mins .. " min ago")), "err" }
    end
    return c, chips, err
end

-- One of the guild's items that sound the same: its kind's icon (the shared icon tile), its words, Me too.
local function SimilarRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(CW - 20, 30)
    r.tile = UI():CreateIconTile(r, 18)
    r.tile:SetPoint("LEFT", 1, 0)
    r.icon = r.tile.tex
    r.text = UI():Text(r, "small", "TEXT", WRAP)
    r.text:SetPoint("LEFT", 29, 0)
    r.text:SetWidth(CW - 20 - 29 - 86)
    if r.text.SetMaxLines then r.text:SetMaxLines(2) end
    r.btn = UI():CreateSleekButton(r, "Me too", 72, S.BTN_H, function()
        local item = r.item
        if not item then return end
        FB():Vote(item.id, not item.voted)
        Sheet:Layout()
    end)
    r.btn:SetPoint("RIGHT", 0, 0)
    return r
end

local function Build()
    local f = UI():CreateWindow("DisasterZoneFeedbackSheet", "Send feedback", SHEET_W, SHEET_H)
    f:SetFrameStrata("DIALOG")
    f:Hide()
    -- a tool window: the strip banner asks what it is, the body holds the form (or, after Send, where it goes)
    local L = UI():CreateLayout("tool", f, { width = SHEET_W, pad = 15, top = 21, bottom = 12,
        banner = { size = "tool", icon = "notes", title = "What is it?" } })
    f.layout = L
    local c = L.body
    c:SetSize(CW, SHEET_H - 48 - BAN_H - S.GAP + 19)
    f.body = c
    f.q = L.banner.title
    local FUI = ns.FeedbackUI

    -- the four kinds
    f.tiles = {}
    for i, kind in ipairs(FB().KINDS) do
        local t = NewTile(c, kind, function(k)
            draft.kind = k
            Sheet:Layout()
            f.edit:SetFocus()
        end)
        t:SetPoint("TOPLEFT", c, "TOPLEFT", (i - 1) * (t:GetWidth() + 8), 0)
        f.tiles[i] = t
    end

    -- the words
    local y = -(TILE_H + 10)
    -- (an inset card, its edge strong, gold while typing: the fields' look)
    f.boxEdge = UI():CreateCard(c, { tone = "inset", pad = 0 })
    f.boxEdge:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y)
    f.boxEdge:SetSize(CW, BOX_H)
    UI():SetEdgeColor(f.boxEdge, S:Color("EDGE_STRONG"))
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
    f.edit:SetScript("OnEditFocusGained", function() UI():SetEdgeColor(f.boxEdge, S:Color("EDGE_FOCUS")) end)
    f.edit:SetScript("OnEditFocusLost", function() UI():SetEdgeColor(f.boxEdge, S:Color("EDGE_STRONG")) end)
    -- (the placeholder and the count on the card: over its fill, under the words typed)
    f.hint = UI():Text(f.boxEdge, "emph", "DIM", WRAP)
    f.hint:SetPoint("TOPLEFT", c, "TOPLEFT", 9, y - 8)
    f.hint:SetWidth(CW - 18)
    f.count = UI():Text(f.boxEdge, "small", "DIM")
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
    f.aboutLabel = UI():Text(c, "small", "GOLD")
    f.aboutLabel:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 5)
    f.aboutLabel:SetText("About")
    f.about = UI():CreateSleekEditBox(c, CW - 54 - 96, S.BTN_H, "GameFontHighlightSmall")
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
    f.point = UI():CreateSleekButton(c, "Point at it", 88, S.BTN_H, function() Sheet:StartPointing() end)
    f.point:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, y)
    f.point:HookScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Point at it", "The form steps aside: go to the page, button or window you mean "
            .. "as usual, then right-click it. Tip: Ctrl+right-click anything in DisasterZone to start from it." },
            "ANCHOR_TOP")
    end)
    f.point:HookScript("OnLeave", function() GameTooltip:Hide() end)
    y = y - 30

    -- what goes with it
    f.sentLabel = UI():Text(c, "small", "GOLD")
    f.sentLabel:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 5)
    f.sentLabel:SetText("With it")
    f.withY = y
    f.withChips = {}
    y = y - 30

    -- the guild's items that sound the same
    f.simBox = UI():CreateCard(c, { tone = "inset", pad = 0 })
    f.simBox:SetPoint("TOPLEFT", c, "TOPLEFT", 0, y - 2)
    f.simBox:SetSize(CW, 50)
    f.simTitle = UI():Text(f.simBox, "caps", "GOLD")
    f.simTitle:SetPoint("TOPLEFT", 10, -8)
    f.sim = { SimilarRow(f.simBox), SimilarRow(f.simBox) }

    -- bottom: credit, buttons, and where it goes
    f.err = UI():Text(c, "small", "BAD")
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
    f.send = UI():CreateSleekButton(c, "Send", 84, S.BTN_H, function() Sheet:Send() end, "primary")
    f.send:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 26)
    f.cancel = UI():CreateSleekButton(c, "Cancel", 84, S.BTN_H, function() f:Hide() end)
    f.cancel:SetPoint("RIGHT", f.send, "LEFT", -8, 0)
    f.foot = UI():Text(c, "small", "DIM", WRAP)
    f.foot:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
    f.foot:SetWidth(CW)
    f.foot:SetText("Everyone in the guild can see it. It reaches the developer even while offline: whoever is "
        .. "online carries it.")

    -- after Send
    f.done = CreateFrame("Frame", nil, f)
    f.done:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -36)
    f.done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -15, 12)
    -- (check, words, steps and buttons as one block in the middle: the window is taller than the block, for the
    -- form's banner)
    f.done.block = CreateFrame("Frame", nil, f.done)
    f.done.block:SetSize(CW, DONE_H)
    f.done.block:SetPoint("CENTER", f.done, "CENTER", 0, 0)
    f.done.check = f.done:CreateTexture(nil, "ARTWORK")
    f.done.check:SetSize(46, 46)
    f.done.check:SetPoint("TOP", f.done.block, "TOP", 0, 0)
    f.done.check:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
    f.done.title = UI():Text(f.done, "page", "GOLD", { justify = "CENTER" })
    f.done.title:SetPoint("TOP", f.done.check, "BOTTOM", 0, -12)
    f.done.title:SetText("Sent")
    f.done.text = UI():Text(f.done, "emph", "TEXT", { justify = "CENTER", wrap = true })
    f.done.text:SetPoint("TOP", f.done.title, "BOTTOM", 0, -10)
    f.done.text:SetWidth(CW - 80)
    f.done.text:SetSpacing(3)
    f.done.steps = FUI.NewSteps(f.done)
    f.done.steps:SetPoint("TOP", f.done.text, "BOTTOM", 0, -26)
    f.done.steps:SetWidth(380)
    f.done.see = UI():CreateSleekButton(f.done, "See it", 90, S.BTN_H, function()
        f:Hide()
        if ns.FeedbackUI then ns.FeedbackUI:Open("mine", f.sentId) end
    end, "primary")
    f.done.see:SetPoint("BOTTOM", f.done.block, "BOTTOM", -50, 0)
    f.done.close = UI():CreateSleekButton(f.done, "Close", 90, S.BTN_H, function() f:Hide() end)
    f.done.close:SetPoint("LEFT", f.done.see, "RIGHT", 10, 0)
    f.done:Hide()

    f:HookScript("OnHide", function()
        if pointer and pointer:IsShown() then return end
        if f.done:IsShown() then
            Sheet:ShowForm(true)
            f.edit:SetText("")
            draft.kind, draft.about, draft.ref = nil, nil, nil
        end
    end)
    return f
end

-- The form (with its banner) or, after Send, where it went (the whole window).
function Sheet:ShowForm(on)
    local f = sheet
    if not f then return end
    f.done:SetShown(not on)
    f.body:SetShown(on)
    f.layout.banner:SetShown(on)
end

function Sheet:LayoutSimilar()
    local f = sheet
    if not f or not f:IsShown() then return end
    local text = f.edit:GetText() or ""
    local items = #text >= 8 and FB():Similar(text, draft.about, 2) or {}
    f.simBox:SetShown(#items > 0)
    f.simTitle:SetText(UI():CapsText(#items == 1 and "Sounds like this one" or "Sounds like these"))
    for i, r in ipairs(f.sim) do
        local item = items[i]
        r.item = item
        r:SetShown(item ~= nil)
        if item then
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", f.simBox, "TOPLEFT", 10, -22 - (i - 1) * 32)
            local info = FB().KIND_INFO[item.kind]
            r.icon:SetTexture(info.icon)
            r.text:SetText(UI():SafeText(item.text) .. S:Wrap("DIM", "  · " .. ns.Util.ShortName(item.author)
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
            ch = ns.FeedbackUI.NewContextPill(f.body)
            ch:EnableMouse(true)
            ch:SetScript("OnEnter", function(self)
                local ctx, _, err = AttachedParts()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine("Sent with your words", S:RGB("GOLD"))
                GameTooltip:AddLine("So the developer knows where and on what it happened. Nothing else about you is sent.",
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
        self:ShowForm(true)
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
    self:ShowForm(false)
    local online = ns.Guild and ns.Guild.GetOnlineMembers and #ns.Guild:GetOnlineMembers() or 1
    f.done.text:SetText((online > 1 or F.DemoOn()) and "Thanks! It's on its way to the developer through the guild. Follow it "
        .. "under Feedback > Yours." or "Thanks! It's saved, and goes out as soon as guildmates come online. Follow "
        .. "it under Feedback > Yours.")
    f.done.steps:Set({
        { text = "Sent", date = "now", st = "done" }, { text = "Received", st = "now" },
        { text = "Planned", st = "todo" }, { text = draft.kind == "bug" and "Fixed" or "In a release", st = "todo" },
    }, 380)
end

---------------------------------------------------------------------------
-- Pop-ups
---------------------------------------------------------------------------

local queue = {}

local function InCombat() return InCombatLockdown and InCombatLockdown() end

-- The next waiting pop-up (UI:Toast, one of this file's at a time; never in combat): icon, title, text, its button.
function Sheet:NextToast()
    if UI():GetToast(TOAST_KEY) or #queue == 0 or InCombat() then return end
    -- (one still waiting in the shared queue is busy too: a second under its key would replace it there)
    for _, o in ipairs(UI():ToastQueue()) do
        if o.key == TOAST_KEY then return end
    end
    local q = table.remove(queue, 1)
    toast = UI():Toast({
        key = TOAST_KEY, kind = q.color, icon = q.icon, title = q.title, text = q.text, lines = 3,
        duration = q.seconds or 12, sound = "TELL_MESSAGE", width = 372,
        buttons = { { text = q.button, kind = "primary", onClick = function() if q.fn then q.fn() end end } },
        onClose = function() C_Timer.After(0.5, function() Sheet:NextToast() end) end,
    }) or toast
end

function Sheet:Toast(q)
    q.color = q.color or GOLD
    queue[#queue + 1] = q
    self:NextToast()
end

function Sheet:GetToast() return UI():GetToast(TOAST_KEY) or toast end
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
            out[#out + 1] = { key = item.id, title = (who and ns.Util.ShortName(who) or "The developer") .. " answered your "
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
    local gold = S.C.GOLD
    Nf:RegisterKind("feedbackAnswer", {
        section = "Feedback", page = "feedback", icon = 42, color = gold,
        label = "Answers to your feedback", desc = "The developer or an officer answered your feedback, or set where it stands.",
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
        label = "DisasterZone errors", desc = "DisasterZone hit a Lua error: report what you were doing.",
        needsYou = false, popup = true, sound = false,
        open = function() Sheet:Open({ kind = "bug" }) end,
        actions = function() return { { text = "Report it", primary = true, fn = function() Sheet:Open({ kind = "bug" })
            end } } end,
    })
end

local function OnError(e)
    if Sheet:IsOpen() then return end
    local Nf = N()
    if Nf and Nf.Post and Sheet.kindsRegistered then
        Nf:Post("feedbackError", { key = e and e.m or "error", title = "DisasterZone hit an error",
            text = "Report what you were doing? The error goes with it.", expires = time() + 1800 })
        return
    end
    Sheet:Toast({
        icon = FB().KIND_INFO.bug.icon, color = FB().KIND_INFO.bug.color,
        title = "DisasterZone hit an error",
        text = "Report what you were doing? The error goes with it.",
        button = "Report it", seconds = 15,
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
    end, "report that something broke (the last Lua error goes with it)")
    ns:RegisterSlash("idea", function(rest)
        rest = ns.Util.Trim(rest or "")
        Sheet:Open({ kind = "idea", text = rest ~= "" and rest or nil })
    end, "send an idea for DisasterZone")
end

function Sheet:OnLogin()
    RegisterKinds()
    ns:RegisterEvent("GLOBAL_MOUSE_DOWN", OnGlobalMouseDown)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function() Sheet:NextToast() end)
    -- after the login rush: what shipped since I last looked
    ns.Util.After(45, CheckShipped)
end

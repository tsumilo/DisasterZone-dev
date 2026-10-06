if DisasterZoneBoot and DisasterZoneBoot.Run("UI/EventBuilder.lua", ...) then return end -- DisasterZone: the event builder.
-- The event builder: its own window, like the strategy board. Stages run along the top (Always at the end), each with
-- a free canvas of scripts; the palette on the left (Scratch's circles, the pieces of the picked category, a search);
-- pieces snap together when dragged (a grey ghost shows where), values drop into blanks that take them, a click on a
-- blank opens the WC3-style picker of what fits there. Smart blocks sit on the canvas as cards with their settings and
-- the events they give (drag one onto the canvas: its "when" piece); "Open" steps inside one (its own pieces, locked
-- until you make your own copy). Practice runs the event with dummies (Core/EventLive.lua): the scripts glow as they
-- run, their values show, a log says what happened. Save, then Host puts it on the calendar (UI/EventsTab.lua).
--
-- Builder:Open(def | defId | nil [, opts]) (nil: a new event), Builder:Close(), Builder:IsShown(), Builder:GetWindow(),
-- Builder:GetState(), Builder:WasPracticed(defId, rev).
local addonName, ns = ...

local Builder = ns:NewModule("EventBuilder")

local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local floor, max, min, abs, sqrt = math.floor, math.max, math.min, math.abs, math.sqrt
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

local WIN_NAME = "DisasterZoneEventBuilder"
local WIN_W, WIN_H = 1040, 660
local TOP_H = 44
local PAL_W, CAT_W = 266, 60
local LOG_H = 118
local SNAP = 22                 -- content units a dragged piece snaps from
local UNDO_MAX = 60
local GRID = "Interface\\AddOns\\DisasterZone\\Media\\Events\\grid"
local GRID_STEP = 22                -- a dot every 22px at 100%
local WHITE = "Interface\\Buttons\\WHITE8X8"

local function B() return ns.EventBlocks end
local function EP() return ns.EventPieces end
local function EUI() return ns.EventUI end
local function UI() return ns.UI end
local function Ev() return ns.Events end
local function L() return ns.EventLive end
local function Util() return ns.Util end
local function Copy(v) return ns.EventBlocks.Copy(v) end
local function Me() return ns.Util.PlayerKey() end
local function Now() return (GetServerTime and GetServerTime()) or time() end

local S = {}        -- the builder's state (Builder:GetState)
local win            -- the window
local ui = {}        -- its parts

local function Sized(fs, size)
    local path, _, flags = fs:GetFont()
    if path then fs:SetFont(path, size, flags) end
    return fs
end

local function Text(parent, font, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    if size then Sized(fs, size) end
    return fs
end

local function Tip(owner, title, text)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

-- A text's whole width on one line (GetStringWidth stops at a width the string was given on this client).
local function TextW(fs)
    if fs.GetUnboundedStringWidth then return fs:GetUnboundedStringWidth() or 0 end
    return fs:GetStringWidth() or 0
end

-- Typed words as the library keeps them (Core/Events.lua cleans the same way when it saves): no "|" (the game reads
-- it as a code) or control characters, at most maxLen bytes (not in the middle of a letter).
local MAX_TEXT, MAX_NAME = 200, 24
local function Clean(text, maxLen)
    text = ns.Util.Trim((tostring(text or ""):gsub("[%c|]", "")))
    if maxLen and #text > maxLen then
        text = text:sub(1, maxLen)
        if text:byte(-1) and text:byte(-1) >= 128 then text = text:gsub("[\192-\255][\128-\191]*$", "") end
    end
    return text
end

---------------------------------------------------------------------------
-- The event being edited
---------------------------------------------------------------------------

local function Def() return S.def end

-- What the canvas shows: the scripts of the stage (or of the smart block opened), and whether they can be changed.
local function Scripts()
    local d = Def()
    if not d then return {} end
    if S.inside then
        local b = d.blocks[S.inside]
        if b and b.inner then return b.inner end
        S.builtIn = S.builtIn or {}
        if not S.builtIn[S.inside] then S.builtIn[S.inside] = B():BracketInner() end
        return S.builtIn[S.inside]
    end
    local out = {}
    for _, s in ipairs(d.scripts) do
        if s.st == S.stage then out[#out + 1] = s end
    end
    return out
end

-- Where a note on the canvas belongs: the stage, or the smart block opened ("in:b2": each block its own notes).
local function NoteSpot() return S.inside and ("in:" .. S.inside) or S.stage end

-- A smart block's notes go with it.
local function DropBlockNotes(d, bid)
    for k = #(d.notes or {}), 1, -1 do
        if d.notes[k].st == "in:" .. bid then tremove(d.notes, k) end
    end
end

local function CanEdit()
    if S.readOnly or S.practice then return false end
    if S.inside then
        local b = Def().blocks[S.inside]
        return b and b.inner ~= nil
    end
    return true
end

local function NewId(prefix)
    S.idn = (S.idn or 0) + 1
    return (prefix or "s") .. string.format("%x", Now() % 1048576) .. S.idn
end

local function ContentHash(d)
    return Util().Hash({ d.stages, d.scripts, d.blocks, d.badges, d.vars })
end

-- The notes on the canvas count as a change too (not for practice: ContentHash is what a practice run matches).
local function NotesHash(d) return Util().Hash(d.notes or {}) end

local function FullHash(d) return Util().Hash({ ContentHash(d), NotesHash(d), d.name, d.art, d.icon }) end

-- A new event (not saved yet) nothing was done to since it was opened.
function Builder:IsUntouched()
    return S.fresh ~= nil and S.def ~= nil and not Ev():GetDef(S.def.id) and FullHash(S.def) == S.fresh
end

-- What Save compares with: the event as it was opened or last saved.
local function NoteSaved(d)
    S.savedHash, S.savedNotes = ContentHash(d), NotesHash(d)
    S.savedName, S.savedArt, S.savedIcon = d.name, d.art, d.icon
end

local function MarkDirty()
    S.dirty = ContentHash(Def()) ~= S.savedHash or NotesHash(Def()) ~= S.savedNotes or (Def().name ~= S.savedName)
        or (Def().art ~= S.savedArt) or (Def().icon ~= S.savedIcon)
end

local function Snapshot() return Copy(S.def) end

local function PushUndo(before)
    tinsert(S.undo, before or Snapshot())
    while #S.undo > UNDO_MAX do tremove(S.undo, 1) end
    S.redo = {}
end

local Refresh   -- (forward) repaints everything

local function Changed(before)
    PushUndo(before)
    MarkDirty()
    Refresh()
end

local KeepPlace  -- (below) the open stage / smart block after the event was swapped

-- Undo and redo swap the event for a copy: the picker and a name being typed held pieces of the old one (they go),
-- and the stage or smart block that was open may not be in the copy. Not while something is being dragged.
local function Swap(from, to)
    if #from == 0 or S.drag or S.cardDrag or S.noteDrag then return end
    tinsert(to, Snapshot())
    S.def = tremove(from)
    KeepPlace()
    Builder:ClosePicker()
    if ui.ask then ui.ask:Hide() end
    MarkDirty()
    Refresh()
end

function Builder:Undo() Swap(S.undo, S.redo) end
function Builder:Redo() Swap(S.redo, S.undo) end

---------------------------------------------------------------------------
-- Finding a piece in the event's trees, cutting it out, putting it in
---------------------------------------------------------------------------

-- Where a piece is: { script = s, parent = piece | nil (the script's top), field = "n" | "c1" | "c2" | number (a blank)
-- | "j" (inside a text), slot (the blank of a "j"), index (in the "j" list) }.
local function Locate(target)
    local found
    local function walk(p, parent, field, script, slot, index)
        if found or type(p) ~= "table" then return end
        if p == target then
            found = { script = script, parent = parent, field = field, slot = slot, index = index }
            return
        end
        for i, a in pairs(p.a or {}) do
            if type(a) == "table" then
                if a.k then walk(a, p, i, script)
                elseif type(a.j) == "table" then
                    for ji, x in ipairs(a.j) do
                        if type(x) == "table" and x.k then walk(x, p, "j", script, i, ji) end
                    end
                end
            end
        end
        if p.c1 then walk(p.c1, p, "c1", script) end
        if p.c2 then walk(p.c2, p, "c2", script) end
        if p.n then walk(p.n, p, "n", script) end
    end
    for _, s in ipairs(Scripts()) do
        walk(s.top, nil, "top", s)
        if found then return found end
    end
    return nil
end

-- Takes a piece out where it is (a stack piece with everything under it). Returns true.
local function Cut(loc, piece)
    if not loc then return false end
    if loc.field == "top" then
        local list = S.inside and Scripts() or Def().scripts
        for i, s in ipairs(list) do
            if s == loc.script then tremove(list, i) break end
        end
    elseif loc.field == "j" then
        local a = loc.parent.a[loc.slot]
        tremove(a.j, loc.index)
    elseif type(loc.field) == "number" then
        loc.parent.a[loc.field] = nil
    else
        loc.parent[loc.field] = nil
    end
    return true
end

local function LastOf(p)
    while p and p.n do p = p.n end
    return p
end

local function Shape(p)
    local pd = p and B().PIECES[p.k]
    if not pd then return p and (p.k == "ctx" or p.k == "var") and "value" or "stack" end
    if p.k == "ctx" or p.k == "var" then return "value" end
    return pd.shape
end

local function IsValue(p)
    local s = Shape(p)
    return s == "value" or s == "bool"
end

-- A new script holding p at x, y on the canvas.
local function AddScript(p, x, y)
    local s = { id = NewId("s"), st = S.stage, x = floor(x), y = floor(y), top = p }
    if S.inside then
        s.st = "*"
        tinsert(Scripts(), s)
    else
        tinsert(Def().scripts, s)
    end
    return s
end

KeepPlace = function()
    local d = Def()
    local b = S.inside and d.blocks[S.inside]
    if S.inside and not (b and b.kind == "bracket") then S.inside = nil end
    if S.stage ~= "*" and not B():Stage(d, S.stage) then S.stage = d.stages[1] and d.stages[1].id or "*" end
end

---------------------------------------------------------------------------
-- The window
---------------------------------------------------------------------------

local function FitScale()
    local sw, sh = UIParent:GetWidth() or 1920, UIParent:GetHeight() or 1080
    return min(1, (sw - 20) / WIN_W, (sh - 20) / WIN_H)
end

local function Divider(parent, vertical)
    local t = parent:CreateTexture(nil, "BORDER")
    t:SetColorTexture(1, 1, 1, 0.12)
    if vertical then t:SetWidth(1) else t:SetHeight(1) end
    return t
end

local CreateTop, CreatePalette, CreateCanvas, CreatePractice

local function CreateWindow()
    win = UI():CreateWindow(WIN_NAME, "Event builder", WIN_W, WIN_H)
    win:SetFrameStrata("HIGH")
    local c = win.content
    c:SetClipsChildren(true)
    ui.body = CreateFrame("Frame", nil, c)
    ui.body:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -TOP_H)
    ui.body:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
    ui.body:SetSize(WIN_W - 12, WIN_H - 31 - TOP_H)
    CreateTop(c)
    CreatePalette(ui.body)
    CreateCanvas(ui.body)
    CreatePractice(ui.body)
    -- Ctrl-Z / Ctrl-Y while the builder has the mouse (the keyboard still moves the character otherwise)
    win:EnableKeyboard(false)
    win:SetScript("OnKeyDown", function(self, key)
        local ctrl = IsControlKeyDown and IsControlKeyDown()
        if ctrl and key == "Z" and CanEdit() then
            self:SetPropagateKeyboardInput(false)
            Builder:Undo()
        elseif ctrl and key == "Y" and CanEdit() then
            self:SetPropagateKeyboardInput(false)
            Builder:Redo()
        elseif key == "ESCAPE" and (S.drag or S.press) then
            -- Escape during a drag drops the drag (the piece goes back), not the window
            self:SetPropagateKeyboardInput(false)
            Builder:CancelDrag()
        elseif key == "ESCAPE" and ui.picker and ui.picker:IsShown() then
            self:SetPropagateKeyboardInput(false)
            Builder:ClosePicker()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    win:SetScript("OnEnter", function(self) if self.EnableKeyboard then self:EnableKeyboard(true) end end)
    win:SetScript("OnHide", function()
        -- a drag still going: the piece goes back first (so the save below has it), its drawing goes
        Builder:CancelDrag()
        Builder:ClosePicker()
        -- (a name being typed belongs to this event: it must not come back over the next one)
        if ui.ask then ui.ask:Hide() end
        if S.practice then Builder:StopPractice() end
        if S.dirty and S.def and not S.readOnly and Builder.autoSave ~= false and not Builder:IsUntouched() then
            -- closing keeps the work: saved to the library (a draft until it is hosted or sent for review)
            Builder:Save(true)
        end
    end)
    win:Hide()
end

---------------------------------------------------------------------------
-- The top bar: the event's name, the stage strip, the actions
---------------------------------------------------------------------------

local function IconButton(parent, icon, title, text, onClick, size)
    local b = UI():CreateTipIconButton(parent, size or 26, icon, title, text, onClick)
    return b
end

CreateTop = function(c)
    local top = CreateFrame("Frame", nil, c)
    top:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
    top:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
    top:SetHeight(TOP_H)
    ui.top = top
    local line = Divider(top)
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    -- the practice tint
    top.tint = top:CreateTexture(nil, "BACKGROUND")
    top.tint:SetAllPoints()
    top.tint:SetTexture(WHITE)
    EUI():Gradient(top.tint, "HORIZONTAL", 0.05, 0.33, 0.29, 0.35, 0)
    top.tint:Hide()
    -- the event: icon, name (a field that reads as text), pencil
    local icon = CreateFrame("Button", nil, top)
    icon:SetSize(24, 24)
    icon:SetPoint("LEFT", top, "LEFT", 10, 0)
    icon.tex = icon:CreateTexture(nil, "ARTWORK")
    icon.tex:SetAllPoints()
    icon.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    EUI():Edge(icon, 0, 0, 0, 1)
    icon:SetScript("OnClick", function(self) Builder:IconMenu(self) end)
    icon:SetScript("OnEnter", function(self) Tip(self, "Event icon", "Click to pick another one.") end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
    top.icon = icon
    local name = CreateFrame("EditBox", nil, top)
    name:SetAutoFocus(false)
    name:SetFontObject("GameFontHighlight")
    Sized(name, 13)
    name:SetSize(170, 24)
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetMaxLetters(40)
    name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    name:SetScript("OnEscapePressed", function(self)
        self:SetText(Def() and Def().name or "")
        self:ClearFocus()
    end)
    name:SetScript("OnEditFocusLost", function(self)
        local d = Def()
        local t = Clean(self:GetText(), 40)
        if d and t ~= "" and t ~= d.name and CanEdit() then
            local before = Snapshot()
            d.name = t
            Changed(before)
        elseif d then
            self:SetText(d.name or "")
        end
    end)
    top.name = name
    top.pencil = top:CreateTexture(nil, "ARTWORK")
    top.pencil:SetSize(12, 12)
    EUI():Glyph(top.pencil, 16, 0.62, 0.62, 0.66)
    top.sep1 = Divider(top, true)
    top.sep1:SetHeight(20)
    -- the stage strip (pills made in RenderTop)
    top.strip = CreateFrame("Frame", nil, top)
    top.strip:SetSize(10, 24)
    top.pills = {}
    -- the crumb (inside a smart block) and the practice controls share the strip's place
    top.crumb = CreateFrame("Frame", nil, top)
    top.crumb:SetSize(300, 24)
    top.crumb.back = Text(top.crumb, "GameFontHighlight", 12)
    top.crumb.back:SetPoint("LEFT", top.crumb, "LEFT", 0, 0)
    top.crumb.back:SetTextColor(0.74, 0.74, 0.74)
    top.crumb.chev = top.crumb:CreateTexture(nil, "ARTWORK")
    top.crumb.chev:SetSize(10, 10)
    UI():SetChevron(top.crumb.chev, true)
    top.crumb.chev:SetVertexColor(0.44, 0.44, 0.46)
    top.crumb.icon = top.crumb:CreateTexture(nil, "ARTWORK")
    top.crumb.icon:SetSize(18, 18)
    top.crumb.name = Text(top.crumb, "GameFontNormal", 12)
    top.crumb.pill = EUI():CreatePill(top.crumb, 16)
    local backBtn = CreateFrame("Button", nil, top.crumb)
    backBtn:SetAllPoints(top.crumb.back)
    backBtn:SetScript("OnClick", function() Builder:CloseInside() end)
    top.crumb:Hide()
    -- right side: undo, redo | practice, share, more, primary
    top.primary = UI():CreateSleekButton(top, "Save", 70, 24, function() Builder:Primary() end, "primary")
    top.primary:SetPoint("RIGHT", top, "RIGHT", -10, 0)
    top.more = IconButton(top, UI().ICON.more, "More", "Art, icon, badges, variables, review, copy, delete.",
        function(self) Builder:MoreMenu(self) end, 24)
    top.more:SetPoint("RIGHT", top.primary, "LEFT", -6, 0)
    top.share = IconButton(top, 18, "Share", "Post a link to this event in chat.", function(self) Builder:ShareEvent(self) end, 24)
    top.share:SetPoint("RIGHT", top.more, "LEFT", -6, 0)
    top.practiceBtn = UI():CreateSleekButton(top, "Practice", 84, 24, function() Builder:StartPractice() end)
    local pi = top.practiceBtn:CreateTexture(nil, "ARTWORK")
    pi:SetSize(10, 10)
    EUI():Glyph(pi, UI().ICON.play or 47, 0.92, 0.92, 0.92)
    pi:SetPoint("LEFT", top.practiceBtn, "LEFT", 10, 0)
    top.practiceBtn:GetFontString():ClearAllPoints()
    top.practiceBtn:GetFontString():SetPoint("LEFT", pi, "RIGHT", 6, 0)
    top.practiceBtn:SetPoint("RIGHT", top.share, "LEFT", -6, 0)
    top.sep2 = Divider(top, true)
    top.sep2:SetHeight(20)
    top.sep2:SetPoint("RIGHT", top.practiceBtn, "LEFT", -8, 0)
    top.redo = IconButton(top, 10, "Redo", "Ctrl-Y", function()
        if #S.redo == 0 then ns:Print("%s", "nothing to redo: redo brings back what undo took away.") end
        Builder:Redo()
    end, 24)
    top.redo:SetPoint("RIGHT", top.sep2, "LEFT", -8, 0)
    top.undo = IconButton(top, 9, "Undo", "Ctrl-Z", function()
        if #S.undo == 0 then ns:Print("%s", "nothing to undo yet.") end
        Builder:Undo()
    end, 24)
    top.undo:SetPoint("RIGHT", top.redo, "LEFT", -6, 0)
    -- practice controls (shown instead of the strip while practising)
    local pr = CreateFrame("Frame", nil, top)
    pr:SetSize(400, 24)
    top.prac = pr
    pr.tag = CreateFrame("Frame", nil, pr)
    pr.tag:SetSize(112, 24)
    pr.tag:SetPoint("LEFT", pr, "LEFT", 0, 0)
    UI():AddPillShape(pr.tag, 24)
    pr.tag:SetPillColors({ 0.05, 0.33, 0.29, 0.85 }, { 0.31, 0.84, 0.73, 0.95 })
    pr.tag.dot = pr.tag:CreateTexture(nil, "OVERLAY")
    pr.tag.dot:SetTexture(EUI().MASK)
    pr.tag.dot:SetSize(7, 7)
    pr.tag.dot:SetVertexColor(0.31, 0.84, 0.73)
    pr.tag.dot:SetPoint("LEFT", pr.tag, "LEFT", 10, 0)
    pr.tag.fs = Text(pr.tag, "GameFontHighlight", 12)
    pr.tag.fs:SetPoint("LEFT", pr.tag.dot, "RIGHT", 7, 0)
    pr.tag.fs:SetText("Practice run")
    pr.tag.fs:SetTextColor(0.92, 1, 0.97)
    pr.pause = IconButton(pr, UI().ICON.pause or 48, "Pause", "Stops the practice clock (timers wait).", function()
        local _, p = L():GetPractice()
        L():SetPracticePaused(not (p and p.paused))
    end, 24)
    pr.pause:SetPoint("LEFT", pr.tag, "RIGHT", 8, 0)
    pr.skip = IconButton(pr, UI().ICON.skip or 49, "Skip ahead", "Jumps to the next timer or wait (a 5 minute no-show takes a click).",
        function() L():PracticeSkip() end, 24)
    pr.skip:SetPoint("LEFT", pr.pause, "RIGHT", -1, 0)
    pr.speed = UI():CreateSleekMenuButton(pr, "1x", 50, function(root)
        for _, x in ipairs({ 1, 2, 5, 10 }) do
            root:CreateRadio(x .. "x", function() local _, p = L():GetPractice(); return p and p.speed == x end,
                function() L():SetPracticeSpeed(x) end)
        end
    end, 24)
    pr.speed:SetPoint("LEFT", pr.skip, "RIGHT", -1, 0)
    pr.restart = IconButton(pr, 34, "Start again", "The practice run starts over with fresh dummies.", function()
        Builder:StartPractice(true)
    end, 24)
    pr.restart:SetPoint("LEFT", pr.speed, "RIGHT", -1, 0)
    pr.sep = Divider(pr, true)
    pr.sep:SetHeight(20)
    pr.sep:SetPoint("LEFT", pr.restart, "RIGHT", 10, 0)
    pr.strip = CreateFrame("Frame", nil, pr)
    pr.strip:SetSize(10, 24)
    pr.strip:SetPoint("LEFT", pr.sep, "RIGHT", 10, 0)
    pr.pills = {}
    pr:Hide()
    top.board = UI():CreateSleekButton(top, "See the board", 112, 24, function()
        if ns.EventBoard and ns.EventBoard.Open then ns.EventBoard:Open("practice") end
    end)
    top.ended = UI():CreateSleekButton(top, "End practice", 100, 24, function() Builder:StopPractice() end)
    top.ended:SetPoint("RIGHT", top, "RIGHT", -10, 0)
    top.board:SetPoint("RIGHT", top.ended, "LEFT", -6, 0)
    top.board:Hide()
    top.ended:Hide()
end

-- A stage pill: number disc + name (+ a warning dot); states on | live | done | (plain).
local function Pill(list, parent, i)
    local p = list[i]
    if p then return p end
    p = CreateFrame("Button", nil, parent)
    p:SetHeight(24)
    UI():AddPillShape(p, 24)
    p.disc = p:CreateTexture(nil, "ARTWORK", nil, 1)
    p.disc:SetTexture(EUI().MASK)
    p.disc:SetSize(17, 17)
    p.disc:SetPoint("LEFT", p, "LEFT", 4, 0)
    p.num = Text(p, "GameFontHighlightSmall", 10)
    p.num:SetJustifyH("CENTER")
    p.num:SetPoint("CENTER", p.disc, "CENTER", 0, 0)
    p.icon = p:CreateTexture(nil, "ARTWORK", nil, 2)
    p.icon:SetSize(15, 15)
    p.fs = Text(p, "GameFontHighlight", 12)
    p.dot = p:CreateTexture(nil, "OVERLAY")
    p.dot:SetTexture(EUI().MASK)
    p.dot:SetSize(6, 6)
    p.dot:SetVertexColor(1, 0.55, 0.1)
    p.arrow = parent:CreateTexture(nil, "ARTWORK")
    p.arrow:SetSize(9, 9)
    UI():SetChevron(p.arrow, true)
    p.arrow:SetVertexColor(0.31, 0.31, 0.33)
    p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    -- (a stage shown by its number only says its name here)
    p:SetScript("OnEnter", function(self) if self.tipTitle then Tip(self, self.tipTitle, self.tipText) end end)
    p:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list[i] = p
    return p
end

local function PaintPill(p, kind)
    if kind == "on" then
        p:SetPillColors({ 0.42, 0.30, 0.04, 0.6 }, { 1, 0.82, 0, 0.85 })
        p.disc:SetVertexColor(1, 0.82, 0)
        p.num:SetTextColor(0.16, 0.11, 0)
        p.fs:SetTextColor(1, 0.95, 0.8)
    elseif kind == "live" then
        p:SetPillColors({ 0.05, 0.33, 0.29, 0.65 }, { 0.31, 0.84, 0.73, 0.95 })
        p.disc:SetVertexColor(0.31, 0.84, 0.73)
        p.num:SetTextColor(0.01, 0.16, 0.13)
        p.fs:SetTextColor(0.92, 1, 0.97)
    elseif kind == "done" then
        p:SetPillColors({ 0.06, 0.06, 0.07, 0.5 }, { 1, 1, 1, 0.14 })
        p.disc:SetVertexColor(0.24, 0.71, 0.35, 0.3)
        p.num:SetTextColor(0.62, 0.94, 0.69)
        p.fs:SetTextColor(0.6, 0.6, 0.63)
    else
        p:SetPillColors({ 0.06, 0.06, 0.07, 0.5 }, { 1, 1, 1, 0.14 })
        p.disc:SetVertexColor(1, 1, 1, 0.08)
        p.num:SetTextColor(0.87, 0.87, 0.87)
        p.fs:SetTextColor(0.74, 0.74, 0.74)
    end
end

-- Lays the stage pills out in a strip: stages (with arrows between), "+", the Always pill. practice: the run's
-- states (done / live) and no "+" or Always. room: the width it has. When the names don't fit, stages show their
-- number only (the name in their tooltip), the farthest from the open one first; then Always its sign only; then
-- the open one's name gets smaller; then it shows its number too. Returns the strip's width.
local function LayoutStrip(strip, pills, practice, room)
    local d = Def()
    local problems = {}
    for _, pr in ipairs(B():Problems(d)) do
        local sid
        for _, s in ipairs(d.scripts) do
            if s.id == pr.script then sid = s.st end
        end
        -- (one in a smart block's own copy: "blockId/scriptId", the block's stage)
        local bid = not sid and tostring(pr.script):match("^(.-)/")
        if bid and d.blocks[bid] then sid = d.blocks[bid].stage end
        if sid then problems[sid] = true end
    end
    local runSt = practice and L():GetState("practice")
    local _, curIdx = B():Stage(d, runSt and runSt.stage)
    local done = runSt and runSt.phase == "done"
    -- the open stage (Always or none: past the last one)
    local openIdx = #d.stages + 1
    for i, st in ipairs(d.stages) do
        if (practice and i == curIdx and not done) or (not practice and st.id == S.stage and not S.inside) then openIdx = i end
    end
    -- one layout: size = the open stage's name size, small[i] = stage i by number, alwSign = Always by its sign
    local function lay(size, small, alwSign)
        local x, n = 0, 0
        for i, st in ipairs(d.stages) do
            n = n + 1
            local p = Pill(pills, strip, n)
            p:Show()
            p.icon:Hide()
            p.disc:Show()
            if p.sep then p.sep:Hide() end      -- (the pill was the Always one before a stage was added)
            p.num:SetText(i)
            local kind = (not practice and st.id == S.stage and not S.inside) and "on" or ""
            if practice then
                kind = curIdx and (i < curIdx and "done" or (i == curIdx and "live" or "")) or ""
                if done then kind = "done" end
                if kind == "done" then p.num:SetText("") end
            end
            local open = i == openIdx
            local num = small[i] and true or false
            Sized(p.fs, open and size or 12)
            p.fs:SetText(st.name)
            p.fs:ClearAllPoints()
            p.fs:SetPoint("LEFT", p.disc, "RIGHT", 6, 0)
            p.fs:SetShown(not num)
            local w = num and 25 or (4 + 17 + 6 + TextW(p.fs) + 10)
            p.dot:ClearAllPoints()
            if problems[st.id] and not practice then
                p.dot:Show()
                if num then
                    p.dot:SetPoint("CENTER", p.disc, "TOPRIGHT", -2, -2)
                else
                    p.dot:SetPoint("LEFT", p.fs, "RIGHT", 5, 0)
                    w = w + 9
                end
            else
                p.dot:Hide()
            end
            PaintPill(p, kind)
            if kind == "done" then
                p.check = p.check or p:CreateTexture(nil, "OVERLAY")
                p.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
                p.check:SetSize(10, 10)
                p.check:SetPoint("CENTER", p.disc, "CENTER", 0, 0)
                p.check:Show()
            elseif p.check then
                p.check:Hide()
            end
            p:SetWidth(w)
            p:ClearAllPoints()
            -- an arrow between two stages with names (a small gap next to a number)
            if i > 1 and not (num or small[i - 1]) then
                p.arrow:ClearAllPoints()
                p.arrow:SetPoint("LEFT", strip, "LEFT", x + 3, 0)
                p.arrow:Show()
                x = x + 15
            else
                p.arrow:Hide()
                if i > 1 then x = x + 4 end
            end
            p:SetPoint("LEFT", strip, "LEFT", x, 0)
            x = x + w
            p.stage = st.id
            p.tipTitle = num and st.name or nil
            p.tipText = num and not practice and CanEdit() and "Right-click: rename, move or delete it." or nil
            p:SetScript("OnClick", function(self, button)
                if practice then return end
                if button == "RightButton" then
                    Builder:StageMenu(self, self.stage)
                else
                    Builder:SelectStage(self.stage)
                end
            end)
            p:SetScript("OnDoubleClick", function(self) if not practice then Builder:RenameStage(self, self.stage) end end)
        end
        if not practice and CanEdit() then
            -- "+" a stage (not on someone else's event: nothing to add there)
            n = n + 1
            local add = Pill(pills, strip, n)
            add:Show()
            if add.sep then add.sep:Hide() end
            add.disc:Hide()
            add.num:SetText("")
            add.fs:SetText("")
            add.dot:Hide()
            add.arrow:Hide()
            if add.check then add.check:Hide() end
            add.icon:Show()
            add.icon:ClearAllPoints()
            add.icon:SetPoint("CENTER")
            add.icon:SetSize(11, 11)
            EUI():Glyph(add.icon, UI().ICON.plus or 39, 0.8, 0.8, 0.8)
            PaintPill(add, "")
            add:SetWidth(24)
            add:ClearAllPoints()
            add:SetPoint("LEFT", strip, "LEFT", x + 8, 0)
            x = x + 32
            add.stage = nil
            add.tipTitle, add.tipText = "Add a stage", nil
            add:SetScript("OnClick", function() if CanEdit() then Builder:AddStage() end end)
            add:SetScript("OnDoubleClick", nil)
        end
        if not practice then
            -- Always (just its sign when there is no room)
            n = n + 1
            local alw = Pill(pills, strip, n)
            local on = S.stage == "*" and not S.inside
            local sign = alwSign and not on
            alw:Show()
            alw.disc:Hide()
            alw.num:SetText("")
            alw.dot:Hide()
            alw.arrow:Hide()
            if alw.check then alw.check:Hide() end
            alw.icon:Show()
            alw.icon:ClearAllPoints()
            alw.icon:SetPoint("LEFT", alw, "LEFT", 9, 0)
            alw.icon:SetSize(15, 15)
            EUI():Glyph(alw.icon, UI().ICON.infinity or 53, 0.81, 0.81, 0.81)
            Sized(alw.fs, on and size or 12)
            alw.fs:SetText("Always")
            alw.fs:ClearAllPoints()
            alw.fs:SetPoint("LEFT", alw.icon, "RIGHT", 5, 0)
            alw.fs:SetShown(not sign)
            PaintPill(alw, on and "on" or "")
            local aw = sign and 33 or (9 + 15 + 5 + TextW(alw.fs) + 10)
            alw:SetWidth(aw)
            alw.sep = alw.sep or Divider(strip, true)
            alw.sep:SetHeight(20)
            alw.sep:ClearAllPoints()
            alw.sep:SetPoint("LEFT", strip, "LEFT", x + 6, 0)
            alw.sep:Show()
            alw:ClearAllPoints()
            alw:SetPoint("LEFT", strip, "LEFT", x + 14, 0)
            x = x + 14 + aw
            alw.stage = "*"
            alw.tipTitle = sign and "Always" or nil
            alw.tipText = sign and "Pieces here run in every stage." or nil
            alw:SetScript("OnClick", function() Builder:SelectStage("*") end)
            alw:SetScript("OnDoubleClick", nil)
        end
        return x, n
    end
    -- the layouts to try, roomiest first: one more stage by number each time (the farthest from the open one, later
    -- ones before earlier ones), then Always by its sign, the open name smaller, at last every stage by number
    local order = {}
    for i = 1, #d.stages do if i ~= openIdx then order[#order + 1] = i end end
    tsort(order, function(a, b)
        local da, db = abs(a - openIdx), abs(b - openIdx)
        if da ~= db then return da > db end
        return a > b
    end)
    local tries, small = { { 12, {}, false } }, {}
    for _, i in ipairs(order) do
        small[i] = true
        local copy = {}
        for k in pairs(small) do copy[k] = true end
        tries[#tries + 1] = { 12, copy, false }
    end
    for _, size in ipairs({ 12, 11, 10, 9 }) do tries[#tries + 1] = { size, small, true } end
    local all = {}
    for i = 1, #d.stages do all[i] = true end
    tries[#tries + 1] = { 12, all, true }
    local x, n
    for _, try in ipairs(tries) do
        x, n = lay(try[1], try[2], try[3])
        if not room or x <= room then break end
    end
    for i = n + 1, #pills do
        pills[i]:Hide()
        pills[i].arrow:Hide()
        if pills[i].sep then pills[i].sep:Hide() end
    end
    strip:SetWidth(max(10, x))
    return x
end

local function RenderTop()
    local top, d = ui.top, Def()
    top.icon.tex:SetTexture(d.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    if not top.name:HasFocus() then top.name:SetText(d.name or "") end
    -- a field sized to its text (a long name in a smaller font, and wider when it must: the field shows all of it;
    -- the stage strip makes room)
    local probe = top.probe or Text(top, "GameFontHighlight", 13)
    top.probe = probe
    probe:SetText(d.name or "")
    probe:Hide()
    local size = 13
    Sized(probe, size)
    while size > 10 and TextW(probe) + 6 > 220 do
        size = size - 1
        Sized(probe, size)
    end
    Sized(top.name, size)
    local nw = min(300, max(40, TextW(probe) + 6))
    top.name:SetWidth(nw)
    top.pencil:ClearAllPoints()
    top.pencil:SetPoint("LEFT", top.name, "RIGHT", 2, 0)
    top.pencil:SetShown(CanEdit() and not S.inside)
    top.sep1:ClearAllPoints()
    top.sep1:SetPoint("LEFT", top.pencil, "RIGHT", 10, 0)
    local practice = S.practice
    top.tint:SetShown(practice)
    top.strip:SetShown(not practice and not S.inside)
    top.crumb:SetShown(S.inside ~= nil and not practice)
    top.prac:SetShown(practice)
    for _, b in ipairs({ top.undo, top.redo, top.practiceBtn, top.share, top.more, top.primary, top.sep2 }) do
        b:SetShown(not practice)
    end
    top.board:SetShown(practice)
    top.ended:SetShown(practice)
    top.icon:SetShown(not practice)
    top.name:SetShown(not practice)
    top.sep1:SetShown(not practice)
    -- the primary: Save while there are changes, then Host; "Make a copy" for someone else's event
    local primary = top.primary
    if S.readOnly then
        primary:SetText("Make a copy")
    elseif S.dirty or not Ev():GetDef(d.id) then
        primary:SetText("Save")
    else
        primary:SetText("Host")
    end
    primary:SetWidth((primary:GetFontString():GetStringWidth() or 40) + 26)
    -- (one gold button a view: inside a built-in smart block it is the ribbon's "Make my own copy")
    local blk = S.inside and d.blocks[S.inside]
    primary:SetKind((blk and not blk.inner and not S.readOnly) and "secondary" or "primary")
    -- the room the strip has: from where it starts to the buttons on the right (their widths add up; 12 between)
    local tw = top:GetWidth() or 0
    if tw < 200 then tw = WIN_W - 12 end
    if practice then
        top.pencil:Hide()
        top.prac:ClearAllPoints()
        top.prac:SetPoint("LEFT", top, "LEFT", 10, 0)
        local pr = top.prac
        local x0 = 10 + pr.tag:GetWidth() + 8 + pr.pause:GetWidth() - 1 + pr.skip:GetWidth() - 1 + pr.speed:GetWidth() - 1
            + pr.restart:GetWidth() + 10 + 1 + 10
        local right = 10 + top.ended:GetWidth() + 6 + top.board:GetWidth()
        LayoutStrip(pr.strip, pr.pills, true, tw - right - 12 - x0)
        local _, p = L():GetPractice()
        top.prac.speed:SetText(((p and p.speed) or 1) .. "x")
        local c = UI():IconCoords((p and p.paused) and (UI().ICON.play or 47) or (UI().ICON.pause or 48))
        top.prac.pause.icon:SetTexCoord(c[1], c[2], c[3], c[4])
        top.prac.pause.tipTitle = (p and p.paused) and "Go on" or "Pause"
    elseif S.inside then
        local b = d.blocks[S.inside]
        local cr = top.crumb
        cr:ClearAllPoints()
        cr:SetPoint("LEFT", top.sep1, "RIGHT", 10, 0)
        cr.back:SetText(d.name or "Event")
        cr.chev:ClearAllPoints()
        cr.chev:SetPoint("LEFT", cr.back, "RIGHT", 6, 0)
        cr.icon:SetTexture(B().SMART[b.kind].icon)
        cr.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        cr.icon:ClearAllPoints()
        cr.icon:SetPoint("LEFT", cr.chev, "RIGHT", 6, 0)
        cr.name:SetText(B():BlockLabel(d, S.inside))
        cr.name:ClearAllPoints()
        cr.name:SetPoint("LEFT", cr.icon, "RIGHT", 6, 0)
        cr.pill:SetKind(b.inner and "your copy" or "built in", b.inner and "alt" or "mute")
        cr.pill:ClearAllPoints()
        cr.pill:SetPoint("LEFT", cr.name, "RIGHT", 8, 0)
        top.icon:Hide()
        top.name:Hide()
        top.pencil:Hide()
        top.sep1:Hide()
        cr:ClearAllPoints()
        cr:SetPoint("LEFT", top, "LEFT", 10, 0)
    else
        top.strip:ClearAllPoints()
        top.strip:SetPoint("LEFT", top.sep1, "RIGHT", 10, 0)
        local x0 = 10 + top.icon:GetWidth() + 8 + nw + 2 + top.pencil:GetWidth() + 10 + 1 + 10
        local right = 10 + primary:GetWidth() + 6 + top.more:GetWidth() + 6 + top.share:GetWidth() + 6
            + top.practiceBtn:GetWidth() + 8 + 1 + 8 + top.redo:GetWidth() + 6 + top.undo:GetWidth()
        LayoutStrip(top.strip, top.pills, false, tw - right - 12 - x0)
    end
    -- undo / redo stay clickable (they say so when there is nothing to take back): dim then
    top.undo.icon:SetAlpha(#S.undo > 0 and 1 or 0.35)
    top.redo.icon:SetAlpha(#S.redo > 0 and 1 or 0.35)
    top.undo.tipText = #S.undo > 0 and "Ctrl-Z" or "Ctrl-Z · nothing to undo yet"
    top.redo.tipText = #S.redo > 0 and "Ctrl-Y" or "Ctrl-Y · nothing to redo"
end

---------------------------------------------------------------------------
-- The palette
---------------------------------------------------------------------------

local CAT_LABEL = { ev = "Events", sg = "Stages", lo = "Logic", pl = "Players", pt = "Points", ch = "Chat", tm = "Timers",
    wo = "World", sm = "Smart" }

CreatePalette = function(body)
    local pal = CreateFrame("Frame", nil, body)
    pal:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    pal:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    pal:SetWidth(PAL_W)
    local bg = pal:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.063, 0.98)
    local line = Divider(pal, true)
    line:SetPoint("TOPRIGHT")
    line:SetPoint("BOTTOMRIGHT")
    ui.pal = pal
    -- the categories: a coloured circle and the word under it
    pal.cats = {}
    local catLine = pal:CreateTexture(nil, "BORDER")
    catLine:SetColorTexture(1, 1, 1, 0.06)
    catLine:SetPoint("TOPLEFT", pal, "TOPLEFT", CAT_W, 0)
    catLine:SetPoint("BOTTOMLEFT", pal, "BOTTOMLEFT", CAT_W, 0)
    catLine:SetWidth(1)
    for i, c in ipairs(B().CATS) do
        local b = CreateFrame("Button", nil, pal)
        b:SetSize(CAT_W, 47)
        b:SetPoint("TOPLEFT", pal, "TOPLEFT", 0, -4 - (i - 1) * 47)
        b.hl = b:CreateTexture(nil, "BACKGROUND")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(1, 1, 1, 0.05)
        b.bar = b:CreateTexture(nil, "ARTWORK")
        b.bar:SetColorTexture(1, 0.82, 0)
        b.bar:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -6)
        b.bar:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 6)
        b.bar:SetWidth(2)
        b.dot = b:CreateTexture(nil, "ARTWORK", nil, 1)
        b.dot:SetTexture(EUI().MASK)
        b.dot:SetSize(16, 16)
        b.dot:SetPoint("TOP", b, "TOP", 0, -8)
        EUI():Gradient(b.dot, "VERTICAL", c.f[1], c.f[2], c.f[3], 1, 1)
        b.dot:SetVertexColor(c.f2[1], c.f2[2], c.f2[3])
        b.ring = b:CreateTexture(nil, "ARTWORK", nil, 2)
        b.ring:SetTexture(EUI().RING)
        b.ring:SetSize(17, 17)
        b.ring:SetPoint("CENTER", b.dot, "CENTER", 0, 0)
        b.ring:SetVertexColor(c.e[1], c.e[2], c.e[3])
        b.fs = Text(b, "GameFontHighlightSmall", 9.5)
        b.fs:SetJustifyH("CENTER")
        b.fs:SetPoint("TOP", b.dot, "BOTTOM", 0, -5)
        b.fs:SetText(c.label)
        b.cat = c.key
        b:SetScript("OnClick", function(self)
            S.cat = self.cat
            S.search = ""
            if ui.search then ui.search:SetText("") end
            Builder:RenderPalette()
        end)
        pal.cats[i] = b
    end
    -- the list: a search on top, the pieces in a scroll frame
    local list = CreateFrame("Frame", nil, pal)
    list:SetPoint("TOPLEFT", pal, "TOPLEFT", CAT_W + 10, -8)
    list:SetPoint("BOTTOMRIGHT", pal, "BOTTOMRIGHT", -10, 8)
    list:SetSize(PAL_W - CAT_W - 20, 500)
    pal.list = list
    local search = UI():CreateSearchBox(list, PAL_W - CAT_W - 20, function(text)
        S.search = text or ""
        Builder:RenderPalette()
    end, "Find a piece")
    search:SetPoint("TOPLEFT", list, "TOPLEFT", 0, 0)
    ui.search = search
    -- (the flat scroll bar sits right of the scroll frame: leave it room)
    local scroll = UI():CreateScrollFrame(list)
    scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -30)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -2, 0)
    scroll:SetSize(PAL_W - CAT_W - 22, 520)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(PAL_W - CAT_W - 22, 10)
    scroll:SetScrollChild(child)
    pal.scroll, pal.child = scroll, child
    pal.items = {}
    pal.heads = {}
    -- dropping a piece on the palette takes it away: the palette shows it while one is dragged over it
    pal.trash = pal:CreateTexture(nil, "OVERLAY")
    pal.trash:SetAllPoints()
    pal.trash:SetColorTexture(0.6, 0.12, 0.1, 0.18)
    pal.trash:Hide()
    pal.trashFs = Text(pal, "GameFontHighlight", 12)
    pal.trashFs:SetPoint("CENTER", pal, "CENTER", 0, 0)
    pal.trashFs:SetText("Drop here to take it away")
    pal.trashFs:SetTextColor(1, 0.85, 0.82)
    pal.trashFs:Hide()
end

-- The pieces of the palette's view: { header, keys / pieces ... }.
local CTX_DESC = {
    winner = "who won", loser = "who lost", player1 = "the match's first player", player2 = "its second player",
    both = "the two players", opponent = "the other one of the match", score = "like 2-1", game = "game number",
    match = "match number", round = "round number", finalist1 = "a finalist", finalist2 = "the other finalist",
    champion = "who won it all", runnerup = "who lost the final", third = "won the bronze", player = "who it's about",
    each = "one player at a time", answer = "what the players said",
}

local function PaletteGroups()
    local d = Def()
    local groups = {}
    local function group(title, list) if #list > 0 then groups[#groups + 1] = { title = title, list = list } end end
    local q = string.lower(S.search or "")
    if q ~= "" then
        local found = {}
        for _, cat in ipairs(B().CATS) do
            for _, k in ipairs(B().PALETTE[cat.key] or {}) do
                local t = string.lower((B().PIECES[k].text or ""):gsub("{%d}", ""))
                if t:find(q, 1, true) then found[#found + 1] = { key = k } end
            end
        end
        for name, c in pairs(B().CTX) do
            if c.label:find(q, 1, true) then found[#found + 1] = { piece = { k = "ctx", a = { name } } } end
        end
        group("Found", found)
        return groups
    end
    local cat = S.cat or "ev"
    if S.inside and cat == "sm" then
        local inner = {}
        for _, k in ipairs(B().INNER_PALETTE.bracket) do inner[#inner + 1] = { key = k } end
        group("Bracket's own pieces", inner)
    end
    local main = {}
    for _, k in ipairs(B().PALETTE[cat] or {}) do main[#main + 1] = { key = k } end
    if cat == "ev" then
        local base, smart = {}, {}
        for _, it in ipairs(main) do base[#base + 1] = it end
        for _, k in ipairs({ "bk.start", "bk.end", "bk.game", "bk.final", "bk.done", "su.join", "su.close" }) do
            smart[#smart + 1] = { key = k }
        end
        group("Events", base)
        group("From smart blocks", smart)
        return groups
    end
    if cat == "pl" then
        group("Players", main)
        local ctx = {}
        for _, name in ipairs(B().CTX_ORDER) do
            if name ~= "answer" then ctx[#ctx + 1] = { piece = { k = "ctx", a = { name } }, desc = CTX_DESC[name] } end
        end
        group("From \"when\" pieces", ctx)
        return groups
    end
    if cat == "pt" then
        group("Points", main)
        local vars = {}
        for _, v in ipairs(d.vars or {}) do vars[#vars + 1] = { piece = { k = "var", a = { v.n } } } end
        vars[#vars + 1] = { button = "Make a variable", fn = function() Builder:NewVariable() end }
        group("Variables", vars)
        return groups
    end
    if cat == "sm" then
        local blocks = {}
        for _, kind in ipairs(B().SMART_ORDER) do
            blocks[#blocks + 1] = { button = "Add a " .. B().SMART[kind].label, icon = B().SMART[kind].icon,
                fn = function() Builder:AddBlock(kind) end }
        end
        group("Smart blocks", blocks)
        group("Their pieces", main)
        return groups
    end
    group(CAT_LABEL[cat] or "", main)
    return groups
end

-- Blocks to name in a new piece's block blank: the first of that kind in the event.
local function FillBlocks(p)
    local pd = B().PIECES[p.k]
    for i, a in ipairs(pd and pd.args or {}) do
        if a.t == "block" and p.a[i] == nil then
            local list = B():BlocksOf(Def(), a.kind)
            p.a[i] = list[1]
        end
    end
    return p
end

function Builder:RenderPalette()
    local pal = ui.pal
    if not pal then return end
    for _, b in ipairs(pal.cats) do
        local on = (S.search or "") == "" and b.cat == (S.cat or "ev")
        b.hl:SetShown(on)
        b.bar:SetShown(on)
        b.fs:SetTextColor(on and 1 or 0.66, on and 1 or 0.66, on and 1 or 0.68)
    end
    local child = pal.child
    for _, it in ipairs(pal.items) do
        if it.draw then EP():Release(it.draw) end
        it.draw = nil
        it:Hide()
    end
    for _, h in ipairs(pal.heads) do h:Hide() end
    local y, n, nh = 2, 0, 0
    local d = Def()
    for _, g in ipairs(PaletteGroups()) do
        nh = nh + 1
        local h = pal.heads[nh]
        if not h then
            h = Text(child, "GameFontNormal", 11)
            pal.heads[nh] = h
        end
        h:SetText(g.title)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        h:Show()
        y = y + 20
        for _, entry in ipairs(g.list) do
            n = n + 1
            local it = pal.items[n]
            if not it then
                it = CreateFrame("Button", nil, child)
                it:RegisterForClicks("LeftButtonUp")
                it.fs = Text(it, "GameFontHighlight", 11)
                it.desc = Text(it, "GameFontHighlightSmall", 10)
                it.desc:SetTextColor(0.55, 0.55, 0.58)
                it.ic = it:CreateTexture(nil, "ARTWORK")
                it.ic:SetSize(16, 16)
                it.ic:SetPoint("LEFT", it, "LEFT", 8, 0)
                pal.items[n] = it
                UI():AddEdges(it)
                it.bg = it:CreateTexture(nil, "BACKGROUND")
                it.bg:SetAllPoints()
            end
            it:Show()
            it:ClearAllPoints()
            it.entry = entry
            it.fs:Hide()
            it.desc:Hide()
            it.ic:Hide()
            UI():SetEdgeColor(it, 0, 0, 0, 0)
            it.bg:SetColorTexture(0, 0, 0, 0)
            local h = 26
            if entry.button then
                it.fs:SetText(entry.button)
                it.fs:ClearAllPoints()
                it.fs:SetPoint("LEFT", it, "LEFT", entry.icon and 30 or 10, 0)
                it.fs:Show()
                if entry.icon then
                    it.ic:SetTexture(entry.icon)
                    it.ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    it.ic:Show()
                end
                UI():SetEdgeColor(it, 0.34, 0.34, 0.38, 0.9)
                it.bg:SetColorTexture(0.1, 0.1, 0.12, 0.92)
                it:SetSize(PAL_W - CAT_W - 26, 26)
                it:SetScript("OnClick", function(self) if CanEdit() and self.entry.fn then self.entry.fn() end end)
                it:SetScript("OnMouseDown", nil)
            else
                local piece = entry.piece or FillBlocks(B():New(entry.key))
                local draw = EP():Draw(it, piece, { def = d, static = true })
                -- a piece wider than the palette is shown smaller (it drops onto the canvas at full size)
                local avail = PAL_W - CAT_W - 22
                local k = (draw.w or 0) > avail and avail / draw.w or 1
                draw:SetScale(k)
                draw:SetPoint("TOPLEFT", it, "TOPLEFT", 0, 0)
                it.draw = draw
                h = floor((draw.h or 28) * k + 0.5) + (Shape(piece) == "hat" and 4 or 2)
                local w = min(avail, max(30, (draw.w or 100) * k))
                if entry.desc then
                    it.desc:SetText(entry.desc)
                    it.desc:ClearAllPoints()
                    it.desc:SetPoint("LEFT", it, "LEFT", w + 6, (Shape(piece) == "hat") and -5 or 0)
                    it.desc:SetWidth(max(10, PAL_W - CAT_W - 26 - w - 6))
                    it.desc:Show()
                end
                it:SetSize(PAL_W - CAT_W - 22, h)
                it.piece = piece
                it:SetScript("OnClick", nil)
                it:SetScript("OnMouseDown", function(self, button)
                    if button == "LeftButton" and CanEdit() then Builder:PressNew(self.piece, self) end
                end)
            end
            it:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            y = y + h + 6
        end
        y = y + 4
    end
    -- a search that finds nothing says so (the list would be empty)
    if not pal.none then
        pal.none = Text(child, "GameFontHighlightSmall", 11)
        pal.none:SetWordWrap(true)
        pal.none:SetWidth(PAL_W - CAT_W - 26)
        pal.none:SetTextColor(0.62, 0.62, 0.62)
        pal.none:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -4)
    end
    if nh == 0 then
        pal.none:SetText("No piece has those words. Try one word, like \"say\" or \"winner\".")
        pal.none:Show()
        y = 40
    else
        pal.none:Hide()
    end
    child:SetHeight(max(10, y))
end

---------------------------------------------------------------------------
-- The canvas
---------------------------------------------------------------------------

CreateCanvas = function(body)
    local cv = CreateFrame("Frame", nil, body)
    cv:SetPoint("TOPLEFT", body, "TOPLEFT", PAL_W, 0)
    cv:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    cv:SetSize(WIN_W - 12 - PAL_W, WIN_H - 31 - TOP_H)
    cv:SetClipsChildren(true)
    cv:EnableMouse(true)
    cv:EnableMouseWheel(true)
    local bg = cv:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetColorTexture(0.043, 0.043, 0.055, 1)
    -- the dots (tiled), moved with the view
    cv.grid = cv:CreateTexture(nil, "BACKGROUND", nil, -1)
    cv.grid:SetAllPoints()
    cv.grid:SetTexture(GRID, "REPEAT", "REPEAT")   -- tiled by its tex coords (ApplyView)
    ui.cv = cv
    -- the view: an unscaled holder sits where the content's top-left is (canvas pixels: the pan), the content in it
    -- carries the zoom. (A scaled frame's own anchor offsets are in its scaled units; the holder keeps the pan plain.)
    local holder = CreateFrame("Frame", nil, cv)
    holder:SetSize(4000, 4000)
    holder:SetPoint("TOPLEFT", cv, "TOPLEFT", 0, 0)
    ui.holder = holder
    local content = CreateFrame("Frame", nil, holder)
    content:SetSize(4000, 4000)
    content:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
    ui.content = content
    ui.scripts = {}     -- [script] = its frame
    ui.cards = {}       -- [bid] = card
    ui.notes = {}
    -- panning (left drag on the empty canvas), zoom (wheel), right-click menu
    cv:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then Builder:BeginPan() end
    end)
    cv:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and not S.drag then Builder:CanvasMenu(self) end
        S.pan = nil
    end)
    cv:SetScript("OnMouseWheel", function(self, delta) Builder:Zoom(delta > 0 and 1 or -1, true) end)
    cv:SetScript("OnUpdate", function() Builder:OnCanvasUpdate() end)
    -- the ghost: where a dragged stack would land
    ui.ghost = CreateFrame("Frame", nil, content)
    ui.ghost:SetFrameLevel(5)
    ui.ghost.bg = ui.ghost:CreateTexture(nil, "ARTWORK")
    ui.ghost.bg:SetAllPoints()
    ui.ghost.bg:SetColorTexture(1, 1, 1, 0.13)
    UI():AddEdges(ui.ghost, "OVERLAY")
    UI():SetEdgeColor(ui.ghost, 1, 1, 1, 0.4)
    ui.ghost:Hide()
    -- a blank that would take the dragged value
    ui.slotHl = CreateFrame("Frame", nil, content)
    UI():AddEdges(ui.slotHl, "OVERLAY")
    UI():SetEdgeColor(ui.slotHl, 1, 0.82, 0, 0.95)
    ui.slotHl:Hide()
    -- the ribbon (inside a smart block)
    local rb = CreateFrame("Frame", nil, cv)
    rb:SetPoint("TOPLEFT", cv, "TOPLEFT", 12, -12)
    rb:SetPoint("TOPRIGHT", cv, "TOPRIGHT", -12, -12)
    rb:SetHeight(44)
    rb:SetFrameLevel(cv:GetFrameLevel() + 900)
    rb.bg = rb:CreateTexture(nil, "BACKGROUND")
    rb.bg:SetAllPoints()
    rb.bg:SetColorTexture(0.078, 0.07, 0.047, 0.96)
    EUI():Edge(rb, 0.84, 0.68, 0.26, 0.6)
    rb.icon = rb:CreateTexture(nil, "ARTWORK")
    rb.icon:SetSize(26, 26)
    rb.icon:SetPoint("LEFT", rb, "LEFT", 12, 0)
    rb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    rb.t1 = Text(rb, "GameFontHighlight", 12)
    rb.t1:SetPoint("TOPLEFT", rb.icon, "TOPRIGHT", 10, 1)
    rb.t2 = Text(rb, "GameFontHighlightSmall", 10.5)
    rb.t2:SetPoint("TOPLEFT", rb.t1, "BOTTOMLEFT", 0, -3)
    rb.t2:SetTextColor(0.74, 0.71, 0.6)
    rb.btn = UI():CreateSleekButton(rb, "Make my own copy", 150, 24, function() Builder:CopyInner() end, "primary")
    rb.btn:SetPoint("RIGHT", rb, "RIGHT", -8, 0)
    rb:Hide()
    ui.ribbon = rb
    -- the empty stage's words
    local em = CreateFrame("Frame", nil, cv)
    em:SetSize(380, 170)
    em:SetPoint("CENTER", cv, "CENTER", 0, 10)
    em.t = Text(em, "GameFontHighlight", 14)
    em.t:SetJustifyH("CENTER")
    em.t:SetPoint("TOP", em, "TOP", 0, -60)
    em.t2 = Text(em, "GameFontHighlightSmall", 11.5)
    em.t2:SetJustifyH("CENTER")
    em.t2:SetWordWrap(true)
    em.t2:SetWidth(320)
    em.t2:SetPoint("TOP", em.t, "BOTTOM", 0, -6)
    em.t2:SetTextColor(0.62, 0.62, 0.62)
    em.start = UI():CreateSleekButton(em, "Start from the Friday duel cup", 220, 24, function() Builder:UseStarter() end)
    em.start:SetPoint("TOP", em.t2, "BOTTOM", 0, -12)
    em:Hide()
    ui.empty = em
    -- bottom right: the overview of the canvas and the zoom
    local zc = CreateFrame("Frame", nil, cv)
    zc:SetSize(130, 24)
    zc:SetPoint("BOTTOMRIGHT", cv, "BOTTOMRIGHT", -10, 10)
    zc:SetFrameLevel(cv:GetFrameLevel() + 900)
    zc.bg = zc:CreateTexture(nil, "BACKGROUND")
    zc.bg:SetAllPoints()
    zc.bg:SetColorTexture(0.055, 0.055, 0.067, 0.94)
    EUI():Edge(zc, 0.34, 0.34, 0.38, 0.9)
    local function zb(icon, x, w, fn, tip)
        local b = CreateFrame("Button", nil, zc)
        b:SetSize(w, 24)
        b:SetPoint("LEFT", zc, "LEFT", x, 0)
        b.t = b:CreateTexture(nil, "ARTWORK")
        b.t:SetSize(11, 11)
        b.t:SetPoint("CENTER")
        if icon then EUI():Glyph(b.t, icon, 0.81, 0.81, 0.81) end
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetScript("OnClick", fn)
        if tip then
            b:SetScript("OnEnter", function(self) Tip(self, tip) end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return b
    end
    zc.minus = zb(nil, 0, 26, function() Builder:Zoom(-1) end, "Zoom out")
    zc.minus.t:SetTexture(WHITE)
    zc.minus.t:SetSize(9, 2)
    zc.minus.t:SetVertexColor(0.81, 0.81, 0.81)
    -- the percentage: a click goes back to 100%
    zc.reset = zb(nil, 26, 50, function() Builder:ZoomTo(1) end, "Back to 100%")
    zc.reset.t:Hide()
    zc.pct = Text(zc.reset, "GameFontHighlight", 12)
    zc.pct:SetJustifyH("CENTER")
    zc.pct:SetPoint("CENTER", zc.reset, "CENTER", 0, 0)
    zc.plus = zb(UI().ICON.plus or 39, 76, 26, function() Builder:Zoom(1) end, "Zoom in")
    zc.fit = zb(35, 102, 28, function() Builder:ZoomToFit() end, "Zoom to fit")
    ui.zoom = zc
    local ov = CreateFrame("Button", nil, cv)
    ov:SetSize(132, 82)
    ov:SetPoint("BOTTOMRIGHT", zc, "TOPRIGHT", 0, 6)
    ov:SetFrameLevel(cv:GetFrameLevel() + 900)
    ov.bg = ov:CreateTexture(nil, "BACKGROUND")
    ov.bg:SetAllPoints()
    ov.bg:SetColorTexture(0.055, 0.055, 0.067, 0.92)
    EUI():Edge(ov, 0.34, 0.34, 0.38, 0.45)
    ov:SetClipsChildren(true)
    ov.boxes = {}
    ov.vp = CreateFrame("Frame", nil, ov)
    EUI():Edge(ov.vp, 1, 0.82, 0, 0.85)
    ov.vp.bg = ov.vp:CreateTexture(nil, "BACKGROUND")
    ov.vp.bg:SetAllPoints()
    ov.vp.bg:SetColorTexture(1, 0.82, 0, 0.05)
    ov:SetScript("OnClick", function(self) Builder:OverviewClick(self) end)
    ui.overview = ov
    -- bottom: the problems pill (or ready)
    local st = CreateFrame("Button", nil, cv)
    st:SetHeight(24)
    st:SetPoint("BOTTOMRIGHT", zc, "BOTTOMLEFT", -10, 0)
    st:SetFrameLevel(cv:GetFrameLevel() + 900)
    st.bg = st:CreateTexture(nil, "BACKGROUND")
    st.bg:SetAllPoints()
    st.bg:SetColorTexture(0.055, 0.055, 0.067, 0.94)
    UI():AddEdges(st)
    st.icon = st:CreateTexture(nil, "ARTWORK")
    st.icon:SetSize(13, 13)
    st.icon:SetPoint("LEFT", st, "LEFT", 8, 0)
    st.fs = Text(st, "GameFontHighlight", 11)
    st.fs:SetPoint("LEFT", st.icon, "RIGHT", 7, 0)
    st:SetScript("OnClick", function() Builder:JumpToProblem() end)
    ui.status = st
end

-- The view of a stage: pan (content units) and zoom.
local function View()
    local key = S.inside and ("in:" .. S.inside) or (S.stage or "s1")
    S.views = S.views or {}
    local v = S.views[key]
    if not v then
        v = { x = 0, y = 0, z = 1 }
        S.views[key] = v
    end
    S.view = v
    return v
end

-- The canvas' size (its own units).
local function CanvasSize()
    local w, h = ui.cv:GetWidth() or 0, ui.cv:GetHeight() or 0
    if w <= 1 or h <= 1 then w, h = WIN_W - 12 - PAL_W, WIN_H - 31 - TOP_H end
    return w, h
end

-- v.x, v.y: where the content's top-left is, in canvas units from the canvas' top-left (y down); v.z: the zoom. A
-- content point (cx, cy) shows at (v.x + cx * z, v.y + cy * z).
local function ApplyView()
    local v = View()
    ui.content:SetScale(v.z)
    ui.holder:ClearAllPoints()
    ui.holder:SetPoint("TOPLEFT", ui.cv, "TOPLEFT", v.x, -v.y)
    -- the dots move and scale with it, and fade a little zoomed out (they crowd together there)
    local w, h = CanvasSize()
    local tile = GRID_STEP * v.z
    local ox, oy = (-v.x / tile) % 1, (-v.y / tile) % 1
    ui.cv.grid:SetTexCoord(ox, ox + w / tile, oy, oy + h / tile)
    ui.cv.grid:SetAlpha(min(1, 0.45 + 0.55 * v.z))
    ui.zoom.pct:SetText(floor(v.z * 100 + 0.5) .. "%")
end

-- Cursor -> content coordinates (x right, y down).
local function CursorInContent()
    local c = ui.content
    local s = c:GetEffectiveScale()
    local x, y = GetCursorPosition()
    local l, t = c:GetLeft() or 0, c:GetTop() or 0
    return x / s - l, t - y / s
end

local function CursorInFrame(f)
    local s = f:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x, y = x / s, y / s
    -- (its edges: a frame sized by two anchors, like the palette, has no height of its own)
    local l, b, r, t = f:GetLeft(), f:GetBottom(), f:GetRight(), f:GetTop()
    if not (l and b and r and t) then return false end
    return x >= l and x <= r and y >= b and y <= t
end

-- The cursor in canvas units (from its top-left, y down), or nil off the canvas.
local function CursorInCanvas()
    local cv = ui.cv
    local l, t = cv:GetLeft(), cv:GetTop()
    if not l then return nil end
    local s = cv:GetEffectiveScale()
    local x, y = GetCursorPosition()
    return x / s - l, t - y / s
end

-- The zoom moves in steps (round percentages), eased over a moment.
local ZOOMS = { 0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5 }
local Z_MIN, Z_MAX = ZOOMS[1], ZOOMS[#ZOOMS]
local ZOOM_TIME = 0.16

local function NextZoom(z, dir)
    if dir > 0 then
        for _, l in ipairs(ZOOMS) do if l > z + 0.005 then return l end end
        return Z_MAX
    end
    for i = #ZOOMS, 1, -1 do if ZOOMS[i] < z - 0.005 then return ZOOMS[i] end end
    return Z_MIN
end

local function Ease(t) return 1 - (1 - t) ^ 3 end

-- Moves the view to x, y, z: eased (a zoom keeps the point under sx, sy still all the way), or at once.
local function MoveView(x, y, z, instant, sx, sy)
    local v = View()
    if instant then
        S.zoomAnim = nil
        v.x, v.y, v.z = x, y, z
        ApplyView()
        Builder:RenderOverview()
        return
    end
    local a = { v = v, t0 = GetTime(), x0 = v.x, y0 = v.y, z0 = v.z, x1 = x, y1 = y, z1 = z }
    if sx then a.sx, a.sy, a.cx, a.cy = sx, sy, (sx - v.x) / v.z, (sy - v.y) / v.z end
    S.zoomAnim = a
end

-- One frame of an eased move (the canvas' OnUpdate).
local function StepView()
    local a = S.zoomAnim
    if not a then return end
    if a.v ~= View() then S.zoomAnim = nil return end       -- another stage (or the inside view) came up
    local t = min(1, (GetTime() - a.t0) / ZOOM_TIME)
    local e = Ease(t)
    local v = a.v
    v.z = a.z0 + (a.z1 - a.z0) * e
    if a.sx then
        v.x, v.y = a.sx - a.cx * v.z, a.sy - a.cy * v.z
    else
        v.x, v.y = a.x0 + (a.x1 - a.x0) * e, a.y0 + (a.y1 - a.y0) * e
    end
    if t >= 1 then
        v.x, v.y, v.z = a.x1, a.y1, a.z1
        S.zoomAnim = nil
        ApplyView()
        Builder:RenderOverview()
        return
    end
    ApplyView()
end

-- A left press on the empty canvas: the view follows the mouse until it's let go (OnCanvasUpdate).
function Builder:BeginPan()
    local x, y = GetCursorPosition()
    S.zoomAnim = nil
    local v = View()
    S.pan = { x = x, y = y, vx = v.x, vy = v.y }
end

-- Zooms to z around a canvas point (sx, sy; default: the canvas' middle).
function Builder:ZoomTo(z, sx, sy, instant)
    local v = View()
    z = max(Z_MIN, min(Z_MAX, z))
    local w, h = CanvasSize()
    sx, sy = sx or w / 2, sy or h / 2
    -- from where the view is now (an eased move still running carries on from here)
    local cx, cy = (sx - v.x) / v.z, (sy - v.y) / v.z
    MoveView(sx - cx * z, sy - cy * z, z, instant, sx, sy)
end

-- A step in (dir 1) or out (-1): the wheel around the cursor, the buttons around the middle. Steps taken while the
-- last one still eases count from where it's going.
function Builder:Zoom(dir, atCursor)
    local v = View()
    local going = S.zoomAnim and S.zoomAnim.v == v and S.zoomAnim.z1 or v.z
    local z = NextZoom(going, dir)
    if math.abs(z - v.z) < 0.001 and not S.zoomAnim then return end
    local sx, sy
    if atCursor then sx, sy = CursorInCanvas() end
    self:ZoomTo(z, sx, sy)
end

---------------------------------------------------------------------------
-- Drawing the canvas
---------------------------------------------------------------------------

local function ReleaseCanvas()
    for s, f in pairs(ui.scripts) do EP():Release(f) end
    ui.scripts = {}
    -- and any drawing on the canvas nothing owns any more (a drag that never ended): it would sit there as a piece
    -- the event doesn't have
    for _, kid in ipairs({ ui.content:GetChildren() }) do
        if EP():IsDrawn(kid) and not (S.drag and S.drag.frame == kid) then EP():Release(kid) end
    end
    for _, card in pairs(ui.cards) do card:Hide() end
    for _, n in ipairs(ui.notes) do n:Hide() end
end

local OnPiece, OnBlank   -- (below)
local PlacePicker        -- (below) the picker under its blank, drawn again

local function ScriptKey(s) return (S.inside and (S.inside .. "/") or "") .. s.id end

local function DrawScriptFrame(s, problems)
    local opts = { def = Def(), problems = problems, onPiece = OnPiece, onBlank = OnBlank,
        locked = S.inside and not (Def().blocks[S.inside] and Def().blocks[S.inside].inner), static = false,
        nameOf = L().DisplayName }
    if S.practice then
        local run = L():GetPractice()
        local key = (S.inside and (S.inside .. "/") or "") .. s.id
        opts.live = run and run.lastCtx and run.lastCtx[key]
        opts.onPiece, opts.onBlank = nil, nil
        opts.static = true
    end
    if ui.picker and ui.picker:IsShown() and S.pick then opts.hot = { piece = S.pick.piece, slot = S.pick.slot } end
    local f = EP():DrawScript(ui.content, s.top, opts)
    f:SetPoint("TOPLEFT", ui.content, "TOPLEFT", s.x, -s.y)
    EP():Raise(f, ui.content:GetFrameLevel() + 10)
    f.script = s
    ui.scripts[s] = f
    -- the glow of a script that just ran (practice)
    local at = S.glow and S.glow[ScriptKey(s)]
    if at and GetTime() - at < 1.6 then Builder:GlowScript(f, at) end
    return f
end

local CreateCard, CreateNote

function Builder:RenderCanvas()
    if not ui.content then return end
    ReleaseCanvas()
    ApplyView()
    local d = Def()
    local problems = B():ProblemsByPiece(d)
    local scripts = Scripts()
    for _, s in ipairs(scripts) do DrawScriptFrame(s, problems) end
    -- smart blocks of this stage (not inside one)
    local nBlocks = 0
    if not S.inside then
        for _, bid in ipairs(B():BlocksOf(d)) do
            local b = d.blocks[bid]
            if b.stage == S.stage then
                nBlocks = nBlocks + 1
                local card = ui.cards[bid] or CreateCard(bid)
                ui.cards[bid] = card
                card:Fill(bid)
                card:ClearAllPoints()
                card:SetPoint("TOPLEFT", ui.content, "TOPLEFT", b.x, -b.y)
                card:Show()
            end
        end
    end
    -- notes
    local i = 0
    for ni, n in ipairs(d.notes or {}) do
        if (n.st or "*") == NoteSpot() then
            i = i + 1
            local f = ui.notes[i] or CreateNote(i)
            ui.notes[i] = f
            f:Fill(ni, n)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", ui.content, "TOPLEFT", n.x, -n.y)
            f:Show()
        end
    end
    -- the ribbon inside a block
    local rb = ui.ribbon
    if S.inside then
        local b = d.blocks[S.inside]
        rb.icon:SetTexture(B().SMART[b.kind].icon)
        if b.inner then
            rb.t1:SetText("This " .. B():BlockLabel(d, S.inside) .. " runs your own copy of its pieces.")
            rb.t2:SetText("Change them as you like. Going back to the built-in pieces drops your changes.")
            rb.btn:SetText("Back to built-in")
            rb.btn:SetKind("secondary")
        else
            rb.t1:SetText(B():BlockLabel(d, S.inside) .. " is built in. These are the pieces it's made of.")
            rb.t2:SetText("They're locked so updates can fix them. Make your own copy to change how matches are decided.")
            rb.btn:SetText("Make my own copy")
            rb.btn:SetKind(S.readOnly and "secondary" or "primary")
        end
        rb.btn:SetWidth((rb.btn:GetFontString():GetStringWidth() or 100) + 28)
        rb:Show()
    else
        rb:Hide()
    end
    -- an empty stage says what to do
    local em = ui.empty
    if #scripts == 0 and nBlocks == 0 and i == 0 and not S.practice then
        local stName = B():StageName(d, S.stage)
        em.t:SetText("Nothing runs in " .. stName .. " yet")
        em.t2:SetText(S.stage == "*" and "Pieces here run in every stage: drag a \"when\" piece here."
            or ("Drag a \"when\" piece here. Pieces in this stage run while the event is in " .. stName .. "."))
        local blankEvent = #d.scripts == 0 and next(d.blocks) == nil
        em.start:SetShown(blankEvent and CanEdit())
        em:Show()
    else
        em:Hide()
    end
    self:RenderOverview()
    self:RenderStatus()
    if ui.picker and ui.picker:IsShown() and S.pick then PlacePicker() end
end

-- The overview: every script / block of this view as a small coloured box, the visible part in gold.
function Builder:RenderOverview()
    local ov = ui.overview
    for _, b in ipairs(ov.boxes) do b:Hide() end
    local items = {}
    local minX, minY, maxX, maxY = 0, 0, 760, 580
    for s, f in pairs(ui.scripts) do
        local pd = B().PIECES[s.top.k]
        items[#items + 1] = { x = s.x, y = s.y, w = f.w or 100, h = f.h or 40, cat = pd and pd.cat or "ev" }
    end
    for bid, card in pairs(ui.cards) do
        if card:IsShown() then
            local b = Def().blocks[bid]
            items[#items + 1] = { x = b.x, y = b.y, w = 318, h = card:GetHeight() or 240, cat = "sm" }
        end
    end
    for _, it in ipairs(items) do
        minX, minY = min(minX, it.x), min(minY, it.y)
        maxX, maxY = max(maxX, it.x + it.w), max(maxY, it.y + it.h)
    end
    local v = View()
    local vw, vh = (ui.cv:GetWidth() or 762) / v.z, (ui.cv:GetHeight() or 585) / v.z
    if vw <= 1 then vw, vh = 762 / v.z, 585 / v.z end
    local vx, vy = -v.x / v.z, -v.y / v.z
    minX, minY = min(minX, vx), min(minY, vy)
    maxX, maxY = max(maxX, vx + vw), max(maxY, vy + vh)
    local sc = min(124 / max(1, maxX - minX), 74 / max(1, maxY - minY))
    ov.map = { minX = minX, minY = minY, sc = sc }
    for i, it in ipairs(items) do
        local b = ov.boxes[i]
        if not b then
            b = ov:CreateTexture(nil, "ARTWORK")
            ov.boxes[i] = b
        end
        local c = B().CAT[it.cat] or B().CAT.ev
        b:SetTexture(WHITE)
        b:SetVertexColor(c.f2[1], c.f2[2], c.f2[3], 0.9)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", ov, "TOPLEFT", 4 + (it.x - minX) * sc, -4 - (it.y - minY) * sc)
        b:SetSize(max(2, it.w * sc), max(2, it.h * sc))
        b:Show()
    end
    ov.vp:ClearAllPoints()
    ov.vp:SetPoint("TOPLEFT", ov, "TOPLEFT", 4 + (vx - minX) * sc, -4 - (vy - minY) * sc)
    ov.vp:SetSize(max(4, vw * sc), max(4, vh * sc))
end

function Builder:OverviewClick(ov)
    local m = ov.map
    if not m then return end
    local s = ov:GetEffectiveScale()
    local x, y = GetCursorPosition()
    local lx, ly = x / s - (ov:GetLeft() or 0), (ov:GetTop() or 0) - y / s
    local cx, cy = m.minX + (lx - 4) / m.sc, m.minY + (ly - 4) / m.sc
    -- that point to the canvas' middle
    local v = View()
    local w, h = CanvasSize()
    MoveView(w / 2 - cx * v.z, h / 2 - cy * v.z, v.z)
end

-- How many pieces need a fix (click: the first of them), or that it's ready.
function Builder:RenderStatus()
    local st = ui.status
    local probs = B():Problems(Def())
    if S.practice then st:Hide() return end
    st:Show()
    if #probs > 0 then
        local word = #probs == 1 and "1 piece needs a fix" or (#probs .. " pieces need a fix")
        local first = probs[1]
        if #probs == 1 and first.text and first.text:find("^Needs a player") then word = "1 piece needs a player" end
        st.fs:SetText(word)
        st.fs:SetTextColor(1, 0.83, 0.64)
        st.icon:SetTexture(UI().ICON_WARN)
        st.icon:SetTexCoord(0, 1, 0, 1)
        UI():SetEdgeColor(st, 1, 0.55, 0.1, 0.6)
    elseif S.readOnly then
        st.fs:SetText("By " .. EUI():Plain(Def().by) .. ": make a copy to change it")
        st.fs:SetTextColor(0.8, 0.8, 0.82)
        EUI():Glyph(st.icon, UI().ICON.lock or 52, 0.91, 0.77, 0.35)
        UI():SetEdgeColor(st, 0.34, 0.34, 0.38, 0.9)
    else
        local state = Ev():GetDef(Def().id) and Ev():ReviewState(Ev():GetDef(Def().id)) or "draft"
        st.fs:SetText(state == "ranked" and not S.dirty and "Ranked · ready to host" or "Every piece is set")
        st.fs:SetTextColor(0.72, 0.94, 0.78)
        st.icon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        st.icon:SetTexCoord(0, 1, 0, 1)
        UI():SetEdgeColor(st, 0.35, 0.86, 0.47, 0.5)
    end
    st:SetWidth(8 + 13 + 7 + (st.fs:GetStringWidth() or 100) + 10)
end

-- Goes to the first piece that needs a fix: its stage, centred, flashing.
function Builder:JumpToProblem()
    local probs = B():Problems(Def())
    local pr = probs[1]
    if not pr then return end
    local d = Def()
    -- a script of a smart block's own copy is "blockId/scriptId": that block is opened
    local bid, sid = tostring(pr.script):match("^(.-)/(.+)$")
    local b = bid and d.blocks[bid]
    local list = (b and b.inner) or d.scripts
    if not (b and b.inner) then bid, sid = nil, pr.script end
    for _, s in ipairs(list) do
        if s.id == sid then
            self:ClosePicker()
            S.inside = bid
            S.stage = bid and b.stage or s.st
            if bid then S.cat = "sm" end
            Refresh()
            local f = ui.scripts[s]
            local v = View()
            MoveView(120 - s.x * v.z, 120 - s.y * v.z, v.z, true)
            local pf = f and f.at and pr.piece and f.at[pr.piece]
            if pf then UI():Glow(pf, true); ns.Util.After(1.2, function() UI():Glow(pf, false) end) end
            return
        end
    end
end

---------------------------------------------------------------------------
-- Smart block cards
---------------------------------------------------------------------------

-- Each setting's dropdown is as wide as its longest choice (no "...").
local CARD_DD_W = { fmt = 168, seed = 168, closes = 196, bo = 60, fbo = 60, spots = 60, noshow = 84, atonce = 112 }

CreateCard = function(bid)
    local card = CreateFrame("Frame", nil, ui.content)
    card:SetWidth(318)
    card:EnableMouse(true)
    card.bg = card:CreateTexture(nil, "BACKGROUND")
    card.bg:SetAllPoints()
    card.bg:SetTexture(WHITE)
    if card.bg.SetGradient and CreateColor then
        card.bg:SetGradient("VERTICAL", CreateColor(0.102, 0.102, 0.122, 1), CreateColor(0.145, 0.145, 0.172, 1))
    else
        card.bg:SetColorTexture(0.12, 0.12, 0.145, 1)
    end
    EUI():Edge(card, 0.84, 0.68, 0.26, 0.72)
    card.icon = card:CreateTexture(nil, "ARTWORK")
    card.icon:SetSize(26, 26)
    card.icon:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
    card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    card.name = Text(card, "GameFontNormal", 13)
    card.name:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 9, -1)
    card.kind = Text(card, "GameFontHighlightSmall", 10)
    card.kind:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -1)
    card.kind:SetTextColor(0.55, 0.55, 0.58)
    card.kind:SetText("smart block")
    card.open = UI():CreateSleekButton(card, "Open", 52, 22, function(self) Builder:OpenInside(self:GetParent().bid) end)
    card.open:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -10)
    card.head = card:CreateTexture(nil, "BORDER")
    card.head:SetColorTexture(1, 1, 1, 0.07)
    card.head:SetHeight(1)
    card.head:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -42)
    card.head:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -42)
    card.rows = {}
    card.chips = {}
    card.foot = card:CreateTexture(nil, "BORDER")
    card.foot:SetColorTexture(1, 1, 1, 0.06)
    card.foot:SetHeight(1)
    card.givesLab = Text(card, "GameFontHighlightSmall", 10)
    card.givesLab:SetText("Gives")
    card.givesLab:SetTextColor(0.55, 0.55, 0.58)
    -- dragged by its head; right-click for its menu
    card:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and CanEdit() then
            local cx, cy = CursorInContent()
            local b = Def().blocks[self.bid]
            S.cardDrag = { bid = self.bid, dx = cx - b.x, dy = cy - b.y, before = Snapshot() }
        end
    end)
    card:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then Builder:BlockMenu(self, self.bid) end
        if S.cardDrag then
            local moved = S.cardDrag.moved
            local before = S.cardDrag.before
            S.cardDrag = nil
            if moved then Changed(before) end
        end
    end)
    function card:Fill(id)
        self.bid = id
        local d = Def()
        local b = d.blocks[id]
        local sm = B().SMART[b.kind]
        self.icon:SetTexture(sm.icon)
        self.name:SetText(B():BlockLabel(d, id))
        self.open:SetShown(b.kind == "bracket")
        local y = 46
        for i, o in ipairs(sm.settings) do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, self)
                row:SetSize(298, 27)
                row.lab = Text(row, "GameFontHighlightSmall", 11)
                row.lab:SetTextColor(0.62, 0.62, 0.62)
                row.lab:SetPoint("LEFT", row, "LEFT", 0, 0)
                self.rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -y)
            row:Show()
            row.lab:SetText(o.label)
            if row.ctl then row.ctl:Hide() end
            if o.kind == "bool" then
                row.sw = row.sw or UI():CreateSwitch(row, function() return B():SmartSetting(Def().blocks[self.bid], row.key) end,
                    function(on)
                        if not CanEdit() then return end
                        local before = Snapshot()
                        Def().blocks[self.bid].set[row.key] = on and true or false
                        Changed(before)
                    end)
                row.sw:ClearAllPoints()
                row.sw:SetPoint("LEFT", row, "LEFT", 70, 0)
                row.key = o.key
                row.sw:Show()
                if row.sw.Refresh then row.sw:Refresh() end
                if row.dd then row.dd:Hide() end
            else
                row.key = o.key
                row.dd = row.dd or UI():CreateSleekMenuButton(row, "", 168, function(root)
                    local opt
                    for _, x in ipairs(sm.settings) do if x.key == row.key then opt = x end end
                    local list = opt.kind == "dur" and opt.choices or opt.choices
                    if opt.kind == "num" then
                        list = {}
                        for _, n in ipairs({ 4, 8, 12, 16, 20, 24, 32, 40 }) do list[#list + 1] = n end
                    end
                    for _, c in ipairs(list or {}) do
                        local v, label = c, nil
                        if type(c) == "table" then v, label = c[1], c[2] end
                        label = label or (opt.kind == "dur" and B():DurationText(v)) or tostring(v)
                        root:CreateRadio(label, function() return B():SmartSetting(Def().blocks[self.bid], row.key) == v end,
                            function()
                                if not CanEdit() then return end
                                local before = Snapshot()
                                Def().blocks[self.bid].set[row.key] = v
                                Changed(before)
                            end)
                    end
                end, 21)
                local v = B():SmartSetting(b, o.key)
                local label
                if o.kind == "choice" then
                    for _, c in ipairs(o.choices) do if c[1] == v then label = c[2] end end
                elseif o.kind == "dur" then
                    label = B():DurationText(v)
                else
                    label = tostring(v)
                end
                row.dd:SetText(label or tostring(v))
                row.dd:SetWidth(CARD_DD_W[o.key] or 92)
                row.dd:ClearAllPoints()
                row.dd:SetPoint("LEFT", row, "LEFT", 70, 0)
                row.dd:Show()
                if row.sw then row.sw:Hide() end
            end
            y = y + 27
        end
        for i = #sm.settings + 1, #self.rows do self.rows[i]:Hide() end
        -- what it gives: chips that drag their "when" piece onto the canvas
        y = y + 4
        self.foot:ClearAllPoints()
        self.foot:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -y)
        self.foot:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -y)
        y = y + 8
        self.givesLab:ClearAllPoints()
        self.givesLab:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -(y + 3))
        local keys = b.kind == "bracket" and { "bk.start", "bk.game", "bk.end", "bk.final", "bk.done" }
            or { "su.join", "su.leave", "su.close" }
        local x, row = 10 + 30, 0
        local ev = B().CAT.ev
        for i, label in ipairs(sm.gives) do
            local chip = self.chips[i]
            if not chip then
                chip = CreateFrame("Button", nil, self)
                chip:SetHeight(17)
                UI():AddPillShape(chip, 17)
                chip.fs = Text(chip, "GameFontHighlightSmall", 10)
                chip.fs:SetPoint("CENTER")
                chip:SetScript("OnEnter", function(c) Tip(c, "Drag it onto the canvas", "for its \"when\" piece.") end)
                chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
                self.chips[i] = chip
            end
            chip:SetPillColors({ ev.f[1], ev.f[2], ev.f[3], 1 }, { ev.e[1], ev.e[2], ev.e[3], 0.85 })
            chip.fs:SetText(label)
            local w = (chip.fs:GetStringWidth() or 40) + 14
            chip:SetWidth(w)
            if x + w > 308 then
                row = row + 1
                x = 10
            end
            chip:ClearAllPoints()
            chip:SetPoint("TOPLEFT", self, "TOPLEFT", x, -(y + row * 22))
            chip:Show()
            chip.key = keys[i]
            chip:SetScript("OnMouseDown", function(c, button)
                if button == "LeftButton" and CanEdit() and c.key then
                    local p = B():New(c.key)
                    p.a[1] = self.bid
                    Builder:PressNew(p, c)
                end
            end)
            x = x + w + 4
        end
        for i = #sm.gives + 1, #self.chips do self.chips[i]:Hide() end
        y = y + (row + 1) * 22 + 6
        self:SetHeight(y)
    end
    return card
end

---------------------------------------------------------------------------
-- Notes on the canvas
---------------------------------------------------------------------------

CreateNote = function(i)
    local f = CreateFrame("Frame", nil, ui.content)
    f:SetSize(170, 70)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.914, 0.863, 0.682, 1)
    f.band = f:CreateTexture(nil, "BORDER")
    f.band:SetPoint("TOPLEFT")
    f.band:SetPoint("TOPRIGHT")
    f.band:SetHeight(12)
    f.band:SetColorTexture(0, 0, 0, 0.07)
    f.eb = CreateFrame("EditBox", nil, f)
    f.eb:SetMultiLine(true)
    f.eb:SetAutoFocus(false)
    f.eb:SetFontObject("GameFontHighlightSmall")
    f.eb:SetTextColor(0.23, 0.2, 0.13)
    f.eb:SetShadowOffset(0, 0)
    f.eb:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -14)
    f.eb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 6)
    f.eb:SetWidth(152)
    f.eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.eb:SetScript("OnEditFocusLost", function(self)
        local n = Def().notes[f.index]
        if n and n.text ~= self:GetText() and CanEdit() then
            local before = Snapshot()
            n.text = self:GetText()
            Changed(before)
        end
    end)
    f:EnableMouse(true)
    f:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and CanEdit() then
            local cx, cy = CursorInContent()
            local n = Def().notes[self.index]
            S.noteDrag = { index = self.index, dx = cx - n.x, dy = cy - n.y, before = Snapshot() }
        end
    end)
    f:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" and CanEdit() then
            UI():ContextMenu(self, function(root)
                root:CreateButton("Delete the note", function()
                    local before = Snapshot()
                    tremove(Def().notes, self.index)
                    Changed(before)
                end)
            end)
        end
        if S.noteDrag then
            local nd = S.noteDrag
            S.noteDrag = nil
            if nd.moved then Changed(nd.before) end
        end
    end)
    function f:Fill(index, n)
        self.index = index
        if not self.eb:HasFocus() then self.eb:SetText(n.text or "") end
        self.eb:EnableMouse(CanEdit())
    end
    return f
end

---------------------------------------------------------------------------
-- Drag and drop
---------------------------------------------------------------------------

-- A mouse press on a palette piece or a block's chip: a new copy follows the cursor once it moves.
function Builder:PressNew(piece, from)
    S.press = { piece = Copy(piece), new = true, x0 = select(1, GetCursorPosition()), y0 = select(2, GetCursorPosition()) }
end

OnPiece = function(piece, frame, button, down)
    if button == "RightButton" then
        if not down then Builder:PieceMenu(frame, piece) end
        return
    end
    if button ~= "LeftButton" or not down or not CanEdit() then return end
    local x, y = GetCursorPosition()
    S.press = { piece = piece, frame = frame, x0 = x, y0 = y }
end

-- Every frame on the canvas: a press that moves starts a drag; a drag follows the cursor; panning; moving cards.
function Builder:OnCanvasUpdate()
    StepView()
    local down = IsMouseButtonDown and IsMouseButtonDown("LeftButton")
    local press = S.press
    if press and not S.drag then
        if not down then
            S.press = nil
        else
            local x, y = GetCursorPosition()
            if abs(x - press.x0) + abs(y - press.y0) > 5 then
                S.press = nil
                self:StartDrag(press)
            end
        end
    end
    if S.drag then
        if down then self:UpdateDrag() else self:EndDrag() end
        return
    end
    if S.pan then
        if not down then S.pan = nil return end
        local x, y = GetCursorPosition()
        local s = ui.cv:GetEffectiveScale()
        local v = View()
        v.x = S.pan.vx + (x - S.pan.x) / s
        v.y = S.pan.vy - (y - S.pan.y) / s
        ApplyView()
        self:RenderOverview()
        return
    end
    for _, kind in ipairs({ "cardDrag", "noteDrag" }) do
        local cd = S[kind]
        if cd then
            if not down then
                S[kind] = nil
                if cd.moved then Changed(cd.before) end
            else
                local cx, cy = CursorInContent()
                local item = kind == "cardDrag" and Def().blocks[cd.bid] or Def().notes[cd.index]
                local nx, ny = floor(cx - cd.dx), floor(cy - cd.dy)
                if item and (nx ~= item.x or ny ~= item.y) then
                    item.x, item.y = nx, ny
                    cd.moved = true
                    local f = kind == "cardDrag" and ui.cards[cd.bid]
                    if f then
                        f:ClearAllPoints()
                        f:SetPoint("TOPLEFT", ui.content, "TOPLEFT", nx, -ny)
                    else
                        self:RenderCanvas()
                    end
                end
            end
        end
    end
end

function Builder:StartDrag(press)
    local before = Snapshot()
    local piece = press.piece
    local cx, cy = CursorInContent()
    local grabX, grabY = 12, 12
    local moveScript
    if not press.new then
        local loc = Locate(piece)
        if not loc then return end
        -- where the cursor holds the piece
        local sf = ui.scripts[loc.script]
        local pf = press.frame
        local ax, ay = 0, 0
        if sf and pf then ax, ay = EP():Abs(pf) end
        grabX, grabY = cx - (loc.script.x + ax), cy - (loc.script.y + ay)
        if loc.field == "top" then
            moveScript = loc.script
        else
            Cut(loc, piece)
        end
    end
    S.drag = { piece = piece, before = before, gx = grabX, gy = grabY, script = moveScript, new = press.new }
    -- what follows the cursor
    if moveScript then
        S.drag.frame = ui.scripts[moveScript]
    else
        self:RenderCanvas()
        S.drag.frame = EP():DrawScript(ui.content, piece, { def = Def(), static = true })
    end
    EP():Raise(S.drag.frame, ui.content:GetFrameLevel() + 2000)
    S.drag.frame:SetAlpha(0.93)
    ui.pal.trash:SetShown(not press.new)
    ui.pal.trashFs:SetShown(not press.new)
    self:UpdateDrag()
end

-- The snap targets of a dragged stack: below a piece, inside a C's arm, above a loose stack. Content coordinates.
local function StackTargets(dragged)
    local out = {}
    local last = LastOf(dragged)
    local dragCap = Shape(last) == "cap"
    for s, f in pairs(ui.scripts) do
        if not (S.drag and s == S.drag.script) then
            for piece, pf in pairs(f.at or {}) do
                local sh = Shape(piece)
                if sh ~= "value" and sh ~= "bool" then
                    local ax, ay = EP():Abs(pf)
                    local x, y = s.x + ax, s.y + ay
                    local h = pf:GetHeight() or 28
                    -- below a piece (not under a cap; a cap at the end only where nothing follows)
                    if sh ~= "cap" and (not dragCap or not piece.n) then
                        out[#out + 1] = { x = x, y = y + h, piece = piece, field = "n", script = s }
                    end
                    if (sh == "c" or sh == "c2") and (not dragCap or not piece.c1) then
                        local top = sh == "hat" and (EP().DOME + EP().HAT_H) or EP().H
                        out[#out + 1] = { x = x + EP().ARM, y = y + top, piece = piece, field = "c1", script = s }
                    end
                end
            end
            -- above a loose stack (its top is no hat): the dragged stack's last piece goes on top of it
            local ts = Shape(s.top)
            if ts ~= "hat" and ts ~= "value" and ts ~= "bool" and not dragCap then
                local hDrag = 0
                local p = dragged
                while p do hDrag = hDrag + EP():HeightOf(p); p = p.n end
                out[#out + 1] = { x = s.x, y = s.y - hDrag, above = true, script = s }
            end
        end
    end
    return out
end

function Builder:UpdateDrag()
    local dr = S.drag
    local cx, cy = CursorInContent()
    local x, y = cx - dr.gx, cy - dr.gy
    dr.frame:ClearAllPoints()
    dr.frame:SetPoint("TOPLEFT", ui.content, "TOPLEFT", x, -y)
    dr.x, dr.y = x, y
    dr.target, dr.slot = nil, nil
    ui.ghost:Hide()
    ui.slotHl:Hide()
    if CursorInFrame(ui.pal) and not dr.new then return end
    local piece = dr.piece
    if IsValue(piece) then
        -- a blank that takes it, under the cursor
        local vt = B():ValueType(piece)
        for s, f in pairs(ui.scripts) do
            for _, bl in ipairs(f.blanks or {}) do
                if B():TakesPieces(bl.t) and B():Fits(bl.t, vt) and bl.frame:IsShown() then
                    local ax, ay = EP():Abs(bl.frame)
                    local bx, by = s.x + ax, s.y + ay
                    local bw, bh = bl.frame:GetWidth() or 20, bl.frame:GetHeight() or 19
                    if cx >= bx - 4 and cx <= bx + bw + 4 and cy >= by - 4 and cy <= by + bh + 4 then
                        dr.slot = { script = s, piece = bl.piece, slot = bl.slot, t = bl.t }
                        ui.slotHl:ClearAllPoints()
                        ui.slotHl:SetPoint("TOPLEFT", ui.content, "TOPLEFT", bx - 2, -(by - 2))
                        ui.slotHl:SetSize(bw + 4, bh + 4)
                        ui.slotHl:SetFrameLevel(ui.content:GetFrameLevel() + 1990)
                        ui.slotHl:Show()
                        return
                    end
                end
            end
        end
        return
    end
    if Shape(piece) == "hat" and not dr.script then
        -- a hat starts a script: it can go on top of a loose stack only
    end
    local best, bestD
    for _, t in ipairs(StackTargets(piece)) do
        if not (Shape(piece) == "hat" and not t.above) then
            local dx, dy = t.x - x, t.y - y
            if t.above then dy = t.y - y end
            local dist = sqrt(dx * dx + dy * dy)
            if dist < SNAP and (not bestD or dist < bestD) then best, bestD = t, dist end
        end
    end
    if best then
        dr.target = best
        local w = min(220, max(60, dr.frame.w or 120))
        ui.ghost:ClearAllPoints()
        ui.ghost:SetPoint("TOPLEFT", ui.content, "TOPLEFT", best.x, -best.y)
        ui.ghost:SetSize(w, best.above and EP().H or EP().H)
        ui.ghost:SetFrameLevel(ui.content:GetFrameLevel() + 1990)
        ui.ghost:Show()
    end
end

-- Stops a press or a drag without dropping it: a piece taken out of a script goes back, a new one goes, the canvas
-- draws what the event has (Escape, the window closing, another event opening).
function Builder:CancelDrag()
    S.press = nil
    local dr = S.drag
    if not dr then return end
    S.drag = nil
    if ui.ghost then ui.ghost:Hide() end
    if ui.slotHl then ui.slotHl:Hide() end
    if ui.pal then
        ui.pal.trash:Hide()
        ui.pal.trashFs:Hide()
    end
    if not dr.script and dr.frame then EP():Release(dr.frame) end
    -- a piece cut out of its script: the event as it was before the drag
    if not dr.new and not dr.script and dr.before then S.def = dr.before end
    if win and win:IsShown() then self:RenderCanvas() end
end

function Builder:EndDrag()
    local dr = S.drag
    S.drag = nil
    ui.ghost:Hide()
    ui.slotHl:Hide()
    ui.pal.trash:Hide()
    ui.pal.trashFs:Hide()
    local overPalette = CursorInFrame(ui.pal)
    if not dr.script and dr.frame then EP():Release(dr.frame) end
    local piece = dr.piece
    if overPalette then
        -- taken away
        if dr.script then
            local list = S.inside and Scripts() or Def().scripts
            for i, s in ipairs(list) do if s == dr.script then tremove(list, i) break end end
        end
        if not dr.new then Changed(dr.before) else self:RenderCanvas() end
        return
    end
    if dr.slot then
        -- a value into a blank: what was there pops out next to it
        local p = dr.slot.piece
        local old = p.a[dr.slot.slot]
        if dr.slot.t == "text" and type(old) == "table" and old.j then
            tinsert(old.j, piece)
        elseif dr.slot.t == "text" and type(old) == "string" and old ~= "" then
            p.a[dr.slot.slot] = { j = { old, " ", piece } }
        else
            p.a[dr.slot.slot] = piece
            if type(old) == "table" and old.k then AddScript(old, dr.x + 30, dr.y + 30) end
        end
        if dr.script then
            local list = S.inside and Scripts() or Def().scripts
            for i, s in ipairs(list) do if s == dr.script then tremove(list, i) break end end
        end
        Changed(dr.before)
        return
    end
    local t = dr.target
    if t then
        local stack = dr.script and dr.script.top or piece
        if dr.script then
            local list = S.inside and Scripts() or Def().scripts
            for i, s in ipairs(list) do if s == dr.script then tremove(list, i) break end end
        end
        if t.above then
            LastOf(stack).n = t.script.top
            t.script.top = stack
            t.script.y = t.script.y - (dr.frame and dr.frame.h or 40)
        else
            local rest = t.piece[t.field]
            if rest then LastOf(stack).n = rest end
            t.piece[t.field] = stack
        end
        Changed(dr.before)
        return
    end
    -- loose on the canvas: a script of its own (or the moved script's new place)
    if dr.script then
        dr.script.x, dr.script.y = floor(dr.x), floor(dr.y)
    else
        AddScript(piece, dr.x, dr.y)
    end
    Changed(dr.before)
end

---------------------------------------------------------------------------
-- The picker (a click on a blank): what fits there, the WC3 way
---------------------------------------------------------------------------

local DROPDOWN = { channel = true, stat = true, stage = true, marker = true, dur = true, var = true, badge = true,
    block = true, timer = true }

-- The values a blank in this script may take: { { piece | literal, label, desc, section } }.
local function ScopeOf(script)
    local scope = B():Scope(script.top, Scripts())
    B():Walk(script.top, function(p)
        local pd = B().PIECES[p.k]
        for _, g in ipairs(pd and pd.gives or {}) do scope[g] = true end
    end)
    return scope
end

local function Choices(script, piece, slot, t)
    local out = {}
    local d = Def()
    local function add(section, p, desc)
        local vt = B():ValueType(p)
        if t == "any" or t == "text" or B():Fits(t, vt) then out[#out + 1] = { piece = p, desc = desc, section = section } end
    end
    local scope = ScopeOf(script)
    for _, name in ipairs(B().CTX_ORDER) do
        if scope[name] then add("THIS SCRIPT", { k = "ctx", a = { name } }, CTX_DESC[name]) end
    end
    if t == "bool" then
        for _, k in ipairs({ "pl.online", "pl.ready", "pl.notready", "pl.is", "pl.in", "pl.below", "lo.set", "lo.gt", "lo.lt",
            "lo.eq", "lo.and", "lo.or", "lo.not", "bk.still", "wo.zone" }) do
            add("YES / NO", FillBlocks(B():New(k)))
        end
        return out
    end
    for _, k in ipairs({ "pl.host", "pl.all", "pl.rand", "pl.seed", "pl.count", "pl.top" }) do
        add("EVENT", B():New(k), (k == "pl.host" and "who runs it") or (k == "pl.all" and "everyone in it") or nil)
    end
    for _, v in ipairs(d.vars or {}) do add("VARIABLES", { k = "var", a = { v.n } }) end
    for _, k in ipairs({ "bk.champ", "bk.second", "bk.third", "bk.fin1", "bk.fin2", "bk.left", "bk.round", "su.list", "su.count" }) do
        local p = FillBlocks(B():New(k))
        if p.a[1] then add("SMART BLOCKS", p) end
    end
    if t == "num" or t == "any" or t == "text" then
        for _, k in ipairs({ "lo.add", "lo.sub", "lo.rand", "pt.get", "tm.left" }) do add("NUMBERS", B():New(k)) end
    end
    return out
end

local PICK_TITLE = { player = "Pick a player", players = "Pick players", num = "A number", text = "Text", any = "A value",
    bool = "A yes / no" }

function Builder:ClosePicker()
    if ui.picker then ui.picker:Hide() end
    if S.pick then
        S.pick = nil
        if win and win:IsShown() then self:RenderCanvas() end
    end
end

local function CreatePicker()
    local p = CreateFrame("Frame", "DisasterZoneEventPicker", win)
    p:SetFrameStrata("DIALOG")
    p:SetSize(252, 300)
    p:EnableMouse(true)
    p.bg = p:CreateTexture(nil, "BACKGROUND")
    p.bg:SetAllPoints()
    p.bg:SetColorTexture(0.047, 0.047, 0.059, 1)
    EUI():Edge(p, 0.47, 0.47, 0.51, 0.75)
    p.title = Text(p, "GameFontNormal", 12)
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -10)
    p.sub = Text(p, "GameFontHighlightSmall", 10)
    p.sub:SetTextColor(0.62, 0.62, 0.62)
    p.sub:SetPoint("TOPRIGHT", p, "TOPRIGHT", -12, -11)
    p.field = UI():CreateSleekEditBox(p, 228, 22)
    p.field:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -30)
    p.field:SetMaxLetters(MAX_TEXT)
    p.field:SetScript("OnEnterPressed", function(self) Builder:PickTyped(self:GetText()) end)
    p.field:SetScript("OnEscapePressed", function() Builder:ClosePicker() end)
    p.search = UI():CreateSearchBox(p, 228, function(text) Builder:FillPicker(text) end, "Search")
    p.search:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -30)
    p.rows = {}
    p.heads = {}
    p.foot = Text(p, "GameFontHighlightSmall", 10.5)
    p.foot:SetTextColor(0.55, 0.55, 0.58)
    p.foot:SetWordWrap(true)
    p.foot:SetWidth(228)
    p.clear = UI():CreateSleekButton(p, "Empty it", 70, 20, function() Builder:PickClear() end)
    p:Hide()
    ui.picker = p
    return p
end

OnBlank = function(piece, slot, blankFrame, button)
    if not CanEdit() then return end
    local pd = B().PIECES[piece.k]
    local a = pd and pd.args[slot] or { t = "any" }
    local loc = Locate(piece)
    if not loc then return end
    Builder:OpenPicker(loc.script, piece, slot, a, blankFrame)
end

function Builder:OpenPicker(script, piece, slot, a, blankFrame)
    local d = Def()
    local t = a.t
    if DROPDOWN[t] then
        UI():ContextMenu(blankFrame, function(root) self:DropdownChoices(root, piece, slot, a) end)
        return
    end
    local p = ui.picker or CreatePicker()
    S.pick = { script = script, piece = piece, slot = slot, a = a }
    p.title:SetText(PICK_TITLE[t] or "A value")
    p.sub:SetText("")
    local cur = piece.a[slot]
    local typed = t == "num" or t == "text" or t == "any"
    p.field:SetShown(typed)
    p.search:SetShown(not typed)
    if typed then
        local plain = (type(cur) == "string" or type(cur) == "number") and tostring(cur) or ""
        if type(cur) == "table" and cur.j then
            local parts = {}
            for _, x in ipairs(cur.j) do if type(x) == "string" then parts[#parts + 1] = x end end
            plain = table.concat(parts)
        end
        p.field:SetText(plain)
        UI():SetEditPlaceholder(p.field, t == "num" and "Type a number, Enter" or "Type, then Enter")
        p.field:SetFocus()
    else
        p.search:SetText("")
    end
    self:FillPicker("")
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", blankFrame, "BOTTOMLEFT", -6, -6)
    p:Show()
    p:Raise()
    -- (drawn again with the blank lit: the picker goes under the blank's new frame)
    self:RenderCanvas()
end

-- The drawn blank the picker is for (the canvas is drawn again while it is open: its frames are new ones, the old
-- ones back in the pool, maybe drawing another blank).
local function PickBlank()
    local pk = S.pick
    local f = pk and ui.scripts[pk.script]
    for _, bl in ipairs(f and f.blanks or {}) do
        if bl.piece == pk.piece and bl.slot == pk.slot then return bl.frame end
    end
    return nil
end

-- The picker under its blank (over it when there is no room below), inside the screen at the sides. (Screen
-- pixels: the blank sits in the zoomed canvas, the picker in the window; anchor offsets are in the picker's units.)
PlacePicker = function()
    local p, bf = ui.picker, PickBlank()
    if not (p and bf) then return end
    local ps, bs = p:GetEffectiveScale(), bf:GetEffectiveScale()
    local l, b, t = bf:GetLeft(), bf:GetBottom(), bf:GetTop()
    local up, dx = false, -6
    -- (a blank at 0, 0 isn't laid out yet: under it, as it comes)
    if l and b and t and (l ~= 0 or b ~= 0) then
        local us = UIParent:GetEffectiveScale()
        local sw, sh = (UIParent:GetWidth() or 0) * us, (UIParent:GetHeight() or 0) * us
        local ph, pw = (6 + p:GetHeight()) * ps, p:GetWidth() * ps
        up = b * bs - ph < 0 and t * bs + ph <= sh
        local over = l * bs + dx * ps + pw - sw
        if over > 0 then dx = dx - over / ps end
        if l * bs + dx * ps < 0 then dx = -l * bs / ps end
    end
    p:ClearAllPoints()
    if up then
        p:SetPoint("BOTTOMLEFT", bf, "TOPLEFT", dx, 6)
    else
        p:SetPoint("TOPLEFT", bf, "BOTTOMLEFT", dx, -6)
    end
end

function Builder:FillPicker(query)
    local p = ui.picker
    local pk = S.pick
    if not (p and pk) then return end
    for _, r in ipairs(p.rows) do
        if r.draw then EP():Release(r.draw) end
        r.draw = nil
        r:Hide()
    end
    for _, h in ipairs(p.heads) do h:Hide() end
    local t = pk.a.t
    local list = Choices(pk.script, pk.piece, pk.slot, t)
    query = string.lower(query or "")
    local y = (t == "num" or t == "text" or t == "any" or true) and 60 or 30
    local section, n, nh = nil, 0, 0
    for _, c in ipairs(list) do
        local label = c.piece.k == "ctx" and B().CTX[c.piece.a[1]].label or (c.piece.k == "var" and c.piece.a[1])
            or (B().PIECES[c.piece.k].text:gsub("{%d}", ""))
        if query == "" or string.lower(label):find(query, 1, true) then
            if n >= 9 then break end
            if c.section ~= section then
                section = c.section
                nh = nh + 1
                local h = p.heads[nh] or Text(p, "GameFontHighlightSmall", 10)
                p.heads[nh] = h
                h:SetTextColor(0.55, 0.55, 0.58)
                h:SetText(section)
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -(y + 4))
                h:Show()
                y = y + 18
            end
            n = n + 1
            local r = p.rows[n]
            if not r then
                r = CreateFrame("Button", nil, p)
                r:SetSize(240, 25)
                r.hl = r:CreateTexture(nil, "BACKGROUND")
                r.hl:SetAllPoints()
                r.hl:SetColorTexture(1, 0.82, 0, 0.12)
                r.hl:Hide()
                r.desc = Text(r, "GameFontHighlightSmall", 10.5)
                r.desc:SetTextColor(0.62, 0.62, 0.62)
                r.desc:SetJustifyH("RIGHT")
                r.desc:SetPoint("RIGHT", r, "RIGHT", -6, 0)
                r:SetScript("OnEnter", function(self) self.hl:Show() end)
                r:SetScript("OnLeave", function(self) self.hl:Hide() end)
                p.rows[n] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -y)
            r:Show()
            r.draw = EP():Draw(r, c.piece, { def = Def(), static = true })
            r.draw:SetPoint("LEFT", r, "LEFT", 6, 0)
            r.draw:SetScale(0.92)
            r.desc:SetText(c.desc or "")
            r.choice = c.piece
            r:SetScript("OnClick", function(self) Builder:PickPiece(self.choice) end)
            y = y + 26
        end
    end
    y = y + 6
    p.foot:ClearAllPoints()
    p.foot:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -y)
    local hint = (t == "player" or t == "players") and "Or drag any round player piece into the blank."
        or (t == "bool" and "Or drag a hexagon piece into the blank.") or "Or drag a round piece into the blank."
    p.foot:SetText(hint)
    y = y + 18
    if pk.piece.a[pk.slot] ~= nil then
        p.clear:ClearAllPoints()
        p.clear:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -(y + 2))
        p.clear:Show()
        y = y + 26
    else
        p.clear:Hide()
    end
    p:SetHeight(y + 10)
end

function Builder:PickPiece(choice)
    local pk = S.pick
    if not pk then return end
    local before = Snapshot()
    local p = Copy(choice)
    local cur = pk.piece.a[pk.slot]
    if pk.a.t == "text" then
        -- a value goes into the text after what is typed
        if type(cur) == "table" and cur.j then tinsert(cur.j, p)
        elseif type(cur) == "string" and cur ~= "" then pk.piece.a[pk.slot] = { j = { cur, " ", p } }
        else pk.piece.a[pk.slot] = p end
    else
        pk.piece.a[pk.slot] = p
    end
    ui.picker:Hide()
    S.pick = nil
    Changed(before)
end

function Builder:PickTyped(text)
    local pk = S.pick
    if not pk then return end
    local before = Snapshot()
    text = text or ""
    if pk.a.t == "num" then
        local n = tonumber(text)
        if not n or n ~= n then
            ui.picker.sub:SetText("|cffff8a7aa number, like 3|r")
            return
        end
        -- (the library keeps numbers under a billion: a bigger one, or "1e999", would empty the blank when saved)
        if n <= -1e9 or n >= 1e9 then
            ui.picker.sub:SetText("|cffff8a7aa smaller number|r")
            return
        end
        pk.piece.a[pk.slot] = n
    else
        text = Clean(text, MAX_TEXT)
        local cur = pk.piece.a[pk.slot]
        if type(cur) == "table" and cur.j then
            -- keep the values, replace the typed words: the words first, then the values in their order
            local vals = {}
            for _, x in ipairs(cur.j) do if type(x) == "table" then vals[#vals + 1] = x end end
            local j = { text }
            for _, v in ipairs(vals) do j[#j + 1] = " "; j[#j + 1] = v end
            pk.piece.a[pk.slot] = #vals > 0 and { j = j } or text
        else
            pk.piece.a[pk.slot] = text
        end
    end
    ui.picker:Hide()
    S.pick = nil
    Changed(before)
end

function Builder:PickClear()
    local pk = S.pick
    if not pk then return end
    local before = Snapshot()
    pk.piece.a[pk.slot] = nil
    ui.picker:Hide()
    S.pick = nil
    Changed(before)
end

-- A dropdown blank's choices.
function Builder:DropdownChoices(root, piece, slot, a)
    local d = Def()
    local function set(v)
        local before = Snapshot()
        piece.a[slot] = v
        Changed(before)
    end
    local function radio(label, v)
        root:CreateRadio(label, function() return piece.a[slot] == v end, function() set(v) end)
    end
    local t = a.t
    if t == "channel" then
        for _, c in ipairs(B().CHANNELS) do radio(c[2], c[1]) end
    elseif t == "marker" then
        for _, c in ipairs(B().MARKERS) do
            radio(("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:14|t %s"):format(c[1], c[2]), c[1])
        end
    elseif t == "dur" then
        for _, sec in ipairs(B().DURATIONS) do radio(B():DurationText(sec), sec) end
    elseif t == "stat" then
        for _, s in ipairs(B().STATS) do radio(s, s) end
    elseif t == "stage" then
        for _, s in ipairs(d.stages) do radio(s.name, s.id) end
    elseif t == "block" then
        for _, bid in ipairs(B():BlocksOf(d, a.kind)) do radio(B():BlockLabel(d, bid), bid) end
    elseif t == "badge" then
        for _, e in ipairs(B():BadgeList(d)) do
            radio(("|T%s:14|t %s"):format(e.b.i or "Interface\\Icons\\INV_Misc_QuestionMark", e.b.n), e.id)
        end
        root:CreateDivider()
        root:CreateButton(UI():AtlasIconText(UI().ICON.plus or 39, 12) .. " New badge", function() Builder:NewBadge(piece, slot) end)
    elseif t == "var" then
        for _, v in ipairs(d.vars or {}) do radio(v.n, v.n) end
        root:CreateDivider()
        root:CreateButton(UI():AtlasIconText(UI().ICON.plus or 39, 12) .. " Make a variable", function()
            Builder:NewVariable(piece, slot)
        end)
    elseif t == "timer" then
        for _, n in ipairs(B():Timers(d)) do radio(n, n) end
        root:CreateDivider()
        root:CreateButton(UI():AtlasIconText(UI().ICON.plus or 39, 12) .. " A new name", function()
            Builder:AskName("Timer name", "", function(name) set(name) end)
        end)
    end
end

---------------------------------------------------------------------------
-- A name (a stage, a variable, a timer): a small field over the window
---------------------------------------------------------------------------

-- onDone(name) gets the name cleaned (maxLen: default 24); check(name) -> why it can't be (shown), or nil.
function Builder:AskName(title, current, onDone, maxLen, check)
    local f = ui.ask
    if not f then
        f = CreateFrame("Frame", "DisasterZoneEventAskName", win)
        f:SetFrameStrata("DIALOG")
        f:SetSize(280, 92)
        f:EnableMouse(true)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetColorTexture(0.075, 0.075, 0.09, 0.985)
        EUI():Edge(f, 0.47, 0.47, 0.51, 0.75)
        f.title = Text(f, "GameFontNormal", 13)
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
        f.field = UI():CreateSleekEditBox(f, 256, 24)
        f.field:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -32)
        f.ok = UI():CreateSleekButton(f, "Done", 70, 22, function() f:Done() end, "primary")
        f.ok:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
        f.cancel = UI():CreateSleekButton(f, "Cancel", 70, 22, function() f:Hide() end)
        f.cancel:SetPoint("RIGHT", f.ok, "LEFT", -6, 0)
        f.err = Text(f, "GameFontHighlightSmall", 10.5)
        f.err:SetTextColor(1, 0.54, 0.48)
        f.err:SetPoint("LEFT", f, "BOTTOMLEFT", 12, 21)
        f.field:SetScript("OnEnterPressed", function() f:Done() end)
        f.field:SetScript("OnEscapePressed", function() f:Hide() end)
        f.field:SetScript("OnTextChanged", function() f.err:SetText("") end)
        function f:Done()
            local t = Clean(self.field:GetText(), self.maxLen)
            if t == "" then
                self.err:SetText("Type a name first")
                return
            end
            local why = self.check and self.check(t)
            if why then
                self.err:SetText(why)
                return
            end
            self:Hide()
            if self.onDone then self.onDone(t) end
        end
        ui.ask = f
    end
    f.title:SetText(title)
    f.field:SetText(current or "")
    f.err:SetText("")
    f.onDone, f.maxLen, f.check = onDone, maxLen or MAX_NAME, check
    f:ClearAllPoints()
    f:SetPoint("CENTER", win, "CENTER", 0, 80)
    f:Show()
    f:Raise()
    f.field:SetFocus()
    f.field:HighlightText()
end

---------------------------------------------------------------------------
-- Stages
---------------------------------------------------------------------------

function Builder:SelectStage(id)
    self:ClosePicker()
    S.inside = nil
    S.stage = id
    Refresh()
end

-- Two stages with one name can't be told apart (the strip, "go to stage", the host's menu): why not, or nil.
local function StageNameTaken(d, name, except)
    for _, s in ipairs(d.stages) do
        if s.id ~= except and string.lower(s.name or "") == string.lower(name) then return "Name already used" end
    end
    return nil
end

function Builder:AddStage()
    local d = Def()
    if #d.stages >= 8 then
        ns:Print("an event has 8 stages at most.")
        return
    end
    self:AskName("New stage", "Stage " .. (#d.stages + 1), function(name)
        local before = Snapshot()
        local id
        repeat
            S.idn = (S.idn or 0) + 1
            id = "s" .. (#d.stages + S.idn)
        until not B():Stage(d, id)
        tinsert(d.stages, { id = id, name = name })
        S.stage = id
        Changed(before)
    end, MAX_NAME, function(name) return StageNameTaken(d, name) end)
end

function Builder:RenameStage(owner, id)
    if not CanEdit() then return end
    local s = B():Stage(Def(), id)
    if not s then return end
    local d = Def()
    self:AskName("Rename the stage", s.name, function(name)
        local before = Snapshot()
        s.name = name
        Changed(before)
    end, MAX_NAME, function(name) return StageNameTaken(d, name, id) end)
end

function Builder:StageMenu(owner, id)
    if not CanEdit() then return end
    local d = Def()
    local s, i = B():Stage(d, id)
    if not s then return end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(s.name)
        root:CreateButton(UI():AtlasIconText(16, 12) .. " Rename", function() Builder:RenameStage(owner, id) end)
        if i > 1 then
            root:CreateButton(UI():AtlasIconText(9, 12) .. " Earlier", function()
                local before = Snapshot()
                d.stages[i], d.stages[i - 1] = d.stages[i - 1], d.stages[i]
                Changed(before)
            end)
        end
        if i < #d.stages then
            root:CreateButton(UI():AtlasIconText(10, 12) .. " Later", function()
                local before = Snapshot()
                d.stages[i], d.stages[i + 1] = d.stages[i + 1], d.stages[i]
                Changed(before)
            end)
        end
        if #d.stages > 1 then
            root:CreateDivider()
            local del = root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete|r", function()
                local before = Snapshot()
                tremove(d.stages, i)
                -- its scripts and blocks go with it
                for k = #d.scripts, 1, -1 do
                    if d.scripts[k].st == id then tremove(d.scripts, k) end
                end
                for bid, b in pairs(d.blocks) do
                    if b.stage == id then
                        d.blocks[bid] = nil
                        DropBlockNotes(d, bid)
                    end
                end
                for k = #(d.notes or {}), 1, -1 do
                    if d.notes[k].st == id then tremove(d.notes, k) end
                end
                -- the stage before it comes up when it was the open one (another open stage stays)
                if S.stage == id then S.stage = d.stages[max(1, i - 1)].id end
                Changed(before)
            end)
            if del.SetTooltip then
                del:SetTooltip(function(tt) tt:AddLine("Deletes the stage, its pieces and its smart blocks.", 1, 1, 1, true) end)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Pieces, blocks and the canvas: right-click menus
---------------------------------------------------------------------------

function Builder:PieceMenu(owner, piece)
    if not CanEdit() then return end
    local loc = Locate(piece)
    if not loc then return end
    UI():ContextMenu(owner, function(root)
        root:CreateButton(UI():AtlasIconText(17, 12) .. " Duplicate", function()
            local before = Snapshot()
            local copy = Copy(piece)
            if IsValue(piece) then copy.n = nil end
            AddScript(copy, loc.script.x + 24, loc.script.y + 24)
            Changed(before)
        end)
        root:CreateButton(UI():AtlasIconText(25, 12) .. " Add a note", function()
            Builder:AddNote(loc.script.x + 260, loc.script.y)
        end)
        root:CreateDivider()
        root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete|r", function()
            local before = Snapshot()
            -- the piece goes; what was under it stays where it was
            local rest = (not IsValue(piece)) and piece.n or nil
            Cut(loc, piece)
            if rest then
                if loc.field == "top" then
                    AddScript(rest, loc.script.x, loc.script.y)
                elseif type(loc.field) == "string" and loc.field ~= "j" then
                    loc.parent[loc.field] = rest
                end
            end
            Changed(before)
        end)
    end)
end

function Builder:BlockMenu(owner, bid)
    if not CanEdit() then return end
    local d = Def()
    local b = d.blocks[bid]
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(B():BlockLabel(d, bid))
        local move = root:CreateButton("Move to a stage")
        for _, s in ipairs(d.stages) do
            move:CreateRadio(s.name, function() return b.stage == s.id end, function()
                local before = Snapshot()
                b.stage = s.id
                Changed(before)
            end)
        end
        root:CreateDivider()
        root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete|r", function()
            local before = Snapshot()
            d.blocks[bid] = nil
            DropBlockNotes(d, bid)
            Changed(before)
        end)
    end)
end

function Builder:CanvasMenu(owner)
    local cx, cy = CursorInContent()
    UI():ContextMenu(owner, function(root)
        if CanEdit() then
            root:CreateButton(UI():AtlasIconText(UI().ICON.bracket or 54, 12) .. " Clean up", function() Builder:CleanUp() end)
            root:CreateButton(UI():AtlasIconText(25, 12) .. " Add a note", function() Builder:AddNote(cx, cy) end)
        end
        root:CreateButton(UI():AtlasIconText(35, 12) .. " Zoom to fit", function() Builder:ZoomToFit() end)
    end)
end

function Builder:AddNote(x, y)
    if not CanEdit() then return end
    local before = Snapshot()
    local d = Def()
    d.notes = d.notes or {}
    tinsert(d.notes, { st = NoteSpot(), x = floor(x), y = floor(y), text = "" })
    Changed(before)
    -- the new note's frame (frames are reused: not always the last one made)
    for _, f in ipairs(ui.notes) do
        if f:IsShown() and f.index == #d.notes then f.eb:SetFocus() end
    end
end

-- Lines the scripts up in columns, in reading order (the cards keep their place).
function Builder:CleanUp()
    local before = Snapshot()
    local list = {}
    for _, s in ipairs(Scripts()) do list[#list + 1] = s end
    tsort(list, function(a, b)
        if abs(a.x - b.x) > 60 then return a.x < b.x end
        return a.y < b.y
    end)
    local x0 = 20
    if not S.inside then
        for _, bid in ipairs(B():BlocksOf(Def())) do
            local b = Def().blocks[bid]
            if b.stage == S.stage then x0 = max(x0, b.x + 340) end
        end
    end
    local col, x, y, colW = 0, x0, 20, 0
    for _, s in ipairs(list) do
        local f = ui.scripts[s]
        local h, w = f and f.h or 60, f and f.w or 300
        if y + h > 560 and y > 20 then
            x = x + colW + 30
            y, colW = 20, 0
        end
        s.x, s.y = x, y
        y = y + h + 30
        colW = max(colW, w)
    end
    Changed(before)
end

function Builder:ZoomToFit()
    local minX, minY, maxX, maxY
    local function take(x, y, w, h)
        minX, minY = min(minX or x, x), min(minY or y, y)
        maxX, maxY = max(maxX or (x + w), x + w), max(maxY or (y + h), y + h)
    end
    for s, f in pairs(ui.scripts) do take(s.x, s.y, f.w or 100, f.h or 40) end
    for bid, c in pairs(ui.cards) do
        if c:IsShown() then local b = Def().blocks[bid]; take(b.x, b.y, 318, c:GetHeight() or 240) end
    end
    if not minX then
        MoveView(0, 0, 1)
        return
    end
    -- everything in the free part of the canvas (under the ribbon inside a block, over the zoom bar), centred, at
    -- 100% at most
    local cw, ch = CanvasSize()
    local top, bottom, side = S.inside and 66 or 16, 46, 16
    local aw, ah = cw - 2 * side, ch - top - bottom
    local bw, bh = max(1, maxX - minX), max(1, maxY - minY)
    local z = max(Z_MIN, min(1, aw / bw, ah / bh))
    MoveView(side + (aw - bw * z) / 2 - minX * z, top + (ah - bh * z) / 2 - minY * z, z)
end

---------------------------------------------------------------------------
-- Smart blocks: adding one, stepping inside
---------------------------------------------------------------------------

function Builder:AddBlock(kind)
    local d = Def()
    local n = 0
    for _ in pairs(d.blocks) do n = n + 1 end
    if n >= 8 then
        ns:Print("an event has 8 smart blocks at most.")
        return
    end
    local before = Snapshot()
    local id
    repeat
        S.idn = (S.idn or 0) + 1
        id = "b" .. (n + S.idn)
    until not d.blocks[id]
    local stage = S.stage == "*" and d.stages[1].id or S.stage
    local v = View()
    d.blocks[id] = { kind = kind, stage = stage, x = floor(-v.x / v.z + 30), y = floor(-v.y / v.z + 30), set = B():SmartDefaults(kind) }
    S.stage = stage
    Changed(before)
end

function Builder:OpenInside(bid)
    local b = Def().blocks[bid]
    if not b or b.kind ~= "bracket" then return end
    self:ClosePicker()
    S.inside = bid
    S.cat = "sm"
    Refresh()
end

function Builder:CloseInside()
    S.inside = nil
    Refresh()
end

-- Make my own copy (the built-in scripts become the block's own, to change) / back to the built-in ones.
function Builder:CopyInner()
    if S.readOnly then
        ns:Print("this is %s's event: make a copy of the event first.", EUI():Plain(Def().by))
        return
    end
    local b = Def().blocks[S.inside]
    if not b then return end
    local before = Snapshot()
    if b.inner then
        b.inner = nil
    else
        b.inner = Copy(B():BracketInner())
    end
    Changed(before)
end

function Builder:UseStarter()
    local before = Snapshot()
    local st = B():Starter()
    local d = Def()
    for _, k in ipairs({ "stages", "scripts", "blocks", "vars", "badges", "notes" }) do d[k] = st[k] end
    if d.name == "New event" then d.name = st.name end
    d.icon, d.art = st.icon, st.art
    S.stage = d.stages[1].id
    Changed(before)
end

---------------------------------------------------------------------------
-- Variables, badges, icon, art
---------------------------------------------------------------------------

function Builder:NewVariable(piece, slot)
    if not CanEdit() then return end
    self:AskName("New variable", "", function(name)
        local d = Def()
        if B():Var(d, name) then
            if piece then local before = Snapshot(); piece.a[slot] = name; Changed(before) end
            return
        end
        local before = Snapshot()
        d.vars = d.vars or {}
        tinsert(d.vars, { n = name:sub(1, 24), t = "player" })
        if piece then piece.a[slot] = name:sub(1, 24) end
        S.cat = "pt"
        Changed(before)
    end)
end

function Builder:NewBadge(piece, slot, badgeId)
    local d = Def()
    local function save(id, bd)
        local before = Snapshot()
        id = id or ("bd" .. (#B():BadgeList(d) + 1))
        while not badgeId and d.badges[id] do id = id .. "x" end
        d.badges[id] = bd
        if piece then piece.a[slot] = id end
        Changed(before)
    end
    local UIx = ns.EventsUI
    if UIx and UIx.OpenBadgeDesigner then
        UIx:OpenBadgeDesigner(d, badgeId, save)
    else
        self:AskName("Badge name", "", function(name)
            save(nil, { n = name, i = "Interface\\Icons\\INV_Misc_Ribbon_01", f = "gold" })
        end, 32)
    end
end

local ICONS = {
    "Interface\\Icons\\Ability_DualWield", "Interface\\Icons\\Ability_Warrior_Challange", "Interface\\Icons\\INV_Sword_39",
    "Interface\\Icons\\Achievement_Arena_2v2_7", "Interface\\Icons\\INV_BannerPVP_02", "Interface\\Icons\\Ability_Mount_RidingHorse",
    "Interface\\Icons\\Ability_Mount_WhiteTiger", "Interface\\Icons\\Trade_Fishing", "Interface\\Icons\\INV_Misc_Bandana_03",
    "Interface\\Icons\\Ability_Stealth", "Interface\\Icons\\INV_Misc_Map_01", "Interface\\Icons\\INV_Misc_Spyglass_02",
    "Interface\\Icons\\INV_Misc_Gift_01", "Interface\\Icons\\INV_Misc_Ticket_Darkmoon_01", "Interface\\Icons\\Spell_Holy_Heroism",
    "Interface\\Icons\\INV_Misc_Head_Dragon_01", "Interface\\Icons\\INV_Crown_02", "Interface\\Icons\\INV_Misc_Horn_01",
}

function Builder:IconMenu(owner)
    if not CanEdit() then return end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Event icon")
        for _, path in ipairs(ICONS) do
            local name = path:match("([^\\]+)$"):gsub("_", " ")
            root:CreateRadio(("|T%s:16|t %s"):format(path, name), function() return Def().icon == path end, function()
                local before = Snapshot()
                Def().icon = path
                Changed(before)
            end)
        end
    end)
end

function Builder:MoreMenu(owner)
    local d = Def()
    UI():ContextMenu(owner, function(root)
        if CanEdit() then
            local art = root:CreateButton(UI():AtlasIconText(31, 12) .. " Art")
            for _, a in ipairs(B().ART) do
                art:CreateRadio(a[2], function() return d.art == a[1] end, function()
                    local before = Snapshot()
                    d.art = a[1]
                    Changed(before)
                end)
            end
            local badges = root:CreateButton(UI():AtlasIconText(UI().ICON.trophy or 51, 12) .. " Badges")
            for _, e in ipairs(B():BadgeList(d)) do
                badges:CreateButton(("|T%s:14|t %s"):format(e.b.i or "Interface\\Icons\\INV_Misc_QuestionMark", e.b.n), function()
                    Builder:NewBadge(nil, nil, e.id)
                end)
            end
            badges:CreateButton(UI():AtlasIconText(UI().ICON.plus or 39, 12) .. " New badge", function() Builder:NewBadge() end)
            local vars = root:CreateButton(UI():AtlasIconText(8, 12) .. " Variables")
            for i, v in ipairs(d.vars or {}) do
                vars:CreateButton(v.n .. "  |cff8d8d93(delete)|r", function()
                    local before = Snapshot()
                    tremove(d.vars, i)
                    Changed(before)
                end)
            end
            vars:CreateButton(UI():AtlasIconText(UI().ICON.plus or 39, 12) .. " Make a variable", function() Builder:NewVariable() end)
            root:CreateDivider()
            local review = root:CreateButton(UI():AtlasIconText(UI().ICON.rank or 26, 12) .. " Send for review", function()
                Builder:SendForReview()
            end)
            if review.SetTooltip then
                review:SetTooltip(function(tt)
                    tt:AddLine("Send for review", 1, 0.82, 0)
                    tt:AddLine("The GM, officers or the guild council can mark it ranked: then its badges and season points count.",
                        1, 1, 1, true)
                end)
            end
        end
        root:CreateButton(UI():AtlasIconText(17, 12) .. " Copy", function() Builder:MakeCopy() end)
        if Ev():GetDef(d.id) and (Ev():IsMine(d) or Ev():CanModerate(Me())) then
            root:CreateDivider()
            root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete|r", function()
                Builder:Delete()
            end)
        end
    end)
end

---------------------------------------------------------------------------
-- Save, host, share, copy, delete, review
---------------------------------------------------------------------------

function Builder:Save(quiet)
    local d = Def()
    if not d or S.readOnly then return false end
    -- deleted from the library while it was open (by an officer, or on my other client): the library keeps a
    -- deleted event deleted, so the work is kept as a new event
    if S.inLibrary and not Ev():GetDef(d.id) then
        d.id, d.rev = nil, nil
    end
    if Ev():SaveDef(d) then
        local saved = Ev():GetDef(d.id)
        if saved then S.def.rev = saved.rev end
        S.inLibrary, S.gone = true, nil
        NoteSaved(d)
        S.dirty = false
        if S.practicedHash and S.practicedHash == S.savedHash then Builder:NotePracticed(d) end
        if not quiet then Refresh() end
        return true
    end
    return false
end

function Builder:Primary()
    if S.readOnly then return self:MakeCopy() end
    local d = Def()
    if S.dirty or not Ev():GetDef(d.id) then
        self:Save()
        return
    end
    self:Host()
end

function Builder:Host()
    local d = Def()
    local probs = B():Problems(d)
    if #probs > 0 then
        ns:Print("%s", "fix the pieces that need it first (the orange pill at the bottom takes you there).")
        self:JumpToProblem()
        return
    end
    if S.dirty then self:Save(true) end
    local UIx = ns.EventsUI
    if UIx and UIx.OpenSchedule then
        UIx:OpenSchedule(d.id)
    else
        local occ = Ev():Schedule(d.id, Now() + 3600)
        if occ then ns:Print("%s is on the calendar in an hour.", d.name) end
    end
end

function Builder:SendForReview()
    local d = Def()
    if S.dirty then self:Save(true) end
    if not Ev():GetDef(d.id) then return end
    local UIx = ns.EventsUI
    if UIx and UIx.OpenSubmit then
        UIx:OpenSubmit(d.id)
    else
        Ev():SubmitForReview(d.id, "")
    end
end

function Builder:MakeCopy()
    local copy = Ev():CopyDef(Def())
    if not copy then return end
    if Ev():SaveDef(copy) then self:Open(Ev():GetDef(copy.id) or copy) end
end

function Builder:Delete()
    local d = Def()
    if Ev():DeleteDef(d.id) then
        S.dirty = false
        S.def = nil
        win:Hide()
    end
end

-- The share window with a link to the event (the saved one: what the guild has).
function Builder:ShareEvent(owner)
    local d = Def()
    if not Ev():GetDef(d.id) then
        ns:Print("%s", "save the event first: the link opens the one the guild has.")
        return
    end
    local ref = ns.Share:EventDefRef(d.id)
    if IsShiftKeyDown() then
        ns.Share:PutInChat(ref)
    elseif ns.ShareWindow then
        ns.ShareWindow:Open(ref, owner)
    end
end

---------------------------------------------------------------------------
-- Practice: the event with dummies
---------------------------------------------------------------------------

local function Practicing() return S.practice and L():GetPractice() end

function Builder:WasPracticed(defId, rev)
    local db = ns.db
    local p = db and db.eventPracticed and db.eventPracticed[defId]
    if not p then return false end
    local d = Ev():GetDef(defId)
    if not d then return false end
    return p.h == ContentHash(d), p.at
end

function Builder:NotePracticed(d)
    local db = ns.db
    if not db or not d.id then return end
    db.eventPracticed = db.eventPracticed or {}
    db.eventPracticed[d.id] = { h = ContentHash(d), at = Now() }
end

function Builder:StartPractice(again)
    self:ClosePicker()
    local d = Def()
    if #B():Problems(d) > 0 then
        ns:Print("%s", "fix the pieces that need it first: a practice runs the event as it is.")
        self:JumpToProblem()
        return
    end
    S.practice = true
    S.inside = nil
    S.glow = {}
    S.log = {}
    S.practicedHash = nil
    L():StartPractice(Copy(d), 16)
    local st = L():GetState("practice")
    if st and st.stage then S.stage = st.stage end
    Refresh()
end

function Builder:StopPractice()
    if not S.practice then return end
    S.practice = false
    L():StopPractice()
    if ns.EventBoard and ns.EventBoard.GetOcc and ns.EventBoard:GetOcc() == "practice" then ns.EventBoard:Close() end
    if win and win:IsShown() then
        Refresh()
        self:OnLibraryChanged()     -- (what came in while practising)
    end
end

-- A script just ran: it glows a moment (Scratch's yellow edge).
function Builder:GlowScript(f, at)
    local g = f.glowFrame
    if not g then
        g = CreateFrame("Frame", nil, f)
        g:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
        g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
        g.edges = {}
        UI():AddEdges(g, "OVERLAY")
        g.soft = CreateFrame("Frame", nil, g)
        g.soft:SetPoint("TOPLEFT", g, "TOPLEFT", -3, 3)
        g.soft:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 3, -3)
        UI():AddEdges(g.soft, "OVERLAY")
        f.glowFrame = g
    end
    g:SetFrameLevel(f:GetFrameLevel() + 450)
    g.at = at
    g:Show()
    g:SetScript("OnUpdate", function(self)
        local a = 1 - (GetTime() - self.at) / 1.6
        if a <= 0 then
            self:Hide()
            self:SetScript("OnUpdate", nil)
            return
        end
        UI():SetEdgeColor(self, 1, 0.92, 0.6, a)
        UI():SetEdgeColor(self.soft, 1, 0.82, 0, a * 0.35)
    end)
end

local LOG_CAT = { say = "ch", whisper = "ch", warning = "ch", moment = "ch", points = "pt", badge = "pt", var = "pt",
    stage = "sg", block = "ev", script = "ev", ask = "pl", countdown = "tm", invite = "wo", mark = "wo" }

CreatePractice = function(body)
    -- the dummies panel (in the palette's place)
    local dp = CreateFrame("Frame", nil, body)
    dp:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    dp:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    dp:SetWidth(PAL_W)
    dp.bg = dp:CreateTexture(nil, "BACKGROUND")
    dp.bg:SetAllPoints()
    dp.bg:SetColorTexture(0.05, 0.05, 0.063, 0.98)
    local line = Divider(dp, true)
    line:SetPoint("TOPRIGHT")
    line:SetPoint("BOTTOMRIGHT")
    dp:Hide()
    ui.dp = dp
    local function head(text, y, right)
        local h = Text(dp, "GameFontNormal", 12)
        h:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
        h:SetText(text)
        local r = Text(dp, "GameFontHighlightSmall", 10.5)
        r:SetTextColor(0.62, 0.62, 0.62)
        r:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 1))
        r:SetText(right or "")
        local ln = dp:CreateTexture(nil, "BORDER")
        ln:SetColorTexture(1, 1, 1, 0.08)
        ln:SetHeight(1)
        ln:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -(y + 18))
        ln:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 18))
        return h, r
    end
    dp.h1, dp.h1r = head("Playing now", 8)
    dp.matches = {}
    for i = 1, 4 do
        local m = CreateFrame("Frame", nil, dp)
        m:SetSize(PAL_W - 20, 54)
        m.bg = m:CreateTexture(nil, "BACKGROUND")
        m.bg:SetAllPoints()
        m.bg:SetColorTexture(1, 1, 1, 0.03)
        UI():AddEdges(m)
        m.c1 = m:CreateTexture(nil, "ARTWORK")
        m.c1:SetSize(16, 16)
        m.c1:SetPoint("TOPLEFT", m, "TOPLEFT", 8, -7)
        m.n1 = Text(m, "GameFontHighlight", 11.5)
        m.n1:SetPoint("LEFT", m.c1, "RIGHT", 5, 0)
        m.vs = Text(m, "GameFontHighlightSmall", 10.5)
        m.vs:SetText("vs")
        m.vs:SetTextColor(0.62, 0.62, 0.62)
        m.vs:SetPoint("LEFT", m.n1, "RIGHT", 6, 0)
        m.c2 = m:CreateTexture(nil, "ARTWORK")
        m.c2:SetSize(16, 16)
        m.c2:SetPoint("LEFT", m.vs, "RIGHT", 6, 0)
        m.n2 = Text(m, "GameFontHighlight", 11.5)
        m.n2:SetPoint("LEFT", m.c2, "RIGHT", 5, 0)
        m.sc = Text(m, "GameFontHighlightSmall", 10.5)
        m.sc:SetTextColor(0.62, 0.62, 0.62)
        m.sc:SetPoint("TOPRIGHT", m, "TOPRIGHT", -8, -9)
        m.b1 = UI():CreateSleekButton(m, "", 116, 20, function(self) local mm = self:GetParent(); L():PracticeDuel(mm.a, mm.b) end)
        m.b1:SetPoint("BOTTOMLEFT", m, "BOTTOMLEFT", 6, 6)
        m.b2 = UI():CreateSleekButton(m, "", 116, 20, function(self) local mm = self:GetParent(); L():PracticeDuel(mm.b, mm.a) end)
        m.b2:SetPoint("BOTTOMRIGHT", m, "BOTTOMRIGHT", -6, 6)
        m:Hide()
        dp.matches[i] = m
    end
    dp.none = Text(dp, "GameFontHighlightSmall", 11)
    dp.none:SetTextColor(0.62, 0.62, 0.62)
    dp.none:SetWordWrap(true)
    dp.none:SetWidth(PAL_W - 20)
    dp.h2 = Text(dp, "GameFontNormal", 12)
    dp.h2:SetText("Make something happen")
    dp.h2ln = dp:CreateTexture(nil, "BORDER")
    dp.h2ln:SetColorTexture(1, 1, 1, 0.08)
    dp.h2ln:SetHeight(1)
    S.happen = S.happen or { kind = "duel" }
    dp.kind = UI():CreateSleekMenuButton(dp, "a duel ends", 108, function(root)
        for _, k in ipairs({ { "duel", "a duel ends" }, { "off", "goes offline" }, { "on", "comes back" }, { "ready", "is ready" } }) do
            root:CreateRadio(k[2], function() return S.happen.kind == k[1] end, function()
                S.happen.kind = k[1]
                Builder:RenderPractice()
            end)
        end
    end, 21)
    local function who(field, width)
        return UI():CreateSleekMenuButton(dp, "", width, function(root)
            local st = L():GetState("practice")
            for _, k in ipairs(st and st.entrants or {}) do
                root:CreateRadio(L().DisplayName(k), function() return S.happen[field] == k end, function()
                    S.happen[field] = k
                    Builder:RenderPractice()
                end)
            end
        end, 21)
    end
    dp.w = who("w", 84)
    dp.l = who("l", 84)
    dp.wlab = Text(dp, "GameFontHighlightSmall", 11)
    dp.wlab:SetText("winner")
    dp.wlab:SetTextColor(0.82, 0.82, 0.82)
    dp.llab = Text(dp, "GameFontHighlightSmall", 11)
    dp.llab:SetText("loser")
    dp.llab:SetTextColor(0.82, 0.82, 0.82)
    dp.doit = UI():CreateSleekButton(dp, "Do it", 54, 21, function() Builder:Happen() end)
    dp.h3 = Text(dp, "GameFontNormal", 12)
    dp.h3:SetText("Dummies")
    dp.h3r = Text(dp, "GameFontHighlightSmall", 10.5)
    dp.h3r:SetTextColor(0.62, 0.62, 0.62)
    dp.h3r:SetText("click to take one offline")
    dp.h3ln = dp:CreateTexture(nil, "BORDER")
    dp.h3ln:SetColorTexture(1, 1, 1, 0.08)
    dp.h3ln:SetHeight(1)
    dp.dummies = {}
    -- the log (over the canvas' bottom)
    local lg = CreateFrame("Frame", nil, body)
    lg:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", PAL_W, 0)
    lg:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    lg:SetHeight(LOG_H)
    lg:SetFrameLevel(body:GetFrameLevel() + 950)
    lg.bg = lg:CreateTexture(nil, "BACKGROUND")
    lg.bg:SetAllPoints()
    lg.bg:SetColorTexture(0.039, 0.039, 0.051, 0.97)
    local top = Divider(lg)
    top:SetPoint("TOPLEFT")
    top:SetPoint("TOPRIGHT")
    lg.h = Text(lg, "GameFontNormal", 11.5)
    lg.h:SetText("Practice log")
    lg.h:SetPoint("TOPLEFT", lg, "TOPLEFT", 12, -7)
    lg.r = Text(lg, "GameFontHighlightSmall", 10.5)
    lg.r:SetTextColor(0.62, 0.62, 0.62)
    lg.r:SetPoint("TOPRIGHT", lg, "TOPRIGHT", -12, -8)
    lg.lines = {}
    for i = 1, 5 do
        local l = CreateFrame("Frame", nil, lg)
        l:SetHeight(18)
        l:SetPoint("TOPLEFT", lg, "TOPLEFT", 0, -26 - (i - 1) * 18)
        l:SetPoint("TOPRIGHT", lg, "TOPRIGHT", 0, -26 - (i - 1) * 18)
        l.bg = l:CreateTexture(nil, "BACKGROUND")
        l.bg:SetAllPoints()
        l.bg:SetColorTexture(1, 0.82, 0, 0.07)
        l.tm = Text(l, "GameFontHighlightSmall", 11)
        l.tm:SetTextColor(0.44, 0.44, 0.46)
        l.tm:SetPoint("LEFT", l, "LEFT", 12, 0)
        l.dot = l:CreateTexture(nil, "ARTWORK")
        l.dot:SetTexture(EUI().MASK)
        l.dot:SetSize(7, 7)
        l.dot:SetPoint("LEFT", l, "LEFT", 74, 0)
        l.fs = Text(l, "GameFontHighlightSmall", 11)
        l.fs:SetPoint("LEFT", l.dot, "RIGHT", 9, 0)
        l.fs:SetTextColor(0.82, 0.82, 0.82)
        lg.lines[i] = l
    end
    lg:Hide()
    ui.log = lg
end

function Builder:Happen()
    S.happen = S.happen or { kind = "duel" }
    local h = S.happen
    if h.kind == "duel" then
        if not (h.w and h.l) or h.w == h.l then
            ns:Print("%s", "pick a winner and a loser first.")
            return
        end
        L():PracticeDuel(h.w, h.l)
    elseif h.kind == "off" and h.w then
        L():PracticeOffline(h.w, true)
    elseif h.kind == "on" and h.w then
        L():PracticeOffline(h.w, false)
    elseif h.kind == "ready" and h.w then
        L():PracticeReady(h.w)
    end
end

function Builder:RenderPractice()
    local dp, lg = ui.dp, ui.log
    local run, p = L():GetPractice()
    local on = S.practice and run ~= nil
    dp:SetShown(on)
    lg:SetShown(on)
    ui.pal:SetShown(not on)
    -- the zoom and the overview sit above the log while it shows
    ui.zoom:ClearAllPoints()
    ui.zoom:SetPoint("BOTTOMRIGHT", ui.cv, "BOTTOMRIGHT", -10, on and (LOG_H + 10) or 10)
    if not on then return end
    local st = run.st
    local bk = run:MainBracket()
    -- playing now
    local playing = {}
    if bk then
        for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then playing[#playing + 1] = m end
        end
    end
    dp.h1r:SetText(bk and EUI():StageSub(run.def, st) or "")
    local y = 32
    for i, box in ipairs(dp.matches) do
        local m = playing[i]
        if m and i <= 3 then
            box.a, box.b = m.a, m.b
            EUI():SetClass(box.c1, m.a)
            EUI():SetClass(box.c2, m.b)
            box.n1:SetText(EUI():Name(m.a))
            box.n2:SetText(EUI():Name(m.b))
            box.sc:SetText(m.wa .. "-" .. m.wb)
            box.b1:SetText(EUI():Plain(m.a) .. " wins")
            box.b2:SetText(EUI():Plain(m.b) .. " wins")
            local live = m.g > 0
            UI():SetEdgeColor(box, live and 0.31 or 1, live and 0.84 or 1, live and 0.73 or 1, live and 0.55 or 0.08)
            box.bg:SetColorTexture(live and 0.05 or 1, live and 0.33 or 1, live and 0.29 or 1, live and 0.12 or 0.03)
            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
            box:Show()
            y = y + 60
        else
            box:Hide()
        end
    end
    if #playing == 0 then
        dp.none:SetText(st.phase == "done" and "The event is over. Start again to run it once more."
            or "No match is being played: the event waits for its next step.")
        dp.none:ClearAllPoints()
        dp.none:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
        dp.none:Show()
        y = y + 34
    else
        dp.none:Hide()
    end
    y = y + 6
    dp.h2:ClearAllPoints()
    dp.h2:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
    dp.h2ln:ClearAllPoints()
    dp.h2ln:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -(y + 18))
    dp.h2ln:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 18))
    y = y + 26
    S.happen = S.happen or { kind = "duel" }
    local h = S.happen
    local labels = { duel = "a duel ends", off = "goes offline", on = "comes back", ready = "is ready" }
    dp.kind:SetText(labels[h.kind] or "a duel ends")
    dp.kind:ClearAllPoints()
    dp.kind:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
    h.w = h.w or st.entrants[1]
    h.l = h.l or st.entrants[2]
    dp.w:SetText(h.w and EUI():Plain(h.w) or "")
    dp.l:SetText(h.l and EUI():Plain(h.l) or "")
    dp.wlab:ClearAllPoints()
    dp.wlab:SetPoint("LEFT", dp.kind, "RIGHT", 6, 0)
    dp.wlab:SetText(h.kind == "duel" and "winner" or "")
    dp.w:ClearAllPoints()
    if h.kind == "duel" then
        dp.w:SetPoint("LEFT", dp.wlab, "RIGHT", 6, 0)
        y = y + 28
        dp.llab:ClearAllPoints()
        dp.llab:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -(y + 4))
        dp.llab:Show()
        dp.l:ClearAllPoints()
        dp.l:SetPoint("LEFT", dp.llab, "RIGHT", 6, 0)
        dp.l:Show()
        dp.doit:ClearAllPoints()
        dp.doit:SetPoint("LEFT", dp.l, "RIGHT", 6, 0)
    else
        dp.w:SetPoint("LEFT", dp.kind, "RIGHT", 6, 0)
        dp.llab:Hide()
        dp.l:Hide()
        dp.doit:ClearAllPoints()
        dp.doit:SetPoint("LEFT", dp.w, "RIGHT", 6, 0)
    end
    y = y + 34
    -- the dummies
    dp.h3:ClearAllPoints()
    dp.h3:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
    dp.h3r:ClearAllPoints()
    dp.h3r:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 1))
    dp.h3ln:ClearAllPoints()
    dp.h3ln:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -(y + 18))
    dp.h3ln:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 18))
    y = y + 26
    local room = dp:GetHeight() or 0
    if room < 50 then room = WIN_H - 31 - TOP_H end
    for i, key in ipairs(st.entrants) do
        local b = dp.dummies[i]
        if not b then
            b = CreateFrame("Button", nil, dp)
            b:SetSize((PAL_W - 28) / 2, 22)
            b.c = b:CreateTexture(nil, "ARTWORK")
            b.c:SetSize(15, 15)
            b.c:SetPoint("LEFT", b, "LEFT", 0, 0)
            b.fs = Text(b, "GameFontHighlightSmall", 11)
            b.fs:SetPoint("LEFT", b.c, "RIGHT", 6, 0)
            b.off = Text(b, "GameFontHighlightSmall", 10)
            b.off:SetTextColor(0.44, 0.44, 0.46)
            b.off:SetPoint("RIGHT", b, "RIGHT", -4, 0)
            b.off:SetText("offline")
            b:SetScript("OnClick", function(self)
                local _, pp = L():GetPractice()
                L():PracticeOffline(self.key, not (pp and pp.off[self.key]))
            end)
            dp.dummies[i] = b
        end
        b.key = key
        local off = p and p.off[key]
        EUI():SetClass(b.c, key)
        b.c:SetDesaturated(off and true or false)
        b.c:SetAlpha(off and 0.5 or 1)
        b.fs:SetText(off and ("|cff6f6f74" .. EUI():Plain(key) .. "|r") or EUI():Name(key))
        b.off:SetShown(off and true or false)
        b:ClearAllPoints()
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        if y + row * 22 + 22 < room then
            b:SetPoint("TOPLEFT", dp, "TOPLEFT", 10 + col * ((PAL_W - 20) / 2), -(y + row * 22))
            b:Show()
        else
            b:Hide()
        end
    end
    for i = #st.entrants + 1, #dp.dummies do dp.dummies[i]:Hide() end
    -- the log: the latest five lines
    local lines = S.log or {}
    local n = #lines
    lg.r:SetText(#st.entrants .. " dummies     " .. floor(((L():PracticeNow() or 0) - (st.t0 or 0)) / 60) .. " min in     nothing is sent or saved")
    for i, l in ipairs(lg.lines) do
        local e = lines[n - i + 1]
        if e then
            l.tm:SetText(date("%H:%M:%S", e.at))
            local c = B().CAT[LOG_CAT[e.kind] or "ev"]
            if e.kind == "error" then
                l.dot:SetVertexColor(1, 0.35, 0.3)
            else
                l.dot:SetVertexColor(c.f2[1], c.f2[2], c.f2[3])
            end
            local text = e.text or ""
            if e.kind == "say" or e.kind == "whisper" or e.kind == "warning" then
                text = text .. "  |cff7a7a80(not sent, practice)|r"
            end
            l.fs:SetText(text)
            l.bg:SetShown(i <= (e.fresh and 4 or 0) and GetTime() - (e.t or 0) < 3)
            l:Show()
        else
            l:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Painting everything
---------------------------------------------------------------------------

Refresh = function()
    if not (win and S.def) then return end
    if S.practice then
        local st = L():GetState("practice")
        if st and st.stage and st.stage ~= S.stage then S.stage = st.stage end
    end
    win:SetWindowTitle(S.readOnly and ("Event builder - " .. (S.def.name or "") .. " (" .. EUI():Plain(S.def.by) .. "'s)")
        or ("Event builder - " .. (S.def.name or "") .. (S.practice and " (practice)" or "")
        .. (S.inside and (" › " .. B():BlockLabel(S.def, S.inside)) or "")))
    RenderTop()
    if not S.practice then Builder:RenderPalette() end
    Builder:RenderCanvas()
    Builder:RenderPractice()
end
Builder.Refresh = function() Refresh() end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

-- def: a library event (table or id) to edit (someone else's opens read-only: Make a copy), or nil for a new one.
function Builder:Open(def, opts)
    if type(def) == "string" then
        local id = def
        def = Ev():GetDef(id)
        if not def then
            -- (not a new event in its place: an old link, or deleted since)
            ns:Print("%s", "that event isn't in the library any more.")
            return false
        end
    end
    if not win then CreateWindow() end
    self:CancelDrag()
    if S.practice then self:StopPractice() end
    self:ClosePicker()
    if ui.ask then ui.ask:Hide() end
    if S.dirty and S.def and not S.readOnly and not self:IsUntouched() then self:Save(true) end
    S = { undo = {}, redo = {}, cat = "ev", search = "", views = {}, glow = {}, log = {} }
    if def then
        S.def = Copy(def)
        S.readOnly = not Ev():IsMine(def)
        S.inLibrary = Ev():GetDef(def.id) ~= nil
    else
        S.def = Ev():NewDef(false)
        S.readOnly = false
    end
    local d = S.def
    d.stages = d.stages or { { id = "s1", name = "Main" } }
    d.scripts, d.blocks, d.vars, d.badges, d.notes = d.scripts or {}, d.blocks or {}, d.vars or {}, d.badges or {}, d.notes or {}
    S.stage = (opts and opts.stage) or d.stages[1].id
    KeepPlace()
    NoteSaved(d)
    if not def then
        -- a new event: closing it before anything was done keeps nothing (no empty "New event" in the library)
        S.savedHash = nil
        S.fresh = FullHash(d)
    end
    S.dirty = not def
    win:SetScale(FitScale())
    win:Show()
    win:Raise()
    Refresh()
    return true
end

-- The library changed (sync): a newer version of the open event (saved on my other client, or by its owner while I
-- look at it) comes in when nothing here is unsaved; with unsaved work it is said once (Save keeps mine). An event
-- deleted elsewhere is said once too: saving keeps it as a new event (Builder:Save).
function Builder:OnLibraryChanged()
    local d = S.def
    if not (win and win:IsShown() and d and d.id) or S.practice then return end
    local saved = Ev():GetDef(d.id)
    if not saved then
        if S.inLibrary and not S.gone then
            S.gone = true
            if not S.readOnly then ns:Print("%s was deleted from the library: Save keeps it as a new event.", d.name or "This event") end
            Refresh()
        end
        return
    end
    if (tonumber(saved.rev) or 0) <= (tonumber(d.rev) or 0) then return end
    if S.dirty and not S.readOnly then
        if S.staleRev ~= saved.rev then
            S.staleRev = saved.rev
            ns:Print("%s was changed somewhere else too: Save keeps your version.", d.name or "This event")
        end
        return
    end
    if S.drag or S.cardDrag or S.noteDrag then
        -- (not under a piece being dragged: once it is let go)
        ns.Util.After(0.5, function() Builder:OnLibraryChanged() end)
        return
    end
    -- nothing unsaved here: the newer version (undo can't go back past it: its steps were made on the old one)
    self:ClosePicker()
    if ui.ask then ui.ask:Hide() end
    S.def = Copy(saved)
    S.readOnly = not Ev():IsMine(saved)
    local nd = S.def
    nd.stages = nd.stages or { { id = "s1", name = "Main" } }
    nd.scripts, nd.blocks, nd.vars, nd.badges, nd.notes = nd.scripts or {}, nd.blocks or {}, nd.vars or {}, nd.badges or {},
        nd.notes or {}
    S.undo, S.redo = {}, {}
    S.builtIn = nil
    KeepPlace()
    NoteSaved(nd)
    S.dirty = false
    Refresh()
end

function Builder:Close() if win then win:Hide() end end
function Builder:IsShown() return win ~= nil and win:IsShown() end
function Builder:GetWindow() return win end
function Builder:GetState() return S, ui end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Builder:OnInit()
    ns:On("EVENTS_UPDATED", function() Builder:OnLibraryChanged() end)
    ns:On("EVENT_PRACTICE_UPDATED", function()
        if not (win and win:IsShown() and S.practice) then return end
        ns.Util.Debounce("event-builder-practice", 0.1, function()
            local st = L():GetState("practice")
            if st and st.phase == "done" and S.def then
                S.practicedHash = ContentHash(S.def)
                if not S.dirty then Builder:NotePracticed(S.def) end
            end
            Refresh()
        end)
    end)
    ns:On("EVENT_PRACTICE_RAN", function(sid, block)
        if not S.practice then return end
        S.glow = S.glow or {}
        S.glow[(block and (block .. "/") or "") .. tostring(sid)] = GetTime()
    end)
    ns:On("EVENT_PRACTICE_LOG", function(kind, text)
        if not S.practice or kind == "script" then return end
        S.log = S.log or {}
        local run = L():GetPractice()
        tinsert(S.log, { kind = kind, text = text, at = L():PracticeNow(), t = GetTime(), fresh = true })
        while #S.log > 60 do tremove(S.log, 1) end
    end)
    ns:RegisterSlash("event", function(rest)
        rest = ns.Util.Trim(rest or "")
        if rest == "new" or rest == "" then
            Builder:Open(nil)
        else
            local found
            for _, d in ipairs(Ev():GetDefs()) do
                if string.lower(d.name) == string.lower(rest) then found = d end
            end
            if found then Builder:Open(found) else ns:Print("no event called %s.", rest) end
        end
    end, "open the event builder (new, or an event's name)")
end

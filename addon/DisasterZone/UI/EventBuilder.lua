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
-- (filled in below: the definitions' palette rows and editors, the map sheet, the questions sheet, the place card)
local Defs, MapSheet, QSheet = {}, {}, {}
Builder.Defs, Builder.MapSheet, Builder.QSheet = Defs, MapSheet, QSheet   -- (the tests and the audit drive them)

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

-- The event's definitions (tags, scores ...) can be changed: my event, not in practice (inside a built-in smart block
-- too: they're the event's, not the block's).
local function CanEditDefs() return not S.readOnly and not S.practice and S.def ~= nil end

-- Someone else's event: why nothing changes (said on the click, the control stays as it was).
function Builder:SayReadOnly()
    if S.practice then
        ns:Print("%s", "end the practice first: it runs the event as it was.")
    elseif S.inside and not S.readOnly then
        ns:Print("%s", "these pieces are built in: Make my own copy to change them.")
    else
        ns:Print("this is %s's event: make a copy to change it.", EUI():Plain(Def() and Def().by))
    end
end

local function NewId(prefix)
    S.idn = (S.idn or 0) + 1
    return (prefix or "s") .. string.format("%x", Now() % 1048576) .. S.idn
end

-- (the definitions too: a tag's colour or a place's size changes how the event runs)
local function ContentHash(d)
    return Util().Hash({ d.stages, d.scripts, d.blocks, d.badges, d.vars, d.tags or false, d.scores or false,
        d.places or false, d.lists or false, d.asks or false })
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
    Builder:CloseFloating()
    if ui.ask then ui.ask:Hide() end
    MarkDirty()
    Refresh()
end

-- The editors over the builder (a definition's popover, the map and questions sheets, a place's card, a confirm):
-- they hold parts of the event, so they go when it's swapped, closed or practised.
function Builder:CloseFloating()
    if Defs.Close then Defs:Close() end
    if QSheet.Close then QSheet:Close() end
    if MapSheet.Close then MapSheet:Close() end
    if Defs.HideCard then Defs:HideCard() end
    if ui.confirm then ui.confirm:Hide() end
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
        elseif key == "ESCAPE" and ((ui.confirm and ui.confirm:IsShown()) or (ui.msheet and ui.msheet:IsShown())
            or (ui.qsheet and ui.qsheet:IsShown()) or (ui.dpop and ui.dpop:IsShown())) then
            self:SetPropagateKeyboardInput(false)
            if ui.confirm and ui.confirm:IsShown() then ui.confirm:Hide()
            elseif ui.msheet and ui.msheet:IsShown() then MapSheet:Close()
            elseif ui.qsheet and ui.qsheet:IsShown() then QSheet:Close()
            else Defs:Close() end
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    win:SetScript("OnEnter", function(self) if self.EnableKeyboard then self:EnableKeyboard(true) end end)
    win:SetScript("OnHide", function()
        -- a drag still going: the piece goes back first (so the save below has it), its drawing goes
        Builder:CancelDrag()
        Builder:ClosePicker()
        Builder:CloseFloating()
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
    UI():AttachRestLabel(name)
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
        -- (its colour from the category's light top to its dark foot, as the pieces)
        if b.dot.SetGradient and CreateColor then
            b.dot:SetGradient("VERTICAL", CreateColor(c.f[1], c.f[2], c.f[3], 1), CreateColor(c.f2[1], c.f2[2], c.f2[3], 1))
        else
            b.dot:SetVertexColor(c.f2[1], c.f2[2], c.f2[3])
        end
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

-- What the values "when" pieces give are (the palette's and the picker's words beside them).
local CTX_DESC = {
    winner = "who won", loser = "who lost", player1 = "the match's first player", player2 = "its second player",
    both = "the two players", opponent = "the other one of the match", score = "like 2-1", game = "game number",
    match = "match number", round = "round number", finalist1 = "a finalist", finalist2 = "the other finalist",
    champion = "who won it all", runnerup = "who lost the final", third = "won the bronze", player = "who it's about",
    each = "one player at a time", answer = "what they answered", other = "the other one in it",
    creature = "what was killed", item = "the item, or the list's item", count = "how many", emote = "the emote",
    toucher = "who touched", touched = "who was touched", who = "who targeted", whom = "who was targeted",
    place = "the place",
}

-- The pieces of the palette's view: { { title, list = { entry ... } } }. An entry: { key } (a piece of the catalogue),
-- { piece, desc } (a value), { def = kind, e } (one of the event's definitions), { add = kind } (its "+ Add"),
-- { button, fn, icon } (an action).
local function PaletteGroups()
    local d = Def()
    local groups = {}
    local function group(title, list) if #list > 0 then groups[#groups + 1] = { title = title, list = list } end end
    local q = string.lower(S.search or "")
    if q ~= "" then
        -- the event's definitions by name, then pieces by their words, then the values "when" pieces give
        local defs, found = {}, {}
        for _, kind in ipairs(B().DEF_ORDER) do
            for _, e in ipairs(B():Defs(d, kind)) do
                if string.lower(tostring(e.n or "")):find(q, 1, true) then defs[#defs + 1] = { def = kind, e = e } end
            end
        end
        for _, cat in ipairs(B().CATS) do
            for _, k in ipairs(B().PALETTE[cat.key] or {}) do
                local t = string.lower((B().PIECES[k].text or ""):gsub("{%d}", ""))
                if t:find(q, 1, true) then found[#found + 1] = { key = k } end
            end
        end
        for _, name in ipairs(B().CTX_ORDER) do
            local c = B().CTX[name]
            if c and c.label:find(q, 1, true) then found[#found + 1] = { piece = { k = "ctx", a = { name } } } end
        end
        group("In this event", defs)
        group(#defs > 0 and "Pieces" or "Found", found)
        return groups
    end
    local cat = S.cat or "ev"
    if S.inside and cat == "sm" then
        local inner = {}
        for _, k in ipairs(B().INNER_PALETTE.bracket) do inner[#inner + 1] = { key = k } end
        group("Its own pieces", inner)
    end
    -- the category's definitions first (Players: tags, Scores: scores ...), then its pieces
    local kind = B().CAT_DEFS[cat]
    if kind then
        local rows = {}
        for _, e in ipairs(Defs:Ordered(d, kind)) do rows[#rows + 1] = { def = kind, e = e } end
        rows[#rows + 1] = { add = kind }
        group(Defs.HEAD[kind], rows)
    end
    local main = {}
    for _, k in ipairs(B().PALETTE[cat] or {}) do main[#main + 1] = { key = k } end
    if kind then
        -- (right under the definitions, the pieces about them, their "when" pieces first: the mockups' Players lists
        -- "when no one has tag", the touch, "has tag", "players with tag", tag, untag before the host and the rest)
        local t = ({ tags = "tag", scores = "score", places = "place", lists = "list", asks = "ask" })[kind]
        local function about(k)
            local pd = B().PIECES[k]
            for _, a in ipairs(pd and pd.args or {}) do
                if a.t == t or (t == "place" and a.t == "where") then return true end
            end
            return false
        end
        -- (Players: its "when" pieces lead, the touch and target ones too: their players blanks take the tags)
        local rank = {}
        for i, it in ipairs(main) do
            local pd = B().PIECES[it.key]
            local hat = pd and pd.shape == "hat"
            rank[it] = ((cat == "pl" and hat) and 1 or (about(it.key) and 2) or 3) * 1000 + i
        end
        tsort(main, function(a, b) return rank[a] < rank[b] end)
    end
    if cat == "lo" then
        local vars = {}
        for _, v in ipairs(d.vars or {}) do vars[#vars + 1] = { piece = { k = "var", a = { v.n } } } end
        vars[#vars + 1] = { button = "Make a variable", fn = function() Builder:NewVariable() end, plus = true }
        group("Variables", vars)
        group("Pieces", main)
        return groups
    end
    if cat == "ev" then
        local smart = {}
        for _, k in ipairs({ "bk.start", "bk.end", "bk.game", "bk.final", "bk.done", "su.join", "su.close" }) do
            smart[#smart + 1] = { key = k }
        end
        group("Events", main)
        group("From smart blocks", smart)
        return groups
    end
    if cat == "pl" then
        group("Pieces", main)
        local ctx = {}
        for _, name in ipairs(B().CTX_ORDER) do
            if name ~= "answer" then ctx[#ctx + 1] = { piece = { k = "ctx", a = { name } }, desc = CTX_DESC[name] } end
        end
        group("From \"when\" pieces", ctx)
        return groups
    end
    if cat == "ch" then
        local own, guild = {}, {}
        for _, it in ipairs(main) do
            if it.key == "ch.guild" then guild[#guild + 1] = it else own[#own + 1] = it end
        end
        group("Messages", own)
        group("For the guild", guild)
        return groups
    end
    if cat == "sm" then
        local blocks = {}
        for _, k in ipairs(B().SMART_ORDER) do
            blocks[#blocks + 1] = { button = "Add " .. B().SMART[k].label, icon = B().SMART[k].icon,
                fn = function() Builder:AddBlock(k) end }
        end
        group("Smart blocks", blocks)
        group("Their pieces", main)
        return groups
    end
    group(kind and "Pieces" or ((B().CAT[cat] and B().CAT[cat].label) or ""), main)
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

local PAL_LIST_W = PAL_W - CAT_W - 22      -- the palette's column (a piece wider than this takes two lines there)

-- A palette row's parts for a definition (made once per pooled row): swatch, name, its line, the pencil.
local function DefRowParts(it)
    if it.nm then return end
    it.sel = it:CreateTexture(nil, "BACKGROUND", nil, 1)
    it.sel:SetAllPoints()
    it.sel:SetColorTexture(1, 0.82, 0, 0.10)
    it.bar = it:CreateTexture(nil, "ARTWORK")
    it.bar:SetColorTexture(1, 0.82, 0)
    it.bar:SetPoint("TOPLEFT")
    it.bar:SetPoint("BOTTOMLEFT")
    it.bar:SetWidth(2)
    it.hov = it:CreateTexture(nil, "HIGHLIGHT")
    it.hov:SetAllPoints()
    it.hov:SetColorTexture(1, 1, 1, 0.04)
    it.sw = it:CreateTexture(nil, "ARTWORK", nil, 1)
    it.sw2 = it:CreateTexture(nil, "ARTWORK", nil, 2)
    it.sw3 = it:CreateTexture(nil, "ARTWORK", nil, 3)
    it.nm = Text(it, "GameFontHighlight", 11.5)
    it.sb = Text(it, "GameFontHighlightSmall", 10)
    it.sb:SetTextColor(0.62, 0.62, 0.62)
    it.pen = it:CreateTexture(nil, "ARTWORK")
    it.pen:SetSize(11, 11)
    it.pen:SetPoint("RIGHT", it, "RIGHT", -6, 0)
    EUI():Glyph(it.pen, 16, 1, 1, 1, 0.55)
    it.plus = it:CreateTexture(nil, "ARTWORK")
    it.plus:SetSize(10, 10)
    it.caret = it:CreateTexture(nil, "ARTWORK")
    it.caret:SetSize(10, 10)
end

local function HideDefParts(it)
    if not it.nm then return end
    for _, k in ipairs({ "sel", "bar", "hov", "sw", "sw2", "sw3", "nm", "sb", "pen", "plus", "caret" }) do it[k]:Hide() end
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
    pal.rowOf, pal.rowY = {}, {}
    for gi, g in ipairs(PaletteGroups()) do
        nh = nh + 1
        local h = pal.heads[nh]
        if not h then
            h = Text(child, "GameFontNormal", 11)
            pal.heads[nh] = h
        end
        if gi > 1 then y = y + 6 end
        h:SetText(g.title)
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
        h:Show()
        y = y + 20
        local lastWasHat
        for _, entry in ipairs(g.list) do
            n = n + 1
            local it = pal.items[n]
            if not it then
                it = CreateFrame("Button", nil, child)
                it:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
            -- (a pooled row keeps nothing of what it showed last: a piece, a definition)
            it.piece, it.defId, it.kind, it.builtin = nil, nil, nil, nil
            it.fs:Hide()
            it.desc:Hide()
            it.ic:Hide()
            HideDefParts(it)
            UI():SetEdgeColor(it, 0, 0, 0, 0)
            it.bg:SetColorTexture(0, 0, 0, 0)
            it:SetScript("OnEnter", nil)
            it:SetScript("OnLeave", nil)
            it:SetScript("OnMouseDown", nil)
            it:SetScript("OnClick", nil)
            local h = 26
            local gap = 6
            if entry.def then
                h = Defs:PaletteRow(it, entry.def, entry.e)
                pal.rowOf[entry.def .. ":" .. tostring(entry.e.id)] = it
                pal.rowY[entry.def .. ":" .. tostring(entry.e.id)] = { y = y, h = h }
                gap = 2
            elseif entry.add then
                y = y + 2
                h = Defs:AddRow(it, entry.add)
                pal.rowOf["add:" .. entry.add] = it
                pal.rowY["add:" .. entry.add] = { y = y, h = h }
            elseif entry.button then
                it.fs:SetText(entry.button)
                it.fs:ClearAllPoints()
                local x = 10
                if entry.icon then
                    it.ic:SetTexture(entry.icon)
                    it.ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    it.ic:Show()
                    x = 30
                elseif entry.plus then
                    DefRowParts(it)
                    HideDefParts(it)
                    it.plus:ClearAllPoints()
                    it.plus:SetPoint("LEFT", it, "LEFT", 9, 0)
                    EUI():Glyph(it.plus, UI().ICON.plus or 39, 0.86, 0.86, 0.86)
                    it.plus:Show()
                    x = 25
                end
                it.fs:SetPoint("LEFT", it, "LEFT", x, 0)
                it.fs:Show()
                UI():SetEdgeColor(it, 0.34, 0.34, 0.38, 0.9)
                it.bg:SetColorTexture(0.1, 0.1, 0.12, 0.92)
                it:SetSize(min(PAL_LIST_W, x + TextW(it.fs) + 12), 24)
                h = 24
                it:SetScript("OnClick", function(self, button)
                    if button ~= "LeftButton" then return end
                    if not CanEdit() then Builder:SayReadOnly() return end
                    if self.entry.fn then self.entry.fn() end
                end)
            else
                local piece = entry.piece or FillBlocks(B():New(entry.key))
                -- a piece wider than the column takes two lines (or more) here; it drops onto the canvas on one
                local draw = EP():Draw(it, piece, { def = d, static = true, wrap = entry.desc and nil or PAL_LIST_W })
                local k = (draw.w or 0) > PAL_LIST_W and PAL_LIST_W / draw.w or 1
                draw:SetScale(k)
                draw:SetPoint("TOPLEFT", it, "TOPLEFT", 0, 0)
                it.draw = draw
                local hat = Shape(piece) == "hat"
                -- (a hat's dome stands above the row before it: a little more room there)
                if hat and not lastWasHat and n > 1 then y = y + 4 end
                h = floor((draw.h or 28) * k + 0.5) + (hat and 4 or 2)
                local w = min(PAL_LIST_W, max(30, (draw.w or 100) * k))
                if entry.desc then
                    it.desc:SetText(entry.desc)
                    it.desc:ClearAllPoints()
                    it.desc:SetPoint("LEFT", it, "LEFT", w + 6, (hat and -5) or 0)
                    it.desc:SetWidth(max(10, PAL_W - CAT_W - 26 - w - 6))
                    it.desc:Show()
                end
                it:SetSize(PAL_LIST_W, h)
                it.piece = piece
                it:SetScript("OnMouseDown", function(self, button)
                    if button == "LeftButton" and CanEdit() then Builder:PressNew(self.piece, self) end
                end)
                it:SetScript("OnClick", function(self, button)
                    if button == "LeftButton" and not CanEdit() then Builder:SayReadOnly() end
                end)
                it:SetScript("OnEnter", function(self) Builder:PieceTip(self.piece.k, self, true) end)
                it:SetScript("OnLeave", function(self) Builder:PieceTip(nil, self, false) end)
                lastWasHat = hat
            end
            if not (entry.key or entry.piece) then lastWasHat = nil end
            it:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
            y = y + h + gap
        end
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
        pal.none:SetText("No piece has those words. Try one word, like \"tell\" or \"winner\".")
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
    -- the empty stage: a box where its first "when" piece goes (a faint one in it), and its words
    local em = CreateFrame("Frame", nil, cv)
    em:SetSize(292, 236)
    em:SetPoint("CENTER", cv, "CENTER", 0, 10)
    em.bg = em:CreateTexture(nil, "BACKGROUND")
    em.bg:SetAllPoints()
    em.bg:SetColorTexture(1, 1, 1, 0.02)
    EUI():Edge(em, 1, 1, 1, 0.14)
    em.t = Text(em, "GameFontHighlight", 14)
    em.t:SetJustifyH("CENTER")
    em.t:SetPoint("TOP", em, "TOP", 0, -108)
    em.t2 = Text(em, "GameFontHighlightSmall", 11.5)
    em.t2:SetJustifyH("CENTER")
    em.t2:SetWordWrap(true)
    em.t2:SetWidth(270)
    em.t2:SetPoint("TOP", em.t, "BOTTOM", 0, -6)
    em.t2:SetTextColor(0.62, 0.62, 0.62)
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

local OnPiece, OnBlank, OnHover   -- (below)
local OpenFitted                  -- (below) a view seen for the first time: at 100%, or zoomed out to show it all
local PlacePicker        -- (below) the picker under its blank, drawn again

local function ScriptKey(s) return (S.inside and (S.inside .. "/") or "") .. s.id end

local function DrawScriptFrame(s, problems)
    local opts = { def = Def(), problems = problems, onPiece = OnPiece, onBlank = OnBlank, onHover = OnHover,
        onEnter = function(p, f, on) Builder:PieceTip(p and p.k, f, on) end, locked = S.inside and not (Def().blocks[S.inside] and Def().blocks[S.inside].inner), static = false,
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
    -- (a place's card belongs to a blank this drawing replaces)
    if ui.pcard then ui.pcard:Hide() end
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
    -- an empty stage says what to do; a new event's offers the examples to start from
    local em = ui.empty
    local empty = #scripts == 0 and nBlocks == 0 and i == 0 and not S.practice
    local blankEvent = #d.scripts == 0 and next(d.blocks) == nil and not S.inside
    local startFrom = empty and blankEvent and CanEdit()
    self:RenderStartFrom(startFrom)
    S.startFrom = startFrom
    if empty and not startFrom then
        local stName = B():StageName(d, S.stage)
        em.t:SetText("Nothing runs in " .. stName .. " yet")
        em.t2:SetText(S.stage == "*" and "Pieces here run in every stage: drag a \"when\" piece here."
            or ("Drag a \"when\" piece here. Pieces in this stage run while the event is in " .. stName .. "."))
        if not em.ghost then
            -- (a faint "when" piece where the first one goes)
            em.ghost = EP():Draw(em, B():New("ev.start"), { static = true })
            em.ghost:SetAlpha(0.42)
        end
        em.ghost:ClearAllPoints()
        em.ghost:SetPoint("TOP", em, "TOP", 0, -46)
        em:Show()
    else
        em:Hide()
    end
    self:RenderOverview()
    self:RenderStatus()
    OpenFitted(View())
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
    -- (nothing to say yet: an event with no pieces at all, its examples on the canvas)
    if S.practice or (#(Def().scripts or {}) == 0 and next(Def().blocks or {}) == nil) then
        st:Hide()
        if ui.overview then ui.overview:SetShown(not S.startFrom) end
        return
    end
    if ui.overview then ui.overview:Show() end
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
        -- every piece is set: practise it first (a practice run to its end of exactly this event), then host it
        local d = Def()
        local state = Ev():GetDef(d.id) and Ev():ReviewState(Ev():GetDef(d.id)) or "draft"
        local h = ContentHash(d)
        local p = ns.db and ns.db.eventPracticed and d.id and ns.db.eventPracticed[d.id]
        local practiced = S.practicedHash == h or (p ~= nil and p.h == h)
        st.fs:SetText((state == "ranked" and not S.dirty and "Ranked · ready to host")
            or (practiced and "Ready to host") or "Ready to practice")
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
local CARD_DD_W = { fmt = 168, seed = 168, closes = 196, bo = 52, fbo = 52, spots = 60, noshow = 84, atonce = 112,
    win = 120 }

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
        -- the rows: each setting (Matches: "Best of" with its final beside it, where its entrants come from, and a line
        -- under "Won by" when the pieces decide)
        local list = {}
        for _, o in ipairs(sm.settings) do
            if o.key ~= "fbo" then list[#list + 1] = o end
            if b.kind == "bracket" and o.key == "seed" then list[#list + 1] = { key = "_entrants", label = "Entrants" } end
        end
        local function opt(key)
            for _, x in ipairs(sm.settings) do if x.key == key then return x end end
        end
        local function dd(row, field, key, x)
            local o = opt(key)
            row[field] = row[field] or UI():CreateSleekMenuButton(row, "", 168, function(root)
                local list2 = o.choices
                if o.kind == "num" then
                    list2 = {}
                    for _, n in ipairs({ 4, 8, 12, 16, 20, 24, 32, 40 }) do list2[#list2 + 1] = n end
                end
                for _, c in ipairs(list2 or {}) do
                    local v, label = c, nil
                    if type(c) == "table" then v, label = c[1], c[2] end
                    label = label or (o.kind == "dur" and B():DurationText(v)) or tostring(v)
                    root:CreateRadio(label, function() return B():SmartSetting(Def().blocks[self.bid], key) == v end,
                        function()
                            if not CanEdit() then Builder:SayReadOnly() return end
                            local before = Snapshot()
                            Def().blocks[self.bid].set[key] = v
                            Changed(before)
                        end)
                end
            end, 21)
            local v = B():SmartSetting(b, key)
            local label
            if o.kind == "choice" then
                for _, c in ipairs(o.choices) do if c[1] == v then label = c[2] end end
            elseif o.kind == "dur" then
                label = B():DurationText(v)
            end
            row[field]:SetText(label or tostring(v))
            row[field]:SetWidth(CARD_DD_W[key] or 92)
            row[field]:ClearAllPoints()
            row[field]:SetPoint("LEFT", row, "LEFT", x, 0)
            row[field]:Show()
            return row[field]
        end
        for i, o in ipairs(list) do
            local row = self.rows[i]
            if not row then
                row = CreateFrame("Frame", nil, self)
                row:SetSize(298, 27)
                row.lab = Text(row, "GameFontHighlightSmall", 11)
                row.lab:SetTextColor(0.62, 0.62, 0.62)
                row.lab:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.mid = Text(row, "GameFontHighlightSmall", 11)
                row.mid:SetTextColor(0.62, 0.62, 0.62)
                row.words = Text(row, "GameFontHighlightSmall", 11)
                row.words:SetTextColor(0.85, 0.85, 0.85)
                self.rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self, "TOPLEFT", 10, -y)
            row:Show()
            row.lab:SetText(o.label)
            for _, k in ipairs({ "dd", "dd2", "sw", "pill" }) do if row[k] then row[k]:Hide() end end
            row.mid:Hide()
            row.words:Hide()
            row.key = o.key
            if o.key == "_entrants" then
                -- (where the players come from: the sign-up's list, else the host's group)
                local su = B():BlocksOf(d, "signup")[1]
                if su then
                    row.pill = row.pill or CreateFrame("Frame", nil, row)
                    local pl = row.pill
                    if not pl.fs then
                        pl:SetHeight(19)
                        UI():AddPillShape(pl, 19)
                        local c = B().CAT.sm
                        pl:SetPillColors({ c.f2[1], c.f2[2], c.f2[3], 1 }, { c.e[1], c.e[2], c.e[3], 0.85 })
                        pl.ic = pl:CreateTexture(nil, "ARTWORK")
                        pl.ic:SetSize(13, 13)
                        pl.ic:SetPoint("LEFT", pl, "LEFT", 5, 0)
                        pl.ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        pl.fs = Text(pl, "GameFontHighlight", 11)
                        pl.fs:SetPoint("LEFT", pl, "LEFT", 21, 0)
                    end
                    pl.ic:SetTexture(B().SMART.signup.icon)
                    pl.fs:SetText(B():BlockLabel(d, su) .. " list")
                    pl:SetWidth(21 + TextW(pl.fs) + 9)
                    pl:ClearAllPoints()
                    pl:SetPoint("LEFT", row, "LEFT", 70, 0)
                    pl:Show()
                else
                    row.words:SetText("the host's group")
                    row.words:ClearAllPoints()
                    row.words:SetPoint("LEFT", row, "LEFT", 70, 0)
                    row.words:Show()
                end
            elseif o.kind == "bool" then
                row.sw = row.sw or UI():CreateSwitch(row, function() return B():SmartSetting(Def().blocks[self.bid], row.key) end,
                    function(on)
                        if not CanEdit() then Builder:SayReadOnly(); row.sw:Refresh() return end
                        local before = Snapshot()
                        Def().blocks[self.bid].set[row.key] = on and true or false
                        Changed(before)
                    end)
                row.sw:ClearAllPoints()
                row.sw:SetPoint("LEFT", row, "LEFT", 70, 0)
                row.sw:Show()
                if row.sw.Refresh then row.sw:Refresh() end
                if o.key == "bronze" then
                    row.words:SetText("a match for third")
                    row.words:ClearAllPoints()
                    row.words:SetPoint("LEFT", row.sw, "RIGHT", 8, 0)
                    row.words:Show()
                end
            else
                local first = dd(row, "dd", o.key, 70)
                if o.key == "bo" and opt("fbo") then
                    -- best of [3] final [5]
                    row.mid:SetText("final")
                    row.mid:ClearAllPoints()
                    row.mid:SetPoint("LEFT", first, "RIGHT", 8, 0)
                    row.mid:Show()
                    dd(row, "dd2", "fbo", 70 + first:GetWidth() + 8 + TextW(row.mid) + 8)
                end
            end
            y = y + 27
        end
        for i = #list + 1, #self.rows do self.rows[i]:Hide() end
        -- won by the pieces: what that means
        self.note = self.note or Text(self, "GameFontHighlightSmall", 10.5)
        if b.kind == "bracket" and B():SmartSetting(b, "win") == "pieces" then
            self.note:SetWordWrap(true)
            self.note:SetWidth(318 - 80 - 12)
            self.note:SetTextColor(0.62, 0.62, 0.62)
            self.note:SetText("Duels don't count. A match ends when a piece says |cffffd100award the match to|r.")
            self.note:ClearAllPoints()
            self.note:SetPoint("TOPLEFT", self, "TOPLEFT", 80, -(y - 2))
            self.note:Show()
            y = y + max(14, floor((self.note:GetStringHeight() or 28) + 0.5)) + 4
        else
            self.note:Hide()
        end
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
    if button ~= "LeftButton" then return end
    local x, y = GetCursorPosition()
    if not down then
        -- a click (no drag) on a value sitting in a blank: that blank's picker (to change what's there)
        local tap = S.tap
        S.tap = nil
        if tap and tap.piece == piece and not S.drag and abs(x - tap.x0) + abs(y - tap.y0) <= 5 then
            Builder:TapValue(piece, frame)
        end
        return
    end
    if not CanEdit() then return end
    S.press = { piece = piece, frame = frame, x0 = x, y0 = y }
    S.tap = IsValue(piece) and { piece = piece, x0 = x, y0 = y } or nil
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

-- Blanks whose choice comes from a menu (the rest open the picker: values, places, typed words).
local DROPDOWN = { channel = true, stat = true, stage = true, marker = true, dur = true, var = true, badge = true,
    block = true, timer = true, tag = true, score = true, list = true, ask = true, what = true, how = true, sound = true,
    state = true, since = true, emote = true }
-- Typed in the picker's field (label, item, creature: words only, no values)
local TYPED = { num = true, text = true, any = true, label = true, item = true, creature = true }
local WORDS_ONLY = { label = true, item = true, creature = true }

-- The values a blank in this script may take: what its hat gives, and what the loops and asks inside it add.
local function ScopeOf(script)
    local scope = B():Scope(script.top, Scripts())
    B():Walk(script.top, function(p)
        for _, g in ipairs(B():Gives(p)) do scope[g] = true end
    end)
    return scope
end

-- Value pieces the picker offers, by the type they give: { section, keys }.
local OFFER = {
    { "EVENT", { "pl.host", "pl.all", "pl.rand", "pl.seed", "pl.top", "pc.near" } },
    { "NUMBERS", { "lo.add", "lo.sub", "lo.rand", "pt.get", "pt.place", "pt.total", "tm.since", "tm.left", "pc.yards",
        "pl.howmany", "lo.lcount", "lo.lpos", "as.count", "wo.items", "wo.gold" } },
    { "WORDS", { "pc.sub", "pc.zone", "pc.warm", "lo.litem", "lo.lrand", "lo.lmine", "as.answer", "as.top" } },
}
local BOOLS = { "pl.online", "pl.ready", "pl.notready", "pl.is", "pl.in", "pl.has", "pc.in", "wo.is", "lo.set", "lo.gt",
    "lo.lt", "lo.eq", "lo.match", "lo.and", "lo.or", "lo.not", "bk.still", "pl.below" }

-- A place's one line: where it is and how big ("Halaa · 600 yd").
local function PlaceLine(pl)
    if type(pl) ~= "table" then return "" end
    local where = (pl.sz and pl.sz ~= "" and pl.sz) or (pl.z and pl.z ~= "" and pl.z)
    if not (tonumber(pl.map) and tonumber(pl.x)) then return where and (where .. " · the subzone") or "not set yet" end
    return (where and (where .. " · ") or "") .. floor(tonumber(pl.r) or 30) .. " yd"
end
Defs.PlaceLine = PlaceLine

-- The picker's rows for a blank of type t: { piece | chip = { kind, id } | action = { text, icon, fn }, desc, section }.
local function Choices(script, piece, slot, t)
    local out = {}
    local d = Def()
    local function add(section, p, desc)
        local vt = B():ValueType(p)
        if t == "any" or t == "text" or B():Fits(t, vt) then out[#out + 1] = { piece = p, desc = desc, section = section } end
    end
    local scope = ScopeOf(script)
    if t == "place" or t == "where" then
        for _, e in ipairs(Defs:Ordered(d, "places")) do
            out[#out + 1] = { chip = { "place", e.id }, desc = PlaceLine(e), section = "THIS EVENT" }
        end
    end
    for _, name in ipairs(B().CTX_ORDER) do
        if scope[name] then add("THIS SCRIPT", { k = "ctx", a = { name } }, CTX_DESC[name]) end
    end
    if t == "bool" then
        for _, k in ipairs(BOOLS) do add("YES / NO", FillBlocks(B():New(k))) end
        return out
    end
    if t == "place" or t == "where" then
        if t == "where" then
            for _, k in ipairs({ "pl.host", "pl.rand", "pc.near" }) do add("PLAYERS", B():New(k)) end
        end
        local cur = piece.a[slot]
        local here = type(cur) == "string" and B():Definition(d, "places", cur)
        if here then
            out[#out + 1] = { action = { "Change " .. here.n .. " on the map", 31, function() Builder:ClosePicker(); MapSheet:Open({ pid = cur }) end },
                section = "NEW PLACE" }
        end
        out[#out + 1] = { action = { "Set from where I stand", 37, function() Builder:NewPlaceFor(piece, slot, "stand") end },
            section = "NEW PLACE" }
        out[#out + 1] = { action = { "Pick on the map", 31, function() Builder:NewPlaceFor(piece, slot, "map") end },
            section = "NEW PLACE" }
        return out
    end
    if t == "players" then
        for _, e in ipairs(Defs:Ordered(d, "tags")) do add("TAGS", { k = "pl.tagged", a = { e.id } }) end
    end
    for _, sec in ipairs(OFFER) do
        if sec[1] == "EVENT" or t ~= "player" and t ~= "players" then
            for _, k in ipairs(sec[2]) do
                add(sec[1], B():New(k), (k == "pl.host" and "who runs it") or (k == "pl.all" and "everyone in it") or nil)
            end
        end
    end
    for _, v in ipairs(d.vars or {}) do add("VARIABLES", { k = "var", a = { v.n } }) end
    for _, k in ipairs({ "bk.champ", "bk.second", "bk.third", "bk.fin1", "bk.fin2", "bk.left", "bk.round", "su.list", "su.count" }) do
        local p = FillBlocks(B():New(k))
        if p.a[1] then add("SMART BLOCKS", p) end
    end
    return out
end

local PICK_TITLE = { player = "Pick a player", players = "Pick players", num = "A number", text = "Text", any = "A value",
    bool = "A yes / no", place = "Pick a place", where = "A place or a player", label = "A button", item = "An item",
    creature = "A creature" }
local PICK_FIELD = { num = "Type a number, Enter", label = "The button's name, Enter", item = "An item's name or id, Enter",
    creature = "A creature's name, Enter" }
local FILLER = { to = true, of = true, from = true, ["in"] = true, as = true, the = true, by = true, with = true, ["for"] = true,
    ["and"] = true, is = true, into = true, on = true, at = true, an = true, a = true }

-- 'for "leaves"': the word of the piece the blank is for (the one before it, or the piece's first).
local function PickFor(piece, slot)
    local pd = B().PIECES[piece.k]
    if not pd then return "" end
    local before
    for _, tok in ipairs(EP().Tokens(pd.text)) do
        if tok == slot then break end
        if type(tok) == "string" then before = tok end
    end
    local w = before and before:match("(%S+)$")
    if not w or FILLER[w] or w:find("'") then
        w = nil
        for word in (pd.text:gsub("{%d}", " ")):gmatch("%S+") do
            if word ~= "when" and word ~= "every" and not FILLER[word] then w = word break end
        end
    end
    return w and ("for \"" .. w:gsub("[:%p]+$", "") .. "\"") or ""
end

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
    p.field:SetScript("OnTextChanged", function(self, user)
        -- (what's typed narrows the values below; a number hides them)
        if user and S.pick and not WORDS_ONLY[S.pick.a.t] then Builder:FillPicker(self:GetText()) end
    end)
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
    -- an item shift-clicked (a bag, a link in chat) while an item's blank is being typed goes in it
    local function onLink(link)
        local pk = S.pick
        if type(link) == "string" and link:find("item:%d+") and pk and pk.a.t == "item" and p:IsShown()
            and p.field:IsShown() and p.field:HasFocus() then
            p.field:SetText(link)
        end
    end
    if hooksecurefunc then
        if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", onLink) end
        if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", onLink) end
    end
    return p
end

-- The blank's type and catalogue entry (a filter blank: its choice's type).
local function BlankArg(piece, slot)
    local pd = B().PIECES[piece.k]
    local a = pd and pd.args[slot] or { t = "any" }
    local t = B():ArgType(piece, slot) or a.t
    if t ~= a.t then
        local c = {}
        for k, v in pairs(a) do c[k] = v end
        c.t, c.filter = t, true
        a = c
    end
    return a
end

OnBlank = function(piece, slot, blankFrame, button)
    if not CanEdit() then
        if button == "LeftButton" then Builder:SayReadOnly() end
        return
    end
    local loc = Locate(piece)
    if not loc then return end
    Builder:OpenPicker(loc.script, piece, slot, BlankArg(piece, slot), blankFrame)
end

-- A value in a blank was clicked (not dragged): the picker of the blank it sits in, to change it.
function Builder:TapValue(piece, frame)
    if not CanEdit() then return end
    local loc = Locate(piece)
    if not loc or not loc.parent then return end
    local slot = type(loc.field) == "number" and loc.field or (loc.field == "j" and loc.slot)
    if not slot then return end
    self:OpenPicker(loc.script, loc.parent, slot, BlankArg(loc.parent, slot), frame)
end

function Builder:OpenPicker(script, piece, slot, a, blankFrame)
    local t = a.t
    if DROPDOWN[t] then
        UI():ContextMenu(blankFrame, function(root) self:DropdownChoices(root, piece, slot, a) end)
        return
    end
    local p = ui.picker or CreatePicker()
    S.pick = { script = script, piece = piece, slot = slot, a = a }
    p.title:SetText(PICK_TITLE[t] or "A value")
    p.sub:SetText(PickFor(piece, slot))
    local cur = piece.a[slot]
    local typed = TYPED[t]
    p.field:SetShown(typed)
    p.search:SetShown(not typed)
    if typed then
        local plain = (type(cur) == "string" or type(cur) == "number") and tostring(cur) or ""
        if type(cur) == "table" and cur.j then
            local parts = {}
            for _, x in ipairs(cur.j) do if type(x) == "string" then parts[#parts + 1] = x end end
            plain = table.concat(parts)
        end
        p.field:SetMaxLetters(t == "label" and (B().LIMITS.label or 24) or MAX_TEXT)
        p.field:SetText(plain)
        UI():SetEditPlaceholder(p.field, PICK_FIELD[t] or "Type, then Enter")
    else
        p.search:SetText("")
    end
    self:FillPicker("")
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", blankFrame, "BOTTOMLEFT", -6, -6)
    p:Show()
    p:Raise()
    -- (a hidden field takes no focus: once the picker shows)
    if typed then p.field:SetFocus() end
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
    -- (a value in the blank: its frame)
    local v = pk and pk.piece.a[pk.slot]
    if f and type(v) == "table" and v.k and f.at[v] then return f.at[v] end
    -- (a blank not drawn, a choice's empty second one: the piece it belongs to)
    return f and pk and f.at[pk.piece] or nil
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
        -- (inside the window when it can be: over the blank when there's no room under it, and room over it)
        local ws = win and win:GetEffectiveScale() or us
        local wb, wt = win and win:GetBottom(), win and win:GetTop()
        local floorY = max(0, wb and wb * ws or 0)
        local ceilY = min(sh, wt and wt * ws or sh)
        local below, above = b * bs - floorY, ceilY - t * bs
        up = below < ph and (above >= ph or above > below)
        local over = l * bs + dx * ps + pw - sw
        if over > 0 then dx = dx - over / ps end
        if l * bs + dx * ps < 0 then dx = -l * bs / ps end
        -- room neither under nor over it (a tall picker by a blank half way down): beside it, left of it when there's
        -- room there, held inside the window from top to bottom
        if below < ph and above < ph then
            local wl, wr = win and win:GetLeft(), win and win:GetRight()
            local left = l * bs - (wl and wl * ws or 0)
            local right = (wr and wr * ws or sw) - (bf:GetRight() or l) * bs
            local topY = min(ceilY - 8 * ps, max(floorY + ph + 8 * ps, t * bs + 12 * ps))
            local yoff = (topY - t * bs) / ps
            p:ClearAllPoints()
            if left >= pw + 8 * ps or left >= right then
                p:SetPoint("TOPRIGHT", bf, "TOPLEFT", -8, yoff)
            else
                p:SetPoint("TOPLEFT", bf, "TOPRIGHT", 8, yoff)
            end
            return
        end
    end
    p:ClearAllPoints()
    if up then
        p:SetPoint("BOTTOMLEFT", bf, "TOPLEFT", dx, 6)
    else
        p:SetPoint("TOPLEFT", bf, "BOTTOMLEFT", dx, -6)
    end
end

local PICK_ROWS = 9

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
    local d = Def()
    local list
    if t == "label" then
        list = {}
        for _, lab in ipairs(B():Labels(d)) do
            list[#list + 1] = { action = { lab, nil, function() Builder:PickTyped(lab) end }, section = "THIS EVENT'S BUTTONS" }
        end
    elseif WORDS_ONLY[t] then
        list = {}
    else
        list = Choices(pk.script, pk.piece, pk.slot, t)
    end
    query = string.lower(query or "")
    local y = 60
    local section, n, nh = nil, 0, 0
    local cur = pk.piece.a[pk.slot]
    for _, c in ipairs(list) do
        local label
        if c.piece then
            label = c.piece.k == "ctx" and B().CTX[c.piece.a[1]].label or (c.piece.k == "var" and c.piece.a[1])
                or (c.piece.k == "pl.tagged" and B():DefinitionName(d, "tags", c.piece.a[1]))
                or (B().PIECES[c.piece.k].text:gsub("{%d}", ""))
        elseif c.chip then
            label = B():DefinitionName(d, "places", c.chip[2])
        else
            label = c.action[1]
        end
        -- (the values up to PICK_ROWS: a search finds the rest; the new-place actions always)
        if (query == "" or string.lower(label):find(query, 1, true)) and (n < PICK_ROWS or c.action) then
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
                r.on = r:CreateTexture(nil, "BACKGROUND", nil, 1)
                r.on:SetAllPoints()
                r.on:SetColorTexture(1, 0.82, 0, 0.10)
                r.desc = Text(r, "GameFontHighlightSmall", 10.5)
                r.desc:SetTextColor(0.62, 0.62, 0.62)
                r.desc:SetJustifyH("RIGHT")
                r.desc:SetPoint("RIGHT", r, "RIGHT", -6, 0)
                r.icon = r:CreateTexture(nil, "ARTWORK")
                r.icon:SetSize(13, 13)
                r.icon:SetPoint("LEFT", r, "LEFT", 8, 0)
                r.label = Text(r, "GameFontHighlight", 11.5)
                r:SetScript("OnEnter", function(self) self.hl:Show() end)
                r:SetScript("OnLeave", function(self) self.hl:Hide() end)
                p.rows[n] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", p, "TOPLEFT", 6, -y)
            r:Show()
            r.icon:Hide()
            r.label:Hide()
            r.on:Hide()
            r.choice, r.chip, r.fn = nil, nil, nil
            r.desc:SetText(c.desc or "")
            if c.piece then
                r.draw = EP():Draw(r, c.piece, { def = d, static = true })
                r.draw:SetPoint("LEFT", r, "LEFT", 6, 0)
                r.draw:SetScale(0.92)
                r.choice = c.piece
                r:SetScript("OnClick", function(self) Builder:PickPiece(self.choice) end)
            elseif c.chip then
                r.draw = EP():DrawChip(r, c.chip[1], c.chip[2], { def = d, static = true })
                r.draw:SetPoint("LEFT", r, "LEFT", 6, 0)
                r.on:SetShown(cur == c.chip[2])
                r.chip = c.chip[2]
                r:SetScript("OnClick", function(self) Builder:PickValue(self.chip) end)
            else
                local icon = c.action[2]
                local x = 8
                if icon then
                    EUI():Glyph(r.icon, icon, 0.86, 0.86, 0.86)
                    r.icon:Show()
                    x = 28
                end
                r.label:ClearAllPoints()
                r.label:SetPoint("LEFT", r, "LEFT", x, 0)
                r.label:SetText(c.action[1])
                r.label:SetTextColor(0.91, 0.91, 0.91)
                r.label:Show()
                r.on:SetShown(cur ~= nil and cur == c.action[1])
                r.fn = c.action[3]
                r:SetScript("OnClick", function(self) if self.fn then self.fn() end end)
            end
            y = y + 26
        end
    end
    y = y + 6
    p.foot:ClearAllPoints()
    p.foot:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -y)
    local hint
    if t == "player" or t == "players" then hint = "Or drag any round player piece into the blank."
    elseif t == "bool" then hint = "Or drag a hexagon piece into the blank."
    elseif t == "place" then hint = pk.a.opt and "Empty: any place." or "Or drag a place value into the blank."
    elseif t == "where" then hint = "A place, or a player to measure to."
    elseif t == "label" then hint = "The button shows in the tracker with these words."
    elseif t == "item" then hint = pk.a.filter and "Empty: any item. Shift-click an item to put it here." or
        "Shift-click an item to put it here."
    elseif t == "creature" then hint = "Empty: any creature. The name as the game shows it."
    else hint = "Or drag a round piece into the blank." end
    p.foot:SetText(hint)
    y = y + max(18, floor((TextW(p.foot) / 228) + 1) * 14)
    if pk.piece.a[pk.slot] ~= nil then
        p.clear:ClearAllPoints()
        p.clear:SetPoint("TOPLEFT", p, "TOPLEFT", 12, -(y + 2))
        p.clear:SetText(pk.a.opt and "Any" or "Empty it")
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

-- A literal picked in the picker (a place's id).
function Builder:PickValue(v)
    local pk = S.pick
    if not pk then return end
    local before = Snapshot()
    pk.piece.a[pk.slot] = v
    ui.picker:Hide()
    S.pick = nil
    Changed(before)
end

function Builder:PickTyped(text)
    local pk = S.pick
    if not pk then return end
    local before = Snapshot()
    text = text or ""
    local t = pk.a.t
    if t == "num" then
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
    elseif WORDS_ONLY[t] then
        -- an item link (shift-click) or its id is kept as the id; a button's name and a creature's as typed
        local id = t == "item" and (tonumber(text:match("item:(%d+)")) or tonumber(text))
        local clean = Clean((text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1")),
            t == "label" and (B().LIMITS.label or 24) or 40)
        if id and id > 0 then
            pk.piece.a[pk.slot] = floor(id)
        elseif clean == "" then
            if t == "label" or not pk.a.opt then
                ui.picker.sub:SetText("|cffff8a7atype a name first|r")
                return
            end
            pk.piece.a[pk.slot] = nil
        else
            pk.piece.a[pk.slot] = clean
        end
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

-- A colour dot in menu text (a tag's colour).
local function DotText(c)
    c = c or { 1, 1, 1 }
    local function byte(v) return floor((v or 1) * 255 + 0.5) end
    return ("|T%s:10:10:0:0:64:64:0:64:0:64:%d:%d:%d|t"):format(EUI().MASK, byte(c[1]), byte(c[2]), byte(c[3]))
end
Defs.DotText = DotText

-- What a piece does when its words don't say all of it (its tooltip, on the canvas and in the palette).
Defs.TIPS = {
    ["ch.guild"] = { "Post in guild chat", "For the people who aren't in the event. Only the host's addon sends it: once "
        .. "every 10 seconds at most, 20 times an event. Everything else shows in the addon." },
    ["ch.show"] = { "Show", "A banner in the middle of their screen, in the event's look." },
    ["ch.tell"] = { "Tell", "A line in their tracker and its feed." },
    ["ch.moment"] = { "Add a moment", "A line in the board's feed and in the results." },
    ["ch.sound"] = { "Play a sound", "On the named players' own clients." },
    ["pl.touch"] = { "Touches", "A click on them up close (a /target macro doesn't count), a /point at them up close, or "
        .. "an emote at them up close: pick which at its end. Empty players: anyone." },
    ["pl.radar"] = { "Targets without clicking", "Their target became one of these without a click on them (a macro, a raid "
        .. "frame, Tab): to say only clicks count." },
    ["wo.plates"] = { "Hide friendly nameplates", "Back when the event ends, or when they leave it." },
    ["pc.warm"] = { "Warmer or colder", "\"warmer\", \"colder\" or \"the same\", since this piece last asked about the two." },
    ["pc.enter"] = { "Enters a place", "Places work in the open world, not in dungeons. Empty: any of the event's places." },
    ["pc.leave"] = { "Leaves a place", "Places work in the open world, not in dungeons. Empty: any of the event's places." },
    ["pc.point"] = { "Point", "The tracker's arrow shows them the way, until they're there or pointed elsewhere." },
    ["ev.happen"] = { "When an entrant ...", "Pick what happens. Kills, loots and fish can name one creature or item; "
        .. "empty means any." },
    ["lo.match"] = { "Matches", "Capitals and spaces don't count. Answers: a question's from its list, or \"a / b / c\"." },
    ["as.give"] = { "Give a button", "It shows in their tracker until it's taken back." },
    ["tm.since"] = { "Seconds since", "This stage started, or a timer was started." },
}

function Builder:PieceTip(key, owner, on)
    if not on then GameTooltip:Hide() return end
    local t = key and Defs.TIPS[key]
    if t and owner then Tip(owner, t[1], t[2]) end
end

-- A dropdown blank's choices (the event's definitions end with "+ New ...").
function Builder:DropdownChoices(root, piece, slot, a)
    local d = Def()
    local function set(v, also)
        local before = Snapshot()
        piece.a[slot] = v
        if also then also() end
        Changed(before)
    end
    local function radio(label, v, also)
        return root:CreateRadio(label, function() return piece.a[slot] == v end, function() set(v, also) end)
    end
    local plus = UI():AtlasIconText(UI().ICON.plus or 39, 12)
    local t = a.t
    local fslot = (t == "what" or t == "how") and (function()
        local pd = B().PIECES[piece.k]
        for j, x in ipairs(pd and pd.args or {}) do if x.t == "filter" and x.of == slot then return j end end
    end)()
    local function clearFilter() if fslot then piece.a[fslot] = nil end end
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
        root:CreateButton(plus .. " New badge", function() Builder:NewBadge(piece, slot) end)
    elseif t == "var" then
        for _, v in ipairs(d.vars or {}) do radio(v.n, v.n) end
        root:CreateDivider()
        root:CreateButton(plus .. " Make a variable", function()
            Builder:NewVariable(piece, slot)
        end)
    elseif t == "timer" or t == "since" then
        if t == "since" then radio("this stage started", "stage") end
        for _, n in ipairs(B():Timers(d)) do radio(n, n) end
        root:CreateDivider()
        root:CreateButton(plus .. " A new name", function()
            Builder:AskName("Timer name", "", function(name) set(name) end)
        end)
    elseif t == "tag" or t == "score" or t == "list" or t == "ask" then
        local kind = B().DEF_OF_TYPE[t]
        for _, e in ipairs(Defs:Ordered(d, kind)) do
            local label = e.n
            if kind == "tags" then label = DotText(B():TagColor(e.c)) .. " " .. e.n end
            radio(label, e.id)
        end
        root:CreateDivider()
        root:CreateButton(plus .. " New " .. B().DEF_KINDS[kind].label, function()
            Defs:Open(kind, nil, nil, { onSaved = function(id) set(id) end })
        end)
    elseif t == "what" then
        -- a choice with a second blank ("kills a creature"): any one, or one by name
        for _, h in ipairs(B().HAPPEN) do
            if h.filter then
                local sub = root:CreateButton(h.label)
                sub:CreateRadio("any " .. (h.any or ""):gsub("^an? ", ""), function()
                    return piece.a[slot] == h.key and (piece.a[fslot] == nil or piece.a[fslot] == "")
                end, function() set(h.key, clearFilter) end)
                if h.filter == "emote" then
                    for _, e in ipairs(B().EMOTES) do
                        sub:CreateRadio(e[2], function() return piece.a[slot] == h.key and piece.a[fslot] == e[1] end,
                            function() set(h.key, function() piece.a[fslot] = e[1] end) end)
                    end
                else
                    sub:CreateButton(h.filter == "item" and "One item by name..." or "One creature by name...", function()
                        if piece.a[slot] ~= h.key then set(h.key, clearFilter) end
                        Builder:OpenFilter(piece, fslot)
                    end)
                end
            else
                radio(h.label, h.key, clearFilter)
            end
        end
    elseif t == "how" then
        for _, h in ipairs(B().TOUCH) do
            if h.filter == "emote" then
                local sub = root:CreateButton(h.label)
                sub:CreateRadio("any emote", function()
                    return piece.a[slot] == h.key and (piece.a[fslot] == nil or piece.a[fslot] == "")
                end, function() set(h.key, clearFilter) end)
                for _, e in ipairs(B().EMOTES) do
                    sub:CreateRadio(e[2], function() return piece.a[slot] == h.key and piece.a[fslot] == e[1] end,
                        function() set(h.key, function() piece.a[fslot] = e[1] end) end)
                end
            else
                radio(h.label, h.key, clearFilter)
            end
        end
    elseif t == "emote" then
        if a.opt then radio("any emote", nil) end
        for _, e in ipairs(B().EMOTES) do radio(e[2], e[1]) end
    elseif t == "sound" then
        for _, s in ipairs(B().SOUNDS) do
            root:CreateRadio(s[2], function() return piece.a[slot] == s[1] end, function()
                set(s[1])
                -- (a moment of it, here only)
                local kit = SOUNDKIT and SOUNDKIT[s[3]] or s[4]
                if PlaySound and kit then pcall(PlaySound, kit, "Master") end
            end)
        end
    elseif t == "state" then
        for _, s in ipairs(B().STATES) do radio(s[2], s[1]) end
    end
end

-- The typed second blank of a choice ("kills {Hogger}"): the picker on it, under its piece.
function Builder:OpenFilter(piece, fslot)
    if not (piece and fslot) then return end
    local loc = Locate(piece)
    if not loc then return end
    local f = ui.scripts[loc.script]
    local anchor = f and f.at[piece] or ui.cv
    self:OpenPicker(loc.script, piece, fslot, BlankArg(piece, fslot), anchor)
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
    -- (tidied: from the top-left, at the largest zoom step that shows all of it, clear of the overview)
    for _, z in ipairs({ 1, 0.9, 0.8, 0.67, 0.5 }) do
        if self:FitsAt(z) or z == 0.5 then
            MoveView(0, 0, z)
            break
        end
    end
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

-- What the drawn scripts, cards and notes cover ({ x, y, w, h } in content units), piece by piece: a C piece is its
-- header, its arm, its else bar and its foot, so a script's narrow foot may sit beside the overview.
local function DrawnRects()
    local out = {}
    local Ep = EP()
    for s, f in pairs(ui.scripts) do
        for _, pf in pairs(f.at or {}) do
            if pf.kind == "piece" and pf:IsShown() then
                local px, py = Ep:Abs(pf)
                local x, y = s.x + px, s.y + py
                local w, h = pf:GetWidth() or 0, pf:GetHeight() or 0
                if pf.headW then
                    out[#out + 1] = { x, y, pf.headW, pf.headH }
                    out[#out + 1] = { x, y + pf.headH, Ep.ARM, h - pf.headH }
                    if pf.midY then out[#out + 1] = { x, y + pf.midY, Ep.FOOT_W, Ep.MID } end
                    out[#out + 1] = { x, y + h - Ep.FOOT, Ep.FOOT_W, Ep.FOOT }
                else
                    out[#out + 1] = { x, y, w, h }
                end
            end
        end
    end
    local d = Def()
    for bid, card in pairs(ui.cards) do
        local b = d.blocks[bid]
        if card:IsShown() and b then out[#out + 1] = { b.x, b.y, 318, card:GetHeight() or 240 } end
    end
    for _, n in ipairs(ui.notes) do
        local nd = n:IsShown() and n.index and d.notes and d.notes[n.index]
        if nd then out[#out + 1] = { nd.x, nd.y, 170, 70 } end
    end
    return out
end

-- The parts of the canvas its own controls cover (canvas units): the overview, the zoom bar with the status pill
-- left of it, the ribbon inside a smart block.
local function ControlRects()
    local cw, ch = CanvasSize()
    local st = ui.status:IsShown() and ((ui.status:GetWidth() or 140) + 10) or 0
    local out = {
        { cw - 10 - 132, ch - 10 - 24 - 6 - 82, 132, 82 },
        { cw - 10 - 130 - st, ch - 10 - 24, 130 + st, 24 },
    }
    if S.inside then out[#out + 1] = { 0, 0, cw, 12 + 44 + 8 } end
    return out
end

-- Does all of the view show at zoom z (the view at its top-left), clear of the canvas' own controls?
function Builder:FitsAt(z)
    local cw, ch = CanvasSize()
    local W, H = cw / z, ch / z
    local ctl = {}
    for _, r in ipairs(ControlRects()) do ctl[#ctl + 1] = { r[1] / z, r[2] / z, r[3] / z, r[4] / z } end
    for _, r in ipairs(DrawnRects()) do
        if r[1] < 0 or r[2] < 0 or r[1] + r[3] > W - 4 or r[2] + r[4] > H - 4 then return false end
        for _, c in ipairs(ctl) do
            if r[1] < c[1] + c[3] and c[1] < r[1] + r[3] and r[2] < c[2] + c[4] and c[2] < r[2] + r[4] then return false end
        end
    end
    return true
end

-- A view seen for the first time opens at 100%, or a step or two out when what's on it would run past the canvas or
-- under its controls at 100% (a busy stage): the largest step where all of it shows (none: 100%, zoom to fit is there).
local FIT_STEPS = { 1, 0.9, 0.8, 0.67 }
OpenFitted = function(v)
    if v.seen or S.practice then return end
    v.seen = true
    if v.x ~= 0 or v.y ~= 0 or v.z ~= 1 then return end
    for _, z in ipairs(FIT_STEPS) do
        if Builder:FitsAt(z) then
            if z ~= 1 then
                v.z = z
                ApplyView()
                Builder:RenderOverview()
            end
            return
        end
    end
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

-- Loads an example (B:Examples' key) into the event: its stages, pieces, smart blocks and definitions (the name too
-- while it is still "New event"). One step undo takes back.
local function LoadExample(d, ex)
    for _, k in ipairs({ "stages", "scripts", "blocks", "vars", "badges", "notes", "tags", "scores", "places", "lists", "asks" }) do
        d[k] = ex[k]
    end
    d.stages = d.stages or { { id = "s1", name = "Main" } }
    d.scripts, d.blocks, d.vars, d.badges, d.notes = d.scripts or {}, d.blocks or {}, d.vars or {}, d.badges or {}, d.notes or {}
    if d.name == "New event" or (d.name or "") == "" then d.name = ex.name end
    d.icon, d.art = ex.icon, ex.art
    S.stage = d.stages[1].id
    S.views = {}
end

function Builder:UseExample(key)
    if not CanEdit() then self:SayReadOnly() return end
    local ex = B():Example(key)
    if not ex then return end
    local before = Snapshot()
    LoadExample(Def(), ex)
    Defs:Close()
    Changed(before)
end

-- A new event made from an example (the Library's Examples menu): as "Start from" makes it, but closing it untouched
-- keeps nothing (like a new event). False: no such example.
function Builder:OpenExample(key)
    local ex = B():Example(key)
    if not ex then return false end
    if not self:Open(nil) then return false end
    LoadExample(Def(), ex)
    S.fresh = FullHash(Def())
    Refresh()
    return true
end

-- The Friday duel cup (part 1's "Start from the Friday duel cup").
function Builder:UseStarter() self:UseExample("duel") end

-- The examples' cards on a new event's empty stage ("Start from an example"): art, icon, name, what it's made of.
function Builder:RenderStartFrom(show)
    local sf = ui.start
    if not show then
        if sf then sf:Hide() end
        return
    end
    if not sf then
        sf = CreateFrame("Frame", nil, ui.cv)
        sf:SetAllPoints(ui.cv)
        sf:SetFrameLevel(ui.cv:GetFrameLevel() + 800)
        sf.box = CreateFrame("Frame", nil, sf)
        sf.box.bg = sf.box:CreateTexture(nil, "BACKGROUND")
        sf.box.bg:SetAllPoints()
        sf.box.bg:SetColorTexture(1, 1, 1, 0.02)
        EUI():Edge(sf.box, 1, 1, 1, 0.14)
        sf.t = Text(sf, "GameFontHighlight", 15)
        sf.t:SetJustifyH("CENTER")
        sf.t:SetText("Start from an example")
        sf.t2 = Text(sf, "GameFontHighlightSmall", 11.5)
        sf.t2:SetJustifyH("CENTER")
        sf.t2:SetWordWrap(true)
        sf.t2:SetTextColor(0.62, 0.62, 0.62)
        sf.cards = {}
        ui.start = sf
        -- (the examples' words and art, once: their events are made when one is picked)
        Defs.examples = {}
        for _, e in ipairs(B():Examples()) do
            Defs.examples[#Defs.examples + 1] = { key = e.key, name = e.name, icon = e.icon, art = e.art, desc = e.desc }
        end
    end
    local cw, ch = CanvasSize()
    local side = 44
    local gw = cw - 2 * side
    local cols = 4
    local cardW = floor((gw - (cols - 1) * 8) / cols)
    sf.t2:SetWidth(gw)
    sf.t2:SetText("Each one shows a few blocks at work. Change anything after, or drag a \"when\" piece here to start from nothing.")
    -- every card as tall as the tallest one's words
    local cardH = 104
    for i, e in ipairs(Defs.examples) do
        local c = sf.cards[i]
        if not c then
            c = CreateFrame("Button", nil, sf)
            c.bg = c:CreateTexture(nil, "BACKGROUND")
            c.bg:SetAllPoints()
            c.bg:SetColorTexture(0.102, 0.102, 0.122, 1)
            c.art = c:CreateTexture(nil, "BORDER")
            c.art:SetPoint("TOPLEFT", c, "TOPLEFT", 1, -1)
            c.art:SetPoint("TOPRIGHT", c, "TOPRIGHT", -1, -1)
            c.art:SetHeight(44)
            c.fade = c:CreateTexture(nil, "BORDER", nil, 1)
            c.fade:SetPoint("BOTTOMLEFT", c.art, "BOTTOMLEFT")
            c.fade:SetPoint("BOTTOMRIGHT", c.art, "BOTTOMRIGHT")
            c.fade:SetHeight(33)
            c.fade:SetTexture(WHITE)
            EUI():Gradient(c.fade, "VERTICAL", 0.102, 0.102, 0.122, 1, 0)
            c.iconE = c:CreateTexture(nil, "ARTWORK", nil, 1)
            c.iconE:SetColorTexture(0, 0, 0, 1)
            c.iconE:SetSize(30, 30)
            c.iconE:SetPoint("TOPLEFT", c, "TOPLEFT", 9, -25)
            c.icon = c:CreateTexture(nil, "ARTWORK", nil, 2)
            c.icon:SetSize(28, 28)
            c.icon:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -26)
            c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            c.n = Text(c, "GameFontHighlight", 12)
            c.n:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -58)
            c.a = Text(c, "GameFontHighlightSmall", 10)
            c.a:SetTextColor(0.62, 0.62, 0.62)
            c.a:SetWordWrap(true)
            c.a:SetPoint("TOPLEFT", c.n, "BOTTOMLEFT", 0, -2)
            UI():AddEdges(c)
            c:SetScript("OnEnter", function(self) UI():SetEdgeColor(self, 1, 0.82, 0, 0.6) end)
            c:SetScript("OnLeave", function(self) UI():SetEdgeColor(self, 0.34, 0.34, 0.38, 0.55) end)
            c:SetScript("OnClick", function(self) Builder:UseExample(self.key) end)
            sf.cards[i] = c
        end
        c.key = e.key
        c:SetSize(cardW, cardH)
        UI():SetEdgeColor(c, 0.34, 0.34, 0.38, 0.55)
        EUI():SetArt(c.art, e.art, cardW - 2, 44, nil, nil, 0.6)
        c.icon:SetTexture(e.icon)
        -- a long name a little smaller, and on two lines if it must (never cut)
        Sized(c.n, 12)
        c.n:SetWordWrap(false)
        c.n:SetWidth(cardW - 20)
        c.n:SetText(e.name)
        if TextW(c.n) > cardW - 20 then
            Sized(c.n, 11)
            if TextW(c.n) > cardW - 20 then c.n:SetWordWrap(true) end
            c.n:SetText(e.name)
        end
        c.a:SetWidth(cardW - 20)
        c.a:SetText(e.desc)
        local nh = max(15, floor((c.n:GetStringHeight() or 15) + 0.5))
        cardH = max(cardH, 58 + nh + 2 + floor((c.a:GetStringHeight() or 26) + 0.5) + 9)
    end
    local rows = math.ceil(#Defs.examples / cols)
    local t2h = max(14, floor((sf.t2:GetStringHeight() or 14) + 0.5))
    local total = 18 + 5 + t2h + 24 + rows * cardH + (rows - 1) * 8
    local top = max(40, floor((ch - 46 - total) / 2))
    sf.t:ClearAllPoints()
    sf.t:SetPoint("TOP", sf, "TOPLEFT", cw / 2, -top)
    sf.t2:ClearAllPoints()
    sf.t2:SetPoint("TOP", sf.t, "BOTTOM", 0, -5)
    local gy = top + 18 + 5 + t2h + 24
    -- (the box holds its words and cards, 24 around them: clear of the overview and the zoom bar under it)
    sf.box:ClearAllPoints()
    sf.box:SetPoint("TOPLEFT", sf, "TOPLEFT", side - 24, -(top - 24))
    sf.box:SetSize(gw + 48, total + 48)
    for i, c in ipairs(sf.cards) do
        local col, row = (i - 1) % cols, floor((i - 1) / cols)
        c:SetHeight(cardH)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", sf, "TOPLEFT", side + col * (cardW + 8), -(gy + row * (cardH + 8)))
        c:SetShown(i <= #Defs.examples)
    end
    sf:Show()
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
    self:CloseFloating()
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

local LOG_CAT = { say = "ch", whisper = "ch", warning = "ch", moment = "ch", show = "ch", tell = "ch", sound = "ch",
    guild = "ch", points = "pt", badge = "pt", var = "lo", list = "lo", stage = "sg", block = "ev", script = "ev",
    ask = "as", button = "as", tag = "pl", point = "pc", countdown = "tm", invite = "wo", mark = "wo", plates = "wo" }

-- What "Make something happen" can make happen in a practice run: key, words, what it needs ({ field, word, kind }:
-- a dummy, a typed name, an emote, a place, how, a button, an ask, an answer). Made once (EventBlocks' lists).
local function Facts()
    if Builder.facts then return Builder.facts end
    local who = { "who", "who", "dummy" }
    local out = { { key = "duel", label = "a duel ends", need = { { "w", "winner", "dummy" }, { "l", "loser", "dummy" } } } }
    for _, h in ipairs(B().HAPPEN) do
        local need = { who }
        if h.key == "duel" or h.key == "lose" then need[2] = { "other", "against", "dummy" }
        elseif h.key == "kill" then need[2] = { "name", "creature", "text", "any creature" }
        elseif h.key == "loot" or h.key == "fish" then need[2] = { "item", "item", "text", "any item" }
        elseif h.key == "emote" then need[2] = { "emote", "emote", "emote" }; need[3] = { "other", "at", "dummy" } end
        out[#out + 1] = { key = "h:" .. h.key, label = h.label, what = h.key, need = need }
    end
    out[#out + 1] = { key = "enter", label = "enters a place", need = { who, { "place", "place", "place" } } }
    out[#out + 1] = { key = "leave", label = "leaves a place", need = { who, { "place", "place", "place" } } }
    out[#out + 1] = { key = "touch", label = "touches someone", need = { who, { "whom", "touches", "dummy" }, { "how", "by", "how" } } }
    out[#out + 1] = { key = "radar", label = "targets someone without clicking", need = { who, { "whom", "targets", "dummy" } } }
    out[#out + 1] = { key = "press", label = "presses a button", need = { who, { "label", "button", "label" } } }
    out[#out + 1] = { key = "answer", label = "answers an ask", need = { who, { "ask", "ask", "ask" }, { "ans", "answer", "ans" } } }
    Builder.facts = out
    return out
end

local function FactOf(key)
    for _, f in ipairs(Facts()) do if f.key == key then return f end end
    return Facts()[1]
end

-- The facts the practised event listens for (its "when" pieces): those come first in the menu.
local function UsedFacts(d)
    local used = {}
    if #B():BlocksOf(d, "bracket") > 0 then used.duel = true end
    local HAT = { ["pc.enter"] = "enter", ["pc.leave"] = "leave", ["pl.touch"] = "touch", ["pl.radar"] = "radar",
        ["as.press"] = "press", ["as.on"] = "answer", ["as.closed"] = "answer" }
    B():EachScript(d, function(s)
        local top = s.top
        if type(top) ~= "table" then return end
        if top.k == "ev.happen" and top.a then used["h:" .. tostring(top.a[1])] = true end
        if HAT[top.k] then used[HAT[top.k]] = true end
    end)
    return used
end

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
        return h, r, ln
    end
    dp.h1, dp.h1r, dp.h1ln = head("Playing now", 8)
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
    -- a WC3-style sentence: [what happens], then who, to whom, where ... and Do it
    dp.kind = UI():CreateSleekMenuButton(dp, "", PAL_W - 20, function(root) Builder:FactMenu(root) end, 22)
    dp.params = {}
    for i = 1, 4 do
        local r = {}
        r.lab = Text(dp, "GameFontHighlightSmall", 11)
        r.lab:SetTextColor(0.82, 0.82, 0.82)
        r.dd = UI():CreateSleekMenuButton(dp, "", 128, function(root) Builder:ParamMenu(root, i) end, 21)
        r.eb = UI():CreateSleekEditBox(dp, 128, 21, "GameFontHighlightSmall")
        r.eb:SetMaxLetters(40)
        r.eb:SetScript("OnTextChanged", function(self, user)
            local p = dp.params[i]
            if user and p.field then S.happen[p.field] = self:GetText() end
        end)
        r.eb:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            Builder:Happen()
        end)
        r.eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        dp.params[i] = r
    end
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
    lg.bg:SetColorTexture(0.039, 0.039, 0.051, 1)
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

-- The fact's menu: what the event listens for first, the rest after.
function Builder:FactMenu(root)
    local run = L():GetPractice()
    local used = run and UsedFacts(run.def) or {}
    local function pick(f)
        root:CreateRadio(f.label, function() return S.happen.kind == f.key end, function()
            S.happen.kind = f.key
            Builder:RenderPractice()
        end)
    end
    local rest = {}
    for _, f in ipairs(Facts()) do
        if used[f.key] then pick(f) else rest[#rest + 1] = f end
    end
    if #rest == #Facts() then
        for _, f in ipairs(rest) do pick(f) end
        return
    end
    root:CreateDivider()
    local sub = root:CreateButton("Something else")
    for _, f in ipairs(rest) do
        sub:CreateRadio(f.label, function() return S.happen.kind == f.key end, function()
            S.happen.kind = f.key
            Builder:RenderPractice()
        end)
    end
end

-- A part of the fact's sentence: its choices (a dummy, an emote, a place, how, a button, an ask, an answer).
function Builder:ParamMenu(root, i)
    local p = ui.dp.params[i]
    local field, kind = p.field, p.kind
    if not field then return end
    local h = S.happen
    local run = L():GetPractice()
    if not run then return end
    local d = run.def
    local function radio(label, v)
        root:CreateRadio(label, function() return h[field] == v end, function()
            h[field] = v
            Builder:RenderPractice()
        end)
    end
    if kind == "dummy" then
        if field == "other" then radio("nobody", nil) end
        for _, k in ipairs(run.st.entrants or {}) do radio(L().DisplayName(k), k) end
        if root.SetScrollMode then root:SetScrollMode(20 * 16) end
    elseif kind == "emote" then
        for _, e in ipairs(B().EMOTES) do radio(e[2], e[1]) end
    elseif kind == "place" then
        for _, e in ipairs(Defs:Ordered(d, "places")) do radio(e.n, e.id) end
    elseif kind == "how" then
        for _, t in ipairs(B().TOUCH) do radio(t.label, t.key) end
    elseif kind == "label" then
        for _, lab in ipairs(B():Labels(d)) do radio(lab, lab) end
    elseif kind == "ask" then
        for _, e in ipairs(Defs:Ordered(d, "asks")) do radio(e.n, e.id) end
    elseif kind == "ans" then
        local a = h.ask and B():Definition(d, "asks", h.ask)
        local ak = a and a.kind or "player"
        if ak == "player" then
            for _, k in ipairs(run.st.entrants or {}) do radio(L().DisplayName(k), k) end
            if root.SetScrollMode then root:SetScrollMode(20 * 16) end
        elseif ak == "choice" then
            for _, c in ipairs(a.choices or {}) do radio(c, c) end
        elseif ak == "yesno" then
            radio("yes", true)
            radio("no", false)
        elseif ak == "number" then
            for n = 1, 10 do radio(tostring(n), n) end
        end
    end
end

-- Does the fact the panel shows, to the dummies (EventLive's practice inputs; each guarded: the live layer says
-- what it can).
function Builder:Happen()
    S.happen = S.happen or { kind = "duel" }
    local h = S.happen
    local f = FactOf(h.kind)
    local Lv = L()
    local run = Lv:GetPractice()
    if not run then return end
    local function call(name, ...)
        if type(Lv[name]) ~= "function" then
            ns:Print("practice can't do that yet (%s).", name)
            return false
        end
        Lv[name](Lv, ...)
        return true
    end
    for _, n in ipairs(f.need) do
        local v = h[n[1]]
        if n[3] ~= "text" and n[1] ~= "other" and v == nil then
            ns:Print("pick the %s first.", n[2])
            return
        end
    end
    if f.key == "duel" then
        if h.w == h.l then ns:Print("%s", "pick a winner and a loser: two dummies.") return end
        Lv:PracticeDuel(h.w, h.l)
    elseif f.what == "off" then
        Lv:PracticeOffline(h.who, true)
    elseif f.what == "on" then
        Lv:PracticeOffline(h.who, false)
    elseif f.what == "ready" then
        Lv:PracticeReady(h.who)
    elseif f.what then
        local data = { other = h.other, count = 1 }
        if f.what == "kill" then
            local n = Clean(h.name or "", 40)
            data.creature = n ~= "" and n or "Practice dummy"
        elseif f.what == "loot" or f.what == "fish" then
            local it = Clean(h.item or "", 40)
            local id = tonumber(it:match("item:(%d+)")) or tonumber(it)
            if id then data.item = id else data.name = it ~= "" and it or (f.what == "fish" and "Fish" or "Item") end
        elseif f.what == "emote" then
            data.emote = h.emote or "WAVE"
        end
        call("PracticeHappen", h.who, f.what, data)
    elseif f.key == "enter" or f.key == "leave" then
        -- (someone only leaves a place they're in, and enters one they're not in: the run takes the change)
        local set = type(run.st.inplace) == "table" and run.st.inplace[h.place]
        local inside = type(set) == "table" and set[h.who] and true or false
        if inside == (f.key == "enter") then
            ns:Print("%s is %s %s already.", EUI():Plain(h.who), inside and "in" or "out of",
                B():DefinitionName(run.def, "places", h.place))
            return
        end
        call("PracticePlace", h.who, h.place, f.key == "enter")
    elseif f.key == "touch" then
        if h.who == h.whom then ns:Print("%s", "a dummy can't touch itself: pick another.") return end
        call("PracticeTouch", h.who, h.whom, h.how or "click", h.how == "emote" and (h.emote or "WAVE") or nil)
    elseif f.key == "radar" then
        if h.who == h.whom then ns:Print("%s", "pick another dummy to target.") return end
        call("PracticeRadar", h.who, h.whom)
    elseif f.key == "press" then
        call("PracticePress", h.who, h.label)
    elseif f.key == "answer" then
        local v = h.ans
        local a = B():Definition(run.def, "asks", h.ask)
        if a and a.kind == "text" then v = Clean(h.answer or "", 120) end
        if v == nil or v == "" then ns:Print("%s", "give the answer first.") return end
        call("PracticeAnswer", h.who, h.ask, v)
    end
end

-- The fact's sentence under its menu: a row a part (its word, its dropdown or field), Do it at the end. Returns y.
local function RenderFact(dp, run, y)
    local st = run.st
    local h = S.happen
    local f = FactOf(h.kind)
    h.kind = f.key
    dp.kind:SetText(f.label)
    local d = run.def
    -- defaults: the first dummies, the event's first place / button / ask
    local e1, e2 = st.entrants[1], st.entrants[2]
    h.w, h.l = h.w or e1, h.l or e2
    h.who, h.whom = h.who or e1, h.whom or e2
    if not (h.place and B():Definition(d, "places", h.place)) then
        local pl = Defs:Ordered(d, "places")[1]
        h.place = pl and pl.id
    end
    local labels = B():Labels(d)
    local known = false
    for _, lab in ipairs(labels) do if lab == h.label then known = true end end
    if not known then h.label = labels[1] end
    if not (h.ask and B():Definition(d, "asks", h.ask)) then
        local a = Defs:Ordered(d, "asks")[1]
        h.ask = a and a.id
        h.ans = nil
    end
    h.how = h.how or "click"
    h.emote = h.emote or "WAVE"
    local need = f.need
    -- touch by an emote: which one
    if f.key == "touch" and h.how == "emote" then need = { need[1], need[2], need[3], { "emote", "emote", "emote" } } end
    local ask = h.ask and B():Definition(d, "asks", h.ask)
    local rows = {}
    for i, r in ipairs(dp.params) do
        local n = need[i]
        if n and f.key == "answer" and n[1] == "ans" and ask and ask.kind == "text" then n = { "answer", "answer", "text", "type it" } end
        r.lab:Hide()
        r.dd:Hide()
        r.eb:Hide()
        r.field, r.kind = nil, nil
        if n then
            r.field, r.kind = n[1], n[3]
            r.lab:SetText(n[2])
            r.lab:Show()
            local ctl
            if n[3] == "text" then
                ctl = r.eb
                if not ctl:HasFocus() then ctl:SetText(h[n[1]] or "") end
                UI():SetEditPlaceholder(ctl, n[4] or "")
            else
                ctl = r.dd
                local v = h[n[1]]
                local label
                if n[3] == "dummy" then label = v and EUI():Plain(v) or "nobody"
                elseif n[3] == "emote" then for _, e in ipairs(B().EMOTES) do if e[1] == v then label = e[2] end end
                elseif n[3] == "place" then label = v and B():DefinitionName(d, "places", v) or "no places"
                elseif n[3] == "how" then label = B().TOUCH_BY[v] and B().TOUCH_BY[v].label
                elseif n[3] == "label" then label = v or "no buttons"
                elseif n[3] == "ask" then label = v and B():DefinitionName(d, "asks", v) or "no asks"
                elseif n[3] == "ans" then
                    if v == nil then label = "pick one"
                    elseif v == true then label = "yes" elseif v == false then label = "no"
                    elseif type(v) == "string" and v:find("%-") then label = EUI():Plain(v)
                    else label = tostring(v) end
                end
                ctl:SetText(label or tostring(v or ""))
            end
            ctl:Show()
            rows[#rows + 1] = { lab = r.lab, ctl = ctl }
        end
    end
    -- a short fact reads as a sentence ("[a duel ends] winner [Dummy 7]" / "loser [Dummy 2] [Do it]"); a long one
    -- takes the whole width, its parts in rows under it
    local right = PAL_W - 10
    local kw = max(108, floor(TextW(dp.kind:GetFontString()) + 30 + 0.5))
    dp.kind:ClearAllPoints()
    dp.kind:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
    dp.doit:ClearAllPoints()
    if kw <= 140 then
        dp.kind:SetWidth(kw)
        local x, rowY = 10 + kw + 6, y
        for i, it in ipairs(rows) do
            local lw = TextW(it.lab)
            if i > 1 or x + lw + 6 + 84 > right then x, rowY = 10, rowY + 28 end
            it.lab:ClearAllPoints()
            it.lab:SetPoint("LEFT", dp, "TOPLEFT", x, -(rowY + 11))
            it.ctl:SetWidth(84)
            it.ctl:ClearAllPoints()
            it.ctl:SetPoint("TOPLEFT", dp, "TOPLEFT", x + lw + 6, -rowY)
            x = x + lw + 6 + 84 + 6
        end
        if x + 54 > right then x, rowY = 10, rowY + 28 end
        dp.doit:SetPoint("TOPLEFT", dp, "TOPLEFT", x, -rowY)
        return rowY + 28 + 8
    end
    dp.kind:SetWidth(PAL_W - 20)
    y = y + 28
    for _, it in ipairs(rows) do
        it.lab:ClearAllPoints()
        it.lab:SetPoint("LEFT", dp, "TOPLEFT", 10, -(y + 10))
        it.ctl:SetWidth(128)
        it.ctl:ClearAllPoints()
        it.ctl:SetPoint("TOPLEFT", dp, "TOPLEFT", 64, -y)
        y = y + 26
    end
    -- Do it, on the last row's right
    if #rows > 0 then
        dp.doit:SetPoint("TOPLEFT", dp, "TOPLEFT", 64 + 128 + 6, -(y - 26))
    else
        dp.doit:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
        y = y + 26
    end
    return y + 8
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
    -- playing now (an event with Matches)
    local playing = {}
    if bk then
        for _, mid in ipairs(bk.rounds[bk.r] or {}) do
            local m = bk.m[mid]
            if m.st == "play" then playing[#playing + 1] = m end
        end
    end
    dp.h1:SetShown(bk ~= nil)
    dp.h1r:SetShown(bk ~= nil)
    dp.h1ln:SetShown(bk ~= nil)
    dp.h1r:SetText(bk and EUI():StageSub(run.def, st) or "")
    local y = bk and 32 or 8
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
    if bk and #playing == 0 then
        dp.none:SetText(st.phase == "done" and "The event is over. Start again to run it once more."
            or "No match is being played: the event waits for its next step.")
        dp.none:ClearAllPoints()
        dp.none:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
        dp.none:Show()
        y = y + 34
    elseif not bk and st.phase == "done" then
        dp.none:SetText("The event is over. Start again to run it once more.")
        dp.none:ClearAllPoints()
        dp.none:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
        dp.none:Show()
        y = y + 34
    else
        dp.none:Hide()
    end
    if bk then y = y + 6 end
    dp.h2:ClearAllPoints()
    dp.h2:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -y)
    dp.h2ln:ClearAllPoints()
    dp.h2ln:SetPoint("TOPLEFT", dp, "TOPLEFT", 10, -(y + 18))
    dp.h2ln:SetPoint("TOPRIGHT", dp, "TOPRIGHT", -10, -(y + 18))
    y = y + 26
    S.happen = S.happen or { kind = "duel" }
    y = RenderFact(dp, run, y)
    -- the dummies (and the tags they have, as dots)
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
    local tagList = Defs:Ordered(run.def, "tags")
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
            b.dots = {}
            b:SetScript("OnClick", function(self)
                local _, pp = L():GetPractice()
                L():PracticeOffline(self.key, not (pp and pp.off[self.key]))
            end)
            b:SetScript("OnEnter", function(self) if self.tagTip then Tip(self, EUI():Plain(self.key), self.tagTip) end end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            dp.dummies[i] = b
        end
        b.key = key
        local off = p and p.off[key]
        EUI():SetClass(b.c, key)
        b.c:SetDesaturated(off and true or false)
        b.c:SetAlpha(off and 0.5 or 1)
        b.fs:SetText(off and ("|cff6f6f74" .. EUI():Plain(key) .. "|r") or EUI():Name(key))
        b.off:SetShown(off and true or false)
        -- its tags: a dot each after its name (their names in its tooltip)
        local nd, names = 0, {}
        for _, e in ipairs(tagList) do
            local has = not e.builtin and type(st.tags) == "table" and type(st.tags[e.id]) == "table" and st.tags[e.id][key]
            if has and nd < 3 and not off then
                nd = nd + 1
                local t = b.dots[nd] or b:CreateTexture(nil, "ARTWORK")
                b.dots[nd] = t
                t:SetTexture(EUI().MASK)
                t:SetSize(7, 7)
                local col = B():TagColor(e.c)
                t:SetVertexColor(col[1], col[2], col[3])
                t:ClearAllPoints()
                t:SetPoint("LEFT", b.fs, "RIGHT", 4 + (nd - 1) * 9, 0)
                t:Show()
            end
            if has then names[#names + 1] = e.n end
        end
        for k = nd + 1, #b.dots do b.dots[k]:Hide() end
        b.tagTip = #names > 0 and table.concat(names, ", ") or nil
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
            if e.kind == "say" or e.kind == "whisper" or e.kind == "warning" or e.kind == "guild" then
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
-- Definitions (tags, scores, places, lists, asks): their palette rows and their editors
---------------------------------------------------------------------------

Defs.HEAD = { tags = "Tags", scores = "Scores", places = "Places", lists = "Lists", asks = "Asks" }
Defs.ADD = { tags = "Add tag", scores = "Add score", places = "Add place", lists = "Add list", asks = "Add ask" }
Defs.CAT = { tags = "pl", scores = "pt", places = "pc", lists = "lo", asks = "as" }
Defs.ASK_WORD = { player = "pick a player", choice = "a choice", text = "typed", yesno = "yes or no", number = "1 to 10" }
Defs.SHOWN_WORD = { all = "everyone sees it", self = "only they see it", host = "only the host sees it" }
Defs.ICON = { num = "INV_Misc_PunchCards_Yellow", time = "INV_Misc_PocketWatch_01", gold = "INV_Misc_Coin_02",
    season = "INV_Misc_Coin_01", place = "INV_Misc_Map_01", question = "INV_Misc_Book_11", text = "INV_Misc_Note_02",
    ask = "INV_Misc_Ticket_Darkmoon_01" }
Defs.TEAL = { 0.34, 0.84, 0.94 }

local function VGrad(t, top, bottom)
    t:SetTexture(WHITE)
    if t.SetGradient and CreateColor then
        t:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
            CreateColor(top[1], top[2], top[3], top[4] or 1))
    else
        t:SetVertexColor((top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2, top[4] or 1)
    end
end

local function Plural(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- The window dimmed under a sheet (the map, the questions), and the clicks on it caught.
function Defs.Dim(on)
    local d = ui.dim
    if not d then
        if not on then return end
        d = CreateFrame("Frame", nil, win)
        d:SetFrameStrata("FULLSCREEN")
        d:SetFrameLevel(2)
        d:SetPoint("TOPLEFT", win.content or win, "TOPLEFT", 0, 0)
        d:SetPoint("BOTTOMRIGHT", win.content or win, "BOTTOMRIGHT", 0, 0)
        d:EnableMouse(true)
        d:EnableMouseWheel(true)
        d:SetScript("OnMouseWheel", function() end)
        d.t = d:CreateTexture(nil, "BACKGROUND")
        d.t:SetAllPoints()
        d.t:SetColorTexture(0, 0, 0, 0.6)
        ui.dim = d
    end
    d:SetShown(on or QSheet.cur ~= nil or MapSheet.cur ~= nil)
end

-- A definition's one line in the palette ("everyone sees it", "lower wins · a time", "Halaa · 600 yd").
function Defs:Sub(kind, e)
    if e.builtin then return kind == "tags" and "every entrant · built in" or "the season · built in" end
    if kind == "tags" then return self.SHOWN_WORD[e.shown or "all"] or self.SHOWN_WORD.all end
    if kind == "scores" then
        local s = e.high == false and "lower wins" or "higher wins"
        if e.fmt == "time" then s = s .. " · a time" elseif e.fmt == "gold" then s = s .. " · gold" end
        return s
    end
    if kind == "places" then return PlaceLine(e) end
    if kind == "lists" then
        local n = type(e.items) == "table" and #e.items or 0
        if n == 0 then return "empty" end
        if e.kind == "place" then return Plural(n, "place", "places") .. ", in order" end
        if e.kind == "question" then return Plural(n, "question", "questions") end
        return Plural(n, "text", "texts")
    end
    if kind == "asks" then
        local s = self.ASK_WORD[e.kind or "player"] or self.ASK_WORD.player
        return e.secret and (s .. " · secret") or s
    end
    return ""
end

-- The palette's order: as they were made (tg1, tg2 ...); the built-in tag (Entrants) last, the built-in score (Season
-- points, the one that counts for the season) first.
function Defs:Ordered(d, kind)
    local own = B():Defs(d, kind, true)
    local function num(id) return tonumber(tostring(id):match("(%d+)$")) or 0 end
    tsort(own, function(a, b)
        local na, nb = num(a.id), num(b.id)
        if na ~= nb then return na < nb end
        return tostring(a.id) < tostring(b.id)
    end)
    local out = {}
    local bi = {}
    for _, e in ipairs(B():Defs(d, kind)) do if e.builtin then bi[#bi + 1] = e end end
    if kind ~= "tags" then for _, e in ipairs(bi) do out[#out + 1] = e end end
    for _, e in ipairs(own) do out[#out + 1] = e end
    if kind == "tags" then for _, e in ipairs(bi) do out[#out + 1] = e end end
    return out
end

function Defs:IconOf(kind, e)
    local I = self.ICON
    if kind == "scores" then return "Interface\\Icons\\" .. (e.builtin and I.season or I[e.fmt or "num"] or I.num) end
    if kind == "lists" then return "Interface\\Icons\\" .. (I[e.kind or "text"] or I.text) end
    return "Interface\\Icons\\" .. I.ask
end

-- A definition's swatch on a row's three textures: a tag's colour, a place's ring, else an icon. x: its middle.
function Defs:Swatch(it, kind, e, x)
    local a, b, c = it.sw, it.sw2, it.sw3
    for _, t in ipairs({ a, b, c }) do
        t:ClearAllPoints()
        t:SetTexCoord(0, 1, 0, 1)
        t:SetVertexColor(1, 1, 1, 1)
        t:Hide()
    end
    x = x or 13
    local function put(t, tex, size, r, g, bl, al)
        t:SetTexture(tex)
        t:SetSize(size, size)
        t:SetPoint("CENTER", it, "LEFT", x, 0)
        t:SetVertexColor(r or 1, g or 1, bl or 1, al or 1)
        t:Show()
    end
    if kind == "tags" then
        local col = B():TagColor(e.c)
        put(a, EUI().MASK, 16, 0, 0, 0, 0.9)
        put(b, EUI().MASK, 14, col[1], col[2], col[3], 1)
    elseif kind == "places" then
        local T = self.TEAL
        put(a, EUI().MASK, 17, T[1], T[2], T[3], 0.13)
        put(b, EUI().RING, 18, T[1], T[2], T[3], 0.95)
        put(c, EUI().MASK, 4, 0.61, 0.94, 1, 1)
    else
        put(a, self:IconOf(kind, e), 18)
        a:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

-- Is this definition's editor open (its row lit)?
function Defs:IsOpen(kind, id)
    local cur = self.cur
    if cur and not cur.hold and cur.kind == kind and cur.id == id then return true end
    local ms = MapSheet.cur
    if kind == "places" and ms and ms.pid == id then return true end
    local qs = QSheet.cur
    return kind == "lists" and qs ~= nil and qs.lid == id
end

-- A definition's row in the palette: swatch, name, one line, the pencil while its editor is open. Returns its height.
function Defs:PaletteRow(it, kind, e)
    DefRowParts(it)
    self:Swatch(it, kind, e)
    local on = self:IsOpen(kind, e.id)
    it.sel:SetShown(on)
    it.bar:SetShown(on)
    it.pen:SetShown(on and not e.builtin)
    it.hov:Show()
    local x = 30
    local avail = PAL_LIST_W - x - (on and not e.builtin and 25 or 6)
    -- (a long name or line takes two lines: nothing is cut)
    it.nm:SetWordWrap(true)
    it.nm:SetWidth(avail)
    it.nm:SetText(e.n or "?")
    it.sb:SetWordWrap(true)
    it.sb:SetWidth(avail)
    it.sb:SetText(self:Sub(kind, e))
    local h1 = max(14, floor((it.nm:GetStringHeight() or 14) + 0.5))
    local h2 = max(13, floor((it.sb:GetStringHeight() or 13) + 0.5))
    local h = max(36, h1 + h2 + 10)
    it:SetSize(PAL_LIST_W, h)
    it.nm:ClearAllPoints()
    it.nm:SetPoint("TOPLEFT", it, "TOPLEFT", x, -floor((h - h1 - h2) / 2))
    it.sb:ClearAllPoints()
    it.sb:SetPoint("TOPLEFT", it.nm, "BOTTOMLEFT", 0, 0)
    it.nm:Show()
    it.sb:Show()
    it.kind, it.defId, it.builtin = kind, e.id, e.builtin
    it:SetScript("OnClick", function(self, button)
        if button == "RightButton" then Defs:RowMenu(self, self.kind, self.defId) return end
        Defs:RowClick(self.kind, self.defId, self)
    end)
    -- a tag dragged onto the canvas: "players with tag ..." (its chip)
    if kind == "tags" then
        it:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and CanEdit() then Builder:PressNew({ k = "pl.tagged", a = { self.defId } }, self) end
        end)
    end
    it:SetScript("OnEnter", function(self)
        if self.builtin then
            Tip(self, e.n, kind == "tags" and "Built in: everyone in the event has it. Drag it onto a players blank."
                or "Built in: the season's points (ranked events only), held to the season's cap.")
        end
    end)
    it:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return h
end

-- "+ Add tag" (Places: a menu, by standing there or on the map). Returns its height.
function Defs:AddRow(it, kind)
    DefRowParts(it)
    HideDefParts(it)
    it.plus:ClearAllPoints()
    it.plus:SetPoint("LEFT", it, "LEFT", 9, 0)
    EUI():Glyph(it.plus, UI().ICON.plus or 39, 0.86, 0.86, 0.86)
    it.plus:Show()
    it.fs:SetText(self.ADD[kind])
    it.fs:ClearAllPoints()
    it.fs:SetPoint("LEFT", it, "LEFT", 25, 0)
    it.fs:Show()
    local w = 25 + TextW(it.fs) + 10
    if kind == "places" then
        it.caret:ClearAllPoints()
        it.caret:SetPoint("LEFT", it, "LEFT", w - 4, 0)
        EUI():Glyph(it.caret, 14, 0.86, 0.86, 0.86)
        it.caret:Show()
        w = w + 12
    end
    UI():SetEdgeColor(it, 0.34, 0.34, 0.38, 0.9)
    it.bg:SetColorTexture(0.1, 0.1, 0.12, 0.92)
    it:SetSize(floor(w + 0.5), 24)
    it.kind = kind
    it:SetScript("OnClick", function(self, button)
        if button ~= "LeftButton" then return end
        if not CanEditDefs() then Builder:SayReadOnly() return end
        if self.kind == "places" then Defs:AddPlaceMenu(self) else Defs:Open(self.kind, nil, self) end
    end)
    return 24
end

function Defs:AddPlaceMenu(owner, onSaved)
    UI():ContextMenu(owner, function(root)
        root:CreateButton(UI():AtlasIconText(37, 12) .. " Set from where I stand", function()
            MapSheet:Open({ stand = true, onSaved = onSaved })
        end)
        root:CreateButton(UI():AtlasIconText(31, 12) .. " Pick on the map", function() MapSheet:Open({ onSaved = onSaved }) end)
    end)
end

function Defs:RowClick(kind, id, row)
    local e = B():Definition(Def(), kind, id)
    if not e then return end
    if e.builtin then
        Tip(row, e.n, kind == "tags" and "Built in: everyone in the event has it. It can't be changed."
            or "Built in: the season's points. It can't be changed.")
        return
    end
    if kind == "places" then
        MapSheet:Open({ pid = id })
    elseif kind == "lists" and e.kind == "question" then
        QSheet:Open(id)
    else
        self:Open(kind, id, row)
    end
end

function Defs:RowMenu(owner, kind, id)
    local e = B():Definition(Def(), kind, id)
    if not e or e.builtin then return end
    UI():ContextMenu(owner, function(root)
        root:CreateTitle(e.n)
        root:CreateButton(UI():AtlasIconText(16, 12) .. " Change it", function() Defs:RowClick(kind, id, owner) end)
        root:CreateDivider()
        root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete|r", function()
            Defs:Delete(kind, id)
        end)
    end)
end

-- Two of a kind with one name can't be told apart in a dropdown: why not, or nil.
function Defs:NameTaken(kind, name, except)
    local low = string.lower(name)
    for _, e in ipairs(B():Defs(Def(), kind)) do
        if e.id ~= except and string.lower(tostring(e.n or "")) == low then return "Name already used" end
    end
    return nil
end

-- Deletes a definition (asking first when pieces use it: they'll each say they need another). A place leaves the
-- lists of places too; an ask that picked from a tag picks from the entrants.
function Defs:Delete(kind, id, confirmed)
    if not CanEditDefs() then Builder:SayReadOnly() return end
    local d = Def()
    local e = B():Definition(d, kind, id)
    if not e or e.builtin then return end
    local uses = B():DefinitionUses(d, kind, id)
    if uses > 0 and not confirmed then
        Builder:Confirm("Delete " .. e.n .. "?", Plural(uses, "piece uses", "pieces use") .. " it: "
            .. (uses == 1 and "it" or "each") .. " will need another " .. B().DEF_KINDS[kind].label .. ".", "Delete",
            function() Defs:Delete(kind, id, true) end)
        return
    end
    local before = Snapshot()
    B():RemoveDefinition(d, kind, id)
    if kind == "places" then
        for _, l in pairs(d.lists or {}) do
            if type(l) == "table" and l.kind == "place" and type(l.items) == "table" then
                for i = #l.items, 1, -1 do if l.items[i] == id then tremove(l.items, i) end end
            end
        end
    elseif kind == "tags" then
        for _, a in pairs(d.asks or {}) do
            if type(a) == "table" and a.from == id then a.from = "entrants" end
        end
    end
    if self.cur and self.cur.kind == kind and self.cur.id == id then self:Close(true) end
    if kind == "places" and MapSheet.cur and MapSheet.cur.pid == id then MapSheet:Close(true) end
    if kind == "lists" and QSheet.cur and QSheet.cur.lid == id then QSheet:Close(true) end
    Changed(before)
end

-- A yes / no box over the window (a delete that pieces would feel): text, the danger button's word, fn on yes.
function Builder:Confirm(title, text, okText, fn)
    local f = ui.confirm
    if not f then
        f = CreateFrame("Frame", "DisasterZoneEventBuilderConfirm", win)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetSize(300, 100)
        f:EnableMouse(true)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetColorTexture(0.075, 0.075, 0.09, 0.985)
        EUI():Edge(f, 0.47, 0.47, 0.51, 0.75)
        f.title = Text(f, "GameFontNormal", 13)
        f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
        f.text = Text(f, "GameFontHighlightSmall", 11)
        f.text:SetWordWrap(true)
        f.text:SetWidth(276)
        f.text:SetTextColor(0.82, 0.82, 0.84)
        f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -7)
        f.ok = UI():CreateSleekButton(f, "Delete", 70, 22, function()
            f:Hide()
            if f.fn then f.fn() end
        end, "danger")
        f.ok:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 10)
        f.cancel = UI():CreateSleekButton(f, "Cancel", 70, 22, function() f:Hide() end)
        f.cancel:SetPoint("RIGHT", f.ok, "LEFT", -6, 0)
        ui.confirm = f
    end
    f.title:SetText(title)
    f.text:SetText(text or "")
    f.ok:SetText(okText or "Delete")
    f.ok:SetWidth(TextW(f.ok:GetFontString()) + 26)
    f.fn = fn
    f:SetHeight(12 + 16 + 7 + max(14, floor((f.text:GetStringHeight() or 14) + 0.5)) + 14 + 22 + 10)
    f:ClearAllPoints()
    f:SetPoint("CENTER", win, "CENTER", 0, 60)
    f:Show()
    f:Raise()
end

---------------------------------------------------------------------------
-- The editor: a popover next to its palette row (name first, the kind's fields, "N pieces use it", bin, Save)
---------------------------------------------------------------------------

local POP_W, POP_X = 272, 84          -- its width; where the controls start (12 + a 62 label + 10)
local POP_CTL = POP_W - POP_X - 12    -- the controls' width
local ASK_TIMES = { 15, 30, 45, 60, 120, 180, 300, 600 }
local CAPS = { num = { 5, 10, 20, 50, 100, 1000 }, time = { 60, 300, 600, 1800, 3600 }, gold = { 10000, 100000, 1000000 } }

-- A row of a form: its label (grey, left) and the space for its controls.
local function FormRow(form, label, h)
    local r = CreateFrame("Frame", nil, form)
    r:SetSize(POP_W - 24, h or 24)
    r.lab = Text(r, "GameFontHighlightSmall", 11)
    r.lab:SetTextColor(0.62, 0.62, 0.62)
    r.lab:SetPoint("LEFT", r, "TOPLEFT", 0, -12)
    r.lab:SetText(label or "")
    form.rows[#form.rows + 1] = r
    return r
end

-- Buttons side by side, one chosen (Higher / Lower ...): seg:Set(value).
local function Segmented(parent, choices, onPick)
    local seg = CreateFrame("Frame", nil, parent)
    seg:SetSize(10, 22)
    seg.buttons = {}
    local x = 0
    for i, c in ipairs(choices) do
        local b = UI():CreateSleekButton(seg, c[2], 40, 22, function()
            if not CanEditDefs() then Builder:SayReadOnly() return end
            onPick(c[1])
        end)
        Sized(b:GetFontString(), 11.5)
        b:SetWidth(floor(TextW(b:GetFontString()) + 18 + 0.5))
        b:SetPoint("LEFT", seg, "LEFT", x, 0)
        x = x + b:GetWidth() - 1
        b.value = c[1]
        seg.buttons[i] = b
    end
    seg:SetWidth(x + 1)
    function seg:Set(v)
        for _, b in ipairs(self.buttons) do b:SetKind(b.value == v and "chosen" or "secondary") end
    end
    return seg
end

-- A switch with its words after it.
local function SwitchWords(parent, onSet)
    local sw = UI():CreateSwitch(parent, nil, function(on)
        if not CanEditDefs() then Builder:SayReadOnly() return end
        onSet(on)
    end)
    sw.words = Text(parent, "GameFontHighlightSmall", 11)
    sw.words:SetTextColor(0.62, 0.62, 0.62)
    sw.words:SetPoint("LEFT", sw, "RIGHT", 8, 0)
    return sw
end

-- Chips with a cross each (an ask's choices, a question's answers, a list's texts) and a field to add one:
-- box:Set(list) shows them, onChange(list) when one goes or comes. Wraps inside width; box.h its height.
local function ChipBox(parent, width, maxN, maxLen, onChange, addWord)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(width, 22)
    box.chips = {}
    box.list = {}
    box.add = UI():CreateSleekEditBox(box, 70, 20, "GameFontHighlightSmall")
    box.add:SetMaxLetters(maxLen)
    UI():SetEditPlaceholder(box.add, addWord or "Add", "GameFontDisableSmall")
    box.add:SetScript("OnEnterPressed", function(self)
        local t = Clean(self:GetText(), maxLen)
        if not CanEditDefs() then Builder:SayReadOnly() return end
        if t ~= "" then
            if #box.list >= maxN then
                ns:Print("%d at most.", maxN)
            else
                box.list[#box.list + 1] = t
                self:SetText("")
                onChange(box.list)
            end
        end
        self:SetFocus()
    end)
    box.add:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    function box:Set(list)
        self.list = list or {}
        for _, c in ipairs(self.chips) do c:Hide() end
        local x, y = 0, 0
        local rowH = 20
        for i, s in ipairs(self.list) do
            local c = self.chips[i]
            if not c then
                c = CreateFrame("Button", nil, self)
                c:SetHeight(20)
                UI():AddPillShape(c, 20)
                c.fs = Text(c, "GameFontHighlightSmall", 11)
                c.fs:SetPoint("LEFT", c, "LEFT", 8, 0)
                c.x = Text(c, "GameFontHighlightSmall", 12)
                c.x:SetText("\195\151")
                c.x:SetTextColor(0.75, 0.75, 0.78)
                c.x:SetPoint("RIGHT", c, "RIGHT", -7, 1)
                c:SetScript("OnEnter", function(cc) cc.x:SetTextColor(1, 1, 1) end)
                c:SetScript("OnLeave", function(cc) cc.x:SetTextColor(0.75, 0.75, 0.78) end)
                c:SetScript("OnClick", function(cc)
                    if not CanEditDefs() then Builder:SayReadOnly() return end
                    tremove(box.list, cc.index)
                    onChange(box.list)
                end)
                self.chips[i] = c
            end
            c.index = i
            c:SetPillColors({ 0.11, 0.11, 0.13, 1 }, { 1, 1, 1, 0.22 })
            c.fs:SetWordWrap(false)
            Sized(c.fs, 11)
            c.fs:SetText(s)
            -- (a long one: smaller, then on two lines in a taller chip; never past the box)
            local room = width - 8 - 6 - 9 - 7
            if TextW(c.fs) > room then Sized(c.fs, 10) end
            local tall = TextW(c.fs) > room
            local ch = tall and 32 or 20
            if tall then
                if not c.tall then
                    c.tall = CreateFrame("Frame", nil, c)
                    c.tall:SetAllPoints()
                    c.tall:SetFrameLevel(max(0, c:GetFrameLevel() - 1))
                    UI():AddPillShape(c.tall, 32)
                    c.tall:SetPillColors({ 0.11, 0.11, 0.13, 1 }, { 1, 1, 1, 0.22 })
                end
                c.fs:SetWordWrap(true)
                c.fs:SetWidth(room)
                c.fs:SetText(s)
            else
                c.fs:SetWidth(max(1, TextW(c.fs) + 2))
            end
            if c.tall then c.tall:SetShown(tall) end
            for _, t in ipairs(c.pillEdge or {}) do t:SetShown(not tall) end
            for _, t in ipairs(c.pillFill or {}) do t:SetShown(not tall) end
            c:SetHeight(ch)
            local w = tall and width or min(width, 8 + TextW(c.fs) + 6 + 9 + 7)
            c:SetWidth(w)
            if x > 0 and x + w > width then x, y = 0, y + rowH + 4 end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", self, "TOPLEFT", x, -y)
            c:Show()
            rowH = (x == 0) and ch or max(rowH, ch)
            x = x + w + 4
        end
        local aw = 70
        local adding = #self.list < maxN
        if adding and x > 0 and x + aw > width then x, y, rowH = 0, y + rowH + 4, 20 end
        self.add:ClearAllPoints()
        self.add:SetPoint("TOPLEFT", self, "TOPLEFT", x, -y)
        self.add:SetShown(adding)
        self.h = y + rowH
        self:SetHeight(self.h)
    end
    return box
end

local function CreatePop()
    local f = CreateFrame("Frame", "DisasterZoneEventDefEditor", win)
    f:SetFrameStrata("DIALOG")
    f:SetWidth(POP_W)
    f:SetHeight(200)
    f:EnableMouse(true)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    VGrad(f.bg, { 0.11, 0.11, 0.129, 1 }, { 0.078, 0.078, 0.094, 1 })
    EUI():Edge(f, 0.47, 0.47, 0.51, 0.75)
    -- the pointer at its row (a turned square, half of it out of the left side)
    f.ptrE = f:CreateTexture(nil, "BORDER", nil, 1)
    f.ptrE:SetTexture(WHITE)
    f.ptrE:SetSize(12, 12)
    f.ptrE:SetVertexColor(0.47, 0.47, 0.51, 0.75)
    f.ptr = f:CreateTexture(nil, "BORDER", nil, 2)
    f.ptr:SetTexture(WHITE)
    f.ptr:SetSize(10, 10)
    f.ptr:SetVertexColor(0.106, 0.106, 0.125, 1)
    for _, t in ipairs({ f.ptr, f.ptrE }) do
        if t.SetRotation then t:SetRotation(math.pi / 4) end
    end
    f.title = Text(f, "GameFontNormal", 13)
    f.title:SetPoint("LEFT", f, "TOPLEFT", 12, -18)
    f.kind = Text(f, "GameFontHighlightSmall", 10.5)
    f.kind:SetTextColor(0.62, 0.62, 0.62)
    f.kind:SetPoint("BOTTOMLEFT", f.title, "BOTTOMRIGHT", 8, 0)
    f.x = CreateFrame("Button", nil, f)
    f.x:SetSize(20, 20)
    f.x:SetPoint("RIGHT", f, "TOPRIGHT", -8, -18)
    f.x.fs = Text(f.x, "GameFontHighlight", 16)
    f.x.fs:SetText("\195\151")
    f.x.fs:SetPoint("CENTER", 0, 1)
    f.x.fs:SetTextColor(0.66, 0.66, 0.68)
    f.x:SetScript("OnEnter", function(b) b.fs:SetTextColor(1, 1, 1) end)
    f.x:SetScript("OnLeave", function(b) b.fs:SetTextColor(0.66, 0.66, 0.68) end)
    f.x:SetScript("OnClick", function() Defs:Close() end)
    f.hd = f:CreateTexture(nil, "BORDER")
    f.hd:SetColorTexture(1, 1, 1, 0.07)
    f.hd:SetHeight(1)
    f.hd:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -36)
    f.hd:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -36)
    f.fd = f:CreateTexture(nil, "BORDER")
    f.fd:SetColorTexture(1, 1, 1, 0.07)
    f.fd:SetHeight(1)
    f.fd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 40)
    f.fd:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 40)
    f.save = UI():CreateSleekButton(f, "Save", 52, 22, function() Defs:Save() end, "primary")
    f.save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 9)
    f.bin = UI():CreateTipIconButton(f, 22, UI().ICON.trash, "Delete it", "Pieces that use it will each need another.",
        function() if Defs.cur and Defs.cur.id then Defs:Delete(Defs.cur.kind, Defs.cur.id) end end)
    f.bin:SetPoint("RIGHT", f.save, "LEFT", -6, 0)
    f.foot = Text(f, "GameFontHighlightSmall", 10.5)
    f.foot:SetTextColor(0.62, 0.62, 0.62)
    f.foot:SetPoint("LEFT", f, "BOTTOMLEFT", 12, 20)
    f.err = Text(f, "GameFontHighlightSmall", 10.5)
    f.err:SetTextColor(1, 0.54, 0.48)
    f.err:SetPoint("LEFT", f, "BOTTOMLEFT", 12, 20)
    f.forms = {}
    f:SetScript("OnHide", function() if Defs.cur and not Defs.cur.hold then Defs.cur = nil; Builder:RenderPalette() end end)
    f:Hide()
    ui.dpop = f
    return f
end

-- The tag form: name, colour, who sees it, how it looks.
local function TagForm(f)
    local form = CreateFrame("Frame", nil, f)
    form.rows = {}
    local w = function() return Defs.cur.work end
    local r = FormRow(form, "Name")
    form.name = UI():CreateSleekEditBox(r, POP_CTL, 24)
    form.name:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Colour")
    form.sws = {}
    for i, c in ipairs(B().TAG_COLORS) do
        local b = CreateFrame("Button", nil, r)
        b:SetSize(16, 16)
        b:SetPoint("LEFT", r, "LEFT", POP_X - 12 + (i - 1) * 20, 0)
        b.on = b:CreateTexture(nil, "BACKGROUND")
        b.on:SetTexture(EUI().MASK)
        b.on:SetSize(22, 22)
        b.on:SetPoint("CENTER")
        b.on:SetVertexColor(0.96, 0.93, 0.82)
        b.edge = b:CreateTexture(nil, "BORDER")
        b.edge:SetTexture(EUI().MASK)
        b.edge:SetSize(18, 18)
        b.edge:SetPoint("CENTER")
        b.edge:SetVertexColor(0, 0, 0, 1)
        b.fill = b:CreateTexture(nil, "ARTWORK")
        b.fill:SetTexture(EUI().MASK)
        b.fill:SetSize(16, 16)
        b.fill:SetPoint("CENTER")
        b.fill:SetVertexColor(c[3][1], c[3][2], c[3][3])
        b.key = c[1]
        b:SetScript("OnEnter", function(self) Tip(self, c[2]) end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function(self)
            if not CanEditDefs() then Builder:SayReadOnly() return end
            w().c = self.key
            form:Fill()
        end)
        form.sws[i] = b
    end
    r = FormRow(form, "Seen by")
    form.shown = Segmented(r, B().TAG_SHOWN, function(v) w().shown = v; form:Fill() end)
    form.shown:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Looks like")
    form.chip = CreateFrame("Frame", nil, r)
    form.chip:SetHeight(19)
    UI():AddPillShape(form.chip, 19)
    local pl = B().CAT.pl
    form.chip:SetPillColors({ pl.f2[1], pl.f2[2], pl.f2[3], 1 }, { pl.e[1], pl.e[2], pl.e[3], 0.85 })
    form.chip:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    form.chip.dotE = form.chip:CreateTexture(nil, "ARTWORK", nil, 1)
    form.chip.dotE:SetTexture(EUI().MASK)
    form.chip.dotE:SetSize(9, 9)
    form.chip.dotE:SetPoint("LEFT", form.chip, "LEFT", 7, 0)
    form.chip.dotE:SetVertexColor(0, 0, 0, 0.8)
    form.chip.dot = form.chip:CreateTexture(nil, "ARTWORK", nil, 2)
    form.chip.dot:SetTexture(EUI().MASK)
    form.chip.dot:SetSize(7, 7)
    form.chip.dot:SetPoint("LEFT", form.chip, "LEFT", 8, 0)
    form.chip.fs = Text(form.chip, "GameFontHighlight", 11)
    form.chip.fs:SetPoint("LEFT", form.chip, "LEFT", 20, 0)
    form.where = Text(r, "GameFontHighlightSmall", 11)
    form.where:SetTextColor(0.62, 0.62, 0.62)
    form.where:SetText("board, tracker")
    function form:Fill()
        local x = w()
        for _, b in ipairs(self.sws) do b.on:SetShown(b.key == (x.c or "blue")) end
        self.shown:Set(x.shown or "all")
        local col = B():TagColor(x.c)
        self.chip.dot:SetVertexColor(col[1], col[2], col[3])
        self.chip.fs:SetText(x.n ~= "" and x.n or "Tag")
        self.chip:SetWidth(20 + TextW(self.chip.fs) + 9)
        self.where:ClearAllPoints()
        self.where:SetPoint("LEFT", self.chip, "RIGHT", 7, 0)
    end
    return form
end

-- The score form: name, which way wins, how it counts, on the board, a cap.
local function ScoreForm(f)
    local form = CreateFrame("Frame", nil, f)
    form.rows = {}
    local w = function() return Defs.cur.work end
    local r = FormRow(form, "Name")
    form.name = UI():CreateSleekEditBox(r, POP_CTL, 24)
    form.name:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Wins")
    form.high = Segmented(r, { { true, "Higher" }, { false, "Lower" } }, function(v) w().high = v; form:Fill() end)
    form.high:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Counts")
    form.fmt = Segmented(r, B().SCORE_FMT, function(v)
        w().fmt = v
        w().cap = nil       -- (a cap in seconds isn't one in gold)
        form:Fill()
    end)
    form.fmt:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Board")
    form.board = SwitchWords(r, function(on) w().board = on; form:Fill() end)
    form.board:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Cap")
    form.cap = UI():CreateSleekMenuButton(r, "", 110, function(root)
        local x = w()
        root:CreateRadio("No cap", function() return not tonumber(x.cap) end, function()
            if not CanEditDefs() then Builder:SayReadOnly() return end
            x.cap = nil; form:Fill()
        end)
        for _, n in ipairs(CAPS[x.fmt or "num"] or CAPS.num) do
            root:CreateRadio(B():FormatScore({ scores = { _ = { fmt = x.fmt } } }, "_", n), function() return tonumber(x.cap) == n end,
                function()
                    if not CanEditDefs() then Builder:SayReadOnly() return end
                    x.cap = n; form:Fill()
                end)
        end
    end, 22)
    form.cap:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    function form:Fill()
        local x = w()
        self.high:Set(x.high ~= false)
        self.fmt:Set(x.fmt or "num")
        self.board:SetChecked(x.board and true or false)
        self.board.words:SetText(x.board and "and in the tracker" or "not shown")
        local cap = tonumber(x.cap)
        self.cap:SetText(cap and cap > 0 and B():FormatScore({ scores = { _ = { fmt = x.fmt } } }, "_", cap) or "No cap")
    end
    return form
end

-- The ask form: name, question, how it's answered, and what that needs (choices; who can be picked, votes, self),
-- time, secret.
local function AskForm(f)
    local form = CreateFrame("Frame", nil, f)
    form.rows = {}
    local w = function() return Defs.cur.work end
    local r = FormRow(form, "Name")
    form.name = UI():CreateSleekEditBox(r, POP_CTL, 24)
    form.name:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Question")
    form.q = UI():CreateSleekEditBox(r, POP_CTL, 24)
    form.q:SetMaxLetters(B().LIMITS.question or 120)
    form.q:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    UI():SetEditPlaceholder(form.q, "Or the piece gives it")
    form.q:SetScript("OnTextChanged", function(self, user) if user then w().q = self:GetText() end end)
    -- the kinds as chips that wrap (A player, A choice, Typed, Yes or no, 1 to 10)
    r = FormRow(form, "Answer", 50)
    form.kindRow = r
    form.kinds = {}
    for i, k in ipairs(B().ASK_KINDS) do
        local b = CreateFrame("Button", nil, r)
        b:SetHeight(22)
        UI():AddPillShape(b, 22)
        b.fs = Text(b, "GameFontHighlightSmall", 11)
        b.fs:SetPoint("CENTER")
        b.fs:SetText(k[2])
        b:SetWidth(TextW(b.fs) + 18)
        b.key = k[1]
        b:SetScript("OnClick", function(self)
            if not CanEditDefs() then Builder:SayReadOnly() return end
            w().kind = self.key
            form:Fill()
            Defs:Layout()
        end)
        form.kinds[i] = b
    end
    r = FormRow(form, "Choices", 22)
    form.choiceRow = r
    form.choices = ChipBox(r, POP_CTL, B().LIMITS.choices or 6, B().LIMITS.choice or 40, function(list)
        w().choices = list
        form:Fill()
        Defs:Layout()
    end)
    form.choices:SetPoint("TOPLEFT", r, "TOPLEFT", POP_X - 12, -1)
    r = FormRow(form, "From")
    form.fromRow = r
    form.from = UI():CreateSleekMenuButton(r, "", 150, function(root)
        local x = w()
        for _, e in ipairs(Defs:Ordered(Def(), "tags")) do
            local id = e.builtin and "entrants" or e.id
            root:CreateRadio(DotText(B():TagColor(e.c)) .. " " .. e.n, function() return (x.from or "entrants") == id end,
                function()
                    if not CanEditDefs() then Builder:SayReadOnly() return end
                    x.from = id; form:Fill()
                end)
        end
    end, 22)
    form.from:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Votes")
    form.votesRow = r
    form.votes = UI():CreateSleekMenuButton(r, "", 80, function(root)
        local x = w()
        for n = 1, 3 do
            root:CreateRadio(n .. " each", function() return (tonumber(x.votes) or 1) == n end, function()
                if not CanEditDefs() then Builder:SayReadOnly() return end
                x.votes = n; form:Fill()
            end)
        end
    end, 22)
    form.votes:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Self")
    form.selfRow = r
    form.self = SwitchWords(r, function(on) w().self = on; form:Fill() end)
    form.self:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Time")
    form.time = UI():CreateSleekMenuButton(r, "", 80, function(root)
        local x = w()
        for _, s in ipairs(ASK_TIMES) do
            root:CreateRadio(B():DurationText(s), function() return (tonumber(x.time) or 60) == s end, function()
                if not CanEditDefs() then Builder:SayReadOnly() return end
                x.time = s; form:Fill()
            end)
        end
    end, 22)
    form.time:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Secret")
    form.secret = SwitchWords(r, function(on) w().secret = on; form:Fill() end)
    form.secret:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    function form:Fill()
        local x = w()
        local kind = x.kind or "player"
        -- the kinds' chips, wrapping in the controls' width; the chosen one in the Ask colour
        local cx, cy = 0, 0
        for _, b in ipairs(self.kinds) do
            local bw = b:GetWidth()
            if cx > 0 and cx + bw > POP_CTL then cx, cy = 0, cy + 26 end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self.kindRow, "TOPLEFT", POP_X - 12 + cx, -cy - 1)
            cx = cx + bw + 4
            local on = b.key == kind
            if on then
                b:SetPillColors({ 0.66, 0.28, 0.42, 0.55 }, { 1, 0.67, 0.77, 0.9 })
                b.fs:SetTextColor(1, 1, 1)
            else
                b:SetPillColors({ 0.055, 0.055, 0.067, 0.9 }, { 0.34, 0.34, 0.38, 0.9 })
                b.fs:SetTextColor(0.82, 0.82, 0.82)
            end
        end
        self.kindRow:SetHeight(cy + 24)
        self.choiceRow:SetShown(kind == "choice")
        if kind == "choice" then
            self.choices:Set(x.choices or {})
            self.choiceRow:SetHeight(max(24, self.choices.h + 2))
        end
        self.fromRow:SetShown(kind == "player")
        self.votesRow:SetShown(kind == "player" or kind == "choice")
        self.selfRow:SetShown(kind == "player")
        local from = x.from or "entrants"
        self.from:SetText(from == "entrants" and "Entrants" or B():DefinitionName(Def(), "tags", from))
        self.votes:SetText((tonumber(x.votes) or 1) .. " each")
        self.self:SetChecked(x.self and true or false)
        self.self.words:SetText(x.self and "can pick themselves" or "can't pick themselves")
        self.time:SetText(B():DurationText(tonumber(x.time) or 60))
        self.secret:SetChecked(x.secret and true or false)
        self.secret.words:SetText(x.secret and "hidden until it closes" or "shown as they come")
    end
    return form
end

-- The list form: name, what it holds, its items (places in order, dragged by their grip; texts; questions in a sheet).
local LIST_ROWS = 10       -- items shown before the list scrolls
local function ListForm(f)
    local form = CreateFrame("Frame", nil, f)
    form.rows = {}
    local w = function() return Defs.cur.work end
    local r = FormRow(form, "Name")
    form.name = UI():CreateSleekEditBox(r, POP_CTL, 24)
    form.name:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    r = FormRow(form, "Holds")
    form.kind = Segmented(r, B().LIST_KINDS, function(v)
        local x = w()
        if (x.kind or "text") ~= v then
            if type(x.items) == "table" and #x.items > 0 then
                -- (texts aren't places: what it held goes; undo brings it back once saved, Close keeps it)
                ns:Print("%s", "a list holds one kind: its items go when it holds another.")
            end
            x.kind, x.items = v, {}
        end
        form:Fill()
        Defs:Layout()
    end)
    form.kind:SetPoint("LEFT", r, "LEFT", POP_X - 12, 0)
    -- the items: a scroll list (places: grip, number, chip; texts: chips)
    r = FormRow(form, "", 30)
    form.itemsRow = r
    r.lab:Hide()
    form.scroll = UI():CreateScrollFrame(r)
    form.scroll:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    form.scroll:SetSize(POP_W - 24 - 4, 30)
    form.child = CreateFrame("Frame", nil, form.scroll)
    form.child:SetSize(POP_W - 30, 10)
    form.scroll:SetScrollChild(form.child)
    form.items = {}
    form.texts = ChipBox(r, POP_W - 24, B().LIMITS.items or 40, 120, function(list)
        w().items = list
        form:Fill()
        Defs:Layout()
    end, "Add a text")
    form.texts:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    form.qline = Text(r, "GameFontHighlightSmall", 11)
    form.qline:SetTextColor(0.82, 0.82, 0.82)
    form.qline:SetPoint("LEFT", r, "LEFT", 0, 0)
    form.qbtn = UI():CreateSleekButton(r, "Edit questions", 110, 22, function() Defs:EditQuestions() end)
    form.qbtn:SetPoint("RIGHT", r, "RIGHT", 0, 0)
    -- add a place (the event's, or a new one), or pick a new one on the map
    r = FormRow(form, "", 24)
    form.addRow = r
    r.lab:Hide()
    form.addPlace = UI():CreateSleekButton(r, "Add place", 92, 22, function(self)
        if not CanEditDefs() then Builder:SayReadOnly() return end
        Defs:ListAddMenu(self)
    end)
    form.addPlace:SetPoint("LEFT", r, "LEFT", 0, 0)
    form.addPlace.plus = form.addPlace:CreateTexture(nil, "ARTWORK")
    form.addPlace.plus:SetSize(10, 10)
    EUI():Glyph(form.addPlace.plus, UI().ICON.plus or 39, 0.9, 0.9, 0.9)
    form.addPlace.plus:SetPoint("LEFT", form.addPlace, "LEFT", 9, 0)
    form.addPlace:GetFontString():ClearAllPoints()
    form.addPlace:GetFontString():SetPoint("LEFT", form.addPlace.plus, "RIGHT", 6, 0)
    form.addPlace:SetWidth(9 + 10 + 6 + TextW(form.addPlace:GetFontString()) + 10)
    form.onMap = UI():CreateSleekButton(r, "Pick on the map", 120, 22, function()
        if not CanEditDefs() then Builder:SayReadOnly() return end
        Defs:ListNewPlace(false)
    end)
    form.onMap.icon = form.onMap:CreateTexture(nil, "ARTWORK")
    form.onMap.icon:SetSize(11, 11)
    EUI():Glyph(form.onMap.icon, 31, 0.9, 0.9, 0.9)
    form.onMap.icon:SetPoint("LEFT", form.onMap, "LEFT", 9, 0)
    form.onMap:GetFontString():ClearAllPoints()
    form.onMap:GetFontString():SetPoint("LEFT", form.onMap.icon, "RIGHT", 6, 0)
    form.onMap:SetWidth(9 + 11 + 6 + TextW(form.onMap:GetFontString()) + 10)
    form.onMap:SetPoint("LEFT", form.addPlace, "RIGHT", 6, 0)
    -- moving a place in the route: its grip dragged up or down
    form:SetScript("OnUpdate", function(self)
        local dr = self.drag
        if not dr then return end
        if not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
            self.drag = nil
            if self.line then self.line:Hide() end
            if dr.to and dr.to ~= dr.from then
                local items = w().items
                local it = tremove(items, dr.from)
                tinsert(items, dr.to > dr.from and dr.to - 1 or dr.to, it)
                self:Fill()
            end
            return
        end
        local s = self.child:GetEffectiveScale()
        local _, cy = GetCursorPosition()
        local top = self.child:GetTop()
        if not top then return end
        local rel = top - cy / s
        local n = #w().items
        local to = max(1, min(n + 1, floor(rel / 24 + 0.5) + 1))
        dr.to = to
        self.line = self.line or self.child:CreateTexture(nil, "OVERLAY")
        self.line:SetColorTexture(1, 0.82, 0, 0.9)
        self.line:SetHeight(2)
        self.line:ClearAllPoints()
        self.line:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -((to - 1) * 24) + 1)
        self.line:SetWidth(POP_W - 40)
        self.line:Show()
    end)
    function form:Item(i)
        local it = self.items[i]
        if it then return it end
        it = CreateFrame("Button", nil, self.child)
        it:SetSize(POP_W - 32, 22)
        it:RegisterForClicks("RightButtonUp")
        it.grip = CreateFrame("Button", nil, it)
        it.grip:SetSize(12, 22)
        it.grip:SetPoint("LEFT", it, "LEFT", 0, 0)
        it.grip.dots = {}
        for d = 1, 6 do
            local t = it.grip:CreateTexture(nil, "ARTWORK")
            t:SetColorTexture(0.54, 0.54, 0.56, 0.9)
            t:SetSize(2, 2)
            t:SetPoint("TOPLEFT", it.grip, "TOPLEFT", 3 + ((d - 1) % 2) * 4, -6 - floor((d - 1) / 2) * 4)
        end
        it.grip:SetScript("OnEnter", function(g) Tip(g, "Drag to move it", "up or down the list.") end)
        it.grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
        it.grip:SetScript("OnMouseDown", function(g, button)
            if button ~= "LeftButton" then return end
            if not CanEditDefs() then Builder:SayReadOnly() return end
            self.drag = { from = g:GetParent().index }
        end)
        it.disc = it:CreateTexture(nil, "ARTWORK")
        it.disc:SetTexture(EUI().MASK)
        it.disc:SetSize(16, 16)
        it.disc:SetPoint("LEFT", it, "LEFT", 19, 0)
        it.num = Text(it, "GameFontHighlightSmall", 9.5)
        it.num:SetJustifyH("CENTER")
        it.num:SetPoint("CENTER", it.disc, "CENTER", 0, 0)
        it.num:SetShadowOffset(0, 0)
        it.x = CreateFrame("Button", nil, it)
        it.x:SetSize(16, 16)
        it.x:SetPoint("RIGHT", it, "RIGHT", -2, 0)
        it.x.fs = Text(it.x, "GameFontHighlightSmall", 12)
        it.x.fs:SetText("\195\151")
        it.x.fs:SetPoint("CENTER", 0, 1)
        it.x.fs:SetTextColor(0.66, 0.66, 0.68)
        it.x:SetScript("OnEnter", function(b) b.fs:SetTextColor(1, 1, 1); Tip(b, "Take it off the list") end)
        it.x:SetScript("OnLeave", function(b) b.fs:SetTextColor(0.66, 0.66, 0.68); GameTooltip:Hide() end)
        it.x:SetScript("OnClick", function(b)
            if not CanEditDefs() then Builder:SayReadOnly() return end
            tremove(w().items, b:GetParent().index)
            self:Fill()
            Defs:Layout()
        end)
        it:SetScript("OnClick", function(row)
            local items = w().items
            local i0 = row.index
            UI():ContextMenu(row, function(root)
                if i0 > 1 then root:CreateButton("Move up", function() items[i0], items[i0 - 1] = items[i0 - 1], items[i0]; self:Fill() end) end
                if i0 < #items then root:CreateButton("Move down", function() items[i0], items[i0 + 1] = items[i0 + 1], items[i0]; self:Fill() end) end
                root:CreateButton("Take it off the list", function() tremove(items, i0); self:Fill(); Defs:Layout() end)
            end)
        end)
        self.items[i] = it
        return it
    end
    function form:Fill()
        local x = w()
        local kind = x.kind or "text"
        x.items = type(x.items) == "table" and x.items or {}
        self.kind:Set(kind)
        for _, it in ipairs(self.items) do
            if it.chip then EP():Release(it.chip); it.chip = nil end
            it:Hide()
        end
        self.scroll:SetShown(kind == "place")
        self.texts:SetShown(kind == "text")
        self.qline:SetShown(kind == "question")
        self.qbtn:SetShown(kind == "question")
        self.addRow:SetShown(kind == "place")
        local h = 24
        if kind == "place" then
            local n = #x.items
            for i, pid in ipairs(x.items) do
                local it = self:Item(i)
                it.index = i
                it:ClearAllPoints()
                it:SetPoint("TOPLEFT", self.child, "TOPLEFT", 0, -(i - 1) * 24)
                it:Show()
                -- the places in the order they're walked, the last one (the finish) in gold
                local ends = n >= 2 and i == n
                it.num:SetText(ends and "F" or i)
                if ends then
                    it.disc:SetVertexColor(1, 0.82, 0)
                    it.num:SetTextColor(0.16, 0.11, 0)
                else
                    it.disc:SetVertexColor(Defs.TEAL[1], Defs.TEAL[2], Defs.TEAL[3])
                    it.num:SetTextColor(0.01, 0.16, 0.2)
                end
                if B():Definition(Def(), "places", pid) then
                    it.chip = EP():DrawChip(it, "place", pid, { def = Def(), static = true })
                    it.chip:SetPoint("LEFT", it, "LEFT", 41, 0)
                end
            end
            self.child:SetHeight(max(10, n * 24))
            h = max(1, min(n, LIST_ROWS)) * 24
            self.scroll:SetHeight(h)
            if n == 0 then
                self.qline:SetShown(true)
                self.qline:SetWordWrap(false)
                self.qline:SetWidth(POP_W - 24)
                self.qline:SetText("No places yet: add the first one.")
                h = 20
            end
        elseif kind == "text" then
            self.texts:Set(x.items)
            h = self.texts.h + 2
        else
            local n = #x.items
            self.qline:SetWordWrap(true)
            self.qline:SetWidth(POP_W - 24 - 120)
            self.qline:SetText(n == 0 and "No questions yet." or (Plural(n, "question", "questions") .. ", their right answers and points"))
            h = 30
        end
        self.itemsRow:SetHeight(h)
    end
    return form
end

local FORMS = { tags = TagForm, scores = ScoreForm, asks = AskForm, lists = ListForm }

-- Opens kind's editor for id (nil: a new one, not in the event until Save), next to its palette row (row: that row,
-- else the category's row is found: the palette shows that category). opts.onSaved(id) after Save.
function Defs:Open(kind, id, row, opts)
    if not FORMS[kind] then return end
    local d = Def()
    if id and not B():Definition(d, kind, id) then return end
    Builder:ClosePicker()
    QSheet:Close()
    local f = ui.dpop or CreatePop()
    -- the palette shows the category, the row is lit
    if S.cat ~= self.CAT[kind] or (S.search or "") ~= "" then
        S.cat = self.CAT[kind]
        S.search = ""
        if ui.search then ui.search:SetText("") end
    end
    local work
    if id then
        work = Copy(B():Definition(d, kind, id))
    else
        work = { n = "" }
        if kind == "tags" then work.c, work.shown = "blue", "all"
        elseif kind == "scores" then work.high, work.fmt, work.board = true, "num", true
        elseif kind == "lists" then work.kind, work.items = "text", {}
        elseif kind == "asks" then
            work.kind, work.q, work.from, work.votes, work.self, work.time, work.secret = "player", "", "entrants", 1, false, 60, false
        end
    end
    self.cur = { kind = kind, id = id, work = work, onSaved = opts and opts.onSaved }
    for k, form in pairs(f.forms) do form:Hide() end
    local form = f.forms[kind]
    if not form then
        form = FORMS[kind](f)
        form:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -36)
        form:SetWidth(POP_W)
        f.forms[kind] = form
        -- the name: the title follows it; Enter saves, Escape leaves it as it was
        form.name:SetMaxLetters(MAX_NAME)
        form.name:SetScript("OnTextChanged", function(self, user)
            if not Defs.cur then return end
            if user then Defs.cur.work.n = self:GetText() end
            f.title:SetText(self:GetText() ~= "" and self:GetText() or ("New " .. B().DEF_KINDS[Defs.cur.kind].label))
            f.err:SetText("")
            if form.Fill and user and Defs.cur.kind == "tags" then form:Fill() end
        end)
        form.name:SetScript("OnEnterPressed", function() Defs:Save() end)
        form.name:SetScript("OnEscapePressed", function() Defs:Close() end)
    end
    form:Show()
    f.kind:SetText(B().DEF_KINDS[kind].label)
    form.name:SetText(work.n or "")
    f.title:SetText((work.n and work.n ~= "") and work.n or ("New " .. B().DEF_KINDS[kind].label))
    form:Fill()
    if kind == "asks" then form.q:SetText(work.q or "") end
    f.err:SetText("")
    local editable = CanEditDefs()
    f.save:SetShown(editable)
    f.bin:SetShown(editable and id ~= nil)
    if not editable then
        f.foot:SetText("By " .. EUI():Plain(d.by) .. ": make a copy to change it")
    elseif id then
        local n = B():DefinitionUses(d, kind, id)
        f.foot:SetText(n == 0 and "No piece uses it yet" or (Plural(n, "piece uses", "pieces use") .. " it"))
    else
        f.foot:SetText("")
    end
    f:Show()
    f:Raise()
    Builder:RenderPalette()
    self:Layout()
    if editable and not id then form.name:SetFocus() end
end

-- The popover's height from its form, and its place next to the row (its pointer at the row's middle; inside the
-- builder's body).
function Defs:Layout()
    local f = ui.dpop
    local cur = self.cur
    if not (f and cur) then return end
    local form = f.forms[cur.kind]
    local y = 10
    for _, r in ipairs(form.rows) do
        if r:IsShown() then
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", form, "TOPLEFT", 12, -y)
            y = y + r:GetHeight() + 9
        end
    end
    form:SetHeight(y + 3)
    local h = 36 + y + 3 + 40
    f:SetHeight(h)
    -- the row it's for: where the palette drew it (its scroll list starts 38 below the palette's top)
    local pal = ui.pal
    local key = (cur.id and (cur.kind .. ":" .. tostring(cur.id))) or ("add:" .. cur.kind)
    local ry = pal and pal.rowY and pal.rowY[key]
    local palH = pal and pal:GetHeight() or 0
    if palH < 100 then palH = WIN_H - 31 - TOP_H end
    f:ClearAllPoints()
    if not ry then
        f:SetPoint("TOPLEFT", pal, "TOPRIGHT", 12, -8)
        f.ptr:Hide()
        f.ptrE:Hide()
        return
    end
    local off = pal.scroll.GetVerticalScroll and pal.scroll:GetVerticalScroll() or 0
    local mid = 38 + ry.y + ry.h / 2 - (tonumber(off) or 0)
    -- its pointer 24 below its top, at the row; inside the builder's body
    local top = max(6, min(mid - 24, palH - 6 - h))
    local ay = mid - top
    f:SetPoint("TOPLEFT", pal, "TOPRIGHT", 12, -top)
    local showPtr = ay >= 12 and ay <= h - 12 and mid >= 38 and mid <= palH
    f.ptr:SetShown(showPtr)
    f.ptrE:SetShown(showPtr)
    f.ptr:ClearAllPoints()
    f.ptr:SetPoint("CENTER", f, "TOPLEFT", 0, -ay)
    f.ptrE:ClearAllPoints()
    f.ptrE:SetPoint("CENTER", f, "TOPLEFT", -1, -ay)
end

function Defs:Close(saved)
    -- (hidden whether or not it shows: a frame hidden with its window would come back with it)
    if self.cur then self.cur.hold = nil end
    self.cur = nil
    if ui.dpop then ui.dpop:Hide() end
    if ui.pal and win and win:IsShown() then Builder:RenderPalette() end
end

function Defs:Err(text)
    if ui.dpop then
        ui.dpop.err:SetText(text)
        ui.dpop.foot:SetText("")
    end
end

-- Save: the editor's copy into the event (one step undo takes back).
function Defs:Save()
    local cur = self.cur
    if not cur then return end
    if not CanEditDefs() then Builder:SayReadOnly() return end
    local w = cur.work
    local name = Clean(w.n, MAX_NAME)
    if name == "" then self:Err("Type a name first") return end
    local taken = self:NameTaken(cur.kind, name, cur.id)
    if taken then self:Err(taken) return end
    w.n = name
    if cur.kind == "asks" then
        w.q = Clean(w.q, B().LIMITS.question or 120)
        if w.kind ~= "choice" then w.choices = nil end
    end
    if cur.kind == "lists" then
        local all, mine = 0, #(w.items or {})
        for lid, l in pairs(Def().lists or {}) do
            if lid ~= cur.id and type(l) == "table" and type(l.items) == "table" then all = all + #l.items end
        end
        local cap = B().LIMITS.allItems or 80
        if all + mine > cap then
            self:Err(("An event's lists hold %d items in all: %d left"):format(cap, max(0, cap - all)))
            return
        end
    end
    local d = Def()
    local before = Snapshot()
    local id = cur.id
    if id then
        d[cur.kind] = type(d[cur.kind]) == "table" and d[cur.kind] or {}
        d[cur.kind][id] = Copy(w)
    else
        id = B():NewDefinition(d, cur.kind, w)
        if not id then
            self:Err(("An event has %d %ss at most"):format(cur.kind == "places" and B().LIMITS.places or B().LIMITS.defs,
                B().DEF_KINDS[cur.kind].label))
            return
        end
    end
    local onSaved, kind, wasNew = cur.onSaved, cur.kind, cur.id == nil
    self:Close(true)
    Changed(before)
    if onSaved then onSaved(id) end
    -- a new list of questions: they're typed in their sheet
    if kind == "lists" and wasNew and w.kind == "question" then QSheet:Open(id) end
end

-- The list editor's "Add place": one of the event's places, or a new one (from where I stand, or on the map).
function Defs:ListAddMenu(owner)
    local cur = self.cur
    if not cur then return end
    UI():ContextMenu(owner, function(root)
        for _, e in ipairs(Defs:Ordered(Def(), "places")) do
            root:CreateButton(e.n, function()
                if #cur.work.items >= (B().LIMITS.items or 40) then ns:Print("a list holds %d items at most.", B().LIMITS.items or 40) return end
                tinsert(cur.work.items, e.id)
                ui.dpop.forms.lists:Fill()
                Defs:Layout()
            end)
        end
        if #B():Defs(Def(), "places") > 0 then root:CreateDivider() end
        root:CreateButton(UI():AtlasIconText(37, 12) .. " Set from where I stand", function() Defs:ListNewPlace(true) end)
        root:CreateButton(UI():AtlasIconText(31, 12) .. " Pick on the map", function() Defs:ListNewPlace(false) end)
    end)
end

-- A new place for the list being edited: the map sheet (the editor waits behind it), then it's the list's last.
function Defs:ListNewPlace(stand)
    local cur = self.cur
    if not cur then return end
    cur.hold = true
    ui.dpop:Hide()
    MapSheet:Open({ stand = stand, onSaved = function(pid)
        if Defs.cur == cur then tinsert(cur.work.items, pid) end
    end, onClosed = function()
        if Defs.cur == cur and ui.dpop then
            cur.hold = nil
            ui.dpop:Show()
            ui.dpop.forms.lists:Fill()
            Defs:Layout()
            Builder:RenderPalette()
        end
    end })
end

-- A list of questions: its sheet (the list saved first when it's new).
function Defs:EditQuestions()
    local cur = self.cur
    if not cur then return end
    if not cur.id then
        cur.work.kind = "question"
        self:Save()
        return
    end
    local id = cur.id
    self:Close()
    QSheet:Open(id)
end

---------------------------------------------------------------------------
-- The questions of a list: a wide sheet (question, right answers as chips, points)
---------------------------------------------------------------------------

local QS_W = 988
local QCOL = { n = 12, q = 40, a = 380, p = QS_W - 12 - 52 }     -- the columns' x

function QSheet:Create()
    local f = CreateFrame("Frame", "DisasterZoneEventQuestions", win)
    f:SetFrameStrata("FULLSCREEN")
    f:SetFrameLevel(20)
    f:SetSize(QS_W, 460)
    f:EnableMouse(true)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    VGrad(f.bg, { 0.11, 0.11, 0.129, 1 }, { 0.078, 0.078, 0.094, 1 })
    EUI():Edge(f, 0.47, 0.47, 0.51, 0.75)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(20, 20)
    f.icon:SetPoint("LEFT", f, "TOPLEFT", 12, -20)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- the list's name (it reads as the title; a click lets it be changed)
    f.name = CreateFrame("EditBox", nil, f)
    f.name:SetAutoFocus(false)
    f.name:SetFontObject("GameFontNormal")
    Sized(f.name, 14)
    f.name:SetSize(200, 24)
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 9, 0)
    f.name:SetMaxLetters(MAX_NAME)
    f.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.name:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    f.name:SetScript("OnTextChanged", function() QSheet:FitName() end)
    UI():AttachRestLabel(f.name)
    f.probe = Text(f, "GameFontNormal", 14)
    f.probe:Hide()
    f.sub = Text(f, "GameFontHighlightSmall", 11)
    f.sub:SetTextColor(0.62, 0.62, 0.62)
    f.x = CreateFrame("Button", nil, f)
    f.x:SetSize(20, 20)
    f.x:SetPoint("RIGHT", f, "TOPRIGHT", -10, -20)
    f.x.fs = Text(f.x, "GameFontHighlight", 17)
    f.x.fs:SetText("\195\151")
    f.x.fs:SetPoint("CENTER", 0, 1)
    f.x.fs:SetTextColor(0.66, 0.66, 0.68)
    f.x:SetScript("OnEnter", function(b) b.fs:SetTextColor(1, 1, 1); Tip(b, "Close", "Changes not kept: Done keeps them.") end)
    f.x:SetScript("OnLeave", function(b) b.fs:SetTextColor(0.66, 0.66, 0.68); GameTooltip:Hide() end)
    f.x:SetScript("OnClick", function() QSheet:Close() end)
    local function rule(y)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 1, 1, 0.07)
        t:SetHeight(1)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", 1, y)
        t:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, y)
        return t
    end
    rule(-40)
    -- the column heads
    local function head(text, x, right)
        local h = Text(f, "GameFontHighlightSmall", 10.5)
        h:SetTextColor(0.62, 0.62, 0.62)
        h:SetText(text)
        if right then h:SetPoint("RIGHT", f, "TOPRIGHT", -12, -52) else h:SetPoint("LEFT", f, "TOPLEFT", x, -52) end
        return h
    end
    head("Question", QCOL.q)
    head("Right answers", QCOL.a)
    head("Points", 0, true)
    rule(-64)
    f.scroll = UI():CreateScrollFrame(f)
    f.scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -64)
    f.scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 46)
    f.scroll:SetSize(QS_W - 4, 300)
    f.child = CreateFrame("Frame", nil, f.scroll)
    f.child:SetSize(QS_W - 6, 10)
    f.scroll:SetScrollChild(f.child)
    f.rows = {}
    f.foot = rule(-1)
    f.foot:ClearAllPoints()
    f.foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 46)
    f.foot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 46)
    f.note = Text(f, "GameFontHighlightSmall", 11)
    f.note:SetTextColor(0.62, 0.62, 0.62)
    f.note:SetPoint("LEFT", f, "BOTTOMLEFT", 12, 23)
    f.note:SetText("Answers count however they're spelled: capitals and spaces don't matter")
    f.done = UI():CreateSleekButton(f, "Done", 64, 24, function() QSheet:Done() end, "primary")
    f.done:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 11)
    f.add = UI():CreateSleekButton(f, "Add question", 120, 24, function() QSheet:AddQuestion() end)
    f.add.plus = f.add:CreateTexture(nil, "ARTWORK")
    f.add.plus:SetSize(10, 10)
    EUI():Glyph(f.add.plus, UI().ICON.plus or 39, 0.9, 0.9, 0.9)
    f.add.plus:SetPoint("LEFT", f.add, "LEFT", 11, 0)
    f.add:GetFontString():ClearAllPoints()
    f.add:GetFontString():SetPoint("LEFT", f.add.plus, "RIGHT", 7, 0)
    f.add:SetWidth(11 + 10 + 7 + TextW(f.add:GetFontString()) + 12)
    f.add:SetPoint("RIGHT", f.done, "LEFT", -6, 0)
    f.err = Text(f, "GameFontHighlightSmall", 11)
    f.err:SetTextColor(1, 0.54, 0.48)
    f.err:SetPoint("RIGHT", f.add, "LEFT", -12, 0)
    f:SetScript("OnShow", function() Defs.Dim(true) end)
    f:SetScript("OnHide", function()
        QSheet.cur = nil
        Defs.Dim(false)
        if win and win:IsShown() then Builder:RenderPalette() end
    end)
    f:Hide()
    ui.qsheet = f
    return f
end

function QSheet:Open(lid)
    local d = Def()
    local l = B():Definition(d, "lists", lid)
    if not l then return end
    Builder:ClosePicker()
    Defs:Close()
    local f = ui.qsheet or self:Create()
    local items = {}
    for _, it in ipairs(type(l.items) == "table" and l.items or {}) do
        if type(it) == "table" then items[#items + 1] = { q = it.q or "", a = Copy(it.a or {}), pts = tonumber(it.pts) or 1 } end
    end
    self.cur = { lid = lid, name = l.n, items = items }
    f.icon:SetTexture(d.icon or "Interface\\Icons\\INV_Misc_Book_11")
    f.name:SetText(l.n or "")
    self:FitName()
    f.err:SetText("")
    f.add:SetShown(CanEditDefs())
    f:ClearAllPoints()
    f:SetPoint("TOP", win.content or win, "TOP", 0, -20)
    f:Show()
    f:Raise()
    if #items == 0 and CanEditDefs() then self:AddQuestion() else self:Render() end
    Builder:RenderPalette()
end

function QSheet:Close()
    self.cur = nil
    if ui.qsheet then ui.qsheet:Hide() end
    Defs.Dim(false)
end

-- A question row: its number, the question, its answers as chips, its points. The one picked is edited in place.
function QSheet:Row(i)
    local f = ui.qsheet
    local r = f.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, f.child)
    r:SetSize(QS_W - 6, 30)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(1, 0.82, 0, 0.08)
    r.bar = r:CreateTexture(nil, "ARTWORK")
    r.bar:SetColorTexture(1, 0.82, 0)
    r.bar:SetWidth(2)
    r.bar:SetPoint("TOPLEFT")
    r.bar:SetPoint("BOTTOMLEFT")
    r.rule = r:CreateTexture(nil, "BORDER")
    r.rule:SetColorTexture(1, 1, 1, 0.05)
    r.rule:SetHeight(1)
    r.rule:SetPoint("BOTTOMLEFT")
    r.rule:SetPoint("BOTTOMRIGHT")
    r.hov = r:CreateTexture(nil, "HIGHLIGHT")
    r.hov:SetAllPoints()
    r.hov:SetColorTexture(1, 1, 1, 0.03)
    r.n = Text(r, "GameFontHighlightSmall", 12)
    r.n:SetJustifyH("RIGHT")
    r.n:SetWidth(18)
    r.q = Text(r, "GameFontHighlight", 11.5)
    r.q:SetWordWrap(true)
    r.q:SetWidth(QCOL.a - QCOL.q - 16)
    r.qe = UI():CreateSleekEditBox(r, QCOL.a - QCOL.q - 14, 24)
    r.qe:SetMaxLetters(B().LIMITS.question or 120)
    r.qe:SetScript("OnTextChanged", function(self, user)
        if user and QSheet.cur and QSheet.cur.items[r.index] then QSheet.cur.items[r.index].q = self:GetText() end
    end)
    r.qe:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    r.qe:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    r.chips = {}
    r.p = Text(r, "GameFontHighlight", 13)
    r.p:SetJustifyH("RIGHT")
    r.p:SetTextColor(1, 0.88, 0.54)
    r.pts = UI():CreateSleekMenuButton(r, "1", 46, function(root)
        for n = 1, 5 do
            root:CreateRadio(tostring(n), function() return (QSheet.cur.items[r.index].pts or 1) == n end, function()
                QSheet.cur.items[r.index].pts = n
                QSheet:Render()
            end)
        end
    end, 22)
    r.bin = UI():CreateTipIconButton(r, 20, UI().ICON.trash, "Delete the question", nil, function()
        if not CanEditDefs() then Builder:SayReadOnly() return end
        tremove(QSheet.cur.items, r.index)
        QSheet.cur.sel = nil
        QSheet:Render()
    end)
    r.box = ChipBox(r, QCOL.p - QCOL.a - 40, B().LIMITS.answers or 6, B().LIMITS.answer or 40, function(list)
        QSheet.cur.items[r.index].a = list
        QSheet:Render()
    end)
    r:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if not CanEditDefs() then return end
            UI():ContextMenu(self, function(root)
                root:CreateButton("|cffff8d80" .. UI():AtlasIconText(12, 12, { 1, 0.55, 0.5 }) .. " Delete the question|r", function()
                    tremove(QSheet.cur.items, self.index)
                    QSheet.cur.sel = nil
                    QSheet:Render()
                end)
            end)
            return
        end
        if not CanEditDefs() then Builder:SayReadOnly() return end
        QSheet.cur.sel = self.index
        QSheet:Render()
        self.qe:SetFocus()
    end)
    f.rows[i] = r
    return r
end

-- Read-only answer chips in a row (wrapping in their column).
local function AnswerChips(r, list, width)
    for _, c in ipairs(r.chips) do c:Hide() end
    local x, y = 0, 0
    for i, s in ipairs(list) do
        local c = r.chips[i]
        if not c then
            c = CreateFrame("Frame", nil, r)
            c:SetHeight(19)
            UI():AddPillShape(c, 19)
            c:SetPillColors({ 1, 1, 1, 0.04 }, { 1, 1, 1, 0.14 })
            c.fs = Text(c, "GameFontHighlightSmall", 10.5)
            c.fs:SetTextColor(0.85, 0.85, 0.85)
            c.fs:SetPoint("LEFT", c, "LEFT", 8, 0)
            r.chips[i] = c
        end
        c.fs:SetText(s)
        local w = min(width, TextW(c.fs) + 16)
        c:SetWidth(w)
        if x > 0 and x + w > width then x, y = 0, y + 23 end
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", r, "TOPLEFT", QCOL.a + x, -(6 + y))
        c:Show()
        x = x + w + 4
    end
    return y + 19
end

function QSheet:Render()
    local f, cur = ui.qsheet, self.cur
    if not (f and cur) then return end
    for _, r in ipairs(f.rows) do r:Hide() end
    local y = 0
    for i, it in ipairs(cur.items) do
        local r = self:Row(i)
        r.index = i
        local on = cur.sel == i
        r.sel:SetShown(on)
        r.bar:SetShown(on)
        r.n:SetText(i)
        r.n:SetTextColor(on and 1 or 0.44, on and 0.82 or 0.44, on and 0 or 0.46)
        r.q:SetShown(not on)
        r.qe:SetShown(on)
        r.p:SetShown(not on)
        r.pts:SetShown(on)
        r.bin:SetShown(on)
        r.box:SetShown(on)
        local h
        if on then
            if not r.qe:HasFocus() then r.qe:SetText(it.q or "") end
            for _, c in ipairs(r.chips) do c:Hide() end
            r.box:Set(it.a)
            r.pts:SetText(tostring(it.pts or 1))
            h = max(38, r.box.h + 16)
        else
            r.q:SetText(it.q ~= "" and it.q or "|cff8a8a90(no question yet)|r")
            local qh = max(14, floor((r.q:GetStringHeight() or 14) + 0.5))
            local ah = AnswerChips(r, it.a or {}, QCOL.p - QCOL.a - 12)
            r.p:SetText(tostring(it.pts or 1))
            h = max(30, qh + 16, ah + 11)
        end
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f.child, "TOPLEFT", 0, -y)
        r:Show()
        r.n:ClearAllPoints()
        r.n:SetPoint("RIGHT", r, "LEFT", QCOL.n + 18, 0)
        r.q:ClearAllPoints()
        r.q:SetPoint("LEFT", r, "LEFT", QCOL.q, 0)
        r.qe:ClearAllPoints()
        r.qe:SetPoint("LEFT", r, "LEFT", QCOL.q - 4, 0)
        r.box:ClearAllPoints()
        r.box:SetPoint("LEFT", r, "LEFT", QCOL.a, 0)
        r.p:ClearAllPoints()
        r.p:SetPoint("RIGHT", r, "RIGHT", -12, 0)
        r.pts:ClearAllPoints()
        r.pts:SetPoint("RIGHT", r, "RIGHT", -12, 0)
        r.bin:ClearAllPoints()
        r.bin:SetPoint("RIGHT", r.pts, "LEFT", -6, 0)
        y = y + h
    end
    f.child:SetHeight(max(10, y))
    -- the sheet grows with its questions, up to the window's room (then it scrolls)
    local room = ((win.content and win.content:GetHeight()) or (WIN_H - 31)) - 40
    if room < 200 then room = WIN_H - 31 - 40 end
    f:SetHeight(max(200, min(room, 64 + y + 46 + 8)))
    local d = Def()
    f.sub:SetText("a list of questions · " .. (d.name or ""))
    f.sub:ClearAllPoints()
    f.sub:SetPoint("LEFT", f.name, "RIGHT", 4, 0)
    self:FitName()
end

-- The list's name as wide as its words (it reads as the title; the line after it follows).
function QSheet:FitName()
    local f = ui.qsheet
    if not f then return end
    f.probe:SetText(f.name:GetText() or "")
    f.name:SetWidth(min(300, max(40, TextW(f.probe) + 8)))
end

function QSheet:AddQuestion()
    local cur = self.cur
    if not cur then return end
    if not CanEditDefs() then Builder:SayReadOnly() return end
    if #cur.items >= (B().LIMITS.items or 40) then
        ui.qsheet.err:SetText(("A list holds %d at most"):format(B().LIMITS.items or 40))
        return
    end
    cur.items[#cur.items + 1] = { q = "", a = {}, pts = 1 }
    cur.sel = #cur.items
    self:Render()
    local r = ui.qsheet.rows[cur.sel]
    if r then r.qe:SetFocus() end
    -- (the new one in view)
    local sc = ui.qsheet.scroll
    if sc.SetVerticalScroll and sc.GetVerticalScrollRange then sc:SetVerticalScroll(sc:GetVerticalScrollRange() or 0) end
end

-- Done: the questions into the list (empty ones dropped), the name as typed; one undo step.
function QSheet:Done()
    local cur, f = self.cur, ui.qsheet
    if not cur then return end
    if not CanEditDefs() then self:Close() return end
    local d = Def()
    local l = B():Definition(d, "lists", cur.lid)
    if not l then self:Close() return end
    local name = Clean(f.name:GetText(), MAX_NAME)
    if name == "" then f.err:SetText("Type the list's name first") return end
    local taken = Defs:NameTaken("lists", name, cur.lid)
    if taken then f.err:SetText(taken) return end
    local items = {}
    for _, it in ipairs(cur.items) do
        local q = Clean(it.q, B().LIMITS.question or 120)
        if q ~= "" then items[#items + 1] = { q = q, a = it.a or {}, pts = it.pts or 1 } end
    end
    local all = 0
    for lid, x in pairs(d.lists or {}) do
        if lid ~= cur.lid and type(x) == "table" and type(x.items) == "table" then all = all + #x.items end
    end
    local cap = B().LIMITS.allItems or 80
    if all + #items > cap then
        f.err:SetText(("An event's lists hold %d items in all: %d left"):format(cap, max(0, cap - all)))
        return
    end
    local before = Snapshot()
    l.n, l.kind, l.items = name, "question", items
    self:Close()
    Changed(before)
end

---------------------------------------------------------------------------
-- Places on a map: a zone's art from the game (C_Map's tiles), places as rings at their size, me as an arrow
---------------------------------------------------------------------------

local GOLD3 = { 1, 0.82, 0 }
local MS_W, MS_H = 848, 542            -- the map sheet
local MAP_W, MAP_H = 576, 384          -- its map (a zone's 1002 x 668 art fits it at 1x)
local ZOOMS_MAP = { 1, 1.5, 2, 3, 4, 6 }

-- A map's art layer (its size and tiles), or nil where the game doesn't say (UI/Comp/MapArt.lua).
function MapSheet.Layer(map)
    return ns.MapArt.Layer(map)
end

-- A map's size in yards (its whole width), from where its corners are in the world; nil where unknown.
function MapSheet.Yards(map)
    return (ns.MapArt.Yards(map))
end

function MapSheet.MapName(map)
    if not (C_Map and C_Map.GetMapInfo and tonumber(map)) then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, tonumber(map))
    return ok and type(info) == "table" and info.name or nil
end

-- Where I stand: { map, x, y, z, sz } or nil and why not (in an instance, or the game doesn't say).
function MapSheet.Here()
    local inside = IsInInstance and IsInInstance()
    if inside then return nil, "Places work in the open world, not in dungeons or raids: step outside and try again." end
    local pos
    local Sn = ns.EventSensors
    if Sn and Sn.MyPos then pos = Sn:MyPos() end
    if not pos and C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition then
        local map = C_Map.GetBestMapForUnit("player")
        local v = map and C_Map.GetPlayerMapPosition(map, "player")
        local x, y
        if type(v) == "table" and v.GetXY then x, y = v:GetXY() end
        if x and y then pos = { map = map, x = x, y = y } end
    end
    if not pos then return nil, "The game doesn't say where you are here: try again in the open world." end
    -- (the zone as its map names it: the same words the map sheet's zones have)
    local z = MapSheet.MapName(pos.map) or (GetZoneText and GetZoneText())
    local sz = GetSubZoneText and GetSubZoneText()
    pos.z = (z and z ~= "") and z or nil
    pos.sz = (sz and sz ~= "" and sz ~= pos.z) and sz or nil
    return pos
end

-- A map view: view:Set(map, cx, cy, zoom) draws the art around map point cx, cy (0..1); view:ToView(x, y) and
-- view:FromView(px, py) turn map points into the view's pixels (y down) and back; rings and labels drawn over it
-- between view:Begin() and view:Done().
function MapSheet.NewView(parent, w, h)
    -- (the events' shared zone map: the same art, rings and frame as the board's and the tracker's)
    local v = EUI():CreateZoneMap(parent, w, h)
    v.W, v.H = w, h
    v.ov = CreateFrame("Frame", nil, v)
    v.ov:SetAllPoints()
    v.ov:SetFrameLevel(v.canvas:GetFrameLevel() + 4)
    v.circles, v.lines, v.texs, v.fonts = {}, {}, {}, {}
    v.msg = Text(v.ov, "GameFontHighlight", 12)
    v.msg:SetWordWrap(true)
    v.msg:SetWidth(w - 60)
    v.msg:SetJustifyH("CENTER")
    v.msg:SetPoint("CENTER")
    v.msg:SetTextColor(0.85, 0.85, 0.85)
    v.msg:Hide()
    -- map point cx, cy (0..1) in the middle, zoom z (1: the whole zone)
    function v:Set(map, cx, cy, z)
        local art = self:SetMap(map)
        self.layer = art and self.L or nil
        local LW, LH = self:ArtSize()
        self.lw, self.lh = LW, LH
        self.z = z or 1
        local base = max(1, (self.W * LH) / (self.H * LW))
        local spanX = base / self.z
        local spanY = self.H * spanX * LW / (self.W * LH)
        local function fit(c, span)
            if span >= 1 then return (1 - span) / 2 end
            return max(0, min(1 - span, (c or 0.5) - span / 2))
        end
        self:SetView(fit(cx, spanX), fit(cy, spanY), spanX)
        self.cx, self.cy = self.x0 + spanX / 2, self.y0 + spanY / 2
        if not art then
            self.msg:SetText(self.map and "The game doesn't draw this zone's map here: set the place from where you stand."
                or "Pick a zone above, or set the place from where you stand.")
            self.msg:Show()
        else
            self.msg:Hide()
        end
        return art
    end
    function v:ToView(x, y) return self:P(x, y) end
    function v:FromView(px, py) return self.x0 + px / (self.lw * self.s), self.y0 + py / (self.lh * self.s) end
    -- pixels a yard (a guess of 4000 a zone where the game doesn't say)
    function v:PerYard() return self:Px(1) or (self.lw * self.s / 4000) end
    -- the cursor in the view (y down), and whether it's on it
    function v:Cursor()
        local l, t = self:GetLeft(), self:GetTop()
        if not l then return nil end
        local s = self:GetEffectiveScale()
        local x, y = GetCursorPosition()
        local px, py = x / s - l, t - y / s
        if px < 0 or py < 0 or px > self.W or py > self.H then return px, py, false end
        return px, py, true
    end
    function v:Begin() self.nc, self.nl, self.nt, self.nf = 0, 0, 0, 0 end
    function v:Line(x1, y1, x2, y2, c, a, thick, sub)
        self.nl = self.nl + 1
        local l = self.lines[self.nl]
        if not l then
            l = self.ov:CreateLine(nil, "ARTWORK")
            self.lines[self.nl] = l
        end
        l:SetDrawLayer("ARTWORK", sub or 2)
        l:SetThickness(thick)
        l:SetColorTexture(c[1], c[2], c[3], a)
        l:SetStartPoint("TOPLEFT", self.ov, x1, -y1)
        l:SetEndPoint("TOPLEFT", self.ov, x2, -y2)
        l:Show()
        return l
    end
    function v:Tex(path, x, y, size, c, a, sub)
        self.nt = self.nt + 1
        local t = self.texs[self.nt]
        if not t then
            t = self.ov:CreateTexture(nil, "ARTWORK")
            self.texs[self.nt] = t
        end
        t:SetDrawLayer("ARTWORK", sub or 1)
        t:SetTexture(path)
        t:SetTexCoord(0, 1, 0, 1)
        if t.SetRotation then t:SetRotation(0) end
        t:SetSize(size, size)
        t:ClearAllPoints()
        t:SetPoint("CENTER", self.ov, "TOPLEFT", x, -y)
        t:SetVertexColor(c[1], c[2], c[3], a or 1)
        t:Show()
        return t
    end
    function v:Label(text, x, y, c, anchor)
        self.nf = self.nf + 1
        local fs = self.fonts[self.nf]
        if not fs then
            fs = Text(self.ov, "GameFontHighlightSmall", 10.5)
            fs:SetShadowOffset(1, -1)
            fs:SetShadowColor(0, 0, 0, 1)
            self.fonts[self.nf] = fs
        end
        fs:SetText(text)
        fs:SetTextColor(c[1], c[2], c[3])
        fs:ClearAllPoints()
        fs:SetPoint(anchor or "CENTER", self.ov, "TOPLEFT", x, -y)
        fs:Show()
        return fs
    end
    -- a ring of radius r (pixels) at x, y: a soft fill, a dark line under a coloured one (the shared circle)
    function v:Ring(x, y, r, c, fillA, thick)
        self.nc = self.nc + 1
        local circ = self.circles[self.nc]
        if not circ then
            circ = EUI():CreateCircle(self.ov)
            self.circles[self.nc] = circ
        end
        circ:ClearAllPoints()
        circ:SetPoint("CENTER", self.ov, "TOPLEFT", x, -y)
        circ:Set(r, { stroke = { c[1], c[2], c[3], 1 }, width = thick, shadow = true, fill = { c[1], c[2], c[3], fillA } })
        return circ
    end
    -- the mouse near a place's middle (not dragging): its card in the tooltip (zone, coordinates, how far from me)
    local hover = CreateFrame("Frame", nil, v)
    hover.t = 0
    hover:SetScript("OnUpdate", function(f, dt)
        f.t = f.t + (dt or 0)
        if f.t < 0.1 then return end
        f.t = 0
        local px, py, on = v:Cursor()
        local found
        if on and v.hov and not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
            for _, h in ipairs(v.hov) do
                local reach = max(10, min(h[3], 24))
                if (px - h[1]) ^ 2 + (py - h[2]) ^ 2 <= reach * reach then found = h[4] end
            end
        end
        if found and v.tipFor ~= found then
            EUI():PlaceTip(v, found, false)
            v.tipFor = found
        elseif not found and v.tipFor then
            GameTooltip:Hide()
            v.tipFor = nil
        end
    end)
    function v:Done()
        for i = self.nc + 1, #self.circles do self.circles[i]:Hide() end
        for i = self.nl + 1, #self.lines do self.lines[i]:Hide() end
        for i = self.nt + 1, #self.texs do self.texs[i]:Hide() end
        for i = self.nf + 1, #self.fonts do self.fonts[i]:Hide() end
    end
    return v
end

-- My arrow on a view: where I stand, turned the way I face (only on the map I'm on, or its parent zone).
function MapSheet.DrawMe(v)
    if not (v.map and C_Map and C_Map.GetPlayerMapPosition) then return end
    if IsInInstance and IsInInstance() then return end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, v.map, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return end
    local x, y = pos:GetXY()
    if not (x and y) or x < 0 or x > 1 or y < 0 or y > 1 then return end
    local px, py = v:ToView(x, y)
    local blue = { 0.4, 0.72, 1 }
    v:Tex(EUI().MASK, px, py, 24, blue, 0.22, 4)
    v:Tex(EUI().RING, px, py, 25, blue, 0.95, 5)
    local arrow = v:Tex("Interface\\Minimap\\MinimapArrow", px, py, 20, { 1, 1, 1 }, 1, 6)
    local face = ns.EventSensors and ns.EventSensors.Facing and ns.EventSensors.Facing()
    if arrow.SetRotation and face then arrow:SetRotation(face) end
    v:Label("You", px + 15, py + 1, blue, "LEFT")
end

-- The places of the event on a view (edit: the one being changed, in gold with its size handle; its own values).
function MapSheet.DrawPlaces(v, edit)
    local d = Def()
    local per = v:PerYard()
    local T = Defs.TEAL
    v.hov = {}
    -- (names: the one being changed first, each kept inside the map, under its ring or over it at the foot; one that
    -- would lie on another is left to its card on hover)
    local kept = {}
    local function name(text, px, py, r, c)
        if not text or text == "" then return end
        local fs = v:Label(text, px, py + r + 10, c)
        local tw = TextW(fs)
        local y = py + r + 10
        if y + 7 > v.H then y = py - r - 10 end
        -- (a place whose name has no room on the map: its card on hover says it)
        if y < 8 or y > v.H - 8 or px < -r or px > v.W + r then fs:Hide() return end
        local x = max(tw / 2 + 4, min(v.W - tw / 2 - 4, px))
        local x1, y1, x2, y2 = x - tw / 2 - 2, y - 7, x + tw / 2 + 2, y + 7
        for _, k in ipairs(kept) do
            if x1 < k[3] and k[1] < x2 and y1 < k[4] and k[2] < y2 then fs:Hide() return end
        end
        kept[#kept + 1] = { x1, y1, x2, y2 }
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", v.ov, "TOPLEFT", x, -y)
    end
    if edit and tonumber(edit.map) == v.map and tonumber(edit.x) and tonumber(edit.y) and edit.n and edit.n ~= "" then
        local px, py = v:ToView(edit.x, edit.y)
        local r = max(6, (tonumber(edit.r) or 30) * per)
        -- (its own name over its ring: the handle is at its right)
        local fs = v:Label(edit.n, px, py - r - 11, GOLD3)
        local tw = TextW(fs)
        local x = max(tw / 2 + 4, min(v.W - tw / 2 - 4, px))
        local y = (py - r - 11 < 8) and (py + r + 11) or (py - r - 11)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", v.ov, "TOPLEFT", x, -y)
        kept[#kept + 1] = { x - tw / 2 - 2, y - 7, x + tw / 2 + 2, y + 7 }
    end
    for _, e in ipairs(B():Defs(d, "places")) do
        if (not edit or e.id ~= edit.pid) and tonumber(e.map) == v.map and tonumber(e.x) and tonumber(e.y) then
            local px, py = v:ToView(e.x, e.y)
            local r = max(6, (tonumber(e.r) or 30) * per)
            v:Ring(px, py, r, T, 0.2, 1.6)
            v:Tex(EUI().MASK, px, py, 4, { 0.61, 0.94, 1 }, 1, 4)
            name(e.n, px, py, r, { 1, 1, 1 })
            v.hov[#v.hov + 1] = { px, py, r, e }
        end
    end
    if edit and tonumber(edit.map) == v.map and tonumber(edit.x) and tonumber(edit.y) then
        local px, py = v:ToView(edit.x, edit.y)
        local r = max(6, (tonumber(edit.r) or 30) * per)
        v:Ring(px, py, r, GOLD3, 0.12, 2)
        -- its middle (a cross) and its size handle on the right
        v:Line(px - 6, py, px + 6, py, { 0, 0, 0 }, 1, 3.4, 4)
        v:Line(px, py - 6, px, py + 6, { 0, 0, 0 }, 1, 3.4, 4)
        v:Line(px - 6, py, px + 6, py, GOLD3, 1, 1.6, 5)
        v:Line(px, py - 6, px, py + 6, GOLD3, 1, 1.6, 5)
        v:Tex(EUI().MASK, px + r, py, 13, { 0, 0, 0 }, 1, 6)
        v:Tex(EUI().MASK, px + r, py, 11, { 0.96, 0.93, 0.82 }, 1, 7)
        v.handle = { x = px + r, y = py, cx = px, cy = py }
    else
        v.handle = nil
    end
end

-- The zones a place can be on: Outland's, Kalimdor's and the Eastern Kingdoms' (the game's list), with my zone.
local ZONE_PARENTS = { { 1945, "Outland" }, { 1414, "Kalimdor" }, { 1415, "Eastern Kingdoms" } }
local OUTLAND = { 1944, 1946, 1948, 1949, 1951, 1952, 1953, 1955 }
function MapSheet.Zones()
    if MapSheet.zones then return MapSheet.zones end
    local out = {}
    for _, p in ipairs(ZONE_PARENTS) do
        local list = {}
        if C_Map and C_Map.GetMapChildrenInfo then
            local ok, kids = pcall(C_Map.GetMapChildrenInfo, p[1], Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3, false)
            for _, k in ipairs(ok and type(kids) == "table" and kids or {}) do
                if k.mapID and k.name then list[#list + 1] = { id = k.mapID, name = k.name } end
            end
        end
        if #list == 0 and p[1] == 1945 then
            for _, id in ipairs(OUTLAND) do
                local n = MapSheet.MapName(id)
                if n then list[#list + 1] = { id = id, name = n } end
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        if #list > 0 then out[#out + 1] = { name = p[2], zones = list } end
    end
    MapSheet.zones = out
    return out
end

-- The size slider: 10 to 2000 yards, finer at the small end.
local R_MIN, R_MAX = 10, 2000
local function SizeToPos(r) return sqrt(max(0, min(1, ((r or 30) - R_MIN) / (R_MAX - R_MIN)))) end
local function PosToSize(p)
    local r = R_MIN + (max(0, min(1, p)) ^ 2) * (R_MAX - R_MIN)
    if r < 100 then return floor(r + 0.5) end
    return floor(r / 5 + 0.5) * 5
end

function MapSheet:Create()
    local f = CreateFrame("Frame", "DisasterZoneEventMapSheet", win)
    f:SetFrameStrata("FULLSCREEN")
    f:SetFrameLevel(20)
    f:SetSize(MS_W, MS_H)
    f:EnableMouse(true)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    VGrad(f.bg, { 0.11, 0.11, 0.129, 1 }, { 0.078, 0.078, 0.094, 1 })
    EUI():Edge(f, 0.47, 0.47, 0.51, 0.75)
    f.title = Text(f, "GameFontNormal", 14)
    f.title:SetPoint("LEFT", f, "TOPLEFT", 12, -20)
    f.x = CreateFrame("Button", nil, f)
    f.x:SetSize(20, 20)
    f.x:SetPoint("RIGHT", f, "TOPRIGHT", -10, -20)
    f.x.fs = Text(f.x, "GameFontHighlight", 17)
    f.x.fs:SetText("\195\151")
    f.x.fs:SetPoint("CENTER", 0, 1)
    f.x.fs:SetTextColor(0.66, 0.66, 0.68)
    f.x:SetScript("OnEnter", function(b) b.fs:SetTextColor(1, 1, 1) end)
    f.x:SetScript("OnLeave", function(b) b.fs:SetTextColor(0.66, 0.66, 0.68) end)
    f.x:SetScript("OnClick", function() MapSheet:Close() end)
    local hd = f:CreateTexture(nil, "BORDER")
    hd:SetColorTexture(1, 1, 1, 0.07)
    hd:SetHeight(1)
    hd:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -40)
    hd:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -40)
    -- the zone, and what the map does
    f.zone = UI():CreateSleekMenuButton(f, "", 186, function(root) MapSheet:ZoneMenu(root) end, 24)
    f.zone:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -52)
    f.hint = Text(f, "GameFontHighlightSmall", 11)
    f.hint:SetTextColor(0.62, 0.62, 0.62)
    f.hint:SetPoint("LEFT", f.zone, "RIGHT", 12, 0)
    f.hint:SetText("Click to move the place, drag its ring to size it")
    -- the map
    f.view = MapSheet.NewView(f, MAP_W, MAP_H)
    f.view:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -86)
    f.view:EnableMouse(true)
    f.view:EnableMouseWheel(true)
    f.view:SetScript("OnMouseDown", function(v, button) MapSheet:MouseDown(button) end)
    f.view:SetScript("OnMouseUp", function(v, button) MapSheet:MouseUp(button) end)
    f.view:SetScript("OnMouseWheel", function(v, delta) MapSheet:Zoom(delta > 0 and 1 or -1, true) end)
    f.view:SetScript("OnUpdate", function() MapSheet:OnUpdate() end)
    local zc = CreateFrame("Frame", nil, f.view.ov)
    zc:SetSize(24, 48)
    zc:SetPoint("BOTTOMRIGHT", f.view, "BOTTOMRIGHT", -8, 8)
    zc.bg = zc:CreateTexture(nil, "BACKGROUND")
    zc.bg:SetAllPoints()
    zc.bg:SetColorTexture(0.055, 0.055, 0.067, 0.94)
    EUI():Edge(zc, 0.34, 0.34, 0.38, 0.9)
    local function zb(y, plus, fn, tip)
        local b = CreateFrame("Button", nil, zc)
        b:SetSize(24, 24)
        b:SetPoint("TOPLEFT", zc, "TOPLEFT", 0, -y)
        b.t = b:CreateTexture(nil, "ARTWORK")
        b.t:SetPoint("CENTER")
        if plus then
            b.t:SetSize(11, 11)
            EUI():Glyph(b.t, UI().ICON.plus or 39, 0.86, 0.86, 0.86)
        else
            b.t:SetTexture(WHITE)
            b.t:SetSize(9, 2)
            b.t:SetVertexColor(0.86, 0.86, 0.86)
        end
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetScript("OnClick", fn)
        b:SetScript("OnEnter", function(self) Tip(self, tip) end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return b
    end
    zc.plus = zb(0, true, function() MapSheet:Zoom(1) end, "Zoom in")
    zc.minus = zb(24, false, function() MapSheet:Zoom(-1) end, "Zoom out")
    local zl = zc:CreateTexture(nil, "BORDER")
    zl:SetColorTexture(1, 1, 1, 0.08)
    zl:SetHeight(1)
    zl:SetPoint("LEFT", zc, "TOPLEFT", 1, -24)
    zl:SetPoint("RIGHT", zc, "TOPRIGHT", -1, -24)
    f.zc = zc
    -- the side: name, size, where, set from where I stand
    local sx = 12 + MAP_W + 48
    local sw = MS_W - sx - 12
    local function lab(text, y)
        local l = Text(f, "GameFontHighlightSmall", 11)
        l:SetTextColor(0.62, 0.62, 0.62)
        l:SetPoint("TOPLEFT", f, "TOPLEFT", sx, -y)
        l:SetText(text)
        return l
    end
    lab("Name", 92)
    f.name = UI():CreateSleekEditBox(f, sw, 26)
    f.name:SetPoint("TOPLEFT", f, "TOPLEFT", sx, -108)
    f.name:SetMaxLetters(MAX_NAME)
    f.name:SetScript("OnTextChanged", function(self, user)
        if user and MapSheet.cur then MapSheet.cur.n = self:GetText(); MapSheet:Draw() end
        if f.err then f.err:SetText("") end
    end)
    f.name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.name:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    lab("Size", 146)
    f.size = Text(f, "GameFontHighlight", 12)
    f.size:SetPoint("TOPRIGHT", f, "TOPLEFT", sx + sw, -145)
    f.slider = CreateFrame("Frame", nil, f)
    f.slider:SetSize(sw, 16)
    f.slider:SetPoint("TOPLEFT", f, "TOPLEFT", sx, -164)
    f.slider:EnableMouse(true)
    f.slider.track = f.slider:CreateTexture(nil, "BACKGROUND")
    f.slider.track:SetColorTexture(1, 1, 1, 0.14)
    f.slider.track:SetHeight(2)
    f.slider.track:SetPoint("LEFT", f.slider, "LEFT", 0, 0)
    f.slider.track:SetPoint("RIGHT", f.slider, "RIGHT", 0, 0)
    f.slider.fill = f.slider:CreateTexture(nil, "ARTWORK")
    f.slider.fill:SetColorTexture(1, 0.82, 0, 1)
    f.slider.fill:SetHeight(2)
    f.slider.fill:SetPoint("LEFT", f.slider, "LEFT", 0, 0)
    f.slider.knobE = f.slider:CreateTexture(nil, "OVERLAY", nil, 1)
    f.slider.knobE:SetTexture(EUI().MASK)
    f.slider.knobE:SetSize(14, 14)
    f.slider.knobE:SetVertexColor(0, 0, 0, 1)
    f.slider.knob = f.slider:CreateTexture(nil, "OVERLAY", nil, 2)
    f.slider.knob:SetTexture(EUI().MASK)
    f.slider.knob:SetSize(12, 12)
    f.slider.knob:SetVertexColor(0.96, 0.93, 0.82)
    f.slider:SetScript("OnMouseDown", function(s, button)
        if button == "LeftButton" then s.dragging = true end
    end)
    f.slider:SetScript("OnMouseUp", function(s) s.dragging = nil end)
    f.slider:SetScript("OnUpdate", function(s)
        if not s.dragging then return end
        if not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then s.dragging = nil return end
        local l = s:GetLeft()
        if not l then return end
        local x = GetCursorPosition() / s:GetEffectiveScale()
        MapSheet:SetSize(PosToSize((x - l) / s:GetWidth()))
    end)
    lab("Where", 176)
    f.where = Text(f, "GameFontHighlight", 12)
    f.where:SetWordWrap(true)
    f.where:SetWidth(sw)
    f.where:SetPoint("TOPLEFT", f, "TOPLEFT", sx, -192)
    f.coords = Text(f, "GameFontHighlightSmall", 10.5)
    f.coords:SetTextColor(0.62, 0.62, 0.62)
    f.coords:SetPoint("TOPLEFT", f.where, "BOTTOMLEFT", 0, -2)
    f.stand = UI():CreateSleekButton(f, "Set from where I stand", sw, 24, function() MapSheet:StandHere() end)
    f.stand:SetPoint("TOPLEFT", f.coords, "BOTTOMLEFT", 0, -14)
    f.stand.icon = f.stand:CreateTexture(nil, "ARTWORK")
    f.stand.icon:SetSize(12, 12)
    EUI():Glyph(f.stand.icon, 37, 0.9, 0.9, 0.9)
    local sfs = f.stand:GetFontString()
    sfs:ClearAllPoints()
    sfs:SetPoint("CENTER", f.stand, "CENTER", 9, 0)
    f.stand.icon:SetPoint("RIGHT", sfs, "LEFT", -7, 0)
    f.err = Text(f, "GameFontHighlightSmall", 11)
    f.err:SetTextColor(1, 0.54, 0.48)
    f.err:SetWordWrap(true)
    f.err:SetWidth(sw)
    f.err:SetPoint("TOPLEFT", f.stand, "BOTTOMLEFT", 0, -10)
    -- the foot
    local fd = f:CreateTexture(nil, "BORDER")
    fd:SetColorTexture(1, 1, 1, 0.07)
    fd:SetHeight(1)
    fd:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 46)
    fd:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 46)
    f.pin = f:CreateTexture(nil, "ARTWORK")
    f.pin:SetSize(12, 12)
    EUI():Glyph(f.pin, 7, 0.62, 0.62, 0.62)
    f.pin:SetPoint("LEFT", f, "BOTTOMLEFT", 12, 23)
    f.note = Text(f, "GameFontHighlightSmall", 11)
    f.note:SetTextColor(0.62, 0.62, 0.62)
    f.note:SetPoint("LEFT", f.pin, "RIGHT", 7, 0)
    f.note:SetText("Places work in the open world, not in dungeons")
    f.save = UI():CreateSleekButton(f, "Save place", 92, 24, function() MapSheet:Save() end, "primary")
    f.save:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 11)
    f.cancel = UI():CreateSleekButton(f, "Cancel", 74, 24, function() MapSheet:Close() end)
    f.cancel:SetPoint("RIGHT", f.save, "LEFT", -6, 0)
    f.bin = UI():CreateTipIconButton(f, 24, UI().ICON.trash, "Delete the place", "Pieces that use it will each need another.",
        function() if MapSheet.cur and MapSheet.cur.pid then Defs:Delete("places", MapSheet.cur.pid) end end)
    f.bin:SetPoint("RIGHT", f.cancel, "LEFT", -6, 0)
    f:SetScript("OnShow", function() Defs.Dim(true) end)
    f:SetScript("OnHide", function()
        local cur = MapSheet.cur
        MapSheet.cur = nil
        Defs.Dim(false)
        if cur and cur.onClosed then cur.onClosed() end
        if win and win:IsShown() then Builder:RenderPalette() end
    end)
    f:Hide()
    ui.msheet = f
    return f
end

-- Opens the sheet: opts.pid (a place to change), opts.stand (a new one where I stand: refused in an instance),
-- opts.onSaved(pid), opts.onClosed().
function MapSheet:Open(opts)
    opts = opts or {}
    if not CanEditDefs() and not opts.pid then Builder:SayReadOnly() return end
    local d = Def()
    local cur
    if opts.pid then
        local pl = B():Definition(d, "places", opts.pid)
        if not pl then return end
        cur = Copy(pl)
        cur.pid = opts.pid
    else
        cur = { r = 30 }
        if opts.stand then
            local here, why = MapSheet.Here()
            if not here then
                ns:Print("%s", why)
                if opts.onClosed then opts.onClosed() end
                return
            end
            cur.map, cur.x, cur.y, cur.z, cur.sz = here.map, here.x, here.y, here.z, here.sz
            cur.n = here.sz or here.z or ""
        end
        if not cur.n or cur.n == "" then
            local i = #B():Defs(d, "places", true) + 1
            cur.n = "Place " .. i
        end
    end
    -- a place with no spot yet starts on my zone (or the event's first place's)
    if not tonumber(cur.map) then
        local here = MapSheet.Here()
        local first = B():Defs(d, "places", true)[1]
        cur.view = (here and here.map) or (first and tonumber(first.map)) or 1951
    end
    cur.onSaved, cur.onClosed = opts.onSaved, opts.onClosed
    Builder:ClosePicker()
    if ui.dpop and ui.dpop:IsShown() then Defs:Close() end
    QSheet:Close()
    local f = ui.msheet or self:Create()
    self.cur = cur
    cur.vmap = tonumber(cur.map) or cur.view
    cur.vz = 1
    cur.vx, cur.vy = tonumber(cur.x) or 0.5, tonumber(cur.y) or 0.5
    -- a place whose ring is small in its zone: closer in
    local yd = MapSheet.Yards(cur.vmap)
    if cur.x and yd then
        local frac = (tonumber(cur.r) or 30) * 2 / yd
        for _, z in ipairs(ZOOMS_MAP) do if frac * z < 0.35 then cur.vz = z end end
        cur.vz = min(cur.vz, 3)
    end
    f.title:SetText("Pick on the map")
    f.name:SetText(cur.n or "")
    f.err:SetText("")
    f.save:SetShown(CanEditDefs())
    f.bin:SetShown(CanEditDefs() and cur.pid ~= nil)
    f.stand:SetShown(CanEditDefs())
    f:ClearAllPoints()
    f:SetPoint("TOP", win.content or win, "TOP", 0, -40)
    f:Show()
    f:Raise()
    self:Draw()
    Builder:RenderPalette()
end

function MapSheet:Close(quiet)
    local cur = self.cur
    self.cur = nil
    if ui.msheet then ui.msheet:Hide() end
    Defs.Dim(false)
    if cur and cur.onClosed then cur.onClosed() end
end

function MapSheet:Draw()
    local f, cur = ui.msheet, self.cur
    if not (f and cur) then return end
    local v = f.view
    v:Set(cur.vmap, cur.vx, cur.vy, cur.vz)
    cur.vx, cur.vy = v.cx, v.cy
    v:Begin()
    MapSheet.DrawPlaces(v, cur)
    MapSheet.DrawMe(v)
    v:Done()
    f.zc:SetShown(v.layer ~= nil)
    local zname = MapSheet.MapName(cur.vmap) or (cur.vmap and ("Map " .. cur.vmap)) or "Pick a zone"
    f.zone:SetText("|cff9e9ea4Zone|r  " .. zname)
    f.size:SetText(floor(tonumber(cur.r) or 30) .. " yd")
    local p = SizeToPos(tonumber(cur.r) or 30)
    local sw = f.slider:GetWidth()
    f.slider.fill:SetWidth(max(1, p * sw))
    f.slider.knob:ClearAllPoints()
    f.slider.knob:SetPoint("CENTER", f.slider, "LEFT", p * sw, 0)
    f.slider.knobE:ClearAllPoints()
    f.slider.knobE:SetPoint("CENTER", f.slider, "LEFT", p * sw, 0)
    if tonumber(cur.x) and tonumber(cur.y) then
        local where = {}
        if cur.sz and cur.sz ~= "" then where[#where + 1] = cur.sz end
        where[#where + 1] = cur.z or MapSheet.MapName(cur.map) or ""
        f.where:SetText(table.concat(where, ", "))
        f.coords:SetText(("%.1f, %.1f"):format(cur.x * 100, cur.y * 100))
    elseif cur.sz or cur.z then
        f.where:SetText((cur.sz and (cur.sz .. ", ") or "") .. (cur.z or ""))
        f.coords:SetText("its subzone: click the map to set a spot")
    else
        f.where:SetText("Not set yet")
        f.coords:SetText("click the map, or stand there")
    end
end

function MapSheet:ZoneMenu(root)
    local cur = self.cur
    if not cur then return end
    local function pick(id)
        cur.vmap, cur.vz, cur.vx, cur.vy = id, 1, 0.5, 0.5
        if tonumber(cur.map) == id and tonumber(cur.x) then cur.vx, cur.vy = cur.x, cur.y end
        MapSheet:Draw()
    end
    local here = MapSheet.Here()
    if here and here.map then
        root:CreateRadio("Where I am: " .. (MapSheet.MapName(here.map) or here.z or "?"), function() return cur.vmap == here.map end,
            function() pick(here.map) end)
        root:CreateDivider()
    end
    for _, group in ipairs(MapSheet.Zones()) do
        local sub = root:CreateButton(group.name)
        for _, z in ipairs(group.zones) do
            sub:CreateRadio(z.name, function() return cur.vmap == z.id end, function() pick(z.id) end)
        end
        if sub.SetScrollMode then sub:SetScrollMode(20 * 20) end
    end
end

function MapSheet:Zoom(dir, atCursor)
    local cur, v = self.cur, ui.msheet and ui.msheet.view
    if not (cur and v and v.layer) then return end
    local z = cur.vz
    local nz = z
    if dir > 0 then
        for _, l in ipairs(ZOOMS_MAP) do if l > z + 0.01 then nz = l break end end
    else
        for i = #ZOOMS_MAP, 1, -1 do if ZOOMS_MAP[i] < z - 0.01 then nz = ZOOMS_MAP[i] break end end
    end
    if nz == z then return end
    -- around the cursor (the wheel), else the place
    local px, py, inside = v:Cursor()
    if atCursor and inside then
        local mx, my = v:FromView(px, py)
        local k = z / nz
        cur.vx, cur.vy = mx - (mx - v.cx) * k, my - (my - v.cy) * k
    elseif tonumber(cur.x) and tonumber(cur.map) == cur.vmap then
        cur.vx, cur.vy = cur.x, cur.y
    end
    cur.vz = nz
    self:Draw()
end

function MapSheet:SetSize(r)
    local cur = self.cur
    if not cur then return end
    if not CanEditDefs() then return end
    cur.r = max(5, min(5000, floor(r + 0.5)))
    self:Draw()
end

-- A press on the map: on the ring's handle it sizes the place; a click elsewhere moves the place there, a drag pans.
function MapSheet:MouseDown(button)
    local cur, v = self.cur, ui.msheet and ui.msheet.view
    if button ~= "LeftButton" or not (cur and v) then return end
    local px, py = v:Cursor()
    if not px then return end
    local h = v.handle
    if h and CanEditDefs() and (px - h.x) ^ 2 + (py - h.y) ^ 2 <= 81 then
        self.press = { size = true }
        return
    end
    self.press = { x = px, y = py, vx = cur.vx, vy = cur.vy }
end

function MapSheet:OnUpdate()
    local pr, cur, v = self.press, self.cur, ui.msheet and ui.msheet.view
    if not (pr and cur and v) then return end
    if not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then return end
    local px, py = v:Cursor()
    if not px then return end
    if pr.size then
        local h = v.handle
        if not h then return end
        local dist = sqrt((px - h.cx) ^ 2 + (py - h.cy) ^ 2)
        self:SetSize(dist / v:PerYard())
        return
    end
    if pr.pan or abs(px - pr.x) + abs(py - pr.y) > 4 then
        pr.pan = true
        cur.vx = pr.vx - (px - pr.x) / (v.lw * v.s)
        cur.vy = pr.vy - (py - pr.y) / (v.lh * v.s)
        self:Draw()
    end
end

function MapSheet:MouseUp(button)
    local pr, cur, v = self.press, self.cur, ui.msheet and ui.msheet.view
    self.press = nil
    if button ~= "LeftButton" or not (pr and cur and v) or pr.size or pr.pan then return end
    if not v.layer then return end
    if not CanEditDefs() then Builder:SayReadOnly() return end
    local px, py, inside = v:Cursor()
    if not inside then return end
    local x, y = v:FromView(px, py)
    if x < 0 or x > 1 or y < 0 or y > 1 then return end
    -- moved on the map: its zone is the map's, its subzone isn't known any more (the game says it only where I stand)
    if tonumber(cur.map) ~= v.map then cur.sz = nil end
    if not (tonumber(cur.x) and abs(x - cur.x) < 0.0005 and abs(y - cur.y) < 0.0005) then cur.sz = nil end
    cur.map, cur.x, cur.y = v.map, floor(x * 10000 + 0.5) / 10000, floor(y * 10000 + 0.5) / 10000
    cur.z = MapSheet.MapName(v.map) or cur.z
    self:Draw()
end

function MapSheet:StandHere()
    local cur = self.cur
    if not cur then return end
    if not CanEditDefs() then Builder:SayReadOnly() return end
    local here, why = MapSheet.Here()
    if not here then
        ui.msheet.err:SetText(why)
        return
    end
    cur.map, cur.x, cur.y, cur.z, cur.sz = here.map, here.x, here.y, here.z, here.sz
    cur.vmap, cur.vx, cur.vy = here.map, here.x, here.y
    if (cur.n or "") == "" or (cur.n or ""):find("^Place %d+$") then
        cur.n = here.sz or here.z or cur.n
        ui.msheet.name:SetText(cur.n or "")
    end
    ui.msheet.err:SetText("")
    self:Draw()
end

-- Save place: its name (unique), where it is, its size; a new one joins the event.
function MapSheet:Save()
    local cur, f = self.cur, ui.msheet
    if not cur then return end
    if not CanEditDefs() then Builder:SayReadOnly() return end
    local name = Clean(f.name:GetText(), MAX_NAME)
    if name == "" then f.err:SetText("Type a name first") return end
    local taken = Defs:NameTaken("places", name, cur.pid)
    if taken then f.err:SetText(taken) return end
    if not (tonumber(cur.map) and tonumber(cur.x)) and not cur.sz and not cur.z then
        f.err:SetText("Click the map where it is, or set it from where you stand")
        return
    end
    local d = Def()
    local fields = { n = name, map = tonumber(cur.map), x = tonumber(cur.x), y = tonumber(cur.y),
        r = max(5, min(5000, floor((tonumber(cur.r) or 30) + 0.5))), z = cur.z, sz = cur.sz }
    local before = Snapshot()
    local pid = cur.pid
    if pid then
        d.places[pid] = fields
    else
        pid = B():NewDefinition(d, "places", fields)
        if not pid then
            f.err:SetText(("An event has %d places at most"):format(B().LIMITS.places or 24))
            return
        end
    end
    local onSaved = cur.onSaved
    self:Close()
    Changed(before)
    if onSaved then onSaved(pid) end
end

-- A new place for a blank: the sheet (by standing there, or on the map), then the blank holds it.
function Builder:NewPlaceFor(piece, slot, how)
    self:ClosePicker()
    MapSheet:Open({ stand = how == "stand", onSaved = function(pid)
        local before = Snapshot()
        piece.a[slot] = pid
        Changed(before)
    end })
end

---------------------------------------------------------------------------
-- A place's card (the mouse over a place in a blank): a small map with its ring, where it is, how many pieces use it
---------------------------------------------------------------------------

local CARD_W, CARD_MAP_H = 250, 118

function Defs:ShowCard(pid, anchor)
    local d = Def()
    local pl = B():Definition(d, "places", pid)
    if not (pl and anchor) then return end
    local c = ui.pcard
    if not c then
        c = CreateFrame("Frame", "DisasterZoneEventPlaceCard", win)
        c:SetFrameStrata("TOOLTIP")
        c:SetWidth(CARD_W)
        c.bg = c:CreateTexture(nil, "BACKGROUND")
        c.bg:SetAllPoints()
        c.bg:SetColorTexture(0.047, 0.047, 0.059, 0.98)
        EUI():Edge(c, 0.47, 0.47, 0.51, 0.75)
        c.view = MapSheet.NewView(c, CARD_W, CARD_MAP_H)
        c.view:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
        c.line = Text(c, "GameFontHighlightSmall", 11)
        c.line:SetTextColor(0.62, 0.62, 0.62)
        c.m = Text(c, "GameFontHighlightSmall", 11)
        c.m:SetWordWrap(true)
        c.m:SetWidth(CARD_W - 20)
        c.m:SetTextColor(0.81, 0.81, 0.81)
        ui.pcard = c
    end
    local v = c.view
    local onMap = tonumber(pl.map) and tonumber(pl.x)
    v:SetShown(onMap and MapSheet.Layer(pl.map) ~= nil)
    local top = 0
    if v:IsShown() then
        -- close enough that the ring is most of the map's height
        local yd = MapSheet.Yards(pl.map) or 4000
        local z = 1
        for _, zz in ipairs({ 1, 1.5, 2, 3, 4, 6, 8 }) do
            local base = min(CARD_W / 1002, CARD_MAP_H / 668)
            if (tonumber(pl.r) or 30) * 2 * (1002 * base * zz) / yd < CARD_MAP_H * 0.8 then z = zz end
        end
        v:Set(pl.map, pl.x, pl.y, z)
        v:Begin()
        local px, py = v:ToView(pl.x, pl.y)
        local r = max(6, (tonumber(pl.r) or 30) * v:PerYard())
        v:Ring(px, py, r, GOLD3, 0.12, 2)
        v:Line(px - 6, py, px + 6, py, GOLD3, 1, 1.6, 5)
        v:Line(px, py - 6, px, py + 6, GOLD3, 1, 1.6, 5)
        v:Tex(EUI().MASK, px + r, py, 11, { 0.96, 0.93, 0.82 }, 1, 7)
        MapSheet.DrawMe(v)
        v:Done()
        v:ShowZone(true)
        top = CARD_MAP_H
    end
    if c.chip then EP():Release(c.chip) end
    c.chip = EP():DrawChip(c, "place", pid, { def = d, static = true })
    c.chip:ClearAllPoints()
    c.chip:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -(top + 9))
    local where = {}
    if pl.sz and pl.sz ~= "" then where[#where + 1] = pl.sz end
    if pl.z and pl.z ~= "" then where[#where + 1] = pl.z end
    local wtext = table.concat(where, ", ")
    c.line:SetText((wtext ~= "" and (wtext .. " · ") or "") .. (onMap and (floor(tonumber(pl.r) or 30) .. " yd") or "the subzone"))
    c.line:ClearAllPoints()
    c.line:SetPoint("LEFT", c.chip, "RIGHT", 8, 0)
    local n = B():DefinitionUses(d, "places", pid)
    -- (where it is exactly, and how far from me: "At 41.5, 47.0, 340 yd from you.")
    local xy, yd = EUI():Coords(pl, 1), EUI():YardsTo(pl)
    local at = xy and ("At " .. xy .. (yd and (", " .. floor(yd + 0.5) .. " yd from you") or "") .. ". ") or ""
    c.m:SetText(at .. Plural(n, "piece uses", "pieces use") .. " it. "
        .. (CanEdit() and "Click to pick another, or to change it on the map." or ""))
    c.m:ClearAllPoints()
    c.m:SetPoint("TOPLEFT", c, "TOPLEFT", 10, -(top + 9 + 19 + 6))
    c:SetHeight(top + 9 + 19 + 6 + max(14, floor((c.m:GetStringHeight() or 14) + 0.5)) + 10)
    c:ClearAllPoints()
    c:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -6, -8)
    c:Show()
end

function Defs:HideCard()
    if ui.pcard then ui.pcard:Hide() end
end

-- The mouse over a blank: a place in it shows its card.
OnHover = function(piece, slot, frame, on)
    if not on then Defs:HideCard() return end
    local v = piece and piece.a and piece.a[slot]
    local t = B():ArgType(piece, slot)
    if (t == "place" or t == "where") and type(v) == "string" and B():Definition(Def(), "places", v) then
        Defs:ShowCard(v, frame)
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
    self:CloseFloating()
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
    self:CloseFloating()
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

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Notify.lua", ...) then return end -- DisasterZone UI/Notify.lua
-- ns.NotifyUI: everything that shows the notification center's feed (Core/Notify.lua).
--   the bell     left of the sync mark in the nav strip: a gold count of what needs you, a grey dot for news
--   the tray     drops from the bell: "Needs you" / "Everything", answers right on the rows, "All notifications"
--   the page     Notifications (no tab of its own; the tray's foot opens it): sections on the left, handled items
--   pop-ups      one toast look for every kind (top of the screen), queued, "1 of 3", never in combat
--   counts       on the nav strip's tabs (a group's pages added up) and on the minimap button
-- Sections never draw their own counts or pop-ups: they register kinds with ns.Notify.
local addonName, ns = ...

local NotifyUI = ns:NewModule("NotifyUI")

local floor, max, min = math.floor, math.max, math.min

local function UI() return ns.UI end
local function N() return ns.Notify end
local function Now() return (GetServerTime and GetServerTime()) or time() end

local GOLD = { 1, 0.82, 0 }
local GREY = { 0.62, 0.62, 0.62 }
local DIM = { 0.55, 0.55, 0.57 }
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BELL = { 56, 42, 6 }            -- the bell (art pack 6), else the speech bubble
NotifyUI.TRAY_W, NotifyUI.TRAY_MAX_H = 392, 452
NotifyUI.TOAST_W = 340
NotifyUI.INFO_SECONDS = 7             -- a news pop-up stays this long (held while the mouse is on it)

local bell, tray, page, toast
local queue = {}                      -- pop-ups waiting (ids)
local inEncounter = false

---------------------------------------------------------------------------
-- Small pieces
---------------------------------------------------------------------------

local function IconIndex(spec)
    if type(spec) == "table" then return ns:HasAssets(spec[3] or 4) and spec[1] or spec[2] end
    return spec
end

-- A kind's icon on a texture, in its colour.
local function SetKindIcon(tex, def, it)
    local spec = def and def.icon
    if type(def and def.iconFor) == "function" then
        local ok, s = pcall(def.iconFor, it)
        if ok and s then spec = s end
    end
    if type(spec) == "table" and spec.tex then
        tex:SetTexture(spec.tex)
        local c = spec.coords
        if c then tex:SetTexCoord(c[1], c[2], c[3], c[4]) else tex:SetTexCoord(0, 1, 0, 1) end
    else
        tex:SetTexture(UI().ICON_ATLAS)
        tex:SetTexCoord(unpack(UI():IconCoords(IconIndex(spec) or UI().ICON.notes)))
    end
    local c = def and def.color or GOLD
    tex:SetVertexColor(c[1], c[2], c[3])
end

local function SetFontSize(fs, size)
    local path, _, flags = fs:GetFont()
    fs:SetFont(path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, flags or "")
end

local function FS(parent, template, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    if size then SetFontSize(fs, size) end
    if color then fs:SetTextColor(color[1], color[2], color[3]) end
    fs:SetJustifyH("LEFT")
    return fs
end

local function StrH(fs, fallback)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (h and h > 0) and h or fallback
end

-- A count: a small pill, dark gold fill and edge, the number in cream. p:SetCount(n) (0 hides it).
local function CountPill(parent, h)
    local p = CreateFrame("Frame", nil, parent)
    p:SetHeight(h)
    UI():AddPillShape(p, h)
    p:SetPillColors({ 0.25, 0.19, 0.12, 1 }, { 0.78, 0.57, 0.2, 1 })
    p.fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetFontSize(p.fs, h - 4)
    p.fs:SetPoint("CENTER", 0.5, 0)
    p.fs:SetTextColor(1, 0.86, 0.62)
    function p:SetCount(n)
        n = tonumber(n) or 0
        if n <= 0 then
            self:Hide()
            return
        end
        self.fs:SetText(n > 99 and "99+" or tostring(n))
        self:SetWidth(max(h, floor((self.fs:GetStringWidth() or 6) + 6 + 0.5)))
        self:Show()
    end
    p:Hide()
    return p
end
NotifyUI.CountPill = CountPill

local function Dot(parent, size, color)
    local t = parent:CreateTexture(nil, "OVERLAY", nil, 2)
    t:SetSize(size, size)
    t:SetTexture(DISC)
    t:SetVertexColor(color[1], color[2], color[3], 1)
    t:Hide()
    return t
end

-- "SECTION · FROM NAME": the kicker over an item's title.
local function Kicker(def, it)
    local s = (def.section or ""):upper()
    if def.kicker then
        local ok, k = pcall(def.kicker, it)
        if ok and k then s = s .. " · " .. tostring(k):upper() end
    end
    if it.from then
        local name = UI():ColoredName(it.from)
        s = s .. " · FROM " .. (name or tostring(it.from))
    end
    return s
end

---------------------------------------------------------------------------
-- Rows (the tray and the page)
---------------------------------------------------------------------------

local TILE = 26

local function MakeRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetColorTexture(1, 1, 1, 0)
    r.tile = CreateFrame("Frame", nil, r)
    r.tile:SetSize(TILE, TILE)
    r.tile:SetPoint("TOPLEFT", 10, -9)
    r.tile.bg = r.tile:CreateTexture(nil, "BACKGROUND")
    r.tile.bg:SetAllPoints()
    r.tile.bg:SetColorTexture(0.09, 0.09, 0.11, 1)
    UI():AddEdges(r.tile, "BORDER")
    UI():SetEdgeColor(r.tile, 0.2, 0.2, 0.23, 1)
    r.icon = r.tile:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("CENTER")
    r.dot = Dot(r.tile, 7, GOLD)
    r.dot:SetPoint("CENTER", r.tile, "TOPRIGHT", 0, 0)
    r.stack = CountPill(r.tile, 11)
    r.stack:SetPillColors({ 0.17, 0.17, 0.19, 1 }, { 0.06, 0.06, 0.07, 1 })
    r.stack.fs:SetTextColor(0.86, 0.86, 0.86)
    r.stack:SetPoint("CENTER", r.tile, "BOTTOMRIGHT", 0, 0)
    r.kicker = FS(r, "GameFontHighlightSmall", 9, DIM)
    r.when = FS(r, "GameFontHighlightSmall", 10, DIM)
    r.when:SetJustifyH("RIGHT")
    r.title = FS(r, "GameFontHighlight", nil, { 1, 1, 1 })
    r.title:SetWordWrap(true)
    r.text = FS(r, "GameFontHighlightSmall", nil, GREY)
    r.text:SetWordWrap(true)
    r.btns = {}
    r.line = r:CreateTexture(nil, "BORDER")
    r.line:SetColorTexture(1, 1, 1, 0.06)
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r:SetScript("OnEnter", function(self)
        if not self.done then self.bg:SetColorTexture(1, 1, 1, 0.04) end
    end)
    r:SetScript("OnLeave", function(self) self.bg:SetColorTexture(1, 1, 1, self.fresh and 0.025 or 0) end)
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnClick", function(self)
        if self.done or not self.id then return end
        if self.onOpen then self.onOpen(self.id) end
        N():Open(self.id)
    end)
    return r
end

-- A header line between groups ("NEEDS YOU", "NEWS", "HANDLED").
local function MakeHead(parent)
    local h = CreateFrame("Frame", nil, parent)
    h.fs = FS(h, "GameFontHighlightSmall", 9, DIM)
    h.fs:SetPoint("BOTTOMLEFT", 10, 4)
    h.right = FS(h, "GameFontHighlightSmall", 9, DIM)
    h.right:SetJustifyH("RIGHT")
    h.right:SetPoint("BOTTOMRIGHT", -10, 4)
    return h
end

-- Fills a row for item it, width w; returns its height. opts: { done = true } (a handled item, dimmed),
-- fresh (unseen: the gold dot), onOpen(id) / onAction() before the item's own open / action.
local function FillRow(r, it, w, opts)
    opts = opts or {}
    local def = N():GetKind(it.kind) or {}
    r.id, r.done, r.onOpen, r.fresh = it.id, opts.done, opts.onOpen, opts.fresh
    r:SetWidth(w)
    SetKindIcon(r.icon, def, it)
    r.icon:SetDesaturated(opts.done and true or false)
    r.dot:SetShown(opts.fresh and true or false)
    r.stack:SetCount((it.n or 0) > 1 and it.n or 0)
    r.bg:SetColorTexture(1, 1, 1, opts.fresh and 0.025 or 0)
    local x, tw = 10 + TILE + 10, w - (10 + TILE + 10) - 12
    r.kicker:ClearAllPoints()
    r.kicker:SetPoint("TOPLEFT", x, -9)
    r.kicker:SetPoint("TOPRIGHT", -64, -9)
    r.kicker:SetText(Kicker(def, it))
    r.when:ClearAllPoints()
    r.when:SetPoint("TOPRIGHT", -12, -8)
    r.when:SetText(opts.done and ((it.how == "handled" and "handled " or "gone ") .. N():Ago(it.done)) or N():Ago(it.time))
    local y = -22
    r.title:ClearAllPoints()
    r.title:SetWidth(tw)                               -- (the width before the text: a wrapped layout)
    r.title:SetPoint("TOPLEFT", x, y)
    r.title:SetText(it.title or "")
    r.title:SetTextColor(opts.done and 0.7 or 1, opts.done and 0.7 or 1, opts.done and 0.7 or 1)
    y = y - StrH(r.title, 14) - 2
    r.text:ClearAllPoints()
    r.text:SetWidth(tw)
    r.text:SetPoint("TOPLEFT", x, y)
    r.text:SetText(it.text or "")
    r.text:SetShown((it.text or "") ~= "")
    if (it.text or "") ~= "" then y = y - StrH(r.text, 12) end
    for _, b in ipairs(r.btns) do b:Hide() end
    local acts = (not opts.done) and N():GetActions(it.id) or {}
    if #acts > 0 then
        y = y - 7
        local bx = x
        for i = 1, min(2, #acts) do
            local a = acts[i]
            local b = r.btns[i]
            if not b then
                b = UI():CreateSleekButton(r, "", nil, 20)
                r.btns[i] = b
            end
            b:SetText(a.text or "")
            b:SetWidth(max(64, floor((b:GetFontString():GetStringWidth() or 40) + 24)))
            b:SetKind(a.primary and "primary" or "secondary")
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", bx, y)
            local id, index = it.id, i
            b:SetScript("OnClick", function()
                if opts.onAction then opts.onAction(id) end
                N():RunAction(id, index)
            end)
            b:Show()
            bx = bx + b:GetWidth() + 6
        end
        y = y - 20
    end
    local h = max(TILE + 18, floor(-y + 10))
    r:SetHeight(h)
    r:Show()
    return h
end
NotifyUI.FillRow = FillRow

-- Lays rows and headers into a scroll child: entries = { { head = text, right = text } | { item = it, done, fresh } }.
local function LayoutList(holder, entries, w, opts)
    holder.rows = holder.rows or {}
    holder.heads = holder.heads or {}
    local ri, hi, y = 0, 0, 0
    for _, e in ipairs(entries) do
        if e.head then
            hi = hi + 1
            local h = holder.heads[hi] or MakeHead(holder)
            holder.heads[hi] = h
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", 0, -y)
            h:SetSize(w, 24)
            h.fs:SetText(e.head)
            h.right:SetText(e.right or "")
            h:Show()
            y = y + 24
        else
            ri = ri + 1
            local r = holder.rows[ri] or MakeRow(holder)
            holder.rows[ri] = r
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -y)
            y = y + FillRow(r, e.item, w, { done = e.done, fresh = e.fresh, onOpen = opts and opts.onOpen,
                onAction = opts and opts.onAction })
        end
    end
    for i = ri + 1, #holder.rows do holder.rows[i]:Hide() end
    for i = hi + 1, #holder.heads do holder.heads[i]:Hide() end
    holder:SetHeight(max(1, y))
    return y
end

-- The feed as entries for a view: "needs" | "all" | a section name | "done".
local function Entries(view)
    local Nf, out = N(), {}
    local function add(list, done)
        for _, it in ipairs(list) do
            out[#out + 1] = { item = it, done = done, fresh = not done and not Nf:IsSeen(it.id) }
        end
    end
    if view == "needs" then
        add(Nf:List({ needsYou = true }))
    elseif view == "done" then
        add(Nf:ListDone(), true)
    elseif view == "all" then
        local needs, news = Nf:List({ needsYou = true }), Nf:List({ needsYou = false })
        if #needs > 0 then
            out[#out + 1] = { head = "NEEDS YOU" }
            add(needs)
        end
        if #news > 0 then
            if #needs > 0 then out[#out + 1] = { head = "NEWS" } end
            add(news)
        end
    else
        add(Nf:List({ section = view }))
        local done = Nf:ListDone({ section = view })
        if #done > 0 then
            out[#out + 1] = { head = "HANDLED" }
            add(done, true)
        end
    end
    return out
end
NotifyUI.Entries = Entries

---------------------------------------------------------------------------
-- The bell
---------------------------------------------------------------------------

local function PaintBell()
    if not bell then return end
    local c = (tray and tray:IsShown()) and GOLD or (bell.hovered and { 1, 1, 1 } or GREY)
    bell.icon:SetVertexColor(c[1], c[2], c[3])
end

function NotifyUI:UpdateBell()
    if not bell or not N() then return end
    local n = N():Count()
    bell.count:SetCount(n)
    bell.dot:SetShown(n == 0 and N():UnseenCount() > 0)
    PaintBell()
end

local function BellTip(self)
    local GT = GameTooltip
    GT:SetOwner(self, "ANCHOR_BOTTOM")
    GT:AddLine("Notifications")
    local n = N() and N():Count() or 0
    if n > 0 then
        GT:AddLine(n == 1 and "1 thing waits for you." or (n .. " things wait for you."), 1, 1, 1, true)
    elseif N() and N():UnseenCount() > 0 then
        GT:AddLine("Something new to read.", 1, 1, 1, true)
    else
        GT:AddLine("Nothing new.", 1, 1, 1, true)
    end
    GT:Show()
end

function NotifyUI:CreateBell(parent)
    if bell then return bell end
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(28, 26)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(16, 16)
    b.icon:SetPoint("CENTER", 0, 1)
    b.icon:SetTexture(UI().ICON_ATLAS)
    b.icon:SetTexCoord(unpack(UI():IconCoords(IconIndex(BELL))))
    b.count = CountPill(b, 12)
    b.count:SetPoint("LEFT", b.icon, "TOPRIGHT", -5, -1)
    b.count:SetFrameLevel(b:GetFrameLevel() + 2)
    b.dot = Dot(b, 6, { 0.62, 0.62, 0.65 })
    b.dot:SetPoint("CENTER", b.icon, "TOPRIGHT", -1, -1)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        PaintBell()
        if not (tray and tray:IsShown()) then BellTip(self) end
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        PaintBell()
        GameTooltip:Hide()
    end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function()
        GameTooltip:Hide()
        NotifyUI:ToggleTray()
    end)
    bell = b
    self:UpdateBell()
    return b
end

function NotifyUI:GetBell() return bell end

---------------------------------------------------------------------------
-- The tray
---------------------------------------------------------------------------

local HEAD_H, FOOT_H = 40, 30

local function SetView(view)
    tray.view = view
    tray.segNeeds:SetKind(view == "needs" and "chosen" or "secondary")
    tray.segAll:SetKind(view == "all" and "chosen" or "secondary")
    NotifyUI:RefreshTray()
end

local function CreateTray()
    local main = ns.MainFrame and ns.MainFrame:GetFrame()
    local t = CreateFrame("Frame", "DisasterZoneNotifyTray", main or UIParent)
    t:SetFrameStrata("DIALOG")
    t:SetToplevel(true)
    t:EnableMouse(true)
    t:SetSize(NotifyUI.TRAY_W, 200)
    t:Hide()
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    local bgc = UI().DROP_BG
    t.bg:SetColorTexture(bgc[1], bgc[2], bgc[3], bgc[4])
    UI():AddEdges(t, "BORDER")
    local e = UI().DROP_EDGE
    UI():SetEdgeColor(t, e[1], e[2], e[3], e[4])

    t.title = FS(t, "GameFontNormal", nil, GOLD)
    t.title:SetPoint("LEFT", t, "TOPLEFT", 12, -HEAD_H / 2)
    t.title:SetText("Notifications")
    t.segNeeds = UI():CreateSleekButton(t, "Needs you", nil, 22, function() SetView("needs") end)
    t.segNeeds:SetPoint("LEFT", t.title, "RIGHT", 12, 0)
    t.segAll = UI():CreateSleekButton(t, "Everything", nil, 22, function() SetView("all") end)
    t.segAll:SetPoint("LEFT", t.segNeeds, "RIGHT", -1, 0)
    t.gear = UI():CreateTipIconButton(t, 22, UI().ICON.gear, "Notification settings",
        "Which kinds pop up, play a sound or write a chat line.", function()
            NotifyUI:CloseTray()
            NotifyUI:OpenSettings()
        end)
    t.gear:SetPoint("RIGHT", t, "TOPRIGHT", -9, -HEAD_H / 2)
    local rule = t:CreateTexture(nil, "BORDER")
    rule:SetColorTexture(1, 1, 1, 0.08)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -HEAD_H)
    rule:SetPoint("TOPRIGHT", -1, -HEAD_H)

    t.scroll = UI():CreateScrollFrame(t)
    t.scroll:SetPoint("TOPLEFT", 1, -HEAD_H - 1)
    t.scroll:SetPoint("BOTTOMRIGHT", -1, FOOT_H)
    t.list = CreateFrame("Frame", nil, t.scroll)
    t.list:SetSize(NotifyUI.TRAY_W - 2, 10)
    t.scroll:SetScrollChild(t.list)
    t.empty = FS(t, "GameFontHighlight", nil, GREY)
    t.empty:SetJustifyH("CENTER")
    t.empty:SetPoint("TOP", 0, -HEAD_H - 26)

    local foot = CreateFrame("Button", nil, t)
    foot:SetPoint("BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", -1, 1)
    foot:SetHeight(FOOT_H - 1)
    local frule = foot:CreateTexture(nil, "BORDER")
    frule:SetColorTexture(1, 1, 1, 0.08)
    frule:SetHeight(1)
    frule:SetPoint("TOPLEFT")
    frule:SetPoint("TOPRIGHT")
    foot.fs = FS(foot, "GameFontHighlightSmall", nil, { 0.8, 0.8, 0.8 })
    foot.fs:SetPoint("CENTER", -6, 0)
    foot.fs:SetText("All notifications")
    foot.chev = foot:CreateTexture(nil, "ARTWORK")
    foot.chev:SetSize(9, 9)
    foot.chev:SetTexture(UI().ICON_ATLAS)
    UI():SetChevron(foot.chev, true)
    foot.chev:SetVertexColor(0.8, 0.8, 0.8)
    foot.chev:SetPoint("LEFT", foot.fs, "RIGHT", 4, 0)
    foot:SetScript("OnEnter", function(self)
        self.fs:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
        self.chev:SetVertexColor(GOLD[1], GOLD[2], GOLD[3])
    end)
    foot:SetScript("OnLeave", function(self)
        self.fs:SetTextColor(0.8, 0.8, 0.8)
        self.chev:SetVertexColor(0.8, 0.8, 0.8)
    end)
    foot:SetScript("OnClick", function()
        NotifyUI:CloseTray()
        NotifyUI:OpenPage(tray.view == "needs" and "needs" or "all")
    end)
    t.foot = foot

    -- a click anywhere else closes it; Escape closes it (and only it)
    t:SetScript("OnShow", function(self)
        if C_EventUtils == nil or C_EventUtils.IsEventValid == nil or C_EventUtils.IsEventValid("GLOBAL_MOUSE_DOWN") then
            pcall(self.RegisterEvent, self, "GLOBAL_MOUSE_DOWN")
        end
        PaintBell()
    end)
    t:SetScript("OnHide", function(self)
        pcall(self.UnregisterEvent, self, "GLOBAL_MOUSE_DOWN")
        PaintBell()
    end)
    t:SetScript("OnEvent", function(self, event)
        if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() and not (bell and bell:IsMouseOver())
            and not (UI().GetOpenMenu and UI():GetOpenMenu()) then
            NotifyUI:CloseTray()
        end
    end)
    t:EnableKeyboard(true)
    t:SetScript("OnKeyDown", function(self, key)
        local esc = key == "ESCAPE"
        if self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, not esc) end
        if esc then NotifyUI:CloseTray() end
    end)
    if main then main:HookScript("OnHide", function() NotifyUI:CloseTray() end) end
    t.view = "needs"
    return t
end

function NotifyUI:RefreshTray()
    if not (tray and tray:IsShown()) then return end
    local Nf = N()
    local n = Nf:Count()
    tray.segNeeds:SetText(n > 0 and ("Needs you  " .. n) or "Needs you")
    tray.segNeeds:SetWidth(floor((tray.segNeeds:GetFontString():GetStringWidth() or 60) + 22))
    tray.segAll:SetWidth(floor((tray.segAll:GetFontString():GetStringWidth() or 60) + 22))
    local entries = Entries(tray.view)
    local close = function() NotifyUI:CloseTray() end
    local h = LayoutList(tray.list, entries, NotifyUI.TRAY_W - 2, { onOpen = close })
    tray.empty:SetText(#entries == 0 and (tray.view == "needs" and "Nothing waits for you." or "Nothing new.") or "")
    local body = #entries == 0 and 64 or h
    tray:SetHeight(min(NotifyUI.TRAY_MAX_H, HEAD_H + 1 + body + FOOT_H))
end

function NotifyUI:OpenTray(view)
    if not (N() and N():IsLoaded()) then return end
    tray = tray or CreateTray()
    local main = ns.MainFrame and ns.MainFrame:GetFrame()
    tray:ClearAllPoints()
    local inset = main and main.Inset
    if bell then
        tray:SetPoint("TOP", bell, "BOTTOM", 0, -3)
        tray:SetPoint("RIGHT", inset or main or UIParent, "RIGHT", inset and -3 or -6, 0)
    else
        tray:SetPoint("TOPRIGHT", inset or main or UIParent, "TOPRIGHT", -3, -32)
    end
    -- open on what needs you; on everything when nothing does
    tray.view = view or ((N():Count() > 0 or N():UnseenCount() == 0) and "needs" or "all")
    tray:Show()
    tray:Raise()
    SetView(tray.view)
    if UI().DropIn then
        UI():DropIn(tray, function(dx, dy)
            tray:ClearAllPoints()
            if bell then
                tray:SetPoint("TOP", bell, "BOTTOM", dx, -3 + dy)
                tray:SetPoint("RIGHT", inset or main or UIParent, "RIGHT", (inset and -3 or -6) + dx, 0)
            else
                tray:SetPoint("TOPRIGHT", inset or main or UIParent, "TOPRIGHT", -3 + dx, -32 + dy)
            end
        end)
    end
    -- opening the bell reads the news (the rows keep their dots until it closes)
    tray.readOnClose = true
end

function NotifyUI:CloseTray()
    if not (tray and tray:IsShown()) then return end
    tray:Hide()
    if tray.readOnClose then
        tray.readOnClose = false
        N():MarkAllSeen()
    end
end

function NotifyUI:ToggleTray()
    if tray and tray:IsShown() then self:CloseTray() else self:OpenTray() end
end

function NotifyUI:GetTray() return tray end

---------------------------------------------------------------------------
-- The Notifications page
---------------------------------------------------------------------------

local RAIL_W, PAD = 170, 10

local function RailItem(parent, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetHeight(26)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(1, 1, 1, 0)
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("TOPLEFT")
    b.bar:SetPoint("BOTTOMLEFT")
    b.bar:SetWidth(2)
    b.bar:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(13, 13)
    b.icon:SetPoint("LEFT", 10, 0)
    b.fs = FS(b, "GameFontHighlight", nil, { 0.85, 0.85, 0.85 })
    b.fs:SetPoint("LEFT", b.icon, "RIGHT", 8, 0)
    b.n = FS(b, "GameFontHighlightSmall", nil, DIM)
    b.n:SetJustifyH("RIGHT")
    b.n:SetPoint("RIGHT", -10, 0)
    function b:SetOn(on)
        self.on = on
        self.bar:SetShown(on)
        self.bg:SetColorTexture(1, 0.82, 0, on and 0.08 or 0)
        local c = on and { 1, 1, 1 } or { 0.85, 0.85, 0.85 }
        self.fs:SetTextColor(c[1], c[2], c[3])
    end
    b:SetScript("OnEnter", function(self) if not self.on then self.bg:SetColorTexture(1, 1, 1, 0.04) end end)
    b:SetScript("OnLeave", function(self) if not self.on then self.bg:SetColorTexture(1, 1, 1, 0) end end)
    b:SetScript("OnClick", onClick)
    return b
end

local VIEW_TEXT = {
    needs = { "Needs you", "Things that wait for your answer. They leave by themselves once handled, here or anywhere else." },
    all = { "Everything", "What waits for you and what happened, newest first. News is kept for a week." },
    done = { "Handled", "What you answered or what went away in the last week." },
}

function NotifyUI:CreatePage(parent)
    if page then return page end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    p.view = "needs"
    p.rail = CreateFrame("Frame", nil, p)
    p.rail:SetPoint("TOPLEFT", 0, -PAD)
    p.rail:SetPoint("BOTTOMLEFT", 0, PAD)
    p.rail:SetWidth(RAIL_W)
    local rule = p:CreateTexture(nil, "BORDER")
    rule:SetColorTexture(1, 1, 1, 0.08)
    rule:SetWidth(1)
    rule:SetPoint("TOPLEFT", RAIL_W, -PAD)
    rule:SetPoint("BOTTOMLEFT", RAIL_W, PAD)
    p.items = {}
    p.seps = {}

    p.head = FS(p, "GameFontNormalLarge", nil, GOLD)
    p.head:SetPoint("TOPLEFT", RAIL_W + 16, -PAD - 2)
    p.sub = FS(p, "GameFontHighlightSmall", nil, GREY)
    p.sub:SetPoint("TOPLEFT", p.head, "BOTTOMLEFT", 0, -4)
    p.sub:SetPoint("RIGHT", p, "RIGHT", -PAD - 120, 0)
    p.read = UI():CreateSleekButton(p, "Mark all read", nil, 22, function()
        N():MarkAllSeen()
        NotifyUI:RefreshPage()
    end)
    p.read:SetPoint("TOPRIGHT", -PAD - 12, -PAD - 2)
    p.scroll = UI():CreateScrollFrame(p)
    p.scroll:SetPoint("TOPLEFT", RAIL_W + 1, -PAD - 50)
    p.scroll:SetPoint("BOTTOMRIGHT", -PAD - 12, PAD)
    p.list = CreateFrame("Frame", nil, p.scroll)
    p.list:SetSize(560, 10)
    p.scroll:SetScrollChild(p.list)
    p.empty = FS(p, "GameFontHighlight", nil, GREY)
    p.empty:SetPoint("TOPLEFT", RAIL_W + 16, -PAD - 70)
    function p:OnPanelShown() NotifyUI:RefreshPage() end
    page = p
    return p
end

local function RailEntries()
    local Nf = N()
    local out = {
        { view = "needs", label = "Needs you", icon = IconIndex(BELL), n = Nf:Count(), gold = true },
        { view = "all", label = "Everything", icon = UI().ICON.notes, n = #Nf:List() },
        { sep = true },
    }
    local seen = {}
    for _, def in ipairs(Nf:GetKinds()) do
        local s = def.section
        if s and not seen[s] then
            seen[s] = true
            local n = #Nf:List({ section = s })
            if n > 0 or #Nf:ListDone({ section = s }) > 0 then
                out[#out + 1] = { view = s, label = s, def = def, n = n }
            end
        end
    end
    out[#out + 1] = { sep = true }
    out[#out + 1] = { view = "done", label = "Handled", icon = UI().ICON.notes, n = #Nf:ListDone(), dim = true }
    return out
end

function NotifyUI:RefreshPage()
    local p = page
    if not (p and p:IsVisible() and N()) then return end
    local y, ii, si = 0, 0, 0
    for _, e in ipairs(RailEntries()) do
        if e.sep then
            si = si + 1
            local s = p.seps[si]
            if not s then
                s = p.rail:CreateTexture(nil, "BORDER")
                s:SetColorTexture(1, 1, 1, 0.08)
                s:SetHeight(1)
                p.seps[si] = s
            end
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", 10, -y - 6)
            s:SetPoint("TOPRIGHT", -10, -y - 6)
            s:Show()
            y = y + 13
        else
            ii = ii + 1
            local b = p.items[ii]
            if not b then
                b = RailItem(p.rail, function(self)
                    p.view = self.view
                    NotifyUI:RefreshPage()
                end)
                p.items[ii] = b
            end
            b.view = e.view
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b:SetPoint("TOPRIGHT", 0, -y)
            if e.def then
                SetKindIcon(b.icon, e.def, nil)
            else
                b.icon:SetTexture(UI().ICON_ATLAS)
                b.icon:SetTexCoord(unpack(UI():IconCoords(e.icon)))
                local c = (e.gold and p.view == e.view) and GOLD or GREY
                b.icon:SetVertexColor(c[1], c[2], c[3])
            end
            b.fs:SetText(e.label)
            b.n:SetText((e.n or 0) > 0 and tostring(e.n) or "")
            local nc = (e.gold and (e.n or 0) > 0) and { 1, 0.86, 0.62 } or DIM
            b.n:SetTextColor(nc[1], nc[2], nc[3])
            b:SetOn(p.view == e.view)
            b:Show()
            y = y + 26
        end
    end
    for i = ii + 1, #p.items do p.items[i]:Hide() end
    for i = si + 1, #p.seps do p.seps[i]:Hide() end

    local vt = VIEW_TEXT[p.view] or { p.view, "From " .. p.view .. ": what waits for you, what happened, and what was handled this week." }
    p.head:SetText(vt[1])
    p.sub:SetText(vt[2])
    p.read:SetShown(N():UnseenCount() > 0 or N():Count({ unseen = true }) > 0)
    local w = (p.scroll:GetWidth() or 0) > 100 and floor(p.scroll:GetWidth()) or 560
    p.list:SetWidth(w)
    local entries = Entries(p.view)
    LayoutList(p.list, entries, w)
    p.empty:SetText(#entries == 0 and (p.view == "needs" and "Nothing waits for you." or "Nothing here.") or "")
end

function NotifyUI:OpenPage(view)
    if not ns.MainFrame then return end
    ns.MainFrame:Open("notify")
    if page then
        page.view = view or page.view or "needs"
        self:RefreshPage()
    end
end

function NotifyUI:GetPage() return page end

function NotifyUI:OpenSettings()
    if not ns.MainFrame then return end
    ns.MainFrame:Open("settings")
    local S = ns.SettingsUI
    if S and S.SelectSection then S:SelectSection("notify") end
end

---------------------------------------------------------------------------
-- Pop-ups
---------------------------------------------------------------------------

local function Quiet()
    local s = N().Settings()
    if s and (tonumber(s.dndUntil) or 0) > Now() then return "dnd" end
    if s and s.quietCombat ~= false and ((InCombatLockdown and InCombatLockdown()) or inEncounter) then return "combat" end
    return nil
end

local function PlayFor(def, it)
    local kit, play = _G.SOUNDKIT, _G.PlaySound
    if not (kit and play) then return end
    local snd = it.needsYou and (kit.IG_PLAYER_INVITE or kit.TELL_MESSAGE) or kit.TELL_MESSAGE
    if snd then pcall(play, snd) end
end

local function CreateToast()
    local f = CreateFrame("Frame", "DisasterZoneNotifyToast", UIParent)
    f:SetFrameStrata("DIALOG")
    f:SetSize(NotifyUI.TOAST_W, 90)
    f:SetPoint("TOP", UIParent, "TOP", 0, -112)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:Hide()
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0.05, 0.05, 0.06, 0.97)
    UI():AddEdges(f, "BORDER")
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(11, 11)
    f.icon:SetPoint("TOPLEFT", 12, -11)
    f.kicker = FS(f, "GameFontHighlightSmall", 9, GOLD)
    f.kicker:SetPoint("LEFT", f.icon, "RIGHT", 6, 0)
    f.kicker:SetPoint("RIGHT", f, "RIGHT", -64, 0)
    f.kicker:SetWordWrap(false)
    f.of = FS(f, "GameFontHighlightSmall", 10, DIM)
    f.of:SetJustifyH("RIGHT")
    f.of:SetPoint("TOPRIGHT", -30, -10)
    f.x = CreateFrame("Button", nil, f)
    f.x:SetSize(16, 16)
    f.x:SetPoint("TOPRIGHT", -8, -7)
    f.x.fs = FS(f.x, "GameFontHighlightSmall", 12, GREY)
    f.x.fs:SetPoint("CENTER", 0, 0)
    f.x.fs:SetText("×")
    f.x:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) end)
    f.x:SetScript("OnLeave", function(self) self.fs:SetTextColor(GREY[1], GREY[2], GREY[3]) end)
    f.x:SetScript("OnClick", function() NotifyUI:NextToast() end)
    f.title = FS(f, "GameFontHighlightMedium", nil, { 1, 1, 1 })
    f.title:SetWordWrap(true)
    f.text = FS(f, "GameFontHighlightSmall", nil, GREY)
    f.text:SetWordWrap(true)
    f.btns = {}
    f.later = CreateFrame("Button", nil, f)
    f.later:SetSize(44, 20)
    f.later.fs = FS(f.later, "GameFontHighlightSmall", nil, GREY)
    f.later.fs:SetPoint("RIGHT", 0, 0)
    f.later.fs:SetText("Later")
    f.later:SetScript("OnEnter", function(self) self.fs:SetTextColor(1, 1, 1) end)
    f.later:SetScript("OnLeave", function(self) self.fs:SetTextColor(GREY[1], GREY[2], GREY[3]) end)
    f.later:SetScript("OnClick", function() NotifyUI:NextToast() end)
    f.bar = f:CreateTexture(nil, "ARTWORK")
    f.bar:SetPoint("BOTTOMLEFT", 1, 1)
    f.bar:SetHeight(2)
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self.left then return end
        if self:IsMouseOver() then return end
        self.left = self.left - (elapsed or 0)
        local w = NotifyUI.TOAST_W - 2
        self.bar:SetWidth(max(1, w * max(0, self.left) / NotifyUI.INFO_SECONDS))
        if self.left <= 0 then NotifyUI:NextToast() end
    end)
    -- a click on the card (not a button) opens the item
    f:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.id then
            local id = self.id
            NotifyUI:NextToast()
            N():Open(id)
        end
    end)
    return f
end

local function Alive(id)
    local it = N():Get(id)
    return it and not N():WasShown(id) and it or nil
end

local function ShowToast(it)
    toast = toast or CreateToast()
    local f, def = toast, N():GetKind(it.kind) or {}
    f.id = it.id
    N():MarkShown(it.id)
    SetKindIcon(f.icon, def, it)
    local edge = it.needsYou and { 0.56, 0.45, 0.13 } or { 0.24, 0.24, 0.27 }
    UI():SetEdgeColor(f, edge[1], edge[2], edge[3], 1)
    local kc = it.needsYou and GOLD or { 0.74, 0.74, 0.74 }
    f.kicker:SetTextColor(kc[1], kc[2], kc[3])
    f.kicker:SetText(Kicker(def, it))
    local waiting = 0
    for _, id in ipairs(queue) do if Alive(id) then waiting = waiting + 1 end end
    f.of:SetText(waiting > 0 and ("+" .. waiting) or "")
    local tw = NotifyUI.TOAST_W - 24
    f.title:SetWidth(tw - 16)
    f.title:ClearAllPoints()
    f.title:SetPoint("TOPLEFT", 12, -27)
    f.title:SetText(it.title or "")
    local y = -27 - StrH(f.title, 16) - 3
    f.text:SetWidth(tw)
    f.text:ClearAllPoints()
    f.text:SetPoint("TOPLEFT", 12, y)
    f.text:SetText(it.text or "")
    if (it.text or "") ~= "" then y = y - StrH(f.text, 12) end
    for _, b in ipairs(f.btns) do b:Hide() end
    local acts = N():GetActions(it.id)
    if #acts == 0 and it.needsYou then
        acts = { { text = "Open", primary = true, open = true } }
    end
    if #acts > 0 then
        y = y - 9
        local bx = 12
        for i = 1, min(2, #acts) do
            local a = acts[i]
            local b = f.btns[i]
            if not b then
                b = UI():CreateSleekButton(f, "", nil, 22)
                f.btns[i] = b
            end
            b:SetText(a.text or "")
            b:SetWidth(max(72, floor((b:GetFontString():GetStringWidth() or 40) + 26)))
            b:SetKind(a.primary and "primary" or "secondary")
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", bx, y)
            local id, index, open = it.id, i, a.open
            b:SetScript("OnClick", function()
                NotifyUI:NextToast()
                if open then N():Open(id) else N():RunAction(id, index) end
            end)
            b:Show()
            bx = bx + b:GetWidth() + 8
        end
        f.later:ClearAllPoints()
        f.later:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, y - 1)
        f.later:Show()
        y = y - 22
    else
        f.later:Hide()
    end
    f:SetHeight(floor(-y + 12))
    if it.needsYou then
        f.left = nil
        f.bar:Hide()
    else
        f.left = NotifyUI.INFO_SECONDS
        f.bar:SetColorTexture(0.42, 0.42, 0.45, 1)
        f.bar:SetWidth(NotifyUI.TOAST_W - 2)
        f.bar:Show()
    end
    f:Show()
    f:Raise()
    if N():Wants(it.kind, "sound") then PlayFor(def, it) end
end

-- The next waiting pop-up (or none): the one shown leaves.
function NotifyUI:NextToast()
    if toast then
        toast:Hide()
        toast.id, toast.left = nil, nil
    end
    if Quiet() then return end
    while #queue > 0 do
        local id = table.remove(queue, 1)
        local it = Alive(id)
        if it then
            ShowToast(it)
            return
        end
    end
end

function NotifyUI:GetToast() return toast end
function NotifyUI:GetQueue() return queue end

local function Enqueue(id)
    for _, q in ipairs(queue) do if q == id then return end end
    queue[#queue + 1] = id
    if not (toast and toast:IsShown()) then NotifyUI:NextToast() end
end

-- Something new in the feed: a chat line, a pop-up or a sound, as the player chose for its kind.
function NotifyUI:OnNew(id)
    local Nf = N()
    local it = Nf and Nf:Get(id)
    local def = it and Nf:GetKind(it.kind)
    if not def or Nf:WasShown(id) then return end
    if Nf:Wants(it.kind, "chat") then
        ns:Print("%s", (it.title or "") .. ((it.text and it.text ~= "") and ("|cff9e9e9e - " .. it.text .. "|r") or ""))
    end
    local s = Nf.Settings()
    local quietOpen = s and s.quietOpen and ns.MainFrame and ns.MainFrame:IsShown()
    if Nf:Wants(it.kind, "popup") and not quietOpen and not (s and (tonumber(s.dndUntil) or 0) > Now()) then
        Enqueue(id)
    else
        Nf:MarkShown(id)
        if Nf:Wants(it.kind, "sound") and not Quiet() then PlayFor(def, it) end
    end
end

---------------------------------------------------------------------------
-- Counts on the nav strip, the minimap button and its tooltip
---------------------------------------------------------------------------

local navPills = {}

function NotifyUI:UpdateNav()
    local MF = ns.MainFrame
    if not (MF and MF.GetNavTabs and N()) then return end
    for key, tab in pairs(MF:GetNavTabs()) do
        local n = 0
        for _, pg in ipairs(MF:GetNavPages(key)) do n = n + N():Count({ page = pg }) end
        local p = navPills[tab]
        if not p and n > 0 then
            p = CountPill(tab, 12)
            p:SetFrameLevel(tab:GetFrameLevel() + 3)
            navPills[tab] = p
        end
        if p then
            p:ClearAllPoints()
            local after = tab.chevron or tab.icon or tab:GetFontString()
            if tab.icon then
                p:SetPoint("LEFT", after, "TOPRIGHT", -5, -1)
            else
                p:SetPoint("BOTTOMLEFT", after, "TOPRIGHT", -1, -6)
            end
            p:SetCount(n)
        end
    end
end

function NotifyUI:OnTabsBuilt()
    for _, p in pairs(navPills) do p:Hide() end
    wipe(navPills)
    self:UpdateNav()
end

local launcherPill
function NotifyUI:UpdateLauncher()
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    local btn = icon and icon.GetMinimapButton and icon:GetMinimapButton("DisasterZone")
    if not btn then return end
    if not launcherPill then
        launcherPill = CountPill(btn, 12)
        launcherPill:SetFrameLevel(btn:GetFrameLevel() + 5)
        launcherPill:SetPoint("CENTER", btn, "TOPRIGHT", -5, -5)
    end
    launcherPill:SetCount(N():Count())
end

-- Lines for the minimap button's tooltip: what needs you (up to five).
function NotifyUI:AddTooltipLines(tt)
    if not (tt and N() and N():IsLoaded()) then return end
    local list = N():List({ needsYou = true })
    if #list == 0 then return end
    tt:AddLine(" ")
    tt:AddLine(#list == 1 and "1 thing waits for you" or (#list .. " things wait for you"), GOLD[1], GOLD[2], GOLD[3])
    for i = 1, min(5, #list) do tt:AddLine(UI():SafeText(list[i].title or ""), 1, 1, 1, true) end
    if #list > 5 then tt:AddLine("and " .. (#list - 5) .. " more", 0.6, 0.6, 0.6) end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local refreshQueued = false
local function OnChanged()
    if refreshQueued then return end
    refreshQueued = true
    C_Timer.After(0, function()
        refreshQueued = false
        NotifyUI:UpdateBell()
        NotifyUI:UpdateNav()
        NotifyUI:UpdateLauncher()
        NotifyUI:RefreshTray()
        NotifyUI:RefreshPage()
        -- a pop-up for something handled meanwhile goes away
        if toast and toast:IsShown() and toast.id and not N():Get(toast.id) then NotifyUI:NextToast() end
    end)
end

function NotifyUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("notify", "Notifications", 3.95, function(parent) return NotifyUI:CreatePage(parent) end)
    end
    ns:On("NOTIFY_CHANGED", OnChanged)
    ns:On("NOTIFY_NEW", function(id) NotifyUI:OnNew(id) end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        C_Timer.After(1, function() if not (toast and toast:IsShown()) then NotifyUI:NextToast() end end)
    end)
    ns:RegisterEvent("ENCOUNTER_START", function() inEncounter = true end)
    ns:RegisterEvent("ENCOUNTER_END", function()
        inEncounter = false
        C_Timer.After(3, function() if not (toast and toast:IsShown()) then NotifyUI:NextToast() end end)
    end)
end

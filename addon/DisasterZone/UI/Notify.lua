if DisasterZoneBoot and DisasterZoneBoot.Run("UI/Notify.lua", ...) then return end -- DisasterZone UI/Notify.lua
-- ns.NotifyUI: everything that shows the notification center's feed (Core/Notify.lua).
--   the bell     left of the sync mark in the nav strip: a gold count of what needs you, a grey dot for news
--   the tray     drops from the bell: "Needs you" / "Everything", answers right on the rows, "All notifications"
--   the page     Notifications (no tab of its own; the tray's foot opens it): the side menu layout (UI:CreateLayout
--                "rail": sections in UI:CreateRailNav on the left), the items on the right
--   pop-ups      the shared toast (UI:Toast, one key: one at a time), queued here, "+2", never in combat
--   counts       on the nav strip's tabs (a group's pages added up) and on the minimap button
-- Sections never draw their own counts or pop-ups: they register kinds with ns.Notify.
local addonName, ns = ...

local NotifyUI = ns:NewModule("NotifyUI")

local floor, max, min = math.floor, math.max, math.min

local S = ns.Style
local function UI() return ns.UI end
local function N() return ns.Notify end

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local BELL = { 56, 42, 6 }            -- the bell (art pack 6), else the speech bubble
local DONE_TEXT = { 0.7, 0.7, 0.7 }   -- a handled item's title
local NEWS_KICK = { 0.74, 0.74, 0.74 } -- a news pop-up's kicker and edge
NotifyUI.TRAY_W, NotifyUI.TRAY_MAX_H = 392, 452
NotifyUI.TOAST_W = 380                -- (the shared toast's width, UI.TOAST.W)
NotifyUI.INFO_SECONDS = 7             -- a news pop-up stays this long (held while the mouse is on it)
NotifyUI.TOAST_KEY = "dz-notify"      -- the pop-up's UI:Toast key

local bell, tray, page
local toastId                         -- the item the pop-up shows
local advancing = false               -- (NextToast is hiding the pop-up itself: its onClose must not advance again)
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
    local c = def and def.color or S.C.GOLD
    tex:SetVertexColor(c[1], c[2], c[3])
end

local function StrH(fs, fallback)
    local h = fs.GetStringHeight and fs:GetStringHeight()
    return (h and h > 0) and h or fallback
end

-- A count: the addon's count badge (UI:CreateCountBadge). p:SetCount(n) (0 hides it).
local function CountPill(parent, h, kind)
    return UI():CreateCountBadge(parent, h, kind)
end
NotifyUI.CountPill = CountPill

local function Dot(parent, size, color)
    local t = parent:CreateTexture(nil, "OVERLAY", nil, 2)
    t:SetSize(size, size)
    t:SetTexture(DISC)
    t:SetVertexColor(S:Color(color))
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

-- A button sized to its words (at least minW).
local function FitButton(b, minW, pad)
    local fs = b:GetFontString()
    b:SetWidth(max(minW, floor(((fs and fs:GetStringWidth()) or 40) + pad)))
end

---------------------------------------------------------------------------
-- Rows (the tray and the page)
---------------------------------------------------------------------------

local TILE = 26

-- A row: the shared row looks (the hover, a hairline under it; an unseen item lifted like a list's stripe), the
-- kind's glyph in an inset tile, the kicker, when, title, text and up to two answers.
local function MakeRow(parent)
    local r = CreateFrame("Button", nil, parent)
    UI():DecorateRow(r, { stripe = true, rule = true })
    r.tile = UI():CreateCard(r, { tone = "inset", width = TILE, height = TILE })
    r.tile:SetPoint("TOPLEFT", 10, -9)
    r.icon = r.tile:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(15, 15)
    r.icon:SetPoint("CENTER")
    r.dot = Dot(r.tile, 7, "GOLD")
    r.dot:SetPoint("CENTER", r.tile, "TOPRIGHT", 0, 0)
    r.stack = CountPill(r.tile, 12, "muted")
    r.stack:SetCutout(S:Color("DROP_BG"))
    r.stack:SetPoint("LEFT", r.tile, "BOTTOMRIGHT", -6, 1)
    r.kicker = UI():Text(r, "caps", "SUB")
    r.when = UI():Text(r, "small", "SUB", { justify = "RIGHT" })
    r.title = UI():Text(r, "emph", "TEXT", { wrap = true })
    r.text = UI():Text(r, "small", "SUB", { wrap = true })
    r.btns = {}
    r:RegisterForClicks("LeftButtonUp")
    r:SetScript("OnClick", function(self)
        if self.done or not self.id then return end
        if self.onOpen then self.onOpen(self.id) end
        N():Open(self.id)
    end)
    return r
end

-- A header line between groups ("NEEDS YOU", "NEWS", "HANDLED"): the caps section header.
local function MakeHead(parent)
    return UI():CreateSectionHeader(parent, "", { style = "caps" })
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
    r:SetStripe(opts.fresh and true or false)
    if r.dzHover then r.dzHover:SetAlpha(opts.done and 0 or 1) end   -- (a handled item takes no click)
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
    r.title:SetTextColor(S:Color(opts.done and DONE_TEXT or "TEXT"))
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
                b = UI():CreateSleekButton(r, "", nil, S.ROW.compact)
                r.btns[i] = b
            end
            b:SetText(a.text or "")
            FitButton(b, 64, 24)
            b:SetHeight(S.ROW.compact)
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
        y = y - S.ROW.compact
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
            h:SetPoint("TOPLEFT", 10, -y - 6)
            h:SetWidth(w - 20)
            h:SetTitle(e.head)
            h:SetRight(e.right)
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
    UI():HideFrom(holder.rows, ri + 1)
    UI():HideFrom(holder.heads, hi + 1)
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
    local c = (tray and tray:IsShown()) and "GOLD" or (bell.hovered and { 1, 1, 1 } or "SUB")
    bell.icon:SetVertexColor(S:Color(c))
end

function NotifyUI:UpdateBell()
    if not bell or not N() then return end
    local n = N():Count()
    bell.count:SetCount(n)
    bell.dot:SetShown(n == 0 and N():UnseenCount() > 0)
    PaintBell()
end

-- The bell's tooltip (none while the tray is open).
local function BellTip(_, tt)
    if tray and tray:IsShown() then return false end
    tt:AddLine("Notifications", S:Color("GOLD"))
    local n = N() and N():Count() or 0
    if n > 0 then
        tt:AddLine(n == 1 and "1 thing waits for you." or (n .. " things wait for you."), 1, 1, 1, true)
    elseif N() and N():UnseenCount() > 0 then
        tt:AddLine("Something new to read.", 1, 1, 1, true)
    else
        tt:AddLine("Nothing new.", 1, 1, 1, true)
    end
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
    b.count = CountPill(b, 14)
    b.count:SetCutout()
    b.count:SetPoint("LEFT", b.icon, "TOPRIGHT", -7, -2)
    b.count:SetFrameLevel(b:GetFrameLevel() + 2)
    b.dot = Dot(b, 6, { 0.62, 0.62, 0.65 })
    b.dot:SetPoint("CENTER", b.icon, "TOPRIGHT", -1, -1)
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        PaintBell()
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        PaintBell()
    end)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function()
        GameTooltip:Hide()
        NotifyUI:ToggleTray()
    end)
    UI():AttachTooltip(b, BellTip, nil, { anchor = "ANCHOR_BOTTOM" })
    bell = b
    self:UpdateBell()
    return b
end

function NotifyUI:GetBell() return bell end

---------------------------------------------------------------------------
-- The tray
---------------------------------------------------------------------------

local HEAD_H, FOOT_H = 40, 30
local FOOT_TEXT = { 0.8, 0.8, 0.8 }

local function SetView(view)
    tray.view = view
    tray.seg:Select(view)
    NotifyUI:RefreshTray()
end

local function PaintFoot(foot, on)
    local c = on and "GOLD" or FOOT_TEXT
    foot.fs:SetTextColor(S:Color(c))
    foot.chev:SetVertexColor(S:Color(c))
end

local function CreateTray()
    local main = ns.MainFrame and ns.MainFrame:GetFrame()
    local t = CreateFrame("Frame", "DisasterZoneNotifyTray", main or UIParent)
    t:SetFrameStrata("DIALOG")
    t:SetToplevel(true)
    t:EnableMouse(true)
    t:SetSize(NotifyUI.TRAY_W, 200)
    t:Hide()
    t.bg = UI():Fill(t, "DROP_BG")
    UI():AddEdges(t, "BORDER")
    UI():SetEdgeColor(t, S:Color("DROP_EDGE"))

    t.title = UI():Text(t, "title", "GOLD")
    t.title:SetPoint("LEFT", t, "TOPLEFT", 12, -HEAD_H / 2)
    t.title:SetText("Notifications")
    -- Needs you / Everything: the shared segments (seg.buttons: segNeeds, segAll)
    t.seg = UI():CreateSegments(t, { { key = "needs", label = "Needs you" }, { key = "all", label = "Everything" } },
        function(key) SetView(key) end, { selected = "needs" })
    t.seg:SetPoint("LEFT", t.title, "RIGHT", 12, 0)
    t.segNeeds, t.segAll = t.seg.buttons[1], t.seg.buttons[2]
    t.gear = UI():CreateTipIconButton(t, 22, UI().ICON.gear, "Notification settings",
        "Which kinds pop up, play a sound or write a chat line.", function()
            NotifyUI:CloseTray()
            NotifyUI:OpenSettings()
        end)
    t.gear:SetPoint("RIGHT", t, "TOPRIGHT", -9, -HEAD_H / 2)
    UI():Rule(t, { top = HEAD_H, left = 1, right = 1, alpha = 0.08, layer = "BORDER" })

    t.scroll = UI():CreateScrollFrame(t)
    t.scroll:SetPoint("TOPLEFT", 1, -HEAD_H - 1)
    t.scroll:SetPoint("BOTTOMRIGHT", -1, FOOT_H)
    t.list = CreateFrame("Frame", nil, t.scroll)
    t.list:SetSize(NotifyUI.TRAY_W - 2, 10)
    t.scroll:SetScrollChild(t.list)
    t.empty = UI():CreateEmptyState(t, { compact = true, glyph = IconIndex(BELL), width = NotifyUI.TRAY_W - 60 })
    t.empty:SetPoint("TOP", 0, -HEAD_H - 16)
    t.empty:Hide()

    -- the foot: All notifications, a quiet link with a chevron across the tray's width
    -- TODO(refactor): move into PageParts (the section header's action link as UI:CreateTextLink)
    local foot = CreateFrame("Button", nil, t)
    foot:SetPoint("BOTTOMLEFT", 1, 1)
    foot:SetPoint("BOTTOMRIGHT", -1, 1)
    foot:SetHeight(FOOT_H - 1)
    UI():Rule(foot, { alpha = 0.08, layer = "BORDER" })
    foot.fs = UI():Text(foot, "small", FOOT_TEXT)
    foot.fs:SetPoint("CENTER", -6, 0)
    foot.fs:SetText("All notifications")
    foot.chev = foot:CreateTexture(nil, "ARTWORK")
    foot.chev:SetSize(9, 9)
    foot.chev:SetTexture(UI().ICON_ATLAS)
    UI():SetChevron(foot.chev, true)
    foot.chev:SetPoint("LEFT", foot.fs, "RIGHT", 4, 0)
    PaintFoot(foot, false)
    foot:SetScript("OnEnter", function(self) PaintFoot(self, true) end)
    foot:SetScript("OnLeave", function(self) PaintFoot(self, false) end)
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
    tray.seg:SetLabel("needs", n > 0 and ("Needs you  " .. n) or "Needs you")
    local entries = Entries(tray.view)
    local close = function() NotifyUI:CloseTray() end
    local h = LayoutList(tray.list, entries, NotifyUI.TRAY_W - 2, { onOpen = close })
    local none = #entries == 0
    if none then
        tray.empty:SetContent({ glyph = IconIndex(BELL),
            title = tray.view == "needs" and "Nothing waits for you." or "Nothing new." })
    end
    tray.empty:SetShown(none)
    local body = none and (tray.empty:GetHeight() + 32) or h
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
-- The Notifications page: the side menu layout (UI:CreateLayout "rail")
---------------------------------------------------------------------------

local RAIL_W = 160                    -- (+ the layout's margin: the menu's hairline sits 170 in, as before)
local RAIL_GAP = 18                   -- (UI.LAYOUT.RAIL_GAP: the body starts this far right of the hairline)

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
    local L = UI():CreateLayout("rail", p, { railWidth = RAIL_W, rowH = 26, selected = p.view,
        onSelect = function(key)
            p.view = key
            NotifyUI:RefreshPage()
        end })
    p.layout, p.rail = L, L.rail
    p.items = L.rail.buttons           -- (the menu's rows: .text, .count, .key)
    local body = L.body

    p.head = UI():Text(body, "page", "GOLD")
    p.head:SetPoint("TOPLEFT", body, "TOPLEFT", -2, -4)
    p.sub = UI():Text(body, "small", "SUB", { wrap = true })
    p.sub:SetPoint("TOPLEFT", p.head, "BOTTOMLEFT", 0, -4)
    p.sub:SetPoint("RIGHT", body, "RIGHT", -120, 0)
    p.read = UI():CreateSleekButton(body, "Mark all read", nil, S.BTN_H, function()
        N():MarkAllSeen()
        NotifyUI:RefreshPage()
    end)
    p.read:SetPoint("TOPRIGHT", body, "TOPRIGHT", -12, -2)
    -- the items run from the menu's hairline to the page's edge
    p.scroll = UI():CreateScrollFrame(body)
    p.scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 1 - RAIL_GAP, -50)
    p.scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -12, 0)
    p.list = CreateFrame("Frame", nil, p.scroll)
    p.list:SetSize(560, 10)
    p.scroll:SetScrollChild(p.list)
    -- (the list takes the scroll frame's width once the page is laid out)
    p.scroll:HookScript("OnSizeChanged", function() NotifyUI:RefreshPage() end)
    p.empty = UI():CreateEmptyState(body, { compact = true, glyph = IconIndex(BELL) })
    p.empty:SetPoint("TOP", p.scroll, "TOP", 0, -30)
    p.empty:Hide()
    function p:OnPanelShown() NotifyUI:RefreshPage() end
    page = p
    return p
end

-- The side menu's items: Needs you, Everything | the sections with something | Handled.
local function RailItems()
    local Nf = N()
    local out = {
        { key = "needs", label = "Needs you", icon = IconIndex(BELL), count = Nf:Count(), gold = true },
        { key = "all", label = "Everything", icon = UI().ICON.notes, count = #Nf:List() },
        { sep = true },
    }
    local seen = {}
    for _, def in ipairs(Nf:GetKinds()) do
        local s = def.section
        if s and not seen[s] then
            seen[s] = true
            local n = #Nf:List({ section = s })
            if n > 0 or #Nf:ListDone({ section = s }) > 0 then
                out[#out + 1] = { key = s, label = s, count = n, icon = function(tex) SetKindIcon(tex, def, nil) end }
            end
        end
    end
    out[#out + 1] = { sep = true }
    out[#out + 1] = { key = "done", label = "Handled", icon = UI().ICON.notes, count = #Nf:ListDone(), dim = true }
    return out
end

function NotifyUI:RefreshPage()
    local p = page
    if not (p and p:IsVisible() and N()) then return end
    p.rail:SetItems(RailItems())
    p.rail:Select(p.view)

    local vt = VIEW_TEXT[p.view] or { p.view, "From " .. p.view .. ": what waits for you, what happened, and what was handled this week." }
    p.head:SetText(vt[1])
    p.sub:SetText(vt[2])
    p.read:SetShown(N():UnseenCount() > 0 or N():Count({ unseen = true }) > 0)
    local w = (p.scroll:GetWidth() or 0) > 100 and floor(p.scroll:GetWidth()) or 560
    p.list:SetWidth(w)
    local entries = Entries(p.view)
    LayoutList(p.list, entries, w)
    if #entries == 0 then
        p.empty:SetContent({ glyph = IconIndex(BELL),
            title = p.view == "needs" and "Nothing waits for you." or "Nothing here." })
        p.empty:Show()
    else
        p.empty:Hide()
    end
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
    local SU = ns.SettingsUI
    if SU and SU.SelectSection then SU:SelectSection("notify") end
end

---------------------------------------------------------------------------
-- Pop-ups: the shared toast (UI:Toast) under one key, one at a time; the queue is kept here
---------------------------------------------------------------------------

local function Quiet()
    local s = N().Settings()
    if s and (tonumber(s.dndUntil) or 0) > ns.Util.Now() then return "dnd" end
    if s and s.quietCombat ~= false and ((InCombatLockdown and InCombatLockdown()) or inEncounter) then return "combat" end
    return nil
end

local function PlayFor(def, it)
    local kit, play = _G.SOUNDKIT, _G.PlaySound
    if not (kit and play) then return end
    local snd = it.needsYou and (kit.IG_PLAYER_INVITE or kit.TELL_MESSAGE) or kit.TELL_MESSAGE
    if snd then pcall(play, snd) end
end

local function Alive(id)
    local it = N():Get(id)
    return it and not N():WasShown(id) and it or nil
end

-- The pop-up on screen (the shared toast frame while it shows a notification), or nil.
local function Shown() return UI():GetToast(NotifyUI.TOAST_KEY) end

-- The pop-up went (its X, Later, a button, a click on it, its time): the next one comes.
local function OnToastClose(t)
    toastId = nil
    if t and t.icon then t.icon:SetVertexColor(1, 1, 1) end   -- (the frame is shared: no tint left for the next)
    if not advancing then NotifyUI:NextToast() end
end

-- "+2": how many more wait, at the top right (a piece of ours in the toast's slot).
local function SetWaiting(t, waiting)
    local fs = t.dzNotifyOf
    if not fs then
        fs = UI():Text(t.slot, "small", "SUB", { justify = "RIGHT" })
        fs:SetPoint("TOPRIGHT", t, "TOPRIGHT", -24, -10)
        t.dzNotifyOf = fs
    end
    fs:SetText(waiting > 0 and ("+" .. waiting) or "")
    fs:SetShown(waiting > 0)
end

local function ShowToast(it)
    local def = N():GetKind(it.kind) or {}
    local id = it.id
    toastId = id
    N():MarkShown(id)
    local waiting = 0
    for _, q in ipairs(queue) do if Alive(q) then waiting = waiting + 1 end end
    local buttons = {}
    local acts = N():GetActions(id)
    if #acts == 0 and it.needsYou then
        acts = { { text = "Open", primary = true, open = true } }
    end
    for i = 1, min(2, #acts) do
        local a, index = acts[i], i
        buttons[#buttons + 1] = { text = a.text or "", kind = a.primary and "primary" or "secondary",
            onClick = function()
                if a.open then N():Open(id) else N():RunAction(id, index) end
            end }
    end
    local later
    if #buttons > 0 then
        later = { text = "Later", kind = "link", onClick = function() end }
        buttons[#buttons + 1] = later
    end
    local kicker = Kicker(def, it)
    local t = UI():Toast({
        key = NotifyUI.TOAST_KEY,
        kind = it.needsYou and "info" or NEWS_KICK,
        icon = UI().ICON_ATLAS, iconSize = 14, iconCoords = UI():IconCoords(UI().ICON.notes),
        kicker = kicker, title = it.title or "", text = (it.text or "") ~= "" and it.text or nil,
        buttons = buttons, buttonRow = true,
        duration = it.needsYou and 0 or NotifyUI.INFO_SECONDS,
        timeBar = not it.needsYou,
        -- a click on the card (not a button) opens the item
        onClick = function() N():Open(id) end,
        onClose = OnToastClose,
    })
    if t then
        SetKindIcon(t.icon, def, it)
        t.kick:SetText(kicker)                         -- (as it is: the sender's name keeps its colour and case)
        SetWaiting(t, waiting)
        -- (the fields the harness reads: the shared toast's own under the old names)
        t.kicker, t.x, t.later = t.kick, t.close, later and t.links[1] or nil
    end
    if N():Wants(it.kind, "sound") then PlayFor(def, it) end
end

-- The next waiting pop-up (or none): the one shown leaves.
function NotifyUI:NextToast()
    local t = Shown()
    if t then
        advancing = true
        UI():HideToast(t, "next")
        advancing = false
    end
    toastId = nil
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

function NotifyUI:GetToast() return Shown() end
function NotifyUI:GetQueue() return queue end

local function Enqueue(id)
    for _, q in ipairs(queue) do if q == id then return end end
    queue[#queue + 1] = id
    if not (Shown() or toastId) then NotifyUI:NextToast() end
end

-- Something new in the feed: a chat line, a pop-up or a sound, as the player chose for its kind.
function NotifyUI:OnNew(id)
    local Nf = N()
    local it = Nf and Nf:Get(id)
    local def = it and Nf:GetKind(it.kind)
    if not def or Nf:WasShown(id) then return end
    if Nf:Wants(it.kind, "chat") then
        ns:Print("%s", (it.title or "") .. ((it.text and it.text ~= "") and (S:Hex("GREY") .. " - " .. it.text .. "|r") or ""))
    end
    local s = Nf.Settings()
    local quietOpen = s and s.quietOpen and ns.MainFrame and ns.MainFrame:IsShown()
    if Nf:Wants(it.kind, "popup") and not quietOpen and not (s and (tonumber(s.dndUntil) or 0) > ns.Util.Now()) then
        Enqueue(id)
    else
        Nf:MarkShown(id)
        if Nf:Wants(it.kind, "sound") and not Quiet() then PlayFor(def, it) end
    end
end

---------------------------------------------------------------------------
-- Counts on the nav strip, the minimap button and its tooltip
---------------------------------------------------------------------------

-- (the strip's tabs carry their own badge: UI:SetNavCount)
function NotifyUI:UpdateNav()
    local MF = ns.MainFrame
    if not (MF and MF.GetNavTabs and N()) then return end
    for key, tab in pairs(MF:GetNavTabs()) do
        local n = 0
        for _, pg in ipairs(MF:GetNavPages(key)) do n = n + N():Count({ page = pg }) end
        UI():SetNavCount(tab, n)
    end
end

function NotifyUI:OnTabsBuilt()
    self:UpdateNav()
end

local launcherPill
function NotifyUI:UpdateLauncher()
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    local btn = icon and icon.GetMinimapButton and icon:GetMinimapButton("DisasterZone")
    if not btn then return end
    if not launcherPill then
        launcherPill = CountPill(btn, 14)
        launcherPill:SetCutout(0.05, 0.05, 0.06)
        launcherPill:SetFrameLevel(btn:GetFrameLevel() + 5)
        launcherPill:SetPoint("LEFT", btn, "TOPRIGHT", -12, -6)
    end
    launcherPill:SetCount(N():Count())
end

-- Lines for the minimap button's tooltip: what needs you (up to five).
function NotifyUI:AddTooltipLines(tt)
    if not (tt and N() and N():IsLoaded()) then return end
    local list = N():List({ needsYou = true })
    if #list == 0 then return end
    tt:AddLine(" ")
    tt:AddLine(#list == 1 and "1 thing waits for you" or (#list .. " things wait for you"), S:Color("GOLD"))
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
        if Shown() and toastId and not N():Get(toastId) then NotifyUI:NextToast() end
    end)
end

function NotifyUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("notify", "Notifications", 3.95, function(parent) return NotifyUI:CreatePage(parent) end,
            nil, { layout = "rail" })
    end
    ns:On("NOTIFY_CHANGED", OnChanged)
    ns:On("NOTIFY_NEW", function(id) NotifyUI:OnNew(id) end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        C_Timer.After(1, function() if not (Shown() or toastId) then NotifyUI:NextToast() end end)
    end)
    ns:RegisterEvent("ENCOUNTER_START", function() inEncounter = true end)
    ns:RegisterEvent("ENCOUNTER_END", function()
        inEncounter = false
        C_Timer.After(3, function() if not (Shown() or toastId) then NotifyUI:NextToast() end end)
    end)
end

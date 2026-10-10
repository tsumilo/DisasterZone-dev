if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PollsTab.lua", ...) then return end -- DisasterZone: UI/PollsTab.lua
-- Guild > Polls (Core/Polls.lua): the polls that ask me and the ones I asked.
--   List:  Open | Closed tabs (Open counts the polls waiting for me), New poll for the GM / officers / guild council.
--          Open: Waiting for you (Yes / No answered on the row, the rest open the poll), Answered (the leading answer,
--          or a lock until the close), Your polls (answered n / m, the ··· menu). Closed: every closed poll I see.
--   Poll:  the question with its kind, closing time, asker and who it asks; the answers to click (one: a dot, several:
--          check boxes) and Vote; after voting (or when results are live) every answer with its count, bar and the
--          names of who picked it. The card at the right: who has answered (names, not picks), or for the asker the
--          people who haven't with Nudge them, Close now and Extend. Pick days: my row on top (click a night for can,
--          again for if needed, again for can't), everyone's rows under it, the totals line, the best night framed.
--   New poll: the question, the kind (four tiles), the answers (Pick days: a calendar and a start time per day), when
--          it closes, when results show, whether answers can change; "Who votes": chips over a search list of
--          everyone, teams (and lineups), roles, ranks and players; the count of people asked; a preview.
-- The pop-up (PollsUI.Toast): when a poll that asks me arrives, at login for one I haven't seen, or when its asker
-- nudges me. Yes / No is answered right there; the rest open the poll. Never in combat: it waits until combat ends.
-- Test / audit hooks at the end of the file.
local addonName, ns = ...

local PollsUI = ns:NewModule("PollsUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local tsort, tconcat = table.sort, table.concat
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber

local DAY = 86400
local PAD, GAP = 10, 8
local PAGE_W, PAGE_H = 790, 548
local NUM_FONT = "Fonts\\ARIALN.TTF"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local CHECK_GLYPH = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\check"
local ROW_H = 52                     -- a poll in the list
local TABS_H = 30
local LEFT_W = 450                   -- the poll page's answers column
local CARD_X = LEFT_W + 30           -- its card
local SHEET_L = 480                  -- the new poll sheet's left column
local ANS_H, ANS_GAP = 32, 6
local NAME_COL = 150                 -- Pick days: the names column
local CELL_GAP = 4
local MAX_LIST_ROWS = 60

local C = {
    gold = { 1, 0.82, 0 }, white = { 1, 1, 1 }, text = { 0.88, 0.88, 0.88 }, grey = { 0.62, 0.62, 0.62 },
    dim = { 0.55, 0.55, 0.57 }, faint = { 0.33, 0.33, 0.35 }, green = { 0.47, 0.83, 0.54 }, red = { 1, 0.45, 0.4 },
    can = { 0.12, 0.23, 0.14, 1 }, canEdge = { 0.18, 0.42, 0.23, 1 }, maybe = { 0.23, 0.2, 0.09, 1 },
    maybeEdge = { 0.48, 0.39, 0.13, 1 }, no = { 0.09, 0.09, 0.11, 1 }, noEdge = { 0.14, 0.14, 0.16, 1 },
    bar = { 0.82, 0.64, 0.03 }, track = { 0.16, 0.16, 0.18 }, pick = { 0.15, 0.14, 0.08, 1 },
    pickEdge = { 0.54, 0.45, 0.13, 1 }, row = { 0.09, 0.09, 0.11, 1 }, rowEdge = { 0.17, 0.17, 0.2, 1 },
}
local CARD = { 0.075, 0.075, 0.09, 1 }
local CARD_EDGE = { 0.19, 0.19, 0.22, 1 }

local panel
local state = { view = "list", tab = "open", poll = nil, pick = {}, days = nil, changing = false, draft = nil }

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function P() return ns.Polls end
local function Now() return (GetServerTime and GetServerTime()) or time() end
local function Me() return ns.Util.PlayerKey() end
local function IsMe(key) return type(key) == "string" and ns.Util.IsMe(key) or false end

local function Hex(c, s)
    return ("|cff%02x%02x%02x%s|r"):format(floor(c[1] * 255 + 0.5), floor(c[2] * 255 + 0.5), floor(c[3] * 255 + 0.5),
        tostring(s))
end
local function white(s) return Hex(C.white, s) end
local function Name(key) return EUI():Name(key) end
local function Tip(owner, lines) UI():SetTextTooltip(owner, lines, "ANCHOR_TOP") end
local function HideTip() GameTooltip:Hide() end
local function Plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

-- The poll icon (art pack 6), else the notes icon.
local function PollIcon() return ns:HasAssets(6) and UI().ICON.poll or UI().ICON.notes end

---------------------------------------------------------------------------
-- Small pieces
---------------------------------------------------------------------------

local function Sized(fs, size, path)
    local p, _, flags = fs:GetFont()
    fs:SetFont(path or p or "Fonts\\FRIZQT__.TTF", size, flags or "")
    return fs
end

local function Text(parent, size, color, num, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    Sized(fs, size or 12, num and NUM_FONT or nil)
    local c = color or C.white
    fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    return fs
end

local function Color(fs, c) fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end

local function Fill(f, c, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function Edges(f, c, layer)
    UI():AddEdges(f, layer or "BORDER")
    UI():SetEdgeColor(f, c[1], c[2], c[3], c[4] or 1)
end

local function Line(parent, c, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function TextW(fs) return EUI():TextWidth(fs) end

-- A wrapped text w wide: returns its height.
local function Wrap(fs, text, w, size)
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    fs:SetWidth(w)
    fs:SetText(text or "")
    local real = fs:GetStringHeight() or 0
    local uw = TextW(fs)
    local lines = max(1, ceil(uw / max(1, w)))
    local h = ceil(max(real, lines * ((size or 12) + 3)))
    fs:SetHeight(h)
    return h
end

local function Glyph(tex, idx, c)
    c = c or { 1, 1, 1 }
    if type(idx) == "string" then
        tex:SetTexture(idx)
        tex:SetTexCoord(0, 1, 0, 1)
    else
        local co = UI():IconCoords(idx)
        tex:SetTexture(UI().ICON_ATLAS)
        tex:SetTexCoord(co[1], co[2], co[3], co[4])
    end
    tex:SetVertexColor(c[1], c[2], c[3], c[4] or 1)
end

-- A flat button; glyph: an atlas index or a texture before the text.
local function Button(parent, text, w, h, kind, onClick, glyph)
    local b = UI():CreateSleekButton(parent, text, w, h, onClick, kind)
    local fs = b:GetFontString()
    if (h or 22) <= 20 then Sized(fs, 10) elseif (h or 22) <= 22 then Sized(fs, 11) end
    if glyph then
        b.glyph = b:CreateTexture(nil, "OVERLAY")
        b.glyph:SetSize(11, 11)
        Glyph(b.glyph, glyph, { 0.92, 0.92, 0.92, 0.9 })
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", 7, 0)
        b.glyph:SetPoint("RIGHT", fs, "LEFT", -5, 0)
    end
    return b
end

local function FitButton(b, minW)
    local w = (b:GetFontString():GetStringWidth() or 0) + 24 + (b.glyph and 16 or 0)
    b:SetWidth(max(minW or 0, ceil(w)))
    return b:GetWidth()
end

-- A section title over a hairline (the Events list's).
local function Sect(parent)
    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(100, 24)
    s.t = Text(s, 12, C.gold)
    s.t:SetPoint("BOTTOMLEFT", 2, 7)
    s.r = Text(s, 10, C.dim)
    s.r:SetJustifyH("RIGHT")
    s.r:SetPoint("BOTTOMRIGHT", -2, 7)
    s.line = Line(s, { 1, 1, 1, 0.08 })
    s.line:SetHeight(1)
    s.line:SetPoint("BOTTOMLEFT")
    s.line:SetPoint("BOTTOMRIGHT")
    function s:Set(t, r)
        self.t:SetText(t or "")
        self.r:SetText(r or "")
        self:Show()
    end
    return s
end

-- The back link of the Raids page ("< ALL RAIDS"): back to the list.
local function BackLink(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(80, 14)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(10, 10)
    b.icon:SetPoint("LEFT", 0, 0)
    UI():SetChevron(b.icon, false)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetJustifyH("LEFT")
    Sized(b.text, 10)
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
    b.text:SetText("ALL POLLS")
    local function paint(self, on)
        local r, g, bl = 0.65, 0.65, 0.65
        if on then r, g, bl = 1, 0.82, 0 end
        self.text:SetTextColor(r, g, bl)
        self.icon:SetVertexColor(r, g, bl)
    end
    paint(b, false)
    b:SetScript("OnEnter", function(self) paint(self, true) end)
    b:SetScript("OnLeave", function(self) paint(self, false) end)
    b:SetScript("OnClick", function() PollsUI:ShowList() end)
    return b
end

-- A class circle of a member.
local function Face(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    function f:Set(key)
        self.key = key
        EUI():SetClass(self.tex, key)
        self:Show()
    end
    return f
end

local function Pool(list, i, make)
    local x = list[i]
    if not x then
        x = make()
        list[i] = x
    end
    return x
end

local function HideFrom(list, i)
    for j = i, #list do list[j]:Hide() end
end

-- A rounded chip (the poll page's targets, the sheet's picks).
local function Chip(parent, h, removable)
    h = h or 17
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(h)
    UI():AddPillShape(c, h)
    c.glyph = c:CreateTexture(nil, "ARTWORK")
    c.glyph:SetSize(h - 7, h - 7)
    c.glyph:SetPoint("LEFT", 7, 0)
    c.fs = Text(c, h >= 20 and 11 or 10, C.text)
    c.fs:SetPoint("LEFT", c.glyph, "RIGHT", 4, 0)
    c.n = Text(c, h >= 20 and 11 or 10, C.dim, true)
    c.n:SetPoint("LEFT", c.fs, "RIGHT", 4, 0)
    if removable then
        c.x = c:CreateTexture(nil, "ARTWORK")
        c.x:SetSize(7, 7)
        c.x:SetTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
        c.x:SetVertexColor(0.85, 0.75, 0.45)
    end
    function c:Set(text, glyph, n, on, face)
        self.fs:SetText(text or "")
        self.n:SetText(n and tostring(n) or "")
        if face then
            EUI():SetClass(self.glyph, face)
            self.glyph:SetVertexColor(1, 1, 1, 1)
        elseif glyph then
            Glyph(self.glyph, glyph, on and { 0.95, 0.85, 0.54 } or { 0.74, 0.74, 0.74 })
        end
        self.glyph:SetShown(glyph ~= nil or face ~= nil)
        if on then
            self:SetPillColors({ 0.18, 0.15, 0.09, 1 }, { 0.54, 0.45, 0.13, 1 })
            Color(self.fs, { 0.95, 0.85, 0.54 })
        else
            self:SetPillColors({ 0.11, 0.11, 0.13, 1 }, { 0.23, 0.23, 0.26, 1 })
            Color(self.fs, C.text)
        end
        local w = 7 + ((glyph or face) and (self.glyph:GetWidth() + 4) or 0) + TextW(self.fs) + 8
        if n then w = w + 4 + TextW(self.n) end
        if self.x then
            self.x:ClearAllPoints()
            self.x:SetPoint("LEFT", n and self.n or self.fs, "RIGHT", 6, 0)
            w = w + 12
        end
        self:SetWidth(ceil(w))
        self:Show()
        return self:GetWidth()
    end
    return c
end

-- A thin bar: b:Set(share) (0..1).
local function Bar(parent, h, color)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(h or 4)
    b.track = Fill(b, C.track, "BACKGROUND")
    b.fill = b:CreateTexture(nil, "ARTWORK")
    b.fill:SetPoint("TOPLEFT")
    b.fill:SetPoint("BOTTOMLEFT")
    local c = color or C.bar
    b.fill:SetColorTexture(c[1], c[2], c[3], 1)
    function b:Set(share, w)
        share = max(0, min(1, share or 0))
        b.fill:SetWidth(max(0.01, (w or self:GetWidth() or 100) * share))
        b.fill:SetShown(share > 0)
    end
    return b
end

---------------------------------------------------------------------------
-- Words
---------------------------------------------------------------------------

local KIND_WORD = { one = "One answer", many = "Several answers", yn = "Yes or no", days = "Pick days" }

local function KindGlyph(kind)
    if kind == "days" then return UI().ICON.calendar end
    if kind == "yn" then return CHECK_GLYPH end
    return PollIcon()
end

-- "today 20:00", "tomorrow", "Sun 20:00", "Fri 17 Oct"
local function When(t, withTime)
    local now = Now()
    local d0 = date("*t", now)
    local today = time({ year = d0.year, month = d0.month, day = d0.day, hour = 0 })
    local clock = date("%H:%M", t)
    if t >= today and t < today + DAY then return "today " .. clock end
    if t >= today + DAY and t < today + 2 * DAY then return withTime and ("tomorrow " .. clock) or "tomorrow" end
    if t > now - 6 * DAY and t < now + 6 * DAY then return date("%a", t) .. " " .. clock end
    return date("%a %d %b", t)
end

local function ClosesWord(p)
    if P():IsOpen(p) then return "closes " .. white(When(p.cl, true)) end
    return "closed " .. white(When(p.cl))
end

local function TargetsWord(p)
    local names = {}
    for _, t in ipairs(p.a or {}) do names[#names + 1] = P():TargetName(t) end
    if #names == 0 then return Plural(#p.m, "player") end
    if #names > 3 then return names[1] .. ", " .. names[2] .. " +" .. (#names - 2) end
    return tconcat(names, ", ")
end

local function TargetGlyph(t)
    if t[1] == "t" then return UI().ICON.team end
    if t[1] == "r" then return UI().ICON.crown end
    if t[1] == "k" then return UI().ICON.notes end
    if t[1] == "g" then return UI().ICON.team end
    return nil
end

local function AnswerText(p, i)
    if p.k == "days" then
        local d, tm = P():DayLabel(p.o[i])
        return d .. (tm and (" " .. tm) or "")
    end
    return p.o[i] or "?"
end

-- The leading answer of a poll ("Thursday", 47) or nil.
local function Leading(p, res)
    local best, bi = -1, nil
    for i = 1, #p.o do
        local n = res.counts[i] or 0
        if n > best then best, bi = n, i end
    end
    if not bi or best <= 0 then return nil end
    if p.k == "days" and res.best then bi = res.best end
    local share = res.answered > 0 and floor((res.counts[bi] or 0) * 100 / res.answered + 0.5) or 0
    return AnswerText(p, bi), share
end

---------------------------------------------------------------------------
local function ManageMenu(owner, p)
    UI():ContextMenu(owner, function(root)
        if IsMe(p.by) and P():IsOpen(p) then
            root:CreateButton("Close now", function() P():Close(p.id) end)
            root:CreateButton("Extend a day", function() P():Extend(p.id, DAY) end)
        elseif IsMe(p.by) then
            root:CreateButton("Open again for a day", function() P():Extend(p.id, DAY) end)
        end
        if P():CanManage(p) then
            local b = root:CreateButton("|cffff7766Remove|r", function()
                P():Delete(p.id)
                if state.poll == p.id then PollsUI:ShowList() end
            end)
            b:SetTooltip(function(tt)
                tt:AddLine("Remove the poll")
                tt:AddLine("It goes for everyone, answers included.", 1, 1, 1, true)
            end)
        end
    end)
end

---------------------------------------------------------------------------
-- The banner (the Events / Raids pages' look): the poll's art under a shade, its icon tile, the question, who asked
-- whom, a stack of who answered with a bar, when it closes, and what I can do.
---------------------------------------------------------------------------

local BAN_LIST_H, BAN_PAGE_H = 132, 150
local KIND_ICON = { one = "Interface\\Icons\\INV_Scroll_03", many = "Interface\\Icons\\INV_Misc_Note_05",
                    yn = "Interface\\Icons\\INV_Misc_Coin_01", days = "Interface\\Icons\\INV_Misc_PocketWatch_01" }
local THEMES = { "kara", "gruul", "mag", "ssc", "tk", "hyjal", "bt", "za", "swp" }
local FACE_RING = { 0, 0, 0, 1 }
local SEG_ON, SEG_ON_EDGE = { 0.11, 0.33, 0.14, 1 }, { 0.26, 0.74, 0.31, 1 }

-- A poll's art: the theme of the first team it asks, else one picked from its id (so it stays put).
local function ArtKey(p)
    local R = ns.RaidPlan
    for _, t in ipairs(p and p.a or {}) do
        if t[1] == "t" then
            local team = R and R.GetTeam and R:GetTeam(t[2])
            if team and team.theme then return team.theme end
            local n = 0
            for i = 1, #t[2] do n = n + t[2]:byte(i) end
            return THEMES[n % #THEMES + 1]
        end
    end
    local id = p and p.id or "x"
    local n = 0
    for i = 1, #id do n = n + id:byte(i) end
    return THEMES[n % #THEMES + 1]
end

local function SetArt(tex, p, w, h, fw)
    local PUI = ns.RaidPlanUI
    if PUI and PUI.RaidArt then
        local file, l, r, t, b = PUI:RaidArt(ArtKey(p), w, h, fw or 0.95)
        if t < 0.28 then                                     -- (under the game's logo)
            local d = min(0.28 - t, 0.98 - b)
            t, b = t + d, b + d
        end
        tex:SetTexture(file)
        tex:SetTexCoord(l, r, t, b)
    else
        tex:SetColorTexture(0.12, 0.12, 0.14, 1)
    end
end

-- An icon tile (an item icon with its dark edge and a gold ring, the event icons' look).
local function IconTile(parent, size, ring)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.outer = Fill(f, { 0, 0, 0, 1 }, "BACKGROUND")
    f.outer:ClearAllPoints()
    f.outer:SetPoint("TOPLEFT", -1, 1)
    f.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    if ring then
        f.ring = Fill(f, ring, "BACKGROUND", -1)
        f.ring:ClearAllPoints()
        f.ring:SetPoint("TOPLEFT", -2, 2)
        f.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    end
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    function f:Set(kind) self.tex:SetTexture(KIND_ICON[kind] or KIND_ICON.one) end
    return f
end

-- A class circle with its dark ring (the Duelists list's).
local function RingFace(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.ring = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.ring:SetTexture(DISC)
    f.ring:SetSize(size + 3, size + 3)
    f.ring:SetPoint("CENTER")
    f.ring:SetVertexColor(FACE_RING[1], FACE_RING[2], FACE_RING[3], 1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    function f:Set(key)
        self.key = key
        EUI():SetClass(self.tex, key)
        self:Show()
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        if not self.key then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(EUI():Name(self.key, true))
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", HideTip)
    return f
end

-- A pill on the art: a glyph and a few words.
local function ArtChip(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetHeight(22)
    UI():AddPillShape(c, 22)
    c:SetPillColors({ 0.04, 0.04, 0.05, 0.78 }, { 1, 1, 1, 0.2 })
    c.glyph = c:CreateTexture(nil, "ARTWORK")
    c.glyph:SetSize(12, 12)
    c.glyph:SetPoint("LEFT", 9, 0)
    c.fs = Text(c, 11, { 0.91, 0.91, 0.91 })
    c.fs:SetPoint("LEFT", c.glyph, "RIGHT", 6, 0)
    function c:Set(text, glyph, color)
        self.fs:SetText(text)
        Glyph(self.glyph, glyph or UI().ICON.calendar, color or { 0.86, 0.86, 0.86 })
        self:SetWidth(ceil(9 + 12 + 6 + TextW(self.fs) + 11))
        self:Show()
    end
    return c
end

-- The answer bar (the raid page's Accept / Tentative): a dark band, the picked answer green.
local function SegBar(parent, h)
    local s = CreateFrame("Frame", nil, parent)
    s:SetHeight(h or 24)
    s.bg = Fill(s, { 0.07, 0.08, 0.09, 0.82 })
    s.opts = {}
    function s:Set(labels, picked, onPick, minW)
        local x = 0
        for i, label in ipairs(labels) do
            local b = self.opts[i]
            if not b then
                b = CreateFrame("Button", nil, self)
                b.fill = Fill(b, SEG_ON, "BACKGROUND", 1)
                UI():AddEdges(b, "BORDER")
                b.fs = Text(b, 12, C.text)
                b.fs:SetJustifyH("CENTER")
                b.fs:SetPoint("CENTER", 0, 0)
                b.hl = b:CreateTexture(nil, "HIGHLIGHT")
                b.hl:SetAllPoints()
                b.hl:SetColorTexture(1, 1, 1, 0.05)
                self.opts[i] = b
            end
            b.fs:SetText(label)
            local w = max(minW or 64, ceil(TextW(b.fs) + 30))
            b:SetSize(w, self:GetHeight())
            b:ClearAllPoints()
            b:SetPoint("LEFT", self, "LEFT", x, 0)
            local on = picked == i
            b.fill:SetShown(on)
            UI():SetEdgeColor(b, SEG_ON_EDGE[1], SEG_ON_EDGE[2], SEG_ON_EDGE[3], on and 1 or 0)
            Color(b.fs, on and C.white or { 0.82, 0.82, 0.82 })
            b:SetScript("OnClick", function() if onPick then onPick(i) end end)
            b:Show()
            x = x + w
        end
        for i = #labels + 1, #self.opts do self.opts[i]:Hide() end
        self:SetWidth(x)
        self:Show()
        return x
    end
    return s
end

local function Banner(parent, h, page)
    local b = CreateFrame("Frame", nil, parent)
    b:SetHeight(h)
    b.art = b:CreateTexture(nil, "BACKGROUND")
    b.art:SetAllPoints()
    EUI():AddShade(b)
    EUI():Edge(b)
    local top = 14
    if page then
        b.back = BackLink(b)
        b.back:SetPoint("TOPLEFT", 16, -11)
        top = 36
    end
    b.kick = Text(b, 10, C.gold)
    b.kick:SetPoint("TOPLEFT", 14, -14)
    b.icon = IconTile(b, 46, { 1, 0.82, 0.36, 0.85 })
    b.icon:SetPoint("TOPLEFT", 14, -top)
    b.q = Text(b, 19, C.white)
    b.q:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 12, -2)
    b.pill = EUI():CreatePill(b, 17)
    b.meta = Text(b, 11, { 0.86, 0.86, 0.86 })
    b.meta:SetPoint("TOPLEFT", b.q, "BOTTOMLEFT", 0, -6)
    b.faces = {}
    b.count = Text(b, 11, { 0.86, 0.86, 0.86 })
    b.bar = Bar(b, 4, C.green)
    b.bar:SetWidth(120)
    b.chip = ArtChip(b)
    b.btn = Button(b, "Answer", 70, 25, "primary")
    b.seg = SegBar(b, 25)
    b.segLab = Text(b, 9, { 0.86, 0.86, 0.86 })
    b.segLab:SetText("YOUR ANSWER")
    b.more = UI():CreateTipIconButton(b, 22, UI().ICON.more, "More", "Close, extend or remove the poll.", function(self)
        local p = P():GetPoll(self:GetParent().pid)
        if p then ManageMenu(self, p) end
    end)
    b.more:SetPoint("TOPRIGHT", -12, -12)
    return b
end

-- Fills a banner for poll p. mode "list" (the poll waiting for me on the list) | "page" (the poll's own page).
local function FillBanner(b, p, mode, w)
    local Pl = P()
    b.pid = p.id
    w = w or (PAGE_W - 2 * PAD)
    SetArt(b.art, p, w, b:GetHeight())
    b.icon:Set(p.k)
    local open = Pl:IsOpen(p)
    if mode == "list" then
        b.kick:SetText(("Waiting for you · " .. KIND_WORD[p.k] .. " · closes " .. When(p.cl, true)):upper())
        b.kick:Show()
        b.icon:ClearAllPoints()
        b.icon:SetPoint("TOPLEFT", 14, -34)
    else
        b.kick:Hide()
    end
    b.q:SetText(p.q)
    local res = Pl:Results(p)
    local meta = { KIND_WORD[p.k] }
    meta[#meta + 1] = (IsMe(p.by) and "asked by you" or ("asked by " .. Name(p.by)))
    meta[#meta + 1] = TargetsWord(p)
    if mode == "page" and p.k == "days" then meta[#meta + 1] = Plural(#p.o, "day") end
    b.meta:SetText(tconcat(meta, " · "))
    -- a pill after the question: Closed, or my answer
    local mine = Pl:MyVote(p)
    local pillText, pillTone
    if not open then pillText, pillTone = "Closed", "changed"
    elseif mine and p.k ~= "days" and mode == "page" then pillText, pillTone = "Answered", "rank" end
    local qRoom = w - 14 - 46 - 12 - (b.more:IsShown() and 46 or 16) - (pillText and 90 or 0)
    b.q:SetWidth(min(TextW(b.q) + 2, qRoom))
    b.meta:SetWidth(w - 14 - 46 - 12 - 16)
    if pillText then
        b.pill:SetKind(pillText, pillTone)
        b.pill:ClearAllPoints()
        b.pill:SetPoint("LEFT", b.q, "RIGHT", 10, 0)
        b.pill:Show()
    else
        b.pill:Hide()
    end
    -- who answered: faces, "n of m answered", a bar
    local voters = {}
    for _, slot in ipairs(p.m) do
        local v = res.votes[slot]
        if v then voters[#voters + 1] = v.by end
    end
    local fx = 14
    for i = 1, min(6, #voters) do
        local f = Pool(b.faces, i, function() return RingFace(b, 16) end)
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", fx, 16)
        f:SetFrameLevel(b:GetFrameLevel() + 2 + (6 - i))
        f:Set(voters[i])
        fx = fx + 12
    end
    HideFrom(b.faces, min(6, #voters) + 1)
    b.count:ClearAllPoints()
    b.count:SetPoint("BOTTOMLEFT", fx + (#voters > 0 and 12 or 0), 17)
    b.count:SetText(res.answered .. " of " .. res.total .. " answered")
    b.bar:ClearAllPoints()
    b.bar:SetPoint("LEFT", b.count, "RIGHT", 14, 0)
    b.bar:Set(res.total > 0 and res.answered / res.total or 0, 120)
    -- the right side: the answer bar (yes / no), Answer, or when it closes
    b.btn:Hide(); b.seg:Hide(); b.segLab:Hide(); b.chip:Hide()
    b.more:SetShown(mode == "page" and Pl:CanManage(p))
    local asked = Pl:AsksMe(p)
    local right = -14
    if p.k == "yn" and asked and open and (not mine or p.ch) then
        local picked = mine and mine.c[1] or nil
        b.seg:Set({ "Yes", "No" }, picked, function(i)
            Pl:Vote(p.id, { i })
        end, 70)
        b.seg:ClearAllPoints()
        b.seg:SetPoint("BOTTOMRIGHT", right, 12)
        b.segLab:ClearAllPoints()
        b.segLab:SetPoint("BOTTOMRIGHT", b.seg, "TOPRIGHT", 0, 5)
        b.segLab:Show()
        right = right - b.seg:GetWidth() - 12
    elseif mode == "list" then
        b.btn:SetText("Answer")
        b.btn:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
        b.btn:ClearAllPoints()
        b.btn:SetPoint("BOTTOMRIGHT", right, 12)
        b.btn:Show()
        right = right - b.btn:GetWidth() - 10
    elseif mode == "page" and IsMe(p.by) and open and #res.waiting > 0 then
        b.btn:SetText("Nudge them")
        FitButton(b.btn, 96)
        b.btn:SetKind("secondary")
        b.btn:SetScript("OnClick", function() PollsUI:Nudge(p.id) end)
        b.btn:ClearAllPoints()
        b.btn:SetPoint("BOTTOMRIGHT", right, 12)
        b.btn:Show()
        right = right - b.btn:GetWidth() - 10
    end
    if mode == "list" then b.btn:SetKind("primary") FitButton(b.btn, 70) end
    b.chip:Set(open and ("Closes " .. When(p.cl, true)) or ("Closed " .. When(p.cl)), UI().ICON.calendar)
    b.chip:ClearAllPoints()
    b.chip:SetPoint("BOTTOMRIGHT", right, 13)
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local L = {}
local CARD_W = 282
local LROW_H = 50

function L.NewRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(LROW_H)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.03)
    r.line = Line(r, { 1, 1, 1, 0.045 })
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r.art = CreateFrame("Frame", nil, r)
    r.art:SetSize(64, 38)
    r.art:SetPoint("LEFT", 2, 0)
    r.art.outer = Fill(r.art, { 0, 0, 0, 1 }, "BACKGROUND")
    r.art.outer:ClearAllPoints()
    r.art.outer:SetPoint("TOPLEFT", -1, 1)
    r.art.outer:SetPoint("BOTTOMRIGHT", 1, -1)
    r.art.tex = r.art:CreateTexture(nil, "ARTWORK")
    r.art.tex:SetAllPoints()
    r.icon = IconTile(r, 20)
    r.icon:SetPoint("BOTTOMLEFT", r.art, "BOTTOMLEFT", -5, -5)
    r.icon:SetFrameLevel(r.art:GetFrameLevel() + 3)
    r.dot = r.art:CreateTexture(nil, "OVERLAY")
    r.dot:SetTexture(DISC)
    r.dot:SetSize(8, 8)
    r.dot:SetVertexColor(1, 0.82, 0)
    r.dot:SetPoint("CENTER", r.art, "TOPRIGHT", 0, 0)
    r.title = Text(r, 12, C.white)
    r.title:SetPoint("TOPLEFT", 80, -10)
    r.meta = Text(r, 10, C.grey)
    r.meta:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -5)
    r.b1 = Button(r, "", 64, 24, "primary")
    r.b2 = Button(r, "", 44, 24, "secondary")
    r.more = UI():CreateTipIconButton(r, 20, UI().ICON.more, "More", nil, function() end)
    r.mini = CreateFrame("Frame", nil, r)
    r.mini:SetSize(110, 20)
    r.mini.l = Text(r.mini, 10, { 0.82, 0.82, 0.82 })
    r.mini.l:SetPoint("TOPLEFT")
    r.mini.r = Text(r.mini, 10, { 0.82, 0.82, 0.82 }, true)
    r.mini.r:SetJustifyH("RIGHT")
    r.mini.r:SetPoint("TOPRIGHT")
    r.mini.bar = Bar(r.mini, 4)
    r.mini.bar:SetPoint("BOTTOMLEFT")
    r.mini.bar:SetPoint("BOTTOMRIGHT")
    r.mini.bar:SetWidth(110)
    r.lock = CreateFrame("Frame", nil, r)
    r.lock:SetSize(120, 16)
    r.lock.icon = r.lock:CreateTexture(nil, "ARTWORK")
    r.lock.icon:SetSize(11, 11)
    r.lock.icon:SetPoint("LEFT")
    Glyph(r.lock.icon, UI().ICON.lock, C.dim)
    r.lock.fs = Text(r.lock, 10, C.dim)
    r.lock.fs:SetPoint("LEFT", r.lock.icon, "RIGHT", 5, 0)
    r:SetScript("OnClick", function(self) if self.pid then PollsUI:OpenPoll(self.pid) end end)
    return r
end

-- Fills a list row for poll p in section `sec` ("wait" | "done" | "mine" | "closed").
function L.Fill(r, p, sec, w)
    local Pl = P()
    r.pid = p.id
    r:SetWidth(w)
    SetArt(r.art.tex, p, 64, 38, 0.6)
    r.icon:Set(p.k)
    r.dot:SetShown(sec == "wait" or (sec == "mine" and Pl:AsksMe(p) and not Pl:MyVote(p)))
    r.title:SetText(p.q)
    local res = Pl:Results(p)
    local meta = { KIND_WORD[p.k] }
    local mine = Pl:MyVote(p)
    if sec == "done" then
        if mine and p.k ~= "days" then
            local picks = {}
            for _, i in ipairs(mine.c) do picks[#picks + 1] = p.o[i] end
            meta[#meta + 1] = #picks == 1 and ("you picked " .. white(picks[1])) or ("you picked " .. #picks)
        else
            meta[#meta + 1] = "you answered"
        end
        meta[#meta + 1] = ClosesWord(p)
    else
        if not IsMe(p.by) then meta[#meta + 1] = "asked by " .. Name(p.by) end
        meta[#meta + 1] = TargetsWord(p)
        meta[#meta + 1] = ClosesWord(p)
    end
    r.metaVariants = { tconcat(meta, " · ") }
    for drop = #meta - 1, 2, -1 do
        local short = {}
        for i, m in ipairs(meta) do
            if i == 1 or i > drop or i == #meta then short[#short + 1] = m end
        end
        r.metaVariants[#r.metaVariants + 1] = tconcat(short, " · ")
    end
    r.metaVariants[#r.metaVariants + 1] = meta[#meta]
    r.b1:Hide(); r.b2:Hide(); r.more:Hide(); r.mini:Hide(); r.lock:Hide()
    local right = 0
    if sec == "wait" then
        if p.k == "yn" then
            r.b1:SetText("No"); r.b1:SetKind("secondary"); FitButton(r.b1, 48)
            r.b2:SetText("Yes"); r.b2:SetKind("secondary"); FitButton(r.b2, 48)
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", -2, 0)
            r.b2:ClearAllPoints(); r.b2:SetPoint("RIGHT", r.b1, "LEFT", -6, 0)
            r.b1:SetScript("OnClick", function() Pl:Vote(p.id, { 2 }) end)
            r.b2:SetScript("OnClick", function() Pl:Vote(p.id, { 1 }) end)
            r.b1:Show(); r.b2:Show()
            right = r.b1:GetWidth() + r.b2:GetWidth() + 12
        else
            r.b1:SetText("Answer"); r.b1:SetKind("primary"); FitButton(r.b1, 70)
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", -2, 0)
            r.b1:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
            r.b1:Show()
            right = r.b1:GetWidth() + 6
        end
    elseif sec == "mine" then
        r.more:ClearAllPoints(); r.more:SetPoint("RIGHT", -2, 0)
        r.more:SetScript("OnClick", function(self) ManageMenu(self, p) end)
        r.more:Show()
        r.mini.l:SetText("Answered")
        Sized(r.mini.l, 10)
        r.mini.r:SetText(res.answered .. "/" .. res.total)
        r.mini.bar.fill:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
        r.mini.bar:Set(res.total > 0 and res.answered / res.total or 0, 110)
        r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", r.more, "LEFT", -10, 0)
        r.mini:Show()
        right = 110 + 34
    else
        local shown = Pl:ResultsShown(p)
        local lead, share = Leading(p, res)
        if shown and lead then
            r.mini.r:SetText(share .. "%")
            local room = 110 - TextW(r.mini.r) - 6
            for _, size in ipairs({ 10, 9, 8 }) do
                Sized(r.mini.l, size)
                r.mini.l:SetText(lead)
                if TextW(r.mini.l) <= room then break end
            end
            if TextW(r.mini.l) > room then r.mini.l:SetText("Leading") end
            r.mini.bar.fill:SetColorTexture(C.bar[1], C.bar[2], C.bar[3], 1)
            r.mini.bar:Set(share / 100, 110)
            r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", -2, 0)
            r.mini:Show()
            right = 116
        elseif not shown then
            r.lock.fs:SetText("Results " .. When(p.cl))
            r.lock:SetWidth(16 + TextW(r.lock.fs))
            r.lock:ClearAllPoints(); r.lock:SetPoint("RIGHT", -2, 0)
            r.lock:Show()
            right = r.lock:GetWidth() + 8
        end
    end
    local room = w - 80 - right - 12
    -- the question at 12, else 11; still too long: on two lines, the line under it goes to the tooltip
    r.title:SetWordWrap(false)
    r.title:SetWidth(room)
    r.title:ClearAllPoints()
    r.title:SetPoint("TOPLEFT", 80, -10)
    local fits = false
    for _, size in ipairs({ 12, 11 }) do
        Sized(r.title, size)
        r.title:SetText(p.q)
        if TextW(r.title) <= room then fits = true break end
    end
    r.tip = nil
    if fits then
        r.meta:Show()
        for _, text in ipairs(r.metaVariants) do
            r.meta:SetText(text)
            if TextW(r.meta) <= room then break end
        end
        r.meta:SetWidth(room)
        if r.meta:GetText() ~= r.metaVariants[1] then r.tip = { p.q, r.metaVariants[1] } end
    else
        r.title:ClearAllPoints()
        r.title:SetPoint("LEFT", 80, 0)
        Wrap(r.title, p.q, room, 11)
        r.meta:Hide()
        r.tip = { p.q, r.metaVariants[1] }
    end
    r:SetScript("OnEnter", function(self) if self.tip then Tip(self, self.tip) end end)
    r:SetScript("OnLeave", HideTip)
    r:Show()
end

-- The card at the right: the polls that closed lately, with what won.
function L.BuildCard(v)
    local c = CreateFrame("Frame", nil, v)
    c:SetWidth(CARD_W)
    Fill(c, CARD)
    Edges(c, CARD_EDGE)
    c.title = Text(c, 13, C.gold)
    c.title:SetPoint("TOPLEFT", 12, -12)
    c.title:SetText("Closed lately")
    c.all = CreateFrame("Button", nil, c)
    c.all:SetSize(40, 16)
    c.all:SetPoint("TOPRIGHT", -10, -11)
    c.all.fs = Text(c.all, 11, { 0.82, 0.82, 0.82 })
    c.all.fs:SetJustifyH("RIGHT")
    c.all.fs:SetPoint("RIGHT", -12, 0)
    c.all.fs:SetText("All")
    c.all.chev = c.all:CreateTexture(nil, "ARTWORK")
    c.all.chev:SetSize(9, 9)
    c.all.chev:SetPoint("RIGHT", 0, 0)
    c.all.chev:SetTexture(UI().ICON_ATLAS)
    UI():SetChevron(c.all.chev, true)
    c.all.chev:SetVertexColor(0.82, 0.82, 0.82)
    c.all:SetScript("OnClick", function() PollsUI:ShowList("closed") end)
    c.rule = Line(c, { 1, 1, 1, 0.08 })
    c.rule:SetHeight(1)
    c.rule:SetPoint("TOPLEFT", 10, -36)
    c.rule:SetPoint("TOPRIGHT", -10, -36)
    c.items = {}
    c.empty = Text(c, 11, C.dim)
    c.empty:SetPoint("TOPLEFT", 12, -48)
    c.empty:SetText("Nothing has closed yet.")
    v.card = c
end

function L.FillCard(v, closed)
    local c = v.card
    local y = 46
    local n = 0
    for _, p in ipairs(closed) do
        if n >= 5 then break end
        n = n + 1
        local it = Pool(c.items, n, function()
            local f = CreateFrame("Button", nil, c)
            f.icon = IconTile(f, 22)
            f.icon:SetPoint("TOPLEFT", 1, -1)
            f.q = Text(f, 11, C.white)
            f.q:SetPoint("TOPLEFT", 32, 0)
            f.w = Text(f, 10, C.gold)
            f.w:SetPoint("TOPLEFT", f.q, "BOTTOMLEFT", 0, -4)
            f.pct = Text(f, 10, { 0.82, 0.82, 0.82 }, true)
            f.pct:SetJustifyH("RIGHT")
            f.pct:SetPoint("TOPRIGHT", 0, -15)
            f.bar = Bar(f, 3)
            f.hl = f:CreateTexture(nil, "HIGHLIGHT")
            f.hl:SetPoint("TOPLEFT", -6, 4)
            f.hl:SetPoint("BOTTOMRIGHT", 6, -4)
            f.hl:SetColorTexture(1, 1, 1, 0.03)
            return f
        end)
        local w = CARD_W - 24
        it:SetSize(w, 40)
        it:ClearAllPoints()
        it:SetPoint("TOPLEFT", 12, -y)
        it.icon:Set(p.k)
        it.q:SetText(p.q)
        it.q:SetWidth(w - 32)
        local res = P():Results(p)
        local lead, share = Leading(p, res)
        it.w:SetText(lead or Hex(C.dim, "No answers"))
        it.w:SetWidth(w - 32 - 36)
        it.pct:SetText(lead and (share .. "%") or "")
        it.bar:ClearAllPoints()
        it.bar:SetPoint("BOTTOMLEFT", 32, 0)
        it.bar:SetPoint("BOTTOMRIGHT", 0, 0)
        it.bar:Set(lead and share / 100 or 0, w - 32)
        it:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
        it:Show()
        y = y + 52
    end
    HideFrom(c.items, n + 1)
    c.empty:SetShown(n == 0)
    c.all:SetShown(n > 0)
    c:SetHeight(n == 0 and 76 or (y + 4))
end

function L.Build(v)
    v.tabOpen = UI():CreateUnderlineTab(v, "Open", function() PollsUI:ShowList("open") end, "page")
    v.tabOpen:SetPoint("TOPLEFT", PAD - 4, -6)
    v.tabClosed = UI():CreateUnderlineTab(v, "Closed", function() PollsUI:ShowList("closed") end, "page")
    v.tabClosed:SetPoint("LEFT", v.tabOpen, "RIGHT", 4, 0)
    v.new = Button(v, "New poll", 104, 24, "primary", function() PollsUI:OpenNew() end, UI().ICON.plus)
    v.new:SetPoint("TOPRIGHT", -PAD, -7)
    v.hero = Banner(v, BAN_LIST_H, false)
    v.hero:SetPoint("TOPLEFT", PAD, -(TABS_H + 6))
    v.hero:SetPoint("TOPRIGHT", -PAD, -(TABS_H + 6))
    v.scroll = UI():CreateScrollFrame(v)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(PAGE_W - 2 * PAD, 10)
    v.scroll:SetScrollChild(v.content)
    v.heads, v.rows = {}, {}
    v.empty = Text(v.content, 11, C.dim)
    L.BuildCard(v)
end

function L.Refresh(v)
    local Pl = P()
    local polls = Pl:GetPolls()
    UI():SetTabCount(v.tabOpen, Pl:WaitingCount())
    v.tabOpen:SetActive(state.tab == "open")
    v.tabClosed:SetActive(state.tab == "closed")
    v.new:SetShown(Pl:AmIAsker())
    local wait, done, mine, closed = {}, {}, {}, {}
    for _, p in ipairs(polls) do
        if not Pl:IsOpen(p) then
            closed[#closed + 1] = p
        elseif IsMe(p.by) then
            mine[#mine + 1] = p
        elseif Pl:AsksMe(p) then
            if Pl:MyVote(p) then done[#done + 1] = p else wait[#wait + 1] = p end
        end
    end
    -- the banner: the open poll waiting for me that closes first (open tab only)
    local hero = state.tab == "open" and wait[1] or nil
    local top = TABS_H + 6
    if hero then
        table.remove(wait, 1)
        FillBanner(v.hero, hero, "list")
        v.hero:Show()
        top = top + BAN_LIST_H + 14
    else
        v.hero:Hide()
    end
    local groups
    if state.tab == "open" then
        groups = { { "Waiting for you", wait, "wait" }, { "Answered", done, "done" }, { "Your polls", mine, "mine" } }
    else
        groups = { { "Closed", closed, "closed" } }
    end
    -- the card at the right (open tab, when something closed)
    local withCard = state.tab == "open" and #closed > 0
    local listW = PAGE_W - 2 * PAD - (withCard and (CARD_W + 16) or 0)
    v.card:SetShown(withCard)
    if withCard then
        v.card:ClearAllPoints()
        v.card:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, -top)
        L.FillCard(v, closed)
    end
    v.scroll:ClearAllPoints()
    v.scroll:SetPoint("TOPLEFT", PAD, -top)
    v.scroll:SetSize(listW, PAGE_H - top - PAD)
    local total, heads = 0, 0
    for _, g in ipairs(groups) do
        if #g[2] > 0 then
            heads = heads + 1
            total = total + min(#g[2], MAX_LIST_ROWS)
        end
    end
    local need = total * LROW_H + heads * 28 + max(0, heads - 1) * 12
    local cw = need > (PAGE_H - top - PAD) and (listW - 14) or listW
    v.content:SetWidth(cw)
    local y, hi, ri = 0, 0, 0
    for _, g in ipairs(groups) do
        if #g[2] > 0 then
            hi = hi + 1
            local s = Pool(v.heads, hi, function() return Sect(v.content) end)
            s:SetWidth(cw)
            s:ClearAllPoints()
            if hi > 1 then y = y + 12 end
            s:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
            s:Set(g[1], tostring(#g[2]))
            y = y + 28
            for i = 1, min(#g[2], MAX_LIST_ROWS) do
                ri = ri + 1
                local r = Pool(v.rows, ri, function() return L.NewRow(v.content) end)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
                L.Fill(r, g[2][i], g[3], cw)
                y = y + LROW_H
            end
        end
    end
    HideFrom(v.heads, hi + 1)
    HideFrom(v.rows, ri + 1)
    v.empty:Hide()
    if ri == 0 and not hero then
        v.empty:ClearAllPoints()
        v.empty:SetPoint("TOPLEFT", v.content, "TOPLEFT", 2, -8)
        if state.tab == "open" then
            v.empty:SetText(Pl:AmIAsker() and "No open polls. Ask the guild something: it reaches the people you pick."
                or "No polls for you right now. When the officers ask you something, it shows up here.")
        else
            v.empty:SetText("No closed polls yet.")
        end
        v.empty:Show()
        y = 30
    end
    v.content:SetHeight(max(10, y))
end

---------------------------------------------------------------------------
-- A poll's page
---------------------------------------------------------------------------

local V = {}
local BODY_Y = BAN_PAGE_H + 8 + 14
local COL_R = 282

function PollsUI:Nudge(id)
    local n, why = P():Nudge(id)
    if n and n > 0 then
        ns:Print("reminded %s about the poll.", Plural(n, "player"))
    elseif why == "soon" then
        ns:Print("you nudged them a moment ago: wait a few minutes before the next one.")
    end
end

function V.Build(v)
    v.ban = Banner(v, BAN_PAGE_H, true)
    v.ban:SetPoint("TOPLEFT", PAD, -8)
    v.ban:SetPoint("TOPRIGHT", -PAD, -8)
    local LW = PAGE_W - 2 * PAD - COL_R - 24
    v.lsec = Sect(v)
    v.lsec:SetPoint("TOPLEFT", PAD, -BODY_Y)
    v.lsec:SetWidth(LW)
    v.scroll = UI():CreateScrollFrame(v)
    v.scroll:SetPoint("TOPLEFT", PAD, -(BODY_Y + 34))
    v.scroll:SetSize(LW, PAGE_H - BODY_Y - 34 - PAD)
    v.body = CreateFrame("Frame", nil, v.scroll)
    v.body:SetSize(LW, 10)
    v.scroll:SetScrollChild(v.body)
    v.ans, v.res = {}, {}
    v.vote = Button(v.body, "Vote", 76, 24, "primary", function() V.SendVote() end)
    v.note = Text(v.body, 10, C.dim)
    v.change = Button(v.body, "Change my answer", 130, 24, "secondary", function()
        state.changing = true
        local p = P():GetPoll(state.poll)
        local mine = p and P():MyVote(p)
        state.pick = {}
        for _, i in ipairs(mine and mine.c or {}) do state.pick[i] = true end
        PollsUI:Refresh()
    end)
    v.err = Text(v.body, 10, C.red)
    -- the people (right column)
    v.rsec = Sect(v)
    v.rsec:SetPoint("TOPRIGHT", -PAD, -BODY_Y)
    v.rsec:SetWidth(COL_R)
    v.people = {}
    v.pmore = Text(v, 10, C.dim)
    -- Pick days
    v.grid = CreateFrame("Frame", nil, v)
    v.grid:SetPoint("TOPLEFT", PAD, -BODY_Y)
    v.grid:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    V.BuildGrid(v.grid)
end

local function AnswerRow(parent, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, ANS_H)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetTexture(WHITE)
    Edges(b, C.rowEdge)
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetColorTexture(1, 0.82, 0, 1)
    b.bar:SetPoint("TOPLEFT", 0, 0)
    b.bar:SetPoint("BOTTOMLEFT", 0, 0)
    b.bar:SetWidth(3)
    b.ring = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.ring:SetTexture(DISC)
    b.ring:SetSize(14, 14)
    b.ring:SetPoint("LEFT", 12, 0)
    b.hole = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.hole:SetTexture(DISC)
    b.hole:SetSize(11, 11)
    b.hole:SetPoint("CENTER", b.ring)
    b.dot = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.dot:SetTexture(DISC)
    b.dot:SetSize(7, 7)
    b.dot:SetPoint("CENTER", b.ring)
    b.dot:SetVertexColor(1, 0.82, 0)
    b.box = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.box:SetSize(13, 13)
    b.box:SetPoint("LEFT", 12, 0)
    b.check = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.check:SetTexture(CHECK)
    b.check:SetSize(19, 19)
    b.check:SetPoint("CENTER", b.box, "CENTER", 1, 0)
    b.check:SetVertexColor(1, 0.82, 0)
    b.fs = Text(b, 12, C.text)
    b.fs:SetPoint("LEFT", 36, 0)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.035)
    function b:Set(text, multi, on, rowW)
        self:SetWidth(rowW or w)
        self.fs:SetText(text)
        self.fs:SetWidth((rowW or w) - 48)
        self.ring:SetShown(not multi)
        self.hole:SetShown(not multi)
        self.dot:SetShown(not multi and on)
        self.box:SetShown(multi)
        self.check:SetShown(multi and on)
        self.bar:SetShown(on)
        if on then
            if self.bg.SetGradient and CreateColor then
                self.bg:SetGradient("HORIZONTAL", CreateColor(0.24, 0.2, 0.08, 1), CreateColor(0.12, 0.11, 0.07, 1))
            end
            UI():SetEdgeColor(self, C.pickEdge[1], C.pickEdge[2], C.pickEdge[3], 1)
            Color(self.fs, C.white)
            self.ring:SetVertexColor(1, 0.82, 0, 1)
            self.hole:SetVertexColor(0.2, 0.17, 0.08, 1)
            self.box:SetColorTexture(0.24, 0.2, 0.08, 1)
        else
            if self.bg.SetGradient and CreateColor then
                self.bg:SetGradient("HORIZONTAL", CreateColor(0.12, 0.12, 0.14, 1), CreateColor(0.085, 0.085, 0.1, 1))
            end
            UI():SetEdgeColor(self, C.rowEdge[1], C.rowEdge[2], C.rowEdge[3], 1)
            Color(self.fs, C.text)
            self.ring:SetVertexColor(0.42, 0.42, 0.45, 1)
            self.hole:SetVertexColor(0.11, 0.11, 0.13, 1)
            self.box:SetColorTexture(0.3, 0.3, 0.33, 1)
        end
        self:Show()
    end
    return b
end

local function ResultBlock(parent, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(w)
    f.l = Text(f, 13, C.white)
    f.l:SetPoint("TOPLEFT", 0, -3)            -- (room above for the "Your vote" pill: the scroll frame clips)
    f.mine = EUI():CreatePill(f, 16)
    f.c = Text(f, 12, C.white, true)
    f.c:SetJustifyH("RIGHT")
    f.c:SetPoint("TOPRIGHT", 0, -3)
    f.pct = Text(f, 11, { 0.66, 0.66, 0.68 }, true)
    f.pct:SetJustifyH("RIGHT")
    f.bar = CreateFrame("Frame", nil, f)
    f.bar:SetHeight(8)
    f.bar:SetPoint("TOPLEFT", 0, -24)
    f.bar:SetPoint("TOPRIGHT", 0, -24)
    f.bar.track = Fill(f.bar, { 0.14, 0.14, 0.16, 1 })
    f.bar.fill = f.bar:CreateTexture(nil, "ARTWORK")
    f.bar.fill:SetPoint("TOPLEFT")
    f.bar.fill:SetPoint("BOTTOMLEFT")
    f.bar.fill:SetTexture(WHITE)
    if f.bar.fill.SetGradient and CreateColor then
        f.bar.fill:SetGradient("HORIZONTAL", CreateColor(0.72, 0.53, 0.04, 1), CreateColor(1, 0.82, 0.25, 1))
    else
        f.bar.fill:SetColorTexture(C.bar[1], C.bar[2], C.bar[3], 1)
    end
    f.names = Text(f, 10, C.dim)
    f.names:SetPoint("TOPLEFT", 0, -39)
    return f
end

local function PersonRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(24)
    r.face = RingFace(r, 17)
    r.face:SetPoint("LEFT", 2, 0)
    r.fs = Text(r, 11, C.white)
    r.fs:SetPoint("LEFT", r.face, "RIGHT", 8, 0)
    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetTexture(CHECK)
    r.mark:SetSize(16, 16)
    r.mark:SetPoint("RIGHT", 0, 0)
    r.mark:SetVertexColor(0.31, 0.83, 0.42)
    r.wait = r:CreateTexture(nil, "ARTWORK")
    r.wait:SetTexture(DISC)
    r.wait:SetSize(9, 9)
    r.wait:SetPoint("RIGHT", -3, 0)
    r.wait:SetVertexColor(1, 1, 1, 0.16)
    r.waitHole = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.waitHole:SetTexture(DISC)
    r.waitHole:SetSize(7, 7)
    r.waitHole:SetPoint("CENTER", r.wait)
    r.waitHole:SetVertexColor(0.08, 0.08, 0.09, 1)
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
        if self.tipText then Tip(self, self.tipText) end
    end)
    r:SetScript("OnLeave", HideTip)
    return r
end

-- The right column: who answered (names, not picks; answered first), or for the asker who hasn't.
function V.FillPeople(v, p, res)
    local manage = IsMe(p.by)
    local keys, marks = {}, not manage
    for _, k in ipairs(manage and res.waiting or p.m) do keys[#keys + 1] = k end
    if marks then
        tsort(keys, function(a, b)
            local va, vb = res.votes[a] ~= nil, res.votes[b] ~= nil
            if va ~= vb then return va end
            return a < b
        end)
    end
    v.rsec:Set(manage and "Not answered" or "Answered",
        manage and (#res.waiting .. " of " .. res.total) or (res.answered .. " of " .. res.total))
    local colW = floor((COL_R - 14) / 2)
    local maxRows = 12
    local shown = min(#keys, maxRows * 2)
    if #keys > maxRows * 2 then shown = maxRows * 2 - 1 end
    local x0 = PAGE_W - PAD - COL_R
    for i = 1, shown do
        local r = Pool(v.people, i, function() return PersonRow(v) end)
        local k = keys[i]
        local vote = res.votes[k]
        local who = vote and vote.by or k
        r:SetWidth(colW)
        r:ClearAllPoints()
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        r:SetPoint("TOPLEFT", v, "TOPLEFT", x0 + col * (colW + 14), -(BODY_Y + 36 + row * 26))
        r.face:Set(who)
        r.fs:SetText(Name(who))
        r.fs:SetWidth(colW - 27 - (marks and 18 or 0))
        r.mark:SetShown(marks and vote ~= nil)
        r.wait:SetShown(marks and vote == nil)
        r.waitHole:SetShown(marks and vote == nil)
        r.tipText = marks and { Name(who), vote and "Has answered" or "Hasn't answered yet" } or nil
        r:Show()
    end
    HideFrom(v.people, shown + 1)
    v.pmore:Hide()
    if #keys > shown then
        local rows = ceil(shown / 2)
        v.pmore:ClearAllPoints()
        v.pmore:SetPoint("TOPLEFT", v, "TOPLEFT", x0 + 2 + (shown % 2) * (colW + 14),
            -(BODY_Y + 36 + (rows - (shown % 2 == 1 and 1 or 0)) * 26 + 6))
        v.pmore:SetText("and " .. (#keys - shown) .. " more")
        v.pmore:Show()
    elseif #keys == 0 then
        v.pmore:ClearAllPoints()
        v.pmore:SetPoint("TOPLEFT", v, "TOPLEFT", x0 + 2, -(BODY_Y + 40))
        v.pmore:SetText(manage and "Everyone has answered." or "Nobody yet.")
        v.pmore:Show()
    end
end

function V.SendVote()
    local p = P():GetPoll(state.poll)
    if not p then return end
    local c = {}
    for i = 1, #p.o do
        if state.pick[i] then c[#c + 1] = i end
    end
    local ok, why = P():Vote(p.id, c)
    if ok then
        state.changing = false
        state.pick = {}
        state.err = nil
    else
        state.err = why or "Couldn't send your answer."
    end
    PollsUI:Refresh()
end

function V.Refresh(v)
    local Pl = P()
    local p = Pl:GetPoll(state.poll)
    if not p then
        PollsUI:ShowList()
        return
    end
    FillBanner(v.ban, p, "page")
    local open = Pl:IsOpen(p)
    local res = Pl:Results(p)
    if p.k == "days" then
        v.scroll:Hide(); v.lsec:Hide(); v.rsec:Hide(); v.pmore:Hide()
        HideFrom(v.people, 1)
        v.grid:Show()
        V.FillGrid(v.grid, p, res)
        return
    end
    v.grid:Hide()
    v.scroll:Show(); v.lsec:Show(); v.rsec:Show()
    local LW = v.body:GetWidth()
    local mine = Pl:MyVote(p)
    local asked = Pl:AsksMe(p)
    local answering = asked and open and (not mine or state.changing) and p.k ~= "yn"
    local shown = Pl:ResultsShown(p)
    local y = 0
    for _, b in ipairs(v.ans) do b:Hide() end
    for _, b in ipairs(v.res) do b:Hide() end
    v.vote:Hide(); v.note:Hide(); v.change:Hide(); v.err:Hide()
    if answering then
        v.lsec:Set(mine and "Change your answer" or "Your answer",
            p.k == "many" and ((p.mx or 0) > 0 and ("pick up to " .. p.mx) or "pick any") or "pick one")
        local multi = p.k == "many"
        for i = 1, #p.o do
            local b = Pool(v.ans, i, function() return AnswerRow(v.body, LW) end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b:Set(p.o[i], multi, state.pick[i] and true or false, LW)
            b:SetScript("OnClick", function()
                if multi then
                    local n = 0
                    for _, on in pairs(state.pick) do if on then n = n + 1 end end
                    if not state.pick[i] and p.mx and p.mx > 0 and n >= p.mx then
                        state.err = "Pick at most " .. p.mx .. "."
                    else
                        state.pick[i] = not state.pick[i] or nil
                        state.err = nil
                    end
                else
                    state.pick = { [i] = true }
                    state.err = nil
                end
                PollsUI:Refresh()
            end)
            y = y + ANS_H + ANS_GAP
        end
        y = y + 8
        v.vote:SetText(mine and "Save" or "Vote")
        v.vote:ClearAllPoints()
        v.vote:SetPoint("TOPLEFT", 0, -y)
        v.vote:Show()
        local words = {}
        local after = ({ vote = "Results show after you vote.", close = "Results show when it closes." })[p.rv]
        if after then words[#words + 1] = after end
        words[#words + 1] = p.ch and "You can change it until it closes." or "Your answer can't be changed afterwards."
        v.note:SetText(tconcat(words, " "))
        v.note:ClearAllPoints()
        v.note:SetPoint("LEFT", v.vote, "RIGHT", 12, 0)
        v.note:SetWidth(LW - v.vote:GetWidth() - 12)
        v.note:Show()
        y = y + 32
        if state.err then
            v.err:SetText(state.err)
            v.err:ClearAllPoints()
            v.err:SetPoint("TOPLEFT", 0, -y)
            v.err:Show()
            y = y + 16
        end
    elseif shown then
        v.lsec:Set("Results", Plural(res.answered, "answer"))
        local myPick = {}
        for _, i in ipairs(mine and mine.c or {}) do myPick[i] = true end
        local order = {}
        for i = 1, #p.o do order[i] = i end
        tsort(order, function(a, b)
            if res.counts[a] ~= res.counts[b] then return res.counts[a] > res.counts[b] end
            return a < b
        end)
        local denom = max(1, res.answered)
        for n, i in ipairs(order) do
            local f = Pool(v.res, n, function() return ResultBlock(v.body, LW) end)
            f:SetWidth(LW)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", 0, -y)
            f.l:SetText(p.o[i])
            local pct = floor(res.counts[i] * 100 / denom + 0.5)
            f.c:SetText(tostring(res.counts[i]))
            f.pct:SetText(pct .. "%")
            f.pct:ClearAllPoints()
            f.pct:SetPoint("RIGHT", f.c, "LEFT", -8, 0)
            local roomL = LW - TextW(f.c) - TextW(f.pct) - 20 - (myPick[i] and 84 or 0)
            f.l:SetWidth(min(TextW(f.l) + 2, roomL))
            if myPick[i] then
                f.mine:SetKind("Your vote", "rank")
                f.mine:ClearAllPoints()
                f.mine:SetPoint("LEFT", f.l, "RIGHT", 8, 0)
                f.mine:Show()
            else
                f.mine:Hide()
            end
            f.bar.fill:SetWidth(max(0.01, LW * res.counts[i] / denom))
            f.bar.fill:SetShown(res.counts[i] > 0)
            local names = {}
            for _, k in ipairs(res.voters[i]) do names[#names + 1] = Name(k) end
            local h = 0
            if #names > 0 then
                h = Wrap(f.names, tconcat(names, Hex(C.dim, ", ")), LW, 10)
                f.names:Show()
            else
                f.names:Hide()
            end
            f:SetHeight(39 + h)
            f:Show()
            y = y + 39 + h + 14
        end
        if asked and open and p.ch and mine and p.k ~= "yn" then
            v.change:ClearAllPoints()
            v.change:SetPoint("TOPLEFT", 0, -(y + 2))
            v.change:Show()
            y = y + 32
        end
    else
        -- answered (or not asked), results wait
        v.lsec:Set(mine and "Your answer" or "Answers", "results " .. When(p.cl))
        local myPick = {}
        for _, i in ipairs(mine and mine.c or {}) do myPick[i] = true end
        for i = 1, #p.o do
            local b = Pool(v.ans, i, function() return AnswerRow(v.body, LW) end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b:Set(p.o[i], p.k == "many", myPick[i] and true or false, LW)
            b:SetScript("OnClick", nil)
            y = y + ANS_H + ANS_GAP
        end
        v.note:SetText((mine and "Voted. " or "") .. "Results show when it closes " .. white(When(p.cl, true)) .. ".")
        v.note:ClearAllPoints()
        v.note:SetPoint("TOPLEFT", 0, -(y + 6))
        v.note:SetWidth(LW)
        v.note:Show()
        y = y + 26
        if asked and open and p.ch and mine and p.k ~= "yn" then
            v.change:ClearAllPoints()
            v.change:SetPoint("TOPLEFT", 0, -(y + 4))
            v.change:Show()
            y = y + 32
        end
    end
    v.body:SetHeight(max(10, y))
    V.FillPeople(v, p, res)
end

---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Pick days: the grid
---------------------------------------------------------------------------

local function Cell(parent)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(20)
    c.bg = Fill(c, C.no)
    Edges(c, C.noEdge)
    c.check = c:CreateTexture(nil, "ARTWORK")
    c.check:SetTexture(CHECK)
    c.check:SetSize(16, 16)
    c.check:SetPoint("CENTER", 1, 0)
    c.check:SetVertexColor(0.47, 0.83, 0.54)
    c.fs = Text(c, 9, { 0.91, 0.77, 0.42 })
    c.fs:SetJustifyH("CENTER")
    c.fs:SetPoint("CENTER")
    function c:Set(s, mineRow)
        local bg, edge = C.no, C.noEdge
        if s == 1 then bg, edge = C.can, C.canEdge elseif s == 2 then bg, edge = C.maybe, C.maybeEdge end
        self.bg:SetColorTexture(bg[1], bg[2], bg[3], 1)
        UI():SetEdgeColor(self, edge[1], edge[2], edge[3], 1)
        self.check:SetShown(s == 1)
        if s == 2 then
            self.fs:SetText(self:GetWidth() >= 60 and "if needed" or "maybe")
            Color(self.fs, { 0.91, 0.77, 0.42 })
        elseif mineRow and s == 0 then
            self.fs:SetText("can't")
            Color(self.fs, { 0.33, 0.33, 0.35 })
        else
            self.fs:SetText("")
        end
        self:Show()
    end
    return c
end

local function GridRow(parent, n)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(23)
    r.face = RingFace(r, 15)
    r.face:SetPoint("LEFT", 5, 0)
    r.fs = Text(r, 11, C.white)
    r.fs:SetPoint("LEFT", r.face, "RIGHT", 8, 0)
    r.cells = {}
    return r
end

function V.BuildGrid(g)
    g.head = CreateFrame("Frame", nil, g)
    g.head:SetPoint("TOPLEFT", 0, -12)
    g.head:SetPoint("TOPRIGHT", 0, -12)
    g.head:SetHeight(39)
    g.hint = Text(g.head, 10, C.dim)
    g.hint:SetPoint("LEFT", 4, 0)
    g.days = {}
    g.you = GridRow(g)
    g.you.bg = Fill(g.you, { 0.106, 0.102, 0.078, 1 })
    Edges(g.you, { 0.23, 0.21, 0.13, 1 })
    g.you:SetHeight(28)
    g.you.sub = Text(g.you, 8, C.dim)
    g.you.sub:SetPoint("LEFT", g.you.fs, "RIGHT", 6, 0)
    g.tot = CreateFrame("Frame", nil, g)
    g.tot:SetHeight(26)
    g.tot.fs = Text(g.tot, 10, C.gold)
    g.tot.fs:SetPoint("LEFT", 4, 0)
    g.tot.fs:SetText("Can make it")
    g.tot.rule = Line(g.tot, { 1, 1, 1, 0.08 })
    g.tot.rule:SetHeight(1)
    g.tot.rule:SetPoint("BOTTOMLEFT")
    g.tot.rule:SetPoint("BOTTOMRIGHT")
    g.tot.n = {}
    g.scroll = UI():CreateScrollFrame(g)
    g.list = CreateFrame("Frame", nil, g.scroll)
    g.list:SetSize(PAGE_W - 2 * PAD, 10)
    g.scroll:SetScrollChild(g.list)
    g.rows = {}
    g.foot = Text(g, 10, C.dim)
    g.best = CreateFrame("Frame", nil, g)
    g.best:SetFrameLevel(g:GetFrameLevel() + 20)
    g.best.edges = {}
    UI():AddEdges(g.best, "OVERLAY")
    UI():SetEdgeColor(g.best, 0.82, 0.64, 0.03, 1)
    g.best.tag = CreateFrame("Frame", nil, g.best)
    g.best.tag:SetSize(36, 11)
    g.best.tag:SetPoint("BOTTOM", g.best, "TOP", 0, -1)
    Fill(g.best.tag, { 0.82, 0.64, 0.03, 1 }, "ARTWORK")
    g.best.tag.fs = Text(g.best.tag, 8, { 0.1, 0.08, 0 })
    g.best.tag.fs:SetShadowOffset(0, 0)
    g.best.tag.fs:SetJustifyH("CENTER")
    g.best.tag.fs:SetPoint("CENTER", 0, 0)
    g.best.tag.fs:SetText("BEST")
    g.save = Button(g, "Save", 64, 22, "primary", function() V.SaveDays() end)
    g.save:SetPoint("BOTTOMRIGHT", 0, 0)
    g.saveNote = Text(g, 10, C.dim)
    g.saveNote:SetJustifyH("RIGHT")
    g.saveNote:SetPoint("RIGHT", g.save, "LEFT", -10, 0)
end

function V.SaveDays()
    local p = P():GetPoll(state.poll)
    if not p or not state.days then return end
    local c = {}
    for i = 1, #p.o do c[i] = state.days[i] or 0 end
    local ok, why = P():Vote(p.id, c)
    if ok then
        state.days = nil
    else
        ns:Print(why or "couldn't save your answer.")
    end
    PollsUI:Refresh()
end

function V.FillGrid(g, p, res)
    local Pl = P()
    local n = #p.o
    local W = PAGE_W - 2 * PAD
    local cw = max(40, min(120, floor((W - NAME_COL) / n) - CELL_GAP))
    local x0 = NAME_COL
    local open = Pl:IsOpen(p)
    local asked = Pl:AsksMe(p)
    local mine = Pl:MyVote(p)
    local shown = Pl:ResultsShown(p) or (asked and not open)
    local editing = asked and open and (not mine or p.ch)
    if editing and not state.days then
        state.days = {}
        for i = 1, n do state.days[i] = mine and mine.c[i] or 0 end
    end
    g.hint:SetText(editing and "Tick the nights you can make" or "")
    -- the header
    for i = 1, n do
        local d = Pool(g.days, i, function()
            local f = CreateFrame("Frame", nil, g.head)
            f:SetSize(cw, 39)
            f.wd = Text(f, 9, C.gold)
            f.wd:SetJustifyH("CENTER")
            f.wd:SetPoint("TOP", 0, -1)
            f.dn = Text(f, 15, C.white, true)
            f.dn:SetJustifyH("CENTER")
            f.dn:SetPoint("TOP", f.wd, "BOTTOM", 0, -1)
            f.tm = Text(f, 9, C.grey, true)
            f.tm:SetJustifyH("CENTER")
            f.tm:SetPoint("TOP", f.dn, "BOTTOM", 0, 0)
            return f
        end)
        d:SetWidth(cw)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", g.head, "TOPLEFT", x0 + (i - 1) * (cw + CELL_GAP), 0)
        local y, mo, dd, hh, mm = Pl.DayParts(p.o[i])
        local t = y and time({ year = y, month = mo, day = dd, hour = 12 }) or 0
        d.wd:SetText(date("%a", t):upper())
        d.dn:SetText(tostring(dd or "?"))
        d.tm:SetText(hh and ("%02d:%02d"):format(hh, mm) or "")
        d:Show()
    end
    HideFrom(g.days, n + 1)
    local y = 53
    -- my row
    if asked then
        g.you:ClearAllPoints()
        g.you:SetPoint("TOPLEFT", 0, -y)
        g.you:SetPoint("TOPRIGHT", 0, -y)
        g.you.face:Set(Me())
        local cr, cg, cb = UI():ClassColor(EUI():ClassOf(Me()))
        g.you.fs:SetText("You")
        g.you.fs:SetTextColor(cr or 1, cg or 1, cb or 1)
        g.you.sub:SetText(editing and "click to change" or (mine and "" or "closed"))
        for i = 1, n do
            local c = Pool(g.you.cells, i, function() return Cell(g.you) end)
            c:SetWidth(cw)
            c:ClearAllPoints()
            c:SetPoint("LEFT", g.you, "LEFT", x0 + (i - 1) * (cw + CELL_GAP), 0)
            local s = state.days and state.days[i] or (mine and mine.c[i]) or 0
            c:Set(s, true)
            if editing then
                c:SetScript("OnClick", function()
                    state.days[i] = ({ [0] = 1, [1] = 2, [2] = 0 })[state.days[i] or 0]
                    PollsUI:Refresh()
                end)
            else
                c:SetScript("OnClick", nil)
            end
        end
        HideFrom(g.you.cells, n + 1)
        g.you:Show()
        y = y + 28 + 4
    else
        g.you:Hide()
    end
    -- totals and everyone's rows
    if shown then
        g.tot:ClearAllPoints()
        g.tot:SetPoint("TOPLEFT", 0, -y)
        g.tot:SetPoint("TOPRIGHT", 0, -y)
        for i = 1, n do
            local f = Pool(g.tot.n, i, function()
                local t = CreateFrame("Frame", nil, g.tot)
                t:SetSize(cw, 26)
                t.n = Text(t, 12, C.white, true)
                t.m = Text(t, 9, C.dim)
                return t
            end)
            f:SetWidth(cw)
            f:ClearAllPoints()
            f:SetPoint("LEFT", g.tot, "LEFT", x0 + (i - 1) * (cw + CELL_GAP), 0)
            f.n:SetText(tostring(res.counts[i]))
            f.m:SetText(res.maybe[i] > 0 and ("+ " .. res.maybe[i] .. (cw >= 100 and " if needed" or "")) or "")
            local tw = TextW(f.n) + (f.m:GetText() ~= "" and (5 + TextW(f.m)) or 0)
            f.n:ClearAllPoints()
            f.n:SetPoint("LEFT", f, "CENTER", -tw / 2, 0)
            f.m:ClearAllPoints()
            f.m:SetPoint("LEFT", f.n, "RIGHT", 5, 0)
            f:Show()
        end
        HideFrom(g.tot.n, n + 1)
        g.tot:Show()
        y = y + 26 + 6
        -- everyone else who answered
        local others = {}
        for _, slot in ipairs(p.m) do
            local v = res.votes[slot]
            if v and not (asked and Pl:SlotOf(p) == slot) then others[#others + 1] = v end
        end
        tsort(others, function(a, b) return a.by < b.by end)
        local footH = 22
        local avail = PAGE_H - BODY_Y - PAD - y - footH - 30
        g.scroll:ClearAllPoints()
        g.scroll:SetPoint("TOPLEFT", 0, -y)
        local listH = #others * 23
        local scrolls = listH > avail
        g.scroll:SetSize(W - (scrolls and 14 or 0), max(23, min(listH, avail)))
        g.list:SetWidth(W - (scrolls and 14 or 0))
        for ri, v in ipairs(others) do
            local r = Pool(g.rows, ri, function() return GridRow(g.list) end)
            r:SetWidth(W)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -(ri - 1) * 23)
            r.face:Set(v.by)
            r.fs:SetText(Name(v.by))
            r.fs:SetWidth(NAME_COL - 30)
            for i = 1, n do
                local c = Pool(r.cells, i, function()
                    local cc = Cell(r)
                    cc:EnableMouse(false)
                    return cc
                end)
                c:SetWidth(cw)
                c:ClearAllPoints()
                c:SetPoint("LEFT", r, "LEFT", x0 + (i - 1) * (cw + CELL_GAP), 0)
                c:Set(v.c[i] or 0)
            end
            HideFrom(r.cells, n + 1)
            r:Show()
        end
        HideFrom(g.rows, #others + 1)
        g.list:SetHeight(max(10, listH))
        g.scroll:Show()
        local below = y + min(listH, avail)
        local waiting = #res.waiting
        g.foot:ClearAllPoints()
        g.foot:SetPoint("TOPLEFT", 4, -(below + 6))
        g.foot:SetText(res.answered .. " of " .. res.total .. " answered" .. (waiting > 0 and (" · " .. waiting .. " waiting") or ""))
        g.foot:Show()
        -- the best night
        if res.best then
            g.best:ClearAllPoints()
            g.best:SetPoint("TOPLEFT", g, "TOPLEFT", x0 + (res.best - 1) * (cw + CELL_GAP) - 3, -10)
            g.best:SetSize(cw + 6, below - 6)
            g.best:Show()
        else
            g.best:Hide()
        end
    else
        g.tot:Hide()
        g.scroll:Hide()
        HideFrom(g.rows, 1)
        g.best:Hide()
        g.foot:ClearAllPoints()
        g.foot:SetPoint("TOPLEFT", 4, -(y + 8))
        g.foot:SetText(p.rv == "close" and ("Everyone's answers show when it closes " .. white(When(p.cl)) .. ".")
            or "Everyone's answers show after you save yours.")
        g.foot:Show()
    end
    -- Save
    local dirty = false
    if editing and state.days then
        for i = 1, n do
            if (state.days[i] or 0) ~= (mine and mine.c[i] or -1) then dirty = true break end
        end
    end
    g.save:SetShown(editing)
    g.save:SetEnabled(dirty)
    g.saveNote:SetShown(editing)
    g.saveNote:SetText(dirty and (mine and "Changed, not saved" or "Not sent yet") or (mine and "Saved" or ""))
end

---------------------------------------------------------------------------
-- New poll
---------------------------------------------------------------------------

local S = {}

local TIMES = {}
for h = 0, 23 do
    TIMES[#TIMES + 1] = ("%02d:00"):format(h)
    TIMES[#TIMES + 1] = ("%02d:30"):format(h)
end

local function NewDraft()
    local t = date("*t", Now() + 3 * DAY)
    return { q = "", k = "one", o = { "", "" }, mx = 0, rv = "vote", ch = true, a = {},
             cday = { t.year, t.month, t.day }, ctime = "20:00", days = {}, month = nil }
end

local function TargetKey(t)
    if t[1] == "t" then return "t:" .. t[2] .. ":" .. tostring(t[3] or "") end
    if t[1] == "g" then return "g" end
    return t[1] .. ":" .. tostring(t[2])
end

local function HasTarget(d, key)
    for i, t in ipairs(d.a) do
        if TargetKey(t) == key then return i end
    end
end

function S.ToggleTarget(t)
    local d = state.draft
    local key = TargetKey(t)
    local i = HasTarget(d, key)
    if i then
        table.remove(d.a, i)
    elseif t[1] == "g" then
        d.a = { t }                                           -- everyone replaces the other picks
    else
        local g = HasTarget(d, "g")
        if g then table.remove(d.a, g) end
        d.a[#d.a + 1] = t
    end
    S.RefreshAudience(panel.sheet)
end

local function ClosesAt(d)
    local hh, mm = d.ctime:match("^(%d%d):(%d%d)$")
    return time({ year = d.cday[1], month = d.cday[2], day = d.cday[3], hour = tonumber(hh) or 20,
                  min = tonumber(mm) or 0, sec = 0 })
end

-- The draft's answers as the poll stores them.
local function DraftAnswers(d)
    if d.k == "yn" then return { "Yes", "No" } end
    if d.k == "days" then
        local out = {}
        for _, e in ipairs(d.days) do out[#out + 1] = e.d .. (e.t and (" " .. e.t) or "") end
        return out
    end
    local out = {}
    for _, a in ipairs(d.o) do
        local s = ns.Util.Trim(a or "")
        if s ~= "" then out[#out + 1] = s end
    end
    return out
end

function S.Post()
    local d = state.draft
    local q = ns.Util.Trim(d.q or "")
    local o = DraftAnswers(d)
    local why
    if q == "" then why = "Write the question first."
    elseif d.k == "days" and #o == 0 then why = "Pick at least one day in the calendar."
    elseif (d.k == "one" or d.k == "many") and #o < 2 then why = "Give at least two answers."
    elseif #d.a == 0 then why = "Pick who votes."
    elseif ClosesAt(d) <= Now() + 60 then why = "Pick a closing time in the future."
    end
    if why then
        state.sheetErr = why
        S.Refresh(panel.sheet)
        return
    end
    local id, err = P():Create({ q = q, k = d.k, o = o, mx = d.k == "many" and d.mx or nil, cl = ClosesAt(d), rv = d.rv,
                                 ch = d.ch, a = d.a })
    if not id then
        state.sheetErr = err
        S.Refresh(panel.sheet)
        return
    end
    state.draft, state.sheetErr = nil, nil
    PollsUI:OpenPoll(id)
end

local function Label(parent, text)
    local fs = Text(parent, 11, { 0.62, 0.62, 0.62 })
    fs:SetText(text)
    return fs
end

local function Tile(parent, kind, glyph, title, sub)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(114, 46)
    b.bg = Fill(b, C.row)
    Edges(b, { 0.2, 0.2, 0.23, 1 })
    b.icon = IconTile(b, 24)
    b.icon:SetPoint("LEFT", 10, 0)
    b.icon:Set(kind)
    b.t = Text(b, 11, C.text)
    b.t:SetPoint("TOPLEFT", 42, -10)
    b.t:SetText(title)
    b.s = Text(b, 9, C.dim)
    b.s:SetPoint("TOPLEFT", 42, -26)
    b.s:SetText(sub)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.03)
    b.kind, b.glyph = kind, glyph
    function b:SetOn(on)
        if on then
            self.bg:SetColorTexture(C.pick[1], C.pick[2], C.pick[3], 1)
            UI():SetEdgeColor(self, 0.64, 0.51, 0.16, 1)
            Color(self.t, C.white)
        else
            self.bg:SetColorTexture(C.row[1], C.row[2], C.row[3], 1)
            UI():SetEdgeColor(self, 0.2, 0.2, 0.23, 1)
            Color(self.t, C.text)
        end
        self.icon.tex:SetDesaturated(not on)
        self.icon.tex:SetAlpha(on and 1 or 0.75)
    end
    b:SetScript("OnClick", function()
        state.draft.k = kind
        S.Refresh(panel.sheet)
    end)
    return b
end

function S.Build(v)
    v.back = BackLink(v)
    v.back:SetPoint("TOPLEFT", PAD, -8)
    v.title = Text(v, 17, C.white)
    v.title:SetPoint("TOPLEFT", PAD, -26)
    v.title:SetText("New poll")
    -- the left column scrolls (a long answer list, many days)
    v.scroll = UI():CreateScrollFrame(v)
    v.scroll:SetPoint("TOPLEFT", PAD, -56)
    v.scroll:SetSize(SHEET_L, PAGE_H - 56 - 40)
    v.left = CreateFrame("Frame", nil, v.scroll)
    v.left:SetSize(SHEET_L, 10)
    v.scroll:SetScrollChild(v.left)
    local L0 = v.left
    v.qLab = Label(L0, "Question")
    v.qLab:SetPoint("TOPLEFT", 0, 0)
    v.q = UI():CreateSleekEditBox(L0, SHEET_L, 24)
    v.q:SetPoint("TOPLEFT", 0, -16)
    v.q:SetMaxLetters(P().MAX_Q)
    v.q:SetTextColor(1, 1, 1)
    v.q:SetScript("OnTextChanged", function(self, user)
        if user then
            state.draft.q = self:GetText()
            S.RefreshPreview(v)
        end
    end)
    UI():SetEditPlaceholder(v.q, "Which night should we move SSC to?")
    v.kLab = Label(L0, "Kind")
    v.kLab:SetPoint("TOPLEFT", 0, -52)
    v.tiles = {}
    local defs = { { "one", PollIcon(), "One answer", "Pick one" }, { "many", PollIcon(), "Several", "Pick any" },
                   { "yn", CHECK_GLYPH, "Yes or no", "Quick answer" },
                   { "days", UI().ICON.calendar, "Pick days", "When can you" } }
    for i, d in ipairs(defs) do
        local t = Tile(L0, d[1], d[2], d[3], d[4])
        t:SetPoint("TOPLEFT", (i - 1) * 122, -68)
        v.tiles[i] = t
    end
    v.aLab = Label(L0, "Answers")
    v.answers = {}
    v.addAns = CreateFrame("Button", nil, L0)
    v.addAns:SetSize(SHEET_L, 22)
    UI():AddEdges(v.addAns)
    UI():SetEdgeColor(v.addAns, 0.23, 0.23, 0.26, 1)
    v.addAns.fs = Text(v.addAns, 10, C.dim)
    v.addAns.fs:SetPoint("LEFT", 22, 0)
    v.addAns.fs:SetText("Answer")
    v.addAns.icon = v.addAns:CreateTexture(nil, "ARTWORK")
    v.addAns.icon:SetSize(9, 9)
    v.addAns.icon:SetPoint("LEFT", 8, 0)
    Glyph(v.addAns.icon, UI().ICON.plus, C.dim)
    v.addAns:SetScript("OnClick", function()
        local d = state.draft
        if #d.o < P().MAX_ANSWERS then
            d.o[#d.o + 1] = ""
            S.Refresh(v)
            local eb = v.answers[#d.o] and v.answers[#d.o].eb
            if eb then eb:SetFocus() end
        end
    end)
    v.ynNote = Text(L0, 10, C.dim)
    v.ynNote:SetText("Voters answer Yes or No.")
    v.upTo = UI():CreateCheckbox(L0, "Up to", function() return state.draft and (state.draft.mx or 0) > 0 or false end, function(on)
        if not state.draft then return end
        state.draft.mx = on and 2 or 0
        S.Refresh(v)
    end)
    v.upToDD = UI():CreateSleekDropdown(L0, 50, function()
        local out = {}
        for i = 1, max(1, (state.draft and #DraftAnswers(state.draft) or 2) - 1) do out[#out + 1] = { value = i, text = tostring(i) } end
        return out
    end, function() return state.draft and state.draft.mx end, function(val)
        if not state.draft then return end
        state.draft.mx = val
        S.Refresh(v)
    end)
    v.upToDD:SetHeight(20)
    -- Pick days: the calendar and the picked days' times
    v.cal = S.BuildCalendar(L0)
    v.dayRows = {}
    v.tLab = Label(L0, "Start time (optional)")
    v.daysNote = Text(L0, 9, C.dim)
    v.daysNote:SetText("Voters tick each day: can, if needed or can't.")
    -- closes / results / can change
    v.cLab = Label(L0, "Closes")
    v.cDate = UI():CreateDatePicker(L0, {
        width = 104,
        get = function()
            if state.draft then return unpack(state.draft.cday) end
            local t = date("*t", Now() + 3 * DAY)
            return t.year, t.month, t.day
        end,
        set = function(y, m, d) if state.draft then state.draft.cday = { y, m, d } end end,
        minDate = function() local t = date("*t", Now()) return t.year, t.month, t.day end,
        maxDate = function() local t = date("*t", Now() + 59 * DAY) return t.year, t.month, t.day end,
    })
    local dateRefresh = v.cDate.Refresh
    function v.cDate:Refresh()
        dateRefresh(self)
        local d = state.draft
        if d then self:SetText(date("%a %d %b", time({ year = d.cday[1], month = d.cday[2], day = d.cday[3], hour = 12 }))) end
    end
    v.cTime = UI():CreateSleekDropdown(L0, 62, function()
        local out = {}
        for _, t in ipairs(TIMES) do out[#out + 1] = { value = t, text = t } end
        return out
    end, function() return state.draft and state.draft.ctime end, function(val)
        if state.draft then state.draft.ctime = val end
    end)
    v.cTime:SetHeight(22)
    v.rLab = Label(L0, "Results")
    v.seg = {}
    for i, d in ipairs({ { "live", "Live" }, { "vote", "After voting" }, { "close", "When closed" } }) do
        local b = Button(L0, d[2], 10, 22, "secondary", function()
            state.draft.rv = d[1]
            S.Refresh(v)
        end)
        FitButton(b, 40)
        b.key = d[1]
        v.seg[i] = b
    end
    v.change = UI():CreateCheckbox(L0, "Can change their answer", function() return state.draft and state.draft.ch or false end, function(on)
        if state.draft then state.draft.ch = on and true or false end
    end)
    -- the right column: who votes, the count, a preview
    local R0 = CreateFrame("Frame", nil, v)
    R0:SetPoint("TOPLEFT", PAD + SHEET_L + 18, -56)
    R0:SetPoint("BOTTOMRIGHT", -PAD, 40)
    v.right = R0
    v.wLab = Label(R0, "Who votes")
    v.wLab:SetPoint("TOPLEFT", 0, 0)
    v.chipBox = CreateFrame("Frame", nil, R0)
    v.chipBox:SetPoint("TOPLEFT", 0, -16)
    v.chipBox:SetPoint("TOPRIGHT", 0, -16)
    v.chipBox:SetHeight(26)
    Fill(v.chipBox, { 0.10, 0.10, 0.12, 0.92 })
    Edges(v.chipBox, { 0.34, 0.34, 0.38, 0.9 })
    v.chips = {}
    v.chipHint = Text(v.chipBox, 10, C.dim)
    v.chipHint:SetPoint("LEFT", 8, 0)
    v.chipHint:SetText("Nobody yet: add them below")
    local rw = PAGE_W - PAD - (PAD + SHEET_L + 18)
    v.search = UI():CreateSearchDropdown(R0, rw, {
        placeholder = "Add a team, role, rank or player",
        maxRows = 12,
        getItems = function() return S.AudienceItems() end,
        isChecked = function(key) return HasTarget(state.draft, key) ~= nil end,
        onToggle = function(key, e) if e.target then S.ToggleTarget(e.target) end end,
        footerText = function() return Plural(#S.Asked(), "person", "people") .. " asked" end,
        emptyText = "Nobody by that name.",
    })
    v.count = CreateFrame("Frame", nil, R0)
    v.count:SetSize(rw, 18)
    v.count.faces = {}
    v.count.fs = Text(v.count, 10, C.grey)
    v.count:SetScript("OnEnter", function(self)
        local keys = S.Asked()
        if #keys == 0 then return end
        local names = {}
        for i = 1, min(#keys, 30) do names[#names + 1] = Name(keys[i]) end
        if #keys > 30 then names[#names + 1] = Hex(C.dim, "and " .. (#keys - 30) .. " more") end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(Plural(#keys, "person", "people") .. " will be asked")
        GameTooltip:AddLine(tconcat(names, ", "), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    v.count:SetScript("OnLeave", HideTip)
    v.pvSect = Sect(R0)
    v.pvBan = Banner(R0, 104, false)
    v.preview = CreateFrame("Frame", nil, R0)
    v.preview:SetHeight(10)
    v.preview.items = {}
    -- the footer
    v.post = Button(v, "Post poll", 80, 22, "primary", function() S.Post() end)
    v.post:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    v.cancel = Button(v, "Cancel", 70, 22, "secondary", function()
        state.draft, state.sheetErr = nil, nil
        PollsUI:ShowList()
    end)
    v.cancel:SetPoint("RIGHT", v.post, "LEFT", -6, 0)
    v.err = Text(v, 10, C.red)
    v.err:SetPoint("RIGHT", v.cancel, "LEFT", -12, 0)
end

-- The calendar of a Pick days draft: a month, the picked days gold.
function S.BuildCalendar(parent)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(7 * 31, 22 + 16 + 6 * 26)
    c.lab = Label(c, "Days")
    c.lab:SetPoint("TOPLEFT", 0, 0)
    c.prev = UI():CreateArrowButton(c, false, 14, 14, function() S.ShiftMonth(-1) end)
    c.next = UI():CreateArrowButton(c, true, 14, 14, function() S.ShiftMonth(1) end)
    c.next:SetPoint("TOPRIGHT", 0, 2)
    c.prev:SetPoint("RIGHT", c.next, "LEFT", -4, 0)
    c.heads = {}
    for i, w in ipairs({ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" }) do
        local fs = Text(c, 9, { 0.55, 0.55, 0.55 })
        fs:SetJustifyH("CENTER")
        fs:SetWidth(31)
        fs:SetPoint("TOPLEFT", (i - 1) * 31, -18)
        fs:SetText(w)
        c.heads[i] = fs
    end
    c.cells = {}
    for i = 1, 42 do
        local b = CreateFrame("Button", nil, c)
        b:SetSize(31, 26)
        b:SetPoint("TOPLEFT", ((i - 1) % 7) * 31, -(32 + floor((i - 1) / 7) * 26))
        b.disc = b:CreateTexture(nil, "ARTWORK")
        b.disc:SetTexture(DISC)
        b.disc:SetSize(23, 23)
        b.disc:SetPoint("CENTER")
        b.disc:SetVertexColor(1, 0.82, 0)
        b.fs = Text(b, 11, C.text, true)
        b.fs:SetJustifyH("CENTER")
        b.fs:SetPoint("CENTER", 0, 0)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetTexture(DISC)
        b.hl:SetSize(23, 23)
        b.hl:SetPoint("CENTER")
        b.hl:SetVertexColor(1, 1, 1, 0.08)
        b:SetScript("OnClick", function(self) if self.day then S.ToggleDay(self.day) end end)
        c.cells[i] = b
    end
    return c
end

function S.ShiftMonth(delta)
    local d = state.draft
    local y, m = d.month[1], d.month[2] + delta
    if m < 1 then y, m = y - 1, 12 elseif m > 12 then y, m = y + 1, 1 end
    d.month = { y, m }
    S.Refresh(panel.sheet)
end

function S.ToggleDay(day)
    local d = state.draft
    for i, e in ipairs(d.days) do
        if e.d == day then
            table.remove(d.days, i)
            S.Refresh(panel.sheet)
            return
        end
    end
    if #d.days >= P().MAX_DAYS then return end
    local last = d.days[#d.days]
    d.days[#d.days + 1] = { d = day, t = last and last.t or "20:00" }
    tsort(d.days, function(a, b) return a.d < b.d end)
    S.Refresh(panel.sheet)
end

function S.FillCalendar(c)
    local d = state.draft
    if not d.month then
        local t = date("*t", Now())
        d.month = { t.year, t.month }
    end
    local y, m = d.month[1], d.month[2]
    c.lab:SetText("Days · " .. date("%B", time({ year = y, month = m, day = 1, hour = 12 })))
    local first = time({ year = y, month = m, day = 1, hour = 12 })
    local wd = (tonumber(date("%w", first)) + 6) % 7          -- Monday first
    local dim = tonumber(date("%d", time({ year = y, month = m + 1, day = 0, hour = 12 })))
    local t0 = date("*t", Now())
    local today = t0.year * 10000 + t0.month * 100 + t0.day
    local picked = {}
    for _, e in ipairs(d.days) do picked[e.d] = true end
    for i, b in ipairs(c.cells) do
        local dd = i - wd
        if dd >= 1 and dd <= dim then
            local key = ("%04d-%02d-%02d"):format(y, m, dd)
            local past = y * 10000 + m * 100 + dd < today
            b.fs:SetText(tostring(dd))
            b.day = not past and key or nil
            b.disc:SetShown(picked[key] and true or false)
            if picked[key] then
                Color(b.fs, { 0.1, 0.08, 0 })
                b.fs:SetShadowColor(0, 0, 0, 0)
            else
                Color(b.fs, past and { 0.33, 0.33, 0.35 } or C.text)
                b.fs:SetShadowColor(0, 0, 0, 1)
            end
            b:EnableMouse(not past)
            b:Show()
        else
            b:Hide()
        end
    end
    local now = date("*t", Now())
    c.prev:SetEnabled(y * 12 + m > now.year * 12 + now.month)
end

function S.Asked()
    local d = state.draft
    if not d or #d.a == 0 then return {} end
    local Pl = P()
    local Demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    return Demo and Pl:DemoResolve(d.a) or Pl:Resolve(d.a)
end

function S.AudienceItems()
    local out, head = {}, nil
    local HEADS = { team = "TEAMS", lineup = "TEAMS", role = "ROLES", rank = "RANKS", player = "PLAYERS" }
    local ICONS = { g = UI().ICON.team, team = UI().ICON.team, lineup = UI().ICON.team, role = UI().ICON.crown,
                    rank = UI().ICON.notes }
    for _, o in ipairs(P():AudienceOptions()) do
        local h = HEADS[o.kind]
        if h and h ~= head then
            out[#out + 1] = { header = h }
            head = h
        end
        local e = { key = TargetKey(o.target), target = o.target, note = o.kind ~= "player" and tostring(o.n) or nil }
        if o.kind == "player" then
            e.text, e.classFile = o.name, o.class
        else
            local co = UI():IconCoords(ICONS[o.kind] or UI().ICON.team)
            e.icon = { UI().ICON_ATLAS, co[1], co[2], co[3], co[4] }
            e.iconColor = o.kind == "g" and { 1, 0.82, 0 } or { 0.74, 0.74, 0.74 }
            e.text = o.kind == "lineup" and ("   " .. o.name) or o.name
            e.search = (o.team or "") .. " " .. o.name
            e.color = o.kind == "lineup" and "ffb0b0b4" or "ffe5e5e5"
        end
        out[#out + 1] = e
    end
    return out
end

function S.RefreshAudience(v)
    local d = state.draft
    local x, y, rowH = 5, 4, 22
    local boxW = v.chipBox:GetWidth()
    if not boxW or boxW < 50 then boxW = PAGE_W - PAD - (PAD + SHEET_L + 18) end
    for i, t in ipairs(d.a) do
        local ch = Pool(v.chips, i, function() return Chip(v.chipBox, 18, true) end)
        local n = #(P():Resolve({ t }))
        local face = t[1] == "p" and t[2] or nil
        local w = ch:Set(P():TargetName(t), TargetGlyph(t), t[1] ~= "p" and n or nil, true, face)
        if x + w > boxW - 5 then
            x, y = 5, y + rowH
        end
        ch:ClearAllPoints()
        ch:SetPoint("TOPLEFT", v.chipBox, "TOPLEFT", x, -y)
        ch:SetScript("OnClick", function() S.ToggleTarget(t) end)
        ch:SetScript("OnEnter", function(self) Tip(self, { P():TargetName(t), "Click to take it off." }) end)
        ch:SetScript("OnLeave", HideTip)
        x = x + w + 4
    end
    HideFrom(v.chips, #d.a + 1)
    v.chipHint:SetShown(#d.a == 0)
    local h = #d.a == 0 and 26 or (y + rowH + 4)
    v.chipBox:SetHeight(h)
    v.search.frame:ClearAllPoints()
    v.search.frame:SetPoint("TOPLEFT", v.chipBox, "BOTTOMLEFT", 0, -6)
    if v.search.RefreshRows then v.search:RefreshRows() end
    -- the count
    local keys = S.Asked()
    local fx = 0
    for i = 1, min(6, #keys) do
        local f = Pool(v.count.faces, i, function() return Face(v.count, 15) end)
        f:ClearAllPoints()
        f:SetPoint("LEFT", fx, 0)
        f:Set(keys[i])
        fx = fx + 11
    end
    HideFrom(v.count.faces, min(6, #keys) + 1)
    v.count.fs:ClearAllPoints()
    v.count.fs:SetPoint("LEFT", #keys > 0 and (fx + 8) or 0, 0)
    v.count.fs:SetText(#keys > 0 and (white(#keys) .. " " .. (#keys == 1 and "person" or "people") .. " will be asked")
        or "Pick teams, roles, ranks or players.")
    v.count:ClearAllPoints()
    v.count:SetPoint("TOPLEFT", v.search.frame, "BOTTOMLEFT", 0, -10)
    v.pvSect:ClearAllPoints()
    v.pvSect:SetPoint("TOPLEFT", v.count, "BOTTOMLEFT", 0, -14)
    v.pvSect:SetPoint("RIGHT", v.right, "RIGHT")
    v.pvSect:Set("Preview", "what voters see")
    v.pvBan:ClearAllPoints()
    v.pvBan:SetPoint("TOPLEFT", v.pvSect, "BOTTOMLEFT", 0, -10)
    v.pvBan:SetPoint("RIGHT", v.right, "RIGHT")
    v.preview:ClearAllPoints()
    v.preview:SetPoint("TOPLEFT", v.pvBan, "BOTTOMLEFT", 0, -10)
    v.preview:SetPoint("RIGHT", v.right, "RIGHT")
end

-- The preview banner: the list's banner as the people asked will see it (kicker, icon, the question on up to two
-- lines, who is asked).
function S.FillPreviewBanner(b, d, w)
    local fake = { id = "preview", k = d.k, a = d.a, cl = ClosesAt(d) }
    SetArt(b.art, fake, w, b:GetHeight())
    b.icon:Set(d.k)
    b.icon:SetSize(36, 36)
    b.icon:ClearAllPoints()
    b.icon:SetPoint("TOPLEFT", 12, -30)
    b.kick:SetText((KIND_WORD[d.k] .. " · closes " .. When(ClosesAt(d), true)):upper())
    b.kick:ClearAllPoints()
    b.kick:SetPoint("TOPLEFT", 12, -12)
    Sized(b.kick, 9)
    b.kick:Show()
    local q = ns.Util.Trim(d.q or "")
    Sized(b.q, 13)
    b.q:ClearAllPoints()
    b.q:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 10, -1)
    Wrap(b.q, q ~= "" and q or Hex(C.dim, "Your question"), w - 12 - 36 - 10 - 12, 13)
    b.meta:Hide(); b.pill:Hide(); b.bar:Hide(); b.btn:Hide(); b.seg:Hide(); b.segLab:Hide(); b.chip:Hide()
    b.more:Hide()
    local keys = S.Asked()
    local fx = 12
    for i = 1, min(6, #keys) do
        local f = Pool(b.faces, i, function() return RingFace(b, 14) end)
        f:ClearAllPoints()
        f:SetPoint("BOTTOMLEFT", fx, 12)
        f:SetFrameLevel(b:GetFrameLevel() + 2 + (6 - i))
        f:Set(keys[i])
        fx = fx + 10
    end
    HideFrom(b.faces, min(6, #keys) + 1)
    b.count:ClearAllPoints()
    b.count:SetPoint("BOTTOMLEFT", fx + (#keys > 0 and 10 or 0), 12)
    Sized(b.count, 10)
    b.count:SetText(#keys > 0 and (Plural(#keys, "person", "people") .. " asked") or "Nobody asked yet")
end

function S.RefreshPreview(v)
    local d = state.draft
    local pv = v.preview
    local w = PAGE_W - PAD - (PAD + SHEET_L + 18)
    S.FillPreviewBanner(v.pvBan, d, w)
    local y = 0
    local items = d.k == "days" and d.days or DraftAnswers(d)
    local n, dn = 0, 0
    pv.dayItems = pv.dayItems or {}
    if d.k == "days" then
        local cw = floor((w - 4 * 3) / 5)
        for i, e in ipairs(items) do
            if i > 10 then break end
            dn = dn + 1
            local b = Pool(pv.dayItems, dn, function()
                local f = CreateFrame("Frame", nil, pv)
                f.bg = Fill(f, C.no)
                Edges(f, C.noEdge)
                f.a = Text(f, 8, C.gold)
                f.a:SetJustifyH("CENTER")
                f.a:SetPoint("TOP", 0, -5)
                f.b = Text(f, 11, C.white, true)
                f.b:SetJustifyH("CENTER")
                f.b:SetPoint("TOP", f.a, "BOTTOM", 0, -1)
                return f
            end)
            b:SetSize(cw, 30)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", ((i - 1) % 5) * (cw + 3), -(y + floor((i - 1) / 5) * 34))
            local yy, mo, dd = P().DayParts(e.d)
            local t = time({ year = yy, month = mo, day = dd, hour = 12 })
            b.a:SetText(date("%a", t):upper())
            b.b:SetText(tostring(dd))
            if b.fs then b.fs:Hide() end
            b.bg:SetColorTexture(C.no[1], C.no[2], C.no[3], 1)
            b:Show()
        end
        y = y + ceil(min(#items, 10) / 5) * 34 + (#items == 0 and 0 or 4)
        if #items == 0 then
            n = n + 1
            local b = Pool(pv.items, n, function() return CreateFrame("Frame", nil, pv) end)
            if not b.fs then b.fs = Text(b, 10, C.dim) b.fs:SetPoint("LEFT") end
            b:SetSize(w, 14)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b.fs:SetText("Pick the days in the calendar.")
            b.fs:Show()
            if b.bg then b.bg:Hide() b.a:Hide() b.b:Hide() end
            b:Show()
            y = y + 18
        end
    else
        for i, a in ipairs(items) do
            if i > 6 then break end
            n = n + 1
            local b = Pool(pv.items, n, function() return CreateFrame("Frame", nil, pv) end)
            if not b.fs then
                b.fs = Text(b, 10, C.text)
                b.fs:SetPoint("LEFT", 16, 0)
                b.ring = b:CreateTexture(nil, "ARTWORK")
                b.ring:SetTexture(DISC)
                b.ring:SetSize(9, 9)
                b.ring:SetPoint("LEFT", 2, 0)
                b.ring:SetVertexColor(0.42, 0.42, 0.45)
            end
            if b.bg then b.bg:Hide() b.a:Hide() b.b:Hide() end
            b:SetSize(w, 16)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b.fs:SetText(a)
            b.fs:SetWidth(w - 40)
            b.fs:Show()
            if b.ring then b.ring:Show() end
            b:Show()
            y = y + 18
        end
        if #items > 6 then
            n = n + 1
            local b = Pool(pv.items, n, function() return CreateFrame("Frame", nil, pv) end)
            if not b.fs then b.fs = Text(b, 10, C.dim) b.fs:SetPoint("LEFT", 16, 0) end
            if b.ring then b.ring:Hide() end
            if b.bg then b.bg:Hide() b.a:Hide() b.b:Hide() end
            b:SetSize(w, 16)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b.fs:SetText("and " .. (#items - 6) .. " more")
            b.fs:Show()
            b:Show()
            y = y + 18
        end
    end
    HideFrom(pv.items, n + 1)
    HideFrom(pv.dayItems, dn + 1)
    pv:SetHeight(max(10, y))
end

function S.Refresh(v)
    local d = state.draft
    if not d then
        d = NewDraft()
        state.draft = d
    end
    if not v.q:HasFocus() then v.q:SetText(d.q or "") end
    for _, t in ipairs(v.tiles) do t:SetOn(t.kind == d.k) end
    local y = 126
    local L0 = v.left
    for _, r in ipairs(v.answers) do r:Hide() end
    v.addAns:Hide(); v.ynNote:Hide(); v.upTo:Hide(); v.upToDD:Hide()
    v.cal:Hide(); v.tLab:Hide(); v.daysNote:Hide()
    for _, r in ipairs(v.dayRows) do r:Hide() end
    v.aLab:ClearAllPoints()
    v.aLab:SetPoint("TOPLEFT", 0, -y)
    v.aLab:SetText(d.k == "days" and "" or "Answers")
    y = y + 16
    if d.k == "one" or d.k == "many" then
        for i = 1, #d.o do
            local r = Pool(v.answers, i, function()
                local f = CreateFrame("Frame", nil, L0)
                f:SetSize(SHEET_L, 22)
                f.eb = UI():CreateSleekEditBox(f, SHEET_L - 28, 22)
                f.eb:SetPoint("LEFT")
                f.eb:SetMaxLetters(P().MAX_A)
                f.eb:SetTextColor(1, 1, 1)
                f.bin = UI():CreateRemoveButton(f, "Take this answer off")
                f.bin:SetPoint("RIGHT")
                return f
            end)
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 0, -y)
            if not r.eb:HasFocus() then r.eb:SetText(d.o[i] or "") end
            r.eb:SetScript("OnTextChanged", function(self, user)
                if user then
                    d.o[i] = self:GetText()
                    S.RefreshPreview(v)
                end
            end)
            r.eb:SetScript("OnTabPressed", function()
                local nx = v.answers[i + 1]
                if nx and nx:IsShown() then nx.eb:SetFocus() end
            end)
            r.bin:SetScript("OnClick", function()
                if #d.o > 2 then table.remove(d.o, i) else d.o[i] = "" end
                S.Refresh(v)
            end)
            r:Show()
            y = y + 27
        end
        if #d.o < P().MAX_ANSWERS then
            v.addAns:ClearAllPoints()
            v.addAns:SetPoint("TOPLEFT", 0, -y)
            v.addAns:Show()
            y = y + 27
        end
        if d.k == "many" then
            v.upTo:ClearAllPoints()
            v.upTo:SetPoint("TOPLEFT", -4, -y)
            v.upTo:SetChecked((d.mx or 0) > 0)
            v.upTo:Show()
            if (d.mx or 0) > 0 then
                v.upToDD:ClearAllPoints()
                v.upToDD:SetPoint("LEFT", v.upTo, "RIGHT", 40, 0)
                v.upToDD:Show()
                if v.upToDD.Refresh then v.upToDD:Refresh() end
            end
            y = y + 26
        end
    elseif d.k == "yn" then
        v.ynNote:ClearAllPoints()
        v.ynNote:SetPoint("TOPLEFT", 0, -y)
        v.ynNote:Show()
        y = y + 18
    else
        y = y - 12
        v.cal:ClearAllPoints()
        v.cal:SetPoint("TOPLEFT", 0, -y)
        S.FillCalendar(v.cal)
        v.cal:Show()
        local tx = 7 * 31 + 18
        v.tLab:ClearAllPoints()
        v.tLab:SetPoint("TOPLEFT", tx, -y)
        v.tLab:Show()
        local ry = y + 12
        for i, e in ipairs(d.days) do
            local r = Pool(v.dayRows, i, function()
                local f = CreateFrame("Frame", nil, L0)
                f:SetSize(SHEET_L - tx, 25)
                f.fs = Text(f, 11, C.white)
                f.fs:SetPoint("LEFT", 0, 0)
                f.dd = UI():CreateSleekDropdown(f, 62, function()
                    local out = { { value = false, text = "No time" } }
                    for h = 16, 23 do
                        out[#out + 1] = { value = ("%02d:00"):format(h), text = ("%02d:00"):format(h) }
                        out[#out + 1] = { value = ("%02d:30"):format(h), text = ("%02d:30"):format(h) }
                    end
                    return out
                end, function() return f.e and (f.e.t or false) end, function(val)
                    if f.e then f.e.t = val or nil end
                    S.RefreshPreview(v)
                end)
                f.dd:SetHeight(20)
                f.dd:SetPoint("LEFT", 66, 0)
                f.bin = UI():CreateRemoveButton(f, "Take this day off")
                f.bin:SetPoint("RIGHT", 0, 0)
                f.rule = Line(f, { 1, 1, 1, 0.045 })
                f.rule:SetHeight(1)
                f.rule:SetPoint("BOTTOMLEFT")
                f.rule:SetPoint("BOTTOMRIGHT")
                return f
            end)
            r.e = e
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", tx, -ry)
            r.fs:SetText((P():DayLabel(e.d)))
            if r.dd.Refresh then r.dd:Refresh() end
            r.bin:SetScript("OnClick", function() S.ToggleDay(e.d) end)
            r:Show()
            ry = ry + 25
        end
        v.daysNote:ClearAllPoints()
        v.daysNote:SetPoint("TOPLEFT", tx, -(ry + 6))
        v.daysNote:SetText(#d.days == 0 and "Click days in the calendar to add them." or
            "Voters tick each day: can, if needed or can't.")
        v.daysNote:Show()
        y = max(y + v.cal:GetHeight(), ry + 22) + 4
    end
    -- closes / results / change
    y = y + 12
    v.cLab:ClearAllPoints(); v.cLab:SetPoint("TOPLEFT", 0, -y)
    v.rLab:ClearAllPoints(); v.rLab:SetPoint("TOPLEFT", 190, -y)
    v.cDate:ClearAllPoints(); v.cDate:SetPoint("TOPLEFT", 0, -(y + 16))
    if v.cDate.Refresh then v.cDate:Refresh() end
    v.cTime:ClearAllPoints(); v.cTime:SetPoint("LEFT", v.cDate, "RIGHT", 6, 0)
    if v.cTime.Refresh then v.cTime:Refresh() end
    local sx = 190
    for _, b in ipairs(v.seg) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", sx, -(y + 16))
        b:SetKind(b.key == d.rv and "chosen" or "secondary")
        sx = sx + b:GetWidth() - 1
    end
    y = y + 16 + 22 + 10
    v.change:ClearAllPoints()
    v.change:SetPoint("TOPLEFT", -4, -y)
    v.change:SetChecked(d.ch and true or false)
    y = y + 26
    v.left:SetHeight(y)
    S.RefreshAudience(v)
    S.RefreshPreview(v)
    v.err:SetText(state.sheetErr or "")
    v.err:SetShown(state.sheetErr ~= nil)
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

function PollsUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZonePollsPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.list = CreateFrame("Frame", nil, p)
    p.list:SetAllPoints()
    L.Build(p.list)
    p.poll = CreateFrame("Frame", nil, p)
    p.poll:SetAllPoints()
    V.Build(p.poll)
    p.sheet = CreateFrame("Frame", nil, p)
    p.sheet:SetAllPoints()
    S.Build(p.sheet)
    p:SetScript("OnShow", function() PollsUI:Refresh() end)
    self:Refresh()
    return p
end

function PollsUI:Refresh()
    if not panel then return end
    if state.view == "poll" and not P():GetPoll(state.poll) then state.view = "list" end
    if state.view == "new" and not P():AmIAsker() then state.view = "list" end
    panel.list:SetShown(state.view == "list")
    panel.poll:SetShown(state.view == "poll")
    panel.sheet:SetShown(state.view == "new")
    if state.view == "list" then
        L.Refresh(panel.list)
    elseif state.view == "poll" then
        V.Refresh(panel.poll)
    else
        S.Refresh(panel.sheet)
    end
end

function PollsUI:ShowList(tab)
    if tab then state.tab = tab end
    state.view = "list"
    state.changing, state.days, state.err = false, nil, nil
    self:Refresh()
end

function PollsUI:OpenPoll(id)
    if state.poll ~= id then state.pick, state.days = {}, nil end
    state.view, state.poll, state.changing, state.err = "poll", id, false, nil
    if ns.MainFrame and (not ns.MainFrame:IsShown() or ns.MainFrame:GetSelectedTab() ~= "polls") then
        ns.MainFrame:Open("polls")
    end
    self:Refresh()
end

function PollsUI:OpenNew()
    if not P():AmIAsker() then return end
    state.view = "new"
    if not state.draft then state.draft = NewDraft() end
    if ns.MainFrame and (not ns.MainFrame:IsShown() or ns.MainFrame:GetSelectedTab() ~= "polls") then
        ns.MainFrame:Open("polls")
    end
    self:Refresh()
end

---------------------------------------------------------------------------
-- The pop-up
---------------------------------------------------------------------------

local toast
local queue = {}

local function BuildToast()
    local f = CreateFrame("Frame", "DisasterZonePollToast", UIParent)
    f:SetSize(380, 112)
    f:SetPoint("TOP", UIParent, "TOP", 0, -140)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f.bg = Fill(f, { 0.05, 0.05, 0.063, 0.97 })
    Edges(f, { 0.56, 0.45, 0.13, 1 })
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(10, 10)
    f.icon:SetPoint("TOPLEFT", 12, -13)
    f.kick = Text(f, 9, C.gold)
    f.kick:SetPoint("LEFT", f.icon, "RIGHT", 5, 0)
    f.x = CreateFrame("Button", nil, f)
    f.x:SetSize(15, 15)
    f.x:SetPoint("TOPRIGHT", -6, -6)
    Edges(f.x, { 0.27, 0.27, 0.3, 1 })
    f.x.fs = Text(f.x, 9, C.dim)
    f.x.fs:SetJustifyH("CENTER")
    f.x.fs:SetPoint("CENTER", 0, 0)
    f.x.fs:SetText("x")
    f.x:SetScript("OnClick", function() PollsUI:HideToast() end)
    f.q = Text(f, 13, C.white)
    f.q:SetPoint("TOPLEFT", 12, -29)
    f.meta = Text(f, 10, C.grey)
    f.meta:SetPoint("TOPLEFT", f.q, "BOTTOMLEFT", 0, -5)
    f.a = Button(f, "Yes", 60, 22, "primary")
    f.a:SetPoint("BOTTOMLEFT", 12, 12)
    f.b = Button(f, "No", 60, 22, "secondary")
    f.b:SetPoint("LEFT", f.a, "RIGHT", 6, 0)
    f.later = CreateFrame("Button", nil, f)
    f.later:SetSize(44, 16)
    f.later:SetPoint("BOTTOMRIGHT", -12, 15)
    f.later.fs = Text(f.later, 10, C.dim)
    f.later.fs:SetJustifyH("RIGHT")
    f.later.fs:SetPoint("RIGHT")
    f.later.fs:SetText("Later")
    f.later:SetScript("OnClick", function() PollsUI:HideToast() end)
    f.later:SetScript("OnEnter", function(self) Color(self.fs, C.gold) end)
    f.later:SetScript("OnLeave", function(self) Color(self.fs, C.dim) end)
    f.tbar = f:CreateTexture(nil, "OVERLAY")
    f.tbar:SetPoint("BOTTOMLEFT", 1, 1)
    f.tbar:SetHeight(2)
    f.tbar:SetColorTexture(0.47, 0.83, 0.54, 1)
    f:Hide()
    return f
end

local function ShowNext()
    if toast and toast:IsShown() then return end
    if InCombatLockdown and InCombatLockdown() then return end
    while #queue > 0 do
        local item = table.remove(queue, 1)
        local p = P():GetPoll(item.id)
        if p and P():IsOpen(p) and P():AsksMe(p) and not P():MyVote(p) then
            PollsUI:ShowToast(p, item.nudge)
            return
        end
    end
end

function PollsUI:QueueToast(id, nudge)
    if ns.Notify then return end
    for _, item in ipairs(queue) do
        if item.id == id then
            item.nudge = item.nudge or nudge
            return
        end
    end
    queue[#queue + 1] = { id = id, nudge = nudge }
    ShowNext()
end

function PollsUI:ShowToast(p, nudge)
    toast = toast or BuildToast()
    local f = toast
    f.pid = p.id
    P():MarkShown(p.id)
    f:SetHeight(112)
    UI():SetEdgeColor(f, 0.56, 0.45, 0.13, 1)
    Glyph(f.icon, KindGlyph(p.k), C.gold)
    Color(f.kick, C.gold)
    local cr, cg, cb = UI():ClassColor(EUI():ClassOf(p.by))
    f.kick:SetText((nudge and "REMINDER · FROM " or "NEW POLL · FROM ")
        .. Hex({ cr, cg, cb }, (ns.Util.ShortName(p.by) or p.by):upper()))
    f.q:SetText(p.q)
    f.q:SetWidth(352)
    local meta = { KIND_WORD[p.k] }
    if p.k == "days" then meta[#meta + 1] = Plural(#p.o, "day") end
    meta[#meta + 1] = TargetsWord(p)
    meta[#meta + 1] = ClosesWord(p)
    f.meta:SetText(tconcat(meta, " · "))
    f.meta:SetWidth(352)
    f.tbar:Hide()
    f.later:Show()
    if p.k == "yn" then
        f.a:SetText("Yes"); f.a:SetKind("primary"); f.a:SetWidth(60)
        f.b:SetText("No"); f.b:SetWidth(60)
        f.a:SetScript("OnClick", function() PollsUI:ToastVote(p.id, 1) end)
        f.b:SetScript("OnClick", function() PollsUI:ToastVote(p.id, 2) end)
        f.b:Show()
    else
        f.a:SetText("Answer"); f.a:SetKind("primary"); FitButton(f.a, 70)
        f.a:SetScript("OnClick", function()
            PollsUI:HideToast()
            PollsUI:OpenPoll(p.id)
        end)
        f.b:Hide()
    end
    f.a:Show()
    f:SetAlpha(1)
    f:Show()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_CHAT_EMOTE_BUTTON then PlaySound(SOUNDKIT.IG_CHAT_EMOTE_BUTTON) end
end

-- Answered from the pop-up: it says so with the running totals, then goes.
function PollsUI:ToastVote(id, i)
    local ok = P():Vote(id, { i })
    local f = toast
    local p = P():GetPoll(id)
    if not ok or not p or not f then
        PollsUI:HideToast()
        return
    end
    local res = P():Results(p)
    UI():SetEdgeColor(f, 0.24, 0.42, 0.27, 1)
    Glyph(f.icon, CHECK, C.green)
    Color(f.kick, C.green)
    f.kick:SetText("ANSWERED · " .. (p.o[i] or ""):upper())
    if P():ResultsShown(p) then
        f.meta:SetText(white(res.counts[1]) .. " yes · " .. white(res.counts[2]) .. " no so far · " .. Hex(C.gold, "Open"))
    else
        f.meta:SetText("Thanks. Results show " .. (p.rv == "close" and ("when it closes " .. When(p.cl)) or "on the poll") .. ".")
    end
    f.a:Hide(); f.b:Hide(); f.later:Hide()
    f:SetHeight(84)
    local w = f:GetWidth() - 2
    f.tbar:SetWidth(max(1, w * (res.total > 0 and res.answered / res.total or 0)))
    f.tbar:Show()
    f.meta:SetScript("OnMouseUp", nil)
    f:SetScript("OnMouseUp", function()
        PollsUI:HideToast()
        PollsUI:OpenPoll(id)
    end)
    C_Timer.After(5, function()
        if toast and toast:IsShown() and toast.pid == id and not toast.a:IsShown() then PollsUI:HideToast() end
    end)
end

function PollsUI:HideToast()
    if toast then
        toast:Hide()
        toast:SetScript("OnMouseUp", nil)
    end
    C_Timer.After(0.4, ShowNext)
end

function PollsUI:GetToast() return toast end

---------------------------------------------------------------------------
-- Badges: the minimap button's count
---------------------------------------------------------------------------

-- (only while there is no notification center: Core/Notify.lua then counts and pops up polls itself)
local function RefreshBadges()
    if ns.Notify then return end
    local n = P():WaitingCount()
    local LDBI = LibStub and LibStub("LibDBIcon-1.0", true)
    local btn = LDBI and LDBI.GetMinimapButton and LDBI:GetMinimapButton("DisasterZone")
    if btn then
        if not btn.dzCount then
            local c = CreateFrame("Frame", nil, btn)
            c:SetSize(14, 14)
            c:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1)
            c:SetFrameLevel(btn:GetFrameLevel() + 5)
            c.disc = c:CreateTexture(nil, "OVERLAY")
            c.disc:SetTexture(DISC)
            c.disc:SetAllPoints()
            c.disc:SetVertexColor(1, 0.66, 0.24)
            c.fs = Text(c, 9, { 0.1, 0.06, 0 }, true)
            c.fs:SetShadowOffset(0, 0)
            c.fs:SetJustifyH("CENTER")
            c.fs:SetPoint("CENTER", 0.5, 0)
            btn.dzCount = c
        end
        btn.dzCount.fs:SetText(n > 9 and "9+" or tostring(n))
        btn.dzCount:SetShown(n > 0)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function PollsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("polls", "Polls", 3.575, function(parent) return PollsUI:CreatePanel(parent) end,
            function() return IsInGuild() or (ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()) end)
    end
    ns:On("POLLS_UPDATED", function()
        if panel and panel:IsVisible() then PollsUI:Refresh() end
        RefreshBadges()
        if toast and toast:IsShown() and toast.a:IsShown() then
            local p = P():GetPoll(toast.pid)
            if not p or not P():IsOpen(p) or P():MyVote(p) then PollsUI:HideToast() end
        end
    end)
    ns:On("POLL_ARRIVED", function(id) PollsUI:QueueToast(id) end)
    ns:On("POLL_NUDGED", function(id) PollsUI:QueueToast(id, true) end)
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function() C_Timer.After(1, ShowNext) end)
    ns:RegisterSlash("polls", function() ns.MainFrame:Open("polls") end, "open the guild's polls")
end

function PollsUI:OnLogin()
    -- after the login settles (and the guild's polls had a moment to sync): the polls I haven't seen pop up
    C_Timer.After(25, function()
        for _, p in ipairs(P():GetWaiting()) do
            if not P():WasShown(p.id) then PollsUI:QueueToast(p.id) end
        end
        RefreshBadges()
    end)
    C_Timer.After(3, RefreshBadges)
end

---------------------------------------------------------------------------
-- Test / audit hooks
---------------------------------------------------------------------------

function PollsUI:GetState() return state end
function PollsUI:GetPanel() return panel end
function PollsUI:SetDraft(d)
    state.draft = d
    if d then
        local base = NewDraft()
        for k, val in pairs(base) do if d[k] == nil then d[k] = val end end
    end
    self:Refresh()
end
function PollsUI:Pick(i)
    state.pick[i] = true
    self:Refresh()
end
function PollsUI:SetDays(list)
    state.days = list
    self:Refresh()
end
function PollsUI:OpenAudience()
    if panel and panel.sheet.search and panel.sheet.search.Open then panel.sheet.search:Open() end
end

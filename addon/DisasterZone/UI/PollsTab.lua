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
-- The list
---------------------------------------------------------------------------

local L = {}

function L.NewRow(parent)
    local r = CreateFrame("Button", nil, parent)
    r:SetHeight(ROW_H)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetColorTexture(1, 1, 1, 0.03)
    r.line = Line(r, { 1, 1, 1, 0.045 })
    r.line:SetHeight(1)
    r.line:SetPoint("BOTTOMLEFT")
    r.line:SetPoint("BOTTOMRIGHT")
    r.box = CreateFrame("Frame", nil, r)
    r.box:SetSize(40, 40)
    r.box:SetPoint("LEFT", 0, 0)
    Fill(r.box, { 0.094, 0.094, 0.11, 1 })
    Edges(r.box, CARD_EDGE)
    r.glyph = r.box:CreateTexture(nil, "ARTWORK")
    r.glyph:SetSize(20, 20)
    r.glyph:SetPoint("CENTER")
    r.dot = r.box:CreateTexture(nil, "OVERLAY")
    r.dot:SetTexture(DISC)
    r.dot:SetSize(8, 8)
    r.dot:SetVertexColor(1, 0.82, 0)
    r.dot:SetPoint("CENTER", r.box, "TOPRIGHT", -1, -1)
    r.title = Text(r, 12, C.white)
    r.title:SetPoint("TOPLEFT", 51, -11)
    r.meta = Text(r, 10, C.grey)
    r.meta:SetPoint("TOPLEFT", r.title, "BOTTOMLEFT", 0, -4)
    r.b1 = Button(r, "", 64, 22, "primary")
    r.b2 = Button(r, "", 40, 18, "secondary")
    r.more = UI():CreateTipIconButton(r, 18, UI().ICON.more, "More", nil, function() end)
    r.mini = CreateFrame("Frame", nil, r)
    r.mini:SetSize(115, 20)
    r.mini.l = Text(r.mini, 10, { 0.74, 0.74, 0.74 })
    r.mini.l:SetPoint("TOPLEFT")
    r.mini.r = Text(r.mini, 10, { 0.74, 0.74, 0.74 }, true)
    r.mini.r:SetJustifyH("RIGHT")
    r.mini.r:SetPoint("TOPRIGHT")
    r.mini.bar = Bar(r.mini, 4)
    r.mini.bar:SetPoint("BOTTOMLEFT")
    r.mini.bar:SetPoint("BOTTOMRIGHT")
    r.mini.bar:SetWidth(115)
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

-- Fills a list row for poll p in section `sec` ("wait" | "done" | "mine" | "closed").
function L.Fill(r, p, sec, w)
    r.pid = p.id
    r:SetWidth(w)
    Glyph(r.glyph, KindGlyph(p.k), { 0.81, 0.81, 0.81 })
    r.dot:SetShown(sec == "wait")
    r.title:SetText(p.q)
    local res = P():Results(p)
    local meta = { KIND_WORD[p.k] }
    local mine = P():MyVote(p)
    if sec == "wait" or sec == "closed" or sec == "mine" then
        if not IsMe(p.by) then meta[#meta + 1] = "asked by " .. Name(p.by) end
        meta[#meta + 1] = TargetsWord(p)
        meta[#meta + 1] = ClosesWord(p)
    else
        if mine and p.k ~= "days" then
            local picks = {}
            for _, i in ipairs(mine.c) do picks[#picks + 1] = p.o[i] end
            meta[#meta + 1] = #picks == 1 and ("you picked " .. white(picks[1])) or ("you picked " .. #picks)
        else
            meta[#meta + 1] = "you answered"
        end
        if P():ResultsShown(p) then
            meta[#meta + 1] = res.answered .. " of " .. res.total .. " answered"
        else
            meta[#meta + 1] = "results when it closes " .. white(When(p.cl))
        end
    end
    r.meta:SetText(tconcat(meta, " · "))
    r.b1:Hide(); r.b2:Hide(); r.more:Hide(); r.mini:Hide(); r.lock:Hide()
    local right = 0
    if sec == "wait" then
        if p.k == "yn" then
            r.b1:SetText("No"); r.b1:SetKind("secondary"); FitButton(r.b1, 44)
            r.b2:SetText("Yes"); r.b2:SetHeight(22); r.b2:SetKind("secondary"); FitButton(r.b2, 44)
            Sized(r.b2:GetFontString(), 11)
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", -4, 0)
            r.b2:ClearAllPoints(); r.b2:SetPoint("RIGHT", r.b1, "LEFT", -8, 0)
            r.b1:SetScript("OnClick", function() P():Vote(p.id, { 2 }) end)
            r.b2:SetScript("OnClick", function() P():Vote(p.id, { 1 }) end)
            r.b1:Show(); r.b2:Show()
            right = r.b1:GetWidth() + r.b2:GetWidth() + 16
        else
            r.b1:SetText("Answer"); r.b1:SetKind("primary"); FitButton(r.b1, 70)
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", -4, 0)
            r.b1:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
            r.b1:Show()
            right = r.b1:GetWidth() + 8
        end
    elseif sec == "mine" then
        r.dot:SetShown(P():AsksMe(p) and not mine)
        r.more:ClearAllPoints(); r.more:SetPoint("RIGHT", -4, 0)
        r.more:SetScript("OnClick", function(self) ManageMenu(self, p) end)
        r.more:Show()
        r.mini.l:SetText("Answered")
        r.mini.r:SetText(res.answered .. "/" .. res.total)
        r.mini.bar.fill:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
        r.mini.bar:Set(res.total > 0 and res.answered / res.total or 0, 115)
        r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", r.more, "LEFT", -10, 0)
        r.mini:Show()
        right = 115 + 32
    else
        local shown = P():ResultsShown(p)
        local lead, share = Leading(p, res)
        if shown and lead then
            r.mini.r:SetText(share .. "%")
            local room = 115 - TextW(r.mini.r) - 6
            for _, size in ipairs({ 10, 9, 8 }) do
                Sized(r.mini.l, size)
                r.mini.l:SetText(lead)
                if TextW(r.mini.l) <= room then break end
            end
            if TextW(r.mini.l) > room then r.mini.l:SetText("Leading") end
            r.mini.bar.fill:SetColorTexture(C.bar[1], C.bar[2], C.bar[3], 1)
            r.mini.bar:Set(share / 100, 115)
            r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", -4, 0)
            r.mini:Show()
            right = 120
        elseif not shown then
            r.lock.fs:SetText("Results " .. When(p.cl))
            r.lock:SetWidth(16 + TextW(r.lock.fs))
            r.lock:ClearAllPoints(); r.lock:SetPoint("RIGHT", -4, 0)
            r.lock:Show()
            right = r.lock:GetWidth() + 8
        end
    end
    -- (the title and line never run under the right side)
    local room = w - 51 - right - 12
    r.title:SetWidth(room)
    r.meta:SetWidth(room)
    r:Show()
end

function L.Build(v)
    v.tabOpen = UI():CreateUnderlineTab(v, "Open", function() PollsUI:ShowList("open") end, "page")
    v.tabOpen:SetPoint("TOPLEFT", PAD - 4, -6)
    v.tabClosed = UI():CreateUnderlineTab(v, "Closed", function() PollsUI:ShowList("closed") end, "page")
    v.tabClosed:SetPoint("LEFT", v.tabOpen, "RIGHT", 4, 0)
    v.new = Button(v, "New poll", 96, 22, "secondary", function() PollsUI:OpenNew() end, UI().ICON.plus)
    v.new:SetPoint("TOPRIGHT", -PAD, -8)
    v.scroll = UI():CreateScrollFrame(v)
    v.scroll:SetPoint("TOPLEFT", PAD, -(TABS_H + 10))
    v.scroll:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(PAGE_W - 2 * PAD, 10)
    v.scroll:SetScrollChild(v.content)
    v.heads, v.rows = {}, {}
    v.empty = Text(v.content, 11, C.dim)
    v.emptyBtn = Button(v.content, "New poll", 96, 22, "primary", function() PollsUI:OpenNew() end, UI().ICON.plus)
end

function L.Refresh(v)
    local Pl = P()
    local polls = Pl:GetPolls()
    local waiting = Pl:WaitingCount()
    UI():SetTabCount(v.tabOpen, waiting)
    v.tabOpen:SetActive(state.tab == "open")
    v.tabClosed:SetActive(state.tab == "closed")
    v.new:SetShown(Pl:AmIAsker())
    local groups = {}
    if state.tab == "open" then
        local wait, done, mine = {}, {}, {}
        for _, p in ipairs(polls) do
            if Pl:IsOpen(p) then
                if IsMe(p.by) then
                    mine[#mine + 1] = p
                elseif Pl:AsksMe(p) then
                    if Pl:MyVote(p) then done[#done + 1] = p else wait[#wait + 1] = p end
                end
            end
        end
        groups = { { "Waiting for you", wait, "wait" }, { "Answered", done, "done" }, { "Your polls", mine, "mine" } }
    else
        local closed = {}
        for _, p in ipairs(polls) do
            if not Pl:IsOpen(p) then closed[#closed + 1] = p end
        end
        groups = { { "Closed", closed, "closed" } }
    end
    local total, heads = 0, 0
    for _, g in ipairs(groups) do
        if #g[2] > 0 then
            heads = heads + 1
            total = total + min(#g[2], MAX_LIST_ROWS)
        end
    end
    local avail = (v.scroll:GetHeight() or 0) > 50 and v.scroll:GetHeight() or (PAGE_H - TABS_H - 20)
    local need = total * ROW_H + heads * 28 + max(0, heads - 1) * 12
    local cw = need > avail and (PAGE_W - 2 * PAD - 14) or (PAGE_W - 2 * PAD)
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
            s:Set(g[1])
            y = y + 28
            for i = 1, min(#g[2], MAX_LIST_ROWS) do
                ri = ri + 1
                local r = Pool(v.rows, ri, function() return L.NewRow(v.content) end)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
                L.Fill(r, g[2][i], g[3], cw)
                y = y + ROW_H
            end
        end
    end
    HideFrom(v.heads, hi + 1)
    HideFrom(v.rows, ri + 1)
    v.empty:Hide()
    v.emptyBtn:Hide()
    if ri == 0 then
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

function V.Build(v)
    v.back = CreateFrame("Button", nil, v)
    v.back:SetSize(60, 14)
    v.back:SetPoint("TOPLEFT", PAD, -8)
    v.back.fs = Text(v.back, 9, { 0.55, 0.55, 0.55 })
    v.back.fs:SetPoint("LEFT")
    v.back.fs:SetText("‹ POLLS")
    v.back:SetScript("OnClick", function() PollsUI:ShowList() end)
    v.back:SetScript("OnEnter", function(self) Color(self.fs, C.gold) end)
    v.back:SetScript("OnLeave", function(self) Color(self.fs, { 0.55, 0.55, 0.55 }) end)
    v.kick = Text(v, 10, C.gold)
    v.kick:SetPoint("TOPLEFT", PAD, -28)
    v.q = Text(v, 17, C.white)
    v.q:SetPoint("TOPLEFT", PAD, -43)
    v.meta = Text(v, 10, C.grey)
    v.meta:SetPoint("TOPLEFT", PAD, -71)
    v.chips = {}
    v.more = UI():CreateTipIconButton(v, 18, UI().ICON.more, "More", "Close, extend or remove the poll.", function(self)
        local p = P():GetPoll(state.poll)
        if p then ManageMenu(self, p) end
    end)
    v.more:SetPoint("TOPRIGHT", -PAD, -26)
    -- the answers / results column (scrolls when long)
    v.scroll = UI():CreateScrollFrame(v)
    v.scroll:SetPoint("TOPLEFT", PAD, -104)
    v.scroll:SetSize(LEFT_W, PAGE_H - 104 - PAD)
    v.body = CreateFrame("Frame", nil, v.scroll)
    v.body:SetSize(LEFT_W, 10)
    v.scroll:SetScrollChild(v.body)
    v.ans, v.res = {}, {}
    v.vote = Button(v.body, "Vote", 70, 22, "primary", function() V.SendVote() end)
    v.note = Text(v.body, 10, C.dim)
    v.change = Button(v.body, "Change vote", 100, 22, "secondary", function()
        state.changing = true
        local p = P():GetPoll(state.poll)
        local mine = p and P():MyVote(p)
        state.pick = {}
        for _, i in ipairs(mine and mine.c or {}) do state.pick[i] = true end
        PollsUI:Refresh()
    end)
    v.err = Text(v.body, 10, C.red)
    -- the card at the right
    v.card = CreateFrame("Frame", nil, v)
    v.card:SetPoint("TOPLEFT", CARD_X, -104)
    v.card:SetPoint("TOPRIGHT", -PAD, -104)
    v.card:SetHeight(200)
    Fill(v.card, CARD)
    Edges(v.card, CARD_EDGE)
    v.card.title = Text(v.card, 12, C.gold)
    v.card.title:SetPoint("TOPLEFT", 9, -9)
    v.card.right = Text(v.card, 10, { 0.74, 0.74, 0.74 })
    v.card.right:SetJustifyH("RIGHT")
    v.card.right:SetPoint("TOPRIGHT", -9, -10)
    v.card.rule = Line(v.card, { 0.14, 0.14, 0.15, 1 })
    v.card.rule:SetHeight(1)
    v.card.rule:SetPoint("TOPLEFT", 1, -28)
    v.card.rule:SetPoint("TOPRIGHT", -1, -28)
    v.card.people = {}
    v.card.more = Text(v.card, 10, C.dim)
    v.card.nudge = Button(v.card, "Nudge them", 96, 20, "secondary", function()
        local n, why = P():Nudge(state.poll)
        if n and n > 0 then
            ns:Print("reminded %s about the poll.", Plural(n, "player"))
        elseif why == "soon" then
            ns:Print("you nudged them a moment ago: wait a few minutes before the next one.")
        end
    end, UI().ICON.whisper)
    v.card2 = CreateFrame("Frame", nil, v)
    v.card2:SetPoint("TOPLEFT", v.card, "BOTTOMLEFT", 0, -GAP)
    v.card2:SetPoint("TOPRIGHT", v.card, "BOTTOMRIGHT", 0, -GAP)
    v.card2:SetHeight(64)
    Fill(v.card2, CARD)
    Edges(v.card2, CARD_EDGE)
    v.card2.fs = Text(v.card2, 10, C.grey)
    v.card2.fs:SetPoint("TOPLEFT", 9, -10)
    v.card2.close = Button(v.card2, "Close now", 80, 20, "secondary", function() P():Close(state.poll) end)
    v.card2.close:SetPoint("TOPLEFT", 9, -30)
    v.card2.extend = Button(v.card2, "Extend", 64, 20, "secondary", function() P():Extend(state.poll, DAY) end)
    v.card2.extend:SetPoint("LEFT", v.card2.close, "RIGHT", 6, 0)
    -- Pick days
    v.grid = CreateFrame("Frame", nil, v)
    v.grid:SetPoint("TOPLEFT", PAD, -104)
    v.grid:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    V.BuildGrid(v.grid)
end

local function AnswerRow(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(LEFT_W, ANS_H)
    b.bg = Fill(b, C.row)
    Edges(b, C.rowEdge)
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetColorTexture(1, 0.82, 0, 1)
    b.bar:SetPoint("TOPLEFT", -1, 1)
    b.bar:SetPoint("BOTTOMLEFT", -1, -1)
    b.bar:SetWidth(3)
    b.ring = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.ring:SetTexture(DISC)
    b.ring:SetSize(13, 13)
    b.ring:SetPoint("LEFT", 10, 0)
    b.hole = b:CreateTexture(nil, "ARTWORK", nil, 2)
    b.hole:SetTexture(DISC)
    b.hole:SetSize(10, 10)
    b.hole:SetPoint("CENTER", b.ring)
    b.dot = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.dot:SetTexture(DISC)
    b.dot:SetSize(6, 6)
    b.dot:SetPoint("CENTER", b.ring)
    b.dot:SetVertexColor(1, 0.82, 0)
    b.box = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.box:SetSize(12, 12)
    b.box:SetPoint("LEFT", 10, 0)
    b.check = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.check:SetTexture(CHECK)
    b.check:SetSize(18, 18)
    b.check:SetPoint("CENTER", b.box, "CENTER", 1, 0)
    b.check:SetVertexColor(1, 0.82, 0)
    b.fs = Text(b, 12, C.text)
    b.fs:SetPoint("LEFT", 32, 0)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints()
    b.hl:SetColorTexture(1, 1, 1, 0.03)
    function b:Set(text, multi, on)
        self.fs:SetText(text)
        self.fs:SetWidth(LEFT_W - 44)
        self.ring:SetShown(not multi)
        self.hole:SetShown(not multi)
        self.dot:SetShown(not multi and on)
        self.box:SetShown(multi)
        self.check:SetShown(multi and on)
        self.bar:SetShown(on)
        if on then
            self.bg:SetColorTexture(C.pick[1], C.pick[2], C.pick[3], 1)
            UI():SetEdgeColor(self, C.pickEdge[1], C.pickEdge[2], C.pickEdge[3], 1)
            Color(self.fs, C.white)
            self.ring:SetVertexColor(1, 0.82, 0, 1)
            self.hole:SetVertexColor(C.pick[1], C.pick[2], C.pick[3], 1)
            self.box:SetColorTexture(0.18, 0.15, 0.09, 1)
        else
            self.bg:SetColorTexture(C.row[1], C.row[2], C.row[3], 1)
            UI():SetEdgeColor(self, C.rowEdge[1], C.rowEdge[2], C.rowEdge[3], 1)
            Color(self.fs, C.text)
            self.ring:SetVertexColor(0.42, 0.42, 0.45, 1)
            self.hole:SetVertexColor(C.row[1], C.row[2], C.row[3], 1)
            self.box:SetColorTexture(0.3, 0.3, 0.33, 1)
        end
        self:Show()
    end
    return b
end

local function ResultBlock(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(LEFT_W)
    f.l = Text(f, 12, C.white)
    f.l:SetPoint("TOPLEFT", 0, 0)
    f.mine = CreateFrame("Frame", nil, f)
    f.mine:SetSize(70, 14)
    UI():AddPillShape(f.mine, 14)
    f.mine:SetPillColors({ 0.18, 0.15, 0.09, 1 }, { 0.54, 0.45, 0.13, 1 })
    f.mine.icon = f.mine:CreateTexture(nil, "ARTWORK")
    f.mine.icon:SetTexture(CHECK)
    f.mine.icon:SetSize(13, 13)
    f.mine.icon:SetPoint("LEFT", 4, 0)
    f.mine.icon:SetVertexColor(1, 0.82, 0)
    f.mine.fs = Text(f.mine, 9, C.gold)
    f.mine.fs:SetPoint("LEFT", f.mine.icon, "RIGHT", 1, 0)
    f.mine.fs:SetText("Your vote")
    f.mine:SetPoint("LEFT", f.l, "RIGHT", 7, 0)
    f.c = Text(f, 11, { 0.74, 0.74, 0.74 }, true)
    f.c:SetJustifyH("RIGHT")
    f.c:SetPoint("TOPRIGHT", 0, -1)
    f.bar = Bar(f, 6)
    f.bar:SetPoint("TOPLEFT", 0, -19)
    f.bar:SetPoint("TOPRIGHT", 0, -19)
    f.names = Text(f, 9, C.dim)
    f.names:SetPoint("TOPLEFT", 0, -30)
    return f
end

local function PersonRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(21)
    r.face = Face(r, 14)
    r.face:SetPoint("LEFT", 0, 0)
    r.fs = Text(r, 10, C.white)
    r.fs:SetPoint("LEFT", r.face, "RIGHT", 5, 0)
    r.mark = r:CreateTexture(nil, "ARTWORK")
    r.mark:SetTexture(CHECK)
    r.mark:SetSize(15, 15)
    r.mark:SetPoint("RIGHT", 0, 0)
    r.mark:SetVertexColor(0.31, 0.83, 0.42)
    r.wait = Text(r, 9, C.dim)
    r.wait:SetJustifyH("RIGHT")
    r.wait:SetPoint("RIGHT", 0, 0)
    r.wait:SetText("waiting")
    return r
end

-- The card: who answered (names, not picks), or (the asker; or results shown) who hasn't.
function V.FillCard(v, p, res, manage)
    local c = v.card
    local list, title, right, marks
    if manage then
        list, title, right, marks = res.waiting, "Not answered", res.waiting and (#res.waiting .. " of " .. res.total), false
    else
        list, title, right, marks = p.m, "Asked", res.answered .. "/" .. res.total .. " answered", true
    end
    c.title:SetText(title)
    c.right:SetText(right)
    local cw = c:GetWidth()
    if not cw or cw < 50 then cw = PAGE_W - CARD_X - PAD end
    local colW = floor((cw - 18 - 12) / 2)
    -- answered first when the card shows marks
    local keys = {}
    for _, k in ipairs(list) do keys[#keys + 1] = k end
    if marks then
        tsort(keys, function(a, b)
            local va, vb = res.votes[a] ~= nil, res.votes[b] ~= nil
            if va ~= vb then return va end
            return a < b
        end)
    end
    local maxRows = manage and 7 or 9
    local shown = min(#keys, maxRows * 2)
    if #keys > maxRows * 2 then shown = maxRows * 2 - 1 end
    for i = 1, shown do
        local r = Pool(c.people, i, function() return PersonRow(c) end)
        local k = keys[i]
        local vote = res.votes[k]
        local who = vote and vote.by or k
        r:SetWidth(colW)
        r:ClearAllPoints()
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        r:SetPoint("TOPLEFT", 9 + col * (colW + 12), -(34 + row * 21))
        r.face:Set(who)
        r.fs:SetText(Name(who))
        r.fs:SetWidth(colW - 19 - (marks and (vote and 18 or 40) or 0))
        r.mark:SetShown(marks and vote ~= nil)
        r.wait:SetShown(marks and vote == nil)
        r:Show()
    end
    HideFrom(c.people, shown + 1)
    local rows = ceil(shown / 2)
    local y = 34 + rows * 21
    c.more:Hide()
    if #keys > shown then
        c.more:ClearAllPoints()
        c.more:SetPoint("TOPLEFT", 9 + (shown % 2) * (colW + 12), -(34 + (rows - (shown % 2 == 1 and 1 or 0)) * 21 + 4))
        c.more:SetText("and " .. (#keys - shown) .. " more")
        c.more:Show()
        if shown % 2 == 0 then y = y + 21 end
    end
    if #keys == 0 then
        c.more:ClearAllPoints()
        c.more:SetPoint("TOPLEFT", 9, -38)
        c.more:SetText(manage and "Everyone has answered." or "Nobody yet.")
        c.more:Show()
        y = 58
    end
    c.nudge:Hide()
    if manage and #keys > 0 and P():IsOpen(p) then
        c.nudge:ClearAllPoints()
        c.nudge:SetPoint("TOPLEFT", 9, -(y + 4))
        c.nudge:Show()
        y = y + 30
    end
    c:SetHeight(y + 8)
    -- the asker's closing card
    if IsMe(p.by) then
        local shownWord = ({ live = "results always shown", vote = "results show after voting",
                             close = "results show when it closes" })[p.rv]
        v.card2.fs:SetText((P():IsOpen(p) and "Closes " or "Closed ") .. white(When(p.cl, true)) .. " · " .. shownWord)
        v.card2.close:SetShown(P():IsOpen(p))
        v.card2.extend:SetText(P():IsOpen(p) and "Extend" or "Open again")
        FitButton(v.card2.extend, 64)
        v.card2.extend:ClearAllPoints()
        if P():IsOpen(p) then
            v.card2.extend:SetPoint("LEFT", v.card2.close, "RIGHT", 6, 0)
        else
            v.card2.extend:SetPoint("TOPLEFT", 9, -30)
        end
        v.card2:Show()
    else
        v.card2:Hide()
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
    local open = Pl:IsOpen(p)
    local kick = KIND_WORD[p.k]:upper() .. " · " .. (open and ("CLOSES " .. When(p.cl, true)) or ("CLOSED " .. When(p.cl))):upper()
    v.kick:SetText(kick)
    v.q:SetText(p.q)
    v.q:SetWidth(PAGE_W - 2 * PAD - 30)
    v.meta:SetText((IsMe(p.by) and "Asked by you" or ("Asked by " .. Name(p.by))) .. " · for")
    local x = PAD + TextW(v.meta) + 6
    for i, t in ipairs(p.a or {}) do
        local ch = Pool(v.chips, i, function() return Chip(v, 17) end)
        ch:ClearAllPoints()
        ch:SetPoint("LEFT", v, "TOPLEFT", x, -77)
        local w = ch:Set(P():TargetName(t), TargetGlyph(t))
        x = x + w + 4
        if x > PAGE_W - PAD - 60 then
            for j = i + 1, #(p.a or {}) do if v.chips[j] then v.chips[j]:Hide() end end
            break
        end
    end
    HideFrom(v.chips, #(p.a or {}) + 1)
    v.more:SetShown(Pl:CanManage(p))
    local res = Pl:Results(p)
    local manage = Pl:CanManage(p) and IsMe(p.by)
    if p.k == "days" then
        v.scroll:Hide(); v.card:Hide(); v.card2:Hide()
        v.grid:Show()
        V.FillGrid(v.grid, p, res)
        return
    end
    v.grid:Hide()
    v.scroll:Show(); v.card:Show()
    local mine = Pl:MyVote(p)
    local asked = Pl:AsksMe(p)
    local answering = asked and open and (not mine or state.changing)
    local shown = Pl:ResultsShown(p)
    local y = 0
    for _, b in ipairs(v.ans) do b:Hide() end
    for _, b in ipairs(v.res) do b:Hide() end
    v.vote:Hide(); v.note:Hide(); v.change:Hide(); v.err:Hide()
    if answering then
        local multi = p.k == "many"
        for i = 1, #p.o do
            local b = Pool(v.ans, i, function() return AnswerRow(v.body) end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b:Set(p.o[i], multi, state.pick[i] and true or false)
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
        y = y + 10
        v.vote:SetText(mine and "Save" or "Vote")
        v.vote:ClearAllPoints()
        v.vote:SetPoint("TOPLEFT", 0, -y)
        v.vote:Show()
        local note
        if p.k == "many" and (p.mx or 0) > 0 then note = "Pick up to " .. p.mx .. "." elseif p.k == "many" then
            note = "Pick as many as you like."
        end
        local after = ({ live = nil, vote = "Results show after you vote.", close = "Results show when it closes." })[p.rv]
        local change = p.ch and "You can change it until it closes." or "Your answer can't be changed afterwards."
        local words = {}
        for _, s in ipairs({ note or false, after or false, change }) do
            if s then words[#words + 1] = s end
        end
        v.note:SetText(tconcat(words, " "))
        v.note:ClearAllPoints()
        v.note:SetPoint("LEFT", v.vote, "RIGHT", 10, 0)
        v.note:SetWidth(LEFT_W - v.vote:GetWidth() - 10)
        v.note:Show()
        y = y + 30
        if state.err then
            v.err:SetText(state.err)
            v.err:ClearAllPoints()
            v.err:SetPoint("TOPLEFT", 0, -y)
            v.err:Show()
            y = y + 16
        end
    elseif shown then
        local myPick = {}
        for _, i in ipairs(mine and mine.c or {}) do myPick[i] = true end
        -- most picked first
        local order = {}
        for i = 1, #p.o do order[i] = i end
        tsort(order, function(a, b)
            if res.counts[a] ~= res.counts[b] then return res.counts[a] > res.counts[b] end
            return a < b
        end)
        local denom = max(1, res.answered)
        for n, i in ipairs(order) do
            local f = Pool(v.res, n, function() return ResultBlock(v.body) end)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", 0, -y)
            f.l:SetText(p.o[i])
            f.l:SetWidth(min(TextW(f.l) + 2, LEFT_W - 160))
            f.mine:SetShown(myPick[i] and true or false)
            local pct = floor(res.counts[i] * 100 / denom + 0.5)
            f.c:SetText(res.counts[i] .. " · " .. pct .. "%")
            f.bar:Set(res.counts[i] / denom, LEFT_W)
            local names = {}
            for _, k in ipairs(res.voters[i]) do names[#names + 1] = Name(k) end
            local h = 0
            if #names > 0 then
                h = Wrap(f.names, tconcat(names, Hex(C.dim, ", ")), LEFT_W, 9)
                f.names:Show()
            else
                f.names:Hide()
            end
            f:SetHeight(30 + h)
            f:Show()
            y = y + 30 + h + 12
        end
        if asked and open and p.ch and mine then
            v.change:ClearAllPoints()
            v.change:SetPoint("TOPLEFT", 0, -(y + 2))
            v.change:Show()
            y = y + 30
        end
    else
        -- answered, results wait
        local myPick = {}
        for _, i in ipairs(mine and mine.c or {}) do myPick[i] = true end
        for i = 1, #p.o do
            local b = Pool(v.ans, i, function() return AnswerRow(v.body) end)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 0, -y)
            b:Set(p.o[i], p.k == "many", myPick[i] and true or false)
            b:SetScript("OnClick", nil)
            y = y + ANS_H + ANS_GAP
        end
        v.note:SetText(asked and mine and ("Voted. Results show when it closes " .. white(When(p.cl)) .. ".")
            or ("Results show when it closes " .. white(When(p.cl)) .. "."))
        v.note:ClearAllPoints()
        v.note:SetPoint("TOPLEFT", 0, -(y + 6))
        v.note:SetWidth(LEFT_W)
        v.note:Show()
        y = y + 24
        if asked and open and p.ch and mine then
            v.change:ClearAllPoints()
            v.change:SetPoint("TOPLEFT", 0, -(y + 4))
            v.change:Show()
            y = y + 30
        end
    end
    v.body:SetHeight(max(10, y))
    V.FillCard(v, p, res, manage)
end

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
    r.face = Face(r, 14)
    r.face:SetPoint("LEFT", 4, 0)
    r.fs = Text(r, 10, C.white)
    r.fs:SetPoint("LEFT", r.face, "RIGHT", 6, 0)
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
        local avail = PAGE_H - 104 - PAD - y - footH - 30
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
    local fs = Text(parent, 9, { 0.55, 0.55, 0.55 })
    fs:SetText(text)
    return fs
end

local function Tile(parent, kind, glyph, title, sub)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(114, 46)
    b.bg = Fill(b, C.row)
    Edges(b, { 0.2, 0.2, 0.23, 1 })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(12, 12)
    b.icon:SetPoint("TOPLEFT", 8, -10)
    b.t = Text(b, 11, C.text)
    b.t:SetPoint("LEFT", b.icon, "RIGHT", 5, 0)
    b.t:SetText(title)
    b.s = Text(b, 8, C.dim)
    b.s:SetPoint("TOPLEFT", 8, -28)
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
        Glyph(self.icon, self.glyph, on and C.gold or { 0.86, 0.86, 0.86 })
    end
    b:SetScript("OnClick", function()
        state.draft.k = kind
        S.Refresh(panel.sheet)
    end)
    return b
end

function S.Build(v)
    v.back = CreateFrame("Button", nil, v)
    v.back:SetSize(60, 14)
    v.back:SetPoint("TOPLEFT", PAD, -8)
    v.back.fs = Text(v.back, 9, { 0.55, 0.55, 0.55 })
    v.back.fs:SetPoint("LEFT")
    v.back.fs:SetText("‹ POLLS")
    v.back:SetScript("OnClick", function() PollsUI:ShowList() end)
    v.back:SetScript("OnEnter", function(self) Color(self.fs, C.gold) end)
    v.back:SetScript("OnLeave", function(self) Color(self.fs, { 0.55, 0.55, 0.55 }) end)
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
    v.qLab = Label(L0, "QUESTION")
    v.qLab:SetPoint("TOPLEFT", 0, 0)
    v.q = UI():CreateSleekEditBox(L0, SHEET_L, 24)
    v.q:SetPoint("TOPLEFT", 0, -12)
    v.q:SetMaxLetters(P().MAX_Q)
    v.q:SetTextColor(1, 1, 1)
    v.q:SetScript("OnTextChanged", function(self, user)
        if user then
            state.draft.q = self:GetText()
            S.RefreshPreview(v)
        end
    end)
    UI():SetEditPlaceholder(v.q, "Which night should we move SSC to?")
    v.kLab = Label(L0, "KIND")
    v.kLab:SetPoint("TOPLEFT", 0, -48)
    v.tiles = {}
    local defs = { { "one", PollIcon(), "One answer", "Pick one" }, { "many", PollIcon(), "Several answers", "Pick any" },
                   { "yn", CHECK_GLYPH, "Yes or no", "Quick answer" },
                   { "days", UI().ICON.calendar, "Pick days", "When can you" } }
    for i, d in ipairs(defs) do
        local t = Tile(L0, d[1], d[2], d[3], d[4])
        t:SetPoint("TOPLEFT", (i - 1) * 122, -60)
        v.tiles[i] = t
    end
    v.aLab = Label(L0, "ANSWERS")
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
    v.tLab = Label(L0, "TIME (OPTIONAL)")
    v.daysNote = Text(L0, 9, C.dim)
    v.daysNote:SetText("Voters tick each day: can, if needed or can't.")
    -- closes / results / can change
    v.cLab = Label(L0, "CLOSES")
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
    v.rLab = Label(L0, "RESULTS")
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
    v.wLab = Label(R0, "WHO VOTES")
    v.wLab:SetPoint("TOPLEFT", 0, 0)
    v.chipBox = CreateFrame("Frame", nil, R0)
    v.chipBox:SetPoint("TOPLEFT", 0, -12)
    v.chipBox:SetPoint("TOPRIGHT", 0, -12)
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
    v.preview = CreateFrame("Frame", nil, R0)
    v.preview:SetPoint("LEFT", R0, "LEFT")
    v.preview:SetPoint("RIGHT", R0, "RIGHT")
    v.preview:SetHeight(120)
    Fill(v.preview, CARD)
    Edges(v.preview, CARD_EDGE)
    v.preview.title = Text(v.preview, 12, C.gold)
    v.preview.title:SetPoint("TOPLEFT", 9, -9)
    v.preview.title:SetText("Preview")
    v.preview.r = Text(v.preview, 10, { 0.74, 0.74, 0.74 })
    v.preview.r:SetJustifyH("RIGHT")
    v.preview.r:SetPoint("TOPRIGHT", -9, -10)
    v.preview.r:SetText("as a voter")
    local rule = Line(v.preview, { 0.14, 0.14, 0.15, 1 })
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 1, -28)
    rule:SetPoint("TOPRIGHT", -1, -28)
    v.preview.kick = Text(v.preview, 8, C.gold)
    v.preview.kick:SetPoint("TOPLEFT", 9, -37)
    v.preview.q = Text(v.preview, 11, C.white)
    v.preview.q:SetPoint("TOPLEFT", 9, -50)
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
    c.lab = Label(c, "DAYS")
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
    c.lab:SetText("DAYS · " .. date("%B", time({ year = y, month = m, day = 1, hour = 12 })):upper())
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
    v.preview:ClearAllPoints()
    v.preview:SetPoint("TOPLEFT", v.count, "BOTTOMLEFT", 0, -14)
    v.preview:SetPoint("RIGHT", v.right, "RIGHT")
end

function S.RefreshPreview(v)
    local d = state.draft
    local pv = v.preview
    pv.kick:SetText((KIND_WORD[d.k] .. " · closes " .. When(ClosesAt(d), true)):upper())
    local q = ns.Util.Trim(d.q or "")
    local w = pv:GetWidth()
    if not w or w < 50 then w = PAGE_W - PAD - (PAD + SHEET_L + 18) end
    local qh = Wrap(pv.q, q ~= "" and q or Hex(C.dim, "Your question"), w - 18, 11)
    local y = 50 + qh + 8
    local items = d.k == "days" and d.days or DraftAnswers(d)
    local n, dn = 0, 0
    pv.dayItems = pv.dayItems or {}
    if d.k == "days" then
        local cw = floor((w - 18 - 4 * 3) / 5)
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
            b:SetPoint("TOPLEFT", 9 + ((i - 1) % 5) * (cw + 3), -(y + floor((i - 1) / 5) * 34))
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
            b:SetSize(w - 18, 14)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 9, -y)
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
            b:SetSize(w - 18, 16)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 9, -y)
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
            b:SetSize(w - 18, 16)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 9, -y)
            b.fs:SetText("and " .. (#items - 6) .. " more")
            b.fs:Show()
            b:Show()
            y = y + 18
        end
    end
    HideFrom(pv.items, n + 1)
    HideFrom(pv.dayItems, dn + 1)
    pv:SetHeight(y + 8)
end

function S.Refresh(v)
    local d = state.draft
    if not d then
        d = NewDraft()
        state.draft = d
    end
    if not v.q:HasFocus() then v.q:SetText(d.q or "") end
    for _, t in ipairs(v.tiles) do t:SetOn(t.kind == d.k) end
    local y = 118
    local L0 = v.left
    for _, r in ipairs(v.answers) do r:Hide() end
    v.addAns:Hide(); v.ynNote:Hide(); v.upTo:Hide(); v.upToDD:Hide()
    v.cal:Hide(); v.tLab:Hide(); v.daysNote:Hide()
    for _, r in ipairs(v.dayRows) do r:Hide() end
    v.aLab:ClearAllPoints()
    v.aLab:SetPoint("TOPLEFT", 0, -y)
    v.aLab:SetText(d.k == "days" and "" or "ANSWERS")
    y = y + 12
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
    v.cDate:ClearAllPoints(); v.cDate:SetPoint("TOPLEFT", 0, -(y + 12))
    if v.cDate.Refresh then v.cDate:Refresh() end
    v.cTime:ClearAllPoints(); v.cTime:SetPoint("LEFT", v.cDate, "RIGHT", 6, 0)
    if v.cTime.Refresh then v.cTime:Refresh() end
    local sx = 190
    for _, b in ipairs(v.seg) do
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", sx, -(y + 12))
        b:SetKind(b.key == d.rv and "chosen" or "secondary")
        sx = sx + b:GetWidth() - 1
    end
    y = y + 12 + 22 + 10
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

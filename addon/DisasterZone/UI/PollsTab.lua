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

-- (ns.Style is St here: S is the new poll sheet's table)
local St = ns.Style
local DAY = 86400
local PAD, GAP = St.PAD, St.GAP
local PAGE_W, PAGE_H = St.PAGE_W, St.PAGE_H
local NUM_FONT = St.FONT_NUM
local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local CHECK = "Interface\\Buttons\\UI-CheckBox-Check"
local CHECK_GLYPH = "Interface\\AddOns\\DisasterZone\\Media\\Strategy\\check"
local LEFT_W = 450                   -- the poll page's answers column
local CARD_X = LEFT_W + 30           -- its card
local SHEET_L = 480                  -- the new poll sheet's left column
local ANS_H, ANS_GAP = 32, 6
local NAME_COL = 150                 -- Pick days: the names column
local CELL_GAP = 4
local MAX_LIST_ROWS = 60

-- The colours: ns.Style tokens, plus this page's own shades (read-only: several are shared tables).
local C = {
    gold = St.C.GOLD, white = { 1, 1, 1 }, text = St.C.TEXT, grey = St.C.SUB,
    dim = { 0.55, 0.55, 0.57 }, faint = { 0.33, 0.33, 0.35 }, green = { 0.47, 0.83, 0.54 }, red = { 1, 0.45, 0.4 },
    can = { 0.12, 0.23, 0.14, 1 }, canEdge = { 0.18, 0.42, 0.23, 1 }, maybe = { 0.23, 0.2, 0.09, 1 },
    maybeEdge = { 0.48, 0.39, 0.13, 1 }, no = { 0.09, 0.09, 0.11, 1 }, noEdge = { 0.14, 0.14, 0.16, 1 },
    bar = { 0.82, 0.64, 0.03 }, track = { 0.16, 0.16, 0.18 }, pick = { 0.15, 0.14, 0.08, 1 },
    pickEdge = { 0.54, 0.45, 0.13, 1 }, row = { 0.09, 0.09, 0.11, 1 }, rowEdge = { 0.17, 0.17, 0.2, 1 },
    meta = { 0.82, 0.82, 0.82 }, light = { 0.86, 0.86, 0.86 }, desc = { 0.74, 0.74, 0.74 },
    warm = { 0.95, 0.85, 0.54 }, chip = { 0.91, 0.91, 0.91 }, black = { 0, 0, 0, 1 },
}

local panel
local state = { view = "list", tab = "open", poll = nil, pick = {}, days = nil, changing = false, draft = nil }

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function P() return ns.Polls end
local function Me() return ns.Util.PlayerKey() end
local function IsMe(key) return type(key) == "string" and ns.Util.IsMe(key) or false end

-- A word in white among grey ones (a pick, a count, a time).
local function white(s) return "|cffffffff" .. tostring(s) .. "|r" end
local function Name(key) return EUI():Name(key) end
local function Plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

-- The poll icon (art pack 6), else the notes icon.
local function PollIcon() return ns:HasAssets(6) and UI().ICON.poll or UI().ICON.notes end

---------------------------------------------------------------------------
-- Small pieces (1.4: this was a near-verbatim copy of the Events tab's kit; it is retired onto the shared UI: texts are
-- UI:Text on the type scale (sizes snap, D2), fills UI:Fill, colours ns.Style tokens (St:Color / St:Wrap), times
-- ns.Util.Now; what stays here is page logic and thin aliases of shared parts)
---------------------------------------------------------------------------

local function Edges(f, c, layer)
    UI():AddEdges(f, layer or "BORDER")
    UI():SetEdgeColor(f, St:Color(c))
end

-- A coloured texture the caller anchors (a hairline, a bar); UI:Rule when it runs along a whole edge.
local function Line(parent, c, layer)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(St:Color(c or "HAIRLINE"))
    return t
end

local function TextW(fs) return UI():TextWidth(fs) end

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
    c = c or C.white
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
    if (h or 22) <= 20 then UI():SetTextSize(fs, 10) elseif (h or 22) <= 22 then UI():SetTextSize(fs, 11) end
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

-- A section title over a hairline (UI:CreateSectionHeader, "title"): s:Set(title, right); s.t / s.r / s.line.
local function SectSet(self, t, r)
    self:SetTitle(t or "")
    self:SetRight(r)
    self:Show()
end
local function Sect(parent)
    local s = UI():CreateSectionHeader(parent, "", { style = "title", width = 100 })
    s.t, s.r, s.line = s.title, s.right, s.rule
    s.Set = SectSet
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

local function HideFrom(list, i) UI():HideFrom(list, i) end

-- A rounded chip (the poll page's targets, the sheet's picks).
-- TODO(refactor): move into UI:CreateChip (a count after the name, a remove x, the gold "on" look of a picked one).
local function Chip(parent, h, removable)
    h = h or 17
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(h)
    UI():AddPillShape(c, h)
    c.glyph = c:CreateTexture(nil, "ARTWORK")
    c.glyph:SetSize(h - 7, h - 7)
    c.glyph:SetPoint("LEFT", 7, 0)
    c.fs = UI():Text(c, h >= 20 and 11 or 10, C.text)
    c.fs:SetPoint("LEFT", c.glyph, "RIGHT", 4, 0)
    c.n = UI():Text(c, h >= 20 and 11 or 10, C.dim, { font = NUM_FONT })
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
            Glyph(self.glyph, glyph, on and C.warm or C.desc)
        end
        self.glyph:SetShown(glyph ~= nil or face ~= nil)
        if on then
            self:SetPillColors({ 0.18, 0.15, 0.09, 1 }, { 0.54, 0.45, 0.13, 1 })
            self.fs:SetTextColor(St:Color(C.warm))
        else
            self:SetPillColors({ 0.11, 0.11, 0.13, 1 }, { 0.23, 0.23, 0.26, 1 })
            self.fs:SetTextColor(St:Color(C.text))
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
    b.track = UI():Fill(b, C.track, "BACKGROUND")
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

-- "today 20:00", "tomorrow", "Sun 20:00", "Fri 17 Oct"
local function When(t, withTime)
    local now = ns.Util.Now()
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
-- 1.4: it IS the shared page banner (UI:CreatePageBanner, "hero": the art of the team it asks, the kind's icon tile,
-- the kicker, the question with its pill, who asked whom; Answer / Nudge them as its action, ··· as its tool, the back
-- link on the poll's page). Its extras, laid out after the banner's own layout: who answered (faces, a count, a bar)
-- at the bottom left, the Yes / No answer bar in the actions' place, the closing chip left of them.
-- TODO(refactor): move into UI:CreatePageBanner (a slot at the bottom left; a control in the actions' place; a chip
-- beside the actions: the Events banner has the same extras)
---------------------------------------------------------------------------

local KIND_ICON = { one = "Interface\\Icons\\INV_Scroll_03", many = "Interface\\Icons\\INV_Misc_Note_05",
                    yn = "Interface\\Icons\\INV_Misc_Coin_01", days = "Interface\\Icons\\INV_Misc_PocketWatch_01" }
local THEMES = { "kara", "gruul", "mag", "ssc", "tk", "hyjal", "bt", "za", "swp" }

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

-- The kind's icon in the shared icon tile; f:Set(kind).
local function IconTile(parent, size)
    local f = UI():CreateIconTile(parent, size)
    local set = f.Set
    function f:Set(kind) set(self, KIND_ICON[kind] or KIND_ICON.one) end
    return f
end

-- A class circle with its dark ring (the Duelists list's).
-- TODO(refactor): move into a shared avatar (a player's class circle; the Events pages have the same)
local function RingFace(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.ring = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.ring:SetTexture(DISC)
    f.ring:SetSize(size + 3, size + 3)
    f.ring:SetPoint("CENTER")
    f.ring:SetVertexColor(0, 0, 0, 1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    function f:Set(key)
        self.key = key
        EUI():SetClass(self.tex, key)
        self:Show()
    end
    UI():AttachTooltip(f, function(self, tt)
        if not self.key then return false end
        tt:AddLine(EUI():Name(self.key, true))
    end, nil, { anchor = "ANCHOR_TOP" })
    return f
end

-- The answer bar (the raid page's Accept / Tentative): UI:CreateSegments in the green answer look.
-- s:Set(labels, picked, onPick, minW) (picked: an index or nil); s.buttons[i] (.fs = its label) are the answers.
local function SegSet(self, labels, picked, onPick, minW)
    self.onPick = onPick
    self.opts.minW = minW or 64
    self.opts.pad = 15
    local items = {}
    for i, label in ipairs(labels) do items[i] = { key = i, label = label } end
    local x = self:SetItems(items)
    for _, b in ipairs(self.buttons) do b.fs = b.label end
    self:Select(picked)
    self:Show()
    return x
end
local function SegBar(parent, h)
    local s
    s = UI():CreateSegments(parent, {}, function(i) if s.onPick then s.onPick(i) end end, { h = h or St.BTN_H,
        accent = "OK" })
    s.Set = SegSet
    return s
end

-- (after the banner's own layout: the answer bar in the actions' place, the chip left of it or of the actions)
local function BannerLayout(b)
    b:BaseLayout()
    if not b.seg then return end
    local right = b.actions[#b.actions]
    if b.seg:IsShown() then
        b.seg:ClearAllPoints()
        b.seg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -12, 12)
        b.segLab:ClearAllPoints()
        b.segLab:SetPoint("BOTTOMRIGHT", b.seg, "TOPRIGHT", 0, 5)
        right = b.seg
    end
    if b.chip:IsShown() then
        b.chip:ClearAllPoints()
        if right then
            b.chip:SetPoint("RIGHT", right, "LEFT", -8, 0)
        else
            b.chip:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -12, 15)
        end
    end
end

-- Makes page banner b a poll banner (see above): b.q / b.kick / b.meta (its title, kicker, sub), b.faces / b.count /
-- b.bar (who answered), b.seg / b.segLab (the answer bar), b.chip (when it closes), b.btn (its action), b.more (its
-- ··· tool, on the poll's page).
local function Banner(b)
    b.q, b.kick, b.meta = b.title, b.kicker, b.sub
    b.BaseLayout = b.Layout
    b.Layout = BannerLayout
    b.faces = {}
    b.count = UI():Text(b, "body", C.light)
    b.bar = Bar(b, 4, C.green)
    b.bar:SetWidth(120)
    b.chip = UI():CreateChip(b, { kind = "track" })
    b.chip:Hide()
    b.seg = SegBar(b, St.BTN_H)
    b.seg:Hide()
    b.segLab = UI():Text(b, "caps", C.light)
    b.segLab:SetText("YOUR ANSWER")
    b.segLab:Hide()
    b.toolList = { { icon = "more", title = "More", text = "Close, extend or remove the poll.", onClick = function(self)
        local p = P():GetPoll(b.pid)
        if p then ManageMenu(self, p) end
    end } }
    b:SetTools(b.toolList)
    b.more = b.tools[1]
    b:SetTools(nil)
    b.spare = UI():CreateSleekButton(b, "", 60, St.BTN_H, nil, "primary")
    b.spare:Hide()
    b.btn = b.spare
    return b
end

-- Fills a banner for poll p. mode "list" (the poll waiting for me on the list) | "page" (the poll's own page).
local function FillBanner(b, p, mode)
    local Pl = P()
    b.pid = p.id
    b.building = true
    b:SetArt(ArtKey(p))
    b:SetIcon(KIND_ICON[p.k] or KIND_ICON.one)
    local open = Pl:IsOpen(p)
    b:SetKicker(mode == "list" and ("Waiting for you · " .. KIND_WORD[p.k] .. " · closes " .. When(p.cl, true)) or nil)
    b:SetTitle(p.q)
    local res = Pl:Results(p)
    local meta = { KIND_WORD[p.k] }
    meta[#meta + 1] = (IsMe(p.by) and "asked by you" or ("asked by " .. Name(p.by)))
    meta[#meta + 1] = TargetsWord(p)
    if mode == "page" and p.k == "days" then meta[#meta + 1] = Plural(#p.o, "day") end
    b:SetSub(tconcat(meta, " · "))
    -- a pill after the question: Closed, or my answer
    local mine = Pl:MyVote(p)
    if not open then
        b:SetPill("changed", "Closed")
    elseif mine and p.k ~= "days" and mode == "page" then
        b:SetPill("rank", "Answered")
    else
        b:SetPill(nil, nil)
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
    b.count:SetPoint("BOTTOMLEFT", fx + (#voters > 0 and 12 or 0), 18)
    b.count:SetText(res.answered .. " of " .. res.total .. " answered")
    b.bar:ClearAllPoints()
    b.bar:SetPoint("LEFT", b.count, "RIGHT", 14, 0)
    b.bar:Set(res.total > 0 and res.answered / res.total or 0, 120)
    -- the right side: the answer bar (yes / no), Answer, or Nudge them; when it closes left of them
    b.seg:Hide()
    b.segLab:Hide()
    b:SetTools((mode == "page" and Pl:CanManage(p)) and b.toolList or nil)
    local asked = Pl:AsksMe(p)
    local action
    if p.k == "yn" and asked and open and (not mine or p.ch) then
        local picked = mine and mine.c[1] or nil
        b.seg:Set({ "Yes", "No" }, picked, function(i)
            Pl:Vote(p.id, { i })
        end, 70)
        b.segLab:Show()
    elseif mode == "list" then
        action = { text = "Answer", kind = "primary", onClick = function() PollsUI:OpenPoll(p.id) end }
    elseif mode == "page" and IsMe(p.by) and open and #res.waiting > 0 then
        action = { text = "Nudge them", onClick = function() PollsUI:Nudge(p.id) end }
    end
    b:SetActions(action and { action } or nil)
    b.btn = b.actions[1] or b.spare
    b.chip:Set(open and ("Closes " .. When(p.cl, true)) or ("Closed " .. When(p.cl)))
    b.chip:Show()
    b.building = nil
    b:Layout()
end

---------------------------------------------------------------------------
-- The list
---------------------------------------------------------------------------

local L = {}
local CARD_W = 282

-- A frame whose tooltip is its .tip field at the time ({ title, line ... }; nil: none), above it.
local function FieldTip(self, tt)
    local lines = self.tip
    if not lines then return false end
    for i, line in ipairs(lines) do
        if i == 1 then tt:AddLine(line, St:Color("GOLD")) else tt:AddLine(line, 1, 1, 1, true) end
    end
end

-- A poll in the list: UI:CreateArtRow (the art of the team it asks, the kind's icon, the question over what it is /
-- who asked whom / when it closes), a gold dot on the art while it waits for me, at the right Yes / No, Answer, my
-- poll's answered meter and ···, the leading answer, or when the results show.
function L.NewRow(parent)
    local r = UI():CreateArtRow(parent, { onClick = function(self) if self.pid then PollsUI:OpenPoll(self.pid) end end })
    r.hl, r.line, r.meta = r.dzHover, r.dzRule, r.sub
    UI():AttachTooltip(r, FieldTip, nil, { anchor = "ANCHOR_TOP" })
    r.dot = r.art:CreateTexture(nil, "OVERLAY")
    r.dot:SetTexture(DISC)
    r.dot:SetSize(8, 8)
    r.dot:SetVertexColor(St:Color("GOLD"))
    r.dot:SetPoint("CENTER", r.art, "TOPRIGHT", 0, 0)
    local rt = r.right
    r.b1 = Button(rt, "", 64, St.BTN_H, "primary")
    r.b2 = Button(rt, "", 44, St.BTN_H, "secondary")
    r.more = UI():CreateTipIconButton(rt, St.BTN_H, UI().ICON.more, "More", nil, function() end)
    r.mini = CreateFrame("Frame", nil, rt)
    r.mini:SetSize(110, 20)
    r.mini.l = UI():Text(r.mini, "small", C.meta)
    r.mini.l:SetPoint("TOPLEFT")
    r.mini.r = UI():Text(r.mini, "small", C.meta, { font = NUM_FONT })
    r.mini.r:SetJustifyH("RIGHT")
    r.mini.r:SetPoint("TOPRIGHT")
    r.mini.bar = Bar(r.mini, 4)
    r.mini.bar:SetPoint("BOTTOMLEFT")
    r.mini.bar:SetPoint("BOTTOMRIGHT")
    r.mini.bar:SetWidth(110)
    r.lock = CreateFrame("Frame", nil, rt)
    r.lock:SetSize(120, 16)
    r.lock.icon = r.lock:CreateTexture(nil, "ARTWORK")
    r.lock.icon:SetSize(11, 11)
    r.lock.icon:SetPoint("LEFT")
    Glyph(r.lock.icon, UI().ICON.lock, C.dim)
    r.lock.fs = UI():Text(r.lock, "small", C.dim)
    r.lock.fs:SetPoint("LEFT", r.lock.icon, "RIGHT", 5, 0)
    return r
end

-- Fills a list row for poll p in section `sec` ("wait" | "done" | "mine" | "closed").
function L.Fill(r, p, sec, w)
    local Pl = P()
    r.pid = p.id
    r:SetWidth(w)
    r.dot:SetShown(sec == "wait" or (sec == "mine" and Pl:AsksMe(p) and not Pl:MyVote(p)))
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
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", 0, 0)
            r.b2:ClearAllPoints(); r.b2:SetPoint("RIGHT", r.b1, "LEFT", -6, 0)
            r.b1:SetScript("OnClick", function() Pl:Vote(p.id, { 2 }) end)
            r.b2:SetScript("OnClick", function() Pl:Vote(p.id, { 1 }) end)
            r.b1:Show(); r.b2:Show()
            right = r.b1:GetWidth() + r.b2:GetWidth() + 6
        else
            r.b1:SetText("Answer"); r.b1:SetKind("primary"); FitButton(r.b1, 70)
            r.b1:ClearAllPoints(); r.b1:SetPoint("RIGHT", 0, 0)
            r.b1:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
            r.b1:Show()
            right = r.b1:GetWidth()
        end
    elseif sec == "mine" then
        r.more:ClearAllPoints(); r.more:SetPoint("RIGHT", 0, 0)
        r.more:SetScript("OnClick", function(self) ManageMenu(self, p) end)
        r.more:Show()
        r.mini.l:SetText("Answered")
        UI():SetTextSize(r.mini.l, "small")
        r.mini.r:SetText(res.answered .. "/" .. res.total)
        r.mini.bar.fill:SetColorTexture(C.green[1], C.green[2], C.green[3], 1)
        r.mini.bar:Set(res.total > 0 and res.answered / res.total or 0, 110)
        r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", r.more, "LEFT", -10, 0)
        r.mini:Show()
        right = 110 + 10 + St.BTN_H
    else
        local shown = Pl:ResultsShown(p)
        local lead, share = Leading(p, res)
        if shown and lead then
            r.mini.r:SetText(share .. "%")
            local room = 110 - TextW(r.mini.r) - 6
            for _, size in ipairs({ 10, 9.5 }) do
                UI():SetTextSize(r.mini.l, size)
                r.mini.l:SetText(lead)
                if TextW(r.mini.l) <= room then break end
            end
            if TextW(r.mini.l) > room then r.mini.l:SetText("Leading") end
            r.mini.bar.fill:SetColorTexture(C.bar[1], C.bar[2], C.bar[3], 1)
            r.mini.bar:Set(share / 100, 110)
            r.mini:ClearAllPoints(); r.mini:SetPoint("RIGHT", 0, 0)
            r.mini:Show()
            right = 110
        elseif not shown then
            r.lock.fs:SetText("Results " .. When(p.cl))
            r.lock:SetWidth(16 + TextW(r.lock.fs))
            r.lock:ClearAllPoints(); r.lock:SetPoint("RIGHT", 0, 0)
            r.lock:Show()
            right = r.lock:GetWidth()
        end
    end
    -- the question and the longest of its lines that fits (the whole of both in the tooltip when cut)
    r:SetRightWidth(right + 16)
    r:SetData({ art = ArtKey(p), icon = KIND_ICON[p.k] or KIND_ICON.one, title = p.q, sub = r.metaVariants[1] })
    local room = w - r.textX - right - 16 - 8
    for _, text in ipairs(r.metaVariants) do
        r.meta:SetText(text)
        if TextW(r.meta) <= room then break end
    end
    local cut = r.meta:GetText() ~= r.metaVariants[1] or TextW(r.title) + 1 < UI():TextWidth(p.q, "emph")
    r.tip = cut and { p.q, r.metaVariants[1] } or nil
    r:Show()
end

-- The card at the right: the polls that closed lately, with what won.
function L.BuildCard(v, parent)
    local c = UI():CreateCard(parent, { tone = "card" })
    c:SetWidth(CARD_W)
    c.head = Sect(c)
    c.head:SetPoint("TOPLEFT", St.IN, -4)
    c.head:SetPoint("TOPRIGHT", -St.IN, -4)
    c.head:Set("Closed lately")
    c.head:SetAction({ text = "All", onClick = function() PollsUI:ShowList("closed") end })
    c.title, c.all = c.head.title, c.head.action
    c.items = {}
    c.empty = UI():Text(c, "body", C.dim)
    c.empty:SetPoint("TOPLEFT", St.IN + 4, -40)
    c.empty:SetText("Nothing has closed yet.")
    v.card = c
end

function L.FillCard(v, closed)
    local c = v.card
    local y = 34
    local n = 0
    for _, p in ipairs(closed) do
        if n >= 5 then break end
        n = n + 1
        local it = Pool(c.items, n, function()
            local f = CreateFrame("Button", nil, c)
            UI():DecorateRow(f)
            f.icon = IconTile(f, 22)
            f.icon:SetPoint("TOPLEFT", 6, -6)
            f.q = UI():Text(f, "body", C.white)
            f.q:SetPoint("TOPLEFT", 38, -5)
            f.w = UI():Text(f, "small", C.gold)
            f.w:SetPoint("TOPLEFT", f.q, "BOTTOMLEFT", 0, -4)
            f.pct = UI():Text(f, "small", C.meta, { font = NUM_FONT })
            f.pct:SetJustifyH("RIGHT")
            f.pct:SetPoint("TOPRIGHT", -6, -20)
            f.bar = Bar(f, 3)
            return f
        end)
        local w = CARD_W - 2
        it:SetSize(w, 50)
        it:ClearAllPoints()
        it:SetPoint("TOPLEFT", 1, -y)
        it.icon:Set(p.k)
        UI():FitText(it.q, p.q, w - 38 - 6)
        local res = P():Results(p)
        local lead, share = Leading(p, res)
        it.w:SetText(lead or St:Wrap("DIM", "No answers"))
        it.w:SetWidth(w - 38 - 42)
        it.pct:SetText(lead and (share .. "%") or "")
        it.bar:ClearAllPoints()
        it.bar:SetPoint("BOTTOMLEFT", 38, 7)
        it.bar:SetPoint("BOTTOMRIGHT", -6, 7)
        it.bar:Set(lead and share / 100 or 0, w - 44)
        it:SetScript("OnClick", function() PollsUI:OpenPoll(p.id) end)
        it:Show()
        y = y + 50
    end
    HideFrom(c.items, n + 1)
    c.empty:SetShown(n == 0)
    c.head:SetAction(n > 0 and { text = "All", onClick = function() PollsUI:ShowList("closed") end } or nil)
    c:SetHeight(n == 0 and 70 or (y + 6))
end

-- 1.4: the list is a Board page (UI:CreateLayout "board") under the tab's toolbar (Open / Closed, New poll as the
-- main action): the poll waiting for me as its hero banner, the sections of art rows in its body, the polls that
-- closed lately in a card at the body's right.
function L.Build(v)
    v.layout = UI():CreateLayout("board", v, { toolbar = false, top = UI().LAYOUT.TOP,
        hero = { size = "hero", artUnder = true } })
    local LY = v.layout
    v.hero = Banner(LY.banner)
    v.scroll = UI():CreateScrollFrame(LY.body)
    v.content = CreateFrame("Frame", nil, v.scroll)
    v.content:SetSize(St.INNER_W, 10)
    v.scroll:SetScrollChild(v.content)
    v.heads, v.rows = {}, {}
    v.empty = UI():CreateEmptyState(LY.body, { glyph = PollIcon() })
    v.empty:Hide()
    L.BuildCard(v, LY.body)
end

function L.Refresh(v)
    local Pl = P()
    local polls = Pl:GetPolls()
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
    local LY = v.layout
    local hero = state.tab == "open" and wait[1] or nil
    if hero then
        table.remove(wait, 1)
        FillBanner(v.hero, hero, "list")
        v.hero:Show()
    else
        v.hero:Hide()
    end
    LY:Layout()
    local groups
    if state.tab == "open" then
        groups = { { "Waiting for you", wait, "wait" }, { "Answered", done, "done" }, { "Your polls", mine, "mine" } }
    else
        groups = { { "Closed", closed, "closed" } }
    end
    -- the card at the right (open tab, when something closed)
    local withCard = state.tab == "open" and #closed > 0
    local listW = LY.bodyW - (withCard and (CARD_W + St.GAP * 2) or 0)
    local bodyH = LY.body:GetHeight() or 0
    if bodyH < 50 then
        bodyH = PAGE_H - UI().LAYOUT.TOP - UI().LAYOUT.BOTTOM - (hero and (St.BANNER.hero + St.GAP) or 0)
    end
    v.card:SetShown(withCard)
    if withCard then
        v.card:ClearAllPoints()
        v.card:SetPoint("TOPRIGHT", LY.body, "TOPRIGHT", 0, 0)
        L.FillCard(v, closed)
    end
    v.scroll:ClearAllPoints()
    v.scroll:SetPoint("TOPLEFT", LY.body, "TOPLEFT", 0, 0)
    v.scroll:SetSize(listW, bodyH)
    local total, heads = 0, 0
    for _, g in ipairs(groups) do
        if #g[2] > 0 then
            heads = heads + 1
            total = total + min(#g[2], MAX_LIST_ROWS)
        end
    end
    local need = total * St.ROW.art + heads * 28 + max(0, heads - 1) * St.GAP
    local cw = need > bodyH and (listW - 14) or listW
    v.content:SetWidth(cw)
    local y, hi, ri = 0, 0, 0
    for _, g in ipairs(groups) do
        if #g[2] > 0 then
            hi = hi + 1
            local s = Pool(v.heads, hi, function() return Sect(v.content) end)
            s:SetWidth(cw)
            s:ClearAllPoints()
            if hi > 1 then y = y + St.GAP end
            s:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
            s:Set(g[1])
            s:SetCount(#g[2])
            y = y + 28
            for i = 1, min(#g[2], MAX_LIST_ROWS) do
                ri = ri + 1
                local r = Pool(v.rows, ri, function() return L.NewRow(v.content) end)
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", v.content, "TOPLEFT", 0, -y)
                L.Fill(r, g[2][i], g[3], cw)
                y = y + St.ROW.art
            end
        end
    end
    HideFrom(v.heads, hi + 1)
    HideFrom(v.rows, ri + 1)
    v.empty:Hide()
    if ri == 0 and not hero then
        -- (an illustrated empty state over the list's column: the card may stand at the right)
        local open = state.tab == "open"
        v.empty:SetContent({ glyph = PollIcon(), title = open and "No open polls" or "No closed polls",
            text = open and (Pl:AmIAsker() and "Ask the guild something: it reaches the people you pick."
                or "No polls for you right now. When the officers ask you something, it shows up here.")
                or "No closed polls yet." })
        v.empty:SetBoxWidth(min(430, listW - 40))
        v.empty:ClearAllPoints()
        v.empty:SetPoint("TOP", v.scroll, "TOP", 0, -50)
        v.empty:Show()
        y = 30
    end
    v.content:SetHeight(max(10, y))
end

---------------------------------------------------------------------------
-- A poll's page
---------------------------------------------------------------------------

local V = {}
local COL_R = 282
-- (the page's body: under the tab's toolbar, the hero banner and the gap)
local BODY_H = PAGE_H - 36 - St.BANNER.hero - St.GAP - 4

function PollsUI:Nudge(id)
    local n, why = P():Nudge(id)
    if n and n > 0 then
        ns:Print("reminded %s about the poll.", Plural(n, "player"))
    elseif why == "soon" then
        ns:Print("you nudged them a moment ago: wait a few minutes before the next one.")
    end
end

-- 1.4: a poll's page is a Detail page (UI:CreateLayout "detail") under the tab's toolbar: the poll banner with the way
-- back, then the body: my answer (or the results) on the left, who answered on the right; Pick days: the grid.
function V.Build(v)
    v.layout = UI():CreateLayout("detail", v, { toolbar = false, top = UI().LAYOUT.TOP,
        banner = { size = "hero", artUnder = true }, back = { text = "All polls", onClick = function() PollsUI:ShowList() end } })
    local LY = v.layout
    LY.tabs:Hide()
    LY:Layout()
    v.ban = Banner(LY.banner)
    v.ban.back = LY.banner.back
    local B = LY.body
    v.pbody = B
    local LW = LY.bodyW - COL_R - 24
    v.lsec = Sect(B)
    v.lsec:SetPoint("TOPLEFT", B, "TOPLEFT", 0, 0)
    v.lsec:SetWidth(LW)
    v.scroll = UI():CreateScrollFrame(B)
    v.scroll:SetPoint("TOPLEFT", B, "TOPLEFT", 0, -34)
    v.scroll:SetSize(LW, BODY_H - 34)
    v.body = CreateFrame("Frame", nil, v.scroll)
    v.body:SetSize(LW, 10)
    v.scroll:SetScrollChild(v.body)
    v.ans, v.res = {}, {}
    v.vote = Button(v.body, "Vote", 76, 24, "primary", function() V.SendVote() end)
    v.note = UI():Text(v.body, "small", C.dim)
    v.change = Button(v.body, "Change my answer", 130, 24, "secondary", function()
        state.changing = true
        local p = P():GetPoll(state.poll)
        local mine = p and P():MyVote(p)
        state.pick = {}
        for _, i in ipairs(mine and mine.c or {}) do state.pick[i] = true end
        PollsUI:Refresh()
    end)
    v.err = UI():Text(v.body, "small", C.red)
    -- the people (right column)
    v.rsec = Sect(v)
    v.rsec:SetPoint("TOPRIGHT", B, "TOPRIGHT", 0, 0)
    v.rsec:SetWidth(COL_R)
    v.people = {}
    v.pmore = UI():Text(B, "small", C.dim)
    -- Pick days
    v.grid = CreateFrame("Frame", nil, v)
    v.grid:SetPoint("TOPLEFT", B, "TOPLEFT", 0, 0)
    v.grid:SetPoint("BOTTOMRIGHT", B, "BOTTOMRIGHT", 0, 0)
    V.BuildGrid(v.grid)
end

-- An answer to pick: a card-surface row with the shared row looks (the hover; picked: the gold wash and bar, a deep
-- gold edge), a radio dot (one answer) or a check box (several) and the answer.
local function AnswerRow(parent, w)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, ANS_H)
    b.bg = UI():Fill(b, "CARD")
    UI():AddEdges(b)
    UI():DecorateRow(b, { selectable = true })
    b.bar = b.dzSelBar
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
    b.dot:SetVertexColor(St:Color("GOLD"))
    b.box = b:CreateTexture(nil, "ARTWORK", nil, 1)
    b.box:SetSize(13, 13)
    b.box:SetPoint("LEFT", 12, 0)
    b.check = b:CreateTexture(nil, "ARTWORK", nil, 3)
    b.check:SetTexture(CHECK)
    b.check:SetSize(19, 19)
    b.check:SetPoint("CENTER", b.box, "CENTER", 1, 0)
    b.check:SetVertexColor(St:Color("GOLD"))
    b.fs = UI():Text(b, "emph", C.text)
    b.fs:SetPoint("LEFT", 36, 0)
    function b:Set(text, multi, on, rowW)
        self:SetWidth(rowW or w)
        self.fs:SetText(text)
        self.fs:SetWidth((rowW or w) - 48)
        self.ring:SetShown(not multi)
        self.hole:SetShown(not multi)
        self.dot:SetShown(not multi and on)
        self.box:SetShown(multi)
        self.check:SetShown(multi and on)
        self:SetSelected(on)
        UI():SetEdgeColor(self, St:Color(on and "GOLD_DEEP" or "EDGE"))
        self.fs:SetTextColor(St:Color(on and C.white or C.text))
        self.ring:SetVertexColor(St:Color(on and "GOLD" or "DIM"))
        self.hole:SetVertexColor(St:Color(on and "INSET" or "CARD"))
        self.box:SetColorTexture(St:Color(on and "INSET" or "EDGE_STRONG"))
        self:Show()
    end
    return b
end

local function ResultBlock(parent, w)
    local f = CreateFrame("Frame", nil, parent)
    f:SetWidth(w)
    f.l = UI():Text(f, "title", C.white)
    f.l:SetPoint("TOPLEFT", 0, -3)            -- (room above for the "Your vote" pill: the scroll frame clips)
    f.mine = UI():CreatePill(f, 16)
    f.c = UI():Text(f, "emph", C.white, { font = NUM_FONT })
    f.c:SetJustifyH("RIGHT")
    f.c:SetPoint("TOPRIGHT", 0, -3)
    f.pct = UI():Text(f, "body", { 0.66, 0.66, 0.68 }, { font = NUM_FONT })
    f.pct:SetJustifyH("RIGHT")
    f.bar = CreateFrame("Frame", nil, f)
    f.bar:SetHeight(8)
    f.bar:SetPoint("TOPLEFT", 0, -24)
    f.bar:SetPoint("TOPRIGHT", 0, -24)
    f.bar.track = UI():Fill(f.bar, { 0.14, 0.14, 0.16, 1 })
    f.bar.fill = f.bar:CreateTexture(nil, "ARTWORK")
    f.bar.fill:SetPoint("TOPLEFT")
    f.bar.fill:SetPoint("BOTTOMLEFT")
    UI():Gradient(f.bar.fill, "HORIZONTAL", { 0.72, 0.53, 0.04, 1 }, { 1, 0.82, 0.25, 1 })
    f.names = UI():Text(f, "small", C.dim)
    f.names:SetPoint("TOPLEFT", 0, -39)
    return f
end

local function PersonRow(parent)
    local r = CreateFrame("Frame", nil, parent)
    r:SetHeight(24)
    r.face = RingFace(r, 17)
    r.face:SetPoint("LEFT", 2, 0)
    r.fs = UI():Text(r, "body", C.white)
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
    UI():AttachTooltip(r, function(self, tt)
        if not self.tipText then return false end
        for i, line in ipairs(self.tipText) do
            if i == 1 then tt:AddLine(line, St:Color("GOLD")) else tt:AddLine(line, 1, 1, 1, true) end
        end
    end, nil, { anchor = "ANCHOR_TOP" })
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
    local B = v.pbody
    local x0 = v.layout.bodyW - COL_R
    for i = 1, shown do
        local r = Pool(v.people, i, function() return PersonRow(B) end)
        local k = keys[i]
        local vote = res.votes[k]
        local who = vote and vote.by or k
        r:SetWidth(colW)
        r:ClearAllPoints()
        local col, row = (i - 1) % 2, floor((i - 1) / 2)
        r:SetPoint("TOPLEFT", B, "TOPLEFT", x0 + col * (colW + 14), -(36 + row * 26))
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
        v.pmore:SetPoint("TOPLEFT", B, "TOPLEFT", x0 + 2 + (shown % 2) * (colW + 14),
            -(36 + (rows - (shown % 2 == 1 and 1 or 0)) * 26 + 6))
        v.pmore:SetText("and " .. (#keys - shown) .. " more")
        v.pmore:Show()
    elseif #keys == 0 then
        v.pmore:ClearAllPoints()
        v.pmore:SetPoint("TOPLEFT", B, "TOPLEFT", x0 + 2, -40)
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
                h = Wrap(f.names, tconcat(names, St:Wrap("DIM", ", ")), LW, 10)
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
    c.bg = UI():Fill(c, C.no)
    Edges(c, C.noEdge)
    c.check = c:CreateTexture(nil, "ARTWORK")
    c.check:SetTexture(CHECK)
    c.check:SetSize(16, 16)
    c.check:SetPoint("CENTER", 1, 0)
    c.check:SetVertexColor(0.47, 0.83, 0.54)
    c.fs = UI():Text(c, 9, { 0.91, 0.77, 0.42 })
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
            self.fs:SetTextColor(St:Color({ 0.91, 0.77, 0.42 }))
        elseif mineRow and s == 0 then
            self.fs:SetText("can't")
            self.fs:SetTextColor(St:Color({ 0.33, 0.33, 0.35 }))
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
    r.fs = UI():Text(r, "body", C.white)
    r.fs:SetPoint("LEFT", r.face, "RIGHT", 8, 0)
    r.cells = {}
    return r
end

function V.BuildGrid(g)
    g.head = CreateFrame("Frame", nil, g)
    g.head:SetPoint("TOPLEFT", 0, -12)
    g.head:SetPoint("TOPRIGHT", 0, -12)
    g.head:SetHeight(39)
    g.hint = UI():Text(g.head, "small", C.dim)
    g.hint:SetPoint("LEFT", 4, 0)
    g.days = {}
    g.you = GridRow(g)
    g.you.bg = UI():Fill(g.you, { 0.106, 0.102, 0.078, 1 })
    Edges(g.you, { 0.23, 0.21, 0.13, 1 })
    g.you:SetHeight(28)
    g.you.sub = UI():Text(g.you, 8, C.dim)
    g.you.sub:SetPoint("LEFT", g.you.fs, "RIGHT", 6, 0)
    g.tot = CreateFrame("Frame", nil, g)
    g.tot:SetHeight(26)
    g.tot.fs = UI():Text(g.tot, "small", C.gold)
    g.tot.fs:SetPoint("LEFT", 4, 0)
    g.tot.fs:SetText("Can make it")
    g.tot.rule = Line(g.tot, "HAIRLINE")
    g.tot.rule:SetHeight(1)
    g.tot.rule:SetPoint("BOTTOMLEFT")
    g.tot.rule:SetPoint("BOTTOMRIGHT")
    g.tot.n = {}
    g.scroll = UI():CreateScrollFrame(g)
    g.list = CreateFrame("Frame", nil, g.scroll)
    g.list:SetSize(PAGE_W - 2 * PAD, 10)
    g.scroll:SetScrollChild(g.list)
    g.rows = {}
    g.foot = UI():Text(g, "small", C.dim)
    g.best = CreateFrame("Frame", nil, g)
    g.best:SetFrameLevel(g:GetFrameLevel() + 20)
    g.best.edges = {}
    UI():AddEdges(g.best, "OVERLAY")
    UI():SetEdgeColor(g.best, 0.82, 0.64, 0.03, 1)
    g.best.tag = CreateFrame("Frame", nil, g.best)
    g.best.tag:SetSize(36, 11)
    g.best.tag:SetPoint("BOTTOM", g.best, "TOP", 0, -1)
    UI():Fill(g.best.tag, { 0.82, 0.64, 0.03, 1 }, "ARTWORK")
    g.best.tag.fs = UI():Text(g.best.tag, 8, { 0.1, 0.08, 0 })
    g.best.tag.fs:SetShadowOffset(0, 0)
    g.best.tag.fs:SetJustifyH("CENTER")
    g.best.tag.fs:SetPoint("CENTER", 0, 0)
    g.best.tag.fs:SetText("BEST")
    g.save = Button(g, "Save", 64, 22, "primary", function() V.SaveDays() end)
    g.save:SetPoint("BOTTOMRIGHT", 0, 0)
    g.saveNote = UI():Text(g, "small", C.dim)
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
            f.wd = UI():Text(f, 9, C.gold)
            f.wd:SetJustifyH("CENTER")
            f.wd:SetPoint("TOP", 0, -1)
            f.dn = UI():Text(f, 15, C.white, { font = NUM_FONT })
            f.dn:SetJustifyH("CENTER")
            f.dn:SetPoint("TOP", f.wd, "BOTTOM", 0, -1)
            f.tm = UI():Text(f, 9, C.grey, { font = NUM_FONT })
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
                t.n = UI():Text(t, "emph", C.white, { font = NUM_FONT })
                t.m = UI():Text(t, 9, C.dim)
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
        local avail = BODY_H - y - footH - 30
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
    local t = date("*t", ns.Util.Now() + 3 * DAY)
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
    elseif ClosesAt(d) <= ns.Util.Now() + 60 then why = "Pick a closing time in the future."
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
    local fs = UI():Text(parent, "body", C.grey)
    fs:SetText(text)
    return fs
end

-- A kind to pick: a card-surface tile with the shared row looks (picked: the gold wash and bar, a deep gold edge).
local function Tile(parent, kind, glyph, title, sub)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(114, 46)
    b.bg = UI():Fill(b, "CARD")
    UI():AddEdges(b)
    UI():DecorateRow(b, { selectable = true })
    b.icon = IconTile(b, 24)
    b.icon:SetPoint("LEFT", 10, 0)
    b.icon:Set(kind)
    b.t = UI():Text(b, "body", C.text)
    b.t:SetPoint("TOPLEFT", 42, -10)
    b.t:SetText(title)
    b.s = UI():Text(b, 9, C.dim)
    b.s:SetPoint("TOPLEFT", 42, -26)
    b.s:SetText(sub)
    b.kind, b.glyph = kind, glyph
    function b:SetOn(on)
        self:SetSelected(on)
        UI():SetEdgeColor(self, St:Color(on and "GOLD_DEEP" or "EDGE"))
        self.t:SetTextColor(St:Color(on and C.white or C.text))
        self.icon.tex:SetDesaturated(not on)
        self.icon.tex:SetAlpha(on and 1 or 0.75)
    end
    b:SetScript("OnClick", function()
        state.draft.k = kind
        S.Refresh(panel.sheet)
    end)
    return b
end

-- 1.4: the new poll is a Detail page (UI:CreateLayout "detail") under the tab's toolbar: a strip banner (the way back,
-- "New poll", what is missing in its sub line; Post poll as the main action, Cancel beside it), then the form: the
-- question, kind, answers and when it closes on the left; who votes, the count and a preview on the right.
function S.Build(v)
    v.layout = UI():CreateLayout("detail", v, { toolbar = false, top = UI().LAYOUT.TOP,
        banner = { size = "strip", title = "New poll", subColor = "BAD" },
        back = { text = "All polls", onClick = function() PollsUI:ShowList() end } })
    local LY = v.layout
    LY.tabs:Hide()
    LY:Layout()
    local ban = LY.banner
    v.ban, v.back, v.title, v.err = ban, ban.back, ban.title, ban.sub
    ban:SetActions({ { text = "Post poll", kind = "primary", onClick = function() S.Post() end },
        { text = "Cancel", onClick = function()
            state.draft, state.sheetErr = nil, nil
            PollsUI:ShowList()
        end } })
    v.post, v.cancel = ban.actions[1], ban.actions[2]
    local B = LY.body
    local bodyH = PAGE_H - 36 - St.BANNER.strip - St.GAP - 4
    -- the left column scrolls (a long answer list, many days)
    v.scroll = UI():CreateScrollFrame(B)
    v.scroll:SetPoint("TOPLEFT", B, "TOPLEFT", 0, 0)
    v.scroll:SetSize(SHEET_L, bodyH)
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
    UI():SetEdgeColor(v.addAns, St:Color("EDGE"))
    UI():DecorateRow(v.addAns)
    v.addAns.fs = UI():Text(v.addAns, "small", C.dim)
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
    v.ynNote = UI():Text(L0, "small", C.dim)
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
    v.daysNote = UI():Text(L0, 9, C.dim)
    v.daysNote:SetText("Voters tick each day: can, if needed or can't.")
    -- closes / results / can change
    v.cLab = Label(L0, "Closes")
    v.cDate = UI():CreateDatePicker(L0, {
        width = 104,
        get = function()
            if state.draft then return unpack(state.draft.cday) end
            local t = date("*t", ns.Util.Now() + 3 * DAY)
            return t.year, t.month, t.day
        end,
        set = function(y, m, d) if state.draft then state.draft.cday = { y, m, d } end end,
        minDate = function() local t = date("*t", ns.Util.Now()) return t.year, t.month, t.day end,
        maxDate = function() local t = date("*t", ns.Util.Now() + 59 * DAY) return t.year, t.month, t.day end,
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
    v.rvSeg = UI():CreateSegments(L0, { { "live", "Live" }, { "vote", "After voting" }, { "close", "When closed" } },
        function(key)
            state.draft.rv = key
            S.Refresh(v)
        end, { h = 22 })
    v.change = UI():CreateCheckbox(L0, "Can change their answer", function() return state.draft and state.draft.ch or false end, function(on)
        if state.draft then state.draft.ch = on and true or false end
    end)
    -- the right column: who votes, the count, a preview
    local R0 = CreateFrame("Frame", nil, B)
    R0:SetPoint("TOPLEFT", B, "TOPLEFT", SHEET_L + 18, 0)
    R0:SetPoint("BOTTOMRIGHT", B, "BOTTOMRIGHT", 0, 0)
    v.right = R0
    v.wLab = Label(R0, "Who votes")
    v.wLab:SetPoint("TOPLEFT", 0, 0)
    v.chipBox = UI():CreateCard(R0, { tone = "card" })
    v.chipBox:SetPoint("TOPLEFT", 0, -16)
    v.chipBox:SetPoint("TOPRIGHT", 0, -16)
    v.chipBox:SetHeight(26)
    v.chips = {}
    v.chipHint = UI():Text(v.chipBox, "small", C.dim)
    v.chipHint:SetPoint("LEFT", 8, 0)
    v.chipHint:SetText("Nobody yet: add them below")
    local rw = St.INNER_W - SHEET_L - 18
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
    v.count.fs = UI():Text(v.count, "small", C.grey)
    UI():AttachTooltip(v.count, function(_, tt)
        local keys = S.Asked()
        if #keys == 0 then return false end
        local names = {}
        for i = 1, min(#keys, 30) do names[#names + 1] = Name(keys[i]) end
        if #keys > 30 then names[#names + 1] = St:Wrap("DIM", "and " .. (#keys - 30) .. " more") end
        tt:AddLine(Plural(#keys, "person", "people") .. " will be asked")
        tt:AddLine(tconcat(names, ", "), 1, 1, 1, true)
    end, nil, { anchor = "ANCHOR_TOP" })
    v.pvSect = Sect(R0)
    v.pvBan = UI():CreatePageBanner(R0, { size = 66, width = rw, artUnder = true })
    v.preview = CreateFrame("Frame", nil, R0)
    v.preview:SetHeight(10)
    v.preview.items = {}
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
        local fs = UI():Text(c, 9, { 0.55, 0.55, 0.55 })
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
        b.disc:SetVertexColor(St:Color("GOLD"))
        b.fs = UI():Text(b, "body", C.text, { font = NUM_FONT })
        b.fs:SetJustifyH("CENTER")
        b.fs:SetPoint("CENTER", 0, 0)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetTexture(DISC)
        b.hl:SetSize(23, 23)
        b.hl:SetPoint("CENTER")
        b.hl:SetVertexColor(St:Color("HOVER"))
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
        local t = date("*t", ns.Util.Now())
        d.month = { t.year, t.month }
    end
    local y, m = d.month[1], d.month[2]
    c.lab:SetText("Days · " .. date("%B", time({ year = y, month = m, day = 1, hour = 12 })))
    local first = time({ year = y, month = m, day = 1, hour = 12 })
    local wd = (tonumber(date("%w", first)) + 6) % 7          -- Monday first
    local dim = tonumber(date("%d", time({ year = y, month = m + 1, day = 0, hour = 12 })))
    local t0 = date("*t", ns.Util.Now())
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
                b.fs:SetTextColor(St:Color({ 0.1, 0.08, 0 }))
                b.fs:SetShadowColor(0, 0, 0, 0)
            else
                b.fs:SetTextColor(St:Color(past and { 0.33, 0.33, 0.35 } or C.text))
                b.fs:SetShadowColor(0, 0, 0, 1)
            end
            b:EnableMouse(not past)
            b:Show()
        else
            b:Hide()
        end
    end
    local now = date("*t", ns.Util.Now())
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
            e.iconColor = o.kind == "g" and C.gold or C.desc
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
    if not boxW or boxW < 50 then boxW = St.INNER_W - SHEET_L - 18 end
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
        UI():AttachTooltip(ch, P():TargetName(t), "Click to take it off.", { anchor = "ANCHOR_TOP" })
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

-- The preview banner: the list's banner as the people asked will see it, smaller (UI:CreatePageBanner, 66 high: the
-- art, the kind's icon, the kicker, the question, how many are asked).
function S.FillPreviewBanner(b, d)
    local fake = { id = "preview", k = d.k, a = d.a, cl = ClosesAt(d) }
    b.building = true
    b:SetArt(ArtKey(fake))
    b:SetIcon(KIND_ICON[d.k] or KIND_ICON.one)
    b:SetKicker(KIND_WORD[d.k] .. " · closes " .. When(ClosesAt(d), true))
    local q = ns.Util.Trim(d.q or "")
    b:SetTitle(q ~= "" and q or St:Wrap("DIM", "Your question"))
    local keys = S.Asked()
    b:SetSub(#keys > 0 and (Plural(#keys, "person", "people") .. " asked") or "Nobody asked yet")
    b.building = nil
    b:Layout()
end

function S.RefreshPreview(v)
    local d = state.draft
    local pv = v.preview
    local w = St.INNER_W - SHEET_L - 18
    S.FillPreviewBanner(v.pvBan, d)
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
                f.bg = UI():Fill(f, C.no)
                Edges(f, C.noEdge)
                f.a = UI():Text(f, 8, C.gold)
                f.a:SetJustifyH("CENTER")
                f.a:SetPoint("TOP", 0, -5)
                f.b = UI():Text(f, "body", C.white, { font = NUM_FONT })
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
            if not b.fs then b.fs = UI():Text(b, "small", C.dim) b.fs:SetPoint("LEFT") end
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
                b.fs = UI():Text(b, "small", C.text)
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
            if not b.fs then b.fs = UI():Text(b, "small", C.dim) b.fs:SetPoint("LEFT", 16, 0) end
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
                f.fs = UI():Text(f, "body", C.white)
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
                f.rule = Line(f, "HAIRLINE")
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
    v.rvSeg:ClearAllPoints()
    v.rvSeg:SetPoint("TOPLEFT", 190, -(y + 16))
    v.rvSeg:Select(d.rv)
    y = y + 16 + 22 + 10
    v.change:ClearAllPoints()
    v.change:SetPoint("TOPLEFT", -4, -y)
    v.change:SetChecked(d.ch and true or false)
    y = y + 26
    v.left:SetHeight(y)
    S.RefreshAudience(v)
    S.RefreshPreview(v)
    -- (what is missing: the banner's sub line, in red)
    v.ban:SetSub(state.sheetErr)
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

-- 1.4: the tab is a Board page (UI:CreateLayout): its toolbar holds Open / Closed and the main action New poll; each
-- view under it is a layout of its own (the list: a board; a poll: a detail page; the new poll: a detail page).
function PollsUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZonePollsPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    p.layout = UI():CreateLayout("board", p)
    local bar = p.layout.toolbar
    p.toolbar = bar
    bar:SetTabs({ { key = "open", text = "Open" }, { key = "closed", text = "Closed" } },
        function(key) PollsUI:ShowList(key) end)
    p.new = bar:SetPrimary({ text = "New poll", width = 104, onClick = function() PollsUI:OpenNew() end })
    -- (its plus as a glyph beside the words: the button's text stays "New poll", which the welcome tour points at)
    -- TODO(refactor): move into the layout toolbar (SetPrimary's icon puts the glyph into the button's text)
    p.new.glyph = p.new:CreateTexture(nil, "OVERLAY")
    p.new.glyph:SetSize(11, 11)
    Glyph(p.new.glyph, UI().ICON.plus, { 0.92, 0.92, 0.92, 0.9 })
    local fs = p.new:GetFontString()
    fs:ClearAllPoints()
    fs:SetPoint("CENTER", 7, 0)
    p.new.glyph:SetPoint("RIGHT", fs, "LEFT", -5, 0)
    p.list = CreateFrame("Frame", nil, p)
    p.list:SetAllPoints()
    L.Build(p.list)
    -- (the list's old handles: the toolbar, its tabs and New poll)
    p.list.toolbar, p.list.new = bar, p.new
    p.list.tabOpen, p.list.tabClosed = bar:GetTab("open"), bar:GetTab("closed")
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
    -- (the toolbar on every view: the tab it was opened from stays lit; New poll on the list)
    panel.toolbar:SetTabCount("open", P():WaitingCount())
    panel.toolbar:SelectTab(state.tab)
    panel.new:SetShown(state.view == "list" and P():AmIAsker())
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

-- 1.4: the pop-up is the shared toast (UI:Toast, key "poll"): a kicker (a new poll or a reminder, from whom), the
-- question, what it is; Yes / No answered right there, else Answer opens the poll; Later puts it away. One at a time
-- (the rest wait in the queue), never in combat. Answered, it says so with the running totals, then goes.
local TOAST_KEY = "poll"
local queue = {}
local asking            -- (the poll the toast asks about, while it still asks)

local function ShowNext()
    if UI():GetToast(TOAST_KEY) then return end
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

-- (the toast went: the next one in the queue, a moment later)
local function ToastGone()
    asking = nil
    C_Timer.After(0.4, ShowNext)
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
    P():MarkShown(p.id)
    local meta = { KIND_WORD[p.k] }
    if p.k == "days" then meta[#meta + 1] = Plural(#p.o, "day") end
    meta[#meta + 1] = TargetsWord(p)
    meta[#meta + 1] = ClosesWord(p)
    local buttons
    if p.k == "yn" then
        buttons = { { text = "Yes", kind = "primary", width = 60, onClick = function() PollsUI:ToastVote(p.id, 1) return true end },
            { text = "No", kind = "secondary", width = 60, onClick = function() PollsUI:ToastVote(p.id, 2) return true end },
            { text = "Later", kind = "link" } }
    else
        buttons = { { text = "Answer", kind = "primary", onClick = function() PollsUI:OpenPoll(p.id) end },
            { text = "Later", kind = "link" } }
    end
    asking = p.id
    UI():Toast({ key = TOAST_KEY, kind = "info", icon = KIND_ICON[p.k] or KIND_ICON.one,
        kicker = (nudge and "Reminder · from " or "New poll · from ")
            .. (ns.Util.ShortName(p.by) or p.by),
        title = p.q, text = tconcat(meta, " · "), buttons = buttons, buttonRow = true, duration = 0, combat = false,
        sound = SOUNDKIT and SOUNDKIT.IG_CHAT_EMOTE_BUTTON, onClose = function() ToastGone() end })
end

-- Answered from the pop-up: it says so with the running totals, then goes.
function PollsUI:ToastVote(id, i)
    local ok = P():Vote(id, { i })
    local p = P():GetPoll(id)
    if not ok or not p or not UI():GetToast(TOAST_KEY) then
        PollsUI:HideToast()
        return
    end
    asking = nil
    local res = P():Results(p)
    local text
    if P():ResultsShown(p) then
        text = white(res.counts[1]) .. " yes · " .. white(res.counts[2]) .. " no so far · " .. St:Wrap("GOLD", "Open")
    else
        text = "Thanks. Results show " .. (p.rv == "close" and ("when it closes " .. When(p.cl)) or "on the poll") .. "."
    end
    UI():Toast({ key = TOAST_KEY, kind = "ok", icon = CHECK, kicker = "Answered · " .. (p.o[i] or ""), title = p.q,
        text = text, duration = 5, progress = res.total > 0 and res.answered / res.total or 0,
        onClick = function() PollsUI:OpenPoll(id) end, onClose = function() ToastGone() end })
end

function PollsUI:HideToast()
    if UI():GetToast(TOAST_KEY) then UI():HideToast(TOAST_KEY) else ToastGone() end
end

function PollsUI:GetToast() return UI():GetToast(TOAST_KEY) end

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
        -- (the shared count badge: UI:CreateCountBadge)
        if not btn.dzCount then
            local c = UI():CreateCountBadge(btn, 14)
            c:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1)
            c:SetFrameLevel(btn:GetFrameLevel() + 5)
            btn.dzCount = c
        end
        btn.dzCount:SetLabel(n > 9 and "9+" or tostring(n))
        btn.dzCount:SetShown(n > 0)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function PollsUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("polls", "Polls", 3.575, function(parent) return PollsUI:CreatePanel(parent) end,
            function() return IsInGuild() or ns.Util.DemoOn() end, { layout = "board" })
    end
    ns:On("POLLS_UPDATED", function()
        if panel and panel:IsVisible() then PollsUI:Refresh() end
        RefreshBadges()
        if asking and UI():GetToast(TOAST_KEY) then
            local p = P():GetPoll(asking)
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

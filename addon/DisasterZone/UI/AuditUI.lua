if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AuditUI.lua", ...) then return end -- DisasterZone: UI/AuditUI.lua
-- Guild > Audit log (the Guild Master and the guild council; Core/Audit.lua): every change in the addon.
--   Banner: the title and what's new since my last look (or the person picked), the last 30 days as bars (click a day,
--           drag across several; the readout says what the bars hold), ··· (mark everything seen).
--   Left:   views (Since you looked, Everything, Big changes), areas and people; they combine.
--   Middle: the search, Added / Changed / Removed, and the changes newest first, under a header per day. One person's
--           changes to one thing within 10 minutes fold into one row, sign-ups per raid, loot handed out per person.
--           A gold dot = new since I looked; the gold rule = where I stopped last time.
--   Right:  the change: the thing (its art), who and when, a big change's reason, every field before and after, Put
--           back (removed things), Open, Whole story (UI/AuditStory.lua), and the thing's latest changes.
local addonName, ns = ...

local AU = ns:NewModule("AuditUI")
local UI, S = ns.UI, ns.Style

local floor, max, min = math.floor, math.max, math.min
local tconcat, tsort = table.concat, table.sort

local DAY = 86400
local DAYS = 30
local PAD, GAP = S.PAD, S.GAP
local BAN_H = 92
local RAIL_W, LIST_W = 140, 366
local DET_W = S.INNER_W - RAIL_W - LIST_W - 2 * GAP
local BODY_Y = PAD + BAN_H + GAP
local BODY_H = S.PAGE_H - BODY_Y - PAD
local ART_W, ART_H = 64, 38
local TEXT_X = 8 + ART_W + 12
local ROW_TEXT_W = LIST_W - 20 - TEXT_X - 44
local FOLD = { su = 2 * 3600, aw = 30 * 60, x = 10 * 60 }
local OLD, NEW = "|cffd08a80", "|cffa6e3ad"

local H = {}
AU._H = H
local state = { view = "all", kind = "all", q = "" }
local view

local function A() return ns.Audit end
local function Short(key) return ns.Util.ShortName(key) or tostring(key) end
local function Name(key) return UI:ColoredName(key, UI:ClassOf(key)) end

H.VERB = { add = { "OK", "plus" }, chg = { "GOLD", 16 }, rem = { "BAD", "trash" }, back = { "YOU", 9 } }
H.PHRASE = { add = "added {o}", chg = "changed {o}", rem = "removed {o}", back = "put back {o}" }
H.BIG = { rem = "Removed", void = "Award taken back", black = "Blacklist", rights = "Rights", rules = "Loot rules",
          update = "Addon update", lock = "Changed while the BiS lists were locked" }
H.AREAS = { { "raids", "Raids", "calendar" }, { "loot", "Loot", "games" }, { "strat", "Strategies", "reserve" },
            { "members", "Members", "person" }, { "guests", "Guests", "team" }, { "events", "Events", "trophy", "Events and polls" },
            { "recruit", "Recruitment", "whisper" }, { "roles", "Roles", "crown" }, { "addon", "Addon", "gear" } }
H.KIND = { ["rp.E"] = "RAID", ["rp.S"] = "WEEKLY RAID", ["rp.U"] = "SIGN-UPS", ["rp.T"] = "TEAM", ["rp.W"] = "WAITLIST",
           ["rp.BL"] = "BLACKLIST", ["gb.N"] = "GUEST BOOK", ["sb.B"] = "STRATEGY", ["sb.F"] = "RAID STRATEGIES",
           ["pl.P"] = "POLL", ["ev.D"] = "EVENT", ["ev.O"] = "EVENT", ["ev.K"] = "EVENT REVIEW", ["ev.R"] = "EVENT RESULTS",
           ["ev.C"] = "EVENTS SEASON", ["lg.A"] = "LOOT", ["pz.I"] = "PRIZED ITEM", ["bis.L"] = "BIS LIST",
           ["gd.CG"] = "GUILD COUNCIL", ["gd.RL"] = "GUILD RULES", ["gd.AC"] = "CHARACTERS", ["on.N"] = "OFFICER NOTE",
           ["rc.P"] = "RECRUIT", ["rl.R"] = "RAID LOG", ["rl.E"] = "RAID LOG", ["rl.D"] = "RAID LOG",
           ["at.D"] = "ATTENDANCE", ["pt.U"] = "ADDON UPDATE" }

---------------------------------------------------------------------------
-- Words
---------------------------------------------------------------------------

function H.ItemText(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local name = UI:ItemName(id) or (ns.ItemDB and ns.ItemDB.GetName and ns.ItemDB:GetName(id))
    return "|cffa335ee" .. (name or ("item " .. id)) .. "|r"
end

-- A value that is a whole player ("@key") or item ("#id") token, else the text as it is.
function H.Value(v)
    if type(v) ~= "string" then return v == nil and "None" or tostring(v) end
    local key = v:match("^@(.+)$")
    if key then return Name(key) end
    local id = v:match("^#(%d+)$")
    if id then return H.ItemText(id) or v end
    return v
end

-- The tokens inside a phrase the describers wrote ("gave {o} to @key").
function H.Tokens(s)
    s = s:gsub("@([^%s,;:%)]+)", function(k) return Name(k) end)
    return s
end

function H.Obj(e)
    local n = e.n or "?"
    local id = n:match("^#(%d+)$")
    if id then return H.ItemText(id) or n end
    return "|cffffffff" .. n .. "|r"
end

function H.Who(e)
    if e.w then return Name(e.w) end
    return "|cff9e9e9eSomeone|r"
end

function H.Phrase(e)
    local c = e.c or H.PHRASE[e.v] or "changed {o}"
    local obj = H.Obj(e)
    return H.Tokens((c:gsub("{o}", function() return obj end)))
end

function H.Line1(e) return H.Who(e) .. " " .. H.Phrase(e) end

-- The words without the thing, where the thing is already named (its story): "changed it", "signed up".
function H.StoryPhrase(e)
    local c = e.c or H.PHRASE[e.v] or "changed {o}"
    c = c:gsub(" for {o}$", ""):gsub(" of {o}$", ""):gsub(" on {o}$", ""):gsub(" in {o}$", "")
    return H.Tokens((c:gsub("{o}", "it")))
end

local function Join(list, n, fmt)
    local out = {}
    for i = 1, min(#list, n) do out[i] = fmt and fmt(list[i]) or tostring(list[i]) end
    local s = tconcat(out, ", ")
    if #list > n then s = s .. " and " .. (#list - n) .. " more" end
    return s
end

-- One field in a few words (the row's second line).
function H.FieldShort(f)
    if f.aw then
        local w = f.aw[1]
        local item = (w[1] and w[1] ~= 0) and H.ItemText(w[1]) or ("|cffa335ee" .. tostring(w[4] or "an item") .. "|r")
        return item .. " → " .. Name(w[2]) .. (#f.aw > 1 and (", and " .. (#f.aw - 1) .. " more") or "")
    end
    if f.mv then
        local m = f.mv[1]
        local s = Name(m[1]) .. " to " .. tostring(m[3])
        if #f.mv > 1 then s = s .. ", " .. (#f.mv - 1) .. " more" end
        return s
    end
    if f.ad or f.rm then
        local parts = {}
        if f.ad then parts[#parts + 1] = NEW .. "+|r " .. Join(f.ad, 2, H.Value) end
        if f.rm then parts[#parts + 1] = OLD .. "−|r " .. Join(f.rm, 2, H.Value) end
        return tostring(f.l) .. " " .. tconcat(parts, " ")
    end
    if f.ta then return tostring(f.l) .. " changed" end
    if f.was then return tostring(f.l) .. ": " .. OLD .. tostring(f.was) .. "|r" end
    if f.v ~= nil then return tostring(f.l) .. ": " .. H.Value(f.v) end
    if f.a ~= nil then return tostring(f.l) .. " " .. OLD .. H.Value(f.a) .. "|r → " .. NEW .. H.Value(f.b) .. "|r" end
    return tostring(f.l or "")
end

function H.Summary(e)
    if e.s then return e.s end
    local parts = {}
    for i, f in ipairs(e.f or {}) do
        if i > 2 then break end
        parts[#parts + 1] = H.FieldShort(f)
    end
    return tconcat(parts, " · ")
end

function H.Clock(t) return date("%H:%M", t) end

function H.When(t)
    local d = H.DayIndex(t)
    if d == 0 then return "Today, " .. H.Clock(t) end
    if d == 1 then return "Yesterday, " .. H.Clock(t) end
    return date("%a ", t) .. tonumber(date("%d", t)) .. date(" %b, %H:%M", t)
end

-- As H.When, for inside a sentence ("today, 16:14").
function H.WhenIn(t)
    local d = H.DayIndex(t)
    if d == 0 then return "today, " .. H.Clock(t) end
    if d == 1 then return "yesterday, " .. H.Clock(t) end
    return H.When(t)
end

-- Days ago (0 = today), by my calendar.
function H.Midnight()
    local d = date("*t", ns.Util.Now())
    d.hour, d.min, d.sec = 0, 0, 0
    return time(d)
end

function H.DayIndex(t)
    local m = H.Midnight()
    if t >= m then return 0 end
    return floor((m - t - 1) / DAY) + 1
end

---------------------------------------------------------------------------
-- What shows
---------------------------------------------------------------------------

local HAY = setmetatable({}, { __mode = "k" })   -- entry -> its search text (weak: entries come and go)

function H.Hay(e)
    if HAY[e] then return HAY[e] end
    local parts = { e.n or "", e.c or "", e.s or "", e.w and Short(e.w) or "" }
    local function walk(v)
        if type(v) == "table" then for _, x in pairs(v) do walk(x) end
        elseif type(v) == "string" then
            local key = v:match("^@(.+)$")
            local id = v:match("^#(%d+)$")
            if key then parts[#parts + 1] = Short(key)
            elseif id then parts[#parts + 1] = UI:ItemName(tonumber(id)) or ""
            else parts[#parts + 1] = v end
        elseif type(v) == "number" and v > 1000 then
            parts[#parts + 1] = UI:ItemName(v) or ""
        end
    end
    walk(e.f)
    local id = (e.n or ""):match("^#(%d+)$")
    if id then parts[#parts + 1] = UI:ItemName(tonumber(id)) or "" end
    for k in (e.c or ""):gmatch("@([^%s,;:%)]+)") do parts[#parts + 1] = Short(k) end
    local s = tconcat(parts, " "):lower()
    HAY[e] = s
    return s
end

function H.Match(e, skip)
    skip = skip or {}
    local Au = A()
    if not skip.view then
        if state.view == "new" and not Au:IsNew(e) then return false end
        if state.view == "big" and not e.b then return false end
    end
    if not skip.area and state.area and e.a ~= state.area then return false end
    if not skip.person and state.person and e.w ~= state.person then return false end
    if not skip.kind and state.kind ~= "all" and (e.v == "back" and "chg" or e.v) ~= state.kind then return false end
    if not skip.range and state.range then
        local d = H.DayIndex(e.t)
        if d < state.range[1] or d > state.range[2] then return false end
    end
    local q = state.q
    if q and q ~= "" and not H.Hay(e):find(q:lower(), 1, true) then return false end
    return true
end

function H.FoldKey(e)
    if e.k == "rp.U" and e.v == "add" then return "su:" .. e.o, FOLD.su end
    if e.k == "lg.A" and e.v == "add" then return "aw:" .. tostring(e.w), FOLD.aw end
    return "x:" .. e.o .. ":" .. tostring(e.w) .. ":" .. tostring(e.k) .. ":" .. e.v, FOLD.x
end

-- The list's rows: day headers, the "seen up to here" rule, and rows of one or more folded changes.
function H.Rows()
    local Au = A()
    local rows, cur, head, lastDay = {}, nil, nil, nil
    local seen = Au:LastSeen()
    local seenDone = state.view ~= "all" or seen <= 0
    local anyNew = false
    for _, e in ipairs(Au:Entries()) do
        if H.Match(e) then
            if not seenDone and anyNew and e.t <= seen then
                rows[#rows + 1] = { seen = true }
                seenDone, cur = true, nil
            end
            if Au:IsNew(e) then anyNew = true end
            local d = H.DayIndex(e.t)
            if d ~= lastDay then
                head = { head = true, day = d, t = e.t, count = 0 }
                rows[#rows + 1] = head
                lastDay, cur = d, nil
            end
            head.count = head.count + 1
            local fk, window = H.FoldKey(e)
            if cur and cur.fk == fk and cur.first.t - e.t <= window then
                cur.list[#cur.list + 1] = e
            else
                cur = { e = e, first = e, list = { e }, fk = fk, id = e.id }
                rows[#rows + 1] = cur
            end
        end
    end
    return rows
end

-- A row's two lines.
function H.RowText(r)
    local e, n = r.e, #r.list
    if n > 1 and e.k == "rp.U" and e.v == "add" then
        local names = {}
        for _, x in ipairs(r.list) do names[#names + 1] = x.w end
        return n .. " people signed up for " .. H.Obj(e), Join(names, 3, Name)
    end
    if n > 1 and e.k == "lg.A" and e.v == "add" then
        local aw = {}
        for _, x in ipairs(r.list) do
            for _, f in ipairs(x.f or {}) do
                for _, w in ipairs(f.aw or {}) do aw[#aw + 1] = w end
            end
        end
        return H.Who(e) .. " handed out " .. n .. " items", H.FieldShort({ aw = aw })
    end
    local l2 = H.Summary(e)
    if n > 1 then l2 = n .. " changes" .. (l2 ~= "" and (" · " .. l2) or "") end
    return H.Line1(e), l2
end

local measure
function H.Lines(text, w, style)
    if not measure then
        measure = UIParent:CreateFontString(nil, "OVERLAY")
        UI:SetTextStyle(measure, style or "body")
    end
    UI:SetTextStyle(measure, style or "body")
    measure:SetText(text or "")
    local tw = UI:TextWidth(measure)
    if tw <= w then return 1 end
    return min(3, floor(tw / w) + 1)
end

function H.RowHeight(r)
    if r.head then return 26 end
    if r.seen then return 22 end
    local l1, l2 = H.RowText(r)
    local n1 = H.Lines(l1, ROW_TEXT_W, "body")
    local n2 = (l2 and l2 ~= "") and H.Lines(l2, ROW_TEXT_W, "small") or 0
    return max(S.ROW.art, 14 + n1 * 14 + n2 * 13 + 2)
end

---------------------------------------------------------------------------
-- Art
---------------------------------------------------------------------------

-- Paints art hint x (Core/AuditKinds.lua) on tex, w x h. tile = a dark backing for an icon drawn smaller.
function H.PaintArt(tex, tile, x, w, h)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER")
    tex:SetDesaturated(false)
    tex:SetVertexColor(1, 1, 1)
    tex:SetTexCoord(0, 1, 0, 1)
    tile:Show()
    local kind, val = tostring(x or ""):match("^(%a+):?(.*)$")
    local small = floor(h * 0.8)
    if kind == "raid" then
        local file, l, r, t, b = ns.ItemDB:RaidArt(val ~= "" and val or "other", w, h, 0.5, true)
        tex:SetSize(w, h)
        tex:SetTexture(file)
        tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
        tile:Hide()
    elseif kind == "item" then
        tex:SetSize(small, small)
        tex:SetTexture(UI:ItemIcon(tonumber(val)))
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    elseif kind == "class" or kind == "who" then
        local cls = kind == "class" and val or UI:ClassOf(val)
        tex:SetSize(small, small)
        if cls then UI:ClassIcon(tex, cls) else UI:SetGlyph(tex, "person", "SUB") end
    elseif kind == "seal" then
        tex:SetSize(small, small)
        UI:SetGlyph(tex, "notes", "GOLD")
    else
        tex:SetSize(floor(h * 0.6), floor(h * 0.6))
        UI:SetGlyph(tex, val ~= "" and val or "notes", "SUB")
    end
end

-- The verb badge: a disc in the verb's colour with its glyph.
function H.Badge(parent, size)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(size, size)
    b.disc = UI:CreateDot(b, size, "OK")
    b.disc:ClearAllPoints()
    b.disc:SetAllPoints()
    b.ring = UI:CreateDot(b, size + 3, { 0.08, 0.08, 0.09 }, { layer = "BORDER" })
    b.ring:ClearAllPoints()
    b.ring:SetPoint("CENTER")
    b.glyph = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.glyph:SetSize(size - 6, size - 6)
    b.glyph:SetPoint("CENTER")
    function b:SetVerb(v)
        local def = H.VERB[v] or H.VERB.chg
        self.disc:SetVertexColor(S:Color(def[1]))
        UI:SetGlyph(self.glyph, def[2], { 1, 1, 1 })
    end
    return b
end

---------------------------------------------------------------------------
-- The list's rows
---------------------------------------------------------------------------

local function initRow(row, d)
    row.d = d
    if not row.built then
        row.built = true
        UI:DecorateRow(row, { selectable = true, rule = false })
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.headText = UI:Text(row, "emph", "GOLD")
        row.headText:SetPoint("BOTTOMLEFT", 4, 6)
        row.headDate = UI:Text(row, "small", "SUB")
        row.headDate:SetPoint("LEFT", row.headText, "RIGHT", 6, 0)
        row.headCount = UI:Text(row, "small", "DIM")
        row.headCount:SetPoint("BOTTOMRIGHT", -4, 6)
        row.headRule = UI:Rule(row, { bottom = 2, alpha = 0.08 })
        row.seenText = UI:Text(row, "caps", "GOLD")
        row.seenText:SetPoint("CENTER", 0, -1)
        row.seenL = row:CreateTexture(nil, "ARTWORK")
        row.seenL:SetHeight(1)
        row.seenL:SetPoint("LEFT", 6, -1)
        row.seenL:SetPoint("RIGHT", row.seenText, "LEFT", -8, -1)
        UI:Gradient(row.seenL, "HORIZONTAL", S:WithAlpha("GOLD", 0), S:WithAlpha("GOLD", 0.6))
        row.seenR = row:CreateTexture(nil, "ARTWORK")
        row.seenR:SetHeight(1)
        row.seenR:SetPoint("LEFT", row.seenText, "RIGHT", 8, -1)
        row.seenR:SetPoint("RIGHT", -6, -1)
        UI:Gradient(row.seenR, "HORIZONTAL", S:WithAlpha("GOLD", 0.6), S:WithAlpha("GOLD", 0))
        row.dot = UI:CreateDot(row, 6, "GOLD")
        row.dot:ClearAllPoints()
        row.dot:SetPoint("TOPLEFT", 1, -19)
        row.art = CreateFrame("Frame", nil, row)
        row.art:SetSize(ART_W, ART_H)
        row.art:SetPoint("TOPLEFT", 8, -6)
        row.art.bg = UI:Fill(row.art, { 0.05, 0.05, 0.06, 1 }, "BACKGROUND")
        row.art.tex = row.art:CreateTexture(nil, "ARTWORK")
        UI:AddEdges(row.art, "OVERLAY")
        UI:SetEdgeColor(row.art, S:Color("HAIRLINE"))
        row.badge = H.Badge(row, 16)
        row.badge:SetPoint("CENTER", row.art, "BOTTOMRIGHT", -2, 3)
        row.badge:SetFrameLevel(row:GetFrameLevel() + 4)
        row.l1 = UI:Text(row, "body", "TEXT", { wrap = true, width = ROW_TEXT_W })
        row.l1:SetPoint("TOPLEFT", TEXT_X, -7)
        row.l2 = UI:Text(row, "small", "SUB", { wrap = true, width = ROW_TEXT_W })
        row.l2:SetPoint("TOPLEFT", row.l1, "BOTTOMLEFT", 0, -3)
        row.time = UI:Text(row, "small", "DIM", { justify = "RIGHT" })
        row.time:SetPoint("TOPRIGHT", -8, -8)
        row.flag = row:CreateTexture(nil, "ARTWORK")
        row.flag:SetSize(11, 11)
        row.flag:SetPoint("TOPRIGHT", -8, -24)
        UI:SetGlyph(row.flag, "flag", "WARN")
        row:SetScript("OnClick", function(self)
            local data = self.d
            if data and data.e then AU:Select(data.id) end
        end)
        row:SetScript("OnDoubleClick", function(self)
            local data = self.d
            if data and data.e then AU:OpenStory(data.e.o) end
        end)
    end
    local isHead, isSeen = d.head and true or false, d.seen and true or false
    local isRow = not isHead and not isSeen
    row.headText:SetShown(isHead)
    row.headDate:SetShown(isHead)
    row.headCount:SetShown(isHead)
    row.headRule:SetShown(isHead)
    row.seenText:SetShown(isSeen)
    row.seenL:SetShown(isSeen)
    row.seenR:SetShown(isSeen)
    for _, f in ipairs({ row.art, row.badge, row.l1, row.l2, row.time }) do f:SetShown(isRow) end
    row.dot:Hide()
    row.flag:Hide()
    row:EnableMouse(isRow)
    if row.SetSelected then row:SetSelected(isRow and state.sel == d.id) end
    if isHead then
        row.headText:SetText(d.day == 0 and "Today" or d.day == 1 and "Yesterday" or date("%A", d.t))
        row.headDate:SetText(tonumber(date("%d", d.t)) .. date(" %b", d.t))
        row.headCount:SetText(d.count)
        return
    end
    if isSeen then
        local seen = A():LastSeen()
        row.seenText:SetText("SEEN UP TO HERE · " .. H.WhenIn(seen):upper())
        return
    end
    local e = d.e
    local l1, l2 = H.RowText(d)
    row.l1:SetText(l1)
    row.l2:SetText(l2 or "")
    row.time:SetText(H.Clock(e.t))
    row.badge:SetVerb(e.v)
    H.PaintArt(row.art.tex, row.art.bg, e.x, ART_W, ART_H)
    local new = false
    for _, x in ipairs(d.list) do if A():IsNew(x) then new = true end end
    row.dot:SetShown(new)
    local big = false
    for _, x in ipairs(d.list) do if x.b then big = true end end
    row.flag:SetShown(big)
    local pb = e.v == "rem" and A():PutBackOf(e)
    if pb then row.l2:SetText((l2 and l2 ~= "" and (l2 .. " · ") or "") .. "|cff66b8ffPut back by|r " .. H.Who(pb)) end
end

---------------------------------------------------------------------------
-- The banner and its 30 days
---------------------------------------------------------------------------

function H.CreateStrip(banner)
    local s = CreateFrame("Frame", nil, banner)
    s:SetSize(276, 70)
    s:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -44, -10)
    s:SetFrameLevel(banner:GetFrameLevel() + 6)
    s.label = UI:Text(s, "caps", "SUB")
    s.label:SetPoint("TOPLEFT", 0, 0)
    s.read = UI:Text(s, "small", "TEXT", { justify = "RIGHT" })
    s.read:SetPoint("TOPRIGHT", -14, 0)
    s.clear = UI:CreateTextLink(s, "×", function() AU:SetRange(nil) end, { color = "GOLD", style = "body" })
    s.clear:SetPoint("TOPRIGHT", 0, 3)
    s.base = s:CreateTexture(nil, "ARTWORK")
    s.base:SetColorTexture(1, 1, 1, 0.16)
    s.base:SetHeight(1)
    s.bars = {}
    local bw = (276 - (DAYS - 1) * 2) / DAYS
    for i = 1, DAYS do
        local d = DAYS - i                       -- left: 29 days ago .. right: today
        local b = CreateFrame("Button", nil, s)
        b:SetSize(bw, 44)
        b:SetPoint("BOTTOMLEFT", s, "TOPLEFT", (i - 1) * (bw + 2), -60)
        b.fill = b:CreateTexture(nil, "ARTWORK")
        b.fill:SetPoint("BOTTOMLEFT")
        b.fill:SetPoint("BOTTOMRIGHT")
        b.fill:SetHeight(2)
        b.day = d
        b:RegisterForClicks("LeftButtonUp")
        b:SetScript("OnMouseDown", function() s.dragFrom = d; s.moved = false; AU:PaintStrip(d, d) end)
        b:SetScript("OnMouseUp", function()
            local from = s.dragFrom
            s.dragFrom = nil
            if from == nil then return end
            local lo, hi = min(from, s.hover or d), max(from, s.hover or d)
            local r = state.range
            if not s.moved and r and r[1] == d and r[2] == d then AU:SetRange(nil) else AU:SetRange({ lo, hi }) end
        end)
        b:SetScript("OnEnter", function()
            s.hover = d
            if s.dragFrom and d ~= s.dragFrom then
                s.moved = true
                AU:PaintStrip(min(s.dragFrom, d), max(s.dragFrom, d))
            end
            AU:StripReadout(d)
        end)
        b:SetScript("OnLeave", function() s.hover = nil; AU:StripReadout(nil) end)
        s.bars[i] = b
    end
    s.base:ClearAllPoints()
    s.base:SetPoint("TOPLEFT", s, "TOPLEFT", 0, -60)
    s.base:SetPoint("TOPRIGHT", s, "TOPRIGHT", 0, -60)
    s.today = UI:CreateDot(s, 3, "GOLD")
    s.today:ClearAllPoints()
    s.today:SetPoint("TOP", s.bars[DAYS], "BOTTOM", 0, -3)
    s.ax = {}
    for i, spec in ipairs({ { 1, "LEFT" }, { 14, "CENTER" }, { DAYS, "RIGHT" } }) do
        local t = UI:Text(s, "small", "DIM", { justify = spec[2] })
        t:SetPoint(spec[2] == "LEFT" and "TOPLEFT" or spec[2] == "RIGHT" and "TOPRIGHT" or "TOP", s.bars[spec[1]],
            spec[2] == "LEFT" and "BOTTOMLEFT" or spec[2] == "RIGHT" and "BOTTOMRIGHT" or "BOTTOM", 0, -8)
        s.ax[i] = t
    end
    return s
end

function AU:DayCounts()
    local c = {}
    for d = 0, DAYS - 1 do c[d] = 0 end
    for _, e in ipairs(A():Entries()) do
        local d = H.DayIndex(e.t)
        if d < DAYS and H.Match(e, { range = true }) then c[d] = c[d] + 1 end
    end
    return c
end

function AU:PaintStrip(lo, hi)
    local s = view and view.strip
    if not s then return end
    local c = self:DayCounts()
    s.counts = c
    local mx = 1
    for d = 0, DAYS - 1 do mx = max(mx, c[d]) end
    local r = (lo and { lo, hi }) or state.range
    for _, b in ipairs(s.bars) do
        local d, n = b.day, c[b.day]
        b.fill:SetHeight(n > 0 and max(4, floor(n / mx * 44 + 0.5)) or 2)
        local wd = date("*t", ns.Util.Now() - d * DAY).wday
        local night = (wd == 5 or wd == 1)
        local a
        if r then a = (d >= r[1] and d <= r[2]) and 1 or 0.13 else a = night and 0.62 or 0.34 end
        local gr, gg, gb = S:Color("GOLD")
        if r and d >= r[1] and d <= r[2] then
            b.fill:SetColorTexture(gr, gg, gb, 1)
        elseif r then
            b.fill:SetColorTexture(1, 1, 1, a)
        else
            b.fill:SetColorTexture(gr, gg, gb, n > 0 and a or 0.12)
        end
    end
    local now = ns.Util.Now()
    s.ax[1]:SetText(tonumber(date("%d", now - (DAYS - 1) * DAY)) .. date(" %b", now - (DAYS - 1) * DAY))
    s.ax[2]:SetText(tonumber(date("%d", now - (DAYS - 14) * DAY)) .. date(" %b", now - (DAYS - 14) * DAY))
    s.ax[3]:SetText("Today")
    self:StripReadout(nil)
end

function AU:StripReadout(d)
    local s = view and view.strip
    if not s then return end
    local c = s.counts or self:DayCounts()
    local now = ns.Util.Now()
    local function day(n) return date("%a ", now - n * DAY) .. tonumber(date("%d", now - n * DAY)) end
    s.label:SetText(state.person and "THEIR LAST 30 DAYS" or "LAST 30 DAYS")
    s.clear:SetShown(state.range ~= nil and d == nil)
    if d ~= nil then
        s.read:SetText(day(d) .. " · " .. c[d] .. (c[d] == 1 and " change" or " changes"))
        return
    end
    local r = state.range
    if r then
        local n = 0
        for i = r[1], r[2] do n = n + (c[i] or 0) end
        s.read:SetText((r[1] == r[2] and day(r[1]) or (day(r[2]) .. " – " .. day(r[1]))) .. " · " .. n)
    else
        s.read:SetText("")
    end
end

function AU:SetRange(r)
    state.range = r
    self:Refresh(true)
end

function AU:RefreshBanner()
    local b = view.banner
    local Au = A()
    if state.person then
        local key = state.person
        local cls = UI:ClassOf(key)
        local mine, last = 0, nil
        for _, e in ipairs(Au:Entries()) do
            if e.w == key then
                mine = mine + 1
                last = last or e
            end
        end
        local G = ns.Guild
        local role = (G and G.IsGM and G:IsGM(key)) and "GUILD MASTER" or (G and G.IsGuildCouncil and G:IsGuildCouncil(key))
            and "GUILD COUNCIL" or "MEMBER"
        b:SetKicker(role .. (cls and (" · " .. (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[cls] or cls):upper()) or ""))
        b:SetTitle(Name(key))
        b:SetSub(mine .. (mine == 1 and " change" or " changes") .. " in the log" .. (last and (" · last " .. H.WhenIn(last.t)) or ""))
        if cls and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[cls] then
            local c = CLASS_ICON_TCOORDS[cls]
            b:SetIcon({ "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES", c[1], c[2], c[3], c[4] })
        else
            b:SetIcon("person")
        end
        return
    end
    local n, big = Au:NewCount()
    local seen = Au:LastSeen()
    b:SetIcon(nil)
    b:SetKicker("ONLY THE GUILD COUNCIL AND THE GUILD MASTER SEE THIS")
    b:SetTitle("Audit log")
    if seen > 0 then
        b:SetSub(n .. " new since you looked " .. H.WhenIn(seen) .. (big > 0 and (" · " .. big .. " of them big") or ""))
    else
        b:SetSub("Every change in the addon: who made it, and what it was before and after")
    end
end

---------------------------------------------------------------------------
-- The left rail
---------------------------------------------------------------------------

function AU:RefreshRail()
    local v, Au = view, A()
    local all, newN, bigN = 0, 0, 0
    local byArea, byWho = {}, {}
    for _, e in ipairs(Au:Entries()) do
        if H.Match(e, { view = true }) then
            all = all + 1
            if Au:IsNew(e) then newN = newN + 1 end
            if e.b then bigN = bigN + 1 end
        end
        if H.Match(e, { area = true }) then byArea[e.a] = (byArea[e.a] or 0) + 1 end
        if e.w and H.Match(e, { person = true }) then byWho[e.w] = (byWho[e.w] or 0) + 1 end
    end
    v.rViews:SetCount("new", newN, true)
    v.rViews:SetCount("all", all)
    v.rViews:SetCount("big", bigN)
    v.rViews:Select(state.view)
    for _, a in ipairs(H.AREAS) do
        v.rAreas:SetCount(a[1], byArea[a[1]] or 0)
        local b = v.rAreas.byKey[a[1]]
        if b then b.item.dim = (byArea[a[1]] or 0) == 0 end
    end
    v.rAreas:Select(state.area)
    local people = {}
    for k in pairs(byWho) do people[#people + 1] = k end
    tsort(people, function(x, y)
        if byWho[x] ~= byWho[y] then return byWho[x] > byWho[y] end
        return x < y
    end)
    local items = { { header = "People" } }
    local cap = state.morePeople and 9 or 4
    if state.person and not byWho[state.person] then items[#items + 1] = H.PersonItem(state.person, 0) end
    for i = 1, min(#people, cap) do items[#items + 1] = H.PersonItem(people[i], byWho[people[i]]) end
    if state.person then
        local shown = false
        for _, it in ipairs(items) do if it.key == state.person then shown = true end end
        if not shown then items[#items + 1] = H.PersonItem(state.person, byWho[state.person] or 0) end
    end
    if #people > 4 then
        items[#items + 1] = { key = "__more", label = state.morePeople and "Fewer people" or ("All " .. #people .. " people"), dim = true }
    end
    v.rPeople:SetItems(items)
    v.rPeople:Select(state.person)
    v.rAreas:ClearAllPoints()
    v.rAreas:SetPoint("TOPLEFT", v.rViews, "TOPLEFT", 0, -(v.rViews:GetContentHeight() + 2))
    v.rPeople:ClearAllPoints()
    v.rPeople:SetPoint("TOPLEFT", v.rAreas, "TOPLEFT", 0, -(v.rAreas:GetContentHeight() + 2))
    v.rAreas:Paint()
end

function H.PersonItem(key, n)
    return { key = key, label = Short(key), count = n, dim = n == 0,
        icon = function(tex)
            local cls = UI:ClassOf(key)
            if cls then UI:ClassIcon(tex, cls); tex:SetVertexColor(1, 1, 1) else UI:SetGlyph(tex, "person", "SUB") end
        end }
end

---------------------------------------------------------------------------
-- The detail card
---------------------------------------------------------------------------

-- A flow of lines in a scroll child: fs pool and button pool, reset each time.
function H.Flow(child)
    local f = { child = child, y = 0, fsUsed = 0, fs = {}, btnUsed = 0, btn = {}, rowUsed = 0, rows = {} }
    function f:Reset()
        for _, x in ipairs(self.fs) do x:Hide() end
        for _, x in ipairs(self.btn) do x:Hide() end
        for _, x in ipairs(self.rows) do x:Hide() end
        self.y, self.fsUsed, self.btnUsed, self.rowUsed = 0, 0, 0, 0
    end
    function f:Text(text, style, color, indent, gapAfter)
        self.fsUsed = self.fsUsed + 1
        local fs = self.fs[self.fsUsed]
        if not fs then
            fs = UI:Text(self.child, "body", "TEXT", { wrap = true })
            self.fs[self.fsUsed] = fs
        end
        UI:SetTextStyle(fs, style or "body")
        fs:SetTextColor(S:Color(color or "TEXT"))
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", indent or 0, -self.y)
        fs:SetWidth(DET_W - 26 - (indent or 0))
        fs:SetText(text or "")
        fs:Show()
        local h = fs:GetStringHeight() or 12
        if h <= 0 then h = 12 * H.Lines(text, DET_W - 26 - (indent or 0), style) end
        self.y = self.y + h + (gapAfter or 4)
        return fs
    end
    function f:Gap(n) self.y = self.y + (n or 6) end
    function f:Button(text, kind, onClick, x, w)
        self.btnUsed = self.btnUsed + 1
        local b = self.btn[self.btnUsed]
        if not b then
            b = UI:CreateSleekButton(self.child, text, w or 90, 22, nil, kind)
            self.btn[self.btnUsed] = b
        end
        b:SetKind(kind or "secondary")
        b:SetText(text)
        b:SetWidth(w or max(70, UI:TextWidth(text, "body") + 26))
        b:SetScript("OnClick", onClick)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", x or 0, -self.y)
        b:Show()
        return b
    end
    function f:Row(text, time, verb, onClick)
        self.rowUsed = self.rowUsed + 1
        local r = self.rows[self.rowUsed]
        if not r then
            r = CreateFrame("Button", nil, self.child)
            UI:DecorateRow(r, { rule = false })
            r.dot = UI:CreateDot(r, 7, "GOLD")
            r.dot:ClearAllPoints()
            r.dot:SetPoint("TOPLEFT", 2, -5)
            r.text = UI:Text(r, "small", "TEXT", { wrap = true })
            r.text:SetPoint("TOPLEFT", 14, -2)
            r.time = UI:Text(r, "small", "DIM", { justify = "RIGHT" })
            r.time:SetPoint("TOPRIGHT", -2, -2)
            self.rows[self.rowUsed] = r
        end
        r:SetWidth(DET_W - 26)
        r.text:SetWidth(DET_W - 26 - 14 - 46)
        r.text:SetText(text)
        r.time:SetText(time)
        r.dot:SetVertexColor(S:Color((H.VERB[verb] or H.VERB.chg)[1]))
        local h = max(16, (r.text:GetStringHeight() or 12) + 4)
        r:SetHeight(h)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", 0, -self.y)
        r:SetScript("OnClick", onClick)
        r:Show()
        self.y = self.y + h + 1
        return r
    end
    return f
end

-- A field in full (the detail card, the story).
function H.FieldLong(flow, f, indent)
    indent = indent or 0
    flow:Text(tostring(f.l or ""):upper(), "caps", "DIM", indent, 2)
    if f.aw then
        for _, w in ipairs(f.aw) do
            local item = (w[1] and w[1] ~= 0) and H.ItemText(w[1]) or ("|cffa335ee" .. tostring(w[4] or "An item") .. "|r")
            local icon = (w[1] and w[1] ~= 0) and ("|T" .. UI:ItemIcon(w[1]) .. ":14:14:0:0|t ") or ""
            local reason = w[3] and ns.AWARD_REASON and ns.AWARD_REASON[w[3]]
            flow:Text(icon .. item .. " → " .. Name(w[2]) .. (reason and ("  |cff9e9e9e" .. (reason.label or w[3]) .. "|r") or ""), "body", "TEXT", indent, 3)
        end
    elseif f.mv then
        for _, m in ipairs(f.mv) do
            flow:Text(Name(m[1]) .. "  " .. OLD .. tostring(m[2]) .. "|r → " .. NEW .. tostring(m[3]) .. "|r", "body", "TEXT", indent, 2)
        end
    elseif f.ad or f.rm then
        if f.ad then flow:Text(NEW .. "+|r " .. Join(f.ad, 25, H.Value), "body", "TEXT", indent, 2) end
        if f.rm then flow:Text(OLD .. "−|r " .. Join(f.rm, 25, H.Value), "body", "TEXT", indent, 2) end
    elseif f.ta then
        local a, b = tostring(f.ta), tostring(f.tb or "")
        if a ~= "" then flow:Text(OLD .. a .. "|r", "body", "TEXT", indent, 2) end
        flow:Text(NEW .. (b ~= "" and b or "(empty)") .. "|r", "body", "TEXT", indent, 2)
    elseif f.was then
        flow:Text(OLD .. tostring(f.was) .. "|r", "body", "TEXT", indent, 2)
    elseif f.v ~= nil then
        flow:Text(H.Value(f.v), "body", "TEXT", indent, 2)
    elseif f.a ~= nil then
        flow:Text(OLD .. H.Value(f.a) .. "|r  →  " .. NEW .. H.Value(f.b) .. "|r", "body", "TEXT", indent, 2)
    end
    flow:Gap(6)
end

function H.CreateDetail(parent)
    local c = UI:CreateCard(parent, { tone = "card", width = DET_W, height = BODY_H, pad = 0 })
    local d = { card = c }
    d.band = CreateFrame("Frame", nil, c)
    d.band:SetPoint("TOPLEFT", 1, -1)
    d.band:SetPoint("TOPRIGHT", -1, -1)
    d.band:SetHeight(82)
    d.band.art = d.band:CreateTexture(nil, "BACKGROUND", nil, 1)
    d.band.art:SetAllPoints()
    d.band.shade = d.band:CreateTexture(nil, "BACKGROUND", nil, 2)
    d.band.shade:SetAllPoints()
    UI:Gradient(d.band.shade, "VERTICAL", S:WithAlpha("SURFACE_WINDOW", 1), S:WithAlpha("SURFACE_WINDOW", 0.15))
    d.ring = CreateFrame("Frame", nil, d.band)
    d.ring:SetSize(34, 34)
    d.ring:SetPoint("BOTTOMLEFT", 11, 10)
    d.ring.bg = UI:CreateDot(d.ring, 34, { 0.05, 0.05, 0.06 }, { layer = "BACKGROUND" })
    d.ring.bg:ClearAllPoints()
    d.ring.bg:SetAllPoints()
    d.ring.gold = UI:CreateDot(d.ring, 40, "GOLD", { layer = "BACKGROUND", sublevel = -1 })
    d.ring.gold:ClearAllPoints()
    d.ring.gold:SetPoint("CENTER")
    d.ring.tile = UI:Fill(d.ring, { 0, 0, 0, 0 }, "BORDER")
    d.ring.tex = d.ring:CreateTexture(nil, "ARTWORK")
    d.kicker = UI:Text(d.band, "caps", "GOLD")
    d.title = UI:Text(d.band, "title", "TEXT", { wrap = true, width = DET_W - 66 })
    d.title:SetPoint("BOTTOMLEFT", d.ring, "BOTTOMRIGHT", 10, 0)
    d.kicker:SetPoint("BOTTOMLEFT", d.title, "TOPLEFT", 0, 2)
    d.scroll = UI:CreateScrollFrame(c)
    d.scroll:SetPoint("TOPLEFT", 12, -90)
    d.scroll:SetPoint("BOTTOMRIGHT", -16, 8)
    d.child = CreateFrame("Frame", nil, d.scroll)
    d.child:SetSize(DET_W - 26, 10)
    d.scroll:SetScrollChild(d.child)
    d.flow = H.Flow(d.child)
    d.empty = UI:Text(c, "body", "SUB", { justify = "CENTER", wrap = true, width = DET_W - 40 })
    d.empty:SetPoint("CENTER", 0, 0)
    d.empty:SetText("Pick a change to see it here.")
    return d
end

function AU:RenderDetail()
    local d = view.detail
    local row = state.selRow
    local flow = d.flow
    flow:Reset()
    if not row then
        d.band:Hide()
        d.scroll:Hide()
        d.empty:Show()
        return
    end
    d.empty:Hide()
    d.band:Show()
    d.scroll:Show()
    local e, Au = row.e, A()
    -- the band: the thing's art, its ring, kind and name
    local x = e.x or ""
    if x:find("^raid:") then
        H.PaintArt(d.band.art, d.ring.tile, x, DET_W, 82)
        d.band.art:SetAllPoints()
        d.band.art:SetAlpha(0.85)
    else
        local file, l, r, t, b = ns.ItemDB:RaidArt("other", DET_W, 82, 0.5, true)
        d.band.art:SetTexture(file)
        d.band.art:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
        d.band.art:SetAllPoints()
        d.band.art:SetAlpha(0.45)
    end
    H.PaintArt(d.ring.tex, d.ring.tile, x:find("^raid:") and "g:calendar" or x, 34, 34)
    d.ring.tile:Hide()
    if x:find("^raid:") then
        local inst = x:match("^raid:(.+)$")
        local file, l, r, t, b = ns.ItemDB:RaidArt(inst, 34, 34, 0.5, true)
        d.ring.tex:SetSize(30, 30)
        d.ring.tex:SetTexture(file)
        d.ring.tex:SetTexCoord(l or 0, r or 1, t or 0, b or 1)
    end
    d.kicker:SetText(H.KIND[e.k] or (e.a or ""):upper())
    d.title:SetText(H.Obj(e))
    -- who and when
    if #row.list > 1 and e.k == "rp.U" and e.v == "add" then
        flow:Text(#row.list .. " people signed up", "emph", "TEXT", 0, 1)
    else
        local role = ""
        local G = ns.Guild
        if e.w and G then
            if G.IsGM and G:IsGM(e.w) then role = "  |cff9e9e9eGuild Master|r"
            elseif G.IsGuildCouncil and G:IsGuildCouncil(e.w) then role = "  |cff9e9e9eGuild council|r" end
        end
        flow:Text(H.Who(e) .. role, "emph", "TEXT", 0, 1)
    end
    flow:Text(H.When(e.t) .. (#row.list > 1 and ("  ·  " .. #row.list .. " changes") or ""), "small", "SUB", 0, 8)
    local pb = e.v == "rem" and Au:PutBackOf(e)
    if pb then
        flow:Text(UI:AtlasIconText(9, 12, S.C.YOU) .. " Put back by " .. H.Who(pb) .. ", " .. H.WhenIn(pb.t), "body", "YOU", 0, 8)
    elseif e.b then
        flow:Text(UI:AtlasIconText(UI.ICON.flag, 12, S.C.WARN) .. " Big change · " .. (H.BIG[e.b] or e.b), "body", "WARN", 0, 8)
    end
    if e.s then flow:Text(H.Tokens(e.s), "body", "SUB", 0, 8) end
    -- what changed
    if #row.list > 1 and e.k == "rp.U" and e.v == "add" then
        flow:Text("SIGN-UPS", "caps", "DIM", 0, 2)
        for _, x2 in ipairs(row.list) do
            local ans = x2.f and x2.f[1] and x2.f[1].v or ""
            flow:Text(Name(x2.w) .. "  |cff9e9e9e" .. tostring(ans) .. " · " .. H.Clock(x2.t) .. "|r", "body", "TEXT", 0, 2)
        end
        flow:Gap(6)
    elseif #row.list > 1 then
        for i, x2 in ipairs(row.list) do
            if i > 8 then
                flow:Text("And " .. (#row.list - 8) .. " more", "small", "SUB", 0, 6)
                break
            end
            if e.k ~= "lg.A" then flow:Text(H.Clock(x2.t), "small", "GOLD", 0, 3) end
            for _, f in ipairs(x2.f or {}) do H.FieldLong(flow, f, 0) end
        end
    else
        for _, f in ipairs(e.f or {}) do H.FieldLong(flow, f, 0) end
    end
    -- actions
    flow:Gap(2)
    local x0 = 0
    if Au:CanPutBack(e) then
        local b = flow:Button("Put back", "primary", function() AU:ConfirmPutBack(e) end, x0)
        x0 = x0 + b:GetWidth() + 6
    elseif H.CanOpen(e) then
        local b = flow:Button("Open", "primary", function() H.Open(e) end, x0)
        x0 = x0 + b:GetWidth() + 6
    end
    local story = Au:ForThing(e.o)
    if #story > 1 or H.Related(e.o) then
        flow:Button("Whole story", "secondary", function() AU:OpenStory(e.o) end, x0)
    end
    if x0 > 0 or #story > 1 then flow.y = flow.y + 30 end
    -- the thing's latest changes
    if #story > 1 then
        flow:Gap(6)
        flow:Text("ITS STORY  |cff6f6f74" .. #story .. " changes|r", "caps", "GOLD", 0, 4)
        for i = 1, min(5, #story) do
            local x2 = story[i]
            local r = flow:Row(H.Who(x2) .. " " .. H.StoryPhrase(x2),
                H.DayIndex(x2.t) == 0 and H.Clock(x2.t) or (date("%a ", x2.t) .. tonumber(date("%d", x2.t))), x2.v,
                function() AU:Select(x2.id, true) end)
            r.text:SetTextColor(S:Color(x2.id == e.id and "TEXT" or "SUB"))
        end
        if #story > 5 then
            flow:Gap(2)
            local b = flow:Button("All " .. #story .. " in the whole story", "secondary", function() AU:OpenStory(e.o) end, 0)
            b:SetKind("secondary")
            flow.y = flow.y + 26
        end
    end
    d.child:SetHeight(max(10, flow.y + 4))
    d.scroll:SetVerticalScroll(0)
end

-- Raids also gather their series' changes in the story.
function H.Related(o)
    local sid = o and o:match("^rp:O:(%w+)#%d+$")
    return sid and ("rp:S:" .. sid) or nil
end

---------------------------------------------------------------------------
-- Open the thing / Put back
---------------------------------------------------------------------------

local OPEN = {
    { "^rp:O:(.+)$", function(id) ns.MainFrame:Open("raids"); if ns.RaidsUI then ns.RaidsUI:SetView("upcoming") end
        if ns.RaidPlanUI and ns.RaidPlanUI.SelectRaid then ns.RaidPlanUI:SelectRaid(id) end end },
    { "^rp:S:(.+)$", function() ns.MainFrame:Open("raids"); if ns.RaidsUI then ns.RaidsUI:SetView("upcoming") end end },
    { "^rp:T:(.+)$", function(id) ns.MainFrame:Open("raids"); if ns.RaidsUI then ns.RaidsUI:SetView("teams") end
        if ns.RaidPlanUI and ns.RaidPlanUI.SelectTeam then ns.RaidPlanUI:SelectTeam(id) end end },
    { "^bl:(.+)$", function(key) if ns.GuestBookUI and ns.GuestBookUI.OpenBlacklist then ns.GuestBookUI:OpenBlacklist(key) end end },
    { "^gb:(.+)$", function() ns.MainFrame:Open("raids"); if ns.RaidsUI then ns.RaidsUI:SetView("guests") end end },
    { "^sb:(.+)$", function(id) if ns.StrategyBoard and ns.StrategyBoard.OpenStrategy then ns.StrategyBoard:OpenStrategy(id) end end },
    { "^rl:(.+)$", function(id) ns.MainFrame:Open("raids"); if ns.RaidsUI then ns.RaidsUI:Select(id) end end },
    { "^rc:(.+)$", function(key) if ns.RecruitUI and ns.RecruitUI.Open then ns.RecruitUI:Open(key) end end },
    { "^pl:", function() ns.MainFrame:Open("polls") end },
    { "^ev:", function() ns.MainFrame:Open("events") end },
    { "^lg:", function() ns.MainFrame:Open("council"); if ns.CouncilUI then ns.CouncilUI:SetView("log") end end },
    { "^pz:", function() ns.MainFrame:Open("lootrules"); if ns.LootRulesUI then ns.LootRulesUI:SetView("prized") end end },
    { "^gd:lootrules", function() ns.MainFrame:Open("lootrules") end },
    { "^bis:", function() ns.MainFrame:Open("council"); if ns.CouncilUI then ns.CouncilUI:SetView("roster") end end },
    { "^on:", function() ns.MainFrame:Open("members") end },
    { "^ac:", function() ns.MainFrame:Open("members") end },
    { "^gd:", function() if ns.SettingsUI and ns.SettingsUI.SelectSection then ns.MainFrame:Open("settings"); ns.SettingsUI:SelectSection("guild") else ns.MainFrame:Open("settings") end end },
    { "^pt:", function() ns.MainFrame:Open("changelog") end },
}

function H.CanOpen(e)
    if ns.Util.DemoOn() and not (e.o or ""):find("^rp:") then return false end
    if e.v == "rem" and not e.o:find("^lg:") and not e.o:find("^rl:") then return false end
    for _, spec in ipairs(OPEN) do
        if e.o:find(spec[1]) then return true end
    end
    return false
end

function H.Open(e)
    for _, spec in ipairs(OPEN) do
        local cap = e.o:match(spec[1])
        if cap then
            local ok, err = pcall(spec[2], cap ~= true and cap or nil)
            if not ok then ns:Debug("AuditUI open %s: %s", e.o, tostring(err)) end
            return
        end
    end
end

function AU:ConfirmPutBack(e)
    local what = H.Obj(e)
    ns.Popup:Confirm({ key = "audit-putback", title = "Put it back?",
        text = what .. " comes back as it was when " .. H.Who(e) .. " removed it. The log keeps both changes.",
        ok = "Put back", cancel = "Cancel",
        onAccept = function()
            local ok, err = A():PutBack(e)
            if not ok then ns:Print("%s", tostring(err or "That can't be put back.")) end
            AU:Refresh()
        end })
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

function AU:CreatePanel(parent)
    if view then return view end
    local v = CreateFrame("Frame", nil, parent)
    view = v
    v:SetSize(S.PAGE_W, S.PAGE_H)
    v.main = CreateFrame("Frame", nil, v)
    v.main:SetAllPoints()
    local m = v.main
    v.banner = UI:CreatePageBanner(m, { size = BAN_H, art = "kara", artTint = 0.8, title = "Audit log", width = S.INNER_W,
        rightW = 330,
        tools = { { icon = UI.ICON.more, title = "More", menu = function(root) AU:FillMore(root) end } } })
    v.banner:SetPoint("TOPLEFT", PAD, -PAD)
    v.strip = H.CreateStrip(v.banner)
    -- the rail
    v.rViews = UI:CreateRailNav(m, {
        { key = "new", label = "New for you", icon = "eye", gold = true, tip = "What changed since you last looked" },
        { key = "all", label = "Everything", icon = "notes" },
        { key = "big", label = "Big changes", icon = "flag", iconColor = "WARN" },
    }, function(key) state.view = key; AU:Refresh(true) end, { width = RAIL_W, rowH = 22, selected = state.view })
    v.rViews:SetPoint("TOPLEFT", PAD, -BODY_Y)
    v.rViews:SetSize(RAIL_W, 70)
    local areas = { { header = "Areas" } }
    for _, a in ipairs(H.AREAS) do areas[#areas + 1] = { key = a[1], label = a[2], icon = a[3], tip = a[4] } end
    v.rAreas = UI:CreateRailNav(m, areas, function(key)
        if state.area == key then state.area = nil else state.area = key end
        AU:Refresh(true)
    end, { width = RAIL_W, rowH = 22 })
    v.rAreas:SetSize(RAIL_W, 230)
    v.rPeople = UI:CreateRailNav(m, { { header = "People" } }, function(key)
        if key == "__more" then
            state.morePeople = not state.morePeople
        elseif state.person == key then
            state.person = nil
        else
            state.person = key
        end
        AU:Refresh(true)
    end, { width = RAIL_W, rowH = 22 })
    v.rPeople:SetSize(RAIL_W, 150)
    -- the list
    local lx = PAD + RAIL_W + GAP
    v.search = UI:CreateSearchBox(m, LIST_W, function(text)
        state.q = text or ""
        AU:Refresh(true)
    end, "Search names, raids, items, notes")
    v.search:SetHeight(24)
    v.search:SetPoint("TOPLEFT", lx, -BODY_Y)
    v.kinds = UI:CreateSegments(m, { { key = "all", label = "All" }, { key = "add", label = "Added" },
        { key = "chg", label = "Changed" }, { key = "rem", label = "Removed" } }, function(key)
        state.kind = key
        AU:Refresh(true)
    end, { h = 22, selected = "all" })
    v.kinds:SetPoint("TOPLEFT", lx, -(BODY_Y + 30))
    v.clear = UI:CreateTextLink(m, "Clear", function() AU:Reset() end, { color = "GOLD", align = "RIGHT" })
    v.clear:SetPoint("TOPRIGHT", m, "TOPLEFT", lx + LIST_W, -(BODY_Y + 33))
    v.ruleTop = UI:Rule(m, { top = BODY_Y + 58, left = lx, right = S.PAGE_W - lx - LIST_W, alpha = 0.1 })
    v.list = UI:CreateScrollList(m, S.ROW.art, initRow, function(d) return d.h or H.RowHeight(d) end)
    v.list.frame:SetPoint("TOPLEFT", lx, -(BODY_Y + 60))
    v.list.frame:SetSize(LIST_W, BODY_H - 60)
    v.list.bar:ClearAllPoints()
    v.list.bar:SetPoint("TOPLEFT", v.list.box, "TOPRIGHT", 1, 0)
    v.list.bar:SetPoint("BOTTOMLEFT", v.list.box, "BOTTOMRIGHT", 1, 0)
    v.list:SetEmptyState({ glyph = UI.ICON.notes, title = "Nothing here", compact = true,
        text = "No change matches. Try fewer filters, or Clear." })
    -- the detail
    v.detail = H.CreateDetail(m)
    v.detail.card:SetPoint("TOPLEFT", lx + LIST_W + GAP, -BODY_Y)
    v:SetScript("OnShow", function() AU:Refresh() end)
    v:SetScript("OnHide", function()
        if not ns.Util.DemoOn() then A():MarkSeen() end
    end)
    if ns.AuditStory then ns.AuditStory:Attach(v) end
    return v
end

function AU:FillMore(root)
    root:CreateButton("Mark everything seen", function()
        A():MarkSeen()
        AU:Refresh()
    end)
    root:CreateButton(state.range and "Back to the last 30 days" or "Show all " .. A().KEEP_DAYS .. " days", function()
        AU:SetRange((not state.range) and { 0, A().KEEP_DAYS } or nil)
    end)
    root:CreateDivider()
    root:CreateTitle("Kept " .. A().KEEP_DAYS .. " days, only by the council and the GM")
end

function AU:Reset()
    state.view, state.area, state.person, state.kind, state.q, state.range = "all", nil, nil, "all", "", nil
    if view then
        view.search:SetText("")
        view.kinds:Select("all")
    end
    self:Refresh(true)
end

-- Selects a row by its id (a change's id; a folded row is found by any of its changes). reveal: clear the filters
-- when it is not shown.
function AU:Select(id, reveal)
    state.sel = id
    if view and view.rows then
        local found
        for _, r in ipairs(view.rows) do
            if r.list then
                for _, x in ipairs(r.list) do if x.id == id then found = r end end
            end
        end
        if not found and reveal then
            state.view, state.area, state.person, state.kind, state.q, state.range = "all", nil, nil, "all", "", nil
            view.search:SetText("")
            view.kinds:Select("all")
            return self:Refresh(true, id)
        end
        if found then state.sel = found.id end
        state.selRow = found
        view.list:Refresh()
        self:RenderDetail()
    end
end

function AU:Refresh(resetScroll, selectId)
    local v = view
    if not v or not v:IsShown() then return end
    if not A():CanSee() then return end
    if v.story and v.story:IsShown() then
        if ns.AuditStory then ns.AuditStory:Refresh() end
        return
    end
    local rows = H.Rows()
    for _, r in ipairs(rows) do r.h = H.RowHeight(r) end
    v.rows = rows
    local want = selectId or state.sel
    local sel
    for _, r in ipairs(rows) do
        if r.list then
            for _, x in ipairs(r.list) do if x.id == want then sel = r end end
        end
    end
    if not sel then
        for _, r in ipairs(rows) do if r.list then sel = r break end end
    end
    state.sel = sel and sel.id or nil
    state.selRow = sel
    v.list:SetData(rows, resetScroll)
    -- counts
    local Au = A()
    local kc = { all = 0, add = 0, chg = 0, rem = 0 }
    for _, e in ipairs(Au:Entries()) do
        if H.Match(e, { kind = true }) then
            kc.all = kc.all + 1
            local k = e.v == "back" and "chg" or e.v
            kc[k] = (kc[k] or 0) + 1
        end
    end
    v.kinds:SetLabel("all", "All " .. kc.all)
    v.kinds:SetLabel("add", "Added " .. kc.add)
    v.kinds:SetLabel("chg", "Changed " .. kc.chg)
    v.kinds:SetLabel("rem", "Removed " .. kc.rem)
    local filtered = state.view ~= "all" or state.area or state.person or state.kind ~= "all" or (state.q or "") ~= "" or state.range
    v.clear:SetShown(filtered and true or false)
    self:RefreshBanner()
    self:RefreshRail()
    self:PaintStrip()
    self:RenderDetail()
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

-- Opens Guild > Audit log; opts { view, person, thing (opens its whole story), id (selects that change) }.
function AU:Open(opts)
    opts = type(opts) == "table" and opts or {}
    if opts.view then state.view = opts.view end
    if opts.person then state.person = opts.person end
    if ns.MainFrame then ns.MainFrame:Open("audit") end
    if opts.thing then return self:OpenStory(opts.thing) end
    if view and view.story and view.story:IsShown() and ns.AuditStory then ns.AuditStory:Close(true) end
    if opts.id then self:Select(opts.id, true) else self:Refresh(true) end
end

function AU:OpenStory(o)
    if not o then return end
    if ns.MainFrame and not (view and view:IsVisible()) then ns.MainFrame:Open("audit") end
    if ns.AuditStory and view then ns.AuditStory:Open(o) end
end

-- (tests / audit)
function AU:GetPanel() return view end
function AU:GetState() return state end
function AU:SetSearch(text)
    state.q = text or ""
    if view and view.search then view.search:SetText(state.q) end
    self:Refresh(true)
end
AU.Phrase, AU.Line1, AU.Obj, AU.Who, AU.When, AU.WhenIn = H.Phrase, H.Line1, H.Obj, H.Who, H.When, H.WhenIn
AU.Phrase, AU.Line1, AU.Obj, AU.Who, AU.When, AU.FieldLong, AU.Flow, AU.PaintArt, AU.Badge, AU.Value =
    H.Phrase, H.Line1, H.Obj, H.Who, H.When, H.FieldLong, H.Flow, H.PaintArt, H.Badge, H.Value
AU.KIND, AU.VERB, AU.BIG, AU.Related, AU.CanOpen, AU.OpenThing, AU.Lines, AU.DayIndex =
    H.KIND, H.VERB, H.BIG, H.Related, H.CanOpen, H.Open, H.Lines, H.DayIndex

---------------------------------------------------------------------------
-- Big changes as notifications (off by default: Settings > Alerts)
---------------------------------------------------------------------------

function H.RegisterNotify()
    local N = ns.Notify
    if not (N and N.RegisterKind) then return end
    N:RegisterKind("auditBig", { section = "Guild", page = "audit", icon = UI.ICON.flag, color = S.C.WARN,
        label = "Big changes (audit log)", desc = "Something removed, loot taken back, rights or rules changed.",
        popup = false, sound = false, chat = false, home = false,
        open = function(item) AU:Open({ id = item and item.data }) end })
    A().OnNew = function(c, ctx)
        if not c.b or (c.w and ns.Util.IsMe(c.w)) then return end
        if ns.Util.Now() - c.t > 3600 then return end              -- (old ones a sync brought: no news)
        N:Post("auditBig", { key = c.id, title = H.BIG[c.b] or "Big change",
            text = ns.Util.StripColors and ns.Util.StripColors(H.Line1(c)) or (H.Line1(c):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")),
            from = c.w, time = c.t, data = c.id })
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function AU:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("audit", "Audit log", 3.578, function(parent) return AU:CreatePanel(parent) end,
            function() return A():CanSee() end, { layout = "board" })
    end
    ns:On("AUDIT_UPDATED", function()
        if view and view:IsVisible() then ns.Util.Debounce("audit-ui", 0.15, function() AU:Refresh() end) end
    end)
    ns:On("DEMO_TOGGLED", function()
        state.sel, state.selRow, state.person = nil, nil, nil
        if view and view:IsVisible() then AU:Refresh(true) end
    end)
    ns:RegisterSlash("audit", function() AU:Open() end, "open Guild > Audit log (the guild council and the GM)")
    H.RegisterNotify()
end

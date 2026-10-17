if DisasterZoneBoot and DisasterZoneBoot.Run("UI/AuditStory.lua", ...) then return end -- DisasterZone: UI/AuditStory.lua
-- The audit log's Whole story (UI/AuditUI.lua): one thing's every change, newest first, down to the moment it was
-- made (a weekly raid's week also shows its series' changes).
--   Banner: back to the log, the thing (its art, kind, name), who made it and how many changes, who changed it most,
--           Open.
--   Tabs:   Everything, then one per kind of change when there are several (Details, Sign-ups, ...).
--   Left:   the timeline: a day label, a dot in the verb's colour on a line, a card per change with its fields.
--   Right:  "As it is now", the thing's values as the log knows them (every value a change set, replayed in order);
--           click a change and it shows them right after that change instead, what that change set in gold.
local addonName, ns = ...

local Story = {}
ns.AuditStory = Story

local UI, S = ns.UI, ns.Style
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local PAD, GAP = S.PAD, S.GAP
local BAN_H = 116
local SIDE_W = 248
local TL_W = S.INNER_W - SIDE_W - GAP
local TABS_Y = PAD + BAN_H + 6
local BODY_Y = TABS_Y + 30
local BODY_H = S.PAGE_H - BODY_Y - PAD
local DAY_W = 58
local CARD_X = DAY_W + 20
local CARD_W = TL_W - 20 - CARD_X
local MAX_SIDE = 10

local st = { o = nil, tab = "all", sel = nil }
local sv, page

local function A() return ns.Audit end
local function AU() return ns.AuditUI end
local function Name(key) return UI:ColoredName(key, UI:ClassOf(key)) end

-- (the tab a change goes under)
local TAB_OF = { ["rp.E"] = "Details", ["rp.S"] = "Details", ["rp.U"] = "Sign-ups", ["sb.F"] = "Strategies",
                 ["rl.R"] = "Raid log", ["rl.E"] = "Raid log", ["rl.D"] = "Raid log", ["at.D"] = "Attendance" }
-- A change's words without the thing (the story is about it): "changed it", "signed up", "took it back".
local function StoryPhrase(e) return ns.AuditUI._H.StoryPhrase(e) end

local function TabOf(e) return TAB_OF[e.k] or (AU().KIND[e.k] and (AU().KIND[e.k]:sub(1, 1) .. AU().KIND[e.k]:sub(2):lower())) or "Other" end

-- Every change of the thing (and of its series), newest first.
function Story:Entries(o)
    local Au = A()
    local list = Au:ForThing(o)
    local rel = AU().Related(o)
    if rel then
        for _, e in ipairs(Au:ForThing(rel)) do list[#list + 1] = e end
        tsort(list, function(a, b)
            if a.t ~= b.t then return a.t > b.t end
            return a.id > b.id
        end)
    end
    return list
end

---------------------------------------------------------------------------
-- As it was: the values the log's changes set, replayed oldest first up to one change
---------------------------------------------------------------------------

function Story:Replay(list, upto)
    local vals, order, hit = {}, {}, {}
    local function set(l, v)
        if vals[l] == nil and not order[l] then order[#order + 1] = l; order[l] = true end
        vals[l] = v
    end
    for i = #list, 1, -1 do
        local e = list[i]
        local mine = upto and e.id == upto
        for _, f in ipairs(e.k ~= "rp.U" and e.f or {}) do   -- (one player's sign-up says nothing of the raid)
            local l = f.l
            if type(l) == "string" and not f.aw and not f.mv then
                if f.v ~= nil then set(l, AU().Value(f.v))
                elseif f.a ~= nil then
                    if vals[l] == nil and not order[l] then set(l, AU().Value(f.a)) end
                    set(l, AU().Value(f.b))
                elseif f.ta then set(l, f.tb ~= "" and f.tb or "None")
                elseif f.was then set(l, "None")
                elseif f.ad or f.rm then
                    local cur = type(vals[l]) == "table" and vals[l] or {}
                    local out, seen = {}, {}
                    local gone = {}
                    for _, x in ipairs(f.rm or {}) do gone[x] = true end
                    for _, x in ipairs(cur) do if not gone[x] and not seen[x] then out[#out + 1] = x; seen[x] = true end end
                    for _, x in ipairs(f.ad or {}) do if not seen[x] then out[#out + 1] = x; seen[x] = true end end
                    set(l, out)
                end
                if mine then hit[l] = true end
            end
        end
        if mine then break end
    end
    local rows = {}
    for _, l in ipairs(order) do
        local v = vals[l]
        if type(v) == "table" then
            local names = {}
            for i = 1, min(#v, 6) do names[i] = AU().Value(v[i]) end
            v = #v == 0 and "None" or (tconcat(names, ", ") .. (#v > 6 and (" and " .. (#v - 6) .. " more") or ""))
        end
        rows[#rows + 1] = { l = l, v = v, hit = hit[l] }
    end
    return rows
end

---------------------------------------------------------------------------
-- The timeline's rows
---------------------------------------------------------------------------

local FIELD_LINES = 6

-- A field on one line (in full for a text: the new words).
local function FieldLine(f)
    if f.ta then return tostring(f.l) .. ": |cffa6e3ad" .. tostring(f.tb ~= "" and f.tb or "(empty)") .. "|r" end
    return ns.AuditUI._H.FieldShort(f)
end

local function RowLines(d)
    local e = d.e
    local lines = {}
    if e.s then lines[#lines + 1] = e.s end
    for _, f in ipairs(e.f or {}) do
        if #lines >= FIELD_LINES then break end
        lines[#lines + 1] = FieldLine(f)
    end
    return lines
end

local function RowHeight(d)
    local e = d.e
    local h = 8 + 14 * AU().Lines(AU().Who(e) .. " " .. StoryPhrase(e), CARD_W - 60, "body")
    for _, l in ipairs(RowLines(d)) do h = h + 2 + 13 * AU().Lines(l, CARD_W - 20, "small") end
    return h + 12
end

local function initRow(row, d)
    row.d = d
    if not row.built then
        row.built = true
        row:RegisterForClicks("LeftButtonUp")
        row.day = UI:Text(row, "caps", "GOLD")
        row.day:SetPoint("TOPLEFT", 2, -9)
        row.date = UI:Text(row, "small", "DIM")
        row.date:SetPoint("TOPLEFT", row.day, "BOTTOMLEFT", 0, -2)
        row.line = row:CreateTexture(nil, "BACKGROUND")
        row.line:SetColorTexture(1, 1, 1, 0.12)
        row.line:SetWidth(1)
        row.line:SetPoint("TOP", row, "TOPLEFT", DAY_W + 8, 0)
        row.line:SetPoint("BOTTOM", row, "BOTTOMLEFT", DAY_W + 8, 0)
        row.badge = AU().Badge(row, 14)
        row.badge:SetPoint("CENTER", row, "TOPLEFT", DAY_W + 8, -14)
        row.card = CreateFrame("Frame", nil, row)
        row.card:SetPoint("TOPLEFT", CARD_X, -3)
        row.card:SetPoint("BOTTOMRIGHT", -2, 3)
        row.card.bg = UI:Fill(row.card, "CARD", "BACKGROUND")
        UI:AddEdges(row.card, "BORDER")
        row.l1 = UI:Text(row.card, "body", "TEXT", { wrap = true, width = CARD_W - 60 })
        row.l1:SetPoint("TOPLEFT", 9, -6)
        row.time = UI:Text(row.card, "small", "DIM", { justify = "RIGHT" })
        row.time:SetPoint("TOPRIGHT", -8, -7)
        row.lines = {}
        for i = 1, FIELD_LINES + 1 do
            local fs = UI:Text(row.card, "small", "SUB", { wrap = true, width = CARD_W - 20 })
            row.lines[i] = fs
        end
        row:SetScript("OnClick", function(self)
            local data = self.d
            if not data then return end
            st.sel = (st.sel == data.e.id) and nil or data.e.id
            Story:Paint()
        end)
    end
    local e = d.e
    row.day:SetShown(d.firstOfDay and true or false)
    row.date:SetShown(d.firstOfDay and true or false)
    if d.firstOfDay then
        local di = AU().DayIndex(e.t)
        row.day:SetText(di == 0 and "TODAY" or (date("%a ", e.t) .. tonumber(date("%d", e.t))):upper())
        row.date:SetText(di == 0 and (tonumber(date("%d", e.t)) .. date(" %b", e.t)) or date("%b", e.t))
    end
    row.badge:SetVerb(e.v)
    row.l1:SetText(AU().Who(e) .. " " .. StoryPhrase(e))
    row.time:SetText(date("%H:%M", e.t))
    local prev = row.l1
    local lines = RowLines(d)
    for i, fs in ipairs(row.lines) do
        local l = lines[i]
        fs:ClearAllPoints()
        if l then
            fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -3)
            fs:SetText(l)
            fs:Show()
            prev = fs
        else
            fs:Hide()
        end
    end
    local sel = st.sel == e.id
    if sel then
        row.card.bg:SetColorTexture(S:Color("SELECT"))
        UI:SetEdgeColor(row.card, S:Color("EDGE_FOCUS"))
    else
        row.card.bg:SetColorTexture(S:Color("CARD"))
        UI:SetEdgeColor(row.card, S:Color("EDGE"))
    end
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

-- Builds the story's frame on the audit page (hidden until a story opens).
function Story:Attach(v)
    page = v
    sv = CreateFrame("Frame", nil, v)
    sv:SetAllPoints()
    sv:Hide()
    v.story = sv
    sv.banner = UI:CreatePageBanner(sv, { size = BAN_H, art = "kara", artTint = 0.85, width = S.INNER_W, rightW = 250,
        back = { "Audit log", function() Story:Close() end } })
    sv.banner:SetPoint("TOPLEFT", PAD, -PAD)
    sv.who = CreateFrame("Frame", nil, sv.banner)
    sv.who:SetSize(220, 70)
    sv.who:SetPoint("TOPRIGHT", sv.banner, "TOPRIGHT", -14, -12)
    sv.who:SetFrameLevel(sv.banner:GetFrameLevel() + 6)
    sv.who.head = UI:Text(sv.who, "caps", "SUB", { justify = "RIGHT" })
    sv.who.head:SetPoint("TOPRIGHT", 0, 0)
    sv.who.head:SetText("CHANGED MOST BY")
    sv.who.rows = {}
    for i = 1, 3 do
        local t = UI:Text(sv.who, "body", "TEXT", { justify = "RIGHT" })
        t:SetPoint("TOPRIGHT", 0, -2 - i * 15)
        sv.who.rows[i] = t
    end
    sv.tabs = {}
    sv.hint = UI:Text(sv, "small", "DIM", { justify = "RIGHT" })
    sv.hint:SetPoint("TOPRIGHT", sv, "TOPLEFT", PAD + TL_W, -(TABS_Y + 8))
    sv.hint:SetText("Click a change to see it as it was then")
    sv.rule = UI:Rule(sv, { top = TABS_Y + 26, left = PAD, right = PAD, alpha = 0.1 })
    sv.list = UI:CreateScrollList(sv, 60, initRow, function(d) return d.h or RowHeight(d) end)
    sv.list.frame:SetPoint("TOPLEFT", PAD, -BODY_Y)
    sv.list.frame:SetSize(TL_W, BODY_H)
    sv.list.bar:ClearAllPoints()
    sv.list.bar:SetPoint("TOPLEFT", sv.list.box, "TOPRIGHT", 1, 0)
    sv.list.bar:SetPoint("BOTTOMLEFT", sv.list.box, "BOTTOMRIGHT", 1, 0)
    sv.side = UI:CreateCard(sv, { tone = "card", width = SIDE_W, height = 220, pad = 0 })
    sv.side:SetPoint("TOPLEFT", PAD + TL_W + GAP, -BODY_Y)
    sv.sideTitle = UI:Text(sv.side, "emph", "GOLD")
    sv.sideTitle:SetPoint("TOPLEFT", 10, -9)
    sv.sideNow = UI:CreateTextLink(sv.side, "Now ›", function() st.sel = nil; Story:Paint() end, { color = "SUB", align = "RIGHT" })
    sv.sideNow:SetPoint("TOPRIGHT", -8, -7)
    sv.sideFlow = AU().Flow(sv.side)
    sv.people = UI:CreateCard(sv, { tone = "card", width = SIDE_W, height = 120, pad = 0 })
    sv.peopleTitle = UI:Text(sv.people, "emph", "GOLD")
    sv.peopleTitle:SetPoint("TOPLEFT", 10, -9)
    sv.peopleFlow = AU().Flow(sv.people)
end

function Story:Open(o)
    if not sv then return end
    st.o, st.tab, st.sel = o, "all", nil
    page.main:Hide()
    sv:Show()
    self:Refresh()
end

function Story:Close(quiet)
    if not sv then return end
    sv:Hide()
    page.main:Show()
    st.o = nil
    if not quiet and AU() then AU():Refresh() end
end

function Story:IsOpen() return sv and sv:IsShown() and st.o or nil end
function Story:GetState() return st end

function Story:Refresh()
    if not (sv and sv:IsShown() and st.o) then return end
    local all = self:Entries(st.o)
    if #all == 0 then return self:Close() end
    local newest, oldest = all[1], all[#all]
    -- the banner
    local b = sv.banner
    local x = newest.x or ""
    local inst = x:match("^raid:(.+)$")
    b:SetArt(inst or "other")
    b:SetKicker(AU().KIND[newest.k] or (newest.a or ""):upper())
    b:SetTitle(AU().Obj(newest))
    local made = ((oldest.v == "add" and oldest.k ~= "rp.U") and "Made by " or "First change by ") .. AU().Who(oldest) .. ", "
        .. AU().WhenIn(oldest.t)
    local signups = 0
    for _, e in ipairs(all) do if e.k == "rp.U" and e.v == "add" then signups = signups + 1 end end
    b:SetSub(made .. " · " .. #all .. (#all == 1 and " change" or " changes") .. (signups > 0 and (" · " .. signups .. " sign-ups") or ""))
    local canOpen = AU().CanOpen(newest)
    b:SetActions(canOpen and { { text = "Open", kind = "primary", onClick = function() AU().OpenThing(newest) end } } or {})
    local counts, keys = {}, {}
    for _, e in ipairs(all) do
        if e.w and e.k ~= "rp.U" then
            if not counts[e.w] then keys[#keys + 1] = e.w end
            counts[e.w] = (counts[e.w] or 0) + 1
        end
    end
    tsort(keys, function(a, c) if counts[a] ~= counts[c] then return counts[a] > counts[c] end return a < c end)
    sv.who.head:SetShown(#keys > 0)
    for i, t in ipairs(sv.who.rows) do
        local k = keys[i]
        t:SetText(k and (Name(k) .. "  |cff8d8d93" .. counts[k] .. "|r") or "")
    end
    -- the tabs
    local tabCounts, tabOrder = {}, {}
    for _, e in ipairs(all) do
        local t = TabOf(e)
        if not tabCounts[t] then tabOrder[#tabOrder + 1] = t end
        tabCounts[t] = (tabCounts[t] or 0) + 1
    end
    for _, t in ipairs(sv.tabs) do t:Hide() end
    local specs = { { key = "all", text = "Everything", n = #all } }
    if #tabOrder > 1 then
        for _, t in ipairs(tabOrder) do specs[#specs + 1] = { key = t, text = t, n = tabCounts[t] } end
    end
    if st.tab ~= "all" and not tabCounts[st.tab] then st.tab = "all" end
    local prev
    for i, spec in ipairs(specs) do
        local tab = sv.tabs[i]
        if not tab then
            tab = UI:CreateUnderlineTab(sv, "", nil, "small")
            sv.tabs[i] = tab
        end
        local key = spec.key
        tab:SetLabel(spec.text .. "  |cff77777d" .. spec.n .. "|r")
        tab:SetScript("OnClick", function() st.tab, st.sel = key, nil; Story:Refresh() end)
        tab:ClearAllPoints()
        if prev then tab:SetPoint("LEFT", prev, "RIGHT", 6, 0) else tab:SetPoint("TOPLEFT", PAD - 2, -TABS_Y) end
        if tab.SetActive then tab:SetActive(st.tab == key) end
        tab:Show()
        prev = tab
    end
    -- the timeline
    local rows, lastDay = {}, nil
    for _, e in ipairs(all) do
        if st.tab == "all" or TabOf(e) == st.tab then
            local di = AU().DayIndex(e.t)
            local d = { e = e, firstOfDay = di ~= lastDay }
            lastDay = di
            d.h = RowHeight(d)
            rows[#rows + 1] = d
        end
    end
    sv.rows = rows
    sv.all = all
    sv.list:SetData(rows, true)
    self:Paint()
end

-- The side cards (and the rows' selected look).
function Story:Paint()
    if not sv then return end
    sv.list:Refresh()
    local all = sv.all or {}
    local sel
    for _, e in ipairs(all) do if e.id == st.sel then sel = e end end
    local rows = self:Replay(all, sel and sel.id or nil)
    local flow = sv.sideFlow
    flow:Reset()
    flow.y = 30
    if sel then
        sv.sideTitle:SetText("As it was " .. AU().WhenIn(sel.t))
        sv.sideNow:Show()
    else
        sv.sideTitle:SetText("As it is now")
        sv.sideNow:Hide()
    end
    if #rows == 0 then
        flow:Text("Nothing the log can show yet.", "small", "SUB", 10, 4)
    end
    for i, r in ipairs(rows) do
        if i > MAX_SIDE then break end
        flow:Text(tostring(r.l):upper(), "caps", r.hit and "GOLD" or "DIM", 10, 1)
        flow:Text(tostring(r.v), "body", r.hit and "GOLD" or "TEXT", 10, 6)
    end
    local h = flow.y + 6
    sv.side:SetHeight(h)
    if sv.side.bg then sv.side.bg:SetAllPoints() end
    if sel then
        UI:SetEdgeColor(sv.side, S:Color("EDGE_FOCUS"))
    else
        UI:SetEdgeColor(sv.side, S:Color("EDGE"))
    end
    -- everyone in it
    local counts, keys = {}, {}
    for _, e in ipairs(all) do
        if e.w then
            if not counts[e.w] then keys[#keys + 1] = e.w end
            counts[e.w] = (counts[e.w] or 0) + 1
        end
    end
    tsort(keys, function(a, c) if counts[a] ~= counts[c] then return counts[a] > counts[c] end return a < c end)
    sv.peopleTitle:SetText("Everyone in it  |cff8d8d93" .. #keys .. "|r")
    local pf = sv.peopleFlow
    pf:Reset()
    pf.y = 30
    for i = 1, min(#keys, 8) do
        pf:Text(Name(keys[i]) .. "  |cff8d8d93" .. counts[keys[i]] .. "|r", "body", "TEXT", 10, 3)
    end
    if #keys > 8 then pf:Text("and " .. (#keys - 8) .. " more", "small", "SUB", 10, 3) end
    sv.people:ClearAllPoints()
    sv.people:SetPoint("TOPLEFT", sv.side, "BOTTOMLEFT", 0, -GAP)
    sv.people:SetHeight(pf.y + 6)
    sv.people:SetShown(#keys > 0 and (BODY_H - h - GAP) > 60)
end

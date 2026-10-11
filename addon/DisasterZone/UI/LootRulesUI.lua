if DisasterZoneBoot and DisasterZoneBoot.Run("UI/LootRulesUI.lua", ...) then return end -- DisasterZone: UI/LootRulesUI.lua
-- Raids > Loot rules (1.3.5, the user's pick "the path", mockup dev/art/casc/lootrules_mockup): the guild's loot rules
-- for every member, read-only (Council > Rules is where the Guild Master and the council set them). Two views, the
-- toolbar's tabs:
--   How it's decided: a banner, then the rules as numbered steps along a gold line, in plain words and built from the
--     guild's rules as they are (Guild:GetLootRules): who can be suggested, the council's votes first, your list sets
--     your group, then inside a group (longest use, driest, the roll: only those switched on). On the right, Where you
--     stand: my own numbers against them (attendance and the floor, raids since my last item when this client knows
--     it, my BiS list for the phase, how long my picks last when Longest use is on, the prized items I qualify for).
--   Prized items (1.4: the list + detail layout, as Council > Rules > Prized items): the items as art rows grouped by
--     raid on the left (my standing on each), the picked one on the right - its banner (the item, my standing) with
--     Rules / History on its foot: its rules with how I stand, its history. The rule and history rows are
--     UI/PrizedUI.lua's own.
local addonName, ns = ...

local LootRulesUI = ns:NewModule("LootRulesUI")

local UI = ns.UI
local S = ns.Style

local floor, max, min = math.floor, math.max, math.min
local format, tconcat = string.format, table.concat

local K = { W = S.INNER_W, GAP = S.GAP, LEFT_W = 480, NODE = 34, LIST_W = 300, INTRO_H = 44 }
K.RIGHT_X = K.LEFT_W + K.GAP
K.RIGHT_W = K.W - K.RIGHT_X
K.DETAIL_W = K.W - K.LIST_W - K.GAP
local MEDIA = "Interface\\AddOns\\DisasterZone\\Media\\"
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"

local state = { view = "decided", item = nil }
local panel

local function Me() return ns.Util.PlayerKey() end

-- (art pack 7's icons fall back without it)
local ICON_FALLBACK = { ballot = "poll", prized = "trophy", stopwatch = "calendar" }
local function IconName(name)
    if ICON_FALLBACK[name] and not (ns.HasAssets and ns:HasAssets(7)) then return ICON_FALLBACK[name] end
    return name
end

local function Plural(n, one, many) return n == 1 and ("1 " .. one) or (n .. " " .. (many or (one .. "s"))) end

-- A banner pill in any pill kind ("bis": the banner's own SetPill reads the event kinds only).
-- TODO(refactor): move into CreatePageBanner (SetPill with every pill kind: "bis")
local function BannerPill(b, kind, text)
    b.pill:SetPill(kind, text)
    b.pill:SetShown(text ~= nil and text ~= "")
    b:Layout()
end

local function Rules()
    local G = ns.Guild
    return G and G.GetLootRules and G:GetLootRules() or { f = 0, s = "r", l = "l", w = "r", y = "n", o = 0, q = "h" }
end

---------------------------------------------------------------------------
-- How it's decided
---------------------------------------------------------------------------

-- A pool of tag pills on a parent (reused on every fill).
local function NewStepPill(parent)
    local p = UI:CreatePill(parent, 20)
    p:SetBase(S:Color("INSET"))
    return p
end

-- The steps, as words, from the rules: { { title, chips = { { text, kind, icon } ... }, sep = "›" (chips in an order),
-- text } }.
local function StepDefs(R)
    local steps = {}
    local floorPct = tonumber(R.f) or 0
    local who = { { "Didn't pass", "ok", CHECK }, { "In the raid", "ok", CHECK }, { "Can use it", "ok", CHECK } }
    if floorPct > 0 then who[#who + 1] = { floorPct .. "%+ attendance", "ok", CHECK } end
    steps[#steps + 1] = { title = "Who can be suggested", chips = who,
        text = floorPct > 0 and format("Under %d%% attendance you are still listed, with a warning, but never the "
            .. "suggestion.", floorPct) or "Anyone who rolled, still in the raid and able to use it." }
    steps[#steps + 1] = { title = "The council's votes come first", sep = true,
        chips = { { "Most votes", "bis" }, { R.s == "p" and "A tie: the council picks" or "A tie: the highest roll", "mute" } },
        text = R.s == "p" and "Most votes is the suggestion. When votes tie, the council picks one of them."
            or "Most votes is the suggestion. A tie goes to the highest roll among them; whoever didn't roll never "
            .. "wins a tie." }
    if R.l ~= "r" then
        steps[#steps + 1] = { title = "No votes yet? Your list sets your group", sep = true,
            chips = { { "BiS", "bis" }, { "Alt", "alt" }, { "Off-spec", "os" }, { "Everyone else", "mute" } },
            text = "Players with it as a BiS pick come before alts, off-spec lists, then everyone else." }
    else
        steps[#steps + 1] = { title = "No votes yet? The roll decides", chips = { { "Lists don't matter", "mute" } },
            text = "Whoever's list it is on doesn't matter: the highest roll is the suggestion." }
    end
    local chain, words = {}, {}
    local upTo = tonumber(R.o) or 0
    if upTo > 0 then
        chain[#chain + 1] = { "Longest use, to P" .. upTo, "mute" }
        words[#words + 1] = format("who keeps it on their list longest (to P%d)", upTo)
    end
    if R.w == "d" then
        chain[#chain + 1] = { "Driest first", "mute" }
        words[#words + 1] = "the most raids since their last item"
    end
    chain[#chain + 1] = { "Highest roll", "mute" }
    local text
    if #words == 0 then
        text = "The highest roll wins."
    else
        text = "First " .. tconcat(words, ", then ") .. "; the roll breaks the last tie."
    end
    steps[#steps + 1] = { title = R.l ~= "r" and "Then, inside a group" or "The roll", sep = true, chips = chain, text = text }
    return steps
end

local function DecidedBanner(parent)
    local b = UI:CreatePageBanner(parent, { size = "tool", art = "BlackTemple", width = K.W, icon = IconName("ballot"),
        kicker = "Loot rules", title = "How the winner is picked", titleColor = "TEXT",
        sub = "The loot council decides. These rules make the drop panel's suggestion, the same for everyone." })
    if b.icon then b.icon.tex:SetVertexColor(S:Color("GOLD")) end
    return b
end

-- The path: the steps as numbered nodes along a gold line, on an inset card. (A drawing of its own: the numbered
-- nodes and the line between them are this page's figure, not a page structure.)
local function BuildPath(parent)
    local p = UI:CreateCard(parent, { tone = "inset", title = "How the suggestion is made", titleStyle = "caps",
        pad = S.PAD + 4 })
    p.line = p:CreateTexture(nil, "ARTWORK")
    p.line:SetWidth(2)
    local gd = S.C.GOLD_DEEP
    UI:Gradient(p.line, "VERTICAL", { gd[1], gd[2], gd[3], 0.25 }, { gd[1], gd[2], gd[3], 1 })
    p.steps = {}
    for i = 1, 4 do
        local s = CreateFrame("Frame", nil, p.body)
        s.node = CreateFrame("Frame", nil, s)
        s.node:SetSize(K.NODE, K.NODE)
        s.node:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
        s.node.disc = s.node:CreateTexture(nil, "ARTWORK", nil, 0)
        s.node.disc:SetTexture(MEDIA .. "Strategy\\disc")
        s.node.disc:SetVertexColor(S:Color("INSET"))
        s.node.disc:SetAllPoints()
        s.node.ring = s.node:CreateTexture(nil, "ARTWORK", nil, 1)
        s.node.ring:SetTexture(MEDIA .. "Events\\ring")
        s.node.ring:SetVertexColor(S:Color("GOLD_DEEP"))
        s.node.ring:SetAllPoints()
        s.node.n = UI:Text(s.node, "page", "GOLD", { justify = "CENTER", text = tostring(i) })
        s.node.n:SetPoint("CENTER", 0, 0)
        s.title = UI:Text(s, "title", "TEXT")
        s.title:SetPoint("TOPLEFT", s, "TOPLEFT", K.NODE + 14, -2)
        s.pills = UI:Pool(s, NewStepPill)
        s.seps = {}
        s.text = UI:Text(s, "sub", nil, { wrap = true })
        p.steps[i] = s
    end
    p.foot = UI:Text(p, "sub", nil, { text = "The loot council decides in the end: this is only how its suggestion is made." })
    p.foot:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", p.pad, p.pad)
    return p
end

local function FillPath(p, R)
    local defs = StepDefs(R)
    local w = K.LEFT_W - 2 * p.pad
    local textX = K.NODE + 14
    local y = -4
    local firstY, lastY
    for i, s in ipairs(p.steps) do
        local d = defs[i]
        s:SetShown(d ~= nil)
        if d then
            s:ClearAllPoints()
            s:SetPoint("TOPLEFT", p.body, "TOPLEFT", 0, y)
            s:SetWidth(w)
            s.title:SetText(d.title)
            s.pills:ReleaseAll()
            for _, t in ipairs(s.seps) do t:Hide() end
            local x, rowY = textX, -22
            for j, c in ipairs(d.chips) do
                local pill = s.pills:Acquire()
                pill:Set(c[1], c[2], c[3])
                if x + pill:GetWidth() > w and x > textX then
                    x, rowY = textX, rowY - 24
                end
                pill:ClearAllPoints()
                pill:SetPoint("TOPLEFT", s, "TOPLEFT", x, rowY)
                x = x + pill:GetWidth() + 6
                if d.sep and j < #d.chips then
                    local sep = s.seps[j]
                    if not sep then
                        sep = UI:Text(s, "title", "DIM", { text = "›" })
                        s.seps[j] = sep
                    end
                    sep:ClearAllPoints()
                    sep:SetPoint("TOPLEFT", s, "TOPLEFT", x - 1, rowY - 3)
                    sep:Show()
                    x = x + 10
                end
            end
            s.text:ClearAllPoints()
            s.text:SetPoint("TOPLEFT", s, "TOPLEFT", textX, rowY - 26)
            s.text:SetWidth(w - textX)
            s.text:SetText(d.text)
            local h = -(rowY - 26) + (s.text:GetStringHeight() or 13) + 4
            h = max(h, K.NODE + 6)
            s:SetHeight(h)
            local cy = y - K.NODE / 2
            firstY = firstY or cy
            lastY = cy
            y = y - h - 12
        end
    end
    p.line:ClearAllPoints()
    p.line:SetPoint("TOP", p.body, "TOPLEFT", K.NODE / 2, firstY or 0)
    p.line:SetPoint("BOTTOM", p.body, "TOPLEFT", K.NODE / 2, lastY or 0)
end

-- Where you stand: one section per number (a caps section header, the number, a line under it), built once, shown
-- when it has something to say. r.head (the header: its action is the way on), r.big, r.after, r.note.
local function WRow(parent, label, action)
    local r = CreateFrame("Frame", nil, parent)
    r.head = UI:CreateSectionHeader(r, label, { style = "caps", action = action })
    r.head:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
    r.head:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)
    r.label = r.head.title
    r.big = UI:Text(r, "page", "TEXT")
    r.big:SetPoint("TOPLEFT", r.head, "BOTTOMLEFT", 2, -4)
    r.after = UI:Text(r, "sub")
    r.after:SetPoint("BOTTOMLEFT", r.big, "BOTTOMRIGHT", 8, 1)
    r.note = UI:Text(r, "sub", nil, { wrap = true })
    return r
end

local ROW_HEAD = 18 + 4      -- a section's header and the gap under it

local function BuildYou(parent)
    local p = UI:CreateCard(parent, { tone = "inset", title = "Where you stand", titleStyle = "caps", pad = S.PAD + 4 })
    local b = p.body
    p.cls = b:CreateTexture(nil, "ARTWORK")
    p.cls:SetSize(30, 30)
    p.cls:SetPoint("TOPLEFT", b, "TOPLEFT", 0, -2)
    p.name = UI:Text(b, "title", "TEXT")
    p.name:SetPoint("TOPLEFT", p.cls, "TOPRIGHT", 10, 0)
    p.spec = UI:Text(b, "sub")
    p.spec:SetPoint("TOPLEFT", p.name, "BOTTOMLEFT", 0, -2)
    p.att = WRow(b, "Attendance")
    p.att.pill = UI:CreatePill(p.att, 18)
    p.att.pill:SetBase(S:Color("INSET"))
    p.att.pill:SetPoint("RIGHT", p.att, "TOPRIGHT", 0, -(ROW_HEAD + 10))
    p.dry = WRow(p.body, "Since your last item")
    p.dry.bars = {}
    for i = 1, 6 do
        local t = p.dry:CreateTexture(nil, "ARTWORK")
        t:SetSize(7, 16)
        p.dry.bars[i] = t
    end
    p.bis = WRow(b, "Your BiS list", { text = "Open My BiS",
        onClick = function() if ns.MainFrame then ns.MainFrame:Open("mybis") end end })
    p.bis.track = p.bis:CreateTexture(nil, "ARTWORK", nil, 0)
    p.bis.track:SetHeight(5)
    p.bis.track:SetColorTexture(S:Color("EDGE_QUIET"))
    p.bis.fill = p.bis:CreateTexture(nil, "ARTWORK", nil, 1)
    p.bis.fill:SetHeight(5)
    UI:Gradient(p.bis.fill, "HORIZONTAL", "GOLD_DEEP", "GOLD")
    p.bis.open = p.bis.head.action
    p.lng = WRow(b, "Longest use")
    p.prz = WRow(b, "Prized items", { text = "", onClick = function() LootRulesUI:SetView("prized") end })
    p.prz.go = p.prz.head.action
    p.prz.icons = {}
    for i = 1, 6 do
        local f = UI:CreateIconTile(p.prz, 24)
        f:SetPoint("TOPLEFT", p.prz.head, "BOTTOMLEFT", 2 + (i - 1) * 30, -6)
        p.prz.icons[i] = f
    end
    return p
end

-- My attendance % (the raid log's, or the copy a reader sent me) or nil.
local function MyAttendance()
    local Att, RL, me = ns.Attendance, ns.RaidLog, Me()
    if Att and Att.CanSeeAll and Att:CanSeeAll() and RL and RL.GetAttendance then
        return (RL:GetAttendance(me, 8))
    end
    local mine = Att and Att.GetMine and Att:GetMine()
    if not mine and Att and Att.RequestMine then Att:RequestMine() end
    return mine and mine.p or nil
end

-- (each section as tall as its texts really are: the game's fonts run taller than they look)
local function TextH(fs)
    return fs and fs:IsShown() and fs:GetText() and fs:GetText() ~= "" and (fs:GetStringHeight() or 0) or 0
end
local function HeadH(r) return ROW_HEAD + max(TextH(r.big), 18) end

local function FillYou(p, R)
    local me = Me()
    local G, Store = ns.Guild, ns.Store
    local rec = Store and Store.Get and me and Store:Get(me)
    local data = rec and rec.data
    local cls = (data and data.cl) or (G and G.GetClass and me and G:GetClass(me))
    if cls then UI:ClassIcon(p.cls, cls) end
    p.name:SetText(me and UI:ColoredName(me, cls) or "You")
    p.spec:SetText(((data and data.sp) and (data.sp .. " ") or "") .. (cls and ns.ClassName(cls) or ""))
    local w = K.RIGHT_W - 2 * p.pad
    -- (rows are measured first, then laid out: under a tight panel the gaps shrink, then the prized row goes)
    local rows = {}
    local function place(r, h)
        r:SetWidth(w)
        rows[#rows + 1] = { r = r, h = h }
    end
    -- attendance against the floor
    local att = MyAttendance()
    local floorPct = tonumber(R.f) or 0
    if att then
        p.att.big:SetText(att .. "%")
        p.att.big:SetTextColor(S:Color(att >= 90 and "OK" or "TEXT"))
        p.att.after:SetText("last 8 raids")
    else
        p.att.big:SetText("–")
        p.att.big:SetTextColor(S:Color("SUB"))
        p.att.after:SetText("asking a raid log reader")
    end
    p.att.pill:SetShown(floorPct > 0 and att ~= nil)
    if floorPct > 0 and att then
        if att >= floorPct then
            p.att.pill:Set("above the " .. floorPct .. "% floor", "ok", CHECK)
        else
            p.att.pill:Set("under the " .. floorPct .. "% floor", "warn")
        end
    end
    p.att.note:Hide()
    place(p.att, HeadH(p.att))
    -- raids since my last item (only where this client keeps the loot log: the council)
    local Att = ns.Attendance
    local d = Att and Att.CanSeeDryStreaks and Att:CanSeeDryStreaks() and me and Att:GetDryStreak(me) or nil
    if d then
        local n = tonumber(d.nights) or 0
        p.dry.big:ClearAllPoints()
        p.dry.big:SetPoint("TOPLEFT", p.dry.head, "BOTTOMLEFT", 2 + 6 * 9 + 6, -4)
        for i, t in ipairs(p.dry.bars) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", p.dry.head, "BOTTOMLEFT", 2 + (i - 1) * 9, -6)
            t:SetColorTexture(S:Color(i <= min(n, 6) and "WARN" or "EDGE_QUIET"))
        end
        p.dry.big:SetText(Plural(n, "raid"))
        p.dry.after:SetText("")
        local last = d.last
        local nm = last and UI:ItemName(last.i)
        p.dry.note:ClearAllPoints()
        p.dry.note:SetPoint("TOPLEFT", p.dry.big, "BOTTOMLEFT", -(6 * 9 + 6), -4)
        p.dry.note:SetWidth(w)
        p.dry.note:SetText(nm and ("Last: " .. nm .. ", " .. (ns.Util.FormatAgo and ns.Util.FormatAgo(last.ts) or "")) or
            "No item on record yet.")
        p.dry.note:Show()
        place(p.dry, HeadH(p.dry) + 4 + max(TextH(p.dry.note), 11))
    else
        p.dry:Hide()
    end
    -- my BiS list for the phase
    local phase = G and G.GetViewPhase and G:GetViewPhase() or 1
    local picked, total, empty = 0, 0, {}
    local ph = data and type(data.ph) == "table" and data.ph[phase]
    -- (a two-hander leaves the off hand empty on purpose, as My BiS counts it)
    local mh = type(ph) == "table" and type(ph[15]) == "table" and tonumber(ph[15][1]) or 0
    local twoHand = mh > 0 and ns.ItemDB and ns.ItemDB:GetEquipLoc(mh) == "INVTYPE_2HWEAPON"
    for _, slot in ipairs(ns.SLOTS or {}) do
        local skip = twoHand and slot.id == 16 and not (type(ph[16]) == "table" and (tonumber(ph[16][1]) or 0) > 0)
        if not skip and not (Store and Store.IsSlotDisabled and data and Store:IsSlotDisabled(data, phase, slot.id)) then
            total = total + 1
            local e = type(ph) == "table" and ph[slot.id]
            if type(e) == "table" and (tonumber(e[1]) or 0) > 0 then
                picked = picked + 1
            else
                empty[#empty + 1] = slot.label
            end
        end
    end
    p.bis.head:SetTitle("Your BiS list · P" .. phase)
    p.bis.big:SetText(picked .. S:Wrap("SUB", " / " .. total .. " picked"))
    p.bis.after:SetText("")
    p.bis.track:ClearAllPoints()
    p.bis.track:SetPoint("TOPLEFT", p.bis.big, "BOTTOMLEFT", 0, -6)
    p.bis.track:SetWidth(w - 2)
    p.bis.fill:ClearAllPoints()
    p.bis.fill:SetPoint("TOPLEFT", p.bis.track)
    p.bis.fill:SetWidth(max(1, (w - 2) * (total > 0 and picked / total or 0)))
    p.bis.fill:SetShown(picked > 0)
    p.bis.note:ClearAllPoints()
    p.bis.note:SetPoint("TOPLEFT", p.bis.track, "BOTTOMLEFT", 0, -6)
    p.bis.note:SetWidth(w)
    if #empty == 0 then
        p.bis.note:SetText(R.l ~= "r" and "Every slot picked: lists come first." or "Every slot picked.")
    else
        local list = {}
        for i = 1, min(#empty, 3) do list[i] = empty[i] end
        p.bis.note:SetText("Empty: " .. tconcat(list, ", ") .. (#empty > 3 and (" and " .. (#empty - 3) .. " more") or ""))
    end
    p.bis.note:Show()
    place(p.bis, HeadH(p.bis) + 6 + 5 + 6 + max(TextH(p.bis.note), 11))
    -- longest use: my picks kept to the last phase counted
    local upTo = tonumber(R.o) or 0
    if upTo > 0 and Store and Store.Longevity and type(ph) == "table" then
        local kept, n = 0, 0
        for _, e in pairs(ph) do
            local id = type(e) == "table" and tonumber(e[1])
            if id and id > 0 then
                n = n + 1
                local _, _, last = Store:Longevity(me, id, phase, upTo)
                if last and last >= upTo then kept = kept + 1 end
            end
        end
        p.lng.head:SetTitle("Longest use · counted to P" .. upTo)
        p.lng.big:SetText(Plural(kept, "pick"))
        p.lng.after:SetText(format("kept on your list to P%d, out of %d", upTo, n))
        p.lng.note:Hide()
        place(p.lng, HeadH(p.lng))
    else
        p.lng:Hide()
    end
    -- the prized items I qualify for
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    if #items > 0 then
        local ok = 0
        for i, it in ipairs(items) do
            local c = P:Check(it, me)
            if c.ok == true then ok = ok + 1 end
            local f = p.prz.icons[i]
            if f then
                f:Set(UI:ItemIcon(it.ids[1]))
                f:SetAlpha(c.ok == false and 0.4 or 1)
            end
        end
        for i = #items + 1, #p.prz.icons do p.prz.icons[i]:Hide() end
        p.prz.big:SetText("")
        p.prz.after:SetText("")
        p.prz.note:Hide()
        p.prz.head:SetAction({ text = format("%d of %d you qualify for", ok, #items),
            onClick = function() LootRulesUI:SetView("prized") end })
        p.prz.go = p.prz.head.action
        place(p.prz, ROW_HEAD + 2 + 24)
    else
        p.prz:Hide()
    end
    local top = 30 + S.GAP + 4       -- under who I am
    local room = (p.body:GetHeight() or 0) - top
    local sum = 0
    for _, it in ipairs(rows) do sum = sum + it.h end
    local pad = 14
    if room > 0 and sum + pad * #rows > room then
        pad = max(6, floor((room - sum) / #rows))
        if sum + pad * #rows > room and #rows > 1 and rows[#rows].r == p.prz then
            p.prz:Hide()
            sum = sum - rows[#rows].h
            rows[#rows] = nil
            pad = min(14, max(6, floor((room - sum) / #rows)))
        end
    end
    local y = -top
    for _, it in ipairs(rows) do
        it.r:ClearAllPoints()
        it.r:SetPoint("TOPLEFT", p.body, "TOPLEFT", 0, y)
        it.r:SetHeight(it.h + pad)
        it.r:Show()
        y = y - it.h - pad
    end
end

---------------------------------------------------------------------------
-- Prized items: the list and the picked item
---------------------------------------------------------------------------

-- A prized item's art row: the raid's art with the item in its icon tile, the name in its quality's colour, the boss,
-- my standing as a pill at the right of the second line. row.pill (the standing), row.recId.
local function NewItemRow(parent)
    local r = UI:CreateArtRow(parent, { selectable = true, width = K.LIST_W,
        onClick = function(self) if self.recId then LootRulesUI:OpenItem(self.recId) end end })
    r.pill = UI:CreatePill(r.right, 16)
    r.pill:SetBase(S:Color("SURFACE_WINDOW"))
    r.pill:SetPoint("BOTTOMRIGHT", r.right, "BOTTOMRIGHT", 0, 9)
    return r
end

local function FillItemRow(r, rec, selected)
    local P, PU = ns.Prized, ns.PrizedUI
    r.recId = rec.id
    local pl = P:Place(rec.ids[1])
    local text, kind = PU:Standing(rec)
    r:SetData({ art = pl.raidKey or "other", icon = UI:ItemIcon(rec.ids[1]), title = PU:RecName(rec),
        sub = pl.bossName or pl.raidName or "", selected = selected })
    r.title:SetTextColor(UI:QualityColor(ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(rec.ids[1]) or 4))
    r.pill:SetShown(text ~= nil)
    if text then
        r.pill:Set(text, kind)
        -- (the boss' line makes room for the standing; the name has the whole row)
        UI:FitText(r.sub, r.subText or "", (r:GetWidth() or K.LIST_W) - r.textX - r.pill:GetWidth() - 20)
    end
end

-- The list: an intro line, then the items under their raid's caps header (a scroll frame of pooled parts).
local function BuildList(parent)
    local g = CreateFrame("Frame", nil, parent)
    g:SetAllPoints()
    g.intro = UI:Text(g, "sub", nil, { wrap = true, width = K.LIST_W - 4,
        text = "A few drops have stricter rules, set by the Guild Master and the guild council. Pick one to see each "
            .. "rule and how you stand." })
    g.intro:SetPoint("TOPLEFT", g, "TOPLEFT", 2, -2)
    local sf = UI:CreateScrollFrame(g)
    sf:SetPoint("TOPLEFT", g, "TOPLEFT", 0, -K.INTRO_H)
    sf:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, 0)
    local body = CreateFrame("Frame", nil, sf)
    body:SetSize(K.LIST_W, 10)
    sf:SetScrollChild(body)
    g.scroll, g.body, g.cards = sf, body, {}
    g.rows = UI:Pool(body, NewItemRow)
    g.heads = UI:Pool(body, function(p) return UI:CreateSectionHeader(p, "", { style = "caps", width = K.LIST_W }) end)
    return g
end

-- (true when the list has items; the page shows its empty state otherwise)
local function FillList(g, selId)
    local P = ns.Prized
    local items = P and P.GetItems and P:GetItems() or {}
    g.rows:ReleaseAll()
    g.heads:ReleaseAll()
    wipe(g.cards)
    -- (how many items each raid has: its header's count)
    local per, lastRaid = {}, nil
    for _, rec in ipairs(items) do
        local k = P:Place(rec.ids[1]).raidKey or "other"
        per[k] = (per[k] or 0) + 1
    end
    local y = 0
    for i, rec in ipairs(items) do
        local pl = P:Place(rec.ids[1])
        if pl.raidKey ~= lastRaid then
            lastRaid = pl.raidKey
            local h = g.heads:Acquire()
            h:SetTitle(pl.raidName or "Other")
            h:SetCount(per[pl.raidKey or "other"])
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", g.body, "TOPLEFT", 0, -(y + (i > 1 and S.GAP or 0)))
            h:SetPoint("TOPRIGHT", g.body, "TOPRIGHT", 0, -(y + (i > 1 and S.GAP or 0)))
            y = y + (i > 1 and S.GAP or 0) + 18 + 2
        end
        local r = g.rows:Acquire()
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", g.body, "TOPLEFT", 0, -y)
        r:SetWidth(K.LIST_W)
        FillItemRow(r, rec, rec.id == selId)
        g.cards[i] = r
        y = y + S.ROW.art
    end
    g.body:SetHeight(max(10, y + 4))
    return #items > 0
end

-- The picked item: the list + detail layout's detail - the banner (the item's icons, PRIZED ITEM, the name in its
-- quality's colour, the slot, boss and raid, my standing) with Rules / History on its foot, then the open tab.
local function BuildItem(L)
    local f = L.detail
    local b = L.banner
    -- the item's icons in the banner's icon place (one, or the pieces of a set side by side)
    -- TODO(refactor): move into CreatePageBanner (an icon slot that takes several item icons)
    b.iconHolder = CreateFrame("Frame", nil, b)
    b.iconHolder:SetSize(52, 48)
    b.icons = ns.PrizedUI:NewItemIcons(b.iconHolder, 44, 2)
    b.icon = b.iconHolder
    b:Layout()
    f.banner = b
    -- the rules and the history: one scrolling column each (the tabs show one)
    local function column(title)
        local p = CreateFrame("Frame", nil, L.body)
        p:SetAllPoints(L.body)
        p.head = UI:CreateSectionHeader(p, title, { style = "caps" })
        p.head:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
        p.head:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
        local sf = UI:CreateScrollFrame(p)
        sf:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -(18 + 6))
        sf:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
        local body = CreateFrame("Frame", nil, sf)
        body:SetSize(K.DETAIL_W - 16, 10)
        sf:SetScrollChild(body)
        p.scroll, p.body, p.rows = sf, body, {}
        return p
    end
    f.rules = column("Rules")
    f.hist = column("History")
    f.hist.empty = UI:Text(f.hist.body, "sub", nil, { text = "Nobody got it yet." })
    f.hist.empty:SetPoint("TOPLEFT", f.hist.body, "TOPLEFT", 2, -4)
    return f
end

local function FillItem(L, rec)
    local P, PU = ns.Prized, ns.PrizedUI
    local f = L.detail
    local b = f.banner
    local pl = P:Place(rec.ids[1])
    PU:SetItemIcons(b.icons, rec, 14)
    b.iconHolder:SetWidth(#rec.ids > 1 and 78 or 48)
    b:SetArt(pl.raidKey or "other")
    b:SetTitle(PU:RecName(rec))
    b.title:SetTextColor(UI:QualityColor(ns.ItemDB and ns.ItemDB.GetQuality and ns.ItemDB:GetQuality(rec.ids[1]) or 4))
    b:SetSub(PU:SlotText(rec) .. " · " .. (pl.bossName and (pl.bossName .. " · ") or "") .. (pl.raidName or ""))
    local _, kind, long = PU:Standing(rec)
    BannerPill(b, kind, long)
    -- the rules, with how I stand
    local check = P:Check(rec, Me())
    local by = check.by or {}
    local body = f.rules.body
    for _, r in ipairs(f.rules.rows) do r:Hide() end
    local y, n, req, pri = 0, 0, 0, 0
    for _, d in ipairs(P.RULES) do
        local v = rec.r[d.key]
        if v then
            n = n + 1
            local r = f.rules.rows[n]
            if not r then
                r = PU:NewRuleRow(body, K.DETAIL_W - 16)
                f.rules.rows[n] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
            y = y + PU:FillRuleRow(r, rec, d.key, by[d.key])
            r:Show()
            if d.key ~= "vote" then
                if (v.m or "r") == "r" then req = req + 1 else pri = pri + 1 end
            end
        end
    end
    body:SetHeight(max(10, y))
    f.rules.head:SetRight(format("%d required · %d priority", req, pri))
    -- the history
    local hb = f.hist.body
    for _, r in ipairs(f.hist.rows) do r:Hide() end
    y = 0
    local hist = P:GetHistory(rec.id)
    for i, e in ipairs(hist) do
        local r = f.hist.rows[i]
        if not r then
            r = PU:NewHistRow(hb, K.DETAIL_W - 16)
            f.hist.rows[i] = r
        end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", hb, "TOPLEFT", 0, -y)
        y = y + PU:FillHistRow(r, e)
        r:Show()
    end
    f.hist.empty:SetShown(#hist == 0)
    hb:SetHeight(max(10, y))
    f.hist.head:SetCount(#hist > 0 and #hist or nil)
    -- the tabs: the counts, the open one
    L.tabs:SetTabCount("rules", n)
    L.tabs:SetTabCount("history", #hist)
    local tab = state.tab == "history" and "history" or "rules"
    L.tabs:SelectTab(tab)
    f.rules:SetShown(tab == "rules")
    f.hist:SetShown(tab == "history")
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

function LootRulesUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", "DisasterZoneLootRulesPanel", parent)
    p:SetAllPoints(parent)
    panel = p
    -- the toolbar: the two views as its tabs, who set the rules after them; the view under it
    local L = UI:CreateLayout("board", p)
    p.layout = L
    L.toolbar:SetTabs({ { key = "decided", text = "How it's decided" }, { key = "prized", text = "Prized items" },
        selected = "decided" }, function(key) LootRulesUI:SetView(key) end)
    local body = L.body
    p.body = body
    -- How it's decided: the banner, the path (left) and where I stand (right)
    local d = CreateFrame("Frame", nil, body)
    d:SetAllPoints()
    p.decided = d
    d.banner = DecidedBanner(d)
    d.banner:SetPoint("TOPLEFT", d, "TOPLEFT", 0, 0)
    d.banner:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, 0)
    d.path = BuildPath(d)
    d.path:SetPoint("TOPLEFT", d.banner, "BOTTOMLEFT", 0, -K.GAP)
    d.path:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 0, 0)
    d.path:SetWidth(K.LEFT_W)
    d.you = BuildYou(d)
    d.you:SetPoint("TOPLEFT", d.banner, "BOTTOMLEFT", K.RIGHT_X, -K.GAP)
    d.you:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", 0, 0)
    -- Prized items: the list + detail layout under the toolbar
    local PL = UI:CreateLayout("listdetail", body, { toolbar = false, pad = 0, bottom = 0, width = K.W,
        listWidth = K.LIST_W, banner = { size = "hero", kicker = "Prized item", kickerColor = "WARN", title = " " },
        tabs = { { key = "rules", text = "Rules" }, { key = "history", text = "History" }, selected = "rules" },
        onTab = function(key) LootRulesUI:SetTab(key) end })
    p.prized = PL
    p.gallery = BuildList(PL.list)
    p.item = BuildItem(PL)
    -- (MainFrame calls this on every show, the first one too: OnShow set here would miss that one)
    p.OnPanelShown = function() LootRulesUI:Refresh() end
    return p
end

function LootRulesUI:Refresh()
    local p = panel
    if not p or not p:IsVisible() then return end
    local R = Rules()
    local G = ns.Guild
    local L = p.layout
    local by = G and G.GetLootRulesBy and G:GetLootRulesBy()
    L.toolbar:SetText("Set by " .. (by and UI:ColoredName(by, G:GetClass(by)) or "the Guild Master") ..
        " · the same for everyone")
    local decided = state.view ~= "prized"
    L.toolbar:SelectTab(decided and "decided" or "prized")
    p.decided:SetShown(decided)
    p.prized:SetShown(not decided)
    local empty = false
    if decided then
        local d = p.decided
        BannerPill(d.banner, "bis", R.l ~= "r" and "Lists first" or "The roll decides")
        FillPath(d.path, R)
        FillYou(d.you, R)
    else
        -- the picked item (none, or gone: the first one)
        local P = ns.Prized
        local items = P and P.GetItems and P:GetItems() or {}
        local rec = state.item and P and P.Get and P:Get(state.item) or nil
        if not rec then
            rec = items[1]
            state.item = rec and rec.id or nil
        end
        empty = not FillList(p.gallery, state.item)
        if rec then FillItem(p.prized, rec) end
    end
    if empty then
        L:ShowEmpty({ glyph = UI.ICON[IconName("prized")], title = "No prized items yet",
            text = "Every drop follows the guild's rules (How it's decided)." })
    elseif L:IsEmptyShown() then
        L:HideEmpty()
    end
end

function LootRulesUI:RequestRefresh()
    if panel and panel:IsVisible() then ns.Util.Debounce("lootrules-ui", 0.15, function() LootRulesUI:Refresh() end) end
end

-- "decided" | "prized".
function LootRulesUI:SetView(view)
    state.view = view == "prized" and "prized" or "decided"
    if state.view == "decided" then state.item = nil end
    self:Refresh()
end

function LootRulesUI:GetView() return state.view end

-- Opens a prized item on the Prized items view (nil: the first one).
function LootRulesUI:OpenItem(id)
    state.view, state.item = "prized", id
    self:Refresh()
end

-- The prized item shown on the Prized items view (nil on How it's decided, or with no prized items).
function LootRulesUI:GetItem() return state.item end

-- The picked item's tab: "rules" | "history".
function LootRulesUI:SetTab(tab)
    state.tab = tab == "history" and "history" or "rules"
    self:Refresh()
end

function LootRulesUI:IsAvailable()
    return (IsInGuild() or ns.Util.DemoOn()) and true or false
end

function LootRulesUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("lootrules", "Loot rules", 3.51,
            function(parent) return LootRulesUI:CreatePanel(parent) end,
            function() return LootRulesUI:IsAvailable() end, { layout = "listdetail" })
    end
    for _, m in ipairs({ "LOOT_RULES_CHANGED", "PRIZED_UPDATED", "ATTENDANCE_MINE", "RAIDLOG_CHANGED", "LEDGER_UPDATED",
                         "MYLIST_COMMITTED", "MYLIST_CHANGED", "DEMO_TOGGLED", "ITEMINFO_READY", "ROSTER_UPDATED" }) do
        ns:On(m, function() LootRulesUI:RequestRefresh() end)
    end
    ns:RegisterSlash("lootrules", function()
        ns.MainFrame:Open("lootrules")
        LootRulesUI:SetView("decided")
    end, "open Raids > Loot rules: how the loot council's suggestion is made, and the prized items")
end

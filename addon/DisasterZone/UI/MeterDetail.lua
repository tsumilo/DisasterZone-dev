if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MeterDetail.lua", ...) then return end -- DisasterZone: meter breakdown + death recap.
-- The window a click on a meter bar opens: a tool window (UI:CreateWindow + the "tool" layout, its place saved like
-- every window's). The tool banner shows the raid's loading screen, the player's spec in its icon tile, the meter as
-- the kicker, the name in class colour and the spec and fight under it; the tool row has the tabs on the left (and
-- what they hold), the arrows through the players in the mode's order and the fight switch on the right. The body:
-- four stat cards, then the tab:
--   Abilities  every ability with its share; picking one shows how it hit (hits, crits, glancing, misses with their
--              averages, the biggest hit, the share of all) in a card on the right
--   Targets    damage by enemy (the boss's journal picture, a skull for the rest) as art rows (damage modes only)
--   Over time  the player's damage (or healing) per 5 s against the raid's average     (not for Whole raid)
-- In Deaths mode a click opens the death recap instead: health over the last 10 seconds and every hit and heal that
-- landed, newest first, the killing blow marked; the arrows go through the fight's deaths.
-- Built from the shared parts: cards UI:CreateCard, icons UI:CreateIconTile, rows UI:DecorateRow / UI:CreateArtRow,
-- column titles UI:CreateColumnHeader, block headings UI:CreateSectionHeader, empty states UI:CreateEmptyState, text
-- UI:Text on the type scale, colours ns.Style; the charts are My Log's (MyLogKit.Chart).
local addonName, ns = ...

local MD = ns:NewModule("MeterDetail")
local UI = ns.UI
local S = ns.Style

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local pairs, ipairs, tostring = pairs, ipairs, tostring
local strformat = string.format
local tsort = table.sort

local W, H = 780, 620                          -- the window; its content is W - 10 wide
local INNER_W = W - 10 - 2 * S.PAD             -- the tool layout's body width (750)
local BODY_H = H - (ns.UI.WIN_HEAD + 6) - S.PAD - S.BANNER.tool - S.GAP - (ns.UI.LAYOUT and ns.UI.LAYOUT.ROW_H or 26)
    - S.GAP - S.PAD                           -- (the body's height before the first layout: the charts' fallback)
local CARD_H = 58
local LIST_Y = CARD_H + S.GAP                  -- the list / chart area under the cards
local ROW_H, EROW_H = S.ROW.rich, 30
local DETAIL_W = 300
local LIST_W = INNER_W - DETAIL_W - S.GAP - 12

local Meter, Kit
local K = ns.MeterWindow.K
local frame
local St = { sel = "cur", guid = nil, mode = "damage", tab = "abilities", ab = nil, view = "player", death = nil }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- "1 hit", "3 hits" (word = the plural)
local function Count(n, word)
    if n == 1 then word = word:gsub("es$", ""):gsub("s$", "") end
    return K.Int(n) .. " " .. word
end

local function FightText(seg)
    if not seg then return "" end
    local parts = { Meter:SegName(seg) }
    if seg.kind == "boss" and not seg.live then
        parts[#parts + 1] = seg.kill and S:Wrap("OK", "Kill")
            or S:Wrap("BAD", "Wipe" .. (seg.pct and strformat(" %d%%", floor(seg.pct + 0.5)) or ""))
    elseif seg.live then
        parts[#parts + 1] = S:Wrap("LIVE", "Live")
    end
    parts[#parts + 1] = K.Clock(Meter:Duration(seg))
    return table.concat(parts, " · ")
end

local function JournalArt(name)
    local key = name and ns.MyLog and ns.MyLog.BossDataKey and ns.MyLog:BossDataKey(name)
    return key and ns.Data and ns.Data.BossJournal and ns.Data.BossJournal[key]
end

-- The mode's rows (players with something to show), for the arrows and the rank.
local function Ranked(seg, mode)
    local m = (mode == "dps") and "damage" or mode
    if m == "deaths" then m = "damage" end
    local rows = Meter:Rows(seg, m)
    return rows, m
end

-- The meter's name for the banner's kicker.
local function ModeLabel(mode)
    local info = Meter.MODE and Meter.MODE[mode]
    return info and info.label or ""
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

-- A stat card: the shared card with an icon tile, a big number (a note beside it: the rank), a caption.
local function NewStatCard(parent)
    local c = UI:CreateCard(parent, { tone = "card", height = CARD_H })
    c.icon = UI:CreateIconTile(c, 34)
    c.icon:SetPoint("LEFT", c, "LEFT", 12, 0)
    c.num = UI:Text(c, "hero", { 1, 1, 1 }, { shadow = true })
    c.num:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 11, 1)
    c.extra = UI:Text(c, "title", "OK", { shadow = true })
    c.extra:SetPoint("BOTTOMLEFT", c.num, "BOTTOMRIGHT", 6, 1)
    c.lab = UI:Text(c, "body", "SUB")
    c.lab:SetPoint("BOTTOMLEFT", c.icon, "BOTTOMRIGHT", 11, 0)
    return c
end

-- The tool row's right side: the arrows through the players (or deaths) with "10th of 19" between them, then the
-- fight switch (the row's main control, at the right edge, S.BTN_H high).
local function NewPager(bar)
    local prev = UI:CreateArrowButton(bar, false, S.BTN_H, S.BTN_H, function() MD:Step(-1) end)
    local step = CreateFrame("Frame", nil, bar)
    step:SetSize(60, S.BTN_H)
    step.text = UI:Text(step, "body", "TEXT", { justify = "CENTER" })
    step.text:SetPoint("CENTER")
    function step:SetText(t)
        self.text:SetText(t or "")
        self:SetWidth(max(20, floor(UI:TextWidth(self.text) + 8)))
        if bar.LayoutRight then bar:LayoutRight() end
    end
    function step:GetText() return self.text:GetText() end
    local nxt = UI:CreateArrowButton(bar, true, S.BTN_H, S.BTN_H, function() MD:Step(1) end)
    UI:AttachTooltip(prev, "Previous", nil, { anchor = "ANCHOR_TOP" })
    UI:AttachTooltip(nxt, "Next", nil, { anchor = "ANCHOR_TOP" })
    local fight = UI:CreateSleekMenuButton(bar, "Void Reaver", 150, function(root) MD:FightMenu(root) end, S.BTN_H)
    return prev, step, nxt, fight
end

local function Build()
    Kit = ns.MyLogKit
    frame = UI:CreateWindow("DisasterZoneMeterDetail", "Breakdown", W, H)
    local L = UI:CreateLayout("tool", frame.content, { width = W - 10, toolbar = true,
        banner = { size = "tool", art = { "Interface\\Glues\\LoadingScreens\\LoadScreenOutland", 0, 1, 0.3, 0.42 },
                   icon = 134400, title = "?", kicker = "" } })
    frame.layout = L

    -- banner (the drag handle too: the window moves by it, its place saved)
    local banner = L.banner
    banner:EnableMouse(true)
    banner:RegisterForDrag("LeftButton")
    banner:SetScript("OnDragStart", function() frame:StartMoving() end)
    banner:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        UI:SavePosition(frame)
    end)
    banner.name = banner.title
    frame.banner = banner

    -- tool row: the tabs (what they hold after them), the pager and the fight switch
    local bar = L.toolbar
    bar:SetTabs({ { key = "abilities", text = "Abilities" }, { key = "targets", text = "Targets" },
        { key = "time", text = "Over time" } }, function(key) St.tab = key; MD:Draw() end)
    banner.prev, banner.step, banner.next, banner.fight = NewPager(bar)
    bar:SetFilters({ banner.prev, banner.step, banner.next, banner.fight })
    frame.tabs = bar

    local body = L.body
    frame.body = body

    -- stat cards
    frame.cards = {}
    local cw = (INNER_W - S.GAP * 3) / 4
    for i = 1, 4 do
        local c = NewStatCard(body)
        c:SetWidth(cw)
        c:SetPoint("TOPLEFT", body, "TOPLEFT", (i - 1) * (cw + S.GAP), 0)
        frame.cards[i] = c
    end

    -- the list (scrolling), the detail card, the chart
    local sf = UI:CreateScrollFrame(body, nil)
    sf:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -LIST_Y)
    sf:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    sf:SetWidth(LIST_W)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(LIST_W, 10)
    sf:SetScrollChild(child)
    frame.list, frame.listChild, frame.listW = sf, child, LIST_W
    frame.rows, frame.trows = {}, {}

    local det = UI:CreateCard(body, { tone = "card", pad = 16 })
    det:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -LIST_Y)
    det:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    det:SetWidth(DETAIL_W)
    det.icon = UI:CreateIconTile(det, 40)
    det.icon:SetPoint("TOPLEFT", det, "TOPLEFT", 16, -14)
    det.name = UI:Text(det, "page", { 1, 1, 1 }, { width = DETAIL_W - 90 })
    det.name:SetPoint("TOPLEFT", det.icon, "TOPRIGHT", 11, -2)
    det.sub = UI:Text(det, "body", "SUB")
    det.sub:SetPoint("TOPLEFT", det.name, "BOTTOMLEFT", 0, -4)
    det.dist = CreateFrame("Frame", nil, det)
    det.dist:SetPoint("TOPLEFT", det, "TOPLEFT", 16, -72)
    det.dist:SetPoint("TOPRIGHT", det, "TOPRIGHT", -16, -72)
    det.dist:SetHeight(10)
    det.parts = {}
    det.cols = UI:CreateColumnHeader(det, 18)
    det.cols:SetPoint("TOPLEFT", det, "TOPLEFT", 0, -92)
    det.cols:SetPoint("TOPRIGHT", det, "TOPRIGHT", 0, -92)
    det.head = {
        det.cols:AddColumn("How it hit", 34, 60),
        det.cols:AddColumn("Count", 100, 50, { justify = "RIGHT" }),
        det.cols:AddColumn("Average", 150, 58, { justify = "RIGHT" }),
        det.cols:AddColumn("Share", 210, 58, { justify = "RIGHT" }),
    }
    det.lines = {}
    for i = 1, 5 do
        local y = -116 - (i - 1) * 21
        local ln = { key = UI:Fill(det, "TEXT", "ARTWORK") }
        ln.key:ClearAllPoints()
        ln.key:SetSize(9, 9)
        ln.key:SetPoint("TOPLEFT", det, "TOPLEFT", 18, y - 3)
        ln.name = UI:Text(det, "body", "TEXT")
        ln.name:SetPoint("TOPLEFT", det, "TOPLEFT", 34, y)
        ln.n = UI:Text(det, "body", "TEXT", { justify = "RIGHT" })
        ln.n:SetPoint("TOPRIGHT", det, "TOPLEFT", 150, y)
        ln.avg = UI:Text(det, "body", "TEXT", { justify = "RIGHT" })
        ln.avg:SetPoint("TOPRIGHT", det, "TOPLEFT", 208, y)
        ln.share = UI:Text(det, "body", "TEXT", { justify = "RIGHT" })
        ln.share:SetPoint("TOPRIGHT", det, "TOPLEFT", 268, y)
        det.lines[i] = ln
    end
    det.facts = {}
    local fw = (DETAIL_W - 32 - S.GAP) / 2
    for i = 1, 4 do
        local f = UI:CreateCard(det, { tone = "inset", width = fw, height = 46 })
        local col, rw = (i - 1) % 2, floor((i - 1) / 2)
        f:SetPoint("BOTTOMLEFT", det, "BOTTOMLEFT", 16 + col * (fw + S.GAP), 16 + (1 - rw) * 54)
        f.num = UI:Text(f, "page", { 1, 1, 1 })
        f.num:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -7)
        f.lab = UI:Text(f, "small", "SUB")
        f.lab:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 7)
        det.facts[i] = f
    end
    frame.det = det

    local chart = Kit.Chart(body)
    chart:SetPoint("TOPLEFT", body, "TOPLEFT", 46, -(LIST_Y + 34))
    chart:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 26)
    chart.fallback = { INNER_W - 46, BODY_H - LIST_Y - 34 - 26 }
    frame.chart = chart
    frame.legend = UI:Text(body, "body", "SUB")
    frame.legend:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(LIST_Y + 8))
    frame.yLabs, frame.xLabs = {}, {}
    for i = 1, 5 do
        frame.yLabs[i] = UI:Text(body, "small", "SUB", { justify = "RIGHT" })
        frame.xLabs[i] = UI:Text(body, "small", "SUB")
    end

    -- death recap: the health chart, then every event
    frame.deathChart = Kit.Chart(body)
    frame.deathChart:SetPoint("TOPLEFT", body, "TOPLEFT", 36, -18)
    frame.deathChart:SetPoint("TOPRIGHT", body, "TOPRIGHT", -4, -18)
    frame.deathChart:SetHeight(128)
    frame.deathChart.fallback = { INNER_W - 40, 128 }
    frame.deathLabs = {}
    for i = 1, 6 do frame.deathLabs[i] = UI:Text(body, "small", "SUB") end
    frame.deathHp = UI:Text(body, "small", "SUB", { justify = "RIGHT" })
    frame.deathHp:SetPoint("BOTTOMRIGHT", frame.deathChart, "TOPRIGHT", 0, 4)
    frame.evHead = UI:CreateSectionHeader(body, "Every hit and heal, newest first", { style = "caps" })
    frame.evHead:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -172)
    frame.evHead:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -172)
    local esf = UI:CreateScrollFrame(body, nil)
    esf:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -194)
    esf:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -10, 0)
    local echild = CreateFrame("Frame", nil, esf)
    echild:SetSize(INNER_W - 10, 10)
    esf:SetScrollChild(echild)
    frame.events, frame.eventsChild, frame.evRows = esf, echild, {}

    -- the empty state of the list area (the cards stay above it)
    frame.empty = UI:CreateEmptyState(body, { compact = true })
    frame.empty:SetPoint("TOP", body, "TOP", 0, -(LIST_Y + 40))
    frame.empty:SetBoxWidth(420)
    frame.empty:Hide()
    frame:Hide()
end

-- The empty state with a title (nil: hidden); the meter's icon in it.
local function ShowEmpty(text)
    if not text then frame.empty:Hide() return end
    local info = Meter.MODE and Meter.MODE[St.mode]
    frame.empty:SetContent({ icon = info and info.icon or 134939, title = text })
    frame.empty:Show()
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

-- An ability row (also a block's heading in Interrupts / Dispels): the shared row looks (hover, the picked one), an
-- icon tile, name and line under it, a gold bar of its share, the amount and its share on the right.
local function AbilityRow(i)
    local r = frame.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, frame.listChild)
    r:SetHeight(ROW_H)
    UI:DecorateRow(r, { hover = true, selectable = true })
    r.icon = UI:CreateIconTile(r, 28)
    r.icon:SetPoint("LEFT", r, "LEFT", 8, 0)
    r.name = UI:Text(r, "emph", { 1, 1, 1 })
    r.sub = UI:Text(r, "small", "SUB")
    r.amount = UI:Text(r, "title", { 1, 1, 1 }, { justify = "RIGHT" })
    r.amount:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -5)
    r.pct = UI:Text(r, "small", "SUB", { justify = "RIGHT" })
    r.pct:SetPoint("TOPRIGHT", r.amount, "BOTTOMRIGHT", 0, -2)
    r.track = UI:Fill(r, "EDGE_QUIET", "ARTWORK")
    r.track:ClearAllPoints()
    r.track:SetHeight(6)
    r.fill = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.fill:SetHeight(6)
    UI:Gradient(r.fill, "HORIZONTAL", "GOLD_DEEP", "GOLD")
    r.fill:SetPoint("LEFT", r.track, "LEFT")
    r.head = UI:CreateSectionHeader(r, "", { style = "title" })
    r.head:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 2)
    r.head:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 2)
    r.head:Hide()
    r:SetScript("OnClick", function(self) if self.key ~= nil then St.ab = self.key; MD:Draw() end end)
    frame.rows[i] = r
    return r
end

-- A row back to an ability row (a heading row before: its texts and bar come back).
local function AsAbility(r)
    r.head:Hide()
    r.name:Show(); r.sub:Show(); r.amount:Show(); r.pct:Show(); r.icon:Show(); r.track:Show(); r.fill:Show()
    r:EnableMouse(true)
    r:SetHeight(ROW_H)
end

local function PlaceRowText(r, x, w)
    r.name:ClearAllPoints()
    r.name:SetPoint("TOPLEFT", r, "TOPLEFT", x, -6)
    r.name:SetWidth(w)
    r.sub:ClearAllPoints()
    r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
    r.sub:SetWidth(w)
    r.track:ClearAllPoints()
    r.track:SetPoint("LEFT", r, "LEFT", x + w + 12, 0)
    r.track:SetPoint("RIGHT", r, "RIGHT", -96, 0)
end

-- A target: the shared art row (the boss's journal picture, a skull for the rest), its share as a bar.
local SKULL_ART = function(tex)
    tex:SetTexture(K.SKULL)
    tex:SetTexCoord(-0.6, 1.6, -0.1, 1.1)
    tex:SetVertexColor(0.55, 0.55, 0.58)
end
local function TargetRow(i)
    local r = frame.trows[i]
    if r then return r end
    r = UI:CreateArtRow(frame.listChild, { rule = true })
    r.track = UI:Fill(r, "EDGE_QUIET", "ARTWORK")
    r.track:ClearAllPoints()
    r.track:SetHeight(6)
    r.fill = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.fill:SetHeight(6)
    UI:Gradient(r.fill, "HORIZONTAL", "GOLD_DEEP", "GOLD")
    r.fill:SetPoint("LEFT", r.track, "LEFT")
    r.amount = UI:Text(r, "title", { 1, 1, 1 }, { justify = "RIGHT" })
    r.amount:SetPoint("TOPRIGHT", r, "TOPRIGHT", -10, -9)
    r.pct = UI:Text(r, "small", "SUB", { justify = "RIGHT" })
    r.pct:SetPoint("TOPRIGHT", r.amount, "BOTTOMRIGHT", 0, -2)
    frame.trows[i] = r
    return r
end

-- A death recap line: the shared stripes, the killing blow in the bad colour with its bar.
local function EventRow(i)
    local r = frame.evRows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, frame.eventsChild)
    r:SetHeight(EROW_H)
    UI:DecorateRow(r, { hover = false, stripe = true })
    local bad = S.C.BAD
    r.kill = UI:Fill(r, { bad[1], bad[2], bad[3], 0.09 }, "BACKGROUND", 2)
    r.mark = UI:Rule(r, { vertical = true, color = "BAD", size = 2, layer = "ARTWORK" })
    r.t = UI:Text(r, "body", "SUB", { justify = "RIGHT", font = K.NARROW })
    r.t:SetPoint("RIGHT", r, "LEFT", 58, 0)
    r.icon = UI:CreateIconTile(r, 20)
    r.icon:SetPoint("LEFT", r, "LEFT", 68, 0)
    r.what = UI:Text(r, "body", { 1, 1, 1 }, { width = INNER_W - 10 - 68 - 30 - 220 })
    r.what:SetPoint("LEFT", r.icon, "RIGHT", 10, 0)
    r.amount = UI:Text(r, "emph", "BAD", { justify = "RIGHT" })
    r.amount:SetPoint("RIGHT", r, "RIGHT", -120, 0)
    r.hpTrack = UI:Fill(r, "EDGE_QUIET", "ARTWORK")
    r.hpTrack:ClearAllPoints()
    r.hpTrack:SetSize(64, 5)
    r.hpTrack:SetPoint("RIGHT", r, "RIGHT", -44, 0)
    r.hpFill = r:CreateTexture(nil, "ARTWORK", nil, 1)
    r.hpFill:SetTexture(K.WHITE)
    r.hpFill:SetHeight(5)
    r.hpFill:SetPoint("LEFT", r.hpTrack, "LEFT")
    r.hp = UI:Text(r, "small", "SUB", { justify = "RIGHT" })
    r.hp:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    frame.evRows[i] = r
    return r
end

---------------------------------------------------------------------------
-- Drawing a player
---------------------------------------------------------------------------

-- The banner: the raid's loading screen (the Outland one outside a raid), the player's spec, the name in class colour.
local OUTLAND = { "Interface\\Glues\\LoadingScreens\\LoadScreenOutland", 0, 1, 0.3, 0.3 + S.BANNER.tool / W * 0.75 }
local function SetBanner(seg, a, kicker)
    local b = frame.banner
    local iid = seg and seg.iid
    local raid = iid and ns.ItemDB and ns.ItemDB.GetRaidByInstance and ns.ItemDB:GetRaidByInstance(iid)
    b:SetArt(raid and iid or OUTLAND)
    local spec = a and K.SpecIcon(a.c, a.s)
    local c = not spec and a and a.c and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[a.c]
    if spec then b:SetIcon(spec)
    elseif c then b:SetIcon({ "Interface\\WorldStateFrame\\Icons-Classes", c[1], c[2], c[3], c[4] })
    else b:SetIcon(134400) end
    b:SetKicker(kicker)
    b:SetTitle(a and a.n or "?")
    if a and a.c then b.title:SetTextColor(K.ClassColor(a.c)) else b.title:SetTextColor(1, 1, 1) end
end

-- A card's texts always fit inside it, whatever the class or the numbers: the room right of the icon, and a text
-- that is still too wide steps down the type scale instead of running out of the card.
local NUM_STEPS = { "hero", "page", "title", "emph", "body" }
local LAB_STEPS = { "body", "small", "caps" }
local function Fit(fs, steps, room, color)
    for i, st in ipairs(steps) do
        UI:SetTextStyle(fs, st, color)
        if UI:TextWidth(fs) <= room or i == #steps then return end
    end
end

local function SetCard(c, icon, num, extra, lab)
    c.icon:Set(icon)
    c.num:SetText(num)
    c.extra:SetText(extra or "")
    c.lab:SetText(lab)
    local w = c:GetWidth() or 0
    if w <= 0 then w = (INNER_W - S.GAP * 3) / 4 end
    local room = w - 12 - 34 - 11 - 10                       -- the icon, its gaps and the card's right padding
    local extraW = (extra and extra ~= "") and UI:TextWidth(c.extra) + 6 or 0
    Fit(c.num, NUM_STEPS, room - extraW, { 1, 1, 1 })
    Fit(c.lab, LAB_STEPS, room, "SUB")
end

-- The ability list of a mode: { key, a (amount), n, sub, s (the stat) }
local function Abilities(a, mode, dur)
    local list = {}
    if mode == "healing" then
        for k, s in pairs(a.hs or {}) do
            local tot = s.a + (s.oh or 0)
            local sub
            if s.sh then sub = Count(s.n, "absorbs")
            else sub = strformat("%s · %d%% over", Count(s.n, "heals"), tot > 0 and floor((s.oh or 0) / tot * 100 + 0.5) or 0) end
            list[#list + 1] = { key = k, a = s.a, sub = sub, s = s }
        end
    elseif mode == "taken" then
        for k, s in pairs(a.ts or {}) do
            list[#list + 1] = { key = k, a = s.a, sub = Count(s.n, "hits") .. (s.src and (" · " .. s.src) or ""), s = s }
        end
    else
        for k, s in pairs(a.sp or {}) do
            local miss = 0
            for _, n in pairs(s.m or {}) do miss = miss + n end
            local unit = (k == 0 or k == "p0") and "swings" or "hits"
            local crit = s.n > 0 and s.c / s.n * 100 or 0
            list[#list + 1] = { key = k, a = s.a, s = s,
                sub = strformat("%s · %s", Count(s.n + miss, unit),
                    s.nc and "can't crit" or (s.c > 0 and strformat("%.1f%% crit", crit) or "no crits")) }
        end
    end
    tsort(list, function(x, y)
        if x.a ~= y.a then return x.a > y.a end
        return tostring(x.key) < tostring(y.key)
    end)
    return list
end

local HIT_COLORS = { hit = { 0.85, 0.76, 0.48 }, crit = S.C.GOLD, glance = { 0.56, 0.48, 0.27 },
                     miss = { 0.35, 0.35, 0.39 } }

local function DrawDetail(e, total, mode, dur, a)
    local det = frame.det
    if not e then det:Hide() return end
    det:Show()
    local s = e.s
    det.icon:Set(K.SpellIcon(e.key, a))
    det.name:SetText(K.SpellName(e.key, a.pn))
    local per = mode == "taken" and dur or MD.act or dur
    det.sub:SetText(strformat("%s · %s per second", K.Fmt(e.a), K.Int(e.a / per)))
    local parts = {}
    if mode == "taken" then
        parts[#parts + 1] = { "Hit", s.n, s.n > 0 and s.a / s.n or 0, HIT_COLORS.hit }
    else
        local miss = 0
        for _, n in pairs(s.m or {}) do miss = miss + n end
        local crits, glances = s.c or 0, s.g or 0
        local hits = max(0, s.n - crits - glances)
        local ca, ga = s.ca or 0, s.ga or 0
        local ha = max(0, s.a - ca - ga)
        if mode == "healing" then ha = s.a - (ca) end
        parts[#parts + 1] = { "Hit", hits, hits > 0 and ha / hits or 0, HIT_COLORS.hit }
        if crits > 0 then parts[#parts + 1] = { "Crit", crits, ca > 0 and ca / crits or (s.a / max(1, s.n)) * 1.5, HIT_COLORS.crit } end
        if glances > 0 then parts[#parts + 1] = { "Glancing", glances, ga / glances, HIT_COLORS.glance } end
        for mt, n in pairs(s.m or {}) do
            parts[#parts + 1] = { mt:sub(1, 1) .. mt:sub(2):lower(), n, nil, HIT_COLORS.miss }
        end
    end
    local n = 0
    for _, p in ipairs(parts) do n = n + p[2] end
    if n <= 0 then n = 1 end
    -- the distribution bar
    UI:HideFrom(det.parts, 1)
    local x = 0
    local bw = DETAIL_W - 32
    for i, p in ipairs(parts) do
        local t = det.parts[i]
        if not t then
            t = det.dist:CreateTexture(nil, "ARTWORK")
            t:SetTexture(K.WHITE)
            det.parts[i] = t
        end
        local w = max(1, bw * p[2] / n - (i < #parts and 1 or 0))
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", det.dist, "TOPLEFT", x, 0)
        t:SetSize(w, 10)
        t:SetVertexColor(p[4][1], p[4][2], p[4][3], 1)
        t:Show()
        x = x + bw * p[2] / n
    end
    for i, ln in ipairs(det.lines) do
        local p = parts[i]
        local on = p ~= nil
        for _, f in ipairs({ ln.key, ln.name, ln.n, ln.avg, ln.share }) do f:SetShown(on) end
        if on then
            ln.key:SetColorTexture(p[4][1], p[4][2], p[4][3], 1)
            ln.name:SetText(p[1])
            ln.n:SetText(K.Int(p[2]))
            ln.avg:SetText(p[3] and K.Int(p[3]) or "–")
            ln.share:SetText(strformat("%.1f%%", p[2] / n * 100))
        end
    end
    local f = det.facts
    local hits = max(1, s.n)
    if mode == "healing" then
        local tot = s.a + (s.oh or 0)
        f[1].num:SetText(K.Int(s.mx or 0)); f[1].lab:SetText("Biggest heal")
        f[2].num:SetText(strformat("%d%%", tot > 0 and floor((s.oh or 0) / tot * 100 + 0.5) or 0)); f[2].lab:SetText("Overhealing")
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average heal")
    elseif mode == "taken" then
        f[1].num:SetText(K.Int(s.n)); f[1].lab:SetText("Hits")
        f[2].num:SetText(strformat("%.1f s", dur / hits)); f[2].lab:SetText("Between hits")
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average hit")
    else
        f[1].num:SetText(K.Int(s.mx or 0)); f[1].lab:SetText("Biggest hit")
        local unit = (e.key == 0 or e.key == "p0") and "swings" or "hits"
        f[2].num:SetText(strformat("%.1f s", dur / hits)); f[2].lab:SetText("Between " .. unit)
        f[3].num:SetText(K.Int(s.a / hits)); f[3].lab:SetText("Average per " .. unit:gsub("s$", ""))
    end
    f[4].num:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
    f[4].lab:SetText(mode == "healing" and "Of all healing" or mode == "taken" and "Of all taken" or "Of all damage")
end

local function DrawAbilities(a, mode, dur)
    local list = Abilities(a, mode, dur)
    local total = 0
    for _, e in ipairs(list) do total = total + e.a end
    local sel
    for _, e in ipairs(list) do if e.key == St.ab then sel = e end end
    if not sel then sel = list[1]; St.ab = sel and sel.key end
    local top = list[1] and list[1].a or 1
    local textW = 190
    for i, e in ipairs(list) do
        local r = AbilityRow(i)
        AsAbility(r)
        r.key = e.key
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -(i - 1) * ROW_H)
        r:SetWidth(frame.listW)
        r.icon:Set(K.SpellIcon(e.key, a))
        r.name:SetText(K.SpellName(e.key, a.pn))
        r.sub:SetText(e.sub)
        PlaceRowText(r, 46, textW)
        r.amount:SetText(K.Fmt(e.a))
        r.pct:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
        local tw = max(10, frame.listW - 46 - textW - 12 - 96)
        r.fill:SetWidth(max(1, tw * e.a / top))
        r:SetSelected(e == sel)
        r:Show()
    end
    UI:HideFrom(frame.rows, #list + 1)
    UI:HideFrom(frame.trows, 1)
    frame.listChild:SetHeight(max(10, #list * ROW_H))
    DrawDetail(sel, total, mode, dur, a)
    local hits = 0
    for _, e in ipairs(list) do hits = hits + (e.s.n or 0) end
    frame.tabs:SetText(strformat("%d %s · %s %s", #list, #list == 1 and "ability" or "abilities", K.Int(hits),
        mode == "healing" and "heals" or "hits"))
    ShowEmpty(#list == 0 and "Nothing to break down in this fight." or nil)
end

local function DrawTargets(a)
    local list = {}
    local total = 0
    for name, v in pairs(a.tg or {}) do list[#list + 1] = { name = name, a = v }; total = total + v end
    tsort(list, function(x, y) return x.a > y.a end)
    local top = list[1] and list[1].a or 1
    local rw = INNER_W - 12
    local textW = 230
    for i, e in ipairs(list) do
        local r = TargetRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -(i - 1) * S.ROW.art)
        r:SetWidth(rw)
        local fid = JournalArt(e.name)
        r:SetData({ art = fid or SKULL_ART, title = e.name, sub = fid and "boss" or nil })
        if fid then r.art.tex:SetVertexColor(1, 1, 1) end
        r:SetRightWidth(rw - r.textX - textW)
        r.amount:SetText(K.Fmt(e.a))
        r.pct:SetText(strformat("%.1f%%", total > 0 and e.a / total * 100 or 0))
        r.track:ClearAllPoints()
        r.track:SetPoint("LEFT", r, "LEFT", r.textX + textW + 12, 0)
        r.track:SetPoint("RIGHT", r, "RIGHT", -110, 0)
        local tw = max(10, rw - r.textX - textW - 12 - 110)
        r.fill:SetWidth(max(1, tw * e.a / top))
        r:Show()
    end
    UI:HideFrom(frame.trows, #list + 1)
    UI:HideFrom(frame.rows, 1)
    frame.listChild:SetHeight(max(10, #list * S.ROW.art))
    frame.tabs:SetText(strformat("%d %s", #list, #list == 1 and "target" or "targets"))
    ShowEmpty(#list == 0 and "No targets in this fight." or nil)
end

-- Points sit at each 5 s step's middle; the line runs edge to edge (the first step's value from 0:00, the last one's to
-- the end), so the chart's first and last seconds are not left empty.
local function EdgeToEdge(pts, dur)
    if #pts == 0 then return pts end
    if pts[1][1] > 0 then table.insert(pts, 1, { 0, pts[1][2] }) end
    if pts[#pts][1] < dur then pts[#pts + 1] = { dur, pts[#pts][2] } end
    return pts
end

-- The fight switch as wide as its name (within limits).
local function SetFightChip(text)
    local f = frame.banner.fight
    f:SetText(text or "")
    local fs = f.GetFontString and f:GetFontString()
    local w = fs and fs:GetStringWidth() or 0
    f:SetWidth(min(260, max(120, w + 46)))
    frame.tabs:LayoutRight()
end

-- The chart's time labels under it.
local function TimeLabels(dur)
    local ch = frame.chart
    local chW = (ch:GetWidth() or 0) > 0 and ch:GetWidth() or ch.fallback[1]
    for i = 1, 5 do
        local xl = frame.xLabs[i]
        xl:ClearAllPoints()
        xl:SetPoint("TOP", ch, "BOTTOMLEFT", chW * (i - 1) / 4, -6)
        xl:SetText(K.Clock(dur * (i - 1) / 4))
        xl:Show()
    end
end

local function DrawTime(seg, a, mode, dur)
    local field = mode == "healing" and "hl" or "tl"
    local own = a[field] or {}
    local nb = max(1, math.ceil(dur / Meter.BUCKET))
    local pts, avg = {}, {}
    local others = {}
    for _, o in pairs(seg.actors) do
        if (mode == "healing" and (o.h or 0) > 0) or (mode ~= "healing" and (o.d or 0) > 0) then others[#others + 1] = o end
    end
    local hi = 1
    for b = 1, nb do
        local x = min(dur, (b - 0.5) * Meter.BUCKET)
        local span = min(Meter.BUCKET, dur - (b - 1) * Meter.BUCKET)
        if span <= 0 then span = Meter.BUCKET end
        local v = (own[b] or 0) / span
        local s = 0
        for _, o in ipairs(others) do s = s + ((o[field] or {})[b] or 0) end
        local m = #others > 0 and s / #others / span or 0
        pts[#pts + 1] = { x, v }
        avg[#avg + 1] = { x, m }
        hi = max(hi, v, m)
    end
    EdgeToEdge(pts, dur)
    EdgeToEdge(avg, dur)
    local step = Kit.NiceStep and Kit.NiceStep(hi * 1.1, 4) or hi / 4
    local y1 = step * math.ceil(hi * 1.1 / step)
    frame.chart:SetData({
        x0 = 0, x1 = dur, y1 = y1, grid = true,
        series = {
            { points = pts, color = Kit.C.gold, width = 1.8, fill = true, fillAlpha = 0.16, smooth = true, glow = true, endDot = true },
            { points = avg, color = S.C.SUB, width = 1.2, alpha = 0.6, smooth = true },
        },
        hover = function(x)
            local yp, ya = Kit.YAt(pts, x), Kit.YAt(avg, x)
            return { { K.Clock(x), Kit.C.mute }, { strformat("%s %s", K.Int(yp or 0), mode == "healing" and "HPS" or "DPS"), Kit.C.gold },
                     { strformat("%s raid average", K.Int(ya or 0)), Kit.C.mute } }
        end,
    })
    local metric = mode == "healing" and "healing per second" or "damage per second"
    frame.legend:SetText(strformat("%s %s's %s     %s the raid's average", S:Wrap("GOLD", "—"), a.n or "?", metric,
        S:Wrap("SUB", "—")))
    TimeLabels(dur)
    frame.tabs:SetText("5-second steps")
end

-- A list's scroll bar only when the list is taller than its room.
local function FitScroll(sf, contentH, fallbackH)
    local h = sf:GetHeight() or 0
    if h <= 0 then h = fallbackH end
    sf.ScrollBar:SetShown(sf:IsShown() and contentH > h + 1)
    if contentH <= h + 1 then sf:SetVerticalScroll(0) end
end

-- Interrupts / Dispels: the spells they used, then what those cut or removed (a section header over each block).
local function DrawUses(a, mode)
    local by, cut = mode == "kicks" and a.ks or a.ds, mode == "kicks" and a.kx or a.dx
    local verb = mode == "kicks" and "interrupted" or "removed"
    local blocks = {
        { "Spells they used", by, "used" },
        { mode == "kicks" and "What they interrupted" or "What they removed", cut, verb },
    }
    local i, y = 0, 0
    local listW = INNER_W - 12
    local total = (mode == "kicks" and a.k or a.dp) or 0
    for _, blk in ipairs(blocks) do
        local list = {}
        for k, n in pairs(blk[2] or {}) do list[#list + 1] = { key = k, n = n } end
        tsort(list, function(x, z) if x.n ~= z.n then return x.n > z.n end return tostring(x.key) < tostring(z.key) end)
        if #list > 0 then
            i = i + 1
            local hr = AbilityRow(i)
            hr.key = nil
            hr:ClearAllPoints()
            hr:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -y)
            hr:SetWidth(listW)
            hr:SetHeight(30)
            hr.icon:Hide(); hr.track:Hide(); hr.fill:Hide()
            hr.amount:Hide(); hr.pct:Hide(); hr.sub:Hide(); hr.name:Hide()
            hr.name:SetText(blk[1])                -- (what the heading says, for whoever reads the rows)
            hr.head:SetTitle(blk[1])
            hr.head:SetCount(#list)
            hr.head:Show()
            hr:SetSelected(false)
            hr:EnableMouse(false)
            hr:Show()
            y = y + 30
            local top = list[1].n
            for _, e in ipairs(list) do
                i = i + 1
                local r = AbilityRow(i)
                AsAbility(r)
                r.key = nil
                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", frame.listChild, "TOPLEFT", 0, -y)
                r:SetWidth(listW)
                r.icon:Set(K.SpellIcon(e.key))
                r.name:SetText(K.SpellName(e.key))
                r.sub:SetText(strformat("%s %s", blk[3], e.n == 1 and "once" or (K.Int(e.n) .. " times")))
                PlaceRowText(r, 46, 260)
                r.amount:SetText(K.Int(e.n))
                r.pct:SetText(total > 0 and strformat("%.0f%%", e.n / total * 100) or "")
                local tw = max(10, listW - 46 - 260 - 12 - 96)
                r.fill:SetWidth(max(1, tw * e.n / top))
                r:SetSelected(false)
                r:Show()
                y = y + ROW_H
            end
        end
    end
    UI:HideFrom(frame.rows, i + 1)
    UI:HideFrom(frame.trows, 1)
    frame.listChild:SetHeight(max(10, y))
    ShowEmpty(i == 0 and (mode == "kicks" and "No interrupts in this fight." or "No dispels in this fight.") or nil)
    return y
end

-- Active time: their output per 5 s with the steps they did nothing in shaded.
local function DrawActive(seg, a, dur)
    local field = ((a.h or 0) > (a.d or 0)) and "hl" or "tl"
    local own = a[field] or {}
    local nb = max(1, math.ceil(dur / Meter.BUCKET))
    local pts, bands, hi = {}, {}, 1
    for bk = 1, nb do
        local x0 = (bk - 1) * Meter.BUCKET
        local span = min(Meter.BUCKET, dur - x0)
        if span <= 0 then span = Meter.BUCKET end
        local v = (own[bk] or 0) / span
        pts[#pts + 1] = { min(dur, x0 + span / 2), v }
        hi = max(hi, v)
        if (own[bk] or 0) <= 0 then bands[#bands + 1] = { x0, min(dur, x0 + span), S.C.BAD, nil, alpha = 0.14 } end
    end
    EdgeToEdge(pts, dur)
    local step = Kit.NiceStep and Kit.NiceStep(hi * 1.1, 4) or hi / 4
    frame.chart:SetData({
        x0 = 0, x1 = dur, y1 = step * math.ceil(hi * 1.1 / step), grid = true, bands = bands,
        series = { { points = pts, color = Kit.C.gold, width = 1.8, fill = true, fillAlpha = 0.16, smooth = true, glow = true } },
        hover = function(x)
            local bk = floor(x / Meter.BUCKET) + 1
            local idle = (own[bk] or 0) <= 0
            return { { K.Clock(x), Kit.C.mute }, idle and { "did nothing", Kit.C.down } or
                     { strformat("%s %s", K.Int(Kit.YAt(pts, x) or 0), field == "hl" and "HPS" or "DPS"), Kit.C.gold } }
        end,
    })
    local metric = field == "hl" and "healing" or "damage"
    local bad = S.C.BAD
    frame.legend:SetText(strformat("%s %s's %s per second     "
        .. "|TInterface\\Buttons\\WHITE8X8:10:10:0:0:8:8:0:8:0:8:%d:%d:%d|t 5-second steps with nothing done",
        S:Wrap("GOLD", "—"), a.n or "?", metric, floor(bad[1] * 255), floor(bad[2] * 255), floor(bad[3] * 255)))
    TimeLabels(dur)
end

-- Shows the tabs that fit the mode; on = false: none (the tool row keeps the pager and the fight switch).
local function ShowTabs(on, canTargets, canTime)
    local bar = frame.tabs
    bar:SetTabShown("abilities", on and true or false)
    bar:SetTabShown("targets", (on and canTargets) and true or false)
    bar:SetTabShown("time", (on and canTime) and true or false)
end

-- The player and death views share the body: everything off, each view shows its own parts.
local function HideBody()
    for _, c in ipairs(frame.cards) do c:Hide() end
    frame.list:Hide(); frame.list.ScrollBar:Hide(); frame.det:Hide()
    frame.chart:Reset(); frame.chart:Hide(); frame.legend:Hide()
    for i = 1, 5 do frame.yLabs[i]:Hide(); frame.xLabs[i]:Hide() end
    frame.deathChart:Reset()                  -- (its labels sit on this window: Reset hides them too)
    frame.deathChart:Hide()
    frame.events:Hide()
    frame.events.ScrollBar:Hide()
    frame.evHead:Hide()
    frame.deathHp:Hide()
    for _, l in ipairs(frame.deathLabs) do l:Hide() end
    frame.empty:Hide()
end

function MD:Draw()
    if not frame or not frame:IsShown() then return end
    if St.view == "death" then return self:DrawDeath() end
    local seg = Meter:GetSegment(St.sel)
    local a = seg and seg.actors[St.guid]
    local mode = St.mode
    if mode == "dps" or mode == "deaths" then mode = "damage" end
    if mode == "damage" and a and (a.d or 0) == 0 and (a.h or 0) > 0 then mode = "healing" end
    local dur = Meter:Duration(seg)
    frame:SetWindowTitle("Breakdown")
    SetBanner(seg, a or { n = "?" }, ModeLabel(St.mode))
    local b = frame.banner
    b:SetSub(a and (S:Wrap("TEXT", K.SpecText(a)) .. " · " .. FightText(seg)) or FightText(seg))
    SetFightChip(seg and (seg.live and "Current fight" or Meter:SegName(seg)) or "No fights")
    local ranked = Ranked(seg, mode)
    local idx
    for i, r in ipairs(ranked) do if r.g == St.guid then idx = i end end
    b.step:SetText(idx and (K.Ordinal(idx) .. " of " .. #ranked) or "")
    b.prev:SetShown(#ranked > 1)
    b.next:SetShown(#ranked > 1)
    b.step:SetShown(true)
    HideBody()
    for _, c in ipairs(frame.cards) do c:Show() end
    if not a then
        for _, c in ipairs(frame.cards) do c:Hide() end
        ShowTabs(false)
        frame.tabs:SetText("")
        UI:HideFrom(frame.rows, 1)
        UI:HideFrom(frame.trows, 1)
        ShowEmpty("They were not in this fight.")
        return
    end

    -- cards
    local c = frame.cards
    local specIcon = K.SpecIcon(a.c, a.s) or "Interface\\Icons\\Ability_Warrior_SavageBlow"
    local act = Meter:RateTime(seg, a)
    MD.act = act
    if mode == "healing" then
        local tot = a.h + a.oh
        local crits, n = 0, 0
        for _, s in pairs(a.hs or {}) do if not s.sh and not s.nc then crits = crits + (s.c or 0); n = n + s.n end end
        SetCard(c[1], specIcon, K.Fmt(a.h), nil, "Healing done")
        SetCard(c[2], "Interface\\Icons\\Spell_Holy_FlashHeal", K.Int(a.h / act), idx and K.Ordinal(idx) or nil, "HPS in the raid")
        SetCard(c[3], "Interface\\Icons\\Spell_Holy_Renew", strformat("%d%%", tot > 0 and floor(a.oh / tot * 100 + 0.5) or 0), nil, "Overhealing")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", strformat("%.1f%%", n > 0 and crits / n * 100 or 0), nil, "Crit chance")
    elseif mode == "taken" then
        local big = 0                                      -- the biggest single hit (older fights: the biggest average)
        for _, s in pairs(a.ts or {}) do big = max(big, s.mx or (s.a / max(1, s.n))) end
        SetCard(c[1], specIcon, K.Fmt(a.t), nil, "Damage taken")
        SetCard(c[2], "Interface\\Icons\\Ability_Warrior_DefensiveStance", K.Int(a.t / dur), idx and K.Ordinal(idx) or nil, "Taken per second")
        SetCard(c[3], "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", tostring(Meter.IsDead and Meter:IsDead(seg, St.guid) and 1 or 0), nil, "Deaths")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", K.Int(big), nil, "Biggest hit")
    elseif mode == "kicks" or mode == "dispels" then
        local by = mode == "kicks" and a.ks or a.ds
        local spells, best, bestN = 0, nil, 0
        for k, n in pairs(by or {}) do spells = spells + 1; if n > bestN then best, bestN = k, n end end
        local count = (mode == "kicks" and a.k or a.dp) or 0
        local info = Meter.MODE[mode]
        SetCard(c[1], info.icon, K.Int(count), idx and K.Ordinal(idx) or nil, mode == "kicks" and "Interrupts" or "Dispels")
        SetCard(c[2], best and K.SpellIcon(best) or info.icon, K.Int(bestN), nil, best and K.SpellName(best) or "Most used")
        SetCard(c[3], "Interface\\Icons\\INV_Misc_Book_09", tostring(spells), nil, spells == 1 and "Spell used" or "Spells used")
        local per = dur > 0 and count / (dur / 60) or 0
        SetCard(c[4], "Interface\\Icons\\INV_Misc_PocketWatch_01", strformat("%.1f", per), nil, "Per minute")
    elseif mode == "active" then
        local on = min(dur, a.act or 0)
        SetCard(c[1], Meter.MODE.active.icon, K.Pct(on / dur * 100), idx and K.Ordinal(idx) or nil, "Active time")
        SetCard(c[2], specIcon, K.Clock(on), nil, "Active")
        SetCard(c[3], "Interface\\Icons\\Spell_Nature_Sleep", K.Clock(max(0, dur - on)), nil, "Idle")
        SetCard(c[4], "Interface\\Icons\\INV_Misc_PocketWatch_01", K.Clock(dur), nil, "Fight length")
    else
        local crits, n = 0, 0
        -- (only hits that can crit: periodic ticks, damage shields and Consecration would drag it down)
        for _, s in pairs(a.sp or {}) do if not s.nc then crits = crits + (s.c or 0); n = n + (s.n or 0) end end
        SetCard(c[1], specIcon, K.Fmt(a.d), nil, "Damage done")
        SetCard(c[2], "Interface\\Icons\\Spell_Nature_BloodLust", K.Int(a.d / act), idx and K.Ordinal(idx) or nil, "DPS in the raid")
        SetCard(c[3], "Interface\\Icons\\Spell_Holy_BlessingOfStrength", K.Pct(min(100, (a.act or 0) / dur * 100)), nil, "Active time")
        SetCard(c[4], "Interface\\Icons\\Spell_Holy_SealOfMight", strformat("%.1f%%", n > 0 and crits / n * 100 or 0), nil, "Crit chance")
    end

    -- Interrupts / Dispels: one list, no tabs; Active time: the chart, no tabs
    if mode == "kicks" or mode == "dispels" or mode == "active" then
        ShowTabs(false)
        frame.tabs:SetText(mode == "active" and "5-second steps" or "")
        local isList = mode ~= "active"
        frame.list:SetShown(isList)
        if isList then
            frame.list:SetWidth(INNER_W - 12)
            frame.listChild:SetWidth(INNER_W - 12)
            local h = DrawUses(a, mode)
            FitScroll(frame.list, h, BODY_H - LIST_Y)
        else
            UI:HideFrom(frame.rows, 1)
            UI:HideFrom(frame.trows, 1)
            if seg.noTl then
                ShowEmpty("Whole raid keeps no timeline: pick one fight to see when they were busy.")
            else
                frame.chart:Show(); frame.legend:Show()
                DrawActive(seg, a, dur)
            end
        end
        return
    end

    -- tabs: Targets for damage only, Over time not for Whole raid
    local canTargets = mode == "damage"
    local canTime = not seg.noTl and mode ~= "taken"
    ShowTabs(true, canTargets, canTime)
    if (St.tab == "targets" and not canTargets) or (St.tab == "time" and not canTime) then St.tab = "abilities" end
    frame.tabs:SelectTab(St.tab)

    local isList = St.tab ~= "time"
    frame.list:SetShown(isList)
    frame.chart:SetShown(not isList)
    frame.legend:SetShown(not isList)
    if St.tab == "abilities" then
        frame.list:SetWidth(frame.listW)
        frame.listChild:SetWidth(frame.listW)
        DrawAbilities(a, mode, dur)
        FitScroll(frame.list, frame.listChild:GetHeight() or 0, BODY_H - LIST_Y)
    elseif St.tab == "targets" then
        frame.list:SetWidth(INNER_W - 12)
        frame.listChild:SetWidth(INNER_W - 12)
        DrawTargets(a)
        FitScroll(frame.list, frame.listChild:GetHeight() or 0, BODY_H - LIST_Y)
    else
        UI:HideFrom(frame.rows, 1)
        UI:HideFrom(frame.trows, 1)
        DrawTime(seg, a, mode, dur)
    end
end

---------------------------------------------------------------------------
-- The death recap
---------------------------------------------------------------------------

local function DeathsOf(seg)
    local list = {}
    for _, d in ipairs(seg and seg.deaths or {}) do list[#list + 1] = d end
    return list
end

function MD:DrawDeath()
    local seg = Meter:GetSegment(St.sel)
    local d = St.death
    local deaths = DeathsOf(seg)
    local idx
    for i, x in ipairs(deaths) do if x == d then idx = i end end
    if not idx and d and seg then
        for i, x in ipairs(deaths) do if x.g == d.g and x.t == d.t then idx = i; d = x; St.death = x end end
    end
    if not d then frame:Hide() return end
    local a = (seg and seg.actors[d.g]) or { n = d.n, c = d.c }
    frame:SetWindowTitle("Death recap")
    SetBanner(seg, a, "Death recap")
    local b = frame.banner
    local took, healed = 0, 0
    for _, e in ipairs(d.ev or {}) do
        if e[2] == "d" then took = took + (e[4] or 0) else healed = healed + (e[4] or 0) end
    end
    b:SetSub(strformat("Died at %s to %s · in the last %d s took %s, healed %s",
        S:Wrap("TEXT", K.Clock(d.t)), S:Wrap("BAD", d.by and K.SpellName(d.by) or "?"), Meter.RECAP,
        S:Wrap("TEXT", K.Int(took)), S:Wrap("TEXT", K.Int(healed))))
    SetFightChip(seg and (seg.live and "Current fight" or Meter:SegName(seg)) or "")
    b.step:SetText(idx and (K.Ordinal(idx) .. " of " .. #deaths) or "")
    b.prev:SetShown(#deaths > 1)
    b.next:SetShown(#deaths > 1)
    HideBody()
    ShowTabs(false)
    frame.tabs:SetText(strformat("The last %d seconds", Meter.RECAP))
    UI:HideFrom(frame.rows, 1)
    UI:HideFrom(frame.trows, 1)

    -- health over the last seconds (a step line; the start is worked back from the first event)
    local ev = d.ev or {}
    local hpMax = (d.hpMax and d.hpMax > 0) and d.hpMax or 0
    if hpMax <= 0 then for _, e in ipairs(ev) do hpMax = max(hpMax, e[6] or 0) end end
    if hpMax <= 0 then hpMax = 1 end
    local function pct(v) return min(100, max(0, (v or 0) / hpMax * 100)) end
    local pts, dots = {}, {}
    local first = ev[1]
    local start = hpMax
    if first then
        start = (first[6] or 0) + (first[2] == "d" and (first[4] or 0) or -(first[4] or 0))
        start = min(hpMax, max(0, start))
    end
    pts[1] = { -Meter.RECAP, pct(start) }
    local prev = pct(start)
    for _, e in ipairs(ev) do
        pts[#pts + 1] = { e[1], prev }
        local now = pct(e[6])
        pts[#pts + 1] = { e[1], now }
        dots[#dots + 1] = { e[1], now, e[2] == "d" and Kit.C.down or Kit.C.up, 8 }
        prev = now
    end
    local dc = frame.deathChart
    dc:Show()
    dc:SetData({
        x0 = -Meter.RECAP, x1 = 0.3, y1 = 112, grid = true,
        series = { { points = pts, color = Kit.C.up, width = 2, fill = true, fillAlpha = 0.18 } },
        dots = dots,
        hover = function(x)
            local best, bd
            for _, e in ipairs(ev) do
                local dd = abs(e[1] - x)
                if not bd or dd < bd then best, bd = e, dd end
            end
            if not best or bd > 0.8 then return nil end
            return { { strformat("%.1f s", best[1]), Kit.C.mute },
                     { K.SpellName(best[3]) .. "  " .. (best[2] == "d" and "-" or "+") .. K.Int(best[4]), best[2] == "d" and Kit.C.down or Kit.C.up },
                     { strformat("health %s", K.Int(best[6] or 0)), Kit.C.mute } }
        end,
    })
    frame.deathHp:SetText(K.Int(hpMax) .. " health")
    frame.deathHp:Show()
    local dW = (dc:GetWidth() or 0) > 0 and dc:GetWidth() or dc.fallback[1]
    for i = 1, 6 do
        local s = -Meter.RECAP + (i - 1) * 2
        local lab = frame.deathLabs[i]
        lab:ClearAllPoints()
        lab:SetPoint("TOP", dc, "BOTTOMLEFT", dW * (s + Meter.RECAP) / (Meter.RECAP + 0.3), -5)
        lab:SetText(s == 0 and "death" or (s .. " s"))
        lab:Show()
    end

    -- every event, newest first
    frame.evHead:SetCount(#ev)
    frame.evHead:Show()
    frame.events:Show()
    local n = #ev
    for i = 1, n do
        local e = ev[n - i + 1]
        local r = EventRow(i)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", frame.eventsChild, "TOPLEFT", 0, -(i - 1) * EROW_H)
        r:SetWidth(INNER_W - 10)
        local killing = i == 1 and e[2] == "d"
        r:SetStripe(not killing and i % 2 == 1)
        r.kill:SetShown(killing)
        r.mark:SetShown(killing)
        r.t:SetText(strformat("%.1f s", e[1]))
        r.icon:Set(K.SpellIcon(e[3]))
        local extra = ""
        if e[2] == "d" and e[7] then extra = " · overkill " .. K.Int(e[7]) end
        if e[2] == "h" and e[7] then extra = " · " .. K.Int(e[7]) .. " over" end
        r.what:SetText(strformat("%s %s", K.SpellName(e[3]),
            S:Wrap("SUB", strformat("%s %s%s", e[2] == "d" and "from" or "by", e[5] or "?", extra))))
        r.amount:SetText((e[2] == "d" and "−" or "+") .. K.Int(e[4]))
        r.amount:SetTextColor(S:Color(e[2] == "d" and "BAD" or "OK"))
        local p = pct(e[6])
        r.hpFill:SetWidth(max(0.01, 64 * p / 100))
        r.hpFill:SetShown(p > 0)
        r.hpFill:SetVertexColor(S:Color(p < 30 and "BAD" or "OK"))
        r.hp:SetText(floor(p + 0.5) .. "%")
        r:Show()
    end
    UI:HideFrom(frame.evRows, n + 1)
    frame.eventsChild:SetHeight(max(10, n * EROW_H))
    FitScroll(frame.events, n * EROW_H, BODY_H - 194)
end

---------------------------------------------------------------------------
-- Opening, arrows, fights
---------------------------------------------------------------------------

function MD:Open(sel, guid, mode)
    if not frame then Build() end
    St.view, St.sel, St.guid, St.mode = "player", sel or "cur", guid, mode or "damage"
    St.ab = nil
    if St.mode == "healing" or St.mode == "taken" then St.tab = "abilities" end
    frame:Show()
    frame:Raise()
    self:Draw()
end

function MD:OpenDeath(sel, death)
    if not frame then Build() end
    St.view, St.sel, St.death = "death", sel or "cur", death
    frame:Show()
    frame:Raise()
    self:Draw()
end

function MD:Step(dir)
    local seg = Meter:GetSegment(St.sel)
    if St.view == "death" then
        local list = DeathsOf(seg)
        if #list == 0 then return end
        local i = 1
        for j, d in ipairs(list) do if d == St.death then i = j end end
        St.death = list[(i - 1 + dir) % #list + 1]
    else
        local mode = St.mode
        if mode == "dps" or mode == "deaths" then mode = "damage" end
        local list = Ranked(seg, mode)
        if #list == 0 then return end
        local i = 1
        for j, r in ipairs(list) do if r.g == St.guid then i = j end end
        St.guid = list[(i - 1 + dir) % #list + 1].g
        St.ab = nil
    end
    self:Draw()
end

function MD:FightMenu(root)
    local fights, all = Meter:GetFights()
    for i, seg in ipairs(fights) do
        local e = root:CreateRadio(seg.live and "Current fight" or Meter:SegName(seg), function()
            local cur = Meter:GetSegment(St.sel)
            return cur == seg
        end, function()
            St.sel = (i == 1) and "cur" or seg.id
            MD:Draw()
        end, seg.id)
        e:SetSubtext(FightText(seg):gsub("^[^·]+· ", ""))
    end
    if all then
        root:CreateDivider()
        local e = root:CreateRadio(Meter:SegName(all), function() return St.sel == "all" end,
            function() St.sel = "all"; MD:Draw() end, "all")
        e:SetSubtext(K.Clock(Meter:Duration(all)))
    end
end

function MD:GetFrame() return frame end
function MD:GetState() return St end

function MD:OnLogin()
    Meter = ns.Meter
    Meter:OnChange(function(what)
        if frame and frame:IsShown() and (what == "end" or what == "clear") then MD:Draw() end
    end)
end

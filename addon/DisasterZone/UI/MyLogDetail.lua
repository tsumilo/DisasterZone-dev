if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogDetail.lua", ...) then return end -- DisasterZone: My Log boss and death screens.
-- Two screens of the My Log page (UI/MyLogUI.lua), on the shared layouts; the data drawings come from UI/MyLogKit.lua:
--   boss:   a Detail page (UI:CreateLayout "detail"): a strip banner over the raid's art (back to the raid's nights,
--           the boss's portrait, name and the pull's facts), tabs Breakdown | Cast timeline on its foot, a tool row
--           with the view switch and the pull to compare with (my previous kill by default; any pull that still has
--           its detail can be picked). Breakdown: a big chart (the view's number every 5 seconds for both pulls, gold
--           with a soft fill and grey; the boss's mechanics as violet bands, my idle gaps as red ticks on the
--           baseline; hover it to read both pulls at that moment), four stat cards (the number, active time, idle
--           gaps, how fast I was back after the boss's mechanics), then where my damage (healing, or the damage I
--           took) came from: spell icon, a gold bar for this pull and a grey one for the other, the amount, its share
--           and its change; uptimes in a column on the right. Cast timeline: UI/MyLogTimeline.lua over the whole body.
--   deaths: the Deaths tab, a List + detail (UI:CreateLayout "listdetail") in the board's body: left, what kills me
--           here (All deaths, then every cause, most deaths first, avoidable ones marked; a click picks one); right,
--           the picked death's banner (boss, when, which of how many, Next / Previous), its last 10 seconds as a
--           health line with its hits and heals as dots and my casts as ticks, and the same seconds as a story, line
--           by line, with my health after each.
local addonName, ns = ...

local MyLogDetail = ns:NewModule("MyLogDetail")

local S = ns.Style
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat, strsub = string.format, string.sub

local ROW_H = S.ROW.rich
local STORY_H = S.ROW.list

local panel, bossView, deathsView
local cur = { pull = nil, cmp = nil }
local deathSel, causeSel

local function UI() return ns.UI end
local function Log() return ns.MyLog end
local function K() return ns.MyLogKit end
local function Views() return ns.MyLogUI.VIEW_BY_KEY end
local function A(c, a) return { c[1], c[2], c[3], a } end

local function SpellName(p, key)
    local n = p and p.names and p.names[key]
    if n then return n end
    local id = tonumber((tostring(key):gsub("^[pm]", "")))
    if id and GetSpellInfo then
        local name = GetSpellInfo(id)
        if name then return name end
    end
    return tostring(key)
end

local function BossKey(p) return p.enc or p.boss end

---------------------------------------------------------------------------
-- Picking the pulls
---------------------------------------------------------------------------

local function DetailPulls(boss)
    local out = {}
    local all = Log():GetPulls()
    for i = #all, 1, -1 do
        local p = all[i]
        if BossKey(p) == boss and p.tl and not p.cut then out[#out + 1] = p end
    end
    return out
end

local function PullLabel(p)
    local k = K()
    return strformat("%s · %s %s", k.Day(p.at), p.kill and "kill" or strformat("wipe %.0f%%", p.pct or 0), k.Clock(p.dur))
end

local function DefaultCompare(p)
    local same, any, before
    for _, q in ipairs(DetailPulls(BossKey(p))) do
        if q ~= p and (q.at or 0) < (p.at or 0) then
            if q.kill and q.spec == p.spec and not same then same = q end
            if q.kill and not any then any = q end
            if not before then before = q end
        end
    end
    return same or any or before
end

function MyLogDetail:ShowBoss(row)
    local state = ns.MyLogUI:GetState()
    local pull = row.kill
    if not pull then
        local runs = Log():GetRuns(state.inst)
        local run = runs[state.run] or runs[1]
        for _, p in ipairs(run and run.pulls or {}) do
            if BossKey(p) == (row.enc or row.boss) and not p.cut then
                if not pull or (p.pct or 100) < (pull.pct or 100) then pull = p end
            end
        end
    end
    cur.pull = pull
    cur.cmp = pull and DefaultCompare(pull) or nil
    cur.mode = cur.mode or "list"
    ns.MyLogUI:SetMode("boss")
end

function MyLogDetail:HideAll()
    if bossView then bossView.layout:Hide() end
    if deathsView then deathsView.layout:Hide() end
end

function MyLogDetail:GetCurrent() return cur.pull, cur.cmp end
function MyLogDetail:GetSelectedDeath() return deathSel end

---------------------------------------------------------------------------
-- Abilities
---------------------------------------------------------------------------

-- Rows for a pull: { key, name, casts, hits, amount, share (0..1), crit (0..1), avg, max, avoidable, src, pet }
local function AbilityRows(p, view)
    local out, total = {}, 0
    if not p or not p.dmg then return out, 0 end
    local function add(key, st, amount, opts)
        opts = opts or {}
        local id = tonumber((tostring(key):gsub("^p", "")))
        local r = {
            key = key, name = SpellName(p, key), hits = st.n or 0, amount = amount,
            crit = (st.n or 0) > 0 and (st.c or 0) / st.n or nil, max = st.mx,
            casts = (strsub(tostring(key), 1, 1) ~= "p" and id and p.casts and p.casts[id]) or nil,
            avoidable = opts.avoidable, src = st.src, overheal = opts.overheal, shield = opts.shield,
            pet = strsub(tostring(key), 1, 1) == "p",
        }
        r.avg = (st.n or 0) > 0 and amount / st.n or nil
        out[#out + 1] = r
        total = total + amount
    end
    if view == "healing" then
        for key, st in pairs(p.heal) do
            local eff = st.a or 0
            add(key, st, eff, { overheal = (eff + (st.oh or 0)) > 0 and (st.oh or 0) / (eff + (st.oh or 0)) or 0 })
        end
        for key, st in pairs(p.shield) do add(key, st, st.a or 0, { shield = true }) end
    elseif view == "tanking" then
        for key, st in pairs(p.taken) do
            add(key, st, (st.a or 0) - (st.o or 0) + (st.ab or 0) + (st.mab or 0), { avoidable = Log():IsAvoidable(key) })
        end
    else
        for _, tbl in ipairs({ p.dmg, p.pet }) do
            for key, st in pairs(tbl) do add(key, st, (st.a or 0) - (st.o or 0) + (st.ab or 0)) end
        end
    end
    table.sort(out, function(a, b) return a.amount > b.amount end)
    for _, r in ipairs(out) do r.share = total > 0 and r.amount / total or 0 end
    return out, total
end
function MyLogDetail:AbilityRows(p, view) return AbilityRows(p, view) end

local function AbilitySub(r, view)
    local bits = {}
    if view == "tanking" then
        if r.src then bits[#bits + 1] = "from " .. r.src end
        bits[#bits + 1] = strformat("%d hit%s", r.hits, r.hits == 1 and "" or "s")
    else
        if r.casts then bits[#bits + 1] = strformat("%d casts", r.casts) else bits[#bits + 1] = strformat("%d hits", r.hits) end
        if r.crit and r.crit > 0 then bits[#bits + 1] = strformat("%.1f%% crit", r.crit * 100) end
        if r.overheal and r.overheal > 0 then bits[#bits + 1] = strformat("%.0f%% overheal", r.overheal * 100) end
        if r.shield then bits[#bits + 1] = "shield" end
    end
    return table.concat(bits, " · ")
end

local BAR_X, BAR_W = 230, 150

-- The tooltip lines of an ability row (under its name).
local function AbilityTip(row)
    local d = row.__cdlData
    local r = d and d.r
    if not r then return {} end
    local k = K()
    local lines = {}
    if r.src then lines[#lines + 1] = "From " .. r.src end
    lines[#lines + 1] = strformat("%s in %d hit%s, biggest %s", k.Num(r.amount), r.hits, r.hits == 1 and "" or "s", k.Num(r.max))
    if r.avoidable then lines[#lines + 1] = { "Avoidable: you can stay out of this.", "WARN" } end
    if r.before then lines[#lines + 1] = { strformat("%s in the pull compared with.", k.Num(r.before)), "SUB" } end
    return lines
end

local function InitAbility(row, data)
    local k = K()
    local C = k.C
    local ui = UI()
    if not row.name then
        ui:DecorateRow(row, { hover = true, stripe = true })
        row.rank = ui:Text(row, "small", "DIM", { justify = "RIGHT", width = 16 })
        row.rank:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.icon = k.Icon(row, 28)
        row.icon:SetPoint("LEFT", row, "LEFT", 26, 0)
        row.name = ui:Text(row, "body", "TEXT", { width = 158 })
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 64, -6)
        row.sub = ui:Text(row, "small", "SUB", { width = 158 })
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        -- the track: a faint full-width groove, this pull's bar on it, the other pull's as a thin line under it
        row.track = row:CreateTexture(nil, "ARTWORK")
        row.track:SetPoint("LEFT", row, "LEFT", BAR_X, 2)
        row.track:SetSize(BAR_W, 6)
        row.track:SetColorTexture(S:Color("QUIET"))
        row.barNow = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.barNow:SetPoint("LEFT", row.track, "LEFT", 0, 0)
        row.barNow:SetHeight(6)
        row.barThen = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.barThen:SetPoint("TOPLEFT", row.track, "BOTTOMLEFT", 0, -3)
        row.barThen:SetHeight(2)
        row.barThen:SetColorTexture(C.mute[1], C.mute[2], C.mute[3], 0.55)
        row.amount = ui:Text(row, "title", "TEXT", { justify = "RIGHT" })
        row.amount:SetPoint("TOPRIGHT", row, "TOPRIGHT", -78, -5)
        row.share = ui:Text(row, "small", "SUB", { justify = "RIGHT" })
        row.share:SetPoint("TOPRIGHT", row.amount, "BOTTOMRIGHT", 0, -1)
        row.chip = k.Pill(row)
        row.chip:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.av = k.Pill(row)
        ui:AttachTooltip(row, function(self, tip)
            local d = self.__cdlData
            if not (d and d.r) then return false end
            tip:AddLine(d.r.name, S:Color("GOLD"))
        end, AbilityTip)
    end
    local r, view, top = data.r, data.view, data.top
    row:SetStripe(data.rank)
    row.rank:SetText(data.rank)
    row.icon:SetSpell(r.key)
    row.name:SetText(r.name .. (r.pet and S:Wrap("DIM", "  pet") or ""))
    row.sub:SetText(AbilitySub(r, view))
    local scale = top > 0 and BAR_W / top or 0
    row.barNow:SetWidth(max(2, r.amount * scale))
    local col = view == "healing" and C.up or (view == "tanking" and (r.avoidable and C.avoid or C.down) or C.gold)
    ui:Gradient(row.barNow, "HORIZONTAL", { col[1] * 0.45, col[2] * 0.45, col[3] * 0.45, 1 }, A(col, 1))
    if r.before then
        row.barThen:SetWidth(max(2, r.before * scale))
        row.barThen:Show()
    else
        row.barThen:Hide()
    end
    row.amount:SetText(k.Num(r.amount))
    row.share:SetText(strformat("%.1f%%", (r.share or 0) * 100))
    if r.before then
        local text, kind = k.ChangeChip(k.Change(r.amount, r.before), view ~= "tanking")
        row.chip:SetPill(kind, text)
    elseif data.hasCmp then
        row.chip:SetPill("mute", "new")
    else
        row.chip:SetPill(nil)
    end
    if r.avoidable then
        row.av:SetPill(k.PILL.avoid, "avoidable")
        row.av:ClearAllPoints()
        row.av:SetPoint("LEFT", row.name, "LEFT", min(158, (row.name:GetStringWidth() or 60)) + 6, 0)
    else
        row.av:SetPill(nil)
    end
end

---------------------------------------------------------------------------
-- Boss screen
---------------------------------------------------------------------------

local TL_FIELD = { damage = "d", healing = "h", tanking = "t" }

-- Per-second values of a pull every 5 s (the last bucket divided by its real length, so a fight that ends 2 s into
-- a bucket does not dip or spike at the end).
local function Points(p, view)
    local tl = p and p.tl and p.tl[TL_FIELD[view] or "d"]
    local out = {}
    if not tl then return out end
    local dur = p.dur or 0
    local n = floor(dur / 5) + 1
    for i = 1, n do
        local len = min(5, dur - (i - 1) * 5)
        if len >= 2 then out[#out + 1] = { (i - 1) * 5 + len / 2, (tl[i] or 0) / len } end   -- (a 1 s tail is noise)
    end
    -- damage taken comes in single hits: a 15 s average reads as pressure instead of a row of needles
    if view == "tanking" and #out > 2 then
        local avg = {}
        for i = 1, #out do
            local a, b = max(1, i - 1), min(#out, i + 1)
            local sum = 0
            for j = a, b do sum = sum + out[j][2] end
            avg[i] = { out[i][1], sum / (b - a + 1) }
        end
        out = avg
    end
    return out
end

local function GapsOf(p)
    local n, s = 0, 0
    for _, g in ipairs(p and p.gaps or {}) do n = n + 1; s = s + (g.len or 0) end
    return n, s
end

-- How fast I was back after the boss's mechanics: the average idle gap that starts within 6 s of one (0 when
-- none), and the first mechanic's spell id. nil when the pull has no mechanics.
local function Recovery(p)
    if not p or not p.mech or #p.mech == 0 then return nil end
    local total, n = 0, 0
    for _, m in ipairs(p.mech) do
        local best
        for _, g in ipairs(p.gaps or {}) do
            if g.at >= m[1] - 1 and g.at <= m[1] + 6 then best = max(best or 0, g.len) end
        end
        total, n = total + (best or 0), n + 1
    end
    return n > 0 and total / n or nil, p.mech[1][2]
end

-- The breakdown's blocks, top down: the chart card, the stat cards, the two column heads, the list.
local CHART_H = 150
local STATS_Y = -(CHART_H + S.GAP)
local HEAD_Y = STATS_Y - S.ROW.art - S.GAP
local LIST_Y = HEAD_Y - 18 - 4
-- the uptime column right of the abilities (the list's scroll bar sits in the gap)
local UP_W, COL_GAP, UP_ROW_H = 214, 24, S.ROW.list
local ICON_ACTIVE = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local ICON_IDLE = "Interface\\Icons\\Spell_Nature_Sleep"
local ICON_AVOID = "Interface\\Icons\\Spell_Fire_Fire"
local LIST_LABEL = { damage = "Damage by ability", healing = "Healing by ability", tanking = "What hit you" }

-- One uptime row: icon, name, time, a thin bar along its foot.
local function NewUptime(v, i)
    local ui = UI()
    local u = CreateFrame("Frame", nil, v)
    u:SetSize(UP_W, UP_ROW_H)
    u:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, LIST_Y - (i - 1) * UP_ROW_H)
    u.icon = K().Icon(u, 18)
    u.icon:SetPoint("LEFT", u, "LEFT", 0, 1)
    u.name = ui:Text(u, "body", "TEXT", { width = UP_W - 26 - 44 })
    u.name:SetPoint("LEFT", u, "LEFT", 26, 1)
    u.val = ui:Text(u, "body", "TEXT", { justify = "RIGHT" })
    u.val:SetPoint("RIGHT", u, "RIGHT", 0, 1)
    u.well = u:CreateTexture(nil, "ARTWORK")
    u.well:SetColorTexture(S:Color("QUIET"))
    u.well:SetHeight(2)
    u.well:SetPoint("BOTTOMLEFT", u, "BOTTOMLEFT", 26, 2)
    u.well:SetPoint("BOTTOMRIGHT", u, "BOTTOMRIGHT", 0, 2)
    u.bar = u:CreateTexture(nil, "ARTWORK", nil, 1)
    u.bar:SetHeight(2)
    u.bar:SetPoint("LEFT", u.well, "LEFT")
    ui:AttachTooltip(u, function(self, tip)
        if not self.tipTitle then return false end
        tip:AddLine(self.tipTitle, S:Color("GOLD"))
    end, function(self) return self.tipLines end)
    return u
end

-- The tool row's compare picker: "compare with" and the pulls of this boss that still have their detail.
local function NewComparePicker(bar)
    local ui = UI()
    local f = CreateFrame("Frame", nil, bar)
    f:SetSize(10, 22)
    f.dd = ui:CreateSleekDropdown(f, 200,
        function()
            local out = {}
            if not cur.pull then return out end
            for _, q in ipairs(DetailPulls(BossKey(cur.pull))) do
                if q ~= cur.pull then out[#out + 1] = { value = q.id, text = PullLabel(q) } end
            end
            return out
        end,
        function() return cur.cmp and cur.cmp.id end,
        function(id)
            for _, q in ipairs(DetailPulls(BossKey(cur.pull))) do if q.id == id then cur.cmp = q end end
            ns.MyLogUI:Refresh()
        end)
    f.dd:SetDefaultText("nothing to compare")
    f.dd:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    f.lab = ui:Text(f, "small", "SUB", { text = "compare with", justify = "RIGHT" })
    f.lab:SetPoint("RIGHT", f.dd, "LEFT", -8, 0)
    f:SetWidth(floor(ui:TextWidth(f.lab) + 8 + 200 + 0.5))
    return f
end

local function BuildBossView(parent)
    local k = K()
    local C = k.C
    local ui = UI()
    local L = ui:CreateLayout("detail", parent, {
        banner = { size = "strip" },
        back = { "My Log", function() ns.MyLogUI:SetMode("runs") end },
        tabs = { { key = "list", text = "Breakdown" }, { key = "timeline", text = "Cast timeline" } },
        onTab = function(key) cur.mode = key; ns.MyLogUI:Refresh() end,
    })
    local v = CreateFrame("Frame", nil, L.body)
    v:SetAllPoints(L.body)
    v.layout = L
    v.modeSeg = L.tabs
    v.modeSeg.buttons = L.tabs.tabButtons
    -- the tool row: the view switch and the pull to compare with
    local items = {}
    for i, it in ipairs(ns.MyLogUI.VIEWS) do items[i] = { key = it.key, label = it.label } end
    v.seg = ui:CreateSegments(L.toolbar, items, function(key) ns.MyLogUI:SetView(key) end, { itemW = 70 })
    v.cmp = NewComparePicker(L.toolbar)
    v.cmpDD = v.cmp.dd
    L.toolbar:SetFilters({ v.seg, v.cmp })

    v.chartCard = ui:CreateCard(v, { tone = "inset" })
    v.chartCard:SetPoint("TOPLEFT", v, "TOPLEFT", 0, 0)
    v.chartCard:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, 0)
    v.chartCard:SetHeight(CHART_H)
    v.legend = k.Legend(v.chartCard)
    v.legend:SetPoint("TOPRIGHT", v.chartCard, "TOPRIGHT", -12, -8)
    v.chart = k.Chart(v.chartCard)
    v.chart:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 48, -26)
    v.chart:SetPoint("BOTTOMRIGHT", v.chartCard, "BOTTOMRIGHT", -14, 22)
    v.chart.inset = { l = 0, r = 0, t = 14, b = 0 }
    v.chart.fallback = { S.INNER_W - 62, CHART_H - 48 }
    v.xLabs = {}
    for i = 1, 4 do v.xLabs[i] = ui:Text(v.chartCard, "small", "DIM") end
    -- the time labels at 0, 1/3, 2/3 and the end of the chart's width
    function v.PlaceX()
        local w = v.chart:GetWidth() or 0
        if w <= 0 then w = v.chart.fallback[1] end
        for i, lab in ipairs(v.xLabs) do
            lab:ClearAllPoints()
            lab:SetPoint(i == 4 and "TOPRIGHT" or (i == 1 and "TOPLEFT" or "TOP"), v.chart, "BOTTOMLEFT", w * (i - 1) / 3, -6)
        end
    end
    v.chart:HookScript("OnSizeChanged", function() v.PlaceX() end)

    v.stats = k.StatStrip(v, 4)
    v.stats:SetPoint("TOPLEFT", v, "TOPLEFT", 0, STATS_Y)
    v.stats:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, STATS_Y)

    -- the two columns: the abilities (scrolling, whole rows) and the uptimes
    v.listHead = ui:CreateSectionHeader(v, LIST_LABEL.damage, { style = "caps" })
    v.listHead:SetPoint("TOPLEFT", v, "TOPLEFT", 0, HEAD_Y)
    v.listHead:SetPoint("TOPRIGHT", v, "TOPRIGHT", -(UP_W + COL_GAP), HEAD_Y)
    v.list = ui:CreateScrollList(v, ROW_H, InitAbility)
    v.list.frame:SetPoint("TOPLEFT", v, "TOPLEFT", 0, LIST_Y)
    v.list.frame:SetPoint("TOPRIGHT", v, "TOPRIGHT", -(UP_W + COL_GAP) + 20, LIST_Y)
    -- whole rows only: a half row peeking out at the bottom looks broken
    local function fitList()
        local h = v:GetHeight() or 0
        if h <= -LIST_Y then h = 420 end    -- (the body's height under the strip banner, before layout)
        local avail = h + LIST_Y
        v.list.frame:SetHeight(max(ROW_H, floor(avail / ROW_H) * ROW_H))
        v.upFit = max(1, floor(avail / UP_ROW_H))
    end
    fitList()
    v.FitList = fitList
    v:HookScript("OnSizeChanged", fitList)
    v.list:SetEmptyText("The detail of this pull aged out: only the newest pulls of a boss keep it.")

    -- uptimes: a column of icon, name, time and a thin bar (like My BiS's "still to get" list)
    v.upLab = ui:CreateSectionHeader(v, "Uptime", { style = "caps" })
    v.upLab:SetPoint("TOPRIGHT", v, "TOPRIGHT", 0, HEAD_Y)
    v.upLab:SetWidth(UP_W)
    v.ups = {}
    for i = 1, 12 do v.ups[i] = NewUptime(v, i) end
    v.breakdown = { v.chartCard, v.stats, v.listHead, v.list.frame }

    -- the cast timeline: the whole body
    v.timeline = ns.MyLogTimeline:Create(v)
    v.timeline:SetAllPoints(v)
    v.timeline.fallback = { S.INNER_W, 420 }
    return v
end

local function Uptimes(p)
    local out = {}
    for side, list in pairs(p.up or {}) do
        for id, secs in pairs(list) do
            out[#out + 1] = { id = id, pct = (p.dur or 0) > 0 and secs / p.dur or 0, secs = secs, out = side == "out" }
        end
    end
    -- my debuffs first, then the buffs that were not up all fight (procs, cooldowns), then the rest
    table.sort(out, function(a, b)
        if a.out ~= b.out then return a.out end
        local fa, fb = a.pct >= 0.99, b.pct >= 0.99
        if fa ~= fb then return fb end
        return a.secs > b.secs
    end)
    return out
end

-- The banner: back to the raid's nights, the boss's portrait (when the game knows its face), name and the facts.
local function FillBossBanner(v, state, p)
    local k = K()
    local b = v.layout.banner
    b:SetArt(ns.MyLogUI:InstanceArt(state.inst))
    b:SetBack(ns.MyLogUI:InstanceName(state.inst), function() ns.MyLogUI:SetMode("runs") end)
    local disp = Log().BossDisplayId and Log():BossDisplayId(p.boss)
    if disp and SetPortraitTextureFromCreatureDisplayID then
        b:SetIcon(134400)
        SetPortraitTextureFromCreatureDisplayID(b.icon.tex, disp)
        if b.icon.tex.SetDesaturated then b.icon.tex:SetDesaturated(not p.kill) end
    else
        b:SetIcon(nil)
    end
    b:SetTitle(p.boss or "?")
    local bits = { p.kill and ("Kill in " .. k.Clock(p.dur)) or strformat("Wipe at %.1f%% after %s", p.pct or 0, k.Clock(p.dur)),
        k.Day(p.at) }
    if p.spec and p.spec ~= "" then bits[#bits + 1] = p.spec end
    if p.ilvl then bits[#bits + 1] = strformat("ilvl %.1f", p.ilvl) end
    b:SetSub(table.concat(bits, "  ·  "))
end

local function FillBossChart(v, view, p, q)
    local k = K()
    local C = k.C
    local V = Views()[view]
    local a = Points(p, view)
    local b = q and Points(q, view) or {}
    local x1 = max(p.dur or 5, q and q.dur or 0, 5)
    local hi = 1
    for _, s in ipairs({ a, b }) do for _, pt in ipairs(s) do hi = max(hi, pt[2]) end end
    local bands, marks = {}, {}
    for _, e in ipairs(p.bev or {}) do
        if e[2] == "a" then
            bands[#bands + 1] = { e[1], e[1] + (e[4] or ((p.dur or 0) - e[1])), C.violet, SpellName(p, tostring(e[3])), alpha = 0.16 }
        elseif e[2] == "y" then
            marks[#marks + 1] = { e[1], C.gold }
        end
    end
    if #bands == 0 then
        for _, m in ipairs(p.mech or {}) do
            bands[#bands + 1] = { m[1], m[1] + 5, C.violet, SpellName(p, tostring(m[2])), alpha = 0.16 }
        end
    end
    local ticks = {}
    for _, g in ipairs(p.gaps or {}) do ticks[#ticks + 1] = { g.at, C.down, g.at + g.len } end
    local series = {}
    -- (damage taken is already averaged; a curve through sparse hits would wobble)
    local smooth = view ~= "tanking"
    if q then series[#series + 1] = { points = b, color = C.mute, width = 1.2, alpha = 0.55, smooth = smooth } end
    table.insert(series, 1, { points = a, color = C.gold, width = 1.8, fill = true, fillAlpha = 0.16, smooth = smooth, glow = true, endDot = true })
    v.chart:SetData({
        x0 = 0, x1 = x1, y1 = hi * 1.12, series = series, bands = bands, ticks = ticks, grid = true, marks = marks,
        hover = function(x)
            local lines = { { k.Clock(x), C.mute } }
            local ya = k.YAt(a, x)
            if ya and x <= (p.dur or 0) then lines[#lines + 1] = { strformat("%s %s   %s", k.Num(ya), V.metric, k.ShortDay(p.at)), C.gold } end
            local yb = q and k.YAt(b, x)
            if yb and x <= (q.dur or 0) then lines[#lines + 1] = { strformat("%s %s   %s", k.Num(yb), V.metric, k.ShortDay(q.at)), C.mute } end
            local shown = 0
            for _, e in ipairs(p.bev or {}) do
                local hit = abs(e[1] - x) <= 3 or (e[2] == "a" and x >= e[1] and x <= e[1] + (e[4] or p.dur or 0))
                if hit and shown < 3 then
                    lines[#lines + 1] = { ns.MyLogTimeline:BossEventText(p, e), e[2] == "y" and C.gold or C.violet }
                    shown = shown + 1
                end
            end
            if shown == 0 then
                for _, m in ipairs(p.mech or {}) do
                    if x >= m[1] and x <= m[1] + 5 then lines[#lines + 1] = { SpellName(p, tostring(m[2])), C.violet } break end
                end
            end
            for _, g in ipairs(p.gaps or {}) do
                if x >= g.at and x <= g.at + g.len then lines[#lines + 1] = { strformat("idle %.1f s", g.len), C.down } break end
            end
            return lines
        end,
    })
    local at = { 0, x1 / 3, x1 * 2 / 3, x1 }
    for i, lab in ipairs(v.xLabs) do lab:SetText(k.Clock(at[i])) end
    v.PlaceX()
    local legend = { { C.gold, k.ShortDay(p.at) } }
    if q then legend[#legend + 1] = { C.mute, k.ShortDay(q.at) } end
    if #bands > 0 then legend[#legend + 1] = { C.violet, "boss ability", "box" } end
    if #marks > 0 then legend[#legend + 1] = { C.gold, "boss yell", "tick" } end
    legend[#legend + 1] = { C.down, "idle 2 s+", "tick" }
    v.legend:Set(legend)
end

local function FillBossStats(v, view, p, q, rows)
    local k = K()
    local V = Views()[view]
    local ps, qs = p.s or {}, q and q.s or {}
    local metricNow, metricThen = Log():Metric(p, view), q and Log():Metric(q, view)
    local text, kind = k.ChangeChip(k.Change(metricNow, metricThen), view ~= "tanking")
    local noteKind = kind == "ok" and "up" or (kind == "live" and "down" or "mute")
    v.stats:SetCell(1, V.metric, k.Num(metricNow), text or "", noteKind, rows[1] and rows[1].key)
    local actNote, actKind = "", "mute"
    if ps.act and qs.act then
        local d = (ps.act - qs.act) * 100
        actNote, actKind = strformat("%+.1f pts", d), d >= 0 and "up" or "down"
    end
    v.stats:SetCell(2, "Active time", ps.act and strformat("%.1f%%", ps.act * 100) or "-", actNote, actKind, ICON_ACTIVE)
    local gn, gs = GapsOf(p)
    local qn = q and GapsOf(q) or nil
    v.stats:SetCell(3, gn > 0 and strformat("Idle gaps, %.0f s in all", gs) or "Idle gaps", tostring(gn),
        qn and ("was " .. qn) or "", qn and (gn <= qn and "up" or "down") or "mute", ICON_IDLE)
    local rec, mechId = Recovery(p)
    local qrec = q and Recovery(q)
    if rec and mechId then
        v.stats:SetCell(4, "Back after " .. SpellName(p, tostring(mechId)), strformat("%.1f s", rec),
            qrec and strformat("was %.1f", qrec) or "", qrec and (rec <= qrec and "up" or "down") or "mute", tostring(mechId))
    else
        local avText, avKind = k.ChangeChip(k.Change(ps.av, qs.av), false)
        v.stats:SetCell(4, "Avoidable damage", k.Num(ps.av or 0), (q and avText) or "",
            (q and avKind) and (avKind == "ok" and "up" or (avKind == "live" and "down" or "mute")) or "mute", ICON_AVOID)
    end
end

local function FillUptimes(v, p)
    local k = K()
    local C = k.C
    local ups = Uptimes(p)
    local barW = UP_W - 26
    for i, u in ipairs(v.ups) do
        local e = i <= (v.upFit or #v.ups) and ups[i]
        if e then
            local name = SpellName(p, tostring(e.id))
            u.icon:SetSpell(tostring(e.id))
            u.name:SetText(name)
            local pct = min(1, e.pct)
            local c = (e.out and (pct >= 0.9 and C.up or (pct >= 0.75 and C.gold or C.down))) or C.blue
            if pct >= 0.995 or e.out or pct >= 0.5 then
                u.val:SetText(strformat("%.0f%%", pct * 100))
            else
                u.val:SetText(strformat("%d s", floor(e.secs + 0.5)))
            end
            local tc = e.out and c or C.fg
            u.val:SetTextColor(tc[1], tc[2], tc[3])
            u.bar:SetWidth(max(1, barW * pct))
            u.bar:SetColorTexture(c[1], c[2], c[3], 0.9)
            u.tipTitle = name
            u.tipLines = { { strformat("%s on %s: %d s of %s (%.0f%%)", e.out and "Your debuff" or "Buff",
                e.out and "the boss" or "you", floor(e.secs + 0.5), k.Clock(p.dur or 0), pct * 100), "SUB" } }
            u:Show()
        else
            u:Hide()
        end
    end
    v.upLab:SetShown(#ups > 0)
end

local function RefreshBoss(state)
    local v = bossView
    local p, q = cur.pull, cur.cmp
    local view = state.view or "damage"
    if not p then ns.MyLogUI:SetMode("runs"); return end
    FillBossBanner(v, state, p)
    v.seg:Select(view)
    v.cmpDD:Refresh()
    FillBossChart(v, view, p, q)
    local rows = AbilityRows(p, view)
    FillBossStats(v, view, p, q, rows)

    -- breakdown or timeline
    v.FitList()
    local timeline = cur.mode == "timeline"
    v.layout.tabs:SelectTab(timeline and "timeline" or "list")
    v.listHead:SetTitle(LIST_LABEL[view] or LIST_LABEL.damage)
    for _, f in ipairs(v.breakdown) do f:SetShown(not timeline) end
    v.timeline:SetShown(timeline)
    for _, u in ipairs(v.ups) do u:SetShown(false) end
    v.upLab:SetShown(false)
    if timeline then
        if v.timeline.pull ~= p then v.timeline:SetPull(p) else v.timeline:Draw() end
        return
    end
    local before = {}
    if q then for _, r in ipairs(AbilityRows(q, view)) do before[r.key] = r.amount end end
    local top = 0
    for _, r in ipairs(rows) do
        r.before = before[r.key]
        top = max(top, r.amount, r.before or 0)
    end
    local data = {}
    for i, r in ipairs(rows) do data[#data + 1] = { r = r, view = view, hasCmp = q ~= nil, top = top, rank = i } end
    v.list:SetData(data, true)
    FillUptimes(v, p)
end

---------------------------------------------------------------------------
-- Deaths screen
---------------------------------------------------------------------------

function MyLogDetail:DeathGroups(instKey)
    local groups, byKey = {}, {}
    for _, p in ipairs(Log():GetPulls()) do
        if (p.iid or p.zone) == instKey then
            for _, d in ipairs(p.deaths or {}) do
                local key = d.by or "?"
                local g = byKey[key]
                if not g then
                    g = { key = key, name = d.by and SpellName(p, d.by) or "Unknown", count = 0, last = 0, deaths = {},
                          boss = p.boss, avoidable = d.by and Log():IsAvoidable(d.by) or false }
                    byKey[key] = g
                    groups[#groups + 1] = g
                end
                g.count = g.count + 1
                if (p.at or 0) >= g.last then g.last = p.at or 0; g.boss = p.boss end
                table.insert(g.deaths, 1, { pull = p, death = d })
            end
        end
    end
    table.sort(groups, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.last > b.last
    end)
    return groups
end

-- The causes list: "All deaths" first, then every cause, most deaths first. A row: icon, name, the boss (and
-- "avoidable"), the count; the picked one in the shared selected look.
local RAIL_W = 270
local ICON_ALL = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"

local function PickCause(key)
    causeSel = key
    deathSel = nil
    ns.MyLogUI:Refresh()
end
function MyLogDetail:PickCause(key) PickCause(key) end

local function InitCause(row, data)
    local k = K()
    local ui = UI()
    if not row.name then
        ui:DecorateRow(row, { hover = true, selectable = true, rule = true })
        row.icon = k.Icon(row, 26)
        row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.name = ui:Text(row, "body", "TEXT", { width = RAIL_W - 20 - 42 - 40 })
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 42, -6)
        row.sub = ui:Text(row, "small", "SUB", { width = RAIL_W - 20 - 42 - 40 })
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.count = ui:Text(row, "page", "TEXT", { justify = "RIGHT" })
        row.count:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row:SetScript("OnClick", function(self)
            local d = self.__cdlData
            if d then PickCause(d.key) end
        end)
        ui:AttachTooltip(row, function(self, tip)
            local d = self.__cdlData
            if not d or d.all then return false end
            tip:AddLine(d.group.name, S:Color("GOLD"))
        end, function(self)
            local d = self.__cdlData
            local g = d and d.group
            if not g then return {} end
            local lines = { { strformat("Killed you %d time%s here, last on %s by %s.", g.count, g.count == 1 and "" or "s",
                k.Day(g.last), g.boss or "?"), "SUB" } }
            if g.avoidable then lines[#lines + 1] = { "Avoidable: you can stay out of this.", "WARN" } end
            return lines
        end)
    end
    local picked = data.key == causeSel
    if data.all then
        row.icon:SetIcon(ICON_ALL)
        row.name:SetText("All deaths")
        row.sub:SetText(data.causes == 1 and "1 cause" or (data.causes .. " causes"))
    else
        local g = data.group
        row.icon:SetSpell(g.key)
        row.name:SetText(g.name)
        row.sub:SetText(g.avoidable and (S:Wrap("WARN", "avoidable") .. " · " .. (g.boss or "?")) or (g.boss or "?"))
    end
    row.count:SetText(tostring(data.count))
    row.count:SetTextColor(S:Color(picked and "GOLD" or "TEXT"))
    row:SetSelected(picked)
end

local function InitStory(row, data)
    local k = K()
    local C = k.C
    local ui = UI()
    if not row.t then
        ui:DecorateRow(row, { hover = true, stripe = true })
        row.bg = row:CreateTexture(nil, "BACKGROUND", nil, 2)
        row.bg:SetAllPoints()
        ui:AddEdges(row, "BORDER", true)
        row.t = ui:Text(row, "small", "SUB", { justify = "RIGHT", width = 36 })
        row.t:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.icon = k.Icon(row, 16)
        row.icon:SetPoint("LEFT", row, "LEFT", 46, 0)
        row.what = ui:Text(row, "body", "TEXT")
        row.what:SetPoint("LEFT", row, "LEFT", 68, 0)
        row.what:SetPoint("RIGHT", row, "RIGHT", -150, 0)
        row.amount = ui:Text(row, "emph", "TEXT", { justify = "RIGHT" })
        row.amount:SetPoint("RIGHT", row, "RIGHT", -92, 0)
        row.hpWell = row:CreateTexture(nil, "ARTWORK")
        row.hpWell:SetColorTexture(S:Color("INSET"))
        row.hpWell:SetSize(40, 5)
        row.hpWell:SetPoint("RIGHT", row, "RIGHT", -46, 0)
        row.hpBar = row:CreateTexture(nil, "ARTWORK", nil, 1)
        row.hpBar:SetHeight(5)
        row.hpBar:SetPoint("LEFT", row.hpWell, "LEFT")
        row.hp = ui:Text(row, "small", "TEXT", { justify = "RIGHT" })
        row.hp:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    end
    local e, p, hpMax = data.e, data.pull, data.hpMax
    local kind, key, amount, hp, who, extra = e[2], e[3], e[4], e[5], e[6], e[7]
    local last = data.last
    local avoid = kind == "d" and Log():IsAvoidable(key)
    row:SetStripe(data.i)
    row.t:SetText(strformat("%.1fs", e[1]))
    row.t:SetTextColor(S:Color(last and "BAD" or "SUB"))
    row.icon:SetSpell(key)
    local name = SpellName(p, key)
    if kind == "d" then
        local tail = who and S:Wrap("SUB", "  from " .. who) or ""
        if last then tail = S:Wrap("SUB", "  killing blow") end
        row.what:SetText(S:Wrap(avoid and "WARN" or "BAD", name) .. tail .. (avoid and S:Wrap("WARN", "  avoidable") or ""))
        row.amount:SetText(S:Wrap("BAD", "-" .. k.Num(amount)))
    elseif kind == "h" then
        row.what:SetText(S:Wrap("OK", name) .. (who and S:Wrap("SUB", "  from " .. who) or ""))
        row.amount:SetText(S:Wrap("OK", "+" .. k.Num(amount)))
    elseif kind == "m" then
        row.what:SetText(S:Wrap("SUB", name .. " (" .. tostring(extra or "miss"):lower() .. ")"))
        row.amount:SetText(amount and S:Wrap("SUB", k.Num(amount)) or "")
    else
        row.what:SetText(S:Wrap("SUB", "You cast ") .. name)
        row.amount:SetText("")
    end
    local pct = (hpMax and hpMax > 0 and hp) and max(0, min(1, hp / hpMax)) or nil
    if last then
        row.hp:SetText(S:Wrap("BAD", "dead"))
        row.hpBar:Hide()
        row.hpWell:Hide()
    elseif pct then
        row.hp:SetText(strformat("%.0f%%", pct * 100))
        local c = pct > 0.6 and C.up or (pct > 0.3 and C.gold or C.down)
        row.hpBar:SetColorTexture(c[1], c[2], c[3], 1)
        row.hpBar:SetWidth(max(1, 40 * pct))
        row.hpBar:Show()
        row.hpWell:Show()
    else
        row.hp:SetText(hp and k.Num(hp) or "")
        row.hpBar:Hide()
        row.hpWell:Hide()
    end
    -- the killing blow on a red wash, an avoidable hit on an orange one with an edge
    if last then
        row.bg:SetColorTexture(C.down[1], C.down[2], C.down[3], 0.10)
        ui:SetEdgeColor(row, 0, 0, 0, 0)
    elseif avoid then
        row.bg:SetColorTexture(C.avoid[1], C.avoid[2], C.avoid[3], 0.06)
        ui:SetEdgeColor(row, C.avoid[1], C.avoid[2], C.avoid[3], 0.45)
    else
        row.bg:SetColorTexture(0, 0, 0, 0)
        ui:SetEdgeColor(row, 0, 0, 0, 0)
    end
end

local function BuildDeathsView(parent)
    local k = K()
    local ui = UI()
    local L = ui:CreateLayout("listdetail", parent, {
        toolbar = false, pad = 0, bottom = 0, width = S.INNER_W, listWidth = RAIL_W,
        banner = { size = "hero" },
    })
    local v = { layout = L }
    -- left: what kills me, as a list that scrolls when there are many causes
    v.causeLab = ui:CreateSectionHeader(L.list, "What kills you here")
    v.causeLab:SetPoint("TOPLEFT", L.list, "TOPLEFT", 0, 0)
    v.causeLab:SetPoint("TOPRIGHT", L.list, "TOPRIGHT", 0, 0)
    v.causes = ui:CreateScrollList(L.list, ROW_H, InitCause)
    v.causes.frame:SetPoint("TOPLEFT", v.causeLab, "BOTTOMLEFT", 0, -4)
    v.causes.frame:SetPoint("BOTTOMRIGHT", L.list, "BOTTOMRIGHT", 0, 0)

    -- right: the picked death's banner (boss, when, which of how many, Next / Previous) ...
    local b = L.banner
    b:SetActions({ { text = "Next", onClick = function() MyLogDetail:StepDeath(1) end },
        { text = "Previous", onClick = function() MyLogDetail:StepDeath(-1) end } })
    v.banner = b
    v.next, v.prev = b.actions[1], b.actions[2]
    v.pos = b.pill.fs

    -- ... its health line ...
    local body = L.body
    v.chartCard = ui:CreateCard(body, { tone = "inset" })
    v.chartCard:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    v.chartCard:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
    v.chartCard:SetHeight(132)
    v.chart = k.Chart(v.chartCard)
    v.chart:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 44, -6)
    v.chart:SetPoint("BOTTOMRIGHT", v.chartCard, "BOTTOMRIGHT", -16, 22)
    v.chart.inset = { l = 0, r = 0, t = 20, b = 6 }
    v.chart.fallback = { L.detailW - 60, 104 }
    v.yTop = ui:Text(v.chartCard, "small", "DIM", { text = "100%" })
    v.yTop:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 10, -24)
    v.xLabs = {}
    for i, txt in ipairs({ "-10 s", "-5 s", "death" }) do
        v.xLabs[i] = ui:Text(v.chartCard, "small", "DIM", { text = txt })
    end
    v.xLabs[1]:SetPoint("TOPLEFT", v.chart, "BOTTOMLEFT", 0, -4)
    v.xLabs[2]:SetPoint("TOP", v.chart, "BOTTOM", -8, -4)
    v.xLabs[3]:SetPoint("TOPRIGHT", v.chart, "BOTTOMRIGHT", 0, -4)

    -- ... and the story of its last 10 seconds
    v.story = ui:CreateScrollList(body, STORY_H, InitStory)
    v.story.frame:SetPoint("TOPLEFT", v.chartCard, "BOTTOMLEFT", 0, -S.GAP)
    v.story.frame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
    return v
end

-- The deaths shown (the picked cause's, or all), newest first.
local function DeathList(groups)
    local list = {}
    for _, g in ipairs(groups) do
        if not causeSel or g.key == causeSel then
            for _, e in ipairs(g.deaths) do list[#list + 1] = e end
        end
    end
    table.sort(list, function(a, b)
        if (a.pull.at or 0) ~= (b.pull.at or 0) then return (a.pull.at or 0) > (b.pull.at or 0) end
        return a.death.t > b.death.t
    end)
    return list
end

function MyLogDetail:StepDeath(dir)
    local state = ns.MyLogUI:GetState()
    local list = DeathList(self:DeathGroups(state.inst))
    if #list == 0 then return end
    local at = 1
    for i, e in ipairs(list) do if deathSel and e.death == deathSel.death then at = i end end
    at = (at - 1 + dir) % #list + 1
    deathSel = list[at]
    ns.MyLogUI:Refresh()
end

-- The health line of a death's last seconds: { series, dots, ticks, hover } for the chart.
local function DeathChart(p, d, hpMax)
    local k = K()
    local C = k.C
    local ring = d.ring or {}
    local pts = {}
    local first = ring[1]
    if first then
        local before = (first[5] or 0)
        if first[2] == "d" then before = before + (first[4] or 0) elseif first[2] == "h" then before = before - (first[4] or 0) end
        pts[1] = { -10, before / hpMax * 100 }
    end
    for _, e in ipairs(ring) do
        if e[2] ~= "c" then pts[#pts + 1] = { e[1], (e[5] or 0) / hpMax * 100 } end
    end
    if #pts > 0 then pts[#pts][2] = 0 end
    for _, pt in ipairs(pts) do pt[2] = max(0, min(100, pt[2])) end
    local series = { { points = pts, color = C.up, width = 0.01, alpha = 0, fill = true, fillAlpha = 0.16 } }
    for i = 2, #pts do
        local hp = pts[i][2]
        local c = hp > 60 and C.up or (hp > 30 and C.gold or C.down)
        series[#series + 1] = { points = { pts[i - 1], pts[i] }, color = c, width = 2.5 }
    end
    local dots, ticks = {}, {}
    for i, e in ipairs(ring) do
        local kind = e[2]
        local y = (e[5] or 0) / hpMax * 100
        if i == #ring then y = 0 end
        if kind == "d" then
            local avoid = Log():IsAvoidable(e[3])
            dots[#dots + 1] = { e[1], min(100, y), avoid and C.avoid or C.down, i == #ring and 12 or 9, "-" .. k.Num(e[4]) }
        elseif kind == "h" then
            dots[#dots + 1] = { e[1], min(100, y), C.up, 9, "+" .. k.Num(e[4]) }
        elseif kind == "c" then
            ticks[#ticks + 1] = { e[1], C.mute, nil, h = 7 }
        end
    end
    return {
        x0 = -10, x1 = 0.3, y1 = 118, series = series, dots = dots, ticks = ticks,
        hover = function(x)
            local best, bd
            for _, e in ipairs(ring) do
                local dd = abs(e[1] - x)
                if not bd or dd < bd then best, bd = e, dd end
            end
            if not best or bd > 0.8 then return nil end
            local name = SpellName(p, best[3])
            local line = best[2] == "c" and ("You cast " .. name) or name
            return { { strformat("%.1f s", best[1]), C.mute }, { line, best[2] == "h" and C.up or (best[2] == "d" and C.down or C.fg) },
                { strformat("health %s", k.Num(best[5])), C.mute } }
        end,
    }
end

local function RefreshDeaths(state)
    local k = K()
    local v = deathsView
    local L = v.layout
    local groups = MyLogDetail:DeathGroups(state.inst)
    local found = false
    for _, g in ipairs(groups) do if g.key == causeSel then found = true end end
    if not found then causeSel = nil end
    -- the causes
    local total = 0
    for _, g in ipairs(groups) do total = total + g.count end
    local rows = {}
    if #groups > 0 then
        rows[1] = { all = true, count = total, causes = #groups }
        for _, g in ipairs(groups) do rows[#rows + 1] = { key = g.key, group = g, count = g.count } end
    end
    v.causes:SetData(rows, v.causesFor ~= state.inst)
    v.causesFor = state.inst
    local list = DeathList(groups)
    local inList = false
    for _, e in ipairs(list) do if deathSel and e.death == deathSel.death then inList = true end end
    if not inList then deathSel = list[1] end
    if not deathSel then
        L:ShowEmpty({ icon = ICON_ALL, title = "No deaths in your stored pulls here", text = "Keep it up." })
        return
    end
    L:HideEmpty()
    local p, d = deathSel.pull, deathSel.death
    local pos = 1
    for i, e in ipairs(list) do if e.death == d then pos = i end end
    local b = v.banner
    b:SetArt(ns.MyLogUI:InstanceArt(state.inst))
    b:SetTitle(p.boss or "?")
    local phase = p.kill and "the kill" or strformat("a wipe at %.0f%%", p.pct or 0)
    b:SetSub(strformat("%s · %s · died at %s", k.Day(p.at), phase, k.Clock(d.t)))
    b:SetPill("mute", strformat("%d of %d", pos, #list))

    -- the health line
    local ring = d.ring or {}
    local hpMax = d.hpMax
    if not hpMax or hpMax <= 0 then
        hpMax = 1
        for _, e in ipairs(ring) do hpMax = max(hpMax, e[5] or 0) end
    end
    v.chart:SetData(DeathChart(p, d, hpMax))

    -- the story
    local story = {}
    for i, e in ipairs(ring) do story[#story + 1] = { e = e, pull = p, hpMax = hpMax, last = i == #ring, i = i } end
    v.story:SetData(story, true)
end

---------------------------------------------------------------------------
-- Entry from MyLogUI:Refresh
---------------------------------------------------------------------------

function MyLogDetail:Refresh(state)
    panel = ns.MainFrame and ns.MainFrame:GetPanel("mylog")
    if not panel then return end
    if state.mode == "boss" then
        if not bossView then bossView = BuildBossView(panel) end
        if deathsView then deathsView.layout:Hide() end
        bossView.layout:Show()
        RefreshBoss(state)
    else
        if not deathsView then deathsView = BuildDeathsView(panel.board.body) end
        if bossView then bossView.layout:Hide() end
        deathsView.layout:Show()
        RefreshDeaths(state)
    end
end

function MyLogDetail:GetViews() return bossView, deathsView end

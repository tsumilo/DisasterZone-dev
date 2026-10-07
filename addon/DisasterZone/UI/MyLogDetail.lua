if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogDetail.lua", ...) then return end -- DisasterZone: My Log boss and death screens.
-- Two screens of the My Log page (UI/MyLogUI.lua), drawn with UI/MyLogKit.lua under its breadcrumb:
--   boss:   portrait and title; one pull (the night's kill, or its best wipe) against another pull of the boss (my
--           previous kill by default, any pull that still has its detail can be picked). A big chart: the view's
--           number every 5 seconds for both (gold with a soft fill, the other grey), the boss's mechanics as violet
--           bands, my idle gaps as red ticks on the baseline; hover it to read both pulls at that moment. Chips: active
--           time, idle gaps, how fast I was back after the boss's mechanics. Then where my damage (healing, or the
--           damage I took) came from: spell icon, a gold bar for this pull and a grey one for the other, the amount,
--           its share and its change. A line of uptimes along the bottom.
--   deaths: what kills me here (tiles, most deaths first, avoidable causes marked; a click picks one); a death's
--           last 10 seconds as a health line with its hits and heals as dots and my casts as ticks; under it the same
--           seconds as a story, line by line, with my health after each. Arrows step through the deaths.
local addonName, ns = ...

local MyLogDetail = ns:NewModule("MyLogDetail")

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat, strsub = string.format, string.sub

local PAD = 14
local ROW_H = 38
local STORY_H = 26

local panel, bossView, deathsView
local cur = { pull = nil, cmp = nil }
local deathSel, causeSel

local function UI() return ns.UI end
local function Log() return ns.MyLog end
local function K() return ns.MyLogKit end
local function Views() return ns.MyLogUI.VIEW_BY_KEY end

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
    if bossView then bossView:Hide() end
    if deathsView then deathsView:Hide() end
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

local function InitAbility(row, data)
    local k = K()
    local C = k.C
    if not row.name then
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetPoint("TOPLEFT", 0, -2)
        row.bg:SetPoint("BOTTOMRIGHT", 0, 2)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints(row.bg)
        row.hl:SetColorTexture(1, 1, 1, 0.035)
        row.rank = k.Text(row, "numXS")
        row.rank:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.rank:SetWidth(16)
        row.rank:SetJustifyH("RIGHT")
        row.rank:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        row.icon = k.Icon(row, 28)
        row.icon:SetPoint("LEFT", row, "LEFT", 26, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 64, -5)
        row.name:SetWidth(158)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
        row.sub:SetWidth(158)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)
        -- the track: a faint full-width groove, this pull's bar on it, the other pull's as a thin line under it
        row.track = row:CreateTexture(nil, "ARTWORK")
        row.track:SetPoint("LEFT", row, "LEFT", BAR_X, 2)
        row.track:SetSize(BAR_W, 6)
        row.track:SetColorTexture(1, 1, 1, 0.04)
        row.barNow = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.barNow:SetPoint("LEFT", row.track, "LEFT", 0, 0)
        row.barNow:SetHeight(6)
        row.barThen = row:CreateTexture(nil, "ARTWORK", nil, 2)
        row.barThen:SetPoint("TOPLEFT", row.track, "BOTTOMLEFT", 0, -3)
        row.barThen:SetHeight(2)
        row.barThen:SetColorTexture(0.55, 0.57, 0.61, 0.55)
        row.amount = k.Text(row, "numS")
        row.amount:SetFont(k.NUM_FONT, 14, "")
        row.amount:SetPoint("TOPRIGHT", row, "TOPRIGHT", -78, -5)
        row.amount:SetJustifyH("RIGHT")
        row.share = k.Text(row, "numXS")
        row.share:SetPoint("TOPRIGHT", row.amount, "BOTTOMRIGHT", 0, -1)
        row.share:SetJustifyH("RIGHT")
        row.share:SetTextColor(C.mute[1], C.mute[2], C.mute[3])
        row.chip = k.Chip(row, 16)
        row.chip:SetPoint("RIGHT", row, "RIGHT", -8, 0)
        row.av = k.Chip(row, 14)
        row:SetScript("OnEnter", function(self)
            local r = self.__cdlData and self.__cdlData.r
            if not r then return end
            local lines = { r.name }
            if r.src then lines[#lines + 1] = "From " .. r.src end
            lines[#lines + 1] = strformat("%s in %d hit%s, biggest %s", k.Num(r.amount), r.hits, r.hits == 1 and "" or "s", k.Num(r.max))
            if r.avoidable then lines[#lines + 1] = { "Avoidable: you can stay out of this.", C.avoid[1], C.avoid[2], C.avoid[3] } end
            if r.before then lines[#lines + 1] = { strformat("%s in the pull compared with.", k.Num(r.before)), C.mute[1], C.mute[2], C.mute[3] } end
            UI():SetTextTooltip(self, lines)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local r, view, top = data.r, data.view, data.top
    row.bg:SetColorTexture(C.card[1], C.card[2], C.card[3], data.odd and 1 or 0.55)
    row.rank:SetText(data.rank)
    row.icon:SetSpell(r.key)
    row.name:SetText(r.name .. (r.pet and k.Paint("  pet", C.dim) or ""))
    row.sub:SetText(AbilitySub(r, view))
    local scale = top > 0 and BAR_W / top or 0
    row.barNow:SetWidth(max(2, r.amount * scale))
    local col = view == "healing" and C.up or (view == "tanking" and (r.avoidable and C.avoid or C.down) or C.gold)
    k.Gradient(row.barNow, { col[1] * 0.45, col[2] * 0.45, col[3] * 0.45, 1 }, { col[1], col[2], col[3], 1 }, "HORIZONTAL")
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
        row.chip:Set(text, kind)
    elseif data.hasCmp then
        row.chip:Set("new", "mute")
    else
        row.chip:Set(nil)
    end
    if r.avoidable then
        row.av:Set("avoidable", "av")
        row.av:ClearAllPoints()
        row.av:SetPoint("LEFT", row.name, "LEFT", min(158, (row.name:GetStringWidth() or 60)) + 6, 0)
    else
        row.av:Set(nil)
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

local CHART_Y, CHART_H = -92, 170
local STATS_Y, STATS_H = CHART_Y - CHART_H - 8, 50
local LIST_LAB_Y = STATS_Y - STATS_H - 12          -- the row of tabs (Breakdown / Cast timeline) and the Uptime heading
local LIST_Y = LIST_LAB_Y - 30
-- the uptime column right of the abilities (the list's scroll bar sits in the gap)
local UP_W, COL_GAP, UP_ROW_H = 214, 24, 34
local ICON_ACTIVE = "Interface\\Icons\\INV_Misc_PocketWatch_01"
local ICON_IDLE = "Interface\\Icons\\Spell_Nature_Sleep"
local ICON_AVOID = "Interface\\Icons\\Spell_Fire_Fire"

local function BuildBossView(body)
    local k = K()
    local C = k.C
    local v = CreateFrame("Frame", nil, body)
    v:SetAllPoints(body)
    v.port = k.Portrait(v, 44)
    v.port:SetPoint("TOPLEFT", v, "TOPLEFT", PAD + 3, -38)
    v.title = k.Text(v, "title")
    v.title:SetPoint("TOPLEFT", v, "TOPLEFT", PAD + 60, -42)
    v.title:SetWidth(400)
    v.title:SetTextColor(C.fg[1], C.fg[2], C.fg[3])
    v.sub = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v.sub:SetPoint("TOPLEFT", v.title, "BOTTOMLEFT", 0, -5)
    v.sub:SetWidth(400)
    v.sub:SetJustifyH("LEFT")
    v.sub:SetWordWrap(false)
    v.cmpDD = UI():CreateSleekDropdown(v, 200,
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
    v.cmpDD:SetDefaultText("nothing to compare")
    v.cmpDD:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, -46)
    v.cmpLab = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v.cmpLab:SetPoint("RIGHT", v.cmpDD, "LEFT", -8, 0)
    v.cmpLab:SetText("compare with")

    v.chartCard = k.Card(v, { 0.059, 0.067, 0.086, 1 }, 0.06)
    v.chartCard:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, CHART_Y)
    v.chartCard:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, CHART_Y)
    v.chartCard:SetHeight(CHART_H)
    k.Gradient(v.chartCard.bg, { 0.051, 0.059, 0.075, 1 }, { 0.071, 0.082, 0.106, 1 })
    v.legend = k.Legend(v.chartCard)
    v.legend:SetPoint("TOPRIGHT", v.chartCard, "TOPRIGHT", -12, -8)
    v.chart = k.Chart(v.chartCard)
    v.chart:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 48, -26)
    v.chart:SetPoint("BOTTOMRIGHT", v.chartCard, "BOTTOMRIGHT", -14, 22)
    v.chart.inset = { l = 0, r = 0, t = 14, b = 0 }
    v.chart.fallback = { 710, 122 }
    v.xLabs = {}
    for i = 1, 4 do
        local lab = k.Text(v.chartCard, "numXS")
        lab:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        v.xLabs[i] = lab
    end
    -- the time labels at 0, 1/3, 2/3 and the end of the chart's width
    function v.PlaceX()
        local w = v.chart:GetWidth() or 0
        if w <= 0 then w = 710 end
        for i, lab in ipairs(v.xLabs) do
            lab:ClearAllPoints()
            lab:SetPoint(i == 4 and "TOPRIGHT" or (i == 1 and "TOPLEFT" or "TOP"), v.chart, "BOTTOMLEFT", w * (i - 1) / 3, -6)
        end
    end
    v.chart:HookScript("OnSizeChanged", function() v.PlaceX() end)

    v.stats = k.StatStrip(v, 4, STATS_H)
    v.stats:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, STATS_Y)
    v.stats:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, STATS_Y)

    -- the section's own tabs; the first one names what the list shows ("Damage by ability", ...)
    v.modeSeg = k.Tabs(v, { { key = "list", label = "Damage by ability" }, { key = "timeline", label = "Cast timeline" } },
        function(key) cur.mode = key; ns.MyLogUI:Refresh() end)
    v.modeSeg:SetPoint("TOPLEFT", v, "TOPLEFT", PAD - 8, LIST_LAB_Y)
    v.timeline = ns.MyLogTimeline:Create(v)
    v.timeline:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, LIST_Y)
    v.timeline:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -PAD, 6)
    v.timeline.fallback = { 772, 200 }
    v.list = UI():CreateScrollList(v, ROW_H, InitAbility)
    v.list.frame:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, LIST_Y)
    v.list.frame:SetPoint("TOPRIGHT", v, "TOPRIGHT", -(PAD + UP_W + COL_GAP) + 20, LIST_Y)
    -- whole rows only: a half row peeking out at the bottom looks broken
    local function fitList()
        local h = v:GetHeight() or 0
        if h <= 0 then h = 550 end          -- (the page's height in the 800 x 580 window, before layout)
        local avail = h + LIST_Y - 8
        v.list.frame:SetHeight(max(ROW_H, floor(avail / ROW_H) * ROW_H))
        v.upFit = max(1, floor(avail / UP_ROW_H))
    end
    fitList()
    v.FitList = fitList
    v:HookScript("OnSizeChanged", fitList)
    v.list:SetEmptyText("The detail of this pull aged out: only the newest pulls of a boss keep it.")

    -- uptimes: a column of icon, name, time and a thin bar (like My BiS's "still to get" list)
    v.upLab = k.Heading(v, "Uptime")
    v.upLab:SetPoint("LEFT", v, "TOPRIGHT", -(PAD + UP_W), LIST_LAB_Y - 11)
    v.ups = {}
    for i = 1, 10 do
        local u = CreateFrame("Frame", nil, v)
        u:SetSize(UP_W, UP_ROW_H)
        u:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, LIST_Y - (i - 1) * UP_ROW_H)
        u.icon = k.Icon(u, 24)
        u.icon:SetPoint("LEFT", u, "LEFT", 0, 0)
        u.name = u:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        u.name:SetPoint("TOPLEFT", u, "TOPLEFT", 34, -6)
        u.name:SetWidth(UP_W - 34 - 44)
        u.name:SetJustifyH("LEFT")
        u.name:SetWordWrap(false)
        u.val = k.Text(u, "numS")
        u.val:SetPoint("TOPRIGHT", u, "TOPRIGHT", 0, -5)
        u.val:SetJustifyH("RIGHT")
        u.well = u:CreateTexture(nil, "ARTWORK")
        u.well:SetColorTexture(1, 1, 1, 0.06)
        u.well:SetHeight(3)
        u.well:SetPoint("BOTTOMLEFT", u, "BOTTOMLEFT", 34, 7)
        u.well:SetPoint("BOTTOMRIGHT", u, "BOTTOMRIGHT", 0, 7)
        u.bar = u:CreateTexture(nil, "ARTWORK", nil, 1)
        u.bar:SetHeight(3)
        u.bar:SetPoint("LEFT", u.well, "LEFT")
        u:SetScript("OnEnter", function(self)
            if self.tip then UI():SetTextTooltip(self, self.tip) end
        end)
        u:SetScript("OnLeave", function() GameTooltip:Hide() end)
        v.ups[i] = u
    end
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

local function RefreshBoss(state)
    local k = K()
    local C = k.C
    local v = bossView
    local p, q = cur.pull, cur.cmp
    local view = state.view or "damage"
    local V = Views()[view]
    if not p then ns.MyLogUI:SetMode("runs"); return end
    ns.MyLogUI:Crumb(p.boss)
    v.port:SetBoss(p.boss, not p.kill)
    v.title:SetText(p.boss or "?")
    local bits = { p.kill and ("Kill in " .. k.Clock(p.dur)) or strformat("Wipe at %.1f%% after %s", p.pct or 0, k.Clock(p.dur)),
        k.Day(p.at) }
    if p.spec and p.spec ~= "" then bits[#bits + 1] = p.spec end
    if p.ilvl then bits[#bits + 1] = strformat("ilvl %.1f", p.ilvl) end
    v.sub:SetText(table.concat(bits, "   ·   "))
    v.cmpDD:Refresh()

    -- chart
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
    if q then series[#series + 1] = { points = b, color = { 0.62, 0.65, 0.70 }, width = 1.2, alpha = 0.55, smooth = smooth } end
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
    local marks = { 0, x1 / 3, x1 * 2 / 3, x1 }
    for i, lab in ipairs(v.xLabs) do lab:SetText(k.Clock(marks[i])) end
    v.PlaceX()
    local legend = { { C.gold, k.ShortDay(p.at) } }
    if q then legend[#legend + 1] = { { 0.62, 0.65, 0.70 }, k.ShortDay(q.at) } end
    if #bands > 0 then legend[#legend + 1] = { C.violet, "boss ability", "box" } end
    if #marks > 0 then legend[#legend + 1] = { C.gold, "boss yell", "tick" } end
    legend[#legend + 1] = { C.down, "idle 2 s+", "tick" }
    v.legend:Set(legend)

    -- the stats strip
    local ps, qs = p.s or {}, q and q.s or {}
    local metricNow, metricThen = Log():Metric(p, view), q and Log():Metric(q, view)
    local text, kind = k.ChangeChip(k.Change(metricNow, metricThen), view ~= "tanking")
    local rows = AbilityRows(p, view)
    v.stats:SetCell(1, V.metric, k.Num(metricNow), text or "", kind, rows[1] and rows[1].key)
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
        v.stats:SetCell(4, "Avoidable damage", k.Num(ps.av or 0),
            q and (select(1, k.ChangeChip(k.Change(ps.av, qs.av), false)) or "") or "",
            q and (select(2, k.ChangeChip(k.Change(ps.av, qs.av), false)) or "mute") or "mute", ICON_AVOID)
    end

    -- breakdown or timeline
    v.FitList()
    local timeline = cur.mode == "timeline"
    v.modeSeg:SetLabel("list", view == "healing" and "Healing by ability" or (view == "tanking" and "What hit you"
        or "Damage by ability"))
    v.modeSeg:SetSelected(timeline and "timeline" or "list")
    v.list.frame:SetShown(not timeline)
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
    for i, r in ipairs(rows) do data[#data + 1] = { r = r, view = view, hasCmp = q ~= nil, top = top, rank = i, odd = i % 2 == 1 } end
    v.list:SetData(data, true)

    -- uptimes
    local ups = Uptimes(p)
    local barW = UP_W - 34
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
            u.val:SetTextColor((e.out and c or C.fg)[1], (e.out and c or C.fg)[2], (e.out and c or C.fg)[3])
            u.bar:SetWidth(max(1, barW * pct))
            u.bar:SetColorTexture(c[1], c[2], c[3], 0.9)
            u.tip = { name, { strformat("%s on %s: %d s of %s (%.0f%%)", e.out and "Your debuff" or "Buff",
                e.out and "the boss" or "you", floor(e.secs + 0.5), k.Clock(p.dur or 0), pct * 100), C.mute[1], C.mute[2], C.mute[3] } }
            u:Show()
        else
            u:Hide()
        end
    end
    v.upLab:SetShown(#ups > 0)
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

local function NewCauseTile(parent)
    local k = K()
    local t = CreateFrame("Button", nil, parent)
    t:SetHeight(58)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    UI():AddEdges(t, "BORDER", true)
    t.icon = k.Icon(t, 32)
    t.icon:SetPoint("LEFT", t, "LEFT", 12, 0)
    t.name = t:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t.name:SetPoint("TOPLEFT", t, "TOPLEFT", 54, -12)
    t.name:SetJustifyH("LEFT")
    t.name:SetWordWrap(false)
    t.av = k.Chip(t, 14)
    t.av:SetPoint("LEFT", t.name, "RIGHT", 6, 0)
    t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    t.sub:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -4)
    t.sub:SetJustifyH("LEFT")
    t.sub:SetWordWrap(false)
    t.count = k.Text(t, "hero")
    t.count:SetFont(k.NUM_FONT, 28, "")
    t.count:SetPoint("RIGHT", t, "RIGHT", -14, 0)
    t.count:SetJustifyH("RIGHT")
    t:SetScript("OnClick", function(self)
        if causeSel == (self.group and self.group.key) then causeSel = nil else causeSel = self.group and self.group.key end
        deathSel = nil
        ns.MyLogUI:Refresh()
    end)
    t:SetScript("OnEnter", function(self)
        if not self.group then return end
        UI():SetTextTooltip(self, { self.group.name, causeSel == self.group.key and "Click to show every death again."
            or "Click to show only these deaths." })
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return t
end

local function InitStory(row, data)
    local k = K()
    local C = k.C
    if not row.t then
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetPoint("TOPLEFT", 0, -1)
        row.bg:SetPoint("BOTTOMRIGHT", 0, 1)
        UI():AddEdges(row, "BORDER", true)
        row.t = k.Text(row, "numXS")
        row.t:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.t:SetWidth(40)
        row.t:SetJustifyH("RIGHT")
        row.icon = k.Icon(row, 16)
        row.icon:SetPoint("LEFT", row, "LEFT", 56, 0)
        row.what = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.what:SetPoint("LEFT", row, "LEFT", 80, 0)
        row.what:SetPoint("RIGHT", row, "RIGHT", -190, 0)
        row.what:SetJustifyH("LEFT")
        row.what:SetWordWrap(false)
        row.amount = k.Text(row, "numS")
        row.amount:SetPoint("RIGHT", row, "RIGHT", -110, 0)
        row.amount:SetJustifyH("RIGHT")
        row.hpWell = row:CreateTexture(nil, "ARTWORK")
        row.hpWell:SetColorTexture(C.well[1], C.well[2], C.well[3], 1)
        row.hpWell:SetSize(46, 5)
        row.hpWell:SetPoint("RIGHT", row, "RIGHT", -52, 0)
        row.hpBar = row:CreateTexture(nil, "ARTWORK", nil, 1)
        row.hpBar:SetHeight(5)
        row.hpBar:SetPoint("LEFT", row.hpWell, "LEFT")
        row.hp = k.Text(row, "numXS")
        row.hp:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.hp:SetJustifyH("RIGHT")
    end
    local e, p, hpMax = data.e, data.pull, data.hpMax
    local kind, key, amount, hp, who, extra = e[2], e[3], e[4], e[5], e[6], e[7]
    local last = data.last
    local avoid = kind == "d" and Log():IsAvoidable(key)
    local tc = last and C.down or C.mute
    row.t:SetText(strformat("%.1fs", e[1]))
    row.t:SetTextColor(tc[1], tc[2], tc[3])
    row.icon:SetSpell(key)
    local name = SpellName(p, key)
    if kind == "d" then
        local tail = who and k.Paint("  from " .. who, C.mute) or ""
        if last then tail = k.Paint("  killing blow", C.mute) end
        row.what:SetText(k.Paint(name, avoid and C.avoid or C.down) .. tail .. (avoid and k.Paint("   avoidable", C.avoid) or ""))
        row.amount:SetText(k.Paint("-" .. k.Num(amount), C.down))
    elseif kind == "h" then
        row.what:SetText(k.Paint(name, C.up) .. (who and k.Paint("  from " .. who, C.mute) or ""))
        row.amount:SetText(k.Paint("+" .. k.Num(amount), C.up))
    elseif kind == "m" then
        row.what:SetText(k.Paint(name .. " (" .. tostring(extra or "miss"):lower() .. ")", C.mute))
        row.amount:SetText(amount and k.Paint(k.Num(amount), C.mute) or "")
    else
        row.what:SetText(k.Paint("You cast ", C.mute) .. name)
        row.amount:SetText("")
    end
    local pct = (hpMax and hpMax > 0 and hp) and max(0, min(1, hp / hpMax)) or nil
    if last then
        row.hp:SetText(k.Paint("dead", C.down))
        row.hpBar:Hide()
        row.hpWell:Hide()
    elseif pct then
        row.hp:SetText(strformat("%.0f%%", pct * 100))
        local c = pct > 0.6 and C.up or (pct > 0.3 and C.gold or C.down)
        row.hpBar:SetColorTexture(c[1], c[2], c[3], 1)
        row.hpBar:SetWidth(max(1, 46 * pct))
        row.hpBar:Show()
        row.hpWell:Show()
    else
        row.hp:SetText(hp and k.Num(hp) or "")
        row.hpBar:Hide()
        row.hpWell:Hide()
    end
    if last then
        row.bg:SetColorTexture(C.down[1], C.down[2], C.down[3], 0.10)
        UI():SetEdgeColor(row, 0, 0, 0, 0)
    elseif avoid then
        row.bg:SetColorTexture(C.avoid[1], C.avoid[2], C.avoid[3], 0.06)
        UI():SetEdgeColor(row, C.avoid[1], C.avoid[2], C.avoid[3], 0.45)
    else
        row.bg:SetColorTexture(C.card[1], C.card[2], C.card[3], data.odd and 1 or 0)
        UI():SetEdgeColor(row, 0, 0, 0, 0)
    end
end

local function BuildDeathsView(body)
    local k = K()
    local C = k.C
    local v = CreateFrame("Frame", nil, body)
    v:SetAllPoints(body)
    v.causeLab = k.Label(v, "What kills you here")
    v.causeLab:SetPoint("TOPLEFT", v, "TOPLEFT", PAD + 2, -38)
    v.tiles = {}
    for i = 1, 3 do v.tiles[i] = NewCauseTile(v) end
    v.none = k.Text(v, "titleS")
    v.none:SetPoint("TOP", v, "TOP", 0, -140)
    v.none:SetJustifyH("CENTER")
    v.none:SetTextColor(C.mute[1], C.mute[2], C.mute[3])

    v.title = k.Text(v, "titleS")
    v.title:SetPoint("TOPLEFT", v, "TOPLEFT", PAD + 2, -128)
    v.title:SetTextColor(C.fg[1], C.fg[2], C.fg[3])
    v.titleSub = v:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v.titleSub:SetPoint("LEFT", v.title, "RIGHT", 8, -1)
    v.next = UI():CreateArrowButton(v, true, 22, 20, function() MyLogDetail:StepDeath(1) end)
    v.next:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, -126)
    v.pos = k.Text(v, "numXS")
    v.pos:SetPoint("RIGHT", v.next, "LEFT", -8, 0)
    v.pos:SetTextColor(C.mute[1], C.mute[2], C.mute[3])
    v.prev = UI():CreateArrowButton(v, false, 22, 20, function() MyLogDetail:StepDeath(-1) end)
    v.prev:SetPoint("RIGHT", v.pos, "LEFT", -8, 0)

    v.chartCard = k.Card(v, { 0.067, 0.078, 0.102, 1 }, 0.07)
    v.chartCard:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, -152)
    v.chartCard:SetPoint("TOPRIGHT", v, "TOPRIGHT", -PAD, -152)
    v.chartCard:SetHeight(132)
    v.chart = k.Chart(v.chartCard)
    v.chart:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 44, -6)
    v.chart:SetPoint("BOTTOMRIGHT", v.chartCard, "BOTTOMRIGHT", -16, 22)
    v.chart.inset = { l = 0, r = 0, t = 20, b = 6 }
    v.chart.fallback = { 712, 104 }
    v.yTop = k.Label(v.chartCard, "100%")
    v.yTop:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    v.yTop:SetPoint("TOPLEFT", v.chartCard, "TOPLEFT", 10, -24)
    v.xLabs = {}
    for i, txt in ipairs({ "-10 s", "-5 s", "death" }) do
        local lab = k.Label(v.chartCard, txt)
        lab:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
        v.xLabs[i] = lab
    end

    v.story = UI():CreateScrollList(v, STORY_H, InitStory)
    v.story.frame:SetPoint("TOPLEFT", v, "TOPLEFT", PAD, -292)
    v.story.frame:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -PAD + 20, 8)
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

local function RefreshDeaths(state)
    local k = K()
    local C = k.C
    local v = deathsView
    ns.MyLogUI:Crumb("Deaths")
    local groups = MyLogDetail:DeathGroups(state.inst)
    local found = false
    for _, g in ipairs(groups) do if g.key == causeSel then found = true end end
    if not found then causeSel = nil end
    -- cause tiles: the top three
    local w = ((v:GetWidth() or 800) - 2 * PAD - 16) / 3
    if w <= 0 then w = 252 end
    for i, t in ipairs(v.tiles) do
        local g = groups[i]
        if g then
            t.group = g
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", v, "TOPLEFT", PAD + (i - 1) * (w + 8), -54)
            t:SetWidth(w)
            t.icon:SetSpell(g.key)
            t.name:SetText(g.name)
            t.name:SetWidth(min(w - 140, (t.name:GetStringWidth() or 80) + 2))
            t.av:Set(g.avoidable and "avoidable" or nil, "av")
            t.sub:SetText(strformat("%s · %s", g.boss or "?", k.ShortDay(g.last)))
            t.sub:SetWidth(w - 96)
            t.count:SetText(tostring(g.count))
            local picked = causeSel == g.key
            local hot = picked or (not causeSel and i == 1)
            if hot then
                k.Gradient(t.bg, { C.down[1] * 0.18 + C.card[1] * 0.82, C.down[2] * 0.18 + C.card[2] * 0.82, C.down[3] * 0.18 + C.card[3] * 0.82, 1 },
                    { C.card[1], C.card[2], C.card[3], 1 }, "HORIZONTAL")
            else
                t.bg:SetTexture(nil)
                t.bg:SetColorTexture(C.card[1], C.card[2], C.card[3], 1)
            end
            if hot then UI():SetEdgeColor(t, C.down[1], C.down[2], C.down[3], picked and 0.65 or 0.35)
            else UI():SetEdgeColor(t, 1, 1, 1, 0.07) end
            local cc = hot and C.down or C.fg
            t.count:SetTextColor(cc[1], cc[2], cc[3])
            t:Show()
        else
            t:Hide()
        end
    end
    local list = DeathList(groups)
    local inList = false
    for _, e in ipairs(list) do if deathSel and e.death == deathSel.death then inList = true end end
    if not inList then deathSel = list[1] end
    local has = deathSel ~= nil
    v.none:SetShown(not has)
    v.none:SetText(has and "" or "No deaths in your stored pulls here. Keep it up.")
    for _, f in ipairs({ v.title, v.titleSub, v.next, v.prev, v.pos, v.chartCard, v.story.frame, v.causeLab }) do f:SetShown(has) end
    if not has then return end
    local p, d = deathSel.pull, deathSel.death
    local pos = 1
    for i, e in ipairs(list) do if e.death == d then pos = i end end
    v.title:SetText(p.boss or "?")
    local phase = p.kill and "the kill" or strformat("a wipe at %.0f%%", p.pct or 0)
    v.titleSub:SetText(strformat("· %s · %s · died at %s", k.Day(p.at), phase, k.Clock(d.t)))
    v.pos:SetText(strformat("%d of %d", pos, #list))

    -- the health line
    local ring = d.ring or {}
    local hpMax = d.hpMax
    if not hpMax or hpMax <= 0 then
        hpMax = 1
        for _, e in ipairs(ring) do hpMax = max(hpMax, e[5] or 0) end
    end
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
    v.chart:SetData({
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
    })
    v.xLabs[1]:ClearAllPoints()
    v.xLabs[1]:SetPoint("TOPLEFT", v.chart, "BOTTOMLEFT", 0, -4)
    v.xLabs[2]:ClearAllPoints()
    v.xLabs[2]:SetPoint("TOP", v.chart, "BOTTOM", -8, -4)
    v.xLabs[3]:ClearAllPoints()
    v.xLabs[3]:SetPoint("TOPRIGHT", v.chart, "BOTTOMRIGHT", 0, -4)

    -- the story
    local rows = {}
    for i, e in ipairs(ring) do rows[#rows + 1] = { e = e, pull = p, hpMax = hpMax, last = i == #ring, odd = i % 2 == 1 } end
    v.story:SetData(rows, true)
end

---------------------------------------------------------------------------
-- Entry from MyLogUI:Refresh
---------------------------------------------------------------------------

function MyLogDetail:Refresh(state)
    panel = ns.MainFrame and ns.MainFrame:GetPanel("mylog")
    if not panel then return end
    if not bossView then bossView = BuildBossView(panel.body) end
    if not deathsView then deathsView = BuildDeathsView(panel.body) end
    bossView:SetShown(state.mode == "boss")
    deathsView:SetShown(state.mode == "deaths")
    if state.mode == "boss" then RefreshBoss(state) else RefreshDeaths(state) end
end

function MyLogDetail:GetViews() return bossView, deathsView end

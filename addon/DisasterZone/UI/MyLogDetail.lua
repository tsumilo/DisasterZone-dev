if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogDetail.lua", ...) then return end -- DisasterZone: My Log boss detail and deaths.
-- Two views of the My Log page (UI/MyLogUI.lua), drawn in its body under the top bar:
--   boss:   one pull of a boss (the run's kill, or its best wipe) against another pull of that boss (my previous
--           kill by default; any pull that still has its detail can be picked): the view's number every 5 seconds
--           for both (the picked pull gold, the other grey) with my idle gaps marked red, four numbers with their
--           change, and a table of abilities (damage: mine and my pets'; healing: heals and shields; tanking: what
--           hit me, avoidable ones marked) with each one's change
--   deaths: every death in the instance's stored pulls, grouped by what killed me (most often first); a death shows
--           its last 10 seconds: hits, heals, my casts, with my health after each
local addonName, ns = ...

local MyLogDetail = ns:NewModule("MyLogDetail")

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat, strsub = string.format, string.sub

local HEAD_Y = -66          -- the boss view's title row
local CHART_Y, CHART_H = -96, 112
local MINI_Y, MINI_H = -232, 50
local TABLE_Y = -292
local ROW_H = 22
local DROW_H = 22
local LEFT_W = 300
local AVOID = { 1, 0.62, 0.25 }

local panel, bossView, deathsView
local cur = { pull = nil, cmp = nil }        -- the pulls shown in the boss view
local deathSel                                -- the death shown in the deaths view

local function UI() return ns.UI end
local function Log() return ns.MyLog end
local function F() return ns.MyLogUI.F end

local function SpellName(p, key)
    local n = p and p.names and p.names[key]
    if n then return n end
    local id = tonumber((tostring(key):gsub("^p", "")))
    if id and GetSpellInfo then
        local name = GetSpellInfo(id)
        if name then return name end
    end
    return tostring(key)
end

local function Clock(sec)
    sec = floor((sec or 0) + 0.5)
    return strformat("%d:%02d", floor(sec / 60), sec % 60)
end

local function BossKey(p) return p.enc or p.boss end

---------------------------------------------------------------------------
-- Picking the pulls
---------------------------------------------------------------------------

-- Pulls of the boss (newest first) that still have their detail.
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
    local f = F()
    local what = p.kill and "kill" or strformat("wipe %.0f%%", p.pct or 0)
    return strformat("%s · %s · %s", f.Day(p.at), what, Clock(p.dur))
end

-- The pull compared with by default: the kill before it (same spec first), else the pull before it.
local function DefaultCompare(p)
    local list = DetailPulls(BossKey(p))
    local same, any, before
    for _, q in ipairs(list) do
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
        -- no kill: the best wipe of the run
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
    ns.MyLogUI:SetMode("boss")
end

function MyLogDetail:HideAll()
    if bossView then bossView:Hide() end
    if deathsView then deathsView:Hide() end
end

---------------------------------------------------------------------------
-- Chart: per-second values in 5 s buckets, two pulls, idle gaps of the first
---------------------------------------------------------------------------

local TL_FIELD = { damage = "d", healing = "h", tanking = "t" }

local function Series(p, view)
    local tl = p and p.tl and p.tl[TL_FIELD[view] or "d"]
    if not tl then return {}, 0 end
    local n = floor((p.dur or 0) / 5) + 1
    local out, hi = {}, 0
    for i = 1, n do
        local v = (tl[i] or 0) / 5
        out[i] = v
        if v > hi then hi = v end
    end
    return out, hi
end

local function NewChart(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(1, 1, 1, 0.03)
    c.grid = {}
    for i = 1, 3 do
        local g = c:CreateTexture(nil, "BORDER")
        g:SetColorTexture(1, 1, 1, 0.06)
        g:SetHeight(1)
        c.grid[i] = g
    end
    c.yTop = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.yTop:SetPoint("TOPLEFT", c, "TOPLEFT", 4, -3)
    c.xEnd = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.xEnd:SetPoint("TOPRIGHT", c, "BOTTOMRIGHT", 0, -2)
    c.xMid = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.xMid:SetPoint("TOP", c, "BOTTOM", 0, -2)
    c.xStart = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.xStart:SetPoint("TOPLEFT", c, "BOTTOMLEFT", 0, -2)
    c.xStart:SetText("0:00")
    c.lines = { {}, {} }
    c.bands = {}
    function c:Line(set, i)
        local l = self.lines[set][i]
        if not l then
            l = self:CreateLine(nil, set == 1 and "OVERLAY" or "ARTWORK")
            l:SetThickness(set == 1 and 2 or 1.5)
            self.lines[set][i] = l
        end
        return l
    end
    function c:Band(i)
        local b = self.bands[i]
        if not b then
            b = self:CreateTexture(nil, "BORDER")
            b:SetColorTexture(0.89, 0.42, 0.36, 0.16)
            self.bands[i] = b
        end
        return b
    end
    function c:Draw(a, b, gaps, durMax)
        local w, h = self:GetWidth() or 0, self:GetHeight() or 0
        if w <= 0 then w = 760 end
        if h <= 0 then h = CHART_H end
        for set = 1, 2 do for _, l in ipairs(self.lines[set]) do l:Hide() end end
        for _, band in ipairs(self.bands) do band:Hide() end
        for i, g in ipairs(self.grid) do
            g:ClearAllPoints()
            g:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -h * i / 4)
            g:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -h * i / 4)
        end
        local hi = 1
        for _, s in ipairs({ a, b }) do for _, v in ipairs(s) do if v > hi then hi = v end end end
        hi = hi * 1.08
        durMax = max(durMax or 5, 5)
        local function x(t) return t / durMax * w end
        local function y(v) return 2 + v / hi * (h - 6) end
        for set, s in ipairs({ a, b }) do
            local color = set == 1 and F().GOLD or F().GREY
            for i = 2, #s do
                local l = self:Line(set, i - 1)
                l:SetColorTexture(color[1], color[2], color[3], set == 1 and 1 or 0.8)
                l:SetStartPoint("BOTTOMLEFT", self, x((i - 2) * 5), y(s[i - 1]))
                l:SetEndPoint("BOTTOMLEFT", self, x((i - 1) * 5), y(s[i]))
                l:Show()
            end
        end
        for i, gap in ipairs(gaps or {}) do
            local band = self:Band(i)
            band:ClearAllPoints()
            band:SetPoint("TOPLEFT", self, "TOPLEFT", x(gap.at), 0)
            band:SetSize(max(1, x(gap.len)), h)
            band:Show()
        end
        self.yTop:SetText(F().Num(hi / 1.08) .. "/s")
        self.xMid:SetText(Clock(durMax / 2))
        self.xEnd:SetText(Clock(durMax))
    end
    return c
end

---------------------------------------------------------------------------
-- Ability rows
---------------------------------------------------------------------------

-- Columns: x, width, justify
local AC = {
    name = { 8, 236, "LEFT" }, casts = { 250, 44 }, hits = { 300, 44 }, amount = { 350, 78 }, share = { 434, 46 },
    crit = { 486, 54 }, avg = { 546, 62 }, max = { 614, 62 }, change = { 682, 70 },
}
local HEAD = {
    damage = { amount = "Damage", crit = "Crit", avg = "Average" },
    healing = { amount = "Healing", crit = "Crit", avg = "Overheal" },
    tanking = { amount = "Taken", crit = "Crit", avg = "Average" },
}

-- Rows for a pull: { key, name, casts, hits, amount, share (0..1), crit (0..1), avg, max, avoidable, extra }
local function AbilityRows(p, view)
    local out, total = {}, 0
    if not p or not p.dmg then return out, 0 end
    local function add(key, st, amount, opts)
        opts = opts or {}
        local id = tonumber((tostring(key):gsub("^p", "")))
        local r = {
            key = key, name = SpellName(p, key) .. (opts.suffix or ""), hits = st.n or 0, amount = amount,
            crit = (st.n or 0) > 0 and (st.c or 0) / st.n or nil, max = st.mx,
            casts = (strsub(tostring(key), 1, 1) ~= "p" and id and p.casts and p.casts[id]) or nil,
            avoidable = opts.avoidable, src = st.src,
        }
        r.avg = opts.avg or ((st.n or 0) > 0 and amount / st.n or nil)
        out[#out + 1] = r
        total = total + amount
    end
    if view == "healing" then
        for key, st in pairs(p.heal) do
            local eff = st.a or 0
            add(key, st, eff, { avg = (eff + (st.oh or 0)) > 0 and (st.oh or 0) / (eff + (st.oh or 0)) or 0 })
        end
        for key, st in pairs(p.shield) do add(key, st, st.a or 0, { suffix = " (shield)", avg = 0 }) end
    elseif view == "tanking" then
        for key, st in pairs(p.taken) do
            local amount = (st.a or 0) - (st.o or 0) + (st.ab or 0) + (st.mab or 0)
            add(key, st, amount, { avoidable = Log():IsAvoidable(key) })
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

local function Cell(row, col, font)
    local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint("LEFT", row, "LEFT", col[1], 0)
    fs:SetWidth(col[2])
    fs:SetJustifyH(col[3] or "RIGHT")
    fs:SetWordWrap(false)
    return fs
end

local function InitAbility(row, data)
    if not row.name then
        row.bar = row:CreateTexture(nil, "BACKGROUND")
        row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        for k, col in pairs(AC) do row[k] = Cell(row, col, k == "name" and "GameFontHighlight" or nil) end
        row:SetScript("OnEnter", function(self)
            local r = self.__cdlData and self.__cdlData.r
            if not r then return end
            local lines = { r.name }
            if r.src then lines[#lines + 1] = "From " .. r.src end
            if r.avoidable then lines[#lines + 1] = { "Avoidable: you can stay out of this.", AVOID[1], AVOID[2], AVOID[3] } end
            if r.before then
                lines[#lines + 1] = strformat("%s in the pull compared with (was %s).", F().Num(r.amount), F().Num(r.before))
            end
            UI():SetTextTooltip(self, lines)
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local r, view = data.r, data.view
    local f = F()
    local w = (row:GetWidth() or 760)
    row.bar:SetWidth(max(1, w * (r.share or 0)))
    local c = view == "healing" and f.UP or (view == "tanking" and f.DOWN or f.BLUE)
    row.bar:SetColorTexture(c[1], c[2], c[3], 0.12)
    local name = r.name
    if r.avoidable then name = name .. "  " .. f.Hex(AVOID) .. "avoidable|r" end
    row.name:SetText(name)
    row.casts:SetText(r.casts and tostring(r.casts) or "")
    row.hits:SetText(tostring(r.hits or 0))
    row.amount:SetText(f.Num(r.amount))
    row.share:SetText(strformat("%.1f%%", (r.share or 0) * 100))
    row.crit:SetText(r.crit and r.crit > 0 and strformat("%.1f%%", r.crit * 100) or "")
    if view == "healing" then
        row.avg:SetText(r.avg and r.avg > 0 and strformat("%.0f%%", r.avg * 100) or "")
    else
        row.avg:SetText(r.avg and f.Num(r.avg) or "")
    end
    row.max:SetText(r.max and f.Num(r.max) or "")
    if r.before then
        row.change:SetText(f.ChangeText(f.Change(r.amount, r.before), view ~= "tanking"))
    elseif data.hasCmp then
        row.change:SetText(f.Hex(f.GREY) .. "new|r")
    else
        row.change:SetText("")
    end
end

---------------------------------------------------------------------------
-- Boss view
---------------------------------------------------------------------------

local function BuildBossView(body)
    local v = CreateFrame("Frame", nil, body)
    v:SetAllPoints(body)
    local f = F()
    v.back = UI():CreateSleekButton(v, "Back", 60, 22, function() ns.MyLogUI:SetMode("runs") end)
    v.back:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD, HEAD_Y)
    v.title = v:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    v.title:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD + 72, HEAD_Y - 3)
    v.title:SetWidth(440)
    v.title:SetJustifyH("LEFT")
    v.title:SetWordWrap(false)
    v.cmpDD = UI():CreateSleekDropdown(v, 230,
        function()
            local out = {}
            if not cur.pull then return out end
            for _, q in ipairs(DetailPulls(BossKey(cur.pull))) do
                if q ~= cur.pull then out[#out + 1] = { value = q.id, text = "vs " .. PullLabel(q) } end
            end
            return out
        end,
        function() return cur.cmp and cur.cmp.id end,
        function(id)
            for _, q in ipairs(DetailPulls(BossKey(cur.pull))) do if q.id == id then cur.cmp = q end end
            ns.MyLogUI:Refresh()
        end)
    v.cmpDD:SetDefaultText("Nothing to compare with")
    v.cmpDD:SetPoint("TOPRIGHT", v, "TOPRIGHT", -f.PAD, HEAD_Y)

    v.chart = NewChart(v)
    v.chart:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD, CHART_Y)
    v.chart:SetPoint("TOPRIGHT", v, "TOPRIGHT", -f.PAD, CHART_Y)
    v.chart:SetHeight(CHART_H)
    v.legend = v:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v.legend:SetPoint("TOPRIGHT", v.chart, "BOTTOMRIGHT", -40, -2)
    v.legend:SetJustifyH("RIGHT")

    v.tiles = {}
    for i = 1, 4 do v.tiles[i] = f.NewTile(v) end
    local function place()
        local w = (v:GetWidth() or 780) - 2 * f.PAD
        if w <= 0 then w = 760 end
        local tw = (w - 3 * 8) / 4
        for i, t in ipairs(v.tiles) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD + (i - 1) * (tw + 8), MINI_Y)
            t:SetWidth(tw)
        end
    end
    place()
    v:HookScript("OnSizeChanged", place)

    local head = UI():CreateColumnHeader(v, 20)
    head:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD, TABLE_Y)
    head:SetPoint("TOPRIGHT", v, "TOPRIGHT", -f.PAD - 20, TABLE_Y)
    v.heads = {}
    v.heads.name = head:AddColumn("Ability", AC.name[1], AC.name[2]).label
    v.heads.casts = head:AddColumn("Casts", AC.casts[1], AC.casts[2], { justify = "RIGHT" }).label
    v.heads.hits = head:AddColumn("Hits", AC.hits[1], AC.hits[2], { justify = "RIGHT" }).label
    v.heads.amount = head:AddColumn("Damage", AC.amount[1], AC.amount[2], { justify = "RIGHT" }).label
    v.heads.share = head:AddColumn("%", AC.share[1], AC.share[2], { justify = "RIGHT" }).label
    v.heads.crit = head:AddColumn("Crit", AC.crit[1], AC.crit[2], { justify = "RIGHT" }).label
    v.heads.avg = head:AddColumn("Average", AC.avg[1], AC.avg[2], { justify = "RIGHT" }).label
    v.heads.max = head:AddColumn("Biggest", AC.max[1], AC.max[2], { justify = "RIGHT" }).label
    v.heads.change = head:AddColumn("Change", AC.change[1], AC.change[2], { justify = "RIGHT" }).label

    v.list = UI():CreateScrollList(v, ROW_H, InitAbility)
    v.list.frame:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD, TABLE_Y - 22)
    v.list.frame:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -f.PAD, f.PAD)
    v.list:SetEmptyText("The detail of this pull aged out: only the newest pulls of a boss keep it.")
    return v
end

local function GapsTotal(p)
    local n, s = 0, 0
    for _, g in ipairs(p and p.gaps or {}) do n = n + 1; s = s + (g.len or 0) end
    return n, s
end

local function RefreshBoss(state)
    local v = bossView
    local f = F()
    local p, q = cur.pull, cur.cmp
    local view = state.view or "damage"
    if not p then
        ns.MyLogUI:SetMode("runs")
        return
    end
    v.title:SetText(p.boss or "?")
    local bits = { p.kill and ("Kill in " .. Clock(p.dur)) or strformat("Wipe at %.1f%% after %s", p.pct or 0, Clock(p.dur)),
        f.Day(p.at) }
    if p.spec and p.spec ~= "" then bits[#bits + 1] = p.spec end
    if p.ilvl then bits[#bits + 1] = strformat("item level %.1f", p.ilvl) end
    panel.sub:SetText(table.concat(bits, "  ·  "))
    v.cmpDD:Refresh()

    local a = Series(p, view)
    local b = q and Series(q, view) or {}
    v.chart:Draw(a, b, p.gaps, max(p.dur or 0, q and q.dur or 0))
    v.legend:SetText(f.Hex(f.GOLD) .. "gold: " .. f.Day(p.at) .. "|r     "
        .. (q and (f.Hex(f.GREY) .. "grey: " .. f.Day(q.at) .. "|r     ") or "")
        .. f.Hex(f.DOWN) .. "red: idle 2 s or more|r")

    local ps, qs = p.s or {}, q and q.s or {}
    local gn, gs = GapsTotal(p)
    local qn = q and GapsTotal(q) or nil
    local metric = f.VIEW_BY_KEY[view].metric
    f.SetTile(v.tiles[1], metric, f.Num(Log():Metric(p, view)),
        q and f.ChangeText(f.Change(Log():Metric(p, view), Log():Metric(q, view)), view ~= "tanking") or "",
        { metric, "Over the whole fight, for this pull." })
    f.SetTile(v.tiles[2], "Active time", f.Pct(ps.act), q and f.Points(ps.act, qs.act, true) or "",
        { "Active time", "Casting, channeling, on the global cooldown or swinging, while alive." })
    f.SetTile(v.tiles[3], "Idle gaps", strformat("%d · %.0fs", gn, gs), q and f.Count(gn, qn) or "",
        { "Idle gaps", "Times you did nothing for 2 seconds or more (red on the chart). A boss that forces you off "
            .. "(Whirlwind, phase changes) shows here too." })
    f.SetTile(v.tiles[4], "Avoidable damage", f.Num(ps.av or 0), q and f.ChangeText(f.Change(ps.av, qs.av), false) or "",
        { "Avoidable damage", "Damage from boss abilities you can stay out of." })
    for k, label in pairs(HEAD[view] or HEAD.damage) do v.heads[k]:SetText(label) end
    v.heads.casts:SetText(view == "tanking" and "" or "Casts")
    v.heads.name:SetText(view == "tanking" and "What hit you" or "Ability")

    local rows = AbilityRows(p, view)
    local before = {}
    if q then for _, r in ipairs(AbilityRows(q, view)) do before[r.key] = r.amount end end
    local data = {}
    for _, r in ipairs(rows) do
        r.before = before[r.key]
        data[#data + 1] = { r = r, view = view, hasCmp = q ~= nil }
    end
    v.list:SetData(data, true)
end

---------------------------------------------------------------------------
-- Deaths view
---------------------------------------------------------------------------

-- Every death in the instance's pulls, grouped by what killed me: { { key, name, count, last, deaths = { {
-- pull, death } } } }, most deaths first.
function MyLogDetail:DeathGroups(instKey)
    local groups, byKey = {}, {}
    for _, p in ipairs(Log():GetPulls()) do
        if (p.iid or p.zone) == instKey then
            for _, d in ipairs(p.deaths or {}) do
                local key = d.by or "?"
                local g = byKey[key]
                if not g then
                    g = { key = key, name = d.by and SpellName(p, d.by) or "Unknown", count = 0, last = 0, deaths = {} }
                    byKey[key] = g
                    groups[#groups + 1] = g
                end
                g.count = g.count + 1
                g.last = max(g.last, p.at or 0)
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

local function InitDeathRow(row, data)
    if not row.text then
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.12)
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -60, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.right = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.right:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.right:SetJustifyH("RIGHT")
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            local d = self.__cdlData
            if d and d.entry then
                deathSel = d.entry
                ns.MyLogUI:Refresh()
            end
        end)
    end
    local f = F()
    if data.group then
        local g = data.group
        row.text:SetFontObject("GameFontNormal")
        row.text:SetText(g.name)
        row.right:SetText(strformat("%d death%s", g.count, g.count == 1 and "" or "s"))
        row.sel:Hide()
    else
        local e = data.entry
        row.text:SetFontObject("GameFontHighlightSmall")
        row.text:SetText("   " .. (e.pull.boss or "?") .. "  " .. f.Hex(f.GREY) .. f.Day(e.pull.at) .. "|r")
        row.right:SetText(Clock(e.death.t))
        row.sel:SetShown(deathSel ~= nil and deathSel.death == e.death)
    end
end

local KIND = { d = "hit", h = "heal", c = "cast", m = "miss" }

local function InitRecapRow(row, data)
    if not row.t then
        row.t = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.t:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.t:SetWidth(48)
        row.t:SetJustifyH("RIGHT")
        row.what = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.what:SetPoint("LEFT", row, "LEFT", 64, 0)
        row.what:SetPoint("RIGHT", row, "RIGHT", -150, 0)
        row.what:SetJustifyH("LEFT")
        row.what:SetWordWrap(false)
        row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.amount:SetPoint("RIGHT", row, "RIGHT", -76, 0)
        row.amount:SetWidth(70)
        row.amount:SetJustifyH("RIGHT")
        row.hp = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.hp:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.hp:SetWidth(64)
        row.hp:SetJustifyH("RIGHT")
        row.line = row:CreateTexture(nil, "BORDER")
        row.line:SetColorTexture(1, 1, 1, 0.05)
        row.line:SetHeight(1)
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
    end
    local f = F()
    local e, p = data.e, data.pull
    if data.head then
        row.t:SetText(f.Hex(f.GREY) .. "time|r")
        row.what:SetText(f.Hex(f.GREY) .. "what happened|r")
        row.amount:SetText(f.Hex(f.GREY) .. "amount|r")
        row.hp:SetText(f.Hex(f.GREY) .. "health|r")
        return
    end
    local kind, key, amount, hp, who, extra = e[2], e[3], e[4], e[5], e[6], e[7]
    row.t:SetText(strformat("%.1fs", e[1]))
    local name = SpellName(p, key)
    if kind == "d" then
        local tag = Log():IsAvoidable(key) and ("  " .. f.Hex(AVOID) .. "avoidable|r") or ""
        row.what:SetText(f.Hex(f.DOWN) .. name .. "|r" .. (who and (f.Hex(f.GREY) .. "  from " .. who .. "|r") or "") .. tag)
        row.amount:SetText(f.Hex(f.DOWN) .. "-" .. f.Num(amount) .. "|r")
    elseif kind == "h" then
        row.what:SetText(f.Hex(f.UP) .. name .. "|r" .. (who and (f.Hex(f.GREY) .. "  from " .. who .. "|r") or ""))
        row.amount:SetText(f.Hex(f.UP) .. "+" .. f.Num(amount) .. "|r")
    elseif kind == "m" then
        row.what:SetText(f.Hex(f.GREY) .. name .. " (" .. tostring(extra or "miss"):lower() .. ")|r")
        row.amount:SetText(amount and (f.Hex(f.GREY) .. f.Num(amount) .. "|r") or "")
    else
        row.what:SetText("You cast " .. name)
        row.amount:SetText("")
    end
    row.hp:SetText(hp and f.Num(hp) or "")
    if e[1] == 0 and kind == "d" then row.hp:SetText(f.Hex(f.DOWN) .. "dead|r") end
end

local function BuildDeathsView(body)
    local v = CreateFrame("Frame", nil, body)
    v:SetAllPoints(body)
    local f = F()
    local left = CreateFrame("Frame", nil, v)
    left:SetPoint("TOPLEFT", v, "TOPLEFT", f.PAD, HEAD_Y)
    left:SetPoint("BOTTOMLEFT", v, "BOTTOMLEFT", f.PAD, f.PAD)
    left:SetWidth(LEFT_W)
    v.groups = UI():CreateScrollList(left, DROW_H, InitDeathRow)
    v.groups.frame:SetAllPoints(left)
    v.groups:SetEmptyText("No deaths in your stored pulls here. Keep it up.")
    local right = CreateFrame("Frame", nil, v)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 14, 0)
    right:SetPoint("BOTTOMRIGHT", v, "BOTTOMRIGHT", -f.PAD, f.PAD)
    v.title = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    v.title:SetPoint("TOPLEFT", right, "TOPLEFT", 4, 0)
    v.title:SetPoint("RIGHT", right, "RIGHT", -4, 0)
    v.title:SetJustifyH("LEFT")
    v.title:SetWordWrap(false)
    v.recap = UI():CreateScrollList(right, DROW_H, InitRecapRow)
    v.recap.frame:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -22)
    v.recap.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
    return v
end

local function RefreshDeaths(state)
    local v = deathsView
    local f = F()
    local groups = MyLogDetail:DeathGroups(state.inst)
    local data, first, found = {}, nil, false
    local total = 0
    for _, g in ipairs(groups) do
        data[#data + 1] = { group = g }
        total = total + g.count
        for _, e in ipairs(g.deaths) do
            data[#data + 1] = { entry = e }
            first = first or e
            if deathSel and deathSel.death == e.death then found = true end
        end
    end
    if not found then deathSel = first end
    v.groups:SetData(data)
    panel.sub:SetText(total == 0 and "No deaths stored for this raid."
        or strformat("%d death%s in your stored pulls here, by what killed you", total, total == 1 and "" or "s"))
    local rows = {}
    if deathSel then
        local p, d = deathSel.pull, deathSel.death
        v.title:SetText(strformat("%s · %s · died at %s%s", p.boss or "?", f.Day(p.at), Clock(d.t),
            p.kill and " (killed)" or ""))
        rows[1] = { head = true }
        for _, e in ipairs(d.ring or {}) do rows[#rows + 1] = { e = e, pull = p } end
    else
        v.title:SetText("")
    end
    v.recap:SetData(rows, true)
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

function MyLogDetail:GetCurrent() return cur.pull, cur.cmp end
function MyLogDetail:GetSelectedDeath() return deathSel end
function MyLogDetail:AbilityRows(p, view) return AbilityRows(p, view) end

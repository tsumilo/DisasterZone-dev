if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogUI.lua", ...) then return end -- DisasterZone: the My Log page (Raids > My Log).
-- My own boss pulls from Core/MyLog.lua, one raid night (run) at a time, against the run before it.
--   top:     the instances I have pulls in (tabs), the run picker (dropdown, newest first)
--   line 2:  spec, item level and what the run is compared with; the view: Damage | Healing | Tanking (starts on
--            the role of the spec played most in the run; every view is there for every role)
--   tiles:   four headline numbers of the run, each with its change from the run before
--   table:   a row per boss: pulls, the view's number on the run's kill, its change from my previous kill of that
--            boss (same spec when there is one), active time, casts per minute and the last 8 kills; a boss with
--            wipes only shows the lowest boss health reached
-- A boss row opens its detail (UI/MyLogDetail.lua), Deaths opens the death recaps. With demo mode on, the page
-- shows the demo pulls (Core/MyLogDemo.lua) and a DEMO tag.
-- Off: an explainer with a button that turns My Log on. Nothing on this page is ever sent.
local addonName, ns = ...

local MyLogUI = ns:NewModule("MyLogUI")

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat = string.format

local PAD = 10
local TOP_Y, SUB_Y, TILE_Y = -6, -40, -64
local TILE_H, TILE_GAP = 60, 8
local HEAD_Y = TILE_Y - TILE_H - 14
local ROW_H = 28
local SPARK_W, SPARK_H, SPARK_N = 96, 16, 8

local UP = { 0.36, 0.79, 0.54 }
local DOWN = { 0.89, 0.42, 0.36 }
local GREY = { 0.55, 0.57, 0.6 }
local GOLD = { 1, 0.82, 0 }
local BLUE = { 0.35, 0.65, 0.9 }

-- Columns (x, width) inside a row
local COL = {
    boss = { x = 8, w = 220 },
    pulls = { x = 232, w = 40 },
    value = { x = 280, w = 76 },
    change = { x = 364, w = 104 },
    active = { x = 476, w = 62 },
    cpm = { x = 546, w = 70 },
    spark = { x = 636, w = SPARK_W },
}

local VIEWS = {
    { key = "damage", label = "Damage", metric = "DPS" },
    { key = "healing", label = "Healing", metric = "HPS" },
    { key = "tanking", label = "Tanking", metric = "Taken/s" },
}
local VIEW_BY_KEY = {}
for _, v in ipairs(VIEWS) do VIEW_BY_KEY[v.key] = v end

local panel
local state = { inst = nil, run = 1, view = nil }

local function UI() return ns.UI end
local function Log() return ns.MyLog end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local function Num(n)
    if not n then return "-" end
    if n >= 100000 then return strformat("%.0fk", n / 1000) end
    if n >= 10000 then return strformat("%.1fk", n / 1000) end
    local s = tostring(floor(n + 0.5))
    if #s > 3 then s = s:sub(1, #s - 3) .. "," .. s:sub(-3) end
    return s
end

local function Pct(f, digits)
    if not f then return "-" end
    return strformat("%." .. (digits or 1) .. "f%%", f * 100)
end

local function Hex(c) return strformat("|cff%02x%02x%02x", floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255)) end

local function Day(at)
    if not at or at == 0 then return "?" end
    return date("%a %d %b", at)
end

local function ShortDay(at)
    if not at or at == 0 then return "?" end
    return date("%d %b", at)
end

-- "+6.1%" in green / red; higherIsBetter decides which is which. nil -> "".
local function ChangeText(change, higherIsBetter, suffix)
    if not change then return "" end
    if abs(change) < 0.05 then return Hex(GREY) .. "same" .. (suffix or "") .. "|r" end
    local good = (change > 0) == (higherIsBetter ~= false)
    return Hex(good and UP or DOWN) .. strformat("%s%.1f%%", change > 0 and "+" or "-", abs(change)) .. (suffix or "") .. "|r"
end

local function Points(now, before, higherIsBetter, unit)
    if not now or not before then return "" end
    local d = (now - before) * 100
    if abs(d) < 0.05 then return Hex(GREY) .. "same|r" end
    local good = (d > 0) == (higherIsBetter ~= false)
    return Hex(good and UP or DOWN) .. strformat("%s%.1f %s", d > 0 and "+" or "-", abs(d), unit or "pts") .. "|r"
end

local function Count(now, before)
    if not now or not before then return "" end
    local d = now - before
    if d == 0 then return Hex(GREY) .. "same|r" end
    return Hex(d < 0 and UP or DOWN) .. strformat("%d %s", abs(d), d < 0 and "fewer" or "more") .. "|r"
end

local function Change(now, before)
    if not now or not before or before == 0 then return nil end
    return (now - before) / before * 100
end

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

local function NewTile(parent)
    local t = CreateFrame("Frame", nil, parent)
    t:SetHeight(TILE_H)
    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetAllPoints()
    t.bg:SetColorTexture(1, 1, 1, 0.04)
    if UI().AddEdges then UI():AddEdges(t, "BORDER", true) end
    t.label = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t.label:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -8)
    t.label:SetPoint("RIGHT", t, "RIGHT", -8, 0)
    t.label:SetJustifyH("LEFT")
    t.label:SetWordWrap(false)
    t.label:SetTextColor(GREY[1], GREY[2], GREY[3])
    t.value = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    t.value:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -22)
    t.value:SetJustifyH("LEFT")
    t.delta = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.delta:SetPoint("TOPLEFT", t, "TOPLEFT", 10, -42)
    t.delta:SetPoint("RIGHT", t, "RIGHT", -8, 0)
    t.delta:SetJustifyH("LEFT")
    t.delta:SetWordWrap(false)
    t:EnableMouse(true)
    t:SetScript("OnEnter", function(self)
        if self.tip then UI():SetTextTooltip(self, self.tip, "ANCHOR_BOTTOM") end
    end)
    t:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return t
end

local function SetTile(t, label, value, delta, tip)
    t.label:SetText(label:upper())
    t.value:SetText(value)
    t.delta:SetText(delta ~= "" and delta or (Hex(GREY) .. "first run here|r"))
    t.tip = tip
end

---------------------------------------------------------------------------
-- Sparkline: up to SPARK_N values, the last one (this run's kill) gold
---------------------------------------------------------------------------

local function NewSpark(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(SPARK_W, SPARK_H)
    f.lines = {}
    for i = 1, SPARK_N - 1 do
        local l = f:CreateLine(nil, "ARTWORK")
        l:SetThickness(1.5)
        l:SetColorTexture(BLUE[1], BLUE[2], BLUE[3], 0.9)
        f.lines[i] = l
    end
    f.dot = f:CreateTexture(nil, "OVERLAY")
    f.dot:SetSize(4, 4)
    f.dot:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    function f:SetValues(vals)
        for _, l in ipairs(self.lines) do l:Hide() end
        self.dot:Hide()
        local n = vals and #vals or 0
        if n == 0 then return end
        local lo, hi = math.huge, -math.huge
        for i = 1, n do
            lo = min(lo, vals[i] or 0)
            hi = max(hi, vals[i] or 0)
        end
        if hi - lo < 1e-6 then lo, hi = lo - 1, hi + 1 end
        local step = (SPARK_W - 6) / (SPARK_N - 1)
        local x0 = SPARK_W - 3 - (n - 1) * step      -- the newest kill sits at the right edge
        local function pt(i)
            return x0 + (i - 1) * step, 2 + ((vals[i] or 0) - lo) / (hi - lo) * (SPARK_H - 4)
        end
        for i = 2, n do
            local l = self.lines[i - 1]
            local ax, ay = pt(i - 1)
            local bx, by = pt(i)
            l:SetStartPoint("BOTTOMLEFT", self, ax, ay)
            l:SetEndPoint("BOTTOMLEFT", self, bx, by)
            l:Show()
        end
        local x, y = pt(n)
        self.dot:ClearAllPoints()
        self.dot:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
        self.dot:Show()
    end
    return f
end

-- Shared with UI/MyLogDetail.lua
MyLogUI.F = {
    Num = Num, Pct = Pct, Hex = Hex, Day = Day, ShortDay = ShortDay, ChangeText = ChangeText, Points = Points,
    Count = Count, Change = Change, NewTile = NewTile, SetTile = SetTile, NewSpark = NewSpark,
    UP = UP, DOWN = DOWN, GREY = GREY, GOLD = GOLD, BLUE = BLUE, PAD = PAD, SUB_Y = SUB_Y, TILE_Y = TILE_Y,
    VIEWS = VIEWS, VIEW_BY_KEY = VIEW_BY_KEY,
}
function MyLogUI:GetState() return state end

---------------------------------------------------------------------------
-- Boss rows
---------------------------------------------------------------------------

local function Cell(row, col, justify, font)
    local fs = row:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
    fs:SetWidth(col.w)
    fs:SetJustifyH(justify or "RIGHT")
    fs:SetWordWrap(false)
    return fs
end

local function RowTip(row)
    local r = row.__cdlData and row.__cdlData.row
    if not r then return end
    local view = VIEW_BY_KEY[state.view] or VIEWS[1]
    local lines = { r.boss }
    local p = r.kill
    if p then
        lines[#lines + 1] = strformat("Killed in %d:%02d · %s %s", floor((p.dur or 0) / 60), floor((p.dur or 0) % 60),
            Num(r.value), view.metric)
        if r.prev then
            lines[#lines + 1] = strformat("Compared with your kill on %s (%s %s)%s", Day(r.prev.at),
                Num(Log():Metric(r.prev, state.view)), view.metric,
                r.sameSpec and "" or (", played as " .. tostring(r.prev.spec or "?")))
        else
            lines[#lines + 1] = "Your first kill of this boss in My Log."
        end
        if p.ilvl and r.prev and r.prev.ilvl and p.ilvl ~= r.prev.ilvl then
            lines[#lines + 1] = { strformat("Item level %.1f (was %.1f)", p.ilvl, r.prev.ilvl), GREY[1], GREY[2], GREY[3] }
        end
    elseif r.best then
        lines[#lines + 1] = strformat("No kill this run. Best pull: boss at %.1f%%.", r.best)
    else
        lines[#lines + 1] = "No kill this run."
    end
    if r.deaths > 0 then
        lines[#lines + 1] = { strformat("%d death%s this run", r.deaths, r.deaths == 1 and "" or "s"), DOWN[1], DOWN[2], DOWN[3] }
    end
    lines[#lines + 1] = { "Click for the fight in detail.", GREY[1], GREY[2], GREY[3] }
    UI():SetTextTooltip(row, lines)
end

local function InitRow(row, data)
    if not row.boss then
        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.05)
        row.line = row:CreateTexture(nil, "BORDER")
        row.line:SetColorTexture(1, 1, 1, 0.06)
        row.line:SetHeight(1)
        row.line:SetPoint("BOTTOMLEFT")
        row.line:SetPoint("BOTTOMRIGHT")
        row.boss = Cell(row, COL.boss, "LEFT")
        row.pulls = Cell(row, COL.pulls)
        row.value = Cell(row, COL.value)
        row.change = Cell(row, COL.change)
        row.active = Cell(row, COL.active)
        row.cpm = Cell(row, COL.cpm)
        row.spark = NewSpark(row)
        row.spark:SetPoint("LEFT", row, "LEFT", COL.spark.x, 0)
        row:SetScript("OnEnter", RowTip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnClick", function(self)
            local d = self.__cdlData and self.__cdlData.row
            if d and ns.MyLogDetail then ns.MyLogDetail:ShowBoss(d) end
        end)
    end
    local r = data.row
    local deaths = r.deaths > 0 and ("  |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:12|t" .. (r.deaths > 1 and (Hex(DOWN) .. r.deaths .. "|r") or "")) or ""
    row.pulls:SetText(r.pulls)
    if r.kill then
        row.boss:SetText(r.boss .. deaths)
        row.value:SetText(Num(r.value))
        local better = state.view ~= "tanking"
        row.change:SetText(r.prev and ChangeText(r.change, better, r.sameSpec and "" or "*")
            or (Hex(GREY) .. "first kill|r"))
        row.active:SetText(Pct(r.active))
        row.cpm:SetText(r.cpm and strformat("%.1f", r.cpm) or "-")
        row.spark:SetValues(r.spark)
        row.spark:Show()
    else
        row.boss:SetText(r.boss .. " " .. Hex(GREY) .. "(wipe" .. (r.pulls > 1 and (" x" .. r.pulls) or "") .. ")|r" .. deaths)
        row.value:SetText(Hex(GREY) .. "-|r")
        row.change:SetText(r.best and (Hex(GREY) .. strformat("best %.0f%%", r.best) .. "|r") or "")
        row.active:SetText("")
        row.cpm:SetText("")
        row.spark:Hide()
    end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function CurrentRun()
    local runs = state.inst and Log():GetRuns(state.inst) or {}
    if state.run > #runs then state.run = 1 end
    return runs[state.run], runs[state.run + 1], runs
end

local function RunLabel(run)
    return strformat("%s · %d kill%s%s", Day(run.at), run.kills, run.kills == 1 and "" or "s",
        run.wipes > 0 and strformat(", %d wipe%s", run.wipes, run.wipes == 1 and "" or "s") or "")
end

function MyLogUI:SetView(key)
    state.view = key
    state.viewPicked = true
    self:Refresh()
end

function MyLogUI:SelectInstance(key)
    state.inst = key
    state.mode = "runs"
    state.run = 1
    state.viewPicked = nil
    self:Refresh()
end

function MyLogUI:SelectRun(i)
    state.run = i
    state.viewPicked = nil
    self:Refresh()
end

local function BuildTiles(run, prevRun)
    local view = state.view
    local now = Log():RunNumbers(run, view)
    local before = prevRun and Log():RunNumbers(prevRun, view) or nil
    local b = before or {}
    local since = prevRun and (" vs " .. ShortDay(prevRun.at)) or ""
    local metric = VIEW_BY_KEY[view].metric
    local t = panel.tiles
    local function kills(n) return strformat("Average over %d kill%s this run.", n, n == 1 and "" or "s") end
    if view == "healing" then
        SetTile(t[1], "Avg HPS (kills)", Num(now.value), ChangeText(Change(now.value, b.value), true, since),
            { "Healing per second", "Effective healing plus your shields' absorbs, per second of the fight.", kills(now.kills) })
        SetTile(t[2], "Overhealing", Pct(now.overheal), Points(now.overheal, b.overheal, false),
            { "Overhealing", "The share of your healing that landed on full health." })
    elseif view == "tanking" then
        SetTile(t[1], "Damage taken/s", Num(now.value), ChangeText(Change(now.value, b.value), false, since),
            { "Damage taken per second", "Health lost plus what shields took for you, per second.", kills(now.kills) })
        SetTile(t[2], "Swings avoided", Pct(now.avoid), Points(now.avoid, b.avoid, true),
            { "Swings avoided", "Melee swings at you that you dodged or parried, or that missed." })
    else
        SetTile(t[1], "Avg DPS (kills)", Num(now.value), ChangeText(Change(now.value, b.value), true, since),
            { "Damage per second", "Your damage and your pets', without overkill, per second of the fight.", kills(now.kills) })
        SetTile(t[2], "Avoidable damage", Num(now.avoidable), ChangeText(Change(now.avoidable, b.avoidable), false),
            { "Avoidable damage taken", "Damage from boss abilities you can stay out of (Toxic Spores, Whirlwind, "
                .. "Flame Patch...), every pull of the run, wipes included." })
    end
    SetTile(t[3], "Active time", Pct(now.active), Points(now.active, b.active, true),
        { "Active time", "Time casting, channeling, on the global cooldown or swinging, out of the time you were alive." })
    SetTile(t[4], "Deaths", tostring(now.deaths), before and Count(now.deaths, b.deaths) or "",
        { "Deaths", "Every pull of the run, wipes included." })
    -- the line under the top bar
    local spec = Log():RunSpec(run)
    local parts = {}
    if spec and spec ~= "" then parts[#parts + 1] = spec end
    if now.ilvl then
        local il = strformat("item level %.1f", now.ilvl)
        if b.ilvl and abs(now.ilvl - b.ilvl) >= 0.05 then
            il = il .. strformat(" (%s%.1f)", now.ilvl > b.ilvl and "+" or "-", abs(now.ilvl - b.ilvl))
        end
        parts[#parts + 1] = il
    end
    parts[#parts + 1] = prevRun and ("compared with " .. Day(prevRun.at)) or "your first run here"
    panel.sub:SetText(table.concat(parts, "  ·  "))
    panel.valueHead:SetText(metric)
end

function MyLogUI:Refresh()
    local p = panel
    if not p or not p:IsShown() then
        if p then p.dirty = true end
        return
    end
    p.dirty = false
    local L = Log()
    local enabled = L and L:IsEnabled()
    local instances = L and L:GetInstances() or {}
    local hasData = #instances > 0
    p.body:SetShown(hasData)
    p.empty:SetShown(not hasData)
    p.demoTag:SetShown(hasData and L:IsDemo())
    if not hasData then
        if enabled then
            p.empty.title:SetText("No boss pulls yet")
            p.empty.text:SetText("My Log is on. Your next raid boss pull shows up here: your numbers, "
                .. "and how they compare with your last kill of that boss.")
            p.empty.btn:Hide()
        else
            p.empty.title:SetText("My Log is off")
            p.empty.text:SetText("Turn it on to record your own play in every raid boss pull: damage, healing, "
                .. "damage taken, casts, buffs and deaths. It stays on this PC. Nobody else can see it, the loot "
                .. "council included.")
            p.empty.btn:Show()
        end
        return
    end
    -- instance tabs
    local found = false
    for _, e in ipairs(instances) do if e.key == state.inst then found = true end end
    if not found then state.inst, state.run, state.viewPicked = instances[1].key, 1, nil end
    for i, tab in ipairs(p.instTabs) do tab:Hide(); tab.key = nil end
    local x = PAD
    for i, e in ipairs(instances) do
        if i > 5 then break end
        local tab = p.instTabs[i]
        if not tab then
            tab = UI():CreateUnderlineTab(p.body, "", function(self) MyLogUI:SelectInstance(self.key) end, "page")
            p.instTabs[i] = tab
        end
        tab.key = e.key
        tab:SetLabel(e.name .. (e.heroic and " (H)" or ""))
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", p.body, "TOPLEFT", x, TOP_Y)
        tab:SetActive(e.key == state.inst)
        tab:Show()
        x = x + tab:GetWidth() + 4
    end
    local run, prevRun = CurrentRun()
    if not run then return end
    if not state.viewPicked then
        local _, role = L:RunSpec(run)
        state.view = L:ViewForRole(role)
    end
    for _, b in ipairs(p.viewBtns) do b:SetKind(b.key == state.view and "chosen" or "secondary") end
    p.runDD:Refresh()
    state.mode = state.mode or "runs"
    p.runsView:SetShown(state.mode == "runs")
    p.deathsBtn:SetKind(state.mode == "deaths" and "chosen" or "secondary")
    if state.mode ~= "runs" and ns.MyLogDetail then
        p.runDD:SetShown(false)
        ns.MyLogDetail:Refresh(state, run, prevRun)
        return
    end
    p.runDD:SetShown(true)
    if ns.MyLogDetail then ns.MyLogDetail:HideAll() end
    BuildTiles(run, prevRun)
    local rows = {}
    for _, r in ipairs(L:BossRows(run, state.view)) do rows[#rows + 1] = { row = r } end
    p.list:SetData(rows)
end

-- "runs" | "boss" | "deaths" (MyLogDetail sets state.boss for "boss")
function MyLogUI:SetMode(mode)
    state.mode = mode
    self:Refresh()
end

function MyLogUI:RequestRefresh()
    if panel then
        panel.dirty = true
        if panel:IsShown() then self:Refresh() end
    end
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function MyLogUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.instTabs = {}

    -- empty state
    local e = CreateFrame("Frame", nil, p)
    e:SetPoint("CENTER", p, "CENTER", 0, 30)
    e:SetSize(460, 160)
    e.title = e:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    e.title:SetPoint("TOP", e, "TOP", 0, 0)
    e.text = e:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    e.text:SetPoint("TOP", e.title, "BOTTOM", 0, -10)
    e.text:SetWidth(440)
    e.text:SetJustifyH("CENTER")
    e.text:SetSpacing(3)
    e.btn = UI():CreateSleekButton(e, "Turn on My Log", 150, 26, function()
        ns.DB:SetSetting("mylog.enabled", true)
        MyLogUI:Refresh()
    end, "primary")
    e.btn:SetPoint("TOP", e.text, "BOTTOM", 0, -14)
    p.empty = e

    -- body
    local body = CreateFrame("Frame", nil, p)
    body:SetAllPoints(p)
    p.body = body

    p.runDD = UI():CreateSleekDropdown(body, 210,
        function()
            local out = {}
            for i, run in ipairs(state.inst and Log():GetRuns(state.inst) or {}) do
                out[#out + 1] = { value = i, text = RunLabel(run) }
            end
            return out
        end,
        function() return state.run end,
        function(v) MyLogUI:SelectRun(v) end)
    p.runDD:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, TOP_Y - 2)

    p.deathsBtn = UI():CreateSleekButton(body, "Deaths", 70, 22, function()
        MyLogUI:SetMode(state.mode == "deaths" and "runs" or "deaths")
    end)
    p.deathsBtn:SetPoint("RIGHT", p.runDD, "LEFT", -8, 0)
    p.demoTag = UI():CreateTagPill(body, 16)
    p.demoTag:Set("DEMO", "warn")
    p.demoTag:SetPoint("RIGHT", p.deathsBtn, "LEFT", -8, 0)
    p.demoTag:EnableMouse(true)
    p.demoTag:SetScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Demo data", "Made-up pulls while demo mode is on (Settings > Demo mode). "
            .. "Your own log is untouched and keeps recording." })
    end)
    p.demoTag:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local rv = CreateFrame("Frame", nil, body)
    rv:SetAllPoints(body)
    p.runsView = rv

    p.sub = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.sub:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, SUB_Y - 4)
    p.sub:SetPoint("RIGHT", body, "RIGHT", -250, 0)
    p.sub:SetJustifyH("LEFT")
    p.sub:SetWordWrap(false)
    p.sub:SetTextColor(0.75, 0.75, 0.75)

    p.viewBtns = {}
    local prev
    for i = #VIEWS, 1, -1 do
        local v = VIEWS[i]
        local b = UI():CreateSleekButton(body, v.label, 76, 20, function() MyLogUI:SetView(v.key) end)
        b.key = v.key
        if prev then b:SetPoint("RIGHT", prev, "LEFT", -4, 0) else b:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, SUB_Y) end
        prev = b
        p.viewBtns[i] = b
    end

    p.tiles = {}
    for i = 1, 4 do
        local t = NewTile(rv)
        p.tiles[i] = t
    end
    local function placeTiles()
        local w = (body:GetWidth() or 780) - 2 * PAD
        if w <= 0 then w = 760 end
        local tw = (w - 3 * TILE_GAP) / 4
        for i, t in ipairs(p.tiles) do
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", body, "TOPLEFT", PAD + (i - 1) * (tw + TILE_GAP), TILE_Y)
            t:SetWidth(tw)
        end
    end
    placeTiles()
    body:HookScript("OnSizeChanged", placeTiles)

    local head = UI():CreateColumnHeader(rv, 20)
    head:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, HEAD_Y)
    head:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD - 20, HEAD_Y)
    head:AddColumn("Boss", COL.boss.x, COL.boss.w)
    head:AddColumn("Pulls", COL.pulls.x, COL.pulls.w, { justify = "RIGHT" })
    p.valueHead = head:AddColumn("DPS", COL.value.x, COL.value.w, { justify = "RIGHT" }).label
    head:AddColumn("vs last kill", COL.change.x, COL.change.w, { justify = "RIGHT", tip = function()
        GameTooltip:AddLine("vs last kill", 1, 0.82, 0)
        GameTooltip:AddLine("The change from your previous kill of the boss in the same spec. * = no kill in this "
            .. "spec yet, compared with another spec.", 1, 1, 1, true)
    end })
    head:AddColumn("Active", COL.active.x, COL.active.w, { justify = "RIGHT" })
    head:AddColumn("Casts/min", COL.cpm.x, COL.cpm.w, { justify = "RIGHT" })
    head:AddColumn("Last 8 kills", COL.spark.x, COL.spark.w, { justify = "RIGHT" })

    p.list = UI():CreateScrollList(rv, ROW_H, InitRow)
    p.list.frame:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, HEAD_Y - 22)
    p.list.frame:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -PAD, PAD)

    function p:OnPanelShown()
        MyLogUI:Refresh()
    end
    p:HookScript("OnShow", function(self) if self.dirty then MyLogUI:Refresh() end end)
    return p
end

function MyLogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("mylog", "My Log", 3.52, function(parent) return MyLogUI:CreatePanel(parent) end)
    end
    local function changed() MyLogUI:RequestRefresh() end
    ns:On("MYLOG_CHANGED", changed)
    ns:On("SETTINGS_CHANGED", function(path) if path == "mylog.enabled" then changed() end end)
    ns:On("DEMO_TOGGLED", function() state.mode = "runs"; state.inst = nil; changed() end)
end

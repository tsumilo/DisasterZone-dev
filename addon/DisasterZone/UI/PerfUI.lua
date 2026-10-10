if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PerfUI.lua", ...) then return end -- DisasterZone UI/PerfUI.lua
-- The Performance page (the developer's only: Core/Perf.lua, an icon at the right of the strip). Top: four tiles -
-- in use (after the last cleanup), now (garbage included, the AddOn list's number), garbage per minute, CPU - and
-- Clean up now. Then the memory over the last hour. Bottom left: who makes garbage (Measure 30 s: every handler,
-- most garbage first); bottom right: what holds memory (pages and their widgets, saved data by section).
local addonName, ns = ...

local PerfUI = ns:NewModule("PerfUI")

local floor, max, min = math.floor, math.max, math.min
local tostring, tonumber, ipairs, pairs = tostring, tonumber, ipairs, pairs

local PAD = 10
local TOP_H, CHART_H, ROW_H = 74, 128, 18
local MEASURE_S = 30

local panel
local function UI() return ns.UI end
local function Perf() return ns.Perf end

local function MB(kb) return ("%.1f MB"):format((tonumber(kb) or 0) / 1024) end
local function KB(kb)
    kb = tonumber(kb) or 0
    if kb >= 1024 then return ("%.1f MB"):format(kb / 1024) end
    return ("%d KB"):format(floor(kb + 0.5))
end
local function Clock(t)
    if not (t and date and time and GetTime) then return "" end
    return date("%H:%M", time() - floor(GetTime() - t))
end

---------------------------------------------------------------------------
-- Pieces
---------------------------------------------------------------------------

local function Text(parent, font, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function Tile(parent, caption)
    local t = CreateFrame("Frame", nil, parent)
    t.caption = Text(t, "GameFontNormalSmall")
    t.caption:SetPoint("TOPLEFT", 0, 0)
    t.caption:SetPoint("RIGHT", t, "RIGHT", -6, 0)
    t.caption:SetText(caption)
    t.value = Text(t, "GameFontHighlightLarge")
    t.value:SetPoint("TOPLEFT", t.caption, "BOTTOMLEFT", 0, -5)
    t.value:SetPoint("RIGHT", t, "RIGHT", -6, 0)
    t.sub = Text(t, "GameFontDisableSmall")
    t.sub:SetPoint("TOPLEFT", t.value, "BOTTOMLEFT", 0, -5)
    t.sub:SetPoint("RIGHT", t, "RIGHT", -6, 0)
    return t
end

-- A list in a panel: columns { { title, x, width, justify }, ... }; cells filled by fill(row, data) -> texts, tint
-- (of the first cell), sub (a second, grey line under the first cell: rows are then rowH tall), tip (hover lines).
local function Table(parent, columns, fill, rowH)
    rowH = rowH or ROW_H
    local head = UI():CreateColumnHeader(parent, 16)
    for _, c in ipairs(columns) do head:AddColumn(c[1], c[2], c[3], { justify = c[4] }) end
    local list = UI():CreateScrollList(parent, rowH, function(row, data)
        if not row.cells then
            row.cells = {}
            local two = rowH > ROW_H
            for i, c in ipairs(columns) do
                local fs = Text(row, "GameFontHighlightSmall", c[4] or "LEFT")
                fs:SetPoint(two and i == 1 and "TOPLEFT" or "LEFT", row, two and i == 1 and "TOPLEFT" or "LEFT", c[2],
                    two and i == 1 and -3 or 0)
                fs:SetWidth(c[3])
                row.cells[i] = fs
            end
            if two then
                row.sub = Text(row, "GameFontDisableSmall")
                row.sub:SetPoint("TOPLEFT", row.cells[1], "BOTTOMLEFT", 0, -2)
                row.sub:SetWidth(columns[1][3])
            end
            row.shade = row:CreateTexture(nil, "BACKGROUND")
            row.shade:SetAllPoints()
            row.shade:SetColorTexture(1, 1, 1, 0.04)
            row:SetScript("OnEnter", function(self)
                if not self.tip then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                for i, line in ipairs(self.tip) do
                    if i == 1 then GameTooltip:AddLine(line) else GameTooltip:AddLine(line, 1, 1, 1, true) end
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        local texts, tint, sub, tip = fill(data)
        for i, fs in ipairs(row.cells) do
            fs:SetText(texts[i] or "")
            if i == 1 and tint then fs:SetTextColor(tint[1], tint[2], tint[3]) else fs:SetTextColor(0.9, 0.9, 0.9) end
        end
        if row.sub then row.sub:SetText(sub or "") end
        row.tip = tip
        row.shade:SetShown(data.odd and true or false)
    end)
    return head, list
end

local KIND_TINT = { event = { 0.55, 0.78, 1 }, OnEvent = { 0.55, 0.78, 1 }, message = { 0.75, 0.62, 1 },
                    OnUpdate = { 1, 0.82, 0.35 }, timer = { 0.5, 0.9, 0.6 }, comm = { 1, 0.6, 0.4 }, send = { 1, 0.75, 0.55 },
                    library = { 0.95, 0.5, 0.55 } }
local KIND_NAME = { event = "event", OnEvent = "event (own frame)", message = "addon message bus", OnUpdate = "every frame",
                    timer = "timer", comm = "addon messages", send = "addon messages I send",
                    library = "shared library" }
local MEASURE_ROW_H = 30
local HOLD_TITLES = { pages = { "Page", "widgets", "built in" }, saved = { "Section", "size", "entries" } }

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function RefreshTiles(p)
    local P = Perf()
    local s = P.samples
    local cur = s[#s] and s[#s].kb
    local clean = P.clean
    -- (the subs stay short: a tile is ~150 px)
    p.tUse.value:SetText(clean and MB(clean.after) or "?")
    p.tUse.sub:SetText(clean and ("after cleanup %s"):format(Clock(clean.t)) or "press Clean up now")
    p.tNow.value:SetText(cur and MB(cur) or "?")
    p.tNow.sub:SetText(cur and clean and cur > clean.after and ("%s garbage"):format(MB(cur - clean.after))
        or "as the AddOn list")
    local rate = P:GarbageRate()
    p.tRate.value:SetText(rate and (KB(rate) .. " / min") or "?")
    p.tRate.sub:SetText(rate and "last 5 minutes" or "after two samples")
    local cpu = P:CPU()
    if not cpu then
        p.tCpu.value:SetText("n/a")
        p.tCpu.sub:SetText("no addon profiler")
    elseif cpu.off then
        p.tCpu.value:SetText("off")
        p.tCpu.sub:SetText("profiler is off")
    else
        p.tCpu.value:SetText(cpu.recent and ("%.2f ms"):format(cpu.recent) or "?")
        p.tCpu.sub:SetText(cpu.share and ("%.1f%% of frame time"):format(cpu.share * 100)
            or (cpu.peak and ("a frame, peak %.1f ms"):format(cpu.peak) or "a frame on average"))
    end
end

local function RefreshChart(p)
    local c = p.chart
    local s = Perf().samples
    local n = #s
    -- (before the first layout the area has no size yet: the page's own then)
    local w, h = c.area:GetWidth() or 0, c.area:GetHeight() or 0
    if w <= 1 then w = (panel:GetWidth() > 1 and panel:GetWidth() or 792) - 8 - 2 * PAD end
    if h <= 1 then h = CHART_H - 48 end
    local top = 1
    for i = 1, n do top = max(top, s[i].kb) end
    top = top * 1.1
    local bw = w / 360
    for i = 1, max(n, #c.bars) do
        local bar = c.bars[i]
        if i <= n then
            if not bar then
                bar = c.area:CreateTexture(nil, "ARTWORK")
                bar:SetColorTexture(1, 0.78, 0.25, 0.85)
                c.bars[i] = bar
            end
            local bh = max(1, s[i].kb / top * h)
            bar:ClearAllPoints()
            bar:SetPoint("BOTTOMLEFT", c.area, "BOTTOMLEFT", (360 - n + i - 1) * bw, 0)
            bar:SetSize(max(1, bw - 0.5), bh)
            bar:Show()
        elseif bar then
            bar:Hide()
        end
    end
    local clean = Perf().clean
    if clean then
        c.floor:ClearAllPoints()
        c.floor:SetPoint("BOTTOMLEFT", c.area, "BOTTOMLEFT", 0, min(h, clean.after / top * h))
        c.floor:SetPoint("RIGHT", c.area, "RIGHT", 0, 0)
        c.floor:Show()
    else
        c.floor:Hide()
    end
    c.top:SetText(MB(top))
    c.span:SetText(n > 0 and ("%d min, a sample every 10 s%s"):format(floor(n / 6 + 0.5),
        clean and "  |cff59e673-|r in use after cleanup" or "") or "no samples yet")
end

local function RefreshMeasure(p)
    local P = Perf()
    local on, elapsed, secs = P:IsMeasuring()
    local m = p.measure
    if on then
        m.button:SetText(("Measuring %d s"):format(max(0, floor(secs - elapsed + 0.5))))
        m.button:SetEnabled(false)
    else
        m.button:SetText(("Measure %d s"):format(MEASURE_S))
        m.button:SetEnabled(true)
    end
    local r = P.last
    local rows = {}
    if r then
        local perMin = 60 / max(1, r.seconds)
        for i, row in ipairs(r.rows) do
            if i > 200 then break end
            rows[#rows + 1] = { odd = i % 2 == 1, row = row, perMin = perMin, seconds = r.seconds }
        end
        local grew = r.grew * perMin
        m.summary:SetText(("DisasterZone grew %s / min while measuring; these handlers made %s / min (%d%%). The rest: "
            .. "C_Timer callbacks and code the page cannot see."):format(KB(max(0, grew)), KB(r.attributed * perMin),
            grew > 0 and floor(min(1, r.attributed * perMin / grew) * 100 + 0.5) or 0))
    else
        m.summary:SetText("Measure times every DisasterZone handler for 30 s and weighs the garbage it makes.")
    end
    m.list:SetData(rows)
end

local function RefreshHolds(p)
    local h = p.holds
    local P = Perf()
    local rows = {}
    if h.mode == "pages" then
        for _, pg in ipairs(P:Pages()) do
            if pg.widgets then
                rows[#rows + 1] = { odd = #rows % 2 == 0, texts = { pg.label or pg.key, tostring(pg.widgets),
                    pg.build and ("%d ms"):format(floor(pg.build + 0.5)) or "" } }
            end
        end
        h.list:SetEmptyText("No page built yet.")
    else
        for i, sv in ipairs(P:SavedSizes()) do
            rows[#rows + 1] = { odd = i % 2 == 1, texts = { sv.name, KB(sv.kb), tostring(sv.entries) } }
        end
    end
    h.list:SetData(rows)
    for key, tab in pairs(h.tabs) do tab:SetActive(key == h.mode) end
    for i, title in ipairs(HOLD_TITLES[h.mode]) do h.head.columns[i].label:SetText(title) end
end

function PerfUI:Refresh(full)
    if not (panel and panel:IsVisible()) then return end
    RefreshTiles(panel)
    RefreshChart(panel)
    RefreshMeasure(panel)
    if full then RefreshHolds(panel) end
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

function PerfUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p

    -- tiles + Clean up now
    local top = UI():CreatePanel(p)
    top:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -4)
    top:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -4)
    top:SetHeight(TOP_H)
    p.clean = UI():CreateSleekButton(top, "Clean up now", 110, 24, function()
        Perf():CleanUp()
        PerfUI:Refresh()
    end)
    p.clean:SetPoint("RIGHT", top, "RIGHT", -PAD, 0)
    p.clean:SetScript("OnEnter", function(b)
        GameTooltip:SetOwner(b, "ANCHOR_BOTTOMLEFT")
        GameTooltip:AddLine("Clean up now")
        GameTooltip:AddLine("A full garbage collection (the game pauses a moment): what is left is what DisasterZone "
            .. "really holds.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    p.clean:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local tiles = { { "tUse", "In use" }, { "tNow", "Now" }, { "tRate", "Garbage" }, { "tCpu", "CPU" } }
    local prev
    for _, def in ipairs(tiles) do
        local t = Tile(top, def[2])
        t:SetHeight(TOP_H - 2 * PAD)
        if prev then t:SetPoint("TOPLEFT", prev, "TOPRIGHT", 8, 0) else t:SetPoint("TOPLEFT", top, "TOPLEFT", PAD + 2, -PAD) end
        p[def[1]] = t
        prev = t
    end
    local function SizeTiles(w)
        if not w or w <= 1 then w = (parent:GetWidth() > 1 and parent:GetWidth() or 792) - 8 end
        local tw = floor((w - 2 * PAD - 110 - 16 - 3 * 8) / 4)
        for _, def in ipairs(tiles) do p[def[1]]:SetWidth(max(60, tw)) end
    end
    SizeTiles(top:GetWidth())
    top:SetScript("OnSizeChanged", function(_, w) SizeTiles(w) end)

    -- memory over the last hour
    local chart = UI():CreatePanel(p)
    chart:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    chart:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", 0, -6)
    chart:SetHeight(CHART_H)
    local c = { bars = {} }
    p.chart = c
    local title = Text(chart, "GameFontNormal")
    title:SetPoint("TOPLEFT", chart, "TOPLEFT", PAD, -8)
    title:SetText("Memory over the last hour")
    c.span = Text(chart, "GameFontDisableSmall", "RIGHT")
    c.span:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -PAD, -10)
    c.area = CreateFrame("Frame", nil, chart)
    c.area:SetPoint("TOPLEFT", chart, "TOPLEFT", PAD, -40)
    c.top = Text(c.area, "GameFontDisableSmall")          -- (the scale: the area's top line)
    c.top:SetPoint("BOTTOMLEFT", c.area, "TOPLEFT", 0, 2)
    local topLine = c.area:CreateTexture(nil, "BORDER")
    topLine:SetColorTexture(1, 1, 1, 0.06)
    topLine:SetPoint("TOPLEFT")
    topLine:SetPoint("TOPRIGHT")
    topLine:SetHeight(1)
    c.area:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -PAD, 8)
    local base = c.area:CreateTexture(nil, "BORDER")
    base:SetColorTexture(1, 1, 1, 0.12)
    base:SetPoint("BOTTOMLEFT")
    base:SetPoint("BOTTOMRIGHT")
    base:SetHeight(1)
    c.floor = c.area:CreateTexture(nil, "OVERLAY")
    c.floor:SetColorTexture(0.35, 0.9, 0.45, 0.8)
    c.floor:SetHeight(1)
    c.floor:Hide()
    c.area:SetScript("OnSizeChanged", function() if p:IsVisible() then RefreshChart(p) end end)

    -- who makes garbage
    local left = UI():CreatePanel(p)
    left:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -6)
    left:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 4, 4)
    left:SetPoint("RIGHT", p, "CENTER", 80, 0)
    local m = {}
    p.measure = m
    local lt = Text(left, "GameFontNormal")
    lt:SetPoint("TOPLEFT", left, "TOPLEFT", PAD, -9)
    lt:SetText("Who makes garbage")
    m.button = UI():CreateSleekButton(left, ("Measure %d s"):format(MEASURE_S), 120, 22, function()
        Perf():Measure(MEASURE_S, function() PerfUI:Refresh() end)
        PerfUI:Refresh()
    end, "primary")
    m.button:SetPoint("TOPRIGHT", left, "TOPRIGHT", -PAD, -6)
    m.summary = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.summary:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", PAD, 8)
    m.summary:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -PAD, 8)
    m.summary:SetJustifyH("LEFT")
    m.summary:SetHeight(26)
    local cols = { { "Source", 4, 228 }, { "per min", 236, 58, "RIGHT" }, { "ms / s", 298, 44, "RIGHT" },
                   { "calls / s", 346, 52, "RIGHT" } }
    m.head, m.list = Table(left, cols, function(d)
        local r, perMin, secs = d.row, d.perMin, max(1, d.seconds)
        local at, name = tostring(r.key):match("^(.-)  (.*)$")
        at, name = at or "", name or tostring(r.key)
        local per, ms, calls = KB(r.kb * perMin), ("%.2f"):format(r.ms / secs), ("%.1f"):format(r.calls / secs)
        local tip = { name, at, ("%s  -  %s / min of garbage, %s ms / s, %s calls / s"):format(
            KIND_NAME[r.what] or tostring(r.what), per, ms, calls) }
        if r.gc > 0 then tip[#tip + 1] = ("%d call(s) had a cleanup inside: their garbage is not counted."):format(r.gc) end
        if r.who then                         -- (messages: who from / to, the most first, with the last rev)
            local list = {}
            for who, x in pairs(r.who) do list[#list + 1] = { who = who, n = x.n, rev = x.rev } end
            table.sort(list, function(a, b) return a.n > b.n end)
            tip[#tip + 1] = r.what == "send" and "To:" or "From:"
            for i = 1, min(8, #list) do
                local e = list[i]
                tip[#tip + 1] = ("  %s  x%d%s"):format(e.who, e.n, e.rev and ("  (rev %s)"):format(tostring(e.rev)) or "")
            end
            if #list > 8 then tip[#tip + 1] = ("  and %d more"):format(#list - 8) end
        end
        return { name, per, ms, calls }, KIND_TINT[r.what], at, tip
    end, MEASURE_ROW_H)
    m.head:SetPoint("TOPLEFT", left, "TOPLEFT", PAD, -34)
    m.head:SetPoint("RIGHT", left, "RIGHT", -PAD - 20, 0)
    m.list.frame:SetPoint("TOPLEFT", m.head, "BOTTOMLEFT", 0, -2)
    m.list.frame:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", -6, 38)
    m.list:SetEmptyText("Nothing measured yet.")

    -- what holds memory
    local right = UI():CreatePanel(p)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 6, 0)
    right:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -4, 4)
    local h = { mode = "pages", tabs = {} }
    p.holds = h
    local rt = Text(right, "GameFontNormal")
    rt:SetPoint("TOPLEFT", right, "TOPLEFT", PAD, -9)
    rt:SetText("What holds memory")
    h.tabs.saved = UI():CreateUnderlineTab(right, "Saved data", function()
        h.mode = "saved" RefreshHolds(p)
    end, "small")
    h.tabs.saved:SetPoint("TOPRIGHT", right, "TOPRIGHT", -PAD, -6)
    h.tabs.pages = UI():CreateUnderlineTab(right, "Pages", function()
        h.mode = "pages" RefreshHolds(p)
    end, "small")
    h.tabs.pages:SetPoint("RIGHT", h.tabs.saved, "LEFT", -4, 0)
    -- (one set of columns; the titles follow the tab: HOLD_TITLES)
    local hcols = { { "Page", 4, 150 }, { "widgets", 158, 52, "RIGHT" }, { "built in", 214, 50, "RIGHT" } }
    h.head, h.list = Table(right, hcols, function(d) return d.texts end)
    h.head:SetPoint("TOPLEFT", right, "TOPLEFT", PAD, -34)
    h.head:SetPoint("RIGHT", right, "RIGHT", -PAD - 20, 0)
    h.list.frame:SetPoint("TOPLEFT", h.head, "BOTTOMLEFT", 0, -2)
    h.list.frame:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -6, 8)

    p:SetScript("OnShow", function()
        if p.ticker then p.ticker:Cancel() end
        p.ticker = C_Timer.NewTicker(2, function() PerfUI:Refresh() end)
    end)
    p:SetScript("OnHide", function()
        if p.ticker then p.ticker:Cancel() p.ticker = nil end
    end)
    function p:OnPanelShown()
        PerfUI:Refresh(true)
    end
    return p
end

PerfUI._panel = function() return panel end      -- (tests)

function PerfUI:OnLogin()
    if ns.Perf and ns.Perf.Start then ns.Perf:Start() end
end

function PerfUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("perf", "Performance", 3.92, function(parent) return PerfUI:CreatePanel(parent) end,
            function() return ns.Perf and ns.Perf:IsDev() end)
    end
    ns:On("PERF_UPDATED", function() PerfUI:Refresh() end)
    if ns.Perf and ns.Perf:IsDev() then          -- (/dz perf: the developer's only, like the page)
        ns:RegisterSlash("perf", function() if ns.MainFrame then ns.MainFrame:Open("perf") end end,
            "open the Performance page (memory, garbage, CPU)")
    end
end

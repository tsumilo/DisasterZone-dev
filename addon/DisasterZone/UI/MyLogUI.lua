if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogUI.lua", ...) then return end -- DisasterZone: the My Log page (Raids > My Log).
-- My own boss pulls from Core/MyLog.lua, one raid night (run) at a time, on the shared Board layout
-- (UI:CreateLayout "board"); the data drawings come from UI/MyLogKit.lua.
--   toolbar: tabs Raid nights | Deaths (with their count); filters: a DEMO pill while demo mode shows made-up pulls
--            (Core/MyLogDemo.lua), the raid picker, the view switch Damage | Healing | Tanking (starts on the role
--            played most in the run; every view is there for every role)
--   hero:    the night's banner over the raid's art: when, the headline number (average over its kills) and what it
--            is, its change from the night before, "best night" when it is my best night here, and the trend of my
--            last 8 nights on the right
--   cards:   four stat cards (the same as the boss screen's); then "Bosses this night": a card per boss: portrait, kill
--            time and active time, my number with its change from my previous kill of the boss (same spec first) or
--            "best" for a personal best, the last 8 kills; a thin line along the bottom shows how close the kill came
--            to my best. A boss with wipes only shows its lowest health. A click opens the boss (UI/MyLogDetail.lua,
--            a Detail page); the Deaths tab is UI/MyLogDetail.lua's list + detail.
--   foot:    "Raid nights": every night as a bar (taller = a higher number), a click opens it.
-- Off: the layout's empty state with a button that turns My Log on. Nothing on this page is ever sent.
local addonName, ns = ...

local MyLogUI = ns:NewModule("MyLogUI")

local S = ns.Style
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat = string.format

local TREND_W = 320
local FOOT_H = 18 + 4 + 26            -- the caps header, a gap, the bars
local NIGHTS = 12
local TREND_N = 8
local ICON = {
    active = "Interface\\Icons\\INV_Misc_PocketWatch_01", avoid = "Interface\\Icons\\Spell_Fire_Fire",
    deaths = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01", ilvl = "Interface\\Icons\\INV_Chest_Plate06",
    overheal = "Interface\\Icons\\Spell_Holy_FlashHeal", swings = "Interface\\Icons\\Ability_Parry",
    log = 134939,                     -- a scroll (the empty state's)
}

local VIEWS = {
    { key = "damage", label = "Damage", metric = "DPS", long = "avg DPS on kills" },
    { key = "healing", label = "Healing", metric = "HPS", long = "avg HPS on kills" },
    { key = "tanking", label = "Tanking", metric = "Taken/s", long = "avg damage taken per second" },
}
local VIEW_BY_KEY = {}
for _, v in ipairs(VIEWS) do VIEW_BY_KEY[v.key] = v end

local panel
local state = { inst = nil, run = 1, view = nil, mode = "runs" }
local lastRows = {}

local function UI() return ns.UI end
local function Log() return ns.MyLog end
local function K() return ns.MyLogKit end
local function A(c, a) return { c[1], c[2], c[3], a } end

function MyLogUI:GetState() return state end
function MyLogUI:GetBossRows() return lastRows end
MyLogUI.VIEWS, MyLogUI.VIEW_BY_KEY = VIEWS, VIEW_BY_KEY

---------------------------------------------------------------------------
-- State changes
---------------------------------------------------------------------------

function MyLogUI:SetView(key)
    state.view = key
    state.viewPicked = true
    self:Refresh()
end

function MyLogUI:SelectInstance(key)
    state.inst, state.run, state.mode, state.viewPicked = key, 1, "runs", nil
    self:Refresh()
end

function MyLogUI:SelectRun(i)
    state.run, state.mode, state.viewPicked = i, "runs", nil
    self:Refresh()
end

-- "runs" | "boss" | "deaths"
function MyLogUI:SetMode(mode)
    state.mode = mode
    self:Refresh()
end

local function CurrentRun()
    local runs = state.inst and Log():GetRuns(state.inst) or {}
    if state.run > #runs then state.run = 1 end
    return runs[state.run], runs[state.run + 1], runs
end

-- The instance's name ("Serpentshrine Cavern", "... (Heroic)").
function MyLogUI:InstanceName(key)
    for _, e in ipairs(Log():GetInstances()) do
        if e.key == key then return e.name .. (e.heroic and " (Heroic)" or "") end
    end
    return "?"
end

-- The banner art of an instance: its raid key when it is a raid (ItemDB knows it), else nil (the plain banner).
function MyLogUI:InstanceArt(key)
    local db = ns.ItemDB
    if key and db and db.ItemKeyOf and db:ItemKeyOf(key) then return key end
    return nil
end

function MyLogUI:PickInstance(owner)
    UI():ContextMenu(owner, function(root)
        root:CreateTitle("Raids in My Log")
        for _, e in ipairs(Log():GetInstances()) do
            root:CreateRadio(e.name .. (e.heroic and " (Heroic)" or ""), function() return e.key == state.inst end,
                function() MyLogUI:SelectInstance(e.key) end)
        end
    end)
end

---------------------------------------------------------------------------
-- The night's banner (the board's hero) and its stat cards
---------------------------------------------------------------------------

-- The hero banner's own parts: the second pill ("best night") and the trend chart on its right.
local function DressHero(h)
    local k = K()
    h.num, h.metric, h.change = h.title, h.sub, h.pill    -- (the banner's title, sub line and pill)
    h.best = k.Pill(h)
    h.trend = k.Chart(h)
    h.trend:SetPoint("TOPRIGHT", h, "TOPRIGHT", -14, -14)
    h.trend:SetSize(TREND_W, S.BANNER.hero - 14 - 30)
    h.trend.inset = { l = 6, r = 10, t = 14, b = 6 }
    h.trendFrom = UI():Text(h, "small", "SUB")
    h.trendFrom:SetPoint("TOPLEFT", h.trend, "BOTTOMLEFT", 2, -3)
    h.trendTo = UI():Text(h, "small", "SUB", { justify = "RIGHT" })
    h.trendTo:SetPoint("TOPRIGHT", h.trend, "BOTTOMRIGHT", 0, -3)
    h:EnableMouse(true)
end

-- One stat card: label, value, change (a number; text shown as given) and whether up is good.
local function StatCell(i, label, value, change, higherIsBetter, fmt, icon)
    local note, kind = "", "mute"
    if change and abs(change) >= 0.05 then
        kind = ((change > 0) == higherIsBetter) and "up" or "down"
        note = strformat(fmt or "%+.1f", change)
    elseif change then
        note = "same"
    end
    panel.stats:SetCell(i, label, value, note, kind, icon)
end

local function Round1(x) return floor(x * 10 + 0.5) / 10 end

local function FillHero(run, prevRun, runs)
    local k = K()
    local C = k.C
    local h = panel.hero
    local view = state.view
    local L = Log()
    local now = L:RunNumbers(run, view)
    local before = prevRun and L:RunNumbers(prevRun, view) or {}
    h:SetArt(MyLogUI:InstanceArt(state.inst))
    h:SetKicker((state.run == 1 and "Latest night" or "Raid night") .. " · " .. k.Day(run.at))
    h:SetTitle(k.Num(now.value))
    h:SetSub((VIEW_BY_KEY[view].long:gsub("^%l", string.upper)))
    local text, kind = k.ChangeChip(k.Change(now.value, before.value), view ~= "tanking", prevRun and " vs last night" or "")
    h:SetPill(kind, text)
    -- best night of this instance (same view)
    local best = true
    for _, r in ipairs(runs) do
        if r ~= run then
            local v = L:RunNumbers(r, view).value
            if v and now.value and ((view ~= "tanking" and v > now.value) or (view == "tanking" and v < now.value)) then best = false end
        end
    end
    h.best:SetPill(k.PILL.best, (best and now.value and #runs > 1) and "best night" or nil)
    h.best:ClearAllPoints()
    if h.pill:IsShown() then h.best:SetPoint("LEFT", h.pill, "RIGHT", 6, 0)
    else h.best:SetPoint("LEFT", h.title, "RIGHT", 10, 0) end
    -- the stat cards
    local dDeaths = prevRun and (now.deaths - (before.deaths or 0)) or nil
    local function pts(a, b) return (a and b) and Round1((a - b) * 100) or nil end
    local function pct(x, d) return x and strformat("%." .. (d or 1) .. "f%%", x * 100) or "-" end
    if view == "healing" then
        StatCell(1, "Overheal", pct(now.overheal, 0), pts(now.overheal, before.overheal), false, nil, ICON.overheal)
        StatCell(2, "Active", pct(now.active), pts(now.active, before.active), true, nil, ICON.active)
    elseif view == "tanking" then
        StatCell(1, "Swings avoided", pct(now.avoid), pts(now.avoid, before.avoid), true, nil, ICON.swings)
        StatCell(2, "Active", pct(now.active), pts(now.active, before.active), true, nil, ICON.active)
    else
        StatCell(1, "Active", pct(now.active), pts(now.active, before.active), true, nil, ICON.active)
        StatCell(2, "Avoidable / kill", k.Num(now.avoidable), k.Change(now.avoidable, before.avoidable), false, "%+.0f%%", ICON.avoid)
    end
    StatCell(3, "Deaths", tostring(now.deaths), dDeaths, false, "%+d", ICON.deaths)
    StatCell(4, "Item level", now.ilvl and strformat("%.1f", now.ilvl) or "-",
        (now.ilvl and before.ilvl) and Round1(now.ilvl - before.ilvl) or nil, true, nil, ICON.ilvl)
    -- trend: up to 8 nights ending with this one
    local points, labels = {}, {}
    local from = min(#runs, state.run + TREND_N - 1)
    for i = from, state.run, -1 do
        local v = L:RunNumbers(runs[i], view).value
        if v then
            points[#points + 1] = { #points, v }
            labels[#points] = runs[i]
        end
    end
    if #points == 0 then points = { { 0, 0 } } end
    local lo, hi = math.huge, 0
    for _, p in ipairs(points) do lo = min(lo, p[2]); hi = max(hi, p[2]) end
    -- lift the floor so the change reads (the chart starts a bit under the lowest night)
    local floorV = max(0, lo - (hi - lo) * 0.6 - 1)
    local shifted = {}
    for i, p in ipairs(points) do shifted[i] = { p[1], p[2] - floorV } end
    local dots = {}
    for i, p in ipairs(shifted) do
        local last = i == #shifted
        dots[#dots + 1] = { p[1], p[2], last and C.gold or C.blue, last and 9 or 5, last and k.Num(points[i][2]) or nil }
    end
    h.trend:SetData({
        x0 = 0, x1 = max(1, #points - 1), y1 = (hi - floorV) * 1.12 + 1,
        series = { { points = shifted, color = C.blue, width = 2, fill = true, fillAlpha = 0.24, glow = true } },
        dots = dots,
        hover = function(x)
            local i = floor(x + 0.5) + 1
            local r = labels[i]
            if not r then return nil end
            return { { k.Day(r.at), C.mute }, { strformat("%s %s", k.Num(points[i][2]), VIEW_BY_KEY[view].metric), C.fg },
                { strformat("%d kill%s", r.kills, r.kills == 1 and "" or "s"), C.mute } }
        end,
    })
    h.trendFrom:SetText(#points > 1 and k.ShortDay(labels[1].at) or "")
    h.trendTo:SetText(k.ShortDay(run.at))
end

---------------------------------------------------------------------------
-- Boss cards (UI:CreateCard; a click opens the boss)
---------------------------------------------------------------------------

-- The tooltip lines under the boss's name.
local function CardLines(card)
    local r = card.row
    if not r then return {} end
    local k = K()
    local view = VIEW_BY_KEY[state.view]
    local lines = {}
    local p = r.kill
    if p then
        lines[#lines + 1] = strformat("Killed in %s · %s %s", k.Clock(p.dur), k.Num(r.value), view.metric)
        if r.prev then
            lines[#lines + 1] = strformat("Compared with your kill on %s (%s %s)%s", k.Day(r.prev.at),
                k.Num(Log():Metric(r.prev, state.view)), view.metric,
                r.sameSpec and "" or (", played as " .. tostring(r.prev.spec or "?")))
        else
            lines[#lines + 1] = "Your first kill of this boss in My Log."
        end
    elseif r.best then
        lines[#lines + 1] = strformat("No kill this night. Best pull: boss at %.1f%%.", r.best)
    end
    if r.deaths > 0 then
        lines[#lines + 1] = { strformat("%d death%s this night", r.deaths, r.deaths == 1 and "" or "s"), "BAD" }
    end
    lines[#lines + 1] = { "Click to open the fight.", "SUB" }
    return lines
end

-- (a boss card: UI:CreateCard with the boss's parts on a button over it)
local function NewBossCard(parent)
    local k = K()
    local ui = UI()
    local c = ui:CreateCard(parent, { tone = "card" })
    -- the whole card is the button (the shared row hover, a gold edge, the tooltip); its parts sit on it
    local hit = CreateFrame("Button", nil, c)
    hit:SetAllPoints()
    c.hit = hit
    ui:DecorateRow(hit, { hover = true })
    hit:RegisterForClicks("LeftButtonUp")
    hit:SetScript("OnClick", function()
        if c.row and ns.MyLogDetail then ns.MyLogDetail:ShowBoss(c.row) end
    end)
    hit:HookScript("OnEnter", function() ui:SetEdgeColor(c, S:Color("EDGE_FOCUS")) end)
    hit:HookScript("OnLeave", function() c:SetTone(c.tone) end)
    ui:AttachTooltip(hit, function(_, tip)
        if not c.row then return false end
        tip:AddLine(c.row.boss, S:RGB("GOLD"))
    end, function() return CardLines(c) end)
    c.port = k.Portrait(hit, 40)
    c.name = ui:Text(hit, "emph", "TEXT")
    c.sub = ui:Text(hit, "small", "SUB")
    c.extra = ui:Text(hit, "small", "SUB")
    c.num = ui:Text(hit, "page", "TEXT", { justify = "RIGHT" })
    c.chip = k.Pill(hit)
    c.spark = k.Spark(hit, 92, 34)
    -- how close to my best: a thin line along the bottom
    c.line = hit:CreateTexture(nil, "ARTWORK")
    c.line:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 1, 1)
    c.line:SetHeight(2)
    -- wipes only: the best pull's boss health
    c.prog = CreateFrame("Frame", nil, hit)
    c.prog:SetSize(160, 30)
    c.prog.lab = ui:Text(c.prog, "small", "SUB", { text = "best pull" })
    c.prog.lab:SetPoint("TOPLEFT")
    c.prog.val = ui:Text(c.prog, "emph", "TEXT", { justify = "RIGHT" })
    c.prog.val:SetPoint("TOPRIGHT")
    c.prog.well = ui:Fill(c.prog, "INSET", "ARTWORK")
    c.prog.well:ClearAllPoints()
    c.prog.well:SetPoint("BOTTOMLEFT", c.prog, "BOTTOMLEFT", 0, 4)
    c.prog.well:SetSize(160, 6)
    c.prog.fill = c.prog:CreateTexture(nil, "ARTWORK", nil, 1)
    c.prog.fill:SetPoint("LEFT", c.prog.well, "LEFT", 0, 0)
    c.prog.fill:SetHeight(6)
    return c
end

-- Places a card's parts for its height h (cards grow to fill the page; tall ones show a third line).
local function ShapeCard(c, h)
    local tall = h >= 66
    local ps = max(30, min(44, h - 26))
    c:SetHeight(h)
    c.port:SetPortraitSize(ps)
    c.port:ClearAllPoints()
    c.port:SetPoint("LEFT", c, "LEFT", 14, 0)
    local tx = 14 + ps + 12
    local block = tall and 46 or 30
    local top = -(h - block) / 2
    c.name:ClearAllPoints()
    c.name:SetPoint("TOPLEFT", c, "TOPLEFT", tx, top)
    c.sub:ClearAllPoints()
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
    c.extra:ClearAllPoints()
    c.extra:SetPoint("TOPLEFT", c.sub, "BOTTOMLEFT", 0, -3)
    c.extra:SetShown(tall)
    local sw = tall and 72 or 60
    c.spark:SetSize(sw, max(20, h - 26))
    c.spark:ClearAllPoints()
    c.spark:SetPoint("RIGHT", c, "RIGHT", -12, 0)
    UI():SetTextStyle(c.num, tall and "hero" or "page", "TEXT")
    c.num:ClearAllPoints()
    c.num:SetPoint("BOTTOMRIGHT", c, "RIGHT", -(sw + 22), tall and 1 or 0)
    c.chip:ClearAllPoints()
    c.chip:SetPoint("TOPRIGHT", c, "RIGHT", -(sw + 22), -4)
    local textW = (c:GetWidth() or 380) - tx - sw - 22 - 66
    c.name:SetWidth(textW)
    c.sub:SetWidth(textW)
    c.extra:SetWidth(textW)
    c.prog:ClearAllPoints()
    c.prog:SetPoint("RIGHT", c, "RIGHT", -14, 0)
end

local function FillCard(c, r)
    local k = K()
    local C = k.C
    c.row = r
    c.name:SetText(r.boss)
    c.port:SetBoss(r.boss, not r.kill)
    local higher = state.view ~= "tanking"
    local deaths = r.deaths > 0 and S:Wrap("BAD", r.deaths == 1 and "died once" or (r.deaths .. " deaths")) or nil
    if r.kill then
        local p = r.kill
        local s = p.s or {}
        local bits = { k.Clock(p.dur) .. " kill" }
        if s.act then bits[#bits + 1] = strformat("%.0f%% active", s.act * 100) end
        c.sub:SetText(table.concat(bits, "  ·  "))
        local more = {}
        local gaps = p.gaps and #p.gaps
        if gaps then more[#more + 1] = gaps == 1 and "1 idle gap" or (gaps .. " idle gaps") end
        if deaths then more[#more + 1] = deaths end
        c.extra:SetText(table.concat(more, "  ·  "))
        c.num:SetText(k.Num(r.value))
        c.num:Show()
        -- personal best of this boss (same view)?
        local best = r.value
        local isBest = r.prev ~= nil
        for _, v in ipairs(r.spark or {}) do
            if higher then
                if v > best then best = v; isBest = false end
            else
                if v < best then best = v; isBest = false end
            end
        end
        local pb = isBest and #(r.spark or {}) > 1
        if pb then
            c.chip:SetPill(k.PILL.best, "best")
        elseif r.prev then
            local text, kind = k.ChangeChip(r.change, higher, r.sameSpec and "" or "*")
            c.chip:SetPill(kind, text)
        else
            c.chip:SetPill("mute", "first kill")
        end
        c.spark:SetValues(r.spark)
        c.spark:Show()
        c.prog:Hide()
        local frac = (best and best > 0 and r.value) and (higher and r.value / best or best / r.value) or 1
        c.line:SetWidth(((c:GetWidth() or 380) - 2) * max(0.05, min(1, frac)))
        local col = pb and C.gold or C.blue
        UI():Gradient(c.line, "HORIZONTAL", A(col, 0), A(col, 0.55))
        c.line:Show()
        c:SetTone("card")
    else
        c.sub:SetText(strformat("%d pull%s  ·  no kill yet", r.pulls, r.pulls == 1 and "" or "s"))
        c.extra:SetText(deaths or "")
        c.num:Hide()
        c.chip:SetPill(nil)
        c.spark:Hide()
        c.line:Hide()
        c.prog:Show()
        local left = r.best or 100
        c.prog.val:SetText(strformat("%.0f%% left", left))
        c.prog.fill:SetWidth(max(1, 160 * (100 - left) / 100))
        -- (a data colour: the boss's health taken off, teal like the health bars of the meters)
        UI():Gradient(c.prog.fill, "HORIZONTAL", { 0.12, 0.54, 0.49, 1 }, { 0.37, 0.82, 0.78, 1 })
        c:SetTone("inset")
    end
end

local function LayoutCards(rows)
    local p = panel
    local area, scroll = p.cardsArea, p.cardsScroll
    local w = scroll:GetWidth() or 0
    if w <= 0 then w = S.INNER_W end
    local avail = scroll:GetHeight() or 0
    if avail <= 0 then avail = 230 end
    avail = avail - 2                                      -- (the scroll clips: keep the last row's edge inside)
    local lines = max(1, math.ceil(#rows / 2))
    local h = floor((avail - (lines - 1) * S.GAP) / lines)
    h = max(46, min(86, h))
    -- the cards shrink to fit; a raid with more bosses than fit at the smallest card scrolls instead of running
    -- under the nights' bars (Karazhan: 11 bosses)
    local need = lines * h + (lines - 1) * S.GAP
    if need > avail + 0.5 then w = w - 14 end              -- (room for the scroll bar)
    area:SetSize(w, max(need, 1))
    if need <= avail + 0.5 then scroll:SetVerticalScroll(0) end
    local cw = (w - S.GAP) / 2
    for i, r in ipairs(rows) do
        local c = p.cards[i]
        if not c then c = NewBossCard(area); p.cards[i] = c end
        c:ClearAllPoints()
        local col, line = (i - 1) % 2, floor((i - 1) / 2)
        c:SetPoint("TOPLEFT", area, "TOPLEFT", col * (cw + S.GAP), -line * (h + S.GAP))
        c:SetWidth(cw)
        ShapeCard(c, h)
        FillCard(c, r)
        c:Show()
    end
    UI():HideFrom(p.cards, #rows + 1)
end

---------------------------------------------------------------------------
-- Foot: the nights as bars
---------------------------------------------------------------------------

-- (the bars' looks: data colours on the "you" blue, the picked night gold)
local BAR_OFF = { A(S.C.YOU, 0.22), A(S.C.YOU, 0.38) }
local BAR_HOVER = { A(S.C.YOU, 0.40), A(S.C.YOU, 0.62) }
local BAR_ON = { S.C.GOLD_DEEP, S.C.GOLD }

local function PaintBar(b, look)
    UI():Gradient(b.bar, "VERTICAL", look[1], look[2])
end

local function NightBar(parent)
    local k = K()
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 28)
    b.bar = b:CreateTexture(nil, "ARTWORK")
    b.bar:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
    b.bar:SetWidth(14)
    b:SetScript("OnEnter", function(self) if not self.on then PaintBar(self, BAR_HOVER) end end)
    b:SetScript("OnLeave", function(self) if not self.on then PaintBar(self, BAR_OFF) end end)
    b:SetScript("OnClick", function(self) MyLogUI:SelectRun(self.index) end)
    UI():AttachTooltip(b, function(self, tip)
        local r = self.run
        if not r then return false end
        tip:AddLine(k.Day(r.at), S:RGB("GOLD"))
        tip:AddLine(strformat("%s %s · %d kill%s%s", k.Num(self.value), VIEW_BY_KEY[state.view].metric, r.kills,
            r.kills == 1 and "" or "s", r.wipes > 0 and strformat(", %d wipe%s", r.wipes, r.wipes == 1 and "" or "s") or ""),
            1, 1, 1)
    end, nil, { anchor = "ANCHOR_TOP" })
    return b
end

local function FillNights(runs)
    local p = panel
    local L = Log()
    local n = min(#runs, NIGHTS)
    local vals, lo, hi = {}, math.huge, 0
    for i = 1, n do
        local v = L:RunNumbers(runs[i], state.view).value or 0
        vals[i] = v
        lo, hi = min(lo, v), max(hi, v)
    end
    for slot = 1, n do
        local i = n - slot + 1                    -- oldest on the left
        local b = p.nights[slot]
        if not b then b = NightBar(p.foot); p.nights[slot] = b end
        b.index, b.run, b.value = i, runs[i], vals[i]
        b.on = i == state.run
        local f = (hi - lo) > 0 and (vals[i] - lo) / (hi - lo) or 1
        b.bar:SetHeight(8 + f * 18)
        PaintBar(b, b.on and BAR_ON or BAR_OFF)
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", p.foot, "BOTTOMLEFT", 2 + (slot - 1) * 20, 0)
        b:Show()
    end
    UI():HideFrom(p.nights, n + 1)
    p.nightsHead:SetRight(n > 1 and "click a night to open it" or nil)
end

-- My deaths in this instance's stored pulls (the Deaths tab's count).
local function DeathCount()
    local deaths = 0
    for _, pl in ipairs(Log():GetPulls()) do
        if (pl.iid or pl.zone) == state.inst then deaths = deaths + #(pl.deaths or {}) end
    end
    return deaths
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function ShowOff(p, L)
    local B = p.board
    B:Show()
    if ns.MyLogDetail then ns.MyLogDetail:HideAll() end
    B.toolbar:Hide()
    if L and L:IsEnabled() then
        B:ShowEmpty({ icon = ICON.log, title = "No boss pulls yet",
            text = "My Log is on. Your next raid boss pull shows up here, with how it compares to your last kill of "
                .. "that boss." })
    else
        B:ShowEmpty({ icon = ICON.log, title = "My Log is off",
            text = "Turn it on to record your own play in every raid boss pull: damage, healing, damage taken, casts, "
                .. "buffs and deaths. It stays on this PC. Nobody else can see it, the loot council included.",
            action = { text = "Turn on My Log", onClick = function()
                ns.DB:SetSetting("mylog.enabled", true)
                MyLogUI:Refresh()
            end } })
    end
    p.empty = B.empty
end

function MyLogUI:Refresh()
    local p = panel
    if not p or not p:IsShown() then
        if p then p.dirty = true end
        return
    end
    p.dirty = false
    local L = Log()
    local instances = L and L:GetInstances() or {}
    if #instances == 0 then return ShowOff(p, L) end
    local B = p.board
    B.toolbar:Show()
    B:HideEmpty()
    p.demoTag:SetShown(L:IsDemo())
    local found = false
    for _, e in ipairs(instances) do if e.key == state.inst then found = true end end
    if not found then state.inst, state.run, state.viewPicked, state.mode = instances[1].key, 1, nil, "runs" end
    local run, prevRun, runs = CurrentRun()
    if not run then return end
    if not state.viewPicked then
        local _, role = L:RunSpec(run)
        state.view = L:ViewForRole(role)
    end
    state.mode = state.mode or "runs"
    p.seg:Select(state.view)
    p.instDD:Refresh()
    B.toolbar:SetTabCount("deaths", DeathCount(), "muted")
    if state.mode == "boss" and ns.MyLogDetail then
        B:Hide()
        p.runsView:Hide()
        ns.MyLogDetail:Refresh(state, run, prevRun)
        return
    end
    B:Show()
    B.toolbar:SelectTab(state.mode == "deaths" and "deaths" or "runs")
    local runsMode = state.mode ~= "deaths" or not ns.MyLogDetail
    p.hero:SetShown(runsMode)
    B:Layout()
    p.runsView:SetShown(runsMode)
    if not runsMode then
        ns.MyLogDetail:Refresh(state, run, prevRun)
        return
    end
    if ns.MyLogDetail then ns.MyLogDetail:HideAll() end
    FillHero(run, prevRun, runs)
    lastRows = L:BossRows(run, state.view)
    p.cardsHead:SetTitle(state.run == 1 and "Bosses this night" or "Bosses that night")
    LayoutCards(lastRows)
    FillNights(runs)
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

-- The toolbar: the tabs, then the DEMO pill, the raid picker and the view switch.
local function BuildToolbar(p)
    local ui = UI()
    local bar = p.board.toolbar
    bar:SetTabs({ { key = "runs", text = "Raid nights" }, { key = "deaths", text = "Deaths" } },
        function(key) MyLogUI:SetMode(key) end)
    p.deathsBtn = bar:GetTab("deaths")
    p.demoTag = ui:CreatePill(bar, "warn", "DEMO")
    ui:AttachTooltip(p.demoTag, "Demo data", "Made-up raid nights while demo mode is on. Your own log is untouched "
        .. "and keeps recording.")
    p.instDD = ui:CreateSleekDropdown(bar, 190,
        function()
            local out = { { isTitle = true, text = "Raids in My Log" } }
            for _, e in ipairs(Log():GetInstances()) do
                out[#out + 1] = { value = e.key, text = e.name .. (e.heroic and " (Heroic)" or "") }
            end
            return out
        end,
        function() return state.inst end,
        function(key) MyLogUI:SelectInstance(key) end)
    local items = {}
    for i, v in ipairs(VIEWS) do items[i] = { key = v.key, label = v.label } end
    p.seg = ui:CreateSegments(bar, items, function(key) MyLogUI:SetView(key) end, { itemW = 70 })
    bar:SetFilters({ p.demoTag, p.instDD, p.seg })
end

-- The runs view in the board's body: the stat cards, the bosses, the nights.
local function BuildRunsView(p)
    local ui = UI()
    local rv = CreateFrame("Frame", nil, p.board.body)
    rv:SetAllPoints(p.board.body)
    p.runsView = rv
    p.stats = K().StatStrip(rv, 4)
    p.stats:SetPoint("TOPLEFT", rv, "TOPLEFT", 0, 0)
    p.stats:SetPoint("TOPRIGHT", rv, "TOPRIGHT", 0, 0)
    p.hero.cells = p.stats.cells

    p.cardsHead = ui:CreateSectionHeader(rv, "Bosses this night", { right = "vs your last kill · last 8 kills" })
    p.cardsHead:SetPoint("TOPLEFT", p.stats, "BOTTOMLEFT", 0, -S.GAP)
    p.cardsHead:SetPoint("TOPRIGHT", p.stats, "BOTTOMRIGHT", 0, -S.GAP)
    p.cardsLabel = p.cardsHead

    -- the cards fill the space between the heading and the foot: they shrink to fit, and scroll when even the
    -- smallest cards don't (the scroll bar only shows then)
    p.cardsScroll = ui:CreateScrollFrame(rv)
    p.cardsScroll:SetPoint("TOPLEFT", p.cardsHead, "BOTTOMLEFT", 0, -S.GAP)
    p.cardsScroll:SetPoint("BOTTOMRIGHT", rv, "BOTTOMRIGHT", 0, FOOT_H + S.GAP)
    p.cardsArea = CreateFrame("Frame", nil, p.cardsScroll)
    p.cardsArea:SetSize(S.INNER_W, 1)
    p.cardsScroll:SetScrollChild(p.cardsArea)
    p.cardsScroll:HookScript("OnSizeChanged", function() if p:IsShown() and lastRows then LayoutCards(lastRows) end end)

    local foot = CreateFrame("Frame", nil, rv)
    foot:SetPoint("BOTTOMLEFT", rv, "BOTTOMLEFT", 0, 0)
    foot:SetPoint("BOTTOMRIGHT", rv, "BOTTOMRIGHT", 0, 0)
    foot:SetHeight(FOOT_H)
    p.foot = foot
    p.nightsHead = ui:CreateSectionHeader(foot, "Raid nights", { style = "caps" })
    p.nightsHead:SetPoint("TOPLEFT", foot, "TOPLEFT", 0, 0)
    p.nightsHead:SetPoint("TOPRIGHT", foot, "TOPRIGHT", 0, 0)
end

function MyLogUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.cards, p.nights = {}, {}
    p.board = UI():CreateLayout("board", p, { hero = { size = "hero", artTint = 0.55 } })
    p.body = p.board.content
    p.hero = p.board.hero
    DressHero(p.hero)
    BuildToolbar(p)
    BuildRunsView(p)
    function p:OnPanelShown() MyLogUI:Refresh() end
    p:HookScript("OnShow", function(self) if self.dirty then MyLogUI:Refresh() end end)
    return p
end

function MyLogUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("mylog", "My Log", 3.52, function(parent) return MyLogUI:CreatePanel(parent) end, nil,
            { layout = "board" })
    end
    local function changed() MyLogUI:RequestRefresh() end
    ns:On("MYLOG_CHANGED", changed)
    ns:On("SETTINGS_CHANGED", function(path) if path == "mylog.enabled" then changed() end end)
    ns:On("DEMO_TOGGLED", function() state.mode = "runs"; state.inst = nil; changed() end)
end

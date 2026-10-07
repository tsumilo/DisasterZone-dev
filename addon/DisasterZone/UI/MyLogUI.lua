if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogUI.lua", ...) then return end -- DisasterZone: the My Log page (Raids > My Log).
-- My own boss pulls from Core/MyLog.lua, one raid night (run) at a time. Drawn with UI/MyLogKit.lua.
--   top:     breadcrumb My Log > instance (click: pick another instance) [> boss | Deaths]; the view switch
--            Damage | Healing | Tanking (starts on the role played most in the run; every view is there for
--            every role); a DEMO tag while demo mode shows made-up pulls (Core/MyLogDemo.lua)
--   banner:  the night's headline number big (average over its kills), its change from the night before, a star
--            when it is my best night here, a quiet line of four more numbers, and the trend of my last 8 nights
--   cards:   a card per boss: portrait, kill time and active time, my number with its change from my previous
--            kill of the boss (same spec first) or a star for a personal best, the last 8 kills; a thin line along
--            the bottom shows how close the kill came to my best. A boss with wipes only shows its lowest health.
--            A click opens the boss (UI/MyLogDetail.lua).
--   footer:  every night as a bar (taller = a higher number), a click opens it; Deaths with their count.
-- Off: an explainer with a button that turns My Log on. Nothing on this page is ever sent.
local addonName, ns = ...

local MyLogUI = ns:NewModule("MyLogUI")

local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local strformat = string.format

local PAD = 14
local TOP_Y = -8
local HERO_Y, HERO_H = -38, 146
local CARDS_LABEL_Y = HERO_Y - HERO_H - 12
local CARDS_Y = CARDS_LABEL_Y - 16
local CARD_H, CARD_GAP = 50, 6
local FOOT_H = 44
local NIGHTS = 12
local TREND_N = 8

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

---------------------------------------------------------------------------
-- Banner
---------------------------------------------------------------------------

local function BuildHero(parent)
    local k = K()
    local C = k.C
    local h = k.Card(parent, { 0.08, 0.10, 0.14, 1 }, 0.08)
    h:SetHeight(HERO_H)
    -- a cool light from the top left over a dark gradient
    k.Gradient(h.bg, { 0.063, 0.075, 0.102, 1 }, { 0.082, 0.102, 0.141, 1 })
    h.glow = h:CreateTexture(nil, "BACKGROUND", nil, 1)
    h.glow:SetPoint("TOPLEFT")
    h.glow:SetSize(380, HERO_H)
    k.Gradient(h.glow, { C.blue[1], C.blue[2], C.blue[3], 0.10 }, { C.blue[1], C.blue[2], C.blue[3], 0 }, "HORIZONTAL")

    h.when = k.Label(h, "")
    h.when:SetPoint("TOPLEFT", h, "TOPLEFT", 18, -14)
    h.num = k.Text(h, "hero")
    h.num:SetPoint("TOPLEFT", h, "TOPLEFT", 16, -30)
    h.metric = k.Label(h, "")
    h.metric:SetTextColor(0.79, 0.77, 0.74)
    h.metric:SetPoint("TOPLEFT", h, "TOPLEFT", 18, -82)
    h.change = k.Chip(h, 16)
    h.change:SetPoint("LEFT", h.metric, "RIGHT", 8, 0)
    h.best = k.Chip(h, 16)
    h.best:SetPoint("LEFT", h.change, "RIGHT", 5, 0)
    h.stats = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.stats:SetPoint("TOPLEFT", h, "TOPLEFT", 18, -110)
    h.stats:SetPoint("RIGHT", h, "LEFT", 400, 0)
    h.stats:SetJustifyH("LEFT")
    h.stats:SetWordWrap(false)

    h.trend = k.Chart(h)
    h.trend:SetPoint("TOPRIGHT", h, "TOPRIGHT", -14, -14)
    h.trend:SetSize(350, 104)
    h.trend.inset = { l = 6, r = 10, t = 14, b = 6 }
    h.trendFrom = k.Label(h, "")
    h.trendFrom:SetPoint("TOPLEFT", h.trend, "BOTTOMLEFT", 2, -3)
    h.trendTo = k.Label(h, "")
    h.trendTo:SetPoint("TOPRIGHT", h.trend, "BOTTOMRIGHT", 0, -3)
    h.trendTo:SetJustifyH("RIGHT")
    h:EnableMouse(true)
    return h
end

local function StatBit(value, label, change, higherIsBetter, isCount)
    local k = K()
    local C = k.C
    local s = k.Paint(value, C.fg) .. " " .. k.Paint(label, C.mute)
    if change then
        local good
        if isCount then good = change < 0 else good = (change > 0) == higherIsBetter end
        if abs(change) >= 0.05 then s = s .. " " .. k.Paint(change > 0 and ("+" .. change) or tostring(change), good and C.up or C.down) end
    end
    return s
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
    h.when:SetText(((state.run == 1 and "Latest night" or "Raid night") .. " · " .. k.Day(run.at)):upper())
    h.num:SetText(k.Num(now.value))
    h.metric:SetText(VIEW_BY_KEY[view].long:upper())
    local text, kind = k.ChangeChip(k.Change(now.value, before.value), view ~= "tanking", prevRun and " vs last night" or "")
    h.change:Set(text, kind)
    -- best night of this instance (same view)
    local best = true
    for _, r in ipairs(runs) do
        if r ~= run then
            local v = L:RunNumbers(r, view).value
            if v and now.value and ((view ~= "tanking" and v > now.value) or (view == "tanking" and v < now.value)) then best = false end
        end
    end
    h.best:Set((best and now.value and #runs > 1) and "best night" or nil, "pb")
    if view == "healing" then
        h.stats:SetText(table.concat({
            StatBit(now.overheal and strformat("%.0f%%", now.overheal * 100) or "-", "overheal",
                now.overheal and before.overheal and Round1((now.overheal - before.overheal) * 100), false),
            StatBit(now.active and strformat("%.1f%%", now.active * 100) or "-", "active",
                now.active and before.active and Round1((now.active - before.active) * 100), true),
            StatBit(tostring(now.deaths), now.deaths == 1 and "death" or "deaths", prevRun and (now.deaths - (before.deaths or 0)), false, true),
            StatBit(now.ilvl and strformat("%.1f", now.ilvl) or "-", "ilvl", now.ilvl and before.ilvl and Round1(now.ilvl - before.ilvl), true),
        }, "    "))
    elseif view == "tanking" then
        h.stats:SetText(table.concat({
            StatBit(now.avoid and strformat("%.1f%%", now.avoid * 100) or "-", "swings avoided",
                now.avoid and before.avoid and Round1((now.avoid - before.avoid) * 100), true),
            StatBit(now.active and strformat("%.1f%%", now.active * 100) or "-", "active",
                now.active and before.active and Round1((now.active - before.active) * 100), true),
            StatBit(tostring(now.deaths), now.deaths == 1 and "death" or "deaths", prevRun and (now.deaths - (before.deaths or 0)), false, true),
        }, "    "))
    else
        local avPct = k.Change(now.avoidable, before.avoidable)
        h.stats:SetText(table.concat({
            StatBit(now.active and strformat("%.1f%%", now.active * 100) or "-", "active",
                now.active and before.active and Round1((now.active - before.active) * 100), true),
            StatBit(k.Num(now.avoidable), "avoidable a kill", nil) .. (avPct and abs(avPct) >= 0.5 and (" " .. k.Paint(strformat("%+.0f%%", avPct), avPct < 0 and C.up or C.down)) or ""),
            StatBit(tostring(now.deaths), now.deaths == 1 and "death" or "deaths", prevRun and (now.deaths - (before.deaths or 0)), false, true),
            StatBit(now.ilvl and strformat("%.1f", now.ilvl) or "-", "ilvl", now.ilvl and before.ilvl and Round1(now.ilvl - before.ilvl), true),
        }, "    "))
    end
    -- trend: up to 8 nights ending with this one
    local pts, labels = {}, {}
    local from = min(#runs, state.run + TREND_N - 1)
    for i = from, state.run, -1 do
        local v = L:RunNumbers(runs[i], view).value
        if v then
            pts[#pts + 1] = { #pts, v }
            labels[#pts] = runs[i]
        end
    end
    if #pts == 0 then pts = { { 0, 0 } } end
    local lo, hi = math.huge, 0
    for _, p in ipairs(pts) do lo = min(lo, p[2]); hi = max(hi, p[2]) end
    -- lift the floor so the change reads (the chart starts a bit under the lowest night)
    local floorV = max(0, lo - (hi - lo) * 0.6 - 1)
    local shifted = {}
    for i, p in ipairs(pts) do shifted[i] = { p[1], p[2] - floorV } end
    local dots = {}
    for i, p in ipairs(shifted) do
        local last = i == #shifted
        dots[#dots + 1] = { p[1], p[2], last and C.gold or C.blue, last and 9 or 5, last and k.Num(pts[i][2]) or nil }
    end
    h.trend:SetData({
        x0 = 0, x1 = max(1, #pts - 1), y1 = (hi - floorV) * 1.12 + 1,
        series = { { points = shifted, color = C.blue, width = 2, fill = true, fillAlpha = 0.24, glow = true } },
        dots = dots,
        hover = function(x)
            local i = floor(x + 0.5) + 1
            local r = labels[i]
            if not r then return nil end
            return { { k.Day(r.at), C.mute }, { strformat("%s %s", k.Num(pts[i][2]), VIEW_BY_KEY[view].metric), C.fg },
                { strformat("%d kill%s", r.kills, r.kills == 1 and "" or "s"), C.mute } }
        end,
    })
    h.trendFrom:SetText(#pts > 1 and k.ShortDay(labels[1].at):upper() or "")
    h.trendTo:SetText(k.ShortDay(run.at):upper())
end

---------------------------------------------------------------------------
-- Boss cards
---------------------------------------------------------------------------

local function CardTip(card)
    local r = card.row
    if not r then return end
    local k = K()
    local view = VIEW_BY_KEY[state.view]
    local lines = { r.boss }
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
        lines[#lines + 1] = { strformat("%d death%s this night", r.deaths, r.deaths == 1 and "" or "s"), k.C.down[1], k.C.down[2], k.C.down[3] }
    end
    lines[#lines + 1] = { "Click to open the fight.", k.C.mute[1], k.C.mute[2], k.C.mute[3] }
    UI():SetTextTooltip(card, lines)
end

local function NewCard(parent)
    local k = K()
    local C = k.C
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H)
    c.bg = c:CreateTexture(nil, "BACKGROUND")
    c.bg:SetAllPoints()
    c.bg:SetColorTexture(C.card[1], C.card[2], C.card[3], 1)
    UI():AddEdges(c, "BORDER", true)
    UI():SetEdgeColor(c, 1, 1, 1, 0.07)
    c.port = k.Portrait(c, 32)
    c.port:SetPoint("LEFT", c, "LEFT", 12, 0)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    c.name:SetPoint("TOPLEFT", c, "TOPLEFT", 54, -10)
    c.name:SetWidth(180)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)
    c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.sub:SetWidth(180)
    c.sub:SetJustifyH("LEFT")
    c.sub:SetWordWrap(false)
    c.num = k.Text(c, "num")
    c.num:SetPoint("TOPRIGHT", c, "TOPRIGHT", -82, -8)
    c.num:SetJustifyH("RIGHT")
    c.chip = k.Chip(c, 15)
    c.chip:SetPoint("TOPRIGHT", c, "TOPRIGHT", -82, -29)
    c.spark = k.Spark(c, 62, 26)
    c.spark:SetPoint("RIGHT", c, "RIGHT", -10, 0)
    -- how close to my best: a thin line along the bottom
    c.line = c:CreateTexture(nil, "ARTWORK")
    c.line:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 1, 1)
    c.line:SetHeight(2)
    -- wipes only: the best pull's boss health
    c.prog = CreateFrame("Frame", nil, c)
    c.prog:SetSize(150, 30)
    c.prog:SetPoint("RIGHT", c, "RIGHT", -12, 0)
    c.prog.lab = c.prog:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    c.prog.lab:SetPoint("TOPLEFT")
    c.prog.lab:SetText("best pull")
    c.prog.val = k.Text(c.prog, "numS")
    c.prog.val:SetPoint("TOPRIGHT")
    c.prog.val:SetJustifyH("RIGHT")
    c.prog.well = c.prog:CreateTexture(nil, "ARTWORK")
    c.prog.well:SetColorTexture(C.well[1], C.well[2], C.well[3], 1)
    c.prog.well:SetPoint("BOTTOMLEFT", c.prog, "BOTTOMLEFT", 0, 4)
    c.prog.well:SetSize(150, 6)
    c.prog.fill = c.prog:CreateTexture(nil, "ARTWORK", nil, 1)
    c.prog.fill:SetPoint("LEFT", c.prog.well, "LEFT", 0, 0)
    c.prog.fill:SetHeight(6)
    c:SetScript("OnEnter", function(self)
        UI():SetEdgeColor(self, 1, 0.82, 0, 0.45)
        CardTip(self)
    end)
    c:SetScript("OnLeave", function(self)
        UI():SetEdgeColor(self, 1, 1, 1, 0.07)
        GameTooltip:Hide()
    end)
    c:RegisterForClicks("LeftButtonUp")
    c:SetScript("OnClick", function(self)
        if self.row and ns.MyLogDetail then ns.MyLogDetail:ShowBoss(self.row) end
    end)
    return c
end

local function FillCard(c, r)
    local k = K()
    local C = k.C
    c.row = r
    c.name:SetText(r.boss)
    c.port:SetBoss(r.boss, not r.kill)
    local higher = state.view ~= "tanking"
    if r.kill then
        local p = r.kill
        local act = p.s and p.s.act
        local bits = { "kill " .. k.Clock(p.dur) }
        if act then bits[#bits + 1] = strformat("%.0f%% active", act * 100) end
        if r.deaths > 0 then bits[#bits + 1] = k.Paint(r.deaths == 1 and "died" or (r.deaths .. " deaths"), C.down) end
        c.sub:SetText(table.concat(bits, " · "))
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
        if isBest and (#(r.spark or {}) > 1) then
            c.chip:Set("best", "pb")
        elseif r.prev then
            local text, kind = k.ChangeChip(r.change, higher, r.sameSpec and "" or "*")
            c.chip:Set(text, kind)
        else
            c.chip:Set("first kill", "mute")
        end
        c.spark:SetValues(r.spark)
        c.spark:Show()
        c.prog:Hide()
        local frac = (best and best > 0 and r.value) and (higher and r.value / best or best / r.value) or 1
        local w = ((c:GetWidth() or 380) - 2) * max(0.05, min(1, frac))
        c.line:SetWidth(w)
        local col = (isBest and #(r.spark or {}) > 1) and C.gold or C.blue
        k.Gradient(c.line, { col[1], col[2], col[3], 0 }, { col[1], col[2], col[3], 0.8 }, "HORIZONTAL")
        c.line:Show()
        c.bg:SetColorTexture(C.card[1], C.card[2], C.card[3], 1)
    else
        c.sub:SetText(strformat("%d pull%s · no kill yet", r.pulls, r.pulls == 1 and "" or "s"))
        c.num:Hide()
        c.chip:Set(nil)
        c.spark:Hide()
        c.line:Hide()
        c.prog:Show()
        local left = r.best or 100
        c.prog.val:SetText(strformat("%.0f%% left", left))
        c.prog.fill:SetWidth(max(1, 150 * (100 - left) / 100))
        k.Gradient(c.prog.fill, { 0.12, 0.54, 0.49, 1 }, { 0.37, 0.82, 0.78, 1 }, "HORIZONTAL")
        c.bg:SetColorTexture(C.card2[1] * 0.85, C.card2[2] * 0.85, C.card2[3] * 0.85, 1)
    end
end

local function LayoutCards(rows)
    local p = panel
    local child = p.cardsChild
    local w = (p.cardsScroll:GetWidth() or 772)
    if w <= 0 then w = 772 end
    child:SetWidth(w)
    local cw = (w - CARD_GAP) / 2
    for i, r in ipairs(rows) do
        local c = p.cards[i]
        if not c then c = NewCard(child); p.cards[i] = c end
        c:ClearAllPoints()
        local col, line = (i - 1) % 2, floor((i - 1) / 2)
        c:SetPoint("TOPLEFT", child, "TOPLEFT", col * (cw + CARD_GAP), -line * (CARD_H + CARD_GAP))
        c:SetWidth(cw)
        FillCard(c, r)
        c:Show()
    end
    for i = #rows + 1, #p.cards do p.cards[i]:Hide() end
    child:SetHeight(max(1, floor((#rows + 1) / 2) * (CARD_H + CARD_GAP)))
end

---------------------------------------------------------------------------
-- Footer: the nights as bars, Deaths
---------------------------------------------------------------------------

local function FillNights(runs)
    local k = K()
    local C = k.C
    local p = panel
    local L = Log()
    local n = min(#runs, NIGHTS)
    local vals, lo, hi = {}, math.huge, 0
    for i = 1, n do
        local v = L:RunNumbers(runs[i], state.view).value or 0
        vals[i] = v
        lo, hi = min(lo, v), max(hi, v)
    end
    for i, b in ipairs(p.nights) do b:Hide() end
    for slot = 1, n do
        local i = n - slot + 1                    -- oldest on the left
        local b = p.nights[slot]
        if not b then
            b = CreateFrame("Button", nil, p.foot)
            b:SetSize(20, 28)
            b.bar = b:CreateTexture(nil, "ARTWORK")
            b.bar:SetPoint("BOTTOM", b, "BOTTOM", 0, 0)
            b.bar:SetWidth(18)
            b:SetScript("OnEnter", function(self)
                local r = self.run
                if not r then return end
                UI():SetTextTooltip(self, { k.Day(r.at), strformat("%s %s · %d kill%s%s", k.Num(self.value),
                    VIEW_BY_KEY[state.view].metric, r.kills, r.kills == 1 and "" or "s",
                    r.wipes > 0 and strformat(", %d wipe%s", r.wipes, r.wipes == 1 and "" or "s") or "") }, "ANCHOR_TOP")
                if not self.on then self.bar:SetVertexColor(0.30, 0.38, 0.52, 1) end
            end)
            b:SetScript("OnLeave", function(self)
                GameTooltip:Hide()
                if not self.on then self.bar:SetVertexColor(0.19, 0.23, 0.31, 1) end
            end)
            b:SetScript("OnClick", function(self) MyLogUI:SelectRun(self.index) end)
            p.nights[slot] = b
        end
        b.index, b.run, b.value = i, runs[i], vals[i]
        b.on = i == state.run
        local f = (hi - lo) > 0 and (vals[i] - lo) / (hi - lo) or 1
        b.bar:SetHeight(8 + f * 18)
        if b.on then
            k.Gradient(b.bar, { 0.66, 0.54, 0, 1 }, { 1, 0.82, 0, 1 })
            b.bar:SetVertexColor(1, 1, 1, 1)
        else
            b.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
            b.bar:SetVertexColor(0.19, 0.23, 0.31, 1)
        end
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", p.nightsLab, "BOTTOMRIGHT", 10 + (slot - 1) * 24, -4)
        b:Show()
    end
    p.nightsHint:ClearAllPoints()
    p.nightsHint:SetPoint("LEFT", p.nightsLab, "RIGHT", 18 + n * 24, 0)
    p.nightsHint:SetText(n > 1 and "click a night to open it" or "")
    -- deaths in this instance's stored pulls
    local deaths = 0
    for _, pl in ipairs(L:GetPulls()) do
        if (pl.iid or pl.zone) == state.inst then deaths = deaths + #(pl.deaths or {}) end
    end
    p.deathsBtn:SetText(deaths > 0 and ("Deaths  " .. k.Paint(deaths, C.down)) or "Deaths")
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

local function InstanceName(key)
    for _, e in ipairs(Log():GetInstances()) do
        if e.key == key then return e.name .. (e.heroic and " (Heroic)" or "") end
    end
    return "?"
end

function MyLogUI:Crumb(extra)
    local parts = {
        { "My Log", state.mode ~= "runs" and function() MyLogUI:SetMode("runs") end or nil },
        { InstanceName(state.inst), function(btn) MyLogUI:PickInstance(btn) end },
    }
    if extra then parts[#parts + 1] = { extra } end
    panel.crumb:Set(parts)
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

function MyLogUI:Refresh()
    local p = panel
    if not p or not p:IsShown() then
        if p then p.dirty = true end
        return
    end
    p.dirty = false
    local L = Log()
    local instances = L and L:GetInstances() or {}
    local hasData = #instances > 0
    p.body:SetShown(hasData)
    p.empty:SetShown(not hasData)
    if not hasData then
        if L and L:IsEnabled() then
            p.empty.title:SetText("No boss pulls yet")
            p.empty.text:SetText("My Log is on. Your next raid boss pull shows up here, with how it compares "
                .. "to your last kill of that boss.")
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
    p.seg:SetSelected(state.view)
    state.mode = state.mode or "runs"
    p.runsView:SetShown(state.mode == "runs")
    if state.mode ~= "runs" and ns.MyLogDetail then
        ns.MyLogDetail:Refresh(state, run, prevRun)
        return
    end
    if ns.MyLogDetail then ns.MyLogDetail:HideAll() end
    self:Crumb()
    FillHero(run, prevRun, runs)
    lastRows = L:BossRows(run, state.view)
    p.cardsLabel:SetText(((state.run == 1 and "Bosses this night" or "Bosses that night")):upper())
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

function MyLogUI:CreatePanel(parent)
    if panel then return panel end
    local k = K()
    local C = k.C
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.cards, p.nights = {}, {}

    -- empty state
    local e = CreateFrame("Frame", nil, p)
    e:SetPoint("CENTER", p, "CENTER", 0, 30)
    e:SetSize(460, 190)
    e.port = k.Dot(e, 54, C.gold, 0.12, "ARTWORK")
    e.port:SetPoint("TOP", e, "TOP", 0, 0)
    e.icon = e:CreateTexture(nil, "OVERLAY")
    e.icon:SetSize(30, 30)
    e.icon:SetPoint("CENTER", e.port, "CENTER")
    e.icon:SetTexture(134939)        -- a scroll
    e.title = k.Text(e, "title")
    e.title:SetPoint("TOP", e.port, "BOTTOM", 0, -12)
    e.title:SetJustifyH("CENTER")
    e.title:SetTextColor(C.gold[1], C.gold[2], C.gold[3])
    e.text = e:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    e.text:SetPoint("TOP", e.title, "BOTTOM", 0, -10)
    e.text:SetWidth(430)
    e.text:SetJustifyH("CENTER")
    e.text:SetSpacing(3)
    e.text:SetTextColor(0.79, 0.77, 0.74)
    e.btn = UI():CreateSleekButton(e, "Turn on My Log", 160, 26, function()
        ns.DB:SetSetting("mylog.enabled", true)
        MyLogUI:Refresh()
    end, "primary")
    e.btn:SetPoint("TOP", e.text, "BOTTOM", 0, -16)
    p.empty = e

    local body = CreateFrame("Frame", nil, p)
    body:SetAllPoints(p)
    p.body = body

    p.crumb = k.Crumb(body)
    p.crumb:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, TOP_Y)
    p.seg = k.Segment(body, VIEWS, function(key) MyLogUI:SetView(key) end, 70)
    p.seg:SetPoint("TOPRIGHT", body, "TOPRIGHT", -PAD, TOP_Y + 2)
    p.demoTag = k.Chip(body, 16)
    p.demoTag:Set("DEMO", "av")
    p.demoTag:SetPoint("RIGHT", p.seg, "LEFT", -10, 0)
    p.demoTag:EnableMouse(true)
    p.demoTag:SetScript("OnEnter", function(self)
        UI():SetTextTooltip(self, { "Demo data", "Made-up raid nights while demo mode is on. Your own log is "
            .. "untouched and keeps recording." })
    end)
    p.demoTag:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the subtitle line the detail views use (under the crumb)
    p.sub = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.sub:SetPoint("TOPLEFT", body, "TOPLEFT", PAD, TOP_Y - 22)
    p.sub:SetJustifyH("LEFT")
    p.sub:Hide()

    local rv = CreateFrame("Frame", nil, body)
    rv:SetAllPoints(body)
    p.runsView = rv

    p.hero = BuildHero(rv)
    p.hero:SetPoint("TOPLEFT", rv, "TOPLEFT", PAD, HERO_Y)
    p.hero:SetPoint("TOPRIGHT", rv, "TOPRIGHT", -PAD, HERO_Y)

    p.cardsLabel = k.Label(rv, "")
    p.cardsLabel:SetPoint("TOPLEFT", rv, "TOPLEFT", PAD + 2, CARDS_LABEL_Y)
    p.cardsHint = k.Label(rv, "vs your last kill · last 8 kills")
    p.cardsHint:SetTextColor(C.dim[1], C.dim[2], C.dim[3])
    p.cardsHint:SetPoint("TOPRIGHT", rv, "TOPRIGHT", -PAD - 2, CARDS_LABEL_Y)
    p.cardsHint:SetJustifyH("RIGHT")

    p.cardsScroll = UI():CreateScrollFrame(rv, nil)
    p.cardsScroll:SetPoint("TOPLEFT", rv, "TOPLEFT", PAD, CARDS_Y)
    p.cardsScroll:SetPoint("BOTTOMRIGHT", rv, "BOTTOMRIGHT", -PAD, FOOT_H + 6)
    p.cardsChild = CreateFrame("Frame", nil, p.cardsScroll)
    p.cardsChild:SetSize(772, 10)
    p.cardsScroll:SetScrollChild(p.cardsChild)
    p.cardsScroll:HookScript("OnSizeChanged", function() if p:IsShown() and lastRows then LayoutCards(lastRows) end end)

    local foot = CreateFrame("Frame", nil, rv)
    foot:SetPoint("BOTTOMLEFT", rv, "BOTTOMLEFT", PAD, 6)
    foot:SetPoint("BOTTOMRIGHT", rv, "BOTTOMRIGHT", -PAD, 6)
    foot:SetHeight(FOOT_H)
    foot.rule = foot:CreateTexture(nil, "BORDER")
    foot.rule:SetColorTexture(1, 1, 1, 0.07)
    foot.rule:SetHeight(1)
    foot.rule:SetPoint("TOPLEFT")
    foot.rule:SetPoint("TOPRIGHT")
    p.foot = foot
    p.nightsLab = k.Label(foot, "Raid nights")
    p.nightsLab:SetPoint("LEFT", foot, "LEFT", 2, -4)
    p.nightsHint = foot:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.deathsBtn = UI():CreateSleekButton(foot, "Deaths", 96, 24, function()
        MyLogUI:SetMode(state.mode == "deaths" and "runs" or "deaths")
    end)
    p.deathsBtn:SetPoint("RIGHT", foot, "RIGHT", 0, -4)

    function p:OnPanelShown() MyLogUI:Refresh() end
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

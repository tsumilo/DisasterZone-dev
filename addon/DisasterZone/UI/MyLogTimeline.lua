if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogTimeline.lua", ...) then return end -- DisasterZone: My Log cast timeline.
-- The boss screen's advanced breakdown (UI/MyLogDetail.lua, "Timeline"): one pull laid out in lanes over the fight.
--   Boss lane:  the boss side (Core/MyLog.lua p.bev): its casts as violet ticks, auras on it as violet bars as long as
--               they lasted (Whirlwind, Magic Barrier...), yells and emotes as gold dots, adds dying as grey dots.
--   My lanes:   one per spell I cast most (up to MAX_LANES), each cast a tick, cast and channel times as bars.
--   Idle gaps of 2 s or more shade every lane red, so the reason sits right above the gap.
-- Hover reads out what happened around that second; the mouse wheel zooms around the mouse, right-click zooms out.
local addonName, ns = ...

local MyLogTimeline = ns:NewModule("MyLogTimeline")

local S = ns.Style
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local strformat = string.format

local LABEL_W = 166
local LANE_H, LANE_GAP = 17, 3
local AXIS_H = 16
local MAX_LANES = 8
-- (data colours: one a lane, the first the gold of "this pull")
local PALETTE = {
    S.C.GOLD, { 0.35, 0.66, 1 }, { 0.36, 0.86, 0.62 }, { 1, 0.55, 0.30 }, { 0.80, 0.55, 1 },
    { 0.45, 0.85, 0.90 }, { 1, 0.45, 0.60 }, { 0.75, 0.80, 0.45 },
}

local function K() return ns.MyLogKit end
local function UI() return ns.UI end
local LANE_RGB = S.C.HAIRLINE             -- (the grooves and grid: white at a low alpha)

local function SpellName(p, key)
    local n = p and p.names and p.names[tostring(key)]
    if n then return n end
    local id = tonumber(key)
    if id and GetSpellInfo then
        local name = GetSpellInfo(id)
        if name then return name end
    end
    return tostring(key)
end
MyLogTimeline.SpellName = SpellName

-- Lanes for a pull: { { id, name, casts = { { t, len } }, n } } (most casts first, at most MAX_LANES), and how many
-- spells did not fit.
function MyLogTimeline:Lanes(p)
    local by, order = {}, {}
    for _, e in ipairs(p and p.ct or {}) do
        local id = e[2]
        local l = by[id]
        if not l then
            l = { id = id, name = SpellName(p, id), casts = {}, n = 0 }
            by[id] = l
            order[#order + 1] = l
        end
        l.casts[#l.casts + 1] = { e[1], e[3] }
        l.n = l.n + 1
    end
    table.sort(order, function(a, b) return a.n > b.n end)
    local out = {}
    for i = 1, min(MAX_LANES, #order) do out[i] = order[i] end
    return out, max(0, #order - MAX_LANES)
end

-- The words for a boss event: e = { t, kind, id, extra }
function MyLogTimeline:BossEventText(p, e)
    local kind = e[2]
    if kind == "c" then return "casts " .. SpellName(p, e[3])
    elseif kind == "a" then
        return SpellName(p, e[3]) .. (e[4] and strformat(" for %.0f s", e[4]) or " (still up at the end)")
    elseif kind == "s" then return "summons (" .. SpellName(p, e[3]) .. ")"
    elseif kind == "d" then return (p.names and p.names["n" .. tostring(e[3])] or "A creature") .. " dies"
    elseif kind == "y" then return tostring(e[3]) .. ": " .. tostring(e[4] or "")
    end
    return "?"
end

---------------------------------------------------------------------------
-- The frame
---------------------------------------------------------------------------

function MyLogTimeline:Create(parent)
    local k = K()
    local C = k.C
    local f = CreateFrame("Frame", nil, parent)
    f.pool, f.used = {}, {}
    f.z0, f.z1 = 0, 1                     -- the zoom window as fractions of the fight
    local function take(kind, make)
        local list = f.pool[kind]
        if not list then list = {}; f.pool[kind] = list end
        f.used[kind] = (f.used[kind] or 0) + 1
        local o = list[f.used[kind]]
        if not o then o = make(); list[f.used[kind]] = o end
        o:Show()
        return o
    end
    local function reset()
        for _, list in pairs(f.pool) do for _, o in ipairs(list) do o:Hide() end end
        f.used = {}
    end

    -- the plot area (right of the labels)
    f.plot = CreateFrame("Frame", nil, f)
    f.plot:SetPoint("TOPLEFT", f, "TOPLEFT", LABEL_W, 0)
    f.plot:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, AXIS_H)
    f.plot:EnableMouse(true)
    f.plot:EnableMouseWheel(true)
    f.hint = UI():Text(f, "small", "DIM", { text = "Scroll to zoom · right-click to zoom out" })
    f.hint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 3)
    f.more = UI():Text(f, "small", "SUB")
    f.scrub = f.plot:CreateTexture(nil, "OVERLAY", nil, 7)
    f.scrub:SetColorTexture(1, 1, 1, 0.35)
    f.scrub:SetWidth(1)
    f.scrub:Hide()

    function f:Size()
        local w, h = self.plot:GetWidth() or 0, self.plot:GetHeight() or 0
        if w <= 0 or h <= 0 then w, h = self.fallback and (self.fallback[1] - LABEL_W - 4) or 600, self.fallback and (self.fallback[2] - AXIS_H) or 160 end
        return w, h
    end
    -- seconds -> x in the plot (nil when outside the zoom window)
    function f:X(t, clamp)
        local dur = self.dur or 1
        local a, b = self.z0 * dur, self.z1 * dur
        local w = self:Size()
        local x = (t - a) / max(0.001, b - a) * w
        if clamp then return max(0, min(w, x)) end
        if x < -1 or x > w + 1 then return nil end
        return x
    end
    function f:T(x)
        local dur = self.dur or 1
        local w = self:Size()
        return (self.z0 + (x / max(1, w)) * (self.z1 - self.z0)) * dur
    end

    local function laneY(i) return -(i - 1) * (LANE_H + LANE_GAP) end

    local function bar(x0, x1, y, h, col, a, layer)
        local t = take("bar" .. (layer or ""), function() return f.plot:CreateTexture(nil, layer or "ARTWORK") end)
        t:SetColorTexture(col[1], col[2], col[3], a or 1)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f.plot, "TOPLEFT", x0, y)
        t:SetSize(max(1, x1 - x0), h)
        return t
    end
    local function dot(x, y, size, col)
        local d = take("dot", function() return k.Dot(f.plot, 6, C.gold, 1, "OVERLAY") end)
        d:SetVertexColor(col[1], col[2], col[3], 1)
        d:SetSize(size, size)
        d:ClearAllPoints()
        d:SetPoint("CENTER", f.plot, "TOPLEFT", x, y)
        return d
    end

    function f:Draw()
        reset()
        local p = self.pull
        if not p then return end
        local w, h = self:Size()
        local lanes = self.lanes or {}
        local nl = #lanes + 1
        -- lane rows: a faint groove each; labels on the left
        for i = 1, nl do
            local y = laneY(i)
            bar(0, w, y, LANE_H, LANE_RGB, i % 2 == 1 and 0.035 or 0.02, "BACKGROUND")
            local lab = take("lab", function() return UI():Text(self, "small", "TEXT", { width = LABEL_W - 30 }) end)
            local icon = take("icon", function() return k.Icon(self, 14) end)
            icon:ClearAllPoints()
            icon:SetPoint("TOPLEFT", self, "TOPLEFT", 4, y - 1.5)
            lab:ClearAllPoints()
            lab:SetPoint("TOPLEFT", self, "TOPLEFT", 24, y - 3)
            if i == 1 then
                lab:SetText(p.boss or "Boss")
                lab:SetTextColor(C.violet[1], C.violet[2], C.violet[3])
                icon:Hide()
                local por = take("por", function() return k.Portrait(self, 14) end)
                por:ClearAllPoints()
                por:SetPoint("TOPLEFT", self, "TOPLEFT", 4, y - 1.5)
                por:SetBoss(p.boss)
            else
                local l = lanes[i - 1]
                local col = PALETTE[(i - 2) % #PALETTE + 1]
                lab:SetText(l.name .. S:Wrap("DIM", "  " .. l.n))
                lab:SetTextColor(col[1] * 0.4 + 0.6, col[2] * 0.4 + 0.6, col[3] * 0.4 + 0.6)
                icon:SetSpell(tostring(l.id))
            end
        end
        local totalH = nl * (LANE_H + LANE_GAP)
        -- idle gaps across every lane
        for _, g in ipairs(p.gaps or {}) do
            local x0, x1 = self:X(g.at, true), self:X(g.at + g.len, true)
            if x1 > x0 then
                bar(x0, x1, 0, totalH - LANE_GAP, C.down, 0.10, "BORDER")
                bar(x0, x1, -(totalH - LANE_GAP) - 1, 2, C.down, 0.9, "OVERLAY")
            end
        end
        -- the boss lane
        local by = laneY(1)
        for _, e in ipairs(p.bev or {}) do
            local kind = e[2]
            if kind == "a" then
                local x0 = self:X(e[1], true)
                local x1 = self:X(e[1] + (e[4] or (self.dur - e[1])), true)
                if x1 > x0 then
                    bar(x0, x1, by - 3, LANE_H - 6, C.violet, 0.35)
                    bar(x0, x0 + 2, by - 1, LANE_H - 2, C.violet, 0.95)
                end
            elseif kind == "c" or kind == "s" then
                local x = self:X(e[1])
                if x then bar(x, x + 2, by - 4, LANE_H - 8, C.violet, 0.9, "OVERLAY") end
            elseif kind == "y" then
                local x = self:X(e[1])
                if x then dot(x, by - LANE_H / 2, 7, C.gold) end
            elseif kind == "d" then
                local x = self:X(e[1])
                if x then dot(x, by - LANE_H / 2, 6, C.mute) end
            end
        end
        -- my lanes
        for i, l in ipairs(lanes) do
            local y = laneY(i + 1)
            local col = PALETTE[(i - 1) % #PALETTE + 1]
            for _, c in ipairs(l.casts) do
                local x0 = self:X(c[1])
                if c[2] and c[2] > 0 then
                    local xa, xb = self:X(c[1], true), self:X(c[1] + c[2], true)
                    if xb > xa then
                        bar(xa, xb, y - 4, LANE_H - 8, col, 0.35)
                        if x0 then bar(xb - 2, xb, y - 2, LANE_H - 4, col, 1, "OVERLAY") end   -- where it landed
                    end
                elseif x0 then
                    bar(x0, x0 + 2, y - 2, LANE_H - 4, col, 1, "OVERLAY")
                end
            end
        end
        -- the time axis
        local dur = self.dur or 1
        local a, b = self.z0 * dur, self.z1 * dur
        local step = k.NiceStep and k.NiceStep(b - a, 5) or 30
        if step < 1 then step = 1 end
        local t = math.ceil(a / step) * step
        while t <= b + 0.001 do
            local x = self:X(t)
            if x then
                local tk = bar(x, x + 1, 0, totalH - LANE_GAP, LANE_RGB, 0.05, "BACKGROUND")
                tk:SetDrawLayer("BACKGROUND", 1)
                local lab = take("axis", function() return UI():Text(self, "small", "DIM") end)
                lab:SetText(k.Clock(t))
                lab:ClearAllPoints()
                lab:SetPoint("TOP", self.plot, "TOPLEFT", x, -totalH - 2)
            end
            t = t + step
        end
        self.more:ClearAllPoints()
        self.more:SetPoint("TOPLEFT", self, "TOPLEFT", 4, -totalH - 2)
        self.more:SetText(self.hidden > 0 and strformat("+%d more spell%s", self.hidden, self.hidden == 1 and "" or "s") or "")
        self.hint:SetShown(self.z0 == 0 and self.z1 == 1)
    end

    function f:SetPull(p)
        self.pull = p
        self.dur = max(1, p and p.dur or 1)
        self.lanes, self.hidden = MyLogTimeline:Lanes(p)
        self.z0, self.z1 = 0, 1
        self:Draw()
    end

    -- hover: what happened around the second under the mouse (a live read-out that follows the mouse every frame,
    -- so it fills GameTooltip itself instead of UI:AttachTooltip's once-per-enter tooltip)
    local function hover(self)
        local p = f.pull
        if not p or not GetCursorPosition then return end
        local cx, cy = GetCursorPosition()
        local scale = self:GetEffectiveScale() or 1
        local x = cx / scale - (self:GetLeft() or 0)
        local yTop = (self:GetTop() or 0) - cy / scale
        local w = f:Size()
        if x < 0 or x > w then return end
        local t = f:T(x)
        f.scrub:ClearAllPoints()
        f.scrub:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
        f.scrub:SetHeight((#f.lanes + 1) * (LANE_H + LANE_GAP))
        f.scrub:Show()
        local lane = floor(yTop / (LANE_H + LANE_GAP)) + 1
        local secPerPx = (f.z1 - f.z0) * f.dur / max(1, w)
        local near = max(1.5, secPerPx * 8)
        local lines = { { k.Clock(t), C.mute } }
        for _, e in ipairs(p.bev or {}) do
            local hit = abs(e[1] - t) <= near or (e[2] == "a" and t >= e[1] and t <= e[1] + (e[4] or f.dur))
            if hit then lines[#lines + 1] = { strformat("%s  %s", k.Clock(e[1]), MyLogTimeline:BossEventText(p, e)), e[2] == "y" and C.gold or C.violet } end
            if #lines > 6 then break end
        end
        local mine = 0
        for _, e in ipairs(p.ct or {}) do
            if e[1] <= t + near and e[1] + (e[3] or 0) >= t - near then
                if mine < 4 then
                    lines[#lines + 1] = { strformat("%s  %s%s", k.Clock(e[1]), SpellName(p, e[2]), e[3] and strformat(" (%.1f s)", e[3]) or ""), C.fg }
                end
                mine = mine + 1
            end
        end
        for _, g in ipairs(p.gaps or {}) do
            if t >= g.at and t <= g.at + g.len then lines[#lines + 1] = { strformat("idle %.1f s", g.len), C.down } end
        end
        if mine == 0 and lane > 1 then lines[#lines + 1] = { "no casts here", C.dim } end
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        for i, ln in ipairs(lines) do GameTooltip:AddLine(ln[1], ln[2][1], ln[2][2], ln[2][3]) end
        GameTooltip:Show()
    end
    f.plot:SetScript("OnEnter", function(self) self.hovering = true end)
    f.plot:SetScript("OnLeave", function(self) self.hovering = false; f.scrub:Hide(); GameTooltip:Hide() end)
    f.plot:SetScript("OnUpdate", function(self) if self.hovering then hover(self) end end)
    f.plot:SetScript("OnMouseWheel", function(self, delta)
        if not f.pull then return end
        local w = f:Size()
        local cx = GetCursorPosition and GetCursorPosition() or 0
        local x = cx / (self:GetEffectiveScale() or 1) - (self:GetLeft() or 0)
        f:Zoom(delta > 0 and 0.7 or 1 / 0.7, max(0, min(1, x / max(1, w))))
    end)
    f.plot:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then f.z0, f.z1 = 0, 1; f:Draw() end
    end)
    -- zoom by factor around a point (0..1 of the current window); at least 10 seconds stay in view
    function f:Zoom(factor, at)
        local span = self.z1 - self.z0
        local minSpan = min(1, 10 / self.dur)
        local new = max(minSpan, min(1, span * factor))
        local centre = self.z0 + span * (at or 0.5)
        local z0 = centre - new * (at or 0.5)
        z0 = max(0, min(1 - new, z0))
        self.z0, self.z1 = z0, z0 + new
        self:Draw()
    end
    f:SetScript("OnSizeChanged", function(self) if self.pull then self:Draw() end end)
    return f
end

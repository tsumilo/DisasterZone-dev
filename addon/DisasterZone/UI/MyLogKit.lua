if DisasterZoneBoot and DisasterZoneBoot.Run("UI/MyLogKit.lua", ...) then return end -- DisasterZone: drawing kit of the My Log page.
-- The data drawings UI/MyLogUI.lua, UI/MyLogDetail.lua and UI/MyLogTimeline.lua share (the page itself is built from
-- the shared layouts and components: UI:CreateLayout, UI:CreatePageBanner, UI:CreateCard, UI:CreatePill ...):
--   colours (Kit.C: ns.Style tokens, plus the violet of the boss's mechanics), round dots, a boss's round portrait
--   with a gold ring, spell icons, a sparkline, a chart (lines over x/y points, a soft gradient fill under the first
--   series, bands, baseline ticks, dots with labels, and a hover scrubber that reports the x under the mouse), its
--   legend, a row of stat cards (UI:CreateCard) and the number formats.
-- Numbers are set in the text font (Friz), like My BiS, on purpose: the narrow digits (S.FONT_NUM, the "num" style)
-- read as a generic web dashboard in game. So the kit uses the text styles ("page", "emph", "small") for numbers too.
local addonName, ns = ...

local Kit = ns:NewModule("MyLogKit")

local UI, S = ns.UI, ns.Style
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local strformat = string.format

local DISC = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- Colours (r, g, b): the ns.Style tokens under the names the My Log code (and UI/MeterDetail.lua) reads.
Kit.C = {
    fg = S.C.TEXT, mute = S.C.SUB, dim = S.C.DIM, gold = S.C.GOLD, gold2 = S.C.GOLD_DEEP,
    up = S.C.OK, down = S.C.BAD, avoid = S.C.WARN, blue = S.C.YOU,
    violet = { 0.66, 0.55, 1 },            -- (a data colour: the boss's mechanics on the charts; no token)
    card = S.C.CARD, well = S.C.INSET,
}
local C = Kit.C

-- The pill kind (UI:CreatePill) of a change: better / worse / the same.
Kit.PILL = { up = "ok", down = "bad", mute = "mute", best = "rank", avoid = "warn" }

---------------------------------------------------------------------------
-- Small pieces
---------------------------------------------------------------------------

-- "+6.1%" style change text: change in % (nil -> nil), higherIsBetter. Returns text, pill kind (Kit.PILL).
function Kit.ChangeChip(change, higherIsBetter, suffix)
    if not change then return nil end
    if abs(change) < 0.05 then return "same" .. (suffix or ""), "mute" end
    local good = (change > 0) == (higherIsBetter ~= false)
    return strformat("%s%.1f%%%s", change > 0 and "+" or "-", abs(change), suffix or ""), good and Kit.PILL.up or Kit.PILL.down
end

-- A pill (UI:CreatePill) that hides itself without text: pill:SetPill(kind, text) with text nil hides it.
function Kit.Pill(parent)
    local p = UI:CreatePill(parent)
    local set = p.SetPill
    function p:SetPill(kind, text)
        if text == nil or text == "" then self:Hide() return end
        set(self, kind, text)
        self:Show()
    end
    p:Hide()
    return p
end

---------------------------------------------------------------------------
-- Portrait: a boss's round portrait (creature display id) with a gold ring; a tinted disc and the initial when
-- the boss has no display id. p:SetBoss(name); p:SetPortraitSize(px)
---------------------------------------------------------------------------

function Kit.Portrait(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f.ring = UI:CreateDot(f, size + 6, C.gold, { alpha = 0.35, layer = "BACKGROUND" })
    f.ring:SetPoint("CENTER")
    f.gap = UI:CreateDot(f, size + 3, S.C.INSET, { alpha = 1, layer = "BORDER" })
    f.gap:SetPoint("CENTER")
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetPoint("CENTER")
    f.initial = UI:Text(f, "page", "TEXT", { justify = "CENTER" })
    f.initial:SetPoint("CENTER")
    function f:SetPortraitSize(ps)
        self:SetSize(ps, ps)
        self.tex:SetSize(ps, ps)
        self.ring:SetSize(ps + 6, ps + 6)
        self.gap:SetSize(ps + 3, ps + 3)
    end
    f:SetPortraitSize(size)
    function f:SetBoss(name, desaturate)
        local disp = ns.MyLog and ns.MyLog.BossDisplayId and ns.MyLog:BossDisplayId(name)
        self.initial:SetText("")
        if disp and SetPortraitTextureFromCreatureDisplayID then
            self.tex:SetTexture(nil)
            self.tex:SetVertexColor(1, 1, 1, 1)
            SetPortraitTextureFromCreatureDisplayID(self.tex, disp)
        else
            self.tex:SetTexture(DISC)
            self.tex:SetVertexColor(S:Color("EDGE_STRONG"))
            self.initial:SetText((name or "?"):sub(1, 1))
        end
        if self.tex.SetDesaturated then self.tex:SetDesaturated(desaturate and true or false) end
    end
    return f
end

-- A spell icon with a thin dark edge: icon:SetSpell(id | key) (pet keys "p123" use the spell; melee -> a sword).
function Kit.Icon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.edge = f:CreateTexture(nil, "BACKGROUND")
    f.edge:SetAllPoints()
    f.edge:SetColorTexture(0, 0, 0, 0.8)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetPoint("TOPLEFT", 1, -1)
    f.tex:SetPoint("BOTTOMRIGHT", -1, 1)
    f.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    function f:SetSpell(key)
        local id = tonumber((tostring(key or ""):gsub("^[pm]", "")))
        local tex
        if key == "0" or key == "p0" or (type(key) == "string" and key:sub(1, 1) == "m") then
            tex = 132147                                   -- an auto attack icon
        elseif type(key) == "string" and key:sub(1, 1) == "e" then
            tex = 135805                                   -- environment
        elseif id and GetSpellTexture then
            tex = GetSpellTexture(id)
        end
        self.tex:SetTexture(tex or 134400)                 -- the question mark
    end
    function f:SetIcon(tex) self.tex:SetTexture(tex or 134400) end
    return f
end

---------------------------------------------------------------------------
-- Chart: points in data units; sc:SetData(opts)
--   opts.series = { { points = { { x, y }, ... }, color, width, alpha, fill (bool: gradient under it) } }
--   opts.x0, opts.x1, opts.y1 (top; default the highest y + 8%), opts.bands = { { x0, x1, color, label } },
--   opts.ticks = { { x, color } } (on the baseline), opts.dots = { { x, y, color, size, label } }
--   opts.hover = function(x) -> lines (shown in the chart's own tooltip box) | nil
---------------------------------------------------------------------------

local FILL_STEP = 3      -- px between fill columns

local function YAt(points, x)
    local n = #points
    if n == 0 then return nil end
    if x <= points[1][1] then return points[1][2] end
    for i = 2, n do
        local a, b = points[i - 1], points[i]
        if x <= b[1] then
            local f = (b[1] - a[1]) > 0 and (x - a[1]) / (b[1] - a[1]) or 0
            return a[2] + (b[2] - a[2]) * f
        end
    end
    return points[n][2]
end
Kit.YAt = YAt

-- A "nice" step for about n grid lines up to hi: 1, 2, 2.5 or 5 times a power of ten.
local function NiceStep(hi, n)
    local raw = hi / n
    local mag = 10 ^ floor(math.log10(max(raw, 1e-9)))
    for _, m in ipairs({ 1, 2, 2.5, 5, 10 }) do
        if m * mag >= raw then return m * mag end
    end
    return 10 * mag
end
Kit.NiceStep = NiceStep

-- Catmull-Rom points between the given ones (steps per segment), clamped to >= 0: a calm curve through
-- every value instead of a zigzag.
local function Smooth(pts, steps)
    local n = #pts
    if n < 3 then return pts end
    local out = {}
    for i = 1, n - 1 do
        local p0, p1, p2, p3 = pts[max(1, i - 1)], pts[i], pts[i + 1], pts[min(n, i + 2)]
        for s = 0, steps - 1 do
            local t = s / steps
            local t2, t3 = t * t, t * t * t
            local function cr(a, b, c2, d) return 0.5 * ((2 * b) + (-a + c2) * t + (2 * a - 5 * b + 4 * c2 - d) * t2 + (-a + 3 * b - 3 * c2 + d) * t3) end
            out[#out + 1] = { p1[1] + (p2[1] - p1[1]) * t, max(0, cr(p0[2], p1[2], p2[2], p3[2])) }
        end
    end
    out[#out + 1] = { pts[n][1], pts[n][2] }
    return out
end
Kit.Smooth = Smooth

-- (a colour with its alpha)
local function A(c, a) return { c[1], c[2], c[3], a } end

function Kit.Chart(parent)
    local c = CreateFrame("Frame", nil, parent)
    c.pool = { line = {}, fill = {}, band = {}, tick = {}, dot = {}, lab = {} }
    c.used = {}
    c.inset = { l = 0, r = 0, t = 8, b = 2 }
    local function take(kind, make)
        local list = c.pool[kind]
        if not list then list = {}; c.pool[kind] = list end
        c.used[kind] = (c.used[kind] or 0) + 1
        local o = list[c.used[kind]]
        if not o then o = make(); list[c.used[kind]] = o end
        o:Show()
        return o
    end
    function c:Reset()
        for _, list in pairs(self.pool) do for _, o in ipairs(list) do o:Hide() end end
        self.used = {}
    end
    -- the chart's size; before the first layout (width 0) the size it was given as a fallback (c.fallback)
    function c:Size()
        local w, h = self:GetWidth() or 0, self:GetHeight() or 0
        if (w <= 0 or h <= 0) and self.fallback then w, h = self.fallback[1], self.fallback[2] end
        return w, h
    end
    function c:Map(x, y)
        local o = self.opts
        local cw, ch = self:Size()
        local w = cw - self.inset.l - self.inset.r
        local h = ch - self.inset.t - self.inset.b
        local fx = (o.x1 - o.x0) > 0 and (x - o.x0) / (o.x1 - o.x0) or 0
        return self.inset.l + fx * w, self.inset.b + (y / o.y1) * h
    end
    function c:SetData(opts)
        self.opts = opts
        self:Draw()
    end

    function c:Draw()
        local o = self.opts
        if not o then return end
        self:Reset()
        local w, h = self:Size()
        if w <= 0 or h <= 0 then return end
        if not o.y1 then
            local hi = 1
            for _, s in ipairs(o.series or {}) do for _, p in ipairs(s.points) do if p[2] > hi then hi = p[2] end end end
            o.y1 = hi * 1.08
        end
        local base = self.inset.b
        local top = h - self.inset.t
        local hr, hg, hb = S:Color("HAIRLINE")
        -- grid: round values, labels left of the chart
        if o.grid then
            local step = NiceStep(o.y1 / 1.05, 4)
            local v = step
            while v < o.y1 do
                local _, y = self:Map(0, v)
                local g = take("grid", function() return self:CreateTexture(nil, "BACKGROUND", nil, -1) end)
                g:SetColorTexture(hr, hg, hb, 0.045)
                g:ClearAllPoints()
                g:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, y)
                g:SetSize(w, 1)
                local l = take("ylab", function() return UI:Text(self:GetParent(), "small", "DIM", { justify = "RIGHT" }) end)
                l:SetText((o.yFormat or Kit.Num)(v))
                l:ClearAllPoints()
                l:SetPoint("RIGHT", self, "BOTTOMLEFT", -8, y)
                v = v + step
            end
            local b = take("grid", function() return self:CreateTexture(nil, "BACKGROUND", nil, -1) end)
            b:SetColorTexture(hr, hg, hb, 0.10)
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, base)
            b:SetSize(w, 1)
        end
        -- bands: a faint wash with a brighter cap line and a small label (labels closer than 70 px are skipped)
        local lastLabelX = -999
        for _, band in ipairs(o.bands or {}) do
            local col = band[3] or C.violet
            local x0 = self:Map(band[1], 0)
            local x1 = self:Map(band[2], 0)
            local t = take("band", function() return self:CreateTexture(nil, "BACKGROUND", nil, 0) end)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x0, base)
            t:SetSize(max(2, x1 - x0), top - base)
            UI:Gradient(t, "VERTICAL", A(col, 0.02), A(col, band.alpha or 0.10))
            local cap = take("bandcap", function() return self:CreateTexture(nil, "BORDER") end)
            cap:SetColorTexture(col[1], col[2], col[3], 0.75)
            cap:ClearAllPoints()
            cap:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x0, top - 2)
            cap:SetSize(max(2, x1 - x0), 2)
            if band[4] and x0 - lastLabelX > 70 then
                local l = take("lab", function() return UI:Text(self, "small") end)
                l:SetText(band[4])
                l:SetTextColor(col[1], col[2], col[3], 0.95)
                l:ClearAllPoints()
                l:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x0, top + 2)
                lastLabelX = x0
            end
        end
        -- marks: a thin full-height line (a yell, a phase) with a small diamond on top
        for _, m in ipairs(o.marks or {}) do
            local col = m[2] or C.gold
            local x = self:Map(m[1], 0)
            local ln = take("mark", function() return self:CreateTexture(nil, "BORDER", nil, 1) end)
            ln:SetColorTexture(col[1], col[2], col[3], 0.35)
            ln:ClearAllPoints()
            ln:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, base)
            ln:SetSize(1, top - base)
            local d = take("markdot", function()
                local t = self:CreateTexture(nil, "OVERLAY")
                t:SetTexture(WHITE)
                if t.SetRotation then t:SetRotation(math.pi / 4) end
                return t
            end)
            d:SetVertexColor(col[1], col[2], col[3], 1)
            d:SetSize(6, 6)
            d:ClearAllPoints()
            d:SetPoint("CENTER", self, "BOTTOMLEFT", x + 0.5, top)
        end
        for si, s in ipairs(o.series or {}) do
            local pts = s.smooth and Smooth(s.points, 4) or s.points
            local col = s.color or C.gold
            if s.fill and #pts > 1 then
                local x0 = self:Map(pts[1][1], 0)
                local x1 = self:Map(pts[#pts][1], 0)
                -- columns edge to edge on whole units (no overlap: overlapping see-through columns show as
                -- stripes); each column's gradient runs from 0 at the baseline to A * its height / the plot height,
                -- so the alpha at any height is the same in every column and the wash reads as one smooth surface
                local x = floor(x0)
                local span = (w - self.inset.l - self.inset.r)
                local fa = s.fillAlpha or 0.22
                while x < x1 do
                    local cw = min(FILL_STEP, floor(x1) - x)
                    if cw < 1 then break end
                    local dataX = o.x0 + (x + cw / 2 - self.inset.l) / span * (o.x1 - o.x0)
                    local y = YAt(pts, dataX) or 0
                    local _, py = self:Map(dataX, y)
                    local hgt = max(1, py - base)
                    local t = take("fill", function() return self:CreateTexture(nil, "BACKGROUND", nil, 1) end)
                    t:ClearAllPoints()
                    t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, base)
                    t:SetSize(cw, hgt)
                    UI:Gradient(t, "VERTICAL", A(col, 0), A(col, fa * hgt / max(1, top - base)))
                    x = x + cw
                end
            end
            if (s.width or 2) > 0.05 then
                for pass = s.glow and 1 or 2, 2 do
                    for i = 2, #pts do
                        local l = take("line", function() return self:CreateLine(nil, "ARTWORK") end)
                        l:SetDrawLayer("ARTWORK", (si == 1 and 3 or 1) + (pass == 1 and -1 or 0))
                        if pass == 1 then
                            l:SetThickness((s.width or 2) * 3.5)
                            l:SetColorTexture(col[1], col[2], col[3], 0.10)
                        else
                            l:SetThickness(s.width or 2)
                            l:SetColorTexture(col[1], col[2], col[3], s.alpha or 1)
                        end
                        local ax, ay = self:Map(pts[i - 1][1], pts[i - 1][2])
                        local bx, by = self:Map(pts[i][1], pts[i][2])
                        l:SetStartPoint("BOTTOMLEFT", self, ax, ay)
                        l:SetEndPoint("BOTTOMLEFT", self, bx, by)
                    end
                end
            end
            if s.endDot and #pts > 0 then
                local x, y = self:Map(pts[#pts][1], pts[#pts][2])
                local halo = take("dot", function() return UI:CreateDot(self, 8, C.gold, { alpha = 1 }) end)
                halo:SetVertexColor(col[1], col[2], col[3], 0.22)
                halo:SetSize(16, 16)
                halo:ClearAllPoints()
                halo:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
                local d = take("dot", function() return UI:CreateDot(self, 8, C.gold, { alpha = 1 }) end)
                d:SetVertexColor(col[1], col[2], col[3], 1)
                d:SetSize(7, 7)
                d:ClearAllPoints()
                d:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
            end
        end
        for _, tk in ipairs(o.ticks or {}) do
            local t = take("tick", function() return self:CreateTexture(nil, "OVERLAY") end)
            local col = tk[2] or C.down
            t:SetColorTexture(col[1], col[2], col[3], 0.95)
            local x = self:Map(tk[1], 0)
            local x2 = tk[3] and self:Map(tk[3], 0) or (x + 3)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, base - 1)
            t:SetSize(max(3, x2 - x), tk.h or 3)
        end
        local ir, ig, ib = S:Color("INSET")
        for _, d in ipairs(o.dots or {}) do
            local col = d[3] or C.gold
            local x, y = self:Map(d[1], d[2])
            local size = d[4] or 8
            local ring = take("dot", function() return UI:CreateDot(self, 8, C.gold, { alpha = 1 }) end)
            ring:SetVertexColor(ir, ig, ib, 1)
            ring:SetSize(size + 4, size + 4)
            ring:ClearAllPoints()
            ring:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
            local t = take("dot", function() return UI:CreateDot(self, 8, C.gold, { alpha = 1 }) end)
            t:SetVertexColor(col[1], col[2], col[3], 1)
            t:SetSize(size, size)
            t:ClearAllPoints()
            t:SetPoint("CENTER", self, "BOTTOMLEFT", x, y)
            if d[5] then
                local l = take("lab", function() return UI:Text(self, "small") end)
                l:SetText(d[5])
                l:SetTextColor(col[1], col[2], col[3])
                l:ClearAllPoints()
                l:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, y + size / 2 + 3)
            end
        end
    end
    c:SetScript("OnSizeChanged", function(self) self:Draw() end)

    -- hover: a scrub line, a dot per series and a small box (an inset card) with opts.hover(x)'s lines
    c.scrub = c:CreateTexture(nil, "OVERLAY")
    c.scrub:SetColorTexture(1, 1, 1, 0.3)
    c.scrub:SetWidth(1)
    c.scrub:Hide()
    c.hoverDots = {}
    c.box = UI:CreateCard(c, { tone = "inset" })
    c.box:SetFrameLevel(c:GetFrameLevel() + 5)
    c.box.lines = {}
    c.box:Hide()
    c:EnableMouse(true)
    local function hoverAt(self)
        local o = self.opts
        if not (o and o.hover and GetCursorPosition) then return end
        local cx = GetCursorPosition()
        local scale = self:GetEffectiveScale() or 1
        local left = self:GetLeft() or 0
        local px = cx / scale - left
        local w = (self:GetWidth() or 1) - self.inset.l - self.inset.r
        local fx = max(0, min(1, (px - self.inset.l) / max(1, w)))
        local x = o.x0 + fx * (o.x1 - o.x0)
        local lines = o.hover(x)
        if not lines then self.scrub:Hide(); self.box:Hide(); return end
        local sx = self:Map(x, 0)
        self.scrub:ClearAllPoints()
        self.scrub:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", sx, self.inset.b)
        self.scrub:SetHeight((self:GetHeight() or 0) - self.inset.b - 2)
        self.scrub:Show()
        for i, s in ipairs(o.series or {}) do
            local d = self.hoverDots[i]
            if not d then d = UI:CreateDot(self, 8, C.gold, { alpha = 1 }); self.hoverDots[i] = d end
            local y = YAt(s.points, x)
            if y then
                local col = s.color or C.gold
                d:SetVertexColor(col[1], col[2], col[3], 1)
                local _, py = self:Map(x, y)
                d:ClearAllPoints()
                d:SetPoint("CENTER", self, "BOTTOMLEFT", sx, py)
                d:Show()
            else
                d:Hide()
            end
        end
        local box = self.box
        local wmax, hy = 0, 6
        for i, line in ipairs(lines) do
            local fs = box.lines[i]
            if not fs then fs = UI:Text(box, "small", "TEXT"); box.lines[i] = fs end
            fs:SetText(type(line) == "table" and line[1] or line)
            local col = type(line) == "table" and line[2] or C.fg
            fs:SetTextColor(col[1], col[2], col[3])
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -hy)
            fs:Show()
            wmax = max(wmax, fs:GetStringWidth() or 0)
            hy = hy + 14
        end
        UI:HideFrom(box.lines, #lines + 1)
        box:SetSize(wmax + 16, hy + 4)
        box:ClearAllPoints()
        local right = sx + 12 + wmax + 16 < (self:GetWidth() or 0)
        if right then box:SetPoint("TOPLEFT", self, "TOPLEFT", sx + 10, -16)
        else box:SetPoint("TOPRIGHT", self, "TOPLEFT", sx - 10, -16) end
        box:Show()
    end
    c:SetScript("OnEnter", function(self) self.hovering = true end)
    c:SetScript("OnLeave", function(self)
        self.hovering = false
        self.scrub:Hide()
        self.box:Hide()
        for _, d in ipairs(self.hoverDots) do d:Hide() end
    end)
    c:SetScript("OnUpdate", function(self) if self.hovering then hoverAt(self) end end)
    c.HoverAt = hoverAt
    return c
end

-- A sparkline of up to 8 values (the last one gold): sp:SetValues(values)
function Kit.Spark(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f.lines = {}
    f.dot = UI:CreateDot(f, 5, C.gold, { alpha = 1 })
    function f:SetValues(vals)
        for _, l in ipairs(self.lines) do l:Hide() end
        self.dot:Hide()
        local n = vals and #vals or 0
        if n == 0 then return end
        local lo, hi = math.huge, -math.huge
        for i = 1, n do lo = min(lo, vals[i] or 0); hi = max(hi, vals[i] or 0) end
        if hi - lo < 1e-6 then lo, hi = lo - 1, hi + 1 end
        local sw, sh = self:GetWidth() or w, self:GetHeight() or h      -- (it may have been resized)
        if sw <= 0 then sw = w end
        if sh <= 0 then sh = h end
        local step = (sw - 6) / 7
        local x0 = sw - 3 - (n - 1) * step
        local function pt(i) return x0 + (i - 1) * step, 3 + ((vals[i] or 0) - lo) / (hi - lo) * (sh - 6) end
        for i = 2, n do
            local l = self.lines[i - 1]
            if not l then
                l = self:CreateLine(nil, "ARTWORK")
                l:SetThickness(1.5)
                l:SetColorTexture(C.blue[1], C.blue[2], C.blue[3], 0.95)
                self.lines[i - 1] = l
            end
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

---------------------------------------------------------------------------
-- Numbers
---------------------------------------------------------------------------

function Kit.Num(n)
    if not n then return "-" end
    if n >= 1e6 then return strformat("%.2fm", n / 1e6) end
    if n >= 1e5 then return strformat("%.0fk", n / 1000) end
    if n >= 1e4 then return strformat("%.1fk", n / 1000) end
    local s = tostring(floor(n + 0.5))
    if #s > 3 then s = s:sub(1, #s - 3) .. "," .. s:sub(-3) end
    return s
end

function Kit.Clock(sec)
    sec = floor((sec or 0) + 0.5)
    return strformat("%d:%02d", floor(sec / 60), sec % 60)
end

function Kit.Day(at)
    if not at or at == 0 then return "?" end
    return date("%a %d %b", at)
end

function Kit.ShortDay(at)
    if not at or at == 0 then return "?" end
    return date("%d %b", at)
end

function Kit.Change(now, before)
    if not now or not before or before == 0 then return nil end
    return (now - before) / before * 100
end

---------------------------------------------------------------------------
-- Legend: lg:Set({ { color, text, kind } }) kind = "line" (default) | "dash" | "box" | "tick"; laid out right to left
-- from its right edge.
---------------------------------------------------------------------------

function Kit.Legend(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(10, 14)
    f.items = {}
    function f:Set(items)
        for _, it in ipairs(self.items) do it:Hide() end
        local x = 0
        for i = #items, 1, -1 do
            local e = items[i]
            local it = self.items[i]
            if not it then
                it = CreateFrame("Frame", nil, self)
                it:SetHeight(14)
                it.sw = it:CreateTexture(nil, "ARTWORK")
                it.sw2 = it:CreateTexture(nil, "ARTWORK")
                it.fs = UI:Text(it, "small", "SUB")
                it.fs:SetPoint("LEFT", it, "LEFT", 20, 0)
                self.items[i] = it
            end
            local c = e[1]
            local kind = e[3] or "line"
            it.sw:ClearAllPoints()
            it.sw2:Hide()
            if kind == "box" then
                it.sw:SetColorTexture(c[1], c[2], c[3], 0.45)
                it.sw:SetSize(10, 10)
                it.sw:SetPoint("LEFT", it, "LEFT", 3, 0)
            elseif kind == "tick" then
                it.sw:SetColorTexture(c[1], c[2], c[3], 1)
                it.sw:SetSize(10, 3)
                it.sw:SetPoint("LEFT", it, "LEFT", 3, -4)
            elseif kind == "dash" then
                it.sw:SetColorTexture(c[1], c[2], c[3], 1)
                it.sw:SetSize(6, 2)
                it.sw:SetPoint("LEFT", it, "LEFT", 1, 0)
                it.sw2:ClearAllPoints()
                it.sw2:SetColorTexture(c[1], c[2], c[3], 1)
                it.sw2:SetSize(6, 2)
                it.sw2:SetPoint("LEFT", it, "LEFT", 10, 0)
                it.sw2:Show()
            else
                it.sw:SetColorTexture(c[1], c[2], c[3], 1)
                it.sw:SetSize(15, 2)
                it.sw:SetPoint("LEFT", it, "LEFT", 1, 0)
            end
            it.fs:SetText(e[2])
            local w = 20 + (it.fs:GetStringWidth() or 40)
            it:SetWidth(w)
            it:ClearAllPoints()
            it:SetPoint("RIGHT", self, "RIGHT", -x, 0)
            it:Show()
            x = x + w + 16
        end
        self:SetWidth(max(10, x))
    end
    return f
end

---------------------------------------------------------------------------
-- Stat cards: n cards (UI:CreateCard) in a row, S.GAP apart, each an icon, a value with its change beside it and a
-- grey caption under it:
-- st:SetCell(i, label, value, note, noteKind, icon) noteKind = "up" | "down" | "mute"; icon = texture or spell key.
-- st.cells[i]: .icon, .val, .note (= .delta), .lab
---------------------------------------------------------------------------

function Kit.StatStrip(parent, n, h)
    local f = CreateFrame("Frame", nil, parent)
    h = h or S.ROW.art
    f:SetHeight(h)
    f.cells = {}
    local iconS = h - 22
    for i = 1, n do
        local cell = UI:CreateCard(f, { tone = "card" })
        cell.icon = Kit.Icon(cell, iconS)
        cell.icon:SetPoint("LEFT", cell, "LEFT", S.IN + 1, 0)
        cell.val = UI:Text(cell, "page", "TEXT")
        cell.val:SetPoint("BOTTOMLEFT", cell, "LEFT", S.IN + iconS + 10, -1)
        cell.note = UI:Text(cell, "small", "SUB")
        cell.note:SetPoint("BOTTOMLEFT", cell.val, "BOTTOMRIGHT", 6, 1)
        cell.delta = cell.note
        cell.lab = UI:Text(cell, "small", "SUB")
        cell.lab:SetPoint("TOPLEFT", cell, "LEFT", S.IN + iconS + 10, -3)
        f.cells[i] = cell
    end
    local function place()
        local w = f:GetWidth() or 0
        if w <= 0 then w = S.INNER_W end          -- (the page's inner width, before layout)
        local cw = (w - (n - 1) * S.GAP) / n
        for i, cell in ipairs(f.cells) do
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", f, "TOPLEFT", (i - 1) * (cw + S.GAP), 0)
            cell:SetSize(cw, h)
            cell.lab:SetWidth(max(10, cw - iconS - S.IN - 16))
        end
    end
    place()
    f:HookScript("OnSizeChanged", place)
    function f:SetCell(i, label, value, note, kind, icon)
        local cell = self.cells[i]
        if label == nil then cell:Hide() return end
        cell:Show()
        cell.lab:SetText(label)
        cell.val:SetText(value or "")
        cell.note:SetText(note or "")
        cell.note:SetTextColor(S:Color(kind == "up" and "OK" or (kind == "down" and "BAD" or "DIM")))
        if type(icon) == "string" and icon:find("\\", 1, true) then cell.icon:SetIcon(icon) else cell.icon:SetSpell(icon) end
    end
    return f
end

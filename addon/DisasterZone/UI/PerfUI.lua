if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PerfUI.lua", ...) then return end -- DisasterZone UI/PerfUI.lua
-- The Performance page (the developer's, and anyone's who turns it on in Settings > About: Core/Perf.lua; an icon at
-- the right of the strip, /dz perf). Mockup B
-- "Tabs" (dev/art/casc/perf_mockup, picked 2026-10-11): page tabs Overview / Garbage / Memory / Network / CPU with
-- Clean up and Measure 30 s at their right; under them an art banner that every tab keeps (a ring of in use vs
-- garbage, the headline number, the session line, chips for CPU, fps, garbage a minute and the 3D rooms); then the
-- tab's cards:
--   Overview  the last hour (memory or CPU, the game's cleanups marked), next to the other addons, the three biggest
--             garbage makers of the last Measure;
--   Garbage   every handler of the last Measure (or per file) and, at the right, the one picked: who sent it, what I
--             send back, a sync loop when a message type goes both ways this often;
--   Memory    pages built (widgets, build time), saved data by section, the 3D rooms addon;
--   Network   addon messages in and out per prefix (the last minute), ChatThrottleLib, who sends the most;
--   CPU       the last hour, now / this session / boss fights / slowest frame, slow frames, the costliest handlers.
-- The Events look: art under a shade, boxes with a gold title and a hairline, pills and chips, standings rows with
-- mine in blue, icons with a dark edge. Sizes are fixed (the window's page is 790 x 548).
local addonName, ns = ...

local PerfUI = ns:NewModule("PerfUI")

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local cos, sin, pi = math.cos, math.sin, math.pi
local tostring, tonumber, ipairs, pairs, type = tostring, tonumber, ipairs, pairs, type
local tsort = table.sort

local PAD, GAP = 10, 8
local PAGE_W = 790
local W = PAGE_W - 2 * PAD
local TAB_Y, BAN_Y, BAN_H = -6, -36, 96
local BODY_Y = BAN_Y - BAN_H - GAP          -- -140
local BODY_H = 548 - 140 - PAD              -- 398
local LEFT_W, RIGHT_W = 486, W - 486 - GAP  -- 486 / 276
local MEASURE_S = 30
local NUM_FONT = "Fonts\\ARIALN.TTF"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local RING = "Interface\\AddOns\\DisasterZone\\Media\\Events\\ring"
local ART = "Interface\\Glues\\LoadingScreens\\LoadScreenTempestKeep"
local ROOMS_ART = "Interface\\Glues\\LoadingScreens\\LoadScreenKarazhan"
local function ICON(n) return "Interface\\Icons\\" .. n end

local C = {
    gold = { 1, 0.82, 0 }, white = { 1, 1, 1 }, text = { 0.9, 0.9, 0.92 }, grey = { 0.62, 0.62, 0.64 },
    dim = { 0.5, 0.5, 0.54 }, cap = { 0.79, 0.65, 0.27 }, blue = { 0.4, 0.72, 1 }, green = { 0.31, 0.83, 0.42 },
    red = { 0.88, 0.38, 0.31 }, mem = { 0.89, 0.7, 0.24 }, cpu = { 0.35, 0.65, 1 }, garbage = { 0.42, 0.42, 0.45 },
}
local BOX = { 0.067, 0.067, 0.078, 0.92 }
local PEDGE = { 0.34, 0.34, 0.38, 0.45 }

-- The kinds of handler a Measure finds: icon, colour, what the row's second line calls it.
local KIND = {
    timer    = { ICON("INV_Misc_PocketWatch_01"), { 0.5, 0.88, 0.56 }, "timer" },
    comm     = { ICON("INV_Letter_15"), { 1, 0.6, 0.4 }, "addon message" },
    send     = { ICON("INV_Letter_02"), { 1, 0.75, 0.54 }, "I send" },
    OnUpdate = { ICON("Spell_Nature_TimeStop"), { 1, 0.84, 0.42 }, "every frame" },
    OnEvent  = { ICON("INV_Misc_Note_01"), { 0.55, 0.77, 1 }, "event (own frame)" },
    event    = { ICON("INV_Misc_Note_01"), { 0.55, 0.77, 1 }, "event" },
    message  = { ICON("INV_Misc_Note_06"), { 0.75, 0.62, 1 }, "addon's own message" },
    library  = { ICON("INV_Misc_Book_11"), { 0.94, 0.54, 0.58 }, "shared library" },
}
-- What a message type carries (the second line of its row).
local MSG = { BLL = "raid blacklist", RPD = "raid plan data", RLD = "raid log", HELLO = "hello", PLD = "polls",
              BLQ = "blacklist query" }

local panel
local state = { tab = "overview", chart = "memory", byFile = false, picked = nil }

local function UI() return ns.UI end
local function EUI() return ns.EventUI end
local function Perf() return ns.Perf end

---------------------------------------------------------------------------
-- Small pieces (the Events page's look)
---------------------------------------------------------------------------

local function Sized(fs, size, path)
    local p, _, flags = fs:GetFont()
    fs:SetFont(path or p or "Fonts\\FRIZQT__.TTF", size, flags or "")
    return fs
end

local function Color(fs, c) fs:SetTextColor(c[1], c[2], c[3], c[4] or 1) end

-- A one-line text (no wrap); num: the narrow number font.
local function Text(parent, size, color, num, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    Sized(fs, size or 12, num and NUM_FONT or nil)
    Color(fs, color or C.text)
    return fs
end

-- A right-aligned number cell: its right edge at x (from the parent's left), w wide.
local function Cell(parent, x, y, w, size, color)
    local fs = Text(parent, size or 12, color or C.text, true, "RIGHT")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x - w, y)
    fs:SetWidth(w)
    return fs
end

local function Fill(f, c, layer, sub)
    local t = f:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function Rect(parent, c, layer, sub)
    local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sub)
    t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
    return t
end

local function HLine(parent, y, inset)
    local t = Rect(parent, { 1, 1, 1, 0.07 })
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", inset or 12, y)
    t:SetPoint("TOPRIGHT", -(inset or 12), y)
    return t
end

local function Fmt(kb)
    kb = tonumber(kb) or 0
    if kb >= 1024 then return ("%.1f MB"):format(kb / 1024) end
    return ("%d KB"):format(floor(kb + 0.5))
end

local function Ago(t)
    if not t then return "" end
    local s = max(0, (GetTime and GetTime() or 0) - t)
    if s < 60 then return "just now" end
    if s < 3600 then return ("%d min ago"):format(floor(s / 60)) end
    return ("%d h %d min ago"):format(floor(s / 3600), floor(s % 3600 / 60))
end

local function Span(s)
    s = max(0, floor(s or 0))
    if s < 3600 then return ("%d min"):format(floor(s / 60)) end
    return ("%d h %d min"):format(floor(s / 3600), floor(s % 3600 / 60))
end

-- A box: dark fill, soft edge; title (gold), a grey note after it, a hairline under the title row.
local function Box(parent, x, y, w, h, title)
    local b = CreateFrame("Frame", nil, parent)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    b:SetSize(w, h)
    Fill(b, BOX)
    EUI():Edge(b, PEDGE[1], PEDGE[2], PEDGE[3], PEDGE[4])
    if title then
        b.ht = Text(b, 13, C.gold)
        b.ht:SetPoint("TOPLEFT", 10, -8)
        b.ht:SetText(title)
        b.note = Text(b, 10, C.dim)
        b.note:SetPoint("LEFT", b.ht, "RIGHT", 12, -1)
        b.line = Rect(b, { 1, 1, 1, 0.07 })
        b.line:SetHeight(1)
        b.line:SetPoint("TOPLEFT", 1, -28)
        b.line:SetPoint("TOPRIGHT", -1, -28)
    end
    return b
end

-- A link at the right of a box's title ("Garbage >"): text and a chevron.
local function Link(b, text, onClick)
    local l = CreateFrame("Button", nil, b)
    l.fs = Text(l, 11, C.grey)
    l.fs:SetPoint("LEFT", 0, 0)
    l.chev = l:CreateTexture(nil, "ARTWORK")
    l.chev:SetSize(10, 10)
    UI():SetChevron(l.chev, true)
    l.chev:SetVertexColor(0.62, 0.62, 0.62)
    function l:SetLabel(t)
        self.fs:SetText(t or "")
        self.chev:ClearAllPoints()
        self.chev:SetPoint("LEFT", self.fs, "RIGHT", 3, 0)
        self:SetSize(ceil(EUI():TextWidth(self.fs) + 15), 16)
    end
    l:SetScript("OnEnter", function(self) Color(self.fs, C.white) self.chev:SetVertexColor(1, 1, 1) end)
    l:SetScript("OnLeave", function(self) Color(self.fs, C.grey) self.chev:SetVertexColor(0.62, 0.62, 0.62) end)
    l:SetScript("OnClick", onClick)
    l:SetLabel(text)
    l:SetPoint("TOPRIGHT", b, "TOPRIGHT", -10, -7)
    return l
end

-- An icon with a 1px dark edge (an event's look).
local function Icon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local edge = Fill(f, { 0, 0, 0, 1 }, "BACKGROUND")
    edge:ClearAllPoints()
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return f
end

-- A round icon in a thin gold ring (an addon's, a player's class). f:SetIcon(path [, atlas]) / f:SetClassOf(key).
local function RoundIcon(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size + 4, size + 4)
    f.tex = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.tex:SetPoint("CENTER")
    f.tex:SetSize(size, size)
    if f.CreateMaskTexture then
        local m = f:CreateMaskTexture()
        m:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(f.tex)
        f.tex:AddMaskTexture(m)
    end
    f.ring = f:CreateTexture(nil, "OVERLAY")
    f.ring:SetTexture(RING)
    f.ring:SetAllPoints()
    f.ring:SetVertexColor(0.72, 0.56, 0.18)
    function f:SetIcon(path, atlas)
        if atlas and self.tex.SetAtlas then
            self.tex:SetAtlas(atlas)
        else
            self.tex:SetTexture(path or ICON("INV_Misc_Gear_01"))
            self.tex:SetTexCoord(0.06, 0.94, 0.06, 0.94)
        end
        self.tex:SetVertexColor(1, 1, 1)
    end
    function f:SetClassOf(key)
        self.tex:SetTexCoord(0, 1, 0, 1)
        EUI():SetClass(self.tex, key)
    end
    return f
end

-- A thin bar: a grey track and a coloured fill; bar:Set(frac, color).
local function Bar(parent, w, h)
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(w, h or 2)
    b.track = Fill(b, { 1, 1, 1, 0.08 }, "ARTWORK")
    b.fill = Rect(b, C.gold, "ARTWORK", 1)
    b.fill:SetPoint("TOPLEFT")
    b.fill:SetPoint("BOTTOMLEFT")
    function b:Set(frac, c)
        frac = max(0, min(1, tonumber(frac) or 0))
        self.fill:SetWidth(max(1, frac * w))
        self.fill:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        self.fill:SetShown(frac > 0)
    end
    return b
end

-- A chip (the banner's): a round icon, a text, a pill shape. chip:Set(icon, text).
local function Chip(parent)
    local h = 22
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(80, h)
    UI():AddPillShape(p, h)
    p:SetPillColors({ 0.03, 0.03, 0.04, 0.78 }, { 0.25, 0.25, 0.28, 1 })
    p.icon = p:CreateTexture(nil, "ARTWORK")
    p.icon:SetSize(16, 16)
    p.icon:SetPoint("LEFT", 3, 0)
    if p.CreateMaskTexture then
        local m = p:CreateMaskTexture()
        m:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        m:SetAllPoints(p.icon)
        p.icon:AddMaskTexture(m)
    end
    p.fs = Text(p, 11, C.text)
    p.fs:SetPoint("LEFT", 25, 0)
    function p:Set(icon, text)
        self.icon:SetTexture(icon)
        self.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        self.fs:SetText(text or "")
        self:SetWidth(ceil(25 + EUI():TextWidth(self.fs) + 10))
    end
    return p
end

local function Pill(parent)
    local p = EUI():CreatePill(parent, 16)
    if p.SetBase then p:SetBase(0.05, 0.05, 0.06) end
    return p
end

-- A ring gauge drawn with lines (parts from the top, clockwise). g:Set({ { frac, color }, ... }): what the parts
-- don't cover is the dark track.
local SEGS = 90
local OVERLAP = 0.012                    -- radians each segment reaches past its neighbours (square ends, no notches)
local function Gauge(parent, r, width)
    local g = CreateFrame("Frame", nil, parent)
    g:SetSize(2 * r + width, 2 * r + width)
    g.lines = {}
    for i = 1, SEGS do
        local a1, a2 = pi / 2 - (i - 1) / SEGS * 2 * pi + OVERLAP, pi / 2 - i / SEGS * 2 * pi - OVERLAP
        local l = g:CreateLine(nil, "ARTWORK")
        l:SetStartPoint("CENTER", g, r * cos(a1), r * sin(a1))
        l:SetEndPoint("CENTER", g, r * cos(a2), r * sin(a2))
        l:SetThickness(width)
        g.lines[i] = l
    end
    function g:Set(parts)
        for i, l in ipairs(self.lines) do
            local mid, acc, c = (i - 0.5) / SEGS, 0, nil
            for _, p in ipairs(parts) do
                if mid >= acc and mid < acc + p[1] then c = p[2] break end
                acc = acc + p[1]
            end
            c = c or { 0.15, 0.15, 0.17 }
            l:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        end
    end
    g.big = Text(g, 17, C.white, true, "CENTER")
    g.big:SetPoint("CENTER", 0, 5)
    g.unit = Text(g, 8, { 0.66, 0.66, 0.7 }, false, "CENTER")
    g.unit:SetPoint("CENTER", 0, -10)
    return g
end

-- The chart of the last hour: a sample a column (an area under a line), the game's cleanups as small rings, a dashed
-- line for what is in use, the scale at the top left. c:Set(values, opts): opts.drops = { [i] = true }, opts.floor,
-- opts.color, opts.unit ("ms"), opts.min (the least top), opts.empty (said when there is nothing).
local function Chart(parent, x, y, w, h)
    local c = CreateFrame("Frame", nil, parent)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    c:SetSize(w, h)
    c.w, c.h = w, h
    c.cols, c.caps, c.rings, c.dash = {}, {}, {}, {}
    for i = 1, 3 do
        local gl = Rect(c, { 1, 1, 1, 0.05 }, "BORDER")
        gl:SetHeight(1)
        gl:SetPoint("TOPLEFT", 0, -floor(h * i / 4))
        gl:SetPoint("TOPRIGHT", 0, -floor(h * i / 4))
    end
    local base = Rect(c, { 1, 1, 1, 0.14 }, "BORDER")
    base:SetHeight(1)
    base:SetPoint("BOTTOMLEFT")
    base:SetPoint("BOTTOMRIGHT")
    c.top = Text(c, 10, { 0.49, 0.49, 0.52 }, true)
    c.top:SetPoint("BOTTOMLEFT", c, "TOPLEFT", 0, 3)
    c.empty = Text(c, 11, C.dim, false, "CENTER")
    c.empty:SetPoint("CENTER")
    function c:Set(values, o)
        o = o or {}
        local n = #values
        local top = 0
        for i = 1, n do top = max(top, values[i] or 0) end
        top = max(top * 1.1, o.min or 1)
        local col = o.color or C.mem
        local cw = self.w / 360
        for i = 1, max(n, #self.cols) do
            local f, cap = self.cols[i], self.caps[i]
            if i <= n then
                if not f then
                    f = Rect(self, col, "ARTWORK")
                    cap = Rect(self, col, "ARTWORK", 1)
                    self.cols[i], self.caps[i] = f, cap
                end
                local hh = max(1, (values[i] or 0) / top * self.h)
                local px = (360 - n + i - 1) * cw
                f:ClearAllPoints()
                f:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", px, 0)
                f:SetSize(max(1, cw + 0.4), hh)
                f:SetColorTexture(col[1], col[2], col[3], 0.17)
                f:Show()
                cap:ClearAllPoints()
                cap:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", px, hh - 1)
                cap:SetSize(max(1, cw + 0.4), 1.5)
                cap:SetColorTexture(col[1], col[2], col[3], 1)
                cap:Show()
            elseif f then
                f:Hide()
                cap:Hide()
            end
        end
        local ri = 0
        if o.drops then
            for i = 1, n do
                if o.drops[i] then
                    ri = ri + 1
                    local r = self.rings[ri]
                    if not r then
                        r = self:CreateTexture(nil, "OVERLAY")
                        r:SetTexture(RING)
                        r:SetSize(7, 7)
                        r:SetVertexColor(C.green[1], C.green[2], C.green[3])
                        self.rings[ri] = r
                    end
                    r:ClearAllPoints()
                    r:SetPoint("CENTER", self, "BOTTOMLEFT", (360 - n + i - 0.5) * cw, (values[i] or 0) / top * self.h)
                    r:Show()
                end
            end
        end
        for i = ri + 1, #self.rings do self.rings[i]:Hide() end
        local fy = o.floor and o.floor / top * self.h
        for i = 1, 60 do
            local d = self.dash[i]
            if fy and n > 0 then
                if not d then
                    d = Rect(self, C.green, "OVERLAY")
                    self.dash[i] = d
                end
                d:ClearAllPoints()
                d:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", (i - 1) * self.w / 60, fy)
                d:SetSize(self.w / 120, 1)
                d:Show()
            elseif d then
                d:Hide()
            end
        end
        self.top:SetText(n > 0 and ((o.unit == "ms") and ("%.1f ms"):format(top) or Fmt(top)) or "")
        self.empty:SetShown(n == 0)
        self.empty:SetText(o.empty or "No samples yet: one comes every 10 s.")
    end
    return c
end

-- A row of a handler list: the kind's icon, the handler (in the kind's colour), where it comes from, a bar, and the
-- numbers (their right edges at cols[i] from the row's left). row:Set(data).
local function HandlerRow(parent, w, h, cols)
    local r = CreateFrame("Button", nil, parent)
    r:SetSize(w, h)
    r.sel = Fill(r, { 1, 0.82, 0, 0.07 }, "BACKGROUND")
    r.selBar = Rect(r, C.mem, "ARTWORK")
    r.selBar:SetPoint("TOPLEFT")
    r.selBar:SetPoint("BOTTOMLEFT")
    r.selBar:SetWidth(2)
    r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
    r.rule:SetHeight(1)
    r.rule:SetPoint("TOPLEFT")
    r.rule:SetPoint("TOPRIGHT")
    r.icon = Icon(r, 24)
    r.icon:SetPoint("LEFT", 10, 0)
    local nameW = cols[1] - 62 - 44 - 8
    r.name = Text(r, 12, C.text)
    r.name:SetPoint("TOPLEFT", 44, -(floor(h / 2) - 13))
    r.name:SetWidth(nameW)
    r.sub = Text(r, 10, { 0.5, 0.5, 0.54 })
    r.sub:SetPoint("TOPLEFT", 44, -(floor(h / 2) + 1))
    r.sub:SetWidth(nameW)
    r.bar = Bar(r, nameW, 2)
    r.bar:SetPoint("BOTTOMLEFT", 44, 3)
    r.loop = Pill(r)
    r.cells = {}
    for i, x in ipairs(cols) do r.cells[i] = Cell(r, x, -(floor(h / 2) - 7), 62, 12, i == 1 and C.white or { 0.66, 0.66, 0.7 }) end
    function r:Set(d)
        self.data = d
        local k = KIND[d.kind] or KIND.event
        self.icon.tex:SetTexture(k[1])
        self.name:SetText(d.name)
        Color(self.name, k[2])
        self.sub:SetText(d.sub or "")
        self.bar:Set(d.frac, k[2])
        for i, fs in ipairs(self.cells) do fs:SetText(d.cells[i] or "") end
        self.sel:SetShown(d.picked and true or false)
        self.selBar:SetShown(d.picked and true or false)
        if d.loop then
            self.loop:SetKind("loop?", "live")
            self.loop:ClearAllPoints()
            self.loop:SetPoint("LEFT", self.name, "LEFT", min(nameW - 44, EUI():TextWidth(self.name) + 8), 0)
            self.loop:Show()
        else
            self.loop:Hide()
        end
        self:Show()
    end
    return r
end

local function Pool(list, i, make)
    local f = list[i]
    if not f then
        f = make()
        list[i] = f
    end
    return f
end

-- A column header line: the first title at x 44 (over the names), the others right-aligned at cols[i].
local function Heads(parent, y, first, titles, cols)
    local out = {}
    local f = Text(parent, 10, C.cap)
    f:SetPoint("TOPLEFT", 44, y)
    f:SetText(first or "")
    out[0] = f
    for i, t in ipairs(titles) do
        local fs = Cell(parent, cols[i], y, 70, 10, C.cap)
        fs:SetText(t)
        out[i] = fs
    end
    return out
end

---------------------------------------------------------------------------
-- The measured rows: by handler (as Perf measured them) or per file
---------------------------------------------------------------------------

-- The last Measure as rows: { key, kind, name, sub, at (where), kbMin, msS, callsS, worstKb, worstMs, loop, sent,
-- who, gc, calls }, most garbage first; and the measurement.
local function MeasuredRows(byFile)
    local r = Perf().last
    if not r then return {}, nil end
    local secs = max(1, r.seconds)
    local out = {}
    for _, row in ipairs(r.rows) do
        local at, name = tostring(row.key):match("^(.-)  (.*)$")
        at, name = at or "?", name or tostring(row.key)
        local kind = row.what
        -- (the second line: where, and what it is - a message type's meaning, else the kind; the icon shows the kind)
        local msg = name:match("^message (%S+)$")
        local sub = at .. " · " .. ((msg and MSG[msg]) or (KIND[kind] or KIND.event)[3])
        if at == "?" then sub = "a file the page could not name · " .. (KIND[kind] or KIND.event)[3] end
        out[#out + 1] = { key = row.key, kind = kind, name = name, at = at, sub = sub,
                          kbMin = row.kb * 60 / secs, msS = row.ms / secs, callsS = row.calls / secs,
                          worstKb = row.maxKb or 0, worstMs = row.maxMs or 0, loop = row.loop, sent = row.sent,
                          who = row.who, gc = row.gc, calls = row.calls }
    end
    if byFile then
        local by, list = {}, {}
        for _, x in ipairs(out) do
            local file = x.at:match("^([^:]+)") or x.at
            local f = by[file]
            if not f then
                f = { key = "file:" .. file, kind = x.kind, name = file, at = file, kbMin = 0, msS = 0, callsS = 0,
                      worstKb = 0, worstMs = 0, n = 0 }
                by[file] = f
                list[#list + 1] = f
            end
            f.kbMin, f.msS, f.callsS, f.n = f.kbMin + x.kbMin, f.msS + x.msS, f.callsS + x.callsS, f.n + 1
            f.worstKb, f.worstMs = max(f.worstKb, x.worstKb), max(f.worstMs, x.worstMs)
            f.sub = f.n == 1 and "1 handler" or (f.n .. " handlers")
        end
        out = list
    end
    tsort(out, function(a, b)
        if a.kbMin ~= b.kbMin then return a.kbMin > b.kbMin end
        return a.msS > b.msS
    end)
    return out, r
end

local function GarbageCells(x) return { Fmt(x.kbMin), ("%.2f"):format(x.msS), ("%.1f"):format(x.callsS), Fmt(x.worstKb) } end
local function CpuCells(x) return { ("%.2f"):format(x.msS), ("%.1f"):format(x.callsS), ("%.1f"):format(x.worstMs) } end

---------------------------------------------------------------------------
-- The banner (every tab)
---------------------------------------------------------------------------

local function CreateBanner(p)
    local b = CreateFrame("Frame", nil, p)
    b:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, BAN_Y)
    b:SetSize(W, BAN_H)
    b.art = b:CreateTexture(nil, "BACKGROUND")
    b.art:SetPoint("TOPLEFT", 1, -1)
    b.art:SetPoint("BOTTOMRIGHT", -1, 1)
    b.art:SetTexture(ART)
    -- (a strip of the loading screen below its logo band)
    b.art:SetTexCoord(0.04, 0.96, 0.36, 0.36 + 0.92 * (BAN_H / W) * (4 / 3))
    EUI():AddShade(b)
    EUI():Edge(b, PEDGE[1], PEDGE[2], PEDGE[3], PEDGE[4])
    b.gauge = Gauge(b, 30, 7)
    b.gauge:SetPoint("CENTER", b, "TOPLEFT", 52, -48)
    b.kick = Text(b, 9, C.cap)
    b.kick:SetPoint("TOPLEFT", 102, -14)
    b.kick:SetWidth(446)
    b.big = Text(b, 25, C.white, true)
    b.big:SetPoint("TOPLEFT", 102, -28)
    b.bigUnit = Text(b, 13, { 0.81, 0.81, 0.83 })
    b.bigUnit:SetPoint("BOTTOMLEFT", b.big, "BOTTOMRIGHT", 4, 4)
    b.pill = Pill(b)
    b.pill:SetPoint("LEFT", b.bigUnit, "RIGHT", 12, 1)
    b.sub = Text(b, 11, { 0.73, 0.73, 0.76 })
    b.sub:SetPoint("TOPLEFT", 102, -64)
    b.sub:SetWidth(446)
    b.chips = {}
    for i = 1, 4 do b.chips[i] = Chip(b) end
    b.chips[1]:SetPoint("TOPLEFT", b, "TOPLEFT", 560, -12)
    b.chips[2]:SetPoint("LEFT", b.chips[1], "RIGHT", 6, 0)
    b.chips[3]:SetPoint("TOPLEFT", b, "TOPLEFT", 560, -40)
    b.chips[4]:SetPoint("TOPLEFT", b, "TOPLEFT", 560, -68)
    return b
end

local function FillBanner(p)
    local b, P = p.banner, Perf()
    local s = P.samples
    local cur = s[#s] and s[#s].kb or 0
    local clean = P.clean
    local inUse = clean and clean.after
    local se = P:Session()
    local now = GetTime and GetTime() or 0
    b.kick:SetText(("SESSION %s · %s · BUILD %s · %s"):format(Span(now - (se.started or now)):upper(), tostring(se.version),
        tostring(se.build):sub(1, 8):upper(), se.update and ("IN-GAME UPDATE " .. se.update):upper() or "NO IN-GAME UPDATE"))
    b.big:SetText(("%.1f"):format((inUse or cur) / 1024))
    b.bigUnit:SetText(inUse and "MB in use" or "MB now")
    local cpu = P:CPU()
    if cpu and cpu.share then
        b.pill:SetKind(("%.1f%% of frame time"):format(cpu.share * 100), "rank")
        b.pill:Show()
    else
        b.pill:Hide()
    end
    local parts = {}
    if inUse then
        parts[#parts + 1] = ("%s now"):format(Fmt(cur))
        parts[#parts + 1] = ("%s garbage"):format(Fmt(max(0, cur - inUse)))
    else
        parts[#parts + 1] = "Clean up shows what is in use"
    end
    parts[#parts + 1] = ("peak %s"):format(Fmt(P.stats.peak))
    local n = P.stats.cleanups
    parts[#parts + 1] = n > 0 and ("%d cleanup%s, last %s"):format(n, n == 1 and "" or "s", Ago(P.stats.lastCleanAt))
        or "no cleanup yet"
    b.sub:SetText(table.concat(parts, " · "))
    -- the ring: in use (gold) and garbage (grey) of now, on a scale a little over the peak
    local total = max(cur, 1)
    local scale = max(total, P.stats.peak or 0) * 1.05
    if inUse then
        b.gauge:Set({ { min(inUse, total) / scale, C.mem }, { max(0, total - inUse) / scale, C.garbage } })
    else
        b.gauge:Set({ { total / scale, C.mem } })
    end
    b.gauge.big:SetText(tostring(floor(cur / 1024 + 0.5)))
    b.gauge.unit:SetText("MB")
    local fps = P:FPS()
    b.chips[1]:Set(ICON("Spell_Nature_Lightning"), cpu and cpu.recent and ("CPU %.2f ms"):format(cpu.recent)
        or (cpu and cpu.off and "CPU profiler off" or "CPU n/a"))
    b.chips[2]:Set(ICON("INV_Misc_EngGizmos_20"), fps and ("%d fps"):format(floor(fps + 0.5)) or "fps n/a")
    local rate = P:GarbageRate()
    b.chips[3]:Set(ICON("INV_Misc_Bag_10"), rate and (Fmt(rate) .. " garbage / min") or "garbage / min after 2 samples")
    local rooms = se.rooms
    b.chips[4]:Set(ICON("INV_Misc_Map_01"), rooms.loaded and ("3D rooms loaded · %s"):format(Fmt(rooms.kb or 0))
        or "3D rooms not loaded")
end

---------------------------------------------------------------------------
-- Overview
---------------------------------------------------------------------------

local function CreateOverview(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    -- the last hour
    local c = Box(v, PAD, BODY_Y, LEFT_W, 228, "The last hour")
    v.hourBox = c
    c.tabs = {}
    c.tabs.memory = UI():CreateUnderlineTab(c, "Memory", function() state.chart = "memory" PerfUI:Refresh() end, "small")
    c.tabs.memory:SetPoint("TOPLEFT", 196, -5)
    c.tabs.cpu = UI():CreateUnderlineTab(c, "CPU", function() state.chart = "cpu" PerfUI:Refresh() end, "small")
    c.tabs.cpu:SetPoint("LEFT", c.tabs.memory, "RIGHT", 4, 0)
    Link(c, "Garbage", function() PerfUI:SetTab("garbage") end)
    c.legend = Text(c, 10, C.dim)
    c.legend:SetPoint("TOPRIGHT", -14, -38)
    c.chart = Chart(c, 14, -60, LEFT_W - 28, 118)
    c.facts = {}
    for i = 1, 3 do
        local f = Text(c, 11, C.text)
        f:SetPoint("TOPLEFT", 14 + (i - 1) * 156, -198)
        f:SetWidth(150)
        c.facts[i] = f
    end
    -- next to the other addons
    local s = Box(v, PAD + LEFT_W + GAP, BODY_Y, RIGHT_W, BODY_H, "Next to your other addons")
    v.addons = s
    Cell(s, RIGHT_W - 60, -38, 70, 10, C.cap):SetText("memory")
    Cell(s, RIGHT_W - 12, -38, 40, 10, C.cap):SetText("ms")
    s.rows = {}
    for i = 1, 10 do
        local r = CreateFrame("Frame", nil, s)
        r:SetSize(RIGHT_W - 2, 27)
        r:SetPoint("TOPLEFT", 1, -52 - (i - 1) * 27)
        r.me = Fill(r, { 0.4, 0.72, 1, 0.12 }, "BACKGROUND")
        r.meBar = Rect(r, C.blue, "ARTWORK")
        r.meBar:SetPoint("TOPLEFT")
        r.meBar:SetPoint("BOTTOMLEFT")
        r.meBar:SetWidth(2)
        r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
        r.rule:SetHeight(1)
        r.rule:SetPoint("TOPLEFT")
        r.rule:SetPoint("TOPRIGHT")
        r.rank = Cell(r, 22, -7, 18, 11, C.dim)
        r.icon = RoundIcon(r, 17)
        r.icon:SetPoint("LEFT", 27, 0)
        r.name = Text(r, 12, C.text)
        r.name:SetPoint("TOPLEFT", 54, -6)
        r.name:SetWidth(RIGHT_W - 54 - 124)
        r.kb = Cell(r, RIGHT_W - 60, -7, 70, 12, C.text)
        r.cpu = Cell(r, RIGHT_W - 12, -7, 40, 12, { 0.6, 0.6, 0.64 })
        r.bar = Bar(r, RIGHT_W - 54 - 120, 2)
        r.bar:SetPoint("BOTTOMLEFT", 54, 3)
        s.rows[i] = r
    end
    s.share = Text(s, 21, C.blue, true)
    s.share:SetPoint("TOPLEFT", 12, -330)
    s.shareText = Text(s, 11, C.grey)
    s.shareText:SetPoint("BOTTOMLEFT", s.share, "BOTTOMRIGHT", 6, 3)
    s.shareText:SetWidth(RIGHT_W - 70)
    s.shareBar = Bar(s, RIGHT_W - 24, 4)
    s.shareBar:SetPoint("TOPLEFT", 12, -362)
    s.rankText = Text(s, 10, C.dim)
    s.rankText:SetPoint("TOPLEFT", 12, -372)
    s.rankText:SetWidth(RIGHT_W - 24)
    -- the biggest three
    local g = Box(v, PAD, BODY_Y - 228 - GAP, LEFT_W, BODY_H - 228 - GAP, "Biggest right now")
    v.biggest = g
    Link(g, "Garbage", function() PerfUI:SetTab("garbage") end)
    g.cols = { LEFT_W - 136, LEFT_W - 70, LEFT_W - 12 }
    g.heads = Heads(g, -37, "Handler", { "per min", "ms / s", "calls / s" }, g.cols)
    g.rows = {}
    g.empty = Text(g, 11, C.dim, false, "CENTER")
    g.empty:SetPoint("TOPLEFT", 10, -80)
    g.empty:SetWidth(LEFT_W - 20)
    return v
end

local function Nth(k)
    if k == 1 then return "most" end
    if k == 2 then return "2nd most" end
    if k == 3 then return "3rd most" end
    return k .. "th most"
end

local function FillOverview(p)
    local v, P = p.views.overview, Perf()
    local c = v.hourBox
    for k, t in pairs(c.tabs) do t:SetActive(k == state.chart) end
    local values, drops = {}, {}
    for i, smp in ipairs(P.samples) do
        values[i] = state.chart == "cpu" and (smp.cpu or 0) or smp.kb
        drops[i] = smp.drop
    end
    if state.chart == "cpu" then
        c.legend:SetText("ms a frame, the profiler's recent average")
        local cpu = P:CPU()
        c.chart:Set(cpu and values or {}, { color = C.cpu, unit = "ms", min = 0.5,
            empty = cpu and "No samples yet: one comes every 10 s." or "This client has no addon profiler." })
    else
        c.legend:SetText("|cff4fd36b- -|r in use after cleanup    |cff4fd36bo|r the game cleaned up")
        c.chart:Set(values, { color = C.mem, drops = drops, floor = P.clean and P.clean.after })
    end
    local addons, total = P:Addons()
    local n = P.stats.cleanups
    local facts = { ("|cff9e9ea4Peak|r %s"):format(Fmt(P.stats.peak)),
        ("|cff9e9ea4Cleanups|r %d%s"):format(n, n > 0 and (", last " .. Ago(P.stats.lastCleanAt)) or ""),
        ("|cff9e9ea4All addons|r %s"):format(Fmt(total)) }
    for i, f in ipairs(c.facts) do f:SetText(facts[i]) end
    -- next to the other addons: the top ten, me among them (in the last place when I'm further down)
    local s = v.addons
    local list, mine = {}, nil
    for i, a in ipairs(addons) do
        if a.me then mine = i end
        if i <= 10 then list[#list + 1] = { a = a, rank = i } end
    end
    if mine and mine > 10 then list[10] = { a = addons[mine], rank = mine } end
    local maxKb = addons[1] and addons[1].kb or 1
    local cpuTotal, myCpu, cpuRank = 0, nil, 1
    for _, a in ipairs(addons) do
        cpuTotal = cpuTotal + (a.cpu or 0)
        if a.me then myCpu = a.cpu end
    end
    if myCpu then
        for _, a in ipairs(addons) do if not a.me and (a.cpu or 0) > myCpu then cpuRank = cpuRank + 1 end end
    end
    for i, r in ipairs(s.rows) do
        local e = list[i]
        if e then
            local a = e.a
            r.me:SetShown(a.me)
            r.meBar:SetShown(a.me)
            r.rank:SetText(e.rank)
            r.icon:SetIcon(a.icon, a.atlas)
            r.name:SetText(a.name)
            Color(r.name, a.me and { 0.62, 0.82, 1 } or C.text)
            r.kb:SetText(Fmt(a.kb))
            r.cpu:SetText(a.cpu and ("%.2f"):format(a.cpu) or "")
            r.bar:Set(a.kb / max(1, maxKb), a.me and C.blue or { 0.36, 0.36, 0.4 })
            r:Show()
        else
            r:Hide()
        end
    end
    local me = mine and addons[mine]
    if me and total > 0 then
        local share = me.kb / total
        s.share:SetText(("%d%%"):format(floor(share * 100 + 0.5)))
        s.shareText:SetText("of all addons' memory")
        s.shareBar:Set(share, C.blue)
        local cpuPart = (cpuTotal > 0 and myCpu) and ("%d%% of their CPU · "):format(floor(myCpu / cpuTotal * 100 + 0.5)) or ""
        s.rankText:SetText(("%s%s memory%s"):format(cpuPart, Nth(mine), myCpu and (", " .. Nth(cpuRank) .. " CPU") or ""))
    else
        s.share:SetText("")
        s.shareText:SetText("")
        s.shareBar:Set(0, C.blue)
        s.rankText:SetText("")
    end
    -- the biggest three
    local g = v.biggest
    local rows, r = MeasuredRows(false)
    g.note:SetText(r and ("measured %s, %d s"):format(Ago(r.at), r.seconds) or "")
    local maxKb2 = rows[1] and rows[1].kbMin or 1
    for i = 1, 3 do
        local x = rows[i]
        local row = Pool(g.rows, i, function()
            local hr = HandlerRow(g, LEFT_W - 2, 36, g.cols)
            hr:SetPoint("TOPLEFT", 1, -51 - (i - 1) * 36)
            hr:SetScript("OnClick", function(self) state.picked = self.data and self.data.key PerfUI:SetTab("garbage") end)
            return hr
        end)
        if x then
            local cells = GarbageCells(x)
            row:Set({ kind = x.kind, name = x.name, sub = x.sub, frac = x.kbMin / max(1, maxKb2), loop = x.loop,
                      key = x.key, cells = { cells[1], cells[2], cells[3] } })
        else
            row:Hide()
        end
    end
    for _, h in pairs(g.heads) do h:SetShown(#rows > 0) end
    g.empty:SetShown(#rows == 0)
    g.empty:SetText("Measure 30 s times every DisasterZone handler and weighs the garbage it makes.")
end

---------------------------------------------------------------------------
-- Garbage
---------------------------------------------------------------------------

local LIST_W, SIDE_W = 520, W - 520 - GAP
local ROW_H = 34

local function CreateGarbage(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    local c = Box(v, PAD, BODY_Y, LIST_W, BODY_H, "Who makes garbage")
    v.list = c
    c.group = Link(c, "By file", function() state.byFile = not state.byFile PerfUI:Refresh() end)
    c.cols = { LIST_W - 196, LIST_W - 138, LIST_W - 84, LIST_W - 28 }
    c.heads = Heads(c, -37, "Handler", { "per min", "ms / s", "calls / s", "worst call" }, c.cols)
    c.scroll = UI():CreateScrollFrame(c)
    c.scroll:SetPoint("TOPLEFT", 1, -51)
    c.scroll:SetSize(LIST_W - 18, BODY_H - 51 - 4)
    c.child = CreateFrame("Frame", nil, c.scroll)
    c.child:SetSize(LIST_W - 18, 10)
    c.scroll:SetScrollChild(c.child)
    c.rows = {}
    c.empty = Text(c, 11, C.dim, false, "CENTER")
    c.empty:SetPoint("TOPLEFT", 10, -110)
    c.empty:SetWidth(LIST_W - 20)
    -- the picked one
    local s = Box(v, PAD + LIST_W + GAP, BODY_Y, SIDE_W, BODY_H, "")
    v.side = s
    s.ht:SetWidth(SIDE_W - 20)
    s.where = Text(s, 10, C.dim)
    s.where:SetPoint("TOPLEFT", 12, -36)
    s.where:SetWidth(SIDE_W - 24)
    s.stats = {}
    for i = 1, 3 do
        local big = Text(s, 17, C.white, true)
        big:SetPoint("TOPLEFT", 12 + (i - 1) * 76, -54)
        local cap = Text(s, 10, C.grey)
        cap:SetPoint("TOPLEFT", big, "BOTTOMLEFT", 0, -2)
        s.stats[i] = { big, cap }
    end
    s.rule = HLine(s, -98)
    s.fromHead = Text(s, 10, C.cap)
    s.fromHead:SetPoint("TOPLEFT", 12, -106)
    s.sentHead = Cell(s, SIDE_W - 52, -106, 40, 10, C.cap)
    s.revHead = Cell(s, SIDE_W - 12, -106, 40, 10, C.cap)
    s.who = {}
    for i = 1, 4 do
        local r = CreateFrame("Frame", nil, s)
        r:SetSize(SIDE_W - 2, 27)
        r:SetPoint("TOPLEFT", 1, -122 - (i - 1) * 27)
        r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
        r.rule:SetHeight(1)
        r.rule:SetPoint("TOPLEFT")
        r.rule:SetPoint("TOPRIGHT")
        r.me = Fill(r, { 0.4, 0.72, 1, 0.12 }, "BACKGROUND")
        r.face = RoundIcon(r, 16)
        r.face:SetPoint("LEFT", 10, 0)
        r.name = Text(r, 12, C.text)
        r.name:SetPoint("LEFT", 36, 0)
        r.name:SetWidth(SIDE_W - 36 - 100)
        r.n = Cell(r, SIDE_W - 52, -7, 40, 12, C.text)
        r.rev = Cell(r, SIDE_W - 12, -7, 40, 12, { 0.6, 0.6, 0.64 })
        s.who[i] = r
    end
    s.loop = Pill(s)
    s.loop:SetPoint("TOPLEFT", 12, -238)
    s.loopText = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    Sized(s.loopText, 10)
    Color(s.loopText, { 0.73, 0.73, 0.76 })
    s.loopText:SetJustifyH("LEFT")
    s.loopText:SetJustifyV("TOP")
    s.loopText:SetWordWrap(true)
    s.loopText:SetPoint("TOPLEFT", 12, -260)
    s.loopText:SetWidth(SIDE_W - 24)
    s.loopText:SetHeight(52)
    s.rule2 = HLine(s, -318)
    s.backHead = Text(s, 10, C.cap)
    s.backHead:SetPoint("TOPLEFT", 12, -326)
    s.back = Text(s, 11, { 0.73, 0.73, 0.76 })
    s.back:SetPoint("TOPLEFT", 12, -344)
    s.back:SetWidth(SIDE_W - 24)
    s.back2 = Text(s, 10, C.dim)
    s.back2:SetPoint("TOPLEFT", 12, -364)
    s.back2:SetWidth(SIDE_W - 24)
    return v
end

local function FillSide(s, x, rows, r)
    if not x then
        s.ht:SetText(state.byFile and "Per file" or "Nothing picked")
        s.where:SetText(state.byFile and "Back to By handler to pick one" or "Measure, then click a row")
        for _, st in ipairs(s.stats) do st[1]:SetText("") st[2]:SetText("") end
        for _, w in ipairs(s.who) do w:Hide() end
        s.fromHead:SetText("") s.sentHead:SetText("") s.revHead:SetText("")
        s.loop:Hide()
        s.loopText:SetText("")
        s.backHead:SetText("") s.back:SetText("") s.back2:SetText("")
        s.rule:Hide()
        s.rule2:Hide()
        return
    end
    s.rule:Show()
    s.ht:SetText(x.name)
    s.where:SetText(x.sub)
    local stats = { { Fmt(x.kbMin), "per min" }, { ("%.1f"):format(x.callsS), "calls / s" }, { Fmt(x.worstKb), "worst call" } }
    for i, st in ipairs(s.stats) do st[1]:SetText(stats[i][1]) st[2]:SetText(stats[i][2]) end
    -- who it came from (a message) / where it went (a send)
    local list = {}
    for who, w in pairs(x.who or {}) do list[#list + 1] = { who = who, n = w.n, rev = w.rev } end
    tsort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.who < b.who end)
    local isSend = x.kind == "send"
    s.fromHead:SetText(#list > 0 and (isSend and "To" or "From") or "")
    s.sentHead:SetText(#list > 0 and (isSend and "sent" or "got") or "")
    s.revHead:SetText(#list > 0 and "rev" or "")
    local shown = 0
    for i, row in ipairs(s.who) do
        local e = list[i]
        if e then
            shown = i
            local isMe = ns.Util and ns.Util.IsMe and ns.Util.IsMe(e.who)
            row.me:SetShown(isMe and true or false)
            if e.who:find("-", 1, true) then row.face:SetClassOf(e.who) else row.face:SetIcon(ICON("INV_Letter_02")) end
            row.name:SetText((e.who:match("^([^%-]+)") or e.who) .. (isMe and " (you)" or ""))
            row.n:SetText("x" .. e.n)
            row.rev:SetText(e.rev and ("..." .. tostring(e.rev):sub(-3)) or "")
            row:Show()
        else
            row:Hide()
        end
    end
    -- a sync loop, or what the handler did: under the last sender (or the stats), then what I send back under it
    local y = shown > 0 and (-122 - shown * 27 - 12) or -106
    s.loop:ClearAllPoints()
    s.loop:SetPoint("TOPLEFT", 12, y)
    s.loopText:ClearAllPoints()
    s.loopText:SetPoint("TOPLEFT", 12, x.loop and (y - 22) or y)
    local by = (x.loop and (y - 22) or y) - 58
    s.rule2:ClearAllPoints()
    s.rule2:SetPoint("TOPLEFT", 12, by)
    s.rule2:SetPoint("TOPRIGHT", -12, by)
    s.backHead:SetPoint("TOPLEFT", 12, by - 8)
    s.back:SetPoint("TOPLEFT", 12, by - 26)
    s.back2:SetPoint("TOPLEFT", 12, by - 46)
    local msg = x.name:match("^message (%S+)$")
    if x.loop then
        s.loop:SetKind("sync loop?", "live")
        s.loop:Show()
        s.loopText:SetText(("You got %s %.1f times a second and sent it back %.1f times a second while measuring: a "
            .. "message type that goes both ways this often."):format(msg or "it", x.callsS, (x.sent or 0) / max(1, r.seconds)))
    else
        s.loop:Hide()
        s.loopText:SetText(("%d call%s in %d s; the slowest took %.1f ms.%s"):format(x.calls or 0,
            (x.calls or 0) == 1 and "" or "s", r.seconds, x.worstMs, (x.gc or 0) > 0
            and (" %d had a cleanup inside: their garbage is not counted."):format(x.gc) or ""))
    end
    -- what I send back of the same type
    local back
    if msg then
        for _, o in ipairs(rows) do
            if o.name:match("^send " .. msg .. " ") then back = o break end
        end
    end
    s.rule2:SetShown(back ~= nil)
    if back then
        s.backHead:SetText("I send back")
        s.back:SetText(("%.1f / s · %s a minute"):format(back.callsS, Fmt(back.kbMin)))
        local ch = back.name:match("^send %S+ (%S+)$")
        s.back2:SetText(ch and ("on " .. ch) or "")
    else
        s.backHead:SetText("") s.back:SetText("") s.back2:SetText("")
    end
end

local function FillGarbage(p)
    local v = p.views.garbage
    local c = v.list
    local rows, r = MeasuredRows(state.byFile)
    c.group:SetLabel(state.byFile and "By handler" or "By file")
    local found = r and r.grew > 0 and min(100, floor(r.attributed / r.grew * 100 + 0.5)) or nil
    c.note:SetText(r and ("measured %s · %d s%s"):format(Ago(r.at), r.seconds,
        found and (" · %d%% of the growth found"):format(found) or "") or "")
    c.heads[0]:SetText(state.byFile and "File" or "Handler")
    local maxKb = rows[1] and rows[1].kbMin or 1
    local picked
    if not state.byFile then
        for _, x in ipairs(rows) do if x.key == state.picked then picked = x end end
        if not picked then
            for _, x in ipairs(rows) do if x.loop then picked = x break end end
            picked = picked or rows[1]
        end
    end
    for i, x in ipairs(rows) do
        local row = Pool(c.rows, i, function()
            local hr = HandlerRow(c.child, LIST_W - 18, ROW_H, c.cols)
            hr:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            hr:SetScript("OnClick", function(self)
                if state.byFile then return end
                state.picked = self.data and self.data.key
                PerfUI:Refresh()
            end)
            return hr
        end)
        row:Set({ kind = x.kind, name = x.name, sub = x.sub, frac = x.kbMin / max(1, maxKb), loop = x.loop, key = x.key,
                  picked = x == picked, cells = GarbageCells(x) })
    end
    for i = #rows + 1, #c.rows do c.rows[i]:Hide() end
    c.child:SetHeight(max(10, #rows * ROW_H))
    for _, h in pairs(c.heads) do h:SetShown(#rows > 0) end
    c.empty:SetShown(#rows == 0)
    c.empty:SetText(Perf():IsMeasuring() and "Measuring..." or "Press Measure 30 s: every DisasterZone handler is timed and weighed.")
    FillSide(v.side, picked, rows, r)
end

---------------------------------------------------------------------------
-- Memory
---------------------------------------------------------------------------

local PAGES_W, SAVED_W = 383, W - 383 - GAP

-- A box with a scrolled list of simple rows (a name, a grey second name, two numbers, a bar).
local function ListBox(v, x, w, h, title, note, heads, rowH, listH)
    local c = Box(v, x, BODY_Y, w, h, title)
    c.note:SetText(note)
    c.cols, c.rowH = { w - 92, w - 34 }, rowH
    c.heads = {}
    for i, t in ipairs(heads) do
        local fs = Cell(c, c.cols[i], -37, 70, 10, C.cap)
        fs:SetText(t)
        c.heads[i] = fs
    end
    c.scroll = UI():CreateScrollFrame(c)
    c.scroll:SetPoint("TOPLEFT", 1, -51)
    c.scroll:SetSize(w - 18, listH or (h - 51 - 4))
    c.child = CreateFrame("Frame", nil, c.scroll)
    c.child:SetSize(w - 18, 10)
    c.scroll:SetScrollChild(c.child)
    c.rows = {}
    c.rowW = w - 18
    return c
end

local function SimpleRow(parent, w, h, cols)
    local r = CreateFrame("Frame", nil, parent)
    r:SetSize(w, h)
    r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
    r.rule:SetHeight(1)
    r.rule:SetPoint("TOPLEFT")
    r.rule:SetPoint("TOPRIGHT")
    r.name = Text(r, 12, C.text)
    r.name:SetPoint("TOPLEFT", 12, -6)
    r.name2 = Text(r, 10, C.dim)
    r.name2:SetPoint("LEFT", r.name, "RIGHT", 7, -1)
    r.cells = {}
    for i, x in ipairs(cols) do r.cells[i] = Cell(r, x, -7, 70, 12, i == 1 and C.text or { 0.6, 0.6, 0.64 }) end
    r.bar = Bar(r, cols[1] - 90, 2)
    r.bar:SetPoint("BOTTOMLEFT", 12, 4)
    return r
end

local function FillList(c, items, fill)
    local maxV = items[1] and items[1].v or 1
    for i, it in ipairs(items) do
        local row = Pool(c.rows, i, function()
            local sr = SimpleRow(c.child, c.rowW, c.rowH, c.cols)
            sr:SetPoint("TOPLEFT", 0, -(i - 1) * c.rowH)
            return sr
        end)
        fill(row, it, it.v / max(1, maxV))
        row:Show()
    end
    for i = #items + 1, #c.rows do c.rows[i]:Hide() end
    c.child:SetHeight(max(10, #items * c.rowH))
end

local function CreateMemory(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    v.pages = ListBox(v, PAD, PAGES_W, BODY_H, "Pages built", "kept until a /reload", { "widgets", "built in" }, 30,
        BODY_H - 51 - 36)
    v.pages.foot = Text(v.pages, 11, C.grey)
    v.pages.foot:SetPoint("BOTTOMLEFT", 12, 12)
    v.pages.foot:SetWidth(PAGES_W - 24)
    v.saved = ListBox(v, PAD + PAGES_W + GAP, SAVED_W, 300, "Saved data", "written at logout", { "size", "entries" }, 29)
    -- the 3D rooms
    local r = Box(v, PAD + PAGES_W + GAP, BODY_Y - 300 - GAP, SAVED_W, BODY_H - 300 - GAP, nil)
    v.rooms = r
    r.art = Icon(r, 40)
    r.art:SetPoint("TOPLEFT", 12, -14)
    r.art.tex:SetTexture(ROOMS_ART)
    r.art.tex:SetTexCoord(0.3, 0.7, 0.42, 0.82)
    r.title = Text(r, 13, C.gold)
    r.title:SetPoint("TOPLEFT", 62, -13)
    r.title:SetText("3D rooms")
    r.pill = Pill(r)
    r.pill:SetPoint("LEFT", r.title, "RIGHT", 10, 0)
    r.line1 = Text(r, 11, { 0.73, 0.73, 0.76 })
    r.line1:SetPoint("TOPLEFT", 62, -35)
    r.line1:SetWidth(SAVED_W - 74)
    r.line2 = Text(r, 10, C.dim)
    r.line2:SetPoint("TOPLEFT", 62, -53)
    r.line2:SetWidth(SAVED_W - 74)
    return v
end

local function FillMemory(p)
    local v, P = p.views.memory, Perf()
    local pages, built, notBuilt, widgets = {}, 0, 0, 0
    for _, pg in ipairs(P:Pages()) do
        if pg.widgets then
            built = built + 1
            widgets = widgets + pg.widgets
            pages[#pages + 1] = { v = pg.widgets, label = pg.label or pg.key, build = pg.build }
        else
            notBuilt = notBuilt + 1
        end
    end
    FillList(v.pages, pages, function(row, it, frac)
        row.name:SetText(it.label)
        row.name2:SetText("")
        row.cells[1]:SetText(tostring(it.v))
        row.cells[2]:SetText(it.build and ("%d ms"):format(floor(it.build + 0.5)) or "")
        row.bar:Set(frac, C.mem)
    end)
    v.pages.foot:SetText(("%d widgets on %d page%s · %d not built yet"):format(widgets, built, built == 1 and "" or "s",
        notBuilt))
    local saved = {}
    for _, sv in ipairs(P:SavedSizes()) do
        local db, sec = sv.name:match("^([^%.]+)%.(.+)$")
        saved[#saved + 1] = { v = sv.kb, sec = sec or sv.name, db = db or "", entries = sv.entries }
    end
    FillList(v.saved, saved, function(row, it, frac)
        row.name:SetText(it.sec)
        row.name2:SetText(it.db)
        row.cells[1]:SetText(Fmt(it.v))
        row.cells[2]:SetText(tostring(it.entries))
        row.bar:Set(frac, { 0.56, 0.56, 0.6 })
    end)
    local se = P:Session()
    local r = v.rooms
    if se.rooms.loaded then
        r.pill:SetKind("loaded", "ok")
        r.line1:SetText(("%s, until a /reload"):format(Fmt(se.rooms.kb or 0)))
    else
        r.pill:SetKind("not loaded", "mute")
        r.line1:SetText("about 20 MB once a 3D view opens")
    end
    r.line2:SetText("DisasterZone_Rooms, a load-on-demand addon")
end

---------------------------------------------------------------------------
-- Network
---------------------------------------------------------------------------

-- What a prefix carries, by its class in Core/Comm.lua (Comm.CLASS_BY_PREFIX); CDLp1-4: in-game updates.
local CLASS_WHAT = { ctrl = "control", data = "data", alert = "alerts", game = "games", member = "member cards",
                     live = "live strategy boards", walk = "3D walking", run = "dungeon runs", event = "events",
                     eventmsg = "event messages", map = "guild map", craft = "crafting", craftev = "crafting news",
                     fb = "feedback" }
local function PrefixWhat(prefix)
    local Comm = ns.Comm
    local cls = Comm and Comm.CLASS_BY_PREFIX and Comm.CLASS_BY_PREFIX[prefix]
    if cls then return CLASS_WHAT[cls] or cls end
    if tostring(prefix):match("^CDLp%d$") then return "in-game updates" end
    return "another addon's"
end

local function CreateNetwork(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    local c = Box(v, PAD, BODY_Y, LEFT_W, BODY_H, "Addon messages")
    v.msgs = c
    c.big = {}
    for i, def in ipairs({ { "INV_Letter_15", "In" }, { "INV_Letter_02", "Out" } }) do
        local x = 12 + (i - 1) * 236
        local ic = Icon(c, 32)
        ic:SetPoint("TOPLEFT", x, -42)
        ic.tex:SetTexture(ICON(def[1]))
        local n = Text(c, 19, C.white, true)
        n:SetPoint("TOPLEFT", x + 42, -40)
        local sub = Text(c, 10, C.grey)
        sub:SetPoint("TOPLEFT", x + 42, -64)
        c.big[i] = { n = n, sub = sub, label = def[2] }
    end
    HLine(c, -92)
    c.cols = { 256, 314, 394, 460 }
    local hd = Text(c, 10, C.cap)
    hd:SetPoint("TOPLEFT", 12, -100)
    hd:SetText("Prefix")
    for i, t in ipairs({ "in / min", "KB", "out / min", "KB" }) do Cell(c, c.cols[i], -100, 70, 10, C.cap):SetText(t) end
    c.rows = {}
    for i = 1, 5 do
        local r = CreateFrame("Frame", nil, c)
        r:SetSize(LEFT_W - 2, 32)
        r:SetPoint("TOPLEFT", 1, -116 - (i - 1) * 32)
        r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
        r.rule:SetHeight(1)
        r.rule:SetPoint("TOPLEFT")
        r.rule:SetPoint("TOPRIGHT")
        r.p = Text(r, 12, { 1, 0.75, 0.54 }, true)
        r.p:SetPoint("TOPLEFT", 12, -3)
        r.what = Text(r, 10, C.dim)
        r.what:SetPoint("TOPLEFT", 12, -18)
        r.cells = {}
        for j, x in ipairs(c.cols) do r.cells[j] = Cell(r, x - 1, -9, 70, 12, j % 2 == 1 and C.white or { 0.66, 0.66, 0.7 }) end
        c.rows[i] = r
    end
    HLine(c, -288)
    c.ctl = Text(c, 12, C.text)
    c.ctl:SetPoint("TOPLEFT", 12, -298)
    c.ctl:SetText("ChatThrottleLib")
    c.ctlPill = Pill(c)
    c.ctlPill:SetPoint("LEFT", c.ctl, "RIGHT", 10, 0)
    c.ctl1 = Text(c, 10, C.grey)
    c.ctl1:SetPoint("TOPLEFT", 12, -318)
    c.ctl1:SetWidth(LEFT_W - 24)
    c.ctl2 = Text(c, 10, C.grey)
    c.ctl2:SetPoint("TOPLEFT", 12, -334)
    c.ctl2:SetWidth(LEFT_W - 24)
    c.ctl3 = Text(c, 10, C.dim)
    c.ctl3:SetPoint("TOPLEFT", 12, -358)
    c.ctl3:SetWidth(LEFT_W - 24)
    c.empty = Text(c, 11, C.dim, false, "CENTER")
    c.empty:SetPoint("TOPLEFT", 10, -160)
    c.empty:SetWidth(LEFT_W - 20)
    -- who sends the most
    local s = Box(v, PAD + LEFT_W + GAP, BODY_Y, RIGHT_W, BODY_H, "Who sends the most")
    v.who = s
    Cell(s, RIGHT_W - 60, -38, 80, 10, C.cap):SetText("msgs / min")
    Cell(s, RIGHT_W - 12, -38, 40, 10, C.cap):SetText("KB")
    s.rows = {}
    for i = 1, 11 do
        local r = CreateFrame("Frame", nil, s)
        r:SetSize(RIGHT_W - 2, 29)
        r:SetPoint("TOPLEFT", 1, -52 - (i - 1) * 29)
        r.rule = Rect(r, { 1, 1, 1, 0.045 }, "BORDER")
        r.rule:SetHeight(1)
        r.rule:SetPoint("TOPLEFT")
        r.rule:SetPoint("TOPRIGHT")
        r.face = RoundIcon(r, 17)
        r.face:SetPoint("LEFT", 8, 1)
        r.name = Text(r, 12, C.text)
        r.name:SetPoint("TOPLEFT", 34, -6)
        r.name:SetWidth(RIGHT_W - 34 - 112)
        r.n = Cell(r, RIGHT_W - 60, -7, 70, 12, C.text)
        r.kb = Cell(r, RIGHT_W - 12, -7, 40, 12, { 0.6, 0.6, 0.64 })
        r.bar = Bar(r, RIGHT_W - 34 - 120, 2)
        r.bar:SetPoint("BOTTOMLEFT", 34, 4)
        s.rows[i] = r
    end
    s.empty = Text(s, 11, C.dim, false, "CENTER")
    s.empty:SetPoint("TOPLEFT", 10, -80)
    s.empty:SetWidth(RIGHT_W - 20)
    return v
end

local function FillNetwork(p)
    local v, P = p.views.network, Perf()
    local n = P:Network()
    local mins = max(1, n.span) / 60
    local c = v.msgs
    c.note:SetText(P.net.last and "the last minute" or ("the first %d s"):format(floor(n.span)))
    local inN, inB, outN, outB = 0, 0, 0, 0
    for _, x in ipairs(n.prefixes) do inN, inB, outN, outB = inN + x.inN, inB + x.inB, outN + x.outN, outB + x.outB end
    local big = { { inN, inB }, { outN, outB } }
    for i, b in ipairs(c.big) do
        b.n:SetText(("%.1f / s"):format(big[i][1] / mins / 60))
        b.sub:SetText(("%s · %s / min"):format(b.label, Fmt(big[i][2] / 1024 / mins)))
    end
    for i, r in ipairs(c.rows) do
        local x = n.prefixes[i]
        if x then
            r.p:SetText(x.prefix)
            r.what:SetText(PrefixWhat(x.prefix))
            local vals = { ("%.1f"):format(x.inN / mins), ("%.1f"):format(x.inB / 1024 / mins), ("%.1f"):format(x.outN / mins),
                           ("%.1f"):format(x.outB / 1024 / mins) }
            for j, fs in ipairs(r.cells) do fs:SetText(vals[j]) end
            r:Show()
        else
            r:Hide()
        end
    end
    c.empty:SetShown(#n.prefixes == 0)
    c.empty:SetText("No addon messages yet.")
    local t = P:Throttle()
    if t.max then
        c.ctlPill:SetKind(t.queueing and "queueing" or "no queue", t.queueing and "warn" or "ok")
        c.ctlPill:Show()
        local own = P.ctlOwnVersion and t.version == P.ctlOwnVersion
        c.ctl1:SetText(("%d B a second · %s ready now · %s waiting from DisasterZone"):format(t.max,
            Fmt((t.avail or 0) / 1024), Fmt((t.backlog or 0) / 1024)))
        c.ctl2:SetText(own and "The copy at work is DisasterZone's version." or "Another addon's copy is at work.")
    else
        c.ctlPill:Hide()
        c.ctl1:SetText("not loaded")
        c.ctl2:SetText("")
    end
    c.ctl3:SetText(("Dropped this session: %d (too large, not from the guild, or unreadable)"):format(t.dropped or 0))
    -- who sends the most
    local s = v.who
    local maxN = n.senders[1] and n.senders[1].inN or 1
    for i, r in ipairs(s.rows) do
        local x = n.senders[i]
        if x then
            r.face:SetClassOf(x.who)
            r.name:SetText(x.who:match("^([^%-]+)") or x.who)
            r.n:SetText(("%.0f"):format(x.inN / mins))
            r.kb:SetText(("%.1f"):format(x.inB / 1024 / mins))
            r.bar:Set(x.inN / max(1, maxN), { 1, 0.6, 0.4 })
            r:Show()
        else
            r:Hide()
        end
    end
    s.empty:SetShown(#n.senders == 0)
    s.empty:SetText("Nobody has sent anything yet.")
end

---------------------------------------------------------------------------
-- CPU
---------------------------------------------------------------------------

local function CreateCPU(p)
    local v = CreateFrame("Frame", nil, p)
    v:SetAllPoints(p)
    local c = Box(v, PAD, BODY_Y, LEFT_W, 228, "CPU over the last hour")
    v.hour = c
    c.chart = Chart(c, 14, -54, LEFT_W - 28, 124)
    c.facts = {}
    for i, label in ipairs({ "Now", "This session", "Boss fights", "Slowest frame" }) do
        local n = Text(c, 15, C.white, true)
        n:SetPoint("TOPLEFT", 14 + (i - 1) * 118, -188)
        local cap = Text(c, 10, C.grey)
        cap:SetPoint("TOPLEFT", n, "BOTTOMLEFT", 0, -1)
        cap:SetText(label)
        c.facts[i] = n
    end
    local s = Box(v, PAD + LEFT_W + GAP, BODY_Y, RIGHT_W, 228, "Slow frames")
    v.slow = s
    s.sub = Text(s, 10, C.dim)
    s.sub:SetPoint("TOPLEFT", 12, -36)
    s.sub:SetText("frames DisasterZone took longer than")
    s.rows = {}
    for i = 1, 5 do
        local y = -56 - (i - 1) * 32
        local ms = Text(s, 12, C.text, true)
        ms:SetPoint("TOPLEFT", 12, y - 2)
        local bar = Bar(s, 150, 6)
        bar:SetPoint("TOPLEFT", 62, y - 6)
        local n = Cell(s, RIGHT_W - 12, y - 2, 60, 12, C.white)
        s.rows[i] = { ms = ms, bar = bar, n = n }
    end
    s.empty = Text(s, 11, C.dim, false, "CENTER")
    s.empty:SetPoint("TOPLEFT", 10, -100)
    s.empty:SetWidth(RIGHT_W - 20)
    local g = Box(v, PAD, BODY_Y - 228 - GAP, W, BODY_H - 228 - GAP, "Most CPU right now")
    v.top = g
    g.note:SetText("from the last Measure · milliseconds of each second")
    Link(g, "Garbage", function() PerfUI:SetTab("garbage") end)
    g.cols = { W - 136, W - 70, W - 12 }
    g.heads = Heads(g, -37, "Handler", { "ms / s", "calls / s", "worst ms" }, g.cols)
    g.rows = {}
    g.empty = Text(g, 11, C.dim, false, "CENTER")
    g.empty:SetPoint("TOPLEFT", 10, -80)
    g.empty:SetWidth(W - 20)
    return v
end

local function FillCPU(p)
    local v, P = p.views.cpu, Perf()
    local cpu = P:CPU()
    local values = {}
    for i, smp in ipairs(P.samples) do values[i] = smp.cpu or 0 end
    local c = v.hour
    c.chart:Set((cpu and not cpu.off) and values or {}, { color = C.cpu, unit = "ms", min = 0.5,
        empty = cpu and (cpu.off and "The addon profiler is turned off." or "No samples yet: one comes every 10 s.")
            or "This client has no addon profiler." })
    local function ms(x) return x and ("%.2f |cff8f8f95ms|r"):format(x) or "-" end
    local facts = { cpu and cpu.recent, cpu and cpu.session, cpu and cpu.boss, cpu and cpu.peak }
    for i, f in ipairs(c.facts) do f:SetText(ms(facts[i])) end
    local s = v.slow
    local over = cpu and cpu.over or {}
    local mx = 1
    for _, o in ipairs(over) do mx = max(mx, o.n) end
    for i, r in ipairs(s.rows) do
        local o = over[i]
        if o then
            r.ms:SetText(o.ms .. " ms")
            r.bar:Set(o.n / mx, o.ms >= 50 and C.red or (o.ms >= 10 and C.mem or C.cpu))
            r.n:SetText(tostring(o.n))
            r.ms:Show() r.bar:Show() r.n:Show()
        else
            r.ms:Hide() r.bar:Hide() r.n:Hide()
        end
    end
    s.sub:SetShown(#over > 0)
    s.empty:SetShown(#over == 0)
    s.empty:SetText(cpu and "The profiler gives no slow-frame counts here." or "This client has no addon profiler.")
    local g = v.top
    local rows = MeasuredRows(false)
    tsort(rows, function(a, b) return a.msS > b.msS end)
    local maxMs = rows[1] and rows[1].msS or 1
    for i = 1, 3 do
        local x = rows[i]
        local row = Pool(g.rows, i, function()
            local hr = HandlerRow(g, W - 2, 36, g.cols)
            hr:SetPoint("TOPLEFT", 1, -51 - (i - 1) * 36)
            hr:SetScript("OnClick", function(self) state.picked = self.data and self.data.key PerfUI:SetTab("garbage") end)
            return hr
        end)
        if x then
            row:Set({ kind = x.kind, name = x.name, sub = x.sub, frac = x.msS / max(0.001, maxMs), key = x.key,
                      cells = CpuCells(x) })
        else
            row:Hide()
        end
    end
    for _, h in pairs(g.heads) do h:SetShown(#rows > 0) end
    g.empty:SetShown(#rows == 0)
    g.empty:SetText("Measure 30 s to see which handlers take the most time.")
end

---------------------------------------------------------------------------
-- The page
---------------------------------------------------------------------------

local TABS = { { "overview", "Overview" }, { "garbage", "Garbage" }, { "memory", "Memory" }, { "network", "Network" },
               { "cpu", "CPU" } }
local FILL = { overview = FillOverview, garbage = FillGarbage, memory = FillMemory, network = FillNetwork, cpu = FillCPU }

function PerfUI:SetTab(key)
    if not FILL[key] then return end
    state.tab = key
    self:Refresh()
end

function PerfUI:Refresh()
    local p = panel
    if not (p and p:IsVisible()) then return end
    for k, t in pairs(p.tabs) do t:SetActive(k == state.tab) end
    for k, v in pairs(p.views) do v:SetShown(k == state.tab) end
    local on, elapsed, secs = Perf():IsMeasuring()
    if on then
        p.measure:SetText(("Measuring %d s"):format(max(0, floor(secs - elapsed + 0.5))))
        p.measure:SetEnabled(false)
    else
        -- (the addon's own icons: a stopwatch from art pack 7, else play)
        local icon = ns:HasAssets(7) and UI().ICON.stopwatch or UI().ICON.play
        p.measure:SetText(UI():AtlasIconText(icon, 13) .. "  " .. ("Measure %d s"):format(MEASURE_S))
        p.measure:SetEnabled(not (InCombatLockdown and InCombatLockdown()))
    end
    FillBanner(p)
    FILL[state.tab](p)
end

function PerfUI:CreatePanel(parent)
    if panel then return panel end
    local p = CreateFrame("Frame", nil, parent)
    p:SetAllPoints(parent)
    panel = p
    p.tabs = {}
    local prev
    for _, t in ipairs(TABS) do
        local key = t[1]
        local tab = UI():CreateUnderlineTab(p, t[2], function() PerfUI:SetTab(key) end, "page")
        if prev then tab:SetPoint("LEFT", prev, "RIGHT", 14, 0) else tab:SetPoint("TOPLEFT", PAD - 2, TAB_Y) end
        p.tabs[key] = tab
        prev = tab
    end
    p.measure = UI():CreateSleekButton(p, "Measure", 132, 24, function()
        if not Perf():Measure(MEASURE_S, function() PerfUI:Refresh() end) then
            ns:Print("Measure waits until you are out of combat, and runs one at a time.")
        end
        PerfUI:SetTab("garbage")
    end, "primary")
    p.measure:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, TAB_Y)
    p.clean = UI():CreateSleekButton(p, UI():AtlasIconText(UI().ICON.disenchant, 13) .. "  Clean up", 104, 24, function()
            Perf():CleanUp()
            PerfUI:Refresh()
        end)
    p.clean:SetPoint("RIGHT", p.measure, "LEFT", -8, 0)
    p.clean:HookScript("OnEnter", function(b)
        UI():SetTextTooltip(b, { "Clean up now", "A full garbage collection (the game pauses a moment): what is left is "
            .. "what DisasterZone really holds." }, "ANCHOR_BOTTOMLEFT")
    end)
    p.clean:HookScript("OnLeave", function() GameTooltip:Hide() end)
    p.banner = CreateBanner(p)
    p.views = { overview = CreateOverview(p), garbage = CreateGarbage(p), memory = CreateMemory(p),
                network = CreateNetwork(p), cpu = CreateCPU(p) }
    p:SetScript("OnShow", function()
        if p.ticker then p.ticker:Cancel() end
        p.ticker = C_Timer.NewTicker(2, function() PerfUI:Refresh() end)
    end)
    p:SetScript("OnHide", function()
        if p.ticker then p.ticker:Cancel() p.ticker = nil end
    end)
    function p:OnPanelShown() PerfUI:Refresh() end
    return p
end

PerfUI._panel = function() return panel end      -- (tests)
PerfUI._state = state

function PerfUI:OnLogin()
    if ns.Perf and ns.Perf.Start then ns.Perf:Start() end
end

function PerfUI:OnInit()
    if ns.MainFrame and ns.MainFrame.RegisterTab then
        ns.MainFrame:RegisterTab("perf", "Performance", 3.92, function(parent) return PerfUI:CreatePanel(parent) end,
            function() return ns.Perf and ns.Perf:IsOn() end)
    end
    ns:On("PERF_UPDATED", function() PerfUI:Refresh() end)
    if ns.Perf and ns.Perf:IsOn() then           -- (/dz perf: only where the page is, like the page)
        ns:RegisterSlash("perf", function() if ns.MainFrame then ns.MainFrame:Open("perf") end end,
            "open the Performance page (memory, garbage, CPU)")
    end
end

if DisasterZoneBoot and DisasterZoneBoot.Run("UI/PlateLooks.lua", ...) then return end -- DisasterZone UI/PlateLooks.lua
-- The nameplates' six looks (ns.PlateLooks), ported from the mockup's canvas code (claude.ai/artifact/
-- TxPbRME3GQ9ACQ88e74evf, built by dev/art/casc/nameplate_mockup) to the combat text's pen (UI/CombatTextPen.lua).
-- Each look: Geom(p) = how far the plate reaches left / right / up / down of its bar's middle (y down), Draw(c, p)
-- with (0, 0) on the bar's middle. A plate p (UI/Plates.lua) carries:
--   name, lvl ("??" or a number), boss, mark (raid mark 1-8), hp (0-1), col (the bar's colour), nameCol, glow (a
--   threat glow colour or nil), pulse (0.55-1), cast { spell, icon, prog (0-1), left (s), kick } or nil, auras
--   { icon, left, dur, start, stacks, mine }, target, combat, exec (the execute tick's line, 0-1, or nil), execReady,
--   execIcon, nameOnly (a friendly name, no bar).
-- Signatures (the user's mockup): Flat, the target a size bigger with a white edge; Halo, a ring of light, the mark in
-- a disc, debuffs as discs that run out; Sigil, gold brackets, a kickable cast in a pulsing gold frame; Slate, names
-- first and 2 px hairlines; Gilded, moulding, the target's filigree corners and a boss's gold wings; Classic, the
-- game's own nameplate pieces.
local addonName, ns = ...

local L = {}
ns.PlateLooks = L
local Pen = ns.CTPen

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local format, tostring, ipairs = string.format, tostring, ipairs
local pi = math.pi

local function C(r, g, b) return { r / 255, g / 255, b / 255 } end
local WHITE, BLACK = { 1, 1, 1 }, { 0, 0, 0 }
local GOLD = { 1, 0.82, 0 }
local DARK = C(10, 10, 14)
local KICK, NOKICK = C(255, 194, 61), C(128, 128, 140)
L.KICK, L.NOKICK = KICK, NOKICK
local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
local RAID = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local SBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local GILT = "Interface\\AddOns\\" .. addonName .. "\\Media\\Gilt\\"
local TT = "Interface\\Tooltips\\"
local BW = 118

---------------------------------------------------------------------------
-- Shared bits
---------------------------------------------------------------------------

local function Mark(c, i, cx, cy, sz)
    i = tonumber(i)
    if not i or i < 1 or i > 8 then return end
    local col, row = (i - 1) % 4, floor((i - 1) / 4)
    c:Img(RAID, cx, cy, sz, sz, nil, 1, col * 0.25, col * 0.25 + 0.25, row * 0.25, row * 0.25 + 0.25)
end
L.Mark = Mark

local function Edge(c, x, y, w, h, col, a)
    c:Rect(x, y, w, 1, col, a)
    c:Rect(x, y + h - 1, w, 1, col, a)
    c:Rect(x, y + 1, 1, h - 2, col, a)
    c:Rect(x + w - 1, y + 1, 1, h - 2, col, a)
end

-- An icon cut to w x h (its middle), top left at x, y.
local function IconAt(c, tex, x, y, w, h)
    if not tex then return end
    local v = 0.84 * min(1, h / w) / 2
    local u = 0.84 * min(1, w / h) / 2
    c:Img(tex, x + w / 2, y + h / 2, w, h, nil, 1, 0.5 - u, 0.5 + u, 0.5 - v, 0.5 + v)
end

local function Shade(col, k, add)
    add = add or 0
    return { min(1, col[1] * k + add), min(1, col[2] * k + add), min(1, col[3] * k + add) }
end

-- The piece of health just taken off (p.trail > p.hp): pale, behind the bar, until it drains.
local function Chunk(col) return { min(1, col[1] * 0.45 + 0.55), min(1, col[2] * 0.45 + 0.55), min(1, col[3] * 0.45 + 0.5) } end
L.Chunk = Chunk

-- (the number is the health now; only the bar slides)
local function Pct(p) return floor((p.hpTarget or p.hp or 0) * 100 + 0.5) .. "%" end
L.Pct = Pct

local function CastTime(p)
    local s = p.cast and p.cast.left or 0
    if s < 0 then s = 0 end
    return format("%.1f", s)
end

local function AuraTime(a)
    local s = a.left or 0
    if s >= 60 then return ceil(s / 60) .. "m" end
    if s >= 3 then return tostring(floor(s)) end
    if s <= 0 then return "" end
    return format("%.1f", s)
end
L.AuraTime = AuraTime

local function AuraLabel(c, a, cx, y, size)
    local s = AuraTime(a)
    if s ~= "" then c:Text(s, cx, y, "ArialN", size or 8.5, WHITE, 1) end
end

local function Stacks(c, a, x, y)
    if a.stacks and a.stacks > 1 then c:Text(tostring(a.stacks), x, y, "ArialN", 8.5, WHITE, 1, "RIGHT") end
end

-- A small padlock: a cast that can't be kicked.
local function Lock(c, x, y, col)
    c:Rect(x - 3, y - 1, 6, 5, col, 1)
    c:Rect(x - 2.2, y - 4.2, 1, 3.4, col, 1)
    c:Rect(x + 1.2, y - 4.2, 1, 3.4, col, 1)
    c:Rect(x - 2.2, y - 4.4, 4.4, 1, col, 1)
end

-- The level: a skull for "??", else the number (align LEFT / RIGHT / CENTER at x). Returns its width.
local function Level(c, p, x, y, align, size, col, skull)
    if p.lvl == "??" then
        local s = skull or 11
        local cx = (align == "RIGHT" and x - s / 2) or (align == "LEFT" and x + s / 2) or x
        c:Img(SKULL, cx, y, s, s)
        return s
    end
    if not p.lvl then return 0 end
    local t = tostring(p.lvl)
    c:Text(t, x, y, "ArialN", size, p.lvlCol or col, 1, align)   -- (the game's difficulty colour, feedback #50)
    return c:W("ArialN", size, t, 1)
end

-- The biggest of `size` .. 7 that fits `room` px.
local function Fit(c, font, size, s, room)
    while size > 7 and c:W(font, size, s, 1) > room do size = size - 0.5 end
    return size
end

-- Pulsing parts: alpha times the pulse while drawn.
local function Pulse(c, p, f)
    local a = c.a
    c.a = a * (0.6 + 0.4 * (p.pulse or 1))
    f()
    c.a = a
end

local NAMEONLY = { l = -56, r = 56, top = -8, bot = 6 }

local function NameOnlyGeom(p)
    local w = Pen.W(nil, "Friz", 11, p.name or "", 1) / 2 + 4
    return { l = -w, r = w, top = -8, bot = 6 }
end

---------------------------------------------------------------------------
-- Flat: dark 66% slabs, 1 px black edges, square icons. The target steps forward: a size bigger, a white edge.
---------------------------------------------------------------------------

local FLAT = { key = "flat" }
function FLAT.Geom(p)
    if p.nameOnly then return NameOnlyGeom(p) end
    local s = p.target and 1.1 or 1
    return { l = (-BW / 2 - 21) * s, r = (BW / 2 + (p.execReady and 24 or 0)) * s,
             top = (-5 - 13 - (#p.auras > 0 and 18 or 0)) * s, bot = (5 + (p.cast and 14 or 0)) * s }
end
function FLAT.Draw(c, p)
    if p.nameOnly then c:Text(p.name, 0, 0, "Friz", 11, p.nameCol, 1) return end
    local s = p.target and 1.1 or 1
    c:Push()
    c:Scale(s)
    local w, h = BW, 10
    local x0, y0 = -w / 2, -h / 2
    if p.glow then c:Glow(0, 0, w + 24, h + 16, p.glow, 0.75 * p.pulse) end
    c:Rect(x0, y0, w, h, DARK, 0.66)
    c:Rect(x0, y0, w, h, WHITE, 0.04)
    if p.trail then c:Rect(x0 + w * p.hp, y0, w * (p.trail - p.hp), h, Chunk(p.col), 0.75) end
    if p.hp > 0 then c:Rect(x0, y0, w * p.hp, h, p.col, 0.8) end
    if p.exec then c:Rect(x0 + w * p.exec - 0.5, y0, 1, h, WHITE, 0.6) end
    if p.target then Edge(c, x0 - 2, y0 - 2, w + 4, h + 4, BLACK, 1) end
    Edge(c, x0 - 1, y0 - 1, w + 2, h + 2, p.target and WHITE or BLACK, 1)
    c:Text(Pct(p), x0 + w - 3, 0.5, "ArialN", 9.5, p.execReady and GOLD or WHITE, 1, "RIGHT")
    local ny = y0 - 7.5
    local lw = Level(c, p, x0 + w, ny, "RIGHT", 9.5, C(201, 198, 211), 11)
    c:Text(p.name, x0, ny, "Friz", Fit(c, "Friz", 10, p.name, w - lw - 6), WHITE, 1, "LEFT")
    if p.mark then Mark(c, p.mark, x0 - 12, 0, 17) end
    if #p.auras > 0 then
        local ax, ay = x0, ny - 7 - 15
        for _, a in ipairs(p.auras) do
            c:Rect(ax - 1, ay - 1, 20, 16, BLACK, 1)
            IconAt(c, a.icon, ax, ay, 18, 14)
            if a.mine then Edge(c, ax - 1, ay - 1, 20, 16, WHITE, 0.9) end
            AuraLabel(c, a, ax + 9, ay + 10)
            Stacks(c, a, ax + 18, ay + 3.5)
            ax = ax + 22
        end
    end
    if p.cast then
        local cy, ch = h / 2 + 3, 11
        local col = p.cast.kick and KICK or NOKICK
        c:Rect(x0, cy, w, ch, DARK, 0.66)
        IconAt(c, p.cast.icon, x0, cy, ch, ch)
        c:Rect(x0 + ch + 1, cy, (w - ch - 1) * p.cast.prog, ch, col, 0.74)
        Edge(c, x0 - 1, cy - 1, w + 2, ch + 2, BLACK, 1)
        local tt = CastTime(p)
        local room = w - ch - 8 - c:W("ArialN", 9, tt, 1) - (p.cast.kick and 0 or 12)
        c:Text(p.cast.spell, x0 + ch + 4, cy + ch / 2 + 0.5, "ArialN", Fit(c, "ArialN", 9, p.cast.spell, room), WHITE, 1, "LEFT")
        c:Text(tt, x0 + w - 3, cy + ch / 2 + 0.5, "ArialN", 9, WHITE, 1, "RIGHT")
        if not p.cast.kick then Lock(c, x0 + w - 6 - c:W("ArialN", 9, tt, 1) - 6, cy + ch / 2 + 0.5, C(228, 226, 234)) end
    end
    if p.execReady then
        Pulse(c, p, function()
            c:Rect(x0 + w + 5, y0 - 4, 18, 18, BLACK, 1)
            IconAt(c, p.execIcon, x0 + w + 6, y0 - 3, 16, 16)
            Edge(c, x0 + w + 5, y0 - 4, 18, 18, GOLD, 1)
        end)
    end
    c:Pop()
end

---------------------------------------------------------------------------
-- Halo: pills with a soft fade, round discs in thin rings. A ring of light round the target.
---------------------------------------------------------------------------

local RINGC = C(245, 220, 143)
local DIMRING = C(70, 70, 82)

-- A solid pill (left L, middle y) shading from col0 at its left to col1 at its right. (Solid: a see-through start
-- let the dark track show at the plate's left end, read in game as a cut-off background.)
local function FadePill(c, L0, y, w, h, col0, col1)
    if w <= h or not (Pen.Smooth and Pen.Smooth()) then c:Pill(L0, y, max(w, h), h, col1, 1) return end
    local e, tex, u = h / 2, Pen.PEN .. "pill", 32 / 256
    c:Img(tex, L0 + e / 2, y, e, h, col0, 1, 0, u, 0, 1)
    c:Grad(L0 + e, y - h / 2, w - 2 * e, h, "H", col0, 1, col1, 1)
    c:Img(tex, L0 + w - e / 2, y, e, h, col1, 1, 1 - u, 1, 0, 1)
end

-- A bar piece from xa (square) to xb (round), middle on y 0, h high.
local function RightRound(c, xa, xb, h, col, a)
    if xb - xa <= 0.5 then return end
    if not (Pen.Smooth and Pen.Smooth()) then c:Rect(xa, -h / 2, xb - xa, h, col, a) return end
    local e = h / 2
    local ce = min(e, xb - xa)
    if xb - xa > e then c:Rect(xa, -h / 2, xb - xa - e, h, col, a) end
    c:Img(Pen.PEN .. "pill", xb - ce / 2, 0, ce, h, col, a, 1 - (32 / 256) * (ce / e), 1, 0, 1)
end

local HALO = { key = "halo" }
function HALO.Geom(p)
    if p.nameOnly then local g = NameOnlyGeom(p); g.l, g.r, g.top, g.bot = g.l - 9, g.r + 9, -9, 7 return g end
    return { l = -72, r = 58 + (p.execReady and 23 or 0), top = -6 - 14 - (p.target and 3 or 0) - (#p.auras > 0 and 22 or 0),
             bot = 6 + (p.cast and (4 + 6 + 14) or 0) }
end
function HALO.Draw(c, p)
    if p.nameOnly then
        local nw = c:W("Friz", 11, p.name, 1) + 18
        c:Pill(-nw / 2, 0, nw, 16, C(8, 8, 11), 0.55)
        c:Text(p.name, 0, 0.5, "Friz", 11, p.nameCol, 1)
        return
    end
    local w, h = 116, 12
    local x0, y0 = -w / 2, -h / 2
    if p.glow then c:Glow(0, 0, w + 26, h + 18, p.glow, 0.75 * p.pulse) end
    if p.target then c:Pill(x0 - 3.5, 0, w + 7, h + 7, WHITE, 0.95, true) end
    -- (the fill nearly solid: a faint start let the dark track show at the ends, read as a dark box edge in game)
    -- (nothing under the fill: a dimmed plate draws every piece see-through, WoW fades each region on its own, so
    -- a rim or track under the fill showed through as dark hard-looking ends. The track and the chunk only cover
    -- what the fill doesn't, from under its round end.)
    local fw = w * p.hp
    local fend = (p.hp > 0) and (x0 + max(fw, h)) or x0
    if p.hp <= 0 then c:Pill(x0, 0, w, h, DARK, 0.85)
    elseif fend < x0 + w - 0.5 then
        local from = fend - h / 2
        if p.trail then
            local tend = min(x0 + w, x0 + w * p.trail)
            RightRound(c, from, tend, h, Chunk(p.col), 0.75)
            from = max(from, tend - h / 2)
        end
        RightRound(c, from, x0 + w, h, DARK, 0.85)
    end
    if p.hp > 0 then FadePill(c, x0, 0, fw, h, Shade(p.col, 0.62), p.col) end
    if p.exec then c:Rect(x0 + w * p.exec - 0.5, y0 + 2, 1, h - 4, WHITE, 0.55) end
    c:Text(Pct(p), x0 + w - 6, 0.5, "ArialN", 9.5, p.execReady and GOLD or WHITE, 1, "RIGHT")
    local ny = y0 - (p.target and 12 or 9)
    local nsize = Fit(c, "Friz", 10.5, p.name, w - 14)
    c:Text(p.name, 0, ny, "Friz", nsize, RINGC, 1)
    if p.lvl == "??" then c:Img(SKULL, c:W("Friz", nsize, p.name, 1) / 2 + 9.5, ny, 11, 11)
    elseif p.lvlCol then c:Text(tostring(p.lvl), c:W("Friz", nsize, p.name, 1) / 2 + 5, ny + 0.5, "ArialN", 9.5, p.lvlCol, 1, "LEFT") end
    if p.mark then
        local cx = x0 - 3
        c:Disc(cx, 0, 11, C(8, 8, 11), 0.96)
        c:Ring(cx, 0, 11, 1.2, RINGC, 0.95)
        Mark(c, p.mark, cx, 0, 14)
    end
    local n = #p.auras
    if n > 0 then
        local d, gap = 18, 6
        local ax, ay = -(n * d + (n - 1) * gap) / 2 + d / 2, ny - 7 - 13
        for _, a in ipairs(p.auras) do
            c:Icon(a.icon, ax, ay, d, "round", DIMRING)
            if a.start and a.dur and a.dur > 0 then c:Sweep(ax, ay, d / 2 + 0.4, 1.3, a.mine and RINGC or C(190, 190, 200), 1, a.start, a.dur)
            else c:Ring(ax, ay, d / 2 + 0.4, 1.2, a.mine and RINGC or C(190, 190, 200), 0.95) end
            AuraLabel(c, a, ax, ay + 0.5, 9)
            if a.stacks and a.stacks > 1 then
                c:Disc(ax + 7, ay + 7, 5, GOLD, 1)
                c:Ring(ax + 7, ay + 7, 5, 1, BLACK, 1)
                c:Text(tostring(a.stacks), ax + 7, ay + 7.5, "ArialN", 8, C(17, 17, 17), 0)
            end
            ax = ax + d + gap
        end
    end
    if p.cast then
        local ch = 6
        local cy = h / 2 + 4 + ch / 2
        local col = p.cast.kick and KICK or NOKICK
        c:Pill(x0 - 1, cy, w + 2, ch + 2, BLACK, 0.9)
        c:Pill(x0, cy, w, ch, DARK, 0.94)
        if p.cast.prog > 0 then c:Pill(x0, cy, max(ch, w * p.cast.prog), ch, col, 0.95) end
        local ty = cy + ch / 2 + 8
        local tt = CastTime(p)
        local fs = Fit(c, "Friz", 9, p.cast.spell, w - 20)
        local sw, tsw = c:W("Friz", fs, p.cast.spell, 1), c:W("ArialN", 9.5, tt, 1)
        local tx = -(sw + 5 + tsw + (p.cast.kick and 0 or 12)) / 2
        if not p.cast.kick then Lock(c, tx + 3, ty + 0.5, C(201, 198, 211)); tx = tx + 12 end
        c:Text(p.cast.spell, tx, ty, "Friz", fs, p.cast.kick and C(255, 231, 166) or C(201, 198, 211), 1, "LEFT")
        c:Text(tt, tx + sw + 5, ty + 0.5, "ArialN", 9.5, C(162, 159, 174), 1, "LEFT")
    end
    if p.execReady then
        Pulse(c, p, function() c:Icon(p.execIcon, x0 + w + 14, 0, 18, "round", GOLD) end)
    end
end

---------------------------------------------------------------------------
-- Sigil: framed tiles, bars with a lit top edge, small caps in gold. Brackets box the target in.
---------------------------------------------------------------------------

local TILE_IN = C(18, 18, 21)
local function Tile(c, x, y, w, h, rim, a)
    c:Rect(x, y, w, h, BLACK, 1)
    c:Rect(x + 1, y + 1, w - 2, h - 2, TILE_IN, 1)
    Edge(c, x + 1, y + 1, w - 2, h - 2, rim, a)
end
local function LitBar(c, x, y, w, h, frac, col, trail)
    c:Rect(x - 1, y - 1, w + 2, h + 2, BLACK, 1)
    c:Rect(x, y, w, h, TILE_IN, 1)
    if trail and trail > frac then c:Rect(x + w * frac, y, w * (trail - frac), h, Chunk(col), 0.75) end
    if frac > 0 then
        c:Grad(x, y, w * frac, h, "V", Shade(col, 1.12, 0.08), 1, Shade(col, 0.62), 1)
        c:Rect(x, y, w * frac, 1, WHITE, 0.35)
    end
    Edge(c, x, y, w, h, WHITE, 0.07)
end

local SIGIL = { key = "sigil" }
function SIGIL.Geom(p)
    if p.nameOnly then return NameOnlyGeom(p) end
    return { l = -80, r = 78 + (p.execReady and 20 or 0), top = -5.5 - 12 - (#p.auras > 0 and 19 or 0),
             bot = 6.5 + (p.cast and 12 or 0) }
end
function SIGIL.Draw(c, p)
    if p.nameOnly then c:Text(p.name:upper(), 0, 0, "Friz", 9.5, p.nameCol, 1) return end
    local w, h = BW, 11
    local x0, y0 = -w / 2, -h / 2
    if p.glow then c:Glow(0, 0, w + 24, h + 16, p.glow, 0.75 * p.pulse) end
    LitBar(c, x0, y0, w, h, p.hp, p.col, p.trail)
    if p.exec then c:Rect(x0 + w * p.exec - 0.5, y0, 1, h, GOLD, 0.8) end
    c:Text(Pct(p), x0 + w - 3, 0.5, "ArialN", 9.5, p.execReady and GOLD or WHITE, 1, "RIGHT")
    Tile(c, x0 + w + 2, y0 - 1, 13, 13, GOLD, 0.75)
    Level(c, p, x0 + w + 8.5, 0.5, "CENTER", 9, GOLD, 9)
    if p.mark then Tile(c, x0 - 17, y0 - 1, 14, 13, GOLD, 0.75); Mark(c, p.mark, x0 - 10, 0.5, 11) end
    local ny = y0 - 7
    local nm = p.name:upper()
    c:Text(nm, x0, ny, "Friz", Fit(c, "Friz", 8.5, nm, w + 14), GOLD, 1, "LEFT")
    if #p.auras > 0 then
        local ax, ay = x0, ny - 6 - 16
        for _, a in ipairs(p.auras) do
            c:Rect(ax, ay, 20, 16, BLACK, 1)
            IconAt(c, a.icon, ax + 1, ay + 1, 18, 14)
            Edge(c, ax + 1, ay + 1, 18, 14, a.mine and GOLD or WHITE, a.mine and 0.8 or 0.2)
            AuraLabel(c, a, ax + 10, ay + 11)
            Stacks(c, a, ax + 18.5, ay + 4.5)
            ax = ax + 22
        end
    end
    if p.cast then
        local cy, ch = y0 + h + 3, 9
        LitBar(c, x0, cy, w, ch, p.cast.prog, p.cast.kick and C(255, 186, 40) or C(118, 122, 136))
        Tile(c, x0 - 17, cy - 1, 14, 11, p.cast.kick and GOLD or WHITE, p.cast.kick and 0.75 or 0.2)
        IconAt(c, p.cast.icon, x0 - 15, cy + 1, 10, 7)
        local tt = CastTime(p)
        local room = w - 10 - c:W("ArialN", 8.5, tt, 1) - (p.cast.kick and 0 or 12)
        c:Text(p.cast.spell, x0 + 3, cy + ch / 2 + 0.5, "ArialN", Fit(c, "ArialN", 8.5, p.cast.spell, room), WHITE, 1, "LEFT")
        c:Text(tt, x0 + w - 3, cy + ch / 2 + 0.5, "ArialN", 8.5, WHITE, 1, "RIGHT")
        if p.cast.kick then
            Edge(c, x0 - 2, cy - 2, w + 4, ch + 4, GOLD, 0.45 + 0.55 * (p.pulse or 1))
        else
            Lock(c, x0 + w - 6 - c:W("ArialN", 8.5, tt, 1) - 6, cy + ch / 2 + 0.5, C(228, 226, 234))
        end
    end
    if p.execReady then
        Pulse(c, p, function() Tile(c, x0 + w + 18, y0 - 4, 18, 18, GOLD, 0.9); IconAt(c, p.execIcon, x0 + w + 20, y0 - 2, 14, 14) end)
    end
    if p.target then
        local g = SIGIL.Geom(p)
        local Lx, Rx, T, B, a = x0 - 21, x0 + w + 19 + (p.execReady and 20 or 0), g.top - 4, g.bot + 3, 7
        for _, q in ipairs({ { Lx, T, 1, 1 }, { Rx, T, -1, 1 }, { Lx, B, 1, -1 }, { Rx, B, -1, -1 } }) do
            local x, y, sx, sy = q[1], q[2], q[3], q[4]
            c:Rect(sx > 0 and x or x - a, sy > 0 and y or y - 2, a, 2, GOLD, 1)
            c:Rect(sx > 0 and x or x - 2, sy > 0 and y or y - a, 2, a, GOLD, 1)
        end
    end
end

---------------------------------------------------------------------------
-- Slate: text first. Names in colour, 2 px hairlines that show in combat, casts as words.
---------------------------------------------------------------------------

local SUBT = C(236, 233, 225)
local SLATE = { key = "slate" }
local function SlateBar(p) return not p.nameOnly and (p.combat or p.target) end

-- The name row's parts and width: mark, », name, %, the finisher's icon, «.
local parts = {}
local function SlateParts(p)
    local bar = SlateBar(p)
    local size = p.target and 12 or 11
    local n = 0
    local function add(q) n = n + 1; parts[n] = q end
    if p.mark then add({ mark = p.mark, w = 13 }) end
    if p.target then add({ t = "»", size = size, col = WHITE }) end
    if p.lvlCol then add({ t = tostring(p.lvl), font = "ArialN", size = 10, col = p.lvlCol }) end
    add({ t = p.name, size = size, col = p.nameCol, name = true })
    if bar then add({ t = Pct(p), font = "ArialN", size = 10, col = p.execReady and GOLD or SUBT, a = p.execReady and 1 or 0.62 }) end
    if p.execReady then add({ icon = p.execIcon, w = 11 }) end
    if p.target then add({ t = "«", size = size, col = WHITE }) end
    local tot = 0
    for i = 1, n do
        local q = parts[i]
        if q.t then q.font = q.font or "Friz"; q.w = Pen.W(nil, q.font, q.size, q.t, 1) end
        tot = tot + q.w
    end
    for i = n + 1, #parts do parts[i] = nil end
    return parts, n, tot + 5 * (n - 1)
end

function SLATE.Geom(p)
    local bar = SlateBar(p)
    local _, _, tot = SlateParts(p)
    local half = max(52, tot / 2 + 2)
    return { l = -half, r = half, top = -18 - ((bar and #p.auras > 0) and 15 or 0),
             bot = (bar and 3 or -2) + (p.cast and 18 or 0) }
end
function SLATE.Draw(c, p)
    local bar = SlateBar(p)
    local ny = bar and (p.target and -11 or -10) or -4
    local list, n, tot = SlateParts(p)
    local x = -tot / 2
    for i = 1, n do
        local q = list[i]
        if q.mark then Mark(c, q.mark, x + 6, ny, 12)
        elseif q.icon then Pulse(c, p, function() IconAt(c, q.icon, x, ny - 5.5, 11, 11) end)
        else
            local a0 = c.a
            if q.a then c.a = a0 * q.a end
            c:Text(q.t, x, ny + 0.5, q.font, q.size, q.col, 1, "LEFT", q.name and p.glow or nil, p.pulse)
            c.a = a0
        end
        x = x + q.w + 5
    end
    if bar then
        local w, hh = 100, p.target and 3 or 2
        local x0 = -w / 2
        c:Rect(x0, -hh / 2, w, hh, WHITE, 0.1)
        if p.trail then c:Rect(x0 + w * p.hp, -hh / 2, w * (p.trail - p.hp), hh, Chunk(p.col), 0.8) end
        if p.hp > 0 then c:Rect(x0, -hh / 2, w * p.hp, hh, p.col, 1) end
        if p.exec then c:Rect(x0 + w * p.exec - 0.5, -2.5, 1, 5, WHITE, 0.55) end
        if #p.auras > 0 then
            local items, t2 = {}, 0
            for i, a in ipairs(p.auras) do
                local s = AuraTime(a)
                local iw = 12 + 3 + c:W("ArialN", 9, s, 1) + ((a.stacks and a.stacks > 1) and 14 or 0)
                items[i] = { a = a, s = s, w = iw }
                t2 = t2 + iw
            end
            t2 = t2 + 8 * (#items - 1)
            local ax, ay = -t2 / 2, ny - 15
            for _, q in ipairs(items) do
                IconAt(c, q.a.icon, ax, ay - 6, 12, 12)
                local a0 = c.a
                c.a = a0 * (q.a.mine and 1 or 0.6)
                c:Text(q.s, ax + 15, ay + 0.5, "ArialN", 9, q.a.mine and WHITE or SUBT, 1, "LEFT")
                if q.a.stacks and q.a.stacks > 1 then c:Text("x" .. q.a.stacks, ax + q.w, ay + 0.5, "ArialN", 8.5, SUBT, 1, "RIGHT") end
                c.a = a0
                ax = ax + q.w + 8
            end
        end
    end
    if p.cast then
        local ty = (bar and 3 or 0) + 7
        local col = p.cast.kick and KICK or NOKICK
        local tt = CastTime(p)
        local fs = Fit(c, "Friz", 9.5, p.cast.spell, 120)
        local sw, tsw = c:W("Friz", fs, p.cast.spell, 1), c:W("ArialN", 9.5, tt, 1)
        local tx = -(sw + 5 + tsw + (p.cast.kick and 0 or 11)) / 2
        if not p.cast.kick then Lock(c, tx + 3, ty + 0.5, col); tx = tx + 11 end
        c:Text(p.cast.spell, tx, ty, "Friz", fs, p.cast.kick and C(255, 210, 122) or C(180, 179, 191), 1, "LEFT")
        local a0 = c.a
        c.a = a0 * 0.6
        c:Text(tt, tx + sw + 5, ty + 0.5, "ArialN", 9.5, SUBT, 1, "LEFT")
        c.a = a0
        c:Rect(-50, ty + 7, 100, 1.5, WHITE, 0.1)
        if p.cast.prog > 0 then c:Rect(-50, ty + 7, 100 * p.cast.prog, 1.5, col, 1) end
    end
end

---------------------------------------------------------------------------
-- Gilded: the status bar's grain in gold moulding, bezels. The target's corners light up; bosses wear gold wings.
---------------------------------------------------------------------------

local GNAME, GDARK = C(255, 215, 107), C(30, 18, 4)
-- Gilded's moulding round (x0, y0, w, h), t px thick (its art repeats every 4t px), as Look:Gilt draws it.
local function Trim(c, x0, y0, w, h, t, col, a)
    local u = (w + 2 * t) / (4 * t)
    local v = h / (4 * t)
    c:Tile(GILT .. "trim_h", x0 - t, y0 - t, w + 2 * t, t, 0, u, 0, 1, col, a)
    c:Tile(GILT .. "trim_h", x0 - t, y0 + h, w + 2 * t, t, 0, u, 1, 0, col, a)
    c:Tile(GILT .. "trim_v", x0 - t, y0, t, h, 0, 1, 0, v, col, a)
    c:Tile(GILT .. "trim_v", x0 + w, y0, t, h, 1, 0, 0, v, col, a)
end
local function Corners(c, x0, y0, w, h, t, s)
    local o = t + 1
    local CO = { { x0 - o, y0 - o, 0, 1, 0, 1 }, { x0 + w + o - s, y0 - o, 1, 0, 0, 1 },
                 { x0 - o, y0 + h + o - s, 0, 1, 1, 0 }, { x0 + w + o - s, y0 + h + o - s, 1, 0, 1, 0 } }
    for _, q in ipairs(CO) do c:Img(GILT .. "corner", q[1] + s / 2, q[2] + s / 2, s, s, nil, 1, q[3], q[4], q[5], q[6]) end
end
local function Bezel(c, cx, cy, s, fill)
    c:Rect(cx - s / 2 + 1, cy - s / 2 + 1, s - 2, s - 2, BLACK, 1)
    local ins = s * 0.14
    fill(cx - s / 2 + ins, cy - s / 2 + ins, s - 2 * ins)
    c:Img(GILT .. "bezel", cx, cy, s, s)
end
local function Grain(c, x0, y0, w, h, frac, col)
    if frac > 0 then c:Img(SBAR, x0 + w * frac / 2, y0 + h / 2, w * frac, h, col, 1, 0, frac, 0, 1) end
end

local GILDED = { key = "gilded" }
function GILDED.Geom(p)
    if p.nameOnly then return NameOnlyGeom(p) end
    return { l = -78, r = p.execReady and 100 or 78, top = -5 - 3 - 8 - 8 - (#p.auras > 0 and 22 or 0),
             bot = 5 + 3 + (p.cast and (5 + 7 + 2 + 13) or 0) }
end
function GILDED.Draw(c, p)
    if p.nameOnly then c:Text(p.name, 0, 0, "Friz", 11, p.nameCol, 1) return end
    local w, h, t = 112, 10, 3
    local x0, y0 = -w / 2, -h / 2
    if p.glow then c:Glow(0, 0, w + 26, h + 18, p.glow, 0.75 * p.pulse) end
    c:Rect(x0, y0, w, h, BLACK, 0.62)
    if p.trail then c:Rect(x0 + w * p.hp, y0, w * (p.trail - p.hp), h, Chunk(p.col), 0.7) end
    Grain(c, x0, y0, w, h, p.hp, p.col)
    if p.exec then c:Rect(x0 + w * p.exec - 0.5, y0, 1, h, GNAME, 0.85) end
    Trim(c, x0, y0, w, h, t)
    if p.target then Corners(c, x0, y0, w, h, t, 11) end
    c:Text(Pct(p), x0 + w - 3, 0.5, "ArialN", 9.5, p.execReady and GOLD or WHITE, 1, "RIGHT")
    Bezel(c, x0 + w + t + 10, 0, 18, function(x, y, s)
        c:Rect(x, y, s, s, C(20, 13, 4), 1)
        Level(c, p, x + s / 2, y + s / 2 + 0.5, "CENTER", 9, GNAME, s - 2)
    end)
    if p.mark then
        Bezel(c, x0 - t - 10, 0, 18, function(x, y, s) c:Rect(x, y, s, s, C(20, 13, 4), 1); Mark(c, p.mark, x + s / 2, y + s / 2, s) end)
    end
    local ny = y0 - t - 8
    local nsize = Fit(c, "Friz", 10.5, p.name, w - (p.boss and 36 or 4))
    c:Text(p.name, 0, ny, "Friz", nsize, GNAME, 1)
    if p.boss then
        local nw = c:W("Friz", nsize, p.name, 1) / 2 + 6
        for _, sx in ipairs({ -1, 1 }) do
            c:Rect(sx > 0 and nw - 1 or -nw - 15, ny - 1.5, 16, 3, GDARK, 0.9)
            c:Grad(sx > 0 and nw or -nw - 14, ny - 0.5, 14, 1, "H", GNAME, sx > 0 and 0.95 or 0, GNAME, sx > 0 and 0 or 0.95)
            c:Img(Pen.WHITE, sx * nw, ny, 6, 6, GDARK, 0.95, 0, 1, 0, 1, pi / 4)
            c:Img(Pen.WHITE, sx * nw, ny, 4, 4, GNAME, 1, 0, 1, 0, 1, pi / 4)
        end
    end
    local n = #p.auras
    if n > 0 then
        local s, gap = 19, 4
        local ax, ay = -(n * s + (n - 1) * gap) / 2, ny - 8 - s
        for _, a in ipairs(p.auras) do
            Bezel(c, ax + s / 2, ay + s / 2, s, function(x, y, q) IconAt(c, a.icon, x, y, q, q) end)
            if not a.mine then c:Rect(ax + 2, ay + 2, s - 4, s - 4, BLACK, 0.28) end
            AuraLabel(c, a, ax + s / 2, ay + s - 4)
            Stacks(c, a, ax + s - 2.5, ay + 5)
            ax = ax + s + gap
        end
    end
    if p.cast then
        local cy, ch, kt = y0 + h + t + 5, 7, 2
        local col = p.cast.kick and C(255, 176, 52) or C(140, 134, 124)
        c:Rect(x0, cy, w, ch, BLACK, 0.62)
        Grain(c, x0, cy, w, ch, p.cast.prog, col)
        Trim(c, x0, cy, w, ch, kt, (not p.cast.kick) and C(150, 150, 160) or nil)
        Bezel(c, x0 - kt - 9, cy + ch / 2, 15, function(x, y, q) IconAt(c, p.cast.icon, x, y, q, q) end)
        local ty = cy + ch + kt + 7
        local tt = CastTime(p)
        local fs = Fit(c, "Friz", 9, p.cast.spell, w - 20)
        local sw, tsw = c:W("Friz", fs, p.cast.spell, 1), c:W("ArialN", 9.5, tt, 1)
        local tx = -(sw + 5 + tsw + (p.cast.kick and 0 or 11)) / 2
        if not p.cast.kick then Lock(c, tx + 3, ty + 0.5, C(184, 176, 160)); tx = tx + 11 end
        c:Text(p.cast.spell, tx, ty, "Friz", fs, p.cast.kick and C(243, 220, 160) or C(184, 176, 160), 1, "LEFT")
        c:Text(tt, tx + sw + 5, ty + 0.5, "ArialN", 9.5, C(191, 169, 121), 1, "LEFT")
    end
    if p.execReady then
        Pulse(c, p, function() Bezel(c, x0 + w + t + 31, 0, 20, function(x, y, q) IconAt(c, p.execIcon, x, y, q, q) end) end)
    end
end

---------------------------------------------------------------------------
-- Classic: the game's own nameplate pieces (border, level box, elite dragon, cast bar, shield) with ours added.
-- In Nameplate-Border (128 x 32) the bar's inside is x 5 .. 104, y 19 .. 27 and the level box's middle 114.5, 23;
-- in Nameplate-CastBar the bar is x 21 .. 123, y 11 .. 19 and the icon's recess 6, 9 (12 px); the shield's bar
-- starts at 23 and its icon square at 5, 5 (13 px). The bar's middle is (0, 0): the border's top left is -64, -23.
---------------------------------------------------------------------------

local CLASSIC = { key = "classic" }
function CLASSIC.Geom(p)
    if p.nameOnly then return NameOnlyGeom(p) end
    local r = p.boss and 102 or 64
    if p.execReady then r = 100 + (p.boss and 14 or 0) end
    return { l = -80, r = r, top = -4 - 12 - 6 - (#p.auras > 0 and 19 or 0), bot = 8 + (p.cast and 16 or 0) }
end
function CLASSIC.Draw(c, p)
    if p.nameOnly then c:Text(p.name, 0, 0, "Friz", 11, p.nameCol, 1) return end
    local bx, by = -64, -23
    local fx, fy, fw, fh = bx + 5, by + 19, 99, 8
    if p.glow then c:Glow(bx + 64, 0, 150, 26, p.glow, 0.75 * p.pulse) end
    c:Rect(fx, fy, fw, fh, BLACK, 0.7)
    if p.trail then c:Rect(fx + fw * p.hp, fy, fw * (p.trail - p.hp), fh, Chunk(p.col), 0.7) end
    Grain(c, fx, fy, fw, fh, p.hp, p.col)
    if p.exec then c:Rect(fx + fw * p.exec - 0.5, fy, 1, fh, GOLD, 0.9) end
    c:Text(Pct(p), fx + fw - 3, fy + fh / 2 + 0.5, "ArialN", 8.5, p.execReady and GOLD or WHITE, 1, "RIGHT")
    c:Img(TT .. "Nameplate-Border", bx + 64, by + 16, 128, 32)
    if p.boss then c:Img(TT .. "EliteNameplateIcon", bx + 134, by + 25, 64, 32) end
    Level(c, p, bx + 114.5, by + 23.5, "CENTER", 10, GOLD, 12)
    if p.mark then Mark(c, p.mark, bx - 7, 0, 18) end
    local ny = by + 11
    c:Text(p.name, fx + fw / 2, ny, "Friz", Fit(c, "Friz", 10, p.name, 120), p.target and GOLD or WHITE, 1)
    if #p.auras > 0 then
        local ax, ay = fx, ny - 7 - 17
        for _, a in ipairs(p.auras) do
            c:Rect(ax, ay, 17, 17, BLACK, 1)
            IconAt(c, a.icon, ax + 1, ay + 1, 15, 15)
            Edge(c, ax, ay, 17, 17, a.mine and GOLD or C(204, 0, 0), 0.85)
            AuraLabel(c, a, ax + 8.5, ay + 13)
            Stacks(c, a, ax + 16, ay + 4.5)
            ax = ax + 19
        end
    end
    if p.cast then
        local cx, cy = bx, by + 27
        local spell = p.cast.spell
        if p.cast.kick then
            c:Rect(cx + 21, cy + 11, 102, 8, BLACK, 0.7)
            Grain(c, cx + 21, cy + 11, 102, 8, p.cast.prog, { 1, 0.7, 0 })
            c:Img(TT .. "Nameplate-CastBar", cx + 64, cy + 16, 128, 32)
            IconAt(c, p.cast.icon, cx + 6, cy + 9, 12, 12)
        else
            c:Rect(cx + 23, cy + 11, 99, 8, BLACK, 0.7)
            Grain(c, cx + 23, cy + 11, 99, 8, p.cast.prog, { 0.6, 0.6, 0.6 })
            c:Img(TT .. "Nameplate-CastBar-Shield", cx + 64, cy + 16, 128, 32)
            IconAt(c, p.cast.icon, cx + 5, cy + 5, 13, 13)
        end
        c:Text(spell, cx + 72, cy + 15.5, "ArialN", Fit(c, "ArialN", 8.5, spell, 96), WHITE, 1)
    end
    if p.execReady then
        Pulse(c, p, function()
            local ix = bx + 132 + (p.boss and 14 or 0)
            c:Rect(ix, -9, 18, 18, BLACK, 1)
            IconAt(c, p.execIcon, ix + 1, -8, 16, 16)
            Edge(c, ix, -9, 18, 18, GOLD, 1)
        end)
    end
end

L.flat, L.halo, L.sigil, L.slate, L.gilded, L.classic = FLAT, HALO, SIGIL, SLATE, GILDED, CLASSIC
L.ORDER = { "flat", "halo", "sigil", "slate", "gilded", "classic" }
L.BW = BW

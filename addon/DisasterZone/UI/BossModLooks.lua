if DisasterZoneBoot and DisasterZoneBoot.Run("UI/BossModLooks.lua", ...) then return end -- DisasterZone UI/BossModLooks.lua
-- The boss mods' six looks (ns.BossModLooks), ported from the mockup (claude.ai/artifact/66LY12B41hTyqt7e8GEXEM;
-- dev/art/casc/bossmod_mockup/bossmods_template.html) with the combat text's pen (UI/CombatTextPen.lua), so they
-- look and move as shown there. Coordinates are the mockup's px (a 540 px tall screen), local to the spot each part
-- is drawn in (UI/BossModUI.lua): a bar from its top left, a warning from its centre, the countdown and the range
-- frame from their centres, the "on you" effects on the whole screen.
--   flat    the soon lane: a bar's last 5 s leaves the stack and moves under the warnings, tall and red
--   halo    countdown rings: a bar's last 5 s is its round icon in a ring that runs out, under the warnings
--   sigil   stamped warnings: they slam down, shake once and gold corners close on them; five pips count down
--   slate   text first: hairlines, no icons; the range frame is a list of who is too close
--   gilded  gold work: trimmed bars, warnings in a cartouche, the range frame a gilded compass
--   classic the game's own: cast bars that fill, raid warnings, the big countdown digits, the minimap's raid blips
-- Each look: bar(c, b, x, y, w, h, soon, t), warn(c, w, x, y, a, life), you(c, a, sw, sh), count(c, n, k, x, y),
-- range(c, R, a, x, y); ring(c, b, x, y, k) for Halo's soon ring. Numbers: barH, gap, soonLane / soonRing,
-- soonExtra, soonBelow.
local addonName, ns = ...

local BL = {}
ns.BossModLooks = BL
local Pen = ns.CTPen
local C, Mix, clamp = Pen.C, Pen.Mix, Pen.clamp
local K = ns.CombatTextLooks.kit
local Edge, tile, stamp, sigTag, brackets = K.Edge, K.tile, K.stamp, K.sigTag, K.brackets
local trimH, cartouche, easeOut, easeIn = K.trimH, K.cartouche, K.easeOut, K.easeIn
local GP = ns.CombatTextLooks.GP

local floor, max, min, abs, cos, sin, ceil = math.floor, math.max, math.min, math.abs, math.cos, math.sin, math.ceil
local pi = math.pi
local TAU = pi * 2
local ipairs = ipairs

local W, BLACK, GOLD = C("#ffffff"), C("#000000"), C("#ffd100")
local CHIP = C("#0a0a0d")
local SBAR = "Interface\\TargetingFrame\\UI-StatusBar"
local CASTB = "Interface\\CastingBar\\UI-CastingBar-Border"
local SPARK = "Interface\\CastingBar\\UI-CastingBar-Spark"
local TIPEDGE = "Interface\\Tooltips\\UI-Tooltip-Border"
local BLIPS = "Interface\\Minimap\\PartyRaidBlips"
local BIGNUM = "Interface\\Timer\\BigTimerNumbers"
BL.ART = { SBAR, CASTB, SPARK, TIPEDGE, BLIPS, BIGNUM }

local CLS = { WARRIOR = C("#c79c6e"), PALADIN = C("#f58cba"), HUNTER = C("#abd473"), ROGUE = C("#fff569"),
              PRIEST = C("#ffffff"), SHAMAN = C("#0070de"), MAGE = C("#69ccf0"), WARLOCK = C("#9482c9"),
              DRUID = C("#ff7d0a") }
BL.CLS = CLS
local BLIP = { WARRIOR = 0, PALADIN = 1, HUNTER = 2, ROGUE = 3, PRIEST = 4, SHAMAN = 6, MAGE = 7, WARLOCK = 8, DRUID = 10 }

-- The time on a bar: m:ss, whole seconds, tenths under 10; inside a window "<n" (it comes within n s).
local function T(b)
    if b.win then return "<" .. ceil(b.win) end
    local r = b.rem
    if r >= 60 then return floor(r / 60) .. ":" .. string.format("%02d", floor(r % 60)) end
    if r >= 10 then return tostring(floor(r)) end
    return string.format("%.1f", r)
end
BL.TimeText = T
local function Frac(b)
    if b.win then return 0 end
    return clamp(b.rem / b.total)
end
BL.Frac = Frac
local function RoleWord(r) return r == "T" and "tank" or "healer" end

-- A meArrow (the player on a radar).
local function Arrow(c, x, y, col)
    c:Tri(x, y - 6, x + 4.5, y + 5, x, y + 2.5, col, 1)
    c:Tri(x, y - 6, x, y + 2.5, x - 4.5, y + 5, col, 1)
end

-- A pill (rounded both ends): its left edge L, middle y, width w, height h (one smooth capsule; its outline).
local function Pill(c, L, y, w, h, col, a) c:Pill(L, y, w, h, col, a) end
local function PillLine(c, L, y, w, h, col, a) c:Pill(L, y, w, h, col, a, true) end

-- The dots a range frame draws: R.dots { x, y (yd, north up, from me), cls, close, n, d }; R.n too close.
local function DotsIn(R, scale, maxr)
    return function(fn)
        for _, d in ipairs(R.dots or {}) do
            local dx, dy = d.x * scale, d.y * scale
            local r = (dx * dx + dy * dy) ^ 0.5
            if r <= maxr then fn(d, dx, dy) end
        end
    end
end

-- A range frame without positions (the game hid them): the list of who is too close, nearest first.
local LGREY, LRED, LGREEN = C("#b9b6c4"), C("#ff6a5e"), C("#5fe05a")
local function RangeList(c, R, x, y, w, font)
    font = font or "ArialN"
    local n = 0
    for _, d in ipairs(R.near or {}) do
        n = n + 1
        if n > 5 then break end
        local ly = y + (n - 1) * 20
        c:Text(d.n, x, ly, font, 13, CLS[d.cls] or W, 1, "LEFT")
        if d.d then c:Text(floor(d.d + 0.5) .. " yd", x + w, ly, font, 13, W, 1, "RIGHT") end
    end
    if n == 0 then c:Text("Nobody within " .. R.yd .. " yd", x, y, font, 13, LGREY, 1, "LEFT") end
end
BL.RangeList = RangeList

---------------------------------------------------------------------------
-- Flat (today's look): the soon lane
---------------------------------------------------------------------------

local FLAT = { barH = 20, gap = 3, soonLane = { h = 30, gap = 5, w = 300 } }
BL.flat = FLAT
local FC = { cd = C("#4f86c8"), pull = C("#3fae4f"), ["break"] = C("#6f7e95"), wave = C("#9a6fd0"), soon = C("#d9472f"),
             win = C("#e0902f") }
local FWARN = { you = C("#ff5a4a"), warn = C("#ffb347"), info = W }
local FSUB = C("#b9b6c4")
local function KindCol(P, b, soon)
    if b.win then return P.win or P.soon end
    if soon then return P.soon end
    return P[b.kind or "cd"] or P.cd
end

function FLAT.bar(c, b, x, y, w, h, soon, t)
    local frac, col = Frac(b), KindCol(FC, b, soon)
    if b.win then frac = 0.35 + 0.25 * abs(sin(t * 5)) end
    c:Rect(x, y, w, h, CHIP, 0.66)
    c:Rect(x + h, y, (w - h) * frac, h, col, 1)
    c:Rect(x + h, y, (w - h) * frac, 1, W, 0.08)
    Edge(c, x, y, w, h, BLACK, 1)
    c:Icon(b.icon, x + h / 2, y + h / 2, h - 2, "sq")
    local fs = soon and 15 or 12
    c:Text(b.text, x + h + 7, y + h / 2 + 1, "Friz", fs, W, 1, "LEFT")
    c:Text(T(b), x + w - 6, y + h / 2 + 1, "ArialN", soon and 19 or 14, W, 1, "RIGHT")
    if b.role then
        local tx = x + h + 11 + c:W("Friz", fs, b.text, 1)
        c:Rect(tx, y + h / 2 - 6, 13, 12, BLACK, 0.55)
        Edge(c, tx, y + h / 2 - 6, 13, 12, W, 0.35)
        c:Text(b.role, tx + 6.5, y + h / 2 + 0.5, "Friz", 9, C("#e6e3ee"), 0)
    end
end

function FLAT.warn(c, w, x, y, a)
    local col = FWARN[w.kind] or W
    local bw = max(c:W("Friz", 22, w.text, 1), w.sub and c:W("Friz", 13, w.sub, 0) or 0) + 64
    local bh = w.sub and 50 or 36
    c:Rect(x - bw / 2, y - 18, bw, bh, CHIP, 0.66)
    if w.kind == "you" then Edge(c, x - bw / 2, y - 18, bw, bh, FWARN.you, 0.45 + 0.55 * abs(sin(a * 6)))
    else Edge(c, x - bw / 2, y - 18, bw, bh, BLACK, 1) end
    c:Icon(w.icon, x - bw / 2 + 21, y + (w.sub and 7 or 0), 26, "sq")
    c:Text(w.text, x - bw / 2 + 40, y, "Friz", 22, col, 1, "LEFT")
    if w.sub then c:Text(w.sub, x - bw / 2 + 40, y + 21, "Friz", 13, FSUB, 0, "LEFT") end
end

local RED = C("#ff3c32")
function FLAT.you(c, a, sw, sh)
    local k = 0.9 * abs(sin(a * pi * 1.6)) * clamp(1 - (a - 2) / 0.5)
    if k <= 0 then return end
    c:Rect(0, 0, sw, 3, RED, k); c:Rect(0, sh - 3, sw, 3, RED, k)
    c:Rect(0, 0, 3, sh, RED, k); c:Rect(sw - 3, 0, 3, sh, RED, k)
end

function FLAT.count(c, n, k, x, y)
    local sc = 1 + 0.5 * (1 - easeOut(k / 0.18))
    c.a = c.a * clamp((1 - k) / 0.25)
    c:Text(tostring(n), x, y, "ArialN", 76 * sc, W, 2)
end

local RGRID = C("#ffffff")
function FLAT.range(c, R, a, cx0, cy0)
    local s, hh = 164, 22
    local x, y = cx0 - s / 2, cy0 - s / 2
    c:Rect(x, y, s, s, CHIP, 0.66)
    Edge(c, x, y, s, s, BLACK, 1)
    c:Rect(x + 1, y + hh, s - 2, 1, W, 0.06)
    c:Text("Range · " .. R.yd .. " yd", x + 8, y + 12, "ArialN", 13, W, 0, "LEFT")
    c:Text(R.n > 0 and (R.n .. " too close") or "Clear", x + s - 8, y + 12, "ArialN", 13, R.n > 0 and LRED or LGREEN, 0, "RIGHT")
    if R.noPos then RangeList(c, R, x + 10, y + hh + 14, s - 20) return end
    local cx, cy, px = cx0, y + hh + (s - hh) / 2, 46 / R.yd
    c:Line(cx, y + hh + 2, cx, y + s - 2, 1, RGRID, 0.07)
    c:Line(x + 2, cy, x + s - 2, cy, 1, RGRID, 0.07)
    c:Ring(cx, cy, R.yd * px, 1, R.n > 0 and LRED or W, R.n > 0 and 0.75 or 0.35)
    DotsIn(R, px, (s - hh) / 2 - 9)(function(d, dx, dy)
        c:Rect(cx + dx - 3, cy + dy - 3, 6, 6, BLACK, 1)
        c:Rect(cx + dx - 2, cy + dy - 2, 4, 4, CLS[d.cls] or W, 1)
        if d.close then Edge(c, cx + dx - 4.5, cy + dy - 4.5, 9, 9, FWARN.you, 1) end
    end)
    Arrow(c, cx, cy, W)
end

---------------------------------------------------------------------------
-- Halo: countdown rings
---------------------------------------------------------------------------

local HALO = { barH = 22, gap = 5, soonRing = true }
BL.halo = HALO
-- (solid fills in calm colours on a see-through track: no fades to black)
local HC = { cd = C("#3f78c8"), pull = C("#3aa653"), ["break"] = C("#6b7a92"), wave = C("#8a62d0"), soon = C("#dc5a38"),
             win = C("#e08a2c") }
local HWARN = { you = C("#c8322a"), warn = C("#c87a1e"), info = C("#4a5a78") }
local HDARK = C("#0b0c10")
local HRING = C("#ffb26e")
local HPALE = C("#efe7d6")
local HGOLD = C("#ffe6a8")
local HRIP = C("#ff8a70")

-- A bar: the round icon in its gold ring, a capsule track you can see through, a solid fill with a light top edge.
function HALO.bar(c, b, x, y, w, h, soon, t)
    local frac, col = Frac(b), KindCol(HC, b, soon)
    local fa = 0.9
    if b.win then frac, fa = 1, 0.55 + 0.35 * abs(sin(t * 5)) end
    local L, cy, ph = x + h / 2, y + h / 2, h - 6
    local bw = w - h / 2
    Pill(c, L, cy, bw, ph, HDARK, 0.5)
    PillLine(c, L, cy, bw, ph, W, 0.08)
    local fw = bw * frac
    if fw > 0.5 then
        fw = max(fw, ph)
        Pill(c, L, cy, fw, ph, col, fa)
        if fw > ph then c:Rect(L + ph / 2, cy - ph / 2 + 1, fw - ph, 1, W, 0.22) end
    end
    c:Icon(b.icon, x + h / 2, cy, h, "round")
    local tt = T(b)
    local tw = c:W("Friz", 13, tt, 0)
    c:Text(b.text, x + h + 9, cy + 1, "Friz", 12, W, 0, "LEFT")
    c:Text(tt, x + w - 10, cy + 1, "Friz", 13, W, 0, "RIGHT")
    if b.role then
        local rx = x + w - 10 - tw - 11
        c:Disc(rx, cy, 6.5, GOLD, 1)
        c:Text(b.role, rx, cy + 0.5, "ArialN", 9, BLACK, 0)
    end
end

-- The last 5 s: the round icon in a ring that runs out (the game's own sweep: smooth), the tenths in it, the name
-- under it.
function HALO.ring(c, b, x, y, k)
    local r = 26
    c.a = c.a * easeOut(k / 0.25)
    c:Icon(b.icon, x, y, 2 * r - 8, "round", BLACK)
    c:Disc(x, y, r - 4, BLACK, 0.42)
    c:Ring(x, y, r, 3, W, 0.12)
    local start, dur = b.lo - 5, 5
    if b.win then start, dur = b.lo, b.hi - b.lo end
    c:Sweep(x, y, r, 3, HRING, 1, start, dur, true)
    c:Text(b.win and T(b) or string.format("%.1f", b.rem), x, y + 1, "Friz", 17, W, 1)
    c:Text(b.text, x, y + r + 13, "Friz", 11, HPALE, 1)
end

-- A warning: a solid capsule in its colour (red on you, amber for everyone, slate for news), the round icon at its
-- left end; on you, outlines ripple out of it.
function HALO.warn(c, w, x, y, a)
    local col = HWARN[w.kind] or HWARN.info
    local h = 34
    local bw = c:W("Friz", 20, w.text, 0) + h + 30
    local L = x - bw / 2
    Pill(c, L, y, bw, h, col, 0.92)
    c:Rect(L + h / 2, y - h / 2 + 1, bw - h, 1, W, 0.25)
    PillLine(c, L, y, bw, h, BLACK, 0.35)
    c:Icon(w.icon, L + h / 2, y, h - 6, "round", BLACK)
    c:Text(w.text, L + h + 8, y + 1, "Friz", 20, W, 0, "LEFT")
    if w.sub then c:Text(w.sub, x, y + h / 2 + 12, "Friz", 12, HPALE, 1) end
    if w.kind == "you" then
        local a0 = c.a
        for _, d in ipairs({ 0, 0.45 }) do
            local k = ((a + d) % 0.9) / 0.9
            c.a = a0 * (1 - k) * 0.8
            PillLine(c, L - 12 * k, y, bw + 24 * k, h + 16 * k, HRIP, 1)
        end
        c.a = a0
    end
end

-- On you: rings spread on the ground round you.
function HALO.you(c, a, sw, sh)
    if a > 2.6 then return end
    local x, y = sw / 2, sh * 0.62
    local a0 = c.a
    for _, d in ipairs({ 0, 0.4, 0.8 }) do
        local k = ((a + d) % 1.2) / 1.2
        local R = 20 + 60 * k
        c.a = a0 * (1 - k) * 0.9
        c:Ring(x, y, R, 4, C("#ff6a50"), 1, nil, R * 0.32)
    end
    c.a = a0
end

-- The pull countdown: the number in a ring that runs out each second.
function HALO.count(c, n, k, x, y)
    local r = 46
    c.a = c.a * clamp((1 - k) / 0.2) * easeOut(k / 0.1)
    c:Disc(x, y, r, HDARK, 0.45)
    c:Ring(x, y, r, 3, W, 0.1)
    c:Sweep(x, y, r, 3, HGOLD, 1, GetTime() - k, 1, true)
    c:Text(tostring(n), x, y + 2, "Friz", 50, W, 1)
end

function HALO.range(c, R, a, cx, cy0)
    local r, cy = 64, cy0 - 6
    c:Disc(cx, cy, r, HDARK, 0.55)
    c:Ring(cx, cy, r, 1.5, C("#f5dc8f"), 0.85)
    local label = R.n > 0 and (R.n .. " too close") or "Clear"
    if R.noPos then
        RangeList(c, R, cx - 48, cy - 34, 96, "Friz")
    else
        local px = 46 / R.yd
        local col = R.n > 0 and C("#ff6a50") or HGOLD
        c:Ring(cx, cy, R.yd * px, 1.5, col, 0.8, true)
        if R.n > 0 then
            local k = (a % 1.1) / 1.1
            local a0 = c.a
            c.a = a0 * (1 - k) * 0.6
            c:Ring(cx, cy, R.yd * px * (0.4 + 0.6 * k), 1.5, col, 1)
            c.a = a0
        end
        DotsIn(R, px, r - 5)(function(d, dx, dy)
            local dc = CLS[d.cls] or W
            c:Disc(cx + dx, cy + dy, 4.4, d.close and C("#ff5a3c") or BLACK, 0.9)
            c:Disc(cx + dx, cy + dy, 3.4, dc, 1)
        end)
        Arrow(c, cx, cy, C("#fff6d8"))
    end
    local lw = c:W("Friz", 12, label, 0) + 22
    Pill(c, cx - lw / 2, cy + r + 2, lw, 18, R.n > 0 and C("#a8241a") or C("#22743a"), 0.92)
    c:Text(label, cx, cy + r + 3, "Friz", 12, W, 0)
end

---------------------------------------------------------------------------
-- Sigil: stamped warnings, pips
---------------------------------------------------------------------------

local SIGIL = { barH = 22, gap = 6, soonExtra = 6, soonBelow = 10 }
BL.sigil = SIGIL
local SC_ = { cd = C("#4a83c9"), pull = C("#46b24f"), ["break"] = C("#77839a"), wave = C("#9a6fd0"), soon = C("#d84a2c"),
              win = C("#e0902f") }
local SWARN = { you = C("#ff5a4a"), warn = C("#ffb347"), info = W }
local SRED = C("#ff5a4a")
local SGREEN = C("#5fe05a")
local SPIPOFF = C("#ffffff")

function SIGIL.bar(c, b, x, y, w, h, soon, t)
    local frac, col = Frac(b), KindCol(SC_, b, soon)
    if b.win then frac = 0.35 + 0.25 * abs(sin(t * 5)) end
    local tx, tw = x + h + 4, w - h - 4
    tile(c, tx + tw / 2, y + h / 2, tw, h, soon and GOLD or nil, 0.85, soon and GOLD or W, soon and 0.5 or 0.22)
    local fx, fw = x + h + 6, (w - h - 8) * frac
    if fw > 0.5 then
        c:Grad(fx, y + 2, fw, (h - 4) / 2, "V", Mix(col, W, 0.25), 1, col, 1)
        c:Grad(fx, y + 2 + (h - 4) / 2, fw, (h - 4) / 2, "V", col, 1, Mix(col, BLACK, 0.35), 1)
        c:Rect(fx, y + 2, fw, 1, W, 0.35)
    end
    c:Icon(b.icon, x + h / 2, y + h / 2, h - 2, "framed")
    c:Text(b.text:upper(), x + h + 12, y + h / 2 + 1, "Friz", 10, W, 1, "LEFT")
    c:Text(T(b), x + w - 7, y + h / 2 + 1, "ArialN", 15, W, 1, "RIGHT")
    if b.role then sigTag(c, b.role == "T" and "TANK" or "HEAL", x + w - 46, y, 8) end
    if soon then
        local lit = b.win and 5 or ceil(b.rem)
        for i = 0, 4 do
            local px = x + h + 6 + i * 11
            c:Rect(px - 1, y + h + 3, 9, 6, BLACK, 1)
            c:Rect(px, y + h + 4, 7, 4, i < lit and GOLD or SPIPOFF, i < lit and 1 or 0.12)
        end
    end
end

function SIGIL.warn(c, w, x, y, a)
    local S = stamp(a)
    local col = SWARN[w.kind] or W
    c:Push()
    c:Translate(x + S.dx, y + S.dy)
    c:Scale(S.sc)
    c.a = c.a * S.a
    local bw, bh = c:W("Friz", 21, w.text, 1) + 72, 42
    local you = w.kind == "you"
    tile(c, 0, 0, bw, bh, you and SRED or GOLD, you and 0.9 or 0.55, you and SRED or GOLD, you and 0.6 or 0.35)
    c:Icon(w.icon, -bw / 2 + 22, 0, 26, "framed")
    c:Text(w.text, -bw / 2 + 44, 1, "Friz", 21, col, 1, "LEFT")
    if w.kind ~= "info" then sigTag(c, you and "ON YOU" or "WARNING", -bw / 2 + 34, -bh / 2, 8, BLACK, you and SRED or GOLD, 1, you and SRED or GOLD, 1) end
    if a > 0.08 then
        local k = easeOut((a - 0.08) / 0.25)
        local off = 14 * (1 - k)
        brackets(c, 0, 0, bw / 2 + 4 + off, bh / 2 + 4 + off, 12, you and SRED or GOLD, 0.95, 2)
    end
    if w.sub then c:Text(w.sub:upper(), 0, bh / 2 + 13, "Friz", 10, C("#d6d3df"), 1) end
    c:Pop()
end

function SIGIL.you(c, a, sw, sh)
    if a > 2.4 then return end
    local k = easeOut(a / 0.3)
    brackets(c, sw / 2, sh * 0.62, 50 - 18 * k, 26 - 8 * k, 10, SRED, 0.9 * clamp((2.4 - a) / 0.4), 2.5)
end

function SIGIL.count(c, n, k, x, y)
    local S = stamp(k, 2.2, 0.08)
    c:Push()
    c:Translate(x + S.dx, y + S.dy)
    c:Scale(S.sc)
    c.a = c.a * S.a * clamp((1 - k) / 0.2)
    tile(c, 0, 0, 80, 80, GOLD, 0.8, GOLD, 0.5)
    c:Text(tostring(n), 0, 3, "Friz", 54, W, 2)
    sigTag(c, "PULL", 0, -40, 8, BLACK, GOLD, 1, GOLD, 1)
    c:Pop()
end

function SIGIL.range(c, R, a, cx0, cy0)
    local s, hh = 150, 22
    local x, y = cx0 - s / 2, cy0 - s / 2
    local close = R.n > 0
    tile(c, cx0, cy0, s, s, close and SRED or nil, 0.7, close and SRED or W, close and 0.45 or 0.22)
    c:Text("RANGE · " .. R.yd .. " YD", x + 9, y + 12, "Friz", 10, W, 0, "LEFT")
    if R.noPos then
        RangeList(c, R, x + 10, y + hh + 14, s - 20)
    else
        local cx, cy, px = cx0, y + hh + (s - hh) / 2, 46 / R.yd
        for i = -4, 4 do
            local o = i * 5 * px
            if abs(o) < (s - hh) / 2 then
                c:Line(cx + o, y + hh, cx + o, y + s - 2, 1, W, 0.06)
                c:Line(x + 2, cy + o, x + s - 2, cy + o, 1, W, 0.06)
            end
        end
        local ring = R.yd * px
        brackets(c, cx, cy, ring, ring, 10, close and SRED or GOLD, close and 0.9 or 0.7, 1.5)
        c:Ring(cx, cy, ring, 1, close and SRED or GOLD, close and 0.35 or 0.25)
        DotsIn(R, px, (s - hh) / 2 - 9)(function(d, dx, dy)
            c:Rect(cx + dx - 3.5, cy + dy - 3.5, 7, 7, BLACK, 1)
            c:Rect(cx + dx - 2.5, cy + dy - 2.5, 5, 5, CLS[d.cls] or W, 1)
            if d.close then Edge(c, cx + dx - 5, cy + dy - 5, 10, 10, SRED, 1) end
        end)
        Arrow(c, cx, cy, GOLD)
    end
    if close then sigTag(c, R.n .. " TOO CLOSE", cx0, y + s, 8, BLACK, SRED, 1, SRED, 1)
    else sigTag(c, "CLEAR", cx0, y + s, 8, BLACK, SGREEN, 1, SGREEN, 1) end
end

---------------------------------------------------------------------------
-- Slate: text first
---------------------------------------------------------------------------

local SLATE = { barH = 26, gap = 2 }
BL.slate = SLATE
local SL = { name = C("#e8e6ee"), pull = C("#5fe05a"), wave = C("#b89cff"), red = C("#ff6a5e"), hair = C("#ffffff"),
             you = C("#ff6a5e"), warn = C("#ffc070"), sub = C("#b9b6c4") }

function SLATE.bar(c, b, x, y, w, h, soon, t)
    local nc = b.kind == "pull" and SL.pull or b.kind == "wave" and SL.wave or SL.name
    local fs = soon and 16 or 14
    c:Text(b.text, x, y + 9, "ArialN", fs, soon and W or nc, 1, "LEFT")
    if b.role then c:Text(RoleWord(b.role), x + c:W("ArialN", fs, b.text, 1) + 7, y + 9.5, "ArialN", 11, GOLD, 1, "LEFT") end
    c:Text(T(b), x + w, y + 9, "ArialN", soon and 18 or 15, (soon or b.win) and SL.red or W, 1, "RIGHT")
    c:Rect(x, y + 20, w, 2, SL.hair, 0.1)
    if b.win then
        c:Rect(x, y + 20, w, 2, SL.red, 0.4 + 0.4 * abs(sin(t * 5)))
    else
        c:Rect(x, y + 20, w * Frac(b), 2, soon and SL.red or SL.hair, soon and 1 or 0.5)
    end
end

function SLATE.warn(c, w, x, y, a, life)
    local col = w.kind == "you" and SL.you or w.kind == "warn" and SL.warn or W
    local ww = c:W("ArialN", 22, w.text, 1)
    c:Text(w.text, x, y, "ArialN", 22, col, 1)
    c:Rect(x - ww / 2, y + 15, ww, 2, SL.hair, 0.1)
    local hc = w.kind == "you" and C("#ff5a4a") or w.kind == "warn" and C("#ffb347") or SL.hair
    c:Rect(x - ww / 2, y + 15, ww * clamp(1 - a / (life or 3)), 2, hc, w.kind == "info" and 0.55 or 1)
    if w.sub then c:Text(w.sub, x, y + 30, "ArialN", 14, SL.sub, 1) end
end

function SLATE.you(c, a, sw, sh)
    if a < 2.4 then
        local a0 = c.a
        c.a = a0 * clamp((2.4 - a) / 0.4)
        c:Text("you", sw / 2, sh * 0.62 - 38, "ArialN", 13, SL.you, 1)
        c.a = a0
    end
end

function SLATE.count(c, n, k, x, y)
    c.a = c.a * clamp((1 - k) / 0.2) * easeOut(k / 0.1)
    c:Text(tostring(n), x, y - 6, "ArialN", 72, W, 1)
    c:Rect(x - 60, y + 34, 120, 2, SL.hair, 0.12)
    c:Rect(x - 60, y + 34, 120 * (1 - k), 2, SL.pull, 1)
    c:Text("pull", x, y + 50, "ArialN", 14, SL.sub, 1)
end

-- The range frame as a list: who is too close and how far, nearest first.
function SLATE.range(c, R, a, cx, cy)
    local x, y, w = cx - 82, cy - 66, 164
    c:Text(R.n > 0 and "Too close" or "Clear", x, y, "ArialN", 15, R.n > 0 and SL.red or SL.pull, 1, "LEFT")
    c:Text(R.yd .. " yd", x + w, y, "ArialN", 13, SL.sub, 1, "RIGHT")
    c:Rect(x, y + 11, w, 1, SL.hair, 0.18)
    local n = 0
    for _, d in ipairs(R.near or {}) do
        n = n + 1
        if n > 5 then break end
        local ly = y + 28 + (n - 1) * 22
        c:Text(d.n, x, ly, "ArialN", 14, CLS[d.cls] or W, 1, "LEFT")
        if d.d then
            c:Text(floor(d.d + 0.5) .. " yd", x + w, ly, "ArialN", 14, W, 1, "RIGHT")
            c:Rect(x, ly + 9, w, 2, SL.hair, 0.08)
            c:Rect(x, ly + 9, w * clamp(1 - d.d / R.yd), 2, C("#ff5a4a"), 0.8)
        end
    end
    if n == 0 then c:Text("Nobody within " .. R.yd .. " yd", x, y + 28, "ArialN", 14, SL.sub, 1, "LEFT") end
end

---------------------------------------------------------------------------
-- Gilded: gold work, the compass
---------------------------------------------------------------------------

local GILD = { barH = 22, gap = 9 }
BL.gilded = GILD
local GC = { cd = C("#c08a2a"), pull = C("#3f9a3a"), ["break"] = C("#6f7e95"), wave = C("#7b4fb8"), soon = C("#c8381f"),
             win = C("#e06a1f") }
local GBG1, GBG2 = C("#2b1f0b"), C("#0e0a05")
local GNAME = C("#f3e6c4")
local GPALE = C("#e9d6a0")
local GDARK = C("#1c1103")

function GILD.bar(c, b, x, y, w, h, soon, t)
    local frac, col = Frac(b), KindCol(GC, b, soon)
    if b.win then frac = 0.35 + 0.25 * abs(sin(t * 5)) end
    local L, bw = x + h + 5, w - h - 5
    c:Rect(L - 1, y - 1, bw + 2, h + 2, BLACK, 1)
    c:Grad(L, y, bw, h, "V", GBG1, 0.95, GBG2, 0.95)
    if frac > 0 then c:Img(SBAR, L + 2 + (bw - 4) * frac / 2, y + h / 2, (bw - 4) * frac, h - 6, col, 1, 0, frac, 0, 1) end
    trimH(c, L + 2, y - 3, bw - 4, 6)
    trimH(c, L + 2, y + h - 3, bw - 4, 6)
    c:Icon(b.icon, x + h / 2, y + h / 2, h + 4, "bezel")
    c:Text(b.text, L + 8, y + h / 2 + 1, "Friz", 12, GNAME, 1, "LEFT")
    local shine = soon and ((t * 0.9) % 1.4 - 0.2) or nil
    c:GText(T(b), L + bw - 8, y + h / 2 + 1, soon and 16 or 14, (soon or b.win) and GP.red or GP.gold, "Friz", "RIGHT", shine)
    if b.role then c:GText(b.role, L + 16 + c:W("Friz", 12, b.text, 1), y + h / 2 + 1, 11, GP.silver, "Friz", "LEFT") end
end

function GILD.warn(c, w, x, y, a)
    local pal = w.kind == "you" and GP.red or w.kind == "warn" and GP.gold or GP.silver
    local sc = a < 0.16 and (0.7 + 0.3 * easeOut(a / 0.16)) or 1
    c:Push()
    c:Translate(x, y + 4)
    c:Scale(sc)
    c.a = c.a * easeOut(a / 0.12)
    local bw = c:W("Morpheus", 26, w.text, 2) + 84
    local bh = w.sub and 58 or 44
    cartouche(c, 0, 0, bw, bh, 22)
    c:Icon(w.icon, -bw / 2 + 26, 0, 30, "bezel")
    c:GText(w.text, 18, w.sub and -8 or 1, 26, pal, "Morpheus", "CENTER", (a - 0.15) / 0.6)
    if w.sub then c:Text(w.sub, 18, 16, "Friz", 12, GPALE, 0) end
    c:Pop()
end

local VIGNETTE = "Interface\\FullScreenTextures\\LowHealth"
function GILD.you(c, a, sw, sh)
    if a > 2.6 then return end
    local a0 = c.a
    c.a = a0 * 0.5 * clamp((2.6 - a) / 0.5) * (0.6 + 0.4 * sin(a * 7))
    c:Img(VIGNETTE, sw / 2, sh / 2, sw, sh, C("#a8180a"), 1)
    c.a = a0
end

function GILD.count(c, n, k, x, y)
    c.a = c.a * clamp((1 - k) / 0.2) * easeOut(k / 0.1)
    local sc = 1 + 0.35 * (1 - easeOut(k / 0.2))
    c:GText(tostring(n), x, y, 84 * sc, GP.gold, "Morpheus", "CENTER", (k - 0.1) / 0.6)
end

local GRING1, GRING2 = C("#e3a42c"), C("#6e4a10")
local GTICK = C("#e3a42c")
local GDISC1, GDISC2 = C("#322610"), C("#100b05")
function GILD.range(c, R, a, cx, cy0)
    local r, cy = 64, cy0 - 8
    local close = R.n > 0
    c:Disc(cx, cy, r + 5, BLACK, 1)
    c:Disc(cx, cy, r, GDISC2, 0.96)
    c:Glow(cx, cy - 18, r * 1.6, r * 1.2, GDISC1, 0.9)
    c:Ring(cx, cy, r + 2, 5, GRING1, 1)
    c:Ring(cx, cy, r - 0.5, 1, GRING2, 0.8)
    c:Ring(cx, cy, r + 4.5, 1, GDARK, 1)
    for i = 0, 15 do
        local an, l = i * TAU / 16, (i % 4 == 0) and 8 or 4
        c:Line(cx + cos(an) * (r - 1), cy + sin(an) * (r - 1), cx + cos(an) * (r - 1 - l), cy + sin(an) * (r - 1 - l),
               (i % 4 == 0) and 1.6 or 1, GTICK, 0.7)
    end
    c:GText("N", cx, cy - r + 15, 11, GP.gold, "Friz", "CENTER")
    if R.noPos then
        RangeList(c, R, cx - 46, cy - 26, 92, "Friz")
    else
        local px = 46 / R.yd
        local ring = R.yd * px
        local col = close and C("#ff6f55") or C("#ffd65a")
        c:Ring(cx, cy, ring, 1.2, col, close and 0.9 or 0.7)     -- (the range engraved)
        DotsIn(R, px, r - 6)(function(d, dx, dy)
            local dc = CLS[d.cls] or W
            c:Disc(cx + dx, cy + dy, 4.6, close and d.close and C("#ff6f55") or GDARK, 1)
            c:Disc(cx + dx, cy + dy, 3.8, Mix(dc, BLACK, 0.35), 1)
            c:Disc(cx + dx - 0.8, cy + dy - 1, 2.2, dc, 1)
            c:Disc(cx + dx - 1.1, cy + dy - 1.4, 0.8, W, 0.9)
            if d.close then c:Ring(cx + dx, cy + dy, 6.5, 1, C("#ff6f55"), 0.5 + 0.5 * sin(a * 8)) end
        end)
        Arrow(c, cx, cy, C("#ffd65a"))
    end
    local label = close and (R.n .. " too close") or "Clear"
    local lw = c:W("Morpheus", 15, label, 2) + 34
    cartouche(c, cx, cy + r + 15, lw, 22, 12)
    c:GText(label, cx, cy + r + 16, 15, close and GP.red or GP.green, "Morpheus", "CENTER")
end

---------------------------------------------------------------------------
-- Classic: the game's own art
---------------------------------------------------------------------------

local CLASSIC = { barH = 26, gap = 8 }
BL.classic = CLASSIC
local CCOL = { cd = C("#ffb300"), pull = C("#00ff00"), ["break"] = C("#9cb4d8"), wave = C("#c890ff"), soon = C("#ff4020"),
               win = C("#ff8020") }
local CRW = C("#ff4709")          -- the raid warning colour
local CRED = C("#ff2020")
local CYEL = C("#ffd100")
local CGREEN = C("#20ff20")
local DARKBAR = C("#000000")

-- The cast bar border (256 x 64; the piece 24,14 .. 231,48: 12 px ends) stretched to w x h, the fill inside it.
local function CastBar(c, x, y, w, h, frac, col)
    local k = h / 34
    local e = 12 * k
    local fx, fy, fw, fh = x + 9 * k, y + 10 * k, w - 19 * k, 14 * k
    c:Rect(fx, fy, fw, fh, DARKBAR, 0.6)
    if frac > 0 then c:Img(SBAR, fx + fw * frac / 2, fy + fh / 2, fw * frac, fh, col, 1, 0, frac, 0, 1) end
    c:Img(CASTB, x + e / 2, y + h / 2, e, h, nil, 1, 24 / 256, 36 / 256, 14 / 64, 48 / 64)
    c:Img(CASTB, x + w / 2, y + h / 2, w - 2 * e, h, nil, 1, 36 / 256, 219 / 256, 14 / 64, 48 / 64)
    c:Img(CASTB, x + w - e / 2, y + h / 2, e, h, nil, 1, 219 / 256, 231 / 256, 14 / 64, 48 / 64)
    if frac > 0.02 and frac < 0.995 then
        local add = c.add
        c.add = true
        c:Img(SPARK, fx + fw * frac, fy + fh / 2, 16 * k, 28 * k)
        c.add = add
    end
end

function CLASSIC.bar(c, b, x, y, w, h, soon, t)
    -- (a cast bar that fills as the cast comes)
    local frac = b.win and (0.5 + 0.5 * abs(sin(t * 5))) or (1 - Frac(b))
    local ih = h - 4
    c:Rect(x - 1, y + 1, ih + 2, ih + 2, BLACK, 1)
    c:Icon(b.icon, x + ih / 2, y + 2 + ih / 2, ih, "sq")
    CastBar(c, x + ih + 4, y, w - ih - 4, h, frac, KindCol(CCOL, b, soon))
    local k = h / 34
    local name = b.text .. (b.role and (b.role == "T" and " (Tank)" or " (Healer)") or "")
    c:Text(name, x + ih + 4 + 14 * k, y + h / 2 + 0.5, "Friz", 11, W, 0, "LEFT")
    c:Text(T(b), x + w - 13 * k, y + h / 2 + 0.5, "Friz", 11, W, 0, "RIGHT")
end

-- The game's raid warning: big outlined text in the raid warning colour; on me, the proc glow round the spell.
local ALERT = "Interface\\SpellActivationOverlay\\IconAlert"
function CLASSIC.warn(c, w, x, y, a)
    local col = w.kind == "info" and CYEL or w.kind == "you" and CRED or CRW
    local sc = a < 0.12 and (1.3 - 0.3 * easeOut(a / 0.12)) or 1
    c:Push()
    c:Translate(x, y)
    c:Scale(sc)
    if w.kind == "you" then
        local ix = -c:W("Friz", 24, w.text, 1) / 2 - 30
        local gl = 34 * 1.75
        local a0 = c.a
        c.a = a0 * (0.55 + 0.45 * abs(sin(a * 5)))
        c:Img(ALERT, ix, 0, gl, gl, nil, 1, 3 / 128, 67 / 128, 71 / 256, 135 / 256)
        c.a = a0
        c:Icon(w.icon, ix, 0, 32, "quick")
    end
    c:Text(w.text, 0, 0, "Friz", 24, col, 1)
    if w.sub then c:Text(w.sub, 0, 26, "Friz", 16, CYEL, 1) end
    c:Pop()
end

function CLASSIC.you(c, a, sw, sh)
    if a > 2.4 then return end
    local a0 = c.a
    c.a = a0 * clamp((2.4 - a) / 0.4)
    c:Glow(sw / 2, sh * 0.62 + 8, 72, 22, C("#783c14"), 0.9)
    c.a = a0
end

-- The game's countdown digits (Interface\Timer\BigTimerNumbers: 4 x 3 cells of 256 x 170.67 in 1024 x 512).
function CLASSIC.count(c, n, k, x, y)
    local sc = k < 0.1 and (1.6 - 0.6 * easeOut(k / 0.1)) or 1
    c.a = c.a * clamp((1 - k) / 0.25)
    local col, row = n % 4, floor(n / 4)
    c:Img(BIGNUM, x, y, 128 * sc, 85 * sc, nil, 1, col * 0.25, (col + 1) * 0.25, row / 3, (row + 1) / 3)
end

-- The tooltip edge (UI-Tooltip-Border: 8 pieces of 16 px: left, right, top, bottom, the 4 corners; top and bottom
-- are the left piece turned).
local function TipPanel(c, x, y, w, h)
    c:Rect(x + 3, y + 3, w - 6, h - 6, BLACK, 0.82)
    local s, P = 16, function(i) return i / 8, (i + 1) / 8 end
    local l, r = P(0)
    c:Img(TIPEDGE, x + s / 2, y + h / 2, s, h - 2 * s, nil, 1, l, r, 0, 1)
    l, r = P(1)
    c:Img(TIPEDGE, x + w - s / 2, y + h / 2, s, h - 2 * s, nil, 1, l, r, 0, 1)
    l, r = P(2)
    c:Img(TIPEDGE, x + w / 2, y + s / 2, s, w - 2 * s, nil, 1, l, r, 0, 1, -pi / 2)
    l, r = P(3)
    c:Img(TIPEDGE, x + w / 2, y + h - s / 2, s, w - 2 * s, nil, 1, l, r, 0, 1, -pi / 2)
    for i, at in ipairs({ { x, y }, { x + w - s, y }, { x, y + h - s }, { x + w - s, y + h - s } }) do
        l, r = P(3 + i)
        c:Img(TIPEDGE, at[1] + s / 2, at[2] + s / 2, s, s, nil, 1, l, r, 0, 1)
    end
end
BL.TipPanel = TipPanel

local DISCBG, DISCEDGE = C("#141812"), C("#5c5244")
function CLASSIC.range(c, R, a, cx, cy0)
    local s = 150
    local x, y = cx - s / 2, cy0 - s / 2 - 22
    TipPanel(c, x, y, s, s + 34)
    c:Text("Range: " .. R.yd .. " yd", cx, y + 15, "Friz", 12, CYEL, 0)
    c:Text(R.n > 0 and (R.n .. " too close") or "Clear", cx, y + s + 18, "Friz", 12, R.n > 0 and CRED or CGREEN, 0)
    if R.noPos then RangeList(c, R, x + 14, y + 40, s - 28, "Friz") return end
    local cy, px = y + 86, 46 / R.yd
    c:Disc(cx, cy, 59, DISCEDGE, 1)
    c:Disc(cx, cy, 57, DISCBG, 0.95)
    c:Ring(cx, cy, R.yd * px, 1, R.n > 0 and CRED or CYEL, R.n > 0 and 0.8 or 0.5)
    DotsIn(R, px, 52)(function(d, dx, dy)
        local i = BLIP[d.cls] or 4
        local col, row = i % 8, floor(i / 8) + (d.close and 2 or 0)
        c:Img(BLIPS, cx + dx, cy + dy, 12, 12, nil, 1, col / 8, (col + 1) / 8, row / 4, (row + 1) / 4)
    end)
    Arrow(c, cx, cy, C("#f8f8a0"))
end

BL.ORDER = { "flat", "halo", "sigil", "slate", "gilded", "classic" }
BL.SIGNATURE = { flat = "The soon lane", halo = "Countdown rings", sigil = "Stamped warnings", slate = "Text first",
                 gilded = "The compass", classic = "Raid warnings" }

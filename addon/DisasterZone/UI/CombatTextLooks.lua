if DisasterZoneBoot and DisasterZoneBoot.Run("UI/CombatTextLooks.lua", ...) then return end -- DisasterZone UI/CombatTextLooks.lua
-- The six looks of the combat text (ns.CombatTextLooks), ported line by line from the mockup
-- (claude.ai/artifact/LeZxS4KRZhKGsQXUbLRCiE; dev/art/casc/sct_mockup/sct_template.html), so they move and look as
-- shown there. Each look spawns numbers for the stage's events (UI/CombatText.lua): out (my hits; group "tick" =
-- ticks that count up in place, "multi" = hits that land together), miss, taken, heal, proc, alert, lowhp, kill.
-- A number draws itself every frame with the pen (UI/CombatTextPen.lua) in coordinates local to its anchor, in the
-- mockup's px: the hit point of the mob (its nameplate), you, the alerts spot, or the screen's top left.
--   flat    rolling totals: hits that land together count up as one line
--   halo    crit rings: a ring fires out of a crit; ticks land round the target on a ring
--   sigil   stamp and shatter: numbers slam down, a crit's tile breaks into shards; tally pips for ticks
--   slate   hairlines and a receipt: a feed beside the target, each hit's size as a hairline, a fight receipt
--   gilded  new records: per-spell bests in a gilded banner, gold sparks, big crits in a cartouche
--   classic the game's damage font and its scrolling text over your head, reactive alerts in the button's glow
local addonName, ns = ...

local L = {}
ns.CombatTextLooks = L
local Pen = ns.CTPen
local C, Mix, clamp = Pen.C, Pen.Mix, Pen.clamp

local floor, max, min, abs, exp, cos, sin, ceil = math.floor, math.max, math.min, math.abs, math.exp, math.cos,
    math.sin, math.ceil
local pi = math.pi
local TAU = pi * 2
local ipairs, tostring = ipairs, tostring

---------------------------------------------------------------------------
-- The mockup's helpers
---------------------------------------------------------------------------

local function easeOut(k) k = clamp(k); return 1 - (1 - k) ^ 3 end
local function easeIn(k) k = clamp(k); return k * k end
local function fade(age, life, tail)
    tail = tail or 0.35
    local k = age / life
    if k < 1 - tail then return 1 end
    return clamp((1 - k) / tail)
end
local function fin(age, d) return clamp(age / (d or 0.1)) end
local function rnd(s) local x = sin(s * 12.9898 + 4.1414) * 43758.5453; return x - floor(x) end
local function galpha(s) return s.ending and clamp((s.life - s.age) / 0.35) or 1 end

-- 1284 -> "1,284"
local function fmt(n)
    n = floor((n or 0) + 0.5)
    local s = tostring(abs(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (n < 0 and "-" or "") .. out
end
L.fmt = fmt

local W = C("#ffffff")
local BLACK = C("#000000")
local GOLD = C("#ffd100")
local GREYT = C("#aaa7b5")
local SC = { phys = C("#ffffff"), holy = C("#ffe27a"), arcane = C("#ff86ff"), fire = C("#ff8a3d"),
             frost = C("#80e8ff"), nature = C("#7cf05a"), shadow = C("#a796ff"), heal = C("#3cf03c") }
L.SC = SC
local function School(ev) return SC[ev.school or "phys"] or W end
local PAL = C("#f58cba")
local CLASSC = { PRIEST = C("#ffffff"), PALADIN = PAL, WARRIOR = C("#c79c6e"), HUNTER = C("#abd473"),
                 ROGUE = C("#fff569"), SHAMAN = C("#0070de"), MAGE = C("#69ccf0"), WARLOCK = C("#9482c9"),
                 DRUID = C("#ff7d0a") }
L.CLASSC = CLASSC
local function MyClassColor()
    local cls
    if UnitClass then _, cls = UnitClass("player") end
    return CLASSC[cls or "PALADIN"] or PAL
end

local HIT = { x = 0, y = 0 }
local BOSS = { x = 0, y = 38 }
local ME = { x = 0, y = 0 }
local TOP = { x = 0, y = -34 }
local MID = { x = 0, y = 34 }
L.TOP, L.MID = TOP, MID

-- Where a miss stands: on the mob, or (a miss of a hit on me) where my taken hits stand.
local function MissAt(st, ev)
    if ev.mine then return st.you, st.IN.x, st.IN.y end
    return ev.hit, nil, HIT.y
end

---------------------------------------------------------------------------
-- Flat: rolling totals
---------------------------------------------------------------------------

local CHIP = C("#0a0a0d")
local function Edge(c, x, y, w, h, col, a)
    c:Rect(x, y, w, 1, col, a); c:Rect(x, y + h - 1, w, 1, col, a)
    c:Rect(x, y, 1, h, col, a); c:Rect(x + w - 1, y, 1, h, col, a)
end
local function flatChip(c, x, y, w, h, edge, ea)
    c:Rect(x - w / 2, y - h / 2, w, h, CHIP, 0.66)
    Edge(c, x - w / 2, y - h / 2, w, h, edge or BLACK, ea or 1)
end

local F = {}
L.flat = F
F.out = function(st, ev)
    if ev.group then return F.tick(st, ev) end
    local x0, y0, crit = st:Lane(ev), HIT.y, ev.crit
    local life = crit and 1.75 or 1.25
    local col, str = School(ev), fmt(ev.amt)
    local best = ev.record and ("Best " .. (ev.spell or "")) or nil
    local was = ev.record and ("was " .. fmt(ev.record)) or nil
    local over = ev.overkill and (fmt(ev.overkill) .. " overkill") or nil
    local pet = ev.pet and 0.8 or 1
    local fill = {}
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local y = y0 - (crit and 54 or 70) * easeOut(t / life)
        c.a = fade(t, life, 0.3)
        local pop = (crit and t < 0.1) and (1 + 0.42 * (1 - t / 0.1)) or 1
        local sz = (crit and 34 or 21) * pop * pet
        local fc = crit and Mix(W, col, t / 0.22, fill) or col
        c:R()
        if ev.icon then c:RI(ev.icon, floor((crit and 22 or 16) * pop * pet + 0.5), "sq") end
        c:RT(str, "ArialN", sz, fc, 1)
        local w = c:RD(x0, y, 5)
        if crit then
            local r = clamp(1 - t / 0.5)
            if r > 0 then c:Rect(x0 - w / 2, y + sz * 0.5 + 2, w * r, 2, W, 0.9 * r) end
        end
        local ly = y + sz * 0.5 + 15
        if best then
            c:R(); c:RT(best, "Friz", 11, GOLD, 1); c:RT(was, "Friz", 11, GREYT, 1); c:RD(x0, ly, 6)
            ly = ly + 15
        end
        if over then c:Text(over, x0, ly, "Friz", 11, GREYT, 1) end
    end }, ev.hit)
end
F.tick = function(st, ev)
    local cons = ev.group == "tick"
    local lx = cons and 158 or st:Lane(ev)
    local tcol = C("#cfcbd8")
    st:Group(ev, cons and (ev.hold or 1.4) or 0.9, function(g, s) return function(c)
        local y = cons and (HIT.y - 36) or (HIT.y - 6 - 46 * easeOut(s.age / 1.4))
        c.a = galpha(s)
        local sc = 1 + 0.14 * g.pulse * g.pulse
        c:R()
        if g.icon then c:RI(g.icon, 16, "sq") end
        c:RT(fmt(g.shown), "ArialN", 21 * sc, School(g.ev), 1)
        if g.n > 1 then c:RT("\195\151" .. g.n, "Friz", 12, tcol, 1, 1) end
        c:RD(lx, y, 5)
        c:Text(g.spell or "", lx, y + 18, "Friz", 11, GREYT, 1)
    end end)
end
F.miss = function(st, ev)
    local at, mx, my = MissAt(st, ev)
    local x0 = mx or st:Lane(ev)
    local col = C("#d6d3df")
    st:Add({ life = 1.1, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.35)
        c:Text(ev.what or "", x0, my - 60 * easeOut(s.age / s.life), "Friz", 16, col, 1)
    end }, at)
end
F.taken = function(st, ev)
    local IN = st.IN
    local red = C("#ff4b3e")
    local str = "-" .. fmt(ev.amt)
    local res = ev.resist and (fmt(ev.resist) .. " resisted") or nil
    st:Add({ life = 1.8, draw = function(c, s)
        local y = IN.y - 80 * easeOut(s.age / s.life)
        c.a = fade(s.age, s.life, 0.3)
        c:R(); c:RI(ev.icon, 16, "sq"); c:RT(str, "ArialN", 21, red, 1); c:RD(IN.x, y, 5)
        if res then c:Text(res, IN.x, y + 18, "Friz", 11, GREYT, 1) end
    end }, st.you)
end
F.heal = function(st, ev)
    local HEAL = st.HEAL
    local green = C("#3cf03c")
    local str = "+" .. fmt(ev.amt)
    st:Add({ life = 1.8, draw = function(c, s)
        local y = HEAL.y - 80 * easeOut(s.age / s.life)
        c.a = fade(s.age, s.life, 0.3)
        c:R(); c:RI(ev.icon, 16, "sq"); c:RT(str, "ArialN", 21, green, 1); c:RD(HEAL.x, y, 5)
        if ev.who then c:Text(ev.who, HEAL.x, y + 18, "Friz", 11, GREYT, 1) end
    end }, st.you)
end
F.proc = function(st, ev)
    local dur = ev.dur and (floor(ev.dur + 0.5) .. "s") or ""
    local sub = C("#a29fae")
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        local y = TOP.y - 8 * (1 - easeOut(t / 0.2))
        c.a = fade(t, s.life, 0.15) * fin(t, 0.12)
        c:R(); c:RI(ev.icon, 22, "sq"); c:RT(ev.spell or "", "Friz", 13, W); c:RT(dur, "ArialN", 14, sub)
        flatChip(c, TOP.x, y, c:RW(8) + 18, 32)
        c:R(); c:RI(ev.icon, 22, "sq"); c:RT(ev.spell or "", "Friz", 13, W); c:RT(dur, "ArialN", 14, sub)
        c:RD(TOP.x, y, 8)
    end }, st.top)
end
F.alert = function(st, ev)
    st:Add({ life = 2.2, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.1)
        c:R(); c:RI(ev.icon, 22, "sq"); c:RT(ev.spell or "", "Friz", 13, W); c:RT("usable", "ArialN", 14, GOLD)
        flatChip(c, MID.x, MID.y, c:RW(8) + 18, 32, GOLD, 0.45 + 0.55 * abs(sin(t * 6)))
        c:R(); c:RI(ev.icon, 22, "sq"); c:RT(ev.spell or "", "Friz", 13, W); c:RT("usable", "ArialN", 14, GOLD)
        c:RD(MID.x, MID.y, 8)
    end }, st.top)
end
F.lowhp = function(st, ev)
    local red = C("#ff3c32")
    local label = (ev.mana and "Mana " or "Health ") .. (ev.pct or 0) .. "%"
    if not ev.mana then
        st:Add({ life = 1.6, under = true, draw = function(c, s)
            local t = s.age
            local Wd, Hd = st:ScreenSize()
            local a = 0.9 * abs(sin(t * pi * 1.5)) * fade(t, s.life, 0.3)
            c:Rect(0, 0, Wd, 3, red, a); c:Rect(0, Hd - 3, Wd, 3, red, a)
            c:Rect(0, 0, 3, Hd, red, a); c:Rect(Wd - 3, 0, 3, Hd, red, a)
        end }, st.screen)
    end
    local tc = ev.mana and C("#6ea8ff") or C("#ff6a5e")
    st:Add({ life = 1.6, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.3)
        c:Text(label, ME.x, ME.y - 26, "Friz", 12, tc, 1)
    end }, st.you)
end
F.kill = function(st, ev)
    local sub = C("#a29fae")
    local dps = fmt(ev.dps) .. " dps"
    st:Add({ life = 2.4, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.12)
        c:R(); c:RT(ev.name or "", "Friz", 13, W); c:RT(ev.time or "", "ArialN", 14, sub); c:RT(dps, "ArialN", 14, GOLD)
        flatChip(c, MID.x, MID.y, c:RW(10) + 22, 30)
        c:R(); c:RT(ev.name or "", "Friz", 13, W); c:RT(ev.time or "", "ArialN", 14, sub); c:RT(dps, "ArialN", 14, GOLD)
        c:RD(MID.x, MID.y, 10)
    end }, st.top)
end

---------------------------------------------------------------------------
-- Halo: crit rings
---------------------------------------------------------------------------

local HALO = {}
L.halo = HALO
local RINGC = C("#ffeec0")
local GLOWC = C("#ffe196")
local HGOLD = C("#ffd76a")
local PALE = C("#e9dcb0")
local PALE2 = C("#d6cfb4")
local DOT = C("#ffe9b0")
local HEAD = C("#fff6d8")

HALO.ring = function(st, at, x, y, scale, col, delay)
    delay = delay or 0
    st:Add({ life = 0.55 + delay, draw = function(c, s)
        local t = s.age - delay
        if t < 0 then return end
        local k = t / 0.55
        local r = (16 + 118 * easeOut(k)) * scale
        c.a = (1 - k) * 0.95
        c:Ring(x, y, r, 0.6 + 3.4 * (1 - k), col, 1)
        c.a = (1 - k) * 0.4
        c:Ring(x, y, r * 0.72, 1, col, 1)
    end }, at)
end
HALO.out = function(st, ev)
    if ev.group == "tick" then return HALO.tick(st, ev) end
    if ev.group then return HALO.multi(st, ev) end
    if ev.crit then return HALO.crit(st, ev) end
    local side = st:Side(ev)
    local seed = ev.seed or (ev.amt or 0) * 0.001
    local vx, vy, g = side * (55 + 50 * rnd(seed * 7)), -215 - 30 * rnd(seed * 3), 380
    local x0 = HIT.x + side * 12
    local col, str = School(ev), fmt(ev.amt)
    local pet = ev.pet and 0.8 or 1
    st:Add({ life = 1.3, draw = function(c, s)
        local t = s.age
        local x, y = x0 + vx * t, HIT.y + vy * t + 0.5 * g * t * t
        c.a = fade(t, s.life, 0.4) * fin(t, 0.06)
        c:R()
        if ev.icon then c:RI(ev.icon, 18 * pet, "round") end
        c:RT(str, "Friz", 20 * pet, col, 1, nil, col, 0.6)
        c:RD(x, y, 6)
    end }, ev.hit)
end
HALO.crit = function(st, ev)
    local x0, y0 = st:Lane(ev) * 0.6, HIT.y - 6
    local col, str = School(ev), fmt(ev.amt)
    HALO.ring(st, ev.hit, x0, y0, 1, RINGC)
    if ev.record then
        HALO.ring(st, ev.hit, x0, y0, 1.5, GOLD, 0.12)
        HALO.ring(st, ev.hit, x0, y0, 2.1, GOLD, 0.26)
    end
    local was = ev.record and ("was " .. fmt(ev.record)) or nil
    local over = ev.overkill and (fmt(ev.overkill) .. " overkill") or nil
    local fill = {}
    st:Add({ life = 1.7, draw = function(c, s)
        local t = s.age
        local y = y0 - 46 * easeOut(t / s.life)
        local sc = max(0.85, 1 + 0.85 * exp(-t * 9) * cos(t * 21))
        c.a = fade(t, s.life, 0.3)
        c:Glow(x0, y, 148, 148, GLOWC, 0.32)
        c:R()
        if ev.icon then c:RI(ev.icon, floor(24 * sc + 0.5), "round") end
        c:RT(str, "Friz", floor(30 * sc + 0.5), Mix(W, col, t / 0.3, fill), 1, nil, GLOWC, 0.85)
        c:RD(x0, y, 7)
        local ly = y + 30
        if was then
            c:Text("BEST EVER", x0, ly, "Friz", 11, GOLD, 1)
            c:Text(was, x0, ly + 15, "Friz", 11, PALE2, 1)
        end
        if over then c:Text(over, x0, ly, "Friz", 11, PALE2, 1) end
    end }, ev.hit)
end
HALO.tick = function(st, ev)
    local RX, RY, cx, cy = 196, 74, BOSS.x, BOSS.y - 6
    local function A(n) return (-165 + (n - 1) * 46) * pi / 180 end
    local function P(a) return cx + RX * cos(a), cy + RY * sin(a) end
    local arcc = C("#ffdd8c")
    st:Group(ev, ev.hold or 1.4, function(g, s) return function(c)
        local al = galpha(s)
        local last = g.ticks[#g.ticks]
        local grow = easeOut((st.clock - last.at) / 0.3)
        local a0, aPrev = A(1), A(max(1, g.n - 1))
        local aCur = g.n == 1 and a0 or (aPrev + (A(g.n) - aPrev) * grow)
        c.a = al
        if g.n > 1 then c:Arc(cx, cy, RX, RY, a0, aCur, 2, arcc, 0.65, true) end
        for _, tk in ipairs(g.ticks) do
            local px, py = P(A(tk.n))
            local age = st.clock - tk.at
            c.a = al
            c:Disc(px, py, 2.5, DOT, 1)
            local la = clamp(1 - (age - 0.9) / 0.4) * al
            if la > 0 then
                c.a = la
                local sc = 1 + 0.5 * exp(-age * 12)
                c:Text(fmt(tk.amt), px, py - 15 - 8 * easeOut(age / 1.3), "Friz", floor(15 * sc + 0.5), SC.holy, 1, nil,
                    SC.holy, 0.6)
            end
        end
        local hx, hy = P(aCur)
        c.a = al
        c:Glow(hx, hy, 22, 22, HGOLD, 0.9)
        c:Disc(hx, hy, 4, HEAD, 1)
        local p0x, p0y = P(a0)
        c:R(); c:RI(g.icon, 16, "round"); c:RT(fmt(g.shown), "Friz", 15, GOLD, 1)
        c:RT("\195\151" .. g.n, "Friz", 11, PALE, 1)
        c:RD(p0x - 4, p0y + 22, 5)
    end end)
end
HALO.multi = function(st, ev)
    local x = st:Lane(ev)
    st:Group(ev, 0.9, function(g, s) return function(c)
        local y = HIT.y - 6 - 44 * easeOut(s.age / 1.4)
        local sc = 1 + 0.18 * g.pulse * g.pulse
        c.a = galpha(s)
        c:R(); c:RI(g.icon or ev.icon or "Interface\\Icons\\Spell_Nature_Windfury", 18, "round")
        c:RT(fmt(g.shown), "Friz", floor(20 * sc + 0.5), W, 1, nil, W, 0.45)
        local w = c:RD(x, y, 6)
        if g.n > 1 then
            local bx, by = x - w / 2 + 16, y - 10
            c:Disc(bx, by, 8, BLACK, 1)
            c:Disc(bx, by, 7, GOLD, 1)
            c:Text(tostring(g.n), bx, by + 0.5, "ArialN", 10, BLACK, 0)
        end
        c:Text(g.spell or "", x, y + 19, "Friz", 11, PALE, 1)
    end end)
end
HALO.miss = function(st, ev)
    local at, mx, my = MissAt(st, ev)
    local x0 = mx or st:Lane(ev)
    HALO.ring(st, at, x0, my, 0.5, C("#dcdce6"))
    local col = C("#e4e1ec")
    st:Add({ life = 1.1, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.35)
        c:Text(ev.what or "", x0, my - 56 * easeOut(s.age / s.life), "Friz", 16, col, 1, nil, W, 0.35)
    end }, at)
end
local TRACK = C("#08080b")
HALO.pill = function(c, x, y, w, h, col, icon, label, sub, ring, coords)
    local Lx, r = x - w / 2, h / 2
    local D = Pen.DISC
    -- the dark rim, the track, the fill fading out to the right
    c:Img(D, Lx + r / 2, y, r + 1, h + 2, BLACK, 0.9, 0, 0.5, 0, 1)
    c:Img(D, Lx + w - r / 2, y, r + 1, h + 2, BLACK, 0.9, 0.5, 1, 0, 1)
    c:Rect(Lx + r - 0.5, y - r - 1, w - 2 * r + 1, h + 2, BLACK, 0.9)
    c:Img(D, Lx + r / 2, y, r, h, TRACK, 0.62, 0, 0.5, 0, 1)
    c:Img(D, Lx + w - r / 2, y, r, h, TRACK, 0.62, 0.5, 1, 0, 1)
    c:Rect(Lx + r, y - r, w - 2 * r, h, TRACK, 0.62)
    c:Img(D, Lx + r / 2, y, r, h, col, 0.95, 0, 0.5, 0, 1)
    c:Grad(Lx + r, y - r, w - 2 * r, h, "H", col, 0.95, col, 0)
    c:Icon(icon, Lx + r, y, h - 4, "round", ring or BLACK, coords)
    c:Text(label, Lx + h + 6, y + 1, "Friz", 14, W, 1, "LEFT")
    if sub then c:Text(sub, Lx + w - 12, y + 1, "Friz", 11, W, 0, "RIGHT") end
end
HALO.taken = function(st, ev)
    local IN = st.IN
    local col = ev.school == "arcane" and C("#b23fd0") or C("#d2281e")
    local str = "-" .. fmt(ev.amt)
    local res = ev.resist and (fmt(ev.resist) .. " resisted") or nil
    st:Add({ life = 1.8, draw = function(c, s)
        local y = IN.y - 70 * easeOut(s.age / s.life)
        c.a = fade(s.age, s.life, 0.3) * fin(s.age, 0.08)
        HALO.pill(c, IN.x, y, 136, 24, col, ev.icon, str)
        if res then c:Text(res, IN.x, y + 22, "Friz", 11, PALE2, 1) end
    end }, st.you)
end
HALO.heal = function(st, ev)
    local HEAL = st.HEAL
    local col = C("#2fae37")
    local str = "+" .. fmt(ev.amt)
    local ring = CLASSC[ev.whoClass or ""] or nil
    st:Add({ life = 1.8, draw = function(c, s)
        local y = HEAL.y - 70 * easeOut(s.age / s.life)
        c.a = fade(s.age, s.life, 0.3) * fin(s.age, 0.08)
        HALO.pill(c, HEAL.x, y, 176, 24, col, ev.whoIcon or ev.icon, str, ev.who, ring, ev.whoIcon and ev.whoCoords or nil)
    end }, st.you)
end
HALO.proc = function(st, ev)
    local pale = C("#f5dc8f")
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        local x, y = TOP.x, TOP.y + 4
        local base = fade(t, s.life, 0.15) * fin(t, 0.1)
        c.a = base
        c:Ring(x, y, 21, 2.5, W, 0.12)
        local f = easeOut(t / 0.45) * (1 - t / (ev.dur or 30))
        c:Arc(x, y, 21, 21, -pi / 2, -pi / 2 + TAU * f, 2.5, HGOLD, 1, true)
        c:Icon(ev.icon, x, y, 34, "round", BLACK)
        if t < 0.6 then
            local k = t / 0.6
            c.a = base * (1 - k)
            c:Ring(x, y, 22 + 30 * easeOut(k), 1.5, DOT, 1)
        end
        c.a = base
        c:Text(ev.spell or "", x + 32, y + 1, "Friz", 14, pale, 1, "LEFT")
    end }, st.top)
end
HALO.alert = function(st, ev)
    st:Add({ life = 2.2, draw = function(c, s)
        local t = s.age
        local base = fade(t, s.life, 0.15) * fin(t, 0.1)
        for i = 0, 2 do
            local k = (t - i * 0.45) / 0.7
            if k >= 0 and k <= 1 then
                c.a = base * (1 - k)
                c:Ring(MID.x, MID.y, 22 + 44 * easeOut(k), 1.5, HGOLD, 1)
            end
        end
        c.a = base
        c:Icon(ev.icon, MID.x, MID.y, 38, "round")
        c:Text(ev.spell or "", MID.x, MID.y + 36, "Friz", 14, GOLD, 1, nil, HGOLD, 0.6)
    end }, st.top)
end
HALO.lowhp = function(st, ev)
    if ev.mana then return F.lowhp(st, ev) end
    local red = C("#ff2a24")
    st:Add({ life = 1.7, under = true, draw = function(c, s)
        local t = s.age
        local Wd, Hd = st:ScreenSize()
        c.add = true
        c:Img(Pen.LOWHP, Wd / 2, Hd / 2, Wd, Hd, red, 0.9 * fade(t, s.life, 0.3) * (0.55 + 0.45 * sin(t * 7)))
    end }, st.screen)
end
HALO.kill = function(st, ev)
    st:Add({ life = 1.1, draw = function(c, s)
        local k = s.age / s.life
        local r, a
        if k < 0.38 then
            r = 20 + 260 * (1 - easeIn(k / 0.38)); a = 0.35 + 0.65 * (k / 0.38)
        else
            local q = (k - 0.38) / 0.62
            r = 20 + 320 * easeOut(q); a = 1 - q
        end
        c.a = a
        c:Arc(BOSS.x, BOSS.y - 10, r, r * 0.62, 0, TAU, 2.5, HGOLD, 1, true)
    end }, ev.hit)
    local line = (ev.time or "") .. "  \194\183  " .. fmt(ev.dps) .. " dps"
    st:Add({ life = 2.4, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t - 0.35, 0.2)
        c:Text(ev.name or "", MID.x, MID.y - 6, "Friz", 18, GOLD, 1, nil, HGOLD, 0.7)
        c:Text(line, MID.x, MID.y + 16, "Friz", 12, PALE, 1)
    end }, st.top)
end

---------------------------------------------------------------------------
-- Sigil: stamp and shatter
---------------------------------------------------------------------------

local SIGIL = {}
L.sigil = SIGIL
local TILE = C("#09090b")
local function tile(c, cx, cy, w, h, rim, rimA, lit, litA, fill, fillA)
    local x, y = cx - w / 2, cy - h / 2
    c:Rect(x, y, w, h, fill or TILE, fillA or 0.88)
    Edge(c, x - 1, y - 1, w + 2, h + 2, BLACK, 1)
    Edge(c, x + 1, y + 1, w - 2, h - 2, W, 0.07)
    if rim then Edge(c, x, y, w, h, rim, rimA or 1) end
    if lit then
        c:Grad(x + 1, y + 1, w - 2, h * 0.55, "V", lit, litA, lit, 0)
        c:Rect(x + 1, y + 1, w - 2, 1.5, lit, litA)
    end
end
local SS = {}
local function stamp(t, from, d)
    from, d = from or 1.9, d or 0.09
    if t < d then
        local k = t / d
        SS.sc, SS.dx, SS.dy, SS.a = from + (1 - from) * k * k, 0, 0, 0.25 + 0.75 * k
        return SS
    end
    local j = t < d + 0.16 and (1 - (t - d) / 0.16) or 0
    SS.sc, SS.dx, SS.dy, SS.a = 1, sin(t * 97) * 2.4 * j, cos(t * 83) * 1.5 * j, 1
    return SS
end
local DUST = C("#fff3c0")
local function dust(c, w, h, t, d)
    d = d or 0.09
    local k = (t - d) / 0.22
    if k < 0 or k > 1 then return end
    local a = c.a
    c.a = a * (1 - k)
    local e = 6 + 12 * easeOut(k)
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local px, py = sx * w / 2, sy * h / 2
            c:Line(px + sx * e * 0.4, py + sy * e * 0.4, px + sx * e, py + sy * e, 1.5, DUST, 1)
        end
    end
    c.a = a
end
local SGOLD = C("#ffd100")
local function sigTag(c, text, x, y, size, color, lit, litA, fill, fillA, rim)
    size = size or 9
    local w = c:W("Friz", size, text, 0) + 12
    tile(c, x, y, w, size + 7, rim, 1, lit or SGOLD, litA or 0.3, fill, fillA)
    c:Text(text, x + 0.75, y + 0.5, "Friz", size, color or SGOLD, 0)
    return w
end
local EU = {}
local function exitUp(t, hold, life)
    if t < hold then EU.up, EU.a = 0, 1 return EU end
    EU.up, EU.a = 34 * easeIn((t - hold) / (life - hold)), 1 - (t - hold) / (life - hold)
    return EU
end
local SHARD = C("#0e0e11")
local function shards(c, w, h, k)
    local tris = { { -w / 2, -h / 2, w / 2, -h / 2, 0, -1 }, { w / 2, -h / 2, w / 2, h / 2, 1, 0 },
                   { w / 2, h / 2, -w / 2, h / 2, 0, 1 }, { -w / 2, h / 2, -w / 2, -h / 2, -1, 0 } }
    local a0 = c.a
    for _, tr in ipairs(tris) do
        local ax, ay, bx, by, dx, dy = tr[1], tr[2], tr[3], tr[4], tr[5], tr[6]
        local cx, cy = (ax + bx) / 3, (ay + by) / 3
        local ox, oy = cx + dx * 70 * k + cx * 0.5 * k, cy + dy * 46 * k + 110 * k * k
        local rot = (dx - dy) * 1.4 * k + (dx + dy) * 0.3 * k
        local cr, sr = cos(rot), sin(rot)
        local function R(px, py) px, py = px - cx, py - cy; return ox + px * cr - py * sr, oy + px * sr + py * cr end
        local p1x, p1y = R(ax, ay)
        local p2x, p2y = R(bx, by)
        local p3x, p3y = R(0, 0)
        c.a = a0 * (1 - k) * 0.95
        c:Tri(p1x, p1y, p2x, p2y, p3x, p3y, SHARD, 0.92)
        c:Line(p1x, p1y, p2x, p2y, 1, SGOLD, 0.85)
        c:Line(p2x, p2y, p3x, p3y, 1, SGOLD, 0.85)
        c:Line(p3x, p3y, p1x, p1y, 1, SGOLD, 0.85)
    end
    c.a = a0
end
local function brackets(c, x, y, hw, hh, len, col, a, lw)
    lw = lw or 2
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local px, py = x + sx * hw, y + sy * hh
            c:Line(px - sx * len, py, px, py, lw, col, a)
            c:Line(px, py, px, py - sy * len, lw, col, a)
        end
    end
end
local SGREY = C("#a8a5b3")
local function Caps(s) return (s or ""):upper() end

SIGIL.out = function(st, ev)
    if ev.group == "tick" then return SIGIL.tick(st, ev) end
    if ev.group then return SIGIL.multi(st, ev) end
    if ev.crit then return SIGIL.crit(st, ev) end
    local x0, col, str = st:Lane(ev), School(ev), fmt(ev.amt)
    local pet = ev.pet and 0.8 or 1
    st:Add({ life = 1.3, draw = function(c, s)
        local t = s.age
        local S = stamp(t)
        local E = exitUp(t, 0.6, s.life)
        c.a = S.a * E.a
        c:Translate(x0 + S.dx, HIT.y - E.up + S.dy)
        c:Scale(S.sc * pet)
        c:R()
        if ev.icon then c:RI(ev.icon, 16, "framed") end
        c:RT(str, "Friz", 22, col, 2)
        local w = c:RD(0, 0, 6)
        dust(c, w + 8, 26, t)
    end }, ev.hit)
end
SIGIL.crit = function(st, ev)
    local x0, y0 = st:Lane(ev) * 0.6, HIT.y - 8
    local col, str = School(ev), fmt(ev.amt)
    local life = 1.9
    local brk = life - 0.42
    local was = ev.record and ("WAS " .. fmt(ev.record)) or nil
    local over = ev.overkill and ("OVERKILL " .. fmt(ev.overkill)) or nil
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local S = stamp(t, 2.1, 0.1)
        c.a = S.a
        c:Translate(x0 + S.dx, y0 + S.dy - 10 * easeOut(min(t, brk) / brk))
        c:Scale(S.sc)
        c:R()
        if ev.icon then c:RI(ev.icon, 26, "framed") end
        c:RT(str, "Friz", 30, col, 2)
        local w, h = c:RW(8) + 36, 48
        if t < brk then
            tile(c, 0, 0, w, h, SGOLD, 0.8, SGOLD, 0.32)
            if ev.record then Edge(c, -w / 2 - 4, -h / 2 - 4, w + 9, h + 9, SGOLD, 0.55) end
            c:R()
            if ev.icon then c:RI(ev.icon, 26, "framed") end
            c:RT(str, "Friz", 30, col, 2)
            c:RD(0, 1, 8)
            sigTag(c, "CRIT", -w / 2 + 22, -h / 2)
            if was then
                sigTag(c, "NEW BEST", w / 2 - 36, -h / 2, 9, C("#111111"), W, 0.45, SGOLD, 0.95)
                c:Text(was, 0, h / 2 + 13, "Friz", 9, C("#d6cfb4"), 1)
            end
            if over then c:Text(over, 0, h / 2 + 13, "Friz", 9, C("#d6cfb4"), 1) end
            dust(c, w, h, t, 0.1)
        else
            local k = (t - brk) / (life - brk)
            shards(c, w, h, k)
            c.a = clamp(1 - k / 0.35)
            c:R()
            if ev.icon then c:RI(ev.icon, 26, "framed") end
            c:RT(str, "Friz", 30, col, 2)
            c:RD(0, 1 - 14 * k, 8)
        end
    end }, ev.hit)
end
SIGIL.tick = function(st, ev)
    local x, y = HIT.x + 162, HIT.y - 40
    local name = Caps(ev.spell)
    local pipFill, pipLit = C("#463400"), C("#ffdc50")
    st:Group(ev, ev.hold or 1.4, function(g, s) return function(c)
        local al = galpha(s)
        c.a = al
        local last = g.ticks[#g.ticks]
        local S = stamp(st.clock - last.at, 1.5, 0.08)
        c:Text(name, x, y - 21, "Friz", 9, SGREY, 1)
        c:Push()
        c:Translate(x + S.dx, y + S.dy)
        c:Scale(S.sc)
        c:R(); c:RI(g.icon, 16, "framed"); c:RT(fmt(g.shown), "Friz", 21, School(g.ev), 2); c:RD(0, 0, 6)
        c:Pop()
        local n, pw, gap = g.n, 8, 4
        local tot = n * pw + (n - 1) * gap
        for i = 0, n - 1 do
            local px, py = x - tot / 2 + i * (pw + gap) + pw / 2, y + 20
            local sc = (i == n - 1) and stamp(st.clock - last.at, 2.4, 0.08).sc or 1
            c:Push()
            c:Translate(px, py)
            c:Scale(sc)
            tile(c, 0, 0, pw, pw, SGOLD, 0.9, pipLit, 0.75, pipFill, 0.95)
            c:Pop()
            c.a = al
        end
    end end)
end
SIGIL.multi = function(st, ev)
    local x = st:Lane(ev)
    st:Group(ev, 0.9, function(g, s) return function(c)
        local first, last = g.ticks[1], g.ticks[#g.ticks]
        local S = stamp(st.clock - first.at)
        local up = s.ending and 30 * (1 - galpha(s)) or 0
        c.a = S.a * galpha(s)
        c:Translate(x + S.dx, HIT.y - up + S.dy)
        c:Scale(S.sc)
        c:R(); c:RI(g.icon or ev.icon or "Interface\\Icons\\Spell_Nature_Windfury", 16, "framed")
        c:RT(fmt(g.shown), "Friz", 22, W, 2)
        local w = c:RD(0, 0, 6)
        if g.n > 1 then
            local P = stamp(st.clock - last.at, 2.4, 0.08)
            c:Push()
            c:Translate(w / 2 + 18, -12)
            c:Scale(P.sc)
            sigTag(c, "\195\151" .. g.n, 0, 0, 10)
            c:Pop()
        end
        c:Text(Caps(g.spell), 0, 21, "Friz", 9, SGREY, 1)
    end end)
end
SIGIL.miss = function(st, ev)
    local at, mx, my = MissAt(st, ev)
    local x0 = mx or st:Lane(ev)
    local word = Caps(ev.what)
    st:Add({ life = 1.2, draw = function(c, s)
        local t = s.age
        local S = stamp(t, 2)
        local E = exitUp(t, 0.6, s.life)
        c.a = S.a * E.a
        c:Translate(x0 + S.dx, my - E.up + S.dy)
        c:Scale(S.sc)
        sigTag(c, word, 0, 0, 12, C("#ecebf2"), W, 0.2)
        dust(c, 74, 20, t)
    end }, at)
end
SIGIL.taken_ = function(st, ev, pos, lit, litA, col, sign, tag)
    local str = sign .. fmt(ev.amt)
    local res = ev.resist and ("RESIST " .. fmt(ev.resist)) or nil
    st:Add({ life = 1.9, draw = function(c, s)
        local t = s.age
        local S = stamp(t, 1.8)
        local E = exitUp(t, 0.9, s.life)
        c.a = S.a * E.a
        c:Translate(pos.x + S.dx, pos.y - E.up + S.dy)
        c:Scale(S.sc)
        c:R(); c:RI(ev.icon, 18, "framed"); c:RT(str, "Friz", 20, col, 2)
        local w = c:RW(7) + 26
        tile(c, 0, 0, w, 34, nil, nil, lit, litA)
        c:R(); c:RI(ev.icon, 18, "framed"); c:RT(str, "Friz", 20, col, 2); c:RD(0, 0, 7)
        sigTag(c, tag, 0, 25, 9, C("#d4d0de"), W, 0.12)
        if res then sigTag(c, res, 0, 43, 9, C("#ffa6ec"), C("#ff86ff"), 0.25) end
    end }, st.you)
end
SIGIL.taken = function(st, ev) SIGIL.taken_(st, ev, st.IN, C("#ff4632"), 0.42, C("#ff5444"), "-", Caps(ev.spell)) end
SIGIL.heal = function(st, ev) SIGIL.taken_(st, ev, st.HEAL, C("#50e650"), 0.36, C("#58f058"), "+", Caps(ev.who or ev.spell)) end
SIGIL.proc = function(st, ev)
    local name, dur = Caps(ev.spell), (ev.dur and (floor(ev.dur + 0.5) .. "S") or "")
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        local S = stamp(t, 1.7)
        c.a = S.a * fade(t, s.life, 0.15)
        c:Translate(TOP.x + S.dx, TOP.y + S.dy)
        c:Scale(S.sc)
        c:R(); c:RI(ev.icon, 22, "framed"); c:RT(name, "Friz", 12, W); c:RT(dur, "Friz", 10, SGREY)
        tile(c, 0, 0, c:RW(9) + 24, 34, SGOLD, 0.45, SGOLD, 0.22)
        c:R(); c:RI(ev.icon, 22, "framed"); c:RT(name, "Friz", 12, W); c:RT(dur, "Friz", 10, SGREY)
        c:RD(0, 0, 9)
    end }, st.top)
end
SIGIL.alert = function(st, ev)
    local name = Caps(ev.spell)
    st:Add({ life = 2.2, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.08)
        c:Icon(ev.icon, MID.x, MID.y, 30, "framed")
        local d = 30 - 12 * easeOut(t / 0.25)
        local pulse = t > 0.25 and (0.6 + 0.4 * abs(sin((t - 0.25) * 6))) or 1
        brackets(c, MID.x, MID.y, d, d, 8, SGOLD, pulse, 2)
        c:Text(name, MID.x, MID.y + 36, "Friz", 11, SGOLD, 1)
    end }, st.top)
end
SIGIL.lowhp = function(st, ev)
    local red = C("#ff4637")
    if not ev.mana then
        st:Add({ life = 1.6, under = true, draw = function(c, s)
            local t = s.age
            local Wd, Hd = st:ScreenSize()
            local inset = 14 + 30 * (1 - easeOut(t / 0.2))
            local a = fade(t, s.life, 0.3) * (0.55 + 0.45 * abs(sin(t * 6)))
            brackets(c, Wd / 2, Hd / 2, Wd / 2 - inset, Hd / 2 - inset, 46, red, a, 3)
        end }, st.screen)
    end
    local label = (ev.mana and "MANA " or "HEALTH ") .. (ev.pct or 0) .. "%"
    st:Add({ life = 1.6, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.3)
        sigTag(c, label, ME.x, ME.y - 30, 9, ev.mana and C("#a8c8ff") or C("#ffb3a8"),
            ev.mana and C("#4678ff") or C("#ff4632"), 0.45)
    end }, st.you)
end
SIGIL.kill = function(st, ev)
    local life = 2.4
    local brk = life - 0.45
    local line = Caps((ev.name or "") .. "  \194\183  " .. (ev.time or "") .. "  \194\183  " .. fmt(ev.dps) .. " dps")
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local S = stamp(t, 2.4, 0.11)
        c.a = S.a
        c:Translate(MID.x + S.dx, MID.y + S.dy)
        c:Scale(S.sc)
        local w, h = 300, 60
        if t < brk then
            tile(c, 0, 0, w, h, SGOLD, 0.85, SGOLD, 0.3)
            c:Text("S L A I N", 0, -6, "Friz", 28, SGOLD, 2)
            c:Text(line, 0, 18, "Friz", 9, C("#cfcbd8"), 0)
            dust(c, w, h, t, 0.11)
        else
            shards(c, w, h, (t - brk) / (life - brk))
        end
    end }, st.top)
end

---------------------------------------------------------------------------
-- Slate: hairlines and a receipt
---------------------------------------------------------------------------

local SLATE = {}
L.slate = SLATE
local OX, OY, IX, IY, PITCH, TRACKW, ITRACKW = 132, 56, -92, -14, 21, 170, 150
local SNAME = C("#b9b6c4")
local SAMT = C("#e8e6ee")
local SRED = C("#ff5a4a")
local SGREEN = C("#5fe05a")
local SSUB = C("#a29fae")

local function slatePush(st, name, at, line)
    local F = st:Feed(name, at)
    table.insert(F, 1, line)
    line.yy = -0.9
    line.life = line.life or 3.2
    if #F > 7 then
        local old = F[#F]
        if not old.ending then old.ending = true; old.life = old.age + 0.25 end
    end
    local own = line.update
    line.update = function(s, dt, st)
        local f = st:Feed(name, at)
        local idx = 0
        for i = 1, #f do if f[i] == s then idx = i - 1 break end end
        s.yy = s.yy + (idx - s.yy) * min(1, dt * 16)
        if own then own(s, dt, st) end
    end
    st:Add(line, at)
    return line
end
local function slateDraw(c, s, X, Y, track)
    local Lr = s.get and s.get() or s
    local y = Y - s.yy * PITCH
    local a = min(fin(s.age, 0.12), s.ending and clamp((s.life - s.age) / 0.25) or fade(s.age, s.life, 0.2))
    c.a = a
    c:Text(Lr.amt, X, y, "ArialN", 16, Lr.col or W, 1, "RIGHT")
    local nameW = c:W("ArialN", 14, Lr.name, 1)
    c:Text(Lr.name, X + 8, y + 0.5, "ArialN", 14, Lr.ncol or SNAME, 1, "LEFT")
    if Lr.tag then c:Text(Lr.tag, X + 14 + nameW, y + 0.5, "ArialN", 11, Lr.tagCol or GOLD, 1, "LEFT") end
    local hx, hy = X - 52, y + 10
    c:Rect(hx, hy, track, 2, W, 0.08)
    local grow = easeOut(s.age / 0.35)
    local fw = track * clamp(Lr.frac or 0) * grow
    if fw > 0 then c:Rect(hx, hy, fw, 2, Lr.hcol or W, Lr.ha or 0.45) end
end
SLATE.outLine = function(st, ev, line)
    line.draw = function(c, s) slateDraw(c, s, OX, OY, TRACKW) end
    return slatePush(st, "out", ev.hit, line)
end
SLATE.inLine = function(st, line)
    line.draw = function(c, s) slateDraw(c, s, IX, IY, ITRACKW) end
    return slatePush(st, "in", st.you, line)
end
local function BestAny(ev) return ev.bestAny or 6240 end
SLATE.out = function(st, ev)
    if ev.group then return SLATE.tick(st, ev) end
    local melee = ev.spell == "Melee" or not ev.icon
    local tag = (ev.record and ("best \194\183 was " .. fmt(ev.record)))
        or (ev.overkill and ("crit \194\183 " .. fmt(ev.overkill) .. " overkill"))
        or (ev.crit and "crit") or nil
    SLATE.outLine(st, ev, { amt = fmt(ev.amt), name = ev.spell or "Melee", ncol = melee and SNAME or MyClassColor(),
        frac = (ev.amt or 0) / BestAny(ev), col = ev.crit and W or SAMT,
        hcol = (ev.record or ev.crit) and GOLD or W, ha = ev.record and 1 or (ev.crit and 0.85 or 0.45), tag = tag })
end
SLATE.tick = function(st, ev)
    local g = st.groups[ev.gkey]
    if not g or g.done or not g.line or g.line.age >= g.line.life then
        g = { total = 0, n = 0, shown = 0 }
        st.groups[ev.gkey] = g
        local multi = ev.group == "multi"
        local L2 = { col = SAMT, ncol = multi and SNAME or MyClassColor() }
        local first = ev
        g.line = SLATE.outLine(st, ev, { life = 3.2, get = function()
            L2.amt = fmt(g.shown)
            L2.name = (g.spell or first.spell or "") .. (g.n > 1 and ("  \195\151" .. g.n) or "")
            L2.frac = g.total / BestAny(first)
            return L2
        end, update = function(s, dt) g.shown = g.shown + (g.total - g.shown) * min(1, dt * 11) end })
        g.line.g, g.line.gkey = g, ev.gkey
    end
    g.total = g.total + (ev.amt or 0)
    g.n = g.n + 1
    g.spell = ev.gname or ev.spell
    g.line.age = min(g.line.age, 0.3)
end
SLATE.miss = function(st, ev)
    if ev.mine then
        SLATE.inLine(st, { amt = ev.what or "", name = ev.spell or "Melee", col = SNAME, frac = 0 })
        return
    end
    SLATE.outLine(st, ev, { amt = ev.what or "", name = ev.spell or "Melee", col = SNAME, frac = 0 })
end
SLATE.taken = function(st, ev)
    SLATE.inLine(st, { amt = "-" .. fmt(ev.amt), name = ev.spell or "Melee", col = SRED, ncol = SNAME,
        frac = (ev.amt or 0) / (ev.maxHP or 10000), hcol = SRED, ha = 0.8,
        tag = ev.resist and (fmt(ev.resist) .. " resisted") or nil, tagCol = SNAME })
end
SLATE.heal = function(st, ev)
    SLATE.inLine(st, { amt = "+" .. fmt(ev.amt), name = ev.who or ev.spell or "", col = SGREEN,
        ncol = CLASSC[ev.whoClass or ""] or W, frac = (ev.amt or 0) / (ev.maxHP or 10000), hcol = SGREEN, ha = 0.8 })
end
SLATE.lowhp = function(st, ev)
    SLATE.inLine(st, { amt = (ev.pct or 0) .. "%", name = ev.mana and "Mana" or "Health",
        col = ev.mana and C("#6ea8ff") or SRED, ncol = ev.mana and C("#a8c8ff") or C("#ff8a7e"),
        frac = (ev.pct or 0) / 100, hcol = ev.mana and C("#6ea8ff") or SRED, ha = 0.8, tag = "low",
        tagCol = ev.mana and C("#6ea8ff") or SRED })
end
SLATE.proc = function(st, ev)
    local name = Caps(ev.spell)
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.12)
        c:R(); c:RT(name, "Friz", 11, C("#ece9e1")); c:RT(ceil((ev.dur or 0) - t) .. "s", "ArialN", 14, SSUB)
        c:RD(TOP.x, TOP.y, 10)
        c:Rect(TOP.x - 60, TOP.y + 11, 120, 2, W, 0.08)
        c:Rect(TOP.x - 60, TOP.y + 11, 120 * (1 - t / (ev.dur or 30)) * easeOut(t / 0.3), 2, W, 0.55)
    end }, st.top)
end
SLATE.alert = function(st, ev)
    local name = Caps(ev.spell)
    st:Add({ life = 2.2, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.12)
        c:R(); c:RT(name, "Friz", 11, GOLD); c:RT("ready", "ArialN", 14, SSUB); c:RD(MID.x, MID.y, 10)
        c:Rect(MID.x - 70, MID.y + 11, 140, 2, GOLD, 0.5 + 0.5 * abs(sin(t * 5)))
    end }, st.top)
end
SLATE.kill = function(st, ev)
    for _, l in ipairs(st:Feed("out", ev.hit)) do
        if not l.ending then l.ending = true; l.life = l.age + 0.25 end
    end
    local bg = C("#0d0d11")
    local bestAmt = fmt(ev.bestAmt)
    local frac = (ev.bestAmt or 0) / (ev.bestAny or 6240)
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        local x, y, w, h = OX - 52, OY - 118 + 8 * (1 - easeOut(t / 0.3)), 250, 86
        c.a = fade(t, s.life, 0.15) * fin(t - 0.15, 0.2)
        c:Rect(x, y, w, h, bg, 0.8)
        Edge(c, x, y, w, h, W, 0.1)
        c:Text(ev.name or "", x + 12, y + 17, "Friz", 13, W, 0, "LEFT")
        c:Text(ev.time or "", x + w - 12, y + 17, "ArialN", 15, SSUB, 0, "RIGHT")
        c:Rect(x + 12, y + 31, w - 24, 1, W, 0.08)
        c:R()
        c:RT(fmt(ev.dps), "ArialN", 15, W); c:RT("dps", "ArialN", 13, SSUB)
        c:RT(tostring(ev.hits or 0), "ArialN", 15, W); c:RT("hits", "ArialN", 13, SSUB)
        c:RT((ev.critPct or 0) .. "%", "ArialN", 15, W); c:RT("crit", "ArialN", 13, SSUB)
        c:RD(x + 12, y + 46, 5, "LEFT")
        c:R(); c:RT("best", "ArialN", 13, SSUB); c:RT(ev.best or "", "ArialN", 14, MyClassColor())
        c:RT(bestAmt, "ArialN", 15, GOLD)
        c:RD(x + 12, y + 68, 6, "LEFT")
        local fw = (w - 24) * easeOut((t - 0.3) / 0.5) * clamp(frac)
        if fw > 0 then c:Rect(x + 12, y + 78, fw, 2, GOLD, 1) end
    end }, ev.hit)
end

---------------------------------------------------------------------------
-- Gilded: new records
---------------------------------------------------------------------------

local GILD = {}
L.gilded = GILD
local function Pal(a, b, c2, d) return { C(a), C(b), C(c2), C(d) } end
local GP = {
    gold = Pal("#fff7d6", "#ffd65a", "#e3a42c", "#9a6512"), silver = Pal("#ffffff", "#ececf4", "#b7b7c7", "#76768a"),
    arcane = Pal("#ffe2ff", "#f39cff", "#b85ad8", "#6b2a88"), red = Pal("#ffd6cc", "#ff6f55", "#d2321f", "#781208"),
    green = Pal("#ecffdc", "#86f26a", "#38b72c", "#196614"), fire = Pal("#fff0d0", "#ffb04a", "#e0661c", "#7a2a08"),
    frost = Pal("#f0ffff", "#a8f0ff", "#4cb8e0", "#1a5a7a"), shadow = Pal("#f0e8ff", "#c0a8ff", "#7a5ad8", "#3a2470"),
}
L.GP = GP
local GPS = { phys = "silver", holy = "gold", arcane = "arcane", fire = "fire", frost = "frost", nature = "green",
              shadow = "shadow", heal = "green" }
local SPARK = C("#ffe08a")
local GPALE = C("#e9d6a0")

local function sparks(st, at, x, y, n, seed, dir, spread, vmin, vmax, gy, delay, wspan)
    seed = seed or 1
    vmin, vmax, gy = vmin or 90, vmax or 230, gy or 340
    for i = 0, n - 1 do
        local a = dir and (dir + (rnd(seed + i) - 0.5) * spread) or rnd(seed + i) * TAU
        local sp = vmin + rnd(seed + i * 3.1) * (vmax - vmin)
        local vx, vy = cos(a) * sp, sin(a) * sp
        local life = 0.55 + rnd(seed + i * 7.7) * 0.45
        local sz = 1.6 + rnd(seed + i * 5.3) * 2.2
        local dl = delay and rnd(seed + i * 2.2) * delay or 0
        local ox = wspan and (rnd(seed + i * 9.1) - 0.5) * wspan or 0
        st:Add({ life = life + dl, draw = function(c, s)
            local t = s.age - dl
            if t < 0 then return end
            local k = t / life
            c.add = true
            c.a = 1 - k
            local r = sz * (1 - k * 0.6)
            c:Img(Pen.STAR, x + ox + vx * t, y + vy * t + 0.5 * gy * t * t, r * 5, r * 5, SPARK, 1, 0, 1, 0, 1, pi / 4)
        end }, at)
    end
end
local function trimH(c, x, y, w, h)
    local tl = h * 4
    local i = 0
    while i < w do
        local ww = min(tl, w - i)
        c:Img(Pen.GILT .. "trim_h", x + i + ww / 2, y + h / 2, ww, h, nil, 1, 0, ww / tl, 0, 1)
        i = i + tl
    end
end
local function corner(c, x, y, s, sx, sy)
    -- (the art faces top left; flipped by its coords)
    local l, r = 0, 1
    local t, b = 0, 1
    if sx < 0 then l, r = 1, 0 end
    if sy < 0 then t, b = 1, 0 end
    c:Img(Pen.GILT .. "corner", x + sx * s / 2, y + sy * s / 2, s, s, nil, 1, l, r, t, b)
end
local CART1, CART2, CEDGE = C("#2b1f0b"), C("#0e0a05"), C("#6e5421")
local function cartouche(c, x, y, w, h, cs)
    cs = cs or 22
    local Lx, T = x - w / 2, y - h / 2
    c:Rect(Lx - 1, T - 1, w + 2, h + 2, BLACK, 1)
    c:Grad(Lx, T, w, h, "V", CART1, 0.95, CART2, 0.95)
    Edge(c, Lx, T, w, h, CEDGE, 1)
    trimH(c, Lx + 8, T - 4, w - 16, 8)
    trimH(c, Lx + 8, T + h - 4, w - 16, 8)
    local o = 5
    corner(c, Lx - o, T - o, cs, 1, 1)
    corner(c, Lx + w + o, T - o, cs, -1, 1)
    corner(c, Lx - o, T + h + o, cs, 1, -1)
    corner(c, Lx + w + o, T + h + o, cs, -1, -1)
end
local MEDALBG = C("#140e05")
local function medal(c, x, y, n, pulse)
    local s = 22 * (1 + 0.25 * pulse * pulse)
    c:Rect(x - s / 2 + 1, y - s / 2 + 1, s - 2, s - 2, MEDALBG, 1)
    c:Img(Pen.GILT .. "bezel", x, y, s, s)
    c:GText(tostring(n), x, y + 1, 12 * (1 + 0.25 * pulse * pulse), GP.gold, "Friz", "CENTER", nil, 1)
end

GILD.banner = function(st, title, sub, life, shower)
    local x, y = MID.x, MID.y
    if shower then
        sparks(st, st.top, x, y + 30, 34, st.clock * 7 + 3, pi / 2, 1.2, 20, 80, 240, 1.0, 320)
        sparks(st, st.top, x, y, 22, st.clock * 3 + 1)
    end
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local sc = t < 0.18 and (0.6 + 0.4 * easeOut(t / 0.18)) or 1
        c.a = fade(t, life, 0.2) * fin(t, 0.1)
        c:Translate(x, y)
        c:Scale(sc)
        cartouche(c, 0, 0, 380, 64, 24)
        c:GText(title, 0, -9, 28, GP.gold, "Morpheus", "CENTER", (t - 0.2) / 0.6, 2)
        c:Text(sub, 0, 17, "Friz", 12, GPALE, 0)
    end }, st.top)
end
GILD.out = function(st, ev)
    if ev.group then return GILD.tick(st, ev) end
    local crit = ev.crit
    local big = crit and (ev.amt or 0) >= (ev.bigAt or 4000)
    local x0 = st:Lane(ev) * (crit and 0.6 or 1)
    local y0 = HIT.y - (crit and 8 or 0)
    local pal = crit and GP.gold or GP[GPS[ev.school or "phys"] or "silver"]
    local str = fmt(ev.amt)
    local life = big and 2.0 or (crit and 1.6 or 1.3)
    local over = ev.overkill and (fmt(ev.overkill) .. " overkill") or nil
    local pet = ev.pet and 0.8 or 1
    if crit then sparks(st, ev.hit, x0, y0, big and 30 or 18, (ev.amt or 1) * 0.031) end
    if ev.record then
        GILD.banner(st, "New Record", (ev.spell or "") .. " " .. str .. "   \194\183   was " .. fmt(ev.record), 1.9, true)
    end
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local y = y0 - (big and 30 or (crit and 50 or 66)) * easeOut(t / life)
        local sc = crit and (t < 0.12 and (0.7 + 0.5 * easeOut(t / 0.12)) or (1.2 - 0.2 * easeOut((t - 0.12) / 0.3)))
            or (0.85 + 0.15 * easeOut(t / 0.1))
        c.a = fade(t, life, 0.3)
        c:Translate(x0, y)
        c:Scale(sc * pet)
        local size = crit and 30 or 20
        local iw = ev.icon and (crit and 26 or 18) or 0
        local nw = c:W("Friz", size, str, 2)
        local w = nw + (iw > 0 and iw + 7 or 0)
        if big then cartouche(c, 0, 0, w + 50, 52) end
        local x = -w / 2
        if iw > 0 then c:Icon(ev.icon, x + iw / 2, 0, iw, "bezel"); x = x + iw + 7 end
        c:GText(str, x + nw / 2, 1, size, pal, "Friz", "CENTER", crit and (t - 0.12) / 0.4 or nil, 2)
        if over then c:GText(over, 0, big and 40 or (size * 0.6 + 12), 11, GP.silver, "Friz", "CENTER", nil, 1) end
    end }, ev.hit)
end
GILD.tick = function(st, ev)
    local cons = ev.group == "tick"
    local lx = cons and 160 or st:Lane(ev)
    st:Group(ev, cons and (ev.hold or 1.4) or 0.9, function(g, s) return function(c)
        local y = cons and (HIT.y - 36) or (HIT.y - 4 - 44 * easeOut(s.age / 1.4))
        c.a = galpha(s)
        local pal = cons and GP[GPS[g.ev.school or "holy"] or "gold"] or GP.silver
        local str = fmt(g.shown)
        local nw = c:W("Friz", 20, str, 2)
        local w = 18 + 6 + nw + (g.n > 1 and 30 or 0)
        local x = lx - w / 2
        c:Icon(g.icon or ev.icon or "Interface\\Icons\\Spell_Nature_Windfury", x + 9, y, 18, "bezel")
        x = x + 24
        c:GText(str, x + nw / 2, y + 1, 20, pal, "Friz", "CENTER", nil, 2)
        x = x + nw
        if g.n > 1 then medal(c, x + 18, y, g.n, g.pulse) end
        c:Text(g.spell or "", lx, y + 20, "Friz", 11, GPALE, 1)
    end end)
end
GILD.miss = function(st, ev)
    local at, mx, my = MissAt(st, ev)
    local x0 = mx or st:Lane(ev)
    st:Add({ life = 1.1, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.35)
        c:GText(ev.what or "", x0, my - 56 * easeOut(s.age / s.life), 17, GP.silver, "Friz", "CENTER", nil, 2)
    end }, at)
end
GILD.taken_ = function(st, ev, pos, pal, sign, sub)
    local str = sign .. fmt(ev.amt)
    st:Add({ life = 1.8, draw = function(c, s)
        local y = pos.y - 74 * easeOut(s.age / s.life)
        c.a = fade(s.age, s.life, 0.3)
        local nw = c:W("Friz", 20, str, 2)
        local w = 18 + 6 + nw
        c:Icon(ev.icon, pos.x - w / 2 + 9, y, 18, "bezel")
        c:GText(str, pos.x - w / 2 + 24 + nw / 2, y + 1, 20, pal, "Friz", "CENTER", nil, 2)
        if sub then c:Text(sub, pos.x, y + 20, "Friz", 11, GPALE, 1) end
    end }, st.you)
end
GILD.taken = function(st, ev)
    GILD.taken_(st, ev, st.IN, ev.school == "arcane" and GP.arcane or GP.red, "-",
        ev.resist and (fmt(ev.resist) .. " resisted") or nil)
end
GILD.heal = function(st, ev) GILD.taken_(st, ev, st.HEAL, GP.green, "+", ev.who) end
GILD.proc = function(st, ev)
    local dur = ev.dur and (floor(ev.dur + 0.5) .. "s") or ""
    st:Add({ life = 2.6, draw = function(c, s)
        local t = s.age
        c.a = fade(t, s.life, 0.15) * fin(t, 0.12)
        c:Translate(TOP.x, TOP.y + 4 - 10 * (1 - easeOut(t / 0.25)))
        local nw = c:W("Morpheus", 20, ev.spell or "", 2)
        local w = 26 + 10 + nw + 14 + 30 + 24
        local Lx = -w / 2
        c:Rect(Lx - 1, -18, w + 2, 36, BLACK, 1)
        c:Grad(Lx, -17, w, 34, "V", CART1, 0.94, CART2, 0.94)
        trimH(c, Lx + 4, -21, w - 8, 8)
        trimH(c, Lx + 4, 13, w - 8, 8)
        c:Icon(ev.icon, Lx + 12 + 13, 0, 26, "bezel")
        c:GText(ev.spell or "", Lx + 12 + 26 + 10, 1, 20, GP.gold, "Morpheus", "LEFT", nil, 1)
        c:Text(dur, -Lx - 12, 1, "Friz", 12, GPALE, 0, "RIGHT")
    end }, st.top)
end
GILD.alert = function(st, ev)
    st:Add({ life = 2.2, draw = function(c, s)
        local t = s.age
        local sc = 1 + 0.06 * sin(t * 7)
        c.a = fade(t, s.life, 0.15) * fin(t, 0.1)
        c:Translate(MID.x, MID.y)
        c:Scale(sc)
        c:Icon(ev.icon, 0, 0, 38, "bezel")
        -- the glint: a pale band across the bezel, looping
        local p = ((t * 1.25) % 1) * 1.6 - 0.3
        if p > -0.15 and p < 1.15 then
            c.add = true
            c:Img(Pen.GLOW, -19 + 38 * p, 0, 14, 44, C("#fffadc"), 0.75, 0, 1, 0, 1, -pi / 4)
            c.add = false
        end
        c:GText(ev.spell or "", 0, 38, 20, GP.gold, "Morpheus", "CENTER", nil, 1)
    end }, st.top)
end
GILD.lowhp = function(st, ev)
    if ev.mana then return F.lowhp(st, ev) end
    local red = C("#a8180a")
    st:Add({ life = 1.7, under = true, draw = function(c, s)
        local t = s.age
        local Wd, Hd = st:ScreenSize()
        c.add = true
        c:Img(Pen.LOWHP, Wd / 2, Hd / 2, Wd, Hd, red, fade(t, s.life, 0.3) * (0.55 + 0.45 * sin(t * 7)))
    end }, st.screen)
end
GILD.kill = function(st, ev)
    local kb = ev.killingBlow and ("   \194\183   killing blow " .. fmt(ev.killingBlow)) or ""
    GILD.banner(st, (ev.name or "") .. " slain", (ev.time or "") .. "   \194\183   " .. fmt(ev.dps) .. " dps" .. kb, 2.4, true)
end

---------------------------------------------------------------------------
-- Classic: the game's own way
---------------------------------------------------------------------------

local CLASSIC = {}
L.classic = CLASSIC
local CWHITE, CYELLOW = C("#ffffff"), C("#ffff00")
-- The game's scrolling text over your head: a line that would land on the one before it waits until that one has
-- moved up a line (as the game's own does).
CLASSIC.fct = function(st, text, col, size, life, dx)
    st.fctLane = ((st.fctLane or 0) % 3) + 1
    local x = ME.x + (dx or ({ 0, -18, 18 })[st.fctLane])
    life = life or 1.9
    local start = max(st.clock, st.fctNext or 0)
    st.fctNext = start + 0.42
    local delay = start - st.clock
    st:Add({ life = life + delay, draw = function(c, s)
        local t = s.age - delay
        if t < 0 then return end
        local y = ME.y - 62 - 92 * (t / life)
        c.a = fade(t, life, 0.35)
        c:Text(text, x, y, "Friz", size or 22, col, 1)
    end }, st.you)
end
CLASSIC.out = function(st, ev)
    local x0 = st:Lane(ev) * 0.4
    local col = (ev.school == "phys" or not ev.school) and CWHITE or CYELLOW
    if ev.k == "heal" or ev.school == "heal" then col = C("#1aff1a") end
    local str = tostring(floor((ev.amt or 0) + 0.5))
    local crit = ev.crit
    local life = crit and 1.6 or 1.4
    local pet = ev.pet and 0.8 or 1
    if ev.record then
        CLASSIC.fct(st, "New best: " .. (ev.spell or "") .. " " .. str, C("#ffd100"), 18, 2.2, 0)
    end
    st:Add({ life = life, draw = function(c, s)
        local t = s.age
        local y = HIT.y - 6 - (crit and 48 or 62) * (t / life)
        local sc = 1
        if crit then
            sc = (t < 0.06 and (1 + 1.1 * (t / 0.06))) or (t < 0.22 and (2.1 - 0.6 * easeOut((t - 0.06) / 0.16))) or 1.5
        end
        c.a = fade(t, life, 0.4)
        c:Text(str, x0, y, "Skurri", floor(24 * sc * pet + 0.5), col, 1)
    end }, ev.hit)
end
CLASSIC.tick = CLASSIC.out
CLASSIC.miss = function(st, ev)
    if ev.mine then return CLASSIC.fct(st, ev.what or "", CWHITE, 20) end
    local x0 = st:Lane(ev) * 0.4
    st:Add({ life = 1.3, draw = function(c, s)
        c.a = fade(s.age, s.life, 0.4)
        c:Text(ev.what or "", x0, HIT.y - 6 - 56 * (s.age / s.life), "Skurri", 22, CWHITE, 1)
    end }, ev.hit)
end
CLASSIC.taken = function(st, ev)
    local amt = tostring(floor((ev.amt or 0) + 0.5))
    CLASSIC.fct(st, "-" .. amt .. (ev.resist and (" (" .. ev.resist .. " resisted)") or ""), C("#ff1a1a"))
end
CLASSIC.heal = function(st, ev) CLASSIC.fct(st, "+" .. tostring(floor((ev.amt or 0) + 0.5)), C("#1aff1a")) end
CLASSIC.proc = function(st, ev) CLASSIC.fct(st, "<" .. (ev.spell or "") .. ">", C("#ffff80"), 20) end
CLASSIC.lowhp = function(st, ev)
    if not ev.mana then
        st:Add({ life = 1.8, under = true, draw = function(c, s)
            local t = s.age
            local Wd, Hd = st:ScreenSize()
            c.add = true
            c.a = fade(t, s.life, 0.3) * (0.45 + 0.55 * abs(sin(t * 4)))
            c:Img(Pen.LOWHP, Wd / 2, Hd / 2, Wd, Hd)
        end }, st.screen)
    end
    CLASSIC.fct(st, ev.mana and "Low Mana" or "Low Health", ev.mana and C("#6ea8ff") or C("#ff1a1a"), 24, nil, 0)
end
CLASSIC.alert = function(st, ev)
    local call = (ev.spell or "") .. "!"
    st:Add({ life = 2.3, draw = function(c, s)
        local t = s.age
        local base = fade(t, s.life, 0.15) * fin(t, 0.08)
        local sz = 36
        local gl = sz * 1.75
        c.a = base * (0.55 + 0.45 * abs(sin(t * 5)))
        c:Img(Pen.ALERT, MID.x, MID.y, gl, gl, nil, 1, 3 / 128, 67 / 128, 71 / 256, 135 / 256)
        c.a = base
        c:Icon(ev.icon, MID.x, MID.y, sz, "quick")
        c:Text(call, MID.x, MID.y + 46, "Friz", 24, CYELLOW, 1)
    end }, st.top)
end
CLASSIC.kill = function(st, ev) CLASSIC.fct(st, "Killing Blow!", C("#ffd100"), 24, 2.2, 0) end

-- Looks by key (the UI looks' keys)
L.ORDER = { "flat", "halo", "sigil", "slate", "gilded", "classic" }
L.SIGNATURE = { flat = "Rolling totals", halo = "Crit rings", sigil = "Stamp and shatter",
                slate = "Hairlines and a receipt", gilded = "New records", classic = "Reactive alerts" }

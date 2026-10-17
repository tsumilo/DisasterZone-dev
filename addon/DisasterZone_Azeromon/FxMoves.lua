if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/FxMoves.lua", ...) then return end -- DisasterZone_Azeromon/FxMoves.lua
-- The moves' effects, drawn by Fx.lua. 0.41 (step 1): the Beast and Fire kits and their big casts' wind-ups; every
-- other move keeps the battle's lunge until its type is drawn (the marks and all eight guard shells are in Fx.lua).
-- A recipe is a timeline on a run: r:At(t, fn) once, r:Span(t0, t1, fn(progress, age)) every frame in between;
-- X is the move's context (F.Context: a / b the sides, A / B their points, dir, muzzle, hit, ground, combo, miss,
-- guarded). Times are seconds; places are game pixels (3 UI pixels) from the battle layer's top-left, y down.
local addonName, ns = ...

local F = ns.AzeroFx
local M = F.MOVES
local PAL, C = F.PAL, F.C
local floor, max, min, sin, cos, pi = math.floor, math.max, math.min, math.sin, math.cos, math.pi
local random = math.random
local TAU = pi * 2
local rr, eOut, eIn, bump, lerp = F.rr, F.eOut, F.eIn, F.bump, F.lerp

local WHITE = F.WHITE
local BLOOD = F.BLOOD
local BLOOD4 = { BLOOD[2], BLOOD[1], BLOOD[3], BLOOD[4] }        -- a drop: falling, fast, its splat
local FIRE5 = { PAL.FIRE.d, PAL.FIRE.m, PAL.FIRE.l, PAL.FIRE.h, PAL.FIRE.w }
local ORANGE = C("#ff7a26")
local FUR = { PAL.BEAST.h, PAL.BEAST.l, PAL.BEAST.m }

local function every(st, k, iv, dt, fn)
    st[k] = (st[k] or 0) + dt
    local n = 0
    while st[k] >= iv and n < 4 do st[k] = st[k] - iv n = n + 1 fn() end
end

-- tufts of fur fly off a clawed beast, away from the attacker
local function FurBits(X, n)
    F.Spray(X.hit[1], X.hit[2], n, { kind = "px", cols = FUR, s = { 25, 60 }, ang = X.dir > 0 and -0.6 or pi + 0.6, spread = pi,
            ay = 160, ground = X.ground[2] + 2, life = { 0.35, 0.6 } })
end
local function Hits(X) return not X.miss and not X.guarded end

---------------------------------------------------------------------------
-- Beast: claws, blood and dust
---------------------------------------------------------------------------

M.kclaw = { desc = "Three claw rakes, fur flies", play = function(r, X)
    r.dur = 0.58
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.32, 10)
    F.Slashes(r, X, { t0 = 0.14, n = 3, len = 15, gap = 4, cols = { PAL.BEAST.m, PAL.BEAST.h, WHITE } })
    F.React(r, X, 0.18, { knock = 2 })
    r:At(0.18, function() if Hits(X) then FurBits(X, 6) end end)
end }

M.krend = { desc = "One deep slash, it starts to bleed", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.34, 10)
    F.Slashes(r, X, { t0 = 0.15, n = 1, len = 22, th = 3, wipe = 0.1, hold = 0.1, out = 0.14, bend = 3, cols = { BLOOD[3], BLOOD[1], WHITE } })
    F.React(r, X, 0.2, { knock = 3, flash = C("#ffd0c8") })
    r:At(0.22, function()
        if not Hits(X) then return end
        F.Spray(X.hit[1], X.hit[2], 9, { kind = "drop", cols = BLOOD4, s = { 20, 55 }, ang = -pi / 2, spread = pi * 1.3, ay = 240,
                ground = X.ground[2] + 1, jx = 3, life = { 0.9, 1.3 }, onLand = F.Splat })
    end)
end }

M.kferobite = { desc = "Jaws snap shut; with Bleeding up, the wound bursts", play = function(r, X)
    r.dur = X.combo and 0.9 or 0.72
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.36, 14)
    F.Jaws(r, X, { t0 = 0.08, close = 0.12, hold = 0.14, pal = { m = PAL.BEAST.m, h = PAL.BEAST.h, w = WHITE },
                   gum = C("#8e2a22"), gumD = BLOOD[4] })
    F.React(r, X, 0.2, { knock = 3, shake = 1 })
    F.ComboFx(r, X, 0.2)
    r:At(0.2, function()
        if X.combo and not X.miss then
            F.Spray(X.hit[1], X.hit[2], 16, { kind = "drop", cols = BLOOD4, s = { 40, 95 }, ay = 260, ground = X.ground[2] + 2,
                    life = { 0.8, 1.2 }, onLand = F.Splat })
        end
    end)
end }

M.kmaul = { desc = "Crouches, then leaps through two crossing rakes", play = function(r, X)
    r.dur = 1.05
    F.Clip(X.a, 16)
    local vx, vy = X.B.c[1] - X.A.c[1], X.B.c[2] - X.A.c[2]
    local trail = {}
    r:Span(0, 0.62, function(p)
        local k = p < 0.45 and eOut(p / 0.45) or 1 - eIn((p - 0.45) / 0.55)
        local ox, oy = vx * 0.5 * k, vy * 0.5 * k - (p < 0.45 and 14 * bump(p / 0.45) or 0)
        F.Offset(X.a, ox, oy)
        if p < 0.45 then
            table.insert(trail, 1, { ox, oy })
            if #trail > 6 then trail[7] = nil end
            local g3, g5 = trail[4] or trail[#trail], trail[6] or trail[#trail]
            F.Ghost(X.a, g3[1], g3[2], 0.35, PAL.BEAST.h)
            F.Ghost(X.a, g5[1], g5[2], 0.18, PAL.BEAST.h)
        end
    end)
    local cols = { PAL.BEAST.d, PAL.BEAST.h, WHITE }
    F.Slashes(r, X, { t0 = 0.27, n = 1, len = 26, th = 3, bend = 4, ang = X.dir > 0 and 2.1 or pi - 2.1, cols = cols, hold = 0.1 })
    F.Slashes(r, X, { t0 = 0.31, n = 1, len = 26, th = 3, bend = -4, ang = X.dir > 0 and 1.0 or pi - 1.0, cols = cols, hold = 0.1 })
    F.React(r, X, 0.3, { knock = 4, shake = 3, shakeDur = 0.28, stop = 0.06 })
    r:At(0.3, function()
        if not Hits(X) then return end
        FurBits(X, 9)
        F.Spray(X.ground[1], X.ground[2], 6, { kind = "puff", cols = F.DUST, s = { 20, 40 }, ang = 0, spread = TAU, jy = 1,
                life = { 0.5, 0.8 }, r0 = 1.5, r1 = 4, drag = 3, a = 0.85 })
    end)
    r:Span(0.3, 0.6, function(p)
        if X.miss then return end
        local rad = 4 + 22 * eOut(p)
        F.Ring(X.ground[1], X.ground[2], rad, max(1, rad * 0.3), 1, p < 0.4 and F.DUST[1] or F.DUST[2], 1 - p, "under")
    end)
end }

M.kskullbash = { desc = "A headlong charge; stars circle its head", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.28, 18)
    if Hits(X) then
        F.Bonk(r, 0.12, { X.B.head[1] - X.dir * 3, X.B.head[2] + 4 }, { C("#ffd84a"), WHITE }, 6)
        F.Daze(r, X.b, 0.16, 0.45)
    end
    F.React(r, X, 0.12, { knock = 3, shake = 1 })
end }

-- Savage Maul's turn of waiting: it crouches, dust puffs at its feet, its claws glint
F.CASTS.maul = { focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] + p.h * 0.2 } end,
    windup = function(s, st, dt)
        local p = F.Pts(s)
        F.Offset(s, s == "ally" and -2 or 2, 2)
        every(st, "p", 0.42, dt, function()
            F.Emit({ kind = "puff", x = p.feet[1] + rr(-p.w * 0.4, p.w * 0.4), y = p.feet[2], vx = rr(-8, 8), vy = -6, life = 0.6,
                     r0 = 1, r1 = 3, cols = F.DUST, a = 0.8 })
        end)
        every(st, "g", 0.55, dt, function()
            F.Emit({ kind = "glint", x = p.c[1] + (s == "ally" and 1 or -1) * p.w * 0.3, y = p.c[2] + p.h * 0.25, life = 0.3,
                     cols = { PAL.BEAST.h, WHITE } })
        end)
        F.Glow(p.c[1], p.c[2], p.w, C("#e8a060"), 0.18 + 0.1 * sin(st.tw * 7), "under")
    end }
F.CAST_OF.kmaul = "maul"

---------------------------------------------------------------------------
-- Fire: fireballs, flames, embers and smoke
---------------------------------------------------------------------------

-- a comet of fire from the muzzle (or o.from) to the hit; o: t0, dur, r (head), len (tail), arc, embers, smoke
local function Fireball(r, X, o)
    F.Fly(r, X, { t0 = o.t0, dur = o.dur, arc = o.arc or 3, from = o.from, draw = function(x, y, q, vx)
        local g = F.Comet(o.r, o.len, FIRE5, floor(r.t * 14) % 3)
        F.Stamp(g, floor(x + 0.5) - (vx >= 0 and g.w - o.r - 1 or o.r), floor(y + 0.5) - o.r, nil, { flip = vx < 0 })
        F.Glow(x, y, o.r * 4 + 4, ORANGE, o.r >= 5 and 0.65 or 0.5)
    end, trail = function(x, y)
        for _ = 1, o.embers or 1 do
            F.Emit({ kind = "ember", x = x + rr(-1, 1) * (o.r >= 5 and 2 or 1), y = y + rr(-1, 1), vx = rr(-6, 6), vy = rr(-14, -4),
                     ay = -20, life = rr(0.2, 0.4), cols = F.FIRE_R })
        end
        if o.smoke and random() < o.smoke then
            F.Emit({ kind = "puff", x = x, y = y, vy = -8, life = 0.7, r0 = 1.5, r1 = 3.5, cols = F.SMOKE, a = 0.55 })
        end
    end })
end

M.kscorch = { desc = "A small fireball, a lick of flame", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 54)
    Fireball(r, X, { t0 = 0.12, dur = 0.24, r = 2, len = 4 })
    F.React(r, X, 0.36, { knock = 2, flash = C("#ffd080") })
    r:At(0.36, function()
        if X.miss then return end
        F.Spray(X.hit[1], X.hit[2] + 2, 3, { kind = "flame", pal = F.FLAME, s = { 5, 12 }, ang = -pi / 2, spread = 1.4, ay = -10, life = { 0.3, 0.45 } })
        F.Spray(X.hit[1], X.hit[2], 7, { kind = "ember", cols = F.FIRE_R, s = { 20, 50 }, ay = -20, drag = 2, life = { 0.3, 0.5 } })
    end)
    r:Span(0.36, 0.5, function(p) F.Glow(X.hit[1], X.hit[2], 18, C("#ff8a2a"), 0.6 * (1 - p)) end)
end }

M.kimmolate = { desc = "A ring of fire rises at its feet", play = function(r, X)
    r.dur = 0.78
    F.Clip(X.a, 54)
    r:Span(0.1, 0.62, function(p, lt)
        local g = X.ground
        local rx = X.B.w * 0.45 + 3
        local up = p < 0.3 and p / 0.3 or p > 0.75 and (1 - p) / 0.25 or 1
        for i = 0, 5 do
            local a = i * TAU / 6 + 0.3
            local x, y = g[1] + cos(a) * rx, g[2] + sin(a) * 3 + 1
            local fr = (floor(lt * 12) + i) % 3 + 1
            local lay = sin(a) < 0 and "under" or "over"
            if up > 0.55 then F.StampB(F.GL.flame[fr], x, y, F.FLAME, { lay = lay })
            elseif up > 0.15 then F.StampB(F.GL.flameS[fr], x, y, F.FLAME, { lay = lay }) end
        end
        F.Glow(g[1], g[2] - 4, rx * 2.2, ORANGE, 0.45 * up, "under")
    end)
    r:At(0.15, function()
        F.Spray(X.ground[1], X.ground[2], 10, { kind = "ember", cols = F.FIRE_R, s = { 15, 40 }, ang = -pi / 2, spread = 1.2, ay = -30,
                jx = X.B.w * 0.4, life = { 0.4, 0.8 } })
    end)
    F.React(r, X, 0.24, { knock = 1, flash = C("#ffb070") })
end }

M.kincinerate = { desc = "A big fireball bursts; on an Immolated foe the flames erupt", play = function(r, X)
    r.dur = X.combo and 1.0 or 0.82
    F.Clip(X.a, 54)
    Fireball(r, X, { t0 = 0.12, dur = 0.26, r = 3, len = 6, embers = 2 })
    F.Explode(r, 0.38, X.hit, 7, F.FIRE_R)
    F.React(r, X, 0.38, { knock = 3, shake = 1 })
    F.ComboFx(r, X, 0.4)
    if X.combo and not X.miss then
        r:Span(0.4, 0.85, function(p, lt)
            local g = X.ground
            local up = p < 0.25 and p / 0.25 or p > 0.7 and (1 - p) / 0.3 or 1
            for i = 0, 4 do
                local dx = (i - 2) * X.B.w * 0.18
                local fr = (floor(lt * 14) + i) % 3 + 1
                if up > 0.5 then F.StampB(F.GL.flameT[fr], g[1] + dx, g[2] + 1 - (i % 2) * 3, F.FLAME)
                else F.StampB(F.GL.flame[fr], g[1] + dx, g[2] + 1, F.FLAME) end
            end
            F.Glow(g[1], g[2] - 10, 34, ORANGE, 0.6 * (1 - p))
        end)
        r:At(0.42, function()
            F.Spray(X.ground[1], X.ground[2] - 6, 20, { kind = "ember", cols = F.FIRE_R, s = { 30, 70 }, ang = -pi / 2, spread = 1.6, ay = -20,
                    life = { 0.5, 0.9 } })
        end)
    end
end }

-- Pyroblast's orb, held out in front of the caster at chest height (clear of the HP boxes)
local function PyroFocus(s)
    local p = F.Pts(s)
    if s == "ally" then return { p.r + 5, p.top + p.h * 0.3 } end
    return { p.l - 5, p.top + p.h * 0.35 }
end
local EMBERS_IN = { F.FIRE_R[4], F.FIRE_R[3], F.FIRE_R[2], F.FIRE_R[1] }
F.CASTS.pyro = { focus = PyroFocus, windup = function(s, st, dt)
    -- the orb swells as embers are drawn into it; once full it throbs
    local f = PyroFocus(s)
    local rad = st.tw < 0.8 and 1 + 4 * eOut(st.tw / 0.8) or 5 + (floor(st.tw * 8) % 2)
    every(st, "e", 0.07, dt, function()
        local a, R = rr(0, TAU), rr(14, 18)
        F.Seek(f[1] + cos(a) * R, f[2] + sin(a) * R * 0.7, f[1], f[2], 0.42, EMBERS_IN, 0)
    end)
    F.DrawGen(F.Ball(floor(rad + 0.5), FIRE5, "core"), f[1], f[2])
    if rad >= 3 then F.StampB(F.GL.flameS[floor(st.tw * 12) % 3 + 1], f[1] + 1, f[2] - floor(rad + 0.5) + 1, F.FLAME) end
    F.Glow(f[1], f[2], 8 + rad * 2.5, ORANGE, 0.55)
end }
F.CAST_OF.kpyroblast = "pyro"

M.kpyroblast = { desc = "A fire orb swells, then flies as a great fireball", play = function(r, X)
    r.dur = 1.15
    F.Clip(X.a, 54)
    Fireball(r, X, { t0 = 0.06, dur = 0.36, arc = 5, from = PyroFocus(X.a), r = 5, len = 10, embers = 3, smoke = 0.45 })
    F.Explode(r, 0.42, X.hit, 12, F.FIRE_R, { puffs = 6, sparks = 20 })
    F.React(r, X, 0.42, { knock = 4, shake = 3, shakeDur = 0.32, stop = 0.06 })
    r:At(0.45, function()
        if Hits(X) then F.Emit({ kind = "decal", x = X.ground[1], y = X.ground[2], r0 = 11, life = 1.3, cols = { C("#1a0e08") }, a = 0.55 }) end
    end)
end }

---------------------------------------------------------------------------
-- Signature moves (sf_ / sc_ ids: a species' own move, of its type or another): a shape picked by the words in the
-- move's name, drawn in its type's colours, with a small gold glint as it starts. Step 1 draws Beast and Fire ones;
-- the others keep the lunge until their type is drawn.
---------------------------------------------------------------------------

local SIG_TYPES = { BEAST = true, FIRE = true }
local SHAPES = {
    { "jaws", { "Bite", "Jaw", "Gnaw", "Pincer", "Fang" } },
    { "flurry", { "Frenzy", "Flurry", "Thrash", "Feral Rage" } },
    { "cleave", { "Cleave", "Scythe", "Sweep" } },
    { "rakes", { "Claw", "Rake", "Ravage", "Rend", "Maul", "Strike", "Slash", "Swipe" } },
    { "charge", { "Pounce", "Gore", "Charge", "Dive", "Roll", "Spin", "Burrow" } },
    { "breath", { "Breath", "Buffet", "Jet", "Shadow Flame", "Inferno" } },
    { "storm", { "Firestorm" } },
    { "lob", { "Toss", "Throw", "Axe", "Headhunter", "Cannon" } },
}
local function ShapeOf(name)
    for _, s in ipairs(SHAPES) do
        for _, w in ipairs(s[2]) do if name:find(w, 1, true) then return s[1] end end
    end
    return "bolt"
end
F.ShapeOf = ShapeOf

local AXE_HEAD = { PAL.MECH.o, PAL.MECH.d, PAL.MECH.m, PAL.MECH.l, PAL.MECH.h, WHITE }
local function SigPlay(shape, r, X, cast)
    local p = X.pal
    local fire = X.type == "FIRE"
    local function scatter(pt, n)
        if fire then F.Spray(pt[1], pt[2], n, { kind = "ember", cols = F.FIRE_R, s = { 25, 70 }, ay = -20, drag = 1.5, life = { 0.35, 0.7 } })
        else F.Spray(pt[1], pt[2], n, { kind = "px", cols = { p.h, p.l, p.m }, s = { 25, 70 }, ay = 140, drag = 1.5, ground = X.ground[2] + 2, life = { 0.35, 0.7 } }) end
    end
    r:At(0, function() F.Emit({ kind = "glint", x = X.muzzle[1], y = X.muzzle[2] - 2, life = 0.35, cols = { F.GOLD.h, F.GOLD.w } }) end)
    r:Span(0, 0.2, function(q) F.Star(X.muzzle[1], X.muzzle[2] - 2, 26 * bump(q), F.GOLD.h, 0.9) end)
    local steel = { p.d, C("#eef2fa"), WHITE }
    if shape == "jaws" then
        r.dur = cast and 0.86 or 0.72
        F.Clip(X.a, 16)
        F.Lunge(r, X, 0, 0.36, 14)
        F.Jaws(r, X, { t0 = 0.08, close = 0.12, hold = 0.14, w = cast and 22 or nil, n = cast and 5 or 4,
                       pal = { m = p.m, h = p.h, w = p.w }, gum = p.d, gumD = p.o })
        F.React(r, X, 0.2, { knock = cast and 4 or 3, shake = cast and 3 or 1, stop = cast and 0.05 or 0 })
        r:At(0.2, function() if Hits(X) then scatter(X.hit, cast and 12 or 6) end end)
    elseif shape == "flurry" then
        r.dur = 0.95
        F.Clip(X.a, 16)
        F.Lunge(r, X, 0, 0.6, 12)
        local angs = { 2.1, 0.9, 1.7, 1.1, 1.95 }
        for i = 1, 5 do
            local a = X.dir > 0 and angs[i] or pi - angs[i]
            F.Slashes(r, X, { t0 = 0.08 + (i - 1) * 0.07, n = 1, len = 12 + i, th = 2, ang = a, cols = steel, wipe = 0.05, hold = 0.04,
                              at = { X.hit[1] + rr(-3, 3), X.hit[2] + rr(-3, 3) } })
            F.React(r, X, 0.1 + (i - 1) * 0.07, { knock = 1 })
        end
        F.Slashes(r, X, { t0 = 0.5, n = 1, len = 24, th = 3, bend = 4, ang = X.dir > 0 and 2.1 or pi - 2.1, cols = steel, hold = 0.08 })
        F.Slashes(r, X, { t0 = 0.53, n = 1, len = 24, th = 3, bend = -4, ang = X.dir > 0 and 1.0 or pi - 1.0, cols = steel, hold = 0.08 })
        F.React(r, X, 0.53, { knock = 4, shake = cast and 3 or 2, stop = 0.05 })
        r:At(0.53, function() if Hits(X) then scatter(X.hit, 8) end end)
    elseif shape == "cleave" then
        r.dur = 0.7
        F.Clip(X.a, 16)
        F.Lunge(r, X, 0, 0.36, 12)
        F.Slashes(r, X, { t0 = 0.14, n = 1, len = 30, th = 3, bend = 7, ang = X.dir > 0 and 0.3 or pi - 0.3, cols = { p.d, p.h, WHITE }, wipe = 0.1, hold = 0.08 })
        F.React(r, X, 0.2, { knock = 3, shake = 1 })
        r:At(0.2, function() if Hits(X) then scatter(X.hit, 7) end end)
    elseif shape == "rakes" then
        r.dur = cast and 0.78 or 0.68
        F.Clip(X.a, 16)
        F.Lunge(r, X, 0, 0.34, 12)
        F.Slashes(r, X, { t0 = 0.14, n = 3, len = cast and 22 or 17, th = 3, gap = 5, cols = { p.d, p.h, WHITE } })
        F.React(r, X, 0.19, { knock = 3, shake = cast and 2 or 1 })
        r:At(0.19, function() if Hits(X) then scatter(X.hit, 7) end end)
    elseif shape == "charge" then
        r.dur = 0.75
        F.Clip(X.a, 16)
        local vx, vy = X.B.c[1] - X.A.c[1], X.B.c[2] - X.A.c[2]
        local trail = {}
        r:Span(0, 0.6, function(q)
            local k = q < 0.45 and eIn(q / 0.45) or 1 - eOut((q - 0.45) / 0.55)
            local ox, oy = vx * 0.6 * k, vy * 0.6 * k
            F.Offset(X.a, ox, oy)
            table.insert(trail, 1, { ox, oy })
            if #trail > 6 then trail[7] = nil end
            if q > 0.15 and q < 0.5 then local g = trail[4] or trail[#trail] F.Ghost(X.a, g[1], g[2], 0.3, p.h) end
        end)
        if Hits(X) then F.Bonk(r, 0.27, X.hit, { p.l, WHITE }, 6) end
        F.React(r, X, 0.27, { knock = 4, shake = cast and 3 or 2, stop = 0.04 })
        r:At(0.27, function()
            if Hits(X) then scatter(X.hit, 9) end
            F.Spray(X.ground[1], X.ground[2], 4, { kind = "puff", cols = F.DUST, s = { 10, 25 }, life = { 0.4, 0.7 }, r0 = 1, r1 = 3, a = 0.8 })
        end)
    elseif shape == "breath" then
        r.dur = cast and 1.0 or 0.9
        F.Clip(X.a, 54)
        local ux, uy = F.unit(X.hit[1] - X.muzzle[1], X.hit[2] - X.muzzle[2])
        local base = math.atan2(uy, ux)
        r:Span(0.1, 0.55, function()
            for _ = 1, 3 do
                local a, sp = base + rr(-0.16, 0.16), rr(110, 160)
                F.Emit({ kind = "flame", x = X.muzzle[1], y = X.muzzle[2] + 2, vx = cos(a) * sp, vy = sin(a) * sp, drag = 2.4, life = 0.5, pal = F.FLAME })
            end
            F.Glow(lerp(X.muzzle[1], X.hit[1], 0.5), lerp(X.muzzle[2], X.hit[2], 0.5), 30, ORANGE, 0.35)
        end)
        F.React(r, X, 0.32, { knock = 2, flash = C("#ffc080") })
        if Hits(X) then
            r:Span(0.35, 0.85, function(_, lt)
                for i = 0, 2 do
                    F.StampB(F.GL.flameS[(floor(lt * 12) + i) % 3 + 1], X.ground[1] + (i - 1) * X.B.w * 0.3, X.ground[2] - (i == 1 and 6 or 0), F.FLAME)
                end
            end)
        end
    elseif shape == "storm" then
        r.dur = 1.1
        F.Clip(X.a, 54)
        for m = 0, 5 do
            local to = { X.ground[1] + rr(-X.B.w * 0.6, X.B.w * 0.6), X.ground[2] + rr(-3, 3) }
            local from = { to[1] - X.dir * 30, to[2] - 70 }
            F.Fly(r, X, { t0 = 0.12 + m * 0.08, dur = 0.2, from = from, to = to, draw = function(x, y, q, vx)
                local g = F.Comet(2, 5, FIRE5, floor(r.t * 14) % 3)
                F.Stamp(g, floor(x + 0.5) - g.w + 3, floor(y + 0.5) - 2, nil, { flip = vx < 0 })
                F.Glow(x, y, 12, ORANGE, 0.5)
            end })
            F.Explode(r, 0.32 + m * 0.08, to, 4, F.FIRE_R, { puffs = 2, sparks = 6 })
        end
        F.React(r, X, 0.4, { knock = 2, shake = 2 })
        F.React(r, X, 0.6, { knock = 2, shake = 2 })
    elseif shape == "lob" then
        r.dur = 0.8
        F.Clip(X.a, 16)
        F.Fly(r, X, { t0 = 0.12, dur = 0.36, arc = 18, shadow = 3, draw = function(x, y)
            local a = r.t * 22
            local ps = F.NewPS()
            F.Line(ps, x - cos(a) * 4 + 1, y - sin(a) * 4, x + cos(a) * 4 + 1, y + sin(a) * 4, F.BARK.d)
            F.Line(ps, x - cos(a) * 4, y - sin(a) * 4, x + cos(a) * 4, y + sin(a) * 4, F.BARK.l)
            ps:Flush("over")
            F.DrawGen(F.Ball(2, AXE_HEAD, "lit"), x + cos(a) * 4, y + sin(a) * 4)
        end })
        F.React(r, X, 0.48, { knock = 3, shake = 1 })
        r:At(0.48, function() if Hits(X) then scatter(X.hit, 6) end end)
    else                                                            -- a bolt (Fireball, Lava Burst, Fire Nova ...)
        r.dur = cast and 0.95 or 0.78
        F.Clip(X.a, fire and 54 or 16)
        local rad = cast and 4 or 3
        local ramp = fire and FIRE5 or { p.d, p.m, p.l, p.h, p.w }
        F.Fly(r, X, { t0 = 0.12, dur = 0.28, arc = 6, draw = function(x, y, q, vx)
            local g = F.Comet(rad, rad * 2, ramp, floor(r.t * 14) % 3)
            F.Stamp(g, floor(x + 0.5) - (vx >= 0 and g.w - rad - 1 or rad), floor(y + 0.5) - rad, nil, { flip = vx < 0 })
            F.Glow(x, y, rad * 5, p.glow, 0.5)
        end, trail = function(x, y)
            if random() < 0.7 then
                F.Emit({ kind = "ember", x = x, y = y, vx = rr(-6, 6), vy = rr(-10, 0), ay = -10, life = 0.35, cols = fire and F.FIRE_R or { p.h, p.l, p.m } })
            end
        end })
        local rampX = fire and F.FIRE_R or { p.w, p.h, p.l, p.m, p.d }
        F.Explode(r, 0.4, X.hit, cast and 10 or 6, rampX, { glow = p.glow })
        F.React(r, X, 0.4, { knock = 3, shake = cast and 3 or 1, stop = cast and 0.05 or 0 })
    end
end

-- a signature move's recipe, or nil (another type: it keeps the lunge for now)
function F.Sig(id, mv)
    if not (id and mv and id:match("^s[fc]x?_") and SIG_TYPES[mv.type]) then return nil end
    local shape = ShapeOf(mv.name or "")
    local cast = mv.role == "nuke"
    return { play = function(r, X) SigPlay(shape, r, X, cast) end }
end
-- a signature cast winds up like its type's big cast
function F.CastFor(id)
    local mv = id and id:match("^scx?_") and ns.AzeroData.moves[id]
    if not mv then return nil end
    return ({ BEAST = "maul", FIRE = "pyro" })[mv.type]
end

local RUNE = { h = C("#ffb050") }
M.kcounterspell = { desc = "Four runes close on its head and snuff it out", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 54)
    local function head() return X.hit[1], X.B.head[2] + 5 end
    r:Span(0.08, 0.34, function(p, lt)
        local hx, hy = head()
        local R = lerp(14, 3, eIn(p))
        for i = 0, 3 do
            local a = lt * 6 + i * pi / 2
            F.StampC(F.GL.runes[i + 1], hx + cos(a) * R, hy + sin(a) * R * 0.6, RUNE, { shadow = PAL.FIRE.o })
        end
        F.Glow(hx, hy, 16, C("#ff8a2a"), 0.4)
    end)
    r:At(0.34, function()
        local hx, hy = head()
        F.Spray(hx, hy, 4, { kind = "puff", cols = F.SMOKE, s = { 8, 18 }, ang = -pi / 2, spread = pi * 1.6, ay = -6, life = { 0.5, 0.8 }, r0 = 1, r1 = 3, a = 0.8 })
        F.Spray(hx, hy, 6, { kind = "spark", cols = F.SPARK, s = { 30, 60 }, ay = 100, life = { 0.2, 0.4 } })
    end)
    r:Span(0.34, 0.46, function(p) local hx, hy = head() F.Star(hx, hy, 36 * (1 - p), C("#ffe0a0"), 1 - p) end)
    F.React(r, X, 0.34, { knock = 1, flash = C("#ffc890") })
end }

if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_Azeromon/FxMoves.lua", ...) then return end -- DisasterZone_Azeromon/FxMoves.lua
-- The moves' effects, drawn by Fx.lua. 0.41 (step 1): the Beast and Fire kits, their big casts' wind-ups and the
-- Beast / Fire signature shapes; 0.42 (step 2): the other six types' kits and wind-ups; 0.43 (step 3): every type's
-- signature shapes, the bosses' own casts, heals and rallies (marks and the guard shells are in Fx.lua).
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
-- move's name (the first that matches), drawn in its type's colours, with a small gold glint as it starts; no match is
-- a bolt. Volley, smash, vortex, wave, spit, dread and saw are in the 0.43 section at the end of this file
-- (F.SIG_SHAPES).
---------------------------------------------------------------------------

local SHAPES = {
    { "jaws", { "Bite", "Jaw", "Gnaw", "Pincer", "Fang" } },
    { "flurry", { "Frenzy", "Flurry", "Thrash", "Feral Rage" } },
    { "cleave", { "Cleave", "Scythe", "Sweep" } },
    { "lob", { "Toss", "Throw", "Axe", "Headhunter", "Cannon" } },        -- (before rakes: Headhunter's Strike)
    { "rakes", { "Claw", "Rake", "Ravage", "Rend", "Maul", "Strike", "Slash", "Swipe" } },
    { "volley", { "Spines", "Petal", "Volley" } },                        -- (before charge: Crystal Spines)
    { "charge", { "Pounce", "Gore", "Charge", "Dive", "Roll", "Spin", "Burrow" } },
    { "breath", { "Breath", "Buffet", "Jet", "Shadow Flame", "Inferno" } },
    { "storm", { "Firestorm" } },
    { "smash", { "Slam", "Pound", "Stomp", "Smash", "Quake", "Blow" } },
    { "vortex", { "Whirlwind", "Cyclone", "Tempest", "Maelstrom" } },
    { "wave", { "Tsunami", "Riptide", "Tidal" } },
    { "spit", { "Poison", "Corrosive", "Venom" } },
    { "dread", { "Nightmare" } },
    { "saw", { "Buzzsaw", "Saw" } },
}
F.SIG_SHAPES = {}
local function ShapeOf(name)
    for _, s in ipairs(SHAPES) do
        for _, w in ipairs(s[2]) do if name:find(w, 1, true) then return s[1] end end
    end
    return "bolt"
end
F.ShapeOf = ShapeOf

local AXE_HEAD = { PAL.MECH.o, PAL.MECH.d, PAL.MECH.m, PAL.MECH.l, PAL.MECH.h, WHITE }
local CANNONBALL = F.Ramp({ "#15161a", "#2a2c34", "#4c505c", "#7d828f", "#c4c8d2", "#eef0f4" })
local SLAG = F.Ramp({ "#2a0e06", "#5a2410", "#c84a1a", "#f6902a", "#ffcf55" })
local SHADOW_FLAME = F.Pal({ d = "#2c1547", m = "#56308a", l = "#8b62c4", h = "#c6a6ee", w = "#efe4ff" })
local STEAM = F.Ramp({ "#ffffff", "#e6e9ef", "#b8bdc8", "#8a8f9c" })
-- what flies off a signature's hit: each type its own (fur, embers, drops, leaves, wisps, pebbles, feathers, sparks)
local function Bits(X)
    local p = X.pal
    local t = X.type
    if t == "FIRE" then return { kind = "ember", cols = F.FIRE_R, ay = -20 } end
    if t == "WATER" then return { kind = "drop", cols = { p.h, p.l, p.m, p.d }, ay = 240 } end
    if t == "NATURE" then return { kind = "leaf", cols = { p.l, p.h }, ay = 50 } end
    if t == "SHADOW" then return { kind = "wisp", cols = { p.h, p.l, p.m, p.d }, ay = -10 } end
    if t == "EARTH" then return { kind = "pebble", cols = { p.d, p.m, p.l }, ay = 280 } end
    if t == "MECH" then return { kind = "spark", cols = F.SPARK, ay = 220 } end
    return { kind = "px", cols = { p.h, p.l, p.m }, ay = 140 }
end
F.Bits = Bits
local function SigPlay(shape, r, X, cast)
    local p = X.pal
    local fire = X.type == "FIRE"
    local bits = Bits(X)
    local function scatter(pt, n)
        F.Spray(pt[1], pt[2], n, { kind = bits.kind, cols = bits.cols, s = { 25, 70 }, ay = bits.ay, drag = 1.5, ground = X.ground[2] + 2,
                life = { 0.35, 0.7 }, bounce = bits.kind == "pebble" and 0.3 or nil })
    end
    r:At(0, function() F.Emit({ kind = "glint", x = X.muzzle[1], y = X.muzzle[2] - 2, life = 0.35, cols = { F.GOLD.h, F.GOLD.w } }) end)
    r:Span(0, 0.2, function(q) F.Star(X.muzzle[1], X.muzzle[2] - 2, 26 * bump(q), F.GOLD.h, 0.9) end)
    local ext = F.SIG_SHAPES[shape]
    if ext then return ext(r, X, cast, scatter) end
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
        -- fire (or shadow fire) flames; a Mech or Water beast breathes steam
        local steam = X.type == "MECH" or X.type == "WATER"
        local fp = X.type == "SHADOW" and SHADOW_FLAME or F.FLAME
        local made, rate = 0, steam and 70 or 150                   -- (a second, whatever the frame rate; puffs are big)
        r:Span(0.1, 0.55, function(_, lt)
            local due = floor(lt * rate) + 1
            while made < due do
                made = made + 1
                local a, sp = base + rr(-0.16, 0.16), rr(110, 160)
                if steam then
                    sp = sp * 1.4
                    F.Emit({ kind = "puff", x = X.muzzle[1], y = X.muzzle[2], vx = cos(a) * sp, vy = sin(a) * sp, drag = 1.6, life = 0.7, r0 = 1, r1 = 4, cols = STEAM, a = 0.75 })
                else
                    F.Emit({ kind = "flame", x = X.muzzle[1], y = X.muzzle[2] + 2, vx = cos(a) * sp, vy = sin(a) * sp, drag = 2.4, life = 0.5, pal = fp })
                end
            end
            F.Glow(lerp(X.muzzle[1], X.hit[1], 0.5), lerp(X.muzzle[2], X.hit[2], 0.5), 30,
                   steam and C("#e6f0ff") or X.type == "SHADOW" and C("#9a5cff") or ORANGE, 0.35)
        end)
        F.React(r, X, 0.32, { knock = 2, flash = steam and WHITE or C("#ffc080") })
        if steam and not X.miss then
            r:At(0.34, function()
                F.Spray(X.hit[1], X.hit[2], 6, { kind = "puff", cols = STEAM, s = { 10, 30 }, drag = 2, ay = -8, life = { 0.6, 0.9 }, r0 = 2, r1 = 5, a = 0.7 })
            end)
        end
        if Hits(X) and not steam then
            r:Span(0.35, 0.85, function(_, lt)
                for i = 0, 2 do
                    F.StampB(F.GL.flameS[(floor(lt * 12) + i) % 3 + 1], X.ground[1] + (i - 1) * X.B.w * 0.3, X.ground[2] - (i == 1 and 6 or 0), fp)
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
        -- a spinning axe (Throwing Axe, Headhunter's Strike), a cannonball or a lump of molten slag, in an arc
        r.dur = 0.8
        F.Clip(X.a, 16)
        local name = X.mv.name or ""
        local cannon, slag = name:find("Cannon", 1, true), name:find("Slag", 1, true)
        F.Fly(r, X, { t0 = 0.12, dur = 0.36, arc = 18, shadow = 3, draw = function(x, y)
            if cannon then F.DrawGen(F.Ball(3, CANNONBALL, "lit"), x, y) return end
            if slag then
                F.DrawGen(F.Rock(3, SLAG, floor(r.t * 14) % 4), x, y)
                F.Glow(x, y, 10, ORANGE, 0.45)
                return
            end
            local a = r.t * 22
            local ps = F.NewPS()
            F.Line(ps, x - cos(a) * 4 + 1, y - sin(a) * 4, x + cos(a) * 4 + 1, y + sin(a) * 4, F.BARK.d)
            F.Line(ps, x - cos(a) * 4, y - sin(a) * 4, x + cos(a) * 4, y + sin(a) * 4, F.BARK.l)
            ps:Flush("over")
            F.DrawGen(F.Ball(2, AXE_HEAD, "lit"), x + cos(a) * 4, y + sin(a) * 4)
        end, trail = slag and function(x, y)
            if random() < 0.5 then F.Emit({ kind = "ember", x = x, y = y, vx = rr(-6, 6), vy = rr(-10, 0), ay = -10, life = 0.35, cols = F.FIRE_R }) end
        end or nil })
        if cannon or slag then F.Explode(r, 0.48, X.hit, 7, F.FIRE_R, { puffs = 4, sparks = 12 }) end
        F.React(r, X, 0.48, { knock = 3, shake = cannon and 2 or 1 })
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
                F.Emit({ kind = bits.kind == "pebble" and "px" or bits.kind, x = x, y = y, vx = rr(-6, 6), vy = rr(-10, 0),
                         ay = bits.kind == "drop" and 160 or -10, life = 0.35, cols = bits.cols })
            end
        end })
        local rampX = fire and F.FIRE_R or { p.w, p.h, p.l, p.m, p.d }
        F.Explode(r, 0.4, X.hit, cast and 10 or 6, rampX, { glow = p.glow, sparkCols = not fire and bits.cols or nil })
        F.React(r, X, 0.4, { knock = 3, shake = cast and 3 or 1, stop = cast and 0.05 or 0 })
    end
end

-- a signature move's recipe (any type), or nil (not a signature)
function F.Sig(id, mv)
    if not (id and mv and id:match("^s[fc]x?_")) then return nil end
    local shape = ShapeOf(mv.name or "")
    local cast = mv.role == "nuke"
    return { play = function(r, X) SigPlay(shape, r, X, cast) end }
end
-- the wind-up of a cast that isn't a kit move: a signature cast winds up like its type's big cast (a cannon: its fuse
-- fizzes), a boss's like its own family (F.BossFamily, below; else its type's), a boss's heal or rally gathers green
-- light or shouts
local TYPE_WINDUP = { BEAST = "maul", FIRE = "pyro", WATER = "tidal", NATURE = "overgrowth", SHADOW = "shadowbolt",
                      EARTH = "quake", AIR = "tempest", MECH = "sawstorm" }
function F.CastFor(id)
    local mv = id and ns.AzeroData.moves[id]
    if not mv then return nil end
    if id:match("^scx?_") then return (mv.name or ""):find("Cannon", 1, true) and "broadside" or TYPE_WINDUP[mv.type] end
    if id:match("^bcast_") then return F.BossFamily(id:sub(7)) or TYPE_WINDUP[mv.type] end
    if id:match("^bsecond_") then return mv.heal and "heal" or "rally" end
    return nil
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

---------------------------------------------------------------------------
-- 0.42 (step 2): the other six types
---------------------------------------------------------------------------

local SMOKE, DUST, SPARK, VOLT, GOLD, HEAL = F.SMOKE, F.DUST, F.SPARK, F.VOLT, F.GOLD, F.HEAL
local BARK, STONE, BLOOM = F.BARK, F.STONE, F.BLOOM
local function Up(side, n) F.Offset(side, 0, -n) end
local function Jolt(side, lt, rate) F.Offset(side, (floor(lt * rate) % 2 == 1) and 1 or -1, 0) end

-- Water: orbs, ice, waves and spray -----------------------------------------------------------------------------

local W = PAL.WATER
local WATER6 = { W.o, W.d, W.m, W.l, W.h, W.w }
local DROPS = { W.h, W.l, W.m, W.d }
local function Splash(pt, gy, n, big)
    F.Spray(pt[1], pt[2], n, { kind = "drop", cols = DROPS, s = big and { 50, 110 } or { 40, 80 }, ang = -pi / 2, spread = 1.9, ay = 280,
            ground = gy, life = { 0.5, 0.9 } })
    F.Emit({ kind = "ring", x = pt[1], y = pt[2], r0 = 2, r1 = big and 14 or 8, flat = 0.55, cols = { W.w, W.h, W.l }, life = 0.3 })
end

M.kwaterbolt = { desc = "A water orb, a splash crown", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 54)
    F.Fly(r, X, { t0 = 0.12, dur = 0.24, arc = 4, draw = function(x, y)
        F.DrawGen(F.Ball(3, WATER6, "lit"), x, y)
        F.Glow(x, y, 14, C("#4aa8ff"), 0.35)
    end, trail = function(x, y)
        F.Emit({ kind = "drop", x = x + rr(-1, 1), y = y + 1, vy = rr(0, 15), ay = 180, life = 0.4, cols = { W.l, W.h } })
    end })
    F.React(r, X, 0.36, { knock = 2, flash = C("#cdeeff") })
    r:At(0.36, function() Splash(X.hit, X.ground[2] + 2, 9) end)
end }

local CRYSTALS = { { -0.32, 0 }, { 0.3, 1 }, { 0.05, -1 } }
M.kfrostshock = { desc = "Ice spikes burst from it, frost forms at its feet", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 54)
    r:Span(0.12, 0.42, function(p)
        local ps, c = F.NewPS(), X.hit
        local L = 2 + 6 * eOut(min(1, p * 2))
        for i = 0, 5 do
            local a = i * TAU / 6 + 0.25
            local x1, y1 = c[1] + cos(a) * L, c[2] + sin(a) * L * 0.85
            F.Line(ps, c[1] + cos(a) * 2 + 1, c[2] + sin(a) * 2, x1 + 1, y1, W.m)
            F.Line(ps, c[1] + cos(a) * 2, c[2] + sin(a) * 2, x1, y1, p > 0.6 and W.l or W.w)
        end
        ps:Flush("over", p > 0.7 and (1 - p) / 0.3 or 1)
        F.Glow(c[1], c[2], 20, C("#9ad8ff"), 0.5 * (1 - p))
    end)
    r:Span(0.2, 0.7, function(p)
        for i, cr in ipairs(CRYSTALS) do
            if p * 3 > (i - 1) * 0.5 then
                F.StampB(i == 2 and F.GL.crystal or F.GL.crystalS, X.ground[1] + cr[1] * X.B.w, X.ground[2] + cr[2], W, { lay = cr[2] < 0 and "under" or "over" })
            end
        end
    end)
    F.React(r, X, 0.14, { knock = 1, flash = C("#bfe6ff") })
    r:At(0.2, function()
        if not X.miss then F.Spray(X.hit[1], X.hit[2], 6, { kind = "glint", cols = { W.h, W.w }, s = { 20, 50 }, drag = 4, life = { 0.3, 0.5 } }) end
    end)
end }

local LANCE = { W.w, W.w, W.h, W.h, W.l, W.l, W.l, W.m, W.m, W.d, W.d, W.o }
M.kicelance = { desc = "An ice lance shatters; on a Chilled foe the frost explodes", play = function(r, X)
    r.dur = X.combo and 0.9 or 0.7
    F.Clip(X.a, 54)
    F.Fly(r, X, { t0 = 0.12, dur = 0.16, draw = function(x, y, q, vx, vy)
        local ux, uy = F.unit(vx, vy)
        local ps = F.NewPS()
        for i = #LANCE, 1, -1 do
            ps:Add(x - ux * (i - 1), y - uy * (i - 1) + 1, i <= 3 and W.l or W.d)
            ps:Add(x - ux * (i - 1), y - uy * (i - 1), LANCE[i])
        end
        ps:Flush("over")
        F.Glow(x, y, 12, C("#9ad8ff"), 0.4)
    end, trail = function(x, y)
        if random() < 0.6 then F.Emit({ kind = "glint", x = x + rr(-3, 0), y = y + rr(-1, 1), life = 0.2, cols = { W.h, W.w } }) end
    end })
    F.React(r, X, 0.28, { knock = 2 })
    r:At(0.28, function()
        if not X.miss then
            F.Spray(X.hit[1], X.hit[2], X.combo and 18 or 8, { kind = "shard", cols = { W.w, W.l }, s = { 35, 80 }, ay = 200, drag = 1.5, life = { 0.3, 0.55 } })
        end
    end)
    F.ComboFx(r, X, 0.3)
    if X.combo and not X.miss then
        r:At(0.3, function()
            F.Spray(X.ground[1], X.ground[2] - 2, 10, { kind = "shard", cols = { W.h, W.m }, s = { 40, 90 }, ang = -pi / 2, spread = 2.4, ay = 220,
                    ground = X.ground[2] + 2, life = { 0.5, 0.8 }, bounce = 0.3 })
        end)
        r:Span(0.3, 0.42, function() F.Light(X.b, WHITE, 0.3) end)
    end
end }

-- a breaker rolling over the grass: its back slopes away, its crest near the front, a foam lip curling over
local function Breaker(cx, by, Wd, H, dir, lt, a)
    Wd, H = max(6, floor(Wd + 0.5)), max(2, floor(H + 0.5))
    local front = floor(cx + dir * Wd / 2 + 0.5)
    for i = 0, Wd - 1 do
        local u = i / (Wd - 1)
        local x = floor(cx + dir * (i - Wd / 2) + 0.5)
        local prof = u < 0.72 and (u / 0.72) ^ 1.3 or 1 - ((u - 0.72) / 0.28) ^ 2 * 0.35
        local h = max(1, floor(H * (0.2 + 0.8 * prof) + sin(lt * 16 + i * 0.8) * 0.7 + 0.5))
        local low, top = max(1, floor(h * 0.35 + 0.5)), max(1, floor(h * 0.3 + 0.5))
        F.Rect(x, by - h, 1, h, W.m, a)
        F.Rect(x, by - low, 1, low, W.d, a)
        F.Rect(x, by - h, 1, top, W.l, a)
        F.Rect(x, by - h, 1, 1, u > 0.5 and W.w or W.h, a)
        if u > 0.5 and (i + floor(lt * 20)) % 3 == 0 then F.Rect(x, by - h - 1, 1, 1, W.w, a) end
    end
    for k = 1, 4 do F.Rect(front + dir * k, by - floor(H * 0.95 + 0.5) + floor(k * k * 0.4 + 0.5), 1, k < 3 and 2 or 1, k < 3 and W.w or W.h, a) end
    F.Rect(front + dir * 2, by - floor(H * 0.6 + 0.5), 1, 1, W.l, a)
    F.Rect(floor(cx - dir * Wd / 2 + 0.5), by, Wd, 1, W.o, 0.35 * a, "under")
end
M.ktidalwave = { desc = "Water swirls round its feet, then a wave rolls over the foe", play = function(r, X)
    r.dur = 1.25
    F.Clip(X.a, 54)
    local A0, B0 = X.A.feet, X.miss and X.ground or X.B.feet
    local travel, t0 = 0.5, 0.08
    r:Span(t0, t0 + travel + 0.32, function(_, lt)
        local q, crash = F.clamp(lt / travel, 0, 1), F.clamp((lt - travel) / 0.32, 0, 1)
        local hx = lerp(A0[1] + X.dir * 10, B0[1] - X.dir * 4, eOut(q))
        local hy = lerp(A0[2] + 2, B0[2] + 2, eOut(q))
        local persp = lerp(1, 0.78, X.dir > 0 and q or 1 - q)
        local H = 21 * persp * (crash > 0 and 1 - eIn(crash) or min(1, 0.4 + q * 2))
        local Wd = 38 * persp * (1 + crash * 0.4)
        Breaker(hx, hy, Wd, H, X.dir, lt, 1 - crash * 0.5)
        if random() < 0.8 then
            F.Emit({ kind = "drop", x = hx + X.dir * Wd * 0.35, y = hy - H, vx = X.dir * rr(10, 35), vy = rr(-45, -15), ay = 220, life = 0.5, cols = { W.w, W.h } })
        end
        F.Glow(hx, hy - H / 2, 22, C("#4aa8ff"), 0.3)
    end)
    F.React(r, X, t0 + travel, { knock = 4, shake = 2, stop = 0.05, flash = C("#cdeeff") })
    r:At(t0 + travel, function() Splash(X.B.c, X.ground[2] + 2, 18, true) end)
end }
-- Tidal Wave's turn of waiting: water swirls round its feet, droplets lift off
F.CASTS.tidal = { cols = { W.w, W.l }, focus = function(s) local p = F.Pts(s) return { p.feet[1], p.feet[2] - 3 } end,
    windup = function(s, st, dt)
        local p = F.Pts(s)
        local rx, k = p.w * 0.55 + 3, min(1, st.tw / 0.6)
        local pf, pb = F.NewPS(), F.NewPS()
        F.Disc(p.feet[1], p.feet[2], rx * k, 3, W.m, 0.45, "under")
        for i = 0, 5 do
            local a0 = st.tw * 3.2 + i * TAU / 6
            local a = a0
            while a < a0 + 0.55 do
                local set = sin(a) > 0 and pf or pb
                set:Add(p.feet[1] + cos(a) * rx * k, p.feet[2] - 1 + sin(a) * 3.2, a > a0 + 0.4 and W.w or W.l)
                a = a + 0.05
            end
        end
        pb:Flush("under") pf:Flush("over")
        every(st, "d", 0.06, dt, function()
            local a = rr(0, TAU)
            F.Emit({ kind = "drop", x = p.feet[1] + cos(a) * rx * k, y = p.feet[2] + sin(a) * 3, vy = rr(-45, -25), ay = 120, life = 0.55, cols = { W.h, W.l } })
        end)
        F.Glow(p.feet[1], p.feet[2] - 4, rx * 1.6, C("#4aa8ff"), 0.25, "under")
    end }
F.CAST_OF.ktidalwave = "tidal"

M.kwindshear = { desc = "Three thin crescents cut across it", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 54)
    for i = 0, 2 do
        local t0 = 0.1 + i * 0.07
        local to = { X.hit[1], X.hit[2] + (i - 1) * 5 }
        F.Fly(r, X, { t0 = t0, dur = 0.18, to = to, draw = function(x, y, q, vx)
            local ps, f = F.NewPS(), vx >= 0 and 1 or -1
            F.Arc(ps, x - f * 2, y, 3, 5, f > 0 and -1.1 or pi - 1.1, f > 0 and 1.1 or pi + 1.1, W.l)
            F.Arc(ps, x, y, 3, 5, f > 0 and -1.0 or pi - 1.0, f > 0 and 1.0 or pi + 1.0, W.w)
            ps:Flush("over")
        end })
        r:Span(t0 + 0.18, t0 + 0.3, function(p)
            if not Hits(X) then return end
            local ps, a = F.NewPS(), 0.5 + i * 0.6
            F.Line(ps, to[1] - cos(a) * 6, to[2] - sin(a) * 4, to[1] + cos(a) * 6, to[2] + sin(a) * 4, WHITE)
            ps:Flush("over", 1 - p)
        end)
    end
    F.React(r, X, 0.28, { knock = 1, flash = C("#e0f4ff") })
end }

-- Nature: thorns, roots, vines and blooms --------------------------------------------------------------------------

local N = PAL.NATURE
local LEAVES = { N.l, N.h }
local THORN = { BARK.h, BARK.l, BARK.l, BARK.m, BARK.m, N.l, N.m }
local function Thorn(ps, x, y, ux, uy)
    for i = #THORN, 1, -1 do ps:Add(x - ux * (i - 1), y - uy * (i - 1), THORN[i]) end
    ps:Add(x - ux * 5 - uy, y - uy * 5 + ux, N.d)
end
local function ThornDraw(x, y, q, vx, vy)
    local ps = F.NewPS()
    local ux, uy = F.unit(vx, vy)
    Thorn(ps, x, y, ux, uy)
    ps:Flush("over")
end
M.kthorns = { desc = "Three thorns fly, leaves scatter", play = function(r, X)
    r.dur = 0.66
    F.Clip(X.a, 54)
    for i, s in ipairs({ { 0.1, 6, -3 }, { 0.16, 9, 2 }, { 0.22, 4, 5 } }) do
        F.Fly(r, X, { t0 = s[1], dur = 0.24, arc = s[2], to = { X.hit[1], X.hit[2] + s[3] }, draw = ThornDraw, hit = function(pt)
            if Hits(X) then F.Spray(pt[1], pt[2], 2, { kind = "leaf", cols = LEAVES, s = { 15, 35 }, ay = 50, drag = 2, life = { 0.5, 0.8 } }) end
        end })
        if i > 1 then r:Span(s[1] + 0.24, s[1] + 0.32, function() if Hits(X) then F.Offset(X.b, X.dir, 0) end end) end
    end
    F.React(r, X, 0.34, { knock = 1 })
end }

local ROOT = { BARK.d, BARK.l, BARK.h, N.l, N.d }
M.kroots = { desc = "Roots burst from the ground and coil round its feet", play = function(r, X)
    r.dur = 0.8
    F.Clip(X.a, 54)
    local spots = { { -0.4, 12, 0.3, -1 }, { -0.12, 16, 2.1, 1 }, { 0.15, 14, 4.0, -1 }, { 0.4, 10, 5.2, 1 } }
    r:Span(0.08, 0.72, function(p, lt)
        local g = X.ground
        local grow = p < 0.45 and eOut(p / 0.45) or 1 - eIn((p - 0.45) / 0.55) * 0.75
        local pf, pb = F.NewPS(), F.NewPS()
        for _, s in ipairs(spots) do
            F.Vine(s[4] > 0 and pf or pb, g[1] + s[1] * X.B.w * 1.1, g[2] + (s[4] > 0 and 1 or -1), s[2] * grow, s[3] + lt * 4, 2, ROOT)
        end
        pb:Flush("under") pf:Flush("over")
    end)
    r:At(0.1, function()
        F.Spray(X.ground[1], X.ground[2], 8, { kind = "pebble", cols = { BARK.d, BARK.m, BARK.l }, s = { 25, 50 }, ang = -pi / 2, spread = 1.6, ay = 260,
                ground = X.ground[2] + 2, jx = X.B.w * 0.4, life = { 0.4, 0.7 }, bounce = 0.3 })
    end)
    F.React(r, X, 0.2, { knock = 0, flash = C("#c8f0a0") })
end }

local SQUEEZE = { BARK.d, BARK.h, WHITE, N.h, N.m }
M.kthornvolley = { desc = "Thorns rain down; on a Rooted foe the roots crush it", play = function(r, X)
    r.dur = X.combo and 1.0 or 0.85
    F.Clip(X.a, 54)
    for i = 0, 7 do
        local to = { X.hit[1] + rr(-X.B.w * 0.4, X.B.w * 0.4), X.hit[2] + rr(-X.B.h * 0.3, X.B.h * 0.4) }
        F.Fly(r, X, { t0 = 0.1 + i * 0.04, dur = 0.16, from = { to[1] - X.dir * 24, to[2] - 42 }, to = to, draw = ThornDraw, hit = function(pt)
            if not X.guarded then F.Spray(pt[1], pt[2], 1, { kind = "leaf", cols = LEAVES, s = { 10, 30 }, ay = 40, life = { 0.4, 0.7 } }) end
        end })
    end
    F.React(r, X, 0.28, { knock = 2 })
    F.ComboFx(r, X, 0.5)
    if X.combo and not X.miss then
        r:Span(0.5, 0.82, function(p, lt)
            local g = X.ground
            local pf, pb = F.NewPS(), F.NewPS()
            local sq = floor(2 * bump(p) + 0.5)
            for _, s in ipairs({ { -0.42, 14, 0.3, -1 }, { -0.15, 18, 2.1, 1 }, { 0.15, 16, 4.0, -1 }, { 0.42, 12, 5.2, 1 } }) do
                F.Vine(s[4] > 0 and pf or pb, g[1] + s[1] * X.B.w * (1.1 - sq * 0.1), g[2], s[2] * bump(p), s[3] + lt * 9, 1, SQUEEZE)
            end
            pb:Flush("under") pf:Flush("over")
            F.Light(X.b, C("#c8f0a0"), 0.3 * bump(p))
        end)
        r:At(0.52, function() F.Spray(X.B.c[1], X.B.c[2], 14, { kind = "leaf", cols = LEAVES, s = { 30, 70 }, ay = 60, drag = 2, life = { 0.6, 1.0 } }) end)
    end
end }

local VINE_A, VINE_B = { BARK.d, N.m, N.h, N.l, N.d }, { N.d, N.l, N.h, N.l, N.d }
M.kovergrowth = { desc = "Leaves whirl round it, then giant vines erupt and bloom", play = function(r, X)
    r.dur = 1.15
    F.Clip(X.a, 54)
    r:Span(0.08, 1.0, function(p, lt)
        local g = X.ground
        local up = p < 0.3 and eOut(p / 0.3) or p > 0.75 and 1 - eIn((p - 0.75) / 0.25) or 1
        local pf, pb = F.NewPS(), F.NewPS()
        for _, s in ipairs({ { -0.32, 18, 0.5, 1 }, { 0.0, 24, 2.6, -1 }, { 0.3, 16, 4.4, 1 } }) do
            local set, x0, L = s[4] > 0 and pf or pb, g[1] + s[1] * X.B.w * 1.2, s[2] * up
            F.Vine(set, x0, g[2], L, s[3] + lt * 2, 2.5, VINE_A)
            F.Vine(set, x0 + 1, g[2], L * 0.9, s[3] + lt * 2, 2.5, VINE_B)
        end
        pb:Flush("under") pf:Flush("over")
        if p > 0.28 and up > 0.6 then
            F.StampB(p < 0.36 and F.GL.bud or F.GL.bloom, g[1] + sin(24 * 0.42 + 2.6 + lt * 2) * 2.5, g[2] - 24 * up + 2, BLOOM)
        end
        F.Glow(g[1], g[2] - 10, 26, C("#7ee05a"), 0.3 * up)
    end)
    F.React(r, X, 0.2, { knock = 3, shake = 1, flash = C("#d0f0b0") })
    r:At(0.1, function()
        F.Spray(X.ground[1], X.ground[2], 10, { kind = "pebble", cols = { BARK.d, BARK.m, BARK.l }, s = { 30, 60 }, ang = -pi / 2, spread = 1.6, ay = 280,
                ground = X.ground[2] + 2, jx = X.B.w * 0.4, life = { 0.5, 0.8 }, bounce = 0.3 })
    end)
    r:At(0.45, function()
        F.Spray(X.ground[1], X.ground[2] - 22, 10, { kind = "petal", cols = { BLOOM.p, BLOOM.P }, s = { 20, 45 }, ay = 30, drag = 2, sway = 2, life = { 0.8, 1.2 } })
    end)
end }
-- Overgrowth's turn of waiting: leaves whirl round it, vines curl up its sides, sprouts push up at its feet
local SPROUTS = { -0.45, 0.4, -0.1 }
local VINE_UP = { N.o, N.m, N.h, N.l, N.d }
F.CASTS.overgrowth = { cols = { N.h, N.l }, focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] } end,
    windup = function(s, st, dt)
        local p = F.Pts(s)
        for i = 0, 5 do
            local a = st.tw * 2.4 + i * TAU / 6
            local x = p.c[1] + cos(a) * (p.w * 0.55 + 4)
            local y = p.c[2] + p.h * 0.15 + sin(a) * 4 - (i % 3) * 6 + sin(st.tw * 2 + i) * 2
            F.StampC(F.GL.leaf[(floor(st.tw * 8) + i) % 2 + 1], x, y, N, { lay = sin(a) > 0 and "over" or "under" })
        end
        local pv, k = F.NewPS(), min(1, st.tw / 0.8)
        for _, sd in ipairs({ -1, 1 }) do
            F.Vine(pv, p.c[1] + sd * (p.w * 0.5 + 1), p.feet[2], p.h * 0.55 * k, st.tw * 3 + (sd > 0 and 2 or 0), 1.5, VINE_UP)
        end
        pv:Flush("over")
        for i, dx in ipairs(SPROUTS) do
            local up = F.clamp(st.tw * 3 - (i - 1) * 0.4, 0, 1)
            if up > 0 then
                F.StampB(F.GL.sprout, p.feet[1] + dx * p.w + (sin(st.tw * 3 + i) > 0.6 and 1 or 0), p.feet[2] + 1 + floor((1 - up) * 3 + 0.5), N,
                         { lay = i == 3 and "under" or "over" })
            end
        end
        F.Glow(p.feet[1], p.feet[2] - 4, p.w * 1.1, C("#7ee05a"), 0.25, "under")
    end }
F.CAST_OF.kovergrowth = "overgrowth"

local HEAL_MOTES = { HEAL.w, HEAL.h, HEAL.l, HEAL.m }
M.kregrowth = { desc = "Green motes spiral up and close its wounds", play = function(r, X)
    r.dur = 0.88
    F.Clip(X.a, 54)
    local A = X.A
    r:Span(0.04, 0.7, function(p, lt)
        if random() < 0.9 then
            local a, R = lt * 9 + rr(0, 0.5), A.w * (0.5 - 0.2 * p)
            F.Emit({ kind = "mote", x = A.c[1] + cos(a) * R, y = A.feet[2] - 2 - p * A.h * 0.5, vx = -sin(a) * 8, vy = -30, life = 0.6,
                     cols = HEAL_MOTES, lay = sin(a) > 0 and "over" or "under" })
        end
        F.Ring(A.feet[1], A.feet[2], A.w * (0.3 + 0.35 * eOut(p)), 3, 1, HEAL.l, 1 - p, "under")
        F.Glow(A.c[1], A.c[2], A.w * 1.2, C("#7ee05a"), 0.22 * bump(p), "under")
    end)
    for i, t in ipairs({ 0.3, 0.42, 0.56 }) do
        r:Span(t, t + 0.25, function(p)
            F.StampC(F.GL.plus, A.c[1] + (i - 2) * A.w * 0.3, A.c[2] - 4 - p * 8 + (i - 1) * 3, { w = p < 0.5 and HEAL.w or HEAL.h },
                     { shadow = HEAL.o, a = 1 - eIn(p) })
        end)
    end
    r:Span(0.25, 0.55, function(p) F.Light(X.a, C("#b8f080"), 0.25 * bump(p)) end)
end }

-- Shadow: jaws, tendrils, coils and the void -----------------------------------------------------------------------

local S = PAL.SHADOW
local WISPS = { S.h, S.l, S.m, S.d }
M.kshadowbite = { desc = "Shadow jaws snap, purple smoke curls off", play = function(r, X)
    r.dur = 0.62
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.34, 12)
    F.Jaws(r, X, { t0 = 0.08, close = 0.11, hold = 0.12, pal = { m = S.m, h = S.h, w = S.w }, gum = S.d, gumD = S.o, n = 4 })
    F.React(r, X, 0.19, { knock = 2, flash = C("#d8c0f8") })
    r:At(0.19, function()
        if Hits(X) then F.Spray(X.hit[1], X.hit[2], 7, { kind = "wisp", cols = WISPS, s = { 15, 30 }, ang = -pi / 2, spread = pi * 1.4, life = { 0.5, 0.8 } }) end
    end)
end }

M.kcorruption = { desc = "Dark tendrils creep up it and sink in", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 54)
    r:Span(0.08, 0.62, function(p, lt)
        local g, ps = X.ground, F.NewPS()
        local grow, sink = p < 0.6 and eOut(p / 0.6) or 1, p > 0.6 and (p - 0.6) / 0.4 or 0
        for i, dx in ipairs({ -0.42, 0.05, 0.4 }) do
            local x0, L = g[1] + dx * X.B.w * 1.1, X.B.h * 0.55 * grow
            local s = L * sink
            while s <= L do
                local x, y = x0 + sin(s * 0.5 + lt * 8 + i * 2) * 2.2 - dx * s * 0.6, g[2] - s
                ps:Add(x + 1, y, S.o)
                ps:Add(x, y, (floor(s) % 4 == 0) and S.l or S.d)
                s = s + 0.5
            end
        end
        ps:Flush("over")
    end)
    r:Span(0.3, 0.62, function(p) local b = bump(p) F.Shade(X.b, 1 - 0.3 * b, 1 - 0.45 * b, 1 - 0.1 * b) end)
    F.React(r, X, 0.32, { knock = 0, flash = C("#9a70d0") })
end }

local SKULL = { S.o, S.d, S.m, S.l, S.h }
local EYE = C("#d8ff7a")
M.kdeathcoil = { desc = "A skull bolt coils over; its life streams back to you", play = function(r, X)
    r.dur = X.combo and 1.05 or 0.98
    F.Clip(X.a, 54)
    local to = X.hit
    F.Fly(r, X, { t0 = 0.1, dur = 0.32, arc = 4, draw = function(x, y, q, vx, vy)
        local ux, uy = F.unit(vx, vy)
        local wv = sin(q * pi * 3) * 4
        local px, py = x - uy * wv, y + ux * wv
        F.DrawGen(F.Ball(3, SKULL, "lit"), px, py)
        F.Rect(px - 2, py - 1, 1, 1, EYE) F.Rect(px + 1, py - 1, 1, 1, EYE) F.Rect(px - 1, py + 1, 3, 1, S.o)
        F.Emit({ kind = "wisp", x = px, y = py, vx = rr(-5, 5), vy = rr(-12, -4), life = 0.45, cols = { S.l, S.m, S.d } })
        F.Glow(px, py, 12, C("#9a5cff"), 0.45)
    end })
    F.React(r, X, 0.42, { knock = 2, flash = C("#c8a0f0") })
    r:At(0.42, function()
        if not X.miss then F.Emit({ kind = "ring", x = to[1], y = to[2], r0 = 2, r1 = 10, cols = { S.h, S.l, S.m }, life = 0.3 }) end
    end)
    F.ComboFx(r, X, 0.42)
    r:Span(0.48, 0.85, function()
        if not Hits(X) then return end
        if random() < (X.combo and 0.6 or 0.35) then
            F.Seek(to[1] + rr(-4, 4), to[2] + rr(-4, 4), X.A.c[1] + rr(-3, 3), X.A.c[2] + rr(-3, 3), 0.5,
                   X.combo and { S.l, EYE } or { S.m, S.w }, -12, "over", true)
        end
    end)
    r:Span(0.8, 0.98, function(p) if Hits(X) then F.Light(X.a, C("#d8b8ff"), 0.3 * bump(p)) end end)
end }

local VOID = { S.o, S.d, S.m, S.h }
local function BoltFocus(s)
    local p = F.Pts(s)
    return { p.c[1] + (s == "ally" and 1 or -1) * (p.w * 0.5 + 6), p.c[2] - 4 }
end
F.CASTS.shadowbolt = { cols = { S.h, S.l }, focus = BoltFocus, windup = function(s, st, dt)
    -- a void orb gathers in front of it, wisps are drawn in, the ground under it darkens
    local p, f = F.Pts(s), BoltFocus(s)
    local rad = st.tw < 0.8 and 1 + 3 * eOut(st.tw / 0.8) or 4 + (sin(st.tw * 10) > 0.4 and 1 or 0)
    F.Disc(p.feet[1], p.feet[2], p.w * 0.5 + 2, 3, C("#120820"), 0.38, "under")
    every(st, "w", 0.06, dt, function()
        local a, R = rr(0, TAU), rr(12, 16)
        F.Seek(f[1] + cos(a) * R, f[2] + sin(a) * R, f[1], f[2], 0.45, { S.d, S.m, S.l }, 0)
    end)
    F.DrawGen(F.Ball(floor(rad + 0.5), VOID, "void"), f[1], f[2])
    F.Glow(f[1], f[2], 10 + rad * 2, C("#9a5cff"), 0.45)
end }
F.CAST_OF.kshadowbolt = "shadowbolt"
M.kshadowbolt = { desc = "A void orb gathers, then flies trailing smoke", play = function(r, X)
    r.dur = 1.1
    F.Clip(X.a, 54)
    F.Fly(r, X, { t0 = 0.05, dur = 0.32, arc = 6, from = BoltFocus(X.a), draw = function(x, y)
        F.DrawGen(F.Ball(4, VOID, "void"), x, y)
        F.Glow(x, y, 20, C("#9a5cff"), 0.55)
    end, trail = function(x, y)
        F.Emit({ kind = "puff", x = x + rr(-1, 1), y = y + rr(-1, 1), vy = -4, life = 0.55, r0 = 1.5, r1 = 3, cols = { S.m, S.d, S.o }, a = 0.8 })
    end })
    r:Span(0.37, 0.7, function(p)
        if X.miss then return end
        local c, rad = X.hit, 2 + 13 * eOut(p)
        F.Ring(c[1], c[2], rad, rad * 0.8, 1, S.h, 1 - p)
        F.Ring(c[1], c[2], rad * 0.65, rad * 0.52, 1, S.m, 1 - p)
        if p < 0.4 then F.Disc(c[1], c[2], 5 * (1 - p / 0.4), 4 * (1 - p / 0.4), S.o) end
        F.Glow(c[1], c[2], 30, C("#9a5cff"), 0.6 * (1 - p))
    end)
    r:At(0.37, function()
        if not X.miss then F.Spray(X.hit[1], X.hit[2], 14, { kind = "wisp", cols = WISPS, s = { 20, 45 }, drag = 2, life = { 0.5, 0.9 } }) end
    end)
    F.React(r, X, 0.37, { knock = 4, shake = 2, stop = 0.05, flash = C("#d0b0ff") })
end }

M.kspelllock = { desc = "Shackles close on its head and lock", play = function(r, X)
    r.dur = 0.64
    F.Clip(X.a, 54)
    r:Span(0.08, 0.56, function(p)
        local hx, hy = X.hit[1], X.B.head[2] + 6
        local cl = eOut(F.clamp(p / 0.4, 0, 1))
        local R = lerp(14, 7, cl)
        local fade = p > 0.85 and (1 - p) / 0.15 or 1
        local ps = F.NewPS()
        F.Arc(ps, hx - (1 - cl) * 6, hy, R * 0.7, R * 0.5, pi * 0.5, pi * 1.5, S.h)
        F.Arc(ps, hx + (1 - cl) * 6, hy, R * 0.7, R * 0.5, -pi * 0.5, pi * 0.5, S.h)
        F.Arc(ps, hx - (1 - cl) * 6 + 1, hy + 1, R * 0.7, R * 0.5, pi * 0.5, pi * 1.5, S.d)
        ps:Flush("over", fade)
        if p > 0.42 then F.StampB(F.GL.lock, hx, hy - R * 0.5 - 2 + (p < 0.5 and -1 or 0), S, { shadow = S.o, a = fade }) end
        F.Glow(hx, hy, 16, C("#9a5cff"), 0.35)
    end)
    r:At(0.3, function()
        F.Spray(X.hit[1], X.B.head[2] + 6, 6, { kind = "spark", cols = { S.w, S.h, S.l }, s = { 30, 60 }, ay = 80, life = { 0.2, 0.4 } })
    end)
    F.React(r, X, 0.3, { knock = 1, flash = C("#c8a0f0") })
end }

-- Earth: rocks, cracks, spikes and dust --------------------------------------------------------------------------

local E = PAL.EARTH
local EARTH5 = { E.o, E.d, E.m, E.l, E.h }
local PEBBLES = { E.d, E.m, E.l }
local STONES = { STONE.d, STONE.m, STONE.l }
local function Throw(r, X, o)
    F.Fly(r, X, { t0 = o.t0, dur = o.dur, arc = o.arc, shadow = o.r + 1, draw = function(x, y)
        F.DrawGen(F.Rock(o.r, EARTH5, floor(r.t * 14) % 4), x, y)
    end })
end
M.krockthrow = { desc = "A rock tumbles over and breaks into pebbles", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 16)
    Throw(r, X, { t0 = 0.12, dur = 0.32, arc = 16, r = 3 })
    F.React(r, X, 0.44, { knock = 2 })
    r:At(0.44, function()
        F.Spray(X.hit[1], X.hit[2], 5, { kind = "pebble", cols = PEBBLES, s = { 30, 65 }, ang = -pi / 2, spread = 2.2, ay = 300,
                ground = X.ground[2] + 2, life = { 0.6, 0.9 }, bounce = 0.35 })
        F.Spray(X.hit[1], X.hit[2], 2, { kind = "puff", cols = DUST, s = { 6, 14 }, life = { 0.4, 0.6 }, r0 = 1, r1 = 3, a = 0.8 })
    end)
end }

local DOWN = { h = STONE.h, l = STONE.l }
M.kcrusharmor = { desc = "Its hide cracks; chips fall and its Defense drops", play = function(r, X)
    r.dur = 0.78
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.34, 12)
    local cracks
    r:Span(0.16, 0.62, function(p)
        if not Hits(X) then return end
        if not cracks then
            cracks = {}
            for i = 0, 2 do
                local a = -1.2 + i * 1.1 + rr(-0.2, 0.2)
                cracks[#cracks + 1] = F.CrackPath(X.hit[1], X.hit[2], X.hit[1] + cos(a) * 9, X.hit[2] + sin(a) * 8, 2.5, 1.3)
            end
        end
        local ps, g = F.NewPS(), eOut(min(1, p / 0.3))
        for _, c in ipairs(cracks) do F.DrawPath(ps, c, g, STONE.h, 1, 0) F.DrawPath(ps, c, g, STONE.o) end
        ps:Flush("over", p > 0.75 and (1 - p) / 0.25 or 1)
    end)
    r:Span(0.32, 0.7, function(p)
        if Hits(X) then F.StampC(F.GL.down, X.B.head[1], X.B.head[2] - 2 + p * 5, DOWN, { shadow = STONE.o, a = p > 0.7 and (1 - p) / 0.3 or 1 }) end
    end)
    F.React(r, X, 0.17, { knock = 2, shake = 1, flash = C("#e6c88e") })
    r:At(0.18, function()
        if Hits(X) then F.Spray(X.hit[1], X.hit[2], 6, { kind = "pebble", cols = STONES, s = { 20, 45 }, ay = 260, ground = X.ground[2] + 2, life = { 0.5, 0.8 }, bounce = 0.3 }) end
    end)
end }

M.kboulder = { desc = "A boulder arcs high and lands with a thud", play = function(r, X)
    r.dur = 1.0
    F.Clip(X.a, 16)
    Throw(r, X, { t0 = 0.14, dur = 0.46, arc = 30, r = 6 })
    F.React(r, X, 0.6, { knock = 4, shake = 3, shakeDur = 0.3, stop = 0.05 })
    r:At(0.6, function()
        local g = X.ground
        F.Spray(X.hit[1], X.hit[2], 9, { kind = "chunk", cols = PEBBLES, s = { 35, 80 }, ang = -pi / 2, spread = 2.4, ay = 320, ground = g[2] + 3,
                life = { 0.7, 1.0 }, bounce = 0.3 })
        F.Spray(g[1], g[2], 8, { kind = "puff", cols = DUST, s = { 15, 35 }, ang = 0, spread = TAU, jy = 1, drag = 3, life = { 0.5, 0.9 }, r0 = 1.5, r1 = 4, a = 0.85 })
    end)
    r:Span(0.6, 0.9, function(p)
        local rad = 4 + 20 * eOut(p)
        F.Ring(X.ground[1], X.ground[2], rad, max(1, rad * 0.3), 1, DUST[2], 1 - p, "under")
    end)
end }

-- a stomp, a fissure along the ground to the foe, stone spikes bursting up under it (big: a boss's bigger quake)
local function QuakeRelease(r, X, big)
    r.dur = 1.25
    F.Clip(X.a, 16)
    local path
    local tA, tB = 0.08, 0.42
    r:Span(0, 0.1, function() F.Offset(X.a, 0, 3) end)
    r:At(0.05, function() F.Shake(1 + big, 0.4) end)
    r:Span(tA, 1.25, function(_, lt)
        if not path then path = F.CrackPath(X.A.feet[1] + X.dir * 6, X.A.feet[2] + 1, X.ground[1] - X.dir * 4, X.ground[2] + 1, 4, 2) end
        local q = F.clamp(lt / (tB - tA), 0, 1)
        local a = lt > 0.75 and max(0, 1 - (lt - 0.75) / 0.4) or 1
        local ps = F.NewPS()
        F.DrawPath(ps, path, q, E.h, 0, -1) F.DrawPath(ps, path, q, E.o)
        ps:Flush("under", a)
        if q < 1 and random() < 0.5 then
            local i = floor(q * (#path - 1)) + 1
            F.Emit({ kind = "puff", x = path[i][1], y = path[i][2], vx = rr(-6, 6), vy = -8, life = 0.5, r0 = 1, r1 = 3, cols = DUST, a = 0.8 })
        end
    end)
    r:Span(tB, 1.0, function(p)
        local g = X.ground
        local rise = p < 0.15 and p / 0.15 or p > 0.7 and 1 - (p - 0.7) / 0.3 or 1
        local spikes = { { -0.45, 9 * big + 3, 5 }, { 0.0, 13 * big + 3, 7 }, { 0.42, 8 * big + 3, 5 } }
        for i, s in ipairs(spikes) do F.Spike(floor(g[1] + s[1] * X.B.w * 1.1 + 0.5), g[2] + (i == 2 and -1 or 1), s[3], s[2], rise, STONE) end
    end)
    F.React(r, X, tB, { knock = 3, shake = 2 + big, shakeDur = 0.3, stop = 0.06 })
    if Hits(X) then r:Span(tB, tB + 0.3, function(p) Up(X.b, 5 * bump(p)) end) end
    r:At(tB, function()
        local g = X.ground
        F.Spray(g[1], g[2], 8, { kind = "puff", cols = DUST, s = { 15, 35 }, ang = -pi / 2, spread = pi * 1.4, drag = 3, life = { 0.5, 0.9 }, r0 = 1.5, r1 = 4, a = 0.85 })
        F.Spray(g[1], g[2] - 4, 8, { kind = "pebble", cols = STONES, s = { 40, 80 }, ang = -pi / 2, spread = 1.8, ay = 320, ground = g[2] + 2,
                life = { 0.6, 0.9 }, bounce = 0.3 })
    end)
end
F.QuakeRelease = QuakeRelease
M.kearthquake = { desc = "It stomps; a fissure runs to the foe and spikes burst up", play = function(r, X) QuakeRelease(r, X, 1) end }
-- Earthquake's turn of waiting: it stomps, cracks spread round its feet, pebbles hop
F.CASTS.quake = { cols = { STONE.h, STONE.l }, focus = function(s) local p = F.Pts(s) return { p.feet[1], p.feet[2] - 2 } end,
    windup = function(s, st, dt, big)
        local p = F.Pts(s)
        if st.tw % 0.7 < 0.08 then F.Offset(s, 0, big and 3 or 2) end
        if not st.cracks then
            st.cracks = {}
            for _ = 1, 3 do
                local a, r0 = rr(0, TAU), p.w * 0.35
                st.cracks[#st.cracks + 1] = F.CrackPath(p.feet[1] + cos(a) * r0, p.feet[2] + sin(a) * 2, p.feet[1] + cos(a) * (r0 + 9), p.feet[2] + sin(a) * 5, 3, 1.2)
            end
        end
        local ps = F.NewPS()
        for i, c in ipairs(st.cracks) do
            local g = F.clamp(st.tw * 2 - (i - 1) * 0.3, 0, 1)
            F.DrawPath(ps, c, g, E.o) F.DrawPath(ps, c, g, E.l, 0, -1)
        end
        ps:Flush("under")
        every(st, "p", 0.7, dt, function()
            F.Spray(p.feet[1], p.feet[2], big and 6 or 4, { kind = "pebble", cols = PEBBLES, s = { 20, 45 }, ang = -pi / 2, spread = pi * 0.8, ay = 300,
                    ground = p.feet[2] + 2, jx = p.w * 0.4, life = { 0.4, 0.6 }, bounce = 0.3 })
            if big then F.Shake(1, 0.12) end
        end)
    end }
F.CAST_OF.kearthquake = "quake"

M.kwarstomp = { desc = "A stomp sends a shock wave along the ground; it is dazed", play = function(r, X)
    r.dur = 0.9
    F.Clip(X.a, 16)
    r:Span(0.06, 0.18, function(p) F.Offset(X.a, 0, 3 * bump(p)) end)
    r:At(0.14, function() F.Shake(1, 0.15) end)
    local c = X.A.feet
    local dx, dy = X.ground[1] - c[1], X.ground[2] - c[2]
    local dist, ang = math.sqrt(dx * dx + dy * dy) + 12, math.atan2(dy, dx)
    r:Span(0.14, 0.52, function(p)
        local ps = F.NewPS()
        for k = 0, 2 do
            local q = p - k * 0.1
            if q > 0 and q <= 1 then
                local rad = 6 + dist * eOut(q)
                local s = -0.42
                while s <= 0.42 do
                    local a = ang + s
                    ps:Add(c[1] + cos(a) * rad, c[2] + sin(a) * rad * 0.55, DUST[k + 1])
                    ps:Add(c[1] + cos(a) * rad, c[2] + sin(a) * rad * 0.55 + 1, DUST[4])
                    s = s + 0.02
                end
            end
        end
        ps:Flush("under", 1 - p * 0.5)
        if random() < 0.5 then
            local rad, a = 6 + dist * eOut(p), ang + rr(-0.4, 0.4)
            F.Emit({ kind = "puff", x = c[1] + cos(a) * rad, y = c[2] + sin(a) * rad * 0.55, vy = -6, life = 0.5, r0 = 1, r1 = 2.5, cols = DUST, a = 0.8 })
        end
    end)
    F.React(r, X, 0.46, { knock = 1 })
    if Hits(X) then
        r:Span(0.46, 0.7, function(p) Up(X.b, 4 * bump(p)) end)
        F.Daze(r, X.b, 0.5, 0.4)
    end
end }

-- Air: dives, feathers, a hunter's lock and the wind --------------------------------------------------------------

local Ai = PAL.AIR
local FEATHER = F.Pal({ h = "#ece6d6", w = "#ffffff", m = "#9e9682", l = "#d8d2c0" })
M.kdive = { desc = "It climbs, swoops through the foe, feathers fly", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 16)
    local vx, vy = X.B.c[1] - X.A.c[1], X.B.c[2] - X.A.c[2]
    local ux, uy = F.unit(vx, vy)
    local trail = {}
    r:Span(0, 0.6, function(p)
        local ox, oy
        if p < 0.25 then local k = eOut(p / 0.25) ox, oy = -X.dir * 4 * k, -10 * k
        elseif p < 0.5 then local k = eIn((p - 0.25) / 0.25) ox, oy = lerp(-X.dir * 4, vx * 0.62, k), lerp(-10, vy * 0.62, k)
        else local k = eOut((p - 0.5) / 0.5) ox, oy = lerp(vx * 0.62, 0, k), lerp(vy * 0.62, 0, k) end
        F.Offset(X.a, ox, oy)
        table.insert(trail, 1, { ox, oy })
        if #trail > 8 then trail[9] = nil end
        if p > 0.25 and p < 0.55 then
            local g = trail[4] or trail[#trail]
            F.Ghost(X.a, g[1], g[2], 0.3, Ai.h)
            local ps = F.NewPS()
            for i = -1, 1 do
                local bx, by = X.A.c[1] + ox - ux * 6 + uy * i * 5, X.A.c[2] + oy - uy * 6 - ux * i * 5
                F.Line(ps, bx, by, bx - ux * 10, by - uy * 10, i == 0 and Ai.w or Ai.h)
            end
            ps:Flush("over", 0.85)
        end
    end)
    F.React(r, X, 0.3, { knock = 3, shake = 1 })
    if Hits(X) then F.Bonk(r, 0.3, X.hit, { Ai.h, WHITE }, 5) end
    r:At(0.3, function()
        if Hits(X) then F.Spray(X.hit[1], X.hit[2], 5, { kind = "feather", pal = FEATHER, s = { 20, 45 }, ay = 25, drag = 2.5, life = { 0.9, 1.3 } }) end
    end)
end }

local PING = { o = GOLD.o, h = WHITE, w = WHITE }
M.khuntersmark = { desc = "A gold lock snaps round it", play = function(r, X)
    r.dur = 0.72
    F.Clip(X.a, 54)
    r:Span(0.08, 0.6, function(p)
        if X.miss then return end
        local e = 3 + 14 * (1 - eOut(F.clamp(p / 0.45, 0, 1)))
        F.Brackets(X.B, e, (p > 0.45 and p < 0.58) and PING or GOLD, 1)
        if p > 0.45 then
            local q = (p - 0.45) / 0.55
            local rad = 2 + 9 * eOut(q)
            F.Ring(X.B.c[1], X.B.c[2], rad, rad * 0.8, 1, GOLD.h, 1 - q)
            if q < 0.4 then F.Rect(X.B.c[1], X.B.c[2], 1, 1, GOLD.w) F.Star(X.B.c[1], X.B.c[2], 30 * (1 - q), GOLD.h, 1 - q / 0.4) end
        end
    end)
end }

M.ktalonrake = { desc = "Two rakes from above; on an Exposed foe the lock shatters into it", play = function(r, X)
    r.dur = X.combo and 0.95 or 0.8
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.36, 12)
    local cols = { Ai.d, Ai.l, WHITE }
    F.Slashes(r, X, { t0 = 0.12, n = 3, len = 14, gap = 3, ang = X.dir > 0 and 1.75 or pi - 1.75, cols = cols, bend = 2 })
    F.Slashes(r, X, { t0 = 0.22, n = 3, len = 14, gap = 3, ang = X.dir > 0 and 1.25 or pi - 1.25, cols = cols, bend = -2 })
    F.React(r, X, 0.15, { knock = 2 })
    F.React(r, X, 0.25, { knock = 2 })
    r:At(0.25, function()
        if Hits(X) then F.Spray(X.hit[1], X.hit[2], 3, { kind = "feather", pal = FEATHER, s = { 15, 35 }, ay = 25, drag = 2.5, life = { 0.8, 1.2 } }) end
    end)
    F.ComboFx(r, X, 0.4)
    if X.combo and not X.miss then
        r:Span(0.34, 0.42, function(p) F.Brackets(X.B, 3 - 3 * p, PING, 1) end)
        r:At(0.42, function()
            local B = X.B
            for _, c in ipairs({ { B.l, B.top }, { B.r, B.top }, { B.l, B.bot }, { B.r, B.bot } }) do
                F.Spray(c[1], c[2], 4, { kind = "shard", cols = { GOLD.w, GOLD.l }, s = { 30, 60 }, ay = 160, life = { 0.4, 0.6 } })
            end
        end)
    end
end }

M.ktempest = { desc = "A whirlwind spins up round it, then a tornado lifts the foe", play = function(r, X)
    r.dur = 1.3
    F.Clip(X.a, 54)
    local travel, t0, hold = 0.36, 0.05, 0.42
    local leafC, rockC = PAL.NATURE.l, PAL.EARTH.l
    r:Span(t0, t0 + travel + hold + 0.2, function(_, lt)
        local q = F.clamp(lt / travel, 0, 1)
        local fin = F.clamp((lt - travel - hold) / 0.2, 0, 1)
        local x, y = lerp(X.A.feet[1], X.ground[1], eOut(q)), lerp(X.A.feet[2], X.ground[2], eOut(q))
        local sc = lerp(1, 0.85, X.dir > 0 and q or 1 - q) * (1 + fin * 0.6)
        local pf, pb = F.NewPS(), F.NewPS()
        local Hh = 40 * sc
        F.Disc(x, y, 7 * sc, 2, C("#0b0d06"), 0.25 * (1 - fin), "under")
        for i = 0, 6 do
            local f = i / 6
            local rx = (2 + 11 * f) * sc
            local ry = max(1, rx * 0.3)
            local cy, sw, ph = y - f * Hh, sin(lt * 7 + i * 0.8) * 2 * f, lt * 11 + i * 1.2
            local s = ph
            while s < ph + 2.2 do (sin(s) > 0 and pf or pb):Add(x + sw + cos(s) * rx, cy + sin(s) * ry + 1, Ai.d) s = s + 0.05 end
            s = ph
            while s < ph + 2.2 do
                local set = sin(s) > 0 and pf or pb
                set:Add(x + sw + cos(s) * rx, cy + sin(s) * ry, s > ph + 1.7 and Ai.w or (i % 2 == 1 and Ai.l or Ai.m))
                s = s + 0.05
            end
            s = ph + pi
            while s < ph + pi + 1.2 do (sin(s) > 0 and pf or pb):Add(x + sw + cos(s) * rx, cy + sin(s) * ry, Ai.d) s = s + 0.05 end
        end
        for d = 0, 3 do
            local a = lt * 9 + d * TAU / 4
            local set = sin(a) > 0 and pf or pb
            set:Add(x + cos(a) * 9 * sc, y - 8 - d * 6 + sin(a) * 2, d % 2 == 1 and leafC or rockC)
        end
        pb:Flush("under", 1 - fin) pf:Flush("over", 1 - fin)
        if q >= 1 and fin == 0 and Hits(X) then
            Up(X.b, 6 * min(1, (lt - travel) / 0.15))
            Jolt(X.b, lt, 20)
        end
        F.Glow(x, y - Hh / 2, 24, C("#a8c4ff"), 0.3 * (1 - fin))
    end)
    r:Span(t0 + travel + 0.15, t0 + travel + 0.2, function()
        if X.miss then return end
        local ps = F.NewPS()
        F.Zigzag(ps, X.ground[1], X.ground[2] - 34, X.B.c[1], X.B.c[2], 4, 3, { Ai.m, WHITE })
        ps:Flush("over")
        F.Light(X.b, WHITE, 0.3)
        F.Star(X.B.c[1], X.B.c[2], 40, WHITE, 1)
    end)
    F.React(r, X, t0 + travel, { knock = 0, shake = 1, flash = C("#e6eeff") })
end }
-- Tempest's turn of waiting: bands of wind spin up round it, leaves and grit caught in them
F.CASTS.tempest = { cols = { Ai.w, Ai.l }, focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] } end,
    windup = function(s, st, dt)
        local p = F.Pts(s)
        local k = min(1, st.tw / 0.6)
        local pf, pb = F.NewPS(), F.NewPS()
        for b2 = 0, 2 do
            local cy = p.feet[2] - 2 - b2 * p.h * 0.32
            local rx, ry = (p.w * 0.45 + 3 + b2 * 2) * (0.5 + 0.5 * k), 2.5 + b2
            for d = 0, 1 do
                local a0 = st.tw * (6 + b2) + d * pi + b2
                local a = a0
                while a < a0 + 1.4 do
                    local set = sin(a) > 0 and pf or pb
                    set:Add(p.c[1] + cos(a) * rx, cy + sin(a) * ry + 1, Ai.d)
                    set:Add(p.c[1] + cos(a) * rx, cy + sin(a) * ry, a > a0 + 1.0 and Ai.w or Ai.l)
                    a = a + 0.05
                end
            end
        end
        for i = 0, 3 do
            local a = st.tw * 7 + i * TAU / 4
            local set = sin(a) > 0 and pf or pb
            set:Add(p.c[1] + cos(a) * (p.w * 0.5 + 4), p.feet[2] - 4 - i * 4 + sin(a) * 3, i % 2 == 1 and PAL.NATURE.l or PAL.EARTH.l)
        end
        pb:Flush("under") pf:Flush("over")
        every(st, "p", 0.25, dt, function()
            F.Emit({ kind = "puff", x = p.feet[1] + rr(-p.w * 0.4, p.w * 0.4), y = p.feet[2], vx = rr(-10, 10), vy = -4, life = 0.5, r0 = 1, r1 = 2.5, cols = DUST, a = 0.6 })
        end)
        F.Glow(p.c[1], p.c[2], p.w, C("#a8c4ff"), 0.18, "under")
    end }
F.CAST_OF.ktempest = "tempest"

M.kscreech = { desc = "Sound waves roll over it; it shudders", play = function(r, X)
    r.dur = 0.64
    F.Clip(X.a, 54)
    for i = 0, 2 do
        F.Fly(r, X, { t0 = 0.08 + i * 0.07, dur = 0.24, draw = function(x, y, q, vx)
            local ps, f = F.NewPS(), vx >= 0 and 1 or -1
            local rad = 3 + 6 * q
            F.SoundArc(ps, x, y, rad, f, Ai.w)
            F.SoundArc(ps, x - f, y, rad, f, Ai.l)
            ps:Flush("over", 0.95)
        end })
    end
    F.React(r, X, 0.32, { knock = 0, flash = C("#f0f4ff") })
    if Hits(X) then r:Span(0.32, 0.6, function(_, lt) Jolt(X.b, lt, 30) end) end
end }

-- Mech: cogs, sparks, rockets, sawblades and lightning ------------------------------------------------------------

local Me = PAL.MECH
local METAL = { Me.o, Me.d, Me.m, Me.l, Me.h }
local VOLTS = { VOLT.w, VOLT.l, VOLT.m }
local ARC = { VOLT.m, VOLT.w }
M.kgears = { desc = "Two cogs grind on it in a shower of sparks", play = function(r, X)
    r.dur = 0.64
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.36, 12)
    r:Span(0.12, 0.44, function(p, lt)
        if X.miss then return end
        local c, k = X.hit, floor(lt * 20) % 3
        local a = p > 0.8 and (1 - p) / 0.2 or 1
        F.DrawGen(F.Gear(4, METAL, k, 8), c[1] - 3, c[2] - 3, { a = a })
        F.DrawGen(F.Gear(4, METAL, 2 - k, 8), c[1] + 4, c[2] + 3, { a = a })
        if p < 0.85 then
            F.Spray(c[1] + 1, c[2], 2, { kind = "spark", cols = SPARK, s = { 40, 90 }, ang = -pi / 2 - X.dir * 0.6, spread = 1.6, ay = 240,
                    ground = X.ground[2] + 2, life = { 0.25, 0.45 } })
        end
        F.Glow(c[1], c[2], 12, C("#ffb040"), 0.4)
    end)
    F.React(r, X, 0.16, { knock = 2 })
    if Hits(X) then r:Span(0.2, 0.44, function(_, lt) if floor(lt * 24) % 2 == 1 then F.Offset(X.b, 1, 0) end end) end
end }

M.kchargeup = { desc = "Arcs crackle over it as it charges", play = function(r, X)
    r.dur = 0.78
    F.Clip(X.a, 54)
    local A = X.A
    local arcs, acc = {}, -1
    r:Span(0.04, 0.66, function(p, lt)
        if lt - acc > 0.05 then
            acc = lt
            for i = 1, 3 do
                local x0, y0 = A.c[1] + rr(-A.w * 0.4, A.w * 0.4), A.c[2] + rr(-A.h * 0.4, A.h * 0.3)
                arcs[i] = { x0, y0, x0 + rr(-9, 9), y0 + rr(-8, 8) }
            end
        end
        local ps = F.NewPS()
        for _, a in ipairs(arcs) do F.Zigzag(ps, a[1], a[2], a[3], a[4], 3, 2, ARC) end
        ps:Flush("over")
        if random() < 0.6 then
            F.Spray(A.c[1] + rr(-A.w * 0.4, A.w * 0.4), A.c[2] + rr(-A.h * 0.3, A.h * 0.3), 1, { kind = "spark", cols = VOLTS, s = { 20, 50 }, ay = 80, life = { 0.2, 0.35 } })
        end
        F.Glow(A.c[1], A.c[2], A.w * (0.6 + 0.8 * p), C("#3fe0d0"), 0.45 * p + 0.1)
    end)
    r:Span(0.58, 0.72, function(p) F.Light(X.a, C("#9af2e8"), 0.4 * (1 - p)) end)
end }

local VOLT5 = { VOLT.w, VOLT.h, VOLT.l, VOLT.m, VOLT.d }
M.krocketpunch = { desc = "A rocket fist; Charged, it lands in a burst of lightning", play = function(r, X)
    r.dur = X.combo and 0.95 or 0.8
    F.Clip(X.a, 16)
    F.Fly(r, X, { t0 = 0.12, dur = 0.28, arc = 3, draw = function(x, y, q, vx)
        local right = vx >= 0
        local g = F.Comet(1, 5, FIRE5, floor(r.t * 14) % 3)
        F.Stamp(g, right and x - 4 - g.w or x + 4, y - 1, nil, { flip = not right })
        F.StampC(F.GL.fist, x, y, Me, { flip = not right })
        if X.combo then
            local ps = F.NewPS()
            F.Zigzag(ps, x - 5, y - 4, x + 5, y + 4, 2, 2, ARC)
            ps:Flush("over")
            F.Glow(x, y, 16, C("#3fe0d0"), 0.6)
        end
        F.Glow(x - (right and 6 or -6), y, 10, C("#ff8a2a"), 0.45)
    end, trail = function(x, y, q, vx)
        if random() < 0.55 then F.Emit({ kind = "puff", x = x - (vx >= 0 and 7 or -7), y = y, vy = -5, life = 0.55, r0 = 1, r1 = 2.5, cols = SMOKE, a = 0.7 }) end
    end })
    if X.combo then
        F.Explode(r, 0.4, X.hit, 8, VOLT5, { glow = C("#3fe0d0"), sparkCols = VOLTS, sparks = 16 })
    else
        F.Explode(r, 0.4, X.hit, 5, F.FIRE_R, { puffs = 3, sparks = 10, sparkCols = SPARK })
    end
    F.React(r, X, 0.4, { knock = 3, shake = 1 })
    F.ComboFx(r, X, 0.4)
    if X.combo and not X.miss then
        r:Span(0.4, 0.62, function(p)
            local ps = F.NewPS()
            for i = 0, 2 do
                local a = i * TAU / 3 + p * 2
                F.Zigzag(ps, X.hit[1], X.hit[2], X.hit[1] + cos(a) * 14, X.hit[2] + sin(a) * 10, 3, 2, ARC)
            end
            ps:Flush("over", 1 - p)
        end)
    end
end }

local function SawAt(s, i, ang)
    local p = F.Pts(s)
    local a = ang + i * TAU / 3
    return p.c[1] + cos(a) * (p.w * 0.55 + 5), p.c[2] + sin(a) * (p.h * 0.18 + 2), a
end
-- Sawblade Storm's turn of waiting: three blades circle it, faster and faster, sparks flying off
F.CASTS.sawstorm = { cols = { Me.h, SPARK[2] }, focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] } end,
    windup = function(s, st, dt)
        local spd = 2 + 7 * min(1, st.tw / 1.0)
        st.ang = (st.ang or 0) + spd * dt
        for i = 0, 2 do
            local x, y, a = SawAt(s, i, st.ang)
            F.DrawGen(F.Saw(4, METAL, floor(st.tw * 18) % 3), x, y, { lay = sin(a) > 0 and "over" or "under" })
            if spd > 6 and random() < 0.15 then
                F.Spray(x, y, 1, { kind = "spark", cols = SPARK, s = { 40, 70 }, ang = a + pi / 2, spread = 0.6, ay = 150, life = { 0.2, 0.35 } })
            end
        end
    end }
F.CAST_OF.ksawstorm = "sawstorm"
M.ksawstorm = { desc = "Sawblades spin up round it, then fly in one by one", play = function(r, X)
    r.dur = 1.05
    F.Clip(X.a, 16)
    for i, t0 in ipairs({ 0.05, 0.15, 0.25 }) do
        local fx, fy = SawAt(X.a, i - 1, 0)
        local to = { X.hit[1] + (i - 2) * 3, X.hit[2] + (i - 2) * 4 }
        F.Fly(r, X, { t0 = t0, dur = 0.22, from = { fx, fy }, to = to, draw = function(x, y)
            F.DrawGen(F.Saw(4, METAL, floor(r.t * 24) % 3), x, y)
        end })
        r:Span(t0 + 0.22, t0 + 0.42, function(p)
            F.DrawGen(F.Saw(4, METAL, floor(r.t * 24) % 3), to[1] - X.dir * 14 * p, to[2] - 18 * bump(p * 0.6) - 8 * p, { a = 1 - p })
        end)
        r:At(t0 + 0.22, function()
            if not X.miss then F.Spray(to[1], to[2], 8, { kind = "spark", cols = SPARK, s = { 40, 90 }, ang = -pi / 2, spread = 2.2, ay = 240, life = { 0.25, 0.45 } }) end
        end)
        F.React(r, X, t0 + 0.22, { knock = 2, shake = i == 3 and 2 or nil })
    end
end }

local VOLT_DIM = { VOLT.d, VOLT.l }
M.kshock = { desc = "A crackling bolt jumps to it; it jolts", play = function(r, X)
    r.dur = 0.58
    F.Clip(X.a, 54)
    r:Span(0.1, 0.38, function()
        local ps, side = F.NewPS(), F.NewPS()
        F.Zigzag(ps, X.muzzle[1], X.muzzle[2], X.hit[1], X.hit[2], 7, 4, ARC)
        if random() < 0.5 then F.Zigzag(side, X.hit[1] - X.dir * 10, X.hit[2] - 8, X.hit[1], X.hit[2], 3, 2, VOLT_DIM) end
        side:Flush("over") ps:Flush("over")
        F.Glow(X.hit[1], X.hit[2], 16, C("#3fe0d0"), 0.6)
        F.Glow(X.muzzle[1], X.muzzle[2], 10, C("#3fe0d0"), 0.5)
    end)
    F.React(r, X, 0.12, { knock = 1, flash = C("#c9fff8") })
    if Hits(X) then
        r:Span(0.12, 0.4, function(_, lt)
            Jolt(X.b, lt, 30)
            if floor(lt * 20) % 2 == 1 then F.Light(X.b, C("#c9fff8"), 0.45) end
        end)
    end
    r:At(0.14, function()
        if not X.miss then F.Spray(X.hit[1], X.hit[2], 8, { kind = "spark", cols = VOLTS, s = { 30, 70 }, ay = 120, life = { 0.2, 0.4 } }) end
    end)
end }

---------------------------------------------------------------------------
-- 0.43 (step 3): the other signature shapes, and the bosses' own casts, heals and rallies
---------------------------------------------------------------------------

local SS = F.SIG_SHAPES

-- a slam: it lunges in hard; a hit star, two dust rings and pebbles at the target's feet
SS.smash = function(r, X, cast)
    local p = X.pal
    local big = cast and 1.35 or 1
    r.dur = cast and 1.08 or 0.9
    F.Clip(X.a, 16)
    F.Lunge(r, X, 0, 0.4, 16)
    F.React(r, X, 0.2, { knock = 3, shake = cast and 3 or 2, stop = 0.05 })
    if Hits(X) then F.Bonk(r, 0.2, X.hit, { p.l, WHITE }, 7) end
    r:Span(0.2, 0.55, function(q)
        for k = 0, 1 do
            local rad = 4 + (18 + k * 8) * eOut(q) * big
            F.Ring(X.ground[1], X.ground[2], rad, max(1, rad * 0.3), 1, DUST[k == 0 and 1 or 3], 1 - q, "under")
        end
    end)
    r:At(0.2, function()
        local g = X.ground
        F.Spray(g[1], g[2] - 3, 8, { kind = "pebble", cols = PEBBLES, s = { 30, 70 }, ang = -pi / 2, spread = 2, ay = 300, ground = g[2] + 2,
                life = { 0.5, 0.8 }, bounce = 0.3 })
        F.Spray(g[1], g[2], 6, { kind = "puff", cols = DUST, s = { 15, 30 }, drag = 3, life = { 0.5, 0.8 }, r0 = 1.5, r1 = 4, a = 0.85 })
    end)
end

-- a volley of small shards in its type's colours (Crystal Spines), or of petals (Razor Petal)
SS.volley = function(r, X, cast, scatter)
    local p = X.pal
    r.dur = 0.85
    F.Clip(X.a, 54)
    local petals = (X.mv.name or ""):find("Petal", 1, true)
    for i = 1, 7 do
        local to = { X.hit[1] + rr(-6, 6), X.hit[2] + rr(-6, 6) }
        F.Fly(r, X, { t0 = 0.1 + (i - 1) * 0.045, dur = 0.22, arc = rr(2, 10), to = to, draw = function(x, y, q, vx, vy)
            if petals then F.Rect(x, y, 2, 1, BLOOM.p) F.Rect(x + 1, y - 1, 1, 1, BLOOM.P) return end
            local ux, uy = F.unit(vx, vy)
            local ps = F.NewPS()
            ps:Add(x, y, p.w) ps:Add(x - ux, y - uy, p.h) ps:Add(x - ux * 2, y - uy * 2, p.l) ps:Add(x - ux * 3, y - uy * 3, p.m)
            ps:Flush("over")
        end })
    end
    F.React(r, X, 0.32, { knock = 2 })
    r:At(0.4, function() if Hits(X) then scatter(X.hit, 6) end end)
end

-- a spinning vortex on the target: a funnel that lifts it (Whirlwind, Cyclone), or a flat whirlpool round its feet
-- for a Water one (Maelstrom)
SS.vortex = function(r, X, cast)
    local p = X.pal
    local big = cast and 1.35 or 1
    local water = X.type == "WATER"
    local wide, tall = max(1, X.B.w / 24), max(30, X.B.h * 0.95)       -- (it wraps a big beast too)
    r.dur = cast and 1.15 or 1.05
    F.Clip(X.a, 54)
    r:Span(0.1, 0.9, function(q, lt)
        local g = X.ground
        local k = q < 0.2 and q / 0.2 or q > 0.8 and (1 - q) / 0.2 or 1
        local pf, pb = F.NewPS(), F.NewPS()
        for i = 0, 5 do
            local f = i / 5
            local rx = (water and (12 - 8 * f) or (3 + 9 * f)) * k * big * wide
            local ry = max(1, rx * (water and 0.32 or 0.28))
            local cy = water and g[2] - f * 4 or g[2] - f * tall * big
            local ph = lt * 12 + i
            local s = ph
            while s < ph + 3 do
                local front = sin(s) > 0
                local x, y = g[1] + cos(s) * rx, cy + sin(s) * ry
                local set = front and pf or pb
                set:Add(x, y, s > ph + 2.5 and p.w or (i % 2 == 1 and p.l or p.h))
                if front then set:Add(x, y + 1, p.m) end
                s = s + 0.05
            end
        end
        pb:Flush("under") pf:Flush("over")
        if Hits(X) and not water then Up(X.b, 4 * k) end
    end)
    F.React(r, X, 0.2, { knock = 0, shake = 1 })
    F.React(r, X, 0.6, { knock = 2 })
end

-- a wave rolls over the target (Tsunami, Riptide): Tidal Wave's breaker, in water's colours whatever the type
SS.wave = function(r, X)
    local X2 = {}
    for k, v in pairs(X) do X2[k] = v end
    X2.pal = PAL.WATER
    M.ktidalwave.play(r, X2)
    r.dur = 1.2
end

-- a glob of poison arcs over and bubbles on the target (Poison Spit, Corrosive Poison)
local VENOM = F.Ramp({ "#1e3a10", "#4a7a1a", "#86c42a", "#c8f060", "#eaffb0" })
local VENOM_DROP = { VENOM[3], VENOM[4] }
local BUBBLES = { VENOM[3], VENOM[5] }
SS.spit = function(r, X)
    r.dur = 0.85
    F.Clip(X.a, 54)
    F.Fly(r, X, { t0 = 0.12, dur = 0.3, arc = 10, draw = function(x, y) F.DrawGen(F.Ball(2, VENOM, "lit"), x, y) end, trail = function(x, y)
        if random() < 0.5 then F.Emit({ kind = "drop", x = x, y = y + 1, vy = 10, ay = 200, life = 0.3, cols = VENOM_DROP }) end
    end })
    F.React(r, X, 0.42, { knock = 2, flash = C("#d8ff90") })
    r:Span(0.42, 0.85, function()
        if Hits(X) and random() < 0.4 then
            F.Emit({ kind = "bubble", x = X.B.c[1] + rr(-X.B.w * 0.35, X.B.w * 0.35), y = X.B.c[2] + rr(-4, 6), vy = -10, life = 0.5, cols = BUBBLES })
        end
    end)
end

-- dark fog closes round the target and two yellow eyes open in it (Nightmare)
local FOG = { PAL.SHADOW.o, PAL.SHADOW.d }
local EYES = C("#ffe060")
SS.dread = function(r, X, cast)
    r.dur = 1.15
    F.Clip(X.a, 54)
    r:Span(0.08, 1.0, function(q, lt)
        local c = X.B.c
        local k = q < 0.25 and q / 0.25 or q > 0.75 and (1 - q) / 0.25 or 1
        for i = 0, 6 do
            local a = i * TAU / 7 + lt * 0.8
            local rad = X.B.w * 0.45 * (1.4 - 0.4 * k)
            F.Disc(c[1] + cos(a) * rad, c[2] + sin(a) * rad * 0.6, 4 * k + 1, 3 * k + 1, FOG[i % 2 + 1], 0.7 * k)
        end
        if q > 0.3 and q < 0.8 and floor(lt * 3) % 3 ~= 2 then
            local ex, ey = c[1] - X.dir * 4, c[2] - X.B.h * 0.25
            F.Rect(ex - 4, ey, 2, 1, EYES) F.Rect(ex + 3, ey, 2, 1, EYES)
            F.Glow(ex, ey, 10, EYES, 0.4)
        end
    end)
    F.React(r, X, 0.4, { knock = 1, flash = C("#8a60c0") })
    F.React(r, X, 0.7, { knock = 2, shake = cast and 2 or 1 })
    r:Span(0.3, 0.9, function() if Hits(X) then F.Shade(X.b, 0.69, 0.63, 0.78) end end)
end

-- one big sawblade flies in, grinds in a shower of sparks, then spins away (Buzzsaw)
local BLADE = { Me.o, Me.d, Me.m, Me.l, Me.w }
SS.saw = function(r, X)
    r.dur = 0.9
    F.Clip(X.a, 16)
    F.Fly(r, X, { t0 = 0.1, dur = 0.3, arc = 4, draw = function(x, y) F.DrawGen(F.Saw(5, BLADE, floor(r.t * 24) % 3), x, y) end })
    r:Span(0.4, 0.6, function()
        F.DrawGen(F.Saw(5, BLADE, floor(r.t * 30) % 3), X.hit[1] + rr(-1, 1), X.hit[2])
        if not X.miss then F.Spray(X.hit[1], X.hit[2], 2, { kind = "spark", cols = SPARK, s = { 40, 90 }, ang = -pi / 2, spread = 2, ay = 240, life = { 0.2, 0.4 } }) end
    end)
    r:Span(0.6, 0.85, function(q)
        F.DrawGen(F.Saw(5, BLADE, floor(r.t * 24) % 3), X.hit[1] - X.dir * 18 * q, X.hit[2] - 20 * bump(q * 0.6), { a = 1 - q })
    end)
    F.React(r, X, 0.4, { knock = 3, shake = 2 })
end

-- Bosses: each named boss's big cast (it can't be interrupted) has a family that picks its wind-up and its blow; a
-- boss without one winds up like its type's big cast and plays the signature shape its cast's name picks.

local BOSS_FAMILY = { hogger = "smash", vancleef = "flurry", stitches = "smash", mukla = "quake", smite = "stomp",
                      firallon = "broadside", bangalash = "flurry", rhahkzor = "smash" }
function F.BossFamily(k) return BOSS_FAMILY[k] end

local HURL = C("#ffd0b0")
local STEEL = F.Pal({ l = "#c8d0e0", h = "#eef2fa" })
local FUSE = C("#ffb040")
-- the cannon a boss fires a broadside from: just in front of it, at its middle
local function BroadsideFrom(s)
    local p = F.Pts(s)
    return { s == "foe" and p.l - 4 or p.r + 4, p.c[2] }
end
local BOSS_CAST = {
    -- it leaps and lands on the target: a hit star, three dust rings, chunks of earth and a crater
    smash = function(r, X)
        r.dur = 1.15
        F.Clip(X.a, 16)
        local vx, vy = X.B.c[1] - X.A.c[1], X.B.c[2] - X.A.c[2]
        local trail = {}
        r:Span(0, 0.66, function(p)
            local k = p < 0.45 and eOut(p / 0.45) or 1 - eIn((p - 0.45) / 0.55)
            local ox, oy = vx * 0.55 * k, vy * 0.55 * k - (p < 0.45 and 18 * bump(p / 0.45) or 0)
            F.Offset(X.a, ox, oy)
            table.insert(trail, 1, { ox, oy })
            if #trail > 6 then trail[7] = nil end
            if p > 0.1 and p < 0.45 then local g = trail[4] or trail[#trail] F.Ghost(X.a, g[1], g[2], 0.3, HURL) end
        end)
        F.React(r, X, 0.32, { knock = 5, shake = 4, shakeDur = 0.4, stop = 0.08 })
        if not X.guarded then F.Bonk(r, 0.32, X.hit, { C("#ffd84a"), WHITE }, 9) end
        r:Span(0.32, 0.75, function(q)
            for k = 0, 2 do
                local rad = 4 + (16 + k * 10) * eOut(q)
                F.Ring(X.ground[1], X.ground[2], rad, max(1, rad * 0.3), 1, DUST[k + 1], 1 - q, "under")
            end
        end)
        r:At(0.32, function()
            local g = X.ground
            F.Spray(g[1], g[2] - 3, 12, { kind = "chunk", cols = PEBBLES, s = { 40, 90 }, ang = -pi / 2, spread = 2.2, ay = 320, ground = g[2] + 3,
                    life = { 0.7, 1.0 }, bounce = 0.3 })
            F.Spray(g[1], g[2], 10, { kind = "puff", cols = DUST, s = { 15, 40 }, drag = 3, life = { 0.6, 1.0 }, r0 = 1.5, r1 = 5, a = 0.9 })
            F.Emit({ kind = "decal", x = g[1], y = g[2], r0 = 13, life = 1.4, cols = { C("#2a1c0c") }, a = 0.5 })
        end)
    end,
    -- War Stomp, bigger: a wider shock wave and a harder shake
    stomp = function(r, X)
        M.kwarstomp.play(r, X)
        r.dur = 1.0
        r:At(0.14, function() F.Shake(3, 0.35) end)
        r:Span(0.14, 0.6, function(p)
            local c = X.A.feet
            for k = 0, 1 do
                local rad = 6 + (30 + k * 14) * eOut(p)
                F.Ring(c[1], c[2], rad, max(1, rad * 0.3), 1, DUST[k + 1], 1 - p, "under")
            end
        end)
        F.React(r, X, 0.46, { knock = 4, shake = 3, stop = 0.06 })
    end,
    flurry = function(r, X) SigPlay("flurry", r, X, true) end,
    quake = function(r, X) QuakeRelease(r, X, 1.6) end,
    -- three cannonballs, one after another, each bursting where it lands
    broadside = function(r, X)
        r.dur = 1.25
        F.Clip(X.a, 54)
        local from = BroadsideFrom(X.a)
        for i = 0, 2 do
            local to = { X.ground[1] + (i - 1) * 12, X.ground[2] - 4 + (i % 2) * 3 }
            local t0 = 0.05 + i * 0.14
            r:At(t0, function()
                F.Spray(from[1], from[2], 4, { kind = "puff", cols = SMOKE, s = { 8, 20 }, ang = X.dir > 0 and 0 or pi, spread = 1.2,
                        life = { 0.5, 0.8 }, r0 = 1, r1 = 3, a = 0.8 })
            end)
            r:Span(t0, t0 + 0.05, function() F.Glow(from[1], from[2], 14, FUSE, 0.8) F.Star(from[1], from[2], 26, C("#ffe0a0"), 1) end)
            F.Fly(r, X, { t0 = t0, dur = 0.34, arc = 24, from = from, to = to, shadow = 3, draw = function(x, y)
                F.DrawGen(F.Ball(3, CANNONBALL, "lit"), x, y)
            end })
            F.Explode(r, t0 + 0.34, to, 8, F.FIRE_R, { puffs = 4, sparks = 12 })
            F.React(r, X, t0 + 0.34, { knock = 2, shake = 2 })
        end
    end,
}
F.BOSS_CAST = BOSS_CAST

-- the cast a boss must be interrupted in: a heal, or a rally that sharply raises its Attack
local RAGE = F.Pal({ o = "#3a0808", d = "#7e1414", m = "#c8302a", l = "#f06048", h = "#ffa080", w = "#ffe0d0" })
local RAGE_UP = { h = RAGE.h, l = RAGE.m }
local BOSS_SECOND = {
    -- green light rises round it in columns, plus signs float up
    heal = function(r, X)
        r.dur = 0.95
        F.Clip(X.a, 54)
        local A = X.A
        r:Span(0.04, 0.7, function(p)
            for col = 0, 3 do
                local x = A.c[1] + (col - 1.5) * A.w * 0.28
                local top = A.feet[2] - (A.h + 20) * eOut(min(1, p * 1.6))
                local y = A.feet[2]
                while y > top do
                    F.Rect(x, y - 5, 3, 5, HEAL.h, 0.38 * (1 - (A.feet[2] - y) / (A.h + 24)) * (1 - eIn(p)), col % 2 == 1 and "under" or "over")
                    y = y - 5
                end
            end
            F.Glow(A.c[1], A.c[2], A.w * 1.4, C("#7ee05a"), 0.5 * bump(p), "under")
        end)
        for i, t in ipairs({ 0.2, 0.32, 0.44, 0.56 }) do
            r:Span(t, t + 0.3, function(p)
                F.StampC(F.GL.plus, A.c[1] + (i % 2 == 0 and 1 or -1) * A.w * (0.1 + 0.1 * i), A.c[2] - p * 10 + (i - 1) * 2,
                         { w = p < 0.5 and HEAL.w or HEAL.h }, { shadow = HEAL.o, a = 1 - eIn(p) })
            end)
        end
        r:Span(0.15, 0.6, function(p) F.Light(X.a, C("#b8f080"), 0.3 * bump(p)) end)
    end,
    -- red flames flicker up in a ring round its feet, three arrows rise
    rally = function(r, X)
        r.dur = 0.95
        F.Clip(X.a, 54)
        local A = X.A
        r:Span(0.04, 0.7, function(p, lt)
            local up = p < 0.2 and p / 0.2 or p > 0.7 and (1 - p) / 0.3 or 1
            for i = 0, 5 do
                local a = i * TAU / 6 + 0.4
                local x, y = A.feet[1] + cos(a) * (A.w * 0.5 + 2), A.feet[2] + sin(a) * 3 + 1
                local g = up > 0.5 and F.GL.flame or F.GL.flameS
                F.StampB(g[(floor(lt * 12) + i) % 3 + 1], x, y, RAGE, { lay = sin(a) < 0 and "under" or "over" })
            end
            F.Glow(A.c[1], A.c[2], A.w * 1.3, C("#ff5a3a"), 0.5 * up, "under")
        end)
        for i, t in ipairs({ 0.15, 0.27, 0.39 }) do
            r:Span(t, t + 0.4, function(p)
                F.StampC(F.GL.up, A.c[1] + (i - 2) * 8, A.c[2] - p * 16, RAGE_UP, { shadow = RAGE.o, a = 1 - eIn(p) })
            end)
        end
        r:Span(0.1, 0.5, function(p) F.Light(X.a, C("#ff6a4a"), 0.3 * bump(p)) end)
    end,
}
F.BOSS_SECOND = BOSS_SECOND

-- a boss move's recipe (bcast_<boss>, bsecond_<boss>), or nil
function F.Boss(id, mv)
    if not (id and mv) then return nil end
    if id:match("^bcast_") then
        local fam = BOSS_FAMILY[id:sub(7)]
        if fam then return { play = BOSS_CAST[fam] } end
        local shape = ShapeOf(mv.name or "")
        return { play = function(r, X) SigPlay(shape, r, X, true) end }
    elseif id:match("^bsecond_") then
        return { play = mv.heal and BOSS_SECOND.heal or BOSS_SECOND.rally }
    end
    return nil
end

-- their turns of waiting
F.CASTS.smash = { cols = { E.h, E.l }, focus = F.CASTS.maul.focus, windup = function(s, st, dt)
    -- it crouches and rocks, dust puffs at its feet, a hot glow builds
    local p = F.Pts(s)
    F.Offset(s, 0, 2 - floor(st.tw * 3) % 2)
    every(st, "p", 0.35, dt, function()
        F.Emit({ kind = "puff", x = p.feet[1] + rr(-p.w * 0.45, p.w * 0.45), y = p.feet[2], vx = rr(-10, 10), vy = -5, life = 0.6, r0 = 1, r1 = 3,
                 cols = DUST, a = 0.85 })
    end)
    F.Glow(p.c[1], p.c[2], p.w * 1.1, C("#ff7a4a"), 0.2 + 0.1 * sin(st.tw * 6), "under")
end }
F.CASTS.flurry = { cols = { WHITE, STEEL.h }, focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] } end, windup = function(s, st, dt)
    -- blades glint all round it
    local p = F.Pts(s)
    every(st, "g", 0.18, dt, function()
        local a = rr(0, TAU)
        F.Emit({ kind = "glint", x = p.c[1] + cos(a) * p.w * 0.5, y = p.c[2] + sin(a) * p.h * 0.4, life = 0.32, cols = { STEEL.h, WHITE } })
    end)
    if floor(st.tw * 5.5) % 3 == 0 then F.Star(p.c[1] + p.w * 0.3, p.c[2] - p.h * 0.2, 18, WHITE, 0.7) end
    F.Glow(p.c[1], p.c[2], p.w, C("#ff8a6a"), 0.16, "under")
end }
F.CASTS.stomp = { cols = F.CASTS.quake.cols, focus = F.CASTS.quake.focus, windup = function(s, st, dt) F.CASTS.quake.windup(s, st, dt, true) end }
F.CASTS.broadside = { cols = { F.IRON.h, SPARK[1] }, focus = BroadsideFrom, windup = function(s, st, dt)
    -- a fuse fizzes beside it, smoke curls up
    local f = BroadsideFrom(s)
    every(st, "f", 0.05, dt, function()
        F.Emit({ kind = "spark", x = f[1], y = f[2], vx = rr(-20, 20), vy = rr(-40, -15), ay = 120, life = 0.3, cols = SPARK })
    end)
    every(st, "s", 0.2, dt, function()
        F.Emit({ kind = "puff", x = f[1], y = f[2] - 2, vx = rr(-6, 6), vy = -10, life = 0.8, r0 = 1, r1 = 2.5, cols = SMOKE, a = 0.7 })
    end)
    F.Rect(f[1], f[2], 1, 1, floor(st.tw * 12) % 2 == 1 and SPARK[1] or SPARK[2])
    F.Glow(f[1], f[2], 8, FUSE, 0.5)
end }
F.CASTS.heal = { cols = { HEAL.w, HEAL.l }, focus = function(s) local p = F.Pts(s) return { p.c[1], p.c[2] } end, windup = function(s, st, dt)
    -- green motes gather into it over a soft ring at its feet
    local p = F.Pts(s)
    F.Ring(p.feet[1], p.feet[2], p.w * 0.5 + 3, 3, 1, HEAL.w, 0.55 + 0.3 * sin(st.tw * 6), "under")
    F.Ring(p.feet[1], p.feet[2] + 1, p.w * 0.5 + 3, 3, 1, HEAL.d, 0.4, "under")
    every(st, "m", 0.05, dt, function()
        local a, R = rr(0, TAU), rr(18, 24)
        F.Seek(p.c[1] + cos(a) * R, p.c[2] + sin(a) * R * 0.8, p.c[1] + rr(-3, 3), p.c[2] + rr(-3, 3), 0.55, { HEAL.m, HEAL.l, HEAL.h }, -4)
    end)
    every(st, "M", 0.22, dt, function()
        local a, R = rr(0, TAU), rr(20, 26)
        F.Seek(p.c[1] + cos(a) * R, p.c[2] + sin(a) * R * 0.8, p.c[1], p.c[2], 0.6, { HEAL.h, HEAL.w }, -6, nil, true)
    end)
    F.Light(s, C("#b8f080"), 0.1 + 0.08 * sin(st.tw * 5))
    F.Glow(p.c[1], p.c[2], p.w, C("#7ee05a"), 0.22, "under")
end }
F.CASTS.rally = { cols = { RAGE.h, RAGE.l }, focus = function(s) local p = F.Pts(s) return { p.head[1], p.head[2] + 4 } end, windup = function(s, st, dt)
    -- it shouts: red arcs ripple out from its head, it shakes with it
    local p = F.Pts(s)
    local ps = F.NewPS()
    for k = 0, 1 do
        local q = ((st.tw + k * 0.25) % 0.5) / 0.5
        local rad = 3 + q * 10
        if q < 0.9 then
            F.SoundArc(ps, p.head[1] + 4, p.head[2] + 4, rad, 1, q < 0.5 and RAGE.h or RAGE.l)
            F.SoundArc(ps, p.head[1] - 4, p.head[2] + 4, rad, -1, q < 0.5 and RAGE.h or RAGE.l)
        end
    end
    ps:Flush("over", 0.9)
    if floor(st.tw * 10) % 2 == 1 then F.Offset(s, 1, 0) end
    F.Glow(p.c[1], p.c[2], p.w, C("#ff5a3a"), 0.2 + 0.12 * sin(st.tw * 8), "under")
end }

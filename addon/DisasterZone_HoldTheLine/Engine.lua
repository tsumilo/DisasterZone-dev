if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Engine.lua", ...) then return end -- DisasterZone_HoldTheLine/Engine.lua
-- ns.HTL: Hold the Line's run - a port of the mockup's game.js, frame-free: E.New makes a run, E.Step(run, dt, input)
-- moves it, the renderer (HoldTheLine/Render.lua) draws whatever a run holds. The simulation's dice come from the
-- run's seed (Park-Miller, as The Binding of Illidan); the looks' dice (sparks, gore, souls) from math.random.
-- Effects are particles (pooled tables) in run.parts: img (an FX texture name), tint, x y z, vx vy vz, g, drag,
-- life, s0 s1 (size), a0 a1 (alpha), fi (fade-in share), rot vr, add (additive), cell (flipbook), stretch
-- (drawn along its velocity), flat (on the ground), under (under the bodies), sx sy, light, bounce, decal.
-- Sounds go out through run.onSound(name, gap, vol) (the UI plays the client's sound files).
local _, ns = ...

local D = ns.HTLData
local E = {}
ns.HTL = E
-- hooks (NaxxBoss.lua): BOSSFN[type](e, dt, d) a boss's turn; ONSPAWN[type](ev) a clock event's own spawning;
-- MOBTICK(e, dt, d) the necropolis's dead (their tricks); ONKILL(e, o) after a death; STAGEFN[stage].init(run) /
-- .tick(dt) a stage's floor and hazards. E.I (end of file) hands them the run's tools.
E.BOSSFN, E.ONSPAWN, E.STAGEFN = {}, {}, {}

local floor, min, max, abs, sqrt, sin, cos, atan2, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos, math.atan2 or math.atan, math.pi
local TAU = pi * 2
local MOBS, C, SPELLS, PASSIVES, LEGEND = D.MOBS, D.C, D.SPELLS, D.PASSIVES, D.LEGEND
local random = math.random

local R      -- the run being stepped (set by every entry point; the mockup's global R)
local VW, VH = D.VW, D.VH

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local MOD = 2147483647
local function rnd() local g = R.rng g.s = (g.s * 16807) % MOD return g.s / MOD end
local function rr(a, b) return a + (b - a) * rnd() end
local function fr() return random() end
local function vr(a, b) return a + (b - a) * random() end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
local function hyp(x, y) return sqrt(x * x + y * y) end
local function lerp(a, b, k) return a + (b - a) * k end
local function easeOut(k) return 1 - (1 - k) * (1 - k) end
local function dirOf(vx, vy) return (floor(atan2(vy, vx) / (pi / 4) + 0.5) % 8 + 8) % 8 end
local function hash2(x, y, s)
    local h = (x * 374761393 + y * 668265263 + s * 2147483647) % 4294967296
    h = (h * 1274126177 + 12345) % 4294967296
    return h / 4294967296
end
local function pickW(list)
    local tot = 0
    for i = 1, #list do tot = tot + list[i][2] end
    local x = rnd() * tot
    for i = 1, #list do x = x - list[i][2] if x <= 0 then return list[i][1] end end
    return list[1][1]
end
local function remove(t, i) local n = #t t[i] = t[n] t[n] = nil end    -- (order free arrays)
E.dirOf, E.hyp, E.clamp, E.easeOut = dirOf, hyp, clamp, easeOut

local function sound(name, gap, vol) if R.onSound and not R.preview and not R.attract and not R.ff then R.onSound(name, gap or 0.05, vol or 1) end end

---------------------------------------------------------------------------
-- runs
---------------------------------------------------------------------------
local function stats()
    local P, Cl, T = R.passives, D.CLASSES[R.cls], R.tal
    local s = R.st or {}
    s.might = (1 + 0.1 * (P.might or 0)) * (1 + 0.03 * (T.might or 0))
    s.cdr = 1 / (1 + 0.08 * (P.crusader or 0) + 0.03 * (T.swift or 0))
    s.xp = (1 + 0.1 * (P.intellect or 0)) * (1 + 0.05 * (T.wisdom or 0))
    s.area = (1 + 0.04 * (P.intellect or 0)) * (1 + 0.04 * (T.area or 0))
    s.maxHp = Cl.hp + 25 * (P.fortitude or 0) + 10 * (T.tough or 0)
    s.speed = Cl.speed * (1 + 0.08 * (P.cheetah or 0)) * (1 + 0.03 * (T.freedom or 0))
    s.magnet = 64 * (1 + 0.3 * (P.lootarang or 0)) * (1 + 0.1 * (T.magnet or 0))
    s.regen = 0.3 * (P.motw or 0) + 0.2 * (T.loh or 0)
    s.armor = 0.03 * (P.motw or 0) + 0.02 * (T.devotion or 0) + (Cl.armor or 0)
    s.crit = 0.08 + 0.03 * (T.crit or 0)
    if (R.t3n or 0) >= 3 then s.might = s.might * 1.05 end          -- Tier 3: +5% damage at three pieces, +15 health at six
    if (R.t3n or 0) >= 6 then s.maxHp = s.maxHp + 15 end
    local Rl = R.relics or {}
    if Rl.wraith then s.crit = s.crit + 0.12 end
    if Rl.collar then s.magnet = s.magnet * 1.4 end
    if Rl.bearer then s.armor = s.armor + 0.15 end
    s.critMul = Rl.reflection and 2.4 or 2
    if R.rules.hpMul then s.maxHp = floor(s.maxHp * R.rules.hpMul) end
    if R.rules.dmgMul then s.might = s.might * R.rules.dmgMul end
    return s
end

local function addSpell(id)
    local s = R.spells[id]
    if not s then R.spells[id] = { r = 1, cd = 0.3, acc = 0, a = 0, cdMax = 1 } R.order[#R.order + 1] = id
    else s.r = min(SPELLS[id].max, s.r + 1) end
end
local function addRelic(id)
    if not id or R.relics[id] or not D.RELICS[id] then return end
    R.relics[id] = true
    R.rorder[#R.rorder + 1] = id
    local before = R.p.maxHp
    R.st = stats()
    R.p.maxHp = R.st.maxHp
    R.p.hp = R.p.hp + max(0, R.p.maxHp - before)
end
local function addPassive(id)
    if not R.passives[id] then R.porder[#R.porder + 1] = id end
    R.passives[id] = min(5, (R.passives[id] or 0) + 1)
    local before = R.p.maxHp
    R.st = stats()
    R.p.maxHp = R.st.maxHp
    R.p.hp = R.p.hp + max(0, R.p.maxHp - before)
end

-- opts: { cls = "PALADIN"|"MAGE", seed, god, bot, attract, preview, lab, noStart, stage, frostRes, t3n, ktSlain }
function E.New(opts)
    opts = opts or {}
    local cls = D.CLASSES[opts.cls or ""] and opts.cls or "PALADIN"
    local Cl = D.CLASSES[cls]
    local seed = floor(tonumber(opts.seed) or 1) % MOD
    if seed <= 0 then seed = seed + MOD - 1 end
    local run = {
        cls = cls, t = 0, speed = 1, god = opts.god and true or false, bot = opts.bot and true or false, attract = opts.attract and true or false,
        preview = opts.preview and true or false, lab = opts.lab and true or false, rng = { s = seed }, seed = seed,
        p = { x = 0, y = 0, vx = 0, vy = 1, dir = 2, anim = 0, hp = Cl.hp, maxHp = Cl.hp, inv = 0, moving = false, dead = false, deadT = 0, hurtT = 0, chill = 0 },
        en = {}, corpses = {}, gems = {}, pick = {}, proj = {}, eproj = {}, areas = {}, haz = {}, fx = {}, texts = {}, decals = {}, tele = {}, parts = {}, arcs = {},
        spells = {}, passives = {}, legend = {}, order = {}, porder = {}, tal = opts.talents or {}, rules = opts.rules or {}, perks = opts.perks or {},
        slain = {}, stones = 0, challenge = opts.challenge,
        level = 1, xp = 0, xpNext = 8, kills = 0, gold = 0, runes = 0,
        evI = 1, warn = nil, trauma = 0, kick = { x = 0, y = 0 }, hitstop = 0, hsCool = 0, flash = 0, flashC = { 0.63, 0, 0 }, pending = 0,
        boss = nil, chunks = {}, breakT = 4, dark = 0, over = nil, rerolls = 2, banish = 1, banished = {}, bossKills = 0, ts = 1, tsGoal = 1,
        xpPulse = 0, slotFlash = {}, lvlT = -1, VW = VW, VH = VH, free = {}, gemChain = 0, gemChainT = -1,
        stage = "epl", nx = {}, relics = {}, rorder = {}, tokens = {}, frozen = 0, frostRes = opts.frostRes or 0, t3n = opts.t3n or 0,
        ktSlain = opts.ktSlain and true or false, allies = {}, cold = 0, pSlow = 1, pSlowN = 1,
    }
    local ST = D.STAGES and D.STAGES[opts.stage or "epl"] or nil
    if ST then run.stage = ST.key end
    run.ST = ST or { key = "epl", reaper = true, props = true, len = 900, waves = D.WAVES, events = D.EVENTS, target = D.Target }
    local keep = R
    R = run
    if not opts.noStart then addSpell(Cl.start) if run.tal.purpose then addSpell(Cl.start) end end
    run.rerolls = run.rerolls + (run.tal.reroll or 0)
    run.banish = run.banish + (run.tal.banish or 0)
    if run.tal.headstart then run.level, run.pending, run.wantLevelUp = 2, 1, true end
    run.rerolls = run.rerolls + (run.perks.reroll or 0)
    if run.perks.seal then run.pending, run.wantLevelUp, run.blessOnly = run.pending + 1, true, 1 end     -- (Seal of the Dawn: a blessing to start)
    if run.rules.noRerolls then run.rerolls, run.banish = 0, 0 end
    run.st = stats()
    run.p.maxHp = run.st.maxHp
    run.p.hp = run.p.maxHp
    local SF = E.STAGEFN[run.stage]
    if SF and SF.init and not run.preview then SF.init(run) end
    R = keep
    return run
end

function E.Use(run) R = run VW, VH = run.VW or D.VW, run.VH or D.VH end
function E.AddSpell(run, id) E.Use(run) addSpell(id) end
function E.AddPassive(run, id) E.Use(run) addPassive(id) end
function E.AddRelic(run, id) E.Use(run) addRelic(id) end
function E.SetView(run, w, h) run.VW, run.VH = w, h end

---------------------------------------------------------------------------
-- particles
---------------------------------------------------------------------------
E.PMAX = 900       -- (the mockup's 2600 is a browser number; the client pays per texture)
local function emit(o)
    if R.ff and not o.must then return nil end
    local ps = R.parts
    if #ps >= E.PMAX then if not o.must then return nil end remove(ps, 1) end
    local p = R.free[#R.free]
    if p then R.free[#R.free] = nil wipe(p) else p = {} end
    p.t, p.x, p.y, p.z, p.vx, p.vy, p.vz, p.g, p.drag, p.life, p.s0, p.s1, p.a0, p.a1, p.fi, p.rot, p.vr, p.add, p.sx, p.sy =
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 10, 10, 1, 0, 0, 0, 0, true, 1, 1
    for k, v in pairs(o) do p[k] = v end
    if p.rot == "rnd" then p.rot = random() * TAU end
    ps[#ps + 1] = p
    return p
end
E.emit = emit

-- a particle table for o: callers build o fresh only where the mockup did; the hot paths below reuse O
local O = {}
local function o0() wipe(O) return O end

local function addDecal(x, y, r, col, kind)
    local d = R.decals
    if #d > 220 then remove(d, 1) end
    d[#d + 1] = { x = x, y = y, r = r, c = col, a = random() * TAU, cell = floor(random() * 4), t = 0, scorch = kind == "scorch", gold = kind == "gold" }
end

local function updParts(dt)
    local ps = R.parts
    local i = 1
    while i <= #ps do
        local p = ps[i]
        p.t = p.t + dt
        if p.drag > 0 then local k = max(0, 1 - p.drag * dt) p.vx, p.vy, p.vz = p.vx * k, p.vy * k, p.vz * k end
        p.x, p.y = p.x + p.vx * dt, p.y + p.vy * dt
        if p.g ~= 0 or p.vz ~= 0 then
            p.vz = p.vz - p.g * dt
            p.z = p.z + p.vz * dt
            if p.z < 0 and p.bounce then
                if p.decal and not p.landed then p.landed = true addDecal(p.x, p.y, p.decal[1], p.decal[2], nil) end
                p.z = 0 p.vz = -p.vz * p.bounce p.vx, p.vy = p.vx * 0.6, p.vy * 0.6
                if abs(p.vz) < 20 then p.vz, p.g = 0, 0 end
            end
        end
        p.rot = p.rot + p.vr * dt
        if p.follow then p.x, p.y = p.follow.x + (p.fx or 0), p.follow.y + (p.fy or 0) end
        if p.t >= p.life then
            if p.ends == "icehit" then
                local x, y = p.x, p.y
                remove(ps, i)
                R.free[#R.free + 1] = p
                local q = o0() q.img, q.tint, q.x, q.y, q.life, q.s0, q.s1, q.a0, q.a1, q.rot, q.flat = "blue_star", C.FROST, x, y, 0.22, 8, 22, 0.9, 0, "rnd", true
                emit(q)
                if random() < 0.4 then q = o0() q.img, q.tint, q.x, q.y, q.z, q.vx, q.vy, q.vz, q.drag, q.life, q.s0, q.s1, q.a0, q.a1, q.rot = "mist", C.ICE, x, y, 2, vr(-12, 12), vr(-6, 6), 10, 1, 0.6, 10, 26, 0.3, 0, "rnd" emit(q) end
            else
                remove(ps, i)
                R.free[#R.free + 1] = p
            end
        else
            i = i + 1
        end
    end
end

local function sparks(x, y, n, tint, o)
    o = o or O
    local spr = o.spread or 0.8
    for _ = 1, n do
        local a = o.dir and (o.dir + vr(-spr, spr)) or random() * TAU
        local sp = vr(o.v0 or 80, o.v1 or 260)
        emit({ img = o.img or "sparkle", tint = tint, x = x, y = y, z = o.z or 14, vx = cos(a) * sp, vy = sin(a) * sp * 0.75, vz = vr(o.up0 or 30, o.up1 or 160),
            g = o.g or 420, drag = 2.2, life = vr(o.l0 or 0.3, o.l1 or 0.65), s0 = o.s or 10, s1 = (o.s or 10) * 0.3, stretch = o.stretch or 0.9, bounce = 0.3, light = o.light })
    end
end
local function puff(x, y, n, tint, o)
    o = o or O
    for _ = 1, n do
        emit({ img = "smoke_sheet", cell = floor(random() * 40), tint = tint, add = false, x = x + vr(-8, 8), y = y + vr(-5, 5), z = o.z or 8,
            vx = vr(-30, 30) * (o.spread or 1), vy = vr(-20, 20) * (o.spread or 1), vz = vr(10, 50), drag = 1.6, life = vr(0.6, 1.2) * (o.life or 1),
            s0 = o.s0 or 14, s1 = o.s1 or 40, a0 = o.a or 0.55, a1 = 0, rot = "rnd", vr = vr(-1, 1) })
    end
end
local function flash(img, x, y, size, tint, life, o)
    o = o or O
    return emit({ img = img, tint = tint, x = x, y = y, z = o.z or 0, life = life or 0.25, s0 = size * (o.from or 0.6), s1 = size, a0 = o.a or 1, a1 = 0,
        rot = o.rot or "rnd", vr = o.vr or 0, flat = o.flat, light = o.light, sx = o.sx or 1, sy = o.sy or 1, under = o.under, fi = o.fi or 0, follow = o.follow })
end
local function ring(img, x, y, r0, r1, life, tint, a, o)
    return emit({ img = img, tint = tint, x = x, y = y, life = life, s0 = r0 * 2, s1 = r1 * 2, a0 = a or 0.9, a1 = 0, flat = true,
        rot = o and o.rot or "rnd", vr = o and o.vr or 0, ease = o and o.ease, light = o and o.light })
end

local function shake(t) if not R.ff then R.trauma = min(1, R.trauma + t) end end
-- (a hit-stop punctuates: after one, the next waits 0.2 s - a crowd of hits must not stop the clock)
local function stop(s) if not R.preview and not R.ff and R.hsCool <= 0 then R.hitstop = max(R.hitstop, s) R.hsCool = s + 0.2 end end
local function kick(dx, dy, s) local l = hyp(dx, dy) if l == 0 then l = 1 end R.kick.x = R.kick.x + dx / l * s R.kick.y = R.kick.y + dy / l * s end

---------------------------------------------------------------------------
-- the land: props per chunk (seeded by the chunk, not the run: the land is always the same)
---------------------------------------------------------------------------
local PROPW = { { "tree2_0", 3 }, { "tree3_0", 3 }, { "tree4_0", 2 }, { "shroom1_0", 2 }, { "shroom2_0", 2 }, { "shroom3_0", 3 }, { "bones_0", 3 }, { "bones_1", 3 },
    { "spikes_0", 4 }, { "stump_0", 3 }, { "bush_0", 4 }, { "log_0", 2 }, { "mound_0", 2 }, { "wagon_0", 1 }, { "outpost_0", 1 } }
local PROPTOT = 0
for _, p in ipairs(PROPW) do PROPTOT = PROPTOT + p[2] end
E.CH = 560
local CH = E.CH
function E.Chunk(run, cx, cy)
    local k = cx * 100003 + cy
    local c = run.chunks[k]
    if c then return c end
    c = { dec = {}, zones = {} }
    local ST = run.ST
    local n = (run.preview or (ST and not ST.props)) and 0 or 2 + floor(hash2(cx, cy, 1) * 3)
    local hz = ST and ST.hazard
    if (hz == "webs" or hz == "slime") and not run.preview then        -- (webs / slime pools lie where the chunk says)
        for i = 0, 1 do
            local x, y = cx * CH + 60 + hash2(cx, cy, 110 + i) * (CH - 120), cy * CH + 60 + hash2(cx, cy, 120 + i) * (CH - 120)
            if hyp(x, y) >= 220 and hash2(cx, cy, 130 + i) < 0.75 then c.zones[#c.zones + 1] = { kind = hz == "webs" and "web" or "slime", x = x, y = y, r = 60 + hash2(cx, cy, 140 + i) * 50 } end
        end
    end
    for i = 0, n - 1 do
        local x, y = cx * CH + 40 + hash2(cx, cy, 10 + i) * (CH - 80), cy * CH + 40 + hash2(cx, cy, 30 + i) * (CH - 80)
        if hyp(x, y) >= 180 then
            local w, name = hash2(cx, cy, 50 + i) * PROPTOT, PROPW[1][1]
            for _, pw in ipairs(PROPW) do w = w - pw[2] if w <= 0 then name = pw[1] break end end
            local ok = true
            for _, o in ipairs(c) do if hyp(o.x - x, o.y - y) < 150 then ok = false break end end
            if ok then c[#c + 1] = { name = name, x = x, y = y } end
        end
    end
    for i = 0, 2 do
        c.dec[#c.dec + 1] = { x = cx * CH + hash2(cx, cy, 70 + i) * CH, y = cy * CH + hash2(cx, cy, 80 + i) * CH, r = 30 + hash2(cx, cy, 90 + i) * 50, a = hash2(cx, cy, 99 + i) * TAU }
    end
    run.chunks[k] = c
    return c
end

---------------------------------------------------------------------------
-- spawning + the clock's events
---------------------------------------------------------------------------
local function spawn(mtype, x, y, extra)
    local M = MOBS[mtype]
    local k = R.preview and 5 or ((M.boss or M.elite or M.reaper) and 1 or 1 + R.t / 300 * 0.55)
    local e = { type = mtype, M = M, x = x, y = y, vx = 0, vy = 0, dir = 2, anim = rnd() * 8, hp = M.hp * k, maxHp = M.hp * k, flash = 0, slow = 0, frz = 0, frzMax = 0,
        stun = 0, sq = 0, hitT = 0, cd1 = 3, cd2 = 5, cd3 = 8, cast = nil, atkT = 0, fixed = nil, wob = rnd() * TAU, kb = 0, kx = 0, ky = 0, spawnT = 0 }
    if extra then for kk, v in pairs(extra) do e[kk] = v end end
    R.en[#R.en + 1] = e
    if M.boss then R.boss = e end
    return e
end
E.Spawn = function(run, ...) E.Use(run) return spawn(...) end
local function edgePoint(pad)
    local a, rx, ry = rnd() * TAU, VW / 2 + pad, VH / 2 + pad
    return R.p.x + cos(a) * rx * 1.05, R.p.y + sin(a) * ry * 1.25
end
local function waveAt(t)
    local WV = R.ST and R.ST.waves or D.WAVES
    for _, w in ipairs(WV) do if t >= w[1] and t < w[2] then return w.list end end
    return WV[#WV].list
end
local LAB = { { "ghoul", 6 }, { "skeleton", 3 }, { "ghoul2", 1 }, { "rat", 2 } }
local PREVIEW_MOBS = { { "ghoul", 7 }, { "skeleton", 3 } }

local function warn(msg, col) R.warn = { msg = msg, col = col, t = 4.2, t0 = 4.2 } end
E.Warn = function(run, msg, col) run.warn = { msg = msg, col = col, t = 4.2, t0 = 4.2 } end
local RED, YELLOW, ORANGE, ICEW = { 1, 0.25, 0.25 }, { 1, 0.82, 0.25 }, { 1, 0.6, 0.16 }, { 0.62, 0.88, 1 }

local function spawner(dt)
    if R.preview then
        while #R.en < (R.pvN or 6) do
            local a, d = -pi / 2 + rr(-1.35, 1.35), rr(R.pvR0 or 70, R.pvR1 or 100)
            local x, y = R.p.x + cos(a) * d, R.p.y + sin(a) * d * 0.6
            spawn(pickW(PREVIEW_MOBS), x, y, { dir = dirOf(R.p.x - x, R.p.y - y) })
        end
        return
    end
    if R.lab then
        while #R.en < (R.labN or 70) do local x, y = edgePoint(30) spawn(pickW(LAB), x, y) end
        return
    end
    local ST = R.ST
    if ST.reaper and R.t >= ST.len then return end
    if R.calm then return end                                    -- (Patchwerk wants the room to himself)
    local want = ST.target(R.t) * (R.dark > 0 and 1.25 or 1) * (R.finaleOn and 0.6 or 1) * (R.spawnK or 1)
    local n, alive = 0, #R.en
    while alive + n < want and n < 6 do local x, y = edgePoint(60) spawn(pickW(waveAt(R.t)), x, y) n = n + 1 end
    R.breakT = R.breakT - dt
    if R.breakT <= 0 then
        R.breakT = 11 + rnd() * 6
        local a, d = rnd() * TAU, 300 + rnd() * 160
        R.pick[#R.pick + 1] = { kind = "cauldron", x = R.p.x + cos(a) * d, y = R.p.y + sin(a) * d * 0.7, hp = 1, t = 0 }
    end
end

local kill
local function runEvents()
    if R.preview or R.lab then return end
    local EV, k = R.ST.events or D.EVENTS, R.rules.rush or 1
    while R.evI <= #EV and R.t >= EV[R.evI].t * k do
        local ev = EV[R.evI]
        R.evI = R.evI + 1
        warn(ev.msg, (ev.kind == "boss" or ev.kind == "reaper" or ev.kind == "finale") and RED or YELLOW)
        if ev.kind == "ring" then
            sound("raidwarn")
            for i = 0, 63 do local a = i / 64 * TAU spawn(ev.mob or (i % 3 ~= 0 and "ghoul" or "skeleton"), R.p.x + cos(a) * 520, R.p.y + sin(a) * 380) end
        elseif ev.kind == "brood" then
            sound("raidwarn")
            for i = 0, 47 do local a = i / 48 * TAU spawn("n_spider", R.p.x + cos(a) * 480, R.p.y + sin(a) * 350) end
        elseif ev.kind == "boss" or ev.kind == "elite" or ev.kind == "finale" then
            sound(ev.kind == "elite" and "raidwarn" or "bosswarn")
            if ev.mob == "lich" then sound("lich") end
            if ev.kind == "finale" then R.finaleOn, R.finaleT = true, R.t end
            local made
            if E.ONSPAWN[ev.mob] then made = E.ONSPAWN[ev.mob](ev)
            else made = {} for _ = 1, ev.n or 1 do local x, y = edgePoint(40) made[#made + 1] = spawn(ev.mob, x, y) end end
            for _, e in ipairs(made or {}) do
                e.arriveT = R.t
                if e.M.finale and R.ST.berserk then e.berserkAt = R.t + R.ST.berserk end
            end
        elseif ev.kind == "storm" then
            R.storm = true sound("raidwarn")
        elseif ev.kind == "swarm" then
            sound("raidwarn")
            local dir = rnd() < 0.5 and 1 or -1
            for _ = 1, 46 do spawn(ev.mob or "bat", R.p.x - dir * (VW / 2 + 60 + rnd() * 200), R.p.y + rr(-VH / 2, VH / 2), { fixed = { dir * 170, rr(-12, 12) }, life = 9 }) end
        elseif ev.kind == "dark" then
            R.dark = 1 sound("fear")
        elseif ev.kind == "reaper" then
            for _, e in ipairs(R.en) do kill(e, true) end
            R.boss = nil
            spawn("reaper", R.p.x, R.p.y - VH / 2 - 10)
            shake(0.6) sound("bell")
        end
    end
end

---------------------------------------------------------------------------
-- damage + death
---------------------------------------------------------------------------
local deathFx, legendFx
local function hurt(e, dmg, o)
    if e.dead or e.M.reaper then return end
    o = o or O
    if e.immune then return end
    local Rl = R.relics
    local big = e.M.elite or e.M.boss
    local crit = rnd() < R.st.crit + ((R.creepT or 0) > 0 and 0.5 or 0)
    dmg = dmg * R.st.might * (crit and R.st.critMul or 1)
    if R.tal.slayer and big then dmg = dmg * (1 + 0.06 * R.tal.slayer) end
    if R.wrathOn then dmg = dmg * 1.4 end
    if Rl.remorse and big then dmg = dmg * 1.25 end
    if R.essenceOn then dmg = dmg * 1.3 end
    if Rl.righteye and o.school == "frost" then dmg = dmg * 1.2 end
    if Rl.hungering and e.frz > 0 then dmg = dmg * 2 end
    dmg = dmg * (e.dmgTakenMul or 1) * (R.dmgMul or 1)
    if Rl.menethil and not e.M.boss and e.hp - dmg < e.maxHp * 0.45 then if e.M.elite then dmg = dmg * 2 else dmg = max(dmg, e.hp) end end
    e.hp = e.hp - dmg
    if not o.dot then
        if Rl.fang then e.poison, e.poisonT = min(3, (e.poison or 0) + 1), 4 end
        if Rl.spire then R.spireN = (R.spireN or 0) + 1 if R.spireN >= 5 then R.spireN = 0 R.pendingChain = e end end
        if Rl.hungering and not e.M.boss and rnd() < 0.15 then e.frz = max(e.frz, 2) e.frzMax = e.frz end
    end
    if e.onHurt then e.onHurt(e, dmg) end
    e.flash, e.sq = 0.11, 0.22
    local tx = R.texts
    if #tx < (R.preview and 6 or 80) and (not R.preview or crit or rnd() < 0.35) then
        local t = R.free[#R.free] or {}
        R.free[#R.free] = nil
        t.x, t.y, t.vx, t.vy, t.v, t.t, t.life, t.crit, t.col = e.x + vr(-6, 6), e.y - 30 - e.M.r, vr(-26, 26), -vr(70, 110), floor(dmg + 0.5), 0, crit and 0.95 or 0.7, crit, D.SCHOOL_COL[o.school or "phys"]
        tx[#tx + 1] = t
    end
    local fx0, fy0 = o.fx or R.p.x, o.fy or R.p.y
    if o.kb and not e.M.boss then local d = hyp(e.x - fx0, e.y - fy0) if d == 0 then d = 1 end e.kb, e.kx, e.ky = o.kb, (e.x - fx0) / d, (e.y - fy0) / d end
    if o.stun then e.stun = max(e.stun, o.stun) end
    if o.slow then e.slow = max(e.slow, o.slow * (Rl.righteye and 1.3 or 1)) end
    if o.frz and not (e.M.boss and e.M.naxx) then e.frz = max(e.frz, o.frz * (Rl.righteye and 1.3 or 1)) e.frzMax = e.frz end
    if e.hp <= 0 then kill(e, false, o) end
end

kill = function(e, silent, o)
    if e.dead then return end
    e.dead = true
    local M = e.M
    local cs = R.corpses
    cs[#cs + 1] = { type = e.type, x = e.x, y = e.y, dir = e.dir, t = 0, purge = o and o.purge, frozen = e.frz > 0 }
    if #cs > 140 then remove(cs, 1) end
    deathFx(e, M, o)
    if not silent then
        R.kills = R.kills + 1
        if not (o and o.purge) then addDecal(e.x, e.y, M.r * (1.3 + rnd() * 0.6), D.ICHOR[M.ichor], nil) end
        if M.xp > 0 then R.gems[#R.gems + 1] = { x = e.x, y = e.y, v = M.xp, t = rnd() * 6, m = false, pop = 0.35, vx = rr(-40, 40), vy = rr(-30, 30) } end
        if rnd() < 0.01 * (1 + 0.25 * (R.tal.lucky or 0)) then R.pick[#R.pick + 1] = { kind = "gold", x = e.x + 8, y = e.y, v = 5 + floor(rnd() * 10), t = 0 } end
        if e.type == "rat" then sound("rat", 0.25) end
        local Rl = R.relics
        if Rl.ashbringer and not M.boss and not M.elite and #R.allies < 8 and rnd() < 0.1 then
            R.allies[#R.allies + 1] = { type = e.type, x = e.x, y = e.y, dir = e.dir, t = 0, life = 6, anim = 0, hitT = 0 }
        end
        if Rl.kingsfall then
            if R.t - (R.kfT0 or -99) > 10 then R.kfT0, R.kfN = R.t, 0 end
            R.kfN = (R.kfN or 0) + 1
            if R.kfN >= 50 then R.kfN, R.kfOn = 0, 8 warn("Kingsfall!", C.GOLD) end
        end
    end
    if (M.elite or M.boss) and not silent then
        R.slain[e.type] = true
        R.stones = R.stones + (M.boss and 3 or 1)          -- (Scourgestones: handed to the Argent Dawn when the run ends)
        if R.ST.key ~= "epl" then                          -- (the necropolis: Frozen Runes, and a master's Desecrated token)
            local n = e.type == "n_sapphiron" and D.RUNES_SAPPHIRON or M.boss and D.RUNES_BOSS or D.RUNES_ELITE
            R.frozen = R.frozen + n * (R.perks.runes2 and 2 or 1)
            local slot = D.T3_FROM and D.T3_FROM[e.type]
            if slot then R.tokens[#R.tokens + 1] = { boss = e.type, slot = slot } end
        end
        if not M.finale then R.pick[#R.pick + 1] = { kind = "chest", x = e.x, y = e.y, t = 0, boss = M.boss, src = e.type } end
        if R.relics.brimstone and M.elite then R.areas[#R.areas + 1] = { kind = "burn", x = e.x, y = e.y, r = 70, t = 0, dur = 6, acc = 0, dmg = 8, emitAcc = 0 } end
        shake(0.5) stop(0.08)
        ring("ring_soft", e.x, e.y, 20, 220, 0.7, C.GOLD, 0.9, { light = 300 })
        if M.boss then
            R.boss = nil
            for _, o2 in ipairs(R.en) do if o2 ~= e and not o2.dead and o2.M.boss then R.boss = o2 break end end
            R.bossKills = R.bossKills + 1 warn(M.name .. " has been slain!", YELLOW) sound("uber")
        end
    end
    if E.ONKILL and not silent then E.ONKILL(e, o) end
end

deathFx = function(e, M, o)
    local big = (M.elite or M.boss) and 3 or (M.r > 16 and 1.6 or 1)
    local x, y = e.x, e.y
    if o and o.purge then        -- Ashbringer: the body burns away in light
        for _ = 1, 10 do emit({ img = "sparkle", tint = C.GOLD, x = x + vr(-10, 10), y = y + vr(-4, 4), z = vr(0, 30), vx = vr(-15, 15), vy = vr(-8, 8), vz = vr(40, 110), drag = 1.2, life = vr(0.6, 1.1), s0 = vr(8, 14), s1 = 2, light = 40 }) end
        flash("holy_star", x, y - 20, 46, C.GOLD, 0.3, { a = 0.7 })
        emit({ img = "levelup_rays", tint = C.GOLD, x = x, y = y - 22, life = 0.6, s0 = 30, s1 = 36, sx = 0.8, sy = 1.6, a0 = 0.6, a1 = 0 })
        return
    end
    local g = D.GORE[M.ichor]
    if M.ichor == "bone" then
        for _ = 1, floor(6 * big) do emit({ img = "ice_chunks2", tint = g, add = false, x = x, y = y, z = 18, vx = vr(-90, 90), vy = vr(-60, 60), vz = vr(60, 200), g = 520, drag = 0.6,
            life = vr(0.7, 1.2), s0 = vr(7, 12), s1 = 6, a0 = 1, a1 = 0, ease = "late", rot = "rnd", vr = vr(-9, 9), bounce = 0.35 }) end
        puff(x, y, floor(3 * big), { 150 / 255, 140 / 255, 120 / 255 }, { a = 0.4 })
    elseif M.ichor == "spirit" then
        emit({ img = "ghost_purple", x = x, y = y - 20, vy = -40, life = 1.1, s0 = 30 * big, s1 = 46 * big, sx = 2, sy = 1, a0 = 0.8, a1 = 0, rot = -pi / 2, drag = 0.5 })
        ring("ring_soft", x, y, 6, 44 * big, 0.45, { 190 / 255, 150 / 255, 1 }, 0.7)
        sparks(x, y, 6, { 200 / 255, 170 / 255, 1 }, { g = 0, up0 = 0, up1 = 40 })
    else
        for _ = 1, floor(7 * big) do emit({ img = "blood", tint = g, add = false, x = x, y = y, z = 16, vx = vr(-110, 110), vy = vr(-80, 80), vz = vr(40, 190), g = 560, drag = 0.4,
            life = vr(0.4, 0.8), s0 = vr(5, 9) * min(1.6, big), s1 = 4, a0 = 1, a1 = 0.6, stretch = 0.5, bounce = 0, decal = random() < 0.35 and { vr(4, 8), D.ICHOR[M.ichor] } or nil }) end
        puff(x, y, floor(2 * big), M.ichor == "rot" and { 70 / 255, 80 / 255, 50 / 255 } or { 90 / 255, 30 / 255, 30 / 255 }, { a = 0.45, s0 = 12, s1 = 34 })
    end
    if M.ichor ~= "spirit" and (random() < 0.28 or big > 1) and not (o and o.noSoul) then   -- the soul leaves the body
        emit({ img = "ghost_blue", x = x, y = y - 18, vx = vr(-8, 8), vy = -vr(30, 50), life = vr(0.9, 1.3), s0 = 22, s1 = 36, sx = 2, sy = 1, a0 = 0.55, a1 = 0, fi = 0.15, rot = -pi / 2 + vr(-0.2, 0.2), light = 30 })
        if random() < 0.3 then sound("soulshatter", 0.2) end
    end
    if big > 2 then puff(x, y, 10, { 60 / 255, 70 / 255, 40 / 255 }, { a = 0.6, s0 = 30, s1 = 90, spread = 2.5 }) sparks(x, y, 20, C.GOLD, { v0 = 120, v1 = 360 }) end
end

local function hurtPlayer(dmg, src)
    local p = R.p
    local reaper = src and src.M and src.M.reaper
    if p.inv > 0 or p.dead or (R.god and not reaper) then if R.god and not reaper then p.hurtT = 0.1 end return end
    if R.relics.bearer and (R.blockCd or 0) <= 0 and not reaper then             -- The Plague Bearer: a hit blocked
        R.blockCd = 10
        R.texts[#R.texts + 1] = { x = p.x, y = p.y - 50, vx = 0, vy = -60, v = "Blocked", t = 0, life = 0.9, col = { 0.8, 0.9, 1 } }
        p.inv = 0.3
        return
    end
    if src and src.tag then R.nx[src.tag] = true end
    dmg = dmg * (1 - R.st.armor) * (R.dmgTakenMul or 1)
    if R.tal.ardent and p.hp < p.maxHp * 0.3 then dmg = dmg * (1 - 0.15 * R.tal.ardent) end
    p.hp = p.hp - dmg
    if not R.firstHit then R.firstHit = R.t end
    if R.t >= 600 and p.hp > 0 and p.hp < p.maxHp * 0.15 then R.thread = true end
    p.inv, p.hurtT, R.flash = 0.45 + 0.15 * (R.tal.unbreak or 0), 0.3, 0.25
    R.flashC = { 0.63, 0, 0 }
    shake(0.18)
    if p.hp <= 0 and R.tal.redemption and not R.redeemed then       -- Redemption: once a run, back up at half health
        R.redeemed = true
        p.hp, p.inv = p.maxHp * 0.5, 2.5
        warn("Redemption!", C.GOLD)
        sound("crusader")
        legendFx()
        return
    end
    if p.hp <= 0 then p.hp = 0 p.dead = true p.deadT = 0 R.killer = src and src.M and src.M.name or "the Scourge" end
end

---------------------------------------------------------------------------
-- spells
---------------------------------------------------------------------------
local function nearest(x, y, maxd, skip)
    local best, bd = nil, maxd * maxd
    for _, e in ipairs(R.en) do
        if not e.dead and not e.M.reaper and not (skip and skip[e]) then
            local d = (e.x - x) ^ 2 + (e.y - y) ^ 2
            if d < bd then bd, best = d, e end
        end
    end
    return best
end
local function onScreen(e) return abs(e.x - R.p.x) < VW / 2 + 20 and abs(e.y - R.p.y) < VH / 2 + 20 end
local VIS = {}
local function visible()
    wipe(VIS)
    for _, e in ipairs(R.en) do if not e.dead and not e.M.reaper and onScreen(e) then VIS[#VIS + 1] = e end end
    return VIS
end
local HX, HY = { 12, 9, 0, -9, -12, -9, 0, 9 }, { 0, 3, 5, 3, 0, -3, -4, -3 }
local function hand() return R.p.x + HX[R.p.dir + 1], R.p.y - 26 + HY[R.p.dir + 1] end
local PORTAL = { 16, 12, 0, -12, -16, -12, 0, 12 }
E.PORTAL = PORTAL

local function consecrationAmbient(s, dt, L)
    local p, r = R.p, s.rad
    s.emb = (s.emb or 0) + dt * r * (L and 0.5 or 0.28)
    while s.emb > 1 do
        s.emb = s.emb - 1
        local a, d = random() * TAU, sqrt(random()) * r
        local q = o0()
        q.img, q.tint, q.x, q.y, q.z, q.vx, q.vz, q.life, q.s0, q.s1, q.a0, q.a1, q.fi = "sparkle", L and C.HOLY or C.GOLD, p.x + cos(a) * d, p.y + sin(a) * d / 1.3, 2, vr(-6, 6), vr(30, L and 110 or 70), vr(0.6, 1.3), vr(5, L and 12 or 9), 1, 0.95, 0, 0.15
        emit(q)
        if random() < (L and 0.22 or 0.07) then
            q = o0()
            q.img, q.tint, q.x, q.y, q.life, q.s0, q.s1, q.sx, q.sy, q.a0, q.a1, q.fi = "levelup_rays", L and C.HOLY or C.GOLD, p.x + cos(a) * d, p.y + sin(a) * d / 1.3 - 14, vr(0.6, 1), L and 26 or 18, L and 34 or 24, 0.8, 1.7, 0.5, 0, 0.3
            emit(q)
        end
    end
end

local function exorcismHit(t)
    local x, y = t.e.dead and t.x or t.e.x, t.e.dead and t.y or t.e.y
    R.fx[#R.fx + 1] = { kind = "pillar", x = x, y = y, t = 0, dur = 0.7 }
    flash("holy_star", x, y - 10, 160, C.HOLY, 0.35, { light = 300 })
    flash("holy_flare", x, y - 30, 90, C.GOLD, 0.25)
    ring("ring_blue", x, y, 10, 100, 0.45, C.GOLD, 1)
    ring("ring_shards", x, y, 10, 80, 0.4, C.HOLY, 0.8)
    emit({ img = "levelup_rays", tint = C.GOLD, x = x, y = y - 30, life = 0.8, s0 = 60, s1 = 80, sx = 1.2, sy = 1.4, a0 = 0.9, a1 = 0 })
    for _ = 1, 18 do local a = random() * TAU emit({ img = "sparkle", tint = C.GOLD, x = x, y = y, z = vr(0, 40), vx = cos(a) * vr(40, 180), vy = sin(a) * vr(30, 120), vz = vr(60, 260), g = 300, drag = 1.5, life = vr(0.5, 1), s0 = vr(8, 13), s1 = 2, bounce = 0.2 }) end
    puff(x, y, 4, { 190 / 255, 170 / 255, 130 / 255 }, { a = 0.35, s0 = 20, s1 = 60, spread = 2 })
    addDecal(x, y, 34, { 60 / 255, 46 / 255, 16 / 255 }, "gold")
    if not t.e.dead then hurt(t.e, t.dmg, { stun = 0.35, school = "holy" }) end
    shake(0.28) stop(0.055) sound("exorcism", 0.08)
end

local areaPush
local function flamestrikeHit(t)
    R.fx[#R.fx + 1] = { kind = "flame", x = t.x, y = t.y, t = 0, dur = 0.9, r = t.r }
    flash("fire_core", t.x, t.y - 20, t.r * 2.4, nil, 0.4, { light = t.r * 3 })
    ring("ring_soft", t.x, t.y, 10, t.r * 1.3, 0.45, C.FIRE, 1)
    ring("fire_ring", t.x, t.y, t.r * 0.6, t.r * 1.2, 0.6, nil, 1)
    for _ = 1, 26 do local a = random() * TAU emit({ img = "sparkle", tint = C.EMBER, x = t.x, y = t.y, z = 10, vx = cos(a) * vr(60, 260), vy = sin(a) * vr(40, 180), vz = vr(120, 380), g = 380, drag = 0.8, life = vr(0.6, 1.3), s0 = vr(7, 12), s1 = 2, stretch = 0.6, bounce = 0.25, light = 30 }) end
    for _ = 1, 10 do puff(t.x + vr(-t.r, t.r) * 0.6, t.y + vr(-t.r, t.r) * 0.4, 1, { 40 / 255, 32 / 255, 28 / 255 }, { a = 0.65, s0 = 30, s1 = 90, life = 1.6, z = 30 }) end
    addDecal(t.x, t.y, t.r, { 24 / 255, 14 / 255, 10 / 255 }, "scorch")
    areaPush({ kind = "burn", x = t.x, y = t.y, r = t.r * 0.8, t = 0, dur = 2.2, acc = 0, dmg = 4, emitAcc = 0 })
    for _, e in ipairs(R.en) do if not e.dead and hyp(e.x - t.x, (e.y - t.y) * 1.3) < t.r then hurt(e, t.dmg, { school = "fire", kb = 60, fx = t.x, fy = t.y }) end end
    shake(0.38) stop(0.05) sound("flamestrike", 0.1)
end
areaPush = function(a) R.areas[#R.areas + 1] = a end

local function explode(x, y, r, dmg)
    flash("fire_core", x, y - 14, r * 2.2, nil, 0.35, { light = r * 3 })
    flash("flame", x, y - 20, r * 2, nil, 0.4)
    ring("ring_smoke", x, y, 10, r * 1.2, 0.45, C.FIRE, 0.9)
    puff(x, y, 7, { 50 / 255, 42 / 255, 36 / 255 }, { a = 0.6, s0 = 20, s1 = 70, spread = 2.2, life = 1.3 })
    for _ = 1, 9 do emit({ img = "ice_chunks2", tint = { 70 / 255, 56 / 255, 40 / 255 }, add = false, x = x, y = y, z = 10, vx = vr(-160, 160), vy = vr(-120, 120), vz = vr(100, 260), g = 600, life = 0.8, s0 = 7, s1 = 6, a0 = 1, a1 = 0, ease = "late", rot = "rnd", vr = vr(-10, 10), bounce = 0.3 }) end
    sparks(x, y, 14, C.EMBER, { v0 = 100, v1 = 340, light = 20 })
    addDecal(x, y, r * 0.7, { 20 / 255, 16 / 255, 14 / 255 }, "scorch")
    for _, e in ipairs(R.en) do if not e.dead and hyp(e.x - x, (e.y - y) * 1.3) < r then hurt(e, dmg, { kb = 70, fx = x, fy = y, school = "fire" }) end end
    shake(0.22) stop(0.03) sound(random() < 0.5 and "fireimpact" or "fireimpact2", 0.06)
end

-- the warrior: a swing's victims (in reach and inside the arc round angle a), Thunderfury's chain, Charge's landing
local function swingHits(x, y, a, rad, half)
    local out = {}
    for _, e in ipairs(R.en) do
        if not e.dead and not e.M.reaper then
            local dx, dy = e.x - x, (e.y - y) * 1.3
            local d = hyp(dx, dy)
            if d < rad + e.M.r and (d < 28 or abs((atan2(dy, dx) - a + pi) % TAU - pi) < half) then out[#out + 1] = e end
        end
    end
    return out
end
local function chain(from, n, dmg)
    local hit, cur = { [from] = true }, from
    for _ = 1, n do
        local nx = nearest(cur.x, cur.y, 170, hit)
        if not nx then break end
        hit[nx] = true
        R.arcs[#R.arcs + 1] = { x0 = cur.x, y0 = cur.y - 18, x1 = nx.x, y1 = nx.y - 18, t = 0, life = 0.3, storm = true }
        hurt(nx, dmg, { slow = 1.5, school = "nature" })
        flash("blue_star", nx.x, nx.y - 18, 46, C.STORM, 0.2, { light = 90 })
        cur = nx
    end
    sound("lightning", 0.18, 0.6)
end
local function chargeLand(d)
    local p = R.p
    local rad = 80 * R.st.area
    ring("ring_smoke", p.x, p.y, 10, rad * 1.4, 0.5, C.DUST, 0.9)
    ring("nova_ring", p.x, p.y, 10, rad, 0.3, { 1, 0.9, 0.7 }, 0.8)
    puff(p.x, p.y, 8, { 0.42, 0.36, 0.28 }, { a = 0.6, s0 = 20, s1 = 70, spread = 1.8, life = 1 })
    for _, e in ipairs(R.en) do
        if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < rad + e.M.r then
            hurt(e, 20 + 8 * d.r, { stun = 0.6 + 0.1 * d.r, kb = 60, fx = p.x, fy = p.y, school = "phys" })
            puff(e.x, e.y - 6, 1, C.BLOOD, { a = 0.7, s0 = 8, s1 = 24, life = 0.45, z = 14, spread = 1.4 })
        end
    end
    shake(0.35) stop(0.06) sound("axehit", 0.05) sound("strike", 0.05)
end

local function fire(id, s, r, L)
    local p, st = R.p, R.st
    local function cd(v) s.cd = v * st.cdr s.cdMax = s.cd end
    if id == "cleave" then
        local rad = (72 + 6 * r) * st.area * (L and 1.25 or 1)
        local t = nearest(p.x, p.y, rad + 30)
        if not t then s.cd = 0.12 return end
        local a = atan2((t.y - p.y) * 1.3, t.x - p.x)
        local hits = swingHits(p.x, p.y, a, rad, L and 1.3 or 1.0)
        R.fx[#R.fx + 1] = { kind = "slash", x = p.x, y = p.y - 16, a = atan2(t.y - p.y, t.x - p.x), r = rad, t = 0, dur = 0.24, legend = L }
        p.atkT, p.atkDir = 0.36, dirOf(t.x - p.x, t.y - p.y)
        for i, e in ipairs(hits) do
            hurt(e, (12 + 5 * r) * (L and 1.2 or 1), { kb = 35, fx = p.x, fy = p.y, school = L and "nature" or "phys" })
            if i <= 8 then puff(e.x, e.y - 6, 1, C.BLOOD, { a = 0.7, s0 = 8, s1 = 24, life = 0.45, z = 14, spread = 1.4 }) end
        end
        if L and hits[1] then chain(hits[1], 3 + floor(r / 2), 14 + 4 * r) end
        sound(random() < 0.5 and "swing" or "swing2", 0.08, 0.7)
        if #hits > 0 then sound("axehit", 0.09, 0.8) stop(0.025) shake(min(0.16, 0.03 * #hits)) end
        cd(1.4 - 0.07 * r)
    elseif id == "thunderclap" then
        local rad = (100 + 10 * r) * st.area
        local n = 0                                          -- (it waits for a crowd: three in reach, or anything big)
        for _, e in ipairs(R.en) do if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < rad + e.M.r then n = n + ((e.M.boss or e.M.elite) and 3 or 1) end end
        if n < 3 then s.cd = 0.2 return end
        emit({ img = "ring_smoke", tint = C.DUST, x = p.x, y = p.y, life = 0.65, s0 = 30, s1 = rad * 2.3, a0 = 0.9, a1 = 0, flat = true, rot = "rnd" })
        ring("nova_ring", p.x, p.y, 20, rad, 0.35, { 1, 0.92, 0.7 }, 1)
        ring("ring_shards", p.x, p.y, 20, rad * 1.05, 0.45, C.DUST, 0.85)
        flash("sun_ring", p.x, p.y - 10, 130, { 1, 0.92, 0.7 }, 0.25, { light = 220 })
        puff(p.x, p.y, 10, { 0.45, 0.4, 0.32 }, { a = 0.55, s0 = 30, s1 = 90, spread = rad / 40, life = 1.2 })
        addDecal(p.x, p.y, rad * 0.45, { 30 / 255, 24 / 255, 18 / 255 }, "scorch")
        for _, e in ipairs(R.en) do
            if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < rad + e.M.r then hurt(e, 8 + 3 * r, { slow = 2.5 + 0.3 * r, kb = 30, fx = p.x, fy = p.y, school = "phys" }) end
        end
        p.atkT, p.atkDir = 0.36, p.dir
        shake(0.3) stop(0.05) sound("thunderclap")
        cd(7 - 0.45 * r)
    elseif id == "charge" then
        if p.dash then s.cd = 0.2 return end
        local best, bn = nil, 0
        for _ = 1, 14 do
            local e = R.en[floor(rnd() * #R.en) + 1]
            if e and not e.dead and not e.M.reaper then
                local d = hyp(e.x - p.x, e.y - p.y)
                if d > 130 and d < 340 then
                    local n = 0
                    for _, o in ipairs(R.en) do if (o.x - e.x) ^ 2 + (o.y - e.y) ^ 2 < 4900 then n = n + 1 end end
                    if n > bn then bn, best = n, e end
                end
            end
        end
        if not best then s.cd = 0.4 return end
        p.dash = { x0 = p.x, y0 = p.y, x1 = best.x, y1 = best.y, t = 0, dur = 0.22, r = r }
        p.inv = max(p.inv, 0.22)
        sound("swing2", 0.1)
        cd(7 - 0.6 * r)
    elseif id == "execute" then
        -- the most wounded in reach first; under 35% health they are finished outright
        local list = {}
        for _, e in ipairs(R.en) do
            if not e.dead and not e.M.reaper and hyp(e.x - p.x, (e.y - p.y) * 1.3) < 120 + e.M.r then list[#list + 1] = e end
        end
        if #list == 0 then s.cd = 0.25 return end
        table.sort(list, function(a, b) return a.hp / a.maxHp < b.hp / b.maxHp end)
        for i = 1, min(1 + floor(r / 2), #list) do
            local e = list[i]
            local a = atan2(e.y - p.y, e.x - p.x)
            R.fx[#R.fx + 1] = { kind = "slash", x = e.x, y = e.y - 18, a = a + 0.9, r = 34 + e.M.r, t = 0, dur = 0.26, exec = true }
            R.fx[#R.fx + 1] = { kind = "slash", x = e.x, y = e.y - 18, a = a - 0.9 + pi, r = 34 + e.M.r, t = -0.05, dur = 0.26, exec = true }
            puff(e.x, e.y - 10, 4, C.BLOOD, { a = 0.7, s0 = 14, s1 = 40, spread = 1.4, life = 0.7 })
            local low = R.preview or e.hp < e.maxHp * 0.35
            if not low then hurt(e, 24 + 8 * r, { kb = 50, fx = p.x, fy = p.y, school = "phys" })
            elseif e.M.boss or e.M.elite then hurt(e, 60 + 25 * r, { kb = 60, fx = p.x, fy = p.y, school = "phys" })
            else e.hp = 0 kill(e, false, { kb = 90, fx = p.x, fy = p.y }) end
        end
        p.atkT, p.atkDir = 0.36, dirOf(list[1].x - p.x, list[1].y - p.y)
        stop(0.07) shake(0.2) sound("axehit", 0.06) sound("strike", 0.06)
        cd(2.6 - 0.2 * r)
    elseif id == "avenger" then
        local t = nearest(p.x, p.y, 380)
        if not t then s.cd = 0.3 return end
        local hx, hy = hand()
        local a = atan2(t.y - 16 - hy, t.x - hx)
        R.proj[#R.proj + 1] = { kind = "shield", x = hx, y = hy, vx = cos(a) * 600, vy = sin(a) * 600, tgt = t, bounces = 2 + r, dmg = 18 + 6 * r, life = 4, hit = {}, spin = 0, trail = {}, lastX = hx, lastY = hy }
        flash("holy_star2", hx, hy, 42, C.GOLD, 0.2, { light = 80 })
        sound("fist")
        cd(2.4 - 0.15 * r)
    elseif id == "exorcism" then
        local n = 1 + floor(r / 2)
        local vis = visible()
        table.sort(vis, function(a, b) return a.hp > b.hp end)
        if #vis == 0 then s.cd = 0.4 return end
        for i = 1, min(n, #vis) do
            local e = vis[i]
            local dl = 0.42 + (i - 1) * 0.07
            R.tele[#R.tele + 1] = { kind = "pillar", e = e, x = e.x, y = e.y, t = dl, t0 = dl, dmg = 44 + 16 * r }
            emit({ img = "rune_circle", tint = C.GOLD, x = e.x, y = e.y, follow = e, life = 0.5 + (i - 1) * 0.07, s0 = 20, s1 = 74, a0 = 0.95, a1 = 0.6, flat = true, rot = "rnd", vr = 3, fi = 0.2 })
            for _ = 1, 4 do emit({ img = "glow_dot", tint = C.HOLY, x = e.x + vr(-20, 20), y = e.y, z = vr(120, 200), vz = -vr(260, 360), life = 0.42, s0 = 10, s1 = 4, a0 = 0, a1 = 1, light = 40 }) end
        end
        cd(3.4 - 0.25 * r)
    elseif id == "holywrath" then
        local rad = (200 + 20 * r) * st.area
        R.fx[#R.fx + 1] = { kind = "wave", x = p.x, y = p.y, t = 0, dur = 0.55, r = rad, hit = {}, dmg = 12 + 6 * r }
        flash("sun_ring", p.x, p.y - 20, 150, C.HOLY, 0.35, { light = 260 })
        flash("holy_star", p.x, p.y - 26, 110, C.GOLD, 0.25)
        ring("ring_shards", p.x, p.y, 30, rad, 0.55, C.HOLY, 0.9)
        ring("ring_smoke", p.x, p.y, 20, rad * 1.02, 0.6, C.GOLD, 0.8)
        shake(0.22) stop(0.03) sound("wrath")
        cd(7 - 0.6 * r)
    elseif id == "frostbolt" then
        local t = nearest(p.x, p.y, 520)
        if not t then s.cd = 0.2 return end
        local hx, hy = hand()
        local n, base = 1 + floor((r - 1) / 2), atan2(t.y - 16 - hy, t.x - hx)
        for i = 0, n - 1 do
            local a = base + (i - (n - 1) / 2) * 0.16
            R.proj[#R.proj + 1] = { kind = "frost", x = hx, y = hy, vx = cos(a) * 430, vy = sin(a) * 430, pierce = 1 + floor(r / 3), dmg = 12 + 5 * r, life = 1.6, hit = {}, spin = random() * 6 }
        end
        flash("blue_star", hx, hy, 44, C.ICE, 0.18, { light = 70 })
        sparks(hx, hy, 4, C.FROST, { dir = base, spread = 0.5, z = 26, g = 0, v0 = 60, v1 = 160, s = 7 })
        sound("frostprecast", 0.25, 0.6)
        cd(1.05 - 0.07 * r)
    elseif id == "arcane" then
        local n = L and 2 or 3 + r
        local ox, oy = L and (p.x - PORTAL[p.dir + 1] * 2.6) or p.x, L and p.y - 60 or p.y - 46
        for i = 0, n - 1 do
            local a = -pi / 2 + (i - (n - 1) / 2) * 0.45 + vr(-0.2, 0.2)
            R.proj[#R.proj + 1] = { kind = "arcane", x = ox, y = oy, vx = cos(a) * 230, vy = sin(a) * 230, dmg = 6 + 2 * r, life = 2.4, delay = i * 0.07, ox = ox, oy = oy, trail = {} }
        end
        if not L then emit({ img = "arcane_circle", tint = C.ARC, x = p.x, y = p.y - 46, life = 0.65, s0 = 20, s1 = 52, sy = 0.45, a0 = 1, a1 = 0, rot = "rnd", vr = 4, fi = 0.15, light = 90 }) sound("arcaneprecast", 0.4, 0.7) end
        cd(L and 0.2 or 2.0)
    elseif id == "nova" then
        local rad, dur = (110 + 15 * r) * st.area, 1.5 + 0.3 * r
        R.fx[#R.fx + 1] = { kind = "nova", x = p.x, y = p.y, t = 0, dur = 0.6, r = rad }
        emit({ img = "ice_disc", tint = C.ICE, x = p.x, y = p.y, life = 0.7, s0 = 40, s1 = rad * 1.3, a0 = 1, a1 = 0, flat = true, rot = "rnd", vr = 1.5, light = 260 })
        ring("nova_ring", p.x, p.y, 20, rad, 0.4, C.FROST, 1)
        ring("ring_shards2", p.x, p.y, 20, rad * 1.05, 0.5, C.ICE, 0.9)
        emit({ img = "frost_disc", tint = { 150 / 255, 200 / 255, 240 / 255 }, x = p.x, y = p.y, life = dur + 1, s0 = rad * 2.1, s1 = rad * 2.15, a0 = 0.5, a1 = 0, ease = "late", flat = true, rot = "rnd", add = false, under = true })
        local nIce = floor(rad / 9 + 0.5)
        for i = 0, nIce - 1 do
            local a, d = i / nIce * TAU + vr(-0.1, 0.1), rad * vr(0.72, 1)
            R.fx[#R.fx + 1] = { kind = "icicle", x = p.x + cos(a) * d, y = p.y + sin(a) * d / 1.3, t = -i * 0.006, dur = dur, s = vr(18, 30), v = floor(random() * 3) }
        end
        for _, e in ipairs(R.en) do if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < rad then hurt(e, 8 + 4 * r, { frz = dur, school = "frost" }) end end
        shake(0.25) stop(0.04) sound("frostnova")
        cd(6 - 0.5 * r)
    elseif id == "blizzard" then
        for _ = 1, 1 + floor(r / 2) do
            local vis = visible()
            local tx, ty
            if #vis > 0 then local e = vis[floor(rnd() * #vis) + 1] tx, ty = e.x, e.y else tx, ty = p.x + rr(-200, 200), p.y + rr(-120, 120) end
            areaPush({ kind = "blizzard", x = tx, y = ty, r = (70 + 8 * r) * st.area, t = 0, dur = 3.2, acc = 0, dmg = 5 + 2 * r, emitAcc = 0 })
        end
        sound("coneofcold", 0.3)
        cd(5 - 0.4 * r)
    elseif id == "flamestrike" then
        local best, bn = nil, -1
        for _ = 1, 14 do
            local e = R.en[floor(rnd() * #R.en) + 1]
            if e and not e.dead and onScreen(e) then
                local n = 0
                for _, o in ipairs(R.en) do if (o.x - e.x) ^ 2 + (o.y - e.y) ^ 2 < 6400 then n = n + 1 end end
                if n > bn then bn, best = n, e end
            end
        end
        if not best then s.cd = 0.4 return end
        local rad = (80 + 10 * r) * st.area
        R.tele[#R.tele + 1] = { kind = "flamestrike", x = best.x, y = best.y, t = 0.65, t0 = 0.65, r = rad, dmg = 30 + 12 * r }
        emit({ img = "rune_circle", tint = { 1, 120 / 255, 40 / 255 }, x = best.x, y = best.y, life = 0.7, s0 = rad * 0.5, s1 = rad * 2.2, a0 = 0.2, a1 = 1, flat = true, rot = "rnd", vr = 5, light = 120 })
        emit({ img = "fire_ring", tint = C.FIRE, x = best.x, y = best.y, life = 0.68, s0 = rad * 2.5, s1 = rad * 2, a0 = 0.3, a1 = 1, flat = true, rot = "rnd", vr = -2 })
        cd(4.5 - 0.35 * r)
    elseif id == "grenade" then
        for i = 0, floor(r / 2) do
            local vis = visible()
            if #vis == 0 then break end
            local t = vis[floor(rnd() * #vis) + 1]
            R.proj[#R.proj + 1] = { kind = "grenade", x = p.x, y = p.y - 20, sx = p.x, sy = p.y - 20, tx = t.x, ty = t.y, t = -i * 0.12, dur = 0.6, dmg = 20 + 8 * r, r = (60 + 6 * r) * st.area, life = 2, spin = 0, gx = p.x, gy = p.y }
        end
        cd(3 - 0.25 * r)
    end
end

local function castSpells(dt)
    local p, st = R.p, R.st
    if (p.silenceT or 0) > 0 then return end                    -- (silenced: a Naxxramas Follower's charge)
    if R.disrupt then dt = dt * 0.7 end                          -- (Heigan's Spell Disruption)
    for _, id in ipairs(R.order) do
        local s = R.spells[id]
        local r, L = s.r, R.legend[id]
        s.cd = s.cd - dt * (((R.kfOn or 0) > 0) and 2 or 1)
        s.a = s.a + dt
        if id == "consecration" then
            local rad = (L and 128 + 10 * r or 64 + 8 * r) * st.area
            s.rad = s.rad and lerp(s.rad, rad, min(1, dt * 4)) or rad
            s.acc = s.acc + dt
            local tick = L and 0.32 or 0.45
            consecrationAmbient(s, dt, L)
            if s.acc >= tick then
                s.acc = s.acc - tick
                ring("ring_soft", p.x, p.y, s.rad * 0.55, s.rad * 1.02, 0.42, L and C.HOLY or C.GOLD, L and 0.55 or 0.4)
                local n = 0
                for _, e in ipairs(R.en) do
                    if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < s.rad + e.M.r then
                        if L and not e.M.boss and not e.M.reaper and e.hp < e.maxHp * 0.2 then
                            kill(e, false, { purge = true }) sound("holybolt", 0.09)
                        else
                            hurt(e, L and 14 + 5 * r or 5 + 3 * r, { school = "holy" })
                            n = n + 1
                            if n <= 14 then emit({ img = "holy_flare", tint = C.GOLD, x = e.x + vr(-6, 6), y = e.y, z = vr(4, 20), vz = 40, life = 0.3, s0 = 18, s1 = 6, a0 = 0.9, a1 = 0 }) end
                        end
                    end
                end
            end
        elseif id == "dragonling" then
            if not s.init then s.init = true sound("firenova") end
        elseif s.cd <= 0 then
            fire(id, s, r, L)
        end
    end
end

local function areaFx(a, dt)
    a.emitAcc = a.emitAcc + dt
    local f = min(1, (a.dur - a.t) / 0.4)
    if a.kind == "blizzard" then
        while a.emitAcc > 0.022 do
            a.emitAcc = a.emitAcc - 0.022
            if f >= 0.5 then
                local ang, d = random() * TAU, sqrt(random()) * a.r
                local gx, gy, fall = a.x + cos(ang) * d, a.y + sin(ang) * d / 1.3, vr(0.32, 0.42)
                local q = o0()
                q.img, q.tint, q.x, q.y, q.z, q.vx, q.vz, q.life, q.s0, q.s1, q.sy, q.a0, q.a1, q.rot, q.stretch, q.ends =
                    "ice_missile", C.FROST, gx - 27 * fall, gy, 420 * fall, 27, -420, fall, 22, 22, 0.45, 0.95, 0.95, pi, 0.15, "icehit"
                emit(q)
            end
        end
        if random() < 0.35 then emit({ img = "mist", tint = C.ICE, x = a.x + vr(-a.r, a.r) * 0.8, y = a.y + vr(-a.r, a.r) * 0.6, life = 1, s0 = 20, s1 = 50, a0 = 0.12 * f, a1 = 0, rot = "rnd", vr = 0.5, fi = 0.3 }) end
    else
        while a.emitAcc > 0.03 do
            a.emitAcc = a.emitAcc - 0.03
            local ang, d = random() * TAU, sqrt(random()) * a.r
            local q = o0()
            q.img, q.x, q.y, q.z, q.vz, q.life, q.s0, q.s1, q.a0, q.a1, q.rot, q.light = "flame", a.x + cos(ang) * d, a.y + sin(ang) * d / 1.3, 4, vr(20, 60), vr(0.3, 0.55), vr(14, 24) * f, 4, 0.85, 0, vr(-0.3, 0.3), 40
            emit(q)
        end
    end
end

local function updateProj(dt)
    local p = R.p
    local i = 1
    while i <= #R.proj do
        local b = R.proj[i]
        b.life = b.life - dt
        if b.delay and b.delay > 0 then
            b.delay = b.delay - dt
            if b.ox then b.x, b.y = b.ox, b.oy end
        else
            if b.trail then
                local tr = b.trail
                tr[#tr + 1] = b.x tr[#tr + 1] = b.y
                if #tr > 24 then table.remove(tr, 1) table.remove(tr, 1) end
            end
            if b.kind == "shield" then
                b.spin = b.spin + dt * 20
                if b.tgt and not b.tgt.dead then local a = atan2(b.tgt.y - 16 - b.y, b.tgt.x - b.x) b.vx, b.vy = cos(a) * 620, sin(a) * 620 end
                b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
                if random() < 0.7 then emit({ img = "sparkle", tint = C.GOLD, x = b.x, y = b.y, vx = vr(-30, 30), vy = vr(-30, 30), life = 0.35, s0 = 8, s1 = 1, a0 = 0.9, a1 = 0 }) end
                for _, e in ipairs(R.en) do
                    if not e.dead and not b.hit[e] and not e.M.reaper and hyp(e.x - b.x, e.y - 16 - b.y) < e.M.r + 12 then
                        b.hit[e] = true
                        hurt(e, b.dmg, { kb = 80, fx = b.x - b.vx * 0.05, fy = b.y - b.vy * 0.05, school = "holy" })
                        R.arcs[#R.arcs + 1] = { x0 = b.lastX, y0 = b.lastY, x1 = b.x, y1 = b.y, t = 0, life = 0.28 }
                        b.lastX, b.lastY = b.x, b.y
                        flash("holy_star", b.x, b.y, 64, C.HOLY, 0.22, { light = 120 })
                        ring("ring_soft", e.x, e.y, 6, 40, 0.3, C.GOLD, 0.8)
                        sparks(b.x, b.y, 9, C.GOLD, { dir = atan2(b.vy, b.vx), spread = 0.9, z = 16, v0 = 120, v1 = 320 })
                        stop(0.022) kick(b.vx, b.vy, 1.2) sound("strike", 0.06)
                        b.bounces = b.bounces - 1
                        b.tgt = b.bounces > 0 and nearest(b.x, b.y, 260, b.hit) or nil
                        if not b.tgt then b.ret = true end
                        break
                    end
                end
                if b.ret then
                    local a = atan2(p.y - 22 - b.y, p.x - b.x)
                    b.vx, b.vy = cos(a) * 700, sin(a) * 700
                    if hyp(p.x - b.x, p.y - 22 - b.y) < 18 then b.life = 0 flash("holy_star2", b.x, b.y, 30, C.GOLD, 0.15) end
                elseif b.tgt and b.tgt.dead then
                    b.tgt = nearest(b.x, b.y, 260, b.hit)
                    if not b.tgt then b.ret = true end
                end
            elseif b.kind == "frost" then
                b.x, b.y, b.spin = b.x + b.vx * dt, b.y + b.vy * dt, b.spin + dt * 9
                if random() < 0.85 then emit({ img = "mist", tint = C.ICE, x = b.x - b.vx * 0.02, y = b.y - b.vy * 0.02, vx = b.vx * 0.05 + vr(-10, 10), vy = b.vy * 0.05 + vr(-10, 10), life = 0.35, s0 = 10, s1 = 26, a0 = 0.4, a1 = 0, rot = "rnd" }) end
                if random() < 0.4 then emit({ img = "sparkle", tint = C.FROST, x = b.x, y = b.y, vx = vr(-40, 40), vy = vr(-40, 40), life = 0.3, s0 = 7, s1 = 1 }) end
                for _, e in ipairs(R.en) do
                    if not e.dead and not b.hit[e] and not e.M.reaper and hyp(e.x - b.x, e.y - 18 - b.y) < e.M.r + 6 then
                        b.hit[e] = true
                        hurt(e, b.dmg, { slow = 1.6, school = "frost", kb = 25, fx = b.x - b.vx, fy = b.y - b.vy })
                        flash("frost_burst", b.x, b.y, 46, C.ICE, 0.25, { light = 90 })
                        flash("blue_star", b.x, b.y, 54, C.FROST, 0.18)
                        for _ = 1, 5 do emit({ img = "ice_chunks", tint = C.FROST, x = b.x, y = e.y, z = 18, vx = b.vx * 0.15 + vr(-80, 80), vy = b.vy * 0.15 + vr(-60, 60), vz = vr(40, 150), g = 520, life = vr(0.35, 0.6), s0 = vr(6, 10), s1 = 4, a0 = 1, a1 = 0, rot = "rnd", vr = vr(-10, 10), bounce = 0.3 }) end
                        sound("icelance", 0.07)
                        b.pierce = b.pierce - 1
                        if b.pierce < 0 then b.life = 0 break end
                    end
                end
            elseif b.kind == "arcane" then
                if not b.tgt or b.tgt.dead then local vis = visible() b.tgt = #vis > 0 and vis[floor(rnd() * #vis) + 1] or nil end
                if b.tgt then
                    local a = atan2(b.tgt.y - 18 - b.y, b.tgt.x - b.x)
                    local k = min(1, dt * 5.5)
                    b.vx, b.vy = b.vx + (cos(a) * 380 - b.vx) * k, b.vy + (sin(a) * 380 - b.vy) * k
                end
                b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
                if random() < 0.5 then emit({ img = "sparkle", tint = C.ARC, x = b.x, y = b.y, vx = vr(-20, 20), vy = vr(-20, 20), life = 0.4, s0 = 7, s1 = 1 }) end
                if b.tgt and hyp(b.tgt.x - b.x, b.tgt.y - 18 - b.y) < b.tgt.M.r + 6 then
                    hurt(b.tgt, b.dmg, { school = "arcane", kb = 12, fx = b.x - b.vx, fy = b.y - b.vy })
                    flash("arcane_burst", b.x, b.y, 44, nil, 0.25, { light = 70 })
                    flash("lens", b.x, b.y, 40, C.ARC, 0.18)
                    sparks(b.x, b.y, 4, C.ARC, { g = 0, up0 = 0, up1 = 20, s = 8 })
                    sound("starfire", 0.05)
                    b.life = 0
                end
            elseif b.kind == "grenade" then
                b.t, b.spin = b.t + dt, b.spin + dt * 14
                if b.t < 0 then
                    b.x, b.y, b.sx, b.sy = p.x, p.y - 20, p.x, p.y - 20
                else
                    local f = min(1, b.t / b.dur)
                    b.gx, b.gy = b.sx + (b.tx - b.sx) * f, b.sy + 20 + (b.ty - b.sy - 20) * f
                    b.x, b.y = b.gx, b.gy - 20 * (1 - f) - sin(f * pi) * 110
                    if random() < 0.8 then emit({ img = "sparkle", tint = C.EMBER, x = b.x + 5, y = b.y - 7, vx = vr(-30, 30), vy = vr(-40, 0), life = 0.3, s0 = 6, s1 = 1 }) end
                    if f >= 1 then b.life = 0 explode(b.tx, b.ty, b.r, b.dmg) end
                end
            end
        end
        if b.life <= 0 then remove(R.proj, i) else i = i + 1 end
    end

    -- dragonlings (orbiters)
    local dr = R.spells.dragonling
    if dr then
        local n = 1 + floor(dr.r / 2)
        dr.orbs = dr.orbs or {}
        for k = 1, n do
            local a, rad = dr.a * 2.4 + (k - 1) / n * TAU, 92 * R.st.area
            local x, y = p.x + cos(a) * rad, p.y - 16 + sin(a) * rad * 0.62
            local o = dr.orbs[k] or {}
            o.x, o.y, o.a = x, y, a
            dr.orbs[k] = o
            emit({ img = "flame", x = x, y = y, vx = -sin(a) * 30, vy = vr(-30, -10), life = 0.35, s0 = 22, s1 = 6, a0 = 0.8, a1 = 0, rot = "rnd" })
            for _, e in ipairs(R.en) do
                if not e.dead and not e.M.reaper and e.hitT <= 0 and hyp(e.x - x, e.y - 16 - y) < e.M.r + 14 then
                    e.hitT = 0.45
                    hurt(e, 8 + 4 * dr.r, { kb = 30, fx = x, fy = y, school = "fire" })
                    flash("fire_core", x, y, 44, nil, 0.2, { light = 80 })
                    sound("fireimpact2", 0.12, 0.5)
                end
            end
        end
        for k = n + 1, #dr.orbs do dr.orbs[k] = nil end
    end

    i = 1
    while i <= #R.eproj do
        local b = R.eproj[i]
        b.life = b.life - dt
        b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
        if random() < 0.5 then emit({ img = "mist", tint = b.tint or { 140 / 255, 90 / 255, 200 / 255 }, x = b.x, y = b.y, life = 0.4, s0 = 10, s1 = 20, a0 = 0.4, a1 = 0, rot = "rnd" }) end
        if hyp(b.x - p.x, b.y - (p.y - 18)) < (b.size and b.size * 0.5 or 14) then hurtPlayer(b.dmg, b.src or { M = MOBS.lich }) b.life = 0 flash(b.img or "shadow_glyph", b.x, b.y, 40, b.tint, 0.3) end
        if b.life <= 0 then remove(R.eproj, i) else i = i + 1 end
    end

    i = 1
    while i <= #R.tele do
        local t = R.tele[i]
        t.t = t.t - dt
        if t.kind == "flamestrike" and t.t > 0 and random() < 0.9 then
            local a, d = random() * TAU, sqrt(random()) * t.r * 0.9
            emit({ img = "sparkle", tint = C.EMBER, x = t.x + cos(a) * d, y = t.y + sin(a) * d / 1.3, vz = vr(40, 140), life = 0.5, s0 = 8, s1 = 2 })
        end
        if t.onTick and t.t > 0 then t.onTick(t, dt) end
        if t.t <= 0 then
            remove(R.tele, i)
            if t.onEnd then t.onEnd(t)
            elseif t.kind == "pillar" then exorcismHit(t)
            elseif t.kind == "flamestrike" then flamestrikeHit(t)
            elseif t.kind == "slam" then
                ring("ring_smoke", t.x, t.y, 20, t.r * 1.2, 0.6, { 150 / 255, 200 / 255, 90 / 255 }, 1)
                puff(t.x, t.y, 12, { 70 / 255, 80 / 255, 50 / 255 }, { a = 0.6, s0 = 30, s1 = 80, spread = 3 })
                shake(0.5) stop(0.06) sound("meteor")
                addDecal(t.x, t.y, t.r * 0.8, { 30 / 255, 26 / 255, 20 / 255 }, "scorch")
                if hyp(p.x - t.x, (p.y - t.y) * 1.3) < t.r then hurtPlayer(30, { M = MOBS.abom }) end
            elseif t.kind == "fnova" then
                ring("nova_ring", t.x, t.y, 20, t.r, 0.45, { 190 / 255, 150 / 255, 1 }, 1)
                ring("ring_shards2", t.x, t.y, 20, t.r, 0.5, { 170 / 255, 130 / 255, 1 }, 0.9)
                sound("frostnova")
                if hyp(p.x - t.x, (p.y - t.y) * 1.3) < t.r then hurtPlayer(20, { M = MOBS.lich }) R.p.chill = 2 end
            end
        else
            i = i + 1
        end
    end

    i = 1
    while i <= #R.areas do
        local a = R.areas[i]
        a.t, a.acc = a.t + dt, a.acc + dt
        areaFx(a, dt)
        if a.acc >= 0.3 then
            a.acc = a.acc - 0.3
            for _, e in ipairs(R.en) do
                if not e.dead and hyp(e.x - a.x, (e.y - a.y) * 1.3) < a.r then
                    if a.kind == "blizzard" then hurt(e, a.dmg, { slow = 0.6, school = "frost" }) else hurt(e, a.dmg, { school = "fire" }) end
                end
            end
        end
        if a.t >= a.dur then remove(R.areas, i) else i = i + 1 end
    end
    i = 1
    while i <= #R.haz do
        local h = R.haz[i]
        h.t, h.acc = h.t + dt, (h.acc or 0) + dt
        if h.vx then h.x, h.y = h.x + h.vx * dt, h.y + (h.vy or 0) * dt end
        if h.onTick then h.onTick(h, dt)
        elseif random() < 0.4 then emit({ img = "smoke_sheet", cell = floor(random() * 40), tint = h.tint or { 90 / 255, 150 / 255, 50 / 255 }, add = false, x = h.x + vr(-h.r, h.r) * 0.8, y = h.y + vr(-h.r, h.r) * 0.5, z = 4, vz = vr(6, 20), life = 1.6, s0 = 24, s1 = 54, a0 = 0.4, a1 = 0, fi = 0.3, rot = "rnd", vr = 0.4 }) end
        local inside = h.t >= (h.arm or 0) and hyp(p.x - h.x, (p.y - h.y) * 1.3) < h.r
        if inside and h.slow then R.pSlowN = min(R.pSlowN, h.slow) end
        local ev = h.every or 0.5
        if h.acc > ev then h.acc = h.acc - ev if inside and (h.dmg or 6) > 0 then hurtPlayer(h.dmg or 6, h.src or { M = MOBS.abom }) end end
        if h.t >= h.dur then remove(R.haz, i) else i = i + 1 end
    end
    for _, f in ipairs(R.fx) do
        if f.kind == "wave" then
            local rr2 = f.r * easeOut(min(1, f.t / f.dur))
            for _ = 1, 10 do local a = random() * TAU emit({ img = "sparkle", tint = C.HOLY, x = f.x + cos(a) * rr2, y = f.y + sin(a) * rr2 / 1.3, vz = vr(20, 80), life = 0.35, s0 = 9, s1 = 2 }) end
            for _, e in ipairs(R.en) do
                if not e.dead and not f.hit[e] and hyp(e.x - f.x, (e.y - f.y) * 1.3) < rr2 then
                    f.hit[e] = true
                    hurt(e, f.dmg, { kb = 130, fx = f.x, fy = f.y, stun = 0.6, school = "holy" })
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- enemies + bosses
---------------------------------------------------------------------------
local GRID = 56
local grid, gridUsed = {}, {}
local function boss(e, dt, d)
    local fn = E.BOSSFN[e.type]
    if fn then fn(e, dt, d) return end
    local p = R.p
    e.cd1, e.cd2, e.cd3 = e.cd1 - dt, e.cd2 - dt, e.cd3 - dt
    if e.cast then e.cast = e.cast - dt if e.cast <= 0 then e.cast = nil end return end
    if e.type == "abom" then
        if e.cd1 <= 0 and d < 420 then
            e.cd1, e.cast, e.atkT = 7, 1.2, 1.2
            R.tele[#R.tele + 1] = { kind = "slam", x = p.x, y = p.y, t = 1.1, t0 = 1.1, r = 110, enemy = true }
        elseif e.cd2 <= 0 then
            e.cd2 = 5
            R.haz[#R.haz + 1] = { kind = "poison", x = e.x, y = e.y, r = 74, t = 0, dur = 9 }
        end
    elseif e.type == "lich" then
        if d > 640 then
            flash("shadow_glyph", e.x, e.y - 40, 100, nil, 0.5)
            local a = rnd() * TAU
            e.x, e.y = p.x + cos(a) * 300, p.y + sin(a) * 200
            flash("shadow_glyph", e.x, e.y - 40, 100, nil, 0.5)
        end
        if e.cd1 <= 0 then
            e.cd1, e.cast, e.atkT = 5, 0.6, 0.9
            flash("arcane_burst", e.x, e.y - 40, 90, { 180 / 255, 120 / 255, 1 }, 0.4, { light = 150 })
            for k = 0, 11 do local a = k / 12 * TAU + R.t R.eproj[#R.eproj + 1] = { x = e.x, y = e.y - 40, vx = cos(a) * 170, vy = sin(a) * 170, dmg = 12, life = 4 } end
        elseif e.cd2 <= 0 and d < 260 then
            e.cd2, e.cast, e.atkT = 9, 1.0, 1.1
            R.tele[#R.tele + 1] = { kind = "fnova", x = e.x, y = e.y, t = 1.0, t0 = 1.0, r = 170, enemy = true }
        elseif e.cd3 <= 0 then
            e.cd3 = 12
            for k = 0, 5 do
                local a = k / 6 * TAU
                local x, y = p.x + cos(a) * 170, p.y + sin(a) * 120
                emit({ img = "scourge_runes", tint = C.GREEN, x = x, y = y, life = 0.9, s0 = 20, s1 = 70, a0 = 1, a1 = 0, flat = true, rot = "rnd", vr = 3, light = 70 })
                spawn("skeleton", x, y)
            end
        end
    end
end

local function updateEnemies(dt)
    local p = R.p
    for k in pairs(gridUsed) do local b = grid[k] for j = #b, 1, -1 do b[j] = nil end gridUsed[k] = nil end
    for _, e in ipairs(R.en) do
        if not e.dead then
            local k = floor(e.x / GRID) * 4099 + floor(e.y / GRID)
            local b = grid[k]
            if not b then b = {} grid[k] = b end
            b[#b + 1] = e
            gridUsed[k] = true
        end
    end
    for _, e in ipairs(R.en) do
        if not e.dead then
            local M = e.M
            e.spawnT = e.spawnT + dt
            e.flash, e.hitT, e.sq = max(0, e.flash - dt), max(0, e.hitT - dt), max(0, e.sq - dt * 1.6)
            e.slow, e.stun = max(0, e.slow - dt), max(0, e.stun - dt)
            if e.frz > 0 then
                e.frz = e.frz - dt
                if e.frz <= 0 then
                    e.frz = 0
                    for _ = 1, 6 do emit({ img = "ice_chunks", tint = C.FROST, x = e.x, y = e.y, z = 20, vx = vr(-90, 90), vy = vr(-60, 60), vz = vr(60, 160), g = 520, life = 0.5, s0 = 9, s1 = 5, rot = "rnd", vr = 8, bounce = 0.3 }) end
                    sound("icenuke", 0.15, 0.4)
                end
            end
            if e.life then e.life = e.life - dt if e.life <= 0 then e.dead = true end end
            if e.poison and e.poison > 0 and not e.dead then                  -- (Maexxna's Fang)
                e.poisonT = e.poisonT - dt
                e.pAcc = (e.pAcc or 0) + dt
                if e.pAcc >= 1 then e.pAcc = e.pAcc - 1 hurt(e, 6 * e.poison, { dot = true, school = "nature" }) end
                if e.poisonT <= 0 then e.poison = 0 end
            end
            if e.berserkAt and not e.berserk and R.t >= e.berserkAt and not e.dead then
                e.berserk = true
                warn(M.name .. " goes berserk!", RED) sound("bosswarn") shake(0.5)
            end
            if not e.dead then
                local sp = M.spd * (e.slow > 0 and 0.55 or 1) * (e.berserk and 2 or 1) * (e.spdMul or 1)
                if M.reaper then sp = M.spd + max(0, R.t - 900) * 6 end
                if e.frz > 0 or e.stun > 0 then sp = 0 end
                local dx, dy = p.x - e.x, p.y - e.y
                local d = hyp(dx, dy)
                if d == 0 then d = 1 end
                if M.boss then boss(e, dt, d) elseif M.naxx and E.MOBTICK then E.MOBTICK(e, dt, d) end
                if R.preview then sp = 0 end
                if M.boss and M.naxx and d > 560 then sp = sp * 2.5 end     -- (a master far away closes in)
                if e.cast or e.root or e.dead then sp = 0 end
                local vx, vy
                if e.fixed then vx, vy = e.fixed[1], e.fixed[2] + sin(R.t * 4 + e.wob) * 30
                else
                    vx, vy = dx / d * sp, dy / d * sp
                    if M.fly or M.ghost then vx, vy = vx + cos(R.t * 3 + e.wob) * sp * 0.35, vy + sin(R.t * 2.6 + e.wob) * sp * 0.35 end
                end
                if not M.fly and not e.fixed then
                    local cx, cy = floor(e.x / GRID), floor(e.y / GRID)
                    local sx, sy = 0, 0
                    for ix = cx - 1, cx + 1 do
                        for iy = cy - 1, cy + 1 do
                            local b = grid[ix * 4099 + iy]
                            if b then
                                for _, o in ipairs(b) do
                                    if o ~= e then
                                        local ox, oy, rr2 = e.x - o.x, e.y - o.y, M.r + o.M.r
                                        local dd = ox * ox + oy * oy
                                        if dd < rr2 * rr2 and dd > 0.01 then
                                            local l = sqrt(dd)
                                            local push = (rr2 - l) / rr2 * o.M.mass / (M.mass + 0.5)
                                            sx, sy = sx + ox / l * push, sy + oy / l * push
                                        end
                                    end
                                end
                            end
                        end
                    end
                    vx, vy = vx + sx * 90, vy + sy * 90
                end
                if e.kb > 0 then vx, vy = vx + e.kx * e.kb * 4, vy + e.ky * e.kb * 4 e.kb = max(0, e.kb - dt * 420) end
                e.x, e.y = e.x + vx * dt, e.y + vy * dt
                local mv = hyp(vx, vy)
                if e.cast or e.atkT > 0 then e.dir = dirOf(dx, dy)
                elseif mv > 5 and sp > 0 then e.dir = dirOf(vx, vy) end
                if (sp > 0 or e.fixed) and not (e.frz > 0) then
                    local U = ns.HTLArt.UNITS[M.sprite or e.type] or ns.HTLArt.UNITS.ghoul
                    e.anim = e.anim + dt * (e.fixed and 14 or 8 / (U.moveDur / 1000) * clamp(mv / max(1, M.spd), 0.5, 1.6))
                end
                if e.atkT > 0 then e.atkT = e.atkT - dt end
                if d < M.r + 13 and e.frz <= 0 and e.stun <= 0 and not e.noTouch and not e.dead then
                    if M.reaper then R.over = "victory" else hurtPlayer(M.dmg * (e.berserk and 10 or 1) * (e.dmgMul or 1), e) end
                end
                if not M.boss and not M.elite and not M.reaper and (abs(dx) > VW * 0.95 or abs(dy) > VH * 1.1) then e.x, e.y = edgePoint(40) end
            end
        end
    end
    local i = 1
    while i <= #R.en do if R.en[i].dead then table.remove(R.en, i) else i = i + 1 end end
end

---------------------------------------------------------------------------
-- pickups, xp, level-ups
---------------------------------------------------------------------------
local function gainXp(v)
    R.xp = R.xp + v * R.st.xp
    R.runes = R.runes + v
    while R.xp >= R.xpNext do
        R.xp = R.xp - R.xpNext
        R.level = R.level + 1
        R.xpNext = floor(6 + R.level * 4 + max(0, R.level - 20) * 6 + 0.5)
        R.pending = R.pending + 1
    end
end

local openChest
local function updatePickups(dt)
    local p, mag = R.p, R.st.magnet
    local i = 1
    while i <= #R.gems do
        local g = R.gems[i]
        g.t = g.t + dt
        local got = false
        if g.pop > 0 then g.pop = g.pop - dt g.x, g.y = g.x + g.vx * dt, g.y + g.vy * dt
        else
            local dx, dy = p.x - g.x, p.y - 14 - g.y
            local d = hyp(dx, dy)
            if g.m or d < mag then g.m = true local sp = 260 + g.t * 60 g.x, g.y = g.x + dx / d * sp * dt * 1.6, g.y + dy / d * sp * dt * 1.6 end
            if d < 16 then
                got = true
                gainXp(g.v)
                if R.relics.collar and p.noHeal <= 0 then p.hp = min(p.maxHp, p.hp + 1) end
                R.xpPulse = 1
                if R.t - R.gemChainT < 0.25 then R.gemChain = R.gemChain + 1 else R.gemChain = 0 end
                R.gemChainT = R.t
                sound("gem", 0.045)
                emit({ img = "sparkle", tint = g.v >= 25 and C.ARC or g.v >= 3 and C.ICE or C.GREEN, x = p.x + vr(-6, 6), y = p.y - 18, vz = 30, life = 0.3, s0 = 14, s1 = 2 })
            end
        end
        if got then remove(R.gems, i) else i = i + 1 end
    end
    if #R.gems > 420 then
        local v, x0, y0, n = 0, nil, nil, 0
        local j = 1
        while j <= #R.gems do
            local g = R.gems[j]
            if hyp(g.x - p.x, g.y - p.y) > 500 then v, n = v + g.v, n + 1 x0, y0 = x0 or g.x, y0 or g.y remove(R.gems, j) else j = j + 1 end
        end
        if n > 0 then R.gems[#R.gems + 1] = { x = x0, y = y0, v = v, t = 0, m = false, pop = 0, vx = 0, vy = 0 } end
    end
    i = 1
    while i <= #R.pick do
        local k = R.pick[i]
        k.t = k.t + dt
        local d = hyp(p.x - k.x, p.y - k.y)
        local got = false
        if k.kind == "cauldron" then
            for _, b in ipairs(R.proj) do if hyp(b.x - k.x, b.y - (k.y - 20)) < 30 then k.hp = 0 end end
            for _, f in ipairs(R.fx) do if f.kind == "wave" and hyp(f.x - k.x, f.y - k.y) < f.r * min(1, f.t / f.dur) then k.hp = 0 end end
            local cs = R.spells.consecration
            if cs and cs.rad and d < cs.rad then k.hp = 0 end
            if R.spells.nova and d < 140 then k.hp = 0 end
            if k.hp <= 0 then
                got = true
                flash("white_orb", k.x, k.y - 20, 80, C.GREEN, 0.4, { light = 160 })
                for _ = 1, 10 do emit({ img = "ice_chunks2", tint = { 120 / 255, 110 / 255, 100 / 255 }, add = false, x = k.x, y = k.y, z = 20, vx = vr(-140, 140), vy = vr(-100, 100), vz = vr(80, 240), g = 600, life = 0.9, s0 = 9, s1 = 7, a0 = 1, a1 = 0, ease = "late", rot = "rnd", vr = 8, bounce = 0.3 }) end
                puff(k.x, k.y, 6, { 100 / 255, 150 / 255, 70 / 255 }, { a = 0.5, s0 = 20, s1 = 60, spread = 2 })
                sound("fireimpact2", 0.05, 0.6)
                local roll = rnd()
                R.pick[#R.pick + 1] = { kind = roll < 0.4 and "gold" or roll < 0.7 and "healthstone" or roll < 0.86 and "lootarang" or "sapper", x = k.x, y = k.y, v = 10 + floor(rnd() * 15), t = 0 }
            end
        elseif not k.static and d < (k.kind == "chest" and 26 or 22) then
            got = true
            if k.kind == "gold" then
                local v = floor(k.v * (1 + 0.1 * (R.tal.greed or 0)) + 0.5)
                R.gold = R.gold + v R.texts[#R.texts + 1] = { x = p.x, y = p.y - 50, vx = 0, vy = -60, v = "+" .. v .. "g", t = 0, life = 1, col = { 1, 0.82, 0.25 } } sound("coin")
            elseif k.kind == "healthstone" then
                local h = floor(40 * (1 + 0.5 * (R.tal.favor or 0)) * (R.relics.hammer and 2 or 1))
                if (R.p.noHeal or 0) > 0 or R.healLock then h = 0 end
                if R.relics.hammer and h > 0 then R.hotT = 4 end
                R.p.hp = min(R.p.maxHp, R.p.hp + h) R.texts[#R.texts + 1] = { x = p.x, y = p.y - 50, vx = 0, vy = -60, v = "+" .. h, t = 0, life = 1, col = { 0.38, 1, 0.38 } } flash("white_orb", p.x, p.y - 20, 80, C.GREEN, 0.4) sound("pick")
            elseif k.kind == "lootarang" then for _, g in ipairs(R.gems) do g.m = true end warn("Loot-A-Rang! Every rune flies to you.", ICEW) sound("pick")
            elseif k.kind == "sapper" then
                R.flash = 0.6 R.flashC = { 1, 0.9, 0.7 } shake(0.8) stop(0.1)
                flash("fire_core", p.x, p.y, 1200, nil, 0.7, { light = 2000 })
                for _, e in ipairs(R.en) do if onScreen(e) and not e.M.boss and not e.M.reaper then kill(e, false, { noSoul = random() < 0.7 }) end end
                sound("meteor") sound("fireimpact")
            elseif k.kind == "chest" then openChest(k.boss, k.src) end
        end
        if got then remove(R.pick, i) else i = i + 1 end
    end
end

local OPTS = {}
local function choices(n)
    local opts = {}
    local nSp, nPa = #R.order, #R.porder
    for _, id in ipairs(D.SPELL_ORDER) do
        local S_ = SPELLS[id]
        if not ((S_.cls and S_.cls ~= R.cls) or R.banished[id]) then
            local s = R.spells[id]
            local shut = (not s and R.rules.oneSpell) or (R.blessOnly or 0) > 0
            if not shut and not (s and s.r >= S_.max) and not (not s and nSp >= 6) then opts[#opts + 1] = { kind = "spell", id = id, w = S_.cls and 3 or 1.4, r = s and s.r + 1 or 1 } end
        end
    end
    for _, id in ipairs(D.PASSIVE_ORDER) do
        local r = R.passives[id] or 0
        if not (r >= 5 or (r == 0 and nPa >= 6) or R.banished[id]) then opts[#opts + 1] = { kind = "passive", id = id, w = 1.4, r = r + 1 } end
    end
    local out = {}
    while #out < n and #opts > 0 do
        local tot = 0
        for _, o in ipairs(opts) do tot = tot + o.w end
        local x, j = rnd() * tot, 1
        for k = 1, #opts do x = x - opts[k].w j = k if x <= 0 then break end end
        out[#out + 1] = table.remove(opts, j)
    end
    if #out == 0 then out[1] = { kind = "gold", id = "gold", r = 0 } out[2] = { kind = "heal", id = "heal", r = 0 } end
    return out
end
function E.Choices(run, n) E.Use(run) return choices(n) end

legendFx = function()
    local p = R.p
    R.flash = 0.5 R.flashC = { 1, 0.86, 0.6 } shake(0.5)
    flash("sun_ring", p.x, p.y - 30, 300, C.HOLY, 0.8, { light = 600 })
    ring("ring_wide", p.x, p.y, 20, 360, 0.9, { 1, 160 / 255, 60 / 255 }, 1)
    for k = 0, 13 do local a = k / 14 * TAU emit({ img = "levelup_rays", tint = { 1, 170 / 255, 60 / 255 }, x = p.x + cos(a) * 46, y = p.y + sin(a) * 30 - 40, life = 1.4, s0 = 50, s1 = 70, sx = 0.8, sy = 2.2, a0 = 1, a1 = 0, fi = 0.1 }) end
    sparks(p.x, p.y, 40, { 1, 180 / 255, 80 / 255 }, { v0 = 100, v1 = 420, light = 20 })
end
E.LegendFx = function(run) E.Use(run) legendFx() end

local function apply(o)
    if o.kind == "spell" then addSpell(o.id)
    elseif o.kind == "passive" then addPassive(o.id) if R.blessOnly then R.blessOnly = max(0, R.blessOnly - 1) end
    elseif o.kind == "gold" then R.gold = R.gold + 25
    elseif o.kind == "heal" then R.p.hp = R.p.maxHp
    elseif o.kind == "relic" then addRelic(o.id) R.relicSeen = R.relicSeen or {} R.relicSeen[o.id] = true
    elseif o.kind == "legend" then
        R.legend[o.id] = true
        if o.id == "consecration" then R.ashbringer = true end
        legendFx()
    end
    R.slotFlash[o.id] = 1
end
function E.Apply(run, o) E.Use(run) apply(o) end

local function evolvable()
    if R.rules.noLegend then return nil end
    for _, id in ipairs({ "consecration", "arcane", "cleave" }) do
        local s = R.spells[id]
        if s and s.r >= SPELLS[id].max and R.passives[LEGEND[id].need] and not R.legend[id] then return id end
    end
end
E.Evolvable = function(run) E.Use(run) return evolvable() end

openChest = function(isBoss, src)
    local items = {}
    local ev = evolvable()
    if ev then items[1] = { kind = "legend", id = ev } end
    local n = (isBoss and 3 or (rnd() < 0.12 and 5 or rnd() < 0.3 and 3 or 1)) + (R.tal.hoard and 1 or 0)
    local guard = 0
    while #items < n and guard < 30 do
        guard = guard + 1
        local c = choices(1)[1]
        if not c then break end
        local dup = false
        for _, it in ipairs(items) do if it.id == c.id and c.kind ~= "gold" and c.kind ~= "heal" then dup = true end end
        if not dup then items[#items + 1] = c end
    end
    local gold = isBoss and 60 or 20 + floor(rnd() * 20)
    R.gold = R.gold + gold
    for _, it in ipairs(items) do if it.kind ~= "legend" then apply(it) end end
    -- relics: a necropolis boss offers three (its own first); once Kel'Thuzad has fallen, any boss may add one of his
    local pool, own, seen = {}, R.relics, {}
    if isBoss and src and D.RELIC_FROM and D.RELIC_FROM[src] then
        for _, id in ipairs(D.RELIC_FROM[src]) do if not own[id] and not seen[id] then pool[#pool + 1] = id seen[id] = true end end
        local others = {}
        for _, id in ipairs(D.RELIC_ORDER) do if not D.RELICS[id].legend and not own[id] and not seen[id] then others[#others + 1] = id end end
        while #pool < 3 and #others > 0 do local id = table.remove(others, floor(rnd() * #others) + 1) pool[#pool + 1] = id seen[id] = true end
    end
    if isBoss and R.ktSlain and D.RELIC_LEGEND and rnd() < D.RELIC_LEGEND_CHANCE then
        local leg = {}
        for _, id in ipairs(D.RELIC_LEGEND) do if not own[id] then leg[#leg + 1] = id end end
        if #leg > 0 then local id = leg[floor(rnd() * #leg) + 1] if #pool >= 3 then pool[3] = id else pool[#pool + 1] = id end end
    end
    local relics
    if #pool > 0 then
        relics = {}
        for i = 1, min(3, #pool) do relics[i] = { kind = "relic", id = pool[i] } end
        if R.bot or R.ff then apply(relics[1]) relics = nil end         -- (the bot Needs the first)
    end
    R.chest = { items = items, gold = gold, relics = relics }   -- (the UI shows the coffer; a legend in it is taken there)
end
E.OpenChest = function(run, isBoss, src) E.Use(run) openChest(isBoss, src) end

---------------------------------------------------------------------------
-- the player
---------------------------------------------------------------------------
local function botInput()
    local p = R.p
    local ax, ay = 0, 0
    local melee = D.CLASSES[R.cls].melee
    local naxx = R.ST and R.ST.key ~= "epl"
    for _, e in ipairs(R.en) do
        local dx, dy = p.x - e.x, p.y - e.y
        local d2 = dx * dx + dy * dy
        local big = e.M.boss or e.M.elite
        if naxx and e.M.boss then                                  -- (the necropolis: keep its master in reach, not away)
            local d = sqrt(d2)
            local want = melee and 70 or 190
            if d > want + 60 and not e.immune then ax, ay = ax - dx / d * 0.03, ay - dy / d * 0.03
            elseif d < want then local w = 2 / max(400, d2) ax, ay = ax + dx * w, ay + dy * w end
        elseif melee and not big then
            if d2 <= 46 * 46 then local w = 1 / max(400, d2) ax, ay = ax + dx * w, ay + dy * w end
        elseif d2 <= 260 * 260 then local w = (big and 4 or 1) / max(400, d2) ax, ay = ax + dx * w, ay + dy * w end
    end
    if melee then
        local t = nearest(p.x, p.y, 400)
        if t and not (t.M.boss or t.M.elite) then
            local d = hyp(t.x - p.x, t.y - p.y)
            if d > 70 then ax, ay = ax + (t.x - p.x) / d * 0.01, ay + (t.y - p.y) / d * 0.01 end
        end
    end
    for _, t in ipairs(R.tele) do
        if t.enemy then
            if t.shape == "line" then
                local lx, ly = t.x2 - t.x, t.y2 - t.y
                local L2 = max(1, lx * lx + ly * ly)
                local k = clamp(((p.x - t.x) * lx + (p.y - t.y) * ly) / L2, 0, 1)
                local cx2, cy2 = t.x + lx * k, t.y + ly * k
                local dx, dy = p.x - cx2, p.y - cy2
                local d = max(1, hyp(dx, dy))
                if d < (t.w or 40) / 2 + 26 then ax, ay = ax + dx / d * 0.1, ay + dy / d * 0.1 end
            elseif t.shape == "band" then
                if p.x > t.x and p.x < t.x + t.w then local mid = t.x + t.w / 2 ax = ax + (p.x < mid and -0.12 or 0.12) end
            elseif t.r then
                local dx, dy = p.x - t.x, p.y - t.y local d = max(1, hyp(dx, dy)) if d < t.r + 30 then ax, ay = ax + dx / d * 0.08, ay + dy / d * 0.08 end
            end
        end
    end
    if R.botGoal then local g = R.botGoal local dx, dy = g.x - p.x, g.y - p.y local d = max(1, hyp(dx, dy)) if d > 12 then ax, ay = ax + dx / d * (g.w or 0.1), ay + dy / d * (g.w or 0.1) end end
    for _, h in ipairs(R.haz) do if (h.dmg or 6) > 0 and not h.safe then local dx, dy = p.x - h.x, p.y - h.y local d = max(1, hyp(dx, dy)) if d < h.r + 30 then ax, ay = ax + dx / d * 0.05, ay + dy / d * 0.05 end end end
    local g, gd = nil, 1e9
    for _, x in ipairs(R.gems) do local d = hyp(x.x - p.x, x.y - p.y) if d < gd then gd, g = d, x end end
    for _, k in ipairs(R.pick) do if k.kind ~= "cauldron" then local d = hyp(k.x - p.x, k.y - p.y) * 0.5 if d < gd then gd, g = d, k end end end
    if g and gd < 400 and gd > 0 then ax, ay = ax + (g.x - p.x) / gd * 0.012, ay + (g.y - p.y) / gd * 0.012 end
    ax, ay = ax + cos(R.t * 0.31) * 0.004, ay + sin(R.t * 0.23) * 0.004
    return ax, ay
end

local function updatePlayer(dt, ix, iy)
    local p = R.p
    if p.dead then p.deadT = p.deadT + dt return end
    if R.preview then
        ix, iy = 0, 0
        if R.pvMove then ix, iy = cos(R.t * 0.9), sin(R.t * 0.9) * 0.7 end
    elseif R.bot then ix, iy = botInput() end
    p.atkT = max(0, (p.atkT or 0) - dt)
    if p.dash then
        local d = p.dash
        d.t = d.t + dt
        local k = min(1, d.t / d.dur)
        local e2 = 1 - (1 - k) * (1 - k)
        p.x, p.y = d.x0 + (d.x1 - d.x0) * e2, d.y0 + (d.y1 - d.y0) * e2
        p.dir, p.moving = dirOf(d.x1 - d.x0, d.y1 - d.y0), true
        p.anim = p.anim + dt * 24
        puff(p.x, p.y, 1, { 0.42, 0.36, 0.28 }, { a = 0.45, s0 = 12, s1 = 32, life = 0.5 })
        if k >= 1 then p.dash = nil chargeLand(d) end
        p.inv, p.hurtT, p.chill = max(0, p.inv - dt), max(0, p.hurtT - dt), max(0, p.chill - dt)
        return
    end
    if p.pull then                                                -- (thrown: Web Wrap, a knockback)
        local q = p.pull
        q.t = q.t + dt
        local k = min(1, q.t / q.dur)
        p.x, p.y = q.x0 + (q.x1 - q.x0) * easeOut(k), q.y0 + (q.y1 - q.y0) * easeOut(k)
        if k >= 1 then p.pull = nil end
        p.inv, p.hurtT, p.chill = max(0, p.inv - dt), max(0, p.hurtT - dt), max(0, p.chill - dt)
        return
    end
    if (p.stunT or 0) > 0 then p.stunT = p.stunT - dt ix, iy = 0, 0 end
    if (p.rev or 0) > 0 then p.rev = p.rev - dt ix, iy = -(ix or 0), -(iy or 0) end
    p.noHeal = max(0, (p.noHeal or 0) - dt)
    local l = hyp(ix or 0, iy or 0)
    local sp = R.st.speed * (p.chill > 0 and 0.6 or 1) * (R.pSlow or 1) * ((R.cold or 0) >= 50 and 0.75 or 1)
    if l > 0.001 then
        p.vx, p.vy = ix / l, iy / l
        p.x, p.y = p.x + p.vx * sp * dt, p.y + p.vy * sp * dt
        p.dir = dirOf(p.vx, p.vy)
        p.anim = p.anim + dt * 8 / (ns.HTLArt.UNITS.paladin.moveDur / 1000) * 1.15
        p.moving = true
        if R.passives.cheetah and random() < 0.3 then emit({ img = "mist", tint = { 200 / 255, 190 / 255, 150 / 255 }, add = false, x = p.x - p.vx * 10, y = p.y, z = 2, life = 0.4, s0 = 8, s1 = 18, a0 = 0.3, a1 = 0, rot = "rnd" }) end
    else
        p.moving = false
        if R.preview and R.pvFace then p.dir = R.pvFace end
    end
    p.inv, p.hurtT, p.chill = max(0, p.inv - dt), max(0, p.hurtT - dt), max(0, p.chill - dt)
    if p.noHeal <= 0 and not R.healLock then
        p.hp = min(p.maxHp, p.hp + R.st.regen * dt)
        if (R.hotT or 0) > 0 then p.hp = min(p.maxHp, p.hp + p.maxHp * 0.05 * dt) end
    end
end

---------------------------------------------------------------------------
-- step
---------------------------------------------------------------------------
local function updFeel(dt)
    R.trauma = max(0, R.trauma - dt * 1.4)
    local k = max(0, 1 - dt * 12)
    R.kick.x, R.kick.y = R.kick.x * k, R.kick.y * k
    R.flash = max(0, R.flash - dt)
    R.xpPulse = max(0, R.xpPulse - dt * 3)
    for id, v in pairs(R.slotFlash) do v = v - dt * 1.2 R.slotFlash[id] = v > 0 and v or nil end
end
local function updFx(dt)
    local i = 1
    while i <= #R.fx do local f = R.fx[i] f.t = f.t + dt if f.t >= f.dur then remove(R.fx, i) else i = i + 1 end end
    local keep = R.preview and 1.1 or 2.2
    i = 1
    while i <= #R.corpses do local c = R.corpses[i] c.t = c.t + dt if c.t >= keep then table.remove(R.corpses, i) else i = i + 1 end end
    i = 1
    while i <= #R.texts do
        local t = R.texts[i]
        t.t = t.t + dt
        t.x, t.y, t.vy = t.x + t.vx * dt, t.y + t.vy * dt, t.vy + 160 * dt
        if t.t >= t.life then remove(R.texts, i) R.free[#R.free + 1] = t else i = i + 1 end
    end
    i = 1
    while i <= #R.decals do local d = R.decals[i] d.t = d.t + dt if d.t >= 40 then table.remove(R.decals, i) else i = i + 1 end end
    i = 1
    while i <= #R.arcs do local a = R.arcs[i] a.t = a.t + dt if a.t >= a.life then remove(R.arcs, i) else i = i + 1 end end
    if R.warn then R.warn.t = R.warn.t - dt if R.warn.t <= 0 then R.warn = nil end end
end

local function beginLevelUp()
    local p = R.p
    R.lvlT, R.tsGoal = 0, 0.04
    sound("levelup")
    flash("sun_ring", p.x, p.y - 24, 160, C.GOLD, 0.6, { light = 400 })
    ring("ring_wide", p.x, p.y, 10, 120, 0.5, C.GOLD, 1)
    for k = 0, 11 do local a = k / 12 * TAU emit({ img = "levelup_rays", tint = C.GOLD, x = p.x + cos(a) * 26, y = p.y + sin(a) * 16 - 30, life = 1.1, s0 = 30, s1 = 46, sx = 0.7, sy = 2.4, a0 = 0.95, a1 = 0, fi = 0.15 }) end
    for _ = 1, 22 do emit({ img = "sparkle", tint = C.HOLY, x = p.x + vr(-24, 24), y = p.y + vr(-8, 8), z = vr(0, 30), vz = vr(60, 200), life = vr(0.6, 1.2), s0 = vr(8, 14), s1 = 2 }) end
end

-- input: ix, iy (the movement keys, -1..1). Sets run.wantLevelUp when the picker should open (the UI clears it).
function E.Step(run, dt, ix, iy)
    E.Use(run)
    if run.paused or run.over then return end
    run.ts = run.ts + (run.tsGoal - run.ts) * min(1, dt * 9)
    run.hsCool = run.hsCool - dt
    if run.hitstop > 0 then run.hitstop = run.hitstop - dt updFeel(dt) return end
    local wdt = dt * run.ts
    if run.p.dead then
        run.p.deadT = run.p.deadT + dt
        if run.p.deadT > 1.6 and not run.over then run.over = "dead" end
        updFx(wdt) updParts(dt)
        return
    end
    run.t = run.t + wdt
    if run.tal.wrath then
        local on = run.t > 8 and run.t % 45 < 8
        if on and not run.wrathOn then warn("Avenging Wrath", C.GOLD) sound("crusader") legendFx() end
        run.wrathOn = on
    end
    run.pSlow, run.pSlowN = run.pSlowN or 1, 1
    updatePlayer(wdt, ix, iy)
    runEvents()
    spawner(wdt)
    castSpells(wdt)
    updateEnemies(wdt)
    updateProj(wdt)
    updatePickups(wdt)
    E._relicTick(wdt)
    if run.pendingChain then local e = run.pendingChain run.pendingChain = nil if not e.dead then chain(e, 4, 20) end end
    E._allies(wdt)
    local SF = E.STAGEFN[run.stage]
    if SF and SF.tick then SF.tick(wdt) end
    if run.victoryT then run.victoryT = run.victoryT - wdt if run.victoryT <= 0 and not run.over then run.over = "victory" end end
    updFx(wdt)
    updParts(dt * max(run.ts, 0.4))
    updFeel(dt)
    if run.lvlT >= 0 then
        run.lvlT = run.lvlT + dt
        if run.lvlT > 0.42 then run.lvlT = -1 run.wantLevelUp = true end
    elseif run.pending > 0 and not run.wantLevelUp then
        if run.bot or run.preview or run.lab then
            while run.pending > 0 do
                run.pending = run.pending - 1
                if not run.preview and not run.lab then
                    local c = choices(3)
                    local pickC = c[1]
                    for _, o in ipairs(c) do if o.kind == "spell" and SPELLS[o.id].cls then pickC = o break end end
                    apply(pickC)
                end
            end
        else
            beginLevelUp()
        end
    end
end

-- Only the particles (while a picker is up and the world is frozen, the chosen card's sparks still fly).
function E.StepParts(run, dt) E.Use(run) updParts(dt) end

-- the demos (title, hub poster): a run that looks a minute and a half old at once - the clock at t, its wave closing in
-- from all round, xp lying about - instead of simulating that long (a 95 s fast-forward was ~0.8 s of Lua)
function E.JumpStart(run, t)
    E.Use(run)
    R.t = t
    while R.evI <= #D.EVENTS and D.EVENTS[R.evI].t <= t do R.evI = R.evI + 1 end
    local want = floor(D.Target(t) * 1.1)
    for _ = 1, want do
        local a, d = rnd() * TAU, rr(130, 520)
        local x, y = R.p.x + cos(a) * d, R.p.y + sin(a) * d * 0.72
        spawn(pickW(waveAt(t)), x, y, { dir = dirOf(R.p.x - x, R.p.y - y) })
    end
    for _ = 1, 26 do
        local a, d = rnd() * TAU, rr(60, 360)
        R.gems[#R.gems + 1] = { x = R.p.x + cos(a) * d, y = R.p.y + sin(a) * d * 0.72, v = 1, t = rnd() * 6, m = false, pop = 0, vx = 0, vy = 0 }
    end
end

-- fast-forward with the bot (attract mode, tests): no particles, no hit-stops
function E.FastForward(run, secs, bot)
    E.Use(run)
    local b = run.bot
    run.bot, run.ff = bot ~= false, true
    local n = floor(secs * 30)
    for _ = 1, n do
        if run.over then break end
        if run.lvlT >= 0 then run.lvlT, run.tsGoal, run.ts = -1, 1, 1 end
        run.wantLevelUp = nil
        E.Step(run, 1 / 30, 0, 0)
    end
    run.bot, run.ff = b, nil
    run.pending = 0
end

-- relics that tick (in E.Step, the run in R)
function E._relicTick(dt)
    local Rl, p = R.relics, R.p
    R.blockCd = (R.blockCd or 0) - dt
    R.hotT = max(0, (R.hotT or 0) - dt)
    R.creepT = max(0, (R.creepT or 0) - dt)
    R.kfOn = max(0, (R.kfOn or 0) - dt)
    if Rl.frigid then
        R.frigidT = (R.frigidT or 8) - dt
        if R.frigidT <= 0 then
            R.frigidT = 8
            ring("nova_ring", p.x, p.y, 20, 90, 0.4, C.FROST, 1)
            ring("ring_shards2", p.x, p.y, 20, 95, 0.5, C.ICE, 0.9)
            for _, e in ipairs(R.en) do if not e.dead and hyp(e.x - p.x, (e.y - p.y) * 1.3) < 90 then hurt(e, 10, { frz = 1.5, school = "frost", dot = true }) end end
            sound("frostnova", 0.5, 0.6)
        end
    end
    if Rl.eye then
        R.eyeT = (R.eyeT or 12) - dt
        if R.eyeT <= 0 then
            R.eyeT = 12
            flash("arcane_burst", p.x, p.y - 30, 80, { 0.7, 0.6, 1 }, 0.4)
            for _, e in ipairs(R.en) do if not e.dead and not e.M.boss and hyp(e.x - p.x, e.y - p.y) < 130 then e.stun = max(e.stun, 1) end end
        end
    end
    if Rl.essence then
        R.essT = ((R.essT or 0) + dt) % 30
        local on = R.essT < 20
        if on and not R.essenceOn then flash("frost_burst", p.x, p.y - 30, 90, C.ICE, 0.4, { light = 140 }) end
        R.essenceOn = on
    end
end
function E._allies(dt)
    local i = 1
    while i <= #R.allies do
        local a = R.allies[i]
        a.t, a.hitT = a.t + dt, a.hitT - dt
        local tgt = nearest(a.x, a.y, 320)
        if tgt then
            local dx, dy = tgt.x - a.x, tgt.y - a.y
            local d = max(1, hyp(dx, dy))
            if d > tgt.M.r + 10 then a.x, a.y = a.x + dx / d * 120 * dt, a.y + dy / d * 120 * dt a.anim = a.anim + dt * 12
            elseif a.hitT <= 0 then a.hitT = 0.5 hurt(tgt, 15, { school = "shadow", dot = true }) end
            a.dir = dirOf(dx, dy)
        end
        if a.t >= a.life then
            emit({ img = "ghost_blue", tint = { 0.6, 1, 0.6 }, x = a.x, y = a.y - 18, vy = -40, life = 0.9, s0 = 22, s1 = 36, sx = 2, sy = 1, a0 = 0.6, a1 = 0, rot = -pi / 2 })
            remove(R.allies, i)
        else i = i + 1 end
    end
end

E.Kill = function(run, e, silent) E.Use(run) kill(e, silent) end
E.Hurt = function(run, e, dmg, o) E.Use(run) hurt(e, dmg, o) end

-- the tools the bosses' scripts use (NaxxBoss.lua): all act on the run being stepped
E.I = { emit = emit, flash = flash, ring = ring, sparks = sparks, puff = puff, shake = shake, stop = stop, kick = kick, spawn = spawn,
    hurt = hurt, kill = function(e, silent, o) kill(e, silent, o) end, hurtPlayer = hurtPlayer, warn = warn, sound = sound, rnd = rnd, rr = rr, vr = vr,
    addDecal = addDecal, edgePoint = edgePoint, nearest = nearest, onScreen = onScreen, visible = visible, chain = chain, explode = explode,
    areaPush = function(a) R.areas[#R.areas + 1] = a end, addRelic = addRelic, legendFx = function() legendFx() end,
    R = function() return R end, View = function() return VW, VH end, RED = RED, YELLOW = YELLOW, ORANGE = ORANGE, ICEW = ICEW }

if DisasterZoneBoot and DisasterZoneBoot.Run("Games/HoldTheLine/NaxxBoss.lua", ...) then return end -- DisasterZone Games/HoldTheLine/NaxxBoss.lua
-- Naxxramas in a run: the bosses' turns (E.BOSSFN), their entrances (E.ONSPAWN), the dead's tricks (E.MOBTICK), what a
-- death sets off (E.ONKILL) and each stage's floor (E.STAGEFN: webs and egg sacs, plague clouds, rider lanes, slime
-- pools, the Chill and its braziers). Everything acts on the run being stepped, through the engine's tools (E.I).
-- The mockup's scenes (dev/art/casc/survivors_mockup/naxx/site/scenes.js) are what these look like.
local _, ns = ...

local D, E = ns.HTLData, ns.HTL
local MOBS = D.MOBS
local floor, min, max, abs, sqrt, sin, cos, atan2, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos, math.atan2 or math.atan, math.pi
local TAU = pi * 2
local random = math.random
local I = E.I

local function vr(a, b) return a + (b - a) * random() end
local function hyp(x, y) return sqrt(x * x + y * y) end
local function c(r, g, b) return { r / 255, g / 255, b / 255 } end
local GREEN, PURPLE, RED, FROST, GOLD, FIRE, WHITE = c(140, 255, 110), c(190, 110, 255), c(255, 70, 50), c(170, 225, 255), c(255, 214, 120), c(255, 150, 60), { 1, 1, 1 }
local SHADOW, FISS, STORM = c(170, 80, 255), c(240, 50, 100), c(120, 170, 255)

---------------------------------------------------------------------------
-- small tools
---------------------------------------------------------------------------
local function Rn() return I.R() end
-- a cooldown on e: true (and reset to every) when it runs out; first = the first wait
local function ready(e, k, dt, every, first)
    e.cds = e.cds or {}
    local v = (e.cds[k] or first or every) - dt
    if v <= 0 then e.cds[k] = every return true end
    e.cds[k] = v
    return false
end
-- a cast: the boss stands still, the HUD shows its bar; done(e) runs at the end (unless interrupted)
local function cast(e, name, dur, done)
    e.cast, e.castName, e.castDur, e.castT, e.onCast, e.castDmg = dur, name, dur, 0, done, 0
    e.atkT = min(1.2, dur)
end
-- the boss's own turn: true while it is casting (its cast counts down here)
local function busy(e, dt)
    if not e.cast then return false end
    e.cast = e.cast - dt
    e.castT = (e.castT or 0) + dt
    if e.cast <= 0 then
        e.cast = nil
        local cb = e.onCast
        e.onCast = nil
        if cb and not e.dead then cb(e) end
    end
    return true
end
local function tele(t) local R = Rn() t.enemy = true t.t0 = t.t R.tele[#R.tele + 1] = t return t end
local function haz(h) local R = Rn() h.t = 0 h.acc = 0 R.haz[#R.haz + 1] = h return h end
local function beam(x, y, h, w, col, dur) local R = Rn() R.beams = R.beams or {} R.beams[#R.beams + 1] = { x = x, y = y, h = h, w = w, col = col, dur = dur, t = 0 } end
local function text(x, y, s, col, life) local R = Rn() R.texts[#R.texts + 1] = { x = x, y = y, vx = 0, vy = -40, v = s, t = 0, life = life or 1.2, col = col or WHITE } end
local function src(k, tag) return { M = MOBS[k] or { name = k }, tag = tag } end
local function alive(k) for _, e in ipairs(Rn().en) do if e.type == k and not e.dead then return e end end end
local function inCircle(x, y, cx, cy, r) return hyp(x - cx, (y - cy) * 1.3) < r end
local function boom(x, y, size, col, o)          -- a layered burst (the mockup's explode, lighter for the client)
    o = o or {}
    local z = o.z or 14
    I.flash("shine", x, y, size * 1.0, o.core or WHITE, 0.2, { z = z, a = 0.8, light = size * 2.4 })
    I.flash(o.img or "starburst", x, y, size * 1.15, col, 0.4, { z = z, vr = 2 })
    I.flash("glow_dot", x, y, size * 1.5, col, 0.45, { z = z, a = 0.6 })
    I.ring("nova_ring", x, y, size * 0.15, size * 1.3, 0.5, col, 1)
    I.sparks(x, y, o.n or floor(size / 8), col, { s = 10, v0 = size * 1.2, v1 = size * 3.6, z = z, up0 = 60, up1 = size * 2.4, light = 24 })
    if o.smoke ~= false then I.puff(x, y, 4, o.dark or { 0.2, 0.2, 0.2 }, { s0 = size * 0.3, s1 = size * 0.9, spread = size / 45, a = 0.5 }) end
    if o.shake ~= false then I.shake(min(0.9, size / 260)) end
end

---------------------------------------------------------------------------
-- the dead's tricks
---------------------------------------------------------------------------
function E.MOBTICK(e, dt, d)
    local R, M, p = Rn(), e.M, Rn().p
    if e.ally then return end
    local close = d < M.r + 13
    if M.leap and d < 140 and d > 50 and ready(e, "leap", dt, 4, 1 + random() * 2) then
        e.kb, e.kx, e.ky = 100, (p.x - e.x) / d, (p.y - e.y) / d
        I.puff(e.x, e.y, 2, { 0.35, 0.3, 0.2 }, { a = 0.4, s0 = 10, s1 = 30 })
    end
    if M.spits and d < 320 and ready(e, "spit", dt, 6, 2 + random() * 3) then
        local tx, ty = p.x, p.y
        I.emit({ img = M.spits == "web" and "webspin" or "green_glow", x = e.x, y = e.y - 20, vx = (tx - e.x) / 0.6, vy = (ty - e.y) / 0.6, life = 0.6, s0 = 18, s1 = 24, a0 = 1, a1 = 1, rot = "rnd", vr = 4, add = M.spits ~= "web" })
        tele({ shape = "circle", x = tx, y = ty, r = 44, t = 0.6, col = M.spits == "web" and { 0.85, 0.85, 0.9 } or GREEN, onEnd = function(t)
            if M.spits == "web" then
                haz({ x = t.x, y = t.y, r = 50, dur = 6, dmg = 0, slow = 0.55, look = "web", safe = true })
            else
                haz({ x = t.x, y = t.y, r = 46, dur = 5, dmg = 3, every = 0.6, slow = 0.7, look = "slime", src = src("n_belcher") })
                for _ = 1, 2 do I.spawn("n_slime", t.x + vr(-20, 20), t.y + vr(-14, 14)) end
            end
        end })
    end
    if M.venom and close and ready(e, "venom", dt, 1, 0) then
        p.venom, p.venomT = min(5, (p.venom or 0) + 1), 6
    end
    if M.caster == "fire" and d < 380 and ready(e, "cast", dt, 5, 1 + random() * 4) then
        local a = atan2(p.y - 18 - (e.y - 30), p.x - e.x)
        R.eproj[#R.eproj + 1] = { x = e.x, y = e.y - 30, vx = cos(a) * 200, vy = sin(a) * 200, dmg = 8, life = 3, img = "fire_core", tint = FIRE, glow = FIRE, src = src(e.type) }
    end
    if M.caster == "storm" and d < 260 and ready(e, "cast", dt, 6, 2 + random() * 3) then
        R.arcs[#R.arcs + 1] = { x0 = e.x, y0 = e.y - 30, x1 = p.x, y1 = p.y - 22, t = 0, life = 0.3, storm = true }
        I.flash("lightning_hit", p.x, p.y - 20, 60, nil, 0.25, { light = 90 })
        I.hurtPlayer(8, src(e.type)) I.sound("lightning", 0.2, 0.5)
    end
    if M.charger and d > 120 and d < 320 and ready(e, "charge", dt, 7, 2 + random() * 4) then
        e.kb, e.kx, e.ky = 150, (p.x - e.x) / d, (p.y - e.y) / d
        e.silencer = 1.2
    end
    if e.silencer then e.silencer = e.silencer - dt if close then p.silenceT = 2 e.silencer = nil text(p.x, p.y - 60, "Silenced", c(200, 160, 255)) elseif e.silencer <= 0 then e.silencer = nil end end
    if M.trample and d < 220 and ready(e, "trample", dt, 6, 3) then
        tele({ shape = "circle", x = p.x, y = p.y, r = 70, t = 0.9, onEnd = function(t)
            e.x, e.y = t.x, t.y
            boom(t.x, t.y, 90, GREEN, { img = "red_burst", dark = { 0.25, 0.3, 0.15 } })
            if inCircle(p.x, p.y, t.x, t.y, 70) then
                I.hurtPlayer(18, src(e.type))
                local a = atan2(p.y - t.y, p.x - t.x)
                p.pull = { x0 = p.x, y0 = p.y, x1 = p.x + cos(a) * 110, y1 = p.y + sin(a) * 80, t = 0, dur = 0.35 }
            end
        end })
    end
    if M.stoneskin then
        if e.stoned then
            e.stoned = e.stoned - dt
            e.hp = min(e.maxHp, e.hp + e.maxHp * 0.12 * dt)
            if e.stoned <= 0 then e.stoned, e.immune, e.tint = nil, nil, nil end
        elseif e.hp < e.maxHp * 0.3 and not e.stonedOnce then
            e.stoned, e.stonedOnce, e.immune, e.root, e.tint = 3, true, true, nil, { 0.6, 0.6, 0.65 }
            I.flash("ring_soft", e.x, e.y - 16, 60, { 0.8, 0.8, 0.8 }, 0.4)
        end
        e.root = e.stoned and true or nil
    end
    if M.crush and close and ready(e, "crush", dt, 2, 0) then p.chill = max(p.chill, 3) end
    if M.blinker and d > 150 and ready(e, "blink", dt, 8, 3 + random() * 4) then
        I.flash("shadow_glyph", e.x, e.y - 30, 70, nil, 0.4)
        local a = random() * TAU
        e.x, e.y = p.x + cos(a) * 90, p.y + sin(a) * 60
        I.flash("shadow_glyph", e.x, e.y - 30, 70, nil, 0.4)
        tele({ shape = "circle", x = p.x, y = p.y, r = 60, t = 1.1, col = FIRE, onEnd = function(t)
            boom(t.x, t.y, 80, FIRE, { img = "fire_core", dark = { 0.2, 0.12, 0.08 }, shake = false })
            haz({ x = t.x, y = t.y, r = 50, dur = 3, dmg = 4, every = 0.5, look = "fire", src = src(e.type) })
            if inCircle(p.x, p.y, t.x, t.y, 60) then I.hurtPlayer(14, src(e.type)) end
        end })
    end
    if M.aura and d < 100 then
        R.auraAcc = (R.auraAcc or 0) + dt
        if R.auraAcc > 0.5 then R.auraAcc = 0 I.hurtPlayer(3, src(e.type)) end
        if random() < dt * 6 then I.emit({ img = "smoke_sheet", cell = floor(random() * 40), tint = { 0.4, 0.6, 0.25 }, add = false, x = e.x + vr(-60, 60), y = e.y + vr(-30, 30), z = 6, vz = 14, life = 1.4, s0 = 30, s1 = 60, a0 = 0.35, a1 = 0, rot = "rnd" }) end
    end
    if M.healer and ready(e, "heal", dt, 4, 1 + random() * 2) then      -- (patches up to three of the dead nearby)
        local n = 0
        for _, o in ipairs(R.en) do
            if n < 3 and o ~= e and not o.dead and not o.M.boss and not o.M.healer and o.hp < o.maxHp * 0.8 and hyp(o.x - e.x, o.y - e.y) < 140 then
                n = n + 1
                o.hp = min(o.maxHp, o.hp + o.maxHp * 0.15)
                I.flash("green_glow", o.x, o.y - 20, 40, nil, 0.35)
            end
        end
        I.flash("holy_star", e.x, e.y - 30, 50, GREEN, 0.3)
    end
    if M.bursts and close then
        boom(e.x, e.y, 60, FROST, { img = "ice_burst", shake = false, smoke = false, n = 6 })
        I.hurtPlayer(10, src(e.type))
        I.kill(e, false)
    end
    if M.wound and close and ready(e, "wound", dt, 1, 0) then p.noHeal = max(p.noHeal or 0, 2) end
    if M.wail and d < 150 and ready(e, "wail", dt, 7, 2 + random() * 3) then
        I.ring("ring_soft", e.x, e.y, 10, 160, 0.4, { 0.7, 0.8, 1 }, 0.8)
        local a = atan2(p.y - e.y, p.x - e.x)
        p.pull = { x0 = p.x, y0 = p.y, x1 = p.x + cos(a) * 90, y1 = p.y + sin(a) * 60, t = 0, dur = 0.3 }
    end
    -- led by someone (Faerlina's worshippers, the chow to Gluth, Gothik's ghosts): moved here, not by the engine
    if e.lead then
        local L = e.lead
        if L.dead then e.lead, e.root = nil, nil
        else
            local gx, gy = L.x + cos(R.t * 0.5 + (e.leadA or 0)) * (e.leadR or 90), L.y + sin(R.t * 0.5 + (e.leadA or 0)) * (e.leadR or 90) * 0.6
            local dx, dy = gx - e.x, gy - e.y
            local dd = max(1, hyp(dx, dy))
            if dd > 3 then e.x, e.y = e.x + dx / dd * min(dd, 70 * dt), e.y + dy / dd * min(dd, 70 * dt) e.dir = E.dirOf(dx, dy) e.anim = e.anim + dt * 8 end
        end
    end
    if e.toGluth then
        local G = e.toGluth
        if G.dead then e.toGluth, e.root = nil, nil
        else
            local dx, dy = G.x - e.x, G.y - e.y
            local dd = max(1, hyp(dx, dy))
            e.x, e.y = e.x + dx / dd * 52 * dt, e.y + dy / dd * 52 * dt
            e.dir, e.anim = E.dirOf(dx, dy), e.anim + dt * 8
            if dd < G.M.r + 14 then
                I.kill(e, true)
                G.hp = min(G.maxHp, G.hp + G.maxHp * 0.03)
                G.atkT = 0.6
                R.nx.ate = true
                text(G.x, G.y - 120, "+3%", GREEN)
                I.flash("green_glow", G.x, G.y - 60, 100, nil, 0.4, { light = 120 })
            end
        end
    end
end

---------------------------------------------------------------------------
-- the Arachnid Quarter
---------------------------------------------------------------------------
local function spikesAlong(x0, y0, a, len, owner)
    local R, p = Rn(), Rn().p
    for i = 1, floor(len / 38) do
        local x, y = x0 + cos(a) * i * 38, y0 + sin(a) * i * 38
        I.emit({ img = "spikes", tint = { 0.95, 0.9, 0.8 }, x = x, y = y - 22, life = 0.55, s0 = 26, s1 = 40, sx = 0.6, sy = 1.8, a0 = 1, a1 = 0, add = false, fi = 0.05 + i * 0.004 })
        I.emit({ img = "bone", x = x, y = y, z = 4, vx = vr(-40, 40), vy = vr(-20, 20), vz = vr(200, 340), g = 900, life = 0.7, s0 = vr(12, 20), s1 = 14, a0 = 1, a1 = 0.8, add = false, rot = "rnd", vr = vr(-9, 9), bounce = 0.25 })
        if i % 2 == 0 then I.puff(x, y, 1, { 0.5, 0.45, 0.38 }, { a = 0.5, s0 = 16, s1 = 44 }) end
        for _, e in ipairs(R.en) do if not e.dead and not e.M.boss and hyp(e.x - x, e.y - y) < 26 then I.hurt(e, 200, { dot = true }) end end
    end
    local lx, ly = cos(a) * len, sin(a) * len
    local k = max(0, min(1, ((p.x - x0) * lx + (p.y - y0) * ly) / (len * len)))
    if hyp(p.x - (x0 + lx * k), p.y - (y0 + ly * k)) < 26 then I.hurtPlayer(26, src(owner)) end
    I.shake(0.4) I.sound("meteor", 0.3, 0.6)
end

E.BOSSFN.n_anub = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if e.swarmT then
        e.swarmT = e.swarmT - dt
        e.spdMul = 0.6
        R.swAcc = (R.swAcc or 0) + dt
        if R.swAcc > 0.5 then
            R.swAcc = 0
            if d < 140 then I.hurtPlayer(6, src("n_anub")) R.pSlowN = min(R.pSlowN, 0.7) end
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and hyp(o.x - e.x, o.y - e.y) < 140 then I.hurt(o, 15, { dot = true }) end end
        end
        for _ = 1, 3 do
            local a, r = random() * TAU, vr(20, 140)
            I.emit({ img = random() < 0.5 and "insect_a" or "insect_b", tint = { 0.3, 0.24, 0.12 }, follow = e, fx = cos(a) * r, fy = sin(a) * r * 0.55 - vr(10, 80), life = 0.4, s0 = vr(10, 16), s1 = 12, a0 = 1, a1 = 0, add = false, rot = "rnd" })
        end
        if random() < dt * 8 then I.emit({ img = "swarm_cloud", tint = { 0.15, 0.12, 0.06 }, follow = e, fx = vr(-90, 90), fy = vr(-70, 10), life = 0.8, s0 = 90, s1 = 120, a0 = 0.5, a1 = 0, add = false, rot = "rnd" }) end
        if e.swarmT <= 0 then e.swarmT, e.spdMul = nil, nil end
    end
    if busy(e, dt) then return end
    if ready(e, "impale", dt, 12, 4) then
        cast(e, "Impale", 1.0, function(b)
            local a0 = atan2(p.y - b.y, p.x - b.x)
            for k = -1, 1 do
                local a = a0 + k * 0.22
                tele({ shape = "line", x = b.x, y = b.y, x2 = b.x + cos(a) * 700, y2 = b.y + sin(a) * 700, w = 40, t = 0.9, col = c(255, 90, 40), onEnd = function(t) spikesAlong(t.x, t.y, a, 700, "n_anub") end })
            end
        end)
    elseif ready(e, "swarm", dt, 40, 20) then
        I.warn("Anub'Rekhan begins to channel Locust Swarm!", I.ORANGE)
        cast(e, "Locust Swarm", 1.5, function(b)
            b.swarmT = 16
            for _ = 1, 2 do local a = random() * TAU local g = I.spawn("n_cryptguard", b.x + cos(a) * 120, b.y + sin(a) * 80) g.spawnT = 0 I.puff(g.x, g.y, 6, { 0.35, 0.3, 0.2 }, { a = 0.6, s0 = 20, s1 = 60 }) end
        end)
    end
end

E.ONSPAWN.n_faerlina = function()
    local R = Rn()
    local x, y = I.edgePoint(40)
    local f = I.spawn("n_faerlina", x, y)
    local out = { f }
    for i = 0, 3 do
        local w = I.spawn("n_worshipper", x + cos(i * 1.57) * 90, y + sin(i * 1.57) * 54)
        w.lead, w.leadA, w.leadR, w.root, w.worship = f, i * 1.57, 95, true, true
        out[#out + 1] = w
    end
    return out
end
E.BOSSFN.n_faerlina = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if e.silenced then e.silenced = e.silenced - dt if e.silenced <= 0 then e.silenced = nil end end
    if e.enraged and random() < dt * 14 then
        local a = random() * TAU
        I.emit({ img = "flames", cell = floor(random() * 16), cells = 4, x = e.x + cos(a) * 30, y = e.y + sin(a) * 14, vz = 60, life = 0.6, s0 = 30, s1 = 40, a0 = 0.9, a1 = 0, light = 50 })
    end
    if ready(e, "enrage", dt, 60, 45) and not e.enraged then
        e.enraged, e.dmgMul, e.spdMul, e.tint = true, 1.5, 1.3, { 1, 0.55, 0.45 }
        I.warn("Grand Widow Faerlina goes into a frenzy!", I.RED)
    end
    if busy(e, dt) or e.silenced then return end
    if ready(e, "volley", dt, 9, 3) then
        cast(e, "Poison Bolt Volley", 0.6, function(b)
            local a0 = atan2(p.y - b.y, p.x - b.x)
            for k = 0, 5 do
                local a = a0 + (k - 2.5) * 0.15
                R.eproj[#R.eproj + 1] = { x = b.x, y = b.y - 40, vx = cos(a) * 240, vy = sin(a) * 240, dmg = 10, life = 3, img = "green_glow", tint = GREEN, glow = GREEN, src = src("n_faerlina") }
            end
        end)
    elseif ready(e, "rain", dt, 11, 6) then
        cast(e, "Rain of Fire", 0.8, function()
            for k = 1, 3 do
                local x, y = p.x + vr(-90, 90), p.y + vr(-60, 60)
                tele({ shape = "circle", x = x, y = y, r = 60, t = 1.2, col = FIRE, onEnd = function(t)
                    I.emit({ img = "fire_core", tint = FIRE, x = t.x + 100, y = t.y, z = 300, vx = -100 / 0.3, vz = -300 / 0.3, life = 0.3, s0 = 40, s1 = 40, a0 = 1, a1 = 1, light = 200 })
                    boom(t.x, t.y, 100, FIRE, { img = "meteor_fire", dark = { 0.2, 0.1, 0.05 } })
                    haz({ x = t.x, y = t.y, r = 55, dur = 4, dmg = 6, every = 0.5, look = "fire", src = src("n_faerlina") })
                    if inCircle(p.x, p.y, t.x, t.y, 60) then I.hurtPlayer(16, src("n_faerlina")) end
                    I.sound("fireimpact", 0.1)
                end })
            end
        end)
    end
end

E.BOSSFN.n_maexxna = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if e.sprayT then
        e.sprayT = e.sprayT - dt
        if e.sprayT <= 0 then
            e.sprayT = nil
            for k = 0, 7 do local a = k / 8 * TAU I.spawn("n_spider", p.x + cos(a) * 160, p.y + sin(a) * 110) end
            I.flash("green_glow", p.x, p.y - 20, 160, nil, 0.4)
        end
    end
    if not e.frenzy and e.hp < e.maxHp * 0.3 then e.frenzy, e.spdMul, e.dmgMul = true, 1.3, 1.5 I.warn("Maexxna goes into a frenzy!", I.RED) end
    if d < e.M.r + 16 and ready(e, "bite", dt, 2, 0) then p.noHeal = max(p.noHeal or 0, 10) text(p.x, p.y - 60, "Necrotic Poison", GREEN) end
    if busy(e, dt) then return end
    if ready(e, "wrap", dt, 25, 8) then
        cast(e, "Web Wrap", 0.6, function(b)
            local a = random() * TAU
            I.emit({ img = "webspin", x = b.x, y = b.y - 40, vx = (p.x - b.x) / 0.35, vy = (p.y - b.y) / 0.35, life = 0.35, s0 = 24, s1 = 40, a0 = 1, a1 = 1, add = false, rot = "rnd", vr = 4 })
            p.pull = { x0 = p.x, y0 = p.y, x1 = p.x + cos(a) * 280, y1 = p.y + sin(a) * 190, t = 0, dur = 0.5 }
            p.wrapT, p.stunT = 2.4, 2.4
            I.warn("Maexxna wraps you in her web!", { 0.92, 0.92, 1 })
        end)
    elseif ready(e, "spray", dt, 40, 18) then
        I.warn("Maexxna sprays her web!", { 0.92, 0.92, 1 })
        I.ring("web", e.x, e.y, 20, 700, 0.75, { 0.95, 0.95, 1 }, 0.9, { rot = 0 })
        I.ring("ring_soft", e.x, e.y, 20, 700, 0.6, WHITE, 0.6)
        p.stunT, p.wrapT = 2, 2
        for _, o in ipairs(R.en) do if not o.dead and not o.M.boss then o.stun = max(o.stun, 2) end end
        e.sprayT = 2
        I.shake(0.3)
    elseif d < 220 and ready(e, "shock", dt, 9, 5) then
        local a = atan2(p.y - e.y, p.x - e.x)
        tele({ shape = "cone", x = e.x, y = e.y, r = 180, ang = a, spread = 0.4, t = 0.8, col = GREEN, onEnd = function(t)
            for _ = 1, 30 do local aa = t.ang + vr(-0.4, 0.4) local sp = vr(200, 420) I.emit({ img = "green_drops", x = t.x, y = t.y, z = 40, vx = cos(aa) * sp, vy = sin(aa) * sp * 0.77, vz = vr(-20, 80), g = 300, life = 0.5, s0 = 18, s1 = 10, a0 = 1, a1 = 0.3, stretch = 0.6 }) end
            local dx, dy = p.x - t.x, (p.y - t.y) * 1.3
            if hyp(dx, dy) < t.r and abs((atan2(dy, dx) - t.ang + pi) % TAU - pi) < t.spread then I.hurtPlayer(18, src("n_maexxna")) end
        end })
    end
end

---------------------------------------------------------------------------
-- the Plague Quarter
---------------------------------------------------------------------------
E.BOSSFN.n_noth = function(e, dt, d)
    local R, p = Rn(), Rn().p
    local cu = R.curse
    if cu then
        cu.t = cu.t - dt
        if cu.got >= cu.need then
            R.curse = nil
            R.nx.cursesBroken = (R.nx.cursesBroken or 0) + 1
            boom(p.x, p.y - 60, 110, GOLD, { img = "holy_star", smoke = false, shake = false })
            text(p.x, p.y - 90, "Curse lifted", GOLD)
        elseif cu.t <= 0 then
            R.curse = nil
            R.nx.curseBurst = true
            boom(p.x, p.y, 180, SHADOW, { img = "purple_star", dark = { 0.15, 0.05, 0.2 } })
            I.ring("shadow_ring", p.x, p.y, 10, 180, 0.6, nil, 1)
            I.hurtPlayer(40, src("n_noth"))
        end
    end
    if e.away then
        e.away = e.away - dt
        if ready(e, "wave", dt, 8, 0.5) then
            for _ = 1, 8 do local x, y = I.edgePoint(30) I.spawn(random() < 0.7 and "n_infghoul" or "n_necroknight", x, y) end
        end
        if e.away <= 0 then
            e.away, e.immune, e.alpha, e.root = nil, nil, nil, nil
            local a = random() * TAU
            e.x, e.y = p.x + cos(a) * 160, p.y + sin(a) * 110
            I.flash("tele_star", e.x, e.y - 40, 130, PURPLE, 0.45, { light = 160 })
            I.warn("Noth returns from the balcony!", I.ORANGE)
        end
        return
    end
    if (e.hp < e.maxHp * 0.7 and not e.away1) or (e.hp < e.maxHp * 0.4 and not e.away2) then
        if e.hp < e.maxHp * 0.4 then e.away2 = true else e.away1 = true end
        e.away, e.immune, e.alpha, e.root = 25, true, 0.2, true
        I.flash("tele_star", e.x, e.y - 40, 130, PURPLE, 0.45)
        I.warn("Noth teleports to the balcony! His warriors rush in!", I.ORANGE)
        return
    end
    if busy(e, dt) then return end
    if ready(e, "blink", dt, 14, 6) then
        I.flash("tele_star", e.x, e.y - 40, 120, PURPLE, 0.45, { light = 140 })
        I.ring("shadow_glyph2", e.x, e.y, 10, 60, 0.6, nil, 0.9, { vr = 3 })
        local a = random() * TAU
        e.x, e.y = p.x + cos(a) * 80, p.y + sin(a) * 55
        I.flash("tele_star", e.x, e.y - 40, 120, PURPLE, 0.45, { light = 140 })
        I.ring("shadow_glyph2", e.x, e.y, 60, 10, 0.6, nil, 0.9, { vr = -3 })
    elseif not R.curse and ready(e, "curse", dt, 20, 3) then
        cast(e, "Curse of the Plaguebringer", 0.8, function()
            R.curse = { t = 10, need = 25, got = 0 }
            I.warn("Curse of the Plaguebringer: slay 25 in 10 seconds!", c(220, 160, 255))
        end)
    end
end

-- Heigan's dance: four bands across his arena erupt in turn
local function erupt(R, x0, w, y0, h, owner)
    local p = R.p
    for k = 0, 7 do
        local x, y = x0 + 20 + random() * (w - 40), y0 + random() * h
        I.emit({ img = "green_glow", x = x, y = y - 50, life = 0.6, s0 = 60, s1 = 70, sx = 0.6, sy = 2.2, a0 = 0.9, a1 = 0, light = 140 })
        I.flash("starburst", x, y, 90, GREEN, 0.35, { flat = true })
        for _ = 1, 5 do I.emit({ img = "green_drops", x = x, y = y, z = 10, vx = vr(-80, 80), vy = vr(-40, 40), vz = vr(260, 460), g = 1000, life = 0.9, s0 = 14, s1 = 7, a0 = 1, a1 = 0.3, bounce = 0.1, rot = "rnd" }) end
        I.emit({ img = "poison_sheet", cell = 8 + floor(random() * 16), tint = { 0.55, 0.85, 0.35 }, add = false, x = x, y = y, z = 26, vz = 24, life = 1.2, s0 = 60, s1 = 100, a0 = 0.5, a1 = 0, rot = "rnd" })
    end
    if p.x > x0 and p.x < x0 + w and p.y > y0 - 30 and p.y < y0 + h + 30 then I.hurtPlayer(30, src(owner, "erupted")) end
    for _, e in ipairs(R.en) do if not e.dead and not e.M.boss and e.x > x0 and e.x < x0 + w and e.y > y0 - 30 and e.y < y0 + h + 30 then I.hurt(e, 250, { dot = true, kb = 60, fx = e.x, fy = e.y + 10 }) end end
    I.shake(0.25) I.sound("fireimpact2", 0.15, 0.5)
end
local function danceStep(R, cx, cy, i, every)
    local bw = 160
    local band = i % 4
    local order = { 0, 1, 2, 3, 2, 1 }
    band = order[(i % 6) + 1]
    local x0 = cx - 2 * bw + band * bw
    tele({ shape = "band", x = x0, y = cy - 260, w = bw, h = 520, t = every * 0.75, col = GREEN, onEnd = function() erupt(R, x0, bw, cy - 260, 520, "n_heigan") end })
end
E.BOSSFN.n_heigan = function(e, dt, d)
    local R, p = Rn(), Rn().p
    e.cx, e.cy = e.cx or p.x, e.cy or p.y
    e.phT = (e.phT or 0) + dt
    local fast = e.phT % 90 >= 45
    if fast ~= e.fast then
        e.fast = fast
        e.immune, e.root = fast or nil, fast or nil
        e.alpha = fast and 0.5 or nil
        if fast then I.warn("Heigan the Unclean teleports and begins to channel!", GREEN) e.x, e.y = e.cx, e.cy - 300 end
    end
    local every = fast and 1.1 or 2.4
    if ready(e, "dance", dt, every, 1) then e.step = (e.step or 0) + 1 danceStep(R, e.cx, e.cy, e.step, every) end
    R.disrupt = d < 130 and not fast
    if fast and random() < dt * 10 then I.emit({ img = "smoke_sheet", cell = floor(random() * 40), tint = { 0.4, 0.7, 0.25 }, add = false, x = p.x + vr(-400, 400), y = p.y + vr(-260, 260), z = 10, vz = 10, life = 2, s0 = 80, s1 = 160, a0 = 0.25, a1 = 0, rot = "rnd" }) end
end

E.ONSPAWN.n_loatheb = function()
    local p = Rn().p
    local e = I.spawn("n_loatheb", p.x, p.y - 220)
    e.root = true
    return { e }
end
E.BOSSFN.n_loatheb = function(e, dt, d)
    local R, p = Rn(), Rn().p
    e.fightT = (e.fightT or 0) + dt
    R.healLock = (e.fightT % 20) >= 5                     -- Corrupted Mind: healing only in a 5 s window of every 20
    if d < 170 then R.lAcc = (R.lAcc or 0) + dt if R.lAcc > 1 then R.lAcc = 0 I.hurtPlayer(3, src("n_loatheb")) end end
    if random() < dt * 4 then I.ring("poison_ring", e.x, e.y, 60, 170, 1.2, nil, 0.5) end
    if R.doomT then
        R.doomT = R.doomT - dt
        if R.doomT <= 0 then
            R.doomT = nil
            R.doomN = (R.doomN or 0) + 1
            boom(p.x, p.y, 160, SHADOW, { img = "purple_star", dark = { 0.12, 0.04, 0.18 } })
            I.ring("shadow_ring2", p.x, p.y, 10, 170, 0.7, nil, 1)
            I.hurtPlayer(16 + 6 * R.doomN, src("n_loatheb"))
        end
    end
    if ready(e, "doom", dt, e.fightT > 300 and 15 or 30, 6) then R.doomT = 10 I.warn("Inevitable Doom!", PURPLE) end
    if ready(e, "spore", dt, 12, 4) then
        local a = random() * TAU
        local s = I.spawn("n_spore", e.x + cos(a) * vr(150, 260), e.y + 120 + sin(a) * vr(60, 140))
        s.root, s.noTouch = true, true
    end
end

---------------------------------------------------------------------------
-- the Military Quarter
---------------------------------------------------------------------------
E.ONSPAWN.n_razuvious = function()
    local p = Rn().p
    local x, y = p.x + 260, p.y - 120
    local b = I.spawn("n_razuvious", x, y)
    local out = { b }
    for _, o in ipairs({ { -180, 120 }, { 180, 120 }, { -280, -10 }, { 280, -10 } }) do
        local u = I.spawn("n_understudy", x + o[1], y + o[2] + 60)
        u.root, u.barrier, u.noTouch = true, true, true
        u.hp, u.maxHp = 900, 900
        out[#out + 1] = u
    end
    return out
end
E.BOSSFN.n_razuvious = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if busy(e, dt) then return end
    if ready(e, "shout", dt, 25, 8) then
        I.warn("Instructor Razuvious draws breath...", GOLD)
        tele({ shape = "ringwarn", x = e.x, y = e.y, r = 900, t = 2, col = GOLD })
        cast(e, "Disrupting Shout", 2, function(b)
            boom(b.x, b.y, 200, { 1, 0.9, 0.7 }, { img = "starburst", dark = { 0.45, 0.4, 0.32 } })
            I.ring("ring_smoke", b.x, b.y, 20, 800, 0.8, { 1, 0.92, 0.8 }, 1)
            I.ring("ring_soft", b.x, b.y, 20, 900, 0.5, WHITE, 0.8)
            local safe = false
            for _, u in ipairs(R.en) do if u.barrier and not u.dead and hyp(p.x - u.x, p.y - u.y) < 70 then safe = u end end
            if safe then text(p.x, p.y - 70, "Absorbed", c(200, 230, 255)) I.flash("ring_soft", safe.x, safe.y - 30, 120, c(180, 220, 255), 0.4)
            else I.hurtPlayer(55, src("n_razuvious", "shouted")) end
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and not o.barrier and hyp(o.x - b.x, o.y - b.y) < 700 then I.hurt(o, 400, { dot = true, kb = 90, fx = b.x, fy = b.y }) end end
            I.flash("shine", b.x, b.y - 40, 300, WHITE, 0.3)
            I.sound("bosswarn", 0.5)
        end)
    elseif d < 70 and ready(e, "strike", dt, 6, 2) then
        I.hurtPlayer(20, src("n_razuvious"))
        local a = atan2(p.y - e.y, p.x - e.x)
        p.pull = { x0 = p.x, y0 = p.y, x1 = p.x + cos(a) * 100, y1 = p.y + sin(a) * 70, t = 0, dur = 0.3 }
        I.flash("red_burst", p.x, p.y - 26, 70, nil, 0.25)
    end
end

E.ONSPAWN.n_gothik = function()
    local R, p = Rn(), Rn().p
    R.gateX = p.x + 240
    R.gateOpen = false
    R.gateT = R.t + 120
    local g = I.spawn("n_gothik", R.gateX + 200, p.y - 160)
    g.root, g.immune = true, true
    return { g }
end
E.BOSSFN.n_gothik = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if not R.gateOpen then
        if p.x > R.gateX - 14 then p.x = R.gateX - 14 end           -- the gate: you cannot cross
        if ready(e, "harvest", dt, 8, 1) then
            for _ = 1, 6 do local x, y = I.edgePoint(30) if x > R.gateX then x = R.gateX - 400 - random() * 200 end I.spawn(random() < 0.7 and "n_trainee" or "n_necroknight", x, y) end
        end
        if R.t >= R.gateT then
            R.gateOpen = true
            I.warn("The gate opens!", GREEN)
            boom(R.gateX, p.y, 200, SHADOW, { img = "purple_star", dark = { 0.15, 0.05, 0.2 } })
            for _, o in ipairs(R.en) do if o.ghostOf then o.root = nil end end
            e.root, e.immune = nil, nil
            local a = random() * TAU
            e.x, e.y = p.x + cos(a) * 200, p.y + sin(a) * 140
            I.flash("tele_star", e.x, e.y - 40, 130, PURPLE, 0.45)
        end
        return
    end
    if busy(e, dt) then return end
    if ready(e, "reap", dt, 15, 6) then
        cast(e, "Harvest Soul", 0.6, function()
            R.dmgMul = max(0.5, (R.dmgMul or 1) * 0.9)
            text(p.x, p.y - 80, "Harvest Soul  -10% damage", c(220, 180, 255))
            for _ = 1, 10 do I.emit({ img = "ghost_purple", tint = c(210, 160, 255), x = p.x, y = p.y - 30, vx = (e.x - p.x) / 0.9, vy = (e.y - p.y) / 0.9, life = 0.9, s0 = 24, s1 = 30, a0 = 1, a1 = 0, rot = "rnd", vr = 3 }) end
        end)
    elseif ready(e, "bolt", dt, 4, 2) then
        local a = atan2(p.y - 18 - (e.y - 40), p.x - e.x)
        R.eproj[#R.eproj + 1] = { x = e.x, y = e.y - 40, vx = cos(a) * 220, vy = sin(a) * 220, dmg = 10, life = 3, src = src("n_gothik") }
    end
end

-- the Four Horsemen: one in each corner; marks stack while you stand in a Horseman's reach
local HORSE = { { "n_korthazz", -300, -220, c(255, 140, 60) }, { "n_blaumeux", 300, -220, c(180, 110, 255) }, { "n_mograine", -300, 220, c(255, 80, 60) }, { "n_zeliek", 300, 220, c(255, 230, 140) } }
E.ONSPAWN.n_mograine = function()
    local R, p = Rn(), Rn().p
    local out = {}
    R.groupName, R.groupN = "The Four Horsemen", 4
    R.marks, R.horseDead = {}, {}
    for _, h in ipairs(HORSE) do
        local e = I.spawn(h[1], p.x + h[2], p.y + h[3])
        e.homeX, e.homeY, e.col = p.x + h[2], p.y + h[3], h[4]
        out[#out + 1] = e
    end
    return out
end
local function horseCommon(e, dt, d)
    local R, p = Rn(), Rn().p
    local dx, dy = e.x - e.homeX, e.y - e.homeY
    e.root = hyp(dx, dy) > 140 and d > 90 or nil         -- (they hold their corners)
    if e.root and hyp(dx, dy) > 140 then local l = hyp(dx, dy) e.x, e.y = e.x - dx / l * 40 * dt, e.y - dy / l * 40 * dt end
    local m = R.marks[e.type] or { n = 0, last = -99, acc = 0 }
    R.marks[e.type] = m
    if d < 270 then
        m.last = R.t
        m.acc = m.acc + dt
        if m.acc >= 12 then m.acc = 0 m.n = m.n + 1 text(p.x, p.y - 70, MOBS[e.type].name:match("%S+$") .. "'s mark x" .. m.n, e.col) end
    elseif R.t - m.last > 30 then m.n, m.acc = 0, 0 end
end
E.BOSSFN.n_korthazz = function(e, dt, d)
    local R, p = Rn(), Rn().p
    horseCommon(e, dt, d)
    if ready(e, "meteor", dt, 12, 4) then
        I.warn("Thane Korth'azz calls down a Meteor!", I.ORANGE)
        tele({ shape = "circle", x = p.x, y = p.y, r = 90, t = 1.4, col = FIRE, onEnd = function(t)
            I.emit({ img = "meteor_rock", x = t.x, y = t.y, z = 30, life = 0.2, s0 = 60, s1 = 70, a0 = 1, a1 = 0, add = false, rot = "rnd" })
            boom(t.x, t.y, 220, FIRE, { img = "meteor_fire", dark = { 0.25, 0.12, 0.05 }, n = 30 })
            haz({ x = t.x, y = t.y, r = 80, dur = 3, dmg = 0, look = "fire", safe = true })
            local n = 0
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and inCircle(o.x, o.y, t.x, t.y, 95) then n = n + 1 end end
            local share = 1 / (n + 1)
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and inCircle(o.x, o.y, t.x, t.y, 95) then I.hurt(o, 1800 * share, { dot = true, kb = 80, fx = t.x, fy = t.y }) end end
            if inCircle(p.x, p.y, t.x, t.y, 95) then I.hurtPlayer(max(6, 90 * share), src("n_korthazz")) text(t.x, t.y - 110, "Meteor split " .. (n + 1) .. " ways", c(255, 200, 150), 1.6) end
            I.sound("meteor")
        end })
    end
end
E.BOSSFN.n_blaumeux = function(e, dt, d)
    local p = Rn().p
    horseCommon(e, dt, d)
    if ready(e, "void", dt, 10, 3) then
        haz({ x = p.x, y = p.y, r = 64, dur = 20, dmg = 8, every = 0.5, arm = 1, look = "void", src = src("n_blaumeux"), onTick = function(h)
            if random() < 0.25 then I.emit({ img = "purple_star", tint = PURPLE, x = h.x + vr(-h.r, h.r), y = h.y + vr(-h.r, h.r) * 0.6, vz = 70, life = 0.6, s0 = 16, s1 = 4, a0 = 1, a1 = 0 }) end
        end })
    end
end
E.BOSSFN.n_mograine = function(e, dt, d)
    local R, p = Rn(), Rn().p
    horseCommon(e, dt, d)
    if random() < dt * 22 then local a = random() * TAU I.emit({ img = "flames", cell = floor(random() * 16), cells = 4, x = e.x + cos(a) * 60, y = e.y + sin(a) * 30, vz = 40, life = 0.6, s0 = 30, s1 = 40, a0 = 1, a1 = 0, light = 50 }) end
    if d < 110 then R.mAcc = (R.mAcc or 0) + dt if R.mAcc > 0.5 then R.mAcc = 0 I.hurtPlayer(5, src("n_mograine")) end end
    if d > 120 and d < 360 and ready(e, "charge", dt, 15, 6) then e.kb, e.kx, e.ky = 160, (p.x - e.x) / d, (p.y - e.y) / d I.warn("Highlord Mograine charges!", I.RED) end
end
E.BOSSFN.n_zeliek = function(e, dt, d)
    local R, p = Rn(), Rn().p
    horseCommon(e, dt, d)
    if ready(e, "wrath", dt, 9, 5) then
        local from, n = e, 0
        local near = {}
        for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and hyp(o.x - p.x, o.y - p.y) < 140 then near[#near + 1] = o end end
        for i = 1, min(2, #near) do
            local o = near[i]
            R.arcs[#R.arcs + 1] = { x0 = from.x, y0 = from.y - 40, x1 = o.x, y1 = o.y - 22, t = 0, life = 0.35 }
            I.flash("holy_star", o.x, o.y - 26, 70, GOLD, 0.3) I.hurt(o, 300, { dot = true })
            from, n = o, n + 1
        end
        R.arcs[#R.arcs + 1] = { x0 = from.x, y0 = from.y - 30, x1 = p.x, y1 = p.y - 22, t = 0, life = 0.35 }
        I.flash("holy_star", p.x, p.y - 26, 90, GOLD, 0.35, { light = 120 })
        I.hurtPlayer(14 + 8 * n, src("n_zeliek"))
        I.sound("wrath", 0.3)
    end
end

---------------------------------------------------------------------------
-- the Construct Quarter
---------------------------------------------------------------------------
E.ONSPAWN.n_patchwerk = function()
    local R, p = Rn(), Rn().p
    R.calm = true
    for _, o in ipairs(R.en) do
        if not o.dead and not o.M.boss then
            local a = atan2(o.y - p.y, o.x - p.x)
            o.fixed, o.life = { cos(a) * 160, sin(a) * 160 }, 3
        end
    end
    local x, y = I.edgePoint(20)
    local e = I.spawn("n_patchwerk", x, y)
    e.berserkAt = R.t + 120
    return { e }
end
E.BOSSFN.n_patchwerk = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if not e.frenzy and e.hp < e.maxHp * 0.05 then e.frenzy, e.spdMul, e.dmgMul = true, 1.4, 1.5 I.warn("Patchwerk goes into a frenzy!", I.RED) end
    if d < 90 and ready(e, "hateful", dt, 1.2, 0.6) then
        e.atkT = 0.6
        boom(p.x + 6, p.y, 80, RED, { img = "red_burst", smoke = false, shake = false, n = 8 })
        I.hurtPlayer(16, src("n_patchwerk"))
        text(p.x, p.y - 90, "Hateful Strike", c(255, 90, 60))
        I.shake(0.3)
    end
end

E.BOSSFN.n_grobbulus = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if ready(e, "trail", dt, 1.5, 1) then haz({ x = e.x, y = e.y, r = 50, dur = 10, dmg = 4, every = 0.5, src = src("n_grobbulus"), tint = { 0.4, 0.75, 0.25 } }) end
    if R.injT then
        R.injT = R.injT - dt
        if random() < dt * 30 then I.emit({ img = "green_glow", x = p.x + vr(-20, 20), y = p.y, z = vr(10, 60), vz = 50, life = 0.5, s0 = 30, s1 = 8, a0 = 0.9, a1 = 0, light = 60 }) end
        if R.injT <= 0 then
            R.injT = nil
            boom(p.x, p.y, 240, GREEN, { img = "green_glow", dark = { 0.2, 0.3, 0.1 }, n = 40 })
            I.ring("green_ring", p.x, p.y, 20, 240, 0.6, nil, 1)
            local n = 0
            for _, o in ipairs(R.en) do
                if not o.dead and not o.M.boss and hyp(o.x - p.x, (o.y - p.y) * 1.3) < 220 then I.hurt(o, 500, { dot = true, kb = 80, fx = p.x, fy = p.y }) if o.dead then n = n + 1 end end
            end
            R.nx.bombBest = max(R.nx.bombBest or 0, n)
            if n > 0 then text(p.x, p.y - 120, "Bomb Squad x" .. n, c(190, 255, 140), 1.6) end
            I.hurtPlayer(12, src("n_grobbulus"))
            haz({ x = p.x, y = p.y, r = 90, dur = 8, dmg = 4, every = 0.5, src = src("n_grobbulus"), tint = { 0.4, 0.75, 0.25 } })
        end
    end
    if busy(e, dt) then return end
    if not R.injT and ready(e, "inject", dt, 20, 4) then
        cast(e, "Mutating Injection", 0.6, function() R.injT = 10 I.warn("Mutating Injection! Run into the dead.", GREEN) end)
    elseif d < 260 and ready(e, "spray", dt, 15, 9) then
        local a = atan2(p.y - e.y, p.x - e.x)
        cast(e, "Slime Spray", 0.8, nil)
        tele({ shape = "cone", x = e.x, y = e.y, r = 230, ang = a, spread = 0.38, t = 0.8, col = GREEN, onEnd = function(t)
            for _ = 1, 40 do local aa = t.ang + vr(-0.38, 0.38) local sp = vr(220, 480) I.emit({ img = "green_drops", x = t.x, y = t.y, z = 70, vx = cos(aa) * sp, vy = sin(aa) * sp * 0.77, vz = vr(-30, 100), g = 400, life = 0.55, s0 = 22, s1 = 12, a0 = 1, a1 = 0.3, stretch = 0.6 }) end
            local dx, dy = p.x - t.x, (p.y - t.y) * 1.3
            if hyp(dx, dy) < t.r and abs((atan2(dy, dx) - t.ang + pi) % TAU - pi) < t.spread then I.hurtPlayer(16, src("n_grobbulus")) end
            for k = 1, 3 do local dd = 80 + k * 50 I.spawn("n_slime", t.x + cos(t.ang) * dd, t.y + sin(t.ang) * dd * 0.77) end
        end })
    end
end

E.BOSSFN.n_gluth = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if ready(e, "chow", dt, 2.4, 0.5) then
        local a = floor(random() * 3) / 3 * TAU + 0.5
        local z = I.spawn("n_chow", e.x + cos(a) * 460, e.y + sin(a) * 320)
        z.toGluth, z.root = e, true
    end
    if d < e.M.r + 16 and ready(e, "wound", dt, 1.5, 0) then p.noHeal = max(p.noHeal or 0, 3) end
    if busy(e, dt) then return end
    if ready(e, "decimate", dt, 100, 50) then
        I.warn("Gluth decimates all nearby flesh!", I.RED)
        cast(e, "Decimate", 1.2, function(b)
            boom(b.x, b.y, 220, RED, { img = "red_star", dark = { 0.25, 0.04, 0.04 } })
            I.ring("shadow_ring", b.x, b.y, 30, 900, 0.8, c(220, 30, 30), 1)
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss then o.hp = max(1, o.maxHp * 0.05) end end
            if p.hp > p.maxHp * 0.3 then p.hp = p.maxHp * 0.3 end
            text(p.x, p.y - 90, "Decimate", c(255, 90, 60))
        end)
    end
end

-- Thaddius: first Stalagg and Feugen (the second must fall within 15 s of the first), then polarity
E.ONSPAWN.n_stalagg = function()
    local R, p = Rn(), Rn().p
    R.groupName, R.groupN = "Stalagg and Feugen", 2
    local s = I.spawn("n_stalagg", p.x - 260, p.y - 90)
    local f = I.spawn("n_feugen", p.x + 260, p.y - 90)
    s.root, f.root = true, true
    s.twin, f.twin = f, s
    return { s, f }
end
local function twinTick(e, dt, d)
    local R, p = Rn(), Rn().p
    if ready(e, "coil", dt, 2.5, random() * 2) and not e.twin.dead then
        R.arcs[#R.arcs + 1] = { x0 = e.x, y0 = e.y - 80, x1 = e.twin.x, y1 = e.twin.y - 80, t = 0, life = 0.25, storm = true }
    end
    if d < 260 and ready(e, "zap", dt, 4, 2) then
        R.arcs[#R.arcs + 1] = { x0 = e.x, y0 = e.y - 60, x1 = p.x, y1 = p.y - 22, t = 0, life = 0.3, storm = true }
        I.hurtPlayer(10, src(e.type))
    end
    if e.reviveAt and R.t >= e.reviveAt then e.reviveAt = nil end
end
E.BOSSFN.n_stalagg = twinTick
E.BOSSFN.n_feugen = twinTick
local function shift(R)
    local p = R.p
    p.charge = random() < 0.5 and 1 or -1
    for _, o in ipairs(R.en) do if not o.dead and not o.M.boss then o.charge = random() < 0.5 and 1 or -1 end end
    I.flash("shine", p.x, p.y - 30, 160, STORM, 0.4, { light = 300 })
    text(p.x, p.y - 90, p.charge > 0 and "Positive Charge" or "Negative Charge", p.charge > 0 and c(255, 150, 120) or c(140, 190, 255), 1.6)
end
E.BOSSFN.n_thaddius = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if random() < dt * 4 then local x = e.x + vr(-60, 60) R.arcs[#R.arcs + 1] = { x0 = x, y0 = e.y - vr(80, 170), x1 = x + vr(-80, 80), y1 = e.y - vr(0, 60), t = 0, life = 0.12, storm = true } end
    if p.charge then
        for _, o in ipairs(R.en) do if not o.dead and not o.charge and not o.M.boss then o.charge = random() < 0.5 and 1 or -1 end end
        local same, opp = 0, {}
        for _, o in ipairs(R.en) do
            if o.charge and not o.dead and hyp(o.x - p.x, o.y - p.y) < 150 then
                if o.charge == p.charge then same = same + 1 else opp[#opp + 1] = o end
            end
        end
        R.dmgMul = 1 + 0.1 * min(10, same)
        R.stacks = min(10, same)
        if #opp > 0 and ready(e, "shock", dt, 1, 0) then
            local o = opp[floor(random() * #opp) + 1]
            R.arcs[#R.arcs + 1] = { x0 = o.x, y0 = o.y - 26, x1 = p.x, y1 = p.y - 22, t = 0, life = 0.25, storm = true }
            I.flash("lightning_hit", p.x, p.y - 22, 70, nil, 0.25, { light = 80 })
            I.hurtPlayer(9, src("n_thaddius", "shocked"))
        end
    end
    if d > 380 and ready(e, "ball", dt, 2, 1) then
        local a = atan2(p.y - 18 - (e.y - 80), p.x - e.x)
        R.eproj[#R.eproj + 1] = { x = e.x, y = e.y - 80, vx = cos(a) * 260, vy = sin(a) * 260, dmg = 14, life = 3, img = "lightning_hit", tint = STORM, glow = STORM, src = src("n_thaddius") }
    end
    if busy(e, dt) then return end
    if ready(e, "polarity", dt, 30, 6) then
        I.warn("Thaddius begins to cast Polarity Shift!", STORM)
        cast(e, "Polarity Shift", 2, function(b)
            for _ = 1, 8 do local x = b.x + vr(-60, 60) R.arcs[#R.arcs + 1] = { x0 = x + vr(-80, 80), y0 = b.y - 400, x1 = x, y1 = b.y - 150, t = 0, life = 0.25, storm = true } end
            boom(b.x, b.y - 100, 200, STORM, { img = "lightning_hit", smoke = false })
            shift(R)
        end)
    end
end

---------------------------------------------------------------------------
-- the Frostwyrm Lair
---------------------------------------------------------------------------
local function shadowed(R, x, y)              -- behind an ice block, as seen from Sapphiron
    local s = alive("n_sapphiron")
    if not s then return true end
    for _, b in ipairs(R.blocks or {}) do
        local ax, ay = b.x - s.x, b.y - s.y
        local l = max(1, hyp(ax, ay))
        local ux, uy = ax / l, ay / l
        local px, py = x - b.x, y - b.y
        local along = px * ux + py * uy
        local side = abs(px * uy - py * ux)
        if along > -6 and along < 180 and side < 44 + along * 0.18 then return true end
    end
    return false
end
E.BOSSFN.n_sapphiron = function(e, dt, d)
    local R, p = Rn(), Rn().p
    e.z = (e.z or 0) + ((e.fly and 70 or 0) - (e.z or 0)) * min(1, dt * 2)
    e.noTouch = e.fly
    if R.drainT then
        R.drainT = R.drainT - dt
        R.dAcc = (R.dAcc or 0) + dt
        if R.dAcc > 0.5 then R.dAcc = 0 I.hurtPlayer(2, src("n_sapphiron")) e.hp = min(e.maxHp, e.hp + e.maxHp * 0.005)
            I.emit({ img = "ghost_blue", tint = FROST, x = p.x, y = p.y - 30, vx = (e.x - p.x) / 0.8, vy = (e.y - 60 - p.y) / 0.8, life = 0.8, s0 = 20, s1 = 26, a0 = 0.9, a1 = 0 }) end
        if R.drainT <= 0 or (R.drainKills or 0) >= 30 then R.drainT, R.drainKills = nil, nil end
    end
    if busy(e, dt) then return end
    if e.fly then
        e.airT = e.airT + dt
        if e.airT > 1 and e.bolts < 4 and ready(e, "icebolt", dt, 0.6, 0) then
            e.bolts = e.bolts + 1
            local a, r = random() * TAU, vr(110, 240)
            local x, y = p.x + cos(a) * r, p.y + sin(a) * r * 0.7
            tele({ shape = "circle", x = x, y = y, r = 42, t = 0.7, col = FROST, onEnd = function(t)
                boom(t.x, t.y, 110, FROST, { img = "ice_burst", smoke = false, shake = false, n = 10 })
                R.blocks = R.blocks or {}
                R.blocks[#R.blocks + 1] = { x = t.x, y = t.y, t = 0 }
                for k = 0, 4 do R.fx[#R.fx + 1] = { kind = "icicle", x = t.x + (k - 2) * 12, y = t.y + (k % 2) * 6, t = -k * 0.02, dur = 9, s = 44 + (k % 3) * 8, v = k % 3 } end
                if inCircle(p.x, p.y, t.x, t.y, 42) then p.stunT, p.tombT = 2, 2 I.hurtPlayer(10, src("n_sapphiron")) end
            end })
        elseif e.bolts >= 4 and not e.breathCast and e.airT > 4 then
            e.breathCast = true
            I.warn("Sapphiron takes a deep breath.", FROST)
            cast(e, "Frost Breath", 2.5, function(b)
                R.flash, R.flashC = 0.6, { 0.86, 0.94, 1 }
                boom(p.x, p.y - 40, 380, FROST, { img = "ice_burst", smoke = false, n = 50 })
                for _ = 1, 30 do I.emit({ img = "frost_cloud2", tint = c(200, 230, 255), x = p.x + vr(-500, 500), y = p.y + vr(-300, 300), z = vr(0, 60), vx = vr(-40, 40), life = vr(1.2, 2), s0 = 140, s1 = 280, a0 = 0.32, a1 = 0, rot = "rnd" }) end
                if not shadowed(R, p.x, p.y) then I.hurtPlayer(80, src("n_sapphiron", "breathed")) else text(p.x, p.y - 80, "Hidden behind the ice", c(225, 245, 255)) end
                for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and not shadowed(R, o.x, o.y) then o.frz = 1.5 o.frzMax = 1.5 o.doom = 1.2 end end
                b.fly, b.immune, b.root = nil, nil, nil
                b.landT = 3
            end)
        end
        return
    end
    if e.landT then e.landT = e.landT - dt if e.landT <= 0 then e.landT = nil
        for _, bl in ipairs(R.blocks or {}) do boom(bl.x, bl.y, 100, FROST, { img = "ice_burst", smoke = false, shake = false, n = 8 }) end
        R.blocks = {} end end
    if ready(e, "air", dt, 60, 30) then
        e.fly, e.immune, e.root, e.airT, e.bolts, e.breathCast = true, true, true, 0, 0, false
        I.warn("Sapphiron lifts off into the air!", FROST)
        I.puff(e.x, e.y, 10, { 0.7, 0.8, 0.9 }, { a = 0.5, s0 = 40, s1 = 120, spread = 3 })
    elseif not R.drainT and ready(e, "drain", dt, 24, 8) then
        cast(e, "Life Drain", 0.8, function() R.drainT, R.drainKills = 10, 0 I.warn("Life Drain! Slay 30 to break it.", FROST) end)
    end
end

E.ONSPAWN.n_kelthuzad = function()
    local R, p = Rn(), Rn().p
    local k = I.spawn("n_kelthuzad", p.x, p.y - 170)
    k.root, k.immune, k.phase = true, true, 1
    R.ktP1 = R.t + 180
    R.alcoves = {}
    for i = 0, 6 do local a = -pi / 2 + (i - 3) * 0.55 + pi R.alcoves[i + 1] = { a = a } end
    return { k }
end
E.BOSSFN.n_kelthuzad = function(e, dt, d)
    local R, p = Rn(), Rn().p
    if random() < dt * 10 then I.emit({ img = "purple_star", tint = c(150, 110, 255), x = e.x + vr(-44, 44), y = e.y, z = vr(20, 150), vz = 40, life = 0.8, s0 = 22, s1 = 6, a0 = 0.8, a1 = 0, light = 40 }) end
    if e.phase == 1 then
        if ready(e, "alcove", dt, 2, 0) then
            for i, al in ipairs(R.alcoves) do
                local x, y = p.x + cos(i * 0.9 + R.t * 0.05) * 480, p.y + sin(i * 0.9 + R.t * 0.05) * 330
                if random() < 0.6 then I.spawn("n_soldier", x, y) end
                if i == 1 then beam(x, y, 160, 60, GREEN, 1.2) end
            end
            e.abT = (e.abT or 0) + 1
            if e.abT % 3 == 0 then local x, y = I.edgePoint(30) I.spawn("n_abom", x, y) end
            if e.abT % 4 == 0 then local x, y = I.edgePoint(30) I.spawn("n_soulweaver", x, y) end
        end
        if R.t >= R.ktP1 then
            e.phase, e.immune, e.root = 2, nil, nil
            I.warn("Kel'Thuzad walks among you!", c(200, 160, 255))
            I.legendFx()
        end
        return
    end
    if e.phase == 2 and e.hp < e.maxHp * 0.45 then
        e.phase = 3
        I.warn("Kel'Thuzad calls for aid! Guardians of Icecrown arrive.", I.RED)
        for _ = 1, 2 do local x, y = I.edgePoint(30) I.spawn("n_guardian", x, y) end
        e.aidT = 20
    end
    if e.aidT then e.aidT = e.aidT - dt if e.aidT <= 0 then e.aidT = nil for _ = 1, 3 do local x, y = I.edgePoint(30) I.spawn("n_guardian", x, y) end end end
    if R.chainT then R.chainT = R.chainT - dt if R.chainT <= 0 then R.chainT = nil end end
    if busy(e, dt) then
        if e.castName == "Frostbolt" and (e.castDmg or 0) >= 400 then
            e.cast, e.onCast = nil, nil
            I.warn("Frostbolt interrupted!", GOLD)
        end
        return
    end
    if ready(e, "fbolt", dt, 12, 4) then
        cast(e, "Frostbolt", 2, function(b)
            local a = atan2(p.y - 18 - (b.y - 60), p.x - b.x)
            R.eproj[#R.eproj + 1] = { x = b.x, y = b.y - 60, vx = cos(a) * 300, vy = sin(a) * 300, dmg = 40, life = 3, img = "ice_blue", tint = FROST, glow = FROST, size = 40, src = src("n_kelthuzad") }
        end)
        e.onHurt = function(b, dmg) if b.cast and b.castName == "Frostbolt" then b.castDmg = (b.castDmg or 0) + dmg end end
    elseif ready(e, "blast", dt, 20, 9) then
        I.warn("Frost Blast!", FROST)
        p.tombT, p.stunT = 4, 4
        I.hurtPlayer(15, src("n_kelthuzad"))
        boom(p.x, p.y, 120, FROST, { img = "ice_burst", smoke = false, shake = false })
        for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and hyp(o.x - p.x, o.y - p.y) < 130 then o.frz, o.frzMax = 4, 4 R.arcs[#R.arcs + 1] = { x0 = p.x, y0 = p.y - 30, x1 = o.x, y1 = o.y - 26, t = 0, life = 0.4, storm = true } end end
    elseif ready(e, "fissure", dt, 14, 5) then
        local x, y = p.x, p.y
        haz({ x = x, y = y, r = 62, dur = 3, dmg = 0, look = "fissure", safe = false })
        tele({ shape = "circle", x = x, y = y, r = 62, t = 3, col = FISS, onEnd = function(t)
            beam(t.x, t.y, 520, 120, FISS, 0.9)
            boom(t.x, t.y, 220, FISS, { img = "shadow_burst", dark = { 0.2, 0.04, 0.1 } })
            if inCircle(p.x, p.y, t.x, t.y, 64) then I.hurtPlayer(70, src("n_kelthuzad")) end
            for _, o in ipairs(R.en) do if not o.dead and not o.M.boss and inCircle(o.x, o.y, t.x, t.y, 70) then I.kill(o, false) end end
        end })
    elseif ready(e, "chains", dt, 30, 16) then
        I.warn("Kel'Thuzad binds you in chains!", c(200, 160, 255))
        R.chainT, p.rev = 4, 4
    end
end

---------------------------------------------------------------------------
-- deaths
---------------------------------------------------------------------------
local function finaleDown(R)                 -- the master (or the last of a group) is dead: the run is won
    if R.victoryT or R.over then return end
    R.victoryT = 2.5
    R.finaleOn = false
    R.calm = true
    for _, o in ipairs(R.en) do if not o.dead and not o.M.boss then o.fixed, o.life = { vr(-140, 140), vr(-140, 140) }, 2 end end
end
function E.ONKILL(e, o)
    local R = Rn()
    local M, t = e.M, e.type
    if M.burst then
        I.flash("green_glow", e.x, e.y - 10, 60, nil, 0.35)
        haz({ x = e.x, y = e.y, r = 34, dur = 3, dmg = 3, every = 0.6, look = "slime", src = src(t) })
    end
    if M.ghosts then for k = 0, 2 do I.spawn("n_soulweaver", e.x + cos(k * 2.1) * 30, e.y + sin(k * 2.1) * 20) end end
    if e.worship then
        R.nx.worshipKilled = true
        local f = alive("n_faerlina")
        if f and hyp(f.x - e.x, f.y - e.y) < 170 and f.enraged then
            f.enraged, f.dmgMul, f.spdMul, f.tint, f.silenced = nil, nil, nil, nil, 30
            I.warn("Widow's Embrace: the frenzy ends.", c(220, 190, 255))
            boom(f.x, f.y, 160, SHADOW, { img = "purple_star", smoke = false })
        end
    end
    if R.curse then R.curse.got = R.curse.got + 1 end
    if R.drainT then R.drainKills = (R.drainKills or 0) + 1 end
    if t == "n_spore" then
        if hyp(R.p.x - e.x, R.p.y - e.y) < 160 then R.creepT = 90 I.warn("Fungal Creep: +50% critical strikes", c(230, 255, 120)) end
        R.nx.sporeKilled = true
        I.puff(e.x, e.y, 12, { 0.7, 0.8, 0.35 }, { a = 0.6, s0 = 30, s1 = 90, spread = 2 })
    end
    if t == "n_abom" and R.ktP1 and R.t < R.ktP1 then R.nx.ktAboms = (R.nx.ktAboms or 0) + 1 end
    -- Gothik's harvest: the living who die rise on the dead side
    if R.gateX and not R.gateOpen and not M.boss and e.x < R.gateX and alive("n_gothik") then
        local g = I.spawn(t, R.gateX + (R.gateX - e.x), e.y)
        g.ghostOf, g.root, g.tint, g.alpha = t, true, { 0.55, 1, 0.65 }, 0.75
        R.nx.ghosts = (R.nx.ghosts or 0) + 1
    end
    if not M.boss then return end
    if t == "n_maexxna" then if e.arriveT and R.t - e.arriveT <= 60 then R.nx.maexxnaFast = true end finaleDown(R)
    elseif t == "n_loatheb" then R.healLock = nil finaleDown(R)
    elseif t == "n_heigan" then R.disrupt = nil
    elseif t == "n_gothik" then R.dmgMul = 1 R.gateX = nil
    elseif t == "n_patchwerk" then R.calm = nil if e.arriveT and R.t - e.arriveT <= 60 then R.nx.werkFast = true end
    elseif M.horseman then
        R.horseDead = R.horseDead or {}
        R.horseDead[t] = R.t
        local n, lo, hi = 0, 1e9, -1e9
        for _, h in ipairs(HORSE) do local tt = R.horseDead[h[1]] if tt then n = n + 1 lo, hi = min(lo, tt), max(hi, tt) end end
        if n >= 4 then
            R.nx.horsemen = true
            if hi - lo <= 15 then R.nx.together = true end
            R.marks = nil R.dmgTakenMul = 1 R.groupName = nil
            finaleDown(R)
        end
    elseif t == "n_stalagg" or t == "n_feugen" then
        local tw = e.twin
        if tw and not tw.dead then
            tw.reviveOther = { type = t, x = e.x, y = e.y, at = R.t + 15 }
            I.warn((t == "n_stalagg" and "Feugen" or "Stalagg") .. " will revive his twin in 15 seconds!", I.ORANGE)
        else
            R.groupName = nil
            I.warn("Thaddius awakens!", I.RED)
            local p = R.p
            local th = I.spawn("n_thaddius", p.x, p.y - 220)
            th.arriveT = R.t
            th.berserkAt = R.t + (R.ST.berserk or 200)
            boom(th.x, th.y, 220, STORM, { img = "lightning_hit", smoke = false })
        end
    elseif t == "n_thaddius" then R.dmgMul = 1 R.p.charge = nil R.stacks = nil for _, o in ipairs(R.en) do o.charge = nil end finaleDown(R)
    elseif t == "n_sapphiron" then R.blocks = {} R.drainT = nil
    elseif t == "n_kelthuzad" then R.chainT = nil R.ktKilled = true finaleDown(R) end
end

---------------------------------------------------------------------------
-- the stages' floors
---------------------------------------------------------------------------
local function common(R, dt)
    local p = R.p
    -- beams fade
    local bs = R.beams
    if bs then local i = 1 while i <= #bs do local b = bs[i] b.t = b.t + dt if b.t >= b.dur then table.remove(bs, i) else i = i + 1 end end end
    -- the hero's states
    if (p.wrapT or 0) > 0 then p.wrapT = p.wrapT - dt end
    if (p.tombT or 0) > 0 then p.tombT = p.tombT - dt end
    if (p.silenceT or 0) > 0 then p.silenceT = p.silenceT - dt end
    if (p.venom or 0) > 0 then
        p.venomT = p.venomT - dt
        R.vAcc = (R.vAcc or 0) + dt
        if R.vAcc >= 1 then R.vAcc = 0 I.hurtPlayer(1.2 * p.venom, src("n_venom")) end
        if p.venomT <= 0 then p.venom = 0 end
    end
    -- Stalagg and Feugen: one revives the other if not both fall in time
    for _, e in ipairs(R.en) do
        local rv = e.reviveOther
        if rv and not e.dead and R.t >= rv.at then
            e.reviveOther = nil
            local n = I.spawn(rv.type, rv.x, rv.y)
            n.root, n.twin, e.twin = true, e, n
            n.hp = n.maxHp * 0.5
            I.warn(MOBS[rv.type].name .. " is revived!", I.RED)
            boom(rv.x, rv.y, 160, STORM, { img = "lightning_hit", smoke = false })
        end
    end
    -- frozen dead that the breath doomed
    for _, e in ipairs(R.en) do if e.doom and not e.dead then e.doom = e.doom - dt if e.doom <= 0 then I.kill(e, false) end end end
    -- the HUD's notes
    local n = R.hudNotes or {}
    for k in pairs(n) do n[k] = nil end
    R.hudNotes = n
    if R.curse then n[#n + 1] = { string.format("Curse: slain %d / %d  \194\183  %ds", R.curse.got, R.curse.need, math.ceil(R.curse.t)), c(220, 170, 255) } end
    if R.doomT then n[#n + 1] = { string.format("Inevitable Doom in %ds", math.ceil(R.doomT)), c(200, 140, 255) } end
    if R.injT then n[#n + 1] = { string.format("Mutating Injection: %ds", math.ceil(R.injT)), c(170, 255, 120) } end
    if R.stacks and p.charge then n[#n + 1] = { string.format("%s Charge x%d  +%d%% damage", p.charge > 0 and "Positive" or "Negative", R.stacks, R.stacks * 10), p.charge > 0 and c(255, 170, 150) or c(150, 200, 255) } end
    if (R.creepT or 0) > 0 then n[#n + 1] = { string.format("Fungal Creep: +50%% crit  %ds", math.ceil(R.creepT)), c(230, 255, 120) } end
    if R.healLock then n[#n + 1] = { "Corrupted Mind: no healing", c(150, 220, 110) } end
    if R.drainT then n[#n + 1] = { string.format("Life Drain: slay %d more", max(0, 30 - (R.drainKills or 0))), FROST } end
    if R.marks then
        local tot = 0
        for _, m in pairs(R.marks) do tot = tot + m.n end
        R.dmgTakenMul = 1 + 0.08 * tot
        if tot > 0 then n[#n + 1] = { string.format("Marks x%d  +%d%% damage taken", tot, tot * 8), c(255, 190, 140) } end
    end
    if (p.venom or 0) > 0 then n[#n + 1] = { "Venom x" .. p.venom, GREEN } end
    if (R.dmgMul or 1) < 1 then n[#n + 1] = { string.format("Harvest Soul: %d%% damage", floor(R.dmgMul * 100 + 0.5)), c(220, 180, 255) } end
end

local function webs(R, dt)
    local p = R.p
    R.webAcc = (R.webAcc or 0) + dt
    local CH = E.CH
    local cx0, cy0 = floor(p.x / CH), floor(p.y / CH)
    local cs = R.spells.consecration
    for cx = cx0 - 1, cx0 + 1 do
        for cy = cy0 - 1, cy0 + 1 do
            local ch = E.Chunk(R, cx, cy)
            for _, z in ipairs(ch.zones) do
                if not z.gone then
                    local dd = hyp(p.x - z.x, (p.y - z.y) * 1.3)
                    if z.kind == "web" then
                        if dd < z.r then R.pSlowN = min(R.pSlowN, 0.6) end
                        -- fire burns webs: Consecration's ground, Flamestrike's fire, the Dragonling's orbs
                        local burn = cs and cs.rad and dd < cs.rad + z.r * 0.5
                        if not burn then for _, a in ipairs(R.areas) do if a.kind == "burn" and hyp(a.x - z.x, a.y - z.y) < a.r + z.r then burn = true break end end end
                        if not burn and R.spells.dragonling and dd < 110 then burn = true end
                        if burn then
                            z.gone = true
                            I.flash("fire_core", z.x, z.y - 10, z.r * 1.6, nil, 0.4, { light = 120 })
                            I.puff(z.x, z.y, 5, { 0.3, 0.25, 0.2 }, { a = 0.5, s0 = 20, s1 = 60, spread = 2 })
                        end
                    else
                        if dd < z.r then
                            R.pSlowN = min(R.pSlowN, 0.65)
                            R.slimeAcc = (R.slimeAcc or 0) + dt
                            if R.slimeAcc > 0.6 then R.slimeAcc = 0 I.hurtPlayer(3, { M = { name = "a slime pool" } }) end
                        end
                    end
                end
            end
        end
    end
end

E.STAGEFN.arachnid = {
    tick = function(dt)
        local R = Rn()
        common(R, dt) webs(R, dt)
        local p = R.p
        if ready(R, "eggs", dt, 40, 20) then
            for _ = 1, 2 do local a, d = random() * TAU, vr(260, 420) R.pick[#R.pick + 1] = { kind = "eggsac", static = true, x = p.x + cos(a) * d, y = p.y + sin(a) * d * 0.7, t = 0 } end
        end
        local i = 1
        while i <= #R.pick do
            local k = R.pick[i]
            local gone = false
            if k.kind == "eggsac" then
                local d = hyp(p.x - k.x, p.y - k.y)
                local cs = R.spells.consecration
                local burnt = cs and cs.rad and d < cs.rad
                for _, a in ipairs(R.areas) do if hyp(a.x - k.x, a.y - k.y) < a.r then burnt = true end end
                if burnt then gone = true I.flash("fire_core", k.x, k.y - 14, 60, nil, 0.3)
                elseif d < 110 or k.t > 45 then
                    gone = true
                    I.flash("green_glow", k.x, k.y - 14, 80, nil, 0.4)
                    I.puff(k.x, k.y, 6, { 0.75, 0.78, 0.7 }, { a = 0.5, s0 = 20, s1 = 60 })
                    for _ = 1, 6 do I.spawn("n_spider", k.x + vr(-20, 20), k.y + vr(-14, 14)) end
                end
            end
            if gone then table.remove(R.pick, i) else i = i + 1 end
        end
    end }
E.STAGEFN.plague = {
    tick = function(dt)
        local R = Rn()
        common(R, dt)
        local p = R.p
        local VW = I.View()
        if ready(R, "cloud", dt, 22, 15) then
            local dir = random() < 0.5 and 1 or -1
            for k = -1, 1 do
                haz({ x = p.x - dir * (VW / 2 + 120), y = p.y + k * 150, vx = dir * 55, r = 95, dur = 24, dmg = 4, every = 0.5, look = "none", src = { M = { name = "the plague" } }, onTick = function(h)
                    if random() < 0.5 then I.emit({ img = "smoke_sheet", cell = floor(random() * 40), tint = { 0.42, 0.68, 0.24 }, add = false, x = h.x + vr(-h.r, h.r), y = h.y + vr(-h.r, h.r) * 0.6, z = 10, vz = 12, vx = h.vx, life = 1.8, s0 = 50, s1 = 110, a0 = 0.35, a1 = 0, fi = 0.2, rot = "rnd" }) end
                end })
            end
        end
        if R.rules.dance and not alive("n_heigan") and ready(R, "dance", dt, 7, 30) then
            R.danceI = (R.danceI or 0) + 1
            danceStep(R, p.x, p.y, R.danceI, 4)
        end
    end }
E.STAGEFN.military = {
    tick = function(dt)
        local R = Rn()
        common(R, dt)
        local p = R.p
        local VW = I.View()
        if ready(R, "riders", dt, 20, 25) then
            local y, dir = p.y + vr(-120, 120), random() < 0.5 and 1 or -1
            local x0, x1 = p.x - dir * (VW / 2 + 60), p.x + dir * (VW / 2 + 60)
            tele({ shape = "line", x = x0, y = y, x2 = x1, y2 = y, w = 50, t = 1.6, col = RED, onEnd = function()
                for k = 0, 1 do I.spawn("n_rider", x0 - dir * k * 60, y + (k - 0.5) * 24, { fixed = { dir * 540, 0 }, life = 2.4 }) end
                I.sound("bosswarn", 0.5, 0.4)
            end })
        end
    end }
E.STAGEFN.construct = { tick = function(dt) local R = Rn() common(R, dt) webs(R, dt) end }
E.STAGEFN.frost = {
    init = function(run)
        run.braziers = {}
    end,
    tick = function(dt)
        local R = Rn()
        common(R, dt)
        local p = R.p
        -- braziers: a few always within reach; standing by one (or in your own fire) thaws you
        local near = 0
        for _, k in ipairs(R.pick) do if k.kind == "brazier" and hyp(k.x - p.x, k.y - p.y) < 700 then near = near + 1 end end
        if near < 3 then local a, d = random() * TAU, vr(320, 520) R.pick[#R.pick + 1] = { kind = "brazier", static = true, x = p.x + cos(a) * d, y = p.y + sin(a) * d * 0.7, t = 0 } end
        local i = 1
        while i <= #R.pick do local k = R.pick[i] if k.kind == "brazier" and hyp(k.x - p.x, k.y - p.y) > 1300 then table.remove(R.pick, i) else i = i + 1 end end
        local warm = false
        for _, k in ipairs(R.pick) do if k.kind == "brazier" and hyp(k.x - p.x, k.y - p.y) < 75 then warm = true end end
        for _, a in ipairs(R.areas) do if a.kind == "burn" and hyp(a.x - p.x, a.y - p.y) < a.r then warm = true end end
        if R.spells.dragonling then warm = warm or random() < 0.3 end
        local fr = R.rules.noFrostRes and 0 or (R.frostRes or 0)
        local rate = 2.6 * (alive("n_sapphiron") and 2 or 1) * (1 - D.FROST_RES_SLOW * fr)
        if warm then R.cold = max(0, R.cold - dt * 22 * (fr >= 5 and 2 or 1)) else R.cold = min(100, R.cold + dt * rate) end
        if R.cold >= 100 then R.coldAcc = (R.coldAcc or 0) + dt if R.coldAcc > 1 then R.coldAcc = 0 I.hurtPlayer(5, { M = { name = "the cold" } }) end end
        if random() < dt * 20 then I.emit({ img = "snowflake", tint = { 0.9, 0.95, 1 }, x = p.x + vr(-500, 500), y = p.y + vr(-300, 260), z = 260, vx = -30, vz = -vr(50, 100), life = 3, s0 = vr(5, 9), s1 = 5, a0 = 0.9, a1 = 0.3, rot = "rnd", vr = 2 }) end
        if R.storm and ready(R, "blizz", dt, 14, 2) then
            local a = random() * TAU
            haz({ x = p.x + cos(a) * 300, y = p.y + sin(a) * 200, vx = -cos(a) * 40, vy = -sin(a) * 28, r = 90, dur = 14, dmg = 3, every = 0.6, slow = 0.7, look = "frost", src = { M = { name = "a blizzard" } }, onTick = function(h)
                if random() < 0.6 then I.emit({ img = "ice_missile", tint = FROST, x = h.x + vr(-h.r, h.r) - 20, y = h.y + vr(-h.r, h.r) * 0.6, z = 200, vx = 60, vz = -400, life = 0.5, s0 = 18, s1 = 18, sy = 0.45, a0 = 0.9, a1 = 0.6, rot = pi, stretch = 0.15 }) end
            end })
        end
    end }

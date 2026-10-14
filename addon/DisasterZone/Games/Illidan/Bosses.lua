if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/Bosses.lua", ...) then return end -- DisasterZone Games/Illidan/Bosses.lua
-- ns.BoIBosses: the five bosses of The Binding of Illidan, each with the mechanics people know from the raid, scaled
-- to one room and one player. Phases, emotes and yells are the raid's (Data/BossMods/*.lua has the real timers); the
-- timers here run at about a third of the raid's. Init[key](run, boss, room) sets a fight up, AI[key](run, boss, p,
-- dx, dy, d) runs it a frame. They draw on the engine's helpers (ns.BoI: Hz, Patch, Say, Cast, Chase, Cleave...).
local _, ns = ...

local D, E = ns.BoIData, ns.BoI
local B = { Init = {}, AI = {} }
ns.BoIBosses = B

local floor, min, max, sin, cos, pi, atan2 = math.floor, math.min, math.max, math.sin, math.cos, math.pi, math.atan2
local R, Rnd, Hyp = E.R, E.Rnd, E.Hyp
local X0, Y0, X1, Y1, CX, CY = E.X0, E.Y0, E.X1, E.Y1, E.CX, E.CY
local SP = D.SPELL

local DEBRIS = { 0.79, 0.64, 0.48 }
local FEL = { 0.49, 1, 0.23 }
local SHADOW = { 0.69, 0.42, 1 }
local PINK = { 1, 0.4, 0.75 }

---------------------------------------------------------------------------
-- Magtheridon (Magtheridon's Lair)
-- Banished by five Hellfire Channelers: kill them, or he breaks free on his own (2 min in the raid, 40 s here).
-- Blast Nova: the Manticron Cubes (here: stand on one for a second); a used cube is exhausted for the next Nova.
-- Quake; at 30% the ceiling caves in and keeps falling.
---------------------------------------------------------------------------

B.Init.magtheridon = function(run, f, room)
    f.immune, f.noTouch, f.y, f.free = true, true, CY - 10, 2400
    for i = 0, 4 do
        local a = -pi / 2 + i * pi * 2 / 5
        local c = E.MkFoe(run, "mchan", CX + cos(a) * 160, CY - 10 + sin(a) * 118)
        c.off, c.t = 60 + i * 90, i * 31
        room.foes[#room.foes + 1] = c
    end
    run.cubes = {}
    for _, xy in ipairs({ { X0 + 46, Y0 + 46 }, { X1 - 46, Y0 + 46 }, { X0 + 46, Y1 - 46 }, { X1 - 46, Y1 - 46 }, { CX, Y1 - 40 } }) do
        run.cubes[#run.cubes + 1] = { x = xy[1], y = xy[2], ex = 0, hold = 0 }
    end
end

B.AI.magtheridon = function(run, f, p, dx, dy, d)
    if f.phase == 1 then
        f.vx, f.vy = 0, 0
        local left = 0
        for _, x in ipairs(run.room.foes) do if x.kind == "mchan" then left = left + 1 end end
        f.free = f.free - 1
        f.phaseName = string.format("Banished \194\183 free in %d s", math.ceil(f.free / 60))
        if f.free <= 0 or left == 0 then
            f.phase, f.immune, f.noTouch, f.phaseName, f.nova, f.quake = 2, nil, nil, "Free", 240, 700
            E.Say(run, "Magtheridon", "I... am... unleashed!")
            run.shake = 18
        end
        return
    end
    if f.phase == 2 and f.hp < f.max * 0.3 then
        f.phase, f.phaseName, run.shake = 3, "The ceiling collapses", 40
        E.Say(run, "Magtheridon", "Let the walls of this prison tremble... and FALL!")
        for i = 1, 14 do
            local x, y = E.Near(run, CX, CY, 300)
            E.Hz(run, x, y, 30, 60 + i * 4, { col = DEBRIS, dmg = 2, boom = true, by = { n = "Debris" } })
        end
    end
    if f.casting then
        f.vx, f.vy = 0, 0
        for _, c in ipairs(run.cubes) do
            if c.ex == 0 and Hyp(p.x - c.x, p.y - c.y) < 24 then
                c.hold = c.hold + 1
                if c.hold >= 55 then
                    run.cast, f.casting, c.ex, c.hold = nil, nil, 2, 0
                    E.Toast(run, "Shadow Grasp: Blast Nova interrupted", 120)
                end
            else
                c.hold = max(0, c.hold - 2)
            end
        end
        return
    end
    E.Chase(run, f, 0.55)
    E.Cleave(run, f, 120)
    f.nova = f.nova - 1
    if f.nova <= 0 then
        f.nova, f.casting = 960, true
        for _, c in ipairs(run.cubes) do c.ex = max(0, c.ex - 1) end
        E.Say(run, "", "Magtheridon begins to cast Blast Nova!", "emote")
        E.Cast(run, "Blast Nova", SP.blastNova, 210, function()
            f.casting, f.rings = nil, { 1, 22, 44 }
            for _, c in ipairs(run.cubes) do c.hold = 0 end
        end)
    end
    if f.rings then
        local keep = {}
        for _, n in ipairs(f.rings) do
            n = n - 1
            if n == 0 then
                local o = Rnd(run.rng, 0, 1)
                for k = 0, 29 do E.Shoot(run, f, o + k * pi / 15, 2.5, 8, { 1, 0.48, 0.18 }, { n = "Blast Nova" }) end
            else
                keep[#keep + 1] = n
            end
        end
        f.rings = #keep > 0 and keep or nil
    end
    f.quake = f.quake - 1
    if f.quake <= 0 then
        f.quake, run.shake = 1100, 36
        for i = 1, 6 do
            local x, y = E.Near(run, p.x, p.y, 160)
            E.Hz(run, x, y, 26, 55 + i * 6, { col = DEBRIS, boom = true, by = { n = "Quake" } })
        end
    end
    if f.phase == 3 and f.t % 45 == 0 then
        local x, y
        if f.t % 135 == 0 then x, y = p.x, p.y else x, y = E.Near(run, CX, CY, 300) end
        E.Hz(run, x, y, 26, 60, { col = DEBRIS, boom = true, by = { n = "Debris" } })
    end
end

---------------------------------------------------------------------------
-- Supremus (Illidari Training Grounds)
-- Every 60 s in the raid (20 s here) he swaps: the tank phase (Hateful Strike, Molten Flame crawling at you) and
-- the kite phase ("The ground begins to crack open": he picks you, chases faster and faster, Volcanic Geysers).
---------------------------------------------------------------------------

B.Init.supremus = function(run, f)
    f.phaseName, f.mode, f.sw, f.mf, f.hs = "Tank phase", "tank", 1100, 120, 0
end

B.AI.supremus = function(run, f, p, dx, dy, d)
    f.sw = f.sw - 1
    if f.sw <= 0 then
        f.sw = 1100
        if f.mode == "tank" then
            f.mode, f.phaseName, f.vol = "kite", "Kite phase", 60
            E.Say(run, "", "The ground begins to crack open!", "emote")
            E.Toast(run, "Supremus acquires a new target!", 140)
        else
            f.mode, f.phaseName, run.shake = "tank", "Tank phase", 24
            E.Say(run, "", "Supremus punches the ground in anger!", "emote")
            for k = 0, 15 do E.Shoot(run, f, k * pi / 8, 2.4, 8, { 0.82, 0.54, 0.29 }) end
        end
    end
    if f.mode == "tank" then
        E.Chase(run, f, 0.6)
        if f.hs > 0 then f.hs = f.hs - 1
        elseif d < f.r + 34 then
            E.Hz(run, p.x, p.y, 26, 30, { col = { 1, 0.23, 0.18 }, dmg = 2, by = { n = "Hateful Strike" } })
            f.hs = 80
        end
        f.mf = f.mf - 1
        if f.mf <= 0 then
            f.mf = 150
            run.mflames[#run.mflames + 1] = { x = f.x, y = f.y + f.r * 0.6, vx = 0, vy = 0, life = 300 }
        end
    else
        E.Chase(run, f, 1.1 + (1 - f.sw / 1100) * 1.7, 0.1)
        f.vol = f.vol - 1
        if f.vol <= 0 then
            f.vol = 75
            local x, y = E.Near(run, p.x, p.y, 45)
            E.Hz(run, x, y, 28, 55, { col = { 1, 0.35, 0.1 }, by = { n = "Volcanic Geyser" },
                                      ["then"] = function(h) run.volcs[#run.volcs + 1] = { x = h.x, y = h.y, life = 210 } end })
        end
    end
end

---------------------------------------------------------------------------
-- Teron Gorefiend (Gorefiend's Vigil)
-- Incinerate, Crushing Shadows, Doom Blossoms. Shadow of Death: a few seconds after he marks you, you die and rise
-- as a Vengeful Spirit (nothing can hurt you, your bolts become Spirit Lances); Shadowy Constructs rise from your
-- body and walk at it - only a spirit can hurt them. When the spirit fades you stand up where you fell, and any
-- construct still standing is solid again.
---------------------------------------------------------------------------

B.Init.teron = function(run, f)
    f.phaseName, f.inc, f.crush, f.bloom, f.sodT = "", 150, 400, 300, 540
end

local function EndSpirit(run)
    local p = run.p
    if run.corpse then p.x, p.y = run.corpse.x, run.corpse.y end
    run.spirit, run.corpse = nil, nil
    for _, x in ipairs(run.room.foes) do if x.kind == "construct" then x.spiritOnly = nil end end
    local torn = run.corpseHits or 0
    run.corpseHits = 0
    if torn > 0 then
        p.inv = 0
        E.Hurt(run, { n = "Shadowy Construct" }, min(3, torn))
    else
        E.Toast(run, "You return to your body", 90)
    end
    p.inv = max(p.inv, 60)
end

-- a construct that reaches your body while you are a spirit tears at it (it costs you when you stand up)
local function Constructs(run)
    local c = run.corpse
    if not c then return end
    local keep = {}
    for _, x in ipairs(run.room.foes) do
        if x.kind == "construct" and Hyp(x.x - c.x, x.y - c.y) < x.r + 14 then
            run.corpseHits = (run.corpseHits or 0) + 1
            run.zaps[#run.zaps + 1] = { boom = true, x = c.x, y = c.y, life = 12, col = SHADOW }
            E.Toast(run, "A construct reached your body", 90)
        else
            keep[#keep + 1] = x
        end
    end
    run.room.foes = keep
end

B.AI.teron = function(run, f, p, dx, dy, d)
    -- Shadow of Death: the mark, the spirit, the return
    if run.spirit then
        run.spirit = run.spirit - 1
        Constructs(run)
        if run.spirit <= 0 then EndSpirit(run) end
    elseif run.sod then
        run.sod = run.sod - 1
        if run.sod <= 0 then
            run.sod = nil
            run.spirit, run.corpse = 600, { x = p.x, y = p.y }
            for k = 0, 3 do
                local a = k * pi / 2 + pi / 4
                local c = E.MkFoe(run, "construct", p.x + cos(a) * 60, p.y + sin(a) * 60)
                c.x, c.y = E.Clamp(c.x, c.y, 20)
                run.room.foes[#run.room.foes + 1] = c
            end
            E.Toast(run, "You are a Vengeful Spirit: kill the Shadowy Constructs before they reach your body", 200)
        end
    else
        f.sodT = f.sodT - 1
        if f.sodT <= 0 then
            f.sodT, run.sod = 1250, 300
            E.Toast(run, "Shadow of Death on you: you die in 5 seconds", 140)
        end
    end
    E.Chase(run, f, run.spirit and 0.2 or 0.8)
    if run.spirit then return end
    f.inc = f.inc - 1
    if f.inc <= 0 then
        f.inc = 170
        E.Hz(run, p.x, p.y, 28, 40, { col = { 1, 0.45, 0.1 }, fire = 200, boom = true, by = { n = "Incinerate" } })
    end
    f.crush = f.crush - 1
    if f.crush <= 0 then
        f.crush = 420
        E.Hz(run, p.x, p.y, 34, 60, { col = SHADOW, boom = true, dmg = 2, by = { n = "Crushing Shadows" } })
        for _ = 1, 3 do
            local x, y = E.Near(run, CX, CY, 260)
            E.Hz(run, x, y, 34, 60, { col = SHADOW, boom = true, dmg = 2, by = { n = "Crushing Shadows" } })
        end
    end
    f.bloom = f.bloom - 1
    if f.bloom <= 0 then
        f.bloom = 620
        local x, y = E.Near(run, f.x, f.y, 90)
        run.room.foes[#run.room.foes + 1] = E.MkFoe(run, "blossom", x, y)
    end
end

---------------------------------------------------------------------------
-- Mother Shahraz (Den of Mortal Delights)
-- Saber Lash in front; her beams (Sinister, Vile, Wicked, Sinful) one after another; Fatal Attraction pulls you
-- together with two others (here: you are ported and the three explode - run); Silencing Shriek; below 10% she
-- frenzies and the beams come all at once.
---------------------------------------------------------------------------

local BEAMS = {
    { kind = "sinister", n = "Sinister Beam", col = { 0.69, 0.42, 1 } },
    { kind = "vile", n = "Vile Beam", col = { 0.49, 1, 0.23 } },
    { kind = "wicked", n = "Wicked Beam", col = { 1, 0.3, 0.25 } },
    { kind = "sinful", n = "Sinful Beam", col = { 1, 0.4, 0.75 } },
}

B.Init.shahraz = function(run, f)
    f.phaseName, f.beamT, f.beamI, f.fatal, f.shriek = "", 120, 0, 700, 500
end

B.AI.shahraz = function(run, f, p, dx, dy, d)
    if not f.frenzy and f.hp < f.max * 0.1 then
        f.frenzy, f.phaseName = true, "Frenzy"
        E.Say(run, "", "Mother Shahraz goes into a frenzy!", "emote")
    end
    E.Chase(run, f, 0.5)
    E.Cleave(run, f, 140)
    f.beamT = f.beamT - 1
    if f.beamT <= 0 then
        f.beamT = f.frenzy and 45 or 120
        f.beamI = f.beamI % #BEAMS + 1
        local b = BEAMS[f.beamI]
        -- the beam runs from her through where you stand to the wall
        local a = atan2(dy, dx)
        local ex, ey = E.Clamp(f.x + cos(a) * 900, f.y + sin(a) * 900, 0)
        run.beams[#run.beams + 1] = { kind = b.kind, n = b.n, col = b.col, ax = f.x, ay = f.y, bx = ex, by = ey, t = 0, warn = 40 }
    end
    f.fatal = f.fatal - 1
    if f.fatal <= 0 then
        f.fatal = 1300
        local x, y = E.Near(run, CX, CY, 220)
        p.x, p.y, p.vx, p.vy = x, y, 0, 0
        E.Toast(run, "Fatal Attraction: run!", 120)
        E.Hz(run, x, y, 80, 100, { col = PINK, dmg = 2, boom = true, by = { n = "Fatal Attraction" } })
        for _, o in ipairs({ -55, 55 }) do
            local hx, hy = E.Clamp(x + o, y + (o > 0 and 30 or -30), 0)
            E.Hz(run, hx, hy, 70, 100, { col = PINK, dmg = 2, boom = true, by = { n = "Fatal Attraction" } })
        end
    end
    f.shriek = f.shriek - 1
    if f.shriek <= 0 then
        f.shriek = 560
        for k = 0, 19 do E.Shoot(run, f, k * pi / 10, 2.4, 7, PINK, { n = "Silencing Shriek" }) end
    end
end

---------------------------------------------------------------------------
-- Illidan Stormrage (Temple Summit)
-- P1 Shear, Flame Crash, Parasitic Shadowfiend. 65%: he flies up and throws his glaives; two Flames of Azzinoth,
-- each tied to its blade (too far: Uncaged Wrath), Eye Blast, fireballs. P3 he lands; Demon Form with Shadow Blast
-- and Shadow Demons. 30%: Maiev joins and sets Cage Traps; walk him onto one and he takes double damage.
---------------------------------------------------------------------------

B.Init.illidan = function(run, f)
    f.phaseName, f.crash, f.para, f.y = "Phase 1", 260, 480, CY - 60
end

local function EndDemon(f)
    f.demon, f.d.i, f.d.ej, f.r, f.demonT = 0, f.boss.ej, true, f.boss.r, 1250
    f.phaseName = f.phase == 4 and "Phase 4" or "Phase 3"
end

local function EyeBlast(run)
    E.Say(run, "Illidan Stormrage", "Stare into the eyes of the Betrayer!")
    local top = R(run.rng) < 0.5
    local ax, ay, bx, by
    if top then ax, ay, bx, by = Rnd(run.rng, X0 + 40, X1 - 40), Y0 + 10, Rnd(run.rng, X0 + 40, X1 - 40), Y1 - 10
    else ax, ay, bx, by = X0 + 10, Rnd(run.rng, Y0 + 40, Y1 - 40), X1 - 10, Rnd(run.rng, Y0 + 40, Y1 - 40) end
    run.beam = { ax = ax, ay = ay, bx = bx, by = by, t = 0, warn = 70, run = 130 }
end

local function TrapCheck(run, f)
    local m = run.maiev
    if not m then return end
    m.trap = m.trap - 1
    if m.trap <= 0 then
        m.trap = 480
        local x, y = E.Clamp((run.p.x + f.x) / 2 + Rnd(run.rng, -30, 30), (run.p.y + f.y) / 2 + Rnd(run.rng, -30, 30))
        run.zaps[#run.zaps + 1] = { boom = true, x = m.x, y = m.y, life = 10, col = { 0.48, 0.24, 1 } }
        m.x, m.y = E.Near(run, x, y, 90)
        run.traps[#run.traps + 1] = { x = x, y = y, arm = 40, forBoss = true }
        E.Toast(run, "Maiev sets a Cage Trap: lead Illidan onto it", 120)
    end
    for _, t in ipairs(run.traps) do
        if t.forBoss and t.arm <= 0 and not t.used and Hyp(f.x - t.x, f.y - t.y) < f.r then
            t.used = true
            if f.demon and f.demon > 0 then EndDemon(f) end
            f.caged, f.vx, f.vy, f.phaseName = 300, 0, 0, "Caged"
            E.Toast(run, "Illidan is caged: he takes double damage", 140)
        end
    end
end

B.AI.illidan = function(run, f, p, dx, dy, d)
    if f.caged and f.caged > 0 then
        f.caged, f.vx, f.vy = f.caged - 1, 0, 0
        if f.caged % 5 == 0 then run.zaps[#run.zaps + 1] = { x1 = f.x + Rnd(run.rng, -50, 50), y1 = f.y - 60, x2 = f.x, y2 = f.y, life = 6 } end
        if f.caged == 0 then f.phaseName = "Phase 4" end
        return
    end
    if f.phase == 1 and f.hp < f.max * 0.65 then
        f.phase, f.phaseName, f.immune, f.noTouch, f.swing, f.eye, f.ball = 2, "Flames of Azzinoth", true, true, nil, 420, 120
        E.Say(run, "Illidan Stormrage", "Behold the flames of Azzinoth!")
        run.glaives = {}
        for _, xy in ipairs({ { CX - 180, CY + 40 }, { CX + 180, CY + 40 } }) do
            local fl = E.MkFoe(run, "azflame", xy[1], xy[2] + 30)
            fl.blade = { x = xy[1], y = xy[2] }
            run.room.foes[#run.room.foes + 1] = fl
            run.glaives[#run.glaives + 1] = fl.blade
        end
    end
    if f.phase == 2 then
        E.MoveTo(f, CX, Y0 + f.r + 4, 2)
        local flames = 0
        for _, fl in ipairs(run.room.foes) do
            if fl.kind == "azflame" then
                flames = flames + 1
                local far = Hyp(fl.x - fl.blade.x, fl.y - fl.blade.y) > 220
                if far and not fl.enraged then fl.enraged, fl.spd = true, 2.1 E.Toast(run, "Uncaged Wrath: a Flame is too far from its blade", 120) end
                if not far and fl.enraged then fl.enraged, fl.spd = nil, nil end
            end
        end
        f.ball = f.ball - 1
        if f.ball <= 0 then
            f.ball = 100
            run.orbs[#run.orbs + 1] = { x0 = f.x, y0 = f.y, x = p.x, y = p.y, t = 0, max = 50, col = FEL }
            E.Hz(run, p.x, p.y, 30, 50, { col = FEL, boom = true, fire = 300, by = { n = "Fireball" } })
        end
        f.eye = f.eye - 1
        if f.eye <= 0 then f.eye = 640 EyeBlast(run) end
        if flames == 0 then
            f.phase, f.phaseName, f.immune, f.noTouch, f.demonT = 3, "Phase 3", nil, nil, 360
            run.glaives, run.beam = nil, nil
            E.Toast(run, "Illidan lands", 100)
        end
        return
    end
    if f.phase == 3 and f.hp < f.max * 0.3 then
        f.phase, f.phaseName = 4, "Phase 4"
        run.maiev = { x = X0 + 50, y = Y1 - 50, trap = 60 }
        E.Say(run, "Maiev Shadowsong", "Their fury pales next to mine, Illidan.")
    end
    if f.demon and f.demon > 0 then   -- Demon Form: keeps away, Shadow Blast, the Shadow Demons creep at you
        f.demon = f.demon - 1
        if f.demon == 0 then EndDemon(f) end
        if d < 200 then f.vx, f.vy = -dx / d * 1.2, -dy / d * 1.2 else f.vx, f.vy = f.vx * 0.9, f.vy * 0.9 end
        if f.demon % 80 == 40 then
            run.orbs[#run.orbs + 1] = { x0 = f.x, y0 = f.y, x = p.x, y = p.y, t = 0, max = 60, col = SHADOW }
            E.Hz(run, p.x, p.y, 52, 60, { col = SHADOW, boom = true, dmg = 2, by = { n = "Shadow Blast" } })
        end
        return TrapCheck(run, f)
    end
    if f.phase >= 3 then
        f.demonT = f.demonT - 1
        if f.demonT <= 0 then
            f.demon, f.d.i, f.d.ej, f.r, f.phaseName, f.swing = 560, D.METAMORPH, nil, 42, "Demon Form", nil
            E.Say(run, "Illidan Stormrage", "Behold the power... of the demon within!")
            for _, xy in ipairs({ { X0 + 30, Y0 + 30 }, { X1 - 30, Y1 - 30 } }) do
                run.room.foes[#run.room.foes + 1] = E.MkFoe(run, "sdemon", xy[1], xy[2])
            end
            return
        end
    end
    E.Chase(run, f, f.phase == 4 and 1.15 or 0.95)
    E.Cleave(run, f, 140)
    f.crash = f.crash - 1
    if f.crash <= 0 then
        f.crash = 330
        E.Hz(run, p.x, p.y, 32, 50, { col = FEL, fire = 900, boom = true, by = { n = "Flame Crash" } })
    end
    f.para = f.para - 1
    if f.para <= 0 then
        f.para, run.paraOn = 600, 150
        E.Toast(run, "Parasitic Shadowfiend on you", 110)
    end
    TrapCheck(run, f)
end

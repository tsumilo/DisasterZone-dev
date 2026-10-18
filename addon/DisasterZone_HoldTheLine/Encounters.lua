if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Encounters.lua", ...) then return end -- DisasterZone_HoldTheLine/Encounters.lua
-- Hold the Line's small encounters in the Plaguelands (E.STAGEFN.epl): between the clock's events, every minute or so
-- something small happens - a courier fleeing with a satchel of runes, bones clawing out of the earth round the hero, a
-- tide of rats running past, a hound pack on the scent, a Ravener packleader with its pack. Picked with the run's seeded
-- dice (a seeded run is the same twice); never close to a clock event or while a boss stands, none after 13:45, none in
-- the lab, the demos or a card's preview.
local _, ns = ...
local E, D = ns.HTL, ns.HTLData
local I = E.I
local floor, max, cos, sin, sqrt, pi = math.floor, math.max, math.cos, math.sin, math.sqrt, math.pi
local TAU = pi * 2
local C = D.C
local YELLOW, GOLDTXT = { 1, 0.82, 0.25 }, { 1, 0.82, 0.25 }
local BONE_DUST = { 0.62, 0.58, 0.5 }
local function Rn() return I.R() end

-- the units an encounter watches (a courier's flight, a packleader's purse), in R.encWatch
local function watch(R, e, kind) R.encWatch = R.encWatch or {} R.encWatch[#R.encWatch + 1] = { e = e, kind = kind, t = 0 } end
local function float(R, x, y, text)
    R.texts[#R.texts + 1] = { x = x, y = y, vx = 0, vy = -50, v = text, t = 0, life = 1.2, col = GOLDTXT }
end
local function gems(R, x, y, n, v)
    for k = 1, n do
        local a = k / n * TAU
        R.gems[#R.gems + 1] = { x = x, y = y, v = v, t = 0, m = false, pop = 0.45, vx = cos(a) * 100, vy = sin(a) * 75 }
    end
end

local ENC, ORDER = {}, { "courier", "bones", "rats", "hounds", "packleader" }

-- a Plagued Courier runs from you with a satchel: catch it before it gets away for gold and a ring of runes
ENC.courier = { w = 3, from = 40, msg = "A Plagued Courier flees with a satchel of runes!", run = function(R)
    local p = R.p
    local a = I.rnd() * TAU
    local e = I.spawn("courier", p.x + cos(a) * 210, p.y + sin(a) * 150)
    e.noTouch = true
    R.courier = e
    watch(R, e, "courier")
end }

-- bones claw out of the earth in a ring round the hero (green runes mark where, a second before)
local function rise(t)
    I.spawn("skeleton", t.x, t.y)
    I.puff(t.x, t.y, 3, BONE_DUST, { a = 0.55, s0 = 16, s1 = 46, spread = 1.4, life = 0.8 })
    I.sparks(t.x, t.y, 5, BONE_DUST, { v0 = 60, v1 = 180, img = "dust", s = 7 })
end
ENC.bones = { w = 3, from = 45, msg = "Skeletons claw their way out of the earth!", run = function(R)
    local p = R.p
    local n = 6 + floor(R.t / 90)
    local a0 = I.rnd() * TAU
    for k = 0, n - 1 do
        local a = a0 + k / n * TAU
        local x, y = p.x + cos(a) * 175, p.y + sin(a) * 175 * 0.72
        I.emit({ img = "scourge_runes", tint = C.GREEN, x = x, y = y, life = 1.25, s0 = 14, s1 = 54, a0 = 1, a1 = 0.25, flat = true, rot = "rnd", vr = 3, light = 50 })
        R.tele[#R.tele + 1] = { kind = "rise", x = x, y = y, t = 1.1 + k * 0.04, t0 = 1.1, onEnd = rise }
    end
    I.sound("fear", 0.5, 0.6)
end }

-- a tide of rats runs across the field from one side to the other
ENC.rats = { w = 2, from = 50, msg = "A tide of plague rats scurries past!", run = function(R)
    local p = R.p
    local VW, VH = I.View()
    local dir = I.rnd() < 0.5 and 1 or -1
    for _ = 1, 18 + floor(R.t / 60) do
        I.spawn("rat", p.x - dir * (VW / 2 + 40 + I.rnd() * 160), p.y + I.rr(-VH * 0.35, VH * 0.35), { fixed = { dir * 170, I.rr(-10, 10) }, life = 9 })
    end
    I.sound("rat", 0.3)
end }

-- a hound pack comes in from one side, fast
ENC.hounds = { w = 2, from = 75, msg = "Plaguehounds have caught your scent!", run = function(R)
    local x, y = I.edgePoint(40)
    for _ = 1, 4 + floor(R.t / 150) do I.spawn("hound", x + I.rr(-40, 40), y + I.rr(-30, 30)) end
end }

-- a Ravener packleader with its ghouls; it carries a purse
ENC.packleader = { w = 2, from = 110, msg = "A Ravener Packleader leads its pack to you.", run = function(R)
    local x, y = I.edgePoint(40)
    local e = I.spawn("packleader", x, y)
    for _ = 1, 3 + floor(R.t / 180) do I.spawn("ghoul", x + I.rr(-50, 50), y + I.rr(-40, 40)) end
    watch(R, e, "purse")
end }

-- the clock's own events, scaled as runEvents scales them: an encounter waits for a quiet stretch
local function nearEvent(R)
    local EV, k = R.ST.events or D.EVENTS, R.rules.rush or 1
    for _, ev in ipairs(EV) do
        local t = ev.t * k
        if t > R.t - 15 and t < R.t + 25 then return true end
    end
end

local function pick(R)
    local list, tot = {}, 0
    for _, id in ipairs(ORDER) do
        local en = ENC[id]
        if R.t >= en.from and id ~= R.encLast then list[#list + 1] = id tot = tot + en.w end
    end
    local x = I.rnd() * tot
    for _, id in ipairs(list) do x = x - ENC[id].w if x <= 0 then return id end end
    return list[#list]
end

local function tickWatch(R, dt)
    local W = R.encWatch
    if not W then return end
    local p = R.p
    local VW = I.View()
    local i = 1
    while i <= #W do
        local w = W[i]
        local e = w.e
        local done = false
        w.t = w.t + dt
        if w.kind == "courier" then
            if e.dead then
                if not w.gone then           -- caught: the satchel spills
                    R.pick[#R.pick + 1] = { kind = "gold", x = e.x + 8, y = e.y, v = 15 + floor(R.t / 30), t = 0 }
                    gems(R, e.x, e.y, 8, 3)
                    I.flash("holy_star", e.x, e.y - 20, 70, C.GOLD, 0.3, { light = 120 })
                    float(R, e.x, e.y - 46, "Satchel!")
                    I.sound("coin")
                end
                done = true
            else
                local dx, dy = e.x - p.x, e.y - p.y
                local d = max(1, sqrt(dx * dx + dy * dy))
                if d > VW * 0.62 or w.t > 16 then       -- gone into the fog
                    w.gone = true
                    I.puff(e.x, e.y, 4, BONE_DUST, { a = 0.5, s0 = 20, s1 = 60, spread = 1.5 })
                    e.dead = true
                    float(R, p.x, p.y - 60, "The courier got away")
                elseif e.frz > 0 or e.stun > 0 then
                    e.fixed = nil                       -- (held: it stands where it is)
                else
                    local sp = 96 * (e.slow > 0 and 0.55 or 1)
                    e.fixed = e.fixed or {}
                    e.fixed[1], e.fixed[2] = dx / d * sp, dy / d * sp
                end
            end
            if done and R.courier == e then R.courier = nil end
        elseif w.kind == "purse" then
            if e.dead then
                R.pick[#R.pick + 1] = { kind = "gold", x = e.x + 8, y = e.y, v = 10 + floor(R.t / 45), t = 0 }
                gems(R, e.x, e.y, 5, 3)
                done = true
            end
        end
        if done then table.remove(W, i) else i = i + 1 end
    end
end

E.STAGEFN.epl = {
    init = function(run)
        if run.lab or run.attract or run.preview then return end
        run.encT = 42 + I.rnd() * 14            -- (the first one comes in the first minute)
    end,
    tick = function(dt)
        local R = Rn()
        if R.preview or R.lab or R.attract then return end
        tickWatch(R, dt)
        if not R.encT or R.t < R.encT then return end
        if R.t > 825 then R.encT = nil return end
        if R.boss or nearEvent(R) then R.encT = R.t + 8 return end
        local id = pick(R)
        if not id then R.encT = R.t + 3 return end    -- (none allowed yet)
        R.encLast = id
        I.warn(ENC[id].msg, YELLOW)
        ENC[id].run(R)
        R.encT = R.t + I.rr(50, 80)
    end,
}
E.ENCOUNTERS = ENC            -- (the tests start one by name: E.Use(run) E.ENCOUNTERS[id].run(run))
-- the dev bar's "Encounter now": the next one the dice pick, at once (whatever the clock says)
function E.DevEncounter(run)
    E.Use(run)
    local id = pick(run) or "courier"
    run.encLast = id
    I.warn(ENC[id].msg, YELLOW)
    ENC[id].run(run)
end

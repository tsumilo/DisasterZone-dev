if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Illidan/Engine.lua", ...) then return end -- DisasterZone Games/Illidan/Engine.lua
-- ns.BoI: The Binding of Illidan's game, without a single frame: a run is a plain table that E.Step moves one
-- frame (1/60 s) at a time from an input table, so the panel (Games/Illidan/UI.lua) draws it and the tests and the
-- balance bot play it headless. Everything random comes from the run's own generators: the map from its seed alone
-- (the daily seed gives the whole guild the same dungeon), the fights from the seed and the floor.
--
-- input = { mx, my (-1..1), shoot = "up" | "down" | "left" | "right" | nil, bomb = true (pressed this frame),
--           use = true (Space pressed this frame) }
-- run.mode: "floorcard" (the floor's title), "vs" (the boss's card), "play", "dying" (the killing blow's slow
-- motion, E.DYING frames), "dead" (the death card; run.deadT counts its frames), "won".
local _, ns = ...

local D = ns.BoIData
local E = {}
ns.BoI = E

local floor, min, max, abs, sqrt, sin, cos, pi = math.floor, math.min, math.max, math.abs, math.sqrt, math.sin, math.cos, math.pi
local atan2 = math.atan2
local W, H, T = D.W, D.H, D.T
local X0, Y0, X1, Y1 = T, T, W - T, H - T
local CX, CY = W / 2, H / 2
E.X0, E.Y0, E.X1, E.Y1, E.CX, E.CY, E.W, E.H = X0, Y0, X1, Y1, CX, CY, W, H

E.DIRS = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
E.DIRLIST = { "up", "down", "left", "right" }
E.OPP = { up = "down", down = "up", left = "right", right = "left" }
E.DOOR = { up = { CX, Y0 }, down = { CX, Y1 }, left = { X0, CY }, right = { X1, CY } }
local DIRS, DIRLIST, OPP, DOOR = E.DIRS, E.DIRLIST, E.OPP, E.DOOR

---------------------------------------------------------------------------
-- Random numbers: Park-Miller, exact in doubles (16807 * 2^31 < 2^53)
---------------------------------------------------------------------------

local MOD = 2147483647
function E.NewRng(seed)
    seed = floor(tonumber(seed) or 1) % MOD
    if seed <= 0 then seed = seed + MOD - 1 end
    return { s = seed }
end
local function R(g) g.s = (g.s * 16807) % MOD return g.s / MOD end
local function Rnd(g, a, b) return a + R(g) * (b - a) end
local function Pick(g, t) return t[floor(R(g) * #t) + 1] end
E.R, E.Rnd, E.Pick = R, Rnd, Pick

-- A seed from a text (the daily seed's date): a small string hash folded into the generator's range.
function E.SeedOf(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % MOD end
    return h
end

local function Hyp(x, y) return sqrt(x * x + y * y) end
local function Dist(a, b) return Hyp(a.x - b.x, a.y - b.y) end
E.Hyp, E.Dist = Hyp, Dist
function E.Clamp(x, y, pad)
    pad = pad or 30
    return max(X0 + pad, min(X1 - pad, x)), max(Y0 + pad, min(Y1 - pad, y))
end
function E.Near(run, x, y, r) return E.Clamp(x + Rnd(run.rng, -(r or 50), r or 50), y + Rnd(run.rng, -(r or 50), r or 50)) end

---------------------------------------------------------------------------
-- The floor: Isaac's rule (a new room may touch only one room) keeps dead ends for the boss, the vault, the shop
---------------------------------------------------------------------------

local function Key(x, y) return x .. "," .. y end

local function NewRoom(rooms, list, x, y, kind)
    local r = { x = x, y = y, type = kind, foes = {}, pickups = {}, shop = nil }
    rooms[Key(x, y)] = r
    list[#list + 1] = r
    return r
end

-- (kept per room until a secret room is found: the panel asks several times a frame; callers only read the list)
local nbCache = setmetatable({}, { __mode = "k" })
function E.Neighbours(map, r, withSecret)
    local slot, key
    if map.ready then
        slot = nbCache[r]
        if not slot then slot = {} nbCache[r] = slot end
        key = (withSecret and 1 or 0) + 2 * (map.reveals or 0)
        if slot[key] then return slot[key] end
    end
    local out = {}
    if slot then slot[key] = out end
    for _, d in ipairs(DIRLIST) do
        local o = map.rooms[Key(r.x + DIRS[d][1], r.y + DIRS[d][2])]
        -- (a secret room's doors stay hidden until a bomb opens the wall)
        local hidden = o and ((o.type == "secret" and not o.revealed) or (r.type == "secret" and not r.revealed))
        if o and (withSecret or not hidden) then out[#out + 1] = { dir = d, room = o } end
    end
    return out
end
local Nbs = E.Neighbours

function E.GenFloor(run, n)
    local g = E.NewRng(run.seed * 7 + n * 7919 + 13)
    for _ = 1, 200 do
        local rooms, list = {}, {}
        local start = NewRoom(rooms, list, 4, 4, "start")
        start.cleared, start.visited = true, true
        local want = 7 + n * 2
        local guard = 0
        while #list < want and guard < 600 do
            guard = guard + 1
            local from = Pick(g, list)
            local d = DIRS[Pick(g, DIRLIST)]
            local x, y = from.x + d[1], from.y + d[2]
            if x >= 0 and y >= 0 and x <= 8 and y <= 8 and not rooms[Key(x, y)] then
                local nb = 0
                for _, dd in ipairs(DIRLIST) do
                    if rooms[Key(x + DIRS[dd][1], y + DIRS[dd][2])] then nb = nb + 1 end
                end
                if nb <= 1 then NewRoom(rooms, list, x, y, "normal") end
            end
        end
        local map = { rooms = rooms, list = list, start = start }
        -- depth from the start
        local depth, q = { [start] = 0 }, { start }
        local qi = 1
        while q[qi] do
            local r = q[qi]
            qi = qi + 1
            for _, nb in ipairs(Nbs(map, r, true)) do
                if not depth[nb.room] then depth[nb.room] = depth[r] + 1 q[#q + 1] = nb.room end
            end
        end
        local ends = {}
        for _, r in ipairs(list) do
            if r ~= start and #Nbs(map, r, true) == 1 then ends[#ends + 1] = r end
        end
        table.sort(ends, function(a, b)
            if depth[a] ~= depth[b] then return depth[a] > depth[b] end
            return a.y * 10 + a.x < b.y * 10 + b.x
        end)
        if #ends >= 3 then
            ends[1].type = "boss"
            ends[2].type, ends[2].locked = "treasure", true
            ends[3].type = "shop"
            -- the secret room: an empty cell touching two rooms or more (never the boss's)
            local best, bestN
            for y = 0, 8 do
                for x = 0, 8 do
                    if not rooms[Key(x, y)] then
                        local nb, boss = 0, false
                        for _, dd in ipairs(DIRLIST) do
                            local o = rooms[Key(x + DIRS[dd][1], y + DIRS[dd][2])]
                            if o then nb = nb + 1 if o.type == "boss" then boss = true end end
                        end
                        if nb >= 2 and not boss and (not bestN or nb > bestN) then best, bestN = { x, y }, nb end
                    end
                end
            end
            if best then
                local s = NewRoom(rooms, list, best[1], best[2], "secret")
                s.cleared = true
            end
            map.depth = depth
            map.ready = true                  -- (built: E.Neighbours may keep its lists from now on)
            return map
        end
    end
    error("BoI: no floor")
end

---------------------------------------------------------------------------
-- A run
---------------------------------------------------------------------------

local function DrawItem(run, pool)
    local cands, any = {}, {}
    local names = {}
    for k in pairs(D.ITEMS) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
        if not run.has[k] and not run.offered[k] then
            any[#any + 1] = k
            if D.ITEMS[k].pool == pool then cands[#cands + 1] = k end
        end
    end
    local k = (#cands > 0 and Pick(run.rng, cands)) or (#any > 0 and Pick(run.rng, any)) or "blade"
    run.offered[k] = true
    return k
end
E.DrawItem = DrawItem

-- opts = { class = "MAGE", seed = n, daily = "2026-10-14" }
function E.New(opts)
    opts = opts or {}
    local cls = D.CLASSES[opts.class or "WARRIOR"] and (opts.class or "WARRIOR") or "WARRIOR"
    local c = D.CLASSES[cls]
    local seed = floor(tonumber(opts.seed) or 1)
    local run = {
        seed = seed, daily = opts.daily, class = cls, cdef = c, frame = 0, time = 0, mode = "floorcard", cardT = 150,
        hp = c.hp * 2, maxHp = c.hp, soul = c.soul or 0, gold = 3, bombs = 1, keys = 1,
        p = { x = CX, y = CY + 70, vx = 0, vy = 0, r = 15, inv = 0, cd = 0, face = "down" },
        stats = { dmg = c.dmg, delay = c.delay, speed = c.speed, range = c.range, shot = c.shot },
        items = {}, has = {}, offered = {}, tears = {}, shots = {}, bombsLive = {}, fires = {}, zaps = {}, fams = {}, fx = {},
        kills = 0, extraLife = 0, floorN = 0, deaths = {}, rng = E.NewRng(seed + 1), tookBargain = false,
    }
    E.ResetBossFx(run)
    for _, k in ipairs(c.items or {}) do E.GiveItem(run, k, true) end
    E.EnterFloor(run, 1)
    return run
end

function E.ResetBossFx(run)
    run.hz, run.patches, run.cast, run.say, run.cubes, run.traps = {}, {}, nil, nil, nil, {}
    run.mflames, run.volcs, run.beam, run.beams, run.glaives, run.maiev, run.orbs = {}, {}, nil, {}, nil, nil, {}
    run.pcaged, run.paraOn, run.bossF, run.sod, run.spirit, run.corpse = 0, 0, nil, nil, nil, nil
end

function E.EnterFloor(run, n)
    run.floorN = n
    run.F = D.FLOORS[n]
    run.rng = E.NewRng(run.seed * 31 + n * 104729)
    run.map = E.GenFloor(run, n)
    for _, r in ipairs(run.map.list) do
        if r.type == "treasure" then r.item = DrawItem(run, "vault") end
        if r.type == "shop" then
            r.cleared = true
            r.shop = { { kind = "heart", price = 3, x = CX - 110, y = CY }, { kind = R(run.rng) < 0.5 and "key" or "bomb", price = 5, x = CX, y = CY },
                       { item = DrawItem(run, "shop"), price = 15, x = CX + 110, y = CY } }
        end
        if r.type == "secret" then
            for i = 1, 4 do r.pickups[i] = { kind = Pick(run.rng, { "gold", "gold", "soul", "bomb" }), x = CX - 75 + i * 30, y = CY + 20, t = 0 } end
            if R(run.rng) < 0.5 then r.item = DrawItem(run, "vault") end
        end
    end
    run.room = run.map.start
    run.p.x, run.p.y = CX, CY
    run.tears, run.shots, run.bombsLive, run.fires, run.zaps, run.fx = {}, {}, {}, {}, {}, {}
    E.ResetBossFx(run)
    run.mode, run.cardT = "floorcard", 150
    run.shield = run.has.pws
end

function E.GiveItem(run, k, quiet)
    local it = D.ITEMS[k]
    if not it then return end
    if it.active then
        run.active, run.charge, run.chargeMax = k, it.active, it.active
    else
        run.items[#run.items + 1] = k
        run.has[k] = true
    end
    run.offered[k] = true
    local st = run.stats
    if k == "sprint" then st.speed = st.speed + 0.7 end
    if k == "mongoose" then st.delay = max(6, st.delay - 5) end
    if k == "soulstone" then run.extraLife = run.extraLife + 1 end
    if k == "glaive" then st.range = st.range + 10 end
    if k == "blade" then st.dmg = st.dmg + 0.8 end
    if k == "imp" or k == "fiend" then run.fams[#run.fams + 1] = { k = k, x = run.p.x, y = run.p.y, cd = 0 } end
    if k == "pws" then run.shield = true end
    if not quiet then run.banner = { n = it.n, t = it.t, q = it.q, life = 170 } end
end

local function MkFoe(run, kind, x, y)
    local d = D.FOES[kind]
    local scale = 1 + (run.floorN - 1) * 0.25
    return { kind = kind, d = d, x = x, y = y, vx = 0, vy = 0, hp = d.hp * scale, max = d.hp * scale, r = d.r,
             t = floor(R(run.rng) * 90), flash = 0, state = 0, spiritOnly = d.spiritOnly }
end
E.MkFoe = MkFoe

local function SpawnFoes(run, room)
    local n = 3 + min(run.floorN, 4) + floor(R(run.rng) * 3)
    for _ = 1, n do
        local kind = Pick(run.rng, run.F.foes)
        local x, y
        for _ = 1, 40 do
            x, y = Rnd(run.rng, X0 + 40, X1 - 40), Rnd(run.rng, Y0 + 40, Y1 - 40)
            if Hyp(x - run.p.x, y - run.p.y) >= 170 then break end
        end
        room.foes[#room.foes + 1] = MkFoe(run, kind, x, y)
    end
end

local function SpawnBoss(run, room)
    local key = run.F.boss
    local b = D.BOSSES[key]
    E.ResetBossFx(run)
    local f = { kind = "boss", key = key, d = { n = b.n, i = b.ej, ej = true, ai = "boss" }, boss = b, x = CX, y = CY - 40,
                vx = 0, vy = 0, hp = b.hp, max = b.hp, r = b.r, t = 0, flash = 0, phase = 1 }
    room.foes[#room.foes + 1] = f
    run.bossF = f
    ns.BoIBosses.Init[key](run, f, room)
    run.mode, run.cardT = "vs", 110
end

function E.ChangeRoom(run, dir)
    local d = DIRS[dir]
    local nr = run.map.rooms[Key(run.room.x + d[1], run.room.y + d[2])]
    if not nr then return end
    run.room = nr
    run.tears, run.shots, run.bombsLive, run.fires, run.zaps, run.fx = {}, {}, {}, {}, {}, {}
    E.ResetBossFx(run)
    local p = run.p
    if dir == "left" then p.x, p.y = X1 - 30, CY end
    if dir == "right" then p.x, p.y = X0 + 30, CY end
    if dir == "up" then p.x, p.y = CX, Y1 - 30 end
    if dir == "down" then p.x, p.y = CX, Y0 + 30 end
    for _, fm in ipairs(run.fams) do fm.x, fm.y = p.x, p.y end
    run.fade = 14
    run.shield = run.has.pws
    run.madness = nil
    if run.has.madness then
        run.madness = Pick(run.rng, { { "dmg", "Damage up for this room" }, { "tears", "Tears up for this room" }, { "speed", "Speed up for this room" } })
        run.toast = { t = run.madness[2], life = 120 }
    end
    if not nr.visited then
        nr.visited = true
        if nr.type == "normal" then SpawnFoes(run, nr) end
        if nr.type == "boss" then SpawnBoss(run, nr) end
        if #nr.foes == 0 then nr.cleared = true end
    end
end

local function RoomCleared(run, room)
    room.cleared = true
    if run.active and run.charge < run.chargeMax then run.charge = run.charge + 1 end
    if room.type == "boss" then
        E.ResetBossFx(run)
        room.trapdoor = { x = CX, y = CY + 50 }
        room.item = DrawItem(run, "boss")
        room.pedestal = { x = CX, y = CY - 60 }
        -- a deal after the boss: a fel bargain (an item for healthstones), or the Naaru's free gift if you never bargained
        local roll = R(run.rng)
        if roll < 0.55 then
            if not run.tookBargain and roll < 0.2 then
                room.deal = { kind = "naaru", item = DrawItem(run, "naaru"), x = CX + 140, y = CY - 60 }
            else
                room.deal = { kind = "bargain", item = DrawItem(run, "bargain"), price = 1, x = CX - 140, y = CY - 60 }
            end
        end
        run.toast = { t = run.bossName and (run.bossName .. " is dead") or "The boss is dead", life = 120 }
        return
    end
    if R(run.rng) < 0.8 then
        local kind = Pick(run.rng, { "heart", "heart", "gold", "gold", "gold", "key", "bomb", "bomb", "soul" })
        room.pickups[#room.pickups + 1] = { kind = kind, x = CX + Rnd(run.rng, -40, 40), y = CY + Rnd(run.rng, -30, 30), t = 0 }
    end
end

function E.Hurt(run, by, n)
    n = n or 1
    local p = run.p
    if p.inv > 0 or run.mode ~= "play" or run.spirit or run.meta then return end
    run.takenBy = run.takenBy or {}
    local src = by and by.n or "?"
    run.takenBy[src] = (run.takenBy[src] or 0) + n
    if run.god then   -- (tests and the balance bot: the hit is counted, as if taken, but nothing is lost)
        run.taken, p.inv = (run.taken or 0) + n, 70
        return
    end
    run.taken = (run.taken or 0) + n
    if run.shield then run.shield = false p.inv = 50 return end
    if run.soul > 0 then
        local s = min(run.soul, n)
        run.soul, n = run.soul - s, n - s
    end
    run.hp = run.hp - n
    p.inv, run.shake = 70, 8
    run.hits = (run.hits or 0) + 1
    if run.hp <= 0 then
        if run.extraLife > 0 then
            run.extraLife = run.extraLife - 1
            for i, k in ipairs(run.items) do if k == "soulstone" then table.remove(run.items, i) break end end
            run.has.soulstone = nil
            run.hp = 2
            run.toast = { t = "The Soulstone pulls you back", life = 120 }
            return
        end
        -- the death: a moment of slow motion (the room goes on at a third of its speed, then holds), the card after
        run.mode, run.dyingT = "dying", 0
        run.killer = by and by.n or "something"
        run.killerIcon, run.killerEj = by and by.i, by and by.ej
        run.diedAt = { x = p.x, y = p.y }
        run.shake = 16
        local best   -- the one that did it: the nearest of its kind
        for _, f in ipairs(run.room.foes) do
            if f.d == by and (not best or E.Dist(f, p) < E.Dist(best, p)) then best = f end
        end
        run.killerFoe = best
    end
end
E.DYING = 170   -- frames from the killing blow to the card
local Hurt = E.Hurt

-- a short effect where something ended: "splash" (a tear), "pop" (a shot), "die" (an enemy: o = the enemy)
function E.Fx(run, kind, x, y, r, col, frames, o)
    local fx = run.fx
    if not fx then return end
    if #fx > 120 then table.remove(fx, 1) end
    fx[#fx + 1] = { k = kind, x = x, y = y, r = r, col = col, t = 0, max = frames, o = o }
end

-- the stain an enemy leaves: fel green for demons, bone grey for the dead, shadow for shades, blood for the rest
local ICHOR = { demon = { 0.35, 0.75, 0.12 }, undead = { 0.45, 0.45, 0.42 }, shadow = { 0.35, 0.18, 0.55 }, fire = { 0.45, 0.2, 0.05 },
                blood = { 0.45, 0.04, 0.03 } }
local KIND_ICHOR = { imp = "demon", felhunter = "demon", void = "shadow", sdemon = "shadow", parasite = "shadow", construct = "shadow",
                     blossom = "shadow", dead = "undead", abyssal = "fire", azflame = "demon", mchan = "blood", channeler = "blood",
                     watcher = "shadow", priestess = "blood", brute = "blood", bat = "blood", spider = "blood", sheep = "blood" }
function E.Die(run, room, f)
    local ichor = KIND_ICHOR[f.kind] or (f.kind == "boss" and "demon") or "blood"
    local col = ICHOR[ichor]
    E.Fx(run, "die", f.x, f.y, f.r, col, f.kind == "boss" and 70 or 26,
         { i = f.d.i, ej = f.d.ej, boss = f.kind == "boss", ring = f.kind == "boss" and { 1, 0.23, 0.18 } or { 0.48, 0.1, 0.07 } })
    room.decals = room.decals or {}
    if #room.decals > 24 then table.remove(room.decals, 1) end
    room.decals[#room.decals + 1] = { x = f.x, y = f.y, r = f.r * (f.kind == "boss" and 1.8 or 1.15), col = col, t = 0,
                                      ichor = ichor, seed = floor(f.x * 7 + f.y * 13) % 97 }
end

local function Shoot(run, f, ang, sp, r, col, by)
    run.shots[#run.shots + 1] = { x = f.x, y = f.y, vx = cos(ang) * (sp or 3.2), vy = sin(ang) * (sp or 3.2), life = 240,
                                  r = r or 7, col = col or { 0.49, 1, 0.29 }, by = by or f.d }
end
E.Shoot = Shoot

local function Fire(run, dir)
    local st, p = run.stats, run.p
    local d = DIRS[dir]
    local dmg = st.dmg
    if run.madness and run.madness[1] == "dmg" then dmg = dmg * 1.5 end
    if run.meta then dmg = dmg * 3 end
    local sp = st.shot
    run.tears[#run.tears + 1] = {
        x = p.x + d[1] * 10, y = p.y + d[2] * 10 - 4, vx = d[1] * sp + p.vx * 0.4, vy = d[2] * sp + p.vy * 0.4,
        life = st.range, max = st.range, dmg = dmg, r = 6 + min(4, max(0, dmg - 3)), col = run.spirit and { 0.6, 0.9, 1 } or run.cdef.tear,
        pierce = run.has.glaive, homing = run.has.eye or run.spirit, spirit = run.spirit and true or nil, grow = run.has.orb, hit = {},
    }
    p.face = dir
end

---------------------------------------------------------------------------
-- Enemies
---------------------------------------------------------------------------

local function FoeAI(run, f, p)
    if f.stun and f.stun > 0 and f.kind ~= "boss" then   -- the pause after a body hit (a boss's mechanics go on: it only stands)
        f.stun = f.stun - 1
        f.vx, f.vy = f.vx * 0.8, f.vy * 0.8
        f.x, f.y = f.x + f.vx, f.y + f.vy
        return
    end
    f.t = f.t + 1
    local dx, dy = p.x - f.x, p.y - f.y
    local d = Hyp(dx, dy)
    if d == 0 then d = 1 end
    local ai = f.d.ai
    local sp = f.spd or f.d.sp or 0
    if f.slow and f.slow > 0 then f.slow = f.slow - 1 sp = sp * 0.5 end
    -- a spirit is not chased: the constructs go for your body
    local tx, ty = p.x, p.y
    if run.spirit and run.corpse then tx, ty = run.corpse.x, run.corpse.y dx, dy = tx - f.x, ty - f.y d = max(1, Hyp(dx, dy)) end
    if ai == "chase" then
        f.vx = f.vx + (dx / d * sp - f.vx) * 0.08
        f.vy = f.vy + (dy / d * sp - f.vy) * 0.08
    elseif ai == "flit" then
        local w = sin(f.t * 0.12) * 2.2
        f.vx, f.vy = dx / d * sp - dy / d * w, dy / d * sp + dx / d * w
    elseif ai == "wander" then
        if f.t % 60 == 0 then f.wa = Rnd(run.rng, 0, 2 * pi) end
        f.vx, f.vy = cos(f.wa or 0) * sp, sin(f.wa or 0) * sp
    elseif ai == "hop" then
        if f.t % 70 == 0 then f.vx, f.vy = dx / d * sp + Rnd(run.rng, -1.5, 1.5), dy / d * sp + Rnd(run.rng, -1.5, 1.5) end
        f.vx, f.vy = f.vx * 0.9, f.vy * 0.9
    elseif ai == "dash" then
        if f.state > 0 then f.state = f.state - 1
        elseif f.t % 110 == 0 then f.vx, f.vy, f.state = dx / d * sp, dy / d * sp, 22 end
        if f.state == 0 then f.vx, f.vy = f.vx * 0.85 + dx / d * 0.05, f.vy * 0.85 + dy / d * 0.05 end
    elseif ai == "turret" then
        f.vx, f.vy = 0, 0
        if f.t % 100 == 0 then
            local off = (floor(f.t / 100) % 2 == 1) and pi / 4 or 0
            for k = 0, 3 do Shoot(run, f, off + k * pi / 2, 2.6, 7, f.d.col) end
        end
    elseif ai == "blossom" then   -- Doom Blossom: drifts, a shadow bolt at you now and then
        f.vx, f.vy = cos(f.t * 0.02) * sp, sin(f.t * 0.03) * sp
        if f.t % 120 == 60 then Shoot(run, f, atan2(dy, dx), 2.8, 7, { 0.6, 0.4, 1 }) end
    elseif ai == "mchan" then     -- Hellfire Channeler: Shadow Bolt Volley; in phase 1 a Burning Abyssal dropped on you
        f.vx, f.vy = 0, 0
        f.rate = f.rate or 220
        if f.t % floor(f.rate + 0.5) == 0 then Shoot(run, f, atan2(dy, dx), 2.4, 7, { 0.69, 0.42, 1 }, { n = "Shadow Bolt Volley" }) end
    elseif ai == "boss" then
        ns.BoIBosses.AI[f.key](run, f, p, dx, dy, d)
    end
    if f.d.trail and f.t % 40 == 0 then E.Patch(run, f.x, f.y, 13, 260, f.d.trail) end
    if f.kind == "boss" and f.stun and f.stun > 0 then f.stun, f.vx, f.vy = f.stun - 1, 0, 0 end
    f.x, f.y = f.x + f.vx, f.y + f.vy
    f.x = max(X0 + f.r, min(X1 - f.r, f.x))
    f.y = max(Y0 + f.r, min(Y1 - f.r, f.y))
    if ai ~= "wander" and not f.noTouch and Hyp(f.x - p.x, f.y - p.y) < f.r + p.r - 4 then
        if not run.spirit then
            local inv0 = p.inv
            Hurt(run, f.d, f.touch or f.d.hard or (f.kind == "boss" and 2 or 1))
            if p.inv > inv0 then   -- a hit: you are thrown off it and it pauses (or a big body pins you and hits again and again)
                f.stun = 40
                -- away from it and a little towards the room's middle: a corner never pins you against a big body
                local kd = max(1, Hyp(p.x - f.x, p.y - f.y))
                local cd = max(1, Hyp(CX - p.x, CY - p.y))
                local kx, ky = (p.x - f.x) / kd + (CX - p.x) / cd * 0.7, (p.y - f.y) / kd + (CY - p.y) / cd * 0.7
                local kl = max(0.01, Hyp(kx, ky))
                p.vx, p.vy = kx / kl * 8, ky / kl * 8
                p.x, p.y = p.x + kx / kl * 16, p.y + ky / kl * 16
            end
        end
        if run.has.thorns and run.frame % 8 == 0 and not f.immune then f.hp, f.flash = f.hp - 3, 5 end
    end
end

---------------------------------------------------------------------------
-- Boss helpers (Games/Illidan/Bosses.lua uses them)
---------------------------------------------------------------------------

-- a telegraphed hit: a circle that fills over `delay` frames, then hurts whoever stands in it.
-- o = { col, dmg, boom, fire (a patch's life), by, then = function(h) }
function E.Hz(run, x, y, r, delay, o)
    o = o or {}
    local h = { x = x, y = y, r = r, delay = delay, t = 0, col = o.col or { 1, 0.35, 0.16 }, dmg = o.dmg or 1,
                boom = o.boom, fire = o.fire, by = o.by or (run.bossF and run.bossF.d) or { n = "the floor" }, after = o["then"] }
    run.hz[#run.hz + 1] = h
    return h
end
function E.Patch(run, x, y, r, life, col, by)
    run.patches[#run.patches + 1] = { x = x, y = y, r = r, life = life, max = life, col = col,
                                      by = by or (run.bossF and run.bossF.d) or { n = "fire" } }
end
function E.Say(run, who, text, kind) run.say = { who = who, text = text, kind = kind or "yell", life = 220 } end
function E.Cast(run, name, icon, frames, done) run.cast = { name = name, icon = icon, t = 0, max = frames, done = done } end
function E.Toast(run, text, life) run.toast = { t = text, life = life or 120 } end
function E.Chase(run, f, sp, k)
    local p = run.p
    local dx, dy = p.x - f.x, p.y - f.y
    local d = max(1, Hyp(dx, dy))
    k = k or 0.06
    f.vx = f.vx + (dx / d * sp - f.vx) * k
    f.vy = f.vy + (dy / d * sp - f.vy) * k
end
function E.MoveTo(f, x, y, sp)
    local dx, dy = x - f.x, y - f.y
    local d = Hyp(dx, dy)
    if d < sp then f.vx, f.vy = 0, 0 return true end
    f.vx, f.vy = dx / d * sp, dy / d * sp
    return false
end
local function InCone(run, f, ang, reach, half)
    local dx, dy = run.p.x - f.x, run.p.y - f.y
    local a = atan2(dy, dx) - ang
    a = atan2(sin(a), cos(a))
    return Hyp(dx, dy) < reach and abs(a) < half
end
-- a frontal swing (Cleave, Shear, Saber Lash): the cone shows for half a second, then hits
function E.Cleave(run, f, cd, dmg)
    if f.swing then
        f.swing.t = f.swing.t + 1
        if f.swing.t == 32 and InCone(run, f, f.swing.a, f.r + 80, 0.75) then Hurt(run, f.d, dmg or 2) end
        if f.swing.t > 40 then f.swing = nil end
        return
    end
    f.swingCd = (f.swingCd or 0) - 1
    if f.swingCd <= 0 and Hyp(run.p.x - f.x, run.p.y - f.y) < f.r + 60 then
        f.swing = { t = 0, a = atan2(run.p.y - f.y, run.p.x - f.x) }
        f.swingCd = cd
    end
end
-- distance from point (px, py) to the segment a-b
function E.SegDist(px, py, ax, ay, bx, by)
    local vx, vy = bx - ax, by - ay
    local l2 = vx * vx + vy * vy
    local k = l2 > 0 and max(0, min(1, ((px - ax) * vx + (py - ay) * vy) / l2)) or 0
    return Hyp(px - (ax + vx * k), py - (ay + vy * k))
end

local function BossFx(run)
    local p = run.p
    local keep = {}
    for _, h in ipairs(run.hz) do
        h.t = h.t + 1
        if h.t == h.delay then
            if Hyp(p.x - h.x, p.y - h.y) < h.r + p.r * 0.5 then Hurt(run, h.by, h.dmg) end
            if h.boom then run.zaps[#run.zaps + 1] = { boom = true, x = h.x, y = h.y, life = 14, col = h.col } end
            if h.fire then E.Patch(run, h.x, h.y, h.r * 0.9, h.fire, h.col, h.by) end
            if h.after then h.after(h) end
        else
            keep[#keep + 1] = h
        end
    end
    run.hz = keep
    keep = {}
    for _, q in ipairs(run.patches) do
        q.life = q.life - 1
        if Hyp(p.x - q.x, p.y - q.y) < q.r + p.r * 0.4 then Hurt(run, q.by) end
        if q.life > 0 then keep[#keep + 1] = q end
    end
    run.patches = keep
    keep = {}
    for _, m in ipairs(run.mflames) do   -- Molten Flame crawls along the floor at you, burning as it goes
        local dx, dy = p.x - m.x, p.y - m.y
        local d = max(1, Hyp(dx, dy))
        m.vx = m.vx + (dx / d * 1.7 - m.vx) * 0.03
        m.vy = m.vy + (dy / d * 1.7 - m.vy) * 0.03
        m.x, m.y, m.life = m.x + m.vx, m.y + m.vy, m.life - 1
        if m.life % 10 == 0 then E.Patch(run, m.x, m.y, 12, 110, { 0.31, 0.72, 1 }, { n = "Molten Flame" }) end
        if d < p.r + 10 then Hurt(run, { n = "Molten Flame" }) m.life = 0 end
        if m.life > 0 then keep[#keep + 1] = m end
    end
    run.mflames = keep
    keep = {}
    for _, v in ipairs(run.volcs) do
        v.life = v.life - 1
        if v.life % 7 == 0 then
            run.shots[#run.shots + 1] = { x = v.x, y = v.y, vx = Rnd(run.rng, -2.4, 2.4), vy = Rnd(run.rng, -2.4, 2.4), life = 55, r = 6,
                                          col = { 1, 0.54, 0.24 }, by = { n = "Volcanic Geyser" } }
        end
        if v.life > 0 then keep[#keep + 1] = v end
    end
    run.volcs = keep
    if run.beam then   -- Eye Blast: a line warned, then a beam sweeping it and leaving fel fire
        local b = run.beam
        b.t = b.t + 1
        if b.t > b.warn then
            local k = (b.t - b.warn) / b.run
            local hx, hy = b.ax + (b.bx - b.ax) * k, b.ay + (b.by - b.ay) * k
            if b.t % 8 == 0 then E.Patch(run, hx, hy, 22, 420, { 0.49, 1, 0.23 }, { n = "Eye Blast" }) end
            if Hyp(p.x - hx, p.y - hy) < 26 then Hurt(run, { n = "Eye Blast" }) end
            if k >= 1 then run.beam = nil end
        end
    end
    keep = {}
    for _, b in ipairs(run.beams) do   -- Shahraz's beams: a line from her, warned, then a flash along it
        b.t = b.t + 1
        if b.t == b.warn then
            if E.SegDist(p.x, p.y, b.ax, b.ay, b.bx, b.by) < 18 + p.r * 0.4 then
                Hurt(run, { n = b.n })
                if b.kind == "sinful" then run.slowed = 150 end
                if b.kind == "wicked" and run.bossF then run.bossF.hp = min(run.bossF.max, run.bossF.hp + 12) end
            end
            if b.kind == "vile" then
                for k = 1, 5 do E.Patch(run, b.ax + (b.bx - b.ax) * k / 6, b.ay + (b.by - b.ay) * k / 6, 14, 300, b.col, { n = b.n }) end
            end
        end
        if b.t < b.warn + 12 then keep[#keep + 1] = b end
    end
    run.beams = keep
    keep = {}
    for _, o in ipairs(run.orbs) do o.t = o.t + 1 if o.t < o.max then keep[#keep + 1] = o end end
    run.orbs = keep
    keep = {}
    for _, t in ipairs(run.traps) do
        if t.arm > 0 then t.arm = t.arm - 1
        elseif not t.forBoss and Hyp(p.x - t.x, p.y - t.y) < p.r + 8 then
            t.used = true
            run.pcaged = 80
            Hurt(run, { n = "Cage Trap" })
        end
        if not t.used then keep[#keep + 1] = t end
    end
    run.traps = keep
    if run.paraOn > 0 then
        run.paraOn = run.paraOn - 1
        if run.paraOn == 0 then
            for _, o in ipairs({ -22, 22 }) do run.room.foes[#run.room.foes + 1] = MkFoe(run, "parasite", p.x + o, p.y + 10) end
        end
    end
    if run.cast then
        run.cast.t = run.cast.t + 1
        if run.cast.t >= run.cast.max then
            local c = run.cast
            run.cast = nil
            if c.done then c.done() end
        end
    end
end

---------------------------------------------------------------------------
-- One frame
---------------------------------------------------------------------------

local function UseActive(run)
    if not run.active or run.charge < run.chargeMax then return end
    local p = run.p
    if run.active == "blink" then
        local mx, my = p.vx, p.vy
        local l = Hyp(mx, my)
        if l < 0.3 then local d = DIRS[p.face] mx, my, l = d[1], d[2], 1 end
        p.x, p.y = E.Clamp(p.x + mx / l * 130, p.y + my / l * 130, p.r)
        p.inv = max(p.inv, 30)
    elseif run.active == "meta" then
        run.meta = 360
    end
    run.charge = 0
end

local function Pickups(run, room, p)
    local keep = {}
    for _, k in ipairs(room.pickups) do
        k.t = k.t + 1
        local take = Hyp(k.x - p.x, k.y - p.y) < p.r + 12
        if take and k.kind == "heart" and run.hp >= run.maxHp * 2 then take = false end
        if take then
            if k.kind == "heart" then run.hp = min(run.maxHp * 2, run.hp + 2) end
            if k.kind == "soul" then run.soul = run.soul + 2 end
            if k.kind == "gold" then run.gold = run.gold + 1 end
            if k.kind == "key" then run.keys = run.keys + 1 end
            if k.kind == "bomb" then run.bombs = run.bombs + 1 end
        else
            keep[#keep + 1] = k
        end
    end
    room.pickups = keep
    -- the pedestal: the vault's, the secret room's, the boss's reward
    local ped = (room.type == "treasure" or room.type == "secret") and { x = CX, y = CY - 30 } or room.pedestal
    if ped and room.item and Hyp(ped.x - p.x, ped.y - p.y) < p.r + 22 then E.GiveItem(run, room.item) room.item = nil end
    local deal = room.deal
    if deal and deal.item and Hyp(deal.x - p.x, deal.y - p.y) < p.r + 22 then
        if deal.kind == "naaru" then
            E.GiveItem(run, deal.item) deal.item = nil
        elseif run.maxHp > 1 then
            run.maxHp = run.maxHp - deal.price
            run.hp = min(run.hp, run.maxHp * 2)
            run.tookBargain = true
            E.GiveItem(run, deal.item) deal.item = nil
        elseif not run.toast then
            E.Toast(run, "You can't pay with your last healthstone", 90)
        end
    end
    for _, s in ipairs(room.shop or {}) do
        if not s.sold and Hyp(s.x - p.x, s.y - p.y) < p.r + 18 then
            if run.gold >= s.price then
                local ok = true
                if s.kind == "heart" then if run.hp >= run.maxHp * 2 then ok = false else run.hp = min(run.maxHp * 2, run.hp + 2) end end
                if s.kind == "key" then run.keys = run.keys + 1 end
                if s.kind == "bomb" then run.bombs = run.bombs + 1 end
                if s.item then E.GiveItem(run, s.item) end
                if ok then run.gold, s.sold = run.gold - s.price, true end
            elseif not run.toast then
                E.Toast(run, string.format("%d gold", s.price), 60)
            end
        end
    end
    -- a guildmate's grave on today's dungeon: who fell here and to what (and the gold they dropped)
    for _, g in ipairs(run.graves or {}) do
        if g.f == run.floorN and g.rx == room.x and g.ry == room.y and not g.read and Hyp(g.x - p.x, g.y - p.y) < p.r + 14 then
            g.read = true
            run.gold = run.gold + 1
            E.Toast(run, string.format("%s fell here to %s", g.who, g.by or "something"), 170)
        end
    end
    if room.trapdoor and Hyp(room.trapdoor.x - p.x, room.trapdoor.y - p.y) < 20 then
        if run.floorN < #D.FLOORS then E.EnterFloor(run, run.floorN + 1)
        else
            run.mode = "won"
            if run.onEnd then run.onEnd(run) end
        end
    end
end

local function Doors(run, room, p)
    for _, nb in ipairs(Nbs(run.map, room)) do
        local dir, other = nb.dir, nb.room
        local dx, dy = DOOR[dir][1], DOOR[dir][2]
        local inGap = (dir == "up" or dir == "down") and abs(p.x - dx) < 26 or abs(p.y - dy) < 26
        local atEdge = (dir == "up" and p.y - p.r < Y0 + 4) or (dir == "down" and p.y + p.r > Y1 - 4)
            or (dir == "left" and p.x - p.r < X0 + 4) or (dir == "right" and p.x + p.r > X1 - 4)
        if inGap and atEdge and room.cleared then
            if other.locked then
                if run.keys > 0 then run.keys, other.locked = run.keys - 1, nil E.Toast(run, "Unlocked the vault", 90)
                elseif not run.toast then E.Toast(run, "Locked. You need a key.", 90) end
            else
                E.ChangeRoom(run, dir)
                return true
            end
        end
    end
end

function E.Step(run, input)
    input = input or {}
    run.frame = run.frame + 1
    if run.mode == "floorcard" or run.mode == "vs" then
        run.cardT = run.cardT - 1
        if run.cardT <= 0 then run.mode = "play" end
        return
    end
    if run.mode == "dead" then run.deadT = (run.deadT or 0) + 1 return end
    if run.mode == "won" then run.wonT = (run.wonT or 0) + 1 return end
    local dying = run.mode == "dying"
    if dying then
        run.dyingT = run.dyingT + 1
        if run.shake and run.shake > 0 then run.shake = run.shake - 1 end
        if run.dyingT >= E.DYING then
            run.mode, run.deadT = "dead", 0
            if run.onEnd then run.onEnd(run) end
            return
        end
        -- the room goes on at a third of its speed for a second, then holds still; you no longer act
        if run.dyingT > 66 or run.dyingT % 3 ~= 0 then return end
        input = {}
    elseif run.mode ~= "play" then
        return
    else
        run.time = run.time + 1
    end
    local p, st, room = run.p, run.stats, run.room
    if run.fade and run.fade > 0 then run.fade = run.fade - 1 end
    -- move
    local mx, my = input.mx or 0, input.my or 0
    if run.pcaged > 0 then run.pcaged = run.pcaged - 1 mx, my, p.vx, p.vy = 0, 0, 0, 0 end
    local l = Hyp(mx, my)
    if l < 1 then l = 1 end
    local spd = st.speed * (run.madness and run.madness[1] == "speed" and 1.25 or 1)
    if run.slowed and run.slowed > 0 then run.slowed = run.slowed - 1 spd = spd * 0.6 end
    p.vx = p.vx + (mx / l * spd - p.vx) * 0.28
    p.vy = p.vy + (my / l * spd - p.vy) * 0.28
    p.x, p.y = p.x + p.vx, p.y + p.vy
    if not dying and Doors(run, room, p) then return end
    p.x = max(X0 + p.r, min(X1 - p.r, p.x))
    p.y = max(Y0 + p.r, min(Y1 - p.r, p.y))
    -- shoot
    if p.cd > 0 then p.cd = p.cd - 1 end
    local sd = input.shoot
    local delay = st.delay * (run.madness and run.madness[1] == "tears" and 0.7 or 1)
    if sd and DIRS[sd] and p.cd <= 0 then Fire(run, sd) p.cd = delay end
    if sd and DIRS[sd] then p.face = sd end
    for i, fm in ipairs(run.fams) do   -- the familiars follow and shoot with you
        local tx, ty = p.x - 30 + (i - 1) * 60, p.y + 18
        fm.x, fm.y = fm.x + (tx - fm.x) * 0.12, fm.y + (ty - fm.y) * 0.12
        fm.cd = fm.cd - 1
        if sd and DIRS[sd] and fm.cd <= 0 then
            local d = DIRS[sd]
            run.tears[#run.tears + 1] = { x = fm.x, y = fm.y, vx = d[1] * 6.5, vy = d[2] * 6.5, life = 40, max = 40, dmg = 2, r = 5,
                                          col = fm.k == "imp" and { 1, 0.55, 0.2 } or { 0.78, 0.6, 1 }, hit = {} }
            fm.cd = 26
        end
    end
    if run.has.elemental then   -- Water Elemental: circles you, eats shots, bumps into enemies
        local a = run.frame * 0.05
        run.orbital = { x = p.x + cos(a) * 40, y = p.y + sin(a) * 40 }
    else
        run.orbital = nil
    end
    if p.inv > 0 then p.inv = p.inv - 1 end
    if run.shake and run.shake > 0 then run.shake = run.shake - 1 end
    if run.meta then run.meta = run.meta - 1 if run.meta <= 0 then run.meta = nil end end
    if input.use then UseActive(run) end
    -- bombs
    if input.bomb and run.bombs > 0 then run.bombs = run.bombs - 1 run.bombsLive[#run.bombsLive + 1] = { x = p.x, y = p.y + 6, t = 80 } end
    local keep = {}
    for _, b in ipairs(run.bombsLive) do
        b.t = b.t - 1
        if b.t == 0 then
            run.zaps[#run.zaps + 1] = { boom = true, x = b.x, y = b.y, life = 18 }
            run.shake = 10
            for _, f in ipairs(room.foes) do
                if not f.immune and Hyp(f.x - b.x, f.y - b.y) < 95 + f.r then f.hp, f.flash = f.hp - 18, 8 end
            end
            if Hyp(p.x - b.x, p.y - b.y) < 80 then Hurt(run, { n = "your own Goblin Bomb" }, 2) end
            -- a cracked wall next to the secret room opens
            for _, nb in ipairs(Nbs(run.map, room, true)) do
                if nb.room.type == "secret" and not nb.room.revealed then
                    local dp = DOOR[nb.dir]
                    if Hyp(b.x - dp[1], b.y - dp[2]) < 90 then nb.room.revealed = true run.map.reveals = (run.map.reveals or 0) + 1 E.Toast(run, "A secret room", 100) end
                end
            end
        else
            keep[#keep + 1] = b
        end
    end
    run.bombsLive = keep
    -- tears
    keep = {}
    for _, t in ipairs(run.tears) do
        if t.homing and #room.foes > 0 then
            local best, bd
            for _, f in ipairs(room.foes) do
                local dd = Hyp(f.x - t.x, f.y - t.y)
                if not f.immune and (not bd or dd < bd) then best, bd = f, dd end
            end
            if best and bd < 260 then
                local sp = Hyp(t.vx, t.vy)
                t.vx, t.vy = t.vx + (best.x - t.x) / bd * 0.6, t.vy + (best.y - t.y) / bd * 0.6
                local ns2 = Hyp(t.vx, t.vy)
                t.vx, t.vy = t.vx * sp / ns2, t.vy * sp / ns2
            end
        end
        if t.pierce then
            if t.life == floor(t.max / 2) then t.vx, t.vy, t.hit = -t.vx, -t.vy, {} end
            if t.life < t.max / 2 then
                local dx, dy = p.x - t.x, p.y - t.y
                local dd, sp = max(1, Hyp(dx, dy)), Hyp(t.vx, t.vy)
                t.vx, t.vy = dx / dd * sp, dy / dd * sp
                if dd < 16 then t.life = 0 end
            end
        end
        if t.grow then t.r, t.dmg = min(14, t.r + 0.08), t.dmg + 0.015 end
        t.x, t.y, t.life = t.x + t.vx, t.y + t.vy, t.life - 1
        if t.x < X0 or t.x > X1 or t.y < Y0 or t.y > Y1 then
            if t.pierce then t.vx, t.vy = -t.vx, -t.vy else t.life = 0 end
        end
        for _, f in ipairs(room.foes) do
            if t.life > 0 and not t.hit[f] and Hyp(f.x - t.x, f.y - t.y) < f.r + t.r then
                t.hit[f] = true
                if f.immune or (f.spiritOnly and not t.spirit) then
                    if not t.pierce then t.life = 0 end
                else
                    f.hp, f.flash = f.hp - t.dmg * (f.caged and 2 or 1), 6
                    run.dealt = (run.dealt or 0) + t.dmg
                    if f.kind ~= "boss" then f.x, f.y = f.x + t.vx * 0.9, f.y + t.vy * 0.9 end
                    if run.cdef.slow then f.slow = 90 end
                    if run.has.poly and f.kind ~= "boss" and f.kind ~= "sheep" and not f.d.spiritOnly and R(run.rng) < 0.1 then
                        local s = MkFoe(run, "sheep", f.x, f.y)
                        for k2, v in pairs(s) do f[k2] = v end
                    end
                    if run.has.chain then
                        local o, od = nil, 170
                        for _, f2 in ipairs(room.foes) do
                            local dd = Hyp(f2.x - f.x, f2.y - f.y)
                            if f2 ~= f and not f2.immune and dd < od then o, od = f2, dd end
                        end
                        if o then
                            o.hp, o.flash = o.hp - t.dmg * 0.4, 6
                            run.zaps[#run.zaps + 1] = { x1 = f.x, y1 = f.y, x2 = o.x, y2 = o.y, life = 9 }
                        end
                    end
                    if not t.pierce then t.life = 0 end
                end
            end
        end
        if t.life <= 0 and run.has.sulfuras then run.fires[#run.fires + 1] = { x = t.x, y = t.y, life = 110 } end
        if t.life > 0 then keep[#keep + 1] = t else E.Fx(run, "splash", t.x, t.y, t.r, t.col, 16) end
    end
    run.tears = keep
    keep = {}
    for _, fi in ipairs(run.fires) do
        fi.life = fi.life - 1
        for _, f in ipairs(room.foes) do
            if not f.immune and Hyp(f.x - fi.x, f.y - fi.y) < f.r + 14 then
                f.hp = f.hp - 0.07
                if run.frame % 10 == 0 then f.flash = 3 end
            end
        end
        if fi.life > 0 then keep[#keep + 1] = fi end
    end
    run.fires = keep
    -- enemies
    for _, f in ipairs(room.foes) do FoeAI(run, f, p) end
    for _, f in ipairs(room.foes) do if f.flash > 0 then f.flash = f.flash - 1 end end
    if run.orbital then
        for _, f in ipairs(room.foes) do
            if not f.immune and Hyp(f.x - run.orbital.x, f.y - run.orbital.y) < f.r + 12 and run.frame % 6 == 0 then f.hp, f.flash = f.hp - 1.5, 4 end
        end
    end
    local dead, alive = {}, {}
    for _, f in ipairs(room.foes) do
        if f.hp <= 0 then dead[#dead + 1] = f else alive[#alive + 1] = f end
    end
    if #dead > 0 then
        run.kills = run.kills + #dead
        local bossDied, chanDied = false, false
        for _, f in ipairs(dead) do
            if f.kind == "boss" then bossDied = true run.bossName = f.d.n end
            E.Die(run, room, f)
            if f.kind == "mchan" then chanDied = true end
        end
        if bossDied then   -- (its adds fall with it)
            for _, a in ipairs(alive) do E.Die(run, room, a) end
            alive = {}
        end
        room.foes = alive
        if chanDied then   -- Soul Transfer
            local any = false
            for _, c in ipairs(alive) do
                if c.kind == "mchan" then any = true c.rate = max(80, (c.rate or 220) * 0.75) c.r = c.r + 1.5 end
            end
            if any then E.Toast(run, "Soul Transfer: the other channelers grow stronger", 120) end
        end
        if #room.foes == 0 and not room.cleared then RoomCleared(run, room) end
    end
    if run.bossF then BossFx(run) end
    -- enemy shots
    keep = {}
    for _, s in ipairs(run.shots) do
        s.x, s.y, s.life = s.x + s.vx, s.y + s.vy, s.life - 1
        if s.x < X0 or s.x > X1 or s.y < Y0 or s.y > Y1 then s.life = 0 end
        if run.orbital and Hyp(s.x - run.orbital.x, s.y - run.orbital.y) < s.r + 12 then s.life = 0 end
        if s.life > 0 and Hyp(s.x - p.x, s.y - p.y) < p.r + s.r - 3 then s.life = 0 Hurt(run, s.by) end
        if s.life > 0 then keep[#keep + 1] = s else E.Fx(run, "pop", s.x, s.y, s.r, s.col, 12) end
    end
    run.shots = keep
    keep = {}
    keep = {}
    for _, x in ipairs(run.fx) do x.t = x.t + 1 if x.t < x.max then keep[#keep + 1] = x end end
    run.fx = keep
    for _, dc in ipairs(room.decals or {}) do dc.t = dc.t + 1 end
    keep = {}
    for _, z in ipairs(run.zaps) do z.life = z.life - 1 if z.life > 0 then keep[#keep + 1] = z end end
    run.zaps = keep
    if run.mode ~= "play" then return end
    Pickups(run, room, p)
    if run.banner then run.banner.life = run.banner.life - 1 if run.banner.life <= 0 then run.banner = nil end end
    if run.toast then run.toast.life = run.toast.life - 1 if run.toast.life <= 0 then run.toast = nil end end
    if run.say then run.say.life = run.say.life - 1 if run.say.life <= 0 then run.say = nil end end
end

-- The graves in the room you are in (today's dungeon).
function E.GravesHere(run)
    local out = {}
    for _, g in ipairs(run.graves or {}) do
        if g.f == run.floorN and g.rx == run.room.x and g.ry == run.room.y then out[#out + 1] = g end
    end
    return out
end

-- The doors of the room you are in: { dir, room, open, locked, kind } for the panel.
-- (the records are reused: read them now, keep none of them)
local doorsCache = setmetatable({}, { __mode = "k" })
function E.Doors(run)
    local out = doorsCache[run]
    if not out then out = {} doorsCache[run] = out end
    local n = 0
    for _, nb in ipairs(Nbs(run.map, run.room)) do
        n = n + 1
        local d = out[n] or {}
        out[n] = d
        d.dir, d.room, d.open, d.locked, d.kind = nb.dir, nb.room, run.room.cleared and not nb.room.locked, nb.room.locked, nb.room.type
    end
    for i = n + 1, #out do out[i] = nil end
    return out
end

-- What a finished (or abandoned) run leaves for the saved stats and the guild board.
function E.Summary(run)
    return { class = run.class, floor = run.floorN, won = run.mode == "won", time = floor(run.time / 60), kills = run.kills,
             items = #run.items + (run.active and 1 or 0), killer = run.killer, daily = run.daily, seed = run.seed,
             room = run.room and { run.room.x, run.room.y }, at = run.p and { floor(run.p.x), floor(run.p.y) } }
end

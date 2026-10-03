if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Engine.lua", ...) then return end -- DisasterZone Games/Trainer/Engine.lua
-- ns.Trainer: the Raid Trainer, a top-down practice arena for raid encounter mechanics. This file is the generic
-- engine: an encounter registry and a frame-free simulation (units, movement, targeting, abilities with cooldowns,
-- auras, timers, win / lose). An encounter is one file under Encounters/ that registers a table of data and hooks;
-- nothing in here knows a boss. Games/Trainer/UI.lua draws a sim and feeds it the keys.
--
-- Distances are yards, time is seconds, the arena's origin is its bottom-left corner (x right, y up).
--
-- def = {
--   name, desc, icon, order,
--   arena = { w = 70, h = 90, labels = { { x, y, text } }, walkable = function(x, y) end, outline = { { x, y }, .. },
--             map = { file, u0, u1, v0, v1 },          (the floor picture: the texture piece that covers w x h)
--             height = function(x, y) end,             (the floor's height there; drawn, it does not change speed)
--             mesh = { textures, verts, tris } },      (the room's own triangles, see TeronGorefiendFloor.lua)
--   difficulties = { { id = "normal", name = "Normal", ... the encounter's own numbers ... } },   first = default
--   player = { x, y, speed, facing },
--   interactKey = "F",                  that key uses the nearest thing with an .interact in reach
--   compass = true,                     the view shows N / E / S / W at the room's edges (arena y is north)
--   (the encounter may also keep these on the sim, redrawn every frame:
--    sim.marks  = { { x, y, r, color = { r, g, b }, column = height, label = "text" } }   rings on the floor
--    sim.status = { "line", ... }                                                         the job card
--    sim.beams  = { { x, y, z, x2, y2, z2, r, g, b } })
--   abilities = { { id, key = "3", name, icon, tip, cooldown, gcd, range, needsTarget, friendly (the target must be
--                   a .selectable ally: no auto-target),
--                   usable = function(sim) return ok, why end, use = function(sim, ability, target) end } },
--   start = function(sim) end,          spawn units, set the first objective
--   update = function(sim, dt) end,     every step: the script, sim:Win() / sim:Lose(reason)
--   score = function(sim) return n end, higher is better (the hub keeps the best)
--   summary = function(sim) return { "line", ... } end,   the end screen
-- }
local addonName, ns = ...

local T = ns:NewModule("Trainer")
T.GAME_ID = "trainer"
T.STEP = 0.05

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max
local sin, cos, atan2, pi = math.sin, math.cos, math.atan2, math.pi

T.TURN_RATE = pi            -- keyboard turning, radians per second (the client's default: 180 degrees)
T.BACKPEDAL = 4.5 / 7       -- walking backwards: 4.5 yd/s at normal run speed

local encs = {}     -- id -> def
local encList = {}  -- defs sorted by order

function T:RegisterEncounter(id, def)
    if type(id) ~= "string" or type(def) ~= "table" or type(def.start) ~= "function" then
        error("DisasterZone Trainer:RegisterEncounter(id, def): bad arguments", 2)
    end
    if not encs[id] then encList[#encList + 1] = def end
    def.id = id
    def.order = tonumber(def.order) or (#encList * 10)
    encs[id] = def
    table.sort(encList, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
end

function T:GetEncounter(id) return encs[id] end

-- A floor's height function from a generated height grid (ns.TrainerFloors: one letter per square yard, rows
-- south to north): smooth between the yard centres, the edge value outside.
function T.HeightFn(grid)
    if not grid then return nil end
    local index = {}                                    -- character -> its place in the alphabet
    local alphabet = grid.alphabet or "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for k = 1, #alphabet do index[alphabet:byte(k)] = k - 1 end
    local function cell(i, j)                           -- nil where there is no floor
        i = max(1, min(grid.w, i))
        j = max(1, min(grid.h, j))
        local n = index[grid.rows[j]:byte(i)]
        return n and (n * grid.step + grid.base)
    end
    return function(x, y)
        local fx, fy = x - 0.5, y - 0.5
        local i, j = floor(fx), floor(fy)
        local tx, ty = fx - i, fy - j
        local a, b = cell(i + 1, j + 1), cell(i + 2, j + 1)
        local c, d = cell(i + 1, j + 2), cell(i + 2, j + 2)
        local any = a or b or c or d or 0               -- at a hole's edge: the floor next to it
        a, b, c, d = a or any, b or any, c or any, d or any
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    end
end

-- Where the grid has floor (a space in a row = none): the room's own outline, for arena.walkable.
function T.WalkableFn(grid)
    if not grid then return nil end
    return function(x, y)
        local i, j = floor(x) + 1, floor(y) + 1
        if i < 1 or j < 1 or i > grid.w or j > grid.h then return false end
        return grid.rows[j]:byte(i) ~= 32
    end
end

function T:GetEncounters()
    local out = {}
    for i = 1, #encList do out[i] = encList[i] end
    return out
end

function T:GetDifficulty(enc, diffId)
    for _, d in ipairs(enc.difficulties or {}) do
        if d.id == diffId then return d end
    end
    return enc.difficulties and enc.difficulties[1] or { id = "normal", name = "Normal" }
end

function T.Dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end
local Dist = T.Dist

---------------------------------------------------------------------------
-- Saved results: DisasterZoneDB.games.trainer.enc[encounter][difficulty] = { tries, clears, bestTime, bestScore }
---------------------------------------------------------------------------

function T:Record(encId, diffId)
    local data = ns.Games:GetData(T.GAME_ID)
    if type(data.enc) ~= "table" then data.enc = {} end
    if type(data.enc[encId]) ~= "table" then data.enc[encId] = {} end
    local e = data.enc[encId]
    if type(e[diffId]) ~= "table" then e[diffId] = { tries = 0, clears = 0 } end
    return e[diffId]
end

-- Stores a finished sim; returns its score and whether that is a new best for this encounter and difficulty.
function T:Finish(sim)
    if sim.recorded then return sim.result or 0, false end
    sim.recorded = true
    local score = floor((sim.enc.score and sim.enc.score(sim)) or 0)
    sim.result = score
    local rec = self:Record(sim.enc.id, sim.diff.id)
    rec.tries = (rec.tries or 0) + 1
    local best = false
    if sim.state == "won" then
        rec.clears = (rec.clears or 0) + 1
        if not rec.bestTime or sim.clearTime < rec.bestTime then rec.bestTime = sim.clearTime end
        if not rec.bestScore or score > rec.bestScore then rec.bestScore = score best = true end
    end
    ns.Games:SubmitScore(T.GAME_ID, score)
    return score, best
end

---------------------------------------------------------------------------
-- Sim
---------------------------------------------------------------------------

local Sim = {}
Sim.__index = Sim

function T:NewSim(encId, diffId, seed)
    local enc = encs[encId]
    if not enc then return nil end
    seed = floor(tonumber(seed) or ((GetTime() * 1000) % 2147483646)) % 2147483646 + 1
    local sim = setmetatable({
        enc = enc, diff = T:GetDifficulty(enc, diffId),
        time = 0, acc = 0, state = "run", seed = seed,
        units = {}, nextId = 1, timers = {}, fx = {}, sounds = {}, hits = {}, bars = {}, zones = {},
        cds = {}, gcdUntil = 0, gcdTotal = 1, moveX = 0, moveY = 0, fwd = 0, strafe = 0, turn = 0,
        stats = { casts = {} },
    }, Sim)
    local p = enc.player or {}
    sim.player = sim:Spawn({ kind = "player", name = "You", x = p.x or enc.arena.w / 2, y = p.y or enc.arena.h / 2,
                             speed = p.speed or 7, radius = 1.2, color = { 0.3, 0.9, 0.3 },
                             facing = p.facing or pi / 2, model = "player" })
    enc.start(sim)
    return sim
end

-- Park-Miller: the sim owns its random numbers (a seed replays a run; nobody else's sequence shifts).
function Sim:Random(lo, hi)
    self.seed = (self.seed * 16807) % 2147483647
    local r = (self.seed - 1) / 2147483646
    if not lo then return r end
    return lo + floor(r * (hi - lo + 1))
end

-- u = { kind, name, x, y, hp, speed, radius, color = { r, g, b }, icon, targetable, goal = { x, y } }
function Sim:Spawn(u)
    u.id = self.nextId
    self.nextId = self.nextId + 1
    u.hpMax = u.hpMax or u.hp
    u.auras = {}
    u.radius = u.radius or 1.5
    u.facing = u.facing or 0
    self.units[#self.units + 1] = u
    return u
end

function Sim:After(delay, fn)
    self.timers[#self.timers + 1] = { at = self.time + delay, fn = fn }
end

-- A short-lived effect for the UI. The flat view draws { kind = "ring", x, y, r } and { kind = "beam", x, y, x2,
-- y2 } (plus color); the 3D view draws { kind = "model", fdid, unit or x / y, z } (a spell effect's model file,
-- on a unit or a spot) and { kind = "missile", ... } (Sim:Missile).
function Sim:Fx(fx, dur)
    fx.at, fx.dur = self.time, dur or 0.4
    self.fx[#self.fx + 1] = fx
end

-- A spell missile: the model flies from (x, y) to the unit at `speed` yd/s and onHit(sim, unit) runs as it lands.
function Sim:Missile(fdid, x, y, unit, speed, onHit)
    local dur = max(0.05, Dist(x, y, unit.x, unit.y) / speed)
    self:Fx({ kind = "missile", fdid = fdid, x = x, y = y, unit = unit }, dur)
    self:After(dur, function(s) onHit(s, unit) end)
end

-- A sound kit for the UI to play.
function Sim:Sound(kit)
    self.sounds[#self.sounds + 1] = kit
end

function Sim:Banner(text, dur, r, g, b)
    self.banner = { text = text, at = self.time, dur = dur or 2.5, color = { r or 1, g or 0.85, b or 0.3 } }
end

function Sim:Error(text)
    self.error = { text = text, at = self.time }
end

function Sim:Alive(filter)
    local out = {}
    for _, u in ipairs(self.units) do
        if not u.dead and (not filter or u.kind == filter) then out[#out + 1] = u end
    end
    return out
end

function Sim:UnitsInRange(x, y, r, filter)
    local out = {}
    for _, u in ipairs(self.units) do
        if not u.dead and u.targetable and (not filter or u.kind == filter) and Dist(x, y, u.x, u.y) <= r then
            out[#out + 1] = u
        end
    end
    return out
end

function Sim:Damage(u, amount)
    if u.dead or not u.hp then return end
    u.hp = max(0, u.hp - amount)
    u.hitAt = self.time
    if #self.hits < 40 then                 -- for the UI's floating numbers (it empties the list)
        self.hits[#self.hits + 1] = { amount = amount, x = u.x, y = u.y, kind = u.kind }
    end
    if u.hp <= 0 then
        u.dead, u.diedAt = true, self.time
        if self.target == u then self.target = nil end
    end
end

-- def = { dur, slow = 0.3 (per stack), stun = true, maxStacks, fade = 3 }: applying again refreshes and adds a
-- stack. fade: the slow weakens in steps, one every `fade` seconds, down to nothing when the aura ends.
function Sim:AddAura(u, id, def)
    local a = u.auras[id]
    if not a then
        a = { stacks = 0 }
        u.auras[id] = a
    end
    a.at = self.time
    a.untilT = self.time + def.dur
    a.total = def.dur
    a.slow, a.stun, a.fade = def.slow, def.stun, def.fade
    a.icon, a.name = def.icon, def.name            -- shown as a debuff on the target frame when it has an icon
    a.stacks = min(def.maxStacks or 1, a.stacks + 1)
    return a
end

function Sim:HasAura(u, id)
    local a = u.auras[id]
    return a and a.untilT > self.time and a or nil
end

-- The share of its speed an aura takes right now (0.9 = slowed by 90%).
function Sim:AuraSlow(a)
    if not a.slow then return 0 end
    local k = 1
    if a.fade then
        local ticks = a.total / a.fade
        k = max(0, 1 - floor((self.time - a.at) / a.fade + 1e-6) / ticks)
    end
    return a.slow * a.stacks * k
end

function Sim:UnitSpeed(u)
    local mult = 1
    for _, a in pairs(u.auras) do
        if a.stun then return 0 end
        mult = mult - self:AuraSlow(a)
    end
    return (u.speed or 0) * max(0, mult)
end

---------------------------------------------------------------------------
-- Input: the move vector, the target, the abilities
---------------------------------------------------------------------------

-- A direction on the map (tests, and the flat fallback view).
function Sim:SetMove(dx, dy)
    self.moveX, self.moveY = dx or 0, dy or 0
end

-- The client's own controls: forward / back (1 / -1), strafe (1 = right), keyboard turn (1 = left).
function Sim:SetControls(fwd, strafe, turn)
    self.fwd, self.strafe, self.turn = fwd or 0, strafe or 0, turn or 0
end

-- Mouse look: turn by an angle (counter-clockwise seen from above).
function Sim:Turn(rad)
    self.player.facing = (self.player.facing + rad) % (2 * pi)
end

function Sim:SetTarget(u)
    if u and (u.dead or not (u.targetable or u.selectable)) then return end
    self.target = u
    self.tabSeen = { [u or false] = true }
end

-- Tab, like the client's: the nearest enemy in front of you that this round of Tabs has not picked yet (what is
-- in front = within T.TAB_CONE of where you face); then the ones behind you; then the round starts over. A
-- round remembers its picks, so enemies that overtake each other are never picked twice while another waits.
T.TAB_CONE = math.rad(70)
function Sim:TabTarget()
    local p = self.player
    local seen = self.tabSeen or {}
    local function nearest(frontOnly)
        local best, bestD
        for _, u in ipairs(self.units) do
            if not u.dead and u.targetable and not seen[u] then
                local d = Dist(p.x, p.y, u.x, u.y)
                local off = 0
                if frontOnly and d > 1.5 then
                    off = math.abs((atan2(u.y - p.y, u.x - p.x) - p.facing + pi) % (2 * pi) - pi)
                end
                if off <= T.TAB_CONE and (not bestD or d < bestD or (d == bestD and u.id < best.id)) then
                    best, bestD = u, d
                end
            end
        end
        return best
    end
    local pick = nearest(true) or nearest(false)
    if not pick then                                   -- everyone had a turn: a new round (not the same one again)
        seen = { [self.target or false] = true }
        pick = nearest(true) or nearest(false)
        if not pick then
            seen = {}
            pick = nearest(true) or nearest(false)
        end
    end
    seen[pick or false] = true
    self.tabSeen = seen
    self.target = pick
    return pick
end

function Sim:GetAbility(idOrKey)
    for _, ab in ipairs(self.enc.abilities or {}) do
        if ab.id == idOrKey or ab.key == idOrKey then return ab end
    end
    return nil
end

-- Seconds until the ability can be used, and the length of whatever it is waiting for (for the button's sweep).
function Sim:Cooldown(ab)
    local cd = (self.cds[ab.id] or 0) - self.time
    local gcd = self.gcdUntil - self.time
    if cd > 0 and cd >= gcd then return cd, ab.cooldown or cd end
    if gcd > 0 then return gcd, self.gcdTotal end
    return 0, 0
end

-- Returns true, or false and why not (also shown as the red error line).
function Sim:Use(idOrKey)
    local ab = self:GetAbility(idOrKey)
    if not ab or self.state ~= "run" then return false, "not running" end
    local function fail(why)
        self:Error(why)
        return false, why
    end
    if ab.usable then
        local ok, why = ab.usable(self)
        if not ok then return fail(why or "You can't do that yet.") end
    end
    if self:Cooldown(ab) > 0 then return fail("That ability isn't ready yet.") end
    if ab.check then
        local ok, why = ab.check(self)
        if not ok then return fail(why or "You can't do that yet.") end
    end
    local target
    if ab.needsTarget then
        target = self.target
        if ab.friendly then
            if not target or target.dead or not target.selectable then return fail("You have no target.") end
        elseif not target or target.dead or not target.targetable then
            target = self:TabTarget()
        end
        if not target then return fail("You have no target.") end
        if ab.range and Dist(self.player.x, self.player.y, target.x, target.y) > ab.range then
            return fail("Out of range.")
        end
    end
    ab.use(self, ab, target)
    if ab.cooldown then self.cds[ab.id] = self.time + ab.cooldown end
    self.gcdTotal = ab.gcd or 1
    self.gcdUntil = self.time + self.gcdTotal
    self.stats.casts[ab.id] = (self.stats.casts[ab.id] or 0) + 1
    return true
end

-- Use a thing in the world (a unit with .interact = function(sim, unit) and optionally .interactRange): the one
-- given, or the nearest one in reach. Returns true, or false and why not.
T.INTERACT_RANGE = 5
function Sim:Interact(u)
    if self.state ~= "run" then return false, "not running" end
    local p = self.player
    if not u then
        local bestD
        for _, o in ipairs(self.units) do
            if o.interact and not o.dead then
                local d = Dist(p.x, p.y, o.x, o.y)
                if d <= (o.interactRange or T.INTERACT_RANGE) and (not bestD or d < bestD) then u, bestD = o, d end
            end
        end
        if not u then return false, "nothing in reach" end
    end
    if not u.interact or u.dead then return false, "nothing to use" end
    if Dist(p.x, p.y, u.x, u.y) > (u.interactRange or T.INTERACT_RANGE) then
        self:Error("You are too far away.")
        return false, "You are too far away."
    end
    u.interact(self, u)
    return true
end

---------------------------------------------------------------------------
-- Stepping
---------------------------------------------------------------------------

function Sim:Win()
    if self.state ~= "run" then return end
    self.state, self.clearTime = "won", self.time
end

function Sim:Lose(reason)
    if self.state ~= "run" then return end
    self.state, self.reason = "lost", reason
end

local function MoveToward(u, x, y, dist)
    local d = Dist(u.x, u.y, x, y)
    if d > 0.01 then u.facing = atan2(y - u.y, x - u.x) end
    if d <= dist or d == 0 then u.x, u.y = x, y return end
    u.x = u.x + (x - u.x) / d * dist
    u.y = u.y + (y - u.y) / d * dist
end

function Sim:Step(dt)
    self.time = self.time + dt
    local now = self.time

    local timers = self.timers
    for i = #timers, 1, -1 do
        local t = timers[i]
        if t.at <= now then
            table.remove(timers, i)
            t.fn(self)
        end
    end

    for _, u in ipairs(self.units) do
        for id, a in pairs(u.auras) do
            if a.untilT <= now then u.auras[id] = nil end
        end
    end

    local p, arena = self.player, self.enc.arena
    if self.turn ~= 0 then self:Turn(self.turn * T.TURN_RATE * dt) end
    local mx, my, speed = self.moveX, self.moveY, self:UnitSpeed(p)
    p.backward = false
    p.bodyTurn = 0                  -- how far the body turns away from where you look, as the client shows a strafe
    if self.fwd ~= 0 or self.strafe ~= 0 then
        local cf, sf = cos(p.facing), sin(p.facing)
        mx = cf * self.fwd + sf * self.strafe
        my = sf * self.fwd - cf * self.strafe
        if self.fwd < 0 then
            speed = speed * T.BACKPEDAL
            p.backward = true
            p.bodyTurn = self.strafe * pi / 4          -- backing off to the right: the body swings left
        elseif self.fwd > 0 then
            p.bodyTurn = -self.strafe * pi / 4         -- running forward and right: the body leans into it
        else
            p.bodyTurn = -self.strafe * pi / 2         -- a pure strafe: the body runs sideways, the view stays
        end
    elseif mx ~= 0 or my ~= 0 then
        p.facing = atan2(my, mx)
    end
    p.moving = false
    if not p.rooted and (mx ~= 0 or my ~= 0) then
        local len = sqrt(mx * mx + my * my)
        local step = speed * dt
        local nx = min(arena.w - p.radius, max(p.radius, p.x + mx / len * step))
        local ny = min(arena.h - p.radius, max(p.radius, p.y + my / len * step))
        -- arena.walkable(x, y): rooms that are not a rectangle. Blocked: slide along the wall on one axis.
        local ok = arena.walkable
        if not ok or ok(nx, ny) then
            p.x, p.y = nx, ny
        elseif ok(nx, p.y) then
            p.x = nx
        elseif ok(p.x, ny) then
            p.y = ny
        end
        p.moving = true
    end
    for _, u in ipairs(self.units) do
        if not u.dead and u.goal then
            local step = self:UnitSpeed(u) * dt
            local stop = u.goal.stop or 0
            local d = Dist(u.x, u.y, u.goal.x, u.goal.y)
            u.moving = step > 0 and d > stop
            if u.moving then MoveToward(u, u.goal.x, u.goal.y, min(step, d - stop)) end
        end
    end

    if self.enc.update then self.enc.update(self, dt) end

    local fx = self.fx
    for i = #fx, 1, -1 do
        if fx[i].at + fx[i].dur <= now then table.remove(fx, i) end
    end
end

-- Real time in: one step per frame, so movement and turning are as smooth as the frame rate. A long frame is
-- cut into steps of at most T.STEP (it never tunnels a unit through a trigger).
function Sim:Update(elapsed)
    local left = min(elapsed, 0.25)
    while left > 1e-6 and self.state == "run" do
        local dt = min(left, T.STEP)
        left = left - dt
        self:Step(dt)
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function T:OnInit()
    ns.Games:Register(T.GAME_ID, {
        name = "Raid Trainer",
        desc = "Practice raid encounter mechanics on a top-down map. WASD to move, Tab to target, number keys to cast.",
        icon = "Interface\\Icons\\Spell_Shadow_DeathPact",
        order = 15,
        create = function(parent) return ns.TrainerUI:CreatePanel(parent) end,
    })
end

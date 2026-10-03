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
--   arena = { w = 70, h = 90, labels = { { x, y, text } } },
--   difficulties = { { id = "normal", name = "Normal", ... the encounter's own numbers ... } },   first = default
--   player = { x, y, speed },
--   abilities = { { id, key = "3", name, icon, tip, cooldown, gcd, range, needsTarget,
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
        units = {}, nextId = 1, timers = {}, fx = {}, bars = {}, zones = {},
        cds = {}, gcdUntil = 0, gcdTotal = 1, moveX = 0, moveY = 0,
        stats = { casts = {} },
    }, Sim)
    local p = enc.player or {}
    sim.player = sim:Spawn({ kind = "player", name = "You", x = p.x or enc.arena.w / 2, y = p.y or enc.arena.h / 2,
                             speed = p.speed or 7, radius = 1.2, color = { 0.3, 0.9, 0.3 } })
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
    self.units[#self.units + 1] = u
    return u
end

function Sim:After(delay, fn)
    self.timers[#self.timers + 1] = { at = self.time + delay, fn = fn }
end

-- A short-lived effect for the UI: { kind = "ring", x, y, r } or { kind = "beam", x, y, x2, y2 }, plus color.
function Sim:Fx(fx, dur)
    fx.at, fx.dur = self.time, dur or 0.4
    self.fx[#self.fx + 1] = fx
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
    if u.hp <= 0 then
        u.dead, u.diedAt = true, self.time
        if self.target == u then self.target = nil end
    end
end

-- def = { dur, slow = 0.3 (per stack), stun = true, maxStacks }: applying again refreshes and adds a stack.
function Sim:AddAura(u, id, def)
    local a = u.auras[id]
    if not a then
        a = { stacks = 0 }
        u.auras[id] = a
    end
    a.untilT = self.time + def.dur
    a.total = def.dur
    a.slow, a.stun = def.slow, def.stun
    a.stacks = min(def.maxStacks or 1, a.stacks + 1)
    return a
end

function Sim:HasAura(u, id)
    local a = u.auras[id]
    return a and a.untilT > self.time and a or nil
end

function Sim:UnitSpeed(u)
    local mult = 1
    for _, a in pairs(u.auras) do
        if a.stun then return 0 end
        if a.slow then mult = mult - a.slow * a.stacks end
    end
    return (u.speed or 0) * max(0, mult)
end

---------------------------------------------------------------------------
-- Input: the move vector, the target, the abilities
---------------------------------------------------------------------------

function Sim:SetMove(dx, dy)
    self.moveX, self.moveY = dx or 0, dy or 0
end

function Sim:SetTarget(u)
    if u and (u.dead or not u.targetable) then return end
    self.target = u
end

-- Tab: the living targets from near to far, the one after the current target.
function Sim:TabTarget()
    local p = self.player
    local list = {}
    for _, u in ipairs(self.units) do
        if not u.dead and u.targetable then list[#list + 1] = u end
    end
    if #list == 0 then self.target = nil return nil end
    table.sort(list, function(a, b)
        local da, db = Dist(p.x, p.y, a.x, a.y), Dist(p.x, p.y, b.x, b.y)
        if da ~= db then return da < db end
        return a.id < b.id
    end)
    local pick = list[1]
    for i, u in ipairs(list) do
        if u == self.target then pick = list[i % #list + 1] break end
    end
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
    local target
    if ab.needsTarget then
        target = self.target
        if not target or target.dead then target = self:TabTarget() end
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
    if not p.rooted and (self.moveX ~= 0 or self.moveY ~= 0) then
        local len = sqrt(self.moveX * self.moveX + self.moveY * self.moveY)
        local step = self:UnitSpeed(p) * dt
        p.x = min(arena.w - p.radius, max(p.radius, p.x + self.moveX / len * step))
        p.y = min(arena.h - p.radius, max(p.radius, p.y + self.moveY / len * step))
    end
    for _, u in ipairs(self.units) do
        if not u.dead and u.goal then
            MoveToward(u, u.goal.x, u.goal.y, self:UnitSpeed(u) * dt)
        end
    end

    if self.enc.update then self.enc.update(self, dt) end

    local fx = self.fx
    for i = #fx, 1, -1 do
        if fx[i].at + fx[i].dur <= now then table.remove(fx, i) end
    end
end

-- Real time in, fixed steps out (a long frame never tunnels a unit through a trigger).
function Sim:Update(elapsed)
    if self.state ~= "run" then return end
    self.acc = self.acc + min(elapsed, 0.25)
    while self.acc >= T.STEP and self.state == "run" do
        self.acc = self.acc - T.STEP
        self:Step(T.STEP)
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

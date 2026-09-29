-- CDLoot Games/Murloc/Sim.lua
-- ns.MurlocSim: the deterministic Murloc Defense simulation. Pure Lua, integers only, arrays only (no
-- pairs() over hashes), so every client that starts from the same seed and applies the same actions at the
-- same ticks computes a bit-identical game. The state table S is plain data (serializable for resyncs).
--
-- Actions: { tick = n, p = playerIndex, k = kind, a = , b = , c = , seq = n }
--   "b" build defender c (index into D.defenders, 0 = my hero) on lane a, slot b (own lane only)
--   "u" upgrade the defender on lane a, slot b     "s" sell it
--   "g" gift D.GIFT gold to player a               "l" Bloodlust (shared cooldown)
--   "t" pick talent offer a (1..3)                 "v" vote for boon offer a (1..3)
--
-- S.fx is a cosmetic event list (shots, heals, deaths, ...) for the UI. It is never hashed and the UI
-- drains it; gameplay never reads it.
local addonName, ns = ...

local Sim = ns:NewModule("MurlocSim")
local D = ns.MurlocData

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local MOD = 2147483647
local FX_CAP = 400

local function Rand(S, n)
    S.rng = (S.rng * 16807) % MOD
    return (S.rng % n) + 1
end

local function Fx(S, e)
    local fx = S.fx
    if #fx >= FX_CAP then
        S.fx = {}
        fx = S.fx
    end
    fx[#fx + 1] = e
end

-- A hero from the wire, clamped to sane values (chosen on the player's own client).
local function CleanHero(h)
    h = type(h) == "table" and h or {}
    local role = D.heroRoles[h.role] and h.role or "melee"
    local class = D.heroClass[h.class] and h.class or "WARRIOR"
    local power = floor(tonumber(h.power) or 100)
    power = max(D.POWER_MIN, min(D.POWER_MAX, power))
    local tier = floor(tonumber(h.tier) or 0)
    tier = max(0, min(#D.REP_TIERS - 1, tier))
    local name = type(h.name) == "string" and h.name:sub(1, 24) or "Hero"
    return { role = role, class = class, power = power, name = name, tier = tier }
end

-- Distinct random picks: n values from 1..size (not in `skip`), in pick order.
local function Pick(S, size, n, allowed)
    local pool = {}
    for i = 1, size do
        if not allowed or allowed(i) then pool[#pool + 1] = i end
    end
    local out = {}
    for _ = 1, min(n, #pool) do
        local j = Rand(S, #pool)
        out[#out + 1] = table.remove(pool, j)
    end
    return out
end

-- heroes (optional): array indexed by player of { role, class, power, name, tier }. map: index into D.maps.
function Sim.New(seed, players, heroes, map)
    players = max(1, min(D.MAX_PLAYERS, tonumber(players) or 1))
    map = D.maps[tonumber(map) or 1] and (tonumber(map) or 1) or 1
    local s = (tonumber(seed) or 1) % MOD
    if s <= 0 then s = s + MOD - 1 end
    local S = {
        tick = 0, rng = s, players = players, lives = D.LIVES, map = map,
        wave = 0, phase = "break", phaseEnd = D.FIRST_BREAK,
        gold = {}, towers = {}, terrain = {}, mobs = {}, spawns = {}, actions = {},
        lustUntil = -1, lustReady = 0, nextId = 1, kills = 0, over = false,
        heroes = {}, heroReady = {}, heroUp = {}, heroXp = {}, heroLevel = {}, talentPts = {},
        talentOffer = {}, talentPicks = {}, votes = {}, boonOffer = false, boonsTaken = {},
        mods = { hp = 0, dmg = 0, bounty = 0, haste = 0 },
        bossKills = {}, maxGold = 0, fx = {},
    }
    local mapDef = D.maps[map]
    for p = 1, players do
        S.gold[p] = D.START_GOLD
        local lane, ter = {}, {}
        for col = 1, D.SLOTS do lane[col], ter[col] = false, false end
        S.towers[p], S.terrain[p] = lane, ter
        S.heroes[p] = CleanHero(heroes and heroes[p])
        S.heroReady[p], S.heroUp[p] = 0, false
        S.heroXp[p], S.heroLevel[p], S.talentPts[p] = 0, 1, 0
        S.talentOffer[p] = false
        local picks = {}
        for i = 1, #(D.talents[S.heroes[p].role] or {}) do picks[i] = 0 end
        S.talentPicks[p] = picks
        S.votes[p] = 0
    end
    -- lane terrain (column 1 stays clear so every lane has a last line of defence)
    for p = 1, players do
        local cols = Pick(S, D.SLOTS - 1, mapDef.features)
        local rocks = false
        for _, c in ipairs(cols) do
            local kind = mapDef.pool[Rand(S, #mapDef.pool)]
            if kind == "rocks" then
                if rocks then kind = mapDef.pool[#mapDef.pool] end
                rocks = true
            end
            S.terrain[p][c + 1] = kind
        end
    end
    return S
end

function Sim.SlotX(col) return (col - 1) * D.COL + floor(D.COL / 2) end

function Sim.Queue(S, act)
    if type(act) ~= "table" or type(act.tick) ~= "number" then return false end
    if act.tick < S.tick then return false end
    local list = S.actions
    list[#list + 1] = act
    table.sort(list, function(x, y)
        if x.tick ~= y.tick then return x.tick < y.tick end
        if x.p ~= y.p then return x.p < y.p end
        return (x.seq or 0) < (y.seq or 0)
    end)
    return true
end

---------------------------------------------------------------------------
-- Defender stats
---------------------------------------------------------------------------

-- (Re)computes a defender's stats from its kind, rank, terrain, the party's boons and (heroes) talents.
local function Recalc(S, t, lane, col)
    local st
    if t.kind == 0 then
        st = D.HeroStats(S.heroes[t.owner], S.talentPicks[t.owner], S.heroLevel[t.owner])
    else
        local def = D.defenders[t.kind]
        local mult = D.RANK_MULT[t.rank] or 100
        local function r(v) return v and floor(v * mult / 100) or nil end
        st = { hp = def.hp, dmg = r(def.dmg), heal = r(def.heal), range = def.range, cd = def.cd, slow = def.slow,
               splash = def.splash, crit = def.crit and D.CRIT_CHANCE or nil }
        st.hp = r(def.hp)
    end
    local ter = D.terrain[S.terrain[lane][col] or ""] or {}
    local hpPct = (ter.hp or 100) * (100 + S.mods.hp) / 100
    local dmgPct = (ter.dmg or 100) * (100 + S.mods.dmg) / 100
    local newMax = max(1, floor(st.hp * hpPct / 100))
    if t.max then
        t.hp = min(newMax, t.hp + max(0, newMax - t.max))
    else
        t.hp = newMax
    end
    t.max = newMax
    t.dmg = floor((st.dmg or 0) * dmgPct / 100)
    t.heal = st.heal and floor(st.heal * dmgPct / 100) or nil
    t.range = st.range or 0
    t.rate = max(2, floor(st.cd * (100 - S.mods.haste) / 100))
    t.slow, t.splash, t.crit = st.slow, st.splash, st.crit
    t.chain, t.cross, t.lifesteal = st.chain, st.crossLane or nil, st.lifesteal
end

local function RecalcAll(S)
    for lane = 1, S.players do
        for col = 1, D.SLOTS do
            local t = S.towers[lane][col]
            if t then Recalc(S, t, lane, col) end
        end
    end
end

local function RecalcHero(S, p)
    for col = 1, D.SLOTS do
        local t = S.towers[p][col]
        if t and t.kind == 0 then Recalc(S, t, p, col) end
    end
end

local function RemoveTower(S, lane, col)
    local t = S.towers[lane][col]
    S.towers[lane][col] = false
    if t and t.kind == 0 then
        S.heroUp[t.owner] = false
        S.heroReady[t.owner] = S.tick + D.HERO_RESPAWN
    end
end

---------------------------------------------------------------------------
-- Validation (also used by the UI to grey out buttons)
---------------------------------------------------------------------------

function Sim.HeroReady(S, p)
    return not S.over and S.heroes[p] ~= nil and not S.heroUp[p] and S.tick >= (S.heroReady[p] or 0)
end

function Sim.Unlocked(S, p, kind)
    local def = D.defenders[kind]
    return def ~= nil and (S.heroes[p] and S.heroes[p].tier or 0) >= (def.rep or 0)
end

local function OwnSlot(S, p, lane, col)
    return not S.over and lane == p and S.towers[lane] ~= nil and type(col) == "number" and col >= 1 and col <= D.SLOTS
end

function Sim.CanBuild(S, p, lane, col, kind)
    if not OwnSlot(S, p, lane, col) or S.towers[lane][col] then return false end
    if S.terrain[lane][col] == "rocks" then return false end
    if kind == 0 then return Sim.HeroReady(S, p) end
    local def = D.defenders[kind]
    return def ~= nil and Sim.Unlocked(S, p, kind) and (S.gold[p] or 0) >= def.cost
end

function Sim.UpgradeCost(S, lane, col)
    local t = S.towers[lane] and S.towers[lane][col]
    if not t or t.kind == 0 or t.rank >= D.RANKS then return nil end
    return D.defenders[t.kind].cost * t.rank
end

function Sim.CanUpgrade(S, p, lane, col)
    if not OwnSlot(S, p, lane, col) then return false end
    local cost = Sim.UpgradeCost(S, lane, col)
    return cost ~= nil and (S.gold[p] or 0) >= cost
end

function Sim.SellValue(S, lane, col)
    local t = S.towers[lane] and S.towers[lane][col]
    if not t or t.kind == 0 then return nil end
    return floor(t.spent * D.SELL_REFUND / 100)
end

function Sim.LustReady(S) return not S.over and S.tick >= S.lustReady end

---------------------------------------------------------------------------
-- Progression: hero levels, talents, boons
---------------------------------------------------------------------------

local function OfferTalents(S, p)
    if S.talentOffer[p] or S.talentPts[p] <= 0 then return end
    local picks = S.talentPicks[p]
    local pool = D.talents[S.heroes[p].role] or {}
    local offer = Pick(S, #pool, 3, function(i) return (picks[i] or 0) < D.TALENT_MAX end)
    S.talentOffer[p] = #offer > 0 and offer or false
    if not S.talentOffer[p] then S.talentPts[p] = 0 end
end

local function GainXp(S, p)
    if S.heroLevel[p] >= D.HERO_MAX_LEVEL then return end
    S.heroXp[p] = S.heroXp[p] + 1
    if S.heroXp[p] >= D.XpForLevel(S.heroLevel[p]) then
        S.heroXp[p] = 0
        S.heroLevel[p] = S.heroLevel[p] + 1
        S.talentPts[p] = S.talentPts[p] + 1
        Fx(S, { k = "level", p = p, n = S.heroLevel[p] })
        RecalcHero(S, p)
        OfferTalents(S, p)
    end
end

local function ApplyBoon(S, idx)
    local b = D.boons[idx]
    if not b then return end
    S.boonsTaken[#S.boonsTaken + 1] = idx
    Fx(S, { k = "boon", b = idx })
    if b.id == "motw" then S.mods.hp = S.mods.hp + 15 RecalcAll(S)
    elseif b.id == "shout" then S.mods.dmg = S.mods.dmg + 15 RecalcAll(S)
    elseif b.id == "haste" then S.mods.haste = min(50, S.mods.haste + 10) RecalcAll(S)
    elseif b.id == "bounty" then S.mods.bounty = S.mods.bounty + 25
    elseif b.id == "bank" then for p = 1, S.players do S.gold[p] = S.gold[p] + 80 end
    elseif b.id == "fortify" then S.lives = min(D.MAX_LIVES, S.lives + 2)
    elseif b.id == "renew" then
        for lane = 1, S.players do
            for col = 1, D.SLOTS do
                local t = S.towers[lane][col]
                if t then t.hp = t.max end
            end
            if not S.heroUp[lane] then S.heroReady[lane] = S.tick end
        end
    end
end

local function ResolveVote(S)
    local offer = S.boonOffer
    if not offer then return end
    local counts = {}
    for i = 1, #offer do counts[i] = 0 end
    for p = 1, S.players do
        local v = S.votes[p]
        if counts[v] then counts[v] = counts[v] + 1 end
        S.votes[p] = 0
    end
    local best = 1
    for i = 2, #offer do
        if counts[i] > counts[best] then best = i end
    end
    S.boonOffer = false
    ApplyBoon(S, offer[best])
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function Apply(S, act)
    local p = act.p
    if type(p) ~= "number" or p < 1 or p > S.players then return end
    local k = act.k
    if k == "b" then
        local lane, col, kind = act.a, act.b, act.c
        if not Sim.CanBuild(S, p, lane, col, kind) then return end
        local t = { kind = kind, owner = p, rank = 1, cd = 0, x = Sim.SlotX(col), spent = 0, stun = 0 }
        if kind == 0 then
            S.heroUp[p] = true
        else
            t.spent = D.defenders[kind].cost
            S.gold[p] = S.gold[p] - t.spent
        end
        Recalc(S, t, lane, col)
        S.towers[lane][col] = t
        Fx(S, { k = "build", lane = lane, col = col })
    elseif k == "u" then
        local lane, col = act.a, act.b
        if not Sim.CanUpgrade(S, p, lane, col) then return end
        local t = S.towers[lane][col]
        local cost = Sim.UpgradeCost(S, lane, col)
        S.gold[p] = S.gold[p] - cost
        t.spent = t.spent + cost
        t.rank = t.rank + 1
        Recalc(S, t, lane, col)
        t.hp = t.max
        Fx(S, { k = "upgrade", lane = lane, col = col, rank = t.rank })
    elseif k == "s" then
        local lane, col = act.a, act.b
        if not OwnSlot(S, p, lane, col) then return end
        local value = Sim.SellValue(S, lane, col)
        if not value then return end
        S.gold[p] = S.gold[p] + value
        RemoveTower(S, lane, col)
    elseif k == "g" then
        local to = act.a
        if type(to) ~= "number" or to < 1 or to > S.players or to == p then return end
        if S.gold[p] < D.GIFT then return end
        S.gold[p] = S.gold[p] - D.GIFT
        S.gold[to] = S.gold[to] + D.GIFT
        Fx(S, { k = "gift", from = p, to = to })
    elseif k == "l" then
        if not Sim.LustReady(S) then return end
        S.lustUntil = S.tick + D.LUST.duration
        S.lustReady = S.tick + D.LUST.cooldown
        Fx(S, { k = "lust", p = p })
    elseif k == "t" then
        local offer = S.talentOffer[p]
        local choice = offer and offer[act.a]
        if not choice then return end
        S.talentPicks[p][choice] = (S.talentPicks[p][choice] or 0) + 1
        S.talentOffer[p] = false
        S.talentPts[p] = S.talentPts[p] - 1
        RecalcHero(S, p)
        OfferTalents(S, p)
    elseif k == "v" then
        if S.boonOffer and S.boonOffer[act.a] then S.votes[p] = act.a end
    end
end

---------------------------------------------------------------------------
-- Waves
---------------------------------------------------------------------------

local function StartWave(S)
    ResolveVote(S)
    S.wave = S.wave + 1
    S.phase = "wave"
    local boss = D.WaveBoss(S.wave, S.map)
    local bossLane = boss and Rand(S, S.players) or 0
    Fx(S, { k = "wave", n = S.wave, boss = boss })
    for lane = 1, S.players do
        local order = D.WaveList(S.wave)
        for i = #order, 2, -1 do
            local j = Rand(S, i)
            order[i], order[j] = order[j], order[i]
        end
        if lane == bossLane then order[#order + 1] = boss end
        local t = S.tick + Rand(S, 10)
        for _, kind in ipairs(order) do
            S.spawns[#S.spawns + 1] = { tick = t, lane = lane, kind = kind }
            t = t + D.SPAWN_GAP
        end
    end
    table.sort(S.spawns, function(x, y)
        if x.tick ~= y.tick then return x.tick < y.tick end
        return x.lane < y.lane
    end)
end

local function EndWave(S)
    S.phase = "break"
    S.phaseEnd = S.tick + D.WAVE_BREAK
    S.boonOffer = Pick(S, #D.boons, D.BOON_OFFER)
    for p = 1, S.players do S.votes[p] = 0 end
end

local function Spawn(S, lane, kind, x)
    local def = D.murlocs[kind]
    local hp = floor(D.ScaledHp(def.hp, S.wave) * D.maps[S.map].hpMult / 100)
    x = x or D.LANE
    S.mobs[#S.mobs + 1] = { id = S.nextId, kind = kind, lane = lane, x = x, px = x, hp = hp, max = hp,
                            slow = 0, cd = 0, hcd = 0, hopped = false, leapt = false, netted = false }
    S.nextId = S.nextId + 1
    if def.boss then Fx(S, { k = "boss", kind = kind, lane = lane }) end
end

---------------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------------

local function Target(S, lane, x, range)
    local best, bestDist
    for _, m in ipairs(S.mobs) do
        if m.lane == lane and m.hp > 0 and m.x >= x - 200 then
            local dist = m.x - x
            if dist <= range and (not bestDist or dist < bestDist) then best, bestDist = m, dist end
        end
    end
    return best
end

-- The defender directly in front of a murloc (closest one it is touching), or nil. Mines don't block.
local function Blocker(S, m)
    local row = S.towers[m.lane]
    if not row then return nil end
    local best, bestCol
    for col = 1, D.SLOTS do
        local t = row[col]
        if t and not (t.kind ~= 0 and D.defenders[t.kind].noBlock) and t.x <= m.x and m.x - t.x <= D.CONTACT
            and (not bestCol or col > bestCol) then
            best, bestCol = t, col
        end
    end
    return best, bestCol
end

local function Heal(S, lane, t)
    local cands = {}
    local lo, hi = lane, lane
    if t.cross then lo, hi = max(1, lane - 1), min(S.players, lane + 1) end
    for l = lo, hi do
        local row = S.towers[l]
        for col = 1, D.SLOTS do
            local d = row[col]
            if d and d.hp < d.max then
                cands[#cands + 1] = { t = d, pct = floor(d.hp * 1000 / d.max), l = l, col = col }
            end
        end
    end
    if #cands == 0 then return false end
    table.sort(cands, function(x, y)
        if x.pct ~= y.pct then return x.pct < y.pct end
        if x.l ~= y.l then return x.l < y.l end
        return x.col < y.col
    end)
    for i = 1, min(t.chain or 1, #cands) do
        local c = cands[i]
        c.t.hp = min(c.t.max, c.t.hp + t.heal)
        Fx(S, { k = "heal", lane = c.l, x = c.t.x, from = t.x, fromLane = lane, amt = t.heal })
    end
    return true
end

local function Damage(S, m, amount)
    m.hp = m.hp - amount
end

-- One defender's action this tick. Returns true when it did something (starts its cooldown).
local function Act(S, lane, col, t)
    local healed = t.heal and Heal(S, lane, t) or false
    if t.dmg <= 0 then return healed end
    local m = Target(S, lane, t.x, t.range)
    if not m then return healed end
    local dmg = t.dmg
    local crit = t.crit and Rand(S, 100) <= t.crit
    if crit then dmg = dmg * 2 end
    Damage(S, m, dmg)
    if t.slow then m.slow = max(m.slow, t.slow) end
    if t.lifesteal then t.hp = min(t.max, t.hp + floor(dmg * t.lifesteal / 100)) end
    local proj = t.kind == 0 and ("hero:" .. S.heroes[t.owner].role) or D.defenders[t.kind].proj
    Fx(S, { k = "shot", lane = lane, x1 = t.x, x2 = m.x, id = m.id, dmg = dmg, crit = crit or nil, proj = proj })
    if t.splash then
        local splashDmg = (t.kind ~= 0 and D.defenders[t.kind].once) and dmg or floor(dmg / 2)
        for _, o in ipairs(S.mobs) do
            if o ~= m and o.lane == lane and o.hp > 0 and abs(o.x - m.x) <= t.splash then Damage(S, o, splashDmg) end
        end
        Fx(S, { k = "splash", lane = lane, x = m.x, r = t.splash })
    end
    if t.kind ~= 0 and D.defenders[t.kind].once then
        RemoveTower(S, lane, col)
    end
    return true
end

local function TotemNear(row, col)
    local function isTotem(c)
        local t = row[c]
        return t and t.kind ~= 0 and D.defenders[t.kind].aura
    end
    return (col > 1 and isTotem(col - 1)) or (col < D.SLOTS and isTotem(col + 1))
end

local function TerrainAt(S, lane, x)
    local col = floor(x / D.COL) + 1
    if col < 1 or col > D.SLOTS then return nil end
    return D.terrain[S.terrain[lane][col] or ""]
end

local function MoveMurloc(S, m, def)
    local speed = def.speed
    if m.slow > 0 then
        speed = floor(speed / 2)
        m.slow = m.slow - 1
    end
    local ter = TerrainAt(S, m.lane, m.x)
    if ter and ter.slow then speed = floor(speed / 2) end
    if ter and ter.fast then speed = floor(speed * 3 / 2) end
    m.x = m.x - max(1, speed)
    if def.hopAt and not m.hopped and m.x <= def.hopAt and S.players > 1 then
        m.hopped = true
        local lane = m.lane
        if lane == 1 then lane = 2
        elseif lane == S.players then lane = lane - 1
        else lane = lane + ((Rand(S, 2) == 1) and -1 or 1) end
        Fx(S, { k = "hop", from = m.lane, to = lane, x = m.x })
        m.lane = lane
        m.px = m.x
    end
    if m.x <= 0 then
        m.hp = 0
        m.leaked = true
        S.lives = S.lives - def.leak
        Fx(S, { k = "leak", lane = m.lane, kind = m.kind })
    end
end

---------------------------------------------------------------------------
-- Tick
---------------------------------------------------------------------------

function Sim.Step(S)
    if S.over then return end
    -- 1. actions for this tick
    local acts = S.actions
    while acts[1] and acts[1].tick <= S.tick do
        local act = table.remove(acts, 1)
        if act.tick == S.tick then Apply(S, act) end
    end
    -- 2. gold trickle
    if S.tick % D.TRICKLE_EVERY == 0 then
        for p = 1, S.players do S.gold[p] = S.gold[p] + D.TRICKLE end
    end
    -- 3. waves
    if S.phase == "break" and S.tick >= S.phaseEnd then
        StartWave(S)
    elseif S.phase == "wave" and #S.spawns == 0 and #S.mobs == 0 then
        EndWave(S)
    end
    while S.spawns[1] and S.spawns[1].tick <= S.tick do
        local sp = table.remove(S.spawns, 1)
        Spawn(S, sp.lane, sp.kind)
    end
    -- 4. defenders act
    local lust = S.tick < S.lustUntil
    for lane = 1, S.players do
        local row = S.towers[lane]
        for col = 1, D.SLOTS do
            local t = row[col]
            if t then
                if t.stun > 0 then
                    t.stun = t.stun - 1
                else
                    if t.cd > 0 then t.cd = t.cd - 1 end
                    if t.cd == 0 and Act(S, lane, col, t) then
                        local rate = t.rate
                        if TotemNear(row, col) then rate = floor(rate * D.TOTEM_HASTE / 100) end
                        if lust then rate = floor(rate / 2) end
                        t.cd = max(1, rate)
                    end
                end
            end
        end
    end
    -- 5. murlocs
    local summons = {}
    for _, m in ipairs(S.mobs) do
        if m.hp > 0 then
            local def = D.murlocs[m.kind]
            m.px = m.x
            if m.cd > 0 then m.cd = m.cd - 1 end
            -- oracles heal their friends
            if def.heals then
                m.hcd = m.hcd - 1
                if m.hcd <= 0 then
                    m.hcd = def.healEvery
                    for _, o in ipairs(S.mobs) do
                        if o.lane == m.lane and o.hp > 0 and o.hp < o.max and abs(o.x - m.x) <= def.healRange then
                            o.hp = min(o.max, o.hp + def.heals)
                            Fx(S, { k = "mheal", lane = o.lane, x = o.x })
                        end
                    end
                end
            end
            -- tidecallers call foragers from the surf
            if def.summon and S.tick % def.summon == 0 then
                summons[#summons + 1] = { lane = m.lane, x = min(D.LANE, m.x + 800) }
            end
            local t, col = Blocker(S, m)
            if t and def.leap and not m.leapt then
                m.leapt = true
                m.x = max(1, t.x - 300)
                m.px = m.x
                Fx(S, { k = "leap", lane = m.lane, x = m.x })
            elseif t then
                if def.net and not m.netted then
                    m.netted = true
                    t.stun = def.net
                    Fx(S, { k = "net", lane = m.lane, x = t.x })
                end
                if m.cd == 0 then
                    t.hp = t.hp - def.dmg
                    m.cd = def.cd
                    Fx(S, { k = "bite", lane = m.lane, x = t.x, id = m.id })
                    if t.hp <= 0 then
                        Fx(S, { k = "fall", lane = m.lane, x = t.x, kind = t.kind })
                        RemoveTower(S, m.lane, col)
                    end
                end
            else
                MoveMurloc(S, m, def)
            end
        end
    end
    for _, s in ipairs(summons) do Spawn(S, s.lane, D.murlocIndex.forager, s.x) end
    -- 6. the dead: bounty + hero xp to the lane's owner
    local alive = {}
    for _, m in ipairs(S.mobs) do
        if m.hp > 0 then
            alive[#alive + 1] = m
        elseif not m.leaked then
            local owner = m.lane
            local def = D.murlocs[m.kind]
            S.gold[owner] = S.gold[owner] + floor(def.bounty * (100 + S.mods.bounty) / 100)
            S.kills = S.kills + 1
            if def.boss then S.bossKills[#S.bossKills + 1] = m.kind end
            Fx(S, { k = "die", lane = m.lane, x = m.x, kind = m.kind, id = m.id })
            GainXp(S, owner)
        end
    end
    S.mobs = alive
    for p = 1, S.players do
        if S.gold[p] > S.maxGold then S.maxGold = S.gold[p] end
    end
    if S.lives <= 0 then
        S.lives = 0
        S.over = true
        Fx(S, { k = "over" })
    end
    S.tick = S.tick + 1
end

-- Checksum of the gameplay state (compared between clients to catch desyncs). S.fx is excluded.
function Sim.Hash(S)
    local h = 7
    local function mix(v)
        if type(v) == "boolean" then v = v and 1 or 0 end
        h = (h * 31 + (tonumber(v) or 0) % MOD) % MOD
    end
    mix(S.tick) mix(S.rng) mix(S.lives) mix(S.wave) mix(S.kills) mix(#S.mobs) mix(#S.spawns)
    mix(S.mods.hp) mix(S.mods.dmg) mix(S.mods.haste) mix(S.mods.bounty) mix(#S.boonsTaken)
    for p = 1, S.players do
        mix(S.gold[p]) mix(S.votes[p]) mix(S.heroXp[p]) mix(S.heroLevel[p]) mix(S.talentPts[p])
        for col = 1, D.SLOTS do
            local t = S.towers[p][col]
            if t then mix(col) mix(t.kind) mix(t.rank) mix(t.hp) mix(t.cd) mix(t.stun) end
        end
        mix(S.heroReady[p]) mix(S.heroes[p].power)
    end
    for _, m in ipairs(S.mobs) do mix(m.id) mix(m.lane) mix(m.x) mix(m.hp) end
    return h
end

-- CDLoot Games/RPG/Sim.lua
-- ns.RPGSim: the deterministic "Delve" simulation (real-time, 10 ticks/s). Pure Lua, integers, arrays only, so every
-- client that applies the same actions at the same ticks computes the same run (host-relayed lockstep, like Murloc
-- Defense). S is plain data (serializable for resyncs); S.fx is a cosmetic event list the UI drains (never hashed).
--
-- Actions: { tick, p, k, a, b, seq }
--   "c" cast ability a (1..4) on target b (enemy index for enemy spells, party index for ally spells)
--   "v" vote for path option a (1..2)      "l" take loot offer a (1..3)      "t" take talent offer a (1..3)
local addonName, ns = ...

local Sim = ns:NewModule("RPGSim")
local D = ns.RPGData

local floor, min, max, abs = math.floor, math.min, math.max, math.abs
local MOD = 2147483647
local FX_CAP = 400
local MOD_KEYS = { "dmg", "heal", "hp", "haste", "crit", "regen", "leech", "thorns", "dr" }

local function Rand(S, n)
    S.rng = (S.rng * 16807) % MOD
    return (S.rng % n) + 1
end

local function Fx(S, e)
    if #S.fx >= FX_CAP then S.fx = {} end
    S.fx[#S.fx + 1] = e
end

-- n distinct values from 1..size that pass `ok`, in pick order.
local function Pick(S, size, n, ok)
    local pool = {}
    for i = 1, size do if not ok or ok(i) then pool[#pool + 1] = i end end
    local out = {}
    for _ = 1, min(n, #pool) do out[#out + 1] = table.remove(pool, Rand(S, #pool)) end
    return out
end

---------------------------------------------------------------------------
-- Heroes
---------------------------------------------------------------------------

local function CleanHero(h)
    h = type(h) == "table" and h or {}
    local role = D.kits[h.role] and h.role or "melee"
    local class = D.abilityNames[h.class] and h.class or "WARRIOR"
    local power = max(D.POWER_MIN, min(D.POWER_MAX, floor(tonumber(h.power) or 100)))
    local name = type(h.name) == "string" and h.name:sub(1, 24) or "Hero"
    return role, class, power, name
end

local function EmptyMods() local m = {} for _, k in ipairs(MOD_KEYS) do m[k] = 0 end return m end

-- Recomputes a hero's modifiers (loot + talents + party blessings) and max hp (keeping the hp ratio).
local function Recalc(S, h)
    local m = EmptyMods()
    local function add(src) for _, k in ipairs(MOD_KEYS) do if src[k] then m[k] = m[k] + src[k] end end end
    for _, id in ipairs(h.loot) do add(D.loot[id]) end
    local pool = D.talents[h.role]
    for i, n in ipairs(h.talents) do
        if n > 0 then for _ = 1, n do add(pool[i][3]) end end
    end
    for _, id in ipairs(S.blessings) do add(D.blessings[id]) end
    m.dr = min(60, m.dr)
    m.haste = min(50, m.haste)
    h.mods = m
    local base = D.roleStats[h.role].hp
    local newMax = floor(base * h.power / 100 * (100 + m.hp) / 100)
    if h.max and h.max > 0 then
        h.hp = floor(h.hp * newMax / h.max)
    else
        h.hp = newMax
    end
    h.max = newMax
end

local function NewHero(S, raw)
    local role, class, power, name = CleanHero(raw)
    local resType = D.ResourceFor(class, role)
    local talents = {}
    for i = 1, #D.talents[role] do talents[i] = 0 end
    local h = { name = name, class = class, role = role, power = power, basePower = power, resType = resType,
                res = D.resources[resType].start, resMax = D.resources[resType].max,
                cds = { 0, 0, 0, 0, 0 }, gcd = 0, cast = false, absorb = 0, hots = {}, drUntil = 0, drAmt = 0,
                buffUntil = 0, buffAmt = 0, stunUntil = 0, dead = false, autoCd = 0, target = 1,
                loot = {}, talents = talents, level = 1, xp = 0, talentOffer = false, talentPts = 0,
                lootOffer = false, lootTaken = true, vote = 0, deaths = 0 }
    Recalc(S, h)
    return h
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- heroes: array of { role, class, power, name } per player. opts = { heroic = bool, dungeon = index }
function Sim.New(seed, heroes, opts)
    opts = opts or {}
    local s = (tonumber(seed) or 1) % MOD
    if s <= 0 then s = s + MOD - 1 end
    local n = max(1, min(D.MAX_PLAYERS, #(heroes or {})))
    local S = { tick = 0, rng = s, players = n, heroic = opts.heroic and true or false,
                dungeon = D.dungeons[opts.dungeon or 1] and (opts.dungeon or 1) or 1,
                party = {}, enemies = {}, blessings = {}, depth = 0, elitesDone = 0, phase = "path", phaseEnd = 0,
                pathOffer = false, room = false, actions = {}, fx = {}, nextUid = 1,
                interrupts = 0, bossKills = {}, fightDeaths = 0, flawlessBoss = false, won = false, over = false }
    for p = 1, n do S.party[p] = NewHero(S, heroes and heroes[p]) end
    return S
end

function Sim.Queue(S, act)
    if type(act) ~= "table" or type(act.tick) ~= "number" or act.tick < S.tick then return false end
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
-- Scaling
---------------------------------------------------------------------------

local function EnemyHpPct(S)
    local pct = D.PartyHpPct(S.players) * D.DepthPct(S.depth) / 100
    if S.heroic then pct = floor(pct * D.HEROIC.hp / 100) end
    return floor(pct)
end

local function EnemyDmgPct(S)
    local pct = floor((100 + 6 * S.depth) * D.PartyDmgPct(S.players) / 100)
    if S.heroic then pct = floor(pct * D.HEROIC.dmg / 100) end
    return pct
end

local function Spawn(S, id)
    local def = D.enemies[D.enemyIndex[id]]
    local hp = floor(def.hp * EnemyHpPct(S) / 100)
    local e = { uid = S.nextUid, kind = D.enemyIndex[id], hp = hp, max = hp, autoCd = 10 + Rand(S, 10), cast = false,
                abCd = {}, threat = {}, stunUntil = 0, ccUntil = 0, slowUntil = 0, tauntP = 0, tauntUntil = 0, enraged = false,
                triggered = {}, dead = false }
    for i, ab in ipairs(def.abilities or {}) do
        e.abCd[i] = ab.cd and (S.tick + floor(ab.cd / 2) + Rand(S, 20)) or 0
        e.triggered[i] = false
    end
    for p = 1, S.players do e.threat[p] = 0 end
    S.nextUid = S.nextUid + 1
    S.enemies[#S.enemies + 1] = e
    if def.boss then Fx(S, { k = "boss", kind = e.kind }) end
    return e
end

---------------------------------------------------------------------------
-- Rooms and phases
---------------------------------------------------------------------------

local function Dungeon(S) return D.dungeons[S.dungeon] end

local function OfferPath(S)
    local dg = Dungeon(S)
    S.phase = "path"
    S.phaseEnd = S.tick + D.LOOT_TIME
    for p = 1, S.players do S.party[p].vote = 0 end
    if S.depth >= dg.depth then
        S.pathOffer = { "boss" }
        return
    end
    local kinds = { "fight", "fight", "treasure", "shrine", "rest" }
    if S.depth >= 1 and S.elitesDone < #dg.elites then
        kinds[#kinds + 1] = "elite"
        kinds[#kinds + 1] = "elite"
    end
    local a = kinds[Rand(S, #kinds)]
    local b = a
    local guard = 0
    while b == a and guard < 10 do
        b = kinds[Rand(S, #kinds)]
        guard = guard + 1
    end
    S.pathOffer = { a, b }
end

local function OfferLoot(S)
    S.phase = "loot"
    S.phaseEnd = S.tick + D.LOOT_TIME
    for p = 1, S.players do
        local h = S.party[p]
        h.lootOffer = Pick(S, #D.loot, 3)
        h.lootTaken = false
    end
end

local function OfferTalents(S, h)
    if h.talentOffer or h.talentPts <= 0 then return end
    local offer = Pick(S, #D.talents[h.role], 3, function(i) return h.talents[i] < D.TALENT_MAX end)
    h.talentOffer = #offer > 0 and offer or false
    if not h.talentOffer then h.talentPts = 0 end
end

local function GainXp(S)
    for p = 1, S.players do
        local h = S.party[p]
        h.xp = h.xp + D.XP_PER_ROOM
        if h.xp >= D.XpForLevel(h.level) then
            h.xp = 0
            h.level = h.level + 1
            h.power = floor(h.basePower * (100 + 5 * (h.level - 1)) / 100)
            h.talentPts = h.talentPts + 1
            Recalc(S, h)
            Fx(S, { k = "level", p = p, n = h.level })
            OfferTalents(S, h)
        end
    end
end

local function ResetCombatState(S)
    for p = 1, S.players do
        local h = S.party[p]
        h.cds[D.ABILITIES] = 0                  -- a fresh potion for every fight
        h.cast, h.hots, h.absorb, h.gcd, h.stunUntil = false, {}, 0, 0, 0
        h.drUntil, h.buffUntil = 0, 0
    end
end

local function EnterRoom(S, kind)
    local dg = Dungeon(S)
    S.room = kind
    S.enemies = {}
    S.fightDeaths = 0
    Fx(S, { k = "room", room = kind, depth = S.depth + 1 })
    if kind == "fight" then
        local pack = dg.packs[Rand(S, #dg.packs)]
        for n, id in ipairs(pack) do
            if n <= D.MaxPack(S.players) then Spawn(S, id) end
        end
        S.phase = "combat"
    elseif kind == "elite" then
        S.elitesDone = S.elitesDone + 1
        Spawn(S, dg.elites[S.elitesDone])
        if S.players >= 3 then Spawn(S, "cutpurse") end
        S.phase = "combat"
    elseif kind == "boss" then
        Spawn(S, dg.boss)
        if S.players >= 2 then Spawn(S, "cutpurse") end
        S.phase = "combat"
    elseif kind == "treasure" then
        S.depth = S.depth + 1
        GainXp(S)
        OfferLoot(S)
    elseif kind == "shrine" then
        S.depth = S.depth + 1
        local b = Rand(S, #D.blessings)
        S.blessings[#S.blessings + 1] = b
        for p = 1, S.players do Recalc(S, S.party[p]) end
        Fx(S, { k = "blessing", b = b })
        GainXp(S)
        OfferPath(S)
    elseif kind == "rest" then
        S.depth = S.depth + 1
        for p = 1, S.players do
            local h = S.party[p]
            h.dead, h.hp, h.res = false, h.max, h.resType == "rage" and h.res or h.resMax
        end
        Fx(S, { k = "rest" })
        GainXp(S)
        OfferPath(S)
    end
    ResetCombatState(S)
end

local function WinFight(S)
    local wasBoss = S.room == "boss"
    S.depth = S.depth + 1
    for p = 1, S.players do
        local h = S.party[p]
        if h.dead then
            h.dead = false
            h.hp = floor(h.max * D.REVIVE_PCT / 100)
        else
            h.hp = min(h.max, h.hp + floor(h.max * D.RECOVER_PCT / 100))
        end
    end
    ResetCombatState(S)
    Fx(S, { k = "victory", room = S.room })
    GainXp(S)
    if wasBoss then
        S.won = true
        S.flawlessBoss = S.fightDeaths == 0
        S.phase = "won"
        S.over = true
        return
    end
    OfferLoot(S)
end

local function ResolveVote(S)
    local offer = S.pathOffer
    local counts = {}
    for i = 1, #offer do counts[i] = 0 end
    for p = 1, S.players do
        local v = S.party[p].vote
        if counts[v] then counts[v] = counts[v] + 1 end
    end
    local best = 1
    for i = 2, #offer do if counts[i] > counts[best] then best = i end end
    S.pathOffer = false
    EnterRoom(S, offer[best])
end

---------------------------------------------------------------------------
-- Combat helpers
---------------------------------------------------------------------------

local function Alive(S)
    local out = {}
    for p = 1, S.players do if not S.party[p].dead then out[#out + 1] = p end end
    return out
end

local function LivingEnemy(S, i)
    local e = S.enemies[i]
    return e and not e.dead and e or nil
end

local function FirstEnemy(S)
    for i, e in ipairs(S.enemies) do if not e.dead then return i end end
    return nil
end

local function Crit(S, h, heal)
    return Rand(S, 100) <= D.CRIT + h.mods.crit
end

local function HeroAmount(S, h, base, heal)
    local pct = heal and h.mods.heal or h.mods.dmg
    if S.tick < h.buffUntil then pct = pct + h.buffAmt end
    local amt = floor(base * h.power / 100 * (100 + pct) / 100)
    local crit = Crit(S, h, heal)
    if crit then amt = heal and floor(amt * 3 / 2) or amt * 2 end
    return amt, crit
end

local function HealHero(S, p, amt, from)
    local h = S.party[p]
    if h.dead then return 0 end
    local before = h.hp
    h.hp = min(h.max, h.hp + amt)
    local done = h.hp - before
    if from then
        -- healing threat: half the amount, spread over every enemy that is engaged
        for _, e in ipairs(S.enemies) do
            if not e.dead then e.threat[from] = e.threat[from] + floor(done / 2) end
        end
    end
    return done
end

local function KillHero(S, p)
    local h = S.party[p]
    h.dead, h.hp, h.cast, h.hots, h.absorb = true, 0, false, {}, 0
    h.deaths = h.deaths + 1
    S.fightDeaths = S.fightDeaths + 1
    for _, e in ipairs(S.enemies) do e.threat[p] = 0 end
    Fx(S, { k = "herodie", p = p })
end

-- Enemy damage to a hero (dr, absorb, rage, thorns).
local function HitHero(S, p, amt, e, label)
    local h = S.party[p]
    if h.dead then return end
    local dr = h.mods.dr + (S.tick < h.drUntil and h.drAmt or 0)
    amt = floor(amt * (100 - min(80, dr)) / 100)
    local absorbed = min(h.absorb, amt)
    h.absorb = h.absorb - absorbed
    amt = amt - absorbed
    h.hp = h.hp - amt
    if h.resType == "rage" then h.res = min(h.resMax, h.res + floor(amt / 3) + 2) end
    if e and h.mods.thorns > 0 then e.hp = e.hp - h.mods.thorns end
    Fx(S, { k = "hurt", p = p, amt = amt, absorbed = absorbed > 0 and absorbed or nil, label = label })
    if h.hp <= 0 then KillHero(S, p) end
end

local function DamageEnemy(S, i, amt, p, threatMult, crit, label)
    local e = S.enemies[i]
    if not e or e.dead then return end
    e.hp = e.hp - amt
    e.ccUntil = 0                                 -- damage breaks crowd control
    if p then
        e.threat[p] = e.threat[p] + floor(amt * (threatMult or 1))
        local h = S.party[p]
        if h.mods.leech > 0 then HealHero(S, p, floor(amt * h.mods.leech / 100)) end
        if h.resType == "rage" then h.res = min(h.resMax, h.res + 3) end
    end
    Fx(S, { k = "hit", e = i, amt = amt, crit = crit or nil, p = p, label = label })
end

-- The enemy's current victim: taunter, else highest threat (ties: lowest index), else first living hero.
local function EnemyTarget(S, e)
    if e.tauntP > 0 and S.tick < e.tauntUntil and not S.party[e.tauntP].dead then return e.tauntP end
    local best, bestT = nil, -1
    for p = 1, S.players do
        if not S.party[p].dead and e.threat[p] > bestT then best, bestT = p, e.threat[p] end
    end
    return best
end

---------------------------------------------------------------------------
-- Hero abilities
---------------------------------------------------------------------------

local function Ability(h, a) return D.kits[h.role][a] end

local function Hasted(h, ticks) return floor(ticks * (100 - h.mods.haste) / 100) end

function Sim.CanCast(S, p, a, target)
    local h = S.party[p]
    local ab = h and Ability(h, a)
    if not ab or S.phase ~= "combat" or h.dead or h.cast or S.tick < h.stunUntil then return false end
    if (S.tick < h.gcd and ab.kind ~= "potion") or S.tick < h.cds[a] or h.res < (ab.cost or 0) then return false end
    if ab.tgt == "enemy" then return LivingEnemy(S, target) ~= nil end
    if ab.tgt == "ally" then return S.party[target] ~= nil and not S.party[target].dead end
    return true
end

local function Resolve(S, p, a, target)
    local h = S.party[p]
    local ab = Ability(h, a)
    local label = a
    if ab.kind == "dmg" then
        if not LivingEnemy(S, target) then return end
        local amt, crit = HeroAmount(S, h, ab.amt)
        DamageEnemy(S, target, amt, p, ab.threat, crit, label)
    elseif ab.kind == "aoe" then
        for i, e in ipairs(S.enemies) do
            if not e.dead then
                local amt, crit = HeroAmount(S, h, ab.amt)
                DamageEnemy(S, i, amt, p, ab.threat, crit, label)
            end
        end
    elseif ab.kind == "heal" then
        local amt, crit = HeroAmount(S, h, ab.amt, true)
        local done = HealHero(S, target, amt, p)
        Fx(S, { k = "heal", p = target, from = p, amt = done, crit = crit or nil })
    elseif ab.kind == "hot" then
        local t = S.party[target]
        if t.dead then return end
        local total = HeroAmount(S, h, ab.amt, true)
        local ticks = floor(ab.dur / 10)
        t.hots[#t.hots + 1] = { per = floor(total / ticks), left = ticks, from = p }
        Fx(S, { k = "buff", p = target, what = "hot" })
    elseif ab.kind == "shield" then
        local t = S.party[target]
        if t.dead then return end
        t.absorb = max(t.absorb, (HeroAmount(S, h, ab.amt, true)))
        Fx(S, { k = "buff", p = target, what = "shield" })
    elseif ab.kind == "taunt" then
        local e = LivingEnemy(S, target)
        if not e then return end
        local top = 0
        for q = 1, S.players do top = max(top, e.threat[q]) end
        e.threat[p] = top + 10
        e.tauntP, e.tauntUntil = p, S.tick + D.TAUNT_TIME
        Fx(S, { k = "taunt", e = target, p = p })
    elseif ab.kind == "interrupt" then
        local e = LivingEnemy(S, target)
        if not e then return end
        if e.cast and e.cast.interruptible then
            local ab2 = D.enemies[e.kind].abilities[e.cast.ab]
            e.cast = false
            S.interrupts = S.interrupts + 1
            Fx(S, { k = "interrupt", e = target, p = p, name = ab2 and ab2.name })
        end
        if (ab.amt or 0) > 0 then DamageEnemy(S, target, (HeroAmount(S, h, ab.amt)), p, 1, false, label) end
    elseif ab.kind == "cc" then
        local e = LivingEnemy(S, target)
        if not e then return end
        if D.enemies[e.kind].boss then
            e.slowUntil = S.tick + ab.dur          -- bosses can't be controlled, but they can be slowed
            Fx(S, { k = "slow", e = target, p = p })
        else
            e.ccUntil = S.tick + ab.dur
            e.cast = false
            Fx(S, { k = "cc", e = target, p = p })
        end
    elseif ab.kind == "buff" then
        h.buffUntil, h.buffAmt = S.tick + ab.dur, ab.amt
        Fx(S, { k = "buff", p = p, what = "buff" })
    elseif ab.kind == "potion" then
        local done = HealHero(S, p, floor(h.max * ab.amt / 100))
        Fx(S, { k = "heal", p = p, from = p, amt = done, potion = true })
    elseif ab.kind == "selfdr" then
        h.drUntil, h.drAmt = S.tick + ab.dur, ab.amt
        Fx(S, { k = "buff", p = p, what = "dr" })
    end
end

local function StartCast(S, p, a, target)
    local h = S.party[p]
    local ab = Ability(h, a)
    h.res = h.res - (ab.cost or 0)
    if ab.kind ~= "potion" then h.gcd = S.tick + max(8, Hasted(h, D.GCD)) end
    if (ab.cd or 0) > 0 then h.cds[a] = S.tick + Hasted(h, ab.cd) end
    if ab.tgt == "enemy" then h.target = target end
    Fx(S, { k = "cast", p = p, a = a, target = target, tgt = ab.tgt })
    if (ab.cast or 0) > 0 then
        h.cast = { a = a, target = target, start = S.tick, stop = S.tick + max(5, Hasted(h, ab.cast)) }
    else
        Resolve(S, p, a, target)
    end
end

---------------------------------------------------------------------------
-- Enemy AI
---------------------------------------------------------------------------

local function EnemyAbility(S, i, e, idx)
    local def = D.enemies[e.kind]
    local ab = def.abilities[idx]
    local dmgPct = EnemyDmgPct(S) * (e.enraged and 150 or 100) / 100
    local amt = floor((ab.amt or 0) * dmgPct / 100)
    if ab.kind == "slam" then
        local p = EnemyTarget(S, e)
        if p then HitHero(S, p, amt, e, ab.name) end
    elseif ab.kind == "aoe" then
        for p = 1, S.players do HitHero(S, p, amt, e, ab.name) end
    elseif ab.kind == "bolt" then
        local alive = Alive(S)
        if #alive > 0 then HitHero(S, alive[Rand(S, #alive)], amt, e, ab.name) end
    elseif ab.kind == "mend" then
        local best, bestPct
        for j, o in ipairs(S.enemies) do
            if not o.dead and o.hp < o.max then
                local pct = floor(o.hp * 1000 / o.max)
                if not bestPct or pct < bestPct then best, bestPct = j, pct end
            end
        end
        if best then
            local o = S.enemies[best]
            local heal = floor((ab.amt or 0) * EnemyHpPct(S) / 100)
            o.hp = min(o.max, o.hp + heal)
            Fx(S, { k = "ehealed", e = best, amt = heal })
        end
    elseif ab.kind == "stun" then
        for p = 1, S.players do
            local h = S.party[p]
            if not h.dead then
                h.stunUntil = S.tick + ab.dur
                h.cast = false
            end
        end
        Fx(S, { k = "stun", e = i, name = ab.name })
    end
end

local function EnemyThink(S, i, e)
    local def = D.enemies[e.kind]
    -- hp-threshold triggers (once)
    for idx, ab in ipairs(def.abilities or {}) do
        if ab.at and not e.triggered[idx] and e.hp * 100 <= e.max * ab.at then
            e.triggered[idx] = true
            if ab.kind == "enrage" then
                e.enraged = true
                Fx(S, { k = "enrage", e = i, name = ab.name })
            elseif ab.kind == "summon" then
                for n, id in ipairs(ab.adds) do
                    if S.players >= 2 or n == 1 then Spawn(S, id) end
                end
                Fx(S, { k = "summon", e = i, name = ab.name })
            end
        end
    end
    if S.tick < e.stunUntil or S.tick < e.ccUntil then return end
    -- casting
    if e.cast then
        if S.tick >= e.cast.stop then
            local idx = e.cast.ab
            e.cast = false
            EnemyAbility(S, i, e, idx)
        end
        return
    end
    -- start a cast when one is ready
    for idx, ab in ipairs(def.abilities or {}) do
        if ab.cd and ab.cast and S.tick >= e.abCd[idx] then
            e.abCd[idx] = S.tick + ab.cd
            e.cast = { ab = idx, start = S.tick, stop = S.tick + ab.cast, interruptible = ab.interruptible or false }
            Fx(S, { k = "ecast", e = i, name = ab.name, stop = e.cast.stop })
            return
        end
    end
    -- auto attack
    if e.autoCd > 0 then
        e.autoCd = e.autoCd - 1
        return
    end
    local p = EnemyTarget(S, e)
    if not p then
        local alive = Alive(S)
        if #alive == 0 then return end
        p = alive[1]
        e.threat[p] = 1
    end
    e.autoCd = (S.tick < (e.slowUntil or 0)) and def.every * 2 or def.every
    local amt = floor(def.dmg * EnemyDmgPct(S) / 100 * (e.enraged and 150 or 100) / 100)
    HitHero(S, p, amt, e)
    Fx(S, { k = "swing", e = i, p = p })
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function Apply(S, act)
    local p = act.p
    local h = type(p) == "number" and S.party[p]
    if not h then return end
    local k = act.k
    if k == "c" then
        if Sim.CanCast(S, p, act.a, act.b) then StartCast(S, p, act.a, act.b) end
    elseif k == "v" then
        if S.phase == "path" and S.pathOffer and S.pathOffer[act.a] then h.vote = act.a end
    elseif k == "l" then
        if S.phase == "loot" and not h.lootTaken and h.lootOffer and h.lootOffer[act.a] then
            h.loot[#h.loot + 1] = h.lootOffer[act.a]
            h.lootTaken, h.lootOffer = true, false
            Recalc(S, h)
            Fx(S, { k = "loot", p = p, item = h.loot[#h.loot] })
        end
    elseif k == "t" then
        local offer = h.talentOffer
        local choice = offer and offer[act.a]
        if not choice then return end
        h.talents[choice] = h.talents[choice] + 1
        h.talentOffer = false
        h.talentPts = h.talentPts - 1
        Recalc(S, h)
        OfferTalents(S, h)
    end
end

---------------------------------------------------------------------------
-- Tick
---------------------------------------------------------------------------

local function HeroTick(S, p, h)
    if h.dead then return end
    local r = D.resources[h.resType]
    local every = r.every
    if r.regen > 0 and S.tick % every == 0 then
        h.res = min(h.resMax, h.res + r.regen + (h.resType == "mana" and h.mods.regen or 0))
    end
    if S.phase ~= "combat" then return end
    -- heal over time (every second)
    if S.tick % 10 == 0 and #h.hots > 0 then
        local keep = {}
        for _, hot in ipairs(h.hots) do
            local done = HealHero(S, p, hot.per, hot.from)
            if done > 0 then Fx(S, { k = "heal", p = p, from = hot.from, amt = done, hot = true }) end
            hot.left = hot.left - 1
            if hot.left > 0 then keep[#keep + 1] = hot end
        end
        h.hots = keep
    end
    if S.tick < h.stunUntil then return end
    -- finishing a cast
    if h.cast and S.tick >= h.cast.stop then
        local c = h.cast
        h.cast = false
        Resolve(S, p, c.a, c.target)
    end
    -- auto attack (melee / ranged / tank)
    local kit = D.kits[h.role]
    if kit.auto and not h.cast then
        if h.autoCd > 0 then
            h.autoCd = h.autoCd - 1
        else
            local t = LivingEnemy(S, h.target) and h.target or FirstEnemy(S)
            if t then
                h.target = t
                h.autoCd = Hasted(h, kit.auto.every)
                local amt, crit = HeroAmount(S, h, kit.auto.dmg)
                DamageEnemy(S, t, amt, p, h.role == "tank" and 2 or 1, crit, "auto")
            end
        end
    end
end

function Sim.Step(S)
    if S.over then return end
    local acts = S.actions
    while acts[1] and acts[1].tick <= S.tick do
        local act = table.remove(acts, 1)
        if act.tick == S.tick then Apply(S, act) end
    end
    -- phase flow
    if S.phase == "path" then
        if not S.pathOffer then OfferPath(S) end
        local all = true
        for p = 1, S.players do if S.party[p].vote == 0 then all = false end end
        if S.tick > 0 and (all or S.tick >= S.phaseEnd) then ResolveVote(S) end
        if S.tick == 0 and S.depth == 0 then
            S.pathOffer = false
            EnterRoom(S, "fight")          -- the first room is always a fight
        end
    elseif S.phase == "loot" then
        local all = true
        for p = 1, S.players do if not S.party[p].lootTaken then all = false end end
        if S.tick >= S.phaseEnd then
            for p = 1, S.players do
                if not S.party[p].lootTaken then Apply(S, { p = p, k = "l", a = 1 }) end
            end
            all = true
        end
        if all then OfferPath(S) end
    end
    for p = 1, S.players do HeroTick(S, p, S.party[p]) end
    if S.phase == "combat" then
        for i, e in ipairs(S.enemies) do
            if not e.dead then EnemyThink(S, i, e) end
        end
        -- deaths
        local anyAlive = false
        for i, e in ipairs(S.enemies) do
            if not e.dead then
                if e.hp <= 0 then
                    e.dead, e.hp, e.cast = true, 0, false
                    local def = D.enemies[e.kind]
                    if def.boss then S.bossKills[#S.bossKills + 1] = e.kind end
                    Fx(S, { k = "die", e = i })
                else
                    anyAlive = true
                end
            end
        end
        if #Alive(S) == 0 then
            S.phase = "over"
            S.over = true
            Fx(S, { k = "wipe" })
        elseif not anyAlive then
            WinFight(S)
        end
    end
    S.tick = S.tick + 1
end

function Sim.Hash(S)
    local h = 7
    local function mix(v)
        if type(v) == "boolean" then v = v and 1 or 0 end
        h = (h * 31 + (tonumber(v) or 0) % MOD) % MOD
    end
    mix(S.tick) mix(S.rng) mix(S.depth) mix(#S.enemies) mix(S.interrupts) mix(#S.blessings)
    for p = 1, S.players do
        local x = S.party[p]
        mix(x.hp) mix(x.max) mix(x.res) mix(x.dead) mix(x.level) mix(#x.loot) mix(x.absorb) mix(x.gcd)
        mix(x.cast and x.cast.stop or 0)
    end
    for _, e in ipairs(S.enemies) do mix(e.uid) mix(e.hp) mix(e.dead) mix(e.cast and e.cast.stop or 0) end
    return h
end

-- CDLoot Games/RPG/Sim.lua
-- ns.RPGSim: the deterministic, turn-based "Delve" simulation. Pure Lua, integers, arrays only: every client that
-- applies the same commits (host-ordered) computes the same run. S is plain data (serializable for resyncs); S.fx is
-- a cosmetic, ordered event list the UI plays back (never hashed).
--
-- A combat round: enemies show their INTENT (attack X / casting Y) -> every player picks one ability + target ->
-- Sim.ResolveRound: heroes act in party order, then each enemy carries out its intent (interrupted / crowd
-- controlled ones don't), then end-of-round effects, then the next intents.
-- Out of combat: Sim.Apply for "v" (path vote), "l" (loot pick), "t" (talent pick); the run moves on by itself once
-- everyone has chosen (the host commits a default for anyone who times out).
local addonName, ns = ...

local Sim = ns:NewModule("RPGSim")
local D = ns.RPGData

local floor, min, max = math.floor, math.min, math.max
local MOD = 2147483647
local FX_CAP = 400
local MOD_KEYS = { "dmg", "heal", "hp", "haste", "crit", "regen", "leech", "thorns", "dr" }

local function Rand(S, n)
    S.rng = (S.rng * 16807) % MOD
    return (S.rng % n) + 1
end

local function Fx(S, e)
    if #S.fx >= FX_CAP then S.fx = {} end
    S.fxSeq = S.fxSeq + 1
    e.n = S.fxSeq
    S.fx[#S.fx + 1] = e
end

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

local function Recalc(S, h)
    local m = {}
    for _, k in ipairs(MOD_KEYS) do m[k] = 0 end
    local function add(src) for _, k in ipairs(MOD_KEYS) do if src[k] then m[k] = m[k] + src[k] end end end
    for _, id in ipairs(h.loot) do add(D.loot[id]) end
    local pool = D.talents[h.role]
    for i, n in ipairs(h.talents) do for _ = 1, n do add(pool[i][3]) end end
    for _, id in ipairs(S.blessings) do add(D.blessings[id]) end
    m.dr, m.haste = min(60, m.dr), min(50, m.haste)
    h.mods = m
    local newMax = floor(D.roleStats[h.role].hp * h.power / 100 * (100 + m.hp) / 100)
    if h.max and h.max > 0 then h.hp = floor(h.hp * newMax / h.max) else h.hp = newMax end
    h.max = newMax
end

local function NewHero(S, raw)
    local role, class, power, name = CleanHero(raw)
    local resType = D.ResourceFor(class, role)
    local talents = {}
    for i = 1, #D.talents[role] do talents[i] = 0 end
    local cds = {}
    for a = 1, D.ABILITIES do cds[a] = 0 end
    local h = { name = name, class = class, role = role, power = power, basePower = power, resType = resType,
                res = D.resources[resType].start, resMax = D.resources[resType].max, cds = cds, absorb = 0, hots = {},
                drRounds = 0, drAmt = 0, buffRounds = 0, buffAmt = 0, stunRounds = 0, dead = false,
                loot = {}, talents = talents, level = 1, xp = 0, talentOffer = false, talentPts = 0,
                lootOffer = false, lootTaken = true, vote = 0, deaths = 0 }
    Recalc(S, h)
    return h
end

---------------------------------------------------------------------------
-- Scaling + spawning
---------------------------------------------------------------------------

local function EnemyHpPct(S)
    local pct = D.PartyHpPct(S.players) * D.DepthPct(S.depth) / 100
    if S.heroic then pct = pct * D.HEROIC.hp / 100 end
    return floor(pct)
end

local function EnemyDmgPct(S)
    local pct = floor((100 + 6 * S.depth) * D.PartyDmgPct(S.players) / 100)
    if S.heroic then pct = floor(pct * D.HEROIC.dmg / 100) end
    return pct
end

local function Spawn(S, id)
    local kind = D.enemyIndex[id]
    local def = D.enemies[kind]
    local hp = floor(def.hp * EnemyHpPct(S) / 100)
    local e = { uid = S.nextUid, kind = kind, hp = hp, max = hp, abCd = {}, threat = {}, ccRounds = 0, slowRounds = 0,
                tauntP = 0, tauntRounds = 0, enraged = false, triggered = {}, dead = false, intent = false }
    for i, ab in ipairs(def.abilities or {}) do
        e.abCd[i] = ab.cd and (1 + Rand(S, ab.cd)) or 0
        e.triggered[i] = false
    end
    for p = 1, S.players do e.threat[p] = 0 end
    S.nextUid = S.nextUid + 1
    S.enemies[#S.enemies + 1] = e
    if def.boss then Fx(S, { k = "boss", kind = kind }) end
    return e
end

---------------------------------------------------------------------------
-- Targets / threat / intents
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

function Sim.FirstEnemy(S)
    for i, e in ipairs(S.enemies) do if not e.dead then return i end end
    return nil
end

-- Taunter, else highest threat (ties: lowest index), else the first living hero.
local function EnemyTarget(S, e)
    if e.tauntP > 0 and e.tauntRounds > 0 and not S.party[e.tauntP].dead then return e.tauntP end
    local best, bestT = nil, -1
    for p = 1, S.players do
        if not S.party[p].dead and e.threat[p] > bestT then best, bestT = p, e.threat[p] end
    end
    return best
end
Sim.EnemyTarget = EnemyTarget

local function PlanEnemies(S)
    for _, e in ipairs(S.enemies) do
        if e.dead then
            e.intent = false
        elseif e.ccRounds > 0 then
            e.intent = { k = "cc" }
        else
            local def = D.enemies[e.kind]
            local intent
            for idx, ab in ipairs(def.abilities or {}) do
                if ab.telegraph and e.abCd[idx] <= 0 then
                    local target = 0
                    if ab.kind == "slam" then
                        target = EnemyTarget(S, e) or 0
                    elseif ab.kind == "bolt" then
                        local alive = Alive(S)
                        target = #alive > 0 and alive[Rand(S, #alive)] or 0
                    end
                    intent = { k = "cast", ab = idx, target = target, interruptible = ab.interruptible or false }
                    e.abCd[idx] = ab.cd
                    break
                end
            end
            e.intent = intent or { k = "attack", target = EnemyTarget(S, e) or 0 }
        end
    end
end

---------------------------------------------------------------------------
-- Rooms and phases
---------------------------------------------------------------------------

local function Dungeon(S) return D.dungeons[S.dungeon] end

local function OfferPath(S)
    local dg = Dungeon(S)
    S.phase = "path"
    S.enemies = {}
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
    local b, guard = a, 0
    while b == a and guard < 10 do
        b = kinds[Rand(S, #kinds)]
        guard = guard + 1
    end
    S.pathOffer = { a, b }
end

local function OfferLoot(S)
    S.phase = "loot"
    for p = 1, S.players do
        local h = S.party[p]
        h.lootOffer, h.lootTaken = Pick(S, #D.loot, 3), false
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

local function ResetCombat(S)
    for p = 1, S.players do
        local h = S.party[p]
        h.hots, h.absorb, h.stunRounds, h.drRounds, h.buffRounds = {}, 0, 0, 0, 0
        for a = 1, D.ABILITIES do h.cds[a] = 0 end
        if h.resType == "rage" then h.res = D.resources.rage.start end
    end
end

local function EnterRoom(S, kind)
    local dg = Dungeon(S)
    S.room, S.enemies, S.fightDeaths, S.round = kind, {}, 0, 0
    S.pathOffer = false
    ResetCombat(S)
    Fx(S, { k = "room", room = kind, depth = S.depth + 1 })
    if kind == "fight" or kind == "elite" or kind == "boss" then
        if kind == "fight" then
            local pack = dg.packs[Rand(S, #dg.packs)]
            for n, id in ipairs(pack) do if n <= D.MaxPack(S.players) then Spawn(S, id) end end
        elseif kind == "elite" then
            S.elitesDone = S.elitesDone + 1
            Spawn(S, dg.elites[S.elitesDone])
            if S.players >= 3 then Spawn(S, "cutpurse") end
        else
            Spawn(S, dg.boss)
            if S.players >= 2 then Spawn(S, "cutpurse") end
        end
        S.phase = "combat"
        S.round = 1
        PlanEnemies(S)
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
            h.dead, h.hp = false, h.max
            if h.resType == "mana" then h.res = h.resMax end
        end
        Fx(S, { k = "rest" })
        GainXp(S)
        OfferPath(S)
    end
end

local function WinFight(S)
    local wasBoss = S.room == "boss"
    S.depth = S.depth + 1
    for p = 1, S.players do
        local h = S.party[p]
        if h.dead then
            h.dead, h.hp = false, floor(h.max * D.REVIVE_PCT / 100)
        else
            h.hp = min(h.max, h.hp + floor(h.max * D.RECOVER_PCT / 100))
        end
    end
    Fx(S, { k = "victory", room = S.room })
    GainXp(S)
    if wasBoss then
        S.won, S.flawlessBoss, S.phase, S.over = true, S.fightDeaths == 0, "won", true
        return
    end
    OfferLoot(S)
end

---------------------------------------------------------------------------
-- Combat
---------------------------------------------------------------------------

local function HeroAmount(S, h, base, heal)
    local pct = heal and h.mods.heal or h.mods.dmg
    if h.buffRounds > 0 then pct = pct + h.buffAmt end
    local amt = floor(base * h.power / 100 * (100 + pct) / 100)
    local crit = Rand(S, 100) <= D.CRIT + h.mods.crit
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
        for _, e in ipairs(S.enemies) do
            if not e.dead then e.threat[from] = e.threat[from] + floor(done / 2) end
        end
    end
    return done
end

local function KillHero(S, p)
    local h = S.party[p]
    h.dead, h.hp, h.hots, h.absorb = true, 0, {}, 0
    h.deaths = h.deaths + 1
    S.fightDeaths = S.fightDeaths + 1
    for _, e in ipairs(S.enemies) do e.threat[p] = 0 end
    Fx(S, { k = "herodie", p = p })
end

local function HitHero(S, p, amt, i, label)
    local h = S.party[p]
    if not h or h.dead then return end
    local dr = h.mods.dr + (h.drRounds > 0 and h.drAmt or 0)
    amt = floor(amt * (100 - min(80, dr)) / 100)
    local absorbed = min(h.absorb, amt)
    h.absorb = h.absorb - absorbed
    amt = amt - absorbed
    h.hp = max(0, h.hp - amt)
    if h.resType == "rage" then h.res = min(h.resMax, h.res + floor(amt / 4) + 2) end
    local e = i and S.enemies[i]
    if e and h.mods.thorns > 0 then e.hp = e.hp - h.mods.thorns end
    Fx(S, { k = "hurt", p = p, e = i, amt = amt, absorbed = absorbed > 0 and absorbed or nil, label = label, hp = h.hp })
    if h.hp <= 0 then KillHero(S, p) end
end

local function DamageEnemy(S, i, amt, p, threatMult, crit, label)
    local e = S.enemies[i]
    if not e or e.dead then return end
    e.hp = e.hp - amt
    if e.ccRounds > 0 then                        -- damage breaks crowd control
        e.ccRounds = 0
        if e.intent and e.intent.k == "cc" then e.intent = { k = "attack", target = EnemyTarget(S, e) or 0 } end
    end
    local h = p and S.party[p]
    if h then
        e.threat[p] = e.threat[p] + floor(amt * (threatMult or 1))
        if h.mods.leech > 0 then HealHero(S, p, floor(amt * h.mods.leech / 100)) end
        if h.resType == "rage" then h.res = min(h.resMax, h.res + 4) end
    end
    Fx(S, { k = "hit", e = i, p = p, amt = amt, crit = crit or nil, label = label, hp = max(0, e.hp) })
end

local function Ability(h, a) return D.kits[h.role][a] end

-- Can player p use ability a on `target` this round?
function Sim.CanUse(S, p, a, target)
    local h = S.party[p]
    local ab = h and Ability(h, a)
    if not ab or S.phase ~= "combat" or h.dead or h.stunRounds > 0 then return false end
    if h.cds[a] > 0 or h.res < (ab.cost or 0) then return false end
    if ab.tgt == "enemy" then return LivingEnemy(S, target) ~= nil end
    if ab.tgt == "ally" then return S.party[target] ~= nil and not S.party[target].dead end
    return true
end

-- What a player does when they don't choose in time: the basic move on the first enemy.
function Sim.DefaultChoice(S, p)
    local h = S.party[p]
    if not h or h.dead then return nil end
    local t = Sim.FirstEnemy(S)
    if not t then return nil end
    return { a = 1, b = t }
end

local function UseAbility(S, p, a, target)
    local h = S.party[p]
    local ab = Ability(h, a)
    h.res = h.res - (ab.cost or 0)
    if (ab.cd or 0) > 0 then h.cds[a] = ab.cd + 1 end        -- +1: the end-of-round tick removes one
    Fx(S, { k = "act", p = p, a = a, target = target, tgt = ab.tgt })
    local kind = ab.kind
    if kind == "dmg" then
        local amt, crit = HeroAmount(S, h, ab.amt)
        DamageEnemy(S, target, amt, p, ab.threat, crit, a)
    elseif kind == "aoe" then
        for i, e in ipairs(S.enemies) do
            if not e.dead then
                local amt, crit = HeroAmount(S, h, ab.amt)
                DamageEnemy(S, i, amt, p, ab.threat, crit, a)
            end
        end
    elseif kind == "heal" then
        local amt, crit = HeroAmount(S, h, ab.amt, true)
        local done = HealHero(S, target, amt, p)
        Fx(S, { k = "heal", p = target, from = p, amt = done, crit = crit or nil, hp = S.party[target].hp })
    elseif kind == "hot" then
        local total = HeroAmount(S, h, ab.amt, true)
        local t = S.party[target]
        t.hots[#t.hots + 1] = { per = floor(total / ab.dur), left = ab.dur, from = p }
        Fx(S, { k = "buff", p = target, what = "hot" })
    elseif kind == "shield" then
        local t = S.party[target]
        t.absorb = max(t.absorb, (HeroAmount(S, h, ab.amt, true)))
        Fx(S, { k = "buff", p = target, what = "shield" })
    elseif kind == "taunt" then
        local e = S.enemies[target]
        local top = 0
        for q = 1, S.players do top = max(top, e.threat[q]) end
        e.threat[p] = top + 10
        e.tauntP, e.tauntRounds = p, D.TAUNT_ROUNDS
        if e.intent and e.intent.k == "attack" then e.intent.target = p end
        if e.intent and e.intent.k == "cast" and D.enemies[e.kind].abilities[e.intent.ab].kind == "slam" then
            e.intent.target = p
        end
        Fx(S, { k = "taunt", e = target, p = p })
    elseif kind == "interrupt" then
        local e = S.enemies[target]
        if e.intent and e.intent.k == "cast" and e.intent.interruptible then
            local name = D.enemies[e.kind].abilities[e.intent.ab].name
            e.intent = { k = "interrupted" }
            S.interrupts = S.interrupts + 1
            Fx(S, { k = "interrupt", e = target, p = p, name = name })
        end
        if (ab.amt or 0) > 0 then DamageEnemy(S, target, (HeroAmount(S, h, ab.amt)), p, 1, false, a) end
    elseif kind == "cc" then
        local e = S.enemies[target]
        if D.enemies[e.kind].boss then
            e.slowRounds = ab.dur
            Fx(S, { k = "slow", e = target, p = p })
        else
            e.ccRounds = ab.dur
            e.intent = { k = "cc" }
            Fx(S, { k = "cc", e = target, p = p })
        end
    elseif kind == "buff" then
        h.buffRounds, h.buffAmt = ab.dur, ab.amt
        Fx(S, { k = "buff", p = p, what = "buff" })
    elseif kind == "selfdr" then
        h.drRounds, h.drAmt = ab.dur, ab.amt
        Fx(S, { k = "buff", p = p, what = "dr" })
    elseif kind == "potion" then
        local done = HealHero(S, p, floor(h.max * ab.amt / 100))
        Fx(S, { k = "heal", p = p, from = p, amt = done, potion = true, hp = h.hp })
    end
end

local function EnemyDamage(S, e, base)
    local pct = EnemyDmgPct(S) * (e.enraged and 150 or 100) / 100
    if e.slowRounds > 0 then pct = pct * 60 / 100 end
    return floor(base * pct / 100)
end

local function Triggers(S)
    for i, e in ipairs(S.enemies) do
        if not e.dead and e.hp > 0 then
            local def = D.enemies[e.kind]
            for idx, ab in ipairs(def.abilities or {}) do
                if ab.at and not e.triggered[idx] and e.hp * 100 <= e.max * ab.at then
                    e.triggered[idx] = true
                    if ab.kind == "enrage" then
                        e.enraged = true
                        Fx(S, { k = "enrage", e = i, name = ab.name })
                    elseif ab.kind == "summon" then
                        for n, id in ipairs(ab.adds) do
                            if S.players >= 2 or n == 1 then
                                local add = Spawn(S, id)
                                add.intent = { k = "arrive" }
                            end
                        end
                        Fx(S, { k = "summon", e = i, name = ab.name })
                    end
                end
            end
        end
    end
end

local function EnemyAct(S, i, e)
    local it = e.intent
    if not it or e.dead then return end
    local def = D.enemies[e.kind]
    if it.k == "attack" then
        local p = EnemyTarget(S, e)
        if p then
            Fx(S, { k = "swing", e = i, p = p })
            HitHero(S, p, EnemyDamage(S, e, def.dmg), i)
        end
    elseif it.k == "cast" then
        local ab = def.abilities[it.ab]
        local amt = EnemyDamage(S, e, ab.amt or 0)
        Fx(S, { k = "ecast", e = i, name = ab.name })
        if ab.kind == "slam" or ab.kind == "bolt" then
            local p = (it.target > 0 and not S.party[it.target].dead) and it.target or EnemyTarget(S, e)
            if p then HitHero(S, p, amt, i, ab.name) end
        elseif ab.kind == "aoe" then
            for p = 1, S.players do HitHero(S, p, amt, i, ab.name) end
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
                o.hp = min(o.max, o.hp + floor((ab.amt or 0) * EnemyHpPct(S) / 100))
                Fx(S, { k = "ehealed", e = best, hp = o.hp })
            end
        elseif ab.kind == "stun" then
            for p = 1, S.players do
                if not S.party[p].dead then S.party[p].stunRounds = ab.dur end
            end
            Fx(S, { k = "stun", e = i, name = ab.name })
        end
    end
end

local function CheckDeaths(S)
    for i, e in ipairs(S.enemies) do
        if not e.dead and e.hp <= 0 then
            e.dead, e.hp, e.intent = true, 0, false
            if D.enemies[e.kind].boss then S.bossKills[#S.bossKills + 1] = e.kind end
            Fx(S, { k = "die", e = i })
        end
    end
end

local function EndOfRound(S)
    for p = 1, S.players do
        local h = S.party[p]
        if not h.dead then
            local keep = {}
            for _, hot in ipairs(h.hots) do
                local done = HealHero(S, p, hot.per, hot.from)
                if done > 0 then Fx(S, { k = "heal", p = p, from = hot.from, amt = done, hot = true, hp = h.hp }) end
                hot.left = hot.left - 1
                if hot.left > 0 then keep[#keep + 1] = hot end
            end
            h.hots = keep
            if S.players == 1 and h.hp < h.max then     -- Second Wind: solo heroes need some sustain
                local done = HealHero(S, p, floor(h.max * D.SOLO_REGEN / 100))
                if done > 0 then Fx(S, { k = "heal", p = p, amt = done, hot = true, hp = h.hp }) end
            end
            local r = D.resources[h.resType]
            h.res = min(h.resMax, h.res + r.regen + (h.resType == "mana" and h.mods.regen * 3 or 0))
        end
        for a = 1, D.ABILITIES - 1 do
            if h.cds[a] > 0 then h.cds[a] = h.cds[a] - 1 end
        end
        -- haste: a chance to shave an extra round off every cooldown
        if h.mods.haste > 0 and Rand(S, 100) <= h.mods.haste then
            for a = 1, D.ABILITIES - 1 do if h.cds[a] > 0 then h.cds[a] = h.cds[a] - 1 end end
        end
        if h.stunRounds > 0 then h.stunRounds = h.stunRounds - 1 end
        if h.drRounds > 0 then h.drRounds = h.drRounds - 1 end
        if h.buffRounds > 0 then h.buffRounds = h.buffRounds - 1 end
    end
    for _, e in ipairs(S.enemies) do
        if not e.dead then
            for idx in ipairs(e.abCd) do if e.abCd[idx] > 0 then e.abCd[idx] = e.abCd[idx] - 1 end end
            if e.ccRounds > 0 then e.ccRounds = e.ccRounds - 1 end
            if e.slowRounds > 0 then e.slowRounds = e.slowRounds - 1 end
            if e.tauntRounds > 0 then e.tauntRounds = e.tauntRounds - 1 end
        end
    end
end

-- choices[p] = { a = ability, b = target } (or nil: the default move). Resolves one combat round.
function Sim.ResolveRound(S, choices)
    if S.phase ~= "combat" or S.over then return end
    S.commits = S.commits + 1
    Fx(S, { k = "round", r = S.round })
    for p = 1, S.players do
        local h = S.party[p]
        if not h.dead and h.stunRounds == 0 then
            local c = choices and choices[p]
            if not (c and Sim.CanUse(S, p, c.a, c.b)) then c = Sim.DefaultChoice(S, p) end
            if c and Sim.CanUse(S, p, c.a, c.b) then UseAbility(S, p, c.a, c.b) end
            Triggers(S)
            CheckDeaths(S)
        end
    end
    for i, e in ipairs(S.enemies) do
        if not e.dead then EnemyAct(S, i, e) end
    end
    CheckDeaths(S)
    EndOfRound(S)
    CheckDeaths(S)
    if #Alive(S) == 0 then
        S.phase, S.over = "over", true
        Fx(S, { k = "wipe" })
    elseif not Sim.FirstEnemy(S) then
        WinFight(S)
    else
        S.round = S.round + 1
        PlanEnemies(S)
    end
end

---------------------------------------------------------------------------
-- Out-of-combat choices
---------------------------------------------------------------------------

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
    EnterRoom(S, offer[best])
end

-- act = { p, k, a }: "v" vote, "l" loot, "t" talent.
function Sim.Apply(S, act)
    local p = type(act) == "table" and tonumber(act.p)
    local h = p and S.party[p]
    if not h or S.over then return end
    S.commits = S.commits + 1
    if act.k == "v" then
        if S.phase ~= "path" or not S.pathOffer or not S.pathOffer[act.a] then return end
        h.vote = act.a
        for q = 1, S.players do if S.party[q].vote == 0 then return end end
        ResolveVote(S)
    elseif act.k == "l" then
        if S.phase ~= "loot" or h.lootTaken or not h.lootOffer or not h.lootOffer[act.a] then return end
        h.loot[#h.loot + 1] = h.lootOffer[act.a]
        h.lootTaken, h.lootOffer = true, false
        Recalc(S, h)
        Fx(S, { k = "loot", p = p, item = h.loot[#h.loot] })
        for q = 1, S.players do if not S.party[q].lootTaken then return end end
        OfferPath(S)
    elseif act.k == "t" then
        local choice = h.talentOffer and h.talentOffer[act.a]
        if not choice then return end
        h.talents[choice] = h.talents[choice] + 1
        h.talentOffer = false
        h.talentPts = h.talentPts - 1
        Recalc(S, h)
        OfferTalents(S, h)
    end
end

-- Does player p still have to choose in the current phase?
function Sim.Waiting(S, p)
    local h = S.party[p]
    if not h or S.over then return false end
    if S.phase == "path" then return h.vote == 0 end
    if S.phase == "loot" then return not h.lootTaken end
    if S.phase == "combat" then return not h.dead and h.stunRounds == 0 end
    return false
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
    local S = { rng = s, players = n, heroic = opts.heroic and true or false,
                dungeon = D.dungeons[opts.dungeon or 1] and (opts.dungeon or 1) or 1,
                party = {}, enemies = {}, blessings = {}, depth = 0, elitesDone = 0, phase = "path", round = 0,
                pathOffer = false, room = false, fx = {}, fxSeq = 0, nextUid = 1, commits = 0,
                interrupts = 0, bossKills = {}, fightDeaths = 0, flawlessBoss = false, won = false, over = false }
    for p = 1, n do S.party[p] = NewHero(S, heroes and heroes[p]) end
    EnterRoom(S, "fight")                     -- the first room is always a fight
    return S
end

function Sim.Hash(S)
    local h = 7
    local function mix(v)
        if type(v) == "boolean" then v = v and 1 or 0 end
        h = (h * 31 + (tonumber(v) or 0) % MOD) % MOD
    end
    mix(S.rng) mix(S.depth) mix(S.round) mix(#S.enemies) mix(S.interrupts) mix(#S.blessings) mix(S.commits)
    for p = 1, S.players do
        local x = S.party[p]
        mix(x.hp) mix(x.max) mix(x.res) mix(x.dead) mix(x.level) mix(#x.loot) mix(x.absorb) mix(x.vote)
        for a = 1, D.ABILITIES do mix(x.cds[a]) end
    end
    for _, e in ipairs(S.enemies) do mix(e.uid) mix(e.hp) mix(e.dead) mix(e.intent and e.intent.target or -1) end
    return h
end

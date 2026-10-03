if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Encounters/LadyVashj.lua", ...) then return end -- DisasterZone Games/Trainer/Encounters/LadyVashj.lua
-- Raid Trainer encounter: Lady Vashj (Serpentshrine Cavern), phase 2: the Tainted Core run.
-- Vashj stands in the middle behind her Magic Barrier, fed by four Shield Generators. A Tainted Elemental appears
-- at the room's edge; it drops a Tainted Core. Whoever loots the core cannot move while holding it, and throws it
-- to a raider up to 40 yd away, and so on until someone standing at a generator uses it there. Four cores, four
-- generators. You play one link of that chain (the looter, the relay, or the one at the generator); simulated
-- raiders play the others.
--
-- Where each number comes from:
--   the core (the client's spell tables, build 2.5.6): looting it applies Paralyze 38132 (a root, until the core is
--     gone); using it is Throw Key 38134: instant, 40 yd, a missile at 30 yd/s, the core lands in the target's bags;
--   the room: Blizzard's geometry, see LadyVashjFloor.lua; Vashj's spot is the boss scripts' centre point
--     (world 29.83, -923.27, 42.90: cmangos, TrinityCore);
--   the Tainted Elemental stands where it appears, throws Poison Bolts (38253, 2 s cast) and is gone after 15 s if
--     nobody kills it; the next one comes about 50 s later; Enchanted Elementals walk to Vashj (the same scripts);
--   models (Wowhead): Lady Vashj 20748, Tainted Elemental 11172, Enchanted Elemental 20076;
--   effects and sounds: the client's spell visual tables (the core's missile 166648, its impact 166602, sound 4475;
--     Poison Bolt's missile 166254 and impact 165738, sound 3134; the barrier on Vashj 166541).
-- NOT verified anywhere: the four generators' and the eight edge points' positions (from memory of an older
--   TrinityCore script; they do land on the platform and on the bottom ring of Blizzard's geometry), how long the
--   raid needs to kill a Tainted Elemental (8 s here), how fast Enchanted Elementals walk (2.5 yd/s here), and where
--   a raid stands. The wait between cores is cut from 50 s to a few seconds; Striders, Elites and Vashj's own
--   attacks are left out.
local addonName, ns = ...

local T = ns.Trainer
local Dist = T.Dist
local floor, min, max, pi = math.floor, math.min, math.max, math.pi

local SIZE = 210
local CX, CY = 105, 105
local THROW_RANGE, USE_RANGE = 40, 5
local KILL_TIME = 8          -- seconds the raid needs for a Tainted Elemental
local LOOT_DESPAWN = 45      -- a core nobody brings anywhere: the try is lost
local NEXT_CORE = 5          -- seconds from a generator going down to the next elemental (50 in the real fight)
local BOT_REACT = 1.2        -- a simulated raider's reaction before throwing on
local ELEMENTAL_WALK = 2.5

local DISPLAY_VASHJ, DISPLAY_TAINTED, DISPLAY_ENCHANTED = 20748, 11172, 20076
local FX = { coreMissile = 166648, coreImpact = 166602, coreSound = 4475, barrier = 166541,
             boltMissile = 166254, boltImpact = 165738, boltSound = 3134 }
local RAID_DISPLAYS = { 22931, 20570, 22924, 23714, 22752, 22952, 22973, 22953 }
local RAID_ACTS = { "melee", "melee", "melee", "melee", "bow", "caster", "caster", "caster" }

-- world (x north, y west) -> arena (x east, y north), Vashj in the middle
local function W(wx, wy) return -wy - 923.27 + CX, wx - 29.83 + CY end

local GENERATORS = { { W(49.6262, -902.181) }, { W(10.988, -901.616) }, { W(10.3859, -944.036) }, { W(49.3126, -943.398) } }
local EDGES = { { W(8.3, -835.3) }, { W(53.4, -835.3) }, { W(96.0, -861.9) }, { W(96.0, -986.4) },
                { W(54.4, -1010.6) }, { W(9.8, -1012.0) }, { W(-35.0, -987.6) }, { W(-58.9, -901.6) } }

local function SpellIcon(spellID, fallback)
    return (GetSpellTexture and GetSpellTexture(spellID)) or ("Interface\\Icons\\" .. fallback)
end
local CORE_ICON = (GetItemIcon and GetItemIcon(31088)) or "Interface\\Icons\\Spell_Nature_ElementalShields"

local function Compass(x, y)
    local a = math.atan2(y - CY, x - CX)
    local names = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }
    return names[floor(a / (pi / 4) + 0.5) % 8 + 1]
end

-- A point on the line from Vashj to (x, y), `share` of the way out.
local function Toward(x, y, share)
    return CX + (x - CX) * share, CY + (y - CY) * share
end

local ROLE_NAME = { looter = "the LOOTER", relay = "the RELAY", finisher = "at the GENERATOR" }
local JOB_NAME = { Looter = "Raider (looter)", Relay = "Raider (relay)", Generator = "Raider (at generator)" }

---------------------------------------------------------------------------
-- The core
---------------------------------------------------------------------------

local function NearestGenerator(sim, x, y)
    local best, bestD
    for _, g in ipairs(sim.generators) do
        if g.active then
            local d = Dist(x, y, g.x, g.y)
            if not bestD or d < bestD then best, bestD = g, d end
        end
    end
    return best
end

local function GiveCore(sim, unit)
    local core = sim.core
    core.holder, core.heldAt = unit, sim.time
    if unit == sim.player then
        sim.player.rooted = true                       -- Paralyze
        sim.stats.catches = (sim.stats.catches or 0) + 1
        sim:Banner("You hold the Tainted Core: you cannot move. Target a raider and throw it (1).", 3, 0.4, 1, 0.5)
    end
end

local function Throw(sim, from, to)
    local core = sim.core
    core.holder, core.flying = nil, to
    if from == sim.player then sim.player.rooted = false end
    sim:Sound(FX.coreSound)
    sim:Fx({ kind = "beam", x = from.x, y = from.y, x2 = to.x, y2 = to.y, color = { 0.4, 1, 0.5 } }, 0.3)
    sim:Missile(FX.coreMissile, from.x, from.y, to, 30, function(s, u)
        s:Fx({ kind = "model", fdid = FX.coreImpact, unit = u, z = 1.5 }, 0.8)
        s.core.flying = nil
        GiveCore(s, u)
    end)
    core.throws = (core.throws or 0) + 1
end

local function UseOnGenerator(sim, who, gen)
    local core = sim.core
    gen.active = false
    gen.name = "Shield Generator (off)"
    gen.interact = nil
    core.holder, core.state, core.doneAt = nil, "done", sim.time
    if who == sim.player then sim.player.rooted = false end
    sim.stats.times[#sim.stats.times + 1] = sim.time - core.diedAt
    sim.stats.down = (sim.stats.down or 0) + 1
    sim:Sound(39)
    sim:Banner(string.format("Shield Generator down! (%d of 4)", sim.stats.down), 2.5, 0.4, 0.9, 1)
end

-- What a simulated raider does with the core: use it if a generator is in reach, else throw it to the raider in
-- range who is nearest to the generator (and nearer than himself).
local function BotWithCore(sim, bot)
    local core = sim.core
    if sim.time - core.heldAt < BOT_REACT then return end
    local gen = core.gen
    if not gen.active then
        gen = NearestGenerator(sim, bot.x, bot.y)
        core.gen = gen
    end
    if Dist(bot.x, bot.y, gen.x, gen.y) <= USE_RANGE then
        UseOnGenerator(sim, bot, gen)
        return
    end
    local mine = Dist(bot.x, bot.y, gen.x, gen.y)
    local best, bestD
    for _, u in ipairs(sim.units) do
        if (u.selectable or u == sim.player) and u ~= bot and not u.dead and Dist(bot.x, bot.y, u.x, u.y) <= THROW_RANGE then
            local d = Dist(u.x, u.y, gen.x, gen.y)
            if d < mine - 4 and (not bestD or d < bestD) then best, bestD = u, d end
        end
    end
    if best then
        Throw(sim, bot, best)
    elseif not core.called or sim.time - core.called > 6 then
        core.called = sim.time
        sim:Banner(bot.name .. " has the core and nobody in range: get between them and the generator!", 3, 1, 0.6, 0.2)
    end
end

---------------------------------------------------------------------------
-- A round: one elemental, one core, one generator
---------------------------------------------------------------------------

local function StartCore(sim)
    local p = sim.player
    local role = sim.diff.role
    if role == "all" then role = ({ "looter", "relay", "finisher" })[sim:Random(1, 3)] end
    -- looter and relay work a sector: the elemental comes up at one of the two edge points nearest to you
    local order = {}
    for i, e in ipairs(EDGES) do order[i] = { i = i, d = Dist(p.x, p.y, e[1], e[2]) } end
    table.sort(order, function(a, b) return a.d < b.d end)
    local pick = (role == "finisher") and sim:Random(1, #EDGES) or order[sim:Random(1, 2)].i
    local ex, ey = EDGES[pick][1], EDGES[pick][2]
    local core = { state = "elemental", role = role, edge = pick, x = ex, y = ey, spawnAt = sim.time }
    core.gen = NearestGenerator(sim, ex, ey)
    sim.core = core
    core.elemental = sim:Spawn({ kind = "tainted", name = "Tainted Elemental", x = ex, y = ey, targetable = true,
                                 facing = math.atan2(CY - ey, CX - ex), hp = 100, hpMax = 100, hpPercent = true,
                                 radius = 2, color = { 0.3, 0.9, 0.4 }, display = DISPLAY_TAINTED, level = 71,
                                 elite = true, mana = false, plate = 4.5 })
    core.nextBolt = sim.time + 1
    -- the simulated links of this chain; the one you play is missing
    for _, u in ipairs(sim.units) do
        if u.job then u.dead, u.diedAt = true, -100 end              -- last round's chain leaves
    end
    local function raider(job, x, y, n)
        local k = (pick + n) % #RAID_DISPLAYS + 1
        return sim:Spawn({ kind = "raider", job = job, name = JOB_NAME[job], x = x, y = y, selectable = true, friendly = true,
                           facing = math.atan2(ey - y, ex - x), display = RAID_DISPLAYS[k], act = RAID_ACTS[k],
                           speed = 7, radius = 0.9, color = { 0.3, 0.55, 1 }, plate = 2.6 })
    end
    local gx, gy = core.gen.x, core.gen.y
    if role ~= "looter" then
        local x, y = Toward(ex, ey, 0.86)
        core.looter = raider("Looter", x, y, 0)
    end
    -- relays: as many as it takes for every throw to be at most 34 yd (a far generator needs two); as the relay
    -- you are the first one from the elemental
    local hops = max(2, math.ceil(Dist(ex, ey, gx, gy) / 34))
    for k = 1, hops - 1 do
        local x, y = ex + (gx - ex) * k / hops, ey + (gy - ey) * k / hops
        if k == 1 then core.spot = { x = x, y = y } end
        if not (role == "relay" and k == 1) then raider("Relay", x, y, k) end
    end
    if role ~= "finisher" then
        local x, y = Toward(gx, gy, 1.1)
        core.finisher = raider("Generator", x, y, 2)
    end
    sim.objective = string.format("Core %d of 4: you are %s. Elemental: %s edge. Generator: the %s one.",
        (sim.stats.down or 0) + 1, ROLE_NAME[role], Compass(ex, ey), Compass(gx, gy))
    local how = (role == "looter") and "Run to it; when it dies, loot the core and throw it to the relay."
        or (role == "relay") and string.format("Stand on the line to the generator, about %d yd from the elemental.", Dist(ex, ey, core.spot.x, core.spot.y))
        or "Stand at the generator: catch the core, then use it on the generator."
    sim:Banner(string.format("Tainted Elemental, %s! You are %s. %s", Compass(ex, ey), ROLE_NAME[role], how), 5, 0.4, 1, 0.5)
end

local function LootCore(sim, who)
    local core = sim.core
    if core.state ~= "onground" then return end
    core.state = "carried"
    core.corpse.dead, core.corpse.diedAt = true, -100
    GiveCore(sim, who)
end

local function Start(sim)
    sim.stats.times, sim.stats.down = {}, 0
    sim.boss = sim:Spawn({ kind = "boss", name = "Lady Vashj", x = CX, y = CY, facing = -pi / 2, radius = 3,
                           color = { 0.55, 0.1, 0.5 }, display = DISPLAY_VASHJ, level = -1, plate = 9 })
    sim:Fx({ kind = "model", fdid = FX.barrier, unit = sim.boss, z = 3 }, 100000)
    sim.generators = {}
    for i, g in ipairs(GENERATORS) do
        local u = sim:Spawn({ kind = "generator", name = "Shield Generator", x = g[1], y = g[2], radius = 1.5,
                              color = { 0.3, 0.9, 1 }, active = true, plate = 5, label = true })
        u.interact = function(s, gen)
            if s.core and s.core.holder == s.player then
                UseOnGenerator(s, s.player, gen)
            else
                s:Error("You need a Tainted Core.")
            end
        end
        sim.generators[i] = u
    end
    -- where you start: out by the edge as the looter, on the steps as the relay, up by the generators otherwise
    local role = sim.diff.role
    local share = (role == "looter") and 0.8 or (role == "finisher") and 0.25 or 0.5
    local p = sim.player
    p.x, p.y = Toward(EDGES[8][1], EDGES[8][2], share)
    p.facing = math.atan2(CY - p.y, CX - p.x)
    sim.nextElemental = sim.time + 3
    sim.nextEnchanted = sim.time + 1
    sim.objective = "Phase 2: bring a Tainted Core to each of the four Shield Generators."
end

-- What the view shows you: a ring round every generator (5 yd: where a core can be used), a tall marker on the
-- one this core goes to, on the elemental / the core, on whoever holds it, and on the spot your job is done from.
local function Guide(sim)
    local p, core = sim.player, sim.core
    local marks, status = {}, {}
    for _, g in ipairs(sim.generators) do
        if g.active then
            local mine = core and core.gen == g and core.state ~= "done"
            marks[#marks + 1] = { x = g.x, y = g.y, r = USE_RANGE, color = mine and { 0.3, 1, 1 } or { 0.2, 0.5, 0.7 },
                                  column = mine and 16 or 7, label = mine and "Generator: bring it here" or nil }
        end
    end
    if core and core.state ~= "done" then
        status[#status + 1] = "Your job: |cffffd100" .. ROLE_NAME[core.role] .. "|r"
        if core.state == "elemental" then
            marks[#marks + 1] = { x = core.x, y = core.y, r = 4, color = { 0.3, 1, 0.4 }, column = 16, label = "Tainted Elemental" }
            status[#status + 1] = string.format("Elemental: %s edge, %d yd from you", Compass(core.x, core.y), Dist(p.x, p.y, core.x, core.y))
        elseif core.state == "onground" then
            marks[#marks + 1] = { x = core.x, y = core.y, r = 4, color = { 0.3, 1, 0.4 }, column = 16, label = "Tainted Core: loot it" }
            status[#status + 1] = string.format("Core: on the ground, %s edge, %d yd from you", Compass(core.x, core.y), Dist(p.x, p.y, core.x, core.y))
        elseif core.holder == p then
            status[#status + 1] = "Core: |cff66ff80YOU have it|r (you cannot move)"
        elseif core.holder or core.flying then
            local h = core.holder or core.flying
            marks[#marks + 1] = { x = h.x, y = h.y, r = 1.5, color = { 0.3, 1, 0.4 }, column = 10, label = "Has the core" }
            status[#status + 1] = string.format("Core: with %s, %d yd from you", h.name, Dist(p.x, p.y, h.x, h.y))
        end
        status[#status + 1] = string.format("Generator: the %s one, %d yd from you", Compass(core.gen.x, core.gen.y), Dist(p.x, p.y, core.gen.x, core.gen.y))
        -- where your job is done from
        if core.role == "relay" and core.holder ~= p then
            marks[#marks + 1] = { x = core.spot.x, y = core.spot.y, r = 3, color = { 1, 0.85, 0.1 }, column = 12, label = "Relay: stand here" }
        elseif core.role == "finisher" and core.holder ~= p then
            local x, y = Toward(core.gen.x, core.gen.y, 1.1)
            marks[#marks + 1] = { x = x, y = y, r = 2, color = { 1, 0.85, 0.1 }, column = 0, label = nil }
        end
    else
        status[#status + 1] = string.format("Generators down: %d of 4. Next elemental soon.", sim.stats.down or 0)
    end
    sim.marks, sim.status = marks, status
    sim.zones = marks                                   -- the minimap shows the same
end

local function Update(sim, dt)
    local p = sim.player
    Guide(sim)
    -- the barrier's beams, the Paralyze icon
    sim.beams = {}
    for _, g in ipairs(sim.generators) do
        if g.active then sim.beams[#sim.beams + 1] = { g.x, g.y, 4, CX, CY, 5, 0.3, 0.8, 1 } end
    end
    sim.bars = {}
    local core = sim.core
    if core and core.holder == p then
        sim.bars[1] = { label = "Paralyze", icon = SpellIcon(38132, "Spell_Nature_TimeStop"), harmful = true }
    end

    -- Enchanted Elementals: they walk in from the edge; the raid kills them on the steps
    if sim.time >= sim.nextEnchanted then
        sim.nextEnchanted = sim.time + 3
        if #sim:Alive("enchanted") < 8 then
            local e = EDGES[sim:Random(1, #EDGES)]
            local a = sim:Random() * 2 * pi
            sim:Spawn({ kind = "enchanted", name = "Enchanted Elemental", x = e[1] + math.cos(a) * 4, y = e[2] + math.sin(a) * 4,
                        display = DISPLAY_ENCHANTED, speed = ELEMENTAL_WALK, radius = 1, color = { 0.4, 0.6, 1 },
                        goal = { x = CX, y = CY, stop = 6 }, dieAt = 42 + sim:Random() * 22 })
        end
    end
    for _, u in ipairs(sim.units) do
        if u.kind == "enchanted" and not u.dead and Dist(u.x, u.y, CX, CY) < u.dieAt then
            u.dead, u.diedAt = true, sim.time
        end
    end

    if not core then
        if sim.time >= sim.nextElemental then StartCore(sim) end
        return
    end

    if core.state == "elemental" then
        local e = core.elemental
        e.hp = max(0, 100 * (1 - (sim.time - core.spawnAt) / KILL_TIME))
        if sim.time >= core.nextBolt and e.hp > 20 then
            core.nextBolt = sim.time + 2
            local raiders = sim:Alive("raider")
            local target = (#raiders > 0 and sim:Random(1, 3) > 1) and raiders[sim:Random(1, #raiders)] or p
            sim:Missile(FX.boltMissile, e.x, e.y, target, 40, function(s, u)
                s:Fx({ kind = "model", fdid = FX.boltImpact, unit = u, z = 1.5 }, 0.8)
                s:Sound(FX.boltSound)
            end)
        end
        if e.hp <= 0 then
            e.dead, e.diedAt = true, sim.time
            if sim.target == e then sim.target = nil end
            core.state, core.diedAt = "onground", sim.time
            core.corpse = sim:Spawn({ kind = "core", name = "Tainted Core", x = e.x, y = e.y, radius = 1.2,
                                      color = { 0.4, 1, 0.5 }, plate = 2, label = true, icon = CORE_ICON })
            core.corpse.interact = function(s) LootCore(s, s.player) end
            sim:Fx({ kind = "model", fdid = FX.coreImpact, unit = core.corpse, z = 1 }, LOOT_DESPAWN)   -- it glows where it lies
            if core.looter then core.looter.goal = { x = e.x, y = e.y, stop = 2.5 } end
            sim:Banner("The Tainted Elemental is dead: loot the core!", 2.5, 0.4, 1, 0.5)
        end
    elseif core.state == "onground" then
        local l = core.looter
        if l and Dist(l.x, l.y, core.x, core.y) <= 3 then
            core.lootAt = core.lootAt or (sim.time + 1)
            if sim.time >= core.lootAt then LootCore(sim, l) end
        end
    elseif core.state == "carried" then
        local h = core.holder
        if h and h ~= p then BotWithCore(sim, h) end
    elseif core.state == "done" then
        if sim.stats.down >= 4 then
            sim:Win()
            return
        end
        if sim.time >= core.doneAt + NEXT_CORE then
            sim.core = nil
            sim.nextElemental = sim.time
        end
        return
    end
    if core.diedAt and sim.time - core.diedAt > LOOT_DESPAWN then
        sim:Lose("The Tainted Core never reached a generator.")
    end
end

local abilities = {
    { id = "core", key = "1", name = "Tainted Core", icon = CORE_ICON, item = true,
      tip = "Throw the core to the raider you have targeted, up to 40 yd. Use it on a Shield Generator by clicking the generator (or F) from within 5 yd.",
      range = THROW_RANGE, needsTarget = true, friendly = true, gcd = 0.5,
      usable = function(sim)
          if not (sim.core and sim.core.holder == sim.player) then return false, "You have no Tainted Core." end
          return true
      end,
      use = function(sim, ab, target)
          Throw(sim, sim.player, target)
          sim.stats.throws = (sim.stats.throws or 0) + 1
      end },
}

-- Four cores: 1000 each, less 20 for every second from the elemental's death to the generator going down.
local function Score(sim)
    local pts = 0
    for _, t in ipairs(sim.stats.times) do pts = pts + max(100, 1000 - 20 * t) end
    return floor(pts)
end

local function Summary(sim)
    local out = {}
    for i, t in ipairs(sim.stats.times) do
        out[#out + 1] = string.format("Core %d: %.1f sec from the elemental's death to the generator.", i, t)
    end
    if sim.state ~= "won" then
        out[#out + 1] = string.format("%d of 4 generators down.", sim.stats.down or 0)
        out[#out + 1] = "|cffffd100Tip:|r a thrower needs you within 40 yd, and nearer to the generator than he is."
    end
    out[#out + 1] = "|cff888888In the real fight a Tainted Elemental comes about every 50 sec and is gone after 15.|r"
    return out
end

local floorGrid = ns.TrainerFloors and ns.TrainerFloors.vashj

T:RegisterEncounter("vashj", {
    name = "Lady Vashj",
    desc = "Phase 2: bring the Tainted Cores to the Shield Generators. You are one link of the chain.",
    icon = CORE_ICON,
    order = 20,
    arena = { w = SIZE, h = SIZE,
              height = T.HeightFn(floorGrid), walkable = T.WalkableFn(floorGrid), mesh = floorGrid and floorGrid.mesh },
    difficulties = {
        { id = "all", name = "Any job (random)", role = "all" },
        { id = "looter", name = "Looter", role = "looter" },
        { id = "relay", name = "Relay", role = "relay" },
        { id = "finisher", name = "At the generator", role = "finisher" },
    },
    player = { x = CX, y = CY - 48, speed = 7, facing = pi / 2 },
    abilities = abilities,
    interactKey = "F",
    compass = true,
    resultTitle = function(sim) return sim.state == "won" and "Barrier down!" or "Wipe" end,
    howTo = {
        "A |cff66ff80Tainted Elemental|r comes up at the room's edge. The raid kills it; it leaves a |cff66ff80Tainted Core|r.",
        "Whoever loots the core (click it, or |cffffd100F|r) |cffff6060cannot move|r while holding it.",
        "Click a raider and press |cffffd1001|r to throw it to them: 40 yd at most.",
        "At a |cff80e0ffShield Generator|r: click the generator (or |cffffd100F|r) within 5 yd to use the core on it.",
        "Each core you are told your job: the looter, the relay in between, or the one at the generator.",
    },
    start = Start,
    update = Update,
    score = Score,
    summary = Summary,
})

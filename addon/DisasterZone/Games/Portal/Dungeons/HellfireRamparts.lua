if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Portal/Dungeons/HellfireRamparts.lua", ...) then return end -- DisasterZone Games/Portal/Dungeons/HellfireRamparts.lua
-- PROTOTYPE (2026-10-09) of the Portal crawler: Hellfire Ramparts' entrance in 3D with a fixed, Diablo-style camera.
-- You and two party members walk in from the instance's entrance and fight the first pack where it really stands.
-- Clear it and the run counts; die and the run is void (back to the Portal with what you had). A test of the look
-- and the frame rate, not the game: the numbers below are placeholders.
--
-- Where things come from:
--   the room: Blizzard's own geometry (generators/gen_dungeon_proto.py -> Render3D/Rooms/HellfireRamparts_Entrance.lua,
--     map 543, a 70 x 70 yd box from the entrance past the first pack, height 0 = the entrance floor);
--   the pack: AzerothCore's creature table (two Bonechewer Hungerers 17259, a Bonechewer Ravener 17264, at their
--     spawns on the entrance floor), their models from creature_template_model (displays 17052 and 17049);
--   the camera: the Portal panel's fixed camera (Games/Portal/UI.lua FixedCam: camera = { pitch, dist });
--   animations (the client's AnimationData ids): Attack1H 17, Attack2H 18, CombatWound 9, SpellCastOmni 54; effects
--   (spell model files): bloodyexplosion 165737, cleave_impact_chest 165798, heal_low_base 166292,
--   holy_precast_low_hand 166336.
-- NOT verified: the models' attachment heights (an orc's from the raid stand-ins), every number of the fight.
local addonName, ns = ...

local T = ns.Trainer
local Dist = T.Dist
local floor, min, max, pi = math.floor, math.min, math.max, math.pi

local ROOM = "HellfireRamparts_Entrance"
local SIZE = 70
local ENTRANCE_X, ENTRANCE_Y = 40.0, 24.0   -- a few yards in from the instance's entrance (15 is the room's cut south edge)
local MELEE, AGGRO = 4.5, 16
local DISPLAY_HUNGERER, DISPLAY_RAVENER = 17052, 17049
local DISPLAY_TANK, DISPLAY_HEALER = 22931, 22973
local ANIM_1H, ANIM_2H, ANIM_WOUND, ANIM_CAST = 17, 18, 9, 54
local FX_BLOOD, FX_CLEAVE, FX_HEAL, FX_PRECAST = 165737, 165798, 166292, 166336

-- A one-shot animation (Games/Portal/UI.lua plays it over walking and standing; a new one restarts it).
local function Anim(sim, u, anim, dur) u.oneShot = { anim = anim, untilT = sim.time + dur } end
local function Busy(sim, u) return u.oneShot and sim.time < u.oneShot.untilT end

local DISPLAYS = {
    [DISPLAY_HUNGERER] = { scale = 1, chest = 1.5, head = 2.2, hand = 1.0, name = 2.3 },
    [DISPLAY_RAVENER] = { scale = 1, chest = 1.5, head = 2.2, hand = 1.0, name = 2.3 },
    [DISPLAY_TANK] = { scale = 1, chest = 1.50, head = 2.19, hand = 1.03, name = 2.22 },
    [DISPLAY_HEALER] = { scale = 1, chest = 1.35, head = 2.04, hand = 0.93, name = 2.08 },
}
local function PlateOf(display) local d = DISPLAYS[display]; return d.name * d.scale + 0.4 end

local PACK = {
    { 25.6, 43.5, DISPLAY_HUNGERER, "Bonechewer Hungerer", 5200 },
    { 17.8, 40.7, DISPLAY_HUNGERER, "Bonechewer Hungerer", 5200 },
    { 19.1, 54.4, DISPLAY_RAVENER, "Bonechewer Ravener", 6400 },
}

-- The room's floor, unpacked the first time anything asks (Render3D/Rooms.lua keeps the last two used).
local arena = { w = SIZE, h = SIZE, labels = { { x = ENTRANCE_X, y = ENTRANCE_Y - 4, text = "To the Portal" } } }
local function Floor()
    local R3 = ns.Render3D
    return R3 and R3.Floor and R3.Floor({ floor = ROOM }) or nil
end
setmetatable(arena, { __index = function(t, k)
    if k ~= "mesh" and k ~= "ground" and k ~= "height" then return nil end
    local f = Floor()
    if not f then return nil end
    rawset(t, "mesh", f.mesh)
    rawset(t, "ground", T.GroundFn(f.walk))
    rawset(t, "height", T.HeightFn(f))
    return rawget(t, k)
end })

local function SpellIcon(id, fallback) return (GetSpellTexture and GetSpellTexture(id)) or ("Interface\\Icons\\" .. fallback) end

local function Scale(sim) return sim.diff.scale or 1 end

local function Party(sim)
    local out = { sim.player }
    for _, u in ipairs(sim:Alive("party")) do out[#out + 1] = u end
    return out
end

local function Mobs(sim) return sim:Alive("mob") end

local function Hit(sim, attacker, u, amount)
    if u.dead then return end
    sim:Damage(u, floor(amount))
    if not u.dead and not Busy(sim, u) then Anim(sim, u, ANIM_WOUND, 0.35) end      -- (a flinch when idle)
    if u.kind == "mob" then
        u.threat = u.threat or {}
        u.threat[attacker] = (u.threat[attacker] or 0) + amount * (attacker.tank and 3 or 1)
        u.awake = true
    end
end

local abilities = {
    { id = "strike", key = "1", name = "Heroic Strike", icon = SpellIcon(29707, "Ability_Rogue_Ambush"), gcd = 1.5,
      range = MELEE + 1, needsTarget = true,
      tip = "A heavy blow to your target.",
      use = function(sim, ab, target)
          Anim(sim, sim.player, ANIM_2H, 0.9)
          Hit(sim, sim.player, target, sim:Random(650, 800))
          sim:Fx({ kind = "model", fdid = FX_BLOOD, unit = target, attach = "chest" }, 0.8)
      end },
    { id = "cleave", key = "2", name = "Cleave", icon = SpellIcon(25231, "Ability_Warrior_Cleave"), gcd = 1.5,
      cooldown = 6, tip = "Hits every enemy within 8 yd in front of you.",
      use = function(sim)
          local p = sim.player
          Anim(sim, p, ANIM_2H, 0.9)
          for _, u in ipairs(sim:UnitsInRange(p.x, p.y, 8, "mob")) do
              Hit(sim, p, u, sim:Random(380, 460))
              sim:Fx({ kind = "model", fdid = FX_CLEAVE, unit = u, attach = "chest" }, 0.8)
          end
      end },
    { id = "heal", key = "3", name = "Bandage", icon = SpellIcon(27031, "INV_Misc_Bandage_12"), cooldown = 20,
      tip = "Heals you for 30% of your health.",
      use = function(sim)
          local p = sim.player
          p.hp = min(p.hpMax, p.hp + floor(p.hpMax * 0.3))
          sim:Fx({ kind = "model", fdid = FX_HEAL, unit = p }, 1.2)
      end },
}

local function Start(sim)
    local p = sim.player
    p.hp, p.hpMax, p.swingAt = 9000, 9000, 0
    sim.stats.kills = 0
    local tank = sim:Spawn({ kind = "party", name = "Tank", tank = true, x = ENTRANCE_X - 2, y = ENTRANCE_Y + 3,
                             hp = 14000, speed = 7, radius = 0.9, color = { 0.3, 0.6, 1 }, display = DISPLAY_TANK,
                             selectable = true, plate = PlateOf(DISPLAY_TANK), facing = pi / 2 })
    local healer = sim:Spawn({ kind = "party", name = "Healer", healer = true, x = ENTRANCE_X + 2, y = ENTRANCE_Y - 2,
                               hp = 7000, speed = 7, radius = 0.9, color = { 0.3, 1, 0.6 }, display = DISPLAY_HEALER,
                               selectable = true, plate = PlateOf(DISPLAY_HEALER), facing = pi / 2 })
    tank.swingAt, healer.castAt = 0, 0
    local s = Scale(sim)
    for _, m in ipairs(PACK) do
        sim:Spawn({ kind = "mob", name = m[4], x = m[1], y = m[2], hp = floor(m[5] * s), speed = 6.5, radius = 1.2,
                    color = { 0.85, 0.25, 0.2 }, display = m[3], targetable = true, level = 61, elite = true,
                    plate = PlateOf(m[3]), facing = -pi / 2, swingAt = 0, home = { x = m[1], y = m[2] } })
    end
    sim.objective = "Clear the pack by the entrance. If you die, the run is void."
    sim:Banner("Through the Portal: Hellfire Ramparts", 3, 1, 0.8, 0.35)
end

-- Who a mob hits: the one with the most threat on it (the tank multiplies its own).
local function MobTarget(u)
    local best, bt
    for who, th in pairs(u.threat or {}) do
        if not who.dead and (not bt or th > bt) then best, bt = who, th end
    end
    return best
end

local function Update(sim, dt)
    local t, s = sim.time, Scale(sim)
    local party, mobs = Party(sim), Mobs(sim)
    -- mobs wake when anyone in the party comes close, then run at and hit their target
    for _, m in ipairs(mobs) do
        if not m.awake then
            for _, pm in ipairs(party) do
                if Dist(pm.x, pm.y, m.x, m.y) < AGGRO then
                    m.awake = true
                    m.threat = { [pm] = 1 }
                end
            end
            if m.awake then        -- the pack pulls together
                for _, o in ipairs(mobs) do
                    if not o.awake then o.awake, o.threat = true, { [party[1]] = 1 } end
                end
            end
        end
        if m.awake then
            local target = MobTarget(m) or party[1]
            if target then
                m.goal = { x = target.x, y = target.y, stop = MELEE - 1 }
                local inReach = Dist(m.x, m.y, target.x, target.y) <= MELEE
                m.act = inReach and "ready" or nil
                if inReach then
                    m.facing = math.atan2(target.y - m.y, target.x - m.x)
                    if t >= m.swingAt then
                        m.swingAt = t + 2
                        Anim(sim, m, ANIM_1H, 0.8)
                        Hit(sim, m, target, sim:Random(420, 560) * s)
                    end
                end
            end
        end
    end
    -- the tank goes for the nearest awake mob (or follows you), the healer keeps everyone up from behind
    for _, pm in ipairs(sim:Alive("party")) do
        if pm.tank then
            local best, bd
            for _, m in ipairs(mobs) do
                local d = Dist(pm.x, pm.y, m.x, m.y)
                if m.awake and (not bd or d < bd) then best, bd = m, d end
            end
            if best then
                pm.goal = { x = best.x, y = best.y, stop = MELEE - 1.5 }
                local inReach = bd <= MELEE
                pm.act = inReach and "ready" or nil
                if inReach then
                    pm.facing = math.atan2(best.y - pm.y, best.x - pm.x)
                    if t >= pm.swingAt then
                        pm.swingAt = t + 2.2
                        Anim(sim, pm, ANIM_1H, 0.8)
                        Hit(sim, pm, best, sim:Random(300, 380))
                    end
                end
            else
                pm.goal, pm.act = { x = sim.player.x - 2, y = sim.player.y + 2, stop = 2 }, nil
            end
        elseif pm.healer then
            pm.goal = { x = sim.player.x + 2, y = sim.player.y - 4, stop = 3 }
            local low, lf
            for _, q in ipairs(party) do
                local f = q.hp / q.hpMax
                if f < 0.85 and (not lf or f < lf) then low, lf = q, f end
            end
            pm.act = low and "casting" or nil
            if low and t >= pm.castAt then
                pm.castAt = t + 2.5
                pm.facing = math.atan2(low.y - pm.y, low.x - pm.x)
                Anim(sim, pm, ANIM_CAST, 1.0)
                sim:Fx({ kind = "model", fdid = FX_PRECAST, unit = pm, attach = "hand" }, 1.0)
                sim:After(0.4, function(sm)
                    if low.dead then return end
                    low.hp = min(low.hpMax, low.hp + 900)
                    sm:Fx({ kind = "model", fdid = FX_HEAL, unit = low }, 1.2)
                end)
            end
        end
    end
    -- your auto attack on your target in reach
    local p, tgt = sim.player, sim.target
    local inReach = tgt and not tgt.dead and Dist(p.x, p.y, tgt.x, tgt.y) <= MELEE + 1
    p.act = inReach and "ready" or nil
    if inReach then
        if not p.moving then p.facing = math.atan2(tgt.y - p.y, tgt.x - p.x) end
        if t >= p.swingAt then
            p.swingAt = t + 2.6
            if not Busy(sim, p) then Anim(sim, p, ANIM_2H, 0.9) end
            Hit(sim, p, tgt, sim:Random(260, 340))
        end
    end
    for _, m in ipairs(sim.units) do
        if m.kind == "mob" and m.dead and not m.counted then
            m.counted = true
            sim.stats.kills = sim.stats.kills + 1
        end
    end
    if p.hp <= 0 or p.dead then
        sim:Lose("You died. The run is void: back to the Portal with what you had.")
    elseif #Mobs(sim) == 0 then
        sim:Win()
    end
end

local function Score(sim) return (sim.stats.kills or 0) * 100 + max(0, 120 - floor(sim.time)) end

local function Summary(sim)
    if sim.state == "won" then
        return { "Run cleared in " .. floor(sim.time) .. " sec: what you earned is kept.",
                 "Prototype: one room of Hellfire Ramparts. Tell how the camera and the frame rate felt." }
    end
    return { "The run is void: nothing earned inside counts.", (sim.stats.kills or 0) .. " of 3 killed." }
end

T:RegisterEncounter("ramparts", {
    game = "portal",                     -- listed by the Portal game (Games/Portal/UI.lua), never by the Raid Trainer
    returnTo = "hub",                    -- a finished run, kept or void, goes back to the Stair of Destiny
    name = "Hellfire Ramparts",
    desc = "Hellfire Ramparts' entrance in 3D with a fixed camera: you and two party members against the first pack.",
    icon = "Interface\\Icons\\Spell_Fire_FelFlameRing",
    order = 90,
    displays = DISPLAYS,
    arena = arena,
    camera = { pitch = 0.95, dist = 26 },
    sky = 130525,                         -- Hellfire's red sky over the open-air ramparts (hellfireskybox.m2)
    difficulties = {
        { id = "p0", name = "Portal level 0", scale = 1 },
        { id = "p5", name = "Portal level 5", scale = 1.1 ^ 5 },
        { id = "p10", name = "Portal level 10", scale = 1.1 ^ 10 },
    },
    player = { x = ENTRANCE_X, y = ENTRANCE_Y, speed = 7, facing = pi / 2 },
    abilities = abilities,
    howTo = {
        "WASD moves you on the screen; the camera stays fixed. Tab picks a target.",
        "|cffffd1001|r Heroic Strike, |cffffd1002|r Cleave, |cffffd1003|r Bandage. Your tank and healer follow.",
        "Clear the pack. If you die, the run is void.",
    },
    start = Start,
    update = Update,
    score = Score,
    summary = Summary,
})

if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Encounters/TeronGorefiend.lua", ...) then return end -- DisasterZone Games/Trainer/Encounters/TeronGorefiend.lua
-- Raid Trainer encounter: Teron Gorefiend (Black Temple), the Shadow of Death job.
-- You are marked, run away from the raid, die, and come back possessing a Vengeful Spirit; four Shadowy
-- Constructs rise around your corpse and run at the raid. Kill them before one gets into melee.
--
-- Where each number comes from:
--   spells (Wowhead TBC Classic): Spirit Strike 40325, Spirit Lance 40157, Spirit Chains 40175, Spirit Volley
--     40314, Spirit Shield 40322, Shadow of Death 40251 (55 s), Summon Skeleton 40270 (within 6 yd of the corpse),
--     Brief Stun 41421 (1 s, on every construct as it rises), Spiritual Vengeance 40268 (the spirit lasts 60 s);
--   the three attacks, checked against the client's own spell tables (build 2.5.6: SpellEffect, SpellAuraOptions,
--     SpellCooldowns, SpellDuration, SpellRange, SpellRadius, SpellMisc):
--       Lance   6,175 - 6,825 damage (6174 + 1..651), 30 yd, no cooldown, 1 s global cooldown; a 30% slow that
--               stacks to 3 (CumulativeAura 3), lasts 9 s and has a 3 s period;
--       Chains  1,900 - 2,100 damage (1899 + 1..201) and a 5 s stun, 12 yd around you, 15 s cooldown;
--       Volley  9,900 - 12,100 damage (9899 + 1..2201), 12 yd around you, 15 s cooldown;
--   missile speeds (the client's SpellMisc table, build 2.5.6): Lance 38 yd/s, Volley 15 yd/s, Chains none.
--     Damage lands when the missile does;
--   effect models and sounds (the client's SpellXSpellVisual > SpellVisualEvent > SpellVisualKitEffect >
--     SpellVisualKitModelAttach > SpellVisualEffectName tables, build 2.5.6): see FX below;
--   models (Wowhead): Teron 21254, Vengeful Spirit 21300, Shadowy Construct 21305;
--   construct health 41,567 (TBC Classic DB); constructs take damage from Lance, Chains and Volley only and each
--     runs at a random raider (server emulators' boss scripts);
--   what Lance's 3 s period does is server side: AzerothCore's spell script takes a third of the slow away at
--     every period (30 / 20 / 10% a stack) and a new Lance starts the 9 s over. That is what is built here;
--   the room: Blizzard's map of Gorefiend's Vigil (Media/Maps/BT04) covers world X 343.3..636.7 and
--     Y 135..575 (UiMapAssignment of UiMap 343), 0.436 yd a pixel. The square hall measures 135 x 134 pixels on
--     it: 59 x 58.5 yd. Blizzard's geometry of the hall (blacktemple.wmo, group "Gorefiend's Vigil") says the
--     same: its floor is 60 x 58 yd. The floor shows that piece of the map;
--   the room you see: that same geometry with its own textures and baked light, and the floor's heights from
--     it, see TeronGorefiendFloor.lua. The middle of the hall's north half
--     is a pit 2.75 yd deep and 22 yd wide, with steps down its west, east and south sides.
-- NOT verified anywhere: the run speed of constructs and of the spirit (8 yd/s, the creature default), and
-- where Teron and a raid stand (here: in the pit, at its north end).
local addonName, ns = ...

local T = ns.Trainer
local Dist = T.Dist
local floor, min, max, pi = math.floor, math.min, math.max, math.pi

local ARENA_W, ARENA_H = 60, 58
local BOSS_X, BOSS_Y = 31, 52
local GHOST_TIME = 60
local AOE_RANGE = 12
local MELEE = 3
local CONSTRUCT_HP = 41567
local CREATURE_RUN = 8

local DISPLAY_TERON, DISPLAY_SPIRIT, DISPLAY_CONSTRUCT = 21254, 21300, 21305

-- Effect model files and sound kits, as the client's spell visuals name them.
local FX = {
    lanceMissile = 166373, lanceImpact = 166372, lanceCastSound = 2559, lanceImpactSound = 10009,
    volleyMissile = 166375, volleyImpact = 166370, volleyCastSound = 2559, volleyImpactSound = 7,
    chainsCast = 166210, chainsCastSound = 3076, chainsBase = 165782, chainsBody = 166385, chainsSound = 1502,
    strikeImpact = 166239, strikeSound = 6477,
    shield = 166540, shieldSound = 39,
    markImpact = 166814, markSound = 743,
}

-- The raid: the tank in front of the boss, melee behind him, ranged and healers close around them, all down in
-- the pit (you start among them), which leaves the whole hall between the raid and the corners by the entrance.
-- { x, y, display, what they do }. The models are the Shattered Sun Offensive's soldiers (display IDs from
-- Wowhead: Veteran 22931, Warrior 20570, Trainee 22924, Peacekeeper 23714, Marksman 22752, Magi 22952,
-- Archmage 22973, Cleric 22953): armed blood elves and draenei that every faction's client has.
local RAID = {
    { 31, 48, 22931, "melee", tank = true }, { 28, 55, 20570, "melee" }, { 31, 56, 22924, "melee" },
    { 34, 55, 23714, "melee" },
    { 24, 48, 22752, "bow" }, { 26, 44.5, 22952, "caster" }, { 29, 42.5, 22953, "caster" },
    { 33, 42.5, 22973, "caster" }, { 38, 48, 22752, "bow" }, { 36, 44.5, 22953, "caster" }, { 31, 41, 22952, "caster" },
}

local function SpellIcon(spellID, fallback)
    return (GetSpellTexture and GetSpellTexture(spellID)) or ("Interface\\Icons\\" .. fallback)
end

local function IsGhost(sim)
    if sim.phase ~= "ghost" then return false, "You are still alive: run from the raid first." end
    return true
end

local function Constructs(sim)
    return sim:UnitsInRange(sim.player.x, sim.player.y, AOE_RANGE, "construct")
end

local abilities = {
    { id = "strike", key = "1", spell = 40325, name = "Spirit Strike", icon = SpellIcon(40325, "Spell_Shadow_DarkRitual"),
      tip = "638 damage to Teron in melee and he deals 10% less damage for 5 sec. Constructs are immune to it.",
      usable = IsGhost,
      use = function(sim)
          sim.stats.strikes = (sim.stats.strikes or 0) + 1
          sim:Fx({ kind = "model", fdid = FX.strikeImpact, unit = sim.boss, z = 2.5 }, 0.8)
          sim:Sound(FX.strikeSound)
      end,
      check = function(sim)
          if Dist(sim.player.x, sim.player.y, BOSS_X, BOSS_Y) > 5 + 3 then return false, "Out of range." end
          return true
      end },
    { id = "lance", key = "3", spell = 40157, name = "Spirit Lance", icon = SpellIcon(40157, "Spell_Frost_FrostBolt"),
      tip = "6,175 to 6,825 damage to your target, 30 yd. Slows it by 30% (stacks 3 times); the slow fades over 9 sec.",
      range = 30, needsTarget = true, usable = IsGhost,
      use = function(sim, ab, target)
          sim:Sound(FX.lanceCastSound)
          sim:Fx({ kind = "beam", x = sim.player.x, y = sim.player.y, x2 = target.x, y2 = target.y,
                   color = { 0.6, 0.85, 1 } }, 0.25)
          sim:Missile(FX.lanceMissile, sim.player.x, sim.player.y, target, 38, function(s, u)
              if u.dead then return end
              s:Damage(u, s:Random(6175, 6825))
              s:AddAura(u, "lance", { dur = 9, slow = 0.3, maxStacks = 3, fade = 3, name = "Spirit Lance",
                                      icon = SpellIcon(40157, "Spell_Frost_FrostBolt") })
              s:Fx({ kind = "model", fdid = FX.lanceImpact, unit = u, z = 1.5 }, 0.8)
              s:Sound(FX.lanceImpactSound)
          end)
      end },
    { id = "chains", key = "4", spell = 40175, name = "Spirit Chains", icon = SpellIcon(40175, "Spell_Frost_ChainsOfIce"),
      tip = "1,900 to 2,100 damage to every construct within 12 yd and stuns them for 5 sec. 15 sec cooldown.",
      cooldown = 15, usable = IsGhost,
      use = function(sim)
          sim:Sound(FX.chainsCastSound)
          sim:Fx({ kind = "model", fdid = FX.chainsCast, unit = sim.player }, 1.2)
          sim:Fx({ kind = "ring", x = sim.player.x, y = sim.player.y, r = AOE_RANGE, color = { 0.5, 0.7, 1 } }, 0.5)
          local hit = false
          for _, u in ipairs(Constructs(sim)) do
              sim:Damage(u, sim:Random(1900, 2100))
              sim:AddAura(u, "chains", { dur = 5, stun = true, name = "Spirit Chains",
                                         icon = SpellIcon(40175, "Spell_Frost_ChainsOfIce") })
              if not u.dead then
                  sim:Fx({ kind = "model", fdid = FX.chainsBase, unit = u }, 5)
                  sim:Fx({ kind = "model", fdid = FX.chainsBody, unit = u, z = 1.5 }, 5)
              end
              hit = true
          end
          if hit then sim:Sound(FX.chainsSound) end
      end },
    { id = "volley", key = "5", spell = 40314, name = "Spirit Volley", icon = SpellIcon(40314, "Spell_Frost_IceStorm"),
      tip = "9,900 to 12,100 damage to every construct within 12 yd. 15 sec cooldown.",
      cooldown = 15, usable = IsGhost,
      use = function(sim)
          sim:Sound(FX.volleyCastSound)
          sim:Fx({ kind = "ring", x = sim.player.x, y = sim.player.y, r = AOE_RANGE, color = { 0.8, 0.6, 1 } }, 0.5)
          for _, target in ipairs(Constructs(sim)) do
              sim:Missile(FX.volleyMissile, sim.player.x, sim.player.y, target, 15, function(s, u)
                  if u.dead then return end
                  s:Damage(u, s:Random(9900, 12100))
                  s:Fx({ kind = "model", fdid = FX.volleyImpact, unit = u, z = 1.5 }, 0.8)
                  s:Sound(FX.volleyImpactSound)
              end)
          end
      end },
    { id = "shield", key = "7", spell = 40322, name = "Spirit Shield", icon = SpellIcon(40322, "Ability_Shaman_WaterShield"),
      tip = "Shields the tank from 11,400 Shadow damage for 30 sec. 40 yd, 1.5 min cooldown.",
      cooldown = 90, usable = IsGhost,
      check = function(sim)
          if Dist(sim.player.x, sim.player.y, RAID[1][1], RAID[1][2]) > 40 then return false, "Out of range." end
          return true
      end,
      use = function(sim)
          sim.stats.shields = (sim.stats.shields or 0) + 1
          sim:Fx({ kind = "model", fdid = FX.shield, unit = sim.tank }, 30)
          sim:Sound(FX.shieldSound)
      end },
}

local function Die(sim)
    local p = sim.player
    sim.phase = "ghost"
    sim.ghostUntil = sim.time + GHOST_TIME
    sim.corpse = { x = p.x, y = p.y }
    sim:Spawn({ kind = "corpse", name = "Your corpse", x = p.x, y = p.y, facing = p.facing, model = "player",
                pose = "dead", radius = 1, color = { 0.4, 0.4, 0.4 } })
    p.ghost, p.name, p.color = true, "Vengeful Spirit", { 0.65, 0.85, 1 }
    p.model, p.display, p.speed = nil, DISPLAY_SPIRIT, CREATURE_RUN
    local raiders = sim:Alive("raider")
    local closest = 999
    for i = 1, 4 do
        -- Summon Skeleton: anywhere within 6 yd of the corpse
        local ang, r = sim:Random() * 2 * pi, 2 + sim:Random() * 4
        local prey = raiders[sim:Random(1, #raiders)]
        local u = sim:Spawn({ kind = "construct", name = "Shadowy Construct", targetable = true,
                              x = min(ARENA_W - 1, max(1, p.x + math.cos(ang) * r)),
                              y = min(ARENA_H - 1, max(1, p.y + math.sin(ang) * r)),
                              hp = CONSTRUCT_HP, speed = CREATURE_RUN, radius = 1.6, color = { 0.6, 0.25, 0.8 },
                              display = DISPLAY_CONSTRUCT, prey = prey, level = 70, elite = true, mana = false,
                              goal = { x = prey.x, y = prey.y, stop = MELEE } })
        sim:AddAura(u, "rise", { dur = 1, stun = true })
        closest = min(closest, Dist(u.x, u.y, prey.x, prey.y) - MELEE)
    end
    sim.stats.spawnDist = max(0, closest)
    sim.stats.closest = sim.stats.spawnDist
    sim.objective = "Kill the four Shadowy Constructs before they reach the raid."
    sim:Banner("You died. Volley (5), Chains (4), then Lance (3) each construct!", 3.5, 0.65, 0.85, 1)
end

local function Start(sim)
    sim.phase = "marked"
    sim.stats.kills = 0
    sim.boss = sim:Spawn({ kind = "boss", name = "Teron Gorefiend", x = BOSS_X, y = BOSS_Y, facing = -pi / 2, radius = 3,
                           color = { 0.55, 0.1, 0.1 }, display = DISPLAY_TERON, act = "melee" })
    for _, r in ipairs(RAID) do
        local u = sim:Spawn({ kind = "raider", name = r.tank and "Tank" or "Raider", x = r[1], y = r[2], radius = 0.9,
                              facing = math.atan2(BOSS_Y - r[2], BOSS_X - r[1]), display = r[3], act = r[4],
                              color = { 0.3, 0.55, 1 } })
        if r.tank then sim.tank = u end
    end
    sim.objective = "Shadow of Death: get far away from the raid before you die."
    sim:Banner("You are marked with Shadow of Death!", 3, 0.8, 0.4, 1)
    sim:Fx({ kind = "model", fdid = FX.markImpact, unit = sim.player, z = 1.5 }, 1.2)
    sim:Sound(FX.markSound)
end

local function Update(sim)
    if sim.phase == "marked" then
        local left = sim.diff.fuse - sim.time
        sim.bars[1] = { label = "Shadow of Death", remain = max(0, left), total = sim.diff.fuse, color = { 0.6, 0.3, 0.9 },
                        icon = SpellIcon(40251, "Spell_Arcane_PrismaticCloak"), harmful = true }
        if left <= 0 then Die(sim) end
        return
    end
    local alive, kills = 0, 0
    for _, u in ipairs(sim.units) do
        if u.kind == "construct" then
            if u.dead then
                kills = kills + 1
            else
                alive = alive + 1
                local gap = Dist(u.x, u.y, u.prey.x, u.prey.y) - MELEE
                if gap < sim.stats.closest then sim.stats.closest = max(0, gap) end
                if gap <= 0.05 then
                    sim.stats.kills = kills
                    sim:Lose("A Shadowy Construct reached the raid.")
                    return
                end
            end
        end
    end
    sim.stats.kills = kills
    local left = sim.ghostUntil - sim.time
    sim.bars[1] = { label = "Vengeful Spirit", remain = max(0, left), total = GHOST_TIME, color = { 0.5, 0.75, 1 },
                    icon = SpellIcon(40268, "Spell_Shadow_PossessUndead") }
    if alive == 0 then
        sim.ghostTime = GHOST_TIME - left
        sim:Win()
    elseif left <= 0 then
        sim:Lose("Your spirit faded with constructs still alive.")
    end
end

-- A win: 1000, plus 20 per second under 45 as a spirit, plus 10 per yard the closest construct stayed away.
local function Score(sim)
    local s = sim.stats
    if sim.state ~= "won" then return (s.kills or 0) * 50 end
    return floor(1000 + 20 * max(0, 45 - (sim.ghostTime or 45)) + 10 * (s.closest or 0))
end

local function Summary(sim)
    local s, out = sim.stats, {}
    if sim.state == "won" then
        out[#out + 1] = string.format("All four constructs dead after %.1f sec as a spirit.", sim.ghostTime or 0)
        out[#out + 1] = string.format("The closest one got within %d yd of a raider.", floor(s.closest or 0))
    else
        out[#out + 1] = string.format("%d of 4 constructs killed.", s.kills or 0)
    end
    if s.spawnDist then
        out[#out + 1] = string.format("They rose %d yd from the nearest raider they went for.", floor(s.spawnDist))
        if s.spawnDist < 35 then
            out[#out + 1] = "|cffffd100Tip:|r die further away: the corners by the entrance give the most time."
        end
    end
    local c = s.casts
    if sim.phase == "ghost" and sim.state ~= "won" then
        if not c.volley then
            out[#out + 1] = "|cffffd100Tip:|r open with Spirit Volley (5) while all four stand around your corpse."
        elseif not c.chains then
            out[#out + 1] = "|cffffd100Tip:|r Spirit Chains (4) right after the Volley stuns them for 5 sec."
        elseif (c.lance or 0) < 8 then
            out[#out + 1] = "|cffffd100Tip:|r Tab and Spirit Lance (3) every construct: the slow fades, keep it fresh."
        end
    end
    return out
end

T:RegisterEncounter("teron", {
    name = "Teron Gorefiend",
    desc = "Shadow of Death: die away from the raid, then kill your four Shadowy Constructs as a Vengeful Spirit.",
    icon = "Interface\\Icons\\Spell_Shadow_DeathPact",
    order = 10,
    -- map: the piece of Media/Maps/BT04_a (the top 1024 x 512 of the 1024 x 683 map) that is this hall
    arena = { w = ARENA_W, h = ARENA_H, labels = { { x = ARENA_W / 2, y = 2.5, text = "Entrance" } },
              height = T.HeightFn(ns.TrainerFloors and ns.TrainerFloors.teron),
              mesh = ns.TrainerFloors and ns.TrainerFloors.teron and ns.TrainerFloors.teron.mesh,
              map = { file = "Interface\\AddOns\\DisasterZone\\Media\\Maps\\BT04_a",
                      u0 = 0.3221, u1 = 0.4560, v0 = 0.2537, v1 = 0.5193 } },
    difficulties = {
        { id = "quick", name = "Quick (15 sec mark)", fuse = 15 },
        { id = "real", name = "Real (55 sec mark)", fuse = 55 },
    },
    player = { x = 31, y = 38, speed = 7, facing = pi / 2 },
    abilities = abilities,
    howTo = {
        "You are marked with |cffb48cffShadow of Death|r. Get away from the raid before the mark runs out.",
        "You die and four |cffb48cffShadowy Constructs|r rise around your corpse and run at the raid.",
        "As the spirit: |cffffd1005|r Volley, |cffffd1004|r Chains, then |cffffd100Tab|r + |cffffd1003|r Lance on each one.",
        "Volley and Chains again whenever they are ready. Both only reach 12 yd around you.",
    },
    start = Start,
    update = Update,
    score = Score,
    summary = Summary,
})

if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Trainer/Encounters/TeronGorefiend.lua", ...) then return end -- DisasterZone Games/Trainer/Encounters/TeronGorefiend.lua
-- Raid Trainer encounter: Teron Gorefiend (Black Temple), the Shadow of Death job.
-- You are marked, run away from the raid, die, and come back as a Vengeful Spirit; four Shadowy Constructs rise
-- from your corpse and walk to the raid. Kill them before one arrives.
--
-- Ability numbers are the TBC Classic spells (Spirit Lance 40157, Spirit Chains 40175, Spirit Volley 40314).
-- The constructs' health and speed are not published: they are tuned so that Volley > Chains > Lance on every
-- construct, twice, is a clean kill. The real mark lasts 55 seconds; here it is short so a try takes half a minute.
local addonName, ns = ...

local T = ns.Trainer
local Dist = T.Dist
local floor, min, max = math.floor, math.min, math.max

local ARENA_W, ARENA_H = 70, 90
local RAID_X, RAID_Y, RAID_R = 35, 58, 8
local BOSS_X, BOSS_Y = 35, 70
local GHOST_TIME = 60
local AOE_RANGE = 12

local function SpellIcon(spellID, fallback)
    return (GetSpellTexture and GetSpellTexture(spellID)) or fallback
end

local function IsGhost(sim)
    if sim.phase ~= "ghost" then return false, "You are still alive: run from the raid first." end
    return true
end

local function Constructs(sim)
    return sim:UnitsInRange(sim.player.x, sim.player.y, AOE_RANGE, "construct")
end

local abilities = {
    { id = "lance", key = "3", name = "Spirit Lance", icon = SpellIcon(40157, "Interface\\Icons\\Spell_Frost_FrostBolt02"),
      tip = "6,175 damage to your target, 30 yd. Slows it by 30% for 9 sec, stacking 3 times.",
      range = 30, needsTarget = true, usable = IsGhost,
      use = function(sim, ab, target)
          sim:Damage(target, 6175)
          sim:AddAura(target, "lance", { dur = 9, slow = 0.3, maxStacks = 3 })
          sim:Fx({ kind = "beam", x = sim.player.x, y = sim.player.y, x2 = target.x, y2 = target.y,
                   color = { 0.6, 0.85, 1 } }, 0.25)
      end },
    { id = "chains", key = "4", name = "Spirit Chains", icon = SpellIcon(40175, "Interface\\Icons\\Spell_Frost_ChainsOfIce"),
      tip = "1,900 damage to every construct within 12 yd and holds them in place for 5 sec. 15 sec cooldown.",
      cooldown = 15, usable = IsGhost,
      use = function(sim)
          for _, u in ipairs(Constructs(sim)) do
              sim:Damage(u, 1900)
              sim:AddAura(u, "chains", { dur = 5, stun = true })
          end
          sim:Fx({ kind = "ring", x = sim.player.x, y = sim.player.y, r = AOE_RANGE, color = { 0.5, 0.7, 1 } }, 0.5)
      end },
    { id = "volley", key = "5", name = "Spirit Volley", icon = SpellIcon(40314, "Interface\\Icons\\Spell_Frost_FrostNova"),
      tip = "9,900 to 12,100 damage to every construct within 12 yd. 15 sec cooldown.",
      cooldown = 15, usable = IsGhost,
      use = function(sim)
          for _, u in ipairs(Constructs(sim)) do
              sim:Damage(u, sim:Random(9900, 12100))
          end
          sim:Fx({ kind = "ring", x = sim.player.x, y = sim.player.y, r = AOE_RANGE, color = { 0.8, 0.6, 1 } }, 0.5)
      end },
}

local function Die(sim)
    local p, d = sim.player, sim.diff
    sim.phase = "ghost"
    sim.ghostUntil = sim.time + GHOST_TIME
    sim.corpse = { x = p.x, y = p.y }
    p.ghost, p.name, p.color = true, "Vengeful Spirit", { 0.65, 0.85, 1 }
    sim.stats.spawnDist = max(0, Dist(p.x, p.y, RAID_X, RAID_Y) - RAID_R)
    sim.stats.closest = sim.stats.spawnDist
    for i = 1, 4 do
        local ox, oy = (i % 2 == 0) and 2.5 or -2.5, (i > 2) and 2.5 or -2.5
        sim:Spawn({ kind = "construct", name = "Shadowy Construct", targetable = true,
                    x = min(ARENA_W - 1, max(1, p.x + ox)), y = min(ARENA_H - 1, max(1, p.y + oy)),
                    hp = d.hp, speed = d.speed, radius = 1.6, color = { 0.6, 0.25, 0.8 },
                    goal = { x = RAID_X, y = RAID_Y } })
    end
    sim.objective = "Kill the four Shadowy Constructs before they reach the raid."
    sim:Banner("You died. Volley (5), Chains (4), then Lance (3) each construct!", 3.5, 0.65, 0.85, 1)
end

local function Start(sim)
    sim.phase = "marked"
    sim.stats.kills = 0
    sim:Spawn({ kind = "boss", name = "Teron Gorefiend", x = BOSS_X, y = BOSS_Y, radius = 3, color = { 0.55, 0.1, 0.1 } })
    sim.zones[1] = { x = RAID_X, y = RAID_Y, r = RAID_R, label = "Raid", dots = 20, color = { 0.2, 0.5, 0.9 } }
    sim.objective = "Shadow of Death: run far away from the raid before you die."
    sim:Banner("You are marked with Shadow of Death!", 3, 0.8, 0.4, 1)
end

local function Update(sim)
    if sim.phase == "marked" then
        local left = sim.diff.fuse - sim.time
        sim.bars[1] = { label = "Shadow of Death", remain = max(0, left), total = sim.diff.fuse, color = { 0.6, 0.3, 0.9 } }
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
                local gap = Dist(u.x, u.y, RAID_X, RAID_Y) - RAID_R
                if gap < sim.stats.closest then sim.stats.closest = max(0, gap) end
                if gap <= 0 then
                    sim.stats.kills = kills
                    sim:Lose("A Shadowy Construct reached the raid.")
                    return
                end
            end
        end
    end
    sim.stats.kills = kills
    local left = sim.ghostUntil - sim.time
    sim.bars[1] = { label = "Vengeful Spirit", remain = max(0, left), total = GHOST_TIME, color = { 0.5, 0.75, 1 } }
    if alive == 0 then
        sim.ghostTime = GHOST_TIME - left
        sim:Win()
    elseif left <= 0 then
        sim:Lose("Your spirit faded with constructs still alive.")
    end
end

-- A win: 1000, plus 20 per second under 45 as a ghost, plus 10 per yard the closest construct stayed away.
local function Score(sim)
    local s = sim.stats
    if sim.state ~= "won" then return (s.kills or 0) * 50 end
    local pts = 1000 + 20 * max(0, 45 - (sim.ghostTime or 45)) + 10 * (s.closest or 0)
    return floor(pts * (sim.diff.mult or 1))
end

local function Summary(sim)
    local s, out = sim.stats, {}
    if sim.state == "won" then
        out[#out + 1] = string.format("All four constructs dead after %.1f sec as a spirit.", sim.ghostTime or 0)
        out[#out + 1] = string.format("The closest one got within %d yd of the raid.", floor(s.closest or 0))
    else
        out[#out + 1] = string.format("%d of 4 constructs killed.", s.kills or 0)
    end
    if s.spawnDist then
        out[#out + 1] = string.format("You died %d yd from the raid.", floor(s.spawnDist))
        if s.spawnDist < 35 then
            out[#out + 1] = "|cffffd100Tip:|r die further away: the corners by the entrance give the most time."
        end
    end
    local c = s.casts
    if sim.phase == "ghost" and sim.state ~= "won" then
        if not c.volley then
            out[#out + 1] = "|cffffd100Tip:|r open with Spirit Volley (5) while all four stand on your corpse."
        elseif not c.chains then
            out[#out + 1] = "|cffffd100Tip:|r Spirit Chains (4) right after the Volley holds them for 5 sec."
        elseif (c.lance or 0) < 8 then
            out[#out + 1] = "|cffffd100Tip:|r Tab and Spirit Lance (3) every construct: three stacks nearly stop it."
        end
    end
    out[#out + 1] = "|cff888888In the real fight the mark lasts 55 sec: start moving with 10 to 15 sec left.|r"
    return out
end

T:RegisterEncounter("teron", {
    name = "Teron Gorefiend",
    desc = "Shadow of Death: die away from the raid, then kill your four Shadowy Constructs as a Vengeful Spirit.",
    icon = "Interface\\Icons\\Spell_Shadow_DeathPact",
    order = 10,
    arena = { w = ARENA_W, h = ARENA_H, labels = { { x = ARENA_W / 2, y = 2.5, text = "Entrance" } } },
    difficulties = {
        { id = "learner", name = "Learner", fuse = 15, hp = 32000, speed = 5.5, mult = 0.75 },
        { id = "normal", name = "Normal", fuse = 12, hp = 40000, speed = 7, mult = 1 },
        { id = "hard", name = "Hard", fuse = 10, hp = 46000, speed = 8.5, mult = 1.5 },
    },
    defaultDifficulty = "normal",
    player = { x = RAID_X, y = RAID_Y - 3, speed = 7 },
    abilities = abilities,
    howTo = {
        "You are marked with |cffb48cffShadow of Death|r. Run away from the raid before the timer ends.",
        "You die and four |cffb48cffShadowy Constructs|r rise from your corpse and walk to the raid.",
        "As a spirit: |cffffd1005|r Volley, |cffffd1004|r Chains, then |cffffd100Tab|r + |cffffd1003|r Lance on each one.",
        "Volley and Chains again whenever they are ready. Stay within 12 yd of the constructs.",
    },
    start = Start,
    update = Update,
    score = Score,
    summary = Summary,
})

-- CDLoot Games/Murloc/Data.lua
-- ns.MurlocData: units, maps, talents, boons, reputation and tuning for "Mrglglgl!" (co-op lane tower defense).
-- All gameplay numbers are integers (the simulation must be bit-identical on every client).
-- Distances: a lane is LANE units long (10 columns of COL units); murlocs walk from LANE down to 0.
local addonName, ns = ...

local D = ns:NewModule("MurlocData")

D.TICK_RATE = 10            -- simulation ticks per second
D.LANE = 10000
D.COL = 1000
D.SLOTS = 8                 -- build slots per lane (columns 1..8; 9-10 is the surf where murlocs land)
D.MAX_PLAYERS = 5
D.LIVES = 10
D.MAX_LIVES = 15
D.START_GOLD = 150
D.TRICKLE = 1               -- gold per player every TRICKLE_EVERY ticks
D.TRICKLE_EVERY = 10
D.CONTACT = 450             -- a murloc this close to a defender in front of it stops and attacks
D.WAVE_BREAK = 120          -- ticks between waves (time to vote on a boon)
D.FIRST_BREAK = 100
D.SPAWN_GAP = 15            -- ticks between two murlocs of one lane
D.GIFT = 25                 -- gold per "gift" click
D.CRIT_CHANCE = 10          -- % for ranged / hero attacks
D.SELL_REFUND = 50          -- % of the gold spent

---------------------------------------------------------------------------
-- Defenders. range = reach ahead; cd = ticks between actions; slow = ticks of 50% slow on hit;
-- rep = reputation tier needed (0 Neutral .. 4 Exalted). Ranks multiply hp / dmg / heal by RANK_MULT.
---------------------------------------------------------------------------

D.RANKS = 3
D.RANK_MULT = { 100, 145, 200 }

D.defenders = {
    { id = "footman", name = "Footman", ranks = { "Footman", "Knight", "Champion" }, cost = 50, rep = 0,
      hp = 320, dmg = 10, range = 600, cd = 10,
      icon = "Interface\\Icons\\INV_Shield_06", proj = "melee",
      desc = "Tough and cheap. Holds the line so the others can shoot." },
    { id = "rifleman", name = "Dwarven Rifleman", ranks = { "Rifleman", "Marksman", "Sharpshooter" }, cost = 75, rep = 0,
      hp = 90, dmg = 20, range = 6000, cd = 12, crit = true,
      icon = "Interface\\Icons\\INV_Weapon_Rifle_06", proj = "bullet",
      desc = "Long-range single-target damage. Can crit." },
    { id = "frostmage", name = "Frost Mage", ranks = { "Frostbolt (Rank 1)", "Frostbolt (Rank 2)", "Frostbolt (Rank 3)" },
      cost = 100, rep = 0, hp = 70, dmg = 8, range = 5000, cd = 15, slow = 30,
      icon = "Interface\\Icons\\Spell_Frost_FrostBolt02", proj = "frost",
      desc = "Frostbolt: slows murlocs by 50% for 3 seconds." },
    { id = "acolyte", name = "Acolyte", ranks = { "Acolyte", "Priest", "High Priest" }, cost = 90, rep = 1,
      hp = 110, dmg = 4, range = 3000, cd = 14, heal = 22,
      icon = "Interface\\Icons\\Spell_Holy_FlashHeal", proj = "holy",
      desc = "Heals the most wounded defender in your lane. (Friendly)" },
    { id = "mine", name = "Goblin Land Mine", ranks = { "Land Mine", "Big Mine", "Goblin Sapper Charge" }, cost = 60, rep = 2,
      hp = 1, dmg = 260, range = 450, cd = 1, splash = 1200, once = true, noBlock = true,
      icon = "Interface\\Icons\\INV_Misc_Bomb_05", proj = "boom",
      desc = "Explodes when a murloc steps on it. Murlocs walk over it. (Honored)" },
    { id = "totem", name = "Windfury Totem", ranks = { "Windfury Totem", "Windfury Totem II", "Windfury Totem III" },
      cost = 120, rep = 3, hp = 150, dmg = 0, range = 0, cd = 10, aura = 1,
      icon = "Interface\\Icons\\Spell_Nature_Windfury", proj = nil,
      desc = "Defenders in the next column on each side attack 30% faster. (Revered)" },
}
D.TOTEM_HASTE = 70          -- % of the normal cooldown next to a totem

---------------------------------------------------------------------------
-- Murlocs. speed = units per tick; leak = lives lost when it reaches the shore.
-- display = candidate creature display IDs for 3D models (first that loads wins; icon otherwise).
---------------------------------------------------------------------------

D.murlocs = {
    { id = "forager", name = "Murloc Forager", hp = 60, speed = 30, dmg = 6, cd = 10, bounty = 8, leak = 1,
      icon = "Interface\\Icons\\INV_Misc_Fish_02", size = 30, display = { 478, 441, 486 } },
    { id = "tidehunter", name = "Murloc Tidehunter", hp = 190, speed = 18, dmg = 14, cd = 10, bounty = 15, leak = 1,
      icon = "Interface\\Icons\\INV_Misc_Fish_09", size = 36, display = { 486, 527, 478 } },
    { id = "coastrunner", name = "Murloc Coastrunner", hp = 70, speed = 45, dmg = 5, cd = 10, bounty = 10, leak = 1,
      icon = "Interface\\Icons\\INV_Misc_Fish_16", size = 28, leap = 1300, display = { 1162, 478, 441 },
      desc = "Fast. Leaps over the first defender it reaches." },
    { id = "oracle", name = "Murloc Oracle", hp = 95, speed = 20, dmg = 5, cd = 10, bounty = 14, leak = 1,
      icon = "Interface\\Icons\\INV_Misc_Fish_05", size = 32, heals = 14, healRange = 1600, healEvery = 20,
      display = { 3615, 527, 478 }, desc = "Heals nearby murlocs. Kill it first!" },
    { id = "netter", name = "Murloc Netter", hp = 130, speed = 22, dmg = 8, cd = 10, bounty = 14, leak = 1,
      icon = "Interface\\Icons\\INV_Misc_Net_01", size = 32, net = 40, display = { 1163, 486, 478 },
      desc = "Throws a net: the first defender it reaches can't act for 4 seconds." },
    { id = "king", name = "King Mrgl-Mrgl", hp = 1400, speed = 12, dmg = 45, cd = 10, bounty = 120, leak = 5,
      icon = "Interface\\Icons\\INV_Misc_Fish_18", size = 48, boss = true, hopAt = 5500, display = { 15984, 15398, 527 },
      desc = "Leaps into a neighbouring lane halfway." },
    { id = "tidecaller", name = "Tidecaller Grrlglrg", hp = 1800, speed = 10, dmg = 35, cd = 10, bounty = 160, leak = 5,
      icon = "Interface\\Icons\\Spell_Frost_SummonWaterElemental", size = 50, boss = true, summon = 70,
      display = { 3615, 527 }, desc = "Calls a Forager from the surf every 7 seconds." },
}

D.LUST = { name = "Bloodlust", duration = 150, cooldown = 1200, icon = "Interface\\Icons\\Spell_Nature_BloodLust" }

D.defenderIndex, D.murlocIndex = {}, {}
for i, d in ipairs(D.defenders) do D.defenderIndex[d.id] = i end
for i, m in ipairs(D.murlocs) do D.murlocIndex[m.id] = i end
local M = D.murlocIndex

-- Wave n, one lane: an array of murloc kinds (before shuffling). Bosses are added separately (one lane).
function D.WaveList(n)
    local list = {}
    local function add(kind, count) for _ = 1, count do list[#list + 1] = kind end end
    add(M.forager, 2 + n)
    add(M.tidehunter, math.floor(n / 2))
    if n >= 2 then add(M.coastrunner, math.floor((n + 1) / 3)) end
    if n >= 3 then add(M.oracle, math.floor((n - 1) / 3)) end
    if n >= 4 then add(M.netter, math.floor((n - 2) / 3)) end
    return list
end

-- Boss of wave n on a map (nil = none).
function D.WaveBoss(n, map)
    if n % 5 ~= 0 then return nil end
    local m = D.maps[map] or D.maps[1]
    if (n / 5) % 2 == 1 then return M[m.boss] end
    return M[m.boss2 or "tidecaller"]
end

function D.ScaledHp(base, wave)
    return math.floor(base * (100 + 12 * (wave - 1)) / 100)
end

---------------------------------------------------------------------------
-- Maps + lane terrain. Each lane gets `features` random tiles (seeded, the same on every client).
--   rocks: no building          shallows: murlocs 50% slower
--   bonfire: +30% damage/heal   shrine: +50% max hp        current: murlocs 50% faster
---------------------------------------------------------------------------

D.terrain = {
    rocks    = { name = "Rocks", desc = "Nothing can be built here.", color = { 0.35, 0.33, 0.3 } },
    shallows = { name = "Shallows", desc = "Murlocs wade through at half speed.", color = { 0.15, 0.35, 0.55 }, slow = true },
    current  = { name = "Rip Current", desc = "Murlocs surf through 50% faster.", color = { 0.1, 0.5, 0.6 }, fast = true },
    bonfire  = { name = "Bonfire", desc = "A defender here deals +30% damage and healing.", color = { 0.6, 0.3, 0.05 }, dmg = 130 },
    shrine   = { name = "Light's Shrine", desc = "A defender here has +50% health.", color = { 0.6, 0.55, 0.2 }, hp = 150 },
    glowcap  = { name = "Glowcap", desc = "A defender here deals +30% damage and healing.", color = { 0.3, 0.2, 0.6 }, dmg = 130 },
    bog      = { name = "Bog", desc = "Murlocs wade through at half speed.", color = { 0.2, 0.3, 0.15 }, slow = true },
}

D.maps = {
    { id = "southshore", name = "Southshore Coast", rep = 0, boss = "king", features = 2,
      pool = { "rocks", "shallows", "bonfire", "shrine" }, ground = "sand", lane = { 0.16, 0.2, 0.1 }, hpMult = 100,
      blurb = "The murlocs of Hillsbrad are coming ashore." },
    { id = "stranglethorn", name = "Stranglethorn Vale", rep = 1, boss = "king", boss2 = "tidecaller", features = 3,
      pool = { "rocks", "current", "shallows", "bonfire", "shrine" }, ground = "jungle", lane = { 0.1, 0.2, 0.08 }, hpMult = 115,
      blurb = "Jungle beaches, rip currents and angrier murlocs." },
    { id = "zangarmarsh", name = "Zangarmarsh", rep = 2, boss = "tidecaller", boss2 = "king", features = 3,
      pool = { "bog", "glowcap", "current", "rocks", "shrine" }, ground = "marsh", lane = { 0.1, 0.12, 0.2 }, hpMult = 135,
      blurb = "Bloodscale murlocs in the glowing swamps of Outland." },
}
D.mapIndex = {}
for i, m in ipairs(D.maps) do D.mapIndex[m.id] = i end

---------------------------------------------------------------------------
-- Heroes: one free copy of each player, shaped by their spec role and scaled by their gear.
---------------------------------------------------------------------------

D.HERO_RESPAWN = 300
D.POWER_MIN, D.POWER_MAX = 60, 200
D.HERO_MAX_LEVEL = 10

function D.XpForLevel(level) return 6 + 4 * level end   -- kills in your lane to reach level+1

D.heroRoles = {
    tank   = { hp = 900, dmg = 12, range = 600,  cd = 10 },
    healer = { hp = 220, dmg = 10, range = 3000, cd = 12, heal = 34 },
    melee  = { hp = 360, dmg = 30, range = 700,  cd = 8 },
    caster = { hp = 160, dmg = 24, range = 5500, cd = 15, splash = 800 },
    ranged = { hp = 190, dmg = 32, range = 7000, cd = 12 },
}

D.heroClass = {
    PRIEST  = { crossLane = true },
    SHAMAN  = { chain = 3 },
    MAGE    = { slow = 20 },
    DRUID = {}, PALADIN = {}, WARRIOR = {}, ROGUE = {}, HUNTER = {}, WARLOCK = {},
}

-- Talents: 3 random offers per level-up from the hero's role pool. Each can be taken up to 3 times.
-- Modifiers: hp / dmg / heal (+%), haste (-% cooldown), splash (+units), slow (ticks), chain (+targets),
-- cross (heals neighbouring lanes), lifesteal (% of damage healed on self), crit (+% chance).
D.talents = {
    tank = {
        { id = "shieldwall", name = "Shield Wall", icon = "Interface\\Icons\\Ability_Warrior_ShieldWall", hp = 30 },
        { id = "thunderclap", name = "Thunder Clap", icon = "Interface\\Icons\\Spell_Nature_ThunderClap", splash = 600, slow = 10 },
        { id = "revenge", name = "Revenge", icon = "Interface\\Icons\\Ability_Warrior_Revenge", dmg = 50 },
        { id = "laststand", name = "Last Stand", icon = "Interface\\Icons\\Spell_Holy_AshesToAshes", lifesteal = 40 },
    },
    healer = {
        { id = "impheal", name = "Improved Healing", icon = "Interface\\Icons\\Spell_Holy_Heal02", heal = 30 },
        { id = "beacon", name = "Prayer of Healing", icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02", cross = true },
        { id = "holyshock", name = "Holy Shock", icon = "Interface\\Icons\\Spell_Holy_SearingLight", dmg = 100 },
        { id = "chainheal", name = "Chain Heal", icon = "Interface\\Icons\\Spell_Nature_HealingWaveGreater", chain = 1 },
        { id = "divine", name = "Divine Spirit", icon = "Interface\\Icons\\Spell_Holy_DivineSpirit", haste = 20 },
    },
    melee = {
        { id = "flurry", name = "Flurry", icon = "Interface\\Icons\\Ability_GhoulFrenzy", haste = 25 },
        { id = "cleave", name = "Cleave", icon = "Interface\\Icons\\Ability_Warrior_Cleave", splash = 500 },
        { id = "mortal", name = "Mortal Strike", icon = "Interface\\Icons\\Ability_Warrior_SavageBlow", dmg = 40 },
        { id = "bloodthirst", name = "Bloodthirst", icon = "Interface\\Icons\\Spell_Nature_BloodLust", lifesteal = 30 },
        { id = "precision", name = "Precision", icon = "Interface\\Icons\\Ability_Marksmanship", crit = 10 },
    },
    caster = {
        { id = "frost", name = "Improved Frostbolt", icon = "Interface\\Icons\\Spell_Frost_FrostBolt02", slow = 20 },
        { id = "arcane", name = "Arcane Power", icon = "Interface\\Icons\\Spell_Nature_Lightning", dmg = 40 },
        { id = "blizzard", name = "Blizzard", icon = "Interface\\Icons\\Spell_Frost_IceStorm", splash = 400 },
        { id = "focus", name = "Presence of Mind", icon = "Interface\\Icons\\Spell_Nature_EnchantArmor", haste = 20 },
        { id = "ignite", name = "Critical Mass", icon = "Interface\\Icons\\Spell_Fire_Incinerate", crit = 10 },
    },
    ranged = {
        { id = "trueshot", name = "Trueshot Aura", icon = "Interface\\Icons\\Ability_TrueShot", dmg = 30 },
        { id = "rapidfire", name = "Rapid Fire", icon = "Interface\\Icons\\Ability_Hunter_RunningShot", haste = 25 },
        { id = "multishot", name = "Multi-Shot", icon = "Interface\\Icons\\Ability_UpgradeMoonGlaive", splash = 400 },
        { id = "concussive", name = "Concussive Shot", icon = "Interface\\Icons\\Spell_Frost_Stun", slow = 20 },
        { id = "mortalshots", name = "Mortal Shots", icon = "Interface\\Icons\\Ability_PierceDamage", crit = 10 },
    },
}

D.TALENT_MAX = 3

function D.PowerFromItemLevel(ilvl)
    ilvl = tonumber(ilvl) or 0
    local p = math.floor(100 + (ilvl - 100) * 2)
    if p < D.POWER_MIN then p = D.POWER_MIN end
    if p > D.POWER_MAX then p = D.POWER_MAX end
    return p
end

-- Integer stats of one hero. picks (optional) = { [talentIndex] = count } for the hero's role pool.
-- Each hero level also adds +5% hp / damage / healing.
function D.HeroStats(hero, picks, level)
    local base = D.heroRoles[hero.role] or D.heroRoles.melee
    local twist = D.heroClass[hero.class] or {}
    local pw = hero.power * (100 + 5 * ((level or 1) - 1)) / 100
    local m = { hp = 0, dmg = 0, heal = 0, haste = 0, splash = 0, slow = 0, chain = 0, lifesteal = 0, crit = 0 }
    local cross = twist.crossLane
    local pool = D.talents[hero.role] or {}
    for i, t in ipairs(pool) do
        local n = picks and picks[i] or 0
        if n > 0 then
            for _, k in ipairs({ "hp", "dmg", "heal", "haste", "splash", "slow", "chain", "lifesteal", "crit" }) do
                if t[k] then m[k] = m[k] + t[k] * n end
            end
            if t.cross then cross = true end
        end
    end
    local function s(v, pct) return v and math.floor(v * pw / 100 * (100 + (pct or 0)) / 100) or nil end
    local splash = (base.splash or 0) + m.splash
    local slow = (twist.slow or 0) + m.slow
    return {
        hp = s(base.hp, m.hp), dmg = s(base.dmg, m.dmg), heal = s(base.heal, m.heal), range = base.range,
        cd = math.max(3, math.floor(base.cd * (100 - math.min(60, m.haste)) / 100)),
        splash = splash > 0 and splash or nil, slow = slow > 0 and slow or nil,
        chain = (twist.chain or 1) + m.chain, crossLane = cross, lifesteal = m.lifesteal > 0 and m.lifesteal or nil,
        crit = D.CRIT_CHANCE + m.crit,
    }
end

---------------------------------------------------------------------------
-- Party boons: offered after each wave, the party votes, the winner applies for the rest of the game.
---------------------------------------------------------------------------

D.boons = {
    { id = "motw", name = "Mark of the Wild", icon = "Interface\\Icons\\Spell_Nature_Regeneration",
      desc = "All defenders +15% health (now and later)." },
    { id = "shout", name = "Battle Shout", icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
      desc = "All defenders +15% damage." },
    { id = "bank", name = "Goblin Bank Loan", icon = "Interface\\Icons\\INV_Misc_Coin_02",
      desc = "Everyone gets 80 gold right now." },
    { id = "renew", name = "Renew", icon = "Interface\\Icons\\Spell_Holy_Renew",
      desc = "Heal every defender to full, and heroes respawn instantly." },
    { id = "fortify", name = "Southshore Militia", icon = "Interface\\Icons\\INV_Shield_05",
      desc = "+2 lives (max 15)." },
    { id = "bounty", name = "Bounty Board", icon = "Interface\\Icons\\INV_Misc_Note_01",
      desc = "Murloc bounties +25%." },
    { id = "haste", name = "Mana Tide", icon = "Interface\\Icons\\Spell_Frost_SummonWaterElemental",
      desc = "All defenders attack 10% faster." },
}
D.BOON_OFFER = 3

---------------------------------------------------------------------------
-- Reputation (Southshore Militia) and achievements (per character, saved).
---------------------------------------------------------------------------

D.REP_TIERS = {
    { name = "Neutral", at = 0 }, { name = "Friendly", at = 300 }, { name = "Honored", at = 1200 },
    { name = "Revered", at = 3000 }, { name = "Exalted", at = 6000 },
}

-- Reputation earned by a finished game.
function D.RepForGame(wave, kills, players)
    return math.floor(wave * 12 + kills / 2 + (players > 1 and 25 or 0))
end

function D.RepTier(points)
    local tier = 0
    for i, t in ipairs(D.REP_TIERS) do
        if (points or 0) >= t.at then tier = i - 1 end
    end
    return tier
end

D.achievements = {
    { id = "wave5",  name = "Beachhead",            desc = "Reach wave 5." },
    { id = "wave10", name = "Southshore Stands",    desc = "Reach wave 10." },
    { id = "wave20", name = "Tide Turner",          desc = "Reach wave 20." },
    { id = "king",   name = "Regicide",             desc = "Defeat King Mrgl-Mrgl." },
    { id = "tide",   name = "Low Tide",             desc = "Defeat Tidecaller Grrlglrg." },
    { id = "party5", name = "The Whole Guild Came", desc = "Reach wave 10 with 5 players." },
    { id = "rich",   name = "Mrgl Hoarder",         desc = "Anyone in your game holds 1000 gold at once." },
    { id = "hero10", name = "Local Legend",         desc = "Get your hero to level 10." },
    { id = "zanga",  name = "Through the Dark Portal", desc = "Reach wave 10 in Zangarmarsh." },
    { id = "exalted", name = "Hero of Southshore",  desc = "Reach Exalted with the Southshore Militia." },
}

---------------------------------------------------------------------------
-- Models. Defenders are race models dressed in real TBC gear (faction-aware); totem / mine / murlocs use
-- creature display IDs (candidates tried in order; overridable in-game with /cdl murlocmodels).
---------------------------------------------------------------------------

D.MEDIA = "Interface\AddOns\CDLoot\Media\Murloc\\"

-- race IDs: 1 Human, 2 Orc, 3 Dwarf, 5 Undead, 7 Gnome, 8 Troll, 10 Blood Elf; sex 0 male, 1 female
local FOOTMAN_GEAR = { 28801, 29921, 28666, 28729, 28606 }    -- Maulgar's Warhelm, Fire Crest Breastplate, ...
local RIFLE_GEAR = { 30728, 28589, 28735, 32325 }             -- Fathom-Helm, Beastmaw Pauldrons, ..., Rifle
local MAGE_GEAR = { 28602, 28726, 28633 }                     -- Robe of the Elder Scribe, Mantle, Staff
local PRIEST_GEAR = { 30107, 28612, 30732 }                   -- Vestments of the Sea-Witch, ..., Exodar Life-Staff
D.outfits = {
    Alliance = {
        footman = { race = 1, sex = 0, items = FOOTMAN_GEAR }, rifleman = { race = 3, sex = 0, items = RIFLE_GEAR },
        frostmage = { race = 7, sex = 1, items = MAGE_GEAR }, acolyte = { race = 1, sex = 1, items = PRIEST_GEAR },
    },
    Horde = {
        footman = { race = 2, sex = 0, items = FOOTMAN_GEAR }, rifleman = { race = 8, sex = 0, items = RIFLE_GEAR },
        frostmage = { race = 5, sex = 0, items = MAGE_GEAR }, acolyte = { race = 10, sex = 1, items = PRIEST_GEAR },
    },
}
D.creatureModels = {
    mine = { 7358, 6532, 4587 },
    totem = { 4589, 4587, 4590, 4588 },
}
-- Equipment slots sent with a hero so other players can see you in your gear.
D.HERO_GEAR_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16, 17, 18, 19 }

D.QUOTES = {
    "Mrglglgl!", "Mrrrggk!", "Rwlrwlrwlrwl!", "Mmmrrglllm!", "Aaaaaughibbrgubugbugrguburgle!",
}

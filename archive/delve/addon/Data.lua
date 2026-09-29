-- CDLoot Games/RPG/Data.lua
-- ns.RPGData: "Delve" — a co-op turn-based dungeon RPG (1-5 players). Class kits by spec role, enemies and bosses,
-- in-run loot, talents, room types, reputation and achievements. All gameplay numbers are integers: the simulation
-- (Games/RPG/Sim.lua) must be bit-identical on every client.
local addonName, ns = ...

local D = ns:NewModule("RPGData")

D.MAX_PLAYERS = 5
D.POWER_MIN, D.POWER_MAX = 60, 200
D.CRIT = 8                  -- % base crit chance
D.REVIVE_PCT = 35           -- % hp a fallen hero gets back after a won fight
D.RECOVER_PCT = 40          -- % hp the survivors recover after a won fight
D.PLAN_TIME = 20            -- seconds to choose an action each round (the round resolves early when all are ready)
D.CHOICE_TIME = 30          -- seconds to vote on the path / pick loot before the host picks for you
D.TAUNT_ROUNDS = 2          -- rounds an enemy is forced onto the taunter
D.SOLO_REGEN = 6            -- % max health a lone hero recovers each round ("Second Wind", solo runs only)

---------------------------------------------------------------------------
-- Resources (per round)
---------------------------------------------------------------------------

D.resources = {
    mana   = { name = "Mana",   max = 100, start = 100, regen = 8,  color = { 0.2, 0.4, 1 } },
    rage   = { name = "Rage",   max = 100, start = 20,  regen = 8,  color = { 0.9, 0.1, 0.1 } },
    energy = { name = "Energy", max = 100, start = 100, regen = 35, color = { 1, 0.9, 0.1 } },
}

-- Resource of a class + role.
function D.ResourceFor(class, role)
    if class == "WARRIOR" then return "rage" end
    if class == "ROGUE" then return "energy" end
    if class == "DRUID" then
        if role == "tank" then return "rage" end
        if role == "melee" then return "energy" end
    end
    return "mana"
end

---------------------------------------------------------------------------
-- Abilities (one per round). kind: dmg | aoe | heal | hot | shield | taunt | interrupt | cc | buff | selfdr | potion
-- cd = cooldown in rounds; cost = resource; threat = threat multiplier; amt = base amount at 100% power;
-- dur = rounds for hot / cc / buff / selfdr; tgt = enemy | ally | self | none. Slot 1 is always the free basic move.
---------------------------------------------------------------------------

-- Every kit also gets this as the last ability: one potion per fight (the cooldown resets after each fight).
D.POTION = { id = "potion", kind = "potion", tgt = "self", amt = 40, cd = 999, cost = 0 }
D.ABILITIES = 5

D.kits = {
    tank = {
        { id = "sunder", kind = "dmg", tgt = "enemy", amt = 16, threat = 4, cost = 0 },
        { id = "clap", kind = "aoe", tgt = "none", amt = 12, cd = 2, cost = 20, threat = 4 },
        { id = "taunt", kind = "taunt", tgt = "enemy", cd = 3, cost = 0 },
        { id = "wall", kind = "selfdr", tgt = "self", amt = 60, dur = 2, cd = 5, cost = 0 },
    },
    healer = {
        { id = "nuke", kind = "dmg", tgt = "enemy", amt = 20, cost = 0 },
        { id = "flash", kind = "heal", tgt = "ally", amt = 62, cost = 15 },
        { id = "hot", kind = "hot", tgt = "ally", amt = 75, dur = 3, cost = 12 },
        { id = "shield", kind = "shield", tgt = "ally", amt = 60, cd = 2, cost = 15 },
    },
    melee = {
        { id = "strike", kind = "dmg", tgt = "enemy", amt = 30, cost = 25 },
        { id = "finisher", kind = "dmg", tgt = "enemy", amt = 62, cd = 3, cost = 30 },
        { id = "kick", kind = "interrupt", tgt = "enemy", amt = 10, cd = 3, cost = 15 },
        { id = "frenzy", kind = "buff", tgt = "self", amt = 40, dur = 2, cd = 5, cost = 0 },
    },
    caster = {
        { id = "bolt", kind = "dmg", tgt = "enemy", amt = 36, cost = 8 },
        { id = "storm", kind = "aoe", tgt = "none", amt = 20, cd = 1, cost = 22 },
        { id = "counter", kind = "interrupt", tgt = "enemy", amt = 0, cd = 3, cost = 10 },
        { id = "cc", kind = "cc", tgt = "enemy", dur = 2, cd = 4, cost = 12 },
    },
    ranged = {
        { id = "shot", kind = "dmg", tgt = "enemy", amt = 30, cost = 0 },
        { id = "multi", kind = "aoe", tgt = "none", amt = 17, cd = 2, cost = 15 },
        { id = "silence", kind = "interrupt", tgt = "enemy", amt = 12, cd = 3, cost = 10 },
        { id = "rapid", kind = "buff", tgt = "self", amt = 40, dur = 2, cd = 5, cost = 0 },
    },
}

-- Class flavour: names + icons per ability id (falls back to the generic entry).
D.abilityNames = {
    _ = {
        sunder = { "Sunder Armor", "Ability_Warrior_Sunder" }, slam = { "Shield Slam", "INV_Shield_05" }, clap = { "Thunder Clap", "Spell_Nature_ThunderClap" },
        taunt = { "Taunt", "Spell_Nature_Reincarnation" }, wall = { "Shield Wall", "Ability_Warrior_ShieldWall" },
        flash = { "Flash Heal", "Spell_Holy_FlashHeal" }, hot = { "Renew", "Spell_Holy_Renew" },
        shield = { "Power Word: Shield", "Spell_Holy_PowerWordShield" }, nuke = { "Smite", "Spell_Holy_HolySmite" },
        strike = { "Sinister Strike", "Spell_Shadow_RitualOfSacrifice" }, finisher = { "Eviscerate", "Ability_Rogue_Eviscerate" },
        kick = { "Kick", "Ability_Kick" }, frenzy = { "Blade Flurry", "Ability_Warrior_PunishingBlow" },
        bolt = { "Frostbolt", "Spell_Frost_FrostBolt02" }, storm = { "Blizzard", "Spell_Frost_IceStorm" },
        counter = { "Counterspell", "Spell_Frost_IceShock" }, cc = { "Polymorph", "Spell_Nature_Polymorph" },
        shot = { "Steady Shot", "Ability_Hunter_SteadyShot" }, multi = { "Multi-Shot", "Ability_UpgradeMoonGlaive" },
        silence = { "Silencing Shot", "Ability_TheBlackArrow" }, rapid = { "Rapid Fire", "Ability_Hunter_RunningShot" },
        potion = { "Healing Potion", "INV_Potion_54" },
    },
    WARRIOR = {
        strike = { "Mortal Strike", "Ability_Warrior_SavageBlow" }, finisher = { "Execute", "INV_Sword_48" },
        kick = { "Pummel", "INV_Gauntlets_04" }, frenzy = { "Death Wish", "Spell_Shadow_DeathPact" },
    },
    PALADIN = {
        sunder = { "Avenger's Shield", "Spell_Holy_AvengersShield" }, slam = { "Holy Shield", "Spell_Holy_BlessingOfProtection" }, clap = { "Consecration", "Spell_Holy_InnerFire" },
        taunt = { "Righteous Defense", "INV_Shoulder_37" }, wall = { "Divine Protection", "Spell_Holy_Restoration" },
        flash = { "Flash of Light", "Spell_Holy_FlashHeal" }, hot = { "Holy Light", "Spell_Holy_HolyBolt" },
        shield = { "Blessing of Protection", "Spell_Holy_SealOfProtection" }, nuke = { "Holy Shock", "Spell_Holy_SearingLight" },
        strike = { "Crusader Strike", "Spell_Holy_CrusaderStrike" }, finisher = { "Judgement", "Spell_Holy_RighteousFury" },
        kick = { "Hammer of Justice", "Spell_Holy_SealOfMight" }, frenzy = { "Avenging Wrath", "Spell_Holy_AvengineWrath" },
    },
    PRIEST = {
        bolt = { "Mind Blast", "Spell_Shadow_UnholyFrenzy" }, storm = { "Mind Sear", "Spell_Shadow_MindShear" },
        counter = { "Silence", "Spell_Shadow_ImpPhaseShift" }, cc = { "Psychic Scream", "Spell_Shadow_PsychicScream" },
    },
    SHAMAN = {
        flash = { "Lesser Healing Wave", "Spell_Nature_HealingWaveLesser" }, hot = { "Chain Heal", "Spell_Nature_HealingWaveGreater" },
        shield = { "Earth Shield", "Spell_Nature_SkinofEarth" }, nuke = { "Lightning Bolt", "Spell_Nature_Lightning" },
        bolt = { "Lightning Bolt", "Spell_Nature_Lightning" }, storm = { "Chain Lightning", "Spell_Nature_ChainLightning" },
        counter = { "Earth Shock", "Spell_Nature_EarthShock" }, cc = { "Frost Shock", "Spell_Frost_FrostShock" },
        strike = { "Stormstrike", "Ability_Shaman_Stormstrike" }, finisher = { "Earth Shock", "Spell_Nature_EarthShock" },
        kick = { "Earth Shock", "Spell_Nature_EarthShock" }, frenzy = { "Bloodlust", "Spell_Nature_BloodLust" },
    },
    MAGE = {},
    WARLOCK = {
        bolt = { "Shadow Bolt", "Spell_Shadow_ShadowBolt" }, storm = { "Rain of Fire", "Spell_Shadow_RainOfFire" },
        counter = { "Spell Lock", "Spell_Shadow_MindRot" }, cc = { "Fear", "Spell_Shadow_Possession" },
    },
    DRUID = {
        sunder = { "Maul", "Ability_Druid_Maul" }, slam = { "Maul", "Ability_Druid_Maul" }, clap = { "Swipe", "INV_Misc_MonsterClaw_03" },
        taunt = { "Growl", "Ability_Physical_Taunt" }, wall = { "Barkskin", "Spell_Nature_StoneClawTotem" },
        flash = { "Regrowth", "Spell_Nature_ResistNature" }, hot = { "Rejuvenation", "Spell_Nature_Rejuvenation" },
        shield = { "Lifebloom", "INV_Misc_Herb_Felblossom" }, nuke = { "Wrath", "Spell_Nature_AbolishMagic" },
        strike = { "Shred", "Spell_Shadow_VampiricAura" }, finisher = { "Ferocious Bite", "Ability_Druid_FerociousBite" },
        kick = { "Bash", "Ability_Druid_Bash" }, frenzy = { "Tiger's Fury", "Ability_Mount_JungleTiger" },
        bolt = { "Starfire", "Spell_Arcane_StarFire" }, storm = { "Hurricane", "Spell_Nature_Cyclone" },
        counter = { "Bash", "Ability_Druid_Bash" }, cc = { "Entangling Roots", "Spell_Nature_StrangleVines" },
    },
    ROGUE = {},
    HUNTER = {},
}

for _, kit in pairs(D.kits) do kit[D.ABILITIES] = D.POTION end

function D.AbilityLabel(class, id)
    local over = D.abilityNames[class] and D.abilityNames[class][id]
    local base = over or D.abilityNames._[id] or { id, "INV_Misc_QuestionMark" }
    return base[1], "Interface\\Icons\\" .. base[2]
end

-- Base hero stats at 100% power by role.
D.roleStats = {
    tank = { hp = 520 }, healer = { hp = 300 }, melee = { hp = 340 }, caster = { hp = 330 }, ranged = { hp = 320 },
}

function D.PowerFromItemLevel(ilvl)
    ilvl = tonumber(ilvl) or 0
    local p = math.floor(100 + (ilvl - 100) * 2)
    return math.max(D.POWER_MIN, math.min(D.POWER_MAX, p))
end

---------------------------------------------------------------------------
-- Enemies. display = creature display IDs, verified against Wowhead's TBC model viewer data (npc -> displayId):
-- Kobold Tunneler 475 -> 139, Defias Henchman 594 -> 2323, Defias Miner 598 -> 308, Defias Evoker 1729 -> 2318,
-- Goblin Engineer 622 -> 7109, Murloc Oracle 517 -> 1079, Murloc Raider 515 -> 441, Defias Blackguard 636 -> 2314,
-- Rhahk'Zor 644 -> 14403, Sneed's Shredder 642 -> 1269, Mr. Smite 646 -> 2026, Edwin VanCleef 639 -> 2029.
-- dmg = its basic attack per round. abilities: { kind, cd (rounds), amt, name, [telegraph], [interruptible], [dur], [at] }
--   telegraph: announced one round ahead (its intent), resolves at the end of the next round unless interrupted
--   slam: big hit on its target   aoe: whole party   bolt: one hero   mend: heals the most hurt ally
--   stun: stuns the party (dur rounds)   enrage: +50% damage (below `at` %)   summon: calls `adds` (below `at` %)
---------------------------------------------------------------------------

D.enemies = {
    { id = "kobold", name = "Kobold Tunneler", hp = 150, dmg = 11, display = { 139 }, icon = "INV_Misc_Head_Kobold_01" },
    { id = "cutpurse", name = "Defias Henchman", hp = 180, dmg = 13, display = { 2323 }, icon = "INV_Misc_Bandana_03" },
    { id = "miner", name = "Defias Miner", hp = 230, dmg = 15, display = { 308 }, icon = "INV_Pick_02" },
    { id = "evoker", name = "Defias Evoker", hp = 160, dmg = 8, display = { 2318 }, icon = "Spell_Fire_FlameBolt",
      abilities = { { kind = "bolt", cd = 3, amt = 42, telegraph = true, interruptible = true, name = "Fireball" } } },
    { id = "engineer", name = "Goblin Engineer", hp = 190, dmg = 9, display = { 7109 }, icon = "INV_Misc_Bomb_08",
      abilities = { { kind = "aoe", cd = 4, amt = 24, telegraph = true, interruptible = true, name = "Throw Dynamite" } } },
    { id = "oracle", name = "Murloc Oracle", hp = 140, dmg = 8, display = { 1079 }, icon = "INV_Misc_Fish_05",
      abilities = { { kind = "mend", cd = 3, amt = 60, telegraph = true, interruptible = true, name = "Healing Wave" } } },
    { id = "murloc", name = "Murloc Raider", hp = 130, dmg = 13, display = { 441 }, icon = "INV_Misc_Fish_02" },
    { id = "blackguard", name = "Defias Blackguard", hp = 240, dmg = 17, display = { 2314 }, icon = "Ability_Stealth" },
    -- bosses
    { id = "rhahkzor", name = "Rhahk'Zor", boss = true, hp = 1200, dmg = 24, display = { 14403 }, icon = "INV_Hammer_16",
      abilities = { { kind = "slam", cd = 3, amt = 80, telegraph = true, name = "Rhahk'Zor Slam" } } },
    { id = "shredder", name = "Sneed's Shredder", boss = true, hp = 1400, dmg = 22, display = { 1269 }, icon = "INV_Misc_Gear_03",
      abilities = { { kind = "aoe", cd = 4, amt = 34, telegraph = true, name = "Whirling Blades" },
                    { kind = "summon", at = 40, adds = { "engineer" }, name = "Sneed ejects!" } } },
    { id = "smite", name = "Mr. Smite", boss = true, hp = 1600, dmg = 26, display = { 2026 }, icon = "INV_Axe_09",
      abilities = { { kind = "stun", cd = 5, dur = 1, telegraph = true, name = "Smite Stomp" },
                    { kind = "enrage", at = 35, name = "Smite's Hammer" } } },
    { id = "vancleef", name = "Edwin VanCleef", boss = true, hp = 2200, dmg = 28, display = { 2029 }, icon = "INV_Sword_33",
      abilities = { { kind = "aoe", cd = 3, amt = 32, telegraph = true, name = "Cleave" },
                    { kind = "summon", at = 50, adds = { "blackguard", "blackguard" }, name = "Call Blackguards" },
                    { kind = "enrage", at = 25, name = "Frenzy" } } },
}
D.enemyIndex = {}
for i, e in ipairs(D.enemies) do
    D.enemyIndex[e.id] = i
    e.icon = "Interface\\Icons\\" .. e.icon
end

---------------------------------------------------------------------------
-- The dungeon: rooms by depth. Each step the party votes between two generated rooms.
---------------------------------------------------------------------------

D.dungeons = {
    { id = "deadmines", name = "The Deadmines", rep = 0,
      packs = { { "kobold", "kobold", "kobold" }, { "cutpurse", "miner" }, { "miner", "evoker" },
                { "cutpurse", "cutpurse", "evoker" }, { "engineer", "miner", "miner" }, { "murloc", "murloc", "oracle" },
                { "blackguard", "evoker", "cutpurse" } },
      elites = { "rhahkzor", "shredder", "smite" },
      boss = "vancleef",
      depth = 7,                 -- rooms before the boss
      bg = { 0.12, 0.1, 0.08 } },
}

-- Room kinds offered on the path vote.
D.rooms = {
    fight    = { name = "Mine Tunnels", desc = "A pack of enemies. Loot afterwards.", icon = "INV_Pick_02" },
    elite    = { name = "Foreman's Den", desc = "A dangerous boss guards better loot.", icon = "INV_Misc_Head_Dragon_01" },
    treasure = { name = "Hidden Cache", desc = "Loot without a fight... probably.", icon = "INV_Box_02" },
    shrine   = { name = "Light's Shrine", desc = "A blessing for the whole party.", icon = "Spell_Holy_HolyGuidance" },
    rest     = { name = "Campfire", desc = "Heal to full and revive the fallen.", icon = "Spell_Fire_Fire" },
    boss     = { name = "The Juggernaut", desc = "Edwin VanCleef awaits.", icon = "INV_Sword_33" },
}

-- Enemy hp / damage scaling: party size and depth.
function D.PartyHpPct(n) return 55 + 45 * n end
function D.PartyDmgPct(n) return 40 + 12 * n end           -- solo 52% .. five players 100%
function D.MaxPack(n) return n == 1 and 2 or (n == 2 and 3 or 4) end
function D.DepthPct(depth) return 100 + 10 * depth end

---------------------------------------------------------------------------
-- Loot (in-run): pick 1 of 3 after a fight. Stacking modifiers.
--   dmg / heal / hp: +%   haste: -% cooldowns & cast time   crit: +% chance   regen: +resource regen
--   leech: % of damage healed   thorns: damage back to attackers   dr: -% damage taken
---------------------------------------------------------------------------

D.loot = {
    { id = "smiteHammer", name = "Smite's Mighty Hammer", icon = "INV_Hammer_05", dmg = 15 },
    { id = "cookieKnife", name = "Cookie's Tenderizer", icon = "INV_Mace_12", leech = 8 },
    { id = "vancleefBlade", name = "Cruel Barb", icon = "INV_Sword_22", crit = 8 },
    { id = "shredderShield", name = "Shredder Operating Gloves", icon = "INV_Gauntlets_27", haste = 10 },
    { id = "goldthorn", name = "Blackened Defias Armor", icon = "INV_Chest_Leather_03", hp = 15, dr = 5 },
    { id = "silkcloak", name = "Cape of the Brotherhood", icon = "INV_Misc_Cape_10", hp = 10, crit = 4 },
    { id = "manastone", name = "Mana Agate", icon = "INV_Misc_Gem_Emerald_01", regen = 1 },
    { id = "holywater", name = "Light-Blessed Charm", icon = "INV_Jewelry_Talisman_07", heal = 15 },
    { id = "spikes", name = "Thornmantle's Shoulders", icon = "INV_Shoulder_14", thorns = 6, dr = 3 },
    { id = "lantern", name = "Miner's Lantern", icon = "INV_Misc_Lantern_01", dmg = 8, heal = 8 },
    { id = "cannonball", name = "Cannonball Runner", icon = "INV_Ammo_Bullet_01", dmg = 10, haste = 5 },
    { id = "bandana", name = "Defias Bandana", icon = "INV_Misc_Bandana_03", crit = 5, dmg = 5 },
}
for _, l in ipairs(D.loot) do l.icon = "Interface\\Icons\\" .. l.icon end

-- Shrine blessings (party-wide, whole run).
D.blessings = {
    { id = "kings", name = "Blessing of Kings", icon = "Spell_Magic_GreaterBlessingofKings", hp = 10, dmg = 5, heal = 5 },
    { id = "might", name = "Battle Shout", icon = "Ability_Warrior_BattleShout", dmg = 12 },
    { id = "wisdom", name = "Blessing of Wisdom", icon = "Spell_Holy_SealOfWisdom", regen = 1 },
    { id = "fort", name = "Power Word: Fortitude", icon = "Spell_Holy_WordFortitude", hp = 20 },
}
for _, b in ipairs(D.blessings) do b.icon = "Interface\\Icons\\" .. b.icon end

-- Talents on level-up (per role, 3 offered, max 3 ranks each).
D.XP_PER_ROOM = 1
function D.XpForLevel(level) return 1 + math.floor(level / 2) end
D.talents = {
    tank = { { "Shield Mastery", "INV_Shield_06", { hp = 12 } }, { "Improved Taunt", "Spell_Nature_Reincarnation", { haste = 8 } },
             { "Defiance", "Ability_Warrior_InnerRage", { dmg = 12 } }, { "Toughness", "Spell_Holy_Devotion", { dr = 6 } } },
    healer = { { "Spiritual Healing", "Spell_Nature_MoonGlow", { heal = 12 } }, { "Meditation", "Spell_Nature_Sleep", { regen = 1 } },
               { "Divine Fury", "Spell_Holy_SealOfWrath", { haste = 8 } }, { "Holy Specialization", "Spell_Holy_HolyBolt", { crit = 6 } } },
    melee = { { "Precision", "Ability_Marksmanship", { crit = 6 } }, { "Flurry", "Ability_GhoulFrenzy", { haste = 8 } },
              { "Weapon Mastery", "Ability_Warrior_WeaponMastery", { dmg = 12 } }, { "Bloodthirst", "Spell_Nature_BloodLust", { leech = 6 } } },
    caster = { { "Arcane Power", "Spell_Nature_Lightning", { dmg = 12 } }, { "Presence of Mind", "Spell_Nature_EnchantArmor", { haste = 8 } },
               { "Critical Mass", "Spell_Fire_Incinerate", { crit = 6 } }, { "Arcane Meditation", "Spell_Shadow_ManaBurn", { regen = 1 } } },
    ranged = { { "Trueshot Aura", "Ability_TrueShot", { dmg = 12 } }, { "Rapid Killing", "Ability_Hunter_RapidKilling", { haste = 8 } },
               { "Mortal Shots", "Ability_PierceDamage", { crit = 6 } }, { "Endurance Training", "Spell_Nature_Reincarnation", { hp = 12 } } },
}
D.TALENT_MAX = 3

---------------------------------------------------------------------------
-- Meta: reputation (Brotherhood of Stormwind masons... er, "Westfall Brigade") and achievements
---------------------------------------------------------------------------

D.REP_TIERS = {
    { name = "Neutral", at = 0 }, { name = "Friendly", at = 300 }, { name = "Honored", at = 1200 },
    { name = "Revered", at = 3000 }, { name = "Exalted", at = 6000 },
}
function D.RepTier(points)
    local tier = 0
    for i, t in ipairs(D.REP_TIERS) do if (points or 0) >= t.at then tier = i - 1 end end
    return tier
end
function D.RepForRun(rooms, won, players)
    return rooms * 25 + (won and 150 or 0) + (players > 1 and 25 or 0)
end

-- Heroic (Honored+): enemies +40% hp / +25% damage, more rep.
D.HEROIC = { rep = 2, hp = 140, dmg = 125, repMult = 2 }

D.achievements = {
    { id = "first", name = "Into the Mines", desc = "Finish a room in the Deadmines." },
    { id = "rhahk", name = "Rhahk'Zor Is Down", desc = "Defeat Rhahk'Zor." },
    { id = "smite", name = "Smited", desc = "Defeat Mr. Smite." },
    { id = "vancleef", name = "The Brotherhood Falls", desc = "Defeat Edwin VanCleef." },
    { id = "heroic", name = "Heroic: Deadmines", desc = "Defeat Edwin VanCleef on Heroic." },
    { id = "party5", name = "Full Group", desc = "Defeat VanCleef with 5 players." },
    { id = "solo", name = "Lone Wolf", desc = "Defeat VanCleef alone." },
    { id = "nodeath", name = "Flawless", desc = "Defeat VanCleef without anyone dying in that fight." },
    { id = "interrupt", name = "Kick Master", desc = "Interrupt 10 enemy casts in one run." },
    { id = "exalted", name = "Hero of Westfall", desc = "Reach Exalted with the Westfall Brigade." },
}

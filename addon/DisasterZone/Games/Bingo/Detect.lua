if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/Detect.lua", ...) then return end -- DisasterZone Games/Bingo/Detect.lua
-- ns.BingoDetect: turns raid events into Council Bingo squares. Runs only on the host of an active game
-- (one detector = one truth, no range differences between clients); everyone else gets the hits via sync.
-- Raid events only: combat log, encounters, /roll lines, ready checks, raid chat, disconnects, boss emotes.
-- Never loot / council.
-- Two layers: the core squares (hand-written below, dealt everywhere) and each raid's pool, a data-driven rule table
-- (RULES) that only runs while the host stands inside that raid. COMBAT_LOG_EVENT_UNFILTERED is hot in a raid, so
-- each event costs a dispatch-table lookup plus a couple of name / id lookups; nothing allocates unless a rule
-- matched (and the one small per-raider "last hit" record, made once per raider).
local addonName, ns = ...

local Detect = ns:NewModule("BingoDetect")
local Util = ns.Util

local band = bit and bit.band
local GetTime = GetTime

local AFFIL_GROUP = (COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1) + (COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2)
    + (COMBATLOG_OBJECT_AFFILIATION_RAID or 0x4)
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x400
local TYPE_PET = (COMBATLOG_OBJECT_TYPE_PET or 0x1000) + (COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x2000)

local BIG_CRIT, BIG_OVERKILL = 8000, 5000
local MASS_DEATH_COUNT, MASS_DEATH_WINDOW = 3, 5
local EARLY_DEATH, LATE_DEATH = 30, 10
local SPEED_KILL, LONG_FIGHT, INSTANT_WIPE = 120, 360, 20
local CLUTCH_ALIVE, BIG_GROUP = 5, 10    -- clutch / last_one / no_wipe count in groups of BIG_GROUP or more
local FALL_DEATH_WINDOW = 2         -- a death this soon after fall damage is a fall death
local BUBBLE_HEARTH_WINDOW = 20     -- bubble (12s) + hearth cast (10s)
local FEIGN_WIPE_WINDOW = 20
local READY_CHECK_MAX = 40          -- a check we never saw finish is over after this
local IDLE_SECONDS = 15 * 60
local KILL_WINDOW = 5               -- the last hit this soon before a death is the killing blow
local ONE_SHOT_SHARE = 0.95         -- a killing hit that took this share of max health or more: one_shot
local AURA_GRACE = 3                -- "died while having aura X": the aura may have dropped this long before
local PHOENIX_COUNT, REZ_DEDUPE = 3, 10
local BLIZZARD_COUNT, BLIZZARD_WINDOW = 5, 10
local TICK = 2

-- Group players' casts, matched by id or by exact (English) name so other ranks and item variants count too.
-- LIKE: plain substrings for whole families (any drums, any healthstone; "Create ..." conjures, not eats).
local CAST_GROUPS = {
    lust   = { ids = { 2825, 32182 }, names = { "Bloodlust", "Heroism" } },
    bubble = { ids = { 642, 1020, 498, 5573 }, names = { "Divine Shield", "Divine Protection" } },
    hearth = { ids = { 8690 }, names = { "Hearthstone" } },
    ankh   = { ids = { 20608, 21169 }, names = { "Reincarnation" } },
    feign  = { ids = { 5384 }, names = { "Feign Death" } },
    drums  = { ids = { 35474, 35475, 35476, 35477, 35478 } },
    loh    = { ids = { 633, 2800, 10310, 27154 }, names = { "Lay on Hands" } },
    stone  = { ids = { 27235, 27236, 27237 } },
    di     = { ids = { 19752 }, names = { "Divine Intervention" } },
}
local LIKE = {
    { find = "Drums of ", kind = "drums" },
    { find = "Healthstone", kind = "stone", skip = "Create" },
}
local TAUNTS = { 355, 6795, 31789, 31790, 694, 7400, 7402, 20559, 20560, 25266, 1161, 5209,
    "Taunt", "Growl", "Righteous Defense", "Mocking Blow", "Challenging Shout", "Challenging Roar" }

local CAST_KIND, TAUNT = {}, {}
for kind, g in pairs(CAST_GROUPS) do
    for _, id in ipairs(g.ids or {}) do CAST_KIND[id] = kind end
    for _, n in ipairs(g.names or {}) do CAST_KIND[n] = kind end
end
for _, k in ipairs(TAUNTS) do TAUNT[k] = true end

local function CastKind(spellId, spellName)
    local kind = CAST_KIND[spellId] or CAST_KIND[spellName]
    if kind or type(spellName) ~= "string" then return kind end
    for i = 1, #LIKE do
        local l = LIKE[i]
        if spellName:find(l.find, 1, true) and not (l.skip and spellName:find(l.skip, 1, true)) then return l.kind end
    end
    return nil
end

-- beat_clock: a boss's hard enrage. Verified on Wowhead TBC: Berserk 26662 (Void Reaver, Al'ar), 27680 (Leotheras,
-- Karathress), 35595 (Terestian Illhoof). Moroes' "Enrage" 37023 is his 30% soft enrage: never counts.
local ENRAGE = { Berserk = true, Enrage = true }
local ENRAGE_SKIP = { [37023] = true }

local TAUNT_MISS = { RESIST = true, MISS = true }

---------------------------------------------------------------------------
-- Raid pools: one rule table per raid (plan key)
---------------------------------------------------------------------------
-- A rule: { squareId, kind, ... }; it runs in the raid of its square (ns.BingoSquares, the square's raid). Kinds:
--   dmg       a group player takes damage from spell (any hit; SWING has no spell)      who = the raider hit
--   aura      aura applied to a group player, not by a raider (anySrc = by anyone)       who = the raider
--   cast      SPELL_CAST_SUCCESS by a unit outside the group                             who = the caster
--   summon    SPELL_SUMMON by a unit outside the group                                   who = the caster
--   stacks    SPELL_AURA_APPLIED_DOSE on a unit outside the group reaches `stacks`       who = that unit
--   death     a group player dies; matched on the killing blow (the last damage taken in the KILL_WINDOW
--             seconds before: spell, source npc, or env = "FALLING") and/or aura = held when they died (or
--             dropped up to `within` seconds before, AURA_GRACE by default)              who = the raider
--   npcdeath  a unit outside the group named npc dies                                    who = that unit
--   emote     CHAT_MSG_RAID_BOSS_EMOTE contains phrase (lowercase); capture = pattern for the raider's name
--   atkill    an encounter in enc ends in a kill and its per-fight tally is <= max / >= min   who = the boss
-- Filters: spell = names, ids = spell ids (either matches), npc = source names (the aura holder for stacks, the
--   dead unit for npcdeath), enc = encounter ids / names the fight must be.
-- Counting: n = fire on the n-th match (distinct raiders for dmg / death) within `window` seconds, or within
--   the current boss fight with fight = true; since = only in the first `since` seconds of a fight;
--   gap = count a match at most once per `gap` seconds; tally = also add 1 to the fight's counter of that name.
--
-- Verified on Wowhead TBC (2026-10-12, npc ability lists / spell pages; ids only where the npc's list has them):
--   Karazhan: Nightbane 17225 Charred Earth 30129 | Terestian Illhoof 15688 Sacrifice 30115, Berserk 35595 |
--     Echo of Medivh 16816, Hand of Medivh 39339, Fury of Medivh 39343 39345 39383 | Moroes 15687 guests:
--     Baroness Dorothea Millstipe 19875, Lady Catriona Von'Indi 19872, Lady Keira Berrybuck 17007, Baron Rafe
--     Dreuger 19874, Lord Robin Daris 19876, Lord Crispin Ference 19873 | Maiden of Virtue 16457 Holy Fire 29522,
--     Holy Wrath 32445 (spell exists; not in her list) | Opera: Cyclone 29538 "knocks the player up" (the Crone's
--     cyclone; the npc name isn't on Wowhead TBC, so no npc filter) | Shade of Aran 16524 Flame Wreath 29946
--     (the ring) 29947 / 30004, Pyroblast 29978 | Netherspite Infernal 17646 Hellfire 30859 | The Curator 15691,
--     Hateful Bolt 30383 | The Big Bad Wolf 17521 Red Riding Hood 30753 (the mark), Little Red Riding Hood
--     30756 30768 (the costume) | Julianne 17534 Undying Love 30951 ("restores all health"), Romulo 17533 |
--     Prince Malchezaar 15690 Enfeeble 30843, Shadow Nova 30852.
--   Gruul's Lair: High King Maulgar 18831 Whirlwind 33238 33239, Arcing Smash 28168 39144 | Kiggler the Crazed
--     18835 Greater Polymorph 33173 | Blindeye the Seer 18836 Prayer of Healing 33152 | Krosh Firehand 18832 Blast
--     Wave 33061 | Gruul the Dragonkiller 19044 Shatter 33654 (cast) 33671 (damage), Cave In 36240, Growth 36300,
--     Hurtful Strike 33813 (spell exists; not in his list).
--   Magtheridon's Lair: Magtheridon 17257 Quake 30576 30657 (+ 30571 30572 30658), Blast Nova 30616 (a 2 s cast
--     then a 10 s channel: its cast success comes even when the cubes stop it) / 30613 (the blast itself),
--     Cleave 30619, Debris 36449 (+ 30631 30632) | Hellfire Channeler 17256 Burning Abyssal 30511, Dark Mending
--     30528 | Burning Abyssal 17454 (no abilities listed: Fire Blast by name).
--   Serpentshrine Cavern: Morogrim Tidewalker 21213 Watery Grave 37850 38023 38024 38025 38028 | The Lurker Below
--     21217 Geyser 37478 (Spout by name: 8 spells share it) | Toxic Sporebat 22140 (Toxic Spores by name) |
--     Coilfang Frenzy 21508 | Hydross the Unstable 21216 Mark of Hydross 38215..38218 38231 (250%) 40584 (500%),
--     Mark of Corruption 38219..38222 38230 (250%) 40583 | Tidewalker Lurker 21920 | Lady Vashj 21212 Static
--     Charge 38280 | Leotheras the Blind 21215 Whirlwind 37640 37641, Consuming Madness 37749, Berserk 27680 |
--     Fathom-Guard Tidalvess 21965 summons Spitfire Totem 38236 -> npc Spitfire Totem 22091.
--   Tempest Keep: Void Reaver 19516 Arcane Orb 34172, Knock Away 25778 | Lord Sanguinar 20060 Bellowing Roar
--     44863 | Thaladred the Darkener 20064: no gaze spell; the emote "sets eyes on <name>!" (TBC 2.4.3 DBM) |
--     Al'ar 19514 Rebirth 34342 35369 (Flame Patch, Dive Bomb by name) | High Astromancer Solarian 18805 Wrath of
--     the Astromancer 33040 42783 | Kael'thas Sunstrider 19622 Mind Control 36797, Pyroblast 36819, Gravity
--     Lapse 35941 (the players' auras share the name; Flamestrike isn't in his list: by name, in his fight).
-- Encounter ids (Data/Items.lua): Opera 655, Magtheridon 651, Morogrim 627, Kael'thas 733.
local MOROES_GUESTS = { "Baroness Dorothea Millstipe", "Lady Catriona Von'Indi", "Lady Keira Berrybuck",
    "Baron Rafe Dreuger", "Lord Robin Daris", "Lord Crispin Ference" }
local RED_HOOD = { "Little Red Riding Hood", "Red Riding Hood" }
local SHATTER, SHATTER_IDS = { "Shatter" }, { 33671, 33654 }
local MAG = { 651, "Magtheridon" }
local KAEL = { 733, "Kael'thas Sunstrider" }

local RULES = {
    -- Karazhan
    { "kara_charred", "dmg", spell = { "Charred Earth" }, ids = { 30129 } },
    { "kara_sacrifice", "aura", spell = { "Sacrifice" }, ids = { 30115 } },
    { "kara_medivh", "cast", spell = { "Hand of Medivh", "Fury of Medivh" }, ids = { 39339, 39343, 39345, 39383 } },
    { "kara_dinner", "death", npc = MOROES_GUESTS },
    { "kara_repent", "death", spell = { "Holy Fire", "Holy Wrath" }, ids = { 29522, 32445 },
      npc = { "Maiden of Virtue" } },
    { "kara_cyclone", "aura", spell = { "Cyclone" }, ids = { 29538 } },
    { "kara_wreath", "dmg", spell = { "Flame Wreath" } },
    { "kara_infernal", "dmg", spell = { "Hellfire" }, ids = { 30859 }, npc = { "Netherspite Infernal" } },
    { "kara_hateful", "death", spell = { "Hateful Bolt" }, ids = { 30383 } },
    { "kara_teeth", "death", aura = RED_HOOD },
    { "kara_drink", "death", spell = { "Pyroblast" }, ids = { 29978 }, npc = { "Shade of Aran" } },
    -- the first Undying Love is the scripted revive that starts phase 3: the second one is a real save
    { "kara_undying", "cast", spell = { "Undying Love" }, ids = { 30951 }, npc = { "Julianne", "Romulo" },
      n = 2, fight = true },
    { "kara_enfeebled", "death", spell = { "Shadow Nova" }, ids = { 30852 }, aura = { "Enfeeble" } },
    { "kara_wolfpack", "death", aura = RED_HOOD, n = 3, fight = true },
    -- Gruul's Lair
    { "gruul_shatter", "death", spell = SHATTER, ids = SHATTER_IDS },
    { "gruul_hug", "death", spell = SHATTER, ids = SHATTER_IDS, n = 3, window = 3 },
    { "gruul_rockbottom", "death", spell = SHATTER, ids = SHATTER_IDS, n = 5, window = 3 },
    { "gruul_cavein", "dmg", spell = { "Cave In" }, ids = { 36240 } },
    { "gruul_whirl", "dmg", spell = { "Whirlwind" }, ids = { 33238, 33239 }, npc = { "High King Maulgar" },
      n = 3, window = 2 },
    { "gruul_sheep", "aura", spell = { "Greater Polymorph" }, ids = { 33173 }, npc = { "Kiggler the Crazed" } },
    { "gruul_prayer", "cast", spell = { "Prayer of Healing" }, ids = { 33152 }, npc = { "Blindeye the Seer" } },
    { "gruul_hurtful", "death", spell = { "Hurtful Strike" }, ids = { 33813 } },
    { "gruul_blastwave", "death", spell = { "Blast Wave" }, ids = { 33061 }, npc = { "Krosh Firehand" } },
    { "gruul_smash", "death", spell = { "Arcing Smash" }, ids = { 28168, 39144 }, npc = { "High King Maulgar" } },
    { "gruul_growth", "stacks", spell = { "Growth" }, ids = { 36300 }, npc = { "Gruul the Dragonkiller" },
      stacks = 15 },
    -- Magtheridon's Lair
    { "mag_debris", "dmg", spell = { "Debris" }, ids = { 36449, 30631, 30632 } },
    { "mag_quake", "cast", spell = { "Quake" }, ids = { 30576, 30657 }, npc = { "Magtheridon" } },
    { "mag_quake", "aura", spell = { "Quake" }, ids = { 30576, 30657 } },
    { "mag_quake", "dmg", spell = { "Quake" }, ids = { 30571, 30572, 30658 } },
    { "mag_abyssal", "cast", spell = { "Burning Abyssal" }, ids = { 30511 }, npc = { "Hellfire Channeler" } },
    { "mag_abyssal", "summon", spell = { "Burning Abyssal" }, ids = { 30511 } },
    { "mag_mending", "cast", spell = { "Dark Mending" }, ids = { 30528 }, npc = { "Hellfire Channeler" } },
    { "mag_fireblast", "death", spell = { "Fire Blast" }, npc = { "Burning Abyssal" } },
    { "mag_cleave", "death", spell = { "Cleave" }, ids = { 30619 }, npc = { "Magtheridon" } },
    -- went off = the blast hit someone (the cast success also comes for a nova the cubes stop)
    { "mag_nova", "dmg", spell = { "Blast Nova" }, ids = { 30613, 30616 }, gap = 20, tally = "nova" },
    { "mag_fivedown", "npcdeath", npc = { "Hellfire Channeler" }, n = 5, fight = true, since = 120 },
    { "mag_cubes", "atkill", enc = MAG, tally = "nova", max = 0 },
    { "mag_novaparty", "atkill", enc = MAG, tally = "nova", min = 3 },
    -- Serpentshrine Cavern
    { "ssc_grave", "aura", spell = { "Watery Grave" }, ids = { 37850, 38023, 38024, 38025, 38028 } },
    { "ssc_geyser", "dmg", spell = { "Geyser" }, ids = { 37478 } },
    { "ssc_spores", "dmg", spell = { "Toxic Spores" } },
    { "ssc_piranha", "death", npc = { "Coilfang Frenzy" } },
    { "ssc_marked", "aura", ids = { 38231, 38230 } },      -- the 250% marks: the 5th of one kind
    { "ssc_murloc", "death", npc = { "Tidewalker Lurker" } },
    { "ssc_tsunami", "death", npc = { "Tidewalker Lurker" }, n = 3, fight = true },
    { "ssc_static", "dmg", spell = { "Static Charge" }, ids = { 38280 }, n = 3, window = 1.5 },
    { "ssc_spout", "death", spell = { "Spout" } },
    { "ssc_spoutdoom", "death", spell = { "Spout" }, n = 5, window = 20 },
    { "ssc_whirl", "death", spell = { "Whirlwind" }, ids = { 37640, 37641 }, npc = { "Leotheras the Blind" } },
    { "ssc_demon", "aura", spell = { "Consuming Madness" }, ids = { 37749 }, anySrc = true },
    { "ssc_totem", "death", npc = { "Spitfire Totem" } },
    -- Tempest Keep
    { "tk_orb", "dmg", spell = { "Arcane Orb" }, ids = { 34172 } },
    { "tk_knock", "dmg", spell = { "Knock Away" }, ids = { 25778 }, npc = { "Void Reaver" } },
    { "tk_roar", "cast", spell = { "Bellowing Roar" }, ids = { 44863 }, npc = { "Lord Sanguinar" } },
    { "tk_gaze", "emote", phrase = "sets eyes on", capture = "sets eyes on ([^%s!%.]+)" },
    { "tk_patch", "death", spell = { "Flame Patch" } },
    { "tk_dive", "dmg", spell = { "Dive Bomb" }, n = 5, window = 2 },
    { "tk_wrath", "death", spell = { "Wrath of the Astromancer" }, ids = { 33040, 42783 } },
    { "tk_flamestrike", "death", spell = { "Flamestrike" }, enc = KAEL },
    { "tk_rebirth", "death", spell = { "Rebirth" }, ids = { 34342, 35369 }, npc = { "Al'ar" } },
    { "tk_mc", "aura", spell = { "Mind Control" }, ids = { 36797 }, npc = { "Kael'thas Sunstrider" } },
    { "tk_pyro", "death", spell = { "Pyroblast" }, ids = { 36819 }, npc = { "Kael'thas Sunstrider" } },
    { "tk_lapse", "death", env = "FALLING", aura = { "Gravity Lapse" }, within = 40 },
}
Detect.RULES = RULES

-- Unit tokens, made once (no string building per event).
local RAID_UNITS, PARTY_UNITS = {}, {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end
for i = 1, 4 do PARTY_UNITS[i] = "party" .. i end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

-- Per-game counters (reset on Start) and per-fight counters (reset on ENCOUNTER_START).
local game, fight
local lastHit, auras = {}, {}     -- [raider GUID] = the last damage taken / { [aura name] = applied (+) or -removed }
local raidKey, forcedRaid, R      -- the raid we stand in (plan key), a test override, its compiled rule index
local compiled = {}
local stamp = 0                   -- dedupes a rule listed under both its name and its id within one event

local function NewGame()
    return { deaths = 0, wipes = {}, fell = {}, bubbled = {}, lastAction = GetTime(), dcs = {}, counts = {},
             ruleLast = {}, seq = 0 }
end

game = NewGame()

-- A name without any realm (Util.ShortName), nil for no name (the square then shows nobody).
local function ShortName(name)
    return type(name) == "string" and Util.ShortName(name, true) or nil
end

-- who: the raider (or pet, or boss) that set the square off, shown on the card. Optional.
local function Hit(id, who) ns.Bingo:Hit(id, ShortName(who)) end

local function UnitShortName(unit)
    return ShortName(UnitName(unit))
end

local function Live()
    return ns.Bingo and ns.Bingo:IsActive() and ns.Bingo:IsHost()
end

local function IsGroup(flags, typeMask)
    if not band or type(flags) ~= "number" then return false end
    return band(flags, AFFIL_GROUP) ~= 0 and band(flags, typeMask) ~= 0
end

local function GroupUnits()
    local units = {}
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do units[#units + 1] = RAID_UNITS[i] end
    else
        units[1] = "player"
        for i = 1, n - 1 do units[#units + 1] = PARTY_UNITS[i] end
    end
    return units
end

-- The group unit token of a GUID, or nil.
local function UnitOfGUID(guid)
    if not guid then return nil end
    if IsInRaid() then
        for i = 1, math.min(GetNumGroupMembers() or 0, 40) do
            if UnitGUID(RAID_UNITS[i]) == guid then return RAID_UNITS[i] end
        end
        return nil
    end
    if UnitGUID("player") == guid then return "player" end
    for i = 1, 4 do
        if UnitGUID(PARTY_UNITS[i]) == guid then return PARTY_UNITS[i] end
    end
    return nil
end

-- Strips colour codes, links and {raid target} markers from a chat line.
local function Plain(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("{[^}]*}", "")
    return text
end

---------------------------------------------------------------------------
-- The raid we're in, and its compiled rules
---------------------------------------------------------------------------

local function SetOf(list)
    if not list then return nil end
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

local function Add(map, key, r)
    local l = map[key]
    if not l then l = {}; map[key] = l end
    l[#l + 1] = r
end

local function IndexRule(I, r)
    r.sq, r.kind = r[1], r[2]
    r.spellSet, r.idSet, r.npcSet, r.auraSet, r.encSet = SetOf(r.spell), SetOf(r.ids), SetOf(r.npc), SetOf(r.aura),
        SetOf(r.enc)
    local kind = r.kind
    if kind == "death" then
        if r.spellSet or r.idSet then
            for k in pairs(r.spellSet or {}) do Add(I.deathSpell, k, r) end
            for k in pairs(r.idSet or {}) do Add(I.deathSpell, k, r) end
        elseif r.npcSet then
            for k in pairs(r.npcSet) do Add(I.deathNpc, k, r) end
        elseif r.env then
            Add(I.deathEnv, r.env, r)
        else
            I.deathAura[#I.deathAura + 1] = r
        end
        for k in pairs(r.auraSet or {}) do I.track[k] = true end
    elseif kind == "npcdeath" then
        for k in pairs(r.npcSet) do Add(I.npcdeath, k, r) end
    elseif kind == "emote" or kind == "atkill" then
        I[kind][#I[kind] + 1] = r
    elseif I[kind] then
        for k in pairs(r.spellSet or {}) do Add(I[kind], k, r) end
        for k in pairs(r.idSet or {}) do Add(I[kind], k, r) end
    end
end

-- Index of a raid's rules (the rules whose square is in that raid's pool): per kind, [spell name] / [spell id] /
-- [npc name] = { rule, ... }; nil for a raid without rules.
local function Compile(key)
    local Squares, any = ns.BingoSquares, false
    local I = { dmg = {}, aura = {}, cast = {}, summon = {}, stacks = {}, npcdeath = {}, deathSpell = {},
                deathNpc = {}, deathEnv = {}, deathAura = {}, emote = {}, atkill = {}, track = {} }
    for _, r in ipairs(RULES) do
        local sq = Squares and Squares:Get(r[1])
        if sq and sq.raid == key then
            any = true
            IndexRule(I, r)
        end
    end
    return any and I or nil
end

-- The plan key of the raid instance the player stands in, or nil.
local function RaidHere()
    if not GetInstanceInfo or not ns.ItemDB or not ns.ItemDB.GetRaidByInstance then return nil end
    local instanceID = select(8, GetInstanceInfo())
    local itemKey = ns.ItemDB:GetRaidByInstance(tonumber(instanceID))
    return itemKey and ns.ItemDB:PlanKeyOf(itemKey) or nil
end

local function UseRaid(key)
    raidKey = key
    if key and compiled[key] == nil then compiled[key] = Compile(key) or false end
    R = key and compiled[key] or nil
end

-- Re-reads the instance (zone changes; Start). A test override (SetRaid) wins.
function Detect:RefreshRaid()
    UseRaid(forcedRaid or RaidHere())
end

-- Tests: pretend to stand in raid `key` (a plan key: "kara", "gruul", "mag", "ssc", "tk"); nil = the real instance.
function Detect:SetRaid(key)
    forcedRaid = key or nil
    self:RefreshRaid()
end

function Detect:GetRaid() return raidKey end

function Detect:Reset()
    game = NewGame()
    fight = nil
    lastHit, auras = {}, {}
    self:RefreshRaid()
end

---------------------------------------------------------------------------
-- Rule engine
---------------------------------------------------------------------------

-- How many matches of r are in its window / fight now, after adding one under key (a raider's GUID: distinct
-- raiders; nil: every match counts).
local function Count(r, key, now)
    local owner = r.fight and fight or game
    local st = owner.counts[r]
    if not st then st = {}; owner.counts[r] = st end
    if key == nil then
        owner.seq = owner.seq + 1
        key = owner.seq
    end
    st[key] = now
    local n, w = 0, r.window
    for k, t in pairs(st) do
        if not w or now - t <= w then n = n + 1 else st[k] = nil end
    end
    return n
end

local function Fire(r, who, key, now)
    if r.encSet and not (fight and (r.encSet[fight.id] or r.encSet[fight.name])) then return end
    if (r.fight or r.since) and not fight then return end
    if r.since and now - fight.start > r.since then return end
    if r.gap then
        local last = game.ruleLast[r]
        if last and now - last < r.gap then return end
        game.ruleLast[r] = now
    end
    if r.tally and fight then fight.tally[r.tally] = (fight.tally[r.tally] or 0) + 1 end
    if r.n and Count(r, key, now) < r.n then return end
    if r.sq then Hit(r.sq, who) end
end

-- srcGroup: the source is one of us (aura rules skip that unless anySrc); amount: an aura's stack count.
local function RunList(list, npcName, who, key, now, srcGroup, amount)
    for i = 1, #list do
        local r = list[i]
        if r.seen ~= stamp then
            r.seen = stamp
            if (not r.npcSet or r.npcSet[npcName]) and (not srcGroup or r.anySrc)
                and (not r.stacks or (tonumber(amount) or 0) >= r.stacks) then
                Fire(r, who, key, now)
            end
        end
    end
end

local function RunSpell(map, spellId, spellName, npcName, who, key, srcGroup, amount)
    local byName, byId = spellName ~= nil and map[spellName] or nil, spellId ~= nil and map[spellId] or nil
    if not byName and not byId then return end
    local now = GetTime()
    stamp = stamp + 1
    if byName then RunList(byName, npcName, who, key, now, srcGroup, amount) end
    if byId then RunList(byId, npcName, who, key, now, srcGroup, amount) end
end

-- Did the raider have one of these auras (on now, or dropped no more than `within` seconds ago)?
local function HadAura(guid, set, within, now)
    local held = auras[guid]
    if not held then return false end
    for name in pairs(set) do
        local v = held[name]
        if v and (v > 0 or now + v <= within) then return true end
    end
    return false
end

local function DeathOK(r, guid, lh, fresh, now)
    if (r.spellSet or r.idSet) and not (fresh and ((r.spellSet and r.spellSet[lh.spellName])
        or (r.idSet and r.idSet[lh.spellId]))) then return false end
    if r.npcSet and not (fresh and r.npcSet[lh.srcName]) then return false end
    if r.env and not (fresh and lh.env == r.env) then return false end
    if r.auraSet and not HadAura(guid, r.auraSet, r.within or AURA_GRACE, now) then return false end
    return true
end

local function RunDeath(list, guid, name, lh, fresh, now)
    if not list then return end
    for i = 1, #list do
        local r = list[i]
        if r.seen ~= stamp then
            r.seen = stamp
            if DeathOK(r, guid, lh, fresh, now) then Fire(r, name, guid, now) end
        end
    end
end

local function RaidDeath(guid, name, lh, fresh, now)
    stamp = stamp + 1
    if fresh then
        if lh.spellName then RunDeath(R.deathSpell[lh.spellName], guid, name, lh, fresh, now) end
        if lh.spellId then RunDeath(R.deathSpell[lh.spellId], guid, name, lh, fresh, now) end
        if lh.srcName then RunDeath(R.deathNpc[lh.srcName], guid, name, lh, fresh, now) end
        if lh.env then RunDeath(R.deathEnv[lh.env], guid, name, lh, fresh, now) end
    end
    RunDeath(R.deathAura, guid, name, lh, fresh, now)
end

-- The killing-blow candidate of a raider (one table per raider, reused).
local function NoteHit(guid, now, spellId, spellName, srcName, env)
    local lh = lastHit[guid]
    if not lh then lh = {}; lastHit[guid] = lh end
    lh.t, lh.spellId, lh.spellName, lh.srcName, lh.env, lh.full = now, spellId, spellName, srcName, env, false
    return lh
end

local function TrackAura(guid, name, value)
    local held = auras[guid]
    if not held then held = {}; auras[guid] = held end
    held[name] = value
end

local function Rezzed(guid, who, now)
    if not fight or not guid then return end
    local last = fight.rezzed[guid]
    if last and now - last < REZ_DEDUPE then return end
    fight.rezzed[guid] = now
    fight.rez = fight.rez + 1
    if fight.rez >= PHOENIX_COUNT then Hit("phoenix", who) end
end

---------------------------------------------------------------------------
-- Handlers (public so the test harness can drive them directly)
---------------------------------------------------------------------------

-- name: the dead raider's (or pet's) name, for the card.
function Detect:OnDeath(isPet, guid, name)
    if isPet then Hit("pet_death", name) return end
    local now = GetTime()
    game.deaths = game.deaths + 1
    if game.deaths >= 10 then Hit("ten_deaths", name) end
    local fell = guid and game.fell[guid]
    if fell and now - fell <= FALL_DEATH_WINDOW then Hit("fall_death", name) end
    local lh = guid and lastHit[guid]
    local fresh = lh and now - lh.t <= KILL_WINDOW or false
    if fresh and lh.full then Hit("one_shot", name) end
    if R and guid then RaidDeath(guid, name, lh, fresh, now) end
    if lh then lh.t = -math.huge end
    if guid then auras[guid] = nil end
    if not fight then
        Hit("death_trash", name)
        return
    end
    fight.deaths = fight.deaths + 1
    fight.lastDeath, fight.lastDeathName = now, name
    if guid then fight.died[guid] = true end
    if now - fight.start <= EARLY_DEATH then Hit("death_first", name) end
    local recent = fight.recent
    recent[#recent + 1] = now
    local n = 0
    for i = #recent, 1, -1 do
        if now - recent[i] <= MASS_DEATH_WINDOW then n = n + 1 else break end
    end
    if n >= MASS_DEATH_COUNT then Hit("mass_death", name) end
end

function Detect:OnEncounterStart(encounterID, encounterName)
    local now = GetTime()
    fight = { id = encounterID, name = encounterName, start = now, deaths = 0, interrupts = 0, recent = {}, died = {},
              rez = 0, rezzed = {}, tally = {}, counts = {}, seq = 0 }
    game.lastAction = now
    local rc = game.readyCheck
    if rc and now - rc.start <= READY_CHECK_MAX then Hit("rc_pull", encounterName) end
end

function Detect:OnEncounterEnd(encounterID, success, encounterName)
    local f = fight
    fight = nil
    local now = GetTime()
    game.lastAction = now
    local duration = f and (now - f.start) or 0
    local id = encounterID or 0
    local boss = encounterName or (f and f.name)
    if duration > LONG_FIGHT then Hit("long_fight", boss) end
    if success == 1 or success == true then
        if (game.wipes[id] or 0) >= 1 then Hit("redemption", boss) end
        if f and f.deaths == 0 then Hit("flawless", boss) end
        if f and duration < SPEED_KILL then Hit("speed_kill", boss) end
        if f and f.lastDeath and now - f.lastDeath <= LATE_DEATH then Hit("late_death", f.lastDeathName) end
        if f and f.enraged then Hit("beat_clock", boss) end
        local units, alive, dead = GroupUnits(), 0, 0
        for _, u in ipairs(units) do
            if UnitIsDeadOrGhost(u) then dead = dead + 1
            elseif UnitIsConnected(u) then alive = alive + 1 end
        end
        if #units >= BIG_GROUP then
            if alive <= CLUTCH_ALIVE then Hit("clutch", boss) end
            if alive == 1 then Hit("last_one", boss) end
            if dead * 2 > #units then Hit("no_wipe", boss) end
        end
        if R and f then
            for _, r in ipairs(R.atkill) do
                if r.encSet[f.id] or r.encSet[f.name] then
                    local v = f.tally[r.tally] or 0
                    if (not r.max or v <= r.max) and (not r.min or v >= r.min) then Hit(r.sq, boss) end
                end
            end
        end
    else
        Hit("wipe", boss)
        if f and duration < INSTANT_WIPE then Hit("instant_wipe", boss) end
        if f and f.feign and now - f.feign <= FEIGN_WIPE_WINDOW then Hit("feign_wipe", f.feignName) end
        game.wipes[id] = (game.wipes[id] or 0) + 1
        if game.wipes[id] >= 2 then Hit("wipe_twice", boss) end
    end
end

-- A plain /roll line (never a loot roll decision). key: the roller's name key (from Roll:ParseRollLine).
function Detect:OnRoll(value, lo, hi, key)
    if lo == 1 and hi == 100 and value == 1 then Hit("roll_1", key) end
end

function Detect:OnReadyCheck(initiator)
    game.readyCheck = { start = GetTime(), answered = {}, notReady = false, initiator = ShortName(initiator) }
end

function Detect:OnReadyCheckConfirm(unit, isReady)
    if not isReady then Hit("not_ready", UnitShortName(unit)) end
    local rc = game.readyCheck
    if not rc then return end
    local key = Util.UnitKey(unit)
    if key then rc.answered[key] = true end
    if not isReady then rc.notReady = true end
end

function Detect:OnReadyCheckFinished()
    local rc = game.readyCheck
    game.readyCheck = nil
    if not rc then return end
    local asleep, notReady = nil, rc.notReady
    for _, u in ipairs(GroupUnits()) do
        local key = Util.UnitKey(u)
        if key and UnitIsConnected(u) then
            local status = GetReadyCheckStatus and GetReadyCheckStatus(u)
            if status == "notready" then notReady = true end
            local answered = rc.answered[key] or status == "ready" or status == "notready"
                or (rc.initiator ~= nil and UnitShortName(u) == rc.initiator)
            if not answered and not asleep then asleep = UnitShortName(u) or true end
        end
    end
    if asleep then Hit("rc_asleep", type(asleep) == "string" and asleep or nil)
    elseif not notReady then Hit("rc_all_ready") end
end

-- UNIT_CONNECTION for a raid / party unit: dc, and blizzard for BLIZZARD_COUNT different raiders in the window.
function Detect:OnConnection(unit, isConnected)
    if isConnected ~= false or type(unit) ~= "string" or not (unit:find("^raid") or unit:find("^party")) then return end
    local name = UnitShortName(unit)
    Hit("dc", name)
    local now, dcs = GetTime(), game.dcs
    dcs[UnitGUID(unit) or unit] = now
    local n = 0
    for k, t in pairs(dcs) do
        if now - t <= BLIZZARD_WINDOW then n = n + 1 else dcs[k] = nil end
    end
    if n >= BLIZZARD_COUNT then Hit("blizzard", name) end
end

-- author: who sent the line (the chat event's second argument).
function Detect:OnRaidWarning(text, author)
    if type(text) ~= "string" then return end
    local plain = Plain(text)
    local _, upper = plain:gsub("%u", "")
    if upper >= 8 and not plain:find("%l") then Hit("caps_warning", author) end
end

function Detect:OnRaidChat(text, author)
    if type(text) ~= "string" or text:find("^%[DisasterZone") or text:find("^%[CDLoot") then return end
    local s = " " .. Plain(text):lower() .. " "
    if s:find("[^%a]sor+y+[^%a]") or s:find("[^%a]sry[^%a]") or s:find("[^%a]my bad[^%a]") then Hit("sorry", author) end
end

-- CHAT_MSG_RAID_BOSS_EMOTE: text, the boss (sender), the raider it names (the event's fifth argument).
function Detect:OnBossEmote(text, sender, target)
    if not R or type(text) ~= "string" or #R.emote == 0 then return end
    local plain = Plain(text)
    local lower = plain:lower()
    local now = GetTime()
    for _, r in ipairs(R.emote) do
        if lower:find(r.phrase, 1, true) then
            local who = r.capture and plain:match(r.capture)
            if not who and type(target) == "string" and target ~= "" then who = target end
            Fire(r, who or sender, nil, now)
        end
    end
end

-- Every TICK seconds: releases during a fight, and long stretches without any fighting.
function Detect:OnTick()
    local now = GetTime()
    if fight then
        for _, u in ipairs(GroupUnits()) do
            local guid = UnitGUID(u)
            if guid and fight.died[guid] and UnitIsGhost(u) then
                Hit("early_release", UnitShortName(u))
                break
            end
        end
    elseif now - game.lastAction >= IDLE_SECONDS then
        Hit("idle")
    end
end

---------------------------------------------------------------------------
-- Combat log: one handler per sub-event
---------------------------------------------------------------------------

local function Damage(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName,
                      spellId, spellName, amount, overkill, critical, crushing)
    local now = GetTime()
    local srcGroup = IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET)
    if srcGroup or dstPlayer then game.lastAction = now end
    amount = tonumber(amount) or 0
    if critical and amount >= BIG_CRIT and srcPlayer then Hit("big_crit", srcName) end
    if not dstPlayer then return end
    overkill = tonumber(overkill) or -1
    if crushing then Hit("crushing", dstName) end
    if overkill >= BIG_OVERKILL then Hit("overkill", dstName) end
    if dstGUID then
        local lh = NoteHit(dstGUID, now, spellId, spellName, srcName, nil)
        if overkill > 0 then
            local unit = UnitOfGUID(dstGUID)
            local max = unit and UnitHealthMax(unit) or 0
            lh.full = max > 0 and amount - overkill >= ONE_SHOT_SHARE * max
        end
    end
    if R then RunSpell(R.dmg, spellId, spellName, srcName, dstName, dstGUID, false) end
end

local CLEU = {}

-- swing suffix: amount, overkill, school, resisted, blocked, absorbed, critical, glancing, crushing
function CLEU.SWING_DAMAGE(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local amount, overkill, _, _, _, _, critical, _, crushing = ...
    Damage(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, nil, nil, amount, overkill,
        critical, crushing)
end

-- spell prefix + damage suffix: spellId, spellName, school, amount, overkill, school, resisted, blocked,
-- absorbed, critical, glancing, crushing
local function SpellDamage(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local spellId, spellName, _, amount, overkill, _, _, _, _, critical, _, crushing = ...
    Damage(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, spellId, spellName, amount, overkill,
        critical, crushing)
end
CLEU.SPELL_DAMAGE = SpellDamage
CLEU.RANGE_DAMAGE = SpellDamage
CLEU.SPELL_PERIODIC_DAMAGE = SpellDamage

function CLEU.ENVIRONMENTAL_DAMAGE(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    if not dstPlayer then return end
    local env, _, overkill = ...
    env = type(env) == "string" and env:upper() or ""
    overkill = tonumber(overkill) or 0
    local now = GetTime()
    if dstGUID then NoteHit(dstGUID, now, nil, nil, nil, env) end
    if env == "FALLING" then
        Hit("fall", dstName)
        if dstGUID then game.fell[dstGUID] = now end
        if overkill > 0 then Hit("fall_death", dstName) end
    elseif env == "DROWNING" then Hit("drown", dstName)
    elseif env == "FIRE" or env == "LAVA" then Hit("fire", dstName) end
    if overkill >= BIG_OVERKILL then Hit("overkill", dstName) end
end

function CLEU.UNIT_DIED(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags)
    if dstPlayer then
        Detect:OnDeath(false, dstGUID, dstName)
    elseif IsGroup(dstFlags, TYPE_PET) then
        Detect:OnDeath(true, nil, dstName)
    elseif R and dstName then
        local list = R.npcdeath[dstName]
        if list then
            stamp = stamp + 1
            RunList(list, dstName, dstName, dstGUID, GetTime())
        end
    end
end

-- Group players' casts (the class moments) and, inside a raid, the bosses' casts.
function CLEU.SPELL_CAST_SUCCESS(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                                 spellId, spellName)
    if not srcPlayer then
        if R and not IsGroup(srcFlags, TYPE_PET) then RunSpell(R.cast, spellId, spellName, srcName, srcName, nil) end
        return
    end
    local kind = CastKind(spellId, spellName)
    if not kind then return end
    local now = GetTime()
    if kind == "lust" then Hit("lust", srcName)
    elseif kind == "bubble" then
        if srcGUID then game.bubbled[srcGUID] = now end
    elseif kind == "hearth" then
        local t = srcGUID and game.bubbled[srcGUID]
        if t and now - t <= BUBBLE_HEARTH_WINDOW then Hit("bubble_hearth", srcName) end
    elseif kind == "ankh" then
        Hit("ankh", srcName)
        Rezzed(srcGUID, srcName, now)
    elseif kind == "feign" then
        if fight then fight.feign, fight.feignName = now, srcName end
    elseif kind == "drums" then Hit("drums", srcName)
    elseif kind == "loh" then Hit("loh", srcName)
    elseif kind == "stone" then Hit("healthstone", srcName)
    elseif kind == "di" then Hit("divine_intervention", srcName) end
end

function CLEU.SPELL_SUMMON(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                           spellId, spellName)
    if R and not IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET) then
        RunSpell(R.summon, spellId, spellName, srcName, srcName, nil)
    end
end

-- Battle rez, Soulstone, Ankh: bres / ankh, and every one of them towards phoenix.
function CLEU.SPELL_RESURRECT(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                              spellId, spellName)
    if not srcPlayer and not dstPlayer then return end
    local now = GetTime()
    if CastKind(spellId, spellName) == "ankh" then
        if srcPlayer then Hit("ankh", srcName) end
    elseif fight and srcPlayer then
        Hit("bres", srcName)
    end
    Rezzed(dstGUID or srcGUID, dstName or srcName, now)
end

function CLEU.SPELL_INTERRUPT(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags)
    if fight and IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET) then
        fight.interrupts = fight.interrupts + 1
        if fight.interrupts >= 10 then Hit("interrupts", srcName) end
    end
end

function CLEU.SPELL_MISSED(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                           spellId, spellName, _, missType)
    if srcPlayer and TAUNT_MISS[missType] and (TAUNT[spellId] or TAUNT[spellName]) then Hit("taunt_resist", srcName) end
end

-- aura suffix: spellId, spellName, school, auraType (BUFF / DEBUFF), amount (stacks, DOSE only)
function CLEU.SPELL_AURA_APPLIED(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                                 spellId, spellName)
    if fight and ENRAGE[spellName] and not ENRAGE_SKIP[spellId] and not IsGroup(dstFlags, TYPE_PLAYER + TYPE_PET) then
        fight.enraged = true
    end
    if not R or not dstPlayer then return end
    if dstGUID and R.track[spellName] then TrackAura(dstGUID, spellName, GetTime()) end
    RunSpell(R.aura, spellId, spellName, srcName, dstName, dstGUID, IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET))
end

function CLEU.SPELL_AURA_REFRESH(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                                 spellId, spellName)
    if R and dstPlayer and dstGUID and R.track[spellName] then TrackAura(dstGUID, spellName, GetTime()) end
end

function CLEU.SPELL_AURA_REMOVED(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                                 spellId, spellName)
    if R and dstPlayer and dstGUID and R.track[spellName] then TrackAura(dstGUID, spellName, -GetTime()) end
end

function CLEU.SPELL_AURA_APPLIED_DOSE(srcPlayer, dstPlayer, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
                                      spellId, spellName, _, _, amount)
    if R and not IsGroup(dstFlags, TYPE_PLAYER + TYPE_PET) then
        RunSpell(R.stacks, spellId, spellName, dstName, dstName, nil, false, amount)
    end
end

function Detect:OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local handler = CLEU[sub]
    if not handler then return end
    handler(IsGroup(srcFlags, TYPE_PLAYER), IsGroup(dstFlags, TYPE_PLAYER), srcGUID, srcName, srcFlags,
        dstGUID, dstName, dstFlags, ...)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnCLEU()
    if not Live() then return end
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags = CombatLogGetCurrentEventInfo()
    if not CLEU[sub] then return end
    Detect:OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
        select(12, CombatLogGetCurrentEventInfo()))
end

local function OnRaidChat(_, text, author)
    if Live() then Detect:OnRaidChat(text, author) end
end

local function OnZone()
    Detect:RefreshRaid()
end

function Detect:OnInit()
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCLEU)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnZone)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", OnZone)
    ns:RegisterEvent("ENCOUNTER_START", function(_, id, name)
        if Live() then Detect:OnEncounterStart(id, name) end
    end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, id, name, _, _, success)
        if Live() then Detect:OnEncounterEnd(id, success, name) end
    end)
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text)
        if not Live() or not ns.Roll or not ns.Roll.ParseRollLine then return end
        local key, v, lo, hi = ns.Roll:ParseRollLine(text)
        if key then Detect:OnRoll(v, lo, hi, key) end
    end)
    ns:RegisterEvent("READY_CHECK", function(_, initiator)
        if Live() then Detect:OnReadyCheck(initiator) end
    end)
    ns:RegisterEvent("READY_CHECK_CONFIRM", function(_, unit, isReady)
        if Live() then Detect:OnReadyCheckConfirm(unit, isReady) end
    end)
    ns:RegisterEvent("READY_CHECK_FINISHED", function()
        if Live() then Detect:OnReadyCheckFinished() end
    end)
    ns:RegisterEvent("UNIT_CONNECTION", function(_, unit, isConnected)
        if Live() then Detect:OnConnection(unit, isConnected) end
    end)
    ns:RegisterEvent("CHAT_MSG_RAID_WARNING", function(_, text, author)
        if Live() then Detect:OnRaidWarning(text, author) end
    end)
    ns:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE", function(_, text, sender, _, _, target)
        if Live() then Detect:OnBossEmote(text, sender, target) end
    end)
    for _, ev in ipairs({ "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" }) do
        ns:RegisterEvent(ev, OnRaidChat)
    end
    C_Timer.NewTicker(TICK, function()
        if Live() then Detect:OnTick() end
    end)
end

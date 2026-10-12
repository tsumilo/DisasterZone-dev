if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/Squares.lua", ...) then return end -- DisasterZone Games/Bingo/Squares.lua
-- ns.BingoSquares: the Council Bingo card set. Every square is a named raid moment, detected automatically from raid
-- events (Games/Bingo/Detect.lua). Deliberately nothing about loot or council decisions.
-- A square: id, q (quality, like items: c common, u uncommon, r rare, e epic, l legendary), title (its name on the
-- card), text (the plain rule: tooltip, chat), icon (a file in Interface\Icons), raid (a raid's pool: the plan key;
-- nil = the core set, dealt everywhere), hint (optional extra tooltip line).
-- The quality is how rare the moment really is; it sets the points, how many a card gets and how loudly it arrives.
-- Ids of squares that carried over from the first set (1.0 - 1.4) are kept, so saved games still read.
local addonName, ns = ...

local Squares = ns:NewModule("BingoSquares")

Squares.FREE = "FREE"
Squares.FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
Squares.ORDER = { "l", "e", "r", "u", "c" }          -- rarest first
Squares.RAID_DRAW = 6                                -- inside a raid, up to this many of a card's 24 come from its pool
Squares.LINE_POINTS = 10                             -- each completed line

-- color: the item quality colours (rare's blue brightened for text on the dark panel: the tooltip's own rare blue
-- reads too dark there). deal: how many squares of it every card gets (sums to 24).
Squares.QUALITY = {
    c = { key = "c", name = "Common", color = { 1, 1, 1 }, points = 1, deal = 10, odds = "most nights" },
    u = { key = "u", name = "Uncommon", color = { 0.12, 1, 0 }, points = 2, deal = 7, odds = "most weeks" },
    r = { key = "r", name = "Rare", color = { 0.18, 0.55, 1 }, points = 3, deal = 4, odds = "now and then" },
    e = { key = "e", name = "Epic", color = { 0.64, 0.21, 0.93 }, points = 5, deal = 2, odds = "a story you'll tell" },
    l = { key = "l", name = "Legendary", color = { 1, 0.5, 0 }, points = 10, deal = 1, odds = "once a season, if ever" },
}

-- The raids with a pool of their own (plan keys, ns.Data.RaidMeta).
Squares.RAIDS = { "kara", "gruul", "mag", "ssc", "tk" }

local function S(id, q, title, text, icon, raid, hint)
    return { id = id, q = q, title = title, text = text, icon = icon, raid = raid, hint = hint }
end

Squares.list = {
    -- core: legendary
    S("bubble_hearth", "l", "Bubble Hearth", "A paladin bubbles, then hearths out of the fight", "Spell_Holy_DivineIntervention"),
    S("last_one", "l", "Last One Standing", "A boss dies with one raider left alive", "Spell_Holy_PowerInfusion", nil,
        "Counts in groups of 10 or more."),
    S("beat_clock", "l", "Beat the Clock", "The boss goes berserk and still dies", "Racial_Troll_Berserk"),
    S("phoenix", "l", "Phoenix Down", "3 raiders come back to life in one boss fight", "Spell_Fire_Burnout", nil,
        "Battle rez, Soulstone or Ankh: any three."),
    S("blizzard", "l", "Blizzard Says No", "5 raiders disconnect within 10 seconds", "Spell_Frost_IceStorm"),
    S("no_wipe", "l", "We Don't Wipe", "A kill with more than half the raid dead", "Ability_Warrior_Rampage", nil,
        "Counts in groups of 10 or more."),
    -- core: epic
    S("clutch", "e", "Clutch", "A boss kill with 5 or fewer alive", "Ability_Warrior_EndlessRage", nil,
        "Counts in groups of 10 or more."),
    S("ankh", "e", "Ankh!", "A shaman Reincarnates", "Spell_Nature_Reincarnation"),
    S("fall_death", "e", "Death by Gravity", "Someone falls to their death", "Spell_Magic_FeatherFall"),
    S("rc_pull", "e", "Leeroy", "The boss is pulled during a ready check", "Ability_Warrior_Charge"),
    S("rc_all_ready", "e", "Unicorn", "Every raider is Ready on the first check", "Spell_Holy_MagicalSentry"),
    S("drown", "e", "Sleeps with the Fishes", "Someone drowns", "Spell_Shadow_DemonBreath"),
    S("divine_intervention", "e", "Sacrifice", "A paladin casts Divine Intervention", "Spell_Nature_TimeStop"),
    S("one_shot", "e", "One-Shot", "A raider at full health dies to a single hit", "Ability_Warrior_DecisiveStrike"),
    -- core: rare
    S("flawless", "r", "Flawless", "A boss kill with no deaths", "Spell_Holy_SealOfProtection"),
    S("speed_kill", "r", "Speedrun", "A boss dies in under 2 minutes", "Ability_Rogue_Sprint"),
    S("long_fight", "r", "Marathon", "A boss fight lasts over 6 minutes", "INV_Misc_PocketWatch_02"),
    S("instant_wipe", "r", "Instant Regret", "A wipe in under 20 seconds", "Spell_Fire_SelfDestruct"),
    S("mass_death", "r", "Dominoes", "3 deaths within 5 seconds", "Spell_Shadow_DeathPact"),
    S("late_death", "r", "So Close", "Someone dies in the last 10 seconds of a kill", "Spell_Shadow_AnimateDead"),
    S("bres", "r", "Not Dead Yet", "A battle rez mid-fight", "Spell_Shadow_SoulGem"),
    S("overkill", "r", "Deleted", "5,000+ overkill on a raider", "Ability_Warrior_SavageBlow"),
    S("big_crit", "r", "Big Numbers", "An 8,000+ crit", "Ability_Rogue_Ambush"),
    S("loh", "r", "Hand of God", "A paladin casts Lay on Hands", "Spell_Holy_LayOnHands"),
    S("early_release", "r", "Ghost Mode", "Someone releases while the boss is still up", "Spell_Holy_SenseUndead"),
    S("feign_wipe", "r", "Possum", "A hunter feigns out of a wipe", "Ability_Rogue_FeignDeath", nil,
        "Feign Death in the last 20 seconds before a wipe."),
    -- core: uncommon
    S("wipe_twice", "u", "Rinse, Repeat", "Two wipes on the same boss", "Spell_Shadow_DeathScream"),
    S("redemption", "u", "Redemption Arc", "Kill a boss you wiped on tonight", "Spell_Holy_Resurrection"),
    S("fire", "u", "The Floor Is Lava", "Someone stands in fire", "Spell_Fire_Incinerate"),
    S("interrupts", "u", "Kick Party", "10 interrupts in one fight", "Ability_Kick"),
    S("dc", "u", "Gone with the Wind", "Someone disconnects", "Spell_Nature_Cyclone"),
    S("crushing", "u", "Crushed", "A tank takes a crushing blow", "INV_Shield_06"),
    S("taunt_resist", "u", "Not Today", "A taunt is resisted", "Ability_Physical_Taunt"),
    S("idle", "u", "Smoke Break", "15 minutes without a pull", "INV_Misc_PocketWatch_01"),
    S("rc_asleep", "u", "Sleeping Beauty", "Someone sleeps through a ready check", "Spell_Nature_Sleep",
        nil, "The check ends while someone online never answered."),
    S("roll_1", "u", "Critical Fail", "Someone rolls a 1", "INV_Misc_Ticket_Tarot_Stack_01", nil, "On a /roll 1-100."),
    S("death_first", "u", "Pulled Too Hard", "A death in the first 30 seconds of a pull", "Ability_Warrior_Revenge"),
    -- core: common
    S("wipe", "c", "Corpse Run", "The raid wipes", "INV_Misc_Bone_HumanSkull_01"),
    S("lust", "c", "Heroism!", "Bloodlust or Heroism goes out", "Spell_Nature_BloodLust"),
    S("drums", "c", "Drum Circle", "Someone plays Drums", "INV_Misc_Drum_02", nil,
        "Drums of Battle, War, Restoration, Speed or Panic."),
    S("healthstone", "c", "Soul Snack", "A Healthstone is eaten", "INV_Stone_04"),
    S("not_ready", "c", "Hold On, Brb", "Someone clicks Not Ready", "INV_Misc_Note_01"),
    S("fall", "c", "Mind the Gap", "Someone takes fall damage", "Ability_Druid_Dash"),
    S("sorry", "c", "My Bad", "Someone says sorry in raid chat", "Spell_Holy_Excorcism"),
    S("pet_death", "c", "Pet Cemetery", "A pet dies", "Ability_Hunter_MendPet"),
    S("death_trash", "c", "Trash Talk", "Someone dies to trash", "INV_Misc_Bone_ElfSkull_01"),
    S("ten_deaths", "c", "Spirit Healer's Regular", "10 deaths tonight", "Spell_Shadow_RaiseDead"),
    S("caps_warning", "c", "WE'RE ALL GONNA DIE", "An ALL-CAPS raid warning", "Ability_Warrior_BattleShout"),

    -- Karazhan
    S("kara_charred", "c", "Hot Feet", "Someone stands in Nightbane's Charred Earth", "Spell_Fire_Volcano", "kara"),
    S("kara_sacrifice", "c", "Chained Up", "Illhoof chains someone with Sacrifice", "Spell_Shadow_LifeDrain", "kara"),
    S("kara_medivh", "c", "Medivh Cheats", "Medivh cheats at the chess board", "INV_Staff_Medivh", "kara"),
    S("kara_dinner", "u", "Dinner Guest", "One of Moroes' guests kills someone", "INV_Misc_Food_15", "kara"),
    S("kara_repent", "u", "Repent!", "Maiden's Holy Fire or Holy Wrath kills someone", "Spell_Holy_Excorcism_02", "kara"),
    S("kara_cyclone", "u", "Not in Kansas", "The Opera's cyclone picks someone up", "Spell_Nature_Cyclone", "kara"),
    S("kara_wreath", "u", "You Moved.", "A Flame Wreath goes off (Shade of Aran)", "Spell_Fire_SealOfFire", "kara"),
    S("kara_infernal", "u", "Infernal Real Estate", "Someone burns in an Infernal's Hellfire", "Spell_Shadow_SummonInfernal", "kara"),
    S("kara_hateful", "r", "Hateful Bolt", "The Curator's Hateful Bolt kills someone", "Spell_Arcane_Arcane01", "kara"),
    S("kara_teeth", "r", "What Big Teeth", "Little Red Riding Hood gets eaten", "Ability_Hunter_Pet_Wolf", "kara"),
    S("kara_drink", "r", "Drink Break", "Aran's Pyroblast kills someone after his drink", "INV_Drink_18", "kara"),
    S("kara_undying", "e", "Undying Love", "Julianne brings Romulo back to life", "Spell_Holy_Restoration", "kara",
        "Or Romulo brings back Julianne."),
    S("kara_enfeebled", "e", "Enfeebled", "Shadow Nova kills an Enfeebled raider", "Spell_Shadow_ShadowWordPain", "kara"),
    S("kara_wolfpack", "l", "Wolf Pack", "The Big Bad Wolf eats 3 Little Reds in one fight", "Ability_Hunter_Pet_Wolf", "kara"),
    -- Gruul's Lair
    S("gruul_shatter", "c", "Shattered", "Someone dies to Shatter", "Spell_Nature_EarthQuake", "gruul"),
    S("gruul_cavein", "c", "Cave In", "Rocks from Cave In hit someone", "INV_Stone_10", "gruul"),
    S("gruul_whirl", "c", "Spin to Win", "Maulgar's Whirlwind hits 3 raiders", "Ability_Whirlwind", "gruul"),
    S("gruul_sheep", "u", "Baa", "Kiggler polymorphs someone", "Spell_Nature_Polymorph", "gruul"),
    S("gruul_prayer", "u", "Uninterrupted", "Blindeye's Prayer of Healing goes off", "Spell_Holy_PrayerOfHealing02", "gruul"),
    S("gruul_hurtful", "u", "Hurt Feelings", "Hurtful Strike kills someone", "Ability_Warrior_Cleave", "gruul"),
    S("gruul_blastwave", "r", "Blast Waved", "Krosh's Blast Wave kills someone", "Spell_Holy_Excorcism_02", "gruul"),
    S("gruul_smash", "r", "Arcing Smash", "Maulgar's Arcing Smash kills someone", "Ability_Warrior_Cleave", "gruul"),
    S("gruul_growth", "r", "Big Boy", "Gruul reaches 15 stacks of Growth", "Spell_Shadow_UnholyFrenzy", "gruul"),
    S("gruul_hug", "e", "Group Hug", "3 raiders die to one Shatter", "Spell_Nature_Earthquake", "gruul"),
    S("gruul_rockbottom", "l", "Rock Bottom", "One Shatter kills 5 raiders", "Spell_Nature_EarthQuake", "gruul"),
    -- Magtheridon's Lair
    S("mag_debris", "c", "Ceiling Collapse", "Falling debris hits someone", "INV_Stone_10", "mag"),
    S("mag_quake", "c", "Shake It Off", "Magtheridon's Quake hits the raid", "Ability_ThunderClap", "mag"),
    S("mag_abyssal", "c", "Incoming!", "A channeler summons a Burning Abyssal", "Spell_Shadow_SummonInfernal", "mag"),
    S("mag_mending", "u", "Dark Mending", "A channeler heals with Dark Mending", "Spell_Shadow_LifeDrain", "mag"),
    S("mag_fireblast", "u", "Lit Up", "A Burning Abyssal's Fire Blast kills someone", "Spell_Fire_Immolation", "mag"),
    S("mag_cleave", "u", "Front Row Seat", "Magtheridon's Cleave kills someone", "Ability_Warrior_Cleave", "mag"),
    S("mag_nova", "r", "Blast Nova", "The cubes fail and Blast Nova goes off", "Spell_Fire_SealOfFire", "mag"),
    S("mag_fivedown", "r", "Five Down", "All 5 channelers die within 2 minutes of the pull", "Spell_Shadow_Shadowfury", "mag"),
    S("mag_cubes", "e", "Perfect Cubes", "A kill without a single Blast Nova", "INV_Misc_Orb_05", "mag"),
    S("mag_novaparty", "l", "Nova Party", "Blast Nova goes off 3 times and he still dies", "Spell_Fire_SoulBurn", "mag"),
    -- Serpentshrine Cavern
    S("ssc_grave", "c", "Watery Grave", "Morogrim sends someone to a Watery Grave", "Spell_Frost_ArcticWinds", "ssc"),
    S("ssc_geyser", "c", "Geyser Launch", "A Lurker Geyser throws someone in the air", "Spell_Frost_SummonWaterElemental", "ssc"),
    S("ssc_spores", "c", "Toxic Spores", "Someone stands in a sporebat's Toxic Spores", "Spell_Nature_NullifyPoison", "ssc"),
    S("ssc_piranha", "u", "Piranha Snack", "Someone dies to the piranhas in the water", "INV_Misc_Fish_31", "ssc"),
    S("ssc_marked", "u", "Marked for Death", "A Hydross mark reaches 250%", "Spell_Frost_FrostShock", "ssc",
        "A 250% Mark of Hydross or Mark of Corruption lands on someone."),
    S("ssc_murloc", "u", "Mrglglgl", "A Tidewalker murloc kills someone", "INV_Misc_MonsterHead_02", "ssc"),
    S("ssc_static", "u", "Static Shuffle", "A Static Charge hits 3 raiders at once", "Spell_Nature_LightningOverload", "ssc"),
    S("ssc_spout", "u", "Gone Fishing", "Someone dies to the Lurker's Spout", "INV_Misc_Fish_35", "ssc"),
    S("ssc_whirl", "u", "Run Away!", "Leotheras' Whirlwind kills someone", "Ability_Whirlwind", "ssc"),
    S("ssc_demon", "r", "Inner Demons", "Someone loses to their own Inner Demon", "Spell_Shadow_ManaFeed", "ssc"),
    S("ssc_totem", "r", "Totem Duty", "Karathress' Spitfire Totem kills someone", "Spell_Fire_TotemOfWrath", "ssc"),
    S("ssc_tsunami", "e", "Murloc Tsunami", "Murlocs kill 3 raiders in one Morogrim fight", "Spell_Nature_CallStorm", "ssc"),
    S("ssc_spoutdoom", "l", "Spout of Doom", "One Spout kills 5 raiders", "Spell_Frost_SummonWaterElemental", "ssc"),
    -- Tempest Keep
    S("tk_orb", "c", "Dodgeball", "Void Reaver's Arcane Orb hits someone", "Spell_Arcane_Arcane04", "tk"),
    S("tk_knock", "c", "Knocked Away", "Void Reaver's Knock Away hits someone", "Ability_ThunderClap", "tk"),
    S("tk_roar", "c", "Bellowing Roar", "Lord Sanguinar fears the raid", "Spell_Shadow_PsychicScream", "tk"),
    S("tk_gaze", "c", "Run, Forrest", "Thaladred fixes his gaze on someone", "Spell_Shadow_Charm", "tk"),
    S("tk_patch", "u", "Ashes to Ashes", "Al'ar's Flame Patch kills someone", "Spell_Fire_Burnout", "tk"),
    S("tk_dive", "u", "Dive Bomb", "Al'ar's Dive Bomb hits 5 raiders", "Spell_Fire_Fireball", "tk"),
    S("tk_wrath", "u", "Wrath of the Astromancer", "Solarian's Wrath kills someone", "Spell_Arcane_StarFire", "tk"),
    S("tk_flamestrike", "u", "Flamestrike!", "Someone dies in a Kael'thas Flamestrike", "Spell_Fire_SoulBurn", "tk"),
    S("tk_rebirth", "r", "Rebirth", "Al'ar's Rebirth explosion kills someone", "Spell_Fire_FireArmor", "tk"),
    S("tk_mc", "r", "Mind Games", "Kael'thas mind controls a raider", "Spell_Shadow_ShadowWordDominate", "tk"),
    S("tk_pyro", "e", "Pyroblasted", "Kael's Pyroblast kills someone", "Spell_Fire_Fireball02", "tk"),
    S("tk_lapse", "l", "What Goes Up", "Someone falls to their death after Gravity Lapse", "Spell_Magic_FeatherFall", "tk"),
}

Squares.byId = {}
for _, sq in ipairs(Squares.list) do Squares.byId[sq.id] = sq end

function Squares:Get(id) return self.byId[id] end

function Squares:Quality(sqOrId)
    local sq = type(sqOrId) == "table" and sqOrId or self.byId[sqOrId]
    return self.QUALITY[sq and sq.q or "c"] or self.QUALITY.c
end

-- Points a marked square is worth (0 for the free centre / an unknown id).
function Squares:Points(id)
    local sq = self.byId[id]
    return sq and self.QUALITY[sq.q].points or 0
end

-- Texture of a square's card art (the free centre and unknown ids fall back).
function Squares:Icon(sq)
    if type(sq) == "string" then sq = self.byId[sq] end
    if not sq or not sq.icon then return self.FALLBACK_ICON end
    return "Interface\\Icons\\" .. sq.icon
end

-- The core set (dealt everywhere) and a raid's pool, in list order.
function Squares:Core()
    local out = {}
    for _, sq in ipairs(self.list) do
        if not sq.raid then out[#out + 1] = sq end
    end
    return out
end

function Squares:Pool(raid)
    local out = {}
    if not raid then return out end
    for _, sq in ipairs(self.list) do
        if sq.raid == raid then out[#out + 1] = sq end
    end
    return out
end

function Squares:HasPool(raid)
    return raid ~= nil and #self:Pool(raid) > 0
end

-- Every square id (list order).
function Squares:Ids()
    local out = {}
    for i, sq in ipairs(self.list) do out[i] = sq.id end
    return out
end

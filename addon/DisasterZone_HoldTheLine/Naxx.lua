if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Naxx.lua", ...) then return end -- DisasterZone_HoldTheLine/Naxx.lua
-- Hold the Line's stages: Eastern Plaguelands (the first, Data.lua's waves and events) and the necropolis Naxxramas,
-- five runs: four quarters (15:00, bosses at 5:00 and 10:00, then a master to kill inside a Berserk window) and the
-- Frostwyrm Lair (Sapphiron at 10:00, Kel'Thuzad at 15:00, Berserk at 25:00). Opens after a first win in the
-- Plaguelands; the lair after all four masters fall. Here: their dead, waves, clocks, relics (run-only items from the
-- bosses' coffers), Tier 3 (a Desecrated token per master, nine make a set: small bonuses + the look), Frozen Runes and
-- Frost Resistance, the weekly Naxxramas challenges and the Naxxramas achievements. The bosses' behaviour lives in
-- NaxxBoss.lua; display IDs of the models were checked on wowhead.com/tbc (dev/art/casc/survivors_mockup/gen_sprites.py).
local _, ns = ...

local D = ns.HTLData
local function c(r, g, b) return { r / 255, g / 255, b / 255 } end
local min = math.min

D.NAXX_ASSETS = 16          -- the art set with the necropolis's models, floors and effects

---------------------------------------------------------------------------
-- the necropolis's dead (key = sprite; sprite overrides where a model is shared)
---------------------------------------------------------------------------
local M = D.MOBS
local function mob(k, t) M[k] = t t.key = k t.naxx = true end
-- the Arachnid Quarter
mob("n_spider", { name = "Maexxna Spiderling", hp = 6, spd = 96, dmg = 4, r = 8, xp = 1, ichor = "rot", mass = 0.4 })
mob("n_creeper", { name = "Dread Creeper", hp = 14, spd = 100, dmg = 6, r = 11, xp = 1, ichor = "rot", mass = 0.8, leap = true })
mob("n_spinner", { name = "Carrion Spinner", hp = 26, spd = 46, dmg = 8, r = 13, xp = 2, ichor = "rot", mass = 1, spits = "web" })
mob("n_venom", { name = "Venom Stalker", hp = 34, spd = 60, dmg = 6, r = 13, xp = 3, ichor = "rot", mass = 1, venom = true })
mob("n_cryptguard", { name = "Crypt Guard", hp = 650, spd = 46, dmg = 18, r = 22, xp = 40, ichor = "rot", elite = true, mass = 8 })
mob("n_worshipper", { name = "Naxxramas Worshipper", hp = 40, spd = 40, dmg = 8, r = 12, xp = 3, ichor = "blood", mass = 1, caster = "fire" })
mob("n_follower", { name = "Naxxramas Follower", hp = 46, spd = 64, dmg = 10, r = 12, xp = 3, ichor = "blood", mass = 1, charger = true })
-- the Plague Quarter
mob("n_infghoul", { name = "Infectious Ghoul", hp = 16, spd = 52, dmg = 7, r = 12, xp = 1, ichor = "rot", mass = 1, burst = true })
mob("n_grub", { name = "Mutated Grub", hp = 40, spd = 30, dmg = 8, r = 16, xp = 3, ichor = "rot", mass = 2, burst = true })
mob("n_frenzbat", { name = "Frenzied Bat", hp = 9, spd = 122, dmg = 5, r = 10, xp = 1, ichor = "blood", fly = true, mass = 0.6 })
mob("n_plaguebeast", { name = "Plague Beast", hp = 800, spd = 46, dmg = 20, r = 26, xp = 40, ichor = "rot", elite = true, mass = 8, trample = true })
mob("n_gargoyle", { name = "Stoneskin Gargoyle", hp = 120, spd = 52, dmg = 12, r = 16, xp = 8, ichor = "bone", mass = 2, stoneskin = true })
-- the Military Quarter
mob("n_understudy", { name = "Deathknight Understudy", hp = 70, spd = 40, dmg = 12, r = 13, xp = 4, ichor = "blood", mass = 2 })
mob("n_trainee", { name = "Unrelenting Trainee", hp = 18, spd = 64, dmg = 7, r = 12, xp = 1, ichor = "blood", mass = 1 })
mob("n_rider", { name = "Spectral Rider", hp = 60, spd = 0, dmg = 25, r = 16, xp = 2, ichor = "spirit", ghost = true, mass = 6 })
mob("n_bony", { name = "Bony Construct", hp = 600, spd = 48, dmg = 18, r = 20, xp = 40, ichor = "bone", elite = true, mass = 8, sweep = true })
mob("n_smith", { name = "Skeletal Smith", hp = 50, spd = 44, dmg = 10, r = 12, xp = 4, ichor = "bone", mass = 1, crush = true })
mob("n_necroknight", { name = "Necro Knight", hp = 70, spd = 40, dmg = 12, r = 12, xp = 6, ichor = "blood", mass = 1, blinker = true })
mob("n_shade", { name = "Shade of Naxxramas", hp = 500, spd = 40, dmg = 14, r = 16, xp = 40, ichor = "spirit", ghost = true, elite = true, mass = 6, ghosts = true })
-- the Construct Quarter
mob("n_golem", { name = "Patchwork Golem", hp = 700, spd = 40, dmg = 20, r = 22, xp = 40, ichor = "rot", elite = true, mass = 8, aura = true })
mob("n_belcher", { name = "Sludge Belcher", hp = 90, spd = 36, dmg = 12, r = 18, xp = 6, ichor = "rot", mass = 3, spits = "slime" })
mob("n_monstrosity", { name = "Living Monstrosity", hp = 80, spd = 44, dmg = 10, r = 18, xp = 6, ichor = "rot", mass = 3, caster = "storm" })
mob("n_scientist", { name = "Mad Scientist", hp = 40, spd = 48, dmg = 6, r = 12, xp = 4, ichor = "blood", mass = 1, healer = true })
mob("n_slime", { name = "Fallout Slime", hp = 22, spd = 34, dmg = 6, r = 12, xp = 1, ichor = "rot", mass = 1, burst = true })
mob("n_chow", { name = "Zombie Chow", hp = 20, spd = 46, dmg = 6, r = 12, xp = 1, ichor = "rot", mass = 1 })
-- the Frostwyrm Lair
mob("n_soldier", { name = "Soldier of the Frozen Wastes", hp = 16, spd = 74, dmg = 9, r = 11, xp = 1, ichor = "bone", mass = 0.8, bursts = true })
mob("n_abom", { name = "Unstoppable Abomination", sprite = "abom", hp = 300, spd = 40, dmg = 16, r = 26, xp = 10, ichor = "rot", mass = 6, wound = true })
mob("n_soulweaver", { name = "Soul Weaver", sprite = "n_shade", hp = 60, spd = 46, dmg = 10, r = 14, xp = 4, ichor = "spirit", ghost = true, mass = 1, wail = true })
mob("n_spore", { name = "Spore", sprite = "n_slime", hp = 30, spd = 0, dmg = 0, r = 12, xp = 0, ichor = "rot", mass = 99, tint = c(220, 255, 120), scale = 0.8 })
mob("n_guardian", { name = "Guardian of Icecrown", hp = 2400, spd = 52, dmg = 30, r = 26, xp = 60, ichor = "bone", elite = true, mass = 20 })
-- the masters and their lieutenants
local function boss(k, t) t.boss = true t.mass = t.mass or 40 mob(k, t) end
boss("n_anub", { name = "Anub'Rekhan", hp = 4800, spd = 40, dmg = 22, r = 30, xp = 200, ichor = "rot" })
boss("n_faerlina", { name = "Grand Widow Faerlina", hp = 7000, spd = 44, dmg = 20, r = 16, xp = 250, ichor = "blood" })
boss("n_maexxna", { name = "Maexxna", hp = 26000, spd = 50, dmg = 26, r = 30, xp = 400, ichor = "rot", finale = true })
boss("n_noth", { name = "Noth the Plaguebringer", hp = 4600, spd = 42, dmg = 20, r = 14, xp = 200, ichor = "blood" })
boss("n_heigan", { name = "Heigan the Unclean", hp = 7200, spd = 40, dmg = 22, r = 14, xp = 250, ichor = "blood" })
boss("n_loatheb", { name = "Loatheb", hp = 12500, spd = 28, dmg = 26, r = 40, xp = 400, ichor = "rot", finale = true })
boss("n_razuvious", { name = "Instructor Razuvious", hp = 5000, spd = 44, dmg = 24, r = 16, xp = 200, ichor = "blood" })
boss("n_gothik", { name = "Gothik the Harvester", hp = 7000, spd = 42, dmg = 20, r = 14, xp = 250, ichor = "blood" })
boss("n_korthazz", { name = "Thane Korth'azz", hp = 4500, spd = 40, dmg = 22, r = 22, xp = 150, ichor = "blood", finale = true, horseman = true })
boss("n_blaumeux", { name = "Lady Blaumeux", hp = 4500, spd = 40, dmg = 22, r = 22, xp = 150, ichor = "blood", finale = true, horseman = true })
boss("n_mograine", { name = "Highlord Mograine", hp = 4500, spd = 40, dmg = 22, r = 22, xp = 150, ichor = "blood", finale = true, horseman = true })
boss("n_zeliek", { name = "Sir Zeliek", hp = 4500, spd = 40, dmg = 22, r = 22, xp = 150, ichor = "blood", finale = true, horseman = true })
boss("n_patchwerk", { name = "Patchwerk", hp = 5200, spd = 50, dmg = 30, r = 30, xp = 250, ichor = "rot" })
boss("n_grobbulus", { name = "Grobbulus", hp = 6200, spd = 34, dmg = 22, r = 30, xp = 250, ichor = "rot" })
boss("n_gluth", { name = "Gluth", hp = 7000, spd = 46, dmg = 24, r = 30, xp = 250, ichor = "blood" })
boss("n_stalagg", { name = "Stalagg", hp = 2400, spd = 34, dmg = 24, r = 28, xp = 150, ichor = "rot", finale = true })
boss("n_feugen", { name = "Feugen", sprite = "n_stalagg", hp = 2400, spd = 34, dmg = 24, r = 28, xp = 150, ichor = "rot", finale = true, tint = c(150, 200, 255) })
boss("n_thaddius", { name = "Thaddius", hp = 10000, spd = 38, dmg = 30, r = 34, xp = 500, ichor = "rot", finale = true })
boss("n_sapphiron", { name = "Sapphiron", hp = 12000, spd = 44, dmg = 28, r = 40, xp = 500, ichor = "bone" })
boss("n_kelthuzad", { name = "Kel'Thuzad", hp = 18000, spd = 38, dmg = 30, r = 20, xp = 800, ichor = "spirit", finale = true })

---------------------------------------------------------------------------
-- the stages
---------------------------------------------------------------------------
local function waves(list)
    local order = {}
    for _, w in ipairs(list) do for k in pairs(w[3]) do order[k] = true end end
    local keys = {}
    for k in pairs(order) do keys[#keys + 1] = k end
    table.sort(keys)                                -- (a seeded run must pick the same way every time)
    for _, w in ipairs(list) do
        local l = {}
        for _, k in ipairs(keys) do if w[3][k] then l[#l + 1] = { k, w[3][k] } end end
        w.list = l
    end
    return list
end
local function target(t) return min(300, 30 + t * 0.48 + (t > 300 and (t - 300) * 0.14 or 0)) end

D.STAGES = {
    epl = { key = "epl", name = "Eastern Plaguelands", tint = D.STAGE.tint, dark = D.STAGE.dark, darkA = D.STAGE.darkA, fog = D.STAGE.fog,
        ground = { D.MEDIA .. "ground", 1024 }, props = true, reaper = true, len = 900, waves = D.WAVES, events = D.EVENTS, target = D.Target },
    arachnid = { key = "arachnid", name = "The Arachnid Quarter", short = "Arachnid", wing = true, color = c(200, 140, 255), icon = "spell_nature_web",
        tint = c(206, 214, 200), dark = c(8, 12, 6), darkA = 0.5, fog = 0.1, fogC = c(150, 200, 130), ground = { 127851, 240 }, hazard = "webs",
        len = 900, finale = "n_maexxna", berserk = 180, target = target, tokens = { "wrist", "hands" },
        bosses = { "n_anub", "n_faerlina", "n_maexxna" },
        blurb = "Webs slow you. Fire burns them away. Egg sacs hatch spiderlings.",
        waves = waves({ { 0, 60, { n_spider = 6, n_creeper = 3 } }, { 60, 180, { n_spider = 4, n_creeper = 4, n_spinner = 2 } },
            { 180, 300, { n_creeper = 4, n_spinner = 3, n_venom = 2, n_spider = 3 } }, { 300, 480, { n_creeper = 3, n_venom = 3, n_spinner = 2, n_worshipper = 1, n_follower = 1 } },
            { 480, 660, { n_venom = 4, n_spinner = 3, n_follower = 2, n_creeper = 3 } }, { 660, 9999, { n_venom = 4, n_creeper = 4, n_follower = 3, n_spinner = 3 } } }),
        events = {
            { t = 300, kind = "boss", mob = "n_anub", msg = "Anub'Rekhan rises from the crypt!" },
            { t = 420, kind = "elite", mob = "n_cryptguard", msg = "A Crypt Guard bursts from the floor." },
            { t = 510, kind = "brood", msg = "The brood swarms out of the webs!" },
            { t = 600, kind = "boss", mob = "n_faerlina", msg = "Grand Widow Faerlina and her worshippers arrive!" },
            { t = 720, kind = "elite", mob = "n_cryptguard", n = 2, msg = "Two Crypt Guards break the floor." },
            { t = 840, kind = "dark", msg = "The webs close over the light..." },
            { t = 900, kind = "finale", mob = "n_maexxna", msg = "Maexxna drops from her web!" } } },
    plague = { key = "plague", name = "The Plague Quarter", short = "Plague", wing = true, color = c(160, 224, 106), icon = "spell_shadow_plaguecloud",
        tint = c(204, 222, 190), dark = c(6, 14, 4), darkA = 0.46, fog = 0.2, fogC = c(140, 220, 90), ground = { 127850, 240 }, hazard = "plague",
        len = 900, finale = "n_loatheb", berserk = 180, target = target, tokens = { "waist", "legs" },
        bosses = { "n_noth", "n_heigan", "n_loatheb" },
        blurb = "Plague clouds roll across the floor. The infected burst when they die.",
        waves = waves({ { 0, 60, { n_infghoul = 8 } }, { 60, 180, { n_infghoul = 6, n_frenzbat = 3, n_grub = 1 } },
            { 180, 300, { n_infghoul = 5, n_frenzbat = 3, n_grub = 2, n_gargoyle = 1 } }, { 300, 480, { n_infghoul = 4, n_grub = 2, n_gargoyle = 2, n_frenzbat = 3 } },
            { 480, 660, { n_infghoul = 4, n_grub = 3, n_gargoyle = 2, n_frenzbat = 2 } }, { 660, 9999, { n_infghoul = 4, n_grub = 3, n_gargoyle = 3, n_frenzbat = 3 } } }),
        events = {
            { t = 300, kind = "boss", mob = "n_noth", msg = "Noth the Plaguebringer appears!" },
            { t = 420, kind = "elite", mob = "n_plaguebeast", msg = "A Plague Beast tramples in." },
            { t = 510, kind = "swarm", mob = "n_frenzbat", msg = "Frenzied bats pour from the vents!" },
            { t = 600, kind = "boss", mob = "n_heigan", msg = "Heigan the Unclean begins the dance!" },
            { t = 720, kind = "elite", mob = "n_plaguebeast", n = 2, msg = "Two Plague Beasts break loose." },
            { t = 840, kind = "dark", msg = "Spores fill the air..." },
            { t = 900, kind = "finale", mob = "n_loatheb", msg = "Loatheb stirs. Inevitable Doom begins." } } },
    military = { key = "military", name = "The Military Quarter", short = "Military", wing = true, color = c(224, 83, 60), icon = "ability_mount_undeadhorse",
        tint = c(214, 206, 220), dark = c(12, 8, 18), darkA = 0.48, fog = 0.1, fogC = c(170, 150, 210), ground = { 129877, 240 }, hazard = "riders",
        len = 900, finale = "n_mograine", berserk = 200, target = target, tokens = { "feet", "chest" },
        bosses = { "n_razuvious", "n_gothik", "n_mograine" },
        blurb = "Death knight riders charge down marked lanes.",
        waves = waves({ { 0, 60, { n_trainee = 8 } }, { 60, 180, { n_trainee = 6, n_smith = 2 } },
            { 180, 300, { n_trainee = 5, n_smith = 3, n_necroknight = 1 } }, { 300, 480, { n_trainee = 4, n_smith = 3, n_necroknight = 2, n_understudy = 1 } },
            { 480, 660, { n_trainee = 4, n_smith = 3, n_necroknight = 2, n_understudy = 2 } }, { 660, 9999, { n_trainee = 4, n_smith = 3, n_necroknight = 3, n_understudy = 2 } } }),
        events = {
            { t = 300, kind = "boss", mob = "n_razuvious", msg = "Instructor Razuvious calls his students!" },
            { t = 420, kind = "elite", mob = "n_bony", msg = "A Bony Construct lumbers out." },
            { t = 510, kind = "ring", mob = "n_trainee", msg = "The trainees surround you!" },
            { t = 600, kind = "boss", mob = "n_gothik", msg = "Gothik the Harvester closes the gate!" },
            { t = 720, kind = "elite", mob = "n_shade", n = 2, msg = "Two Shades of Naxxramas drift in." },
            { t = 840, kind = "dark", msg = "Hoofbeats in the dark..." },
            { t = 900, kind = "finale", mob = "n_mograine", msg = "The Four Horsemen ride!" } } },
    construct = { key = "construct", name = "The Construct Quarter", short = "Construct", wing = true, color = c(127, 208, 160), icon = "spell_nature_lightningoverload",
        tint = c(210, 216, 204), dark = c(8, 12, 10), darkA = 0.46, fog = 0.12, fogC = c(150, 210, 150), ground = { 129874, 240 }, hazard = "slime",
        len = 900, finale = "n_thaddius", berserk = 200, target = target, tokens = { "shoulders", "head" },
        bosses = { "n_patchwerk", "n_grobbulus", "n_gluth", "n_thaddius" },
        blurb = "Slime pools slow and poison. Mad Scientists patch the dead back up.",
        waves = waves({ { 0, 60, { n_chow = 8 } }, { 60, 180, { n_chow = 6, n_slime = 3 } },
            { 180, 300, { n_chow = 4, n_slime = 3, n_belcher = 1, n_scientist = 1 } }, { 300, 480, { n_chow = 4, n_slime = 2, n_belcher = 2, n_scientist = 1, n_monstrosity = 1 } },
            { 480, 660, { n_chow = 3, n_slime = 3, n_belcher = 2, n_scientist = 2, n_monstrosity = 2 } }, { 660, 9999, { n_chow = 3, n_slime = 3, n_belcher = 2, n_scientist = 2, n_monstrosity = 3 } } }),
        events = {
            { t = 240, kind = "boss", mob = "n_patchwerk", msg = "Patchwerk want to play!" },
            { t = 480, kind = "boss", mob = "n_grobbulus", msg = "Grobbulus oozes in." },
            { t = 600, kind = "elite", mob = "n_golem", msg = "A Patchwork Golem stitches itself up." },
            { t = 690, kind = "boss", mob = "n_gluth", msg = "Gluth breaks his chains!" },
            { t = 780, kind = "elite", mob = "n_golem", n = 2, msg = "Two Patchwork Golems join the hunt." },
            { t = 840, kind = "dark", msg = "The tesla coils hum..." },
            { t = 900, kind = "finale", mob = "n_stalagg", msg = "Stalagg and Feugen guard the coils!" } } },
    frost = { key = "frost", name = "The Frostwyrm Lair", short = "Frostwyrm", lair = true, color = c(159, 216, 255), icon = "spell_frost_freezingbreath",
        tint = c(206, 220, 236), dark = c(4, 8, 20), darkA = 0.46, fog = 0.14, fogC = c(170, 210, 255), ground = { 129871, 240 }, hazard = "chill",
        len = 1500, finale = "n_kelthuzad", berserk = 600, target = target, tokens = { "ring" },
        bosses = { "n_sapphiron", "n_kelthuzad" },
        blurb = "The Chill fills while you stand in the cold. Fire and braziers thaw you.",
        waves = waves({ { 0, 120, { n_soldier = 8 } }, { 120, 300, { n_soldier = 6, n_soulweaver = 2, n_gargoyle = 1 } },
            { 300, 600, { n_soldier = 5, n_soulweaver = 2, n_gargoyle = 2, n_abom = 1 } }, { 600, 900, { n_soldier = 5, n_soulweaver = 3, n_gargoyle = 2, n_abom = 2 } },
            { 900, 9999, { n_soldier = 6, n_soulweaver = 3, n_abom = 2 } } }),
        events = {
            { t = 300, kind = "storm", msg = "Blizzards sweep the lair." },
            { t = 450, kind = "elite", mob = "n_guardian", msg = "A Guardian of Icecrown wakes." },
            { t = 600, kind = "boss", mob = "n_sapphiron", msg = "Sapphiron descends!" },
            { t = 780, kind = "elite", mob = "n_guardian", n = 2, msg = "Two Guardians of Icecrown wake." },
            { t = 900, kind = "finale", mob = "n_kelthuzad", msg = "Kel'Thuzad: the seven alcoves open!" } } },
}
D.STAGE_ORDER = { "arachnid", "plague", "military", "construct", "frost" }
D.WINGS = { "arachnid", "plague", "military", "construct" }

---------------------------------------------------------------------------
-- Tier 3: a token per master (the raid's own drops), nine make the set
---------------------------------------------------------------------------
D.T3_SLOTS = {
    { id = "head", name = "Head", plate = "inv_misc_desecrated_platehelm", cloth = "inv_misc_desecrated_clothhelm" },
    { id = "shoulders", name = "Shoulders", plate = "inv_misc_desecrated_plateshoulder", cloth = "inv_misc_desecrated_clothshoulder" },
    { id = "chest", name = "Chest", plate = "inv_misc_desecrated_platechest", cloth = "inv_misc_desecrated_clothchest" },
    { id = "wrist", name = "Wrists", plate = "inv_misc_desecrated_platebracer", cloth = "inv_misc_desecrated_clothbracer" },
    { id = "hands", name = "Hands", plate = "inv_misc_desecrated_plategloves", cloth = "inv_misc_desecrated_clothglove" },
    { id = "waist", name = "Waist", plate = "inv_misc_desecrated_platebelt", cloth = "inv_misc_desecrated_clothbelt" },
    { id = "legs", name = "Legs", plate = "inv_misc_desecrated_platepants", cloth = "inv_misc_desecrated_clothpants" },
    { id = "feet", name = "Feet", plate = "inv_misc_desecrated_plateboots", cloth = "inv_misc_desecrated_clothboots" },
    { id = "ring", name = "Ring", plate = "inv_jewelry_ring_51naxxramas", cloth = "inv_jewelry_ring_51naxxramas" },
}
D.T3_SLOT = {}
for i, s in ipairs(D.T3_SLOTS) do D.T3_SLOT[s.id] = s s.i = i end
D.T3_FROM = { n_thaddius = "head", n_patchwerk = "shoulders", n_grobbulus = "shoulders", n_mograine = "chest", n_korthazz = "chest", n_blaumeux = "chest", n_zeliek = "chest",
    n_anub = "wrist", n_faerlina = "wrist", n_maexxna = "hands", n_noth = "waist", n_heigan = "waist", n_loatheb = "legs", n_razuvious = "feet", n_gothik = "feet",
    n_kelthuzad = "ring", n_gluth = "any" }
D.T3_SETS = {
    PALADIN = { name = "Redemption Armor", sprite = "t3_paladin", kind = "plate" },
    MAGE = { name = "Frostfire Regalia", sprite = "t3_mage", kind = "cloth" },
    WARRIOR = { name = "Dreadnaught's Battlegear", sprite = "t3_warrior", kind = "plate" },
}
D.T3_DROP = 0.25          -- a master killed again: one in four drops its token
function D.T3Icon(cls, slot) local s, set = D.T3_SLOT[slot], D.T3_SETS[cls] return s and (set and set.kind == "cloth" and s.cloth or s.plate) end

---------------------------------------------------------------------------
-- relics: real Naxxramas drops, from the boss that holds them; a coffer offers three, you Need one, it lasts the run
---------------------------------------------------------------------------
local W, Y = "|cffffffff", "|r"
D.RELICS = {
    remorse = { name = "Widow's Remorse", icon = "inv_sword_60", from = { "n_faerlina" }, desc = W .. "+25%" .. Y .. " damage to elites and bosses." },
    fang = { name = "Maexxna's Fang", icon = "inv_knife_1h_stratholme_d_01", from = { "n_anub", "n_maexxna" }, desc = "Your hits poison: " .. W .. "6" .. Y .. " a second for 4 s, stacking three times." },
    wraith = { name = "Wraith Blade", icon = "inv_sword_11", from = { "n_anub", "n_maexxna" }, desc = W .. "+12%" .. Y .. " critical strike chance." },
    frigid = { name = "Noth's Frigid Heart", icon = "inv_offhand_naxxramas_04", from = { "n_noth" }, desc = "Every " .. W .. "8" .. Y .. " s a frost nova bursts round you and freezes for " .. W .. "1.5" .. Y .. " s." },
    reflection = { name = "Loatheb's Reflection", icon = "inv_trinket_naxxramas05", from = { "n_heigan", "n_noth" }, desc = "Critical strikes deal " .. W .. "40%" .. Y .. " more." },
    brimstone = { name = "Brimstone Staff", icon = "inv_staff_13", from = { "n_heigan" }, desc = "Elites burn the ground where they die: " .. W .. "8" .. Y .. " a tick for 6 s." },
    ashbringer = { name = "Corrupted Ashbringer", icon = "inv_sword_2h_ashbringercorrupt", from = { "n_gothik", "n_razuvious" }, desc = "One in ten of the dead you slay rises to fight for you for " .. W .. "6" .. Y .. " s." },
    bearer = { name = "The Plague Bearer", icon = "inv_shield_27", from = { "n_patchwerk" }, desc = W .. "-15%" .. Y .. " damage taken, and a hit is blocked every " .. W .. "10" .. Y .. " s." },
    collar = { name = "Gluth's Missing Collar", icon = "inv_jewelry_necklace_27naxxramas", from = { "n_gluth" }, desc = "Pick things up from " .. W .. "40%" .. Y .. " further, and each rune heals " .. W .. "1" .. Y .. "." },
    spire = { name = "Spire of Twilight", icon = "inv_staff_31", from = { "n_grobbulus", "n_gluth" }, desc = "Every fifth hit chains lightning through " .. W .. "4" .. Y .. " foes." },
    eye = { name = "Eye of Diminution", icon = "inv_trinket_naxxramas02", from = { "n_patchwerk", "n_grobbulus" }, desc = "Every " .. W .. "12" .. Y .. " s the dead near you lose track of you for a second." },
    righteye = { name = "Sapphiron's Right Eye", icon = "inv_offhand_naxxramas_02", from = { "n_sapphiron" }, desc = W .. "+20%" .. Y .. " frost damage; your chills and freezes last " .. W .. "30%" .. Y .. " longer." },
    essence = { name = "The Restrained Essence of Sapphiron", icon = "inv_trinket_naxxramas06", from = { "n_sapphiron" }, desc = "Every " .. W .. "30" .. Y .. " s: " .. W .. "+30%" .. Y .. " damage for 20 s." },
    kingsfall = { name = "Kingsfall", icon = "inv_weapon_shortblade_37", legend = true, desc = "After " .. W .. "50" .. Y .. " kills in 10 s, your spells recharge twice as fast for 8 s." },
    menethil = { name = "Might of Menethil", icon = "inv_mace_25", legend = true, desc = "Foes below " .. W .. "45%" .. Y .. " health die to your hits outright; elites take double." },
    hungering = { name = "The Hungering Cold", icon = "inv_sword_62", legend = true, desc = W .. "15%" .. Y .. " of your hits freeze the foe for 2 s. Frozen foes take double." },
    hammer = { name = "Hammer of the Twisting Nether", icon = "inv_mace_27", legend = true, desc = "Healthstones heal twice as much, then " .. W .. "5%" .. Y .. " a second for 4 s." },
}
D.RELIC_ORDER = { "remorse", "fang", "wraith", "frigid", "reflection", "brimstone", "ashbringer", "bearer", "collar", "spire", "eye", "righteye", "essence", "kingsfall", "menethil", "hungering", "hammer" }
D.RELIC_LEGEND = { "kingsfall", "menethil", "hungering", "hammer" }
D.RELIC_FROM = {}
for _, id in ipairs(D.RELIC_ORDER) do local r = D.RELICS[id] r.id = id for _, b in ipairs(r.from or {}) do D.RELIC_FROM[b] = D.RELIC_FROM[b] or {} table.insert(D.RELIC_FROM[b], id) end end
D.RELIC_LEGEND_CHANCE = 0.15       -- once Kel'Thuzad has fallen to you: a coffer may hold one of his weapons (any stage)

---------------------------------------------------------------------------
-- Frozen Runes and Frost Resistance (Craftsman Wilhelm, Light's Hope)
---------------------------------------------------------------------------
D.FROST_RES = { { runes = 4, gold = 200 }, { runes = 6, gold = 400 }, { runes = 8, gold = 700 }, { runes = 10, gold = 1100 }, { runes = 14, gold = 1600 } }
D.FROST_RES_SLOW = 0.15            -- each rank: the Chill fills 15% slower
D.RUNES_ELITE, D.RUNES_BOSS, D.RUNES_SAPPHIRON = 1, 2, 5

---------------------------------------------------------------------------
-- the weekly challenge gets three Naxxramas rule sets
---------------------------------------------------------------------------
table.insert(D.CHALLENGES, { id = "hundred", name = "The Hundred Club", stage = "frost", noFrostRes = true, desc = "The Frostwyrm Lair with Frost Resistance switched off." })
table.insert(D.CHALLENGES, { id = "rush", name = "Quarter Rush", stage = "construct", rush = 0.6, desc = "The Construct Quarter, its bosses come 40% sooner." })
table.insert(D.CHALLENGES, { id = "dance", name = "Dance Night", stage = "plague", dance = true, desc = "The Plague Quarter, and the floor erupts for the whole run." })

-- the Argent Dawn: Naxxramas opens with a first win now; Exalted's place goes to Wilhelm's favour
for _, st in ipairs(D.STANDINGS) do
    for i = #(st.rewards or {}), 1, -1 do
        local r = st.rewards[i]
        if r.kind == "stage" and r.name == "Naxxramas" then
            st.rewards[i] = { kind = "perk", id = "runes2", icon = "inv_misc_rune_09", name = "Wilhelm's Favour", desc = "Frozen Runes count double." }
        end
    end
end

---------------------------------------------------------------------------
-- achievements (a Naxxramas tab before the Feats of Strength)
---------------------------------------------------------------------------
table.insert(D.ACH_CATS, #D.ACH_CATS, { id = "naxx", name = "Naxxramas", icon = "inv_trinket_naxxramas06" })
local function nx(r) return r.nx or {} end
local function slain(k) return function(r) return r.slain and r.slain[k] end end
local NAXX_ACH = {
    { id = "nx_arachnid", pts = 10, icon = "spell_nature_web", name = "The Arachnid Quarter", desc = "Slay Maexxna.", run = slain("n_maexxna") },
    { id = "nx_plague", pts = 10, icon = "spell_shadow_plaguecloud", name = "The Plague Quarter", desc = "Slay Loatheb.", run = slain("n_loatheb") },
    { id = "nx_military", pts = 10, icon = "ability_mount_undeadhorse", name = "The Military Quarter", desc = "Slay the Four Horsemen.", run = function(r) return nx(r).horsemen end },
    { id = "nx_construct", pts = 10, icon = "spell_nature_lightningoverload", name = "The Construct Quarter", desc = "Slay Thaddius.", run = slain("n_thaddius") },
    { id = "nx_sapphiron", pts = 15, icon = "spell_frost_freezingbreath", name = "Sapphiron's Demise", desc = "Slay Sapphiron.", run = slain("n_sapphiron") },
    { id = "nx_fall", pts = 25, icon = "spell_shadow_raisedead", name = "The Fall of Naxxramas", desc = "Slay Kel'Thuzad.", run = slain("n_kelthuzad") },
    { id = "nx_arachno", pts = 15, icon = "ability_hunter_pet_spider", name = "Arachnophobia", desc = "Slay Maexxna within 60 seconds of her arrival.", run = function(r) return nx(r).maexxnaFast end },
    { id = "nx_momma", pts = 15, icon = "spell_holy_holybolt", name = "Momma Said Knock You Out", desc = "Slay Faerlina without killing a Worshipper.", run = function(r) return r.slain and r.slain.n_faerlina and not nx(r).worshipKilled end },
    { id = "nx_dance", pts = 20, icon = "spell_nature_wispsplode", name = "The Safety Dance", desc = "Slay Heigan without an eruption touching you.", run = function(r) return r.slain and r.slain.n_heigan and not nx(r).erupted end },
    { id = "nx_spore", pts = 15, icon = "inv_misc_monsterclaw_04", name = "Spore Loser", desc = "Slay Loatheb without killing a spore.", run = function(r) return r.slain and r.slain.n_loatheb and not nx(r).sporeKilled end },
    { id = "nx_curse", pts = 10, icon = "spell_shadow_curseofmannoroth", name = "Lifted Curse", desc = "Break every Curse of the Plaguebringer on Noth.", run = function(r) return r.slain and r.slain.n_noth and (nx(r).cursesBroken or 0) > 0 and not nx(r).curseBurst end },
    { id = "nx_shelter", pts = 10, icon = "spell_holy_divineintervention", name = "Shelter from the Shout", desc = "Take no Disrupting Shout from Razuvious.", run = function(r) return r.slain and r.slain.n_razuvious and not nx(r).shouted end },
    { id = "nx_gate", pts = 15, icon = "spell_shadow_twilight", name = "A Quiet Gate", desc = "Slay Gothik with fewer than 30 ghosts crossing the gate.", run = function(r) return r.slain and r.slain.n_gothik and (nx(r).ghosts or 0) < 30 end },
    { id = "nx_together", pts = 25, icon = "spell_shadow_deathcoil", name = "And They Would All Go Down Together", desc = "The Four Horsemen fall within 15 seconds of each other.", run = function(r) return nx(r).together end },
    { id = "nx_werk", pts = 15, icon = "ability_warrior_rampage", name = "Make Quick Werk of Him", desc = "Slay Patchwerk within 60 seconds.", run = function(r) return nx(r).werkFast end },
    { id = "nx_bomb", pts = 15, icon = "spell_shadow_abominationexplosion", name = "Bomb Squad", desc = "Slay 100 of the dead with one Mutating Injection.", run = function(r) return (nx(r).bombBest or 0) >= 100 end },
    { id = "nx_glutton", pts = 10, icon = "spell_shadow_carrionswarm", name = "Gluttony Denied", desc = "Slay Gluth before he eats a single Zombie Chow.", run = function(r) return r.slain and r.slain.n_gluth and not nx(r).ate end },
    { id = "nx_shocking", pts = 20, icon = "spell_nature_lightningoverload", name = "Shocking!", desc = "Slay Thaddius without being struck by his chain lightning.", run = function(r) return r.slain and r.slain.n_thaddius and not nx(r).shocked end },
    { id = "nx_hundred", pts = 25, icon = "spell_frost_frostarmor02", name = "The Hundred Club", desc = "Slay Sapphiron with Frost Resistance rank 1 or lower.", run = function(r) return r.slain and r.slain.n_sapphiron and (r.frostRes or 0) <= 1 end },
    { id = "nx_cantget", pts = 20, icon = "inv_misc_head_undead_01", name = "Just Can't Get Enough", desc = "Slay 18 Unstoppable Abominations in Kel'Thuzad's first phase.", run = function(r) return (nx(r).ktAboms or 0) >= 18 end },
    { id = "nx_desecrated", pts = 25, icon = "inv_misc_desecrated_platechest", name = "Desecrated", desc = "Complete a Tier 3 set.", prof = function(d, S) local n = S:T3Sets() return n >= 1, n, 1 end },
    { id = "nx_trinity", pts = 50, icon = "inv_misc_desecrated_clothhelm", name = "Desecrated Trinity", desc = "Complete all three Tier 3 sets.", prof = function(d, S) local n = S:T3Sets() return n >= 3, n, 3 end },
    { id = "nx_warden", pts = 10, icon = "inv_misc_rune_09", name = "Frost Warden", desc = "Learn every rank of Frost Resistance.", prof = function(d) local n = d.frostRes or 0 return n >= #D.FROST_RES, n, #D.FROST_RES end },
    { id = "nx_relics", pts = 15, icon = "inv_mace_27", name = "Relic Hunter", desc = "Need 15 different Necropolis relics.", prof = function(d) local n = 0 for _ in pairs(d.relicsSeen or {}) do n = n + 1 end return n >= 15, min(n, 15), 15 end },
    { id = "nx_bane", pts = 0, icon = "spell_shadow_raisedead", name = "Kel'Thuzad's Bane", desc = "Feat of Strength: the first in the guild to slay Kel'Thuzad.", feat = true, cat = "feats" },
    { id = "nx_hardest", pts = 0, icon = "ability_warrior_battleshout", name = "The Hardest Fall", desc = "Feat of Strength: the first in the guild to slay Kel'Thuzad as a Warrior.", feat = true, cat = "feats" },
}
for _, a in ipairs(NAXX_ACH) do
    a.cat = a.cat or "naxx"
    table.insert(D.ACHIEVEMENTS, a)
    D.ACH[a.id] = a
end

if DisasterZoneBoot and DisasterZoneBoot.Run("DisasterZone_HoldTheLine/Data.lua", ...) then return end -- DisasterZone_HoldTheLine/Data.lua
-- ns.HTLData: Hold the Line's tables - the Scourge of the Plaguelands, the waves and the clock's events, the spells,
-- blessings and legendaries, the classes. A port of the mockup (dev/art/casc/survivors_mockup/game.js): same numbers.
local addonName, ns = ...

local D = {}
ns.HTLData = D

D.GAME_ID = "holdtheline"
D.VW, D.VH = 840, 472            -- the mockup's view in world units (the panel shows VH tall, as wide as it is)
D.S = 0.6                        -- (sprite render px -> world units; Art.lua's frames are already in world units)
D.MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"
D.ASSETS = 15                    -- art pack with these media

D.MOBS = {
    rat      = { name = "Plagued Rat", hp = 5, spd = 74, dmg = 4, r = 8, xp = 1, ichor = "blood", mass = 0.5 },
    ghoul    = { name = "Rotting Ghoul", hp = 12, spd = 50, dmg = 6, r = 12, xp = 1, ichor = "rot", mass = 1 },
    skeleton = { name = "Skeletal Warrior", hp = 20, spd = 42, dmg = 8, r = 12, xp = 2, ichor = "bone", mass = 1 },
    bat      = { name = "Vile Bat", hp = 7, spd = 92, dmg = 5, r = 10, xp = 1, ichor = "blood", fly = true, mass = 0.6 },
    hound    = { name = "Plaguehound", hp = 16, spd = 108, dmg = 7, r = 12, xp = 2, ichor = "blood", mass = 0.9 },
    ghoul2   = { name = "Ghoul Ravener", hp = 44, spd = 56, dmg = 10, r = 15, xp = 3, ichor = "rot", mass = 1.6 },
    banshee  = { name = "Wailing Banshee", hp = 28, spd = 40, dmg = 9, r = 12, xp = 3, ichor = "spirit", ghost = true, mass = 0.8 },
    fiend    = { name = "Crypt Fiend", hp = 90, spd = 36, dmg = 14, r = 20, xp = 6, ichor = "rot", mass = 3 },
    horror   = { name = "Stitched Horror", hp = 700, spd = 40, dmg = 20, r = 24, xp = 40, ichor = "rot", elite = true, mass = 8 },
    abom     = { name = "Unstoppable Abomination", hp = 4200, spd = 42, dmg = 26, r = 34, xp = 120, ichor = "rot", boss = true, mass = 40 },
    lich     = { name = "Lich", hp = 6400, spd = 46, dmg = 24, r = 22, xp = 200, ichor = "spirit", boss = true, mass = 40 },
    -- the small encounters' own (Encounters.lua): a courier that runs from you, a packleader with a purse
    courier  = { name = "Plagued Courier", sprite = "ghoul", hp = 45, spd = 1, dmg = 0, r = 12, xp = 2, ichor = "rot", mass = 1, scale = 0.95, tint = { 1, 0.86, 0.5 } },
    packleader = { name = "Ravener Packleader", sprite = "ghoul2", hp = 240, spd = 58, dmg = 12, r = 18, xp = 10, ichor = "rot", mass = 3, scale = 1.35, tint = { 0.78, 1, 0.66 } },
    reaper   = { name = "The Pale Rider", hp = 1e9, spd = 92, dmg = 9999, r = 22, xp = 0, ichor = "spirit", reaper = true, mass = 99 },
}
for k, m in pairs(D.MOBS) do m.key = k end

-- the ground stains (decal colour) and the gore thrown (particle tint), 0..1
D.ICHOR = { blood = { 70 / 255, 10 / 255, 12 / 255 }, rot = { 34 / 255, 44 / 255, 16 / 255 }, bone = { 58 / 255, 52 / 255, 46 / 255 }, spirit = { 30 / 255, 34 / 255, 52 / 255 } }
D.GORE = { blood = { 150 / 255, 18 / 255, 20 / 255 }, rot = { 74 / 255, 104 / 255, 34 / 255 }, bone = { 214 / 255, 204 / 255, 180 / 255 }, spirit = { 150 / 255, 160 / 255, 1 } }

D.WAVES = {
    { 0, 60, { rat = 3, ghoul = 6 } },
    { 60, 150, { rat = 2, ghoul = 6, skeleton = 3 } },
    { 150, 300, { ghoul = 5, skeleton = 4, bat = 4 } },
    { 300, 420, { ghoul = 4, skeleton = 3, hound = 4, ghoul2 = 1 } },
    { 420, 600, { ghoul = 3, skeleton = 3, banshee = 3, ghoul2 = 2, fiend = 1 } },
    { 600, 780, { skeleton = 4, banshee = 3, ghoul2 = 3, fiend = 2, hound = 2 } },
    { 780, 900, { ghoul2 = 4, fiend = 3, banshee = 3, skeleton = 3, bat = 2 } },
}
-- (weights as ordered lists: pairs() order is not stable, a seeded run must pick the same way every time)
for _, w in ipairs(D.WAVES) do
    local list = {}
    for _, k in ipairs({ "rat", "ghoul", "skeleton", "bat", "hound", "ghoul2", "banshee", "fiend" }) do
        if w[3][k] then list[#list + 1] = { k, w[3][k] } end
    end
    w.list = list
end
D.EVENTS = {
    { t = 150, kind = "ring", msg = "The dead encircle you!" },
    { t = 300, kind = "boss", mob = "abom", msg = "An Unstoppable Abomination lumbers out of the fog!" },
    { t = 420, kind = "elite", mob = "horror", msg = "A Stitched Horror joins the hunt." },
    { t = 510, kind = "swarm", msg = "Vile bats blot out the sky!" },
    { t = 600, kind = "boss", mob = "lich", msg = "A Lich rises from the necropolis!" },
    { t = 720, kind = "elite", mob = "horror", msg = "Two Stitched Horrors break loose.", n = 2 },
    { t = 840, kind = "dark", msg = "The necropolis darkens the sky..." },
    { t = 900, kind = "reaper", msg = "The Pale Rider comes." },
}
-- the crowd the spawner keeps up: a trickle at the start (a fifth of it), the full crowd by 2:00
function D.Target(t)
    local k = t < 120 and 0.22 + 0.78 * t / 120 or 1
    return math.min(330, (34 + t * 0.5 + (t > 300 and (t - 300) * 0.16 or 0)) * k)
end

-- school colours (tints for the client's white effect textures)
local function c(r, g, b) return { r / 255, g / 255, b / 255 } end
D.C = {
    GOLD = c(255, 206, 110), HOLY = c(255, 236, 170), ICE = c(140, 205, 255), FROST = c(190, 232, 255), ARC = c(205, 120, 255),
    FIRE = c(255, 130, 40), EMBER = c(255, 190, 90), GREEN = c(140, 255, 120), WHITE = { 1, 1, 1 },
    BLOOD = c(150, 14, 10), DUST = c(190, 165, 120), STORM = c(150, 215, 255),
}
D.SCHOOL_COL = { holy = c(255, 224, 138), frost = c(168, 228, 255), arcane = c(240, 176, 255), fire = c(255, 176, 96), phys = { 1, 1, 1 }, nature = c(170, 225, 255) }
D.SCHOOL_NAME = { holy = "Holy", frost = "Frost", arcane = "Arcane", fire = "Fire", phys = "Physical", nature = "Nature" }

local min = math.min
local W, Y = "|cffffffff", "|r"          -- (numbers white in the yellow tooltip text)
local function fx1(v) return string.format("%.1f", v) end
D.SPELLS = {
    consecration = { name = "Consecration", cls = "PALADIN", school = "holy", icon = "spell_holy_innerfire", max = 5,
        desc = function(r) return "Holy ground follows you, searing the dead for " .. W .. (5 + 3 * r) .. Y .. " every half second. Radius " .. W .. (64 + 8 * r) .. Y .. "." end },
    avenger = { name = "Avenger's Shield", cls = "PALADIN", school = "holy", icon = "spell_holy_avengersshield", max = 5,
        desc = function(r) return "Hurls a blazing shield that ricochets through " .. W .. (2 + r) .. Y .. " enemies for " .. W .. (18 + 6 * r) .. Y .. " each, then returns." end },
    exorcism = { name = "Exorcism", cls = "PALADIN", school = "holy", icon = "spell_holy_excorcism_02", max = 5, boss = 1.5,
        desc = function(r) return "A pillar of Light smites the " .. W .. (1 + math.floor(r / 2)) .. Y .. " strongest undead for " .. W .. (44 + 16 * r) .. Y .. ", half again on a boss." end },
    holywrath = { name = "Holy Wrath", cls = "PALADIN", school = "holy", icon = "spell_holy_excorcism", max = 5,
        desc = function(r) return "Every " .. W .. fx1(7 - 0.6 * r) .. Y .. " s a wave of Light hurls the dead back and stuns them for " .. W .. (12 + 6 * r) .. Y .. "." end },
    frostbolt = { name = "Frostbolt", cls = "MAGE", school = "frost", icon = "spell_frost_frostbolt02", max = 5,
        desc = function(r) return "Fires " .. W .. (1 + math.floor((r - 1) / 2)) .. Y .. " bolt(s) at the nearest foe for " .. W .. (12 + 5 * r) .. Y .. ", piercing " .. W .. (1 + math.floor(r / 3)) .. Y .. " and chilling." end },
    arcane = { name = "Arcane Missiles", cls = "MAGE", school = "arcane", icon = "spell_nature_starfall", max = 5,
        desc = function(r) return W .. (3 + r) .. Y .. " seeking missiles every 2 s, " .. W .. (6 + 2 * r) .. Y .. " each." end },
    nova = { name = "Frost Nova", cls = "MAGE", school = "frost", icon = "spell_frost_frostnova", max = 5,
        desc = function(r) return "Encases everything within " .. W .. (110 + 15 * r) .. Y .. " in ice for " .. W .. fx1(1.5 + 0.3 * r) .. Y .. " s." end },
    blizzard = { name = "Blizzard", cls = "MAGE", school = "frost", icon = "spell_frost_icestorm", max = 5,
        desc = function(r) return "Calls " .. W .. (1 + math.floor(r / 2)) .. Y .. " blizzard(s) on the horde: " .. W .. (5 + 2 * r) .. Y .. " every 0.3 s, slowing." end },
    flamestrike = { name = "Flamestrike", cls = "MAGE", school = "fire", icon = "spell_fire_selfdestruct", max = 5,
        desc = function(r) return "Strikes the densest pack for " .. W .. (30 + 12 * r) .. Y .. " and leaves the ground burning." end },
    cleave = { name = "Cleave", cls = "WARRIOR", school = "phys", icon = "ability_warrior_cleave", max = 5,
        desc = function(r) return "Swings through everything in front of you for " .. W .. (12 + 5 * r) .. Y .. ". Reach " .. W .. (72 + 6 * r) .. Y .. "." end },
    thunderclap = { name = "Thunder Clap", cls = "WARRIOR", school = "phys", icon = "ability_thunderclap", max = 5,
        desc = function(r) return "Slams the ground: " .. W .. (8 + 3 * r) .. Y .. " to all within " .. W .. (100 + 10 * r) .. Y .. ", slowed for " .. W .. fx1(2.5 + 0.3 * r) .. Y .. " s." end },
    charge = { name = "Charge", cls = "WARRIOR", school = "phys", icon = "ability_warrior_charge", max = 5,
        desc = function(r) return "Charges into the thickest pack: " .. W .. (20 + 8 * r) .. Y .. " and a " .. W .. fx1(0.6 + 0.1 * r) .. Y .. " s stun where you land." end },
    execute = { name = "Execute", cls = "WARRIOR", school = "phys", icon = "inv_sword_48", max = 5,
        desc = function(r) return "Hacks at the " .. W .. (1 + math.floor(r / 2)) .. Y .. " most wounded in reach for " .. W .. (24 + 8 * r) .. Y .. "; under " .. W .. "35%" .. Y .. " health they die outright (elites and bosses take " .. W .. (60 + 25 * r) .. Y .. ")." end },
    grenade = { name = "Thorium Grenade", school = "fire", icon = "inv_misc_bomb_08", max = 5, gadget = true,
        desc = function(r) return "Lobs " .. W .. (1 + math.floor(r / 2)) .. Y .. " grenade(s) that blast for " .. W .. (20 + 8 * r) .. Y .. "." end },
    dragonling = { name = "Arcanite Dragonling", school = "fire", icon = "inv_misc_head_dragon_bronze", max = 5, gadget = true,
        desc = function(r) return W .. (1 + math.floor(r / 2)) .. Y .. " fire orb(s) circle you, burning for " .. W .. (8 + 4 * r) .. Y .. " on touch." end },
}
D.SPELL_ORDER = { "consecration", "avenger", "exorcism", "holywrath", "frostbolt", "arcane", "nova", "blizzard", "flamestrike", "cleave", "thunderclap", "charge", "execute", "grenade", "dragonling" }
D.CD = {
    avenger = function(r) return 2.4 - 0.15 * r end, exorcism = function(r) return 3.4 - 0.25 * r end, holywrath = function(r) return 7 - 0.6 * r end,
    frostbolt = function(r) return 1.05 - 0.07 * r end, arcane = function() return 2 end, nova = function(r) return 6 - 0.5 * r end,
    blizzard = function(r) return 5 - 0.4 * r end, flamestrike = function(r) return 4.5 - 0.35 * r end, grenade = function(r) return 3 - 0.25 * r end,
    cleave = function(r) return 1.4 - 0.07 * r end, thunderclap = function(r) return 7 - 0.45 * r end, charge = function(r) return 7 - 0.6 * r end,
    execute = function(r) return 2.6 - 0.2 * r end,
}
D.PASSIVES = {
    might = { name = "Blessing of Might", icon = "spell_holy_fistofjustice", tint = c(255, 120, 60), desc = function(r) return W .. "+" .. (10 * r) .. "%" .. Y .. " damage." end },
    crusader = { name = "Seal of the Crusader", icon = "spell_holy_holysmite", tint = c(255, 220, 120), desc = function(r) return "Spells recharge " .. W .. (8 * r) .. "%" .. Y .. " faster." end },
    intellect = { name = "Arcane Intellect", icon = "spell_holy_magicalsentry", tint = c(150, 170, 255), desc = function(r) return W .. "+" .. (10 * r) .. "%" .. Y .. " experience, " .. W .. "+" .. (4 * r) .. "%" .. Y .. " area." end },
    fortitude = { name = "Power Word: Fortitude", icon = "spell_holy_wordfortitude", tint = c(230, 240, 255), desc = function(r) return W .. "+" .. (25 * r) .. Y .. " maximum health." end },
    cheetah = { name = "Aspect of the Cheetah", icon = "ability_mount_jungletiger", tint = c(255, 220, 120), desc = function(r) return W .. "+" .. (8 * r) .. "%" .. Y .. " movement speed." end },
    lootarang = { name = "Loot-A-Rang", icon = "inv_misc_enggizmos_17", tint = c(140, 255, 140), desc = function(r) return "Pick things up from " .. W .. (30 * r) .. "%" .. Y .. " further away." end },
    motw = { name = "Mark of the Wild", icon = "spell_nature_regeneration", tint = c(220, 140, 255), desc = function(r) return "Regenerate " .. W .. fx1(0.3 * r) .. Y .. " health a second, " .. W .. "+" .. (r * 3) .. "%" .. Y .. " armor." end },
}
D.PASSIVE_ORDER = { "might", "crusader", "intellect", "fortitude", "cheetah", "lootarang", "motw" }
D.LEGEND = {
    consecration = { need = "crusader", name = "Ashbringer", icon = "inv_sword_2h_ashbringercorrupt",
        desc = "Consecration becomes the Ashbringer's light: twice the reach, the dead under 20% health are purged outright, and the blade burns in your hands." },
    cleave = { need = "might", name = "Thunderfury, Blessed Blade of the Windseeker", icon = "inv_sword_39",
        desc = "Cleave becomes Thunderfury: a wider, longer swing, and every swing calls lightning that leaps through the pack, slowing what it strikes." },
    arcane = { need = "intellect", name = "Atiesh, Greatstaff of the Guardian", icon = "inv_staff_medivh",
        desc = "Arcane Missiles never stop: a Karazhan portal opens behind you and pours out a missile every 0.2 s." },
}
-- every spell has a legendary: its spell at rank 5 and its blessing in a slot, then a coffer offers it
D.LEGEND.avenger = { need = "fortitude", name = "Bulwark of Azzinoth", icon = "inv_shield_52",
    desc = "Avenger's Shield throws two shields at once, and every hit shields you for 10% of the damage it deals." }
D.LEGEND.exorcism = { need = "intellect", name = "Benediction", icon = "inv_staff_30",
    desc = "Every pillar leaves holy ground behind it for two seconds that burns the dead, and each one heals you a little." }
D.LEGEND.holywrath = { need = "might", name = "Sulfuras, Hand of Ragnaros", icon = "inv_hammer_unique_sulfuras",
    desc = "Holy Wrath's wave becomes a ring of fire: everything it pushes back burns for three seconds." }
D.LEGEND.frostbolt = { need = "crusader", name = "Tear of the Frozen Throne", icon = "inv_wand_22",
    desc = "Frostbolt fires a fan of five, and every bolt freezes what it pierces." }
D.LEGEND.nova = { need = "fortitude", name = "Heart of Northrend", icon = "inv_misc_orb_05",
    desc = "Frozen enemies shatter when they die, hurting and freezing the dead around them." }
D.LEGEND.blizzard = { need = "motw", name = "Staff of Endless Winter", icon = "inv_staff_13",
    desc = "One great blizzard travels with you wherever you go." }
D.LEGEND.flamestrike = { need = "might", name = "Ember of Al'ar", icon = "inv_staff_54",
    desc = "Every Flamestrike calls a phoenix that dives through the densest pack and sets it alight." }
D.LEGEND.thunderclap = { need = "fortitude", name = "Earthshaker", icon = "inv_hammer_04",
    desc = "Every Thunder Clap cracks the ground: a second ring of stone follows and stuns everything it reaches." }
D.LEGEND.charge = { need = "cheetah", name = "Warglaive of Azzinoth", icon = "inv_weapon_glave_01",
    desc = "Charge twice in a row, leaving fel fire burning along the way." }
D.LEGEND.execute = { need = "crusader", name = "Gorehowl", icon = "inv_axe_62",
    desc = "Every execute gives back half its cooldown, and the dead under 50% health die outright." }
D.LEGEND.grenade = { need = "lootarang", name = "Gnomish Death Ray", icon = "inv_gizmo_09",
    desc = "A death ray sweeps through the nearest pack in place of grenades." }
D.LEGEND.dragonling = { need = "motw", name = "Onyxia's Brood", icon = "inv_misc_head_dragon_01",
    desc = "Three whelps fly with you and breathe fire on whatever comes close." }

-- the late game: 4 spell and 4 blessing slots; a level waits min(cap, (level - from) * per) s after the last one (the
-- XP meanwhile waits on the bar); with a full build every level is a Paragon level (+1% damage, no picker)
D.SLOTS = { spells = 4, blessings = 4 }
D.PACE = { from = 10, per = 0.5, cap = 12 }
D.PARAGON = 0.01
D.HP_GROW = 0.55             -- (the dead's health grows by this share every 5 minutes of a run)

-- rank 3 of every spell is a path: one of two, kept for the run (ranks 4 and 5 grow it). [1] = path "a", [2] = "b".
D.PATHS = {
    consecration = { { name = "Hallowed Ground", desc = "The holy ground spreads " .. W .. "25%" .. Y .. " wider, and burns " .. W .. "25%" .. Y .. " softer." },
        { name = "Searing Ground", desc = "Every second an enemy stays in it, it burns " .. W .. "15%" .. Y .. " harder (up to " .. W .. "+150%" .. Y .. ")." } },
    avenger = { { name = "Ricochet", desc = W .. "+2" .. Y .. " bounces and half again the leap, each hit " .. W .. "20%" .. Y .. " lighter." },
        { name = "Shield Burst", desc = "Every hit bursts in Light: " .. W .. "25%" .. Y .. " of it to all within " .. W .. "60" .. Y .. "; one bounce less." } },
    exorcism = { { name = "Lingering Light", desc = "Pillars stay " .. W .. "1.5" .. Y .. " s and burn whatever walks into them." },
        { name = "Many Pillars", desc = W .. "+2" .. Y .. " pillars, each " .. W .. "30%" .. Y .. " weaker." } },
    holywrath = { { name = "Righteous Wave", desc = "Pushes twice as far and stuns " .. W .. "0.5" .. Y .. " s longer." },
        { name = "Hammer of Wrath", desc = "Anything but a boss under " .. W .. "25%" .. Y .. " health that the wave touches dies." } },
    frostbolt = { { name = "Splitting Ice", desc = "On its first hit a bolt splits into " .. W .. "three" .. Y .. "." },
        { name = "Shatter", desc = "Frozen targets take " .. W .. "three times" .. Y .. " the damage." } },
    arcane = { { name = "Barrage", desc = W .. "+3" .. Y .. " missiles a volley, with a shorter reach." },
        { name = "Arcane Focus", desc = "Every missile seeks the toughest foe in sight." } },
    nova = { { name = "Deep Freeze", desc = "Frozen enemies take " .. W .. "50%" .. Y .. " more from everything." },
        { name = "Ice Barrier", desc = "The nova also goes off by itself when you are hit (once every " .. W .. "4" .. Y .. " s)." } },
    blizzard = { { name = "Arctic Winds", desc = "Blizzards drift after you." },
        { name = "Great Blizzard", desc = "One storm twice the size, cast a little less often." } },
    flamestrike = { { name = "Pyroclasm", desc = "Every strike stuns for " .. W .. "1" .. Y .. " s." },
        { name = "Wildfire", desc = "The burning ground spreads wider and burns twice as long." } },
    cleave = { { name = "Sweeping Strikes", desc = "Every third swing is a full circle." },
        { name = "Deep Wounds", desc = "Every swing makes them bleed for " .. W .. "3" .. Y .. " s." } },
    thunderclap = { { name = "Thunderous Reach", desc = "The clap reaches " .. W .. "40%" .. Y .. " further." },
        { name = "Shockwave", desc = "A wave in front of you instead: twice the reach, and it stuns for " .. W .. "1" .. Y .. " s." } },
    charge = { { name = "Intercept", desc = "Two charges before the cooldown." },
        { name = "Juggernaut", desc = "You land with a slam that throws the pack back, " .. W .. "30%" .. Y .. " harder." } },
    execute = { { name = "Sudden Death", desc = "A kill sometimes (" .. W .. "1 in 6" .. Y .. ") readies Execute again." },
        { name = "Bloodthirst", desc = "Every execute heals you " .. W .. "3%" .. Y .. "." } },
    grenade = { { name = "Cluster Bomb", desc = "Each grenade breaks into " .. W .. "three" .. Y .. " small ones." },
        { name = "The Big One", desc = "One huge blast, half as often." } },
    dragonling = { { name = "Brood", desc = W .. "+2" .. Y .. " orbs, each a little weaker." },
        { name = "Dragon's Breath", desc = "A single dragonling that breathes a cone of fire every " .. W .. "1.2" .. Y .. " s." } },
}

D.CLASSES = {
    PALADIN = { name = "Paladin", sprite = "paladin", start = "consecration", color = { 0.96, 0.55, 0.73 }, hp = 140, speed = 124 },
    MAGE = { name = "Mage", sprite = "mage", start = "frostbolt", color = { 0.41, 0.8, 0.94 }, hp = 110, speed = 132,
        dmg = 0.9 },          -- (four slots focus the Mage's ranks early: -10% damage, from the balance pass)
    -- the hardest: everything it does is at arm's length, so it has to stand in the horde (plate takes 5% off)
    WARRIOR = { name = "Warrior", sprite = "warrior", legendSprite = "warrior_tf", start = "cleave", color = { 0.78, 0.61, 0.43 }, hp = 150, speed = 118, armor = 0.05, melee = true,
        dmg = 1.2 },          -- (four slots cost the melee most: +20% damage, from the balance pass)
}
D.STAGE = { name = "Eastern Plaguelands", tint = c(222, 212, 226), dark = c(16, 10, 26), darkA = 0.4, fog = 0.15 }

-- The Argent Dawn's talents: bought between runs with the gold you bank, kept for every run and every class (the
-- account's saved data). Three trees on the classic talent frame's own paintings; a tier opens once TIER_GATE points
-- per tier above it are spent in that tree; a rank costs its tier's price. Engine.lua reads them as run.tal[id].
D.TIER_GATE = 4
D.TIER_COST = { 40, 80, 140, 220, 400 }
D.TALENT_TREES = {
    { id = "zeal", name = "Zeal", art = "PaladinCombat", color = c(255, 140, 64), blurb = "Hit harder, cast faster." },
    { id = "bulwark", name = "Bulwark", art = "PaladinProtection", color = c(140, 190, 255), blurb = "Take less, live longer." },
    { id = "fortune", name = "Fortune", art = "PriestDiscipline", color = c(255, 210, 90), blurb = "More gold, better choices." },
}
local function pct(v) return W .. v .. "%" .. Y end
D.TALENTS = {
    -- Zeal
    { id = "might", tree = "zeal", tier = 1, col = 2, max = 5, icon = "spell_holy_sealofmight", name = "Might of the Dawn", desc = function(r) return "Your spells deal " .. pct(3 * r) .. " more damage." end },
    { id = "swift", tree = "zeal", tier = 1, col = 3, max = 3, icon = "spell_nature_bloodlust", name = "Swift Retribution", desc = function(r) return "Your spells recharge " .. pct(3 * r) .. " faster." end },
    { id = "area", tree = "zeal", tier = 2, col = 1, max = 3, icon = "spell_holy_holynova", name = "Sanctified Ground", desc = function(r) return "Your spells reach " .. pct(4 * r) .. " further." end },
    { id = "crit", tree = "zeal", tier = 2, col = 3, max = 3, icon = "ability_criticalstrike", name = "Vindication", desc = function(r) return pct(3 * r) .. " more chance for a spell to strike twice as hard." end },
    { id = "slayer", tree = "zeal", tier = 3, col = 2, max = 3, icon = "spell_holy_blessingofstrength", name = "Scourgebane", desc = function(r) return "Elites and bosses take " .. pct(6 * r) .. " more damage from you." end },
    { id = "purpose", tree = "zeal", tier = 4, col = 2, max = 1, icon = "spell_holy_divinepurpose", name = "Divine Purpose", desc = function() return "Your class's first spell starts at " .. W .. "rank 2" .. Y .. "." end },
    { id = "wrath", tree = "zeal", tier = 5, col = 2, max = 1, icon = "spell_holy_avenginewrath", name = "Avenging Wrath", desc = function() return "Every " .. W .. "45" .. Y .. " seconds the Light fills you: " .. pct(40) .. " more damage for " .. W .. "8" .. Y .. " seconds." end },
    -- Bulwark
    { id = "tough", tree = "bulwark", tier = 1, col = 2, max = 5, icon = "spell_holy_devotion", name = "Toughness", desc = function(r) return W .. "+" .. (10 * r) .. Y .. " maximum health." end },
    { id = "devotion", tree = "bulwark", tier = 1, col = 3, max = 3, icon = "spell_holy_devotionaura", name = "Devotion", desc = function(r) return "You take " .. pct(2 * r) .. " less damage." end },
    { id = "loh", tree = "bulwark", tier = 2, col = 2, max = 3, icon = "spell_holy_layonhands", name = "Healing Light", desc = function(r) return "Regenerate " .. W .. fx1(0.2 * r) .. Y .. " health a second." end },
    { id = "freedom", tree = "bulwark", tier = 2, col = 3, max = 3, icon = "ability_rogue_sprint", name = "Freedom", desc = function(r) return pct(3 * r) .. " movement speed." end },
    { id = "unbreak", tree = "bulwark", tier = 3, col = 2, max = 2, icon = "spell_holy_divineintervention", name = "Unbreakable", desc = function(r) return "After a hit you can't be hurt for " .. W .. fx1(0.15 * r) .. Y .. " seconds longer." end },
    { id = "ardent", tree = "bulwark", tier = 3, col = 3, max = 2, icon = "spell_holy_ardentdefender", name = "Ardent Defender", desc = function(r) return "Under " .. pct(30) .. " health you take " .. pct(15 * r) .. " less damage." end },
    { id = "favor", tree = "bulwark", tier = 4, col = 2, max = 2, icon = "inv_stone_04", name = "Guardian's Favor", desc = function(r) return "Healthstones heal " .. pct(50 * r) .. " more." end },
    { id = "redemption", tree = "bulwark", tier = 5, col = 2, max = 1, icon = "spell_holy_resurrection", name = "Redemption", desc = function() return "Once a run, death lets go of you: you rise with " .. pct(50) .. " health." end },
    -- Fortune
    { id = "greed", tree = "fortune", tier = 1, col = 2, max = 5, icon = "inv_misc_coin_02", name = "Greed", desc = function(r) return "Gold you pick up is worth " .. pct(10 * r) .. " more." end },
    { id = "magnet", tree = "fortune", tier = 1, col = 3, max = 3, icon = "inv_misc_gear_01", name = "Magnetism", desc = function(r) return "Pick things up from " .. pct(10 * r) .. " further away." end },
    { id = "wisdom", tree = "fortune", tier = 2, col = 2, max = 3, icon = "spell_holy_sealofwisdom", name = "Wisdom", desc = function(r) return pct(5 * r) .. " experience." end },
    { id = "reroll", tree = "fortune", tier = 2, col = 3, max = 2, icon = "inv_misc_book_09", name = "Second Thoughts", desc = function(r) return W .. "+" .. r .. Y .. " reroll" .. (r > 1 and "s" or "") .. " a run." end },
    { id = "banish", tree = "fortune", tier = 3, col = 2, max = 2, icon = "spell_holy_sealofsacrifice", name = "Exile", desc = function(r) return W .. "+" .. r .. Y .. " banish" .. (r > 1 and "es" or "") .. " a run." end },
    { id = "lucky", tree = "fortune", tier = 3, col = 3, max = 2, icon = "inv_misc_bag_10", name = "Lucky Find", desc = function(r) return "The fallen drop gold " .. pct(25 * r) .. " more often." end },
    { id = "headstart", tree = "fortune", tier = 4, col = 2, max = 1, icon = "spell_holy_surgeoflight", name = "Head Start", desc = function() return "Each run begins with a blessing to choose." end },
    { id = "hoard", tree = "fortune", tier = 5, col = 2, max = 1, icon = "inv_misc_ornatebox", name = "Argent Hoard", desc = function() return "Scourge Coffers hold " .. W .. "one more" .. Y .. " reward." end },
}
D.TALENT = {}
for _, t in ipairs(D.TALENTS) do D.TALENT[t.id] = t end

-- Achievements (HoldTheLine/Social.lua earns them; the guild hears who was first). run(r, final): checked through a
-- real run and at its end; prof(d): checked against your record (d = Games:GetData) - returns done[, have, need].
D.ACH_CATS = {
    { id = "survival", name = "Survival", icon = "spell_holy_holybolt" },
    { id = "slaughter", name = "Slaughter", icon = "inv_misc_bone_humanskull_01" },
    { id = "legend", name = "Legendaries", icon = "inv_sword_39" },
    { id = "classes", name = "Classes", icon = "ability_warrior_battleshout" },
    { id = "dawn", name = "Argent Dawn", icon = "inv_misc_token_argentdawn" },
    { id = "talents", name = "Talents", icon = "spell_holy_sealofmight" },
    { id = "feats", name = "Feats of Strength", icon = "spell_holy_avenginewrath" },
}
local function won(r, final) return final and r.over == "victory" end
local function standingAch(at) return function(d) return (d.rep or 0) >= at, min(d.rep or 0, at), at end end
D.ACHIEVEMENTS = {
    { id = "first5", cat = "survival", pts = 10, icon = "spell_holy_holybolt", name = "First Light", desc = "Hold the line until 5:00.", run = function(r) return r.t >= 300 end },
    { id = "first10", cat = "survival", pts = 15, icon = "spell_holy_layonhands", name = "Holding Fast", desc = "Hold the line until 10:00.", run = function(r) return r.t >= 600 end },
    { id = "line", cat = "survival", pts = 25, icon = "spell_holy_avenginewrath", name = "The Line Held", desc = "Survive until the Pale Rider comes at 15:00.", run = won },
    { id = "untouch", cat = "survival", pts = 15, icon = "spell_holy_divineintervention", name = "Untouchable", desc = "Reach 3:00 without being hit.", run = function(r) return r.t >= 180 and (not r.firstHit or r.firstHit >= 180) end },
    { id = "thread", cat = "survival", pts = 20, icon = "spell_holy_ashestoashes", name = "By a Thread", desc = "After 10:00, live through a moment under 15% health.", run = function(r) return r.thread end },
    { id = "onespell", cat = "survival", pts = 25, icon = "spell_holy_innerfire", name = "One Spell Wonder", desc = "Reach 10:00 with only your class's first spell.", run = function(r) return r.t >= 600 and #r.order <= 1 end },
    { id = "k1000", cat = "slaughter", pts = 10, icon = "inv_misc_bone_humanskull_01", name = "A Thousand Fall", desc = "Slay 1,000 in one run.", run = function(r) return r.kills >= 1000 end },
    { id = "k5000", cat = "slaughter", pts = 20, icon = "ability_warrior_rampage", name = "The Reaping", desc = "Slay 5,000 in one run.", run = function(r) return r.kills >= 5000 end },
    { id = "life10k", cat = "slaughter", pts = 10, icon = "ability_creature_disease_02", name = "Ten Thousand Fall", desc = "Slay 10,000 of the Scourge across all runs.", prof = function(d) return (d.kills or 0) >= 10000, d.kills or 0, 10000 end },
    { id = "life100k", cat = "slaughter", pts = 25, icon = "spell_shadow_deathcoil", name = "The Scourge Remembers", desc = "Slay 100,000 across all runs.", prof = function(d) return (d.kills or 0) >= 100000, d.kills or 0, 100000 end },
    { id = "abom", cat = "slaughter", pts = 10, icon = "inv_misc_head_undead_01", name = "Stitches Unstitched", desc = "Slay the Unstoppable Abomination.", run = function(r) return r.slain and r.slain.abom end },
    { id = "lich", cat = "slaughter", pts = 15, icon = "spell_shadow_raisedead", name = "Phylactery Shattered", desc = "Slay the Lich.", run = function(r) return r.slain and r.slain.lich end },
    { id = "ash", cat = "legend", pts = 20, icon = "inv_sword_2h_ashbringercorrupt", name = "The Ashbringer Reborn", desc = "Awaken the Ashbringer.", run = function(r) return r.legend.consecration end },
    { id = "atiesh", cat = "legend", pts = 20, icon = "inv_staff_medivh", name = "Guardian's Staff", desc = "Awaken Atiesh, Greatstaff of the Guardian.", run = function(r) return r.legend.arcane end },
    { id = "tf", cat = "legend", pts = 20, icon = "inv_sword_39", name = "Blessed Blade of the Windseeker", desc = "Awaken Thunderfury.", run = function(r) return r.legend.cleave end },
    { id = "arms", cat = "legend", pts = 25, icon = "spell_holy_championsbond", name = "Arms of Legend", desc = "Awaken all three legendaries.", prof = function(d) local n = (d.ach.ash and 1 or 0) + (d.ach.atiesh and 1 or 0) + (d.ach.tf and 1 or 0) return n == 3, n, 3 end },
    { id = "winpal", cat = "classes", pts = 25, icon = "spell_holy_sealofmight", name = "Hand of the Light", desc = "Win a run as a Paladin.", run = function(r, f) return won(r, f) and r.cls == "PALADIN" end },
    { id = "winmage", cat = "classes", pts = 25, icon = "spell_frost_frostbolt02", name = "Archmage of the Line", desc = "Win a run as a Mage.", run = function(r, f) return won(r, f) and r.cls == "MAGE" end },
    { id = "winwar", cat = "classes", pts = 50, icon = "ability_warrior_battleshout", name = "The Hardest Line", desc = "Win a run as a Warrior.", run = function(r, f) return won(r, f) and r.cls == "WARRIOR" end },
    { id = "paths", cat = "classes", pts = 20, icon = "ability_warrior_cleave", name = "Three Paths", desc = "Reach 10:00 with each class.", prof = function(d) local n = 0 for _, c in ipairs({ "PALADIN", "MAGE", "WARRIOR" }) do if (d.clsBest[c] or 0) >= 600 then n = n + 1 end end return n == 3, n, 3 end },
    { id = "friendly", cat = "dawn", pts = 5, icon = "inv_misc_token_argentdawn", name = "Friend of the Dawn", desc = "Reach Friendly with the Argent Dawn.", prof = standingAch(3000) },
    { id = "honored", cat = "dawn", pts = 10, icon = "inv_misc_token_argentdawn2", name = "Honored by the Dawn", desc = "Reach Honored with the Argent Dawn.", prof = standingAch(9000) },
    { id = "revered", cat = "dawn", pts = 15, icon = "inv_misc_token_argentdawn3", name = "Revered by the Dawn", desc = "Reach Revered with the Argent Dawn.", prof = standingAch(21000) },
    { id = "exalted", cat = "dawn", pts = 25, icon = "inv_jewelry_talisman_07", name = "Champion of the Dawn", desc = "Reach Exalted with the Argent Dawn.", prof = standingAch(42000) },
    { id = "stones", cat = "dawn", pts = 10, icon = "inv_misc_bone_humanskull_01", name = "Scourgestone Collector", desc = "Hand in 100 Scourgestones.", prof = function(d) return (d.stones or 0) >= 100, d.stones or 0, 100 end },
    { id = "weekly", cat = "dawn", pts = 25, icon = "inv_misc_token_argentdawn2", name = "Champion of the Week", desc = "Win a weekly challenge.", prof = function(d) return (d.chWins or 0) >= 1, d.chWins or 0, 1 end },
    { id = "lesson", cat = "talents", pts = 5, icon = "inv_misc_book_09", name = "First Lesson", desc = "Learn a talent.", prof = function(d) return next(d.talents) ~= nil end },
    { id = "tree", cat = "talents", pts = 15, icon = "spell_holy_sealofmight", name = "Master of One", desc = "Learn every rank in one tree.", prof = function(d, S) return S:TreesFull() >= 1, S:TreesFull(), 1 end },
    { id = "trees", cat = "talents", pts = 25, icon = "spell_holy_championsbond", name = "Argent Scholar", desc = "Learn every rank in all three trees.", prof = function(d, S) return S:TreesFull() >= 3, S:TreesFull(), 3 end },
    { id = "hoard", cat = "talents", pts = 10, icon = "inv_misc_coin_02", name = "Hoarder", desc = "Carry 5,000 gold home across all runs.", prof = function(d) return (d.goldTotal or 0) >= 5000, d.goldTotal or 0, 5000 end },
    { id = "palefirst", cat = "feats", pts = 0, icon = "spell_shadow_deathcoil", name = "Pale Rider, Pale Horse", desc = "Feat of Strength: the first in the guild to hold all fifteen minutes.", feat = true },
}
D.ACH = {}
for _, a in ipairs(D.ACHIEVEMENTS) do D.ACH[a.id] = a end

-- The weekly challenge: one rule set a week (in turn), one seed for the whole guild, its own board. The leader when
-- the week turns is its champion: +1,000 Argent Dawn and a title for the next week.
D.CHALLENGES = {
    { id = "hardest", name = "The Hardest Line", cls = "WARRIOR", noLegend = true, desc = "Warriors only. No Thunderfury: the run ends when it would awaken." },
    { id = "frostfire", name = "Frost and Fire", cls = "MAGE", noRerolls = true, desc = "Mages only. No rerolls, no banishes." },
    { id = "onespell", name = "One Spell", oneSpell = true, desc = "Any class. You keep your first spell; level-ups offer blessings only." },
    { id = "glass", name = "Glass Cannon", hpMul = 0.5, dmgMul = 1.5, desc = "Any class. Half the health, half again the damage." },
    { id = "light", name = "Light's Chosen", cls = "PALADIN", noRerolls = true, noLegend = true, desc = "Paladins only. No rerolls, no banishes, no Ashbringer." },
}
D.CHALLENGE_REP, D.CHALLENGE_TITLE = 1000, "the Unyielding"

-- The Argent Dawn: what each standing brings (stages are announced before they exist: "soon").
D.STANDINGS = {
    { name = "Neutral", at = 0 },
    { name = "Friendly", at = 3000, rewards = {
        { kind = "stage", icon = "spell_shadow_raisedead", name = "Stage II \194\183 Stratholme", desc = "The burning city and Baron Rivendare.", soon = true },
        { kind = "perk", id = "manual", icon = "inv_misc_book_09", name = "Argent Field Manual", desc = "One more reroll every run." } } },
    { name = "Honored", at = 9000, rewards = {
        { kind = "look", id = "tabard", icon = "inv_shirt_guildtabard_01", name = "Tabard of the Argent Dawn", desc = "Your hero wears the Dawn's colours." },
        { kind = "perk", id = "seal", icon = "inv_jewelry_talisman_07", name = "Seal of the Dawn", desc = "Every run starts with a blessing to choose." } } },
    { name = "Revered", at = 21000, rewards = {
        { kind = "stage", icon = "inv_misc_head_undead_01", name = "Stage III \194\183 Silithus", desc = "The Qiraji swarm.", soon = true },
        { kind = "look", id = "aura", icon = "spell_holy_crusaderstrike", name = "Champion's Aura", desc = "A ring of the Dawn's light under your hero." } } },
    { name = "Exalted", at = 42000, rewards = {
        { kind = "title", id = "champion", icon = "spell_holy_championsbond", name = "Champion of the Dawn", desc = "Shown beside your name on every board." },
        { kind = "stage", icon = "spell_nature_timestop", name = "Naxxramas", desc = "The necropolis. Kel'Thuzad waits.", soon = true } } },
}
D.STONE_REP = 25            -- a Scourgestone handed in (elites drop one, bosses three)

D.ICON = function(name) return "Interface\\Icons\\" .. name end

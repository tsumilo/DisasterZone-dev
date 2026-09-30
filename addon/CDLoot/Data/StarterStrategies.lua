-- CDLoot: starter strategies for the strategy boards (Addendum K). An author loads one from Raids > Strategies
-- ("Starter") and gets it as an unsaved draft to adjust and Save; nothing is shared until then.
-- Same shape as a strategy (Core/Strategy.lua) with two conveniences resolved when loaded:
--   page.map = a Data/RaidMaps.lua file name (instead of the map id m)
--   "@Creature Name" as an icon key = that creature's portrait from Data/BossPortraits.lua
-- Board coordinates are 1000 x 666 over the page's (zoomed) map; the rooms were measured on the floor maps.
local _, ns = ...
ns.Data = ns.Data or {}

ns.Data.StarterStrategies = {
    ---------------------------------------------------------------------------------------------------------------
    -- High King Maulgar: five ogres, each tanked by the class that counters it. Kill order Skull > Cross > Square >
    -- Moon > Triangle (Blindeye, Olm, Kiggler, Krosh, Maulgar).
    ---------------------------------------------------------------------------------------------------------------
    ["GruulsLair:Maulgar"] = {
        n = "25 standard",
        p = {
            {
                id = "p1", n = "Council", map = "Gruul", vx = 547, vy = 600, vz = 300,
                no = "Maulgar: Arcing Smash (frontal), Whirlwind (melee out), Mighty Blow knocks the MT back: the OT "
                    .. "picks him up. At 50% he charges and fears (Intimidating Shout). Blindeye: shields and "
                    .. "heals, interrupt every Prayer of Healing. Olm: Death Coil, summons Fel Stalkers. "
                    .. "Krosh: Spell Shield (Spellsteal it), Blast Wave within 15 yards. Kiggler: Greater Polymorph, "
                    .. "Arcane Explosion close to him.",
                e = {
                    { t = "z", s = "c", x = 575, y = 380, w = 130, h = 120, c = 4, l = "Raid + healers" },
                    { t = "z", s = "c", x = 370, y = 460, w = 150, h = 150, c = 1, l = "Blast Wave: stay out", ln = "kr.1" },
                    { t = "z", s = "r", x = 745, y = 585, w = 220, h = 120, c = 5, ln = "kg.1" },
                    { t = "z", s = "c", x = 625, y = 265, w = 120, h = 120, c = 8, ln = "ol.1" },
                    { t = "i", x = 505, y = 170, i = "@High King Maulgar", z = 48, rm = 4, l = "High King Maulgar", ln = "tk.1.1" },
                    { t = "i", x = 375, y = 250, i = "@Blindeye the Seer", z = 44, rm = 8, l = "Blindeye the Seer", ln = "tk.3.1" },
                    { t = "i", x = 625, y = 240, i = "@Olm the Summoner", z = 44, rm = 7, l = "Olm the Summoner", ln = "ol.1.1" },
                    { t = "i", x = 370, y = 405, i = "@Krosh Firehand", z = 44, rm = 5, l = "Krosh Firehand", ln = "kr.1.1" },
                    { t = "i", x = 700, y = 560, i = "@Kiggler the Crazed", z = 44, rm = 6, l = "Kiggler the Crazed", ln = "kg.1.1" },
                    { t = "a", x = 900, y = 655, x2 = 640, y2 = 470, c = 9, h = true },
                    { t = "x", x = 880, y = 470, l = "Pull: misdirects", c = 9, z = 2 },
                    { t = "x", x = 790, y = 628, l = "Ranged only (Arcane Explosion)", c = 5, z = 1 },
                    { t = "x", x = 230, y = 630, l = "Kill: Skull > Cross > Square > Moon > Triangle", c = 6, z = 2 },
                },
                k = {
                    { id = "tk", n = "Tanks", r = 3, cl = 3,
                      c = { { t = "p", n = "Tank", f = "tank" }, { t = "g", n = "Ogre" } },
                      d = { [1] = { [2] = { i = "@High King Maulgar", l = "Maulgar (MT)" } },
                            [2] = { [2] = { i = "@High King Maulgar", l = "Maulgar (OT, Mighty Blow)" } },
                            [3] = { [2] = { i = "@Blindeye the Seer", l = "Blindeye" } } } },
                    { id = "kr", n = "Krosh (mage tank)", r = 2, i = "cls:MAGE",
                      c = { { t = "p", n = "Mage", f = "MAGE" }, { t = "x", n = "Job" } },
                      d = { [1] = { [2] = "Spellsteal Spell Shield, tank at range" },
                            [2] = { [2] = "Backup: take over if the tank dies" } } },
                    { id = "ol", n = "Olm (warlock tanks)", r = 2, i = "cls:WARLOCK",
                      c = { { t = "p", n = "Warlock", f = "WARLOCK" }, { t = "x", n = "Job" } },
                      d = { [1] = { [2] = "Tank Olm (Searing Pain)" },
                            [2] = { [2] = "Tank Olm, banish / enslave Fel Stalkers" } } },
                    { id = "kg", n = "Kiggler (ranged tanks)", r = 3, i = "cls:HUNTER",
                      c = { { t = "p", n = "Tank", f = "HUNTER,DRUID" }, { t = "x", n = "Job" } },
                      d = { [1] = { [2] = "Tank Kiggler at max range" },
                            [2] = { [2] = "Take over when polymorphed" },
                            [3] = { [2] = "Take over when polymorphed" } } },
                    { id = "bi", n = "Blindeye interrupts", r = 3, i = "i:Ability_Kick",
                      c = { { t = "o" }, { t = "p", n = "Interrupt", f = "ROGUE,WARRIOR,SHAMAN,MAGE" },
                            { t = "g", n = "On" } },
                      d = { [1] = { [3] = { i = "@Blindeye the Seer", l = "Prayer of Healing" } },
                            [2] = { [3] = { i = "@Blindeye the Seer", l = "Prayer of Healing" } },
                            [3] = { [3] = { i = "@Blindeye the Seer", l = "Heal / backup" } } } },
                    { id = "md", n = "Misdirects", r = 2, i = "i:Ability_Hunter_Misdirection",
                      c = { { t = "o" }, { t = "p", n = "Hunter", f = "HUNTER" }, { t = "g", n = "Onto" } },
                      d = { [1] = { [3] = { i = "@High King Maulgar", l = "Maulgar ->", s = "tk.1.1" } },
                            [2] = { [3] = { i = "@Blindeye the Seer", l = "Blindeye ->", s = "tk.3.1" } } } },
                    { id = "hl", n = "Healers", r = 6, i = "role:healer",
                      c = { { t = "p", n = "Healer", f = "healer" }, { t = "g", n = "Heals" } },
                      d = { [1] = { [2] = { s = "tk.1.1" } }, [2] = { [2] = { s = "tk.2.1" } },
                            [3] = { [2] = { s = "tk.3.1" } }, [4] = { [2] = { s = "kr.1.1" } },
                            [5] = { [2] = { l = "Olm warlocks", s = "ol.1.1" } },
                            [6] = { [2] = { l = "Raid (Kiggler side)" } } } },
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust",
                      c = { { t = "p", n = "Shaman", f = "SHAMAN" }, { t = "x", n = "When" } },
                      d = { [1] = { [2] = "On Blindeye, right after the pull" } } },
                },
            },
        },
    },

    ---------------------------------------------------------------------------------------------------------------
    -- The Illidari Council: four bosses on one health pool, each tanked apart (Gathios' auras help the others),
    -- Zerevor by a mage at range, Malande interrupted, the raid split into two zones away from Flamestrike /
    -- Blizzard. Modelled on <Casual Disaster>'s own sheet: 4 misdirects, curses, innervates, Power Infusion.
    ---------------------------------------------------------------------------------------------------------------
    ["BlackTemple:Council"] = {
        n = "25 standard",
        p = {
            {
                id = "p1", n = "Council", map = "BT06", vx = 471, vy = 505, vz = 360,
                no = "One shared health pool: damage any of them. Gathios: Consecration, Hammer of Justice, "
                    .. "BoP / Spell Warding on the others, auras: keep him apart. Zerevor: Flamestrike, Blizzard, "
                    .. "Arcane Explosion near him: a mage tanks him at range. Malande: interrupt Circle of Healing "
                    .. "and Divine Wrath. Veras: Deadly Poison, then Vanish and Envenom. Nature Protection Potions help.",
                e = {
                    -- the raid, split in two zones
                    { t = "z", s = "r", x = 290, y = 455, w = 200, h = 110, c = 3, l = "Zone 1", ln = "zn.1" },
                    { t = "z", s = "r", x = 710, y = 455, w = 200, h = 110, c = 5, l = "Zone 2", ln = "zn.2" },
                    -- what to move out of (examples of where they land)
                    { t = "z", s = "c", x = 375, y = 340, w = 100, h = 100, c = 1, l = "Move out: Flamestrike" },
                    { t = "z", s = "c", x = 620, y = 340, w = 100, h = 100, c = 2, l = "Move out: Blizzard" },
                    { t = "z", s = "c", x = 493, y = 200, w = 170, h = 110, c = 6, l = "Consecration", ln = "tk.1" },
                    -- the council, each where its tank takes it
                    { t = "i", x = 493, y = 138, i = "@Gathios the Shatterer", z = 44, rm = 8, l = "Gathios", ln = "tk.1.1" },
                    { t = "i", x = 820, y = 330, i = "@Veras Darkshadow", z = 44, rm = 7, l = "Veras", ln = "tk.2.1" },
                    { t = "i", x = 175, y = 330, i = "@Lady Malande", z = 44, rm = 1, l = "Malande", ln = "tk.3.1" },
                    { t = "i", x = 500, y = 590, i = "@High Nethermancer Zerevor", z = 44, rm = 6, l = "Zerevor", ln = "ze.1.1" },
                    -- the pull
                    { t = "a", x = 500, y = 660, x2 = 500, y2 = 450, c = 9, h = true },
                    { t = "x", x = 640, y = 640, l = "Pull: 4 misdirects", c = 9, z = 2 },
                    { t = "x", x = 190, y = 640, l = "Major Nature Protection Potion", c = 4, z = 1 },
                },
                k = {
                    { id = "tk", n = "Tanks", r = 3, cl = 3,
                      c = { { t = "p", n = "Tank", f = "tank" }, { t = "g", n = "Boss" } },
                      d = { [1] = { [2] = { i = "@Gathios the Shatterer", l = "Gathios (MT)" } },
                            [2] = { [2] = { i = "@Veras Darkshadow", l = "Veras" } },
                            [3] = { [2] = { i = "@Lady Malande", l = "Malande" } } } },
                    { id = "ze", n = "Zerevor (mage tank)", r = 2, i = "cls:MAGE",
                      c = { { t = "p", n = "Mage", f = "MAGE" }, { t = "x", n = "Job" } },
                      d = { [1] = { [2] = "Tank at range; Dampen Magic pre-pull" },
                            [2] = { [2] = "Backup: take over if the tank dies" } } },
                    { id = "hl", n = "Healers", r = 8, i = "role:healer",
                      c = { { t = "p", n = "Healer", f = "healer" }, { t = "g", n = "Heals" } },
                      d = { [1] = { [2] = { s = "tk.1.1" } }, [2] = { [2] = { s = "tk.2.1" } },
                            [3] = { [2] = { s = "tk.3.1" } }, [4] = { [2] = { s = "ze.1.1" } },
                            [5] = { [2] = { l = "Zone 1" } }, [6] = { [2] = { l = "Zone 2" } },
                            [7] = { [2] = { l = "Flex" } }, [8] = { [2] = { l = "Flex 2" } } } },
                    { id = "zn", n = "Zones", r = 8,
                      c = { { t = "p", n = "Zone 1" }, { t = "p", n = "Zone 2" } } },
                    { id = "mi", n = "Malande interrupts", r = 3, i = "i:Ability_Kick",
                      c = { { t = "o" }, { t = "p", n = "Interrupt", f = "ROGUE,WARRIOR,SHAMAN,MAGE" },
                            { t = "g", n = "On" } },
                      d = { [1] = { [3] = { i = "@Lady Malande", l = "Circle of Healing, Divine Wrath" } },
                            [2] = { [3] = { i = "@Lady Malande", l = "Backup (when she has BoP)" } },
                            [3] = { [3] = { i = "@Lady Malande", l = "Backup" } } } },
                    { id = "cu", n = "Curses", r = 2, i = "cls:WARLOCK",
                      c = { { t = "p", n = "Warlock", f = "WARLOCK" }, { t = "g", n = "Curse" } },
                      d = { [1] = { [2] = { i = "@Lady Malande", l = "Curse of Tongues" } },
                            [2] = { [2] = { i = "@Veras Darkshadow", l = "Curse of Weakness" } } } },
                    { id = "md", n = "Misdirects", r = 4, i = "i:Ability_Hunter_Misdirection",
                      c = { { t = "o" }, { t = "p", n = "Hunter", f = "HUNTER" }, { t = "g", n = "Onto" } },
                      d = { [1] = { [3] = { i = "@Gathios the Shatterer", l = "Gathios ->", s = "tk.1.1" } },
                            [2] = { [3] = { i = "@High Nethermancer Zerevor", l = "Zerevor ->", s = "ze.1.1" } },
                            [3] = { [3] = { i = "@Veras Darkshadow", l = "Veras ->", s = "tk.2.1" } },
                            [4] = { [3] = { i = "@Lady Malande", l = "Malande ->", s = "tk.3.1" } } } },
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust",
                      c = { { t = "p", n = "Shaman", f = "SHAMAN" }, { t = "x", n = "When" } },
                      d = { [1] = { [2] = "15 s after the pull (tanks settled)" } } },
                    { id = "pi", n = "Power Infusion", r = 2, i = "i:Spell_Holy_PowerInfusion",
                      c = { { t = "p", n = "Priest", f = "PRIEST" }, { t = "p", n = "Onto" } } },
                    { id = "iv", n = "Innervates", r = 3, i = "i:Spell_Nature_Lightning",
                      c = { { t = "p", n = "Druid", f = "DRUID" }, { t = "p", n = "Onto", f = "healer" } } },
                    { id = "nt", n = "Remember", r = 4,
                      c = { { t = "x" } },
                      d = { [1] = { [1] = "Keep Gathios away from the others (his auras)" },
                            [2] = { [1] = "Flamestrike / Blizzard: step out, stay in your zone" },
                            [3] = { [1] = "Veras vanishes: heal the Deadly Poison targets" },
                            [4] = { [1] = "Malande with BoP: interrupt, ignore her smites" } } },
                },
            },
        },
    },

    ---------------------------------------------------------------------------------------------------------------
    -- Gruul the Dragonkiller: a tank-and-spank that punishes standing together. Main tank, two Hurtful Strike
    -- soakers, and everyone else on a fixed spread spot for Ground Slam > Shatter.
    ---------------------------------------------------------------------------------------------------------------
    ["GruulsLair:Gruul"] = {
        n = "25 standard",
        p = {
            {
                id = "p1", n = "Gruul", map = "Gruul", vx = 208, vy = 300, vz = 320,
                no = "Growth: +15% damage every 30 seconds, so healing ramps up: kill him fast. Hurtful Strike hits the "
                    .. "second highest threat in melee range: the two soakers stay in melee, 2nd and 3rd on threat. "
                    .. "Ground Slam knocks everyone around; Shatter follows: be 15+ yards from everyone (go to your spot). "
                    .. "Cave In: move out of the dust. Reverberation silences: healers keep HoTs up.",
                e = {
                    { t = "z", s = "c", x = 478, y = 270, w = 190, h = 170, c = 3, l = "Tanks + melee", ln = "tk" },
                    { t = "i", x = 478, y = 250, i = "@Gruul the Dragonkiller", z = 56, rm = 8, l = "Gruul the Dragonkiller", ln = "tk.1.1" },
                    { t = "i", x = 420, y = 320, i = "role:tank", z = 26, ln = "tk.2.1" },
                    { t = "i", x = 540, y = 320, i = "role:tank", z = 26, ln = "tk.3.1" },
                    { t = "z", s = "c", x = 655, y = 250, w = 90, h = 90, c = 10, l = "Cave In" },
                    { t = "i", x = 500, y = 95, i = "rt1", z = 26, ln = "sp.1.2" },
                    { t = "i", x = 684, y = 160, i = "rt2", z = 26, ln = "sp.2.2" },
                    { t = "i", x = 760, y = 330, i = "rt3", z = 26, ln = "sp.3.2" },
                    { t = "i", x = 684, y = 490, i = "rt4", z = 26, ln = "sp.4.2" },
                    { t = "i", x = 500, y = 560, i = "rt5", z = 26, ln = "sp.5.2" },
                    { t = "i", x = 316, y = 490, i = "rt6", z = 26, ln = "sp.6.2" },
                    { t = "i", x = 240, y = 330, i = "rt7", z = 26, ln = "sp.7.2" },
                    { t = "i", x = 316, y = 160, i = "rt8", z = 26, ln = "sp.8.2" },
                    { t = "x", x = 500, y = 630, l = "Shatter: stand on your mark, 15+ yards apart", c = 6, z = 2 },
                },
                k = {
                    { id = "tk", n = "Tanks", r = 3, cl = 3,
                      c = { { t = "p", n = "Tank", f = "tank" }, { t = "g", n = "Job" } },
                      d = { [1] = { [2] = { i = "@Gruul the Dragonkiller", l = "Main tank" } },
                            [2] = { [2] = { i = "role:tank", l = "Hurtful Strike soak 1" } },
                            [3] = { [2] = { i = "role:tank", l = "Hurtful Strike soak 2" } } } },
                    { id = "hl", n = "Healers", r = 7, i = "role:healer",
                      c = { { t = "p", n = "Healer", f = "healer" }, { t = "g", n = "Heals" } },
                      d = { [1] = { [2] = { s = "tk.1.1" } }, [2] = { [2] = { s = "tk.1.1" } },
                            [3] = { [2] = { s = "tk.2.1" } }, [4] = { [2] = { s = "tk.3.1" } },
                            [5] = { [2] = { l = "Raid" } }, [6] = { [2] = { l = "Raid" } },
                            [7] = { [2] = { l = "Raid (Shatter / Cave In)" } } } },
                    { id = "sp", n = "Spread spots (ranged)", r = 8, i = "rt8",
                      c = { { t = "g", n = "Spot" }, { t = "p", n = "Player", f = "ranged,healer" } },
                      d = { [1] = { [1] = { i = "rt1", l = "Star" } }, [2] = { [1] = { i = "rt2", l = "Circle" } },
                            [3] = { [1] = { i = "rt3", l = "Diamond" } }, [4] = { [1] = { i = "rt4", l = "Triangle" } },
                            [5] = { [1] = { i = "rt5", l = "Moon" } }, [6] = { [1] = { i = "rt6", l = "Square" } },
                            [7] = { [1] = { i = "rt7", l = "Cross" } }, [8] = { [1] = { i = "rt8", l = "Skull" } } } },
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust",
                      c = { { t = "p", n = "Shaman", f = "SHAMAN" }, { t = "x", n = "When" } },
                      d = { [1] = { [2] = "On pull, once the main tank has threat" } } },
                    { id = "nt", n = "Remember", r = 4,
                      c = { { t = "x" } },
                      d = { [1] = { [1] = "Melee: spread behind him too, not in one clump" },
                            [2] = { [1] = "Soakers: stay 2nd / 3rd on threat, in melee" },
                            [3] = { [1] = "Ground Slam: walk to your mark before Shatter" },
                            [4] = { [1] = "Cave In: step out of the falling rocks" } } },
                },
            },
        },
    },
}

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
                    { id = "bi", n = "Blindeye interrupts", r = 3, i = "i:Ability_Kick", tr = "rot",
                      c = { { t = "o" }, { t = "p", n = "Interrupt", f = "ROGUE,WARRIOR,SHAMAN,MAGE" },
                            { t = "g", n = "On" } },
                      d = { [1] = { [3] = { i = "@Blindeye the Seer", l = "Prayer of Healing" } },
                            [2] = { [3] = { i = "@Blindeye the Seer", l = "Prayer of Healing" } },
                            [3] = { [3] = { i = "@Blindeye the Seer", l = "Heal / backup" } } } },
                    { id = "md", n = "Misdirects", r = 2, i = "i:Ability_Hunter_Misdirection", tr = "md",
                      c = { { t = "o" }, { t = "p", n = "Hunter", f = "HUNTER" }, { t = "g", n = "Onto" } },
                      d = { [1] = { [3] = { i = "@High King Maulgar", l = "Maulgar ->", s = "tk.1.1" } },
                            [2] = { [3] = { i = "@Blindeye the Seer", l = "Blindeye ->", s = "tk.3.1" } } } },
                    { id = "hl", n = "Healers", r = 6, i = "role:healer",
                      c = { { t = "p", n = "Healer", f = "healer" }, { t = "g", n = "Heals" } },
                      d = { [1] = { [2] = { s = "tk.1.1" } }, [2] = { [2] = { s = "tk.2.1" } },
                            [3] = { [2] = { s = "tk.3.1" } }, [4] = { [2] = { s = "kr.1.1" } },
                            [5] = { [2] = { l = "Olm warlocks", s = "ol.1.1" } },
                            [6] = { [2] = { l = "Raid (Kiggler side)" } } } },
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust", tr = "bl",
                      c = { { t = "p", n = "Shaman", f = "SHAMAN" }, { t = "x", n = "When" } },
                      d = { [1] = { [2] = "On Blindeye, right after the pull" } } },
                },
            },
        },
    },

    ---------------------------------------------------------------------------------------------------------------
    -- The Illidari Council: four bosses on one health pool, each tanked apart (Gathios' auras help the others),
    -- Zerevor by a mage at the entrance, Malande interrupted and meleed, the ranged split in two zones away from
    -- Flamestrike / Blizzard. Page 1 is the fight (every job placed on the map), page 2 the pull.
    -- Modelled on <Casual Disaster>'s own sheet: 4 misdirects, curses, innervates, Power Infusion, flex healers.
    ---------------------------------------------------------------------------------------------------------------
    ["BlackTemple:Council"] = {
        n = "25 standard",
        p = {
            {
                id = "p1", n = "Fight", map = "BT06", vx = 471, vy = 505, vz = 360,
                no = "One shared health pool: damage any of them. Gathios: Consecration, Hammer of Justice, "
                    .. "BoP / Spell Warding on the others, auras: keep him apart. Zerevor: Flamestrike, Blizzard, "
                    .. "Arcane Explosion near him: a mage tanks him at range. Malande: interrupt Circle of Healing "
                    .. "and Divine Wrath. Veras: Deadly Poison, then Vanish and Envenom. Nature Protection Potions help.",
                e = {
                    -- areas
                    { t = "z", s = "c", x = 493, y = 200, w = 170, h = 100, c = 6, l = "Consecration", ln = "tk.1.1" },
                    { t = "z", s = "c", x = 190, y = 340, w = 200, h = 170, c = 8, ln = "mi.2" },
                    { t = "z", s = "r", x = 300, y = 470, w = 200, h = 100, c = 3, l = "Zone 1", ln = "zn.1" },
                    { t = "z", s = "r", x = 700, y = 470, w = 200, h = 100, c = 5, l = "Zone 2", ln = "zn.2" },
                    { t = "z", s = "c", x = 500, y = 600, w = 150, h = 110, c = 1 },
                    { t = "x", x = 700, y = 625, l = "Arcane Explosion: only the mage", c = 1, z = 1 },
                    { t = "z", s = "c", x = 610, y = 330, w = 80, h = 80, c = 2, l = "Blizzard: out" },
                    { t = "z", s = "c", x = 380, y = 320, w = 80, h = 80, c = 1, l = "Flamestrike: out" },
                    -- the council where their tanks hold them (each shows its tank)
                    { t = "i", x = 493, y = 132, i = "@Gathios the Shatterer", z = 44, rm = 8, l = "Gathios", ln = "tk.1.1" },
                    { t = "i", x = 830, y = 320, i = "@Veras Darkshadow", z = 44, rm = 7, l = "Veras", ln = "tk.2.1" },
                    { t = "i", x = 175, y = 320, i = "@Lady Malande", z = 44, rm = 1, l = "Malande", ln = "tk.3.1" },
                    { t = "i", x = 500, y = 588, i = "@High Nethermancer Zerevor", z = 44, rm = 6, l = "Zerevor", ln = "tk.4.1" },
                    -- healers, each within reach of the one they heal and out of the danger areas
                    { t = "s", x = 395, y = 230, r = "hl.1.1" },
                    { t = "s", x = 730, y = 380, r = "hl.2.1" },
                    { t = "s", x = 320, y = 385, r = "hl.3.1" },
                    { t = "s", x = 640, y = 560, r = "hl.4.1" },
                    { t = "s", x = 225, y = 540, r = "hl.5.1" },
                    { t = "s", x = 775, y = 540, r = "hl.6.1" },
                    { t = "s", x = 430, y = 405, r = "hl.7.1" },
                    { t = "s", x = 570, y = 405, r = "hl.8.1" },
                    -- the interrupters on Malande, the backup mage, the warlocks within curse range
                    { t = "s", x = 115, y = 275, r = "mi.1.2" },
                    { t = "s", x = 270, y = 285, r = "mi.2.2" },
                    { t = "s", x = 115, y = 400, r = "mi.3.2" },
                    { t = "s", x = 395, y = 540, r = "tk.5.1" },
                    { t = "s", x = 365, y = 440, r = "cu.1.1" },
                    { t = "s", x = 640, y = 440, r = "cu.2.1" },
                    { t = "x", x = 500, y = 45, l = "Melee on Malande; ranged on Malande or Veras", c = 9, z = 2 },
                    { t = "x", x = 190, y = 640, l = "Major Nature Protection Potion", c = 4, z = 1 },
                    { t = "x", x = 110, y = 445, l = "Melee + kicks", c = 8, z = 2 },
                },
                k = {
                    { id = "tk", n = "Tanks", r = 5, cl = 3,
                      c = { { t = "p", n = "Tank", f = "tank" }, { t = "g", n = "Boss" } },
                      d = { [1] = { [2] = { i = "@Gathios the Shatterer", l = "Gathios (MT)" } },
                            [2] = { [2] = { i = "@Veras Darkshadow", l = "Veras" } },
                            [3] = { [2] = { i = "@Lady Malande", l = "Malande" } },
                            [4] = { [1] = { f = "MAGE" }, [2] = { i = "@High Nethermancer Zerevor", l = "Zerevor (mage, Dampen Magic)" } },
                            [5] = { [1] = { f = "MAGE" }, [2] = { i = "@High Nethermancer Zerevor", l = "Zerevor backup" } } } },
                    { id = "hl", n = "Healers", r = 8, i = "role:healer",
                      c = { { t = "p", n = "Healer", f = "healer" }, { t = "g", n = "Heals" } },
                      d = { [1] = { [2] = { l = "Gathios tank", s = "tk.1.1" } }, [2] = { [2] = { l = "Veras tank", s = "tk.2.1" } },
                            [3] = { [2] = { l = "Malande tank", s = "tk.3.1" } }, [4] = { [2] = { l = "Zerevor mage", s = "tk.4.1" } },
                            [5] = { [2] = { l = "Zone 1" } }, [6] = { [2] = { l = "Zone 2" } },
                            [7] = { [2] = { l = "Flex: tanks" } }, [8] = { [2] = { l = "Flex: poison" } } } },
                    { id = "zn", n = "Ranged zones", r = 7,
                      c = { { t = "p", n = "Zone 1", f = "ranged" }, { t = "p", n = "Zone 2", f = "ranged" } } },
                    { id = "mi", n = "Malande interrupts", r = 3, i = "i:Ability_Kick", tr = "rot",
                      c = { { t = "o" }, { t = "p", n = "Interrupt", f = "ROGUE,WARRIOR,SHAMAN,MAGE" },
                            { t = "g", n = "On" } },
                      d = { [1] = { [3] = { i = "@Lady Malande", l = "Kick 1" } },
                            [2] = { [3] = { i = "@Lady Malande", l = "Kick 2 (also on BoP)" } },
                            [3] = { [3] = { i = "@Lady Malande", l = "Kick 3 (backup)" } } } },
                    { id = "cu", n = "Curses", r = 2, i = "cls:WARLOCK", tr = "curse",
                      c = { { t = "p", n = "Warlock", f = "WARLOCK" }, { t = "g", n = "Curse" } },
                      d = { [1] = { [2] = { i = "@Lady Malande", l = "Curse of Tongues" } },
                            [2] = { [2] = { i = "@Veras Darkshadow", l = "Curse of Weakness" } } } },
                    { id = "md", n = "Misdirects", r = 4, i = "i:Ability_Hunter_Misdirection", tr = "md",
                      c = { { t = "o" }, { t = "p", n = "Hunter", f = "HUNTER" }, { t = "g", n = "Onto" } },
                      d = { [1] = { [3] = { i = "@Gathios the Shatterer", l = "Gathios ->", s = "tk.1.1" } },
                            [2] = { [3] = { i = "@High Nethermancer Zerevor", l = "Zerevor ->", s = "tk.4.1" } },
                            [3] = { [3] = { i = "@Veras Darkshadow", l = "Veras ->", s = "tk.2.1" } },
                            [4] = { [3] = { i = "@Lady Malande", l = "Malande ->", s = "tk.3.1" } } } },
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust", tr = "bl",
                      c = { { t = "p", n = "Shaman", f = "SHAMAN" }, { t = "x", n = "When" } },
                      d = { [1] = { [2] = "15 s after the pull (tanks settled)" } } },
                    { id = "pi", n = "Power Infusion", r = 2, i = "i:Spell_Holy_PowerInfusion", tr = "pi",
                      c = { { t = "p", n = "Priest", f = "PRIEST" }, { t = "p", n = "Onto" } } },
                    { id = "iv", n = "Innervates", r = 3, i = "i:Spell_Nature_Lightning", tr = "iv",
                      c = { { t = "p", n = "Druid", f = "DRUID" }, { t = "p", n = "Onto", f = "healer" } } },
                    { id = "nt", n = "Remember", r = 5,
                      c = { { t = "x" } },
                      d = { [1] = { [1] = "Keep Gathios away from the others (his auras)" },
                            [2] = { [1] = "Flamestrike / Blizzard: step out, stay in your zone" },
                            [3] = { [1] = "Veras vanishes: heal the Deadly Poison targets" },
                            [4] = { [1] = "Nobody but the mage near Zerevor (Arcane Explosion)" },
                            [5] = { [1] = "Kick Circle of Healing and Divine Wrath; skip smites" } } },
                },
            },
            {
                id = "p2", n = "Pull", map = "BT06", vx = 471, vy = 505, vz = 360,
                no = "The council stands together on the platform. Everyone waits in the entrance hall while the hunters "
                    .. "misdirect one boss each onto its tank; the tanks then drag them apart to their spots (arrows). "
                    .. "The mage tank takes Zerevor straight back to the entrance. Healers and ranged walk in once all "
                    .. "four are split up; Bloodlust 15 seconds in.",
                e = {
                    { t = "i", x = 400, y = 150, i = "@High Nethermancer Zerevor", z = 36, rm = 6, l = "Zerevor" },
                    { t = "i", x = 465, y = 150, i = "@Gathios the Shatterer", z = 36, rm = 8, l = "Gathios" },
                    { t = "i", x = 530, y = 150, i = "@Lady Malande", z = 36, rm = 1, l = "Malande" },
                    { t = "i", x = 595, y = 150, i = "@Veras Darkshadow", z = 36, rm = 7, l = "Veras" },
                    { t = "a", x = 620, y = 180, x2 = 815, y2 = 310, c = 7, h = true },
                    { t = "a", x = 505, y = 185, x2 = 200, y2 = 310, c = 8, h = true },
                    { t = "a", x = 400, y = 195, x2 = 490, y2 = 560, c = 2, h = true },
                    -- tanks at the foot of the stairs, the mage tank ready at the entrance
                    { t = "s", x = 440, y = 330, r = "tk.1.1" },
                    { t = "s", x = 700, y = 300, r = "tk.2.1" },
                    { t = "s", x = 290, y = 300, r = "tk.3.1" },
                    { t = "s", x = 560, y = 520, r = "tk.4.1" },
                    -- hunters in the hall, each misdirecting one boss
                    { t = "s", x = 380, y = 600, r = "md.1.2" },
                    { t = "s", x = 460, y = 640, r = "md.2.2" },
                    { t = "s", x = 560, y = 640, r = "md.3.2" },
                    { t = "s", x = 640, y = 600, r = "md.4.2" },
                    { t = "z", s = "r", x = 500, y = 620, w = 380, h = 90, c = 10, l = "Everyone else waits here" },
                },
                k = {
                    { id = "po", n = "Pull order", r = 5,
                      c = { { t = "o" }, { t = "x", n = "Step" } },
                      d = { [1] = { [2] = "Hunters: misdirect your boss (see Fight)" },
                            [2] = { [2] = "Tanks: take your boss to its spot (arrows)" },
                            [3] = { [2] = "Mage: Zerevor to the entrance" },
                            [4] = { [2] = "Healers + ranged: walk in, go to your zone" },
                            [5] = { [2] = "Bloodlust 15 s after the pull" } } },
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
                    { id = "bl", n = "Bloodlust", r = 1, i = "i:Spell_Nature_BloodLust", tr = "bl",
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

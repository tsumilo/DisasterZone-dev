if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/ZulAman.lua", ...) then return end -- DisasterZone: boss mods for Zul'Aman (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_B.md.
-- Hooks assume the engine handles an event's alerts first (counts, bars, warnings) and then runs fn for it.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["ZulAman:Akilzon"] = {
    enc = { 1189, 2482 },
    npc = { 23574 },
    alerts = {
        -- Electrical Storm: first DBM 46.9, BW 50, CM 42 + 8.5 = 50.5 -> {46.9, 50.5}; again (debuff to debuff)
        -- DBM 34.1 (its comment: 34-55), BW 40 after the 8 s storm = 48, CM 54-60 -> {34, 60}
        { key = "storm", kind = "bar", spell = 43648, start = { 46.9, 50.5 }, on = "AURA 43648", cd = { 34, 60 } },
        { key = "stormwarn", kind = "warn", spell = 43648, text = "Electrical Storm on %t",
          sub = "Stack under them", meText = "Electrical Storm on you", on = "AURA 43648" },
        -- Static Disruption: BW proximity 5, closed during the storm (everyone stacks)
        { key = "range", kind = "range", yd = 5, text = "Static Disruption", on = { "ENGAGE", "AURAGONE 43648" },
          stop = "AURA 43648" },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["ZulAman:Nalorakk"] = {
    enc = { 1190, 2483 },
    npc = { 23576 },
    alerts = {
        -- Bear Form: first DBM 45, BW 45, CM 45; again 45 after troll form in all three -> 45
        { key = "bear", kind = "bar", spell = 42377, text = "Bear Form", start = 45, on = "YELL Make way for",
          cd = 45 },
        -- Troll Form: DBM 30, BW 30, CM 30 -> 30
        { key = "troll", kind = "bar", spell = 42377, text = "Troll Form", on = "YELL You call on da beast", cd = 30 },
        { key = "form", kind = "warn", spell = 42377, role = "T", text = "Form change: swap tanks",
          on = { "YELL You call on da beast", "YELL Make way for" } },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["ZulAman:Janalai"] = {
    enc = { 1191, 2484 },
    npc = { 23578 },
    alerts = {
        -- Hatchers: first DBM none, BW 12 (CD), CM 10 -> {10, 12}; again DBM 92 (commented out), BW 92, CM 90
        -- -> {90, 92}. BW reads the summon from the boss's cast (no log event), DBM the yell
        { key = "hatchers", kind = "bar", spell = 43962, start = { 10, 12 },
          on = { "SUMMON 43962 45340", "YELL Where ma hatcha" }, cd = { 90, 92 }, throttle = 10 },
        { key = "hatcherswarn", kind = "warn", spell = 43962, text = "Hatchers: kill them",
          sub = "Before they hatch the eggs", on = { "SUMMON 43962 45340", "YELL Where ma hatcha" }, throttle = 10 },
        { key = "bombs", kind = "warn", spell = 42630, text = "Fire Bombs: find a gap",
          on = { "YELL I burn ya now", "SUCCESS 43098" }, throttle = 10 },
        -- Bombs explode: DBM 12, BW 12 -> 12
        { key = "bombsbar", kind = "bar", spell = 42630, text = "Bombs explode",
          on = { "YELL I burn ya now", "SUCCESS 43098" }, cd = 12, throttle = 10 },
        -- All eggs hatch at 35% (CM); BW warns between 36 and 40%
        { key = "eggs", kind = "warn", spell = 43144, text = "All eggs hatch at 35%", sub = "Get ready for the adds",
          on = "HP 38" },
        -- Enrage: BW 300, CM 300 (or at 20%) -> 300
        { key = "enrage", kind = "bar", spell = 44779, text = "Enrage", start = 300 },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["ZulAman:Halazzi"] = {
    enc = { 1192, 2485 },
    npc = { 23577 },
    alerts = {
        -- Split at 75, 50 and 25% (CM; BW counts them the same); DBM warns from his yell
        { key = "split", kind = "warn", spell = 43143, text = "Split: tank the lynx spirit",
          sub = "Burn the troll to merge them", on = { "HP 75", "HP 50", "HP 25", "YELL untamed spirit" },
          throttle = 10 },
        { key = "totem", kind = "warn", spell = 43302, text = "Lightning Totem: kill it",
          on = { "SUMMON 43302", "CAST 43302" }, throttle = 3 },
        { key = "frenzy", kind = "warn", spell = 43139, text = "Frenzy: tranquilize", on = "AURA 43139",
          src = { 23577 } },
        -- Berserk: DBM 600, BW none, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["ZulAman:Malacrass"] = {
    enc = { 1193, 2486 },
    npc = { 24239 },
    alerts = {
        -- Spirit Bolts: first DBM 30, BW 30, CM 30 -> 30; again DBM 41 (CD), BW 40, CM 10 s bolts + 30 = 40 -> 40
        { key = "bolts", kind = "bar", spell = 43383, start = 30, on = "SUCCESS 43383", cd = 40 },
        { key = "boltswarn", kind = "warn", spell = 43383, text = "Spirit Bolts", sub = "10 s of bolts: heal up",
          on = "SUCCESS 43383" },
        { key = "siphon", kind = "warn", spell = 43501, text = "Siphon Soul on %t",
          sub = "He uses their class spells now", on = "AURA 43501" },
    },
}

B["ZulAman:Zuljin"] = {
    enc = { 1194, 2487 },
    npc = { 23863 },
    phases = { [2] = "Bear", [3] = "Eagle", [4] = "Lynx", [5] = "Dragonhawk" },
    alerts = {
        -- New form at 80, 60, 40 and 20% (CM); a heads-up 2% before
        { key = "nextform", kind = "warn", spell = 42594, text = "Form change soon",
          on = { "HP 82", "HP 62", "HP 42", "HP 22" } },
        { key = "bear", kind = "warn", spell = 42594, text = "Bear form", sub = "Dispel Creeping Paralysis",
          on = "CAST 42594", setPhase = 2 },
        { key = "eagle", kind = "warn", spell = 42606, text = "Eagle form", sub = "Stay out of the cyclones",
          on = "CAST 42606", setPhase = 3 },
        { key = "lynx", kind = "warn", spell = 42607, text = "Lynx form", sub = "Claw Rage and Lynx Rush",
          on = "CAST 42607", setPhase = 4 },
        { key = "dragonhawk", kind = "warn", spell = 42608, text = "Dragonhawk form", sub = "Spread out",
          on = "CAST 42608", setPhase = 5 },
        { key = "throw", kind = "warn", spell = 43093, role = "H", text = "Grievous Throw on %t",
          sub = "Heal them to full", on = "AURA 43093", phase = 1 },
        { key = "paralysis", kind = "warn", spell = 43095, text = "Creeping Paralysis", sub = "Dispel the raid",
          on = "SUCCESS 43095" },
        -- Creeping Paralysis: DBM 27 (CD), BW 27 (CD), CM right after the bear form -> 27
        { key = "paralysisbar", kind = "bar", spell = 43095, on = "SUCCESS 43095", cd = 27, phase = 2 },
        { key = "claw", kind = "you", spell = 43150, text = "Claw Rage on you", sub = "Use a defensive",
          on = "AURA 43150", me = true },
    },
}

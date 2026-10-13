if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/SunwellPlateau.lua", ...) then return end -- DisasterZone: boss mods for Sunwell Plateau (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_B.md.
-- Hooks assume the engine handles an event's alerts first (counts, bars, warnings) and then runs fn for it.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["SunwellPlateau:Kalecgos"] = {
    enc = { 724, 2488 },
    npc = { 24850, 24892 },     -- Kalecgos, Sathrovarr
    alerts = {
        -- Spectral Blast: first DBM none, BW 20, CM 15-18 -> {15, 20}; again DBM 25 (next), BW 20, CM 21-26
        -- -> {20, 26}. Several players get the realm at once (BW waits 19 s between them)
        { key = "blast", kind = "bar", spell = 44866, start = { 15, 20 }, on = "AURA 46021", cd = { 20, 26 },
          throttle = 19 },
        { key = "realm", kind = "you", spell = 46021, text = "Spectral Blast on you",
          sub = "You go to the Spectral Realm", on = "AURA 46021", me = true },
        { key = "curse", kind = "you", spell = 45032, text = "Curse of Boundless Agony on you",
          sub = "Its damage keeps growing", on = "AURA 45032 45034", me = true },
        -- Crazed Rage when either dragon drops to 10% (CM); BW warns from the emote
        { key = "rage", kind = "warn", spell = 44806, text = "Crazed Rage: both bosses enraged",
          on = { "AURA 44806", "EMOTE drives Kalecgos into a crazed rage" }, throttle = 10 },
    },
}

B["SunwellPlateau:Brutallus"] = {
    enc = { 725, 2489 },
    npc = { 24882 },
    -- ENCOUNTER_START fires at the Madrigosa scene, long before the pull (DBM); his pull line starts the timers
    engage = { "YELL Ah, more lambs to the slaughter" },
    alerts = {
        -- Burn: first DBM 20, BW 20, CM 20; again 20 in all three -> 20
        { key = "burn", kind = "bar", spell = 46394, start = 20, on = "SUCCESS 45141", cd = 20 },
        { key = "burnyou", kind = "you", spell = 46394, text = "Burn on you", sub = "Stay away from everyone",
          on = "AURA 46394", me = true },
        -- BW proximity 5 while you burn ("spread distance is 2 yards"), 60 s
        { key = "range", kind = "range", yd = 5, text = "Burn", on = "AURA 46394", me = true, dur = 60 },
        -- Meteor Slash: first DBM none, BW none, CM 11 -> 11; again DBM 12 (cast start), BW 12, CM 11 + the cast
        -- -> 12
        { key = "meteor", kind = "bar", spell = 45150, start = 11, on = "CAST 45150", cd = 12 },
        -- Stomp: first DBM 31, BW 30, CM 30 -> 30; again DBM 31, BW 30.5, CM 30 -> 30
        { key = "stomp", kind = "bar", spell = 45185, role = "T", start = 30, on = "SUCCESS 45185", cd = 30 },
        { key = "stompwarn", kind = "warn", spell = 45185, role = "T", text = "Stomp on %t: swap tanks",
          on = "AURA 45185" },
        -- Berserk: DBM 360, BW 360, CM 360 -> 360
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 360 },
    },
}

B["SunwellPlateau:Felmyst"] = {
    enc = { 726, 2490 },
    npc = { 25038 },
    alerts = {
        -- Air phase: first DBM 60, BW 60, CM 60 -> 60; again 99/100 in the air + 60 on the ground -> {159, 160}
        { key = "air", kind = "bar", spell = 45717, text = "Air phase", start = 60,
          on = "YELL I am stronger than ever before", cd = { 159, 160 } },
        -- Landing: DBM 99, BW 100 -> {99, 100}
        { key = "land", kind = "bar", spell = 45717, text = "Landing", on = "YELL I am stronger than ever before",
          cd = { 99, 100 } },
        -- Deep Breath: first DBM 42, BW 40.5 -> {40.5, 42}; then DBM 17, BW 17 -> 17, three per air phase (hook)
        { key = "breath", kind = "bar", learn = false, spell = 45717, text = "Deep Breath",
          on = "YELL I am stronger than ever before", cd = { 40.5, 42 } },
        { key = "breathwarn", kind = "warn", spell = 45717, text = "Deep Breath: get out of its path",
          count = true, on = "EMOTE takes a deep breath" },
        -- Gas Nova: first DBM 17, BW none, CM 18-20 -> {17, 20}; again DBM 19 (CD), BW 20, CM 16-20 -> {19, 20};
        -- after landing DBM 17, CM 16-20 -> {115, 120} from the air line (hook)
        { key = "gas", kind = "bar", spell = 45855, start = { 17, 20 }, on = "CAST 45855", cd = { 19, 20 },
          learn = false },
        -- Encapsulate: BW reads the damage (no normal debuff), 15 s apart. First DBM none, BW 30, CM 20-30
        -- -> {20, 30}; again CM 30-45 only -> {30, 45}; after landing {119, 130} from the air line (hook)
        { key = "encap", kind = "bar", spell = 45665, start = { 20, 30 }, on = "HIT 45661", cd = { 30, 45 },
          throttle = 15, learn = false },
        { key = "encapwarn", kind = "warn", spell = 45665, text = "Encapsulate on %t",
          meText = "Encapsulate on you", on = "HIT 45661", throttle = 15 },
        -- DBM and BW read SPELL_SUMMON 45392 whose source is the player it follows; `me` looks at the target, so
        -- this uses the debuffs on that player (CM 45399 trail periodic; 45402 the name DBM shows)
        { key = "vapor", kind = "you", spell = 45402, text = "Demonic Vapor on you",
          sub = "Run, its trail spawns skeletons", on = "AURA 45399 45402", me = true },
        -- BW proximity 18 on the ground (Encapsulate); reopened by the first Gas Nova after landing
        { key = "range", kind = "range", yd = 18, text = "Encapsulate", on = { "ENGAGE", "CAST 45855" },
          stop = "YELL I am stronger than ever before" },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
    fn = {
        ["YELL I am stronger than ever before"] = function(m)
            m:Bar("gas", { 115, 120 })
            m:Bar("encap", { 119, 130 })
        end,
        ["EMOTE takes a deep breath"] = function(m)
            if m:Count("breathwarn") % 3 ~= 0 then m:Bar("breath", 17) end
        end,
    },
}

B["SunwellPlateau:EredarTwins"] = {
    enc = { 727, 2491 },
    npc = { 25166, 25165 },     -- Grand Warlock Alythess, Lady Sacrolash
    alerts = {
        -- The emote names the target at cast start (DBM); the cast's end is the backup
        { key = "conflag", kind = "warn", spell = 45342, text = "Conflagration on %t",
          meText = "Conflagration on you: move away", on = { "EMOTE directs Conflagration at", "SUCCESS 45342" },
          throttle = 5 },
        { key = "nova", kind = "warn", spell = 45329, text = "Shadow Nova on %t",
          meText = "Shadow Nova on you: move away", on = { "EMOTE directs Shadow Nova at", "SUCCESS 45329" },
          throttle = 5 },
        -- Conflagration: first only CM 15 (left out); again DBM 31 (CD), BW 32 (CD), CM 35 -> {31, 35}
        { key = "conflagbar", kind = "bar", spell = 45342, on = "CAST 45342", cd = { 31, 35 } },
        -- Shadow Nova: first only CM 35 (left out); again DBM 31 (CD), BW none, CM 35 -> {31, 35}
        { key = "novabar", kind = "bar", spell = 45329, on = "CAST 45329", cd = { 31, 35 } },
        { key = "pyro", kind = "warn", spell = 45230, text = "Pyrogenics: spellsteal it", on = "AURA 45230",
          src = { 25166 } },
        -- BW proximity 10 all fight
        { key = "range", kind = "range", yd = 10, text = "Spread", on = "ENGAGE" },
        -- Berserk: DBM 360, BW 360, CM 360 -> 360
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 360 },
    },
}

-- The adds come on a clock from the pull. DBM and BW only run timers; CM summons them with the spells below (not
-- seen in a log by us), so the bars loop, and Darkness (every 45 s) re-syncs both from the pull clock (hook).
local function nextAt(t, first, every)
    return first + every * (math.floor((t - first) / every) + 1) - t
end
local function Elapsed(m) return m.t or (GetTime() - (m.t0 or GetTime())) end

B["SunwellPlateau:Muru"] = {
    enc = { 728, 2492 },
    npc = { 25741, 25840 },     -- M'uru, Entropius
    phases = { [2] = "Entropius" },
    alerts = {
        -- Humanoids: first DBM 15, BW 10, CM 15 -> {10, 15}; again DBM 60, BW 60, CM 60 -> 60
        { key = "humanoids", kind = "bar", spell = 46037, text = "Humanoids", start = { 10, 15 },
          on = "SUMMON 46037 46038 46039 46040", cd = 60, throttle = 10, loop = true, phase = 1 },
        -- Void Sentinel: first DBM 36.5, BW 30, CM 30 + the summoner -> {30, 36.5}; again DBM 30, BW 30 -> 30
        { key = "sentinel", kind = "bar", spell = 45988, text = "Void Sentinel", start = { 30, 36.5 },
          on = "SUMMON 45988", cd = 30, throttle = 5, loop = true, phase = 1 },
        -- Darkness: first DBM 45 (next), BW 45, CM 45; again 45 in all three -> 45
        { key = "darkness", kind = "bar", spell = 45996, start = 45, on = "AURA 45996", cd = 45, throttle = 10,
          src = { 25741 }, phase = 1 },
        { key = "phase2", kind = "warn", spell = 46177, text = "Entropius in 10 s", sub = "Phase 2",
          on = "SUCCESS 46177", setPhase = 2, once = true },
        -- Black Hole: first DBM 22.6, BW 27, CM 6 + 15 = 21 -> {21, 27}; again DBM 15 (CD), BW 15 -> 15 (CM 11-30)
        { key = "blackhole", kind = "bar", spell = 46282, start = { 21, 27 }, on = "SUCCESS 46282", cd = 15,
          phase = 2 },
        -- Berserk: DBM 600, BW 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
    fn = {
        ["AURA 45996"] = function(m)
            if m.phase ~= 1 then return end
            local t = Elapsed(m)
            local h, s = nextAt(t, 10, 60), nextAt(t, 30, 30)
            m:Bar("humanoids", { h, h + 5 })
            m:Bar("sentinel", { s, s + 6.5 })
        end,
    },
}

B["SunwellPlateau:Kiljaeden"] = {
    enc = { 729, 2493 },        -- fires when he rises (BW: not for the Deceivers)
    npc = { 25315 },
    phases = { [2] = "85%", [3] = "55%", [4] = "25%" },
    alerts = {
        { key = "bloomyou", kind = "you", spell = 45641, text = "Fire Bloom on you", sub = "Move away from others",
          on = "AURA 45641", me = true },
        -- Fire Bloom: first DBM 13.5 (from his pull line), CM 6-10 after he rises -> {6, 13.5}; again DBM 20 (CD),
        -- BW 20, CM 20-23 -> {20, 23}
        { key = "bloom", kind = "bar", spell = 45641, start = { 6, 13.5 }, on = { "SUCCESS 45641", "AURA 45641" },
          cd = { 20, 23 }, throttle = 5 },
        -- DBM range 10 (Fire Bloom), BW proximity 10 once he is up
        { key = "range", kind = "range", yd = 10, text = "Fire Bloom", on = "ENGAGE" },
        -- Sinister Reflection at 85, 55 and 25% (CM); each one is the next phase (hook)
        { key = "reflect", kind = "warn", spell = 45892, text = "Sinister Reflections: kill them",
          on = "SUCCESS 45892", throttle = 10 },
        -- Darkness of a Thousand Souls: after a reflection DBM 77, CM about 76 -> 77; in the last phase DBM 57.8,
        -- CM about 63 -> {57.8, 63} (hook); again DBM 45 (CD), BW 46, CM 45 -> 45, last phase 25 in all three (hook)
        { key = "darkness", kind = "bar", learn = false, spell = 46605, start = 77, on = "CAST 46605", cd = 45,
          phase = { 2, 3, 4 } },
        { key = "darknesswarn", kind = "warn", spell = 46605, text = "Darkness: get behind the blue shield",
          sub = "It goes off in 8 s", on = "CAST 46605" },
        -- No source has a Shield Orb timer that holds up (CM: every 45 s while under the cap); warn when one fires
        { key = "orb", kind = "warn", spell = 45680, text = "Shield Orb shooting: kill it", on = "SUCCESS 45680",
          throttle = 15 },
        -- DBM scans his target for Armageddon; the cast's end may carry it
        { key = "armageddon", kind = "warn", spell = 45909, text = "Armageddon",
          meText = "Armageddon under you: move", on = "SUCCESS 45909", throttle = 2, phase = { 3, 4 } },
        -- Berserk: DBM 900, CM 900 -> 900
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 900 },
    },
    fn = {
        ["SUCCESS 45892"] = function(m)
            local p = math.min(4, m:Count("reflect") + 1)
            m:Phase(p)
            if p == 4 then m:Bar("darkness", { 57.8, 63 }) end
        end,
        ["CAST 46605"] = function(m) if m.phase == 4 then m:Bar("darkness", 25) end end,
    },
}

if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/BlackTemple.lua", ...) then return end -- DisasterZone: boss mods for Black Temple (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_B.md.
-- Hooks assume the engine handles an event's alerts first (counts, bars, warnings) and then runs fn for it.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["BlackTemple:Najentus"] = {
    enc = { 601, 2473 },
    npc = { 22887 },
    alerts = {
        -- Tidal Shield: first DBM 55.5 (CD), BW 55 ("55-60"), CM 60 -> {55, 60}; again DBM 56 (CD), BW 56
        -- ("56-60"), CM 60 -> {56, 60}
        { key = "shield", kind = "bar", spell = 39872, start = { 55, 60 }, on = "AURA 39872", cd = { 56, 60 } },
        { key = "shieldwarn", kind = "warn", spell = 39872, text = "Tidal Shield: throw a spine",
          sub = "Pick up a spine and throw it at him", on = "AURA 39872" },
        -- BW listens to the cast end (faster than the debuff, the spine flies), DBM to the debuff
        { key = "spine", kind = "warn", spell = 39837, text = "Impaling Spine on %t", sub = "Pull the spine out",
          meText = "Impaling Spine on you", on = { "SUCCESS 39837", "AURA 39837" }, throttle = 3 },
        -- Needle Spine: BW proximity 8 for the whole fight
        { key = "range", kind = "range", yd = 8, text = "Needle Spine", on = "ENGAGE" },
        -- Berserk: DBM 480, BW 480, CM 480 -> 480
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 480 },
    },
}

B["BlackTemple:Supremus"] = {
    enc = { 602, 2474 },
    npc = { 22898 },
    alerts = {
        -- Phase change: DBM 60, BW 60, CM 60 both ways -> 60
        { key = "phase", kind = "bar", spell = 42052, text = "Phase change", start = 60,
          on = { "EMOTE The ground begins to crack open", "EMOTE punches the ground in anger" }, cd = 60 },
        { key = "kite", kind = "warn", spell = 42052, text = "Kite phase", sub = "He chases one player",
          on = "EMOTE The ground begins to crack open" },
        -- The fixate debuff 41951 is not in the 2.5.6 client (DBM and BW say so; DBM and BW scan his target), so
        -- the emote can only say that he picked someone
        { key = "fixate", kind = "warn", spell = 40607, text = "Supremus has a new target",
          sub = "Run if he is chasing you", on = "EMOTE acquires a new target", throttle = 3 },
        { key = "fire", kind = "you", spell = 42052, text = "Fire under you", sub = "Move out of it",
          on = "HIT 42052 40265", me = true, throttle = 4 },
        -- Berserk: DBM 900, BW 900, CM 900 -> 900
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 900 },
    },
}

B["BlackTemple:ShadeOfAkama"] = {
    enc = { 603, 2475 },
    npc = { 22841, 23421, 23215 },  -- the Shade, Ashtongue Channeler, Ashtongue Sorcerer
    phases = { [2] = "Shade active" },
    alerts = {
        { key = "channeler", kind = "warn", text = "Channeler down (%n of 6)", count = true, on = "DIES 23421",
          phase = 1 },
        -- Sorcerer: first at the pull (DBM +1, BW 0), second DBM 26, BW 25.5 -> 25.5; again DBM 25, BW 25.5 -> 25.
        -- No log event marks a spawn, so the bar loops
        { key = "sorcererbar", kind = "bar", spell = 40520, text = "Sorcerer", start = 25.5, cd = 25, loop = true,
          phase = 1 },
        -- Defender: first at the pull, second DBM 31, BW 32 -> 31; again DBM 30, BW 29.7 -> 29.7 (loops)
        { key = "defenderbar", kind = "bar", spell = 41180, text = "Defender", start = 31, cd = 29.7, loop = true,
          phase = 1 },
        -- Side waves: DBM 47/51 from +1 and +18 s, BW 45/52 from 0 and 15 s: they drift apart, so no bars.
        -- A sorcerer that reaches the Shade channels it (CM 40401; DBM shows 40520 for it)
        { key = "sorcerer", kind = "warn", spell = 40520, text = "Sorcerer channels the Shade: kill it",
          on = { "SUCCESS 40401", "AURA 40520" }, src = { 23215 }, throttle = 5, phase = 1 },
        -- The Shade wakes when nobody channels it any more: DBM Akama's Fixate 40607 (and 40955), BW the Shade's
        -- first swing; the Shade's first damage is the HP trigger
        { key = "active", kind = "warn", spell = 40607, text = "Shade is active: tank it",
          sub = "Akama fights it, kill the adds", on = { "SUCCESS 40607 40955", "HP 99" }, setPhase = 2,
          once = true },
    },
}

B["BlackTemple:Teron"] = {
    enc = { 604, 2476 },
    npc = { 22871 },
    alerts = {
        -- Shadow of Death: first DBM 9.6 (its comment: 9.6-13?), BW 10, CM 10 -> {9.6, 13}; again DBM 24.5 (its
        -- comment: 24.5-40), BW 32 (its comment: 32-40), CM 30-50 -> {24.5, 40}
        { key = "sod", kind = "bar", spell = 40251, start = { 9.6, 13 }, on = "SUCCESS 40251", cd = { 24.5, 40 } },
        { key = "sodyou", kind = "you", spell = 40251, text = "Shadow of Death on you",
          sub = "You die in 55 s, then kill constructs as a ghost", on = "AURA 40251", me = true },
        -- DBM 55, BW 55 on Classic (30 on retail) -> 55
        { key = "sodbar", kind = "bar", spell = 40251, text = "You die", on = "AURA 40251", me = true, cd = 55 },
        { key = "sodheal", kind = "warn", spell = 40251, role = "H", text = "Shadow of Death on %t",
          sub = "Keep them alive for 55 s", on = "AURA 40251" },
        -- Berserk: DBM none, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["BlackTemple:Bloodboil"] = {
    enc = { 605, 2477 },
    npc = { 22948 },
    alerts = {
        -- Bloodboil: first DBM 10.9, BW 10.5, CM 11 -> 10.5; again DBM 10 (its comment: 10-12, mostly 11), BW 10,
        -- CM 11; after Fel Rage DBM 12.5, BW 10, CM 10 -> {10, 12.5}
        { key = "boil", kind = "bar", spell = 42005, start = 10.5, on = { "SUCCESS 42005", "AURAGONE 40594" },
          cd = { 10, 12.5 }, stop = "AURA 40604" },
        -- Fel Rage: first DBM 52 (its comment: 52-58), BW 58, CM 60 -> {52, 60}; after the rage ends DBM 52, BW 52
        -- (its comment: 52-55), CM 60 -> {52, 60}
        { key = "felrage", kind = "bar", spell = 40604, start = { 52, 60 }, on = "AURAGONE 40594", cd = { 52, 60 } },
        -- DBM 30, BW 30 -> 30
        { key = "felrageends", kind = "bar", spell = 40594, text = "Fel Rage ends", on = "AURA 40604", cd = 30 },
        { key = "felrageyou", kind = "you", spell = 40604, text = "Fel Rage on you",
          sub = "He is coming for you: use defensives", on = "AURA 40604", me = true },
        { key = "felragewarn", kind = "warn", spell = 40604, text = "Fel Rage on %t", on = "AURA 40604" },
        -- Eject: CM only (DBM and BW have no Eject timer): first 10, again 15, 30 after Fel Rage -> 10 / 15
        { key = "eject", kind = "bar", spell = 40486, role = "T", start = 10, on = "SUCCESS 40486", cd = 15,
          stop = "AURA 40604" },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["BlackTemple:Reliquary"] = {
    enc = { 606, 2478 },
    npc = { 22856, 23418, 23419, 23420 },  -- Reliquary, Suffering, Desire, Anger
    phases = { [1] = "Essence of Suffering", [2] = "Essence of Desire", [3] = "Essence of Anger" },
    alerts = {
        -- Frenzy: first DBM 49 (next), BW 48, CM 45 from the essence's aggro -> 48; again from its end DBM 40
        -- (next), BW 40.5, CM 37 -> 40 (CM's flat 45 matches neither log)
        { key = "frenzy", kind = "bar", spell = 41305, text = "Frenzy", start = 48, on = "AURAGONE 41305", cd = 40,
          phase = 1, stop = "YELL I don't want to go back" },
        -- Next essence: DBM 41, BW 40, CM 41 -> 40 (from the essence's parting line)
        { key = "essence", kind = "bar", spell = 41350, text = "Next essence",
          on = { "YELL I don't want to go back", "YELL I won't be far" }, cd = 40 },
        { key = "desire", kind = "warn", spell = 41350, text = "Essence of Desire", sub = "Mana drops to 0 in 160 s",
          on = "SUCCESS 41350", setPhase = 2 },
        -- Rune Shield: first DBM 12.1, BW 13, CM 10-15 -> {10, 15}; again DBM 15, BW 15.7, CM 15 -> 15
        { key = "shieldbar", kind = "bar", spell = 41431, start = { 10, 15 }, on = "SUCCESS 41431", cd = 15,
          phase = 2, stop = "YELL I won't be far" },
        { key = "shield", kind = "warn", spell = 41431, text = "Rune Shield: purge it", on = "SUCCESS 41431",
          phase = 2 },
        -- Deaden: first DBM 26.7, BW 27.6 -> 26.7 (CM 15 matches neither); again DBM 31, BW 31.5, CM 30
        -- -> {30, 31.5}
        { key = "deaden", kind = "bar", spell = 41410, start = 26.7, on = "CAST 41410", cd = { 30, 31.5 },
          phase = 2, stop = "YELL I won't be far" },
        -- Mana to 0: DBM 160, BW 160 -> 160
        { key = "mana", kind = "bar", spell = 41350, text = "Mana 0", on = "SUCCESS 41350", cd = 160,
          stop = "YELL I won't be far" },
        { key = "anger", kind = "warn", spell = 41337, text = "Essence of Anger", sub = "Tanks: no taunting",
          on = "SUCCESS 41337", setPhase = 3 },
        { key = "spite", kind = "warn", spell = 41376, role = "H", text = "Spite on %t", sub = "Big hit in 2 s",
          on = "AURA 41376", phase = 3 },
    },
}

B["BlackTemple:Shahraz"] = {
    enc = { 607 },              -- DBM also lists 2478, which is the Reliquary's (left out)
    npc = { 22947 },
    alerts = {
        -- Fatal Attraction: first DBM 24.4, BW 25, CM 22-29 -> {22, 29}; again DBM 20.7 (its log: 20.7-28.0 over
        -- 16 casts; its comment: 20-51), BW 24 (its comment: 24-40+), CM 22-40 -> {20.7, 28}: the long gaps are
        -- casts the debuff never showed (all three resisted), so the log's range is the real one
        { key = "fa", kind = "bar", spell = 41001, start = { 22, 29 }, on = "AURA 41001", cd = { 20.7, 28 },
          throttle = 5 },
        { key = "fayou", kind = "you", spell = 41001, text = "Fatal Attraction on you",
          sub = "Run away from the other two", on = "AURA 41001", me = true },
        -- BW proximity 15 (it opens it only on the Fatal Attraction targets); the plan wants it all fight
        { key = "range", kind = "range", yd = 15, text = "Fatal Attraction", on = "ENGAGE" },
        -- Enrage below 10% (CM), DBM warns from her emote
        { key = "enrage", kind = "warn", text = "Enrage at 10%", sub = "All beams at once: burn her",
          icon = 26662, on = "HP 10" },
        -- Berserk: DBM none, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["BlackTemple:Council"] = {
    enc = { 608, 2480 },
    npc = { 23426, 22949, 22950, 22951, 22952 },
    alerts = {
        { key = "vanish", kind = "warn", spell = 41476, text = "Veras vanished",
          sub = "He comes back with poison", on = "AURA 41476" },
        -- Veras back: DBM 31, BW 30 -> 30
        { key = "veras", kind = "bar", spell = 41476, text = "Veras returns", on = "AURA 41476", cd = 30 },
        { key = "blessing", kind = "warn", spell = 41450, text = "Blessing on %t: purge it",
          on = "AURA 41450 41451", src = { 22949 } },
        { key = "reflect", kind = "warn", spell = 41475, text = "Reflective Shield on Malande",
          sub = "Stop damage on her for 20 s", on = "AURA 41475" },
        { key = "under", kind = "you", spell = 41541, text = "Bad ground under you",
          sub = "Consecration, Blizzard or Flamestrike: move",
          on = "AURA 41541 41482 41481", me = true, throttle = 2.5 },
        -- Berserk: DBM 900, BW 900, CM 900 -> 900
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 900 },
    },
}

B["BlackTemple:Illidan"] = {
    enc = { 609, 2481 },
    npc = { 22917, 22997 },     -- Illidan, Flame of Azzinoth
    phases = { [2] = "Flames of Azzinoth", [3] = "The Demon Within", [4] = "Maiev" },
    alerts = {
        { key = "parasite", kind = "you", spell = 41917, text = "Parasite on you", sub = "Move away from the raid",
          on = "AURA 41917 41914", me = true },
        -- Stage 2 at 65%: DBM and BW the glaive throw (CM 65%)
        { key = "phase2", kind = "warn", spell = 39849, text = "Phase 2: Flames of Azzinoth", on = "CAST 39849",
          setPhase = 2, once = true },
        { key = "eyeblast", kind = "warn", spell = 40018, text = "Eye Blast: get out of the beam",
          on = "YELL Stare into the eyes of the Betrayer", phase = 2 },
        -- Eye Blast: CM only, 37-65 (DBM and BW have no Eye Blast timer)
        { key = "eyeblastbar", kind = "bar", spell = 40018, on = "YELL Stare into the eyes of the Betrayer",
          cd = { 37, 65 }, phase = 2 },
        -- Dark Barrage: first from the glaive DBM 85, BW 95, CM 77 + the lift-off -> {85, 95}; again DBM 44 (CD),
        -- BW 50 (its comment: 50-70 with Eye Blast), CM 43-60 -> {44, 70}
        { key = "barrage", kind = "bar", spell = 40585, start = { 85, 95 }, on = "AURA 40585", cd = { 44, 70 },
          phase = 2 },
        { key = "barragewarn", kind = "warn", spell = 40585, role = "H", text = "Dark Barrage on %t",
          sub = "10 s of shadow damage", on = "AURA 40585", phase = 2 },
        { key = "flames", kind = "warn", text = "Flame of Azzinoth down (%n of 2)", icon = 39849, count = true,
          on = "DIES 22997", phase = 2 },
        { key = "phase3", kind = "warn", spell = 40506, text = "Phase 3: Illidan lands", on = "PHASE 3" },
        -- Demon Form: first DBM 76, BW 75 after both flames die -> {75, 76} (hook); again from his demon line
        -- DBM 74 + 60, BW 60 + 60 from the form (14 s after the line) -> 134; after Maiev DBM 92, BW 90 -> {90, 92}
        -- (hook)
        { key = "demon", kind = "bar", spell = 40506, on = "YELL of the demon within", cd = 134, phase = { 3, 4 },
          learn = false },
        -- Human again: DBM 74 from the line, BW 60 from the form, CM 48 + the change back -> 74
        { key = "demonends", kind = "bar", spell = 40506, text = "Demon Form ends", on = "YELL of the demon within",
          cd = 74, phase = { 3, 4 }, stop = "SUCCESS 40647" },
        -- Shadow Demons: DBM 34 from the line, BW 25 from the form, CM 20 after the change -> 34
        { key = "demons", kind = "bar", spell = 41117, on = "YELL of the demon within", cd = 34, phase = { 3, 4 },
          stop = "SUCCESS 40647" },
        { key = "demonswarn", kind = "warn", spell = 41117, text = "Shadow Demons: kill them",
          on = "CAST 41117" },
        { key = "demonyou", kind = "you", spell = 41083, text = "Shadow Demon on you",
          sub = "It kills you when it arrives", on = "AURA 41083", me = true },
        { key = "flamesyou", kind = "you", spell = 40932, text = "Agonizing Flames on you",
          sub = "Move away from the raid", on = "AURA 40932", me = true },
        -- Stage 4 at 30%: DBM and BW Shadow Prison
        { key = "phase4", kind = "warn", spell = 40647, text = "Phase 4: Maiev joins",
          sub = "Lure him into her traps", on = "SUCCESS 40647", setPhase = 4, once = true },
        -- DBM: range 10 in phases 3 and 4 (its option text)
        { key = "range", kind = "range", yd = 10, text = "Spread", on = { "PHASE 3", "PHASE 4" }, phase = { 3, 4 } },
        -- Berserk: DBM 1500, BW 1500, CM 1500 -> 1500
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 1500 },
    },
    fn = {
        ["DIES 22997"] = function(m)
            if m.phase == 2 and m:Count("flames") >= 2 then
                m:Phase(3)
                m:Bar("demon", { 75, 76 })
            end
        end,
        ["SUCCESS 40647"] = function(m) m:Bar("demon", { 90, 92 }) end,
    },
}

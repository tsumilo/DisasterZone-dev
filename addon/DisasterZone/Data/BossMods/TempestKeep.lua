if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/TempestKeep.lua", ...) then return end -- DisasterZone: boss mods for Tempest Keep (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_A.md.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["TempestKeep:Alar"] = {
    enc = { 730, 2464 },
    npc = { 19514 },
    phases = { [2] = "Reborn" },
    alerts = {
        -- Flame Quills cannot be timed: CM replaces a platform move (every 30-35 s) with them at 50% odds
        { key = "quills", kind = "warn", spell = 34229, text = "Flame Quills: get off the platforms",
          on = "AURA 34229" },
        -- Flame Quills last DBM 10 -> 10
        { key = "quillsbar", kind = "bar", spell = 34229, text = "Flame Quills end", phase = 1, on = "AURA 34229",
          cd = 10 },
        -- Rebirth: DBM SPELL_HEAL 34342 (no HEAL trigger in our grammar: its cast and its damage instead)
        { key = "rebirth", kind = "warn", spell = 34342, text = "Al'ar is reborn", sub = "Dive Bomb in 30 s",
          on = { "SUCCESS 34342", "HIT 34342" }, setPhase = 2, once = true },
        -- Dive Bomb: first DBM 30, CM 30 -> 30; again DBM 52 (CD), BW 52 (CD), CM 50-60 -> {52, 60}.
        -- DBM and BW find it by target scanning; 35367 (CM's visual cast) / 35181 are untested triggers
        { key = "dive", kind = "bar", spell = 35181, phase = 2, start = 30,
          on = { "SUCCESS 35367", "AURA 35367", "SUCCESS 35181", "HIT 35181" }, cd = { 52, 60 }, throttle = 15 },
        { key = "patch", kind = "you", spell = 35383, text = "Flame Patch under you: move", on = "AURA 35383",
          me = true },
    },
}

B["TempestKeep:VoidReaver"] = {
    enc = { 731, 2465 },
    npc = { 19516 },
    alerts = {
        -- Pounding: first DBM 13 (CD), CM 12 -> 12; again DBM 13 (CD), BW 13 (CD), CM 14 -> 13
        { key = "pounding", kind = "bar", spell = 34162, start = 12, on = "SUCCESS 34162", cd = 13 },
        { key = "orb", kind = "you", spell = 34172, text = "Arcane Orb on you: move", on = "SUCCESS 34172", me = true },
        -- Enrage: DBM 600, BW 600, CM 600 -> 600
        { key = "enrage", kind = "bar", text = "Enrage", icon = 26662, start = 600 },
    },
}

local SPLIT = { "YELL I will crush your delusions of grandeur", "YELL You are hopelessly outmatched" }

B["TempestKeep:Solarian"] = {
    enc = { 732, 2466 },
    npc = { 18805 },
    phases = { [2] = "Voidwalker (20%)" },
    alerts = {
        { key = "wrath", kind = "you", spell = 42783, text = "Wrath on you: run out", sub = "Away from the raid",
          on = "AURA 42783 33045", me = true },
        -- Range: Wrath of the Astromancer 42784 explodes in 8 yd (client data via wowhead) -> 10; open while it lasts
        -- (42783 6 s, 33045 8 s: BW)
        { key = "range", kind = "range", yd = 10, text = "Wrath", on = "AURA 42783 33045", me = true, dur = 8 },
        -- Split: first DBM 50, BW 50, CM 50 -> 50; again (line to line) DBM 90, BW 90, CM 92 -> {90, 92}
        { key = "split", kind = "bar", text = "Split", icon = 33023, phase = 1, start = 50, on = SPLIT, cd = { 90, 92 } },
        -- Agents after the split line: DBM 4, BW 6, CM 5 -> {4, 6}
        { key = "agents", kind = "bar", text = "Agents", icon = 33023, phase = 1, on = SPLIT, cd = { 4, 6 } },
        -- Priests and Solarian: DBM 20, BW 22, CM 21 -> {20, 22}
        { key = "priests", kind = "bar", text = "Priests and Solarian", icon = 33023, phase = 1, on = SPLIT,
          cd = { 20, 22 } },
        -- 20%: CM below 20% casts 39117, DBM and BW the line
        { key = "void", kind = "warn", spell = 39117, text = "20%: Solarian becomes a Voidwalker",
          sub = "Fears and Void Bolts", on = { "HP 20", "YELL I become", "SUCCESS 39117" }, setPhase = 2,
          once = true },
    },
}

B["TempestKeep:Kaelthas"] = {
    enc = { 733, 2467 },
    npc = { 19622 },
    phases = { [2] = "Weapons", [3] = "Advisors revived", [4] = "Kael'thas", [5] = "Gravity Lapse (50%)" },
    alerts = {
        { key = "gaze", kind = "warn", text = "Gaze on %t", meText = "Thaladred's gaze on you: run", icon = 36091,
          on = "EMOTE sets eyes on" },
        -- First advisor (Thaladred) attacks: DBM 32, BW 32, CM 30 (23 + 7) -> {30, 32}; the others by hook
        { key = "advisor", kind = "bar", text = "Next advisor attacks", icon = 36091, phase = 1, start = { 30, 32 },
          cd = 7 },
        -- Weapons: CM casts 36976 and says the line together
        { key = "weapons", kind = "warn", spell = 36976, text = "Phase 2: weapons", sub = "Kill them, then loot them",
          on = { "SUCCESS 36976", "CAST 36976", "YELL As you see, I have many weapons in my arsenal" }, setPhase = 2,
          once = true },
        -- Advisors revived: DBM 104.6, BW 105, CM 120 (post-2.1 value) -> {104.6, 120}
        { key = "revivebar", kind = "bar", spell = 36450, text = "Advisors revived", phase = 2, start = { 104.6, 120 } },
        { key = "revived", kind = "warn", spell = 36450, text = "Phase 3: advisors revived", sub = "Use the weapons",
          on = { "CAST 36450", "SUCCESS 36450", "YELL Perhaps I underestimated you" }, setPhase = 3, once = true },
        -- Kael'thas joins: DBM 183 (10 + 173; "123 pre nerf, 183 post nerf"), CM 186 (6 + 180 post-2.0.3),
        -- BW 120 on Classic (the pre-nerf value) -> {183, 186}; sooner when every advisor dies (CM)
        { key = "kaelbar", kind = "bar", text = "Kael'thas joins", icon = 36091, phase = 3, start = { 183, 186 } },
        { key = "phase4", kind = "warn", text = "Phase 4: Kael'thas joins", icon = 36091,
          on = "YELL Alas, sometimes one must take matters into one's own hands", setPhase = 4, once = true },
        -- Phoenix: DBM 50 at phase 4, 45 (CD) again; 137 at phase 5, 90 again; BW 45; CM DB spell list (hooks)
        { key = "phoenix", kind = "bar", learn = false, spell = 36723, phase = { 4, 5 }, cd = 45 },
        -- Shock Barrier: DBM 60 at phase 4 and 60 (CD) again, BW Pyroblast 60 at phase 4 -> 60
        { key = "barrier", kind = "bar", spell = 36815, phase = 4, start = 60, on = "AURA 36815", cd = 60 },
        { key = "barrierwarn", kind = "warn", spell = 36815, text = "Shock Barrier: break it",
          sub = "Three Pyroblasts on the tank", phase = 4, on = "AURA 36815" },
        { key = "mc", kind = "warn", spell = 36797, text = "Mind Control on %t", on = "AURA 36797" },
        -- 50%: CM below 50%, DBM and BW the line
        { key = "phase5", kind = "warn", spell = 35941, text = "50%: Kael'thas takes flight",
          sub = "Gravity Lapse in about 60 s",
          on = { "HP 50", "YELL I have not come this far to be stopped" }, setPhase = 5, once = true },
        -- Gravity Lapse: first DBM 60, BW 60 -> 60; again DBM 92 next, BW 90 -> {90, 92}; CM DB spell list
        { key = "gravity", kind = "bar", spell = 35941, phase = 5, start = 60, on = "CAST 35941", cd = { 90, 92 } },
    },
    fn = {
        -- next advisor after his line: Sanguinar DBM 12.5, BW 13, CM 12.5; Capernian 7, 7, 7; Telonicus 8.4, 8, 8.4
        ["YELL Behold, Lord Sanguinar"] = function(m) m:Bar("advisor", 12.5) end,
        ["YELL Capernian will see to it that your stay here is a short one"] = function(m) m:Bar("advisor", 7) end,
        ["YELL my master engineer, Telonicus"] = function(m) m:Bar("advisor", 8) end,
        ["PHASE 4"] = function(m) m:Bar("phoenix", 50) end,
        ["PHASE 5"] = function(m) m:Bar("phoenix", 137) end,
        ["SUCCESS 36723"] = function(m) m:Bar("phoenix", m.phase == 5 and 90 or 45) end,
    },
}

if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/SerpentshrineCavern.lua", ...) then return end -- DisasterZone: boss mods for Serpentshrine Cavern (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_A.md.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

local MARKS = "SUCCESS 38215 38216 38217 38218 38231 40584 38219 38220 38221 38222 38230 40583"

B["SerpentshrineCavern:Hydross"] = {
    enc = { 623, 2458 },
    npc = { 21216, 22035, 22036 },  -- Hydross, Pure Spawn (frost form adds), Tainted Spawn (nature form adds)
    alerts = {
        -- Mark: first DBM 16, BW 15 -> {15, 16}; again DBM 15, BW 15; after a form change DBM 16, BW 15 -> {15, 16};
        -- CM DB spell list. The spawns' 25035 marks the form change (DBM)
        { key = "mark", kind = "bar", spell = 38215, text = "Mark stacks up", start = { 15, 16 },
          on = { MARKS, "SUCCESS 25035" }, src = { 21216, 22035, 22036 }, cd = { 15, 16 }, throttle = 2 },
        { key = "frost", kind = "warn", spell = 38215, role = "T", text = "Frost form: swap tanks",
          on = "SUCCESS 25035", src = { 22035 } },
        { key = "nature", kind = "warn", spell = 38219, role = "T", text = "Nature form: swap tanks",
          on = "SUCCESS 25035", src = { 22036 } },
        { key = "adds", kind = "warn", spell = 25035, text = "Four adds: kill them", on = "SUCCESS 25035",
          src = { 22035, 22036 } },
        -- Water Tomb range in frost form: BW proximity 10 yd, opened on pull and on frost, closed on nature (hook)
        { key = "range", kind = "range", yd = 10, text = "Water Tomb", on = "ENGAGE" },
    },
    fn = {
        ["SUCCESS 25035"] = function(m, ev)
            if ev.npc == 22035 then m:Range("range", true) elseif ev.npc == 22036 then m:Range("range", false) end
        end,
    },
}

-- Phase 2 is the Lurker under water. Submerge Visual 28819 is an aura in CM, but on our server it never reached the
-- combat log (16 Oct 2026: a kill with no submerge seen), so he goes under when DBM sees it (UCAST: his unit's cast)
-- or when his adds come up, and he is back at his first sign in the log after 20 s gone (or his Whirl or Geyser).
B["SerpentshrineCavern:Lurker"] = {
    enc = { 624, 2459 },
    npc = { 21217, 21865, 21873 },  -- the Lurker, Coilfang Ambusher, Coilfang Guardian (the adds while he is under)
    phases = { [2] = "Submerged" },
    alerts = {
        { key = "spout", kind = "warn", spell = 37433, text = "Spout: jump in the water",
          on = "EMOTE takes a deep breath" },
        -- Spout: first DBM 37, BW 37, CM 42 -> {37, 42}; again DBM 50 (CD), BW 50, CM 45 -> {45, 50}
        { key = "spoutbar", kind = "bar", spell = 37433, start = { 37, 42 }, on = "EMOTE takes a deep breath",
          cd = { 45, 50 }, stop = "PHASE 2", learn = false },
        -- Submerge: first DBM 90, BW 90, CM 90 -> 90; after emerging BW 90, DBM 105, CM 120 -> {90, 120}.
        -- No event of its own to learn from (the phase changes in the saved pulls time it)
        { key = "submerge", kind = "bar", icon = 28819, text = "Lurker submerges", phase = 1, start = 90,
          on = "PHASE 1", cd = { 90, 120 } },
        -- Emerge: DBM 60, BW 64, CM 60 + 3 -> {60, 64}; earlier when all nine adds die (DBM)
        { key = "emerge", kind = "bar", text = "Lurker emerges", icon = 28819, phase = 2, start = { 60, 64 } },
        { key = "under", kind = "warn", text = "Lurker submerged: adds", icon = 28819, phase = 1, setPhase = 2,
          on = { "UCAST 28819", "SPAWN 21865 21873" } },
        -- his Whirl 37363 and Geyser 37478 (BW reads both) come only while he is up
        { key = "back", kind = "warn", text = "Lurker is back", icon = 28819, phase = 2, setPhase = 1,
          on = { "BACK 21217", "HIT 37363", "SUCCESS 37478" } },
    },
    fn = {
        -- first Spout after emerging: CM about 5 s, BW 1 s after its emerge bar -> {1, 5} (unless a Whirl or Geyser
        -- told us late and his Spout already came: its bar runs from it)
        ["PHASE 1"] = function(m)
            if GetTime() - (m.last.spoutbar or -99) > 20 then m:Bar("spoutbar", { 1, 5 }) end
        end,
    },
}

local DEMON = { "YELL Be gone, trifling elf", "AURA 37673" }

B["SerpentshrineCavern:Leotheras"] = {
    enc = { 625, 2460 },
    npc = { 21215 },
    -- phase 1 is the three Spellbinders while he is banished
    phases = { [2] = "Leotheras free", [3] = "Split (15%)" },
    alerts = {
        -- free: CM removes Banish 37546 and says the line; DBM the line or 3 Spellbinders dead
        { key = "free", kind = "warn", text = "Leotheras is free", sub = "Demon form in 60 s", icon = 37546,
          on = { "AURAGONE 37546", "YELL Finally, my banishment ends" }, setPhase = 2, once = true },
        -- Demon form: first DBM 60, BW 60, CM 60 -> 60; again (demon to demon) DBM 120, CM 120, BW 105 -> {105, 120}
        { key = "demon", kind = "bar", spell = 37673, text = "Demon form", phase = 2, start = 60, on = DEMON,
          cd = { 105, 120 }, throttle = 5 },
        -- Demon form lasts DBM 60, BW 60, CM 60 -> 60
        { key = "demonends", kind = "bar", text = "Demon form ends", icon = 37673, phase = 2, on = DEMON, cd = 60,
          throttle = 5 },
        -- Inner Demons: DBM 23 (CD), BW 23, CM 20 -> {20, 23}
        { key = "innerbar", kind = "bar", spell = 37676, text = "Inner Demons", phase = 2, on = DEMON, cd = { 20, 23 },
          throttle = 5 },
        { key = "innerdemon", kind = "you", spell = 37676, text = "Inner Demon on you: kill it",
          sub = "Or it takes your mind", on = "AURA 37676", me = true },
        -- Whirlwind: again DBM 27 (CD), CM 32 -> {27, 32}; the hooks set the first one of each part
        { key = "whirl", kind = "bar", learn = false, spell = 37640, on = "AURA 37640", cd = { 27, 32 } },
        { key = "whirlwarn", kind = "warn", spell = 37640, text = "Whirlwind: get away from him", on = "AURA 37640" },
        { key = "split", kind = "warn", text = "15%: Leotheras splits", sub = "Tank both, kill Leotheras", icon = 37673,
          on = { "HP 15", "YELL No... no! What have you done" }, setPhase = 3, once = true },
    },
    fn = {
        -- after release: DBM 15, BW 15, CM 18 -> {15, 18}
        ["PHASE 2"] = function(m) m:Bar("whirl", { 15, 18 }) end,
        -- after the split: DBM 22.5, CM 13-22 -> {13, 22.5}
        ["PHASE 3"] = function(m) m:Bar("whirl", { 13, 22.5 }) end,
        -- none in demon form; back in human form BW 15 after it ends (75), CM 1-10 (61-70) -> {61, 75}
        ["YELL Be gone, trifling elf"] = function(m) m:Bar("whirl", { 61, 75 }) end,
        ["AURA 37673"] = function(m) m:Bar("whirl", { 61, 75 }) end,
    },
}

B["SerpentshrineCavern:Karathress"] = {
    enc = { 626, 2461 },
    npc = { 21214 },
    alerts = {
        -- Spitfire Totem: DBM and BW SUMMON 38236 (Tidalvess, later Karathress)
        { key = "totem", kind = "warn", spell = 38236, text = "Spitfire Totem: kill it", on = "SUMMON 38236" },
        { key = "bolt", kind = "warn", spell = 38441, role = "H", text = "Cataclysmic Bolt on %t",
          sub = "Half their health: heal them", on = "SUCCESS 38441" },
        -- Cataclysmic Bolt: CM 10 (pull and repeat; DBM and BW have none) -> 10
        { key = "boltbar", kind = "bar", spell = 38441, role = "H", start = 10, on = "SUCCESS 38441", cd = 10 },
        -- Enrage: DBM 600, BW 600, CM 600 -> 600
        { key = "enrage", kind = "bar", text = "Enrage", icon = 24318, start = 600 },
    },
}

local GRAVES = "AURA 37850 38023 38024 38025"
local GLOBULES = { "EMOTE summons watery globules", "YELL Soon it will be finished", "YELL There is nowhere to hide" }

B["SerpentshrineCavern:Morogrim"] = {
    enc = { 627, 2462 },
    npc = { 21213 },
    alerts = {
        -- Murlocs (Earthquake): first DBM 41, BW 40, CM 40 -> 40; again DBM 51, BW 51, CM 50 -> 51
        { key = "murlocs", kind = "bar", spell = 37764, text = "Murlocs", start = 40, on = "SUCCESS 37764", cd = 51 },
        { key = "murlocwarn", kind = "warn", spell = 37764, text = "Murlocs incoming", on = "SUCCESS 37764" },
        -- Watery Grave: first DBM 20, BW 20 (CM 30, its repeat value) -> 20; again DBM 28.5, BW 28.5, CM 30
        -- -> {28.5, 30}; none below 25% (CM)
        { key = "grave", kind = "bar", spell = 37850, text = "Watery Grave", start = 20, on = GRAVES, cd = { 28.5, 30 },
          stop = "HP 25", throttle = 5 },
        { key = "gravewarn", kind = "warn", spell = 37850, text = "Watery Grave", sub = "Heal the players in bubbles",
          on = GRAVES },
        { key = "graveyou", kind = "you", spell = 37850, text = "Watery Grave on you", on = GRAVES, me = true },
        { key = "globules", kind = "warn", spell = 37854, text = "25%: Water Globules", sub = "Run from them",
          on = { "HP 25", GLOBULES[1] }, once = true },
        -- Water Globules: CM 25 (DBM none, BW 36 = how long they last) -> 25
        { key = "globulebar", kind = "bar", spell = 37854, text = "Water Globules", on = GLOBULES, cd = 25,
          throttle = 5 },
    },
}

B["SerpentshrineCavern:Vashj"] = {
    enc = { 628, 2463 },
    npc = { 21212, 22009 },         -- Vashj, Tainted Elemental
    phases = { [2] = "Shield (70%)", [3] = "Vashj again" },
    alerts = {
        { key = "static", kind = "you", spell = 38280, text = "Static Charge on you: move away",
          sub = "It hits everyone near you", on = "AURA 38280", me = true },
        -- Range: BW proximity 10 yd (Static Charge); phases 1 and 3 (Static Charge stops in phase 2, CM)
        { key = "range", kind = "range", yd = 10, text = "Static Charge", on = { "ENGAGE", "PHASE 3" },
          stop = "PHASE 2" },
        -- 70%: CM below 70%, DBM and BW the yell
        { key = "phase2", kind = "warn", text = "70%: shield phase", sub = "Adds incoming", icon = 38112,
          on = { "HP 70", "YELL The time is now! Leave none standing" }, setPhase = 2, once = true },
        -- Tainted Elemental: first DBM 45 (comment: 46-57), BW 53, CM 53 -> {46, 57}; after it dies DBM 45 (same
        -- comment), BW 53, CM 50 -> {46, 57}
        { key = "elemental", kind = "bar", text = "Tainted Elemental", icon = 38132, phase = 2, start = { 46, 57 },
          on = "DIES 22009", cd = { 46, 57 } },
        -- spawn: DBM uses the elemental's first Poison Bolt cast
        { key = "elementalup", kind = "warn", spell = 38253, text = "Tainted Elemental up: kill it", phase = 2,
          on = "CAST 38253", throttle = 30 },
        -- Strider: first DBM 63, BW 63, CM 62 -> 63; again DBM 63, BW 63, CM 60 -> 63, looped as DBM and BW do. CM's
        -- Panic Periodic 38257 goes on it at spawn, but reaches only the logs of players near the spawn (17 Oct 2026:
        -- one of five pulls), so it resyncs the loop when seen
        { key = "strider", kind = "bar", text = "Coilfang Strider", icon = 38257, phase = 2, start = 63,
          on = "AURA 38257", cd = 63, throttle = 10, loop = true },
        -- Elite: first DBM 47.5, BW 47.5, CM 47 -> 47.5; again DBM 47.5, BW 47.5 (CM 46) -> 47.5, looped as DBM and
        -- BW do (no spawn event of their own)
        { key = "elite", kind = "bar", text = "Coilfang Elite", phase = 2, start = 47.5, cd = 47.5, loop = true },
        { key = "core", kind = "warn", spell = 38132, text = "Tainted Core on %t: pass it",
          meText = "Tainted Core on you: pass it", on = "AURA 38132" },
        { key = "phase3", kind = "warn", text = "Phase 3: Vashj is back", sub = "Avoid the spore clouds", icon = 38575,
          on = "YELL You may want to take cover", setPhase = 3, once = true },
        { key = "spores", kind = "you", spell = 38575, text = "Toxic Spores under you: move", on = "AURA 38575",
          me = true },
        -- Persuasion left out: pre-2.0.3 only (CM #ifdef, DBM comment); 2.5.x is post-nerf
    },
}

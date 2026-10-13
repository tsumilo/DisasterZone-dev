if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/MagtheridonsLair.lua", ...) then return end -- DisasterZone: boss mods for Magtheridon's Lair (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_A.md.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["MagtheridonsLair:Magtheridon"] = {
    enc = { 651, 2457 },
    npc = { 17257 },
    -- the 30% collapse changes no bar, so it is an event here, not a phase
    phases = { [2] = "Magtheridon free" },
    alerts = {
        -- Breaks free: DBM 120, BW 120, AC 120 (the pull is the Channelers) -> 120; earlier when they all die
        { key = "free", kind = "bar", spell = 30205, text = "Magtheridon breaks free", start = 120,
          stop = { "AURAGONE 30205", "YELL I... am... unleashed" } },
        -- free: BW AURAGONE 30205 (cage dummy), DBM the yell
        { key = "freed", kind = "warn", spell = 30205, text = "Magtheridon is free", sub = "Cube clickers get ready",
          on = { "AURAGONE 30205", "YELL I... am... unleashed" }, setPhase = 2, once = true },
        -- Blast Nova: first DBM 54 (CD, same as its repeat), BW 58, AC 58.65 (3 s attack delay + 55.65) -> {54, 59};
        -- again DBM 54 (CD), BW 51 (CD), AC 54.35-55.4 (more when a Quake delays it) -> {51, 55.4}; CM DB spell list
        { key = "novabar", kind = "bar", spell = 30616, phase = 2, start = { 54, 59 }, on = "CAST 30616",
          cd = { 51, 55.4 } },
        { key = "nova", kind = "warn", spell = 30616, text = "Blast Nova: click the cubes", on = "CAST 30616" },
        -- Collapse after the 30% line: DBM 15, CM 13 (5 + 8), AC 15 -> {13, 15}
        { key = "collapse", kind = "bar", spell = 36449, text = "Ceiling collapse",
          on = { "HP 30", "YELL Let the walls of this prison tremble" }, cd = { 13, 15 }, throttle = 5 },
        { key = "collapsewarn", kind = "warn", spell = 36449, text = "30%: the ceiling collapses",
          sub = "Debris hits everyone, heal up", on = { "HP 30", "YELL Let the walls of this prison tremble" },
          once = true },
        -- "Debris on you" left out: the falling debris targets a trigger creature, not a player (AC), and BW's
        -- "on you" (36449) is the collapse that hits everyone (TIMERS_A.md)
    },
}

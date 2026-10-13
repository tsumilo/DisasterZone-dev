if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/GruulsLair.lua", ...) then return end -- DisasterZone: boss mods for Gruul's Lair (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts, AC = AzerothCore. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_A.md.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

B["GruulsLair:Maulgar"] = {
    enc = { 649, 2455 },
    npc = { 18831, 18832, 18834, 18835, 18836 },   -- Maulgar first (HP 50); Olm 18834 ends the Felhunter bar
    alerts = {
        -- Whirlwind: first DBM 58, BW 59 (CM 30: contradicts both logs) -> 58; again DBM 55 from the buff, BW 60
        -- (CM 30-40) -> {55, 60}
        { key = "wwbar", kind = "bar", spell = 33238, start = 58, on = "AURA 33238", cd = { 55, 60 } },
        { key = "ww", kind = "warn", spell = 33238, text = "Whirlwind: melee out", sub = "For 15 s", on = "AURA 33238" },
        -- Felhunter: DBM 48.5 from SUCCESS, BW 50 from CAST start (CM 25-35) -> {48.5, 50} from the cast start
        { key = "felhunter", kind = "bar", spell = 33131, text = "Felhunter", on = "CAST 33131", cd = { 48.5, 50 },
          stop = "DIES 18834" },
        -- 50%: BW SUCCESS 33232 Flurry, CM below 50% (then Charge and Fear)
        { key = "flurry", kind = "warn", spell = 33232, text = "Maulgar 50%: Flurry", sub = "He charges and fears now",
          on = { "SUCCESS 33232", "HP 50" }, once = true },
    },
}

B["GruulsLair:Gruul"] = {
    enc = { 650, 2456 },            -- every ENCOUNTER_START id the sources know for it
    npc = { 19044 },                -- creature ids: the boss (health triggers), plus any add an alert names by id
    alerts = {
        -- Growth: DBM 30 next, BW 30 next, CM 30 -> 30
        { key = "growth", kind = "bar", spell = 36300, text = "Growth (%n)", count = "next",
          start = 30, on = "AURA 36300", cd = 30 },
        -- Ground Slam: first DBM 40, BW 33, CM 35-40 -> {33, 40}; again DBM 74 (cast start; "74-80"), BW 62 after
        -- Shatter (= 72 after the slam), CM 70-80 -> {72, 80}
        { key = "slam", kind = "bar", spell = 33525, start = { 33, 40 }, on = "CAST 33525", cd = { 72, 80 } },
        { key = "slamwarn", kind = "warn", spell = 33525, text = "Ground Slam: spread out", sub = "Shatter in 10 s",
          on = "CAST 33525" },
        -- Shatter: DBM 10 next, BW 10 -> 10
        { key = "shatter", kind = "bar", spell = 33654, on = "CAST 33525", cd = 10 },
        { key = "cavein", kind = "you", spell = 36240, text = "Cave In on you", sub = "Move out of it",
          on = "AURA 36240", me = true },
        -- Range: Shatter 33671 radius 20 yd with falloff (client data via wowhead); DBM's TODO names 11/13/18 with 18
        -- the default -> 18 (was 15)
        { key = "range", kind = "range", yd = 18, text = "Shatter", on = "CAST 33525", stop = "CAST 33654", after = 1 },
        -- Hurtful Strike: CM 8 (DBM and BW have none) -> 8
        { key = "hurtful", kind = "bar", spell = 33813, role = "T", on = "SUCCESS 33813", cd = 8 },
        -- Reverberation: first BW 102 (CD), DBM comment "15 s after the 3rd Growth" (= 105), CM 115 -> {102, 115};
        -- again BW 31 (CD), DBM comment 32-48, CM 35-45 -> {31, 48}
        { key = "reverb", kind = "bar", spell = 36297, role = "H", start = { 102, 115 }, on = "SUCCESS 36297",
          cd = { 31, 48 } },
    },
}

if DisasterZoneBoot and DisasterZoneBoot.Run("Data/BossMods/HyjalSummit.lua", ...) then return end -- DisasterZone: boss mods for Hyjal Summit (format: dev/docs/bossmods/DATA_FORMAT.md)
-- Sources per timer in the comments: DBM = DBM-Raids-BC, BW = BigWigs_BurningCrusade, CM = cmangos mangos-tbc
-- scripts. Numbers only; no code or text from them. Evidence: dev/docs/bossmods/TIMERS_B.md.
-- Hooks assume the engine handles an event's alerts first (counts, bars, warnings) and then runs fn for it.
local _, ns = ...
ns.Data = ns.Data or {}
ns.Data.BossMods = ns.Data.BossMods or {}
local B = ns.Data.BossMods

-- Trash waves. Nothing in the combat log or chat marks a wave: DBM and BW both read the wave counter widget
-- (3121 in Classic, 528 on retail). "WIDGET <id> [id...]" is NOT in the trigger grammar yet: it means
-- UPDATE_UI_WIDGET for those widget ids when the text changes, ev.spell = the widget id, ev.amount = the first
-- number in its text. 3093 is the Horde base's enemy counter (BW), so it tells which base the waves are at.
-- A wave comes when the timer runs out or as soon as every mob of the last one is dead (CM), so the bar is the
-- latest it can come. Which boss's waves (Kaz'rogal or Azgalor) only shows in the gossip, so the Horde base
-- uses windows over both.
-- Alliance base (Winterchill and Anetheron, same in every source): waves 1-7 DBM 125, BW 127.5, CM 130
-- -> {125, 130}; wave 8 to the boss DBM 140, BW 185, CM 190 -> {185, 190} (DBM's 140 is 45 s short)
local ALLY = { { 125, 130 }, { 125, 130 }, { 125, 130 }, { 125, 130 }, { 125, 130 }, { 125, 130 }, { 125, 130 },
    { 185, 190 } }
-- Horde base, Kaz'rogal / Azgalor: DBM 135 165 160 165 135 135 195 225 (one table for both), BW Kaz'rogal
-- 135 160 190 165 140 130 195 222 and Azgalor 135 190 190 195 140 165 195 225, CM Kaz'rogal 130 155 130 155 130
-- 130 155 225 and Azgalor 130 190 190 190 130 155 190 225 -> per wave the lowest and highest of all of them
local HORDE = { { 130, 135 }, { 155, 190 }, { 130, 190 }, { 155, 195 }, { 130, 140 }, { 130, 165 }, { 155, 195 },
    { 222, 225 } }
local function Elapsed(m) return m.t or (GetTime() - (m.t0 or GetTime())) end

B["HyjalSummit:Waves"] = {
    npc = { 17772, 17852 },         -- Lady Jaina Proudmoore, Thrall
    engage = { "WIDGET 3121 528" },
    phases = { [1] = "Alliance base", [2] = "Horde base" },
    alerts = {
        -- first gap: Alliance {125, 130}, Horde {130, 135}; the hook sets the base's own window
        { key = "wave", kind = "bar", text = "Wave 2 of 8", start = { 125, 135 } },
        { key = "wavewarn", kind = "warn", text = "Wave 1 of 8", sub = "Next wave in about 2 min", on = "ENGAGE" },
    },
    fn = {
        ["WIDGET 3121 528 3093"] = function(m, ev)
            if ev.spell == 3093 then
                if m.phase ~= 2 then m:Phase(2) end
                return
            end
            -- The Waves pull stays up from one boss's waves to the next (it has no encounter to end it)
            local n, t = ev.amount or 0, Elapsed(m)
            if n < 1 or n > 8 then -- 0: the boss is out, the counter is gone
                m:Stop("wave")
                if n == 0 and t > 5 then m:Warn("wavewarn", "Boss incoming") end
                return
            end
            if n > 1 or t > 5 then m:Warn("wavewarn", ("Wave %d of 8"):format(n)) end
            local gap = (m.phase == 2 and HORDE or ALLY)[n]
            m:Bar("wave", gap, n == 8 and "Boss arrives" or ("Wave %d of 8"):format(n + 1))
        end,
    },
}

B["HyjalSummit:Winterchill"] = {
    enc = { 618, 2468 },
    npc = { 17767 },
    alerts = {
        -- Death & Decay: first DBM none, BW none, CM 21-28 -> {21, 28}; again DBM 32 (CD, its comment: set to 32
        -- for TBC Classic), BW none, CM 45 -> {32, 45}
        { key = "dnd", kind = "bar", spell = 31258, start = { 21, 28 }, on = "CAST 31258", cd = { 32, 45 } },
        { key = "dndyou", kind = "you", spell = 31258, text = "Death and Decay on you", sub = "Move out of it",
          on = "AURA 31258", me = true },
        { key = "icebolt", kind = "warn", spell = 31249, role = "H", text = "Icebolt on %t", sub = "Stunned: heal them",
          on = "AURA 31249" },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["HyjalSummit:Anetheron"] = {
    enc = { 619, 2469 },
    npc = { 17808 },
    alerts = {
        -- Inferno: first DBM none, BW none, CM 30-48 -> {30, 48}; again DBM 51 (CD, "~55?"), BW 50 (CD), CM 50-55
        -- -> {50, 55}
        { key = "inferno", kind = "bar", spell = 31299, text = "Infernal", start = { 30, 48 }, on = "CAST 31299",
          cd = { 50, 55 } },
        -- DBM and BW scan the boss's target at cast start; the cast's end carries the target
        { key = "infernowarn", kind = "warn", spell = 31299, text = "Infernal on %t",
          meText = "Infernal on you: move away", on = "SUCCESS 31299" },
        -- Carrion Swarm: first DBM none, BW none, CM 20-28 -> {20, 28}; again DBM none, BW 11 (CD), CM 10-15
        -- -> {10, 15}
        { key = "swarm", kind = "bar", spell = 31306, start = { 20, 28 }, on = "SUCCESS 31306", cd = { 10, 15 } },
        -- Berserk: DBM none, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["HyjalSummit:Kazrogal"] = {
    enc = { 620, 2470 },
    npc = { 17888 },
    alerts = {
        -- Mark: first DBM 45, BW 45, CM 45 -> 45; then 5 s shorter each time: DBM and CM stop at 10, BW at 5 -> 10
        -- (the hook)
        { key = "mark", kind = "bar", learn = false, spell = 31447, start = 45 },
        { key = "markwarn", kind = "warn", spell = 31447, text = "Mark of Kaz'rogal (%n)", count = true,
          on = "CAST 31447" },
        { key = "markyou", kind = "you", spell = 31447, text = "Mark on you",
          sub = "Out of mana you explode: move away", on = "AURA 31447", me = true },
    },
    fn = {
        ["CAST 31447"] = function(m) m:Bar("mark", math.max(10, 45 - 5 * m:Count("markwarn"))) end,
    },
}

B["HyjalSummit:Azgalor"] = {
    enc = { 621, 2471 },
    npc = { 17842 },
    alerts = {
        { key = "doom", kind = "you", spell = 31347, text = "Doom on you", sub = "You die in 20 s: leave the raid",
          on = "AURA 31347", me = true },
        -- Howl: first DBM none, BW none, CM 30 -> 30; again DBM 16.7 (CD), BW 16, CM 18-20 -> {16, 20}
        { key = "howl", kind = "bar", spell = 31344, start = 30, on = "SUCCESS 31344", cd = { 16, 20 } },
        { key = "rof", kind = "you", spell = 31340, text = "Rain of Fire on you", sub = "Move out of it",
          on = "AURA 31340", me = true },
        -- Berserk: DBM 600, BW 600, CM 600 -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

B["HyjalSummit:Archimonde"] = {
    enc = { 622, 2472 },
    npc = { 17968 },
    alerts = {
        -- Fear: first DBM 40, BW 40, CM 42-50 -> {40, 50}; again DBM 41 (CD), BW 41.5 (CD), CM 42-50 -> {41, 50}
        { key = "fear", kind = "bar", spell = 31970, start = { 40, 50 }, on = "CAST 31970", cd = { 41, 50 } },
        -- DBM and BW scan the boss's target at cast start; the cast's end carries the target
        { key = "airburst", kind = "warn", spell = 32014, text = "Air Burst on %t", meText = "Air Burst on you",
          on = "SUCCESS 32014" },
        -- Doomfire: not in DBM or BW; 31944 is the burn that sticks, 31945 the fire (CM)
        { key = "doomfire", kind = "you", spell = 31944, text = "Doomfire on you", sub = "Move out of the fire",
          on = { "AURA 31944", "HIT 31945" }, me = true, throttle = 3 },
        { key = "grip", kind = "warn", spell = 31972, text = "Grip of the Legion on %t", sub = "Decurse",
          on = "AURA 31972" },
        -- Berserk: DBM 600, BW 600, CM 600 (Hand of Death) -> 600
        { key = "berserk", kind = "bar", spell = 26662, text = "Berserk", start = 600 },
    },
}

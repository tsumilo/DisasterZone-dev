-- CDLoot Games/Bingo/Detect.lua
-- ns.BingoDetect: turns raid events into Council Bingo squares. Runs only on the host of an active game
-- (one detector = one truth, no range differences between clients); everyone else gets the hits via sync.
-- Raid events only: combat log, encounters, /roll lines, ready checks, disconnects. Never loot / council.
local addonName, ns = ...

local Detect = ns:NewModule("BingoDetect")

local band = bit and bit.band
local GetTime = GetTime

local AFFIL_GROUP = (COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1) + (COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2)
    + (COMBATLOG_OBJECT_AFFILIATION_RAID or 0x4)
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x400
local TYPE_PET = (COMBATLOG_OBJECT_TYPE_PET or 0x1000) + (COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x2000)

local LUST_SPELLS = { [2825] = true, [32182] = true }   -- Bloodlust, Heroism
local BIG_CRIT = 8000
local MASS_DEATH_COUNT, MASS_DEATH_WINDOW = 3, 5
local EARLY_DEATH = 30
local SPEED_KILL, LONG_FIGHT = 120, 360

-- Per-game counters (reset on Start) and per-fight counters (reset on ENCOUNTER_START).
local game, fight

function Detect:Reset()
    game = { deaths = 0, wipes = {} }
    fight = nil
end
Detect:Reset()

local function Hit(id) ns.Bingo:Hit(id) end

local function Live()
    return ns.Bingo and ns.Bingo:IsActive() and ns.Bingo:IsHost()
end

local function IsGroup(flags, typeMask)
    if not band or type(flags) ~= "number" then return false end
    return band(flags, AFFIL_GROUP) ~= 0 and band(flags, typeMask) ~= 0
end

---------------------------------------------------------------------------
-- Handlers (public so the test harness can drive them directly)
---------------------------------------------------------------------------

function Detect:OnDeath(isPet)
    if isPet then Hit("pet_death") return end
    local now = GetTime()
    game.deaths = game.deaths + 1
    if game.deaths >= 10 then Hit("ten_deaths") end
    if not fight then
        Hit("death_trash")
        return
    end
    fight.deaths = fight.deaths + 1
    if fight.deaths >= 5 then Hit("five_deaths") end
    if now - fight.start <= EARLY_DEATH then Hit("death_first") end
    local recent = fight.recent
    recent[#recent + 1] = now
    local n = 0
    for i = #recent, 1, -1 do
        if now - recent[i] <= MASS_DEATH_WINDOW then n = n + 1 else break end
    end
    if n >= MASS_DEATH_COUNT then Hit("mass_death") end
end

function Detect:OnEncounterStart(encounterID)
    fight = { id = encounterID, start = GetTime(), deaths = 0, interrupts = 0, recent = {} }
end

function Detect:OnEncounterEnd(encounterID, success)
    local f = fight
    fight = nil
    local duration = f and (GetTime() - f.start) or 0
    if duration > LONG_FIGHT then Hit("long_fight") end
    if success == 1 or success == true then
        Hit("boss_kill")
        if f and f.deaths == 0 then Hit("flawless") end
        if f and duration < SPEED_KILL then Hit("speed_kill") end
    else
        Hit("wipe")
        local id = encounterID or 0
        game.wipes[id] = (game.wipes[id] or 0) + 1
        if game.wipes[id] >= 2 then Hit("wipe_twice") end
    end
end

function Detect:OnRoll(value, lo, hi)
    if lo ~= 1 or hi ~= 100 then return end
    if value == 1 then Hit("roll_1") end
    if value == 100 then Hit("roll_100") end
    if value == 69 then Hit("roll_69") end
    if value <= 5 then Hit("roll_low") end
end

function Detect:OnCombatLog(sub, srcFlags, dstFlags, ...)
    if sub == "UNIT_DIED" then
        if IsGroup(dstFlags, TYPE_PLAYER) then self:OnDeath(false)
        elseif IsGroup(dstFlags, TYPE_PET) then self:OnDeath(true) end
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        if not IsGroup(dstFlags, TYPE_PLAYER) then return end
        local env = ...
        env = type(env) == "string" and env:upper() or ""
        if env == "FALLING" then Hit("fall")
        elseif env == "DROWNING" then Hit("drown")
        elseif env == "FIRE" or env == "LAVA" then Hit("fire") end
    elseif sub == "SPELL_CAST_SUCCESS" then
        local spellId = ...
        if LUST_SPELLS[spellId] and IsGroup(srcFlags, TYPE_PLAYER) then Hit("lust") end
    elseif sub == "SPELL_RESURRECT" then
        if fight and IsGroup(srcFlags, TYPE_PLAYER) then Hit("bres") end
    elseif sub == "SPELL_INTERRUPT" then
        if fight and IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET) then
            fight.interrupts = fight.interrupts + 1
            if fight.interrupts >= 10 then Hit("interrupts") end
        end
    elseif sub == "SWING_DAMAGE" then
        local amount, _, _, _, _, _, critical = ...
        if critical and (amount or 0) >= BIG_CRIT and IsGroup(srcFlags, TYPE_PLAYER) then Hit("big_crit") end
    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" then
        local _, _, _, amount, _, _, _, _, _, critical = ...
        if critical and (amount or 0) >= BIG_CRIT and IsGroup(srcFlags, TYPE_PLAYER) then Hit("big_crit") end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnCLEU()
    if not Live() then return end
    local _, sub, _, _, _, srcFlags, _, _, _, dstFlags, _ = CombatLogGetCurrentEventInfo()
    Detect:OnCombatLog(sub, srcFlags, dstFlags, select(12, CombatLogGetCurrentEventInfo()))
end

function Detect:OnInit()
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCLEU)
    ns:RegisterEvent("ENCOUNTER_START", function(_, id)
        if Live() then Detect:OnEncounterStart(id) end
    end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, id, _, _, _, success)
        if Live() then Detect:OnEncounterEnd(id, success) end
    end)
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text)
        if not Live() or not ns.Roll or not ns.Roll.ParseRollLine then return end
        local key, v, lo, hi = ns.Roll:ParseRollLine(text)
        if key then Detect:OnRoll(v, lo, hi) end
    end)
    ns:RegisterEvent("READY_CHECK_CONFIRM", function(_, unit, isReady)
        if Live() and not isReady then Hit("not_ready") end
    end)
    ns:RegisterEvent("UNIT_CONNECTION", function(_, unit, isConnected)
        if Live() and isConnected == false and type(unit) == "string" and (unit:find("^raid") or unit:find("^party")) then
            Hit("dc")
        end
    end)
end

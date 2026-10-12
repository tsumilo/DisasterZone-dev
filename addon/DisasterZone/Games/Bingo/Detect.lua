if DisasterZoneBoot and DisasterZoneBoot.Run("Games/Bingo/Detect.lua", ...) then return end -- DisasterZone Games/Bingo/Detect.lua
-- ns.BingoDetect: turns raid events into Council Bingo squares. Runs only on the host of an active game
-- (one detector = one truth, no range differences between clients); everyone else gets the hits via sync.
-- Raid events only: combat log, encounters, /roll lines, ready checks, raid chat, disconnects. Never loot / council.
local addonName, ns = ...

local Detect = ns:NewModule("BingoDetect")
local Util = ns.Util

local band = bit and bit.band
local GetTime = GetTime

local AFFIL_GROUP = (COMBATLOG_OBJECT_AFFILIATION_MINE or 0x1) + (COMBATLOG_OBJECT_AFFILIATION_PARTY or 0x2)
    + (COMBATLOG_OBJECT_AFFILIATION_RAID or 0x4)
local TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER or 0x400
local TYPE_PET = (COMBATLOG_OBJECT_TYPE_PET or 0x1000) + (COMBATLOG_OBJECT_TYPE_GUARDIAN or 0x2000)

local BIG_CRIT, BIG_OVERKILL = 8000, 5000
local MASS_DEATH_COUNT, MASS_DEATH_WINDOW = 3, 5
local EARLY_DEATH, LATE_DEATH = 30, 10
local SPEED_KILL, LONG_FIGHT, INSTANT_WIPE = 120, 360, 20
local CLUTCH_ALIVE, CLUTCH_MIN_GROUP = 5, 10
local FALL_DEATH_WINDOW = 2         -- a death this soon after fall damage is a fall death
local BUBBLE_HEARTH_WINDOW = 20     -- bubble (12s) + hearth cast (10s)
local FEIGN_WIPE_WINDOW = 20
local READY_CHECK_MAX = 40          -- a check we never saw finish is over after this
local IDLE_SECONDS = 15 * 60
local TICK = 2

-- Spell groups, matched by id or by (English) name so other ranks and item variants count too.
-- like = plain substring of the lowercased name; skip = substring that rules a name out.
local SPELLS = {
    lust   = { ids = { 2825, 32182 }, names = { "Bloodlust", "Heroism" } },
    bubble = { ids = { 642, 1020, 498, 5573 }, names = { "Divine Shield", "Divine Protection" } },
    hearth = { ids = { 8690 }, names = { "Hearthstone" } },
    ankh   = { ids = { 20608, 21169 }, names = { "Reincarnation" } },
    feign  = { ids = { 5384 }, names = { "Feign Death" } },
    drums  = { ids = { 35474, 35475, 35476, 35477, 35478 }, like = "drums of " },
    loh    = { ids = { 633, 2800, 10310, 27154 }, names = { "Lay on Hands" } },
    stone  = { ids = { 27235, 27236, 27237 }, like = "healthstone", skip = "create" },
    taunt  = { ids = { 355, 6795, 31789, 31790, 694, 7400, 7402, 20559, 20560, 25266, 1161, 5209 },
               names = { "Taunt", "Growl", "Righteous Defense", "Mocking Blow", "Challenging Shout",
                         "Challenging Roar" } },
}
for _, g in pairs(SPELLS) do
    local ids, names = {}, {}
    for _, id in ipairs(g.ids) do ids[id] = true end
    for _, n in ipairs(g.names or {}) do names[n:lower()] = true end
    g.ids, g.names = ids, names
end

local function Is(g, spellId, spellName)
    local n = type(spellName) == "string" and spellName:lower() or nil
    if n and g.skip and n:find(g.skip, 1, true) then return false end
    if spellId and g.ids[spellId] then return true end
    if not n then return false end
    return g.names[n] or (g.like ~= nil and n:find(g.like, 1, true) ~= nil)
end

local DAMAGE = { SWING_DAMAGE = true, SPELL_DAMAGE = true, RANGE_DAMAGE = true, SPELL_PERIODIC_DAMAGE = true }
local TAUNT_MISS = { RESIST = true, MISS = true }

-- Per-game counters (reset on Start) and per-fight counters (reset on ENCOUNTER_START).
local game, fight

function Detect:Reset()
    game = { deaths = 0, wipes = {}, fell = {}, bubbled = {}, lastAction = GetTime() }
    fight = nil
end
Detect:Reset()

-- A name without any realm (Util.ShortName), nil for no name (the square then shows nobody).
local function ShortName(name)
    return type(name) == "string" and Util.ShortName(name, true) or nil
end

-- who: the raider (or pet, or boss) that set the square off, shown on the card. Optional.
local function Hit(id, who) ns.Bingo:Hit(id, ShortName(who)) end

local function UnitShortName(unit)
    return ShortName(UnitName(unit))
end

local function Live()
    return ns.Bingo and ns.Bingo:IsActive() and ns.Bingo:IsHost()
end

local function IsGroup(flags, typeMask)
    if not band or type(flags) ~= "number" then return false end
    return band(flags, AFFIL_GROUP) ~= 0 and band(flags, typeMask) ~= 0
end

local function GroupUnits()
    local units = {}
    local n = GetNumGroupMembers() or 0
    if IsInRaid() then
        for i = 1, n do units[#units + 1] = "raid" .. i end
    else
        units[1] = "player"
        for i = 1, n - 1 do units[#units + 1] = "party" .. i end
    end
    return units
end

-- Strips colour codes, links and {raid target} markers from a chat line.
local function Plain(text)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("{[^}]*}", "")
    return text
end

---------------------------------------------------------------------------
-- Handlers (public so the test harness can drive them directly)
---------------------------------------------------------------------------

-- name: the dead raider's (or pet's) name, for the card.
function Detect:OnDeath(isPet, guid, name)
    if isPet then Hit("pet_death", name) return end
    local now = GetTime()
    game.deaths = game.deaths + 1
    if game.deaths >= 10 then Hit("ten_deaths", name) end
    local fell = guid and game.fell[guid]
    if fell and now - fell <= FALL_DEATH_WINDOW then Hit("fall_death", name) end
    if not fight then
        Hit("death_trash", name)
        return
    end
    fight.deaths = fight.deaths + 1
    fight.lastDeath, fight.lastDeathName = now, name
    if guid then fight.died[guid] = true end
    if fight.deaths >= 5 then Hit("five_deaths", name) end
    if now - fight.start <= EARLY_DEATH then Hit("death_first", name) end
    local recent = fight.recent
    recent[#recent + 1] = now
    local n = 0
    for i = #recent, 1, -1 do
        if now - recent[i] <= MASS_DEATH_WINDOW then n = n + 1 else break end
    end
    if n >= MASS_DEATH_COUNT then Hit("mass_death", name) end
end

function Detect:OnEncounterStart(encounterID, encounterName)
    local now = GetTime()
    fight = { id = encounterID, name = encounterName, start = now, deaths = 0, interrupts = 0, recent = {}, died = {} }
    game.lastAction = now
    local rc = game.readyCheck
    if rc and now - rc.start <= READY_CHECK_MAX then Hit("rc_pull", encounterName) end
end

function Detect:OnEncounterEnd(encounterID, success, encounterName)
    local f = fight
    fight = nil
    local now = GetTime()
    game.lastAction = now
    local duration = f and (now - f.start) or 0
    local id = encounterID or 0
    local boss = encounterName or (f and f.name)
    if duration > LONG_FIGHT then Hit("long_fight", boss) end
    if success == 1 or success == true then
        Hit("boss_kill", boss)
        if (game.wipes[id] or 0) >= 1 then Hit("redemption", boss) end
        if f and f.deaths == 0 then Hit("flawless", boss) end
        if f and duration < SPEED_KILL then Hit("speed_kill", boss) end
        if f and f.lastDeath and now - f.lastDeath <= LATE_DEATH then Hit("late_death", f.lastDeathName) end
        local units, alive = GroupUnits(), 0
        for _, u in ipairs(units) do
            if UnitIsConnected(u) and not UnitIsDeadOrGhost(u) then alive = alive + 1 end
        end
        if #units >= CLUTCH_MIN_GROUP and alive <= CLUTCH_ALIVE then Hit("clutch", boss) end
    else
        Hit("wipe", boss)
        if f and duration < INSTANT_WIPE then Hit("instant_wipe", boss) end
        if f and f.feign and now - f.feign <= FEIGN_WIPE_WINDOW then Hit("feign_wipe", f.feignName) end
        game.wipes[id] = (game.wipes[id] or 0) + 1
        if game.wipes[id] >= 2 then Hit("wipe_twice", boss) end
    end
end

-- key: the roller's name key (from Roll:ParseRollLine).
function Detect:OnRoll(value, lo, hi, key)
    if lo ~= 1 or hi ~= 100 then
        Hit("odd_roll", key)
        return
    end
    if value == 1 then Hit("roll_1", key) end
    if value == 100 then Hit("roll_100", key) end
    if value == 69 then Hit("roll_69", key) end
    if value == 42 then Hit("roll_42", key) end
    if value <= 5 then Hit("roll_low", key) end
    if value >= 11 and value <= 99 and value % 11 == 0 then Hit("roll_doubles", key) end
    local last = game.lastRoll
    if last and last.value == value and key and last.key ~= key then Hit("roll_twins", key) end
    game.lastRoll = { value = value, key = key }
end

function Detect:OnReadyCheck(initiator)
    game.readyCheck = { start = GetTime(), answered = {}, notReady = false, initiator = ShortName(initiator) }
end

function Detect:OnReadyCheckConfirm(unit, isReady)
    if not isReady then Hit("not_ready", UnitShortName(unit)) end
    local rc = game.readyCheck
    if not rc then return end
    local key = Util.UnitKey(unit)
    if key then rc.answered[key] = true end
    if not isReady then rc.notReady = true end
end

function Detect:OnReadyCheckFinished()
    local rc = game.readyCheck
    game.readyCheck = nil
    if not rc then return end
    local asleep, notReady = nil, rc.notReady
    for _, u in ipairs(GroupUnits()) do
        local key = Util.UnitKey(u)
        if key and UnitIsConnected(u) then
            local status = GetReadyCheckStatus and GetReadyCheckStatus(u)
            if status == "notready" then notReady = true end
            local answered = rc.answered[key] or status == "ready" or status == "notready"
                or (rc.initiator ~= nil and UnitShortName(u) == rc.initiator)
            if not answered and not asleep then asleep = UnitShortName(u) or true end
        end
    end
    if asleep then Hit("rc_asleep", type(asleep) == "string" and asleep or nil)
    elseif not notReady then Hit("rc_all_ready") end
end

-- author: who sent the line (the chat event's second argument).
function Detect:OnRaidWarning(text, author)
    if type(text) ~= "string" then return end
    local plain = Plain(text)
    local _, upper = plain:gsub("%u", "")
    if upper >= 8 and not plain:find("%l") then Hit("caps_warning", author) end
end

function Detect:OnRaidChat(text, author)
    if type(text) ~= "string" or text:find("^%[DisasterZone") or text:find("^%[CDLoot") then return end
    local s = " " .. Plain(text):lower() .. " "
    if s:find("[^%a]sor+y+[^%a]") or s:find("[^%a]sry[^%a]") or s:find("[^%a]my bad[^%a]") then Hit("sorry", author) end
end

-- Every TICK seconds: releases during a fight, and long stretches without any fighting.
function Detect:OnTick()
    local now = GetTime()
    if fight then
        for _, u in ipairs(GroupUnits()) do
            local guid = UnitGUID(u)
            if guid and fight.died[guid] and UnitIsGhost(u) then
                Hit("early_release", UnitShortName(u))
                break
            end
        end
    elseif now - game.lastAction >= IDLE_SECONDS then
        Hit("idle")
    end
end

function Detect:OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags, ...)
    local srcPlayer = IsGroup(srcFlags, TYPE_PLAYER)
    local dstPlayer = IsGroup(dstFlags, TYPE_PLAYER)
    if DAMAGE[sub] and (IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET) or dstPlayer) then game.lastAction = GetTime() end
    if sub == "UNIT_DIED" then
        if dstPlayer then self:OnDeath(false, dstGUID, dstName)
        elseif IsGroup(dstFlags, TYPE_PET) then self:OnDeath(true, nil, dstName) end
    elseif sub == "ENVIRONMENTAL_DAMAGE" then
        if not dstPlayer then return end
        local env, _, overkill = ...
        env = type(env) == "string" and env:upper() or ""
        overkill = tonumber(overkill) or 0
        if env == "FALLING" then
            Hit("fall", dstName)
            if dstGUID then game.fell[dstGUID] = GetTime() end
            if overkill > 0 then Hit("fall_death", dstName) end
        elseif env == "DROWNING" then Hit("drown", dstName)
        elseif env == "FIRE" or env == "LAVA" then Hit("fire", dstName) end
        if overkill >= BIG_OVERKILL then Hit("overkill", dstName) end
    elseif sub == "SPELL_CAST_SUCCESS" then
        if not srcPlayer then return end
        local spellId, spellName = ...
        if Is(SPELLS.lust, spellId, spellName) then Hit("lust", srcName)
        elseif Is(SPELLS.bubble, spellId, spellName) then
            if srcGUID then game.bubbled[srcGUID] = GetTime() end
        elseif Is(SPELLS.hearth, spellId, spellName) then
            local t = srcGUID and game.bubbled[srcGUID]
            if t and GetTime() - t <= BUBBLE_HEARTH_WINDOW then Hit("bubble_hearth", srcName) end
        elseif Is(SPELLS.ankh, spellId, spellName) then Hit("ankh", srcName)
        elseif Is(SPELLS.feign, spellId, spellName) then
            if fight then fight.feign, fight.feignName = GetTime(), srcName end
        elseif Is(SPELLS.drums, spellId, spellName) then Hit("drums", srcName)
        elseif Is(SPELLS.loh, spellId, spellName) then Hit("loh", srcName)
        elseif Is(SPELLS.stone, spellId, spellName) then Hit("healthstone", srcName) end
    elseif sub == "SPELL_RESURRECT" then
        if not srcPlayer then return end
        local spellId, spellName = ...
        if Is(SPELLS.ankh, spellId, spellName) then Hit("ankh", srcName)
        elseif fight then Hit("bres", srcName) end
    elseif sub == "SPELL_INTERRUPT" then
        if fight and IsGroup(srcFlags, TYPE_PLAYER + TYPE_PET) then
            fight.interrupts = fight.interrupts + 1
            if fight.interrupts >= 10 then Hit("interrupts", srcName) end
        end
    elseif sub == "SPELL_MISSED" then
        local spellId, spellName, _, missType = ...
        if srcPlayer and TAUNT_MISS[missType] and Is(SPELLS.taunt, spellId, spellName) then
            Hit("taunt_resist", srcName)
        end
    elseif sub == "SWING_DAMAGE" then
        local amount, overkill, _, _, _, _, critical, _, crushing = ...
        if critical and (tonumber(amount) or 0) >= BIG_CRIT and srcPlayer then Hit("big_crit", srcName) end
        if dstPlayer then
            if crushing then Hit("crushing", dstName) end
            if (tonumber(overkill) or 0) >= BIG_OVERKILL then Hit("overkill", dstName) end
        end
    elseif sub == "SPELL_DAMAGE" or sub == "RANGE_DAMAGE" or sub == "SPELL_PERIODIC_DAMAGE" then
        local _, _, _, amount, overkill, _, _, _, _, critical = ...
        if critical and (tonumber(amount) or 0) >= BIG_CRIT and srcPlayer then Hit("big_crit", srcName) end
        if dstPlayer and (tonumber(overkill) or 0) >= BIG_OVERKILL then Hit("overkill", dstName) end
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnCLEU()
    if not Live() then return end
    local _, sub, _, srcGUID, srcName, srcFlags, _, dstGUID, dstName, dstFlags = CombatLogGetCurrentEventInfo()
    Detect:OnCombatLog(sub, srcGUID, srcName, srcFlags, dstGUID, dstName, dstFlags,
        select(12, CombatLogGetCurrentEventInfo()))
end

local function OnRaidChat(_, text, author)
    if Live() then Detect:OnRaidChat(text, author) end
end

function Detect:OnInit()
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCLEU)
    ns:RegisterEvent("ENCOUNTER_START", function(_, id, name)
        if Live() then Detect:OnEncounterStart(id, name) end
    end)
    ns:RegisterEvent("ENCOUNTER_END", function(_, id, name, _, _, success)
        if Live() then Detect:OnEncounterEnd(id, success, name) end
    end)
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text)
        if not Live() or not ns.Roll or not ns.Roll.ParseRollLine then return end
        local key, v, lo, hi = ns.Roll:ParseRollLine(text)
        if key then Detect:OnRoll(v, lo, hi, key) end
    end)
    ns:RegisterEvent("READY_CHECK", function(_, initiator)
        if Live() then Detect:OnReadyCheck(initiator) end
    end)
    ns:RegisterEvent("READY_CHECK_CONFIRM", function(_, unit, isReady)
        if Live() then Detect:OnReadyCheckConfirm(unit, isReady) end
    end)
    ns:RegisterEvent("READY_CHECK_FINISHED", function()
        if Live() then Detect:OnReadyCheckFinished() end
    end)
    ns:RegisterEvent("UNIT_CONNECTION", function(_, unit, isConnected)
        if Live() and isConnected == false and type(unit) == "string" and (unit:find("^raid") or unit:find("^party")) then
            Hit("dc", UnitShortName(unit))
        end
    end)
    ns:RegisterEvent("CHAT_MSG_RAID_WARNING", function(_, text, author)
        if Live() then Detect:OnRaidWarning(text, author) end
    end)
    for _, ev in ipairs({ "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" }) do
        ns:RegisterEvent(ev, OnRaidChat)
    end
    C_Timer.NewTicker(TICK, function()
        if Live() then Detect:OnTick() end
    end)
end

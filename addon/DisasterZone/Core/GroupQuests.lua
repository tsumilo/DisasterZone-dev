if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GroupQuests.lua", ...) then return end -- DisasterZone: Core/GroupQuests.lua
-- (1.5) Group quests for the Groups board: the list (Data/GroupQuests.lua, generated from the TBC world DB: quests
-- made for 2+ players, by zone), the ones in my quest log (C_QuestLog.IsOnQuest over the list, after the log changes),
-- search by name. A quest and its Alliance / Horde twin are one key (the lower id), so a group for "Wanted: Durn"
-- is one group whatever side lists it. The guild side (who has which quest, the group already listed for a quest)
-- lives in Core/DungeonRuns.lua (profiles, the board).
local addonName, ns = ...

local GQ = ns:NewModule("GroupQuests")

local ipairs, pairs, type, tonumber = ipairs, pairs, type, tonumber
local lower, find = string.lower, string.find
local tsort = table.sort

local byId, zones, list   -- [id] = quest record; the zones in board order; every quest record in data order
local mine = {}           -- [key] = true: the group quests in my log
local MAX_MINE = 30       -- (the profile carries this many at most)

-- The data as records: { id, key, name, zone (index), players, step, steps, side, twin }.
local function Index()
    if byId then return end
    byId, zones, list = {}, {}, {}
    local D = ns.Data and ns.Data.GroupQuests
    if type(D) ~= "table" then return end
    for i, z in ipairs(D.zones or {}) do
        zones[i] = { index = i, key = z.key, name = z.name, area = z.area, screen = z.screen, cx = z.cx or 0.5,
                     cy = z.cy or 0.5 }
    end
    for _, e in ipairs(D.quests or {}) do
        local id = tonumber(e[1])
        if id then
            local q = { id = id, name = e[2], zone = e[3], players = e[4] or 3, step = e[5], steps = e[6],
                        side = e[7], twin = e[8] }
            q.key = (q.twin and q.twin < id) and q.twin or id
            byId[id] = q
            list[#list + 1] = q
        end
    end
end

-- A quest (either twin's id): its record, or nil when it isn't a group quest.
function GQ:Get(id)
    Index()
    return byId[tonumber(id) or 0]
end

-- The one key of a quest and its twin (the lower id); nil for an id that isn't a group quest.
function GQ:Key(id)
    local q = self:Get(id)
    return q and q.key or nil
end

function GQ:GetName(id)
    local q = self:Get(id)
    return q and q.name or nil
end

-- The zones in board order: { index, key, name, screen, cx, cy } (a copy of the list, the records shared).
function GQ:GetZones()
    Index()
    local out = {}
    for i, z in ipairs(zones) do out[i] = z end
    return out
end
function GQ:GetZone(i)
    Index()
    return zones[tonumber(i) or 0]
end

-- The quests of a zone (one record per key: my side's id when the quest has twins).
local function MySide(q)
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local side = faction == "Alliance" and "A" or (faction == "Horde" and "H") or nil
    return not (q.side and side and q.side ~= side)
end
function GQ:GetZoneQuests(zone)
    Index()
    local out = {}
    for _, q in ipairs(list) do
        if q.zone == zone and MySide(q) then out[#out + 1] = q end
    end
    return out
end

-- Quests whose name holds `text` (any case), my side's, at most `limit` (40).
function GQ:Search(text, limit)
    Index()
    local out = {}
    text = lower(text or "")
    if text == "" then return out end
    for _, q in ipairs(list) do
        if MySide(q) and find(lower(q.name or ""), text, 1, true) then
            out[#out + 1] = q
            if #out >= (limit or 40) then break end
        end
    end
    return out
end

-- How many group quests there are (my side's).
function GQ:Count()
    Index()
    local n = 0
    for _, q in ipairs(list) do
        if MySide(q) then n = n + 1 end
    end
    return n
end

---------------------------------------------------------------------------
-- My quest log
---------------------------------------------------------------------------

local function InLog(id)
    local Q = C_QuestLog
    return Q and Q.IsOnQuest and Q.IsOnQuest(id) and true or false
end

-- Looks through the log again (the group quests only); fires GROUP_QUESTS_UPDATED when that set changed, with true
-- when it changed only because demo mode came on or went off (nothing to tell the guild, no group of mine ends).
local scannedDemo = false
function GQ:Scan()
    Index()
    local now, changed = {}, false
    local demo = ns.Util.DemoOn() and true or false
    local swapped = demo ~= scannedDemo
    scannedDemo = demo
    if demo then
        -- (demo: a made-up log, Terokkar and Nagrand)
        for _, id in ipairs({ 11073, 9977, 9937, 9853 }) do
            local q = byId[id]
            if q then now[q.key] = true end
        end
    else
        for _, q in ipairs(list) do
            if InLog(q.id) then now[q.key] = true end
        end
    end
    for k in pairs(now) do if not mine[k] then changed = true end end
    for k in pairs(mine) do if not now[k] then changed = true end end
    mine = now
    if changed then ns:Fire("GROUP_QUESTS_UPDATED", swapped) end
    return changed
end

-- Is the quest (either twin) in my log?
function GQ:IsInMyLog(id)
    local k = self:Key(id)
    return k ~= nil and mine[k] == true
end

-- The keys of the group quests in my log, in data order (zone, level), at most MAX_MINE.
function GQ:GetMine()
    Index()
    local out = {}
    for _, q in ipairs(list) do
        if q.key == q.id and mine[q.key] then
            out[#out + 1] = q.key
            if #out >= MAX_MINE then break end
        end
    end
    return out
end

-- (tests, demo) sets my log's group quests as keys.
function GQ:SetMine(keys)
    mine = {}
    for _, k in ipairs(keys or {}) do
        local key = self:Key(k)
        if key then mine[key] = true end
    end
    ns:Fire("GROUP_QUESTS_UPDATED")
end

-- Sorts quest records by zone order, then name.
function GQ:Sort(records)
    tsort(records, function(a, b)
        if a.zone ~= b.zone then return (a.zone or 99) < (b.zone or 99) end
        return (a.name or "") < (b.name or "")
    end)
    return records
end

function GQ:OnInit()
    local Util = ns.Util
    local function rescan() Util.Debounce("group-quests-scan", 1, function() GQ:Scan() end) end
    for _, ev in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN", "PLAYER_ENTERING_WORLD" }) do
        ns:RegisterEvent(ev, rescan)
    end
    ns:On("DEMO_TOGGLED", rescan)
end

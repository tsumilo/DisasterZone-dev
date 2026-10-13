if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Tanks.lua", ...) then return end -- DisasterZone: Core/Tanks.lua
-- Who tanks (ns.Tanks): the raid's main tanks, one list for every part that asks (the raid frames' tank block and
-- shields, boss mods, blessings, the threat meter). Mockup claude.ai/artifact/CsS7UiuQrEXProchyuQ7jb, 2026-10-13.
--   * the game's own flag is the truth: GetRaidRosterInfo's role "MAINTANK", set with /maintank, by any addon or by
--     the tank block (UI/LookTanks.lua). Setting it is protected (a real click on a secure button, the raid leader or
--     an assistant: Tanks:CanSet), so nothing here sets it;
--   * their order (main tank 1, 2, ...): the leader's (dragged in the tank block, shared with the raid: MTO from the
--     leader or an assistant), else the plan's, else the raid's own order;
--   * the plan (Tanks:Plan): the current boss's strategy rows whose player is a tank (StrategyLive:PlanTanks), shown
--     greyed when nobody is set yet, with a button that sets them all in one click (Tanks:PlanMacro).
-- Fires TANKS_CHANGED when the list, its order or the plan changed.
local addonName, ns = ...

local Tanks = ns:NewModule("Tanks")
local Util = ns.Util

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local tsort, tconcat = table.sort, table.concat

local MAX_ORDER = 40
local RESHARE_AFTER = 3          -- seconds after somebody joined: the leader's order goes out again

local list = {}                  -- { { name = roster name, key, unit = "raidN", index, class, online, dead } }, in order
local byKey = {}                 -- key -> position in list
local order = {}                 -- keys in the leader's order (MTO): may name people who aren't main tanks (skipped)
local orderMine = false          -- I set the order (I share it again when somebody joins)
local plan = {}                  -- { { key, label, mark } } (Tanks:Plan)
local sig = ""
local members = 0

local function InRaid() return IsInRaid and IsInRaid() and true or false end

-- The current boss's plan: { { key, label, mark } } from its strategy's tank rows.
local function ReadPlan()
    local Live = ns.StrategyLive
    local ok, rows = false, nil
    if Live and Live.PlanTanks then ok, rows = pcall(Live.PlanTanks, Live) end
    return (ok and type(rows) == "table") and rows or {}
end

local function Rank(e, planPos)
    for i, k in ipairs(order) do
        if k == e.key then return i end
    end
    local p = planPos[e.key]
    if p then return 100 + p end
    return 1000 + e.index
end

-- Reads the roster and the plan again; fires TANKS_CHANGED when anything a reader sees changed.
function Tanks:Rebuild()
    local out = {}
    if InRaid() and GetRaidRosterInfo then
        local n = math.min(40, tonumber(GetNumGroupMembers and GetNumGroupMembers() or 0) or 0)
        for i = 1, n do
            local name, _, _, _, _, class, _, online, dead, role = GetRaidRosterInfo(i)
            if type(name) == "string" and name ~= "" and name ~= UNKNOWNOBJECT and role == "MAINTANK" then
                out[#out + 1] = { name = name, key = Util.NormalizeName(name), unit = "raid" .. i, index = i,
                                  class = class, online = online and true or false, dead = dead and true or false }
            end
        end
    end
    plan = ReadPlan()
    local planPos = {}
    for i, p in ipairs(plan) do planPos[p.key] = planPos[p.key] or i end
    for _, e in ipairs(out) do e.rank = Rank(e, planPos) end
    tsort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.index < b.index
    end)
    list, byKey = out, {}
    local parts = {}
    for i, e in ipairs(out) do
        byKey[e.key] = i
        parts[#parts + 1] = e.name .. ":" .. e.unit
    end
    for _, p in ipairs(plan) do parts[#parts + 1] = "p" .. tostring(p.key) .. ":" .. tostring(p.label) .. ":" .. tostring(p.mark) end
    local s = tconcat(parts, ",")
    if s ~= sig then
        sig = s
        ns:Fire("TANKS_CHANGED")
    end
end

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

-- The main tanks in order: { { name, key, unit, index, class, online, dead } } (a copy-free list: don't change it).
function Tanks:List() return list end

-- Main tank number of a player (key "Name-Realm"), or nil.
function Tanks:Number(key) return key and byKey[key] or nil end

-- Main tank number of a unit ("raid7", "player", ...), or nil.
function Tanks:NumberOfUnit(unit)
    if #list == 0 or not unit then return nil end
    local key = Util.UnitKey and Util.UnitKey(unit)
    return key and byKey[key] or nil
end

function Tanks:IsMain(key) return key ~= nil and byKey[key] ~= nil end

-- Am I a main tank (the game's flag, read now)?
function Tanks:IsMe()
    if not InRaid() or not GetPartyAssignment then return false end
    return GetPartyAssignment("MAINTANK", "player") and true or false
end

-- Can I set and clear main tanks (the raid leader or an assistant, in a raid)?
function Tanks:CanSet()
    if not InRaid() then return false end
    local lead = UnitIsGroupLeader and UnitIsGroupLeader("player")
    local assist = UnitIsGroupAssistant and UnitIsGroupAssistant("player")
    return (lead or assist) and true or false
end

-- The plan's tanks for the boss we're at: { { key, label, mark } }; PlanFor(key) -> that tank's row.
function Tanks:Plan() return plan end
function Tanks:PlanFor(key)
    for _, p in ipairs(plan) do
        if p.key == key then return p end
    end
    return nil
end

-- The raid members of the plan, with their roster names: { { key, name, unit, label, mark, set } }.
function Tanks:PlanInRaid()
    local out = {}
    if not InRaid() or #plan == 0 then return out end
    local n = math.min(40, tonumber(GetNumGroupMembers and GetNumGroupMembers() or 0) or 0)
    local roster = {}
    for i = 1, n do
        local name = GetRaidRosterInfo(i)
        if type(name) == "string" and name ~= "" then roster[Util.NormalizeName(name)] = { name = name, unit = "raid" .. i } end
    end
    for _, p in ipairs(plan) do
        local r = roster[p.key]
        if r then
            out[#out + 1] = { key = p.key, name = r.name, unit = r.unit, label = p.label, mark = p.mark,
                              set = byKey[p.key] ~= nil }
        end
    end
    return out
end

-- The macro that sets the plan's tanks in one click (one /maintank line per tank not set yet), or nil.
function Tanks:PlanMacro()
    local cmd = (type(SLASH_MAINTANKON1) == "string" and SLASH_MAINTANKON1 ~= "") and SLASH_MAINTANKON1 or "/maintank"
    local lines = {}
    for _, p in ipairs(self:PlanInRaid()) do
        if not p.set and not p.name:find("[%s;\n]") then lines[#lines + 1] = cmd .. " " .. p.name end
    end
    if #lines == 0 then return nil end
    return tconcat(lines, "\n")
end

-- The roster names in order, comma separated (the tank block's header shows these).
function Tanks:Names()
    local out = {}
    for i, e in ipairs(list) do out[i] = e.name end
    return tconcat(out, ",")
end

---------------------------------------------------------------------------
-- The order (the leader's, shared)
---------------------------------------------------------------------------

local function Share()
    local Comm = ns.Comm
    if not (Comm and Comm.Send) or not Tanks:CanSet() or #order == 0 then return end
    Comm:Send({ t = "MTO", o = order }, "RAID", nil, "alert")
end

-- New order (keys, first = main tank 1). The leader's / an assistant's goes to the raid.
function Tanks:SetOrder(keys)
    local o = {}
    for _, k in ipairs(type(keys) == "table" and keys or {}) do
        if type(k) == "string" and #o < MAX_ORDER then o[#o + 1] = k end
    end
    order, orderMine = o, true
    self:Rebuild()
    Share()
end

-- Moves a main tank to position pos (1 = first).
function Tanks:Move(key, pos)
    local keys = {}
    for _, e in ipairs(list) do
        if e.key ~= key then keys[#keys + 1] = e.key end
    end
    pos = math.max(1, math.min(#keys + 1, tonumber(pos) or 1))
    table.insert(keys, pos, key)
    self:SetOrder(keys)
end

-- MTO {o}: the leader's (or an assistant's) order.
local function OnOrder(sender, msg)
    if type(msg.o) ~= "table" or sender == (Util.PlayerKey and Util.PlayerKey()) then return end
    local rank = Util.GetGroupRole and Util.GetGroupRole(sender)
    if not rank or rank < 1 then return end
    local o = {}
    for _, k in ipairs(msg.o) do
        if type(k) == "string" and #k <= 64 and #o < MAX_ORDER then o[#o + 1] = k end
    end
    order, orderMine = o, false
    Tanks:Rebuild()
end

---------------------------------------------------------------------------

function Tanks:OnLogin()
    if ns.Comm and ns.Comm.Register then ns.Comm:Register("MTO", OnOrder) end
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if not InRaid() then order, orderMine = {}, false end
        local n = tonumber(GetNumGroupMembers and GetNumGroupMembers() or 0) or 0
        local joined = n > members
        members = n
        Tanks:Rebuild()
        if joined and orderMine and Util.Debounce then Util.Debounce("tanks:reshare", RESHARE_AFTER, Share) end
    end)
    -- (the plan: STRATEGY_LIVE fires on every tracked cast in a pull, the plan changes only between pulls)
    ns:On("STRATEGY_LIVE", function()
        if Util.Debounce then Util.Debounce("tanks:plan", 0.5, function() Tanks:Rebuild() end) else Tanks:Rebuild() end
    end)
    self:Rebuild()
end

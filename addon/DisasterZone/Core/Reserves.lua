if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Reserves.lua", ...) then return end -- DisasterZone: Core/Reserves.lua
-- Loot reserves (1.4.3): a raid's soft reserves, run by the raid's loot authority (GroupRules), for pug nights and
-- guild runs with a few pugs.
--   The rules: whoever soft reserved an item rolls on it, the highest roll wins (one reserver: theirs, no roll).
--   Nobody reserved it: up for grabs, everyone rolls. Items the guild holds (guild hard reserves) go to the loot
--   council among guild members, as today; when no guild member wants one, it is up for grabs too.
--   Soft reserves per player: 1-3 (the host sets it), one per item. They close at the first pull (the host can still
--   change any player's reserves after that).
--   The list (cur): { id, by (host key), v (rev), at (opened), rk (raid key), n (per player), o (open: taking
--   reserves), h = { itemID, ... } (guild hard reserves), r = { [key] = { [itemID] = src } }, cl (closed at) }.
--   src: "d" DisasterZone, "l" LootReserve, "w" whisper, "s" softres.it / Gargul / CSV import, "h" set by the host.
--   foreign = the LootReserve host's key when the list is a copy of someone else's LootReserve session (read-only).
-- The host (GroupRules:IsAuthority) holds the list: it takes reserves from its own UI, from other DisasterZone
-- clients (RVR), from whispers (Core/ReserveChat.lua), from LootReserve clients (Core/ReserveLR.lua) and imports
-- (Core/ReserveIO.lua), and sends the whole list to the raid (RVS, on RAID). A client asks for it (RVQ) after joining
-- or a /reload. Whoever becomes the authority takes over the last list it saw.
-- The loot method: the raid session's "reserve" feature (GroupRules, GS rv). Roll asks Reserves:Decide(itemID) when a
-- roll opens: "s" (only the reservers roll), "g" (held for the guild: loot council among guild members), "o" (up for
-- grabs), nil (reserves are not the loot method).
-- Demo (Util.DemoOn): a made-up pug night in memory (Reserves:DemoNight, Core/ReserveDemo.lua drives its steps);
-- nothing is sent, saved or whispered.
local addonName, ns = ...

local Reserves = ns:NewModule("Reserves")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next, select = type, pairs, ipairs, tonumber, tostring, next, select
local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat
local strlower, strmatch, strformat, strgsub, strfind = string.lower, string.match, string.format, string.gsub,
    string.find

Reserves.MIN_PER, Reserves.MAX_PER = 1, 3
local MAX_KEYS = 60                 -- players on a list
local MAX_HR = 40                   -- guild hard reserves
local MAX_KEY_LEN = 48
local MAX_ID_LEN = 64
local KEEP_SAVED = 12 * 3600        -- the host's saved list survives a /reload or relog this long
local SEND_DELAY = 0.5              -- RVS is sent this long after the last change
local ASK_DELAY = 8                 -- RVQ this long after a login / reload in a raid (after the busiest seconds)
local SOURCES = { d = true, l = true, w = true, s = true, h = true }

Reserves.SOURCE_TEXT = { d = "DisasterZone", l = "LootReserve", w = "Whisper", s = "Imported", h = "Set by the leader" }

local cur              -- the list (see above), or nil
local demoCur          -- the demo night's list (demo mode only)
local sendPending = false
local lastAskAt = 0
local askPlannedAt = -100   -- (the retries after joining are planned once per 30 s)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function List()
    if Util.DemoOn() then return demoCur end
    return cur
end

local function ValidKey(k)
    return type(k) == "string" and #k > 0 and #k <= MAX_KEY_LEN and not strfind(k, "[%c|]")
end

local function ValidItem(i)
    i = tonumber(i)
    return (i and i == floor(i) and i > 0 and i < 1000000) and i or nil
end

local function GR() return ns.GroupRules end

-- I hold the raid's list: the loot authority (or anyone in demo mode).
local function AmHost()
    if Util.DemoOn() then return true end
    if not IsInRaid() then return false end
    local G = GR()
    return (G and G.IsAuthority and G:IsAuthority()) and true or false
end

-- key leads my raid or assists in it.
local function LeadOrAssist(key)
    local unit = Util.GetPartyUnit and Util.GetPartyUnit(key)
    if not unit then return false end
    return (UnitIsGroupLeader(unit) or (UnitIsGroupAssistant and UnitIsGroupAssistant(unit))) and true or false
end

local function Changed()
    ns:Fire("RESERVES_CHANGED")
end

local function CountKey(L, key)
    local n = 0
    for _ in pairs(L and L.r and L.r[key] or {}) do n = n + 1 end
    return n
end

local function IsHR(L, itemID)
    for _, id in ipairs(L and L.h or {}) do
        if id == itemID then return true end
    end
    return false
end

local function InGroup(key)
    return Util.IsInMyGroup(key)
end

-- The raid's loot (every boss and trash of raid key rk): { [itemID] = boss key }.
local lootCache = {}
function Reserves:RaidLoot(rk)
    if not rk then return {} end
    if lootCache[rk] then return lootCache[rk] end
    local out = {}
    local DB = ns.ItemDB
    local raid = DB and DB.GetRaid and DB:GetRaid(rk)
    for _, boss in ipairs(raid and raid.bosses or {}) do
        for _, id in ipairs(boss.items or {}) do
            if out[id] == nil then out[id] = boss.key end
        end
    end
    lootCache[rk] = out
    return out
end

-- The raid's bosses in order: { { key, name, items = { ids } }, ... } (trash last).
function Reserves:Bosses(rk)
    local DB = ns.ItemDB
    local raid = rk and DB and DB.GetRaid and DB:GetRaid(rk)
    local out, trash = {}, nil
    for _, boss in ipairs(raid and raid.bosses or {}) do
        local b = { key = boss.key, name = boss.name, items = boss.items or {}, trash = boss.isTrash or boss.isChest }
        if b.trash then
            trash = trash or { key = "Trash", name = "Trash", items = {}, trash = true }
            for _, id in ipairs(b.items) do trash.items[#trash.items + 1] = id end
        else
            out[#out + 1] = b
        end
    end
    if trash then out[#out + 1] = trash end
    return out
end

-- The raid key the list is for when I open one: the instance I'm in, else the running session's linked raid, else
-- the raid of my newest planned raid today; nil when there is none.
function Reserves:GuessRaid()
    local DB = ns.ItemDB
    local inst = tonumber((select(8, GetInstanceInfo())))
    local rk = inst and DB and DB.GetRaidByInstance and DB:GetRaidByInstance(inst)
    if type(rk) == "table" then rk = rk.key end
    if rk then return rk end
    local SI = ns.SessionInfo
    local info = SI and SI.Get and SI:Get()
    if info and info.raidKey and DB and DB.ItemKeyOf then return DB:ItemKeyOf(info.raidKey) end
    return nil
end

-- The default soft reserves per player for a raid's size (10: 1, 25: 2).
function Reserves:DefaultPer(rk)
    local DB = ns.ItemDB
    local raid = rk and DB and DB.GetRaid and DB:GetRaid(rk)
    return (raid and (raid.size or 25) <= 10) and 1 or 2
end

---------------------------------------------------------------------------
-- Reading the list
---------------------------------------------------------------------------

-- A copy-free view of the list for the UI: nil when there is none.
function Reserves:Get()
    return List()
end

function Reserves:IsOpen()
    local L = List()
    return (L and L.o) and true or false
end

function Reserves:IsHost()
    local L = List()
    return AmHost() and (L == nil or L.foreign == nil)
end

function Reserves:IsForeign()
    local L = List()
    return L and L.foreign or nil
end

function Reserves:PerPlayer()
    local L = List()
    return L and L.n or 0
end

function Reserves:IsHeld(itemID)
    return IsHR(List(), tonumber(itemID))
end

-- Reserves of key: sorted { itemID, ... }.
function Reserves:Of(key)
    local L, out = List(), {}
    for id in pairs(L and L.r and L.r[key] or {}) do out[#out + 1] = id end
    tsort(out)
    return out
end

function Reserves:Left(key)
    local L = List()
    if not L then return 0 end
    return max(0, (L.n or 0) - CountKey(L, key))
end

-- Who reserved itemID: sorted { key, ... } (inGroup: only players in my group now).
function Reserves:Reservers(itemID, inGroup)
    itemID = tonumber(itemID)
    local L, out = List(), {}
    for key, set in pairs(L and L.r or {}) do
        if set[itemID] and (not inGroup or InGroup(key)) then out[#out + 1] = key end
    end
    tsort(out)
    return out
end

function Reserves:SourceOf(key, itemID)
    local L = List()
    local set = L and L.r and L.r[key]
    return set and set[tonumber(itemID)] or nil
end

-- { [itemID] = { key, ... } } of every reserved item.
function Reserves:ByItem()
    local L, out = List(), {}
    for key, set in pairs(L and L.r or {}) do
        for id in pairs(set) do
            local t = out[id]
            if not t then
                t = {}
                out[id] = t
            end
            t[#t + 1] = key
        end
    end
    for _, t in pairs(out) do tsort(t) end
    return out
end

-- Raid members without a full set of reserves (sorted keys), the count with at least one, and the raid's size.
function Reserves:Missing()
    local L = List()
    local keys = Util.GetGroupKeys()
    tsort(keys)
    local out, done = {}, 0
    for _, key in ipairs(keys) do
        local n = CountKey(L, key)
        if L and n < (L.n or 0) then out[#out + 1] = key end
        if n > 0 then done = done + 1 end
    end
    return out, done, #keys
end

-- Counts by source: { d = n, l = n, w = n, s = n, h = n }, and the total.
function Reserves:SourceCounts()
    local L, out, total = List(), { d = 0, l = 0, w = 0, s = 0, h = 0 }, 0
    for _, set in pairs(L and L.r or {}) do
        for _, src in pairs(set) do
            out[src] = (out[src] or 0) + 1
            total = total + 1
        end
    end
    return out, total
end

-- Reserves are the loot method of the running raid session (GroupRules feature "reserve").
function Reserves:IsLootMethod()
    if Util.DemoOn() then return demoCur ~= nil and demoCur.method == true end
    local G = GR()
    return (G and G.IsFeatureOn and IsInRaid() and G:IsFeatureOn("reserve")) and true or false
end

-- How a roll for itemID is decided under reserves: "s", keys (the reservers in the group; one key = theirs, no
-- roll), "g" (held for the guild), "o" (up for grabs); nil when reserves are not the loot method.
function Reserves:Decide(itemID)
    itemID = tonumber(itemID)
    if not itemID or not self:IsLootMethod() then return nil end
    local L = List()
    if IsHR(L, itemID) then return "g" end
    local keys = self:Reservers(itemID, true)
    if #keys > 0 then return "s", keys end
    return "o"
end

---------------------------------------------------------------------------
-- Changing the list (the host)
---------------------------------------------------------------------------

local SendNow   -- forward

local function Touch(L)
    L.v = (L.v or 0) + 1
    if L == cur then
        local db = ns.db
        if type(db) == "table" then db.reserves = { list = cur, savedAt = GetServerTime() } end
        if not sendPending then
            sendPending = true
            Util.After(SEND_DELAY, function()
                sendPending = false
                SendNow()
            end)
        end
    end
    Changed()
end

local function NewList(rk, n, hr)
    local me = Util.PlayerKey() or "?"
    local at = GetServerTime()
    local h = {}
    for _, id in ipairs(type(hr) == "table" and hr or {}) do
        id = ValidItem(id)
        if id and #h < MAX_HR then h[#h + 1] = id end
    end
    tsort(h)
    return { id = (Util.ShortName(me) .. "-" .. at):sub(1, MAX_ID_LEN), by = me, v = 0, at = at, rk = rk,
             n = max(Reserves.MIN_PER, min(Reserves.MAX_PER, tonumber(n) or Reserves:DefaultPer(rk))), o = true,
             h = h, r = {} }
end

-- Opens reserves (the host): opts = { rk, n, hr = { itemID, ... } }. An open list keeps its reserves (only the rules
-- change). Returns ok, err.
function Reserves:Open(opts)
    opts = opts or {}
    if not AmHost() then return false, "only the raid's loot authority (usually the raid leader) can open reserves." end
    if Util.DemoOn() then
        demoCur = demoCur or NewList(opts.rk or "SerpentshrineCavern", opts.n, opts.hr)
        demoCur.o = true
        Changed()
        return true
    end
    local rk = opts.rk or (cur and cur.rk) or self:GuessRaid()
    if not rk then return false, "enter the raid first, or link the session to a planned raid." end
    if cur and not cur.foreign and cur.rk == rk then
        cur.o = true
        cur.cl = nil
        if opts.n then cur.n = max(self.MIN_PER, min(self.MAX_PER, floor(tonumber(opts.n) or cur.n))) end
        if opts.hr then self:SetHeld(opts.hr) end
        Touch(cur)
    else
        cur = NewList(rk, opts.n, opts.hr)
        Touch(cur)
    end
    ns:Fire("RESERVES_OPENED", cur)
    return true
end

-- Stops taking reserves (the first pull, or the host by hand). The host can still change them.
function Reserves:Close()
    local L = List()
    if not (L and AmHost() and not L.foreign) then return false end
    if not L.o then return true end
    L.o = false
    L.cl = GetServerTime()
    Touch(L)
    ns:Fire("RESERVES_CLOSED", L)
    return true
end

-- Throws the list away (the host): every client drops it.
function Reserves:Clear()
    if Util.DemoOn() then
        demoCur = nil
        Changed()
        return true
    end
    if not (AmHost() and cur) then return false end
    local id = cur.id
    cur = nil
    local db = ns.db
    if type(db) == "table" then db.reserves = nil end
    local Comm = ns.Comm
    if Comm and Comm.Send and IsInRaid() then Comm:Send({ t = "RVS", id = id, x = true }, "RAID", nil, "ctrl") end
    ns:Fire("RESERVES_CLEARED", id)
    Changed()
    return true
end

function Reserves:SetPerPlayer(n)
    local L = List()
    if not (L and AmHost() and not L.foreign) then return false end
    n = max(self.MIN_PER, min(self.MAX_PER, floor(tonumber(n) or L.n)))
    if n == L.n then return true end
    L.n = n
    Touch(L)
    ns:Fire("RESERVES_RULES")
    return true
end

-- Sets the guild's hard reserves (a list of item ids). A reserve on a newly held item is taken back.
function Reserves:SetHeld(list)
    local L = List()
    if not (L and AmHost() and not L.foreign) then return false end
    local h, seen = {}, {}
    for _, id in ipairs(type(list) == "table" and list or {}) do
        id = ValidItem(id)
        if id and not seen[id] and #h < MAX_HR then
            seen[id] = true
            h[#h + 1] = id
        end
    end
    tsort(h)
    L.h = h
    for key, set in pairs(L.r) do
        for id in pairs(seen) do set[id] = nil end
        if next(set) == nil then L.r[key] = nil end
    end
    Touch(L)
    ns:Fire("RESERVES_RULES")
    return true
end

function Reserves:ToggleHeld(itemID)
    local L = List()
    itemID = ValidItem(itemID)
    if not (L and itemID) then return false end
    local list, found = {}, false
    for _, id in ipairs(L.h or {}) do
        if id == itemID then found = true else list[#list + 1] = id end
    end
    if not found then list[#list + 1] = itemID end
    return self:SetHeld(list)
end

-- Why a reserve is refused (codes, also LootReserve's results): "ok", "none" (no list), "closed", "held" (a guild
-- hard reserve), "notloot" (not this raid's loot), "dupe" (already reserved), "full" (no reserves left), "notres"
-- (cancel: not reserved), "foreign" (someone else's LootReserve session), "notmember" (not in the raid).
Reserves.CODE_TEXT = {
    none = "Reserves aren't open in this raid.",
    closed = "Reserves are closed.",
    held = "is held for the guild: the loot council decides it.",
    notloot = "doesn't drop in this raid.",
    dupe = "is already one of your reserves.",
    full = "You have no reserves left.",
    notres = "isn't one of your reserves.",
    foreign = "Reserves run in LootReserve tonight.",
    notmember = "Only raid members can reserve.",
}

-- Adds key's reserve on itemID (the host). src: see SOURCES. force: the host's own change after the close, or an
-- import. Returns ok, code.
function Reserves:AddFor(key, itemID, src, force)
    local L = List()
    itemID = ValidItem(itemID)
    if not L then return false, "none" end
    if L.foreign then return false, "foreign" end
    if not AmHost() then return false, "none" end
    if not ValidKey(key) or not itemID then return false, "notloot" end
    if not (L.o or force) then return false, "closed" end
    if not force and not InGroup(key) then return false, "notmember" end
    if IsHR(L, itemID) then return false, "held" end
    local loot = self:RaidLoot(L.rk)
    if next(loot) and not loot[itemID] then return false, "notloot" end
    local set = L.r[key]
    if set and set[itemID] then return false, "dupe" end
    if CountKey(L, key) >= (L.n or 1) then return false, "full" end
    if not set then
        local n = 0
        for _ in pairs(L.r) do n = n + 1 end
        if n >= MAX_KEYS then return false, "full" end
        set = {}
        L.r[key] = set
    end
    set[itemID] = SOURCES[src] and src or "h"
    Touch(L)
    ns:Fire("RESERVE_ADDED", key, itemID, set[itemID])
    return true, "ok"
end

-- Takes key's reserve on itemID back (the host). Returns ok, code.
function Reserves:CancelFor(key, itemID, force)
    local L = List()
    itemID = ValidItem(itemID)
    if not L then return false, "none" end
    if L.foreign then return false, "foreign" end
    if not AmHost() then return false, "none" end
    if not (L.o or force) then return false, "closed" end
    local set = L.r[key]
    if not (set and itemID and set[itemID]) then return false, "notres" end
    set[itemID] = nil
    if next(set) == nil then L.r[key] = nil end
    Touch(L)
    ns:Fire("RESERVE_REMOVED", key, itemID)
    return true, "ok"
end

-- My own reserve: the host changes the list, anyone else asks the host (RVR). Returns ok, code (asked: true, "asked").
function Reserves:Reserve(itemID)
    local me = Util.PlayerKey()
    if AmHost() then return self:AddFor(me, itemID, "d") end
    local L = List()
    if not L then return false, "none" end
    if L.foreign then return false, "foreign" end
    if not L.o then return false, "closed" end
    local Comm = ns.Comm
    if Comm and Comm.Send then Comm:Send({ t = "RVR", a = "r", i = tonumber(itemID), id = L.id }, "RAID", nil, "ctrl") end
    return true, "asked"
end

function Reserves:Cancel(itemID)
    local me = Util.PlayerKey()
    if AmHost() then return self:CancelFor(me, itemID) end
    local L = List()
    if not L then return false, "none" end
    if L.foreign then return false, "foreign" end
    if not L.o then return false, "closed" end
    local Comm = ns.Comm
    if Comm and Comm.Send then Comm:Send({ t = "RVR", a = "c", i = tonumber(itemID), id = L.id }, "RAID", nil, "ctrl") end
    return true, "asked"
end

-- Replaces the list's reserves of the players named in `entries` ({ { key, itemID }, ... }, an import); returns the
-- number added and the refused entries { { key, itemID, code } }.
function Reserves:Import(entries, held)
    local L = List()
    if not (L and AmHost() and not L.foreign) then return 0, {} end
    if type(held) == "table" and #held > 0 then
        local list = {}
        for _, id in ipairs(L.h or {}) do list[#list + 1] = id end
        for _, id in ipairs(held) do list[#list + 1] = id end
        self:SetHeld(list)
    end
    local added, refused = 0, {}
    for _, e in ipairs(type(entries) == "table" and entries or {}) do
        local ok, code = self:AddFor(e[1], e[2], "s", true)
        if ok then added = added + 1 elseif code ~= "dupe" then refused[#refused + 1] = { e[1], e[2], code } end
    end
    return added, refused
end

---------------------------------------------------------------------------
-- The wire (RVS / RVQ / RVR)
---------------------------------------------------------------------------

local function Encode(L)
    local r = {}
    for key, set in pairs(L.r or {}) do
        local parts = {}
        for id, src in pairs(set) do parts[#parts + 1] = id .. ":" .. src end
        tsort(parts)
        r[key] = tconcat(parts, ",")
    end
    return { t = "RVS", id = L.id, by = L.by, v = L.v, at = L.at, rk = L.rk, n = L.n, o = L.o and 1 or 0, cl = L.cl,
             h = L.h, r = r }
end

local function Decode(msg)
    if type(msg) ~= "table" then return nil end
    if type(msg.id) ~= "string" or #msg.id > MAX_ID_LEN or not ValidKey(msg.by) then return nil end
    local v, at, n = tonumber(msg.v), tonumber(msg.at), tonumber(msg.n)
    if not (v and at and n) then return nil end
    local rk = type(msg.rk) == "string" and #msg.rk <= 40 and msg.rk or nil
    local L = { id = msg.id, by = msg.by, v = floor(v), at = floor(at), rk = rk,
                n = max(Reserves.MIN_PER, min(Reserves.MAX_PER, floor(n))), o = msg.o == 1,
                cl = tonumber(msg.cl), h = {}, r = {} }
    for _, id in ipairs(type(msg.h) == "table" and msg.h or {}) do
        id = ValidItem(id)
        if id and #L.h < MAX_HR then L.h[#L.h + 1] = id end
    end
    local keys = 0
    for key, s in pairs(type(msg.r) == "table" and msg.r or {}) do
        if ValidKey(key) and type(s) == "string" and #s <= 120 and keys < MAX_KEYS then
            local set, count = {}, 0
            for id, src in s:gmatch("(%d+):(%a)") do
                id = ValidItem(id)
                if id and SOURCES[src] and count < Reserves.MAX_PER then
                    set[id] = src
                    count = count + 1
                end
            end
            if next(set) then
                L.r[key] = set
                keys = keys + 1
            end
        end
    end
    return L
end

SendNow = function()
    if Util.DemoOn() or not cur or cur.foreign or not AmHost() or not IsInRaid() then return end
    local Comm = ns.Comm
    if Comm and Comm.Send then Comm:Send(Encode(cur), "RAID", nil, "ctrl") end
end

-- RVS: the host's list (or x = true: it was thrown away). Taken from the raid's loot authority, or from whoever holds
-- the list I have (an authority change mid-raid: the new one sends theirs).
local pendingList   -- { sender, msg, at }: a list from someone I couldn't place yet (I just joined)
local function OnList(sender, msg, dist)
    if Util.DemoOn() or dist ~= "RAID" or type(msg) ~= "table" then return end
    if Util.IsMe(sender) then return end
    local G = GR()
    local auth = G and G.GetAuthority and G:GetAuthority()
    -- (right after a /reload I may not know the authority yet, or take myself for it: the raid leader or an
    -- assistant is believed; only the authority's client sends a list)
    if not (auth == sender or (cur and cur.by == sender) or LeadOrAssist(sender)) then
        -- (a player who just joined may not know the raid's leader yet: kept a moment, taken once they do)
        pendingList = { sender = sender, msg = msg, at = GetTime() }
        return
    end
    pendingList = nil
    if msg.x then
        if cur and cur.id == msg.id then
            cur = nil
            ns:Fire("RESERVES_CLEARED", msg.id)
            Changed()
        end
        return
    end
    local L = Decode(msg)
    if not L or L.by ~= sender then return end
    if cur and cur.id == L.id and (cur.v or 0) > L.v then return end
    local was = cur
    cur = L
    if not was or was.id ~= L.id then ns:Fire("RESERVES_OPENED", cur) end
    Changed()
end

-- RVQ: somebody asks for the list (the host answers).
local function OnAsk(sender, msg, dist)
    if Util.DemoOn() or dist ~= "RAID" or Util.IsMe(sender) then return end
    if cur and not cur.foreign and AmHost() and Util.RateLimit and Util.RateLimit("rvq", 2) then SendNow() end
end

-- RVR: a raid member's own reserve / cancel (the host applies it; the RVS tells everyone).
local function OnRequest(sender, msg, dist)
    if Util.DemoOn() or dist ~= "RAID" or type(msg) ~= "table" then return end
    if not (cur and not cur.foreign and AmHost() and msg.id == cur.id) then return end
    local itemID = ValidItem(msg.i)
    if not itemID then return end
    if msg.a == "r" then
        Reserves:AddFor(sender, itemID, "d")
    elseif msg.a == "c" then
        Reserves:CancelFor(sender, itemID)
    end
end

function Reserves:Ask()
    if Util.DemoOn() or not IsInRaid() then return end
    if GetTime() - lastAskAt < 2 then return end
    lastAskAt = GetTime()
    local Comm = ns.Comm
    if Comm and Comm.Send then Comm:Send({ t = "RVQ" }, "RAID", nil, "ctrl") end
end

-- A copy of another host's LootReserve session (Core/ReserveLR.lua): replaces my list unless I host my own.
function Reserves:Mirror(host, rk, n, open, held, byKey)
    if Util.DemoOn() then return false end
    if cur and not cur.foreign then return false end   -- the raid's own DisasterZone list comes first
    local L = { id = "lr-" .. tostring(host), by = host, v = (cur and cur.v or 0) + 1, at = GetServerTime(), rk = rk, n = n or 1,
                o = open and true or false, h = held or {}, r = {}, foreign = host }
    for key, ids in pairs(byKey or {}) do
        local set = {}
        for _, id in ipairs(ids) do set[id] = "l" end
        if next(set) then L.r[key] = set end
    end
    local was = cur
    cur = L
    if not was or was.id ~= L.id then ns:Fire("RESERVES_OPENED", cur) end
    Changed()
    return true
end

-- Drops a mirrored LootReserve session (its host stopped / reset it).
function Reserves:Unmirror(host)
    if cur and cur.foreign == host then
        cur = nil
        Changed()
    end
end

---------------------------------------------------------------------------
-- Life cycle
---------------------------------------------------------------------------

-- Becoming the authority with a list someone else held: I take it over (their client is gone or lost the lead).
local function MaybeAdopt()
    if Util.DemoOn() or not cur or cur.foreign or not AmHost() then return end
    local me = Util.PlayerKey()
    if cur.by ~= me then
        cur.by = me
        Touch(cur)
    end
end

local function Restore()
    local db = ns.db
    local s = type(db) == "table" and db.reserves
    if type(s) ~= "table" or type(s.list) ~= "table" then return end
    if not IsInRaid() or GetServerTime() - (tonumber(s.savedAt) or 0) > KEEP_SAVED then
        if not IsInRaid() and GetServerTime() - (tonumber(s.savedAt) or 0) > KEEP_SAVED then db.reserves = nil end
        return
    end
    if not cur then cur = s.list end
end

local leftAt
local enteredAt = -1000   -- GetTime() of my last login / reload ...
local enteredInRaid = false   -- ... and I was in a raid then (a /reload mid-raid: I ask for the list)
local members = 0         -- the raid's size when I last looked (the host: a new member gets the list)
-- A list kept because I couldn't place its sender yet: tried again (the roster / the authority is known now).
local function RetryPending()
    local p = pendingList
    if not p then return end
    pendingList = nil
    if GetTime() - p.at < 30 and IsInRaid() then OnList(p.sender, p.msg, "RAID") end
    if pendingList == p then pendingList = nil end   -- (still unknown: dropped)
end

local function OnGroup()
    if IsInRaid() then
        leftAt = nil
        -- in a raid within 2 s of logging in / reloading: I was in it all along (a /reload mid-raid)
        if GetTime() - enteredAt < 2 then enteredInRaid = true end
        if pendingList then Util.Debounce("reserves-pending", 0.5, RetryPending) end
        -- I logged in / reloaded in a raid: I ask for the list (a new member gets it from the host without asking);
        -- again a little later, as right after a /reload the answer can come before I know who may send it
        if not cur and enteredInRaid and GetTime() - enteredAt < 60 and GetTime() - askPlannedAt > 30 then
            askPlannedAt = GetTime()
            Restore()
            for _, d in ipairs({ ASK_DELAY, ASK_DELAY + 6, ASK_DELAY + 20 }) do
                Util.After(d, function()
                    if IsInRaid() and not cur then Reserves:Ask() end
                end)
            end
        end
        local n = GetNumGroupMembers and GetNumGroupMembers() or 0
        if n > members and cur and not cur.foreign and AmHost() and not Util.DemoOn() then
            Util.Debounce("reserves-joined", 3, SendNow)
        end
        members = n
        Util.Debounce("reserves-adopt", 2, MaybeAdopt)
        return
    end
    members = 0
    if cur and not leftAt then
        leftAt = GetTime()
        Util.After(10, function()
            if leftAt and not IsInRaid() then
                cur = nil
                local db = ns.db
                if type(db) == "table" then db.reserves = nil end
                Changed()
            end
        end)
    end
end

-- The first pull closes reserves (the host).
local function OnPull()
    local L = cur
    if L and L.o and not L.foreign and AmHost() and not Util.DemoOn() then
        Reserves:Close()
        local Chat = ns.ReserveChat
        if Chat and Chat.AnnounceClosed then Chat:AnnounceClosed() end
    end
end

function Reserves:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("RVS", OnList)
        Comm:Register("RVQ", OnAsk)
        Comm:Register("RVR", OnRequest)
    end
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", OnGroup)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
        -- (only a login or a /reload: a zone change, entering the raid's instance too, asks nothing)
        if isLogin or isReload then
            enteredAt = GetTime()
            enteredInRaid = IsInRaid() and true or false
        end
        Util.After(1, OnGroup)
    end)
    ns:RegisterEvent("ENCOUNTER_START", OnPull)
    ns:On("GROUP_RULES_CHANGED", function()
        Util.Debounce("reserves-adopt", 2, MaybeAdopt)
        if pendingList then Util.Debounce("reserves-pending", 0.5, RetryPending) end
        Changed()
    end)
    ns:On("DEMO_TOGGLED", function(on)
        if not on then demoCur = nil end
        Changed()
    end)
end

---------------------------------------------------------------------------
-- Demo: a made-up pug night (memory only)
---------------------------------------------------------------------------

-- Sets the demo list (Core/ReserveDemo.lua): list = a table shaped like cur; nil drops it.
function Reserves:SetDemo(list)
    if not Util.DemoOn() then return false end
    demoCur = list
    Changed()
    return true
end

-- (tests) the real list and a reset
function Reserves:_Reset()
    cur, demoCur = nil, nil
    local db = ns.db
    if type(db) == "table" then db.reserves = nil end
    Changed()
end

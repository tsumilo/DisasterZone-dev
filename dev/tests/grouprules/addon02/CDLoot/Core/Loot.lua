-- CDLoot: Core/Loot.lua
-- Drop detection: loot-window scan, DROP broadcast/receive (deduped by source key),
-- CHAT_MSG_LOOT award parsing, group-roll hints, encounter context, /cdl test and /cdl drop,
-- and master-loot hand-out helpers for roll awards (Addendum A §19.4).
-- Dungeon mode (Addendum B §22.2): drops go out on Util.GetGroupChannel() (RAID, or PARTY in a 5-man
-- party with dungeon mode on) and the 5-man quality threshold applies inside party instances.
-- Every loot message is passed to Roll:OnItemLooted (Addendum C §23.1).
local addonName, ns = ...

local Loot = ns:NewModule("Loot")
local Util = ns.Util

local floor, min = math.floor, math.min

local MAX_ITEMS_PER_DROP = 16
local MAX_SOURCE_LEN = 96
local HISTORY_MAX = 40
local HISTORY_AGE = 86400
local ENCOUNTER_FOR_SOURCE = 300   -- recent kill used as the source of unknown corpses/chests
local ENCOUNTER_RECENT = 600       -- GetRecentBossKey window
local UNKNOWN_BUCKET = 60          -- server-time bucket of the fallback source key (no loot source GUID)
local UNKNOWN_SAME_DROP = 180      -- two UNKNOWN-* drops with the same items this close = one corpse
local LOOT_SLOT_ITEM = 1

local MAX_ML_CANDIDATES = 40
local PENDING_GIVE_TIMEOUT = 5     -- seconds to wait for OPEN_MASTER_LOOT_LIST after the fake click

local seenSources = {}     -- [sourceKey] = true: drops handled this session
local remoteSeen = {}      -- [sourceKey] = true: someone else already broadcast this source
local broadcastDone = {}   -- [sourceKey] = true: we sent (or decided to send) the D for it
local lastEncounter        -- { ref = bossRef, time = GetTime() }
local lootPatterns         -- built lazily from the client's globalstrings
local lootOpen = false     -- between LOOT_OPENED / LOOT_READY and LOOT_CLOSED
local pendingGive          -- { itemID=, key=, slot=, at=, onDone= } waiting for the master-loot list
local fakeLootButton       -- CDLootFakeLootButton (lazily created)

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function IsValidItemID(id)
    return type(id) == "number" and id == floor(id) and id >= 1 and id <= 200000
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    local id = tonumber(link:match("item:(%d+)"))
    if id and id > 0 then return id end
    return nil
end

local function Setting(key, default)
    local s = ns.db and ns.db.settings
    local v = s and s[key]
    if v == nil then return default end
    return v
end

local function IsToken(id)
    return ns.ItemDB and ns.ItemDB.IsToken and ns.ItemDB:IsToken(id) or false
end

-- Real council membership: demo mode must never unlock recording or network actions (§20).
local function AmRealCouncil()
    return ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil(true) or false
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

local function SafeBossBySourceGUID(guid)
    if not (ns.ItemDB and ns.ItemDB.GetBossBySourceGUID) or type(guid) ~= "string" then return nil end
    local ok, ref = pcall(ns.ItemDB.GetBossBySourceGUID, ns.ItemDB, guid)
    if ok and type(ref) == "table" then return ref end
    return nil
end

local function ItemText(id)
    local db = ns.ItemDB
    return (db and (db:GetLink(id) or db:GetName(id))) or ("item " .. id)
end

-- Addendum B §22: dungeon mode is active (5-man party) / and I am inside a 5-man instance.
local function DungeonActive()
    return (Util.IsDungeonModeActive and Util.IsDungeonModeActive()) and true or false
end

local function DungeonLootContext()
    return DungeonActive() and Util.InPartyInstance and Util.InPartyInstance() and true or false
end

-- RAID in a raid, PARTY in a party with dungeon mode on, else nil (nothing is broadcast).
local function GroupChannel()
    if Util.GetGroupChannel then return Util.GetGroupChannel() end
    return IsInRaid() and "RAID" or nil
end

-- Minimum quality of a tracked drop: settings.dungeon.quality inside a 5-man instance while dungeon
-- mode is active, else settings.qualityThreshold.
local function QualityThreshold()
    if DungeonLootContext() then
        local D = ns.Dungeon
        local q = D and D.GetQuality and tonumber(D:GetQuality())
        if not q then
            local dg = Setting("dungeon", nil)
            q = type(dg) == "table" and tonumber(dg.quality) or 3
        end
        return q
    end
    return tonumber(Setting("qualityThreshold", 4)) or 4
end

local QUALITY_BY_COLOR = {
    ff9d9d9d = 0, ffffffff = 1, ff1eff00 = 2, ff0070dd = 3, ffa335ee = 4, ffff8000 = 5, ffe6cc80 = 6,
}

local function QualityFromLink(link)
    local hex = type(link) == "string" and link:match("|c(%x%x%x%x%x%x%x%x)")
    return hex and QUALITY_BY_COLOR[hex:lower()] or nil
end

-- Turns a Blizzard format string into an anchored Lua pattern: %s -> (.+), %d -> (%d+),
-- positional markers (%1$s) dropped, every other magic character escaped.
local function FormatToPattern(fmt)
    if type(fmt) ~= "string" or fmt == "" then return nil end
    fmt = fmt:gsub("%%%d+%$", "%%")
    local out, i, n = {}, 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c == "%" then
            local nx = fmt:sub(i + 1, i + 1)
            if nx == "s" then
                out[#out + 1] = "(.+)"
                i = i + 2
            elseif nx == "d" then
                out[#out + 1] = "(%d+)"
                i = i + 2
            elseif nx == "%" then
                out[#out + 1] = "%%"
                i = i + 2
            else
                out[#out + 1] = "%%"
                i = i + 1
            end
        elseif c:find("^[%^%$%(%)%.%[%]%*%+%-%?]$") then
            out[#out + 1] = "%" .. c
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

-- Most specific first: self forms, then "<name> receives loot" forms.
local LOOT_FORMATS = {
    { name = "LOOT_ITEM_SELF_MULTIPLE", self = true },
    { name = "LOOT_ITEM_SELF", self = true },
    { name = "LOOT_ITEM_PUSHED_SELF_MULTIPLE", self = true },
    { name = "LOOT_ITEM_PUSHED_SELF", self = true },
    { name = "LOOT_ITEM_MULTIPLE", self = false },
    { name = "LOOT_ITEM", self = false },
}

local function BuildLootPatterns()
    lootPatterns = {}
    for _, f in ipairs(LOOT_FORMATS) do
        local pat = FormatToPattern(_G[f.name])
        if pat then lootPatterns[#lootPatterns + 1] = { pat = pat, self = f.self } end
    end
    return lootPatterns
end

-- Returns link, winnerKey for a loot chat line, or nil.
function Loot:ParseLootMessage(text)
    if type(text) ~= "string" or text == "" then return nil end
    for _, p in ipairs(lootPatterns or BuildLootPatterns()) do
        local ok, a, b = pcall(string.match, text, p.pat)
        if ok and a then
            if p.self then
                return a, Util.PlayerKey()
            elseif b then
                return b, Util.NormalizeName(a)
            end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- History / dedupe
---------------------------------------------------------------------------

function Loot:GetHistory()
    if not ns.db then return {} end
    if type(ns.db.dropHistory) ~= "table" then ns.db.dropHistory = {} end
    return ns.db.dropHistory
end

local function PruneHistory(hist)
    local cutoff = GetServerTime() - HISTORY_AGE
    local n, j = #hist, 0
    for k = 1, n do
        local d = hist[k]
        if type(d) == "table" and type(d.s) == "string" and (tonumber(d.ts) or 0) >= cutoff then
            j = j + 1
            hist[j] = d
        end
    end
    for k = n, j + 1, -1 do
        hist[k] = nil
    end
    while #hist > HISTORY_MAX do
        table.remove(hist, 1)
    end
end

function Loot:IsSeen(sourceKey)
    if seenSources[sourceKey] then return true end
    for _, d in ipairs(self:GetHistory()) do
        if type(d) == "table" and d.s == sourceKey then return true end
    end
    return false
end

local function SortedItems(list)
    local out = {}
    for k, id in ipairs(list) do out[k] = tonumber(id) or 0 end
    table.sort(out)
    return table.concat(out, ",")
end

-- A drop without a real source GUID that repeats a recent one (same items) under another fallback
-- key: a second looter of the same corpse whose key fell into the next time bucket.
local function IsRepeatedUnknown(drop)
    if drop.s:sub(1, 8) ~= "UNKNOWN-" then return false end
    local items = SortedItems(drop.i)
    local ts = tonumber(drop.ts) or GetServerTime()
    for _, d in ipairs(Loot:GetHistory()) do
        if type(d) == "table" and type(d.s) == "string" and d.s:sub(1, 8) == "UNKNOWN-" and type(d.i) == "table"
            and math.abs((tonumber(d.ts) or 0) - ts) <= UNKNOWN_SAME_DROP and SortedItems(d.i) == items then
            return true
        end
    end
    return false
end

-- Shows a drop locally (once per source key), stores it in the history and fires DROP.
function Loot:HandleDrop(drop, from)
    if type(drop) ~= "table" or type(drop.s) ~= "string" or drop.s == "" or type(drop.i) ~= "table" then
        return false
    end
    if self:IsSeen(drop.s) then return false end
    seenSources[drop.s] = true
    if IsRepeatedUnknown(drop) then return false end
    drop.b = type(drop.b) == "string" and drop.b or ""
    drop.ts = tonumber(drop.ts) or GetServerTime()
    drop.from = from or Util.PlayerKey()
    -- 5-man bosses have no encounter ids: a real dungeon boss drop is the "recent kill" instead.
    if not drop.test and drop.b ~= "" and ns.ItemDB and ns.ItemDB.GetBossRef then
        local ref = ns.ItemDB:GetBossRef(drop.b)
        if type(ref) == "table" and ref.dungeon then lastEncounter = { ref = ref, time = GetTime() } end
    end
    local hist = self:GetHistory()
    hist[#hist + 1] = drop
    PruneHistory(hist)
    ns:Fire("DROP", drop)
    return true
end

---------------------------------------------------------------------------
-- Broadcast
---------------------------------------------------------------------------

local function SendDrop(drop)
    broadcastDone[drop.s] = true
    local channel = GroupChannel()
    if ns.Comm and ns.Comm.Send and channel then
        ns.Comm:Send({ t = "D", s = drop.s, b = drop.b or "", i = drop.i, ts = drop.ts }, channel, nil, "alert")
    end
end

-- The master looter sends at once; anyone else waits a random moment and stays quiet if a
-- D for the same source arrived meanwhile. Receivers dedupe by source key, so the rare
-- double send (two timers firing together) is harmless.
local function BroadcastDrop(drop)
    if not GroupChannel() or broadcastDone[drop.s] or remoteSeen[drop.s] then return end
    if Util.IsPlayerMasterLooter() then
        SendDrop(drop)
        return
    end
    broadcastDone[drop.s] = false   -- pending
    Util.RandomDelay(0.3, 1.5, function()
        if remoteSeen[drop.s] or broadcastDone[drop.s] then return end
        SendDrop(drop)
    end)
end

local function OnDropMessage(sender, msg, distribution)
    if type(msg) ~= "table" then return end
    -- PARTY drops only count while dungeon mode is active for me (§22.2).
    if distribution == "PARTY" then
        if not DungeonActive() then return end
    elseif distribution ~= "RAID" then
        return
    end
    -- The sender is already gated on the REAL group by Comm (Util.IsInMyGroup would use the demo
    -- raid while demo mode is on and drop every real drop).
    local s = msg.s
    if type(s) ~= "string" or s == "" or #s > MAX_SOURCE_LEN then return end
    remoteSeen[s] = true   -- suppress our own pending broadcast for this source

    if type(msg.i) ~= "table" then return end
    local ids = {}
    for k = 1, MAX_ITEMS_PER_DROP do
        local id = msg.i[k]
        if id == nil then break end
        if IsValidItemID(id) then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end

    local b = msg.b
    if type(b) ~= "string" or #b > 64 or (b ~= "" and not (ns.ItemDB and ns.ItemDB:GetBossRef(b))) then
        b = ""
    end
    local now = GetServerTime()
    local ts = tonumber(msg.ts)
    if not ts or math.abs(ts - now) > 3600 then ts = now end

    Loot:HandleDrop({ s = s, b = b, i = ids, ts = ts }, sender)
end

---------------------------------------------------------------------------
-- Loot window scan
---------------------------------------------------------------------------

local function SourceForSlot(slot)
    local guid
    if GetLootSourceInfo then
        local ok, g = pcall(GetLootSourceInfo, slot)
        if ok and type(g) == "string" and g ~= "" then guid = g end
    end
    if not guid and UnitExists("target") and UnitIsDead("target") then
        guid = UnitGUID("target")
    end
    if type(guid) ~= "string" or guid == "" then
        -- Every looter of the corpse must build the same key: server time, not the per-machine GetTime().
        local boss = Loot:GetRecentBossKey() or ""
        guid = "UNKNOWN-" .. boss .. "-" .. floor(GetServerTime() / UNKNOWN_BUCKET)
    end
    return guid:sub(1, MAX_SOURCE_LEN)
end

local function BossKeyForSource(sourceKey)
    local ref = SafeBossBySourceGUID(sourceKey)
    if not ref and lastEncounter and GetTime() - lastEncounter.time <= ENCOUNTER_FOR_SOURCE then
        ref = lastEncounter.ref
    end
    return ref and ref.key or ""
end

function Loot:ScanLoot()
    local num = GetNumLootItems and GetNumLootItems() or 0
    if num <= 0 then return end
    local threshold = QualityThreshold()
    local bySource, order = {}, {}
    for slot = 1, num do
        if GetLootSlotType(slot) == LOOT_SLOT_ITEM then
            local id = ItemIDFromLink(GetLootSlotLink(slot))
            if id and IsValidItemID(id) then
                local quality = select(5, GetLootSlotInfo(slot))
                if (tonumber(quality) or -1) >= threshold or IsToken(id) then
                    local src = SourceForSlot(slot)
                    local list = bySource[src]
                    if not list then
                        list = {}
                        bySource[src] = list
                        order[#order + 1] = src
                    end
                    if #list < MAX_ITEMS_PER_DROP then list[#list + 1] = id end
                end
            end
        end
    end

    for _, src in ipairs(order) do
        if not self:IsSeen(src) then
            local drop = { s = src, b = BossKeyForSource(src), i = bySource[src], ts = GetServerTime() }
            if self:HandleDrop(drop, Util.PlayerKey()) then BroadcastDrop(drop) end
        end
    end
end

---------------------------------------------------------------------------
-- Awards from loot chat, group rolls, encounters
---------------------------------------------------------------------------

function Loot:GetRecentBossKey()
    if lastEncounter and lastEncounter.ref and GetTime() - lastEncounter.time <= ENCOUNTER_RECENT then
        return lastEncounter.ref.key
    end
    return nil
end

local function ItemQualifies(id, link)
    local db = ns.ItemDB
    if not db then return false end
    local token = IsToken(id)
    if not token then
        local q = db:GetQuality(id) or QualityFromLink(link)
        if not q or q < QualityThreshold() then return false end
    end
    local sources = db:GetSources(id)
    return token or (type(sources) == "table" and #sources > 0)
end

local function OnChatLoot(_, text)
    local link, winner = Loot:ParseLootMessage(text)
    local id = ItemIDFromLink(link)
    if not id or not winner or not IsValidItemID(id) then return end
    -- Addendum C §23.1: every client (council or not) resolves the roll of an item that was handed out.
    local Roll = ns.Roll
    if Roll and Roll.OnItemLooted then
        ns.SafeCall(Roll.OnItemLooted, Roll, id, winner)
    end
    if not AmRealCouncil() then return end
    local dungeon = not Util.InRaidInstance() and DungeonLootContext()
    if not (dungeon or Util.InRaidInstance()) then return end
    if ItemQualifies(id, link) and ns.Ledger and ns.Ledger.RecordAuto then
        ns.Ledger:RecordAuto(id, winner, Loot:GetRecentBossKey(), dungeon)
    end
end

local function OnStartLootRoll(_, rollID)
    if rollID == nil or not GetLootRollItemLink then return end
    local ok, link = pcall(GetLootRollItemLink, rollID)
    local id = ok and ItemIDFromLink(link)
    if not id then return end
    ns:Fire("DROP", {
        s = "ROLL-" .. tostring(rollID), b = Loot:GetRecentBossKey() or "", i = { id },
        ts = GetServerTime(), roll = true, from = Util.PlayerKey(),
    })
end

local function OnEncounterEnd(_, encounterID, _, _, _, success)
    if success ~= 1 and success ~= true then return end
    local ref = ns.ItemDB and ns.ItemDB.GetBossByEncounter and ns.ItemDB:GetBossByEncounter(tonumber(encounterID))
    if ref then lastEncounter = { ref = ref, time = GetTime() } end
end

---------------------------------------------------------------------------
-- /cdl test and /cdl drop
---------------------------------------------------------------------------

local DEFAULT_OPTS = {}   -- read-only: default wanter filtering

local function IsWanted(id)
    if ns.Store and ns.Store.CountWanters and (ns.Store:CountWanters(id, DEFAULT_OPTS) or 0) > 0 then return true end
    return ns.BiS and #ns.BiS:MatchItem(id) > 0 or false
end

local function Shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Inside a 5-man instance with dungeon mode active: 2-3 heroic items of a dungeon boss (the current
-- dungeon when it is known, else a random one). Returns true when a drop was simulated.
function Loot:SimulateDungeonDrop()
    local db = ns.ItemDB
    local dungeons = db and db.GetDungeons and db:GetDungeons()
    if type(dungeons) ~= "table" or #dungeons == 0 then return false end
    local instanceID = select(8, GetInstanceInfo())
    local pools, current = {}, nil
    for _, dungeon in ipairs(dungeons) do
        if type(dungeon) == "table" and type(dungeon.bosses) == "table" then
            local bosses = {}
            for _, boss in ipairs(dungeon.bosses) do
                local ref = type(boss) == "table" and not boss.isTrash and type(boss.heroicItems) == "table"
                    and #boss.heroicItems > 0 and db:GetBossRef(tostring(dungeon.key) .. ":" .. tostring(boss.key))
                if ref then bosses[#bosses + 1] = { ref = ref, boss = boss, dungeon = dungeon } end
            end
            if #bosses > 0 then
                pools[#pools + 1] = bosses
                if instanceID and dungeon.instanceID == instanceID then current = bosses end
            end
        end
    end
    if #pools == 0 then return false end
    local bosses = current or pools[math.random(#pools)]
    local pick = bosses[math.random(#bosses)]

    local wanted, rest = {}, {}
    for _, id in ipairs(pick.boss.heroicItems) do
        if IsValidItemID(id) and (IsToken(id) or db:GetEquipLoc(id)) then
            if IsWanted(id) then wanted[#wanted + 1] = id else rest[#rest + 1] = id end
        end
    end
    local count = math.random(2, 3)
    local ids = {}
    for _, id in ipairs(Shuffle(wanted)) do
        if #ids >= count then break end
        ids[#ids + 1] = id
    end
    for _, id in ipairs(Shuffle(rest)) do
        if #ids >= count then break end
        ids[#ids + 1] = id
    end
    if #ids == 0 then ids[1] = pick.boss.heroicItems[1] end

    local names = {}
    for k, id in ipairs(ids) do names[k] = ItemText(id) end
    self:HandleDrop({ s = "TEST-" .. GetTime(), b = pick.ref.key, i = ids, ts = GetServerTime(), test = true },
        Util.PlayerKey())
    ns:Print("Simulated a dungeon drop from %s (%s, Heroic): %s", pick.boss.name or "?", pick.dungeon.name or "?",
        table.concat(names, ", "))
    return true
end

function Loot:SimulateDrop()
    if DungeonLootContext() and self:SimulateDungeonDrop() then return end
    local db = ns.ItemDB
    local raids = db and db:GetRaids()
    if type(raids) ~= "table" then
        ns:Print("No raid loot data available.")
        return
    end
    local phase = ns.Guild and ns.Guild.GetViewPhase and ns.Guild:GetViewPhase() or 1
    local withWanted, all = {}, {}
    for _, raid in ipairs(raids) do
        if raid.phase == phase and type(raid.bosses) == "table" then
            for _, boss in ipairs(raid.bosses) do
                local ref = not boss.isTrash and type(boss.items) == "table" and #boss.items > 0
                    and db:GetBossRef(raid.key .. ":" .. boss.key)
                if ref then
                    local wanted = {}
                    for _, id in ipairs(boss.items) do
                        if IsWanted(id) then wanted[#wanted + 1] = id end
                    end
                    local c = { ref = ref, boss = boss, raid = raid, wanted = wanted }
                    all[#all + 1] = c
                    if #wanted > 0 then withWanted[#withWanted + 1] = c end
                end
            end
        end
    end
    local pool = #withWanted > 0 and withWanted or all
    if #pool == 0 then
        ns:Print("No boss found for phase %d.", tonumber(phase) or 0)
        return
    end
    local pick = pool[math.random(#pool)]

    local ids, used = {}, {}
    for _, id in ipairs(Shuffle(pick.wanted)) do
        if #ids >= 4 then break end
        ids[#ids + 1] = id
        used[id] = true
    end
    local rest = {}
    for _, id in ipairs(pick.boss.items) do
        if not used[id] and (IsToken(id) or db:GetEquipLoc(id)) then rest[#rest + 1] = id end
    end
    for _, id in ipairs(Shuffle(rest)) do
        if #ids >= 4 then break end
        ids[#ids + 1] = id
    end
    if #ids == 0 then ids[1] = pick.boss.items[1] end

    local names = {}
    for k, id in ipairs(ids) do
        names[k] = ItemText(id)
    end
    self:HandleDrop({ s = "TEST-" .. GetTime(), b = pick.ref.key, i = ids, ts = GetServerTime(), test = true },
        Util.PlayerKey())
    ns:Print("Simulated a drop from %s (%s): %s", pick.boss.name or "?", pick.raid.name or "?",
        table.concat(names, ", "))
end

function Loot:ManualDrop(text)
    local demo = DemoOn()
    if not (demo or AmRealCouncil() or Util.IsPlayerLeaderOrAssist()) then
        ns:Print("Only loot council members or the raid leader / assistants can announce drops.")
        return
    end
    local ids = {}
    for _, id in ipairs(Util.ItemIDsFromText(text or "") or {}) do
        if IsValidItemID(id) and #ids < MAX_ITEMS_PER_DROP then ids[#ids + 1] = id end
    end
    if #ids == 0 then
        ns:Print("Usage: /cdl drop [item link] [item link] ... (shift-click items into the command)")
        return
    end
    local now = GetServerTime()
    local s, n = "MANUAL-" .. now, 1
    while self:IsSeen(s) do
        n = n + 1
        s = "MANUAL-" .. now .. "-" .. n
    end
    local drop = { s = s, b = self:GetRecentBossKey() or "", i = ids, ts = now }
    self:HandleDrop(drop, Util.PlayerKey())
    -- Demo mode stays local (§20): nothing typed while trying the demo reaches the raid.
    if GroupChannel() and not demo then SendDrop(drop) end
end

---------------------------------------------------------------------------
-- Master-loot hand-out (§19.4)
---------------------------------------------------------------------------

local function SafeGet(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(fn, ...)
    if ok then return a, b, c, d, e end
    return nil
end

function Loot:IsLootOpen()
    local frame = LootFrame
    if frame and frame.IsShown and frame:IsShown() then return true end
    return lootOpen
end

-- Loot slot (1-based) of itemID in the open loot window, or nil. For two identical items the
-- first remaining one is returned (after it is handed out, the next call finds the other).
function Loot:FindLootSlot(itemID)
    itemID = tonumber(itemID)
    if not itemID or not self:IsLootOpen() then return nil end
    local num = tonumber(SafeGet(GetNumLootItems)) or 0
    for slot = 1, num do
        if SafeGet(GetLootSlotType, slot) == LOOT_SLOT_ITEM
            and ItemIDFromLink(SafeGet(GetLootSlotLink, slot)) == itemID then
            return slot
        end
    end
    return nil
end

-- Scans the master-loot candidates of a slot. Returns index (or nil), anyName (bool: the list
-- had at least one name, i.e. it is populated).
local function FindCandidate(slot, key)
    local anyName = false
    for i = 1, MAX_ML_CANDIDATES do
        local name = SafeGet(GetMasterLootCandidate, slot, i)
        if type(name) == "string" and name ~= "" then
            anyName = true
            if Util.NormalizeName(name) == key then return i, true end
        end
    end
    return nil, anyName
end

-- The slot can be handed out with master loot (quality at or above the loot threshold).
local function SlotIsMasterLootable(slot)
    local threshold = tonumber(SafeGet(GetLootThreshold))
    if not threshold then return true end
    local quality = tonumber((select(5, SafeGet(GetLootSlotInfo, slot))))
    return quality == nil or quality >= threshold
end

-- I am master looter, the loot window is open and the item is in it.
function Loot:CanGiveItem(itemID)
    if not Util.IsPlayerMasterLooter() then return false end
    local slot = self:FindLootSlot(itemID)
    return slot ~= nil and SlotIsMasterLootable(slot)
end

-- true / false when known; nil when the candidate list is not populated yet (it may need the
-- master-loot list to be opened first).
function Loot:IsLootCandidate(itemID, key)
    key = Util.NormalizeName(key)
    local slot = self:FindLootSlot(itemID)
    if not key or not slot then return false end
    local idx, anyName = FindCandidate(slot, key)
    if idx then return true end
    if anyName then return false end
    return nil
end

local function FinishPending(ok, reason)
    local p = pendingGive
    pendingGive = nil
    if p and type(p.onDone) == "function" then
        if ns.SafeCall then ns.SafeCall(p.onDone, ok, reason) else p.onDone(ok, reason) end
    end
end

local function HideMasterLooterFrame()
    local f = MasterLooterFrame
    if f and f.IsShown and f:IsShown() and f.Hide then pcall(f.Hide, f) end
end

local function GetFakeLootButton()
    if fakeLootButton then return fakeLootButton end
    local name = "CDLootFakeLootButton"
    local b = CreateFrame("Frame", name, UIParent)
    b:SetSize(1, 1)
    b:SetPoint("CENTER", UIParent, "CENTER", 0, 0)   -- MasterLooterFrame may anchor to it
    b:Hide()
    b.Text = b:CreateFontString(name .. "Text", "ARTWORK", "GameFontNormal")
    b.Text:Hide()
    b.IconTexture = b:CreateTexture(name .. "IconTexture", "ARTWORK")
    b.IconTexture:Hide()
    fakeLootButton = b
    return b
end

-- Opens the master-loot candidate list for a slot the way LootReserve does on this client
-- (Server.lua ~4076-4144): a fake loot button passed to LootButton_OnClick. Returns true if the
-- click could be made; the list then arrives with OPEN_MASTER_LOOT_LIST.
local function OpenMasterLootList(slot)
    if type(LootButton_OnClick) ~= "function" then return false end
    local icon, name, _, _, quality = SafeGet(GetLootSlotInfo, slot)
    local b = GetFakeLootButton()
    b.slot = slot
    b.quality = quality
    b.Text:SetText(type(name) == "string" and name or "")
    b.IconTexture:SetTexture(icon)
    local ok, err = pcall(LootButton_OnClick, b, "LeftButton")
    if not ok then
        ns:Debug("Loot: could not open the master loot list: %s", tostring(err))
    end
    return ok
end

local function OnMasterLootList()
    local p = pendingGive
    if not p then return end
    if GetTime() - p.at > PENDING_GIVE_TIMEOUT then
        FinishPending(false, "timed out waiting for the master loot list")
        return
    end
    local slot = Loot:FindLootSlot(p.itemID)
    if not slot then
        FinishPending(false, "the item is no longer in the loot window")
        return
    end
    local idx, anyName = FindCandidate(slot, p.key)
    if not idx then
        if not anyName then return end   -- list still empty: wait for UPDATE_MASTER_LOOT_LIST / timeout
        HideMasterLooterFrame()
        FinishPending(false, Util.ShortName(p.key) .. " is not eligible for this loot")
        return
    end
    local ok = pcall(GiveMasterLoot, slot, idx)
    HideMasterLooterFrame()
    FinishPending(ok, not ok and "GiveMasterLoot failed" or nil)
end

-- Hands itemID to key with master loot. Never throws. Returns:
--   true                  the item was given (GiveMasterLoot called);
--   false, reason         not possible (not ML, loot closed, not a candidate, ...);
--   nil, "pending"        the candidate list had to be opened first; onDone(ok, reason) is called
--                         when it arrives (or after a 5s timeout). onDone is only used in this case.
function Loot:GiveItem(itemID, key, onDone)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if not itemID or not key then return false, "bad item or player" end
    if type(GiveMasterLoot) ~= "function" or type(GetMasterLootCandidate) ~= "function" then
        return false, "master loot is not available"
    end
    if not Util.IsPlayerMasterLooter() then return false, "you are not the master looter" end
    local slot = self:FindLootSlot(itemID)
    if not slot then return false, "the item is not in the open loot window" end
    if not SlotIsMasterLootable(slot) then return false, "the item is below the master loot threshold" end

    local idx, anyName = FindCandidate(slot, key)
    if idx then
        local ok, err = pcall(GiveMasterLoot, slot, idx)
        if not ok then return false, "GiveMasterLoot failed: " .. tostring(err) end
        return true
    end
    if anyName then return false, Util.ShortName(key) .. " is not eligible for this loot" end

    -- Candidate data not there yet: open the master-loot list, finish on OPEN_MASTER_LOOT_LIST.
    if pendingGive and GetTime() - pendingGive.at <= PENDING_GIVE_TIMEOUT then
        return false, "another master loot hand-out is in progress, try again in a few seconds"
    end
    local mine = { itemID = itemID, key = key, slot = slot, at = GetTime(), onDone = onDone }
    pendingGive = mine
    if not OpenMasterLootList(slot) then
        if pendingGive == mine then pendingGive = nil end
        return false, "could not open the master loot list"
    end
    -- Note: if the list event fired synchronously, onDone has already been called.
    if pendingGive == mine then
        Util.After(PENDING_GIVE_TIMEOUT + 0.1, function()
            if pendingGive == mine then FinishPending(false, "timed out waiting for the master loot list") end
        end)
    end
    return nil, "pending"
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test drops (/cdl test) are session-only: keep them out of the saved history (§20 review).
local function StripTestDrops()
    local hist = Loot:GetHistory()
    local j, n = 0, #hist
    for k = 1, n do
        local d = hist[k]
        if type(d) == "table" and not d.test then
            j = j + 1
            hist[j] = d
        end
    end
    for k = n, j + 1, -1 do hist[k] = nil end
end

function Loot:OnInit()
    ns:RegisterEvent("LOOT_READY", function()
        lootOpen = true
        Loot:ScanLoot()
    end)
    ns:RegisterEvent("LOOT_OPENED", function() lootOpen = true end)
    ns:RegisterEvent("LOOT_CLOSED", function()
        lootOpen = false
        if pendingGive then FinishPending(false, "the loot window was closed") end
    end)
    ns:RegisterEvent("OPEN_MASTER_LOOT_LIST", OnMasterLootList)
    ns:RegisterEvent("UPDATE_MASTER_LOOT_LIST", OnMasterLootList)
    ns:RegisterEvent("PLAYER_LOGOUT", StripTestDrops)
    ns:RegisterEvent("CHAT_MSG_LOOT", OnChatLoot)
    ns:RegisterEvent("START_LOOT_ROLL", OnStartLootRoll)
    ns:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("D", OnDropMessage)
    end
    ns:RegisterSlash("test", function() Loot:SimulateDrop() end, "simulate a boss drop to try the alerts")
    ns:RegisterSlash("drop", function(rest) Loot:ManualDrop(rest) end,
        "<item links> - announce a drop to the raid (council / raid lead)")
end

function Loot:OnLogin()
    StripTestDrops()   -- in case the last session ended without PLAYER_LOGOUT (crash)
    PruneHistory(self:GetHistory())
end

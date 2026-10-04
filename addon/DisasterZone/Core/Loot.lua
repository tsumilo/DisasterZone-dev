if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Loot.lua", ...) then return end -- DisasterZone: Core/Loot.lua
-- Drop detection: loot-window scan, DROP broadcast/receive (deduped by source key),
-- CHAT_MSG_LOOT award parsing, group-roll hints, encounter context, /dz test and /dz drop,
-- and master-loot hand-out helpers for roll awards (Addendum A §19.4).
-- Bag loot (1.2): under Free for All in a raid that runs loot distribution, a boss item someone picks up is held
-- for the council, not awarded; the holder trades it to the winner (the trade window is filled for them).
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
local GIVE_CONFIRM_TIMEOUT = 5     -- seconds to wait for the server to hand a master-loot item over
local AUTO_BOSS_AGE = 1800         -- an auto ledger entry takes the boss of a drop seen this recently holding the item
local ITEM_CLASS_GEM, ITEM_CLASS_TRADEGOODS = 3, 7
local HELD_AGE = 2 * 3600          -- a held item is tradable for 2 hours
local HELD_MAX = 60
local MAX_TRADE_SLOTS = 6          -- tradable slots of the trade window (the 7th is "will not be traded")
local TRADE_PUT_DELAY = 0.1        -- between two items put into the trade window

local seenSources = {}     -- [sourceKey] = true: drops handled this session
local remoteSeen = {}      -- [sourceKey] = true: someone else already broadcast this source
local broadcastDone = {}   -- [sourceKey] = true: we sent (or decided to send) the D for it
local lastEncounter        -- { ref = bossRef, time = GetTime(), ffa = pulled under Free for All }
local pullFFA = false      -- the running / last encounter started under Free for All
local lootPatterns         -- built lazily from the client's globalstrings
local lootOpen = false     -- between LOOT_OPENED / LOOT_READY and LOOT_CLOSED
local pendingGive          -- { itemID=, key=, slot=, at=, onDone= } waiting for the master-loot list
local giveWatches = {}     -- { {slot=, itemID=, key=, at=, onDone=} }: GiveMasterLoot sent, the server's answer pending
local fakeLootButton       -- DisasterZoneFakeLootButton (lazily created)

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

-- Group-rule settings (Addendum D §26): the loot authority's value while group rules are active.
local function Effective(path, default)
    local DB = ns.DB
    local v
    if DB and DB.GetEffective then v = DB:GetEffective(path) end
    if v == nil then v = Setting(path, nil) end
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

-- Minimum quality of a tracked drop: the effective dungeon.quality inside a 5-man instance while dungeon
-- mode is active, else the effective qualityThreshold (the group's rules while they are active).
local function QualityThreshold()
    if DungeonLootContext() then
        local D = ns.Dungeon
        local q = D and D.GetQuality and tonumber(D:GetQuality())
        if not q then q = tonumber(Effective("dungeon.quality", 3)) or 3 end
        return q
    end
    return tonumber(Effective("qualityThreshold", 4)) or 4
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
    { name = "LOOT_ITEM_PUSHED_SELF_MULTIPLE", self = true, pushed = true },
    { name = "LOOT_ITEM_PUSHED_SELF", self = true, pushed = true },
    { name = "LOOT_ITEM_MULTIPLE", self = false },
    { name = "LOOT_ITEM", self = false },
}

local function BuildLootPatterns()
    lootPatterns = {}
    for _, f in ipairs(LOOT_FORMATS) do
        local pat = FormatToPattern(_G[f.name])
        if pat then lootPatterns[#lootPatterns + 1] = { pat = pat, self = f.self, pushed = f.pushed or false } end
    end
    return lootPatterns
end

-- Returns link, winnerKey, pushed for a loot chat line, or nil. pushed: "You receive item" (a trade, a quest, a
-- craft), not something picked up from a corpse.
function Loot:ParseLootMessage(text)
    if type(text) ~= "string" or text == "" then return nil end
    for _, p in ipairs(lootPatterns or BuildLootPatterns()) do
        local ok, a, b = pcall(string.match, text, p.pat)
        if ok and a then
            if p.self then
                return a, Util.PlayerKey(), p.pushed
            elseif b then
                return b, Util.NormalizeName(a), false
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

-- The group as it was when a drop was seen (local only, never sent): awards recorded by or for these players
-- are this drop's awards (Ledger:AwardsForDrop), not another raid group's award of the same item.
local function GroupSnapshot()
    local set = {}
    local me = Util.PlayerKey()
    if me then set[me] = true end
    for key in pairs(type(Util.group) == "table" and Util.group or {}) do
        if type(key) == "string" then set[key] = true end
    end
    return set
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
    if not drop.test and not drop.roll then drop.grp = GroupSnapshot() end
    -- 5-man bosses have no encounter ids: a real dungeon boss drop is the "recent kill" instead (a dungeon's
    -- trash pseudo-boss never is).
    if not drop.test and drop.b ~= "" and ns.ItemDB and ns.ItemDB.GetBossRef then
        local ref = ns.ItemDB:GetBossRef(drop.b)
        if type(ref) == "table" and ref.dungeon and not (ref.boss and ref.boss.isTrash) then
            lastEncounter = { ref = ref, time = GetTime() }
        end
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

-- The master looter sends at once (even when someone else's D for the source arrived first: receivers dedupe
-- by source key); anyone else waits a random moment and stays quiet if a D for the same source arrived
-- meanwhile. The rare double send (two timers firing together) is harmless.
local TrustedDropSender   -- forward declaration (receive section)

local function BroadcastDrop(drop)
    local channel = GroupChannel()
    if not channel or broadcastDone[drop.s] then return end
    -- (the raid would ignore my D: under master loot only the master looter and the council announce drops)
    if not TrustedDropSender(Util.PlayerKey(), channel) then return end
    if Util.IsPlayerMasterLooter() then
        SendDrop(drop)
        return
    end
    if remoteSeen[drop.s] then return end
    broadcastDone[drop.s] = false   -- pending
    Util.RandomDelay(0.3, 1.5, function()
        if remoteSeen[drop.s] or broadcastDone[drop.s] then return end
        SendDrop(drop)
    end)
end

-- Loot of an item container (disenchant, prospecting, lockbox, bag): never a boss drop.
local function IsItemSource(s)
    return type(s) == "string" and s:sub(1, 5) == "Item-"
end

-- While master loot is on in a raid, only the loot authority side announces drops: the master looter or a council
-- member (the raid leader of my guild counts; 1.3: raid assistants have no loot rights). (Anyone else could pre-claim
-- a boss corpse's source key with junk and every client, the ML's own included, would ignore the real loot window.)
-- PARTY / other loot methods: any real group member, as before. (BroadcastDrop checks me the same way.)
TrustedDropSender = function(sender, distribution)
    if distribution ~= "RAID" then return true end
    local method = C_PartyInfo and C_PartyInfo.GetLootMethod and C_PartyInfo.GetLootMethod()
    local ml = (Enum and Enum.LootMethod and Enum.LootMethod.Masterlooter) or 2
    if method ~= ml then return true end
    local _, isML = Util.GetGroupRole(sender)
    if isML then return true end
    return ns.Guild and ns.Guild.IsCouncil and ns.Guild:IsCouncil(sender, true) and true or false
end

-- In a raid, the loot council (BiS candidates, votes, bag loot) only runs while the raid leader's raid session has
-- it on (GroupRules, 1.2).
local function RaidLootOff(incoming)
    local GR = ns.GroupRules
    return IsInRaid() and GR ~= nil and GR.IsFeatureOn ~= nil and not GR:IsFeatureOn("loot", incoming)
end

-- 1.3: drops (the loot window scan, D, the drop panel) run while the session runs the loot council or rolls; with
-- rolls only, the drop panel is a plain roll panel (no BiS, no votes). Handed-out loot is recorded either way.
local function RaidDropsOff(incoming)
    local GR = ns.GroupRules
    if not (IsInRaid() and GR and GR.IsFeatureOn) then return false end
    return not GR:IsFeatureOn("loot", incoming) and not GR:IsFeatureOn("rolls", incoming)
end

local function OnDropMessage(sender, msg, distribution)
    if type(msg) ~= "table" then return end
    -- PARTY drops only count while dungeon mode is active for me (§22.2).
    if distribution == "PARTY" then
        if not DungeonActive() then return end
    elseif distribution ~= "RAID" then
        return
    elseif RaidDropsOff(true) then
        return
    end
    -- The sender is already gated on the REAL group by Comm (Util.IsInMyGroup would use the demo
    -- raid while demo mode is on and drop every real drop).
    local s = msg.s
    if type(s) ~= "string" or s == "" or #s > MAX_SOURCE_LEN then return end
    -- A disenchant / container loot window a DisasterZone 0.4 client still broadcasts.
    if IsItemSource(s) then return end
    if type(msg.i) ~= "table" then return end
    local ids = {}
    for k = 1, MAX_ITEMS_PER_DROP do
        local id = msg.i[k]
        if id == nil then break end
        if IsValidItemID(id) then ids[#ids + 1] = id end
    end
    if #ids == 0 then return end
    if not TrustedDropSender(sender, distribution) then
        ns:Debug("Loot: D from %s ignored (not the master looter, a lead or council)", tostring(sender))
        return
    end
    remoteSeen[s] = true   -- suppress our own pending broadcast for this source (a valid, trusted D only)

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

-- One of `items` is on that boss's loot list.
local function OnBossList(ref, items)
    local boss = type(ref) == "table" and ref.boss
    if type(boss) ~= "table" or type(items) ~= "table" then return false end
    for _, list in ipairs({ boss.items or {}, boss.heroicItems or {} }) do
        for _, bid in ipairs(list) do
            for _, id in ipairs(items) do
                if bid == id then return true end
            end
        end
    end
    return false
end

-- The boss a loot source belongs to. A mapped boss corpse / chest: that boss. A creature that is no mapped boss:
-- the kill of the last 5 min only when one of the items is on that boss's loot list (a boss NPC DisasterZone does not
-- know), else the current instance's trash pseudo-boss when it lists one of the items, else no boss - trash loot is
-- never filed under the last boss killed. Other sources (chests without an object mapping, the UNKNOWN-* fallback):
-- the kill of the last 5 min.
local function BossKeyForSource(sourceKey, items)
    local ref = SafeBossBySourceGUID(sourceKey)
    if not ref then
        local recent = lastEncounter and GetTime() - lastEncounter.time <= ENCOUNTER_FOR_SOURCE and lastEncounter.ref or nil
        local kind = type(sourceKey) == "string" and sourceKey:match("^(%a+)%-") or nil
        if kind == "Creature" or kind == "Vehicle" then
            if recent and OnBossList(recent, items) then return recent.key or "" end
            local db = ns.ItemDB
            local instanceID = select(8, GetInstanceInfo())
            if db and db.GetTrashRefForInstance and instanceID then
                local ok, r = pcall(db.GetTrashRefForInstance, db, instanceID, items)
                if ok and type(r) == "table" then ref = r end
            end
            return ref and ref.key or ""
        end
        ref = recent
    end
    return ref and ref.key or ""
end

-- Raw loot-source GUID of a slot, or nil.
local function RawSource(slot)
    if not GetLootSourceInfo then return nil end
    local ok, g = pcall(GetLootSourceInfo, slot)
    if ok and type(g) == "string" and g ~= "" then return g end
    return nil
end

-- A trade good / gem that no boss drops (Void Crystal, Large Prismatic Shard from disenchanting, ...): never
-- tracked, also when the loot source is unknown. Boss trade goods (Nether Vortex) have drop sources.
local function IsNonBossMaterial(id)
    local db = ns.ItemDB
    if not db or IsToken(id) or not db.GetItemClassID then return false end
    local cls = db:GetItemClassID(id)
    if cls ~= ITEM_CLASS_TRADEGOODS and cls ~= ITEM_CLASS_GEM then return false end
    local sources = db.GetSources and db:GetSources(id, "drops")
    return not (type(sources) == "table" and #sources > 0)
end

local function FishingLoot()
    if not IsFishingLoot then return false end
    local ok, fishing = pcall(IsFishingLoot)
    return ok and fishing and true or false
end

function Loot:ScanLoot()
    local num = GetNumLootItems and GetNumLootItems() or 0
    if num <= 0 then return end
    if FishingLoot() or RaidDropsOff() then return end
    local threshold = QualityThreshold()
    local bySource, order = {}, {}
    for slot = 1, num do
        -- Loot of an item (disenchant, prospecting, lockbox, bag) is never a boss drop.
        if GetLootSlotType(slot) == LOOT_SLOT_ITEM and not IsItemSource(RawSource(slot)) then
            local id = ItemIDFromLink(GetLootSlotLink(slot))
            if id and IsValidItemID(id) and not IsNonBossMaterial(id) then
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
            local drop = { s = src, b = BossKeyForSource(src, bySource[src]), i = bySource[src], ts = GetServerTime() }
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
    -- "drops": raid + 5-man boss sources only (Addendum F: GetSources' default now also lists crafted /
    -- reputation / badge / PvP sources, which are never boss loot)
    local sources = db:GetSources(id, "drops")
    return token or (type(sources) == "table" and #sources > 0)
end

-- The boss an auto ledger entry of itemID belongs to: the newest drop of the last 30 min that held the item (so a
-- token handed out after the next boss died, or 10+ min later, keeps its boss); else the recent kill when the item
-- is on that boss's loot list; else none.
local function AutoBossKey(itemID)
    local cutoff = GetServerTime() - AUTO_BOSS_AGE
    local hist = Loot:GetHistory()
    for k = #hist, 1, -1 do
        local d = hist[k]
        if type(d) == "table" and not d.test and not d.roll and type(d.i) == "table" and (tonumber(d.ts) or 0) >= cutoff then
            for _, id in ipairs(d.i) do
                if tonumber(id) == itemID then return type(d.b) == "string" and d.b or "" end
            end
        end
    end
    local key = Loot:GetRecentBossKey()
    local ref = key and ns.ItemDB and ns.ItemDB.GetBossRef and ns.ItemDB:GetBossRef(key)
    if type(ref) == "table" and type(ref.boss) == "table" then
        for _, list in ipairs({ ref.boss.items or {}, ref.boss.heroicItems or {} }) do
            for _, id in ipairs(list) do
                if id == itemID then return key end
            end
        end
        -- a token / piece of this boss
        local db = ns.ItemDB
        for _, id in ipairs(db and db.ExpandDrop and db:ExpandDrop(itemID) or {}) do
            for _, bid in ipairs(ref.boss.items or {}) do
                if bid == id then return key end
            end
        end
    end
    return ""
end

local NoteHandedOut   -- forward declaration (master-loot hand-out section)

---------------------------------------------------------------------------
-- Bag loot: Free for All (1.2)
---------------------------------------------------------------------------
-- Some fights need Free for All (Lady Vashj's Tainted Cores, Kael'thas' weapons), and the loot method of a fight
-- is the one set at the pull. In a raid that runs loot distribution, a boss item picked up under Free for All is
-- therefore no award: the looter holds it in their bags, the council awards it as usual (rolls, votes, Award)
-- and the holder trades it to the winner. Nothing here is sent: every client reads the same loot line.

local function FreeForAll()
    local method = C_PartyInfo and C_PartyInfo.GetLootMethod and C_PartyInfo.GetLootMethod()
    return method ~= nil and method == ((Enum and Enum.LootMethod and Enum.LootMethod.Freeforall) or 0)
end

local function BagLootMethodOn()
    return (IsInRaid() and not RaidLootOff() and FreeForAll()) and true or false
end

-- Boss loot goes to bags first: a raid with loot distribution on, and Free for All now or at the pull of the
-- boss killed last (the method may have been switched back since; the corpse keeps the one of the pull).
function Loot:IsBagLoot()
    if not IsInRaid() or RaidLootOff() then return false end
    if FreeForAll() then return true end
    return (lastEncounter and lastEncounter.ffa and GetTime() - lastEncounter.time <= ENCOUNTER_RECENT) and true or false
end

-- { {i = itemID, k = holder, ts = server time} }, oldest first; saved, so a /reload of the holder keeps it.
local function HeldList()
    if not ns.db then return {} end
    if type(ns.db.heldLoot) ~= "table" then ns.db.heldLoot = {} end
    return ns.db.heldLoot
end

local function PruneHeld(list)
    local cutoff = GetServerTime() - HELD_AGE
    local n, j = #list, 0
    for k = 1, n do
        local h = list[k]
        if type(h) == "table" and type(h.k) == "string" and IsValidItemID(h.i) and (tonumber(h.ts) or 0) >= cutoff then
            j = j + 1
            list[j] = h
        end
    end
    for k = n, j + 1, -1 do list[k] = nil end
    while #list > HELD_MAX do table.remove(list, 1) end
end

-- The player holding a copy of itemID for the council (the newest pick-up of the last 2 hours), or nil.
function Loot:GetHolder(itemID)
    itemID = tonumber(itemID)
    local cutoff = GetServerTime() - HELD_AGE
    local list = HeldList()
    for k = #list, 1, -1 do
        local h = list[k]
        if type(h) == "table" and h.i == itemID and (tonumber(h.ts) or 0) >= cutoff then return h.k end
    end
    return nil
end

function Loot:IsHeldBy(itemID, key)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if not itemID or not key then return false end
    local cutoff = GetServerTime() - HELD_AGE
    for _, h in ipairs(HeldList()) do
        if type(h) == "table" and h.i == itemID and h.k == key and (tonumber(h.ts) or 0) >= cutoff then return true end
    end
    return false
end

-- One held copy left its holder (traded to the winner).
local function DropHeld(itemID, key)
    local list = HeldList()
    for k = 1, #list do
        local h = list[k]
        if type(h) == "table" and h.i == itemID and h.k == key then
            table.remove(list, k)
            ns:Fire("LOOT_HELD", itemID, nil)
            return
        end
    end
end

-- 1.3: the holder told the raid they traded a copy to its winner (Roll, their RW with g): it is not held any more,
-- so a later award of the same item to them is not taken as handed out.
function Loot:ReleaseHeld(itemID, key)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if itemID and key then DropHeld(itemID, key) end
end

local function NoteHeld(itemID, key)
    local list = HeldList()
    list[#list + 1] = { i = itemID, k = key, ts = GetServerTime() }
    PruneHeld(list)
    if key == Util.PlayerKey() then
        ns:Print("You hold %s for the loot council. Once it is awarded, open a trade with the winner: DisasterZone "
            .. "puts it in the trade window.", ItemText(itemID))
    elseif AmRealCouncil() or Util.IsPlayerMasterLooter() then
        ns:Print("%s picked up %s (Free for All): held for the council, not logged as an award. Award it as usual; "
            .. "%s trades it to the winner.", Util.ShortName(key), ItemText(itemID), Util.ShortName(key))
    end
    ns:Fire("LOOT_HELD", itemID, key)
end

-- A boss item picked up while bag loot applies. Returns true when the loot line was handled here (it is then
-- neither a roll's hand-out nor an automatic log entry).
local function OnBagLoot(id, link, winner)
    if not Loot:IsBagLoot() or not Util.InRaidInstance() or not ItemQualifies(id, link) then return false end
    -- Already awarded to the looter (awarded before anyone picked it up): this is its hand-out.
    local Roll = ns.Roll
    if Roll and Roll.MarkGiven and Roll:MarkGiven(id, winner) then return true end
    NoteHeld(id, winner)
    return true
end

-- An award of an item I hold: tell me whom to trade it to (once per award).
local toldTrade = {}
local function OnRollUpdatedForHeld(id)
    local Roll = ns.Roll
    local ses = Roll and Roll.Get and Roll:Get(id)
    local me = Util.PlayerKey()
    if type(ses) ~= "table" or ses.demo or ses.state ~= "awarded" or ses.given or ses.via == "loot" then return end
    if not me or ses.winner == me or type(ses.winner) ~= "string" or toldTrade[id] == ses.winner then return end
    if not Loot:IsHeldBy(ses.i, me) then return end
    toldTrade[id] = ses.winner
    ns:Print("%s was awarded to %s. It is in your bags: open a trade with %s and DisasterZone puts it in.",
        ItemText(ses.i), Util.ShortName(ses.winner), Util.ShortName(ses.winner))
end

-- Trade window: what I hold for my trade partner goes in; a completed trade hands the awards out.

local tradeOpen = false
local tradeWith    -- the player I am (or was last) trading with
local tradeGave    -- item ids in my trade slots when both sides had accepted

local function BagAPI(name)
    local C = C_Container
    return (C and C[name]) or _G[name]
end

-- bag, slot of a copy of itemID in my bags that `taken` does not list yet.
local function FindBagItem(itemID, taken)
    local numSlots, getID = BagAPI("GetContainerNumSlots"), BagAPI("GetContainerItemID")
    if not (numSlots and getID) then return nil end
    for bag = 0, 4 do
        for slot = 1, tonumber((numSlots(bag))) or 0 do
            local tag = bag * 1000 + slot
            if not taken[tag] and getID(bag, slot) == itemID then
                taken[tag] = true
                return bag, slot
            end
        end
    end
    return nil
end

local function FreeTradeSlot()
    if type(GetTradePlayerItemInfo) ~= "function" then return nil end
    for n = 1, MAX_TRADE_SLOTS do
        if not GetTradePlayerItemInfo(n) then return n end
    end
    return nil
end

local function PutInTrade(bag, slot, partner)
    if not tradeOpen or tradeWith ~= partner then return end   -- the trade closed meanwhile
    local pickup = BagAPI("PickupContainerItem")
    local n = FreeTradeSlot()
    if not (pickup and n and type(ClickTradeButton) == "function") then return end
    if ClearCursor then ClearCursor() end
    if pcall(pickup, bag, slot) then pcall(ClickTradeButton, n) end
    if CursorHasItem and CursorHasItem() and ClearCursor then ClearCursor() end
end

local function OnTradeShow()
    tradeOpen = true
    tradeWith = Util.UnitKey("NPC")
    tradeGave = nil
    local Roll = ns.Roll
    local me = Util.PlayerKey()
    if not (tradeWith and me and Roll and Roll.GetOwed) then return end
    local partner = tradeWith
    local taken, count = {}, 0
    for _, itemID in ipairs(Roll:GetOwed(partner)) do
        if count >= MAX_TRADE_SLOTS then break end
        if Loot:IsHeldBy(itemID, me) then
            local bag, slot = FindBagItem(itemID, taken)
            if bag then
                Util.After(TRADE_PUT_DELAY * count, function() PutInTrade(bag, slot, partner) end)
                count = count + 1
            end
        end
    end
    if count > 0 then
        ns:Print("Trade with %s: putting in %d awarded item%s. Check them, then accept.", Util.ShortName(partner),
            count, count == 1 and "" or "s")
    end
end

-- TRADE_ACCEPT_UPDATE: what I give is final once both sides accepted.
local function OnTradeAccept(_, mine, theirs)
    if not (tonumber(mine) == 1 and tonumber(theirs) == 1) or type(GetTradePlayerItemLink) ~= "function" then
        tradeGave = nil
        return
    end
    tradeGave = {}
    for n = 1, MAX_TRADE_SLOTS do
        local id = ItemIDFromLink(GetTradePlayerItemLink(n))
        if id then tradeGave[#tradeGave + 1] = id end
    end
end

-- UI_INFO_MESSAGE "Trade complete": the awards of the items I gave are handed out.
local function OnTradeInfo(_, a, b)
    local done = ERR_TRADE_COMPLETE
    if type(done) ~= "string" or (a ~= done and b ~= done) then return end
    local gave, partner = tradeGave, tradeWith
    tradeGave = nil
    local me = Util.PlayerKey()
    if not (gave and partner and me) then return end
    local Roll = ns.Roll
    for _, itemID in ipairs(gave) do
        if Roll and Roll.MarkGiven then Roll:MarkGiven(itemID, partner, true) end
        DropHeld(itemID, me)
    end
end

local wasBagLoot = false
local function OnLootMethodChanged()
    local on = BagLootMethodOn()
    if on and not wasBagLoot and AmRealCouncil() then
        ns:Print("Free for All loot: boss items go to the looter's bags and are not logged as awards. Award them "
            .. "as usual; the holder trades each one to its winner.")
    end
    wasBagLoot = on
end

local function OnChatLoot(_, text)
    local link, winner, pushed = Loot:ParseLootMessage(text)
    local id = ItemIDFromLink(link)
    if not id or not winner or not IsValidItemID(id) then return end
    if not pushed and OnBagLoot(id, link, winner) then return end
    -- Addendum C §23.1: every client (council or not) resolves the roll of an item that was handed out.
    local Roll = ns.Roll
    if Roll and Roll.OnItemLooted then
        ns.SafeCall(Roll.OnItemLooted, Roll, id, winner)
    end
    NoteHandedOut(id, winner)   -- my own master-loot hand-out arrived
    -- 1.3: recorded also while the raid runs without the loot council (or before Start raid): only the council's
    -- distribution is switched off, the loot log still says who got what.
    if not AmRealCouncil() then return end
    local dungeon = not Util.InRaidInstance() and DungeonLootContext()
    if not (dungeon or Util.InRaidInstance()) then return end
    if ItemQualifies(id, link) and ns.Ledger and ns.Ledger.RecordAuto then
        ns.Ledger:RecordAuto(id, winner, AutoBossKey(id), dungeon)
    end
end

local function OnStartLootRoll(_, rollID)
    if rollID == nil or not GetLootRollItemLink then return end
    local ok, link = pcall(GetLootRollItemLink, rollID)
    local id = ok and ItemIDFromLink(link)
    if not id or RaidDropsOff() then return end
    ns:Fire("DROP", {
        s = "ROLL-" .. tostring(rollID), b = Loot:GetRecentBossKey() or "", i = { id },
        ts = GetServerTime(), roll = true, from = Util.PlayerKey(),
    })
end

local function OnEncounterEnd(_, encounterID, _, _, _, success)
    if success ~= 1 and success ~= true then return end
    local ref = ns.ItemDB and ns.ItemDB.GetBossByEncounter and ns.ItemDB:GetBossByEncounter(tonumber(encounterID))
    if ref then lastEncounter = { ref = ref, time = GetTime(), ffa = pullFFA } end
end

---------------------------------------------------------------------------
-- /dz test and /dz drop
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

-- /dz drop: the loot council or the master looter (1.3: in a raid no assistants; the raid leader of my guild is
-- council), in a 5-man party also the party leader.
function Loot:ManualDrop(text)
    local demo = DemoOn()
    local partyLead = not IsInRaid() and Util.IsPlayerLeaderOrAssist()
    if not (demo or AmRealCouncil() or Util.IsPlayerMasterLooter() or partyLead) then
        ns:Print("Only the loot council (the raid leader counts) or the master looter can announce drops.")
        return
    end
    if not demo and RaidDropsOff() then
        ns:Print("The loot council and rolls are off for this raid. The raid leader turns them on with Start raid "
            .. "(or the session bar's Options).")
        return
    end
    local ids = {}
    for _, id in ipairs(Util.ItemIDsFromText(text or "") or {}) do
        if IsValidItemID(id) and #ids < MAX_ITEMS_PER_DROP then ids[#ids + 1] = id end
    end
    if #ids == 0 then
        ns:Print("Usage: /dz drop [item link] [item link] ... (shift-click items into the command)")
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

local function SlotInFlight(slot)
    for _, w in ipairs(giveWatches) do
        if w.slot == slot then return true end
    end
    return false
end

-- Loot slot (1-based) of itemID in the open loot window, or nil. For two identical items the
-- first remaining one is returned (after it is handed out, the next call finds the other); a slot whose
-- hand-out is still on its way to the server is skipped.
function Loot:FindLootSlot(itemID)
    itemID = tonumber(itemID)
    if not itemID or not self:IsLootOpen() then return nil end
    local num = tonumber(SafeGet(GetNumLootItems)) or 0
    for slot = 1, num do
        if SafeGet(GetLootSlotType, slot) == LOOT_SLOT_ITEM and not SlotInFlight(slot)
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

-- GiveMasterLoot only sends a request: the server hands the item over (the slot clears, everyone gets the loot
-- message) or refuses (bags full, unique item, out of range: a UI error, the item stays). A give counts only once
-- the server confirmed it; onDone(ok, reason) is called exactly once.
local function FinishWatch(w, ok, reason)
    for i = #giveWatches, 1, -1 do
        if giveWatches[i] == w then table.remove(giveWatches, i) end
    end
    if type(w.onDone) == "function" then
        if ns.SafeCall then ns.SafeCall(w.onDone, ok, reason) else w.onDone(ok, reason) end
    end
end

-- Sends GiveMasterLoot and waits. Returns nil, "pending" (onDone follows), or false, reason (not sent).
local function StartGive(slot, idx, itemID, key, onDone)
    local w = { slot = slot, itemID = itemID, key = key, at = GetTime(), onDone = onDone }
    giveWatches[#giveWatches + 1] = w   -- before the call: a fast answer may come back inside it
    local ok, err = pcall(GiveMasterLoot, slot, idx)
    if not ok then
        for i = #giveWatches, 1, -1 do
            if giveWatches[i] == w then table.remove(giveWatches, i) end
        end
        return false, "GiveMasterLoot failed: " .. tostring(err)
    end
    Util.After(GIVE_CONFIRM_TIMEOUT, function()
        for _, x in ipairs(giveWatches) do
            if x == w then
                FinishWatch(w, false, "no confirmation from the server")
                return
            end
        end
    end)
    return nil, "pending"
end

-- LOOT_SLOT_CLEARED: the slot of a hand-out emptied.
local function OnLootSlotCleared(_, slot)
    slot = tonumber(slot)
    for _, w in ipairs(giveWatches) do
        if w.slot == slot then
            FinishWatch(w, true)
            return
        end
    end
end

-- The loot message of a hand-out (the window may have closed before the slot-cleared event).
NoteHandedOut = function(itemID, key)
    for _, w in ipairs(giveWatches) do
        if w.itemID == itemID and w.key == key then
            FinishWatch(w, true)
            return
        end
    end
end

-- The master-loot refusals of this client (GlobalStrings); nil-guarded.
local function IsMasterLootError(text)
    if type(text) ~= "string" or text == "" then return false end
    for _, name in ipairs({ "ERR_LOOT_MASTER_INV_FULL", "ERR_LOOT_MASTER_UNIQUE_ITEM", "ERR_LOOT_MASTER_OTHER",
                            "ERR_LOOT_PLAYER_NOT_FOUND" }) do
        local g = _G[name]
        if type(g) == "string" and g ~= "" and g == text then return true end
    end
    return false
end

-- UI_ERROR_MESSAGE (messageType, message): a refused hand-out fails the oldest one in flight.
local function OnUIError(_, a, b)
    if #giveWatches == 0 then return end
    local text = IsMasterLootError(b) and b or (IsMasterLootError(a) and a) or nil
    if not text then return end
    FinishWatch(giveWatches[1], false, text)
end

-- DisasterZone 0.5: a master-loot hand-out of itemID is waiting for the server.
function Loot:IsGiveInFlight(itemID)
    for _, w in ipairs(giveWatches) do
        if w.itemID == tonumber(itemID) then return true end
    end
    return false
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
    local name = "DisasterZoneFakeLootButton"
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
    pendingGive = nil
    local ok, why = StartGive(slot, idx, p.itemID, p.key, p.onDone)
    HideMasterLooterFrame()
    if ok == false and type(p.onDone) == "function" then
        if ns.SafeCall then ns.SafeCall(p.onDone, false, why) else p.onDone(false, why) end
    end
end

-- Hands itemID to key with master loot. Never throws. Returns:
--   false, reason         not possible (not ML, loot closed, not a candidate, ...); onDone is not called;
--   nil, "pending"        GiveMasterLoot was sent (after opening the candidate list when needed): onDone(ok, reason)
--                         follows once the server handed the item over (the slot cleared / the loot message) or
--                         refused it (bags full, unique, out of range, no answer within 5 s).
-- (DisasterZone 0.4 returned true right after GiveMasterLoot, so a refused hand-out was recorded as given.)
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
    if idx then return StartGive(slot, idx, itemID, key, onDone) end
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
-- Disenchant / guild bank hand-outs by a master looter outside the council (1.3)
---------------------------------------------------------------------------
-- With the loot council off the master looter hands the loot out, but only the council writes the loot log: an item
-- the master looter gives to the disenchanter / guild bank character (drop panel DE / Bank) would be logged from its
-- loot line as a normal award, loot won. So the master looter tells the group (LT { i, w, r = "de" | "bank", b, at })
-- and every council client records the hand-out with that reason (Ledger:RecordTargetAward, one id everywhere).
-- Receivers take it only from the master looter and only for the disenchanter / guild bank character they know.

local MAX_TARGET_BOSS_LEN = 64
local LT_AT_SLACK = 120   -- an LT time further than this from my server time is not believed

-- Sends LT for a hand-out of itemID to key, the "de" / "bank" target. Returns true when sent (I am the master
-- looter, not council, outside demo mode).
function Loot:AnnounceTargetHandout(itemID, key, kind, bossKey)
    itemID = tonumber(itemID)
    key = Util.NormalizeName(key)
    if DemoOn() or AmRealCouncil() or not Util.IsPlayerMasterLooter() then return false end
    if (kind ~= "de" and kind ~= "bank") or not IsValidItemID(itemID) or not key then return false end
    local channel = GroupChannel()
    if not (channel and ns.Comm and ns.Comm.Send) then return false end
    local b = (type(bossKey) == "string" and #bossKey <= MAX_TARGET_BOSS_LEN) and bossKey or ""
    return ns.Comm:Send({ t = "LT", i = itemID, w = key, r = kind, b = b, at = GetServerTime() }, channel, nil, "alert")
        and true or false
end

local function OnTargetHandout(sender, msg, distribution)
    if DemoOn() or type(msg) ~= "table" then return end
    if distribution == "PARTY" then
        if not DungeonActive() then return end
    elseif distribution ~= "RAID" then
        return
    end
    local _, isML = Util.GetGroupRole(sender)
    if not isML then return end
    local kind, itemID = msg.r, tonumber(msg.i)
    if (kind ~= "de" and kind ~= "bank") or not IsValidItemID(itemID) then return end
    local w = type(msg.w) == "string" and #msg.w <= 64 and not msg.w:find("[%c|]") and Util.NormalizeName(msg.w) or nil
    local target = ns.Guild and ns.Guild.GetLootTarget and ns.Guild:GetLootTarget(kind)
    if not w or w ~= target then
        ns:Debug("Loot: LT from %s ignored (%s is not the %s character)", tostring(sender), tostring(w), tostring(kind))
        return
    end
    if not AmRealCouncil() or not (ns.Ledger and ns.Ledger.RecordTargetAward) then return end
    local b = msg.b
    if type(b) ~= "string" or #b > MAX_TARGET_BOSS_LEN or (b ~= "" and not (ns.ItemDB and ns.ItemDB:GetBossRef(b))) then
        b = ""
    end
    local now = GetServerTime()
    local at = tonumber(msg.at)
    if not at or at ~= floor(at) or math.abs(at - now) > LT_AT_SLACK then at = now end
    ns.Ledger:RecordTargetAward(itemID, w, b, kind, sender, at)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

-- Test drops (/dz test) are session-only: keep them out of the saved history (§20 review).
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
        -- Hand-outs already sent keep waiting for their loot message (or the timeout).
    end)
    ns:RegisterEvent("LOOT_SLOT_CLEARED", OnLootSlotCleared)
    ns:RegisterEvent("UI_ERROR_MESSAGE", OnUIError)
    ns:RegisterEvent("OPEN_MASTER_LOOT_LIST", OnMasterLootList)
    ns:RegisterEvent("UPDATE_MASTER_LOOT_LIST", OnMasterLootList)
    ns:RegisterEvent("PLAYER_LOGOUT", StripTestDrops)
    ns:RegisterEvent("CHAT_MSG_LOOT", OnChatLoot)
    ns:RegisterEvent("START_LOOT_ROLL", OnStartLootRoll)
    ns:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
    ns:RegisterEvent("ENCOUNTER_START", function() pullFFA = FreeForAll() end)
    ns:RegisterEvent("PARTY_LOOT_METHOD_CHANGED", OnLootMethodChanged)
    ns:RegisterEvent("TRADE_SHOW", OnTradeShow)
    ns:RegisterEvent("TRADE_CLOSED", function() tradeOpen = false end)
    ns:RegisterEvent("TRADE_ACCEPT_UPDATE", OnTradeAccept)
    ns:RegisterEvent("UI_INFO_MESSAGE", OnTradeInfo)
    ns:On("ROLL_UPDATED", OnRollUpdatedForHeld)
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("D", OnDropMessage)
        ns.Comm:Register("LT", OnTargetHandout)   -- 1.3: DE / bank hand-outs of a master looter outside the council
    end
    ns:RegisterSlash("test", function() Loot:SimulateDrop() end, "simulate a boss drop to try the alerts")
    ns:RegisterSlash("drop", function(rest) Loot:ManualDrop(rest) end,
        "<item links> - announce a drop to the raid (loot council / master looter)")
end

function Loot:OnLogin()
    StripTestDrops()   -- in case the last session ended without PLAYER_LOGOUT (crash)
    PruneHistory(self:GetHistory())
    PruneHeld(HeldList())
    wasBagLoot = BagLootMethodOn()
end

-- CDLoot: Core/Ledger.lua
-- Award log (council only): auto/manual entries, void/restore, merge rules, a de-duplicated
-- view that is identical on every client, and digest-based sync (A / LW / LG messages).
-- Demo mode (Addendum A §20): reads and user writes go to an in-memory table, nothing is sent,
-- and demo awards that older versions saved are purged at login.
-- Dungeon mode (Addendum B §22.2): entries created in dungeon mode inside a 5-man instance carry
-- dg = true (optional wire field; older clients drop it). CountSince ignores them unless asked.
local addonName, ns = ...

local Ledger = ns:NewModule("Ledger")
local Util = ns.Util

local floor, max, min = math.floor, math.max, math.min
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local DIGEST_DAYS = 120
local SAME_KIND_WINDOW = 120          -- two auto (or two manual) entries this close = one award
local MANUAL_WINS_AFTER = 6 * 3600    -- an auto entry up to 6h after a manual one is hidden
local MANUAL_WINS_BEFORE = 600        -- ... and up to 10 min before it (award clicked after handing out)
local MAX_DAYS_PER_LW = 30
local MAX_ENTRIES_PER_LG = 20
local MAX_ENTRIES_PER_LG_RECV = 40
local MAX_PENDING_DAYS = 130
local MAX_ID_LEN = 64
local MAX_GUILD_LEN = 128
local MAX_NOTE_LEN = 200
local MAX_TS = 4102444800             -- year 2100; anything larger is junk

local LibDeflate = LibStub and LibStub("LibDeflate", true)

-- View cache (rebuilt lazily after any change)
local view            -- { all = {...newest first, visible non-void + voided}, byWinner = {[key]={entries}}, awarded = {[key]={[itemID]=true}} }
local pendingLW = {}  -- [senderKey] = {[day]=true} ledger days requested by a council peer

-- Demo isolation (§20)
local demoEntries = {}      -- [id] = entry: the ledger while demo mode is on (in memory only)
local deferredSend = {}     -- [id] = true: real entries recorded while demo was on, sent when it ends
local purgeDone = false
local scopeKey              -- guild key the view / legacy adoption was last computed for

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function LedgerDB()
    local db = ns.db
    if not db then return nil end
    if type(db.ledger) ~= "table" then db.ledger = {} end
    return db.ledger
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

-- Where reads and user-initiated writes go: the demo table while demo mode is on.
local function ActiveDB()
    if DemoOn() then return demoEntries end
    return LedgerDB()
end

-- CDLootDB is account-wide: every real entry carries g = the guild key it belongs to, and only the
-- current guild's entries are shown, digested or served (an alt in another guild must not mix logs).
local function CurrentGuildKey()
    local Guild = ns.Guild
    return Guild and Guild.GetGuildKey and Guild:GetGuildKey() or nil
end

local function InScope(e, gkey)
    return gkey ~= nil and e.g == gkey
end

-- Network copy of a stored entry (the guild tag stays local; the receiver applies its own).
local function Wire(e)
    local out = {}
    for k, v in pairs(e) do
        if k ~= "g" then out[k] = v end
    end
    return out
end

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function IsStr(s, maxLen, allowEmpty)
    return type(s) == "string" and #s <= maxLen and (allowEmpty or s ~= "")
end

-- Real council membership (demo mode makes AmICouncil() true for everyone; the real ledger and
-- the network must never rely on that).
local function AmRealCouncil()
    return ns.Guild and ns.Guild.AmICouncil and ns.Guild:AmICouncil(true) or false
end

-- May record into the active ledger: real council, or anyone while demo mode is on.
local function CanRecord()
    return DemoOn() or AmRealCouncil()
end

-- Addendum B §22.2: dungeon mode is active and I am inside a 5-man instance.
local function DungeonContext()
    return (Util.IsDungeonModeActive and Util.IsDungeonModeActive() and Util.InPartyInstance
        and Util.InPartyInstance()) and true or false
end

-- dg field of a new entry: an explicit true / false from the caller, else the current context.
local function DgFlag(dg)
    if dg == nil then dg = DungeonContext() end
    return dg and true or nil
end

local function IsCouncilPair(sender)
    return AmRealCouncil() and ns.Guild.IsCouncil and ns.Guild:IsCouncil(sender, true) or false
end

-- [name] = true for the demo roster's fake names (§20 purge / merge filter).
local function FakeNameSet()
    local Demo = ns.Demo
    local names = Demo and Demo.GetFakeNames and Demo:GetFakeNames()
    local set = {}
    if type(names) == "table" then
        for _, n in ipairs(names) do
            if type(n) == "string" then set[n] = true end
        end
    end
    return set
end

-- A winner key that looks like a demo award: the name part is a demo fake name and the key is
-- not a real guild member. Only decidable once the real roster is known.
local function IsDemoWinner(key, fakeSet)
    if type(key) ~= "string" then return false end
    local name = key:match("^([^%-]+)") or key
    if not fakeSet[name] then return false end
    local Guild = ns.Guild
    if Guild and Guild.IsInGuild and Guild:IsInGuild(key, true) then return false end
    return true
end

local function RosterKnown()
    local Guild = ns.Guild
    return (Guild and Guild.IsReady and Guild:IsReady()) and true or false
end

-- 8 hex digits without relying on %x handling values above 2^31.
local function Hex32(n)
    n = n or 0
    return string.format("%04x%04x", floor(n / 65536) % 65536, n % 65536)
end

local function Checksum(str)
    if LibDeflate and LibDeflate.Adler32 then
        return Hex32(LibDeflate:Adler32(str))
    end
    return Hex32(#str)
end

local function IdName(key)
    local short = Util.ShortName(key) or key or "?"
    return short:sub(1, 24)
end

local function Invalidate()
    view = nil
    Util.Debounce("ledger-updated", 0.2, function() ns:Fire("LEDGER_UPDATED") end)
end

local function ExpandDrop(itemID)
    if ns.ItemDB and ns.ItemDB.ExpandDrop then
        local list = ns.ItemDB:ExpandDrop(itemID)
        if type(list) == "table" then return list end
    end
    return { itemID }
end

-- Nothing is sent while demo mode is on (§20).
local function Send(msg, target, class)
    if DemoOn() then return false end
    if ns.Comm and ns.Comm.Send then
        return ns.Comm:Send(msg, "WHISPER", target, class)
    end
    return false
end

-- Sends a REAL ledger entry to the online council. While demo mode is on it is remembered and
-- sent when demo mode ends.
local function Broadcast(entry)
    if type(entry) ~= "table" then return end
    if DemoOn() then
        deferredSend[entry.id] = true
        return
    end
    if ns.Comm and ns.Comm.SendToCouncil and AmRealCouncil() and InScope(entry, CurrentGuildKey()) then
        ns.Comm:SendToCouncil({ t = "A", e = Wire(entry) }, "ctrl")
    end
end

local function FlushDeferred()
    local db = LedgerDB()
    local ids = deferredSend
    deferredSend = {}
    if not db or DemoOn() then return end
    for id in pairs(ids) do
        local e = db[id]
        if type(e) == "table" then Broadcast(e) end
    end
end

-- Validates an (untrusted) entry and returns a clean copy with known fields only.
local function Clean(e)
    if type(e) ~= "table" then return nil, "not a table" end
    if not IsStr(e.id, MAX_ID_LEN) then return nil, "bad id" end
    if not IsInt(e.i, 1, 200000) then return nil, "bad item" end
    if not IsStr(e.w, MAX_ID_LEN) then return nil, "bad winner" end
    if not IsStr(e.by, MAX_ID_LEN) then return nil, "bad recorder" end
    if not IsInt(e.ts, 1, MAX_TS) then return nil, "bad ts" end
    if e.s ~= "a" and e.s ~= "m" then return nil, "bad source" end
    if e.b ~= nil and not IsStr(e.b, MAX_ID_LEN, true) then return nil, "bad boss" end
    if e.n ~= nil and not IsStr(e.n, MAX_NOTE_LEN, true) then return nil, "bad note" end
    if e.vd ~= nil and type(e.vd) ~= "boolean" then return nil, "bad void flag" end
    if e.vts ~= nil and not IsInt(e.vts, 0, MAX_TS) then return nil, "bad void ts" end
    if e.dg ~= nil and type(e.dg) ~= "boolean" then return nil, "bad dungeon flag" end
    local w = Util.NormalizeName(e.w)
    local by = Util.NormalizeName(e.by)
    if not w or not by then return nil, "bad names" end
    return {
        id = e.id, i = e.i, w = w, b = e.b or "", ts = e.ts, by = by, s = e.s,
        n = (e.n ~= nil and e.n ~= "") and e.n or nil,
        vd = e.vd and true or nil,
        vts = e.vts,
        dg = e.dg and true or nil,                      -- 5-man dungeon loot (Addendum B)
        g = IsStr(e.g, MAX_GUILD_LEN) and e.g or nil,   -- local guild tag (Merge replaces it)
    }
end

local function OrderAsc(a, b)
    if a.ts ~= b.ts then return a.ts < b.ts end
    return a.id < b.id
end

local function OrderDesc(a, b)
    if a.ts ~= b.ts then return a.ts > b.ts end
    return a.id > b.id
end

---------------------------------------------------------------------------
-- De-duplicated view. Depends only on entry contents, so every client that holds the
-- same entries shows exactly the same awards.
--   Within each (winner, item) group of non-void entries:
--   1. same-kind entries (auto/auto or manual/manual) within 120s of the last kept one are
--      hidden (sorted by ts, then id: the earliest / smallest id wins);
--   2. an auto entry from 10 min before to 6h after a kept manual entry is hidden.
---------------------------------------------------------------------------

local function BuildView()
    local demo = DemoOn()
    local db = ActiveDB() or {}
    local gkey = CurrentGuildKey()
    local groups, all = {}, {}
    for _, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and type(e.w) == "string" and type(e.i) == "number"
            and (demo or InScope(e, gkey)) then
            if e.vd then
                all[#all + 1] = e
            else
                local k = e.w .. "\001" .. e.i
                local g = groups[k]
                if not g then
                    g = {}
                    groups[k] = g
                end
                g[#g + 1] = e
            end
        end
    end

    for _, g in pairs(groups) do
        tsort(g, OrderAsc)
        local manuals, autos = {}, {}
        local lastManual, lastAuto
        for _, e in ipairs(g) do
            if e.s == "m" then
                if not (lastManual and e.ts - lastManual.ts <= SAME_KIND_WINDOW) then
                    manuals[#manuals + 1] = e
                    lastManual = e
                end
            else
                if not (lastAuto and e.ts - lastAuto.ts <= SAME_KIND_WINDOW) then
                    autos[#autos + 1] = e
                    lastAuto = e
                end
            end
        end
        for _, m in ipairs(manuals) do
            all[#all + 1] = m
        end
        for _, a in ipairs(autos) do
            local hidden = false
            for _, m in ipairs(manuals) do
                if a.ts >= m.ts - MANUAL_WINS_BEFORE and a.ts <= m.ts + MANUAL_WINS_AFTER then
                    hidden = true
                    break
                end
            end
            if not hidden then all[#all + 1] = a end
        end
    end

    tsort(all, OrderDesc)
    local byWinner, awarded = {}, {}
    for _, e in ipairs(all) do
        if not e.vd then
            local list = byWinner[e.w]
            if not list then
                list = {}
                byWinner[e.w] = list
                awarded[e.w] = {}
            end
            list[#list + 1] = e
            local set = awarded[e.w]
            set[e.i] = true
            for _, id in ipairs(ExpandDrop(e.i)) do
                set[id] = true
            end
        end
    end
    view = { all = all, byWinner = byWinner, awarded = awarded }
    return view
end

local function GetView()
    return view or BuildView()
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- A real loot message: always recorded into the REAL ledger (real council only), also while demo
-- mode is on (then it is sent to the council once demo mode ends).
-- dg (optional): true = 5-man dungeon loot; nil = derived from the current dungeon-mode context.
function Ledger:RecordAuto(itemID, winnerKey, bossKey, dg)
    if not AmRealCouncil() then return nil end
    local db = LedgerDB()
    local me = Util.PlayerKey()
    winnerKey = Util.NormalizeName(winnerKey)
    if not db or not me or not winnerKey or not IsInt(itemID, 1, 200000) then return nil end
    local gkey = CurrentGuildKey()
    if not gkey then return nil end
    local ts = GetServerTime()
    local id = ("a" .. ts .. IdName(winnerKey) .. itemID):sub(1, MAX_ID_LEN)
    if db[id] then return db[id] end   -- same loot line seen twice / already received from a peer
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = me, s = "a",
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "", g = gkey, dg = DgFlag(dg),
    }
    db[id] = entry
    Invalidate()
    Broadcast(entry)
    return entry
end

-- Manual award. In demo mode it goes to the in-memory demo ledger and is never sent.
-- dg (optional): true / false = 5-man dungeon loot or not; nil = derived from the dungeon-mode context.
function Ledger:Award(itemID, winnerKey, bossKey, note, dg)
    if not CanRecord() then
        ns:Print("Only loot council members can record awards.")
        return nil
    end
    local demo = DemoOn()
    local db = ActiveDB()
    local me = Util.PlayerKey()
    itemID = tonumber(itemID)
    winnerKey = Util.NormalizeName(winnerKey)
    if not db or not me or not winnerKey or not IsInt(itemID, 1, 200000) then return nil end
    if type(note) == "string" then
        note = note:gsub("^%s+", ""):gsub("%s+$", "")
        if note == "" then note = nil else note = note:sub(1, MAX_NOTE_LEN) end
    else
        note = nil
    end
    local ts = GetServerTime()
    local base = ("m" .. ts .. IdName(me) .. itemID):sub(1, MAX_ID_LEN - 4)
    local id, n = base, 1
    while db[id] do
        n = n + 1
        id = base .. "-" .. n
    end
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = me, s = "m", n = note,
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "",
        g = (not demo) and CurrentGuildKey() or nil,
        dg = DgFlag(dg),
    }
    db[id] = entry
    Invalidate()
    if not demo then Broadcast(entry) end
    return entry
end

-- Roll awards (Addendum A §19.1 step 3) go to the REAL ledger, also while demo mode is on. The id
-- depends only on the session and the winner, so every council client that sees the award (its own
-- click, or the RW of a non-council master looter) writes the very same entry.
local function RollAwardID(sessionID, winnerKey)
    return ("m" .. sessionID .. "-" .. IdName(winnerKey)):sub(1, MAX_ID_LEN)
end

-- broadcast: true for the awarding client (receivers of RW record it themselves).
-- dg: true / false = a party (dungeon mode) roll or not, so every council client writes the same
-- entry; nil = derived from the dungeon-mode context.
function Ledger:RecordRollAward(sessionID, itemID, winnerKey, bossKey, note, byKey, ts, broadcast, dg)
    if not AmRealCouncil() or not IsStr(sessionID, MAX_ID_LEN) then return nil end
    local db = LedgerDB()
    local gkey = CurrentGuildKey()
    winnerKey = Util.NormalizeName(winnerKey)
    byKey = Util.NormalizeName(byKey) or Util.PlayerKey()
    itemID = tonumber(itemID)
    if not db or not gkey or not winnerKey or not byKey or not IsInt(itemID, 1, 200000) then return nil end
    local id = RollAwardID(sessionID, winnerKey)
    if type(db[id]) == "table" then return db[id] end
    ts = tonumber(ts)
    if not IsInt(ts, 1, MAX_TS) then ts = GetServerTime() end
    if type(note) == "string" and note ~= "" then note = note:sub(1, MAX_NOTE_LEN) else note = nil end
    local entry = {
        id = id, i = itemID, w = winnerKey, ts = ts, by = byKey, s = "m", n = note,
        b = IsStr(bossKey, MAX_ID_LEN, true) and bossKey or "", g = gkey, dg = DgFlag(dg),
    }
    db[id] = entry
    Invalidate()
    if broadcast then Broadcast(entry) end
    return entry
end

-- Voids the roll award of sessionID to winnerKey (lost a conflicting award). Returns true if changed.
function Ledger:VoidRollAward(sessionID, winnerKey)
    if not AmRealCouncil() or not IsStr(sessionID, MAX_ID_LEN) then return false end
    local db = LedgerDB()
    winnerKey = Util.NormalizeName(winnerKey)
    local e = db and winnerKey and db[RollAwardID(sessionID, winnerKey)]
    if type(e) ~= "table" or e.vd then return false end
    e.vd = true
    e.vts = max(GetServerTime(), (e.vts or 0) + 1)
    Invalidate()
    Broadcast(e)
    return true
end

function Ledger:Void(id, voided)
    if not CanRecord() then return false end
    local demo = DemoOn()
    local db = ActiveDB()
    local e = db and type(id) == "string" and db[id]
    if type(e) ~= "table" then return false end
    local value = voided and true or nil
    if e.vd == value then return false end
    e.vd = value
    -- strictly increasing so a quick void + restore still wins on every peer
    e.vts = max(GetServerTime(), (e.vts or 0) + 1)
    Invalidate()
    if not demo then Broadcast(e) end
    return true
end

function Ledger:GetEntry(id)
    local db = ActiveDB()
    return db and type(id) == "string" and db[id] or nil
end

-- True while reads/writes use the in-memory demo ledger (§20).
function Ledger:IsDemo()
    return DemoOn()
end

-- Union by id. For an id we already hold, only the void state can change:
-- the side with the greater vts wins; on a tie the voided side wins. The dungeon flag (dg) is only
-- ever added (an older client relays entries without it).
-- Network data always goes to the REAL ledger, also while demo mode is on.
function Ledger:Merge(entry, fromKey)
    local e, err = Clean(entry)
    if not e then
        ns:Debug("Ledger: rejected entry from %s: %s", tostring(fromKey), tostring(err))
        return false
    end
    -- Demo awards saved and synced by CDLoot 0.1 must not come back through sync (§20).
    if RosterKnown() and IsDemoWinner(e.w, FakeNameSet()) then
        ns:Debug("Ledger: rejected demo award %s from %s", e.id, tostring(fromKey))
        return false
    end
    local db = LedgerDB()
    local gkey = CurrentGuildKey()
    if not db or not gkey then return false end
    e.g = gkey   -- entries from a peer belong to the guild we share with it
    local cur = db[e.id]
    if type(cur) ~= "table" then
        db[e.id] = e
        Invalidate()
        return true
    end
    local changed = false
    if e.dg and not cur.dg then
        cur.dg = true
        changed = true
    end
    local cv, ev = cur.vts or 0, e.vts or 0
    local take = (ev > cv) or (ev == cv and e.vd and not cur.vd)
    if take and not (cur.vd == e.vd and cur.vts == e.vts) then
        cur.vd = e.vd
        cur.vts = e.vts
        changed = true
    end
    if changed then Invalidate() end
    return changed
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

-- filter = { player = key, includeVoid = bool, since = ts, excludeDungeon = bool, dungeonOnly = bool }.
-- Newest first. Returned tables are the stored entries: treat them as read-only. Voided ones have
-- vd = true; 5-man dungeon loot has dg = true.
function Ledger:GetEntries(filter)
    filter = type(filter) == "table" and filter or {}
    local player = filter.player and Util.NormalizeName(filter.player)
    local since = tonumber(filter.since)
    local out = {}
    for _, e in ipairs(GetView().all) do
        if (filter.includeVoid or not e.vd)
            and (not player or e.w == player)
            and (not since or e.ts >= since)
            and not (filter.excludeDungeon and e.dg)
            and not (filter.dungeonOnly and not e.dg) then
            out[#out + 1] = e
        end
    end
    return out
end

function Ledger:HasAward(key, wantedItemID)
    if not key or not wantedItemID then return false end
    local set = GetView().awarded[key]
    return set and set[wantedItemID] and true or false
end

-- Awards to key since ts ("won N tonight"). 5-man dungeon loot (dg) is not counted unless
-- includeDungeon is true.
function Ledger:CountSince(key, ts, includeDungeon)
    local list = key and GetView().byWinner[key]
    if not list then return 0 end
    ts = tonumber(ts) or 0
    local n = 0
    for _, e in ipairs(list) do
        if e.ts >= ts and (includeDungeon or not e.dg) then n = n + 1 end
    end
    return n
end

-- true while new entries get dg = true (dungeon mode active inside a 5-man instance).
function Ledger:IsDungeonContext()
    return DungeonContext()
end

---------------------------------------------------------------------------
-- Digest sync
---------------------------------------------------------------------------

function Ledger:GetDigest()
    local db = LedgerDB()
    local out = {}
    if not db then return out end
    local minDay = floor(GetServerTime() / DAY) - DIGEST_DAYS
    local gkey = CurrentGuildKey()
    local perDay = {}
    for id, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and InScope(e, gkey) then
            local day = floor(e.ts / DAY)
            if day >= minDay then
                local list = perDay[day]
                if not list then
                    list = {}
                    perDay[day] = list
                end
                list[#list + 1] = e.vd and (id .. "v" .. tostring(floor(e.vts or 0))) or id
            end
        end
    end
    for day, list in pairs(perDay) do
        tsort(list)
        out[day] = Checksum(tconcat(list, "\n"))
    end
    return out
end

-- Requests the days where X's digest differs from ours. Days X has no entries for are skipped:
-- X asks us for those itself when it processes our digest (H/M carry both sides' digests).
function Ledger:SyncFromDigest(X, digest)
    if DemoOn() or not AmRealCouncil() or type(X) ~= "string" or type(digest) ~= "table" then return end
    local mine = self:GetDigest()
    local today = floor(GetServerTime() / DAY)
    local days, seen = {}, 0
    for day, h in pairs(digest) do
        seen = seen + 1
        if seen > 400 then break end   -- untrusted table size guard
        if IsInt(day, today - DIGEST_DAYS, today + 1) and IsStr(h, 16) and mine[day] ~= h then
            days[#days + 1] = day
        end
    end
    if #days == 0 then return end
    tsort(days, function(a, b) return a > b end)
    for i = 1, #days, MAX_DAYS_PER_LW do
        local batch = {}
        for j = i, min(i + MAX_DAYS_PER_LW - 1, #days) do
            batch[#batch + 1] = days[j]
        end
        Send({ t = "LW", d = batch }, X, "ctrl")
    end
end

local function FlushLedgerWant(sender)
    local days = pendingLW[sender]
    pendingLW[sender] = nil
    local db = LedgerDB()
    if not days or not db or not IsCouncilPair(sender) then return end
    local gkey = CurrentGuildKey()
    local list = {}
    for _, e in pairs(db) do
        if type(e) == "table" and type(e.ts) == "number" and days[floor(e.ts / DAY)] and InScope(e, gkey) then
            list[#list + 1] = Wire(e)
        end
    end
    tsort(list, OrderAsc)
    for i = 1, #list, MAX_ENTRIES_PER_LG do
        local batch = {}
        for j = i, min(i + MAX_ENTRIES_PER_LG - 1, #list) do
            batch[#batch + 1] = list[j]
        end
        Send({ t = "LG", e = batch }, sender, "data")
    end
end

local function OnAward(sender, msg)
    if not IsCouncilPair(sender) or type(msg) ~= "table" then return end
    Ledger:Merge(msg.e, sender)
end

local function OnLedgerWant(sender, msg)
    if DemoOn() then return end   -- nothing is sent in demo mode; the peer asks again later
    if not IsCouncilPair(sender) or type(msg) ~= "table" or type(msg.d) ~= "table" then return end
    local set = pendingLW[sender] or {}
    local count = 0
    for _ in pairs(set) do count = count + 1 end
    for k = 1, MAX_DAYS_PER_LW do
        local day = msg.d[k]
        if day == nil or count >= MAX_PENDING_DAYS then break end
        if IsInt(day, 0, 1000000) and not set[day] then
            set[day] = true
            count = count + 1
        end
    end
    pendingLW[sender] = set
    -- coalesce repeated requests from the same peer into one reply burst
    Util.Debounce("ledger-lw:" .. sender, 1, function() FlushLedgerWant(sender) end)
end

local function OnLedger(sender, msg)
    if not IsCouncilPair(sender) or type(msg) ~= "table" or type(msg.e) ~= "table" then return end
    for k = 1, MAX_ENTRIES_PER_LG_RECV do
        local e = msg.e[k]
        if e == nil then break end
        Ledger:Merge(e, sender)
    end
end

---------------------------------------------------------------------------
-- Demo isolation (§20)
---------------------------------------------------------------------------

-- Removes awards to demo fake members from the saved ledger (CDLoot 0.1 wrote them there).
-- Needs the real guild roster, so it runs once the roster is ready (or, for a character without
-- a guild, a while after login). Returns the number removed.
function Ledger:PurgeDemoAwards()
    local db = LedgerDB()
    if not db then return 0 end
    if not RosterKnown() and IsInGuild() then return 0 end
    purgeDone = true
    local fakeSet = FakeNameSet()
    if next(fakeSet) == nil then return 0 end
    local removed = 0
    for id, e in pairs(db) do
        if type(e) == "table" and IsDemoWinner(e.w, fakeSet) then
            db[id] = nil
            deferredSend[id] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        Invalidate()
        ns:Print("removed %d demo award(s) from the loot log.", removed)
    end
    return removed
end

-- allowNoGuild: also purge when the character is not in a guild (only used well after login,
-- when IsInGuild() is settled).
local function TryPurge(allowNoGuild)
    if purgeDone or not ns.loggedIn then return end
    if RosterKnown() or (allowNoGuild == true and not IsInGuild()) then
        Ledger:PurgeDemoAwards()
    end
end

-- Entries saved by CDLoot 0.1 have no guild tag: adopt those recorded by (or awarded to) a member of
-- the current guild. Others stay untagged until a character of their guild logs in. Also drops the
-- cached view when the guild changed.
local function UpdateScope()
    local gkey = CurrentGuildKey()
    if gkey ~= scopeKey then
        scopeKey = gkey
        Invalidate()
    end
    local db = LedgerDB()
    local Guild = ns.Guild
    if not db or not gkey or not RosterKnown() or not Guild.IsInGuild then return end
    local adopted = 0
    for _, e in pairs(db) do
        if type(e) == "table" and e.g == nil
            and (Guild:IsInGuild(e.by, true) or Guild:IsInGuild(e.w, true)) then
            e.g = gkey
            adopted = adopted + 1
        end
    end
    if adopted > 0 then Invalidate() end
end

local function OnDemoToggled(enabled)
    -- A fresh, empty demo ledger on every enable; disabling discards it.
    demoEntries = {}
    view = nil
    Invalidate()
    if not enabled then FlushDeferred() end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Ledger:OnInit()
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("A", OnAward)
        ns.Comm:Register("LW", OnLedgerWant)
        ns.Comm:Register("LG", OnLedger)
    end
    ns:On("DEMO_TOGGLED", OnDemoToggled)
    ns:On("ROSTER_UPDATED", function()
        TryPurge(false)
        UpdateScope()
    end)
    ns:On("CONFIG_UPDATED", function() TryPurge(false) end)
end

function Ledger:OnLogin()
    -- Drop or repair malformed saved entries so the view can trust field types
    -- (done at login: name normalization needs the player's realm).
    local db = LedgerDB()
    if not db then return end
    for id, e in pairs(db) do
        local clean = Clean(e)
        if not clean or clean.id ~= id then
            db[id] = nil
        else
            db[id] = clean
        end
    end
    view = nil
    -- Demo purge: as soon as the guild roster is known (ROSTER_UPDATED), or 20s after login for a
    -- character without a guild.
    TryPurge(false)
    Util.After(20, function() TryPurge(true) end)
end

-- CDLoot: cached BiS lists of other players (council only), unified record access for the UI
-- (own record from ns.BiS, demo records when Demo is on) and the "who wants item X" index.
-- Addendum F: disabled slots (data.dx) are validated and left out of the index / summaries (§36); while the
-- raid's BiS lists are locked, council clients flag players whose picks change (§38, GetLockFlag).
local addonName, ns = ...

local Store = ns:NewModule("Store")
local Util = ns.Util

local type, pairs, ipairs, next, tonumber, tostring, pcall = type, pairs, ipairs, next, tonumber, tostring, pcall
local floor = math.floor
local tsort = table.sort

-- Validation limits (SPEC §8.1)
local MAX_ITEM_ID = 200000
local MAX_OB = 200
local MAX_STRING = 24
local MAX_HASH_LEN = 16
local MAX_NODES = 1500          -- total table entries in one list (guards Canonical / copies)
local MAX_DEPTH = 4
local MAX_REV = ns.MAX_REV or 2147483647   -- accepted revs (shared with Sync and BiS)
local MAX_REV_JUMP = 100000     -- a relayed rev this far above the cached copy is implausible (same bound as Sync's
                                -- PlausibleOwnRev: honest revs grow by one per commit)
local PRUNE_AFTER = 30 * 86400  -- drop lists of players missing from the roster this long
local AWARD_WINDOW = 6 * 3600   -- "won tonight"

local index = {}                -- [wantedItemID] = { {key=, phase=, sid=, which=}, ... } (disabled slots left out)
local obSets = {}               -- [key] = { [itemID] = true }
local indexDirty = true

-- Addendum F §38: council change detection while the raid's BiS lists are locked (memory only).
local lockActive = false
local lockSnap = {}             -- [key] = picks hash when the lock started (or of the first list seen during it)
local lockFlags = {}            -- [key] = GetServerTime() when a list with other picks arrived during the lock
local lockWarned = {}           -- [key] = true: the council chat warning was printed
local lockNotes = {}            -- [key] = GetServerTime(): a list that claims a pre-lock commit although it cannot be
                                -- one (soft marker: a warning, never excluded from suggestions)
local lockSeenAt                -- GetServerTime() when this client learned the lock
local confirmed = {}            -- [key] = { rev=, at= }: the owner's own push (direct L) of that rev arrived here
local LOCK_NOTE_WINDOW = 60     -- lists arriving this long after I learned the lock are late for a pre-lock commit
local LOCK_GRACE = 3            -- lists committed up to this long after the lock started count as before it
                                -- (BiS commits a pending edit as soon as the lock arrives)
local WARN_ICON = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:0|t"   -- the default font has no warning sign

local function MaxPhase() return ns.MAX_PHASE or 5 end
local function NumSlots() return ns.NUM_SLOTS or 17 end

local function IsInt(x, lo, hi)
    return type(x) == "number" and x == floor(x) and x >= lo and x <= hi
end

local function DemoOn()
    local Demo = ns.Demo
    return Demo and Demo.IsEnabled and Demo:IsEnabled() and true or false
end

local function DemoRecords()
    local Demo = ns.Demo
    if DemoOn() and Demo.GetRecords then
        local r = Demo:GetRecords()
        if type(r) == "table" then return r end
    end
    return nil
end

local function Lists()
    local db = ns.db
    if not db then return {} end
    if type(db.lists) ~= "table" then db.lists = {} end
    return db.lists
end

local function OwnRecord()
    local BiS = ns.BiS
    if BiS and BiS.GetRecord then return BiS:GetRecord() end
    return nil
end

local function MarkDirty()
    indexDirty = true
end

---------------------------------------------------------------------------
-- Lock change detection (Addendum F §38)
---------------------------------------------------------------------------

-- Hash of what the lock freezes: the picks, the disabled slots and the spec, of both specs (Addendum H).
local function PicksHash(data)
    if type(data) ~= "table" then return nil end
    local ok, h = pcall(Util.Hash, { ph = data.ph, dx = data.dx, sp = data.sp, os = data.os, op = data.op, ox = data.ox })
    return ok and h or nil
end

local function InRealGroup(key)
    return type(Util.group) == "table" and Util.group[key] ~= nil
end

local function AmCouncil()
    local Guild = ns.Guild
    return (Guild and Guild.AmICouncil and Guild:AmICouncil(true)) and true or false
end

-- While locked: snapshot every (real) group member that has none yet, from its cached list. Members
-- without a cached list get their snapshot from the first list that arrives.
local function SnapshotMissing()
    if not lockActive or not AmCouncil() or type(Util.group) ~= "table" then return end
    local lists = Lists()
    for key in pairs(Util.group) do
        if lockSnap[key] == nil and not Util.IsMe(key) then
            local rec = lists[key]
            local h = type(rec) == "table" and PicksHash(rec.data) or nil
            if h then lockSnap[key] = h end
        end
    end
end

-- Lock start (the authority's server time), or nil.
local function LockStartedAt()
    local GR = ns.GroupRules
    local info = GR and GR.GetLockInfo and GR:GetLockInfo()
    return type(info) == "table" and tonumber(info.at) or nil
end

-- An accepted list during the lock: flag the player when the picks differ from the snapshot. A list the
-- owner committed before the lock or within LOCK_GRACE seconds after it (an edit made just before the lock
-- still waiting for its debounced commit, or an older copy arriving late) only updates the snapshot.
-- The commit time is the owner's own claim, so a modified client could backdate a change made during the lock.
-- When receiver-side facts rule an honest pre-lock commit out - the owner's own push of an older rev reached me
-- before the lock started (OnCommitted pushes every commit to online council at once) and this higher rev with
-- other picks arrives well after I learned the lock - the list gets a soft note: a council warning, but no flag
-- (a lost push must never cost an honest raider the suggestion).
-- prev: the owner's own push confirmed before this list ({ rev, at }), or nil.
local function CheckLockChange(key, data, ts, rev, prev)
    if not lockActive or not InRealGroup(key) or Util.IsMe(key) then return end
    local h = PicksHash(data)
    if not h then return end
    local snap = lockSnap[key]
    local startedAt = LockStartedAt()
    if snap == nil or (startedAt and type(ts) == "number" and ts > 0 and ts <= startedAt + LOCK_GRACE) then
        local c = prev
        local now = GetServerTime()
        if snap ~= nil and h ~= snap and c and startedAt and c.at <= startedAt and type(rev) == "number"
            and rev > c.rev and lockSeenAt and now - lockSeenAt > LOCK_NOTE_WINDOW and not lockNotes[key] then
            lockNotes[key] = now
            ns:Print("%s %s's BiS list changed while lists were locked but claims an earlier save (rev %d -> %d); "
                .. "not flagged, please check.", WARN_ICON, Util.ShortName(key), c.rev, rev)
            MarkDirty()
        end
        lockSnap[key] = h
        return
    end
    if h ~= snap and not lockFlags[key] then
        lockFlags[key] = GetServerTime()
        if not lockWarned[key] then
            lockWarned[key] = true
            ns:Print("%s %s changed their BiS list while lists were locked.", WARN_ICON, Util.ShortName(key))
        end
    end
end

local function OnLockChanged(locked)
    if locked == nil then
        local GR = ns.GroupRules
        locked = GR and GR.IsLocked and GR:IsLocked()
    end
    locked = locked and true or false
    if locked == lockActive then return end
    lockActive = locked
    local hadFlags = next(lockFlags) ~= nil or next(lockNotes) ~= nil
    lockSnap, lockFlags, lockWarned, lockNotes = {}, {}, {}, {}
    lockSeenAt = locked and GetServerTime() or nil
    if locked then SnapshotMissing() end
    if hadFlags then MarkDirty() end
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

-- Bounds the size/depth of any table and rejects non-plain keys/values, so hashing and
-- copying an untrusted table cannot blow the stack or take long.
local function CheckShape(t, depth, budget)
    if depth > MAX_DEPTH then return false end
    for k, v in pairs(t) do
        budget.n = budget.n + 1
        if budget.n > MAX_NODES then return false end
        local tk, tv = type(k), type(v)
        if tk ~= "number" and tk ~= "string" then return false end
        if tk == "string" and #k > 64 then return false end
        if tv == "table" then
            if not CheckShape(v, depth + 1, budget) then return false end
        elseif tv == "string" then
            if #v > 255 then return false end
        elseif tv ~= "number" and tv ~= "boolean" then
            return false
        end
    end
    return true
end

local function ValidString(s)
    return s == nil or (type(s) == "string" and #s <= MAX_STRING and not s:find("[%c|]"))
end

-- A phases table (ph, or the off spec's op): { [phase] = { [sid] = { main, alt } } }. Returns ok, err.
local function ValidPhases(ph)
    if ph == nil then return true end
    if type(ph) ~= "table" then return false, "bad phases" end
    for phase, slots in pairs(ph) do
        if not IsInt(phase, 1, MaxPhase()) or type(slots) ~= "table" then return false, "bad phase" end
        for sid, pair in pairs(slots) do
            if not IsInt(sid, 1, NumSlots()) or type(pair) ~= "table" then return false, "bad slot" end
            for k, id in pairs(pair) do
                if (k ~= 1 and k ~= 2) or not IsInt(id, 0, MAX_ITEM_ID) then
                    return false, "bad slot item"
                end
            end
        end
    end
    return true
end

-- Disabled slots (dx, or the off spec's ox): { [phase] = { [sid] = true } }. Returns ok, err.
local function ValidDisabled(dx)
    if dx == nil then return true end
    if type(dx) ~= "table" then return false, "bad disabled slots" end
    for phase, slots in pairs(dx) do
        if not IsInt(phase, 1, MaxPhase()) or type(slots) ~= "table" then return false, "bad disabled phase" end
        for sid, v in pairs(slots) do
            if not IsInt(sid, 1, NumSlots()) or v ~= true then return false, "bad disabled slot" end
        end
    end
    return true
end

function Store:ValidateData(data)
    if type(data) ~= "table" then return false, "data is not a table" end
    if not CheckShape(data, 1, { n = 0 }) then return false, "data too large or malformed" end
    if not IsInt(data.v, 1, 1000) then return false, "bad schema version" end
    if not ValidString(data.cl) then return false, "bad class" end
    if not ValidString(data.sp) then return false, "bad spec" end

    local ok, err = ValidPhases(data.ph)
    if not ok then return false, err end

    -- Addendum H: the off-spec list, flat (os label, op phases, ox disabled) so older validators accept it.
    if not ValidString(data.os) then return false, "bad off spec" end
    ok, err = ValidPhases(data.op)
    if not ok then return false, "off spec: " .. err end
    ok, err = ValidDisabled(data.ox)
    if not ok then return false, "off spec: " .. err end

    local ob = data.ob
    if ob ~= nil then
        if type(ob) ~= "table" then return false, "bad obtained list" end
        local n = 0
        for k, id in pairs(ob) do
            n = n + 1
            if not IsInt(k, 1, MAX_OB) or not IsInt(id, 1, MAX_ITEM_ID) then return false, "bad obtained entry" end
        end
        if n > MAX_OB or n ~= #ob then return false, "bad obtained list" end
    end

    local eq = data.eq
    if eq ~= nil then
        if type(eq) ~= "table" then return false, "bad equipped list" end
        for sid, id in pairs(eq) do
            if not IsInt(sid, 1, NumSlots()) or not IsInt(id, 1, MAX_ITEM_ID) then return false, "bad equipped entry" end
        end
    end

    -- Addendum F §36: disabled slots { [phase] = { [sid] = true } }. Older clients ignore this key (their
    -- validator only checks the keys above) and still verify the hash, which covers it.
    ok, err = ValidDisabled(data.dx)
    if not ok then return false, err end
    return true
end

-- Addendum F §36: the slot is disabled in that record's list. record = a record ({data=}), a list's data
-- table, or a player key. list (Addendum H): "os" = the off-spec list.
function Store:IsSlotDisabled(record, phase, sid, list)
    if type(record) == "string" then record = Store:Get(record) end
    if type(record) ~= "table" then return false end
    local data = type(record.data) == "table" and record.data or record
    local dx = (list == "os") and data.ox or data.dx
    local p = type(dx) == "table" and dx[tonumber(phase) or 0]
    return (type(p) == "table" and p[tonumber(sid) or 0] == true) and true or false
end

---------------------------------------------------------------------------
-- Records
---------------------------------------------------------------------------

function Store:Get(key)
    if type(key) ~= "string" then return nil end
    if Util.IsMe(key) then return OwnRecord() end
    local demo = DemoRecords()
    if demo then return demo[key] end
    return Lists()[key]
end

-- Own key + (council or demo) cached keys; former guild members are left out.
function Store:GetAllKeys()
    local keys = {}
    local me = Util.PlayerKey()
    if me and OwnRecord() then keys[#keys + 1] = me end
    local demo = DemoRecords()
    local Guild = ns.Guild
    if demo then
        for key in pairs(demo) do
            if type(key) == "string" and key ~= me then keys[#keys + 1] = key end
        end
    elseif Guild and Guild:AmICouncil(true) then
        for key in pairs(Lists()) do
            if key ~= me and Guild:IsInGuild(key, true) then keys[#keys + 1] = key end
        end
    end
    tsort(keys)
    return keys
end

-- entry = { r=rev, ts=, h=hash, d=data } (wire shape). Returns true if stored.
function Store:Put(key, entry, via)
    if type(key) ~= "string" or type(entry) ~= "table" then return false end
    if Util.IsMe(key) then return false end   -- the owner's own copy is authoritative
    local Guild = ns.Guild
    if not (Guild and Guild:AmICouncil(true)) then return false end
    if not Guild:IsInGuild(key, true) then return false end

    local r, ts, h, d = entry.r, entry.ts, entry.h, entry.d
    if not IsInt(r, 1, MAX_REV) then return false end
    if type(ts) ~= "number" or ts ~= ts or ts < 0 then ts = 0 end
    if type(h) ~= "string" or #h > MAX_HASH_LEN then return false end
    local ok, err = Store:ValidateData(d)
    if not ok then
        ns:Debug("Rejected list for %s: %s", key, tostring(err))
        return false
    end
    local okHash, hash = pcall(Util.Hash, d)
    if not okHash or hash ~= h then
        ns:Debug("Rejected list for %s: hash mismatch", key)
        return false
    end

    local lists = Lists()
    local cur = lists[key]
    via = (type(via) == "string" and via ~= "") and via or "direct"
    local prevConfirmed = confirmed[key]
    if via == "direct" then confirmed[key] = { rev = r, at = GetServerTime() } end
    local curRev = type(cur) == "table" and (tonumber(cur.rev) or 0) or 0
    local accept = (type(cur) ~= "table")
        -- a relayed copy must not jump implausibly far above the one I hold (forged / bogus rev)
        or (r > curRev and (via == "direct" or r <= curRev + MAX_REV_JUMP))
        or (r == cur.rev and h ~= cur.hash and via == "direct")
        -- the owner's own push replaces a relayed copy implausibly far above it (forged by someone else)
        or (via == "direct" and cur.via ~= "direct" and curRev > r + MAX_REV_JUMP)
    if not accept then return false end

    lists[key] = {
        rev = r, ts = ts, hash = h, data = Util.CopyTable(d),
        recvAt = GetServerTime(), via = via,
        g = Guild.GetGuildName and Guild:GetGuildName() or nil,   -- which guild this copy belongs to
    }
    -- Addendum F §38: the list is accepted either way (obtained / equipped updates matter).
    CheckLockChange(key, d, ts, r, prevConfirmed)
    MarkDirty()
    ns:Fire("LIST_UPDATED", key)
    return true
end

-- Addendum F §38: GetServerTime() when key's list arrived with other picks (ph / dx / spec) while the
-- raid's BiS lists were locked ("changed during lock"), else nil. Cleared when the lock ends.
function Store:GetLockFlag(key)
    if not lockActive or type(key) ~= "string" then return nil end
    return lockFlags[key]
end

-- CDLoot 0.5: GetServerTime() when key's list arrived during the lock with other picks but a claimed pre-lock save
-- that receiver-side facts contradict (see CheckLockChange), else nil. A soft marker only: never excluded.
function Store:GetLockNote(key)
    if not lockActive or type(key) ~= "string" then return nil end
    return lockNotes[key]
end

-- { [key] = ts } of every flagged player (a copy; empty when unlocked).
function Store:GetLockFlags()
    local out = {}
    if lockActive then
        for key, ts in pairs(lockFlags) do out[key] = ts end
    end
    return out
end

function Store:Remove(key)
    local lists = Lists()
    if type(key) == "string" and lists[key] then
        lists[key] = nil
        MarkDirty()
        ns:Fire("LIST_UPDATED", key)
    end
end

-- { [key] = rev } for every cached list of a current guild member, plus my own rev.
function Store:GetManifest()
    local m = {}
    local Guild = ns.Guild
    local me = Util.PlayerKey()
    for key, rec in pairs(Lists()) do
        if key ~= me and type(rec) == "table" and IsInt(rec.rev, 1, MAX_REV)
            and Guild and Guild:IsInGuild(key, true) then
            m[key] = rec.rev
        end
    end
    local own = OwnRecord()
    if me and own and IsInt(own.rev, 1, MAX_REV) then
        m[me] = own.rev
    end
    return m
end

-- { [key] = hash } for the same keys as GetManifest (lets owners spot a same-rev copy with other data).
function Store:GetManifestHashes(manifest)
    local out = {}
    local me = Util.PlayerKey()
    local lists = Lists()
    for key in pairs(manifest or {}) do
        local rec = (key == me) and OwnRecord() or lists[key]
        if type(rec) == "table" and type(rec.hash) == "string" and #rec.hash <= MAX_HASH_LEN then
            out[key] = rec.hash
        end
    end
    return out
end

-- Returns the cached (non-demo) record of another player; used by Sync to serve relays.
function Store:GetCached(key)
    if type(key) ~= "string" then return nil end
    local rec = Lists()[key]
    return type(rec) == "table" and rec or nil
end

-- Drops lists of players who left the guild more than 30 days ago (only this guild's copies).
local function PruneFormerMembers()
    local Guild = ns.Guild
    if not (Guild and Guild:IsReady()) or not IsInGuild() then return end
    local gname = Guild:GetGuildName()
    if not gname then return end
    local now = GetServerTime()
    local removed = false
    local lists = Lists()
    for key, rec in pairs(lists) do
        if type(rec) ~= "table" then
            lists[key] = nil
            removed = true
        elseif rec.g == nil or rec.g == gname then
            if Guild:IsInGuild(key, true) then
                rec.missingSince = nil
            else
                rec.missingSince = rec.missingSince or now
                if now - rec.missingSince > PRUNE_AFTER then
                    lists[key] = nil
                    removed = true
                end
            end
        end
    end
    if removed then
        MarkDirty()
        ns:Fire("LISTS_RESET")
    end
end

---------------------------------------------------------------------------
-- Wanted-item index
---------------------------------------------------------------------------

-- os (Addendum H): the row comes from the off-spec list.
local function AddIndex(itemID, key, phase, sid, which, os)
    local list = index[itemID]
    if not list then
        list = {}
        index[itemID] = list
    end
    list[#list + 1] = { key = key, phase = phase, sid = sid, which = which, os = os }
end

local function IndexPhases(key, ph, dx, os)
    if type(ph) ~= "table" then return end
    dx = type(dx) == "table" and dx or nil
    for phase, slots in pairs(ph) do
        if type(phase) == "number" and type(slots) == "table" then
            local off = dx and dx[phase]
            if type(off) ~= "table" then off = nil end
            for sid, pair in pairs(slots) do
                -- Addendum F §36: a disabled slot wants nothing (no alerts / wanter rows).
                if type(sid) == "number" and type(pair) == "table" and not (off and off[sid] == true) then
                    local main, alt = tonumber(pair[1]), tonumber(pair[2])
                    if main and main > 0 then AddIndex(main, key, phase, sid, "main", os) end
                    if alt and alt > 0 then AddIndex(alt, key, phase, sid, "alt", os) end
                end
            end
        end
    end
end

local function RebuildIndex()
    index, obSets = {}, {}
    for _, key in ipairs(Store:GetAllKeys()) do
        local rec = Store:Get(key)
        local data = type(rec) == "table" and rec.data
        if type(data) == "table" then
            local ob = {}
            if type(data.ob) == "table" then
                for _, id in ipairs(data.ob) do ob[id] = true end
            end
            obSets[key] = ob
            IndexPhases(key, data.ph, data.dx, nil)
            IndexPhases(key, data.op, data.ox, true)   -- the off-spec list (Addendum H)
        end
    end
    indexDirty = false
end

local function EnsureIndex()
    if indexDirty then RebuildIndex() end
end

local function ArrayHas(t, value)
    if type(t) ~= "table" then return false end
    for i = 1, #t do
        if t[i] == value then return true end
    end
    return false
end

-- How a wanted item relates to the dropped item (nil = the item itself).
local function ViaFor(dropID, wantedID)
    if wantedID == dropID then return nil end
    local D = ns.Data
    if D then
        if D.Tokens and ArrayHas(D.Tokens[dropID], wantedID) then return "token" end
        local ex = D.TokenArenaExchanges and D.TokenArenaExchanges[dropID]
        if type(ex) == "table" and ArrayHas(ex.items, wantedID) then return "arena" end
        if D.Upgrades and D.Upgrades[dropID] == wantedID then return "upgrade" end
    end
    return "token"
end

local function ExpandDrop(itemID)
    local ItemDB = ns.ItemDB
    if ItemDB and ItemDB.ExpandDrop then
        local list = ItemDB:ExpandDrop(itemID)
        if type(list) == "table" and #list > 0 then return list end
    end
    return { itemID }
end

local function IsObtained(key, itemID)
    if Util.IsMe(key) then
        -- Always live for me (bags / bank / equipped): the index's copy of my own ob list is only rebuilt when
        -- other data changes, and my bag scan is a superset of it anyway.
        local BiS = ns.BiS
        if BiS and BiS.IsObtained then return BiS:IsObtained(itemID) and true or false end
    end
    local set = obSets[key]
    return (set and set[itemID]) and true or false
end

local function PhaseSortLess(a, b) return a < b end

-- Chosen phase: the view phase if listed there, else the lowest listed phase >= view phase,
-- else the highest listed phase.
local function ChoosePhase(phases, viewPhase)
    local best
    for _, p in ipairs(phases) do
        if p == viewPhase then return p end
        if p > viewPhase and (not best or p < best) then best = p end
    end
    return best or phases[#phases]
end

local function ClassOf(key, data)
    if type(data) == "table" and type(data.cl) == "string" and data.cl ~= "" then return data.cl end
    return ns.Guild and ns.Guild:GetClass(key) or nil
end

-- Equipped item IDs of the slot group of `sid` (§18: both rings / trinkets / weapons), slot order,
-- non-empty values only.
local function EquippedList(eq, sid)
    local out = {}
    if type(eq) ~= "table" or type(sid) ~= "number" then return out end
    local group = (ns.SLOT_GROUP and ns.SLOT_GROUP[sid]) or { sid }
    for _, s in ipairs(group) do
        local id = tonumber(eq[s])
        if id and id > 0 then out[#out + 1] = id end
    end
    return out
end

-- CDLoot extension (§18): equipped items of a player's slot group, from their synced list
-- (own record for me, demo records in demo mode). Always returns an array (possibly empty).
function Store:GetEquippedList(key, sid)
    local rec = Store:Get(key)
    local data = type(rec) == "table" and rec.data or nil
    return EquippedList(type(data) == "table" and data.eq or nil, tonumber(sid))
end

-- opts: includeObtained, raidOnly, mainOnly, phase (rows of exactly that phase), viewPhase (CDLoot 0.5: the phase
-- whose picks count, instead of my personal view phase; roll tiers pass the group's phase), list (Addendum H:
-- "ms" = main-spec lists only (default), "os" = off-spec lists only, "both" = main spec first, then the off-spec
-- wanters who don't list the item for their main spec).
-- Entries carry cantUse = true when the player's class cannot use the item (class-restricted items, a token or
-- arena exchange of other classes): shown, but never a BiS wanter for rolls. Off-spec entries carry os = true and
-- spec = the off-spec label.
function Store:GetWanters(itemID, opts)
    itemID = tonumber(itemID)
    local out = {}
    if not itemID then return out end
    opts = type(opts) == "table" and opts or {}
    EnsureIndex()

    local Guild, Ledger, ItemDB = ns.Guild, ns.Ledger, ns.ItemDB
    local viewPhase = tonumber(opts.viewPhase)
    if not (viewPhase and viewPhase == floor(viewPhase) and viewPhase >= 1 and viewPhase <= MaxPhase()) then
        viewPhase = Guild and Guild:GetViewPhase() or 1
    end
    local now = GetServerTime()
    local wonCache = {}
    local listMode = opts.list
    if listMode ~= "os" and listMode ~= "both" then listMode = "ms" end

    for _, wanted in ipairs(ExpandDrop(itemID)) do
        local rows = index[wanted]
        if rows then
            -- Group index rows per player and list: which phases list it and the best pick per phase.
            local perKey, order, hasMain = {}, {}, {}
            for _, row in ipairs(rows) do
                if not row.os then hasMain[row.key] = true end
            end
            for _, row in ipairs(rows) do
                local take = (row.os and listMode ~= "ms" and not (listMode == "both" and hasMain[row.key]))
                    or (not row.os and listMode ~= "os")
                if take and (not opts.phase or row.phase == opts.phase) then
                    local gk = row.os and (row.key .. "\001os") or row.key
                    local g = perKey[gk]
                    if not g then
                        g = { phases = {}, best = {}, key = row.key, os = row.os }
                        perKey[gk] = g
                        order[#order + 1] = gk
                    end
                    local cur = g.best[row.phase]
                    if not cur then
                        g.phases[#g.phases + 1] = row.phase
                        g.best[row.phase] = row
                    elseif cur.which ~= "main" and row.which == "main" then
                        g.best[row.phase] = row
                    end
                end
            end

            for _, gk in ipairs(order) do
                local g = perKey[gk]
                local key = g.key
                tsort(g.phases, PhaseSortLess)
                local phase = ChoosePhase(g.phases, viewPhase)
                local row = g.best[phase]
                local rec = Store:Get(key)
                local data = type(rec) == "table" and rec.data or nil
                local obtained = IsObtained(key, wanted)
                local inRaid = Util.IsInMyGroup(key)
                -- An earlier phase's pick of a slot the player disabled for the current phase is superseded:
                -- "not needed" in the current phase (Addendum F §36; later-phase picks still count).
                local superseded = phase < viewPhase and data ~= nil
                    and Store:IsSlotDisabled(data, viewPhase, row.sid, g.os and "os" or nil)
                if not superseded and (opts.includeObtained or not obtained)
                    and (not opts.raidOnly or inRaid)
                    and (not opts.mainOnly or row.which == "main") then
                    local won = wonCache[key]
                    if won == nil then
                        won = (Ledger and Ledger.CountSince) and (tonumber(Ledger:CountSince(key, now - AWARD_WINDOW)) or 0) or 0
                        wonCache[key] = won
                    end
                    local eqTable = data and type(data.eq) == "table" and data.eq or nil
                    local eq = eqTable and eqTable[row.sid] or nil
                    local classFile = ClassOf(key, data)
                    local cantUse = nil
                    if classFile and ItemDB and ItemDB.CanClassUse
                        and (ItemDB:CanClassUse(wanted, classFile) == false
                            or (wanted ~= itemID and ItemDB:CanClassUse(itemID, classFile) == false)) then
                        cantUse = true
                    end
                    local spec = data and data.sp or nil
                    if g.os then
                        spec = (data and type(data.os) == "string" and data.os ~= "") and data.os or nil
                    end
                    out[#out + 1] = {
                        key = key,
                        os = g.os and true or nil,                       -- Addendum H: off-spec list
                        classFile = classFile,
                        spec = spec,
                        wanted = wanted,
                        via = ViaFor(itemID, wanted),
                        phase = phase,
                        phases = g.phases,
                        which = row.which,
                        sid = row.sid,
                        obtained = obtained,
                        awarded = (Ledger and Ledger.HasAward and Ledger:HasAward(key, wanted)) and true or false,
                        inRaid = inRaid,
                        online = (Guild and Guild:IsOnline(key)) and true or false,
                        equipped = eq,
                        equippedList = EquippedList(eqTable, row.sid),   -- §18: whole slot group
                        listTs = rec and rec.ts or nil,
                        wonTonight = won,
                        lockChanged = Store:GetLockFlag(key),            -- Addendum F §38
                        lockNote = Store:GetLockNote(key),               -- (0.5) soft "claims an earlier save"
                        cantUse = cantUse,                               -- (0.5) class cannot use it
                    }
                end
            end
        end
    end

    local shortNames = {}
    local function Short(key)
        local s = shortNames[key]
        if not s then
            s = Util.ShortName(key)
            shortNames[key] = s
        end
        return s
    end
    tsort(out, function(a, b)
        local ao, bo = a.os and true or false, b.os and true or false
        if ao ~= bo then return not ao end   -- main-spec wanters first (Addendum H)
        if a.inRaid ~= b.inRaid then return a.inRaid end
        local av, bv = a.phase == viewPhase, b.phase == viewPhase
        if av ~= bv then return av end
        if a.which ~= b.which then return a.which == "main" end
        if a.obtained ~= b.obtained then return not a.obtained end
        if a.wonTonight ~= b.wonTonight then return a.wonTonight < b.wonTonight end
        local sa, sb = Short(a.key), Short(b.key)
        if sa ~= sb then return sa < sb end
        return tostring(a.wanted) < tostring(b.wanted)
    end)
    return out
end

function Store:CountWanters(itemID, opts)
    return #Store:GetWanters(itemID, opts)
end

-- Counts main picks of one phase: filled, obtained, still needed. Disabled slots (Addendum F §36) are left
-- out of every count: total = slots - disabled, disabled = n. list (Addendum H): "os" = the off-spec list.
function Store:GetPlayerSummary(key, phase, list)
    local summary = { filled = 0, obtained = 0, needed = 0, total = NumSlots(), disabled = 0 }
    local rec = Store:Get(key)
    local data = type(rec) == "table" and rec.data
    if type(data) ~= "table" then return summary end
    data = ns.ListView(data, list)
    local off = type(data.dx) == "table" and data.dx[phase]
    if type(off) ~= "table" then off = nil end
    if off then
        for sid = 1, NumSlots() do
            if off[sid] == true then summary.disabled = summary.disabled + 1 end
        end
        summary.total = NumSlots() - summary.disabled
    end
    local slots = type(data.ph) == "table" and data.ph[phase]
    if type(slots) ~= "table" then return summary end
    EnsureIndex()
    for sid = 1, NumSlots() do
        local pair = slots[sid]
        local main = type(pair) == "table" and tonumber(pair[1]) or nil
        if main and main > 0 and not (off and off[sid] == true) then
            summary.filled = summary.filled + 1
            if IsObtained(key, main) then
                summary.obtained = summary.obtained + 1
            end
        end
    end
    summary.needed = summary.filled - summary.obtained
    return summary
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

local wasCouncil

function Store:OnInit()
    Lists()
    -- The index holds list rows only: awards (the ledger) and my own obtained state are read live in GetWanters,
    -- so LEDGER_UPDATED / OWNED_UPDATED do not rebuild it (a rebuild with 80 lists is ~8 ms and ~3.5 MB garbage).
    ns:On("MYLIST_CHANGED", MarkDirty)
    ns:On("MYLIST_COMMITTED", MarkDirty)
    ns:On("DEMO_TOGGLED", MarkDirty)
    ns:On("LISTS_RESET", MarkDirty)
    ns:On("LIST_UPDATED", MarkDirty)
    ns:On("ROSTER_UPDATED", function(membersChanged)
        -- Online / rank / level flips (membersChanged == false) do not change which lists are indexed.
        if membersChanged ~= false then MarkDirty() end
        PruneFormerMembers()
    end)
    ns:On("CONFIG_UPDATED", function()
        MarkDirty()
        -- Becoming (or ceasing to be) council changes which lists are visible at all.
        local now = ns.Guild and ns.Guild:AmICouncil(true) or false
        if wasCouncil ~= nil and now ~= wasCouncil then
            ns:Fire("LISTS_RESET")
        end
        wasCouncil = now
        SnapshotMissing()   -- became council during a lock
    end)
    -- Addendum F §38: lock snapshots (start / end) and members joining during the lock.
    ns:On("BIS_LOCK_CHANGED", OnLockChanged)
    ns:On("GROUP_UPDATED", SnapshotMissing)
end

-- CDLoot: cached BiS lists of other players (council only), unified record access for the UI
-- (own record from ns.BiS, demo records when Demo is on) and the "who wants item X" index.
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
local PRUNE_AFTER = 30 * 86400  -- drop lists of players missing from the roster this long
local AWARD_WINDOW = 6 * 3600   -- "won tonight"

local index = {}                -- [wantedItemID] = { {key=, phase=, sid=, which=}, ... }
local obSets = {}               -- [key] = { [itemID] = true }
local indexDirty = true

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

function Store:ValidateData(data)
    if type(data) ~= "table" then return false, "data is not a table" end
    if not CheckShape(data, 1, { n = 0 }) then return false, "data too large or malformed" end
    if not IsInt(data.v, 1, 1000) then return false, "bad schema version" end
    if not ValidString(data.cl) then return false, "bad class" end
    if not ValidString(data.sp) then return false, "bad spec" end

    local ph = data.ph
    if ph ~= nil then
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
    end

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
    return true
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
    local accept = (type(cur) ~= "table")
        or r > (tonumber(cur.rev) or 0)
        or (r == cur.rev and h ~= cur.hash and via == "direct")
    if not accept then return false end

    lists[key] = {
        rev = r, ts = ts, hash = h, data = Util.CopyTable(d),
        recvAt = GetServerTime(), via = via,
        g = Guild.GetGuildName and Guild:GetGuildName() or nil,   -- which guild this copy belongs to
    }
    MarkDirty()
    ns:Fire("LIST_UPDATED", key)
    return true
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

local function AddIndex(itemID, key, phase, sid, which)
    local list = index[itemID]
    if not list then
        list = {}
        index[itemID] = list
    end
    list[#list + 1] = { key = key, phase = phase, sid = sid, which = which }
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
            if type(data.ph) == "table" then
                for phase, slots in pairs(data.ph) do
                    if type(phase) == "number" and type(slots) == "table" then
                        for sid, pair in pairs(slots) do
                            if type(sid) == "number" and type(pair) == "table" then
                                local main, alt = tonumber(pair[1]), tonumber(pair[2])
                                if main and main > 0 then AddIndex(main, key, phase, sid, "main") end
                                if alt and alt > 0 then AddIndex(alt, key, phase, sid, "alt") end
                            end
                        end
                    end
                end
            end
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
        local BiS = ns.BiS
        if BiS and BiS.IsObtained and BiS:IsObtained(itemID) then return true end
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

function Store:GetWanters(itemID, opts)
    itemID = tonumber(itemID)
    local out = {}
    if not itemID then return out end
    opts = type(opts) == "table" and opts or {}
    EnsureIndex()

    local Guild, Ledger = ns.Guild, ns.Ledger
    local viewPhase = Guild and Guild:GetViewPhase() or 1
    local now = GetServerTime()
    local wonCache = {}

    for _, wanted in ipairs(ExpandDrop(itemID)) do
        local rows = index[wanted]
        if rows then
            -- Group index rows per player: which phases list it and the best pick per phase.
            local perKey, order = {}, {}
            for _, row in ipairs(rows) do
                if not opts.phase or row.phase == opts.phase then
                    local g = perKey[row.key]
                    if not g then
                        g = { phases = {}, best = {} }
                        perKey[row.key] = g
                        order[#order + 1] = row.key
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

            for _, key in ipairs(order) do
                local g = perKey[key]
                tsort(g.phases, PhaseSortLess)
                local phase = ChoosePhase(g.phases, viewPhase)
                local row = g.best[phase]
                local rec = Store:Get(key)
                local data = type(rec) == "table" and rec.data or nil
                local obtained = IsObtained(key, wanted)
                local inRaid = Util.IsInMyGroup(key)
                if (opts.includeObtained or not obtained)
                    and (not opts.raidOnly or inRaid)
                    and (not opts.mainOnly or row.which == "main") then
                    local won = wonCache[key]
                    if won == nil then
                        won = (Ledger and Ledger.CountSince) and (tonumber(Ledger:CountSince(key, now - AWARD_WINDOW)) or 0) or 0
                        wonCache[key] = won
                    end
                    local eqTable = data and type(data.eq) == "table" and data.eq or nil
                    local eq = eqTable and eqTable[row.sid] or nil
                    out[#out + 1] = {
                        key = key,
                        classFile = ClassOf(key, data),
                        spec = data and data.sp or nil,
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

-- Counts main picks of one phase: filled, obtained, still needed.
function Store:GetPlayerSummary(key, phase)
    local summary = { filled = 0, obtained = 0, needed = 0, total = NumSlots() }
    local rec = Store:Get(key)
    local data = type(rec) == "table" and rec.data
    local slots = type(data) == "table" and type(data.ph) == "table" and data.ph[phase]
    if type(slots) ~= "table" then return summary end
    EnsureIndex()
    for sid = 1, NumSlots() do
        local pair = slots[sid]
        local main = type(pair) == "table" and tonumber(pair[1]) or nil
        if main and main > 0 then
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
    ns:On("MYLIST_CHANGED", MarkDirty)
    ns:On("MYLIST_COMMITTED", MarkDirty)
    ns:On("OWNED_UPDATED", MarkDirty)
    ns:On("LEDGER_UPDATED", MarkDirty)
    ns:On("DEMO_TOGGLED", MarkDirty)
    ns:On("LISTS_RESET", MarkDirty)
    ns:On("LIST_UPDATED", MarkDirty)
    ns:On("ROSTER_UPDATED", function()
        MarkDirty()
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
    end)
end

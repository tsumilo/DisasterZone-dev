-- CDLoot: Core/RaidPlan.lua
-- Raid planning (Addendum J §54-§57): teams, raid events (one-off or weekly), sign-ups and group layouts.
--
-- Organizers (the GM and the guild council) write teams (T), weekly series (S) and events (E: a one-off raid, or an
-- override of one occurrence of a series). Every character writes only its own sign-ups (U). Everything is cached by
-- every guild member and kept per guild in db.raidplan[guildKey].
--
-- Sync (§56): live edits go out on GUILD (RPU, RPS). At login the HELLO carries a hash of my plan data (pd); a client
-- whose data differs answers with its per-item digest (RPD, on GUILD so the others can stay quiet), the new client
-- asks for the items that differ (RPW) and sends its own copy of them; items travel one per message (RPG).
-- Records merge by rev (then by hash), so both sides converge.
local addonName, ns = ...

local RaidPlan = ns:NewModule("RaidPlan")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, ceil, max, min, random = math.floor, math.ceil, math.max, math.min, math.random
local tsort, tconcat = table.sort, table.concat
local strformat = string.format

local DAY = 86400
local WEEK = 7 * DAY
local KEEP_PAST = 14 * DAY          -- occurrences are shown this long after they started
local AHEAD = 14 * DAY              -- weekly occurrences are shown this far ahead (occurrence 0 always)
local PRUNE_AFTER = 15 * DAY        -- occurrences (overrides, sign-ups) older than this are dropped
local TOMBSTONE_DAYS = 30 * DAY     -- deleted teams / series spread for this long, then are dropped
local MAX_AHEAD = 180 * DAY         -- a raid can be planned at most this far ahead
local FUTURE_SLACK = 300            -- a rev more than 5 minutes past the server time is implausible
local SIGNUP_CLOSE = 6 * 3600       -- sign-ups close this long after the raid started

local MAX_TEAMS = 20
local MAX_TEAM_MEMBERS = 40
local MAX_SERIES = 12
local MAX_EVENTS = 60
local MAX_SIGNUPS = 60              -- per occurrence
local MAX_SIGNUP_OCCS = 150         -- occurrences with sign-ups (bounds what a sender can make me store)
local MAX_TEAMS_PER_RAID = 10
local MAX_GROUP_ENTRIES = 40
local MAX_DIGEST_ITEMS = 100
local MAX_RPS_ENTRIES = 30
local MAX_KEY_LEN = 48
local MAX_ID_LEN = 24
local MAX_NAME_LEN = 32             -- team names, raid titles
local MAX_NOTE_LEN = 120            -- raid notes
local MAX_SIGNUP_NOTE = 40

local RPD_DELAY_COUNCIL = { 0.5, 2.5 }
local RPD_DELAY_MEMBER = { 3, 8 }
local ROUND_WINDOW = 20             -- seconds an RPD round for one client lasts (suppression / answer once)

-- §54: the TBC raids (key -> name, default size, instance map id as used by the raid log).
local INSTANCES = {
    { key = "kara",  name = "Karazhan",             size = 10, instID = 532 },
    { key = "gruul", name = "Gruul's Lair",         size = 25, instID = 565 },
    { key = "mag",   name = "Magtheridon's Lair",   size = 25, instID = 544 },
    { key = "ssc",   name = "Serpentshrine Cavern", size = 25, instID = 548 },
    { key = "tk",    name = "Tempest Keep",         size = 25, instID = 550 },
    { key = "hyjal", name = "Mount Hyjal",          size = 25, instID = 534 },
    { key = "bt",    name = "Black Temple",         size = 25, instID = 564 },
    { key = "za",    name = "Zul'Aman",             size = 10, instID = 568 },
    { key = "swp",   name = "Sunwell Plateau",      size = 25, instID = 580 },
    { key = "other", name = "Other",                size = 25 },
}
local INSTANCE_BY_KEY = {}
for _, inst in ipairs(INSTANCES) do INSTANCE_BY_KEY[inst.key] = inst end

local SIZES = { [10] = true, [25] = true }
local STATUSES = { A = true, T = true, B = true, X = true }   -- Accept, Tentative, Bench, Absent

local roundSeen = {}                -- [key] = { h = hash, at = GetTime() }: an RPD to that client was seen
local answeredAt = -1000            -- GetTime() I answered the first RPD of my login round
local idCounter = 0

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function CleanText(s, maxLen)
    if type(s) ~= "string" then return nil end
    s = Util.Trim(s)
    if s == "" or #s > maxLen or s:find("[%c|]") then return nil end
    return s
end

-- A name from the network or the UI -> name key, or nil.
local function WireKey(s)
    if type(s) ~= "string" or s == "" or #s > MAX_KEY_LEN or s:find("[%c|]") then return nil end
    return Util.NormalizeName(s)
end

local function IsId(s)
    return type(s) == "string" and #s <= MAX_ID_LEN and s:find("^%w+$") ~= nil
end

-- "<sid>#<k>" -> sid, k (or nil for a one-off event id).
local function SplitOcc(occId)
    if type(occId) ~= "string" then return nil end
    local sid, k = occId:match("^(%w+)#(%d+)$")
    if sid and #sid <= MAX_ID_LEN and #k <= 4 then return sid, tonumber(k) end
    return nil
end

local function IsOccId(s)
    return IsId(s) or SplitOcc(s) ~= nil
end

local function OccId(sid, k)
    return sid .. "#" .. k
end

local function Guild() return ns.Guild end

local function GuildKey()
    local G = Guild()
    return G and G.GetGuildKey and G:GetGuildKey() or nil
end

local function IsOrganizer(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsGuildCouncil ~= nil and G:IsGuildCouncil(key) and true or false
end

local function Send(msg, dist, target, class)
    local Comm = ns.Comm
    return (Comm and Comm.Send and Comm:Send(msg, dist, target, class)) and true or false
end

local function RateLimit(key, seconds)
    local Comm = ns.Comm
    if not (Comm and Comm.RateLimit) then return true end
    return Comm:RateLimit(key, seconds)
end

local function MyClass()
    local _, classFile = UnitClass("player")
    return classFile
end

local function SpecCount(classFile)
    local specs = type(classFile) == "string" and ns.SPECS and ns.SPECS[classFile]
    return specs and #specs or 0
end

-- db.raidplan[guildKey] (created on demand), or nil while the guild is unknown.
local function Root(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.raidplan) ~= "table" then
        if not create then return nil end
        db.raidplan = {}
    end
    local r = db.raidplan[g]
    if type(r) ~= "table" then
        if not create then return nil end
        r = {}
        db.raidplan[g] = r
    end
    for _, k in ipairs({ "T", "S", "E", "U" }) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    return r
end

local function Changed()
    ns:Fire("RAIDPLAN_CHANGED")
end

local function NextRev(cur)
    local prev = type(cur) == "table" and tonumber(cur.rev) or 0
    return max(Now(), prev + 1)
end

local function NewId()
    idCounter = idCounter + 1
    local now = Now()
    return strformat("%x", now) .. Util.Hash({ Util.PlayerKey() or "", now, idCounter, GetTime() }):sub(1, 4)
end

local function CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Series occurrence k: the same local wall-clock time k weeks after the first one (a DST change keeps "20:00").
local function SeriesTime(s, k)
    if k == 0 then return s.t end
    local d = date("*t", s.t)
    if type(d) ~= "table" then return s.t + k * WEEK end
    d.day = d.day + 7 * k
    d.isdst = nil
    local t = time(d)
    return type(t) == "number" and t or (s.t + k * WEEK)
end

-- The week index of the series occurrence at or before `ts` (can be negative).
local function SeriesWeekAt(s, ts)
    return floor((ts - s.t) / WEEK)
end

---------------------------------------------------------------------------
-- Validation (untrusted records -> clean copies)
---------------------------------------------------------------------------

local function CleanTeamIds(tm)
    if tm == nil then return nil end
    if type(tm) ~= "table" then return false end
    local out, seen = {}, {}
    for i = 1, MAX_TEAMS_PER_RAID + 1 do
        local id = tm[i]
        if id == nil then break end
        if i > MAX_TEAMS_PER_RAID or not IsId(id) then return false end
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    return out
end

local function CleanGroups(grp)
    if grp == nil then return nil end
    if type(grp) ~= "table" then return false end
    local out, n = {}, 0
    for key, g in pairs(grp) do
        n = n + 1
        if n > MAX_GROUP_ENTRIES then return false end
        local k = WireKey(key)
        if not k or not IsInt(g, 1, 8) then return false end
        out[k] = g
    end
    return out
end

local function CleanCommon(r, now)
    if type(r) ~= "table" or not IsInt(r.rev, 1, now + FUTURE_SLACK) then return nil end
    local by = WireKey(r.by)
    if not by then return nil end
    return { rev = r.rev, by = by }
end

local function CleanTeam(r, now)
    local out = CleanCommon(r, now)
    if not out or not IsId(r.id) then return nil end
    out.id = r.id
    if r.del == true then
        out.del = true
        out.m = {}
        return out
    end
    out.n = CleanText(r.n, MAX_NAME_LEN)
    if not out.n or type(r.m) ~= "table" then return nil end
    local set = {}
    for i = 1, MAX_TEAM_MEMBERS + 1 do
        local v = r.m[i]
        if v == nil then break end
        if i > MAX_TEAM_MEMBERS then return nil end
        local k = WireKey(v)
        if not k then return nil end
        set[k] = true
    end
    out.m = {}
    for k in pairs(set) do out.m[#out.m + 1] = k end
    tsort(out.m)
    -- §59: the team's size, the spec each member plays in it and its group layout (members only)
    if r.sz ~= nil then
        if not SIZES[r.sz] then return nil end
        out.sz = r.sz
    end
    if r.s ~= nil then
        if type(r.s) ~= "table" then return nil end
        for key, sp in pairs(r.s) do
            local k = WireKey(key)
            if not k or not IsInt(sp, 1, 4) then return nil end
            if set[k] then
                out.s = out.s or {}
                out.s[k] = sp
            end
        end
    end
    local grp = CleanGroups(r.grp)
    if grp == false then return nil end
    if grp then
        for k, g in pairs(grp) do
            if set[k] then
                out.grp = out.grp or {}
                out.grp[k] = g
            end
        end
    end
    return out
end

-- The raid fields shared by series and events. `partial` = an override (every field optional). A series' t is its
-- first occurrence, which can be long ago (minT).
local function CleanRaidFields(out, r, now, partial, minT)
    if r.t ~= nil or not partial then
        if not IsInt(r.t, minT or (now - 60 * DAY), now + MAX_AHEAD + WEEK) then return false end
        out.t = r.t
    end
    if r.i ~= nil or not partial then
        if not INSTANCE_BY_KEY[r.i] then return false end
        out.i = r.i
    end
    if r.sz ~= nil or not partial then
        if not SIZES[r.sz] then return false end
        out.sz = r.sz
    end
    local tm = CleanTeamIds(r.tm)
    if tm == false then return false end
    out.tm = tm
    if r.ti ~= nil then
        out.ti = CleanText(r.ti, MAX_NAME_LEN)
        if not out.ti then return false end
    end
    if r.no ~= nil then
        out.no = CleanText(r.no, MAX_NOTE_LEN)
        if not out.no then return false end
    end
    return true
end

local function CleanSeries(r, now)
    local out = CleanCommon(r, now)
    if not out or not IsId(r.id) then return nil end
    out.id = r.id
    if r.x == true then out.x = true end
    if not CleanRaidFields(out, r, now, false, 1000000000) then return nil end
    if r.u ~= nil then
        if not IsInt(r.u, 0, 9999) then return nil end
        out.u = r.u
    end
    return out
end

local function CleanEvent(r, now)
    local out = CleanCommon(r, now)
    if not out or not IsOccId(r.id) then return nil end
    out.id = r.id
    local sid, k = SplitOcc(r.id)
    if sid then
        if r.sid ~= sid or r.k ~= k then return nil end
        out.sid, out.k = sid, k
    elseif r.sid ~= nil or r.k ~= nil then
        return nil
    end
    if r.del == true then          -- deleted: a tombstone that spreads the deletion (§54)
        out.del = true
        return out
    end
    if r.x == true then out.x = true end
    if not CleanRaidFields(out, r, now, sid ~= nil) then return nil end
    local grp = CleanGroups(r.grp)
    if grp == false then return nil end
    out.grp = grp
    return out
end

local function CleanSignup(s, now)
    if type(s) ~= "table" or not STATUSES[s.st] or not IsInt(s.rev, 1, now + FUTURE_SLACK) then return nil end
    local out = { st = s.st, rev = s.rev }
    if type(s.c) == "string" and ns.SPECS and ns.SPECS[s.c] then
        out.c = s.c
        if s.sp ~= nil then
            if not IsInt(s.sp, 1, SpecCount(s.c)) then return nil end
            out.sp = s.sp
        end
    elseif s.c ~= nil or s.sp ~= nil then
        return nil
    end
    if s.n ~= nil then
        out.n = CleanText(s.n, MAX_SIGNUP_NOTE)
        if not out.n then return nil end
    end
    -- when the character first answered this raid (kept when the answer changes; the sign-up order)
    if s.at ~= nil then
        if not IsInt(s.at, 1, s.rev) then return nil end
        out.at = s.at
    end
    return out
end

---------------------------------------------------------------------------
-- Merge
---------------------------------------------------------------------------

-- Higher rev wins; the same rev settles on the larger hash (every client picks the same one).
local function Newer(a, b)
    if not b then return true end
    if a.rev ~= b.rev then return a.rev > b.rev end
    return Util.Hash(a) > Util.Hash(b)
end

local KIND_CAP = { T = MAX_TEAMS, S = MAX_SERIES, E = MAX_EVENTS }

-- Stores a clean record of kind T / S / E. Returns true when stored.
local function MergeRecord(root, kind, rec)
    local store = root[kind]
    local cur = store[rec.id]
    if cur then
        if not Newer(rec, cur) then return false end
    elseif CountTable(store) >= KIND_CAP[kind] then
        ns:Debug("RaidPlan: %s store full, %s dropped", kind, rec.id)
        return false
    end
    store[rec.id] = rec
    if kind == "E" and rec.del then root.U[rec.id] = nil end   -- a deleted raid takes its sign-ups with it
    return true
end

local function MergeSignup(root, occId, key, s)
    local e = root.E[occId]
    if e and e.del then return false end
    local occ = root.U[occId]
    if not occ then
        if CountTable(root.U) >= MAX_SIGNUP_OCCS then return false end
        occ = {}
        root.U[occId] = occ
    end
    local cur = occ[key]
    if cur then
        if not Newer(s, cur) then return false end
    elseif CountTable(occ) >= MAX_SIGNUPS then
        return false
    end
    occ[key] = s
    return true
end

---------------------------------------------------------------------------
-- Occurrences (the resolved view the UI reads)
---------------------------------------------------------------------------

local RAID_FIELDS = { "t", "i", "sz", "tm", "ti", "no" }

local function CopyList(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for i, v in ipairs(t) do out[i] = v end
    return out
end

local function CopyMap(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

-- The view of a visible one-off event.
local function ViewEvent(e)
    return {
        id = e.id, t = e.t, i = e.i, sz = e.sz, tm = CopyList(e.tm) or {}, ti = e.ti, no = e.no,
        cancelled = e.x and true or false, grp = CopyMap(e.grp), by = e.by, rev = e.rev, weekly = false,
    }
end

-- The view of series occurrence k (nil when the series doesn't have it).
local function ViewOccurrence(root, s, k)
    if s.x or k < 0 or (s.u and k > s.u) then return nil end
    local occId = OccId(s.id, k)
    local o = root.E[occId]
    if o and not IsOrganizer(o.by) then o = nil end
    if o and o.del then return nil end
    local v = {
        id = occId, sid = s.id, k = k, by = s.by, rev = s.rev, weekly = true, cancelled = false, lastWeek = s.u,
    }
    for _, f in ipairs(RAID_FIELDS) do
        local val = (o and o[f] ~= nil) and o[f] or s[f]
        if f == "t" and not (o and o.t) then val = SeriesTime(s, k) end
        v[f] = type(val) == "table" and CopyList(val) or val
    end
    v.tm = v.tm or {}
    if o then
        v.cancelled = o.x and true or false
        v.grp = CopyMap(o.grp)
        v.override = true
    end
    return v
end

local function ResolveOcc(root, occId)
    if not root or type(occId) ~= "string" then return nil end
    local sid, k = SplitOcc(occId)
    if sid then
        local s = root.S[sid]
        if not s or not IsOrganizer(s.by) then return nil end
        return ViewOccurrence(root, s, k)
    end
    local e = root.E[occId]
    if not e or e.sid or e.del or not IsOrganizer(e.by) then return nil end
    return ViewEvent(e)
end

-- The start time of an occurrence from the stored data, visible or not (for pruning). nil = unknown.
local function OccTime(root, occId)
    local sid, k = SplitOcc(occId)
    local e = root.E[occId]
    if e and e.t then return e.t end
    if sid then
        local s = root.S[sid]
        return s and SeriesTime(s, k) or nil
    end
    return nil
end

---------------------------------------------------------------------------
-- Digest (§56)
---------------------------------------------------------------------------

local function ItemHash(root, item)
    local kind, id = item:match("^(%u):(.+)$")
    if kind == "T" or kind == "S" then
        local rec = root[kind][id]
        return rec and Util.Hash(rec):sub(1, 6) or nil
    elseif kind == "O" then
        local e, u = root.E[id], root.U[id]
        if not e and not (u and next(u)) then return nil end
        return Util.Hash({ e = e or false, u = u or {} }):sub(1, 6)
    end
    return nil
end

-- { [item] = short hash } of everything I hold for my guild (at most MAX_DIGEST_ITEMS).
function RaidPlan:GetDigest()
    local out = {}
    local root = Root(false)
    if not root then return out end
    local items = {}
    for id in pairs(root.T) do items[#items + 1] = "T:" .. id end
    for id in pairs(root.S) do items[#items + 1] = "S:" .. id end
    local occ = {}
    for id in pairs(root.E) do occ[id] = true end
    for id, u in pairs(root.U) do
        if next(u) then occ[id] = true end
    end
    for id in pairs(occ) do items[#items + 1] = "O:" .. id end
    tsort(items)
    local n = 0
    for _, item in ipairs(items) do
        local h = ItemHash(root, item)
        if h then
            n = n + 1
            if n > MAX_DIGEST_ITEMS then break end
            out[item] = h
        end
    end
    return out
end

-- One hash over the digest ("0" = I hold nothing). Sent in the HELLO as pd.
function RaidPlan:GetDigestHash()
    local d = self:GetDigest()
    local list = {}
    for item, h in pairs(d) do list[#list + 1] = item .. "=" .. h end
    if #list == 0 then return "0" end
    tsort(list)
    return Util.Hash(list)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function Broadcast(kind, rec)
    Send({ t = "RPU", k = kind, r = rec }, "GUILD", nil, "data")
end

local function BroadcastSignups(list)
    if #list == 0 then return end
    for i = 1, #list, MAX_RPS_ENTRIES do
        local chunk = {}
        for j = i, min(#list, i + MAX_RPS_ENTRIES - 1) do chunk[#chunk + 1] = list[j] end
        Send({ t = "RPS", l = chunk }, "GUILD", nil, "ctrl")
    end
end

-- One digest item to `target` (RPG, whisper).
local function SendItem(root, item, target)
    local kind, id = item:match("^(%u):(.+)$")
    local msg
    if kind == "T" and root.T[id] then
        msg = { t = "RPG", T = root.T[id] }
    elseif kind == "S" and root.S[id] then
        msg = { t = "RPG", S = root.S[id] }
    elseif kind == "O" and IsOccId(id) and (root.E[id] or root.U[id]) then
        msg = { t = "RPG", o = id, e = root.E[id], u = root.U[id] }
    end
    if msg then Send(msg, "WHISPER", target, "data") end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local function StoreRecord(kind, r)
    local root = Root(true)
    if not root then return false end
    local now = Now()
    local rec
    if kind == "T" then rec = CleanTeam(r, now)
    elseif kind == "S" then rec = CleanSeries(r, now)
    elseif kind == "E" then rec = CleanEvent(r, now)
    end
    if not rec then return false end
    return MergeRecord(root, kind, rec)
end

-- RPU { k, r }: an organizer's live edit (the editor must be the sender).
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if not (msg.k == "T" or msg.k == "S" or msg.k == "E") then return end
    if StoreRecord(msg.k, msg.r) then Changed() end
end

-- RPS { l = { { o = occId, s = signup }, ... } }: the sender's own sign-ups.
local function OnSignups(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.l) ~= "table" then return end
    local root = Root(true)
    if not root then return end
    local now, changed = Now(), false
    for i = 1, MAX_RPS_ENTRIES do
        local e = msg.l[i]
        if e == nil then break end
        if type(e) == "table" and IsOccId(e.o) then
            local s = CleanSignup(e.s, now)
            if s and MergeSignup(root, e.o, sender, s) then changed = true end
        end
    end
    if changed then Changed() end
end

-- RPG: one item (a team, a series, or an occurrence's override + sign-ups), relayed by anyone in the guild.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    local changed = false
    if msg.T ~= nil then
        changed = StoreRecord("T", msg.T)
    elseif msg.S ~= nil then
        changed = StoreRecord("S", msg.S)
    elseif IsOccId(msg.o) then
        local root = Root(true)
        if not root then return end
        local now = Now()
        if msg.e ~= nil then
            local e = CleanEvent(msg.e, now)
            if e and e.id == msg.o and MergeRecord(root, "E", e) then changed = true end
        end
        if type(msg.u) == "table" then
            local n = 0
            for key, s in pairs(msg.u) do
                n = n + 1
                if n > MAX_SIGNUPS then break end
                local k = WireKey(key)
                local c = k and CleanSignup(s, now)
                if c and MergeSignup(root, msg.o, k, c) then changed = true end
            end
        end
    end
    if changed then Changed() end
end

-- RPW { w = { item, ... } }: the items a client wants from me.
local function OnWant(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg.w) ~= "table" or not RateLimit("RPW:" .. sender, 5) then return end
    local root = Root(false)
    if not root then return end
    for i = 1, MAX_DIGEST_ITEMS do
        local item = msg.w[i]
        if item == nil then break end
        if type(item) == "string" and #item <= MAX_ID_LEN + 8 then SendItem(root, item, sender) end
    end
end

local function CleanDigest(d)
    if type(d) ~= "table" then return nil end
    local out, n = {}, 0
    for item, h in pairs(d) do
        n = n + 1
        if n > MAX_DIGEST_ITEMS then return nil end
        if type(item) ~= "string" or #item > MAX_ID_LEN + 8 or not item:find("^[TSO]:") then return nil end
        if type(h) ~= "string" or #h > 8 then return nil end
        out[item] = h
    end
    return out
end

-- RPD { to, h, d }: an answer to someone's HELLO. Mine: sync with the responder. Someone else's: remember it, so I
-- don't answer the same round with the same data.
local function OnDigest(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if not to then return end
    if not Util.IsMe(to) then
        if type(msg.h) == "string" then roundSeen[to] = { h = msg.h, at = GetTime() } end
        return
    end
    if GetTime() - answeredAt < ROUND_WINDOW then return end
    local theirs = CleanDigest(msg.d)
    if not theirs then return end
    answeredAt = GetTime()
    local root = Root(true)
    if not root then return end
    local mine = RaidPlan:GetDigest()
    local want, give = {}, {}
    for item, h in pairs(theirs) do
        if mine[item] ~= h then want[#want + 1] = item end
    end
    for item, h in pairs(mine) do
        if theirs[item] ~= h then give[#give + 1] = item end
    end
    tsort(want)
    tsort(give)
    if #want > 0 then Send({ t = "RPW", w = want }, "WHISPER", sender, "ctrl") end
    for _, item in ipairs(give) do SendItem(root, item, sender) end
end

-- Sync calls this for every HELLO on GUILD (pd = the sender's plan hash; nil from clients before 0.7).
function RaidPlan:OnHelloDigest(sender, pd)
    if type(pd) ~= "string" or #pd > 8 or type(sender) ~= "string" then return end
    local mine = self:GetDigestHash()
    if mine == "0" or pd == mine then return end
    if not RateLimit("RPDh:" .. sender, ROUND_WINDOW) then return end
    local G = Guild()
    local delay = (G and G.IsGuildCouncil and G:IsGuildCouncil(Util.PlayerKey())) and RPD_DELAY_COUNCIL or RPD_DELAY_MEMBER
    Util.RandomDelay(delay[1], delay[2], function()
        local h = RaidPlan:GetDigestHash()
        local seen = roundSeen[sender]
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW and seen.h == h) then return end
        roundSeen[sender] = { h = h, at = GetTime() }
        Send({ t = "RPD", to = sender, h = h, d = RaidPlan:GetDigest() }, "GUILD", nil, "data")
    end)
end

---------------------------------------------------------------------------
-- Public API: reading
---------------------------------------------------------------------------

function RaidPlan:GetInstances()
    return INSTANCES
end

function RaidPlan:GetInstance(key)
    return INSTANCE_BY_KEY[key]
end

-- The display name of a raid view (its title, else the instance name).
function RaidPlan:GetRaidName(v)
    if type(v) ~= "table" then return "?" end
    if v.ti then return v.ti end
    local inst = INSTANCE_BY_KEY[v.i]
    return inst and inst.name or "?"
end

function RaidPlan:IsOrganizer(key)
    return IsOrganizer(key)
end

function RaidPlan:CanOrganize()
    return IsOrganizer(Util.PlayerKey())
end

-- Visible teams, sorted by name: { id, name, members = { key, ... }, by, rev }.
function RaidPlan:GetTeams()
    local out = {}
    local root = Root(false)
    if not root then return out end
    for id, t in pairs(root.T) do
        if not t.del and IsOrganizer(t.by) then out[#out + 1] = RaidPlan:GetTeam(id) end
    end
    tsort(out, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return out
end

function RaidPlan:GetTeam(id)
    local root = Root(false)
    local t = root and type(id) == "string" and root.T[id]
    if not t or t.del or not IsOrganizer(t.by) then return nil end
    return { id = t.id, name = t.n, members = CopyList(t.m) or {}, by = t.by, rev = t.rev, size = t.sz or 25,
             specs = CopyMap(t.s) or {}, groups = CopyMap(t.grp) or {} }
end

-- The spec a member plays (§59): the team's pick, else their latest sign-up's, else their BiS list's (mine, or a
-- list the council has cached). Returns spec index, classFile, source ("team" | "signup" | "bis") or nil.
function RaidPlan:GetMemberSpec(key, team)
    local G = Guild()
    local classFile = G and G.GetClass and G:GetClass(key) or nil
    if Util.IsMe(key) then classFile = MyClass() end
    if type(team) == "table" and team.specs and team.specs[key] then
        return team.specs[key], classFile, "team"
    end
    local root = Root(false)
    local best
    if root then
        for _, u in pairs(root.U) do
            local s = u[key]
            if s and s.sp and s.c and (not best or s.rev > best.rev) then best = s end
        end
    end
    if best then return best.sp, best.c, "signup" end
    local label
    if Util.IsMe(key) then
        local BiS = ns.BiS
        label = BiS and BiS.GetSpec and BiS:GetSpec() or nil
    else
        local Store = ns.Store
        local rec = Store and Store.GetCached and Store:GetCached(key)
        local data = type(rec) == "table" and type(rec.data) == "table" and rec.data or nil
        label = data and data.sp or nil
        if data and type(data.cl) == "string" then classFile = classFile or data.cl end
    end
    for i, spec in ipairs(classFile and ns.SPECS[classFile] or {}) do
        if spec.label == label then return i, classFile, "bis" end
    end
    return nil, classFile, nil
end

-- Visible raids (occurrences) starting in [from, to] (default: 14 days back .. 180 days ahead; weekly raids only up
-- to 14 days ahead, their first occurrence always), sorted by start time. Cancelled ones are included (cancelled).
function RaidPlan:GetRaids(from, to)
    local out = {}
    local root = Root(false)
    if not root then return out end
    local now = Now()
    from = tonumber(from) or (now - KEEP_PAST)
    to = tonumber(to) or (now + MAX_AHEAD)
    for _, e in pairs(root.E) do
        if not e.sid and not e.del and IsOrganizer(e.by) and e.t >= from and e.t <= to then
            out[#out + 1] = ViewEvent(e)
        end
    end
    for _, s in pairs(root.S) do
        if not s.x and IsOrganizer(s.by) then
            local last = max(0, SeriesWeekAt(s, min(to, now + AHEAD)))
            if s.u then last = min(last, s.u) end
            for k = max(0, SeriesWeekAt(s, from) - 1), last + 1 do
                local v = ViewOccurrence(root, s, k)
                if v and v.t >= from and v.t <= to and (k <= last or v.t <= now + AHEAD) then
                    out[#out + 1] = v
                end
            end
        end
    end
    tsort(out, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.id < b.id
    end)
    return out
end

function RaidPlan:GetRaid(occId)
    return ResolveOcc(Root(false), occId)
end

-- { [key] = { st, sp, c, n, rev } } (copies).
function RaidPlan:GetSignups(occId)
    local out = {}
    local root = Root(false)
    local u = root and type(occId) == "string" and root.U[occId]
    if type(u) == "table" then
        for key, s in pairs(u) do out[key] = CopyMap(s) end
    end
    return out
end

function RaidPlan:GetMySignup(occId)
    local me = Util.PlayerKey()
    local root = Root(false)
    local u = root and me and type(occId) == "string" and root.U[occId]
    local s = type(u) == "table" and u[me]
    return s and CopyMap(s) or nil
end

-- The sign-up order of a raid: { [key] = position (1 = first) }, total. Ordered by the first answer (any status), so
-- changing an answer keeps the place; the same second settles by name.
function RaidPlan:GetSignupOrder(occId)
    local list = {}
    for key, s in pairs(self:GetSignups(occId)) do list[#list + 1] = { key = key, at = s.at or s.rev or 0 } end
    tsort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.key < b.key
    end)
    local out = {}
    for i, e in ipairs(list) do out[e.key] = i end
    return out, #list
end

-- The set of invited members { [key] = true } (the union of the raid's visible teams), or nil when the raid names
-- no team (open to everyone).
function RaidPlan:GetInvited(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v or not v.tm or #v.tm == 0 then return nil end
    local set = {}
    for _, id in ipairs(v.tm) do
        local t = self:GetTeam(id)
        if t then
            for _, key in ipairs(t.members) do set[key] = true end
        end
    end
    return set
end

-- §60: the raid's group layout members: everyone who answered Accept, Tentative or Bench (Absent is left out), plus
-- anyone placed in the saved layout without such an answer. { key, c, sp, st = "A"|"T"|"B"|nil }, sorted by key.
function RaidPlan:GetLayoutMembers(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    local out = {}
    if not v then return out end
    local signups = self:GetSignups(v.id)
    local seen = {}
    for key, s in pairs(signups) do
        if s.st ~= "X" then
            local sp, c = s.sp, s.c
            if not sp then sp, c = self:GetMemberSpec(key) end
            out[#out + 1] = { key = key, c = c or s.c, sp = sp, st = s.st }
            seen[key] = true
        end
    end
    for key in pairs(v.grp or {}) do
        if not seen[key] and not (signups[key] and signups[key].st == "X") then
            local sp, c = self:GetMemberSpec(key)
            out[#out + 1] = { key = key, c = c, sp = sp }
        end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

-- §60: the starting layout of a raid that has no saved one: its teams' layouts, adjusted to who accepted.
--  1. accepted team members keep their seat (first team first);
--  2. a seat whose team member didn't accept is open for an accepted player of the same role;
--  3. other accepted players join a group of their role with room; Tentative / Bench and whoever doesn't fit stay out.
-- Without any team layout the whole raid is Auto-filled (accepted players only). Returns { [key] = group }.
function RaidPlan:BuildLayout(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return {} end
    local Comp = ns.RaidComp
    local nGroups = Comp:GroupCount(v.sz)
    local size = Comp.GROUP_SIZE
    local accepted = {}
    for _, m in ipairs(self:GetLayoutMembers(v)) do
        if m.st == "A" then accepted[#accepted + 1] = m end
    end
    local teams = {}
    for _, id in ipairs(v.tm or {}) do
        local t = self:GetTeam(id)
        if t and next(t.groups) then teams[#teams + 1] = t end
    end
    if #teams == 0 then return Comp:AutoFill(accepted, v.sz) end

    local grp, count, byKey = {}, {}, {}
    for g = 1, nGroups do count[g] = 0 end
    for _, m in ipairs(accepted) do byKey[m.key] = m end
    local open = {}     -- { g, role } seats of team members who didn't accept
    for _, t in ipairs(teams) do
        local keys = {}
        for key in pairs(t.groups) do keys[#keys + 1] = key end
        tsort(keys)
        for _, key in ipairs(keys) do
            local g = t.groups[key]
            if g <= nGroups and grp[key] == nil then
                if byKey[key] then
                    if count[g] < size then
                        grp[key] = g
                        count[g] = count[g] + 1
                    end
                else
                    local sp, c = self:GetMemberSpec(key, t)
                    open[#open + 1] = { g = g, role = Comp:RoleOf(c, sp) }
                end
            end
        end
    end
    -- groups' roles, for players who find no open seat of their role
    local function groupRole(g)
        local n = {}
        local bestRole, bestN = nil, 0
        for key, x in pairs(grp) do
            if x == g then
                local m = byKey[key]
                local r = m and Comp:RoleOf(m.c, m.sp)
                if r then
                    n[r] = (n[r] or 0) + 1
                    if n[r] > bestN then bestRole, bestN = r, n[r] end
                end
            end
        end
        return bestRole
    end
    local rest = {}
    for _, m in ipairs(accepted) do
        if grp[m.key] == nil then rest[#rest + 1] = m end
    end
    for _, m in ipairs(rest) do
        local role = Comp:RoleOf(m.c, m.sp)
        local placed = false
        for i, seat in ipairs(open) do
            if seat.role == role and count[seat.g] < size then
                grp[m.key] = seat.g
                count[seat.g] = count[seat.g] + 1
                table.remove(open, i)
                placed = true
                break
            end
        end
        if not placed and role then
            local pick
            for g = 1, nGroups do
                if count[g] < size and groupRole(g) == role and (not pick or count[g] < count[pick]) then pick = g end
            end
            if pick then
                grp[m.key] = pick
                count[pick] = count[pick] + 1
            end
        end
    end
    return grp
end

-- The layout to use for a raid: the saved one (the organizers' edits), else the starting layout. Second return:
-- true when saved.
function RaidPlan:GetLayout(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return {}, false end
    if v.grp and next(v.grp) then return CopyMap(v.grp), true end
    return self:BuildLayout(v), false
end

-- Raids in the next `days` days (default 7) I am invited to (by a team) and haven't answered, soonest first.
function RaidPlan:GetUnanswered(days)
    local me = Util.PlayerKey()
    local out = {}
    if not me then return out end
    local now = Now()
    for _, v in ipairs(self:GetRaids(now, now + (tonumber(days) or 7) * DAY)) do
        if not v.cancelled then
            local inv = self:GetInvited(v)
            if inv and inv[me] and not self:GetMySignup(v.id) then out[#out + 1] = v end
        end
    end
    return out
end

-- The spec index this character used last (nil = none yet).
function RaidPlan:GetLastSpec()
    local db, me = ns.db, Util.PlayerKey()
    local t = db and me and type(db.raidplanSpec) == "table" and db.raidplanSpec[me]
    return IsInt(t, 1, SpecCount(MyClass())) and t or nil
end

---------------------------------------------------------------------------
-- Public API: writing (organizers)
---------------------------------------------------------------------------

local function RequireOrganizer()
    if not IsOrganizer(Util.PlayerKey()) then return nil, "Only the Guild Master and the guild council can plan raids." end
    local root = Root(true)
    if not root then return nil, "Your guild is not known yet; try again in a moment." end
    return root
end

-- Stores my own record (already built) after validating it, and shares it. Returns ok, err.
local function Commit(root, kind, rec)
    local clean
    local now = Now()
    if kind == "T" then clean = CleanTeam(rec, now)
    elseif kind == "S" then clean = CleanSeries(rec, now)
    else clean = CleanEvent(rec, now)
    end
    if not clean then return false, "invalid raid data" end
    if not root[kind][clean.id] and CountTable(root[kind]) >= KIND_CAP[kind] then
        return false, "too many " .. (kind == "T" and "teams" or "raids") .. " planned"
    end
    root[kind][clean.id] = clean
    if kind == "E" and clean.del then root.U[clean.id] = nil end
    Broadcast(kind, clean)
    Changed()
    return true
end

-- members: a set { [key] = true } or an array of keys. id = nil creates a team. opts (optional): { size = 10|25,
-- specs = { [key] = spec index }, groups = { [key] = 1..8 } } (nil keeps the team's current ones). Returns ok, idOrErr.
function RaidPlan:SaveTeam(id, name, members, opts)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    name = CleanText(name, MAX_NAME_LEN)
    if not name then return false, "Team names are 1-32 characters." end
    local list = {}
    if type(members) == "table" then
        for k, v in pairs(members) do
            local key = type(k) == "string" and v and k or (type(v) == "string" and v) or nil
            key = key and WireKey(key)
            if key then list[#list + 1] = key end
        end
    end
    if #list > MAX_TEAM_MEMBERS then return false, "A team holds at most " .. MAX_TEAM_MEMBERS .. " members." end
    local cur = id and root.T[id]
    if id and not cur then return false, "unknown team" end
    id = id or NewId()
    opts = type(opts) == "table" and opts or {}
    local rec = { id = id, rev = NextRev(cur), by = Util.PlayerKey(), n = name, m = list }
    rec.sz = opts.size or (cur and cur.sz) or nil
    rec.s = opts.specs or (cur and cur.s) or nil
    rec.grp = opts.groups or (cur and cur.grp) or nil
    if rec.sz ~= nil and not SIZES[rec.sz] then return false, "Team size must be 10 or 25." end
    if rec.s and not next(rec.s) then rec.s = nil end
    if rec.grp and not next(rec.grp) then rec.grp = nil end
    local ok, e = Commit(root, "T", rec)
    if not ok then return false, e end
    return true, id
end

function RaidPlan:DeleteTeam(id)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local cur = type(id) == "string" and root.T[id]
    if not cur or cur.del then return false, "unknown team" end
    return Commit(root, "T", { id = id, rev = NextRev(cur), by = Util.PlayerKey(), del = true })
end

-- Copies the raid fields of `f` (UI input) onto rec; `partial` keeps missing ones. Returns ok, err.
local function ApplyFields(rec, f, partial)
    if f.i ~= nil or not partial then
        if not INSTANCE_BY_KEY[f.i] then return false, "Pick a raid." end
        rec.i = f.i
        if f.sz == nil and not partial then rec.sz = INSTANCE_BY_KEY[f.i].size end
    end
    if f.sz ~= nil then
        if not SIZES[f.sz] then return false, "Raid size must be 10 or 25." end
        rec.sz = f.sz
    end
    if f.t ~= nil or not partial then
        if not IsInt(f.t, 0, Now() + MAX_AHEAD) then return false, "Pick a date at most 180 days ahead." end
        rec.t = f.t
    end
    if f.tm ~= nil then
        local tm = CleanTeamIds(f.tm)
        if tm == false then return false, "invalid team list" end
        rec.tm = tm
    end
    if f.ti ~= nil then
        if f.ti == false or Util.Trim(tostring(f.ti)) == "" then rec.ti = nil
        else
            rec.ti = CleanText(f.ti, MAX_NAME_LEN)
            if not rec.ti then return false, "Titles are at most 32 characters." end
        end
    end
    if f.no ~= nil then
        if f.no == false or Util.Trim(tostring(f.no)) == "" then rec.no = nil
        else
            rec.no = CleanText(f.no, MAX_NOTE_LEN)
            if not rec.no then return false, "Notes are at most 120 characters on one line." end
        end
    end
    return true
end

-- fields: { i = instance key, t = start (server time), sz = 10|25 (default: the instance's), tm = { teamId },
-- ti = title, no = note, weekly = bool }. Returns ok, occIdOrErr.
function RaidPlan:CreateRaid(f)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    if type(f) ~= "table" then return false, "invalid raid" end
    if IsInt(f.t, 0, Now() + MAX_AHEAD) and f.t < Now() - 3600 then return false, "That date is in the past." end
    local rec = { id = NewId(), by = Util.PlayerKey(), rev = NextRev(nil) }
    local ok, e = ApplyFields(rec, f, false)
    if not ok then return false, e end
    local kind = f.weekly and "S" or "E"
    ok, e = Commit(root, kind, rec)
    if not ok then return false, e end
    return true, f.weekly and OccId(rec.id, 0) or rec.id
end

-- scope: "one" (default: this raid only) | "series" (every raid of a weekly series). Moving the time of a series
-- moves every occurrence by the same amount. fields as CreateRaid (partial) plus x = false to restore a cancelled
-- raid. Returns ok, err.
function RaidPlan:EditRaid(occId, f, scope)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local v = ResolveOcc(root, occId)
    if not v or type(f) ~= "table" then return false, "unknown raid" end
    local me = Util.PlayerKey()
    if not v.sid then
        local rec = Util.CopyTable(root.E[occId])
        rec.rev, rec.by = NextRev(rec), me
        local ok, e = ApplyFields(rec, f, true)
        if not ok then return false, e end
        if f.x == false then rec.x = nil end
        return Commit(root, "E", rec)
    end
    if scope == "series" then
        local s = Util.CopyTable(root.S[v.sid])
        s.rev, s.by = NextRev(s), me
        local g = {}
        for k, val in pairs(f) do g[k] = val end
        if g.t ~= nil then
            if not IsInt(g.t, 0, Now() + MAX_AHEAD) then return false, "Pick a date at most 180 days ahead." end
            g.t = s.t + (g.t - SeriesTime(s, v.k))
        end
        local ok, e = ApplyFields(s, g, true)
        if not ok then return false, e end
        return Commit(root, "S", s)
    end
    local o = root.E[occId] and Util.CopyTable(root.E[occId]) or { id = occId, sid = v.sid, k = v.k }
    o.rev, o.by = NextRev(root.E[occId]), me
    local ok, e = ApplyFields(o, f, true)
    if not ok then return false, e end
    if f.x == false then o.x = nil end
    return Commit(root, "E", o)
end

-- scope "one" cancels this raid (it stays listed as cancelled); "series" deletes the whole weekly series.
function RaidPlan:CancelRaid(occId, scope)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local v = ResolveOcc(root, occId)
    if not v then return false, "unknown raid" end
    local me = Util.PlayerKey()
    if v.sid and scope == "series" then
        local s = Util.CopyTable(root.S[v.sid])
        s.rev, s.by, s.x = NextRev(s), me, true
        return Commit(root, "S", s)
    end
    local cur = root.E[occId]
    local o = cur and Util.CopyTable(cur) or { id = occId, sid = v.sid, k = v.k }
    o.rev, o.by, o.x = NextRev(cur), me, true
    return Commit(root, "E", o)
end

-- Deletes a raid for everyone (it disappears, with its sign-ups and group layout). scope "series" on a weekly raid
-- deletes the whole weekly series; otherwise only this raid (for a weekly raid: this week's). Returns ok, err.
function RaidPlan:DeleteRaid(occId, scope)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local v = ResolveOcc(root, occId)
    if not v then return false, "unknown raid" end
    if v.sid and scope == "series" then return self:CancelRaid(occId, "series") end
    local ok, e = Commit(root, "E", { id = occId, sid = v.sid, k = v.k, rev = NextRev(root.E[occId]),
                                      by = Util.PlayerKey(), del = true })
    if ok and ns.RaidInvite and ns.RaidInvite.IsActive and ns.RaidInvite:IsActive(occId) then ns.RaidInvite:Stop() end
    return ok, e
end

-- A weekly series ends after this occurrence ("Stop repeating").
function RaidPlan:StopRepeating(occId)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local v = ResolveOcc(root, occId)
    if not v or not v.sid then return false, "not a weekly raid" end
    local s = Util.CopyTable(root.S[v.sid])
    s.rev, s.by, s.u = NextRev(s), Util.PlayerKey(), v.k
    return Commit(root, "S", s)
end

-- grp: { [key] = group 1..8 } (nil / empty clears the layout).
function RaidPlan:SetGroups(occId, grp)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    local v = ResolveOcc(root, occId)
    if not v then return false, "unknown raid" end
    local clean = CleanGroups(grp or {})
    if clean == false then return false, "invalid group layout" end
    local cur = root.E[occId]
    local o = cur and Util.CopyTable(cur) or { id = occId, sid = v.sid, k = v.k }
    o.rev, o.by = NextRev(cur), Util.PlayerKey()
    o.grp = next(clean) and clean or nil
    return Commit(root, "E", o)
end

---------------------------------------------------------------------------
-- Public API: sign-ups (everyone, for their own character)
---------------------------------------------------------------------------

-- status: "A" | "T" | "B" | "X"; spec: index into ns.SPECS[my class] (nil = keep / last used); note: optional
-- (false clears it). Returns ok, err.
function RaidPlan:SignUp(occId, status, spec, note)
    local root = Root(true)
    local me = Util.PlayerKey()
    if not root or not me then return false, "Your guild is not known yet; try again in a moment." end
    local v = ResolveOcc(root, occId)
    if not v then return false, "unknown raid" end
    if v.cancelled then return false, "This raid was cancelled." end
    if v.t < Now() - SIGNUP_CLOSE then return false, "This raid is over." end
    if not STATUSES[status] then return false, "invalid status" end
    local class = MyClass()
    local cur = root.U[occId] and root.U[occId][me]
    local s = { st = status, rev = NextRev(cur), c = class }
    s.at = cur and (cur.at or cur.rev) or s.rev
    if spec == nil then spec = (cur and cur.sp) or self:GetLastSpec() end
    if spec ~= nil then
        if not IsInt(spec, 1, SpecCount(class)) then return false, "invalid spec" end
        s.sp = spec
    end
    if note == nil then
        s.n = cur and cur.n or nil
    elseif note ~= false and Util.Trim(tostring(note)) ~= "" then
        s.n = CleanText(note, MAX_SIGNUP_NOTE)
        if not s.n then return false, "Notes are at most 40 characters." end
    end
    local clean = CleanSignup(s, Now())
    if not clean or not MergeSignup(root, occId, me, clean) then return false, "could not save the sign-up" end
    if clean.sp then
        local db = ns.db
        if type(db.raidplanSpec) ~= "table" then db.raidplanSpec = {} end
        db.raidplanSpec[me] = clean.sp
    end
    BroadcastSignups({ { o = occId, s = clean } })
    Changed()
    return true
end

-- My sign-ups for raids still shown (sent at login, so one made while nobody else was online spreads later).
local function MyLiveSignups()
    local root = Root(false)
    local me = Util.PlayerKey()
    local out = {}
    if not root or not me then return out end
    local minTs = Now() - KEEP_PAST
    for occId, u in pairs(root.U) do
        local s = u[me]
        if s then
            local t = OccTime(root, occId)
            if t and t >= minTs then out[#out + 1] = { o = occId, s = s } end
        end
    end
    tsort(out, function(a, b) return a.o < b.o end)
    return out
end

---------------------------------------------------------------------------
-- Retention (§54)
---------------------------------------------------------------------------

function RaidPlan:Prune(now)
    local root = Root(false)
    if not root then return end
    now = now or Now()
    local cutoff = now - PRUNE_AFTER
    local changed = false
    -- Start times first: dropping an event below must not make its sign-ups look timeless.
    local occTime = {}
    for id in pairs(root.E) do occTime[id] = OccTime(root, id) end
    for id in pairs(root.U) do occTime[id] = OccTime(root, id) end
    for id, t in pairs(root.T) do
        if t.del and t.rev < now - TOMBSTONE_DAYS then root.T[id] = nil; changed = true end
    end
    for id, s in pairs(root.S) do
        if (s.x and s.rev < now - TOMBSTONE_DAYS) or (s.u and SeriesTime(s, s.u) < cutoff) then
            root.S[id] = nil
            changed = true
        end
    end
    for id, e in pairs(root.E) do
        local t = occTime[id]
        if (t and t < cutoff) or (not t and e.rev < now - TOMBSTONE_DAYS) then root.E[id] = nil; changed = true end
    end
    for id, u in pairs(root.U) do
        local t = occTime[id]
        local newest = 0
        for _, s in pairs(u) do newest = max(newest, s.rev or 0) end
        if (t and t < cutoff) or (not t and newest < now - TOMBSTONE_DAYS) or not next(u) then
            root.U[id] = nil
            changed = true
        end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Slash: /cdl plan (a text overview; the Raids tab is the real UI)
---------------------------------------------------------------------------

local STATUS_LABEL = { A = "Accepted", T = "Tentative", B = "Bench", X = "Absent" }
RaidPlan.STATUS_LABEL = STATUS_LABEL

local function SlashPlan()
    local raids = RaidPlan:GetRaids(Now() - 6 * 3600)
    if #raids == 0 then
        ns:Print("No raids planned.")
        return
    end
    for _, v in ipairs(raids) do
        local mine = RaidPlan:GetMySignup(v.id)
        local n = 0
        for _, s in pairs(RaidPlan:GetSignups(v.id)) do
            if s.st == "A" then n = n + 1 end
        end
        ns:Print("%s %s (%d) · %d accepted · you: %s%s", date("%a %d %b %H:%M", v.t), RaidPlan:GetRaidName(v), v.sz or 0,
            n, mine and STATUS_LABEL[mine.st] or "not answered", v.cancelled and " · CANCELLED" or "")
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RaidPlan:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("RPU", OnUpdate)
        Comm:Register("RPS", OnSignups)
        Comm:Register("RPD", OnDigest)
        Comm:Register("RPW", OnWant)
        Comm:Register("RPG", OnGive)
    end
    ns:RegisterSlash("plan", SlashPlan, "list the planned raids and your sign-ups")
    -- The council list decides what is shown: repaint when it changes.
    ns:On("CONFIG_UPDATED", Changed)
end

function RaidPlan:OnLogin()
    local function Daily()
        RaidPlan:Prune()
        Util.After(DAY / 4, Daily)
    end
    -- The guild key (and roster) arrive a little after login.
    Util.RandomDelay(15, 30, function()
        Daily()
        BroadcastSignups(MyLiveSignups())
    end)
end

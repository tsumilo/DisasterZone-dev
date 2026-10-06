if DisasterZoneBoot and DisasterZoneBoot.Run("Core/GuestBook.lua", ...) then return end -- DisasterZone: Core/GuestBook.lua
-- Guest book (1.3): the players outside the guild who raid with us, for the roster managers (the GM, officers and
-- the raid leaders) and for recruiting.
--   History (derived; nothing new on the wire): the raid log (raids, boss kills, no-shows of a linked raid's guests,
--     each with its raid), the Loot Log (items received; loot council only) and the planned raids' guest seats
--     (upcoming raids).
--   Notes (shared): per player a short note, a Recruit mark and (1.3.2) a class / spec set by hand for a player who
--     has not raided with us yet. db.guestNotes[guildKey] = { rev, by, l = { [key] = { n = note, rc = true, c, sp,
--     by, at } } }, shared whole like the blacklist: GNL on GUILD (or WHISPER as an answer), accepted only from a
--     roster manager, the newer rev wins. HELLO carries my rev (gnr); a manager answers an older one, and a member
--     asks (GNQ) a manager who holds a newer one. (Clients before 1.3.2 ignore c / s / x on the wire.)
--   Removed (1.3.2): a player taken out of the book by hand ({ x = when } instead of a note) is left out of it until
--     something new happens with them after that moment (a raid, a missed raid, a guest seat, an item).
--   Specs (local): the class and spec last seen for a guest (db.guestSpecs[guildKey]), learned from guest seats and
--     from a class set by hand, so a pug added again (or automatically) keeps their spec.
-- In a group:
--   A player outside the guild who joins a raid that is a planned raid (Invite & sort ran for it, the raid session is
--   linked to it, or the players in it signed up for it; a started raid session is not needed) becomes a guest of
--   that raid. One client writes it, so two edits of the raid's record never cross: the raid leader when they may add
--   guests, else the first such assistant by name; when that one can't tell which raid it is (the assistant who ran
--   Invite & sort can), the next who may steps in a little later. A guest taken off by hand is not added again: the
--   raid itself keeps who was taken off (RaidPlan gx), so whoever writes next knows.
--   A blacklisted player who joins: the leader / assistants get a popup (Remove from group / Keep), other roster
--   managers a chat line. A guild member's blacklisting is only shown to roster managers.
--   A known guest who joins: the roster managers get one line with their history and note.
--   Inviting a blacklisted player prints a warning at once.
local addonName, ns = ...

local GuestBook = ns:NewModule("GuestBook")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next, select = type, pairs, ipairs, tonumber, tostring, next, select
local floor, max = math.floor, math.max
local tsort, tconcat = table.sort, table.concat

local MAX_NOTES = 100              -- players with a note or a Recruit mark
local MAX_NOTE_LEN = 60
local MAX_KEY_LEN = 48
local MAX_SPECS = 300              -- class / spec memory (the oldest are dropped)
local MAX_STAMP = 4294967295
local FUTURE_SLACK = 300           -- a rev more than 5 minutes past the server time is implausible
local GNL_REPLY_LIMIT = 30
local SCAN_DELAY = 1               -- the group is looked at this long after its last change
local AUTO_KEEP = 2 * 86400        -- players added automatically are remembered this long per raid
local INVITE_WARN_AGAIN = 10       -- one warning per invited name in this window
local ZONES_KEPT = 12              -- raids listed per guest (newest first; no-shows too)
local NEXT_RAID_SLACK = 6 * 3600   -- a raid that started this long ago still counts as the guest's next raid
local FALLBACK_WAIT = 8            -- seconds per writer before me who may add the pugs (GuestWriterTurn)

local members            -- { [key] = true }: the group as last looked at (nil = not looked at yet in this group)
local resumed = false    -- I was in a group when I logged in / reloaded: the first look at it is quiet (no popups, no
                         -- join lines for players who were there before)
local warned = {}        -- [key] = true: the blacklist popup / line was shown in this group
local told = {}          -- [key] = true: the history line was shown in this group
local inviteWarnAt = {}  -- [key] = GetTime() of the last invite warning
local popupQueue = {}    -- blacklisted players waiting for the popup: { key, ... }
local popupOpen = false  -- the popup is up (the next one waits until it closes)
local cache              -- GetEntries' index, rebuilt after any change of its sources

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

local function GuildKey()
    local G = ns.Guild
    return G and G.GetGuildKey and G:GetGuildKey() or nil
end

local function RP() return ns.RaidPlan end

local function IsManager(key)
    local R = RP()
    return (type(key) == "string" and R and R.IsRosterManager and R:IsRosterManager(key)) and true or false
end

local function AmManager()
    return IsManager(Util.PlayerKey())
end

local function GuildReady()
    local G = ns.Guild
    return (G and G.IsReady and G:IsReady()) and true or false
end

local function DemoOn()
    local Demo = ns.Demo
    return (Demo and Demo.IsEnabled and Demo:IsEnabled()) and true or false
end

-- A player outside my guild (the demo guild counts as mine), never me. False while the roster is not known.
local function IsOutsider(key)
    local G = ns.Guild
    if type(key) ~= "string" or Util.IsMe(key) or not GuildReady() then return false end
    return not G:IsInGuild(key)
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

local function CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function Invalidate()
    cache = nil
end

local function Changed()
    Invalidate()
    ns:Fire("GUESTBOOK_CHANGED")
end

-- "Restoration Shaman" / "Shaman" / "".
local function SpecClassText(classFile, sp)
    local spec = classFile and sp and ns.SPECS and ns.SPECS[classFile] and ns.SPECS[classFile][sp]
    local cls = classFile and ns.CLASS_NAMES and ns.CLASS_NAMES[classFile] or classFile or ""
    return spec and (spec.label .. " " .. cls) or cls
end

---------------------------------------------------------------------------
-- Notes (shared between the roster managers)
---------------------------------------------------------------------------

local function NotesRec(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.guestNotes) ~= "table" then
        if not create then return nil end
        db.guestNotes = {}
    end
    local rec = db.guestNotes[g]
    if type(rec) ~= "table" or type(rec.l) ~= "table" or not IsInt(rec.rev, 0, MAX_STAMP) then
        if not create then return nil end
        rec = { rev = 0, l = {} }
        db.guestNotes[g] = rec
    end
    return rec
end

-- A class file the game knows, and a spec index of that class (or nil).
local function ValidClass(c)
    return type(c) == "string" and ns.SPECS and ns.SPECS[c] ~= nil
end

local function ValidSpec(c, sp)
    return ValidClass(c) and IsInt(sp, 1, 9) and ns.SPECS[c][sp] ~= nil
end

-- An untrusted list { { k, n, rc, c, s, b, a }, ... } -> { [key] = { n, rc, c, sp, by, at } }, or nil.
local function CleanNotes(l)
    if type(l) ~= "table" then return nil end
    local out = {}
    for i = 1, MAX_NOTES + 1 do
        local e = l[i]
        if e == nil then break end
        if i > MAX_NOTES or type(e) ~= "table" then return nil end
        local k = WireKey(e.k)
        if not k then return nil end
        local entry = {}
        if e.n ~= nil then
            entry.n = CleanText(e.n, MAX_NOTE_LEN)
            if not entry.n then return nil end
        end
        if e.rc ~= nil then
            if e.rc ~= 1 then return nil end
            entry.rc = true
        end
        if e.b ~= nil then
            entry.by = WireKey(e.b)
            if not entry.by then return nil end
        end
        if e.a ~= nil then
            if not IsInt(e.a, 1, MAX_STAMP) then return nil end
            entry.at = e.a
        end
        if e.c ~= nil then
            if not ValidClass(e.c) then return nil end
            entry.c = e.c
            if e.s ~= nil then
                if not ValidSpec(e.c, e.s) then return nil end
                entry.sp = e.s
            end
        end
        if e.x ~= nil then
            if not IsInt(e.x, 1, MAX_STAMP) then return nil end
            entry.x = e.x
        end
        if entry.n or entry.rc or entry.c or entry.x then out[k] = entry end
    end
    return out
end

local function WireNotes(rec)
    local keys = {}
    for k in pairs(rec.l) do keys[#keys + 1] = k end
    tsort(keys)
    local l = {}
    for i, k in ipairs(keys) do
        local e = rec.l[k]
        l[i] = { k = k, n = e.n, rc = e.rc and 1 or nil, c = e.c, s = e.c and e.sp or nil, x = e.x, b = e.by, a = e.at }
    end
    return l
end

local function SendNotes(target)
    local rec = NotesRec(false)
    if not rec or rec.rev == 0 then return false end
    local msg = { t = "GNL", rev = rec.rev, by = rec.by, l = WireNotes(rec) }
    if target then return Send(msg, "WHISPER", target, "data") end
    return Send(msg, "GUILD", nil, "data")
end

local function OnNotes(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not IsManager(sender) then return end
    if not IsInt(msg.rev, 1, Now() + FUTURE_SLACK) then return end
    local l = CleanNotes(msg.l)
    if not l then return end
    local rec = NotesRec(true)
    if not rec then return end
    if msg.rev < rec.rev then return end
    if msg.rev == rec.rev and Util.Hash(l) <= Util.Hash(rec.l) then return end   -- the same rev: every client keeps one
    rec.rev, rec.l, rec.by = msg.rev, l, (msg.by ~= nil and WireKey(msg.by)) or sender
    Changed()
end

local function OnNotesQuery(sender, _, dist)
    if dist ~= "WHISPER" or not AmManager() then return end
    if not RateLimit("gnq:" .. sender, GNL_REPLY_LIMIT) then return end
    SendNotes(sender)
end

function GuestBook:GetNotesRev()
    local rec = NotesRec(false)
    return rec and rec.rev or 0
end

-- Sync calls this for every HELLO (gnr = the sender's notes rev; nil from clients before 1.3).
function GuestBook:OnNotesRevSeen(sender, gnr)
    if type(gnr) ~= "number" or type(sender) ~= "string" then return end
    local mine = self:GetNotesRev()
    if gnr < mine and AmManager() then
        if RateLimit("gnl-reply:" .. sender, GNL_REPLY_LIMIT) then
            Util.RandomDelay(0.5, 3, function() SendNotes(sender) end)
        end
    elseif gnr > mine and IsManager(sender) then
        if RateLimit("gnq-ask:" .. sender, GNL_REPLY_LIMIT) then
            Send({ t = "GNQ" }, "WHISPER", sender, "ctrl")
        end
    end
end

-- { note, recruit, c, sp, by, at } of a player, or nil.
function GuestBook:GetNote(key)
    local rec = NotesRec(false)
    local e = rec and type(key) == "string" and rec.l[key]
    if type(e) ~= "table" then return nil end
    return { note = e.n, recruit = e.rc and true or false, c = e.c, sp = e.sp, by = e.by, at = e.at }
end

local LearnSpec   -- (the spec memory, below)

-- Sets the note of a player outside the guild (false / "" clears it, nil keeps it), the Recruit mark (nil keeps it)
-- and / or (1.3.2) their class and spec set by hand (classFile nil keeps both, false clears both; sp needs a class).
-- Roster managers only. Returns ok, keyOrErr.
function GuestBook:SetNote(name, note, recruit, classFile, sp)
    if not AmManager() then
        return false, "Only the Guild Master, officers and the raid leaders keep the guest book."
    end
    local rec = NotesRec(true)
    if not rec then return false, "Your guild is not known yet; try again in a moment." end
    local key = WireKey(type(name) == "string" and Util.Trim(name) or name)
    if not key then return false, "That is not a player name." end
    if Util.IsMe(key) then return false, "That is you." end
    local G = ns.Guild
    if G and G.IsInGuild and G:IsInGuild(key, true) then
        return false, Util.ShortName(key) .. " is in the guild: the guest book is for players outside it."
    end
    local cur = rec.l[key]
    local n = cur and cur.n or nil
    if note ~= nil then
        if note == false or Util.Trim(tostring(note)) == "" then
            n = nil
        else
            n = CleanText(tostring(note), MAX_NOTE_LEN)
            if not n then return false, "Notes are at most " .. MAX_NOTE_LEN .. " characters on one line." end
        end
    end
    local rc = cur and cur.rc or nil
    if recruit ~= nil then rc = recruit and true or nil end
    local c, spec = cur and cur.c or nil, cur and cur.sp or nil
    if classFile == false then
        c, spec = nil, nil
    elseif classFile ~= nil then
        if not ValidClass(classFile) then return false, "Pick a class." end
        if sp ~= nil and not ValidSpec(classFile, sp) then return false, "invalid spec" end
        c, spec = classFile, sp
    end
    if not n and not rc and not c then
        if not cur or cur.x then return true, key end   -- (nothing to clear on a player taken out of the book)
        rec.l[key] = nil
    else
        if not cur and CountTable(rec.l) >= MAX_NOTES then
            return false, "The guest book keeps notes on at most " .. MAX_NOTES .. " players."
        end
        if cur and cur.n == n and cur.rc == rc and cur.c == c and cur.sp == spec then return true, key end
        -- (who wrote the note and when stay with the note while only the mark or the class changes)
        local kept = cur and n and cur.n == n
        rec.l[key] = { n = n, rc = rc, c = c, sp = spec, by = kept and cur.by or Util.PlayerKey(),
                       at = kept and cur.at or Now() }
    end
    if c and classFile ~= nil then LearnSpec(key, c, spec, Now()) end
    rec.rev = max(Now(), rec.rev + 1)
    rec.by = Util.PlayerKey()
    SendNotes()
    Changed()
    return true, key
end

-- Takes a player out of the guest book (1.3.2): their note, Recruit mark and class go, and the book leaves them out
-- until something new happens with them (a raid, a guest seat, an item). Roster managers only. Returns ok, keyOrErr.
function GuestBook:Remove(name)
    if not AmManager() then
        return false, "Only the Guild Master, officers and the raid leaders keep the guest book."
    end
    local rec = NotesRec(true)
    if not rec then return false, "Your guild is not known yet; try again in a moment." end
    local key = WireKey(type(name) == "string" and Util.Trim(name) or name)
    if not key then return false, "That is not a player name." end
    if not rec.l[key] and CountTable(rec.l) >= MAX_NOTES then
        return false, "The guest book keeps notes on at most " .. MAX_NOTES .. " players."
    end
    rec.l[key] = { x = Now(), by = Util.PlayerKey(), at = Now() }
    rec.rev = max(Now(), rec.rev + 1)
    rec.by = Util.PlayerKey()
    SendNotes()
    Changed()
    return true, key
end

---------------------------------------------------------------------------
-- Class / spec memory (local)
---------------------------------------------------------------------------

local function SpecsRec(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.guestSpecs) ~= "table" then
        if not create then return nil end
        db.guestSpecs = {}
    end
    local t = db.guestSpecs[g]
    if type(t) ~= "table" then
        if not create then return nil end
        t = {}
        db.guestSpecs[g] = t
    end
    return t
end

function LearnSpec(key, classFile, sp, at)
    if type(key) ~= "string" or type(classFile) ~= "string" or not (ns.SPECS and ns.SPECS[classFile]) then return end
    if sp ~= nil and not (IsInt(sp, 1, 9) and ns.SPECS[classFile][sp]) then sp = nil end
    local t = SpecsRec(true)
    if not t then return end
    at = tonumber(at) or Now()
    local cur = t[key]
    if type(cur) == "table" then
        if (tonumber(cur.at) or 0) > at then return end          -- an older guest seat doesn't override a newer one
        if cur.c == classFile and sp == nil then sp = cur.sp end  -- (the class alone says nothing about the spec)
        if cur.c == classFile and cur.sp == sp then
            cur.at = max(tonumber(cur.at) or 0, at)
            return
        end
    end
    t[key] = { c = classFile, sp = sp, at = at }
    if CountTable(t) > MAX_SPECS then
        local oldest, oldestAt
        for k, e in pairs(t) do
            local a = type(e) == "table" and tonumber(e.at) or 0
            if not oldestAt or a < oldestAt then oldest, oldestAt = k, a end
        end
        if oldest then t[oldest] = nil end
    end
    Invalidate()
end

-- The guest seats of the planned raids (every member has the raid plan): their class and spec.
local function LearnFromPlan()
    local R = RP()
    if not (R and R.GetRaids) or not GuildReady() then return end
    for _, v in ipairs(R:GetRaids(nil, nil, true)) do
        for key, g in pairs(type(v.gu) == "table" and v.gu or {}) do
            if type(g) == "table" then LearnSpec(key, g.c, g.sp, g.at) end
        end
    end
end

-- classFile, spec index (or nil) last seen for a player outside the guild.
function GuestBook:GetSpec(key)
    local t = SpecsRec(false)
    local e = t and type(key) == "string" and t[key]
    if type(e) ~= "table" then return nil end
    return e.c, e.sp
end

---------------------------------------------------------------------------
-- History (derived)
---------------------------------------------------------------------------

-- A logged raid's instance (the raid plan's key: its loading screen), or nil.
local function InstOf(rec)
    local R = RP()
    for _, inst in ipairs(R and R.GetInstances and R:GetInstances() or {}) do
        if inst.instID and inst.instID == rec.instID then return inst.key end
    end
    return nil
end

local function Build()
    local by, list = {}, {}
    if not GuildReady() then return { by = by, list = list } end
    local function E(key)
        local e = by[key]
        if not e then
            e = { key = key, raids = 0, kills = 0, noShows = 0, items = 0, zones = {}, itemList = {}, recIds = {} }
            by[key] = e
            list[#list + 1] = e
        end
        return e
    end
    -- (the last thing that happened with a player: a player taken out of the book comes back after it)
    local function Touch(e, t)
        t = tonumber(t)
        if t and (not e.act or t > e.act) then e.act = t end
    end
    local RL = ns.RaidLog
    for _, rec in ipairs(RL and RL.GetRaids and RL:GetRaids() or {}) do
        local at = tonumber(rec.start) or 0
        local inst = InstOf(rec)
        for key, a in pairs(type(rec.att) == "table" and rec.att or {}) do
            if IsOutsider(key) then
                local e = E(key)
                Touch(e, at)
                e.raids = e.raids + 1
                e.recIds[rec.id or ""] = true
                local k = type(a) == "table" and tonumber(a.k) or 0
                e.kills = e.kills + k
                if not e.last or at > e.last then
                    e.last = at
                    if type(a) == "table" and type(a.c) == "string" then e.c = a.c end
                end
                if not e.first or at < e.first then e.first = at end
                if not e.c and type(a) == "table" and type(a.c) == "string" then e.c = a.c end
                e.zones[#e.zones + 1] = { id = rec.id, at = at, zone = rec.zone, inst = inst, kills = k,
                                          bosses = #(rec.bosses or {}), bench = type(a) == "table" and a.b and true or nil }
            end
        end
        for key, st in pairs(type(rec.su) == "table" and rec.su or {}) do
            if st == "A" and not (rec.att and rec.att[key]) and IsOutsider(key) then
                local e = E(key)
                Touch(e, at)
                e.noShows = e.noShows + 1
                e.zones[#e.zones + 1] = { id = rec.id, at = at, zone = rec.zone, inst = inst, noShow = true }
            end
        end
    end
    -- the guest seats of the planned raids: an upcoming raid, and the class of a guest who has not raided yet
    local R = RP()
    local now = Now()
    for _, v in ipairs(R and R.GetRaids and R:GetRaids(nil, nil, true) or {}) do
        if not v.cancelled then
            for key, g in pairs(type(v.gu) == "table" and v.gu or {}) do
                if IsOutsider(key) and type(g) == "table" then
                    local e = E(key)
                    Touch(e, g.at)
                    e.c = e.c or g.c
                    if v.t >= now - NEXT_RAID_SLACK and (not e.next or v.t < e.next.t) then
                        e.next = { id = v.id, t = v.t, name = R:GetRaidName(v),
                                   inst = R.GetRaidInstances and R:GetRaidInstances(v)[1] or v.i }
                    end
                end
            end
        end
    end
    -- items received (the Loot Log; the loot council has it)
    local L = ns.Ledger
    for _, it in ipairs(L and L.GetEntries and L:GetEntries({ excludeDungeon = true }) or {}) do
        if type(it.w) == "string" and IsOutsider(it.w) then
            local r = ns.AWARD_REASON and it.r and ns.AWARD_REASON[it.r]
            if not r or r.counts then
                local e = E(it.w)
                Touch(e, it.ts)
                e.items = e.items + 1
                if #e.itemList < 20 then e.itemList[#e.itemList + 1] = it end
            end
        end
    end
    -- notes (also for a player who has not raided with us yet)
    local notes = NotesRec(false)
    for key, n in pairs(notes and notes.l or {}) do
        if type(n) == "table" and IsOutsider(key) then
            local e = E(key)
            e.note, e.recruit, e.noteBy, e.noteAt = n.n, n.rc and true or false, n.by, n.at
            e.setC, e.setSp = n.c, n.sp
            e.removedAt = n.x
        end
    end
    -- players taken out of the book by hand, with nothing new since
    for i = #list, 1, -1 do
        local e = list[i]
        if e.removedAt and (e.act or 0) <= e.removedAt then
            by[e.key] = nil
            table.remove(list, i)
        end
    end
    local specs = SpecsRec(false)
    for _, e in ipairs(list) do
        local s = specs and specs[e.key]
        if type(s) == "table" then
            if not e.c then e.c = s.c end
            if s.c == e.c then e.sp = s.sp end
        end
        -- (a class set by hand: for a player the raids have not shown yet)
        if e.setC and (not e.c or e.c == e.setC) then
            e.c = e.setC
            if e.setSp then e.sp = e.setSp end
        end
        local bl = R and R.GetBlacklistEntry and R:GetBlacklistEntry(e.key)
        e.blacklisted = bl and true or false
        e.blacklist = bl
        e.recruit = e.recruit or false
        tsort(e.zones, function(a, b) return a.at > b.at end)
        for i = #e.zones, ZONES_KEPT + 1, -1 do e.zones[i] = nil end
        e.seen = e.last or (e.next and e.next.t) or e.noteAt or 0
    end
    tsort(list, function(a, b)
        if a.seen ~= b.seen then return a.seen > b.seen end
        return a.key < b.key
    end)
    return { by = by, list = list }
end

local function Index()
    if not cache then cache = Build() end
    return cache
end

-- Everyone outside the guild the guest book knows, newest first: { key, c, sp, raids, kills, first, last, zones (newest
-- first: { id, at, zone, inst, kills, bosses, bench } for a raid they came to, { id, at, zone, inst, noShow = true }
-- for one they signed up for and missed), noShows, items, itemList, next = { id, t, name, inst }, note, recruit,
-- noteBy, noteAt, setC / setSp (the class / spec set by hand), blacklisted, blacklist = { key, reason, by, at },
-- seen }. Stored tables: treat them as read-only.
function GuestBook:GetEntries()
    return Index().list
end

function GuestBook:GetEntry(key)
    return type(key) == "string" and Index().by[key] or nil
end

-- What the guest book says about a player, short: "3 raids with us (last 26 Sep) · 1 no-show · Recruit · "wants to
-- join"". excludeId: a raid log record not to count (the raid running now). nil when nothing is known.
function GuestBook:Summary(key, excludeId)
    local e = self:GetEntry(key)
    if not e then return nil end
    local parts = {}
    local raids = e.raids - ((excludeId and e.recIds[excludeId]) and 1 or 0)
    if raids > 0 then
        local last
        for _, z in ipairs(e.zones) do
            if not z.noShow and z.id ~= excludeId and (not last or z.at > last) then last = z.at end
        end
        parts[#parts + 1] = (raids == 1 and "1 raid with us" or (raids .. " raids with us"))
            .. ((last and last > 0) and (" (last " .. date("%d %b", last) .. ")") or "")
    end
    if e.noShows > 0 then parts[#parts + 1] = e.noShows == 1 and "1 no-show" or (e.noShows .. " no-shows") end
    if e.recruit then parts[#parts + 1] = "Recruit" end
    if e.note then parts[#parts + 1] = '"' .. e.note .. '"' end
    if #parts == 0 then return nil end
    return tconcat(parts, " · ")
end

---------------------------------------------------------------------------
-- In the group: joins, guests added automatically, blacklisted players
---------------------------------------------------------------------------

-- The group now: { [key] = { rank = 0 / 1 / 2, c = classFile } } (me included).
local function RosterNow()
    local out = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() or 0 do
            local name, rank, _, _, _, classFile = GetRaidRosterInfo(i)
            local key = type(name) == "string" and name ~= "" and Util.NormalizeName(name) or nil
            if key then out[key] = { rank = tonumber(rank) or 0, c = classFile } end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() or 0 do
            local unit = "party" .. i
            local key = Util.UnitKey(unit)
            if key then
                out[key] = { rank = UnitIsGroupLeader(unit) and 2 or 0, c = select(2, UnitClass(unit)) }
            end
        end
        local me = Util.PlayerKey()
        if me then out[me] = { rank = UnitIsGroupLeader("player") and 2 or 0, c = select(2, UnitClass("player")) } end
    end
    return out
end

-- May I take a player out of the group (the leader; in a raid also an assistant)?
local function CanRemove()
    if UnitIsGroupLeader("player") then return true end
    return IsInRaid() and UnitIsGroupAssistant("player") and true or false
end

-- Who adds the pugs, in turn: the raid leader when they may add guests to that planned raid (occ; its own leader
-- counts, a raid leader it doesn't belong to doesn't), then the assistants (by name) who may. The first one writes, so
-- two edits of the raid's record never cross; the others step in after a wait when the pugs are still missing (only
-- they may know which raid this is: Invite & sort is known to whoever ran it). Returns my turn (1 = first) or nil.
local function GuestWriterTurn(roster, occ)
    local R = RP()
    local function may(key)
        if R and R.CanManageRoster then return R:CanManageRoster(occ, key) and true or false end
        return IsManager(key)
    end
    local leader, assists = nil, {}
    for key, r in pairs(roster) do
        if r.rank == 2 then leader = key elseif r.rank == 1 then assists[#assists + 1] = key end
    end
    local order = {}
    if leader and may(leader) then order[1] = leader end
    tsort(assists)
    for _, key in ipairs(assists) do
        if may(key) then order[#order + 1] = key end
    end
    for i, key in ipairs(order) do
        if Util.IsMe(key) then return i end
    end
    return nil
end

local function CurrentInstance()
    local inInstance, kind = IsInInstance()
    if not inInstance or kind ~= "raid" then return nil end
    return tonumber((select(8, GetInstanceInfo())))
end

-- The planned raid this raid group is: the one Invite & sort runs for, the one the raid session is linked to, or the
-- best match by time and sign-ups (RaidLink's rules). nil when none is clear (or the session was unlinked on purpose).
local function PlannedRaid(roster)
    local RI = ns.RaidInvite
    local st = RI and RI.GetStatus and RI:GetStatus()
    if type(st) == "table" and st.occ then return st.occ end
    local GR = ns.GroupRules
    local s = GR and GR.GetSession and GR:GetSession()
    if type(s) == "table" and (s.rp or s.rpAt) then return s.rp end
    local RL = ns.RaidLink
    if not (RL and RL.Match) then return nil end
    local keys = {}
    for key in pairs(roster) do keys[key] = true end
    return (RL:Match(Now(), keys, CurrentInstance()))
end

-- db.autoGuests = { [occ] = { [key] = when } }: who I added automatically (or tried), so I don't try again at every
-- change of the group. (A guest taken off by hand: the raid's own mark, gx, for every client.)
local function AutoDone(occ)
    local db = ns.db
    if not db then return {} end
    if type(db.autoGuests) ~= "table" then db.autoGuests = {} end
    local now = Now()
    for o, set in pairs(db.autoGuests) do
        local keep = false
        if type(set) == "table" then
            for k, at in pairs(set) do
                if type(at) ~= "number" or now - at > AUTO_KEEP then set[k] = nil else keep = true end
            end
        end
        if not keep and o ~= occ then db.autoGuests[o] = nil end
    end
    local set = db.autoGuests[occ]
    if type(set) ~= "table" then
        set = {}
        db.autoGuests[occ] = set
    end
    return set
end

-- The pugs of the group who are not on the raid (a view) yet: not blacklisted, not taken off it by hand (the raid's
-- own mark, gx: whoever writes respects it), not tried by me already. Sorted by name.
local function MissingGuests(R, roster, v, done)
    local signups = R:GetSignups(v.id)
    local list = {}
    for key, r in pairs(roster) do
        if IsOutsider(key) and not signups[key] and not done[key] and not R:IsBlacklisted(key)
            and not (v.gx and v.gx[key]) and r.c then
            local c, sp = GuestBook:GetSpec(key)
            list[#list + 1] = { key = key, c = r.c, sp = (c == r.c) and sp or nil }
        end
    end
    tsort(list, function(a, b) return a.key < b.key end)
    return list
end

-- fallback: my turn came because the ones before me (GuestWriterTurn) left the pugs out.
local function AutoGuests(roster, fallback)
    local R = RP()
    if not (R and R.AddGuests and R.GetSignups and R.GetRaid) or DemoOn() then return end
    local occ = PlannedRaid(roster)
    local v = occ and R:GetRaid(occ)
    if not v or v.cancelled then return end
    local turn = GuestWriterTurn(roster, occ)
    if not turn then return end
    local done = AutoDone(occ)
    local list = MissingGuests(R, roster, v, done)
    if #list == 0 then return end
    if turn > 1 and not fallback then
        Util.Debounce("guestbook-fallback", FALLBACK_WAIT * (turn - 1), function()
            if IsInRaid() and ns.loggedIn and GuildReady() then AutoGuests(RosterNow(), true) end
        end)
        return
    end
    local now = Now()
    for _, g in ipairs(list) do done[g.key] = now end
    local ok, added = R:AddGuests(occ, list)
    if not ok or type(added) ~= "table" or #added == 0 then return end
    local names = {}
    local byKey = {}
    for _, g in ipairs(list) do byKey[g.key] = g end
    for i, key in ipairs(added) do
        local g = byKey[key]
        local cls = g and SpecClassText(g.c, g.sp) or ""
        names[i] = Util.ShortName(key) .. (cls ~= "" and (" (" .. cls .. ")") or "")
    end
    ns:Print("Added %s as %s of %s. Right-click a guest in the raid's roster to remove them.", tconcat(names, ", "),
        #added == 1 and "a guest" or "guests", R:GetRaidName(v))
end

local ShowNextPopup

local function BlacklistDetail(e)
    if not (e and AmManager()) then return "" end
    local parts = {}
    if e.reason then parts[#parts + 1] = e.reason end
    local who = e.by and Util.ShortName(e.by)
    local when = e.at and date("%d %b", e.at)
    if who or when then parts[#parts + 1] = "(" .. tconcat({ who or "?", when }, ", ") .. ")" end
    return tconcat(parts, " ")
end

ShowNextPopup = function()
    local key = table.remove(popupQueue, 1)
    if not key then return end
    if not (members and members[key]) then return ShowNextPopup() end   -- gone meanwhile
    local R = RP()
    local e = R and R.GetBlacklistEntry and R:GetBlacklistEntry(key)
    if not e or type(StaticPopup_Show) ~= "function" then return ShowNextPopup() end
    local detail = BlacklistDetail(e)
    if StaticPopup_Show("DISASTERZONE_BLACKLIST_JOINED", Util.ShortName(key), detail ~= "" and ("\n" .. detail) or "",
        { key = key }) then
        popupOpen = true
    end
end

-- quiet: the first look after a /reload or login (they were there before): a line instead of the popup, no join line.
local function OnJoined(key, quiet)
    local R = RP()
    local e = R and R.GetBlacklistEntry and R:GetBlacklistEntry(key)
    local outsider = IsOutsider(key)
    if e then
        if warned[key] or not (outsider or AmManager()) then return end
        warned[key] = true
        if CanRemove() and not quiet then
            popupQueue[#popupQueue + 1] = key
            if not popupOpen then ShowNextPopup() end
        elseif AmManager() or CanRemove() then
            local detail = BlacklistDetail(e)
            ns:Print("|cffff4040%s is on the raid blacklist.|r%s", Util.ShortName(key), detail ~= "" and (" " .. detail) or "")
        end
        return
    end
    if quiet or told[key] or not outsider or not AmManager() then return end
    local RL = ns.RaidLog
    local cur = RL and RL.GetCurrentID and RL:GetCurrentID() or nil
    local summary = GuestBook:Summary(key, cur)
    if not summary then return end
    told[key] = true
    local c, sp = GuestBook:GetSpec(key)
    local entry = GuestBook:GetEntry(key)
    local cls = SpecClassText(c or (entry and entry.c), c and sp or nil)
    ns:Print("%s%s joined: %s", Util.ShortName(key), cls ~= "" and (" (" .. cls .. ")") or "", summary)
end

local function Scan()
    if not IsInGroup() then
        members, warned, told, popupQueue, resumed = nil, {}, {}, {}, false
        return
    end
    if not ns.loggedIn or not GuildReady() then
        Util.Debounce("guestbook-scan", 3, Scan)
        return
    end
    local roster = RosterNow()
    local first = members == nil
    local quiet = first and resumed
    resumed = false
    local fresh = {}
    for key in pairs(roster) do
        if not Util.IsMe(key) and (first or not members[key]) then fresh[#fresh + 1] = key end
    end
    for key in pairs(members or {}) do
        if not roster[key] then warned[key] = nil end   -- left: joining again is a new join
    end
    members = {}
    for key in pairs(roster) do members[key] = true end
    tsort(fresh)
    for _, key in ipairs(fresh) do OnJoined(key, quiet) end
    if IsInRaid() then AutoGuests(roster) end
end

local function ScheduleScan(delay)
    Util.Debounce("guestbook-scan", delay or SCAN_DELAY, Scan)
end

-- An invite I send (the game's menus, /invite, another addon): a blacklisted player gets me a warning at once.
local function OnInvite(name)
    if type(name) ~= "string" or name == "" then return end
    local key = Util.NormalizeName(name)
    local R = RP()
    local e = key and R and R.GetBlacklistEntry and R:GetBlacklistEntry(key)
    if not e or not (IsOutsider(key) or AmManager()) then return end
    local t = GetTime()
    if inviteWarnAt[key] and t - inviteWarnAt[key] < INVITE_WARN_AGAIN then return end
    inviteWarnAt[key] = t
    local detail = BlacklistDetail(e)
    ns:Print("|cffff4040%s is on the raid blacklist.|r%s", Util.ShortName(key), detail ~= "" and (" " .. detail) or "")
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function GuestBook:OnInit()
    local Comm = ns.Comm
    if Comm and Comm.Register then
        Comm:Register("GNL", OnNotes)
        Comm:Register("GNQ", OnNotesQuery)
    end
    for _, msg in ipairs({ "RAIDLOG_CHANGED", "LEDGER_UPDATED", "RAID_BLACKLIST_CHANGED", "ROSTER_UPDATED",
                           "DEMO_TOGGLED", "CONFIG_UPDATED", "ACCOUNTS_UPDATED" }) do
        ns:On(msg, Changed)
    end
    ns:On("RAIDPLAN_CHANGED", function()
        Invalidate()
        Util.Debounce("guestbook-plan", 2, LearnFromPlan)
        ns:Fire("GUESTBOOK_CHANGED")
        if IsInRaid() then ScheduleScan(2) end
    end)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function() ScheduleScan() end)
    ns:On("RAIDINVITE_CHANGED", function() if IsInRaid() then ScheduleScan(2) end end)
    ns:On("GROUP_RULES_CHANGED", function() if IsInRaid() then ScheduleScan(2) end end)
    if StaticPopupDialogs then
        StaticPopupDialogs["DISASTERZONE_BLACKLIST_JOINED"] = {
            text = "%s is on the raid blacklist.%s",
            button1 = "Remove from group",
            button2 = "Keep",
            OnAccept = function(_, data)
                local key = type(data) == "table" and data.key
                if key and UninviteUnit then UninviteUnit(Ambiguate and Ambiguate(key, "none") or key) end
            end,
            OnHide = function()
                popupOpen = false
                Util.After(0.2, ShowNextPopup)
            end,
            showAlert = true,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    if type(hooksecurefunc) == "function" then
        if type(InviteUnit) == "function" then hooksecurefunc("InviteUnit", OnInvite) end
        if C_PartyInfo and type(C_PartyInfo.InviteUnit) == "function" then
            hooksecurefunc(C_PartyInfo, "InviteUnit", OnInvite)
        end
    end
end

function GuestBook:OnLogin()
    resumed = IsInGroup() and true or false
    ScheduleScan(5)
    Util.After(10, LearnFromPlan)
    -- A roster manager shares the notes once after logging in, for members who logged in while none was online.
    -- 20-40 s, spread by my name rather than math.random (drawing from it would shift every other module's jitter).
    local h = tonumber(Util.Hash(Util.PlayerKey() or ""):sub(1, 4), 16) or 0
    Util.After(20 + h % 21, function()
        if AmManager() and GuestBook:GetNotesRev() > 0 then SendNotes() end
    end)
end

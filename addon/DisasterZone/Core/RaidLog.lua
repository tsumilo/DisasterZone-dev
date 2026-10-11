if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidLog.lua", ...) then return end -- DisasterZone: Core/RaidLog.lua
-- Raid log (Addendum I §48-§49): records the raid session the raid's authority runs (GroupRules:GetSession, GS
-- rs / rsAt) into db.raids: zone, boss kills with the roster at each kill, and attendance by raid group
-- membership (not location, so ghost runs, AFKs and long trash clears are fine).
--
-- Every client in the raid records locally; there is no single recorder (council clients merge later, §50).
-- Council members exchange closed records (§50: RLD / RLW / RLG, digests also ride on Sync's H / M as rd).
-- The record closes when the authority ends the session (endedBy), or, as a safety net, when I am no longer in
-- the raid (disband, left, raid -> party: autoEnded, stop = the last activity). While no authority rules are known
-- (right after a /reload, or while the authority changes hands) the open record just waits.
local addonName, ns = ...

local RaidLog = ns:NewModule("RaidLog")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring = type, pairs, ipairs, tonumber, tostring
local floor = math.floor
local tsort = table.sort

local DAY = 86400
local SCAN_INTERVAL = 60                -- roster / activity scan while a session is open
local ROSTER_DELAY = 1                  -- debounce after GROUP_ROSTER_UPDATE
local RESUME_MAX_IDLE = 2 * 3600        -- an open record idle longer than this is not adopted by a new authority
local ROSTER_KEEP_DAYS = 90             -- per-boss rosters are dropped after this (att totals stay)
local PROMPT_SNOOZE = 1800              -- the "no raid session" reminder is asked at most once per 30 min

local scanPending = false
local zoneEnteredAt                     -- server time I entered the current raid instance (backdating)
local promptedAt = -PROMPT_SNOOZE
local missedPull = false                -- a boss was pulled here while no session ran
local pulls = {}                        -- [encounterID] = server time of the pull (the kill's `dur`)
-- 1.3.3: the open record's session as seen running by me since I loaded (its id). Only then does the record take in
-- roster changes, and an end of the session close it "now" (endedBy). An open record from before my logout
-- or crash whose session is gone by the time I hear the authority (I missed the end) closes at its last activity, as
-- the safety net does, without the players who joined the group after it.
local confirmed

-- 1.3.5 (time-based attendance, Core/Attendance.lua): each player's time online in the raid group, as pieces
-- a.s = { from1, to1, from2, to2, ... } (oldest first). A scan extends the last piece while they stay; a piece starts
-- anew after a gap longer than PIECE_JOIN (a scan missed is not a gap). At most MAX_PIECES: past that, the two closest
-- pieces become one (the gap between them is the shortest, so it is the least likely to matter).
local PIECE_JOIN = 2 * SCAN_INTERVAL + 10
local MAX_PIECES = 16
local groupSeen = {}                    -- [key] = server time first seen online in my raid group (this login)
local lastRoster                        -- the keys of the last scan's roster (who left the group since)

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- Addendum J §62: raid log records (no items in them) are exchanged between raid planners: the GM, the guild
-- council and the raid leaders list.
local function IsPlanner(key)
    local Guild = ns.Guild
    return Guild and Guild.IsRaidLogMember and type(key) == "string" and Guild:IsRaidLogMember(key) and true or false
end

-- 1.3.5: reads and shares the raid log: its members and the attendance reviewers (the GM, officers, guild council).
local function IsReader(key)
    local Guild = ns.Guild
    if not (Guild and type(key) == "string") then return false end
    if Guild.IsRaidLogReader then return Guild:IsRaidLogReader(key) end
    return IsPlanner(key)
end

local function RaidsDB()
    local db = ns.db
    if not db then return nil end
    if type(db.raids) ~= "table" then db.raids = {} end
    return db.raids
end

local function OpenRecord()
    local db = ns.db
    local id = db and db.raidCurrent
    local raids = RaidsDB()
    if type(id) ~= "string" or not raids then return nil end
    local rec = raids[id]
    if type(rec) ~= "table" or rec.stop then
        db.raidCurrent = nil
        return nil
    end
    return rec
end

local function GuildKey()
    local Guild = ns.Guild
    return Guild and Guild.GetGuildKey and Guild:GetGuildKey() or nil
end

local attCache = {}   -- [lastN] = attendance totals (GetAttendance), dropped on every change

local function Changed(rec)
    attCache = {}
    ns:Fire("RAIDLOG_CHANGED", rec and rec.id)
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

-- { [key] = { class=, online=, zone= } } of the current raid (the real roster, never the demo raid).
local function Roster()
    local out = {}
    if not IsInRaid() then return out end
    for i = 1, (GetNumGroupMembers() or 0) do
        local name, _, _, _, _, fileName, zone, online = GetRaidRosterInfo(i)
        local key = (type(name) == "string" and name ~= UNKNOWNOBJECT) and Util.NormalizeName(name) or nil
        if key then
            out[key] = { class = fileName, online = online and true or false, zone = zone }
        end
    end
    return out
end

-- Zone / instance of the raid, from my own position when I am inside a raid instance.
local function NoteZone(rec)
    if not Util.InRaidInstance() then return false end
    local name, _, _, _, _, _, _, instID = GetInstanceInfo()
    if type(name) == "string" and name ~= "" and rec.zone ~= name then
        rec.zone = name
        rec.instID = tonumber(instID)
    end
    return true
end

-- Two pieces lists (see PIECE_JOIN) as one: overlapping or nearly touching pieces joined, at most MAX_PIECES.
local function JoinPieces(a, b)
    local list = {}
    for _, s in ipairs({ a or {}, b or {} }) do
        for i = 1, #s - 1, 2 do list[#list + 1] = { s[i], s[i + 1] } end
    end
    tsort(list, function(x, y) return x[1] < y[1] end)
    local out = {}
    for _, p in ipairs(list) do
        local n = #out
        if n >= 2 and p[1] <= out[n] + PIECE_JOIN then
            if p[2] > out[n] then out[n] = p[2] end
        else
            out[n + 1], out[n + 2] = p[1], p[2]
        end
    end
    while #out > 2 * MAX_PIECES do
        local best, gap = 2, math.huge
        for i = 2, #out - 2, 2 do
            if out[i + 1] - out[i] < gap then best, gap = i, out[i + 1] - out[i] end
        end
        table.remove(out, best + 1)
        table.remove(out, best)
    end
    return out
end

-- The player is online in the group now (since: when I first saw them there, for the first piece of a record).
local function AddPresence(a, now, since)
    local s = type(a.s) == "table" and a.s or {}
    local n = #s
    if n >= 2 and now - s[n] <= PIECE_JOIN then
        if now > s[n] then s[n] = now end
        a.s = s
    else
        a.s = JoinPieces(s, { math.min(since or now, now), now })
    end
end

-- Who of my raid group is online, since when (groupSeen): a session started late still knows who was there first.
local function NoteGroup(roster)
    local now = GetServerTime()
    for key in pairs(groupSeen) do
        local m = roster[key]
        if not (m and m.online) then groupSeen[key] = nil end
    end
    for key, m in pairs(roster) do
        if m.online and not groupSeen[key] then groupSeen[key] = now end
    end
end

-- Updates attendance (joins / leaves, the presence pieces) and the activity stamp from the live roster.
local function Scan(rec)
    if not rec then return end
    local now = GetServerTime()
    if not rec.g then rec.g = GuildKey() end
    local inside = NoteZone(rec)
    local NoteZoneInside = inside
    local roster = Roster()
    NoteGroup(roster)
    rec.att = type(rec.att) == "table" and rec.att or {}
    for key, m in pairs(roster) do
        local a = rec.att[key]
        if type(a) ~= "table" then
            a = { j = now, k = 0 }
            rec.att[key] = a
        end
        if not a.j then a.j = now end   -- (a bench mark of somebody who never joined, joining now)
        if m.class then a.c = m.class end
        a.l = nil   -- present (again)
        if m.online then AddPresence(a, now, groupSeen[key]) end
        -- 1.3.5: online in the group but outside the raid's instance while the raid is inside (a soft flag only:
        -- minutes added per scan, at most one scan's worth at a time)
        if m.online and rec.zone and NoteZoneInside and m.zone and m.zone ~= rec.zone then
            local step = math.min(now - (a.ot or now), SCAN_INTERVAL + 10)
            if step > 0 then a.o = (tonumber(a.o) or 0) + step end
        end
        a.ot = now
        if m.online and rec.zone and m.zone == rec.zone then inside = true end
    end
    for key, a in pairs(rec.att) do
        if not roster[key] and not a.l and not a.b then a.l = now end
    end
    if inside then rec.last = now end
    -- who left the group since the last scan / joined it (the raid leader's attendance prompt, fill-ins)
    local before = lastRoster and lastRoster.id == rec.id and lastRoster.keys or nil
    local keys = {}
    for key in pairs(roster) do keys[key] = true end
    lastRoster = { id = rec.id, keys = keys }
    if before then
        for key in pairs(before) do
            if not keys[key] then ns:Fire("RAIDLOG_LEFT", rec.id, key) end
        end
        for key in pairs(keys) do
            if not before[key] then ns:Fire("RAIDLOG_JOINED", rec.id, key) end
        end
    end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    Util.After(ROSTER_DELAY, function()
        scanPending = false
        local rec = OpenRecord()
        if rec and rec.id == confirmed then
            Scan(rec)
            Changed(rec)
        elseif IsInRaid() then
            NoteGroup(Roster())            -- (no session yet: who is here since when, for when it starts)
        else
            wipe(groupSeen)
        end
    end)
end

-- An attendance entry of somebody who was never in the raid: a bench mark only (1.3: no join / leave times; earlier
-- entries carry the raid's start and end).
local function NeverJoined(rec, a)
    if (tonumber(a.k) or 0) > 0 then return false end
    return a.j == nil or (a.j == rec.start and a.l == rec.stop)
end

-- Addendum J §61 (1.3): the sign-ups kept on a record (su) and the bench marks made from them (edit time = the time of
-- the link they came from, plAt) belong to that link. Dropped when the record is linked to another planned raid or
-- unlinked: nothing of the old raid's sign-ups stays behind (no-shows, reliability, the guest book).
local function DropSignups(rec, plAt)
    rec.su = nil
    -- 1.3.5: who the raid expected (and when) came from the same link (Attendance:Snapshot)
    rec.ex, rec.exAt, rec.ef, rec.et, rec.sn = nil, nil, nil, nil, nil
    plAt = tonumber(plAt)
    if not plAt or plAt <= 0 or type(rec.att) ~= "table" then return end
    for key, a in pairs(rec.att) do
        if a.b and a.bts == plAt then
            if NeverJoined(rec, a) then
                rec.att[key] = nil
            else
                a.b, a.bts = nil, nil
            end
        end
    end
end

-- A new link decision (planned raid occurrence id or nil, at plAt): another raid (or none) drops the old one's sign-ups.
local function SetLink(rec, pl, plAt)
    if pl ~= rec.pl then DropSignups(rec, rec.plAt) end
    rec.pl, rec.plAt = pl, plAt
    -- 1.3.5: who is expected, saved when the raid gets its planned raid (at the start, or a relink)
    local Att = ns.Attendance
    if Att and Att.Snapshot then Att:Snapshot(rec) end
end

local function Open(session)
    local raids = RaidsDB()
    if not raids then return nil end
    local rec = raids[session.id]
    if type(rec) ~= "table" or rec.del then
        rec = { id = session.id, start = session.at, by = session.by, bosses = {}, att = {},
            last = GetServerTime() }
        raids[session.id] = rec
        ns:Print("raid session started%s. The raid log is recording.",
            session.by and not Util.IsMe(session.by) and (" by " .. Util.ShortName(session.by)) or "")
    elseif rec.stop then
        -- A session this client closed (e.g. it left the raid for a moment) is running again: reopen it.
        rec.stop, rec.endedBy, rec.autoEnded = nil, nil, nil
    end
    ns.db.raidCurrent = rec.id
    -- the session's link (1.3: rpAt without rp = unlinked on purpose)
    if session.rpAt and (tonumber(rec.plAt) or 0) < (tonumber(session.rpAt) or 0) then
        SetLink(rec, session.rp, session.rpAt)
    end
    Scan(rec)
    Changed(rec)
    return rec
end

-- Addendum J §61: at the end of a linked raid, the sign-ups are kept on the record (su: key -> status; the raid plan
-- drops them after 15 days, the reliability stats need them longer), and Bench sign-ups who never joined are marked
-- bench (counts as attending; edit time = the link time, so every recorder marks the same; a council edit wins).
local function SnapshotPlan(rec)
    local RP = ns.RaidPlan
    if not rec.pl or not (RP and RP.GetSignups) then return end
    -- 1.3.5: the expected list if it was never saved (the plan arrived late), and the sign-up notes / Absent answers
    local Att = ns.Attendance
    if Att and Att.Snapshot then
        if not rec.ex then Att:Snapshot(rec) end
        if Att.SnapshotNotes then Att:SnapshotNotes(rec) end
    end
    local signups = RP:GetSignups(rec.pl)
    if not next(signups) then return end
    rec.su = rec.su or {}
    for key, s in pairs(signups) do
        if not rec.su[key] then rec.su[key] = s.st end
        if s.st == "B" then
            rec.att = type(rec.att) == "table" and rec.att or {}
            local a = rec.att[key]
            if not a then
                rec.att[key] = { k = 0, b = true, bts = rec.plAt, c = s.c }   -- (never joined: no times)
            end
        end
    end
end

-- endedBy = the authority that ended it; nil = the safety net (stop = the last activity).
local function Close(rec, endedBy)
    if not rec or rec.stop then return end
    local now = GetServerTime()
    if endedBy then
        Scan(rec)
        rec.stop = now
        rec.endedBy = endedBy
    else
        rec.stop = math.max(tonumber(rec.last) or rec.start or now, rec.start or 0)
        rec.autoEnded = true
    end
    for _, a in pairs(rec.att or {}) do
        if not a.l and a.j then a.l = rec.stop end   -- (a bench mark of somebody who never joined has no times)
    end
    SnapshotPlan(rec)
    if ns.db and ns.db.raidCurrent == rec.id then ns.db.raidCurrent = nil end
    ns:Print("raid session ended%s.", endedBy and not Util.IsMe(endedBy) and (" by " .. Util.ShortName(endedBy)) or "")
    Changed(rec)
    RaidLog:OfferDigest()   -- council: fill each other's gaps now (§50)
end

-- Brings the open record in line with the authority's session.
local function Reconcile()
    if not ns.db then return end
    local rec = OpenRecord()
    if not IsInRaid() then
        if rec then Close(rec, nil) end
        return
    end
    local GR = ns.GroupRules
    if not GR then return end
    local status, from = GR:GetStatus()
    if status == "own" then return end      -- no authority rules known right now: wait
    local s = GR:GetSession()
    if s then
        if rec and rec.id ~= s.id then Close(rec, nil) end
        confirmed = s.id
        if not rec or rec.id ~= s.id then
            Open(s)
        elseif s.rpAt and (tonumber(rec.plAt) or 0) < s.rpAt then
            SetLink(rec, s.rp, s.rpAt)
            Changed(rec)
        end
    elseif rec then
        -- (1.3.3) ended while I was away: at its last activity, not now
        Close(rec, rec.id == confirmed and (from or Util.PlayerKey()) or nil)
    end
end

-- 1.3.4: a kill reaches the log three ways, since ENCOUNTER_END only comes to players in the instance and in the
-- fight when it ends (a released ghost misses it): the event, the boss's death in my combat log (one-creature
-- encounters only), and RLK from another member of the raid who saw it. Returns true when it was new.
local function RecordKill(enc, encounterName)
    if not enc then return false end
    local pulled = pulls[enc]
    pulls[enc] = nil
    local rec = OpenRecord()
    if not rec then return false end
    rec.bosses = type(rec.bosses) == "table" and rec.bosses or {}
    for _, b in ipairs(rec.bosses) do
        if b.enc == enc then return false end   -- already recorded (the same kill seen twice)
    end
    if type(encounterName) ~= "string" then
        local ref = ns.ItemDB and ns.ItemDB.GetBossByEncounter and ns.ItemDB:GetBossByEncounter(enc)
        encounterName = ref and ref.boss and ref.boss.name or nil
    end
    Scan(rec)
    local now = GetServerTime()
    local roster = Roster()
    local keys, off = {}, nil
    for key, m in pairs(roster) do
        keys[#keys + 1] = key
        local a = rec.att[key]
        if a then a.k = (tonumber(a.k) or 0) + 1 end
        if not m.online then
            off = off or {}
            off[key] = true
        end
    end
    tsort(keys)
    rec.bosses[#rec.bosses + 1] = { enc = enc, name = type(encounterName) == "string" and encounterName or nil,
        ts = now, roster = keys, off = off, dur = pulled and math.max(0, now - pulled) or nil }
    if ns.AzeroHideout and ns.AzeroHideout.Invalidate then ns.AzeroHideout.Invalidate() end
    rec.last = now
    Changed(rec)
    return true
end

-- Tells the raid about a kill I saw, so a member who missed it (dead, released, outside) records it too.
local function BroadcastKill(enc)
    local rec = OpenRecord()
    local Comm = ns.Comm
    if not (rec and IsInRaid() and Comm and Comm.Send) then return end
    if ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() then return end
    Comm:Send({ t = "RLK", e = enc, s = rec.id }, "RAID", nil, "alert")
end

local function OnEncounterEnd(_, encounterID, encounterName, _, _, success)
    local enc = tonumber(encounterID)
    if success ~= 1 and success ~= true then
        if enc then pulls[enc] = nil end
        return
    end
    if RecordKill(enc, encounterName) then BroadcastKill(enc) end
end

-- The boss of a one-creature encounter died in my combat log: a kill even when ENCOUNTER_END never came.
local function OnCombatLog()
    local _, sub, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    if sub ~= "UNIT_DIED" or not IsInRaid() then return end
    local ref = ns.ItemDB and ns.ItemDB.GetBossBySourceGUID and ns.ItemDB:GetBossBySourceGUID(destGUID)
    local boss = ref and ref.boss
    local enc = boss and tonumber(boss.encounterID)
    if not enc or type(boss.npcIDs) ~= "table" or #boss.npcIDs ~= 1 then return end
    if RecordKill(enc, boss.name) then BroadcastKill(enc) end
end

-- RLK {e, s}: a raid member saw the kill of encounter e during session s.
local function OnRaidKill(sender, msg, dist)
    if dist ~= "RAID" or type(msg) ~= "table" then return end
    local enc = tonumber(msg.e)
    local rec = OpenRecord()
    if not (enc and rec and msg.s == rec.id) then return end
    local key = Util.NormalizeName(sender)
    if not (key and Roster()[key]) then return end    -- only somebody in my raid
    local ref = ns.ItemDB and ns.ItemDB.GetBossByEncounter and ns.ItemDB:GetBossByEncounter(enc)
    if not ref then return end                        -- a known raid encounter only
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("RLK:" .. key, 5) then return end
    RecordKill(enc, ref.boss and ref.boss.name)
end

---------------------------------------------------------------------------
-- "No raid session" reminder (§48: forgot to start)
---------------------------------------------------------------------------

-- A boss pull in a raid instance without a session: the authority gets a chat reminder (a popup would get in the
-- way of the pull and the loot windows). A session started after a missed pull is backdated to when I entered
-- the instance.
local function OnEncounterStart(_, encounterID)
    local enc = tonumber(encounterID)
    if enc then pulls[enc] = GetServerTime() end           -- (every client times the fight: the kill's `dur`)
    if not (IsInRaid() and Util.InRaidInstance()) then return end
    local GR = ns.GroupRules
    if not (GR and GR:IsAuthority()) or GR:GetSession() then return end
    missedPull = true
    if GetTime() - promptedAt < PROMPT_SNOOZE then return end
    promptedAt = GetTime()
    ns:Print("no raid session is running, so this raid is not being logged. Type /dz raid start to start one.")
end

local function OnEnteringWorld()
    if IsInRaid() and Util.InRaidInstance() then
        if not zoneEnteredAt then zoneEnteredAt = GetServerTime() end
    else
        zoneEnteredAt = nil
        missedPull = false
    end
    ScheduleScan()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

-- The id of the raid session being recorded now, or nil.
function RaidLog:GetCurrentID()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    return rec and rec.id or nil
end

-- 1.3.5 (Core/Attendance.lua): the record being recorded now (stored table), or nil.
function RaidLog:GetOpenRecord()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    return rec and rec.id == confirmed and rec or nil
end

-- 1.3.5: a record's attendance fields were changed here (a decision, a mark, a reason): refresh, and offer my digest
-- to the other raid log members when the raid is over (so the change spreads now, not at the next login).
function RaidLog:NoteEdit(rec)
    Changed(rec)
    local demo = ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled()
    if type(rec) == "table" and rec.stop and not demo then
        Util.Debounce("raidlog-edit", 5, function() RaidLog:OfferDigest() end)
    end
end

RaidLog.JoinPieces = function(_, a, b) return JoinPieces(a, b) end
RaidLog.PIECE_JOIN = PIECE_JOIN

-- The open record when a new authority may resume it (I am in a raid and it was active recently), or nil:
-- { id, start, pl, plAt } (1.3: with its planned-raid link, so a resumed session keeps it; plAt without pl = unlinked
-- on purpose).
function RaidLog:GetResumable()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    if not rec then return nil end
    local last = tonumber(rec.last) or tonumber(rec.start) or 0
    if GetServerTime() - last > RESUME_MAX_IDLE then return nil end
    return { id = rec.id, start = rec.start, pl = rec.pl, plAt = tonumber(rec.plAt) }
end

-- Demo mode (Addendum I): the Raids tab and attendance read the demo raids instead of the saved ones.
local function DemoRaids()
    local Demo = ns.Demo
    if Demo and Demo.IsEnabled and Demo:IsEnabled() and Demo.GetRaidLog then return Demo:GetRaidLog() end
    return nil
end

function RaidLog:GetRaid(id)
    local demo = DemoRaids()
    if demo then
        for _, rec in ipairs(demo) do
            if rec.id == id then return rec end
        end
    end
    local raids = RaidsDB()
    local rec = raids and type(id) == "string" and raids[id] or nil
    if type(rec) == "table" and rec.del then return nil end   -- deleted (RaidLog:Delete)
    return rec
end

-- The raids of my current guild (and untagged ones), newest first. Stored tables: treat as read-only.
function RaidLog:GetRaids()
    local demo = DemoRaids()
    if demo then
        local out = {}
        for i, rec in ipairs(demo) do out[i] = rec end
        return out
    end
    local raids = RaidsDB()
    local out = {}
    if not raids then return out end
    local g = GuildKey()
    for _, rec in pairs(raids) do
        if type(rec) == "table" and not rec.del and (rec.g == nil or rec.g == g) then out[#out + 1] = rec end
    end
    tsort(out, function(a, b) return (a.start or 0) > (b.start or 0) end)
    return out
end

-- Number of bosses of a raid instance (distinct encounter ids in the item database), or nil when unknown.
local bossTotals = {}
function RaidLog:GetBossTotal(instID)
    instID = tonumber(instID)
    if not instID then return nil end
    if bossTotals[instID] == nil then
        local n, seen = 0, {}
        local raids = ns.ItemDB and ns.ItemDB.GetRaids and ns.ItemDB:GetRaids() or {}
        for _, raid in ipairs(raids) do
            if raid.instanceID == instID then
                for _, b in ipairs(raid.bosses or {}) do
                    local enc = tonumber(b.encounterID)
                    if enc and not b.isTrash and not seen[enc] then   -- (Chess drops a chest but is an encounter)
                        seen[enc] = true
                        n = n + 1
                    end
                end
            end
        end
        bossTotals[instID] = n > 0 and n or false
    end
    return bossTotals[instID] or nil
end

-- Loot Log entries of a raid (not voided, not dungeon loot), newest first: tagged with its id, or untagged ones
-- made while it ran.
-- How many bosses a record's night has: linked to a planned raid of several instances (1.3.2, e.g. Gruul + Mag), all
-- of theirs; else those of the instance it was recorded in (instID: where I stand, for the live session's bar). nil =
-- unknown.
function RaidLog:GetRecordBossTotal(rec, instID)
    local RP = ns.RaidPlan
    local v = type(rec) == "table" and rec.pl and RP and RP.GetRaid and RP:GetRaid(rec.pl)
    local keys = v and RP.GetRaidInstances and RP:GetRaidInstances(v) or {}
    if #keys > 1 then
        local n = 0
        for _, key in ipairs(keys) do
            local inst = RP:GetInstance(key)
            n = n + (inst and inst.instID and self:GetBossTotal(inst.instID) or 0)
        end
        if n > 0 then return n end
    end
    return self:GetBossTotal(instID or (type(rec) == "table" and rec.instID))
end

function RaidLog:GetAwards(rec)
    local out = {}
    if type(rec) == "table" and rec.demoAwards then
        for i, e in ipairs(rec.demoAwards) do out[i] = e end
        tsort(out, function(a, b) return a.ts > b.ts end)
        return out
    end
    local Ledger = ns.Ledger
    if type(rec) ~= "table" or not (Ledger and Ledger.GetEntries) then return out end
    local from, to = rec.start or 0, rec.stop or GetServerTime()
    -- (1.3.5: a night of several logged raids, Attendance:NightView: the awards of each)
    local ids = {}
    for _, id in ipairs(rec.ids or { rec.id }) do ids[id] = true end
    for _, e in ipairs(Ledger:GetEntries({ excludeDungeon = true }) or {}) do
        if (e.rid and ids[e.rid]) or (e.rid == nil and e.ts >= from and e.ts <= to) then out[#out + 1] = e end
    end
    return out
end

-- Council: mark a player as bench / standby for a raid (counts as attending), or clear it.
function RaidLog:SetBench(id, key, on)
    if not DemoRaids() and not IsPlanner(Util.PlayerKey()) then return false end
    local rec = self:GetRaid(id)
    if DemoRaids() and rec and not tostring(rec.id):find("^demo") then return false end   -- demo: demo raids only
    key = Util.NormalizeName(key)
    if not rec or not key then return false end
    rec.att = type(rec.att) == "table" and rec.att or {}
    local a = rec.att[key]
    if on then
        if not a then
            a = { k = 0 }   -- (never joined: no times)
            rec.att[key] = a
        end
        a.b = true
    elseif a then
        a.b = nil
        if NeverJoined(rec, a) then rec.att[key] = nil end
    end
    a = rec.att[key]
    if a then
        -- edit time (merge rule: the newer edit wins, §50); never the link time, which marks the bench marks made from
        -- the sign-ups (DropSignups)
        local t = GetServerTime()
        if t == tonumber(rec.plAt) then t = t + 1 end
        a.bts = t
    end
    Changed(rec)
    return true
end

-- The GM and the guild council may delete logged raids (raid leaders can't). Peers take a deletion only from them.
local function IsDeleter(key)
    local Guild = ns.Guild
    return Guild and Guild.IsGuildCouncil and type(key) == "string" and Guild:IsGuildCouncil(key) and true or false
end

function RaidLog:CanDelete()
    return not DemoRaids() and IsDeleter(Util.PlayerKey())
end

-- Deletes a closed raid: the record becomes a tombstone ({ del, delAt, delBy }, no attendance or kills) that
-- spreads through the raid log sync, so the raid goes away for every raid planner and doesn't come back from a
-- peer who still has it. Awards stay in the Loot Log. Returns ok, err.
function RaidLog:Delete(id)
    if not self:CanDelete() then return false, "Only the Guild Master and the guild council can delete a logged raid." end
    local raids = RaidsDB()
    local rec = raids and type(id) == "string" and raids[id]
    if type(rec) ~= "table" or rec.del then return false, "That raid is no longer in the log." end
    if not rec.stop then return false, "This raid is still running. End it first." end
    raids[id] = { id = id, start = rec.start, stop = rec.stop, g = rec.g, del = true, delAt = GetServerTime(),
                  delBy = Util.PlayerKey() }
    Changed(raids[id])
    self:OfferDigest()
    return true
end

-- Addendum J §61, raid log members: link a logged raid to a planned raid (occurrence id; nil = not linked). A relink
-- replaces the record's sign-ups (and the bench marks made from them) with the new raid's, an unlink clears them.
-- 1.3: the raid running now is relinked through its session, for the whole raid (GroupRules:RequestSessionPlan).
function RaidLog:SetPlanned(id, occId)
    local rec = self:GetRaid(id)
    if not rec or DemoRaids() or not IsPlanner(Util.PlayerKey()) then return false end
    if occId ~= nil and not (type(occId) == "string" and #occId <= 40 and occId:find("^[%w#]+$")) then return false end
    if not rec.stop and ns.db and ns.db.raidCurrent == rec.id then
        local GR = ns.GroupRules
        local s = GR and GR.GetSession and GR:GetSession()
        local ok, err = false, "the raid's session isn't known right now; try again in a moment."
        if s and s.id == rec.id then ok, err = GR:RequestSessionPlan(occId) end
        if not ok and err then ns:Print("%s", tostring(err)) end
        return ok and true or false
    end
    if rec.pl == occId and (occId ~= nil or rec.plAt) then return true end
    SetLink(rec, occId, GetServerTime())
    if rec.stop and occId then SnapshotPlan(rec) end
    Changed(rec)
    return true
end

-- Addendum J §61: sign-up reliability over the last `lastN` closed raids linked to a planned raid, with sign-ups on
-- record: accepted = raids they answered Accept, came = of those, raids they attended (or were marked bench for); also
-- tentative / absent counts. nil when no such raid.
function RaidLog:GetReliability(key, lastN)
    key = Util.NormalizeName(key)
    if not key then return nil end
    lastN = lastN or 8
    local out = { raids = 0, accepted = 0, came = 0, tentative = 0, absent = 0, noShows = {} }
    for _, rec in ipairs(self:GetRaids()) do
        if rec.stop and rec.pl and rec.su then
            out.raids = out.raids + 1
            local st = rec.su[key]
            local present = rec.att and rec.att[key] ~= nil
            if st == "A" then
                out.accepted = out.accepted + 1
                if present then out.came = out.came + 1 else out.noShows[#out.noShows + 1] = rec end
            elseif st == "T" then
                out.tentative = out.tentative + 1
            elseif st == "X" then
                out.absent = out.absent + 1
            end
            if out.raids >= lastN then break end
        end
    end
    if out.raids == 0 then return nil end
    return out
end

-- "came to 7 of 8 accepted raids" or nil.
function RaidLog:GetReliabilityText(key, lastN)
    local r = self:GetReliability(key, lastN)
    if not r or r.accepted == 0 then return nil end
    return ("came to %d of %d accepted raids"):format(r.came, r.accepted)
end

-- Per-player totals over the `lastN` most recent raids (nil = all): { key, class, raids, total, pct, kills,
-- killTotal, bench, items, lastItem = entry } sorted by attendance, then name. Items = awards that count as
-- loot received, over the same raids.
function RaidLog:GetPlayerStats(lastN)
    local raids = self:GetRaids()
    if lastN and #raids > lastN then
        local cut = {}
        for i = 1, lastN do cut[i] = raids[i] end
        raids = cut
    end
    local stats, byKey = {}, {}
    local killTotal = 0
    local function S(key)
        local s = byKey[key]
        if not s then
            s = { key = key, raids = 0, kills = 0, bench = 0, items = 0 }
            byKey[key] = s
            stats[#stats + 1] = s
        end
        return s
    end
    for _, rec in ipairs(raids) do
        killTotal = killTotal + #(rec.bosses or {})
        for key, a in pairs(rec.att or {}) do
            local s = S(key)
            s.raids = s.raids + 1
            s.kills = s.kills + (tonumber(a.k) or 0)
            if a.b then s.bench = s.bench + 1 end
            if a.c then s.class = a.c end
        end
        for _, e in ipairs(self:GetAwards(rec)) do
            if not e.vd then
                local r = ns.AWARD_REASON and e.r and ns.AWARD_REASON[e.r]
                if not r or r.counts then
                    local s = S(e.w)
                    s.items = s.items + 1
                    if not s.lastItem or e.ts > s.lastItem.ts then s.lastItem = e end
                end
            end
        end
    end
    for _, s in ipairs(stats) do
        s.total = #raids
        s.killTotal = killTotal
        s.pct = #raids > 0 and floor(s.raids * 100 / #raids + 0.5) or 0
    end
    tsort(stats, function(a, b)
        if a.pct ~= b.pct then return a.pct > b.pct end
        return a.key < b.key
    end)
    return stats, #raids
end

-- "Attendance 92% (7 of the last 8)" for one player: pct, counted, of; nil when no raid is logged. Only closed
-- raids count. Cached (rebuilt after any raid log change): the drop panel and council views ask per row.
-- 1.3.5: the time-based attendance (Core/Attendance.lua): pct = the average credit over the raids of the last lastN
-- that expected the player and count, counted = how many, of = the raids looked at; nil when none expected them.
function RaidLog:GetAttendance(key, lastN)
    key = Util.NormalizeName(key)
    lastN = lastN or 8
    if not key then return nil end
    local Att = ns.Attendance
    if Att and Att.GetSummary then
        local s, n = Att:GetSummary(key, lastN)
        if not (s and s.pct) then return nil end
        return s.pct, s.counted, n
    end
    local c = attCache[lastN]
    local demo = DemoRaids() ~= nil
    if not c or c.g ~= GuildKey() or c.demo ~= demo then
        c = { g = GuildKey(), demo = demo, n = 0, by = {} }
        for _, rec in ipairs(self:GetRaids()) do
            if rec.stop then
                c.n = c.n + 1
                for k in pairs(rec.att or {}) do c.by[k] = (c.by[k] or 0) + 1 end
                if c.n >= lastN then break end
            end
        end
        attCache[lastN] = c
    end
    if c.n == 0 then return nil end
    local a = c.by[key] or 0
    return floor(a * 100 / c.n + 0.5), a, c.n
end

-- "92% (7 raids)" or nil (1.3.5: the raids that expected them; was "92% (7/8)").
function RaidLog:GetAttendanceText(key, lastN)
    local pct, a = self:GetAttendance(key, lastN)
    if not pct then return nil end
    return ("%d%% (%d %s)"):format(pct, a, a == 1 and "raid" or "raids")
end

-- startAt (optional): an earlier start time; default = now, or my instance entry after a missed boss pull.
-- features (optional): { loot=, rolls=, lock= }, what the session runs; default = what I picked the last time in
-- the Start raid window (everything, the first time).
function RaidLog:Start(startAt, features)
    local GR = ns.GroupRules
    if not GR then return false end
    if not startAt and missedPull then startAt = zoneEnteredAt end
    if features == nil then features = ns.db and ns.db.settings and ns.db.settings.raidStart end
    local ok, err = GR:SetSession(true, startAt, features)
    if not ok then ns:Print("%s", tostring(err)) end
    return ok
end

function RaidLog:End()
    local GR = ns.GroupRules
    if not GR then return false end
    local ok, err = GR:SetSession(false)
    if not ok then ns:Print("%s", tostring(err)) end
    return ok
end

---------------------------------------------------------------------------
-- Retention
---------------------------------------------------------------------------

function RaidLog:Prune(now)
    local raids = RaidsDB()
    if not raids then return end
    now = now or GetServerTime()
    local keepDays = tonumber(ns.DB and ns.DB.GetSetting and ns.DB:GetSetting("raidlog.keepDays")) or 365
    for id, rec in pairs(raids) do
        if type(rec) ~= "table" or type(rec.start) ~= "number" then
            raids[id] = nil
        elseif rec.stop and now - rec.start > keepDays * DAY then
            raids[id] = nil
        else
            if now - rec.start > ROSTER_KEEP_DAYS * DAY then
                for _, b in ipairs(rec.bosses or {}) do
                    b.roster, b.off = nil, nil
                end
            end
            if rec.su and not rec.pl and not rec.del then rec.su = nil end   -- 1.3: sign-ups only with a link
        end
    end
end

---------------------------------------------------------------------------
-- Slash: /dz raid start | end | status
---------------------------------------------------------------------------

local function FormatDuration(sec)
    sec = floor(math.max(0, sec or 0))
    return ("%d:%02d:%02d"):format(floor(sec / 3600), floor(sec % 3600 / 60), sec % 60)
end

local function SlashRaid(rest)
    local cmd = (rest or ""):match("^(%S*)"):lower()
    if cmd == "start" then
        if ns.GroupRules and ns.GroupRules:GetSession() then
            ns:Print("a raid session is already running.")
            return
        end
        RaidLog:Start()
    elseif cmd == "options" or cmd == "features" then
        if ns.SessionBar and ns.SessionBar.OpenOptions then ns.SessionBar:OpenOptions() end
    elseif cmd == "end" or cmd == "stop" then
        if not (ns.GroupRules and ns.GroupRules:GetSession()) then
            ns:Print("no raid session is running.")
            return
        end
        RaidLog:End()
    else
        local rec = OpenRecord()
        if rec then
            ns:Print("raid session: %s, %s, %d boss(es), %d raider(s).", rec.zone or "zone not seen yet",
                FormatDuration(GetServerTime() - (rec.start or GetServerTime())), #(rec.bosses or {}), Util.Count(rec.att or {}))
        else
            ns:Print("no raid session is running. /dz raid start (raid leader) starts one.")
        end
    end
end

---------------------------------------------------------------------------
-- Council sync (§50): per-week digests of closed raids (H / M field rd, and RLD after a raid ends), RLW = the
-- weeks a peer wants, RLG = one record per message. Guild-wide council members only (like the Ledger's LW / LG). The
-- merge is a commutative union, so both sides settle on the same record and the digests match afterwards.
-- Open records (a raid still running here) are not synced; the window (80 days) stays inside the 90 days after
-- which per-boss rosters are pruned, so a pruned record never gets its rosters back from a peer.
---------------------------------------------------------------------------

local WEEK = 7 * DAY
local SYNC_DAYS = 80
local MAX_WEEKS_PER_RW = 12
local MAX_ATT = 80
local MAX_BOSSES = 40
local MAX_ROSTER = 40
local MAX_KEY_LEN = 64
local MAX_NAME_LEN = 64
local MAX_TS = 4102444800
local FUTURE_SLACK = 300
local RD_DELAY_MIN, RD_DELAY_MAX = 3, 15

local function IsInt(n, lo, hi)
    return type(n) == "number" and n == floor(n) and n >= lo and n <= hi
end

local function IsKey(s)
    return type(s) == "string" and s ~= "" and #s <= MAX_KEY_LEN and not s:find("[%c|]")
end

local function DemoOn()
    return ns.Demo and ns.Demo.IsEnabled and ns.Demo:IsEnabled() or false
end

local function IsGuildCouncil(key)
    local Guild = ns.Guild
    return Guild and Guild.IsGuildCouncil and type(key) == "string" and Guild:IsGuildCouncil(key) and true or false
end

local function IsGuildCouncilPair(sender)
    local me = Util.PlayerKey()
    return me ~= nil and IsReader(me) and IsReader(sender)
end

local function SendTo(msg, target, class)
    local Comm = ns.Comm
    if DemoOn() or not (Comm and Comm.Send) then return false end
    return Comm:Send(msg, "WHISPER", target, class)
end

-- 1.3.5: a record's attendance fields (Core/Attendance.lua) for the hash: presence pieces, who was expected and
-- when, sign-up notes, the raid leader's marks, own reasons, decisions and chat lines picked.
local function AttendanceHash(rec)
    local function flat(map, fields)
        local out = {}
        for key, v in pairs(map or {}) do
            local parts = { key }
            for i, f in ipairs(fields) do
                local x = v[f]
                if type(x) == "table" then
                    local l = {}
                    for _, line in ipairs(x) do l[#l + 1] = (line.t or "") .. "@" .. (line.ch or "") .. (line.at or 0) end
                    x = table.concat(l, "~")
                end
                parts[i + 1] = tostring(x == nil and "" or x)
            end
            out[#out + 1] = table.concat(parts, ";")
        end
        tsort(out)
        return table.concat(out, "|")
    end
    local pieces = {}
    for key, a in pairs(rec.att or {}) do
        if a.s then pieces[#pieces + 1] = key .. "=" .. table.concat(a.s, ",") .. (a.o and ("o" .. a.o) or "") end
    end
    tsort(pieces)
    local ex = {}
    for key, k in pairs(rec.ex or {}) do ex[#ex + 1] = key .. "=" .. k end
    tsort(ex)
    return Util.Hash({ table.concat(pieces, "|"), table.concat(ex, ","), rec.exAt or 0, rec.ef or 0, rec.et or 0,
        flat(rec.sn, { "n", "x", "at", "lc" }), flat(rec.mk, { "b", "sw", "rm", "od", "by", "at" }),
        flat(rec.rs, { "c", "n", "at" }), flat(rec.dc, { "d", "by", "at", "n" }), flat(rec.q, { "by", "at", "l" }) })
end

-- The merge-relevant content of a record (what the digest covers). v2 (1.3.5) also covers the attendance fields;
-- the plain hash is what a client before 1.3.5 computes (it drops those fields), for comparing digests with one.
local function RecordHash(rec, v2)
    if rec.del then return Util.Hash({ "del", rec.delAt or 0, rec.delBy or "" }) end
    local att = {}
    for key, a in pairs(rec.att or {}) do
        att[key] = { a.j or 0, a.l or 0, a.k or 0, a.b and 1 or 0, a.bts or 0 }
    end
    if v2 then
        local bosses = {}
        for i, b in ipairs(rec.bosses or {}) do
            bosses[i] = { b.enc or 0, b.ts or 0, b.roster and table.concat(b.roster, ",") or "", b.dur or 0 }
        end
        local su = {}
        for key, st in pairs(rec.su or {}) do su[#su + 1] = key .. "=" .. st end
        tsort(su)
        return Util.Hash({ rec.start or 0, rec.stop or 0, rec.endedBy or "", rec.zone or "", att, bosses, rec.pl or "",
                           rec.plAt or 0, table.concat(su, ","), AttendanceHash(rec) })
    end
    local bosses = {}
    for i, b in ipairs(rec.bosses or {}) do
        bosses[i] = { b.enc or 0, b.ts or 0, b.roster and table.concat(b.roster, ",") or "", b.dur or 0 }
    end
    local su = {}
    for key, st in pairs(rec.su or {}) do su[#su + 1] = key .. "=" .. st end
    tsort(su)
    return Util.Hash({ rec.start or 0, rec.stop or 0, rec.endedBy or "", rec.zone or "", att, bosses, rec.pl or "",
                       rec.plAt or 0, table.concat(su, ",") })
end

local function Syncable(rec, g, minTs)
    return type(rec) == "table" and rec.stop and (rec.g == g) and type(rec.start) == "number" and rec.start >= minTs
end

-- { [week] = checksum } of my closed raids of the last SYNC_DAYS (my current guild only). 1.3.5: v = 2, the checksums
-- cover the attendance fields too (older clients skip the v key: not a week); legacy = true: the checksums a client
-- before 1.3.5 makes, to compare with its digest.
function RaidLog:GetDigest(legacy)
    local out = {}
    local raids = RaidsDB()
    local g = GuildKey()
    if not raids or not g then return out end
    local minTs = GetServerTime() - SYNC_DAYS * DAY
    local perWeek = {}
    for id, rec in pairs(raids) do
        if Syncable(rec, g, minTs) then
            local wk = floor(rec.start / WEEK)
            perWeek[wk] = perWeek[wk] or {}
            local list = perWeek[wk]
            list[#list + 1] = id .. ":" .. RecordHash(rec, not legacy)
        end
    end
    for wk, list in pairs(perWeek) do
        tsort(list)
        out[wk] = Util.Hash(list)
    end
    if not legacy then out.v = 2 end
    return out
end

-- 1.3.5: presence pieces from the wire: whole numbers, in order, from <= to, at most MAX_PIECES; nil when none.
local function CleanPieces(s)
    if type(s) ~= "table" or #s < 2 or #s > 2 * MAX_PIECES or #s % 2 ~= 0 then return nil end
    local out, prev = {}, 0
    for i = 1, #s, 2 do
        local f, t = s[i], s[i + 1]
        if not (IsInt(f, prev, MAX_TS) and IsInt(t, f, MAX_TS)) then return nil end
        out[i], out[i + 1], prev = f, t, t
    end
    return out
end

-- A short plain text (a note, a reason, a chat line): at most `max` characters, no control or escape codes.
local function CleanText(s, max)
    if type(s) ~= "string" or s == "" or #s > (max or 200) or s:find("[%c|]") then return nil end
    return s
end

local CHAT_KINDS = { Raid = true, Party = true, Guild = true, Whisper = true, Officer = true, Say = true }

-- 1.3.5: a record's attendance fields from the wire (Core/Attendance.lua), into `out`. Anything malformed is left out
-- (never the whole record: a newer client may send what this one doesn't know).
local function CleanAttendance(r, out, now)
    local function key(k) return IsKey(k) and Util.NormalizeName(k) or nil end
    local function stamp(t) return IsInt(t, 1, now + FUTURE_SLACK) and t or nil end
    local function each(map, fn)
        if type(map) ~= "table" then return nil end
        local res, n = {}, 0
        for k, v in pairs(map) do
            n = n + 1
            if n > MAX_ATT then break end
            local kk = key(k)
            local c = kk and type(v) == "table" and fn(v)
            if c then res[kk] = c end
        end
        return next(res) and res or nil
    end
    if out.pl then   -- (who was expected belongs to the planned raid, like the sign-ups)
        local n = 0
        for k, kind in pairs(type(r.ex) == "table" and r.ex or {}) do
            n = n + 1
            if n > MAX_ATT then break end
            local kk = key(k)
            if kk and (kind == "l" or kind == "a") then
                out.ex = out.ex or {}
                out.ex[kk] = kind
            end
        end
        if out.ex then
            out.exAt = stamp(r.exAt)
            out.ef = IsInt(r.ef, 1, MAX_TS) and r.ef or nil
            out.et = out.ef and IsInt(r.et, out.ef, MAX_TS) and r.et or nil
        end
        out.sn = each(r.sn, function(v)
            local c = { n = CleanText(v.n, 120), x = v.x == true or nil, at = stamp(v.at), lc = v.lc == true or nil }
            return (c.n or c.x) and c or nil
        end)
    end
    out.mk = each(r.mk, function(v)
        local at = stamp(v.at)
        if not at then return nil end
        return { b = v.b == true or nil, sw = key(v.sw), rm = v.rm == true or nil, od = v.od == true or nil,
                 by = key(v.by), at = at }
    end)
    out.rs = each(r.rs, function(v)
        local at = stamp(v.at)
        local c = type(v.c) == "string" and #v.c <= 16 and v.c:find("^%a+$") and v.c or nil
        if not at or not (c or v.n) then return nil end
        return { c = c, n = CleanText(v.n), at = at }
    end)
    out.dc = each(r.dc, function(v)
        local at, by = stamp(v.at), key(v.by)
        -- (1.3.5: "u" = a decision taken back, newer than the one it undoes, so the undo spreads too)
        if not (at and by and (v.d == "x" or v.d == "c" or v.d == "u")) then return nil end
        return { d = v.d, by = by, at = at, n = CleanText(v.n) }
    end)
    out.q = each(r.q, function(v)
        local at, by = stamp(v.at), key(v.by)
        if not (at and by and type(v.l) == "table") then return nil end
        local lines = {}
        for i = 1, 5 do
            local line = v.l[i]
            if type(line) ~= "table" then break end
            local t, at2 = CleanText(line.t), stamp(line.at)
            if t and at2 and CHAT_KINDS[line.ch] then lines[#lines + 1] = { t = t, ch = line.ch, at = at2 } end
        end
        return { by = by, at = at, l = lines }
    end)
end

-- Validates an untrusted record: a clean copy or nil.
local function CleanRecord(r, now)
    if type(r) ~= "table" or not IsKey(r.id) then return nil end
    if not IsInt(r.start, 1, now + FUTURE_SLACK) or not IsInt(r.stop, r.start, now + FUTURE_SLACK) then return nil end
    if r.del == true then                                   -- a deleted raid: nothing else is kept
        if not IsInt(r.delAt, 1, now + FUTURE_SLACK) or not IsKey(r.delBy) then return nil end
        return { id = r.id, start = r.start, stop = r.stop, del = true, delAt = r.delAt,
                 delBy = Util.NormalizeName(r.delBy) }
    end
    local out = { id = r.id, start = r.start, stop = r.stop, bosses = {}, att = {} }
    if IsKey(r.by) then out.by = Util.NormalizeName(r.by) end
    if IsKey(r.endedBy) then out.endedBy = Util.NormalizeName(r.endedBy) end
    if r.autoEnded == true and not out.endedBy then out.autoEnded = true end
    if type(r.zone) == "string" and #r.zone <= MAX_NAME_LEN and not r.zone:find("[%c|]") then out.zone = r.zone end
    if IsInt(r.instID, 1, 100000) then out.instID = r.instID end
    if type(r.pl) == "string" and #r.pl <= 40 and r.pl:find("^[%w#]+$") and IsInt(r.plAt, 1, now + FUTURE_SLACK) then
        out.pl, out.plAt = r.pl, r.plAt
    elseif r.pl == nil and IsInt(r.plAt, 1, now + FUTURE_SLACK) then
        out.plAt = r.plAt                                   -- unlinked by the council
    end
    if type(r.su) == "table" and out.pl then                -- (1.3: sign-ups belong to a link)
        local n = 0
        for key, st in pairs(r.su) do
            n = n + 1
            if n > MAX_ATT then break end
            local k = IsKey(key) and Util.NormalizeName(key)
            if k and (st == "A" or st == "T" or st == "B" or st == "X") then
                out.su = out.su or {}
                out.su[k] = st
            end
        end
    end
    if type(r.att) ~= "table" then return nil end
    local n = 0
    for key, a in pairs(r.att) do
        n = n + 1
        if n > MAX_ATT then return nil end
        local k = IsKey(key) and Util.NormalizeName(key)
        if k and type(a) == "table" then
            local c = {}
            if IsInt(a.j, 0, MAX_TS) then c.j = a.j end
            if IsInt(a.l, 0, MAX_TS) then c.l = a.l end
            c.k = IsInt(a.k, 0, MAX_BOSSES) and a.k or 0
            if a.b == true then c.b = true end
            if IsInt(a.bts, 0, now + FUTURE_SLACK) then c.bts = a.bts end
            if IsInt(a.o, 1, 86400) then c.o = a.o end   -- 1.3.5: seconds outside the instance
            if type(a.c) == "string" and a.c:find("^%u+$") and #a.c <= 16 then c.c = a.c end
            local s = CleanPieces(a.s)
            if s then c.s = s end
            out.att[k] = c
        end
    end
    CleanAttendance(r, out, now)
    if type(r.bosses) ~= "table" or #r.bosses > MAX_BOSSES then return nil end
    for _, b in ipairs(r.bosses) do
        if type(b) == "table" and IsInt(b.enc, 1, 100000) and IsInt(b.ts, 0, now + FUTURE_SLACK) then
            local c = { enc = b.enc, ts = b.ts }
            if IsInt(b.dur, 0, 86400) then c.dur = b.dur end
            if type(b.name) == "string" and #b.name <= MAX_NAME_LEN and not b.name:find("[%c|]") then c.name = b.name end
            if type(b.roster) == "table" and #b.roster <= MAX_ROSTER then
                c.roster = {}
                for _, key in ipairs(b.roster) do
                    local k = IsKey(key) and Util.NormalizeName(key)
                    if k then c.roster[#c.roster + 1] = k end
                end
            end
            if type(b.off) == "table" then
                for key, v in pairs(b.off) do
                    local k = v == true and IsKey(key) and Util.NormalizeName(key)
                    if k then
                        c.off = c.off or {}
                        c.off[k] = true
                    end
                end
            end
            out.bosses[#out.bosses + 1] = c
        end
    end
    return out
end

local function UnionSorted(a, b)
    local set, out = {}, {}
    for _, k in ipairs(a or {}) do set[k] = true end
    for _, k in ipairs(b or {}) do set[k] = true end
    for k in pairs(set) do out[#out + 1] = k end
    tsort(out)
    return out
end

local function MinN(a, b) if a and b then return math.min(a, b) end return a or b end
local function MaxN(a, b) if a and b then return math.max(a, b) end return a or b end

-- Merges a clean peer record into mine (commutative). Returns true when mine changed.
local function MergeRecord(cur, e)
    local before = RecordHash(cur, true)
    -- the planned-raid link: the newer decision wins (the same time: the larger id, so both sides agree). 1.3: the
    -- sign-ups (su) and the bench marks made from them belong to a link: two copies of the same link are joined, else the
    -- winning link's come along and the other link's are dropped (loseAt: the losing link's time in e's bench marks).
    local cp, ep = tonumber(cur.plAt) or 0, tonumber(e.plAt) or 0
    local eWins = ep > cp or (ep == cp and ep > 0 and (e.pl or "") > (cur.pl or ""))
    local loseAt
    if (e.pl or "") == (cur.pl or "") then
        if eWins then cur.plAt = e.plAt end
        if e.su then
            cur.su = cur.su or {}
            for key, st in pairs(e.su) do
                if not cur.su[key] or st > cur.su[key] then cur.su[key] = st end
            end
        end
        -- 1.3.5: who was expected: the later snapshot wins; two of the same time are joined
        if e.ex then
            local ca, ea = tonumber(cur.exAt) or 0, tonumber(e.exAt) or 0
            if not cur.ex or ea > ca then
                cur.ex, cur.exAt, cur.ef, cur.et = Util.CopyTable(e.ex), e.exAt, e.ef, e.et
            elseif ea == ca then
                for key, kind in pairs(e.ex) do
                    if not cur.ex[key] or kind == "l" then cur.ex[key] = kind end
                end
                cur.ef = MinN(cur.ef, e.ef)
                cur.et = MaxN(cur.et, e.et)
            end
        end
        for key, v in pairs(e.sn or {}) do
            cur.sn = cur.sn or {}
            local c = cur.sn[key]
            if not c or (v.at or 0) > (c.at or 0) then cur.sn[key] = v end
        end
    elseif eWins then
        DropSignups(cur, cp)
        cur.pl, cur.plAt = e.pl, e.plAt
        cur.su = e.su and Util.CopyTable(e.su) or nil
        cur.ex, cur.exAt, cur.ef, cur.et = e.ex and Util.CopyTable(e.ex) or nil, e.exAt, e.ef, e.et
        cur.sn = e.sn and Util.CopyTable(e.sn) or nil
    else
        loseAt = ep > 0 and ep or nil
    end
    if not cur.pl then cur.su = nil end
    cur.start = MinN(cur.start, e.start)
    -- The end: an explicit End beats the safety net; two of a kind settle on the later one (then the smaller key).
    local cx, ex = cur.endedBy ~= nil, e.endedBy ~= nil
    if ex and not cx then
        cur.stop, cur.endedBy, cur.autoEnded = e.stop, e.endedBy, nil
    elseif ex == cx then
        if e.stop > cur.stop or (e.stop == cur.stop and ex and e.endedBy < cur.endedBy) then
            cur.stop, cur.endedBy = e.stop, e.endedBy
        end
    end
    if not cur.zone and e.zone then cur.zone, cur.instID = e.zone, e.instID end
    if not cur.by and e.by then cur.by = e.by end
    cur.att = type(cur.att) == "table" and cur.att or {}
    for key, a in pairs(e.att) do
        local stale = loseAt and a.b and a.bts == loseAt   -- a bench mark from the losing link's sign-ups
        if stale then
            if NeverJoined(e, a) then
                a = nil
            else
                a.b, a.bts = nil, nil
            end
        end
        local c = a and cur.att[key]
        if not a then
            -- (nothing: the losing link's bench mark of somebody who never joined)
        elseif not c then
            cur.att[key] = a
        else
            c.j = MinN(c.j, a.j)
            c.l = MaxN(c.l, a.l)
            c.k = math.max(tonumber(c.k) or 0, a.k or 0)
            if not c.c then c.c = a.c end
            if a.s then c.s = JoinPieces(c.s, a.s) end   -- 1.3.5: what any recorder saw them there
            if a.o and (tonumber(c.o) or 0) < a.o then c.o = a.o end
            local cb, eb = c.bts or 0, a.bts or 0
            if eb > cb or (eb == cb and a.b and not c.b) then c.b, c.bts = a.b, a.bts end
        end
    end
    -- 1.3.5: the raid leader's marks, own reasons, decisions and picked chat lines: per player, the newest wins (the
    -- same time: the larger author, so both sides agree). A decision counts only from a reviewer.
    local Att = ns.Attendance
    for _, field in ipairs({ "mk", "rs", "dc", "q" }) do
        for key, v in pairs(e[field] or {}) do
            local ok = field ~= "dc" or not (Att and Att.CanReview) or Att:CanReview(v.by)
            local c = cur[field] and cur[field][key]
            if ok and (not c or v.at > (c.at or 0) or (v.at == c.at and (v.by or "") > (c.by or ""))) then
                cur[field] = cur[field] or {}
                cur[field][key] = v
            end
        end
    end
    cur.bosses = type(cur.bosses) == "table" and cur.bosses or {}
    local byEnc = {}
    for _, b in ipairs(cur.bosses) do byEnc[b.enc] = b end
    for _, b in ipairs(e.bosses) do
        local c = byEnc[b.enc]
        if not c then
            cur.bosses[#cur.bosses + 1] = b
            byEnc[b.enc] = b
        else
            c.ts = MinN(c.ts, b.ts)
            c.dur = MinN(c.dur, b.dur)
            if not c.name then c.name = b.name end
            if c.roster or b.roster then c.roster = UnionSorted(c.roster, b.roster) end
            if b.off then
                c.off = c.off or {}
                for k in pairs(b.off) do c.off[k] = true end
            end
        end
    end
    tsort(cur.bosses, function(a, b)
        if a.ts ~= b.ts then return a.ts < b.ts end
        return a.enc < b.enc
    end)
    return RecordHash(cur, true) ~= before
end

-- A peer's record (from RLG). Returns true when stored or changed.
function RaidLog:MergeRecord(r, fromKey)
    local now = GetServerTime()
    local e = CleanRecord(r, now)
    local raids = RaidsDB()
    local g = GuildKey()
    if not e or not raids or not g then
        ns:Debug("RaidLog: rejected record from %s", tostring(fromKey))
        return false
    end
    local cur = raids[e.id]
    -- a deletion counts when the GM or a guild council member sends it (1.3: whoever it names: a raid leader can't relay
    -- one that names a council member, and a deletion by someone who has left the council since still spreads)
    if e.del and not IsDeleter(fromKey) then
        ns:Debug("RaidLog: rejected deletion by %s from %s", tostring(e.delBy), tostring(fromKey))
        return false
    end
    if type(cur) ~= "table" then
        e.g = g
        raids[e.id] = e
        Changed(e)
        return true
    end
    if not cur.stop then return false end   -- still running here: my own recording goes on
    if cur.g ~= g then return false end
    -- deleted wins over the record; two deletions settle on the earlier one (then the smaller key)
    if cur.del then
        if e.del and (e.delAt < cur.delAt or (e.delAt == cur.delAt and e.delBy < cur.delBy)) then
            cur.delAt, cur.delBy = e.delAt, e.delBy
            return true
        end
        return false
    end
    if e.del then
        e.g = g
        raids[e.id] = e
        Changed(e)
        return true
    end
    local changed = MergeRecord(cur, e)
    if changed then Changed(cur) end
    return changed
end

-- Requests the weeks where the peer's digest differs from mine.
function RaidLog:SyncFromDigest(X, digest)
    if DemoOn() or type(X) ~= "string" or type(digest) ~= "table" or not IsGuildCouncilPair(X) then return end
    local mine = self:GetDigest(digest.v ~= 2)   -- (a client before 1.3.5: compare without the attendance fields)
    local nowWeek = floor(GetServerTime() / WEEK)
    local minWeek = floor((GetServerTime() - SYNC_DAYS * DAY) / WEEK)
    local weeks, seen = {}, 0
    for wk, h in pairs(digest) do
        seen = seen + 1
        if seen > 40 then break end
        if IsInt(wk, minWeek, nowWeek) and type(h) == "string" and #h <= 16 and mine[wk] ~= h then
            weeks[#weeks + 1] = wk
            if #weeks >= MAX_WEEKS_PER_RW then break end
        end
    end
    if #weeks == 0 then return end
    tsort(weeks)
    SendTo({ t = "RLW", w = weeks }, X, "ctrl")
end

local function OnRaidWant(sender, msg, dist)
    if dist ~= "WHISPER" or DemoOn() or not IsGuildCouncilPair(sender) then return end
    if type(msg) ~= "table" or type(msg.w) ~= "table" then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("RLW:" .. sender, 5) then return end
    local want = {}
    for k = 1, MAX_WEEKS_PER_RW do
        local wk = msg.w[k]
        if wk == nil then break end
        if IsInt(wk, 0, 100000) then want[wk] = true end
    end
    local raids = RaidsDB()
    local g = GuildKey()
    if not raids or not g then return end
    local minTs = GetServerTime() - SYNC_DAYS * DAY
    local list = {}
    for _, rec in pairs(raids) do
        if Syncable(rec, g, minTs) and want[floor(rec.start / WEEK)] then list[#list + 1] = rec end
    end
    tsort(list, function(a, b) return a.start > b.start end)
    for _, rec in ipairs(list) do
        local wire = {}
        for k, v in pairs(rec) do
            if k ~= "g" and k ~= "last" then wire[k] = v end
        end
        SendTo({ t = "RLG", r = wire }, sender, "data")
    end
end

local function OnRaidGive(sender, msg, dist)
    if dist ~= "WHISPER" or not IsGuildCouncilPair(sender) or type(msg) ~= "table" then return end
    RaidLog:MergeRecord(msg.r, sender)
end

-- RLD {rd, q}: a council member finished a raid and offers its digest (q = "answer with yours").
local function OnRaidDigest(sender, msg, dist)
    if dist ~= "WHISPER" or DemoOn() or not IsGuildCouncilPair(sender) or type(msg) ~= "table" then return end
    if type(msg.rd) ~= "table" then return end
    RaidLog:SyncFromDigest(sender, msg.rd)
    if msg.q then
        local Comm = ns.Comm
        if Comm and Comm.RateLimit and not Comm:RateLimit("RLDq:" .. sender, 30) then return end
        Util.RandomDelay(1, 4, function() SendTo({ t = "RLD", rd = RaidLog:GetDigest() }, sender, "ctrl") end)
    end
end

-- After a raid ends here: offer my digest to the online guild council (jittered: every recorder does this).
function RaidLog:OfferDigest()
    if DemoOn() or not IsReader(Util.PlayerKey()) then return end
    Util.RandomDelay(RD_DELAY_MIN, RD_DELAY_MAX, function()
        -- the online council peers and the online raid leaders (raid planners only)
        local targets, seen = {}, {}
        local Sync, Guild = ns.Sync, ns.Guild
        for _, key in ipairs(Sync and Sync.GetOnlineCouncilPeers and Sync:GetOnlineCouncilPeers() or {}) do
            if not seen[key] then seen[key] = true; targets[#targets + 1] = key end
        end
        for _, key in ipairs(Guild and Guild.GetRaidLeaders and Guild:GetRaidLeaders() or {}) do
            if not seen[key] and not Util.IsMe(key) and Guild:IsOnline(key) then
                seen[key] = true
                targets[#targets + 1] = key
            end
        end
        -- 1.3.5: the online officers (attendance reviewers)
        for _, key in ipairs(Guild and Guild.GetOnlineMembers and Guild:GetOnlineMembers() or {}) do
            if not seen[key] and not Util.IsMe(key) and Guild.IsOfficer and Guild:IsOfficer(key) then
                seen[key] = true
                targets[#targets + 1] = key
            end
        end
        local msg = { t = "RLD", rd = RaidLog:GetDigest(), q = true }
        for _, key in ipairs(targets) do
            if IsReader(key) then SendTo(msg, key, "ctrl") end
        end
    end)
end

-- Sync: a raid planner's HELLO digest (a raid leader who isn't council, or talking to one): pull what differs and
-- offer mine back.
function RaidLog:OnPlannerHello(sender, digest)
    if DemoOn() or type(digest) ~= "table" or not IsGuildCouncilPair(sender) then return end
    local Comm = ns.Comm
    if Comm and Comm.RateLimit and not Comm:RateLimit("RLH:" .. sender, 20) then return end
    Util.RandomDelay(1, 5, function()
        RaidLog:SyncFromDigest(sender, digest)
        SendTo({ t = "RLD", rd = RaidLog:GetDigest() }, sender, "ctrl")
    end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function RaidLog:OnInit()
    ns:On("GROUP_RULES_CHANGED", Reconcile)
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        if not IsInRaid() then Reconcile() end
        ScheduleScan()
    end)
    ns:RegisterEvent("ENCOUNTER_START", OnEncounterStart)
    ns:RegisterEvent("ENCOUNTER_END", OnEncounterEnd)
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", OnCombatLog)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("RLW", OnRaidWant)
        ns.Comm:Register("RLG", OnRaidGive)
        ns.Comm:Register("RLD", OnRaidDigest)
        ns.Comm:Register("RLK", OnRaidKill)
    end
    ns:RegisterSlash("raid", SlashRaid, "start | options | end | status - the raid session: loot, rolls and the raid log (raid leader)")
end

function RaidLog:OnLogin()
    self:Prune()
    local function Tick()
        local rec = OpenRecord()
        if rec and rec.id == confirmed and IsInRaid() then
            Scan(rec)
            Changed(rec)
        end
        Util.After(SCAN_INTERVAL, Tick)
    end
    Util.After(SCAN_INTERVAL, Tick)
end

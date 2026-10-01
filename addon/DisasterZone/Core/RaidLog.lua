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

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- Addendum J §62: raid log records (no items in them) are exchanged between raid planners: the GM, the guild
-- council and the raid leaders list.
local function IsPlanner(key)
    local Guild = ns.Guild
    return Guild and Guild.IsRaidLogMember and type(key) == "string" and Guild:IsRaidLogMember(key) and true or false
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

-- Updates attendance (joins / leaves) and the activity stamp from the live roster.
local function Scan(rec)
    if not rec then return end
    local now = GetServerTime()
    if not rec.g then rec.g = GuildKey() end
    local inside = NoteZone(rec)
    local roster = Roster()
    rec.att = type(rec.att) == "table" and rec.att or {}
    for key, m in pairs(roster) do
        local a = rec.att[key]
        if type(a) ~= "table" then
            a = { j = now, k = 0 }
            rec.att[key] = a
        end
        if m.class then a.c = m.class end
        a.l = nil   -- present (again)
        if m.online and rec.zone and m.zone == rec.zone then inside = true end
    end
    for key, a in pairs(rec.att) do
        if not roster[key] and not a.l and not a.b then a.l = now end
    end
    if inside then rec.last = now end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    Util.After(ROSTER_DELAY, function()
        scanPending = false
        local rec = OpenRecord()
        if rec then
            Scan(rec)
            Changed(rec)
        end
    end)
end

local function Open(session)
    local raids = RaidsDB()
    if not raids then return nil end
    local rec = raids[session.id]
    if type(rec) ~= "table" then
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
    if session.rp and (tonumber(rec.plAt) or 0) < (tonumber(session.rpAt) or 0) then
        rec.pl, rec.plAt = session.rp, session.rpAt
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
    local signups = RP:GetSignups(rec.pl)
    if not next(signups) then return end
    rec.su = rec.su or {}
    for key, s in pairs(signups) do
        if not rec.su[key] then rec.su[key] = s.st end
        if s.st == "B" then
            rec.att = type(rec.att) == "table" and rec.att or {}
            local a = rec.att[key]
            if not a then
                rec.att[key] = { j = rec.start, l = rec.stop, k = 0, b = true, bts = rec.plAt, c = s.c }
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
        if not a.l then a.l = rec.stop end
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
        if not rec or rec.id ~= s.id then
            Open(s)
        elseif s.rpAt and (tonumber(rec.plAt) or 0) < s.rpAt then
            rec.pl, rec.plAt = s.rp, s.rpAt
            Changed(rec)
        end
    elseif rec then
        Close(rec, from or Util.PlayerKey())
    end
end

local function OnEncounterEnd(_, encounterID, encounterName, _, _, success)
    local enc = tonumber(encounterID)
    local pulled = enc and pulls[enc]
    if enc then pulls[enc] = nil end
    if success ~= 1 and success ~= true then return end
    local rec = OpenRecord()
    if not rec then return end
    rec.bosses = type(rec.bosses) == "table" and rec.bosses or {}
    for _, b in ipairs(rec.bosses) do
        if b.enc == enc then return end   -- already recorded (the same kill seen twice)
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

-- The open record when a new authority may resume it (I am in a raid and it was active recently), or nil.
function RaidLog:GetResumable()
    if not IsInRaid() then return nil end
    local rec = OpenRecord()
    if not rec then return nil end
    local last = tonumber(rec.last) or tonumber(rec.start) or 0
    if GetServerTime() - last > RESUME_MAX_IDLE then return nil end
    return { id = rec.id, start = rec.start }
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
    return raids and type(id) == "string" and raids[id] or nil
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
        if type(rec) == "table" and (rec.g == nil or rec.g == g) then out[#out + 1] = rec end
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
    for _, e in ipairs(Ledger:GetEntries({ excludeDungeon = true }) or {}) do
        if e.rid == rec.id or (e.rid == nil and e.ts >= from and e.ts <= to) then out[#out + 1] = e end
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
            a = { j = rec.start, l = rec.stop, k = 0 }
            rec.att[key] = a
        end
        a.b = true
    elseif a then
        a.b = nil
        if (tonumber(a.k) or 0) == 0 and a.j == rec.start and a.l == rec.stop then rec.att[key] = nil end
    end
    a = rec.att[key]
    if a then a.bts = GetServerTime() end   -- edit time (merge rule: the newer edit wins, §50)
    Changed(rec)
    return true
end

-- Addendum J §61, council: link a logged raid to a planned raid (occurrence id; nil = not linked).
function RaidLog:SetPlanned(id, occId)
    local rec = self:GetRaid(id)
    if not rec or DemoRaids() or not IsPlanner(Util.PlayerKey()) then return false end
    if occId ~= nil and not (type(occId) == "string" and #occId <= 40 and occId:find("^[%w#]+$")) then return false end
    rec.pl, rec.plAt = occId, GetServerTime()
    if occId == nil then rec.su = nil end
    if rec.stop and occId then SnapshotPlan(rec) end
    Changed(rec)
    return true
end

-- Addendum J §61: sign-up reliability over the last `lastN` closed raids with sign-ups on record: accepted = raids
-- they answered Accept, came = of those, raids they attended (or were marked bench for); also tentative / absent
-- counts. nil when no such raid.
function RaidLog:GetReliability(key, lastN)
    key = Util.NormalizeName(key)
    if not key then return nil end
    lastN = lastN or 8
    local out = { raids = 0, accepted = 0, came = 0, tentative = 0, absent = 0, noShows = {} }
    for _, rec in ipairs(self:GetRaids()) do
        if rec.stop and rec.su then
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

-- "Attendance 92% (7 of the last 8)" for one player: pct, attended, of; nil when no raid is logged. Only closed
-- raids count. Cached (rebuilt after any raid log change): the drop panel and council views ask per row.
function RaidLog:GetAttendance(key, lastN)
    key = Util.NormalizeName(key)
    lastN = lastN or 8
    if not key then return nil end
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

-- "92% (7/8)" or nil.
function RaidLog:GetAttendanceText(key, lastN)
    local pct, a, n = self:GetAttendance(key, lastN)
    if not pct then return nil end
    return ("%d%% (%d/%d)"):format(pct, a, n)
end

-- startAt (optional): an earlier start time; default = now, or my instance entry after a missed boss pull.
function RaidLog:Start(startAt)
    local GR = ns.GroupRules
    if not GR then return false end
    if not startAt and missedPull then startAt = zoneEnteredAt end
    local ok, err = GR:SetSession(true, startAt)
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
        elseif now - rec.start > ROSTER_KEEP_DAYS * DAY then
            for _, b in ipairs(rec.bosses or {}) do
                b.roster, b.off = nil, nil
            end
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
    return me ~= nil and IsPlanner(me) and IsPlanner(sender)
end

local function SendTo(msg, target, class)
    local Comm = ns.Comm
    if DemoOn() or not (Comm and Comm.Send) then return false end
    return Comm:Send(msg, "WHISPER", target, class)
end

-- The merge-relevant content of a record (what the digest covers).
local function RecordHash(rec)
    local att = {}
    for key, a in pairs(rec.att or {}) do
        att[key] = { a.j or 0, a.l or 0, a.k or 0, a.b and 1 or 0, a.bts or 0 }
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

-- { [week] = checksum } of my closed raids of the last SYNC_DAYS (my current guild only).
function RaidLog:GetDigest()
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
            list[#list + 1] = id .. ":" .. RecordHash(rec)
        end
    end
    for wk, list in pairs(perWeek) do
        tsort(list)
        out[wk] = Util.Hash(list)
    end
    return out
end

-- Validates an untrusted record: a clean copy or nil.
local function CleanRecord(r, now)
    if type(r) ~= "table" or not IsKey(r.id) then return nil end
    if not IsInt(r.start, 1, now + FUTURE_SLACK) or not IsInt(r.stop, r.start, now + FUTURE_SLACK) then return nil end
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
    if type(r.su) == "table" then
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
            if type(a.c) == "string" and a.c:find("^%u+$") and #a.c <= 16 then c.c = a.c end
            out.att[k] = c
        end
    end
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
    local before = RecordHash(cur)
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
    -- the planned-raid link: the newer decision wins (the same time: the larger id, so both sides agree)
    local cp, ep = tonumber(cur.plAt) or 0, tonumber(e.plAt) or 0
    if ep > cp or (ep == cp and ep > 0 and (e.pl or "") > (cur.pl or "")) then cur.pl, cur.plAt = e.pl, e.plAt end
    if e.su then
        cur.su = cur.su or {}
        for key, st in pairs(e.su) do
            if not cur.su[key] or st > cur.su[key] then cur.su[key] = st end
        end
    end
    if not cur.by and e.by then cur.by = e.by end
    cur.att = type(cur.att) == "table" and cur.att or {}
    for key, a in pairs(e.att) do
        local c = cur.att[key]
        if not c then
            cur.att[key] = a
        else
            c.j = MinN(c.j, a.j)
            c.l = MaxN(c.l, a.l)
            c.k = math.max(tonumber(c.k) or 0, a.k or 0)
            if not c.c then c.c = a.c end
            local cb, eb = c.bts or 0, a.bts or 0
            if eb > cb or (eb == cb and a.b and not c.b) then c.b, c.bts = a.b, a.bts end
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
    return RecordHash(cur) ~= before
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
    if type(cur) ~= "table" then
        e.g = g
        raids[e.id] = e
        Changed(e)
        return true
    end
    if not cur.stop then return false end   -- still running here: my own recording goes on
    if cur.g ~= g then return false end
    local changed = MergeRecord(cur, e)
    if changed then Changed(cur) end
    return changed
end

-- Requests the weeks where the peer's digest differs from mine.
function RaidLog:SyncFromDigest(X, digest)
    if DemoOn() or type(X) ~= "string" or type(digest) ~= "table" or not IsGuildCouncilPair(X) then return end
    local mine = self:GetDigest()
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
    if DemoOn() or not IsPlanner(Util.PlayerKey()) then return end
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
        local msg = { t = "RLD", rd = RaidLog:GetDigest(), q = true }
        for _, key in ipairs(targets) do
            if IsPlanner(key) then SendTo(msg, key, "ctrl") end
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
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("RLW", OnRaidWant)
        ns.Comm:Register("RLG", OnRaidGive)
        ns.Comm:Register("RLD", OnRaidDigest)
    end
    ns:RegisterSlash("raid", SlashRaid, "start | end | status - the raid session and raid log (raid leader starts / ends)")
end

function RaidLog:OnLogin()
    self:Prune()
    local function Tick()
        local rec = OpenRecord()
        if rec and IsInRaid() then
            Scan(rec)
            Changed(rec)
        end
        Util.After(SCAN_INTERVAL, Tick)
    end
    Util.After(SCAN_INTERVAL, Tick)
end

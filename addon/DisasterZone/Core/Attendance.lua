if DisasterZoneBoot and DisasterZoneBoot.Run("Core/Attendance.lua", ...) then return end -- DisasterZone: Core/Attendance.lua
-- Time-based attendance (1.3.5, user decisions 2026-10-11). The raid log (Core/RaidLog.lua) records each player's
-- time online in the raid group as pieces (att[key].s); this module says who the raid expected, for how long, and
-- how much of it each of them was there.
--
-- Who is expected, saved on the record when the raid gets its planned raid (Snapshot): on a team raid the players
-- placed in the groups of the lineup that raid uses (the ones Invite & sort invites; kind "l"), plus extra invites
-- who answered Accept; on a raid without a lineup (no team, or the team has none of its size / an empty one) whoever
-- answered Accept (kind "a"). Unassigned, waitlist, Tentative, Bench and guests are never expected.
-- The expected time: from the raid's start to the end of the team's raid night that day (ef / et), else to the
-- end of the session, and never past it. Leaving after the planned end is never early. (No length field on planned
-- raids: a new raid field changes every member's raid plan hashes, so older clients would resync until updated.)
--
-- A night = the records of one planned raid (a restart, Gruul then Mag), else one record. Per player:
--   credit = time there / time expected, after the margins (the GM's: how late still counts as on time, how long a
--   disconnect is ignored), from when the raid formed (half the expected players there) if that is after the start.
--   No-show = 0; bench (sign-up or the leader's mark) and removed by the leader = 100%; excused = 100%.
--   Gaps when half the raid dropped at once (server trouble) are excused for everyone.
--   A review opens when someone left before the end and didn't come back, gave a reason (their own, a sign-up note,
--   an Absent answer, chat lines someone picked), or the leader left it to the officers. Until the GM, an officer or
--   a guild council member decides (Excuse / Counts), it doesn't count either way.
--   A fill-in (not expected, came) is never late; the leader's Swap in links them to the player they replace (else a
--   fill-in who joins within 15 minutes of an expected player leaving is linked).
-- Attendance % = the average credit over the last N nights where the player was expected and it counts. A raid
-- without a team that clashes with the player's team night doesn't expect them (the team raid wins).
--
-- Record fields (merged by RaidLog): ex / exAt / ef / et / sn (the snapshot, belongs to the link), mk (the raid leader's
-- marks: b benched, sw fill-in for, rm removed, od officers decide), rs (the player's own reason), dc (decisions),
-- q (chat lines picked). Messages: ATM (the leader's marks, RAID), ATY (my reason, WHISPER), ATQ / ATR (my own
-- attendance, asked from a raid log reader).
local addonName, ns = ...

local Att = ns:NewModule("Attendance")
local Util = ns.Util

local type, pairs, ipairs, tonumber, tostring, next = type, pairs, ipairs, tonumber, tostring, next
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local tsort, tconcat = table.sort, table.concat

local DAY = 86400
local WEEK_MIN = 7 * 1440
local NIGHT_MATCH = 180                 -- minutes: a team night this close to the raid's start is that raid's night
local FORM_MAX = 3600                   -- late counts from when the raid formed, at most this long after the start
local PAIR_BEFORE, PAIR_AFTER = 5 * 60, 15 * 60   -- a fill-in joining this close to a leave replaces that player
local TROUBLE_SPREAD = 180              -- server trouble: half the raid gone within this many seconds
local REVIEW_DAYS = 80                  -- waiting reviews stay listed this long (the raid log's sync window)
local HANDLED_DAYS = 14                 -- decisions listed under Handled for this long
local CHAT_KEEP = DAY                   -- chat lines kept (memory only)
local CHAT_PER_PLAYER = 40
local CHAT_MAX_PLAYERS = 300
local MAX_PICK = 5
local LATE_CANCEL = 2 * 3600            -- Absent answered this close to the start (or later) is a late cancel
local BREAKUP_SLACK = 15 * 60           -- leaving this long before the raid broke up is leaving with it
local BURST_N, BURST_SEC = 3, 180       -- this many expected players leaving this fast: the raid is breaking up
local MAX_TEXT = 200

local nightsCache, cacheVer, ver = nil, nil, 0
local chat = {}                         -- [key] = { { t, ch, at }, ... } oldest first (memory only)
local chatPlayers = 0
local pendingSwap = {}                  -- [invited key] = the player they replace (the leader's Swap in, until they join)
local leaving                           -- { id, auth, readers } while I am in an expected raid (my own leave prompt)

local Now = Util.Now
local function RL() return ns.RaidLog end
local function G() return ns.Guild end
local function Me() return Util.PlayerKey() end

local DemoOn = Util.DemoOn

local function Bump()
    ver = ver + 1
    nightsCache = nil
    -- (the notification center looks again a few seconds after changes stop, not on every scan)
    if Util and Util.Debounce then Util.Debounce("att-reviews", 5, function() ns:Fire("ATTENDANCE_REVIEWS_CHANGED") end) end
end

---------------------------------------------------------------------------
-- Rules and rights
---------------------------------------------------------------------------

-- { onTime, dc } in seconds (the GM's minutes, Guild:GetAttendanceRules).
function Att:Rules()
    local Guild = G()
    local r = Guild and Guild.GetAttendanceRules and Guild:GetAttendanceRules() or { o = 5, d = 10 }
    return { onTime = (tonumber(r.o) or 5) * 60, dc = (tonumber(r.d) or 10) * 60, o = r.o, d = r.d }
end

-- Decides reviews: the GM, officers and the guild council (demo mode: me, on the demo raids).
function Att:CanReview(key)
    key = key or Me()
    if DemoOn() and Util.IsMe(key) then return true end
    local Guild = G()
    return Guild and Guild.IsAttendanceReviewer and Guild:IsAttendanceReviewer(key) or false
end

-- Sees everyone's attendance: the raid log's readers (members + reviewers).
function Att:CanSeeAll(key)
    key = key or Me()
    if DemoOn() and Util.IsMe(key) then return true end
    local Guild = G()
    return Guild and ((Guild.IsRaidLogReader and Guild:IsRaidLogReader(key))
        or (Guild.IsRaidLogMember and Guild:IsRaidLogMember(key))) or false
end

local function Linked(key)
    local Guild = G()
    return Guild and Guild.GetLinkedCharacters and Guild:GetLinkedCharacters(key) or {}
end

-- One player: the guild's account link, where each character vouches for the other (one character naming another
-- as its main is not enough: it would hand that player its time).
local function SameAccount(a, b)
    if a == b then return true end
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    local Guild = G()
    return Guild and Guild.SameAccount and Guild:SameAccount(a, b) or false
end

-- The player behind a character, for listing them once: their main (the Members tab's main / alt link) when the two
-- are linked both ways, else the character itself.
local function PlayerOf(key)
    local P = ns.Professions
    local m = type(key) == "string" and P and P.GetMain and P:GetMain(key)
    if type(m) == "string" and m ~= "" and m ~= key and SameAccount(key, m) then return m end
    return key
end
Att.PlayerOf = function(_, key) return PlayerOf(key) end

local function InGuild(key)
    local Guild = G()
    if DemoOn() then return true end
    return Guild and Guild.IsInGuild and Guild:IsInGuild(key, true) or false
end

---------------------------------------------------------------------------
-- Who is expected (saved on the record)
---------------------------------------------------------------------------

-- The end (server time) of the team night that matches a raid starting at t, or nil.
function Att:NightEnd(nights, t)
    if type(nights) ~= "table" or not t then return nil end
    local lt = date("*t", t)
    local localW = ((lt.wday + 5) % 7) * 1440 + lt.hour * 60 + lt.min
    local Nights = ns.RaidNights
    local realmW = (localW - (Nights and Nights.Offset and Nights:Offset() or 0)) % WEEK_MIN
    local best, bestDiff
    for _, n in ipairs(nights) do
        if type(n) == "table" and tonumber(n.w) and tonumber(n.m) then
            local diff = (n.w - realmW + WEEK_MIN / 2) % WEEK_MIN - WEEK_MIN / 2
            if abs(diff) <= NIGHT_MATCH and (not bestDiff or abs(diff) < abs(bestDiff)) then best, bestDiff = n, diff end
        end
    end
    if not best then return nil end
    local e = t + bestDiff * 60 + best.m * 60
    return e > t and e or nil
end

-- Saves who the record's planned raid expects (ex), and when (ef / et). Called when the record gets its link.
function Att:Snapshot(rec)
    local RP = ns.RaidPlan
    if type(rec) ~= "table" or not rec.pl or not (RP and RP.GetRaid) then return end
    local v = RP:GetRaid(rec.pl)
    if not v or not v.t then return end
    local ex, lineup, nightEnd = {}, false, nil
    for _, id in ipairs(v.tm or {}) do
        local players, l = RP:GetRaidTeamPlayers(v, id)
        if players and l then
            lineup = true
            for _, key in ipairs(players) do ex[key] = "l" end
        end
        local t = RP:GetTeam(id)
        if t and not nightEnd then nightEnd = self:NightEnd(t.nights, v.t) end
    end
    local invited = {}
    for _, key in ipairs(v.inv or {}) do invited[key] = true end
    for key, s in pairs(RP:GetSignups(v.id) or {}) do
        if s.st == "A" and not s.guest and not ex[key] and (not lineup or invited[key]) then
            -- (one of the player's characters may already be expected through the lineup)
            local dup = false
            for other in pairs(ex) do
                if SameAccount(other, key) then dup = true break end
            end
            if not dup then ex[key] = "a" end
        end
    end
    rec.ex = next(ex) and ex or nil
    rec.exAt = rec.ex and (tonumber(rec.plAt) or Now()) or nil
    rec.ef = rec.ex and v.t or nil
    rec.et = rec.ex and nightEnd or nil
    Bump()
end

-- Saves the sign-up notes and Absent answers of the expected players (sn): a reason told before the raid.
function Att:SnapshotNotes(rec)
    local RP = ns.RaidPlan
    if type(rec) ~= "table" or not rec.pl or not (RP and RP.GetSignups) then return end
    local signups = RP:GetSignups(rec.pl) or {}
    for key in pairs(rec.ex or {}) do
        local s = signups[key]
        if not s then
            for _, m in ipairs(Linked(key)) do
                if signups[m] then s = signups[m] break end
            end
        end
        if s and (s.st == "X" or (type(s.n) == "string" and s.n ~= "")) then
            local note = type(s.n) == "string" and s.n:gsub("[%c|]", " "):sub(1, 120) or nil
            rec.sn = rec.sn or {}
            rec.sn[key] = { n = note ~= "" and note or nil, x = s.st == "X" or nil,
                            at = tonumber(s.at) or tonumber(s.rev) or rec.start }
        end
    end
    -- a late cancel: Absent answered in the 2 hours before the start (or after it), by anyone who answered (a mark,
    -- never lost attendance: a raid without a team no longer expects them)
    local v = RP.GetRaid and RP:GetRaid(rec.pl)
    local start = v and v.t or rec.start
    for key, s in pairs(signups) do
        local at = tonumber(s.at) or tonumber(s.rev)
        if s.st == "X" and at and start and at >= start - LATE_CANCEL and not s.guest then
            rec.sn = rec.sn or {}
            local e = rec.sn[key] or { x = true, at = at }
            e.lc = true
            rec.sn[key] = e
        end
    end
end

---------------------------------------------------------------------------
-- Nights: a planned raid's records as one
---------------------------------------------------------------------------

local function CopyPieces(a, rec)
    if type(a) ~= "table" then return nil end
    if type(a.s) == "table" and #a.s >= 2 then return a.s end
    -- (a record from before 1.3.5: one piece from the first join to the last leave)
    if a.j then return { a.j, a.l or rec.stop or Now() } end
    return nil
end

local function Newest(into, map)
    for key, v in pairs(map or {}) do
        local c = into[key]
        if type(v) == "table" and (not c or (v.at or 0) > (c.at or 0)) then into[key] = v end
    end
end

local function BuildNight(recs)
    local first = recs[1]
    local n = { key = first.pl or first.id, pl = first.pl, recs = recs, primary = first, zone = first.zone,
                instID = first.instID, start = first.start, stop = first.stop, att = {}, bench = {}, cls = {},
                ex = {}, sn = {}, mk = {}, rs = {}, dc = {}, q = {}, su = {}, bosses = {}, demo = first.demo }
    local exAt
    for _, rec in ipairs(recs) do
        n.start = min(n.start or rec.start, rec.start or n.start)
        if not rec.stop then n.open = true end
        if rec.stop and (not n.stop or rec.stop > n.stop) then n.stop = rec.stop end
        n.zone = n.zone or rec.zone
        n.instID = n.instID or rec.instID
        for key, a in pairs(rec.att or {}) do
            local s = CopyPieces(a, rec)
            if s then n.att[key] = RL():JoinPieces(n.att[key], s) end
            if a.b then n.bench[key] = true end
            if a.c then n.cls[key] = a.c end
        end
        if rec.ex and (not exAt or (rec.exAt or 0) >= exAt) then
            if exAt and (rec.exAt or 0) == exAt then
                for key, kind in pairs(rec.ex) do
                    if not n.ex[key] or kind == "l" then n.ex[key] = kind end
                end
            else
                n.ex = {}
                for key, kind in pairs(rec.ex) do n.ex[key] = kind end
                n.ef, n.et = rec.ef, rec.et
            end
            exAt = rec.exAt or 0
        end
        for key, st in pairs(rec.su or {}) do n.su[key] = n.su[key] or st end
        Newest(n.sn, rec.sn)
        Newest(n.mk, rec.mk)
        Newest(n.rs, rec.rs)
        -- (a decision counts only when a reviewer made it: GM, officer, guild council)
        for key, v in pairs(rec.dc or {}) do
            local c = n.dc[key]
            if type(v) == "table" and Att:CanReview(v.by) and (not c or (v.at or 0) > (c.at or 0)) then n.dc[key] = v end
        end
        Newest(n.q, rec.q)
        for _, b in ipairs(rec.bosses or {}) do n.bosses[#n.bosses + 1] = b end
    end
    if n.open then n.stop = nil end
    tsort(n.bosses, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
    n.collapse = true
    -- (a record from before 1.3.5, without a snapshot: whoever came, and who answered Accept, was expected)
    -- (players outside the guild, pugs and guests, are never expected; a raid not linked to a planned raid has no
    -- planned time either: who came counts as there, only an Accept answer that didn't come counts against them)
    if not next(n.ex) then
        n.legacy = true
        n.loose = true
        for key in pairs(n.att) do
            if InGuild(key) then n.ex[key] = "a" end
        end
        for key, st in pairs(n.su) do
            if st == "A" and not n.ex[key] and InGuild(key) then n.ex[key] = "a" end
        end
    else
        for key in pairs(n.ex) do
            if not InGuild(key) then n.ex[key] = nil end
        end
    end
    -- one player, one place (in-game report 2026-10-11: a main who answered Accept and came on an alt was a
    -- no-show): of a player's characters the night expects, keep the lineup one, else the main, else the one who
    -- answered Accept, else the one who came
    local keys = {}
    for key in pairs(n.ex) do keys[#keys + 1] = key end
    tsort(keys)
    local function score(key)
        return (n.ex[key] == "l" and 8 or 0) + (PlayerOf(key) == key and 4 or 0) + (n.su[key] == "A" and 2 or 0)
            + (n.att[key] and 1 or 0)
    end
    for i, a in ipairs(keys) do
        if n.ex[a] then
            for j = i + 1, #keys do
                local b = keys[j]
                if n.ex[b] and SameAccount(a, b) then
                    if score(b) > score(a) then
                        n.ex[a] = nil
                        a = b
                    else
                        n.ex[b] = nil
                    end
                end
            end
        end
    end
    return n
end

-- The logged nights of my guild, newest first (the demo's in demo mode). Cached until the raid log changes.
function Att:GetNights()
    if nightsCache and cacheVer == ver then return nightsCache end
    local L = RL()
    local out, byKey = {}, {}
    for _, rec in ipairs(L and L.GetRaids and L:GetRaids() or {}) do
        local k = rec.pl or rec.id
        local list = byKey[k]
        if not list then
            list = {}
            byKey[k] = list
            out[#out + 1] = list
        end
        list[#list + 1] = rec
    end
    for i, recs in ipairs(out) do out[i] = BuildNight(recs) end
    tsort(out, function(a, b) return (a.start or 0) > (b.start or 0) end)
    nightsCache, cacheVer = out, ver
    return out
end

-- A night as one record for the Raid log (one card for a Gruul + Mag run logged as two raids): the newest record's
-- id, ids = every record's, the planned raid's name when there are several, the kills, attendance (kills added up),
-- sign-ups and awards of them all. Treat as read-only.
function Att:NightView(n)
    if #n.recs == 1 then return n.recs[1] end
    local first, last = n.recs[#n.recs], n.recs[1]
    local v = { id = n.primary.id, ids = {}, start = n.start, stop = n.stop, pl = n.pl, plAt = n.primary.plAt,
                by = first.by, endedBy = last.endedBy, autoEnded = last.autoEnded, instID = first.instID,
                bosses = n.bosses, att = {}, su = next(n.su) and n.su or nil, demo = n.demo, night = n }
    local zones = {}
    for i = #n.recs, 1, -1 do
        local rec = n.recs[i]
        v.ids[#v.ids + 1] = rec.id
        if rec.zone then
            local dup = false
            for _, z in ipairs(zones) do if z == rec.zone then dup = true end end
            if not dup then zones[#zones + 1] = rec.zone end
        end
        for key, a in pairs(rec.att or {}) do
            local c = v.att[key]
            if not c then
                c = { k = 0 }
                v.att[key] = c
            end
            c.k = c.k + (tonumber(a.k) or 0)
            c.c = c.c or a.c
            if a.b then c.b, c.bts = true, a.bts end
            if a.j and (not c.j or a.j < c.j) then c.j = a.j end
            if a.l and (not c.l or a.l > c.l) then c.l = a.l end
        end
        if rec.demoAwards then
            v.demoAwards = v.demoAwards or {}
            for _, e in ipairs(rec.demoAwards) do v.demoAwards[#v.demoAwards + 1] = e end
        end
    end
    local RP = ns.RaidPlan
    local plan = n.pl and RP and RP.GetRaid and RP:GetRaid(n.pl)
    v.zone = (plan and RP:GetRaidName(plan)) or tconcat(zones, " + ")
    return v
end

function Att:GetNight(key)
    for _, n in ipairs(self:GetNights()) do
        if n.key == key then return n end
    end
    return nil
end

-- The night a record belongs to.
function Att:NightOf(rec)
    if type(rec) ~= "table" then return nil end
    return self:GetNight(rec.pl or rec.id)
end

---------------------------------------------------------------------------
-- One player's night
---------------------------------------------------------------------------

-- The expected window of a night: from, to (to: the planned end, never past the session's end; open: now).
local function Window(n)
    local F = n.ef or n.start
    local stop = n.stop or Now()
    local T = n.et and min(n.et, stop) or stop
    return F, T
end

-- A player's pieces in a night, with the pieces of their other characters who were there.
local function PiecesOf(n, key)
    local s = n.att[key]
    for other, os in pairs(n.att) do
        if other ~= key and SameAccount(key, other) then s = RL():JoinPieces(s, os) end
    end
    return s
end

-- Joins pieces whose gap is short (a disconnect) or falls in a server-trouble window.
local function Bridge(s, dc, trouble)
    local out = {}
    for i = 1, #(s or {}) - 1, 2 do
        local f, t = s[i], s[i + 1]
        local m = #out
        local excused = false
        if m >= 2 then
            for _, w in ipairs(trouble or {}) do
                if out[m] >= w[1] - 60 and f <= w[2] + 60 then excused = true break end
            end
        end
        if m >= 2 and (f - out[m] <= dc or excused) then
            if t > out[m] then out[m] = t end
        else
            out[m + 1], out[m + 2] = f, t
        end
    end
    return out
end

-- Night-wide: server trouble windows ({ { from, to } }) and when the raid formed (half the expected players there).
-- Time with the stretches nobody logged taken out (gaps = { { from, to } }, sorted): t minus the gap time before it.
local function Compress(t, gaps)
    if not t then return nil end
    local out = t
    for _, g in ipairs(gaps or {}) do
        if g[1] < t then out = out - (min(t, g[2]) - g[1]) end
    end
    return out
end

local function NightFacts(n, rules)
    if n.facts and n.facts.ver == ver then return n.facts end
    local F, T = Window(n)
    local planEnd = T
    -- server trouble: half the players present gone within TROUBLE_SPREAD of each other (players, not gaps)
    local gaps, players = {}, 0
    for _, s in pairs(n.att) do
        local any = false
        for i = 1, #s - 1, 2 do
            if s[i + 1] > F and s[i] < T then any = true break end
        end
        if any then players = players + 1 end
        for i = 2, #s - 2, 2 do
            if s[i] >= F and s[i] <= T and s[i + 1] - s[i] > rules.dc then gaps[#gaps + 1] = { s[i], s[i + 1], s } end
        end
    end
    tsort(gaps, function(a, b) return a[1] < b[1] end)
    local trouble = {}
    local i = 1
    while i <= #gaps do
        local j = i
        while j + 1 <= #gaps and gaps[j + 1][1] - gaps[i][1] <= TROUBLE_SPREAD do j = j + 1 end
        local who = {}
        for k = i, j do who[gaps[k][3]] = true end
        local count = 0
        for _ in pairs(who) do count = count + 1 end
        if count >= 3 and count * 2 >= players then
            -- (until the last of them was back, at most an hour)
            local back = gaps[i][2]
            for k = i, j do back = max(back, gaps[k][2]) end
            trouble[#trouble + 1] = { gaps[i][1], min(back, gaps[i][1] + 3600) }
            i = j + 1
        else
            i = i + 1
        end
    end
    -- a night logged as several raids (Mag, then Gruul): nobody was recorded between them, so that time is taken out
    -- of the night (neither there nor missed)
    local spans, logGaps = {}, {}
    for _, rec in ipairs(n.recs) do
        if rec.start then spans[#spans + 1] = { rec.start, rec.stop or Now() } end
    end
    tsort(spans, function(a, b) return a[1] < b[1] end)
    local reach = spans[1] and spans[1][2]
    for k = 2, #spans do
        if spans[k][1] > reach then logGaps[#logGaps + 1] = { reach, spans[k][1] } end
        reach = max(reach, spans[k][2])
    end
    -- when the raid formed: the median first arrival of the expected players who came
    local arrivals = {}
    for key in pairs(n.ex) do
        local s = PiecesOf(n, key)
        if s then
            for k = 1, #s - 1, 2 do
                if s[k + 1] > F then
                    arrivals[#arrivals + 1] = max(s[k], F)
                    break
                end
            end
        end
    end
    tsort(arrivals)
    local E = F
    local med = arrivals[floor((#arrivals + 1) / 2)]
    if med and med > F + rules.onTime then E = min(med, F + FORM_MAX, T) end
    -- the raid broke up: in the second half of the planned time, half the expected players who came had left (everyone
    -- goes after the last boss while nobody has pressed End raid yet): the expected time ends there
    local ends = {}
    for key in pairs(n.ex) do
        local s = PiecesOf(n, key)
        if s and s[#s] and s[#s] > F then ends[#ends + 1] = min(s[#s], T) end
    end
    tsort(ends)
    local broke
    if #ends >= 3 and not n.open then
        local b = ends[floor(#ends / 2) + 1]          -- (by this time half of them were gone)
        if b and b < T - rules.onTime and b > F + (planEnd - F) / 2 then
            broke = b
            T = b
            E = min(E, T)
        end
    end
    -- a raid that started before its planned time: being there from its start counts (late still counts from the
    -- planned start)
    local S0 = (n.start and n.start < F) and n.start or F
    -- (a raid that ended before its planned start: no planned time to measure; who came is there)
    if T - F < 60 then n.loose = true end
    n.facts = { ver = ver, F = F, T = T, E = E, S0 = S0, trouble = trouble, gaps = logGaps, broke = broke }
    return n.facts
end

-- A player's result for a night:
-- { key, kind ("l" | "a" | nil), F, E, T, expected (seconds), present, late, left, away, noShow, first, last,
--   pieces (bridged, for drawing), credit (0..1), bench, removed, excused, counts, pending, review, decision,
--   reason, picked, note, mark, help (seconds, fill-ins), forKey / replacedBy, outside, lateCancel, loose }
-- Durations leave out the time nobody logged (between two logs of one night).
function Att:Result(n, key, rules)
    rules = rules or self:Rules()
    local facts = NightFacts(n, rules)
    local F, E, T = facts.F, facts.E, facts.T
    local dc, q = n.dc[key], n.q[key]
    if dc and dc.d ~= "x" and dc.d ~= "c" then dc = nil end           -- (taken back)
    if q and not (q.l and q.l[1]) then q = nil end                     -- (lines cleared)
    local r = { key = key, night = n, kind = n.ex[key], F = F, E = E, T = T, decision = dc, reason = n.rs[key],
                picked = q, note = n.sn[key], mark = n.mk[key], cls = n.cls[key] }
    local raw = PiecesOf(n, key)
    local s = Bridge(raw, rules.dc, facts.trouble)
    r.pieces = s
    local out = 0
    for _, rec in ipairs(n.recs) do
        local a = rec.att and rec.att[key]
        if a and tonumber(a.o) then out = out + a.o end
    end
    r.outside = out > 0 and out or nil
    r.lateCancel = r.note and r.note.lc or nil
    -- the measuring is done with the unlogged stretches taken out
    local G = facts.gaps
    local cs = {}
    for i = 1, #s - 1, 2 do
        local a, b = Compress(s[i], G), Compress(s[i + 1], G)
        if b > a then cs[#cs + 1], cs[#cs + 2] = a, b end
    end
    cs = Bridge(cs, rules.dc, nil)
    local cE, cT, cS0, cF = Compress(E, G), Compress(T, G), Compress(facts.S0, G), Compress(F, G)
    -- clipped to [E, T], with the on-time margin at both ends
    local present, first, last = 0, nil, nil
    for i = 1, #cs - 1, 2 do
        local f, t = max(cs[i], cE), min(cs[i + 1], cT)
        if t > f then
            first = first or f
            last = t
            present = present + (t - f)
        end
    end
    local span = max(0, cT - cE)
    r.expected = span
    local lateOk = first and first - cE <= rules.onTime
    local leftOk = last and cT - last <= rules.onTime + RL().PIECE_JOIN + (facts.broke and BREAKUP_SLACK or 0)
    if lateOk then present = present + (first - cE) end
    if leftOk then present = present + (cT - last) end
    -- (an early start: there before the planned time counts too)
    if cS0 < cF then
        for i = 1, #cs - 1, 2 do
            local f, t = max(cs[i], cS0), min(cs[i + 1], cF)
            if t > f then present = present + (t - f) end
        end
    end
    present = min(present, span)
    r.present = present
    r.noShow = present <= 0
    if n.loose then
        -- (no planned time: there at all during the session is there)
        local from, to = (n.start or F) - 3600, n.stop or Now()
        local seen = false
        for i = 1, #s - 1, 2 do
            if s[i + 1] > from and s[i] < to then seen = true break end
        end
        r.noShow = not seen
    end
    r.late = (first and not lateOk) and max(0, first - cE) or 0
    r.left = (last and not leftOk) and max(0, cT - last) or 0
    r.away = max(0, span - present - r.late - r.left)
    -- the times shown: the real ones (when they came, when they went), at the window's edges when on time
    for i = 1, #s - 1, 2 do
        local f, t = max(s[i], E), min(s[i + 1], T)
        if t > f then
            r.first = r.first or f
            r.last = t
        end
    end
    if r.first and r.late == 0 then r.first = E end
    if r.last and r.left == 0 then r.last = T end
    if not r.kind then
        -- not expected: a fill-in when they were there during the window
        local help = 0
        for i = 1, #cs - 1, 2 do
            local f, t = max(cs[i], cF), min(cs[i + 1], cT)
            if t > f then help = help + (t - f) end
        end
        r.help = help > 0 and help or nil
        return r
    end
    local mk = r.mark
    r.bench = n.bench[key] or (mk and mk.b) or false
    r.removed = mk and mk.rm or false
    -- (told before: an Absent answer or a sign-up note, when they were late, left or didn't come)
    local told = r.note and (r.note.x or r.note.n) and (r.late > 0 or r.noShow or r.left > 0)
    -- (a raid logged before 1.3.5 opens no review for an early leave: only for a reason someone gave)
    local leftEarly = r.left > 0 and not r.noShow and not n.legacy
    r.review = (not r.bench and not r.removed) and (leftEarly or r.reason ~= nil or r.picked ~= nil
        or (mk and mk.od) or told) and true or false
    r.told = told and true or false
    local d = r.decision and r.decision.d
    r.excused = d == "x"
    r.pending = r.review and not d
    if n.loose then
        -- (no planned time: who came is there; only an Accept answer that never came is a no-show)
        r.loose = not r.noShow
        r.review = r.reason ~= nil or r.picked ~= nil or (mk and mk.od) or false
        r.pending = r.review and not d
        r.credit = (r.excused or r.bench or not r.noShow) and 1 or 0
        r.late, r.left, r.away = 0, 0, 0
        r.counts = not r.pending
        return r
    elseif r.bench or r.removed or r.excused then
        r.credit = 1
    elseif span > 0 then
        r.credit = present / span
    else
        r.credit = nil
    end
    r.counts = r.credit ~= nil and not r.pending and span > 0
    return r
end

-- Every player of a night: the expected ones, then the fill-ins (their other characters are not separate rows).
-- Fill-ins are linked to the player they replace. Returns { expected = { r... }, helpers = { r... } }.
function Att:NightResults(n, rules)
    rules = rules or self:Rules()
    local out = { expected = {}, helpers = {}, guests = {} }
    local byKey = {}
    for key in pairs(n.ex) do
        local r = self:Result(n, key, rules)
        out.expected[#out.expected + 1] = r
        byKey[key] = r
    end
    for key in pairs(n.att) do
        if not n.ex[key] and not InGuild(key) then
            local r = self:Result(n, key, rules)
            r.guest = true
            out.guests[#out.guests + 1] = r
        elseif not n.ex[key] then
            local alt = false
            for e in pairs(n.ex) do
                if SameAccount(e, key) then alt = true break end
            end
            if not alt then
                for _, h in ipairs(out.helpers) do
                    if SameAccount(h.key, key) then alt = true break end
                end
            end
            if not alt then
                local r = self:Result(n, key, rules)
                if r.help or n.bench[key] then
                    out.helpers[#out.helpers + 1] = r
                    byKey[key] = r
                end
            end
        end
    end
    -- fill-ins: the leader's Swap in, else the expected player who left just before they came
    for _, h in ipairs(out.helpers) do
        local sw = h.mark and h.mark.sw
        if sw and byKey[sw] then
            h.forKey = sw
            byKey[sw].replacedBy = h.key
        end
    end
    for _, h in ipairs(out.helpers) do
        if not h.forKey and h.help and h.first then
            local best
            for _, r in ipairs(out.expected) do
                if r.left > 0 and r.last and not r.replacedBy and h.first >= r.last - PAIR_BEFORE
                    and h.first <= r.last + PAIR_AFTER and (not best or r.last > best.last) then
                    best = r
                end
            end
            if best then
                h.forKey = best.key
                best.replacedBy = h.key
            end
        end
    end
    local function byName(a, b) return a.key < b.key end
    tsort(out.expected, byName)
    tsort(out.helpers, byName)
    tsort(out.guests, byName)
    return out
end

---------------------------------------------------------------------------
-- Over many nights
---------------------------------------------------------------------------

-- The closed nights, newest first, at most lastN (nil / 0: all).
function Att:ClosedNights(lastN)
    local out = {}
    for _, n in ipairs(self:GetNights()) do
        if not n.open then
            out[#out + 1] = n
            if lastN and lastN > 0 and #out >= lastN then break end
        end
    end
    return out
end

-- Per night, every player's result, with the clash rule: a raid without a team that overlaps the player's team raid
-- doesn't expect them (the team raid wins); a team raid they skipped for another guild raid at the same time is
-- excused unless an officer said it counts. Returns { [i] = { night, results = { [key] = r } } }.
function Att:Results(nights, rules)
    rules = rules or self:Rules()
    local list = {}
    for i, n in ipairs(nights) do
        NightFacts(n, rules)
        local res = self:NightResults(n, rules)
        local map = {}
        for _, r in ipairs(res.expected) do map[r.key] = r end
        for _, r in ipairs(res.helpers) do map[r.key] = r end
        for _, r in ipairs(res.guests) do map[r.key] = r end        -- (listed only when guests are asked for)
        list[i] = { night = n, results = map }
    end
    for i, a in ipairs(list) do
        for j, b in ipairs(list) do
            if i ~= j then
                local Fa, Ta = a.night.facts.F, a.night.facts.T
                local Fb, Tb = b.night.facts.F, b.night.facts.T
                if Fa < Tb and Fb < Ta then
                    for key, ra in pairs(a.results) do
                        local rb = b.results[key]
                        if not rb then
                            for other, x in pairs(b.results) do
                                if SameAccount(other, key) then rb = x break end
                            end
                        end
                        if rb then
                            if ra.kind == "a" and rb.kind == "l" then
                                ra.clash, ra.kind, ra.counts, ra.pending, ra.review = b.night, nil, false, false, false
                            elseif ra.kind == "l" and ra.noShow and not rb.noShow and (rb.help or rb.present > 0)
                                and not (ra.decision and ra.decision.d == "c") then
                                ra.otherRaid, ra.excused, ra.credit, ra.counts = b.night, true, 1, true
                                ra.pending = false
                            end
                        end
                    end
                end
            end
        end
    end
    return list
end

-- A square's code for a player's night: F full, pN part (N tenths), N no-show, E excused, B bench, R waiting for
-- review, H helped (fill-in), - not expected.
local function Code(r)
    if not r then return "-" end
    if not r.kind then return r.help and "H" or "-" end
    if r.pending then return "R" end
    if r.bench then return "B" end
    if r.excused or r.removed then return "E" end
    if r.noShow then return "N" end
    if not r.credit then return "-" end
    if r.credit >= 0.99 then return "F" end
    return "p" .. max(1, min(9, floor(r.credit * 10)))
end
Att.Code = Code

-- The lineups a member is placed in now: "25 · Kara A" (team lineup names, shortest first), or nil.
function Att:LineupsOf(key)
    local RP = ns.RaidPlan
    if not (RP and RP.GetTeams) then return nil end
    local names = {}
    for _, team in ipairs(RP:GetTeams() or {}) do
        for _, l in ipairs(team.lineups or {}) do
            local g = l.groups and l.groups[key]
            if type(g) == "number" and g >= 1 then
                local name = RP:LineupName(team, l) or tostring(l.size)
                names[#names + 1] = (name:gsub("^(%d+)%-man$", "%1"))
            end
        end
    end
    if #names == 0 then return nil end
    tsort(names, function(a, b)
        if #a ~= #b then return #a < #b end
        return a < b
    end)
    return tconcat(names, " · ")
end

-- Is a member in a lineup (team id, lineup id) now?
function Att:InLineup(key, teamId, lineupId)
    local RP = ns.RaidPlan
    local team = RP and RP.GetTeam and RP:GetTeam(teamId)
    for _, l in ipairs(team and team.lineups or {}) do
        if l.id == lineupId then
            local g = l.groups and l.groups[key]
            return type(g) == "number" and g >= 1
        end
    end
    return false
end

-- Per player over the last `lastN` closed nights (nil / 0: all): { key, cls, lineups, codes = { newest first },
-- counted, pct, late = { n, sec }, left, noShows, excused, pending, fills, help, clashes } sorted by attendance, then
-- name; and the nights. Players who were never expected and never came are not listed. opts.guests: include players
-- outside the guild.
function Att:GetStats(lastN, opts)
    opts = opts or {}
    local rules = self:Rules()
    local nights = self:ClosedNights(lastN)
    local results = self:Results(nights, rules)
    local by, list = {}, {}
    local function S(key)
        local s = by[key]
        if not s then
            s = { key = key, codes = {}, counted = 0, sum = 0, late = { n = 0, sec = 0 }, left = 0, noShows = 0,
                  excused = 0, pending = 0, fills = 0, help = 0, clashes = 0, bench = 0, lateCancels = 0 }
            by[key] = s
            list[#list + 1] = s
        end
        return s
    end
    local rowOf = {}
    for _, item in ipairs(results) do
        for key, e in pairs(item.night.sn) do
            if e.lc and InGuild(key) then
                local s = S(PlayerOf(key))
                s.lateCancels = s.lateCancels + 1
            end
        end
        item.byPlayer = {}
        for key, r in pairs(item.results) do
            if r.kind or r.help or r.clash then
                local pk = PlayerOf(key)
                rowOf[key] = pk
                item.byPlayer[pk] = item.byPlayer[pk] or r
                if r.kind then item.byPlayer[pk] = r end
                local s = S(pk)
                s.cls = s.cls or r.cls
                if r.clash then s.clashes = s.clashes + 1 end
                if r.kind then
                    if r.pending then s.pending = s.pending + 1 end
                    if r.counts then
                        s.counted = s.counted + 1
                        s.sum = s.sum + (r.credit or 0)
                        if r.bench then s.bench = s.bench + 1
                        elseif r.excused or r.removed then s.excused = s.excused + 1
                        elseif r.noShow then s.noShows = s.noShows + 1
                        else
                            if r.late > 0 then
                                s.late.n = s.late.n + 1
                                s.late.sec = s.late.sec + r.late
                            end
                            if r.left > 0 then s.left = s.left + 1 end
                        end
                    end
                elseif r.help then
                    s.fills = s.fills + 1
                    s.help = s.help + r.help
                end
            end
        end
    end
    local out = {}
    for _, s in ipairs(list) do
        if opts.guests or InGuild(s.key) then
            for i, item in ipairs(results) do s.codes[i] = Code(item.byPlayer[s.key] or item.results[s.key]) end
            s.pct = s.counted > 0 and floor(s.sum * 100 / s.counted + 0.5) or nil
            s.lineups = self:LineupsOf(s.key)
            local Guild = G()
            s.cls = (Guild and Guild.GetClass and Guild:GetClass(s.key)) or s.cls
            out[#out + 1] = s
        end
    end
    tsort(out, function(a, b)
        local pa, pb = a.pct or -1, b.pct or -1
        if pa ~= pb then return pa > pb end
        return a.key < b.key
    end)
    return out, nights
end

-- One player's GetStats row over the last lastN nights (cached until anything changes), and the nights' count.
local summaryCache = {}
function Att:GetSummary(key, lastN)
    lastN = lastN or 8
    local c = summaryCache[lastN]
    if not c or c.ver ~= ver then
        local rows, nights = self:GetStats(lastN, { guests = true })
        c = { ver = ver, by = {}, n = #nights }
        for _, s in ipairs(rows) do c.by[s.key] = s end
        summaryCache[lastN] = c
    end
    if c.n == 0 then return nil, 0 end
    local s = c.by[key]
    if not s then
        for other, x in pairs(c.by) do
            if SameAccount(other, key) then s = x break end
        end
    end
    return s, c.n
end

-- One player's nights, newest first: { { night, r }, ... } where they were expected or came (lastN closed nights;
-- the night running now first when there is one). Also their stats (GetStats' row) and the nights' count.
function Att:GetHistory(key, lastN)
    local rules = self:Rules()
    local nights = self:ClosedNights(lastN)
    local results = self:Results(nights, rules)
    local out = {}
    for _, item in ipairs(results) do
        local r = item.results[key]
        if not r then
            for other, x in pairs(item.results) do
                if SameAccount(other, key) and (x.kind or x.help) then r = x break end
            end
        end
        if r and (r.kind or r.help or r.clash) then out[#out + 1] = { night = item.night, r = r } end
    end
    local stats
    for _, s in ipairs(self:GetStats(lastN, { guests = true })) do
        if s.key == key or s.key == PlayerOf(key) or SameAccount(s.key, key) then stats = s break end
    end
    return out, stats, #nights
end

---------------------------------------------------------------------------
-- Dry streak (1.3.5, the drop panel): how long a player has gone without loot
---------------------------------------------------------------------------

-- The player = the character with its account links (each character vouches for the other, as for attendance): an
-- item on any of them ends the streak, a night on any of them counts. Loot = Loot Log awards that count as loot
-- received (ns.AwardCounts: not offspec / disenchant / guild bank, not 5-man dungeon loot, only gear: a bag or a
-- recipe does not end it). Counted: the closed nights they came to (not benched) that started after that award,
-- and the boss kills they were there for in those nights. The night running now is not counted.
-- The guild's loot rules (Council > Rules, y) say what a night is: "n" (default) only nights they were really there for
-- (a boss kill, or half the night), "a" any night they showed up.
-- Returns { nights, bosses, came = nights they showed up at all, last = the award entry (nil: none on record),
-- first = the oldest night counted } or nil:
-- no closed night logged, or I don't hold the whole Loot Log (only the guild council does; demo mode: the demo's).
-- Cached until the raid log or the Loot Log changes.
local dryCache = {}

function Att:CanSeeDryStreaks()
    if DemoOn() then return true end
    local Guild, me = G(), Me()
    return (me and Guild and Guild.IsGuildCouncil and Guild:IsGuildCouncil(me)) and true or false
end

function Att:GetDryStreak(key)
    key = Util.NormalizeName(key)
    if not key or not self:CanSeeDryStreaks() then return nil end
    -- (a demo scenario's staged streak, Core/DemoScenarios.lua)
    local D = ns.Demo
    local staged = D and D.Override and D:Override(key, "dry")
    if staged then return { nights = staged, bosses = staged * 4, came = staged } end
    local Ledger = ns.Ledger
    local token = Ledger and Ledger.GetViewToken and Ledger:GetViewToken()
    local Guild = G()
    local lr = Guild and Guild.GetLootRules and Guild:GetLootRules()
    local any = lr and lr.y == "a"
    if dryCache.ver ~= ver or dryCache.demo ~= DemoOn() or dryCache.token ~= token or dryCache.any ~= any then
        dryCache = { ver = ver, demo = DemoOn(), token = token, any = any, by = {} }
    end
    local c = dryCache.by[key]
    if c ~= nil then return c or nil end
    local nights = self:ClosedNights()
    if #nights == 0 then
        dryCache.by[key] = false
        return nil
    end
    local chars = { [key] = true }
    for _, k in ipairs(Linked(key)) do chars[k] = true end
    local last
    for k in pairs(chars) do
        for _, e in ipairs(Ledger and Ledger.GetEntries and Ledger:GetEntries({ player = k, excludeDungeon = true }) or {}) do
            if ns.AwardCounts(e) then
                if not last or e.ts > last.ts then last = e end
                break   -- (newest first)
            end
        end
    end
    -- (the demo's raids carry their awards along, Demo.lua)
    for _, n in ipairs(DemoOn() and nights or {}) do
        for _, rec in ipairs(n.recs or {}) do
            for _, e in ipairs(rec.demoAwards or {}) do
                if chars[e.w] and ns.AwardCounts(e) and (not last or e.ts > last.ts) then last = e end
            end
        end
    end
    local since = last and last.ts or 0
    local out = { nights = 0, bosses = 0, came = 0, last = last }
    for _, n in ipairs(nights) do   -- (newest first)
        if (n.start or 0) <= since then break end
        local came, kills, there, long = false, 0, 0, 0
        for _, rec in ipairs(n.recs or {}) do
            local most, best = 0, 0
            for k in pairs(chars) do
                local a = rec.att and rec.att[k]
                if type(a) == "table" and not a.b then
                    came = true
                    most = max(most, tonumber(a.k) or 0)
                    local t, s = 0, CopyPieces(a, rec)
                    for i = 1, #(s or {}) - 1, 2 do t = t + max(0, (s[i + 1] or 0) - (s[i] or 0)) end
                    best = max(best, t)
                end
            end
            kills = kills + most
            there = there + best
            long = long + max(0, (rec.stop or rec.start or 0) - (rec.start or 0))
        end
        if came then out.came = out.came + 1 end
        -- (really there: a boss kill, or half the night)
        if came and (any or kills > 0 or (long > 0 and there * 2 >= long)) then
            out.nights = out.nights + 1
            out.bosses = out.bosses + kills
            out.first = n
        end
    end
    dryCache.by[key] = out
    return out
end

---------------------------------------------------------------------------
-- Reviews
---------------------------------------------------------------------------

-- { pending = { r... }, handled = { r... } } over the last REVIEW_DAYS (decisions of the last HANDLED_DAYS under
-- handled), newest night first. Each r has .night.
local reviewsCache
function Att:GetReviews()
    if reviewsCache and reviewsCache.ver == ver then return reviewsCache.data end
    local rules = self:Rules()
    local since = Now() - REVIEW_DAYS * DAY
    local nights = {}
    for _, n in ipairs(self:GetNights()) do
        if (n.start or 0) >= since and not n.open then nights[#nights + 1] = n end
    end
    local pending, handled = {}, {}
    for _, item in ipairs(self:Results(nights, rules)) do
        local rows = {}
        for _, r in pairs(item.results) do rows[#rows + 1] = r end
        tsort(rows, function(a, b) return a.key < b.key end)
        for _, r in ipairs(rows) do
            if r.kind and r.pending then
                pending[#pending + 1] = r
            elseif r.kind and r.decision and (r.decision.at or 0) >= Now() - HANDLED_DAYS * DAY then
                handled[#handled + 1] = r
            end
        end
    end
    tsort(handled, function(a, b) return (a.decision.at or 0) > (b.decision.at or 0) end)
    reviewsCache = { ver = ver, data = { pending = pending, handled = handled } }
    return reviewsCache.data
end

-- How many reviews wait for a decision (for the reviewers' count badges).
function Att:PendingCount()
    if not self:CanReview() then return 0 end
    return #self:GetReviews().pending
end

-- The record a night's edits go on (its first: the newest), or nil.
local function EditRecord(nightKey)
    local n = Att:GetNight(nightKey)
    return n and n.primary or nil, n
end

local function Edited(rec)
    Bump()
    local L = RL()
    if L and L.NoteEdit then L:NoteEdit(rec) end
end

-- A reviewer decides: d = "x" (excuse) | "c" (counts) | nil (undo), with an optional note. Returns ok, err.
function Att:Decide(nightKey, key, d, note)
    if not self:CanReview() then return false, "Only the Guild Master, officers and the guild council decide." end
    local rec, n = EditRecord(nightKey)
    if not rec then return false, "That raid is no longer in the log." end
    if n.demo ~= (DemoOn() or nil) and DemoOn() then return false, "Demo mode: only the demo raids." end
    if d ~= nil and d ~= "x" and d ~= "c" then return false, "unknown decision" end
    note = type(note) == "string" and note:gsub("[%c|]", " "):sub(1, MAX_TEXT) or nil
    rec.dc = rec.dc or {}
    -- (a decision taken back stays as a newer marker, d = "u": removing it would let any older copy come back)
    local at = Now()
    for _, other in ipairs(n.recs) do
        local old = other.dc and other.dc[key]
        if old and (old.at or 0) >= at then at = old.at + 1 end
    end
    rec.dc[key] = { d = d or "u", by = Me(), at = at, n = d and note ~= "" and note or nil }
    Edited(rec)
    return true
end

-- Keeps chat lines as a player's reason: lines = { { t, ch, at }, ... } (at most 5; {} clears). The reviewers, and
-- while the raid runs its leader. Returns ok, err.
function Att:Pick(nightKey, key, lines)
    local rec = EditRecord(nightKey)
    if not rec then return false, "That raid is no longer in the log." end
    local GR = ns.GroupRules
    local leader = not rec.stop and GR and GR.IsAuthority and GR:IsAuthority()
    if not (self:CanReview() or leader) then return false, "Only the Guild Master, officers and the guild council pick reasons." end
    local clean = {}
    for i = 1, MAX_PICK do
        local l = type(lines) == "table" and lines[i]
        if type(l) ~= "table" then break end
        local t = type(l.t) == "string" and l.t:gsub("[%c|]", " "):sub(1, MAX_TEXT) or nil
        if t and t ~= "" and tonumber(l.at) then clean[#clean + 1] = { t = t, ch = l.ch or "Guild", at = floor(l.at) } end
    end
    rec.q = rec.q or {}
    -- (no lines: kept as an empty, newer pick, so clearing spreads like any change)
    rec.q[key] = { by = Me(), at = Now(), l = clean }
    Edited(rec)
    if leader and #clean > 0 then
        local public = {}
        for _, l in ipairs(clean) do
            if l.ch ~= "Whisper" then public[#public + 1] = l end
        end
        if #public > 0 then self:BroadcastMark(rec, key, { q = public, at = rec.q[key].at - 1 }) end
    end
    return true
end

---------------------------------------------------------------------------
-- Away periods: excuse every raid of a stretch in one go
---------------------------------------------------------------------------

local demoAway = {}
local function AwayList(create)
    if DemoOn() then return demoAway end
    return (ns.DB:GuildBucket("attAway", create))
end

-- The away periods of a player (or everyone's), newest first: { k, f, t, n, by, at }.
function Att:GetAway(key)
    local out = {}
    for _, p in ipairs(AwayList(false) or {}) do
        if key == nil or p.k == key or SameAccount(p.k, key) then out[#out + 1] = p end
    end
    tsort(out, function(a, b) return a.f > b.f end)
    return out
end

local function ApplyPeriod(p)
    local count = 0
    for _, n in ipairs(Att:GetNights()) do
        if (n.start or 0) >= p.f and (n.start or 0) < p.t + DAY then
            for key in pairs(n.ex) do
                if (key == p.k or SameAccount(key, p.k)) and not n.dc[key] then
                    local rec = n.primary
                    rec.dc = rec.dc or {}
                    rec.dc[key] = { d = "x", by = p.by, at = Now(), n = p.n }
                    count = count + 1
                    Edited(rec)
                end
            end
        end
    end
    return count
end

-- A reviewer excuses a player from every raid from day `from` to day `to` (server times; whole days), now and when
-- raids of those days are logged later. Returns ok, count or err.
function Att:ExcusePeriod(key, from, to, note)
    if not self:CanReview() then return false, "Only the Guild Master, officers and the guild council excuse raids." end
    from, to = tonumber(from), tonumber(to)
    if not (from and to) or to < from then return false, "Pick the first and last day." end
    if to - from > 120 * DAY then return false, "An away period is at most 120 days." end
    local list = AwayList(true)
    if not list then return false, "Your guild is not known yet." end
    local text = ("Away %s – %s"):format(date("%d %b", from), date("%d %b", to))
    note = type(note) == "string" and note:gsub("[%c|]", " "):sub(1, 120) or ""
    local p = { k = key, f = from, t = to, n = note ~= "" and (text .. ": " .. note) or text, by = Me(), at = Now() }
    list[#list + 1] = p
    while #list > 100 do table.remove(list, 1) end
    return true, ApplyPeriod(p)
end

function Att:RemoveAway(p)
    local list = AwayList(false)
    for i, x in ipairs(list or {}) do
        if x == p then
            table.remove(list, i)
            -- (the excuses it gave are taken back: a newer "u" marker, so that spreads too)
            for _, n in ipairs(self:GetNights()) do
                for key, e in pairs(n.dc) do
                    if e.d == "x" and e.n == p.n and e.by == p.by and (key == p.k or SameAccount(key, p.k)) then
                        local rec = n.primary
                        rec.dc = rec.dc or {}
                        rec.dc[key] = { d = "u", by = Me(), at = max(Now(), (e.at or 0) + 1) }
                        Edited(rec)
                    end
                end
            end
            Bump()
            return true
        end
    end
    return false
end

-- Raids logged later inside an away period (mine, as a reviewer) get the excuse too.
local function ApplyAllAway()
    if DemoOn() or not Att:CanReview() then return end
    for _, p in ipairs(AwayList(false) or {}) do
        if p.t + DAY >= Now() - REVIEW_DAYS * DAY then ApplyPeriod(p) end
    end
end

---------------------------------------------------------------------------
-- Chat lines (memory only): what a player said, to pick as their reason
---------------------------------------------------------------------------

local CHAT_EVENTS = {
    CHAT_MSG_RAID = "Raid", CHAT_MSG_RAID_LEADER = "Raid", CHAT_MSG_RAID_WARNING = "Raid",
    CHAT_MSG_PARTY = "Party", CHAT_MSG_PARTY_LEADER = "Party", CHAT_MSG_GUILD = "Guild",
    CHAT_MSG_OFFICER = "Officer", CHAT_MSG_WHISPER = "Whisper",
}

local LIKELY = { "gtg", "g2g", "got to go", "gotta go", "have to go", "need to go", "sorry", "dc", "disconnect",
    "crash", "brb", "afk", "work", "sick", "kid", "baby", "power", "internet", "net died", "late", "can't make",
    "cant make", "cannot make", "can't come", "cant come", "emergency", "family", "bed", "sleep", "doctor", "storm" }

-- Without colour codes, links ([Item]) and textures; nil when nothing is left.
local function Plain(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|T.-|t", "")
        :gsub("|", ""):gsub("%c", " ")
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil end
    return text:sub(1, MAX_TEXT)
end

local function IsLikely(text)
    local low = " " .. text:lower() .. " "
    for _, w in ipairs(LIKELY) do
        if low:find("[^%a]" .. w:gsub("(%p)", "%%%1") .. "[^%a]") then return true end
    end
    return false
end

local function OnChat(event, text, sender)
    local ch = CHAT_EVENTS[event]
    local key = ch and type(sender) == "string" and Util.NormalizeName(sender)
    if not key or Util.IsMe(key) then return end
    if not InGuild(key) and not (UnitInRaid and UnitInRaid(Util.ShortName(key) or "")) then return end
    local t = Plain(text)
    if not t then return end
    local list = chat[key]
    if not list then
        if chatPlayers >= CHAT_MAX_PLAYERS then return end
        list = {}
        chat[key] = list
        chatPlayers = chatPlayers + 1
    end
    local now = Now()
    while list[1] and (now - list[1].at > CHAT_KEEP or #list >= CHAT_PER_PLAYER) do table.remove(list, 1) end
    list[#list + 1] = { t = t, ch = ch, at = now }
end

-- What a player (and their other characters) said from `from` to `to`, oldest first: { t, ch, at, likely }.
function Att:GetChat(key, from, to)
    local out = {}
    local keys = { key }
    for _, m in ipairs(Linked(key)) do keys[#keys + 1] = m end
    for _, k in ipairs(keys) do
        for _, l in ipairs(chat[k] or {}) do
            if l.at >= (from or 0) and l.at <= (to or math.huge) then
                out[#out + 1] = { t = l.t, ch = l.ch, at = l.at, likely = IsLikely(l.t), who = k }
            end
        end
    end
    tsort(out, function(a, b) return a.at < b.at end)
    return out
end

-- The window chat lines are offered from for a result: around the leave (15 min before, 30 after), else the day
-- before the raid to the day after.
function Att:ChatWindow(r)
    if r and r.left > 0 and not r.noShow and r.last then return r.last - 15 * 60, r.last + 30 * 60 end
    local F = r and r.F or Now()
    return F - DAY, (r and r.T or F) + DAY
end

-- Demo / tests: a chat line as if it was heard.
function Att:NoteChat(key, ch, text, at)
    local t = Plain(text)
    if not (key and t) then return end
    chat[key] = chat[key] or {}
    local list = chat[key]
    list[#list + 1] = { t = t, ch = ch or "Guild", at = at or Now() }
    tsort(list, function(a, b) return a.at < b.at end)
end

---------------------------------------------------------------------------
-- During the raid: the raid leader's marks, who is not here yet, my own leave
---------------------------------------------------------------------------

-- The night running now (my open record's), or nil.
function Att:GetLiveNight()
    local L = RL()
    local rec = L and L.GetOpenRecord and L:GetOpenRecord()
    return rec and self:NightOf(rec) or nil, rec
end

-- Is `key` expected in the raid running now (or one of their characters)? Returns the expected key.
function Att:ExpectedKey(n, key)
    if not n then return nil end
    if n.ex[key] then return key end
    for e in pairs(n.ex) do
        if SameAccount(e, key) then return e end
    end
    return nil
end

-- Expected players not in the group (yet), once the start + on-time margin has passed: { r... } with r.inGroup false.
function Att:GetNotHereYet()
    local n = self:GetLiveNight()
    if not n or n.loose then return {} end
    local rules = self:Rules()
    local facts = NightFacts(n, rules)
    if Now() < facts.F + rules.onTime then return {} end
    local inGroup = {}
    for i = 1, (GetNumGroupMembers() or 0) do
        local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
        if type(name) == "string" and online then inGroup[Util.NormalizeName(name)] = true end
    end
    local out = {}
    for key in pairs(n.ex) do
        local here = inGroup[key]
        if not here then
            for _, m in ipairs(Linked(key)) do
                if inGroup[m] then here = true break end
            end
        end
        local r = self:Result(n, key, rules)
        if not here and not r.bench and not r.removed then out[#out + 1] = r end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The leader's mark on the open record: what = "b" (benched) | "rm" (removed) | "od" (officers decide) | "sw" (key is
-- the fill-in for `arg`); also sent to the raid so every recorder keeps it. Returns ok.
function Att:LeaderMark(key, what, arg)
    local L = RL()
    local rec = L and L.GetOpenRecord and L:GetOpenRecord()
    local GR = ns.GroupRules
    if not rec or not (GR and GR.IsAuthority and GR:IsAuthority()) or type(key) ~= "string" then return false end
    local m = { by = Me(), at = Now() }
    if what == "b" then m.b = true
    elseif what == "rm" then m.rm = true
    elseif what == "od" then m.od = true
    elseif what == "sw" and type(arg) == "string" then m.sw = arg
    else return false end
    local old = rec.mk and rec.mk[key]
    if old then
        if old.at and old.at >= m.at then m.at = old.at + 1 end
        m.b = m.b or old.b
        m.rm = m.rm or old.rm
        m.od = m.od or old.od
        m.sw = m.sw or old.sw
    end
    rec.mk = rec.mk or {}
    rec.mk[key] = m
    Edited(rec)
    self:BroadcastMark(rec, key, m)
    return true
end

function Att:BroadcastMark(rec, key, m)
    local Comm = ns.Comm
    if DemoOn() or not (Comm and Comm.Send and IsInRaid()) then return end
    Comm:Send({ t = "ATM", s = rec.id, k = key, b = m.b, rm = m.rm, od = m.od, sw = m.sw, at = m.at or Now(), q = m.q },
        "RAID", nil, "data")
end

-- ATM: the raid leader's mark (or picked chat lines) for the raid running now.
local function OnMark(sender, msg, dist)
    if dist ~= "RAID" or type(msg) ~= "table" or type(msg.k) ~= "string" then return end
    local L, GR = RL(), ns.GroupRules
    local rec = L and L.GetOpenRecord and L:GetOpenRecord()
    if not rec or msg.s ~= rec.id or not GR then return end
    local from = Util.NormalizeName(sender)
    if not from or from ~= GR:GetAuthority() then return end
    local key = Util.NormalizeName(msg.k)
    if not key then return end
    local at = tonumber(msg.at)
    if not at then return end
    at = floor(at)
    if type(msg.q) == "table" then
        local lines = {}
        for i = 1, MAX_PICK do
            local l = msg.q[i]
            if type(l) ~= "table" then break end
            local t = Plain(l.t)
            if t and tonumber(l.at) then lines[#lines + 1] = { t = t, ch = type(l.ch) == "string" and l.ch or "Raid", at = floor(l.at) } end
        end
        rec.q = rec.q or {}
        rec.q[key] = { by = from, at = at, l = lines }
    else
        local m = { by = from, at = at, b = msg.b == true or nil, rm = msg.rm == true or nil, od = msg.od == true or nil,
                    sw = type(msg.sw) == "string" and Util.NormalizeName(msg.sw) or nil }
        local old = rec.mk and rec.mk[key]
        if old and (old.at or 0) > at then return end
        rec.mk = rec.mk or {}
        rec.mk[key] = m
    end
    Edited(rec)
end

-- The leader invites a guild member to replace `out` (Swap in...): the mark lands when they join.
function Att:InviteFor(key, out)
    if type(key) ~= "string" or type(out) ~= "string" then return false end
    if DemoOn() then return true end
    pendingSwap[key] = out
    if InviteUnit then InviteUnit(Util.ShortName(key) or key) end
    return true
end

local function OnJoined(recId, key)
    local out = pendingSwap[key]
    if not out then return end
    pendingSwap[key] = nil
    Att:LeaderMark(key, "sw", out)
end

-- My own reason for leaving early: kept on my record and sent to the raid's leader and the online raid log readers.
-- code: "life" | "dc" | "asked" | "other". Returns ok.
function Att:SendReason(recId, code, note)
    local L = RL()
    local rec = L and L.GetRaid and type(recId) == "string" and L:GetRaid(recId)
    if type(recId) ~= "string" then return false end
    note = type(note) == "string" and note:gsub("[%c|]", " "):sub(1, MAX_TEXT) or nil
    if note == "" then note = nil end
    code = type(code) == "string" and code:match("^%a+$") and code:sub(1, 16) or nil
    if not (code or note) then return false end
    local me, at = Me(), Now()
    -- (a raid I wasn't in, or explained days later: no record here; the raid log readers keep it)
    if type(rec) == "table" then
        rec.rs = rec.rs or {}
        rec.rs[me] = { c = code, n = note, at = at }
        Edited(rec)
    end
    local Comm = ns.Comm
    if DemoOn() or not (Comm and Comm.Send) then return true end
    local msg = { t = "ATY", s = recId, c = code, n = note, at = at }
    local seen = {}
    local targets = {}
    local auth = leaving and leaving.id == recId and leaving.auth or nil
    if auth and not Util.IsMe(auth) then targets[#targets + 1] = auth; seen[auth] = true end
    local Guild = G()
    for _, key in ipairs(Guild and Guild.GetOnlineMembers and Guild:GetOnlineMembers() or {}) do
        if #targets >= 10 then break end
        if not seen[key] and not Util.IsMe(key) and Att:CanSeeAll(key) then
            seen[key] = true
            targets[#targets + 1] = key
        end
    end
    for _, key in ipairs(targets) do Comm:Send(msg, "WHISPER", key, "data") end
    return true
end

-- ATY: a player's own reason for a raid I logged.
local function OnReason(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg) ~= "table" then return end
    local key = Util.NormalizeName(sender)
    local L = RL()
    local rec = key and L and L.GetRaid and type(msg.s) == "string" and L:GetRaid(msg.s)
    local Comm = ns.Comm
    if not key or (Comm and Comm.RateLimit and not Comm:RateLimit("ATY:" .. key, 10)) then return end
    local at = tonumber(msg.at)
    if not at or at > Now() + 300 then return end
    local note = type(msg.n) == "string" and Plain(msg.n) or nil
    local code = type(msg.c) == "string" and msg.c:match("^%a+$") and msg.c:sub(1, 16) or nil
    if not (code or note) then return end
    if type(rec) ~= "table" then
        if type(msg.s) == "string" and #msg.s <= 64 and not msg.s:find("[%c|]") and Att:CanSeeAll() then
            Att:HoldReason(msg.s, key, { c = code, n = note, at = floor(at) })
        end
        return
    end
    if rec.demo then return end
    local old = rec.rs and rec.rs[key]
    if old and (old.at or 0) >= at then return end
    rec.rs = rec.rs or {}
    rec.rs[key] = { c = code, n = note, at = floor(at) }
    Edited(rec)
end

-- Reasons for raids not in my log yet: db.attHeld[guild][recId][key] = { c, n, at, held }, kept 7 days, put on the
-- record when it arrives (the raid log sync, a later raid log digest).
local function HeldStore(create)
    return (ns.DB:GuildBucket("attHeld", create))
end

function Att:HoldReason(recId, key, rs)
    local st = HeldStore(true)
    if not st then return end
    local n = 0
    for _ in pairs(st) do n = n + 1 end
    if n >= 50 and not st[recId] then return end
    st[recId] = st[recId] or {}
    rs.held = Now()
    st[recId][key] = rs
end

local function ApplyHeld()
    local st = HeldStore(false)
    if not st then return end
    local L = RL()
    for recId, list in pairs(st) do
        local rec = L and L.GetRaid and L:GetRaid(recId)
        if type(rec) == "table" then
            for key, rs in pairs(list) do
                local old = rec.rs and rec.rs[key]
                if not old or (old.at or 0) < rs.at then
                    rec.rs = rec.rs or {}
                    rec.rs[key] = { c = rs.c, n = rs.n, at = rs.at }
                    Edited(rec)
                end
            end
            st[recId] = nil
        else
            for key, rs in pairs(list) do
                if Now() - (rs.held or 0) > 7 * DAY then list[key] = nil end
            end
            if not next(list) then st[recId] = nil end
        end
    end
end

-- I leave the group myself (Leave Group) during a raid that expects me, before its planned end: ask why.
local function OnLeaveParty()
    local n, rec = Att:GetLiveNight()
    if not (n and rec) then return end
    local me = Me()
    if not Att:ExpectedKey(n, me) then return end
    local rules = Att:Rules()
    if n.et and Now() >= n.et - rules.onTime then return end
    local GR = ns.GroupRules
    leaving = { id = rec.id, auth = GR and GR.GetAuthority and GR:GetAuthority() or nil, T = n.et }
    -- (after the group is gone: the prompt asks once I am out)
    Util.After(1, function() ns:Fire("ATTENDANCE_LEFT_EARLY", rec.id, n.et) end)
end

-- The leader removed someone (Remove from Group): that is the leader's call, not the player leaving.
local function OnUninvite(name)
    if type(name) ~= "string" then return end
    local GR = ns.GroupRules
    if not (GR and GR.IsAuthority and GR:IsAuthority()) then return end
    local key = Util.NormalizeName(name)
    local n = Att:GetLiveNight()
    if key and n and Att:ExpectedKey(n, key) then Att:LeaderMark(Att:ExpectedKey(n, key), "rm") end
end

-- A player left the group during the raid I lead: tell the attendance prompt (UI) when they were expected and the
-- raid's planned end is still ahead (not when I removed them: OnUninvite marked that).
local function OnLeft(recId, key)
    local GR = ns.GroupRules
    if not (GR and GR.IsAuthority and GR:IsAuthority()) then return end
    Bump()
    local n = Att:GetLiveNight()
    if not n or n.loose then return end
    local e = Att:ExpectedKey(n, key)
    if not e then return end
    local r = Att:Result(n, e)
    if r.removed or r.bench then return end
    -- (an open raid without a planned end: any leave is before the end)
    local rules = Att:Rules()
    if n.et and Now() >= n.et - rules.onTime then return end
    -- (several expected players leaving at once: the raid is breaking up, no prompt for each)
    local now = Now()
    Att.recentLeaves = Att.recentLeaves or {}
    local list = Att.recentLeaves
    list[#list + 1] = now
    while list[1] and now - list[1] > BURST_SEC do table.remove(list, 1) end
    if #list >= BURST_N then
        ns:Fire("ATTENDANCE_BREAKUP", recId)
        return
    end
    ns:Fire("ATTENDANCE_PLAYER_LEFT", recId, e, key)
end

---------------------------------------------------------------------------
-- My own attendance (members see theirs; the records live with the raid log readers)
---------------------------------------------------------------------------

local function MineStore(create)
    return (ns.DB:GuildBucket("attMine", create))
end

-- A history compact enough for a message: { p = pct, n = counted, h = { { d, z, c, s, k }, ... } } (newest first).
local function Compact(key)
    local hist, stats = Att:GetHistory(key, 12)
    local h = {}
    for i, e in ipairs(hist) do
        if i > 12 then break end
        local r = e.r
        local zone = e.night.zone
        if #e.night.recs > 1 and e.night.pl then
            local RP = ns.RaidPlan
            local v = RP and RP.GetRaid and RP:GetRaid(e.night.pl)
            if v then zone = RP:GetRaidName(v) end
        end
        h[#h + 1] = { d = e.night.start, z = zone and zone:sub(1, 40) or nil,
                      c = r.credit and floor(r.credit * 100 + 0.5) or nil, s = Code(r), k = r.kind or (r.help and "h"),
                      i = e.night.primary and e.night.primary.id or nil, rs = r.reason and true or nil }
    end
    return { p = stats and stats.pct or nil, n = stats and stats.counted or 0, h = h, at = Now() }
end

-- My attendance: computed here when I see everyone's, else the copy a reader sent me (nil until one has).
function Att:GetMine()
    if self:CanSeeAll() then return Compact(Me()) end
    local st = MineStore(false)
    return st and st.data or nil
end

-- Asks an online raid log reader for my attendance (at most every 5 minutes); the page that shows it calls this.
function Att:RequestMine()
    if self:CanSeeAll() or DemoOn() then return false end
    local st = MineStore(true)
    if not st then return false end
    if st.asked and Now() - st.asked < 300 then return false end
    local Guild, Comm = G(), ns.Comm
    if not (Guild and Comm and Comm.Send) then return false end
    local readers = {}
    for _, key in ipairs(Guild:GetOnlineMembers() or {}) do
        if not Util.IsMe(key) and self:CanSeeAll(key) then readers[#readers + 1] = key end
    end
    if #readers == 0 then return false end
    st.asked = Now()
    -- (one at a time; the next one when no answer came in 10 seconds: an older DisasterZone doesn't answer)
    local asked = Now()
    local function ask(k)
        local key = readers[k]
        if not key then return end
        Comm:Send({ t = "ATQ" }, "WHISPER", key, "ctrl")
        Util.After(10, function()
            local cur = MineStore(false)
            local got = cur and cur.data and (cur.data.at or 0) >= asked
            if not got then ask(k + 1) end
        end)
    end
    ask(1)
    return true
end

local function OnAsk(sender, msg, dist)
    if dist ~= "WHISPER" or not Att:CanSeeAll() then return end
    local key = Util.NormalizeName(sender)
    local Comm = ns.Comm
    if not key or not InGuild(key) or not (Comm and Comm.Send) then return end
    if Comm.RateLimit and not Comm:RateLimit("ATQ:" .. key, 60) then return end
    Util.RandomDelay(0.5, 2, function() Comm:Send({ t = "ATR", a = Compact(key) }, "WHISPER", key, "data") end)
end

local function OnAnswer(sender, msg, dist)
    if dist ~= "WHISPER" or type(msg) ~= "table" or type(msg.a) ~= "table" then return end
    local key = Util.NormalizeName(sender)
    if not key or not Att:CanSeeAll(key) then return end
    local a = msg.a
    local h = {}
    for i = 1, 12 do
        local e = type(a.h) == "table" and a.h[i]
        if type(e) ~= "table" then break end
        local d = tonumber(e.d)
        if d then
            h[#h + 1] = { d = floor(d), z = Plain(e.z), c = tonumber(e.c) and max(0, min(100, floor(e.c))) or nil,
                          s = type(e.s) == "string" and e.s:sub(1, 3) or "-", k = type(e.k) == "string" and e.k:sub(1, 1) or nil,
                          i = type(e.i) == "string" and #e.i <= 64 and not e.i:find("[%c|]") and e.i or nil, rs = e.rs == true or nil }
        end
    end
    local st = MineStore(true)
    if not st then return end
    st.data = { p = tonumber(a.p) and max(0, min(100, floor(a.p))) or nil, n = tonumber(a.n) or 0, h = h, at = Now(),
                from = key }
    ns:Fire("ATTENDANCE_MINE")
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Att:OnInit()
    for _, m in ipairs({ "RAIDLOG_CHANGED", "DEMO_TOGGLED", "ATTENDANCE_RULES_CHANGED", "ROSTER_UPDATED",
                         "RAIDPLAN_CHANGED", "PROFESSIONS_UPDATED" }) do
        ns:On(m, Bump)
    end
    ns:On("RAIDLOG_LEFT", OnLeft)
    ns:On("RAIDLOG_JOINED", function(...)
        Bump()
        OnJoined(...)
    end)
    ns:On("RAIDLOG_CHANGED", function()
        Util.Debounce("att-away", 3, function()
            ApplyAllAway()
            ApplyHeld()
        end)
    end)
    for event in pairs(CHAT_EVENTS) do ns:RegisterEvent(event, OnChat) end
    if ns.Comm and ns.Comm.Register then
        ns.Comm:Register("ATM", OnMark)
        ns.Comm:Register("ATY", OnReason)
        ns.Comm:Register("ATQ", OnAsk)
        ns.Comm:Register("ATR", OnAnswer)
    end
    if hooksecurefunc then
        if LeaveParty then hooksecurefunc("LeaveParty", OnLeaveParty) end
        if C_PartyInfo and C_PartyInfo.LeaveParty then hooksecurefunc(C_PartyInfo, "LeaveParty", OnLeaveParty) end
        if UninviteUnit then hooksecurefunc("UninviteUnit", OnUninvite) end
        if C_PartyInfo and C_PartyInfo.UninviteUnit then hooksecurefunc(C_PartyInfo, "UninviteUnit", OnUninvite) end
    end
end

-- (my own attendance is asked for when I open it, never at login: a guild's logins would all ask at once)

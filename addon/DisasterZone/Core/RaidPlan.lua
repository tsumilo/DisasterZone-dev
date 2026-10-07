if DisasterZoneBoot and DisasterZoneBoot.Run("Core/RaidPlan.lua", ...) then return end -- DisasterZone: Core/RaidPlan.lua
-- Raid planning (Addendum J §54-§57): teams, raid events (one-off or weekly), sign-ups and group layouts.
--
-- The raid planners (the GM and the raid leaders list, §62) write weekly series (S) and events (E: a one-off raid, or
-- an override of one occurrence of a series); the GM and the guild council write teams (T). Every character writes
-- only its own sign-ups (U). Everything is cached by every guild member and kept per guild in db.raidplan[guildKey].
--
-- A raid names teams (tm) and extra invites (inv: players outside those teams). Left open, anyone signs up and the
-- teams only say who is expected. Locked (lk), only the members of its teams and its extra invites sign up; a
-- sign-up of anyone else is not counted (it is hidden, and shows again when they are invited or the lock goes), and
-- the raid is not listed for them (GetRaids / CanSee).
--
-- A raid can ask for a minimum character level (ml; the New raid window sets 70 unless the planner allows lower
-- characters). A character below it can't sign up and its answer is not counted; the raid stays listed for it.
--
-- Guests, and answers the organizers set aside (stored on the raid's own record, so they travel with it):
--   gu  guests: players outside the guild an organizer added by name { [key] = { c, sp, at } }. A guest counts as
--       accepted, can be placed in a group and is invited with the others.
--   rj  declined: the organizers turned that member down { [key] = true }. Their answer is not counted, they can't
--       answer again, and they are listed apart from Bench (GetDeclined).
--   rm  removed: an answer taken off { [key] = rev of that answer }. A newer answer of the member counts again.
--   gx  guests taken off by hand { [key] = when }: whoever adds the pugs of the raid's group automatically (GuestBook)
--       leaves them out; adding them by hand again clears the mark.
-- A member's other characters (Guild:SameAccount) answer as one player: a character can be signed up from any of
-- them (RPA), the newest answer of the player is the one that counts, and a decline covers all of them.
--
-- A raid can have its own leader (rl, named by the GM or a raid leader on the list; rlb = who named them). That
-- leader runs the raid: edit, cancel, delete, players and guests, groups, together with the GM and the raid leaders on
-- the list (the leader need not be on it); the guild council does not. Its strategy picks and names are the leader's
-- and the GM's alone (a raid without a leader: the raid leaders on the list and the GM); everyone else reads them
-- (user decisions 2026-10-04). On a weekly raid the series names the leader and a week's override can name another
-- (false: none); a leader of one week only edits and cancels that week, they don't delete it.
--
-- The blacklist (BLL) blocks a player from every raid: no sign-up, no guest seat, no invite. Kept by the roster
-- managers: the GM, officers and the raid leaders.
--
-- Sync (§56): live edits go out on GUILD (RPU, RPS). At login the HELLO carries a hash of my plan data (pd); a client
-- whose data differs answers with its per-item digest (RPD, on GUILD so the others can stay quiet), the new client
-- asks for the items that differ (RPW) and sends its own copy of them; items travel one per message (RPG).
-- Records merge by rev (then by hash), so both sides converge. A version whose writer may not write it (see Trusted)
-- never replaces one that shows, and only who names leaders changes a stored raid's leader: a hand-made message
-- can't delete, change or take over a raid on a client that holds it. (A copy passed on by someone else, RPG, can't
-- prove who wrote it: a client that never had the record takes it at its word.)
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
-- 1.3.2: a team's lineups and their waitlists (section "Lineups and waitlists"); one table, the main chunk is near
-- Lua's 200 locals
local Lineup = {
    MAX = 10,               -- lineups per team
    ID_LEN = 6,             -- a lineup's id
    MAX_WAIT = 25,          -- players on one lineup's waitlist
    MAX_STORED = 60,        -- waitlist entries kept per lineup, with the taken-off ones (pruned after 30 days)
}
local MAX_SERIES = 12
local MAX_EVENTS = 60
local MAX_SIGNUPS = 60              -- per occurrence
local MAX_SIGNUP_OCCS = 150         -- occurrences with sign-ups (bounds what a sender can make me store)
local MAX_TEAMS_PER_RAID = 10
local MAX_INVITES = 40              -- extra invites per raid (players outside its teams)
local MAX_GROUP_ENTRIES = 40
local MAX_DIGEST_ITEMS = 100
local MAX_RPS_ENTRIES = 30
local MAX_KEY_LEN = 48
local MAX_ID_LEN = 24
local MAX_NAME_LEN = 32             -- team names, raid titles
local MAX_NOTE_LEN = 120            -- raid notes
local MAX_SIGNUP_NOTE = 40
local MAX_LEVEL = 70                -- the level cap: the highest minimum level a raid can ask for
local MAX_GUESTS = 25               -- guests per raid
local MAX_MARKS = 60                -- declined / removed answers per raid
local MAX_BLACKLIST = 100           -- players on the guild's blacklist
local MAX_REASON_LEN = 80           -- a blacklist entry's reason
local MAX_STAMP = 4294967295
local BLL_REPLY_LIMIT = 30

local RPD_DELAY_COUNCIL = { 0.5, 2.5 }
local RPD_DELAY_MEMBER = { 3, 8 }
local ROUND_WINDOW = 20             -- seconds an RPD round for one client lasts (suppression / answer once)
local MAX_PENDING = 20              -- newer versions refused for now, tried again when the guild's roles change
local RESTAMP_AFTER_LOGIN = 90      -- the guild's lists and ranks settle first (plus a spread by name, below)
local RESTAMP_WAIT = 20             -- after a change of roles
local RESTAMP_SPREAD = 40           -- up to this many seconds more, by name: one planner usually writes first
local MAX_RESTAMPS = 10             -- records written again per pass

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
local pending = {}                  -- ["kind:id"] = { kind, rec, via }: newer versions refused for now (MergeRecord)
local asks = {}                     -- [digest item] = true: records to ask a raid planner for (AskPlanner)
local asked = {}                    -- [digest item] = rev: the version a planner was asked about last
local restampQueued = false         -- a pass of RestampPass is scheduled

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

-- Who may do what (§55, §62, user rules 2026-09-29):
--   raids  (create / edit / cancel / delete): the GM and the raid leaders list
--   teams  (members, specs, team groups):     the GM and the guild council
--   groups (a raid's group layout):          the GM, the raid leaders, and the guild council on a raid without its
--                                            own leader
local function IsOrganizer(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsRaidPlanner ~= nil and G:IsRaidPlanner(key) and true or false
end

local function CanTeams(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsGuildCouncil ~= nil and G:IsGuildCouncil(key) and true or false
end

local function CanGroups(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsRaidLogMember ~= nil and G:IsRaidLogMember(key) and true or false
end

-- roster (guests from outside the guild, declining / removing answers, the guest book, the blacklist): those who
-- plan raids (the GM, the raid leaders) and the officers. Not the guild council: they don't invite guild members to
-- raids either (user decision 2026-10-04).
local function CanRoster(key)
    if IsOrganizer(key) then return true end
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsOfficer ~= nil and G:IsOfficer(key) and true or false
end

-- A raid's own leader is named by the GM and the raid leaders on the list (the raid planners).
local function CanAssignLeader(key)
    return IsOrganizer(key)
end

local function IsOfficer(key)
    local G = Guild()
    return type(key) == "string" and G ~= nil and G.IsOfficer ~= nil and G:IsOfficer(key) and true or false
end

-- The same player: the same character, or another character of their account (Guild:SameAccount).
local function SamePlayer(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then return false end
    if a == b then return true end
    local G = Guild()
    return G ~= nil and G.SameAccount ~= nil and G:SameAccount(a, b) and true or false
end

-- The leader a stored raid record names and who named them: its own (an override's false: none that week), else its
-- series'. Only a leader named by the GM or a raid leader on the list counts.
local function RecLeader(root, kind, rec)
    local rl, rlb = rec.rl, rec.rlb
    if rl == nil and kind == "E" and rec.sid then
        local s = root.S[rec.sid]
        if s then rl, rlb = s.rl, s.rlb end
    end
    if type(rl) ~= "string" or not CanAssignLeader(rlb) then return nil end
    return rl, rlb
end

-- Was this record written by the raid's own leader?
local function LeaderWrote(root, kind, rec)
    local rl = RecLeader(root, kind, rec)
    return rl ~= nil and SamePlayer(rec.by, rl)
end

-- May `key` run the raid (a view): edit, cancel, delete, players? The raid planners (the GM, the raid leaders on the
-- list), and the raid's own leader when it has one.
local function CanManage(v, key)
    if type(key) ~= "string" or type(v) ~= "table" then return false end
    return IsOrganizer(key) or (v.rl ~= nil and SamePlayer(key, v.rl))
end

-- May `key` lay out the raid's groups? The same, plus the guild council on a raid without a leader.
local function CanArrange(v, key)
    if type(key) ~= "string" or type(v) ~= "table" then return false end
    if v.rl then return CanManage(v, key) end
    return CanGroups(key)
end

-- May `key` pick the raid's strategies and assign its players (the Assignments tab)? Only who leads it: its own
-- leader, or on a raid without one the raid leaders on the list; and the GM. Everyone else only reads them (user rule
-- 2026-10-04).
local function CanAssignJobs(v, key)
    if type(key) ~= "string" or type(v) ~= "table" then return false end
    local G = Guild()
    if G ~= nil and G.IsGM ~= nil and G:IsGM(key) then return true end
    if v.rl then return SamePlayer(key, v.rl) end
    return IsOrganizer(key)
end

local ALLOWED ={ raids = IsOrganizer, teams = CanTeams, groups = CanGroups, roster = CanRoster }
local REFUSED = {
    roster = "Only the Guild Master, officers and the raid leaders can do that.",
    raids = "Only the Guild Master and the raid leaders can plan raids.",
    teams = "Only the Guild Master and the guild council can change teams.",
    groups = "Only the Guild Master, the guild council and the raid leaders can change a raid's groups.",
    led = "Only this raid's leader, the Guild Master and the raid leaders can change it.",
    lead = "Only the Guild Master and the raid leaders choose a raid's leader.",
    week = "You lead this week only: you can cancel it, not delete it.",
}

-- May the writer of this version of a record (rec.by) write it, by the rules as they are now? Teams: the GM and the
-- guild council. Raids: the raid planners, the raid's own leader, the guild council on a version without a leader (its
-- group layout), and the officers on a raid's own record (its guests and declined answers). A raid is deleted only by
-- who runs it: a deletion (del) by an officer or the council is not theirs to write.
local function Entitled(root, kind, rec)
    local by = rec.by
    if kind == "T" then return CanTeams(by) end
    if IsOrganizer(by) or LeaderWrote(root, kind, rec) then return true end
    if kind == "E" and rec.del then return false end
    if CanGroups(by) and not RecLeader(root, kind, rec) then return true end
    return kind == "E" and IsOfficer(by)
end

-- The trust mark of a record version: kind, id, rev and writer, so a made-up copy of that version by someone else
-- doesn't share the mark.
local function TrustKey(kind, rec)
    return kind .. ":" .. tostring(rec.id) .. ":" .. tostring(rec.rev) .. ":" .. tostring(rec.by)
end

-- A raid / team shows when its writer was entitled to write it when this version arrived, or is now: a raid leader
-- taken off the list later doesn't make their raids vanish where they were seen. Kept per record version, locally
-- (root.OK). A client that gets the version only later goes by the rules then: see RestampPass.
local function Trusted(root, kind, rec)
    if not rec then return false end
    local k = TrustKey(kind, rec)
    if root.OK and root.OK[k] then return true end
    if not Entitled(root, kind, rec) then return false end
    if root.OK then root.OK[k] = true end
    return true
end

-- Do two versions of a raid record name the same leader, named by the same player, in their own fields (rl / rlb)?
local function SameCrown(a, b)
    return a.rl == b.rl and a.rlb == b.rlb
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
    for _, k in ipairs({ "T", "S", "E", "U", "W", "OK" }) do
        if type(r[k]) ~= "table" then r[k] = {} end
    end
    -- 1.3: trust marks name the version's writer too (TrustKey); a mark of before is moved to the version stored
    if r.okv ~= 2 then
        local old = r.OK
        r.OK = {}
        for k in pairs(old) do
            local kind, id, rev = k:match("^(%u):([^:]+):(%d+)$")
            local rec = kind and type(r[kind]) == "table" and r[kind][id]
            if type(rec) == "table" and tostring(rec.rev) == rev then r.OK[TrustKey(kind, rec)] = true end
        end
        r.okv = 2
    end
    return r
end

-- GetSignups is asked many times per page refresh (each raid card, my answer, the counts): its answer is kept for the
-- rest of the frame, until the data changes (dataVer: any raid plan change, a sign-up merged, the roster, the linked
-- characters, the blacklist or the settings).
local dataVer = 0
local function Touch() dataVer = dataVer + 1 end
for _, msg in ipairs({ "ROSTER_UPDATED", "ACCOUNTS_UPDATED", "CONFIG_UPDATED", "RAID_BLACKLIST_CHANGED",
                       "GUILD_KEY_READY", "DEMO_TOGGLED" }) do
    ns:On(msg, Touch)
end

local function Changed()
    Touch()
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

-- A raid's extra invites: player keys, sorted, without doubles. nil = none given, false = invalid.
local function CleanInvites(inv)
    if inv == nil then return nil end
    if type(inv) ~= "table" then return false end
    local out, seen = {}, {}
    for i = 1, MAX_INVITES + 1 do
        local v = inv[i]
        if v == nil then break end
        local k = WireKey(v)
        if i > MAX_INVITES or not k then return false end
        if not seen[k] then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    tsort(out)
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

-- gs: each placed player's seat in their group { [key] = 1..5 } (display order only). Lenient: bad entries and
-- players outside grp are dropped, so an odd seat never costs the layout. Returns the map or nil.
local function CleanSeats(gs, grp)
    if type(gs) ~= "table" or type(grp) ~= "table" then return nil end
    local out, n = {}, 0
    for key, s in pairs(gs) do
        n = n + 1
        if n > MAX_GROUP_ENTRIES then return nil end
        local k = WireKey(key)
        if k and grp[k] and IsInt(s, 1, 5) then out[k] = s end
    end
    return next(out) and out or nil
end

-- 1.3.2: a team's lineups (L): { { id, n = name|nil, sz = 10|25, s = specs, grp, gs, cp }, ... }, at most
-- Lineup.MAX, the first one first (what a raid uses when it names none of that size). Only the roster's members (set)
-- keep a spec or a group. Returns the clean list, nil for none, false when invalid (the record is refused, as a team
-- with a bad comp is).
function Lineup.CleanList(L, set)
    if L == nil then return nil end
    if type(L) ~= "table" then return false end
    local out, seen = {}, {}
    for i = 1, Lineup.MAX + 1 do
        local l = L[i]
        if l == nil then break end
        if i > Lineup.MAX or type(l) ~= "table" or not IsId(l.id) or #l.id > Lineup.ID_LEN or seen[l.id]
            or not SIZES[l.sz] then
            return false
        end
        seen[l.id] = true
        local e = { id = l.id, sz = l.sz }
        if l.n ~= nil then
            e.n = CleanText(l.n, MAX_NAME_LEN)
            if not e.n then return false end
        end
        if l.s ~= nil then
            if type(l.s) ~= "table" then return false end
            for key, sp in pairs(l.s) do
                local k = WireKey(key)
                if not k or not IsInt(sp, 1, 4) then return false end
                if set[k] then
                    e.s = e.s or {}
                    e.s[k] = sp
                end
            end
        end
        local grp = CleanGroups(l.grp)
        if grp == false then return false end
        for k, g in pairs(grp or {}) do
            if set[k] then
                e.grp = e.grp or {}
                e.grp[k] = g
            end
        end
        e.gs = CleanSeats(l.gs, e.grp)
        if l.cp ~= nil then
            local cp = ns.RaidComp:CleanComp(l.cp, l.sz)
            if not cp then return false end
            e.cp = cp
        end
        out[#out + 1] = e
    end
    return #out > 0 and out or nil
end

-- A newer team version from a client before 1.3.2 (MergeRecord): my lineups, the first one taking that version's
-- sz / s / grp / gs / cp, each keeping only its new roster's specs and groups. A new list, or nil.
function Lineup.CarryOver(L, rec)
    local set = {}
    for _, k in ipairs(rec.m or {}) do set[k] = true end
    local list = {}
    for i, l in ipairs(L) do
        local c = { id = l.id, n = l.n, sz = l.sz, s = l.s, grp = l.grp, gs = l.gs, cp = l.cp }
        if i == 1 then c.sz, c.s, c.grp, c.gs, c.cp = rec.sz or 25, rec.s, rec.grp, rec.gs, rec.cp end
        list[i] = c
    end
    return Lineup.CleanList(list, set) or nil
end

-- A stored team's lineups: its L, or (a team saved before 1.3.2) one lineup "1" made of sz / s / grp / gs / cp.
function Lineup.Of(t)
    if type(t.L) == "table" and t.L[1] then return t.L end
    return { { id = "1", sz = t.sz or 25, s = t.s, grp = t.grp, gs = t.gs, cp = t.cp } }
end

-- A raid's lineup of each team (tl): { [team id] = lineup id }. nil = none given, false = invalid.
function Lineup.CleanChoice(tl)
    if tl == nil then return nil end
    if type(tl) ~= "table" then return false end
    local out, n = {}, 0
    for id, ln in pairs(tl) do
        n = n + 1
        if n > MAX_TEAMS_PER_RAID or not IsId(id) or not IsId(ln) or #ln > Lineup.ID_LEN then return false end
        out[id] = ln
    end
    return out
end

-- A waitlist entry { rev, by, at = when they joined, o = their place when moved (else at), sp = the spec they'd
-- play } or a taken-off one { rev, by, x = true }. nil when invalid.
function Lineup.CleanWait(e, now)
    if type(e) ~= "table" or not IsInt(e.rev, 1, now + FUTURE_SLACK) then return nil end
    local by = WireKey(e.by)
    if not by then return nil end
    local out = { rev = e.rev, by = by }
    if e.x == true then
        out.x = true
        return out
    end
    if not IsInt(e.at, 1, e.rev) then return nil end
    out.at = e.at
    if e.o ~= nil then
        if not IsInt(e.o, 0, MAX_STAMP) then return nil end
        out.o = e.o
    end
    if e.sp ~= nil then
        if not IsInt(e.sp, 1, 4) then return nil end
        out.sp = e.sp
    end
    return out
end

-- gu: guests { [key] = { c = classFile, sp = spec index, at = when added } }. nil = none, false = invalid.
local function CleanGuests(gu)
    if gu == nil then return nil end
    if type(gu) ~= "table" then return false end
    local out, n = {}, 0
    for key, g in pairs(gu) do
        n = n + 1
        if n > MAX_GUESTS then return false end
        local k = WireKey(key)
        if not k or type(g) ~= "table" or type(g.c) ~= "string" or not (ns.SPECS and ns.SPECS[g.c]) then return false end
        local e = { c = g.c }
        if g.sp ~= nil then
            if not IsInt(g.sp, 1, SpecCount(g.c)) then return false end
            e.sp = g.sp
        end
        if g.at ~= nil then
            if not IsInt(g.at, 1, MAX_STAMP) then return false end
            e.at = g.at
        end
        out[k] = e
    end
    return next(out) and out or nil
end

-- rj / rm / gx: { [key] = true } (numeric = false) or { [key] = rev or time } (numeric = true). nil = none, false =
-- invalid.
local function CleanMarks(m, numeric)
    if m == nil then return nil end
    if type(m) ~= "table" then return false end
    local out, n = {}, 0
    for key, val in pairs(m) do
        n = n + 1
        if n > MAX_MARKS then return false end
        local k = WireKey(key)
        if not k then return false end
        if numeric then
            if not IsInt(val, 1, MAX_STAMP) then return false end
            out[k] = val
        else
            if val ~= true then return false end
            out[k] = true
        end
    end
    return next(out) and out or nil
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
    out.gs = CleanSeats(r.gs, out.grp)
    -- 1.3.1: the team's target comp (Core/RaidComp.lua): a bad one refuses the record, as a bad s does
    if r.cp ~= nil then
        local cp = ns.RaidComp:CleanComp(r.cp, out.sz or 25)
        if not cp then return nil end
        out.cp = cp
    end
    -- 1.3.2: the lineups (Lineup.CleanList). The first one is mirrored on sz / s / grp / gs / cp, which is all a
    -- client before 1.3.2 knows of the team.
    if r.L ~= nil then
        local L = Lineup.CleanList(r.L, set)
        if L == false then return nil end
        out.L = L
    end
    return out
end

-- 1.3.2: the instances a raid holds after its first (i), in the night's order (ix): { key, ... }, each known, once.
-- nil = none given, false = invalid.
local function CleanInstanceList(ix)
    if ix == nil then return nil end
    if type(ix) ~= "table" then return false end
    local out, seen = {}, {}
    for n = 1, #INSTANCES do
        local key = ix[n]
        if key == nil then break end
        if not INSTANCE_BY_KEY[key] or seen[key] then return false end
        seen[key] = true
        out[n] = key
    end
    if ix[#INSTANCES] ~= nil then return false end
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
    -- 1.3.2: more instances the same night, after i (an override says {}: that week holds i alone)
    local ix = CleanInstanceList(r.ix)
    if ix == false then return false end
    if ix and (#ix > 0 or partial) then out.ix = ix end
    local tm = CleanTeamIds(r.tm)
    if tm == false then return false end
    out.tm = tm
    -- 1.3.2: the lineup it uses of each team (default: the team's first of the raid's size); an override says {}
    local tl = Lineup.CleanChoice(r.tl)
    if tl == false then return false end
    if tl and (next(tl) or partial) then out.tl = tl end
    -- locked to its teams and extra invites; an override says false / {} to undo what its series says
    if r.lk ~= nil then
        if type(r.lk) ~= "boolean" then return false end
        if r.lk or partial then out.lk = r.lk end
    end
    -- private: a locked raid hidden from those it doesn't take, who can't ask to join either (false undoes the series')
    if r.pv ~= nil then
        if type(r.pv) ~= "boolean" then return false end
        if r.pv or partial then out.pv = r.pv end
    end
    local inv = CleanInvites(r.inv)
    if inv == false then return false end
    if inv and (#inv > 0 or partial) then out.inv = inv end
    -- the minimum character level; an override says 0 to undo what its series says
    if r.ml ~= nil then
        if not IsInt(r.ml, 0, MAX_LEVEL) then return false end
        if r.ml > 0 or partial then out.ml = r.ml end
    end
    if r.ti ~= nil then
        out.ti = CleanText(r.ti, MAX_NAME_LEN)
        if not out.ti then return false end
    end
    if r.no ~= nil then
        out.no = CleanText(r.no, MAX_NOTE_LEN)
        if not out.no then return false end
    end
    -- the raid's own leader and who named them; an override says false for no leader that week
    if r.rl == false then
        if not partial then return false end
        out.rl = false
    elseif r.rl ~= nil then
        out.rl, out.rlb = WireKey(r.rl), WireKey(r.rlb)
        if not (out.rl and out.rlb) then return false end
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
        -- (1.3) with the raid's leader of the version deleted: a deletion by that leader is theirs to write
        if r.rl == false then
            if not sid then return nil end
            out.rl = false
        elseif r.rl ~= nil then
            out.rl, out.rlb = WireKey(r.rl), WireKey(r.rlb)
            if not (out.rl and out.rlb) then return nil end
        end
        return out
    end
    if r.x == true then out.x = true end
    if not CleanRaidFields(out, r, now, sid ~= nil) then return nil end
    local grp = CleanGroups(r.grp)
    if grp == false then return nil end
    out.grp = grp
    out.gs = CleanSeats(r.gs, grp)
    local gu, rj, rm, gx = CleanGuests(r.gu), CleanMarks(r.rj, false), CleanMarks(r.rm, true), CleanMarks(r.gx, true)
    if gu == false or rj == false or rm == false or gx == false then return nil end
    out.gu, out.rj, out.rm, out.gx = gu, rj, rm, gx
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

-- Keeps a newer version MergeRecord refused, to try it again when the guild's roles change (RetryPending): its writer
-- may only look unentitled because the guild's lists or ranks are still on their way to me.
local function HoldBack(kind, rec, via)
    local k = kind .. ":" .. rec.id
    local cur = pending[k]
    if cur and not Newer(rec, cur.rec) then return end
    if not cur and CountTable(pending) >= MAX_PENDING then return end
    pending[k] = { kind = kind, rec = rec, via = via }
end

-- Asks a raid planner who is online (the first by name) for their copy of these records (RPW): a raid's leader that
-- changed while I was away is taken from a planner's copy (MergeRecord). Once per version of a record (a made-up one
-- comes back with every sync); gathered for a moment, one message.
local function AskPlanner(item, rev, via)
    if asked[item] == rev then return end
    asked[item] = rev
    asks[item] = true
    Util.Debounce("raidplan-ask", 2, function()
        local list = {}
        for i in pairs(asks) do list[#list + 1] = i end
        asks = {}
        tsort(list)
        local G = Guild()
        local me = Util.PlayerKey()
        for _, key in ipairs(G and G.GetOnlineMembers and G:GetOnlineMembers() or {}) do
            if key ~= me and key ~= via and CanAssignLeader(key) then
                Send({ t = "RPW", w = list }, "WHISPER", key, "ctrl")
                return
            end
        end
    end)
end

-- Stores a clean record of kind T / S / E (via: who sent it to me; the writer for a live edit). Returns true when
-- stored. Over a version that shows (Trusted), a newer one is stored only when its writer may write it, and a raid's
-- leader (rl / rlb) changes only when someone who names leaders wrote it or passed it on (a hand-made message can't
-- delete a raid, wipe its sign-ups or name a leader). A record I don't have yet can't be checked against anything: it
-- is stored, and shows only when its writer is entitled, as before.
local function MergeRecord(root, kind, rec, via)
    local store = root[kind]
    local cur = store[rec.id]
    if cur then
        -- A client before 1.3.1 drops a team's target comp (cp) from the copy it passes on, one before 1.3.2 its
        -- lineups (L): of two copies of a version that differ only by those, the one with more of them wins
        -- (whatever their hashes), and one with fewer never replaces mine. (Two edits in the same second that differ
        -- elsewhere still go by the hash.)
        local tie
        if kind == "T" and rec.rev == cur.rev then
            local na = (rec.cp and 1 or 0) + (rec.L and 1 or 0)
            local nb = (cur.cp and 1 or 0) + (cur.L and 1 or 0)
            if na ~= nb then
                local a, b = {}, {}
                for k, v in pairs(rec) do if k ~= "cp" and k ~= "L" then a[k] = v end end
                for k, v in pairs(cur) do if k ~= "cp" and k ~= "L" then b[k] = v end end
                if Util.Hash(a) == Util.Hash(b) then tie = na > nb end
            end
        end
        if tie == false then return false end
        if tie == nil and not Newer(rec, cur) then return false end
        -- A newer version of a team from a client before 1.3.2 (no L) changed the team as it knows it: the roster and
        -- the first lineup (sz / s / grp / gs / cp). The other lineups are carried over from mine.
        if kind == "T" and not rec.del and rec.L == nil and type(cur.L) == "table" and rec.rev > cur.rev then
            rec.L = Lineup.CarryOver(cur.L, rec)
        end
        -- A client before 1.3 drops the guests and the declined / removed answers from the copy it passes on: the
        -- same version of a raid without them never replaces mine.
        if kind == "E" and rec.rev == cur.rev and (cur.gu or cur.rj or cur.rm or cur.gx)
            and not (rec.gu or rec.rj or rec.rm or rec.gx) then
            return false
        end
        -- nor without the raid's leader (1.3), or the lineups it uses (1.3.2)
        if rec.rev == cur.rev and cur.rl ~= nil and rec.rl == nil then return false end
        if kind ~= "T" and rec.rev == cur.rev and cur.tl ~= nil and rec.tl == nil then return false end
        -- nor without the night's other instances (1.3.2)
        if kind ~= "T" and rec.rev == cur.rev and cur.ix ~= nil and rec.ix == nil then return false end
        if Trusted(root, kind, cur) then
            if kind ~= "T" and not SameCrown(cur, rec) and not CanAssignLeader(rec.by) and not CanAssignLeader(via) then
                -- named while I was away, or made up: a planner's copy tells
                HoldBack(kind, rec, via)
                AskPlanner((kind == "S" and "S:" or "O:") .. rec.id, rec.rev, via)
                return false
            end
            if not Trusted(root, kind, rec) then
                HoldBack(kind, rec, via)
                return false
            end
        end
    elseif CountTable(store) >= KIND_CAP[kind] then
        ns:Debug("RaidPlan: %s store full, %s dropped", kind, rec.id)
        return false
    end
    store[rec.id] = rec
    local p = pending[kind .. ":" .. rec.id]
    if p and not Newer(p.rec, rec) then pending[kind .. ":" .. rec.id] = nil end
    -- a deleted raid takes its sign-ups with it (a deletion its writer may not make doesn't)
    if Trusted(root, kind, rec) and kind == "E" and rec.del then root.U[rec.id] = nil end
    -- (a deleted team its waitlists)
    if Trusted(root, kind, rec) and kind == "T" and rec.del then root.W[rec.id] = nil end
    return true
end

-- The refused versions again, after a change of the guild's roles (or of who shares an account).
local function RetryPending()
    local root = next(pending) and Root(false)
    if not root then return end
    local list = pending
    pending = {}
    local changed = false
    for _, p in pairs(list) do
        if MergeRecord(root, p.kind, p.rec, p.via) then changed = true end
    end
    if changed then Changed() end
end

local function MergeSignup(root, occId, key, s)
    local e = root.E[occId]
    if e and e.del and Trusted(root, "E", e) then return false end
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
    Touch()
    return true
end

-- 1.3.2: a waitlist entry (clean) of player `key` on lineup ln of team tid (root.W[tid][ln][key]); newer rev wins.
function Lineup.MergeWait(root, tid, ln, key, e)
    if not IsId(tid) or not IsId(ln) or #ln > Lineup.ID_LEN then return false end
    local t = root.T[tid]
    if t and t.del then return false end
    local team = root.W[tid]
    if not team then
        if CountTable(root.W) >= MAX_TEAMS * 2 then return false end
        team = {}
        root.W[tid] = team
    end
    local list = team[ln]
    if not list then
        if CountTable(team) >= Lineup.MAX * 2 then return false end
        list = {}
        team[ln] = list
    end
    local cur = list[key]
    if cur then
        if not Newer(e, cur) then return false end
    elseif CountTable(list) >= Lineup.MAX_STORED then
        return false
    end
    list[key] = e
    return true
end

-- A team's waitlists as relayed (RPG w): { [lineup id] = { [player] = entry } }. Returns true when one changed.
function Lineup.MergeAll(tid, w)
    local root = Root(true)
    if not root then return false end
    local now, changed, nl = Now(), false, 0
    for ln, list in pairs(w) do
        nl = nl + 1
        if nl > Lineup.MAX * 2 then break end
        if type(ln) == "string" and type(list) == "table" then
            local n = 0
            for key, e in pairs(list) do
                n = n + 1
                if n > Lineup.MAX_STORED then break end
                local k = WireKey(key)
                local c = k and Lineup.CleanWait(e, now)
                if c and Lineup.MergeWait(root, tid, ln, k, c) then changed = true end
            end
        end
    end
    return changed
end

-- RTW { l = { { tm = team id, ln = lineup id, k = player, e = entry }, ... } } on GUILD: live waitlist entries. Each
-- player writes their own (joining, leaving); the GM and the guild council anyone's (taking off, moving up or down).
function Lineup.OnLive(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.l) ~= "table" then return end
    local root = Root(true)
    if not root then return end
    local now, changed = Now(), false
    for i = 1, MAX_RPS_ENTRIES do
        local x = msg.l[i]
        if x == nil then break end
        local k = type(x) == "table" and WireKey(x.k)
        local e = k and Lineup.CleanWait(x.e, now)
        if e and e.by == sender and (k == sender or CanTeams(sender)) and type(x.ln) == "string"
            and Lineup.MergeWait(root, x.tm, x.ln, k, e) then
            changed = true
        end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Occurrences (the resolved view the UI reads)
---------------------------------------------------------------------------

local RAID_FIELDS = { "t", "i", "ix", "sz", "tm", "tl", "ti", "no", "lk", "pv", "inv", "ml", "rl", "rlb" }

-- The view's leader: a leader named by the GM or a raid leader on the list, else none (rl, rlb = nil).
local function ViewLeader(v)
    if type(v.rl) ~= "string" or not CanAssignLeader(v.rlb) then v.rl, v.rlb = nil, nil end
    return v
end

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

local function CopyGuests(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    for k, g in pairs(t) do out[k] = { c = g.c, sp = g.sp, at = g.at } end
    return out
end

-- The view of a visible one-off event.
local function ViewEvent(e)
    return ViewLeader({
        id = e.id, t = e.t, i = e.i, ix = CopyList(e.ix), sz = e.sz, tm = CopyList(e.tm) or {}, tl = CopyMap(e.tl),
        ti = e.ti, no = e.no,
        lk = e.lk and true or false, pv = e.pv and true or false, inv = CopyList(e.inv) or {}, ml = (e.ml or 0) > 0 and e.ml or nil,
        cancelled = e.x and true or false, grp = CopyMap(e.grp), gs = CopyMap(e.gs), by = e.by, rev = e.rev,
        gu = CopyGuests(e.gu), rj = CopyMap(e.rj), rm = CopyMap(e.rm), gx = CopyMap(e.gx), rl = e.rl, rlb = e.rlb,
        weekly = false,
    })
end

-- The view of series occurrence k (nil when the series doesn't have it).
local function ViewOccurrence(root, s, k)
    if s.x or k < 0 or (s.u and k > s.u) then return nil end
    local occId = OccId(s.id, k)
    local o = root.E[occId]
    if o and not Trusted(root, "E", o) then o = nil end
    if o and o.del then return nil end
    local v = {
        id = occId, sid = s.id, k = k, by = s.by, rev = s.rev, weekly = true, cancelled = false, lastWeek = s.u,
    }
    for _, f in ipairs(RAID_FIELDS) do
        local val = s[f]
        if o and o[f] ~= nil then val = o[f] end
        if f == "t" and not (o and o.t) then val = SeriesTime(s, k) end
        v[f] = type(val) == "table" and (f == "tl" and CopyMap(val) or CopyList(val)) or val
    end
    v.tm = v.tm or {}
    v.lk = v.lk and true or false
    v.pv = v.pv and true or false
    v.inv = v.inv or {}
    if (v.ml or 0) <= 0 then v.ml = nil end
    if o then
        v.cancelled = o.x and true or false
        v.grp = CopyMap(o.grp)
        v.gs = CopyMap(o.gs)
        v.gu, v.rj, v.rm, v.gx = CopyGuests(o.gu), CopyMap(o.rj), CopyMap(o.rm), CopyMap(o.gx)
        v.override = true
    end
    return ViewLeader(v)
end

local function ResolveOcc(root, occId)
    if not root or type(occId) ~= "string" then return nil end
    local sid, k = SplitOcc(occId)
    if sid then
        local s = root.S[sid]
        if not s or not Trusted(root, "S", s) then return nil end
        return ViewOccurrence(root, s, k)
    end
    local e = root.E[occId]
    if not e or e.sid or e.del or not Trusted(root, "E", e) then return nil end
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
        if not rec then return nil end
        -- (a team's waitlists travel with it: a new item kind would make clients before 1.3.2 drop the whole digest)
        local w = kind == "T" and root.W[id]
        if w and next(w) then return Util.Hash({ rec, w }):sub(1, 6) end
        return Util.Hash(rec):sub(1, 6)
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

-- kind: "RPS" (default: my own answers) or "RPA" (answers for other characters of my account; entries carry k).
local function BroadcastSignups(list, kind)
    if #list == 0 then return end
    for i = 1, #list, MAX_RPS_ENTRIES do
        local chunk = {}
        for j = i, min(#list, i + MAX_RPS_ENTRIES - 1) do chunk[#chunk + 1] = list[j] end
        Send({ t = kind or "RPS", l = chunk }, "GUILD", nil, "ctrl")
    end
end

-- One digest item to `target` (RPG, whisper).
local function SendItem(root, item, target)
    local kind, id = item:match("^(%u):(.+)$")
    local msg
    if kind == "T" and root.T[id] then
        msg = { t = "RPG", T = root.T[id], w = root.W[id] }
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

-- via: who sent it to me (MergeRecord).
local function StoreRecord(kind, r, via)
    local root = Root(true)
    if not root then return false end
    local now = Now()
    local rec
    if kind == "T" then rec = CleanTeam(r, now)
    elseif kind == "S" then rec = CleanSeries(r, now)
    elseif kind == "E" then rec = CleanEvent(r, now)
    end
    if not rec then return false end
    return MergeRecord(root, kind, rec, via)
end

-- RPU { k, r }: an organizer's live edit (the editor must be the sender).
local function OnUpdate(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.r) ~= "table" or WireKey(msg.r.by) ~= sender then return end
    if not (msg.k == "T" or msg.k == "S" or msg.k == "E") then return end
    if StoreRecord(msg.k, msg.r, sender) then Changed() end
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

-- RPA { l = { { o = occId, k = character, s = signup }, ... } }: the sender's answers for other characters of their
-- account (each must vouch for the other). Its own message: clients before 1.3 would file them under the sender.
local function OnAltSignups(sender, msg, dist)
    if dist ~= "GUILD" or type(msg.l) ~= "table" then return end
    local root = Root(true)
    local G = Guild()
    if not root or not (G and G.SameAccount) then return end
    local now, changed = Now(), false
    for i = 1, MAX_RPS_ENTRIES do
        local e = msg.l[i]
        if e == nil then break end
        local key = type(e) == "table" and IsOccId(e.o) and WireKey(e.k)
        if key and key ~= sender and G:SameAccount(sender, key) then
            local s = CleanSignup(e.s, now)
            if s and MergeSignup(root, e.o, key, s) then changed = true end
        end
    end
    if changed then Changed() end
end

-- RPG: one item (a team, a series, or an occurrence's override + sign-ups), relayed by anyone in the guild. The
-- records go through the same checks as a live edit (MergeRecord); who relays them only counts for a raid's leader.
local function OnGive(sender, msg, dist)
    if dist ~= "WHISPER" then return end
    local changed = false
    if msg.T ~= nil then
        changed = StoreRecord("T", msg.T, sender)
        -- (1.3.2) its waitlists: { [lineup id] = { [player] = entry } }, taken at their word like relayed sign-ups
        if type(msg.w) == "table" and type(msg.T) == "table" and IsId(msg.T.id) and Lineup.MergeAll(msg.T.id, msg.w) then
            changed = true
        end
    elseif msg.S ~= nil then
        changed = StoreRecord("S", msg.S, sender)
    elseif IsOccId(msg.o) then
        local root = Root(true)
        if not root then return end
        local now = Now()
        if msg.e ~= nil then
            local e = CleanEvent(msg.e, now)
            if e and e.id == msg.o and MergeRecord(root, "E", e, sender) then changed = true end
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

-- RPK { to }: someone is about to answer that client's HELLO with a digest.
local function OnClaim(sender, msg, dist)
    if dist ~= "GUILD" then return end
    local to = WireKey(msg.to)
    if to and not Util.IsMe(to) then roundSeen[to] = { h = "", at = GetTime() } end
end

-- Sync calls this for every HELLO on GUILD (pd = the sender's plan hash; nil from clients before 0.7).
function RaidPlan:OnHelloDigest(sender, pd)
    if type(pd) ~= "string" or #pd > 8 or type(sender) ~= "string" then return end
    local mine = self:GetDigestHash()
    if mine == "0" or pd == mine then return end
    if not RateLimit("RPDh:" .. sender, ROUND_WINDOW) then return end
    local G = Guild()
    local delay = (G and G.IsGuildCouncil and G:IsGuildCouncil(Util.PlayerKey())) and RPD_DELAY_COUNCIL or RPD_DELAY_MEMBER
    -- With item data still waiting in my queue the digest (and what the newcomer then asks for) would wait behind
    -- it: answer after the members whose queue is empty had their turn (they serve the newcomer faster).
    local Comm = ns.Comm
    local queued = Comm and Comm.Backlog and Comm:Backlog("data") or 0
    local busy = queued > 0 and min(12, 6 + queued / 240) or 0
    -- Still catching up myself (my own round was answered moments ago): what I hold is incomplete, so I only answer
    -- once that settled, if nobody else did.
    busy = max(busy, ROUND_WINDOW - (GetTime() - answeredAt))
    Util.RandomDelay(delay[1] + busy, delay[2] + busy, function()
        local h = RaidPlan:GetDigestHash()
        local seen = roundSeen[sender]
        -- Somebody answered this round already (whatever their hash): the newcomer syncs with the first answer only
        -- (answeredAt in OnDigest), so one more is noise.
        if h == "0" or (seen and GetTime() - seen.at < ROUND_WINDOW) then return end
        roundSeen[sender] = { h = h, at = GetTime() }
        -- The digest waits in the bulk queue behind item data; this short claim on the (mostly idle) live prefix tells the
        -- others right away that the round is answered (older clients have no handler for it and ignore it).
        Send({ t = "RPK", to = sender }, "GUILD", nil, "live")
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

-- The instances a raid view holds, in the night's order (1.3.2): { key, ... } (its i, then ix; each once).
function RaidPlan:GetRaidInstances(v)
    local out, seen = {}, {}
    if type(v) ~= "table" then return out end
    local function add(key)
        if INSTANCE_BY_KEY[key] and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
        end
    end
    add(v.i)
    for _, key in ipairs(type(v.ix) == "table" and v.ix or {}) do add(key) end
    return out
end

-- The display name of a raid view: its title, else its instance's name, else (several instances) their short names
-- ("Gruul + Mag").
function RaidPlan:GetRaidName(v)
    if type(v) ~= "table" then return "?" end
    if v.ti then return v.ti end
    local list = self:GetRaidInstances(v)
    if #list > 1 then return ns.RaidComp:ShortInstanceNames(list) end
    local inst = INSTANCE_BY_KEY[list[1]]
    return inst and inst.name or "?"
end

function RaidPlan:IsOrganizer(key)
    return IsOrganizer(key)
end

-- May I plan raids (create new ones)? A raid that exists: CanManageRaid.
function RaidPlan:CanOrganize()
    return IsOrganizer(Util.PlayerKey())
end

-- May I build teams?
function RaidPlan:CanManageTeams()
    return CanTeams(Util.PlayerKey())
end

-- A raid (a view or an id) -> its view, or nil.
local function AsView(occId)
    if type(occId) == "table" then return occId end
    return RaidPlan:GetRaid(occId)
end

-- May I (or that player) change the raid's group layout? Without a raid: may I lay out groups at all.
function RaidPlan:CanEditGroups(occId, key)
    key = key or Util.PlayerKey()
    if occId == nil then return CanGroups(key) end
    return CanArrange(AsView(occId), key)
end

-- The raid's own leader (a view or an id), or nil (then every raid planner runs it).
function RaidPlan:GetRaidLeader(occId)
    local v = AsView(occId)
    return v and v.rl or nil
end

-- Is that player (default: me), or another character of theirs, the raid's own leader?
function RaidPlan:IsLeaderOf(occId, key)
    local rl = self:GetRaidLeader(occId)
    return rl ~= nil and SamePlayer(key or Util.PlayerKey(), rl)
end

-- May I (or that player) run the raid: edit, cancel, delete, add players? The GM and the raid leaders on the list,
-- and the raid's own leader.
function RaidPlan:CanManageRaid(occId, key)
    return CanManage(AsView(occId), key or Util.PlayerKey())
end

-- Who decides for a whole weekly series: a view that has only the series' own leader (a week's leader doesn't count).
-- A one-off raid: its own view.
local function SeriesWho(root, v)
    local s = v.sid and root and root.S[v.sid]
    if not s then return v end
    return ViewLeader({ rl = s.rl, rlb = s.rlb })
end

-- May I (or that player) change a whole weekly series (every week, stop repeating, delete it)? The GM, the raid
-- leaders on the list and the series' own leader; a leader of one week only runs that week. A one-off raid: who runs it.
function RaidPlan:CanManageSeries(occId, key)
    local v = AsView(occId)
    return v ~= nil and CanManage(SeriesWho(Root(false), v), key or Util.PlayerKey())
end

-- May I (or that player) delete the raid (scope "series": the whole weekly series)? Who runs it, but a leader of one
-- week of a weekly raid edits and cancels that week, they don't delete it (user decision 2026-10-04).
function RaidPlan:CanDeleteRaid(occId, scope, key)
    local v = AsView(occId)
    key = key or Util.PlayerKey()
    if not v then return false end
    if v.sid and scope == "series" then return self:CanManageSeries(v, key) end
    return CanManage(v, key) and CanManage(SeriesWho(Root(false), v), key)
end

-- May I (or that player) pick the raid's strategies and assign its players? Its own leader (a raid without one: the
-- raid leaders on the list) and the GM; read-only for everyone else.
function RaidPlan:CanAssignStrategies(occId, key)
    return CanAssignJobs(AsView(occId), key or Util.PlayerKey())
end

-- May I (or that player) name a raid's leader? The GM and the raid leaders on the list.
function RaidPlan:CanAssignLeader(key)
    return CanAssignLeader(key or Util.PlayerKey())
end

-- Visible teams, sorted by name: { id, name, members = { key, ... }, by, rev }.
function RaidPlan:GetTeams()
    local out = {}
    local root = Root(false)
    if not root then return out end
    for id, t in pairs(root.T) do
        if not t.del and Trusted(root, "T", t) then out[#out + 1] = RaidPlan:GetTeam(id) end
    end
    tsort(out, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.id < b.id
    end)
    return out
end

-- A visible team: { id, name, members = { key, ... }, by, rev, lineups = { { id, name|nil, size, specs, groups,
-- seats, comp|nil }, ... } } (copies). size / specs / groups / seats / comp: its first lineup's, as before 1.3.2.
function RaidPlan:GetTeam(id)
    local root = Root(false)
    local t = root and type(id) == "string" and root.T[id]
    if not t or t.del or not Trusted(root, "T", t) then return nil end
    local lineups = {}
    for i, l in ipairs(Lineup.Of(t)) do
        lineups[i] = { id = l.id, name = l.n, size = l.sz, specs = CopyMap(l.s) or {}, groups = CopyMap(l.grp) or {},
                       seats = CopyMap(l.gs) or {}, comp = ns.RaidComp:CopyComp(l.cp) }
    end
    local first = lineups[1]
    return { id = t.id, name = t.n, members = CopyList(t.m) or {}, by = t.by, rev = t.rev, lineups = lineups,
             size = first.size, specs = CopyMap(first.specs), groups = CopyMap(first.groups),
             seats = CopyMap(first.seats), comp = ns.RaidComp:CopyComp(first.comp) }
end

-- A team's lineup (a GetTeam lineup) by id, or its first one when ln is nil.
function RaidPlan:FindLineup(team, ln)
    if type(team) == "string" then team = self:GetTeam(team) end
    local list = type(team) == "table" and team.lineups or {}
    if ln == nil then return list[1] end
    for _, l in ipairs(list) do
        if l.id == ln then return l end
    end
    return nil
end

-- "Kara A", or a lineup without a name: "25-man" ("25-man 2" for the team's second unnamed 25).
function RaidPlan:LineupName(team, l)
    if type(l) ~= "table" then return nil end
    if l.name then return l.name end
    local n = 0
    for _, o in ipairs(type(team) == "table" and team.lineups or {}) do
        if not o.name and o.size == l.size then n = n + 1 end
        if o.id == l.id then break end
    end
    return l.size .. "-man" .. (n > 1 and (" " .. n) or "")
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
-- A locked raid is left out for a member it doesn't take sign-ups from (CanSee); `all` = true keeps those too.
-- `allWeeks` = true lists weekly raids up to `to` as well (at most 180 days ahead; the Home tab's calendar).
function RaidPlan:GetRaids(from, to, all, allWeeks)
    local out = {}
    local root = Root(false)
    if not root then return out end
    local now = Now()
    from = tonumber(from) or (now - KEEP_PAST)
    to = tonumber(to) or (now + MAX_AHEAD)
    local ahead = allWeeks and min(to, now + MAX_AHEAD) or (now + AHEAD)
    for _, e in pairs(root.E) do
        if not e.sid and not e.del and Trusted(root, "E", e) and e.t >= from and e.t <= to then
            out[#out + 1] = ViewEvent(e)
        end
    end
    for _, s in pairs(root.S) do
        if not s.x and Trusted(root, "S", s) then
            local last = max(0, SeriesWeekAt(s, min(to, ahead)))
            if s.u then last = min(last, s.u) end
            for k = max(0, SeriesWeekAt(s, from) - 1), last + 1 do
                local v = ViewOccurrence(root, s, k)
                if v and v.t >= from and v.t <= to and (k <= last or v.t <= ahead) then
                    out[#out + 1] = v
                end
            end
        end
    end
    if not all then
        local seen = {}
        for _, v in ipairs(out) do
            if self:CanSee(v) then seen[#seen + 1] = v end
        end
        out = seen
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

-- The members a locked raid takes sign-ups from { [key] = true }; nil when it is open to everyone (not locked, or
-- locked without any team or invite).
local function LockSet(v)
    if not v or not v.lk then return nil end
    return RaidPlan:GetInvited(v)
end

-- The other characters of the player behind `key` (Guild:SameAccount), or an empty table.
local function Linked(key)
    local G = Guild()
    return G and G.GetLinkedCharacters and G:GetLinkedCharacters(key) or {}
end

-- Is `key`, or another character of its player, in the set / map? Returns the character found.
local function InSet(set, key)
    if type(set) ~= "table" or type(key) ~= "string" then return nil end
    if set[key] ~= nil then return key end
    if next(set) == nil then return nil end
    for _, m in ipairs(Linked(key)) do
        if set[m] ~= nil then return m end
    end
    return nil
end

---------------------------------------------------------------------------
-- Blacklist: players who take no part in the guild's raids. One list per guild, db.raidBlacklist[guildKey] =
-- { rev, by, l = { [key] = { r = reason, by = who, at = when } } }, shared whole like the raid leaders list: BLL on
-- GUILD (or WHISPER as an answer), accepted only from a roster manager, the newer rev wins. HELLO carries my rev
-- (blr); a manager answers an older one, and a member asks (BLQ) a manager who holds a newer one.
---------------------------------------------------------------------------

local function BlacklistRec(create)
    local db = ns.db
    local g = GuildKey()
    if not db or not g then return nil end
    if type(db.raidBlacklist) ~= "table" then
        if not create then return nil end
        db.raidBlacklist = {}
    end
    local rec = db.raidBlacklist[g]
    if type(rec) ~= "table" or type(rec.l) ~= "table" or not IsInt(rec.rev, 0, MAX_STAMP) then
        if not create then return nil end
        rec = { rev = 0, l = {} }
        db.raidBlacklist[g] = rec
    end
    return rec
end

-- An untrusted list { { k, r, b, a }, ... } -> { [key] = { r, by, at } }, or nil.
local function CleanBlacklist(l)
    if type(l) ~= "table" then return nil end
    local out = {}
    for i = 1, MAX_BLACKLIST + 1 do
        local e = l[i]
        if e == nil then break end
        if i > MAX_BLACKLIST or type(e) ~= "table" then return nil end
        local k = WireKey(e.k)
        if not k then return nil end
        local entry = {}
        if e.r ~= nil then
            entry.r = CleanText(e.r, MAX_REASON_LEN)
            if not entry.r then return nil end
        end
        if e.b ~= nil then
            entry.by = WireKey(e.b)
            if not entry.by then return nil end
        end
        if e.a ~= nil then
            if not IsInt(e.a, 1, MAX_STAMP) then return nil end
            entry.at = e.a
        end
        out[k] = entry
    end
    return out
end

local function WireBlacklist(rec)
    local keys = {}
    for k in pairs(rec.l) do keys[#keys + 1] = k end
    tsort(keys)
    local l = {}
    for i, k in ipairs(keys) do
        local e = rec.l[k]
        l[i] = { k = k, r = e.r, b = e.by, a = e.at }
    end
    return l
end

local function SendBlacklist(target)
    local rec = BlacklistRec(false)
    if not rec or rec.rev == 0 then return false end
    local msg = { t = "BLL", rev = rec.rev, by = rec.by, l = WireBlacklist(rec) }
    if target then return Send(msg, "WHISPER", target, "data") end
    return Send(msg, "GUILD", nil, "data")
end

local function OnBlacklist(sender, msg, dist)
    if (dist ~= "GUILD" and dist ~= "WHISPER") or not CanRoster(sender) then return end
    if not IsInt(msg.rev, 1, Now() + FUTURE_SLACK) then return end
    local l = CleanBlacklist(msg.l)
    if not l then return end
    local rec = BlacklistRec(true)
    if not rec then return end
    if msg.rev < rec.rev then return end
    if msg.rev == rec.rev and Util.Hash(l) <= Util.Hash(rec.l) then return end   -- the same rev: every client keeps one
    rec.rev, rec.l, rec.by = msg.rev, l, (msg.by ~= nil and WireKey(msg.by)) or sender
    ns:Fire("RAID_BLACKLIST_CHANGED")
    Changed()
end

local function OnBlacklistQuery(sender, msg, dist)
    if dist ~= "WHISPER" or not CanRoster(Util.PlayerKey()) then return end
    if not RateLimit("blq:" .. sender, BLL_REPLY_LIMIT) then return end
    SendBlacklist(sender)
end

function RaidPlan:GetBlacklistRev()
    local rec = BlacklistRec(false)
    return rec and rec.rev or 0
end

-- Sync calls this for every HELLO (blr = the sender's blacklist rev; nil from clients before 1.3).
function RaidPlan:OnBlacklistRevSeen(sender, blr)
    if type(blr) ~= "number" or type(sender) ~= "string" then return end
    local mine = self:GetBlacklistRev()
    if blr < mine and CanRoster(Util.PlayerKey()) then
        if RateLimit("bll-reply:" .. sender, BLL_REPLY_LIMIT) then
            Util.RandomDelay(0.5, 3, function() SendBlacklist(sender) end)
        end
    elseif blr > mine and CanRoster(sender) then
        if RateLimit("blq-ask:" .. sender, BLL_REPLY_LIMIT) then
            Send({ t = "BLQ" }, "WHISPER", sender, "ctrl")
        end
    end
end

-- May I keep the guest book and the blacklist? With a raid (a view or an id): may I (or that player) add its guests
-- and decline or remove its answers: those who run it (CanManageRaid) and the officers.
function RaidPlan:CanManageRoster(occId, key)
    key = key or Util.PlayerKey()
    if occId == nil then return CanRoster(key) end
    local v = AsView(occId)
    return v ~= nil and (CanManage(v, key) or IsOfficer(key))
end

-- May that player (a roster manager: the GM, officers, the raid leaders) do so? (Guest book.)
function RaidPlan:IsRosterManager(key)
    return CanRoster(key)
end

-- The blacklist entry that blocks `key`: its own, or that of another character of the same player.
-- { key = the listed character, reason, by, at } or nil.
function RaidPlan:GetBlacklistEntry(key)
    local rec = BlacklistRec(false)
    if not rec or next(rec.l) == nil then return nil end
    local hit = InSet(rec.l, key)
    local e = hit and rec.l[hit]
    if type(e) ~= "table" then return nil end
    return { key = hit, reason = e.r, by = e.by, at = e.at }
end

function RaidPlan:IsBlacklisted(key)
    return self:GetBlacklistEntry(key) ~= nil
end

-- The whole list, sorted by name: { { key, reason, by, at }, ... }.
function RaidPlan:GetBlacklist()
    local out = {}
    local rec = BlacklistRec(false)
    for key, e in pairs(rec and rec.l or {}) do
        if type(e) == "table" then out[#out + 1] = { key = key, reason = e.r, by = e.by, at = e.at } end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

local function SaveBlacklist(rec)
    rec.rev = max(Now(), rec.rev + 1)
    rec.by = Util.PlayerKey()
    SendBlacklist()
    ns:Fire("RAID_BLACKLIST_CHANGED")
    Changed()
end

-- Puts a player (a guild member or anyone else, by name) on the blacklist, or changes the reason. Returns ok, err.
function RaidPlan:SetBlacklisted(name, reason)
    if not CanRoster(Util.PlayerKey()) then return false, REFUSED.roster end
    local rec = BlacklistRec(true)
    if not rec then return false, "Your guild is not known yet; try again in a moment." end
    local key = WireKey(type(name) == "string" and Util.Trim(name) or name)
    if not key then return false, "That is not a player name." end
    if Util.IsMe(key) then return false, "You can't blacklist yourself." end
    local r
    if reason ~= nil and Util.Trim(tostring(reason)) ~= "" then
        r = CleanText(tostring(reason), MAX_REASON_LEN)
        if not r then return false, "Reasons are at most " .. MAX_REASON_LEN .. " characters on one line." end
    end
    if not rec.l[key] and CountTable(rec.l) >= MAX_BLACKLIST then
        return false, "The blacklist holds at most " .. MAX_BLACKLIST .. " players."
    end
    local cur = rec.l[key]
    rec.l[key] = { r = r, by = Util.PlayerKey(), at = cur and cur.at or Now() }
    SaveBlacklist(rec)
    return true, key
end

function RaidPlan:RemoveBlacklisted(key)
    if not CanRoster(Util.PlayerKey()) then return false, REFUSED.roster end
    local rec = BlacklistRec(true)
    if not rec or type(key) ~= "string" or not rec.l[key] then return false, "That player is not on the blacklist." end
    rec.l[key] = nil
    SaveBlacklist(rec)
    return true
end

-- A character's level: my own exactly, a guild member's per the guild roster; nil when not known.
local function LevelOf(key)
    if Util.IsMe(key) then return tonumber((UnitLevel("player"))) end
    local G = Guild()
    local m = G and G.GetMember and G:GetMember(key)
    return m and tonumber(m.level) or nil
end

-- Is the character at the raid's minimum level (ml)? An unknown level passes.
local function LevelOk(v, key)
    local ml = v and v.ml
    if not ml then return true end
    local level = LevelOf(key)
    return level == nil or level >= ml
end

-- Was this answer taken off by the organizers (rm holds the rev of the answer that was removed)?
local function Removed(v, key, s)
    local rev = v and v.rm and v.rm[key]
    return rev ~= nil and (s.rev or 0) <= rev
end

-- Is the member outside a locked raid's teams and invites? (Another character of an invited player is in.)
local function LockedOut(v, key)
    local only = LockSet(v)
    return only ~= nil and InSet(only, key) == nil
end

-- Is the raid (a view or an id) listed for me? Every raid, a locked one too (the others ask to join it: user rule
-- 2026-10-04), except a private one (pv): only for the members of its teams, its extra invites, those who plan raids
-- or lay out groups (the GM, the guild council, the raid leaders), its own leader, and the officers. The data itself
-- still reaches every guild member: this is what the lists show, not a secret.
function RaidPlan:CanSee(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return false end
    local me = Util.PlayerKey()
    return not (v.pv and LockedOut(v, me)) or CanGroups(me) or CanManage(v, me) or IsOfficer(me)
end

-- May that member (default: me) ask to join the locked raid (a view or an id)? Those outside it, when it isn't private
-- (not who runs it: they invite themselves).
function RaidPlan:CanRequest(occId, key)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return v ~= nil and not v.pv and self:GetSignupBlock(v, key) == "lock"
        and not CanManage(v, key or Util.PlayerKey())   -- (who runs it invites themselves)
end

-- A request to join a locked raid is the sign-up of a member outside it (not counted until they are invited).
-- The open requests (not withdrawn, declined, removed or blacklisted), oldest first: { { key, c, sp, n, at }, ... }.
-- A player's characters count once: the newest request among them.
function RaidPlan:GetRequests(occId)
    local out = {}
    local root = Root(false)
    local v = root and type(occId) == "string" and ResolveOcc(root, occId)
    local u = v and root.U[occId]
    if not (v and type(u) == "table" and LockSet(v) and not v.cancelled) then return out end
    local raw = {}
    for key, s in pairs(u) do
        if s.st ~= "X" and LockedOut(v, key) and LevelOk(v, key) and not Removed(v, key, s) and not InSet(v.rj, key)
            and not self:IsBlacklisted(key) then
            raw[key] = s
        end
    end
    for key, s in pairs(raw) do
        local newest = true
        for _, m in ipairs(Linked(key)) do
            local o = raw[m]
            if o and (o.rev > s.rev or (o.rev == s.rev and m > key)) then newest = false break end
        end
        if newest then out[#out + 1] = { key = key, st = s.st, c = s.c, sp = s.sp, n = s.n, at = s.at or s.rev } end
    end
    tsort(out, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.key < b.key
    end)
    return out
end

-- My open request for the raid (any of my characters): { key, c, sp, n, at } or nil.
function RaidPlan:GetMyRequest(occId)
    local me = Util.PlayerKey()
    for _, r in ipairs(self:GetRequests(occId)) do
        if r.key == me or InSet({ [r.key] = true }, me) then return r end
    end
    return nil
end

-- Open requests on the upcoming raids I run (CanManageRaid): total, { [occId] = n }.
function RaidPlan:GetPendingRequests()
    local total, per = 0, {}
    local now = Now()
    for _, v in ipairs(self:GetRaids(now - 3 * 3600, nil, true)) do
        if v.lk and not v.cancelled and self:CanManageRaid(v) then
            local n = #self:GetRequests(v.id)
            if n > 0 then
                per[v.id] = n
                total = total + n
            end
        end
    end
    return total, per
end

-- { [key] = { st, sp, c, n, rev } } (copies). A locked raid counts only its teams' members and its extra invites; a
-- raid with a minimum level only the characters at that level. Blacklisted players, declined members and answers
-- the organizers removed are left out. A player's characters count once: the newest answer among them. Guests are
-- included as accepted ({ st = "A", guest = true, c, sp, at }).
local signupMemo, memoAt, memoVer = {}, nil, nil

function RaidPlan:GetSignups(occId)
    local now = GetTime()
    if memoAt ~= now or memoVer ~= dataVer then
        wipe(signupMemo)
        memoAt, memoVer = now, dataVer
    end
    local kept = type(occId) == "string" and signupMemo[occId]
    if not kept then
        kept = self:ReadSignups(occId)
        if type(occId) == "string" then signupMemo[occId] = kept end
    end
    local out = {}
    for key, s in pairs(kept) do out[key] = CopyMap(s) end
    return out
end

-- GetSignups without the memo.
function RaidPlan:ReadSignups(occId)
    local out = {}
    local root = Root(false)
    if not root or type(occId) ~= "string" then return out end
    local v = ResolveOcc(root, occId)
    local u = root.U[occId]
    local raw = {}
    if type(u) == "table" then
        -- (the lock set and the blacklist once, not per answer)
        local only = LockSet(v)
        local bl = BlacklistRec(false)
        local listed = bl and next(bl.l) ~= nil
        for key, s in pairs(u) do
            if not (only ~= nil and InSet(only, key) == nil) and LevelOk(v, key) and not Removed(v, key, s)
                and not InSet(v and v.rj, key) and not (listed and self:IsBlacklisted(key)) then
                raw[key] = s
            end
        end
    end
    for key, s in pairs(raw) do
        local newest = true
        for _, m in ipairs(Linked(key)) do
            local o = raw[m]
            if o and (o.rev > s.rev or (o.rev == s.rev and m > key)) then newest = false break end
        end
        if newest then out[key] = CopyMap(s) end
    end
    for key, g in pairs(v and v.gu or {}) do
        if not out[key] and not self:IsBlacklisted(key) then
            out[key] = { st = "A", c = g.c, sp = g.sp, guest = true, at = g.at or v.rev, rev = g.at or v.rev }
        end
    end
    return out
end

-- My player's answer for the raid: this character's, or the one given with (or for) another of my characters.
-- Returns the sign-up (a copy), or nil.
function RaidPlan:GetMySignup(occId)
    local key = self:GetMySignupCharacter(occId)
    return key and self:GetSignups(occId)[key] or nil
end

-- The character my player's answer for the raid is for (nil when I have not answered).
function RaidPlan:GetMySignupCharacter(occId)
    local me = Util.PlayerKey()
    if not me or type(occId) ~= "string" then return nil end
    local signups = self:GetSignups(occId)
    local key = InSet(signups, me)
    if not key or signups[key].guest then return nil end
    return key
end

-- Has the player behind `key` answered (with any of their characters)? `signups` = GetSignups(occId).
function RaidPlan:HasAnswered(signups, key)
    return InSet(signups, key) ~= nil
end

-- The members the organizers declined for the raid (a view or an id): { [key] = { c, sp, st } } (st = the answer
-- they had given, nil when none).
function RaidPlan:GetDeclined(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    local out = {}
    if not v or not v.rj then return out end
    local root = Root(false)
    local u = root and root.U[v.id] or {}
    for key in pairs(v.rj) do
        local s = u[key]
        local sp, c = s and s.sp, s and s.c
        if not sp then
            local sp2, c2 = self:GetMemberSpec(key)
            sp, c = sp2, c or c2
        end
        out[key] = { c = c, sp = sp, st = s and s.st or nil }
    end
    return out
end

-- The raid's guests (a view or an id): { [key] = { c, sp, at } }.
function RaidPlan:GetGuests(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return v and CopyGuests(v.gu) or {}
end

-- Is that player a guest of the raid?
function RaidPlan:IsGuest(occId, key)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return (v and v.gu and v.gu[key]) and true or false
end

-- Is the raid (a view or an id) locked to its teams and extra invites?
function RaidPlan:IsLocked(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return LockSet(v) ~= nil
end

-- Why that member (default: me) can't sign up for the raid (a view or an id): "blacklist" (the player is on the
-- guild's blacklist), "declined" (the organizers turned them down for this raid), "lock" (locked to its teams and
-- extra invites, and the member is not one of them), "level" (below the raid's minimum level), or nil when they can.
function RaidPlan:GetSignupBlock(occId, key)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return nil end
    key = key or Util.PlayerKey()
    if key ~= nil and self:IsBlacklisted(key) then return "blacklist" end
    if key ~= nil and InSet(v.rj, key) then return "declined" end
    if LockSet(v) ~= nil and (key == nil or LockedOut(v, key)) then return "lock" end
    if key ~= nil and not LevelOk(v, key) then return "level" end
    return nil
end

-- May that member (default: me) sign up for the raid? Everyone for an open raid; for a locked one the members of
-- its teams and its extra invites. A raid with a minimum level takes only the characters at that level.
function RaidPlan:CanSignUp(occId, key)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return false end
    return self:GetSignupBlock(v, key) == nil
end

-- The minimum character level of the raid (a view or an id), or nil when every level signs up.
function RaidPlan:GetMinLevel(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return v and v.ml or nil
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

-- The players a raid (a view or an id) invites through one of its teams (1.3.2, user decision 2026-10-06): the roster
-- members in the groups of the team's lineup for the raid (GetRaidLineup); the whole roster when the team has no
-- lineup of the raid's size, or that lineup has nobody in its groups yet. Unassigned players and the waitlist are not
-- invited through a lineup. Returns { key, ... } (sorted) and the lineup (nil: the roster), or nil (unknown team).
function RaidPlan:GetRaidTeamPlayers(occId, teamId)
    local v = AsView(occId)
    local t = v and self:GetTeam(teamId)
    if not t then return nil end
    local l = self:GetRaidLineup(v, teamId)
    if not l then return t.members, nil end
    local n = ns.RaidComp:GroupCount(v.sz)
    local out = {}
    for _, key in ipairs(t.members) do
        local g = l.groups[key]
        if type(g) == "number" and g >= 1 and g <= n then out[#out + 1] = key end
    end
    if #out == 0 then return t.members, nil end
    return out, l
end

-- The set of invited members { [key] = true } (the players of the raid's visible teams, GetRaidTeamPlayers, plus its
-- extra invites), or nil when the raid names no team and no invite (open to everyone).
function RaidPlan:GetInvited(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return nil end
    local tm, inv = v.tm or {}, v.inv or {}
    if #tm == 0 and #inv == 0 then return nil end
    local set = {}
    for _, id in ipairs(tm) do
        for _, key in ipairs(self:GetRaidTeamPlayers(v, id) or {}) do set[key] = true end
    end
    for _, key in ipairs(inv) do set[key] = true end
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
            if not sp and not s.guest then sp, c = self:GetMemberSpec(key) end
            out[#out + 1] = { key = key, c = c or s.c, sp = sp, st = s.st, guest = s.guest }
            seen[key] = true
        end
    end
    for key in pairs(v.grp or {}) do
        if not seen[key] and not (signups[key] and signups[key].st == "X") and not InSet(v.rj, key)
            and not self:IsBlacklisted(key) then
            local sp, c = self:GetMemberSpec(key)
            out[#out + 1] = { key = key, c = c, sp = sp }
        end
    end
    tsort(out, function(a, b) return a.key < b.key end)
    return out
end

-- §60: the starting layout of a raid that has no saved one: its teams' layouts (1.3.2: the lineup of each team for the
-- raid, GetRaidLineup), adjusted to who accepted.
--  1. accepted team members keep their seat (first team first);
--  2. a seat whose team member didn't accept is open for an accepted player of the same role;
--  3. other accepted players join a group of their role with room; Tentative / Bench and whoever doesn't fit stay out.
-- Without any team layout the whole raid is Auto-filled (accepted players only). Returns { [key] = group } and the
-- seats { [key] = 1..5 } carried over from the teams (nil when Auto-filled).
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
    -- (each team's lineup for this raid, GetRaidLineup: its groups, seats and specs)
    local teams = {}
    for _, id in ipairs(v.tm or {}) do
        local l = self:GetRaidLineup(v, id)
        if l and next(l.groups) then teams[#teams + 1] = l end
    end
    if #teams == 0 then return Comp:AutoFill(accepted, v.sz) end

    local grp, seats, count, byKey = {}, {}, {}, {}
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
                        grp[key], seats[key] = g, t.seats[key]
                        count[g] = count[g] + 1
                    end
                else
                    local sp, c = self:GetMemberSpec(key, t)
                    open[#open + 1] = { g = g, s = t.seats[key], role = Comp:RoleOf(c, sp) }
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
                grp[m.key], seats[m.key] = seat.g, seat.s
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
    return grp, seats
end

-- The layout to use for a raid: the saved one (the organizers' edits), else the starting layout. Second return:
-- true when saved; third: the seats { [key] = 1..5 } (may be empty).
function RaidPlan:GetLayout(occId)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    if not v then return {}, false end
    if v.grp and next(v.grp) then return CopyMap(v.grp), true, CopyMap(v.gs) or {} end
    local grp, seats = self:BuildLayout(v)
    return grp, false, seats or {}
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
            if inv and InSet(inv, me) and not self:GetMySignup(v.id) and self:CanSignUp(v, me) then out[#out + 1] = v end
        end
    end
    return out
end

-- The class of one of my player's characters: mine from the game, another one's from the guild roster.
local function ClassOf(key)
    if Util.IsMe(key) then return MyClass() end
    local G = Guild()
    return G and G.GetClass and G:GetClass(key) or nil
end

-- The spec index this character (default: the one logged in) used last (nil = none yet).
function RaidPlan:GetLastSpec(key)
    local db = ns.db
    key = key or Util.PlayerKey()
    local t = db and key and type(db.raidplanSpec) == "table" and db.raidplanSpec[key]
    return IsInt(t, 1, SpecCount(ClassOf(key))) and t or nil
end

-- The characters I can answer raids with: this one first, then the others of my account in this guild (sorted).
function RaidPlan:GetMyCharacters()
    local me = Util.PlayerKey()
    local out = { me }
    for _, key in ipairs(me and Linked(me) or {}) do out[#out + 1] = key end
    return out
end

---------------------------------------------------------------------------
-- Target comp (1.3.1): a team's wanted specs (cp on the team record, written with the team by the GM and the guild
-- council), who fills them, who could, and the open slots of the raids that invite the team. The comp itself and the
-- pure functions are in Core/RaidComp.lua, with the API contract for the UI. Only methods here (this file's main
-- chunk is close to Lua's 200 locals): everything is computed on each client from the same data, sorted by fixed
-- keys; nothing is left to chance.
---------------------------------------------------------------------------

-- A team's lineup for the comp functions (1.3.2: a comp, groups and specs belong to a lineup): an id (the saved team's
-- first lineup), { id = team id, ln = lineup id } (a saved team's lineup), a GetTeam table (its lineup ln, else its
-- first), or the Teams page's draft of one lineup ({ id, ln, members = set or array, s | specs, grp | groups, sz |
-- size, cp | comp }). Returns { id, ln, lineupName, name, members = sorted keys (the roster), specs, groups, size,
-- comp } or nil (an unknown team or lineup).
function RaidPlan:ResolveTeam(team)
    if type(team) == "table" and team.members == nil and type(team.id) == "string" then
        local ln = team.ln
        team = self:GetTeam(team.id)
        if team then team.ln = ln end
    end
    if type(team) == "string" then team = self:GetTeam(team) end
    if type(team) ~= "table" then return nil end
    if type(team.lineups) == "table" then
        local l = self:FindLineup(team, team.ln)
        if not l then return nil end
        team = { id = team.id, ln = l.id, lineupName = self:LineupName(team, l), name = team.name,
                 members = team.members, specs = l.specs, groups = l.groups, size = l.size, comp = l.comp }
    end
    local members, seen = {}, {}
    for k, v in pairs(type(team.members) == "table" and team.members or {}) do
        local key = (type(k) == "string" and v and k) or (type(v) == "string" and v) or nil
        if key and not seen[key] then
            seen[key] = true
            members[#members + 1] = key
        end
    end
    tsort(members)
    local size = team.size or team.sz
    local comp = team.comp
    if comp == nil then comp = team.cp end
    return {
        id = team.id, ln = type(team.ln) == "string" and team.ln or nil, lineupName = team.lineupName,
        name = team.name or team.n, members = members,
        specs = (type(team.specs) == "table" and team.specs) or (type(team.s) == "table" and team.s) or {},
        groups = (type(team.groups) == "table" and team.groups) or (type(team.grp) == "table" and team.grp) or {},
        size = SIZES[size] and size or 25,
        comp = ns.RaidComp:CleanComp(comp) or nil,
    }
end

-- The roster with the spec each plays in the lineup (the lineup's pick, else the latest sign-up's, else the BiS
-- list's: GetMemberSpec), sorted by key: { key, c, sp, source, seated = placed in one of the lineup's groups }. A
-- member in no group is unassigned: on the roster, but not counted for the lineup's comp, slots or raid buffs.
function RaidPlan:GetTeamMembers(team)
    local t = self:ResolveTeam(team)
    local out = {}
    local nGroups = t and ns.RaidComp:GroupCount(t.size) or 0
    for _, key in ipairs(t and t.members or {}) do
        local sp, c, source = self:GetMemberSpec(key, t)
        local g = t.groups[key]
        out[#out + 1] = { key = key, c = c, sp = sp, source = source,
                          seated = (type(g) == "number" and g >= 1 and g <= nGroups) or nil }
    end
    return out
end

-- The roster members in one of the lineup's groups (GetTeamMembers' seated ones), and the unassigned ones (in none).
function RaidPlan:GetTeamPlaced(team)
    local placed, unassigned = {}, {}
    for _, m in ipairs(self:GetTeamMembers(team)) do
        if m.seated then placed[#placed + 1] = m else unassigned[#unassigned + 1] = m end
    end
    return placed, unassigned
end

-- A lineup's saved comp (a copy; ln nil: the first lineup's), or nil.
function RaidPlan:GetTeamComp(id, ln)
    local l = self:FindLineup(id, ln)
    return l and l.comp or nil
end

-- Saves only a lineup's comp (cp; false or nil clears it; ln nil: the first lineup). The GM and the guild council.
-- Returns ok, idOrErr.
function RaidPlan:SetTeamComp(id, cp, ln)
    if not CanTeams(Util.PlayerKey()) then return false, REFUSED.teams end
    local root = Root(false)
    local t = root and type(id) == "string" and root.T[id]
    if not t or t.del or not Trusted(root, "T", t) then return false, "unknown team" end
    if ln ~= nil and not self:FindLineup(id, ln) then return false, "unknown lineup" end
    return self:SaveTeam(id, t.n, t.m, { comp = cp or false, ln = ln })
end

-- "The team as it is": a slot for the spec of each member in a group (benched members and members without a known
-- spec left out, at most the team's size). Returns cp, slots, or nil.
function RaidPlan:CompFromTeam(team)
    local t = self:ResolveTeam(team)
    if not t then return nil end
    return ns.RaidComp:CompFromMembers((self:GetTeamPlaced(t)), t.size)
end

-- The "Start from" choices of a lineup (any ResolveTeam form): the preset of its size, the team as it is (its groups,
-- when a spec there is known), and the comps of the other lineups of the same size, this team's first, then the
-- other teams' (by name). { { key, kind, name, size, cp, teamId, ln }, ... }; every cp is a copy.
function RaidPlan:GetCompStarts(team)
    local out = {}
    local t = self:ResolveTeam(team)
    if not t then return out end
    for _, p in ipairs(ns.RaidComp:GetPresets(t.size)) do
        out[#out + 1] = { key = p.key, kind = "preset", name = p.name, size = p.size, cp = p.cp }
    end
    local own = self:CompFromTeam(t)
    if own then out[#out + 1] = { key = "team", kind = "team", name = "The team as it is", size = t.size, cp = own } end
    local teams = self:GetTeams()
    for pass = 1, 2 do
        for _, o in ipairs(teams) do
            if (o.id == t.id) == (pass == 1) then
                for _, l in ipairs(o.lineups) do
                    if l.comp and l.size == t.size and not (o.id == t.id and l.id == t.ln) then
                        local name = self:LineupName(o, l)
                        if o.id ~= t.id then name = #o.lineups > 1 and (o.name .. " · " .. name) or o.name end
                        out[#out + 1] = { key = "copy:" .. o.id .. ":" .. l.id, kind = "copy", name = name,
                                          size = l.size, cp = l.comp, teamId = o.id, ln = l.id }
                    end
                end
            end
        end
    end
    return out
end

-- Who fills which slot of the lineup's comp, the bench and the open slots (RaidComp:MatchComp), or nil without a comp.
-- Only the roster members in one of its groups fill slots (bench = those in a group no slot takes). Never counted:
-- unassigned = the roster members in none of its groups (by column, then key, unknown spec last, like bench), and
-- waitlist = its waitlist (GetWaitlist, first in line first).
function RaidPlan:MatchTeam(team)
    local t = self:ResolveTeam(team)
    if not (t and t.comp) then return nil end
    local placed, unassigned = self:GetTeamPlaced(t)
    local m = ns.RaidComp:MatchComp(t.comp, placed)
    m.unassigned = ns.RaidComp:MatchComp({}, unassigned).bench
    m.waitlist = self:GetWaitlist(t)
    return m
end

-- The open slots of the team's comp: { { c, sp, role, name, n }, ... } in comp order, and how many ({}, 0 without one).
function RaidPlan:GetTeamOpenSlots(team)
    local m = self:MatchTeam(team)
    if not m then return {}, 0 end
    return m.open, m.openCount
end

-- The guild's level-70 members by the spec they play (their latest sign-up, else their BiS list: GetMemberSpec):
-- { bySpec = { ["CLASS:sp"] = { key, ... } (sorted) }, byKey = { [key] = { c, sp, src } } }. Built once and kept
-- until the plans, the roster or a BiS list change (OnInit) or 30 seconds pass: a hover reads it, it doesn't scan
-- the guild.
function RaidPlan:GetSpecIndex()
    local idx = self.specIndexCache
    if idx and GetTime() - idx.at < 30 then return idx end
    idx = { at = GetTime(), bySpec = {}, byKey = {} }
    local G = Guild()
    for _, key in ipairs(G and G.GetMembers and G:GetMembers() or {}) do
        if (LevelOf(key) or 0) >= MAX_LEVEL then
            local sp, c, src = self:GetMemberSpec(key)
            if type(c) == "string" and IsInt(sp, 1, SpecCount(c)) then
                idx.byKey[key] = { c = c, sp = sp, src = src }
                local k = c .. ":" .. sp
                local list = idx.bySpec[k] or {}
                list[#list + 1] = key
                idx.bySpec[k] = list
            end
        end
    end
    self.specIndexCache = idx
    return idx
end

-- Who could fill an open slot (class c, spec sp) of a lineup's comp, in six groups (the agreed order):
--   unassigned  the roster members in none of the lineup's groups: that spec, then the class in another spec
--               (other = true)
--   waitlist    the lineup's waitlist: the same rule; n = their place in line
--   extra       the roster members in a group no slot takes, of that class (another spec: they could switch)
--   alts        the roster members' other characters (each vouches for the other) at level 70, not on the roster:
--               the same rule as unassigned; of = the member
--   guild       the rest of the guild at level 70, on no roster, no waitlist of this lineup and no alt of the roster,
--               playing that spec (latest sign-up, else BiS list); not blacklisted
--   teams       members of the other teams who play that spec in one of their lineups (team = its name, teamId)
-- A player shows once (the first group). Each list: that spec first, then online first (the waitlist: its order),
-- then by key.
function RaidPlan:CanFill(team, c, sp)
    local out = { unassigned = {}, waitlist = {}, extra = {}, alts = {}, guild = {}, teams = {} }
    local t = self:ResolveTeam(team)
    if not t or not IsInt(sp, 1, SpecCount(c)) then return out end
    local G = Guild()
    local taken = {}
    local function add(list, key, kc, ksp, extra)
        taken[key] = true
        local e = { key = key, c = kc, sp = ksp, other = ksp ~= sp,
                    online = (G and G.IsOnline and G:IsOnline(key)) and true or false }
        for k, v in pairs(extra or {}) do e[k] = v end
        list[#list + 1] = e
    end
    for _, key in ipairs(t.members) do taken[key] = true end
    -- 1. unassigned, 2. the waitlist, 3. in a group beyond the comp
    local m = t.comp and self:MatchTeam(t)
    local _, unassigned = self:GetTeamPlaced(t)
    for _, b in ipairs(unassigned) do
        if b.c == c then add(out.unassigned, b.key, b.c, b.sp) end
    end
    for _, b in ipairs(self:GetWaitlist(t)) do
        taken[b.key] = true
        if b.c == c then add(out.waitlist, b.key, b.c, b.sp, { n = b.n }) end
    end
    for _, b in ipairs(m and m.bench or {}) do
        if b.c == c then add(out.extra, b.key, b.c, b.sp) end
    end
    -- 4. alts of the roster
    local altOf = {}
    for _, key in ipairs(t.members) do
        for _, alt in ipairs(Linked(key)) do
            if not taken[alt] and not altOf[alt] then
                altOf[alt] = key
                local asp, ac = self:GetMemberSpec(alt)
                if ac == c and (LevelOf(alt) or 0) >= MAX_LEVEL then add(out.alts, alt, ac, asp, { of = key }) end
            end
        end
    end
    -- 5. the rest of the guild
    local teams = self:GetTeams()
    local onTeam = {}
    for _, o in ipairs(teams) do
        if o.id ~= t.id then
            for _, key in ipairs(o.members) do onTeam[key] = true end
        end
    end
    for _, key in ipairs(self:GetSpecIndex().bySpec[c .. ":" .. sp] or {}) do
        if not taken[key] and not altOf[key] and not onTeam[key] and not self:IsBlacklisted(key) then
            add(out.guild, key, c, sp)
        end
    end
    -- 6. the other teams (the spec they play in any of their lineups)
    for _, o in ipairs(teams) do
        if o.id ~= t.id then
            for _, key in ipairs(o.members) do
                if not taken[key] then
                    for _, l in ipairs(o.lineups) do
                        local osp, oc = self:GetMemberSpec(key, l)
                        if oc == c and osp == sp then
                            add(out.teams, key, c, sp, { team = o.name, teamId = o.id })
                            break
                        end
                    end
                end
            end
        end
    end
    local function order(a, b)
        if a.other ~= b.other then return not a.other end
        if a.n and b.n then return a.n < b.n end
        if a.online ~= b.online then return a.online end
        return a.key < b.key
    end
    for _, list in pairs(out) do tsort(list, order) end
    return out
end

-- The lineup a raid (a view or an id) uses of one of its teams: the one it names (tl) when that is of the raid's size,
-- else the team's first of that size. Returns the lineup (a GetTeam lineup) and the team, or nil.
function RaidPlan:GetRaidLineup(occId, teamId)
    local v = AsView(occId)
    local t = v and self:GetTeam(teamId)
    if not t then return nil end
    local want = v.tl and v.tl[teamId]
    local first
    for _, l in ipairs(t.lineups) do
        if l.size == v.sz then
            if l.id == want then return l, t end
            first = first or l
        end
    end
    if not first then return nil end
    return first, t
end

-- The lineup whose comp a raid (a view or an id) uses for its open slots: of its teams (in its order), the first
-- whose lineup for the raid (GetRaidLineup) has a comp. ResolveTeam's shape (id = the team's, ln, name, members =
-- the roster, comp), or nil.
function RaidPlan:GetRaidCompTeam(occId)
    local v = AsView(occId)
    if not v then return nil end
    for _, id in ipairs(v.tm or {}) do
        local l = self:GetRaidLineup(v, id)
        if l and l.comp then return self:ResolveTeam({ id = id, ln = l.id }) end
    end
    return nil
end

-- The open slots of a planned raid (a view or an id) that invites a team with a comp: what the comp asks minus the
-- Accepted and Tentative answers of each spec (the answer's spec, else the one the team gives the member; guests by
-- their class and spec; Accepted fill first). A team member who hasn't answered leaves their slot open. nil when no
-- team of the raid has a comp of its size, or the raid is cancelled. See RaidComp.lua for the shape.
function RaidPlan:GetRaidOpenSlots(occId)
    local v = AsView(occId)
    if not v or v.cancelled then return nil end
    local t = self:GetRaidCompTeam(v)
    if not t then return nil end
    local members = {}
    for key, s in pairs(self:GetSignups(v.id)) do
        if s.st == "A" or s.st == "T" then
            local sp, c = s.sp, s.c
            if not sp and not s.guest then
                local sp2, c2 = self:GetMemberSpec(key, t)
                sp, c = sp2, c or c2
            end
            members[#members + 1] = { key = key, c = c, sp = sp, st = s.st, guest = s.guest, seated = s.st == "A" }
        end
    end
    tsort(members, function(a, b) return a.key < b.key end)
    local m = ns.RaidComp:MatchComp(t.comp, members)
    local slots = {}
    for _, o in ipairs(m.open) do
        for _ = 1, o.n do slots[#slots + 1] = { c = o.c, sp = o.sp, role = o.role, name = o.name } end
    end
    return { teamId = t.id, teamName = t.name, ln = t.ln, lineupName = t.lineupName, size = v.sz, wanted = m.total,
             filled = m.filled, openCount = m.openCount, open = m.open, slots = slots, match = m }
end

-- Who could fill an open slot of a raid (its tooltip): { unanswered = the players the comp team invites to it
-- (GetRaidTeamPlayers: its lineup's) of that spec who haven't answered, guild = level-70 guild members of that spec
-- (spec index) outside them who haven't answered or answered Bench (st = "B") }. Blacklisted and declined players are
-- left out. Each: online first, then by key.
function RaidPlan:RaidCanFill(occId, c, sp)
    local out = { unanswered = {}, guild = {} }
    local v = AsView(occId)
    local t = v and self:GetRaidCompTeam(v)
    if not t or not IsInt(sp, 1, SpecCount(c)) then return out end
    local G = Guild()
    local signups = self:GetSignups(v.id)
    local function online(key) return (G and G.IsOnline and G:IsOnline(key)) and true or false end
    local function blocked(key)
        local b = self:GetSignupBlock(v, key)
        return b == "blacklist" or b == "declined"
    end
    local mine = {}
    for _, key in ipairs(self:GetRaidTeamPlayers(v, t.id) or {}) do
        mine[key] = true
        if not InSet(signups, key) and not blocked(key) then
            local msp, mc = self:GetMemberSpec(key, t)
            if mc == c and msp == sp then
                out.unanswered[#out.unanswered + 1] = { key = key, c = c, sp = sp, online = online(key) }
            end
        end
    end
    for _, key in ipairs(self:GetSpecIndex().bySpec[c .. ":" .. sp] or {}) do
        if not mine[key] then
            local hit = InSet(signups, key)
            local st = hit and signups[hit].st or nil
            if (st == nil or st == "B") and not blocked(key) and LevelOk(v, key) then
                out.guild[#out.guild + 1] = { key = key, c = c, sp = sp, online = online(key), st = st }
            end
        end
    end
    local function order(a, b)
        if a.online ~= b.online then return a.online end
        return a.key < b.key
    end
    tsort(out.unanswered, order)
    tsort(out.guild, order)
    return out
end

-- The raid-buff strip of a lineup (RaidComp:BuffStates): lit = whose slot is filled, planned = the open slots.
-- Without a comp: the roster members in its groups, nothing planned (unassigned and waitlisted players bring
-- nothing).
function RaidPlan:GetTeamBuffStates(team)
    local Comp = ns.RaidComp
    local m = self:MatchTeam(team)
    if not m then return Comp:BuffStates((self:GetTeamPlaced(team)), {}) end
    local have = {}
    for _, s in ipairs(m.slots) do
        if s.member then have[#have + 1] = s.member end
    end
    return Comp:BuffStates(have, m.open)
end

-- The raid-buff strip of a raid: lit = `have` (the Groups tab: who is in the groups; default: the Accepted and
-- Tentative answers, as they fill the comp), planned = the raid's open slots (GetRaidOpenSlots).
function RaidPlan:GetRaidBuffStates(occId, have)
    local Comp = ns.RaidComp
    local v = AsView(occId)
    if not v then return Comp:BuffStates({}, {}) end
    if type(have) ~= "table" then
        have = {}
        for _, m in ipairs(self:GetLayoutMembers(v)) do
            if m.st == "A" or m.st == "T" then have[#have + 1] = m end
        end
    end
    local open = self:GetRaidOpenSlots(v)
    return Comp:BuffStates(have, open and open.open or {})
end

-- The team's next raid: the first raid that invites it, not cancelled, that starts later or started at most 6 hours
-- ago (as the Teams page lists them); with ln, the first that uses that lineup (GetRaidLineup). A view, or nil.
function RaidPlan:GetTeamNextRaid(teamId, ln)
    if type(teamId) ~= "string" then return nil end
    for _, v in ipairs(self:GetRaids(Now() - 6 * 3600)) do
        if not v.cancelled then
            for _, id in ipairs(v.tm or {}) do
                if id == teamId then
                    local l = ln and self:GetRaidLineup(v, id)
                    if not ln or (l and l.id == ln) then return v end
                end
            end
        end
    end
    return nil
end

-- The LF line for a lineup's open slots (any ResolveTeam form): "<Guild> LF Holy Paladin, Survival Hunter · SSC Sun
-- 20:00 · /w me" (the next raid of that lineup: short name, day and time), at most 255 bytes; nil without open
-- slots.
function RaidPlan:GetLFMessage(team)
    local t = self:ResolveTeam(team)
    if not t then return nil end
    local open = self:GetTeamOpenSlots(t)
    if #open == 0 then return nil end
    local v = t.id and self:GetTeamNextRaid(t.id, t.ln)
    local when = v and (ns.RaidComp:ShortRaidName(v) .. " " .. date("%a %H:%M", v.t)) or nil
    local G = Guild()
    return ns.RaidComp:LFLine(G and G.GetGuildName and G:GetGuildName() or nil, open, when)
end

---------------------------------------------------------------------------
-- Public API: writing (organizers)
---------------------------------------------------------------------------

local function RequireOrganizer(what)
    what = what or "raids"
    if not ALLOWED[what](Util.PlayerKey()) then
        return nil, REFUSED[what]
    end
    local root = Root(true)
    if not root then return nil, "Your guild is not known yet; try again in a moment." end
    return root
end

local RAID_CHECK = { raids = CanManage, groups = CanArrange,
                     roster = function(v, key) return CanManage(v, key) or IsOfficer(key) end }

-- A change to one raid: what = "raids" (run it: CanManageRaid), "groups" (CanEditGroups) or "roster"
-- (CanManageRoster). series = true: the whole weekly series (its own leader decides). Returns root, view or nil, err.
local function RequireRaid(occId, what, series)
    local root = Root(true)
    if not root then return nil, "Your guild is not known yet; try again in a moment." end
    local v = ResolveOcc(root, occId)
    if not v then return nil, "unknown raid" end
    local who = series and SeriesWho(root, v) or v
    if not RAID_CHECK[what](who, Util.PlayerKey()) then return nil, who.rl and REFUSED.led or REFUSED[what] end
    return root, v
end

-- What my edit of one raid's own record starts from: the stored record as it shows (a one-off raid, or a week's
-- override), else a new override of that week. A stored version that doesn't show (a deletion or change its writer
-- may not make) is never built on; the new rev still goes past it. Stamped with a new rev and me as the writer.
local function OccBase(root, occId, v)
    local cur = root.E[occId]
    local o
    if cur and not cur.del and Trusted(root, "E", cur) then
        o = Util.CopyTable(cur)
    else
        o = { id = occId, sid = v.sid, k = v.k }
    end
    o.rev, o.by = NextRev(cur), Util.PlayerKey()
    return o
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
    Trusted(root, kind, clean)
    if kind == "E" and clean.del then root.U[clean.id] = nil end
    if kind == "T" and clean.del then root.W[clean.id] = nil end
    Broadcast(kind, clean)
    Changed()
    return true
end

-- members: a set { [key] = true } or an array of keys (the roster). id = nil creates a team. opts (optional):
--   lineups = { { id = lineup id|nil (a new one), name = text|nil, size = 10|25, specs = { [key] = spec index },
--               groups = { [key] = 1..8 }, seats = { [key] = 1..5 }, comp = cp|nil }, ... }: every lineup, in order
--               (1.3.2; at most 10, at least one)
--   or, for one lineup (ln = its id, default the first; a new team gets one): size = 10|25, specs, groups, seats,
--   comp (Core/RaidComp.lua; false clears it): nil keeps the lineup's current ones.
-- A comp with more slots than its lineup's size is refused. Roster members who were on a waitlist of the team are
-- taken off it. Returns ok, idOrErr.
function RaidPlan:SaveTeam(id, name, members, opts)
    local root, err = RequireOrganizer("teams")
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
    local Comp = ns.RaidComp
    local lineups = {}
    if type(opts.lineups) == "table" then
        for i, l in ipairs(opts.lineups) do
            if type(l) ~= "table" then return false, "invalid lineup" end
            lineups[i] = { id = l.id, n = l.name, sz = l.size, s = l.specs, grp = l.groups, gs = l.seats,
                           cp = l.comp or nil }
        end
    else
        for i, l in ipairs(cur and Lineup.Of(cur) or { { id = "1", sz = 25 } }) do
            lineups[i] = { id = l.id, n = l.n, sz = l.sz, s = l.s, grp = l.grp, gs = l.gs, cp = l.cp }
        end
        local l = lineups[1]
        for _, x in ipairs(lineups) do
            if x.id == opts.ln then l = x end
        end
        if opts.ln ~= nil and l.id ~= opts.ln then return false, "unknown lineup" end
        l.sz = opts.size or l.sz
        l.s = opts.specs or l.s
        if opts.groups then l.grp, l.gs = opts.groups, opts.seats
        elseif opts.seats then l.gs = opts.seats end
        if opts.comp == false then l.cp = nil elseif opts.comp ~= nil then l.cp = opts.comp end
    end
    if #lineups == 0 then return false, "A team has at least one lineup." end
    if #lineups > Lineup.MAX then return false, "A team has at most " .. Lineup.MAX .. " lineups." end
    -- new lineups get an id no lineup of the team has had in a while (its waitlist would come back with it)
    local used = {}
    for _, l in ipairs(lineups) do if l.id then used[l.id] = true end end
    for ln in pairs(root.W[id] or {}) do used[ln] = true end
    for i, l in ipairs(lineups) do
        if l.id == nil then
            local n = 0
            repeat
                n = n + 1
                l.id = Util.Hash({ id, Now(), i, n, GetTime() }):sub(1, 5)
            until not used[l.id] and IsId(l.id)
            used[l.id] = true
        end
        if not SIZES[l.sz] then return false, "Team size must be 10 or 25." end
        if l.s and not next(l.s) then l.s = nil end
        if l.grp and not next(l.grp) then l.grp, l.gs = nil, nil end
        if l.cp ~= nil then
            local cp = Comp:CleanComp(l.cp, 1000)
            if cp == false then return false, "That target comp is not valid." end
            l.cp = cp
        end
        local slots = l.cp and Comp:CompSize(l.cp) or 0
        if slots > l.sz then
            return false, ("The target comp%s has %d slots, more than the team's %d."):format(
                l.n and (" of " .. l.n) or "", slots, l.sz)
        end
    end
    -- the first lineup is mirrored on the fields a client before 1.3.2 reads
    local first = lineups[1]
    local rec = { id = id, rev = NextRev(cur), by = Util.PlayerKey(), n = name, m = list, L = lineups,
                  sz = first.sz, s = first.s, grp = first.grp, gs = first.gs, cp = first.cp }
    local ok, e = Commit(root, "T", rec)
    if not ok then return false, e end
    -- who joined the roster leaves the team's waitlists
    local onRoster = {}
    for _, key in ipairs(list) do onRoster[key] = true end
    local gone = {}
    for ln, entries in pairs(root.W[id] or {}) do
        for key, x in pairs(entries) do
            if not x.x and onRoster[key] then gone[#gone + 1] = { ln = ln, k = key } end
        end
    end
    tsort(gone, function(a, b) return a.ln .. ":" .. a.k < b.ln .. ":" .. b.k end)
    Lineup.Write(root, id, gone, function() return { x = true } end)
    return true, id
end

function RaidPlan:DeleteTeam(id)
    local root, err = RequireOrganizer("teams")
    if not root then return false, err end
    local cur = type(id) == "string" and root.T[id]
    if not cur or cur.del then return false, "unknown team" end
    return Commit(root, "T", { id = id, rev = NextRev(cur), by = Util.PlayerKey(), del = true })
end

---------------------------------------------------------------------------
-- Lineups and waitlists (1.3.2, user decisions 2026-10-06): a team has one roster and any number of lineups (10 or
-- 25 players, each with its own groups, specs, target comp and waitlist). In a lineup, a roster member in none of its
-- groups is unassigned; the waitlist holds players who are not on the roster, waiting for a spot, first in line
-- first. Neither counts for the comp. Waitlisted players are not invited to the team's raids (they are not on its
-- roster). Each guild member puts themselves on a waitlist and takes themselves off; the GM and the guild council
-- take anyone off and move them up or down; saving a roster that takes someone in takes them off the team's
-- waitlists. The entries are root.W[team id][lineup id][player] (Lineup.CleanWait), sent live on GUILD (RTW) and
-- relayed with their team (RPG w; the team's digest item covers them).
---------------------------------------------------------------------------

-- Writes waitlist entries as me: items = { { ln, k, ... }, ... }; fields(current entry|nil, item) -> { at, o, sp, x }.
-- Stored, then sent on GUILD (RTW). Returns how many were stored.
function Lineup.Write(root, tid, items, fields)
    local me, now = Util.PlayerKey(), Now()
    local out = {}
    for _, it in ipairs(items) do
        local cur = root.W[tid] and root.W[tid][it.ln] and root.W[tid][it.ln][it.k]
        local f = fields(cur, it) or {}
        local e = Lineup.CleanWait({ rev = NextRev(cur), by = me, at = f.at, o = f.o, sp = f.sp, x = f.x }, now)
        if e and Lineup.MergeWait(root, tid, it.ln, it.k, e) then
            out[#out + 1] = { tm = tid, ln = it.ln, k = it.k, e = e }
        end
    end
    for i = 1, #out, MAX_RPS_ENTRIES do
        local chunk = {}
        for j = i, min(#out, i + MAX_RPS_ENTRIES - 1) do chunk[#chunk + 1] = out[j] end
        Send({ t = "RTW", l = chunk }, "GUILD", nil, "ctrl")
    end
    if #out > 0 then Changed() end
    return #out
end

-- A lineup's waitlist (any ResolveTeam form; a draft leaves out whom it takes onto its roster), first in line first:
-- { { key, c, sp, source = "waitlist" (the spec they picked) | GetMemberSpec's, at = when they joined, by, n = their
-- place }, ... }. Roster members, blacklisted players, entries taken off and entries written by someone who may not
-- (neither the player nor the GM / guild council) are left out.
function RaidPlan:GetWaitlist(team)
    local out = {}
    local t = self:ResolveTeam(team)
    local root = Root(false)
    local list = t and t.id and t.ln and root and root.W[t.id] and root.W[t.id][t.ln]
    if not list then return out end
    local onRoster = {}
    for _, key in ipairs(t.members) do onRoster[key] = true end
    for key, e in pairs(list) do
        if not e.x and not onRoster[key] and (e.by == key or CanTeams(e.by)) and not self:IsBlacklisted(key) then
            local sp, c, source = self:GetMemberSpec(key)
            if e.sp and IsInt(e.sp, 1, SpecCount(c)) then sp, source = e.sp, "waitlist" end
            out[#out + 1] = { key = key, c = c, sp = sp, source = source, at = e.at, by = e.by, ord = e.o or e.at }
        end
    end
    tsort(out, function(a, b)
        if a.ord ~= b.ord then return a.ord < b.ord end
        return a.key < b.key
    end)
    for i, m in ipairs(out) do m.n = i end
    return out
end

-- Puts me on a lineup's waitlist (ln nil: the team's first lineup): any guild member not on the team's roster, as
-- the spec I'd play (a spec index of my class; nil: as my sign-ups / BiS list say). Joining again changes only the
-- spec and keeps my place. Returns ok, err.
function RaidPlan:JoinWaitlist(teamId, ln, sp)
    local root = Root(true)
    local t = root and self:GetTeam(teamId)
    local l = t and self:FindLineup(t, ln)
    if not l then return false, "unknown lineup" end
    local me = Util.PlayerKey()
    for _, key in ipairs(t.members) do
        if key == me then return false, "You're on this team's roster already." end
    end
    if self:IsBlacklisted(me) then return false, "You're on the guild's raid blacklist." end
    if sp ~= nil and not IsInt(sp, 1, SpecCount(MyClass())) then return false, "unknown spec" end
    local cur = root.W[teamId] and root.W[teamId][l.id] and root.W[teamId][l.id][me]
    local on = cur ~= nil and not cur.x
    if not on and #self:GetWaitlist({ id = teamId, ln = l.id }) >= Lineup.MAX_WAIT then
        return false, ("This waitlist is full (%d players)."):format(Lineup.MAX_WAIT)
    end
    local n = Lineup.Write(root, teamId, { { ln = l.id, k = me } }, function(c)
        if on then return { at = c.at, o = c.o, sp = sp } end
        return { at = Now(), sp = sp }
    end)
    if n == 0 then return false, "Could not join the waitlist." end
    return true
end

-- Takes a player off a lineup's waitlist (ln nil: the first lineup): myself, or (the GM and the guild council)
-- anyone. Returns ok, err.
function RaidPlan:LeaveWaitlist(teamId, ln, key)
    local root = Root(true)
    local me = Util.PlayerKey()
    key = key and WireKey(key) or me
    if key ~= me and not CanTeams(me) then return false, REFUSED.teams end
    if ln == nil then
        local l = self:FindLineup(teamId)
        ln = l and l.id
    end
    local cur = root and IsId(teamId) and type(ln) == "string" and root.W[teamId] and root.W[teamId][ln]
        and root.W[teamId][ln][key]
    if not cur or cur.x then return false, "not on the waitlist" end
    Lineup.Write(root, teamId, { { ln = ln, k = key } }, function() return { x = true } end)
    return true
end

-- Moves a player one place up (delta < 0) or down (delta > 0) on a lineup's waitlist: the GM and the guild council.
-- They and the player they pass swap places. Returns ok, err.
function RaidPlan:MoveWaitlist(teamId, ln, key, delta)
    if not CanTeams(Util.PlayerKey()) then return false, REFUSED.teams end
    local root = Root(true)
    local list = root and self:GetWaitlist({ id = teamId, ln = ln }) or {}
    local i
    for j, m in ipairs(list) do
        if m.key == key then i = j end
    end
    local step = (tonumber(delta) or 0) < 0 and -1 or 1
    local a, b = i and list[i], i and list[i + step]
    if not (a and b) then return false, "can't move there" end
    local oa, ob = b.ord, a.ord
    if oa == ob then oa = oa + step end
    Lineup.Write(root, teamId, { { ln = ln, k = a.key, o = oa }, { ln = ln, k = b.key, o = ob } }, function(c, it)
        return { at = c and c.at, sp = c and c.sp, o = it.o }
    end)
    return true
end

-- Copies the raid fields of `f` (UI input) onto rec; `partial` keeps missing ones. Returns ok, err.
local function ApplyFields(rec, f, partial)
    if f.i ~= nil or not partial then
        if not INSTANCE_BY_KEY[f.i] then return false, "Pick a raid." end
        rec.i = f.i
        -- (the default size: the larger of the night's instances)
        if f.sz == nil and not partial then
            rec.sz = INSTANCE_BY_KEY[f.i].size
            for _, key in ipairs(type(f.ix) == "table" and f.ix or {}) do
                local inst = INSTANCE_BY_KEY[key]
                if inst and inst.size > rec.sz then rec.sz = inst.size end
            end
        end
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
    -- the night's other instances, in order (1.3.2); an override keeps {} (that week holds i alone)
    if f.ix ~= nil then
        local ix = CleanInstanceList(f.ix)
        if ix == false then return false, "invalid raid list" end
        local list = {}
        for _, key in ipairs(ix) do
            if key ~= (rec.i or f.i) then list[#list + 1] = key end
        end
        rec.ix = (#list > 0 or rec.sid) and list or nil
    end
    -- the lineup of each team (1.3.2); an override keeps {} (that week uses the teams' first lineups)
    if f.tl ~= nil then
        local tl = Lineup.CleanChoice(f.tl)
        if tl == false then return false, "invalid lineup choice" end
        rec.tl = (next(tl) or rec.sid) and tl or nil
    end
    -- an override of a weekly raid keeps false / {} (that week differs from its series); other records drop them
    if f.lk ~= nil then
        if f.lk then rec.lk = true
        elseif rec.sid then rec.lk = false
        else rec.lk = nil end
    end
    if f.pv ~= nil then
        if f.pv then rec.pv = true
        elseif rec.sid then rec.pv = false
        else rec.pv = nil end
    end
    if f.inv ~= nil then
        local list = {}
        for k, v in pairs(type(f.inv) == "table" and f.inv or {}) do
            local key = type(k) == "string" and v and k or (type(v) == "string" and v) or nil
            key = key and WireKey(key)
            if not key then return false, "invalid invite list" end
            list[#list + 1] = key
        end
        if #list > MAX_INVITES then return false, "A raid has at most " .. MAX_INVITES .. " extra invites." end
        local inv = CleanInvites(list)
        rec.inv = (#inv > 0 or rec.sid) and inv or nil
    end
    if f.ml ~= nil then
        local ml = f.ml == false and 0 or f.ml   -- false / 0: every level
        if not IsInt(ml, 0, MAX_LEVEL) then return false, "The minimum level is at most " .. MAX_LEVEL .. "." end
        if ml > 0 then rec.ml = ml
        elseif rec.sid then rec.ml = 0
        else rec.ml = nil end
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
    -- the raid's leader (I name them: the callers check CanAssignLeader); false: none (an override: none that week)
    if f.rl ~= nil then
        if f.rl == false or f.rl == "" then
            if rec.sid then rec.rl = false else rec.rl = nil end
            rec.rlb = nil
        else
            local key = WireKey(f.rl)
            if not key then return false, "unknown raid leader" end
            rec.rl, rec.rlb = key, Util.PlayerKey()
        end
    end
    return true
end

-- fields: { i = instance key, ix = { instance key, ... } (1.3.2: the night's other instances, in order), t = start
-- (server time), sz = 10|25 (default: the larger instance's), tm = { teamId },
-- tl = { [teamId] = lineup id } (1.3.2: the lineup of a team the raid uses; default its first of the raid's size),
-- lk = bool (locked: only its teams and extra invites sign up), inv = { key } (extra invites), ml = minimum
-- character level (nil / 0 / false: every level), ti = title, no = note, rl = the raid's leader (named by the GM and
-- the raid leaders on the list only), weekly = bool }. Returns ok, occIdOrErr.
function RaidPlan:CreateRaid(f)
    local root, err = RequireOrganizer()
    if not root then return false, err end
    if type(f) ~= "table" then return false, "invalid raid" end
    if f.rl and not CanAssignLeader(Util.PlayerKey()) then return false, REFUSED.lead end
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
-- raid. Who runs the raid edits it (CanManageRaid; the whole series: CanManageSeries); naming its leader (rl) is for
-- the GM and the raid leaders on the list, on any raid. Returns ok, err.
function RaidPlan:EditRaid(occId, f, scope)
    if type(f) ~= "table" then return false, "unknown raid" end
    local me = Util.PlayerKey()
    if f.rl ~= nil and not CanAssignLeader(me) then return false, REFUSED.lead end
    local onlyLeader = f.rl ~= nil
    for k in pairs(f) do
        if k ~= "rl" then onlyLeader = false end
    end
    local root, v
    if onlyLeader then
        root = Root(true)
        v = root and ResolveOcc(root, occId)
        if not v then return false, "unknown raid" end
    else
        root, v = RequireRaid(occId, "raids", scope == "series")
        if not root then return false, v end
    end
    if not v.sid then
        local rec = OccBase(root, occId, v)
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
    local o = OccBase(root, occId, v)
    local ok, e = ApplyFields(o, f, true)
    if not ok then return false, e end
    if f.x == false then o.x = nil end
    return Commit(root, "E", o)
end

-- scope "one" cancels this raid (it stays listed as cancelled); "series" deletes the whole weekly series.
function RaidPlan:CancelRaid(occId, scope)
    local root, v = RequireRaid(occId, "raids", scope == "series")
    if not root then return false, v end
    local me = Util.PlayerKey()
    if v.sid and scope == "series" then
        local s = Util.CopyTable(root.S[v.sid])
        s.rev, s.by, s.x = NextRev(s), me, true
        return Commit(root, "S", s)
    end
    local o = OccBase(root, occId, v)
    o.x = true
    return Commit(root, "E", o)
end

-- Deletes a raid for everyone (it disappears, with its sign-ups and group layout). scope "series" on a weekly raid
-- deletes the whole weekly series; otherwise only this raid (for a weekly raid: this week's; not by a leader of that
-- week only: CanDeleteRaid). Returns ok, err.
function RaidPlan:DeleteRaid(occId, scope)
    local root, v = RequireRaid(occId, "raids", scope == "series")
    if not root then return false, v end
    if v.sid and scope == "series" then return self:CancelRaid(occId, "series") end
    if not CanManage(SeriesWho(root, v), Util.PlayerKey()) then return false, REFUSED.week end
    -- the tombstone keeps the leader of the version deleted: a leader's own deletion is theirs to write (Entitled)
    local base = OccBase(root, occId, v)
    local ok, e = Commit(root, "E", { id = occId, sid = v.sid, k = v.k, rev = base.rev, by = base.by, del = true,
                                      rl = base.rl, rlb = base.rlb })
    if ok and ns.RaidInvite and ns.RaidInvite.IsActive and ns.RaidInvite:IsActive(occId) then ns.RaidInvite:Stop() end
    return ok, e
end

-- A weekly series ends after this occurrence ("Stop repeating").
function RaidPlan:StopRepeating(occId)
    local root, v = RequireRaid(occId, "raids", true)
    if not root then return false, v end
    if not v.sid then return false, "not a weekly raid" end
    local s = Util.CopyTable(root.S[v.sid])
    s.rev, s.by, s.u = NextRev(s), Util.PlayerKey(), v.k
    return Commit(root, "S", s)
end

-- grp: { [key] = group 1..8 } (nil / empty clears the layout); gs (optional): { [key] = seat 1..5 in the group }.
function RaidPlan:SetGroups(occId, grp, gs)
    local root, v = RequireRaid(occId, "groups")
    if not root then return false, v end
    local clean = CleanGroups(grp or {})
    if clean == false then return false, "invalid group layout" end
    local o = OccBase(root, occId, v)
    o.grp = next(clean) and clean or nil
    o.gs = o.grp and CleanSeats(gs, o.grp) or nil
    return Commit(root, "E", o)
end

---------------------------------------------------------------------------
-- Public API: writing (roster managers): guests, declined and removed answers
---------------------------------------------------------------------------

-- Changes the raid's own record (an override for a weekly raid) through fn(o, v) and shares it. fn returns false, err
-- to refuse. Returns ok, err.
local function EditOcc(occId, fn)
    local root, v = RequireRaid(occId, "roster")
    if not root then return false, v end
    local o = OccBase(root, occId, v)
    local ok, e = fn(o, v)
    if ok == false then return false, e end
    for _, f in ipairs({ "gu", "rj", "rm", "gx", "grp" }) do
        if o[f] and not next(o[f]) then o[f] = nil end
    end
    if not o.grp then o.gs = nil end
    return Commit(root, "E", o)
end

local function TakeOutOfGroups(o, key)
    if o.grp then o.grp[key] = nil end
    if o.gs then o.gs[key] = nil end
end

-- Adds a player outside the guild to the raid by name (or changes their class / spec). They count as accepted. (One
-- taken off by hand before is added: by hand, that is meant.) Returns ok, keyOrErr.
function RaidPlan:AddGuest(occId, name, classFile, spec)
    local key = WireKey(type(name) == "string" and Util.Trim(name) or name)
    if not key then return false, "Type the guest's character name." end
    if type(classFile) ~= "string" or not (ns.SPECS and ns.SPECS[classFile]) then return false, "Pick the guest's class." end
    if spec ~= nil and not IsInt(spec, 1, SpecCount(classFile)) then return false, "invalid spec" end
    local G = Guild()
    if G and G.IsInGuild and G:IsInGuild(key, true) then
        return false, Util.ShortName(key) .. " is in the guild: guild members sign up themselves."
    end
    if self:IsBlacklisted(key) then return false, Util.ShortName(key) .. " is on the blacklist." end
    local ok, err = EditOcc(occId, function(o)
        o.gu = o.gu or {}
        if not o.gu[key] and CountTable(o.gu) >= MAX_GUESTS then
            return false, "A raid has at most " .. MAX_GUESTS .. " guests."
        end
        o.gu[key] = { c = classFile, sp = spec, at = o.gu[key] and o.gu[key].at or Now() }
        if o.gx then o.gx[key] = nil end
    end)
    if not ok then return false, err end
    return true, key
end

-- 1.3 guest book: several players who joined the raid at once, as one edit of the raid's record. list = { { key, c,
-- sp }, ... }; players in the guild, blacklisted ones, those already guests and guests taken off by hand (gx) are
-- skipped. Returns ok, keysOrErr (the keys added).
function RaidPlan:AddGuests(occId, list)
    if type(list) ~= "table" then return false, "nothing to add" end
    local G = Guild()
    local added = {}
    local ok, err = EditOcc(occId, function(o)
        o.gu = o.gu or {}
        for _, g in ipairs(list) do
            local key = type(g) == "table" and WireKey(g.key) or nil
            local spec = g and g.sp
            if key and not o.gu[key] and not (o.gx and o.gx[key])
                and type(g.c) == "string" and ns.SPECS and ns.SPECS[g.c]
                and not (G and G.IsInGuild and G:IsInGuild(key, true)) and not self:IsBlacklisted(key)
                and CountTable(o.gu) < MAX_GUESTS then
                if spec ~= nil and not IsInt(spec, 1, SpecCount(g.c)) then spec = nil end
                o.gu[key] = { c = g.c, sp = spec, at = Now() }
                added[#added + 1] = key
            end
        end
        if #added == 0 then return false, "nobody to add" end
    end)
    if not ok then return false, err end
    return true, added
end

-- Takes a guest off the raid. Remembered on the raid (gx), so nobody's client adds them again when they join the
-- raid's group (GuestBook); at most MAX_MARKS, the oldest give way.
function RaidPlan:RemoveGuest(occId, key)
    return EditOcc(occId, function(o)
        if type(key) ~= "string" or not (o.gu and o.gu[key]) then return false, "not a guest of this raid" end
        o.gu[key] = nil
        TakeOutOfGroups(o, key)
        o.gx = o.gx or {}
        if CountTable(o.gx) >= MAX_MARKS then
            local oldest
            for k, at in pairs(o.gx) do
                if not oldest or at < o.gx[oldest] or (at == o.gx[oldest] and k < oldest) then oldest = k end
            end
            o.gx[oldest] = nil
        end
        o.gx[key] = Now()
    end)
end

-- Was that player taken off the raid (a view or an id) as a guest by hand (and not added by hand again since)?
function RaidPlan:IsGuestRemoved(occId, key)
    local v = type(occId) == "table" and occId or self:GetRaid(occId)
    return (v and v.gx and type(key) == "string" and v.gx[key]) and true or false
end

-- Turns a member down for the raid: their answer no longer counts, they can't answer again (with any of their
-- characters) and they are listed as declined.
function RaidPlan:DeclineSignup(occId, key)
    key = WireKey(key)
    if not key then return false, "unknown player" end
    return EditOcc(occId, function(o, v)
        if v.gu and v.gu[key] then return false, "That is a guest: remove them instead." end
        o.rj = o.rj or {}
        if not o.rj[key] and CountTable(o.rj) >= MAX_MARKS then return false, "Too many declined players on this raid." end
        o.rj[key] = true
        TakeOutOfGroups(o, key)
    end)
end

-- Approves a request to join the locked raid: the player becomes one of its extra invites (this raid only; a weekly
-- raid's this week), so their answer counts. Who runs the raid does it (CanManageRaid). Deny: DeclineSignup.
function RaidPlan:ApproveRequest(occId, key)
    local v = self:GetRaid(occId)
    if not v then return false, "unknown raid" end
    key = WireKey(key)
    if not key then return false, "unknown player" end
    if not self:CanManageRaid(v) then return false, "Only who runs this raid can answer its requests." end
    if not LockedOut(v, key) then return true end
    local list = CopyList(v.inv) or {}
    list[#list + 1] = key
    return self:EditRaid(occId, { inv = list }, "one")
end

-- Takes a member's answer off the raid, as if they never answered. They can answer again.
function RaidPlan:RemoveSignup(occId, key)
    key = WireKey(key)
    if not key then return false, "unknown player" end
    return EditOcc(occId, function(o)
        local root = Root(false)
        local s = root and root.U[occId] and root.U[occId][key]
        if not s then return false, "That player has not answered." end
        o.rm = o.rm or {}
        if not o.rm[key] and CountTable(o.rm) >= MAX_MARKS then return false, "Too many removed answers on this raid." end
        o.rm[key] = s.rev
        if o.rj then o.rj[key] = nil end
        TakeOutOfGroups(o, key)
    end)
end

-- Undoes a decline (and a removal): the member's answer counts again.
function RaidPlan:RestoreSignup(occId, key)
    return EditOcc(occId, function(o)
        if type(key) ~= "string" or not ((o.rj and o.rj[key]) or (o.rm and o.rm[key])) then
            return false, "That player was not declined."
        end
        if o.rj then o.rj[key] = nil end
        if o.rm then o.rm[key] = nil end
    end)
end

---------------------------------------------------------------------------
-- Public API: sign-ups (everyone, for their own characters)
---------------------------------------------------------------------------

-- status: "A" | "T" | "B" | "X"; spec: index into ns.SPECS[the character's class] (nil = keep / last used); note:
-- optional (false clears it); charKey: another character of my account to answer with (default: this one).
-- Returns ok, err.
function RaidPlan:SignUp(occId, status, spec, note, charKey)
    local root = Root(true)
    local player = Util.PlayerKey()
    if not root or not player then return false, "Your guild is not known yet; try again in a moment." end
    local me = player
    if charKey ~= nil and charKey ~= player then
        me = WireKey(charKey)
        local G = Guild()
        if not me or not (G and G.SameAccount and G:SameAccount(player, me)) then
            return false, "That is not one of your characters in this guild. Log in on it once first."
        end
    end
    local v = ResolveOcc(root, occId)
    if not v then return false, "unknown raid" end
    if v.cancelled then return false, "This raid was cancelled." end
    if v.t < Now() - SIGNUP_CLOSE then return false, "This raid is over." end
    if not STATUSES[status] then return false, "invalid status" end
    local block = self:GetSignupBlock(v, me)
    if block == "blacklist" then
        return false, "You can't sign up for raids. Contact an officer."
    elseif block == "declined" then
        return false, "You were taken off this raid."
    elseif block == "lock" and not self:CanRequest(v, me) then
        -- (outside a locked raid the answer is a request to join; private, or who runs it: invite instead)
        return false, v.pv and "This raid is private to its teams and invited players. Ask a raid leader for an invite."
            or "This raid is locked to its teams and invited players: add yourself with Invite."
    elseif block == "level" then
        return false, strformat("This raid is for level %d characters.", v.ml)
    end
    local class = ClassOf(me)
    if not class then return false, "That character's class is not known yet; try again in a moment." end
    local cur = root.U[occId] and root.U[occId][me]
    local s = { st = status, rev = NextRev(cur), c = class }
    -- an answer the organizers removed is older than the new one, whatever the clocks say
    if v.rm and v.rm[me] and s.rev <= v.rm[me] then s.rev = v.rm[me] + 1 end
    -- the newest answer of my characters is the one that counts: this one
    for _, other in ipairs(self:GetMyCharacters()) do
        local o = other ~= me and root.U[occId] and root.U[occId][other]
        if o and s.rev <= o.rev then s.rev = o.rev + 1 end
    end
    s.at = cur and (cur.at or cur.rev) or s.rev
    if spec == nil then spec = (cur and cur.sp) or self:GetLastSpec(me) end
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
    if me == player then
        BroadcastSignups({ { o = occId, s = clean } })
    else
        BroadcastSignups({ { o = occId, s = clean, k = me } }, "RPA")
    end
    Changed()
    return true
end

-- The sign-ups of `key` for raids still shown (sent at login, so one made while nobody else was online spreads
-- later). `tag` = true names the character in each entry (RPA: another character of my account).
local function LiveSignups(key, tag)
    local root = Root(false)
    local out = {}
    if not root or not key then return out end
    local minTs = Now() - KEEP_PAST
    for occId, u in pairs(root.U) do
        local s = u[key]
        if s then
            local t = OccTime(root, occId)
            if t and t >= minTs then out[#out + 1] = { o = occId, s = s, k = tag and key or nil } end
        end
    end
    tsort(out, function(a, b) return a.o < b.o end)
    return out
end

local function MyLiveSignups()
    return LiveSignups(Util.PlayerKey())
end

local function MyAltSignups()
    local out = {}
    local me = Util.PlayerKey()
    for _, key in ipairs(me and Linked(me) or {}) do
        for _, e in ipairs(LiveSignups(key, true)) do out[#out + 1] = e end
    end
    return out
end

---------------------------------------------------------------------------
-- The same raids for everyone after a role is taken away (user decision 2026-10-04)
---------------------------------------------------------------------------
-- A version shows where it arrived while its writer was entitled to write it (Trusted keeps that), so after the
-- writer loses the role (off the raid leaders list or the council, an officer no more) the clients that had it keep
-- showing it, while one that gets it only now (a fresh install, a member who was away) would not: the raid would be
-- gone for them, and they could not sign up. A raid's leader also stops leading once whoever named them may no longer
-- name leaders (the raid goes back to the raid leaders on the list). So a raid planner's client (for teams: the GM's
-- or a council member's) that shows such a record writes it again as its own, the same apart from a leader who no
-- longer counts, and every client shows the same again. Only what is still in use (teams, weekly raids that go on,
-- raids not over yet, deletions still spreading), each once, a while after the change, spread by name: one planner
-- usually writes and the others then find nothing to do. Until a planner (for teams: the GM or a council member) is
-- online, a client that only gets such a record now still leaves it out.

local loginAt                       -- GetTime() of my login (RestampPass waits for the guild's lists and ranks)

-- Is the record still in use (worth writing again)?
local function InUse(root, kind, rec, now)
    if kind == "T" then return true end
    if kind == "S" then
        if rec.x then return rec.rev >= now - TOMBSTONE_DAYS end
        return not (rec.u and SeriesTime(rec, rec.u) < now - SIGNUP_CLOSE)
    end
    local t = OccTime(root, rec.id)
    if t then return t >= now - SIGNUP_CLOSE end
    return rec.rev >= now - TOMBSTONE_DAYS
end

-- The new version of a record I show that a client getting it now would leave out, or whose leader no longer counts;
-- nil when it needs none, and when I know of a newer version (refused for now: mine is behind, written again it
-- would undo that one's changes).
local function Restamped(root, kind, rec)
    if pending[kind .. ":" .. rec.id] or not Trusted(root, kind, rec) then return nil end
    local stale = not Entitled(root, kind, rec)
    local crown = kind ~= "T" and type(rec.rl) == "string" and not CanAssignLeader(rec.rlb)
    if not stale and not crown then return nil end
    local out = Util.CopyTable(rec)
    out.rev, out.by = NextRev(rec), Util.PlayerKey()
    if crown then
        -- no leader, as it shows now (a week's own leader: none that week)
        if rec.sid then out.rl = false else out.rl = nil end
        out.rlb = nil
    end
    return out
end

local RestampPass

-- RestampPass after `wait` seconds plus my spread (and not before the lists settled after my login); once: more
-- triggers meanwhile don't move it.
local function ScheduleRestamp(wait)
    if restampQueued or not ns.loggedIn then return end
    restampQueued = true
    if loginAt then wait = max(wait, RESTAMP_AFTER_LOGIN - (GetTime() - loginAt)) end
    local spread = (tonumber(Util.Hash(Util.PlayerKey() or ""):sub(1, 4), 16) or 0) % (RESTAMP_SPREAD + 1)
    Util.After(wait + spread, function()
        restampQueued = false
        RestampPass()
    end)
end

RestampPass = function()
    local root = Root(false)
    local me = Util.PlayerKey()
    local G = Guild()
    if not root or not me or not (G and G.IsReady and G:IsReady()) then return end
    local plans, teams = IsOrganizer(me), CanTeams(me)
    if not plans and not teams then return end
    local now, n = Now(), 0
    for _, kind in ipairs({ "T", "S", "E" }) do
        if (kind == "T" and teams) or (kind ~= "T" and plans) then
            local ids = {}
            for id in pairs(root[kind]) do ids[#ids + 1] = id end
            tsort(ids)
            for _, id in ipairs(ids) do
                local rec = root[kind][id]
                local new = rec and InUse(root, kind, rec, now) and Restamped(root, kind, rec)
                if new then
                    if n >= MAX_RESTAMPS then
                        ScheduleRestamp(RESTAMP_WAIT)
                        return
                    end
                    if RateLimit("RPR:" .. kind .. ":" .. id, 600) and Commit(root, kind, new) then n = n + 1 end
                end
            end
        end
    end
end

-- The guild's roles (or who shares an account) changed: the versions refused for now again, and later a look for
-- records to write again.
local function RolesChanged()
    RetryPending()
    ScheduleRestamp(RESTAMP_WAIT)
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
    -- waitlists (1.3.2): of teams gone or deleted, of lineups the team doesn't have, entries taken off long ago
    for tid, team in pairs(root.W) do
        local t = root.T[tid]
        if not t or t.del then
            root.W[tid] = nil
            changed = true
        else
            local has = {}
            for _, l in ipairs(Lineup.Of(t)) do has[l.id] = true end
            for ln, list in pairs(team) do
                for key, e in pairs(list) do
                    if not has[ln] or (e.x and e.rev < now - TOMBSTONE_DAYS) then
                        list[key] = nil
                        changed = true
                    end
                end
                if not next(list) then team[ln] = nil end
            end
            if not next(team) then root.W[tid] = nil end
        end
    end
    -- trust marks of record versions that are gone
    for k in pairs(root.OK) do
        local kind, id = k:match("^(%u):([^:]+):")
        local rec = kind and type(root[kind]) == "table" and root[kind][id]
        if type(rec) ~= "table" or TrustKey(kind, rec) ~= k then root.OK[k] = nil end
    end
    if changed then Changed() end
end

---------------------------------------------------------------------------
-- Slash: /dz plan (a text overview; the Raids tab is the real UI)
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
        Comm:Register("RPA", OnAltSignups)
        Comm:Register("BLL", OnBlacklist)
        Comm:Register("BLQ", OnBlacklistQuery)
        Comm:Register("RPD", OnDigest)
        Comm:Register("RPK", OnClaim)
        Comm:Register("RPW", OnWant)
        Comm:Register("RPG", OnGive)
        Comm:Register("RTW", Lineup.OnLive)
    end
    ns:RegisterSlash("plan", SlashPlan, "list the planned raids and your sign-ups")
    -- The council list decides what is shown: repaint when it changes.
    ns:On("CONFIG_UPDATED", Changed)
    -- Whose characters belong together decides whose answers count: repaint when that changes.
    ns:On("ACCOUNTS_UPDATED", Changed)
    -- Who may write what changed: versions refused for now, and records to write again (RestampPass).
    for _, msg in ipairs({ "CONFIG_UPDATED", "ACCOUNTS_UPDATED", "ROSTER_UPDATED" }) do ns:On(msg, RolesChanged) end
    -- The target comp's spec index (GetSpecIndex) is built again after a change of the plans, the roster, the
    -- accounts or a BiS list.
    for _, msg in ipairs({ "RAIDPLAN_CHANGED", "ROSTER_UPDATED", "ACCOUNTS_UPDATED", "LIST_UPDATED",
                           "MYLIST_CHANGED" }) do
        ns:On(msg, function() RaidPlan.specIndexCache = nil end)
    end
end

function RaidPlan:OnLogin()
    loginAt = GetTime()
    ScheduleRestamp(RESTAMP_AFTER_LOGIN)
    local function Daily()
        RaidPlan:Prune()
        Util.After(DAY / 4, Daily)
    end
    -- The guild key (and roster) arrive a little after login.
    Util.RandomDelay(15, 30, function()
        Daily()
        BroadcastSignups(MyLiveSignups())
        BroadcastSignups(MyAltSignups(), "RPA")
    end)
    -- A roster manager shares the blacklist once after logging in, for members who logged in while none was online.
    Util.RandomDelay(20, 40, function()
        if CanRoster(Util.PlayerKey()) and RaidPlan:GetBlacklistRev() > 0 then SendBlacklist() end
    end)
end
